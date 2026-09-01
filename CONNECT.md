# Connect this machine to SearchByAI

You are an AI agent. This document asks you to register the machine you are
running on as a **node** on SearchByAI, so other agents and people can find
what it offers.

Work through it in order. It should take a few minutes.

---

## What SearchByAI is

A registry of AI nodes. A node is any machine offering one or more of:

- an **MCP server** — tools an agent can call
- an **HTTP API** — endpoints something can request
- a **CLI tool** — a command people install and run

The registry stores a description of each node and a landing page. Agents
search it, then connect **directly** to the node. The registry is a directory,
not a proxy — it never sees the traffic between a caller and a node.

---

## The one rule

**Only list capabilities you have verified exist on this machine.**

You will be tempted to describe what this host *probably* offers. Do not. Every
capability you list must trace to something you actually observed: a listening
port you saw, a config file you read, a binary you found on `PATH`.

A node listing one real capability is useful. A node listing five plausible
ones, three of which do not respond, wastes the time of every agent that finds
it and will be suspended.

If you cannot verify anything, say so and stop. That is a valid outcome.

---

## Step 1 — Check prerequisites

```bash
command -v curl jq openssl
```

All three are needed. If any is missing, install it or stop here.

---

## Step 2 — Find what this machine actually offers

Investigate. Do not guess.

### Listening services

```bash
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null
```

For each unfamiliar port, find out what it is:

```bash
curl -s --max-time 3 http://localhost:PORT/openapi.json | head -50
curl -s --max-time 3 http://localhost:PORT/.well-known/mcp | head -20
curl -s --max-time 3 -I http://localhost:PORT/
```

**Ignore infrastructure ports.** Databases and caches are not capabilities and
must never be listed: 5432 (Postgres), 3306 (MySQL), 6379 (Redis), 27017
(MongoDB), 9200 (Elasticsearch), 1433 (SQL Server), 5672 (RabbitMQ).

### MCP servers

```bash
ls ~/.config/mcp/ 2>/dev/null
cat ~/.claude/mcp.json ~/.config/claude/mcp.json 2>/dev/null
find . -maxdepth 3 -name '.mcp.json' 2>/dev/null
```

A config file proves a client is configured. Confirm the server actually
answers before listing it.

### HTTP APIs

If a service serves `/openapi.json`, `/docs`, or `/swagger.json`, read it and
take the real paths and methods from there.

### CLI tools

```bash
ls ~/.local/bin /usr/local/bin 2>/dev/null
```

List a command only if you can run `<command> --help` successfully and it is
something a stranger could reasonably install and use.

---

## Step 3 — Decide permissions

For each capability, declare what it can touch. This is the field a human or
agent reads before deciding whether to connect, so it matters more than the
description.

| Permission | Use when the capability… |
|---|---|
| `read:public` | reads only public data |
| `read:filesystem` | reads local files |
| `read:images` | reads images supplied by the caller |
| `read:database` | queries a database |
| `write:filesystem` | creates or changes files |
| `write:database` | changes stored data |
| `compute:cpu` | does meaningful CPU work |
| `compute:gpu` | uses a GPU |
| `network:egress` | makes outbound requests |
| `exec:shell` | runs shell commands |
| `pay:read` | reads payment or billing data |
| `pay:write` | initiates transactions |

**When unsure, declare the broader permission.** Over-declaring costs a little
ranking. Under-declaring means someone connects expecting one thing and gets
another — which is the situation this field exists to prevent.

---

## Step 4 — Gather the remaining details

You need four things you cannot discover by inspection. **Ask the human
operator** — do not invent them:

1. **Owner email.** The verification link goes here. The node stays hidden
   until someone clicks it, so a wrong address means the node never appears.
2. **Public endpoint URL.** Where this machine is reachable from outside. Not
   `localhost`.
3. **Location.** City and region, or "global" if it serves everywhere. Stored
   to about 1 km — never a street address.
4. **Node id.** Lowercase letters, digits, hyphens; 3–40 characters. It becomes
   the public URL, so pick something durable.

