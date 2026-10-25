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
# a DKMS build of the same version number from older sources would pass the check above
REPO=$(cd "$(dirname "$0")/.." && pwd)
for d in proart-battery proart-audio hid-asus-proart; do
	ver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/drivers/$d/dkms.conf" 2>/dev/null)
	[ -n "$ver" ] || continue
	if [ ! -d "/usr/src/$d-$ver" ]; then
		FAIL "$d $ver from this repo is not installed (installed: $(ls -d /usr/src/$d-* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' '))"
	elif diff -q <(cat "$REPO/drivers/$d"/*.c) <(cat "/usr/src/$d-$ver"/*.c) >/dev/null; then
		OK "$d $ver: installed source = repo"
	else
		FAIL "$d $ver: installed source differs from the repo (run its install script again)"
	fi
done
check "EC standby notifications off (they cut the audio codecs' power)" '[ "$(cat /sys/module/proart_battery/parameters/standby_notify)" = N ]'
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
check "power off through UEFI (battery stays connected)" 'journalctl -k -b --no-pager | grep -q "powering off through UEFI ResetSystem"'
check "UPower offers the charge limit" 'busctl get-property org.freedesktop.UPower /org/freedesktop/UPower/devices/battery_BAT1 org.freedesktop.UPower.Device ChargeThresholdSupported | grep -q true'

echo "== Audio"
check "proart_audio loaded" 'test -d /sys/module/proart_audio'
check "speaker tuning loaded (cs35l56 firmware UID 10431484)" 'kmsg | grep -q "proart_audio: firmware UID 10431484"'
check "speaker DSP firmware running" 'kmsg | grep -q "cs35l56.*DSP1: Firmware:"'
# 51-proart-names.conf hides the woofer port; only the repo's UCM profile switches the woofer amps then
check "UCM profile installed = repo (else: sudo bash install/03-audio.sh)" 'diff -rq "$REPO/config/ucm2/MediaTek/mt8901-soundwir" /usr/share/alsa/ucm2/MediaTek/mt8901-soundwir'
check "WirePlumber names installed = repo (else: user/install-user.sh)" 'diff -q "$REPO/config/wireplumber/51-proart-names.conf" ~/.config/wireplumber/wireplumber.conf.d/51-proart-names.conf' WARN
check "speaker sink proart_speakers" 'pw-cli ls Node | grep -q "node.name = \"proart_speakers\""'
check "PipeWire never below 1024 samples (else the speakers xrun; user/install-user.sh)" 'pw-metadata -n settings 0 | grep -q "clock.min-quantum. value:.1024."'
check "tweeter service" 'systemctl --user is-active proart-tweeter'
# optional/phone-handsfree.sh
[ -f ~/.config/systemd/user/proart-phone-bridge.service ] &&
	check "phone call bridge (GNOME Calls)" 'systemctl --user is-active proart-phone-bridge' &&
	check "GNOME Calls running in the background (incoming calls ring)" 'systemctl --user is-active calls-daemon'
# user/install-user.sh puts a fixed copy of WirePlumber's state-stream.lua in the user's data dir
WPS=~/.local/share/wireplumber/scripts/node/state-stream.lua
if [ ! -f $WPS ]; then
	WARN "speaker mute is not kept across reboots (run user/install-user.sh)"
elif diff -q <(sed -e 's/if props\.volume ~= stored_values\.volume then/if props.volume ~= nil and props.volume ~= stored_values.volume then/' \
	-e 's/if props\.mute ~= stored_values\.mute then/if props.mute ~= nil and props.mute ~= stored_values.mute then/' \
	/usr/share/wireplumber/scripts/node/state-stream.lua) $WPS >/dev/null; then
	OK "speaker mute is kept across reboots (WirePlumber fix)"
else
	WARN "WirePlumber was updated: run user/install-user.sh again (mute fix is outdated)"
fi

echo "== Keyboard, touchpad"
check "patched hid-asus with Fn-lock attribute" 'ls /sys/bus/hid/devices/*0B05:4B42*/fn_lock'
check "Fn-lock indicator running" 'pgrep -f proart-fnlock'
check "haptic click service" 'systemctl is-active proart-haptic'
check "libinput touchpad quirk" 'test -f /etc/libinput/local-overrides.quirks'

echo "== Desktop"
# with energy-aware scheduling GNOME Shell otherwise runs on the efficiency cores at ~340 MHz
um=$(uclampset -p "$(pgrep -x gnome-shell)" 2>/dev/null | sed -n 's/.*min.: \([0-9]*\).*/\1/p')
[ "${um:-0}" -ge 768 ] && OK "GNOME Shell on the fast cores (uclamp min $um)" ||
	WARN "GNOME Shell may run on the slow cores (uclamp min ${um:-?}; user/install-user.sh, then log in again)"

echo "== GPU, video"
check "NVIDIA driver ($(nvidia-smi --query-gpu=driver_version,pstate --format=csv,noheader 2>/dev/null))" 'nvidia-smi -L'
# the firmware reports "battery" on AC too (ACPI _PSR); without this key the GPU stays at its battery cap
check "GPU battery cap off (RMSkipACPIBattCap, install/02-nvidia.sh)" 'grep -q "RMSkipACPIBattCap=1" /proc/driver/nvidia/params'
check "snap EGL shim" 'test -f /usr/share/glvnd/egl_vendor.d/09_nvidia_snap.json -a -f /usr/lib/aarch64-linux-gnu/libnvidia-snap-egl.so'
check "VA-API environment" 'test -f ~/.config/environment.d/90-nvidia-vaapi.conf' WARN

echo "== Display (OLED panel)"
bl=$(ls /sys/class/backlight 2>/dev/null | head -1)
[ -n "$bl" ] && OK "panel brightness control ($bl: $(cat /sys/class/backlight/$bl/brightness)/$(cat /sys/class/backlight/$bl/max_brightness))" ||
	WARN "no backlight device: the brightness slider cannot work (docs/hardware-extra.md)"
[ -d /usr/share/color/icc/asus-proart-p16 ] && OK "ASUS factory colour profiles installed ($(ls /usr/share/color/icc/asus-proart-p16 | wc -l))" ||
	WARN "no ASUS colour profile (optional: install/12-display.sh)"
command -v gdctl >/dev/null &&
	check "HDR offered for the internal panel (GNOME Settings > Displays)" 'gdctl show 2>/dev/null | grep -qi bt2100' WARN

echo "== Sensors"
check "webcam presence sensor (iio prox)" 'grep -qx prox /sys/bus/iio/devices/iio:device*/name' WARN
if dkms status spi-hid 2>/dev/null | grep -q installed; then
	check "ambient light sensor (spi-hid + hid-sensor-als, install/14-sensors.sh)" 'ls /sys/bus/iio/devices/iio:device*/in_illuminance_* '
	check "iio-sensor-proxy offers the light sensor to GNOME" 'gdbus call --system --dest net.hadess.SensorProxy --object-path /net/hadess/SensorProxy --method org.freedesktop.DBus.Properties.Get net.hadess.SensorProxy HasAmbientLight | grep -q true' WARN
else
	WARN "ambient light sensor not set up (HID over SPI; optional: install/14-sensors.sh, unverified)"
fi

echo "== USB-C, USB4, card reader"
check "USB-C ports in the Type-C class (UCSI)" 'test -e /sys/class/typec/port0'
# NVDA8100 host routers are ACPI platform devices; stock linux-nvidia has no driver for them
check "USB4/Thunderbolt host routers bound (docks, eGPU, Thunderbolt displays)" 'ls -d /sys/bus/thunderbolt/devices/domain*' WARN
check "SD reader GL9767 bound to sdhci-pci" 'lspci -k -d 17a0:9767 | grep -q "in use: sdhci-pci"' WARN

echo "== Memory, security, firmware"
mt=$(awk '/^MemTotal/ {print int($2 / 1048576)}' /proc/meminfo)
[ "${mt:-0}" -ge 100 ] && OK "$mt GiB RAM visible" ||
	WARN "only ${mt} GiB RAM visible: the firmware's GPU carve-out is not reclaimed (docs/hardware-extra.md)"
check "TPM 2.0 (tpm_crb over FF-A)" 'test -c /dev/tpmrm0' WARN
if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
	check "Secure Boot: DKMS key (MOK) enrolled (install/17-secure-boot.sh)" 'mokutil --test-key /var/lib/shim-signed/mok/MOK.der 2>&1 | grep -q "already enrolled"'
	for m in proart_battery proart_audio hid_asus spi_hid_acpi; do
		modinfo -F filename $m 2>/dev/null | grep -q /updates/ || continue
		check "Secure Boot: $m is signed" "[ -n \"\$(modinfo -F sig_key $m)\" ]"
	done
else
	OK "Secure Boot off (unsigned DKMS modules load)"
fi
check "firmware update table (ESRT) visible to fwupd" 'test -d /sys/firmware/efi/esrt/entries/entry0' WARN

echo "== DGX stack (install/13-dgx-stack.sh, optional)"
if [ -f /etc/apt/sources.list.d/proart-cuda.sources ]; then
	OK "CUDA repository: $(awk '/^URIs:/{print $2}' /etc/apt/sources.list.d/proart-cuda.sources)"
	check "CUDA repo cannot replace the display driver (pin -1)" 'grep -q "Pin-Priority: -1" /etc/apt/preferences.d/proart-cuda'
	# the driver must keep coming from the Ubuntu archive (prebuilt for linux-nvidia)
	dpkg -s libnvidia-compute >/dev/null 2>&1 &&
		FAIL "NVIDIA driver libraries from the CUDA repo are installed (libnvidia-compute): the archive driver was replaced" ||
		OK "NVIDIA driver from the Ubuntu archive ($(dpkg-query -W -f='${Package} ' 'nvidia-utils-*' 2>/dev/null))"
	NVCC=$(ls /usr/local/cuda/bin/nvcc 2>/dev/null || ls /usr/local/cuda-*/bin/nvcc 2>/dev/null | sort -V | tail -1)
	[ -n "$NVCC" ] && OK "CUDA toolkit $("$NVCC" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')" || WARN "CUDA toolkit not installed"
	command -v nvcc >/dev/null || [ -z "$NVCC" ] || WARN "nvcc not in PATH (log in again; /etc/profile.d/proart-cuda.sh)"
	ldconfig -p | grep -q libcudnn.so.9 && OK "cuDNN 9" || WARN "cuDNN not installed"
	ldconfig -p | grep -q libnccl.so.2 && OK "NCCL" || WARN "NCCL not installed"
fi
if command -v nvidia-ctk >/dev/null; then
	OK "NVIDIA Container Toolkit $(nvidia-ctk --version 2>/dev/null | sed -n 's/.*version \([0-9.]*\).*/\1/p' | head -1)"
	check "CDI spec lists the GPU (/etc/cdi/nvidia.yaml)" 'nvidia-ctk cdi list 2>/dev/null | grep -q "nvidia.com/gpu=all"'
fi
if command -v docker >/dev/null; then
	check "user in the docker group" 'id -nG | grep -qw docker' WARN
	check "Docker running" 'systemctl is-active docker'
	check "Docker has CDI enabled" 'docker info --format "{{.CDISpecDirs}}" 2>/dev/null | grep -q /etc/cdi' WARN
	# runs only when the image is already present (no download from a health check)
	docker image inspect ubuntu:26.04 >/dev/null 2>&1 &&
		check "GPU inside a container (CDI)" 'docker run --rm --device nvidia.com/gpu=all ubuntu:26.04 nvidia-smi -L' WARN
fi
[ -f /etc/security/limits.d/90-proart-dgx.conf ] &&
	check "memlock unlimited (DGX Spark limit; log in again)" '[ "$(ulimit -l)" = unlimited ]' WARN

echo "== Power saving"
# powersupersave (L1.2) made sleeps of more than a few minutes hang on resume
check "PCIe ASPM policy not powersupersave (long sleeps would hang)" '! grep -q "\[powersupersave\]" /sys/module/pcie_aspm/parameters/policy'

echo "== Updates"
# install/11-protect.sh
check "UCM profile protected against alsa-ucm-conf updates (install/11-protect.sh)" 'dpkg-divert --list "*mt8901-soundwir*" | grep -q mt8901' WARN
check "apt hook keeps the setup across package updates (install/11-protect.sh)" 'test -x /usr/local/sbin/proart-after-apt -a -f /etc/apt/apt.conf.d/80-proart-p16' WARN
ls /usr/share/alsa/ucm2/MediaTek/mt8901-soundwir/*.distrib >/dev/null 2>&1 &&
	WARN "alsa-ucm-conf now ships its own mt8901-soundwir profile (*.distrib next to the ProArt copy): compare them"
nomod=$(for k in $(ls /lib/modules); do [ -d /lib/modules/$k/build ] || continue
	dkms status proart-battery -k "$k" 2>/dev/null | grep -q installed || echo "$k"; done | tr '\n' ' ')
[ -z "$nomod" ] && OK "ProArt modules built for every installed kernel" || WARN "no ProArt modules for kernel(s) $nomod (install/11-protect.sh builds them)"

echo "== Network"
check "Wi-Fi connected" 'nmcli -t -f TYPE,STATE dev | grep -q "^wifi:connected"' WARN
check "Bluetooth controller" 'test -n "$(ls /sys/class/bluetooth 2>/dev/null)"' WARN

echo "== Kernel log"
# messages every boot of this firmware/kernel prints; they do not indicate a problem
known='of_root node is NULL|Illegal GSI2 translation|mtk_pwrap .*Not find device config data|No MSC devices found|device returned incorrect report|NVM\._STA|region initialization: \[PCI_Config\]|driver name too long|no backend DAIs enabled for DL2_FE|^$'
n=$(journalctl -k -b -p 3 --no-pager -o cat 2>/dev/null | grep -cvE "$known")
[ "$n" -lt 5 ] && OK "$n unexpected kernel errors since boot" || WARN "$n unexpected kernel errors since boot (journalctl -k -b -p 3)"

echo
echo "Result: $ok OK, $warn WARN, $fail FAIL"
[ $fail -eq 0 ]
