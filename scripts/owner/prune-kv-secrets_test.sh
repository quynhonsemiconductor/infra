#!/usr/bin/env bash
# Offline test for scripts/owner/prune-kv-secrets.sh. Stub `az` on PATH; fake
# infra and gitops trees. Proves:
#   - a code/config reference BLOCKS every deletion (exit 1, no az call);
#   - a comment-only or docs-only mention does NOT block;
#   - --apply deletes exactly the proven candidates, and only `secret delete`
#     is ever called (the proof must never read a secret value);
#   - the dry run prints the commands and calls nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/owner/prune-kv-secrets.sh"
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/prune-kv-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; mkdir -p "$BIN"
LOG="$T/az.log"; : >"$LOG"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

cat >"$BIN/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AZ_LOG:?}"
case "$*" in
	"keyvault secret delete --vault-name "*" --name "*" --only-show-errors -o none") ;;
	*) echo "unexpected az call: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$BIN/az"

trees() { # trees: fresh empty trees with one harmless file each
	rm -rf "$T/infra" "$T/gitops"; mkdir -p "$T/infra/live/x" "$T/gitops/values"
	: >"$LOG"
	echo 'resource "null_resource" "x" {}' >"$T/infra/live/x/main.tf"
	echo 'env: dev' >"$T/gitops/values/x.yaml"
}
run() { PATH="$BIN:$PATH" AZ_LOG="$LOG" bash "$SCRIPT" --infra "$T/infra" --gitops "$T/gitops" "$@"; }

# 1. clean trees: all three proven, dry run lists them, az is never called
trees
out=$(run) || { printf '%s\n' "$out"; fail "clean dry run exited non-zero"; }
printf '%s\n' "$out" | grep -q '^OK       kv-qnsc-dev/kb-dev-app' || fail "kb-dev-app not proven"
printf '%s\n' "$out" | grep -q '^OK       kv-qnsc-prod/rova-prod-app' || fail "rova-prod-app not proven"
printf '%s\n' "$out" | grep -q '^OK       kv-qnsc-admin/platform-cnpg-ca-dev' || fail "cnpg ca not proven"
printf '%s\n' "$out" | grep -q 'az keyvault secret delete --vault-name kv-qnsc-dev --name kb-dev-app' || fail "dry run does not print the delete"
[ ! -s "$LOG" ] || fail "dry run called az"
pass "clean dry run"

# 2. a comment-only mention does not block; a code reference does
trees
printf '# the retired bundle kb-dev-app is gone\n' >"$T/gitops/values/notes.yaml"
out=$(run) || { printf '%s\n' "$out"; fail "comment-only mention blocked"; }
printf '%s\n' "$out" | grep -q 'hit .*notes.yaml.*:comment:' || fail "comment hit not classified"
printf '%s\n' "$out" | grep -q '^OK       kv-qnsc-dev/kb-dev-app' || fail "comment mention blocked the candidate"
pass "comment-only mention"

trees
printf 'secretKey: rova-prod-app\n' >"$T/gitops/values/consumer.yaml"
if out=$(run 2>&1); then printf '%s\n' "$out"; fail "code reference did not block"; fi
printf '%s\n' "$out" | grep -q '^BLOCKED  kv-qnsc-prod/rova-prod-app' || { printf '%s\n' "$out"; fail "reference not reported as BLOCKED"; }
printf '%s\n' "$out" | grep -q 'STOP: at least one candidate is referenced; nothing was deleted.' || fail "no STOP on a reference"
[ ! -s "$LOG" ] || fail "a blocked run called az"
pass "code reference blocks"

# a trailing `# name` on a code line is still a comment for that name
trees
printf 'enabled: true # rova-prod-app retired\n' >"$T/gitops/values/trailing.yaml"
out=$(run) || { printf '%s\n' "$out"; fail "trailing comment blocked"; }
printf '%s\n' "$out" | grep -q '^OK       kv-qnsc-prod/rova-prod-app' || fail "trailing comment not treated as a comment"
pass "trailing comment"

# 3. --apply: three deletes, nothing else
trees
run --apply >/dev/null || fail "--apply exited non-zero"
[ "$(wc -l <"$LOG" | tr -d ' ')" = 3 ] || { cat "$LOG"; fail "expected exactly 3 az calls"; }
grep -qx 'keyvault secret delete --vault-name kv-qnsc-dev --name kb-dev-app --only-show-errors -o none' "$LOG" || fail "kb-dev-app delete missing"
grep -qx 'keyvault secret delete --vault-name kv-qnsc-prod --name rova-prod-app --only-show-errors -o none' "$LOG" || fail "rova-prod-app delete missing"
grep -qx 'keyvault secret delete --vault-name kv-qnsc-admin --name platform-cnpg-ca-dev --only-show-errors -o none' "$LOG" || fail "cnpg ca delete missing"
pass "--apply deletes the proven candidates"

# 4. --apply never deletes when ANY candidate is referenced
trees
printf 'env: rova-prod-app\n' >"$T/gitops/values/consumer.yaml"
if run --apply >/dev/null 2>&1; then fail "apply with a reference exited zero"; fi
[ ! -s "$LOG" ] || { cat "$LOG"; fail "apply with a reference called az"; }
pass "apply refused on a reference"

echo "PASS: prune-kv-secrets"
