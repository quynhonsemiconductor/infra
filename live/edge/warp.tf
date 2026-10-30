# ── WARP for platform admins (runbook §12.1, door 2) ────────────────────────
#
# Admin laptops reach the office LAN (ssh, kubectl, router admin) over WARP →
# the qnsc-admin tunnel's private route (live/onprem, ADMIN_PRIVATE_CIDR).
# Three pieces, all here; only the client install is manual (runbook §12.1):
#   1. device enrollment  — an Access app of type `warp` (who may enroll)
#   2. device profile     — a CUSTOM profile for platform admins; the account
#                           default profile is NOT touched
#   3. gateway proxy      — TCP + UDP on (private-network routing needs it)
#
# Provider: cloudflare v5.28 (this stack's pin).

# ── 1. Device enrollment ────────────────────────────────────────────────────
# Same pattern as the admin doors above: Allow grp-qnsc-platform-admins,
# Require amr=mfa, session 8 h, Entra is the only IdP. There is at most one
# `warp` Access app per account.
resource "cloudflare_zero_trust_access_application" "warp" {
  account_id       = var.cloudflare_account_id
  type             = "warp"
  name             = "Cloudflare WARP enrollment"
  session_duration = "8h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  policies = [{
    id         = cloudflare_zero_trust_access_policy.warp_enroll.id
    precedence = 1
  }]
}

resource "cloudflare_zero_trust_access_policy" "warp_enroll" {
  account_id       = var.cloudflare_account_id
  name             = "platform-admins-mfa-warp"
  decision         = "allow"
  session_duration = "8h"

  include = [{
    azure_ad = {
      id                   = var.grp_platform_admins_id
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
    }
  }]
  require = [{
    auth_method = { auth_method = "mfa" }
  }]
}

# ── 2. Device profile (custom, platform admins only) ────────────────────────
# Split tunnel, Exclude mode. Default exclude list = Cloudflare's published
# "Default Split Tunnel entries recommended by Cloudflare" (terraform example
# `global_exclude_list` on
# https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/configure-warp/route-traffic/split-tunnels/
# ), MINUS var.admin_private_cidr. Every other RFC 1918 and default entry
# stays excluded, so home LANs keep working. A home LAN using the SAME range
# as the office conflicts: it is routed into the tunnel (runbook §12.1).
locals {
  warp_default_exclude_v4 = [
    { address = "10.0.0.0/8", description = "RFC 1918" },
    { address = "100.64.0.0/10", description = "CGNAT" },
    { address = "169.254.0.0/16", description = "DHCP Unspecified" },
    { address = "172.16.0.0/12", description = "RFC 1918" },
    { address = "192.0.0.0/24", description = "IETF protocol assignments" },
    { address = "192.168.0.0/16", description = "RFC 1918" },
    { address = "224.0.0.0/24", description = "Multicast" },
    { address = "240.0.0.0/4", description = "Reserved" },
    { address = "255.255.255.255/32", description = "DHCP Broadcast" },
  ]
  warp_default_exclude_v6 = [
    { address = "fd00::/8", description = "Unique local" },
    { address = "fe80::/10", description = "IPv6 Link Local" },
    { address = "ff01::/16", description = "Multicast" },
    { address = "ff02::/16", description = "Multicast" },
    { address = "ff03::/16", description = "Multicast" },
    { address = "ff04::/16", description = "Multicast" },
    { address = "ff05::/16", description = "Multicast" },
  ]

  # admin range as (network int, prefix)
  warp_admin_prefix = tonumber(split("/", var.admin_private_cidr)[1])
  warp_admin_octets = [for o in split(".", split("/", var.admin_private_cidr)[0]) : tonumber(o)]
  warp_admin_int = (
    local.warp_admin_octets[0] * 16777216 + local.warp_admin_octets[1] * 65536 +
    local.warp_admin_octets[2] * 256 + local.warp_admin_octets[3]
  )

  # For a default entry that CONTAINS the admin range: the complement, i.e. the
  # sibling subnet at every level from the entry's prefix down to the admin
  # prefix. An entry INSIDE the admin range (or equal to it) is dropped.
  warp_exclude_v4 = flatten([
    for e in local.warp_default_exclude_v4 : (
      cidrcontains(var.admin_private_cidr, e.address) ? [] :
      !cidrcontains(e.address, var.admin_private_cidr) ? [e] :
      [
        for i in range(tonumber(split("/", e.address)[1]) + 1, local.warp_admin_prefix + 1) : {
          address = format("%d.%d.%d.%d/%d",
            floor(local.warp_sibling[i] / 16777216) % 256,
            floor(local.warp_sibling[i] / 65536) % 256,
            floor(local.warp_sibling[i] / 256) % 256,
          local.warp_sibling[i] % 256, i)
          description = "${e.description} (minus admin range)"
        }
      ]
    )
  ])

  # network int of the sibling of the admin range's ancestor at each prefix i
  warp_sibling = {
    for i in range(1, 33) : i => (
      floor(local.warp_admin_int / pow(2, 32 - i)) % 2 == 0
      ? floor(local.warp_admin_int / pow(2, 32 - i)) + 1
      : floor(local.warp_admin_int / pow(2, 32 - i)) - 1
    ) * pow(2, 32 - i)
  }

  warp_exclude = concat(local.warp_exclude_v4, local.warp_default_exclude_v6)
}

