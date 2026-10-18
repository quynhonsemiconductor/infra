#!/usr/bin/env bash
# READ-ONLY inventory of AWS leftovers in account 608983206583, region ap-southeast-1.
# Writes one markdown report outside any git repository. Prints no secret values.
#
#   scripts/owner/aws-orphan-audit.sh [OUTDIR]     # default: ~/aws-orphan-audit-<date>/
#   STALE_DAYS=90 scripts/owner/aws-orphan-audit.sh  # "old" cut-off for snapshots, AMIs, logs, secrets, ECR
#
# Every AWS call goes through A(), the only call site. A names the profile and region and runs only describe-,
# list- and get- operations, never the ones that return secret material. The script changes nothing in AWS.
# Delete commands in the report are commented out; the owner reviews each one and runs it in their own terminal.
# Cost figures are ESTIMATES from the RATE_* assumptions below. Check them against AWS Pricing and the bill first.
# Not covered: other regions, S3, Route 53, Lambda, KMS last-use (needs CloudTrail). See the limits section.
#
# Needs: aws CLI v2 and jq. Written for the macOS /bin/bash (3.2): no associative arrays, no mapfile.
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROFILE=qnsc-admin
REGION=ap-southeast-1
ACCOUNT=608983206583
STALE_DAYS="${STALE_DAYS:-90}"
P="--profile $PROFILE --region $REGION"

# Monthly USD assumptions for ap-southeast-1 (list price, rounded). Override with env vars when you have the bill.
RATE_EBS_GB="${RATE_EBS_GB:-0.095}"                    # gp3 per GB-month
RATE_SNAP_GB="${RATE_SNAP_GB:-0.055}"                  # EBS and RDS snapshot per GB-month
RATE_ECR_GB="${RATE_ECR_GB:-0.10}"                     # ECR private storage per GB-month
RATE_LOGS_GB="${RATE_LOGS_GB:-0.033}"                  # CloudWatch Logs storage per GB-month
RATE_IPV4="${RATE_IPV4:-3.65}"                         # public IPv4: $0.005 per hour x 730 hours
RATE_SECRET="${RATE_SECRET:-0.40}"                     # Secrets Manager per secret
RATE_KMS="${RATE_KMS:-1.00}"                           # KMS customer managed key
RATE_RDS_GB="${RATE_RDS_GB:-0.131}"                    # RDS gp3 storage per GB-month
RATE_RDS_T4G_MICRO_HR="${RATE_RDS_T4G_MICRO_HR:-0.02}" # db.t4g.micro per hour
RATE_ALB_HR="${RATE_ALB_HR:-0.0225}"                   # Application Load Balancer fixed part per hour

die() { echo "aws-orphan-audit: $*" >&2; exit 2; }
command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# The only AWS call site. Refuses anything that is not a read, and anything that returns secret material.
A() {
  local svc="$1" op="$2"
  shift 2
  case "$op" in
    get-secret-value | get-parameter* | get-authorization-token | get-login-password | get-session-token | get-federation-token)
      die "refusing a call that returns secret material: $svc $op" ;;
    describe-* | list-* | get-*) ;;
    *) die "refusing a call that is not a read: $svc $op" ;;
  esac
  # TZ=UTC makes the CLI print UTC timestamps as well; the jq ep helper handles any offset that still arrives.
  TZ=UTC aws "$svc" "$op" --profile "$PROFILE" --region "$REGION" "$@"
}

OUT="${1:-$HOME/aws-orphan-audit-$(date +%F)}"
d="$OUT"
while [[ ! -d "$d" ]]; do d="$(dirname "$d")"; done
if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "$OUT is inside a git repository; choose a directory outside it (the default is under \$HOME)"
fi
mkdir -p "$OUT"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "Reading only. Profile $PROFILE, region $REGION." >&2
who="$(A sts get-caller-identity --query Account --output text)" ||
  die "not signed in to profile $PROFILE: run aws sso login --profile $PROFILE first"
