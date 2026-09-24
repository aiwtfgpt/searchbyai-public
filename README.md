# searchbyai-public

Open components of [SearchByAI](https://searchbyai.com). Each directory is
independent — take one, take both, ignore the rest.

| Component | What it is |
|---|---|
| [`registry/`](registry/) | Join the node registry so agents can find what you run |
| [`stack/`](stack/) | Install a self-hosted AI stack — GPU optional |

---

## registry/ — list a node

For a machine that already serves something: an MCP server, an HTTP API, a
CLI tool.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/connect.sh)
```

Installs one directory (`~/.searchbyai`) and one cron entry. No sudo, no
packages, no daemon, no open ports. It registers the node and heartbeats
every five minutes so the listing can show real uptime.

Agents searching the registry connect **straight to your machine** — the
registry is an index, not a proxy, and never sits in the traffic path.

Remove it at any time:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/uninstall.sh)
```

Agents: read [`registry/CONNECT.md`](registry/CONNECT.md).
Manifest format: [`registry/schema/searchbyai-1.0.json`](registry/schema/searchbyai-1.0.json).

---

## stack/ — run your own AI

Ollama, Open WebUI, n8n, LightRAG, crawl4ai and a Cloudflare tunnel. Two
builds, and the installer picks for you:

| | **gpu** | **cloud** |
|---|---|---|
| Needs | NVIDIA GPU, 8GB+ VRAM, container toolkit | No GPU |
| Inference | Local models via Ollama | Anthropic, OpenAI or Gemini |
| Downloads | ~9GB of models | Nothing |

There is no CPU-inference option on purpose: a 9GB model answering at a few
tokens per second is worse than an API key, and it pins the machine while it
runs. Without a GPU you get the cloud build, which ships without Ollama
entirely — n8n, Open WebUI, LightRAG and crawl4ai are identical either way.

**Ask your AI to do it.** Any agent with shell access can work through the
guide. It checks the hardware first, installs the matching build, and stops at
each credential only a human can issue:

```
Read https://searchbyai.com/INSTALL.md and install this stack on my machine.
```

**Or run it yourself.** Check the hardware first — which files you need depends
on the answer:

```bash
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
docker info 2>/dev/null | grep -i 'Runtimes.*nvidia'
```

```bash
mkdir -p ~/ai-stack && cd ~/ai-stack
curl -fsSL https://searchbyai.com/stack/install-stack.sh -o install-stack.sh

# GPU with the container toolkit:
curl -fsSL https://searchbyai.com/stack/docker-compose.yml     -o docker-compose.yml
curl -fsSL https://searchbyai.com/stack/docker-compose.gpu.yml -o docker-compose.gpu.yml

# No GPU — have an Anthropic, OpenAI or Gemini key ready:
curl -fsSL https://searchbyai.com/stack/docker-compose.cloud.yml -o docker-compose.cloud.yml

bash install-stack.sh
```

The installer re-checks the hardware itself, so a wrong guess is caught rather
than acted on. Then follow [`stack/INSTALL.md`](stack/INSTALL.md) from step 2
for the tunnel, Google, n8n and Claude credentials.

Needs Docker and Linux either way.

---

## Reading before running

Everything here is meant to be read first. Nothing asks for sudo, nothing
installs packages behind your back, and every credential is issued by you, in
your own dashboard, and stays on your machine.

## Compatibility

Install reads from this repo, so the commands work whether or not
searchbyai.com is up. Paths here are stable; if a file has to move, the old
location keeps working for a release.

Registering a node still calls the SearchByAI API at `searchbyai.com` — that
is the registry itself, not the installer.

## Licence

MIT. See [LICENSE](LICENSE).

