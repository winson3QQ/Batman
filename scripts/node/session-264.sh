#!/bin/sh
# session-264.sh — bench-node side of the #264 review-round-2 suites (busybox sh). Runs on the BENCH node:
#   ssh root@peer "TARGET=<ots-ip> RUN=<id> ACTION=<a> [TAG=..] [VICTIM=..] [N=..] [PORT=..] sh -s" < this
# All uids/callsigns are under $RUN so the harness can delete their rows and queues.
#   same-uid : A (uid $RUN-U, cs $RUN-Uc) reads into $H/$RUN-A.out; B, the same uid/callsign, connects, stays 6 s,
#              closes cleanly (a phone that flapped at the edge of range, or a second app instance)
#   share-cs : A (uid $RUN-U1) and B (uid $RUN-U2) with the SAME callsign $RUN-S, both reading
#   send10   : C (another EUD) sends 10 counted broadcast CoT (identifies once, contact-less events); "SENT10 <tag>"
#   stop     : ends reader $WHO (A or B) only: "STOPPED <who>"
#   count    : "A <n> B <n>" received for tag $TAG
#   swap     : an 8088 client uid $RUN-X whose CALLSIGN is $VICTIM (an 8089 user's uid), stays 10 s
#   silent   : N sockets to TARGET:PORT that never send a byte (they stay open until the server closes them); GAP s
#              between connects (default 0: all at once)
#   chatter  : N sockets that send one empty <event></event> and then nothing (review r3 B3-3)
#   badstart : one session: a CoT without a start attribute, then the identifying CoT of $RUN-B (review r3 A3-2), 10 s
#   idle     : N identifying idle sessions (uid/callsign $RUN-<k>), HOLD s each (capacity)
#   est      : "EST <n>" established connections from this node to TARGET:PORT
#   cleanup  : kills the run's clients; "LEFT <n>" established to 8088
: "${TARGET:?}" "${RUN:?}" "${ACTION:?}"
H=/tmp/run/batman-dv
{ [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }
ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ev(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+600)))" "$2"; }
evn(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail/></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+600)))"; }
est(){ netstat -tn 2>/dev/null | grep -c "$TARGET:${1:-8088} *ESTABLISHED"; }
reader(){ # $1 name, $2 uid, $3 callsign: a long-lived session reading into $H/$RUN-$1.out
	mkfifo "$H/$RUN-$1.fifo" || return 1
	(trap '' HUP; exec nc "$TARGET" 8088 < "$H/$RUN-$1.fifo" > "$H/$RUN-$1.out" 2>/dev/null) &
	echo $! > "$H/$RUN-$1.pid"
	(trap '' HUP; { ev "$2" "$3"; sleep 600; } > "$H/$RUN-$1.fifo") &
}
case $ACTION in
same-uid)
	rm -f "$H/$RUN-"*
	reader A "$RUN-U" "$RUN-Uc"; sleep 4
	{ ev "$RUN-U" "$RUN-Uc"; sleep 6; } | nc "$TARGET" 8088 >/dev/null 2>&1
	echo "B closed"
	;;
share-cs)
	rm -f "$H/$RUN-"*
	reader A "$RUN-U1" "$RUN-S"; sleep 3
	reader B "$RUN-U2" "$RUN-S"; sleep 3
	echo "STARTED established=$(est)"
	;;
send10)
	{ ev "$RUN-C-$TAG-0" "$RUN-C"; sleep 2; i=1; while [ $i -le 10 ]; do evn "$RUN-C-$TAG-$i"; sleep 1; i=$((i+1)); done; sleep 3; } | nc "$TARGET" 8088 >/dev/null 2>&1
	echo "SENT10 $TAG"
	;;
stop)
	kill "$(cat "$H/$RUN-${WHO:?}.pid" 2>/dev/null)" 2>/dev/null && echo "STOPPED $WHO" || echo "FAIL stop $WHO"
	;;
count)
	a=$(grep -o "uid=\"$RUN-C-$TAG-[1-9][0-9]*\"" "$H/$RUN-A.out" 2>/dev/null | sort -u | wc -l)
	b=$(grep -o "uid=\"$RUN-C-$TAG-[1-9][0-9]*\"" "$H/$RUN-B.out" 2>/dev/null | sort -u | wc -l)
	echo "A $a B $b"
	;;
swap)
	{ ev "$RUN-X" "${VICTIM:?}"; sleep 10; } | nc "$TARGET" 8088 >/dev/null 2>&1; echo "swap session closed"
	;;
silent)
	i=0; while [ $i -lt "${N:?}" ]; do (trap '' HUP; sleep 300 | nc "$TARGET" "${PORT:?}" >/dev/null 2>&1) </dev/null >/dev/null 2>&1 & i=$((i+1)); [ "${GAP:-0}" = 0 ] || sleep "$GAP"; done
	sleep 2; echo "SILENT $(est "$PORT")"
	;;
chatter)
	i=0; while [ $i -lt "${N:?}" ]; do (trap '' HUP; { printf '<event></event>'; sleep 300; } | nc "$TARGET" 8088 >/dev/null 2>&1) </dev/null >/dev/null 2>&1 & i=$((i+1)); sleep 1; done
	sleep 2; echo "CHATTER $(est 8088)"
	;;
badstart)
	n=$(date +%s)
	{ printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" stale="%s"><point lat="1" lon="1" hae="0" ce="9" le="9"/><detail><contact callsign="%s"/></detail></event>' "$RUN-B" "$(ts "$n")" "$(ts $((n+600)))" "$RUN-B"
	  sleep 2; ev "$RUN-B" "$RUN-B"; sleep 10; } | nc "$TARGET" 8088 >/dev/null 2>&1; echo "BADSTART done"
	;;
idle)
	i=1; while [ $i -le "${N:?}" ]; do (trap '' HUP; { ev "$RUN-$i" "$RUN-$i"; sleep "${HOLD:-90}"; } | nc "$TARGET" 8088 >/dev/null 2>&1) </dev/null >/dev/null 2>&1 & i=$((i+1)); done
	sleep 3; echo "IDLE $(est 8088)"
	;;
est)
	echo "EST $(est "${PORT:-8088}")"
	;;
cleanup)
	for p in $(pgrep -x nc) $(pgrep -f "^sleep 600$") $(pgrep -f "^sleep 300$") $(pgrep -f "^sleep ${HOLD:-90}$"); do kill "$p" 2>/dev/null; done
	sleep 2; rm -f "$H/$RUN-"*
	echo "LEFT $(est 8088)"
	;;
*) echo "FAIL unknown ACTION $ACTION"; exit 1 ;;
esac
