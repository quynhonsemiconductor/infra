#!/usr/bin/env bash
# Read-only audit of the Cloudflare account API tokens, and the map from the
# R2 Key Vault secrets to them.
#
# WHY THIS RUNS BY HAND. The CF token list needs an account token with
# "Account API Tokens: Read". Nobody keeps one for automation: a token that can
# read every other token is a high-value target, and the sandbox/CI identities
# must not hold it. The owner creates one, runs this, deletes it (the printed
# checklist ends with that step).
#
#   export CLOUDFLARE_ACCOUNT_ID=<account id>
#   export CF_AUDIT_TOKEN=<temporary token: Account API Tokens: Read, 1-day TTL>
#   scripts/owner/cf-tokens-audit.sh
#
# Offline (the regression test): scripts/owner/cf-tokens-audit.sh --policy-fixture FILE
# prints the policy section for the token objects in FILE (JSONL). No network.
#
# Output, and nothing else:
#   1. every account token: id, name, status, created, last used, expiry, and a
#      one-line policy summary (effect + resource scope);
#   2. for every `*-access-key-id` secret in kv-qnsc-prod / kv-qnsc-dev /
#      kv-qnsc-platform: "<vault>/<secret> -> <token name>" or "-> NO MATCHING TOKEN".
#
# It never prints a token value or a secret value: the secret is read into a
# shell variable and compared; only the NAME of the matching token is printed.
# GET requests only; `az keyvault secret show` is a read.
#
# Exit codes: 0 all checks ran; 1 a secret has no matching token (a dead secret,
# or a token deleted while its consumer still reads it); 2 a lookup could not run.
set -euo pipefail
umask 077


usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# One policy summariser, used for the live list and for --policy-fixture (its
# regression test). A policy resource is EITHER an object like
# {"com.cloudflare.api.account.zone": "abc"} OR the string "*" — the string
# case crashed `keys[0]` (owner run 2026-11-06, once per token).
POLICY_JQ='
  [ .policies[]?
    | "\(.effect): " + ([.permission_groups[]?.name] | join(",")) + " @ "
      + ([ (.resources | if type == "array" then .[] else . end)
           | if type == "object" then (keys[0] + "=" + (.[keys[0]] | tostring))
             else tostring
             end ] | join("; "))
  ] | join(" | ")'

# print_policies <jsonl file of token objects>
print_policies() {
  local file=$1 t id name pol
  while IFS= read -r t; do
    id=$(jq -r '.id' <<<"$t")
    name=$(jq -r '.name' <<<"$t")
    pol=$(jq -r "$POLICY_JQ" <<<"$t")
    printf '%s\t%s\t%s\n' "$id" "$name" "${pol:-none}"
  done < "$file" | column -t -s $'\t'
}

FIXTURE=""
while [ $# -gt 0 ]; do
  case $1 in
    --policy-fixture) FIXTURE=${2:?--policy-fixture needs a JSONL file}; shift 2 ;;
    -h | --help) usage 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

if [ -n "$FIXTURE" ]; then
  # Offline regression mode: token objects in, policy lines out. No network, no az.
  [ -r "$FIXTURE" ] || { echo "STOP: cannot read $FIXTURE" >&2; exit 2; }
  echo "# Policy scope (fixture: $FIXTURE)"
  print_policies "$FIXTURE"
  exit 0
fi

: "${CLOUDFLARE_ACCOUNT_ID:?set CLOUDFLARE_ACCOUNT_ID (32 hex chars)}"
: "${CF_AUDIT_TOKEN:?set CF_AUDIT_TOKEN to a TEMPORARY token with 'Account API Tokens: Read'}"
command -v curl >/dev/null || { echo "need curl" >&2; exit 2; }
command -v jq >/dev/null || { echo "need jq" >&2; exit 2; }
command -v az >/dev/null || { echo "need az (az login done)" >&2; exit 2; }

