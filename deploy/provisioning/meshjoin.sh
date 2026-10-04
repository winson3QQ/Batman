# shellcheck shell=ash
# meshjoin.sh — the ONE definition of "this node is in the mesh", shared by joinwatch (diagnosis) and
# batman-autocommit (the OTA commit gate, docs/design/ab-autocommit.md v2.2). Source it; defines only.
#
#   meshjoin_sample     sets MJ_PLINK (ESTAB 802.11s plinks on wlh0), MJ_STA (stations on wlh0) and
#                       MJ_BAT (batman-adv neighbours seen over wlh0 — the HaLow hardif only, so a
#                       neighbour heard over some other hardif cannot stand in for a working radio)
#   meshjoin_joined     0 when MJ_PLINK>=1 and MJ_BAT>=1 (call meshjoin_sample first)
#   meshjoin_reachable  0 when joined AND br-ahwlan has an IPv4 address AND dropbear is running — a node
#                       an operator can actually reach over the mesh, not just an L2 neighbour
MJ_IF=wlh0
MJ_BR=br-ahwlan

meshjoin_sample() {
	_d=$(iw dev "$MJ_IF" station dump 2>/dev/null)
	MJ_PLINK=$(printf '%s\n' "$_d" | grep -c "plink:.*ESTAB")
	# shellcheck disable=SC2034  # read by joinwatch's diagnosis
	MJ_STA=$(printf '%s\n' "$_d" | grep -c "^Station")
	# `batctl n` rows end in "[ <hardif>]"; count only rows learnt over the HaLow interface
	MJ_BAT=$(batctl n 2>/dev/null | grep -E '[0-9]+\.[0-9]+s' | grep -c "\[ *$MJ_IF\]")
}
meshjoin_joined() { [ "${MJ_PLINK:-0}" -ge 1 ] && [ "${MJ_BAT:-0}" -ge 1 ]; }
meshjoin_reachable() {
	meshjoin_joined || return 1
	ip -4 addr show dev "$MJ_BR" 2>/dev/null | grep -q ' inet ' || return 1
	/etc/init.d/dropbear running >/dev/null 2>&1
}
