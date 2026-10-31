variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID that owns the zone the OIDC host lives in."
}

variable "cloudflare_api_token" {
  type        = string
  default     = ""
  description = "Operator token with Workers Scripts:Edit and Zone:Workers Routes:Edit. Empty lets the provider fall back to CLOUDFLARE_API_TOKEN."
  sensitive   = true
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Zone id of qnsc.vn (32 hex). Same value as vars.CLOUDFLARE_ZONE_ID in the other Cloudflare stacks."

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be the 32-hex-character zone id of qnsc.vn."
  }
}

variable "oidc_hostname" {
  type        = string
  default     = "oidc.qnsc.vn"
  description = "Public hostname the OIDC documents are served from. Must be the host of var.eso_oidc_issuer in live/identity (tests/static.sh compares them)."

  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.oidc_hostname))
    error_message = "oidc_hostname must be a bare lower-case hostname."
  }
}

variable "oidc_path" {
  type        = string
  default     = "k3s-onprem"
  description = "Path segment under oidc_hostname. One cluster per segment, so a second site is a new path (or a new stack), never a redefined one."

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.oidc_path))
    error_message = "oidc_path must be one lower-case path segment (no slashes)."
  }
}

variable "worker_name" {
  type        = string
  default     = "qnsc-k3s-oidc"
  description = "Cloudflare Worker name (also the account-wide script name)."
}

variable "k3s_jwks" {
  type        = string
  description = <<-EOT
    The cluster's PUBLIC service-account signing keys, exactly as the API
    server serves them:

      kubectl get --raw /openid/v1/jwks

    Passed as TF_VAR_k3s_jwks. Public key material — it is served on the
    internet by design; nothing here is a secret. Re-run after any rotation of
    service.key (README "Rotation").
  EOT

  validation {
    condition = can(length(jsondecode(var.k3s_jwks).keys) > 0 && alltrue([
      for k in jsondecode(var.k3s_jwks).keys : k.kty == "RSA" && k.alg == "RS256"
    ]))
    error_message = "k3s_jwks must be a JWKS document ({\"keys\":[…]}) whose keys are RSA / RS256 — the output of `kubectl get --raw /openid/v1/jwks`."
  }
}
