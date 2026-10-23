#!/bin/zsh
# rotate-signin-secret.sh — owner-run: rotate ONE sign-in app's client secret
# and land it in the vault. Nothing secret is printed; nothing enters argv or
# TF state (§7). TF owns the registration; this owns the credential.
#
#   ./scripts/rotate-signin-secret.sh <app-object-id> <vault> <secret-name>
#
# --years caps the credential at 1 year; the VAULT secret expires in 6 months
# (--expires), and the weekly expiry-check alerts at < 30 days (§7.5). Revoke
# the previous credential after the next green deploy.
set -euo pipefail
app_id="$1"; vault="$2"; secret_name="$3"

az ad app credential reset --id "$app_id" --years 1 --only-show-errors -o json \
| jq -er '.password' \
| tee >(wc -c | xargs printf 'storing %s chars\n' >&2) \
| az keyvault secret set --vault-name "$vault" --name "$secret_name" \
    --file /dev/stdin --content-type "text/plain" \
    --expires "$(date -v+6m +%Y-%m-%dT00:00:00Z)" \
    --tags owner=platform "rotated=$(date -u +%Y-%m-%d)" -o none

echo "rotated: $secret_name in $vault (vault secret expires +6m; credential +1y)."
