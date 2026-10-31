# shellcheck shell=sh disable=SC3043   # busybox ash has local
# /usr/lib/batman/wireless-settle.sh — netifd's word on a radio (#254 wireless-txn §19). The ONE implementation,
# sourced by halow-setkey and 99-batman-chanfix: a change to the radio is complete when netifd reports the final
# state, and no `wifi reload` is issued while netifd is still reconfiguring the radio (a reload landing inside
# netifd's setup left a mesh netdev + wpa_supplicant_s1g on the air that netifd no longer knew — 04, 2026-10-30).
#
#   wl_status                       `ubus call network.wireless status` (stdout); rc 1 when ubus gave nothing
#   wl_field <json> <radio> <path>  one field of that radio's section (`up` -> true/false, `config.channel`, ...);
#                                   empty when absent
#   wl_settled <radio>              rc 0 = netifd reports the radio with pending=false; rc 1 otherwise — an
#                                   unreadable status, a missing section or a missing field is NOT settled
#   wl_wait_settled <radio> <secs>  poll 1 Hz until settled; rc 1 at the deadline
# fd 9 (the halow-setkey writer lock, when held) is closed for every external command (code review 2 B m6).
wl_status(){ ubus call network.wireless status 2>/dev/null 9>&-; }
wl_field(){ printf '%s' "$1" | jsonfilter -e "@.$2.$3" 2>/dev/null 9>&-; }
wl_settled(){
	local st
	st=$(wl_status) || return 1
	[ -n "$st" ] || return 1
	[ "$(wl_field "$st" "$1" pending)" = false ]
}
wl_wait_settled(){
	local i=0
	while :; do
		wl_settled "$1" && return 0
		[ "$i" -ge "$2" ] && return 1
		sleep 1; i=$((i + 1))
	done
}
