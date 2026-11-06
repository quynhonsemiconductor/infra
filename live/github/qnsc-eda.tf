# =============================================================================
# qnsc-eda — the first repository this stack CREATES (repos.tf `create = true`),
# with its team access and CODEOWNERS as code.
#
# Why these live here and not in the UI: the repository is born protected in one
# apply. Ordering matters and is encoded by references:
#
#   github_repository.this["qnsc-eda"]   (created, auto_init gives branch main)
#     └── github_repository_file.qnsc_eda_codeowners   (direct commit to main)
#           └── github_repository_ruleset.this          (depends_on the file)
#
# Reversing the last edge would make the CODEOWNERS commit the first push the
# new main-protection ruleset blocks.
# =============================================================================

locals {
  # Public team ids (same source as rulesets.tf's locals). Numeric ids avoid a
  # data-source read of the organisation's teams, which the apply credential
  # does not need.
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

# CODEOWNERS names both teams that review this repo: the platform team that
# builds and operates the image, and the VLSI leads whose flow it serves.
resource "github_repository_file" "qnsc_eda_codeowners" {
  repository = github_repository.this["qnsc-eda"].name
  branch     = "main"
  file       = ".github/CODEOWNERS"

  content = <<-EOT
    # Every change needs a review from the platform team or the VLSI leads.
    * @quynhonsemiconductor/platform @quynhonsemiconductor/vlsi-leads
  EOT

  commit_message      = "chore(codeowners): own qnsc-eda by platform and vlsi-leads"
  overwrite_on_create = true
}
