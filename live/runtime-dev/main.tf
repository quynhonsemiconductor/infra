terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/runtime-dev/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org         = "qnsc"
      ManagedBy   = "opentofu"
      Layer       = "platform"
      Environment = "develop"
    }
  }
}

# =============================================================================
# Shared runtime layer — DEVELOP
#
# One VPC + fck-nat + ALB shared by ALL products' develop stacks (rally,
# opshub, …). Product env stacks read this stack's outputs via
# terraform_remote_state and create ONLY their own RDS + ECS + SQS + secrets
# + a host-based listener rule on this shared ALB (rally=100, opshub=200, …).
#
# Dev has NO shared cache here: each product's develop stack provisions its own
# cache (rally: a single-node ElastiCache; opshub: currently a per-task Valkey
# sidecar), so this stack is network + ingress only. RDS and Fargate are always
# per-product and never live here.
# =============================================================================

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# Wildcard *.qnsc.vn ACM cert is created + validated by the edge stack. Read its
# ARN here instead of taking it as an input variable — single source of truth,
# no GitHub var to set/sync per environment. Applies after apply-edge (see CI).
data "terraform_remote_state" "edge" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/edge/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  name   = "qnsc-runtime-dev"
  region = "ap-southeast-1"
  azs    = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  # Single source of truth for Cloudflare edge IPs (bootstrap). The API
  # subdomains are Cloudflare-proxied, so the ALB only ever sees CF edge IPs.
  cloudflare_ipv4 = data.terraform_remote_state.bootstrap.outputs.cloudflare_ipv4

  # ── Serving AZs (cost) ──────────────────────────────────────────────────────
  # The VPC still has subnets in all three AZs — `local.azs` above is unchanged, so the
  # address space, route tables and NAT are untouched and widening later needs no CIDR
  # work. This is only about which AZs actually SERVE: the ALB enables one public subnet
  # per entry (one public IPv4 each, $3.65/mo) and product ECS services are placed in the
  # matching private subnets.
  #
  # ONE list drives both, deliberately. The ALB reading a different set from the services
  # is precisely the bug that rolled back opshub#85 (see module.alb below), and the only
  # durable fix is to make the mismatch unrepresentable rather than to remember the rule.
  #
  # TWO, not one. An Application Load Balancer cannot be single-AZ — AWS rejects the
  # apply outright:
  #
  #   ValidationError: At least two subnets in two different Availability Zones
  #   must be specified
  #
  # So two is the floor for any ALB, and the saving here is one address ($3.65/mo), not
  # two. Verified against the live API on 2026-08-02, not inferred from docs.
  #
  # Develop serves from two AZs. Production serves from three — see runtime-prod/main.tf,
  # which has no equivalent of this local.
  serving_azs = ["ap-southeast-1a", "ap-southeast-1b"]

  az_index = { for i, az in local.azs : az => i }

  alb_public_subnet_ids = [
    for az in local.serving_azs : module.network.public_subnet_ids[local.az_index[az]]
  ]

  serving_private_subnet_ids = [
    for az in local.serving_azs : module.network.private_subnet_ids[local.az_index[az]]
  ]
}

# ── Shared VPC + fck-nat (egress only) ────────────────────────────────────────
module "network" {
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/network?ref=network-v1.3.1"

  name   = local.name
  region = local.region
  azs    = local.azs

  enable_interface_endpoints = false # dev: NAT covers egress — save ~$22/mo

  vpc_cidr             = "10.90.0.0/16"
  public_subnet_cidrs  = ["10.90.0.0/24", "10.90.1.0/24", "10.90.2.0/24"]
  private_subnet_cidrs = ["10.90.10.0/24", "10.90.11.0/24", "10.90.12.0/24"]
  data_subnet_cidrs    = ["10.90.20.0/24", "10.90.21.0/24", "10.90.22.0/24"]

  nat_type = "instance" # fck-nat t4g.nano ~$3/mo vs NAT GW ~$33/mo

