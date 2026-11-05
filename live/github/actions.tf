# =============================================================================
# GitHub Actions policy — repository pinning here, organisation baseline by hand.
#
# WHY: every workflow without its own `permissions:` block inherited a WRITE
# GITHUB_TOKEN, and "Actions can approve pull requests" was ON, so a
# GITHUB_TOKEN approval counts toward a ruleset that asks for one. Combined
# with `sha_pinning_required = false`, a compromised action tag could also run.
# This is the 2026 GitHub baseline: default read, no self-approval, tags refused.
#
# WHAT THIS STACK APPLIES: the `sha_pinning_required` flag on every platform
# repository below. That survives an organisation default being flipped back,
# and it makes the policy visible in the resource the repository is defined in.
#
# WHAT THIS STACK DOES NOT APPLY: the two organisation-level settings. They are
# owner-managed, through the UI, because the `qnsc-iac-apply` GitHub App holds
# repository administration only; the API endpoints behind them
# (PUT /orgs/{org}/actions/permissions and /actions/permissions/workflow) need
# organisation administration, which the App does not have. The App is NOT
# widened for this: it exists to import and maintain the repository settings,
# and an org-admin credential in CI would be a larger blast radius than the
# setting it protects. The first apply on 2026-11-05 failed on exactly those two
# PUTs with `403 Resource not accessible by integration`; that is the expected
# shape of this boundary, not a transient error.
#
# OWNER STEPS (Settings → Actions → General, org level):
#   1. "Workflow permissions" → **Read repository contents and packages
#      permissions** (the default must be read, not write).
#   2. Uncheck **Allow GitHub Actions to create and approve pull requests**.
#   3. "Actions permissions" → tick **Require actions to be pinned to a full-length
#      commit SHA** (allowed actions stay "Allow all actions and reusable workflows").
# Verify with `scripts/owner/check-org-actions-policy.sh` (owner token, read-only)
# or `gh api /orgs/quynhonsemiconductor/actions/permissions` and
# `.../actions/permissions/workflow`; the three live values must be
# `default_workflow_permissions=read`, `can_approve_pull_request_reviews=false`,
# `sha_pinning_required=true`. `github-drift.yml` cannot assert these: it mints
# the same repository-scoped apply token that the PUTs above were refused.
#
# ORDER: the tag-pinning prerequisite is already in: code-review#4 pinned its
# `codeql.yml` actions on 2026-11-04, before the org default is flipped.
#
# Repository-level token defaults are still not in this provider, so a repo that
# explicitly set its own default to `write` keeps it after the org default
# changes. Verify with `scripts/owner/check-org-actions-policy.sh --repos` and
# clear an override once through the API.
#
# NOTHING NEEDS A WRITE TOKEN: release-please, the gitops bump and the deploys
# authenticate with App installation tokens (QNSC_AUTOMATION_*) and every job that
# touches the API declares its own `permissions:`. zizmor/actionlint run on every
# PR and catch a workflow that forgets one.
# =============================================================================

# The same pinning flag on each platform repository this stack manages. Redundant
# while the org setting is on, deliberate: the repo-level value survives an org
# default being flipped back, and it makes the policy visible in the resource the
# repository is defined in rather than only one level up.
resource "github_actions_repository_permissions" "platform" {
  for_each = local.repos

  # allowed_actions is REQUIRED, not optional: the provider sends an empty value
  # when the attribute is absent, the API rejects "" with 422, and the next plan
  # shows a perpetual diff. "all" matches the organisation's current policy, so
  # nothing changes at apply.
  repository           = github_repository.this[each.key].name
  allowed_actions      = "all"
  sha_pinning_required = true
}
