#!/usr/bin/env bash
# autoterminate.sh — PostToolUse hook. Starts a kill timer after a rent and
# cancels it after a manual terminate. The API key is read from the timer's
# environment, never placed on a command line.
set -uo pipefail

MAX_MINUTES="${HYPERBOLIC_MAX_MINUTES:-30}"
LEDGER="${HYPERBOLIC_LEDGER:-$HOME/hyperbolic-guardrails/ledger.jsonl}"
BASE="https://api.hyperbolic.xyz/v2/on-demand/virtual-machine-rentals"
[[ "$MAX_MINUTES" =~ ^[0-9]+$ ]] || { echo "AUTO-TERMINATE NOT ARMED: HYPERBOLIC_MAX_MINUTES must be an integer" >&2; exit 2; }

input=$(cat)
tool=$(jq -r '.tool_name' <<<"$input")
resp=$(jq -r '.tool_response
  | if type=="array" then .[0].text
    elif (.content? // null) != null then .content[0].text
    else (.text // tostring) end' <<<"$input")

case "$tool" in
  mcp__hyperbolic-gpu__rent-gpu-instance)
    [[ -n "${HYPERBOLIC_API_TOKEN:-}" ]] || { echo "AUTO-TERMINATE NOT ARMED: HYPERBOLIC_API_TOKEN is not set" >&2; exit 2; }
    # Prefer the id in the tool response. If the call was backgrounded or
    # timed out, fall back to the newest live rental on the account.
    id=$(grep -oE 'rental_id\\?"?\s*:\s*[0-9]+' <<<"$resp" | head -1 | grep -oE '[0-9]+$' || true)
    if [[ -z "$id" ]] && grep -qiE '"status": *"error"|^Error|hook error|not found' <<<"$resp"; then
      echo "rent call failed, no timer needed" >&2; exit 0
    fi
    if [[ -z "$id" ]]; then
      id=$(curl -sf --max-time 10 -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" "$BASE" \
        | jq -r '[.[] | select(.status=="Pending" or .status=="Running")] | max_by(.id) | .id // empty')
      [[ -n "$id" ]] && echo "rental id not in response, using newest live rental $id" >&2
    fi
    # Loud failure: exit 2 makes Claude Code show this to the model and the user.
    [[ -n "$id" ]] || { echo "AUTO-TERMINATE NOT ARMED: no rental id in response and no live rental found. Check list-user-instances and terminate by hand." >&2; exit 2; }
    # Estimated cost for the ledger: the live catalogue price of the option that was requested.
    g=$(jq -r '.tool_input.gpu_type // empty' <<<"$input"); r=$(jq -r '.tool_input.region // empty' <<<"$input"); n=$(jq -r '.tool_input.gpu_count // 1' <<<"$input")
    cents=$(curl -sf --max-time 10 -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" "https://api.hyperbolic.xyz/v2/on-demand/rental-options" \
      | jq -r --arg g "$g" --arg r "$r" --argjson n "$n" '[.[] | select(.gpuType==$g and .region==$r and .gpuCount==$n)] | first | .costPerHourCents // empty')
    [[ "$cents" =~ ^[0-9]+$ ]] || cents=500   # option no longer listed: assume $5/hr, on the high side
    est=$(awk -v c="$cents" -v m="$MAX_MINUTES" 'BEGIN{printf "%.2f", c/100*m/60}')

    # The timer reads HYPERBOLIC_API_TOKEN from its own environment ($1..$4 are not secrets).
    export HYPERBOLIC_API_TOKEN
    nohup bash -c '
      sleep "$1"
      for attempt in 1 2 3; do
        code=$(curl -s --max-time 20 -o "$4.last" -w "%{http_code}" -X POST -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" -H "Content-Type: application/json" \
              -d "{\"rentalId\":$2,\"reason\":\"auto-terminate\"}" "$3/terminate")
        cat "$4.last" >> "$4"; echo " HTTP $code" >> "$4"
        if [[ "$code" == "200" ]]; then echo "$(date -u +%FT%TZ) auto-terminated $2" >> "$4"; exit 0; fi
        sleep 30
      done
      echo "$(date -u +%FT%TZ) AUTO-TERMINATE FAILED for $2 after 3 attempts, terminate it by hand" >> "$4"
      command -v osascript >/dev/null && osascript -e "display notification \"Rental $2 is still running. Terminate it by hand.\" with title \"Hyperbolic auto-terminate FAILED\"" 2>/dev/null
      command -v notify-send >/dev/null && notify-send "Hyperbolic auto-terminate FAILED" "Rental $2 is still running. Terminate it by hand." 2>/dev/null
    ' _ "$((MAX_MINUTES*60))" "$id" "$BASE" "$LEDGER.log" >/dev/null 2>&1 &
    pid=$!; disown "$pid" 2>/dev/null || true

    jq -cn --arg id "$id" --arg pid "$pid" --arg est "$est" --arg t "$(date -u +%FT%TZ)" \
      '{rental_id:($id|tonumber), timer_pid:($pid|tonumber), est_usd:($est|tonumber), rented_at:$t}' >> "$LEDGER"
    echo "auto-terminate armed: $id in ${MAX_MINUTES} min (timer pid $pid)" >&2
    ;;

  mcp__hyperbolic-gpu__terminate-gpu-instance)
    id=$(jq -r '.tool_input.rental_id' <<<"$input")
    pid=$(jq -r --arg id "$id" 'select((.rental_id|tostring)==$id) | .timer_pid' "$LEDGER" 2>/dev/null | tail -1)
    # Only kill it if that PID is still our timer for this rental, not a reused PID.
    if [[ "$pid" =~ ^[0-9]+$ ]] && ps -o command= -p "$pid" 2>/dev/null | tr '\n' ' ' | grep -q -- "auto-terminate.* $id "; then
      kill "$pid" 2>/dev/null && echo "timer $pid cancelled for $id" >&2
    fi
    ;;
esac
exit 0
