# =============================================================================
# Repository settings that decide how code gets merged. The six PLATFORM repos
# were imported on 2026-11-02; the 13 product and lane repos below were imported
# on 2026-11-06 from the IaC drift audit (sa-notes/reviews/iac-drift-audit-2026-11-06.md
# §GitHub). The values are the LIVE values at import: adding a repo here changes
# no setting. Where they differ from the target ("squash only, delete the branch
# on merge, auto-merge off except gitops") the line says so, and the fix is one
# value in this map, reviewed like any other change. The rulesets force `squash`
# as the only PR merge method on the default branch, so `allow_merge_commit` /
# `allow_rebase_merge` cannot be used for a PR into main today; they only matter
# for repos where a ruleset is later removed.
#
# VLSIT_RTL_Generator_AI_Model is deliberately ABSENT: the owner archives it by
# hand on 2026-11-06. A github_repository resource here defaults `archived =
# false`, so it would UN-archive the repo on the next apply.
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
    "attendance-lock-firmware" = {
      auto_merge  = false, merge_commit = false, rebase_merge = false, delete_branch = true
      has_wiki    = false, has_projects = false, update_branch = true, squash_title = "PR_TITLE"
      description = "Firmware for the door lock + staff-card attendance terminal (syncs to opshub)"
    }
    "chipgraph" = {
      auto_merge    = false, merge_commit = false, rebase_merge = true, delete_branch = true
      update_branch = true
    }
    "ci" = {
      auto_merge = false, merge_commit = true, rebase_merge = true, delete_branch = true
    }
    "code-review" = {
      auto_merge  = false, merge_commit = true, rebase_merge = true, delete_branch = false # merge_commit/rebase_merge/delete_branch: target false/false/true
      has_issues  = false, has_wiki = false
      homepage    = "https://open-codereview.ai"
      description = "Secure, fast, efficient, battle-tested at Alibaba's scale. Hybrid architecture code review tool: deterministic pipelines + LLM Agent, precise line-level comments, built-in multi-language ruleset (NPE, thread-safety, XSS, SQL injection), OpenAI & Anthropic compatible."
    }
    "gitops" = {
      auto_merge = true, merge_commit = true, rebase_merge = true, delete_branch = false # delete_branch: target true
    }
    "infra" = {
      auto_merge = false, merge_commit = true, rebase_merge = true, delete_branch = true
    }
    "mcp-tools" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
    }
    "opc" = {
      auto_merge = false, merge_commit = true, rebase_merge = true, delete_branch = false # merge_commit/rebase_merge/delete_branch: target false/false/true
      has_wiki   = false
    }
    "opshub" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
      has_wiki   = false
    }
    "pidc-landing" = {
      auto_merge  = false, merge_commit = false, rebase_merge = false, delete_branch = true
      has_wiki    = false, has_projects = false
      description = "PIDC (Pisico Data Center) marketing site — Astro, EN/VI, Cloudflare Pages"
    }
    "product-docs" = {
      auto_merge  = false, merge_commit = true, rebase_merge = true, delete_branch = false # merge_commit/rebase_merge/delete_branch: target false/false/true
      has_wiki    = false, visibility = "private"
      description = "Central BA & product design docs (requirements, specs, mockups, diagrams) across QNSC-VN projects"
    }
    "qnsc-kb-backend" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
      has_wiki   = false
    }
    "qnsc-kb-frontend" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
      has_wiki   = false
    }
    "qnsc-landing" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
      has_wiki   = false
    }
    "rova" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
      has_wiki   = false
    }
    "tf-modules" = {
      auto_merge = false, merge_commit = false, rebase_merge = true, delete_branch = true
    }
    "vlsi_deep_training" = {
      auto_merge  = false, merge_commit = false, rebase_merge = true, delete_branch = true
      has_wiki    = false
      description = "QSOC — an RV32IMC microcontroller designed block-by-block as a deep-training project. SMIC 28 nm, 98 KiB on-chip memory, no flash — the application is serial-downloaded into RAM and runs from there."
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
  visibility   = try(each.value.visibility, "public")

  has_issues      = try(each.value.has_issues, true)
  has_wiki        = try(each.value.has_wiki, true)
  has_projects    = try(each.value.has_projects, true)
  has_discussions = false

  allow_auto_merge       = each.value.auto_merge
  allow_squash_merge     = true
  allow_merge_commit     = each.value.merge_commit
  allow_rebase_merge     = each.value.rebase_merge
  allow_update_branch    = try(each.value.update_branch, false)
  delete_branch_on_merge = each.value.delete_branch

  squash_merge_commit_title   = try(each.value.squash_title, "COMMIT_OR_PR_TITLE")
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
