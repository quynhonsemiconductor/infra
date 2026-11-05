#!/usr/bin/env bash
# cloudflare-ssh-ca.sh — owner-run: print the account's Access-for-Infrastructure
# SSH CA public key (the one the Gateway SSH proxy signs short-lived certs
# with). Read-only when the CA exists; creates it once when it does not.
#
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... ./scripts/owner/cloudflare-ssh-ca.sh
#
# The token needs "Access: SSH Auditing" Edit (Cloudflare docs, "SSH with
# Access for Infrastructure"). The public key is NOT a secret; put it in the
# LOCAL Ansible inventory as `node_ssh_ca_public_key`, never in Git (it is the
# trust anchor for shell access to every node that includes the role).
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
command -v curl >/dev/null || { echo "STOP: need curl" >&2; exit 1; }
command -v jq >/dev/null || { echo "STOP: need jq" >&2; exit 1; }

api="https://api.cloudflare.com/client/v4/accounts/$acct/access/gateway_ca"
auth=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")

# GET lists the account's SSH CAs; an empty list means none exists yet.
resp=$(curl -fsS "${auth[@]}" "$api") || {
  echo "STOP: Cloudflare API refused the request (token scope/plan?)" >&2
  exit 1
}
key=$(jq -r 'if (.result | type) == "array" then (.result[0].public_key // empty) else (.result.public_key // empty) end' <<<"$resp")

if [[ -z "$key" ]]; then
  echo "no SSH CA on the account — creating the Gateway CA" >&2
  resp=$(curl -fsS -X POST "${auth[@]}" "$api") || {
    echo "STOP: could not create the Gateway CA (plan or token scope)" >&2
    exit 1
  }
  key=$(jq -r '.result.public_key // empty' <<<"$resp")
fi

[[ -n "$key" ]] || { echo "STOP: the API returned no public_key" >&2; exit 1; }
printf '%s\n' "$key"
