# ── Shared Artifacts S3 Bucket ────────────────────────────────────────────────
# Central bucket for cross-repo build artefacts:
#   - OpenAPI specs   (openapi/{product}/{env}/{sha}/openapi.json)
#   - Future: SBOM exports, release notes, codegen inputs
#
# Products write their own prefix; IAM policies in each product's infra
# scope read/write to their namespace only.
#
# The publish-openapi-spec composite action (qnsc-gitops) uses this bucket
# as the S3 target when s3-upload: 'true' is set.
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket = var.bucket_name
  tags   = merge(var.tags, { Name = var.bucket_name })

  # Prevent accidental destroy — artifacts are audit evidence
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != "" ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
    bucket_key_enabled = var.kms_key_arn != "" ? true : false
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-build-artifacts"
    status = "Enabled"

    filter {
      # Only non-latest/ paths expire — the latest pointer is always kept
      prefix = ""
    }

    # Noncurrent versions (overwritten objects) expire after 90 days
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
