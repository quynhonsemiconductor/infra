#!/usr/bin/env bash
# prune-kv-secrets.sh — owner-run: delete Key Vault secrets that NOTHING reads,
# after a grep proof over the infra and gitops trees. Dry run by default;
# nothing is deleted without --apply.
#
#   scripts/owner/prune-kv-secrets.sh                     # prove + print the plan
#   scripts/owner/prune-kv-secrets.sh --apply             # soft-delete the proven ones
#   scripts/owner/prune-kv-secrets.sh --infra DIR --gitops DIR
#
# The candidates come from the 2026-11-06 drift audit:
#   kv-qnsc-dev   kb-dev-app          legacy JSON bundle (chart dropped secrets.bundle)
#   kv-qnsc-prod  rova-prod-app       legacy JSON bundle (same)
#   kv-qnsc-admin platform-cnpg-ca-dev  dev CNPG CA with no deployment reference
#
# A candidate is deletable only when NO consumer names it. What counts as a
# consumer: any file in either tree except
#   - .git/, .terraform/, *.tfstate*, *.tfplan,
#   - documentation (docs/ directories and *.md),
#   - test fixtures (tests/ directories, test_* / *_test.* files),
#   - comments (a hit whose name sits in a comment-only line, or after `#`).
# Comments and docs may MENTION a retired secret; that is not a consumer. Every
# hit is printed with its classification, so the proof is auditable.
#
# The deletion is a SOFT delete: Key Vault keeps the secret 90 days and it can
# be recovered. Purging is never done here.
#
# Needs an Azure login that can read and delete secrets in the three vaults
# (grp-qnsc-platform-admins: Key Vault Secrets Officer). The read-only CI
# identity cannot run this, on purpose.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA="${INFRA_DIR:-$ROOT}"
GITOPS="${GITOPS_DIR:-$(cd "$ROOT/.." && pwd)/gitops}"

APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --infra) INFRA=${2:?--infra needs a directory}; shift 2 ;;
    --gitops) GITOPS=${2:?--gitops needs a directory}; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

for c in az grep sed; do
  command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }
done
for d in "$INFRA" "$GITOPS"; do
  [[ -d "$d" ]] || { echo "STOP: not a directory: $d (use --infra/--gitops)" >&2; exit 1; }
done

# vault name | secret name | why
CANDIDATES=(
  "kv-qnsc-dev|kb-dev-app|legacy JSON bundle: the chart dropped secrets.bundle"
  "kv-qnsc-prod|rova-prod-app|legacy JSON bundle: the chart dropped secrets.bundle"
  "kv-qnsc-admin|platform-cnpg-ca-dev|dev CNPG CA: no deployment reads the vault copy"
)

# A hit is a consumer unless it is docs, a test fixture or a comment. Prints
# "<path>:<line>:<classification>:<text>" for every raw hit.
scan_tree() { # scan_tree <root>
  local root="$1"
  grep -rInE \
    --exclude-dir=.git --exclude-dir=.terraform \
    --exclude='*.tfstate*' --exclude='*.tfplan' \
    --exclude-dir=docs --exclude='*.md' \
    --exclude-dir=tests --exclude='test_*' --exclude='*_test.sh' --exclude='*_test.py' \
    --exclude='prune-kv-secrets.sh' --exclude='prune_kv_secrets_test.sh' \
    "(^|[^A-Za-z0-9_-])$2([^A-Za-z0-9_-]|\$)" "$root" 2>/dev/null || true
}

classify() { # classify <path> <line-text> <name> : prints reference|comment
  local path="$1" text="$2" name="$3" code
  case "$path" in
    */tests/*|*/docs/*|*.md|*/test_*|*_test.sh|*_test.py) echo doc; return ;;
  esac
  # Code before a trailing comment. `#` inside a quoted string can mislead a
  # human grepping this by hand; the printed hit makes that visible.
  code=${text%%#*}
  if ! printf '%s' "$code" | grep -qE "(^|[^A-Za-z0-9_-])$name([^A-Za-z0-9_-]|\$)"; then
    echo comment
  else
    echo reference
  fi
}

hits_for() { # hits_for <name>: prints "<path>:<n>:<class>:<text>" for both trees
  local name="$1" path n text class
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path=${line%%:*}; line=${line#*:}; n=${line%%:*}; text=${line#*:}
    class=$(classify "$path" "$text" "$name")
    printf '%s:%s:%s:%s\n' "$path" "$n" "$class" "$text"
  done < <(scan_tree "$INFRA" "$name"; scan_tree "$GITOPS" "$name")
}

echo "grep proof — infra: $INFRA"
echo "grep proof — gitops: $GITOPS"
echo

DELETABLE=()
BLOCKED=0
for row in "${CANDIDATES[@]}"; do
  vault=${row%%|*}; rest=${row#*|}; name=${rest%%|*}; why=${rest#*|}
  HITS=$(hits_for "$name")
  if [[ -n "$HITS" ]]; then printf '%s\n' "$HITS" | sed 's/^/  hit /'; fi
  refs=$(printf '%s\n' "$HITS" | grep -c ':reference:' || true)
  mentions=$(printf '%s\n' "$HITS" | grep -cE ':(comment|doc):' || true)
  if [[ "$refs" -gt 0 ]]; then
    echo "BLOCKED  $vault/$name — $refs consumer reference(s); not deletable ($why)"
    BLOCKED=1
  else
    echo "OK       $vault/$name — no consumer ($mentions doc/comment mention(s); $why)"
    DELETABLE+=("$vault|$name")
  fi
  echo
done

if [[ ${#DELETABLE[@]} -eq 0 ]]; then
  echo "nothing to delete"
  exit 0
fi
if [[ "$BLOCKED" -eq 1 ]]; then
  echo "STOP: at least one candidate is referenced; nothing was deleted." >&2
  exit 1
fi

if [[ "$APPLY" -eq 0 ]]; then
  echo "dry run — re-run with --apply to soft-delete:"
  for row in "${DELETABLE[@]}"; do echo "  az keyvault secret delete --vault-name ${row%%|*} --name ${row#*|}"; done
  exit 0
fi

for row in "${DELETABLE[@]}"; do
  vault=${row%%|*}; name=${row#*|}
  echo "deleting $vault/$name ..."
  az keyvault secret delete --vault-name "$vault" --name "$name" --only-show-errors -o none
  echo "deleted $vault/$name (soft delete: recoverable for 90 days)"
done
echo
echo "done. The weekly expiry watch no longer sees these names."
