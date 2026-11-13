#!/bin/bash
# scripts/dv/test-restore-254.sh — offline: the restore / finish path (review 2026-11-09 B-MAJOR-3 / A-MAJOR-2 / A-MAJOR-1).
#   restore_nodes_line (prov-bench-s0-254.sh): the nodes.txt line follows the snapshot's own prov state.
#   a_back (fresh-254.sh): after restore_all's reboot, A is found by MAC wherever it answers; NODE follows it.
#   pr_finish_snap (prov-254.sh): every refused finish is a NEEDS-PERSON; a wrong end state gets one more final restore;
#   an unread start state is fail-closed (A-MAJOR-1 / B-MINOR-4).
# All three are extracted from the files under test (ROOT=<tree> tests another checkout; a missing function = FAIL).
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); ROOT=${ROOT:-$H}
pass=0; fail=0
ok(){ echo "ok   $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fail=$((fail + 1)); }
say(){ :; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# ---- restore_nodes_line
eval "$(sed -n '/^restore_nodes_line(){/,/^}/p' "$ROOT/scripts/dv/prov-bench-s0-254.sh")"
if type restore_nodes_line >/dev/null 2>&1; then
	ok "restore_nodes_line extracted"
	o=$(restore_nodes_line member 04 ch1x d); rc=$?
	[ $rc = 0 ] && [ -z "$o" ] && ok "member snapshot: no nodes.txt line (the node stays on N0)" || no "member snapshot wrote [$o] rc=$rc"
	for st in legacy unclaimed claimed absent -; do
		o=$(restore_nodes_line "$st" 04 s004x 2026-11-09); [ "$o" = "node=04 restored=s004x date=2026-11-09" ] && ok "$st snapshot: restored= line" || no "$st snapshot: [$o]"
	done
	for st in "" garbage "member extra" Member; do
		restore_nodes_line "$st" 04 r d >/dev/null && no "state [$st] accepted" || ok "state [$st]: refused (nothing written)"
	done
	# end to end with bench_ip (bench-254.sh, the one reader): a member restore leaves 04's address readable
	. "$ROOT/scripts/dv/bench-254.sh"
	wsl.exe(){ cat "$T/nodes.txt"; }
	printf 'node=04 run=keep-s004 date=d ip=10.41.80.13 mac=m sn=s version=v\n' > "$T/nodes.txt"
	restore_nodes_line member 04 ch1x d >> "$T/nodes.txt"
	[ "$(bench_ip 04)" = 10.41.80.13 ] && ok "after a member restore bench_ip 04 still gives its address" || no "bench_ip 04 after a member restore: [$(bench_ip 04)]"
	restore_nodes_line legacy 04 s004 d >> "$T/nodes.txt"
	[ -z "$(bench_ip 04)" ] && ok "after a legacy restore bench_ip 04 is empty (off N0)" || no "bench_ip 04 after a legacy restore: [$(bench_ip 04)]"
	unset -f wsl.exe
else no "restore_nodes_line not found in $ROOT/scripts/dv/prov-bench-s0-254.sh"; fi


# ---- pr_finish_snap (prov-254.sh): every refused finish is a NEEDS-PERSON; a wrong end state gets one more restore
# (review 2026-11-09 A-MAJOR-1 / B-MINOR-4). Stubs: the node's prov.meta state, pr_restore, nb finish, pr_needs_person.
eval "$(sed -n '/^pr_meta_state(){/p; /^pr_s0_ok(){/p; /^pr_finish_snap(){/,/^}/p' "$ROOT/scripts/dv/prov-254.sh")"
if type pr_finish_snap >/dev/null 2>&1; then
	ok "pr_finish_snap extracted"
	qr(){ cat "$T/meta"; }; nb(){ echo "nb $*" >> "$T/calls"; [ -e "$T/refuse" ] && echo "REFUSED x" || echo "FINISHED $RUN"; }
	pr_restore(){ echo "restore final=${PR_FINAL:-0}" >> "$T/calls"; [ -e "$T/rfail" ] && { echo "person restore" >> "$T/calls"; PR_PERSON=1; return 1; }; [ -e "$T/fixes" ] && echo member > "$T/meta"; return 0; }
	sleep(){ :; }
	pr_needs_person(){ echo "person $*" >> "$T/calls"; return 1; }
	no(){ echo "no $*" >> "$T/calls"; }; ok_(){ :; }
	fs(){ # <S0> <end state> [fixes] [refuse]: runs pr_finish_snap, prints rc and the calls
		: > "$T/calls"; rm -f "$T/fixes" "$T/refuse" "$T/rfail"; PR_PERSON=0; echo "$2" > "$T/meta"; local a; for a in "${@:3}"; do : > "$T/$a"; done
		PR_S0_STATE=$1; PR_SNAPPED=1; RUN=r1; ( ok(){ :; }; pr_finish_snap; echo "rc=$? snapped=$PR_SNAPPED" >> "$T/calls" ); tr '\n' '|' < "$T/calls"; }
	no(){ echo "FAIL $*"; fail=$((fail + 1)); }
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member member)
	case "$c" in "nb finish r1|rc=0 snapped=0|") ok "end = start: finished" ;; *) no "end = start: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member legacy fixes)
	case "$c" in "restore final=1|no "*"|nb finish r1|rc=0 snapped=0|") ok "end legacy, S0 member: one final restore, one FAIL, then finished" ;; *) no "second restore path: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member legacy)
	case "$c" in *"restore final=1|person "*"rc=1 snapped=1|") case "$c" in *"nb finish"*) no "finished on a wrong state: [$c]" ;; *) ok "still legacy after the second restore: NEEDS-PERSON, not finished" ;; esac ;; *) no "wrong end state: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs "" member)
	case "$c" in "person "*"rc=1 snapped=1|") ok "start state unread: NEEDS-PERSON, not finished (fail-closed)" ;; *) no "empty start state: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member member refuse)
	case "$c" in *"nb finish r1|person "*"rc=1 snapped=1|") ok "finish refused: NEEDS-PERSON" ;; *) no "refused finish: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member "")
	case "$c" in "person "*"rc=1 snapped=1|") ok "end state unreadable: NEEDS-PERSON, no restore (round 5 B-MINOR-7)" ;; *) no "unreadable end state: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member legacy rfail)
	n=$(echo "$c" | tr '|' ' ' | grep -o 'person\|no ' | wc -l)
	case "$c" in "restore final=1|person restore|rc=1 snapped=1|") ok "second restore fails: counted once (its NEEDS-PERSON), not finished" ;; *) no "failed second restore: [$c] ($n counts)" ;; esac
	unset -f qr nb pr_restore pr_needs_person fs ok_ sleep