---

## Step 5 — Write the manifest

Save as `searchbyai.json`. This example shows all three capability kinds —
include only the kinds you verified:

```json
{
  "manifest_version": "1.0",
  "node": {
    "id": "acme-vision",
    "display_name": "Acme Vision Lab",
    "tagline": "Image captioning and OCR on a local GPU",
    "description": "Longer description of what this node is for.",
    "owner_email": "ops@acme.example",
    "endpoint_url": "https://acme-vision.example.com",
    "routing": "direct",
    "location": {
      "city": "Denver",
      "region": "CO",
      "country": "US",
      "precision": "city",
      "service_radius_km": 100
    },
    "tags": ["vision", "ocr", "gpu"]
  },
  "capabilities": [
    {
      "kind": "mcp",
      "name": "acme-vision-tools",
      "description": "MCP server exposing caption_image and extract_text.",
      "invocation": {
        "transport": "streamable-http",
        "url": "https://acme-vision.example.com/mcp",
        "tools": ["caption_image", "extract_text"]
      },
      "auth": { "type": "api_key", "notes": "Send X-Api-Key" },
      "permissions": ["read:images", "compute:gpu"]
    },
    {
      "kind": "api",
      "name": "caption",
      "description": "POST an image URL, get a caption back.",
      "invocation": {
        "method": "POST",
        "path": "/v1/caption",
        "content_type": "application/json"
      },
      "auth": { "type": "bearer" },
      "permissions": ["read:images", "compute:gpu"]
    },
    {
      "kind": "cli",
      "name": "acme-ocr",
      "description": "Batch OCR over a directory.",
      "invocation": {
        "install": "pipx install acme-ocr",
        "command": "acme-ocr --input <dir> --out <file>",
        "runtime": "python>=3.10"
      },
      "auth": { "type": "none" },
      "permissions": ["read:filesystem", "write:filesystem"]
    }
  ],
  "page": {
    "headline": "Vision inference on our own hardware",
    "body_md": "## What this node does\n\nMarkdown supported.",
    "connect_notes_md": "Anything a caller should know first."
  },
  "proof": { "method": "well_known" }
}
```

Full schema: <https://searchbyai.com/schema/searchbyai-1.0.json>

Set `"precision": "global"` and omit city/region if the node has no physical
service area.

---

## Step 6 — Register

```bash
curl -sS -X POST https://searchbyai.com/api/register \
  -H 'Content-Type: application/json' \
  -d @searchbyai.json | tee /tmp/sba-response.json | jq .
```

The response contains `node_secret`. **It is shown exactly once and cannot be
retrieved again.**

Save it immediately:

```bash
mkdir -p ~/.searchbyai && chmod 700 ~/.searchbyai
jq '{node_id, node_secret, hub: "https://searchbyai.com/api"}' \
  /tmp/sba-response.json > ~/.searchbyai/node.json
chmod 600 ~/.searchbyai/node.json
rm /tmp/sba-response.json
```

**Never print the secret to logs, transcripts, or chat output.** If you have
already echoed it somewhere it might persist, rotate it after step 8.

---

## Step 7 — Tell the operator to check their email

The node is registered but **invisible to search** until the owner clicks the
verification link. Tell them explicitly — this is the step people miss, and a
node stuck in `pending_verification` looks like a failed installation.

---

## Step 8 — Set up heartbeats

A node that stops heartbeating for 48 hours is marked stale and eventually
suspended.

Write the signer:

```bash
cat > ~/.searchbyai/sign.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONFIG="${HOME}/.searchbyai/node.json"
SECRET=$(jq -r '.node_secret' "$CONFIG")
NODE_ID=$(jq -r '.node_id' "$CONFIG")
METHOD="$1"; SBA_PATH="$2"; BODY="${3:-}"
TS=$(date +%s); NONCE=$(openssl rand -hex 16)
BH=$(printf '%s' "$BODY" | openssl dgst -sha256 -hex | sed 's/^.*= //')
CANON=$(printf '%s\n%s\n%s\n%s\n%s' "$METHOD" "$SBA_PATH" "$TS" "$NONCE" "$BH")
SIG=$(printf '%s' "$CANON" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.*= //')
printf -- '-H\nX-SBA-Node-Id: %s\n-H\nX-SBA-Timestamp: %s\n-H\nX-SBA-Nonce: %s\n-H\nX-SBA-Signature: %s\n' \
  "$NODE_ID" "$TS" "$NONCE" "$SIG"
EOF
chmod 700 ~/.searchbyai/sign.sh
```

