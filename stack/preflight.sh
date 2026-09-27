#!/usr/bin/env bash
# ==============================================================================
# preflight.sh — check this machine before installing anything
#
#   bash <(curl -fsSL https://searchbyai.com/stack/preflight.sh)
#
# Reports what is present, what is missing, and which install path fits. Offers
# to install Docker if it is absent — nothing else, and nothing without asking.
#
# Read-only unless you say yes to a prompt. Safe to run repeatedly.
# ==============================================================================
set -uo pipefail

BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
RESET=$(printf '\033[0m')

ok()   { echo "  ${GREEN}✓${RESET} $*"; }
warn() { echo "  ${YELLOW}!${RESET} $*"; }
bad()  { echo "  ${RED}✗${RESET} $*"; }
info() { echo "    ${DIM}$*${RESET}"; }

BLOCKERS=0
HAS_GPU=0
HAS_DOCKER=0

echo ""
echo "${BOLD}AI stack — preflight${RESET}"
echo "${DIM}Checking this machine. Nothing is installed unless you say so.${RESET}"
echo ""

# --- OS -----------------------------------------------------------------------
echo "${BOLD}System${RESET}"
OS=$(uname -s)
if [ "$OS" = "Linux" ]; then
  DISTRO=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
  ok "$DISTRO"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    info "WSL detected — fine, but GPU passthrough needs WSL2 + NVIDIA's WSL driver"
  fi
else
  bad "$OS is not supported. This stack needs Linux."
  info "macOS has no NVIDIA GPU. Windows: install WSL2 and run this inside it."
  BLOCKERS=$((BLOCKERS+1))
fi

# RAM and disk are soft checks: low values work, they just work badly.
RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$RAM_GB" -ge 8 ] 2>/dev/null; then ok "RAM: ${RAM_GB}GB"
elif [ "$RAM_GB" -gt 0 ] 2>/dev/null; then warn "RAM: ${RAM_GB}GB — 8GB+ recommended"
fi

DISK_GB=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
if [ "${DISK_GB:-0}" -ge 40 ] 2>/dev/null; then ok "Disk free: ${DISK_GB}GB"
elif [ "${DISK_GB:-0}" -gt 0 ] 2>/dev/null; then warn "Disk free: ${DISK_GB}GB — 40GB+ recommended"
fi
echo ""

# --- Docker -------------------------------------------------------------------
echo "${BOLD}Docker${RESET}"
if command -v docker >/dev/null 2>&1; then
  ok "docker $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if docker compose version >/dev/null 2>&1; then
    ok "docker compose $(docker compose version --short 2>/dev/null)"
  else
    bad "docker compose v2 missing — the old docker-compose script will not work"
    BLOCKERS=$((BLOCKERS+1))
  fi
  # Must be usable without sudo, or every later command breaks.
  if docker info >/dev/null 2>&1; then
    ok "docker usable as $(whoami)"
    HAS_DOCKER=1
  else
    bad "cannot reach the Docker daemon as $(whoami)"
    info "Either it is stopped:  sudo systemctl start docker"
    info "Or you are not in the group:  sudo usermod -aG docker \$USER"
    info "Then log out and back in — group changes need a new session."
    BLOCKERS=$((BLOCKERS+1))
  fi
else
  bad "docker is not installed"
  BLOCKERS=$((BLOCKERS+1))
fi
echo ""

# --- GPU ----------------------------------------------------------------------
echo "${BOLD}GPU${RESET}"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  ok "$GPU_NAME (${VRAM_MB}MB)"

  # The container toolkit is a separate install from the driver. Enabling the
  # GPU without it produces a container that will not start — worse than the
  # cloud build, because it looks broken rather than slow.
  if [ "$HAS_DOCKER" -eq 1 ] && docker info 2>/dev/null | grep -qi 'Runtimes.*nvidia'; then
    if [ "${VRAM_MB:-0}" -ge 8000 ] 2>/dev/null; then
      ok "NVIDIA container toolkit registered"
      HAS_GPU=1
    else
      warn "under 8GB VRAM — the model would spill to system RAM"
      info "Using the cloud build instead."
    fi
  else
    warn "NVIDIA container toolkit not registered with Docker"
    info "The driver alone is not enough. Install the toolkit:"
    info "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
    info "  sudo nvidia-ctk runtime configure --runtime=docker"
    info "  sudo systemctl restart docker"
    info "Until then, the cloud build is used."
  fi
else
  info "No NVIDIA GPU — the cloud build calls an API provider instead."
fi
echo ""

# --- tools --------------------------------------------------------------------
echo "${BOLD}Tools${RESET}"
for t in curl jq openssl crontab; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"
  else
    warn "$t missing"
    [ "$t" = "jq" ] && info "Needed only to list a node on SearchByAI:  sudo apt install jq"
  fi
done
# Optional, and deliberately labelled as such: people assume anything listed
# in a preflight is required.
if command -v claude >/dev/null 2>&1; then
  ok "claude $(claude --version 2>/dev/null | head -1) ${DIM}(optional)${RESET}"
else
  info "Claude Code not installed — optional. Only needed if you want an agent"
  info "to run the install for you:  curl -fsSL https://claude.ai/install.sh | bash"
fi
echo ""

# --- verdict ------------------------------------------------------------------
echo "${BOLD}Verdict${RESET}"
if [ "$BLOCKERS" -gt 0 ]; then
  bad "$BLOCKERS blocker(s) above. Fix those first."
  if ! command -v docker >/dev/null 2>&1 && [ "$OS" = "Linux" ]; then
    echo ""
    printf "  Install Docker now? [y/N] "
    if [ -t 0 ]; then read -r REPLY || REPLY=n; else REPLY=n; fi
    if [ "${REPLY:-n}" = "y" ] || [ "${REPLY:-n}" = "Y" ]; then
      echo ""
      curl -fsSL https://get.docker.com | sh || { bad "Docker install failed."; exit 1; }
      sudo usermod -aG docker "$USER" 2>/dev/null || true
      echo ""
      ok "Docker installed."
      warn "Log out and back in, then run this again — group changes need a new session."
    fi
  fi
  echo ""
  exit 1
fi

if [ "$HAS_GPU" -eq 1 ]; then
  ok "Ready. ${BOLD}gpu build${RESET} — models run locally."
else
  ok "Ready. ${BOLD}cloud build${RESET} — you will need one API key."
  info "Anthropic, OpenAI or Gemini. The installer asks."
fi

echo ""
echo "${BOLD}Before you run the installer${RESET}"
echo ""
echo "  Two things only you can do, and one takes up to 24 hours:"
echo ""
echo "  ${BOLD}A. A public hostname${RESET} — pick one:"
echo "     • Your own domain, added to Cloudflare and showing Active"
echo "     • Or a free Tailscale Funnel hostname (no domain, no open ports)"
echo ""
echo "  ${BOLD}B. A Google Cloud account${RESET} — free, no card, and optional."
echo "     Only needed for n8n's Gmail, Drive, Sheets and Calendar nodes,"
echo "     and only works with your own domain."
echo ""
echo "  Full walkthrough:  ${BOLD}https://searchbyai.com/PREREQUISITES.md${RESET}"
echo ""
echo "  Then:"
echo "    curl -fsSL https://searchbyai.com/stack/install-stack.sh -o install-stack.sh"
echo "    bash install-stack.sh"
echo ""
