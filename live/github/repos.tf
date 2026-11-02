# =============================================================================
# Repository settings that decide how code gets merged — for the PLATFORM repos
# only (YAGNI: product repos are managed by their lanes through rulesets above,
# and a repo is added here the day its settings are worth guarding).
#
# The values below are the LIVE values on 2026-11-02, imported as-is: this PR
# changes no setting. Where they differ from the target ("squash only, delete the
# branch on merge, auto-merge off except gitops") the line says so, and the fix is
# one value in this map, reviewed like any other change. The rulesets already
# force `squash` as the only PR merge method on the default branch, so the extra
# `allow_merge_commit` / `allow_rebase_merge` flags cannot be used for a PR into
# main today; they only matter for repos where a ruleset is later removed.
# =============================================================================
locals {
  repos = {
    ".github" = {
      auto_merge = false, merge_commit = true, rebase_merge = true, delete_branch = false # delete_branch: target true
    }
    "app-platform" = {
      auto_merge  = false, merge_commit = false, rebase_merge = true, delete_branch = true
      description = "Shared application-layer packages (identity, platform-cache, platform-http, runtime, observability) fo product backends. Published to GitHub Packages."
      homepage    = ""
    }
    "ci" = {
      auto_merge = false, merge_commit = true, rebase_merge = true, delete_branch = true
    }
    "gitops" = {
      auto_merge = true, merge_commit = true, rebase_merge = true, delete_branch = false # delete_branch: target true
    }
    "infra" = {
      auto_merge = false, merge_commit = true, rebase_merge = true, delete_branch = true
    }
    "tf-modules" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
    }
  }
}

resource "github_repository" "this" {
  # checkov:skip=CKV_GIT_1:every code repo is PUBLIC on purpose (owner decision; GitHub Free needs it for rulesets and environment reviewers), see the public-repo identifier policy
  # checkov:skip=CKV2_GIT_1:branch protection is by repository RULESET (rulesets.tf, github_repository_ruleset), which this check does not recognise
  for_each = local.repos

  name         = each.key
  description  = try(each.value.description, null)
  homepage_url = try(each.value.homepage, null)
  visibility   = "public"

  has_issues      = true
  has_wiki        = true
  has_projects    = true
  has_discussions = false

  allow_auto_merge       = each.value.auto_merge
  allow_squash_merge     = true
  allow_merge_commit     = each.value.merge_commit
  allow_rebase_merge     = each.value.rebase_merge
  allow_update_branch    = false
  delete_branch_on_merge = each.value.delete_branch

  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"

  web_commit_signoff_required = true

  # Deleting a repository by removing a line from a map is not a change anyone
  # means to make in a PR.
  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = local.repos
  to       = github_repository.this[each.key]
  id       = each.key
}

# ── Environments (infra) ─────────────────────────────────────────────────────
# `production` is the apply gate: every infra apply job pins it, the Azure apply
# identity federates only it, and the required reviewer is the human gate. (`shared`
# and `develop` were deleted on 2026-11-02, empty and unreferenced, so they are not
# here.)
locals {
  reviewer_owner_user_id = 297359903 # GitHub user id of the owner (login shown on the repo's environment settings)
}

resource "github_repository_environment" "infra_production" {
  repository          = github_repository.this["infra"].name
  environment         = "production"
  can_admins_bypass   = true
  prevent_self_review = false

  reviewers {
    users = [local.reviewer_owner_user_id]
  }

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "infra_production_main" {
  repository     = github_repository.this["infra"].name
  environment    = github_repository_environment.infra_production.environment
  branch_pattern = "main"
}

import {
  to = github_repository_environment.infra_production
  id = "infra:production"
}
import {
  to = github_repository_environment_deployment_policy.infra_production_main
  id = "infra:production:64532593"
}
