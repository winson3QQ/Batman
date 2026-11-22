#!/bin/bash
# scripts/dv/test-pr02-254.sh — offline: the 02 slot contract (docs/design/254-v16-group4.md §3.1, §13.3, §15).
#   pr_begin (prov-254.sh), extracted with stubbed ssh: a unit that sets PR_USES_02=1 FAILs before pr_acquire unless 02 is
#   A committed on V; any other unit gets a NOTE; a 02 in a trial FAILs every unit; 02 unreachable FAILs a PR_USES_02
#   unit and is a NOTE for the others. pr_need_02 / as02 / restore02 / fleetchan part 1 refuse unless pr_begin recorded
#   the enforced contract (PR_USES_02=1 set BEFORE pr_begin).
#   The PR_USES_02 lint: every scripts/dv unit that calls as02 / restore02, or sends sysupgrade / rb_guarded /
#   reboot_guarded / commit_guarded / batman-slot to 02 through qp (or scp's to root@$PEER), sets PR_USES_02=1 before its
#   pr_begin call. Fixtures prove the lint catches each form; zero units with such a call is a FAIL.
#   pr_restore_cycle prints every ^(P5-|FAIL) line of the node's p5 restore (§3.2 step 5).
# ROOT=<tree> tests another checkout (the negative control on main); a function missing there is a FAIL.
#   bash scripts/dv/test-pr02-254.sh   -> "================ test-pr02: N passed, M failed", rc 1 on any FAIL
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); ROOT=${ROOT:-$H}
pass=0; fail=0
ok(){ echo "ok   $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fail=$((fail + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P=$ROOT/scripts/dv/prov-254.sh

# ---- pr_begin with stubs: 02's state line is $S02; pr_acquire records the call and stops pr_begin there
eval "$(sed -n '/^field(){/p; /^pr_02_check(){/,/^}/p; /^pr_need_02(){/,/^}/p; /^pr_begin(){/,/^}/p' "$P")"
type pr_begin >/dev/null 2>&1 && ok "pr_begin extracted" || no "pr_begin not found in $P"
type pr_need_02 >/dev/null 2>&1 && ok "pr_need_02 extracted" || no "pr_need_02 not found in $P"
ST=STATE-CMD; PROTB_LS=PROTB-CMD; PEER=10.0.0.2; PEERMAC=a8:dd:9f:4d:c7:60; V=1.6.0-wsl.36; S02=""
pb(){	# <PR_USES_02 or "unset"> <02 state line>: runs pr_begin in a subshell; prints its output + "ACQUIRE" + a rc line
	( [ "$1" = unset ] && unset PR_USES_02 || PR_USES_02=$1; S02=$2
	  say(){ echo "say $*"; }; no(){ echo "FAIL x: $*"; }; ok(){ echo "PASS x: $*"; }
	  pr_lock(){ :; }; pr_unlock(){ :; }; pr_on_exit(){ :; }; mono(){ echo 0; }; sleep(){ :; }
	  pr_p9(){ echo "p9 ok"; }
	  qr(){ case "$1" in "$ST") echo "mac=m slot=A ver=$V trial_rc=1 boot=b04" ;; *) echo x ;; esac; }
	  qp(){ case "$1" in "$ST") [ -n "$S02" ] && echo "$S02" ;; *boot_id*) echo b02b02b0 ;; *wlh0*) echo "$PEERMAC" ;; esac; }
	  pr_acquire(){ echo ACQUIRE >> "$T/calls"; echo "LEASE stub"; return 1; }
	  : > "$T/calls"; pr_begin 600; r=$?; cat "$T/calls"; echo "rc=$r enforced=${PR_02_ENFORCED:-unset}" ) 2>&1
}
B1="mac=x slot=B ver=$V trial_rc=1 boot=b02b02b0"; A1="mac=x slot=A ver=$V trial_rc=1 boot=b02b02b0"
B0="mac=x slot=B ver=$V trial_rc=0 boot=b02b02b0"; OLD="mac=x slot=A ver=1.5.9-wsl.30 trial_rc=1 boot=b02b02b0"
acq(){ grep -qx ACQUIRE <<< "$1"; }
o=$(pb 1 "$B1")
if acq "$o"; then no "PR_USES_02=1, 02 on B committed on V: pr_acquire was called (02 not enforced): $(tr '\n' '|' <<< "$o")"
elif grep -q "^FAIL x: 02 on B committed on V: one more OTA of V to 02 lands it on A" <<< "$o" && grep -q "rc=1 " <<< "$o"; then ok "PR_USES_02=1, 02 on B committed on V: FAIL before pr_acquire, with the one-more-OTA remedy"
else no "PR_USES_02=1, 02 on B: [$(tr '\n' '|' <<< "$o")]"; fi
for u in 0 unset; do
	o=$(pb $u "$B1"); acq "$o" && grep -q "^NOTE 02: 02 on B committed on V" <<< "$o" && ! grep -q "^FAIL x: 02" <<< "$o" && ok "PR_USES_02=$u, 02 on B: NOTE, then pr_acquire" || no "PR_USES_02=$u, 02 on B: [$(tr '\n' '|' <<< "$o")]"
