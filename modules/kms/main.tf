# ── Shared Customer-Managed KMS Key ───────────────────────────────────────────
# One CMK per AWS account, shared by all products (Rally, OpsHub, etc.).
# Uses:
#   - RDS storage encryption (kms_key_id)
#   - Secrets Manager encryption (kms_key_id)
#   - S3 bucket SSE (kms_master_key_id)
#   - ECS task environment variables (future: Parameter Store)
#
# Key policy:
#   - The account root has full admin access (prevents key lockout)
#   - Any principal in the account can use the key for encryption operations
#     (least-privilege — services must be explicitly granted by their own IAM)
#
# Rotation: automatic annual rotation (AWS handles ciphertext transparency).
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "this" {
  description              = "Shared platform CMK — encrypts RDS, Secrets Manager, S3 across all products"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  rotation_period_in_days  = 365
  deletion_window_in_days  = 30 # max safety window before destroy takes effect
  multi_region             = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ── Account root: full key administration ──────────────────────────────
      {
        Sid    = "AllowRootAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # ── AWS services: allow use for encryption (services are scoped by their
      #    own IAM policies; this grants the door, not the key) ───────────────
      {
        Sid    = "AllowAWSServicesEncryption"
        Effect = "Allow"
        Principal = {
          Service = [
            "rds.amazonaws.com",
            "secretsmanager.amazonaws.com",
            "s3.amazonaws.com",
            "logs.${data.aws_region.current.name}.amazonaws.com"
          ]
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:RevokeGrant"
        ]
        Resource = "*"
      },
      # ── IAM roles: allow any IAM entity in the account to use for decryption
      #    (individual task/execution roles are further scoped by their policies)
      {
        Sid    = "AllowIAMEncryptDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:ListGrants"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "qnsc-platform-cmk" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/qnsc-platform"
  target_key_id = aws_kms_key.this.key_id
}
