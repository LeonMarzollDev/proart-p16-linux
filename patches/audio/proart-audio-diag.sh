#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# ASUS ProArt P16 H7607BA - capture the audio state, to compare before and after a long s2idle sleep.
#
#   sudo bash patches/audio/proart-audio-diag.sh snapshot before     # right after boot, audio working
#   (close the lid / systemctl suspend for >= 10 minutes, wake up)
#   sudo bash patches/audio/proart-audio-diag.sh snapshot after
#   sudo bash patches/audio/proart-audio-diag.sh compare before after
#   sudo bash patches/audio/proart-audio-diag.sh recover [--try-clk]  # step-by-step recovery attempts
#
# Output: /var/log/proart-audio-diag/<tag>/ (plain text; nothing is uploaded anywhere).
# The snapshot only reads state, except that it plays 3 s of silence and records 3 s from the
# internal microphone through PipeWire to measure the real sample rates. See research/audio-suspend.md.
set -uo pipefail

OUT=/var/log/proart-audio-diag
SDW_DBG=/sys/kernel/debug/NVDA9100:00          # mtk-soundwire debugfs (bus_reset knob)
PWRAP=/sys/bus/platform/devices/NVDA6210:00/pwrap_power_ctrl_req
SDW_PINS="66 67 126 127 128 129 35"           # _CRS PinFunction pins of CNT0 (0x42 0x43 0x7e-0x81) + spk-id (0x23)

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

desktop_user() {
	local u="${SUDO_USER:-}"
	[ -n "$u" ] && [ "$u" != root ] || u=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="root"{print $3; exit}')
	echo "$u"
}
as_user() {
	local u uid
	u=$(desktop_user); [ -n "$u" ] || return 1
	uid=$(id -u "$u")
	runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid "$@"
}

card_index() { awk '/mt8901|mtk_sdw|sdw/ {print $1; exit}' /proc/asound/cards; }

# Real sample rate of a running PCM: hw_ptr advance over CLOCK_MONOTONIC (~3 s).
pcm_rate() {
	local st=$1 p1 p2 t1 t2
	p1=$(awk '/^hw_ptr/ {print $3}' "$st"); t1=$(date +%s.%N)
	sleep 3
	p2=$(awk '/^hw_ptr/ {print $3}' "$st"); t2=$(date +%s.%N)
	[ -n "$p1" ] && [ -n "$p2" ] || { echo "not running"; return; }
	awk -v a="$p1" -v b="$p2" -v s="$t1" -v e="$t2" 'BEGIN { printf "%.1f frames/s\n", (b-a)/(e-s) }'
}

