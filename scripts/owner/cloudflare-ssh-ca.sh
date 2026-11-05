#!/usr/bin/env bash
# cloudflare-ssh-ca.sh — owner-run: print the account's Access-for-Infrastructure
# SSH CA public key (the one the Gateway SSH proxy signs short-lived certs
# with). Read-only when the CA exists; creates it ONCE when the account truly
# has none.
#
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... ./scripts/owner/cloudflare-ssh-ca.sh
#
# The token needs "Access: SSH Auditing" Edit (Cloudflare docs, "SSH with
# Access for Infrastructure"). The public key is NOT a secret; put it in the
# LOCAL Ansible inventory as `node_ssh_ca_public_key`, never in Git (it is the
# trust anchor for shell access to every node that includes the role).
#
# The bearer token is passed to curl through `-K -` (stdin), never in argv.
# POST happens ONLY when a GET with this token returned a valid success:true
# response with no CA (or a 404) and the account id is a syntactically valid
# 32-hex id. A 401/403 or success:false fails closed: never create a CA on a
# guess.
#
# This exists because the cloudflare provider v5 has no gateway-CA resource:
# cloudflare_zero_trust_access_short_lived_certificate creates a PER-APP CA,
# which Cloudflare documents as incompatible with the Gateway SSH proxy.
set -euo pipefail

acct="${CLOUDFLARE_ACCOUNT_ID:-}"
token="${CLOUDFLARE_API_TOKEN:-}"
[[ -n "$acct" && -n "$token" ]] || {
  echo "STOP: set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN (Access: SSH Auditing Edit)" >&2
  exit 1
}
[[ "$acct" =~ ^[0-9a-f]{32}$ ]] || {
  echo "STOP: CLOUDFLARE_ACCOUNT_ID must be the 32-hex account id (confirm it in the dashboard)" >&2
  exit 1
}
command -v curl >/dev/null || { echo "STOP: need curl" >&2; exit 1; }
command -v jq >/dev/null || { echo "STOP: need jq" >&2; exit 1; }

api="https://api.cloudflare.com/client/v4/accounts/$acct/access/gateway_ca"
body=$(mktemp "${TMPDIR:-/tmp}/cf-gateway-ca.XXXXXX")
trap 'rm -f "$body"' EXIT

# Request through a curl config on stdin: the token never appears in argv.
cf() { # cf <GET|POST>
  local method="$1" auth
  auth=$(printf 'header = "Authorization: Bearer %s"' "$token")
  {
    printf '%s\n' "$auth"
    printf '%s\n' 'header = "Content-Type: application/json"'
    printf '%s\n' 'silent'
    printf '%s\n' 'show-error'
    printf '%s\n' 'write-out = "%{http_code}"'
    [[ "$method" == POST ]] && printf '%s\n' 'request = "POST"'
    printf 'url = "%s"\n' "$api"
  } | curl -K - -o "$body"
}

http=$(cf GET) || { echo "STOP: cannot reach the Cloudflare API" >&2; exit 1; }

case "$http" in
  200)
    if [[ "$(jq -r '.success // false' "$body")" != "true" ]]; then
      echo "STOP: GET gateway_ca returned success:false (token scope/plan) — refusing to create" >&2
      exit 1
    fi
    key=$(jq -r 'if (.result | type) == "array" then (.result[0].public_key // empty) else (.result.public_key // empty) end' "$body")
    ;;
  404)
    key=""
    ;;
  *)
    echo "STOP: GET gateway_ca returned HTTP $http (401/403 = token scope, plan or wrong account; refusing to create)" >&2
    exit 1
    ;;
esac

if [[ -z "$key" ]]; then
  echo "no SSH CA on the confirmed account — creating the Gateway CA once" >&2
  http=$(cf POST) || { echo "STOP: cannot reach the Cloudflare API" >&2; exit 1; }
  case "$http" in
    200|201)
      if [[ "$(jq -r '.success // false' "$body")" != "true" ]]; then
        echo "STOP: POST gateway_ca returned success:false (scope or plan)" >&2
        exit 1
      fi
      key=$(jq -r 'if (.result | type) == "array" then (.result[0].public_key // empty) else (.result.public_key // empty) end' "$body")
      ;;
    *)
      echo "STOP: POST gateway_ca returned HTTP $http (scope or plan); no CA public key" >&2
      exit 1
      ;;
  esac
fi

[[ -n "$key" ]] || { echo "STOP: the API returned no public_key" >&2; exit 1; }
printf '%s\n' "$key"
