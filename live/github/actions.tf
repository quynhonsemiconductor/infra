# =============================================================================
# GitHub Actions policy — the org baseline (N-H3, 2026-11-04).
#
# WHY: every workflow without its own `permissions:` block inherited a WRITE
# GITHUB_TOKEN, and "Actions can approve pull requests" was ON, so a
# GITHUB_TOKEN approval counts toward a ruleset that asks for one. Combined
# with `sha_pinning_required = false`, a compromised action tag could also run.
# This is the 2026 GitHub baseline: default read, no self-approval, tags refused.
#
# WHAT CHANGES AT APPLY:
#   * organisation default token -> read, Actions may NOT approve PR reviews;
#   * organisation policy refuses any `uses:` that is not a full 40-char SHA;
#   * the PLATFORM repositories managed here carry the same pinning flag
#     explicitly, so removing the org default later cannot silently re-allow tags.
#
# WHAT THIS STACK CANNOT DO: the provider has no repository-level workflow-token
# resource (only the org-level `github_actions_organization_workflow_permissions`),
# so a repository that set its OWN default to write keeps it after the org default
# changes. Verify with `gh api repos/<repo>/actions/permissions/workflow` after the
# apply; a repo still reporting `write` needs its override cleared once through the
# API. The audit sweeps this again with `github-drift.yml`.
#
# NOTHING NEEDS A WRITE TOKEN: release-please, the gitops bump and the deploys
# authenticate with App installation tokens (QNSC_AUTOMATION_*) and every job that
# touches the API declares its own `permissions:`. zizmor/actionlint run on every
# PR and catch a workflow that forgets one.
# =============================================================================

resource "github_actions_organization_permissions" "this" {
  allowed_actions      = "all"
  enabled_repositories = "all"
  sha_pinning_required = true
}

resource "github_actions_organization_workflow_permissions" "this" {
  organization_slug                = var.github_owner
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

# The same pinning flag on each platform repository this stack manages. Redundant
# while the org setting is on, deliberate: the repo-level value survives an org
# default being flipped back, and it makes the policy visible in the resource the
# repository is defined in rather than only one level up.
resource "github_actions_repository_permissions" "platform" {
  for_each = local.repos

  repository           = github_repository.this[each.key].name
  sha_pinning_required = true
}
