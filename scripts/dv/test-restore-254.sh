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
	pr_restore(){ echo "restore final=${PR_FINAL:-0}" >> "$T/calls"; [ -e "$T/fixes" ] && echo member > "$T/meta"; return 0; }
	pr_needs_person(){ echo "person $*" >> "$T/calls"; return 1; }
	no(){ echo "no $*" >> "$T/calls"; }; ok_(){ :; }
	fs(){ # <S0> <end state> [fixes] [refuse]: runs pr_finish_snap, prints rc and the calls
		: > "$T/calls"; rm -f "$T/fixes" "$T/refuse"; echo "$2" > "$T/meta"; local a; for a in "${@:3}"; do : > "$T/$a"; done
		PR_S0_STATE=$1; PR_SNAPPED=1; RUN=r1; ( ok(){ :; }; pr_finish_snap; echo "rc=$? snapped=$PR_SNAPPED" >> "$T/calls" ); tr '\n' '|' < "$T/calls"; }
	no(){ echo "FAIL $*"; fail=$((fail + 1)); }
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member member)
	case "$c" in "nb finish r1|rc=0 snapped=0|") ok "end = start: finished" ;; *) no "end = start: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member legacy fixes)
	case "$c" in no*"restore final=1|"*"nb finish r1|rc=0 snapped=0|") ok "end legacy, S0 member: one final restore, then finished" ;; *) no "second restore path: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member legacy)
	case "$c" in *"restore final=1|person "*"rc=1 snapped=1|") case "$c" in *"nb finish"*) no "finished on a wrong state: [$c]" ;; *) ok "still legacy after the second restore: NEEDS-PERSON, not finished" ;; esac ;; *) no "wrong end state: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs "" member)
	case "$c" in "person "*"rc=1 snapped=1|") ok "start state unread: NEEDS-PERSON, not finished (fail-closed)" ;; *) no "empty start state: [$c]" ;; esac
	c=$(no(){ echo "no $*" >> "$T/calls"; }; fs member member refuse)
	case "$c" in *"nb finish r1|person "*"rc=1 snapped=1|") ok "finish refused: NEEDS-PERSON" ;; *) no "refused finish: [$c]" ;; esac
	unset -f qr nb pr_restore pr_needs_person fs ok_
else no "pr_finish_snap not found in $ROOT/scripts/dv/prov-254.sh"; fi
# ---- a_back: A answers at 10.0.0.7, NODE is the kept member's address 10.41.80.13
MAC=88:a2:9e:b5:6c:89; V=1.5.14-wsl.22; ST=x; FRESHO=""; SEEN=""; MDNS=none
ping(){ return 0; }; timeout(){ shift; "$@"; }; sweep(){ :; }; sleep(){ :; }
macips(){ echo 10.0.0.7; }
ssh(){ local a; for a; do case "$a" in root@10.0.0.7) printf '%s\n' "$STATE"; return 0;; esac; done; return 255; }
eval "$(sed -n '/^is_on(){/p; /^find04(){/,/^}/p; /^wait_find(){/p; /^a_back(){/,/^}/p' "$ROOT/scripts/dv/fresh-254.sh")"
if type a_back >/dev/null 2>&1; then
	ok "a_back extracted"
	NODE=10.41.80.13; STATE="mac=$MAC slot=A ver=$V trial_rc=1 dt_try=0 hold=[] held=0 badslot=[] up=30 boot=bbbbbbbb"
	a_back aaaaaaaa 2 && [ "$NODE" = 10.0.0.7 ] && [ "$FIP" = 10.0.0.7 ] && ok "A back at another address: found by MAC, NODE=$NODE" || no "a_back: NODE=$NODE FIP=$FIP"
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
unset -f ping timeout sweep sleep macips ssh

echo "================ test-restore: $pass passed, $fail failed ================"
[ "$fail" = 0 ]
