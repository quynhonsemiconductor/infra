#!/usr/bin/env bash
# Read-only assertion for the organisation-level GitHub Actions baseline that
# Terraform cannot manage: the qnsc-iac-apply App holds repository
# administration only, and the endpoints below need organisation administration
# (see live/github/actions.tf). Run this as an org owner after the manual steps,
# and whenever the org settings are suspected to have drifted.
#
# Usage:
#   scripts/owner/check-org-actions-policy.sh [--repos] [org]
#
#   --repos   also list every repository whose workflow-token default is not
#             read / no PR approvals (an explicit repository override; the org
#             setting does not reach those).
#
# Exit status: 0 when the org baseline and every requested repository check
# pass, 1 on any mismatch. It never writes.
set -euo pipefail

ORG="quynhonsemiconductor"
CHECK_REPOS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --repos) CHECK_REPOS=true ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) ORG="$1" ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 2; }; }
need gh
need jq

failed=0
fail() { printf 'FAIL  %s\n' "$1" >&2; failed=1; }
pass() { printf 'ok    %s\n' "$1"; }

# PUT /orgs/{org}/actions/permissions (org administration required)
perms="$(gh api "/orgs/$ORG/actions/permissions")"
sha_pinning="$(jq -r '.sha_pinning_required' <<<"$perms")"
allowed="$(jq -r '.allowed_actions' <<<"$perms")"
if [ "$sha_pinning" = "true" ]; then
  pass "org sha_pinning_required=true"
else
  fail "org sha_pinning_required=$sha_pinning (want true)"
fi
if [ "$allowed" = "all" ]; then
  pass "org allowed_actions=all"
else
  echo "note  org allowed_actions=$allowed (expected all)" >&2
fi

# PUT /orgs/{org}/actions/permissions/workflow (org administration required)
wf="$(gh api "/orgs/$ORG/actions/permissions/workflow")"
default_perm="$(jq -r '.default_workflow_permissions' <<<"$wf")"
approve="$(jq -r '.can_approve_pull_request_reviews' <<<"$wf")"
if [ "$default_perm" = "read" ]; then
  pass "org default_workflow_permissions=read"
else
  fail "org default_workflow_permissions=$default_perm (want read)"
fi
if [ "$approve" = "false" ]; then
  pass "org can_approve_pull_request_reviews=false"
else
  fail "org can_approve_pull_request_reviews=$approve (want false)"
fi

if $CHECK_REPOS; then
  while IFS=$'\t' read -r repo perm can_approve; do
    if [ "$perm" != "read" ] || [ "$can_approve" != "false" ]; then
      fail "repo $repo default_workflow_permissions=$perm can_approve=$can_approve (want read false; an explicit override once the org steps above are done)"
      printf '      clear it: gh api -X PUT repos/%s/%s/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false\n' "$ORG" "$repo" >&2
    fi
  done < <(
    gh repo list "$ORG" --limit 200 --json name -q '.[].name' |
      while read -r repo; do
        gh api "repos/$ORG/$repo/actions/permissions/workflow" |
          jq -r --arg r "$repo" '[$r, .default_workflow_permissions, (.can_approve_pull_request_reviews|tostring)]|@tsv'
      done
  ) || { failed=1; echo "FAIL  repository sweep did not complete" >&2; }
fi

if [ "$failed" -ne 0 ]; then
  cat >&2 <<EOF

Fix in GitHub: Settings -> Actions -> General (organisation $ORG)
  1. Workflow permissions: "Read repository contents and packages permissions".
  2. Leave "Allow GitHub Actions to create and approve pull requests" unchecked.
  3. Actions permissions: tick "Require actions to be pinned to a full-length commit SHA".
These three are owner-applied on purpose; the CI App has repository
administration only and must not be widened for org administration.
EOF
  exit 1
fi

echo "org Actions baseline is correct"
