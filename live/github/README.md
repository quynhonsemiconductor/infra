# live/github — GitHub organisation config as code

Repository **rulesets** (45: 43 imported or previously created — 39 imported on 2026-11-02, the
`main-protection`/`tag-protection` pair for `code-review` and `opc` created on 2026-11-06 — plus the
pair for `qnsc-eda`, created by this stack), the **merge settings** of the 19 repos this stack manages,
the **team access** of `qnsc-eda`, and the **environment** (`production`) of `infra`.
The 42 existing rulesets, the 18 pre-existing repositories and the environment were imported exactly as
they were on 2026-11-02 (the 12 product/lane repos added on 2026-11-06 were imported as-is too).
`qnsc-eda` (2026-11-06) is the first repository this stack **creates**, and the first whose team access
it manages; its CODEOWNERS is committed by the first pull request, not by this stack (see
`qnsc-eda.tf`).
State: Azure `stqnsctfstate`, key `infra/github/terraform.tfstate`.
Provider `integrations/github` `~> 6.13` (6.13.0, latest stable at the time).

Adding the 12 repos and the four rulesets changes no live repo setting. A scratch-state plan on
2026-11-06 read `62 to import, 22 to add, 0 to change, 0 to destroy`; against the real state that is
12 imports and 16 adds (12 `github_actions_repository_permissions` objects, already at the same
values, plus the four rulesets) with no updates. The 2026-11-02 import was likewise `50 imported
resources, No changes`, and a one-value mutation shows up as a change.

`mcp-tools` was retired by owner decision on 2026-11-06. Its merge settings were never
imported, and its three rulesets left the map. The apply **destroys** those live rulesets,
which is why it must run before the owner archives the repo: GitHub makes an archived
repository read-only, so a delete after archiving would fail with 403. The guard stays: the
three objects move (`moved` blocks) to an empty `github_repository_ruleset.retired` resource
that has no `prevent_destroy`, so only those three are destroyed. Once applied, that resource
and its `moved` blocks are inert and can be removed in a cleanup.

## What is managed

| file | resources | notes |
|---|---|---|
| `rulesets.tf` | `github_repository_ruleset.this` (43 entries: 39 imported, 4 created for `code-review` and `opc`, for_each over a data map) | every ruleset, bypass actors included (team `merge-bypass`, app `qnsc-automation`, team `vlsi-leads`). `prevent_destroy` stays on; the three retired `mcp-tools` objects move to an empty `retired` resource for their destroy (see below). |
| `repos.tf` | `github_repository.this` (19: the six platform repos, plus `attendance-lock-firmware`, `chipgraph`, `code-review`, `opc`, `opshub`, `pidc-landing`, `product-docs`, `qnsc-eda`, `qnsc-kb-backend`, `qnsc-kb-frontend`, `qnsc-landing`, `rova`, `vlsi_deep_training`) | merge methods, auto-merge, delete-branch-on-merge, commit titles, wiki/issues/projects visibility. Live values, `prevent_destroy`. `qnsc-eda` has `create = true` (made by this stack, skipped by the import block) and `auto_init` (needs a default branch for its file and rulesets). |
| `qnsc-eda.tf` | `github_team_repository.qnsc_eda` (4) | team access (platform + vlsi write, vlsi-leads maintain, merge-bypass read) for the repo this stack creates. No `github_repository_file`: Contents write on an app installed on every repo is more blast radius than one CODEOWNERS file is worth; the file comes with the first pull request. |
| `repos.tf` | `github_repository_environment` + deployment policy (infra: `production`) | required reviewer + branch policy `main`. (`shared` and `develop` were deleted on 2026-11-02, empty and unreferenced.) |

Adding a repo to `repos.tf` or a ruleset to `rulesets.tf` is one map entry. The
`import {}` blocks stay in place after the first apply (OpenTofu skips an import whose
resource is already in state). A ruleset entry **with** an `id` is imported; one
**without** an `id` is created, and the ruleset import block filters those out.

`VLSIT_RTL_Generator_AI_Model` was archived by the owner on 2026-11-06, and
`mcp-tools` follows after its retirement PRs apply. Both are absent from `repos.tf`:
they are read-only and need no merge settings. `archived` is in `ignore_changes`, so
archiving any managed repo by hand is never undone by an apply. `product-docs` has merge
settings here but no ruleset: it is the only private repo, and the Free plan has no
rulesets on private repositories. Its description is not copied into this public repo —
`description` is in `ignore_changes`, so the live value stays untouched.

`opc` is protected (PR required, one approval, squash only) but has **no required status
checks yet**: its only checks come from CodeQL default setup, which has reported on `main`
only, never on a pull request. Requiring them would block every opc PR. Add them once a
throwaway PR has shown them reporting. `code-review` requires the three `Analyze (...)`
jobs its own CodeQL workflow runs on PRs.

