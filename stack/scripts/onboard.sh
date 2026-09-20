#!/usr/bin/env bash
# ==============================================================================
# onboard.sh — Guided credential setup, in the correct order
#
# Run this after the stack is up (install-stack.sh for the single-GPU
# build, or docker-compose.client.yml's "sonny" tier) — the core services
# must be running, even if not yet reachable from the internet.
#
# Order matters and is enforced by this script:
#   1. Cloudflare Tunnel  — nothing else has a real hostname until this runs
#   2. n8n API key        — simple, no external dependency, generated inside
#                            n8n itself once it's reachable
#   3. Google OAuth        — needs the real hostname from step 1; the
#                            redirect URI cannot be correct before that
#   4. LLM credential      — detects local Ollama and wires it into n8n;
#                            only asks for a key if there is no local model
#   5. SearchByAI listing  — optional; needs the endpoints that exist only
#                            once the four stages above are done
#
# This script is a guide, not a black box — each stage hands off to one of
# the two other scripts in this directory, which you can also run
# independently once you understand what they do.
#
# Usage:
#   bash onboard.sh <client-name> <your-domain> <service:port> [service:port ...]
#
# Example:
#   bash onboard.sh acme acme.com n8n:5678 open-webui:8080
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLIENT_NAME="${1:-}"
DOMAIN="${2:-}"
shift 2 2>/dev/null || true
SERVICES=("$@")

