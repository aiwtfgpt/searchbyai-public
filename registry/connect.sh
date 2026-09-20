#!/usr/bin/env bash
# ==============================================================================
# SearchByAI — Node Connect
#
# Registers this machine as a discoverable node.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/connect.sh)
#
# Non-interactive (all prompts can be pre-answered):
#   SBA_NODE_ID=my-node SBA_DISPLAY_NAME="My Node" \
#   SBA_EMAIL=me@example.com SBA_ENDPOINT=https://my.example.com \
#   SBA_CITY=Denver SBA_REGION=CO SBA_COUNTRY=US \
#   SBA_YES=1 bash <(curl -fsSL https://raw.githubusercontent.com/aiwtfgpt/searchbyai-public/main/registry/connect.sh)
#
# Requires: curl, jq, openssl
# Writes:   ~/.searchbyai/{node.json,sign.sh,heartbeat.sh}
# Installs: a cron entry that heartbeats every 5 minutes
# ==============================================================================
set -euo pipefail

HUB="${SBA_HUB:-https://searchbyai.com/api}"
CONFIG_DIR="${HOME}/.searchbyai"
CONFIG_FILE="${CONFIG_DIR}/node.json"

BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
GREEN=$(printf '\033[32m'); RED=$(printf '\033[31m')
YELLOW=$(printf '\033[33m'); RESET=$(printf '\033[0m')

banner() {
  echo ""
  echo "${BOLD}  SearchByAI — connect a node${RESET}"
  echo "${DIM}  Make this machine discoverable to AI agents and humans.${RESET}"
  echo ""
}

die() { echo "${RED}error:${RESET} $*" >&2; exit 1; }
ok()  { echo "${GREEN}  ok${RESET}  $*"; }
warn(){ echo "${YELLOW}  !${RESET}   $*"; }

ask() {
  # ask <var_name> <prompt> [default]
  local var="$1" prompt="$2" default="${3:-}" current answer
  current="$(eval "printf '%s' \"\${$var:-}\"")"
  if [ -n "$current" ]; then
    echo "  ${prompt}: ${current} ${DIM}(from environment)${RESET}"
    return
  fi
  if [ -n "$default" ]; then
    printf '  %s [%s]: ' "$prompt" "$default"
  else
    printf '  %s: ' "$prompt"
  fi
  answer=""
  if [ -r /dev/tty ]; then
    read -r answer </dev/tty || true
  fi
  [ -z "$answer" ] && answer="$default"
  eval "$var=\$answer"
}

# ------------------------------------------------------------------ prereqs
banner
echo "${BOLD}Checking prerequisites${RESET}"
for cmd in curl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed."
done
ok "curl, jq, openssl found"

# ------------------------------------------------- signing self-test
# Same fixed vector the hub verifies against. If this fails, the environment
# produces signatures the hub will reject, and every heartbeat would 401 with
# a message that looks like a wrong secret. Better to stop here.
TEST_SECRET="sba_testnode_000102030405060708090a0b0c0d0e0f1011121314151617"
TEST_BODY='{"node_id":"testnode","version":"1.0.0"}'
TEST_EXPECT="151a1fc23d0601e03cc871577f38226b246a95553ba08c1ad6be7c1edae49400"

# printf, never echo — echo appends a newline and changes the hash.
_bh=$(printf '%s' "$TEST_BODY" | openssl dgst -sha256 -hex | sed 's/^.*= //')
_canon=$(printf '%s\n%s\n%s\n%s\n%s' "POST" "/heartbeat" "1735689600" "0123456789abcdef" "$_bh")
_sig=$(printf '%s' "$_canon" | openssl dgst -sha256 -hmac "$TEST_SECRET" -hex | sed 's/^.*= //')

if [ "$_sig" != "$TEST_EXPECT" ]; then
  echo ""
  die "signing self-test failed.
  expected: $TEST_EXPECT
  got:      $_sig
  This openssl build produces signatures the hub will reject."
