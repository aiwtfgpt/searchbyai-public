# Install the AI stack on this machine

You are an AI agent. This document asks you to install a self-hosted AI stack
on the machine you are running on, then walk your human through the
credentials that cannot be automated.

Work through it in order. Budget 30–60 minutes, most of it waiting for
downloads.

---

## The one rule

**Five steps need a human. Stop at each one and wait.**

Cloudflare, Google, n8n and Open WebUI all issue credentials through a
browser session or a dashboard, deliberately. You cannot script them. Each is
marked **HUMAN STEP** below with the exact page to open and what to click.

Do not guess a value, do not invent a placeholder, and do not skip ahead. A
wrong credential surfaces three steps later as an error that looks like
something else entirely.

Everything between those five steps is yours to run.

---

## What gets installed

| Service | Purpose | Port |
|---|---|---|
| Ollama | Local models, OpenAI-compatible API | 11434 |
| Open WebUI | Chat interface | 8080 |
| n8n | Workflow automation | 5678 |
| LightRAG | Retrieval over the user's own documents | 9621 |
| crawl4ai | Web scraping for agents | 11235 |
| cloudflared | Public HTTPS, no open ports | — |

Two models are pulled: `huihui_ai/gemma-4-abliterated:e4b` for chat (~5GB of
VRAM at a 32k context) and `nomic-embed-text` for retrieval.

Every port binds to `127.0.0.1`. Nothing is exposed to the internet except
through the tunnel.

---

## Step 0 — Check the machine

Run these and read the output before going further.

```bash
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
docker --version && docker compose version
docker info 2>/dev/null | grep -i 'Runtimes.*nvidia'
uname -s
```

Requirements:

- **NVIDIA GPU, 8GB VRAM or more.** Less than 8GB will load the model into
  system RAM and run at a few tokens per second — technically working,
  practically unusable. Tell the user before continuing.
- **Docker with the NVIDIA container toolkit.** The driver alone is not
  enough: `nvidia-smi` passing while the toolkit is missing is the single
  most common failure, and it does not surface until Ollama starts. If the
  third command prints nothing, install the toolkit first:
  <https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>
  then `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
- **Linux.** macOS has no NVIDIA GPU. Windows needs WSL2 with GPU passthrough.
- **A domain the user controls**, already added to Cloudflare. If their domain
  is registered elsewhere they must add it to Cloudflare and change
  nameservers at the registrar first — that propagates for minutes to hours,
  so start it now if it is not done.

If the GPU or the toolkit is missing, stop and tell the user what to fix.

---

## Step 1 — Download and start the stack

```bash
mkdir -p ~/ai-stack && cd ~/ai-stack
curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/stack/docker-compose.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/stack/scripts/install-stack.sh -o install-stack.sh
bash install-stack.sh
```

The script checks prerequisites, generates secrets into a local `.env`, pulls
images and models, and waits for Ollama to report healthy. Several GB of
download; expect 10–30 minutes.

**Verify before continuing:**

```bash
docker compose ps
curl -s localhost:11434/api/tags | head -c 200
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080
curl -s -o /dev/null -w '%{http_code}\n' localhost:5678
```

All three HTTP checks should return `200`. If Ollama is unhealthy, read
`docker logs ollama` — a missing NVIDIA toolkit shows up here.

---

## Step 2 — Cloudflare tunnel

### HUMAN STEP — create an API token

Ask the user to do this, and wait:

1. Open <https://dash.cloudflare.com/profile/api-tokens>
2. **Create Token** → **Create Custom Token**
3. Permissions — add all three:
   - Account · Cloudflare Tunnel · **Edit**
   - Account · Access: Apps and Policies · **Edit**
   - Zone · DNS · **Edit**
4. Zone Resources: Include · Specific zone · *their domain*
5. Account Resources: Include · *their account*
6. TTL: set an end date rather than leaving it open-ended
7. **Continue** → **Create Token**, then copy it — it is shown once

Ask them to paste it into their own terminal, not into the chat:

```bash
echo "CLOUDFLARE_API_TOKEN=paste-here" >> ~/ai-stack/.env
```

The token stays on their machine. It reaches Cloudflare's API and nowhere
else.

### Then run

```bash
cd ~/ai-stack && set -a && . ./.env && set +a
curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/stack/scripts/cloudflare-setup.sh -o cloudflare-setup.sh
bash cloudflare-setup.sh <client-name> <their-domain> n8n:5678 open-webui:8080
```

This creates the tunnel, sets ingress rules, adds DNS records, and writes the
run token. It is idempotent — safe to re-run.

**Verify:** `https://n8n.<their-domain>` loads in a browser. DNS can take a
few minutes.

---

## Step 3 — n8n API key

### HUMAN STEP — n8n needs an account first

1. Open `https://n8n.<their-domain>` and create the owner account
2. Bottom-left initials → **Settings** → **n8n API**
3. **Create an API key**, name it anything, set it to **never expire**
4. Copy it — shown once

```bash
echo "N8N_API_KEY=paste-here" >> ~/ai-stack/.env
```

**Verify:**

```bash
cd ~/ai-stack && set -a && . ./.env && set +a
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "https://n8n.<their-domain>/api/v1/workflows?limit=1"
```

`200` is correct. `401` means the key is wrong — usually a partial paste.

