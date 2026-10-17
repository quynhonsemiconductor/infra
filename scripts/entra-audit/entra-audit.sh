#!/usr/bin/env bash
# READ-ONLY audit of the Entra app registrations against the QNSC app-registration standard
# (HYBRID-INFRA-PLAN section 7.4). Collects metadata with `az rest` GET requests against Microsoft Graph,
# writes graph.json, and runs entra_report.py to produce entra-audit-report.md / .json.
#
#   az login --tenant <tenant>.onmicrosoft.com --allow-no-subscriptions   # Global Reader is enough; no write role
#   ./entra-audit.sh [OUTDIR]             # default: ~/entra-audit-<date>/
#   ./entra-audit.sh --expected-owners "a@x.com,b@x.com"   # owners that are NOT flagged (default: every owner is flagged)
#   ./entra-audit.sh --report-only OUTDIR # re-run the report on files already collected (e.g. after exchange.json)
#
# Only GET requests are made: every call goes through graph_get(), the only place `az rest` appears, and
# check-readonly.sh (run in CI) fails if anything else is added. No secret VALUE is read or written: credential
# metadata is reduced to keyId, displayName and dates (the `hint` and `key` fields are dropped).
# The output directory must be outside any git repository; it holds tenant data. Send the report privately.
# SC2016: `$select` / `$top` are literal OData query options, not shell variables.
# shellcheck disable=SC2016
set -euo pipefail
umask 077

