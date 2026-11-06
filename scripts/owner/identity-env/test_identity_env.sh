#!/usr/bin/env bash
# Offline tests for identity-env.sh. Stub `az` and `op` on PATH answer from fixtures shaped like the real CLI
# JSON (no live call, no credential). Checks: the happy path exports every variable, prints ONLY names and
# lengths (no id, host, UPN or PEM ever reaches stdout/stderr), run mode hands the env to the child, and every
# broken input (empty lookup, duplicate app, wrong thumbprint, private key, missing input) stops the run.
# A PASS here must fail on broken input.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/identity-env.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FX="$T/fx"; BIN="$T/bin"; mkdir -p "$FX" "$BIN" "$T/stack" "$T/eso"
for c in jq openssl xxd; do command -v "$c" >/dev/null || { echo "need $c"; exit 2; }; done

g() { printf '%08x-0000-4000-8000-%012x' "$1" "$2"; }   # deterministic GUIDs: g <n> <m>
mkcert() { openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/$1.key" -out "$T/$1.crt" -subj "/CN=stub-$1" -days 2 >/dev/null 2>&1; }
b64thumb() { openssl x509 -in "$1" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' | xxd -r -p | base64 | tr -d '\n'; }
slot_i() { case "$1" in rova_prod) echo 1;; rova_dev) echo 2;; opshub_dev) echo 3;; kb_dev) echo 4;; esac; }
keysf() { echo "$FX/keys-$(g 20 "$(slot_i "$1")").json"; }
addcred() { # addcred <slot> <cert> <keyId> <startDateTime>: append a credential (a rotation)
  local f; f=$(keysf "$1")
  jq -c --arg kid "$3" --arg th "$(b64thumb "$2")" --arg st "$4" \
    --arg key "$(openssl x509 -in "$2" -outform DER | base64 | tr -d '\n')" \
    '.+[{keyId:$kid,customKeyIdentifier:$th,startDateTime:$st,key:$key}]' "$f" >"$FX/x" && mv "$FX/x" "$f"
}
pins() { # pins [rotated keyIds for kb_dev ...]: write the pinned maps the kit parses out of mail.tf
  local ids='' id
  for id in "$@"; do ids="$ids{ pinned_key_id = \"$id\" }, "; done
  cat >"$T/stack/mail.tf" <<EOF
locals {
  mail_service_cert_key_ids = {
    rova_prod  = { pinned_key_id = "$(g 22 1)" }
    rova_dev   = { pinned_key_id = "$(g 22 2)" }
    opshub_dev = { pinned_key_id = "$(g 22 3)" }
    kb_dev     = { pinned_key_id = "$(g 22 4)" }
  }
  mail_service_rotated_cert_key_ids = {
    kb_dev = [${ids%, }]
  }
}
EOF
}

