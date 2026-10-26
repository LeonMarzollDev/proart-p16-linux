#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 18 (optional): firmware updates from Linux (fwupd / LVFS)
#
# The firmware publishes an EFI System Resource Table (ESRT) with five entries (Windows, BIOS 303):
#   97686c57-e102-5ecf-ae23-27647f24f0ca  "ASUS UEFI BIOS" (system firmware, version 10.1.2.303)
#   090aaf80-94d2-3db0-9d58-b8d1a7ff723d, a761b3bd-e62a-4a71-841c-50ba4e500267,
#   c861b3bd-e62a-4a71-841c-50ba4e500267, 282d4664-664b-3da8-9b1a-42671d2b6b26  (device firmware)
# so fwupd's uefi-capsule plugin can see them (linux-nvidia has CONFIG_EFI_ESRT=y and
# CONFIG_EFI_CAPSULE_LOADER=y). ASUS does not publish laptop BIOS capsules on LVFS (not seen for
# this model at the time of writing), so in practice fwupd brings: the UEFI revocation list (dbx)
# and Secure Boot certificate (KEK/db 2023) updates, plus firmware of USB/Thunderbolt peripherals
# that are on LVFS. BIOS updates: download H7607BAxxx from ASUS support, copy it to a FAT32 USB
# stick and flash it with EZ Flash in the BIOS setup (F2 > Advanced > ASUS EZ Flash), on AC power.
# Remove: apt remove fwupd (not recommended)
# Run with: sudo bash install/18-firmware.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root

apt_update
apt-get install -y fwupd

echo "== ESRT entries (firmware-updatable components)"
for e in /sys/firmware/efi/esrt/entries/entry*; do
	[ -d "$e" ] || { echo "no ESRT exposed"; break; }
	printf '  %s  type %s  version 0x%x  last attempt status %s\n' "$(cat "$e/fw_class")" \
		"$(cat "$e/fw_type")" "$(cat "$e/fw_version")" "$(cat "$e/last_attempt_status")"
done
echo "== fwupd devices"
fwupdmgr get-devices --no-unreported-check 2>/dev/null | grep -E '^[├└]|Device ID|Current version|GUID|Update State|Flags' | head -60 || true
echo "== LVFS metadata and available updates"
fwupdmgr refresh --force || echo "Warning: could not refresh LVFS metadata"
fwupdmgr get-updates || true
echo
echo "Done. Apply updates with: sudo fwupdmgr update  (dbx updates may make BitLocker ask for its recovery key)"