[[ "$who" == "$ACCOUNT" ]] || die "profile $PROFILE is account $who, expected $ACCOUNT"

MD="$OUT/aws-orphan-audit-$(date +%F).md"
: >"$MD"
out() { printf '%s\n' "$*" >>"$MD"; }
TOTAL=0
add() { TOTAL="$(awk -v a="$TOTAL" -v b="$1" 'BEGIN { printf "%.2f", a + b }')"; }
gb_cost() { awk -v g="$1" -v r="$2" 'BEGIN { printf "%.2f", g * r }'; }
bytes_to_gb() { awk -v b="$1" 'BEGIN { printf "%.3f", b / 1073741824 }'; }
CUTOFF="$(date -u -v-"$STALE_DAYS"d +%s 2>/dev/null || date -u -d "$STALE_DAYS days ago" +%s)"
ago() { date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }

# jq helpers (ep, eks) live in aws-audit-lib.jq so the tests can run the same definitions.
JQ_LIB="$(cat "$HERE/aws-audit-lib.jq")"

SEC=""
ROWS=0
section() {
  SEC="$1"
  ROWS=0
  : >"$T/cmds"
  out ""
  out "## $SEC"
  out ""
  out "| Resource | Why it looks unused (evidence) | Est. USD/mo |"
  out "|---|---|---|"
}
# row RESOURCE EVIDENCE [COST]
row() {
  ROWS=$((ROWS + 1))
  out "| \`$1\` | $2 | ${3:--} |"
  if [[ -n "${3:-}" ]]; then add "$3"; fi
  return 0
}
# cmd TEXT: a delete or fix command, written commented out (text that already starts with # is kept as is)
cmd() {
  case "$1" in
    \#*) printf '%s\n' "$*" >>"$T/cmds" ;;
    *) printf '# %s\n' "$*" >>"$T/cmds" ;;
  esac
}
end_section() {
  if [[ "$ROWS" -eq 0 ]]; then out "_None found._"; fi
  if [[ -s "$T/cmds" ]]; then
    out ""
    out "Commands for this section (all commented out; review each one, then run it yourself):"
    out '```bash'
    cat "$T/cmds" >>"$MD"
    out '```'
  fi
}

out "# AWS orphan audit: account $ACCOUNT, $REGION"
out ""
out "Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/owner/aws-orphan-audit.sh, profile $PROFILE. Read-only: describe, list and get calls only. No secret value is read or printed."
out "\"Old\" means no activity in the last $STALE_DAYS days. Costs are estimates from the RATE_* assumptions in the script, not from the bill."

# ── 1. EKS and Karpenter ───────────────────────────────────────────────────────────────────────────────────────
section "1. EKS and Karpenter leftovers (EKS spike torn down 2026-10-12)"

ROLES="$(A iam list-roles --output json)"
ROLE_ROWS="$(jq -r '.Roles[]? | select(.RoleName | test("eks|karpenter"; "i")) | [.RoleName, (.RoleLastUsed.LastUsedDate // "never")] | @tsv' <<<"$ROLES")"
while IFS=$'\t' read -r name used; do
  [[ -n "$name" ]] || continue
  row "$name" "IAM role name matches eks or karpenter; last used: $used"
  cmd "aws iam delete-role $P --role-name $name   # detach managed and inline policies first"
done <<<"$ROLE_ROWS"

POLICIES="$(A iam list-policies --scope Local --output json)"
POLICY_ROWS="$(jq -r '.Policies[]? | select(.PolicyName | test("eks|karpenter"; "i")) | [.PolicyName, .Arn, (.AttachmentCount | tostring)] | @tsv' <<<"$POLICIES")"
while IFS=$'\t' read -r name arn attached; do
  [[ -n "$name" ]] || continue
  row "$name" "customer policy name matches eks or karpenter; attached to $attached entities"
  cmd "aws iam delete-policy $P --policy-arn $arn   # detach from all entities first"
