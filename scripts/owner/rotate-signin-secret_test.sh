#!/usr/bin/env bash
# Offline test for scripts/rotate-signin-secret.sh.
#
# Stubs `az` and `date` on PATH — no cloud call, no real credential. The
# fixtures are the REAL command output shapes:
#   az ad app credential reset -o json : {appId, password, tenant} — NO keyId
#   az ad app credential list  -o json : passwordCredentials[] with keyId/displayName
# Every broken input must stop the script; a PASS must fail when the fixture
# breaks (case C/D below).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/rotate-signin-secret.sh"
[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rotate-signin-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/az.log"; VAULT="$TMP/vault.txt"; OUT="$TMP/out.txt"; ERR="$TMP/err.txt"
PASSWORD='fixture-password-123'
APP_OBJECT='11111111-1111-4111-8111-111111111111'
APP_CLIENT='33333333-3333-4333-8333-333333333333'
KEYID='22222222-2222-4222-8222-222222222222'

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

cat >"$BIN/date" <<'EOF'
#!/usr/bin/env bash
case "$*" in
	"-u +%Y-%m-%dT%H-%M-%SZ") printf '2026-11-04T05-00-00Z\n' ;;
	"-u +%Y-%m-%d") printf '2026-11-04\n' ;;
	"-v+6m +%Y-%m-%dT00:00:00Z") printf '2027-05-04T00:00:00Z\n' ;;
	*) exec /bin/date "$@" ;;
esac
EOF

cat >"$BIN/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AZ_LOG:?}"
case "$1 $2 $3 $4" in
	"ad app credential reset"*) cat "${AZ_RESET:?}" ;;
	"ad app credential list"*) cat "${AZ_LIST:?}" ;;
	"keyvault secret set"*)
		# The password arrives on stdin; store it only in the test's temp dir.
		[[ "$*" == *"--file /dev/stdin"* ]] || { echo "vault write without stdin" >&2; exit 1; }
		cat >"${AZ_VAULT:?}"
		;;
	*) echo "unexpected az call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$BIN/date" "$BIN/az"

# Real reset shape: appId/password/tenant, and deliberately NO keyId.
RESET_OK="$TMP/reset-ok.json"
printf '{"appId":"%s","password":"%s","tenant":"tenant-id"}\n' "$APP_CLIENT" "$PASSWORD" >"$RESET_OK"
RESET_NO_PASSWORD="$TMP/reset-broken.json"
printf '{"appId":"%s","tenant":"tenant-id"}\n' "$APP_CLIENT" >"$RESET_NO_PASSWORD"
LIST_OK="$TMP/list-ok.json"
printf '[{"customKeyIdentifier":null,"displayName":"rotated-2026-11-04T05-00-00Z","endDateTime":"2027-05-04T00:00:00Z","hint":"abc","keyId":"%s","startDateTime":"2026-11-04T05:00:00Z","type":"Password"}]\n' "$KEYID" >"$LIST_OK"
LIST_EMPTY="$TMP/list-empty.json"
printf '[]\n' >"$LIST_EMPTY"

run() { # run <reset-fixture> <list-fixture> <args...>; sets CODE
	: >"$LOG"; rm -f "$VAULT"; : >"$OUT"; : >"$ERR"
	set +e
	AZ_LOG="$LOG" AZ_RESET="$1" AZ_LIST="$2" AZ_VAULT="$VAULT" \
		PATH="$BIN:$PATH" bash "$SCRIPT" "${@:3}" >"$OUT" 2>"$ERR"
	CODE=$?
	set -e
	return "$CODE"
}

# A. azuread state form: /applications/<object id> is accepted and stripped.
if ! run "$RESET_OK" "$LIST_OK" "/applications/$APP_OBJECT" kv-qnsc-prod opshub-prod-entra-client-secret; then
	cat "$ERR" >&2
	fail "A: expected success, got exit $CODE"
fi
[[ $CODE -eq 0 ]] || fail "A: exit $CODE"
[[ "$(head -1 "$LOG")" == *"--id $APP_OBJECT"* ]] || fail "A: /applications/ prefix was not stripped"
[[ "$(cat "$VAULT")" == "$PASSWORD" ]] || fail "A: vault did not receive the password via stdin"
if grep -q "$PASSWORD" "$OUT" "$ERR"; then fail "A: the password was printed"; fi
grep -q "$KEYID" "$OUT" || fail "A: the new keyId was not reported"
pass "A: strips /applications/, writes the vault first, reports the keyId by name"

# B. appId form passes through unchanged.
if ! run "$RESET_OK" "$LIST_OK" "$APP_CLIENT" kv-qnsc-prod kb-prod-entra-client-secret; then
	cat "$ERR" >&2
	fail "B: expected success, got exit $CODE"
fi
[[ "$(head -1 "$LOG")" == *"--id $APP_CLIENT"* ]] || fail "B: appId was not passed through"
pass "B: appId accepted unchanged"

# C. Broken reset output (no password): must stop, must NOT write the vault.
if run "$RESET_NO_PASSWORD" "$LIST_OK" "$APP_CLIENT" kv-qnsc-prod x; then
	fail "C: a reset output without a password was accepted"
fi
[[ $CODE -ne 0 ]] || fail "C: expected non-zero exit"
[[ ! -e "$VAULT" ]] || fail "C: the vault was written despite the missing password"
pass "C: missing password stops before the vault write"

# D. keyId lookup empty: the secret is already safe, so warn and succeed.
if ! run "$RESET_OK" "$LIST_EMPTY" "$APP_CLIENT" kv-qnsc-prod x; then
	cat "$ERR" >&2
	fail "D: expected success with a warning, got exit $CODE"
fi
[[ "$(cat "$VAULT")" == "$PASSWORD" ]] || fail "D: vault did not receive the password"
grep -q "WARN" "$ERR" || fail "D: no warning when the keyId lookup came back empty"
pass "D: empty keyId lookup warns without failing after a good vault write"

echo "PASS: rotate-signin-secret"
