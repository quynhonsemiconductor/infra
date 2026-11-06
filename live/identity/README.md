# live/identity

Entra ID + Azure Key Vault for the whole platform, plus the two CI workload
identities (§7.4). **This stack is applied ONLY by the owner, locally, with
their own `az login` — every plan and every apply, not just the first.** CI
neither plans nor applies it. The repository is public, and plan output (PR
comments, Actions logs) would publish the break-glass UPNs and the Entra role
layout, so the owner runs `tofu plan` and `tofu apply` locally. An identity
able to apply this stack could grant itself any role in the tenant, so no CI
identity is given that ability.

The nightly `.github/workflows/drift-detection.yml` DOES compare this stack with
reality, refresh-only, through the owner kit and the same read identity (no
write rights). Its plan text is written to a file and never printed. See
`docs/runbooks/drift-detection.md` for the four repository secrets the job
needs (`IDENTITY_*`).

## Owns

- `rg-qnsc-platform`, the four Key Vaults (`kv-qnsc-{prod,dev,platform,admin}`)
  with §7.1 properties (RBAC auth, 90-day soft delete, purge protection on
  prod/platform/admin), the `qnsc-platform-monthly` $10 budget alert.
- The mail service apps (`mail.tf`, §7.3): certificate-only `<Product> <Env>
  Service` registrations, adopted via import; client ids as outputs; the
  combined PEMs are written to the vaults by the OWNER, never by tofu.
- The state backend `stqnsctfstate` + `tfstate` container (imported; shared
  keys OFF, so the backend authenticates with Entra — `use_azuread_auth`,
  versions.tf).
- The CI identities, GitHub OIDC only, client IDs as outputs — no secrets:
  - "QNSC CI Infra" (apply of the OTHER stacks, environment `production`):
    Contributor (subscription) + Storage Blob Data Contributor
    (`stqnsctfstate`). NO Entra directory role, NO User Access Administrator.
  - "QNSC CI Infra Read" (plan/drift): Directory Readers (Entra), Reader
    (subscription), Storage Blob Data Reader (`stqnsctfstate`), Key Vault
    Reader (metadata only).
    TODO: the Directory Readers role is kept for drift tooling run privately
    or in future; if nothing uses it, remove it.
- Phase 1: the Entra groups, ESO/CI/Backup SP apps with certificate auth,
  product sign-in app redirect URIs, vault RBAC.

## Auth (no client secrets anywhere)

- **CI: none for this stack.**
- **Operators**: `az login` first — both providers and the backend pick up the
  Azure CLI session.

## First apply, at the operator's laptop

Public repository: every `<placeholder>` below is filled in at the terminal,
never committed.

1. Sign in against the tenant and select the platform subscription:

   ```sh
   az login --tenant <tenant-domain>
   az account set --subscription <subscription-id>
   ```

2. Verify the hand-created backend and grant yourself the one backend role
   (idempotent — safe to re-run):

   ```sh
   ../../scripts/owner/bootstrap-state.sh <operator-upn>
   ```

   Azure leaves `publicNetworkAccess` unset on the hand-created account, while
   azurerm 5.x plans `"" -> "Enabled"` for it. The script prints the fix if it
   sees that; run it once (idempotent, no behaviour change) so the first plan
   is clean:

   ```sh
   az storage account update -g rg-qnsc-platform -n stqnsctfstate --public-network-access Enabled
   ```

3. Export the variables the stack needs (values stay in your shell):

   ```sh
   export TF_VAR_subscription_id=<subscription-id>
   export ARM_SUBSCRIPTION_ID=$TF_VAR_subscription_id   # tofu init (backend) reads this one
   export TF_VAR_budget_period_start=2026-10-01T00:00:00Z  # RFC3339, copy from the live budget (bootstrap script prints it)
   export TF_VAR_budget_period_end=2028-09-30T00:00:00Z    # RFC3339, the hand-created budget's end (must match Azure exactly)
   export TF_VAR_break_glass_upn_domain=<tenant-primary-domain>
   ```

4. Init, plan, apply. The plan performs the four `import` blocks in `imports.tf`
   (resource group, storage account, `tfstate` container, budget) and creates
   the four vaults, the break-glass users/group, the two CI identities and
   their role assignments:

   ```sh
   tofu init
   tofu plan     # go/no-go below
   tofu apply
   ```

   **Go/no-go — the first owner plan must read exactly: 4 to import (each
   "no changes"), 23 to add, 0 to change, 0 to destroy, 0 to replace.**
   (These 23 cover the vaults, break-glass and CI identities ONLY. The Phase-1
   PRs — ESO SPs, vault RBAC, sign-in apps — are SEPARATE applies with their
   own expected counts, stated in their sections below; never mix them into
   this first apply.)
   Anything else on an imported resource (an update or a replace on the
   resource group, storage account, container or budget) is NO-GO: STOP and
   reconcile the code to the live value in a reviewed PR instead of applying —
   the resource being changed is the thing holding every state file.

5. Record the two client IDs from the outputs, then set the GitHub repo
   variables CI needs for the later OIDC wiring (repo **variables**, values are
   public identifiers):

   - `AZURE_CLIENT_ID` = `ci_infra_apply_client_id`
   - `AZURE_CLIENT_ID_READ` = `ci_infra_read_client_id`
   - `AZURE_TENANT_ID` = `<tenant-id>`

   The variables still serve other stacks and later OIDC use. `identity` stays
   NOT_PLANNABLE in `infra-plan.yml` on purpose (public repo, see the top of
   this file), so CI never plans this stack. Every change is `tofu plan` and
   `tofu apply` by the owner, locally.

## Residual risk

"QNSC CI Infra" (Contributor + Storage Blob Data Contributor on `stqnsctfstate`)
can WRITE the blob `infra/identity/terraform.tfstate`, i.e. tamper with this
stack's state even though it cannot apply the stack. Follow-up: replace the
account-wide Blob Data Contributor with an ABAC condition that excludes
`infra/identity/*` (and give the Read identity the same view it has today).

## Never does

- Holds no secret values. Certificates are attached by public half; tokens and
  keys are piped into the vaults through stdin by the operator, with expiry and
  `owner`/`rotate-by` tags (§7.5).

## Phase 1: ESO service principals + vault data-plane RBAC (§7.1)

`vault_rbac.tf` + `eso.tf` add, per store in gitops
`platform/eso/stores-onprem.yaml` (dev, prod, platform — none for
`kv-qnsc-admin`):

- one Entra app + service principal `QNSC ESO <Env>`, authenticated by the
  cluster's own OIDC issuer (see "ESO workload identity" below). No password
  credential exists, and no certificate either — `tests/static.sh` fails the
  tree if either reappears;
- `Key Vault Secrets User` for that SP, scoped to **its own vault only**;
- `Key Vault Secrets Officer` for `grp-qnsc-platform-admins` on **all four**
  vaults (the operator writes every secret through stdin).

Owner steps:

1. Run the static guard (plan-free; asserts the auth and RBAC invariants). CI
   runs the same script on every PR as a step of the `tofu fmt check` job in
   `infra-plan.yml`:

   ```sh
   sh live/identity/tests/static.sh
   ```

2. Export the group ids (identifiers, not credentials — operator-supplied all
   the same, so they are never committed). The apply kit does this for every
   plan/apply; by hand they are:

   ```sh
   export TF_VAR_grp_platform_admins_object_id=$(
     az ad group show --group grp-qnsc-platform-admins --query id -o tsv)
   export TF_VAR_grp_developers_object_id=$(
     az ad group show --group grp-qnsc-developers --query id -o tsv)
   ```

   Both groups are ADOPTED (`groups.tf`, import), not created: the plan shows
   two imports with no change, and membership/description stay managed in
   Entra (`ignore_changes`). An update or a replace on either is NO-GO.

3. Plan and apply as above (owner-local only). The plan adds 3 applications,
   3 service principals, 3 federated identity credentials, 4 Secrets Officer
   + 3 Secrets User assignments — nothing wider.

4. Nothing else. With workload identity there is no per-store Secret to create
   at bootstrap, so the `platform-eso-*` / `qnsc-eso-*-cert` steps that §14
   step 2 used to carry are gone.

The certificate path (the `openssl` keypairs, the `eso_certificates` variable
and the `qnsc-eso-*-cert` cluster Secrets) was removed once gitops
authenticated through the federated credential; that shape is in the history
of this file.

## ESO workload identity: no secret zero (§7.1, end state)

A certificate is a long-lived secret that has to be kept, rotated and replaced
when lost — and it leaked once. The end state is a **federated identity
credential**: Entra trusts a service-account token minted by the cluster's own
OIDC issuer, and ESO exchanges it for a Key Vault token. Nothing to store,
nothing to leak.

`eso.tf` adds, per store (`dev`, `prod`, `platform`):

| federated credential field | value |
| --- | --- |
| issuer | `var.eso_oidc_issuer` — default `https://oidc.qnsc.vn/k3s-onprem` |
| subject | `system:serviceaccount:external-secrets:eso-<env>` |
| audience | `api://AzureADTokenExchange` (the fixed exchange audience) |

Three places carry the issuer and must agree: this variable, `live/onprem-oidc`
(the published OIDC documents) and the `k3s_server_oidc_issuer` variable of the
`k3s_server` Ansible role (what k3s signs tokens with). The static guard fails
when the first two drift. The third is a site value in the git-ignored Ansible
inventory (public repo), so CI cannot see it: step 4's `iss` check below is the
only gate for it.

### Ordering — this PR does NOT cut over by itself

Entra must trust the issuer before the cluster can use it, and gitops must stop
using the certificate before the certificate can be removed. Three states, two
applies, and the middle one is a gitops change (agent D applies it; this stack
is never edited by that side):

1. **Snapshot first.** Proxmox snapshot of VM 100 and a CNPG backup. The k3s
   restart in step 4 is the only step that touches the running cluster.
2. **`live/onprem-oidc` applied (owner, local).** Publishes the discovery
   document + JWKS captured from the running cluster. Curl both URLs and
   confirm the issuer string.
3. **This stack, first apply (owner, local).** Adds 3 federated identity
   credentials. The certificates stay. Expected plan: 3 to add, 0 to change,
   0 to destroy.
4. **k3s issuer (owner, Ansible; downtime accepted).** The `k3s_server` role
   (`ansible/roles/k3s_server`) writes the two `service-account-issuer` lines: the new URL FIRST (k3s signs with
   it), the old default SECOND (accepted, never issued). In the git-ignored local inventory set
   `k3s_server_oidc_issuer_enabled: true` and `k3s_server_oidc_issuer: <the issuer above>`.
   Dry run: `ansible-playbook k3s-server.yml --tags k3s_server_config --check --diff` must show only those
   two lines. Read the live audiences BEFORE the restart:
   `ps -o args= -C k3s | tr ' ' '\n' | grep -E 'api-audiences|service-account-issuer'`
   (k3s sets `--api-audiences` itself, so existing tokens keep a valid
   audience; if it prints no `api-audiences`, STOP: the default audience
   would follow the new first issuer and break every pre-restart token).
   Apply with `-e k3s_server_allow_restart=true` (the config change restarts k3s). Verify with a token from an
   EXISTING service account (the ESO SAs do not exist until step 5):

   ```sh
   tok=$(kubectl -n external-secrets create token default --audience api://AzureADTokenExchange)
   p=$(printf %s "$tok" | cut -d. -f2 | tr '_-' '/+')
   while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
   want='https://oidc.qnsc.vn/k3s-onprem
   system:serviceaccount:external-secrets:default
   api://AzureADTokenExchange'
   got=$(printf %s "$p" | base64 -d | jq -r '.iss, .sub, .aud[0]')
   [ "$got" = "$want" ] && echo MATCH || echo MISMATCH
   ```

   (A JWT payload is base64url, hence the alphabet swap and the padding;
   only `MATCH` passes: the three lines must be exactly the new issuer, the
   service account and the exchange audience.)

   Then confirm ArgoCD and the CNPG clusters are healthy — tokens minted
   before the restart carry the OLD issuer and are accepted only because the
   old value is still in the list.
