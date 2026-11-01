# ── Adopted DNS records (no hand-import: CI imports during plan) ────────────
#
# rova.qnsc.vn already exists in the zone — a CNAME to the Pages project of the
# AWS-era SPA (rova-prod-web.pages.dev), created outside Terraform. The cutover
# apply must UPDATE it to the tunnel, not create a second record for the same
# name (the API refuses that). The record id was read from the zone with a
# read-only token on 2026-11-01; it is an identifier, not a secret.
#
# The plan shows `has moved to cloudflare_dns_record.app_hosts["rova.qnsc.vn"]`
# and a single update of `content` (Pages → <tunnel>.cfargotunnel.com); nothing
# is destroyed.
import {
  to = cloudflare_dns_record.app_hosts["rova.qnsc.vn"]
  id = "${var.cloudflare_zone_id}/c6bfbe6c8bff0d88e2eb5b8898b8e0d6"
}
