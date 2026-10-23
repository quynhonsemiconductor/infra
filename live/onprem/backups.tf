# ── qnsc-backups — the R2 backup bucket (ONPREM-PLAN §10.2–10.3 — M-6) ──────
#
# ONE bucket, prefix-scoped lifecycle + Bucket Lock:
#   pg-rova/    CNPG barman base+WAL        PITR 14 d (barman prunes, not us)
#   dumps/      pg_dump daily 15 d / weekly 35 d / monthly 100 d (SERVER-SIDE
#               copy by the nightly job; the job itself never deletes)
#   files/      rova attachments 35 d; full-<YYYY-MM>/ 35 d
#   dev/        pg-dev dumps 7 d (no lock)
#   gate/       pg-gate Phase-1 gate 7 d (no lock)
#
# The lock never exceeds the shortest lifecycle (daily dumps 15 d > lock 14 d).
# The lock is the immutability control: RW tokens scoped to this bucket, no
# "write-only" claim (§10.3).
#
# Product buckets (rova-dev/opshub-dev/kb-dev + rova-prod files) are imported
# from live/storage-dev/-prod in their move PRs — this file is only the
# backups bucket (the rename/import of rova's FILES bucket rides the rova
# dev-move PR, §6.5).

resource "cloudflare_r2_bucket" "qnsc_backups" {
  account_id = var.cloudflare_account_id
  name       = "qnsc-backups"
  location   = "APAC"
}

# Bucket Lock — 14 days, the immutability control (§10.3).
# VERIFY AT PLAN TIME: the v5 provider's lock surface (cloudflare_r2_bucket_lock
# vs a rule block on the bucket) against the live API — the plan PR records
# that this schema was checked, not guessed. If the resource differs, fix here
# before apply; the INTENT (14-day object lock on every prefix) does not move.
resource "cloudflare_r2_bucket_lock" "qnsc_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.qnsc_backups.name

  rule {
    id              = "lock-14d"
    prefix          = ""
    enabled         = true
    retain_for_days = 14
  }
}

resource "cloudflare_r2_bucket_lifecycle" "qnsc_backups" {
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.qnsc_backups.name

  rule {
    id      = "dumps-daily"
    enabled = true
    conditions {
      prefix = "dumps/daily/"
    }
    delete_objects_transition_days = 15 # ≥ the 14 d lock
  }

  rule {
    id      = "dumps-weekly"
    enabled = true
    conditions {
      prefix = "dumps/weekly/"
    }
    delete_objects_transition_days = 35
  }

  rule {
    id      = "dumps-monthly"
    enabled = true
    conditions {
      prefix = "dumps/monthly/"
    }
    delete_objects_transition_days = 100
  }

  rule {
    id      = "files"
    enabled = true
    conditions {
      prefix = "files/"
    }
    delete_objects_transition_days = 35
  }

  rule {
    id      = "dev"
    enabled = true
    conditions {
      prefix = "dev/"
    }
    delete_objects_transition_days = 7
  }

  rule {
    id      = "gate"
    enabled = true
    conditions {
      prefix = "gate/"
    }
    delete_objects_transition_days = 7
  }
}

output "qnsc_backups_bucket" {
  description = "Bucket name for the backup CronJobs' env (r2-backup-rw / r2-backup-dev-rw tokens are scoped to this bucket, §10.3)."
  value       = cloudflare_r2_bucket.qnsc_backups.name
}
