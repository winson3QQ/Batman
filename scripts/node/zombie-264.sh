#!/bin/sh
# zombie-264.sh — peer-node side of the zombie-264 suite (#264 R6/R10), in FIELD ORDER. Runs on the BENCH node:
#   ssh root@peer "TARGET=<ots-ip> RUN=<id> ACTION=start|phase2|cleanup sh -s" < this
# Sessions to TARGET:8088, all with uid/callsign under $RUN (so the harness can delete their rows/queues):
#   A  = the EUD's FIRST session (uid $RUN-A, callsign $RUN-A-cs), the one that goes stale: its port is black-holed
#        on this node both ways (own nft table, set elements with a timeout, a detached delete of the table), so no
#        FIN/RST ever reaches the server: a phone that walked out of range
#   B  = the same EUD reconnecting while A still holds its queues (same uid/callsign), READING into $H/$RUN-B.out
#   D  = another EUD streaming 1 CoT/s for 150 s: 8088 sessions all sit in __ANON__, so the server keeps writing
#        to A's dead socket (data pending: keepalive probes alone would never fire, v5A-F1/v5B-M1)
#   C  = another EUD sending 10 counted CoT once per phase (identifies once, then contact-less events)
# start:   A, black hole, B, D; prints "APORT <p>", "BPORT <p>", "BLACKHOLE <p> 1", "STARTED established=<n>"
# phase2:  C sends 10; prints "PHASE2 <n>" (patched, after A is reaped and B subscribed: 10)
# cleanup: kills the run's clients, deletes the nft table, removes the files; prints "LEFT <established>"
: "${TARGET:?}" "${RUN:?}" "${ACTION:?}"
H=/tmp/run/batman-dv
{ [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }
ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ev(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+600)))" "$2"; }
# a counted event carries no <contact>: the session's identity stays the first event's (a <contact> per event would
# re-identify nothing upstream, but cot_parser's insert would race the new EUD row: "sender_uid not present")
evn(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail/></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+600)))"; }
est(){ netstat -tn 2>/dev/null | grep "$TARGET:8088.*ESTABLISHED" | awk '{print $4}' | cut -d: -f2; }
sendC(){ { ev "$RUN-C-$1-0" "$RUN-C"; sleep 2; i=1; while [ $i -le 10 ]; do evn "$RUN-C-$1-$i"; sleep 1; i=$((i+1)); done; sleep 3; } | nc "$TARGET" 8088 >/dev/null 2>&1; }
countB(){ grep -o "uid=\"$RUN-C-$1-[1-9][0-9]*\"" "$H/$RUN-B.out" 2>/dev/null | sort -u | wc -l; }
case $ACTION in
start)
	rm -f "$H/$RUN-"*
	mkfifo "$H/$RUN-B.fifo" "$H/$RUN-A.fifo" || exit 1
	# A first: the session that will go stale
	(trap '' HUP; nc "$TARGET" 8088 < "$H/$RUN-A.fifo" > /dev/null 2>&1) &
	(trap '' HUP; { ev "$RUN-A" "$RUN-A-cs"; sleep 600; } > "$H/$RUN-A.fifo") &
	sleep 3; ap=$(est | head -1); echo "APORT ${ap:-none}"
	[ -n "$ap" ] || { echo "FAIL no port for A"; exit 1; }
	# black hole A's port both ways: own table, elements expire by themselves, table deleted by a detached timer
	nft add table inet dvz264 2>/dev/null
	nft add set inet dvz264 ports '{ type inet_service; flags timeout; }' 2>/dev/null
	nft add chain inet dvz264 out '{ type filter hook output priority -10; }' 2>/dev/null
	nft add chain inet dvz264 in '{ type filter hook input priority -10; }' 2>/dev/null
	nft add rule inet dvz264 out tcp sport @ports drop 2>/dev/null
	nft add rule inet dvz264 in tcp dport @ports drop 2>/dev/null
	nft add element inet dvz264 ports "{ $ap timeout 300s }" || { echo "FAIL nft"; exit 1; }
	(trap '' HUP; sleep 360; nft delete table inet dvz264 2>/dev/null) </dev/null >/dev/null 2>&1 &
	echo "BLACKHOLE $ap $(nft list set inet dvz264 ports 2>/dev/null | grep -c "$ap")"
	# B: the same EUD reconnects while A is stale
	(trap '' HUP; nc "$TARGET" 8088 < "$H/$RUN-B.fifo" > "$H/$RUN-B.out" 2>/dev/null) &
	(trap '' HUP; { ev "$RUN-A" "$RUN-A-cs"; sleep 600; } > "$H/$RUN-B.fifo") &
	sleep 3; bp=$(est | grep -v -x -F "$ap" | head -1); echo "BPORT ${bp:-none}"
	# D streams for 150 s so the server has data pending towards A
	(trap '' HUP; { i=1; while [ $i -le 150 ]; do ev "$RUN-D-$i" "$RUN-D"; sleep 1; i=$((i+1)); done; } | nc "$TARGET" 8088 >/dev/null 2>&1) </dev/null &
	sleep 2; echo "STARTED established=$(est | wc -l)"
	;;
phase2)
	sendC p2; sleep 3; echo "PHASE2 $(countB p2)"
	;;
cleanup)
	nft delete table inet dvz264 2>/dev/null
	for p in $(pgrep -x nc) $(pgrep -f "^sleep 600$"); do kill "$p" 2>/dev/null; done
	sleep 2; rm -f "$H/$RUN-"*
	echo "LEFT $(est | wc -l)"
	;;
*) echo "FAIL unknown ACTION $ACTION"; exit 1 ;;
esac