  // Turns the NAT box into an SSM jump host so a developer can port-forward to RDS and
  // the cache from a laptop, without the databases being publicly accessible:
  //
  //   aws ssm start-session --target <nat-instance-id> \
  //     --document-name AWS-StartPortForwardingSessionToRemoteHost \
  //     --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["15432"]}'
  //
  // Then point DBeaver at localhost:15432. For the cache the local end must speak TLS
  // (`redis-cli --tls`), because transit encryption is on.
  //
  // Zero cost: the NAT already runs and already has the egress the SSM agent needs. A
  // dedicated bastion is another instance, an always-on cloudflared is another task, and
  // a publicly-accessible database costs nothing until the day it costs everything.
  //
  // DEVELOP ONLY — runtime-prod leaves this at its default of false. A laptop-to-data-tier
  // path is reasonable here and a deliberate decision there.
  //
  // Access is governed by IAM (who may call ssm:StartSession), not by the network, and
  // every session is recorded in CloudTrail. Note that only one Identity Center user
  // exists today, so this grants nothing to the team until they have accounts and a
  // permission set scoped to this instance and the develop secrets.
  nat_ssm_bastion   = true
  app_port          = 3000
  enable_flow_logs  = false
  alb_ingress_cidrs = local.cloudflare_ipv4 # lock ALB to Cloudflare orange-cloud IPs

  tags = { Environment = "develop" }
}

# ── Shared ALB (host-based routing across products) ───────────────────────────
# certificate_arn is the wildcard *.qnsc.vn cert from the edge stack (read via
# terraform_remote_state) — it covers every product API hostname on this ALB.
#
# ABSENT (var.enable_alb = false, 2026-08-02). rally's develop api now serves through a
# Cloudflare Tunnel sidecar (quynhonsemiconductor/rally, `tunnel_enabled`), so it attaches no
# listener rule and no target group. Measured immediately after that cutover: this load
# balancer had ZERO target groups and one default rule forwarding nowhere — $18.40/mo
# plus $7.30 for two public IPv4, buying nothing.
#
# TO BRING IT BACK: set enable_alb = true and apply, then set `tunnel_enabled = false`
# in the consuming product stack and redeploy. Order matters — a product attaching a
# host-header rule fails if the listener does not exist yet.
#
# NOT deleted from the file, because opshub's develop stack is still written against
# this layer's `https_listener_arn`. Nothing of opshub is deployed today, but the next
# product to adopt develop needs either this ALB back or its own tunnel.
module "alb" {
  count = var.enable_alb ? 1 : 0

  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/alb?ref=alb-v1.0.1"

  name               = local.name
  security_group_ids = [module.network.sg_alb_id]
  certificate_arn    = data.terraform_remote_state.edge.outputs.acm_cert_arn

  # SINGLE AZ in develop (decided 2026-08-02), against runtime-prod's three.
  #
  # An ALB bills one public IPv4 per ENABLED AZ ($3.65/mo each), so three AZs here cost
  # $10.95/mo to give a non-production environment an availability property nobody is
  # paged for. Develop's failure mode when its one AZ is impaired is "wait, or change
  # `local.serving_azs` and apply" — acceptable for an environment exercised by CI and a
  # handful of engineers.
  #
  # THIS IS ONLY SAFE BECAUSE THE SERVICES MOVE WITH IT. The history here matters: this
  # was `slice(..., 0, 2)` once before, and it broke deploys. Cross-zone load balancing
  # spreads traffic across targets in the ALB's ENABLED AZs; a target in an AZ the ALB
  # has no subnet in is unreachable, and AWS says so in as many words —
  #
  #   (port 3000) is unhealthy in (target-group .../opshub-develop-api/...) due to
  #   (reason Target is in an Availability Zone that is not enabled for the load balancer)
  #
  # — so roughly one task placement in three landed in an AZ that could never pass a
  # health check, and the deployment circuit breaker rolled it back. It presented as
  # flaky deploys and is what rolled back opshub#85.
  #
  # The previous fix widened the ALB to match the services. This one narrows both, which
  # the earlier comment rejected on the grounds that pinning services "couples each
  # product's service config to this file's slice". That objection is answered by WHERE
  # the slice lives: `local.serving_azs` below drives the ALB subnets AND the exported
  # `private_subnet_ids`, so every product consuming this layer's remote state gets the
  # matching subnets automatically. There is one list, not two that can drift.
  #
  # To go back to multi-AZ, widen `local.serving_azs`. Do not edit this line alone.
  subnet_ids = local.alb_public_subnet_ids

