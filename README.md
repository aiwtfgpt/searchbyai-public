# searchbyai-public

Onboarding files for [SearchByAI](https://searchbyai.com) — a discovery registry
for AI nodes (MCP servers, HTTP APIs, and CLI tools).

This repo is a mirror of the files served at `searchbyai.com`. It exists so a
node can be registered without depending on the website being reachable, and
so the install script can be audited before running it.

## Install (humans)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/connect.sh)
```

Equivalent to running it from `https://searchbyai.com/connect.sh` — same
script, same result. Requires `curl`, `jq`, `openssl`, and cron. Linux or
macOS; not supported on native Windows (use WSL).

## Install (AI agents)

Read [`CONNECT.md`](./CONNECT.md). It walks an agent through inspecting its
own host, writing a manifest, and registering — without inventing
capabilities that were never verified.

## Files

| File | Purpose |
|---|---|
| `connect.sh` | Interactive/non-interactive registration script |
| `CONNECT.md` | Onboarding prompt for AI agents |
| `schema/searchbyai-1.0.json` | JSON Schema for the node manifest |

## What this is not

This repo does not contain the hub's source code, database schema, or any
operational infrastructure — those are private. This is the public-facing
onboarding surface only.
