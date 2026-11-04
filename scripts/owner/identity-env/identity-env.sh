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
# --- mail service certificates: the PINNED keyIds are the source of truth; the kit only ASSERTS ----------------
# The keyIds live in mail.tf (two-space indent, one entry per line) because a value arriving through a variable can
# be missing or mistyped, and that empties a resource's for_each: the apply would DESTROY the live credential.
# Here the kit only checks that every pinned credential is live, that nothing unknown is live, and that the data is
# complete; it never decides which credential belongs where.
MAIL_TF="$STACK/mail.tf"
[[ -r "$MAIL_TF" ]] || die "mail.tf not found in $STACK"
pinned_primary() { # "<slot> <keyId>" lines of local.mail_service_cert_key_ids
  sed -n '/^  mail_service_cert_key_ids = {/,/^  }/p' "$MAIL_TF" \
    | grep -oE '^ +[a-z_]+ *= *"[0-9a-f-]{36}"' \
    | sed -E 's/^ +([a-z_]+) *= *"([0-9a-f-]{36})"/\1 \2/'
}
pinned_rotated() { # "<slot> <keyId>" lines of local.mail_service_rotated_cert_key_ids
  sed -n '/^  mail_service_rotated_cert_key_ids = {/,/^  }/p' "$MAIL_TF" \
    | grep -E '^ +[a-z_]+ *=.*[0-9a-f]{8}-' \
    | while IFS= read -r l; do
        s=$(sed -E 's/^ +([a-z_]+) *=.*/\1/' <<<"$l")
        grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$l" \
          | while read -r i; do echo "$s $i"; done
      done
}
pins_file() { awk -v s="$1" '$1==s{print $2}' <<<"$PINS"; }
PRIMARY_PINS=$(pinned_primary); ROTATED_PINS=$(pinned_rotated)
[[ -n "$PRIMARY_PINS" ]] || die "no pinned certificate keyIds in $MAIL_TF"
PINS="$PRIMARY_PINS
$ROTATED_PINS"
want=$(printf '%s\n' "${KEYS[@]}" | sort | tr '\n' ' ')
have=$(awk 'NF{print $1}' <<<"$PRIMARY_PINS" | sort | tr '\n' ' ')
[[ "$want" == "$have" ]] || die "mail_service_cert_key_ids must pin exactly these slots: ${KEYS[*]}"
while read -r slot id; do
  [[ -n "$slot" ]] || continue
  case " ${KEYS[*]} " in *" $slot "*) ;; *) die "mail_service_rotated_cert_key_ids pins an unknown slot: $slot" ;; esac
done <<<"$ROTATED_PINS"

