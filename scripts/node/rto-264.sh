#!/bin/sh
# rto-264.sh — peer side of the "RTO returns" capacity suites rto-264 / rto-ssl-264 (busybox sh, runs on 02 / 03):
#   ssh root@peer "TARGET=<ots-ip> RUN=<id> ACTION=start|blackhole|cleanup [N=8] [PORT=8088|8089] sh -s" < this
# start     : N identifying idle sessions (uid/callsign $RUN-<k>), each held 600 s. PORT 8089 uses `openssl s_client`
#             with the test client certificate the harness put in $H/$RUN.pem / $RUN.key (removed by cleanup)
# blackhole : drops every packet of those sessions both ways (own nft table, elements expire after 400 s, a
#             detached timer deletes the table): the phones' link to the OTS node is gone, no FIN/RST reaches it
# cleanup   : kills THIS run's clients only (their pids are recorded at start), deletes the table and the run's
#             files; prints LEFT <established to PORT>
: "${TARGET:?}" "${RUN:?}" "${ACTION:?}"
PORT=${PORT:-8088}
H=/tmp/run/batman-dv
{ [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }
ts(){ date -u -d @"$1" +%Y-%m-%dT%H:%M:%S.000Z; }
ev(){ n=$(date +%s); printf '<event version="2.0" uid="%s" type="a-f-G-U-C" how="h-e" time="%s" start="%s" stale="%s"><point lat="25.03" lon="121.56" hae="10" ce="9999999" le="9999999"/><detail><contact callsign="%s"/></detail></event>' "$1" "$(ts "$n")" "$(ts "$n")" "$(ts $((n+600)))" "$2"; }
ports(){ netstat -tn 2>/dev/null | grep "$TARGET:$PORT *ESTABLISHED" | awk '{print $4}' | cut -d: -f2; }
client(){
	if [ "$PORT" = 8089 ]; then
		exec openssl s_client -quiet -connect "$TARGET:8089" -cert "$H/$RUN.pem" -key "$H/$RUN.key" >/dev/null 2>&1
	else
		exec nc "$TARGET" 8088 >/dev/null 2>&1
	fi
}
case $ACTION in
start)
	: > "$H/$RUN.pids"
	i=1; while [ $i -le "${N:-8}" ]; do
		(trap '' HUP; { ev "$RUN-$i" "$RUN-$i"; sleep 600; } | client) </dev/null >/dev/null 2>&1 &
		echo $! >> "$H/$RUN.pids"; i=$((i+1)); sleep 1
	done
	sleep 4; echo "STARTED $(ports | wc -l)"
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
	# this run's subshells and their children (the client and the sleep), nothing else on the node
	for p in $(cat "$H/$RUN.pids" 2>/dev/null); do
		for c in $(grep -l "^PPid:[[:space:]]*$p\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do
			for cc in $(grep -l "^PPid:[[:space:]]*$c\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3); do kill "$cc" 2>/dev/null; done
			kill "$c" 2>/dev/null
		done
		kill "$p" 2>/dev/null
	done
	sleep 2; rm -f "$H/$RUN.pids" "$H/$RUN.pem" "$H/$RUN.key"
	echo "LEFT $(ports | wc -l)"
	;;
*) echo "FAIL unknown ACTION $ACTION"; exit 1 ;;
esac
