# Zone-wide TLS baseline (platform audit 2026-11-04, N-H2): plain HTTP to any proxied host — including prod
# rova.qnsc.vn and its API — answered 200 instead of redirecting. These settings were never in IaC.
#
# - always_use_https: every http:// request on a proxied host gets a 301 to https://.
# - min_tls_version 1.2: TLS 1.0/1.1 refused at the edge.
# - automatic_https_rewrites: http:// sub-resources in HTML are rewritten to https://.
#
# Deliberately NOT here: the SSL mode (tunnel origins are not affected by it; change it only after checking every
# non-tunnel proxied origin) and zone-wide HSTS (each product already sends HSTS with its own scope; a zone-wide
# includeSubDomains HSTS is sticky in browsers and needs every subdomain on HTTPS first).

resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}
