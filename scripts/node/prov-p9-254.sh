#!/bin/sh
# scripts/node/prov-p9-254.sh — #254 preflight P9 on a node (docs/design/254-h23-harness.md §4.7, §22.2, §23.4):
# what an earlier prov run may have left behind, and whether a -wbox TEST image could become (or is) the default.
# Read-only (a temporary read-only mount of the other slot's squashfs under a mktemp dir, removed). Run as root via
# `ssh node sh -s`; every line is FAIL / WARN / INFO / ok; the last line is "P9 clean" or "P9 fails=<n>".
# busybox ash.
set -u
# P9_TEST_ROOT (tests/prov-p1/p9-judge.sh only, never set on a node): every fixed path below is read under it
P9R=${P9_TEST_ROOT:-}; MI=${P9R:+$P9R/mountinfo}; MI=${MI:-/proc/self/mountinfo}
[ -n "$P9R" ] || [ "$(id -u)" = 0 ] || { echo "FAIL P9 root only"; echo "P9 fails=1"; exit 1; }
fails=0
no(){ echo "FAIL $*"; fails=$((fails + 1)); }
ST=$P9R/opt/batdata/state; BT=$P9R/tmp/run/batman-dv/bt
KPD=$P9R/tmp/run/batman-prov-test
iswbox(){ [ -f "$1" ] && [ ! -L "$1" ] && grep -q '^BATMAN_VERSION=' "$1" || return 2   # same rule as batman-slot wbox_stamp
	grep -q '^BATMAN_WBOX=.' "$1" && return 0; sed -n 's/^BATMAN_VERSION=//p' "$1" | grep -q '\.wbox-' && return 0; return 1; }
alive(){ case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ -d "/proc/$1" ]; }

act=$(batman-slot active 2>/dev/null); batman-slot is-trial >/dev/null 2>&1; tr=$?
ver=$(sed -n "s/^BATMAN_VERSION=//p" $P9R/rom/etc/batman-build 2>/dev/null)
echo "INFO slot=$act is_trial=$tr ver=$ver"
# --- the running image and the committed slot
iswbox $P9R/rom/etc/batman-build; r=$?
[ "$r" = 2 ] && no "the running image's /rom/etc/batman-build is unreadable"
[ "$r" = 0 ] && [ "$tr" = 1 ] && no "the COMMITTED running slot $act is a -wbox test image ($ver) — commit a release image on a release slot; never run a prov unit here"
[ "$r" = 0 ] && [ "$tr" != 1 ] && echo "INFO running a -wbox trial ($ver)"
for s in A B; do
	p=$(cat "$ST/slot-$s.protected" 2>/dev/null)
	case "$p" in *wbox*)
		if [ "$s" = "$act" ] && [ "$tr" = 1 ]; then no "slot-$s.protected names a wbox image ($p) on the committed slot"
		else no "slot $s holds a -wbox image ($p) — restore it: scripts/dv/prov-254.sh pr_brewrite (B back to V)"; fi ;;
	esac
done
[ "$tr" = 1 ] && [ -z "$(cat "$ST/slot-$act.protected" 2>/dev/null)" ] && echo "WARN slot-$act.protected is missing on the committed slot"
# --- [all] (§23.4): only on a Pi 4 A/B card
if [ "$(batman-slot layout 2>/dev/null)" = pi4 ] && [ -f $P9R/boot/autoboot.txt ]; then
	. $P9R/usr/lib/batman/bootfacts.sh 2>/dev/null
	x=$(bf_ab_all "$P9R/boot"); fa=$(batman-slot fw-part A 2>/dev/null); fb=$(batman-slot fw-part B 2>/dev/null)
	case "$x" in 1|2) ;; *) no "[all] boot_partition unreadable or not 1|2 ([$x])" ;; esac
	[ -n "$fa" ] && [ -n "$fb" ] && [ -n "$act" ] || no "batman-slot fw-part / active unreadable (A=[$fa] B=[$fb] active=[$act])"
	S=""; [ "$x" = "$fa" ] && S=A; [ "$x" = "$fb" ] && S=B
	trialnow=0; [ "$(bf_dt tryboot)" = 00000001 ] && [ "$tr" = 0 ] && trialnow=1
	[ $trialnow = 1 ] && echo "INFO trial in progress (DT tryboot=1, slot $act)"
	# [all] == the running slot outside a trial = an ordinary committed node: nothing to judge
	if [ -n "$S" ] && { [ "$S" != "$act" ] || [ $trialnow = 1 ]; }; then
		dev=/dev/mmcblk0p2; [ "$S" = B ] && dev=/dev/mmcblk0p4
		{
			mkdir -p -m 700 $P9R/tmp/run/batman-dv 2>/dev/null; m=$(mktemp -d $P9R/tmp/run/batman-dv/p9.XXXXXX)
			if mount -t squashfs -o ro "$dev" "$m" 2>/dev/null; then
				iswbox "$m/etc/batman-build"; w=$?; sv=$(sed -n 's/^BATMAN_VERSION=//p' "$m/etc/batman-build" 2>/dev/null)
				umount "$m"; rmdir "$m"
				p=$(cat "$ST/slot-$S.protected" 2>/dev/null)
				case "$w" in
					0) no "[all] points at slot $S, a -wbox image ($sv) — on the release slot run: batman-slot commit" ;;
					2) no "[all] points at slot $S whose build stamp is unreadable" ;;
					1) [ -n "$p" ] && [ "$p" != "$sv" ] && no "slot-$S.protected [$p] != slot $S's own stamp [$sv]"
					   [ $trialnow = 0 ] && echo "WARN [all] points at slot $S, not the running $act (stale fallback / Pi 4 EEPROM booted the wrong slot) — $sv" ;;
				esac
			else rmdir "$m" 2>/dev/null; no "[all] points at slot $S but its squashfs ($dev) cannot be mounted"; fi
		}
	fi
	[ -z "$S" ] && [ -n "$x" ] && no "[all]=$x is neither slot's firmware partition (A=$fa B=$fb)"
