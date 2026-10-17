#!/usr/bin/env bash
# READ-ONLY audit of the Entra app registrations against the QNSC app-registration standard
# (HYBRID-INFRA-PLAN section 7.4). Collects metadata with `az rest` GET requests against Microsoft Graph,
# writes graph.json, and runs entra_report.py to produce entra-audit-report.md / .json.
#
#   az login                              # an account with the Global Reader role is enough; no write role
#   ./entra-audit.sh [OUTDIR]             # default: ~/entra-audit-<date>/
#   ./entra-audit.sh --report-only OUTDIR # re-run the report on files already collected (e.g. after exchange.json)
#
# Only GET requests are made: every call goes through graph_get(), the only place `az rest` appears, and
# check-readonly.sh (run in CI) fails if anything else is added. No secret VALUE is read or written: credential
# metadata is reduced to keyId, displayName and dates (the `hint` and `key` fields are dropped).
# The output directory must be outside any git repository; it holds tenant data.
# SC2016: `$select` / `$top` are literal OData query options, not shell variables.
# shellcheck disable=SC2016
set -euo pipefail

GRAPH="https://graph.microsoft.com/v1.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTS="Rova,OpsHub,KB,LMS"
RUN_REPORT=1
REPORT_ONLY=0
OUT=""

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "entra-audit: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --no-report) RUN_REPORT=0 ;;
    --report-only) REPORT_ONLY=1 ;;
    --products) shift; [[ $# -gt 0 ]] || die "--products needs a value"; PRODUCTS="$1" ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$OUT" ]] || die "one output directory only"; OUT="$1" ;;
  esac
  shift
done
OUT="${OUT:-$HOME/entra-audit-$(date +%F)}"

run_report() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed for the report (collected files are in $OUT)"
  local rc=0
  python3 "$HERE/entra_report.py" "$OUT" --products "$PRODUCTS" || rc=$?
  return "$rc"
}

if [[ "$REPORT_ONLY" == 1 ]]; then
  [[ -f "$OUT/graph.json" ]] || die "$OUT/graph.json not found"
  run_report
  exit $?
fi

command -v az >/dev/null 2>&1 || die "Azure CLI (az) not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# The audit data must never end up in a repository.
parent="$(dirname "$OUT")"
if command -v git >/dev/null 2>&1 && [[ -d "$parent" ]] && git -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "$OUT is inside a git repository; choose a directory outside it (the default is under \$HOME)"
fi

umask 077
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

az account show --query user.name -o tsv >/dev/null 2>&1 || die "not signed in: run 'az login' first"
echo "Signed in as $(az account show --query user.name -o tsv). Reading only." >&2

# ── the only network call in this script ─────────────────────────────────────────────────────────────────
# Prints the response body on stdout. A 404 prints `null` (an app without a service principal is a finding,
# not an error). Throttling (429) and 5xx are retried with a pause.
graph_get() {
  local url="$1" try err
  err="$TMP/err.txt"
  for try in 1 2 3 4; do
    if az rest --method get --url "$url" --output json 2>"$err"; then
      return 0
    fi
    if grep -qiE 'ResourceNotFound|Request_ResourceNotFound|404' "$err"; then
      echo null
      return 0
    fi
    if grep -qiE '429|TooManyRequests|50[023]|ServiceUnavailable|timed out' "$err" && [[ "$try" -lt 4 ]]; then
      sleep $((try * 3))
      continue
    fi
    echo "entra-audit: GET failed: $url" >&2
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
# Adds a resource service principal (Graph, SharePoint, ...) with its role and scope names, once.
fetch_resource_by_object_id() {
  local id="$1" body
  jq -e --arg id "$id" 'has($id)' "$TMP/resources.json" >/dev/null && return 0
  body="$(graph_get "$GRAPH/servicePrincipals/$id?$RES_SELECT")"
  add_resource "$body"
}
fetch_resource_by_app_id() {
  local app_id="$1" body
  jq -e --arg a "$app_id" 'any(.[]; .appId == $a)' "$TMP/resources.json" >/dev/null && return 0
  body="$(graph_get "$GRAPH/servicePrincipals(appId='$app_id')?$RES_SELECT")"
  add_resource "$body"
}
add_resource() {
  local body="$1"
  [[ "$body" != null ]] || return 0
  jq -c --argjson r "$body" '. + {($r.id): {appId: $r.appId, displayName: $r.displayName,
      appRoles: [($r.appRoles // [])[] | {id, value, displayName}],
      oauth2PermissionScopes: [($r.oauth2PermissionScopes // [])[] | {id, value}]}}' "$TMP/resources.json" >"$TMP/resources.new"
  mv "$TMP/resources.new" "$TMP/resources.json"
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
    jq -c '[.[] | {type: (."@odata.type" // "" | sub("#microsoft.graph."; "")), displayName, userPrincipalName}]' >"$TMP/apps/owners.json"
  graph_get_all "$GRAPH/applications/$object_id/federatedIdentityCredentials" |
    jq -c '[.[] | {name, issuer}]' >"$TMP/apps/federated.json"

  sp="$(graph_get "$GRAPH/servicePrincipals(appId='$app_id')"'?$select=id,appId,displayName,appRoleAssignmentRequired,accountEnabled,servicePrincipalType')"
  if [[ "$sp" == null ]]; then
    echo null >"$TMP/apps/sp.json"
  else
    sp_id="$(jq -r '.id' <<<"$sp")"
    graph_get_all "$GRAPH/servicePrincipals/$sp_id/appRoleAssignments" |
      jq -c '[.[] | {resourceId, appRoleId, resourceDisplayName}]' >"$TMP/apps/assignments.json"
    graph_get_all "$GRAPH/servicePrincipals/$sp_id/oauth2PermissionGrants" |
      jq -c '[.[] | {resourceId, consentType, scope}]' >"$TMP/apps/grants.json"
    jq -c --slurpfile a "$TMP/apps/assignments.json" --slurpfile g "$TMP/apps/grants.json" \
      '{id, appRoleAssignmentRequired, accountEnabled, servicePrincipalType, appRoleAssignments: $a[0], oauth2PermissionGrants: $g[0]}' \
      <<<"$sp" >"$TMP/apps/sp.json"
    while IFS= read -r rid; do [[ -n "$rid" ]] && fetch_resource_by_object_id "$rid"; done < <(jq -r '(.appRoleAssignments + .oauth2PermissionGrants)[].resourceId' "$TMP/apps/sp.json" | sort -u)
  fi
  while IFS= read -r raid; do [[ -n "$raid" ]] && fetch_resource_by_app_id "$raid"; done < <(jq -r '(.requiredResourceAccess // [])[].resourceAppId' "$TMP/apps/base.json" | sort -u)

  jq -c --slurpfile o "$TMP/apps/owners.json" --slurpfile f "$TMP/apps/federated.json" --slurpfile s "$TMP/apps/sp.json" \
    '. + {owners: $o[0], federatedCredentials: $f[0], servicePrincipal: $s[0]}' "$TMP/apps/base.json" >"$TMP/apps/$i.json"
done < <(jq -c '.[]' "$TMP/applications.json")

# A property the API did not return at all is a collection problem, not a finding; say so in the report.
notes='[]'
if [[ "$(jq -s 'map(has("servicePrincipalLockConfiguration") and .servicePrincipalLockConfiguration != null) | any | not' "$TMP"/apps/[0-9]*.json)" == true ]]; then
  notes='["No application returned servicePrincipalLockConfiguration: the lock rule may be failing because the field was not readable with this account, not because the lock is off. Check one app in the portal."]'
fi

jq -s -c --slurpfile r "$TMP/resources.json" --argjson notes "$notes" --arg at "$(date -u +%FT%TZ)" \
  '{collectedAt: $at, collectionNotes: $notes, applications: ., resources: $r[0]}' "$TMP"/apps/[0-9]*.json >"$OUT/graph.json"
echo "Wrote $OUT/graph.json ($count applications)" >&2

if [[ "$RUN_REPORT" == 1 ]]; then
  rc=0
  run_report || rc=$?
  echo "Next: pwsh $HERE/exchange-rbac-audit.ps1 $OUT   then   $0 --report-only $OUT" >&2
  exit "$rc"
fi
