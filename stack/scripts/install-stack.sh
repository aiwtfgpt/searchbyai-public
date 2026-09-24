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
  echo "  ! No NVIDIA GPU detected — installing the cloud build."
  echo "    n8n, Open WebUI, LightRAG and crawl4ai all work the same; they"
  echo "    call your API provider instead of a local model. You will be"
  echo "    asked for one key in a moment."
fi

if [ "$MISSING" -ne 0 ]; then
  echo ""
  echo "Fix the items marked ✗ above, then run this script again."
  exit 1
fi
echo ""

# --- Step 2: compose file ---------------------------------------------------
echo "[2/6] Checking compose file ..."
# GPU present -> the local-inference build. No GPU -> the cloud build, which
# has no Ollama at all. CPU inference is deliberately not an option: a 9GB
# model at a few tokens per second is worse than an API key and pins the
# machine while it runs.
if [ "$HAS_GPU" -eq 1 ]; then
  COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
  [ -f "$COMPOSE_FILE" ] || COMPOSE_FILE="$INSTALL_DIR/docker-compose.single-gpu.yml"
  BUILD="gpu"
else
  COMPOSE_FILE="$INSTALL_DIR/docker-compose.cloud.yml"
  BUILD="cloud"
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "  ✗ Not found: $(basename "$COMPOSE_FILE")"
  echo "    Download it:"
  if [ "$BUILD" = "cloud" ]; then
    echo "      curl -fsSL https://searchbyai.com/stack/docker-compose.cloud.yml -o docker-compose.cloud.yml"
  else
    echo "      curl -fsSL https://searchbyai.com/stack/docker-compose.yml -o docker-compose.yml"
  fi
  exit 1
fi
echo "  ✓ $(basename "$COMPOSE_FILE") ($BUILD build)"

COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [ "$HAS_GPU" -eq 1 ]; then
  GPU_FILE="$INSTALL_DIR/docker-compose.gpu.yml"
  if [ -f "$GPU_FILE" ]; then
    COMPOSE_ARGS+=(-f "$GPU_FILE")
    echo "  ✓ GPU override applied"
  else
    echo "  ! docker-compose.gpu.yml missing — Ollama would run on CPU."
    echo "    Download it: curl -fsSL https://searchbyai.com/stack/docker-compose.gpu.yml -o docker-compose.gpu.yml"
    exit 1
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

# --- provider key, cloud build only ------------------------------------------
# One key drives Open WebUI, n8n and LightRAG. All three providers publish an
# OpenAI-compatible endpoint, so a single LLM_BASE_URL / LLM_API_KEY pair
# covers them and the rest of the compose needs no branching.
if [ "$BUILD" = "cloud" ] && ! grep -q '^LLM_API_KEY=.\+' "$ENV_FILE" 2>/dev/null; then
  echo ""
  echo "  No GPU, so nothing runs a model locally. Pick a provider:"
  echo ""
  echo "    1) Anthropic   console.anthropic.com/settings/keys"
  echo "    2) OpenAI      platform.openai.com/api-keys"
  echo "    3) Gemini      aistudio.google.com/apikey"
  echo "    4) Skip        set it later in .env"
  echo ""
  printf "  Choice [1-4]: "
  # -t 0 is the reliable check: /dev/tty can exist and still not be
  # readable in a container or a piped shell.
  if [ -t 0 ]; then read -r PROVIDER || PROVIDER=4; else PROVIDER=4; fi

  case "$PROVIDER" in
    1) P_NAME="Anthropic"; P_VAR="ANTHROPIC_API_KEY"
       P_URL="https://api.anthropic.com/v1"; P_MODEL="claude-sonnet-4-5" ;;
    2) P_NAME="OpenAI";    P_VAR="OPENAI_API_KEY"
       P_URL="https://api.openai.com/v1";    P_MODEL="gpt-4o-mini" ;;
    3) P_NAME="Gemini";    P_VAR="GEMINI_API_KEY"
       P_URL="https://generativelanguage.googleapis.com/v1beta/openai"
       P_MODEL="gemini-2.0-flash" ;;
    *) P_NAME=""; ;;
  esac

  if [ -n "$P_NAME" ]; then
    printf "  Paste your %s API key: " "$P_NAME"
    if [ -t 0 ]; then read -r P_KEY || P_KEY=""; else P_KEY=""; fi
    if [ -n "$P_KEY" ]; then
      {
        echo "${P_VAR}=${P_KEY}"
        echo "LLM_BASE_URL=${P_URL}"
        echo "LLM_API_KEY=${P_KEY}"
        echo "LLM_MODEL=${P_MODEL}"
      } >> "$ENV_FILE"
      echo "  + ${P_VAR}, LLM_BASE_URL, LLM_API_KEY, LLM_MODEL"
    else
      P_NAME=""
    fi
  fi

  if [ -z "$P_NAME" ]; then
    # Placeholders so compose does not warn. Nothing calls a model until
    # these are real.
    ensure_env LLM_BASE_URL "https://api.anthropic.com/v1"
    ensure_env LLM_API_KEY  ""
    ensure_env LLM_MODEL    "claude-sonnet-4-5"
    echo "  ! No key set. Add LLM_API_KEY to .env before the AI nodes work."
  fi
  echo ""
