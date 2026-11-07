#!/bin/bash
# scripts/dv/prov-http-254.sh — #254 H4 appendix A.7, the rows on the R vehicle (p3-how "n"; the release image, no seam):
#   HT3   bluetoothd stopped -> provd's HealthOK false for 5 min (uptime) -> the HTTP fallback listens on 8095
#         (254-p3 §3.8.2 D6): first seen at 300 s +- 10 s after the stop, not at <= 270 s. Judged as "batman-provd
#         LISTENs on <br-ahwlan IPv4>:8095" (netstat -ltnp): the host is not on the phone-AP port, so the bit-24 rule
#         drops its SYN whether provd listens or not — the design's "連得上" from the phone AP is a manual row. While
#         bluetoothd is stopped, advertising must read unreadable / 0 (the advertising reader's own negative control).
#   HT5   recovery: bluetoothd started -> advertising back -> HealthOK true for 1 min -> no new connections: the
#         listener goes, not before advertising + 50 s and within advertising + 120 s. ⚠️ design: "不收新連線" is
#         judged as the listener closed; "既有的保留" needs a client on the phone AP -> printed as MANUAL, not judged.
#   HT13  firewall reload (twice) -> `bridge batman_http` and `inet batman_http_in` present once each, one rule each
#         (the include deletes and re-creates its tables, F70), inet fw4 present
#   HT22  dbus restarted (then bluetoothd, as prov-misc L10) -> advertising back <= 15 s after the restart, and no
#         listener on 8095 for the next 330 s (P: none before). Discriminating only when HT3 saw the fallback open;
#         otherwise printed as such (a P-only row: it PASSes on a P2 image too).
# Every observation runs DETACHED on the node (setsid, output in $PRD, the staged root-0700 dir) and is fetched with
# qr: a lost ssh connection is "unreadable" (INVALID), never a product verdict. Advertising is read with ble-lib's
# adv_instances (the hardened mgmt.advinfo: stdin closed, lim 10, 3 tries; unreadable while bluetoothd is down).
# Preconditions (otherwise INVALID): br-ahwlan has an IPv4 address (provd binds the fallback there, 254-p3 §3.8.1);
# netstat -ltnp names programs (proven on dropbear's :22). HT3 leaves a detached guard on the node that starts
# bluetoothd again after 900 s if it is still down (the host died mid-arm).
# The other rows need the RB vehicle (P3's prov_test image with its seams) or a client on the phone AP (manual):
# docs/validation/p3-manual-rows.md.
# W (pre-P3 image): no fallback, no tables -> HT3 "not listening after 300 s", HT5's P (listening) not met, HT13 FAIL.
# Type: R. Side effects: bluetoothd down ~6.5 min (BLE provisioning unavailable), firewall reloaded twice, dbus +
# bluetoothd restarted; the restore reboots.
set -u
PR_UNIT=prov-http-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 2400 || { pr_result; exit 1; }
num(){ case "$1" in ''|*[!0-9]*) return 1;; esac; }
kv(){ sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<< " $1" | tail -1; }
# watch <name> <seconds> <node-side body>: start the body detached on the node (ble-lib sourced; T0 = uptime at
# start; the body prints key=value lines and the wrapper ends with DONE), wait, fetch; prints the file's last lines
watch(){
	local n=$1 secs=$2 f="$PRD/$1.out" o t
	# the body goes to the node as a script file (stdin of ssh), so its quoting never meets an outer sh -c '...'
	{ echo ". $PRD/ble-lib-254.sh"; echo 'T0=$(up_s)'
	  echo "ns(){ o=\$(netstat -ltnp 2>/dev/null); printf '%s\n' \"\$o\" | grep -q ':22 .*LISTEN .*/dropbear' || { echo unread; return; }; printf '%s\n' \"\$o\" | grep -c \"\$1\"; }"
	  echo "lsn(){ ns '$BR:8095 .*LISTEN .*/batman-provd'; }; any(){ ns ':8095 .*LISTEN'; }"
	  echo "{"; echo "$3"; echo "} > $f.tmp 2>&1; echo DONE >> $f.tmp; mv $f.tmp $f"; } \
		| q "rm -f $f $f.tmp; cat > $PRD/$n.sh && chmod 700 $PRD/$n.sh && echo WROTE" | grep -q WROTE || { echo "UNREADABLE"; return 1; }
	q "setsid sh $PRD/$n.sh </dev/null >/dev/null 2>&1 &" >/dev/null
	sleep "$secs"
	for t in 1 2 3 4 5 6 7 8 9 10 11 12; do o=$(qr "cat $f 2>/dev/null"); grep -q '^DONE' <<< "$o" && break; sleep 10; done
	grep -q '^DONE' <<< "$o" || { echo "UNREADABLE"; return 1; }
	echo "$o" | tr '\n' ' '
}
BR=$(qr "ip -4 -o addr show br-ahwlan 2>/dev/null | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -1")
ANY="netstat -ltn 2>/dev/null | grep -c ':8095 '"
num "${BR//./}" || { inv "br-ahwlan has no IPv4 address [$BR]: the fallback has nowhere to bind (254-p3 §3.8.1)"; pr_end; pr_result; exit 2; }
# the listener judge needs netstat -p's program column (busybox FEATURE_NETSTAT_PRG): proven on dropbear's own listener
d=$(qr "netstat -ltnp 2>/dev/null | grep -c ':22 .*LISTEN .*/dropbear'")
num "$d" && [ "$d" -ge 1 ] || { inv "netstat -ltnp does not name dropbear's :22 listener [$d]: the batman-provd listener cannot be judged"; pr_end; pr_result; exit 2; }
n=$(qr ". $PRD/ble-lib-254.sh; adv_instances || echo unreadable"); l=$(qr "$ANY")
say "before: br-ahwlan $BR, adv instances [$n], 8095 LISTEN (any process) [$l]"
num "$n" && [ "$n" -ge 1 ] || inv "BLE not advertising before the unit (adv instances [$n])"
if ! num "$l"; then inv "8095 listeners could not be read [$l]"
elif [ "$l" = 0 ]; then ok "8095 not LISTEN while BLE is healthy"
else no "8095 LISTEN [$l] while BLE is healthy (the fallback must be closed)"; fi
# ---- HT3 bluetoothd stopped (polled on the node every 2 s, up to 340 s)
o=$(watch ht3 345 "setsid sh -c 'sleep 900; pidof bluetoothd >/dev/null || /etc/init.d/bluetoothd start' </dev/null >/dev/null 2>&1 &
	/etc/init.d/bluetoothd stop >/dev/null 2>&1; sleep 1; echo bt=\$(pidof bluetoothd | wc -w) adv_down=\$(adv_instances || echo unreadable)
	first=none; early=none; unread=0; while :; do t=\$(( \$(up_s) - T0 )); [ \$t -gt 340 ] && break
		l=\$(lsn); [ \"\$l\" = unread ] && { unread=\$((unread + 1)); sleep 2; continue; }
		[ \"\$l\" -ge 1 ] && { [ \$t -le 270 ] && early=\$t; first=\$t; break; }
		sleep 2; done; echo first=\$first early=\$early unread=\$unread listener=\"\$(netstat -ltnp 2>/dev/null | grep ':8095 ' | tr -s ' ' | cut -d' ' -f4,7 | head -1)\"")
say "HT3: $o"
first=$(kv "$o" first); early=$(kv "$o" early)
if [ "$o" = UNREADABLE ] || ! grep -q 'first=' <<< "$o"; then inv "HT3: the node-side observation could not be read back"; first=unread
else
	if [ "$(kv "$o" bt)" != 0 ]; then inv "HT3: bluetoothd still running after the stop [$o]: nothing judged"; first=unread
	elif [ "$(kv "$o" unread)" != 0 ]; then inv "HT3: $(kv "$o" unread) polls could not read the listeners (netstat): nothing judged"; first=unread
	else
	# with bluetoothd gone adv_instances answers "unreadable" from its pidof guard (ble-lib-254.sh:76): this only shows
	# the reader cannot return a stale count, it is not a negative control of mgmt.advinfo itself
	case "$(kv "$o" adv_down)" in unreadable|0) say "HT3: advertising reads $(kv "$o" adv_down) while bluetoothd is stopped";; *) no "HT3: advertising [$(kv "$o" adv_down)] with bluetoothd stopped";; esac
	if [ "$first" = none ]; then no "HT3: not listening after 300 s (batman-provd never LISTEN on $BR:8095 within 340 s of the bluetoothd stop)"
	else
		[ "$early" = none ] && ok "HT3: not LISTEN at <= 270 s" || no "HT3: LISTEN already at ${early} s (want > 270 s)"
		[ "$first" -ge 290 ] && [ "$first" -le 310 ] && ok "HT3: batman-provd listens on $BR:8095 at ${first} s (300 +- 10)" || no "HT3: first LISTEN at ${first} s (want 290-310)"
	fi
	fi