else echo "INFO [all] check not applicable (not a Pi 4 A/B card)"; fi
# --- the helper
m=$(grep -c BATMAN_PROV_TEST_BUILD_7f3a $P9R/usr/bin/batman-provhelper 2>/dev/null); [ "${m:-0}" = 0 ] || no "the running helper carries the prov_test marker"
hp=$(pidof batman-provhelper | awk '{print $1}')
[ -n "$hp" ] && logread 2>/dev/null | grep -q "batman-provhelper\[$hp\]: killpoint .*: armed" && no "helper pid $hp has a killpoint armed"
$P9R/usr/bin/batman-provhelper --version >/dev/null 2>&1 || echo "INFO pre-P1b helper (no --version): units that need the seams FAIL 'pre-P1b image'"
grep -q 'holds a -wbox test image' $P9R/usr/sbin/batman-slot 2>/dev/null || echo "INFO pre-gate image (batman-slot has no wbox gate): -wbox units FAIL 'pre-gate image' before any OTA"
# --- leftovers of a prov run
d=$(cat "$ST/dv-prov-dirty" 2>/dev/null); [ -n "$d" ] && no "dv-prov-dirty [$d]: run scripts/dv/prov-254.sh restore for that run (snapshot /opt/batdata/dv-prov/<run>)"
n=$(cat "$ST/dv-prov-normalising" 2>/dev/null); [ -n "$n" ] && no "dv-prov-normalising [$n]: pr_normalise was interrupted — check the slots, then rm $ST/dv-prov-normalising"
b=$(awk 'index($4, "/batman-dv/wbox/") {print $5}' "$MI" | tr '\n' ' '); [ -n "$b" ] && no "harness bind mounts left: $b (prov-wbox-254.sh unbind-all)"
[ -e "$KPD" ] && no "the killpoint dir $KPD exists (left behind by a prov run)"
# provd reads provd.env only at start: removing the dir does not take a switch away (254-p2-impl L83)
if [ -z "$P9R" ]; then for p in $(pidof batman-provd); do
	tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q -E '^(SOCK_ONLY|FAST_FAKE_DELAY_MS|NO_BRUTE_LIMIT|GATT_ENCRYPT_CTRL|ADV_LEN_TEST)=' && no "batman-provd pid $p runs with a prov_test switch from an earlier run: /etc/init.d/batman-provd restart"
done; fi
[ -f $P9R/opt/batdata/dv-prov/ch1-deadman.sh ] && no "chain-1 dead-man left on p6 (/opt/batdata/dv-prov/ch1-deadman.sh)"
bs=$(cat "$ST/bad-slot" 2>/dev/null); [ -n "$bs" ] && no "bad-slot [$bs] — $(case "$bs" in *wbox*) echo "a reverted wbox trial: rm $ST/bad-slot after checking";; *) echo "may be a normalise residue; check, then rm $ST/bad-slot";; esac)"
for f in $(ls -d $P9R/tmp/run/batman-dv/*/rbarm.pid $P9R/tmp/run/batman-dv/*/rbfix.pid 2>/dev/null); do alive "$(cat "$f")" && no "a rollback arm is still running ($f pid $(cat "$f"))"; done
for f in "$BT/lease-prov" "$BT/lease"; do
	[ -f "$f" ] || continue; set -- $(cat "$f")
	[ "${2:-}" = "$(cat /proc/sys/kernel/random/boot_id)" ] && no "${f##*/} of run $1 still present (expires at uptime ${3:-?})"
done
for f in $P9R/tmp/run/batman-dv/ble-state/dm $P9R/tmp/run/batman-dv/ble-state/dm.new; do
	[ -f "$f" ] && set -- $(cat "$f") && alive "${3:-}" && grep -q dm-fire "/proc/$3/cmdline" 2>/dev/null && no "a deadman is armed (${f##*/}: $*)"
done
# --- recorded only
t=$(cat "$ST/autocommit.timeout" 2>/dev/null); [ -n "$t" ] && [ "$t" -gt 600 ] 2>/dev/null && echo "INFO p6 autocommit.timeout=$t (> 600: every REVERT unit waits longer)"
echo "INFO kernel.sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)"
[ $fails = 0 ] && echo "P9 clean" || echo "P9 fails=$fails"
[ $fails = 0 ]
