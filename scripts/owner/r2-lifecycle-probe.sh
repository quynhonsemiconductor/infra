#!/usr/bin/env bash
# r2-lifecycle-probe.sh — find out, without touching a production bucket, why the R2 lifecycle PUT
# returns 400 on rules that cover a prefix carrying a bucket lock.
#
#   CLOUDFLARE_API_TOKEN=... scripts/owner/r2-lifecycle-probe.sh <account_id>
#
# 2026-11-07 context: adding four 30-day lifecycle rules (pg-rova/ pg-opshub/ pg-kb/ pg-coder/) made every
# onprem apply fail with
#   PUT .../r2/buckets/qnsc-backups/lifecycle: 400 {"code":10040,"message":"The JSON you provided was not
#   well formed."}
# The body is well formed (replayed against the pinned provider), the rule count is far under the 1000
# limit, and 5.28.1 is the latest provider — so the API is objecting to the CONTENT. The one property
# unique to those rules: each prefix also carries a bucket lock.
#
# This script answers it on a THROWAWAY bucket, so no production bucket is ever written:
#   1. create qnsc-lifecycle-probe-<UTC timestamp>
#   2. PUT a lifecycle rule on a prefix with NO lock          -> expect 200 (control)
#   3. PUT a bucket lock on <prefix>/<gen>/wals/
#   4. PUT a lifecycle rule whose prefix now carries a lock  -> the experiment
#   5. delete the probe bucket (it holds no objects)
#
# If step 4 fails where step 2 succeeded, the lock/lifecycle interaction is the cause, and the message it
# prints is the fact the provider's wrapper hid. If step 4 also succeeds, the cause is elsewhere and the
# status/error from each step narrows it.
#
# TOKEN: this needs an account-scoped API token with **Workers R2 Storage: Edit** and nothing else — mint a
# throwaway one in the dashboard (My Profile -> API Tokens -> Create Custom Token) and give it a one-day
# TTL. Do NOT use the long-lived apply token, and do not store this one anywhere.
#
# The token never appears in argv: every request reads it from curl's config on stdin (`-K -`), so `ps`
# shows nothing.
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN (a throwaway token with Workers R2 Storage: Edit)}"
account=${1:?usage: r2-lifecycle-probe.sh <account_id>}
bucket="qnsc-lifecycle-probe-$(date -u +%Y%m%dT%H%M%SZ)"
base="https://api.cloudflare.com/client/v4/accounts/${account}/r2/buckets"

# cfg <method> <url> [json-file] — one request with the token on stdin; prints HTTP status, leaves the body
# in $BODY_FILE. Never puts the token on the command line.
BODY_FILE=""
cfg() {
  local method=$1 url=$2 data=${3:-}
  local args=(-sS -o "$BODY_FILE" -w '%{http_code}' -X "$method" -K - -H 'Content-Type: application/json')
  if [ -n "$data" ]; then args+=(--data @"$data"); fi
  printf 'header = "Authorization: Bearer %s"\n' "$CLOUDFLARE_API_TOKEN" | curl "${args[@]}" "$url"
}

show() { # show <label> <status>
  echo "$1 -> HTTP $2"
  jq -c '{success, errors: [.errors[]? | {code, message}]}' "$BODY_FILE" 2>/dev/null \
    || head -c 400 "$BODY_FILE"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
BODY_FILE="$tmp/body.json"

created=0
cleanup() {
  if [ "$created" = "1" ]; then
    status="$(BODY_FILE="$tmp/del.json" cfg DELETE "${base}/${bucket}" || true)"
    echo "delete probe bucket ${bucket} -> HTTP ${status:-?}"
    [ "${status:-}" = "200" ] || echo "::warning::could not delete the probe bucket — delete '${bucket}' by hand (it is empty)."
  fi
}
trap 'cleanup; rm -rf "$tmp"' EXIT

# 1. create
cat > "$tmp/create.json" <<JSON
{"name":"${bucket}","location":"apac"}
JSON
status="$(cfg POST "${base}" "$tmp/create.json")"
show "create ${bucket}" "$status"
[ "$status" = "200" ] || { echo "STOP: the token cannot create buckets (needs Workers R2 Storage: Edit)."; exit 1; }
created=1

# 2. control: a lifecycle rule on a prefix with no lock
cat > "$tmp/lc-control.json" <<'JSON'
{"rules":[{"id":"probe-control","enabled":true,"conditions":{"prefix":"probe-control/"},
  "deleteObjectsTransition":{"condition":{"type":"Age","maxAge":2592000}}}]}
JSON
status="$(cfg PUT "${base}/${bucket}/lifecycle" "$tmp/lc-control.json")"
show "lifecycle, prefix WITHOUT a lock" "$status"
control_ok=$([ "$status" = "200" ] && echo yes || echo no)

# 3. a bucket lock on probe-lock/<gen>/wals/
cat > "$tmp/lock.json" <<'JSON'
{"rules":[{"id":"lock-probe-14d","enabled":true,"prefix":"probe-lock/probe-lock-g1/wals/",
  "condition":{"type":"Age","maxAgeSeconds":1209600}}]}
JSON
status="$(cfg PUT "${base}/${bucket}/lock" "$tmp/lock.json")"
show "bucket lock on probe-lock/probe-lock-g1/wals/" "$status"

# 4. the experiment: a 30-day lifecycle rule whose prefix now carries the lock
cat > "$tmp/lc-locked.json" <<'JSON'
{"rules":[{"id":"probe-control","enabled":true,"conditions":{"prefix":"probe-control/"},
  "deleteObjectsTransition":{"condition":{"type":"Age","maxAge":2592000}}},
 {"id":"probe-lock","enabled":true,"conditions":{"prefix":"probe-lock/"},
  "deleteObjectsTransition":{"condition":{"type":"Age","maxAge":2592000}}}]}
JSON
status="$(cfg PUT "${base}/${bucket}/lifecycle" "$tmp/lc-locked.json")"
show "lifecycle, prefix WITH a 14-day lock (the failing shape)" "$status"
locked_status=$status

echo
if [ "$control_ok" = "yes" ] && [ "$locked_status" != "200" ]; then
  echo "CONCLUSION: the lock/lifecycle interaction is the cause — same body, 200 without a lock, ${locked_status} with one."
  echo "Fix in IaC: keep the archives' immutability from the lock and prune with barman; or set the lifecycle"
  echo "maxAge to what the API accepts for a locked prefix (the error above names it)."
elif [ "$locked_status" = "200" ]; then
  echo "CONCLUSION: a locked prefix is accepted — the cause is elsewhere; send the four step results back."
else
  echo "CONCLUSION: inconclusive (the control step also failed) — send the four step results back."
fi
