# Finishing the rally → rova rename: rebuilding both RDS instances

Status: **module prerequisite merged pending, cutover not started.** Written 2026-09-13.

## The problem, and why it cannot be fixed in place

The rename created `rova-develop-db` and `rova-prod-db` DB subnet groups. AWS then refused to
move either instance into its new group:

```
InvalidVPCNetworkStateFault: You cannot move DB instance rova-develop to subnet group
rova-develop-db. The specified DB subnet group and DB instance are in the same VPC.
```

That is not a transient error and there is no flag to override it. A DB instance can only be
moved to a subnet group in a *different* VPC, so the only way into the correctly-named group
is to create a new instance. Both instances therefore still sit in the old groups:

| instance | subnet group | parameter group |
|---|---|---|
| `rova-develop` | `rally-develop-db` | `rova-develop-pg17` `in-sync` — repaired by hand 2026-09-13 |
| `rova-prod` | `rally-prod-db` | `rova-prod-pg17` **`pending-reboot`** |
| `opshub-develop` | `opshub-develop-db` | `in-sync` |
| `opshub-prod` | `opshub-prod-db` | `in-sync` |
| `qnsc-kb-develop` | `qnsc-kb-develop-db` | `in-sync` |

**The subnet groups are functionally identical.** Measured: `rally-prod-db` and `rova-prod-db`
both hold `vpc-00e1ded731c41a27e` and exactly the same three subnets across 1a/1b/1c. Same for
develop. So this rebuild buys a *name*, and on its own that would not justify touching
production.

## What makes it worth doing anyway

The failure was never contained to the subnet group. Terraform sends
`db_subnet_group_name` and `db_parameter_group_name` in the **same** `ModifyDBInstance` call,
so AWS rejected both together. CloudTrail shows six applies — 7, 8 and 13 September — every
one failing identically. Two mechanisms hid it:

* `|| true` on pass 1 of the two-pass apply discards the exit code.
* `-refresh=false` on the converge pass means pass 2 never reads the real state of that
  resource, so it reports convergence while the instance carries neither change.

The visible cost was that `rova-develop` ran on `default.postgres17` — no
`pg_stat_statements`, no slow-query logging — while its three siblings were correct. Nobody
could have noticed from a plan: state and config agreed, so there was no diff to see.

`rova-prod` is still `pending-reboot`, which means its static parameters
(`shared_preload_libraries = pg_stat_statements`) are very likely not loaded. **Production has
no query-performance tooling.** That is the actual reason to do this.

## Why a rebuild and not a reboot

A reboot was tried on `rova-develop` first and did nothing, because the pending change could
never be applied — the modify call itself was being rejected. The eventual repair was a
`modify-db-instance` carrying *only* the parameter group, which succeeded first time and
confirms the diagnosis.

That repair was done with the AWS CLI, **outside OpenTofu**. It is recorded here because it
is a deviation: it was justified only because the pipeline provably could not make the change,
and because it moved AWS toward what state already claimed. It is not a pattern to copy.

A restore, by contrast, comes up correct on both counts. Verified 2026-09-13 by restoring
rova-prod's snapshot into a live instance:

```
subnet group   rova-prod-db          <- the correct group
param group    rova-prod-pg17  in-sync   <- NOT pending-reboot
engine         postgres 17.9
storage        30 GB gp3, encrypted
master secret  NONE
```

So the rebuild fixes the parameter group as a side effect. The test instance was deleted
afterwards; it was holding a copy of production data that nothing tracked.

## The two things that change, and will break the app if missed

**The endpoint.** `rova-prod.cdu0osqeojxv.ap-southeast-1.rds.amazonaws.com` — the middle
component is instance-specific and is regenerated. There is no way to preserve it.

