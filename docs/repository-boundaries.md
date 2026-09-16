# Where infrastructure lives, and why

Status: **Current** · Owner: Platform · Last updated: 2026-09-16

Four repositories hold infrastructure today. Three of them should; the fourth is
an unfinished migration, not a design choice. This file says which is which, so
the question is not re-answered differently next quarter.

```
tf-modules          reusable modules, versioned and tagged
infra               live/<name>-<env> — every stack in the estate
gitops              charts · values · platform · appsets
<product>/infra/    BEING RETIRED — see "The fourth location" below
```

## The rule for each boundary

A repository split is only as good as the rule that says what crosses it. Both of
these are enforced by a check, not by a convention:

| boundary | rule | enforced by |
|---|---|---|
| `tf-modules` → `infra` | consumed by immutable `?ref=<tag>`, never a path | `module-refs` contract |
| `infra` → `gitops` | §7 — **if it outlives a deploy, OpenTofu owns it** | §7c derivation + 5 conformance contracts |

§7c is what makes the second one affordable: names are **computed identically on
both sides** from `product`, `env` and `service`, never passed. An IRSA role, a
secret path, an SQS queue URL and a bucket name all derive from the same three
values, so a new service does not have to thread a dozen strings between two
repositories.

`size` is the one fact declared in both, deliberately, and CI compares them —
OpenTofu picks an RDS instance class from it while the chart picks replica counts
and PodDisruptionBudgets, and neither reads the other at plan time.

## Why three repositories and not one

They change at three different rates, which is the standard reason to split:
modules change independently and are versioned, cloud resources change monthly,
workload config changes on every deploy. Merging them would make a module bump, a
database resize and an image tag the same kind of event, which they are not.

Costs, stated plainly rather than discovered later:

- **A new service touches three repositories** — `infra/live/<product>-<env>`,
  `gitops/values/<product>/`, and the code. §7c and the conformance contracts are
  the machinery that makes that safe; they exist because of this split.
- **Cross-repo bugs are invisible to any single-repo check.** `tofu validate`,
  `helm lint` and `helm unittest` all pass on a reference whose definition is in
  another repository. That is exactly what `ci/scripts/platform_conformance.py`
  is for, and why it lives in `ci` rather than in either repository it checks.

**Worth revisiting once the estate is on EKS, and not before:** merging `infra`
and `gitops` into one platform repository would turn the cross-repo contracts into
intra-repo ones and make a cloud-plus-workload change a single pull request. It
costs ArgoCD path filters and mixes two apply cadences. Do not attempt it
mid-migration.

## `infra/modules/` is not a duplicate of `tf-modules`

Four modules — `state-backend`, `kms`, `oidc-provider`, `artifacts-bucket` — live
in this repository and are consumed only by `live/bootstrap`. That is correct:
they create the S3 backend, the CMK and the OIDC provider that a version-pinned
remote module would itself need in order to be fetched into a stack that has
state. Bootstrap cannot depend on the thing bootstrap creates.

They have one consumer each, and that is fine. Moving them to `tf-modules` would
buy nothing and reintroduce the chicken-and-egg.

## The fourth location: `<product>/infra/`

Every product repository still carries `infra/live/{_shared,develop,prod}` and
`infra/modules/stack`. It is being retired, and the reasons are measured rather
than argued:

```
rova              4,270 lines
opshub            3,508 lines
qnsc-kb-backend   1,802 lines
                  ───────────
                  9,580 lines implementing ONE pattern three times
```

- **Drift is real, not hypothetical.** `cache.shared` existed in two of the three,
  so opshub-develop ran its own ElastiCache node at ~$15/month for services pinned
  at `min_count = 0`.
- **One state owns the database AND the ECS services.** §17b records the twelve
  minutes of downtime on 2026-09-14 spent learning what `tofu destroy` does to a
  database when it was only meant to remove compute.
- Each `_shared` additionally carries its own `ecr` and `iam_oidc` — three copies
  of the deploy-role pattern.

**The counter-argument is good, and it loses on team size.** Service teams owning
their own resources, and a migration shipping atomically with the code that needs
it, is the right answer at thirty engineers. At three there are no ownership
boundaries to respect — only three copies to keep in sync, and the measurement
above says they are not in sync.

### Retirement order

§17 migrates one product at a time. For each: write `infra/live/<product>-<env>`,
apply it, let it run, **then** delete that product's `infra/`. Not before.

The `_shared` stacks go last, because they hold the ECR repositories the images
live in — those move to the new estate rather than being deleted with the rest.

### There are two consolidation paths and only one is being run

`product-service` (`tf-modules`, 0.1.0, unconsumed) was extracted to collapse the
three `infra/modules/stack` copies on ECS.
[`product-service-extraction.md`](./product-service-extraction.md) is **SUPERSEDED**:
running it means migrating three products onto a module that §17 then deletes with
the ECS estate.

`product-profile` (`tf-modules`, v0.1.0) is the same consolidation for EKS, and it
is the one being adopted. `product-service` stays at 0.x, unconsumed, and is
deleted with ECS.

## Target state

```
tf-modules     versioned modules only
infra          live/<name>-<env>, one level, every stack
                 + live/<product>-shared   ECR and deploy roles, once, not 3x
gitops         charts · values · platform · appsets
<product>      application code. No infra/.
```

See [`live/README.md`](../live/README.md) for the stack-naming rule and why the
directory depth is fixed.