fi
# ---- HT5 recovery (gone = the first poll with no listener, recorded once)
if ! num "$first"; then inv "HT5: the fallback was not seen open in HT3 (P not met): recovery cannot be judged"
	q "/etc/init.d/bluetoothd start >/dev/null 2>&1" >/dev/null; sleep 10
else
	o=$(watch ht5 185 "/etc/init.d/bluetoothd start >/dev/null 2>&1; adv=none; gone=none; unread=0
		while :; do t=\$(( \$(up_s) - T0 )); [ \$t -gt 180 ] && break
			[ \"\$adv\" = none ] && a=\$(adv_instances) && [ \"\$a\" -ge 1 ] && adv=\$(( \$(up_s) - T0 ))
			if [ \"\$gone\" = none ]; then l=\$(lsn); case \"\$l\" in unread) unread=\$((unread + 1));; 0) gone=\$(( \$(up_s) - T0 ));; esac; fi
			[ \"\$adv\" != none ] && [ \"\$gone\" != none ] && break
			sleep 2; done; echo adv=\$adv gone=\$gone unread=\$unread")
	say "HT5: $o"
	adv=$(kv "$o" adv); gone=$(kv "$o" gone)
	if [ "$o" = UNREADABLE ] || ! grep -q 'gone=' <<< "$o"; then inv "HT5: the node-side observation could not be read back"
	elif [ "$(kv "$o" unread)" != 0 ] && [ "$gone" = none ]; then inv "HT5: $(kv "$o" unread) polls could not read the listeners and none saw it gone: nothing judged"
	else
		num "$adv" && ok "HT5: advertising back ${adv} s after bluetoothd start" || no "HT5: advertising not back within 180 s"
		if num "$gone" && num "$adv"; then
			# HealthOK true for 1 min before the fallback stops taking connections (D6): the listener may go no earlier
			# than 50 s after bluetoothd's start and no earlier than advertising + 30 s (the advertising time is taken
			# after the read returns; review rounds 2 B-6 / 3 A-m3), no later than advertising + 120 s
			lo=$((adv + 30)); [ $lo -lt 50 ] && lo=50
			[ "$gone" -ge $lo ] && [ "$gone" -le $((adv + 120)) ] && ok "HT5: no new connections ${gone} s after bluetoothd start, advertising back at ${adv} s (want ${lo}..$((adv + 120)) s: HealthOK true for 1 min first)" \
				|| no "HT5: the listener went at ${gone} s, advertising back at ${adv} s (want ${lo}..$((adv + 120)) s)"
		else no "HT5: the listener still there 180 s after bluetoothd came back [gone=$gone adv=$adv]"; fi
	fi
	say "MANUAL HT5: an HTTP session established during the fallback is kept after recovery — needs a client on the phone AP (p3-manual-rows)"
fi
# ---- HT13 firewall reload, twice
tb(){ qr 'nft list tables 2>/dev/null | grep -c "^table bridge batman_http$"; nft list tables 2>/dev/null | grep -c "^table inet batman_http_in$"; nft list table bridge batman_http 2>/dev/null | grep -c "0x01000000"; nft list table inet batman_http_in 2>/dev/null | grep -c "dport 8095"' | tr '\n' ' '; }
t=$(tb); say "HT13 before: tables bridge/inet, rules bridge/inet = $t"
for _ in 1 2; do q '/etc/init.d/firewall reload >/dev/null 2>&1' >/dev/null; sleep 3; done
t2=$(tb); say "HT13 after 2 reloads: $t2"
if [ "$(echo $t2 | wc -w)" != 4 ]; then inv "HT13: the tables could not be read [$(echo $t2)]"
elif [ "$(echo $t2)" = "1 1 1 1" ]; then ok "HT13: after two reloads both tables present once, one rule each"
else no "HT13: after two reloads tables bridge/inet, rules bridge/inet = [$(echo $t2)] (want 1 1 1 1)"; fi
f=$(qr 'nft list tables 2>/dev/null | grep -c "inet fw4"')
if ! num "$f"; then inv "HT13: inet fw4 could not be read [$f]"; elif [ "$f" = 1 ]; then ok "HT13: inet fw4 present after the reloads"; else no "HT13: inet fw4 [$f] after the reloads"; fi
# ---- HT22 dbus restart
n=$(qr ". $PRD/ble-lib-254.sh; adv_instances || echo unreadable"); l=$(qr "$ANY")
num "$n" && [ "$n" -ge 1 ] || inv "HT22: BLE not advertising before the dbus restart [$n] (P)"
[ "$l" = 0 ] || inv "HT22: 8095 LISTEN [$l] before the dbus restart (P: the fallback must be closed first)"
o=$(watch ht22 335 "/etc/init.d/dbus restart >/dev/null 2>&1; /etc/init.d/bluetoothd restart >/dev/null 2>&1; T0=\$(up_s); adv=none; lis=none; unread=0
	while :; do t=\$(( \$(up_s) - T0 )); [ \$t -gt 330 ] && break
		[ \"\$adv\" = none ] && a=\$(adv_instances) && [ \"\$a\" -ge 1 ] && adv=\$(( \$(up_s) - T0 ))
		if [ \"\$lis\" = none ]; then l=\$(any); case \"\$l\" in unread) unread=\$((unread + 1));; 0) ;; *) lis=\$t;; esac; fi
		sleep 2; done; echo adv=\$adv lis=\$lis unread=\$unread")
say "HT22: $o"
if [ "$o" = UNREADABLE ] || ! grep -q 'lis=' <<< "$o"; then inv "HT22: the node-side observation could not be read back"
else
	adv=$(kv "$o" adv); lis=$(kv "$o" lis)
	[ "$lis" = none ] && [ "$(kv "$o" unread)" != 0 ] && { inv "HT22: $(kv "$o" unread) polls could not read the listeners: 'no fallback' is not proven"; lis=unread; }
	num "$adv" && [ "$adv" -le 15 ] && ok "HT22: advertising back ${adv} s after the restart" || no "HT22: advertising back at [$adv] s (want <= 15)"
	if [ "$lis" = unread ]; then :
	elif [ "$lis" = none ]; then
		num "$first" && ok "HT22: no HTTP fallback in the 330 s after the dbus restart" || say "HT22: no listener in 330 s — NOT discriminating on this image (HT3 never saw the fallback open)"
	else no "HT22: 8095 LISTEN at ${lis} s after the dbus restart"; fi
fi
pr_end
pr_result