done
o=$(pb 1 "$A1"); acq "$o" && grep -q "enforced=1" <<< "$o" && ! grep -q "^NOTE 02" <<< "$o" && ok "PR_USES_02=1, 02 A committed on V: pr_acquire, contract recorded (PR_02_ENFORCED=1)" || no "PR_USES_02=1, 02 on A: [$(tr '\n' '|' <<< "$o")]"
o=$(pb 0 "$A1"); acq "$o" && grep -q "enforced=0" <<< "$o" && ! grep -q "^NOTE 02" <<< "$o" && ok "PR_USES_02=0, 02 A committed on V: pr_acquire, not recorded as enforced" || no "PR_USES_02=0, 02 on A: [$(tr '\n' '|' <<< "$o")]"
for u in 1 0; do
	o=$(pb $u "$B0"); ! acq "$o" && grep -q "^FAIL x: 02 not settled (in a trial" <<< "$o" && ok "PR_USES_02=$u, 02 in a trial: FAIL before pr_acquire (every unit)" || no "PR_USES_02=$u, 02 in a trial: [$(tr '\n' '|' <<< "$o")]"
done
o=$(pb 1 "$OLD"); ! acq "$o" && grep -q "^FAIL x: 02 runs 1.5.9-wsl.30, not V ($V): upgrade 02 to V: twice if it is on A now, once if it is on B" <<< "$o" && ok "PR_USES_02=1, 02 on an older version: FAIL with the twice / once remedy" || no "PR_USES_02=1, older 02: [$(tr '\n' '|' <<< "$o")]"
o=$(pb 0 "$OLD"); acq "$o" && grep -q "^NOTE 02: 02 runs 1.5.9-wsl.30" <<< "$o" && ok "PR_USES_02=0, 02 on an older version: NOTE, then pr_acquire" || no "PR_USES_02=0, older 02: [$(tr '\n' '|' <<< "$o")]"
o=$(pb 1 ""); ! acq "$o" && grep -q "^FAIL x: 02 not settled (unreachable" <<< "$o" && ok "PR_USES_02=1, 02's state unreadable: FAIL before pr_acquire" || no "PR_USES_02=1, 02 unreadable: [$(tr '\n' '|' <<< "$o")]"
o=$(pb 0 ""); acq "$o" && grep -q "^NOTE 02: 02 not settled (unreachable" <<< "$o" && ok "PR_USES_02=0, 02's state unreadable: NOTE, then pr_acquire" || no "PR_USES_02=0, 02 unreadable: [$(tr '\n' '|' <<< "$o")]"

