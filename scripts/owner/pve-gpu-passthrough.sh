#!/usr/bin/env bash
# Prepare pve01 to hand the NVIDIA RTX 5060 Ti to the ai-01 VM (§9.1).
#
# Run ON the Proxmox host, as root:
#
#   scripts/owner/pve-gpu-passthrough.sh --check     # read-only: print the state
#   scripts/owner/pve-gpu-passthrough.sh --apply     # write the host config
#
# What it changes (all idempotent, each step is a read first):
#   1. blacklists nouveau and the out-of-tree nvidia modules on the host;
#   2. binds vfio-pci to the card and its audio function by PCI id;
#   3. adds iommu=pt to the kernel cmdline (a passthrough device gets identity
#      mappings; without it every DMA is translated for the whole host);
#   4. refreshes the initramfs (proxmox-boot-tool — this host boots ZFS from
#      systemd-boot, so update-initramfs alone would not reach the ESP);
#   5. creates the cluster-wide PCI mapping "gpu-rtx5060ti" used by
#      live/onprem-vm (the API token path cannot pass a raw hostpci id).
#
# A HOST REBOOT TAKES EVERY VM DOWN. Order:
#   1. qm shutdown 100 --timeout 180     (clean stop of k3s-01)
#   2. reboot                             (this script's changes take effect)
#   3. scripts/owner/pve-gpu-passthrough.sh --check   (expect all PASS)
#   4. qm start 100
#   5. then the on-prem stack apply + the ai-01 join
#
# Public repository: no hostnames, IPs or tokens in this file.
set -euo pipefail

GPU_ID="10de:2d04"   # NVIDIA RTX 5060 Ti (GB206) — VGA function
AUDIO_ID="10de:22eb" # its HDMI/DP audio function, same physical card
GPU_SLOT="0000:01:00"
MAPPING_ID="gpu-rtx5060ti"

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

BLACKLIST=/etc/modprobe.d/blacklist-qnsc-gpu.conf
VFIO=/etc/modprobe.d/vfio-qnsc-gpu.conf
CMDLINE_FILE=/etc/kernel/cmdline

# ── verify (used by --check and at the end of --apply) ──────────────────────
check_state() {
	local rc=0
	say "── GPU $GPU_SLOT ($GPU_ID / $AUDIO_ID) ──"
	say "$(lspci -nnk -s "$GPU_SLOT")"
	if lspci -nnk -s "$GPU_SLOT" | grep -q 'Kernel driver in use: vfio-pci'; then
		pass "vfio-pci is bound to $GPU_SLOT"
	else
		say "FAIL: vfio-pci is not bound (a reboot may be pending)"; rc=1
	fi
	for fn in "$GPU_SLOT.0" "$GPU_SLOT.1"; do
		if lspci -nnk -s "$fn" | grep -q 'Kernel driver in use: nouveau'; then
			say "FAIL: nouveau still holds $fn"; rc=1
		fi
	done
	say "── IOMMU groups ──"
	local g0 g1
	g0=$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_SLOT.0/iommu_group")")
	g1=$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_SLOT.1/iommu_group")")
	say "  $GPU_SLOT.0 → group $g0"
	say "  $GPU_SLOT.1 → group $g1"
	for g in "$g0" "$g1"; do
		say "  group $g:"
		for d in /sys/kernel/iommu_groups/"$g"/devices/*; do
			say "    $(basename "$d") $(lspci -n -s "$(basename "$d")" | cut -d' ' -f3)"
		done
	done
	if [ "$g0" = "$g1" ]; then
		pass "both functions share one IOMMU group ($g0) — passed together, nothing else in it"
	else
		say "NOTE: functions are in different groups ($g0, $g1) — also fine, both are passed"
	fi
	[ -f "$BLACKLIST" ] && pass "blacklist present" || { say "FAIL: $BLACKLIST missing"; rc=1; }
	[ -f "$VFIO" ] && pass "vfio ids present" || { say "FAIL: $VFIO missing"; rc=1; }
	grep -q 'iommu=pt' "$CMDLINE_FILE" 2>/dev/null && pass "iommu=pt on the kernel cmdline" ||
		{ say "FAIL: iommu=pt missing from $CMDLINE_FILE"; rc=1; }
	if pvesh get "/cluster/mapping/pci/$MAPPING_ID" >/dev/null 2>&1; then
		pass "PCI mapping $MAPPING_ID exists"
	else
		say "FAIL: PCI mapping $MAPPING_ID missing"; rc=1
	fi
	return "$rc"
}

if [ "$MODE" = "--check" ]; then
	check_state
	exit $?
fi

say "── applying ──"

# 1. host must not claim the card
if [ -f "$BLACKLIST" ]; then
	say "blacklist already present"
else
	cat >"$BLACKLIST" <<'EOF'
# ai-01 GPU passthrough (§9.1): the host never drives the RTX 5060 Ti.
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
	say "wrote $BLACKLIST"
fi

# 2. bind vfio-pci to both functions by id
if [ -f "$VFIO" ]; then
	say "vfio ids already present"
else
	cat >"$VFIO" <<EOF
# ai-01 GPU passthrough (§9.1): claim the card and its audio function for vfio.
options vfio-pci ids=$GPU_ID,$AUDIO_ID
EOF
	say "wrote $VFIO"
fi

# 3. identity mappings for passthrough devices
if grep -q 'iommu=pt' "$CMDLINE_FILE" 2>/dev/null; then
	say "iommu=pt already on the cmdline"
else
	[ -f "$CMDLINE_FILE" ] || fail "$CMDLINE_FILE not found — is this a systemd-boot/ZFS install?"
	cp -a "$CMDLINE_FILE" "$CMDLINE_FILE.bak-$(date +%Y%m%d%H%M%S)"
	printf ' iommu=pt\n' >>"$CMDLINE_FILE" # cmdline is one line; append, then collapse
	tr '\n' ' ' <"$CMDLINE_FILE" | sed 's/  */ /g; s/ $//' >"$CMDLINE_FILE.new"
	mv "$CMDLINE_FILE.new" "$CMDLINE_FILE"
	say "added iommu=pt to $CMDLINE_FILE"
fi

# 4. rebuild the ESP entry the systemd-boot install actually boots
if command -v proxmox-boot-tool >/dev/null; then
	proxmox-boot-tool refresh
	say "proxmox-boot-tool refresh done"
else
	update-initramfs -u -k all
	say "update-initramfs done (no proxmox-boot-tool)"
fi

# 5. the mapping Terraform passes (an API token cannot pass a raw hostpci id)
if pvesh get "/cluster/mapping/pci/$MAPPING_ID" >/dev/null 2>&1; then
	say "mapping $MAPPING_ID already exists"
else
	pvesh create /cluster/mapping/pci --id "$MAPPING_ID" --description "RTX 5060 Ti (ai-01, §9.1)" \
		--map "node=$(hostname -s),path=$GPU_SLOT.0,id=$GPU_ID" \
		--map "node=$(hostname -s),path=$GPU_SLOT.1,id=$AUDIO_ID"
	say "created mapping $MAPPING_ID"
fi

say ""
say "── changes written. Reboot the host, then --check again. ──"
say "Order: qm shutdown 100 --timeout 180 → reboot → --check → qm start 100"
check_state || true