KEYS=(rova_prod rova_dev opshub_dev kb_dev); i=0
signin_name() { case "$1" in rova_prod) echo "Rova Prod";; rova_dev) echo "Rova Dev";; opshub_dev) echo "OpsHub Dev";; kb_dev) echo "KB Dev";; esac; }
live_scope() { # the scope list already on the live AllPrincipals grant (KB carries email and the Graph file scopes)
  case "$1" in
    kb_dev) echo "openid profile email offline_access User.Read Files.Read Files.Read.All Sites.Read.All" ;;
    *) echo "openid profile email offline_access User.Read" ;;
  esac
}
build() { # build the fixture set from scratch
  rm -rf "$FX"; mkdir -p "$FX"; i=0
  echo "{\"id\":\"$(g 1 1)\"}" >"$FX/account"
  echo '[{"name":"b","timePeriod":{"startDate":"2026-10-01T00:00:00+00:00","endDate":"2028-09-30T00:00:00Z"}}]' >"$FX/budget"
  echo '{"value":[{"verifiedDomains":[{"name":"other.example","isDefault":true,"isInitial":false},{"name":"tenant.example","isDefault":false,"isInitial":true}]}]}' >"$FX/org"
  # Microsoft Graph SP + the four app roles the live service apps hold grants for (2026-11-04 audit)
  jq -n --arg id "$(g 90 1)" '{id:$id}' >"$FX/graph-sp"
  jq -n --arg a "$(g 91 1)" --arg b "$(g 91 2)" --arg c "$(g 91 3)" --arg d "$(g 91 4)" \
    '{"value":[{id:$a,value:"User.Invite.All"},{id:$b,value:"DeviceManagementManagedDevices.Read.All"},{id:$c,value:"SecurityEvents.Read.All"},{id:$d,value:"User.Read.All"}]}' >"$FX/graph-roles"
  echo "{\"id\":\"$(g 2 1)\"}" >"$FX/group-grp-qnsc-platform-admins"
  echo "{\"id\":\"$(g 2 2)\"}" >"$FX/group-grp-qnsc-dev-users"
  echo "{\"id\":\"$(g 2 3)\"}" >"$FX/group-grp-qnsc-developers"
  echo "{\"id\":\"$(g 3 1)\"}" >"$FX/me"
  echo "{\"id\":\"$(g 3 2)\"}" >"$FX/user-second@tenant.example"
  echo "{\"id\":\"$(g 3 6)\",\"userType\":\"Member\"}" >"$FX/user-owner@tenant.example"
  echo "{\"id\":\"$(g 3 7)\",\"userType\":\"Guest\"}" >"$FX/user-owner-guest@tenant.example"
  echo "{\"id\":\"$(g 3 3)\",\"userType\":\"Member\"}" >"$FX/user-dev@tenant.example"
  echo "{\"id\":\"$(g 3 4)\",\"userType\":\"Guest\"}" >"$FX/user-guest@tenant.example"
  echo "{\"id\":\"$(g 3 5)\"}" >"$FX/user-nouser@tenant.example"
  echo "{\"value\":[{\"id\":\"$(g 3 1)\",\"userType\":\"Member\"},{\"id\":\"$(g 3 2)\",\"userType\":\"Member\"}]}" >"$FX/members"
  for k in "${KEYS[@]}"; do
    i=$((i+1)); mkcert "$k"
    jq -n --arg id "$(g 10 $i)" --arg app "$(g 11 $i)" '{id:$id,appId:$app,appRoles:[]}' >"$FX/app-$(signin_name "$k" | tr " " -)"
    jq -n --arg app "$(g 11 $i)" --arg sp "$(g 12 $i)" '[{id:$sp,appId:$app}]' >"$FX/sp-$(g 11 $i)"
    # tenant-wide delegated consent already live for each sign-in app (resource = Graph), with its scope list
    jq -n --arg id "grant$(g 12 $i)" --arg g "$(g 90 1)" --arg s "$(live_scope "$k")" \
      '{value:[{id:$id,consentType:"AllPrincipals",resourceId:$g,scope:$s}]}' >"$FX/delegated-$(g 12 $i).json"
    jq -n --arg id "$(g 20 $i)" --arg app "$(g 21 $i)" --arg kid "$(g 22 $i)" --arg th "$(b64thumb "$T/$k.crt")" \
      '{id:$id,appId:$app,keyCredentials:[{keyId:$kid,customKeyIdentifier:$th}]}' >"$FX/app-$(signin_name "$k" | tr " " -)-Service"
    jq -n --arg app "$(g 21 $i)" --arg sp "$(g 23 $i)" '[{id:$sp,appId:$app}]' >"$FX/sp-$(g 21 $i)"
    # the Graph shape: keyCredentials[].key is base64 DER of the PUBLIC certificate, with the SHA-1 thumbprint in
    # customKeyIdentifier and a startDateTime per credential (pinned in mail.tf; the kit never classifies)
    jq -n --arg kid "$(g 22 $i)" --arg th "$(b64thumb "$T/$k.crt")" --arg st "2026-10-0${i}T00:00:00Z" \
      --arg key "$(openssl x509 -in "$T/$k.crt" -outform DER | base64 | tr -d '\n')" \
      '[{keyId:$kid,customKeyIdentifier:$th,startDateTime:$st,key:$key}]' >"$FX/keys-$(g 20 $i).json"
    # live appRoleAssignments on Microsoft Graph: rova_prod 1 (User.Invite.All), opshub_dev 3, the rest none
    case "$k" in
      rova_prod) jq -n --arg id "$(g 92 1)" --arg r "$(g 91 1)" --arg g "$(g 90 1)" --arg p "$(g 23 $i)" \
        '{value:[{id:$id,appRoleId:$r,resourceId:$g,principalId:$p}]}' >"$FX/grants-$(g 23 $i).json" ;;
      opshub_dev) jq -n --arg a "$(g 92 2)" --arg b "$(g 92 3)" --arg c "$(g 92 4)" \
        --arg r1 "$(g 91 2)" --arg r2 "$(g 91 3)" --arg r3 "$(g 91 4)" --arg g "$(g 90 1)" --arg p "$(g 23 $i)" \
        '{value:[{id:$a,appRoleId:$r1,resourceId:$g,principalId:$p},{id:$b,appRoleId:$r2,resourceId:$g,principalId:$p},{id:$c,appRoleId:$r3,resourceId:$g,principalId:$p}]}' >"$FX/grants-$(g 23 $i).json" ;;
      *) echo '{"value":[]}' >"$FX/grants-$(g 23 $i).json" ;;
    esac
    { echo "\"$(g 20 $i)\""; cat "$T/$k.crt"; } >"$FX/cert-$k"
  done
  # OpsHub Prod sign-in app (prod_apps.tf): exists after the prod apply, with one AllPrincipals grant.
  jq -n --arg id "$(g 15 1)" --arg app "$(g 14 1)" '{id:$id,appId:$app}' >"$FX/app-OpsHub-Prod"
  jq -c '[.]' "$FX/app-OpsHub-Prod" >"$FX/app-OpsHub-Prod.list"
  jq -n --arg app "$(g 14 1)" --arg sp "$(g 16 1)" '[{id:$sp,appId:$app}]' >"$FX/sp-$(g 14 1)"
  jq -n --arg id "grant$(g 16 1)" --arg g "$(g 90 1)" --arg s "openid profile email offline_access User.Read" \
    '{value:[{id:$id,consentType:"AllPrincipals",resourceId:$g,scope:$s}]}' >"$FX/delegated-$(g 16 1).json"
  # KB Prod sign-in app (kb_prod_apps.tf): exists after the kb prod apply, with one AllPrincipals grant.
  jq -n --arg id "$(g 15 2)" --arg app "$(g 14 2)" '{id:$id,appId:$app}' >"$FX/app-KB-Prod"
  jq -c '[.]' "$FX/app-KB-Prod" >"$FX/app-KB-Prod.list"
  jq -n --arg app "$(g 14 2)" --arg sp "$(g 16 2)" '[{id:$sp,appId:$app}]' >"$FX/sp-$(g 14 2)"
  jq -n --arg id "grant$(g 16 2)" --arg g "$(g 90 1)" \
    --arg s "openid profile email offline_access User.Read Files.Read Files.Read.All Sites.Read.All" \
    '{value:[{id:$id,consentType:"AllPrincipals",resourceId:$g,scope:$s}]}' >"$FX/delegated-$(g 16 2).json"
  # Cloudflare Access IdP app (cf_access.tf): one app, its SP, one AllPrincipals Graph grant.
  jq -n --arg id "$(g 17 1)" --arg app "$(g 17 2)" '[{id:$id,appId:$app}]' >"$FX/app-QNSC-Cloudflare-Access.list"
  jq -n --arg app "$(g 17 2)" --arg sp "$(g 17 3)" '[{id:$sp,appId:$app}]' >"$FX/sp-$(g 17 2)"
  jq -n --arg id "grant$(g 17 3)" --arg g "$(g 90 1)" \
    --arg s "openid email profile offline_access User.Read GroupMember.Read.All" \
    '{value:[{id:$id,consentType:"AllPrincipals",resourceId:$g,scope:$s}]}' >"$FX/delegated-$(g 17 3).json"
  roles='[]'; n=0
  for r in admin it-admin security hr manager helpdesk auditor; do n=$((n+1)); roles=$(jq -c --arg r "$r" --arg id "$(g 30 $n)" '.+[{value:$r,id:$id,isEnabled:true}]' <<<"$roles"); done
  jq --argjson r "$roles" '.appRoles=$r' "$FX/app-OpsHub-Dev" >"$FX/x" && mv "$FX/x" "$FX/app-OpsHub-Dev"
  for k in "${KEYS[@]}"; do for f in app-$(signin_name "$k" | tr " " -) app-$(signin_name "$k" | tr " " -)-Service; do jq -c '[.]' "$FX/$f" >"$FX/$f.list"; done; done
  # The live shape on 2026-11-04: KB Dev Service carries a SECOND, pinned credential.
  mkcert extra
  addcred kb_dev "$T/extra.crt" "$(g 22 99)" 2026-11-04T00:00:00Z
  pins "$(g 22 99)"
}
cat >"$BIN/az" <<'STUB'
#!/usr/bin/env bash
a="$*"; echo "az $a" >>"$FX/calls.log"
case "$a" in
  "account show"*) cat "$FX/account" ;;
  "consumption budget list"*) cat "$FX/budget" ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/organization"*) cat "$FX/org" ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/servicePrincipals/"*"/appRoles"*) cat "$FX/graph-roles" ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/servicePrincipals/"*"/oauth2PermissionGrants"*)
    p=${a#*servicePrincipals/}; p=${p%%/*}; cat "$FX/delegated-$p.json" 2>/dev/null || echo '{"value":[]}' ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/servicePrincipals/"*"/appRoleAssignments"*)
    p=${a#*servicePrincipals/}; p=${p%%/*}; cat "$FX/grants-$p.json" 2>/dev/null || echo '{"value":[]}' ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/applications/"*'?$select=keyCredentials'*) o=${a#*applications/}; o=${o%%\?*}
    if [ -f "$FX/keys-$o.json" ]; then jq -c '{keyCredentials:.}' "$FX/keys-$o.json"; exit 0; fi
    f=$(grep -l "\"$o\"" "$FX"/cert-eso-* 2>/dev/null | head -1); [ -n "$f" ] || { echo '{"keyCredentials":[]}'; exit 0; }
    jq -n --arg k "$(sed 1d "$f" | base64 | tr -d '\n')" '{keyCredentials:[{key:$k}]}' ;;
  "ad sp show --id "*) cat "$FX/graph-sp" ;;
  "ad group show --group "*) g=${a#ad group show --group }; cat "$FX/group-${g%% *}" ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/groups/"*)
    case "$a" in
      *skiptoken=2*) cat "$FX/members2" 2>/dev/null || echo '{"value":[]}' ;;
      *) cat "$FX/members" ;;
    esac ;;
  "rest --method get --url https://graph.microsoft.com/v1.0/users/"*)
    u=${a#*v1.0/users/}; u=${u%%\?*}; u=${u//%40/@}; cat "$FX/user-$u" ;;
  "ad signed-in-user show"*) cat "$FX/me" ;;
  "ad user show --id "*) u=${a#ad user show --id }; cat "$FX/user-${u%% *}" ;;
  "ad app list --filter displayName eq '"*) n=${a#*\'}; n=${n%%\'*}; cat "$FX/app-${n// /-}.list" 2>/dev/null || echo '[]' ;;
  "ad sp list --filter appId eq '"*) n=${a#*\'}; n=${n%%\'*}; cat "$FX/sp-$n" ;;
  "keyvault"*) echo "FORBIDDEN: the kit must not read Key Vault" >&2; exit 9 ;;
  *) echo "unexpected az call: $a" >&2; exit 9 ;;
