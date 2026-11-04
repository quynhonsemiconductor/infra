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
NO opshub/kb PROD apps in this section: opshub prod's service app is CREATED
in `prod_apps.tf` (below); kb prod's service app comes with its own prod PR,
after its hostnames and permissions are decided. rova_prod carries the ONE Graph permission
the plan gives the rova Service app — tenant-wide guest invite
(`User.Invite.All`, §7.3/H-D14, backlog P0-7), admin-consented on apply; the
rova SIGN-IN apps keep NO application permissions of their own (the dev
sign-in apps still hold `User.Invite.All` today until rova's P0-7 code moves
the invite to the Service cert — a rova-track change, not this stack's).

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
   - `TF_VAR_mail_service_cert_key_ids` — the four `keyId`s (each app has exactly
     one certificate credential; the check below fails otherwise):

     ```sh
     for f in rova-prod rova-dev opshub-dev kb-dev; do
       n=$(jq '.keyCredentials|length' "$f-service-app.json")
       [ "$n" = "1" ] || echo "STOP: $f-service-app.json has $n key credentials, expected 1"
     done
     jq -n \
       --slurpfile p rova-prod-service-app.json \
       --slurpfile a rova-dev-service-app.json \
       --slurpfile b opshub-dev-service-app.json \
       --slurpfile c kb-dev-service-app.json \
       '{rova_prod:$p[0].keyCredentials[0].keyId, rova_dev:$a[0].keyCredentials[0].keyId, opshub_dev:$b[0].keyCredentials[0].keyId, kb_dev:$c[0].keyCredentials[0].keyId}'
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
   imports** (rova_prod and the three dev certs) — and at most ONE application
   update, on rova_prod only: the wizard-default delegated `User.Read` REMOVED
   and/or the `User.Invite.All` application role ADDED, whichever the export
   shows is not yet in line (the role is already consented on the live app, so
   the plan may show no permission line at all). NO certificate create. A
   plan that creates a certificate means `rova_prod` is missing from
   `mail_service_cert_key_ids`: STOP.
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

Rotation (dev certs expire 2027-10-18, rova_prod ≤ 24 months): new keypair →
`tofu apply` the new public cert (`create_before_destroy` — the new credential
exists before the old is removed) → write the new combined PEM to the vault
(step 5). Between apply and the PEM swap the worker's OLD certificate still
authenticates — no gap.


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

  App roles cannot be imported by a single block: repeat
  `to = azuread_application_app_role.opshub_prod["<key>"]` with
  `id = "<sign-in app OBJECT id>/appRole/<role id>"` for each of the seven.
  The existing role ids must EQUAL the derived ones
  (`tofu output -json opshub_prod_object_ids | jq .signin_app_roles`); if they
  differ, STOP — adopting them is a reviewed code change (a var like the dev
  `opshub_dev_app_role_ids`), not an import.

  The gitops comment that says the service app's certificate is "already in
  kv-qnsc-prod from the AWS-exit copy-out" (`values/opshub/prod.secrets.yaml`,
  the `opshub-prod-graph-cert` rule) is stale: this runbook creates and
  writes it. The gitops owner is correcting that comment; the README is the
  source of truth until then.

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
     "$(tofu output -json opshub_prod_object_ids | jq -r .signin_app)" \
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

### KB prod — open questions (no resources until decided)

KB dev's apps tell us the shape but not the prod addresses:

1. **Sign-in redirects**: dev has two on the `kb-api-dev` host
   (`/api/v1/auth/entra/callback` and `/api/v1/connectors/oauth/callback`)
   plus their localhost forms. What are the PROD host names? They are not in
   live/edge or gitops yet, so they are deliberately not written here.
2. **OAuth connector**: do the `/api/v1/connectors/oauth/callback` redirect
   and the delegated `Files.Read`, `Files.Read.All`, `Sites.Read.All` scopes
   ship in prod? Dev has them.
3. **Mail**: the KB dev service app holds NO Graph application roles. If kb
   prod sends mail, the only requirement is the owner's Exchange RBAC
   (`Application Mail.Send` scoped to `noreply-kb@qnsc.vn`) — no Entra role.
   Confirm whether kb prod mail is in scope for P3.
4. **Service certificate / KV names**: same create pattern as opshub (public
   PEM in, combined PEM to `kv-qnsc-prod/kb-prod-graph-cert` once the name is
   confirmed against `values/kb/prod.secrets.yaml`).
5. **Optional id-token claims**: dev has none (`email` is not in its scopes
   either); keep none unless KB asks for `preferred_username`.

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
4. **`tofu plan`** with the full variable set below. Mail go/no-go: 8 imports
   (apps + SPs), 4 certificate imports, at most 1 application update (rova_prod,
   see step 4 above), no certificate create, nothing replaced. This stack also carries `proxmox.tf` and the sign-in apps: read
   their sections for their expected lines. Any "must be replaced" is a STOP.
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
| `TF_VAR_platform_admins_object_id` | group object id | `az ad group show --group grp-qnsc-platform-admins --query id -o tsv` |
| `TF_VAR_existing_object_ids` | JSON, 4 sign-in app object ids | `*-app.json` `.id` from the sign-in export |
| `TF_VAR_existing_sp_object_ids` | JSON, 4 sign-in SP object ids | `*-sp.json` `.id` from the sign-in export |
| `TF_VAR_existing_identifier_uris` | JSON map; default `{}` | sign-in export shows none; leave default |
| `TF_VAR_opshub_dev_app_role_ids` | JSON, 7 role GUIDs | `opshub-dev-app.json` `.appRoles[].id` |
| `TF_VAR_owner_operator_object_id` | user object id | Entra, Users, the owner, Object ID |
| `TF_VAR_second_owner_object_id` | user object id | Entra, Users, the second owner, Object ID |
| `TF_VAR_proxmox_redirect_uris` | JSON list, `https://<host>/` (trailing slash) | the Proxmox realm host (product-docs) |
| `TF_VAR_proxmox_admin_object_ids` | JSON list of user object ids | Entra, Users, Object ID; keep equal to the platform admins group |
| `TF_VAR_mail_service_object_ids` | JSON, 4 service app object ids | mail export `*-app.json` `.id` |
| `TF_VAR_mail_service_sp_object_ids` | JSON, 4 service SP object ids | mail export `*-sp.json` `.id` |
| `TF_VAR_mail_service_cert_key_ids` | JSON, 4 key GUIDs (rova_prod included) | `.keyCredentials[0].keyId` of each service app export |
| `TF_VAR_mail_service_certificates` | JSON, 4 PEM public certs | dev: 1Password "Entra mail cert – <product>-dev – certificate"; rova_prod: `az keyvault secret show ... | openssl x509` (mail step 3) |
| `TF_VAR_opshub_prod_service_certificate` | PEM PUBLIC cert (one string), optional | `$HOME/keys/opshub-prod-cert.pem` from "Prod identity: OpsHub" step 1. Unset = the prod service app is not created |

The `existing_*` and `mail_service_*` ids are public identifiers, not secrets,
and can be read with read-only `az ad app list|show` / `az ad sp show`.
