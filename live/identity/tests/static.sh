#!/bin/sh
# Static guard for live/identity — plan-free (pure grep, no credentials, runs
# anywhere, and in CI as a step of infra-plan.yml's fmt job). Asserts the §7
# invariants this stack never breaks:
#   1. no secret/password credential resource or block for ANY identity
#   2. no private key material anywhere in the code
#   3. every Key Vault data-plane role assignment in EVERY .tf file (any
#      indentation) is scoped to a vault resource — never an RG or the
#      subscription — and no role is wider than
#      Secrets Officer (humans) / Secrets User (ESO)
#   4. the ESO map has exactly dev/prod/platform and never touches the admin
#      vault (§7.1: nobody automated reads it)
# A violation exits non-zero; success prints PASS.
set -eu
cd "$(dirname "$0")/.."

fail() {
	printf 'FAIL: %s\n' "$1"
	exit 1
}

# 1. Certificate auth only — no password credential resource (v3) or inline
#    `password {}` block (pre-v3 shape either).
grep -rnE 'azuread_(application|service_principal)_password|^[[:space:]]*password[[:space:]]*\{' \
	--include='*.tf' . >/dev/null &&
	fail "password credential found — every identity here is certificate-only"
grep -rn 'client_secret' --include='*.tf' . >/dev/null &&
	fail "client_secret found — no secret-based auth in this stack"

# 2. No private key material committed.
grep -rn 'BEGIN [A-Z ]*PRIVATE KEY' --include='*.tf' . >/dev/null &&
	fail "private key material committed"

# 3. EVERY azurerm_role_assignment in every .tf file: a Key Vault data-plane
#    role must sit on a vault resource scope. Key Vault Reader (metadata) is
#    the documented exception — ci_identities.tf scopes it to the RG on
#    purpose. Everything else (Contributor, Reader on the subscription,
#    Storage Blob …) belongs to the CI identities' documented Azure RBAC.
ROLE_LINE='^[[:space:]]*role_definition_name[[:space:]]*='
ASSIGNMENTS=$(awk -v roleline="$ROLE_LINE" '
	/resource "azurerm_role_assignment"/ { inblk = 1; depth = 0; role = ""; scope = ""; fe = "" }
	inblk {
		depth += gsub(/\{/, "{") - gsub(/\}/, "}")
		if ($0 ~ /^[[:space:]]*for_each[[:space:]]*=/) {
			fe = $0
			sub(/.*for_each[[:space:]]*=[[:space:]]*/, "", fe)
			sub(/[[:space:]]*#.*$/, "", fe)
			gsub(/[[:space:]]/, "", fe)
		}
		if ($0 ~ roleline) {
			role = $0
			sub(/.*role_definition_name[[:space:]]*=[[:space:]]*"/, "", role)
			sub(/".*/, "", role)
		}
		if ($0 ~ /^[[:space:]]*scope[[:space:]]*=/) {
			scope = $0
			sub(/^[^=]*=[[:space:]]*/, "", scope)
			sub(/[[:space:]]*#.*$/, "", scope)
			gsub(/[[:space:]]/, "", scope)
		}
		if (depth <= 0) {
			# `each.value` is acceptable ONLY where the map itself is the vault-id
			# map (local.all_vaults) — any other for_each makes the scope unknown.
			if (scope == "each.value" && fe != "local.all_vaults") { scope = "each.value (for_each " fe ")" }
			if (role ~ /^Key Vault / && role != "Key Vault Reader") {
				if (scope !~ /^azurerm_key_vault\./ &&
					scope !~ /^each\.value$/ &&
					scope !~ /^local\.eso\[each\.key\]\.vault_id$/)
					printf "%s\n", role " @ " scope
			}
			inblk = 0
		}
	}
' *.tf)
[ -z "$ASSIGNMENTS" ] || fail "Key Vault data-plane role outside a vault scope:
$ASSIGNMENTS"
grep -rn 'Key Vault Administrator\|Key Vault Contributor' --include='*.tf' . >/dev/null &&
	fail "over-broad Key Vault role (Administrator/Contributor) — Officer/User only"

# 4. The ESO map: exactly dev/prod/platform, no admin key, no admin reference
#    in CODE (comments may document the exclusion; comments are stripped
#    before the grep).
grep -vE '^[[:space:]]*#' eso.tf | grep -qE 'admin' &&
	fail "eso.tf references the admin vault in code — no store reads it (§7.1)"
KEYS=$(sed -n '/^locals {/,/^}/s/^[[:space:]]*\([a-z]*\)[[:space:]]*=[[:space:]]*{$/\1/p' eso.tf |
	grep -v '^tags$\|^eso$' | sort -u)
[ "$KEYS" = "dev
platform
prod" ] || fail "local.eso keys are not exactly dev/prod/platform: $KEYS"

# 5. ESO workload identity (§7.1): the issuer Entra trusts (this stack), the
#    issuer published as an OIDC document (live/onprem-oidc) and the issuer
#    k3s mints tokens with (live/onprem-vm) are ONE string. A mismatch passes
#    every other gate and fails only at token exchange, silently.
grep -q 'resource "azuread_application_federated_identity_credential" "eso"' eso.tf ||
	fail "no federated identity credential for the ESO apps — the certificate stays the only auth"
grep -q 'system:serviceaccount:external-secrets:eso-' eso.tf ||
	fail "federated credential subject is not system:serviceaccount:external-secrets:eso-<env>"
grep -q 'api://AzureADTokenExchange' eso.tf ||
	fail "federated credential audience is not api://AzureADTokenExchange"

default_of() {
	sed -n "/^variable \"$2\"/,/^}/s/^[[:space:]]*default[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1"
}

IDENTITY_ISSUER=$(default_of eso.tf eso_oidc_issuer)
[ -n "$IDENTITY_ISSUER" ] || fail "eso_oidc_issuer has no default in eso.tf"

OIDC_DIR=../onprem-oidc
[ -f "$OIDC_DIR/variables.tf" ] || fail "live/onprem-oidc is missing — the issuer has no published discovery document"
PUBLISHED_ISSUER="https://$(default_of "$OIDC_DIR/variables.tf" oidc_hostname)/$(default_of "$OIDC_DIR/variables.tf" oidc_path)"
[ "$PUBLISHED_ISSUER" = "$IDENTITY_ISSUER" ] ||
	fail "published issuer ($PUBLISHED_ISSUER) != trusted issuer ($IDENTITY_ISSUER)"

K3S_CONFIG=../onprem-vm/files/k3s/config.yaml
if [ -f "$K3S_CONFIG" ]; then
	# The config carries the new issuer FIRST — the one k3s signs with — and
	# the old default SECOND, which is only accepted. Check the first only.
	K3S_ISSUER=$(sed -n 's/^[[:space:]]*-[[:space:]]*service-account-issuer=\([^[:space:]]*\)$/\1/p' "$K3S_CONFIG" | head -1)
	[ "$K3S_ISSUER" = "$IDENTITY_ISSUER" ] ||
		fail "k3s service-account-issuer ($K3S_ISSUER) != trusted issuer ($IDENTITY_ISSUER)"
fi

echo "PASS: static guard"