GRAPH="https://graph.microsoft.com/v1.0"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
EXCHANGE_APP_ID="00000002-0000-0ff1-ce00-000000000000"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTS="Rova,OpsHub,KB,LMS"
EXPECTED_OWNERS=""
RUN_REPORT=1
REPORT_ONLY=0
OUT=""

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
die() { echo "entra-audit: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --no-report) RUN_REPORT=0 ;;
    --report-only) REPORT_ONLY=1 ;;
    --expected-owners) shift; [[ $# -gt 0 ]] || die "--expected-owners needs a value"; EXPECTED_OWNERS="$1" ;;
    --products) shift; [[ $# -gt 0 ]] || die "--products needs a value"; PRODUCTS="$1" ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$OUT" ]] || die "one output directory only"; OUT="$1" ;;
  esac
  shift
done
OUT="${OUT:-$HOME/entra-audit-$(date +%F)}"

# The audit data must never end up in a repository. Check the nearest EXISTING ancestor, so a directory that does
# not exist yet (and its parents) is judged by where it would be created.
refuse_inside_git_repo() {
  local d="$OUT"
  while [[ ! -d "$d" ]]; do d="$(dirname "$d")"; done
  if command -v git >/dev/null 2>&1 && git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$OUT is inside a git repository; choose a directory outside it (the default is under \$HOME)"
  fi
}

run_report() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed for the report (collected files are in $OUT)"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' ||
    die "Python 3.10+ is needed for the report; $(python3 -V 2>&1) found. On macOS: brew install python (collected files are in $OUT, re-run with --report-only)"
  local rc=0
  python3 "$HERE/entra_report.py" "$OUT" --products "$PRODUCTS" --expected-owners "$EXPECTED_OWNERS" || rc=$?
  return "$rc"
}

if [[ "$REPORT_ONLY" == 1 ]]; then
  [[ -f "$OUT/graph.json" ]] || die "$OUT/graph.json not found"
  refuse_inside_git_repo
  run_report
  exit $?
fi

command -v az >/dev/null 2>&1 || die "Azure CLI (az) not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

refuse_inside_git_repo
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

signed_in="$(az account show --query '[user.name, tenantId]' -o tsv 2>/dev/null | paste -sd' ' -)" ||
  die "not signed in: run 'az login --tenant <tenant>.onmicrosoft.com --allow-no-subscriptions' first"
[[ -n "$signed_in" ]] || die "not signed in: run 'az login --tenant <tenant>.onmicrosoft.com --allow-no-subscriptions' first"
echo "Signed in as: ${signed_in% *} (tenant ${signed_in##* }). Reading only." >&2

# ── the only network call in this script ─────────────────────────────────────────────────────────────────
# graph_get URL [allow-missing]
# Prints the response body on stdout. EVERY failure aborts the run, so a permission error can never read as "nothing
# found". The single exception is `allow-missing`, used only for service-principal lookups by appId, where "not found"
# is a legitimate answer (the app has no enterprise application, or the resource is not instantiated in this tenant):
# then only a real Graph not-found (Request_ResourceNotFound / "Not Found(") prints `null`. Throttling and 5xx are retried
# after 10, 30 and 60 seconds. The error text is matched on error NAMES, never on bare numbers, which request ids contain.
graph_get() {
  local url="$1" allow="${2:-}" try err
  local -a pauses=(10 30 60)
  err="$TMP/err.txt"
  for try in 0 1 2 3; do
    if az rest --method get --url "$url" --output json 2>"$err"; then
      return 0
    fi
    if [[ "$allow" == allow-missing ]] && grep -qE 'Request_ResourceNotFound|Not Found\(' "$err"; then
      echo null
      return 0
    fi
    if [[ "$try" -lt 3 ]] && grep -qE 'TooManyRequests|Too Many Requests|\(429\)|ServiceUnavailable|GatewayTimeout|BadGateway|InternalServerError|\(5(00|02|03|04)\)|timed out|Connection (aborted|reset)' "$err"; then
      echo "entra-audit: throttled or unavailable, retrying in ${pauses[$try]}s: $url" >&2
      sleep "${ENTRA_AUDIT_RETRY_SLEEP:-${pauses[$try]}}"
      continue
    fi
    echo "entra-audit: GET failed (the run is aborted so nothing is silently missing): $url" >&2
    sed 's/^/  /' "$err" >&2
    return 1
  done
}

# Follows @odata.nextLink and prints one JSON array of all `value` items.
graph_get_all() {
  local url="$1" n=0 dir
  dir="$(mktemp -d "$TMP/pages.XXXXXX")"
  while [[ -n "$url" && "$url" != null ]]; do
    n=$((n + 1))
    graph_get "$url" >"$dir/$n.json"
    url="$(jq -r '."@odata.nextLink" // empty' "$dir/$n.json")"
  done
  jq -s -c '[.[] | (.value // []) | .[]]' "$dir"/*.json
}

# ── applications ────────────────────────────────────────────────────────────────────────────────────────
echo "Reading applications..." >&2
APP_SELECT='$select=id,appId,displayName,signInAudience,notes,web,spa,publicClient,requiredResourceAccess,passwordCredentials,keyCredentials,servicePrincipalLockConfiguration'
graph_get_all "$GRAPH/applications?$APP_SELECT&\$top=999" >"$TMP/applications.json"
count="$(jq 'length' "$TMP/applications.json")"
[[ "$count" -gt 0 ]] || die "Graph returned no applications; is this the right tenant, and does the account have a read role?"
echo "  $count application(s)" >&2

RES_SELECT='$select=id,appId,displayName,appRoles,oauth2PermissionScopes'
echo '{}' >"$TMP/resources.json"

# Resource service principals (Graph, SharePoint, Exchange ...) are 0.5 to 1.5 MB of JSON with their role descriptions:
# they only ever travel through FILES (jq --slurpfile), never as a command-line argument (the OS limit is 128 KB to 1 MB).
add_resource_file() {
  local file="$1"
  [[ "$(jq -r 'if type == "object" and .id then "yes" else "no" end' "$file")" == yes ]] || return 0
  jq -c --slurpfile r "$file" '. + {($r[0].id): {appId: $r[0].appId, displayName: $r[0].displayName,
      appRoles: [($r[0].appRoles // [])[] | {id, value, displayName}],
      oauth2PermissionScopes: [($r[0].oauth2PermissionScopes // [])[] | {id, value}]}}' "$TMP/resources.json" >"$TMP/resources.new"
  mv "$TMP/resources.new" "$TMP/resources.json"
}
fetch_resource_by_object_id() {
  local id="$1"
  jq -e --arg id "$id" 'has($id)' "$TMP/resources.json" >/dev/null && return 0
  graph_get "$GRAPH/servicePrincipals/$id?$RES_SELECT" >"$TMP/res.json"
  add_resource_file "$TMP/res.json"
}
# Prints the resource's object id (empty when this tenant has no such service principal).
fetch_resource_by_app_id() {
  local app_id="$1" id
  id="$(jq -r --arg a "$app_id" 'to_entries[] | select(.value.appId == $a) | .key' "$TMP/resources.json" | head -n1)"
  if [[ -z "$id" ]]; then
    graph_get "$GRAPH/servicePrincipals(appId='$app_id')?$RES_SELECT" allow-missing >"$TMP/res.json"
    add_resource_file "$TMP/res.json"
    id="$(jq -r --arg a "$app_id" 'to_entries[] | select(.value.appId == $a) | .key' "$TMP/resources.json" | head -n1)"
  fi
  printf '%s' "$id"
}

mkdir -p "$TMP/apps"
i=0
while IFS= read -r app; do
  i=$((i + 1))
  object_id="$(jq -r '.id' <<<"$app")"
  app_id="$(jq -r '.appId' <<<"$app")"
  name="$(jq -r '.displayName' <<<"$app")"
  echo "  [$i/$count] $name" >&2

  # credentials: metadata only. `hint` (first characters of a secret) and `key` are deliberately not kept.
  jq -c '{id, appId, displayName, signInAudience, notes, web, spa, publicClient, requiredResourceAccess,
          servicePrincipalLockConfiguration,
          passwordCredentials: [(.passwordCredentials // [])[] | {keyId, displayName, startDateTime, endDateTime}],
          keyCredentials: [(.keyCredentials // [])[] | {keyId, displayName, startDateTime, endDateTime, type, usage}]}' <<<"$app" >"$TMP/apps/base.json"

  graph_get_all "$GRAPH/applications/$object_id/owners"'?$select=id,displayName,userPrincipalName' |
    jq -c '[.[] | {id, type: (."@odata.type" // "" | sub("#microsoft.graph."; "")), displayName, userPrincipalName}]' >"$TMP/apps/owners.json"
  graph_get_all "$GRAPH/applications/$object_id/federatedIdentityCredentials" |
    jq -c '[.[] | {name, issuer}]' >"$TMP/apps/federated.json"

  graph_get "$GRAPH/servicePrincipals(appId='$app_id')"'?$select=id,appId,displayName,appRoleAssignmentRequired,accountEnabled,servicePrincipalType' allow-missing >"$TMP/apps/sp.raw.json"
  if [[ "$(jq -r 'type' "$TMP/apps/sp.raw.json")" == null ]]; then
    echo null >"$TMP/apps/sp.json"
  else
    sp_id="$(jq -r '.id' "$TMP/apps/sp.raw.json")"
    graph_get_all "$GRAPH/servicePrincipals/$sp_id/appRoleAssignments" |
      jq -c '[.[] | {resourceId, appRoleId, resourceDisplayName}]' >"$TMP/apps/assignments.json"
    graph_get_all "$GRAPH/servicePrincipals/$sp_id/oauth2PermissionGrants" |
      jq -c '[.[] | {resourceId, consentType, scope}]' >"$TMP/apps/grants.json"
    jq -c --slurpfile a "$TMP/apps/assignments.json" --slurpfile g "$TMP/apps/grants.json" \
      '{id, appRoleAssignmentRequired, accountEnabled, servicePrincipalType, appRoleAssignments: $a[0], oauth2PermissionGrants: $g[0]}' \
      "$TMP/apps/sp.raw.json" >"$TMP/apps/sp.json"
    while IFS= read -r rid; do
      if [[ -n "$rid" ]]; then fetch_resource_by_object_id "$rid"; fi
    done < <(jq -r '(.appRoleAssignments + .oauth2PermissionGrants)[].resourceId' "$TMP/apps/sp.json" | sort -u)
  fi
  while IFS= read -r raid; do
    if [[ -n "$raid" ]]; then fetch_resource_by_app_id "$raid" >/dev/null; fi
  done < <(jq -r '(.requiredResourceAccess // [])[].resourceAppId' "$TMP/apps/base.json" | sort -u)

  jq -c --slurpfile o "$TMP/apps/owners.json" --slurpfile f "$TMP/apps/federated.json" --slurpfile s "$TMP/apps/sp.json" \
    '. + {owners: $o[0], federatedCredentials: $f[0], servicePrincipal: $s[0]}' "$TMP/apps/base.json" >"$TMP/apps/$i.json"
done < <(jq -c '.[]' "$TMP/applications.json")

# ── service principals WITHOUT an app registration here ─────────────────────────────────────────────────
# Third-party and multi-tenant apps and managed identities have no /applications entry but can hold the same application
# permissions. Who holds Graph / Exchange application roles comes from appRoleAssignedTo on those two resources.
echo "Reading who holds Graph / Exchange application roles..." >&2
jq -c '[.servicePrincipal.id // empty]' "$TMP"/apps/[0-9]*.json | jq -s -c 'add // []' >"$TMP/own-sp-ids.json"
echo '[]' >"$TMP/assigned.json"
for resource_app in "$GRAPH_APP_ID" "$EXCHANGE_APP_ID"; do
  resource_id="$(fetch_resource_by_app_id "$resource_app")"
  [[ -n "$resource_id" ]] || { echo "  (no service principal for $resource_app in this tenant; skipped)" >&2; continue; }
  graph_get_all "$GRAPH/servicePrincipals/$resource_id/appRoleAssignedTo" |
    jq -c '[.[] | select(.principalType == "ServicePrincipal") | {principalId, resourceId, appRoleId}]' >"$TMP/assigned.part.json"
  jq -s -c 'add' "$TMP/assigned.json" "$TMP/assigned.part.json" >"$TMP/assigned.new" && mv "$TMP/assigned.new" "$TMP/assigned.json"
done
echo '[]' >"$TMP/external.json"
while IFS= read -r pid; do
  [[ -n "$pid" ]] || continue
  graph_get "$GRAPH/servicePrincipals/$pid"'?$select=id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,accountEnabled' allow-missing >"$TMP/ext.raw.json"
  [[ "$(jq -r 'type' "$TMP/ext.raw.json")" != null ]] || continue
  jq -c --arg id "$pid" --slurpfile a "$TMP/assigned.json" \
    '{id, appId, displayName, servicePrincipalType, appOwnerOrganizationId, accountEnabled,
      appRoleAssignments: [$a[0][] | select(.principalId == $id) | {resourceId, appRoleId}]}' "$TMP/ext.raw.json" >"$TMP/ext.one.json"
  jq -s -c 'add' "$TMP/external.json" <(jq -c '[.]' "$TMP/ext.one.json") >"$TMP/external.new" && mv "$TMP/external.new" "$TMP/external.json"
done < <(jq -r --slurpfile own "$TMP/own-sp-ids.json" '[.[].principalId] | unique | map(select(. as $p | any($own[0][]; . == $p) | not)) | .[]' "$TMP/assigned.json")
echo "  $(jq 'length' "$TMP/external.json") service principal(s) without an app registration here" >&2

# A property the API did not return at all is a collection problem, not a finding; say so in the report.
notes='[]'
if [[ "$(jq -s 'map(has("servicePrincipalLockConfiguration") and .servicePrincipalLockConfiguration != null) | any | not' "$TMP"/apps/[0-9]*.json)" == true ]]; then
  notes='["No application returned servicePrincipalLockConfiguration: the lock rule may be failing because the field was not readable with this account, not because the lock is off. Check one app in the portal."]'
fi

jq -s -c --slurpfile r "$TMP/resources.json" --slurpfile x "$TMP/external.json" --argjson notes "$notes" --arg at "$(date -u +%FT%TZ)" \
  '{collectedAt: $at, collectionNotes: $notes, applications: ., externalPrincipals: $x[0], resources: $r[0]}' "$TMP"/apps/[0-9]*.json >"$OUT/graph.json"
echo "Wrote $OUT/graph.json ($count applications)" >&2

if [[ "$RUN_REPORT" == 1 ]]; then
  rc=0
  run_report || rc=$?
  echo "Next: pwsh $HERE/exchange-rbac-audit.ps1 $OUT   then   $0 --report-only $OUT" >&2
  exit "$rc"
fi
