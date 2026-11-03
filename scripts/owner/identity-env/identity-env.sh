#!/usr/bin/env bash
# Owner apply kit for live/identity: BUILDS every TF_VAR_* that has no default from read-only `az`
# lookups, so no value is typed, kept in a file or committed. Run it in the owner's own terminal (`az login`
# done, `op` signed in: 1Password app integration only answers there, never in CI or an agent).
#
#   scripts/owner/identity-env/identity-env.sh                          # check: print NAMES and LENGTHS only
#   scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan # build the env, run the command in live/identity
#
# The environment exists only inside the child process, so nothing lands in the parent shell or its history.
# Nothing is ever printed except variable names, lengths and the failed lookup's name. A lookup that is empty,
# ambiguous (two apps with the same name) or malformed stops the run: the kit never continues on a guess.
#
# Inputs that cannot be read from Entra (set in your shell, never in Git: Tier 1 identifiers):
#   IDENTITY_SECOND_OWNER_UPN   UPN of the second company owner (the signed-in user is the owner operator)
#   IDENTITY_PROXMOX_HOST       hostname of the Proxmox realm (admin door); the redirect URI is https://<host>/
# Optional:
#   IDENTITY_STACK_DIR (live/identity, relative to the repo root)
set -euo pipefail

STACK="${IDENTITY_STACK_DIR:-live/identity}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[[ "$STACK" = /* ]] || STACK="$ROOT/$STACK"

die() { echo "STOP: $*" >&2; exit 1; }
for c in az jq openssl xxd; do command -v "$c" >/dev/null || die "need $c"; done

MODE=check
if [[ "${1:-}" == "--" ]]; then MODE=run; shift; [[ $# -gt 0 ]] || die "nothing to run after --"; elif [[ $# -gt 0 ]]; then die "usage: identity-env.sh [-- command...]"; fi

NAMES=()
put() { # put TF_VAR_name value  (value stays in the environment, only name + length are reported)
  [[ -n "$2" ]] || die "lookup for $1 is empty"
  export "$1=$2"; NAMES+=("$1")
}
guid_ok() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
need_guid() { guid_ok "$2" || die "$1 is not a GUID"; }
az_json() { # az_json <what> args... : stderr dropped, empty/failed lookup stops
  local what="$1" out; shift
  out=$(az "$@" -o json 2>/dev/null) || die "az lookup failed: $what"
  [[ -n "$out" && "$out" != "null" && "$out" != "[]" ]] || die "az lookup empty: $what"
  printf '%s' "$out"
}
rfc3339() { # normalise an Azure timestamp to the RFC3339 UTC form the stack validates
  local t="${1/+00:00/Z}"; t="${t%.0000000Z}Z"; t="${t/ZZ/Z}"
  [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "budget timestamp is not RFC3339 UTC"
  printf '%s' "$t"
}

# --- tenant-level scalars ------------------------------------------------------------------------
SUB=$(az_json subscription account show | jq -r '.id // empty')
need_guid subscription_id "$SUB"
put TF_VAR_subscription_id "$SUB"; put ARM_SUBSCRIPTION_ID "$SUB"

BUDGET=$(az_json budget consumption budget list)
[[ "$(jq 'length' <<<"$BUDGET")" == "1" ]] || die "expected exactly 1 budget"
put TF_VAR_budget_period_start "$(rfc3339 "$(jq -r '.[0].timePeriod.startDate // empty' <<<"$BUDGET")")"
put TF_VAR_budget_period_end "$(rfc3339 "$(jq -r '.[0].timePeriod.endDate // empty' <<<"$BUDGET")")"

ORG=$(az_json tenant-domains rest --method get --url https://graph.microsoft.com/v1.0/organization)
# Break-glass accounts live on the INITIAL *.onmicrosoft.com domain (never a custom domain they could lose).
put TF_VAR_break_glass_upn_domain "$(jq -r '[.value[0].verifiedDomains[]|select(.isInitial)|.name]|if length==1 then .[0] else empty end' <<<"$ORG")"

grp_id() { local id; id=$(az_json "group $1" ad group show --group "$1" | jq -r '.id // empty'); need_guid "group $1" "$id"; printf '%s' "$id"; }
put TF_VAR_platform_admins_object_id "$(grp_id grp-qnsc-platform-admins)"
put TF_VAR_grp_dev_users_object_id "$(grp_id grp-qnsc-dev-users)"

# --- people --------------------------------------------------------------------------------------
OWNER=$(az_json signed-in-user ad signed-in-user show | jq -r '.id // empty'); need_guid owner_operator_object_id "$OWNER"
put TF_VAR_owner_operator_object_id "$OWNER"
[[ -n "${IDENTITY_SECOND_OWNER_UPN:-}" ]] || die "set IDENTITY_SECOND_OWNER_UPN"
SECOND=$(az_json second-owner ad user show --id "$IDENTITY_SECOND_OWNER_UPN" | jq -r '.id // empty'); need_guid second_owner_object_id "$SECOND"
put TF_VAR_second_owner_object_id "$SECOND"
# The Proxmox admins ARE the platform-admins group's user members (README: keep the two in step).
ADMINS=$(az_json platform-admins-members ad group member list --group grp-qnsc-platform-admins \
  | jq -c '[.[]|select(.["@odata.type"]=="#microsoft.graph.user")|.id]|sort')
[[ "$(jq 'length' <<<"$ADMINS")" -gt 0 ]] || die "grp-qnsc-platform-admins has no user members"
while read -r g; do need_guid proxmox_admin_object_ids "$g"; done < <(jq -r '.[]' <<<"$ADMINS")
put TF_VAR_proxmox_admin_object_ids "$ADMINS"
[[ "${IDENTITY_PROXMOX_HOST:-}" =~ ^[A-Za-z0-9.-]+$ ]] || die "set IDENTITY_PROXMOX_HOST (a bare hostname)"
put TF_VAR_proxmox_redirect_uris "$(jq -cn --arg h "$IDENTITY_PROXMOX_HOST" '["https://\($h)/"]')"

# --- app registrations ---------------------------------------------------------------------------
# bash 3.2 (macOS /bin/bash) has no associative arrays: slot -> display name by function.
signin_name() { case "$1" in rova_prod) echo "Rova Prod";; rova_dev) echo "Rova Dev";; opshub_dev) echo "OpsHub Dev";; kb_dev) echo "KB Dev";; esac; }
KEYS=(rova_prod rova_dev opshub_dev kb_dev)
APPS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/identity-env.XXXXXX"); trap 'rm -rf "$APPS_DIR"' EXIT   # public ids only (no secrets), removed on exit

