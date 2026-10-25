#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Brings RSI Launcher windows back onto a screen. The launcher restores its last position, which after a change
# of the monitor layout (dock, DPI) can lie outside every screen: it runs, but nobody sees it. It opens a small
# start window first and the main window later, so for 3 minutes after start every window is checked.
# Started in the background by start-sc.sh.
monitors() { xrandr --listmonitors | awk 'NR > 1 {print $2, $3}'; }
fix() {   # $1 window id, $2-$5 geometry
	local w=$1 x=$2 y=$3 ww=$4 wh=$5 cx=$(($2 + $4 / 2)) cy=$(($3 + $5 / 2)) name geo mw mh ox oy rest
	local px=0 py=0 pw=0 ph=0
	while read -r name geo; do
		mw=${geo%%/*}; rest=${geo#*x}; mh=${rest%%/*}; ox=$(cut -d+ -f2 <<<"$geo"); oy=$(cut -d+ -f3 <<<"$geo")
		[ "$cx" -ge "$ox" ] && [ "$cx" -lt $((ox + mw)) ] && [ "$cy" -ge "$oy" ] && [ "$cy" -lt $((oy + mh)) ] && return 0
		if [[ $name == *"*"* ]] || [ "$pw" -eq 0 ]; then px=$ox; py=$oy; pw=$mw; ph=$mh; fi
	done < <(monitors)
	local tx=$((px + (pw - ww) / 2)) ty=$((py + (ph - wh) / 2)) nx
	[ $tx -lt $px ] && tx=$px; [ $ty -lt $py ] && ty=$py
	# GNOME takes the move in logical coordinates (X coordinates / scale): try 1:1, halve if it landed doubled
	wmctrl -i -r "$w" -e "0,$tx,$ty,-1,-1"; sleep 0.5
	nx=$(wmctrl -lG | awk -v w="$w" '$1 == w {print $3}')
	[ "$nx" != "$tx" ] && wmctrl -i -r "$w" -e "0,$((tx / 2)),$((ty / 2)),-1,-1"
	wmctrl -i -a "$w"
	logger -t sc-window-fix "launcher window $w was off-screen at $x,$y; moved to the primary screen"
}
for _ in $(seq 60); do
	wmctrl -lG 2>/dev/null | awk '/RSI Launcher$/ {print $1, $3, $4, $5, $6}' | while read -r w x y ww wh; do
		fix "$w" "$x" "$y" "$ww" "$wh"
	done
	sleep 3
done
