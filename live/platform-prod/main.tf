# ─────────────────────────────────────────────────────────────────────────────
# platform-prod — the PRODUCTION network for the Kubernetes estate.
#
# ── WHY A SECOND VPC EXISTS AT ALL ──────────────────────────────────────────
#
# So the ECS estate can be DELETED, not shrunk.
#
# §17b's Phase 5 says: "delete only the ECS BLOCKS from each stack's
# configuration. DO NOT run tofu destroy — one state owns the database and the
# ECS services." That surgery is the most dangerous step in the whole migration
# and it lands on rova's ~6,200-line stack module, where the database, secrets,
# DNS, tunnel and ECS pieces share one state.
#
# The reason it was unavoidable was ownership: the NEW platform's data tier used
# to live in the OLD VPC. `data-prod` read `runtime-prod`'s `data_subnet_ids` and
# `sg_rds_id`, so the shared Postgres that Kubernetes depends on sat inside the
# network the ECS estate owns. You cannot delete a VPC that contains the database
# your new platform is running on, so `runtime-prod` could never be destroyed —
# only carved.
#
# With this stack the new estate is self-contained: its own VPC, its own subnets,
# its own security groups, its own data tier on top. Once traffic has moved and
# soaked, `runtime-prod` and every product's `infra/live/prod` can be destroyed
# WHOLESALE, state and all, because nothing load-bearing is left inside them.
# Phase 5 becomes `tofu destroy` on stacks nobody is using, which is a decision
# with an undo (the state is versioned in S3) rather than surgery on a live state.
#
# ── WHAT THIS COSTS, STATED PLAINLY ─────────────────────────────────────────
#
#   a second NAT           ~$33/month, see nat_type below for why gateway not
#                          instance here
#   the data tier          already a new instance either way — `data-prod` has
#                          always created `qnsc-shared-prod`, it just used to
#                          create it in the wrong VPC
#   DATA MIGRATION         the real price. See the warning below.
#
# ⚠ THE PROPERTY THIS GIVES UP. §17b's cutover is reversible because step 3 runs
# "new pods against the SAME database", so rollback is pointing the Cloudflare
# Tunnel hostname back. A separate data tier breaks that: the moment the
# Kubernetes side accepts a write, the two databases have diverged and the tunnel
# is no longer an undo button.
#
# That trade was made deliberately — easy deletion in exchange for a real data
# migration — and it is written up in `infra/docs/implementation-plan.md` under
# "The same-database contradiction". DO NOT cut over production traffic until that
# migration procedure exists and has been rehearsed. `live/peering-prod` is the
# network path it needs.
#
# ── WHAT IS NOT HERE ────────────────────────────────────────────────────────
#
#   no ALB, no WAF         §3 — Cloudflare Tunnel replaces the load balancer, so
#                          there is no public ingress to protect. `runtime-prod`
#                          carries both because the ECS estate needs them.
#   no ECS anything        that is the whole point
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/platform-prod/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = local.region
}

