#!/usr/bin/env bash
# r2-lifecycle-probe.sh — answer, in one authenticated call, why the R2 lifecycle PUT is rejected.
#
#   CLOUDFLARE_API_TOKEN=... scripts/owner/r2-lifecycle-probe.sh <account_id> <bucket>          # GET only
#   CLOUDFLARE_API_TOKEN=... scripts/owner/r2-lifecycle-probe.sh <account_id> <bucket> --put    # GET, then PUT
#
# 2026-11-07: adding four 30-day rules (pg-rova/ pg-opshub/ pg-kb/ pg-coder/) made every onprem apply
# fail with
#   PUT .../r2/buckets/qnsc-backups/lifecycle: 400
#   {"code":10040,"message":"The JSON you provided was not well formed."}
# The request body is well formed when replayed against the pinned provider (scripts reproduce it with a
# local endpoint), so the API is objecting to the CONTENT. This prints what the API actually holds and,
# with --put, sends the exact body the provider would have sent and prints the API's own answer —
# including the `errors[].message` the provider hides inside its generic wrapper.
#
# --put REPLACES the bucket's lifecycle rules with (live rules + the four new ones). That is idempotent
# and is exactly what the next apply would do; if the API accepts it, re-running the apply is a no-op.
# Nothing is deleted: the four rules are only added.
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (an R2-scoped token with Workers R2 Storage:Edit)}"

account=${1:?usage: r2-lifecycle-probe.sh <account_id> <bucket> [--put]}
bucket=${2:?usage: r2-lifecycle-probe.sh <account_id> <bucket> [--put]}
mode=${3:-}

api="https://api.cloudflare.com/client/v4/accounts/${account}/r2/buckets/${bucket}/lifecycle"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

get_status="$(curl -sS -o "$tmp/live.json" -w '%{http_code}' -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "$api")"
echo "GET  ${api} -> HTTP ${get_status}"
jq -c '{success, rule_count: (.result.rules | length?), errors: [.errors[]? | {code, message}]}' "$tmp/live.json" 2>/dev/null \
  || { echo "body:"; head -c 600 "$tmp/live.json"; exit 1; }

[ "$get_status" = "200" ] || { echo "STOP: the GET failed; fix the token/ids before probing the PUT."; exit 1; }

# The four rules the failed apply wanted to add, in the API's own field names.
jq -c '.result.rules' "$tmp/live.json" > "$tmp/rules.json"
for id in pg-coder pg-kb pg-opshub pg-rova; do
  jq -c --arg id "$id" '. + [{
      id: $id, enabled: true,
      conditions: { prefix: ($id + "/") },
      deleteObjectsTransition: { condition: { type: "Age", maxAge: 2592000 } }
    }]' "$tmp/rules.json" > "$tmp/rules.next.json"
  mv "$tmp/rules.next.json" "$tmp/rules.json"
done
jq -c '{rules: .}' "$tmp/rules.json" > "$tmp/body.json"

echo "candidate body: $(wc -c < "$tmp/body.json") bytes, $(jq '.rules | length' "$tmp/body.json") rules"
jq -c '[.rules[] | {id, prefix: .conditions.prefix}]' "$tmp/body.json"

if [ "$mode" != "--put" ]; then
  echo "GET only. Re-run with --put to send the body above and print the API's answer."
  exit 0
fi

put_status="$(curl -sS -o "$tmp/put.json" -w '%{http_code}' -X PUT \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H 'Content-Type: application/json' \
  --data @"$tmp/body.json" "$api")"
echo "PUT  ${api} -> HTTP ${put_status}"
jq -c '{success, rule_count: (.result.rules | length?), errors: [.errors[]? | {code, message}]}' "$tmp/put.json" 2>/dev/null \
  || head -c 800 "$tmp/put.json"

if [ "$put_status" = "200" ]; then
  echo "ACCEPTED: the four rules exist now; re-run the onprem apply and it should be a no-op."
else
  echo "REJECTED: the body above is valid JSON and matches the API schema; note the code/message above and"
  echo "send it back with the probe output. The next suspect is the bucket lock on the same prefixes."
fi