# ---- the refusal of the steps on 02's slot
if type pr_need_02 >/dev/null 2>&1; then
	o=$( no(){ echo "FAIL x: $*"; }; PR_02_ENFORCED=0; pr_need_02 step; echo "rc=$?")
	grep -q "^FAIL x: step acts on 02's slot" <<< "$o" && grep -q "rc=1" <<< "$o" && ok "pr_need_02 without the recorded contract: FAIL, rc 1" || no "pr_need_02 not enforced: [$o]"
	o=$(PR_02_ENFORCED=1; pr_need_02 step; echo "rc=$?"); [ "$o" = "rc=0" ] && ok "pr_need_02 with the recorded contract: rc 0" || no "pr_need_02 enforced: [$o]"
	# PR_USES_02 set only AFTER pr_begin (v5 A m7): pr_begin ran the NOTE branch, so the helpers still refuse
	o=$( ( no(){ echo "FAIL x: $*"; }; say(){ :; }; ok(){ :; }; pr_lock(){ :; }; pr_unlock(){ :; }; mono(){ echo 0; }; sleep(){ :; }; pr_p9(){ :; }
		qr(){ echo "slot=A ver=$V trial_rc=1"; }; qp(){ case "$1" in "$ST") echo "$B1" ;; *boot_id*) echo b ;; *wlh0*) echo "$PEERMAC" ;; esac; }
		pr_acquire(){ return 1; }; pr_on_exit(){ :; }; PR_USES_02=0; pr_begin 600 >/dev/null; PR_USES_02=1; pr_need_02 late; echo "rc=$?" ) )
	grep -q "^FAIL x: late acts on 02's slot" <<< "$o" && grep -q "rc=1" <<< "$o" && ok "PR_USES_02=1 set after pr_begin: the helpers still refuse" || no "late PR_USES_02: [$o]"
fi
U=$ROOT/scripts/dv/prov-netjoin-fleet-254.sh
NODE=n04; NODE04=n04; MAC=m04; MAC04=m04; MAC02=m02; RUN=r1; RUN04=r1; RUN02=r1p; SNAP02=0; IN02=0; G_DL=0; G_RS=0; G_SN=0
eval "$(sed -n '/^back04(){/p; /^as02(){/,/^}/p; /^restore02(){/,/^}/p' "$U")"
if type as02 >/dev/null 2>&1 && type restore02 >/dev/null 2>&1; then
	o=$( no(){ echo "FAIL x: $*"; }; PR_02_ENFORCED=0; PR_DEADLINE=1; PR_RESTORING=0; PR_SNAPPED=0; as02 echo RAN; echo "rc=$?")
	! grep -q RAN <<< "$o" && grep -q "rc=1" <<< "$o" && ok "as02 without the recorded contract: refused, the step did not run" || no "as02 not enforced: [$(tr '\n' '|' <<< "$o")]"
	o=$( no(){ :; }; PR_02_ENFORCED=1; PR_DEADLINE=1; PR_RESTORING=0; PR_SNAPPED=0; as02 echo RAN; echo "rc=$?")
	grep -q RAN <<< "$o" && ok "as02 with the recorded contract: the step runs" || no "as02 enforced: [$(tr '\n' '|' <<< "$o")]"
	o=$( no(){ echo "FAIL x: $*"; }; pr_needs_person(){ echo "PERSON $*"; }; pr_restore(){ echo RESTORE; }; qp(){ echo QP; }; say(){ :; }; ok(){ :; }
		PR_02_ENFORCED=0; PR_DEADLINE=1; PR_RESTORING=0; PR_SNAPPED=0; restore02; echo "rc=$?")
	! grep -qE "RESTORE|QP|PERSON" <<< "$o" && grep -q "rc=1" <<< "$o" && ok "restore02 without the recorded contract: refused before touching 02" || no "restore02 not enforced: [$(tr '\n' '|' <<< "$o")]"
