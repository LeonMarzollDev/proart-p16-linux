#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 10: power saving
#
# The firmware leaves PCIe ASPM off on all links (SSD, Wi-Fi, SD reader); Windows' drivers enable
# it, Linux' "default" ASPM policy keeps the firmware setting. This sets the policy to
# powersupersave (L1 + L1.1/L1.2) at every boot via systemd-tmpfiles. Tested without PCIe/AER
# errors under heavy SSD and Wi-Fi load. See docs/technical-notes.md.
# Remove: rm /etc/tmpfiles.d/proart-pcie-aspm.conf; reboot
# Run with: sudo bash install/10-power.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root

echo "== PCIe ASPM policy powersupersave"
install -m 644 "$REPO/config/tmpfiles.d/proart-pcie-aspm.conf" /etc/tmpfiles.d/
systemd-tmpfiles --create /etc/tmpfiles.d/proart-pcie-aspm.conf
cat /sys/module/pcie_aspm/parameters/policy
for d in /sys/bus/pci/devices/*; do
	[ -f "$d/link/l1_aspm" ] || continue
	printf '%s %-45s L1=%s L1.2=%s\n' "$(basename "$d")" "$(basename "$(readlink -f "$d/driver")")" \
		"$(cat "$d/link/l1_aspm")" "$(cat "$d/link/l1_2_aspm" 2>/dev/null || echo -)"
done
echo
echo "Done."
