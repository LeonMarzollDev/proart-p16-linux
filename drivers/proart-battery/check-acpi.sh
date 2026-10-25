#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Does the stock ACPI battery work on this BIOS? Prints the BIOS version, the decision
# proart_battery made at load, and what ACPI BAT0/AC0/fan/thermal zones report.
# With "--raw" proart_battery is unloaded first, so BAT0/AC0 are bound to the stock drivers
# (it is loaded again at the end). Run with: sudo bash check-acpi.sh [--raw]
set -uo pipefail
echo "BIOS: $(cat /sys/class/dmi/id/bios_version) ($(cat /sys/class/dmi/id/bios_date))  kernel: $(uname -r)"
dmesg | grep -E 'proart_battery: (acpi|ec) mode|EC register 0x90|custom offset handler|FFixedHW|AE_ERROR' | tail -8
if [ "${1:-}" = --raw ]; then
	modprobe -r proart_battery && echo "proart_battery unloaded" && sleep 3
fi
for p in BAT0 AC0 BAT1 ADP1; do
	[ -e /sys/class/power_supply/$p ] || continue
	echo "--- $p"
	grep -H . /sys/class/power_supply/$p/{status,present,capacity,energy_now,energy_full,energy_full_design,power_now,voltage_now,cycle_count,charge_control_end_threshold,online} 2>/dev/null | sed 's#.*/##'
done
echo "--- ACPI fan / thermal zones"
for f in /sys/bus/acpi/devices/PNP0C0B:*/physical_node/fan_speed_rpm; do [ -r "$f" ] && echo "fan_speed_rpm: $(cat "$f")"; done
for z in /sys/class/thermal/thermal_zone*; do
	t=$(cat "$z/type"); p=$(cat "$z/device/path" 2>/dev/null || true)
	echo "$t ${p:-} $(cat "$z/temp" 2>/dev/null)"
done
echo "Working EC path: BAT0 voltage_now/energy_now non-zero, cycle_count small (not -989719533),"
echo "AC0 online follows the charger, THRM ~40-70 C (not a fixed 60 C)."
if [ "${1:-}" = --raw ]; then modprobe proart_battery; fi
