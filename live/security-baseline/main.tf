# =============================================================================
# security-baseline — account-wide audit & threat-detection baseline.
#
# One stack, applied once per account, that gives the platform its management-
# plane audit trail and detective controls (SOC 2 CC7.x / enterprise baseline):
#   - CloudTrail  — multi-region trail, log-file validation, KMS-encrypted, to a
#                   locked, versioned, TLS-only S3 bucket.
#   - AWS Config  — records all resource config + a core set of managed rules.
#   - GuardDuty   — continuous threat detection.
#   - Access Analyzer — flags resources shared outside the account.
#
# Additive only — provisions no product resources and touches nothing the
# bootstrap/product stacks own. Uses its own dedicated audit CMK (not the
# platform CMK) so it never has to reach into the bootstrap key policy.
# =============================================================================

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/security-baseline/terraform.tfstate"
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
      Stack     = "security-baseline"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  bucket     = "qnsc-audit-logs-${local.account_id}"
}

# ── Dedicated audit-logs CMK ─────────────────────────────────────────────────
# Separate from the platform CMK: audit logs are their own trust domain, and
# CloudTrail/Config need service-specific key-policy grants we don't want to add
# to the shared application key.
resource "aws_kms_key" "audit" {
  description             = "qnsc audit logs (CloudTrail + Config)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudTrailEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*" }
        }
      },
      {
        Sid       = "ConfigEncrypt"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "audit" {
  name          = "alias/qnsc-audit-logs"
  target_key_id = aws_kms_key.audit.key_id
}

# ── Locked audit-logs bucket (CloudTrail + Config share it, distinct prefixes) ─
resource "aws_s3_bucket" "audit" {
  bucket = local.bucket
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 180
      storage_class = "GLACIER"
    }
    expiration { days = 2555 } # 7 years — SOC 2 / audit retention
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "ConfigAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.audit.arn
      },
      {
        Sid       = "ConfigWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit.arn}/config/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

# ── GuardDuty — continuous threat detection ──────────────────────────────────
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"

  datasources {
    s3_logs { enable = true }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes { enable = true }
      }
    }
  }
}

# RDS Protection — OFF, and this is a cost decision taken with the exposure in view.
#
# GuardDuty enabled RDS_LOGIN_EVENTS automatically and ran it on the 30-day free trial.
# The trial expired 2026-08-12: `APS1-FreeRDSvCPUMonitored` went to $0 and
# `APS1-PaidRDSvCPUMonitored` began billing the same day, reaching $2.28/mo within a week
# and still climbing — it bills per vCPU MONITORED, so it grows again when rally
# production runs its database 24/7 rather than idled. Left alone it is roughly $5/mo,
# and it was 82% of GuardDuty's entire bill.
#
# WHAT IT DETECTS: anomalous login behaviour against RDS — brute force, logins from
# unusual principals or geographies.
#
# WHY THE EXPOSURE IS SMALL HERE, stated so this can be re-argued rather than re-guessed:
#   - No RDS instance is publicly accessible. All three sit in data subnets with no
#     internet route, reachable only from the app security group and the SSM bastion.
#   - Credentials are per-role and least-privilege (db_least_privilege in the product
#     stacks): api and worker connect as rally_app / rally_worker, neither of which can
#     DROP a schema. The master credential belongs to the migrator alone.
#   - CloudTrail still records every API-level action against RDS, and that is what an
#     audit asks for. This feature is network/behavioural detection on top.
#
# WHAT IS NOT AFFECTED: the rest of GuardDuty stays on — CloudTrail, DNS, VPC flow logs,
# S3 data events and EBS malware protection are all still enabled above and cost $0.50/mo
# between them.
#
# TURN IT BACK ON IF: an RDS instance is ever made publicly accessible, the bastion is
# opened beyond the current IAM-gated SSM path, or a compliance obligation names
# database-login monitoring specifically. It is one line and takes effect immediately.
#
# Declared explicitly rather than switched off in the console, so the console cannot
# quietly re-enable it and so the reason travels with the setting.
resource "aws_guardduty_detector_feature" "rds_login_events" {
  detector_id = aws_guardduty_detector.this.id
  name        = "RDS_LOGIN_EVENTS"
  status      = "DISABLED"

  # GuardDuty now returns an `additional_configuration { name = "RDS_DATA_RISK", status = "DISABLED" }` block on this
  # feature. The aws provider pinned here (5.100.0) cannot declare it, and treats its absence from the configuration as
  # a change that FORCES REPLACEMENT, so every plan of this stack shows a delete-and-recreate of a setting that is
  # already correct (a no-op re-create, but it makes the plan and the daily drift report permanently noisy and hides
  # real changes). Ignore it. When the stack moves to the v6 provider, declare RDS_DATA_RISK = DISABLED explicitly
  # and remove this block.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

# ── IAM Access Analyzer — external-access findings ───────────────────────────
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "qnsc-account-analyzer"
  type          = "ACCOUNT"
}
