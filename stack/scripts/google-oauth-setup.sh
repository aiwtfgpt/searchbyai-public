#!/usr/bin/env bash
# ==============================================================================
# google-oauth-setup.sh — Prep a Google Cloud project for n8n's Google nodes
#
# Run this in Google Cloud Shell (console.cloud.google.com > Activate Cloud
# Shell), inside the project you want n8n to use.
#
# Prerequisite: the Cloudflare Tunnel step must already be done — n8n needs
# a real, resolvable hostname before this script's redirect URI is valid.
# Google will not redirect the OAuth login back to a domain that isn't live.
#
# Usage:
#   bash google-oauth-setup.sh n8n.your-domain.com
#
# What this script does automatically:
#   - Confirms the active project
#   - Enables the six APIs n8n's Google nodes need
#   - Computes the exact OAuth redirect URI from the domain you pass in
#     (n8n's redirect path is fixed: /rest/oauth2-credential/callback —
#     no need to look it up inside n8n's own UI)
#
# What it CANNOT do (Google does not allow this to be scripted — confirmed
# live, 2026-09: gcloud CAN create an OAuth client via the deprecated IAP
# API, but the client it creates is locked/read-only with no editable
# redirect URI field, making it non-functional for a third-party app's
# OAuth login. Only the Cloud Console UI can create a usable one):
#   - Create the OAuth consent screen
#   - Create a working OAuth 2.0 Client ID + Secret with an editable
#     redirect URI
# This script prints exact, step-by-step instructions for that manual part
# at the end, with the redirect URI already filled in — nothing to look up.
# ==============================================================================
set -euo pipefail

N8N_DOMAIN="${1:-}"
if [ -z "$N8N_DOMAIN" ]; then
  echo "Usage: bash google-oauth-setup.sh <your-n8n-domain>"
  echo "Example: bash google-oauth-setup.sh n8n.acme.com"
  echo ""
  echo "This is the domain from the Cloudflare Tunnel step — that step must"
  echo "be complete first, since Google won't redirect back to a domain"
  echo "that isn't live yet."
  exit 1
fi
REDIRECT_URI="https://${N8N_DOMAIN}/rest/oauth2-credential/callback"

echo "========================================"
echo "  Google OAuth setup for n8n"
echo "========================================"
echo ""

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: No active project set."
  echo "Run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi
echo "Using project: $PROJECT_ID"
echo "n8n domain:     $N8N_DOMAIN"
echo "Redirect URI:   $REDIRECT_URI"
echo ""

echo "Enabling required APIs (this takes ~30-60s) ..."
gcloud services enable \
  gmail.googleapis.com \
  drive.googleapis.com \
  docs.googleapis.com \
  sheets.googleapis.com \
  calendar-json.googleapis.com \
  youtube.googleapis.com \
  --project="$PROJECT_ID"

echo ""
echo "✓ APIs enabled."
echo ""
echo "========================================"
echo "  MANUAL STEP REQUIRED (Google does not"
echo "  allow this part to be scripted)"
echo "========================================"
echo ""
echo "1. Open: https://console.cloud.google.com/auth/overview?project=$PROJECT_ID"
echo "   (Google renamed this section 'Google Auth Platform' in 2026 — if"
echo "   this is the project's first OAuth client, it walks you through a"
echo "   short branding/consent setup first. If one already exists, skip to"
echo "   step 2.)"
echo "   - User Type: External (unless you have a Workspace org, then Internal is fine)"
echo "   - Fill in app name, your email, and save through each screen"
echo "   - On the Scopes screen, you don't need to add scopes manually —"
echo "     n8n requests the exact scopes it needs during the OAuth login"
echo ""
echo "2. Open: https://console.cloud.google.com/auth/clients?project=$PROJECT_ID"
echo "   - Click '+ Create client'"
echo "   - Application type: Web application"
echo "   - Name: n8n"
echo "   - Under 'Authorized redirect URIs', click '+ Add URI' and paste"
echo "     exactly this (already computed for your domain):"
echo ""
echo "       $REDIRECT_URI"
echo ""
echo "   - Click Create"
echo ""
echo "3. A popup shows your Client ID and Client Secret — copy both."
echo ""
echo "4. In n8n: Settings → Credentials → New → search 'Google' → pick the"
echo "   node type you need (Gmail, Google Drive, etc.) → OAuth2 → paste the"
echo "   Client ID and Client Secret → Save → Connect (opens the Google"
echo "   consent screen) → Sign in and approve."
echo ""
echo "   You can reuse the SAME Client ID/Secret for every Google node type"
echo "   (Gmail, Drive, Sheets, Docs, Calendar, YouTube) — one OAuth client"
echo "   covers all of them since the APIs are already enabled on this project."
echo "========================================"
