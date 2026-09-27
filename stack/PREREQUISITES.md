# Before you install

This is a **Docker** install on a Linux machine you control.

**Start here:**

```bash
bash <(curl -fsSL https://searchbyai.com/stack/preflight.sh)
```

That checks the machine, tells you which build fits, and offers to install
Docker if it is missing. It changes nothing else.

---

## Pick your path

Everything below splits on one question, so answer it first.

| | **A — I have a domain** | **B — I do not** |
|---|---|---|
| Public hostname | Cloudflare tunnel on your domain | Tailscale Funnel, free |
| Cost | ~$10/year | nothing |
| Setup time | 10 min + up to 24h for DNS | 5 min |
| n8n Google nodes | **yes** | no — Google will not redirect to `.ts.net` |
| Everything else | identical | identical |

**Path B is a real option, not a downgrade.** You lose Gmail, Drive, Sheets,
Docs and Calendar inside n8n. n8n itself, Open WebUI, LightRAG, crawl4ai,
local models and listing on SearchByAI all work the same. Adding a domain
later changes nothing else.

---

## What you need

| | Required for | Cost | Time |
|---|---|---|---|
| **A machine** running Linux with Docker | everything | — | 15 min |
| **A domain you own** *(or a free tunnel — see below)* | public HTTPS, OAuth redirects | ~$10/year | 10 min + up to 24h |
| **A Cloudflare account** (free) | the tunnel that makes it reachable | free | 10 min |
| **A Google Cloud account** | Gmail, Drive, Sheets, Docs, Calendar in n8n | **free — no card** | 15 min |
| **An LLM** — a GPU, or an API key | the AI nodes | varies | — |

**Only the machine is truly unavoidable.** Google Cloud is free and
skippable. The domain can be replaced with a free Tailscale Funnel hostname —
see below — at the cost of a less professional-looking URL and no Google
OAuth.

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

## 2. A domain — recommended, not required

Roughly $10/year from any registrar: Namecheap, Porkbun, Cloudflare itself.

**Why it helps:** your services get real HTTPS hostnames
(`n8n.yourdomain.com`), and Google's OAuth will only redirect to a domain you
control — so n8n's Google nodes need one.

**If you would rather not buy one**, skip to
[If you do not have a domain](#if-you-do-not-have-a-domain). A free Tailscale
Funnel hostname covers everything except the Google nodes.

---

## 3. Cloudflare account, and your domain added to it

Only if you are using your own domain — skip this with Tailscale Funnel.

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

## 4. Google Cloud account — free, and optional

**This costs nothing.** Gmail, Drive, Sheets, Docs and Calendar all sit in
Google's free tier. You do not need a billing account and you will not be
asked for a card. If you have heard otherwise, that is Google Cloud's *paid*
services — compute, storage, BigQuery — none of which this uses.

<https://console.cloud.google.com>

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

## What happens when

A common confusion: *"connect n8n to Google"* cannot be a prerequisite,
because n8n does not exist until you have installed it. Only two things
genuinely happen beforehand.

### Before the installer runs — you, in a browser

| | Path A (domain) | Path B (no domain) |
|---|---|---|
| 1 | Add your domain to Cloudflare, change nameservers, wait for **Active** | — |
| 2 | Create a Cloudflare API token | — |
| 3 | Create a Google Cloud account *(optional)* | — |
| 4 | — | Install Tailscale, run `tailscale funnel` |
| 5 | Get an LLM API key if you have no GPU | same |

That is the whole list. Everything else needs software that is not installed
yet.

### The installer — automated

Pulls images, starts containers, generates secrets, and on a GPU machine
pulls the models.

### After the installer — guided, mostly automated

Each step needs the one before it:

```
1. Cloudflare tunnel   → your services get a real hostname
                         (Path B: skip — Funnel already gave you one)
2. n8n API key         → n8n has to be running first
3. Google OAuth client → needs the hostname from step 1, because the
                         redirect URI is https://n8n.<domain>/rest/...
                         (Path B: skip — .ts.net is not accepted)
4. Google credential in n8n → needs the client from step 3
5. LLM credential in n8n    → needs n8n
6. Open WebUI API key
7. List on SearchByAI  (optional)
```

Doing Google before Cloudflare does not work: Google will not accept a
redirect to a hostname that does not resolve.

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

You do not strictly need one. **Tailscale Funnel** gives you a free, stable,
public HTTPS URL with no domain, no open ports, and no router configuration.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo tailscale funnel 5678          # or whichever port you want public
```

The first run opens a browser to approve enabling Funnel; Tailscale then
issues the certificate and updates your tailnet policy itself. You get a URL
like:

```
https://your-machine.your-tailnet.ts.net
```

That is stable across restarts, which matters — it is what you register with
SearchByAI, and a URL that changes breaks the listing.

**What this gets you and what it does not:**

| | Tailscale Funnel | Your own domain |
|---|---|---|
| Cost | free | ~$10/year |
| Public HTTPS URL | yes | yes |
| Stable across restarts | yes | yes |
| Open ports needed | **none** | none |
| Port forwarding | **none** | none |
| Works behind CGNAT | yes | yes |
| Google OAuth for n8n | **no** — Google will not accept a `.ts.net` redirect | yes |
| Looks like your brand | no | yes |
| Bandwidth | rate-limited, fine for a low-traffic node | your own |

**The real trade:** Google OAuth needs a redirect URI on a domain you control,
so with Funnel you lose n8n's Gmail, Drive, Sheets, Docs and Calendar nodes.
Everything else — n8n itself, Open WebUI, LightRAG, crawl4ai, and listing on
SearchByAI — works exactly the same.

A reasonable path is to start with Funnel, and add a domain later if you want
the Google nodes. Nothing else in the install changes when you do.

### Other options

- **Already hosting something?** A Replit app, a Hugging Face Space, a Vercel
  function — the registry only needs a URL that answers. List it with
  `connect.sh` and skip this stack entirely.
- **Just want to try it?** Install without the tunnel. Everything runs on
  `localhost`. You cannot be listed, but nothing stops you building.
- **Avoid Cloudflare quick tunnels** (`trycloudflare.com`) for a listing. They
  are free and need no account, but the URL changes on every restart.
