# =============================================================================
# qnsc-eda — the first repository this stack CREATES (repos.tf `create = true`),
# with its team access as code.
#
# The team grants need exactly two permissions from the apply/plan credentials:
# repository Administration (already minted: write for apply, read for plans)
# and organisation Members read, because the "add team repository" endpoint
# requires the caller to be able to see the team. Nothing else (see the three
# token mints in .github/workflows and live/github/README.md).
#
# CODEOWNERS is deliberately NOT a `github_repository_file` here: that needs
# Contents write on an app installed on EVERY repository, which is more blast
# radius than a file is worth. It is committed by the first pull request in the
# new repository instead; the main-protection ruleset (created by this stack)
# requires code-owner review from it thereafter.
# =============================================================================

locals {
  # Public team ids (same source as rulesets.tf's locals). Numeric ids avoid a
  # data-source read of the organisation's teams.
  qnsc_eda_team_ids = {
    platform     = 20267557 # team `platform`
    vlsi         = 19374898 # team `vlsi`
    vlsi-leads   = 19374826 # team `vlsi-leads`
    merge-bypass = 20267573 # team `merge-bypass`: ruleset bypass only
  }

  # The org's area model for this repo: the platform team can push (it owns the
  # image pipeline), the VLSI engineers can push, their leads maintain, and
  # merge-bypass has the read access GitHub requires to be a bypass actor.
  qnsc_eda_team_permissions = {
    platform     = "push"
    vlsi         = "push"
    vlsi-leads   = "maintain"
    merge-bypass = "pull"
  }
}

resource "github_team_repository" "qnsc_eda" {
  for_each = local.qnsc_eda_team_permissions

  team_id    = local.qnsc_eda_team_ids[each.key]
  repository = github_repository.this["qnsc-eda"].name
  permission = each.value
}