else no "as02 / restore02 not found in $U"; fi
U=$ROOT/scripts/dv/prov-ac-fleetchan-254.sh
eval "$(sed -n '/^part1(){/,/^}/p' "$U")"
if type part1 >/dev/null 2>&1; then
	o=$( no(){ echo "FAIL x: $*"; }; say(){ :; }; qp(){ echo QP >> "$T/qp"; }; : > "$T/qp"; PR_02_ENFORCED=0; part1; echo "rc=$? qp=$(wc -l < "$T/qp")")
	grep -q "rc=1 qp=0" <<< "$o" && ok "fleetchan part 1 without the recorded contract: refused, nothing sent to 02" || no "part1 not enforced: [$(tr '\n' '|' <<< "$o")]"
	o=$( no(){ echo "FAIL x: $*"; }; say(){ :; }; qp(){ echo QP >> "$T/qp"; }; : > "$T/qp"; PR_02_ENFORCED=1; part1; echo "rc=$? qp=$(wc -l < "$T/qp")")
	grep -q "qp=[1-9]" <<< "$o" && ok "fleetchan part 1 with the recorded contract: goes on to 02" || no "part1 enforced: [$(tr '\n' '|' <<< "$o")]"
else no "part1 not found in $U"; fi

# ---- the PR_USES_02 lint
# uses02_lint <dir>: every unit (*.sh but prov-254.sh / test-*) with a call that acts on 02's slot must set PR_USES_02=1 on
# a line before its first top-level pr_begin call. Prints a line per unit with a call; rc 1 on any FAIL or on no unit.
uses02_lint(){
	local f h b u r=0 n=0
	for f in "$1"/*.sh; do
		case "${f##*/}" in prov-254.sh|test-*) continue ;; esac
		h=$(grep -nE '(^|[^A-Za-z0-9_])(as02|restore02)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])qp[[:space:]].*(sysupgrade|rb_guarded|reboot_guarded|commit_guarded|batman-slot)|scp[[:space:]].*root@\$\{?PEER' "$f" | grep -vE '^[0-9]+:([[:space:]]*#|PR_USES_02=)' | head -1 | cut -d: -f1)
		u=$(grep -nE '^PR_USES_02=1([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)
		b=$(grep -nE '^pr_begin[[:space:]]' "$f" | head -1 | cut -d: -f1)
		if [ -n "$u" ] && { [ -z "$b" ] || [ "$u" -gt "$b" ]; }; then echo "FAIL ${f##*/}: PR_USES_02=1 (line $u) is not set before pr_begin (line ${b:-none})"; r=1; continue; fi
		[ -n "$h" ] || continue
		n=$((n + 1))
		if [ -z "$b" ]; then echo "FAIL ${f##*/}: acts on 02's slot (line $h) but calls no pr_begin, so the contract is never checked"; r=1
		elif [ -z "$u" ]; then echo "FAIL ${f##*/}: acts on 02's slot (line $h) without PR_USES_02=1 before pr_begin (line $b)"; r=1
		else echo "ok ${f##*/}: acts on 02's slot (line $h), PR_USES_02=1 at line $u, pr_begin at line $b"; fi
	done
	[ "$n" -gt 0 ] || { echo "FAIL no unit in $1 acts on 02's slot: the lint checked nothing"; r=1; }
	return $r
}
F=$T/fx; mkdir -p "$F/good" "$F/rb" "$F/late" "$F/rg" "$F/none" "$F/scp" "$F/nobegin"
printf 'PR_UNIT=prov-a-254\nPR_USES_02=1\n. x\npart(){ qp "setsid sh -c '\''sysupgrade -n x'\''"; }\npr_begin 60\n' > "$F/good/prov-a-254.sh"
# the guard names are spelled through G: a literal guarded call here would be a site for test-slot-guard's pin lint
G=_guarded
printf 'PR_UNIT=prov-b-254\n. x\np(){ qp "$(rb%s "$b" B any r)"; }\npr_begin 60\n' "$G" > "$F/rb/prov-b-254.sh"
printf 'PR_UNIT=prov-c-254\n. x\npr_begin 60\nPR_USES_02=1\nas02 pr_restore\n' > "$F/late/prov-c-254.sh"
printf 'PR_UNIT=prov-d-254\n. x\npr_begin 60\nqp "$(reboot%s "$b" A 0 r)"\n' "$G" > "$F/rg/prov-d-254.sh"
printf 'PR_UNIT=prov-e-254\n. x\n# qp "sysupgrade" in a comment only\npr_begin 60\nqp "cat /etc/batman-build"\n' > "$F/none/prov-e-254.sh"
printf 'PR_UNIT=prov-f-254\n. x\npr_begin 60\nscp -q $SSHO "$PAYF" root@$PEER:/x\n' > "$F/scp/prov-f-254.sh"
printf 'restore02(){ :; }\nrestore02\n' > "$F/nobegin/prov-g-254.sh"
o=$(uses02_lint "$F/good"); [ $? = 0 ] && ok "lint fixture: qp sysupgrade with PR_USES_02=1 before pr_begin -> PASS" || no "lint good fixture: [$o]"
for c in rb:"qp rb_guarded, no PR_USES_02" late:"PR_USES_02=1 after pr_begin" rg:"qp reboot_guarded, no PR_USES_02" none:"no call (comment only)" scp:"scp to root@\$PEER without PR_USES_02" nobegin:"restore02 in a file without pr_begin"; do
	o=$(uses02_lint "$F/${c%%:*}"); [ $? = 1 ] && grep -q '^FAIL' <<< "$o" && ok "lint fixture: ${c#*:} -> FAIL ($(grep -m1 '^FAIL' <<< "$o" | cut -c1-90))" || no "lint fixture ${c#*:} not caught: [$o]"
