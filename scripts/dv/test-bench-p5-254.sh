#!/bin/bash
# scripts/dv/test-bench-p5-254.sh — offline tests (no node) of two bench helpers (#254 H5 review round 2, A-m9):
#   bench_ip (scripts/dv/bench-254.sh): keep line, restored= last line, a line without " ip=", a missing store
#   p5_ap_back (scripts/fault-injection.sh, P5's AP-key restore): every guard and both outcomes, with the node calls
#   stubbed: sysupgrade running / committed on another slot / already at baseline -> nothing written; the write
#   refused -> FAIL and no reboot; the write done, AP gone before the reboot -> PASS; the negative control: the write
#   "done" but the AP still up before the reboot -> FAIL (what the pre-reboot check exists for)
# Prints "ok"/"FAIL" lines and "N passed, M failed"; rc 1 on any FAIL. Run by scripts/test-h4-offline-254.sh.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
P=0; F=0
tok(){ echo "ok   $1"; P=$((P + 1)); }
tbad(){ echo "FAIL $1"; F=$((F + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- bench_ip: the store is read through wsl.exe -- cat <file>; the stub prints $T/nodes.txt
. "$REPO/scripts/dv/bench-254.sh"
wsl.exe(){ [ -f "$T/nodes.txt" ] && cat "$T/nodes.txt"; }
bi(){ printf '%s\n' "$@" > "$T/nodes.txt"; bench_ip 04; }
[ "$(bi 'node=04 run=keep-a date=d ip=10.1.2.3 mac=m sn=s' 'node=02 run=keep-b date=d ip=10.9.9.9 mac=m')" = 10.1.2.3 ] && tok "bench_ip: keep line -> its address" || tbad "bench_ip keep line"
[ -z "$(bi 'node=04 run=keep-a date=d ip=10.1.2.3 mac=m' 'node=04 restored=a date=d')" ] && tok "bench_ip: restored= last line -> nothing" || tbad "bench_ip restored line"
[ "$(bi 'node=04 restored=a date=d' 'node=04 run=keep-c date=d ip=10.4.4.4 mac=m')" = 10.4.4.4 ] && tok "bench_ip: keep after restored -> the new address" || tbad "bench_ip keep after restored"
[ -z "$(bi 'node=04 run=keep-a date=d ip=10.1.2.3')" ] && tok "bench_ip: no space after ip= (truncated line) -> nothing" || tbad "bench_ip truncated line"
rm -f "$T/nodes.txt"; [ -z "$(bench_ip 04)" ] && tok "bench_ip: no store -> nothing" || tbad "bench_ip no store"
unset -f wsl.exe

# ---- p5_ap_back with the node stubbed
FI_SOURCE_ONLY=1 . "$REPO/scripts/fault-injection.sh" testnode --case p5 >/dev/null 2>&1
trap 'rm -rf "$T"' EXIT
PH=$(printf 'CHANGE-ME-NOW\n' | md5sum | cut -c1-8)
# the scenario: SUP (sysupgrade count), SLOT, IT (is-trial rc), STAT (status ap line), KEY (live key), WRITE (the
# node script's output), POSTSTAT / POSTKEY (after the reboot); calls logged to $T/calls
q(){ echo "q $*" >> "$T/calls"
	case "$*" in
		*'[s]ysupgrade'*) echo "$SUP" ;;
		*'halow-setkey --status'*) if [ -e "$T/rebooted" ]; then echo "$POSTSTAT"; else echo "$STAT"; fi ;;
		*'wireless.default_radio0.key'*) if [ -e "$T/rebooted" ]; then echo "$POSTKEY"; else echo "$KEY"; fi ;;
		*'batman-config-save --check'*) if [ -e "$T/rebooted" ]; then echo "batman-config-save: p5 fresh"; echo "ifs=2 apif=0 radio0=false"; else echo "$P5CHK"; fi ;;
	esac; }