  enable_deletion_protection = false # dev: easy teardown

  tags = { Environment = "develop" }
}

# ── Shared develop cache ──────────────────────────────────────────────────────
# ONE Valkey node for every product's develop stack, instead of one per product.
#
# WHY THIS MOVED HERE. rally-develop and qnsc-kb-develop each ran their own
# cache.t4g.micro. Measured 2026-08-01..16, ElastiCache was $20.17/mo run-rate and rising
# to $30.90 as both nodes stayed up around the clock — the largest single reducible line
# on the account. They are always-on because ElastiCache has no stopped state, so the
# nightly idle schedule that scales dev services to zero does not touch them. Two nodes
# at 0.5 GiB each, holding a few thousand keys between them, for $15.45 apiece.
#
# The cache belongs in this layer for the same reason the VPC, the NAT and the security
# groups do: it is infrastructure every product's dev stack needs and none of them owns.
# `sg_cache_id` was ALREADY shared from here — both product caches sat behind the same
# security group in the same data subnets. Only the node was duplicated.
#
# DEVELOP ONLY. runtime-prod deliberately has no equivalent: production products keep
# their own node, because a shared cache is a shared blast radius and prod does not trade
# isolation for $15/mo.
#
# ── How two products share one node safely ────────────────────────────────────
#
# SEPARATE DATABASE INDEXES, not a key prefix. `num_cache_clusters = 1` in the cache
# module means cluster mode is DISABLED (verified on the live node: ClusterEnabled =
# false), so all 16 Valkey databases are available and SELECT works. Each product stack
# passes its own index in the URL path — rally `/0`, qnsc-kb `/1`. A prefix convention
# would have to be honoured by every library; a database index is enforced by the server.
#
# THE EVICTION ORDER IS LOAD-BEARING, because qnsc-kb runs CELERY on this node — broker
# AND result backend. Evicting a broker key does not miss a cache, it LOSES A QUEUED TASK.
#
# The default parameter group (default.valkey7) sets `maxmemory-policy = volatile-lru`,
# which evicts only keys that carry a TTL. Celery's broker keys have none, so they are
# never eviction candidates; rally's rate-limit counters and token denylist entries all
# have TTLs, so they are evicted first. That is the correct order, and it is a DEFAULT
# rather than a decision — if anyone sets `allkeys-lru` on this node to make rally's
# cache behave better under pressure, they will silently start dropping qnsc-kb's tasks.
#
# Headroom makes this theoretical today: 0.5 GiB against two dev workloads whose combined
# working set is measured in megabytes. Watch `DatabaseMemoryUsagePercentage` if a third
# product joins.
#
# COST: $15.45/mo, replacing $30.90.
module "shared_cache" {
  count = var.enable_shared_cache ? 1 : 0

  # checkov:skip=CKV_TF_1: first-party module pinned by immutable release tag — matches
  # every other module source in this layer, and the tags are what scripts/pin_drift.py in
  # qnsc-ci compares across repos. A commit hash would satisfy the check and make the pin
  # invisible to that report.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cache?ref=cache-v1.1.0"

  name              = "${local.name}-cache"
  subnet_ids        = module.network.data_subnet_ids
  security_group_id = module.network.sg_cache_id

  # AWS-managed key rather than a CMK. The module keeps at-rest encryption and TLS in
  # transit on either way — `kms_key_arn = ""` selects the AWS-managed ElastiCache key,
  # which is free, where a customer-managed key is $1/mo. The product CMKs that the
  # per-product caches used are per-product by construction and cannot encrypt a resource
  # shared between them without granting each product's role access to the other's key.
  kms_key_arn = ""

  mode      = "node"
  node_type = "cache.t4g.micro"

  tags = { Environment = "develop" }
}
