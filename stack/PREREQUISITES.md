# Before you install

Read this first. Three of these take time you cannot compress — a domain's
nameservers can take up to 24 hours to propagate — so start them before you
touch the installer.

This is a **Docker** install. Everything runs in containers on a machine you
control.

---

## What you need

| | Required for | Cost | Time |
|---|---|---|---|
| **A machine** running Linux with Docker | everything | — | 15 min |
| **A domain you own** | public HTTPS, OAuth redirects | ~$10/year | 10 min + up to 24h |
| **A Cloudflare account** (free) | the tunnel that makes it reachable | free | 10 min |
| **A Google Cloud account** | Gmail, Drive, Sheets, Docs, Calendar in n8n | free tier | 15 min |
| **An LLM** — a GPU, or an API key | the AI nodes | varies | — |

**Only the machine and the domain are truly unavoidable** for the full
install. Google Cloud is skippable if you do not want n8n's Google nodes.
See "If you do not have a domain" at the bottom.

---

## 1. The machine

- **Linux.** Ubuntu 22.04+ or Debian 11+ are the tested paths. macOS has no
  NVIDIA GPU; Windows needs WSL2.
- **Docker and `docker compose` v2.**
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER   # then log out and back in
  ```
- **8GB+ RAM**, 40GB free disk.
- **A GPU is optional.** With an NVIDIA card of 8GB+ VRAM plus the container
  toolkit, models run locally. Without one you use an API provider instead —
  the installer picks the right build either way.

Verify:
```bash
docker --version && docker compose version
docker info 2>/dev/null | grep -i 'Runtimes.*nvidia'   # blank = no GPU, fine
```

---

## 2. A domain

You need one you control. Roughly $10/year from any registrar —
Namecheap, Porkbun, Cloudflare itself.

**Why:** your services get real HTTPS hostnames (`n8n.yourdomain.com`), and
Google's OAuth will not redirect back to anything else. Without a domain, the
tunnel and Google OAuth both stop being possible.

---

## 3. Cloudflare account, and your domain added to it

Free. <https://dash.cloudflare.com/sign-up>

Then add your domain to that account:

1. **Add a domain**, enter your root domain (`acme.com`, not a subdomain)
2. Cloudflare scans your existing DNS records — review and continue
3. It shows you **two nameservers**. Copy them.
4. **If your registrar shows DNSSEC as enabled for this domain, disable it
   first.** Switching nameservers with DNSSEC on can take the domain offline.
5. Log in at your **registrar** — not Cloudflare — find Nameservers, replace
   what is there with Cloudflare's two, save.
6. Wait. The dashboard shows **Active** when it is done. Usually minutes,
   occasionally 24 hours.

```bash
dig ns yourdomain.com +short    # should list the Cloudflare nameservers
```

**Do not continue until the domain shows Active.** The installer will tell you
the zone is not on your account, which looks like a token problem and is not.

---

## 4. Google Cloud account

Free tier is enough. <https://console.cloud.google.com>

Sign in with the Google account whose Gmail, Drive and Calendar you want n8n
to use — the OAuth consent is tied to that identity, so using a different one
later means redoing it.

Create a project, or note which existing one you will use.

**Skip this entirely** if you do not need n8n's Google nodes. Everything else
installs and works without it.

---

## 5. An LLM

**With a GPU:** nothing to arrange. The installer pulls a local model.

**Without one:** get one key before you start. Any of:

- Anthropic — <https://console.anthropic.com/settings/keys>
- OpenAI — <https://platform.openai.com/api-keys>
- Gemini — <https://aistudio.google.com/apikey>

One note if you plan to use LightRAG: its embeddings need **OpenAI
specifically**. Anthropic has no embedding API and Gemini's is not
OpenAI-compatible, so an Anthropic or Gemini key runs everything except
LightRAG's indexing.

---

## The order, and why it cannot change

Each step needs something the previous one produces.

```
1. Cloudflare tunnel   → your services get real hostnames
2. Google OAuth        → needs that hostname for the redirect URI
3. n8n credentials     → needs the OAuth client from step 2
4. LLM credential      → needs n8n to exist
```

Doing Google before Cloudflare does not work: the redirect URI is
`https://n8n.yourdomain.com/rest/oauth2-credential/callback`, and Google will
not accept a hostname that does not resolve.

---

## What cannot be automated, and why

Five credentials must be issued by a human in a browser. This is not a gap in
the installer — each is a deliberate boundary:

| Credential | Why not scriptable |
|---|---|
| Cloudflare API token | Dashboard only, by design |
| Google OAuth client | `gcloud` creates one, but it is locked read-only with no editable redirect URI — useless for n8n |
| n8n API key | Internal route, needs a browser session |
| n8n MCP key | Same |
| Open WebUI API key | Its own UI |

Every credential you create stays on your machine, in your own `.env`. None of
it is transmitted to us, and none of it needs to be pasted into a chat.

---

## If you do not have a domain

You can still list endpoints on SearchByAI without a domain, Cloudflare or
Google Cloud — you just cannot run the full self-hosted stack.

See <https://searchbyai.com/stack> for the current options.