**Settings that differ from "squash only, delete branch on merge, auto-merge off"**
(imported as they are; each is one value in the `repos` map): merge commits allowed on
`.github`, `ci`, `gitops`, `infra`, `code-review`, `opc`, `product-docs`; rebase merge
allowed everywhere except `attendance-lock-firmware` and `pidc-landing`; branches not
deleted on merge in `.github`, `gitops`, `code-review`, `opc`, `product-docs`; auto-merge
on in `gitops` only; `attendance-lock-firmware` uses `PR_TITLE` as the squash commit title.
The default-branch rulesets already restrict PR merges to `squash`, so these flags are
latent, not live.

## Actions policy (added 2026-11-04, N-H3)

`actions.tf` sets `sha_pinning_required` on every platform repository this stack
owns. The three **organisation-level** settings are owner-applied, not Terraform:
default workflow token **read**, Actions may **not** approve pull-request
reviews, and `sha_pinning_required` **on** org-wide.

Why not Terraform: the `qnsc-iac-apply` App has repository administration only.
`PUT /orgs/{org}/actions/permissions` and `PUT
/orgs/{org}/actions/permissions/workflow` need organisation administration and
were refused with `403 Resource not accessible by integration` on the 2026-11-05
apply. The App is deliberately not widened; an org-admin token in CI has a
larger blast radius than the setting it protects.

**Owner steps — Settings → Actions → General (organisation level):**

1. **Workflow permissions**: select **Read repository contents and packages
   permissions** (the default must be read, not write).
2. Leave **Allow GitHub Actions to create and approve pull requests** unchecked.
3. **Actions permissions**: tick **Require actions to be pinned to a full-length
   commit SHA**. Allowed actions stay **Allow all actions and reusable
   workflows**.

Verify with `scripts/owner/check-org-actions-policy.sh` (owner `gh` token,
read-only; exits non-zero and prints the fix on a mismatch). Two things to know:

- **Every `uses:` must be a full 40-character SHA.** The tag-pinning prerequisite
  is in: `code-review#4` pinned its `codeql.yml` on 2026-11-04. The three other
  repositories that still carry tags (`9router-pool`, `agent-forge`, `solodesk`)
  are ARCHIVED, so their workflows cannot run and their references cannot fail
  the policy.
- **Repository-level token defaults are not in this provider.** A repository
  that explicitly set its own default to `write` keeps it — the org flip does not
  reach an explicit override. `scripts/owner/check-org-actions-policy.sh --repos`
  lists any row that is not `read false`; clear it once with
  `gh api -X PUT repos/quynhonsemiconductor/<repo>/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false`.
  That API clear is the only option today — the provider has no repository-level
  workflow-token resource — so record it in the apply notes if one surfaces.


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
- **Team and app repository access.** Not managed org-wide: the full matrix (13 teams,
  ~20 repos, app installations "selected") is not worth owning. The exception is `qnsc-eda`,
  whose four team grants are in `qnsc-eda.tf` because the repository is created here and must
  be usable the moment it exists.
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

## Plans, refresh and drift: who sees what (decided 2026-11-02)

The read app (`qnsc-iac-read`, Administration read) **cannot see** ruleset `bypass_actors` or the
repository merge settings (`allow_*_merge`, `delete_branch_on_merge`, commit-message formats):
GitHub returns those only to admin/push callers. A refreshed plan with the read app therefore shows a
phantom change on every repo and ruleset (the first PR plan showed `48 to change` for that reason; a plan
with an admin token showed `50 to import, 0 to change`). No write scope is ever added to the read app to
fix this. Instead:

| where | credential | refresh | what it proves |
|---|---|---|---|
| PR plan (`infra-plan.yml`) | read app | **off** (`-refresh=false`) | config vs state, a review of what the PR changes, like `observability`. The one PR that carries the import blocks also shows the phantom diff once; the owner's local admin plan (50 import / 0 change / 0 destroy) is the proof for that one. |
| apply (`infra-apply.yml`, `apply-github`) | apply app, environment `production` | **on** | the real comparison, behind the reviewer. |
| drift (`github-drift.yml`) | apply app, environment `production` | **on** | monthly (1st, 03:00 UTC) and on demand (*Actions > GitHub drift > Run workflow*); the owner approves the run. PLAN ONLY, never applies. A diff or an error opens/updates one issue labelled `github-drift`; a clean run closes it. |
| nightly drift (`drift-detection.yml`) | | | `github` is **excluded** (a read-app refresh would be red every night). |

