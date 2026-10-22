#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 10: power saving
#
# The firmware leaves PCIe ASPM off on all links (SSD, Wi-Fi, SD reader). Earlier versions of this
# step set the ASPM policy to powersupersave (L1 + L1.1/L1.2) at boot. With it, s2idle sleeps of
# more than a few minutes hung on resume, so the policy stays at the kernel's "default" (firmware
# setting) and this step removes the old setting. See docs/technical-notes.md.
# Run with: sudo bash install/10-power.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root

echo "== PCIe ASPM policy: default (powersupersave hangs long sleeps)"
if [ -f /etc/tmpfiles.d/proart-pcie-aspm.conf ]; then
	rm /etc/tmpfiles.d/proart-pcie-aspm.conf
	echo default > /sys/module/pcie_aspm/parameters/policy || true
	echo "Removed /etc/tmpfiles.d/proart-pcie-aspm.conf from an earlier version."
fi
cat /sys/module/pcie_aspm/parameters/policy
echo
echo "Done."