resource "cloudflare_zero_trust_device_custom_profile" "platform_admins" {
  account_id  = var.cloudflare_account_id
  name        = "platform-admins"
  description = "Platform admins: default split-tunnel excludes minus the office admin range (live/edge warp.tf)"
  enabled     = true
  # Lower = evaluated first; the account default profile is always last. 100
  # leaves room for more specific profiles above it.
  precedence = 100
  match      = "any(identity.groups.id[*] in {\"${var.grp_platform_admins_id}\"})"
  exclude    = local.warp_exclude

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.grp_platform_admins_id))
      error_message = "grp_platform_admins_id must be the Entra group object id (a GUID): an empty or placeholder value would make the device-profile match expression meaningless."
    }
  }
}

# ── 3. Gateway proxy TCP + UDP ──────────────────────────────────────────────
# v5 NOTE: the TCP/UDP proxy toggles are NOT on cloudflare_zero_trust_gateway_
# settings (that resource has no proxy block in v5.28). They live on
# cloudflare_zero_trust_device_settings — an ACCOUNT-WIDE singleton that does
# not support `tofu import`. Its other fields are therefore pinned to the
# values read from the account by the data source below, so the apply changes
# ONLY the two proxy toggles; the plan shows every pinned value.
data "cloudflare_zero_trust_device_settings" "current" {
  account_id = var.cloudflare_account_id
}

resource "cloudflare_zero_trust_device_settings" "this" {
  account_id = var.cloudflare_account_id

  gateway_proxy_enabled     = true
  gateway_udp_proxy_enabled = true

  # Preserved, not managed: whatever the account has today.
  disable_for_time                      = data.cloudflare_zero_trust_device_settings.current.disable_for_time
  external_emergency_signal_enabled     = data.cloudflare_zero_trust_device_settings.current.external_emergency_signal_enabled
  external_emergency_signal_fingerprint = data.cloudflare_zero_trust_device_settings.current.external_emergency_signal_fingerprint
  external_emergency_signal_interval    = data.cloudflare_zero_trust_device_settings.current.external_emergency_signal_interval
  external_emergency_signal_url         = data.cloudflare_zero_trust_device_settings.current.external_emergency_signal_url
  root_certificate_installation_enabled = data.cloudflare_zero_trust_device_settings.current.root_certificate_installation_enabled
  use_zt_virtual_ip                     = data.cloudflare_zero_trust_device_settings.current.use_zt_virtual_ip
}