done <<<"$POLICY_ROWS"

OIDC="$(A iam list-open-id-connect-providers --output json)"
OIDC_ROWS="$(jq -r '.OpenIDConnectProviderList[]?.Arn | select(test("eks|karpenter"; "i"))' <<<"$OIDC")"
while read -r arn; do
  [[ -n "$arn" ]] || continue
  row "$arn" "OIDC provider whose URL names EKS"
  cmd "aws iam delete-open-id-connect-provider $P --open-id-connect-provider-arn $arn"
done <<<"$OIDC_ROWS"

ENIS="$(A ec2 describe-network-interfaces --output json)"
printf '%s' "$ENIS" >"$T/enis.json"
ENI_ROWS="$(jq -r '.NetworkInterfaces[]? | select((.Description // "") | test("EKS|aws-K8S|karpenter|kubernetes"; "i")) | [.NetworkInterfaceId, .Status, (.Description // "-")] | @tsv' <<<"$ENIS")"
while IFS=$'\t' read -r id status desc; do
  [[ -n "$id" ]] || continue
  row "$id" "ENI description names EKS or Kubernetes; status $status; \"$desc\""
  cmd "aws ec2 delete-network-interface $P --network-interface-id $id   # only when status is available"
done <<<"$ENI_ROWS"

SGS="$(A ec2 describe-security-groups --output json)"
SG_ROWS="$(jq -r --slurpfile enis "$T/enis.json" '
  .SecurityGroups[]? | . as $sg
  | select(((.GroupName + " ") + ([.Tags[]?.Key] | join(" "))) | test("eks|karpenter|kubernetes.io/cluster|karpenter.sh"; "i"))
  | [.GroupId, .GroupName, ([$enis[0].NetworkInterfaces[]? | .Groups[]?.GroupId | select(. == $sg.GroupId)] | length | tostring)] | @tsv' <<<"$SGS")"
while IFS=$'\t' read -r id name used_by; do
  [[ -n "$id" ]] || continue
  row "$id ($name)" "security group named or tagged for EKS or Karpenter; attached to $used_by ENIs (0 = unused)"
  cmd "aws ec2 delete-security-group $P --group-id $id"
done <<<"$SG_ROWS"

VOLS="$(A ec2 describe-volumes --output json)"
EKS_VOL_ROWS="$(jq -r "$JQ_LIB"' .Volumes[]? | select(eks) | [.VolumeId, .State, (.Size | tostring)] | @tsv' <<<"$VOLS")"
while IFS=$'\t' read -r id state size; do
  [[ -n "$id" ]] || continue
  row "$id" "EBS volume tagged for EKS or Karpenter; state $state; ${size} GiB" "$(gb_cost "$size" "$RATE_EBS_GB")"
  cmd "aws ec2 delete-volume $P --volume-id $id   # only when state is available; snapshot first if data matters"
done <<<"$EKS_VOL_ROWS"

LT="$(A ec2 describe-launch-templates --output json)"
LT_ROWS="$(jq -r '.LaunchTemplates[]? | select(.LaunchTemplateName | test("eks|karpenter"; "i")) | [.LaunchTemplateId, .LaunchTemplateName, (.CreateTime // "-")] | @tsv' <<<"$LT")"
while IFS=$'\t' read -r id name created; do
  [[ -n "$id" ]] || continue
  row "$id ($name)" "launch template name matches eks or karpenter; created $created"
  cmd "aws ec2 delete-launch-template $P --launch-template-id $id"
done <<<"$LT_ROWS"

EKS_LG="$(A logs describe-log-groups --log-group-name-prefix /aws/eks --output json)"
LG_ROWS="$(jq -r '.logGroups[]? | [.logGroupName, (if .retentionInDays then (.retentionInDays | tostring) else "never" end), ((.storedBytes // 0) | tostring)] | @tsv' <<<"$EKS_LG")"
while IFS=$'\t' read -r name retention bytes; do
  [[ -n "$name" ]] || continue
  row "$name" "EKS log group; retention $retention" "$(gb_cost "$(bytes_to_gb "$bytes")" "$RATE_LOGS_GB")"
  cmd "aws logs delete-log-group $P --log-group-name $name"
