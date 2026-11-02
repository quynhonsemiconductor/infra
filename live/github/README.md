# live/github — GitHub organisation config as code

Repository **rulesets** (all 42 that exist, across 17 repositories), the **merge settings** of the platform
repos, and the **environment** (`production`) of `infra`, imported exactly as they are on
2026-11-02. State: Azure `stqnsctfstate`, key `infra/github/terraform.tfstate`.
Provider `integrations/github` `~> 6.13` (6.13.0, latest stable at the time).

Nothing here changes a setting: the first apply only **imports** (the plan after the
import is empty, checked on a scratch state with a read token: 50 imported resources,
`No changes`, and a one-value mutation shows up as a change).

## What is managed

| file | resources | notes |
|---|---|---|
| `rulesets.tf` | `github_repository_ruleset.this` (42, for_each over a data map) | every ruleset, bypass actors included (team `merge-bypass`, app `qnsc-automation`, team `vlsi-leads`). `prevent_destroy`. |
| `repos.tf` | `github_repository.this` (6: `.github`, `app-platform`, `ci`, `gitops`, `infra`, `tf-modules`) | merge methods, auto-merge, delete-branch-on-merge, commit titles. Live values, `prevent_destroy`. |
| `repos.tf` | `github_repository_environment` + deployment policy (infra: `production`) | required reviewer + branch policy `main`. (`shared` and `develop` were deleted on 2026-11-02, empty and unreferenced.) |

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

## Credentials: two org-owned GitHub Apps (the owner creates them; code cannot)

Terraform cannot create GitHub Apps, so each app is created from a committed **manifest**
(`apps/*.json`) by one script, and nothing is long-lived in the workflows: every job mints a
~1 hour installation token with `actions/create-github-app-token` (pinned by SHA, v3.3.0, the
same pin as our other repos) and GitHub revokes it when the job ends.

| app | manifest | permissions | used by |
|---|---|---|---|
| `qnsc-iac-read` | `apps/qnsc-iac-read.json` | Administration **read**, Environments **read**, Metadata read | PR plans (once `github` leaves `NOT_PLANNABLE`) and the nightly drift job |
| `qnsc-iac-apply` | `apps/qnsc-iac-apply.json` | Administration **read/write**, Environments **read/write**, Metadata read | the `apply-github` job only (environment `production`) |

Both: no webhook, no subscribed events, **not public** (installable only on this
account), installed on **All repositories** (the stack manages 17 of them, and a new repo
would otherwise need an app change).

Where the credentials live (names the workflows read):

| value | name | kind | where |
|---|---|---|---|
| read app id | `IAC_READ_APP_ID` | variable | repository `infra` |
| read app key | `IAC_READ_APP_KEY` | secret | repository `infra` |
| apply app id | `IAC_APPLY_APP_ID` | variable | environment `production` of `infra` |
| apply app key | `IAC_APPLY_APP_KEY` | secret | environment `production` of `infra` (never a repository secret) |

PR plans and drift see only the read app; the apply app exists for the one job that pins
`environment: production` and so waits for its required reviewer.

### Owner steps (about 10 minutes, once per app; do both before merging this PR)

You need: org-owner rights on GitHub, `python3`, the 1Password CLI signed in (`op`, Touch ID),
and `gh` signed in as an owner. Run from a checkout of this repo (your own, on the PR branch or main
after merge):

```sh
# 1. Create the READ app. A browser tab opens on GitHub's confirmation page: click
#    "Create GitHub App" once. The script receives the one-time code on 127.0.0.1, exchanges it, and
#    stores the private key in 1Password (vault QNSC, Document "GitHub App - qnsc-iac-read - private key")
#    through stdin. No .pem file is ever written, so there is nothing to delete afterwards.
python3 scripts/owner/create_github_app.py read

# 2. On the page the script prints (…/settings/apps/qnsc-iac-read/installations):
#    Install -> "All repositories".

# 3. Wire the repository. The script prints these exact lines with the app id filled in:
gh variable set IAC_READ_APP_ID --repo quynhonsemiconductor/infra --body <app id>
op document get "GitHub App - qnsc-iac-read - private key" --vault QNSC \
  | gh secret set IAC_READ_APP_KEY --repo quynhonsemiconductor/infra

# 4. Same for the APPLY app (its values go to the environment, not the repository):
python3 scripts/owner/create_github_app.py apply
#    Install -> "All repositories" on …/settings/apps/qnsc-iac-apply/installations, then:
gh variable set IAC_APPLY_APP_ID --env production --repo quynhonsemiconductor/infra --body <app id>
op document get "GitHub App - qnsc-iac-apply - private key" --vault QNSC \
  | gh secret set IAC_APPLY_APP_KEY --env production --repo quynhonsemiconductor/infra
```

Notes:
- The key travels 1Password to `gh` through a pipe; it never reaches a file, argv or the terminal.
  `op document get` is the documented command for a Document item (`op read` is for fields).
- If the manifest page cannot be used (browser blocked, corporate proxy), the manual path gives
  the same result: *Settings > Developer settings > GitHub Apps > New GitHub App* with the values in
  the manifest, then *Generate a private key*, then
  `op document create ~/Downloads/<app>.<date>.private-key.pem --title "GitHub App - <app> - private key" --vault QNSC`
  and **delete the downloaded `.pem`** (`rm -P` on macOS) immediately after 1Password has it.
- The script refuses to run when the 1Password item already exists (that means the app exists), so a
  second app is never created by accident. To rotate a key: generate a new one in the app's settings,
  archive the old item, store the new one with the same commands.
- A lost key is not an emergency: the apps only have repository-administration scope on this org, so
  delete the app (Settings > Developer settings), remove the 1Password item, and run the script again.
- The create script has offline tests (`python3 scripts/owner/test_create_github_app.py`: stub `op`,
  fake conversion endpoint, no GitHub, no 1Password).

## Order of operations (before merging this PR)

1. Do the owner steps above for both apps.
1b. **Seed the state blob once** (owner, with write access to the state account). The read identity
   that PR plans and drift use cannot create the blob, and `tofu init` takes a lock on it first
   (`failed to lock azure state ... 403 AuthorizationPermissionMismatch`, as every new stack does
   until its blob exists). From a checkout of this branch:
   ```sh
   az login --tenant <tenant-domain>        # an identity with Storage Blob Data Contributor on stqnsctfstate
   cd live/github && tofu init              # creates infra/github/terraform.tfstate, empty; changes nothing else
   ```
   Then re-run the failed `Plan github` job on the PR.
2. Merge. The apply job (`apply-github`) mints the apply token, shows `50 to import, 0 to change`,
   waits for the `production` reviewer, then imports into the empty state.
3. One-line follow-up PR: remove `github` from `NOT_PLANNABLE` in `infra-plan.yml`, so PRs get a plan
   of this stack from then on.

Merging before step 1 makes `apply-github` and the nightly drift job fail loudly (no app credentials);
nothing else is affected.

## Local run (read-only)

```sh
export GITHUB_TOKEN=...           # any token with Administration + Environments read; from your own shell, never argv or Git
cd live/github
tofu init -backend=false          # local state; the real state is on Azure
tofu plan                         # 50 to import on an empty state
```
