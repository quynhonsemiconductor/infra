#!/usr/bin/env bash
# Read-only (default) or admin kubeconfig for the on-prem k3s cluster, with the credential in
# 1Password and NOT on disk.
#
# Run on a machine that already has admin access to the k3s server over SSH (WARP up):
#
#   scripts/owner/kubeconfig-ro.sh --ssh <user@k3s-server> --server https://<k3s-server>:6443
#   scripts/owner/kubeconfig-ro.sh --ssh <user@k3s-server> --server https://<k3s-server>:6443 --admin
#
# Hostnames and addresses are arguments (or K3S_SSH / K3S_SERVER), never written in this public repo.
#
# READ-ONLY (default): reads the token of ServiceAccount platform-access/sa-readonly (gitops
#   platform/access, bound to the built-in `view` role + a small read role: no Secrets, no exec) and the
#   cluster CA over SSH, stores the token in 1Password (vault QNSC, item "k3s onprem - sa-readonly - token",
#   field `credential`, via stdin), and writes ~/.kube/qnsc-onprem-ro.yaml, context `qnsc-onprem-ro`.
# --admin: OWNER ONLY. Reads the k3s admin client certificate and key from the server's admin kubeconfig,
#   stores them in 1Password (item "k3s onprem - admin - client cert", fields client-certificate-data and
#   client-key-data, via stdin) and writes ~/.kube/qnsc-onprem-admin.yaml, context `qnsc-onprem-admin`.
#   That identity is cluster-admin (group system:masters). Never hand it to an agent or the SA.
#
# The kubeconfig holds an exec credential that calls `op read` at use time, so no token or key sits in a
# file. `op` must be signed in (Touch ID) whenever kubectl runs; the admin variant's exec credential also needs `jq`.
# Secrets live only in shell variables and pipes: never argv (visible in `ps`), never a file, never printed.
#
# Idempotent: when 1Password already holds the same value nothing is written to it; when the value changed
# (rotation) the old item is archived and a new one created; the kubeconfig is rewritten identically.
#
# Options: --vault <name> (default QNSC)   --out <file>   --context <name>   --dry-run (read + report, change nothing)
set -euo pipefail

SSH_TARGET="${K3S_SSH:-}"
SERVER="${K3S_SERVER:-}"
VAULT="${OP_VAULT:-QNSC}"
MODE="ro"
OUT=""
CONTEXT=""
DRY=0
KUBECTL_REMOTE="sudo k3s kubectl"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case $1 in
		--ssh) SSH_TARGET=${2:?--ssh needs a value}; shift 2 ;;
		--server) SERVER=${2:?--server needs a value}; shift 2 ;;
		--vault) VAULT=${2:?}; shift 2 ;;
		--out) OUT=${2:?}; shift 2 ;;
		--context) CONTEXT=${2:?}; shift 2 ;;
		--admin) MODE="admin"; shift ;;
		--dry-run) DRY=1; shift ;;
		-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
		*) fail "unknown option $1" ;;
	esac
done
[ -n "$SSH_TARGET" ] || fail "--ssh <user@k3s-server> (or K3S_SSH) is required"
[ -n "$SERVER" ] || fail "--server https://<k3s-server>:6443 (or K3S_SERVER) is required"
case $SERVER in https://*) ;; *) fail "--server must be an https:// URL" ;; esac
for c in ssh op base64 kubectl jq; do command -v "$c" >/dev/null || fail "$c not found on PATH"; done

if [ "$MODE" = ro ]; then
	CONTEXT=${CONTEXT:-qnsc-onprem-ro}
	OUT=${OUT:-$HOME/.kube/qnsc-onprem-ro.yaml}
	ITEM="k3s onprem - sa-readonly - token"
else
	CONTEXT=${CONTEXT:-qnsc-onprem-admin}
	OUT=${OUT:-$HOME/.kube/qnsc-onprem-admin.yaml}
	ITEM="k3s onprem - admin - client cert"
fi

remote() { ssh -o BatchMode=yes "$SSH_TARGET" "$@"; }

# --- 1. read the credential and the CA from the cluster -----------------------------------------
if [ "$MODE" = ro ]; then
	# Both values stay base64 as stored in the Secret; the CA is embedded as-is (certificate-authority-data).
	TOKEN_B64=$(remote "$KUBECTL_REMOTE -n platform-access get secret sa-readonly-token -o jsonpath='{.data.token}'") \
		|| fail "could not read Secret platform-access/sa-readonly-token (is the gitops platform-base app synced?)"
	CA_B64=$(remote "$KUBECTL_REMOTE -n platform-access get secret sa-readonly-token -o jsonpath='{.data.ca\\.crt}'") \
		|| fail "could not read the cluster CA"
	[ -n "$TOKEN_B64" ] || fail "the token Secret exists but holds no token yet (the token controller fills it a moment after creation; retry)"
	SECRET_1=$(printf '%s' "$TOKEN_B64" | base64 -d)
	case $SECRET_1 in *.*.*) ;; *) fail "the token does not look like a service-account JWT" ;; esac
