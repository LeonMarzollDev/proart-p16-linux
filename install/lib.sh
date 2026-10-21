#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Shared helpers for the ProArt P16 install scripts. Sourced, not executed.

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

require_root() {
	[ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo or pkexec)"; exit 1; }
}

# The desktop user who started the script through sudo/pkexec.
target_user() {
	local u="${SUDO_USER:-}"
	if [ -z "$u" ] && [ -n "${PKEXEC_UID:-}" ]; then
		u=$(getent passwd "$PKEXEC_UID" | cut -d: -f1)
	fi
	[ -n "$u" ] || u=$(logname 2>/dev/null || true)
	if [ -z "$u" ] || [ "$u" = root ]; then
		echo "Cannot determine the desktop user; run this through sudo or pkexec from your session" >&2
		exit 1
	fi
	echo "$u"
}

user_home() {
	getent passwd "$1" | cut -d: -f6
}

# A failing third-party source (e.g. a mirror in the middle of a sync) must not abort the script.
apt_update() {
	apt-get update || echo "Warning: not every package source could be refreshed - continuing"
}

# Temporary access to <codename>-proposed, pinned to priority 1: only explicitly requested
# package versions are taken from it. Always removed again on exit (also on errors).
PROPOSED_SRC=/etc/apt/sources.list.d/proart-proposed-tmp.sources
PROPOSED_PIN=/etc/apt/preferences.d/proart-proposed-tmp

proposed_disable() {
	rm -f "$PROPOSED_SRC" "$PROPOSED_PIN"
}

proposed_enable() {
	local codename uri
	codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
	uri=$(awk '/^URIs:/ {print $2; exit}' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true)
	[ -n "$uri" ] || uri=http://archive.ubuntu.com/ubuntu/
	trap proposed_disable EXIT
	cat > "$PROPOSED_SRC" <<EOF
Types: deb
URIs: $uri
Suites: $codename-proposed
Components: main restricted
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
	cat > "$PROPOSED_PIN" <<EOF
Package: *
Pin: release a=$codename-proposed
Pin-Priority: 1
EOF
	apt_update
}

# GRUB menu entry id of an installed kernel, as "<submenu id>><entry id>" for grub-set-default.
grub_entry_for() {
	local krel="$1" cfg=/boot/grub/grub.cfg sub ent
	sub=$(grep -oE "submenu .*\\\$menuentry_id_option 'gnulinux-advanced-[^']+'" "$cfg" | head -1 |
		grep -oE "'gnulinux-advanced-[^']+'" | tr -d "'")
	ent=$(grep -oE "'gnulinux-$krel-advanced-[^']+'" "$cfg" | head -1 | tr -d "'")
	[ -n "$sub" ] && [ -n "$ent" ] && echo "$sub>$ent"
}
