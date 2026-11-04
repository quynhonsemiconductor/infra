#!/usr/bin/env bash
# READ-ONLY report of the tenant-wide permissions third-party (and first-party) apps hold in the QNSC tenant.
#
#   az login --tenant <tenant>.onmicrosoft.com --allow-no-subscriptions   # Global Reader is enough
#   ./tenant-consents.sh                 # default output: ~/tenant-consents-<date>/
#   ./tenant-consents.sh DIR             # collect into DIR and print the report
#   ./tenant-consents.sh --report-only DIR   # re-render from an existing DIR/tenant-consents.json
#
# The audit (platform audit 2026-11-04, N-M1) found tenant-wide delegated consents (consentType
# AllPrincipals) on apps that are not in IaC: every user in the tenant can be an actor for those scopes.
# This script lists them, plus the APPLICATION permissions held on Microsoft Graph and Exchange Online
# (admin consent for an app role is tenant-wide by nature), so the owner can decide per app: keep
# (sanctioned tool, later turned into per-user grants) or revoke (delete the grant/assignment).
#
# Only GET requests are made: every call goes through graph_get(), the only place `az rest` appears, and
# check-readonly.sh (run in CI) fails if anything else is added. The output directory must be outside any
# git repository — it names real apps and permission scopes. Send the report privately.
# SC2016: `$filter` / `$select` / `$top` are literal OData query options, not shell variables.
# shellcheck disable=SC2016
set -euo pipefail
umask 077

GRAPH="https://graph.microsoft.com/v1.0"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
EXCHANGE_APP_ID="00000002-0000-0ff1-ce00-000000000000"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=""
REPORT_ONLY=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
die() { echo "tenant-consents: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --report-only) REPORT_ONLY=1 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$OUT" ]] || die "one output directory only"; OUT="$1" ;;
  esac
  shift
done
OUT="${OUT:-$HOME/tenant-consents-$(date +%F)}"

if [[ "$REPORT_ONLY" == 1 ]]; then
  [[ -f "$OUT/tenant-consents.json" ]] || die "$OUT/tenant-consents.json not found"
  python3 "$HERE/tenant_consents_report.py" "$OUT/tenant-consents.json" >"$OUT/tenant-consents-report.md" ||
    die "the collected file could not be rendered (see above); it is left at $OUT/tenant-consents.json"
  cat "$OUT/tenant-consents-report.md"
  echo "Report: $OUT/tenant-consents-report.md" >&2
  exit 0
fi

command -v az >/dev/null 2>&1 || die "Azure CLI (az) not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# Tenant data must never end up in a repository. Check the nearest EXISTING ancestor, so a directory that
# does not exist yet (and its parents) is judged by where it would be created.
refuse_inside_git_repo() {
  local d="$OUT"
  while [[ ! -d "$d" ]]; do d="$(dirname "$d")"; done
  if command -v git >/dev/null 2>&1 && git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$OUT is inside a git repository; choose a directory outside it (the default is under \$HOME)"
  fi
}

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
# Prints the response body on stdout. EVERY failure aborts the run, so a permission error can never read as
# "nothing found". `allow-missing` is used only for service-principal lookups by id, where "not found" means
# the object was deleted between the list and the lookup (print `null`). Throttling and 5xx are retried.
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
      echo "tenant-consents: throttled or unavailable, retrying in ${pauses[$try]}s: $url" >&2
      sleep "${TENANT_CONSENTS_RETRY_SLEEP:-${pauses[$try]}}"
      continue
    fi
    echo "tenant-consents: GET failed (the run is aborted so nothing is silently missing): $url" >&2
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

# ── delegated grants, tenant-wide only ──────────────────────────────────────────────────────────────────
echo "Reading tenant-wide delegated grants..." >&2
graph_get_all "$GRAPH/oauth2PermissionGrants?\$filter=consentType%20eq%20%27AllPrincipals%27&\$top=999" >"$TMP/grants.json"
echo "  $(jq 'length' "$TMP/grants.json") grant(s)" >&2

