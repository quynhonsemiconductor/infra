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
# ORDER: the credential EXISTS the moment the reset returns. `-o json` from the
# reset carries appId/password/tenant only — NO keyId — so the keyId is read
# first from the credential list by the display name this run created and
# printed to STDERR BEFORE the vault write: if the write fails, the orphan has
# a handle the owner can revoke. The password then goes to the vault before
# any other step can fail.
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

# The password is captured and piped; it is never echoed or passed in argv. jq
# runs with -e, so a missing/empty password stops here — BEFORE any vault write
# — with no credential created by a failed parse (the reset already failed if
# it exits).
password=$(printf '%s' "$reset" | jq -er '.password' 2>/dev/null) || {
	echo "STOP: the reset returned no password — no vault write attempted" >&2
	exit 1
}
printf 'storing %s chars\n' "${#password}" >&2

# keyId is NOT in the reset output. Read it from the list by the unique display
# name BEFORE the vault write, so a failed write still leaves a revocable handle
# on stderr. A failed lookup is a warning: the vault write below must still run.
kid=""
creds=$(az ad app credential list --id "$app" --only-show-errors -o json 2>/dev/null || true)
if [[ -n "$creds" ]]; then
	kid=$(printf '%s' "$creds" |
		jq -r --arg n "$name" 'map(select(.displayName == $n)) | .[0].keyId // empty' 2>/dev/null || true)
fi
if [[ -n "$kid" ]]; then
	echo "new credential keyId $kid — revoke it if the vault write below fails" >&2
else
	echo "WARN: the new credential's keyId was not listed — if the vault write fails, find it in the app's credentials by display name '$name' and revoke it." >&2
fi

# Vault write: the credential gains a password holder; the keyId above is its
# handle whether or not this succeeds.
printf '%s' "$password" | az keyvault secret set --vault-name "$vault" --name "$secret_name" \
	--file /dev/stdin --content-type "text/plain" \
	--expires "$end" \
	--tags owner=platform "rotated=$(date -u +%Y-%m-%d)" -o none
unset password reset creds

echo "rotated: $secret_name in $vault (vault secret +6m; new credential --end-date $end; old credentials kept — revoke manually after the next green deploy)."