5. **gitops (D).** `platform/eso/stores-onprem.yaml` switches each store from
   `authType: ServicePrincipal` to `WorkloadIdentity` and adds the three
   ServiceAccounts (annotated `azure.workload.identity/client-id`). Prove all
   three stores `Valid` and an ExternalSecret syncing.
6. **Merge + apply this PR** (the certificate removal): the plan destroys
   `azuread_application_certificate.eso["dev"|"prod"|"platform"]` and removes
   `var.eso_certificates` and the openssl steps — **3 to destroy, 0 to add,
   0 to change**, nothing else in the stack. Never merge it before step 5
   reports every store `Valid` on `WorkloadIdentity`.

   After the apply, prove the stores never leaned on the certificate. First the
   three stores' AUTH SHAPE — each line must read `WorkloadIdentity` with an
   EMPTY `authSecretRef` (a name there means a secret-based credential is still
   wired):

   ```sh
   kubectl get clustersecretstore kv-qnsc-dev kv-qnsc-prod kv-qnsc-platform \
     -o jsonpath='{range .items[*]}{.metadata.name} {.spec.provider.azurekv.authType} {.spec.provider.azurekv.authSecretRef}{"\n"}{end}'
   ```

   Then force one sync per store and read its result — every one must be
   `SecretSynced` (a credential problem surfaces here, not as a silent retry):

   ```sh
   # one ExternalSecret per store (the three stores back different namespaces)
   kubectl get externalsecrets -A \
     -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name
   # ... pick one per store's namespace, then force it:
   kubectl -n <namespace> annotate externalsecret <name> \
     force-sync="$(date +%s)" --overwrite
   kubectl get externalsecrets -A \
     -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status,REASON:'.status.conditions[?(@.type=="Ready")].reason'
   ```

   Every forced ExternalSecret must read `READY=True` / `REASON=SecretSynced`.
   Only then delete the three Secrets — nothing reads them, deleting them is
   final:

   ```sh
   kubectl -n external-secrets delete secret \
     qnsc-eso-dev-cert qnsc-eso-prod-cert qnsc-eso-platform-cert
   ```