fi
ok "signing self-test passed"

# ------------------------------------------------------------ existing node
if [ -f "$CONFIG_FILE" ]; then
  EXISTING_ID=$(jq -r '.node_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [ -n "$EXISTING_ID" ]; then
    warn "this machine is already registered as '${EXISTING_ID}'"
    echo "      ${DIM}config: ${CONFIG_FILE}${RESET}"
    echo ""
    if [ "${SBA_YES:-0}" != "1" ]; then
      printf '  Register a second node anyway? [y/N]: '
      again=""
      [ -r /dev/tty ] && { read -r again </dev/tty || true; }
      case "$again" in [Yy]*) ;; *) echo "  Nothing changed."; exit 0 ;; esac
    fi
  fi
fi

# ------------------------------------------------------------------ identity
echo ""
echo "${BOLD}About this node${RESET}"
DEFAULT_ID=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//' || echo "my-node")
ask SBA_NODE_ID      "Node id (lowercase, url-safe)" "$DEFAULT_ID"
ask SBA_DISPLAY_NAME "Display name"                  "$SBA_NODE_ID"
ask SBA_TAGLINE      "One-line description"          ""
ask SBA_EMAIL        "Owner email (gets the verification link)"
ask SBA_ENDPOINT     "Public base URL for this node"

[ -n "${SBA_NODE_ID:-}" ]  || die "node id is required"
[ -n "${SBA_EMAIL:-}" ]    || die "owner email is required"
if [ -z "${SBA_ENDPOINT:-}" ]; then
  echo ""
  echo "${BOLD}No endpoint yet?${RESET}"
  echo "${DIM}  This registry lists endpoints you already run — it does not"
  echo "  install anything beyond a heartbeat."
  echo ""
  echo "  If you have no stack yet, there is a separate installer that sets"
  echo "  up Ollama, Open WebUI, n8n, LightRAG and a Cloudflare tunnel, then"
  echo "  walks you through the credentials:"
  echo "      https://searchbyai.com/stack"
  echo ""
  echo "  Run this again once something is serving.${RESET}"
  echo ""
  die "endpoint URL is required"
fi

case "$SBA_ENDPOINT" in
  http://*|https://*) ;;
  *) die "endpoint must start with http:// or https://" ;;
esac

# ------------------------------------------------------------------ location
echo ""
echo "${BOLD}Location${RESET}"
echo "${DIM}  Used so agents can find nearby nodes. Stored to about 1km — never${RESET}"
echo "${DIM}  a street address. Leave city blank if you serve everywhere.${RESET}"
ask SBA_CITY    "City (blank = serve globally)" ""
if [ -n "${SBA_CITY:-}" ]; then
  ask SBA_REGION  "State / region" ""
  ask SBA_COUNTRY "Country code"   "US"
  ask SBA_RADIUS  "Service radius in km (blank = not location-bound)" ""
  PRECISION="city"
else
  SBA_REGION=""; SBA_COUNTRY="${SBA_COUNTRY:-US}"; SBA_RADIUS=""
  PRECISION="global"
fi

# -------------------------------------------------------------- capabilities
echo ""
echo "${BOLD}What does this node offer?${RESET}"
echo "${DIM}  Only list things that actually work. An unreachable capability${RESET}"
echo "${DIM}  is worse than no listing.${RESET}"
echo ""

CAPS="[]"

add_cap() { CAPS=$(echo "$CAPS" | jq -c ". += [$1]"); }

# --- MCP ---
if [ "${SBA_YES:-0}" != "1" ]; then
  printf '  Does it expose an MCP server? [y/N]: '
  has_mcp=""
  [ -r /dev/tty ] && { read -r has_mcp </dev/tty || true; }
else
  has_mcp="${SBA_HAS_MCP:-n}"
