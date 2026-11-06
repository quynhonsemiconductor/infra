#!/bin/sh
# Static guard for live/observability-alerting — plan-free (grep only).
#
# The 2026-11-06 audit round found ONE routing bug four times: the notification
# policy matches env="prod", but new rules kept being written with
# env="production". Grafana matches labels EXACTLY, so a critical alert with the
# wrong value silently skips the Teams child and nobody pages. This guard makes
# that class of typo a CI failure instead of an incident.
#
# Rules:
#   1. "production"/"development" may appear only in comments (prose), never in
#      an HCL string.
#   2. The notification policy must still carry an env=prod matcher.
set -eu
cd "$(dirname "$0")/.."

fail() {
	printf 'FAIL: %s\n' "$1"
	exit 1
}

# Strip `#`-comments before searching: prose may say "production" (the old
# name), code may not.
code() { sed 's/#.*//' "$1"; }

for f in *.tf; do
	code "$f" | grep -qE '"(production|development)"' &&
		fail "$f: \"production\"/\"development\" in code — the policy matches \"prod\"/\"dev\""
done

code main.tf | grep -q 'label = "env"' ||
	fail 'main.tf: notification policy has no env matcher'
code main.tf | grep -q 'value = "prod"' ||
	fail 'main.tf: notification policy has no env=prod matcher'

echo 'PASS: observability-alerting static guard'
