#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 4: battery, AC adapter, fan, performance modes, charge limit
# (proart_battery, DKMS)
#
# The BIOS talks to the ASUS EC service over FF-A, but on Linux the responses never reach the AML:
# ACPI _BST/_PSR always report zeros (0 %, AC offline), the fan sensor garbage, and the ASUS fan
# modes/charge limit do nothing. proart_battery sends the same EC commands directly and registers
# BAT1/ADP1, a fan sensor, a platform profile (GNOME power modes = ASUS silent/standard/performance)
# and BAT1's charge_control_end_threshold. While it is loaded, the non-working ACPI BAT0/AC0/fan
# are unbound. See docs/technical-notes.md.
# Remove: modprobe -r proart_battery; dkms remove proart-battery/<version> --all;
#         rm -rf /usr/src/proart-battery-* /etc/modules-load.d/proart-battery.conf \
#         /etc/udev/rules.d/61-proart-battery.rules
# Run with: sudo bash install/04-battery.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
KREL=$(uname -r)
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/drivers/proart-battery/dkms.conf")
SRC=/usr/src/proart-battery-$VER

echo "== 1/4 Build tools"
apt_update
apt-get install -y dkms build-essential

echo "== 2/4 Remove older versions, build and install $VER for $KREL"
for old in $(dkms status proart-battery 2>/dev/null | sed -n 's#^proart-battery/\([^,]*\),.*#\1#p' | sort -u); do
	dkms remove "proart-battery/$old" --all || true
done
rm -rf /usr/src/proart-battery-*
install -d "$SRC"
install -m 644 "$REPO"/drivers/proart-battery/{proart_battery.c,Makefile,dkms.conf} "$SRC/"
dkms add "proart-battery/$VER"
dkms build "proart-battery/$VER" -k "$KREL"
dkms install "proart-battery/$VER" -k "$KREL"
echo proart_battery > /etc/modules-load.d/proart-battery.conf
# the initramfs loads the module at boot; without this it keeps the previous version
update-initramfs -u -k "$KREL"

echo "== 3/4 udev rule for UPower's charge limit"
install -m 644 "$REPO/config/udev/61-proart-battery.rules" /etc/udev/rules.d/
udevadm control --reload

echo "== 4/4 Load"
if [ "$(cat /sys/module/proart_battery/initstate 2>/dev/null)" = "coming" ]; then
	echo "A previous proart_battery is stuck in the kernel - the new version loads on the next boot."
	exit 0
fi
modprobe -r proart_battery 2>/dev/null || true
modprobe proart_battery
sleep 1
udevadm trigger --action=change --subsystem-match=power_supply
udevadm settle
systemctl daemon-reload
systemctl restart upower power-profiles-daemon
dmesg | grep proart_battery | tail -3
echo "--- platform profile: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null) ($(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null))"
echo "--- fan: $(cat /sys/class/hwmon/hwmon*/fan1_input 2>/dev/null | head -1) rpm"
for p in BAT1 ADP1; do
	echo "--- $p"
	# not every attribute exists on both supplies; a missing one must not end the script
	grep -H . /sys/class/power_supply/$p/{status,capacity,energy_now,energy_full,power_now,voltage_now,cycle_count,charge_control_end_threshold,online} 2>/dev/null | sed 's#.*/##' || true
done
echo
echo "Done. The battery shows up in the desktop after a few seconds."