done <<<"$LG_ROWS"

DETECTORS="$(A guardduty list-detectors --output json)"
DET_IDS="$(jq -r '.DetectorIds[]?' <<<"$DETECTORS")"
while read -r det; do
  [[ -n "$det" ]] || continue
  DET="$(A guardduty get-detector --detector-id "$det" --output json)"
  GD_ROWS="$(jq -r '.Features[]? | select(.Name | test("EKS|RUNTIME"; "i")) | select(.Status == "ENABLED") | .Name' <<<"$DET")"
  while read -r feat; do
    [[ -n "$feat" ]] || continue
    row "GuardDuty $feat ($det)" "feature still ENABLED; usage-based cost, check the bill; infra manages aws_guardduty_detector_feature"
    cmd "# prefer a change in infra (aws_guardduty_detector_feature), not the console; then re-run this audit"
  done <<<"$GD_ROWS"
done <<<"$DET_IDS"
end_section

# ── 2. SQL Server RDS leftovers ────────────────────────────────────────────────────────────────────────────────
section "2. SQL Server RDS leftovers (the instance is gone)"

DBI="$(A rds describe-db-instances --output json)"
DBI_ROWS="$(jq -r '.DBInstances[]? | select(.Engine | test("sqlserver"; "i")) | [.DBInstanceIdentifier, .DBInstanceStatus] | @tsv' <<<"$DBI")"
while IFS=$'\t' read -r id status; do
  [[ -n "$id" ]] || continue
  row "$id" "SQL Server DB instance still exists; status $status (expected none)"
  cmd "aws rds delete-db-instance $P --db-instance-identifier $id --final-db-snapshot-identifier ${id}-final-$(date +%F)"
done <<<"$DBI_ROWS"

SNAPS="$(A rds describe-db-snapshots --output json)"
SNAP_ROWS="$(jq -r '.DBSnapshots[]? | select(.Engine | test("sqlserver"; "i")) | [.DBSnapshotIdentifier, .SnapshotType, (.SnapshotCreateTime // "-"), ((.AllocatedStorage // 0) | tostring)] | @tsv' <<<"$SNAPS")"
while IFS=$'\t' read -r id type created gib; do
  [[ -n "$id" ]] || continue
  row "$id" "SQL Server snapshot, $type, created $created" "$(gb_cost "$gib" "$RATE_SNAP_GB")"
  if [[ "$type" == manual ]]; then
    cmd "aws rds delete-db-snapshot $P --db-snapshot-identifier $id"
  else
    cmd "# $id is automated: it expires with the retention window and cannot be deleted directly"
  fi
done <<<"$SNAP_ROWS"

OPT="$(A rds describe-option-groups --output json)"
OPT_ROWS="$(jq -r '.OptionGroupsList[]? | select(.EngineName | test("sqlserver"; "i")) | .OptionGroupName' <<<"$OPT")"
while read -r name; do
  [[ -n "$name" ]] || continue
  row "$name" "option group for a SQL Server engine; no instance left to use it"
  cmd "aws rds delete-option-group $P --option-group-name $name"
done <<<"$OPT_ROWS"

PGRP="$(A rds describe-db-parameter-groups --output json)"
PG_ROWS="$(jq -r '.DBParameterGroups[]? | select(.DBParameterGroupFamily | test("sqlserver"; "i")) | .DBParameterGroupName' <<<"$PGRP")"
while read -r name; do
  [[ -n "$name" ]] || continue
  row "$name" "parameter group in a SQL Server family; no instance left to use it"
  cmd "aws rds delete-db-parameter-group $P --db-parameter-group-name $name"
