# live/github — GitHub organisation config as code

Repository **rulesets** (all 42 that exist, across 17 repositories), the **merge settings** of the platform
repos, and the **environments** of `infra`, imported exactly as they are on
2026-11-02. State: Azure `stqnsctfstate`, key `infra/github/terraform.tfstate`.
Provider `integrations/github` `~> 6.13` (6.13.0, latest stable at the time).

Nothing here changes a setting: the first apply only **imports** (the plan after the
import is empty, checked on a scratch state with a read token: 53 imported resources,
`No changes`, and a one-value mutation shows up as a change).

## What is managed

| file | resources | notes |
|---|---|---|
| `rulesets.tf` | `github_repository_ruleset.this` (42, for_each over a data map) | every ruleset, bypass actors included (team `merge-bypass`, app `qnsc-automation`, team `vlsi-leads`). `prevent_destroy`. |
| `repos.tf` | `github_repository.this` (6: `.github`, `app-platform`, `ci`, `gitops`, `infra`, `tf-modules`) | merge methods, auto-merge, delete-branch-on-merge, commit titles. Live values, `prevent_destroy`. |
| `repos.tf` | `github_repository_environment` + deployment policy (infra: `production`, `shared`, `develop`) | `production`: required reviewer + branch policy `main`. |

Adding a repo to `repos.tf` or a ruleset to `rulesets.tf` is one map entry. The
`import {}` blocks stay in place after the first apply (OpenTofu skips an import whose
resource is already in state).

**Settings that differ from "squash only, delete branch on merge, auto-merge off"**
(imported as they are; each is one value in the `repos` map): merge commits allowed on
`.github`, `ci`, `gitops`, `infra`; rebase merge allowed everywhere; branches not deleted on
merge in `.github` and `gitops`; auto-merge on in `gitops` only. The default-branch
rulesets already restrict PR merges to `squash`, so these flags are latent, not live.

## Not managed, on purpose

- **Secret and variable values, and the secrets themselves.** `github_actions_secret`
  would put the value in state. Names only, as documentation, from the API on 2026-11-02:
  - organisation secrets (selected repos): `ANTHROPIC_CODE_REVIEW_API_KEY`,
    `CLOUDFLARE_API_TOKEN`, `CODE_REVIEW_APP_KEY`, `GRAFANA_ALERTS_TOKEN`,
    `QNSC_AUTOMATION_PRIVATE_KEY`, `QNSC_REPO_READER_PRIVATE_KEY`, `Z_AI_CODING_API_KEY`;
  - `infra` repository secrets: the `*_READONLY` Cloudflare/Grafana tokens, `ADMIN_*`,
    `ENTRA_IDP_CLIENT_SECRET`, `GRAFANA_SM_TOKEN`, `TEAMS_ALERTS_WEBHOOK_URL`,
    `WARP_EXTRA_EXCLUDES`; environment `production` holds the write tokens;
  - organisation variables (e.g. `AWS_ACCOUNT_ID`) are **not** in this stack and must not be
    recreated from it. Nothing here reads or writes a variable.
- **Team and app repository access.** `github_team_repository` would be clean, but the full
  matrix (13 teams, ~20 repos, app installations "selected") is not worth owning yet.
  Snapshot: team `platform` has write on `.github`, `infra`, `ci`, `tf-modules`,
  `infra-template`, `app-platform`, `gitops`, `qnsc-landing` and read elsewhere; team
  `merge-bypass` has read on every non-archived repo (its only job is the ruleset bypass).
  Apps: `qnsc-automation`, `qnsc-code-review`, `qnsc-repo-reader` are installed on selected
  repositories; `rova-scm-dev`, `rova-scm-prod`, `qnsc-agent-force`, `renovate` on all.
- **Two ruleset fields the provider cannot express** (live: `require_extra_approval_for_
  unattributed_changes = true` on every pull-request rule, `dismissal_restriction` off).
  An update to a ruleset through the provider may send neither. The plan shows no change
  today, so nothing is sent; if a later edit to a `pull_request` rule is ever applied,
  re-read the ruleset in the UI afterwards and restore the field by hand, or wait for
  provider support. Edits to `status_checks` or `bypass` carry the same caveat on
  those rulesets that have a pull-request rule.

## Credentials: what the owner creates (nothing is created by code)

Fine-grained personal access tokens, **resource owner = the organisation**, expiry
no more than 12 months (calendar reminder 30 days before). The organisation must
allow fine-grained tokens and an owner must approve the request. A GitHub App with the
same permissions is the better long-term shape (no personal owner); it needs a
token-minting step in the three workflows, so the PAT is the smaller change today.

| token | secret name | stored in | repository access | permissions |
|---|---|---|---|---|
| plans and drift | `GH_IAC_TOKEN_READONLY` | repository secret (`infra`) | all repositories (the 17 with a ruleset) | Repository: **Administration: Read-only**, **Environments: Read-only**, Metadata: Read-only (automatic). No write permission. |
| apply | `GH_IAC_TOKEN` | **environment secret of `production`** (`infra`), never a repository secret | same | Repository: **Administration: Read and write**, **Environments: Read and write**, Metadata: Read-only. |

Secret names cannot start with `GITHUB_`, hence the `GH_` prefix. The pattern is the one
of infra#274: PR plans and the nightly drift job see only the read token; the write token
exists for the apply job, which pins `environment: production` and so waits for its
required reviewer.

## Order of operations (do these BEFORE merging this PR)

1. Create both tokens above and store them under the names above.
2. Merge. The apply job (`apply-github`) runs, shows `53 to import, 0 to change`, waits
   for the `production` reviewer, then imports into the empty state.
3. One-line follow-up PR: remove `github` from `NOT_PLANNABLE` in `infra-plan.yml`, so
   PRs get a plan of this stack from then on.

Merging before step 1 makes `apply-github` and the nightly drift job fail loudly (no token);
nothing else is affected.

## Local run (read-only)

```sh
export GITHUB_TOKEN=...           # the READ-ONLY token, from your own shell, never argv or Git
cd live/github
tofu init -backend=false          # local state; the real state is on Azure
tofu plan                         # 53 to import on an empty state
```