snapshot() {
	local tag=$1 d c
	d=$OUT/$tag; rm -rf "$d"; mkdir -p "$d"
	c=$(card_index)
	{
		date -Is; uname -a; cat /proc/cmdline
		echo "--- last suspend"; journalctl -k -b --no-pager -g 'PM: suspend (entry|exit)|s2idle|PM: resume' | tail -6
	} > "$d/system.txt" 2>&1

	# kernel log of the audio stack (this boot)
	journalctl -k -b --no-pager -o short-monotonic \
		-g 'soundwire|sdw|NVDA9100|NVDA9022|mt8901|afe|cs35l56|cs42l43|cs_dsp|SSPM|sspm|power_wrap|pwrap|PLL|PM: suspend|PM: resume|s2idle' \
		> "$d/kernel.txt" 2>&1
	grep -E 'Timeout out waiting for PLL|pll_lost_lock|Failed|failed|error|timed out|Timed out|bus restart|no peripheral attached|FIRMWARE_MISSING|Calibration' \
		"$d/kernel.txt" > "$d/kernel-errors.txt"

	# module parameters
	for m in soundwire_mtk snd_soc_cs35l56 snd_soc_cs42l43 cs42l43 snd_soc_mt8901_afe proart_audio; do
		[ -d /sys/module/$m/parameters ] || continue
		for p in /sys/module/$m/parameters/*; do echo "$m.$(basename "$p")=$(cat "$p" 2>/dev/null)"; done
	done > "$d/module-params.txt"

	# SoundWire peripherals: attach state, and the SCP/DP0 registers through the core's debugfs
	for s in /sys/bus/soundwire/devices/sdw:*; do
		[ -e "$s" ] || continue
		echo "$(basename "$s") status=$(cat "$s/status" 2>/dev/null) driver=$(basename "$(readlink "$s/driver" 2>/dev/null)") runtime=$(cat "$s/power/runtime_status" 2>/dev/null)"
	done > "$d/soundwire.txt"
	find /sys/kernel/debug/soundwire -name registers 2>/dev/null | while read -r r; do
		echo "=== $r"; timeout 5 cat "$r" 2>&1
	done > "$d/soundwire-registers.txt"

	# SoundWire pad configuration (mode / bias / drive) of the CNT0 pins
	for f in /sys/kernel/debug/pinctrl/*/pinconf-pins /sys/kernel/debug/pinctrl/*/pins; do
		[ -r "$f" ] || continue
		echo "=== $f"
		for p in $SDW_PINS; do grep -E "^pin $p( |:|\))" "$f"; done
	done > "$d/pins.txt" 2>&1
	for f in /sys/kernel/debug/pinctrl/*/pinmux-pins; do
		[ -r "$f" ] || continue
		echo "=== $f"; for p in $SDW_PINS; do grep -E "^pin $p " "$f"; done
	done >> "$d/pins.txt" 2>&1

	# Cirrus DSP state (firmware names, booted/running) and the codec / AFE register maps
	find /sys/kernel/debug/asoc -path '*cs35l56*' -type f 2>/dev/null | while read -r f; do
		echo "$f: $(timeout 2 head -c 200 "$f" 2>/dev/null | tr '\n' ' ')"
	done > "$d/cs35l56-dsp.txt"
	for r in /sys/kernel/debug/regmap/*; do
		case "$(basename "$r")" in
		*cs42l43*|*cs35l56*|*sdw:*|*NVDA9022*|*afe*) ;;
		*) continue ;;
		esac
		timeout 10 cat "$r/registers" > "$d/regmap-$(basename "$r" | tr ':/' '__').txt" 2>&1
	done

	# ALSA view
	cat /proc/asound/cards > "$d/alsa.txt" 2>&1
	[ -n "$c" ] && amixer -c "$c" contents > "$d/amixer.txt" 2>&1

	# Functional test through PipeWire: 3 s silence to the speakers, 3 s from the internal mic,
	# while measuring the real hw_ptr rate of every running PCM of the card.
	if [ -n "$c" ] && as_user true 2>/dev/null; then
		as_user pw-dump > "$d/pw-dump.json" 2>/dev/null
		local mic spk
		mic=$(as_user pw-cli ls Node 2>/dev/null | grep -o 'alsa_input.platform-mtk_sdw_mc[^"]*Mic[^"]*source' | head -1)
		spk=$(as_user pw-cli ls Node 2>/dev/null | grep -o 'alsa_output.platform-mtk_sdw_mc[^"]*Speaker[^"]*sink' | head -1)
		{
			echo "mic node: ${mic:-none}"; echo "speaker node: ${spk:-none}"
			[ -n "$spk" ] && as_user timeout 8 pw-play --target "$spk" -r 48000 -c 2 /dev/zero >/dev/null 2>&1 &
			[ -n "$mic" ] && as_user timeout 8 pw-record --target "$mic" -r 48000 -c 1 --format s16 "$d/mic.wav" >/dev/null 2>&1 &
			sleep 2
			for st in /proc/asound/card$c/pcm*/sub0/status; do
				grep -q RUNNING "$st" 2>/dev/null || continue
				echo "$st: $(pcm_rate "$st")"
			done
			wait
		} > "$d/rates.txt" 2>&1
		if [ -s "$d/mic.wav" ]; then
			python3 -I - "$d/mic.wav" >> "$d/rates.txt" 2>&1 <<'PY'
import sys, wave, array, math
w = wave.open(sys.argv[1]); a = array.array('h', w.readframes(w.getnframes()))
if not a: print("mic: no samples"); sys.exit()
rms = math.sqrt(sum(x*x for x in a) / len(a)); peak = max(abs(x) for x in a)
print(f"mic: {len(a)} samples, rms {rms:.1f}, peak {peak} ({'SILENT' if peak < 8 else 'signal'})")
PY
		fi
		as_user pw-top -b -n 2 > "$d/pw-top.txt" 2>&1
	fi
	echo "snapshot written to $d"
}

