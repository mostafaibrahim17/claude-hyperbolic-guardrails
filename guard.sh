#!/usr/bin/env bash
# guard.sh — PreToolUse hook. Blocks rent-gpu-instance when it would pass the
# daily cap, the live-rental limit, or the account balance. Prices the rent
# from Hyperbolic's live rental options. Fails closed: any error blocks.
set -uo pipefail

BUDGET_USD="${HYPERBOLIC_BUDGET_USD:-10}"      # daily cap, UTC day
MAX_MINUTES="${HYPERBOLIC_MAX_MINUTES:-30}"    # auto-terminate window
MAX_LIVE="${HYPERBOLIC_MAX_LIVE:-1}"           # live rentals allowed at once
LEDGER="${HYPERBOLIC_LEDGER:-$HOME/hyperbolic-guardrails/ledger.jsonl}"
API="https://api.hyperbolic.xyz/v2"

die() { echo "BLOCKED: $*" >&2; exit 2; }
get() { curl -sf --max-time 10 -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" "$API$1"; }

input=$(cat) || die "could not read hook input"
tool=$(jq -r '.tool_name' <<<"$input") || die "jq failed on hook input"
[[ "$tool" == "mcp__hyperbolic-gpu__rent-gpu-instance" ]] || exit 0
[[ -n "${HYPERBOLIC_API_TOKEN:-}" ]] || die "HYPERBOLIC_API_TOKEN is not set"
[[ "$MAX_MINUTES" =~ ^[0-9]+$ && "$MAX_LIVE" =~ ^[0-9]+$ && "$BUDGET_USD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "MAX_MINUTES, MAX_LIVE and BUDGET_USD must be numbers"

gpus=$(jq -r '.tool_input.gpu_count // empty' <<<"$input")
gpu=$(jq -r '.tool_input.gpu_type // empty' <<<"$input")
region=$(jq -r '.tool_input.region // empty' <<<"$input")
[[ "$gpus" =~ ^[1-9][0-9]*$ && -n "$gpu" && -n "$region" ]] || die "rent request is missing gpu_type, region or a positive gpu_count"

# Real price of this exact option, from the live catalogue. No option, no rent.
cents=$(get /on-demand/rental-options | jq -r --arg g "$gpu" --arg r "$region" --argjson n "$gpus" \
  '[.[] | select(.enabled and .machineType=="virtual-machine" and .gpuType==$g and .region==$r and .gpuCount==$n)] | first | .costPerHourCents // empty') \
  || die "could not fetch rental options"
[[ "$cents" =~ ^[0-9]+$ ]] || die "no live option for ${gpus}x ${gpu} in ${region}"
est=$(awk -v c="$cents" -v m="$MAX_MINUTES" 'BEGIN{printf "%.2f", c/100*m/60}')

# Live rentals right now
live=$(get /on-demand/virtual-machine-rentals | jq '[.[] | select(.status=="Pending" or .status=="Running")] | length') \
  || die "could not list live rentals"
[[ "$live" =~ ^[0-9]+$ ]] || die "could not count live rentals"
(( live < MAX_LIVE )) || die "$live rental(s) already live, limit is $MAX_LIVE"

# What today has already committed (rows dated today, UTC)
today=$(date -u +%F); spent=0
if [[ -f "$LEDGER" ]]; then
  spent=$(jq -s --arg d "$today" '[.[] | select((.rented_at // "") | startswith($d)) | (.est_usd // error("ledger row without est_usd"))] | add // 0' "$LEDGER") \
    || die "ledger unreadable or malformed at $LEDGER"
fi
total=$(awk -v s="$spent" -v e="$est" 'BEGIN{printf "%.2f", s+e}')
awk -v t="$total" -v b="$BUDGET_USD" 'BEGIN{exit !(t>b)}' \
  && die "renting ${gpus}x ${gpu} in ${region} for up to ${MAX_MINUTES} min is ~\$${est}. Today's total would be \$${total}, cap is \$${BUDGET_USD}."

# Account balance. Hyperbolic allows no overdraft, so this is the hard ceiling.
bal=$(get /customer/balance | jq -r '.balanceCents') || die "balance check failed"
[[ "$bal" =~ ^[0-9]+$ ]] || die "balance check returned no number"
balance=$(awk -v c="$bal" 'BEGIN{printf "%.2f", c/100}')
awk -v e="$est" -v b="$balance" 'BEGIN{exit !(e>b)}' && die "account balance is \$${balance}, this rent needs ~\$${est}."

echo "budget ok: \$$(awk -v c="$cents" 'BEGIN{printf "%.2f", c/100}')/hr, est \$${est}, today \$${total}/\$${BUDGET_USD}, balance \$${balance}, live ${live}/${MAX_LIVE}" >&2
exit 0
