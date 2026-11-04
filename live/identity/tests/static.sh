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

# 1b. The ESO certificate credential is gone from EVERY .tf file: no
#     certificate resource for the ESO apps and no eso_certificates variable.
#     mail.tf keeps its OWN certificates and is not matched (the names make
#     the check ESO-specific).
grep -rnE 'azuread_application_certificate"[[:space:]]*"eso"|variable[[:space:]]*"eso_certificates"' \
	--include='*.tf' . >/dev/null &&
	fail "the ESO certificate credential is back — the ESO apps authenticate with workload identity only"

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

# 5. Certificate import ids: azuread 3.10 parses EXACTLY "{app object id}/certificate/{keyId}"
#    (3 slash-parts). A "/applications/" prefix fails the whole plan at parse time.
grep -vE '^[[:space:]]*#' mail.tf | grep -qE '/applications/[^"]*/certificate/' &&
	fail "mail.tf: a certificate import id has the /applications/ prefix (azuread 3.10 rejects it)"
grep -vE '^[[:space:]]*#' mail.tf | grep -qE 'azuread_application_certificate\.mail_service\["rova_prod"\]' ||
	fail "mail.tf: rova_prod certificate is not imported (a create would add a duplicate credential)"

# 6. ESO workload identity (§7.1): the issuer Entra trusts (this stack) and the issuer published as an OIDC
#    document (live/onprem-oidc) are ONE string; the k3s side (site value in the git-ignored Ansible inventory)
#    is NOT visible to CI and is verified at rollout (identity README step 4). A mismatch passes every other
#    gate and fails only at token exchange, silently. Only NON-COMMENT lines count below.
ESO_CODE=$(grep -vE '^[[:space:]]*#' eso.tf)
printf '%s\n' "$ESO_CODE" | grep -q 'resource "azuread_application_federated_identity_credential" "eso"' ||
	fail "no federated identity credential for the ESO apps — the certificate stays the only auth"
SUBJECT_LINES=$(printf '%s\n' "$ESO_CODE" | grep -E '^[[:space:]]*subject[[:space:]]*=' || true)
[ "$(printf '%s\n' "$SUBJECT_LINES" | grep -c .)" = "1" ] ||
	fail "expected exactly one federated credential subject line in eso.tf"
printf '%s\n' "$SUBJECT_LINES" | grep -qE '^[[:space:]]*subject[[:space:]]*=[[:space:]]*"system:serviceaccount:external-secrets:eso-\$\{each\.key\}"[[:space:]]*$' ||
	fail "federated credential subject is not exactly system:serviceaccount:external-secrets:eso-<env>"
printf '%s\n' "$SUBJECT_LINES" | grep -q '\*' && fail "federated credential subject contains a wildcard"
AUD_LINES=$(printf '%s\n' "$ESO_CODE" | grep -E '^[[:space:]]*audiences[[:space:]]*=' || true)
[ "$(printf '%s\n' "$AUD_LINES" | grep -c .)" = "1" ] &&
	printf '%s\n' "$AUD_LINES" | grep -qE '^[[:space:]]*audiences[[:space:]]*=[[:space:]]*\["api://AzureADTokenExchange"\][[:space:]]*$' ||
	fail 'federated credential audiences must be exactly ["api://AzureADTokenExchange"]'
grep -vE '^[[:space:]]*#' ../onprem-oidc/variables.tf | grep -q '"qi"' ||
	fail "onprem-oidc k3s_jwks validation does not reject private key members"

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

# The k3s role's ORDER is checkable (the site issuer value is not): the new issuer is listed FIRST (k3s signs
# with it), the old default second.
K3S_TPL=../../ansible/roles/k3s_server/templates/config.yaml.j2
NEW_LN=$(grep -n 'service-account-issuer={{ k3s_server_oidc_issuer }}' "$K3S_TPL" | head -1 | cut -d: -f1)
OLD_LN=$(grep -n 'service-account-issuer={{ k3s_server_oidc_issuer_old }}' "$K3S_TPL" | head -1 | cut -d: -f1)
[ -n "$NEW_LN" ] && [ -n "$OLD_LN" ] && [ "$NEW_LN" -lt "$OLD_LN" ] ||
	fail "k3s_server template must list the new issuer BEFORE the old default (k3s signs with the first)"

# 7. Prod identity (prod_apps.tf): the prod sign-in callback is the deployed
#    host only (no loopback, ever) and the prod service app never carries
#    Mail.Send — prod mail is Exchange RBAC, not an Entra permission.
PROD_CODE=$(grep -vE '^[[:space:]]*#' prod_apps.tf)
printf '%s\n' "$PROD_CODE" | grep -q 'https://opshub.qnsc.vn/api/auth/callback/microsoft' ||
	fail "prod_apps.tf: the OpsHub Prod sign-in callback is missing"
printf '%s\n' "$PROD_CODE" | grep -qE 'localhost|127\.0\.0\.1' &&
	fail "prod_apps.tf: a loopback redirect — prod sign-in uses the deployed callback only"
printf '%s\n' "$PROD_CODE" | grep -qi 'Mail\.Send' &&
	fail "prod_apps.tf: Mail.Send in Entra — prod mail is Exchange RBAC only"

# 8. Prod identity: the sign-in app refuses to apply without the service
#    certificate, so a 9-add partial shape cannot be applied.
grep -A90 'resource "azuread_application" "opshub_prod"' prod_apps.tf |
	grep -q 'condition[[:space:]]*=[[:space:]]*var\.opshub_prod_service_certificate != null' ||
	fail "prod_apps.tf: the OpsHub Prod app has no precondition on the service certificate"

echo "PASS: static guard"
