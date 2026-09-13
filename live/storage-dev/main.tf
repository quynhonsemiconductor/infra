terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
  }

  backend "s3" {
    bucket         = "qnsc-tofu-state"
    key            = "platform/storage-dev/terraform.tfstate"
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
# Shared object storage (develop) — Cloudflare R2 attachment buckets.
#
# Object storage is dedicated per-product (rally-develop-attachments,
# opshub-develop-attachments, …), but the buckets are provisioned here in the
# platform layer — the same place the Cloudflare provider + token already live
# for `edge` — so the R2 admin token is centralized in one stack rather than
# copied into every product's CI.
#
# This stack pins the Cloudflare provider v5 (the R2 CORS/lifecycle resources
# are v5-only). It is deliberately isolated: the product stacks (rally, opshub)
# stay on the v4 provider for their DNS/edge resources and consume the bucket
# name + endpoint from this stack's outputs via terraform_remote_state — so
# shipping R2 does not force a v4→v5 migration of live DNS/Pages/WAF.
#
# The bucket-scoped runtime token the app uses is created out-of-band and stored
# in each product's Secrets Manager (never in this stack's state).
# =============================================================================

module "rally_attachments" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "rova-develop-attachments" # same name as the S3 bucket it replaces
  location   = "apac"                     # co-locate with the ap-southeast-1 footprint

  # Mirrors the rally-develop S3 CORS exactly (browser presigned PUT upload).
  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://rova-dev.qnsc.vn", "http://localhost:5173"]
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
  name       = "opshub-develop-attachments" # replaces the opshub-develop S3 uploads bucket
  location   = "apac"                       # co-locate with the ap-southeast-1 footprint

  # Mirrors the opshub-develop web origin (browser presigned PUT upload).
  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://opshub-dev.qnsc.vn", "http://localhost:5173"]
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
  name       = "rova-develop-public-assets"
  location   = "apac"

  cors_rules = [{
    allowed_methods = ["PUT"]
    allowed_origins = ["https://rova-dev.qnsc.vn", "http://localhost:5173"]
    allowed_headers = ["Content-Type", "Content-Disposition", "x-amz-checksum-sha256"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }]

  # The avatar/logo surface has shipped, so the domain this bucket was always meant
  # to have is now attached. While `public_base_url` was null nothing set
  # CDN_PUBLIC_ASSETS_BASE_URL, `StorageService.cdnUrl()` returned null, and the API
  # rejected every avatar upload with 409 "Avatar storage is not configured (no
  # public CDN base URL)" — which is exactly what develop was doing.
  #
  # Correct ONLY on this bucket: everything here is non-sensitive by construction
  # (UploadPolicy.visibility restricts it to raster-image avatar/logo surfaces), so
  # world-readable-by-key is the intended property rather than a leak.
  custom_domain = {
    hostname = "rova-assets-dev.qnsc.vn"
    zone_id  = data.terraform_remote_state.bootstrap.outputs.cloudflare_zone_id
  }

  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}


# ── qnsc-kb · develop · knowledge sources ────────────────────────────────────
# Holds the ORIGINAL uploaded documents (pdf/docx/xlsx/pptx/images) that the RAG
# pipeline extracts text from. The extracted text, chunks and embeddings live in
# Postgres; this bucket is the only copy of the source file itself.
#
# NO cors_rules, deliberately — unlike the rally buckets above, nothing uploads to
# this bucket from a browser. qnsc-kb receives the file at its own API
# (MAX_SOURCE_UPLOAD_BYTES, malware scan, extraction), then writes it server-side via
# src/domain/source_storage.py. Adding CORS here would advertise a direct-to-bucket
# path that bypasses both the size limit and the virus scan.
#
# Private, and it must stay private: the app serves originals only after its own
# authorization check and never returns an object URL. There is no custom_domain for
# the same reason — a public origin would make every uploaded document readable by
# anyone who learns the key, which for a knowledge base is the whole corpus.
module "qnsc_kb_sources" {
  count = var.cloudflare_account_id != "" ? 1 : 0

  source     = "git::https://github.com/quynhonsemiconductor/tf-modules.git//modules/cf-r2?ref=cf-r2-v1.1.0"
  account_id = var.cloudflare_account_id
  name       = "qnsc-kb-develop-sources"
  location   = "apac" # co-locate with the ap-southeast-1 footprint

  lifecycle_rules = [{
    id                              = "abort-incomplete-multipart"
    abort_incomplete_multipart_days = 7
  }]
}
