#!/usr/bin/env bash
# Offline tests for aws-orphan-audit.sh. A stub `aws` on PATH logs every call and answers from fixtures, so no
# account is touched. Checks: the report is written, no call is a write or returns secret material, delete
# commands come out commented, a wrong account is refused, and output inside a git repository is refused.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/aws-orphan-audit.sh"
T="$(mktemp -d)"
[[ -n "${KEEP_TEST_DIR:-}" ]] || trap 'rm -rf "$T"' EXIT
FIX="$T/fixtures"
LOG="$T/calls.log"
mkdir -p "$T/bin" "$FIX"
export FIX LOG

cat >"$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG"
if [[ "$1 $2" == "sts get-caller-identity" ]]; then
  echo "${STUB_ACCOUNT:-608983206583}"
  exit 0
fi
f="$FIX/$1-$2.json"
if [[ -f "$f" ]]; then cat "$f"; else echo '{}'; fi
STUB
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH"

cat >"$FIX/iam-list-roles.json" <<'JSON'
{"Roles": [
  {"RoleName": "eks-spike-node", "Arn": "arn:aws:iam::608983206583:role/eks-spike-node", "RoleLastUsed": {"LastUsedDate": "2026-10-01T00:00:00+00:00"}},
  {"RoleName": "rova-api-task", "Arn": "arn:aws:iam::608983206583:role/rova-api-task", "RoleLastUsed": {}}
]}
JSON
cat >"$FIX/ec2-describe-volumes.json" <<'JSON'
{"Volumes": [
  {"VolumeId": "vol-0aaa", "State": "available", "Size": 100, "CreateTime": "2026-08-01T10:00:00.000Z", "Tags": []},
  {"VolumeId": "vol-0bbb", "State": "in-use", "Size": 20, "CreateTime": "2026-08-01T10:00:00.000Z", "Tags": [{"Key": "kubernetes.io/cluster/spike", "Value": "owned"}]}
]}
JSON
cat >"$FIX/secretsmanager-list-secrets.json" <<'JSON'
{"SecretList": [
  {"Name": "opshub/prod/app", "LastAccessedDate": "2026-10-17T00:00:00+00:00", "LastChangedDate": "2026-10-01T00:00:00+00:00"},
  {"Name": "legacy/sqlserver/conn", "LastChangedDate": "2026-03-01T00:00:00+00:00"}
]}
JSON
cat >"$FIX/ecr-describe-repositories.json" <<'JSON'
{"repositories": [{"repositoryName": "charts/qnsc-service"}]}
JSON
cat >"$FIX/ecr-describe-images.json" <<'JSON'
{"imageDetails": [{"imagePushedAt": "2026-03-01T00:00:00+00:00", "imageSizeInBytes": 2147483648}]}
JSON
cat >"$FIX/logs-describe-log-groups.json" <<'JSON'
{"logGroups": [{"logGroupName": "/aws/eks/spike/cluster", "storedBytes": 1073741824}]}
JSON
cat >"$FIX/rds-describe-db-instances.json" <<'JSON'
{"DBInstances": [{"DBInstanceIdentifier": "opshub-prod-db", "DBInstanceClass": "db.t4g.micro", "AllocatedStorage": 20, "DBInstanceStatus": "available", "Engine": "postgres"}]}
JSON
cat >"$FIX/kms-list-keys.json" <<'JSON'
{"Keys": [{"KeyId": "1111aaaa-0000-0000-0000-000000000000"}]}
JSON
cat >"$FIX/kms-describe-key.json" <<'JSON'
{"KeyMetadata": {"KeyId": "1111aaaa-0000-0000-0000-000000000000", "KeyManager": "CUSTOMER", "KeyState": "Enabled"}}
JSON
cat >"$FIX/kms-list-aliases.json" <<'JSON'
{"Aliases": [{"AliasName": "alias/rova-develop", "TargetKeyId": "2222bbbb-0000-0000-0000-000000000000"}]}
JSON
cat >"$FIX/elbv2-describe-load-balancers.json" <<'JSON'
{"LoadBalancers": [{"LoadBalancerName": "opshub-prod-alb", "LoadBalancerArn": "arn:aws:elasticloadbalancing:ap-southeast-1:608983206583:loadbalancer/app/opshub-prod-alb/abc123"}]}
JSON
cat >"$FIX/rds-describe-db-snapshots.json" <<'JSON'
{"DBSnapshots": [{"DBSnapshotIdentifier": "qnsc-sql-final", "Engine": "sqlserver-se", "SnapshotType": "manual", "SnapshotCreateTime": "2026-02-02T00:00:00+00:00", "AllocatedStorage": 50}]}
JSON

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

