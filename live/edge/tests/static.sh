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

# 2. Identity selectors live in the policy's `identity` attribute, NEVER inside `traffic`: the API
#    rejects that with 400 code 2091 "expression contains fields that are not allowed for rule-type
#    traffic" (2026-11-06, the same resource's third failure). The `traffic` and `identity` attributes
#    are separate wirefilter expressions in the Gateway rule (Cloudflare API reference, Gateway rules:
#    traffic / identity / device_posture).
in_traffic=$(grep -rnE 'traffic[[:space:]]*=.*identity\.' --include='*.tf' . || true)
[ -z "$in_traffic" ] || fail "an identity selector is inside a traffic expression — move it to the policy's identity attribute:
$in_traffic"

# 2b. Selector TYPES differ inside one policy: `net.dst.ip` is a scalar Ip and must never be indexed —
#     the API answers `cannot access index MapEach for type Ip` (2026-11-06). identity.groups.id and
#     net.sni.domains ARE arrays and keep their `[*]`.
dstip=$(grep -rnE 'net\.dst\.ip\[\*\]' --include='*.tf' . | grep -vE ':[[:space:]]*#' || true)
[ -z "$dstip" ] || fail "net.dst.ip is a scalar Ip — use 'net.dst.ip in {...}', not an indexed form:
$dstip"

# 3. Belt and braces: no scalar or indexed comparison, in code or comment.
bad=$(grep -rnE 'identity\.groups\.id(\[\*\])?[[:space:]]*(==|!=)' --include='*.tf' . || true)
[ -z "$bad" ] || fail "identity.groups.id compared with ==/!= — it is an Array(Bytes); use any(...[*] in {...}):
$bad"

# 4. Laptop phase 0a: the staff WARP profile must be LOCKED (endpoint.tf). A profile that can be
#    switched off is not an enforcement point; the three fields are the whole "cannot turn it off".
for field in 'switch_locked[[:space:]]*=[[:space:]]*true' \
             'allowed_to_leave[[:space:]]*=[[:space:]]*false' \
             'allow_mode_switch[[:space:]]*=[[:space:]]*false'; do
	grep -qE "^[[:space:]]*$field\$" endpoint.tf ||
		fail "the staff device profile must set $field (live/edge/endpoint.tf)"
done

# 5. Every Gateway policy precedence in this stack is unique. Cloudflare requires it, and a
#    duplicate makes one rule silently shadow the other. Comments are ignored (the line starts
#    with the attribute).
precs=$(awk '
	/^resource "cloudflare_zero_trust_gateway_policy"/ { inb = 1; next }
	inb && /^}/ { inb = 0 }
	inb && match($0, /precedence[[:space:]]*=[[:space:]]*[0-9]+/) {
		line = substr($0, RSTART, RLENGTH); sub(/.*=[[:space:]]*/, "", line); print line
	}
' ./*.tf | sort -n)
dupes=$(printf '%s\n' "$precs" | uniq -d)
[ -z "$dupes" ] || fail "two Gateway policies share a precedence: $dupes"
[ -n "$precs" ] || fail "no Gateway policy precedence found — the parser in static.sh is stale"

# 6. Every DNS policy carries an identity expression, EXCEPT the all-identities security block.
#    A staff/content/app rule without `identity` would silently apply to the whole company.
noident=$(awk '
	/^resource "cloudflare_zero_trust_gateway_policy"/ { inb = 1; name = ""; dns = 0; ident = 0; next }
	inb && /^}/ {
		if (dns && !ident && name != "security-block-dns") print name
		inb = 0
	}
	inb && /^  name[[:space:]]*=/ { n = $0; sub(/.*=[[:space:]]*"/, "", n); sub(/".*/, "", n); name = n }
	inb && /^  filters[[:space:]]*=/ && /"dns"/ { dns = 1 }
	inb && /^  identity[[:space:]]*=/ { ident = 1 }
' endpoint.tf)
[ -z "$noident" ] || fail "DNS policy without an identity expression (only security-block-dns may omit it): $noident"

# 7. Phase 0a adds NO HTTP filtering and NO TLS inspection: this stack must not declare an http
#    filter, and must not touch the account's root-CA installation (a phase 0c decision). Every
#    root_certificate_installation_enabled line must be the pinned read from the account.
httpf=$(grep -rnE 'filters[[:space:]]*=.*"http"' --include='*.tf' . || true)
[ -z "$httpf" ] || fail "phase 0a allows no HTTP/TLS inspection — found an http filter:
$httpf"
rootca=$(grep -rn 'root_certificate_installation_enabled' --include='*.tf' . | grep -v '= data\.cloudflare_zero_trust_device_settings\.current\.root_certificate_installation_enabled' || true)
[ -z "$rootca" ] || fail "root_certificate_installation_enabled must only be pinned from the data source in warp.tf:
$rootca"

echo "PASS: static guard (live/edge wirefilter identity selectors)"
