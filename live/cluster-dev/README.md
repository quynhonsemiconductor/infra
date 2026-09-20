# `cluster-dev`

**The reasoning for both clusters lives in [`../cluster-prod/README.md`](../cluster-prod/README.md).**
Read that. This file holds only what is specific to dev, and it is deliberately
short.

## Why this is a pointer and not a copy

It used to be a copy — byte-for-byte the same 5 KB as `cluster-prod/README.md` —
and on 2026-09-19 that cost something real. Three claims in the shared text were
corrected in `cluster-prod`'s copy: that the subnets are *resized* (AWS has no
subnet-resize operation), that `elastic_load_balancing.enabled` is `false` (the
code has never said that), and that system pods run on a general Spot pool (no
such pool existed until `gitops/platform/compute/` was written).

This copy kept all three. A reader who opened the dev README — the natural thing
to do when bringing up dev first — would have been told to resize subnets on a
VPC where that fails part-way through an apply.

Two documents that must agree and that nothing compares is the same failure shape
`ci/scripts/platform_conformance.py` exists for, one level up from code. The fix
for prose is not a checker; it is having one copy.

## What is specific to dev

```
subnets        runtime-dev's cluster tier — 10.90.{32,48,64}.0/20.
               NOT `private_subnet_ids`: that output is narrowed to
               `serving_azs`, two of three, which is right for ECS behind a
               single-AZ NAT and wrong for a cluster whose every rendered
               manifest spreads across three zones.
ArgoCD         does NOT run here. §2/§5b are hub-and-spoke: one instance in prod
               manages both. This stack grants prod's `argocd_role_arn` an EKS
               access entry — the only non-human principal with cluster-admin
               here.
CA output      `cluster_certificate_authority_data` exists for exactly one
               consumer: `gitops/platform/argocd/clusters.yaml`. The API server
               is private, so the hub cannot validate this cluster's certificate
               from any public chain and the registration needs the CA inline.
access         platform-admin has a STANDING cluster-admin entry, and developers
               get EKSEditPolicy — exec and port-forward. Both are the opposite
               of prod, and `cluster-prod/README.md` explains why.
first workload rova dev (§17, reordered 2026-09-17). `infra/live/rova-dev`.
```

## The order dev is brought up in

Dev is applied *after* prod, which reads backwards and is not:

```
cluster-prod   FIRST — it outputs argocd_role_arn
cluster-dev    consumes it
```

`cluster-dev` is `NOT_PLANNABLE` in `infra-plan.yml` until `cluster-prod` is
applied, for that reason — it reads a remote-state output that does not exist yet.
That is a dependency, not a CI failure, and the exclusion comment says so.