esac
STUB
cat >"$BIN/op" <<'STUB'
#!/usr/bin/env bash
echo "op $*" >>"$FX/calls.log"; echo "the kit must not call op" >&2; exit 9
STUB
chmod +x "$BIN/az" "$BIN/op"
echo 'variable "other" {}' >"$T/stack/v.tf"

run() { PATH="$BIN:$PATH" FX="$FX" IDENTITY_STACK_DIR="$T/stack" \
  IDENTITY_SECOND_OWNER_UPN="second@tenant.example" IDENTITY_PROXMOX_HOST="pve.example.test" \
  IDENTITY_PBS_HOST="pbs.example.test" "$@"; }
fail() { echo "FAIL: $*"; exit 1; }
leak_scan() { # no fixture identifier or PEM may appear in the captured output
  grep -qE '[0-9a-f]{8}-0000-4000-8000|BEGIN|PRIVATE|pve\.example|pbs\.example|tenant\.example|second@' "$1" && fail "$2: a value reached the output" || true
}
expect_stop() { # expect_stop <label> <expected fragment>
  local out="$T/out.$RANDOM"
  if run bash "$SCRIPT" >"$out" 2>&1; then fail "$1: broken input did not stop the run"; fi
  grep -q "STOP: .*$2" "$out" || { cat "$out"; fail "$1: wrong stop reason (wanted '$2')"; }
  leak_scan "$out" "$1"
}
expect_stop_extra() { # expect_stop_extra <label> <expected fragment> <IDENTITY_DEV_APP_EXTRA_OWNERS value>
  local out="$T/out.$RANDOM"
  if run env IDENTITY_DEV_APP_EXTRA_OWNERS="$3" bash "$SCRIPT" >"$out" 2>&1; then fail "$1: broken input did not stop the run"; fi
  grep -q "STOP: .*$2" "$out" || { cat "$out"; fail "$1: wrong stop reason (wanted '$2')"; }
  leak_scan "$out" "$1"
}

