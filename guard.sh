#!/usr/bin/env bash
# guard.sh — PreToolUse hook. Blocks rent-gpu-instance when it would pass the
# daily cap or the account balance. Fails closed: any error blocks the call.
set -uo pipefail

BUDGET_USD="${HYPERBOLIC_BUDGET_USD:-10}"        # daily cap, UTC day
MAX_RATE_USD="${HYPERBOLIC_MAX_RATE_USD:-5.00}"  # worst-case $/GPU/hour
MAX_MINUTES="${HYPERBOLIC_MAX_MINUTES:-30}"      # auto-terminate window
LEDGER="${HYPERBOLIC_LEDGER:-$HOME/hyperbolic-guardrails/ledger.jsonl}"

die() { echo "BLOCKED: $*" >&2; exit 2; }

input=$(cat) || die "could not read hook input"
tool=$(jq -r '.tool_name' <<<"$input") || die "jq failed on hook input"
[[ "$tool" == "mcp__hyperbolic-gpu__rent-gpu-instance" ]] || exit 0
[[ -n "${HYPERBOLIC_API_TOKEN:-}" ]] || die "HYPERBOLIC_API_TOKEN is not set"

gpus=$(jq -r '.tool_input.gpu_count // 1' <<<"$input")
gpu=$(jq -r '.tool_input.gpu_type // "gpu"' <<<"$input")
region=$(jq -r '.tool_input.region // "?"' <<<"$input")

# Worst-case cost of this rent
est=$(awk -v r="$MAX_RATE_USD" -v g="$gpus" -v m="$MAX_MINUTES" 'BEGIN{printf "%.2f", r*g*m/60}')

# What today has already committed (rows dated today, UTC)
today=$(date -u +%F)
spent=0
if [[ -f "$LEDGER" ]]; then
  spent=$(jq -s --arg d "$today" '[.[] | select((.rented_at // "") | startswith($d)) | .est_usd] | add // 0' "$LEDGER") \
    || die "ledger unreadable at $LEDGER"
fi
total=$(awk -v s="$spent" -v e="$est" 'BEGIN{printf "%.2f", s+e}')

if awk -v t="$total" -v b="$BUDGET_USD" 'BEGIN{exit !(t>b)}'; then
  die "renting ${gpus}x ${gpu} in ${region} for up to ${MAX_MINUTES} min is ~\$${est}. Today's total would be \$${total}, cap is \$${BUDGET_USD}."
fi

# Live balance check (the API returns cents). A failed check blocks.
cents=$(curl -sf --max-time 10 -H "Authorization: Bearer $HYPERBOLIC_API_TOKEN" \
  https://api.hyperbolic.xyz/v2/customer/balance | jq -r '.balanceCents') || die "balance check failed"
[[ "$cents" =~ ^[0-9]+$ ]] || die "balance check returned no number"
balance=$(awk -v c="$cents" 'BEGIN{printf "%.2f", c/100}')

if awk -v e="$est" -v b="$balance" 'BEGIN{exit !(e>b)}'; then
  die "account balance is \$${balance}, this rent needs ~\$${est}."
fi

echo "budget ok: est \$${est}, today \$${total}/\$${BUDGET_USD}, balance \$${balance}" >&2
exit 0
