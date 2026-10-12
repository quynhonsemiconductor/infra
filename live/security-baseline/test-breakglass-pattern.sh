#!/usr/bin/env bash
# Tests the event pattern of the rule `qnsc-prod-breakglass-assumed` against recorded-shape events, using the EventBridge
# API itself (events:TestEventPattern evaluates a pattern against an event; it creates nothing and reads nothing).
#
#   ./test-breakglass-pattern.sh [role-arn]          # profile/credentials from your environment
#
# Fixtures in fixtures/breakglass/: match-*.json MUST match, nomatch-*.json MUST NOT.
# The pattern is rendered from the SAME template the stack uses (breakglass-assumed.pattern.json.tftpl).
set -uo pipefail
cd "$(dirname "$0")"
ROLE_ARN="${1:-arn:aws:iam::608983206583:role/qnsc-prod-breakglass}"
REGION="${AWS_REGION:-ap-southeast-1}"
pat="$(mktemp)"; trap 'rm -f "$pat"' EXIT
sed "s|\${role_arn}|$ROLE_ARN|g" breakglass-assumed.pattern.json.tftpl >"$pat"
fail=0
for f in fixtures/breakglass/*.json; do
  name="$(basename "$f")"
  got="$(aws events test-event-pattern --region "$REGION" --no-cli-pager --event-pattern "file://$pat" --event "file://$f" --query Result --output text 2>&1)"
  case "$name" in match-*) want=True;; nomatch-*) want=False;; *) echo "FAIL $name: name must start with match- or nomatch-"; fail=1; continue;; esac
  if [ "$got" = "$want" ]; then echo "PASS $name (matches: $got)"; else echo "FAIL $name: expected Result=$want, got '$got'"; fail=1; fi
done
exit "$fail"
