#!/bin/sh
# Static guard for live/identity — plan-free (pure grep, no credentials, runs
# anywhere). Asserts the §7 invariants this stack never breaks:
#   1. no secret/password credential resource for the machine identities
#   2. no private key material anywhere in the code
#   3. no Key Vault data-plane role wider than a vault scope, and no role
#      beyond Secrets Officer (humans) / Secrets User (ESO)
#   4. no ESO principal for kv-qnsc-admin (§7.1: nobody automated reads it)
# A violation exits non-zero; success prints PASS.
set -eu
cd "$(dirname "$0")/.."

fail() {
	printf 'FAIL: %s\n' "$1"
	exit 1
}

# 1. Certificate auth only for apps/service principals.
grep -rn 'azuread_application_password' --include='*.tf' . >/dev/null &&
	fail "azuread_application_password found — apps are certificate-only"
grep -rn 'client_secret' --include='*.tf' . >/dev/null &&
	fail "client_secret found — no secret-based auth in this stack"

# 2. No private key material committed.
grep -rn 'BEGIN [A-Z ]*PRIVATE KEY' --include='*.tf' . >/dev/null &&
	fail "private key material committed"

# 3. Vault data-plane RBAC stays inside the vault boundary.
#    (The CI identities' subscription-scope assignments are in ci_identities.tf,
#    that file's documented purpose — not re-checked here.)
ROLES=$(sed -n 's/^  role_definition_name *= *"\(.*\)"$/\1/p' vault_rbac.tf eso.tf | sort -u)
[ "$ROLES" = "Key Vault Secrets Officer
Key Vault Secrets User" ] ||
	fail "unexpected role in vault_rbac.tf/eso.tf: only Secrets Officer (admins) and Secrets User (ESO) allowed; got: $ROLES"

SCOPES=$(sed -n 's/ *#.*$//; s/^  scope *= *\(.*\)$/\1/p' vault_rbac.tf eso.tf | sort -u)
for s in $SCOPES; do
	case "$s" in
	# each.value = the all_vaults map (vault ids); the other two are the ESO
	# per-vault references. Anything else (RG id, subscription id, *) is wider
	# than a vault.
	'each.value' | 'local.eso[each.key].vault_id') ;;
	*) fail "role assignment scope outside a vault resource: $s" ;;
	esac
done

# 4. The ESO map has exactly dev/prod/platform — no admin key.
KEYS=$(sed -n '/^locals {/,/^}/s/^    \([a-z]*\) *= *{$/\1/p' eso.tf | sort -u)
[ "$KEYS" = "dev
platform
prod" ] || fail "local.eso keys are not exactly dev/prod/platform: $KEYS"

echo "PASS: static guard"
