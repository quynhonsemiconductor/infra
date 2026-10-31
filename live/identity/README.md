# live/identity

Entra ID + Azure Key Vault for the whole platform, plus the two CI workload
identities (§7.4). **This stack is applied ONLY by the owner, locally, with
their own `az login` — every plan and every apply, not just the first.** CI
neither plans nor applies it. The repository is public, and plan output (PR
comments, Actions logs) would publish the break-glass UPNs and the Entra role
layout, so the owner runs `tofu plan` and `tofu apply` locally. An identity
able to apply this stack could grant itself any role in the tenant, so no CI
identity is given that ability.

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

2. Export the group id (an identifier, not a credential — it is
   operator-supplied all the same, so it is never committed):

   ```sh
   export TF_VAR_platform_admins_object_id=$(
     az ad group show --group grp-qnsc-platform-admins --query id -o tsv)
   ```

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

Three files carry the issuer and must agree (the static guard fails on drift):
this variable, `live/onprem-oidc` (the published OIDC documents) and
`live/onprem-vm/files/k3s/config.yaml` (what k3s signs tokens with).

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
4. **k3s issuer (owner, on the node).** Add the two `service-account-issuer`
   lines to `/etc/rancher/k3s/config.yaml` — the new URL FIRST (that is the
   one k3s signs with) and the old default SECOND (accepted, never issued) —
   then `systemctl restart k3s`. Verify with a token from an EXISTING service
   account (the ESO SAs do not exist until step 5):

   ```sh
   kubectl -n external-secrets create token default --audience api://AzureADTokenExchange \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.iss, .sub, .aud'
   # must print https://oidc.qnsc.vn/k3s-onprem,
   # system:serviceaccount:external-secrets:default and the audience
   ```

   Then confirm ArgoCD and the CNPG clusters are healthy — tokens minted
   before the restart carry the OLD issuer and are accepted only because the
   old value is still in the list.
5. **gitops (D).** `platform/eso/stores-onprem.yaml` switches each store from
   `authType: ServicePrincipal` to `WorkloadIdentity` and adds the three
   ServiceAccounts (annotated `azure.workload.identity/client-id`). Prove all
   three stores `Valid` and an ExternalSecret syncing.
6. **Delete the `*-cert` Secrets** in `external-secrets`, then merge + apply
   **this PR** (the certificate removal): `azuread_application_certificate.eso`,
   `var.eso_certificates` and the openssl steps go. Expected plan: 3 to
   destroy, 0 to add. Only now is the secret gone. Never merge it before step
   5 reports every store `Valid` on `WorkloadIdentity`.
7. **`live/onprem-vm`** only after its rework, with VM 100 planning **no
   changes**.

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

1. Rotate so `service.key` holds the NEW key **after** the old one (k3s
   accepts several; the API server publishes all of them in its JWKS).
2. `kubectl get --raw /openid/v1/jwks` — the response now lists both keys.
3. `TF_VAR_k3s_jwks=... tofu apply` in `live/onprem-oidc`. Old and new tokens
   both validate; nothing breaks.
4. After the longest token lifetime has passed, drop the old key from
   `service.key`, restart k3s, re-publish (steps 2–3 again).

Publishing both keys in step 3 is what makes the rotation uninterrupted; a
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
   verbatim from the 2026-10-27 export (admin: `Admin`,
   `["User", "Application"]`; auditor: `Auditor`; the rest `["User"]`). If a
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

## Proxmox login (`proxmox.tf`): app "QNSC Proxmox", plan, secret

Adds the Entra half of Proxmox's OpenID realm; the Proxmox half is the
platform runbook (server-setup §3.2.1, product-docs, private). The tenant has
NO Entra ID P1, so group-based app assignment and `ApplicationGroup` claims
are unavailable: the admin USERS are assigned directly and the ID token
carries security-group object ids (`SecurityGroup`).

**Adding or removing an admin = edit `TF_VAR_proxmox_admin_object_ids` (and
re-apply) AND the Entra group `grp-qnsc-platform-admins` (Cloudflare Access
and the Proxmox ACL key on it).** Keep the two in step.