thumb_of_pem() { openssl x509 -noout -fingerprint -sha1 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'; }
# key_pem <base64 key> <out file>: Graph's keyCredentials[].key is base64 of whatever was uploaded: DER (portal, az)
# or the PEM text itself (the azuread provider with encoding = "pem"). PEM is kept byte for byte (trailing newline
# included) so the value equals the one in state; DER is converted. Public certificates only.
key_pem() {
  printf '%s' "$1" | base64 -d >"$2.raw" 2>/dev/null || return 1
  if grep -q 'BEGIN CERTIFICATE' "$2.raw"; then mv "$2.raw" "$2"
  else openssl x509 -inform DER -outform PEM -in "$2.raw" -out "$2" 2>/dev/null || return 1; rm -f "$2.raw"; fi
  ! grep -q 'PRIVATE KEY' "$2" && openssl x509 -in "$2" -noout 2>/dev/null
}
CERTS='{}'; ROTATED='{}'
for k in "${KEYS[@]}"; do
  f="$APPS_DIR/service-$k.json"
  oid=$(jq -r '.id // empty' "$f"); need_guid "service $k object id" "$oid"
  # ALL credentials at once, key bytes included: Graph returns keyCredentials[].key only on a single-object GET
  # with $select=keyCredentials. No Key Vault (the prod entry also holds the private key), no 1Password copy to drift.
  kc=$(az_json "mail certs $k" rest --method get --url "https://graph.microsoft.com/v1.0/applications/$oid?\$select=keyCredentials" \
    | jq -c '.keyCredentials')
  n=$(jq 'length' <<<"$kc")
  [[ "$n" -ge 1 ]] || die "service app $k carries no key credential"
  : >"$APPS_DIR/ids-$k"
  j=0
  # Non-whitespace IFS: a whitespace IFS collapses empty fields, which would shift a null startDateTime into `key`.
  while IFS='|' read -r kid cki start key; do
    j=$((j+1))
    need_guid "service $k keyId" "$kid"
    [[ -n "$start" ]] || die "service app $k credential $j has no startDateTime"
    # customKeyIdentifier is normally base64 of the SHA-1 bytes; a cert added with the HEX thumbprint where base64
    # was expected (rova-prod, by hand) comes back as those 40 hex characters. Accept both forms.
    if [[ "$cki" =~ ^[0-9A-Fa-f]{40}$ ]]; then want=$(tr 'A-F' 'a-f' <<<"$cki")
    else want=$(printf '%s' "$cki" | base64 -d 2>/dev/null | xxd -p | tr -d '\n'); fi
    [[ -n "$want" ]] || die "service $k credential $j has no customKeyIdentifier (thumbprint)"
    pem="$APPS_DIR/cred-$kid.pem"
    if [[ -z "$key" ]] || ! key_pem "$key" "$pem"; then die "lookup failed: mail cert $k"; fi
    have=$(thumb_of_pem <"$pem")
    [[ -n "$have" && "$have" == "$want" ]] || die "mail cert $k thumbprint differs from the certificate live on the app (a replace would be planned)"
    printf '%s\n' "$kid" >>"$APPS_DIR/ids-$k"
  done < <(jq -r '.[] | [.keyId, (.customKeyIdentifier // ""), (.startDateTime // ""), (.key // "")] | join("|")' <<<"$kc")
  # Every pinned credential must be on this app...
  while read -r id; do
    [[ -n "$id" ]] || continue
    grep -qx "$id" "$APPS_DIR/ids-$k" || die "a credential pinned for $k is not on the app (check mail.tf)"
  done < <(pins_file "$k")
  # ...and nothing unpinned may be live: adding a credential is a reviewed mail.tf change, never a silent extra.
  while read -r id; do
    awk 'NF{print $2}' <<<"$PINS" | grep -qx "$id" \
      || die "service app $k carries an UNPINNED credential $id — add its keyId to mail.tf (local.mail_service_rotated_cert_key_ids) before planning"
  done <"$APPS_DIR/ids-$k"
  primary=$(pins_file "$k" | head -1)
  CERTS=$(jq -c --arg k "$k" --rawfile v "$APPS_DIR/cred-$primary.pem" '.[$k]=$v' <<<"$CERTS")
done
while read -r slot id; do
  [[ -n "$id" ]] || continue
  ROTATED=$(jq -c --arg id "$id" --rawfile v "$APPS_DIR/cred-$id.pem" '.[$id]=$v' <<<"$ROTATED")
done <<<"$ROTATED_PINS"
put TF_VAR_mail_service_certificates "$CERTS"
put TF_VAR_mail_service_rotated_certificates "$ROTATED"

# --- Graph application-role grants already created by admin consent ------------------------------------------
# A grant lives on the Microsoft Graph service principal, not on the app: a plan that CREATES one without
# importing it first adds a DUPLICATE. The direction is appRoleAssignments ("grants THIS SP holds");
# appRoleAssignedTo is the opposite one (who holds a role ON this SP) and returns nothing useful here.
GRAPH_APP_ID=00000003-0000-0000-c000-000000000000   # Microsoft Graph, well-known
GRAPH_SP=$(az_json "graph service principal" ad sp show --id "$GRAPH_APP_ID" | jq -r '.id // empty')
need_guid "Microsoft Graph SP object id" "$GRAPH_SP"
GRAPH_ROLES=$(az_json "graph app roles" rest --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GRAPH_SP/appRoles" \
  | jq -c '[.value[] | {(.id): .value}] | add // {}')
grants_of() { # <sp object id>: JSON object {role value: assignment id} for the Graph grants this SP holds
  az_json "app role assignments" rest --method get \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/$1/appRoleAssignments" \
    | jq -c --argjson m "$GRAPH_ROLES" --arg g "$GRAPH_SP" \
        '[.value[] | select(.resourceId == $g and $m[.appRoleId] != null) | {($m[.appRoleId]): .id}] | add // {}'
}
MAIL_GRANTS='{}'
for k in "${KEYS[@]}"; do
  g=$(grants_of "$(<"$APPS_DIR/service-$k.sp")")
  while IFS=$'\t' read -r role aid; do
    MAIL_GRANTS=$(jq -c --arg k "$k/$role" --arg v "$aid" '.[$k]=$v' <<<"$MAIL_GRANTS")
  done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"$g")
done
[[ "$MAIL_GRANTS" == "{}" ]] || put TF_VAR_mail_service_graph_grant_ids "$MAIL_GRANTS"

# OpsHub Prod Service (prod_apps.tf): same grants, keyed by role value. Optional app: it exists only once the
# 2026-11-04 prod apply created it. The stack gates its import block on the certificate variable.
OPS=$(az ad app list --filter "displayName eq 'OpsHub Prod Service'" -o json 2>/dev/null) \
  || die "az lookup failed: OpsHub Prod Service"
case "$(jq 'length' <<<"$OPS")" in
  0) ;;
  1) opsapp=$(jq -r '.[0].appId // empty' <<<"$OPS"); need_guid "OpsHub Prod Service appId" "$opsapp"
     opssp=$(az_json "service principal of OpsHub Prod Service" ad sp list --filter "appId eq '$opsapp'")
     [[ "$(jq 'length' <<<"$opssp")" == "1" ]] || die "expected exactly 1 service principal for 'OpsHub Prod Service'"
     OPSIDS=$(grants_of "$(jq -r '.[0].id' <<<"$opssp")")
     [[ "$OPSIDS" == "{}" ]] || put TF_VAR_opshub_prod_service_graph_grant_ids "$OPSIDS" ;;
  *) die "expected at most 1 app named 'OpsHub Prod Service'" ;;
esac

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
    key=$(jq -r '.keyCredentials[0].key // empty' <<<"$kc")
    if [[ -z "$key" ]] || ! key_pem "$key" "$APPS_DIR/eso-$p.pem"; then die "lookup failed: eso cert $p"; fi
    E=$(jq -c --arg k "$p" --rawfile v "$APPS_DIR/eso-$p.pem" '.[$k]=$v' <<<"$E")
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