7. **`live/onprem-vm`**: `tofu plan` there must still say **No changes** after step 4 (the k3s config is Ansible's, not a VM resource).

Until step 6 runs, both credentials exist and either authenticates — which is
what makes each step separately revertible.

### The published documents (`live/onprem-oidc`)

Entra fetches `<issuer>/.well-known/openid-configuration`, then the `jwks_uri`
inside it. Both are published from a Cloudflare Worker in `live/onprem-oidc`
(the provider has no resource that uploads static objects to R2 and none that
deploys Pages, so a Worker is the only way to keep the content in Terraform).

The JWKS is the PUBLIC half of the cluster's service-account signing key:

```sh
kubectl get --raw /openid/v1/jwks > /tmp/jwks.json     # public keys only
TF_VAR_k3s_jwks="$(cat /tmp/jwks.json)" tofu apply     # in live/onprem-oidc
```

### Rotation of the service-account signing key

**k3s does not rotate it on its own.** The API server SIGNS with
`/var/lib/rancher/k3s/server/tls/service.current.key`
(`service-account-signing-key-file`, k3s `pkg/daemons/control/server.go`), and
VALIDATES with `service.key` (`service-account-key-file`) — which is why
`service.key` can hold several keys and old tokens keep working. They are
rewritten only by `k3s certificate rotate-ca` (k3s docs, "Service-Account
Issuer Key Rotation": stage the new key, append the old one, rotate, restart).
Nothing in k3s watches the file.

So the published JWKS stays valid until someone rotates deliberately. When
that happens, in this order:

1. **Stage the new key (old stays the signer).** Append the new key to
   `service.key` after the old one (`service.current.key` unchanged), restart
   k3s: the API server now lists both keys in its JWKS.
2. **Publish first.** `kubectl get --raw /openid/v1/jwks` (both keys), then
   `TF_VAR_k3s_jwks=... tofu apply` in `live/onprem-oidc`; curl the served
   JWKS and confirm both `kid`s; copy the new `jwks_sha256` output into
   `live/onprem-oidc/jwks-expected.txt` (the drift detector compares to it).
   Entra now trusts both keys.
3. **Switch the signing key second.** Point `service.current.key` at the new
   key, restart k3s. New tokens are signed with it; Entra already knows it.
4. **Drop the old key last,** after the longest token lifetime: remove it from
   `service.key`, restart k3s, re-publish (steps 2 again, JWKS with the new key
   only) and update `jwks-expected.txt`.

Publishing both keys in step 2 is what makes the rotation uninterrupted; a
JWKS that carried only the new key would reject every token minted before the
rotation.

Where the mechanisms come from (checked 2026-10-31):

- ESO, Azure Key Vault provider — https://external-secrets.io/latest/provider/azure-key-vault/
  (`authType: WorkloadIdentity`, `serviceAccountRef.name`/`namespace`, and the
  `azure.workload.identity/client-id` annotation on the ServiceAccount; the
  audience `api://AzureADTokenExchange` is added by the provider itself —
  `AzureDefaultAudience` in `providers/v1/azure/keyvault/keyvault.go` at the
  chart's pinned version 2.11.0).
- Microsoft Learn, "Create a trust relationship between an app and an external
  identity provider" — https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust
  (issuer / subject / audience semantics; the wrong-subject failure is silent).
- k3s, "k3s certificate" (Service-Account Issuer Key Rotation) —
  https://docs.k3s.io/cli/certificate
  (the rotation is manual: `k3s certificate rotate-ca` + restart; k3s never
  rotates the signing key by itself).

## Sign-in apps (`apps.tf`): owner export, plan, go/no-go

The four existing registrations are ADOPTED (import blocks), never recreated.
Because azuread 3.x does not treat app roles / optional claims / identifier
URIs as Computed, anything the code omits would be REMOVED on apply — so the
owner exports the live shape first and the plan is a hard go/no-go.

1. Export the FULL live shape of each app AND its service principal — not a
   subset: azuread treats `web.homepage_url`, `web.logout_url`,
   `web.implicit_grant`, the `api` block (`requested_access_token_version`,
   oauth2 scopes), `sign_in_audience`, `feature_tags`, `tags`, `notes`, other
   `required_resource_access`, and the SP's `login_url`/`tags` as
   non-Computed too, so anything the code omits would be REMOVED on apply.
   The loop FAILS unless exactly one app matches each name:

   ```sh
   # NOTE: --display-name is a PREFIX match ("Rova Dev" also hits
   # "Rova Dev Service") — filter on EXACT equality instead:
   mkdir -p ~/signin-export && cd ~/signin-export
   for app in "Rova Prod" "Rova Dev" "OpsHub Dev" "KB Dev"; do
     n=$(az ad app list --filter "displayName eq '$app'" --query 'length(@)' -o tsv)
     [ "$n" = "1" ] || { echo "expected exactly 1 app named '$app', got $n — STOP"; exit 1; }
     app_id=$(az ad app list --filter "displayName eq '$app'" --query '[0].appId' -o tsv)
     slug=$(echo "$app" | tr ' ' '-' | tr 'A-Z' 'a-z')
     az ad app show --id "$app_id" > "$slug-app.json"
     az ad sp show --id "$app_id"  > "$slug-sp.json"
   done
   ```

2. Owner diffs each export against the code (this is the go/no-go, below).
   From the exports, fill EVERY sign-in variable:
   - `TF_VAR_existing_object_ids` / `TF_VAR_existing_sp_object_ids` — the app
     and SP object ids, the `id` field of each saved JSON, as one JSON map per
     variable:
     `jq -n --slurpfile a rova-prod-app.json '{rova_prod:$a[0].id, …}'`
     (keys `rova_prod`/`rova_dev`/`opshub_dev`/`kb_dev`);
   - `TF_VAR_opshub_dev_app_role_ids` — the App Role `id` GUIDs (keys `admin`,
     `it-admin`, `security`, `hr`, `manager`, `helpdesk`, `auditor` — 7 roles;
     there is NO `employee` role live and none is modeled);
   - `TF_VAR_existing_identifier_uris` — JSON map keyed like above; pass `{}`
     ONLY if the exports show none;
   - `TF_VAR_owner_operator_object_id` and `TF_VAR_second_owner_object_id` —
     the two human owners (A4/O2).
   Display names, descriptions and member types are IN the code now, taken
   verbatim from the 2026-10-27 export (admin: `Admin`, `["User"]` — the
   `Application` member type was dropped by the 2026-11-06 audit because no
   SP holds the role; auditor: `Auditor`; the rest `["User"]`). If a
   future export differs from the code on any role field, STOP and reconcile
   in a reviewed commit first. If an export shows `optionalClaims`, a `groupMembershipClaims`
   value, or ANY of the non-Computed fields above set differently from the
   code, STOP and encode the difference in a reviewed commit BEFORE the
   apply — the code cannot guess it.

   **Once this lands on main, EVERY `live/identity` plan/apply needs ALL of
   these variables exported — Phase-1-only plans (vault RBAC + ESO alone) are
   no longer possible.**

3. Expected plan: **8 imports** (4 applications + 4 service principals) and
   **in-place updates on the imported apps only** — 0 create, 0 destroy. Any
   other resource appearing in the plan is NO-GO. Since #238/#239 the plan
   also names exactly **3 FIC in-place updates** (subject flips to the
   numeric org/repo-id form; credential ids untouched — `subject` is a plain
   updatable attribute, CI keeps the same app/credential): the federated
   credentials `infra-environment-production`
   (`…@297362956/infra@1282170347:environment:production`), `infra-pull-request`
   (`…:pull_request`) and `infra-main-schedule` (`…:ref:refs/heads/main`) on
   the two `QNSC CI Infra`/`QNSC CI Infra Read` apps. A FIC removal, a
   replacement, or a fourth FIC is NO-GO.

   **Go/no-go: 8 imports and ONLY the changes named in the PR body. Any
   removal, replacement, or a change on an imported app that the PR does not
   name is NO-GO — STOP, export again, and reconcile the code in a reviewed
   commit instead of applying.**

4. After apply: record `signin_app_client_ids`; rotate/land client secrets
   with `scripts/rotate-signin-secret.sh` (≤ 6 months, into the vault).
   KB Dev's cluster credential is split from the laptop one with
   `docs/runbooks/kb-dev-signin-secret.md` (one app, two credentials, same
   ESO key).

## Cloudflare Access IdP app (`cf_access.tf`)

"QNSC Cloudflare Access" is the Entra app every Zero Trust door signs users in
with. It was the only sign-in app outside this stack (2026-11-06 drift audit,
Med), so `cf_access.tf` ADOPTS it — app, service principal and its tenant-wide
(AllPrincipals) delegated Graph grant — with `import` blocks. No object is
created.

Owner steps (the apply kit builds `TF_VAR_cf_access_object_ids` from read-only
lookups; nothing is typed or committed):

1. Run the kit's check mode, then the plan:

   ```sh
   scripts/owner/identity-env/identity-env.sh
   scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan
   ```

2. **Go/no-go: 3 imports** (application, service principal, delegated grant),
   **0 to add, only the 2 SP owners to change, 0 to destroy, 0 to replace.**
   The app already has those two owners; the live SP has none. If the plan
   shows a change on the app's redirect URIs, scopes or grant claim values,
   STOP: export the live app again and reconcile the code in a reviewed commit
   — never apply a change to the sign-in path of every Access door.

3. The CLIENT SECRET is not managed here (§7: values out of state) and the
   import does not touch it. The live credential is `cf-access-idp-2026-10`,
   expiring **2027-10-28** — 12 months, longer than the 6-month policy the
   rotation script enforces. At the next rotation window the owner runs:

   ```sh
   scripts/rotate-idp-secret.sh <app-object-id>
   ```

   which appends a +6-month credential and updates the infra repo secret
   `ENTRA_IDP_CLIENT_SECRET` that live/edge reads. Revoke the 12-month
   credential after a verified Access sign-in. The weekly expiry watch already
   covers it (metadata only).

## Coder sign-in (`coder.tf`): app "Coder" + group grp-qnsc-vlsi

The VLSI workspace platform (product-docs `projects/vlsi-platform/00_DESIGN.md` §5.2)
signs users in with Coder's own Entra OIDC. It is the ONE sign-in app with no
Cloudflare Access in front: Access breaks `coder` CLI, `coder ssh`, the workspace
agents and the `/api/v2` websockets. The door is Coder's allow list, and Coder is
not reachable from the public internet at all — live/edge routes `coder.qnsc.vn` and
`*.coder.qnsc.vn` over WARP only (private hostname routes).

Created here (nothing imported — the registration is new):

- `azuread_group.vlsi` — **grp-qnsc-vlsi**, security group. Membership is managed in
  the Entra admin center (`ignore_changes = [members]`); adding an engineer to the
  VLSI team is adding them to this group.
- `azuread_application.coder` — "Coder", single tenant, redirect
  `https://coder.qnsc.vn/api/v2/users/oidc/callback`, delegated scopes
  openid/profile/email/offline_access, `group_membership_claims = ["SecurityGroup"]`
  and id-token optional claims `groups`, `email`, `preferred_username`.
- its service principal (`app_role_assignment_required = false`) and the tenant-wide
  delegated grant, so no user meets a consent prompt.

Why the claim carries group OBJECT IDS: the tenant has no Entra ID P1, so
`ApplicationGroup` / group-based app assignment is unavailable and `SecurityGroup` is
the only form — the claim lists object ids. Coder compares the claim entries verbatim
against `CODER_OIDC_ALLOWED_GROUPS`, so the allow list is the object id printed by
`output grp_vlsi_id`.

**`CODER_OIDC_GROUP_FIELD=groups` is required, not cosmetic.** In Coder's AGPL code
(`coderd/idpsync/group.go`, `AGPLIDPSync.ParseGroupClaims`) the allow-list check runs
only when the group field is set AND the list is non-empty; with the field unset the
list is ignored silently. Group SYNC (mapping groups to Coder roles) is Premium and
is not used.

Owner steps:

1. Apply (this adds 4 resources — group, app, service principal, delegated grant —
   and creates no credential):

   ```sh
   scripts/owner/identity-env/identity-env.sh -- tofu apply -auto-approve tfplan
   tofu output -json | jq '{coder_oidc_client_id, coder_signin_app_object_id, grp_vlsi_id, coder_oidc_issuer_url}'
   ```

2. Create the client secret OUT OF BAND — 6 months, straight into
   `kv-qnsc-platform` (the `platform` ESO store's vault), never printed, never in
   state:

   ```sh
   scripts/rotate-signin-secret.sh <coder_signin_app_object_id> kv-qnsc-platform coder-oidc-client-secret
   ```

   The weekly expiry watch reads that vault and covers the new secret automatically
   (`kv-qnsc-platform` is a STRICT vault: a missing expiry is a FAIL).

3. Record the two ids in the gitops values for the Coder deployment (lane D):
   `coder_oidc_client_id` → `CODER_OIDC_CLIENT_ID`; `grp_vlsi_id` →
   `CODER_OIDC_ALLOWED_GROUPS` (with `CODER_OIDC_GROUP_FIELD=groups`);
   `coder_oidc_issuer_url` → `CODER_OIDC_ISSUER_URL`. The client secret reaches the
   pod through ESO from `kv-qnsc-platform`, not through a values file.

4. Add the VLSI engineers to **grp-qnsc-vlsi** in the Entra admin center. Anyone not
   in it is refused by Coder after a successful Entra sign-in. The same group is what
   live/edge enrolls in WARP (`ENTRA_GRP_VLSI_ID`) — membership is the single switch for
   both halves.

Pilot check before the team lands: sign in once as a member (works) and once as a
non-member (Coder refuses with "Not a member of an allowed group"), and confirm from a
non-member's WARP client that `coder.qnsc.vn` does not resolve.

## kubectl through Entra (`k3s_oidc.tf`): app "QNSC k3s"

Admins and developers sign `kubectl` in with Entra instead of sharing long-lived admin kubeconfig
files. kubelogin (`kubectl oidc-login`) obtains an ID token; the k3s API server verifies it as an
OIDC provider; RBAC maps the Entra **groups claim** to cluster roles.

- "QNSC k3s": single tenant, **public client** (no secret — it runs on a laptop), SecurityGroup
  membership claims, id-token claims `groups`/`email`/`preferred_username`, delegated
  openid/profile/email. Redirect URIs are kubelogin's defaults: `http://localhost:8000` and
  `http://localhost:18000`.
- Nothing secret is created. The owner applies this stack and records the outputs:

  ```sh
  tofu output -json | jq '{k3s_oidc_client_id, k3s_oidc_issuer_url}'
  ```

  `k3s_oidc_client_id` → `k3s_server_entra_client_id` in the LOCAL Ansible inventory; the two group
  object ids (`grp-qnsc-platform-admins`, `grp-qnsc-developers`) → `k3s_server_entra_platform_admins_group_id`
  and `..._developers_group_id`; `k3s_server_oidc_entra_tenant_id` is the tenant id.
- The API-server flags and the RBAC bindings are the `k3s_server` Ansible role
  (`k3s_server_entra_auth_enabled=true`), applied in an owner window because they need a k3s restart.
  Setup for a laptop — kubelogin, the kubeconfig stanza, the restart impact and the break-glass rule —
  is `docs/runbooks/kubectl-entra-login.md` in the infra repo.

## Proxmox VE + PBS login (`proxmox.tf`): app "QNSC Proxmox", plan, secret

Adds the Entra half of the Proxmox VE and Proxmox Backup Server OpenID realms;
ONE app backs both, so there is one client id, one client secret, one
direct-assignment list and one consent grant. The Proxmox half is the platform
runbook (server-setup §3.2.1, product-docs, private) and the `pve_base`/`pbs`
Ansible roles (ansible/README.md), run by the owner. The tenant has NO Entra ID
P1, so group-based app assignment and `ApplicationGroup` claims are unavailable:
the admin USERS are assigned directly and the ID token carries security-group
object ids (`SecurityGroup`).

PVE does NOT get groups from the token: it reads claim values from the
provider's userinfo endpoint (`query-userinfo` defaults on in
`src/PVE/API2/OpenId.pm`), and Microsoft's userinfo response carries no
`groups` — it returns only the standard name/subject/email claims and cannot be
customized (Microsoft Learn, "UserInfo endpoint"). The app's SecurityGroup
`groups` claim exists only in the ID token. So the `pve_base_entra` Ansible role
pre-creates `<email>@entra` for every shared admin email, makes each one a
member of `<group-object-id>-entra`, removes members no longer listed, and
keeps the realm at `autocreate=0` / `groups-overwrite=0`. PBS is the same model
(per-user ACL on a pre-created user); the app's assignment list still gates
sign-in on both.

**Adding or removing an admin = edit `TF_VAR_platform_admin_object_ids` (and
re-apply), the Entra group `grp-qnsc-platform-admins` (Cloudflare Access and the
Proxmox VE ACL key on it), AND `proxmox_entra_admin_emails` in the local Ansible
inventory. The same list drives the Proxmox app and the OpsHub Dev/Prod Admin
role (direct user assignments; group-based app assignment needs Entra ID P1).
Keep all three in step.**

The owner sequence is ONE identity plan/apply, then the secret, then the local
Ansible inventory and the Ansible run. Do not split the identity run: the same
plan carries #402 (rova invite scope).

1. Export the three identifiers the kit cannot read from Entra, then plan with
   the kit. The admin-door hostnames are Tier 1 in this public repo, so they
   stay out of Git; the kit builds `TF_VAR_proxmox_redirect_uris` from them,
   with the trailing slash azuread 3.10 requires. **Both hosts are required:**
   the ONE app registers the PVE and the PBS origin (runbook server-setup
   §3.2.1), so a missing or malformed host stops the kit before the plan. Both
   doors are https on 443 behind the Cloudflare tunnel, so neither value takes
   a port.

   ```sh
   # UPN of the second company owner
   export IDENTITY_SECOND_OWNER_UPN='<second owner UPN>'
   # https://<host>/ is registered for each door
   export IDENTITY_PROXMOX_HOST='<pve admin host>'
   export IDENTITY_PBS_HOST='<pbs admin host>'
   # optional: extra owners for DEV sign-in apps only, comma-separated app=MemberUPN
   export IDENTITY_DEV_APP_EXTRA_OWNERS='opshub_dev=<developer UPN>'
   scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan
   ```

   `IDENTITY_DEV_APP_EXTRA_OWNERS` is optional. It keeps a named developer as
   an OWNER of a DEV app registration (the live `signin["opshub_dev"]` carries
   one added by hand); unset means no extras. Set it for the owner run —
   without it the apply REMOVES that hand-added owner. Keys are limited to
   `rova_dev`, `opshub_dev`, `kb_dev` (both the kit and the variable
   validation reject a prod key). An app owner can add client credentials and
   redirect URIs, so prod apps never take extras. With the line above the
   plan shows **no change** to the `opshub_dev` owners (app and SP); every
   other line is unchanged.

   pve-manager and the PBS UI send `location.origin` (no slash) and Entra
   normalises the root. This first plan is a scout: existing direct Admin
   assignments appear as creates until step 3a imports them; the go/no-go
   gate is the re-plan in step 3d.

2. Go/no-go — this review applies to the FINAL plan produced in step 3d, not
   to the scout plan above. It must contain exactly these three change sets
   and nothing else.

   **Proxmox (`proxmox.tf`)** — ONE in-place update,
   `azuread_application.proxmox`, adding the PBS origin:

   ```
   ~ web {
       ~ redirect_uris = [
             "https://<pve host>/",
           + "https://<pbs host>/",
         ]
     }
   ```

   0 to add, 0 to destroy, 0 to replace; the service principal, the direct
   assignments and the delegated grant are unchanged. On a first apply instead:
   adds only (`azuread_application.proxmox`,
   `azuread_service_principal.proxmox`, one
   `azuread_app_role_assignment.proxmox_admins[...]` per listed user,
   `azuread_service_principal_delegated_permission_grant.proxmox`) and two new
   outputs — still 0 to change/destroy/replace.

   **#402 (`apps.tf`, applied by the same run)** — in-place updates on
   `azuread_application.signin["rova_prod"]` and `["rova_dev"]` removing the
   `User.Invite.All` application role from `required_resource_access`; at most
   the removal of a wizard-default delegated `User.Read` on "Rova Prod Service"
   / "Rova Dev Service" when the live export still shows it. NO grant is
   created, and no assignment may remain on either sign-in SP (they carry
   secrets and can mint app-only tokens); #402's pre-apply GET gate proves
   zero, and the dev service app stays empty. No certificate changes. #402
   must be in the same tree (merged main or its branch) — one plan, not two;
   run its gate first.

   **OpsHub Admin direct assignment (`apps.tf`, `prod_apps.tf`)** — the Admin
   role moves off `grp-qnsc-platform-admins` and onto each platform admin
   directly, from the SAME list as Proxmox
   (`var.platform_admin_object_ids`). Group-based app-role assignment is an
   Entra ID P1/P2 feature and the tenant has no P1 (owner decision 2026-11-04;
   Microsoft Learn, "Manage access to apps": "Group-based assignment (requires
   Microsoft Entra ID P1 or P2)",
   <https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/what-is-access-management#assigning-users-and-groups-to-an-app>).
   Expected in the FINAL plan (3d): **0 creates** under
   `azuread_app_role_assignment.opshub_dev_admin[...]` /
   `opshub_prod_admin[...]` — every live direct assignment was imported in 3a
   or created and verified in 3b. The two legacy unkeyed group assignments
   (`opshub_dev_admin`, `opshub_prod_admin`) are DESTROYED; live check
   2026-11-05 confirms #381 was applied and both exist. A user-key create in
   the final plan is the duplicate path — import it in 3a instead. 0 replace;
   any other destroy is NO-GO.

   Any other resource in the plan, any destroy beyond the group assignments
   named above, and any `must be replaced` is NO-GO: stop and reconcile in a
   reviewed commit before the apply.

3. Apply in two phases so no admin loses Admin while the group assignment is
   destroyed. The live tenant holds the group assignment AND some direct
   Admin user assignments (#381 applied; the API allowed the group without
   P1).

   **3a. Import every existing direct Admin assignment first.** A CREATE for
   an assignment already live is a duplicate Entra rejects (409). This loop
   lists the `admin` role's assignments on each OpsHub sign-in SP, excludes
   the group principal, keeps only platform-admin users, and imports each at
   its `for_each` address:

   ```sh
   GROUP=$(az ad group show --group grp-qnsc-platform-admins --query id -o tsv)
   next="https://graph.microsoft.com/v1.0/groups/$GROUP/members?\$select=id,userType,userPrincipalName"
   USERS=""
   while [ -n "$next" ]; do
     page=$(az rest --method get --url "$next" -o json) || exit 1
     bad=$(jq '[.value[] | select((.userType // "") != "Member")] | length' <<<"$page")
     [ "$bad" = 0 ] || { echo "STOP: grp-qnsc-platform-admins has a guest, group or non-Member member"; exit 1; }
     USERS=$(printf '%s\n%s' "$USERS" "$(jq -r '.value[].id' <<<"$page")")
     next=$(jq -r '.["@odata.nextLink"] // empty' <<<"$page")
   done
   GOT=$(printf '%s' "$USERS" | grep -c . || true)
   EXPECTED=$(scripts/owner/identity-env/identity-env.sh -- \
     sh -c 'printf "%s" "$TF_VAR_platform_admin_object_ids" | jq length')
   [ "$GOT" -gt 0 ] || { echo "STOP: USERS is empty — refusing to import or build targets"; exit 1; }
   [ "$GOT" = "$EXPECTED" ] || { echo "STOP: USERS ($GOT) != platform_admin_object_ids ($EXPECTED)"; exit 1; }
   for pair in "OpsHub Dev:opshub_dev_admin" "OpsHub Prod:opshub_prod_admin"; do
     app=${pair%%:*}; res=${pair##*:}
     appId=$(az ad app list --filter "displayName eq '$app'" --query "[0].appId" -o tsv)
     sp=$(az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv)
     role=$(az ad app show --id "$appId" --query "appRoles[?value=='admin'].id | [0]" -o tsv)
     az rest --method get \
       --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignments" \
       --query "value[?appRoleId=='$role' && principalId!='$GROUP'].{principalId:principalId,assignment:id}" -o tsv |
     while IFS=$'\t' read -r principal assignment; do
       [ -n "$principal" ] || continue
       printf '%s\n' "$USERS" | grep -qx "$principal" || continue
       scripts/owner/identity-env/identity-env.sh -- tofu import \
         "azuread_app_role_assignment.${res}[\"$principal\"]" \
         "/servicePrincipals/$sp/appRoleAssignedTo/$assignment"
     done
   done
   ```

   `az ad group member list` is NOT used: it omits `userType`, which made the
   old query return an empty list on the live tenant. Read the members through
   Graph with the fields selected and page through `@odata.nextLink`; the gate
   above dies on a non-Member member, an empty list, or a count that differs
   from the kit's `platform_admin_object_ids`.

   A principal outside the group (a stale Admin) is intentionally NOT
   imported: it is not in the shared list, and per-user grants are additive,
   so the apply leaves it alone. Remove it by hand if it should not have
   Admin.

   **3b. Create only the missing user assignments.** Target the user-keyed
   instances explicitly — targeting the bare resource address would include
   the legacy group instance and destroy it in this phase:

   ```sh
   targets=()
   while IFS= read -r u; do
     [ -n "$u" ] || continue
     targets+=(-target="azuread_app_role_assignment.opshub_dev_admin[\"$u\"]")
     targets+=(-target="azuread_app_role_assignment.opshub_prod_admin[\"$u\"]")
   done <<<"$USERS"
   [ "${#targets[@]}" -gt 0 ] \
     || { echo "STOP: no -target built (USERS empty?) — refusing a full apply"; exit 1; }
   scripts/owner/identity-env/identity-env.sh -- tofu apply "${targets[@]}"
   ```

   **3c. Verify every admin holds Admin on BOTH apps** (one assignment per
   user per app, exact GET):

   ```sh
   for app in "OpsHub Dev" "OpsHub Prod"; do
     appId=$(az ad app list --filter "displayName eq '$app'" --query "[0].appId" -o tsv)
     sp=$(az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv)
     role=$(az ad app show --id "$appId" --query "appRoles[?value=='admin'].id | [0]" -o tsv)
     while IFS= read -r u; do
       [ -n "$u" ] || continue
       n=$(az rest --method get \
         --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignments" \
         --query "value[?principalId=='$u' && appRoleId=='$role'] | length" -o tsv)
       [ "$n" = 1 ] || { echo "STOP: $u does not hold Admin on $app"; exit 1; }
     done <<<"$USERS"
   done
   echo "ok: every platform admin holds Admin on both apps"
   ```

   **3d. Re-plan, apply the FINAL plan, record the outputs.** The plan must
   match step 2 (group destroys + Proxmox redirect + #402 only). The plan
   file holds the values, so delete it after the apply:

   ```sh
   scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan
   # review against step 2 before this line
   scripts/owner/identity-env/identity-env.sh -- tofu apply tfplan
   scripts/owner/identity-env/identity-env.sh -- tofu output -raw proxmox_oidc_client_id
   scripts/owner/identity-env/identity-env.sh -- tofu output -raw proxmox_oidc_issuer_url
   rm live/identity/tfplan
   ```

   Every `tofu` call goes through the kit: the azurerm backend needs
   `ARM_SUBSCRIPTION_ID`, which the kit exports for the child (`tofu output`
   alone fails in a fresh shell).

4. Create the client secret OUT OF BAND straight into the admin vault: nothing
   printed, nothing in state, ≤ 6 months. Reuse the sign-in rotation script —
   it `--append`s (never wipes a live credential) and prints the new
   credential's `keyId` to stderr BEFORE the vault write, so a failed write
   leaves a revocable handle:

   ```sh
   ./scripts/rotate-signin-secret.sh \
     "$(scripts/owner/identity-env/identity-env.sh -- tofu output -raw proxmox_oidc_client_id)" \
     kv-qnsc-admin admin-proxmox-oidc-secret
   ```

   Revoke an orphaned credential by its `rotated-<UTC timestamp>` display name:

   ```sh
   az ad app credential list --id "<proxmox client id>" -o table
   az ad app credential delete --id "<proxmox client id>" --key-id "<keyId>"
   ```

   BOTH realms use this one secret. Set the calendar reminder before the
   6-month expiry; a rotation stores the new value under the same secret name
   and reruns both Ansible roles with the rotate flags
   (ansible/README.md, "Entra OpenID login").

5. Fill the LOCAL Ansible inventory with the four non-secret site values
   (git-ignored; this repo is public). The block is in ansible/README.md
   "Entra OpenID login": `proxmox_oidc_issuer_url` and
   `proxmox_oidc_client_id` from step 3d, `proxmox_oidc_admin_group_oid` from
   `az ad group show --group grp-qnsc-platform-admins --query id -o tsv`, and
   `proxmox_entra_admin_emails` = the Entra `email` claim of the two platform
   admins (owner-held addresses, exact casing, never committed; keep the list
   equal to the app's direct assignments and the group). The old
   `pbs_entra_admin_emails` key is still accepted as a fallback.

6. From `ansible/`, with the vault secret only in the environment (never argv
   or a file), run the dry run and then the run:

   ```zsh
   export PROXMOX_OIDC_CLIENT_SECRET="$(az keyvault secret show --vault-name kv-qnsc-admin \
     --name admin-proxmox-oidc-secret --query value -o tsv --only-show-errors)"
   ansible-playbook pve-host.yml --check --diff --tags pve_base_entra,pbs_entra
   ansible-playbook pve-host.yml --tags pve_base_entra,pbs_entra
   unset PROXMOX_OIDC_CLIENT_SECRET
   ```

   The first login on each door must show no `AADSTS50011` (redirect URI
   mismatch); if it does, STOP and tell the SA.

## Mail service apps (`mail.tf`): owner export, plan, go/no-go

One certificate-only Service app per product per env, `<Product> <Env> Service`
(§7.3): **rova prod** (the registration was hand-made on 2026-11-01 — step 1) plus the
three **existing dev service apps** (live since 2026-10-18) — all ADOPTED via
import. The **dev certificates are adopted too** (SA decision — no rotation):
imported by `<app object id>/certificate/<keyId>`, value = the exact public
certificate already in 1Password ("Entra mail cert – <product>-dev –
certificate"). **rova_prod's certificate is adopted the same way**: the hand-made
app already carries it (2026-11-01; its combined PEM is
`kv-qnsc-prod/rova-prod-graph-cert`), so nothing is created in this stack.
Import id form (azuread 3.10 parser): EXACTLY
`<app OBJECT id>/certificate/<keyId>` — no `/applications/` prefix.
**Additional credentials** (rotation) are adopted the same way, one
`azuread_application_certificate.mail_service_rotated` per credential, keyed by
its keyId. **KB Dev Service carries two today**: the 2026-10-18 credential above
and a Key Vault-generated one the owner appended on 2026-11-04 with
`az ad app credential reset --cert --append` (the vault holds the private key,
Entra the public half, `kv-qnsc-dev/kb-dev-graph-cert`). Both are imported, so the plan shows an
IMPORT and never a create or replace.

NO opshub/kb PROD apps in this section: opshub prod's service app is CREATED
in `prod_apps.tf` (below); kb prod's service app comes with its own prod PR.
Guest invitation is **prod-only** in this sense: the ONE Entra tenant is
shared by dev and prod, and only the **PROD service app** ("Rova Prod
Service") holds the `User.Invite.All` grant (tenant-wide, §7.3/H-D14, backlog
P0-7), admin-consented on apply. rova's sign-in apps must hold NO Graph
application permission or assignment. N-M10 removes the `User.Invite.All`
role both sign-in apps still declare **and** the live assignments they carry:
a sign-in app DOES have a client secret, so it can mint an app-only token —
the control is "no `User.Invite.All` assignment on any sign-in SP", proven by
the pre-apply GET gate below. rova#763 moved the only Graph invitation call
to `EntraGuestInviteClient` on the SERVICE certificate (`MAIL_GRAPH_CLIENT_ID`).

**Dev must NOT hold the grant.** A dev-vault certificate must not be able to
invite guests into that shared production tenant (SA decision 2026-11-05), so
"Rova Dev Service" stays empty. **The absent grant is the security control;
the `ENTRA_GUEST_INVITE_ENABLED=false` flag is not** — it only stops new
enqueues (see `mail.tf`). Dev tests the invitation with the feature off.

**The keyIds are PINNED in `mail.tf`** (`local.mail_service_cert_key_ids` and
`local.mail_service_rotated_cert_key_ids`), not derived and not passed as
Terraform variables. A credential keyId is a public identifier, and a value that
comes from a variable can be missing or mistyped — which would empty a
resource's `for_each` and **destroy the live credential** on the next apply
(`create_before_destroy` does not protect a destroy). With pinned ids the plan
is driven by reviewed code: the kit only ASSERTS that every pinned credential
exists on its app, that no unpinned credential is live, and that every
credential has a `startDateTime`. Every certificate resource also carries
`prevent_destroy = true`, so no apply can drop one.

An import block whose resource is already in state with the SAME id is a
**no-op** in OpenTofu (verified 2026-11-04 with 1.12: the resource is refreshed,
not re-imported), so the blocks stay in the tree after the apply. An import
block with a DIFFERENT id against a managed address fails the plan — a stop, not
a replace.

**Retiring a credential** (the 2026-10-18 KB Dev key is dead — its private key
never left AWS). NEVER delete a resource from `mail.tf`: that plans a destroy in
an ordinary apply, and `prevent_destroy` turns it into a hard error. Forget the
object from state FIRST, then remove the pin; the Entra delete is the LAST step,
by hand. `removed { ... }` blocks take a RESOURCE address, not an instance, so a
single rotated credential is forgotten with `tofu state rm`.

ROTATED credential (an entry of `mail_service_rotated_cert_key_ids`):

1. Forget the instance (no Entra call):

   ```sh
   tofu state rm 'azuread_application_certificate.mail_service_rotated["<keyId>"]'
   ```

2. Remove its entry from the pinned list, and its PEM from
   `TF_VAR_mail_service_rotated_certificates` (the kit stops exporting an
   unpinned credential).
3. `tofu plan` → `No changes`. Nothing to apply.
4. Delete the credential in Entra (App registrations > <app> > Certificates &
   secrets) — only after the worker no longer uses it.

PRIMARY credential (`mail_service_cert_key_ids[<slot>]`) — the new one must be
managed as a rotated credential first, then promoted:

1. Confirm the replacement is pinned in the rotated list, imported, and applied,
   and that the worker's vault PEM already uses it.
2. Forget BOTH instances (no Entra call):

   ```sh
   tofu state rm 'azuread_application_certificate.mail_service_rotated["<newKeyId>"]'
   tofu state rm 'azuread_application_certificate.mail_service["<slot>"]'
   ```

3. In ONE commit: set the slot's `pinned_key_id` to the replacement, remove it
   from the rotated list, and keep the replacement as the slot's PUBLIC PEM in
   `TF_VAR_mail_service_certificates`.
4. `tofu plan` → **1 to import, 0 to add, 0 to change, 0 to destroy** (the
   primary import block adopts the replacement). A destroy is STOP.
5. Apply; then delete the OLD credential in Entra by hand.

Why the `state rm` first: an import block never re-targets an address that is
already in state, so without forgetting, the plan either does nothing or tries
to destroy the object — and `prevent_destroy` makes that a hard error.
1. The ONE registration that was missing, "Rova Prod Service", was hand-made
   on 2026-11-01 (single tenant, no redirect URI, no client secret, certificate
   attached, `User.Invite.All` consented) and is imported like the others. If
   it still carries the wizard's default delegated `User.Read`, leave it: the
   code models NO delegated permission for rova, so the plan REMOVING it is an
   intended, named change (step 4).

2. Export the live shape (umask first; the loop prints STOP and keeps going —
   it never `exit`s your shell; read the summary before continuing):

   ```sh
   umask 077
   mkdir -p ~/mail-export && cd ~/mail-export
   for app in "Rova Prod Service" "Rova Dev Service" "OpsHub Dev Service" "KB Dev Service"; do
     n=$(az ad app list --filter "displayName eq '$app'" --query 'length(@)' -o tsv)
     if [ "$n" != "1" ]; then echo "STOP: expected exactly 1 app named '$app', got $n"; continue; fi
     app_id=$(az ad app list --filter "displayName eq '$app'" --query '[0].appId' -o tsv)
     slug=$(echo "$app" | tr ' ' '-' | tr 'A-Z' 'a-z')
     az ad app show --id "$app_id" > "$slug-app.json"
     az ad sp show  --id "$app_id" > "$slug-sp.json"
   done
   ```

   From the exports also read `keyCredentials[].keyId` and confirm the pins in
   `mail.tf` (`local.mail_service_cert_key_ids`,
   `local.mail_service_rotated_cert_key_ids`) name exactly the live credentials,
   and that each dev app's `requiredResourceAccess` shows exactly the three
   opshub roles / none for rova and kb. Watch list (same as the sign-in apps,
   suppressed identically): SP `tags` (`HideApp`, …) and
   `api.requestedAccessTokenVersion` (live `null`) are provider-computed — never
   hand-model them.

3. Export the variables (values stay in your shell):

   - `TF_VAR_mail_service_object_ids` — the app-registrations object ids
     (the `id` field of each `*-app.json`):

     ```sh
     jq -n \
       --slurpfile a rova-prod-service-app.json \
       --slurpfile b rova-dev-service-app.json \
       --slurpfile c opshub-dev-service-app.json \
       --slurpfile d kb-dev-service-app.json \
       '{rova_prod:$a[0].id, rova_dev:$b[0].id, opshub_dev:$c[0].id, kb_dev:$d[0].id}'
     ```;
   - `TF_VAR_mail_service_sp_object_ids` — the SP object ids
     (`id` field of each `*-sp.json`);
   - **the keyIds are NOT exported any more**: they are pinned in
     `local.mail_service_cert_key_ids` / `local.mail_service_rotated_cert_key_ids`
     (see "The keyIds are PINNED" above). Adding a credential to an app means a
     reviewed edit there, in the same commit that adds its PEM to the variable
     below. Confirm the pins against the export before planning — every pinned
     keyId must be on its app, and every live credential must be pinned:

     ```sh
     for f in rova-prod rova-dev opshub-dev kb-dev; do
       jq -r --arg f "$f" '.keyCredentials[] | "\($f) \(.keyId)"' "$f-service-app.json"
     done
     ```

   - `TF_VAR_mail_service_certificates` — one PEM PUBLIC certificate per app.
     Dev: the EXACT live certificates from 1Password ("Entra mail cert –
     <product>-dev – certificate") — different bytes would plan a certificate
     replacement, which is NO-GO. rova_prod: the PUBLIC half of the certificate
     already on the app, taken from the vault (`openssl x509` reads only the
     first CERTIFICATE block and writes only it: the private key in the same
     file is neither read out nor printed):

     ```sh
     umask 077
     mkdir -p "$HOME/keys"
     az keyvault secret show --vault-name kv-qnsc-prod --name rova-prod-graph-cert \
       --query value -o tsv | openssl x509 -outform PEM > "$HOME/keys/rova-prod.crt"
     grep -c "PRIVATE KEY" "$HOME/keys/rova-prod.crt"   # must print 0
     ```

     **This check is MANUAL and mandatory.** The certificate resource has
     `ignore_changes = [value, encoding]`, so a wrong `rova_prod` certificate
     here plans CLEAN and the mismatch is never shown. Compare the SHA-1
     thumbprint of the vault certificate with the app's key credential
     (`rova-prod-service-app.json` from the export in step 2):

     ```sh
     want=$(openssl x509 -in "$HOME/keys/rova-prod.crt" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
     ck=$(jq -r '.keyCredentials[0].customKeyIdentifier' rova-prod-service-app.json)
     if printf '%s' "$ck" | grep -qE '^[0-9A-Fa-f]{40}$'; then have=$(printf '%s' "$ck" | tr 'A-F' 'a-f'); else have=$(printf '%s' "$ck" | base64 -d | xxd -p -c 64); fi
     [ "$want" = "$have" ] && echo MATCH || echo "MISMATCH: do not apply"
     ```

     MISMATCH means the vault holds a different certificate than the one on the
     app: stop and tell the SA. Do the same for a dev certificate if its
     1Password file is in doubt.

     Build the JSON with `jq --rawfile` so multi-line PEMs stay intact
     (adjust the dev paths to wherever 1Password wrote them):

     ```sh
     jq -n \
       --rawfile rova_prod "$HOME/keys/rova-prod.crt" \
       --rawfile rova_dev "$HOME/keys/rova-dev.crt" \
       --rawfile opshub_dev "$HOME/keys/opshub-dev.crt" \
       --rawfile kb_dev "$HOME/keys/kb-dev.crt" \
       '{rova_prod:$rova_prod, rova_dev:$rova_dev, opshub_dev:$opshub_dev, kb_dev:$kb_dev}'
     ```

     A private key in any value fails the variable validation.

4. `tofu plan` go/no-go — the mail part of the plan must read EXACTLY: **8
   imports** (4 applications + 4 service principals) + **4 certificate
   imports** (rova_prod and the three dev certs). The only application
   updates allowed are the two named here, and BOTH are the removal of the
   wizard-default delegated `User.Read` (the code models no delegated
   permission on a service app):
   - "Rova Prod Service": delegated `User.Read` REMOVED if the live export
     still shows it; `User.Invite.All` is already declared, consented and
     imported, so no role line.
   - "Rova Dev Service": delegated `User.Read` REMOVED if the live export
     still shows it. NO role is added — guest invitation is prod-only.

   NO certificate create. A plan that creates a certificate means the keyId is
   missing from the pinned map in `mail.tf`: STOP.
   Any OTHER change on an imported app — a permission add, a redirect URI, a
   secret credential — is NO-GO, and **any certificate showing "must be
   replaced" is STOP** (the certs are imported write-only; see the `mail.tf`
   resource comment). opshub_dev's three application roles are in the code; a
   different live set is STOP and reconcile `mail.tf` first.
   The `User.Invite.All` ADMIN CONSENT is a separate manual step right after
   apply (the plan only updates the app):

   ```sh
   az ad app permission admin-consent --id <rova_prod service app id>
   ```

   **N-M10 delta (this PR; it does not change the paragraph above).** The
   plan now also shows:
   - an UPDATE on the "Rova Prod" and "Rova Dev" SIGN-IN apps removing the
     `User.Invite.All` application role. Removing `required_resource_access`
     does NOT revoke a live assignment, and both sign-in apps carry client
     secrets, so they can mint app-only tokens and invite guests TODAY (the
     assignments were created 2026-08-16/17). The owner deletes both live
     assignments by hand (SA commands, 2026-11-05), then runs this gate; it
     must pass before the plan is approved:

     ```sh
     for app in "Rova Prod" "Rova Dev"; do
       apps=$(az ad app list --filter "displayName eq '$app'" -o json) || exit 1
       [ "$(jq 'length' <<<"$apps")" = 1 ] || { echo "STOP: expected exactly 1 app named '$app'"; exit 1; }
       appId=$(jq -r '.[0].appId' <<<"$apps")
       sps=$(az ad sp list --filter "appId eq '$appId'" -o json) || exit 1
       [ "$(jq 'length' <<<"$sps")" = 1 ] || { echo "STOP: expected exactly 1 SP for $app"; exit 1; }
       sp=$(jq -r '.[0].id' <<<"$sps")
       left=$(az rest --method get -o json \
         --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignments") || exit 1
       [ "$(jq '.value | length' <<<"$left")" = 0 ] || {
         echo "STOP: $app still holds app-role assignments — delete them before the apply"
         jq '.value[] | {assignment: .id, appRoleId, principalId}' <<<"$left"
         exit 1
       }
     done
     echo "gate OK: no app-role assignment on either rova sign-in SP"
     ```

     The gate stops on a missing/duplicate app or SP and on ANY remaining
     assignment (not only `User.Invite.All`). No role is added to "Rova Dev
     Service", and no grant is created there.
   - no change to "Rova Prod Service".

   **State after the 2026-11-04 identity apply:** the 4 applications, their 4
   service principals and their 4 primary certificates are IN STATE, and the
   four Graph grants the audit found (rova_prod `User.Invite.All`, opshub_dev's
   three read roles) are modelled but not yet imported. The next plan
   (`scripts/owner/identity-env/identity-env.sh -- tofu plan`, which also
   supplies the grant ids and KB Dev's second certificate) must read EXACTLY
   **8 to import, 0 to add, 0 to change, 0 to destroy, 7 to forget**:

   - `azuread_application_certificate.mail_service_rotated["e967b988-…"]` (KB
     Dev's 2026-11-04 credential);
   - `azuread_app_role_assignment.mail_service["rova_prod/User.Invite.All"]`,
     `["opshub_dev/DeviceManagementManagedDevices.Read.All"]`,
     `["opshub_dev/SecurityEvents.Read.All"]`, `["opshub_dev/User.Read.All"]`;
   - `azuread_app_role_assignment.opshub_prod_service["…Read.All"]` ×3.

   Any `create` on those addresses means the id map is wrong (STOP); a
   `destroy` or a certificate `must be replaced` is STOP, always. The **7 to
   forget** are the seven `azuread_application_app_role.opshub_prod` state
   entries that became inline `app_role` blocks on `azuread_application.opshub_prod`
   (prod_apps.tf): the plan shows
   "will be removed from the OpenTofu state but will not be destroyed" — no
   Entra call, the roles stay. Verify every one of the seven carries
   `destroy = false`; anything that says "will be destroyed" is STOP.
   After this apply the same plan reads `No changes` (the imports are no-ops).

5. After apply: record `mail_service_client_ids` (rova_prod's is the value
   rova's Graph config records; the dev values land in the dev bundles). The
   vault secrets already exist (rova_prod: `kv-qnsc-prod/rova-prod-graph-cert`,
   written when the app was hand-made; dev: 1Password combined PEMs, key +
   cert). Nothing is written to a vault in this step. A vault write is needed
   only on rotation: the FILE path is the argv, the value never is:

   ```sh
   pem=$(mktemp /tmp/graph-combined.XXXXXX) && chmod 600 "$pem"
   cat <new key pem> <new cert pem> > "$pem"
   az keyvault secret set --vault-name kv-qnsc-prod --name rova-prod-graph-cert --file "$pem"
   rm -f "$pem"   # after the vault holds it
   # dev, same shape: kv-qnsc-dev, names rova-dev-graph-cert / opshub-dev-graph-cert / kb-dev-graph-cert
   ```

   The worker reads them as `AZURE_CLIENT_CERTIFICATE_PATH` (§7.3 — one
   credential mechanism). Exchange-side RBAC (mailbox, scope,
   `Application Mail.Send`) stays in `scripts/owner/mail-prod-tenant/`.

**Rotation** (dev certs expire 2027-10-18, rova_prod ≤ 24 months). An apply
does NOT issue a credential: `value` is `ignore_changes`d and `prevent_destroy`
refuses a replace. The order is:

1. Append the new credential IN ENTRA — the app is the source of truth for the
   key; only the public half ever leaves the vault:

   ```sh
   az ad app credential reset --id <appId> --cert @"$HOME/keys/<product>-new.crt" --append
   az ad app credential list --id <appId> --cert --query "[].{keyId:keyId,start:startDateTime}" -o table
   ```

   Pin the new keyId in `local.mail_service_rotated_cert_key_ids` and add the
   new PUBLIC PEM to `TF_VAR_mail_service_rotated_certificates` (the kit does
   both from Entra; the pin is the reviewed change, the PEM is generated).
2. `tofu plan`: **1 to import, 0 to add, 0 to change, 0 to destroy**. A create
   or replace is STOP (and `prevent_destroy` would refuse the replace).
3. Apply, then write the new combined PEM to the vault (step 5) and point the
   worker at it. Between the apply and the vault swap the OLD credential stays
   valid — no gap.
4. Retire the old credential (next section) — never before the worker uses the
   new one.

The **OpsHub Prod Service** certificate is created by this stack from the
public half the owner passes. Appending a second credential to that app is a
reviewed change of the same shape (pin + import of the new keyId), not an
apply: this resource keeps the one credential it created.


### Delegated consent and app-role groups

Every sign-in app (Rova Dev/Prod, OpsHub Dev/Prod, KB Dev/Prod) has an
AllPrincipals `azuread_service_principal_delegated_permission_grant` for the
delegated scopes that app requests (`openid profile email offline_access
User.Read`, plus KB's `Files.Read`, `Files.Read.All` and `Sites.Read.All`), so
no user sees a consent prompt. The set is DERIVED from the app's
`requiredResourceAccess`, never a fixed list. Grant ids that already exist are
imported through `TF_VAR_signin_delegated_grant_ids` (the apply kit discovers
them); a missing key plans a create, which Entra rejects as a duplicate against
a live grant.

An apply replaces a grant's scope list, so the kit also reads each live grant's
scopes into `TF_VAR_signin_delegated_grant_scopes`. A live scope the derived set
would drop fails the plan (the KB Dev `email` case in #381): declare it on the
app first, or the apply revokes it.

The OpsHub Dev and Prod `admin` role is assigned DIRECTLY to each user in
`var.platform_admin_object_ids` (the same list as the Proxmox app); group-based
app-role assignment is an Entra ID P1/P2 feature this tenant does not have.
The other six roles stay per-user: no role-specific Entra group exists (owner
decision 2026-11-05). Per-user assignments are additive and never remove the
live user grants of the other roles.

### Extra OpsHub Dev admin holders (`dev_extra_admins.tf`)

Two tester grants were added by hand on 2026-08-31 (drift audit 2026-11-06):
people who hold the OpsHub Dev `admin` role but are neither platform admins nor
members of `grp-qnsc-platform-admins`. `dev_extra_admins.tf` ADOPTS those
assignments so the next apply does not remove them. DEV only; a prod key fails
the plan.

No name, UPN or object id is committed. The owner lists the people as
`opshub_dev=<upn>` pairs; the kit resolves each to a **Member** user and reads
the app's live `appRoleAssignedTo`, so the assignments that already exist are
IMPORTED (a re-create would be an HTTP 409):

```sh
export IDENTITY_DEV_APP_EXTRA_ADMINS='opshub_dev=<tester UPN>,opshub_dev=<tester UPN>'
scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan
```

Go/no-go: the plan shows **1 import per existing tester assignment** and no
change on them; any tester without a live assignment is a new add. Nothing to
destroy or replace. Removing a UPN from the list removes that assignment on
the next apply — review first.

## Prod identity: OpsHub (`prod_apps.tf`)

Unlike the dev pair, the prod pair does not exist: this stack CREATES it.
Nothing is imported, and the shape is OpenTofu's like any other resource.

- **"OpsHub Prod"** — sign-in app, Delegated Graph scopes only (the dev set:
  `openid profile email offline_access User.Read`), ONE redirect:
  `https://opshub.qnsc.vn/api/auth/callback/microsoft`. NO loopback (prod
  sign-in happens on the deployed host only). It carries the same seven app
  roles as the dev registration (the ids are derived name-based UUIDs, so a
  re-plan never changes them). No client secret in state: the owner creates
  it (step 4).
- **"OpsHub Prod Service"** — certificate only, the same three Graph
  application roles as the dev service app
  (`DeviceManagementManagedDevices.Read.All`, `SecurityEvents.Read.All`,
  `User.Read.All`). **Never `Mail.Send` in Entra** — prod mail is Exchange
  RBAC for Applications, scoped to the mailbox (step 7). Created only when
  the PUBLIC certificate is supplied, so a plan never creates an app without
  its credential.

### Pre-apply check (run it first)

The readiness report (2026-11-03) says neither app exists, so the plan is
CREATES. Confirm before spending the keypair step:

```sh
az ad app list --display-name "OpsHub Prod" --query "[].appId" -o tsv
az ad app list --display-name "OpsHub Prod Service" --query "[].appId" -o tsv
```

- **Both empty** — expected. Continue with the owner steps: `tofu plan` must
  show the 12 adds.
- **Any app exists** — do NOT create. Adopt it instead of a duplicate: add
  the import blocks below to `prod_apps.tf` (the ids are OBJECT ids, not app
  ids: `az ad app show --id <appId> --query id -o tsv`, and
  `az ad sp show --id <appId> --query id -o tsv`), then `tofu plan` must show
  no create for the imported addresses. The certificate import id is
  `<service app OBJECT id>/certificate/<keyId>` (the same shape mail.tf uses).

  ```hcl
  import {
    to = azuread_application.opshub_prod
    id = "/applications/<sign-in app OBJECT id>"
  }
  import {
    to = azuread_service_principal.opshub_prod
    id = "/servicePrincipals/<sign-in SP OBJECT id>"
  }
  import {
    to = azuread_application.opshub_prod_service[0]
    id = "/applications/<service app OBJECT id>"
  }
  import {
    to = azuread_service_principal.opshub_prod_service[0]
    id = "/servicePrincipals/<service SP OBJECT id>"
  }
  import {
    to = azuread_application_certificate.opshub_prod_service[0]
    id = "<service app OBJECT id>/certificate/<keyId>"
  }
  ```

  The seven app roles are INLINE on `azuread_application.opshub_prod`
  (`dynamic "app_role"`, ids derived in `local.opshub_prod_app_role_ids`) — the
  import of the application adopts them with it. The ids Entra holds must EQUAL
  the derived ones: after the import,
  `tofu output -json opshub_prod_object_ids | jq .signin_app_roles` reads the
  LIVE roles from state (not the local map), so a difference is visible. If
  they differ, STOP — reconciling them is a reviewed code change (a var like
  the dev `opshub_dev_app_role_ids`), not an import.

  The gitops comment that says the service app's certificate is "already in
  kv-qnsc-prod from the AWS-exit copy-out" (`values/opshub/prod.secrets.yaml`,
  the `opshub-prod-graph-cert` rule) is stale: this runbook creates and
  writes it. The gitops owner is correcting that comment; the README is the
  source of truth until then.

The seven roles have ONE owner: the inline `app_role` blocks on
`azuread_application.opshub_prod` (the same shape the dev app uses). The seven
separate `azuread_application_app_role.opshub_prod` objects of the 2026-11-04
apply are forgotten from state (`removed { destroy = false }`, no Entra call) —
the plan says "will be removed from the OpenTofu state but will not be
destroyed". Anything that removes or changes a role in the plan is STOP.

### Graph permission grants — import the existing ones, never create

A grant (`appRoleAssignment`) is a separate object on the Microsoft Graph
service principal; `required_resource_access` only DECLARES the role. A plan
that creates a grant without importing it first adds a DUPLICATE. Every role
declared in this stack is therefore also managed as
`azuread_app_role_assignment`: `mail_service` (keyed `<slot>/<role>`, from
`local.mail_service_graph_grants`) and `opshub_prod_service` (keyed `<role>`).

The DIRECTION matters: `servicePrincipals/<sp id>/appRoleAssignments` lists the
grants that app HOLDS. `appRoleAssignedTo` is the opposite one (who holds a role
ON this app) and shows nothing useful here — an earlier revision of this
section named the wrong endpoint.

The owner kit builds the import id maps — `TF_VAR_mail_service_graph_grant_ids`
and `TF_VAR_opshub_prod_service_graph_grant_ids` — from that endpoint (read
only; assignment ids are public identifiers, never pasted). With them set,
`tofu plan` shows the grants as IMPORTS; **0 to add**. A planned create means
the map is wrong: STOP.

Read-only audit of every service app (2026-11-04):

```sh
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"   # Microsoft Graph, well-known, not a secret
GRAPH=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)
for n in "Rova Prod Service" "Rova Dev Service" "OpsHub Dev Service" "KB Dev Service" "OpsHub Prod Service"; do
  sp=$(az ad sp list --display-name "$n" --query "[0].id" -o tsv)
  echo "$n"
  az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignments" \
    --query "value[?resourceId=='$GRAPH'].{assignment:id,appRoleId:appRoleId}" -o table
done
```

Result on 2026-11-04: Rova Prod Service **1** (`User.Invite.All`), OpsHub Dev
Service **3** (`DeviceManagementManagedDevices.Read.All`,
`SecurityEvents.Read.All`, `User.Read.All`), OpsHub Prod Service **3** (the same
three), Rova Dev and KB Dev **0**. Every granted role is declared in `mail.tf` /
`prod_apps.tf`, and this stack manages every one of those grants. A live grant
that is NOT declared, or a role declared with no grant, is a STOP: reconcile
`mail.tf`'s `graph_app_role_values` first, then re-run the kit.

Manual fallback (only if the kit cannot run; the id is the ASSIGNMENT id, the
resource is Microsoft Graph):

```sh
tofu import 'azuread_app_role_assignment.opshub_prod_service["User.Read.All"]' \
  "/servicePrincipals/$GRAPH/appRoleAssignedTo/<assignment id>"
```

### Owner steps

1. Generate the service keypair locally (RSA 2048, ≤ 24 months). Only the
   PUBLIC half goes to Terraform; the combined PEM goes to the vault. None of
   it enters the repo or TF state:

   ```sh
   umask 077
   mkdir -p "$HOME/keys" && cd "$HOME/keys"
   openssl req -x509 -newkey rsa:2048 -nodes \
     -keyout opshub-prod-key.pem -out opshub-prod-cert.pem \
     -days 730 -subj '/CN=OpsHub Prod Service'
   # ORDER MATTERS: private key (PKCS#8) FIRST, then the certificate —
   # exactly what the gitops consumer (values/opshub/prod.secrets.yaml)
   # reads. The other order mounts a file the worker cannot parse.
   cat opshub-prod-key.pem opshub-prod-cert.pem > opshub-prod-combined.pem
   grep -c "PRIVATE KEY" opshub-prod-cert.pem
   export TF_VAR_opshub_prod_service_certificate="$(cat "$HOME/keys/opshub-prod-cert.pem")"
   ```

   The `grep` must print `0` and the export carries the PUBLIC half only.
   `scripts/owner/identity-env/identity-env.sh` keeps TF_VARs already set in
   your shell, so this export survives the kit.

2. `tofu plan` with the full variable set (the kit). Go/no-go, exactly:
   **12 to add, 0 to change, 0 to destroy** — 1 sign-in application
   ("OpsHub Prod"), 1 service principal, 7 app roles; 1 service application
   ("OpsHub Prod Service"), 1 service principal, 1 certificate credential.
   Without `TF_VAR_opshub_prod_service_certificate` the plan adds only the
   sign-in app + SP + roles (9): supply the certificate and re-plan — do not
   apply the partial shape.

3. `tofu apply`, then record the outputs:
   `tofu output -json opshub_prod_client_ids` (gitops placeholders
   `<OPSHUB_PROD_ENTRA_CLIENT_ID>` = `signin`,
   `<OPSHUB_PROD_SERVICE_APP_ID>` = `service`) and
   `tofu output -json opshub_prod_object_ids` (follow-up steps below).

4. **Sign-in client secret** — never in state, ≤ 6 months, straight into the
   vault. The script appends the credential and writes it in one run:

   ```sh
   ./scripts/rotate-signin-secret.sh \
     "$(tofu output -json opshub_prod_client_ids | jq -r .signin)" \
     kv-qnsc-prod opshub-prod-entra-client-secret
   ```

5. **Service certificate** — the worker reads the combined PEM from the
   vault through ESO (key + cert, one secret). The FILE is the argv:

   ```sh
   az keyvault secret set --vault-name kv-qnsc-prod \
     --name opshub-prod-graph-cert \
     --file "$HOME/keys/opshub-prod-combined.pem" \
     --tags owner=platform rotate-by=2028-11-04
   ```

6. **Admin consent** for the three application roles (tenant-wide; they are
   the dev set, no `Mail.Send`):

   ```sh
   az ad app permission admin-consent \
     --id "$(tofu output -json opshub_prod_client_ids | jq -r .service)"
   ```

7. **Exchange RBAC** (owner, PowerShell 7 + ExchangeOnlineManagement, Exchange
   admin role). Creates the mailbox, the mailbox-scoped management scope and
   `Application Mail.Send` on the SERVICE app, then proves the scope. Allow up
   to an hour for propagation before debugging.

   ```powershell
   Import-Module ExchangeOnlineManagement
   Connect-ExchangeOnline -ShowBanner:$false
   # Run this INSIDE the repo's live/identity directory, logged in with `az
   # login`; the two values are read from the outputs, not typed.
   $svcApp = (tofu output -json opshub_prod_client_ids  | ConvertFrom-Json).service
   $svcObj = (tofu output -json opshub_prod_object_ids  | ConvertFrom-Json).service_sp
   $own    = 'noreply-opshub@qnsc.vn'

   Get-Mailbox -Identity $own -ErrorAction SilentlyContinue
   New-Mailbox -Shared -Name 'OpsHub No-Reply' -Alias 'noreply-opshub' -PrimarySmtpAddress $own
   New-ManagementScope -Name 'noreply-opshub' -RecipientRestrictionFilter "PrimarySmtpAddress -eq '$own'"
   New-ServicePrincipal -AppId $svcApp -ObjectId $svcObj -DisplayName 'OpsHub Prod Service'
   New-ManagementRoleAssignment -App $svcApp -Role 'Application Mail.Send' -CustomResourceScope 'noreply-opshub'
   foreach ($mb in 'noreply-opshub@qnsc.vn','noreply-rova@qnsc.vn','noreply-kb@qnsc.vn','noreply-opshub-dev@qnsc.vn') {
     $in = @(Test-ServicePrincipalAuthorization -Identity $svcApp -Resource $mb) |
       Where-Object { $_.RoleName -eq 'Application Mail.Send' } |
       ForEach-Object { [string]$_.InScope }
     '{0,-32} {1}' -f $mb, ($in -join ',')
   }
   ```

   The proof table must read `True` for `noreply-opshub@qnsc.vn` and `False`
   for every other row. Run each `New-*` only when the matching `Get-*` shows
   it missing (all of them are idempotent in the rova script's shape; a
   second `New-ManagementScope` fails on the name). If `Get-Mailbox` finds a
   non-SharedMailbox at that address, stop and fix it by hand.

8. **Group access** — already wired, nothing in this stack: prod internal
   tools are gated at the EDGE by `grp-qnsc-staff` (this stack's
   `grp_staff_id` output → repo variable `ENTRA_GRP_STAFF_ID` → live/edge).
   The `opshub.qnsc.vn` host row in live/edge and its Access policy are the
   edge owner's change; inside opshub, access is the app roles above.

### Key Vault wiring (`opshub-prod-*`)

Values never pass through OpenTofu. The prod ESO store already authenticates
with workload identity and reads `kv-qnsc-prod` (Secrets User, Phase 1), so
there is no per-name TF resource to add. `values/opshub/prod.secrets.yaml`
expects these names in `kv-qnsc-prod`:

| Secret | Written by |
| --- | --- |
| `opshub-prod-entra-client-secret` | step 4 (this README) |
| `opshub-prod-graph-cert` | step 5 (this README) |
| `opshub-prod-cookie-secret`, `-csrf-secret`, `-better-auth-secret` | owner bootstrap (`secrets.sh --product opshub --env prod`), random values |
| `opshub-prod-db-app`, `-db-worker`, `-db-migrator`, `-db-readonly`, `-redis-url` | owner bootstrap / pg-opshub provisioning |
| `opshub-prod-storage-access-key-id`, `-storage-secret-access-key` | R2 token (live/storage-prod) |

## Prod identity: KB (`kb_prod_apps.tf`)

The prod pair does not exist: this stack CREATES it, exactly like OpsHub prod.

- **"KB Prod"** — sign-in app, the dev delegated set (`openid profile email
  offline_access User.Read Files.Read Files.Read.All Sites.Read.All`), TWO
  redirects on the decided prod host:
  `https://kb.qnsc.vn/api/v1/auth/entra/callback` and
  `https://kb.qnsc.vn/api/v1/connectors/oauth/callback`. No loopback, no
  optional id-token claims, no app roles (the dev app has none).
- **"KB Prod Service"** — certificate only, the same EMPTY Graph permission
  set as KB Dev Service. Mail is Exchange RBAC for Applications, never
  `Mail.Send` in Entra.
- **Tenant-wide delegated consent** — the same
  `azuread_service_principal_delegated_permission_grant.signin["kb_prod"]`
  resource as every other sign-in app, with the #383 no-narrowing
  preconditions. It is created by the apply; the kit imports it on a later
  run.

The known host and the owner decisions (both callbacks, connector scopes,
mail via Exchange RBAC) close the five questions the earlier draft carried.

### Pre-apply check (run it first)

```sh
az ad app list --display-name "KB Prod" --query "[].appId" -o tsv
az ad app list --display-name "KB Prod Service" --query "[].appId" -o tsv
```

Both must print nothing. A hit belongs to someone else: STOP and adopt it with
import blocks instead of creating a duplicate.

### Owner steps

1. Generate the service keypair locally (RSA 2048, ≤ 24 months). Only the
   PUBLIC half goes to Terraform; the combined PEM goes to the vault:

   ```sh
   umask 077
   mkdir -p "$HOME/keys" && cd "$HOME/keys"
   openssl req -x509 -newkey rsa:2048 -nodes \
     -keyout kb-prod-key.pem -out kb-prod-cert.pem \
     -days 730 -subj '/CN=KB Prod Service'
   # ORDER MATTERS: private key (PKCS#8) FIRST, then the certificate — the
   # order values/kb/prod.secrets.yaml mounts the file in.
   cat kb-prod-key.pem kb-prod-cert.pem > kb-prod-combined.pem
   grep -c "PRIVATE KEY" kb-prod-cert.pem   # must print 0
   export TF_VAR_kb_prod_service_certificate="$(cat "$HOME/keys/kb-prod-cert.pem")"
   ```

2. `tofu plan` with the full variable set. Go/no-go, exactly: **6 to add,
   0 to change, 0 to destroy** — 1 sign-in application ("KB Prod"), 1 service
   principal, 1 service application ("KB Prod Service"), 1 certificate
   credential, 1 service principal, 1 tenant-wide delegated grant. Without
   `TF_VAR_kb_prod_service_certificate` the precondition on the sign-in app
   stops the plan: no partial shape is possible.

3. `tofu apply`, then record the outputs:
   `tofu output -json kb_prod_client_ids` (gitops placeholders
   `<KB_PROD_CLIENT_ID>` = `signin`, `<KB_PROD_SERVICE_APP_ID>` = `service`)
   and `tofu output -json kb_prod_object_ids` (the steps below).

4. **Sign-in client secret** — never in state, ≤ 6 months, straight into the
   vault under the name `values/kb/prod.secrets.yaml` reads. KB names it
   `microsoft-client-secret`, not `entra-client-secret` like rova/opshub:

   ```sh
   ./scripts/rotate-signin-secret.sh \
     "$(tofu output -json kb_prod_client_ids | jq -r .signin)" \
     kv-qnsc-prod kb-prod-microsoft-client-secret
   ```

5. **Service certificate** — combined PEM into the vault; ESO mounts it
   worker-only at `AZURE_CLIENT_CERTIFICATE_PATH`:

   ```sh
   az keyvault secret set --vault-name kv-qnsc-prod \
     --name kb-prod-graph-cert \
     --file "$HOME/keys/kb-prod-combined.pem" \
     --tags owner=platform rotate-by=2028-11-05
   ```

6. **Admin consent** for the delegated grant: created tenant-wide by
   Terraform (AllPrincipals), so there is nothing to consent by hand. The
   service app's Graph set is intentionally empty.

7. **The rest of the prod secret bundle** — generated/asked by the bootstrap
   script (DB passwords, redis URL, gemini key, R2 pair, the client secret it
   finds already set is skipped):

   ```sh
   gitops/platform/bootstrap/secrets.sh --product kb --env prod \
     --vault-app kv-qnsc-prod --skip-site
   ```

8. **R2 token** — one bucket, one token pair (see "KB prod R2" below).

9. **Exchange RBAC** — after this apply, run the merged infra#340 script at
   least a day before cutover (RBAC propagation):

   ```powershell
   ./exchange-prod-mail.ps1 -TenantId dc0f2078-… -Product kb `
     -ServiceAppId <kb_prod_client_ids.service> `
     -ServiceObjectId <kb_prod_object_ids.service_sp> `
     -ControlMailbox noreply-kb-dev@qnsc.vn
   ```

   Creates `noreply-kb@qnsc.vn`, the `noreply-kb` scope and
   `Application Mail.Send` for "KB Prod Service". The proof table must read
   `True` for its own mailbox and `False` everywhere else.

10. **Group access** — the `kb.qnsc.vn` host is gated at the EDGE by
    `grp-qnsc-staff` (`grp_staff_id` output → repo variable
    `ENTRA_GRP_STAFF_ID` → live/edge), not in this stack.

### KB prod R2

Confirmed against `live/storage-prod` and `values/kb/prod.secrets.yaml`:

| Item | Value |
| --- | --- |
| Bucket | `qnsc-kb-prod-sources` (ONE bucket; the module `qnsc_kb_sources`, outputs `qnsc_kb_sources_name` / `_endpoint`) |
| Token secret names | `kb-prod-r2-access-key-id`, `kb-prod-r2-secret-access-key` |
| Scope | The two above, `kv-qnsc-prod`, **scoped to that bucket only**, object read+write; no CORS, no custom domain (uploads are server-side) |
| Bucket state | `cd infra/live/storage-prod && tofu state list \| grep qnsc_kb_sources` must show the module; if absent, apply that stack first |

Backups do NOT use a kb-specific token: `platform/kb-prod/pg-kb-backup.yaml`
(gitops#255) reads the shared `r2-backup-rw-*` pair for bucket
`qnsc-backups`, destination `pg-kb/pg-kb-g1`.

### KB prod Key Vault wiring (`kb-prod-*`)

| Secret | Written by |
| --- | --- |
| `kb-prod-microsoft-client-secret` | step 4 (this README) |
| `kb-prod-graph-cert` | step 5 (this README) |
| `kb-prod-secret-key`, `-data-encryption-key`, `-gemini-api-key` | `secrets.sh` (step 7) |
| `kb-prod-r2-access-key-id`, `-r2-secret-access-key` | R2 token (step 8) |
| `kb-prod-db-app`, `-db-migrator`, `-db-readonly`, `-redis-url` | `secrets.sh` / pg-kb provisioning (step 7) |


## Prod mail readiness: the rova prod fast-track checklist

For the rova prod move (fast track, 2026-11-01). Everything below already
exists in code (`mail.tf`, `scripts/owner/mail-prod-tenant/`); this section is
the ordered owner run and the one variable table. Nothing here is applied by CI.

**What is scoped to what.** The Entra app "Rova Prod Service" is certificate-only
and holds NO `Mail.Send` in Entra. Mail permission is Exchange RBAC for
Applications: management scope `noreply-rova` (recipient filter = the mailbox
`noreply-rova@qnsc.vn`) plus an `Application Mail.Send` role assignment on the
app's service principal limited to that scope. This is the supported successor
of the legacy "application access policy"; `exchange-prod-mail.ps1` creates both
and proves that other mailboxes are out of scope. The one Graph application
permission on the app is `User.Invite.All` (guest invite), admin-consented by
the owner.

### Owner steps, in order

1. **The registration "Rova Prod Service" already exists** (hand-made 2026-11-01,
   single tenant, no redirect URI, no secret, certificate attached, `User.Invite.All`
   consented). Nothing to create; it is imported.
2. **Export** the live shape and build the variables: "Mail service apps"
   steps 2 and 3 above, plus the sign-in export in "Sign-in apps" step 1.
3. **No new keypair**: the app already has its certificate. Extract the public
   half from the vault (mail step 3) for `TF_VAR_mail_service_certificates`.
4. **`tofu plan`** with the full variable set below. The go/no-go is the ONE
   canonical list in "Mail service apps" step 4 (the mail side); `proxmox.tf`
   and the sign-in apps have their own sections. Do not re-derive a second
   count here. Any "must be replaced" is a STOP.
5. **`tofu apply`** (owner, local, `--profile`/`az login` as in "First apply").
6. **Admin consent** for `User.Invite.All`:
   `az ad app permission admin-consent --id <rova prod service app id>`.
7. **Key Vault certificate**: nothing to write. `kv-qnsc-prod/rova-prod-graph-cert`
   already holds the combined PEM; the apply only registers its public half in
   Entra by import. The on-prem worker reads the secret through ESO from
   `kv-qnsc-prod`; ESO authenticates with its own store credential (see "Phase 1"
   and the workload-identity PR), unrelated to this secret.
8. **Exchange** (PowerShell 7, ExchangeOnlineManagement, Exchange admin role):
   run `scripts/owner/mail-prod-tenant/exchange-prod-mail.ps1` exactly as in its
   README step 2. The run FAILS unless the own mailbox is in scope and the
   `-ControlMailbox noreply-rova-dev@qnsc.vn` is out of scope. Allow up to an
   hour for propagation and re-run before debugging.
9. **Record** `tofu output mail_service_client_ids` (rova_prod) as rova's Graph
   client id; smoke with `pnpm exec platform-mail-check` from the rova repo
   (send OK to its own mailbox, 403 to the others).
10. After a real prod invitation arrived: `-Step RemoveSignInRole` (dry run first).

### Full `TF_VAR_*` list for the next apply

Every plan and apply of this stack needs ALL of these. The repo records the
source of values only where noted; names of 1Password items other than the mail
certificates are not recorded in this repo (and tenant details belong in
product-docs), so the owner reads the rest from Entra or `az` as shown.

| Variable | Value | Where the owner reads it |
| --- | --- | --- |
| `TF_VAR_subscription_id` (+ `ARM_SUBSCRIPTION_ID`) | subscription GUID | `az account show --query id -o tsv` |
| `TF_VAR_budget_period_start` / `_end` | RFC3339 UTC | `az consumption budget list`, the live budget (README "First apply" step 3) |
| `TF_VAR_break_glass_upn_domain` | tenant primary domain | Entra admin center, Overview, Primary domain |
| `TF_VAR_office_ip` | office /32, optional (empty disables allowlists) | GitHub repo variable `TF_VAR_office_ip` |
| `TF_VAR_grp_platform_admins_object_id` | group object id (import) | `az ad group show --group grp-qnsc-platform-admins --query id -o tsv` |
| `TF_VAR_grp_developers_object_id` | group object id (import) | `az ad group show --group grp-qnsc-developers --query id -o tsv` |
| `TF_VAR_existing_object_ids` | JSON, 4 sign-in app object ids | `*-app.json` `.id` from the sign-in export |
| `TF_VAR_existing_sp_object_ids` | JSON, 4 sign-in SP object ids | `*-sp.json` `.id` from the sign-in export |
| `TF_VAR_existing_identifier_uris` | JSON map; default `{}` | sign-in export shows none; leave default |
| `TF_VAR_opshub_dev_app_role_ids` | JSON, 7 role GUIDs | `opshub-dev-app.json` `.appRoles[].id` |
| `TF_VAR_owner_operator_object_id` | user object id | Entra, Users, the owner, Object ID |
| `TF_VAR_second_owner_object_id` | user object id | Entra, Users, the second owner, Object ID |
| `TF_VAR_proxmox_redirect_uris` | JSON list, one `https://<host>/` per door (trailing slash) | the PVE and PBS admin hosts (product-docs) |
| `TF_VAR_platform_admin_object_ids` | JSON list of user object ids | the platform admins' object ids (Proxmox app + OpsHub Admin role); keep equal to the platform admins group |
| `TF_VAR_mail_service_object_ids` | JSON, 4 service app object ids | mail export `*-app.json` `.id` |
| `TF_VAR_mail_service_sp_object_ids` | JSON, 4 service SP object ids | mail export `*-sp.json` `.id` |
| `TF_VAR_mail_service_certificates` | JSON, 4 PEM public certs (the pinned primary of each app) | dev: 1Password "Entra mail cert – <product>-dev – certificate"; rova_prod: `az keyvault secret show ... | openssl x509` (mail step 3) |
| `TF_VAR_mail_service_rotated_certificates` | JSON map `{keyId: PEM}`, REQUIRED, no default | built by the kit from Entra `keyCredentials`; today one entry: KB Dev's 2026-11-04 credential. Keyed by the keyIds pinned in `mail.tf`, never hand-built |
| `TF_VAR_mail_service_graph_grant_ids` | JSON map `{"<slot>/<role>": <assignment id>}`, REQUIRED, no default | built by the kit from each service app's live `appRoleAssignments` (README "Graph permission grants") |
| `TF_VAR_signin_delegated_grant_ids` | JSON map `{<slot>: <grant id>}`, optional (default `{}`) | built by the kit from each sign-in app's live AllPrincipals `oauth2PermissionGrants`; absent apps plan a create |
| `TF_VAR_signin_delegated_grant_scopes` | JSON map `{<slot>: [<scope>...]}`, optional (default `{}`) | built by the kit from the same live grants; a live scope missing from the derived set fails the plan |
| `TF_VAR_opshub_prod_service_graph_grant_ids` | JSON map `{<role>: <assignment id>}`, REQUIRED, no default | built by the kit from "OpsHub Prod Service" `appRoleAssignments` |
| `TF_VAR_opshub_prod_service_certificate` | PEM PUBLIC cert (one string), optional | `$HOME/keys/opshub-prod-cert.pem` from "Prod identity: OpsHub" step 1. Unset = the prod service app is not created (and the app's precondition stops the plan) |
| `TF_VAR_kb_prod_service_certificate` | PEM PUBLIC cert (one string), optional | `$HOME/keys/kb-prod-cert.pem` from "Prod identity: KB" step 1. Unset = the whole KB prod pair is refused (precondition) |

The `existing_*` and `mail_service_*` ids are public identifiers, not secrets,
and can be read with read-only `az ad app list|show` / `az ad sp show`.