fi
case "$has_mcp" in [Yy]*)
  ask SBA_MCP_NAME  "  MCP server name" "${SBA_NODE_ID}-mcp"
  ask SBA_MCP_URL   "  MCP URL" "${SBA_ENDPOINT}/mcp"
  ask SBA_MCP_TOOLS "  Tool names (comma separated)" ""
  ask SBA_MCP_PERMS "  Permissions (comma separated)" "read:public"
  TOOLS=$(echo "${SBA_MCP_TOOLS:-}" | jq -Rc 'split(",") | map(select(length>0) | ltrimstr(" ") | rtrimstr(" "))')
  PERMS=$(echo "${SBA_MCP_PERMS:-read:public}" | jq -Rc 'split(",") | map(select(length>0) | ltrimstr(" ") | rtrimstr(" "))')
  add_cap "$(jq -nc --arg n "$SBA_MCP_NAME" --arg u "$SBA_MCP_URL" \
    --argjson t "$TOOLS" --argjson p "$PERMS" \
    '{kind:"mcp",name:$n,invocation:{transport:"streamable-http",url:$u,tools:$t},
      auth:{type:"none"},permissions:$p}')"
  ;;
esac

# --- API ---
if [ "${SBA_YES:-0}" != "1" ]; then
  printf '  Does it expose an HTTP API? [y/N]: '
  has_api=""
  [ -r /dev/tty ] && { read -r has_api </dev/tty || true; }
else
  has_api="${SBA_HAS_API:-n}"
fi
case "$has_api" in [Yy]*)
  ask SBA_API_NAME   "  Endpoint name" "main"
  ask SBA_API_PATH   "  Path (e.g. /v1/generate)" "/"
  ask SBA_API_METHOD "  Method" "POST"
  ask SBA_API_DESC   "  What it does" ""
  ask SBA_API_PERMS  "  Permissions (comma separated)" "read:public"
  PERMS=$(echo "${SBA_API_PERMS:-read:public}" | jq -Rc 'split(",") | map(select(length>0) | ltrimstr(" ") | rtrimstr(" "))')
  add_cap "$(jq -nc --arg n "$SBA_API_NAME" --arg p "$SBA_API_PATH" \
    --arg m "$SBA_API_METHOD" --arg d "$SBA_API_DESC" --argjson perms "$PERMS" \
    '{kind:"api",name:$n,description:$d,
      invocation:{method:$m,path:$p,content_type:"application/json"},
      auth:{type:"none"},permissions:$perms}')"
  ;;
esac

# --- CLI ---
if [ "${SBA_YES:-0}" != "1" ]; then
  printf '  Does it provide a CLI tool? [y/N]: '
  has_cli=""
  [ -r /dev/tty ] && { read -r has_cli </dev/tty || true; }
else
  has_cli="${SBA_HAS_CLI:-n}"
fi
case "$has_cli" in [Yy]*)
  ask SBA_CLI_NAME    "  Command name" ""
  ask SBA_CLI_INSTALL "  Install command" ""
  ask SBA_CLI_USAGE   "  Example usage" ""
  ask SBA_CLI_PERMS   "  Permissions (comma separated)" "read:filesystem"
  PERMS=$(echo "${SBA_CLI_PERMS:-read:filesystem}" | jq -Rc 'split(",") | map(select(length>0) | ltrimstr(" ") | rtrimstr(" "))')
  add_cap "$(jq -nc --arg n "$SBA_CLI_NAME" --arg i "$SBA_CLI_INSTALL" \
    --arg c "$SBA_CLI_USAGE" --argjson p "$PERMS" \
    '{kind:"cli",name:$n,invocation:{install:$i,command:$c},
      auth:{type:"none"},permissions:$p}')"
  ;;
esac

if [ "$(echo "$CAPS" | jq 'length')" -eq 0 ]; then
  warn "no capabilities declared — the node will list with nothing to offer"
fi

