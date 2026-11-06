# identity-env: owner apply kit for live/identity

Builds every `TF_VAR_*` of `live/identity` that has no default from read-only `az` lookups (no value typed,
none in Git, none printed). Owner's own terminal only: `az login` done.

```sh
export IDENTITY_SECOND_OWNER_UPN='<second owner UPN>'
# redirect URI https://<host>/ is registered for each admin door
export IDENTITY_PROXMOX_HOST='<Proxmox VE admin host>'
export IDENTITY_PBS_HOST='<Proxmox Backup Server admin host>'
# optional: extra owners for DEV sign-in apps only, comma-separated app=MemberUPN
export IDENTITY_DEV_APP_EXTRA_OWNERS='opshub_dev=<developer UPN>'
scripts/owner/identity-env/identity-env.sh                            # names + lengths only
scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan   # runs in live/identity, env only in the child
```

All three of the first are required: both admin doors are registered on the ONE "QNSC Proxmox" app (runbook
server-setup §3.2.1), so a missing `IDENTITY_PBS_HOST` stops the kit before any plan. Each value is a bare
hostname; the kit builds `TF_VAR_proxmox_redirect_uris` with the trailing slash azuread 3.10 requires.

`IDENTITY_DEV_APP_EXTRA_OWNERS` is optional. It resolves each UPN to a **Member** user and builds
`TF_VAR_dev_app_extra_owner_object_ids` (keys limited to `rova_dev`, `opshub_dev`, `kb_dev`; prod keys stop the
kit). Unset = empty map. An app owner can add client credentials and redirect URIs, so extras are DEV-only.

`tfplan` / `*.tfplan` are git-ignored (root `.gitignore`) but a plan file holds the values: delete it after the apply (`rm live/identity/tfplan`).

It stops (never guesses) on an empty lookup, a duplicate app name, a non-GUID id, an app-role set other than the
seven OpsHub roles, a mail certificate whose thumbprint differs from the one live on the app, a private key
anywhere, a credential without a `startDateTime`, a credential the stack does not pin, or a pinned credential that
is not on the app. Every mail certificate's PUBLIC part is read from the Entra app itself (Graph
`keyCredentials[].key` on `$select`); the kit never reads Key Vault or 1Password.

The credential keyIds are **pinned in `live/identity/mail.tf`** (`local.mail_service_cert_key_ids` and
`local.mail_service_rotated_cert_key_ids`), never derived and never supplied by a variable: a missing value there
would empty a resource's `for_each` and destroy a live credential. The kit parses those two blocks (two-space
indent, one entry per line — keep the shape), asserts them against Entra, and exports only the PEM maps
(`TF_VAR_mail_service_certificates`, `TF_VAR_mail_service_rotated_certificates`, keyed by the pinned keyIds). The
one identifier it ever prints is the keyId of an unpinned live credential, so the owner can pin it.

It also builds `TF_VAR_cf_access_object_ids` — the app, service-principal and AllPrincipals grant ids of
"QNSC Cloudflare Access" — so `cf_access.tf` can import the IdP without any id in Git. The app's credential is
never read: only ids and the grant's scope list (which must not be narrowed).

The kit also builds the grant import maps `TF_VAR_mail_service_graph_grant_ids` and
`TF_VAR_opshub_prod_service_graph_grant_ids` from each app's live `appRoleAssignments` on Microsoft Graph
(`appRoleAssignedTo` is the other direction and would return nothing useful). The sign-in apps' tenant-wide
consent comes from one `oauth2PermissionGrants` lookup per app, which yields both
`TF_VAR_signin_delegated_grant_ids` and `TF_VAR_signin_delegated_grant_scopes` (the live scope lists the plan
must never narrow). `eso_certificates` is built the same
way, from the certificate live on each ESO app (a stale file would plan a replace), only while the stack still
declares it. Test (offline, runs in the `Infrastructure · Plan` lint job):
`bash scripts/owner/identity-env/test_identity_env.sh`.
