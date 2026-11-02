# Runbook: leave AWS (owner-run)

Deadline: everything below finished before **2026-11-09**, when the stopped RDS
instance auto-starts again. Source: audit-infra 2026-11-02, section 2.

Preconditions (SA confirms before step 4): rova prod GO and the 72 h soak passed
(about 2026-11-05); on-prem backups green (barman, nightly dump, restore test);
a final manual RDS snapshot exists and its id is recorded.

Conventions for every command: AWS commands name the profile, never rely on the
default (the default profile on the owner machine is another account).

```sh
export AWS_PROFILE=qnsc-admin AWS_REGION=ap-southeast-1 AWS_PAGER=""
az login   # tenant of the Entra directory; then: export ARM_SUBSCRIPTION_ID=<subscription id>
```

State files hold secrets (the Access IdP client secret, Turnstile secret, Grafana
tokens). Keep copies in a `chmod 700` directory outside the repo and outside
iCloud-synced folders, and shred them when the step is done. Never paste a state
file into chat, a PR or a log.

While a stack is being migrated or destroyed, merge nothing that touches
`live/<stack>`: the CI apply and an owner-local apply do not share a lock until
the state is on Azure (audit C-4). Apply jobs wait for the `production`
reviewer, so you can also simply leave the run unapproved.

## Step 1: CI trust first (no AWS needed)

1. Merge the CI PR (read-only plan tokens, every apply in `production`) after the
   owner created the secrets listed in its body.
2. Add `Workers Routes: Read` (and the other read scopes in that PR) to
   `CLOUDFLARE_API_TOKEN_READONLY`, re-run drift, close issue #166.
3. Merge PR #188 (SES identity and mail-from DNS out of edge) only after the Graph
   prod mail proof passed. Afterwards the follow-up "drop the `aws` provider from
   `live/edge`" is a one-line PR (remove `aws` from `required_providers` and the
   `provider "aws"` block in `live/edge/main.tf`).

## Step 2: edge off AWS

The ACM change is its own PR (`removed { destroy = false }` for the certificate,
its validation and the validation record). Its plan must read: three resources
"will no longer be managed", zero destroys. The certificate and the validation
CNAME stay in AWS and Cloudflare until the account is closed (the AWS ALB, our
rollback path, still serves the certificate). Delete the validation CNAME in the
dashboard afterwards.

## Step 3: unblock `observability` (audit A-5)

Its state holds Grafana objects under a provider alias that no longer exists, so
it cannot be planned (listed in NOT_PLANNABLE in `infra-plan.yml`).

1. Actions, "Observability state migration", branch `main`, `apply = false`. Read
   the dry run (it prints every import id and refuses to `state rm` anything until
   the sibling plan is empty).
2. Re-run with `apply = true`. Nothing in Grafana changes; only the state owner.
3. In `live/observability` and `live/observability-alerting`, `tofu plan` must be
   "No changes" (needs the same TF_VARs as CI).
4. A small PR removes `observability` from NOT_PLANNABLE in `infra-plan.yml` and
   adds it to the `drift-detection.yml` matrix. Hold PR #268 (synthetic monitoring
   installation) until this is done: it is the reason the SM token behaviour on
   install is unknown.

## Step 4: archive the S3 state bucket (audit A-7)

```sh
umask 077
dir=$(mktemp -d "$HOME/state-archive.XXXXXX") && cd "$dir"
aws s3 sync s3://qnsc-tofu-state ./qnsc-tofu-state --only-show-errors
aws s3api list-object-versions --bucket qnsc-tofu-state --query 'length(Versions)'   # record this number
find ./qnsc-tofu-state -type f | wc -l                                             # and this one
# Azure copy (versioned, soft delete on the account):
az storage blob upload-batch --auth-mode login --account-name stqnsctfstate \
  --destination tfstate --destination-path aws-archive --source ./qnsc-tofu-state
```