REPORT_DIR="$T/out"
run_audit() { : >"$LOG"; bash "$SCRIPT" "$REPORT_DIR" >"$T/stdout.txt" 2>"$T/stderr.txt"; }

# 1. happy path: exit 0, report written, expected findings present
if run_audit; then pass "happy path exits 0"; else fail "happy path exits 0 (stderr: $(cat "$T/stderr.txt"))"; fi
MD="$REPORT_DIR/aws-orphan-audit-$(date +%F).md"
if [[ -n "$MD" ]] && grep -q 'eks-spike-node' "$MD" && grep -q 'qnsc-sql-final' "$MD" && grep -q 'legacy/sqlserver/conn' "$MD"; then
  pass "report names the expected findings"
else
  fail "report names the expected findings"
fi
if grep -q 'last push 2026-03-01' "$MD" && grep -q 'vol-0aaa' "$MD" && [[ "$(grep -c 'vol-0bbb' "$MD")" -eq 2 ]]; then
  pass "ECR and EBS rows right; EKS-tagged volume listed once as a row (plus its command)"
else
  fail "ECR and EBS rows right; EKS-tagged volume listed once as a row (plus its command)"
fi
if [[ "$(grep -c 'legacy/sqlserver/conn' "$MD")" -eq 2 ]]; then
  pass "SQL Server secret listed once as a row (plus its command), not again in section 7"
else
  fail "SQL Server secret listed once as a row (plus its command), not again in section 7"
fi
if grep -q 'KMS' "$MD" && grep -q 'enabled customer key with no alias' "$MD" && grep -q 'opshub-prod-db' "$MD" && grep -q 'max DatabaseConnections in 30 days: 0' "$MD" && grep -q 'opshub-prod-alb' "$MD"; then
  pass "KMS unaliased key, opshub-prod DB and ALB rows present"
else
  fail "KMS unaliased key, opshub-prod DB and ALB rows present"
fi

# 2. read-only: every call is describe-, list- or get-, and none returns secret material
if [[ -s "$LOG" ]] && ! awk '{ print $2 }' "$LOG" | grep -qvE '^(describe|list|get)-' &&
  ! grep -qE 'get-secret-value|get-parameter|get-authorization-token|get-login-password' "$LOG"; then
  pass "all calls are reads and none returns secret material ($(wc -l <"$LOG" | tr -d ' ') calls)"
else
  fail "all calls are reads and none returns secret material"
fi
if grep -qE ' (create|delete|put|update|modify|release|deregister|schedule|cancel|tag|attach|detach|register|revoke|authorize|run|start|stop|terminate|reboot|enable|disable|set|restore|copy)-' "$LOG"; then
  fail "no write call in the log"
else
  pass "no write call in the log"
fi

# 3. delete commands are commented out
if grep -qE '^aws ' "$MD"; then fail "every command in the report is commented out"; else pass "every command in the report is commented out"; fi
if grep -q '^# aws iam delete-role' "$MD"; then pass "delete-role command is present, commented"; else fail "delete-role command is present, commented"; fi

# 4. a wrong account is refused before anything else runs
if STUB_ACCOUNT=111111111111 run_audit; then
  fail "wrong account refused"
elif grep -q 'expected 608983206583' "$T/stderr.txt"; then
  pass "wrong account refused"
else
  fail "wrong account refused (stderr: $(cat "$T/stderr.txt"))"
fi

# 5. output inside a git repository is refused
REPO="$T/some-repo"
mkdir -p "$REPO" && git -C "$REPO" init -q
if bash "$SCRIPT" "$REPO/out" >/dev/null 2>"$T/stderr.txt"; then
  fail "output inside a git repository refused"
elif grep -q 'inside a git repository' "$T/stderr.txt"; then
  pass "output inside a git repository refused"
else
  fail "output inside a git repository refused"
fi

echo "---"
if [[ "$fails" -eq 0 ]]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