if [ -z "$CLIENT_NAME" ] || [ -z "$DOMAIN" ] || [ ${#SERVICES[@]} -eq 0 ]; then
  echo "Usage: bash onboard.sh <client-name> <domain> <service:port> [service:port ...]"
  echo "Example: bash onboard.sh acme acme.com n8n:5678 open-webui:8080"
  exit 1
fi

# Find the n8n service:port pair among the arguments, since step 3 needs
# n8n's specific hostname, not just "the domain."
N8N_HOSTNAME=""
for svc in "${SERVICES[@]}"; do
  if [[ "$svc" == n8n:* ]]; then
    N8N_HOSTNAME="n8n.$DOMAIN"
  fi
done

echo "################################################################"
echo "#  Onboarding: $CLIENT_NAME"
echo "#  Domain:     $DOMAIN"
echo "#  Services:   ${SERVICES[*]}"
echo "################################################################"
echo ""

# --- Stage 1: Cloudflare --------------------------------------------------
echo "================================================================"
echo "  STAGE 1 of 5 — Cloudflare Tunnel"
echo "================================================================"
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo ""
  echo "Before this can run, you need a Cloudflare API token."
  echo "Full instructions are in the header comment of:"
  echo "  $SCRIPT_DIR/cloudflare-setup.sh"
  echo ""
  echo "Once you have a token, run:"
  echo "  echo \"CLOUDFLARE_API_TOKEN=your-token-here\" >> .env"
  echo "  source .env"
  echo "  bash $SCRIPT_DIR/onboard.sh $CLIENT_NAME $DOMAIN ${SERVICES[*]}"
  echo ""
  echo "(Re-running this script picks up right where you left off — nothing"
  echo " from stage 1 needs to be redone if it already succeeded.)"
  exit 1
fi

bash "$SCRIPT_DIR/cloudflare-setup.sh" "$CLIENT_NAME" "$DOMAIN" "${SERVICES[@]}"
echo ""
echo "Stage 1 complete."
echo ""

# --- Stage 2: n8n API key --------------------------------------------------
echo "================================================================"
echo "  STAGE 2 of 5 — n8n API key"
echo "================================================================"
echo ""
if [ -z "$N8N_HOSTNAME" ]; then
  echo "No 'n8n:PORT' service was given, so skipping this stage — n8n isn't"
  echo "part of this install."
else
  if [ -z "${N8N_API_KEY:-}" ]; then
    echo "n8n should now be reachable at: https://$N8N_HOSTNAME"
    echo "(DNS may still be propagating — if this doesn't load yet, wait a"
    echo " few minutes and refresh.)"
    echo ""
    echo "To create the API key:"
    echo "  1. Open https://$N8N_HOSTNAME and log in (or create the admin"
    echo "     account if this is the first visit)."
    echo "  2. Click the icon in the bottom-left corner showing your"
    echo "     initials → Settings → n8n API"
    echo "  3. Click 'Create an API key'"
    echo "  4. Name it whatever you want (e.g. '$CLIENT_NAME onboarding')"
    echo "  5. Set it to never expire"
    echo "  6. Click Create, then copy the key shown (it's shown once)"
    echo ""
    echo "Save it locally yourself — type this directly into a terminal on"
    echo "this machine (never paste the key into a chat with any AI,"
    echo "local or remote — it doesn't need to leave this machine):"
    echo "  echo \"N8N_API_KEY=your-key-here\" >> .env"
    echo "  source .env"
    echo "  bash $SCRIPT_DIR/onboard.sh $CLIENT_NAME $DOMAIN ${SERVICES[*]}"
    exit 1
  fi

  echo "Verifying n8n API key ..."
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://$N8N_HOSTNAME/api/v1/workflows?limit=1" -H "X-N8N-API-KEY: $N8N_API_KEY")
  case "$STATUS" in
    200)
      echo "  ✓ n8n API key verified."
      ;;
    401|403)
      # The only status that actually proves a bad key. n8n returns 401
      # for a missing or wrong key, so this is worth stopping on.
      echo "ERROR: n8n rejected the API key (HTTP $STATUS)."
      echo "Re-copy the key — it is shown only once, so a partial paste is"
      echo "the usual cause. Create a fresh one if in doubt."
      exit 1
      ;;
    000)
      echo "ERROR: could not reach https://$N8N_HOSTNAME at all."
      echo "DNS may still be propagating from stage 1, or cloudflared is not"
      echo "running. Check: docker logs cloudflared"
      exit 1
      ;;
    500)
      # n8n classifies a JWT signature failure as a serverError, so a key
      # signed with a secret the instance no longer has returns 500 with a
      # generic body rather than 401. Diagnosed live on 2.38.1, where every
      # existing key broke because N8N_USER_MANAGEMENT_JWT_SECRET was not
      # pinned and regenerated on upgrade.
      echo "ERROR: n8n returned HTTP 500 on the key check."
      echo ""
      echo "This usually means the key was signed with a JWT secret this"
      echo "instance no longer has — n8n reports that as a server error, not"
      echo "a 401, so it looks like a bug rather than a bad credential."
      echo ""
      echo "Fix: pin the secret so it survives restarts and upgrades —"
      echo "  N8N_USER_MANAGEMENT_JWT_SECRET=<a long random string>"
      echo "then restart n8n and create a NEW API key. Existing keys signed"
      echo "with the lost secret cannot be recovered."
      exit 1
      ;;
    *)
      echo "  ! n8n returned HTTP $STATUS on the key check."
      echo "    Unexpected, but not clearly a credential problem. Continuing."
      echo "    Stage 5's endpoint auto-discovery may fall back to manual"
      echo "    entry while this persists."
      ;;
  esac
fi
echo ""
echo "Stage 2 complete."
echo ""

# --- Stage 3: Google OAuth --------------------------------------------------
echo "================================================================"
echo "  STAGE 3 of 5 — Google OAuth (for n8n's Gmail/Drive/Sheets/Docs/"
echo "  Calendar/YouTube nodes)"
echo "================================================================"
echo ""
if [ -z "$N8N_HOSTNAME" ]; then
  echo "No n8n in this install — skipping. If you add n8n later, run:"
  echo "  bash $SCRIPT_DIR/google-oauth-setup.sh n8n.$DOMAIN"
else
  echo "This stage runs in Google Cloud Shell, not here — it needs your"
  echo "Google identity, not this machine's."
  echo ""
  echo "1. Open https://console.cloud.google.com and select or create the"
  echo "   project you want n8n to use."
  echo "2. Click the Cloud Shell icon (top-right, >_ )."
  echo "3. Upload or paste in the contents of:"
  echo "     $SCRIPT_DIR/google-oauth-setup.sh"
  echo "4. Run:"
  echo "     bash google-oauth-setup.sh $N8N_HOSTNAME"
  echo "5. Follow the printed instructions — API enablement is automatic;"
  echo "   the OAuth client creation is one guided manual step (Google"
  echo "   requires a human to do this part, confirmed — no way around it)."
