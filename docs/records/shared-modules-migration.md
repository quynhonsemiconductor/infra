# Plan: Shared Terraform Modules (`qnsc-tf-modules`)

Status: **Proposed** · Owner: Platform · Last updated: 2026-06-28

## Problem

Each product infra repo (`rally-infra`, `opshub-infra`, and every future product)
carries its **own copy** of the core Terraform modules — `network`, `rds`,
`ecs-service`, `ecs-cluster`, `cdn`, `waf`, `secrets`, `messaging`, `iam-oidc`,
`ecr`. These copies have already **diverged**:

| Module | rally LOC | opshub LOC | Notes |
| :----- | --------: | ---------: | :---- |
| ecs-service | 412 | 344 | core compute — drift is risky |
| network | 337 | 310 | VPC/subnets/SGs |
| iam-oidc | 297 | 94 | rally has extra infra-roles |
| cdn | 235 | 235 | **identical** — ideal pilot |
| rds | 202 | 83 | |
| waf | 149 | 89 | security rules drift = exposure |
| messaging | 123 | 40 | |
| ecr | 113 | 57 | |
| secrets | 77 | 19 | |
| ecs-cluster | 34 | 24 | |
| cache | 64 | — | rally-only (opshub single-tenant) |

A security fix to `waf` in rally never reaches opshub. By product #3 we maintain
the same logic in three places. This does not scale.

## Goal

A dedicated, **independently-versioned** module repository — `qnsc-tf-modules` —
that products consume by pinned ref. Mirrors the `qnsc-gitops` pattern (shared,
versioned CI actions) but for infrastructure. Product infra repos shrink to
**`live/` only** (environment composition + values); no `modules/` copies.

```
qnsc-tf-modules/              ← NEW shared repo
  modules/
    network/  rds/  ecs-service/  ecs-cluster/  cdn/
    waf/  secrets/  messaging/  iam-oidc/  ecr/
  README.md                   ← per-module input/output docs
  .github/workflows/ci.yml    ← fmt, validate, tflint, checkout, terraform test

rally-infra/                  ← shrinks
  live/{_shared,develop,prod}/ ← source = "git::…/qnsc-tf-modules//modules/network?ref=network-v1.2.0"
opshub-infra/                 ← shrinks (same pattern)
```

### Why a separate repo (not `qnsc-infra/modules/`)

- `qnsc-infra` holds **live account state** (bootstrap: OIDC, KMS, state bucket).
  Reusable module *code* should not share a repo with a pipeline that mutates the
  account — different change cadence, different blast radius.
- Independent semver per module (`network-v1.2.0`) lets products upgrade
  deliberately, one module at a time.
- Module CI (validate/tflint/checkov/`terraform test`) stays separate from apply.

## Hard constraint: zero resource churn

A module's source path is part of each resource's address only via the module
**call name**, not its `source`. Changing `source` from `./modules/network` to a
git ref **does not** move resources in state — addresses stay
`module.network.aws_vpc.this`. Therefore each migration step **must** end with:

```
tofu init -upgrade && tofu plan   → "No changes. Your infrastructure matches…"
```

If a plan shows create/destroy, **stop** — the extracted module differs from the
local one and must be reconciled first.

> Note: we are **pre-release** (no `tofu apply` has run; S3 backend still
> commented out in `qnsc-infra/live/bootstrap`). Today the "zero churn" check is
> against an empty state, so the risk is minimal. This plan is still written to be
> safe once state exists, because it will.

## Phased rollout

### Phase 0 — Reconcile divergence (decide canonical)
For each module, diff rally vs opshub and decide the canonical version. Most
differences are **product config that belongs in `live/` variables**, not in the
module. Push product-specific values up to the caller; keep the module generic.
Output: one agreed module per name.

### Phase 1 — Create `qnsc-tf-modules` + pilot with `cdn`
- Scaffold the repo + CI (fmt, validate, tflint).
- `cdn` is **byte-identical** across both products → zero reconciliation. Move it
  first, tag `cdn-v1.0.0`.
- Repoint **one** environment (e.g. `rally-infra/live/develop`) to the git ref.
- Run `tofu plan` → must be **no changes**. This validates the whole approach
  end-to-end on the safest module.

### Phase 2 — Migrate low-risk modules
`ecr`, `ecs-cluster`, `secrets`, `messaging` — small, mostly mechanical. One
module per PR, each ending in a clean plan.

### Phase 3 — Migrate high-value / high-risk modules
`network`, `rds`, `ecs-service`, `waf`, `iam-oidc`. Largest and most diverged.
One per PR, careful reconciliation, clean plan required before merge.

### Phase 4 — Remove product `modules/` copies
Once all callers reference the registry, delete the per-product `modules/` dirs.
Product infra repos now contain only `live/`.

### Phase 5 — Versioning discipline
- Per-module semver tags (`network-v1.2.0`); document inputs/outputs per module.
- Products pin to a tag and bump intentionally (Dependabot can watch git refs).
- Optional: a floating `network-v1` like the `qnsc-gitops` `@v1` pattern.

## Per-step checklist (apply to every module move)

- [ ] Module reconciled (no product-specific hardcoding; differences moved to `live/` vars)
- [ ] Moved to `qnsc-tf-modules/modules/<name>`, tagged `<name>-vX.Y.Z`
- [ ] CI green in `qnsc-tf-modules` (fmt, validate, tflint)
- [ ] Each consuming `live/` env repointed to the git ref
- [ ] `tofu init -upgrade && tofu plan` → **No changes** in every env
- [ ] PR reviewed by infra lead (CODEOWNERS)
- [ ] Old local `modules/<name>` deleted only after all callers migrated

## Open decisions

1. Module source style: `git::https://…//modules/network?ref=network-v1.0.0`
   (simple, no registry infra) vs a private Terraform registry (more tooling).
   Recommend git-ref to start.
2. Tagging: per-module tags (`network-v1`) vs one repo-wide version. Per-module
   gives finer control; repo-wide is simpler. Recommend per-module.
3. Whether `cache` stays rally-only or becomes a generic optional module for
   future multi-tenant products.
