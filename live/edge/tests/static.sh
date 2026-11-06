#!/bin/sh
# Static guard for live/edge — plan-free (pure grep, no credentials, runs anywhere and in CI).
#
# 2026-11-06: the first Gateway L4 policies used `identity.groups.id == "<object id>"` and the API
# rejected every one with
#   400 Filter parsing error (1:20): identity.groups.id == "<id>"
#       ^^ cannot perform this operation on type Array(Bytes)
# The selector is an ARRAY of the user's group object ids, so it is only ever tested with the set form
# `any(identity.groups.id[*] in {"<id>"})` — the form live/edge/warp.tf has always used for its device
# profile match. OpenTofu validates neither: the string is opaque until Cloudflare parses it.
set -eu
cd "$(dirname "$0")/.."

fail() {
	printf 'FAIL: %s\n' "$1"
	exit 1
}

# Every mention of the selector in this stack must be the set form. Comments that explain the rule are
# allowed (they carry no code); a `#` inside the line is not enough on its own, so code lines are judged
# by what follows `identity.groups.id`.
hits=$(grep -rn 'identity\.groups\.id' --include='*.tf' . | grep -v 'in {' || true)
while IFS= read -r line; do
	[ -n "$line" ] || continue
	case $line in
		*'identity.groups.id` is an ARRAY'*) ;;   # the explanation in coder.tf's header
		*'# '*|*'#'*) ;;                          # prose
		*) fail "identity.groups.id must use the array form 'any(identity.groups.id[*] in {\"...\"})': $line" ;;
	esac
done <<EOF
$hits
EOF

# Belt and braces: no scalar or indexed comparison, in code or comment.
bad=$(grep -rnE 'identity\.groups\.id(\[\*\])?[[:space:]]*(==|!=)' --include='*.tf' . || true)
[ -z "$bad" ] || fail "identity.groups.id compared with ==/!= — it is an Array(Bytes); use any(...[*] in {...}):
$bad"

echo "PASS: static guard (live/edge wirefilter identity selectors)"
