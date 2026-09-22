# ─────────────────────────────────────────────────────────────────────────────
# cluster-prod — the EKS dev cluster.
#
# §2: "Separate clusters for dev and prod is not negotiable." Namespace-only
# separation shares a control plane, a CNI, and every cluster-scoped resource —
# so a bad admission webhook or a CRD upgrade reaches production. $73/month buys
# real isolation and it is the cheapest isolation available.
#
# One component is exempt and it is stated rather than hidden: ARGOCD REACHES BOTH
# CLUSTERS BY DESIGN. It runs in prod and manages dev remotely (§5b), which is the
# conventional hub-and-spoke arrangement and how a deployer has to work. The
# isolation above is therefore "no shared control plane EXCEPT the deployer".
#
# ArgoCD runs HERE and manages both clusters (§5b). That makes this stack the one
# holding credentials into dev, so its own RBAC and repository access are the thing
# to review carefully — §2 footnotes the isolation claim for exactly this reason.
#
# ⚠ BLOCKED ON THE RESIDENCY ANSWER. `infra/docs/data-residency-question.md` must
# be answered before this is applied. Answer C — all Vietnamese personal data must
# stay in Vietnam — means a different CLOUD PROVIDER, not a different region, and
# AWS has no Vietnam region. Creating clusters first is the one sequence that
# cannot be recovered from cheaply (§18).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    # §2b — `data "tls_certificate"` below reads the OIDC issuer's thumbprint for
    # the IRSA provider. Without a constraint OpenTofu installs whatever `tls` is
    # latest at `init` time, which is the unpinned-version class §2b closes.
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/cluster-prod/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = local.region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/platform-prod/terraform.tfstate"
    region = "ap-southeast-1"
  }
}


