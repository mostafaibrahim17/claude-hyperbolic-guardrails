#!/usr/bin/env bash
# reaper.sh — backstop for the timer. Run it from cron every few minutes.
# Terminates any live rental that started more than MAX_MINUTES ago.
set -uo pipefail
MAX_MINUTES="${HYPERBOLIC_MAX_MINUTES:-30}"
BASE="https://api.hyperbolic.xyz/v2/on-demand/virtual-machine-rentals"
[[ -n "${HYPERBOLIC_API_TOKEN:-}" ]] || { echo "HYPERBOLIC_API_TOKEN is not set" >&2; exit 1; }
now=$(date -u +%s)
curl -sf --max-time 15 -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" "$BASE" \
| jq -r '.[] | select(.status=="Running" or .status=="Pending") | "\(.id) \(.startedAt // .createdAt)"' \
| while read -r id started; do
    t=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "${started:0:19}" +%s 2>/dev/null || date -u -d "${started:0:19}" +%s)
    if (( now - t > MAX_MINUTES*60 )); then
      code=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" \
             -H "Content-Type: application/json" -d "{\"rentalId\":$id,\"reason\":\"reaper\"}" "$BASE/terminate")
      echo "$(date -u +%FT%TZ) reaper terminated $id (started $started) HTTP $code"
    fi
  done
