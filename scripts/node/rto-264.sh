#!/bin/sh
# rto-264.sh — peer side of the "RTO returns" capacity test (busybox sh, runs on 02 / 03):
#   ssh root@peer "TARGET=<ots-ip> RUN=<id> ACTION=start|blackhole|cleanup [N=8] sh -s" < this
# start     : N identifying idle 8088 sessions (uid/callsign $RUN-<k>), each held 600 s
# blackhole : drops every packet of those sessions both ways (own nft table, elements expire after 400 s, a
#             detached timer deletes the table): the phones' link to the OTS node is gone, no FIN/RST reaches it
# cleanup   : kills the run's clients, deletes the table; prints LEFT <established to 8088>
: "${TARGET:?}" "${RUN:?}" "${ACTION:?}"
ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ev(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+600)))" "$2"; }
ports(){ netstat -tn 2>/dev/null | grep "$TARGET:8088 *ESTABLISHED" | awk '{print $4}' | cut -d: -f2; }
case $ACTION in
start)
	i=1; while [ $i -le "${N:-8}" ]; do (trap '' HUP; { ev "$RUN-$i" "$RUN-$i"; sleep 600; } | nc "$TARGET" 8088 >/dev/null 2>&1) </dev/null >/dev/null 2>&1 & i=$((i+1)); sleep 1; done
	sleep 3; echo "STARTED $(ports | wc -l)"
	;;
blackhole)
	nft add table inet dvrto 2>/dev/null
	nft add set inet dvrto ports '{ type inet_service; flags timeout; }' 2>/dev/null
	nft add chain inet dvrto out '{ type filter hook output priority -10; }' 2>/dev/null
	nft add chain inet dvrto in '{ type filter hook input priority -10; }' 2>/dev/null
	nft add rule inet dvrto out tcp sport @ports drop 2>/dev/null
	nft add rule inet dvrto in tcp dport @ports drop 2>/dev/null
	n=0; for p in $(ports); do nft add element inet dvrto ports "{ $p timeout 400s }" && n=$((n+1)); done
	(trap '' HUP; sleep 450; nft delete table inet dvrto 2>/dev/null) </dev/null >/dev/null 2>&1 &
	echo "BLACKHOLED $n"
	;;
cleanup)
	nft delete table inet dvrto 2>/dev/null
	for p in $(pgrep -x nc) $(pgrep -f "^sleep 600$"); do kill "$p" 2>/dev/null; done
	sleep 2; echo "LEFT $(ports | wc -l)"
	;;
*) echo "FAIL unknown ACTION $ACTION"; exit 1 ;;
esac
