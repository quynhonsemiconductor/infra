# ── Microsoft 365 DKIM for qnsc.vn (platform audit N-M8) ────────────────────
#
# Product mail leaves through Microsoft Graph sendMail (Exchange Online) and
# staff mailboxes are on Microsoft 365, but DKIM was never enabled: selector1
# and selector2 under qnsc.vn did not resolve, so Graph mail aligned on SPF
# only. These two CNAMEs are the selector records Exchange asks for; the DKIM
# public keys stay in Exchange and are served through the target domain — this
# file only publishes the names.
#
# Record shape is Microsoft's, not ours:
#   selector<N>._domainkey.qnsc.vn -> selector<N>-qnsc-vn._domainkey.qnscvn.onmicrosoft.com
# (the tenant's initial domain; a public name, and the target of a CNAME that
#  is public DNS by definition).
#
# SEQUENCING (owner, in this order — the records are inert until step 2):
#   1. Apply this stack (or let CI apply it on the owner's "go"): 2 DNS records.
#   2. In Exchange Online PowerShell, as an admin with the DKIM role:
#        Connect-ExchangeOnline
#        New-DkimSigningConfig -DomainName qnsc.vn -Enabled $true   # if none exists
#        Get-DkimSigningConfig -Identity qnsc.vn                   # Status: Valid, Enabled: True
#      If the config already exists: Set-DkimSigningConfig -Identity qnsc.vn -Enabled $true
#   3. Confirm both selectors resolve and the tenant shows them valid
#      (Get-DkimSigningConfig may take up to 48 h to report Valid).
#   4. Only then start the DMARC clock (docs/dns.md): watch rua for 2-4 weeks
#      with DKIM aligned, then p=quarantine, then p=reject, one PR each.
#
# The SES DKIM CNAMEs (three `*._domainkey` records) are still in the zone from
# the AWS exit (audit E-5); they do not collide with selector1/selector2 and are
# deleted by hand when the SES records go. prevent_destroy here: dropping a DKIM
# selector breaks signing for every mailbox on the domain.
locals {
  m365_dkim_selectors = {
    selector1 = "selector1-qnsc-vn._domainkey.qnscvn.onmicrosoft.com"
    selector2 = "selector2-qnsc-vn._domainkey.qnscvn.onmicrosoft.com"
  }
}

resource "cloudflare_dns_record" "m365_dkim" {
  for_each = local.m365_dkim_selectors

  zone_id = var.cloudflare_zone_id
  name    = "${each.key}._domainkey"
  type    = "CNAME"
  content = each.value
  ttl     = 1
  proxied = false # a DKIM selector is read by mail servers, never by a browser

  lifecycle {
    prevent_destroy = true # see docs/incidents/2026-10-09-edge-dns.md

    precondition {
      condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
      error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn: this resource's zone_id forces REPLACEMENT, so a null or empty value would destroy it."
    }
  }
}
