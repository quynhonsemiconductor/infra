# `cluster-dev` / `cluster-prod`

The two EKS clusters. §2 of `infra/docs/kubernetes-platform-design.md`.

> **⚠ BLOCKED.** `infra/docs/data-residency-question.md` must be answered before
> either is applied. Answer C — all Vietnamese personal data must stay in
> Vietnam — means a different **cloud provider**, not a different region, because
> AWS has no Vietnam region. Creating clusters first is the one sequence that
> cannot be recovered from cheaply (§18).

## Apply order

```
1  runtime-dev / runtime-prod    the /20 CLUSTER subnets are ADDED (§3, task 0.6)
2  organization                  the Identity Center permission sets this consumes
3  cluster-prod                  FIRST — it outputs argocd_role_arn
4  cluster-dev                   consumes it
5  bootstrap ArgoCD in prod      platform/compute FIRST, then gitops/apps/root.yaml
```

**Step 5's order is not cosmetic.** ArgoCD's own pods ask for
`karpenter.sh/capacity-type: spot`, and Auto Mode's built-in `general-purpose`
pool is on-demand-only and amd64-only — see `compute_config` in `main.tf`. Apply
`gitops/platform/compute/` before ArgoCD, or ArgoCD never schedules and there is
nothing running to reconcile `root.yaml`.

**The subnets are ADDED, not resized — and the earlier wording here was wrong.**
This file used to say "subnets resized /24 → /20" and call the resize "not
optional and not reversible under load". It is worse than that: it is **not
available**. AWS has no operation that resizes a subnet, `cidr_block` on
`aws_subnet` forces replacement, and `runtime-prod` is applied with production
ECS ENIs in its private subnets — so the plan is a destroy the EC2 API refuses
part-way, and the only way to make it succeed is to drain production first.

What actually happens is a fourth subnet tier at /20 (`cluster_subnet_cidrs`),
routed through the existing private route tables so it inherits NAT egress and
§3's free S3 gateway endpoint. The ECS /24s do not move. That also makes the step
reversible, which a resize never was.

§3 on why /20 at all:

> "The AWS VPC CNI assigns every pod a *real subnet IP*… At fifteen services with
> replicas, plus Alloy on every node, plus system workloads, that is not enough —
> and exhaustion presents as pods stuck in `ContainerCreating` with no obvious
> cause."

§15c lists it as failure #2, arriving at roughly fifteen services. Auto Mode makes
a /24 worse than that reads: it reserves a **/28 per node up front**, so a /24 is
about fifteen nodes per AZ, shared with whatever ECS still holds.

## Prefix delegation is already on, and is not configurable

Task 0.6's second half — "the VPC CNI has prefix delegation enabled" — needs no
work and cannot be done. AWS: *"EKS Auto Mode defaults to using prefix delegation
(/28 prefixes) for pod networking"*, and *"Configuration options for the previous
AWS VPC CNI will not apply to EKS Auto Mode"*. Auto Mode explicitly does not
support warm IP / warm prefix / warm ENI or minimum-IP-target configuration.

So there is no `vpc-cni` addon to configure here, and adding one would be inert.
The only related knob is `advancedNetworking.ipv4PrefixSize: "32"` on a custom
NodeClass, which turns prefix delegation **off** in favour of one IP per pod — the
right choice for pod-sparse workloads at hundreds of nodes per AZ, and the wrong
one here.

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
                           BUT elastic_load_balancing.enabled = TRUE, because Auto
                           Mode rejects a mixed configuration: compute, block
                           storage and load balancing must all be true or all
                           false. It enables the CONTROLLER, not a balancer —
                           nothing is provisioned until something asks, and §3
                           routes through Gateway API behind the tunnel, so
                           nothing does. (This line used to claim `false`, which
                           the code has never said.)
a public API endpoint      endpoint_public_access = false. "No inbound surface is
                           the strongest property of the current architecture"
a dedicated system pool    §2 — system pods run on the general SPOT pool with PDBs
                           and topology spread. Instance-family diversity beats two
                           on-demand nodes, because what kills a Spot workload is a
                           CORRELATED reclaim across one capacity pool.
                           THAT POOL IS gitops/platform/compute/nodepools.yaml, and
                           until it was written it did not exist anywhere — this
                           line described an intention, not a resource. Auto Mode's
                           built-in `general-purpose` is on-demand-only and
                           amd64-only and cannot be modified.
controllerManager /        high volume, and nothing in §10b's alert list reads them
scheduler logs
```

## Log retention

90 days, created explicitly rather than letting EKS create it — so the retention is
ours and the cost is visible. §15 budgets ~$15/month for both clusters, and §10b
alerts on `pods/exec`, secret reads outside ESO's service account, RBAC changes and
break-glass assumption.