n(){ echo "n $*" >> "$T/calls"; touch "$T/rebooted"; }
ssh(){ echo "ssh-write" >> "$T/calls"; cat >/dev/null; echo "$WRITE"; }
# p5_ap_back writes with `timeout 240 ssh ...`: timeout(1) would exec the real ssh, not the stub above (a first draft
# of this test "passed" its refused / negative cases on a real ssh error) -> run the stub; no real ssh may be reached
timeout(){ shift; "$@"; }
command -v ssh >/dev/null 2>&1 && [ "$(type -t ssh)" = function ] || { echo "FAIL the ssh stub is not in place"; exit 1; }
slot(){ echo "$SLOT"; }
committed(){ return "$IT"; }
bootid(){ echo b1; }
waitboot(){ return 0; }
settle(){ return 0; }
ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; }
# DV_DIR: the run dir the suite passes; needs-person.txt there is what blocks the run's later D suites
export DV_DIR=$T/dv; mkdir -p "$DV_DIR"
run(){ rm -f "$T/calls" "$T/rebooted" "$DV_DIR/needs-person.txt"; touch "$T/calls"; p5_ap_back CHANGE-ME-NOW "$PH" A; }
np(){ grep -q '^NEEDS-PERSON reflash-survives-config-202' "$DV_DIR/needs-person.txt" 2>/dev/null; }
base(){ SUP=0 SLOT=A IT=0 STAT="ap   default_radio0   ssid=x key=set disabled=0" KEY=fi202-abc POSTSTAT="ap   default_radio0   ssid=x key=PLACEHOLDER disabled=1" POSTKEY=CHANGE-ME-NOW
	WRITE=$'pre_ifs=2 pre_apif=0\nsave_rc=0' P5CHK="batman-config-save: p5 fresh"; }
nw(){ ! grep -q '^ssh-write' "$T/calls"; }; nr(){ [ ! -e "$T/rebooted" ]; }
base; SUP=1; o=$(run); grep -q 'FAIL.*sysupgrade is running' <<< "$o" && nw && nr && np && tok "p5_ap_back: sysupgrade running -> FAIL, nothing written" || tbad "sysupgrade guard: $o"
base; SLOT=B; o=$(run); grep -q 'FAIL.*needs a person' <<< "$o" && nw && nr && np && tok "p5_ap_back: committed on another slot -> FAIL + needs-person.txt, nothing written" || tbad "other slot: $o"
base; STAT="ap   default_radio0   ssid=x key=PLACEHOLDER disabled=1" KEY=CHANGE-ME-NOW; o=$(run); grep -q 'PASS.*nothing written' <<< "$o" && nw && nr && ! np && tok "p5_ap_back: already at baseline (p5 fresh too) -> nothing written" || tbad "baseline no-op: $o"
base; STAT="ap   default_radio0   ssid=x key=PLACEHOLDER disabled=1" KEY=CHANGE-ME-NOW P5CHK="batman-config-save: p5 STALE"; o=$(run); ! grep -q 'nothing written' <<< "$o" && ! nw && tok "p5_ap_back: live at baseline but p5 stale -> written (the test key in p5 would come back)" || tbad "stale p5 no-op: $o"
base; WRITE="REFUSED setkey lock busy"; o=$(run); grep -q 'FAIL.*not rebooting' <<< "$o" && nr && np && tok "p5_ap_back: write refused -> FAIL, no reboot" || tbad "refused write: $o"
base; o=$(run); [ "$(grep -c '^PASS' <<< "$o")" = 2 ] && ! grep -q '^FAIL' <<< "$o" && ! nr && ! np && tok "p5_ap_back: write + AP gone before the reboot + baseline after -> 2 PASS, rebooted once" || tbad "positive: $o"
base; WRITE=$'pre_ifs=2 pre_apif=1\nsave_rc=0'; o=$(run); grep -q 'FAIL.*AP is still up' <<< "$o" && tok "p5_ap_back negative control: AP still up after the write -> FAIL (keyguard's reboot would hide it)" || tbad "negative control: $o"
base; WRITE=$'pre_ifs=0 pre_apif=0\nsave_rc=0'; o=$(run); grep -q 'FAIL.*iw unreadable' <<< "$o" && tok "p5_ap_back: iw lists no interface -> FAIL (not read as AP gone)" || tbad "iw unreadable: $o"
base; WRITE=$'pre_ifs=unread pre_apif=unread (radio0 still pending after 30 s)\nsave_rc=0'; o=$(run); grep -q 'FAIL.*iw unreadable' <<< "$o" && tok "p5_ap_back: radio0 still pending -> FAIL (no fixed-sleep snapshot)" || tbad "pending: $o"
echo "$P passed, $F failed"; [ "$F" = 0 ]
