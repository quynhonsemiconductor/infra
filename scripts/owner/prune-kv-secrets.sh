#!/usr/bin/env bash
# prune-kv-secrets.sh — owner-run: delete Key Vault secrets that NOTHING reads,
# after a grep proof over the COMMITTED origin/main trees (infra, gitops) and
# optionally the four product repos. Dry run by default; nothing is deleted
# without --apply.
#
#   scripts/owner/prune-kv-secrets.sh                 # proof against origin/main
#   scripts/owner/prune-kv-secrets.sh --with-products # + shallow clones of the product repos
#   scripts/owner/prune-kv-secrets.sh --apply         # implies --with-products
#
# The candidates come from the 2026-11-06 drift audit:
#   kv-qnsc-dev   kb-dev-app          legacy JSON bundle (chart dropped secrets.bundle)
#   kv-qnsc-prod  rova-prod-app       legacy JSON bundle (same)
#
# `platform-cnpg-ca-dev` is NOT a candidate: gitops builds its name
# (platform/bootstrap/cluster.sh: `platform-cnpg-ca-$ENV`) and secrets.sh MINTS
# A NEW CA when the secret is absent, so deleting it would silently break the
# existing dev CNPG clusters' trust chain.
#
# A candidate is deletable only when NO consumer names it. The scan reads what
# is COMMITTED on origin/main (git fetch + git archive), never the working
# tree: a local branch or an uncommitted edit is not what the cluster runs.
# The product repos (rova, opshub, qnsc-kb-backend, qnsc-kb-frontend) are
# shallow-cloned fresh for the same reason.
#
# What counts as a consumer: any file in those trees except
#   - .git/, .terraform/, *.tfstate*, *.tfplan,
#   - documentation (docs/ directories and *.md),
#   - test fixtures (tests/ directories, test_* / *_test.* files),
#   - comments (a hit whose name sits in a comment-only line, or after `#`).
# Docs, tests and comments may MENTION a retired secret; that is not a consumer.
# Every hit is printed with its classification, so the proof is auditable.
#
# ANY consumer reference STOPS the run (exit 1) with nothing deleted, even when
# the other candidates are clean. The deletion is a SOFT delete: Key Vault
# keeps the secret 90 days and it can be recovered. Purging is never done here.
#
# Needs an Azure login that can delete secrets in the two vaults
# (grp-qnsc-platform-admins: Key Vault Secrets Officer). The read-only CI
# identity cannot run this, on purpose.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA="${INFRA_DIR:-$ROOT}"
GITOPS="${GITOPS_DIR:-$(cd "$ROOT/.." && pwd)/gitops}"
ORG="${PRUNE_ORG:-quynhonsemiconductor}"
PRODUCT_REPOS="rova opshub qnsc-kb-backend qnsc-kb-frontend"

PRODUCT_DIRS=()
WITH_PRODUCTS=0
APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; WITH_PRODUCTS=1; shift ;;
    --with-products) WITH_PRODUCTS=1; shift ;;
    --infra) INFRA=${2:?--infra needs a directory}; shift 2 ;;
    --gitops) GITOPS=${2:?--gitops needs a directory}; shift 2 ;;
    --product-dir) PRODUCT_DIRS+=("${2:?--product-dir needs NAME=DIR}"); WITH_PRODUCTS=1; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

for c in az git tar grep sed mktemp; do
  command -v "$c" >/dev/null || { echo "missing required tool: $c" >&2; exit 1; }
done
for d in "$INFRA" "$GITOPS"; do
  [[ -d "$d" ]] || { echo "STOP: not a directory: $d (use --infra/--gitops)" >&2; exit 1; }
done

# vault name | secret name | why
CANDIDATES=(
  "kv-qnsc-dev|kb-dev-app|legacy JSON bundle: the chart dropped secrets.bundle"
  "kv-qnsc-prod|rova-prod-app|legacy JSON bundle: the chart dropped secrets.bundle"
)

PROOF=$(mktemp -d "${TMPDIR:-/tmp}/kv-proof.XXXXXX")
trap 'rm -rf "$PROOF"' EXIT
ROOTS=(); LABELS=()

git_tree() { # git_tree <dir> <label>: extract the COMMITTED origin/main tree
  local dir="$1" label="$2"
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    # A plain directory is NOT the proof: the tree must be what origin/main
    # holds, not a working checkout. Only the offline test may bypass that.
    [[ "${PRUNE_KV_TEST_FIXTURE:-0}" = "1" ]] \
      || { echo "STOP: not a git repository: $dir — the proof reads committed origin/main (PRUNE_KV_TEST_FIXTURE=1 is for the offline test only)" >&2; exit 1; }
    ROOTS+=("$dir"); LABELS+=("$label (TEST FIXTURE, not origin/main)"); return
  fi
  git -C "$dir" fetch -q origin main
  mkdir -p "$PROOF/$label"
  git -C "$dir" archive origin/main | tar -x -C "$PROOF/$label"
  ROOTS+=("$PROOF/$label"); LABELS+=("$label@origin/main")
}

