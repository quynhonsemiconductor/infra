# ── Coder over WARP only (VLSI platform, design §5.2) ───────────────────────
#
# coder.qnsc.vn and *.coder.qnsc.vn are PRIVATE hostnames. They are reachable
# ONLY from a WARP-enrolled company device, through a Zero Trust HOSTNAME ROUTE
# on the qnsc-apps tunnel:
#
#   WARP DNS  ── Gateway resolves the name to the tunnel's virtual network
#   Gateway   ── assigns an "initial resolved IP" and routes it down the tunnel
#   cloudflared on k3s-01 ── resolves the name with ITS host resolver (in-cluster:
#                             CoreDNS) and connects to the origin with the TLS
#                             identity Coder's own certificate carries.
#
# There is NO public DNS record and NO Cloudflare Access app in front:
#   - not proxied: no `cloudflare_dns_record` for these names, so the host does
#     not exist on the public internet at all (the only public records are the
#     _acme-challenge TXT records cert-manager writes for the certificate);
#   - no Access app: Access answers every request with a browser redirect, and
#     Coder is not only a web page — the `coder` CLI, `coder ssh`, the workspace
#     agents and the websockets under /api/v2 do not follow it. Coder's own
#     Entra OIDC (live/identity `coder.tf`) is the single sign-on; the Entra group
#     allow list is the door.
#
# Prerequisites this file does NOT create (each is somebody else's deliverable):
#   - the in-cluster cloudflared must be 2025.7.0 or newer for private hostname
#     routes (Cloudflare's supported-versions table);
#   - CoreDNS must answer coder.qnsc.vn and *.coder.qnsc.vn (gitops, the Coder
#     lane): cloudflared resolves the name before it connects, so an NXDOMAIN
#     here fails the request even though the route exists;
#   - the WARP split tunnel must NOT exclude the initial resolved IP ranges
#     (172.64.128.0/20, 2606:4700:0cf1:4000::/64). warp.tf excludes the RFC 1918
#     ranges and the Cloudflare defaults, none of which contain them, so the
#     profile is already correct;
#   - Gateway proxy on (warp.tf, both toggles), and the host's TLD must not be in
#     the DNS Local Domain Fallback list;
#   - TLS: cert-manager with a Let's Encrypt DNS-01 wildcard for
#     coder.qnsc.vn + *.coder.qnsc.vn (design §5.2 — Universal SSL cannot cover a
#     second-level wildcard such as *.coder.qnsc.vn). The Cloudflare API token
#     that cert-manager needs is minted by the owner, never by tofu: Cloudflare
#     has no API for creating API tokens. Owner steps:
#       1. Dashboard → My Profile → API Tokens → Create Custom Token, name
#          "cert-manager DNS-01 (qnsc.vn)": Permissions `Zone → DNS → Edit` and
#          `Zone → Zone → Read`; Zone Resources `Include → Specific zone → qnsc.vn`;
#          no account resources; TTL 1 year (calendar reminder to rotate).
#          NOTE: `DNS:Edit` is ZONE-WIDE by construction — Cloudflare has no
#          per-record or per-prefix permission, so the token CAN write any record
#          in qnsc.vn, not just `_acme-challenge`. Scope it by ZONE (only qnsc.vn),
#          store it where only cert-manager can read it, and rotate it yearly.
#       2. Copy the token ONCE and pipe it into the vault the `platform` ESO store
#          syncs from:
#
#            az keyvault secret set --vault-name kv-qnsc-platform \
#              --name coder-certmanager-cloudflare-dns-token \
#              --file /dev/stdin --content-type text/plain \
#              --expires <token expiry, RFC3339> --tags owner=platform rotated=<date>
#
#          (read it with a prompt or a password manager; never in argv).
#       3. Delivery is NARROW: the ExternalSecret and the resulting Secret live in the
#          cert-manager/coder namespace the Coder lane deploys (the issuer reads it
#          from there), never a cluster-wide copy. Nothing is committed and nothing
#          enters TF state.
#       4. Rotation (1 year, at least): create the replacement token, write it over
#          the same vault secret name, wait for ESO to sync, then revoke the old
#          token in the dashboard. The cert-manager solver reads the Secret on each
#          issuance, so no restart is needed.
#
# ONE route, not two (finding from the first apply, run 42205180725).
#
# Cloudflare stores a private hostname route under its PARENT name: a route entered
# as `*.coder.qnsc.vn` is "saved as" `coder.qnsc.vn`, and the stored entry matches
# the name and one label below it (`*.internal.local` is saved as `internal.local`,
# "will match all subdomains at the wildcard level", covers `foo.internal.local` but
# not `foo.bar.internal.local" — Cloudflare Zero Trust docs, "Connect a private
# hostname", wildcard section). The first apply created `coder.qnsc.vn` and the API
# answered 409 for `*.coder.qnsc.vn`: the same stored object, under the other
# spelling. Creating both is therefore impossible, not merely redundant.
#
# So this file keeps the name the API kept — `coder.qnsc.vn` — and relies on that
# entry matching both the control plane and the workspace apps at ONE label
# (`ws1.coder.qnsc.vn`). That is also what a wildcard entry would have done.
#
# If the pilot shows the apex resolving but a workspace app not, the fix is to
# recreate the route from the dashboard with the `*.` spelling (Cloudflare must
# accept it once the plain name is gone) and import it under the same key:
#   tofu import 'cloudflare_zero_trust_network_hostname_route.coder["coder.qnsc.vn"]' <route id>
# Do not add a second resource for the same name.
#
# Route records are additive and idempotent; prevent_destroy so a bad plan can
# never silently drop the only door to the platform.

