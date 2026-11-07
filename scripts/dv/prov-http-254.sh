#!/bin/bash
# scripts/dv/prov-http-254.sh — #254 H4 appendix A.7, the rows on the R vehicle (p3-how "n"; the release image, no seam):
#   HT3   bluetoothd stopped -> provd's HealthOK false for 5 min (uptime) -> the HTTP fallback listens on 8095
#         (254-p3 §3.8.2 D6): first seen LISTEN at 300 s +- 10 s after the stop; not LISTEN at <= 270 s
#   HT5   recovery: bluetoothd started -> HealthOK true for 1 min -> no new connections: 8095 no longer LISTEN within
#         120 s, BLE advertising back. ⚠️ design: "不收新連線" is judged as the listener closed; "既有的保留" needs a
#         client on the phone AP (a manual row with the app)
#   HT13  firewall reload (twice) -> `bridge batman_http` and `inet batman_http_in` present once each, one rule each
#         (the include deletes and re-creates its tables, F70)
#   HT22  dbus restarted (then bluetoothd, as prov-misc L10: bluetoothd does not re-attach to a new bus by itself) ->
#         BLE advertising back <= 15 s after bluetoothd's restart, and no HTTP fallback because of it (8095 not LISTEN
#         for the next 330 s)
# The other rows need the RB vehicle (P3's prov_test image with its seams) or a client on the phone AP (manual):
# docs/validation/p3-manual-rows.md. 8095 is judged on the node (netstat): the host is not on the phone AP port, so
# the bit-24 rule drops its SYN whether provd listens or not.
# W (pre-P3 image): no fallback, no tables -> HT3 "not listening after 300 s", HT5's P (listening) not met, HT13 FAIL.
# HT22 has no W (P only): it PASSes on a P2 image too.
# Type: R. Side effects: bluetoothd down ~6.5 min (BLE provisioning unavailable), firewall reloaded twice, dbus +
# bluetoothd restarted; the restore reboots.
set -u
PR_UNIT=prov-http-254
PR_BASE=member
# shellcheck source=scripts/dv/prov-254.sh
. "$(dirname "$0")/prov-254.sh"
pr_begin 2400 || { pr_result; exit 1; }
L8095='netstat -ltn 2>/dev/null | grep -c ":8095 "'
NINST="bluetoothctl mgmt.advinfo 2>/dev/null | sed -n 's/^Instances list with \([0-9]*\) item.*/\1/p' | head -1"
n=$(qr "$NINST"); l=$(qr "$L8095"); say "before: adv instances [$n], 8095 LISTEN [$l]"
[ "${n:-0}" -ge 1 ] 2>/dev/null || inv "BLE not advertising before the unit (adv instances [$n])"
[ "$l" = 0 ] && ok "8095 not LISTEN while BLE is healthy" || no "8095 LISTEN [$l] while BLE is healthy (the fallback must be closed)"
# ---- HT3 bluetoothd stopped: polled on the node every 2 s (the ssh round trip is not in the measurement)
o=$(QT=420 q '/etc/init.d/bluetoothd stop >/dev/null 2>&1; t0=$(cut -d. -f1 /proc/uptime); first=; early=
	while :; do t=$(( $(cut -d. -f1 /proc/uptime) - t0 )); [ $t -gt 340 ] && break
		l=$(netstat -ltn 2>/dev/null | grep -c ":8095 ")
		[ "$l" -ge 1 ] && { [ $t -le 270 ] && early=$t; first=$t; break; }
		sleep 2; done
	echo "first=${first:-none} early=${early:-none} bt=$(pidof bluetoothd | wc -w)"')
say "HT3: $o"
first=$(sed -n 's/.*first=\([0-9a-z]*\).*/\1/p' <<< "$o"); early=$(sed -n 's/.*early=\([0-9a-z]*\).*/\1/p' <<< "$o")
grep -q 'bt=0' <<< "$o" || inv "HT3: bluetoothd still running after the stop [$o]"
case "$first" in
	none|"") no "HT3: not listening after 300 s (8095 never LISTEN within 340 s of the bluetoothd stop)";;
	*) [ "$early" = none ] && ok "HT3: 8095 not LISTEN at <= 270 s" || no "HT3: 8095 LISTEN already at ${early} s (want > 270 s)"
	   [ "$first" -ge 290 ] && [ "$first" -le 310 ] && ok "HT3: the fallback listens at ${first} s (300 +- 10)" || no "HT3: the fallback first LISTEN at ${first} s (want 290-310)";;
