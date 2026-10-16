#!/bin/sh
# gw-blackhole-289.sh — on the OTS node: drop every packet of chosen br-ots TCP connections (by the client's source
# port) so test sessions go stale without a FIN or RST, like phones that walked out of range (#289 suites).
#   ACTION=add PORTS="<p> [<p>..]" [TTL=300]  add ports to the set; creates the table on first use
#   ACTION=count                              print "DROPPED <packets>" (proof the rules bite)
#   ACTION=del                                print "DROPPED <packets>", delete the table
# BRIDGE family, not inet: br-ots has nf_call_iptables=0 (probed on 04), so container-to-container frames never
# reach the inet forward hook — the first version of this script installed an inet table that never matched.
# Every step is checked: a table without its two drop rules is reported as FAIL, never as a black hole.
: "${ACTION:?}"
T=dv289
case "$ACTION" in
add)
	: "${PORTS:?}"; TTL=${TTL:-300}
	if ! nft list table bridge $T >/dev/null 2>&1; then
		nft add table bridge $T || { echo "FAIL nft table"; exit 1; }
		nft add set bridge $T ports '{ type inet_service; flags timeout; }' || { echo "FAIL nft set"; exit 1; }
		nft add chain bridge $T bh '{ type filter hook forward priority -10; }' || { echo "FAIL nft chain"; exit 1; }
		nft add rule bridge $T bh ip protocol tcp tcp sport @ports counter drop || { echo "FAIL nft rule"; exit 1; }
		nft add rule bridge $T bh ip protocol tcp tcp dport @ports counter drop || { echo "FAIL nft rule"; exit 1; }
		# safety net for an aborted test: delete the table once nothing is left in it. It must NOT remove a table a
		# later test is using: a deleter armed by presence-289 removed zombie-289's table seconds after its supersede
		# (2026-10-16: A's pings got through, its deadline kept extending; on rc 5 the same race fired before the
		# supersede and produced the only PASSes). Elements expire on their own (per-element timeout).
		(sleep $((TTL + 60)); nft list set bridge $T ports 2>/dev/null | grep -q "elements" || nft delete table bridge $T 2>/dev/null) </dev/null >/dev/null 2>&1 &
	fi
	n=0
	for p in $PORTS; do nft add element bridge $T ports "{ $p timeout ${TTL}s }" && n=$((n+1)); done
	r=$(nft list chain bridge $T bh 2>/dev/null | grep -c "counter packets .* drop")
	[ "$r" = 2 ] || { echo "FAIL black hole chain has $r drop rule(s), not 2"; exit 1; }
	echo "BLACKHOLE $n"
	;;
count|del)
	d=$(nft list chain bridge $T bh 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\) .*/\1/p' | awk '{s+=$1} END{print s+0}')
	echo "DROPPED ${d:-0}"
	[ "$ACTION" = del ] && { nft delete table bridge $T 2>/dev/null; echo "BLACKHOLE-DELETED"; }
	;;
esac
