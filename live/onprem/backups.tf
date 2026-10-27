# ── qnsc-backups — the R2 backup bucket (ONPREM-PLAN §10.2–10.3 — M-6) ──────
#
# ONE bucket, prefix-scoped lifecycle + Bucket Lock:
#   pg-rova/    CNPG barman base+WAL        PITR 14 d (barman prunes, not us)
#   dumps/      pg_dump daily 15 d / weekly 35 d / monthly 100 d
#   files/      rova attachments 35 d; full-<YYYY-MM>/ 35 d
#   dev/        pg-dev dumps 7 d (NO lock — a 14-day lock would override it)
#   gate/       pg-gate Phase-1 gate 7 d (NO lock); CUTOVER B9 adds a locked
#               TEST prefix to prove barman works under the lock
#
# The lock is the immutability control: RW tokens scoped to this bucket, no
# "write-only" claim (§10.3). Lock covers pg-rova/, dumps/, files/ — 14 days,
# never longer than the shortest locked lifecycle (daily 15 d > 14 d).
#
# Product buckets (rova-dev/opshub-dev/kb-dev + rova-prod files) are imported
# from live/storage-dev/-prod in their move PRs — this file is only the
# backups bucket.

resource "cloudflare_r2_bucket" "qnsc_backups" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-backups"
  location   = "apac"
}

resource "cloudflare_r2_bucket_lock" "qnsc_backups" {
  account_id   = var.cloudflare_account_id
  bucket_name  = cloudflare_r2_bucket.qnsc_backups.name
  jurisdiction = "default"

  rules = [
    {
      id      = "lock-pg-rova-14d"
      prefix  = "pg-rova/"
      enabled = true
      condition = {
        type            = "Age"
        max_age_seconds = 1209600 # 14 days
      }
    },
    {
      id      = "lock-dumps-14d"
      prefix  = "dumps/"
      enabled = true
      condition = {
        type            = "Age"
        max_age_seconds = 1209600
      }
    },
    {
      id      = "lock-files-14d"
      prefix  = "files/"
      enabled = true
      condition = {
        type            = "Age"
        max_age_seconds = 1209600
      }
    },
    {
      # CUTOVER B9: the Phase-1 gate writes here to PROVE barman-cloud
      # WAL/base backups survive a Bucket Lock. Own TOP-LEVEL prefix on
      # purpose: under gate/ the 7-day gate/ lifecycle rule would shadow
      # the 15-day delete below (both rules match, earliest wins).
      id      = "lock-gate-locked-test-14d"
      prefix  = "gate-locked-test/"
      enabled = true
      condition = {
        type            = "Age"
        max_age_seconds = 1209600
      }
    },
  ]
}

resource "cloudflare_r2_bucket_lifecycle" "qnsc_backups" {
  account_id   = var.cloudflare_account_id
  bucket_name  = cloudflare_r2_bucket.qnsc_backups.name
  jurisdiction = "default"

  rules = [
    {
      id      = "dumps-daily"
      enabled = true
      conditions = {
        prefix = "dumps/daily/"
      }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 1296000 } # 15 d ≥ the 14 d lock
      }
    },
    {
      id      = "dumps-weekly"
      enabled = true
      conditions = {
        prefix = "dumps/weekly/"
      }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 3024000 } # 35 d
      }
    },
    {
      id      = "dumps-monthly"
      enabled = true
      conditions = {
        prefix = "dumps/monthly/"
      }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 8640000 } # 100 d
      }
    },
    {
      # write-once in practice: the 14 d lock on files/ makes any rewrite
      # impossible until expiry — uploads are append-only by key.
      id      = "files"
      enabled = true
      conditions = {
        prefix = "files/"
      }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 3024000 } # 35 d
      }
    },
    {
      id      = "dev"
      enabled = true
      conditions = {
        prefix = "dev/"
      }
      # no lock on purpose: a 14-day lock would override the 7-day delete
      delete_objects_transition = {
        condition = { type = "Age", max_age = 604800 } # 7 d
      }
    },
    {
      id      = "gate"
      enabled = true
      conditions = {
        prefix = "gate/"
      }
      # gate-locked-test/ does NOT match this prefix (different top-level
      # segment), so the 15-day rule below is not shadowed by this 7-day one.
      delete_objects_transition = {
        condition = { type = "Age", max_age = 604800 }
      }
    },
    {
      # the locked test prefix needs >= the 14-day lock, or the lock would
      # keep objects past their delete date
      id      = "gate-locked-test"
      enabled = true
      conditions = {
        prefix = "gate-locked-test/"
      }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 1296000 } # 15 d
      }
    },
    {
      id      = "cleanup-incomplete-uploads"
      enabled = true
      conditions = {
        prefix = ""
      }
      abort_multipart_uploads_transition = {
        condition = { type = "Age", max_age = 604800 } # 7 d
      }
    },
  ]
}

output "qnsc_backups_bucket" {
  description = "Bucket name for the backup CronJobs' env (r2-backup-rw / r2-backup-dev-rw tokens are scoped to this bucket, §10.3)."
  value       = cloudflare_r2_bucket.qnsc_backups.name
}

# ── Office-IP allowlist (OPTIONAL, owner 2026-10-25) ────────────────────────
# When the stqnscbackup storage account lands (its own PR — written once the
# subscription exists), it carries the SAME guarded shape as the KV
# allowlists (live/identity/main.tf): storage_account_network_rules with
# default_action Deny, bypass ["AzureServices"], ip_rules = [TF_VAR_office_ip]
# — machine credentials only; humans stay on Entra + MFA; enable only after
# the line is stable. The variable lives with that resource.
