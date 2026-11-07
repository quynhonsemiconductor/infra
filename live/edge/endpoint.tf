# ── Laptop phase 0a: staff WARP + Gateway DNS policies (ENDPOINT-DATA-FLOW §1a, §3, §7 phase 0) ──
#
# Owner decisions 2026-11-07: Windows 11 Home, no Intune. NO TLS inspection, NO HTTP rules and NO
# root-CA install in this change (phase 0c later). Enforced at the network layer:
#   * a `staff` device profile (precedence 200, behind the admins' 100) that cannot be switched off;
#   * an L4 block of the private ranges for staff (precedence 930, after admins' allow 900 and the
#     VLSI allow 910 — those still win);
#   * DNS policies: one security block for EVERYONE, then staff-except-admins content block,
#      approved-app allow and app-type block.
#
# Content/app rules apply to grp-qnsc-staff EXCEPT grp-qnsc-platform-admins. Security categories
# apply to everyone (no identity expression = all identities).
#
# Everything except the security policy is gated on var.grp_staff_id != "" (repo variable
# ENTRA_GRP_STAFF_ID), the same shape as coder_access_enabled: no staff group = no enrollment
# widening, no profile, no staff rules.
#
# DNS policy traffic uses the Gateway selectors `dns.security_category`, `dns.content_category`,
# `app.ids` and `app.type.ids` (Cloudflare One docs: DNS policies, Applications and app types).
# The category IDs are the published Domain-categories table
# (https://developers.cloudflare.com/cloudflare-one/traffic-controls/domain-categories/):
#   Security threats (dns.security_category):
#     80 Command and Control & Botnet, 83 Cryptomining, 117 Malware, 131 Phishing,
#     153 Spyware, 176 Domain Generation Algorithm
#   Security Risks (dns.content_category): 169 New Domains, 177 Newly Seen Domains
#   Content block: 2 Adult Themes, 8 Gambling, 17 Questionable Content
#
# App IDs/types are resolved from the live catalogue at plan time (cloudflare_zero_trust_gateway_
# app_types_list) and matched BY NAME: no opaque numeric app/type ids in this file. Missing names
# fail the plan with the catalogue's names in the error.

locals {
  endpoint_enabled = var.grp_staff_id != ""

  staff_identity           = "any(identity.groups.id[*] in {\"${var.grp_staff_id}\"})"
  admin_identity           = "any(identity.groups.id[*] in {\"${var.grp_platform_admins_id}\"})"
  staff_not_admin_identity = "${local.staff_identity} and not(${local.admin_identity})"

  # Gateway application catalogue, read at plan time. App entries carry an application_type_id;
  # type entries do not. This account's catalogue (free plan) has NO "Artificial Intelligence"
  # type and no Claude/Copilot entry, and names carry a suffix ("chatgpt (do not inspect)"), so
  # the allow rule matches approved names by PREFIX and also allows the approved domains, while
  # the block uses the DNS content categories for AI (184) and File Sharing (95) — the same
  # outcome on a plan that cannot select app types.
  endpoint_catalog = local.endpoint_enabled ? data.cloudflare_zero_trust_gateway_app_types_list.this[0].result : []
  gateway_app_list = [
    for i in local.endpoint_catalog : { name = lower(i.name), id = tostring(i.id) }
    if i.application_type_id != null
  ]

  approved_app_ids = compact([
    for pattern in ["^claude( |$)", "^chatgpt( |$)", "^copilot( |$)", "^microsoft copilot( |$)", "^onedrive( |$)", "^microsoft onedrive( |$)", "^sharepoint( |$)", "^microsoft sharepoint( |$)"] :
    try([for a in local.gateway_app_list : a.id if can(regex(pattern, a.name))][0], "")
  ])

  # Domains the owner approved, independent of the catalogue. Cloudflare matches a DNS domain
  # selector on the domain and its subdomains. One line per approved app, signed supporting
  # domains included (login/CDN/redirect hosts belong to the same service or the flow breaks).
  approved_app_domains = [
    # Claude (Anthropic): claude.ai + its sign-in, marketing and API hosts.
    "claude.ai", "claude.com", "anthropic.com",
    # ChatGPT (OpenAI): chat, auth and the static/user-content CDNs.
    "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
    # Microsoft Copilot: the assistant and the M365 cloud redirect hosts.
    "copilot.microsoft.com", "copilot.cloud.microsoft", "m365.cloud.microsoft",
    # OneDrive: web, personal share links (1drv.ms).
    "onedrive.com", "onedrive.live.com", "1drv.ms",
    # SharePoint: tenant hosts and the online office surface.
    "sharepoint.com", "sharepointonline.com",
  ]

  security_dns_traffic = "any(dns.security_category[*] in {80 83 117 131 153 176}) or any(dns.content_category[*] in {169 177})"
  content_dns_traffic  = "any(dns.content_category[*] in {2 8 17})"
  approved_app_traffic = trimspace(join(" or ", compact([
    length(local.approved_app_ids) > 0 ? "any(app.ids[*] in {${join(" ", local.approved_app_ids)}})" : "",
    "any(dns.domains[*] in {${join(" ", [for d in local.approved_app_domains : "\"${d}\""])}})",
  ])))
  blocked_app_type_traffic = "any(dns.content_category[*] in {184 95})"
}

