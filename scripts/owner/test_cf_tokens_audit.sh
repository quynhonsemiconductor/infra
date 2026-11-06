#!/usr/bin/env bash
# Offline regression test for cf-tokens-audit.sh's policy summariser.
#
# The owner's 2026-11-06 run printed `jq: error: string ("*") has no keys` once
# per token: an API-token policy resource is either an object
# ({"com.cloudflare.api.account.zone": "<id>"}) or the literal string "*".
# This locks both shapes, the mixed-resource token, a policy without permission
# groups, no policies at all, and the exit codes — with no network and no az.
#
#   bash scripts/owner/test_cf_tokens_audit.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/cf-tokens-audit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# ── fixture: one token per shape the API returns ────────────────────────────
cat > "$TMP/tokens.jsonl" <<'EOF'
{"id":"aaa","name":"object-resource","policies":[{"effect":"allow","permission_groups":[{"name":"Workers Scripts:Edit"}],"resources":{"com.cloudflare.api.account":"abc"}}]}
{"id":"bbb","name":"star-resource","policies":[{"effect":"allow","permission_groups":[{"name":"Zone:Read"}],"resources":"*"}]}
{"id":"ccc","name":"mixed-resource","policies":[{"effect":"allow","permission_groups":[{"name":"Zone:Read"},{"name":"DNS:Read"}],"resources":["*",{"com.cloudflare.api.account.zone":"zzz"}]}]}
{"id":"ddd","name":"no-groups","policies":[{"effect":"allow","resources":"*"}]}
{"id":"eee","name":"no-policies"}
EOF

out="$(bash "$SCRIPT" --policy-fixture "$TMP/tokens.jsonl")" || fail "--policy-fixture exited non-zero"
[ -n "$out" ] || fail "no output"

# object resource → key=value, permission group printed
grep -q 'object-resource.*allow: Workers Scripts:Edit @ com.cloudflare.api.account=abc' <<<"$out" \
  || fail "object resource not rendered: $out"
pass "object resource"

# string resource → the literal *, not a jq error
grep -q 'star-resource.*allow: Zone:Read @ \*' <<<"$out" || fail "string resource not rendered: $out"
grep -qi 'error' <<<"$out" && fail "jq error leaked into the output: $out"
pass "string resource (*)"

# mixed list → both forms in one line, groups joined
grep -q 'mixed-resource.*allow: Zone:Read,DNS:Read @ \*; com.cloudflare.api.account.zone=zzz' <<<"$out" \
  || fail "mixed resources not rendered: $out"
pass "mixed resources"

# no permission_groups → empty group list, no crash
grep -q 'no-groups.*allow:  @ \*' <<<"$out" || fail "missing permission groups not tolerated: $out"
pass "no permission groups"

# no policies → "none"
grep -q 'no-policies.*none' <<<"$out" || fail "empty policy list not rendered as none: $out"
pass "no policies"

# unreadable fixture → exit 2
if bash "$SCRIPT" --policy-fixture "$TMP/missing.jsonl" >/dev/null 2>&1; then
  fail "a missing fixture must exit non-zero"
fi
pass "missing fixture exits non-zero"

# unknown argument → exit 2, with the usage line
if bash "$SCRIPT" --nonsense >/dev/null 2>&1; then
  fail "an unknown argument must exit non-zero"
fi
pass "unknown argument rejected"

echo "all cf-tokens-audit checks passed"
