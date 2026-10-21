#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 - optional: mouse/keyboard automation under GNOME/Wayland (ydotool)
#
# ydotoold runs as a system service with access to /dev/uinput; only the desktop user may use its
# socket (/run/ydotoold/socket, mode 0600). Useful for scripted testing/remote assistance together
# with user/bin/ui-screenshot (xdg-desktop-portal) and user/bin/ui-tree (AT-SPI).
# NOTE: every program running as that user can send input through it.
# Remove: systemctl disable --now ydotoold; rm /etc/systemd/system/ydotoold.service; apt remove ydotool
# Run with: sudo bash optional/ui-control.sh
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
USERNAME=$(target_user)
UHOME=$(user_home "$USERNAME")
UID_GID="$(id -u "$USERNAME"):$(id -g "$USERNAME")"

echo "== 1/3 ydotool"
apt_update
apt-get install -y ydotool

echo "== 2/3 ydotoold service (socket only for $USERNAME)"
cat > /etc/systemd/system/ydotoold.service <<EOF
[Unit]
Description=ydotool daemon (virtual mouse/keyboard for $USERNAME)

[Service]
ExecStart=/usr/bin/ydotoold --socket-path=/run/ydotoold/socket --socket-perm=0600 --socket-own=$UID_GID
RuntimeDirectory=ydotoold
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ydotoold.service
sleep 1
ls -l /run/ydotoold/socket

echo "== 3/3 Socket path for the session; mask the package's per-user ydotool service"
install -d -o "$USERNAME" -g "$USERNAME" "$UHOME/.config/environment.d" "$UHOME/.config/systemd/user"
echo "YDOTOOL_SOCKET=/run/ydotoold/socket" > "$UHOME/.config/environment.d/91-ydotool.conf"
ln -sfn /dev/null "$UHOME/.config/systemd/user/ydotool.service"
chown -h "$USERNAME:" "$UHOME/.config/environment.d/91-ydotool.conf" "$UHOME/.config/systemd/user/ydotool.service"
# GNOME accessibility (AT-SPI) for ui-tree
sudo -u "$USERNAME" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$USERNAME")/bus" \
	gsettings set org.gnome.desktop.interface toolkit-accessibility true || true

echo
echo "Done. ydotool is ready (YDOTOOL_SOCKET=/run/ydotoold/socket, active after the next login)."
echo "Absolute mouse positioning needs pointer acceleration off (see 'ydotool mousemove --help')."
