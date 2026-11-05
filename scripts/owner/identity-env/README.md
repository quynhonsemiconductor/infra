# identity-env: owner apply kit for live/identity

Builds every `TF_VAR_*` of `live/identity` that has no default from read-only `az` lookups (no value typed,
none in Git, none printed). Owner's own terminal only: `az login` done.

```sh
export IDENTITY_SECOND_OWNER_UPN=<second owner UPN>
export IDENTITY_PROXMOX_HOST=<proxmox realm hostname>
scripts/owner/identity-env/identity-env.sh                            # names + lengths only
scripts/owner/identity-env/identity-env.sh -- tofu plan -out=tfplan   # runs in live/identity, env only in the child
```

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

The kit also builds the grant import maps `TF_VAR_mail_service_graph_grant_ids` and
`TF_VAR_opshub_prod_service_graph_grant_ids` from each app's live `appRoleAssignments` on Microsoft Graph
(`appRoleAssignedTo` is the other direction and would return nothing useful). The sign-in apps' tenant-wide
consent comes from one `oauth2PermissionGrants` lookup per app, which yields both
`TF_VAR_signin_delegated_grant_ids` and `TF_VAR_signin_delegated_grant_scopes` (the live scope lists the plan
must never narrow). `eso_certificates` is built the same
way, from the certificate live on each ESO app (a stale file would plan a replace), only while the stack still
declares it. Test (offline, runs in the `Infrastructure · Plan` lint job):
`bash scripts/owner/identity-env/test_identity_env.sh`.
