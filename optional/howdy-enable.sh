#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - optional: Howdy stage 2: face login for login screen, lock screen and sudo
#
# Runs a recognition test first; only on success Howdy is added to /etc/pam.d/common-auth through
# pam-auth-update. The password always stays as fallback ([success=end default=ignore]).
# Admin dialogs (polkit/pkexec) are skipped: their helper runs in a systemd sandbox without camera
# access, Howdy fails there and GNOME's dialog hangs. To include them, see optional/howdy-polkit.sh.
# The GNOME login keyring is encrypted with your password and is NOT unlocked by a face login.
# Remove: pam-auth-update --disable howdy; rm /usr/share/pam-configs/howdy
# Run with: sudo bash optional/howdy-enable.sh   (look into the camera)
set -euo pipefail
. "$(dirname "$0")/../install/lib.sh"
require_root
USERNAME=$(target_user)
PY=/opt/howdy-venv/bin/python3
COMPARE=/usr/local/lib/aarch64-linux-gnu/howdy/compare.py
PAMDIR=/usr/lib/aarch64-linux-gnu/security

echo "== 1/3 Recognition test - look into the camera NOW"
set +e
"$PY" "$COMPARE" "$USERNAME"
rc=$?
set -e
case $rc in
	0)  echo "Face recognised." ;;
	10) echo "No face model - first run: /usr/local/bin/howdy -U $USERNAME -y add"; exit 1 ;;
	11) echo "Timeout, face not recognised - nothing changed. Try again or add another model."; exit 1 ;;
	13) echo "Image too dark - nothing changed."; exit 1 ;;
	*)  echo "Test failed (code $rc) - nothing changed."; exit 1 ;;
esac

echo "== 2/3 Add Howdy to PAM (backup: /etc/pam.d/common-auth.before-howdy)"
cp -a /etc/pam.d/common-auth /etc/pam.d/common-auth.before-howdy
cat > /usr/share/pam-configs/howdy <<EOF
Name: Howdy (face recognition, not for polkit admin dialogs)
Default: yes
Priority: 512
Auth-Type: Primary
Auth:
	[success=1 default=ignore]	pam_succeed_if.so service = polkit-1 quiet
	[success=end default=ignore]	$PAMDIR/pam_howdy.so
EOF
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable howdy
grep -n "pam_succeed_if\|pam_howdy\|pam_unix" /etc/pam.d/common-auth

echo "== 3/3 Check"
if ! grep -q "pam_howdy.so" /etc/pam.d/common-auth || ! grep -q "pam_unix.so" /etc/pam.d/common-auth; then
	echo "Unexpected result - restoring the backup"
	cp -a /etc/pam.d/common-auth.before-howdy /etc/pam.d/common-auth
	exit 1
fi

echo
echo "Done. Face recognition is active for login, lock screen and sudo (password as fallback)."
echo "Disable: pam-auth-update --disable howdy"
