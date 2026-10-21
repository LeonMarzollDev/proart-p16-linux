#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - step 5: keyboard 0B05:4B42 (patched hid-asus, DKMS)
#
#  - registers the keyboard backlight without asus-wmi (LED asus::kbd_backlight, levels 0-3) and
#    sends the OOBE-disable sequence on the way: the backlight stops fading in and out by itself
#  - the backlight key (F4) cycles off -> 1 -> 2 -> 3 -> off and the desktop shows the level
#  - Fn-lock via Fn+Esc; default here: media keys first (as on Windows). The state is exposed in
#    /sys/bus/hid/devices/*0B05:4B42*/fn_lock for the top-bar indicator proart-fnlock (user/)
# Source: NVIDIA NV-Kernels 26.04_linux-nvidia drivers/hid/hid-asus.c + Omarchy patches 0002-0004
#         + patches 0005 (backlight hotkey) and 0006 (fn_lock in sysfs) from this repository.
# Remove: dkms remove hid-asus-proart/<version> --all; rm -rf /usr/src/hid-asus-proart-* \
#         /etc/modprobe.d/hid-asus-proart.conf; update-initramfs -u
# Run with: sudo bash install/05-keyboard.sh
set -euo pipefail
. "$(dirname "$0")/lib.sh"
require_root
KREL=$(uname -r)
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$REPO/drivers/hid-asus-proart/dkms.conf")
SRC=/usr/src/hid-asus-proart-$VER
TUSER=$(target_user)
TUID=$(id -u "$TUSER")

echo "== 1/5 DKMS package hid-asus-proart $VER"
apt_update
apt-get install -y dkms build-essential
for old in $(dkms status hid-asus-proart 2>/dev/null | sed -n 's#^hid-asus-proart/\([^,]*\),.*#\1#p' | sort -u); do
	dkms remove "hid-asus-proart/$old" --all || true
done
rm -rf /usr/src/hid-asus-proart-*
install -d "$SRC"
install -m 644 "$REPO"/drivers/hid-asus-proart/{hid-asus.c,hid-ids.h,Makefile,dkms.conf} "$SRC/"
dkms add "hid-asus-proart/$VER"
dkms build "hid-asus-proart/$VER" -k "$KREL"
dkms install "hid-asus-proart/$VER" -k "$KREL"
modinfo -F filename hid_asus

echo "== 2/5 F-row: media keys first (Fn+Esc toggles); libraries for the Fn-lock indicator"
echo "options hid_asus fnlock_default=0" > /etc/modprobe.d/hid-asus-proart.conf
apt-get install -y gir1.2-ayatanaappindicator3-0.1 gir1.2-notify-0.7 \
	|| echo "Warning: indicator libraries not installed (proart-fnlock falls back to notifications)"

echo "== 3/5 Reload the driver (the keyboard is gone for ~1 s)"
modprobe -r hid_asus
modprobe hid_asus
sleep 2
dmesg | grep -iE "asus 0018:0B05:4B42|OOBE|kbd_backlight" | tail -5
ls /sys/class/leds/ | grep -i kbd || echo "(no kbd_backlight LED found)"
ls /sys/bus/hid/devices/*0B05:4B42*/fn_lock 2>/dev/null || echo "(no fn_lock attribute found)"

echo "== 4/5 Let UPower and GNOME pick up the keyboard backlight"
# Both only look for keyboard backlights at startup. gsd-power refuses a manual restart but is
# Restart=on-failure, so a SIGKILL makes systemd start it again. Not needed after a reboot.
systemctl daemon-reload
systemctl restart upower
sudo -u "$TUSER" XDG_RUNTIME_DIR="/run/user/$TUID" \
	systemctl --user kill -s SIGKILL org.gnome.SettingsDaemon.Power.service 2>/dev/null || true

echo "== 5/5 Update the initramfs"
update-initramfs -u -k "$KREL"

echo
echo "Done. Run user/install-user.sh (as $TUSER) for the Fn-lock top-bar indicator."
