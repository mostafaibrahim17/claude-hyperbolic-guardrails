# claude-hyperbolic-guardrails

**Let Claude Code rent, test and terminate a Hyperbolic GPU from chat, with a budget cap, an approval gate, and an auto-terminate timer in front of every call that spends money.**

Companion repo for the tutorial *From Chat Prompt to Terminated Instance*. Everything here was run for real: five rentals over two days, 26 minutes of H100, about $1.25, with every guardrail exercised at least once. The transcripts are in `transcript/`.

<p align="center"><img src="assets/flow.svg" alt="A rent call passes through guard.sh, then a permission prompt, then the MCP server, then Hyperbolic. Over the cap, the hook exits 2 and the request is blocked before any prompt." width="760"></p>

## What you get

| | |
|---|---|
| **A working server** | Hyperbolic's open-source MCP server, updated from the retired v1 routes to the live v2 API. `server/index.ts` is the file, `server/hyperbolic-mcp-v2.patch` is the diff. |
| **Guardrail 1, budget** | `guard.sh` prices the exact option from the live catalogue and blocks a rent that would pass your daily cap, your balance, or your live-rental limit. Any error blocks. |
| **Guardrail 2, approval** | `config/claude-code-settings.json` makes rent, terminate, ssh-connect and remote-shell ask you every time, even in auto-accept mode, and denies direct API calls from the shell. |
| **Guardrail 3, timer** | `autoterminate.sh` arms a timer on every rent and terminates the rental when the window runs out. Judged by HTTP status, retried, and it notifies you if it fails. |
| **Backstop** | `reaper.sh` runs from cron and terminates any guard-created rental older than the window, for the day the timer dies with your laptop. |
| **Benchmark** | `bench/bench.py`, a one-minute bf16 matmul and bandwidth test that prints its own cost. |

## Quick start

Requirements: Node 18+, `jq` 1.6+, `curl`, Claude Code. Tested on macOS 14 with Claude Code 2.1.261.

**1. Hyperbolic account.** Sign up at [app.hyperbolic.ai](https://app.hyperbolic.ai), add the $5 minimum, create an API key, and paste an SSH public key. The server cannot use a passphrase, so make a separate key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hyperbolic_mcp -N ""
```

**2. Build the patched server.**

```bash
git clone https://github.com/HyperbolicLabs/hyperbolic-mcp.git && git -C hyperbolic-mcp checkout d2962d3
git clone https://github.com/mostafaibrahim17/claude-hyperbolic-guardrails.git
cp claude-hyperbolic-guardrails/server/index.ts hyperbolic-mcp/src/index.ts
cd hyperbolic-mcp && npm install && npm run build && cd ..
```

**3. Register it with Claude Code.** The name `hyperbolic-gpu` is load-bearing; the hooks, rules and scripts all key on it.

```bash
claude mcp add --scope user hyperbolic-gpu \
  -e HYPERBOLIC_API_TOKEN=your-key \
  -e SSH_PRIVATE_KEY_PATH=$HOME/.ssh/hyperbolic_mcp \
  -- node "$PWD/hyperbolic-mcp/build/index.js"
```

**4. Install the guardrails.**

```bash
mkdir -p ~/hyperbolic-guardrails
cp claude-hyperbolic-guardrails/*.sh ~/hyperbolic-guardrails/ && chmod +x ~/hyperbolic-guardrails/*.sh
```

Merge `config/claude-code-settings.json` into `~/.claude/settings.json`.

**5. Run.** Export the settings in the shell you start Claude from, then start it.

```bash
export HYPERBOLIC_API_TOKEN=your-key HYPERBOLIC_BUDGET_USD=10 HYPERBOLIC_MAX_MINUTES=30 HYPERBOLIC_MAX_LIVE=1
claude
```

**6. Prove it works before trusting it.** Ask for a rent that exceeds the cap and confirm you see `BLOCKED`. If the hook cannot run at all, a wrong path or a missing `chmod +x`, Claude Code treats that as a hook error and lets the call through.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `HYPERBOLIC_BUDGET_USD` | 10 | Daily cap, UTC day. The sum of today's estimates in the ledger may not pass it. Terminating early does not credit an estimate back. |
| `HYPERBOLIC_MAX_MINUTES` | 30 | Auto-terminate window, counted from the order, so it includes boot time. Also the length used for estimates. |
| `HYPERBOLIC_MAX_LIVE` | 1 | How many rentals may be live at once. |
| `HYPERBOLIC_LEDGER` | `~/hyperbolic-guardrails/ledger.jsonl` | Where rentals, estimates and timer PIDs are recorded. |

## Backstop from cron

The timer is a process on your laptop. It pauses when the laptop sleeps and dies on reboot. For anything you cannot watch, run the reaper every five minutes with the token in a file only you can read:

```bash
umask 077; echo sk_live_... > ~/.hyperbolic_token
```

```
*/5 * * * * HYPERBOLIC_API_TOKEN=$(cat ~/.hyperbolic_token) HYPERBOLIC_MAX_MINUTES=30 ~/hyperbolic-guardrails/reaper.sh >> ~/hyperbolic-guardrails/reaper.log 2>&1
```

The reaper only touches rentals whose id is in the ledger. Set `REAPER_ALL=1` to reap every rental on the account.

## What was proven, and how

| Check | Run | Result |
|---|---|---|
| Rent passes the budget, machine boots | 18025 | Running 2 min 20 s after the order |
| GPU is real | 18025 | `nvidia-smi` shows one H100 PCIe, 80 GB; matmul at H100 speed |
| Option vanished from catalogue | 18025 | `BLOCKED: no live option`, no prompt shown |
| Live-rental limit | 18025 | `BLOCKED: 1 rental(s) already live, limit is 1` |
| Daily cap | after 18025 | `BLOCKED: ... Today's total would be $4.09, cap is $2` |
| Manual terminate cancels the timer | 18025 | timer process gone, nothing fired later |
| Auto-terminate | 18026 | fired 8 min 2 s after the order, HTTP 200 |
| Deny rule | session | `curl` to the API refused by the permission layer |
| Reaper after a dead timer | 18028 | timer killed by hand, reaper terminated the rental once it passed the window |

## Limits

- The hooks gate the MCP tool, not the credential. The agent's shell inherits your API key and can read `~/.claude.json` or edit `settings.json`. The deny rules are best effort. The real fix is a sandbox and a key with a spend limit. Hyperbolic allows no overdraft, so your balance is the one ceiling nothing here can bypass.
- The timer is a hard stop and saves nothing first. Do not point it at a training run without a checkpoint.
- The ledger has no lock, so two rents placed at the same instant can both pass the cap.
- On-Demand virtual machines only. Reserved clusters and bare metal are not covered.
- Prices and inventory change constantly, which is why the guard prices every rent from the live catalogue at request time.

## License

MIT. `server/index.ts` is derived from [HyperbolicLabs/hyperbolic-mcp](https://github.com/HyperbolicLabs/hyperbolic-mcp), MIT, Copyright (c) 2025 Hyperbolic Labs.
