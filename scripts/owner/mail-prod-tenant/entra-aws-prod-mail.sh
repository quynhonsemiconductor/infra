#!/usr/bin/env bash
# Owner script, PROD tenant: Entra and AWS side of the Graph mail setup.
#
#   preflight  check tenant (az), AWS account (qnsc-admin) and that the cert dir is not under iCloud
#   certs      create one RSA 2048 certificate per product in ~/.qnsc-secrets/mail-certs (never overwrites)
#   entra      upload each .crt as a certificate credential (--append), add the five opshub
#              Graph application permissions, admin-consent them, assert rova/kb hold no app roles
#   secrets    write key+cert PEM to the prod standalone secrets (stdin, never argv)
#   check      run each product's own check tool against prod (one product or all)
#
# Run order: exchange-prod-mail.ps1 -Step Setup first (the Service apps need their Exchange role),
# then preflight, certs, entra, secrets, check. See README.md in this directory.
#
# Placeholders: ROVA_PROD_SERVICE_APP_ID, OPSHUB_PROD_SERVICE_APP_ID, KB_PROD_SERVICE_APP_ID must be
# exported to the real GUIDs (the owner creates the apps by hand). Placeholder values are refused.
#
# Nothing in this file has been executed against a tenant. Secret values and key material are never printed.
set -euo pipefail
umask 077

readonly TENANT_ID="dc0f2078-ac28-4ff2-b21a-d4b28df32361"
readonly AWS_ACCOUNT_ID="608983206583"
readonly GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
readonly CERT_DIR="${HOME}/.qnsc-secrets/mail-certs"
readonly -a OPSHUB_GRAPH_ROLES=(
  SecurityEvents.Read.All
  DeviceManagementManagedDevices.Read.All
  User.Read.All
  User.EnableDisableAccount.All
  User.RevokeSessions.All
)

PRODUCT=""
APP_ID=""
SECRET_NAME=""
KEY=""
CRT=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in az aws openssl python3; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
}

require_guid() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || die "$name is not set (export the real GUID from the Entra app registration)"
  [[ "$value" != "<"*">" ]] || die "$name is still a placeholder; export the real GUID"
  [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "$name is not a GUID"
}

