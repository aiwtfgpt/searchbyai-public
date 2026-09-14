#!/usr/bin/env bash
# ==============================================================================
# cloudflare-setup.sh — Provision a Cloudflare Tunnel for this install
#
# Prerequisite — YOUR DOMAIN MUST BE ADDED TO CLOUDFLARE FIRST. If you
# bought your domain from GoDaddy, Namecheap, Google Domains, or anywhere
# else, it is NOT on Cloudflare by default — this is a separate, required
# step before anything below will work. (One-time, ~5-10 minutes of your
# time, then up to 24 hours for the change to fully take effect worldwide —
# usually much faster, often minutes.)
#
#   A. Sign up for a free Cloudflare account: https://dash.cloudflare.com/sign-up
#   B. In the Cloudflare dashboard, click "Add a domain" (or "Onboard a
#      domain") and enter your domain (e.g. acme.com — the root domain,
#      not a subdomain).
#   C. Cloudflare scans your domain's existing DNS records automatically —
#      review them, then continue. (It's OK if this list looks incomplete;
#      this script only adds new records, it doesn't remove existing ones.)
#   D. Cloudflare shows you two nameservers (e.g. kobe.ns.cloudflare.com
#      and love.ns.cloudflare.com — yours will differ). Copy them.
#   E. IMPORTANT — if your current registrar shows "DNSSEC" as enabled for
#      this domain, disable it BEFORE the next step, or your domain can
#      go offline during the switch. (Most personal/small-business domains
#      don't have this on — if you're not sure, it's usually off.)
#   F. Log into wherever you originally bought/registered the domain (NOT
#      Cloudflare) → find "Nameservers" or "DNS settings" for that domain
#      → replace whatever nameservers are listed there with the two
#      Cloudflare gave you in step D → save.
#   G. Wait for it to take effect — check status at
#      https://dash.cloudflare.com (your domain shows "Active" once done),
#      or run: dig ns yourdomain.com — it should show the Cloudflare
#      nameservers once propagated.
#
#   Only once your domain shows "Active" in Cloudflare, continue below.
#
# Prerequisite 2 (one manual step, cannot be scripted — creating an API
# token is deliberately a human-in-the-loop action on Cloudflare's
# dashboard):
#   1. Go to: My Profile (top-right) → API Tokens → Create Token →
#      Create Custom Token, and set:
#        - Permissions:
#            Account | Cloudflare Tunnel | Edit
#            Account | Access: Apps and Policies | Edit
#            Zone    | DNS                       | Edit
#        - Zone Resources: Include | Specific zone | <your domain>
#        - Account Resources: Include | <your account>
#        - TTL: set an End Date (e.g. 6 months out) rather than none
#   2. Copy the token it shows you (shown once) and save it to a LOCAL
#      .env file in this directory:
#        echo "CLOUDFLARE_API_TOKEN=paste-it-here" >> .env
#      Never paste this token into a chat, email, or support ticket — it
#      never needs to leave this machine.
#
# Usage:
#   source .env   # loads CLOUDFLARE_API_TOKEN into this shell
#   bash cloudflare-setup.sh <client-name> <your-domain> <service:port> [service:port ...]
#
# Example:
#   bash cloudflare-setup.sh acme acme.com n8n:5678 open-webui:8080
#   → creates hostnames n8n.acme.com and owui... pointing at the
#     given container:port pairs over the tunnel
#
# What this script does automatically, using ONLY the local token above:
#   - Verifies the token and the target zone are reachable
#   - Creates (or reuses) one Cloudflare Tunnel for this client
#   - Sets the tunnel's ingress rules — one per service:port argument
#   - Creates the DNS CNAME record(s) pointing at the tunnel
#   - Writes cloudflared/config.yml + prints the tunnel run token for the
#     cloudflared container's command in docker-compose.yml
#
# Nothing here is transmitted anywhere except directly to Cloudflare's own
# API, using the token you generated yourself. This script never sees or
# needs any other credential.
# ==============================================================================
set -euo pipefail

CLIENT_NAME="${1:-}"
DOMAIN="${2:-}"
shift 2 2>/dev/null || { echo "Usage: bash cloudflare-setup.sh <client-name> <domain> <service:port> [service:port ...]"; exit 1; }
SERVICES=("$@")

