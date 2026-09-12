#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh — remove this machine's SearchByAI listing and local files
#
#   bash <(curl -fsSL https://searchbyai.com/uninstall.sh)
#
# Does three things, in the order that matters:
#
#   1. Tells the registry to delist the node, while the credentials to sign
#      that request still exist. Deleting the files first would leave the
#      listing up with no way to authenticate its removal — it would linger
#      as 'stale' for 48h and 'suspended' for 14 days before disappearing.
#   2. Removes the heartbeat cron entry.
#   3. Removes ~/.searchbyai.
#
# Nothing else was ever installed, so nothing else is removed: no packages,
# no services, no files outside that one directory.
#
# Safe to run twice. Each step is skipped if it has already been done.
# ==============================================================================
set -euo pipefail

BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RESET=$(printf '\033[0m')

ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}!${RESET} $*"; }

CONFIG_DIR="${HOME}/.searchbyai"
CONFIG_FILE="${CONFIG_DIR}/node.json"

echo ""
echo "${BOLD}SearchByAI — uninstall${RESET}"
echo ""

if [ ! -d "$CONFIG_DIR" ]; then
  ok "Nothing to remove — ${CONFIG_DIR} does not exist."
  exit 0
fi

# --- 1. delist ---------------------------------------------------------------
# Best effort. A failure here must not stop the local cleanup: someone whose
# node is already suspended, or who is offline, still gets their files back.
if [ -f "$CONFIG_FILE" ] && [ -x "${CONFIG_DIR}/sign.sh" ] \
   && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then

  NODE_ID=$(jq -r '.node_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
  HUB=$(jq -r '.hub // empty' "$CONFIG_FILE" 2>/dev/null || true)

  if [ -n "$NODE_ID" ] && [ -n "$HUB" ]; then
    echo "Delisting ${BOLD}${NODE_ID}${RESET} from the registry ..."
    BODY='{}'
    PATH_PART="/nodes/${NODE_ID}/disable"

    if mapfile -t HEADERS < <(
         "${CONFIG_DIR}/sign.sh" POST "$PATH_PART" "$BODY" 2>/dev/null
       ) && [ "${#HEADERS[@]}" -gt 0 ]; then

      STATUS=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        -X POST "${HUB}${PATH_PART}" "${HEADERS[@]}" \
        -H 'Content-Type: application/json' -d "$BODY" 2>/dev/null || echo 000)

      case "$STATUS" in
        200|204) ok "Node delisted — it no longer appears in search." ;;
        401|403) warn "Registry rejected the signature (HTTP $STATUS)." ;;
        404)     ok "Node was not listed." ;;
        000)     warn "Could not reach the registry. Continuing." ;;
        *)       warn "Registry returned HTTP $STATUS. Continuing." ;;
      esac

      if [ "$STATUS" != "200" ] && [ "$STATUS" != "204" ] && [ "$STATUS" != "404" ]; then
        echo "${DIM}  The listing stops receiving heartbeats either way: it goes"
        echo "  stale after 48h and is hidden, then suspended after 14 days."
        echo "  To remove it sooner, email ai@wtfgpt.com with the node id.${RESET}"
      fi
    else
      warn "Could not sign the delist request. Continuing with local cleanup."
    fi
  fi
else
  warn "No usable credentials found — skipping delist."
fi

# --- 2. cron -----------------------------------------------------------------
if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -qF "${CONFIG_DIR}/heartbeat.sh"; then
    # Filter by the exact path so unrelated cron entries survive.
    crontab -l 2>/dev/null | grep -vF "${CONFIG_DIR}/heartbeat.sh" | crontab - \
      && ok "Heartbeat cron removed." \
      || warn "Could not edit crontab — remove this line yourself:
      */5 * * * * ${CONFIG_DIR}/heartbeat.sh"
  else
    ok "No heartbeat cron entry found."
  fi
else
  warn "crontab not available — skipping."
fi

# --- 3. files ----------------------------------------------------------------
rm -rf "$CONFIG_DIR"
ok "Removed ${CONFIG_DIR}"

echo ""
echo "${BOLD}Done.${RESET} Nothing from SearchByAI remains on this machine."
echo "${DIM}Your own services are untouched — this only ever installed a"
echo "credentials file and a heartbeat.${RESET}"
echo ""