# Refuse any path that iCloud Desktop & Documents sync could copy off the machine.
assert_not_icloud() {
  local real
  real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1")"
  case "$real" in
    "$HOME/Desktop" | "$HOME/Desktop"/* | "$HOME/Documents" | "$HOME/Documents"/* | "$HOME/Library/Mobile Documents"/*)
      die "refusing to use $real: it is under an iCloud-synced folder"
      ;;
  esac
}

# Sets PRODUCT, APP_ID, SECRET_NAME, KEY and CRT for one product.
product_setup() {
  PRODUCT="$1"
  case "$PRODUCT" in
    rova)
      require_guid ROVA_PROD_SERVICE_APP_ID "${ROVA_PROD_SERVICE_APP_ID:-}"
      APP_ID="$ROVA_PROD_SERVICE_APP_ID"
      SECRET_NAME="rova/production/mail-graph-certificate"
      ;;
    opshub)
      require_guid OPSHUB_PROD_SERVICE_APP_ID "${OPSHUB_PROD_SERVICE_APP_ID:-}"
      APP_ID="$OPSHUB_PROD_SERVICE_APP_ID"
      SECRET_NAME="opshub/production/graph-client-certificate"
      ;;
    kb)
      require_guid KB_PROD_SERVICE_APP_ID "${KB_PROD_SERVICE_APP_ID:-}"
      APP_ID="$KB_PROD_SERVICE_APP_ID"
      SECRET_NAME="qnsc-kb/production/mail-graph-certificate"
      ;;
    *)
      die "unknown product '$PRODUCT' (rova, opshub, kb)"
      ;;
  esac
  KEY="$CERT_DIR/$PRODUCT-prod.key"
  CRT="$CERT_DIR/$PRODUCT-prod.crt"
}

cmd_preflight() {
  require_tools
  assert_not_icloud "$CERT_DIR"

  local tenant account
  tenant="$(az account show --query tenantId -o tsv 2>/dev/null)" \
    || die "az is not signed in. Run: az login --tenant $TENANT_ID"
  [[ "$tenant" == "$TENANT_ID" ]] || die "az is on a different tenant; expected the PROD tenant $TENANT_ID. Run: az login --tenant $TENANT_ID"

  account="$(aws sts get-caller-identity --profile qnsc-admin --region ap-southeast-1 --query Account --output text)" \
    || die "AWS profile qnsc-admin does not work"
  [[ "$account" == "$AWS_ACCOUNT_ID" ]] || die "profile qnsc-admin is account $account, expected $AWS_ACCOUNT_ID"

  echo "preflight OK: az tenant and AWS account (qnsc-admin) match PROD; cert dir is not iCloud-synced"
}

cmd_certs() {
  require_tools
  assert_not_icloud "$CERT_DIR"
  mkdir -p "$CERT_DIR"
  chmod 700 "$(dirname "$CERT_DIR")" "$CERT_DIR"

  local p
  for p in rova opshub kb; do
    product_setup "$p"
    [[ ! -e "$KEY" && ! -e "$CRT" ]] || die "$p: key or certificate already exists in $CERT_DIR; move it aside to rotate"
    openssl req -x509 -newkey rsa:2048 -nodes -days 730 \
      -keyout "$KEY" -out "$CRT" -subj "/CN=qnsc-$p-prod-mail" >/dev/null 2>&1 \
      || die "$p: openssl failed"
    chmod 600 "$KEY" "$CRT"
    echo "$p: created $(basename "$KEY") and $(basename "$CRT") ($(openssl x509 -in "$CRT" -noout -enddate))"
  done
}

cmd_entra() {
  cmd_preflight

  local p cert_before cert_after secret_before secret_after
  for p in rova opshub kb; do
    product_setup "$p"
    [[ -f "$CRT" ]] || die "$p: $CRT is missing; run certs first"

    cert_before="$(az ad app show --id "$APP_ID" --query "length(keyCredentials)" -o tsv)"
    secret_before="$(az ad app show --id "$APP_ID" --query "length(passwordCredentials)" -o tsv)"
    # Only the public .crt is sent. --append keeps existing certificates. No secret is created.
    az ad app credential reset --id "$APP_ID" --cert "@$CRT" --append >/dev/null
    cert_after="$(az ad app show --id "$APP_ID" --query "length(keyCredentials)" -o tsv)"
    secret_after="$(az ad app show --id "$APP_ID" --query "length(passwordCredentials)" -o tsv)"
    echo "$p: certificate credentials before=$cert_before after=$cert_after; client secrets before=$secret_before after=$secret_after"
    [[ "$secret_before" == "$secret_after" ]] || die "$p: a client secret count changed; investigate before continuing"
  done

  # opshub prod: the five application permissions, resolved by name from Microsoft Graph's appRoles.
  product_setup opshub
  local role_value role_id
  local -a role_args=()
  for role_value in "${OPSHUB_GRAPH_ROLES[@]}"; do
    role_id="$(az ad sp show --id "$GRAPH_APP_ID" --query "appRoles[?value=='$role_value'] | [0].id" -o tsv)"
    [[ -n "$role_id" ]] || die "Graph app role $role_value not found"
    role_args+=("$role_id=Role")
  done
  az ad app permission add --id "$APP_ID" --api "$GRAPH_APP_ID" --api-permissions "${role_args[@]}" >/dev/null
  az ad app permission admin-consent --id "$APP_ID" >/dev/null
  echo "opshub: ${#OPSHUB_GRAPH_ROLES[@]} application permissions added and admin-consented"

  # Assert the application-permission count per app: opshub 5, rova 0, kb 0 (no Mail.* anywhere).
  local expected_roles role_count types
  for p in rova opshub kb; do
    product_setup "$p"
    types="$(az ad app show --id "$APP_ID" --query "requiredResourceAccess[].resourceAccess[].type" -o tsv)"
    role_count="$(printf '%s\n' "$types" | grep -c '^Role$' || true)"
    expected_roles=0
    if [[ "$p" == "opshub" ]]; then
      expected_roles=${#OPSHUB_GRAPH_ROLES[@]}
    fi
    [[ "$role_count" == "$expected_roles" ]] \
      || die "$p: $role_count application permission(s) on the Service app, expected $expected_roles. Remove the extra ones in Entra."
    echo "$p: application permissions = $role_count (expected $expected_roles)"
  done
}

cmd_secrets() {
  cmd_preflight

  local p
  for p in rova opshub kb; do
    product_setup "$p"
    [[ -f "$KEY" && -f "$CRT" ]] || die "$p: key or certificate missing; run certs first"

    # Standalone secret: one PEM, key then certificate. Piped on stdin, never in argv.
    if aws secretsmanager describe-secret --profile qnsc-admin --region ap-southeast-1 \
      --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
      cat "$KEY" "$CRT" | aws secretsmanager put-secret-value --profile qnsc-admin --region ap-southeast-1 \
        --secret-id "$SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
      echo "$p: put-secret-value on $SECRET_NAME"
    else
      cat "$KEY" "$CRT" | aws secretsmanager create-secret --profile qnsc-admin --region ap-southeast-1 \
        --name "$SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
      echo "$p: created $SECRET_NAME"
    fi

    # Verify the shape without printing the value: lengths and PEM markers only.
    aws secretsmanager get-secret-value --profile qnsc-admin --region ap-southeast-1 \
      --secret-id "$SECRET_NAME" --query SecretString --output text \
      | python3 -c 'import sys; v = sys.stdin.read(); print("  chars:", len(v), "| private key block:", "PRIVATE KEY-----" in v, "| certificate blocks:", v.count("BEGIN CERTIFICATE-----"))'
  done
}

# Each product's own proof: the Service app sends as its own prod mailbox and is refused (403) for the others.
cmd_check() {
  require_tools
  : "${MAIL_SMOKE_TO:?set MAIL_SMOKE_TO to a mailbox you can read}"
  local -a targets=("$@")
  [[ ${#targets[@]} -gt 0 ]] || targets=(rova opshub kb)

  local target
  for target in "${targets[@]}"; do
    product_setup "$target"
    [[ -f "$KEY" && -f "$CRT" ]] || die "$target: key or certificate missing; run certs first"

    case "$target" in
      rova)
        : "${ROVA_REPO:?set ROVA_REPO to a rova checkout with pnpm install done}"
        (cd "$ROVA_REPO" && pnpm exec platform-mail-check \
          --tenant "$TENANT_ID" --client-id "$APP_ID" --cert "$CRT" --key "$KEY" \
          --sender noreply-rova@qnsc.vn --to "$MAIL_SMOKE_TO" \
          --denied-mailbox noreply-rova-dev@qnsc.vn \
          --denied-mailbox noreply-opshub@qnsc.vn \
          --denied-mailbox noreply-kb@qnsc.vn)
        ;;
      opshub)
        : "${OPSHUB_REPO:?set OPSHUB_REPO to an opshub checkout with pnpm install done}"
        (cd "$OPSHUB_REPO" && pnpm exec platform-mail-check \
          --tenant "$TENANT_ID" --client-id "$APP_ID" --cert "$CRT" --key "$KEY" \
          --sender noreply-opshub@qnsc.vn --to "$MAIL_SMOKE_TO" \
          --denied-mailbox noreply-opshub-dev@qnsc.vn \
          --denied-mailbox noreply-rova@qnsc.vn \
          --denied-mailbox noreply-kb@qnsc.vn \
          --allowed-role SecurityEvents.Read.All \
          --allowed-role DeviceManagementManagedDevices.Read.All \
          --allowed-role User.Read.All \
          --allowed-role User.EnableDisableAccount.All \
          --allowed-role User.RevokeSessions.All)
        ;;
      kb)
        : "${KB_REPO:?set KB_REPO to a qnsc-kb-backend checkout with its Python env ready}"
        (cd "$KB_REPO" && python3 scripts/graph_mail_check.py \
          --tenant "$TENANT_ID" --client-id "$APP_ID" --cert "$CRT" --key "$KEY" \
          --sender noreply-kb@qnsc.vn --to "$MAIL_SMOKE_TO" \
          --denied-mailbox noreply-kb-dev@qnsc.vn \
          --denied-mailbox noreply-rova@qnsc.vn \
          --denied-mailbox noreply-opshub@qnsc.vn)
        ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: entra-aws-prod-mail.sh <preflight|certs|entra|secrets|check [rova|opshub|kb]...>

Required environment (real GUIDs, from the Entra app registrations):
  ROVA_PROD_SERVICE_APP_ID, OPSHUB_PROD_SERVICE_APP_ID, KB_PROD_SERVICE_APP_ID   (entra, secrets, check)
Required for check: MAIL_SMOKE_TO, and ROVA_REPO / OPSHUB_REPO / KB_REPO for the products checked.
EOF
}

main() {
  local cmd="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi
  case "$cmd" in
    preflight) cmd_preflight ;;
    certs) cmd_certs ;;
    entra) cmd_entra ;;
    secrets) cmd_secrets ;;
    check) cmd_check "$@" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