compare() {
	local a=$OUT/$1 b=$OUT/$2 f
	for f in soundwire.txt pins.txt module-params.txt cs35l56-dsp.txt rates.txt amixer.txt; do
		echo "##### $f"; diff -u "$a/$f" "$b/$f" | sed -n '3,200p'
	done
	for f in "$b"/regmap-*.txt; do
		[ -e "$a/$(basename "$f")" ] || continue
		echo "##### $(basename "$f") (changed registers)"
		diff "$a/$(basename "$f")" "$f" | grep '^[<>]' | head -80
	done
	echo "##### new kernel errors after the sleep"; cat "$b/kernel-errors.txt" | tail -40
}

mic_ok() {
	local d=$OUT/recover-$1
	snapshot "recover-$1" >/dev/null
	grep -H -E 'mic:|frames/s' "$d/rates.txt"
	grep -q 'mic: .*signal' "$d/rates.txt"
}

# Recovery ladder, cheapest first; stops at the first step after which the mic records again.
recover() {
	local try_clk=${1:-}
	echo "== 0: current state"; mic_ok 0 && { echo "mic works, nothing to do"; return; }
	echo "== 1: restart PipeWire/WirePlumber"
	as_user systemctl --user restart wireplumber pipewire pipewire-pulse; sleep 4
	mic_ok 1 && return
	if [ -w "$SDW_DBG/bus_reset" ]; then
		echo "== 2: SoundWire link 1 standard bus reset"; echo 1 > "$SDW_DBG/bus_reset"; sleep 4
		mic_ok 2 && return
		echo "== 3: SoundWire link 1 deep reset (clock cycle)"; echo 11 > "$SDW_DBG/bus_reset"; sleep 5
		as_user systemctl --user restart wireplumber pipewire pipewire-pulse; sleep 4
		mic_ok 3 && return
	fi
	if [ "$try_clk" = --try-clk ] && [ -w "$PWRAP" ]; then
		# EXPERIMENT (see research/audio-suspend.md, hypothesis H1): re-select the audio clock mux
		# parents that only the boot firmware sets, with the levels of the mt8901 AFE driver's own
		# table (mux id, level): AUDIO_H=0 -> apll2_d2 (3), AUD_ENGEN1=1 -> apll1_d4 (3),
		# AUD_ENGEN2=2 -> apll2_d4 (3), AUD_INTBUS=7 -> mainpll2_d4_d4 (3), AUD_1=8 -> apll1 (1),
		# AUD_2=9 -> apll2 (1). Command 4 = SSPM_AUD_CMD_VLP_SYS_CLK_SET_PARENT. A reboot undoes it.
		# SoundWire bus/PHY clocks (via \_SB.CNT0): AUD_SOUNDWIRE0/1=3/4 -> apll2_d8 (3),
		# SOUNDWIRE0/1_PHY=5/6 -> apll2 (3), levels from the Windows controller driver's table.
		echo "== 4: re-select the SoundWire and AFE clock parents, then deep reset"
		for m in 3 4 5 6; do
			echo "\\_SB.CNT0 4 $m 3 0" > "$PWRAP" || echo "set_parent sdw mux $m failed"
		done
		for ml in "0 3" "1 3" "2 3" "7 3" "8 1" "9 1"; do
			echo "\\_SB.ASD0 4 ${ml% *} ${ml#* } 0" > "$PWRAP" || echo "set_parent $ml failed"
		done
		[ -w "$SDW_DBG/bus_reset" ] && echo 11 > "$SDW_DBG/bus_reset"; sleep 5
		as_user systemctl --user restart wireplumber pipewire pipewire-pulse; sleep 4
		mic_ok 4 && return
	fi
	echo "no step brought the microphone back; send $OUT (before/after/recover-*) along with the bug report"
}

case "${1:-}" in
snapshot) snapshot "${2:?tag}" ;;
compare)  compare "${2:?tag}" "${3:?tag}" ;;
recover)  recover "${2:-}" ;;
*) sed -n '3,12p' "$0"; exit 1 ;;
esac
