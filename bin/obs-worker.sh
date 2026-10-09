#!/usr/bin/env bash
# Persistent worker: indexes ModSecurity decisions, forwards JSON events, and sends throttled alerts.
set -euo pipefail
umask 077
export LC_ALL=C
DATA_DIR="${DATA_DIR:-/data}"
OBS_DIR="${OBS_DIR:-$DATA_DIR/observability}"
EVENTS_FILE="${EVENTS_FILE:-$DATA_DIR/logs/events.jsonl}"
AUDIT_FILE="${AUDIT_FILE:-$DATA_DIR/logs/modsec_audit.json}"
mkdir -p "$OBS_DIR" "$DATA_DIR/logs"
: > /dev/null
[[ -f "$EVENTS_FILE" ]] || touch "$EVENTS_FILE"
[[ -f "$AUDIT_FILE" ]] || touch "$AUDIT_FILE"

# Read only complete lines and advance a byte offset after successful delivery.
# Cursors are persistent. On truncation/rotation, restart at byte zero.
read_new_lines() {
  local input="$1" cursor="$2" output="$3" offset=0 size=0 consumed=0 line
  [[ -f "$cursor" ]] && read -r offset < "$cursor" || true
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  [[ -f "$input" ]] || { : > "$output"; return 0; }
  size="$(wc -c < "$input")"
  (( offset <= size )) || offset=0
  : > "$output"
  while IFS= read -r line; do
    consumed=$((consumed + ${#line} + 1))
    printf '%s\n' "$line" >> "$output"
  done < <(tail -c "+$((offset+1))" "$input")
  printf '%s\n' "$((offset+consumed))" > "$cursor.next"
}

normalize_audit() {
  local offset_tmp="$OBS_DIR/.audit-chunk" cursor="$OBS_DIR/audit.offset"
  read_new_lines "$AUDIT_FILE" "$cursor" "$offset_tmp"
  [[ -s "$offset_tmp" ]] || { mv -f "$cursor.next" "$cursor"; return; }
  local generated="$OBS_DIR/.waf-events"
  # Only the security-relevant metadata is copied into centralized events.
  # Request bodies, cookies and authorization headers are deliberately excluded.
  if jq -c --arg http_port "${LITEEDGE_HTTP_PORT:-8080}" --arg https_port "${LITEEDGE_HTTPS_PORT:-8443}" --arg public_http "${LITEEDGE_PUBLIC_HTTP_PORT:-80}" --arg public_https "${LITEEDGE_PUBLIC_HTTPS_PORT:-443}" '
    .transaction as $t
    | ($t.messages // [])[]
    | {type:"waf",epoch:(now|floor),timestamp:(now|todateiso8601),
       host:($t.request.hostname // $t.request.headers.Host // $t.request.headers.host // ""),route:"-",
       port:(($t.host_port // $t.request.port // "" | tostring) | if . == $http_port then $public_http elif . == $https_port then $public_https else . end),method:($t.request.method // ""),
       status:($t.response.http_code // 0),ip:($t.client_ip // ""),
       uri:(($t.request.uri // "") | split("?")[0]),
       request_id:($t.unique_id // ""),rule_id:(.details.ruleId // .details.rule_id // "" | tostring),
       message:(.message // "" | tostring | .[0:250]),
       severity:(.details.severity // ""),
       action:(if (($t.is_interrupted // $t.intervention.disruptive // false) == true) or ((.message // "") | test("access denied|intervention"; "i")) then "blocked" else "matched" end)}
  ' "$offset_tmp" > "$generated"; then
    # Attach the matching public request route by host, client IP and path.
    # WAF's transaction.unique_id is not the same value as NGINX's request_id.
    local event host uri ip request_event
    while IFS= read -r event; do
      [[ -n "$event" ]] || continue
      host="$(jq -r '.host' <<< "$event")"
      uri="$(jq -r '.uri' <<< "$event")"
      ip="$(jq -r '.ip' <<< "$event")"
      request_event="$(tail -n 1000 "$EVENTS_FILE" | jq -c --arg h "$host" --arg u "$uri" --arg ip "$ip" --argjson cutoff "$(( $(date +%s) - 30 ))" 'select(.type=="http" and .host==$h and .uri==$u and .ip==$ip) | select(.status >= 400 and ((.epoch|tonumber) >= $cutoff)) ' | tail -n1)"
      if [[ -n "$request_event" ]]; then
        event="$(jq -c --argjson req "$request_event" '.route=$req.route | .port=$req.port' <<< "$event")"
      fi
      printf '%s\n' "$event" >> "$EVENTS_FILE"
    done < "$generated"
    mv -f "$cursor.next" "$cursor"
  else
    echo 'LiteEdge observability: waiting for complete ModSecurity JSON audit record.' >&2
  fi
}

send_http() {
  local url="$1" payload="$2" key="${3:-}" provider="${4:-generic}" content_type=application/json header_name=Authorization header_value=""
  [[ "$url" == https://* ]] || return 1
  case "$provider" in
    splunk) payload="$(printf '%s' "$payload" | jq -c '{event:., sourcetype:"_json"}')"; header_value="Splunk $key" ;;
    datadog) header_name=DD-API-KEY; header_value="$key" ;;
    elastic) payload="$(printf '%s' "$payload" | jq -c '{index:{}}')"$'\n'"$payload"$'\n'; content_type=application/x-ndjson; header_value="ApiKey $key" ;;
    generic) [[ -z "$key" ]] || header_value="Bearer $key" ;;
    *) return 1 ;;
  esac
  local -a curl_args=(--fail --silent --show-error --connect-timeout 3 --max-time 12 --proto '=https' --max-redirs 0 -X POST -H "Content-Type: $content_type" --data-binary @-)
  [[ -z "$header_value" ]] || curl_args+=(-H "$header_name: $header_value")
  printf '%s' "$payload" | curl "${curl_args[@]}" "$url" >/dev/null
}

forward_event() {
  local event="$1" config="$OBS_DIR/collector.json" mode host port protocol provider url token
  [[ -f "$config" ]] || return 0
  mode="$(jq -r '.mode // "off"' "$config")"
  [[ "$mode" != off ]] || return 0
  case "$mode" in
    syslog)
      host="$(jq -r '.host' "$config")"; port="$(jq -r '.port' "$config")"; protocol="$(jq -r '.protocol' "$config")"
      [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$port" =~ ^[0-9]{1,5}$ ]] || return 1
      # RFC 5424 envelope, JSON event in the message section.
      case "$protocol" in
        udp) printf '<134>1 %s %s LiteEdge - - - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$event" | socat -u - "UDP:$host:$port" ;;
        tcp) printf '<134>1 %s %s LiteEdge - - - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$event" | socat -u - "TCP:$host:$port,connect-timeout=3" ;;
        tls) printf '<134>1 %s %s LiteEdge - - - %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$event" | socat -u - "OPENSSL:$host:$port,verify=1,connect-timeout=3" ;;
        *) return 1 ;;
      esac ;;
    https)
      provider="$(jq -r '.provider // "generic"' "$config")"
      url="$(jq -r '.url' "$config")"; token="$(jq -r '.token // ""' "$config")"
      send_http "$url" "$event" "$token" "$provider" ;;
    *) return 1 ;;
  esac
}

notify_alert() {
  local alert="$1" count="$2" event="$3" collector="$OBS_DIR/collector.json" channel target payload user password smtp_host smtp_port mail_from mail
  channel="$(jq -r '.channel' <<< "$alert")"; target="$(jq -r '.target' <<< "$alert")"
  payload="$(jq -nc --argjson rule "$alert" --argjson sample "$event" --argjson count "$count" '{event:"liteedge.alert",alert_id:$rule.id,name:$rule.name,count:$count,window_seconds:$rule.window,observed_at:(now|todateiso8601),sample:$sample}')"
  if [[ "$channel" == webhook ]]; then send_http "$target" "$payload"; return; fi
  [[ "$channel" == email && -f "$collector" ]] || return 1
  smtp_host="$(jq -r '.smtp_host // ""' "$collector")"
  smtp_port="$(jq -r '.smtp_port // 587' "$collector")"
  user="$(jq -r '.smtp_user // ""' "$collector")"
  password="$(jq -r '.smtp_password // ""' "$collector")"
  mail_from="$(jq -r '.mail_from // ""' "$collector")"
  [[ -n "$smtp_host" && -n "$mail_from" ]] || return 1
  mail="$(mktemp "$OBS_DIR/.mail.XXXXXX")"
  { printf 'From: %s\r\nTo: %s\r\nSubject: [LiteEdge] %s\r\nContent-Type: application/json; charset=utf-8\r\n\r\n' "$mail_from" "$target" "$(jq -r '.name' <<< "$alert" | tr -d '\r\n')"; printf '%s\r\n' "$payload"; } > "$mail"
  local -a args=(--fail --silent --show-error --connect-timeout 3 --max-time 20 --ssl-reqd --url "smtp://$smtp_host:$smtp_port" --mail-from "$mail_from" --mail-rcpt "$target" --upload-file "$mail")
  [[ -z "$user" ]] || args+=(--user "$user:$password")
  local result=0
  curl "${args[@]}" >/dev/null || result=$?
  rm -f "$mail"
  return "$result"
}

alert_matches() {
  local event="$1" rule="$2"
  jq -en --argjson e "$event" --argjson r "$rule" '
    ($r.type=="all" or $e.type==$r.type)
    and ($r.host=="" or $r.host==$e.host)
    and ($r.route=="" or $r.route==$e.route)
    and ($r.method=="" or $r.method==$e.method)
    and ($r.status=="" or (if ($r.status|endswith("xx")) then (($e.status|tostring)|startswith($r.status[0:1])) else ($e.status|tostring)==$r.status end))
    and ($r.action=="any" or $e.action==$r.action)
    and ($r.search=="" or (($e|tostring|ascii_downcase)|contains($r.search|ascii_downcase)))
  ' >/dev/null
}

process_alerts() {
  local batch="$1" rule id now last count first threshold window cooldown sampled
  [[ -s "$batch" && -f "$OBS_DIR/alerts.json" ]] || return 0
  now="$(date +%s)"
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    id="$(jq -r '.id' <<< "$rule")"
    window="$(jq -r '.window' <<< "$rule")"; cooldown="$(jq -r '.cooldown' <<< "$rule")"; threshold="$(jq -r '.threshold' <<< "$rule")"
    first=""
    while IFS= read -r sampled; do
      if alert_matches "$sampled" "$rule"; then first="$sampled"; break; fi
    done < "$batch"
    [[ -n "$first" ]] || continue
    last=0
    [[ -f "$OBS_DIR/alert-$id.last" ]] && read -r last < "$OBS_DIR/alert-$id.last" || true
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= cooldown )) || continue
    count="$(tail -n 10000 "$EVENTS_FILE" | jq -c --argjson since "$((now-window))" 'select(((.epoch // 0)|tonumber) >= $since)' | jq -sc --argjson r "$rule" '[.[] | select(($r.type=="all" or .type==$r.type) and ($r.host=="" or .host==$r.host) and ($r.route=="" or .route==$r.route) and ($r.method=="" or .method==$r.method) and ($r.status=="" or (if ($r.status|endswith("xx")) then ((.status|tostring)|startswith($r.status[0:1])) else (.status|tostring)==$r.status end)) and ($r.action=="any" or .action==$r.action) and ($r.search=="" or ((.|tostring|ascii_downcase)|contains($r.search|ascii_downcase))))] | length')"
    if (( count >= threshold )); then
      if notify_alert "$rule" "$count" "$first"; then
        printf '%s\n' "$now" > "$OBS_DIR/alert-$id.last"
      else
        printf 'LiteEdge alert delivery failed for %s\n' "$id" >&2
      fi
    fi
  done < <(jq -c '.[] | select(.enabled == true)' "$OBS_DIR/alerts.json")
}

process_events() {
  local cursor="$OBS_DIR/events.offset" chunk="$OBS_DIR/.events-chunk" line
  read_new_lines "$EVENTS_FILE" "$cursor" "$chunk"
  [[ -s "$chunk" ]] || { mv -f "$cursor.next" "$cursor"; return 0; }
  # A failed collector does not lose events: cursor only advances on success.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    jq -e . <<< "$line" >/dev/null || continue
    if ! forward_event "$line"; then echo 'Collector delivery failed; retrying next cycle.' >&2; return 1; fi
  done < "$chunk"
  process_alerts "$chunk"
  mv -f "$cursor.next" "$cursor"
}

rotate_logs() {
  [[ -f /opt/liteedge/etc/logrotate-observability.conf ]] || return 0
  logrotate -s "$OBS_DIR/logrotate.status" /opt/liteedge/etc/logrotate-observability.conf || true
}

tick() {
  normalize_audit
  process_events
}
case "${1:-run}" in
  tick) tick ;;
  run)
    last_rotate=0
    while :; do
      tick || true
      now="$(date +%s)"
      if (( now - last_rotate >= 3600 )); then rotate_logs; last_rotate="$now"; fi
      sleep "${LITEEDGE_OBS_INTERVAL:-5}"
    done ;;
  *) echo 'Usage: obs-worker.sh tick|run' >&2; exit 2 ;;
esac
