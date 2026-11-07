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
# ONE route, and the WILDCARD SPELLING IS THE ONE THAT WORKS (owner, live, 2026-11-07 ~01:45).
#
# History: the first apply created `coder.qnsc.vn`; `*.coder.qnsc.vn` was rejected 409 (Cloudflare
# stores a route under its parent name, so the pair is one object). The pilot then showed what the docs
# do not say clearly: the plain entry matched ONLY the apex — `code--<ws>--<user>.coder.qnsc.vn` did
# not resolve over WARP. The owner deleted it and re-created it from the dashboard with the `*.` spelling
# on the same tunnel (same description); the dashboard still lists it as `coder.qnsc.vn`, and both the
# apex and a workspace app named `code--<ws>--<user>` now resolve over WARP, to different synthetic
# addresses (in-cluster CoreDNS wildcard: gitops#409).
#
# So the route is created with the wildcard spelling — and the provider READS IT BACK as the wildcard
# spelling too (proved by the import plan: `hostname = "*.coder.qnsc.vn"` on the imported object, and a
# `~ hostname` line would otherwise appear), so the config and the state agree and a post-apply plan is
# empty. This stack ADOPTS the owner's object instead of re-creating it: its id changed when it was
# re-created, so a plain plan would try to create and hit 409. The import block below finds the live
# route through the single-route data source and binds it to the SAME address the state already uses.
#
# Route records are additive and idempotent; prevent_destroy so a bad plan can
# never silently drop the only door to the platform.

locals {
  # Gated on the tunnels exactly like every other edge object: the route carries a
  # tunnel id, and live/onprem creates the tunnels.
  coder_private_hostnames = var.tunnels_exist ? toset(["coder.qnsc.vn"]) : toset([])

}

# ADOPTION (2026-11-07). The address existed in state pointing at the route the owner deleted; the
# refresh drops that object (the route is gone), and this block binds the NEW id to the same address in
# the same plan.
#
# The id is a VARIABLE, not discovered from the API: an import block whose id comes from a data source
# is deferred to apply (the plan then shows a plain create, which is exactly what we must not review
# blind), and the list data source pads `result` to `max_items`, so `one()` over it is meaningless.
# `CODER_HOSTNAME_ROUTE_ID` is a repo variable like the Entra group ids: an identifier, not a secret.
#
# `for_each`: with the tunnels gated off (or the variable unset) no import instance exists, so the id is
# never evaluated — a plain `id =` expression is, and every gated-off plan errored on it.
#
# The id format is `<account_id>/<hostname_route_id>` — the provider's ImportState parses exactly two
# path segments (internal/importpath.ParseImportID with "<account_id>/<hostname_route_id>"); a bare
# route id is rejected.
#
# The resource address is `...hostname_route.coder_route` rather than `.coder` for this reason only;
# the key stays `coder.qnsc.vn` so the import lands on the instance the old object used.
# The stale object sits at the OLD address (`...hostname_route.coder`) and still names the deleted route.
# An import block cannot rescue it: OpenTofu decides against the pre-refresh state, sees the address
# occupied, skips the import, and the refresh then drops the dead object — the plan comes out as a
# plain create (which the API rejects with 409). So the empty address is retired with `removed` (drop
# from state, never destroy — the object is already gone) and the live route is adopted at a NEW address.
removed {
  from = cloudflare_zero_trust_network_hostname_route.coder
}

import {
  for_each = var.coder_hostname_route_id == "" ? toset([]) : local.coder_private_hostnames
  to       = cloudflare_zero_trust_network_hostname_route.coder_route[each.key]
  id       = "${var.cloudflare_account_id}/${var.coder_hostname_route_id}"
}