# ── application permissions on Graph and Exchange ───────────────────────────────────────────────────────
echo "Reading application permissions on Microsoft Graph and Exchange Online..." >&2
echo '[]' >"$TMP/assigned.json"
echo '{}' >"$TMP/res-roles.json"
for resource_app in "$GRAPH_APP_ID" "$EXCHANGE_APP_ID"; do
  graph_get "$GRAPH/servicePrincipals(appId='$resource_app')?\$select=id,appId,displayName,appRoles" allow-missing >"$TMP/res.json"
  if [[ "$(jq -r 'type' "$TMP/res.json")" == null ]]; then
    echo "  (no service principal for $resource_app in this tenant; skipped)" >&2
    continue
  fi
  resource_id="$(jq -r '.id' "$TMP/res.json")"
  jq -c --arg id "$resource_id" '{($id): {displayName, appRoles: [(.appRoles // [])[] | {id, value}]}}' "$TMP/res.json" >"$TMP/roles.one.json"
  jq -s -c 'add' "$TMP/res-roles.json" "$TMP/roles.one.json" >"$TMP/res-roles.new" && mv "$TMP/res-roles.new" "$TMP/res-roles.json"
  graph_get_all "$GRAPH/servicePrincipals/$resource_id/appRoleAssignedTo" |
    jq -c '[.[] | select(.principalType == "ServicePrincipal") | {principalId, resourceId, appRoleId}]' >"$TMP/assigned.part.json"
  jq -s -c 'add' "$TMP/assigned.json" "$TMP/assigned.part.json" >"$TMP/assigned.new" && mv "$TMP/assigned.new" "$TMP/assigned.json"
done
echo "  $(jq 'length' "$TMP/assigned.json") assignment(s)" >&2

# ── display names for every principal and resource the two lists mention ─────────────────────────────────
mkdir -p "$TMP/sps"
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  graph_get "$GRAPH/servicePrincipals/$id?\$select=id,appId,displayName,servicePrincipalType,appOwnerOrganizationId" allow-missing >"$TMP/sps/$id.json"
done < <(jq -r '[.[] | .clientId, .resourceId] | unique[]' "$TMP/grants.json"; jq -r '.[] | .principalId, .resourceId' "$TMP/assigned.json")
if compgen -G "$TMP/sps/*.json" >/dev/null; then
  jq -s -c '[.[] | select(type == "object" and .id) | {(.id): {displayName, appId, servicePrincipalType, appOwnerOrganizationId}}] | add // {}' "$TMP"/sps/*.json >"$TMP/sps.json"
else
  echo '{}' >"$TMP/sps.json" # a tenant with no tenant-wide grants at all still renders an empty report
fi

# ── one portable JSON file: the report step reads only this ──────────────────────────────────────────────
jq -n \
  --slurpfile grants "$TMP/grants.json" \
  --slurpfile assigned "$TMP/assigned.json" \
  --slurpfile sps "$TMP/sps.json" \
  --slurpfile roles "$TMP/res-roles.json" \
  --arg at "$(date -u +%FT%TZ)" \
  --arg tenant "${signed_in##* }" \
  --arg user "${signed_in% *}" '
  def sp($id): ($sps[0][$id] // {});
  def name($id): (sp($id).displayName // $id);
  def role($resource; $id):
    (($roles[0][$resource].appRoles // [])[] | select(.id == $id) | .value) // ("unresolved-role(" + $id + ")");
  {
    collectedAt: $at,
    tenantId: $tenant,
    collectedBy: $user,
    delegated: ([
      $grants[0][]
      | {client: name(.clientId), clientType: (sp(.clientId).servicePrincipalType // ""),
         resource: name(.resourceId), scopes: ((.scope // "") | split(" ") | map(select(length > 0)) | sort)}
    ] | sort_by(.client, .resource)),
    application: ([
      $assigned[0][]
      | {client: name(.principalId), clientType: (sp(.principalId).servicePrincipalType // ""),
         resource: name(.resourceId), role: role(.resourceId; .appRoleId)}
    ] | sort_by(.client, .resource, .role))
  }' >"$OUT/tenant-consents.json"

echo "Wrote $OUT/tenant-consents.json" >&2
"${BASH_SOURCE[0]}" --report-only "$OUT"
