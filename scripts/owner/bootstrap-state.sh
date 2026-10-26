#!/usr/bin/env bash
# Pre-flight for the FIRST `tofu apply` of live/identity, run by the operator
# at their laptop AFTER the by-hand pre-work (e): verifies the hand-created
# state backend matches what live/identity imports, and grants the one role
# the azurerm backend needs. Idempotent: every step is a read first, the role
# is only assigned when missing, re-running is always safe.
#
#   scripts/owner/bootstrap-state.sh <operator-upn>
#
# Needs: az CLI v2, jq, signed in with `az login --tenant <tenant-domain>` AND
# the platform subscription selected (`az account set --subscription <id>`).
# Prints names and IDs only — never a secret; there are no secrets here.
#
# Public repository: no subscription, tenant or object IDs in this file. All
# values are read live from `az`.
set -euo pipefail
umask 077

STORAGE_RG="rg-qnsc-platform"
STORAGE_ACCOUNT="stqnsctfstate"
CONTAINER="tfstate"
BUDGET="qnsc-platform-monthly"
BACKEND_ROLE="Storage Blob Data Contributor"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

[[ $# -eq 1 ]] || fail "usage: bootstrap-state.sh <operator-upn>"
OPERATOR_UPN="$1"

command -v az >/dev/null || fail "az CLI not found"
command -v jq >/dev/null || fail "jq not found"
command -v tofu >/dev/null || fail "tofu not found"

# ── 1. Signed in, real subscription selected ────────────────────────────────
SUB="$(az account show --output json 2>/dev/null | jq -r '.id // empty' )" \
  || fail "az account show failed — run az login --tenant <tenant-domain> first"
[[ -n "$SUB" ]] || fail "no subscription selected — run az account set --subscription <id>"
SUB_NAME="$(az account show --query name -o tsv)"
ok "subscription selected: $SUB_NAME"

# ── 2. Storage account exists and matches what state_backend.tf imports ─────
SA_JSON="$(az storage account show --resource-group "$STORAGE_RG" --name "$STORAGE_ACCOUNT" --output json)" \
  || fail "storage account $STORAGE_ACCOUNT not found in $STORAGE_RG"

check() { # check <jq-filter> <expected> <label>
  local got
  got="$(echo "$SA_JSON" | jq -r "$1")"
  [[ "$got" == "$2" ]] || fail "$3 is '$got', expected '$2' — fix by hand or reconcile in a PR BEFORE the first apply"
  ok "$3"
}
check '.sku.name'                          'Standard_LRS' 'sku: Standard_LRS'
check '.kind'                              'StorageV2'    'kind: StorageV2'
check '.enableHttpsTrafficOnly'            'true'         'HTTPS-only: on'
check '.minimumTlsVersion'                 'TLS1_2'       'min TLS: 1.2'
check '.allowSharedKeyAccess'              'false'        'shared keys: disabled (backend uses Entra)'
check '.publicNetworkAccess // "Enabled"'  'Enabled'      'public network: enabled (RBAC is the boundary)'

# ── 3. The one role the backend data plane needs (idempotent grant) ─────────
# use_azuread_auth=true (versions.tf) talks to the blob endpoint as the signed
# in operator, so the operator needs Blob Data Contributor on the account.
SCOPE="$(echo "$SA_JSON" | jq -r '.id')"
HAS_ROLE="$(az role assignment list --assignee "$OPERATOR_UPN" --scope "$SCOPE" \
  --role "$BACKEND_ROLE" --query '[0].id' -o tsv || true)"
if [[ -z "$HAS_ROLE" ]]; then
  echo "… assigning '$BACKEND_ROLE' on $STORAGE_ACCOUNT to $OPERATOR_UPN"
  az role assignment create --assignee "$OPERATOR_UPN" --scope "$SCOPE" \
    --role "$BACKEND_ROLE" >/dev/null \
    || fail "role assignment failed — are you Owner/User Access Administrator on the subscription?"
  ok "role granted: $BACKEND_ROLE to $OPERATOR_UPN (may take ~1 min to propagate)"
else
  ok "role already present: $BACKEND_ROLE to $OPERATOR_UPN"
fi

# ── 4. Container exists (as the operator, over Entra — proves the role) ─────
FOUND="$(az storage container exists --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login --name "$CONTAINER" --query exists -o tsv)" \
  || fail "cannot reach the blob endpoint as $OPERATOR_UPN (role still propagating? wait a minute and re-run)"
[[ "$FOUND" == "True" ]] || fail "container '$CONTAINER' missing — create it by hand: az storage container create --account-name $STORAGE_ACCOUNT --auth-mode login --name $CONTAINER"
ok "container: $CONTAINER (reachable over Entra auth)"

# ── 5. Data protection: versioning + 30-day blob/container soft delete ─────
BP="$(echo "$SA_JSON" | jq '.blobProperties // {}')"
check_is() { [[ "$(echo "$BP" | jq -r "$1")" == "$2" ]] || fail "$3 — set it in the portal's Data protection blade (or az) BEFORE the first apply"; }
check_is '.versioning // .versioningEnabled'                     'true' 'versioning is off'
check_is '.deleteRetentionPolicy.enabled'                        'true' 'blob soft delete is off'
check_is '.deleteRetentionPolicy.days'                           '30'   'blob soft delete is not 30 days'
check_is '.containerDeleteRetentionPolicy.enabled'               'true' 'container soft delete is off'
check_is '.containerDeleteRetentionPolicy.days'                  '30'   'container soft delete is not 30 days'
ok "data protection: versioning on, blob + container soft delete 30 days"

# ── 6. Budget exists under the imported name ────────────────────────────────
BUDGET_OK="$(az consumption budget show --budget-name "$BUDGET" --output json 2>/dev/null | jq -r '.name // empty')" \
  || true
[[ "$BUDGET_OK" == "$BUDGET" ]] || fail "budget '$BUDGET' not found on this subscription — the import in imports.tf will fail"
ok "budget: $BUDGET present"

echo
echo "READY. First apply, from live/identity:"
echo "  export TF_VAR_subscription_id=<subscription-id>"
echo "  export TF_VAR_budget_period_start=<first-day-of-this-month YYYY-MM-DD>"
echo "  export TF_VAR_break_glass_upn_domain=<tenant-primary-domain>"
echo "  export ARM_SUBSCRIPTION_ID=\$TF_VAR_subscription_id"
echo "  tofu init && tofu plan && tofu apply"
echo "Plan must show: 4 imports, the 4 vaults, the 2 CI identities, their roles — and NO change on any imported resource."
