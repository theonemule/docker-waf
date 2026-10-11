#!/usr/bin/env bash
# Optional active HTTP backend probes. Changes publish transition events;
# NGINX itself retains passive balancing/failover decisions.
set -euo pipefail
# shellcheck disable=SC1091,SC2153
source /opt/liteedge/bin/common.sh
# shellcheck disable=SC1091
source /opt/liteedge/bin/poolctl.sh
umask 077
STATE_DIR="${OBS_DIR:-$DATA_DIR/observability}/health"
EVENTS_FILE="${EVENTS_FILE:-$DATA_DIR/logs/events.jsonl}"
mkdir -p "$STATE_DIR"

probe_one() {
  local host="$1" route="$2" endpoint="$3" now="$4"
  local path interval timeout fall rise cooldown expect route_name origin code ok=0 next successes failures status last_down state key tmp action message
  path="$(kv_get "$route" HEALTH_PATH)"; path="${path:-/health}"
  interval="$(kv_get "$route" HEALTH_INTERVAL)"; interval="${interval:-30}"
  timeout="$(kv_get "$route" HEALTH_TIMEOUT)"; timeout="${timeout:-5}"
  fall="$(kv_get "$route" HEALTH_FALL)"; fall="${fall:-3}"
  rise="$(kv_get "$route" HEALTH_RISE)"; rise="${rise:-2}"
  cooldown="$(kv_get "$route" HEALTH_COOLDOWN)"; cooldown="${cooldown:-300}"
  expect="$(kv_get "$route" HEALTH_EXPECT)"; expect="${expect:-200}"
  [[ "$interval" =~ ^[0-9]+$ && "$timeout" =~ ^[0-9]+$ && "$fall" =~ ^[0-9]+$ && "$rise" =~ ^[0-9]+$ && "$cooldown" =~ ^[0-9]+$ ]] || return 0
  [[ "$path" == /* && "$path" != *[[:space:]]* && "$path" != *'?'* && "$path" != *'#'* ]] || return 0
  # HTTP/S origin only; URL credentials and arbitrary schemes never enter logs.
  [[ "$endpoint" =~ ^(https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?)(/.*)?$ ]] || return 0
  origin="${BASH_REMATCH[1]}"
  route_name="$(kv_get "$route" MATCH):$(kv_get "$route" PATH)"
  # Do not publish opaque authorization tokens embedded in imported route paths.
  [[ "$route_name" =~ [[:xdigit:]]{24,} ]] && route_name="[redacted]"
  key="$(printf '%s|%s|%s' "$host" "$(kv_get "$route" ID)" "$endpoint" | sha256sum | cut -c1-32)"
  state="$STATE_DIR/$key.json"
  next=0; successes=0; failures=0; status=up; last_down=0
  if [[ -s "$state" ]]; then
    next="$(jq -r '.next // 0' "$state")"
    successes="$(jq -r '.successes // 0' "$state")"
    failures="$(jq -r '.failures // 0' "$state")"
    status="$(jq -r '.state // "up"' "$state")"
    last_down="$(jq -r '.last_down // 0' "$state")"
  fi
  [[ "$next" =~ ^[0-9]+$ ]] || next=0
  (( now >= next )) || return 0
  code="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout "$timeout" --max-time "$timeout" --max-redirs 0 "$origin$path" 2>/dev/null)" || code=000
  if [[ "$expect" == *xx ]]; then
    [[ "$code" == "${expect:0:1}"?? ]] && ok=1
  else
    [[ "$code" == "$expect" ]] && ok=1
  fi
  action=''
  if (( ok )); then
    successes=$((successes+1)); failures=0
    if [[ "$status" == down && "$successes" -ge "$rise" ]]; then status=up; action=up; fi
  else
    failures=$((failures+1)); successes=0
    if [[ "$status" == up && "$failures" -ge "$fall" ]]; then
      status=down
      if (( now-last_down >= cooldown )); then action=down; last_down="$now"; fi
    fi
  fi
  tmp="$(mktemp "$STATE_DIR/.health.XXXXXXXX")"
  jq -nc --arg state "$status" --argjson next "$((now+interval))" --argjson successes "$successes" --argjson failures "$failures" --argjson last_down "$last_down"     '{state:$state,next:$next,successes:$successes,failures:$failures,last_down:$last_down}' > "$tmp"
  mv -f "$tmp" "$state"
  if [[ -n "$action" ]]; then
    if [[ "$action" == down ]]; then message='Backend health check failed'; else message='Backend health recovered'; fi
    jq -nc --arg type health --arg host "$host" --arg route "$route_name" --arg uri "$path" --arg action "$action" --arg message "$message"       --arg result "$code" --argjson epoch "$now" --arg backend "$origin"       '{type:$type,host:$host,route:$route,uri:$uri,action:$action,message:$message,probe_status:$result,
        status:(if $action=="down" then 503 else 200 end),port:"443",method:"GET",upstream_addr:$backend,
        epoch:$epoch,timestamp:($epoch|todateiso8601),ip:""}' >> "$EVENTS_FILE"
  fi
}

tick() {
  local now site host route endpoint
  now="$(date +%s)"
  shopt -s nullglob
  # SITE_DIR is initialized by common.sh.
  # shellcheck disable=SC2153
  for site in "$SITE_DIR"/*.site; do
    [[ -f "$site" ]] || continue
    [[ "$(kv_get "$site" ENABLED)" != 0 ]] || continue
    host="$(kv_get "$site" HOST)"
    for route in "$(route_dir "$host")"/*.route; do
      [[ "$(kv_get "$route" HEALTH_ENABLED)" == 1 ]] || continue
      while IFS= read -r endpoint; do
        [[ -n "$endpoint" ]] || continue
        probe_one "$host" "$route" "$endpoint" "$now"
      done < <(pool_urls "$route")
    done
  done
}
case "${1:-run}" in
  tick) tick ;;
  run) while :; do tick || true; sleep "${LITEEDGE_HEALTH_POLL_SECONDS:-5}"; done ;;
  *) echo 'Usage: health-worker.sh tick|run' >&2; exit 2 ;;
esac
