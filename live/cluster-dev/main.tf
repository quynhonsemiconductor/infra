# ─────────────────────────────────────────────────────────────────────────────
# cluster-dev — the EKS dev cluster.
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
# ⚠ BLOCKED ON THE RESIDENCY ANSWER. `infra/docs/data-residency-question.md` must
# be answered before this is applied. Answer C — all Vietnamese personal data must
# stay in Vietnam — means a different CLOUD PROVIDER, not a different region, and
# AWS has no Vietnam region. Creating clusters first is the one sequence that
# cannot be recovered from cheaply (§18).
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    # §2b — `data "tls_certificate"` below reads the OIDC issuer's thumbprint for
    # the IRSA provider. Without a constraint OpenTofu installs whatever `tls` is
    # latest at `init` time, which is the unpinned-version class §2b closes.
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/cluster-dev/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = local.region
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/runtime-dev/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# The network module outputs no route table IDs, and adding one would mean a
# version bump to a module every live product consumes. Looking them up from the
# subnets is exact, read-only, and touches nothing.
data "aws_route_table" "private" {
  for_each  = toset(data.terraform_remote_state.network.outputs.private_subnet_ids)
  subnet_id = each.value
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
  env    = "dev" # §7c — never `develop`. The cluster is new, so nothing is grandfathered.
  name   = "qnsc-dev"

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
    ManagedBy = "cluster-dev"
    Layer     = "platform"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite — §3. MUST BE APPLIED BEFORE THE CLUSTER.
# ─────────────────────────────────────────────────────────────────────────────

# §3 — "ECR image layers are served from S3, so every image pull currently crosses
# fck-nat and is billed per gigabyte. August's ECR bill was ~94% DATA TRANSFER."
#
# Kubernetes makes that worse than ECS did: nodes pull on every scale-out and every
# Karpenter consolidation, not only on deploy. A gateway endpoint is free and has
# no operational surface.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.terraform_remote_state.network.outputs.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = distinct([for rt in data.aws_route_table.private : rt.route_table_id])

  tags = merge(local.tags, { Name = "${local.name}-s3" })
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
  compute_config {
    enabled       = true
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
    subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

    # §3 — "no inbound surface is the strongest property of the current
    # architecture." The API server is private; humans reach it through
    # Identity Center (§10b), not over the internet.
    endpoint_private_access = true
    endpoint_public_access  = false
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
  kms_key_id        = data.terraform_remote_state.bootstrap.outputs.kms_key_arn
  tags              = local.tags
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