fetch_app() { # fetch_app <slot> <display name> <file prefix>: exactly one app; its SP; ids validated
  local slot="$1" name="$2" pfx="$3" apps appid sp
  apps=$(az_json "app $name" ad app list --filter "displayName eq '$name'")
  [[ "$(jq 'length' <<<"$apps")" == "1" ]] || die "expected exactly 1 app named '$name'"
  jq '.[0]' <<<"$apps" >"$APPS_DIR/$pfx-$slot.json"
  appid=$(jq -r '.appId // empty' "$APPS_DIR/$pfx-$slot.json")
  need_guid "$name appId" "$appid"; need_guid "$name object id" "$(jq -r '.id // empty' "$APPS_DIR/$pfx-$slot.json")"
  sp=$(az_json "service principal of $name" ad sp list --filter "appId eq '$appid'")
  [[ "$(jq 'length' <<<"$sp")" == "1" ]] || die "expected exactly 1 service principal for '$name'"
  need_guid "$name SP object id" "$(jq -r '.[0].id // empty' <<<"$sp")"
  jq -r '.[0].id' <<<"$sp" >"$APPS_DIR/$pfx-$slot.sp"
}
map_of() { # map_of <prefix> <app jq path| sp>: JSON object keyed by slot
  local pfx="$1" what="$2" out='{}' k v
  for k in "${KEYS[@]}"; do
    if [[ "$what" == sp ]]; then v=$(<"$APPS_DIR/$pfx-$k.sp"); else v=$(jq -r "$what // empty" "$APPS_DIR/$pfx-$k.json"); fi
    [[ -n "$v" ]] || die "$pfx/$k: empty $what"
    out=$(jq -c --arg k "$k" --arg v "$v" '.[$k]=$v' <<<"$out")
  done
  printf '%s' "$out"
}
for k in "${KEYS[@]}"; do fetch_app "$k" "$(signin_name "$k")" signin; fetch_app "$k" "$(signin_name "$k") Service" service; done
put TF_VAR_existing_object_ids "$(map_of signin .id)"
put TF_VAR_existing_sp_object_ids "$(map_of signin sp)"
put TF_VAR_mail_service_object_ids "$(map_of service .id)"
put TF_VAR_mail_service_sp_object_ids "$(map_of service sp)"

ROLES=$(jq -c '[.appRoles[]?|select(.isEnabled!=false)|{(.value):.id}]|add // {}' "$APPS_DIR/signin-opshub_dev.json")
jq -e 'keys==["admin","auditor","helpdesk","hr","it-admin","manager","security"] and ([.[]|test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")]|all)' <<<"$ROLES" >/dev/null \
  || die "OpsHub Dev must carry exactly the 7 app roles (admin it-admin security hr manager helpdesk auditor) with GUID ids"
put TF_VAR_opshub_dev_app_role_ids "$ROLES"

