# Plan: Extract the per-service composition bundle (`product-service`)

Status: **SUPERSEDED — do not execute** · Owner: Platform · Superseded 2026-09-16

> ## Why this plan is not being run
>
> It would consolidate the ECS composition layer, and §17 of the Kubernetes
> platform design **retires the ECS estate**. Executing both means migrating three
> products onto `product-service` — renaming resources in state, writing `moved{}`
> blocks and proving a zero-diff plan, three times — and then deleting the module
> when EKS lands.
>
> The duplication this plan measured is real and its analysis still holds. It is
> being solved by the other path: `product-profile` (`tf-modules`, v0.1.0) is the
> same consolidation for the EKS runtime, and §17 moves products onto it one at a
> time. A product's `infra/` is deleted when its new stack has applied and run —
> not before.
>
> `product-service` stays in `tf-modules` at 0.x, unconsumed, and is deleted with
> the ECS estate. It is NOT the next step, and this file said it was.
>
> Keep reading for the measurements, which are the reason `product-profile` has
> the interface it does. See `docs/repository-boundaries.md` for where a product's
> infrastructure lives now.


Sequel to [`shared-modules-migration.md`](./shared-modules-migration.md). That plan moved
the *leaf* modules into `qnsc-tf-modules` and succeeded — all 25 module directories are now
referenced by immutable release tag, and none is unused. The duplication that remains is one
level up: the **composition** layer.

## Problem

Each product carries its own `infra/modules/stack`, called by both `live/develop` and
`live/prod`. Measured 2026-09-12:

| Product | `modules/stack/main.tf` | module calls | `variables.tf` |
| :------ | ----------------------: | -----------: | -------------: |
| rova | 3,232 lines | 17 | 48 KB |
| opshub | 2,539 lines | 18 | 40 KB |
| qnsc-kb-backend | 1,096 lines | 13 | 23 KB |

The overlap is near-total. Comparing declared module calls:

- **rova ∩ opshub = 16 of 17.** rova has *zero* unique module calls; opshub's only extra is
  `app_bucket`.
- **qnsc-kb is a 12-call subset** (no `alerts`, no `firelens_agent_*`, no `otel_agent_*`).
- Shared by all three: `api`, `cache`, `dns_api`, `ecs_cluster`, `migrator`, `observability`,
  `rds`, `secrets`, `tunnel`, `tunnel_api`, `web`, `worker`.

So one composition is implemented three times, in ~6,900 lines of HCL plus ~111 KB of
variable declarations.

## What NOT to do

**Do not extract one shared `product-stack` module.** Those `variables.tf` sizes are the
warning: a single module spanning every product's composition concentrates them into one
interface with well over a hundred variables, and every product-specific option becomes
another optional input with a default that only one caller wants. That is the god-module
antipattern, and it is harder to reason about than the duplication it replaces.

## Proposed factoring

The module names already reveal the seam — they cluster per *service*, not per product:

```
api    + otel_agent_api    + firelens_agent_api    + dns_api + tunnel_api
worker + otel_agent_worker + firelens_agent_worker
```

Extract **`product-service`**: one ECS service plus the sidecars and ingress that always
accompany it.

```hcl
module "api" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/product-service?ref=product-service-v1.0.0"

  product      = "rova"
  env          = "prod"
  service_name = "api"

  # network, from the shared runtime stack's remote state
  vpc_id            = local.vpc_id
  subnet_ids        = local.private_subnet_ids
  security_group_id = local.sg_app_id

  image_uri = "${local.ecr_base}/rova-api:${var.image_tag}"
  cpu       = 1024
  memory    = 2048

  # ingress: tunnel OR alb, never both — the module asserts it
  tunnel_token_secret_arn = module.secrets.secret_arns["tunnel-token"]
  alb_listener_arn        = null

  # sidecars, on by default, each independently disableable
  enable_otel_agent     = true
  enable_firelens_agent = true
  enable_alerts         = true
}
```