A second copy in R2 is NOT a plain upload: every locked prefix of `qnsc-backups`
also has a delete lifecycle (35 days at most), so it would be erased. It needs its
own prefix with a lock rule and no lifecycle rule (a code change in
`live/onprem/backups.tf`); until then keep an encrypted copy outside Cloudflare
and Azure (for example the owner's 1Password vault as a file attachment).

Record the counts in HANDOFF. Keep the archive for one year. Do not delete the S3
bucket until step 7.

## Step 5: move the keeper stacks to Azure state

Keepers: edge, storage-prod, storage-dev, observability, observability-alerting,
adaptive-metrics. Order: edge first (alone, not on a cutover night), then
storage-prod and storage-dev (each R2 bucket must be owned by exactly one stack:
never let two stacks own one bucket), then observability, then
observability-alerting (switch its `terraform_remote_state` of `observability` to
`backend = "azurerm"` in the same PR), then adaptive-metrics.

Target: account `stqnsctfstate`, resource group `rg-qnsc-platform`, container
`tfstate`, key `infra/<stack>/terraform.tfstate`, `use_azuread_auth = true`
(copy the block from `live/onprem/versions.tf`).

Per stack, one PR each:

1. On `main`: `cd live/<stack> && tofu init` (S3 backend), export the same
   `TF_VAR_*` the CI job uses, `tofu plan` and expect "No changes". Copy the
   state aside: `tofu state pull > "$dir/<stack>.tfstate"`.
2. Check out the PR branch (backend block changed to azurerm), then
   `tofu init -migrate-state` and answer yes to copy the state.
3. `tofu plan` must be "No changes". If it is not, stop and tell the SA.
4. In the same PR, switch the stack's jobs in `infra-plan.yml`,
   `infra-apply.yml`, `drift-detection.yml` from `setup-tofu-aws` to the `ARM_*`
   OIDC env that `onprem` already uses (read identity for plan and drift, the
   apply identity under `environment: production` for apply). The PR plan must
   show "No changes" through CI.
5. Merge. Do not delete the S3 object yet.

The apply identity can write the whole state account (audit I-5); a separate PR
adds an access condition. Not a blocker for the exit.

## Step 6: destroy the AWS-only stacks (S3 and the AWS roles still exist)

Order: `runtime-prod`, `runtime-dev` (ALB, NAT, Valkey) after the product repos'
AWS stacks (ECS, RDS after the final snapshot, ElastiCache, ECR last; see the
rova "Decommission" runbook), then `security-baseline` (export CloudTrail first
if any is kept), then `organization` (already retired: `tofu state rm` only).
These are owner-local `tofu destroy` runs with `AWS_PROFILE=qnsc-admin`. Resources
with `prevent_destroy` need that line removed in a reviewed commit first. Take the
final RDS snapshot BEFORE destroying anything that holds the database, and keep it
until the account closes. Remember `edge` still outputs `acm_cert_arn` (null) so
that `runtime-*` can be refreshed during destroy.

## Step 7: bootstrap last

1. In gitops, stop using `CHART_PUBLISH_ROLE_ARN` (charts are on GHCR).
2. Copy `platform/bootstrap/terraform.tfstate` into the archive again (it changes
   as roles are removed).
3. Destroy bootstrap: ECR chart registry, artifacts bucket, IAM OIDC roles and
   provider, KMS, the DynamoDB lock table, then empty and delete the state bucket.

## Step 8: workflows and secrets

- Delete the AWS steps and workflows: `unmanaged-resources.yml`, `aws-audit-tests.yml`,
  `ecr-preview-tests.yml`, the AWS step in `alerting-health.yml`, the repo variable
  `AWS_ACCOUNT_ID`, the product repos' AWS deploy roles. Update the README
  ("Platform-level AWS infrastructure").
- Revoke the AWS-era R2 tokens (`rova-production-r2-app` and the others), remove
  the old GitHub App key `rova-scm-prod` (the AWS one), delete the IAM human users.

## Step 9: close the account

Irreversible: snapshots, CloudTrail and Secrets Manager are gone with it. Do it
only when the SA confirms steps 1 to 8 and the archive counts are recorded. Then
remove the leftover DNS (`rova-api`, the ACM validation CNAME, SES records if
#188 was not applied) and the Pages project `rova-prod-web` with the
`allow-dns-destroy` label (audit E-5).

## Not verified

This runbook was written from code and the audit. No command here was run
against AWS, Azure or Cloudflare. The `prevent_destroy` handling in step 6 and the
`tofu init -migrate-state` prompts in step 5 are from the tool's documented behaviour.