# §7 — kms_key_arn lives in `bootstrap`, NOT in the network stack. Reading it from
# the wrong remote state is invisible to `terraform validate`: outputs are only
# resolved at plan time, so a name that does not exist looks fine until the first
# plan. Found in review, 2026-09-16.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  region = "ap-southeast-1"
  env    = "prod"
  name   = "qnsc-prod"

  # §2b — "EKS ships a new Kubernetes minor roughly three times a year, and each
  # leaves standard support after about fourteen months, after which AWS charges
  # extended-support rates."
  #
  # Cadence: one minor per quarter, always N-1 or newer, never N-3. Dev first,
  # observe for a week, then prod. Keep this in step with gitops/versions.yaml —
  # §2b's compatibility check is one diff across the two.
  kubernetes_version = "1.33"

  tags = {
    env       = local.env
    ManagedBy = "cluster-prod"
    Layer     = "platform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# NO S3 GATEWAY ENDPOINT HERE — the network stack already owns one.
#
# §3's requirement is unchanged and still met: "ECR image layers are served from
# S3, so every image pull crosses NAT and is billed per gigabyte. August's ECR
# bill was ~94% DATA TRANSFER", and Kubernetes makes it worse because nodes pull on
# every scale-out and every Karpenter consolidation, not only on deploy.
#
# What changed is WHO CREATES IT. Task 0.4 put the endpoint in this stack when the
# clusters lived in the ECS VPCs. They now have their own — `live/platform-{dev,prod}`
# — and `tf-modules/modules/network` has always created `aws_vpc_endpoint.s3` and
# attached it to every private route table, which the /20 cluster subnets share.
#
# Creating a second one is not additive, it is an error. AWS refuses:
#
#   Error: creating EC2 VPC Endpoint (com.amazonaws.ap-southeast-1.s3):
#   RouteAlreadyExists: route table rtb-05611b60b0132006d already has a route with
#   destination-prefix-list-id pl-6fa54006
#
# Found 2026-09-20 on the first apply of this stack. `data.aws_route_table.private`
# went with it — it existed only to feed the endpoint's route_table_ids.
# ─────────────────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────────────────
# Pod → data tier. WITHOUT THIS, NOTHING CONNECTS.
#
# The `network` module writes `rds_from_app` and `cache_from_app` ingress rules
# that admit traffic from its OWN `app` security group — the one it was written
# for, when the only clients were ECS tasks. EKS Auto Mode does not use that
# group: it attaches the EKS-MANAGED CLUSTER security group to every node, and
# `gitops/platform/compute/nodeclass.yaml` selects exactly that group by its
# `kubernetes.io/cluster/<name>: owned` tag.
#
# So out of the box a pod's packets arrive at the database's security group from a
# source it does not admit, and are dropped. The failure is the worst shape there
# is to debug: no rejection, no log line on either side, just a TCP connect that
# hangs until the client's timeout — which for the app role is 30s, and for the
# migrator 600s. Nothing in `tofu plan`, `helm template` or admission says a word.
#
# Found 2026-09-19 while giving the platform its own VPC, which is what made the
# question visible: the old VPC's rules had been written for ECS and inherited by
# accident, not by design.
#
# THE RULE BELONGS HERE, not in the network module or the data stack, because the
# cluster security group is created BY the cluster — it does not exist until this
# stack applies, and only this stack knows its id. That also makes the grant
# readable as what it is: "this cluster may reach the data tier", one hop, in the
# file that creates the cluster.
locals {
  # `vpc_config[0].cluster_security_group_id` is the group EKS creates and
  # attaches to Auto Mode nodes. NOT `aws_security_group.*` — this stack creates
  # none — and not the network module's `app` group.
  cluster_sg_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_cluster" {
  security_group_id            = data.terraform_remote_state.network.outputs.sg_rds_id
  referenced_security_group_id = local.cluster_sg_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Postgres from EKS pods (${local.name})"

  tags = merge(local.tags, { Name = "${local.name}-rds-from-cluster" })
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_cluster" {
  security_group_id            = data.terraform_remote_state.network.outputs.sg_cache_id
  referenced_security_group_id = local.cluster_sg_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Valkey from EKS pods (${local.name})"

  tags = merge(local.tags, { Name = "${local.name}-cache-from-cluster" })
}

# ─────────────────────────────────────────────────────────────────────────────
# The cluster
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  # checkov:skip=CKV_AWS_37: control-plane logs bill per GB in CloudWatch, and §9
  #   sends this estate's telemetry to Grafana Cloud. api, audit and authenticator
  #   are the three that answer "who did this and were they allowed to";
  #   controllerManager and scheduler are high-volume and answer a question nobody
  #   here has asked. Add them when there is a scheduling problem to debug.
  name     = local.name
  version  = local.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # §14 — AWS manages nodes, AMIs, patching and upgrades at roughly a 12% premium.
  # An earlier draft priced that at "$12/month on ~$100 of nodes"; re-priced
  # against ap-southeast-1 with a realistic overhead allowance it is about $56 —
  # wrong by 4.7x. The conclusion survives: two or three engineers should not be
  # rotating AMIs, and §2b records that upgrade work is the first thing a small
  # team defers. Re-decide after §15d, when the node bill is measured.
  #
  # NOTE: Auto Mode manages NODES. The control-plane version above is still ours
  # to bump (§2b).
  # REQUIRED BY AUTO MODE, and AWS refuses the create without it:
  #
  #   InvalidParameterException: When EKS Auto Mode is enabled,
  #   bootstrapSelfManagedAddons must be set to false.
  #
  # The provider defaults it to TRUE, which asks EKS to install the self-managed
  # CoreDNS, kube-proxy and VPC CNI addons — exactly the three things Auto Mode
  # manages itself. Auto Mode runs CoreDNS as a node-level system service rather
  # than a Deployment and builds the CNI into the AMI, so the two models cannot
  # coexist: this is the same "Auto Mode rejects a mixed configuration" rule that
  # forces elastic_load_balancing below.
  #
  # Found 2026-09-20 on the first apply. It is not inferable from the resource
  # schema — the default is simply wrong for Auto Mode.
  bootstrap_self_managed_addons = false

  compute_config {
    enabled = true

    # `general-purpose` IS NOT SUFFICIENT ON ITS OWN, and it is kept for two
    # narrow reasons rather than as the estate's node pool.
    #
    # AWS documents this built-in pool as amd64 ONLY, on-demand ONLY, C/M/R,
    # generation 5+, and NOT MODIFIABLE — enable or disable, nothing else. Every
    # pod this estate renders asks for something it cannot give: `arch: arm64`
    # across every product values file, and `capacity-type: spot` for ArgoCD, ESO,
    # KEDA, Alloy, Envoy Gateway and cloudflared. Applied alone, this pool yields a
    # cluster on which ARGOCD ITSELF NEVER SCHEDULES, so nothing is running to
    # reconcile `gitops/apps/root.yaml` — the one thing installed by hand.
    #
    # The pools that do the work are custom, and they live in
    # `gitops/platform/compute/` because a NodePool is a Kubernetes object, not an
    # AWS one (§7: OpenTofu owns what outlives a deploy; ArgoCD owns the rest).
    # `ci/scripts/platform_conformance.py --only schedulable` fails if a rendered
    # nodeSelector has no pool that can satisfy it.
    #
    # WHY KEEP IT ENABLED AT ALL:
    #   1. Enabling at least one built-in pool is what makes AWS provision the
    #      `default` NodeClass. Disabling all of them means creating a NodeClass
    #      AND an EKS access entry of type EC2 for its role by hand — two more
    #      bootstrap steps, before ArgoCD exists to do them.
    #   2. It is a floor of last resort for amd64/on-demand system workloads if a
    #      custom pool is ever misconfigured. It costs nothing while idle:
    #      Karpenter provisions from a pool only when a pod matches it.
    #
    # `system` stays OFF — §2, no dedicated on-demand system pool. It also carries
    # a `CriticalAddonsOnly` taint nothing here tolerates, so enabling it would
    # schedule nothing new.
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.node.arn
  }

  kubernetes_network_config {
    # TRUE, though §3 provisions no load balancer — Cloudflare Tunnel replaces it.
    #
    # Not a choice. EKS Auto Mode rejects a mixed configuration outright:
    # "compute_config.enabled, kubernetes_networking_config.elastic_load_balancing
    # .enabled, and storage_config.block_storage.enabled must all be set to either
    # true or false". Compute and block storage are both required (§14, §13), so
    # this follows them.
    #
    # It enables the CONTROLLER, not a load balancer. Nothing is provisioned until
    # something asks for one, and §3 routes through Gateway API behind the tunnel,
    # so nothing does — no Service of type LoadBalancer, no Ingress, no ALB and no
    # bill. If a future service does ask, that is the review moment: §3's whole
    # argument is that the tunnel removes the load balancer, not that the estate
    # cannot have one.
    elastic_load_balancing { enabled = true }
  }

  storage_config {
    block_storage { enabled = true }
  }

  vpc_config {
    # The /20 cluster tier in `platform-prod` — this cluster's OWN VPC.
    #
    # This used to read `runtime-prod`'s subnets, and moving it is what makes
    # Phase 5 a deletion instead of surgery. While the new platform's data tier
    # lived inside the old VPC, `runtime-prod` could never be destroyed; now the
    # Kubernetes estate is self-contained and the whole ECS estate can go at once.
    # See `live/platform-prod/main.tf` for the full argument and for what the
    # trade costs — a real data migration, because §17b's "same database" cutover
    # is no longer what happens.
    #
    # Sized for Auto Mode's pod networking: it reserves a /28 per node up front,
    # so a /24 exhausts at roughly fifteen nodes per AZ, which is §15c's failure
    # #2 and presents as pods stuck in `ContainerCreating`.
    #
    # An EMPTY list here means `platform-prod` has not been applied yet.
    # `aws_eks_cluster` rejects that at PLAN time rather than creating something
    # subtly wrong, which is the right order to fail in.
    subnet_ids = data.terraform_remote_state.network.outputs.cluster_subnet_ids

    # §3 — "no inbound surface is the strongest property of the current
    # architecture." The API server is private; humans reach it through
    # Identity Center (§10b), not over the internet.
    endpoint_private_access = true
    # Derived, never hardcoded — see var.public_access_cidrs. Empty list means
    # private-only, which is what the committed configuration always says.
    endpoint_public_access = length(var.public_access_cidrs) > 0
    public_access_cidrs    = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : null
  }

  # §10b — control-plane logs are OFF by default, which means the record of who did
  # what to the cluster does not exist unless it is turned on BEFORE it is needed.
  # `controllerManager` and `scheduler` are deliberately omitted: high volume, and
  # nothing in §10b's alert list reads them.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Envelope encryption for Kubernetes Secrets at rest in etcd, under the same CMK
  # that encrypts the log group and RDS storage.
  #
  # §8 routes application secrets through External Secrets Operator, but ESO's
  # output IS a native Secret — it syncs Secrets Manager INTO etcd rather than
  # around it. So every secret the platform handles lands here, and without this
  # block they sit under the AWS-managed key with no CMK boundary and no
  # CloudTrail record tying a decrypt to this cluster.
  #
  # SET AT CREATION. Enabling envelope encryption on a live cluster is a one-way
  # operation AWS will not undo, so it belongs in the first apply — which is where
  # this is, the cluster does not exist yet.
  encryption_config {
    provider {
      key_arn = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
    }
    resources = ["secrets"]
  }

  access_config {
    # §10b — ACCESS ENTRIES, not the aws-auth ConfigMap. The ConfigMap is the
    # legacy mechanism, it is edited in-cluster rather than in OpenTofu, and a
    # malformed edit locks everyone out with no way back in. Access entries are an
    # API, so they belong here under §7's rule: they outlive a deploy.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  tags = merge(local.tags, { Name = local.name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# §10b — 90 days. Created explicitly rather than letting EKS create it, so the
# retention is ours and the cost is visible (§15 budgets ~$15/month for both
# clusters).
resource "aws_cloudwatch_log_group" "cluster" {
  # checkov:skip=CKV_AWS_338: 90 days, not a year. §15 declines a year of
  #   CloudWatch ingestion everywhere in this estate; audit events worth keeping
  #   longer reach Grafana Cloud through §9, which is where they are queried from.

  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = 90
  # NO kms_key_id, and this is the SAME decision tf-modules/modules/rds records at
  # length for its own log groups — reached here the hard way on 2026-09-20:
  #
  #   Error: creating CloudWatch Logs Log Group (/aws/eks/qnsc-prod/cluster):
  #   AccessDeniedException: The specified KMS key does not exist or is not allowed
  #   to be used with Arn 'arn:aws:logs:...:log-group:/aws/eks/qnsc-prod/cluster'
  #
  # CloudWatch Logs encrypts a group by assuming the CALLER's grant on the key, so
  # the KEY POLICY must allow logs.<region>.amazonaws.com with a
  # kms:EncryptionContext:aws:logs:arn condition. The product CMK is written for
  # RDS, ECR and Secrets Manager and grants Logs nothing. No log group in this
  # account uses a CMK, so setting it here made this the odd one out AND required a
  # key-policy change nobody asked for. Logs are encrypted at rest with an
  # AWS-managed key regardless.
  tags = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# IRSA — the OIDC provider every product role trusts (§8)
# ─────────────────────────────────────────────────────────────────────────────

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = local.tags
}

# ─────────────────────────────────────────────────────────────────────────────
# The bootstrap keyhole — §3, §10b
#
# §3 calls "no inbound surface" the strongest property of the current
# architecture, and `endpoint_public_access = false` is how the cluster keeps it.
# That is correct in steady state and it makes the cluster IMPOSSIBLE TO BOOTSTRAP.
#
# Found 2026-09-20, on the first apply: `gitops/platform/` is applied with kubectl,
# ArgoCD is installed with helm, and both need to reach the API server. With a
# private-only endpoint the only paths in are an instance inside the VPC or a VPN —
# and there is no instance, because `platform-prod` runs a NAT GATEWAY rather than a
# NAT instance, so there is no SSM target either. `kubectl` simply times out.
#
# ── WHY A VARIABLE AND NOT AN EDIT ──────────────────────────────────────────
#
# The obvious fix is to flip `endpoint_public_access` to true, bootstrap, and flip it
# back. The problem is the middle state: a committed `true` that somebody forgets to
# revert, in the file that is supposed to be the record of the cluster being closed.
#
# So the DEFAULT IS CLOSED and opening it is `-var`, which lives in a shell history
# and a CloudTrail entry rather than in `main.tf`. There is no way to accidentally
# commit the open state, because the open state is not written down.
#
#     tofu apply -var 'public_access_cidrs=["203.0.113.4/32"]'    # bootstrap
#     tofu apply                                                  # closed again
#
# An empty list means private-only, which is what `git` always shows.
variable "public_access_cidrs" {
  type    = list(string)
  default = []

  description = <<-EOT
    CIDRs allowed to reach the PUBLIC API endpoint, for bootstrap only.

    EMPTY means the endpoint is private, which is the committed state and the one
    §3 wants. Pass a /32 to open a keyhole for `kubectl` and `helm` while applying
    `gitops/platform/`, then apply again with no `-var` to close it.

    NEVER a broad range. `0.0.0.0/0` here would put the API server of a cluster
    with cluster-admin access entries on the open internet, which is the exact
    property §3 spent the Cloudflare Tunnel design avoiding.
  EOT

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is refused. Pass the single /32 you are bootstrapping from — §3, §10b."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# The cluster's Cloudflare Tunnel — §3
#
# §3 replaces the load balancer with a tunnel, so this IS the cluster's ingress.
# `gitops/platform/cloudflared` runs three connectors against it with one catch-all
# rule, and reads its token from `qnsc/<env>/platform/cloudflared-token` through ESO.
#
# ── WHY THIS IS NOT CREATED IN THE DASHBOARD ────────────────────────────────
#
# `modules/cf-tunnel`'s own header says it "replaces the 'create it in the dashboard
# and paste the token into a secret' step", and its `lifecycle` block explains why a
# hand-made tunnel is worse than merely untracked:
#
#   A tunnel created by hand has a secret Cloudflare knows and nobody else does. On
#   `tofu import`, Terraform would compare it against this module's freshly generated
#   random_id and try to write the generated one — which changes the tunnel's secret
#   and therefore its CONNECTOR TOKEN. Every running cloudflared then holds a token
#   that no longer authenticates, and the API is unreachable until the next deploy.
#
# So the dashboard route costs an outage later, at the moment somebody tidies up.
#
# ── ONE TUNNEL PER CLUSTER, NOT PER PRODUCT ────────────────────────────────
#
# The products' own tunnels (rova/develop/tunnel-token-tf and the rest) are the ECS
# estate's, one per service, and they go at Phase 5. §3's arithmetic for the cluster:
# "seven products × 2 replicas would be 14 pods and roughly a gibibyte of RAM
# proxying". One tunnel, three connectors, a catch-all rule.
#
# `hostname` is deliberately UNSET, which means this module creates NO configuration
# resource. Cloudflare's tunnel-config API is a whole-document PUT, so writing a
# partial rule set discards anything the live configuration holds that this file does
# not reproduce. Routing belongs to the Gateway API objects in `gitops`, and the
# catch-all lives with cloudflared's own config — not here.
module "tunnel" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash — the estate's convention.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-tunnel?ref=cf-tunnel-v0.2.1"

  account_id = var.cloudflare_account_id
  name       = local.name

  # ── A WILDCARD, NOT A HOSTNAME PER PRODUCT ────────────────────────────────
  #
  # §3: routing "lives in HTTPRoutes, in product namespaces, in git. The tunnel just
  # carries bytes to the Gateway." A rule per product would put half the routing in
  # Cloudflare — the exact shape §3 rejected — and it would also cost a tunnel edit
  # per pull request, which is what §11's preview environments cannot afford:
  #
  #     <product>.qnsc.vn  ->  the tunnel  ->  the Gateway  ->  an HTTPRoute
  #
  # So ONE wildcard rule, and every real routing decision is a Gateway API object
  # that ArgoCD reconciles. The module appends the `http_status:404` fallback that
  # Cloudflare requires as the last rule.
  hostname = "*.qnsc.vn"

  # A NAME `gitops` OWNS, deliberately not the Service Envoy Gateway generates.
  # That one is `envoy-platform-qnsc-<hash>`, invented by the controller, and
  # writing it here would make this stack depend on a string a Kubernetes controller
  # chose. `platform/gateway/service.yaml` is the stable indirection; it selects the
  # proxy pods by Envoy Gateway's documented ownership labels.
  #
  # Port 8080 matches the Gateway's listener. Plain HTTP is correct and not an
  # oversight: Cloudflare terminates TLS, and this hop is pod-to-pod inside the VPC.
  service = "http://gateway.platform.svc.cluster.local:8080"
}

# ── One DNS record per hostname, NOT a wildcard ──────────────────────────────
#
# A wildcard was the first attempt and it could not work: `*.qnsc.vn` needs a
# certificate Cloudflare's Universal SSL does not issue (it covers the apex and ONE
# wildcard level), so every request died at the edge with SSL alert 40 before the
# tunnel was consulted. Covering it costs Advanced Certificate Manager, ~$10/month on
# this Free zone.
#
# Explicit first-level records are free, because Cloudflare issues a certificate for a
# first-level hostname automatically. They are also SAFER, and that matters more than
# the money: the apex wildcard this replaces would have changed the DNS answer for
# every unrecorded hostname in a zone the ECS estate is still serving. There is now
# nothing to gate, so `enable_tunnel_wildcard_dns` is gone with it.
#
# The tunnel's own rule stays `*.qnsc.vn`. That is not a contradiction — a rule only
# ever sees hostnames whose DNS already points at THIS tunnel, so the wildcard there
# saves a rule per product while these records remain the thing that grants access.
locals {
  # Products served by this cluster. Add a product here when it cuts over; removing
  # one withdraws its DNS and nothing else.
  tunnel_hostnames = []
}

module "tunnel_dns" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash — the estate's convention.
  source   = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/dns-record?ref=dns-record-v1.1.0"
  for_each = toset(local.tunnel_hostnames)

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  content = module.tunnel.cname
  proxied = true # a grey-clouded record resolves to a name meaningless outside the edge
  comment = "${each.value} on the ${local.name} cluster tunnel. Managed by cluster-prod."
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone for qnsc.vn. CI passes TF_VAR_cloudflare_zone_id from the CLOUDFLARE_ZONE_ID org variable."
}

# ⚠ THE TOKEN IS A LIVE CREDENTIAL AND IT IS IN THIS STATE. `modules/cf-tunnel`'s
# header says so outright, and it is the deliberate trade for not having a hand-made
# tunnel nobody can reproduce. The state bucket is encrypted with the product CMK and
# versioned; treat a state dump as a credential leak.
#
# The NAME is what `gitops/platform/secrets/external-secrets.yaml` looks up, so it is
# a contract with that file, not a local choice.
resource "aws_secretsmanager_secret" "cloudflared_token" {
  name                    = "qnsc/${local.env}/platform/cloudflared-token"
  description             = "Cloudflare Tunnel connector token for ${local.name}'s cloudflared. Written by OpenTofu."
  kms_key_id              = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
  recovery_window_in_days = 7

  tags = merge(local.tags, { Name = "qnsc/${local.env}/platform/cloudflared-token" })
}

resource "aws_secretsmanager_secret_version" "cloudflared_token" {
  secret_id     = aws_secretsmanager_secret.cloudflared_token.id
  secret_string = module.tunnel.token
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account that owns the tunnel. CI passes TF_VAR_cloudflare_account_id from the CLOUDFLARE_ACCOUNT_ID org variable."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token. CI passes TF_VAR_cloudflare_api_token from the CLOUDFLARE_API_TOKEN org secret."
}
