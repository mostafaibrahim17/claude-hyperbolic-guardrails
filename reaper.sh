#!/usr/bin/env bash
# reaper.sh — backstop for the timer. Run it from cron every few minutes.
# Terminates any live rental whose start time is more than MAX_MINUTES ago.
# Fails safe: a rental whose start time cannot be parsed is left alone.
set -uo pipefail
MAX_MINUTES="${HYPERBOLIC_MAX_MINUTES:-30}"
BASE="https://api.hyperbolic.xyz/v2/on-demand/virtual-machine-rentals"
[[ -n "${HYPERBOLIC_API_TOKEN:-}" ]] || { echo "HYPERBOLIC_API_TOKEN is not set" >&2; exit 1; }
[[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] || { echo "HYPERBOLIC_MAX_MINUTES must be an integer" >&2; exit 1; }

# Age is computed inside jq from the API's timestamp ("2026-09-12 13:59:00.123+00"),
# so it behaves the same on macOS and Linux. Unparseable timestamps are skipped.
curl -sf --max-time 15 -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" "$BASE" \
| jq -r --argjson max "$((MAX_MINUTES*60))" '
    .[] | select(.status=="Running" or .status=="Pending")
    | . as $r
    | ((.startedAt // .createdAt // "") | sub(" ";"T") | sub("\\.[0-9]+";"") | sub("\\+00(:00)?$";"Z")) as $ts
    | try ($ts | fromdate) catch null
    | select(. != null and . < (now - $max))
    | "\($r.id) \($r.startedAt // $r.createdAt)"' \
| while read -r id started; do
    code=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" \
           -H "Content-Type: application/json" -d "{\"rentalId\":$id,\"reason\":\"reaper\"}" "$BASE/terminate")
    echo "$(date -u +%FT%TZ) reaper terminated $id (started $started) HTTP $code"
  done
