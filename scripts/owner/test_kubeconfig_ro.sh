#!/usr/bin/env bash
# Offline tests for kubeconfig-ro.sh. Stub `ssh` and `op` on PATH answer from fixtures and log every
# argv, so no cluster and no 1Password is touched. Checks: the happy path stores the credential once
# (through stdin), the kubeconfig holds an exec credential and NO secret, nothing secret reaches stdout
# or any argv, a re-run changes nothing, a rotated token archives and re-creates, and bad input fails.
# A PASS here must fail on broken input.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/kubeconfig-ro.sh"
T="$(mktemp -d)"
[[ -n "${KEEP_TEST_DIR:-}" ]] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/store" "$T/home"
LOG="$T/calls.log"

for c in openssl jq kubectl; do command -v "$c" >/dev/null || { echo "need $c"; exit 2; }; done
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -out "$T/ca.crt" -subj "/CN=stub-ca" -days 2 >/dev/null 2>&1
CA_B64=$(base64 <"$T/ca.crt" | tr -d '\n')
TOKEN="eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzdHViIn0.c2lnbmF0dXJl-STUBTOKEN-1"
TOKEN2="eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJzdHViIn0.c2lnbmF0dXJl-STUBTOKEN-2"
CERT_PEM="-----BEGIN CERTIFICATE-----
STUBADMINCERTIFICATEBODY
-----END CERTIFICATE-----"
KEY_PEM="-----BEGIN EC PRIVATE KEY-----
STUBADMINPRIVATEKEYBODY
-----END EC PRIVATE KEY-----"
CERT_B64=$(printf '%s\n' "$CERT_PEM" | base64 | tr -d '\n')
KEY_B64=$(printf '%s\n' "$KEY_PEM" | base64 | tr -d '\n')

cat >"$T/k3s.yaml" <<YAML
apiVersion: v1
kind: Config
clusters:
- cluster: {certificate-authority-data: $CA_B64, server: https://127.0.0.1:6443}
  name: default
contexts:
- context: {cluster: default, user: default}
  name: default
current-context: default
users:
- name: default
  user: {client-certificate-data: $CERT_B64, client-key-data: $KEY_B64}
YAML

cat >"$T/bin/ssh" <<STUB
#!/usr/bin/env bash
printf 'ssh %s\n' "\$*" >>"$LOG"
cmd="\${*: -1}"
case "\$cmd" in
  *"get secret sa-readonly-token"*"{.data.token}"*) printf '%s' "\$(cat "$T/token_b64")" ;;
  *"get secret sa-readonly-token"*"ca"*) printf '%s' "$CA_B64" ;;
  "sudo cat /etc/rancher/k3s/k3s.yaml") cat "$T/k3s.yaml" ;;
  *) echo "stub ssh: unexpected command" >&2; exit 9 ;;
esac
STUB
cat >"$T/bin/op" <<STUB
#!/usr/bin/env bash
printf 'op %s\n' "\$*" >>"$LOG"
STORE="$T/store"
case "\$1 \$2" in
  "read op://"*) ;;
