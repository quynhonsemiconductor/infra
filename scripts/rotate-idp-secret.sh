#!/bin/zsh
# rotate-idp-secret.sh — owner-run: rotate the Zero Trust Entra IdP client
# secret (app "QNSC Cloudflare Access") and push it STRAIGHT into the infra
# GitHub secret. --append keeps the previous secret valid until CF is updated
# (the running tunnel config keeps working); nothing is printed.
#
#   ./scripts/rotate-idp-secret.sh <entra-app-object-id>
#
# --end-date = +6 months (≤ the 6-month policy); the credential is an Entra
# app credential, so the weekly expiry-check already watches it (§7.5).
set -euo pipefail
app_id="$1"

az ad app credential reset --id "$app_id" --append \
  --end-date "$(date -v+6m +%Y-%m-%dT00:00:00Z)" --only-show-errors -o json \
| jq -ej '.password' \
| gh secret set ENTRA_IDP_CLIENT_SECRET -R quynhonsemiconductor/infra --app actions -f - >/dev/null

echo "rotated: ENTRA_IDP_CLIENT_SECRET updated in infra repo secrets (+6m). Old secret still valid — Zero Trust IdP picks up the new one on next CF use; revoke the old one after a verified sign-in."
