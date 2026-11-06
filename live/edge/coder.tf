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
#       2. Copy the token ONCE and pipe it into the platform vault, which is the
#          vault the `platform` ESO store syncs from:
#
#            az keyvault secret set --vault-name kv-qnsc-platform \
#              --name coder-certmanager-cloudflare-dns-token \
#              --file /dev/stdin --content-type text/plain \
#              --expires <token expiry, RFC3339> --tags owner=platform rotated=<date>
#
#          (read the token with a prompt or a password manager; never in argv).
#       3. The gitops ClusterIssuer (Coder lane) references that Secret through an
#          ExternalSecret; nothing is committed and nothing enters TF state.
#
# Route shape notes (Cloudflare docs, 2026-11):
#   - a single `*` is allowed and MUST be a whole label: the wildcard route covers
#     ONE label below it and does NOT cover the apex; hence one route per name;
#   - the docs also say a wildcard route is "saved as" its parent name, so the
#     first apply must confirm the API accepts the pair. If it answers 409, keep
#     *.coder.qnsc.vn and serve the control plane on the same wildcard semantics
#     the API reports — do NOT drop the wildcard, the workspace apps need it.
#
# Route records are additive and idempotent; prevent_destroy so a bad plan can
# never silently drop the only door to the platform.

locals {
  # Gated on the tunnels exactly like every other edge object: the route carries a
  # tunnel id, and live/onprem creates the tunnels.
  coder_private_hostnames = var.tunnels_exist ? toset(["coder.qnsc.vn", "*.coder.qnsc.vn"]) : toset([])
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
  }
}

# A public record for coder.qnsc.vn would put the platform back on the internet,
# behind nothing (there is no Access app by design). The cutover list is the only
# place a host gets published, so refuse the name there.
check "coder_stays_private" {
  assert {
    condition     = !contains(local.cutover, "coder.qnsc.vn") && !contains(local.cutover, "*.coder.qnsc.vn")
    error_message = "coder.qnsc.vn is WARP-only: a public DNS record exposes the Coder control plane with no Access app in front. Keep it out of live/edge onprem.tf local.cutover."
  }
}