**Exception to a plan-first flow (#299).** Where #299 plans in the PR and applies exactly what was
approved, `github` is the one stack whose faithful plan can only be made inside the `production` job with
the apply app (no token a PR may hold can read what this stack manages). So its reviewable plan is the
`-refresh=false` PR plan plus the refreshing plan in the apply job, which is approved on the run page
before `tofu apply` runs.

## Credentials: two org-owned GitHub Apps (the owner creates them; code cannot)

Terraform cannot create GitHub Apps, so each app is created from a committed **manifest**
(`apps/*.json`) by one script, and nothing is long-lived in the workflows: every job mints a
~1 hour installation token with `actions/create-github-app-token` (pinned by SHA, v3.3.0, the
same pin as our other repos) and GitHub revokes it when the job ends.

| app | manifest | permissions | used by |
|---|---|---|---|
| `qnsc-iac-read` | `apps/qnsc-iac-read.json` | Administration **read**, Environments **read**, Members **read**, Metadata read | PR plans of this stack (`-refresh=false`), drift |
| `qnsc-iac-apply` | `apps/qnsc-iac-apply.json` | Administration **read/write**, Environments **read/write**, Members **read**, Metadata read | the `apply-github` job only (environment `production`) |

Members read is required by `qnsc-eda.tf`: the team-grant endpoint needs repository Administration
(present above) and the ability to see the team. Contents is deliberately **not** requested — the
apply app is installed on every repository, so Contents write would let any run push to all of them.
**Existing installations need Members read added by the owner** (see the owner checklist below);
changing the manifest file alone does not change the live app. The three token mints request exactly
the same minimum (`permission-members: read`), so the installation approval list is one item.

Both: no webhook, no subscribed events, **not public** (installable only on this
account), installed on **All repositories** (the stack manages 19 of them, and a new repo
would otherwise need an app change).

### Members read on the existing apps (owner, required before the qnsc-eda apply)

Raising an app's permissions is an owner action; the manifest in this repo is the desired
state, not something an apply can push into GitHub. Before the `apply-github` job runs:

1. `https://github.com/settings/apps/qnsc-iac-apply` → **Permissions & events** →
   **Organisation permissions** → **Members** → **Read-only** → **Save changes**.
2. Approve the increase for the installation: **Organisation settings → GitHub Apps →
   `qnsc-iac-apply` → Configure → review the request → Approve**. (Without this the installation
   token still lacks the permission.)
3. Repeat for `qnsc-iac-read`: **Members: Read-only**. Nothing else is requested — in particular
   **not Contents**: this app is installed on every repository.

No key changes: the next workflow run mints a token with the new permissions.

Where the credentials live (names the workflows read):

| value | name | kind | where |
|---|---|---|---|
| read app id | `IAC_READ_APP_ID` | variable | repository `infra` |
| read app key | `IAC_READ_APP_KEY` | secret | repository `infra` |
| apply app id | `IAC_APPLY_APP_ID` | variable | environment `production` of `infra` |
| apply app key | `IAC_APPLY_APP_KEY` | secret | environment `production` of `infra` (never a repository secret) |

PR plans see only the read app; the apply app exists for the jobs that pin
`environment: production` (apply and the monthly drift plan) and so wait for the owner.

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
   that PR plans use cannot create the blob, and `tofu init` takes a lock on it first
   (`failed to lock azure state ... 403 AuthorizationPermissionMismatch`, as every new stack does
   until its blob exists). From a checkout of this branch:
   ```sh
   az login --tenant <tenant-domain>        # an identity with Storage Blob Data Contributor on stqnsctfstate
   cd live/github && tofu init              # creates infra/github/terraform.tfstate, empty; changes nothing else
   ```
   Then re-run the failed `Plan github` job on the PR.
2. Merge. The apply job (`apply-github`) mints the apply token, shows `50 to import, 0 to change`,
   waits for the `production` reviewer, then imports into the empty state. From then on PRs get a
   `-refresh=false` plan of this stack, and the monthly `github-drift` workflow compares it with the
   organisation.

Merging before step 1 makes `apply-github` fail loudly (no app credentials); nothing else is affected.

## Local run (read-only)

```sh
export GITHUB_TOKEN=...           # any token with Administration, Members and Environments read; from your own shell, never argv or Git
cd live/github
tofu init -backend=false          # local state; the real state is on Azure
tofu plan                         # imports + adds on an empty state; phantom `~` on every repo, see above
```

### Owner's pre-apply admin plan (2026-11-06 import)

Paste this before approving the `production` apply. It reads the REAL state with an admin
token, so merge settings and bypass actors are visible and no phantom diff appears:

```sh
cd ~/Desktop/qnsc/infra/live/github
az login --tenant <tenant-domain>     # identity with Storage Blob Data Contributor on stqnsctfstate
tofu init                             # real backend, key infra/github/terraform.tfstate
GITHUB_TOKEN=$(gh auth token) tofu plan -lock=false
```

Expected for the 2026-11-06 change: **`Plan: 12 to import, 16 to add, 0 to change, 0 to
destroy`** — the 12 new repo imports, 12 `github_actions_repository_permissions` objects
and the 4 new rulesets are `+`/import only, with **no `~` (update-in-place) on any of the
12 repos**. Any `~` is a finding: stop and read it before approving.
