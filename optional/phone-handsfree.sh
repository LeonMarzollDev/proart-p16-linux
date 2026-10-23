#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 - optional: phone calls through a paired mobile phone (Bluetooth hands-free)
#
# The laptop works like a car kit for a paired phone: GNOME Calls rings for incoming calls and
# can dial, and the call audio uses the laptop's speakers and microphone. PipeWire 1.6 handles the
# Bluetooth hands-free profile itself (bluez5.telephony-*); user/bin/proart-phone-bridge presents
# the phone to GNOME Calls as an oFono modem (PipeWire's own oFono emulation lacks what Calls
# needs) and replaces callaudiod for the mute button. Do not install the ofono package: it
# conflicts with ModemManager, and apt then removes GNOME Calls.
# Afterwards pair the phone in Settings -> Bluetooth and allow phone calls on the phone.
# Remove: systemctl --user disable --now proart-phone-bridge; rm ~/.local/bin/proart-phone-bridge \
#         ~/.config/systemd/user/calls-daemon.service.d/50-gapplication-service.conf \
#   ~/.config/systemd/user/proart-phone-bridge.service \
#   ~/.local/share/dbus-1/services/org.mobian_project.CallAudio.service \
#   ~/.config/wireplumber/wireplumber.conf.d/52-proart-bluetooth-handsfree.conf;
#   sudo rm /etc/dbus-1/system.d/proart-phone-bridge.conf
# Run with: sudo bash optional/phone-handsfree.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
TUSER=$(target_user)
TUID=$(id -u "$TUSER")
THOME=$(user_home "$TUSER")
as_user() { sudo -u "$TUSER" XDG_RUNTIME_DIR="/run/user/$TUID" \
	DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TUID/bus" "$@"; }

echo "== 1/3 GNOME Calls"
apt_update
DEBIAN_FRONTEND=noninteractive apt-get install -y gnome-calls

echo "== 2/3 System bus policy for the phone service"
install -m 644 "$REPO/config/dbus/proart-phone-bridge.conf" /etc/dbus-1/system.d/
systemctl daemon-reload
systemctl reload dbus

echo "== 3/3 Bridge, PipeWire hands-free settings and GNOME Calls' oFono plugin (user $TUSER)"
as_user install -D -m 755 "$REPO/user/bin/proart-phone-bridge" "$THOME/.local/bin/proart-phone-bridge"
as_user install -D -m 644 "$REPO/user/systemd/proart-phone-bridge.service" \
	"$THOME/.config/systemd/user/proart-phone-bridge.service"
as_user install -D -m 644 "$REPO/config/dbus/org.mobian_project.CallAudio.service" \
	"$THOME/.local/share/dbus-1/services/org.mobian_project.CallAudio.service"
as_user install -D -m 644 "$REPO/config/wireplumber/52-proart-bluetooth-handsfree.conf" \
	"$THOME/.config/wireplumber/wireplumber.conf.d/52-proart-bluetooth-handsfree.conf"
# Ubuntu's calls-daemon.service still passes --daemon, which gnome-calls 49 rejects: Calls would not
# run in the background and incoming calls would not ring
as_user install -D -m 644 "$REPO/config/systemd-user/calls-daemon.service.d/50-gapplication-service.conf" \
	"$THOME/.config/systemd/user/calls-daemon.service.d/50-gapplication-service.conf"
as_user gsettings set org.gnome.Calls autoload-plugins "['mm', 'sip', 'ofono']"
pkill -u "$TUSER" -x callaudiod || true
as_user systemctl --user daemon-reload
as_user systemctl --user restart wireplumber
# reenable: earlier versions were linked into default.target
as_user systemctl --user reenable proart-phone-bridge.service
as_user systemctl --user restart proart-phone-bridge.service
as_user systemctl --user reset-failed calls-daemon.service 2>/dev/null || true
as_user systemctl --user restart calls-daemon.service || true
sleep 3
as_user systemctl --user --no-pager --lines=4 status proart-phone-bridge | tail -4

echo
echo "Done. Pair your phone in Settings -> Bluetooth, allow phone calls on the phone, then open"
echo "GNOME Calls (\"Calls\"). Contacts: add your Google account in Settings -> Online Accounts."