1. Export the two new variables on top of the existing ones (the Proxmox
   origin is an admin-door hostname, so it stays out of the repo):

   ```sh
   export TF_VAR_proxmox_redirect_uris='["https://<proxmox-host>/"]'   # trailing slash REQUIRED (azuread 3.10)
   export TF_VAR_proxmox_admin_object_ids='["<user-object-id>", "<user-object-id>"]'
   ```

   pve-manager sends `location.origin` (no slash) and Entra normalises the
   root. The FIRST login must confirm there is no `AADSTS50011` (redirect URI
   mismatch); if there is, STOP and tell the SA.
2. Plan and apply as in the sections above, locally. Expected: **adds only**:
   `azuread_application.proxmox`, `azuread_service_principal.proxmox`, one
   `azuread_app_role_assignment.proxmox_admins[...]` per listed user, and
   `azuread_service_principal_delegated_permission_grant.proxmox`; 0 to change,
   0 to destroy, 0 to replace; two new outputs. ANY change or destroy on an
   existing resource is NO-GO: stop and reconcile in a reviewed PR.
3. Record `proxmox_oidc_client_id` and `proxmox_oidc_issuer_url` from the
   outputs (the runbook needs them). Neither is a secret.
4. Create the client secret OUT OF BAND (never in state; same shape as
   `scripts/rotate-signin-secret.sh`) straight into the admin vault, nothing
   printed, 6 months (sign-in app policy), then set a calendar reminder to
   rotate. The new credential's `keyId` goes to stderr so an orphaned
   credential can be revoked if the vault write fails:

   ```sh
   new=$(az ad app credential reset --id <proxmox_oidc_client_id> --append \
     --display-name "rotated-$(date -u +%F)" \
     --end-date "$(date -v+6m +%Y-%m-%dT00:00:00Z)" --only-show-errors -o json)
   printf '%s\n' "$new" | jq -ej '.keyId' |
     xargs printf 'new credential keyId %s — revoke this if the run fails below\n' >&2
   printf '%s\n' "$new" | jq -ej '.password' \
   | az keyvault secret set --vault-name kv-qnsc-admin \
       --name admin-proxmox-oidc-secret --file /dev/stdin \
       --content-type text/plain \
       --expires "$(date -v+6m +%Y-%m-%dT00:00:00Z)" \
       --tags owner=platform "rotated=$(date -u +%Y-%m-%d)" -o none
   unset new
   ```

## Mail service apps (`mail.tf`): owner export, plan, go/no-go

One certificate-only Service app per product per env, `<Product> <Env> Service`
(§7.3): **rova prod** (hand-create the registration FIRST — step 1; the client
id it gets is what rova records as its Graph client id) plus the three
**existing dev service apps** (live since 2026-10-18) — all ADOPTED via import.
NO opshub/kb PROD apps: those products are not live in prod; their service
apps come with their own prod PRs.

1. Hand-create the ONE missing registration (skip the ones already live;
   the export loop in step 2 refuses a name that matches 0 or > 1 apps):
   "Rova Prod Service" — single tenant, no redirect URI, no client secret,
   notes = repo link. Then remove the default delegated `User.Read` entry if
   the new-registration wizard added one (the code models NO Graph permission
   for rova and re-removing it here is an intended change; see step 4).

2. Export the live shape (exact-name filter — NOT `--display-name`, a prefix
   match; each name must match exactly one app):

   ```sh
   mkdir -p ~/mail-export && cd ~/mail-export
   for app in "Rova Prod Service" "Rova Dev Service" "OpsHub Dev Service" "KB Dev Service"; do
     n=$(az ad app list --filter "displayName eq '$app'" --query 'length(@)' -o tsv)
     [ "$n" = "1" ] || { echo "expected exactly 1 app named '$app', got $n — STOP"; exit 1; }
     app_id=$(az ad app list --filter "displayName eq '$app'" --query '[0].appId' -o tsv)
     slug=$(echo "$app" | tr ' ' '-' | tr 'A-Z' 'a-z')
     az ad app show --id "$app_id" > "$slug-app.json"
     az ad sp show  --id "$app_id" > "$slug-sp.json"
   done
   ```

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
   - `TF_VAR_mail_service_certificates` — one PEM PUBLIC certificate per app
     (same keys). Generate locally, one RSA 2048 keypair per app, ≤ 24 months,
     keys stay outside iCloud-synced folders:
     `openssl req -x509 -newkey rsa:2048 -nodes -days 730 -keyout <key>
     -out <crt> -subj "/CN=qnsc-<product>-<env>-mail"`. Pass only the `crt`
     PEMs; a private key fails the variable validation. THE KEY FILES ARE THE
     SOURCE OF THE VAULT SECRETS in step 5 — do not delete them before then.