That collapses ~5 module calls into 1, twice per product, across three products — roughly
30 calls down to 6 — with a small interface because it is scoped to *one service*, not to a
whole product.

A second candidate, once the first has landed: **`product-data`**, bundling
`rds` + `cache` + `secrets`, which all three products declare identically in shape. That
one carries the sharing policy from `allocations.json` in its interface, so a new product
scaffolds into the cheap shape by default rather than the expensive one:

```hcl
module "data" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/product-data?ref=product-data-v1.0.0"

  product = "lms"
  env     = "develop"

  # ── Cache: shared by default, because ElastiCache cannot be stopped ──────────
  # A per-product node bills 730 h/month however little the environment runs. The
  # default is therefore the shared runtime node with a centrally allocated index.
  cache = {
    shared   = true   # DEFAULT true for develop, false for prod
    db_index = 4      # 0 rova · 1 qnsc-kb · 2 opshub · 3 solodesk · 4 lms
  }

  # ── Database: shared when the data is reconstructible ───────────────────────
  # `shared = true` creates a database + role (with CONNECTION LIMIT) on the tier's
  # instance instead of a new instance. Develop data is reconstructible from
  # migrations and seeds, so develop shares; production isolates unless the tenant
  # is internal tooling.
  database = {
    shared = true     # DEFAULT true for develop, false for prod
    # instance_class / storage_gb are IGNORED when shared = true
  }
}
```

Two properties worth designing in from the start:

- **The defaults encode the policy.** `shared = true` for develop and `false` for
  production means the expensive shape requires an explicit, reviewable override with a
  reason — the reverse of today, where opshub-develop got a $15/mo node by taking a default
  nobody chose.
- **A `validation` block, not a `check` block.** rova's `cache` variable records why, from
  measurement: "a violated check emits `Warning: Check block assertion failed` and the plan
  exits 0 — measured on OpenTofu 1.12.3 — so a guard written that way lets exactly the
  state it forbids apply cleanly." Any cross-field guard in `product-data` must be a
  `validation`.

### The shared develop database is a migration, not an edit

Unlike the cache, this one moves data. Five develop instances become one, so it needs
sequencing rather than a flag flip:

1. Create the shared develop instance alongside the existing five (cost overlaps briefly).
2. Per product, in its own change: create the database and role, run migrations into it,
   point the product's `DATABASE_URL` at it, verify, then destroy the old instance.
3. Do the least-loaded product first. opshub develop is the obvious candidate — opshub is
   not launched, so a mistake there costs nothing.

Expected saving at five products: roughly $17/mo, plus one instance to upgrade and one to
rehearse migrations against instead of five. That operational effect is worth more than the
money.

Internally the new module keeps composing the existing leaf modules (`ecs-service`,
`observability-agent`, `firelens-agent`, `dns-record`, `tunnel-agent`,
`observability-alerts`). Nothing about those changes.

## The hard requirement: a zero-diff plan

Moving a resource between module addresses **renames it in state**. Without `moved` blocks
Terraform reads that as destroy-and-create — and for these resources that means recreating
ECS services, and potentially the RDS instance, in an environment where **rova prod is
live** (`live/runtime-prod/main.tf` header: "LIVE as of go-live").

So this migration is gated on evidence, not review:

1. Write `moved` blocks for every relocated address before touching the callers.
2. `tofu plan` must report **no changes** — not "only safe changes". Any non-empty plan means
   an address was missed.
3. Only then apply, one stack at a time.

This cannot be validated from a workstation without state access; it belongs in the
`infra-plan` CI job whose output is reviewable on the PR.

## Sequencing (cheapest risk first)

