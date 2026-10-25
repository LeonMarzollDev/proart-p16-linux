#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 17 (optional, UNVERIFIED on hardware): Secure Boot with the
# out-of-tree modules of this project
#
# The laptop ships with Secure Boot on (Windows 11, Pluton, TPM 2.0 over FF-A). Ubuntu boots under
# Secure Boot through shim (Microsoft UEFI CA) + Canonical-signed GRUB/kernel, and the prebuilt
# linux-modules-nvidia-615-open-* are Canonical-signed too. What is NOT signed by Canonical is
# everything DKMS builds here: proart_battery, proart_audio, proart_s2idle, hid-asus-proart, spi-hid,
# proart-sdw-mtk (soundwire-mtk). With Secure
# Boot on, Ubuntu's kernel runs in lockdown "integrity" mode and refuses unsigned modules, so the
# battery, audio and keyboard fixes silently stop loading. DKMS signs with the machine-owner key
# (MOK) /var/lib/shim-signed/mok/MOK.{priv,der}; this step makes sure that key exists, is enrolled
# in shim (one confirmation in the blue MokManager screen on the next boot) and that every ProArt
# module is signed with it.
#
# Also checked: whether the firmware db trusts the Microsoft UEFI CA (2011 or 2023) that signs
# shim. Some Windows-on-Arm laptops only trust the Windows CA by default; if neither is listed,
# shim cannot boot with Secure Boot on (enable "Microsoft 3rd-party UEFI CA" in the BIOS setup or
# turn Secure Boot off). Note: BitLocker on the Windows partition asks for its recovery key after
# any Secure Boot change - have it ready.
#
# Remove: mokutil --delete /var/lib/shim-signed/mok/MOK.der (confirm on next boot)
# Run with: sudo bash install/17-secure-boot.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
MOK=/var/lib/shim-signed/mok

apt-get install -y mokutil shim-signed openssl >/dev/null

echo "== 1/4 Secure Boot state"
sb=$(mokutil --sb-state 2>&1 || true)
echo "$sb"
echo "lockdown: $(cat /sys/kernel/security/lockdown 2>/dev/null || echo n/a)"
if mokutil --db 2>/dev/null | grep -qE 'Microsoft Corporation UEFI CA 2011|Microsoft UEFI CA 2023'; then
	echo "firmware db trusts the Microsoft UEFI CA (shim can boot with Secure Boot on)"
else
	echo "Warning: Microsoft UEFI CA not found in db (or db unreadable) - shim may not boot with Secure Boot on"
fi

echo "== 2/4 Machine-owner key for DKMS"
if [ ! -f "$MOK/MOK.der" ] || [ ! -f "$MOK/MOK.priv" ]; then
	update-secureboot-policy --new-key || {
		install -d -m 700 "$MOK"
		openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 -outform DER \
			-keyout "$MOK/MOK.priv" -out "$MOK/MOK.der" -subj "/CN=$(hostname) DKMS module signing key/"
		chmod 600 "$MOK/MOK.priv"
	}
fi
openssl x509 -inform DER -in "$MOK/MOK.der" -noout -subject -enddate
SERIAL=$(openssl x509 -inform DER -in "$MOK/MOK.der" -noout -serial | cut -d= -f2 | tr A-F a-f | sed 's/^0*//')

echo "== 3/4 Enrolled in shim?"
if mokutil --test-key "$MOK/MOK.der" 2>&1 | grep -q 'is already enrolled'; then
	echo "MOK is enrolled"
elif echo "$sb" | grep -q 'SecureBoot enabled' || [ "${FORCE_ENROLL:-}" = 1 ]; then
	echo "Enrolling the MOK: choose a one-time password now; on the next boot pick"
	echo "'Enroll MOK' -> 'Continue' -> 'Yes' and type that password."
	if [ -t 0 ]; then mokutil --import "$MOK/MOK.der"; else
		echo "(no terminal - run: sudo mokutil --import $MOK/MOK.der)"; fi
else
	echo "Secure Boot is off: enrolling is not needed now (FORCE_ENROLL=1 to do it anyway before turning it on)"
fi

echo "== 4/4 ProArt modules signed with this key?"
# modinfo's sig_key is the signing certificate's serial number
NEED_REBUILD=""
for m in proart_battery proart_audio proart_s2idle hid_asus spi_hid spi_hid_acpi soundwire_mtk; do
	f=$(modinfo -F filename "$m" 2>/dev/null) || continue
	case "$f" in */updates/*) ;; *) continue ;; esac
	sig=$(modinfo -F sig_key "$m" 2>/dev/null | tr -d ':' | tr A-F a-f | sed 's/^0*//')
	if [ -z "$sig" ]; then
		echo "  $m: NOT signed -> rebuilding"; NEED_REBUILD=1
	elif [ "$sig" = "$SERIAL" ]; then
		echo "  $m: signed by the MOK ($(modinfo -F signer "$m"))"
	else
		echo "  $m: signed by '$(modinfo -F signer "$m")', not by this MOK -> rebuilding"; NEED_REBUILD=1
	fi
done
if [ -n "$NEED_REBUILD" ]; then
	KREL=$(uname -r)
	for p in $(dkms status -k "$KREL" 2>/dev/null | sed -n 's#^\([^/]*\)/\([^,]*\),.*installed.*#\1/\2#p' |
			grep -E '^(proart-battery|proart-audio|proart-s2idle|proart-sdw-mtk|hid-asus-proart|spi-hid)/'); do
		dkms install --force "$p" -k "$KREL"
	done
	update-initramfs -u -k "$KREL"
fi
echo
echo "Done. Hibernation stays unavailable: linux-nvidia is built without CONFIG_HIBERNATION (and lockdown"
echo "would block it under Secure Boot anyway); suspend is s2idle only."
