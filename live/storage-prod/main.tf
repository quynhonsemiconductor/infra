terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/storage-prod/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "qnsc-tofu-locks"
  }
}

# Cloudflare provider — reads the token from TF_VAR_cloudflare_api_token (or the
# CLOUDFLARE_API_TOKEN env var). Needs Account:Workers R2 Storage edit scope.
# Leave empty to skip provider auth (e.g. plan-only bootstrapping).
provider "cloudflare" {
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}

# The zone that owns qnsc.vn, for the public-assets custom domain below. Read from
# bootstrap's state rather than a variable because CI only passes
# TF_VAR_cloudflare_zone_id to live/bootstrap — the same pattern live/edge uses.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "qnsc-tofu-state"
    key    = "platform/bootstrap/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

# =============================================================================
# Shared object storage (prod) — Cloudflare R2 attachment buckets.
#
# Prod counterpart of storage-dev. Object storage is dedicated per-product; the
# buckets are provisioned here in the platform layer (where the Cloudflare
# provider + token already live for `edge`) so the R2 admin token is centralized
# in one stack rather than copied into every product's CI.
#
# Pins the Cloudflare provider v5 (R2 CORS/lifecycle are v5-only). Product stacks
# stay on v4 and consume the outputs via terraform_remote_state.
#
# NOTE: prod launch is gated — this stack is edited but NOT applied until launch.
# =============================================================================

module "rally_attachments" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "rova-prod-attachments" # same name as the S3 bucket it replaces
  location   = "apac"                  # co-locate with the ap-southeast-1 footprint

  # Mirrors the rova-prod S3 CORS exactly (browser presigned PUT upload).
  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://rova.qnsc.vn"]
    # x-amz-checksum-sha256 is REQUIRED: the presigned PUT binds the SHA-256 into
    # its signature, so the browser must be allowed to send that header or every
    # upload fails at preflight.
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  # Incomplete multipart uploads are invisible in a bucket listing but still
  # billed. Nothing else reaps them — the app-side reaper only knows about keys
  # it has a DB row for, and an aborted multipart never produced one.
  #
  # NEVER attach `custom_domain` to THIS bucket. It holds permission-gated files;
  # a custom domain serves objects to anyone who knows the key, with no auth and
  # no expiry, and Terraform reports success. A TODO asking for exactly that used
  # to sit here, having drifted up from the public-assets module it was written
  # for — it is now on `rally_public_assets` below, where it belongs.
  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}

module "opshub_attachments" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  # checkov:skip=CKV_TF_1: first-party module pinned by immutable release tag (matches rally_attachments) — not a mutable external source
  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "opshub-prod-attachments" # replaces the opshub-prod S3 uploads bucket
  location   = "apac"                    # co-locate with the ap-southeast-1 footprint

  # Mirrors the opshub-prod web origin (browser presigned PUT upload).
  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://opshub.qnsc.vn"]
    # x-amz-checksum-sha256 is REQUIRED: the presigned PUT binds the SHA-256 into
    # its signature, so the browser must be allowed to send that header or every
    # upload fails at preflight.
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  # Incomplete multipart uploads are invisible in a bucket listing but still
  # billed. Nothing else reaps them — the app-side reaper only knows about keys
  # it has a DB row for, and an aborted multipart never produced one.
  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}

# ── Public assets ─────────────────────────────────────────────────────────────
# Separate bucket, deliberately. Avatars and workspace logos need long-lived,
# cacheable, CDN-servable URLs; attachments need short-lived signed ones. Putting
# both in one bucket means either attachments become CDN-readable by key
# (bypassing every authorization check) or avatars cannot be cached at all.
#
# Nothing sensitive belongs here: everything in this bucket is readable by anyone
# who knows the key. The app enforces that via UploadPolicy.visibility — only
# raster-image, non-sensitive surfaces may target it.
module "rally_public_assets" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  # checkov:skip=CKV_TF_1: first-party module pinned by immutable release tag
  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "rova-prod-public-assets"
  location   = "apac"

  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://rova.qnsc.vn"]
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  # Correct ONLY on this bucket: everything here is non-sensitive by construction
  # (UploadPolicy.visibility restricts it to raster-image avatar/logo surfaces), so
  # world-readable-by-key is the intended property rather than a leak. Without it
  # `public_base_url` is null and the API rejects every avatar upload with 409.
  custom_domain = {
    hostname = "rova-assets.qnsc.vn"
    zone_id  = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  }

  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}

# =============================================================================
# ceo-suite D1 pre-migration backups.
#
# ceo-suite holds real company financial/governance data in D1. Its deploy
# (qnsc-ci web-deploy reusable, backup_before_migrate=true) exports the DB to a
# restore point BEFORE every migration. That export is always kept as a 90-day
# GitHub artifact; once this bucket exists, the deploy also archives it here for
# durable, off-CI retention. No CORS (server-side only, written by CI via
# `wrangler r2 object put` using the deploy's Cloudflare token). Lifecycle
# expires backups after 90 days to bound cost.
#
# Enable in ceo-suite/.github/workflows/web-deploy.yml by setting
# `d1_backup_bucket: qnsc-ceo-suite-db-backups` after this stack is applied and
# the deploy token is granted Workers R2 Storage: Edit scope.
# =============================================================================
module "ceo_suite_db_backups" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  # checkov:skip=CKV_TF_1: first-party module pinned by immutable release tag (matches rally_attachments) — not a mutable external source
  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "qnsc-ceo-suite-db-backups"
  location   = "apac" # co-locate with the ap-southeast-1 footprint

  lifecycle_rules = [{
    id                              = "expire-backups"
    expiration_days                 = 90
    abort_incomplete_multipart_days = 1
  }]
}

# ── qnsc-kb · production · knowledge sources ─────────────────────────────────
# Mirror of the develop bucket in live/storage-dev. Holds the ORIGINAL uploaded
# documents the RAG pipeline extracts text from — the extracted text, chunks and
# embeddings live in Postgres, so this is the only copy of the source file itself.
#
# Created now, before production serves anyone, because the qnsc-kb prod stack reads
# these outputs on every plan: without them the plan fails on an "Invalid index" against
# a remote-state output that does not exist, which reads as a fault in the product stack
# rather than a missing bucket here.
#
# NO cors_rules and NO custom_domain, exactly as in develop. Nothing uploads from a
# browser — the API receives the file, enforces the size limit and the malware scan, then
# writes it server-side. A public origin would make every uploaded document readable by
# anyone who learns the key, which for a knowledge base is the whole corpus.
module "qnsc_kb_sources" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "qnsc-kb-prod-sources"
  location   = "apac"

  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}
