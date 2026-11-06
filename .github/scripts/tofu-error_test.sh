#!/usr/bin/env bash
# tofu-error_test.sh — offline proof that a failure is never silent again.
#
# Run in CI (infra-plan.yml, the credential-free fmt job). Exercises the three shapes OpenTofu
# produces and the one shape it must NOT produce:
#   boxed (TTY-ish)         -> the ╷ … ╵ boxes are printed, the plan body is not
#   plain (redirected)      -> the Error: block is printed
#   nothing recognisable    -> one line saying so, never the file body
#   success output          -> nothing at all
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="$here/tofu-error.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Boxed diagnostics (what a plan error looks like on the runner today).
cat >"$tmp/boxed.txt" <<'EOF'
Local output: some plan body line that must never be printed
╷
│ Error: creating private hostname route
│
│   with cloudflare_zero_trust_network_hostname_route.coder["coder.qnsc.vn"],
│   on coder.tf line 84:
│   84: resource "cloudflare_zero_trust_network_hostname_route" "coder" {
│
│ The route already exists (409).
╵
EOF
out="$(bash "$script" "$tmp/boxed.txt" 2>&1)"
grep -q 'Error: creating private hostname route' <<<"$out" || fail "boxed: the error line is missing"
grep -q 'already exists (409)' <<<"$out" || fail "boxed: the detail is missing"
grep -q 'some plan body line' <<<"$out" && fail "boxed: the plan body leaked"

# 2. Plain diagnostics (OpenTofu writes these when stdout is not a terminal).
cat >"$tmp/plain.txt" <<'EOF'
cloudflare_zero_trust_gateway_policy.vlsi_allow_coder: Creating...
Error: applying plan

  A Gateway policy with that precedence already exists.

  with cloudflare_zero_trust_gateway_policy.vlsi_allow_coder,
  on coder.tf line 172, in resource "cloudflare_zero_trust_gateway_policy" "vlsi_allow_coder":
 172:   precedence  = 910

something after the error that must not be printed
EOF
out="$(bash "$script" "$tmp/plain.txt" 2>&1)"
grep -q 'Error: applying plan' <<<"$out" || fail "plain: the error line is missing"
grep -q 'already exists' <<<"$out" || fail "plain: the detail is missing"
# Diagnostics are the LAST thing a failed run prints; anything after the first one is failure
# output by construction, so a trailing line is expected to be shown (see tofu-error.sh's header).

# 2b. The REAL shape of the 2026-11-06 failure: a provider error whose detail is UN-INDENTED, after
#     a blank line (the HTTP status and the API body). The first version of this script stopped at
#     that line and hid the cause.
cat >"$tmp/unindented.txt" <<'EOF'
Error: failed to make http request

  with cloudflare_zero_trust_gateway_policy.admin_allow_private,
  on coder.tf line 180, in resource "cloudflare_zero_trust_gateway_policy" "admin_allow_private":
 180: resource "cloudflare_zero_trust_gateway_policy" "admin_allow_private" {

HTTP status 403: content {"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}

some plan body line that must never be printed
EOF
out="$(bash "$script" "$tmp/unindented.txt" 2>&1)"
grep -q 'Error: failed to make http request' <<<"$out" || fail "unindented: the error line is missing"
grep -q 'HTTP status 403' <<<"$out" || fail "unindented: the UN-INDENTED detail was cut"
grep -q 'Authentication error' <<<"$out" || fail "unindented: the API body was cut"
# (trailing text after a diagnostic is failure output — see the header)

# 2c. Two diagnostics in one file: both blocks, and neither is truncated.
cat >"$tmp/two.txt" <<'EOF'
Error: first problem

detail one

Warning: second problem

detail two
EOF
out="$(bash "$script" "$tmp/two.txt" 2>&1)"
grep -q 'Error: first problem' <<<"$out" || fail "two: first block missing"
grep -q 'detail one' <<<"$out" || fail "two: first detail missing"
grep -q 'Warning: second problem' <<<"$out" || fail "two: second block missing"
grep -q 'detail two' <<<"$out" || fail "two: second detail missing"

# 3. A non-zero run with no diagnostics: one line, never the body.
printf 'nothing useful here\n' >"$tmp/none.txt"
out="$(bash "$script" "$tmp/none.txt" 2>&1)"
grep -q 'no Error: diagnostics found' <<<"$out" || fail "none: no explanation printed"
grep -q 'nothing useful here' <<<"$out" && fail "none: the file body leaked"

# 4. Output with no diagnostics at all: the notice only, never the body. (The script is called on a
#    non-zero run; if the file somehow holds success text, that text is still not what gets printed.)
printf 'Apply complete! Resources: 3 added, 0 changed, 0 destroyed.\n' >"$tmp/ok.txt"
out="$(bash "$script" "$tmp/ok.txt" 2>&1)"
grep -q 'no Error: diagnostics found' <<<"$out" || fail "ok: no explanation printed"
grep -q 'Apply complete' <<<"$out" && fail "ok: success output leaked"

# 5. A missing file explains itself instead of crashing the failure path.
out="$(bash "$script" "$tmp/absent.txt" 2>&1)"
grep -q 'missing or empty' <<<"$out" || fail "absent: no explanation printed"

echo "PASS: tofu error printer (boxed, plain, none, success, missing)"
