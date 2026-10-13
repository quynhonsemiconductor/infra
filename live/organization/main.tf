# =============================================================================
# organization — RETIRED 2026-08-18. DO NOT APPLY.
#
# THE ORGANIZATION THIS STACK MANAGES NO LONGER EXISTS. It was deleted on 2026-08-18 so
# that account 608983206583 could join a partner's organization (TrueIDC) to evaluate Kiro.
# An AWS account belongs to at most one organization, so deleting this one was the only
# route in.
#
# WHAT THAT COST, recorded here because it is not obvious from the outside: IAM Identity
# Center lives in an organization's MANAGEMENT account, so it went with the org. A MEMBER
# account cannot enable Identity Center, so `aws sso login` is gone for this account and
# cannot be restored while it belongs to someone else's org. Human access was rebuilt in
# live/security-baseline/human-access.tf — an IAM user with no permissions that assumes a
# role with MFA. Read that file's header before changing anything about access.
#
# WHAT DID NOT BREAK: nothing operational. GitHub Actions authenticates through the OIDC
# provider in iam-oidc, never through Identity Center, so all thirteen `*-github-*` roles
# kept working across the deletion — confirmed by a Terraform plan that ran and read S3
# state afterwards.
#
# APPLYING THIS WOULD CREATE A NEW ORGANIZATION with 608983206583 as its management
# account, which would FAIL while the account is a member of another org — and if it ever
# succeeded it would silently undo the partner-billing arrangement. It is deliberately not
# referenced by .github/workflows/infra-apply.yml, so CI cannot reach it. Keep it that way.
#
# THE REMOTE STATE AT platform/organization/terraform.tfstate IS ORPHANED. It still
# describes the deleted organization, its OUs, its SCPs and its permission sets. It is left
# in place rather than deleted because it is the only record of what that topology was, and
# because deleting state is irreversible in a way that keeping it is not. Do not run
# `tofu destroy` here: the resources are already gone and the run would only mislead.
#
# KEPT, NOT DELETED, on purpose. If the account ever leaves the partner org, this stack is
# the fastest route back to a governed baseline: Organizations with feature set ALL, the
# Security / Shared-Services / Workloads OUs, the baseline SCPs in scp.tf, and Identity
# Center in identity-center.tf. Rebuilding that from memory would be a week's work and the
# SCPs in particular encode decisions nobody would reconstruct correctly.
#
# TO REVIVE IT: leave the partner org, wait for the account to become standalone, delete
# the orphaned state file, then apply from scratch. The `enable_identity_center` variable
# is the switch that brings SSO back, and doing so should retire human-access.tf.
#
# ── Original header follows, describing the design as it was ─────────────────
#
# organization — AWS Organizations landing-zone root (management account).
#
# The identity & governance foundation for the whole platform. Adopt NOW at $0,
# single-account — the account split (dev/prod member accounts) is deferred per
# COST_POSTURE_PLAN.md §8, but the free layer beneath it is not:
#   - AWS Organizations (feature set ALL) + service-access principals
#   - OUs matching the ACCOUNT_SPLIT_PLAN topology (Security / Shared-Services /
#     Workloads) — empty today, ready for member accounts at the split trigger
#   - Baseline Service Control Policies (region-lock, deny-disable-logging,
#     deny IAM-user/access-key creation, deny root, deny leave-org)
#   - IAM Identity Center (SSO) permission sets — the human access model
#     (opt-in via enable_identity_center; humans use SSO, never IAM users/keys)
#
# Additive & isolated: provisions no product resources, owns nothing the
# bootstrap / security-baseline / product stacks own. This stack runs in the
# MANAGEMENT account only.
#
# ⚠ Bootstrap order & import: enabling Organizations + Identity Center is a
# one-time console/CLI action (needs management-account admin). If the org
# already exists, import it before the first apply:
#     tofu import aws_organizations_organization.this <org-id>
# See README.md for the full runbook and the SCP lockout-safety notes.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/organization/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

provider "aws" {
  region = "ap-southeast-1"
  default_tags {
    tags = {
      Org       = "qnsc"
      ManagedBy = "opentofu"
      Layer     = "platform"
      Stack     = "organization"
    }
  }
}

# ── The organization ──────────────────────────────────────────────────────────
# feature_set = ALL is required for SCPs. Service-access principals let the org
# delegate/aggregate the services we already run (CloudTrail org trail, Config,
# GuardDuty, Access Analyzer) and the identity layer (Identity Center / SSO).
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "sso.amazonaws.com",             # IAM Identity Center
    "cloudtrail.amazonaws.com",      # org-wide trail (future delegated admin)
    "config.amazonaws.com",          # org-wide Config aggregation
    "guardduty.amazonaws.com",       # org-wide threat detection
    "access-analyzer.amazonaws.com", # org-wide external-access findings
    "account.amazonaws.com",         # alternate contacts / account mgmt
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]
}

# ── Organizational Units (topology from ACCOUNT_SPLIT_PLAN.md §1) ──────────────
# Empty today (single account). Created now so the tree + SCP attachment points
# exist before member accounts land — the split becomes an Account-Factory move,
# not a re-org. The management account stays at the root (never inside an OU).
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "shared_services" {
  name      = "Shared-Services"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

locals {
  root_id = aws_organizations_organization.this.roots[0].id
}
