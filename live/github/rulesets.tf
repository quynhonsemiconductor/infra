# =============================================================================
# Repository rulesets — every ruleset that exists in the org today. The 42 that
# existed on 2026-11-02 were imported exactly (17 repos). The 4 for code-review
# and opc (2026-11-06, IaC drift audit §GitHub) carry no `id` and are CREATED by
# this stack: the import block skips any entry without one. The data is the live
# API output, reduced to the fields the provider can manage; see README.md "Not
# managed by the provider" for the two ruleset fields it cannot express.
#
# Adding a ruleset = one entry here. With an `id`, it is imported; without one,
# it is created. Either way it goes through this file, not the UI.
# =============================================================================
locals {
  # Org team / app ids (public numbers shown by the GitHub API).
  team_merge_bypass     = 20267573 # team `merge-bypass`: pull-request bypass for admins' squash merges
  team_vlsi_leads       = 19374826 # team `vlsi-leads`
  app_qnsc_automation   = 4166718  # GitHub App `qnsc-automation`
  app_github_actions_id = 15368    # the GitHub Actions app, pins check sources

  rulesets = {
    # ── .github ─────────────────────────────────────────────────────
    ".github/main-protection" = {
      repo    = ".github"
      id      = 19618766
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Secret scan (Gitleaks)" },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    ".github/tag-protection" = {
      repo    = ".github"
      id      = 19618768
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── app-platform ────────────────────────────────────────────────
    "app-platform/main-protection" = {
      repo    = "app-platform"
      id      = 18731336
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = true
        checks = [
          { context = "Lint & typecheck" },
          { context = "Tests" },
          { context = "PR title (conventional commits)" },
          { context = "CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "app-platform/tag-protection" = {
      repo    = "app-platform"
      id      = 18731348
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── attendance-lock-firmware ────────────────────────────────────
    "attendance-lock-firmware/main-protection" = {
      repo    = "attendance-lock-firmware"
      id      = 25729990
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = false
        checks = [
          { context = "build-dev", integration_id = local.app_github_actions_id },
          { context = "build-prod", integration_id = local.app_github_actions_id },
          { context = "host-tests", integration_id = local.app_github_actions_id },
          { context = "PR title (conventional commits)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "attendance-lock-firmware/tag-protection" = {
      repo    = "attendance-lock-firmware"
      id      = 25729994
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── chipgraph ───────────────────────────────────────────────────
    "chipgraph/main-protection" = {
      repo    = "chipgraph"
      id      = 24852356
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "check (ubuntu-latest, 3.13)", integration_id = local.app_github_actions_id },
          { context = "check (ubuntu-latest, 3.14)", integration_id = local.app_github_actions_id },
          { context = "check (macos-latest, 3.13)", integration_id = local.app_github_actions_id },
          { context = "check (macos-latest, 3.14)", integration_id = local.app_github_actions_id },
          { context = "sim (cocotb, verilator + icarus, py3.13)", integration_id = local.app_github_actions_id },
          { context = "sim (cocotb, verilator + icarus, py3.14)", integration_id = local.app_github_actions_id },
          { context = "secrets", integration_id = local.app_github_actions_id },
          { context = "build test image, run tinysoc e2e", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "chipgraph/tag-creation-release-only" = {
      repo    = "chipgraph"
      id      = 24852358
      name    = "tag-creation-release-only"
      target  = "tag"
      include = ["refs/tags/v*"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "chipgraph/tag-protection" = {
      repo    = "chipgraph"
      id      = 24852357
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── code-review ─────────────────────────────────────────────────
    # Created 2026-11-06 (no `id`): the repo had no ruleset and no branch
    # protection. Checks are the three languages in the repo's own CodeQL
    # workflow (`.github/workflows/codeql.yml`); the repo's other product
    # workflows live only on feature branches, so they are not required here.
    "code-review/main-protection" = {
      repo    = "code-review"
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Analyze (actions)", integration_id = local.app_github_actions_id },
          { context = "Analyze (go)", integration_id = local.app_github_actions_id },
          { context = "Analyze (javascript-typescript)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "code-review/tag-protection" = {
      repo    = "code-review"
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── ci ──────────────────────────────────────────────────────────
    "ci/main-protection" = {
      repo    = "ci"
      id      = 18687491
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Unit tests (shipped scripts)" },
          { context = "PR title (conventional commits)" },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "ci/tag-protection" = {
      repo    = "ci"
      id      = 18687033
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── gitops ──────────────────────────────────────────────────────
    "gitops/main-baseline" = {
      repo    = "gitops"
      id      = 23525793
      name    = "main-baseline"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 0
        dismiss_stale      = false
        code_owner_review  = false
        last_push_approval = false
        thread_resolution  = false
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = false
        checks = [
          { context = "chart" },
          { context = "PR title (conventional commits)" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
          { context = "bot-scope", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "gitops/main-review" = {
      repo    = "gitops"
      id      = 26364222
      name    = "main-review"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.app_qnsc_automation, type = "Integration", mode = "pull_request" }, { id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = []
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = false
        merge_methods      = ["squash"]
      }
    }
    "gitops/chart-release-tags-admin-only" = {
      repo    = "gitops"
      id      = 23525795
      name    = "chart-release-tags-admin-only"
      target  = "tag"
      include = ["refs/tags/chart-v*"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "gitops/tag-protection" = {
      repo    = "gitops"
      id      = 23525794
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── infra ───────────────────────────────────────────────────────
    "infra/main-protection" = {
      repo    = "infra"
      id      = 18832997
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Detect changed stacks" },
          { context = "checkov (IaC misconfig)" },
          { context = "Secret scan (Gitleaks)" },
          { context = "tofu fmt check" },
          { context = "tflint" },
          { context = "Plan required" },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
          { context = "leak-guard (public-repo patterns)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "infra/tag-protection" = {
      repo    = "infra"
      id      = 18832999
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── infra-template ──────────────────────────────────────────────
    "infra-template/main-protection" = {
      repo    = "infra-template"
      id      = 19618764
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "checkov (IaC misconfig)" },
          { context = "Secret scan (Gitleaks)" },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "infra-template/tag-protection" = {
      repo    = "infra-template"
      id      = 19618765
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── mcp-tools ───────────────────────────────────────────────────
    "mcp-tools/main-protection" = {
      repo    = "mcp-tools"
      id      = 22875978
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "typecheck" },
          { context = "lint" },
          { context = "PR title (conventional commits)" },
          { context = "Analyze (javascript-typescript)" },
          { context = "test" },
          { context = "build" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "mcp-tools/tag-creation-release-only" = {
      repo    = "mcp-tools"
      id      = 22876000
      name    = "tag-creation-release-only"
      target  = "tag"
      include = ["refs/tags/v*"]
      bypass  = [{ id = local.app_qnsc_automation, type = "Integration", mode = "always" }, { id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "mcp-tools/tag-protection" = {
      repo    = "mcp-tools"
      id      = 22875998
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── opc ─────────────────────────────────────────────────────────
    # Created 2026-11-06 (no `id`): the repo had no ruleset and no branch
    # protection. opc has no workflow files; its only PR checks come from
    # GitHub's CodeQL default setup, so those two are the required set.
    "opc/main-protection" = {
      repo    = "opc"
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Analyze (python)", integration_id = local.app_github_actions_id },
          { context = "Analyze (javascript-typescript)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "opc/tag-protection" = {
      repo    = "opc"
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── opshub ──────────────────────────────────────────────────────
    "opshub/main-protection" = {
      repo    = "opshub"
      id      = 18687485
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = true
        checks = [
          { context = "Lint & typecheck" },
          { context = "Tests" },
          { context = "E2E (Playwright)" },
          { context = "Migration upgrade path" },
          { context = "OpenAPI contract" },
          { context = "PR title (conventional commits)" },
          { context = "Build" },
          { context = "Unit tests" },
          { context = "Backend CI required" },
          { context = "Web CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "opshub/tag-creation-release-only" = {
      repo    = "opshub"
      id      = 21872918
      name    = "tag-creation-release-only"
      target  = "tag"
      include = ["refs/tags/v*"]
      bypass  = [{ id = local.app_qnsc_automation, type = "Integration", mode = "always" }, { id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "opshub/tag-protection" = {
      repo    = "opshub"
      id      = 18687032
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── pidc-landing ────────────────────────────────────────────────
    "pidc-landing/main-protection" = {
      repo    = "pidc-landing"
      id      = 26116874
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Lint & typecheck" },
          { context = "PR title (conventional commits)" },
          { context = "Build" },
          { context = "CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
          { context = "Leak guard", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "pidc-landing/tag-protection" = {
      repo    = "pidc-landing"
      id      = 26116877
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── qnsc-kb-backend ─────────────────────────────────────────────
    "qnsc-kb-backend/main-protection" = {
      repo    = "qnsc-kb-backend"
      id      = 20643706
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = true
        checks = [
          { context = "Format & typecheck" },
          { context = "Tests" },
          { context = "Migration upgrade path" },
          { context = "OpenAPI contract" },
          { context = "Docker build" },
          { context = "PR title (conventional commits)" },
          { context = "Backend CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "qnsc-kb-backend/tag-creation-release-only" = {
      repo    = "qnsc-kb-backend"
      id      = 20643710
      name    = "tag-creation-release-only"
      target  = "tag"
      include = ["refs/tags/v*"]
      bypass  = [{ id = local.app_qnsc_automation, type = "Integration", mode = "always" }, { id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "qnsc-kb-backend/tag-protection" = {
      repo    = "qnsc-kb-backend"
      id      = 20643707
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── qnsc-kb-frontend ────────────────────────────────────────────
    "qnsc-kb-frontend/main-protection" = {
      repo    = "qnsc-kb-frontend"
      id      = 20643711
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = true
        checks = [
          { context = "Lint & typecheck" },
          { context = "Unit tests" },
          { context = "Build" },
          { context = "PR title (conventional commits)" },
          { context = "Web CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "qnsc-kb-frontend/tag-creation-release-only" = {
      repo    = "qnsc-kb-frontend"
      id      = 20643713
      name    = "tag-creation-release-only"
      target  = "tag"
      include = ["refs/tags/v*"]
      bypass  = [{ id = local.app_qnsc_automation, type = "Integration", mode = "always" }, { id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "qnsc-kb-frontend/tag-protection" = {
      repo    = "qnsc-kb-frontend"
      id      = 20643712
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── qnsc-landing ────────────────────────────────────────────────
    "qnsc-landing/main-protection" = {
      repo    = "qnsc-landing"
      id      = 25655236
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "Lint & typecheck" },
          { context = "PR title (conventional commits)" },
          { context = "Build" },
          { context = "CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "qnsc-landing/tag-protection" = {
      repo    = "qnsc-landing"
      id      = 25655231
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── rova ────────────────────────────────────────────────────────
    "rova/main-protection" = {
      repo    = "rova"
      id      = 18687482
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = false
        do_not_enforce_on_create = true
        checks = [
          { context = "Lint & typecheck" },
          { context = "Tests" },
          { context = "Unit tests" },
          { context = "E2E (Playwright)" },
          { context = "Build" },
          { context = "Migration upgrade path" },
          { context = "OpenAPI contract" },
          { context = "PR title (conventional commits)" },
          { context = "Backend CI required" },
          { context = "Web CI required" },
          { context = "security / Security scans (Gitleaks, osv-scanner, Semgrep)", integration_id = local.app_github_actions_id },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "rova/tag-creation-release-only" = {
      repo    = "rova"
      id      = 19596968
      name    = "tag-creation-release-only"
      target  = "tag"
      include = ["refs/tags/v*"]
      bypass  = [{ id = local.app_qnsc_automation, type = "Integration", mode = "always" }, { id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["creation"]
    }
    "rova/tag-protection" = {
      repo    = "rova"
      id      = 18687029
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion", "update"]
    }

    # ── tf-modules ──────────────────────────────────────────────────
    "tf-modules/main-protection" = {
      repo    = "tf-modules"
      id      = 18687492
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "checkov (IaC misconfig)" },
          { context = "fmt \u00b7 validate \u00b7 tflint" },
          { context = "Secret scan (Gitleaks)" },
          { context = "PR title (conventional commits)" },
          { context = "CI required" },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
    "tf-modules/tag-protection" = {
      repo    = "tf-modules"
      id      = 18687034
      name    = "tag-protection"
      target  = "tag"
      include = ["~ALL"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "always" }]
      rules   = ["deletion"]
    }

    # ── vlsi_deep_training ──────────────────────────────────────────
    "vlsi_deep_training/main-merge-by-maintainers" = {
      repo    = "vlsi_deep_training"
      id      = 23991369
      name    = "main-merge-by-maintainers"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_vlsi_leads, type = "Team", mode = "pull_request" }, { id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["update"]
    }
    "vlsi_deep_training/main-protection" = {
      repo    = "vlsi_deep_training"
      id      = 23823475
      name    = "main-protection"
      target  = "branch"
      include = ["~DEFAULT_BRANCH"]
      bypass  = [{ id = local.team_merge_bypass, type = "Team", mode = "pull_request" }]
      rules   = ["deletion", "non_fast_forward"]
      pull_request = {
        approvals          = 1
        dismiss_stale      = true
        code_owner_review  = true
        last_push_approval = true
        thread_resolution  = true
        merge_methods      = ["squash"]
      }
      status_checks = {
        strict                   = true
        do_not_enforce_on_create = true
        checks = [
          { context = "PR title (conventional commits)" },
          { context = "Verilator lint" },
          { context = "Vendor tree unmodified" },
          { context = "RTL naming rule" },
          { context = "Inter-block contract" },
          { context = "No hardcoded shared values" },
          { context = "Filelist paths" },
          { context = "Generated wrappers" },
          { context = "Connectivity" },
          { context = "Generated IP" },
          { context = "IP and integration module rules" },
          { context = "Contract tags" },
          { context = "Simulation" },
          { context = "actions-security / Workflow security (actionlint, zizmor)", integration_id = local.app_github_actions_id },
        ]
      }
    }
  }
}

resource "github_repository_ruleset" "this" {
  for_each = local.rulesets

  repository  = each.value.repo
  name        = each.value.name
  target      = each.value.target
  enforcement = "active"

  conditions {
    ref_name {
      include = each.value.include
      exclude = []
    }
  }

  dynamic "bypass_actors" {
    for_each = each.value.bypass
    content {
      actor_id    = bypass_actors.value.id
      actor_type  = bypass_actors.value.type
      bypass_mode = bypass_actors.value.mode
    }
  }

  rules {
    creation         = contains(each.value.rules, "creation")
    deletion         = contains(each.value.rules, "deletion")
    non_fast_forward = contains(each.value.rules, "non_fast_forward")
    update           = contains(each.value.rules, "update")

    dynamic "pull_request" {
      for_each = try(each.value.pull_request, null) == null ? [] : [each.value.pull_request]
      content {
        required_approving_review_count   = pull_request.value.approvals
        dismiss_stale_reviews_on_push     = pull_request.value.dismiss_stale
        require_code_owner_review         = pull_request.value.code_owner_review
        require_last_push_approval        = pull_request.value.last_push_approval
        required_review_thread_resolution = pull_request.value.thread_resolution
        allowed_merge_methods             = pull_request.value.merge_methods
      }
    }

    dynamic "required_status_checks" {
      for_each = try(each.value.status_checks, null) == null ? [] : [each.value.status_checks]
      content {
        strict_required_status_checks_policy = required_status_checks.value.strict
        do_not_enforce_on_create             = required_status_checks.value.do_not_enforce_on_create
        dynamic "required_check" {
          for_each = required_status_checks.value.checks
          content {
            context        = required_check.value.context
            integration_id = try(required_check.value.integration_id, null)
          }
        }
      }
    }
  }

  # A ruleset deleted by a typo in this file would drop branch protection on
  # a live repo. Removing one is a deliberate two-step: lift this, apply.
  lifecycle {
    prevent_destroy = true
  }
}

# Imports: the live rulesets are adopted, never recreated. `repository:id` is the
# provider's import id. Safe to leave in place after the first apply (OpenTofu
# ignores an import block whose resource is already in state). Entries without
# an `id` are the rulesets this stack creates, so they are skipped here.
import {
  for_each = { for key, ruleset in local.rulesets : key => ruleset if try(ruleset.id, null) != null }
  to       = github_repository_ruleset.this[each.key]
  id       = "${each.value.repo}:${each.value.id}"
}
