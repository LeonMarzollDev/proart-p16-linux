#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: Howdy also for admin dialogs (polkit / pkexec)
#
# SECURITY WARNING: this weakens a security boundary on purpose.
#  - Admin rights would be granted by face recognition, which is weaker than a password
#    (look-alikes, someone holding the laptop up to you).
#  - The polkit agent helper normally runs in a strict systemd sandbox without any devices. This
#    drop-in gives it access to cameras (char-video4linux) and disables MemoryDenyWriteExecute for
#    Python/dlib. Everything else (read-only system, no network, no home, syscall filter) stays.
# Recommended alternative: keep admin dialogs on the password and use sudo in a terminal.
#
# Enable:  sudo bash optional/howdy-polkit.sh
# Revert:  sudo bash optional/howdy-polkit.sh --revert   (in a terminal, Ctrl+Alt+T)
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
DROPIN_DIR=/etc/systemd/system/polkit-agent-helper@.service.d
DROPIN=$DROPIN_DIR/10-howdy-camera.conf
PROFILE=/usr/share/pam-configs/howdy
PAMDIR=/usr/lib/aarch64-linux-gnu/security

write_profile() {	# $1 = skip polkit (yes/no)
	{
		echo "Name: Howdy (face recognition)"
		echo "Default: yes"
		echo "Priority: 512"
		echo "Auth-Type: Primary"
		echo "Auth:"
		[ "$1" = yes ] && printf '\t[success=1 default=ignore]\tpam_succeed_if.so service = polkit-1 quiet\n'
		printf '\t[success=end default=ignore]\t%s/pam_howdy.so\n' "$PAMDIR"
	} > "$PROFILE"
	DEBIAN_FRONTEND=noninteractive pam-auth-update --enable howdy
}

if [ "${1:-}" = "--revert" ]; then
	echo "== Revert: remove the drop-in, admin dialogs use the password only again"
	rm -f "$DROPIN"
	rmdir "$DROPIN_DIR" 2>/dev/null || true
	systemctl daemon-reload
	write_profile yes
	grep -n "pam_succeed_if\|pam_howdy\|pam_unix" /etc/pam.d/common-auth
	echo "Done (reverted)."
	exit 0
fi

echo "== 1/2 Camera access for the polkit agent helper"
cp -a /etc/pam.d/common-auth /etc/pam.d/common-auth.before-howdy-polkit
install -d "$DROPIN_DIR"
cat > "$DROPIN" <<'EOF'
# Howdy: allow cameras in the polkit agent helper (see optional/howdy-polkit.sh)
[Service]
PrivateDevices=no
DevicePolicy=closed
DeviceAllow=/dev/null rw
DeviceAllow=char-video4linux rw
MemoryDenyWriteExecute=no
EOF
systemctl daemon-reload
systemctl show polkit-agent-helper@x.service -p PrivateDevices -p DevicePolicy -p DeviceAllow -p MemoryDenyWriteExecute

echo "== 2/2 Howdy PAM profile without the polkit exception"
write_profile no
grep -n "pam_succeed_if\|pam_howdy\|pam_unix" /etc/pam.d/common-auth
if ! grep -q "pam_unix.so" /etc/pam.d/common-auth; then
	echo "Password line missing - restoring the backup"
	cp -a /etc/pam.d/common-auth.before-howdy-polkit /etc/pam.d/common-auth
	exit 1
fi

echo
echo "Done. Test:  pkexec true   -> look into the camera."
echo "If the admin dialog hangs: terminal (Ctrl+Alt+T) -> sudo bash optional/howdy-polkit.sh --revert"
