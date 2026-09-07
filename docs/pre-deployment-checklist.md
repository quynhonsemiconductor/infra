# Pre-Deployment Validation Checklist

Status: **Required before first apply** · Owner: Platform

Everything in `tf-modules`, `rova`, and `opshub` was built and
refactored **without a single `tofu plan`** — nothing is deployed yet. This
checklist is the gate before the first real apply. Work top to bottom; do not
skip the bootstrap ordering.

---

## 0. Prerequisites (one-time)

- [ ] A workstation with **OpenTofu ≥ 1.9.1** and AWS CLI, authenticated to the
      target AWS account with admin (for bootstrap only).
- [ ] Confirm the AWS account and region (`ap-southeast-1`) are correct.
- [ ] Decide the GitHub org is `quynhonsemiconductor` (default in all modules).

---

## 1. Bootstrap the platform singletons (`qnsc-infra`)

The state backend, OIDC provider, and KMS key must exist before anything else
(every product reads them via remote state).

- [ ] `cd qnsc-infra/live/bootstrap`
- [ ] `tofu init` (local backend first)
- [ ] `tofu validate`
- [ ] `tofu plan` — review: S3 state bucket `qnsc-tofu-state`, DynamoDB
      `qnsc-tofu-locks`, OIDC provider, KMS CMK, artifacts bucket. **Confirm no
      `qncs` typo anywhere.**
- [ ] `tofu apply`
- [ ] Uncomment the `backend "s3"` block in `bootstrap/main.tf`, then
      `tofu init -migrate-state` to move state into the new bucket.
- [ ] Note the outputs: `oidc_provider_arn`, `kms_key_arn`,
      `artifacts_bucket_name`. Product stacks read these.

---

## 2. Bootstrap the infra-apply IAM roles (chicken-and-egg)

The apply pipeline assumes `<product>-github-infra-apply`, but that role is
created by the product's own `_shared` stack. Break the cycle once per product:

- [ ] Apply each product's `live/_shared` **with local admin creds** the first
      time (creates the OIDC roles incl. infra-apply/plan), OR create the
      `<product>-github-infra-apply` role by hand. After that, CI manages it.

---

## 3. Per-product `_shared` stack

For **each** of `rova`, `opshub`:

- [ ] `cd live/_shared`
- [ ] `tofu init` (uses S3 backend — bootstrap must be applied first)
- [ ] `tofu validate` — catches module-source typos, missing vars, output renames.
- [ ] `tofu plan` — review the OIDC roles (`-github-deploy-<env>`, `-ecr-push`,
      `-github-infra-plan`, `-github-infra-apply`, `-github-web-deploy-<env>`)
      and ECR repos. First plan shows **creates** (nothing exists) — that's
      expected; the gate is **no errors**.
- [ ] `tofu apply`

### Things specifically to verify in the `_shared` plan

- [ ] IAM role **names** match what the CI workflows assume (grep the workflows
      for `role/<product>-github-*`).
- [ ] The `ecs_passrole_pattern` (`rova-*`, `opshub-*`) covers the ECS task role
      names the `ecs-service` module will create (`<cluster>-<service>-task`).

---

## 4. Per-product `develop` stack

For each product, then **verify before prod**:

- [ ] `cd live/develop && tofu init && tofu validate && tofu plan`
- [ ] Review the plan for the **migrated modules** — these are the highest-risk
      because they were refactored:
  - [ ] **network** — SG rules: confirm alb→app→rds/cache chain is intact;
        `enable_interface_endpoints=false` in dev (no interface VPC endpoints).
  - [ ] **rds** — uses the **RDS-managed master password** (a Secrets Manager
        secret is created automatically); `engine_version` is correct
        (rova 17, opshub **18**).
  - [ ] **ecs-service** — task/exec role names; `region` is passed; circuit
        breaker + CPU & memory autoscaling present.
  - [ ] **cache** — `mode = "node"` in dev (single small node, not serverless).
  - [ ] **waf** — `enabled=false` in rova dev; opshub dev has it on.
- [ ] `tofu apply`
- [ ] **Fill secret values** (the modules create empty secrets):
      `aws secretsmanager put-secret-value ...` for each `<product>/<env>/*`.
      For RDS, the managed master password is auto-populated.
- [ ] **R2 runtime token** (`r2-access-key-id` / `r2-secret-access-key`) — minted
      by hand in the Cloudflare dashboard (Terraform does not create it; the
      stack's `cloudflare_api_token` is the *provisioning* token and must never
      be reused here). Scope it to **both** buckets of the product+env:
      `<product>-<env>-attachments` **and** `<product>-<env>-public-assets`.
      The app drives both through one S3 client, so a token scoped to
      attachments alone makes every avatar/logo write fail with 403 — and only
      at runtime, never at apply time.
- [ ] Smoke test: ALB responds, app starts, DB + cache reachable.

---

## 5. Per-product `prod` stack (gated)

Only after develop is healthy.

- [ ] `cd live/prod && tofu init && tofu validate && tofu plan`
- [ ] Verify prod-grade settings in the plan:
  - [ ] `multi_az_nat = true`, RDS `multi_az = true`, `deletion_protection = true`.
  - [ ] `enable_interface_endpoints = true` (default) — interface endpoints on.
  - [ ] cache `mode = "serverless"`.
  - [ ] **ALB access logs** enabled (alb-logs bucket created).
  - [ ] WAF `enabled` (default), associated to the ALB.
  - [ ] RDS Performance Insights + enhanced monitoring (if `monitoring_interval>0`).
- [ ] Apply via the **pipeline** (`apply.yml`), which gates prod behind the
      `production` GitHub Environment approval — not a local apply.

---

## 6. CI/CD verification

- [ ] Confirm `qnsc-gitops` CI is green and the `@v1` tag points at latest.
- [ ] Confirm `tf-modules` CI (fmt/validate/tflint) is green.
- [ ] Set the GitHub **org** variables (shared by every product infra repo):
      `AWS_ACCOUNT_ID`. Add `WEB_ACM_CERT_ARN_DEVELOP` / `WEB_ACM_CERT_ARN_PROD`
      only if a CloudFront-fronted web origin is used (Cloudflare Pages needs none).
      The **ALB TLS cert is NOT a variable** — it is the wildcard `*.qnsc.vn` cert
      output by the `edge` stack and consumed by `runtime-dev` / `runtime-prod`
      via `terraform_remote_state` (single source of truth; no per-env ARN to set).
- [ ] Create GitHub Environments `shared`, `develop`, `production` (add required
      reviewers on `production`).
- [ ] Trigger `plan.yml` on a PR — confirm OIDC auth works and the plan comment posts.

---

## Known risks to watch (introduced by the migration)

| Risk | Where | What to confirm in `plan` |
| :--- | :---- | :------------------------ |
| SG-rule redesign (inline → standalone) | network | Same effective ingress/egress; no SG left wide open |
| RDS password model change | rds | RDS-managed secret created; app reads `master_secret_arn` |
| ECS role rename + PassRole pattern | ecs-service + iam-oidc | Deploy role can PassRole to `<cluster>-<service>-task` |
| `engine_version` default | rds (opshub) | opshub plans **postgres 18**, not 17 |
| Resource→module swap | cache (opshub) | Cache recreated under `module.cache.*` address |

> All of these are logically sound but **unverified against real state**. The
> first `tofu plan` per stack is the proof. Treat any unexpected destroy/replace
> on an existing resource as a stop-and-investigate.