Corrected 2026-09-12 against live AWS and the state bucket. An earlier version of this
section said "opshub is currently deployed in neither environment, so there is no state to
migrate" and sequenced opshub first on that basis. **That was wrong.**
`opshub/develop/terraform.tfstate` and `opshub/prod/terraform.tfstate` both exist, the
`opshub-prod` RDS instance is provisioned, and the `opshub-prod` ECS cluster exists. What is
true is that opshub prod is IDLE — one `worker` service at desired 0 / running 0, and no
`api` service — which lowers the consequence of a bad plan but does not remove the state.

**There is no risk-free first target.** `infra/modules/stack` is shared by both environments
of a product, so every adoption touches at least one stateful environment. The order below
sequences by consequence, not by absence of state.

1. **qnsc-kb.** Its prod stack has NO state file at all — verified against the state bucket —
   so only its develop environment carries risk, and that environment's data is
   reconstructible from migrations and seeds. It is also the subset caller (no
   `otel_agent_*`, no `firelens_agent_*`), which exercises the "sidecars disabled" path
   first.
2. **opshub.** Both environments have state, but prod is idle and its data is disposable, so
   a mistake costs a rebuild rather than a recovery.
3. **rova develop.** Real state, disposable data.
4. **rova prod LAST.** The only environment whose data is irreplaceable. Requires a manual
   snapshot taken immediately before — manual, not automated, because automated snapshots are
   deleted along with the instance. `rova-prod-pre-migration-20260912` was created and
   verified `available` on 2026-09-12 as the reference for this step; take a fresh one at the
   time of the actual migration.

The gate at every step is the same and it is not negotiable: `tofu plan` reports **no
changes**. Not "only safe changes".

## Related: retiring the gated ALB blocks

Both `live/runtime-dev` and `live/runtime-prod` still declare `module "alb"` behind
`count = var.enable_alb ? 1 : 0`, with `enable_alb = false`. Each file's comment says the
block is retained because opshub's stacks are written against that layer's
`https_listener_arn`.

**That comment is now only partly accurate.** Verified 2026-09-12:

| Consumer | Form | Blocks deletion? |
| :------- | :--- | :--------------- |
| `opshub/infra/modules/stack/main.tf:423` | `try(…outputs.https_listener_arn, "")` | no — `try` absorbs a missing output |
| `rova/infra/modules/stack/main.tf:1735` | `try(…, "")` | no |
| `qnsc-kb-backend/infra/modules/stack/main.tf:511` | `try(…, "")` | no |
| `infra-template/live/{develop,prod}/main.tf` | **bare reference, no `try`** | **yes, for newly scaffolded products** |

So all three real products already tolerate the output disappearing — the defensive `try(…)`
was the migration. The remaining hard dependency is `infra-template`, which would break the
next product scaffolded from it (not anything deployed).

Order of operations:

1. Update `infra-template/live/{develop,prod}/main.tf` to the same `try(…, "")` form the
   three real products use, so the scaffold matches what products actually do.
2. Re-verify nothing takes a bare reference:
   `grep -rn "https_listener_arn" --include=*.tf . | grep -v /.terraform/`
3. Then delete from both runtime stacks: `module "alb"`, `module "waf"` (gated on
   `enable_alb` too), the `enable_alb` variable, the `https_listener_arn` output in
   `outputs.tf`, and the retained explanatory comments.

Also worth deciding at the same time: with the ALB gone for good, `module "alb_logs"` in
`runtime-prod` provisions an S3 bucket nothing writes to. The `tunnel-agent` README lists
ALB access logs among what tunnel ingress gives up.

**`live/develop/moved.tf` in opshub has been DELETED** as part of this work, and the decision
was verified rather than assumed: `tofu state list` on `opshub/infra/live/develop` returned
**0** legacy root-level addresses (`module.secrets`, `module.rds`, `module.api`, …) and **116**
addresses under `module.stack.`. The moves had applied, exactly as that file's own comment
predicted ("safe to delete once develop has applied"). Note its header also claimed
production had never been applied, which was false — see the corrected sequencing above.