locals {
  # Gated on the tunnels exactly like every other edge object: the route carries a
  # tunnel id, and live/onprem creates the tunnels.
  coder_private_hostnames = var.tunnels_exist ? toset(["coder.qnsc.vn"]) : toset([])
}

resource "cloudflare_zero_trust_network_hostname_route" "coder" {
  for_each = local.coder_private_hostnames

  account_id = var.cloudflare_account_id
  hostname   = each.value
  # The in-cluster tunnel: Coder is a Kubernetes Service, and only the in-cluster
  # cloudflared can reach it (the qnsc-admin tunnel runs on pve01, outside k3s).
  tunnel_id = data.cloudflare_zero_trust_tunnel_cloudflared.qnsc_apps[0].id
  comment   = "VLSI platform: Coder over WARP only (live/edge coder.tf)"

  lifecycle {
    prevent_destroy = true

    # A public record for coder.qnsc.vn would put the platform back on the internet,
    # behind nothing (there is no Access app by design). local.cutover is the only place
    # a host gets published, so refuse the name there — a hard plan failure, not a warning.
    precondition {
      condition     = !contains(local.cutover, "coder.qnsc.vn") && !contains(local.cutover, "*.coder.qnsc.vn")
      error_message = "coder.qnsc.vn is WARP-only: a public DNS record exposes the Coder control plane with no Access app in front. Keep it out of live/edge onprem.tf local.cutover."
    }
  }
}


# ── Gateway network policies: least privilege for the VLSI group ────────────
#
# Enrolling grp-qnsc-vlsi in WARP (warp.tf) without these would hand the group the
# whole private network the tunnels and the device profile expose: the office LAN,
# the k8s API, every other route. L4 (network) policies are the firewall for that
# traffic, evaluated before anything reaches a tunnel. They are IDENTITY policies:
# `identity.groups.id` is the Entra group object id carried in the WARP identity.
#
#   900 allow  platform admins             — today's access, stated explicitly so a
#                                            later blanket rule cannot take it away
#   910 allow  grp-qnsc-vlsi → Coder hosts — the only private destination it needs
#   920 block  grp-qnsc-vlsi → private IPs  — LAN, k8s, any route added later. SCOPED to
#                                            the private ranges on purpose, see below.
#
# SNI, not IP, for the ALLOW: the hostname route resolves to a synthetic address from the
# tunnel's virtual network, so the destination IP does not identify the service.
# `net.sni.domains` matches the domain and its subdomains (coder.qnsc.vn covers
# *.coder.qnsc.vn).
#
# THE BLOCK MUST BE DESTINATION-SCOPED. The device profile is split tunnel in **Exclude**
# mode: everything NOT in the exclude list — the public internet included — is sent through
# WARP and therefore evaluated by Gateway. An unscoped `identity.groups.id == vlsi` block
# would cut a VLSI engineer off the public internet: no login.microsoftonline.com (Coder's
# own OIDC sign-in), no cloudflareaccess.com, nothing. So 920 matches the private ranges
# only, and public traffic falls through to the default (allow, unchanged from today).
#
# DNS is NOT affected by an L4 block: DNS filtering is its own Gateway policy type
# (allow/block by domain and resolver IP), and this stack creates none. Resolution, including
# the private hostname route and the OIDC issuer's name, keeps working under the block.
#
# Everything is gated on var.grp_vlsi_id: empty = no enrollment (warp.tf) and no policy,
# so the group can never be half-guarded. Plan availability: Gateway L4 network policies
# with identity selectors are part of the Zero Trust plans (Free included — see the PR
# body for the citations); the owner confirms the account's plan before the first apply.
#
# Precedences are 900/910/920, not the low numbers a hand-made rule usually carries, and the
# plan reads every policy on the account and refuses to apply when one of them is taken or
# when the stale "Default deny for private traffic" rule is still there.
locals {
  coder_access_enabled = var.tunnels_exist && var.grp_vlsi_id != ""

  # Precedences deliberately far above the low numbers a hand-made rule tends to sit on, and
  # checked against the account below: Cloudflare requires a unique precedence per policy, and a
  # silent renumber would reorder the rules without anyone reading a diff.
  gateway_policy_names = [
    "platform-admins-allow-l4",
    "vlsi-allow-coder",
    "vlsi-block-other-private",
  ]
  gateway_precedences = [900, 910, 920]
}