locals {
  region = "ap-southeast-1"
  env    = "prod"
  name   = "qnsc-platform-prod"

  # Three AZs, unnarrowed — unlike `runtime-dev`, which serves ECS from two.
  # Every manifest in `gitops` spreads on `topology.kubernetes.io/zone`, and a
  # `maxSkew` across three zones cannot be satisfied by two.
  azs = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  tags = {
    Org         = "qnsc"
    ManagedBy   = "platform-prod"
    Layer       = "platform"
    Environment = "production"
    env         = local.env
    # §12 — shared infrastructure carries no `product` tag by definition. This
    # line is split across products, not assigned to one.
    product = "shared"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# The VPC
#
# ── ADDRESS PLAN, AND WHY IT DOES NOT OVERLAP ANYTHING ──────────────────────
#
#   10.90.0.0/16   runtime-dev    the OLD dev VPC
#   10.91.0.0/16   runtime-prod   the OLD prod VPC
#   10.92.0.0/16   platform-dev   this stack's dev sibling
#   10.93.0.0/16   platform-prod  HERE
#
# NON-OVERLAPPING IS A REQUIREMENT, NOT TIDINESS. The data migration needs a
# path from the old RDS to the new one, and VPC peering REFUSES to attach two
# VPCs with overlapping CIDRs — there is no NAT-your-way-out of it after the
# fact. Getting this wrong would mean rebuilding a VPC to migrate into it.
#
# The tier layout is identical in all four VPCs on purpose: someone reading
# 10.9x.20.0/24 knows it is a data subnet without checking which VPC they are in.
# ─────────────────────────────────────────────────────────────────────────────

module "network" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash, and that is the
  #   estate's convention — every other stack pins the same way. release-please
  #   cuts these tags, so the ref is as immutable as a SHA in practice and a
  #   module upgrade stays a diff someone can read.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/network?ref=network-v1.4.0"

  name   = local.name
  region = local.region
  azs    = local.azs

  vpc_cidr             = "10.93.0.0/16"
  public_subnet_cidrs  = ["10.93.0.0/24", "10.93.1.0/24", "10.93.2.0/24"]
  private_subnet_cidrs = ["10.93.10.0/24", "10.93.11.0/24", "10.93.12.0/24"]
  data_subnet_cidrs    = ["10.93.20.0/24", "10.93.21.0/24", "10.93.22.0/24"]

  # The tier EKS nodes and pods live in. /20 because Auto Mode reserves a /28 per
  # node UP FRONT, so a /24 exhausts at roughly fifteen nodes per AZ — §15c's
  # failure #2, which presents as pods stuck in `ContainerCreating`.
  #
  # 4091 usable per AZ. The module rejects anything smaller than /20 with that
  # reason in the error.
  cluster_subnet_cidrs = ["10.93.32.0/20", "10.93.48.0/20", "10.93.64.0/20"]

  # GATEWAY, NOT INSTANCE — and this is the one place this stack deliberately
  # DISAGREES with `runtime-prod`, which runs a fck-nat t4g.nano at ~$4.16/month
  # as a documented cost decision.
  #
  # The blast radius of a dead NAT is not the same on Kubernetes. On ECS, tasks
  # are long-lived and pinned at a fixed count, so losing egress blocked NEW
  # tasks while the running ones kept serving. Under Auto Mode, Karpenter creates
  # and terminates nodes continuously and EVERY new node pulls images — so a dead
  # NAT stops scale-out, stops node replacement, and stops recovery from a Spot
  # reclaim. It converts a single t4g.nano into a availability dependency for the
  # whole cluster, with no auto-recovery: `runtime-prod`'s own notes record that
  # the route table points at an ENI that nothing recreates, and that recovery is
  # `tofu apply`.
  #
  # ~$33/month against ~$4.16. Revisit WITH the §15d measurement (task 2.9), when
  # the node bill is measured rather than modelled — the same review that
  # re-decides Auto Mode itself.
  nat_type = "gateway"

  # ONE gateway, not one per AZ. Three would be ~$99/month, and every other layer
  # of this estate is deliberately single-AZ — production RDS is `multi_az =
  # false` as a recorded cost decision. Buying AZ redundancy here alone would be
  # paying for a property nothing else has. Revisit it WITH the RDS decision.
  multi_az_nat = false

  # OFF. The module places one Interface endpoint ENI per private subnet, so
  # ecr.api + ecr.dkr + secretsmanager across three AZs is ~$85/month of ENI
  # hours before any data. The free S3 gateway endpoint the module always creates
  # already carries ECR's layer blobs, which is the ~94% of August's ECR bill
  # that was data transfer (§3). What still crosses NAT is auth and manifests,
  # which are small.
  #
  # The threshold to revisit is ~230 GB/month of internet egress, from
  # `runtime-prod`'s own working: NAT is ~$0.12/GB in ap-southeast-1.
  enable_interface_endpoints = false

  # NO SSM BASTION, unlike `runtime-dev`. `nat_ssm_bastion` requires
  # `nat_type = "instance"` — the module validates the pair rather than applying
  # cleanly and doing nothing — and there is no NAT instance here.
  #
  # Reaching this VPC's database is a different mechanism anyway: `kubectl
  # port-forward` through the cluster, governed by the EKS access entries in
  # §10b, where production developers have EKSViewPolicy and NO exec. That is a
  # tighter control than an SSM session on a shared NAT box, and it is the one
  # the platform already audits.
  enable_flow_logs        = true
  flow_log_retention_days = 30

  tags = local.tags
}