**The master secret ARN.** `manage_master_user_password` is *not* carried through a restore:
the restored instance keeps the password baked into the snapshot and arrives with no managed
secret at all. Re-enabling it mints a **new** secret with a **new ARN**
(today's is `rds!db-72b35adf-eded-4097-b391-02d1319d1e8e-n0pjLs`).

Both values reach the application through task definitions rendered by this stack, so both are
reconciled by the same apply that rebuilds the instance — provided the apply is allowed to
complete. An apply that stops halfway leaves services pointing at a database that no longer
exists, authenticating with a secret that no longer governs anything.

## Preconditions

- [x] `tf-modules` PR #139 merged and released — adds `snapshot_identifier`, and fixes
      `final_snapshot_identifier` so turning off `deletion_protection` no longer silently
      removes the final snapshot. Without that second fix this procedure destroys a
      production database with no safety net.
- [x] Two verified manual snapshots: `rova-prod-pre-migration-20260912` and
      `rova-prod-pre-subnet-migration-20260913-2035`, both `available`, both 30 GB.
- [x] Restore rehearsed end to end, not merely snapshot-listed.
- [x] 30-day automated backup retention with PITR (`LatestRestorableTime` current).
- [ ] Someone watching who can redeploy rova if the cutover stalls.

## Order: develop first, and treat it as the rehearsal

Develop carries disposable data and the same defect, so it is a free rehearsal of the exact
procedure. **Do not skip it** — the value is not the dev fix, it is discovering there whatever
this document has got wrong.

1. Pin rova to the new `rds` module version.
2. `-replace=module.stack.module.rds.aws_db_instance.this` on `infra/live/develop`.
   No `snapshot_identifier` needed: dev data is disposable and rova has `seed_on_deploy`.
3. Confirm the new instance is in `rova-develop-db` with its parameter group `in-sync`.
4. Confirm api and worker come back healthy against the new endpoint and secret.
5. Only then proceed to prod.

## Prod cutover

1. Fresh snapshot immediately before starting. The two existing ones are hours old by now;
   take another so the rollback point is minutes rather than hours of data.
2. Set `deletion_protection = false` **and** `skip_final_snapshot = false` in
   `infra/live/prod`. Apply. Verify the plan changes *only* those two fields — with the
   module fix these no longer interact, but confirm rather than assume.
3. Set `snapshot_identifier` to the snapshot from step 1.
4. `-replace=module.stack.module.rds.aws_db_instance.this`. This destroys the old instance
   (taking `rova-prod-final`) and restores the new one into `rova-prod-db`.
5. Let the apply finish. Task definitions pick up the new endpoint and secret ARN.
6. Restore `deletion_protection = true`, drop `snapshot_identifier` from config. It is under
   `ignore_changes`, so removing it cannot trigger another replacement — but re-read that
   argument's comment before trusting this sentence.
7. Redeploy rova prod and verify: api healthy, worker draining its queue, migrations
   consistent, `pg_stat_statements` present.

## Rollback

Before step 4 completes, rollback is: restore the step-1 snapshot to a new instance and point
the stack at it. After step 4, the old instance is gone and `rova-prod-final` plus the step-1
snapshot are the recovery path — which is why step 2 must be verified rather than assumed.

The failure that actually matters is not data loss; four independent copies exist. It is
**services running against a stale endpoint or secret**, which looks like an outage while the
database is perfectly healthy. Check the task definition before debugging the database.

## Cleanup once both instances are rebuilt

Everything below is dead only *after* the rebuild, and is why the rebuild is worth doing at
all: it is the difference between renaming a product and finishing the rename.

| item | state | action |
|---|---|---|
| `rally-prod-db` subnet group | orphaned once prod is rebuilt | delete |
| `rally-develop-db` subnet group | orphaned once dev is rebuilt | delete |
| `/aws/rds/instance/rally-prod/postgresql` | log group for a gone instance, retention 90 | delete after exporting anything wanted |
| `/aws/rds/instance/rally-develop/postgresql` | same, retention 7 | delete |
| `rds!db-72b35adf-…` master secret | RDS deletes with the instance | verify, do not delete by hand |
| `rova-prod-pre-migration-20260912` | superseded | delete once prod is verified healthy |
| `rova-prod-pre-subnet-migration-20260913-2035` | superseded | keep 30 days, then delete |
| `|| true` in `rova/.github/workflows/infra-apply.yml` | only existed for this failure | remove, restoring real failure detection |
| `-refresh=false` on the converge pass | same | remove, and let plans see reality again |

The last two are the point. They were reasonable workarounds for an unfixable AWS constraint,
but between them they swallowed a genuine six-day failure. Removing them is what stops the
next one hiding.

**A `rally`-named resource sweep across every service is still outstanding** — the run was cut
short by an expired MFA session. Complete it before declaring the rename done: log groups,
subnet groups, parameter groups, secrets, SNS topics, SQS queues, ECR repositories, security
groups and IAM roles.