# 1. happy path: names + lengths, 23 variables, no value anywhere
build
OUT="$T/out.happy"; run bash "$SCRIPT" >"$OUT" 2>&1 || { cat "$OUT"; fail "happy path exited non-zero"; }
grep -q 'identity env OK: 23 variables' "$OUT" || { cat "$OUT"; fail "variable count"; }
for v in subscription_id budget_period_start budget_period_end break_glass_upn_domain grp_platform_admins_object_id grp_developers_object_id grp_dev_users_object_id \
  owner_operator_object_id second_owner_object_id platform_admin_object_ids proxmox_redirect_uris existing_object_ids existing_sp_object_ids \
  mail_service_object_ids mail_service_sp_object_ids opshub_dev_app_role_ids mail_service_certificates \
  mail_service_rotated_certificates mail_service_graph_grant_ids signin_delegated_grant_ids signin_delegated_grant_scopes \
  cf_access_object_ids; do
  grep -qE "TF_VAR_$v +[0-9]+$" "$OUT" || fail "missing TF_VAR_$v in the report"
done
grep -qE 'TF_VAR_mail_service_cert_key_ids' "$OUT" && fail "the keyIds are pinned in code, the kit must not export them" || true
grep -qE 'ARM_SUBSCRIPTION_ID +36$' "$OUT" || fail "ARM_SUBSCRIPTION_ID not exported with length 36"
leak_scan "$OUT" happy
[ "$(grep -c "2026-10-01T00:00:00Z" "$OUT")" = 0 ] || fail "a value was printed"

# 1b. optional DEV extra owners: resolved to object ids, map keyed by app; nothing printed
build
OUT="$T/out.extra"; run env IDENTITY_DEV_APP_EXTRA_OWNERS="opshub_dev=dev@tenant.example" bash "$SCRIPT" >"$OUT" 2>&1 \
  || { cat "$OUT"; fail "extra owners: happy path exited non-zero"; }
