# `data-dev` / `data-prod`

The shared data tier. §5, §5d.

**This did not exist before.** Each product's own `infra/` owned its database —
which is the duplication this platform exists to remove, and, per §17b, exactly
why those stacks must be **shrunk rather than destroyed**: one Terraform state
owns both the database and the ECS services beside it.

## Who is on the shared instance

```
DEV     everything. No exceptions.
        "Nothing in a development environment justifies an instance: not restore,
         not noisy neighbours, not upgrade timing."

PROD    opshub · LMS · solodesk · ai-dev-kit
        rova and qnsc-kb are DEDICATED and create their own via product-profile
```

## The production split is not a cost decision

§5 measured the alternatives and the gap is about **$40/month** — too small to
decide on. It is decided on **restore granularity**:

> RDS snapshots and point-in-time restore operate on an **instance**, not on a
> database. If opshub needs a restore because someone deleted a table, restoring
> the instance drags LMS, solodesk and ai-dev-kit back to the same moment. The way
> out is restoring to a *new* instance and dumping one database out of it —
> acceptable on a calm afternoon, miserable at 02:00 during the incident that
> created the need.

The products here have no independent restore requirement, no meaningful traffic
and no workload shape of their own. One that develops any of those **graduates** —
`mode = "shared"` becomes `"dedicated"` in its own `product-profile` call. That is
the whole point of the capability being a value rather than a module.

## Three instances in dev, two in prod

```
qnsc-shared-dev    the dev database for every product
qnsc-preview       §11 — a database per pull request. NOT the dev instance:
                   "previews must not pollute dev data", and a preview runs
                   migrations from an unreviewed branch
qnsc-shared-dev    cache. One instance, database index per product
```

## The cache stays, and §5d had to be corrected to say so

An earlier draft said to remove Redis. The measurement said otherwise:

```
qnsc-kb        Celery broker (broker = settings.REDIS_URL) + rate limiting
rova · opshub  app-platform/packages/platform-cache, plus ioredis in platform-http
```

**Celery must not move to SQS.** The SQS transport drops `celery inspect` and
`celery control`, has no priority queues, and caps ETA at 15 minutes. Worker
introspection during an incident is worth more than $12/month to a team of three.

So the decision is **consolidation, not removal** — about $8/month. The reason to
do it anyway is that it stops the line growing with product count, which is the
property every item in §15b is chosen for.

Production keeps 3 days of cache snapshots: losing it loses qnsc-kb's queued
Celery tasks, which is *work* rather than a cold start.

## What `product-profile` needs from here

```hcl
shared_postgres = {
  host       = data.terraform_remote_state.data.outputs.postgres_host
  identifier = data.terraform_remote_state.data.outputs.postgres_identifier
}
```

And then **`role_settings_sql` must be applied**. `product-profile` emits it as an
output because the `cyrilgdn/postgresql` provider has no resource for role
settings — and **until it runs, nothing bounds a noisy neighbour on this
instance** (§5d). That is the one manual step in the data tier, and it is manual
on purpose rather than through a `null_resource` that would leave state
disagreeing with reality.

## Apply order

```
runtime-{dev,prod}   the VPC, subnets and security groups this consumes
data-{dev,prod}      here
cluster-{prod,dev}   §7's boundary: this stack outlives a deploy, so OpenTofu owns it
product-profile      per product, per environment — the databases and roles ON this
```
