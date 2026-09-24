#!/usr/bin/env bash
# ==============================================================================
# install-stack.sh — install and start the single-GPU AI stack
#
# Brings up: Ollama, Open WebUI, n8n, crawl4ai, LightRAG, cloudflared
#            (rss-bridge optional, behind the "feeds" profile)
#
# Run this FIRST. Credentials come after, via onboard.sh, because the
# Cloudflare tunnel needs running services to point at.
#
# Usage:
#   bash install-stack.sh [install-dir]
#
# Default install dir is the parent of this script's directory.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Default: wherever the compose file actually is. The guided install puts it
# next to this script; in a repo checkout the script sits in scripts/ and the
# compose is one level up. An explicit first argument overrides both.
if [ -n "${1:-}" ]; then
  INSTALL_DIR="$1"
elif [ -f "$SCRIPT_DIR/docker-compose.yml" ] || [ -f "$SCRIPT_DIR/docker-compose.single-gpu.yml" ]; then
  INSTALL_DIR="$SCRIPT_DIR"
else
  INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
# Accept either name: the guided install downloads it as docker-compose.yml,
# a direct download keeps its published name.
if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
else
  COMPOSE_FILE="$INSTALL_DIR/docker-compose.single-gpu.yml"
fi
ENV_FILE="$INSTALL_DIR/.env"

# Model defaults. Both are pulled after the stack is up.
CHAT_MODEL="${OLLAMA_CHAT_MODEL:-huihui_ai/gemma-4-abliterated:e4b}"
EMBED_MODEL="${EMBEDDING_MODEL:-nomic-embed-text}"

echo "################################################################"
echo "#  AI Stack install (single GPU)"
echo "#  Directory: $INSTALL_DIR"
echo "################################################################"
echo ""

# --- Step 1: preflight ------------------------------------------------------
echo "[1/6] Checking prerequisites ..."

MISSING=0

if ! command -v docker >/dev/null 2>&1; then
  echo "  ✗ docker is not installed."
  echo "    Install: curl -fsSL https://get.docker.com | sh"
  echo "    Then:    sudo usermod -aG docker \$USER   (log out and back in)"
  MISSING=1
else
  echo "  ✓ docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "  ✗ 'docker compose' (v2) is not available."
  echo "    The old 'docker-compose' v1 script will not work — this file"
  echo "    uses v2 syntax (profiles, service-level healthcheck conditions)."
  MISSING=1
else
  echo "  ✓ docker compose $(docker compose version --short 2>/dev/null)"
fi

# Docker must be usable without sudo, or every later command breaks.
if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
  echo "  ✗ Cannot talk to the Docker daemon as $(whoami)."
  echo "    Either the daemon is stopped (sudo systemctl start docker) or"
  echo "    this user is not in the 'docker' group:"
  echo "      sudo usermod -aG docker \$USER   (log out and back in)"
  MISSING=1
fi

# GPU is optional. Without one the stack still installs and n8n, Open WebUI,
# LightRAG and crawl4ai all work normally — only local model inference is
# affected, and that falls back to CPU or an external provider.
HAS_GPU=0
if command -v nvidia-smi >/dev/null 2>&1 \
   && nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)

  # The toolkit is a separate install from the driver. Enabling the GPU in
  # compose without it makes Ollama fail to start — worse than CPU, because
  # it looks like a broken install rather than a slow one.
  if docker info 2>/dev/null | grep -qi 'Runtimes.*nvidia'; then
    HAS_GPU=1
    echo "  ✓ GPU: $GPU_NAME ($GPU_VRAM), $GPU_COUNT card(s)"
    if [ "$GPU_COUNT" -gt 1 ]; then
      echo "    Note: this build uses device 0 only."
    fi
  else
    echo "  ! GPU found ($GPU_NAME) but the NVIDIA container toolkit is not"
    echo "    registered with Docker, so containers cannot reach it."
    echo "    Installing on CPU. To use the GPU, install the toolkit:"
    echo "      https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    echo "    then: sudo nvidia-ctk runtime configure --runtime=docker"
    echo "          sudo systemctl restart docker"
    echo "    and re-run this script."
  fi
