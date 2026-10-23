#!/bin/zsh
# zt-inventory.sh — READ-ONLY Zero Trust inventory (owner-run or CI-fed).
# Token via env CF_API_TOKEN (never argv, never printed). Lists everything
# that must not be duplicated or destroyed by the tofu adoption:
#   IdPs · Access apps + their policies · Tunnels · device-posture profiles ·
#   gateway firewall policies
set -euo pipefail
: ${CF_API_TOKEN:?"export CF_API_TOKEN=<token with Zero Trust read>; it is never printed"}
acc="${CLOUDFLARE_ACCOUNT_ID:?export CLOUDFLARE_ACCOUNT_ID}"
api="https://api.cloudflare.com/client/v4"
h=(-H "Authorization: Bearer $CF_API_TOKEN")

echo "== Identity providers"
curl -fsS "$api/accounts/$acc/access/identity_providers" "${h[@]}" \
  | jq -r '.result[] | "\(.id)  \(.type)  \(.name)  config.client_id=\(.config.client_id // "-")"'

echo; echo "== Access applications"
curl -fsS "$api/accounts/$acc/access/apps" "${h[@]}" | jq -r '.result[] | "\(.id)  \(.domain)  \(.name)  type=\(.type)  idps=\(.allowed_idps // [] | join(","))"' \
| while IFS= read -r row; do
    echo "$row"
    id=$(echo "$row" | cut -d' ' -f1)
    curl -fsS "$api/accounts/$acc/access/apps/$id/policies" "${h[@]}" \
      | jq -r '.result[] | "    policy \(.id)  \(.name)  decision=\(.decision)  include=\(.include | tostring | .[0:160])"'
  done

echo; echo "== Tunnels"
curl -fsS "$api/accounts/$acc/cfd_tunnel?is_deleted=false" "${h[@]}" \
  | jq -r '.result[] | "\(.id)  \(.name)  status=\(.status)"'

echo; echo "== Device posture profiles"
curl -fsS "$api/accounts/$acc/devices/posture" "${h[@]}" \
  | jq -r '.result[] | "\(.id)  \(.name)  type=\(.type)"' 2>/dev/null || echo "  (endpoint not permitted for this token)"

echo; echo "== Gateway firewall policies"
curl -fsS "$api/accounts/$acc/gateway/rules" "${h[@]}" \
  | jq -r '.result[] | "\(.id)  \(.name)  enabled=\(.enabled)  action=\(.action)"' 2>/dev/null || echo "  (endpoint not permitted for this token)"
