#!/usr/bin/env bash
# set-cf-token-expiry-tags.sh — owner-run: put each Cloudflare R2 token's expiry on
# the Key Vault secrets that hold it, as the `expires` tag, so the existing weekly
# secret-expiry watcher covers the TOKEN deadline (it reads Key Vault tags, not
# Cloudflare).
#
#   scripts/owner/set-cf-token-expiry-tags.sh            # dry run: print the plan
#   scripts/owner/set-cf-token-expiry-tags.sh --apply    # write the tags
#   scripts/owner/set-cf-token-expiry-tags.sh --file X   # another reviewed list
#
# The list is scripts/owner/cf-token-expiry-tags.txt: <vault> <secret> <YYYY-MM-DD> <token name>.
# Review the dates against a fresh `cf-tokens-audit.sh` run before applying: this
# script trusts the list, it does not call Cloudflare.
#
# Only TAGS are written (`az keyvault secret set-attributes --tags`); no secret
# value is read, printed or changed. Existing tags are preserved: set-attributes
# replaces the whole tag set, so the current tags are read first and merged.
#
# Needs an Azure login that can WRITE the vault tags (Key Vault Secrets Officer).
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${HERE}/cf-token-expiry-tags.txt"
APPLY=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case $1 in
    --apply) APPLY=1; shift ;;
    --file) LIST=${2:?--file needs a path}; shift 2 ;;
    -h | --help) usage 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

command -v az >/dev/null || { echo "missing az (az login done)" >&2; exit 2; }
command -v jq >/dev/null || { echo "missing jq" >&2; exit 2; }
[ -r "$LIST" ] || { echo "STOP: cannot read $LIST" >&2; exit 2; }

changed=0
problems=0

while read -r vault secret expires token _rest; do
  case "${vault:-}" in '' | '#'*) continue ;; esac
  [ -n "${secret:-}" ] && [ -n "${expires:-}" ] || {
    echo "STOP: malformed line: $vault $secret $expires" >&2
    problems=$((problems + 1))
    continue
  }
  if ! [[ $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "STOP: $vault/$secret: expiry '$expires' is not YYYY-MM-DD" >&2
    problems=$((problems + 1))
    continue
  fi

  # Current tags (read only). A missing secret is a problem to fix, not a skip.
  if ! tags_json=$(az keyvault secret show --vault-name "$vault" --name "$secret" \
                    --query tags -o json 2>/dev/null); then
    echo "MISSING: $vault/$secret (token ${token:-?})" >&2
    problems=$((problems + 1))
    continue
  fi
  current=$(jq -r '.expires // ""' <<<"$tags_json")
  if [ "$current" = "$expires" ]; then
    printf 'ok      %s/%s expires=%s\n' "$vault" "$secret" "$expires"
    continue
  fi

  printf 'set     %s/%s expires=%s%s\n' "$vault" "$secret" "$expires" \
    "$([ -n "$current" ] && printf ' (was %s)' "$current")"
  changed=$((changed + 1))
  [ "$APPLY" -eq 1 ] || continue

  # Merge: keep every existing tag, replace only `expires`.
  args=()
  while IFS= read -r kv; do
    [ "$kv" = "expires=$expires" ] && continue
    args+=("$kv")
  done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$tags_json")
  args+=("expires=$expires")

  if ! az keyvault secret set-attributes --vault-name "$vault" --name "$secret" \
        --tags "${args[@]}" --output none; then
    echo "STOP: tag write failed for $vault/$secret" >&2
    exit 2
  fi
done < "$LIST"

echo
echo "changed: $changed, problems: $problems, apply: $APPLY"
[ "$problems" -eq 0 ] || exit 1
