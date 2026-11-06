#!/usr/bin/env bash
# cf-gateway-preflight.sh — prove the APPLY token can create a Gateway L4 rule, and print the API's
# own error when it cannot.
#
#   CF_TOKEN=... CF_ACCOUNT_ID=... bash .github/scripts/cf-gateway-preflight.sh
#
# Why this exists: on 2026-11-06 the apply died with `Error: failed to make http request` — the
# provider's generic wrapper for ANY error from the SDK call (internal/services/
# zero_trust_gateway_policy/resource.go wraps every diagnostic that way), so the HTTP status and the
# API's message never reached the log. The plan (read-only token) could LIST gateway policies, which
# proves the read scope; the apply uses a different token, and the most common gap there is the
# account-scoped **Zero Trust: Edit** permission, which Gateway rules need even when Access
# app/policy edits already work.
#
# The probe creates a DISABLED allow rule (filters l4, no traffic expression: it matches nothing),
# prints the status and the API `errors`, then deletes it. It never prints the token.
set -euo pipefail

: "${CF_TOKEN:?CF_TOKEN is required}"
: "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"

api="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/gateway/rules"
name="qnsc-gateway-preflight-$(date -u +%Y%m%dT%H%M%SZ)"
body="$(printf '{"name":"%s","description":"live/edge apply preflight - safe to delete","action":"allow","enabled":false,"filters":["l4"]}' "$name")"

resp="$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST \
  -H "Authorization: Bearer ${CF_TOKEN}" -H 'Content-Type: application/json' \
  --data "$body" "$api")"
status="$(printf '%s' "$resp" | tail -n1)"
json="$(printf '%s' "$resp" | sed '$d')"

echo "gateway preflight: POST ${api} -> HTTP ${status}"
printf '%s' "$json" | jq -c '{success, errors: [.errors[]? | {code, message}]}' 2>/dev/null \
  || printf '%s\n' "$json"

if [ "$status" != "200" ]; then
  msg="$(printf '%s' "$json" | jq -r '.errors[0].message // "no message"' 2>/dev/null || echo "no JSON body")"
  echo "::error title=Gateway preflight::Creating an L4 Gateway rule failed: HTTP ${status} — ${msg}. The apply token needs the account-scoped Zero Trust: Edit permission (Cloudflare dashboard -> My Profile -> API Tokens -> the apply token -> add 'Account > Zero Trust > Edit'); the plan's read-only token already lists policies, so read access exists."
  exit 1
fi

rule_id="$(printf '%s' "$json" | jq -r '.result.id // empty')"
if [ -n "$rule_id" ]; then
  del_status="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${CF_TOKEN}" "${api}/${rule_id}")"
  echo "gateway preflight: created and deleted ${rule_id} (DELETE HTTP ${del_status})"
  if [ "$del_status" != "200" ]; then
    echo "::error title=Gateway preflight::probe rule ${rule_id} could not be deleted (HTTP ${del_status}). Delete '${name}' in the dashboard: it is disabled and matches nothing."
    exit 1
  fi
else
  echo "::warning::the probe rule was created but its id was not returned; delete '${name}' (disabled) in the dashboard."
fi

echo "gateway preflight: PASS — the apply token can create L4 Gateway rules."
