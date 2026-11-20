#!/bin/bash
# A2 D7 (and D5 smoke with WIFI_FIRST=1). No timed tap on a page whose layout moves: every tap is located by a dump,
# except 「國家」 on the 「更多」 page, whose place was read from a dump of that same page just before.
# Taps: the 04 card, 「更多」, 「國家」, Back; with WIFI_FIRST=1 also 「手機 Wi-Fi」 and Back (nothing of that page is dumped).
# Usage: a2d7.sh <out-name>
. "$(dirname "$0")/a2lib-v2.sh"
OUT=${1:?out name}
show(){ dump | tr '>' '\n' | grep -ao 'content-desc="[^"]\+"' | sed -E 's/content-desc="//; s/"$//; s/&#10;/ | /g' | tr '\n' ';' | cut -c1-300; echo; }
front || { log "STOP: the app is not in front"; exit 1; }
home || { log "STOP: not home"; exit 1; }
$A $D logcat -c
tap_desc 7D2C || exit 1; sleep 12
if [ "${WIFI_FIRST:-0}" = 1 ]; then
	Y=$(desc_y '手機 Wi-Fi&#10;') || { log "STOP: no Wi-Fi entry"; back; exit 1; }
	tap_wifi "$Y"; sleep 6
	back   # clears the flag only when the page is known not secure
	[ "$WIFI" = 0 ] || { log "STOP: still secure after Back"; exit 1; }
	log "after Back: $(descs)"
fi
tap_desc '更多&#10;' || { back; exit 1; }; sleep 3
YC=$(desc_y '國家') || { log "STOP: no 國家 on this page"; back; back; exit 1; }
tap_desc '國家' || exit 1; sleep 6
log "country, first read: $(show)"
if [ "${WIFI_FIRST:-0}" != 1 ]; then
	back   # to 「更多」
	descs | grep -q '更多;' || { log "STOP: not on 更多"; exit 1; }
	relaunch; sleep 1.5
	front || { log "STOP: the app is not in front after the launch"; exit 1; }
	log "tap 國家 y=$YC"; $A $D shell input tap 540 "$YC"
	log "country, dump 1: $(show)"
	sleep 8
	log "country, dump 2: $(show)"
fi
back; back; back
home && log "end: home" || log "end: not home"
$A $D logcat -d -v time > "$OUT.logcat"
grep -aE "BMAPP|Start proc.*dev.batman" "$OUT.logcat" | cut -c1-200