grep -q 'identity env OK: 24 variables' "$OUT" || { cat "$OUT"; fail "extra owners: variable count"; }
grep -qE 'TF_VAR_dev_app_extra_owner_object_ids +[0-9]+$' "$OUT" || fail "extra owners: map not exported"
leak_scan "$OUT" "extra owners"
run env IDENTITY_DEV_APP_EXTRA_OWNERS="opshub_dev=dev@tenant.example" bash "$SCRIPT" -- \
  sh -c 'printf "%s" "$TF_VAR_dev_app_extra_owner_object_ids"' >"$T/extra.json" 2>/dev/null \
  || fail "extra owners: run mode"
jq -e --arg id "$(g 3 3)" 'keys==["opshub_dev"] and .opshub_dev==[$id]' "$T/extra.json" >/dev/null \
  || fail "extra owners: wrong map"
grep -q 'v1.0/users/dev%40tenant.example' "$FX/calls.log" || fail "extra owner not read via Graph users?select"
grep -q 'select=id,userType' "$FX/calls.log" || fail "extra owner lookup without userType selected"
grep -q 'ad user show --id dev@' "$FX/calls.log" && fail "extra owner read via az ad user show (omits userType)" || true
expect_stop_extra "extra owner guest" "has a guest or non-Member user" "opshub_dev=guest@tenant.example"
expect_stop_extra "extra owner without userType" "has a guest or non-Member user" "opshub_dev=nouser@tenant.example"
expect_stop_extra "extra owner unknown" "az lookup failed: dev-extra-owner" "opshub_dev=nobody@tenant.example"
expect_stop_extra "extra owner prod key" "rova_prod is not a dev sign-in app" "rova_prod=dev@tenant.example"
expect_stop_extra "extra owner malformed" "expected app=upn" "opshub_dev"
expect_stop_extra "extra owner empty upn" "has an empty UPN" "opshub_dev="
# a stale export in the owner's shell must never reach the plan
build; run env TF_VAR_dev_app_extra_owner_object_ids='{"opshub_dev":["stale"]}' bash "$SCRIPT" -- \
  sh -c 'printf "%s" "${TF_VAR_dev_app_extra_owner_object_ids-UNSET}"' >"$T/stale.txt" 2>/dev/null \
  || fail "stale export: run mode"
[ "$(cat "$T/stale.txt")" = UNSET ] || fail "a stale TF_VAR_dev_app_extra_owner_object_ids reached the child"

# 1c. owner operator override: CI has no signed-in user; the UPN resolves to the same object id
build
run env IDENTITY_OWNER_OPERATOR_UPN="owner@tenant.example" bash "$SCRIPT" -- \
  sh -c 'printf "%s" "$TF_VAR_owner_operator_object_id"' >"$T/owner.txt" 2>/dev/null \
  || fail "owner operator override: run mode"
[ "$(cat "$T/owner.txt")" = "$(g 3 6)" ] || fail "owner operator override: wrong id"
grep -q 'v1.0/users/owner%40tenant.example' "$FX/calls.log" || fail "owner operator not read via Graph"
build; out="$T/out.ownerguest"
if run env IDENTITY_OWNER_OPERATOR_UPN="owner-guest@tenant.example" bash "$SCRIPT" >"$out" 2>&1; then fail "owner operator guest accepted"; fi
grep -q 'STOP: IDENTITY_OWNER_OPERATOR_UPN is a guest or non-Member user' "$out" || fail "owner operator guest reason"

# 2. run mode: the child sees the values (checked by shape, nothing printed), cwd is the stack dir
CH="$T/child.out"
run bash "$SCRIPT" -- bash -c 'jq -e "(.dev|length)>0" >/dev/null 2>&1 <<<"{}" ; [[ "$TF_VAR_budget_period_start" == 2026-10-01T00:00:00Z && "$TF_VAR_budget_period_end" == 2028-09-30T00:00:00Z ]] && [[ "$TF_VAR_proxmox_redirect_uris" == "[\"https://pve.example.test/\",\"https://pbs.example.test/\"]" ]] && jq -e "length==2" <<<"$TF_VAR_platform_admin_object_ids" >/dev/null && jq -e "length==4" <<<"$TF_VAR_mail_service_certificates" >/dev/null && jq -e "length==1 and (.[\"'$(g 22 99)'\"] != null)" <<<"$TF_VAR_mail_service_rotated_certificates" >/dev/null && jq -e "length==4" <<<"$TF_VAR_mail_service_graph_grant_ids" >/dev/null && jq -e "length==6 and .opshub_prod != null and .kb_prod != null" <<<"$TF_VAR_signin_delegated_grant_ids" >/dev/null && jq -e ".application != null and .service_principal != null and .grant != null" <<<"$TF_VAR_cf_access_object_ids" >/dev/null && jq -e "length==6 and (.kb_dev|index(\"email\") != null) and (.kb_prod|length == 8) and (.rova_prod|length == 5)" <<<"$TF_VAR_signin_delegated_grant_scopes" >/dev/null && jq -e ".[\"rova_prod/User.Invite.All\"] != null and .[\"opshub_dev/User.Read.All\"] != null" <<<"$TF_VAR_mail_service_graph_grant_ids" >/dev/null && [[ "$TF_VAR_break_glass_upn_domain" == tenant.example ]] && jq -e ".admin and .auditor" <<<"$TF_VAR_opshub_dev_app_role_ids" >/dev/null && pwd' >"$CH" 2>&1 || { cat "$CH"; fail "child did not get the right env"; }
[ "$(cat "$CH")" = "$T/stack" ] || fail "child cwd is not the stack dir"
# the rotated certificate reaches the child byte for byte under its pinned keyId
run bash "$SCRIPT" -- sh -c 'printf "%s" "$TF_VAR_mail_service_rotated_certificates"' >"$T/rot.json" 2>/dev/null || fail "rotated child"
jq -j --arg k "$(g 22 99)" '.[$k]' "$T/rot.json" >"$T/rot.pem"
cmp -s "$T/rot.pem" "$T/extra.crt" || fail "rotated PEM not passed byte for byte"