esac
# ---- HT5 recovery
case "$first" in none|"") inv "HT5: the fallback was not listening (HT3), recovery cannot be judged (P)";; esac
o=$(QT=200 q '/etc/init.d/bluetoothd start >/dev/null 2>&1; t0=$(cut -d. -f1 /proc/uptime); gone=; adv=
	while :; do t=$(( $(cut -d. -f1 /proc/uptime) - t0 )); [ $t -gt 150 ] && break
		[ -z "$adv" ] && [ "$(bluetoothctl mgmt.advinfo 2>/dev/null | sed -n "s/^Instances list with \([0-9]*\) item.*/\1/p" | head -1)" -ge 1 ] 2>/dev/null && adv=$t
		[ "$(netstat -ltn 2>/dev/null | grep -c ":8095 ")" = 0 ] && { gone=$t; [ -n "$adv" ] && break; }
		sleep 2; done
	echo "gone=${gone:-none} adv=${adv:-none}"')
say "HT5: $o"
gone=$(sed -n 's/.*gone=\([0-9a-z]*\).*/\1/p' <<< "$o"); adv=$(sed -n 's/.*adv=\([0-9a-z]*\).*/\1/p' <<< "$o")
[ "$adv" != none ] && ok "HT5: BLE advertising back ${adv} s after bluetoothd start" || no "HT5: BLE advertising not back within 150 s"
case "$first" in none|"") ;; *)
	[ "$gone" != none ] && [ "$gone" -le 120 ] && ok "HT5: the fallback stopped taking new connections ${gone} s after recovery (8095 not LISTEN)" || no "HT5: 8095 still LISTEN [$gone] 120 s after bluetoothd came back";;
esac
# ---- HT13 firewall reload, twice
tb(){ qr 'nft list tables 2>/dev/null | grep -c "^table bridge batman_http$"; nft list tables 2>/dev/null | grep -c "^table inet batman_http_in$"; nft list table bridge batman_http 2>/dev/null | grep -c "0x01000000"; nft list table inet batman_http_in 2>/dev/null | grep -c "dport 8095"' | tr '\n' ' '; }
t=$(tb); say "HT13 before: tables bridge/inet, rules bridge/inet = $t"
for i in 1 2; do q '/etc/init.d/firewall reload >/dev/null 2>&1' >/dev/null; sleep 3; done
t2=$(tb); say "HT13 after 2 reloads: $t2"
[ "$(echo $t2)" = "1 1 1 1" ] && ok "HT13: after two reloads both tables present once, one rule each" || no "HT13: after two reloads tables bridge/inet, rules bridge/inet = [$(echo $t2)] (want 1 1 1 1)"
f=$(qr 'nft list tables 2>/dev/null | grep -c "inet fw4"'); [ "$f" = 1 ] && ok "HT13: inet fw4 present after the reloads" || no "HT13: inet fw4 [$f] after the reloads"
# ---- HT22 dbus restart
n=$(qr "$NINST"); [ "${n:-0}" -ge 1 ] 2>/dev/null || inv "HT22: BLE not advertising before the dbus restart [$n] (P)"
o=$(QT=420 q '/etc/init.d/dbus restart >/dev/null 2>&1; /etc/init.d/bluetoothd restart >/dev/null 2>&1; t0=$(cut -d. -f1 /proc/uptime); adv=; lis=
	while :; do t=$(( $(cut -d. -f1 /proc/uptime) - t0 )); [ $t -gt 330 ] && break
		[ -z "$adv" ] && [ "$(bluetoothctl mgmt.advinfo 2>/dev/null | sed -n "s/^Instances list with \([0-9]*\) item.*/\1/p" | head -1)" -ge 1 ] 2>/dev/null && adv=$t
		[ -z "$lis" ] && [ "$(netstat -ltn 2>/dev/null | grep -c ":8095 ")" -ge 1 ] && lis=$t
		sleep 2; done
	echo "adv=${adv:-none} lis=${lis:-none}"')
say "HT22: $o"
adv=$(sed -n 's/.*adv=\([0-9a-z]*\).*/\1/p' <<< "$o"); lis=$(sed -n 's/.*lis=\([0-9a-z]*\).*/\1/p' <<< "$o")
[ "$adv" != none ] && [ "$adv" -le 15 ] && ok "HT22: BLE advertising back ${adv} s after the restart" || no "HT22: BLE advertising back at [$adv] s (want <= 15)"
[ "$lis" = none ] && ok "HT22: no HTTP fallback in the 330 s after the dbus restart" || no "HT22: 8095 LISTEN at ${lis} s after the dbus restart"
pr_end
pr_result