else no "pr_finish_snap not found in $ROOT/scripts/dv/prov-254.sh"; fi
# ---- a_back: A answers at 10.0.0.7, NODE is the kept member's address 10.41.80.13
MAC=88:a2:9e:b5:6c:89; V=1.5.14-wsl.22; ST=x; FRESHO=""; SEEN=""; MDNS=none
ping(){ return 0; }; timeout(){ shift; "$@"; }; sweep(){ :; }; sleep(){ :; }
macips(){ echo 10.0.0.7; }
ssh(){ local a h=""; for a; do case "$a" in root@10.0.0.7) h=y;; esac; done; [ -n "$h" ] || return 255
	case "${*: -1}" in "cat /sys/class/net/eth0/address") echo "accept-new=$(case "$*" in *StrictHostKeyChecking=accept-new*) echo y;; esac)" >> "$T/pin"; printf '%s\n' "$HKMAC";; *) printf '%s\n' "$STATE";; esac; }
ssh-keygen(){ echo "keygen $*" >> "$T/pin"; }
eval "$(sed -n '/^is_on(){/p; /^find04(){/,/^}/p; /^wait_find(){/p; /^a_back(){/,/^}/p; /^repin(){/p' "$ROOT/scripts/dv/fresh-254.sh")"
if type a_back >/dev/null 2>&1; then
	ok "a_back extracted"
	NODE=10.41.80.13; STATE="mac=$MAC slot=A ver=$V trial_rc=1 dt_try=0 hold=[] held=0 badslot=[] up=30 boot=bbbbbbbb"
	: > "$T/pin"; HKMAC=$MAC; SSHO=""
	a_back aaaaaaaa 2 && [ "$NODE" = 10.0.0.7 ] && [ "$FIP" = 10.0.0.7 ] && ok "A back at another address: found by MAC, NODE=$NODE" || no "a_back: NODE=$NODE FIP=$FIP"
	[ "$(tr '\n' ' ' < "$T/pin")" = "keygen -R 10.0.0.7 accept-new=y " ] && ok "a_back: the old host key of 10.0.0.7 removed, pinned again (accept-new) on MAC $MAC (round 5 A-MINOR-2 / B-MINOR-6)" || no "a_back pin: [$(tr '\n' ' ' < "$T/pin")]"
	NODE=10.41.80.13; HKMAC=11:22:33:44:55:66; : > "$T/pin"
	a_back aaaaaaaa 2 && no "a_back accepted a node whose MAC under the new pin is another board's" || ok "a_back: another MAC under the new pin fails"
	[ "$(grep -c '^keygen -R 10.0.0.7$' "$T/pin")" = 2 ] && ok "a_back: the other board's key just taken is removed again (round 7 A-MINOR-1)" || no "repin mismatch left the key: [$(tr '
' ' ' < "$T/pin")]"
	HKMAC=$MAC
	NODE=10.41.80.13; STATE="mac=$MAC slot=A ver=$V trial_rc=1 dt_try=0 hold=[] held=0 badslot=[] up=30 boot=aaaaaaaa"
	a_back aaaaaaaa 2 && no "a_back accepted the boot before the reboot" || { [ "$NODE" = 10.41.80.13 ] && ok "the old boot is not 'back' (NODE unchanged)" || no "NODE changed on a miss: $NODE"; }
	NODE=10.41.80.13; STATE="mac=$MAC slot=B ver=$V trial_rc=1 dt_try=0 hold=[] held=0 badslot=[slot=A ver=$V trial_rc=1 ] up=30 boot=bbbbbbbb"
	a_back aaaaaaaa 2 && no "a_back took B (with slot=A inside badslot) for A" || ok "B with badslot=[slot=A …] is not A back"