else
  echo "  ! No NVIDIA GPU detected — installing in CPU mode."
  echo "    Everything works except fast local inference: n8n, Open WebUI,"
  echo "    LightRAG and crawl4ai are unaffected."
  echo "    A local model on CPU answers slowly. Most people in this position"
  echo "    point n8n at an API provider instead — onboard.sh stage 4 covers it."
fi

if [ "$MISSING" -ne 0 ]; then
  echo ""
  echo "Fix the items marked ✗ above, then run this script again."
  exit 1
fi
echo ""

# --- Step 2: compose file ---------------------------------------------------
echo "[2/6] Checking compose file ..."
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "  ✗ No compose file in $INSTALL_DIR"
  echo "    Download it first:"
  echo "      curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/stack/docker-compose.yml -o docker-compose.yml"
  exit 1
fi
echo "  ✓ $COMPOSE_FILE"

# Layer the GPU override only when a card is actually usable.
COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [ "$HAS_GPU" -eq 1 ]; then
  GPU_FILE="$INSTALL_DIR/docker-compose.gpu.yml"
  if [ -f "$GPU_FILE" ]; then
    COMPOSE_ARGS+=(-f "$GPU_FILE")
    echo "  ✓ GPU override: $GPU_FILE"
  else
    echo "  ! docker-compose.gpu.yml not found — running on CPU."
    echo "    Download it: curl -fsSL https://searchbyai.com/stack/docker-compose.gpu.yml -o docker-compose.gpu.yml"
    HAS_GPU=0
  fi
fi
echo ""

# --- Step 3: .env -----------------------------------------------------------
echo "[3/6] Preparing .env ..."

# Generated, not prompted: these are machine secrets with no human meaning.
# Losing them means invalidated sessions, so they are written once and
# then left alone on re-runs.
if [ ! -f "$ENV_FILE" ]; then
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  ✓ Created $ENV_FILE (mode 600)"
fi

ensure_env() {
  local key="$1" val="$2"
  if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    echo "${key}=${val}" >> "$ENV_FILE"
    echo "  + $key"
  fi
}

ensure_env WEBUI_SECRET_KEY      "$(openssl rand -hex 32)"
ensure_env LIGHTRAG_TOKEN_SECRET "$(openssl rand -hex 32)"
ensure_env CRAWL4AI_API_TOKEN    "$(openssl rand -hex 16)"
ensure_env OLLAMA_CHAT_MODEL     "$CHAT_MODEL"
ensure_env EMBEDDING_MODEL       "$EMBED_MODEL"
ensure_env EMBEDDING_DIM         "768"
ensure_env TZ                    "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"

# LightRAG refuses to start without an account. Password is generated;
# the operator can change it later in .env.
if ! grep -q '^LIGHTRAG_AUTH_ACCOUNTS=' "$ENV_FILE" 2>/dev/null; then
  LR_PASS="$(openssl rand -hex 12)"
  echo "LIGHTRAG_AUTH_ACCOUNTS=admin:${LR_PASS}" >> "$ENV_FILE"
  echo "  + LIGHTRAG_AUTH_ACCOUNTS (admin / ${LR_PASS})"
fi

# Placeholders so compose does not warn on first run. cloudflare-setup.sh
# fills the tunnel token; N8N_WEBHOOK_URL becomes the real hostname then.
# Neo4j backs the optional graph profile. Generated now so the
# profile starts without a second trip through this script.
if ! grep -q '^NEO4J_PASSWORD=' "$ENV_FILE" 2>/dev/null; then
  echo "NEO4J_PASSWORD=$(openssl rand -hex 16)" >> "$ENV_FILE"
  echo "  + NEO4J_PASSWORD"
fi
ensure_env NEO4J_USER "neo4j"

ensure_env CLOUDFLARE_TUNNEL_TOKEN ""
ensure_env N8N_WEBHOOK_URL         "http://localhost:5678"
echo ""

# --- Step 4: pull images ----------------------------------------------------
echo "[4/6] Pulling images (several GB — this is the slow step) ..."
docker compose "${COMPOSE_ARGS[@]}" --env-file "$ENV_FILE" pull --quiet 2>&1 | grep -v '^$' || true
echo "  ✓ Images pulled."
echo ""

# --- Step 5: start ----------------------------------------------------------
echo "[5/6] Starting services ..."