fi
echo ""
echo "Stage 3 complete."
echo ""

# --- Stage 4: LLM credential ------------------------------------------------
echo "================================================================"
echo "  STAGE 4 of 5 — LLM credential for n8n"
echo "================================================================"
echo ""

# Detect before asking. This stack ships Ollama, which needs no API key at
# all — only a base URL. Prompting every operator for a key they do not
# have invites confusion and pasted-in junk.
OLLAMA_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
DETECTED_MODEL=""

if curl -s --max-time 5 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
  # Prefer the model this install configured. Falling back to "first in the
  # list" picks whatever sorts first, which on a box with several models is
  # rarely the one n8n should use.
  DETECTED_MODEL=$(curl -s --max-time 5 "$OLLAMA_URL/api/tags" \
    | OLLAMA_MODEL="${OLLAMA_CHAT_MODEL:-}" python3 -c 'import json,os,sys
try:
    m=json.load(sys.stdin).get("models",[])
    # Embedding models cannot serve chat, so they are never candidates.
    chat=[x["name"] for x in m if "embed" not in x["name"].lower()]
    want=os.environ.get("OLLAMA_MODEL","").strip()
    if want:
        exact=[n for n in chat if n==want]
        # Ollama reports "name:tag"; a configured bare name still matches.
        loose=[n for n in chat if n.split(":")[0]==want.split(":")[0]]
        chat=exact or loose or chat
    print(chat[0] if chat else "")
except Exception:
    print("")' 2>/dev/null)
fi

if [ -n "$DETECTED_MODEL" ]; then
  echo "Detected a local Ollama with chat model:"
  echo "    $DETECTED_MODEL"
  echo ""
  echo "No API key is needed for local models. In n8n, add the credential:"
  echo "  Settings → Credentials → New → search 'Ollama' → Ollama account"
  echo "  Base URL: http://ollama:11434"
  echo ""
  echo "  (Use the container name 'ollama', not localhost — n8n resolves it"
  echo "   on the Docker network. 'localhost' inside the n8n container means"
  echo "   the n8n container itself, and the credential will fail to connect.)"
else
  echo "No local Ollama responded at $OLLAMA_URL."
  echo ""
  echo "If you meant to use the local model, check: docker logs ollama"
  echo ""
  echo "To use an external provider instead, get a key from their dashboard"
  echo "and add it in n8n under Settings → Credentials → New:"
  echo "  OpenAI      https://platform.openai.com/api-keys"
  echo "  Anthropic   https://console.anthropic.com/settings/keys"
  echo "  OpenRouter  https://openrouter.ai/keys"
  echo ""
  echo "Save the key to your own .env as well — never paste it into a chat"
  echo "with any AI, local or remote."
fi
echo ""
echo "Stage 4 complete."
echo ""

# --- Stage 5: SearchByAI listing --------------------------------------------
echo "================================================================"
echo "  STAGE 5 of 5 — List this node on SearchByAI (optional)"
echo "================================================================"
echo ""
echo "SearchByAI is a discovery registry: agents and people search it, then"
echo "connect straight to your node. Traffic does not pass through it."
echo ""
echo "Your endpoints stay behind your own Cloudflare tunnel, so your"
echo "server's IP is not visible to the public. SearchByAI does see the"
echo "address your node heartbeats from — that pin is what stops a stolen"
echo "node secret being used from somewhere else."
echo ""
echo "To list this node:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/connect.sh)"
echo ""
echo "It detects what it can (your LLM, your active n8n webhooks, your"
echo "city from the public IP), shows you the draft listing for approval,"
echo "and registers only what you confirm. Nothing is published without"
echo "you seeing it first."
echo ""
echo "Skip this if you do not want the node discoverable."
echo ""

echo "################################################################"
echo "#  Onboarding for $CLIENT_NAME is set up."
echo "#"
echo "#  Still needing a human: stage 3's OAuth client in Google Cloud"
echo "#  Shell, and stage 4's credential entry in the n8n UI."
echo "################################################################"
