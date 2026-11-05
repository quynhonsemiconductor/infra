#!/usr/bin/env bash
# rotate-signin-secret.sh — owner-run: rotate ONE sign-in app's client secret
# and land it in the vault. Nothing secret is printed; nothing enters argv or
# TF state (§7). TF owns the registration; this owns the credential.
#
#   ./scripts/rotate-signin-secret.sh <app-id|object-id|/applications/<object-id>> \
#     <vault> <secret-name>
#
# All three id forms are accepted: `az ad app credential reset --id` takes the
# appId or the object id, and the azuread 3.x state/output form
# `/applications/<object-id>` is stripped first (az rejects that URI form).
#
# --append NEVER wipes existing secrets (rova prod on AWS is using one right
# now); the NEW credential's --end-date is +6 months (≤ the 6-month policy),
# the VAULT secret gets the same --expires, and the weekly expiry watch
# (.github/workflows/secret-expiry.yml, docs/runbooks/secret-expiry.md) alerts at < 30 days
# (§7.5). Revoke superseded credentials after the next green deploy.
#
# ORDER: the credential EXISTS the moment the reset returns, so the password
# is written to the vault BEFORE anything else can fail. `-o json` from the
# reset carries appId/password/tenant only — NO keyId — so the keyId is read
# afterwards from the credential list by the display name this run created.
set -euo pipefail

usage() {
	echo "usage: $0 <app-id|object-id|/applications/<object-id>> <vault> <secret-name>" >&2
	exit 2
}

[[ $# -eq 3 ]] || usage
raw="$1"; vault="$2"; secret_name="$3"
[[ -n "$vault" && -n "$secret_name" ]] || usage

app="${raw#/applications/}"
[[ -n "$app" ]] || {
	echo "STOP: app id is empty after stripping /applications/" >&2
	exit 1
}

name="rotated-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
end="$(date -v+6m +%Y-%m-%dT00:00:00Z)"

reset=$(az ad app credential reset --id "$app" --append \
	--display-name "$name" \
	--end-date "$end" --only-show-errors -o json)

# The password is captured and piped; it is never echoed. jq runs with -e, so a
# missing/empty password stops here — BEFORE any vault prompt — with no
# credential created by a failed parse (the reset already failed if it exits).
password=$(printf '%s' "$reset" | jq -er '.password' 2>/dev/null) || {
	echo "STOP: the reset returned no password — no vault write attempted" >&2
	exit 1
}
printf 'storing %s chars\n' "${#password}" >&2

# Vault write FIRST: after this the credential can never be an orphan with a
# password nobody holds.
printf '%s' "$password" | az keyvault secret set --vault-name "$vault" --name "$secret_name" \
	--file /dev/stdin --content-type "text/plain" \
	--expires "$end" \
	--tags owner=platform "rotated=$(date -u +%Y-%m-%d)" -o none
unset password reset

# keyId is NOT in the reset output; read it from the list by the unique
# display name. Failure here is a warning, not an error: the secret is already
# safe in the vault and nothing secret is at stake.
kid=""
creds=$(az ad app credential list --id "$app" --only-show-errors -o json 2>/dev/null || true)
if [[ -n "$creds" ]]; then
	kid=$(printf '%s' "$creds" |
		jq -r --arg n "$name" 'map(select(.displayName == $n)) | .[0].keyId // empty' 2>/dev/null || true)
fi
if [[ -z "$kid" ]]; then
	echo "WARN: secret stored, but no credential named '$name' was listed — inspect the app's credentials by hand." >&2
else
	echo "new credential keyId $kid — revoke this if the rotation was wrong"
fi

echo "rotated: $secret_name in $vault (vault secret +6m; new credential --end-date $end; old credentials kept — revoke manually after the next green deploy)."