else
	KCFG=$(remote "sudo cat /etc/rancher/k3s/k3s.yaml") || fail "could not read the k3s admin kubeconfig"
	kget() { printf '%s' "$KCFG" | kubectl --kubeconfig=/dev/stdin config view --raw -o "jsonpath=$1"; }
	CERT_B64=$(kget '{.users[0].user.client-certificate-data}')
	KEY_B64=$(kget '{.users[0].user.client-key-data}')
	CA_B64=$(kget '{.clusters[0].cluster.certificate-authority-data}')
	unset KCFG
	[ -n "$CERT_B64" ] && [ -n "$KEY_B64" ] || fail "the admin kubeconfig has no client certificate/key"
fi
[ -n "$CA_B64" ] || fail "no cluster CA found"
printf '%s' "$CA_B64" | base64 -d | grep -q 'BEGIN CERTIFICATE' || fail "the cluster CA is not a PEM certificate"

# --- 2. 1Password (values only through stdin / env, never argv) ----------------------------------
op_read() { op read "op://$VAULT/$ITEM/$1" 2>/dev/null || true; }

store_item() {
	if [ "$MODE" = ro ]; then
		T="$SECRET_1" jq -n --arg title "$ITEM" \
			'{title:$title,category:"API_CREDENTIAL",fields:[{id:"credential",label:"credential",type:"CONCEALED",value:$ENV.T}]}'
	else
		C="$CERT_B64" K="$KEY_B64" jq -n --arg title "$ITEM" \
			'{title:$title,category:"API_CREDENTIAL",fields:[
			   {id:"client-certificate-data",label:"client-certificate-data",type:"CONCEALED",value:$ENV.C},
			   {id:"client-key-data",label:"client-key-data",type:"CONCEALED",value:$ENV.K}]}'
	fi | op item create --vault "$VAULT" - >/dev/null
}

if [ "$MODE" = ro ]; then
	CURRENT=$(op_read credential); WANT=$SECRET_1
else
	CURRENT=$(op_read client-certificate-data)$(op_read client-key-data); WANT=$CERT_B64$KEY_B64
fi
if [ "$CURRENT" = "$WANT" ]; then
	say "1Password: item '$ITEM' in vault $VAULT already holds this credential (unchanged)"
elif [ "$DRY" = 1 ]; then
	say "dry-run: would $([ -n "$CURRENT" ] && echo 'rotate' || echo 'create') item '$ITEM' in vault $VAULT"
else
	if [ -n "$CURRENT" ]; then
		op item delete "$ITEM" --vault "$VAULT" --archive >/dev/null
		say "1Password: archived the previous '$ITEM'"
	fi
	store_item
	say "1Password: stored '$ITEM' in vault $VAULT"
fi
unset TOKEN_B64 SECRET_1 CERT_B64 KEY_B64 CURRENT WANT

# --- 3. the kubeconfig: exec credential, no secret on disk ---------------------------------------
if [ "$MODE" = ro ]; then
	# printf is a shell builtin: the token is never on a command line.
	EXEC_ARGS=$(cat <<ARGS
      - -c
      - printf '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"%s"}}' "\$(op read 'op://$VAULT/$ITEM/credential')"
ARGS
)
else
	EXEC_ARGS=$(cat <<ARGS
      - -c
      - C=\$(op read 'op://$VAULT/$ITEM/client-certificate-data' | base64 -d) K=\$(op read 'op://$VAULT/$ITEM/client-key-data' | base64 -d) jq -cn '{apiVersion:"client.authentication.k8s.io/v1",kind:"ExecCredential",status:{clientCertificateData:\$ENV.C,clientKeyData:\$ENV.K}}'
ARGS
)
fi
RENDER=$(cat <<KUBE
apiVersion: v1
kind: Config
clusters:
  - name: qnsc-onprem
    cluster:
      server: $SERVER
      certificate-authority-data: $CA_B64
users:
  - name: $CONTEXT
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: sh
        interactiveMode: Never
        args:
$(printf '%s\n' "$EXEC_ARGS" | sed 's/^/    /')
contexts:
  - name: $CONTEXT
    context: { cluster: qnsc-onprem, user: $CONTEXT }
current-context: $CONTEXT
KUBE
)
if [ "$DRY" = 1 ]; then
	say "dry-run: would write $OUT (context $CONTEXT)"
else
	mkdir -p "$(dirname "$OUT")"
	if [ -f "$OUT" ] && [ "$(cat "$OUT")" = "$RENDER" ]; then
		say "kubeconfig: $OUT already up to date"
	else
		( umask 077; printf '%s\n' "$RENDER" >"$OUT" )
		chmod 600 "$OUT"
		say "kubeconfig: wrote $OUT (mode 600, context $CONTEXT, no secret inside)"
	fi
fi
say "try: kubectl --kubeconfig $OUT --context $CONTEXT get pods -A"
[ "$MODE" = admin ] && say "NOTE: the admin context is cluster-admin and for the owner only."
exit 0
