#!/usr/bin/env bash
# Offline tests for aws-orphan-audit.sh. A stub `aws` on PATH logs every call and answers from fixtures, so no
# account is touched. Checks: the report is written, no call is a write or returns secret material, delete
# commands come out commented, a wrong account is refused, output inside a git repository is refused, and the
# date helper reads every timestamp shape the CLI can print (Z, +00:00, local offsets, fractional seconds).
# Run in a non-UTC zone too (TZ=Asia/Bangkok) so local-offset output is the normal case.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/aws-orphan-audit.sh"
LIB="$HERE/aws-audit-lib.jq"
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

# A recent last-access time written the way the CLI prints it on a machine in UTC+07:00.
RECENT="$(date -u -v-5d +%Y-%m-%dT10:00:00+07:00 2>/dev/null || date -u -d '5 days ago' +%Y-%m-%dT10:00:00+07:00)"

cat >"$FIX/iam-list-roles.json" <<'JSON'
{"Roles": [
  {"RoleName": "eks-spike-node", "Arn": "arn:aws:iam::608983206583:role/eks-spike-node", "RoleLastUsed": {"LastUsedDate": "2026-10-01T00:00:00+00:00"}},
  {"RoleName": "rova-api-task", "Arn": "arn:aws:iam::608983206583:role/rova-api-task", "RoleLastUsed": {}}
]}
JSON
# CreateTime at 03:00 on the 2nd in +07:00 is still the 1st in UTC: a naive date slice would print the 2nd.
cat >"$FIX/ec2-describe-volumes.json" <<'JSON'
{"Volumes": [
  {"VolumeId": "vol-0aaa", "State": "available", "Size": 100, "CreateTime": "2026-08-02T03:00:00+07:00", "Tags": []},
  {"VolumeId": "vol-0bbb", "State": "in-use", "Size": 20, "CreateTime": "2026-08-01T10:00:00.123456-05:00", "Tags": [{"Key": "kubernetes.io/cluster/spike", "Value": "owned"}]}
]}
JSON
cat >"$FIX/ec2-describe-images.json" <<'JSON'
{"Images": [
  {"ImageId": "ami-old-1", "Name": "old-base", "CreationDate": "2026-01-15T05:00:00.000+07:00", "BlockDeviceMappings": [{"Ebs": {"SnapshotId": "snap-ami-1", "VolumeSize": 8}}]}
]}
JSON
cat >"$FIX/ec2-describe-snapshots.json" <<'JSON'
{"Snapshots": [
  {"SnapshotId": "snap-old-1", "StartTime": "2026-02-01T02:00:00+07:00", "VolumeSize": 30, "Description": "manual copy"},
  {"SnapshotId": "snap-ami-1", "StartTime": "2026-01-15T05:00:00.000Z", "VolumeSize": 8, "Description": "Created by CreateImage(i-1)"}
]}
JSON
cat >"$FIX/secretsmanager-list-secrets.json" <<JSON
{"SecretList": [
  {"Name": "opshub/prod/app", "LastAccessedDate": "$RECENT", "LastChangedDate": "2026-10-01T00:00:00+07:00"},
  {"Name": "legacy/payments/conn", "LastChangedDate": "2026-03-01T00:00:00Z"}
]}
JSON
cat >"$FIX/ecr-describe-repositories.json" <<'JSON'
{"repositories": [{"repositoryName": "charts/qnsc-service"}]}
JSON
# Pushed 06:59 on the 1st in +07:00 with fractional seconds: 2026-02-28 in UTC.
cat >"$FIX/ecr-describe-images.json" <<'JSON'
{"imageDetails": [{"imagePushedAt": "2026-03-01T06:59:00.123+07:00", "imageSizeInBytes": 2147483648}]}
JSON
cat >"$FIX/logs-describe-log-groups.json" <<'JSON'
{"logGroups": [{"logGroupName": "/aws/eks/spike/cluster", "storedBytes": 1073741824}, {"logGroupName": "rova/api", "retentionInDays": 30, "storedBytes": 0}]}
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