done <<<"$PG_ROWS"

SNGRP="$(A rds describe-db-subnet-groups --output json)"
SNG_ROWS="$(jq -r '.DBSubnetGroups[]? | select((.DBSubnetGroupName + " " + (.DBSubnetGroupDescription // "")) | test("sql|mssql"; "i")) | .DBSubnetGroupName' <<<"$SNGRP")"
while read -r name; do
  [[ -n "$name" ]] || continue
  row "$name" "DB subnet group whose name or description names SQL Server"
  cmd "aws rds delete-db-subnet-group $P --db-subnet-group-name $name"
done <<<"$SNG_ROWS"

SM="$(A secretsmanager list-secrets --output json)"
SM_ROWS="$(jq -r --argjson cutoff "$CUTOFF" "$JQ_LIB"' .SecretList[]? | select(.Name | test("sqlserver|mssql|sql-server"; "i"))
  | [.Name, (.LastAccessedDate // "never" | tostring), (.LastChangedDate // "-" | tostring)] | @tsv' <<<"$SM")"
while IFS=$'\t' read -r name accessed changed; do
  [[ -n "$name" ]] || continue
  row "$name" "secret name names SQL Server; last accessed $accessed; last changed $changed" "$RATE_SECRET"
  cmd "aws secretsmanager delete-secret $P --secret-id $name --recovery-window-in-days 30"
done <<<"$SM_ROWS"
end_section

# ── 3. EBS, snapshots, AMIs, Elastic IPs ───────────────────────────────────────────────────────────────────────
section "3. Unattached EBS volumes, old snapshots and AMIs, unassociated Elastic IPs"

AVAIL_ROWS="$(jq -r "$JQ_LIB"' .Volumes[]? | select(.State == "available" and (eks | not)) | [.VolumeId, (.Size | tostring), (.CreateTime | ep | todate[0:10])] | @tsv' <<<"$VOLS")"
while IFS=$'\t' read -r id size created; do
  [[ -n "$id" ]] || continue
  row "$id" "EBS volume in state available (attached to nothing); ${size} GiB; created $created" "$(gb_cost "$size" "$RATE_EBS_GB")"
  cmd "aws ec2 delete-volume $P --volume-id $id   # snapshot first if the data may be needed"
done <<<"$AVAIL_ROWS"

AMIS="$(A ec2 describe-images --owners self --output json)"
INSTANCES="$(A ec2 describe-instances --output json)"
jq '[.Reservations[]?.Instances[]?.ImageId] | unique' <<<"$INSTANCES" >"$T/amis-in-use.json"
AMI_ROWS="$(jq -r --argjson cutoff "$CUTOFF" --slurpfile used "$T/amis-in-use.json" "$JQ_LIB"'
  .Images[]? | select((.CreationDate | ep) < $cutoff) | select([.ImageId] | inside($used[0]) | not)
  | [.ImageId, .Name, (.CreationDate | ep | todate[0:10]),([.BlockDeviceMappings[]?.Ebs.VolumeSize // 0] | add | tostring)] | @tsv' <<<"$AMIS")"
while IFS=$'\t' read -r id name created gib; do
  [[ -n "$id" ]] || continue
  row "$id ($name)" "AMI created $created, older than $STALE_DAYS days; no instance in this region uses it" "$(gb_cost "$gib" "$RATE_SNAP_GB")"
  cmd "aws ec2 deregister-image $P --image-id $id   # then delete the snapshots it references"
done <<<"$AMI_ROWS"

SNAPS_EC2="$(A ec2 describe-snapshots --owner-ids "$ACCOUNT" --output json)"
jq '[.Images[]?.BlockDeviceMappings[]?.Ebs.SnapshotId // empty] | unique' <<<"$AMIS" >"$T/ami-snaps.json"
SNAP_EC2_ROWS="$(jq -r --argjson cutoff "$CUTOFF" --slurpfile amisnaps "$T/ami-snaps.json" "$JQ_LIB"'
  .Snapshots[]? | select((.StartTime | ep) < $cutoff) | select([.SnapshotId] | inside($amisnaps[0]) | not)
  | [.SnapshotId, (.StartTime | ep | todate[0:10]),(.VolumeSize | tostring), (.Description // "-")] | @tsv' <<<"$SNAPS_EC2")"
while IFS=$'\t' read -r id created gib desc; do
  [[ -n "$id" ]] || continue
  row "$id" "EBS snapshot created $created, older than $STALE_DAYS days; not referenced by a listed AMI; \"$desc\"" "$(gb_cost "$gib" "$RATE_SNAP_GB")"
  cmd "aws ec2 delete-snapshot $P --snapshot-id $id"
done <<<"$SNAP_EC2_ROWS"

ADDR="$(A ec2 describe-addresses --output json)"
EIP_ROWS="$(jq -r '.Addresses[]? | select(.AssociationId | not) | [.AllocationId, .PublicIp] | @tsv' <<<"$ADDR")"
while IFS=$'\t' read -r alloc ip; do
  [[ -n "$alloc" ]] || continue
  row "$alloc ($ip)" "Elastic IP with no association; public IPv4 is billed per hour" "$RATE_IPV4"
  cmd "aws ec2 release-address $P --allocation-id $alloc"
done <<<"$EIP_ROWS"
end_section

# ── 4. ECR repositories ────────────────────────────────────────────────────────────────────────────────────────
section "4. ECR repositories with no recent push (older than $STALE_DAYS days, or empty)"

REPOS="$(A ecr describe-repositories --output json)"
REPO_NAMES="$(jq -r '.repositories[]?.repositoryName' <<<"$REPOS")"
while read -r name; do
  [[ -n "$name" ]] || continue
  IMGS="$(A ecr describe-images --repository-name "$name" --output json)"
  STATUS="$(jq -r --argjson cutoff "$CUTOFF" "$JQ_LIB"' [.imageDetails[]? | .imagePushedAt | ep] | max
    | if . == null then "empty" elif . < $cutoff then "last push " + (todate[0:10]) else "recent" end' <<<"$IMGS")"
  [[ "$STATUS" != recent ]] || continue
  BYTES="$(jq -r '[.imageDetails[]?.imageSizeInBytes // 0] | add // 0' <<<"$IMGS")"
  row "$name" "ECR repo: $STATUS" "$(gb_cost "$(bytes_to_gb "$BYTES")" "$RATE_ECR_GB")"
  cmd "aws ecr delete-repository $P --repository-name $name   # refuses while images exist; do not add --force without checking the images"
done <<<"$REPO_NAMES"
end_section

# ── 5. CloudWatch log groups ───────────────────────────────────────────────────────────────────────────────────
section "5. CloudWatch log groups with no retention, or no event in $STALE_DAYS days"

LGS="$(A logs describe-log-groups --output json)"
LG_ALL="$(jq -r '.logGroups[]? | [.logGroupName, (if .retentionInDays then (.retentionInDays | tostring) else "never" end), ((.storedBytes // 0) | tostring)] | @tsv' <<<"$LGS")"
while IFS=$'\t' read -r name retention bytes; do
  [[ -n "$name" ]] || continue
  [[ "$name" != /aws/eks* ]] || continue # already listed in section 1
  STREAMS="$(A logs describe-log-streams --log-group-name "$name" --order-by LastEventTime --descending --max-items 1 --output json)"
  LAST_MS="$(jq -r '.logStreams[0]?.lastEventTimestamp // empty' <<<"$STREAMS")"
  if [[ -n "$LAST_MS" ]]; then
    LAST="$(jq -n --argjson ms "$LAST_MS" '($ms / 1000) | todate[0:10]')"
    STALE="$(jq -n --argjson ms "$LAST_MS" --argjson cutoff "$CUTOFF" '($ms / 1000) < $cutoff')"
  else
    LAST="none recorded"
    STALE=true
  fi
  if [[ "$retention" == never || "$STALE" == true ]]; then
    row "$name" "retention $retention; last event $LAST" "$(gb_cost "$(bytes_to_gb "$bytes")" "$RATE_LOGS_GB")"
    if [[ "$STALE" == true ]]; then
      cmd "aws logs delete-log-group $P --log-group-name $name   # if nothing reads it"
    else
      cmd "aws logs put-retention-policy $P --log-group-name $name --retention-in-days 30"
    fi
  fi
done <<<"$LG_ALL"
end_section

# ── 6. KMS keys ────────────────────────────────────────────────────────────────────────────────────────────────
section "6. KMS keys: pending deletion, disabled, or customer keys with no alias"

ALIASES="$(A kms list-aliases --output json)"
printf '%s' "$ALIASES" >"$T/aliases.json"
KEYS="$(A kms list-keys --output json)"
KEY_IDS="$(jq -r '.Keys[]?.KeyId' <<<"$KEYS")"
while read -r kid; do
  [[ -n "$kid" ]] || continue
  KD="$(A kms describe-key --key-id "$kid" --output json)"
  KEY_ROW="$(jq -r --slurpfile al "$T/aliases.json" '.KeyMetadata | . as $m | select(.KeyManager == "CUSTOMER")
    | [.KeyId, .KeyState, (([$al[0].Aliases[]? | select(.TargetKeyId == $m.KeyId)] | length) | tostring)] | @tsv' <<<"$KD")"
  [[ -n "$KEY_ROW" ]] || continue
  IFS=$'\t' read -r id state aliases <<<"$KEY_ROW"
  if [[ "$state" != Enabled ]]; then
    row "$id" "customer key in state $state"
    cmd "aws kms cancel-key-deletion $P --key-id $id   # only if the key is in PendingDeletion and should stay"
  elif [[ "$aliases" == 0 ]]; then
    row "$id" "enabled customer key with no alias; use not checked (CloudTrail needed)" "$RATE_KMS"
    cmd "aws kms schedule-key-deletion $P --key-id $id --pending-window-in-days 7   # only after CloudTrail shows no use"
  fi
done <<<"$KEY_IDS"
end_section

# ── 7. Secrets Manager ─────────────────────────────────────────────────────────────────────────────────────────
section "7. Secrets Manager: never accessed, or not accessed in $STALE_DAYS days"

SM_ALL="$(A secretsmanager list-secrets --output json)"
SM_STALE="$(jq -r --argjson cutoff "$CUTOFF" "$JQ_LIB"' .SecretList[]?
  | select((.Name | test("sqlserver|mssql|sql-server"; "i")) | not)
  | select((.DeletedDate | not) and ((.LastAccessedDate | not) or ((.LastAccessedDate | ep) < $cutoff)))
  | [.Name, (.LastAccessedDate // "never" | tostring), (.LastChangedDate // "-" | tostring)] | @tsv' <<<"$SM_ALL")"
while IFS=$'\t' read -r name accessed changed; do
  [[ -n "$name" ]] || continue
  row "$name" "last accessed $accessed; last changed $changed; values not read" "$RATE_SECRET"
  cmd "aws secretsmanager delete-secret $P --secret-id $name --recovery-window-in-days 30   # confirm no task or service reads it"
done <<<"$SM_STALE"
end_section

# ── 8. opshub-prod idle resources (report only) ────────────────────────────────────────────────────────────────
section "8. opshub-prod: resources that never served traffic (decision for the owner, nothing changed)"

PROD_DB_ROWS="$(jq -r '.DBInstances[]? | select(.DBInstanceIdentifier | test("opshub"; "i")) | select(.DBInstanceIdentifier | test("prod"; "i"))
  | [.DBInstanceIdentifier, .DBInstanceClass, (.AllocatedStorage | tostring), .DBInstanceStatus] | @tsv' <<<"$DBI")"
while IFS=$'\t' read -r id class gib status; do
  [[ -n "$id" ]] || continue
  CONN="$(A cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name DatabaseConnections \
    --dimensions "Name=DBInstanceIdentifier,Value=$id" --start-time "$(ago 30)" --end-time "$(ago 0)" \
    --period 86400 --statistics Maximum --output json)"
  MAX_CONN="$(jq -r '[.Datapoints[]?.Maximum] | max // 0' <<<"$CONN")"
  if [[ "$class" == db.t4g.micro ]]; then
    COST="$(awk -v h="$RATE_RDS_T4G_MICRO_HR" -v g="$gib" -v s="$RATE_RDS_GB" 'BEGIN { printf "%.2f", h * 730 + g * s }')"
  else
    COST=""
  fi
  row "$id" "RDS $class, $gib GiB, $status; max DatabaseConnections in 30 days: $MAX_CONN (0 = never connected)" "$COST"
  [[ -n "$COST" ]] || out "> Price for $class not in the RATE table: look it up before deciding."
  cmd "aws rds delete-db-instance $P --db-instance-identifier $id --final-db-snapshot-identifier ${id}-final-$(date +%F)   # deletion protection must be off"
done <<<"$PROD_DB_ROWS"

ECS_CLUSTERS="$(A ecs list-clusters --output json)"
ECS_ARNS="$(jq -r '.clusterArns[]? | select(test("opshub"; "i")) | select(test("prod"; "i"))' <<<"$ECS_CLUSTERS")"
while read -r arn; do
  [[ -n "$arn" ]] || continue
  DESC="$(A ecs describe-clusters --clusters "$arn" --output json)"
  ECS_ROW="$(jq -r '.clusters[]? | [.clusterName, (.runningTasksCount | tostring), (.activeServicesCount | tostring)] | @tsv' <<<"$DESC")"
  IFS=$'\t' read -r name tasks services <<<"$ECS_ROW"
  row "$name" "ECS cluster; $services active services, $tasks running tasks (cluster itself is free; tasks are billed)"
  cmd "# scale each service to 0, delete the services, then: aws ecs delete-cluster $P --cluster $name"
done <<<"$ECS_ARNS"

ELB="$(A elbv2 describe-load-balancers --output json)"
ALB_ROWS="$(jq -r '.LoadBalancers[]? | select(.LoadBalancerName | test("opshub"; "i")) | select(.LoadBalancerName | test("prod"; "i"))
  | [.LoadBalancerArn, .LoadBalancerName, (.LoadBalancerArn | split("loadbalancer/")[1])] | @tsv' <<<"$ELB")"
while IFS=$'\t' read -r arn name dim; do
  [[ -n "$arn" ]] || continue
  REQ="$(A cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
    --dimensions "Name=LoadBalancer,Value=$dim" --start-time "$(ago 30)" --end-time "$(ago 0)" \
    --period 2592000 --statistics Sum --output json)"
  REQ_SUM="$(jq -r '[.Datapoints[]?.Sum] | add // 0' <<<"$REQ")"
  row "$name" "load balancer; RequestCount in 30 days: $REQ_SUM (0 = no traffic)" "$(awk -v h="$RATE_ALB_HR" 'BEGIN { printf "%.2f", h * 730 }')"
  cmd "aws elbv2 delete-load-balancer $P --load-balancer-arn $arn"
done <<<"$ALB_ROWS"
end_section

out ""
out "## Totals and limits"
out ""
out "Estimated monthly cost of the rows that carry one: \$$TOTAL. Estimates only: check the rates and the bill."
out ""
out "Limits: region $REGION only, plus global IAM. Not checked: S3, Route 53, Lambda, SES, Cognito, KMS key usage (needs CloudTrail lookup-events), ECS services' task definitions, and whether a launch template still references an AMI. Every flagged item needs a human check before its command is run."

echo "Report: $MD" >&2