# ---------------------------------------------------------------- manifest
RADIUS_JSON="null"
[ -n "${SBA_RADIUS:-}" ] && RADIUS_JSON="$SBA_RADIUS"

MANIFEST=$(jq -nc \
  --arg id "$SBA_NODE_ID" --arg name "$SBA_DISPLAY_NAME" \
  --arg tag "${SBA_TAGLINE:-}" --arg email "$SBA_EMAIL" \
  --arg endpoint "$SBA_ENDPOINT" --arg city "${SBA_CITY:-}" \
  --arg region "${SBA_REGION:-}" --arg country "${SBA_COUNTRY:-US}" \
  --arg precision "$PRECISION" --argjson radius "$RADIUS_JSON" \
  --argjson caps "$CAPS" \
  '{manifest_version:"1.0",
    node:{id:$id,display_name:$name,tagline:$tag,owner_email:$email,
          endpoint_url:$endpoint,routing:"direct",
          location:{city:$city,region:$region,country:$country,
                    precision:$precision,service_radius_km:$radius},
          tags:[]},
    capabilities:$caps,
    page:{},
    proof:{method:"well_known"}}')

echo ""
echo "${BOLD}Manifest${RESET}"
echo "$MANIFEST" | jq .
echo ""

if [ "${SBA_YES:-0}" != "1" ]; then
  printf '  Register this node? [Y/n]: '
  confirm=""
  [ -r /dev/tty ] && { read -r confirm </dev/tty || true; }
  case "$confirm" in [Nn]*) echo "  Cancelled."; exit 0 ;; esac
fi

# ---------------------------------------------------------------- register
echo ""
echo "${BOLD}Registering${RESET}"

RESPONSE=$(curl -sS -X POST "${HUB}/register" \
  -H 'Content-Type: application/json' -d "$MANIFEST" \
  -w '\n%{http_code}') || die "could not reach the hub at ${HUB}"

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "200" ]; then
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
  die "registration failed (HTTP $HTTP_CODE)"
fi

NODE_ID=$(echo "$BODY" | jq -r '.node_id')
NODE_SECRET=$(echo "$BODY" | jq -r '.node_secret')
CHALLENGE=$(echo "$BODY" | jq -r '.proof.well_known_content // empty')
PAGE_URL=$(echo "$BODY" | jq -r '.page_url')

ok "registered as '${NODE_ID}'"

# ------------------------------------------------------------------- config
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

jq -nc --arg id "$NODE_ID" --arg secret "$NODE_SECRET" --arg hub "$HUB" \
  '{node_id:$id,node_secret:$secret,hub:$hub}' > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
ok "credentials saved to ${CONFIG_FILE} (mode 600)"