clone_product() { # clone_product <name>: fresh shallow clone of the default branch
  local name="$1" dir
  dir="$PROOF/$name"
  git clone -q --depth 1 --single-branch "https://github.com/$ORG/$name.git" "$dir" \
    || { echo "STOP: cannot clone $ORG/$name; the proof is incomplete" >&2; exit 1; }
  ROOTS+=("$dir"); LABELS+=("$name@HEAD")
}

git_tree "$INFRA" infra
git_tree "$GITOPS" gitops
if [[ "$WITH_PRODUCTS" -eq 1 ]]; then
  for pair in ${PRODUCT_DIRS[@]+"${PRODUCT_DIRS[@]}"}; do
    pname=${pair%%=*}; pdir=${pair#*=}
    [[ -d "$pdir" ]] || { echo "STOP: --product-dir $pair is not a directory" >&2; exit 1; }
    ROOTS+=("$pdir"); LABELS+=("$pname@dir")
  done
  for r in $PRODUCT_REPOS; do
    # A --product-dir override replaces the clone for that repo.
    skip=0
    for pair in ${PRODUCT_DIRS[@]+"${PRODUCT_DIRS[@]}"}; do
      [[ "${pair%%=*}" = "$r" ]] && skip=1
    done
    [[ "$skip" -eq 1 ]] || clone_product "$r"
  done
fi

# A hit is a consumer unless it is docs, a test fixture or a comment. Prints
# "<label>/<path>:<line>:<classification>:<text>" for every raw hit.
scan_tree() { # scan_tree <root> <label> <name>
  local root="$1" label="$2" name="$3" line rel
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rel=${line%%:*}; rel=${rel#"$root"/}
    printf '%s/%s:%s\n' "$label" "$rel" "${line#*:}"
  done < <(grep -rInE \
    --exclude-dir=.git --exclude-dir=.terraform \
    --exclude='*.tfstate*' --exclude='*.tfplan' \
    --exclude-dir=docs --exclude='*.md' \
    --exclude-dir=tests --exclude='test_*' --exclude='*_test.sh' --exclude='*_test.py' \
    --exclude='prune-kv-secrets.sh' --exclude='prune_kv_secrets_test.sh' \
    "(^|[^A-Za-z0-9_-])$name([^A-Za-z0-9_-]|\$)" "$root" 2>/dev/null || true)
}

classify() { # classify <path> <text> <name> : prints reference|comment
  local path="$1" text="$2" name="$3" code
  case "$path" in
    */tests/*|*/docs/*|*.md|*/test_*|*_test.sh|*_test.py) echo doc; return ;;
  esac
  # Code before a trailing comment. A `#` starts a comment only at the first
  # non-space character or after whitespace — `a#b` (a URL fragment, a token)
  # is data, not a comment. `#` inside a quoted string can still mislead a
  # human grepping this by hand; the printed hit makes that visible.
  code=$(printf '%s' "$text" | sed -E 's/(^|[[:space:]])#.*$//')
  if ! printf '%s' "$code" | grep -qE "(^|[^A-Za-z0-9_-])$name([^A-Za-z0-9_-]|\$)"; then
    echo comment
  else
    echo reference
  fi
}

hits_for() { # hits_for <name>: prints "<label>/<path>:<n>:<class>:<text>"
  local name="$1" i label root path n text class
  for i in "${!ROOTS[@]}"; do
    root=${ROOTS[$i]}; label=${LABELS[$i]}
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      path=${line%%:*}; line=${line#*:}; n=${line%%:*}; text=${line#*:}
      class=$(classify "$path" "$text" "$name")
      printf '%s:%s:%s:%s\n' "$path" "$n" "$class" "$text"
    done < <(scan_tree "$root" "$label" "$name")
  done
}

echo "grep proof — committed trees:"
for i in "${!ROOTS[@]}"; do echo "  ${LABELS[$i]}"; done
[[ "$WITH_PRODUCTS" -eq 1 ]] || echo "  (product repos NOT scanned: add --with-products)"
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

# ANY reference stops the run, including the all-blocked case: silence is not
# a proof. Checked BEFORE the "nothing to delete" branch on purpose.
if [[ "$BLOCKED" -eq 1 ]]; then
  echo "STOP: at least one candidate is referenced; nothing was deleted." >&2
  exit 1
fi
if [[ ${#DELETABLE[@]} -eq 0 ]]; then
  echo "nothing to delete"
  exit 0
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
