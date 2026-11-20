#!/bin/bash
# A2: where the node page's entries are while it is still connecting (no 手機 Wi-Fi tap). Taps: the 04 card, Back.
. "$(dirname "$0")/a2lib-v2.sh"
front || { log "STOP: the app is not in front"; exit 1; }
for i in 1; do
	home || { log "STOP: not home"; exit 1; }
	Y=1575   # after a launch home shows the neutral hero until the round has read: 04 card 1431-1719
	relaunch; sleep 0.5
	log "tap 04 y=$Y"; $A $D shell input tap 540 "$Y"
	x=$(dump) || { log "no dump"; back; continue; }
	log "dump done"
	echo "$x" | tr '>' '\n' | grep -a 'content-desc="[^"]' | sed -nE 's/.*content-desc="([^"]{0,60})[^"]*".*bounds="\[[0-9]+,([0-9]+)\]\[[0-9]+,([0-9]+)\]".*/  \2-\3 \1/p'
	sleep 8; back
done
home && log "end: home" || log "end: not home"
