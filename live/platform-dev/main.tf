# ─────────────────────────────────────────────────────────────────────────────
# platform-dev — the DEVELOPMENT network for the Kubernetes estate.
#
# `live/platform-prod/main.tf` carries the full argument for why a second VPC
# exists: so the ECS estate can be DELETED rather than surgically shrunk, which
# it could not be while the new platform's data tier lived inside the old VPC.
# Read that file first. This one records only what differs in dev.
#
# ── WHAT DIFFERS ────────────────────────────────────────────────────────────
#
#   nat_type       INSTANCE, not gateway. ~$3/month against ~$33. A dead NAT in
#                  dev stops image pulls and scale-out until someone runs
#                  `tofu apply`, which is an interruption dev can absorb and
#                  production cannot — see platform-prod for why the Kubernetes
#                  blast radius is larger than it was on ECS.
#   nat_ssm_bastion  ON. Developers need a path to the dev database from a
#                  laptop, and this is the audited one.
#   flow logs      7 days, not 30. Dev flow logs answer "why can this pod not
#                  reach that", which is a question asked the same day.
#
# Everything else is deliberately identical, including the tier layout, so a
# finding in dev transfers to prod without re-reading the address plan.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/platform-dev/terraform.tfstate"
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
  env    = "dev"
  name   = "qnsc-platform-dev"

  # THREE AZs, and this is a deliberate departure from `runtime-dev`, which
  # narrows its ECS subnets to two `serving_azs` behind a single-AZ NAT.
  #
  # Every manifest in `gitops` carries a `topologySpreadConstraints` on
  # `topology.kubernetes.io/zone`. With two zones a `maxSkew: 1` across three is
  # unsatisfiable, and the scheduler's response is to leave pods Pending — which
  # reads as a capacity problem and is a topology one.
  azs = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]

  tags = {
    Org         = "qnsc"
    ManagedBy   = "platform-dev"
    Layer       = "platform"
    Environment = "develop"
    env         = local.env
    product     = "shared"
  }
}

module "network" {
  # checkov:skip=CKV_TF_1: a version TAG, not a commit hash — the estate's
  #   convention. release-please cuts these, so the ref is as immutable as a SHA
  #   in practice and a module upgrade stays a readable diff.
  source = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/network?ref=network-v1.4.0"

  name   = local.name
  region = local.region
  azs    = local.azs

  # 10.92.0.0/16. Non-overlapping with 10.90 (runtime-dev), 10.91 (runtime-prod)
  # and 10.93 (platform-prod) because VPC peering REFUSES overlapping CIDRs and
  # the data migration needs a path from the old VPC to this one. That is not a
  # constraint you can work around after the fact.
  vpc_cidr             = "10.92.0.0/16"
  public_subnet_cidrs  = ["10.92.0.0/24", "10.92.1.0/24", "10.92.2.0/24"]
  private_subnet_cidrs = ["10.92.10.0/24", "10.92.11.0/24", "10.92.12.0/24"]
  data_subnet_cidrs    = ["10.92.20.0/24", "10.92.21.0/24", "10.92.22.0/24"]
  cluster_subnet_cidrs = ["10.92.32.0/20", "10.92.48.0/20", "10.92.64.0/20"]

  # fck-nat t4g.nano. NOT "none": Auto Mode nodes cannot join the cluster without
  # egress — they need ECR, STS and the EKS endpoint — and the failure arrives at
  # node bootstrap, not at apply, so nothing about the OpenTofu run warns you.
  nat_type = "instance"

  # The audited path to the dev database from a laptop:
  #
  #   aws ssm start-session --target <nat-instance-id> \
  #     --document-name AWS-StartPortForwardingSessionToRemoteHost \
  #     --parameters '{"host":["<rds-endpoint>"],"portNumber":["5432"],"localPortNumber":["15432"]}'
  #
  # Costs nothing — the NAT instance already runs and already has the egress the
  # SSM agent needs. Access is decided by IAM and every session is in CloudTrail,
  # which is what an SSH bastion does not give you. ON in dev, and deliberately
  # absent in prod: see platform-prod.
  nat_ssm_bastion = true

  # Dev already has a NAT, so interface endpoints are ~$22/month of redundancy.
  enable_interface_endpoints = false

  enable_flow_logs        = true
  flow_log_retention_days = 7

  tags = local.tags
}
