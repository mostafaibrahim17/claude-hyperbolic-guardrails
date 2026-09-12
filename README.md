# Safe GPU provisioning with Hyperbolic's MCP server

Companion repo for the tutorial *From Chat Prompt to Terminated Instance*. It lets Claude Code rent, verify and terminate a Hyperbolic GPU by chat, with three guardrails in front of the tools that spend money.

## What is here

| Path | What it is |
|---|---|
| `server/index.ts` | Hyperbolic's official MCP server, patched to the live v2 API. `server/hyperbolic-mcp-v2.patch` is the same change as a diff. Drop it over `src/index.ts` in [hyperbolic-mcp](https://github.com/HyperbolicLabs/hyperbolic-mcp) and build. |
| `guard.sh` | PreToolUse hook. Prices the requested option from Hyperbolic's live catalogue and blocks `rent-gpu-instance` when the cost would pass your daily cap, when too many rentals are already live, or when your balance cannot cover it. Any error blocks. |
| `autoterminate.sh` | PostToolUse hook. Starts a timer after a rent that terminates the rental when the window runs out, and cancels it if you terminate by hand. The terminate call is judged by HTTP status and retried three times; a final failure raises a desktop notification. |
| `reaper.sh` | Cron backstop. Terminates any live rental older than the window, so a dead timer, a reboot, or a closed laptop cannot leave a machine billing. Run it every five minutes with the token in the environment. |
| `bench/bench.py` | One-minute GPU benchmark (bf16 matmul and memory bandwidth, CUDA-event timed, median of five) that prints its own cost. |
| `config/claude-code-settings.json` | Permission rules (ask before rent and terminate) and the hook wiring for `~/.claude/settings.json`. |
| `config/claude_desktop_config.json` | Server entry for the Claude Desktop chat app, which does not run Claude Code hooks. Only its approval dialog applies there. |
| `transcript/run-2026-09-12.md` | The real runs on the shipped scripts: list, rent, nvidia-smi, benchmark, three different blocks, manual terminate, and an automatic terminate. `run-2026-09-10.md` is the earlier run on the first version of the scripts, kept for the bug it found. |

## Why the server is patched

The official server was last updated in May 2025 and calls a v1 marketplace API that Hyperbolic has retired. Every rent, list and terminate call returns 404. The live API is v2, documented only by its OpenAPI spec at `https://api.hyperbolic.xyz/v2/openapi.json`. The patch moves the five GPU tools to the v2 routes, adds a `get-account-balance` tool, and makes `rent-gpu-instance` return as soon as the order is accepted instead of blocking while the machine boots. SSH tools are unchanged.

## Setup

1. Create an account at app.hyperbolic.ai, add $5, paste an SSH public key in Settings, and create an API key.
2. Generate a key with no passphrase for the server: `ssh-keygen -t ed25519 -f ~/.ssh/hyperbolic_mcp -N ""`
3. Build the patched server:
   ```bash
   git clone https://github.com/HyperbolicLabs/hyperbolic-mcp.git
   git -C hyperbolic-mcp checkout d2962d3   # the commit the patch was written against
   cp server/index.ts hyperbolic-mcp/src/index.ts
   cd hyperbolic-mcp && npm install && npm run build
   ```
4. Register it with Claude Code (the name must come before the `-e` flags):
   ```bash
   claude mcp add --scope user hyperbolic-gpu \
     -e HYPERBOLIC_API_TOKEN=your-key \
     -e SSH_PRIVATE_KEY_PATH=$HOME/.ssh/hyperbolic_mcp \
     -- node /absolute/path/to/hyperbolic-mcp/build/index.js
   ```
5. Copy `guard.sh`, `autoterminate.sh` and `reaper.sh` to `~/hyperbolic-guardrails/` and `chmod +x` them. The hook matcher and the scripts key on the server name `hyperbolic-gpu`; if you register the server under another name, change both. Merge `config/claude-code-settings.json` into `~/.claude/settings.json`, fixing the hook paths.
6. Export the variables in the shell you start Claude from, then run `claude`:
   ```bash
   export HYPERBOLIC_API_TOKEN=your-key HYPERBOLIC_BUDGET_USD=10 HYPERBOLIC_MAX_MINUTES=30 HYPERBOLIC_MAX_LIVE=1
   ```

`jq` 1.6+ and `curl` are required, Node 18 or newer for the server. Tested on macOS 14 with Claude Code 2.1.261; the scripts are plain bash and should run on Linux, but only the reaper's age check has been tested there.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `HYPERBOLIC_BUDGET_USD` | 10 | Daily cap (UTC day). Sum of today's estimated costs in the ledger may not pass it. |
| `HYPERBOLIC_MAX_LIVE` | 1 | How many rentals may be live at once. A rent is blocked when this many are already Pending or Running. |
| `HYPERBOLIC_MAX_MINUTES` | 30 | Auto-terminate window. Also the length used for estimates. |
| `HYPERBOLIC_LEDGER` | `~/hyperbolic-guardrails/ledger.jsonl` | Where rentals and timer PIDs are recorded. |

## Backstop

The timer is a process on your laptop. For anything you cannot watch, run the reaper from cron:

```
*/5 * * * * HYPERBOLIC_API_TOKEN=$(cat ~/.hyperbolic_token) HYPERBOLIC_MAX_MINUTES=30 /path/to/reaper.sh >> ~/hyperbolic-guardrails/reaper.log 2>&1
```

## Limits

- Everything runs on your machine. The agent's shell inherits your API key, so the hooks gate the tool, not the credential. Anything that can edit `settings.json` can remove the hooks. Hyperbolic allows no overdraft, so your account balance is the one ceiling nothing here can bypass.
- The timer is a sleeping process. It pauses while the laptop sleeps and dies on logout or reboot. It starts when the order is accepted, so the window includes boot time. It is a hard stop and saves nothing first.
- The budget hook fails closed: if the balance check errors, the rent is blocked.
- The ledger has no lock, so two rents placed at the same moment can both pass the cap.
- On-Demand virtual machines only. Reserved clusters and bare metal are not covered.
- Hyperbolic's inventory and prices change weekly. Check `list-available-gpus` before assuming a price.

MIT, same as the upstream server.
