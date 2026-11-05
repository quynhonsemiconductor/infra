#!/usr/bin/env bash
# backfill-kv-expiry.sh — owner-run: give the secrets that have no expiry one, where that is
# meaningful. Dry run by default; nothing is written without --apply.
#
#   scripts/owner/backfill-kv-expiry.sh                 # print the plan
#   scripts/owner/backfill-kv-expiry.sh --apply         # set the expiries
#
# Rules:
#   - identifiers that never rotate stay without an expiry (Access AUD tags, client ids, rosters);
#   - a *-graph-cert gets the certificate's own end date: the Key Vault certificate object if one
#     exists, otherwise the notAfter of the combined PEM stored as the secret. Never a guess;
#   - everything else gets now + 365 days, the same default secrets.sh uses.
#
# Needs an Azure login that can WRITE the vaults (Key Vault Secrets Officer on each). The
# read-only CI identity cannot run this, on purpose: the watch in .github/workflows/secret-expiry.yml
# is read-only and only reports.
set -euo pipefail
umask 077

APPLY=0
VAULTS=()
EXPIRES=""

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --apply) APPLY=1; shift ;;
    --expires) EXPIRES=${2:?--expires needs YYYY-MM-DD}; shift 2 ;;
    --vault) VAULTS+=("${2:?--vault needs a name}"); shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

for c in az jq date openssl python3; do
  command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }
done

if [[ $APPLY -eq 1 && -z $EXPIRES ]]; then
  echo "STOP: --apply needs an explicit --expires YYYY-MM-DD (no blanket default)" >&2
  exit 2
fi

if [[ ${#VAULTS[@]} -eq 0 ]]; then
  VAULTS=(kv-qnsc-prod kv-qnsc-platform kv-qnsc-dev)
fi

# macOS (BSD) date first, GNU date second. RFC3339 UTC, the format Key Vault accepts.
explicit_expiry() {
  if date -u -j -f "%Y-%m-%d" "$EXPIRES" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
    return 0
  fi
  date -u -d "$EXPIRES" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

no_expiry_ok() {
  case $1 in
    *-mcp-access-aud|*-client-id|*-platform-admin-emails) return 0 ;;
    *) return 1 ;;
  esac
}

echo "== mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo 'dry run (add --apply)')"
echo "== vaults: ${VAULTS[*]}"

failures=0
for vault in "${VAULTS[@]}"; do
  echo "== $vault"
  # Process substitution, not a pipe: the loop's failures must reach this shell.
  while read -r name; do
    [[ -n $name ]] || continue
    if no_expiry_ok "$name"; then
      echo "  - $name: identifier, no expiry by design"
      continue
    fi

    if [[ $name == *-graph-cert ]]; then
      # The graph-certs are combined PEMs stored as SECRETS, not Key Vault certificate objects
      # (live/identity/README.md). Try the certificate object first, then read notAfter from the
      # PEM through stdin; the value is never printed.
      expires=$(az keyvault certificate show --vault-name "$vault" --name "$name" \
        --query attributes.expires --output tsv 2>/dev/null || true)
      if [[ -z $expires ]]; then
        not_after=$(az keyvault secret show --vault-name "$vault" --name "$name" \
          --query value --output tsv 2>/dev/null \
          | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' \
          | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)
        if [[ -n $not_after ]]; then
          expires=$(printf '%s\n' "$not_after" | python3 -c \
            'import datetime as d,sys; s=" ".join(sys.stdin.read().split()); print(d.datetime.strptime(s,"%b %d %H:%M:%S %Y %Z").strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null || true)
        fi
      fi
      if [[ -z $expires ]]; then
        echo "  ! $name: certificate end date not readable; set it by hand" >&2
        failures=1
        continue
      fi
    else
      if [[ -z $EXPIRES ]]; then
        echo "  ! $name: needs an explicit --expires YYYY-MM-DD (no blanket +1 year)" >&2
        failures=1
        continue
      fi
      expires=$(explicit_expiry || true)
      if [[ -z $expires ]]; then
        echo "  ! --expires '$EXPIRES' is not a YYYY-MM-DD date" >&2
        exit 2
      fi
    fi

    # A past expiry would make the secret unusable the moment it is written; that is a rotation,
    # not a backfill. RFC3339 UTC strings compare lexically.
    if [[ $expires < $(date -u +%Y-%m-%dT%H:%M:%SZ) ]]; then
      echo "  ! $name: computed expiry $expires is in the past; rotate the certificate first" >&2
      failures=1
      continue
    fi

    echo "  $vault/$name -> $expires"
    if [[ $APPLY -eq 1 ]]; then
      az keyvault secret set-attributes --vault-name "$vault" --name "$name" \
        --expires "$expires" --output none
      echo "    set"
    fi
  done < <(az keyvault secret list --vault-name "$vault" --output json \
    | jq -r '.[] | select((.attributes.exp // null) == null) | .name')
done

if [[ $failures -ne 0 ]]; then
  echo "one or more items need an explicit date or a readable certificate end date" >&2
  exit 1
fi
if [[ $APPLY -eq 0 ]]; then
  echo "dry run: nothing written. Re-run with --apply if the plan is right."
fi
