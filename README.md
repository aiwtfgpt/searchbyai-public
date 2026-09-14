# searchbyai-public

Open components of [SearchByAI](https://searchbyai.com). Each directory is
independent — take one, take both, ignore the rest.

| Component | What it is |
|---|---|
| [`registry/`](registry/) | Join the node registry so agents can find what you run |
| [`stack/`](stack/) | Install a self-hosted AI stack on your own GPU |

---

## registry/ — list a node

For a machine that already serves something: an MCP server, an HTTP API, a
CLI tool.

```bash
bash <(curl -fsSL https://searchbyai.com/connect.sh)
```

Installs one directory (`~/.searchbyai`) and one cron entry. No sudo, no
packages, no daemon, no open ports. It registers the node and heartbeats
every five minutes so the listing can show real uptime.

Agents searching the registry connect **straight to your machine** — the
registry is an index, not a proxy, and never sits in the traffic path.

Remove it at any time:

```bash
bash <(curl -fsSL https://searchbyai.com/uninstall.sh)
```

Agents: read [`registry/CONNECT.md`](registry/CONNECT.md).
Manifest format: [`registry/schema/searchbyai-1.0.json`](registry/schema/searchbyai-1.0.json).

---

## stack/ — run your own AI

For a machine with an NVIDIA GPU and nothing on it yet. Ollama, Open WebUI,
n8n, LightRAG, crawl4ai and a Cloudflare tunnel, with two local models.

**Ask your AI to do it.** Any agent with shell access can work through the
guide, running what it can and stopping at each credential only a human can
issue:

```
Read https://searchbyai.com/INSTALL.md and install this stack on my machine.
```

**Or run it yourself:**

```bash
mkdir -p ~/ai-stack && cd ~/ai-stack
curl -fsSL https://searchbyai.com/stack/docker-compose.yml -o docker-compose.yml
curl -fsSL https://searchbyai.com/stack/install-stack.sh -o install-stack.sh
bash install-stack.sh
```

Then follow [`stack/INSTALL.md`](stack/INSTALL.md) from step 2 for the tunnel,
Google, n8n and Claude credentials.

Needs 8GB of VRAM or more, Docker with the NVIDIA container toolkit, Linux,
and a domain on Cloudflare.

---

## Reading before running

Everything here is meant to be read first. Nothing asks for sudo, nothing
installs packages behind your back, and every credential is issued by you, in
your own dashboard, and stays on your machine.

## Compatibility

The install commands above are stable. Files may move inside this repo as
components are added; the published URLs will not change.

## Licence

MIT. See [LICENSE](LICENSE).
