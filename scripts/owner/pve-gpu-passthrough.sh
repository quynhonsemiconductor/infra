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
#   5. PRINTS the `gpu_pci_mapping` tfvars snippet for the cluster-wide PCI mapping
#      "gpu-rtx5060ti" (read from sysfs). The mapping itself is Proxmox API state and
#      belongs to IaC: live/onprem-vm imports and manages it (proxmox_host.tf). Only
#      with --create-mapping does this script create it by hand, for a first bring-up
#      before the stack exists.
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
case "$MODE" in --check | --apply | --create-mapping) ;; *)
	echo "usage: $0 [--check|--apply|--create-mapping]" >&2
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
MODLOAD=/etc/modules-load.d/vfio-qnsc.conf
CMDLINE_FILE=/etc/kernel/cmdline

# ── the mapping entries as the host reports them ────────────────────────────
# Proxmox validates a mapping against the hardware at VM start: every entry needs
# iommugroup and subsystem-id, or qmstart fails "PCI device mapping invalid".
map_fields() { # $1 = function (0|1) -> "path group subsystem-id"
	local dev="$GPU_SLOT.$1" grp sub
	grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$dev/iommu_group")")
	sub="$(sed 's/^0x//' "/sys/bus/pci/devices/$dev/subsystem_vendor"):$(sed 's/^0x//' "/sys/bus/pci/devices/$dev/subsystem_device")"
	echo "$dev $grp $sub"
}

print_mapping_tfvars() {
	local node f0 f1
	node=$(hostname -s)
	read -r p0 g0 s0 <<<"$(map_fields 0)"
	read -r p1 g1 s1 <<<"$(map_fields 1)"
	f0="$p0 $g0 $s0"
	f1="$p1 $g1 $s1"
	[ -n "$f0" ] && [ -n "$f1" ] || return 0
	say "── site.tfvars snippet for live/onprem-vm (git-ignored file, NOT the public repo) ──"
	cat <<TFVARS
gpu_pci_mapping = {
  name    = "$MAPPING_ID"
  comment = "RTX 5060 Ti (ai-01, §9.1)"
  map = [
    { id = "$GPU_ID", node = "$node", path = "$p0", iommu_group = $g0, subsystem_id = "$s0" },
    { id = "$AUDIO_ID", node = "$node", path = "$p1", iommu_group = $g1, subsystem_id = "$s1" },
  ]
}
TFVARS
}

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
	[ -f "$MODLOAD" ] && pass "vfio modules load at boot" || { say "FAIL: $MODLOAD missing"; rc=1; }
	awk '/^dir: local$/{f=1;next} f&&/^[a-z]+: /{f=0} f&&$1=="content"{print $2}' /etc/pve/storage.cfg | grep -q snippets && pass "local datastore allows snippets" || { say "FAIL: snippets not enabled on local"; rc=1; }
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
	rc=0
	check_state || rc=$?
	print_mapping_tfvars
	exit "$rc"
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
blacklist nvidiafb
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
# vfio-pci must claim both functions before the host drivers do
softdep nouveau pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
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

# 3b. load vfio at boot (it has no modalias for this card, so nothing else loads it)
if [ -f "$MODLOAD" ]; then
	say "vfio modules-load already present"
else
	printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >"$MODLOAD"
	say "wrote $MODLOAD"
fi

# 4. rebuild the initramfs so it carries the new modprobe.d files; on a
#    proxmox-boot-tool host its hook copies the new image to the ESP
#    (proxmox-boot-tool refresh alone only re-copies the OLD initramfs).
update-initramfs -u -k all
say "update-initramfs done"

# 4b. ai-01's cloud-init snippet lives on the 'local' datastore
local_content() { awk '/^dir: local$/{f=1;next} f&&/^[a-z]+: /{f=0} f&&$1=="content"{print $2}' /etc/pve/storage.cfg; }
if local_content | grep -q snippets; then
	say "local datastore already allows snippets"
else
	cur=$(local_content)
	pvesm set local --content "${cur},snippets"
	say "enabled snippets on local (was: $cur)"
fi

# 5. the PCI mapping: IaC owns it (live/onprem-vm). --create-mapping is the by-hand fallback.
if pvesh get "/cluster/mapping/pci/$MAPPING_ID" >/dev/null 2>&1; then
	say "mapping $MAPPING_ID exists (managed by live/onprem-vm, proxmox_hardware_mapping_pci.gpu)"
elif [ "$MODE" = "--create-mapping" ]; then
	read -r p0 g0 s0 <<<"$(map_fields 0)"
	read -r p1 g1 s1 <<<"$(map_fields 1)"
	pvesh create /cluster/mapping/pci --id "$MAPPING_ID" --description "RTX 5060 Ti (ai-01, §9.1)" \
		--map "node=$(hostname -s),path=$p0,id=$GPU_ID,iommugroup=$g0,subsystem-id=$s0" \
		--map "node=$(hostname -s),path=$p1,id=$AUDIO_ID,iommugroup=$g1,subsystem-id=$s1"
	say "created mapping $MAPPING_ID BY HAND: import it into live/onprem-vm before the first apply"
else
	say "NOTE: mapping $MAPPING_ID does not exist yet. live/onprem-vm creates it from the snippet below;"
	say "      or run this script with --create-mapping and import it afterwards."
fi
print_mapping_tfvars

say ""
say "── changes written. Reboot the host, then --check again. ──"
say "Order: qm shutdown 100 --timeout 180 → reboot → --check → qm start 100"
check_state || true