# --- mail service certificates: public PEM per app, bound to the keyId and thumbprint Entra holds -----------
thumb_of_pem() { openssl x509 -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'; }
KEYIDS='{}'; CERTS='{}'
for k in "${KEYS[@]}"; do
  f="$APPS_DIR/service-$k.json"
  [[ "$(jq '.keyCredentials|length' "$f")" == "1" ]] || die "service app $k must carry exactly 1 key credential"
  kid=$(jq -r '.keyCredentials[0].keyId // empty' "$f"); need_guid "service $k keyId" "$kid"
  # customKeyIdentifier is normally base64 of the SHA-1 bytes; a cert added with the HEX thumbprint where base64 was
  # expected (rova-prod, by hand) comes back as those 40 hex characters. Accept both forms.
  cki=$(jq -r '.keyCredentials[0].customKeyIdentifier // empty' "$f")
  if [[ "$cki" =~ ^[0-9A-Fa-f]{40}$ ]]; then want=$(tr 'A-F' 'a-f' <<<"$cki")
  else want=$(printf '%s' "$cki" | base64 -d 2>/dev/null | xxd -p | tr -d '\n'); fi
  [[ -n "$want" ]] || die "service $k has no customKeyIdentifier (thumbprint)"
  # The PUBLIC certificate comes from Entra itself: Graph returns keyCredentials[].key (base64 DER) only on a single-object
  # GET with $select=keyCredentials. No Key Vault (the prod entry also holds the private key), no 1Password copy to drift.
  oid=$(jq -r '.id // empty' "$f"); need_guid "service $k object id" "$oid"
  pem=$(az_json "mail cert $k" rest --method get --url "https://graph.microsoft.com/v1.0/applications/$oid?\$select=keyCredentials" \
    | jq -r '.keyCredentials[0].key // empty' | base64 -d 2>/dev/null | openssl x509 -inform DER -outform PEM 2>/dev/null) \
    || die "lookup failed: mail cert $k"
  [[ -n "$pem" ]] || die "lookup failed: mail cert $k"
  [[ "$pem" == *"BEGIN CERTIFICATE"* ]] || die "mail cert $k is not a certificate"
  [[ "$pem" != *"PRIVATE KEY"* ]] || die "mail cert $k carries a private key: refusing"
  have=$(printf '%s\n' "$pem" | thumb_of_pem)
  [[ -n "$have" && "$have" == "$want" ]] || die "mail cert $k thumbprint differs from the certificate live on the app (a replace would be planned)"
  KEYIDS=$(jq -c --arg k "$k" --arg v "$kid" '.[$k]=$v' <<<"$KEYIDS")
  CERTS=$(jq -c --arg k "$k" --arg v "$pem" '.[$k]=$v' <<<"$CERTS")
done
put TF_VAR_mail_service_cert_key_ids "$KEYIDS"
put TF_VAR_mail_service_certificates "$CERTS"

# --- ESO certificates: only while the stack still declares the variable (removed by the #254 PR) -------------
# The PUBLIC certificate live on each ESO app, from Graph like the mail certs: a file on disk can be stale (rotation)
# and a stale value plans a REPLACE that takes the ClusterSecretStores' credential away.
if grep -qs '^variable "eso_certificates"' "$STACK"/*.tf; then
  E='{}'
  for p in dev prod platform; do
    n="QNSC ESO $(tr '[:lower:]' '[:upper:]' <<<"${p:0:1}")${p:1}"
    a=$(az_json "eso app $p" ad app list --filter "displayName eq '$n'")
    [[ "$(jq 'length' <<<"$a")" == "1" ]] || die "exactly one app named '$n' expected"
    oid=$(jq -r '.[0].id // empty' <<<"$a"); need_guid "eso $p object id" "$oid"
    kc=$(az_json "eso cert $p" rest --method get --url "https://graph.microsoft.com/v1.0/applications/$oid?\$select=keyCredentials")
    [[ "$(jq '.keyCredentials|length' <<<"$kc")" == "1" ]] || die "eso app $p must carry exactly 1 key credential"
    pem=$(jq -r '.keyCredentials[0].key // empty' <<<"$kc" | base64 -d 2>/dev/null | openssl x509 -inform DER -outform PEM 2>/dev/null) \
      || die "lookup failed: eso cert $p"
    [[ "$pem" == *"BEGIN CERTIFICATE"* ]] || die "lookup failed: eso cert $p"
    E=$(jq -c --arg k "$p" --arg v "$pem" '.[$k]=$v' <<<"$E")
  done
  put TF_VAR_eso_certificates "$E"
fi

if [[ "$MODE" == check ]]; then
  echo "identity env OK: ${#NAMES[@]} variables (name, length)"
  for n in "${NAMES[@]}"; do v="${!n}"; printf '  %-40s %s\n' "$n" "${#v}"; done
  exit 0
fi
cd "$STACK"
# No exec: the EXIT trap must still remove the temp dir after the child ends.
set +e
"$@"
rc=$?
exit "$rc"
