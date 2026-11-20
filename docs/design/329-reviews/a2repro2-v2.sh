#!/bin/bash
# A2: #329 line 255. From the background, open 04 and its 手機 Wi-Fi page while the home round is still connecting.
# Taps: the 04 card, the 手機 Wi-Fi entry, Back. Nothing of the Wi-Fi page is dumped or kept (a2lib-v2.sh).
# After a launch from the background home shows the neutral hero until the round has read (04 card y 1431-1719,
# a2layout.sh), and the node page while connecting has the Wi-Fi entry at y 1305-1506: the two fixed taps.
# Usage: a2repro2-v2.sh <out-name> [delays...]
#   NOWIFI=1  D1: the 04 card only
#   BG=1      D6: after the Wi-Fi tap, to the background 8 s and back, then 45 s
. "$(dirname "$0")/a2lib-v2.sh"
OUT=${1:?out name}; shift
[ $# -gt 0 ] || set -- 0.3 1.5 2.5 3.5 4.5
front || { log "STOP: the app is not in front"; exit 1; }
$A $D logcat -c
for d in "$@"; do
	home || { log "STOP: not home"; break; }
	log "== delay $d: to background"
	relaunch
	sleep "$d"
	log "tap 04";  $A $D shell input tap 540 1563
	if [ "${NOWIFI:-0}" = 1 ]; then sleep 16; back; continue; fi
	sleep 0.7
	tap_wifi 1405
	if [ "${BG:-0}" = 1 ]; then sleep 0.3; log "to background"; relaunch; sleep 45; else sleep 16; fi
	log "screencap size=$(capsize || echo unknown)"
	back
	[ "$WIFI" = 0 ] && log "after Back: $(descs)"
done
home && log "end: $(descs)" || log "end: not home"
$A $D logcat -d -v time > "$OUT.logcat"
grep -aE "BMAPP|connect\(\) - device|cancelOpen" "$OUT.logcat" | cut -c1-210