API="https://api.cloudflare.com/client/v4"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. Tokens ───────────────────────────────────────────────────────────────
page=1
: > "$TMP/tokens.jsonl"
while :; do
  if ! curl -fsS -H "Authorization: Bearer ${CF_AUDIT_TOKEN}" \
       "${API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/tokens?per_page=50&page=${page}" \
       -o "$TMP/page.json"; then
    echo "STOP: the tokens list failed (token lacks Account API Tokens: Read, or the account id is wrong)" >&2
    exit 2
  fi
  jq -e '.success == true' "$TMP/page.json" >/dev/null || {
    echo "STOP: Cloudflare refused the tokens list: $(jq -r '.errors[0].message // "unknown"' "$TMP/page.json")" >&2
    exit 2
  }
  jq -c '.result[]' "$TMP/page.json" >> "$TMP/tokens.jsonl"
  total=$(jq -r '.result_info.total_count // 0' "$TMP/page.json")
  have=$(wc -l < "$TMP/tokens.jsonl" | tr -d ' ')
  [ "$have" -lt "$total" ] || break
  page=$((page + 1))
done

echo "# Cloudflare API tokens (${CLOUDFLARE_ACCOUNT_ID})"
printf '%-34s %-9s %-20s %-20s %s\n' ID NAME STATUS LAST_USED EXPIRES
while IFS= read -r t; do
  id=$(jq -r '.id' <<<"$t")
  name=$(jq -r '.name' <<<"$t")
  status=$(jq -r '.status // "-"' <<<"$t")
  last=$(jq -r '.last_used_on // "never"' <<<"$t")
  exp=$(jq -r '.expires_on // "no expiry"' <<<"$t")
  printf '%-34s %-9s %-20s %-20s %s\n' "$id" "$name" "$status" "${last:0:19}" "${exp:0:19}"
done < "$TMP/tokens.jsonl"

echo
echo "# Policy scope, one line per token (effect / permission groups / resources)"
print_policies "$TMP/tokens.jsonl"

# ── 2. R2 secrets → token ───────────────────────────────────────────────────
echo
echo "# R2 Key Vault secrets -> token"
jq -r '.id' "$TMP/tokens.jsonl" | sort > "$TMP/ids.txt"
jq -r '.id + "\t" + .name' "$TMP/tokens.jsonl" > "$TMP/id-name.txt"
rc=0

for vault in kv-qnsc-prod kv-qnsc-dev kv-qnsc-platform; do
  if ! names=$(az keyvault secret list --vault-name "$vault" \
                 --query "[?ends_with(name, '-access-key-id')].name" -o tsv 2>"$TMP/vault.err"); then
    printf '%s -> ERROR listing secrets (need Key Vault Secrets User on this vault): %s\n' \
      "$vault" "$(head -1 "$TMP/vault.err")"
    rc=2
    continue
  fi
  [ -n "$names" ] || { printf '%s -> no *-access-key-id secrets\n' "$vault"; continue; }
  while IFS= read -r secret; do
    [ -n "$secret" ] || continue
    # Read the VALUE into a variable; never print it. `--query value -o tsv`.
    value=$(az keyvault secret show --vault-name "$vault" --name "$secret" --query value -o tsv 2>/dev/null || true)
    if [ -z "$value" ]; then
      printf '%s/%s -> ERROR reading the secret\n' "$vault" "$secret"
      rc=2
      continue
    fi
    match=$(awk -v id="$value" -F '\t' '$1 == id {print $2; exit}' "$TMP/id-name.txt")
    if [ -n "$match" ]; then
      printf '%s/%s -> %s\n' "$vault" "$secret" "$match"
    else
      printf '%s/%s -> NO MATCHING TOKEN (dead secret, or the token was deleted)\n' "$vault" "$secret"
      rc=1
    fi
  done <<<"$names"
done

# ── 3. Human checklist ──────────────────────────────────────────────────────
cat <<'EOF'

# Next
# 1. Treat every token with last_used "never" or older than 90 days and no KV/env
#    consumer as a deletion candidate; check the audit report
#    (sa-notes/reviews/cf-tokens-2026-11-06.md) before deleting.
# 2. Tokens with "no expiry": set one in the dashboard (Roll/edit token), unless
#    the report marks it as a non-rotating identifier.
# 3. Rotating an R2 token: update EVERY Key Vault item that holds it (the Coder
#    copies coder-r2-* in kv-qnsc-platform are duplicates of r2-* in kv-qnsc-prod).
# 4. DELETE the temporary audit token you created for this run.
EOF
exit "$rc"