4. `tofu plan` go/no-go — expected: **8 imports** (4 applications + 4 service
   principals) + **4 `azuread_application_certificate` creates** and NOTHING
   else. The ONE named in-place change: the rova apps lose a default delegated
   `User.Read` entry if the export shows one (rova Service apps model NO Graph
   permission). Anything else on an imported app — a permission add or
   removal, a redirect URI, a secret credential — is NO-GO: STOP, export
   again, reconcile in a reviewed commit first. (opshub's five application
   roles are in the code; if the export shows a different set on the live
   OpsHub Dev Service app, STOP and reconcile the list in `mail.tf` first.)

5. After apply: record `mail_service_client_ids` (rova_prod's is the value
   rova's Graph config records; the dev values land in the dev bundles).
   Then write the combined PEM per app into its vault — the FILE path is the
   argv, the value never is:

   ```sh
   cat rova-prod.key rova-prod.crt > /tmp/rova-prod-combined.pem && chmod 600 /tmp/rova-prod-combined.pem
   az keyvault secret set --vault-name kv-qnsc-prod --name rova-prod-graph-cert --file /tmp/rova-prod-combined.pem
   # dev, same shape: kv-qnsc-dev, names rova-dev-graph-cert / opshub-dev-graph-cert / kb-dev-graph-cert
   rm /tmp/rova-prod-combined.pem   # after the vault holds it
   ```

   The worker reads them as `AZURE_CLIENT_CERTIFICATE_PATH` (§7.3 — one
   credential mechanism). Exchange-side RBAC (mailbox, scope,
   `Application Mail.Send`) stays in `scripts/owner/mail-prod-tenant/`.

Rotation (≤ 24 months): new keypair → `tofu apply` the new public cert
(`create_before_destroy` — the new credential exists before the old is
removed) → write the new combined PEM to the vault (step 5). Between apply
and the PEM swap the worker's OLD certificate still authenticates — no gap.
## Mail service apps (`mail.tf`): owner export, plan, go/no-go

One certificate-only Service app per product per env, `<Product> <Env> Service`
(§7.3): **rova prod** (hand-create the registration FIRST — step 1) plus the
three **existing dev service apps** (live since 2026-10-18) — all ADOPTED via
import. The **dev certificates are adopted too** (SA decision — no rotation):
imported by `<app object id>/certificate/<keyId>`, value = the exact public
certificate already in 1Password ("Entra mail cert – <product>-dev –
certificate"). Only **rova_prod's certificate is created** (new keypair).
Import id form (azuread 3.10 parser): EXACTLY
`<app OBJECT id>/certificate/<keyId>` — no `/applications/` prefix.
NO opshub/kb PROD apps: those products are not live in prod; their service
apps come with their own prod PRs. rova_prod carries the ONE Graph permission
the plan gives the rova Service app — tenant-wide guest invite
(`User.Invite.All`, §7.3/H-D14, backlog P0-7), admin-consented on apply; the
rova SIGN-IN apps keep NO application permissions of their own (the dev
sign-in apps still hold `User.Invite.All` today until rova's P0-7 code moves
the invite to the Service cert — a rova-track change, not this stack's).

1. Hand-create the ONE missing registration (skip the ones already live;
   the export loop in step 2 refuses a name that matches 0 or > 1 apps):
   "Rova Prod Service" — single tenant, no redirect URI, no client secret,
   notes = `github.com/quynhonsemiconductor/rova`. If the wizard added a
   default delegated `User.Read`, leave it: the code models NO delegated
   permission for rova, so the plan REMOVING it is an intended, named change
   (step 4).

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

   From the dev exports also read `keyCredentials[0].keyId` (the
   `mail_service_cert_key_ids` values) and confirm each dev app's
   `requiredResourceAccess` shows exactly the three opshub roles / none for
   rova and kb. Watch list (same as the sign-in apps, suppressed identically):
   SP `tags` (`HideApp`, …) and `api.requestedAccessTokenVersion` (live
   `null`) are provider-computed — never hand-model them.

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
   - `TF_VAR_mail_service_cert_key_ids` — the three dev `keyId`s:

     ```sh
     jq -n \
       --slurpfile a rova-dev-service-app.json \
       --slurpfile b opshub-dev-service-app.json \
       --slurpfile c kb-dev-service-app.json \
       '{rova_dev:$a[0].keyCredentials[0].keyId, opshub_dev:$b[0].keyCredentials[0].keyId, kb_dev:$c[0].keyCredentials[0].keyId}'
     ```

   - `TF_VAR_mail_service_certificates` — one PEM PUBLIC certificate per app.
     Dev: the EXACT live certificates from 1Password ("Entra mail cert –
     <product>-dev – certificate") — different bytes would plan a certificate
     replacement, which is NO-GO. rova_prod: the owner's NEW keypair, made in
     a private temp dir:

     ```sh
     umask 077
     mkdir -p "$HOME/keys"
     keydir=$(mktemp -d "$HOME/keys/mail-rova-prod.XXXXXX")   # outside iCloud-synced folders
     openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
       -keyout "$keydir/rova-prod.key" -out "$keydir/rova-prod.crt" \
       -subj "/CN=qnsc-rova-prod-service"
     ```

     Build the JSON with `jq --rawfile` so multi-line PEMs stay intact
     (adjust the dev paths to wherever 1Password wrote them):

     ```sh
     jq -n \
       --rawfile rova_prod "$keydir/rova-prod.crt" \
       --rawfile rova_dev "$HOME/keys/rova-dev.crt" \
       --rawfile opshub_dev "$HOME/keys/opshub-dev.crt" \
       --rawfile kb_dev "$HOME/keys/kb-dev.crt" \
       '{rova_prod:$rova_prod, rova_dev:$rova_dev, opshub_dev:$opshub_dev, kb_dev:$kb_dev}'
     ```

     A private key in any value fails the variable validation. KEEP the key
     files — they are the source of the vault secrets in step 5.

4. `tofu plan` go/no-go — the plan must read EXACTLY: **8 imports** (4
   applications + 4 service principals) + **3 certificate imports** (the dev
   certs) + **1 certificate create** (rova_prod) + **1 application update**
   (the hand-created rova_prod app: the wizard-default delegated `User.Read`
   REMOVED, `User.Invite.All` (application role) ADDED) — nothing else.
   Any change on an imported app — a permission add or removal, a redirect
   URI, a secret credential — is NO-GO, and **any certificate showing
   "must be replaced" is STOP** (the dev certs are imported write-only; see
   the `mail.tf` resource comment). opshub_dev's three application roles are
   in the code; a different live set is STOP and reconcile `mail.tf` first.
   The `User.Invite.All` ADMIN CONSENT is a separate manual step right after
   apply (the plan only updates the app):

   ```sh
   az ad app permission admin-consent --id <rova_prod service app id>
   ```

5. After apply: record `mail_service_client_ids` (rova_prod's is the value
   rova's Graph config records; the dev values land in the dev bundles).
   Then write the combined PEM per app into its vault — the FILE path is the
   argv, the value never is. Dev combined PEMs already exist (1Password, key +
   cert — the pre-2026-10-18 shape); rova_prod's is built from the new
   keypair:

   ```sh
   pem=$(mktemp /tmp/rova-prod-combined.XXXXXX) && chmod 600 "$pem"
   cat "$keydir/rova-prod.key" "$keydir/rova-prod.crt" > "$pem"
   az keyvault secret set --vault-name kv-qnsc-prod --name rova-prod-graph-cert --file "$pem"
   rm -f "$pem"   # after the vault holds it
   # dev, same shape: kv-qnsc-dev, names rova-dev-graph-cert / opshub-dev-graph-cert / kb-dev-graph-cert
   ```

   The worker reads them as `AZURE_CLIENT_CERTIFICATE_PATH` (§7.3 — one
   credential mechanism). Exchange-side RBAC (mailbox, scope,
   `Application Mail.Send`) stays in `scripts/owner/mail-prod-tenant/`.

Rotation (dev certs expire 2027-10-18, rova_prod ≤ 24 months): new keypair →
`tofu apply` the new public cert (`create_before_destroy` — the new credential
exists before the old is removed) → write the new combined PEM to the vault
(step 5). Between apply and the PEM swap the worker's OLD certificate still
authenticates — no gap.