# 2b. no temp dir survives, in check mode or after a child run (the script must not exec away its cleanup trap)
build; TD="$T/tmpd"; mkdir -p "$TD"
TMPDIR="$TD" run bash "$SCRIPT" -- true || fail "child true failed"
[ -z "$(ls -A "$TD")" ] || fail "temp dir left behind after -- true"
TMPDIR="$TD" run bash "$SCRIPT" >/dev/null || fail "check failed"
[ -z "$(ls -A "$TD")" ] || fail "temp dir left behind after check"
TMPDIR="$TD" run bash "$SCRIPT" -- bash -c 'exit 7' && fail "child exit code swallowed" || [ "$?" = 7 ] || fail "child exit code not propagated"
[ -z "$(ls -A "$TD")" ] || fail "temp dir left behind after a failing child"

# 3. broken inputs stop the run
build; : >"$FX/account"; expect_stop "empty subscription" "az lookup empty: subscription"
build; echo '[{},{}]' >"$FX/budget"; expect_stop "two budgets" "expected exactly 1 budget"
build; echo '[{"timePeriod":{"startDate":"2026-10-01","endDate":"2028-09-30T00:00:00Z"}}]' >"$FX/budget"; expect_stop "bare-date budget" "budget timestamp is not RFC3339"
build; rm "$FX/app-KB-Dev.list"; expect_stop "app missing" "az lookup empty: app KB Dev"
build; rm "$FX/delegated-$(g 17 3).json"; expect_stop "cf access without a grant" "'QNSC Cloudflare Access' has no AllPrincipals Graph grant"
build; jq -c '. + .' "$FX/app-Rova-Dev.list" >"$FX/x" && mv "$FX/x" "$FX/app-Rova-Dev.list"; expect_stop "duplicate app" "expected exactly 1 app named 'Rova Dev'"
build; echo '[{"id":"not-a-guid","appId":"x"}]' | jq -c '.' >"$FX/sp-$(g 11 1)"; expect_stop "bad SP id" "SP object id is not a GUID"
build; jq -c '[.[0]|.appRoles|=map(select(.value!="hr"))]' "$FX/app-OpsHub-Dev.list" >"$FX/x" && mv "$FX/x" "$FX/app-OpsHub-Dev.list"; expect_stop "missing app role" "OpsHub Dev must carry exactly the 7 app roles"
setcki() { local f; f=$(keysf "$1"); jq -c --arg th "$(b64thumb "$2")" '.[0].customKeyIdentifier=$th' "$f" >"$FX/x" && mv "$FX/x" "$f"; }
sethexcki() { local f; f=$(keysf "$1"); jq -c --arg th "$(openssl x509 -in "$2" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')" '.[0].customKeyIdentifier=$th' "$f" >"$FX/x" && mv "$FX/x" "$f"; }
build; mkcert other; setcki opshub_dev "$T/other.crt"; expect_stop "wrong thumbprint" "mail cert opshub_dev thumbprint differs"
build; rm "$(keysf kb_dev)"; expect_stop "no key on the app" "service app kb_dev carries no key credential"
build; mkcert other; setcki rova_prod "$T/other.crt"; expect_stop "prod cert differs" "mail cert rova_prod thumbprint differs"
# a hex-text customKeyIdentifier (how rova-prod was added by hand) is accepted when it matches, and stops when it does not
build; sethexcki rova_prod "$T/rova_prod.crt"
run bash "$SCRIPT" >"$T/out.hex" 2>&1 || { cat "$T/out.hex"; fail "hex customKeyIdentifier rejected"; }
build; mkcert other; sethexcki rova_prod "$T/other.crt"
out="$T/out.hexbad"; if run bash "$SCRIPT" >"$out" 2>&1; then fail "wrong hex customKeyIdentifier accepted"; fi
grep -q "mail cert rova_prod thumbprint differs" "$out" || fail "wrong hex customKeyIdentifier reason"
# a pinned credential that is NOT live stops (pins are the source of truth)
build; pins "$(g 22 98)"; expect_stop "pinned credential missing" "a credential pinned for kb_dev is not on the app"
# an unpinned live credential stops and prints its keyId (the ONE identifier the kit ever prints)
build; mkcert third; addcred kb_dev "$T/third.crt" "$(g 22 98)" 2026-12-01T00:00:00Z
out="$T/out.unpinned"
if run bash "$SCRIPT" >"$out" 2>&1; then fail "unpinned credential accepted"; fi
grep -q "STOP: .*UNPINNED credential $(g 22 98)" "$out" || { cat "$out"; fail "unpinned credential reason"; }
# a null/empty startDateTime stops (incomplete credential data)
build; jq -c '.[1].startDateTime=null' "$(keysf kb_dev)" >"$FX/x" && mv "$FX/x" "$(keysf kb_dev)"
expect_stop "null startDateTime" "has no startDateTime"
# the Credentials array has no promised order: reversed input exports the same maps
build; jq -c 'reverse' "$(keysf kb_dev)" >"$FX/x" && mv "$FX/x" "$(keysf kb_dev)"
run bash "$SCRIPT" -- sh -c 'printf "%s" "$TF_VAR_mail_service_rotated_certificates"' >"$T/rot.rev.json" 2>/dev/null \
  || fail "reversed array rejected"
