#!/usr/bin/env bash
# Offline tests for bootstrap-state.sh. A stub `az` on PATH logs every call and
# answers from fixtures, so no subscription is touched. Checks: the happy path
# passes and assigns the backend role exactly once, a re-run grants nothing,
# and a wrong storage setting / missing container / missing budget / broken
# data-protection each fail with a non-zero exit. A PASS here must fail on
# broken input.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bootstrap-state.sh"
T="$(mktemp -d)"
[[ -n "${KEEP_TEST_DIR:-}" ]] || trap 'rm -rf "$T"' EXIT
LOG="$T/calls.log"
mkdir -p "$T/bin"

STORAGE_ID='/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-qnsc-platform/providers/Microsoft.Storage/storageAccounts/stqnsctfstate'

cat >"$T/bin/az" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$LOG"
if [[ "\$1 \$2" == "account show" ]]; then
  echo '{"id":"00000000-0000-0000-0000-000000000000","name":"stub-subscription"}'
  exit 0
fi
if [[ "\$1 \$2 \$3" == "storage account show" ]]; then
  # STUB_BAD/STUB_GOOD arrive through the environment: the fixture is read
  # with one value rewritten, so each must_fail flips exactly one field.
  sed "s/\${STUB_BAD:-NONE}/\${STUB_GOOD:-NONE}/" <<'JSON'
{"id":"$STORAGE_ID","sku":{"name":"Standard_LRS"},"kind":"StorageV2",
 "enableHttpsTrafficOnly":true,"minimumTlsVersion":"TLS1_2",
 "allowSharedKeyAccess":false,"publicNetworkAccess":"Enabled"}
JSON
  exit 0
fi
if [[ "\$1 \$2 \$3 \$4" == "storage account blob-service-properties show" ]]; then
  # the data-protection fields live on the blob service, not the account
  sed "s/\${STUB_BAD:-NONE}/\${STUB_GOOD:-NONE}/" <<'JSON'
{"isVersioningEnabled":true,
 "deleteRetentionPolicy":{"enabled":true,"days":30,"allowPermanentDelete":false},
 "containerDeleteRetentionPolicy":{"enabled":true,"days":30}}
JSON
  exit 0
fi
if [[ "\$1 \$2 \$3" == "role assignment list" ]]; then
  # the script queries '[0].id' -o tsv: empty array prints nothing
  if [[ "\${STUB_HAS_ROLE:-}" == "1" ]]; then
    echo 'assignment-1'
  fi
  exit 0
fi
if [[ "\$1 \$2 \$3" == "role assignment create" ]]; then
  echo '{"id":"assignment-2"}'
  exit 0
fi
if [[ "\$1 \$2 \$3" == "storage container exists" ]]; then
  # tsv output of --query exists: az prints booleans capitalised
  if [[ "\${STUB_CONTAINER:-}" == "false" ]]; then
    echo 'False'
  else
    echo 'True'
  fi
  exit 0
fi
if [[ "\$1 \$2 \$3" == "consumption budget show" ]]; then
  if [[ "\${STUB_BUDGET:-}" == "missing" ]]; then
    exit 1
  fi
  echo '{"name":"qnsc-platform-monthly","timePeriod":{"startDate":"2026-10-01T00:00:00Z","endDate":"2028-09-30T00:00:00Z"}}'
  exit 0
fi
echo "stub az: unexpected call: \$*" >&2
exit 42
STUB
chmod +x "$T/bin/az"
export PATH="$T/bin:$PATH"

# ── happy path ───────────────────────────────────────────────────────────────
: >"$LOG"
OUT="$("$SCRIPT" operator@qnsc.vn)"
echo "$OUT" | grep -q '^READY\.' || { echo "FAIL: no READY line"; exit 1; }
grep -q '^ok: min TLS: 1.2$' <<<"$OUT" || { echo "FAIL: TLS check missing from output"; exit 1; }

grep -q 'budget_period_start=2026-10-01T00:00:00Z' <<<"$OUT" && grep -q 'budget_period_end=2028-09-30T00:00:00Z' <<<"$OUT" || { echo "FAIL: READY output lacks the live RFC3339 budget dates"; exit 1; }

CREATE_CALLS="$(grep -c '^role assignment create' "$LOG" || true)"
[[ "$CREATE_CALLS" == "1" ]] || { echo "FAIL: expected exactly 1 role create, got $CREATE_CALLS"; exit 1; }
grep -q '^storage account blob-service-properties show ' "$LOG" || { echo "FAIL: data protection not read via blob-service-properties"; exit 1; }
grep -q -- '--auth-mode login' "$LOG" || { echo "FAIL: container check did not use --auth-mode login"; exit 1; }
grep -q -- '--role Storage Blob Data Contributor' "$LOG" || { echo "FAIL: role grant used the wrong role"; exit 1; }
echo "ok: happy path passes, role assigned once, container checked over Entra auth"

# ── idempotent re-run: role already present → no create call ────────────────
: >"$LOG"
OUT2="$(STUB_HAS_ROLE=1 "$SCRIPT" operator@qnsc.vn)"
grep -q '^READY\.' <<<"$OUT2"
[[ -z "$(grep '^role assignment create' "$LOG" || true)" ]] || { echo "FAIL: re-run assigned the role again"; exit 1; }
echo "ok: re-run with the role present assigns nothing (idempotent)"

# ── broken input must fail ──────────────────────────────────────────────────
# The stub reads STUB_BAD/STUB_GOOD at run time (it inherits the environment)
# and rewrites one value in the storage-account fixture before answering.
# Each case flips exactly one field; the script must exit non-zero.
must_fail() { # must_fail <label> [ENV=v ...]
  local label="$1"; shift
  if env "$@" "$SCRIPT" operator@qnsc.vn >/dev/null 2>"$T/err"; then
    echo "FAIL: $label — script PASSED on broken input"; exit 1
  fi
  echo "ok: $label fails: $(tail -1 "$T/err")"
}

must_fail "wrong min TLS" \
  STUB_BAD='"minimumTlsVersion":"TLS1_2"' STUB_GOOD='"minimumTlsVersion":"TLS1_0"'
must_fail "wrong replication" \
  STUB_BAD='Standard_LRS' STUB_GOOD='Standard_GRS'
must_fail "shared keys enabled" \
  STUB_BAD='"allowSharedKeyAccess":false' STUB_GOOD='"allowSharedKeyAccess":true'
must_fail "versioning off" \
  STUB_BAD='"isVersioningEnabled":true' STUB_GOOD='"isVersioningEnabled":false'
must_fail "soft delete 7 days" \
  STUB_BAD='"days":30' STUB_GOOD='"days":7'
must_fail "container soft delete 7 days" \
  STUB_BAD='"containerDeleteRetentionPolicy":{"enabled":true,"days":30}' STUB_GOOD='"containerDeleteRetentionPolicy":{"enabled":true,"days":7}'
must_fail "container missing" STUB_CONTAINER=false
must_fail "budget missing" STUB_BUDGET=missing

echo "ALL PASS"
