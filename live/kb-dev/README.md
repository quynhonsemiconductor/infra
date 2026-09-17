# `infra/live/<product>-<env>`

One stack per product per environment, flat under `live/` like every other stack
— see `live/README.md` for why the depth is fixed. Each calls `product-profile`
once.

`kb-dev` is written; **the other five are written when their step in §17 arrives.**
Writing all six now would contradict the ordering the migration depends on — and
`ci/scripts/platform_conformance.py` reports the absent ones as *unpaired* rather
than failing, for exactly that reason. (It replaced
`gitops/scripts/check-size-agreement.py`, which this file used to name.)

## Copying this for the next product

Three identity values, then the capability set:

```hcl
product = "opshub"     # short slug — §7c
env     = "dev"        # dev | prod, never develop/production
size    = "s"          # MUST match gitops/values/opshub/dev.yaml
```

Everything else is a capability that **defaults to absent** (§6). A product with
no database sets nothing and gets no RDS, no secret, no IAM grant, no alarms.

## ⚠ One manual step, every apply

```bash
tofu output -raw role_settings_sql | psql "$ADMIN_URL"
```

The `cyrilgdn/postgresql` provider has no resource for role settings, so
`product-profile` emits the SQL instead of pretending. **Until it runs, nothing
bounds a noisy neighbour on the shared instance**, and the migrator carries the
30s application timeout rather than the 600s its Job needs (§5d).

It is idempotent, so running it again costs nothing.

## Why `kb-dev` is step 4, and no longer first

§17 was reordered on 2026-09-17: **rova goes first**, on the product owner's call
that learning the platform on a workload nobody would notice teaches the wrong
lessons. `live/rova-dev` is step 2; this is step 4.

kb keeps its place ahead of LMS and opshub because it is still the lowest-risk
migration in the estate — **qnsc-kb production has no state file**, so only dev
moves here — and because of what it exercises, below.

It also exercises more of the chart than anything else would: PgBouncer, the
migrator role, the `worker` kind, KEDA queue scaling, a 1.5 GB ONNX session that
needs a `startupProbe`, and the clamav sidecar.

## The one fact declared twice

`size` appears here and in `gitops/values/<product>/<env>.yaml`, and nothing else
does. CI compares them, because OpenTofu picks an RDS instance class from it while
the chart picks replica counts and PodDisruptionBudgets — and neither reads the
other's file at plan time (§7c).

A disagreement means a product is **protected at one tier and provisioned at
another**, and neither file is obviously the wrong one. That is why the check
fails rather than picking a winner.
