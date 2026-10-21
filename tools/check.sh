#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - health check after installing/rebooting. Read-only, runs as your user.
# Prints one line per component: OK, WARN or FAIL.
# Run with: bash tools/check.sh
ok=0; warn=0; fail=0
OK()   { printf '  \e[32mOK  \e[0m %s\n' "$*"; ok=$((ok + 1)); }
WARN() { printf '  \e[33mWARN\e[0m %s\n' "$*"; warn=$((warn + 1)); }
FAIL() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fail=$((fail + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then OK "$1"; else ${3:-FAIL} "$1"; fi; }
kmsg() { journalctl -k -b --no-pager -o cat 2>/dev/null; }

echo "== Boot"
echo "  kernel $(uname -r), $(uptime -p)"
check "kernel parameter acpi_osi=\"!Windows 2022\"" 'grep -q "acpi_osi=!Windows 2022" /proc/cmdline'
failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')
[ -z "$failed" ] && OK "no failed system units" || FAIL "failed units: $failed"
# systemd switches /sys/power/mem_sleep to s2idle only when it suspends
check "suspend mode s2idle" 'grep -q "\[s2idle\]" /sys/power/mem_sleep || systemd-analyze cat-config systemd/sleep.conf | grep -q "^MemorySleepMode=s2idle"'

echo "== Battery, EC, power modes"
check "proart_battery loaded ($(dkms status proart-battery 2>/dev/null | grep -o "proart-battery/[0-9.]*" | head -1))" 'test -d /sys/module/proart_battery'
# an initramfs built before the last DKMS install loads an older copy at boot
for m in proart_battery proart_audio hid_asus; do
	[ -r /sys/module/$m/srcversion ] || continue
	[ "$(cat /sys/module/$m/srcversion)" = "$(modinfo -F srcversion $m 2>/dev/null)" ] &&
		OK "$m: running version = installed version" ||
		FAIL "$m: an older copy is running (initramfs not updated? sudo update-initramfs -u)"
done
B=/sys/class/power_supply/BAT1
[ -r $B/capacity ] && OK "battery $(cat $B/capacity) %, $(cat $B/status), $(( $(cat $B/power_now 2>/dev/null || echo 0) / 1000000 )) W, charge limit $(cat $B/charge_control_end_threshold 2>/dev/null || echo -) %" || FAIL "battery BAT1 missing"
check "AC adapter ADP1 ($(cat /sys/class/power_supply/ADP1/online 2>/dev/null | sed 's/1/online/;s/0/offline/'))" 'test -r /sys/class/power_supply/ADP1/online'
pp=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)
[ -n "$pp" ] && OK "power mode $pp ($(cat /sys/firmware/acpi/platform_profile_choices))" || FAIL "no platform profile (GNOME power modes do nothing)"
check "GNOME sees the power modes (platform_profile driver)" 'powerprofilesctl list | grep -q "PlatformDriver:\s*platform_profile"'
H=$(grep -l proart_ec /sys/class/hwmon/*/name 2>/dev/null | head -1 | xargs -r dirname)
if [ -n "$H" ]; then
	OK "sensors: fan $(cat $H/fan1_input) rpm, EC $(( $(cat $H/temp1_input) / 1000 )) C, system $(( $(cat $H/power1_input) / 1000000 )) W, SoC $(( $(cat $H/power2_input) / 1000000 )) W"
else
	FAIL "hwmon proart_ec missing"
fi
bogus=$(for t in /sys/class/thermal/thermal_zone*/temp; do v=$(cat $t 2>/dev/null); [ "${v:-0}" -gt 150000 ] && echo $t; done)
[ -z "$bogus" ] && OK "no impossible temperatures" || WARN "thermal zones above 150 C: $bogus"
check "UPower offers the charge limit" 'busctl get-property org.freedesktop.UPower /org/freedesktop/UPower/devices/battery_BAT1 org.freedesktop.UPower.Device ChargeThresholdSupported | grep -q true'

echo "== Audio"
check "proart_audio loaded" 'test -d /sys/module/proart_audio'
check "speaker tuning loaded (cs35l56 firmware UID 10431484)" 'kmsg | grep -q "proart_audio: firmware UID 10431484"'
check "speaker DSP firmware running" 'kmsg | grep -q "cs35l56.*DSP1: Firmware:"'
check "speaker sink proart_speakers" 'pw-cli ls Node | grep -q "node.name = \"proart_speakers\""'
check "tweeter service" 'systemctl --user is-active proart-tweeter'

echo "== Keyboard, touchpad"
check "patched hid-asus with Fn-lock attribute" 'ls /sys/bus/hid/devices/*0B05:4B42*/fn_lock'
check "Fn-lock indicator running" 'pgrep -f proart-fnlock'
check "haptic click service" 'systemctl is-active proart-haptic'
check "libinput touchpad quirk" 'test -f /etc/libinput/local-overrides.quirks'

echo "== GPU, video"
check "NVIDIA driver ($(nvidia-smi --query-gpu=driver_version,pstate --format=csv,noheader 2>/dev/null))" 'nvidia-smi -L'
check "snap EGL shim" 'test -f /usr/share/glvnd/egl_vendor.d/09_nvidia_snap.json -a -f /usr/lib/aarch64-linux-gnu/libnvidia-snap-egl.so'
check "VA-API environment" 'test -f ~/.config/environment.d/90-nvidia-vaapi.conf' WARN

echo "== Power saving"
check "PCIe ASPM policy powersupersave" 'grep -q "\[powersupersave\]" /sys/module/pcie_aspm/parameters/policy'
for d in /sys/bus/pci/devices/*; do
	[ -f $d/link/l1_aspm ] || continue
	drv=$(basename "$(readlink -f $d/driver)")
	[ "$(cat $d/link/l1_aspm)" = 1 ] && OK "ASPM L1 on $drv" || WARN "ASPM L1 off on $drv"
done

echo "== Network"
check "Wi-Fi connected" 'nmcli -t -f TYPE,STATE dev | grep -q "^wifi:connected"' WARN
check "Bluetooth controller" 'test -n "$(ls /sys/class/bluetooth 2>/dev/null)"' WARN

echo "== Kernel log"
n=$(journalctl -k -b -p 3 --no-pager -o cat 2>/dev/null | wc -l)
[ "$n" -lt 20 ] && OK "$n kernel errors since boot" || WARN "$n kernel errors since boot (journalctl -k -b -p 3)"

echo
echo "Result: $ok OK, $warn WARN, $fail FAIL"
[ $fail -eq 0 ]
