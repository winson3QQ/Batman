#!/bin/sh
# gw-blackhole-289.sh — on the OTS node: drop every packet of one br-ots TCP connection (by the client's source port)
# so a test session goes stale without a FIN or RST, like a phone that walked out of range (#289 suites).
#   ACTION=add PORT=<n> [TTL=300]   add the port to the set (own nft table, elements expire; table deleted by a timer)
#   ACTION=del                      delete the table now
# The rules sit in the forward hook: container-to-container traffic on br-ots crosses the host's bridge through
# br-netfilter (fw4's forward chain), so a forward-hook drop on the host black-holes a client inside ots_cot_parser.
: "${ACTION:?}"
case "$ACTION" in
add)
	: "${PORT:?}"; TTL=${TTL:-300}
	nft add table inet dv289 2>/dev/null
	nft add set inet dv289 ports '{ type inet_service; flags timeout; }' 2>/dev/null
	nft add chain inet dv289 fwd '{ type filter hook forward priority -10; }' 2>/dev/null
	nft add rule inet dv289 fwd tcp sport @ports drop 2>/dev/null
	nft add rule inet dv289 fwd tcp dport @ports drop 2>/dev/null
	nft add element inet dv289 ports "{ $PORT timeout ${TTL}s }" || { echo "FAIL nft"; exit 1; }
	(sleep $((TTL + 60)); nft delete table inet dv289 2>/dev/null) </dev/null >/dev/null 2>&1 &
	echo "BLACKHOLE $PORT $(nft list set inet dv289 ports 2>/dev/null | grep -c "$PORT")"
	;;
del)
	nft delete table inet dv289 2>/dev/null; echo "BLACKHOLE-DELETED"
	;;
esac