esac
if [ "\$1" = read ]; then
  ref=\${2#op://}; vault=\${ref%%/*}; rest=\${ref#*/}; item=\${rest%/*}; field=\${rest##*/}
  f="\$STORE/\$vault|\$item|\$field"
  [ -f "\$f" ] && { cat "\$f"; exit 0; } || { echo "not found" >&2; exit 1; }
elif [ "\$1 \$2" = "item create" ]; then
  json=\$(cat)
  vault=""; while [ \$# -gt 0 ]; do [ "\$1" = --vault ] && vault=\$2; shift; done
  title=\$(jq -r .title <<<"\$json")
  for id in \$(jq -r '.fields[].id' <<<"\$json"); do
    jq -j --arg id "\$id" '.fields[]|select(.id==\$id)|.value' <<<"\$json" >"\$STORE/\$vault|\$title|\$id"
  done
elif [ "\$1 \$2" = "item delete" ]; then
  item=\$3; vault=""; shift 3; while [ \$# -gt 0 ]; do [ "\$1" = --vault ] && vault=\$2; shift; done
  rm -f "\$STORE/\$vault|\$item|"*
else echo "stub op: unexpected \$*" >&2; exit 9; fi
STUB
chmod +x "$T/bin/ssh" "$T/bin/op"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect() { # expect <name> <exit code of the command under test>
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi
}
run() { # run <args...>; sets RC and OUT
  : >"$LOG"
  set +e
  OUT=$(HOME="$T/home" PATH="$T/bin:$PATH" "$SCRIPT" --ssh stub@host.invalid --server https://api.invalid:6443 "$@" 2>&1)
  RC=$?
  set -e
}
count() { grep -c -- "$1" "$LOG" || true; }
leak() { # leak <secret...>: 0 when none of them appears in stdout, argv log or the kubeconfigs
  local s
  for s in "$@"; do
    [[ "$OUT" == *"$s"* ]] && return 1
    grep -qF -- "$s" "$LOG" && return 1
    grep -rqF -- "$s" "$T/home" 2>/dev/null && return 1
  done
  return 0
}
RO="$T/home/.kube/qnsc-onprem-ro.yaml"
ADM="$T/home/.kube/qnsc-onprem-admin.yaml"

# 1. first RO run
printf '%s' "$TOKEN" | base64 | tr -d '\n' >"$T/token_b64"
run
expect "ro: exits 0" "$RC"
if [ "$(cat "$T/store/QNSC|k3s onprem - sa-readonly - token|credential")" = "$TOKEN" ]; then ok "ro: token stored in the item's credential field"; else bad "ro: token stored in the item's credential field"; fi
if [ "$(count 'op item create')" = 1 ]; then ok "ro: item created once"; else bad "ro: item created once"; fi
if leak "$TOKEN" "$TOKEN2"; then ok "ro: token not in stdout, argv or any file under HOME"; else bad "ro: token not in stdout, argv or any file under HOME"; fi
if [ "$(stat -f %Lp "$RO" 2>/dev/null || stat -c %a "$RO")" = 600 ]; then ok "ro: kubeconfig mode 600"; else bad "ro: kubeconfig mode 600"; fi
if grep -q "server: https://api.invalid:6443" "$RO" && grep -q "certificate-authority-data: $CA_B64" "$RO"; then ok "ro: kubeconfig has server and CA"; else bad "ro: kubeconfig has server and CA"; fi
if grep -q "op read 'op://QNSC/k3s onprem - sa-readonly - token/credential'" "$RO" && grep -q "command: sh" "$RO"; then ok "ro: kubeconfig uses an op exec credential"; else bad "ro: kubeconfig uses an op exec credential"; fi
grep -qE '^\s+token:' "$RO" && bad "ro: kubeconfig has a literal token field" || ok "ro: kubeconfig has no literal token field"
# the kubeconfig really works as an exec credential plugin: run its exec command with the stub op
exec_out=$(PATH="$T/bin:$PATH" sh -c "$(awk '/- -c/{getline; sub(/^ *- /,""); print}' "$RO")")
if [ "$(jq -r '.status.token' <<<"$exec_out")" = "$TOKEN" ] && [ "$(jq -r .kind <<<"$exec_out")" = ExecCredential ]; then ok "ro: the exec command prints a valid ExecCredential with the token"; else bad "ro: the exec command prints a valid ExecCredential with the token"; fi

# 2. re-run: nothing changes
run
expect "rerun: exits 0" "$RC"
if [ "$(count 'op item create')" = 0 ] && [ "$(count 'op item delete')" = 0 ]; then ok "rerun: no 1Password write"; else bad "rerun: no 1Password write"; fi
if [[ "$OUT" == *"unchanged"* && "$OUT" == *"up to date"* ]]; then ok "rerun: reports unchanged"; else bad "rerun: reports unchanged"; fi

# 3. rotated token: archive then create
printf '%s' "$TOKEN2" | base64 | tr -d '\n' >"$T/token_b64"
run
if [ "$RC" = 0 ] && [ "$(count 'op item delete')" = 1 ] && [ "$(count '--archive')" = 1 ] && [ "$(count 'op item create')" = 1 ]; then ok "rotate: old item archived, new created"; else bad "rotate: old item archived, new created"; fi
if [ "$(cat "$T/store/QNSC|k3s onprem - sa-readonly - token|credential")" = "$TOKEN2" ]; then ok "rotate: new token stored"; else bad "rotate: new token stored"; fi
if leak "$TOKEN" "$TOKEN2"; then ok "rotate: neither token leaked"; else bad "rotate: neither token leaked"; fi

# 4. bad input
printf '' >"$T/token_b64"
if run; { [ "$RC" != 0 ] && [[ "$OUT" == *"holds no token"* ]]; }; then ok "empty token fails with a clear message"; else bad "empty token fails with a clear message"; fi
printf '%s' "notajwt" | base64 | tr -d '\n' >"$T/token_b64"
if run; { [ "$RC" != 0 ] && [[ "$OUT" == *"JWT"* ]]; }; then ok "non-JWT token fails"; else bad "non-JWT token fails"; fi
printf '%s' "$TOKEN" | base64 | tr -d '\n' >"$T/token_b64"
: >"$LOG"; set +e; HOME="$T/home" PATH="$T/bin:$PATH" "$SCRIPT" --ssh stub@host.invalid >/dev/null 2>&1; r1=$?
HOME="$T/home" PATH="$T/bin:$PATH" "$SCRIPT" --ssh stub@host.invalid --server http://api.invalid:6443 >/dev/null 2>&1; r2=$?; set -e
if { [ "$r1" != 0 ] && [ "$r2" != 0 ]; }; then ok "missing --server and a non-https --server fail"; else bad "missing --server and a non-https --server fail"; fi

# 5. dry run changes nothing
rm -rf "$T/store"/* "$T/home/.kube"
run --dry-run
if { [ "$RC" = 0 ] && [ -z "$(ls "$T/store")" ] && [ ! -e "$RO" ] && [ "$(count 'op item create')" = 0 ]; }; then ok "dry-run: reads, reports, writes nothing"; else bad "dry-run: reads, reports, writes nothing"; fi

# 6. admin
rm -rf "$T/store"/* "$T/home/.kube"
run --admin
expect "admin: exits 0" "$RC"
if [ "$(cat "$T/store/QNSC|k3s onprem - admin - client cert|client-certificate-data")" = "$CERT_B64" ]  && [ "$(cat "$T/store/QNSC|k3s onprem - admin - client cert|client-key-data")" = "$KEY_B64" ]; then ok "admin: cert and key stored in two fields"; else bad "admin: cert and key stored in two fields"; fi
if leak "$CERT_B64" "$KEY_B64" "STUBADMINPRIVATEKEYBODY" "STUBADMINCERTIFICATEBODY"; then ok "admin: cert/key not in stdout, argv or any file under HOME"; else bad "admin: cert/key not in stdout, argv or any file under HOME"; fi
if grep -q "op://QNSC/k3s onprem - admin - client cert/client-key-data" "$ADM" && grep -q "jq -cn" "$ADM"; then ok "admin: kubeconfig uses an op exec credential"; else bad "admin: kubeconfig uses an op exec credential"; fi
if [[ "$OUT" == *"owner only"* ]]; then ok "admin: warns it is owner only"; else bad "admin: warns it is owner only"; fi
exec_out=$(PATH="$T/bin:$PATH" sh -c "$(awk '/- -c/{getline; sub(/^ *- /,""); print}' "$ADM")")
if [[ "$(jq -r '.status.clientKeyData' <<<"$exec_out")" == *STUBADMINPRIVATEKEYBODY* ]] && [[ "$(jq -r '.status.clientCertificateData' <<<"$exec_out")" == *STUBADMINCERTIFICATEBODY* ]]; then ok "admin: the exec command prints cert and key PEM"; else bad "admin: the exec command prints cert and key PEM"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
