# ── qnsc-backups — the PROD R2 backup bucket (ONPREM-PLAN §10.2–10.3 — M-6) ─
#
# The prod bucket: prefix-scoped lifecycle + Bucket Lock. (pg-dev has its own
# bucket, qnsc-backups-dev, at the end of this file: a dev token must never be
# able to reach a prod WAL/base backup.) Prefixes:
#   pg-rova/    CNPG barman base+WAL        PITR 14 d (barman prunes, not us)
#   dumps/      pg_dump daily 15 d / weekly 35 d / monthly 100 d
#   files/      rova attachments 35 d; full-<YYYY-MM>/ 35 d
#   dev/        RETIRED 2026-11-04: pg-dev dumps moved to qnsc-backups-dev
#               (a dev token must never be able to reach this bucket)
#   gate/       pg-gate Phase-1 gate 7 d (NO lock); CUTOVER B9 adds a locked
#               TEST prefix to prove barman works under the lock
#
# The lock is the immutability control: RW tokens scoped to this bucket, no
# "write-only" claim (§10.3). Lock covers pg-rova/<server>/wals/,
# pg-opshub/<server>/wals/, dumps/, files/ — 14 days, never longer than the
# shortest locked lifecycle (daily 15 d > 14 d).
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

  # Order = the order the API returns (by id): rules is a list, so any other
  # order shows as permanent drift.
  rules = [
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
    {
      # WAL segments of the opshub CNPG cluster — the same shape and the same
      # reason as pg-rova below (barman-cloud rewrites backup.info, so the
      # base/ prefixes stay unlocked; WAL files are written once).
      # pg-opshub is not deployed yet (gitops platform/opshub-prod is
      # disabled), so this rule locks nothing until it is: the prefix is fixed
      # NOW so the cluster's first archive is immutable from the first WAL.
      # The path carries the archive generation (serverName in the future
      # gitops platform/cnpg/pg-opshub.yaml): keep it at pg-opshub-g1 and bump
      # this prefix together with that file if the archive is ever rebuilt.
      id      = "lock-pg-opshub-14d"
      prefix  = "pg-opshub/pg-opshub-g1/wals/"
      enabled = true
      condition = {
        type            = "Age"
        max_age_seconds = 1209600 # 14 days
      }
    },
    {
      # WAL segments only. barman-cloud writes each base backup's backup.info
      # twice (STARTED, then DONE), and a lock on the base/ objects refuses the
      # second write (ObjectLockedByBucketPolicy, seen on the first pg-rova
      # backup 2026-11-01). WAL files are written once, so they lock cleanly.
      # The path carries the archive generation (serverName in gitops
      # platform/cnpg/pg-rova.yaml): bump this prefix together with it.
      id      = "lock-pg-rova-14d"
      prefix  = "pg-rova/pg-rova-g1/wals/"
      enabled = true
      condition = {
        type            = "Age"
        max_age_seconds = 1209600 # 14 days
      }
    },
  ]
}

resource "cloudflare_r2_bucket_lifecycle" "qnsc_backups" {
  account_id   = var.cloudflare_account_id
  bucket_name  = cloudflare_r2_bucket.qnsc_backups.name
  jurisdiction = "default"

  # Order = the order the API returns (by id), same reason as the lock above.
  rules = [
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
  ]

  # The API fills the UNUSED transition of every rule with an empty
  # `condition = {}` ("type" is required in the schema, so the config cannot
  # say it). Ignore exactly those two attributes (indexes follow the id order
  # above); a real change to either rule's own transition still plans.
  lifecycle {
    ignore_changes = [
      rules[0].delete_objects_transition,
      rules[7].abort_multipart_uploads_transition,
    ]
  }
}

# ── qnsc-backups-dev — pg-dev dumps, isolated from every prod backup ───────
#
# A SEPARATE bucket on purpose: the pg-dev dump runs with a dev credential, and a
# dev token must never be able to write (or delete) prod WAL/base backups. The
# token is scoped to this bucket only; nothing here is referenced by a prod job.
#
# 7-day lifecycle on EVERY object. No bucket lock: the dev dumps are rebuildable,
# and a 14-day lock would outlive the 7-day delete. Incomplete multipart uploads
# are reaped after 7 days.
resource "cloudflare_r2_bucket" "qnsc_backups_dev" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-backups-dev"
  location   = "apac"
}

resource "cloudflare_r2_bucket_lifecycle" "qnsc_backups_dev" {
  account_id   = var.cloudflare_account_id
  bucket_name  = cloudflare_r2_bucket.qnsc_backups_dev.name
  jurisdiction = "default"

  rules = [
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
    {
      id      = "dev-dumps-7d"
      enabled = true
      conditions = {
        prefix = ""
      }
      delete_objects_transition = {
        condition = { type = "Age", max_age = 604800 } # 7 d
      }
    },
  ]

  # Same Optional+Computed fields the API fills on unused transitions as the
  # qnsc-backups lifecycle above; ignore exactly those two.
  lifecycle {
    ignore_changes = [
      rules[0].delete_objects_transition,
      rules[1].abort_multipart_uploads_transition,
    ]
  }
}

output "qnsc_backups_bucket" {
  description = "Bucket name for the PROD backup CronJobs' env (r2-backup-rw / r2-dump-rw / r2-backup-ro tokens are scoped to this bucket, §10.3)."
  value       = cloudflare_r2_bucket.qnsc_backups.name
}

output "qnsc_backups_dev_bucket" {
  description = "Bucket for the pg-dev dump only; the dev R2 token is scoped to it, never to qnsc-backups."
  value       = cloudflare_r2_bucket.qnsc_backups_dev.name
}

# ── Office-IP allowlist (OPTIONAL, owner 2026-10-25) ────────────────────────
# When the stqnscbackup storage account lands (its own PR — written once the
# subscription exists), it carries the SAME guarded shape as the KV
# allowlists (live/identity/main.tf): storage_account_network_rules with
# default_action Deny, bypass ["AzureServices"], ip_rules = [TF_VAR_office_ip]
# — machine credentials only; humans stay on Entra + MFA; enable only after
# the line is stable. The variable lives with that resource.