jq -e --arg k "$(g 22 99)" 'keys==[$k]' "$T/rot.rev.json" >/dev/null || fail "reversed array changed the exports"
# three credentials, two pinned as rotated
build; mkcert third; addcred kb_dev "$T/third.crt" "$(g 22 98)" 2026-12-01T00:00:00Z; pins "$(g 22 99)" "$(g 22 98)"
run bash "$SCRIPT" -- sh -c 'printf "%s" "$TF_VAR_mail_service_rotated_certificates"' >"$T/rot3.json" 2>/dev/null \
  || fail "three credentials rejected"
jq -e --arg a "$(g 22 99)" --arg b "$(g 22 98)" 'keys|sort==([$a,$b]|sort)' "$T/rot3.json" >/dev/null || fail "three credentials exports"
# the pin map must name every app slot
build; grep -v 'rova_dev' "$T/stack/mail.tf" >"$T/m" && mv "$T/m" "$T/stack/mail.tf"
expect_stop "missing pinned slot" "must pin exactly these slots"
build; echo '{"value":[{"verifiedDomains":[{"name":"a","isDefault":true,"isInitial":false}]}]}' >"$FX/org"; expect_stop "no initial domain" "lookup for TF_VAR_break_glass_upn_domain is empty"
build; echo '{"value":[]}' >"$FX/members"; expect_stop "empty member page" "grp-qnsc-platform-admins has no user members"
build; echo "{\"value\":[{\"id\":\"$(g 9 9)\"}]}" >"$FX/members"; expect_stop "nested group member" "has a guest, nested group or non-Member member"
build; echo "{\"value\":[{\"id\":\"$(g 3 1)\",\"userType\":\"Guest\"}]}" >"$FX/members"; expect_stop "guest member" "has a guest, nested group or non-Member member"
build; echo "{\"value\":[{\"id\":\"$(g 9 9)\",\"userType\":null}]}" >"$FX/members"; expect_stop "non-user member" "has a guest, nested group or non-Member member"
# THE LIVE SHAPE: `az ad group member list` omits userType entirely — must fail closed, not empty the list.
build; echo "{\"value\":[{\"id\":\"$(g 3 1)\",\"userPrincipalName\":\"a@tenant.example\"}]}" >"$FX/members"; expect_stop "member without userType" "has a guest, nested group or non-Member member"
# @odata.nextLink paging: page 2 supplies the second Member.
build
jq -nc --arg a "$(g 3 1)" \
  --arg n 'https://graph.microsoft.com/v1.0/groups/x/members?$select=id,userType,userPrincipalName&$skiptoken=2' \
  '{value:[{id:$a,userType:"Member"}],"@odata.nextLink":$n}' >"$FX/members"
jq -nc --arg b "$(g 3 2)" '{value:[{id:$b,userType:"Member"}]}' >"$FX/members2"
run bash "$SCRIPT" -- sh -c 'printf "%s" "$TF_VAR_platform_admin_object_ids"' >"$T/admins2.json" 2>/dev/null \
  || fail "paged member list rejected"
