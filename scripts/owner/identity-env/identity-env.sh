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
#   IDENTITY_PROXMOX_HOST       hostname of the Proxmox VE admin door; the redirect URI is https://<host>/
#   IDENTITY_PBS_HOST           hostname of the Proxmox Backup Server admin door; the redirect URI is https://<host>/
#                               (both are REQUIRED: the app backs both realms, runbook server-setup §3.2.1)
# Optional:
#   IDENTITY_OWNER_OPERATOR_UPN    the owner operator, when there is no signed-in user (CI OIDC: the read
#                                  identity runs the nightly drift plan). Must be a Member user. Unset =
#                                  the signed-in user, the normal owner-terminal behaviour.
#   IDENTITY_DEV_APP_EXTRA_OWNERS  extra OWNERS for DEV sign-in apps only, as comma-separated
#                                  app=upn pairs (e.g. opshub_dev=dev@example.com). Each UPN must be
#                                  a Member user. Unset = no extras (empty map, today's behaviour).
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
# host_ok <hostname>: DNS labels only — alphanumeric ends, hyphens inside, 1-63 chars per label,
# no empty label, no leading/trailing dot or dash, <= 253 chars. No port, no scheme, no path.
host_ok() {
  [[ -n "$1" && ${#1} -le 253 ]] &&
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
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
ADMINS_GROUP=$(grp_id grp-qnsc-platform-admins)
put TF_VAR_grp_platform_admins_object_id "$ADMINS_GROUP"
put TF_VAR_grp_developers_object_id "$(grp_id grp-qnsc-developers)"
put TF_VAR_grp_dev_users_object_id "$(grp_id grp-qnsc-dev-users)"

# --- people --------------------------------------------------------------------------------------
# The owner operator is normally the signed-in user. In CI (an OIDC service principal) there is no
# signed-in user, so IDENTITY_OWNER_OPERATOR_UPN names the person instead; the lookup is the same
# Graph users?$select=id,userType read used for the extra DEV owners, and a guest stops the run.
if [[ -n "${IDENTITY_OWNER_OPERATOR_UPN:-}" ]]; then
  enc=$(jq -rn --arg v "$IDENTITY_OWNER_OPERATOR_UPN" '$v|@uri')
  me=$(az_json owner-operator rest --method get \
    --url "https://graph.microsoft.com/v1.0/users/$enc?\$select=id,userType")
  [[ "$(jq -r '.userType // empty' <<<"$me")" == "Member" ]] \
    || die "IDENTITY_OWNER_OPERATOR_UPN is a guest or non-Member user"
  OWNER=$(jq -r '.id // empty' <<<"$me")
else
  OWNER=$(az_json signed-in-user ad signed-in-user show | jq -r '.id // empty')
fi
need_guid owner_operator_object_id "$OWNER"
put TF_VAR_owner_operator_object_id "$OWNER"
[[ -n "${IDENTITY_SECOND_OWNER_UPN:-}" ]] || die "set IDENTITY_SECOND_OWNER_UPN"
SECOND=$(az_json second-owner ad user show --id "$IDENTITY_SECOND_OWNER_UPN" | jq -r '.id // empty'); need_guid second_owner_object_id "$SECOND"
put TF_VAR_second_owner_object_id "$SECOND"
# Extra owners for DEV sign-in apps only (app=upn,...). An app owner can add client credentials and
# redirect URIs, so prod keys are refused here too; variables.tf rejects them again at plan time.
# UPNs come from the shell and object ids stay in the child environment: nothing is committed.
unset TF_VAR_dev_app_extra_owner_object_ids   # never inherit a stale export into this run
EXTRA_OWNERS='{}'
if [[ -n "${IDENTITY_DEV_APP_EXTRA_OWNERS:-}" ]]; then
  while IFS= read -r pair; do
    pair="${pair//[[:space:]]/}"
    [[ -n "$pair" ]] || continue
    [[ "$pair" == *=* ]] || die "IDENTITY_DEV_APP_EXTRA_OWNERS: expected app=upn"
    key="${pair%%=*}"; upn="${pair#*=}"
    case " rova_dev opshub_dev kb_dev " in
      *" $key "*) ;;
      *) die "IDENTITY_DEV_APP_EXTRA_OWNERS: $key is not a dev sign-in app" ;;
    esac
    [[ -n "$upn" ]] || die "IDENTITY_DEV_APP_EXTRA_OWNERS: $key has an empty UPN"
    # `az ad user show` omits userType on real tenants; Graph with $select returns it. Encode the UPN
    # (the @ must be %40) — the UPN itself is never printed.
    enc=$(jq -rn --arg v "$upn" '$v|@uri')
    extra=$(az_json dev-extra-owner rest --method get \
      --url "https://graph.microsoft.com/v1.0/users/$enc?\$select=id,userType")
    [[ "$(jq -r '.userType // empty' <<<"$extra")" == "Member" ]] \
      || die "IDENTITY_DEV_APP_EXTRA_OWNERS: $key has a guest or non-Member user"
    uid=$(jq -r '.id // empty' <<<"$extra"); need_guid "dev extra owner $key" "$uid"
    EXTRA_OWNERS=$(jq -c --arg k "$key" --arg v "$uid" '.[$k] = ((.[$k] // []) + [$v] | unique)' <<<"$EXTRA_OWNERS")
  done < <(tr ',' '\n' <<<"$IDENTITY_DEV_APP_EXTRA_OWNERS")
fi
[[ "$EXTRA_OWNERS" == "{}" ]] || put TF_VAR_dev_app_extra_owner_object_ids "$EXTRA_OWNERS"
if [[ "$MODE" == check && -z "${IDENTITY_DEV_APP_EXTRA_OWNERS:-}" ]]; then
  echo "NOTE: IDENTITY_DEV_APP_EXTRA_OWNERS is unset — the plan will REMOVE any hand-added DEV-app owner (e.g. on the OpsHub Dev registration). Set it to keep the developer as owner." >&2
fi
# The platform admins ARE the group's user members (README: keep the two in step). ONE list drives
# the Proxmox app's direct assignments and the OpsHub Dev/Prod Admin role: group-based app-role
# assignment needs Entra ID P1/P2, which the tenant does not have.
#
# `az ad group member list` does NOT return userType on real tenants, so read the members through
# Graph with the fields selected and page through @odata.nextLink. Do not fall back to the CLI: a
# missing userType would make every member look like a non-user.
members_json() {
  local url="https://graph.microsoft.com/v1.0/groups/$ADMINS_GROUP/members?\$select=id,userType,userPrincipalName"
  local out='[]' page
  while [[ -n "$url" ]]; do
    page=$(az_json platform-admins-members rest --method get --url "$url")
    out=$(jq -c --argjson p "$page" '. + ($p.value // [])' <<<"$out")
    url=$(jq -r '.["@odata.nextLink"] // empty' <<<"$page")
  done
  printf '%s' "$out"
}
MEMBERS=$(members_json)
# A guest, a nested group or any non-user member would turn the direct-assignment list into something
# Entra cannot assign to an app role: stop instead of silently filtering it out. Selected-field shape:
# only a Member user carries userType == "Member"; a group or service principal does not.
[[ "$(jq '[.[] | select((.userType // "") != "Member")] | length' <<<"$MEMBERS")" == 0 ]] \
  || die "grp-qnsc-platform-admins has a guest, nested group or non-Member member — remove it first"
ADMINS=$(jq -c '[.[].id]|sort' <<<"$MEMBERS")
[[ "$(jq 'length' <<<"$ADMINS")" -gt 0 ]] || die "grp-qnsc-platform-admins has no user members"
while read -r g; do need_guid platform_admin_object_ids "$g"; done < <(jq -r '.[]' <<<"$ADMINS")
put TF_VAR_platform_admin_object_ids "$ADMINS"
# Hostnames are case-insensitive: normalise before validation, the PVE != PBS check and the URI build.
PVE_HOST=$(tr '[:upper:]' '[:lower:]' <<<"${IDENTITY_PROXMOX_HOST:-}")
PBS_HOST=$(tr '[:upper:]' '[:lower:]' <<<"${IDENTITY_PBS_HOST:-}")
host_ok "$PVE_HOST" || die "set IDENTITY_PROXMOX_HOST (a bare DNS hostname)"
host_ok "$PBS_HOST" || die "set IDENTITY_PBS_HOST (a bare DNS hostname)"
[[ "$PVE_HOST" != "$PBS_HOST" ]] || die "IDENTITY_PROXMOX_HOST and IDENTITY_PBS_HOST must differ"
put TF_VAR_proxmox_redirect_uris "$(jq -cn --arg pve "$PVE_HOST" --arg pbs "$PBS_HOST" '["https://\($pve)/", "https://\($pbs)/"]')"

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
pinned_ids() { # pinned_ids <local name>: "<slot> <keyId>" lines (one entry per line, two-space indent)
  sed -n "/^  $1 = {/,/^  }/p" "$MAIL_TF" \
    | grep -E '^ +[a-z_]+ *=.*[0-9a-f]{8}-' \
    | while IFS= read -r l; do
        s=$(sed -E 's/^ +([a-z_]+) *=.*/\1/' <<<"$l")
        grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$l" \
          | while read -r i; do echo "$s $i"; done
      done
}
pins_file() { awk -v s="$1" '$1==s{print $2}' <<<"$PINS"; }
PRIMARY_PINS=$(pinned_ids mail_service_cert_key_ids)
ROTATED_PINS=$(pinned_ids mail_service_rotated_cert_key_ids)
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

# --- Delegated permission grants already live (AllPrincipals, resource = Microsoft Graph) ---------------------
# Without an import the grant resource would plan a CREATE and Entra answers 409 (duplicate). The id map is
# keyed like local.signin_delegated_grant_targets; an app with no AllPrincipals grant is simply absent and plans
# a create. Principal (single-user) grants are NOT imported: they are a different object and not the tenant-wide
# consent this stack manages.
# The same lookup yields what the guard in apps.tf needs: an apply REPLACES the
# grant's claim_values, so every scope the live grant carries must still be
# requested by the app. Both maps are built here so they cannot drift apart.
delegated_grant() { # <sign-in SP object id>: JSON {id, scopes} for the ONE AllPrincipals Graph grant, or empty
  az_json "delegated grants" rest --method get \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/$1/oauth2PermissionGrants" \
    | jq -c --arg g "$GRAPH_SP" '
        [.value[] | select(.consentType == "AllPrincipals" and .resourceId == $g)
         | {id, scopes: ((.scope // "") | split(" ") | map(select(. != "")))}]
        | if length == 0 then empty elif length == 1 then .[0] else error("more than one AllPrincipals Graph grant") end'
}
SIGNIN_GRANTS='{}'; SIGNIN_GRANT_SCOPES='{}'
for k in "${KEYS[@]}"; do
  dg=$(delegated_grant "$(<"$APPS_DIR/signin-$k.sp")")
  [[ -n "$dg" ]] || continue
  SIGNIN_GRANTS=$(jq -c --arg k "$k" --arg v "$(jq -r '.id' <<<"$dg")" '.[$k]=$v' <<<"$SIGNIN_GRANTS")
  SIGNIN_GRANT_SCOPES=$(jq -c --arg k "$k" --argjson v "$(jq -c '.scopes' <<<"$dg")" '.[$k]=$v' <<<"$SIGNIN_GRANT_SCOPES")
done
# OpsHub Prod sign-in app (prod_apps.tf): optional; it exists after the 2026-11-04 prod apply.
OPS_SIGNIN=$(az ad app list --filter "displayName eq 'OpsHub Prod'" -o json 2>/dev/null) \
  || die "az lookup failed: OpsHub Prod"
case "$(jq 'length' <<<"$OPS_SIGNIN")" in
  0) ;;
  1) osapp=$(jq -r '.[0].appId // empty' <<<"$OPS_SIGNIN"); need_guid "OpsHub Prod appId" "$osapp"
     ossp=$(az_json "service principal of OpsHub Prod" ad sp list --filter "appId eq '$osapp'")
     [[ "$(jq 'length' <<<"$ossp")" == "1" ]] || die "expected exactly 1 service principal for 'OpsHub Prod'"
     dg=$(delegated_grant "$(jq -r '.[0].id' <<<"$ossp")")
     if [[ -n "$dg" ]]; then
       SIGNIN_GRANTS=$(jq -c --arg k opshub_prod --arg v "$(jq -r '.id' <<<"$dg")" '.[$k]=$v' <<<"$SIGNIN_GRANTS")
       SIGNIN_GRANT_SCOPES=$(jq -c --arg k opshub_prod --argjson v "$(jq -c '.scopes' <<<"$dg")" '.[$k]=$v' <<<"$SIGNIN_GRANT_SCOPES")
     fi ;;
  *) die "expected at most 1 app named 'OpsHub Prod'" ;;
esac
# KB Prod sign-in app (kb_prod_apps.tf): optional; it exists after the kb prod apply. Its grant is created
# tenant-wide by the same resource, so a later run must import the live grant instead of planning a duplicate.
KB_SIGNIN=$(az ad app list --filter "displayName eq 'KB Prod'" -o json 2>/dev/null) \
  || die "az lookup failed: KB Prod"
case "$(jq 'length' <<<"$KB_SIGNIN")" in
  0) ;;
  1) kbapp=$(jq -r '.[0].appId // empty' <<<"$KB_SIGNIN"); need_guid "KB Prod appId" "$kbapp"
     kbsp=$(az_json "service principal of KB Prod" ad sp list --filter "appId eq '$kbapp'")
     [[ "$(jq 'length' <<<"$kbsp")" == "1" ]] || die "expected exactly 1 service principal for 'KB Prod'"
     dg=$(delegated_grant "$(jq -r '.[0].id' <<<"$kbsp")")
     if [[ -n "$dg" ]]; then
       SIGNIN_GRANTS=$(jq -c --arg k kb_prod --arg v "$(jq -r '.id' <<<"$dg")" '.[$k]=$v' <<<"$SIGNIN_GRANTS")
       SIGNIN_GRANT_SCOPES=$(jq -c --arg k kb_prod --argjson v "$(jq -c '.scopes' <<<"$dg")" '.[$k]=$v' <<<"$SIGNIN_GRANT_SCOPES")
     fi ;;
  *) die "expected at most 1 app named 'KB Prod'" ;;