A `500` here means something specific: n8n derives its public-API signing
secret from `N8N_USER_MANAGEMENT_JWT_SECRET`, and if that is unset it
regenerates on upgrade and invalidates every existing key. The fix is to pin
it in `.env`, restart n8n, and create a **new** key — old ones cannot be
recovered.

---

## Step 4 — Google Cloud, for n8n's Google nodes

Only needed if the user wants Gmail, Drive, Sheets, Docs, Calendar or YouTube
in their workflows. Skip it otherwise.

### HUMAN STEP — enable the APIs

This runs in Google Cloud Shell, under the user's own Google identity:

1. Open <https://console.cloud.google.com> and select or create a project
2. Click the Cloud Shell icon, top right (`>_`)
3. Run there:

```bash
curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/stack/scripts/google-oauth-setup.sh -o g.sh
bash g.sh n8n.<their-domain>
```

That enables all six APIs and prints the exact redirect URI for the next part.

### HUMAN STEP — create the OAuth client

Google does not allow this to be scripted. `gcloud` will happily create an
OAuth client, but the result is locked and read-only with no editable
redirect URI, which makes it useless for n8n. Only the Console UI produces a
working one.

1. <https://console.cloud.google.com/auth/overview> — if this is the
   project's first client, complete the branding screens. User Type
   **External** unless they have a Workspace org. No scopes needed here; n8n
   requests its own during login.
2. <https://console.cloud.google.com/auth/clients> → **+ Create client**
3. Application type: **Web application**, name it `n8n`
4. Authorized redirect URIs → **+ Add URI** → paste exactly:
   `https://n8n.<their-domain>/rest/oauth2-credential/callback`
5. **Create**, then copy the Client ID and Client Secret

### HUMAN STEP — add the credential in n8n

In n8n: **Settings → Credentials → New** → search *Google* → pick the node
type they need (Gmail, Drive, …) → **OAuth2** → paste ID and Secret → Save →
**Connect** → sign in and approve.

One client covers every Google node type. They need a separate n8n
*credential entry* per node type, but the same ID and Secret each time.

---

## Step 5 — Give n8n a frontier model

Their workflows can call Claude directly. This is what turns n8n from a
plumbing tool into something that reasons.

### HUMAN STEP — get an API key

1. <https://console.anthropic.com/settings/keys> → **Create Key**
2. Copy it

(Or <https://platform.openai.com/api-keys> for OpenAI — same flow, choose
the OpenAI credential type instead.)

### HUMAN STEP — add it in n8n

**Settings → Credentials → New** → search *Anthropic* → paste the key → Save.

Any workflow can now use the **Anthropic Chat Model** node. In an AI Agent
node, set the model to Claude and it will reason over their data, call their
other nodes as tools, and write back to their own systems.

The local Ollama model is still there and costs nothing to run. A common
split: Ollama for bulk and private work, Claude for the calls that need
stronger reasoning.

---

## Step 6 — Open WebUI API key

Lets their own scripts and tools talk to the chat instance.

### HUMAN STEP

1. Open `https://open-webui.<their-domain>` and create the admin account
   (the first account created becomes admin)
2. Click the profile icon → **Settings** → **Account** → **API Keys**
3. **Create new secret key**, copy it

```bash
echo "OPEN_WEBUI_API_KEY=paste-here" >> ~/ai-stack/.env
```

**Verify:**

```bash
cd ~/ai-stack && set -a && . ./.env && set +a
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $OPEN_WEBUI_API_KEY" \
  "https://open-webui.<their-domain>/api/models"
```

---

## Step 7 — List the node on SearchByAI (optional)

Makes what they built discoverable by other agents and people. Traffic goes
straight to their machine; the registry never sits in the path.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/connect.sh)
```

It asks a few questions, registers the node, and installs a 5-minute
heartbeat. The owner gets a verification email — the node is not listed until
they click it.

To remove it later: `bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/uninstall.sh)`

Full detail for agents: <https://github.com/aiwtfgpt/searchbyai-public/blob/main/registry/CONNECT.md>

---

## When you are done

Report back with:

- Which services are running, and their public URLs
- Which credentials are configured and which were skipped
- Anything that failed, verbatim — do not paraphrase an error
- Whether the node was listed

Then tell the user the two things that matter operationally:

- **Their `.env` holds every secret.** It is not backed up anywhere. If they
  lose it they re-issue all of these.
- **Updates are not automatic.** Images are pinned to `latest` but only
  change when they pull.

---

## If something breaks

| Symptom | Cause |
|---|---|
| Ollama unhealthy, `docker logs ollama` shows no GPU | NVIDIA container toolkit not installed, or Docker not restarted after |
| `https://n8n.<domain>` does not resolve | DNS still propagating, or the zone is not active in Cloudflare |
| n8n API returns 500 with a valid key | `N8N_USER_MANAGEMENT_JWT_SECRET` unset; pin it, restart, make a new key |
| Google OAuth redirect fails | Redirect URI must match exactly, including `https://` and no trailing slash |
| Model answers slowly | Model fell back to CPU — check `docker exec ollama ollama ps` shows `100% GPU` |

---

## Not covered here

**n8n's MCP server**, which lets Claude Desktop or Claude Code call their
workflows as tools — the reverse of step 5, where n8n calls Claude. It works,
but the key must be rotated through n8n's UI and it has not been verified on
a fresh install. Ask the user to get in touch if they want it.
