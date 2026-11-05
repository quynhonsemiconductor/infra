# ── SSH for people: Cloudflare Access for Infrastructure ────────────────────
#
# Owner decision 2026-11-05: no shared passwords and no long-lived personal
# keys. A platform admin enables WARP (warp.tf), runs `ssh <user>@<node ip>`,
# and Cloudflare's Gateway SSH proxy checks Entra + MFA and issues a
# short-lived SSH certificate. The node trusts the account's Access SSH CA;
# the CA public key is written by the `ssh_infra` Ansible role.
#
# The public repo carries the SHAPE only: target hostnames, addresses and
# usernames come from TF_VAR_ssh_infra_targets (JSON in a repo secret /
# owner environment file). Empty = feature off (plan unchanged).
#
#   {
#     "ai-01": { "hostname": "ai-01", "ipv4": "192.0.2.21", "usernames": ["<login>"] }
#   }
#
# The account's GATEWAY CA is not exposed by the provider (the
# zero_trust_access_short_lived_certificate resource creates a per-APP CA, which
# Cloudflare documents as incompatible with the Gateway SSH proxy). The owner
# reads/creates it with scripts/owner/cloudflare-ssh-ca.sh and puts the public
# key in the LOCAL Ansible inventory (node_ssh_ca_public_key).

variable "ssh_infra_targets" {
  type = map(object({
    hostname  = string
    ipv4      = string
    usernames = list(string)
  }))
  default     = {}
  description = <<-EOT
    Access for Infrastructure SSH targets, keyed by node. hostname is the friendly target name, ipv4 the node's
    address on the admin VLAN, usernames the UNIX accounts a matching admin may use (they must exist on the node
    and be listed in the LOCAL Ansible inventory node_admin_users). Supplied as TF_VAR_ssh_infra_targets (JSON) from
    a repo secret/owner env file; no address or person name is committed to this public repo. Empty = no SSH targets.
  EOT

  validation {
    condition = alltrue([
      for k, t in var.ssh_infra_targets :
      can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", k)) &&
      can(regex("^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253}[A-Za-z0-9])?$", t.hostname)) &&
      can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", t.ipv4)) &&
      can(cidrhost("${t.ipv4}/32", 0)) &&
      length(t.usernames) > 0 &&
      alltrue([for u in t.usernames : (can(regex("^[a-z_][a-z0-9_-]{0,31}$", u)) && u != "root" && u != "qnsc" && u != "ubuntu")])
    ])
    error_message = "Each ssh_infra_targets entry needs a DNS-label key, a plain hostname, a bare IPv4 address and a non-empty list of valid UNIX usernames (root/qnsc/ubuntu are refused)."
  }
}

# The target is the address Cloudflare reaches THROUGH the admin tunnel's
# private route (live/onprem/tunnels.tf). Omit virtual_network_id: the provider
# defaults to the account's default virtual network, which the tunnel route
# uses.
resource "cloudflare_zero_trust_access_infrastructure_target" "node" {
  for_each = var.ssh_infra_targets

  account_id = var.cloudflare_account_id
  hostname   = each.value.hostname
  ip = {
    ipv4 = {
      ip_addr = each.value.ipv4
    }
  }
}

# One Infrastructure application per target, SSH/22. The policy allows the
# platform-admins Entra group with an MFA requirement and restricts the UNIX
# usernames (Cloudflare's connection rule); the short-lived certificate is
# issued by the Gateway CA after that check.
resource "cloudflare_zero_trust_access_application" "ssh_infra" {
  for_each = var.ssh_infra_targets

  account_id = var.cloudflare_account_id
  name       = "ssh-${each.key}"
  type       = "infrastructure"

  # WARP is the transport for an infrastructure target; the SSH client has no
  # browser, so Cloudflare uses the device's WARP/IdP session.
  session_duration = "1h"
  allowed_idps     = [cloudflare_zero_trust_access_identity_provider.entra.id]

  target_criteria = [{
    port     = 22
    protocol = "SSH"
    include = {
      target_attributes = {
        hostname = [each.value.hostname]
      }
    }
  }]

  policies = [{
    name       = "platform-admins-mfa-ssh"
    decision   = "allow"
    precedence = 1
    include = [{
      azure_ad = {
        id                   = var.grp_platform_admins_id
        identity_provider_id = cloudflare_zero_trust_access_identity_provider.entra.id
      }
    }]
    require = [{
      auth_method = { auth_method = "mfa" }
    }]
    connection_rules = {
      ssh = {
        usernames = each.value.usernames
      }
    }
  }]
}