# 0. the date helper: every shape the CLI can print, against the UTC epoch it means
ep_check() {
  local got
  got="$(jq -n -r --argjson x "$1" "$(cat "$LIB") \$x | ep | todate" 2>&1 || true)"
  if [[ "$got" == "$2" ]]; then pass "ep $1 -> $2"; else fail "ep $1 -> $got, want $2"; fi
}
ep_check '"2026-10-18T20:02:08+07:00"' 2026-10-18T13:02:08Z
ep_check '"2026-10-18T20:02:08.123456+07:00"' 2026-10-18T13:02:08Z
ep_check '"2026-10-18T10:00:00-05:00"' 2026-10-18T15:00:00Z
ep_check '"2026-10-18T10:00:00-0500"' 2026-10-18T15:00:00Z
ep_check '"2026-03-01T00:00:00+00:00"' 2026-03-01T00:00:00Z
ep_check '"2026-10-17T05:00:00.000Z"' 2026-10-17T05:00:00Z
ep_check '1760000000' 2025-10-09T08:53:20Z

# 1. happy path: exit 0, report written, expected findings present
if run_audit; then pass "happy path exits 0"; else fail "happy path exits 0 (stderr: $(cat "$T/stderr.txt"))"; fi
MD="$REPORT_DIR/aws-orphan-audit-$(date +%F).md"
if [[ -s "$MD" ]] && grep -q 'eks-spike-node' "$MD" && grep -q 'qnsc-sql-final' "$MD" && grep -q 'legacy/payments/conn' "$MD"; then
  pass "report names the expected findings"
else
  fail "report names the expected findings"
fi

# 2. dates come out as the UTC day, even when the CLI printed a local offset
if grep -q 'last push 2026-02-28' "$MD"; then pass "ECR last push read as UTC day (+07:00 input)"; else fail "ECR last push read as UTC day (+07:00 input)"; fi
if grep -q 'created 2026-08-01' "$MD"; then pass "EBS created date read as UTC day (+07:00 input)"; else fail "EBS created date read as UTC day (+07:00 input)"; fi
if grep -q 'created 2026-01-31' "$MD" && grep -q 'AMI created 2026-01-14' "$MD"; then
  pass "snapshot and AMI dates read as UTC day (offset and fractional input)"
else
  fail "snapshot and AMI dates read as UTC day (offset and fractional input)"
fi
if grep -q 'opshub/prod/app' "$MD"; then
  fail "recently accessed secret not reported"
else
  pass "recently accessed secret not reported"
fi
if [[ "$(grep -c 'vol-0bbb' "$MD")" -eq 2 ]]; then pass "EKS-tagged volume listed once as a row (plus its command)"; else fail "EKS-tagged volume listed once as a row (plus its command)"; fi
if [[ "$(grep -c 'legacy/payments/conn' "$MD")" -eq 2 ]]; then
  pass "secret listed once as a row (plus its command)"
else
  fail "secret listed once as a row (plus its command)"
fi
if grep -q 'enabled customer key with no alias' "$MD" && grep -q 'opshub-prod-db' "$MD" && grep -q 'max DatabaseConnections in 30 days: 0' "$MD" && grep -q 'opshub-prod-alb' "$MD"; then
  pass "KMS unaliased key, opshub-prod DB and ALB rows present"
else
  fail "KMS unaliased key, opshub-prod DB and ALB rows present"
fi

# 3. read-only: every call is describe-, list- or get-, and none returns secret material
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

# 4. delete commands are commented out
if grep -qE '^aws ' "$MD"; then fail "every command in the report is commented out"; else pass "every command in the report is commented out"; fi
if grep -q '^# aws iam delete-role' "$MD"; then pass "delete-role command is present, commented"; else fail "delete-role command is present, commented"; fi

# 5. a wrong account is refused before anything else runs
if STUB_ACCOUNT=111111111111 run_audit; then
  fail "wrong account refused"
elif grep -q 'expected 608983206583' "$T/stderr.txt"; then
  pass "wrong account refused"
else
  fail "wrong account refused (stderr: $(cat "$T/stderr.txt"))"
fi

# 6. output inside a git repository is refused
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
