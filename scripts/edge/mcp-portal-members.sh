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
#      updated_prompts, default_disabled, ...) is sent back unchanged; only the membership
#      changes: exactly MCP_PORTAL_SERVERS, each with on_behalf = true (Require user auth ON);
#   3. PUT only when the current membership differs (idempotent: a no-op apply sends nothing);
#   4. GET again and fail unless the membership is exactly the desired one.
#
# Inputs (environment, never argv — the token must not appear in a process listing):
#   CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, MCP_PORTAL_ID,
#   MCP_PORTAL_SERVERS (JSON array of {server_id, on_behalf}),
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

cf_get() {
	curl -sS --retry 3 --retry-connrefused -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "$URL"
}

resp=$(cf_get) || fail "GET ${URL} failed"
[ "$(printf '%s' "$resp" | jq -r '.success // false')" = "true" ] ||
	fail "GET ${URL} did not succeed: $(printf '%s' "$resp" | jq -c '.errors // .' | cut -c1-400)"

current=$(printf '%s' "$resp" | jq -c '.result')
current_servers=$(printf '%s' "$current" | jq -c '.servers // []')

# Existing entries are carried over WHOLE (updated_tools and every Cloudflare-filled field),
# with on_behalf forced true; a new server enters as {server_id, on_behalf: true}.
merged=$(jq -n -c --argjson cur "$current_servers" --argjson want "$want" '
	[ $want[] as $d
	  | ((first($cur[]? | select(.server_id == $d.server_id)) // {server_id: $d.server_id})
	     | .on_behalf = true)
	]')

same=$(jq -n -r --argjson cur "$current_servers" --argjson want "$want" '
	(($cur | map({server_id, on_behalf: (.on_behalf // false)}) | sort_by(.server_id))
	 == ($want | map({server_id, on_behalf: (.on_behalf // false)}) | sort_by(.server_id)))')

if [ "$same" = "true" ]; then
	echo "mcp-portal-members: portal ${MCP_PORTAL_ID} already matches $(printf '%s' "$want" | jq -r 'map(.server_id) | join(", ")'); no PUT"
	exit 0
fi

body=$(jq -c --argjson servers "$merged" '.servers = $servers' <<<"$current")
put=$(curl -sS --retry 3 --retry-connrefused -X PUT \
	-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
	-H "Content-Type: application/json" \
	--data-binary "$body" "$URL") || fail "PUT ${URL} failed"
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
