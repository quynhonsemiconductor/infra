#!/bin/zsh
# rotate-signin-secret.sh — owner-run: rotate ONE sign-in app's client secret
# and land it in the vault. Nothing secret is printed; nothing enters argv or
# TF state (§7). TF owns the registration; this owns the credential.
#
#   ./scripts/rotate-signin-secret.sh <app-object-id> <vault> <secret-name>
#
# --append NEVER wipes existing secrets (rova prod on AWS is using one right
# now); the NEW credential's --end-date is +6 months (≤ the 6-month policy),
# the VAULT secret gets the same --expires, and the weekly expiry-check
# alerts at < 30 days (§7.5). Revoke superseded credentials after the next
# green deploy.
set -euo pipefail
app_id="$1"; vault="$2"; secret_name="$3"

az ad app credential reset --id "$app_id" --append \
  --end-date "$(date -v+6m +%Y-%m-%dT00:00:00Z)" --only-show-errors -o json \
| jq -ej '.password' \
| tee >(wc -c | xargs printf 'storing %s chars\n' >&2) \
| az keyvault secret set --vault-name "$vault" --name "$secret_name" \
    --file /dev/stdin --content-type "text/plain" \
    --expires "$(date -v+6m +%Y-%m-%dT00:00:00Z)" \
    --tags owner=platform "rotated=$(date -u +%Y-%m-%d)" -o none

echo "rotated: $secret_name in $vault (vault secret +6m; new credential --end-date +6m; old credentials kept — revoke manually after the next green deploy)."