data "cloudflare_zero_trust_gateway_app_types_list" "this" {
  count = local.endpoint_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  max_items  = 1000
}

# ── Staff device profile: locked, office range NOT excluded ──────────────────
# The default Cloudflare split-tunnel list, UNMODIFIED (warp.tf's list without the admin-range
# surgery): staff keep every RFC 1918 range excluded, so home LANs work, and the office plan does
# not route staff into the admin tunnel. `switch_locked` + `allowed_to_leave=false` + no mode
# switch are the "cannot turn it off" part; only the client install is manual.
resource "cloudflare_zero_trust_device_custom_profile" "staff" {
  count = local.endpoint_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "staff"
  description = "All staff: default split-tunnel excludes, WARP locked on (live/edge endpoint.tf)"
  enabled     = true
  # Lower = evaluated first; admins (100) keep their profile, the account default is last.
  precedence = 200
  match      = local.staff_identity

  switch_locked     = true
  allowed_to_leave  = false
  allow_mode_switch = false
  service_mode_v2   = { mode = "warp" }
  exclude           = concat(local.warp_default_exclude_v4, local.warp_default_exclude_v6)

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.grp_staff_id))
      error_message = "grp_staff_id must be the Entra group object id (a GUID): a display name would silently never match."
    }
  }
}

# ── Staff L4 guard: no private destinations ────────────────────────────────
# 930 sits AFTER the admins' allow (900) and the VLSI Coder allow (910), so an admin — who is also
# staff — is allowed first, and a VLSI engineer keeps coder.qnsc.vn. Scoped to the private ranges:
# the split tunnel is Exclude mode, so public traffic also passes Gateway; an unscoped block would
# cut the internet.
resource "cloudflare_zero_trust_gateway_policy" "staff_block_private" {
  count = local.endpoint_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "staff-block-other-private"
  description = "grp-qnsc-staff: no private destination (LAN, k8s, tunnel routes) except what 900/910 allow (live/edge endpoint.tf)"
  precedence  = 930
  enabled     = true
  action      = "block"
  filters     = ["l4"]
  identity    = local.staff_identity
  traffic     = local.private_l4_traffic
}

# ── DNS: security block, ALL identities ────────────────────────────────────
# No identity expression on purpose: malware, phishing, spyware, C2/botnet, cryptomining, DGA and
# newly registered/seen domains are blocked for everyone, admins included. Cloudflare's default
# block page (no custom page in this change).
resource "cloudflare_zero_trust_gateway_policy" "security_block_dns" {
  account_id  = var.cloudflare_account_id
  name        = "security-block-dns"
  description = "Everyone: security threats + newly registered/seen domains (live/edge endpoint.tf)"
  precedence  = 940
  enabled     = true
  action      = "block"
  filters     = ["dns"]
  traffic     = local.security_dns_traffic
}

# ── DNS: staff-not-admin content block ─────────────────────────────────────
resource "cloudflare_zero_trust_gateway_policy" "staff_content_block_dns" {
  count = local.endpoint_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "staff-content-block-dns"
  description = "Staff except admins: adult, gambling, questionable content (live/edge endpoint.tf)"
  precedence  = 950
  enabled     = true
  action      = "block"
  filters     = ["dns"]
  identity    = local.staff_not_admin_identity
  traffic     = local.content_dns_traffic
}

# ── DNS: staff-not-admin ALLOW approved AI + file sharing, BEFORE the block ──
# Precedence must stay below the block (960 < 970): Gateway is first-match, so the allow has to be
# evaluated first or Claude/ChatGPT/Copilot/OneDrive/SharePoint would be blocked by 970.
resource "cloudflare_zero_trust_gateway_policy" "staff_allow_approved_apps_dns" {
  count = local.endpoint_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "staff-allow-approved-apps-dns"
  description = "Staff except admins: the approved AI apps + OneDrive/SharePoint, ahead of the AI/file-sharing block (live/edge endpoint.tf)"
  precedence  = 960
  enabled     = true
  action      = "allow"
  filters     = ["dns"]
  identity    = local.staff_not_admin_identity
  traffic     = local.approved_app_traffic
}

# ── DNS: staff-not-admin block AI + File Sharing content categories ────────
# Category-based because this account's Gateway catalogue exposes no "Artificial Intelligence"
# app type and no Claude/Copilot application (free plan); category 184 is Cloudflare's AI
# classification and 95 is File Sharing. Approved services are allowed at 960, first match.
resource "cloudflare_zero_trust_gateway_policy" "staff_block_app_types_dns" {
  count = local.endpoint_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "staff-block-ai-filesharing-dns"
  description = "Staff except admins: AI (184) and File Sharing (95) content categories, minus the allow at 960 (live/edge endpoint.tf)"
  precedence  = 970
  enabled     = true
  action      = "block"
  filters     = ["dns"]
  identity    = local.staff_not_admin_identity
  traffic     = local.blocked_app_type_traffic
}
