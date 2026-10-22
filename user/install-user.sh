#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - user-level part (run as your normal user, NOT as root)
#  - ~/.local/bin: proart-eq (tone control), proart-tweeter (tweeter routing + headphone jack),
#                  pw-id (PipeWire node id helper), proart-fnlock (Fn-lock top-bar indicator),
#                  ui-screenshot / ui-tree (optional desktop helpers)
#  - PipeWire 2-way crossover "ProArt P16 Speakers", WirePlumber device names, mute kept across reboots
#  - environment for NVIDIA VA-API video decoding
#  - systemd user service proart-tweeter, autostart entry for proart-fnlock
# Requires install/03-audio.sh (and install/05-keyboard.sh for the Fn-lock indicator) to have been run first.
# Remove: ./install-user.sh --remove
set -euo pipefail
[ "$(id -u)" -ne 0 ] || { echo "Run this as your normal user, not as root"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
BIN="$HOME/.local/bin"
PW="$HOME/.config/pipewire/pipewire.conf.d"
WP="$HOME/.config/wireplumber/wireplumber.conf.d"
ENVD="$HOME/.config/environment.d"
UNIT="$HOME/.config/systemd/user"
AUTOSTART="$HOME/.config/autostart"
TOOLS="proart-eq proart-tweeter proart-fnlock pw-id ui-screenshot ui-tree easyeffects-start"
# WirePlumber 0.5 forgets the mute of filter sinks such as "ProArt P16 Speakers" (muted before a
# reboot = unmuted after it): they have a second Props object (the filter's controls) without
# volume/mute, which overwrites the stored values with nil. A copy of its state-stream.lua with that
# check fixed goes to the user's data dir, which WirePlumber prefers over /usr/share.
# Run this script again after WirePlumber updates (tools/check.sh tells when).
WPS_SYS=/usr/share/wireplumber/scripts/node/state-stream.lua
WPS="$HOME/.local/share/wireplumber/scripts/node/state-stream.lua"

restart_audio() {
	systemctl --user restart pipewire pipewire-pulse wireplumber
	sleep 4
}

if [ "${1:-}" = "--remove" ]; then
	echo "== Removing the user-level ProArt P16 files"
	systemctl --user disable --now proart-tweeter.service 2>/dev/null || true
	pkill -f "$BIN/proart-fnlock" 2>/dev/null || true
	rm -f "$AUTOSTART/proart-fnlock.desktop"
	for t in $TOOLS; do rm -f "$BIN/$t"; done
	rm -f "$PW/60-proart-2way.conf" "$WP/51-proart-names.conf" "$ENVD/90-nvidia-vaapi.conf" "$UNIT/proart-tweeter.service" "$WPS" \
	"$UNIT/org.gnome.Shell@.service.d/50-proart-uclamp.conf"
	systemctl --user daemon-reload
	restart_audio
	echo "Done (log out and back in to drop the VA-API environment)."
	exit 0
fi

echo "== 1/5 Tools -> $BIN"
install -d "$BIN"
for t in $TOOLS; do install -m 755 "$HERE/bin/$t" "$BIN/$t"; done

echo "== 2/5 PipeWire crossover, WirePlumber names, VA-API environment"
install -d "$PW" "$WP" "$ENVD"
install -m 644 "$REPO/config/pipewire/60-proart-2way.conf" "$PW/"
install -m 644 "$REPO/config/wireplumber/51-proart-names.conf" "$WP/"
# 51-proart-names.conf hides the woofer port; the woofer amps are then switched by the UCM profile
diff -rq "$REPO/config/ucm2/MediaTek/mt8901-soundwir" /usr/share/alsa/ucm2/MediaTek/mt8901-soundwir >/dev/null 2>&1 ||
	echo "WARNING: the installed UCM profile is older than this repo, the woofers stay silent: run sudo bash install/03-audio.sh"
install -m 644 "$REPO/config/environment.d/90-nvidia-vaapi.conf" "$ENVD/"
if [ -f "$WPS_SYS" ]; then
	install -d "$(dirname "$WPS")"
	sed -e 's/if props\.volume ~= stored_values\.volume then/if props.volume ~= nil and props.volume ~= stored_values.volume then/' \
	    -e 's/if props\.mute ~= stored_values\.mute then/if props.mute ~= nil and props.mute ~= stored_values.mute then/' \
	    "$WPS_SYS" > "$WPS.new"
	if [ "$(grep -c '~= nil and props\.\(volume\|mute\) ~= stored_values' "$WPS.new")" = 2 ]; then
		mv "$WPS.new" "$WPS"
		echo "WirePlumber: mute of the speakers is kept across reboots"
	else
		rm -f "$WPS.new" "$WPS"
		echo "WirePlumber's state-stream.lua has changed - mute fix not applied (maybe fixed upstream)"
	fi
fi

echo "== 3/5 systemd user service proart-tweeter"
install -d "$UNIT"
install -m 644 "$HERE/systemd/proart-tweeter.service" "$UNIT/"
# GNOME Shell on the fast cores (smooth at 120-180 Hz and with several monitors); from the next
# login on, and right away for the running shell
install -D -m 644 "$REPO/config/systemd-user/org.gnome.Shell@.service.d/50-proart-uclamp.conf" \
	"$UNIT/org.gnome.Shell@.service.d/50-proart-uclamp.conf"
pgrep -x gnome-shell >/dev/null && uclampset -m 768 -a -p "$(pgrep -x gnome-shell)" || true
systemctl --user daemon-reload
restart_audio
systemctl --user enable --now proart-tweeter.service
sleep 3

echo "== 4/5 Levels and defaults"
# both hardware sinks stay at 100 %; the volume is controlled on "ProArt P16 Speakers" only
for n in alsa_output.platform-mtk_sdw_mc.HiFi__Speaker__sink \
         alsa_output.platform-mtk_sdw_mc.HiFi__Headphones__sink proart_speakers; do
	id=$("$BIN/pw-id" "$n")
	[ -n "$id" ] && wpctl set-volume "$id" 1.0
done
mic=$("$BIN/pw-id" alsa_input.platform-mtk_sdw_mc.HiFi__Mic__source)
[ -n "$mic" ] && wpctl set-default "$mic"
wpctl inspect @DEFAULT_AUDIO_SINK@ | grep " node.description" || true
wpctl inspect @DEFAULT_AUDIO_SOURCE@ | grep " node.description" || true
"$BIN/proart-eq"

echo "== 5/5 Fn-lock indicator (top bar + notification on Fn+Esc)"
install -d "$AUTOSTART"
sed "s|^Exec=.*|Exec=$BIN/proart-fnlock|" "$HERE/autostart/proart-fnlock.desktop" > "$AUTOSTART/proart-fnlock.desktop"
if ls /sys/bus/hid/devices/*0B05:4B42*/fn_lock >/dev/null 2>&1; then
	pkill -f "$BIN/proart-fnlock" 2>/dev/null || true
	setsid -f "$BIN/proart-fnlock" >/dev/null 2>&1 < /dev/null
	echo "proart-fnlock started"
else
	echo "fn_lock attribute not found - run install/05-keyboard.sh first; the indicator starts at the next login"
fi

echo
echo "Done. Log out and back in once so the VA-API environment reaches Firefox."
