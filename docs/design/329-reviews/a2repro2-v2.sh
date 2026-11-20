#!/bin/bash
# A2: #329 line 255. From the background, open 04 and its 手機 Wi-Fi page while the home round is still connecting.
# Taps: the 04 card, the 手機 Wi-Fi entry, Back. Nothing of the Wi-Fi page is dumped or kept (a2lib-v2.sh).
# Usage: a2repro2-v2.sh <out-name> [delays...]
. "$(dirname "$0")/a2lib-v2.sh"
OUT=${1:?out name}; shift
[ $# -gt 0 ] || set -- 0.3 1.5 2.5 3.5 4.5
$A $D logcat -c
for d in "$@"; do
	home || { log "STOP: not home"; break; }
	log "== delay $d: to background"
	$A $D shell input keyevent KEYCODE_HOME; sleep 8
	log "launch"
	$A $D shell monkey -p dev.batman.app.dev -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
	sleep "$d"
	log "tap 04";  $A $D shell input tap 540 1563; sleep 0.7
	tap_wifi 1405
	sleep 16
	log "after 16 s: screencap size=$(capsize || echo unknown)"
	back
done
home && log "end: $(descs)" || log "end: not home"
$A $D logcat -d -v time > "$OUT.logcat"
grep -aE "BMAPP|connect\(\) - device|cancelOpen" "$OUT.logcat" | cut -c1-210