fi

ensure_env WEBUI_SECRET_KEY      "$(openssl rand -hex 32)"
ensure_env LIGHTRAG_TOKEN_SECRET "$(openssl rand -hex 32)"
ensure_env CRAWL4AI_API_TOKEN    "$(openssl rand -hex 16)"
if [ "$BUILD" = "gpu" ]; then ensure_env OLLAMA_CHAT_MODEL "$CHAT_MODEL"; fi
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
  if [ "$BUILD" = "gpu" ]; then
    docker compose "${COMPOSE_ARGS[@]}" --env-file "$ENV_FILE" up -d \
      ollama open-webui n8n crawl4ai lightrag
  else
    docker compose "${COMPOSE_ARGS[@]}" --env-file "$ENV_FILE" up -d \
      open-webui n8n crawl4ai lightrag
  fi
else
  docker compose "${COMPOSE_ARGS[@]}" --env-file "$ENV_FILE" up -d
fi
echo ""

if [ "$BUILD" = "gpu" ]; then
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
fi
echo ""

# --- Step 6: models ---------------------------------------------------------
if [ "$BUILD" = "gpu" ]; then
  echo "[6/6] Pulling models ..."
  echo "  - $CHAT_MODEL (several GB)"
  docker exec ollama ollama pull "$CHAT_MODEL"
  echo "  - $EMBED_MODEL"
  docker exec ollama ollama pull "$EMBED_MODEL"
else
  echo "[6/6] No local models — this build calls your provider."
fi
echo ""

echo "################################################################"
echo "#  Stack is up."
echo "################################################################"
echo ""
echo "Local URLs (bound to localhost — the tunnel makes them public):"
echo "  Open WebUI   http://localhost:8080"
echo "  n8n          http://localhost:5678"
echo "  LightRAG     http://localhost:9621"
echo "  crawl4ai     http://localhost:11235"
echo ""
echo "Optional extras:"
echo "  Graph intelligence: docker compose -f $(basename "$COMPOSE_FILE") --profile graph up -d"
echo "  RSS feeds:          docker compose -f $(basename "$COMPOSE_FILE") --profile feeds up -d"
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
echo ""
echo "----------------------------------------------------------------"
echo "  Once it is reachable, list it so agents can find it"
echo "----------------------------------------------------------------"
echo ""
echo "  SearchByAI is a discovery registry. Agents and people search it,"
echo "  then connect straight to your machine — nothing routes through us,"
echo "  so we never see your requests and never sit in the way."
echo ""
echo "    bash <(curl -fsSL https://searchbyai.com/connect.sh)"
echo ""
echo "  One directory and one cron entry. No sudo, no packages, no daemon."
echo "  You get a verification email; nothing is listed until you click it."
echo ""
echo "  After that, https://searchbyai.com/dashboard signs you in with the"
echo "  same email — edit your listing, set what you charge, and see how"
echo "  many searches you turned up in."
echo ""
echo "################################################################"