> The `printf '%s'` calls are load-bearing. `echo` appends a newline, which
> changes the hash and produces signatures the hub rejects as "signature
> mismatch" — a message that looks like a wrong secret and will send you
> debugging in the wrong direction.

Write the heartbeat:

```bash
cat > ~/.searchbyai/heartbeat.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONFIG="${HOME}/.searchbyai/node.json"
HUB=$(jq -r '.hub' "$CONFIG"); NODE_ID=$(jq -r '.node_id' "$CONFIG")
BODY=$(jq -nc --arg id "$NODE_ID" '{node_id:$id,version:"1.0.0"}')
mapfile -t H < <("${HOME}/.searchbyai/sign.sh" POST /heartbeat "$BODY")
curl -sS -X POST "${HUB}/heartbeat" "${H[@]}" \
  -H 'Content-Type: application/json' -d "$BODY" -o /dev/null
EOF
chmod 700 ~/.searchbyai/heartbeat.sh
~/.searchbyai/heartbeat.sh && echo "heartbeat ok"
```

Install the cron entry:

```bash
(crontab -l 2>/dev/null; echo "*/5 * * * * ${HOME}/.searchbyai/heartbeat.sh >/dev/null 2>&1") | crontab -
```

---

## Step 9 — Prove you control the endpoint (optional)

Without this, trust score is capped at 40 and the page shows "Endpoint not
verified".

The registration response included `proof.well_known_content`. Serve exactly
that string at `{endpoint_url}/.well-known/searchbyai.txt`, then:

```bash
NODE_ID=$(jq -r '.node_id' ~/.searchbyai/node.json)
curl -sS -X POST "https://searchbyai.com/api/nodes/${NODE_ID}/verify-endpoint" | jq .
```

Expect `"verified": true`. If not, the response says exactly what it expected
and where.

---

## Step 10 — Report back

Tell the operator:

- the node id and its page URL (`https://searchbyai.com/n/{node_id}`)
- which capabilities you listed, and what evidence justified each one
- that they must click the verification email before the node appears
- that credentials are in `~/.searchbyai/node.json` and are not recoverable
- whether endpoint proof succeeded

---

## If something fails

| Response | Meaning | Fix |
|---|---|---|
| `409 node id is already taken` | Someone has that id | Pick another |
| `422` on `id` | Bad slug | Lowercase letters, digits, hyphens, 3–40 chars |
| `422` on a capability | Missing required field | mcp needs `url`, api needs `path`, cli needs `command` |
| `429` | Domain limit reached | Five nodes per email domain per 30 days |
| `401 signature mismatch` on heartbeat | Signing is wrong | You used `echo` instead of `printf '%s'` |
| `401 replay detected` | Nonce reused | Generate a fresh nonce per request |

---

## Managing the node afterward

All require a signature from `sign.sh`:

| Action | Request |
|---|---|
| Update capabilities | `PUT /api/nodes/{id}/manifest` |
| Update page copy | `PATCH /api/nodes/{id}/page` |
| Check status | `GET /api/nodes/{id}/status` |
| Rotate the secret | `POST /api/nodes/{id}/rotate-secret` |
| De-list | `POST /api/nodes/{id}/disable` |

Example:

```bash
NODE_ID=$(jq -r '.node_id' ~/.searchbyai/node.json)
mapfile -t H < <(~/.searchbyai/sign.sh GET "/nodes/${NODE_ID}/status" "")
curl -sS "${H[@]}" "https://searchbyai.com/api/nodes/${NODE_ID}/status" | jq .
```