done
o=$(uses02_lint "$ROOT/scripts/dv"); rc=$?; echo "$o" | sed 's/^/      | /'
[ $rc = 0 ] && ok "lint on $ROOT/scripts/dv: every unit acting on 02's slot sets PR_USES_02=1 before pr_begin ($(grep -c '^ok ' <<< "$o") units)" || no "lint on scripts/dv: $(grep '^FAIL' <<< "$o" | tr '\n' '|')"

# ---- the host side of the p5 restore (§3.2 step 5): pr_restore_cycle prints every ^(P5-|FAIL) line of the node's
# answer, not only its last line (main printed `tail -1`, so the mount names never reached the unit log)
eval "$(sed -n '/^pr_restore_cycle(){/,/^}/p' "$P")"
if type pr_restore_cycle >/dev/null 2>&1; then
	NBOUT="P5-MOUNTED /tmp/run/batman-dv/pbm.x
P5-MOUNTED /tmp/run/batman/cfgsave-mnt.y
P5-NOT-HARNESS /tmp/run/batman/cfgsave-mnt.y
FAIL p5 is mounted outside the harness: /tmp/run/batman/cfgsave-mnt.y — nothing unmounted, a person checks it"
	o=$( say(){ echo "say $*"; }; no(){ echo "FAIL x: $*"; }; qr(){ echo "slot=A trial_rc=1 boot=b"; }; pr_lease_renew(){ :; }; pl(){ :; }; pw(){ :; }; q(){ :; }
		nb(){ [ "$1" = p5-restore ] && echo "$NBOUT"; }; RUN=r1; HOLDF=h; PR_PAY=p; pr_restore_cycle; echo "rc=$?" )
	n=0; while IFS= read -r l; do grep -qxF "say p5-restore: $l" <<< "$o" && n=$((n + 1)); done <<< "$NBOUT"
	[ "$n" = 4 ] && grep -q "^FAIL x: p5 restore" <<< "$o" && grep -q "rc=1" <<< "$o" && ok "pr_restore_cycle: all 4 P5- / FAIL lines of a refused p5 restore printed, then FAIL" || no "pr_restore_cycle printed $n of 4 lines: [$(tr '\n' '|' <<< "$o")]"
else no "pr_restore_cycle not found in $P"; fi
echo "================ test-pr02: $pass passed, $fail failed"
[ "$fail" = 0 ]