# Every L4 policy on the account, read at plan time. Two facts the plan must have before it
# creates anything: our precedences are free, and the stale hand-made rule is gone (see the
# precondition below).
data "cloudflare_zero_trust_gateway_policies" "existing" {
  account_id = var.cloudflare_account_id
  max_items  = 1000
}

resource "cloudflare_zero_trust_gateway_policy" "admin_allow_private" {
  account_id  = var.cloudflare_account_id
  name        = "platform-admins-allow-l4"
  description = "Platform admins keep today's access ahead of any group-specific rule (live/edge coder.tf)"
  precedence  = 900
  enabled     = true
  action      = "allow"
  filters     = ["l4"]
  traffic     = "identity.groups.id == \"${var.grp_platform_admins_id}\""

  lifecycle {
    # Two rules about the account this file does not own, both proven before anything is created:
    #  1. our precedences must be free — a number already in use would reorder the chain silently;
    #  2. the hand-made "Default deny for private traffic" (Block, DISABLED since 2026-07-09, never
    #     in IaC) must be DELETED by the owner, not worked around: its expression was never reviewed
    #     here, it duplicates the per-group block below, and a disabled block rule sitting in the same
    #     list is a trap for the next person who enables it. Dashboard → Gateway → Firewall policies →
    #     the rule → Delete (it is disabled, so deleting it changes no traffic).
    precondition {
      condition = alltrue([
        for p in data.cloudflare_zero_trust_gateway_policies.existing.result : (
          contains(local.gateway_policy_names, p.name) ||
          p.precedence == null ||
          !contains(local.gateway_precedences, tonumber(tostring(p.precedence)))
        )
      ])
      error_message = "A Gateway L4 policy already uses precedence 900, 910 or 920 (or one of this file's names is taken). Renumber this file's policies and re-plan; do not let two rules share a number."
    }

    precondition {
      condition = alltrue([
        for p in data.cloudflare_zero_trust_gateway_policies.existing.result :
        p.name != "Default deny for private traffic"
      ])
      error_message = "The hand-made Gateway policy \"Default deny for private traffic\" (disabled since 2026-07-09, not in IaC) must be deleted before this applies: Gateway → Firewall policies → that rule → Delete. It duplicates the per-group block this file creates, and its expression was never reviewed. Deleting a disabled rule changes no traffic."
    }
  }
}

resource "cloudflare_zero_trust_gateway_policy" "vlsi_allow_coder" {
  count = local.coder_access_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "vlsi-allow-coder"
  description = "grp-qnsc-vlsi reaches only the Coder hostnames (live/edge coder.tf)"
  precedence  = 910
  enabled     = true
  action      = "allow"
  filters     = ["l4"]
  traffic     = "identity.groups.id == \"${var.grp_vlsi_id}\" and any(net.sni.domains[*] == \"coder.qnsc.vn\")"
}

resource "cloudflare_zero_trust_gateway_policy" "vlsi_block_private" {
  count = local.coder_access_enabled ? 1 : 0

  account_id  = var.cloudflare_account_id
  name        = "vlsi-block-other-private"
  description = "grp-qnsc-vlsi: no other private destination (LAN, k8s, other routes) (live/edge coder.tf)"
  precedence  = 920
  enabled     = true
  action      = "block"
  filters     = ["l4"]
  # SCOPED to the private ranges: the split tunnel is Exclude mode, so PUBLIC traffic also
  # passes through Gateway, and an unscoped block here would take away the internet — and
  # with it Coder's OIDC sign-in (login.microsoftonline.com) and cloudflareaccess.com.
  # RFC 1918 + CGNAT covers every private destination the tunnels can expose; the allow
  # above already claims the one public-looking destination the group needs (the Coder
  # hostname, matched on SNI before this rule). Only the allow needs to be there: a request
  # that reaches Coder matches 100 first, everything else private matches here.
  traffic = "identity.groups.id == \"${var.grp_vlsi_id}\" and any(net.dst.ip[*] in {10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10})"
}