esac
[[ "$SIGNIN_GRANTS" == "{}" ]] || put TF_VAR_signin_delegated_grant_ids "$SIGNIN_GRANTS"
[[ "$SIGNIN_GRANT_SCOPES" == "{}" ]] || put TF_VAR_signin_delegated_grant_scopes "$SIGNIN_GRANT_SCOPES"

# --- Cloudflare Access IdP app (cf_access.tf) --------------------------------------------------
# The app behind every Zero Trust door. Only ids: the app carries a credential, and the kit never
# reads credentials. Its AllPrincipals Graph grant comes from the same delegated lookup as the
# sign-in apps; a missing grant stops the run (the import id would be empty and the apply would
# create a duplicate grant, which Entra answers with 409).
fetch_app cf_access "QNSC Cloudflare Access" cfaccess
CF_GRANT=$(delegated_grant "$(<"$APPS_DIR/cfaccess-cf_access.sp")")
[[ -n "$CF_GRANT" ]] || die "'QNSC Cloudflare Access' has no AllPrincipals Graph grant"
put TF_VAR_cf_access_object_ids "$(jq -nc \
  --arg a "$(jq -r '.id // empty' "$APPS_DIR/cfaccess-cf_access.json")" \
  --arg s "$(<"$APPS_DIR/cfaccess-cf_access.sp")" \
  --arg g "$(jq -r '.id // empty' <<<"$CF_GRANT")" \
  '{application:$a, service_principal:$s, grant:$g}')"

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
