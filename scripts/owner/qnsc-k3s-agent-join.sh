#!/usr/bin/env bash
# Join ai-01 to the on-prem k3s cluster as the GPU agent node (§9.1).
#
# Run ON ai-01, as a user with sudo:
#
#   scripts/owner/qnsc-k3s-agent-join.sh <k3s-01 address> [ssh user]
#
# The node token is read from k3s-01 over SSH into a shell variable and handed
# to the installer through the ENVIRONMENT — never argv (visible in `ps`),
# never a file in Git, never Terraform state. The version comes from
# live/onprem-vm/files/k3s/version, so agent and server cannot drift.
set -euo pipefail

SERVER="${1:?usage: $0 <k3s-01 address> [ssh user]}"
SSH_USER="${2:-$(id -un)}"
VERSION_FILE="${VERSION_FILE:-files/k3s/version}"
NVIDIA_BRANCH="580"           # Blackwell (sm_120) needs >= 570.86.16; 580 is current production
NVIDIA_PKG="nvidia-driver-${NVIDIA_BRANCH}-open"

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] && SUDO=sudo || SUDO=

# 0. the node must see the card before anything else is worth doing
if ! lspci -nn | grep -q '10de:2d04'; then
	fail "the RTX 5060 Ti is not visible in this VM — check hostpci0 and the host mapping first"
fi
say "GPU present: $(lspci -nn | grep '10de:2d04')"

# 1. NVIDIA driver + container toolkit, both from NVIDIA's own apt repo
if ! command -v nvidia-smi >/dev/null; then
	say "installing $NVIDIA_PKG (branch r$NVIDIA_BRANCH)"
	$SUDO install -d -m 0755 /usr/share/keyrings
	curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
		$SUDO gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
	curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
		sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' |
		$SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
	$SUDO apt-get update -qq
	# driver from the distribution repo of the same branch (ubuntu-drivers)
	$SUDO apt-get install -y "$NVIDIA_PKG" nvidia-container-toolkit
else
	say "driver already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader)"
fi

# 2. hand the runtime to containerd through k3s's own templating
$SUDO nvidia-ctk runtime configure --runtime=containerd \
	--config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl 2>/dev/null ||
	$SUDO mkdir -p /var/lib/rancher/k3s/agent/etc/containerd

# 3. the agent config: server, label, taint. No token here.
$SUDO install -d -m 0755 /etc/rancher/k3s
$SUDO tee /etc/rancher/k3s/config.yaml >/dev/null <<YAML
server: https://${SERVER}:6443
node-label:
  - qnsc.vn/pool=ai
node-taint:
  - qnsc.vn/pool=ai:NoSchedule
YAML

# 4. version + token: token in the environment only
VERSION="$(tr -d '[:space:]' <"$VERSION_FILE")"
[ -n "$VERSION" ] || fail "no version in $VERSION_FILE"
TOKEN="$(ssh "${SSH_USER}@${SERVER}" 'sudo cat /var/lib/rancher/k3s/server/node-token')"
[ -n "$TOKEN" ] || fail "could not read the node token from ${SERVER}"

say "joining as $(hostname) with k3s $VERSION"
# The token reaches the installer as a 0600 file in tmpfs, passed by PATH, and
# is removed on exit — never argv, never part of the script's own stdin.
TOKEN_FILE="$(mktemp -p /run qnsc-k3s-token.XXXXXX)"
trap 'rm -f "$TOKEN_FILE" /run/qnsc-k3s-install.sh' EXIT
chmod 600 "$TOKEN_FILE"
printf '%s' "$TOKEN" >"$TOKEN_FILE"
unset TOKEN
curl -sfL https://get.k3s.io -o /run/qnsc-k3s-install.sh
K3S_URL="https://${SERVER}:6443" K3S_TOKEN_FILE="$TOKEN_FILE" \
	INSTALL_K3S_VERSION="$VERSION" $SUDO -E sh /run/qnsc-k3s-install.sh agent

# 5. what the owner then checks (documented in the README)
say ""
say "expect: kubectl get node $(hostname) → Ready, qnsc.vn/pool=ai, taint NoSchedule"
say "expect: nvidia-smi lists the RTX 5060 Ti"