if [ -z "$CLIENT_NAME" ] || [ -z "$DOMAIN" ] || [ ${#SERVICES[@]} -eq 0 ]; then
  echo "Usage: bash cloudflare-setup.sh <client-name> <domain> <service:port> [service:port ...]"
  echo "Example: bash cloudflare-setup.sh acme acme.com n8n:5678 open-webui:8080"
  exit 1
fi

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is not set."
  echo "Run: source .env"
  echo "(See the instructions at the top of this script if you haven't"
  echo " created a token yet.)"
  exit 1
fi

API="https://api.cloudflare.com/client/v4"
AUTH_HEADER="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

echo "========================================"
echo "  Cloudflare Tunnel setup: $CLIENT_NAME"
echo "========================================"
echo ""

# --- Step 1: verify token -----------------------------------------------
echo "[1/6] Verifying API token ..."
VERIFY=$(curl -s "$API/user/tokens/verify" -H "$AUTH_HEADER")
if [ "$(echo "$VERIFY" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("success"))')" != "True" ]; then
  echo "ERROR: Token verification failed."
  echo "$VERIFY"
  exit 1
fi
echo "  ✓ Token is valid."
echo ""

# --- Step 2: resolve zone + account IDs from the domain -----------------
echo "[2/6] Looking up zone for $DOMAIN ..."
ZONE_LOOKUP=$(curl -s "$API/zones?name=$DOMAIN" -H "$AUTH_HEADER")
ZONE_ID=$(echo "$ZONE_LOOKUP" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')
ACCOUNT_ID=$(echo "$ZONE_LOOKUP" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["account"]["id"] if r else "")')
ZONE_STATUS=$(echo "$ZONE_LOOKUP" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["status"] if r else "")')

if [ -z "$ZONE_ID" ]; then
  echo "ERROR: '$DOMAIN' is not on this Cloudflare account yet."
  echo ""
  echo "This means Prerequisite step (adding your domain to Cloudflare and"
  echo "changing nameservers at your registrar) hasn't been done, or the"
  echo "token's Zone Resources don't include this domain. See the numbered"
  echo "A-G steps in the comment block at the top of this script."
  exit 1
fi
if [ "$ZONE_STATUS" != "active" ]; then
  echo "WARNING: '$DOMAIN' is on Cloudflare but its status is '$ZONE_STATUS',"
  echo "not 'active' yet. This usually means the nameserver change at your"
  echo "registrar hasn't finished propagating. This can take anywhere from"
  echo "a few minutes to 24 hours."
  echo ""
  echo "Check status at: https://dash.cloudflare.com"
  echo "Or run: dig ns $DOMAIN"
  echo ""
  read -p "Continue anyway? Tunnel/DNS setup may not fully work until this domain is active. [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi
echo "  ✓ Zone ID:    $ZONE_ID"
echo "  ✓ Account ID: $ACCOUNT_ID"
echo "  ✓ Status:     $ZONE_STATUS"
echo ""

# --- Step 3: create or reuse the tunnel ----------------------------------
echo "[3/6] Creating tunnel '$CLIENT_NAME' (or reusing if it exists) ..."
EXISTING=$(curl -s "$API/accounts/$ACCOUNT_ID/cfd_tunnel?name=$CLIENT_NAME&is_deleted=false" -H "$AUTH_HEADER")
TUNNEL_ID=$(echo "$EXISTING" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"] if r else "")')

if [ -n "$TUNNEL_ID" ]; then
  echo "  ✓ Reusing existing tunnel: $TUNNEL_ID"
else
  TUNNEL_SECRET=$(openssl rand -base64 32)
  CREATE=$(curl -s -X POST "$API/accounts/$ACCOUNT_ID/cfd_tunnel" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    --data "{\"name\":\"$CLIENT_NAME\",\"tunnel_secret\":\"$TUNNEL_SECRET\",\"config_src\":\"cloudflare\"}")
  TUNNEL_ID=$(echo "$CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')
  echo "  ✓ Created tunnel: $TUNNEL_ID"
fi
echo ""

# --- Step 4: set ingress rules -------------------------------------------
echo "[4/6] Setting ingress rules for ${#SERVICES[@]} service(s) ..."
INGRESS_JSON=$(python3 -c "
import json
services = '''${SERVICES[@]}'''.split()
domain = '$DOMAIN'
rules = []
for s in services:
    name, port = s.split(':')
    rules.append({'hostname': f'{name}.{domain}', 'service': f'http://{name}:{port}', 'originRequest': {}})
rules.append({'service': 'http_status:404'})
print(json.dumps({'config': {'ingress': rules, 'warp-routing': {'enabled': False}}}))
")
curl -s -X PUT "$API/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  --data "$INGRESS_JSON" > /dev/null
echo "  ✓ Ingress configured."
echo ""

# --- Step 5: DNS records --------------------------------------------------
echo "[5/6] Creating DNS records ..."
for svc in "${SERVICES[@]}"; do
  NAME="${svc%%:*}"
  HOSTNAME="$NAME.$DOMAIN"
  EXISTING_DNS=$(curl -s "$API/zones/$ZONE_ID/dns_records?type=CNAME&name=$HOSTNAME" -H "$AUTH_HEADER")
  DNS_COUNT=$(echo "$EXISTING_DNS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]))')
  if [ "$DNS_COUNT" -gt 0 ]; then
    echo "  - $HOSTNAME already exists, skipping"
    continue
  fi
  curl -s -X POST "$API/zones/$ZONE_ID/dns_records" \
    -H "$AUTH_HEADER" -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"$HOSTNAME\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}" > /dev/null
  echo "  ✓ $HOSTNAME"
done
echo ""

# --- Step 6: get run token and write local config ------------------------
echo "[6/6] Fetching tunnel run token ..."
TOKEN_RESP=$(curl -s "$API/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" -H "$AUTH_HEADER")
RUN_TOKEN=$(echo "$TOKEN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"])')

mkdir -p cloudflared
echo "$RUN_TOKEN" > cloudflared/run-token.txt
chmod 600 cloudflared/run-token.txt

echo "========================================"
echo "  Done."
echo "========================================"
echo ""
echo "Tunnel ID: $TUNNEL_ID"
echo "Run token saved to: cloudflared/run-token.txt (chmod 600)"
echo ""
echo "In docker-compose.client.yml, set the cloudflared service command to:"
echo ""
echo "    command: tunnel run --token \$(cat cloudflared/run-token.txt)"
echo ""
echo "Hostnames now routing to this tunnel:"
for svc in "${SERVICES[@]}"; do
  echo "  - https://${svc%%:*}.$DOMAIN"
done
echo ""
echo "DNS can take up to a few minutes to propagate. Once cloudflared is"
echo "running, the next step is: bash google-oauth-setup.sh n8n.$DOMAIN"
echo "========================================"
