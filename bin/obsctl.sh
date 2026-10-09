#!/usr/bin/env bash
# Structured log querying and secure observability configuration for LiteEdge.
set -euo pipefail
# shellcheck disable=SC1091,SC2015
source /opt/liteedge/bin/common.sh
umask 077
OBS_DIR="${OBS_DIR:-$DATA_DIR/observability}"
EVENTS_FILE="${EVENTS_FILE:-$DATA_DIR/logs/events.jsonl}"
mkdir -p "$OBS_DIR" "$DATA_DIR/logs"
COLLECTOR="$OBS_DIR/collector.json"
ALERTS="$OBS_DIR/alerts.json"
[[ -f "$ALERTS" ]] || printf '[]\n' > "$ALERTS"
[[ -f "$COLLECTOR" ]] || printf '{}\n' > "$COLLECTOR"

atomic_file() {
  local target="$1" tmp
  tmp="$(mktemp "$OBS_DIR/.write.XXXXXXXX")"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
}
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] && [[ "$1" != *..* ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_email() { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
valid_https() { [[ "$1" =~ ^https://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?%+-]*)?$ ]] && [[ "$1" != *..* ]]; }

# Each JSON document is checked by jq. No shell evaluation of user-defined filters.
query() {
  local kind="${1:-all}" host="${2:-}" route="${3:-}" port="${4:-}" method="${5:-}" status="${6:-}" search="${7:-}" limit="${8:-100}" since="${9:-0}"
  [[ "$kind" == all || "$kind" == http || "$kind" == waf ]] || die 'Invalid event type.'
  if ! { [[ "$limit" =~ ^[0-9]{1,4}$ ]] && (( 10#$limit >= 1 && 10#$limit <= 1000 )); }; then die 'Limit must be 1-1000.'; fi
  [[ "$since" =~ ^[0-9]{1,15}$ ]] || die 'Since must be a Unix timestamp.'
  [[ -z "$status" || "$status" =~ ^[1-5][0-9]{2}$ || "$status" =~ ^[1-5]xx$ ]] || die 'Invalid status filter.'
  [[ -z "$port" || "$port" =~ ^[0-9]{1,5}$ ]] || die 'Invalid port filter.'
  [[ -z "$method" || "$method" =~ ^[A-Z]{1,12}$ ]] || die 'Invalid method filter.'
  [[ -z "$EVENTS_FILE" || -f "$EVENTS_FILE" ]] || return 0
  local -a sources=()
  local i
  for i in 7 6 5 4 3 2 1; do
    [[ -f "$EVENTS_FILE.$i.gz" ]] && sources+=("$EVENTS_FILE.$i.gz")
    [[ -f "$EVENTS_FILE.$i" ]] && sources+=("$EVENTS_FILE.$i")
  done
  sources+=("$EVENTS_FILE")
  { for i in "${sources[@]}"; do
      if [[ "$i" == *.gz ]]; then gzip -cd "$i"; else cat "$i"; fi
    done; } | jq -c --arg kind "$kind" --arg host "$host" --arg route "$route" --arg port "$port" --arg method "$method" --arg status "$status" --arg search "$search" --argjson since "$since" '
    select(type=="object")
    | select($kind == "all" or .type == $kind)
    | select($host == "" or (.host // "") == $host)
    | select($route == "" or (.route // "") == $route)
    | select($port == "" or ((.port // "") | tostring) == $port or ((.listen_port // "") | tostring) == $port or ((.upstream_addr // "" | tostring | split(":") | last) == $port))
    | select($method == "" or (.method // "") == $method)
    | select($status == "" or (if ($status | endswith("xx")) then ((.status // 0) | tostring | startswith($status[0:1])) else ((.status // "") | tostring) == $status end))
    | select((.epoch // 0 | tonumber) >= $since)
    | select($search == "" or (([.host, .route, .method, .uri, .ip, .rule_id, .message, .action, .request_id] | map(. // "" | tostring) | join(" ")) | ascii_downcase | contains($search | ascii_downcase)))
  ' | tail -n "$limit"
}

save_collector() {
  local mode="${1:-off}" host="${2:-}" port="${3:-514}" protocol="${4:-udp}" provider="${5:-generic}" url="${6:-}" token="${7:-}" smtp_host="${8:-}" smtp_port="${9:-587}" smtp_user="${10:-}" smtp_password="${11:-}" mail_from="${12:-}"
  [[ "$mode" == off || "$mode" == syslog || "$mode" == https ]] || die 'Unsupported collector mode.'
  [[ "$protocol" == udp || "$protocol" == tcp || "$protocol" == tls ]] || die 'Unsupported syslog transport.'
  [[ "$provider" == generic || "$provider" == splunk || "$provider" == datadog || "$provider" == elastic ]] || die 'Unsupported HTTP collector.'
  if [[ "$mode" == syslog ]]; then
    if ! { valid_host "$host" && valid_port "$port"; }; then die 'Invalid syslog host or port.'; fi
  fi
  if [[ "$mode" == https ]]; then valid_https "$url" || die 'Collector must be an HTTPS URL.'; fi
  if [[ -n "$smtp_host" ]]; then
    if ! { valid_host "$smtp_host" && valid_port "$smtp_port"; }; then die 'Invalid SMTP host or port.'; fi
  fi
  if [[ -n "$mail_from" ]]; then valid_email "$mail_from" || die 'Invalid sender address.'; fi
  [[ -z "$smtp_user" || -n "$smtp_host" ]] || die 'SMTP username requires SMTP host.'
  # Leaving passwords blank retains previously stored values. Never echo them into the page.
  jq -n --argjson previous "$(cat "$COLLECTOR")" \
    --arg mode "$mode" --arg host "$host" --arg port "$port" --arg protocol "$protocol" --arg provider "$provider" --arg url "$url" --arg token "$token" --arg smtp_host "$smtp_host" --arg smtp_port "$smtp_port" --arg smtp_user "$smtp_user" --arg smtp_password "$smtp_password" --arg mail_from "$mail_from" '
    {mode:$mode, host:$host,port:($port|tonumber),protocol:$protocol,provider:$provider,url:$url,
      token:(if $token=="" then ($previous.token // "") else $token end),
      smtp_host:$smtp_host,smtp_port:($smtp_port|tonumber),smtp_user:$smtp_user,
      smtp_password:(if $smtp_password=="" then ($previous.smtp_password // "") else $smtp_password end),
      mail_from:$mail_from}' | atomic_file "$COLLECTOR"
}

add_alert() {
  local id="${1:-}" name="${2:-}" type="${3:-}" host="${4:-}" route="${5:-}" method="${6:-}" status="${7:-}" action="${8:-}" threshold="${9:-1}" window="${10:-60}" cooldown="${11:-300}" channel="${12:-webhook}" target="${13:-}" search="${14:-}" scopes_json="${15:-}"
  [[ "$id" =~ ^[A-Za-z0-9_-]{1,48}$ && ${#name} -le 100 && -n "$name" ]] || die 'Invalid alert ID or name.'
  [[ "$type" == all || "$type" == waf || "$type" == http ]] || die 'Invalid event type.'
  [[ "$action" == any || "$action" == blocked || "$action" == matched ]] || die 'Invalid WAF action.'
  [[ "$channel" == webhook || "$channel" == email ]] || die 'Invalid alert delivery channel.'
  if [[ "$channel" == webhook ]]; then valid_https "$target" || die 'Webhook must use HTTPS.'; else valid_email "$target" || die 'Invalid recipient.'; fi
  if ! { [[ "$threshold" =~ ^[0-9]{1,5}$ ]] && (( 10#$threshold >= 1 && 10#$threshold <= 10000 )); }; then die 'Invalid event threshold.'; fi
  if ! { [[ "$window" =~ ^[0-9]{1,5}$ ]] && (( 10#$window >= 10 && 10#$window <= 86400 )); }; then die 'Invalid window.'; fi
  if ! { [[ "$cooldown" =~ ^[0-9]{1,6}$ ]] && (( 10#$cooldown >= 10 && 10#$cooldown <= 604800 )); }; then die 'Invalid cooldown.'; fi
  [[ -z "$status" || "$status" =~ ^[1-5][0-9]{2}$ || "$status" =~ ^[1-5]xx$ ]] || die 'Invalid status.'
  [[ -z "$method" || "$method" =~ ^[A-Z]{1,12}$ ]] || die 'Invalid method.'
  # New rules use typed, inventory-validated per-host route scopes; old scalar
  # host/route definitions continue to work unchanged for existing alert rules.
  if [[ -n "$scopes_json" ]]; then
    [[ ${#scopes_json} -le 16384 ]] || die 'Too many host/route selections.'
    local catalog
    catalog="$(/opt/liteedge/bin/alert-catalog.sh)"
    if ! jq -en --argjson scopes "$scopes_json" --argjson catalog "$catalog" '
       ($scopes | type == "array" and length <= 100 and
         all(.[]; type == "object" and ((.host // null)|type)=="string" and
           ((.site // null)|type)=="string" and ((.routes // null)|type)=="array" and
           (.routes|length)<=200 and all(.routes[]; type=="string")))
       and all($scopes[]; . as $scope |
         any($catalog.hosts[]; .name==$scope.host and .site==$scope.site) and
         all($scope.routes[]; . as $route |
           any($catalog.routes[]; .site==$scope.site and .route==$route)))
       ' >/dev/null; then
      die 'Selected hosts, aliases, or routes are not valid for the current sites.'
    fi
  fi
  jq -n --arg id "$id" --arg name "$name" --arg type "$type" --arg host "$host" --arg route "$route" --arg method "$method" --arg status "$status" --arg action "$action" --argjson threshold "$threshold" --argjson window "$window" --argjson cooldown "$cooldown" --arg channel "$channel" --arg target "$target" --arg search "$search" --arg scopes "${scopes_json:-}"     '{id:$id,name:$name,type:$type,host:(if $scopes=="" then $host else "" end),route:(if $scopes=="" then $route else "" end),
      scopes:(if $scopes=="" then null else ($scopes|fromjson) end),
      routes_limited:(if $scopes=="" then false else ([($scopes|fromjson)[] | .routes[]]|length)>0 end),
      method:$method,status:$status,action:$action,threshold:$threshold,window:$window,cooldown:$cooldown,channel:$channel,target:$target,search:$search,enabled:true}' > "$OBS_DIR/.alert-new.json"
  jq --slurpfile rule "$OBS_DIR/.alert-new.json" 'map(select(.id != $rule[0].id)) + $rule' "$ALERTS" | atomic_file "$ALERTS"
  rm -f "$OBS_DIR/.alert-new.json"
}

case "${1:-}" in
  query) shift; query "$@" ;;
  collector) jq 'del(.token,.smtp_password)' "$COLLECTOR" ;;
  collector-save) shift; save_collector "$@" ;;
  alerts) cat "$ALERTS" ;;
  alert-save) shift; add_alert "$@" ;;
  alert-delete)
    [[ "${2:-}" =~ ^[A-Za-z0-9_-]{1,48}$ ]] || die 'Invalid alert ID.'
    jq --arg id "$2" 'map(select(.id != $id))' "$ALERTS" | atomic_file "$ALERTS" ;;
  *) echo 'Usage: obsctl.sh query|collector|collector-save|alerts|alert-save|alert-delete' >&2; exit 2 ;;
esac
