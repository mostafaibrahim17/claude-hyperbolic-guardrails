# Safe GPU provisioning with Hyperbolic's MCP server

Companion repo for the tutorial *From Chat Prompt to Terminated Instance*. It lets Claude Code rent, verify and terminate a Hyperbolic GPU by chat, with three guardrails in front of the tools that spend money.

## What is here

| Path | What it is |
|---|---|
| `server/index.ts` | Hyperbolic's official MCP server, patched to the live v2 API. Drop it over `src/index.ts` in [hyperbolic-mcp](https://github.com/HyperbolicLabs/hyperbolic-mcp) and build. |
| `guard.sh` | PreToolUse hook. Blocks `rent-gpu-instance` when the estimated cost would pass your session cap or your balance. |
| `autoterminate.sh` | PostToolUse hook. Starts a timer after a rent that terminates the rental when the window runs out, and cancels it if you terminate by hand. |
| `config/claude-code-settings.json` | Permission rules (ask before rent and terminate) and the hook wiring for `~/.claude/settings.json`. |
| `config/claude_desktop_config.json` | Server entry for Claude Desktop. Desktop has no hooks, so only the approval dialog applies there. |
| `transcript/run-2026-09-10.md` | The real run: list, rent, nvidia-smi, a blocked over-cap request, manual terminate, and an automatic terminate. |

## Why the server is patched

The official server was last updated in May 2025 and calls a v1 marketplace API that Hyperbolic has retired. Every rent, list and terminate call returns 404. The live API is v2, documented only by its OpenAPI spec at `https://api.hyperbolic.xyz/v2/openapi.json`. The patch moves the five GPU tools to the v2 routes, adds a `get-account-balance` tool, and makes `rent-gpu-instance` return as soon as the order is accepted instead of blocking while the machine boots. SSH tools are unchanged.

## Setup

1. Create an account at app.hyperbolic.ai, add $5, paste an SSH public key in Settings, and create an API key.
2. Generate a key with no passphrase for the server: `ssh-keygen -t ed25519 -f ~/.ssh/hyperbolic_mcp -N ""`
3. Build the patched server:
   ```bash
   git clone https://github.com/HyperbolicLabs/hyperbolic-mcp.git
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
5. Copy `guard.sh` and `autoterminate.sh` to `~/hyperbolic-guardrails/` and `chmod +x` them. Merge `config/claude-code-settings.json` into `~/.claude/settings.json`, fixing the hook paths.
6. Export the variables in the shell you start Claude from, then run `claude`:
   ```bash
   export HYPERBOLIC_API_TOKEN=your-key HYPERBOLIC_BUDGET_USD=10 HYPERBOLIC_MAX_MINUTES=30
   ```

`jq` and `curl` are required. Node 18 or newer for the server.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `HYPERBOLIC_BUDGET_USD` | 10 | Daily cap (UTC day). Sum of today's estimated costs in the ledger may not pass it. |
| `HYPERBOLIC_MAX_RATE_USD` | 5.00 | Worst-case price per GPU hour used for estimates. Set it above the priciest card you might rent. |
| `HYPERBOLIC_MAX_MINUTES` | 30 | Auto-terminate window. Also the length used for estimates. |
| `HYPERBOLIC_LEDGER` | `~/hyperbolic-guardrails/ledger.jsonl` | Where rentals and timer PIDs are recorded. |

## Limits

- Everything runs on your machine. Anything that can edit `settings.json` can remove the hooks.
- The timer is a sleeping process. It does not survive a reboot or a closed laptop. It starts when the order is accepted, so the window includes boot time.
- The budget hook fails closed: if the balance check errors, the rent is blocked.
- The ledger has no lock, so two rents placed at the same moment can both pass the cap.
- On-Demand virtual machines only. Reserved clusters and bare metal are not covered.
- Hyperbolic's inventory and prices change weekly. Check `list-available-gpus` before assuming a price.

MIT, same as the upstream server.
