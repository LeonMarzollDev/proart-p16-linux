#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 1: NVIDIA N1X kernel (linux-nvidia) + acpi_osi + GRUB
#
# Why:
#  - The generic Ubuntu kernel has no drivers for the MT8901 I2C/GPIO blocks (keyboard, touchpad,
#    touchscreen), the MT8901 SoundWire audio stack and the FF-A EC services.
#  - linux-nvidia >= 7.0.0-1023 carries all of them. At the time of writing it is only in
#    <codename>-proposed; only the kernel packages are taken from there (pin priority 1).
#  - The BIOS hides the SSPM power controller (NVDA8400) and other devices from an OS that answers
#    _OSI("Windows 2022"). Without SSPM there is no SCMI, and the kernel's power_wrap driver then
#    leaves USB, I2C and audio powered off. acpi_osi="!Windows 2022" fixes that.
#  - The firmware is built for Modern Standby (FADT "Low Power S0 Idle"), but arm64 Linux suspends
#    with PSCI SYSTEM_SUSPEND ("deep") by default, from which it never woke up. Suspend uses
#    s2idle instead (systemd sleep.conf.d).
#
# Override the kernel with:  KREL=7.0.0-1023-nvidia  (default: newest linux-nvidia >= 1023)
# Remove: boot another kernel, then  apt remove linux-image-$KREL linux-modules-$KREL \
#         linux-modules-nvidia-615-open-$KREL linux-headers-$KREL; remove acpi_osi from /etc/default/grub;
#         rm /etc/systemd/sleep.conf.d/50-proart-s2idle.conf
# Run with: sudo bash install/01-kernel.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
MIN_ABI=1023
NV=615

echo "== 1/5 Find the linux-nvidia kernel (main or -proposed)"
proposed_enable
if [ -z "${KREL:-}" ]; then
	KREL=$(apt-cache search --names-only '^linux-image-7\.[0-9.]+-[0-9]+-nvidia$' | awk '{print $1}' |
		sed 's/^linux-image-//' | sort -V | tail -1)
fi
[ -n "$KREL" ] || { echo "No linux-nvidia kernel found"; exit 1; }
abi=$(echo "$KREL" | sed -E 's/^[0-9.]+-([0-9]+)-nvidia$/\1/')
[ "$abi" -ge $MIN_ABI ] || { echo "$KREL is older than the tested 7.0.0-$MIN_ABI-nvidia"; exit 1; }
VER=$(apt-cache madison "linux-image-$KREL" | awk '{print $3}' | sort -V | tail -1)
echo "Kernel: $KREL ($VER)"

echo "== 2/5 Install kernel, headers and the prebuilt NVIDIA $NV open kernel modules"
apt-get install -y \
	"linux-image-$KREL=$VER" \
	"linux-modules-$KREL=$VER" \
	"linux-headers-$KREL=$VER" \
	"linux-nvidia-headers-${KREL%-nvidia}=$VER" \
	"linux-modules-nvidia-$NV-open-$KREL=$VER"
proposed_disable
apt_update

echo "== 3/5 Kernel parameter acpi_osi=\"!Windows 2022\", visible GRUB menu"
if ! grep -q 'acpi_osi=' /etc/default/grub; then
	sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 acpi_osi=\\"!Windows 2022\\""/' /etc/default/grub
fi
sed -i 's/^GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/; s/^GRUB_TIMEOUT=0$/GRUB_TIMEOUT=5/; s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
grep -E '^GRUB_(DEFAULT|TIMEOUT|CMDLINE_LINUX_DEFAULT)' /etc/default/grub

echo "== 4/5 Suspend with s2idle (Modern Standby)"
install -d /etc/systemd/sleep.conf.d
install -m 644 "$REPO/config/systemd/50-proart-s2idle.conf" /etc/systemd/sleep.conf.d/
echo s2idle > /sys/power/mem_sleep 2>/dev/null || true
cat /sys/power/mem_sleep

echo "== 5/5 Make $KREL the default boot entry (other kernels stay under 'Advanced options')"
update-grub
entry=$(grub_entry_for "$KREL") || { echo "GRUB entry for $KREL not found - select it manually"; exit 1; }
grub-set-default "$entry"
grub-editenv list

echo
echo "Done. Continue with install/02-nvidia.sh, then reboot."
echo "If the new kernel does not boot: GRUB -> 'Advanced options' -> previous kernel."
