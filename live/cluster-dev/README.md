# `cluster-dev` / `cluster-prod`

The two EKS clusters. §2 of `infra/docs/kubernetes-platform-design.md`.

> **⚠ BLOCKED.** `infra/docs/data-residency-question.md` must be answered before
> either is applied. Answer C — all Vietnamese personal data must stay in
> Vietnam — means a different **cloud provider**, not a different region, because
> AWS has no Vietnam region. Creating clusters first is the one sequence that
> cannot be recovered from cheaply (§18).

## Apply order

```
1  runtime-dev / runtime-prod    subnets resized /24 → /20, prefix delegation (§3)
2  organization                  the Identity Center permission sets this consumes
3  cluster-prod                  FIRST — it outputs argocd_role_arn
4  cluster-dev                   consumes it
5  bootstrap ArgoCD in prod       then apply gitops/apps/root.yaml
```

**The subnet resize is not optional and not reversible under load.** §3:

> "The AWS VPC CNI assigns every pod a *real subnet IP*… At fifteen services with
> replicas, plus Alloy on every node, plus system workloads, that is not enough —
> and exhaustion presents as pods stuck in `ContainerCreating` with no obvious
> cause."

§15c lists it as failure #2, arriving at roughly fifteen services.

## What differs between the two

Everything except these is identical, and the differences are the reason there are
two stacks rather than one with a flag:

```
                      dev                          prod
platform-admin        STANDING cluster-admin       NO ENTRY AT ALL
break-glass           —                            cluster-admin, MFA, CloudTrail alert
developer             EKSEditPolicy — exec, port-forward   EKSViewPolicy — NO EXEC
ArgoCD                an access entry, granted     runs here; holds an IRSA role
                      to prod's IRSA role          that dev grants
```

**No exec on production is the control that matters most** (§10b):

> "An exec bypasses every audit trail this platform has: environment variables
> carry the secrets ESO injected, the filesystem is writable, and nothing about any
> of it appears in git. A platform whose entire promise is 'the cluster is
> reproducible from git' (§13) has that promise broken by one shell."

Debugging production is logs, traces and profiles — which is what §9 spent six
signals building, and the point of having built them.

## Access entries, not `aws-auth`

The `aws-auth` ConfigMap is the legacy mechanism: it is edited in-cluster rather
than in OpenTofu, and **a malformed edit locks everyone out with no way back in.**
Access entries are an API, so they belong here under §7's rule — they outlive a
deploy.

`bootstrap_cluster_creator_admin_permissions = false`: whoever runs `tofu apply`
does not silently become a cluster admin.

## ArgoCD reaches both clusters, and that is stated rather than hidden

§2 calls separate clusters non-negotiable because a bad admission webhook or CRD
upgrade must not reach production. ArgoCD is the one exemption: it runs in prod and
manages dev remotely (§5b), which is how a deployer has to work.

So the isolation claim is *"no shared control plane **except the deployer**"*, and
ArgoCD's own RBAC and repository access are the thing to review carefully. It is
the only non-human principal with cluster-admin on dev.

## Auto Mode

`compute_config.enabled = true`. §14 chose it, and the number in that section was
**wrong by 4.7×** — "$12/month on ~$100 of nodes" was priced at us-east-1 against
a model with no node-overhead allowance. Re-priced it is about **$56/month**.

The conclusion survives: three engineers should not be rotating AMIs, and §2b
records that upgrade work is the first thing a small team defers. **Re-decide after
§15d**, when the node bill is measured rather than modelled.

Auto Mode manages **nodes**. The control-plane version is still yours to bump
(§2b): one minor per quarter, always N-1 or newer, never N-3, dev first, observe a
week, then prod.

## Things that are deliberately absent

```
an ALB                     §3 — Cloudflare Tunnel replaces the load balancer.
                           elastic_load_balancing.enabled = false
a public API endpoint      endpoint_public_access = false. "No inbound surface is
                           the strongest property of the current architecture"
a dedicated system pool    §2 — system pods run on the general Spot pool with PDBs
                           and topology spread. Instance-family diversity beats two
                           on-demand nodes, because what kills a Spot workload is a
                           CORRELATED reclaim across one capacity pool
controllerManager /        high volume, and nothing in §10b's alert list reads them
scheduler logs
```

## Log retention

90 days, created explicitly rather than letting EKS create it — so the retention is
ours and the cost is visible. §15 budgets ~$15/month for both clusters, and §10b
alerts on `pods/exec`, secret reads outside ESO's service account, RBAC changes and
break-glass assumption.
