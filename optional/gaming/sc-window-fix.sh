#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Brings the RSI Launcher window back onto a screen. The launcher restores its last position, which after a
# change of the monitor layout (dock, DPI) can lie outside every screen: it runs, but nobody sees it.
# Started in the background by start-sc.sh; waits up to 3 minutes for the window, checks it once.
for _ in $(seq 90); do
	w=$(wmctrl -lG 2>/dev/null | awk '/RSI Launcher$/ {print $1; exit}')
	[ -n "$w" ] && break
	sleep 2
done
[ -n "$w" ] || exit 0
sleep 3
read -r x y ww wh < <(wmctrl -lG | awk -v w="$w" '$1 == w {print $3, $4, $5, $6}')
cx=$((x + ww / 2)); cy=$((y + wh / 2))
# monitors in X coordinates: "WxH+X+Y" from xrandr; primary marked with *
onscreen=0; px=0; py=0; pw=0; ph=0
while read -r name geo; do
	mw=${geo%%/*}; rest=${geo#*x}; mh=${rest%%/*}; ox=$(cut -d+ -f2 <<<"$geo"); oy=$(cut -d+ -f3 <<<"$geo")
	if [ "$cx" -ge "$ox" ] && [ "$cx" -lt $((ox + mw)) ] && [ "$cy" -ge "$oy" ] && [ "$cy" -lt $((oy + mh)) ]; then onscreen=1; fi
	if [[ $name == *"*"* ]] || [ "$pw" -eq 0 ]; then px=$ox; py=$oy; pw=$mw; ph=$mh; fi
done < <(xrandr --listmonitors | awk 'NR > 1 {print $2, $3}')
[ "$onscreen" -eq 1 ] && exit 0
tx=$((px + (pw - ww) / 2)); ty=$((py + (ph - wh) / 2)); [ $tx -lt $px ] && tx=$px; [ $ty -lt $py ] && ty=$py
# GNOME takes the move in logical coordinates (X coordinates / scale): try 1:1, then halve if it landed doubled
wmctrl -i -r "$w" -e "0,$tx,$ty,-1,-1"; sleep 1
read -r nx ny < <(wmctrl -lG | awk -v w="$w" '$1 == w {print $3, $4}')
if [ "$nx" -ne "$tx" ]; then wmctrl -i -r "$w" -e "0,$((tx / 2)),$((ty / 2)),-1,-1"; fi
wmctrl -i -a "$w"
logger -t sc-window-fix "launcher window was off-screen at $x,$y; moved to the primary screen"