jq -e "length==2" "$T/admins2.json" >/dev/null || fail "paged member list did not page through @odata.nextLink"
build; out="$T/out.noupn"; if PATH="$BIN:$PATH" FX="$FX" IDENTITY_STACK_DIR="$T/stack" IDENTITY_PROXMOX_HOST=h.test IDENTITY_PBS_HOST=h2.test bash "$SCRIPT" >"$out" 2>&1; then fail "missing UPN did not stop"; fi
grep -q 'STOP: set IDENTITY_SECOND_OWNER_UPN' "$out" || fail "missing UPN reason"
build; out="$T/out.nohost"; if run env -u IDENTITY_PROXMOX_HOST bash "$SCRIPT" >"$out" 2>&1; then fail "missing host did not stop"; fi
grep -q 'STOP: set IDENTITY_PROXMOX_HOST' "$out" || fail "missing host reason"
build; out="$T/out.nopbshost"; if run env -u IDENTITY_PBS_HOST bash "$SCRIPT" >"$out" 2>&1; then fail "missing PBS host did not stop"; fi
grep -q 'STOP: set IDENTITY_PBS_HOST' "$out" || fail "missing PBS host reason"
build; out="$T/out.badpvehost"; if run env IDENTITY_PROXMOX_HOST="pve.example.test/" bash "$SCRIPT" >"$out" 2>&1; then fail "malformed PVE host did not stop"; fi
grep -q 'STOP: set IDENTITY_PROXMOX_HOST' "$out" || fail "malformed PVE host reason"
build; out="$T/out.badpbshost"; if run env IDENTITY_PBS_HOST="pbs.example.test/" bash "$SCRIPT" >"$out" 2>&1; then fail "malformed PBS host did not stop"; fi
grep -q 'STOP: set IDENTITY_PBS_HOST' "$out" || fail "malformed PBS host reason"
build; out="$T/out.samehost"; if run env IDENTITY_PROXMOX_HOST="PVE.example.test" IDENTITY_PBS_HOST="pve.example.test" bash "$SCRIPT" >"$out" 2>&1; then fail "case-insensitive identical host did not stop"; fi
grep -q 'STOP: IDENTITY_PROXMOX_HOST and IDENTITY_PBS_HOST must differ' "$out" || fail "identical host reason"
build; run env IDENTITY_PROXMOX_HOST="PVE.Example.Test" bash "$SCRIPT" -- sh -c 'printf "%s" "$TF_VAR_proxmox_redirect_uris"' >"$T/upper.json" 2>/dev/null \
  || fail "uppercase host rejected"
grep -q '"https://pve.example.test/"' "$T/upper.json" || fail "hostname was not lowercased"
build; out="$T/out.badlabel"; if run env IDENTITY_PBS_HOST="-pbs.example.test" bash "$SCRIPT" >"$out" 2>&1; then fail "leading-dash label did not stop"; fi
grep -q 'STOP: set IDENTITY_PBS_HOST' "$out" || fail "leading-dash label reason"
build; if run bash "$SCRIPT" -- 2>/dev/null; then fail "empty command after -- accepted"; fi

# 4. eso_certificates: read from the ESO apps (Graph) while the stack declares the variable, absent once it does not
esofix() { local j=40 p; for p in dev prod platform; do j=$((j+1)); mkcert "eso-$p"
    local n; n="QNSC-ESO-$(tr '[:lower:]' '[:upper:]' <<<"${p:0:1}")${p:1}"
    jq -nc --arg id "$(g $j 1)" '[{id:$id}]' >"$FX/app-$n.list"
    { echo "\"$(g $j 1)\""; cat "$T/eso-$p.crt"; } >"$FX/cert-eso-$p"; done; }
build; echo 'variable "eso_certificates" {}' >"$T/stack/eso.tf"
expect_stop "eso app missing" "az lookup empty: eso app dev"
build; esofix; OUT="$T/out.eso"; run bash "$SCRIPT" >"$OUT" 2>&1 || { cat "$OUT"; fail "eso happy path"; }
grep -q 'identity env OK: 24 variables' "$OUT" || fail "eso variable count"
grep -qE 'TF_VAR_eso_certificates +[0-9]+$' "$OUT" || fail "eso variable not built"
leak_scan "$OUT" "eso happy path"
# the PEM text uploaded by the provider reaches the child byte for byte (trailing newline included): no replace planned
build; esofix; run bash "$SCRIPT" -- sh -c 'printf "%s" "$TF_VAR_eso_certificates" | jq -j .dev' >"$T/eso-dev.child" 2>/dev/null \
  || fail "eso run mode"
cmp -s "$T/eso-dev.child" "$T/eso-dev.crt" || fail "eso dev PEM not passed byte for byte"
build; esofix; rm "$FX/cert-eso-prod"; expect_stop "eso app without key" "eso app prod must carry exactly 1 key credential"
build; esofix; jq -c '.+.' "$FX/app-QNSC-ESO-Platform.list" >"$FX/x" && mv "$FX/x" "$FX/app-QNSC-ESO-Platform.list"; expect_stop "duplicate eso app" "exactly one app named 'QNSC ESO Platform' expected"
rm "$T/stack/eso.tf"

# 5. the kit only reads: no az verb other than show/list, no op verb other than read
if grep -q 'keyvault' "$FX/calls.log"; then fail "the kit read Key Vault"; fi
if grep -E '^az (.* )?(create|update|delete|set|reset|add|remove|assignment|grant|invite)( |$)' "$FX/calls.log"; then fail "a mutating az call was made"; fi
if grep -q '^op' "$FX/calls.log"; then fail "the kit called op"; fi
echo "PASS: identity-env"