resource "cloudflare_zero_trust_network_hostname_route" "coder_route" {
  for_each = local.coder_private_hostnames

  account_id = var.cloudflare_account_id
  # The PARENT spelling: it is what the API reads back for a route created with `*.` (the import plan
  # showed `~ hostname = "coder.qnsc.vn" -> "*.coder.qnsc.vn"` when the wildcard was written here), and
  # the attribute is ForceNew — a diff would mean a replace, which `prevent_destroy` blocks forever.
  # The wildcard BEHAVIOUR is stored in the object, not derived from this string: the owner created the
  # route with the `*.` spelling and workspace apps resolve. Anything that ever re-creates this route
  # must use the wildcard spelling (dashboard or API), or subdomains stop resolving.
  hostname = each.value
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
# `identity.groups.id` is an ARRAY of the Entra group object ids carried in the WARP identity, so it is
# always tested with `any(...[*] in {...})` — an `==` against it is a wirefilter type error at the API
# ("cannot perform this operation on type Array(Bytes)", 2026-11-06).
#
# AND it goes in the policy's `identity` attribute, never inside `traffic`: the API rejects an identity
# field in a traffic expression with 400 code 2091 "expression contains fields that are not allowed for
# rule-type traffic" (same day, third failure on this resource). live/edge/tests/static.sh enforces both.
#
# THIRD RULE, same family of mistake: whether a selector takes `[*]` depends on ITS type, and the types
# differ inside one policy — `identity.groups.id` and `net.sni.domains` are Array(Bytes), `net.dst.ip` is
# a scalar Ip ("cannot access index MapEach for type Ip"). Array form ONLY where the field is an array.
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
# WARP and therefore evaluated by Gateway. An unscoped identity-only block for the VLSI group
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

  # The private destinations the tunnels can expose, as a TRAFFIC expression. RFC 1918 + CGNAT; the
  # synthetic IP a private hostname resolves to (172.64.128.0/20) is outside every one of them, which is
  # why the Coder allow below matches on SNI instead.
  #
  # `net.dst.ip` is a SCALAR (type Ip): the API rejects `net.dst.ip[*]` with
  #   400 Filter parsing error (1:15): cannot access index MapEach for type Ip
  # (2026-11-06). Field types are per selector, not per family — identity.groups.id and
  # net.sni.domains ARE arrays and keep `[*]`; net.dst.ip is not and must not.
  private_l4_traffic = "net.dst.ip in {10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10}"
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
  # IDENTITY AND TRAFFIC ARE SEPARATE FIELDS (Cloudflare API: `traffic` = traffic matching expression,
  # `identity` = identity matching expression, `device_posture` = posture). Putting an identity selector
  # in `traffic` is rejected at the API with
  #   400 code 2091 "Invalid expression: expression contains fields that are not allowed for rule-type traffic".
  identity = "any(identity.groups.id[*] in {\"${var.grp_platform_admins_id}\"})"
  traffic  = local.private_l4_traffic

  lifecycle {
    # A rule about the account this file does not own, proven before anything is created: our
    # precedences must be free — a number already in use would reorder the chain silently. (The stale
    # hand-made policy is a `check` below: a warning on every plan, not a plan blocker.)
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

  }
}

# The stale hand-made rule is a WARNING, not a gate: it is disabled, it does not collide with any
# precedence this file uses, and a plan that cannot run until an owner clicks Delete would block every
# unrelated edge change. It must still be deleted, and the plan says so every time (check output is in
# the plan log and the step summary).
check "stale_gateway_policy_removed" {
  assert {
    condition = alltrue([
      for p in data.cloudflare_zero_trust_gateway_policies.existing.result :
      p.name != "Default deny for private traffic"
    ])
    error_message = "The hand-made Gateway policy \"Default deny for private traffic\" (Block, DISABLED since 2026-07-09, never in IaC) should be deleted: Gateway → Firewall policies → that rule → Delete. It duplicates the per-group block this file creates, its expression was never reviewed here, and a disabled block rule in the same list is a trap for whoever enables it next. Deleting a disabled rule changes no traffic."
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
  identity    = "any(identity.groups.id[*] in {\"${var.grp_vlsi_id}\"})"
  traffic     = "any(net.sni.domains[*] == \"coder.qnsc.vn\")"
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
  identity = "any(identity.groups.id[*] in {\"${var.grp_vlsi_id}\"})"
  traffic  = local.private_l4_traffic
}
