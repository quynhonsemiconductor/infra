#!/usr/bin/env bash
# Build the Ubuntu cloud-image VM template (9000) every VM of the stack is cloned from.
#
# Run ON the Proxmox host, as root:
#
#   scripts/owner/pve-template-9000.sh --check     # read-only: does the template exist and look right?
#   NAMESERVER=<lan dns> scripts/owner/pve-template-9000.sh --apply
#
# WHY A SCRIPT AND NOT TERRAFORM (the standard bpg pattern is proxmox_download_file + a
# `template = true` proxmox_virtual_environment_vm with disk.import_from):
#   - import_from is a create-time argument the provider cannot read back, so IMPORTING the existing
#     template 9000 would plan a replacement of the VM every clone depends on; there is no way to
#     prove "No changes" without the host, and a wrong plan destroys the base image.
#   - a template is a build ARTEFACT (an image at a point in time), not desired state: rebuilding it is
#     a deliberate act on a new site or a new Ubuntu release, which is exactly what a script run is.
#   - it needs host-local facts (the LAN resolver, the operator's authorized_keys) that stay out of
#     the public repo.
# The stack consumes it by id (`clone { vm_id = 9000 }` in ai01.tf) and never describes it.
#
# Idempotent: an existing, finished template is reported and left alone. A half-built VM 9000 is
# refused (destroy it yourself, `qm destroy 9000`, after looking at it): this script never deletes.
# Public repository: no hostnames, IPs or keys in this file; site values come from the environment.
set -euo pipefail

TEMPLATE_ID="${TEMPLATE_ID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-ubuntu-2604-tpl}"
STORAGE="${STORAGE:-local-zfs}"
BRIDGE="${BRIDGE:-vmbr0}"
CI_USER="${CI_USER:-qnsc}"
SSH_KEYS_FILE="${SSH_KEYS_FILE:-/root/.ssh/authorized_keys}"
IMAGE_DIR="${IMAGE_DIR:-/var/lib/vz/template/iso}"
RELEASE_URL="${RELEASE_URL:-https://cloud-images.ubuntu.com/releases/resolute/release}"
IMAGE_FILE="${IMAGE_FILE:-ubuntu-26.04-server-cloudimg-amd64.img}"

MODE="${1:---check}"
case "$MODE" in --check | --apply) ;; *)
	echo "usage: $0 [--check|--apply]" >&2
	exit 2
	;;
esac

say() { printf '%s\n' "$*"; }
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}
pass() { printf 'PASS: %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || fail "run as root on the Proxmox host"
command -v qm >/dev/null || fail "qm not found: this runs on the Proxmox host"

state() { # prints: absent | template | vm
	if ! qm config "$TEMPLATE_ID" >/dev/null 2>&1; then
		echo absent
	elif qm config "$TEMPLATE_ID" | grep -q '^template: 1'; then
		echo template
	else
		echo vm
	fi
}

check() {
	case "$(state)" in
	template)
		pass "VM $TEMPLATE_ID is a template"
		qm config "$TEMPLATE_ID" | grep -E '^(name|machine|bios|scsihw|agent|serial0|vga|ciuser):' | sed 's/^/  /'
		;;
	vm) fail "VM $TEMPLATE_ID exists but is not a template (a half-built run?). Inspect it; destroy it yourself to rebuild" ;;
	absent) say "VM $TEMPLATE_ID does not exist" && return 1 ;;
	esac
}

if [ "$MODE" = "--check" ]; then
	check
	exit $?
fi

case "$(state)" in
template)
	pass "VM $TEMPLATE_ID is already a template: nothing to do"
	exit 0
	;;
vm) fail "VM $TEMPLATE_ID exists but is not a template. Inspect it; this script never deletes" ;;
esac

[ -n "${NAMESERVER:-}" ] || fail "set NAMESERVER=<the LAN resolver> (site value, not in the repo)"
[ -s "$SSH_KEYS_FILE" ] || fail "no operator keys in $SSH_KEYS_FILE (set SSH_KEYS_FILE)"
pvesm status --storage "$STORAGE" >/dev/null 2>&1 || fail "storage $STORAGE not found (set STORAGE)"

say "── downloading and verifying the image ──"
mkdir -p "$IMAGE_DIR"
cd "$IMAGE_DIR"
curl -fsSLO "$RELEASE_URL/SHA256SUMS"
if [ ! -s "$IMAGE_FILE" ]; then
	curl -fsSLO "$RELEASE_URL/$IMAGE_FILE"
fi
grep " \*\?$IMAGE_FILE\$" SHA256SUMS | sha256sum -c - || fail "SHA256 mismatch for $IMAGE_FILE: delete it and rerun"

say "── creating VM $TEMPLATE_ID ──"
qm create "$TEMPLATE_ID" --name "$TEMPLATE_NAME" --ostype l26 --machine q35 --bios ovmf \
	--efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0" --cpu host --cores 2 --memory 4096 \
	--scsihw virtio-scsi-single --net0 "virtio,bridge=$BRIDGE" --serial0 socket --vga std --agent enabled=1
qm set "$TEMPLATE_ID" --scsi0 "$STORAGE:0,import-from=$IMAGE_DIR/$IMAGE_FILE,discard=on,iothread=1,ssd=1"
qm set "$TEMPLATE_ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm set "$TEMPLATE_ID" --ciuser "$CI_USER" --sshkeys "$SSH_KEYS_FILE" --nameserver "$NAMESERVER"
qm template "$TEMPLATE_ID"

check