# cloudflared is skipped until it has a real token — it crash-loops on an
# empty one, which looks alarming and obscures real errors.
TUNNEL_TOKEN=$(grep '^CLOUDFLARE_TUNNEL_TOKEN=' "$ENV_FILE" | cut -d= -f2-)
if [ -z "$TUNNEL_TOKEN" ]; then
  echo "  (skipping cloudflared — no tunnel token yet; onboard.sh sets it)"
  docker compose "${COMPOSE_ARGS[@]}" --env-file "$ENV_FILE" up -d \
    ollama open-webui n8n crawl4ai lightrag
else
  docker compose "${COMPOSE_ARGS[@]}" --env-file "$ENV_FILE" up -d
fi
echo ""

echo "  Waiting for Ollama to report healthy (up to 3 minutes) ..."
for i in $(seq 1 36); do
  if docker inspect --format '{{.State.Health.Status}}' ollama 2>/dev/null | grep -q healthy; then
    echo "  ✓ Ollama healthy."
    break
  fi
  if [ "$i" -eq 36 ]; then
    echo "  ✗ Ollama did not become healthy in time."
    echo "    Check: docker logs ollama"
    exit 1
  fi
  sleep 5
done
echo ""

# --- Step 6: models ---------------------------------------------------------
echo "[6/6] Pulling models ..."
if [ "$HAS_GPU" -eq 1 ]; then
  echo "  - $CHAT_MODEL (several GB)"
  docker exec ollama ollama pull "$CHAT_MODEL"
else
  # Not pulled on CPU. It is a ~9GB download for something that answers at a
  # few tokens per second — a slow, expensive disappointment rather than a
  # working default. The embedding model is different: it is small and fast
  # enough on CPU to be genuinely useful, and LightRAG needs it.
  echo "  - skipping $CHAT_MODEL (no GPU: ~9GB for a few tokens/sec)"
  echo "    To pull it anyway:  docker exec ollama ollama pull $CHAT_MODEL"
  echo "    A smaller option:   docker exec ollama ollama pull llama3.2:1b"
fi
echo "  - $EMBED_MODEL"
docker exec ollama ollama pull "$EMBED_MODEL"
echo ""

echo "################################################################"
echo "#  Stack is up."
echo "################################################################"
echo ""
if [ "$HAS_GPU" -eq 0 ]; then
  echo "----------------------------------------------------------------"
  echo "  Running on CPU — no chat model was pulled."
  echo ""
  echo "  n8n, Open WebUI, crawl4ai and the tunnel work exactly the same."
  echo "  For the AI nodes, point n8n at a provider instead of local Ollama:"
  echo "    onboard.sh stage 4, or Settings → Credentials → New in n8n."
  echo ""
  echo "  LightRAG is configured for a local model and will error until one"
  echo "  exists. Either pull a small one:"
  echo "      docker exec ollama ollama pull llama3.2:1b"
  echo "      sed -i 's|^OLLAMA_CHAT_MODEL=.*|OLLAMA_CHAT_MODEL=llama3.2:1b|' .env"
  echo "      docker compose \"\${COMPOSE_ARGS[@]}\" up -d lightrag"
  echo "  or leave LightRAG unused."
  echo "----------------------------------------------------------------"
  echo ""
fi

echo "Local URLs (bound to localhost — the tunnel makes them public):"
echo "  Open WebUI   http://localhost:8080"
echo "  n8n          http://localhost:5678"
echo "  LightRAG     http://localhost:9621"
echo "  crawl4ai     http://localhost:11235"
echo ""
echo "Optional extras:"
echo "  Graph intelligence: docker compose -f $COMPOSE_FILE --profile graph up -d"
echo "  RSS feeds:         docker compose -f $COMPOSE_FILE --profile feeds up -d"
echo ""
echo "Next: connect it to the internet and wire up credentials."
echo ""
echo "  bash $SCRIPT_DIR/onboard.sh <client-name> <your-domain> n8n:5678 open-webui:8080"
echo ""
echo "That handles, in the only order that works:"
echo "  1. Cloudflare Tunnel   (public hostnames)"
echo "  2. n8n API key"
echo "  3. Google OAuth        (needs the hostname from step 1)"
echo "  4. LLM credential      (wires Ollama into n8n)"
echo "  5. SearchByAI listing  (optional)"
echo "################################################################"
