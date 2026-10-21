#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 6: touchpad (libinput quirk, haptic click feedback)
#
# The PixArt 093A:4F01 touchpad reports pressure values of ~80-120 on a declared range of 0-65535.
# libinput detects touches by a pressure threshold (~10 % of the range) and never sees a finger:
# no pointer movement, no tapping. The quirk hides the pressure axes from libinput.
# The pad's haptic actuator has only a manual trigger, so nothing vibrates on a click unless the
# host triggers it: proart-haptic.service does that (settings: /etc/default/proart-haptic).
# Remove: rm /etc/libinput/local-overrides.quirks (or the [ASUS ProArt P16 ...] section); log out/in;
#         systemctl disable --now proart-haptic; rm /etc/systemd/system/proart-haptic.service \
#         /usr/local/bin/proart-haptic /etc/default/proart-haptic
# Run with: sudo bash install/06-touchpad.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
Q=/etc/libinput/local-overrides.quirks

install -d /etc/libinput
if [ -f "$Q" ] && ! grep -q "ASUS ProArt P16 H7607BA Touchpad" "$Q"; then
	{ echo; cat "$REPO/config/libinput/local-overrides.quirks"; } >> "$Q"
else
	install -m 644 "$REPO/config/libinput/local-overrides.quirks" "$Q"
fi
cat "$Q"

echo "== Check: does the quirk match?"
apt-get install -y libinput-tools >/dev/null
for ev in /sys/bus/i2c/devices/i2c-3030443150435341:00/0018:*/input/input*/event*; do
	dev=/dev/input/$(basename "$ev")
	if udevadm info -q property -n "$dev" | grep -q '^ID_INPUT_TOUCHPAD=1'; then
		echo "$dev:"
		libinput quirks list "$dev" || true
	fi
done

echo "== Haptic click feedback (proart-haptic.service)"
install -m 755 "$REPO/drivers/proart-haptic/proart-haptic" /usr/local/bin/
install -m 644 "$REPO/drivers/proart-haptic/proart-haptic.service" /etc/systemd/system/
[ -f /etc/default/proart-haptic ] || install -m 644 "$REPO/drivers/proart-haptic/proart-haptic.default" /etc/default/proart-haptic
systemctl daemon-reload
systemctl enable proart-haptic
systemctl restart proart-haptic
sleep 1
systemctl --no-pager --lines=3 status proart-haptic | tail -4

echo
echo "Done. The libinput quirk takes effect after logging out and back in (or a reboot)."
echo "Clicks vibrate right away; try the waveforms with: sudo proart-haptic test"