else
	no "a_back not found in $ROOT/scripts/dv/fresh-254.sh"
	# the code it replaced polled NODE only: show that misses the same A (the regression B-MAJOR-3 describes)
	NODE=10.41.80.13; STATE="mac=$MAC slot=A ver=$V trial_rc=1 dt_try=0 hold=[] held=0 badslot=[] up=30 boot=bbbbbbbb"
	eval "$(sed -n '/^is_on(){/p' "$ROOT/scripts/dv/fresh-254.sh")"
	is_on $NODE "slot=A ver=$V trial_rc=1 " >/dev/null && echo "     (old: polling NODE finds A)" || echo "     (old: polling NODE=$NODE misses the A at 10.0.0.7)"
fi
unset -f ping timeout sweep sleep macips ssh ssh-keygen
# ---- pr_begin reads the start state BEFORE the snapshot (round 5 A-MINOR-5: after it, a failed read cost a full
# restore of an untouched node). Order check on the real function body (a structural check: the behaviour needs a node).
pb=$(sed -n '/^pr_begin(){/,/^}/p' "$ROOT/scripts/dv/prov-254.sh")
l1=$(echo "$pb" | grep -n 'PR_S0_STATE=$(pr_meta_state)' | head -1 | cut -d: -f1); l2=$(echo "$pb" | grep -n 'nb snap' | head -1 | cut -d: -f1)
[ -n "$l1" ] && [ -n "$l2" ] && [ "$l1" -lt "$l2" ] && ok "pr_begin: start state read (line $l1) before the snapshot (line $l2)" || no "pr_begin: start state read at [$l1], snapshot at [$l2]"

# ---- prov-bench-s0: IP= is the run's address in fresh / slota / toa, not in restore (there the legacy A comes back at
# its own address, found by MAC; round 5 A-MINOR-2 m5). The real line, run for each mode.
l=$(grep -n '^\[ "$MODE" = restore \] || NODE=' "$ROOT/scripts/dv/prov-bench-s0-254.sh" | head -1 | cut -d: -f2-)
if [ -n "$l" ]; then
	r=$(MODE=restore; IP=10.41.80.13; NODE=10.41.1.3; eval "$l"; echo "$NODE"); [ "$r" = 10.41.1.3 ] && ok "restore: IP= does not replace NODE" || no "restore: NODE=$r"
	r=$(MODE=fresh; IP=10.41.80.13; NODE=10.41.1.3; eval "$l"; echo "$NODE"); [ "$r" = 10.41.80.13 ] && ok "fresh: IP= is NODE" || no "fresh: NODE=$r"
else no "the MODE / IP line not found in $ROOT/scripts/dv/prov-bench-s0-254.sh"; fi

# ---- moved_keep_line (prov-bench-s0): a member A restored at another address keeps its keep line, at the new address
# (round 6 B-MINOR-6); anything but a keep line, or an address that is not one, is refused
eval "$(sed -n '/^moved_keep_line(){/,/; }$/p' "$ROOT/scripts/dv/prov-bench-s0-254.sh")"
if type moved_keep_line >/dev/null 2>&1; then
	k='node=04 run=keep-s0abc date=2026-11-08 ip=10.41.80.13 mac=88:a2:9e:b5:6c:89 sn=e61551410cfd538e24 version=v1'
	r=$(moved_keep_line "$k" r9 10.41.1.3 2026-11-09)
	[ "$r" = 'node=04 run=keep-restore-r9 date=2026-11-09 ip=10.41.1.3 mac=88:a2:9e:b5:6c:89 sn=e61551410cfd538e24 version=v1' ] && ok "moved keep line: same line, new address and run" || no "moved keep line: [$r]"
	moved_keep_line 'node=04 restored=r1 date=x' r9 10.41.1.3 x >/dev/null && no "moved_keep_line took a restored= line" || ok "moved_keep_line refuses a non-keep line"
	moved_keep_line "$k" r9 '10.41.1.3; rm -rf x' x >/dev/null && no "moved_keep_line took a bad address" || ok "moved_keep_line refuses a bad address"
	# what bench_ip then reads (the real awk of bench-254.sh)
	. "$ROOT/scripts/dv/bench-254.sh"; wsl.exe(){ shift 6; printf '%s\n%s\n' "$k" "$r"; }
	[ "$(bench_ip 04)" = 10.41.1.3 ] && ok "bench_ip gives the new address after the moved keep line" || no "bench_ip after the move: [$(bench_ip 04)]"
	unset -f wsl.exe
else no "moved_keep_line not found in $ROOT/scripts/dv/prov-bench-s0-254.sh"; fi

echo "================ test-restore: $pass passed, $fail failed ================"
[ "$fail" = 0 ]
