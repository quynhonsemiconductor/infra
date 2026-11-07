#!/usr/bin/env bash
# Set MCP portal membership around the provider 5.28.1 servers[] bug.
#
# Cloudflare's provider cannot manage a portal's `servers` list: every plan shows an
# in-place update from computed fields only (updated_tools, ...) and the apply PUTs
# `updated_tools: null`, which the API refuses (400 "Expected array, received null").
# The portal resource therefore keeps `ignore_changes = [servers]` and this script is run by
# terraform_data "mcp_portal_members" (live/edge/mcp_portal.tf) on apply, when the desired
# membership changes.
#
# What it does:
#   1. GET the portal;
#   2. build the PUT body FROM that GET, so every field Cloudflare filled (updated_tools,
#      updated_prompts, default_disabled, ...) is sent back unchanged; a null list is sent as
#      [] (the exact shape the API rejects when null). Only the membership changes: exactly
#      MCP_PORTAL_SERVERS, each with on_behalf = true (Require user auth ON);
#   3. print the add/remove diff. A REMOVAL is refused unless MCP_PORTAL_ALLOW_REMOVE=1:
#      a server whose resource count drops to 0 (losing its live flag) or whose id changes
#      must never be kicked out of the portal by a silent apply;
#   4. PUT only when the current membership differs (idempotent: a no-op apply sends nothing);
#   5. GET again and fail unless the membership is exactly the desired one.
#
# Inputs (environment, never argv — the token must not appear in a process listing; every
# request carries it in a curl -K - config on stdin, never in a -H argument):
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, MCP_PORTAL_ID,
#   MCP_PORTAL_SERVERS (JSON array of {server_id, on_behalf}),
#   MCP_PORTAL_ALLOW_REMOVE (optional; exactly "1" permits a removal),
#   CLOUDFLARE_API_BASE (optional; defaults to the Cloudflare API, used by the offline test).
#
#   bash scripts/edge/mcp-portal-members.sh
set -euo pipefail

fail() { echo "mcp-portal-members: FAIL: $*" >&2; exit 1; }

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
: "${MCP_PORTAL_ID:?MCP_PORTAL_ID is required}"
: "${MCP_PORTAL_SERVERS:?MCP_PORTAL_SERVERS is required}"

API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
URL="${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/ai-controls/mcp/portals/${MCP_PORTAL_ID}"

want=$(printf '%s' "$MCP_PORTAL_SERVERS" | jq -c .) || fail "MCP_PORTAL_SERVERS is not valid JSON"
[ "$(printf '%s' "$want" | jq -r 'type')" = "array" ] || fail "MCP_PORTAL_SERVERS must be a JSON array"
[ "$(printf '%s' "$want" | jq -r 'length')" -gt 0 ] || fail "MCP_PORTAL_SERVERS is empty: refusing to empty the portal"

# The token goes into curl's config on STDIN (-K -). It is never an argv element.
curl_auth() { printf 'header = "Authorization: Bearer %s"\n' "${CLOUDFLARE_API_TOKEN}"; }

cf_get() {
	curl_auth | curl -sS --retry 3 --retry-connrefused -K - "$URL"
}

resp=$(cf_get) || fail "GET ${URL} failed"
[ "$(printf '%s' "$resp" | jq -r '.success // false')" = "true" ] ||
	fail "GET ${URL} did not succeed: $(printf '%s' "$resp" | jq -c '.errors // .' | cut -c1-400)"

current=$(printf '%s' "$resp" | jq -c '.result')
current_servers=$(printf '%s' "$current" | jq -c '.servers // []')

# Existing entries are carried over WHOLE (every Cloudflare-filled field), with on_behalf
# forced true and a null tool/prompt list normalised to []. A new server enters with both
# lists as [] — an absent/null updated_tools is the 400 the provider hits.
merged=$(jq -n -c --argjson cur "$current_servers" --argjson want "$want" '
	[ $want[] as $d
	  | ((first($cur[]? | select(.server_id == $d.server_id))
	      // {server_id: $d.server_id, on_behalf: true, updated_tools: [], updated_prompts: []})
	     | .on_behalf = true
	     | .updated_tools = (.updated_tools // [])
	     | .updated_prompts = (.updated_prompts // []))
	]')

added=$(jq -n -r --argjson cur "$current_servers" --argjson want "$want" '
	($want | map(.server_id)) - ($cur | map(.server_id)) | sort | join(", ")')
removed=$(jq -n -r --argjson cur "$current_servers" --argjson want "$want" '
	($cur | map(.server_id)) - ($want | map(.server_id)) | sort | join(", ")')

same=$(jq -n -r --argjson cur "$current_servers" --argjson want "$want" '
	(($cur | map({server_id, on_behalf: (.on_behalf // false)}) | sort_by(.server_id))
	 == ($want | map({server_id, on_behalf: (.on_behalf // false)}) | sort_by(.server_id)))')

if [ "$same" = "true" ]; then
	echo "mcp-portal-members: portal ${MCP_PORTAL_ID} already matches $(printf '%s' "$want" | jq -r 'map(.server_id) | join(", ")'); no PUT"
	exit 0
fi

echo "mcp-portal-members: portal ${MCP_PORTAL_ID} add [${added:-none}] remove [${removed:-none}]"

if [ -n "$removed" ] && [ "${MCP_PORTAL_ALLOW_REMOVE:-0}" != "1" ]; then
	fail "removing [${removed}] from portal ${MCP_PORTAL_ID}: a membership loss is never silent. Re-check the server's live flag / id. To accept it, set MCP_PORTAL_ALLOW_REMOVE=1 for the apply."
fi

body=$(jq -c --argjson servers "$merged" '.servers = $servers' <<<"$current")
put=$(curl_auth | curl -sS --retry 3 --retry-connrefused -X PUT \
	-H "Content-Type: application/json" \
	--data-binary "$body" -K - "$URL") || fail "PUT ${URL} failed"
[ "$(printf '%s' "$put" | jq -r '.success // false')" = "true" ] ||
	fail "PUT ${URL} did not succeed: $(printf '%s' "$put" | jq -c '.errors // .' | cut -c1-400)"

# Verify on a fresh GET, not on the PUT response: the API is the source of truth.
resp=$(cf_get) || fail "GET (verify) ${URL} failed"
got=$(printf '%s' "$resp" | jq -c '.result.servers // []')
verified=$(jq -n -r --argjson got "$got" --argjson want "$want" '
	(($got | map({server_id, on_behalf: (.on_behalf // false)}) | sort_by(.server_id))
	 == ($want | map({server_id, on_behalf: (.on_behalf // false)}) | sort_by(.server_id)))')
[ "$verified" = "true" ] ||
	fail "portal ${MCP_PORTAL_ID} membership after PUT is $(printf '%s' "$got" | jq -r 'map(.server_id) | join(", ")'), wanted $(printf '%s' "$want" | jq -r 'map(.server_id) | join(", ")')"

echo "mcp-portal-members: portal ${MCP_PORTAL_ID} now has $(printf '%s' "$want" | jq -r 'map(.server_id) | join(", ")')"