# ------------------------------------------------------------------- signer
cat > "${CONFIG_DIR}/sign.sh" <<'SIGNER'
#!/usr/bin/env bash
# Emit SearchByAI auth headers for a request.
# Usage: sign.sh <METHOD> <path> [body]   -> prints curl -H args
set -euo pipefail
CONFIG="${HOME}/.searchbyai/node.json"
[ -f "$CONFIG" ] || { echo "no config at $CONFIG" >&2; exit 1; }
SECRET=$(jq -r '.node_secret' "$CONFIG")
NODE_ID=$(jq -r '.node_id' "$CONFIG")
METHOD="$1"; SBA_PATH="$2"; BODY="${3:-}"
TS=$(date +%s)
NONCE=$(openssl rand -hex 16)
# printf, NOT echo — echo appends a newline and invalidates the signature.
BH=$(printf '%s' "$BODY" | openssl dgst -sha256 -hex | sed 's/^.*= //')
CANON=$(printf '%s\n%s\n%s\n%s\n%s' "$METHOD" "$SBA_PATH" "$TS" "$NONCE" "$BH")
SIG=$(printf '%s' "$CANON" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.*= //')
printf -- '-H\nX-SBA-Node-Id: %s\n-H\nX-SBA-Timestamp: %s\n-H\nX-SBA-Nonce: %s\n-H\nX-SBA-Signature: %s\n' \
  "$NODE_ID" "$TS" "$NONCE" "$SIG"
SIGNER
chmod 700 "${CONFIG_DIR}/sign.sh"
ok "signer written to ${CONFIG_DIR}/sign.sh"

# ---------------------------------------------------------------- heartbeat
cat > "${CONFIG_DIR}/heartbeat.sh" <<'HEARTBEAT'
#!/usr/bin/env bash
# Tell SearchByAI this node is alive. Run every 5 minutes from cron.
set -euo pipefail
CONFIG="${HOME}/.searchbyai/node.json"
[ -f "$CONFIG" ] || exit 0
HUB=$(jq -r '.hub' "$CONFIG")
NODE_ID=$(jq -r '.node_id' "$CONFIG")
BODY=$(jq -nc --arg id "$NODE_ID" '{node_id:$id,version:"1.0.0"}')
mapfile -t HEADERS < <("${HOME}/.searchbyai/sign.sh" POST /heartbeat "$BODY")
curl -sS -X POST "${HUB}/heartbeat" "${HEADERS[@]}" \
  -H 'Content-Type: application/json' -d "$BODY" -o /dev/null \
  || echo "$(date -Iseconds) heartbeat failed" >> "${HOME}/.searchbyai/heartbeat.log"
HEARTBEAT
chmod 700 "${CONFIG_DIR}/heartbeat.sh"
ok "heartbeat script written"

# --------------------------------------------------------------------- cron
CRON_LINE="*/5 * * * * ${CONFIG_DIR}/heartbeat.sh >/dev/null 2>&1"
if crontab -l 2>/dev/null | grep -qF "${CONFIG_DIR}/heartbeat.sh"; then
  ok "heartbeat cron already installed"
else
  (crontab -l 2>/dev/null || true; echo "$CRON_LINE") | crontab - \
    && ok "heartbeat cron installed (every 5 minutes)" \
    || warn "could not install cron — add this line yourself:
      ${CRON_LINE}"
fi

# -------------------------------------------------------------------- proof
if [ -n "$CHALLENGE" ]; then
  echo ""
  echo "${BOLD}Endpoint verification${RESET}"
  echo "  Serve this exact content at:"
  echo "    ${BOLD}${SBA_ENDPOINT}/.well-known/searchbyai.txt${RESET}"
  echo ""
  echo "    ${CHALLENGE}"
  echo ""
  echo "  ${DIM}Then run:${RESET}"
  echo "    curl -X POST ${HUB}/nodes/${NODE_ID}/verify-endpoint"
  echo ""
  echo "  ${DIM}Optional — without it your trust score is capped at 40.${RESET}"

  WELLKNOWN_DIR="${SBA_WELLKNOWN_DIR:-}"
  if [ -n "$WELLKNOWN_DIR" ] && [ -d "$WELLKNOWN_DIR" ]; then
    printf '%s\n' "$CHALLENGE" > "${WELLKNOWN_DIR}/searchbyai.txt"
    ok "challenge written to ${WELLKNOWN_DIR}/searchbyai.txt"
  fi
fi

# ------------------------------------------------------------------- finish
echo ""
echo "${BOLD}${GREEN}Registered.${RESET}"
echo ""
echo "  Node id:   ${BOLD}${NODE_ID}${RESET}"
echo "  Page:      ${PAGE_URL}"
echo "  Config:    ${CONFIG_FILE}"
echo ""
echo "  ${BOLD}Check your email${RESET} — ${SBA_EMAIL}"
echo "  ${DIM}Your node stays hidden from search until you click that link.${RESET}"
echo ""
echo "  ${DIM}Keep ${CONFIG_FILE} safe. The secret is not recoverable.${RESET}"
echo ""
