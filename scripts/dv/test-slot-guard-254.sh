#!/bin/bash
# scripts/dv/test-slot-guard-254.sh — offline: rb_guarded / reboot_guarded (slot-guard-254.sh) against a stub node, the
# real call sites that use them (extracted and run), and lints over the harness (review 2026-11-09 B-MAJOR-2, round 5):
#   (1) no `batman-slot rollback|commit|reboot` / `batman-autocommit release` outside the guard, except an allowlist
#       (file + text + reason) that must all still exist;
#   (2) every guarded call site with its exact (boot, slot, trial, reason, condition, pre-action): a changed argument
#       FAILs; (2b) pinned lines: the reboot_and_wait precheck and the role deadmen's line;
#   (3) every plain `reboot` / sysrq line is a row of scripts/dv/data/slot-sites.tsv (exact text, exact count, group);
#   (4) no slot match without the field boundary.
# #254 v1.6 group 4 (docs/design/254-v16-group4.md §4, §13, §15): commit_guarded, reboot_guarded's <pre>, every converted
# call site extracted and run against the stub node, pty-commit's stop_commit, reboot_and_wait's precheck.
# The incident line is the real one chain1's restore read on 04 at 14:12 on 2026-11-08.
# ROOT=<tree> tests another checkout (negative control: ROOT=<a232d42 export> must FAIL).
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); ROOT=${ROOT:-$H}
. "$H/scripts/dv/slot-guard-254.sh"
pass=0; fail=0
ok(){ echo "ok   $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fail=$((fail + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# the node: batman-slot, and cut for the boot id (every other cut is the real one)
cat > "$T/bin/batman-slot" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$1" in
	active) echo "$STUB_ACTIVE" ;;
	is-trial) exit "$STUB_TRIAL_RC" ;;
	rollback) exit "${STUB_RB_RC:-0}" ;;
	reboot) exit 0 ;;
	commit) echo "batman-slot: committed slot $STUB_ACTIVE as default ([all]=2, [tryboot]=3)" ;;
esac
STUB
cat > "$T/bin/cut" <<'STUB'
#!/bin/sh
case "$*" in *random/boot_id*) [ -n "$STUB_BOOT" ] && echo "$STUB_BOOT"; exit 0 ;; esac
exec "$REALCUT" "$@"
STUB
# ps: the node's busybox `ps w` lists every process with its full command line; procps `ps w` lists only this tty's
cat > "$T/bin/ps" <<'STUB'
#!/bin/sh
exec "$REALPS" axww
STUB
# batman-autocommit: logs the release; vcmailbox: the tryboot flag in $T/flag, a disarm (0x00038064) clears it unless
# STUB_DISARM_FAIL is set; mkdir: with STUB_MKDIR_CANCEL, ch1.cancel appears just before ch1.running is made (the
# restore's touch landing between the dead-man's first cancel check and its marker)
cat > "$T/bin/batman-autocommit" <<'STUB'
#!/bin/sh
echo "autocommit $*" >> "$STUB_LOG"; echo "release: committed"
STUB
cat > "$T/bin/vcmailbox" <<'STUB'
#!/bin/sh
case "$1" in
	0x00038064) echo "disarm" >> "$STUB_LOG"; [ -n "$STUB_DISARM_FAIL" ] || echo 0 > "$STUB_FLAG" ;;
	# the real format: every word 0x%08x (trybootget-209.log on 04 / 02: "… 0x80000004 0x00000000"); STUB_RESP = word 2
	0x00030064) echo "get" >> "$STUB_LOG"; printf '0x0000001c %s 0x00030064 0x00000004 %s 0x%08x 0x00000000\n' "${STUB_RESP:-0x80000000}" "${STUB_W5:-0x80000004}" "$(cat "$STUB_FLAG")" ;;
esac
STUB
cat > "$T/bin/mkdir" <<'STUB'
#!/bin/sh
for d; do case "$d" in */ch1.running) [ -n "$STUB_MKDIR_CANCEL" ] && : > "${d%/ch1.running}/ch1.cancel" ;; esac; done
exec "$REALMKDIR" "$@"
STUB
# reboot: a plain reboot reaching the node is logged, never run; sleep: STUB_NOSLEEP=1 makes it instant
cat > "$T/bin/reboot" <<'STUB'
#!/bin/sh
echo "plain-reboot $*" >> "$STUB_LOG"
STUB
cat > "$T/bin/sleep" <<'STUB'
#!/bin/sh
[ -n "$STUB_NOSLEEP" ] && exit 0; exec "$REALSLEEP" "$@"
STUB
chmod +x "$T/bin/batman-slot" "$T/bin/cut" "$T/bin/ps" "$T/bin/batman-autocommit" "$T/bin/vcmailbox" "$T/bin/mkdir" "$T/bin/reboot" "$T/bin/sleep"
export REALCUT REALPS REALMKDIR REALSLEEP STUB_FLAG=$T/flag STUB_DISARM_FAIL="" STUB_MKDIR_CANCEL="" STUB_NOSLEEP=""
REALCUT=$(command -v cut); REALPS=$(command -v ps); REALMKDIR=$(command -v mkdir); REALSLEEP=$(command -v sleep); echo 0 > "$T/flag"
# node <boot> <active> <trial-rc> <rollback-rc>: the stub node's state for nsh
node(){ NB=$1 NA=$2 NT=$3 NR=$4; : > "$T/log"; }
nsh(){ PATH="$T/bin:$PATH" STUB_BOOT=$NB STUB_LOG="$T/log" STUB_ACTIVE=$NA STUB_TRIAL_RC=$NT STUB_RB_RC=$NR sh -c "$1"; sleep 0.3; }
run(){ local cmd; node "$1" "$2" "$3" "$4"; shift 5; cmd=$(rb_guarded "$@"); nsh "$cmd"; }
rolled(){ grep -q '^rollback$' "$T/log"; }
rebooted(){ grep -q '^reboot committed' "$T/log"; }

# ---- rb_guarded
o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 ch1-restore); [ "$o" = SENT ] && rolled && rebooted && ok "matching state: SENT, rollback + reboot" || no "matching state: [$o] $(tr '\n' ' ' < "$T/log")"
o=$(run c5faffaa A 1 0 -- c5faffaa B 1 ch1-restore); case "$o" in "WRONG-STATE boot=c5faffaa active=A trial=1 extra=-")! rolled && ok "the 2026-11-08 case (node on A, caller thought B): WRONG-STATE, no rollback" || no "rolled back on A";; *) no "node on A: [$o]";; esac
o=$(run aaaaaaaa B 1 0 -- 1201bf8a B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "another boot (read before a reboot): WRONG-STATE, no rollback" || no "rolled back in another boot";; *) no "another boot: [$o]";; esac
o=$(run 1201bf8a A 1 0 -- 1201bf8a A 0 ch1-b); case "$o" in WRONG-STATE*) ! rolled && ok "the trial already committed / fell back (want trial): WRONG-STATE" || no "rolled back a committed slot";; *) no "trial mismatch: [$o]";; esac
o=$(run 1201bf8a A 0 0 -- 1201bf8a A any x); [ "$o" = SENT ] && ok "trial any: SENT" || no "trial any: [$o]"
o=$(run 1201bf8a B 2 0 -- 1201bf8a B 1 x); case "$o" in *" trial=2 extra=-")! rolled && ok "is-trial rc 2 (unknown) is not 'committed': WRONG-STATE" || no "rolled back on rc 2";; *) no "rc 2: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 x "[ -e $T/nonexistent ]"); case "$o" in *" extra=0") ! rolled && ok "extra condition false (e.g. the dead-man acting): WRONG-STATE … extra=0" || no "rolled back with the extra condition false";; *) no "extra condition: [$o]";; esac
rm -f "$T/ran"; o=$(run aaaaaaaa B 1 0 -- 1201bf8a B 1 x ": > $T/ran"); case "$o" in *" extra=-") [ ! -e "$T/ran" ] && ok "another boot: the extra condition is not run (it may act, e.g. disarm)" || no "the extra condition ran in another boot";; *) no "extra not run: [$o]";; esac
o=$(run 1201bf8a B 1 1 -- 1201bf8a B 1 x); [ "$o" = REFUSED ] && ! rebooted && ok "batman-slot refuses: REFUSED, no reboot" || no "refused rollback: [$o] $(tr '\n' ' ' < "$T/log")"
o=$(run 1201bf8a B 1 0 -- "" B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "empty expected boot: WRONG-STATE (fail-closed)" || no "rolled back with an empty expected boot";; *) no "empty boot: [$o]";; esac
o=$(run "" B 1 0 -- "" B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "node boot id unreadable + empty expected boot: WRONG-STATE" || no "rolled back with no boot id on either side";; *) no "unreadable boot: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- 1201bf8a C 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "invalid slot argument: WRONG-STATE" || no "rolled back on an invalid slot argument";; *) no "invalid slot: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- "1201bf8a' ] || touch $T/PWN; [ 'x" B 1 x); case "$o" in WRONG-STATE*) [ ! -e "$T/PWN" ] && ! rolled && ok "a boot argument carrying shell is not run, never matches (round 5 B-MINOR-3)" || no "boot argument ran shell / rolled back";; *) no "boot injection: [$o] pwn=$([ -e "$T/PWN" ] && echo y)";; esac
o=$(run 1201bf8a B 1 0 -- 1201BF8A B 1 x); case "$o" in WRONG-STATE*) ok "boot argument: 8 lower-case hex only";; *) no "upper-case boot: [$o]";; esac
# ---- reboot_guarded: never a rollback
node 1201bf8a A 0 0; o=$(nsh "$(reboot_guarded 1201bf8a A 0 s0-slota)"); [ "$o" = SENT ] && rebooted && ! rolled && ok "reboot_guarded: SENT, reboot only" || no "reboot_guarded: [$o] $(tr '\n' ' ' < "$T/log")"
node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 0 s0-slota)"); case "$o" in WRONG-STATE*) ! rebooted && ok "reboot_guarded: committed, want trial: nothing" || no "reboot_guarded rebooted a committed slot";; *) no "reboot_guarded mismatch: [$o]";; esac
# ---- release_guarded: only in that boot, on that slot, in a trial (round 6 B-MINOR-5)
released(){ grep -q '^autocommit release' "$T/log"; }
node 1201bf8a B 0 0; o=$(nsh "$(release_guarded 1201bf8a B)"); [ "$o" = "release: committed" ] && grep -q '^autocommit release --wait$' "$T/log" && ok "release_guarded: the trial in that boot: release --wait" || no "release_guarded: [$o] $(tr '\n' ' ' < "$T/log")"
node 1201bf8a B 0 0; o=$(nsh "$(release_guarded 1201bf8a B nowait)"); case "$o" in *"rc=0") grep -q '^autocommit release$' "$T/log" && ok "release_guarded nowait: release, then rc=" || no "nowait sent --wait";; *) no "release nowait: [$o]";; esac
node aaaaaaaa B 0 0; o=$(nsh "$(release_guarded 1201bf8a B)"); case "$o" in WRONG-STATE*) ! released && ok "release_guarded: another boot: nothing" || no "released in another boot";; *) no "release other boot: [$o]";; esac
node 1201bf8a B 1 0; o=$(nsh "$(release_guarded 1201bf8a B)"); case "$o" in WRONG-STATE*) ! released && ok "release_guarded: already committed: nothing" || no "released a committed slot";; *) no "release committed: [$o]";; esac
node 1201bf8a A 0 0; o=$(nsh "$(release_guarded 1201bf8a B)"); case "$o" in WRONG-STATE*) ! released && ok "release_guarded: a trial on the other slot: nothing" || no "released the other slot's trial";; *) no "release other slot: [$o]";; esac
# ---- DISARMED (slot-guard-254.sh; fresh-254.sh before round 7): a reboot that would boot an armed tryboot is not sent
# (round 6 A-MAJOR-1), read in the real vcmailbox format (round 7 B-BLOCKER-1: a decimal stub hid a parse that never held)
unset DISARM DISARMED; eval "$(grep -hE '^(DISARM|DISARMED)=' "$ROOT/scripts/dv/slot-guard-254.sh" "$ROOT/scripts/dv/fresh-254.sh")"
if [ -n "${DISARMED:-}" ]; then
	echo 1 > "$T/flag"; node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 ch1-restore "$DISARMED")"); [ "$o" = SENT ] && grep -q '^disarm$' "$T/log" && [ "$(cat "$T/flag")" = 0 ] && ok "armed tryboot: disarmed, then the reboot is sent" || no "armed + disarm works: [$o] $(tr '\n' ' ' < "$T/log")"
	echo 1 > "$T/flag"; node 1201bf8a A 1 0; o=$(STUB_DISARM_FAIL=y; export STUB_DISARM_FAIL; nsh "$(reboot_guarded 1201bf8a A 1 ch1-restore "$DISARMED")"); case "$o" in *" extra=0") ! rebooted && ok "armed tryboot that will not disarm: WRONG-STATE extra=0, no reboot" || no "rebooted with the tryboot still armed";; *) no "armed, disarm fails: [$o]";; esac
	echo 0 > "$T/flag"; node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 ch1-restore "$DISARMED")"); [ "$o" = SENT ] && ok "flag already 0 (0x00000000): the reboot is sent" || no "flag 0: [$o]"
	echo 0 > "$T/flag"; node 1201bf8a A 1 0; o=$(STUB_RESP=0x80000001; export STUB_RESP; nsh "$(reboot_guarded 1201bf8a A 1 ch1-restore "$DISARMED")"); case "$o" in *" extra=0") ! rebooted && ok "an error response (word 2 not 0x80000000) with value 0: not 'disarmed', no reboot" || no "rebooted on an error response";; *) no "error response: [$o]";; esac
	echo 0 > "$T/flag"; node 1201bf8a A 1 0; o=$(STUB_W5=0x00000004; export STUB_W5; nsh "$(reboot_guarded 1201bf8a A 1 ch1-restore "$DISARMED")"); case "$o" in *" extra=0") ! rebooted && ok "a firmware that did not answer the tag (word 5 0x00000004, value 0): not 'disarmed' (round 8 B-1)" || no "rebooted on an unanswered tag";; *) no "unanswered tag: [$o]";; esac
	echo 0 > "$T/flag"
else no "DISARMED not found in $ROOT/scripts/dv/fresh-254.sh"; fi
. "$H/scripts/dv/slot-guard-254.sh"   # back to the guard under test (the eval above may have taken ROOT's DISARM)
# every guarded rollback / reboot disarms first, with no extra condition from the caller (round 7 A-MINOR-4)
echo 1 > "$T/flag"; node 1201bf8a B 1 0; o=$(STUB_DISARM_FAIL=y; export STUB_DISARM_FAIL; nsh "$(rb_guarded 1201bf8a B 1 x)"); case "$o" in *" extra=0") ! rolled && ! rebooted && ok "rb_guarded: a tryboot that will not disarm -> no rollback, no reboot" || no "rb_guarded acted with the tryboot armed";; *) no "rb_guarded armed: [$o]";; esac
echo 1 > "$T/flag"; node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 x)"); [ "$o" = SENT ] && [ "$(cat "$T/flag")" = 0 ] && ok "reboot_guarded (no extra): an armed tryboot is disarmed before the reboot" || no "reboot_guarded armed: [$o] flag=$(cat "$T/flag")"
echo 0 > "$T/flag"

# ---- the real call sites, extracted from ROOT and run against the stub node
fq(){ nsh "$1"; }
# prov-bench-s0 "back to B" (round 5 MAJOR-1: the old one rolled back on is-trial rc 2 and answered SENT after a refusal)
s0=$(grep -E '^[[:space:]]*(r=|\[ "\$r")' "$ROOT/scripts/dv/prov-bench-s0-254.sh" | grep 's0-slota')
BA=1201bf8a
s0run(){ node "$@"; r=""; eval "$s0"; }
if [ -n "$s0" ]; then
	s0run 1201bf8a A 1 0; [ "$r" = SENT ] && rolled && rebooted && ok "s0 back to B, A committed: rollback + reboot" || no "s0 A committed: [$r] $(tr '\n' ' ' < "$T/log")"
	s0run 1201bf8a A 0 0; [ "$r" = SENT ] && ! rolled && rebooted && ok "s0 back to B, A trial: reboot only" || no "s0 A trial: [$r] $(tr '\n' ' ' < "$T/log")"
	s0run 1201bf8a A 2 0; ! rolled && ! rebooted && ok "s0 back to B, is-trial rc 2: nothing sent (the deadline returns it)" || no "s0 rc 2: [$r] $(tr '\n' ' ' < "$T/log")"
	s0run 1201bf8a A 1 1; [ "$r" != SENT ] && ! rebooted && ok "s0 back to B, rollback refused: not SENT, no reboot [$r]" || no "s0 refused rollback: [$r] $(tr '\n' ' ' < "$T/log")"
	s0run aaaaaaaa A 1 0; ! rolled && ! rebooted && ok "s0 back to B, another boot: nothing" || no "s0 other boot: [$r]"
else no "s0 back-to-B lines not found in $ROOT/scripts/dv/prov-bench-s0-254.sh"; fi
# prov-chain0: only REFUSED gets a (guarded) reboot; anything else is a person and nothing more is sent (round 5 A-MINOR-4)
c0=$(sed -n '/r=$(fq "$(rb_guarded "$b0" B any prov-dv-254)")/,/pr_find 900/p' "$ROOT/scripts/dv/prov-chain0-254.sh" | sed '$d')
if [ -n "$c0" ]; then
	eval "c0f(){ $c0
	return 0; }"
	pr_needs_person(){ echo person >> "$T/log"; return 1; }; say(){ :; }
	b0=1201bf8a
	node 1201bf8a B 0 0; c0f; [ $? = 0 ] && rolled && rebooted && ok "chain0: SENT goes on" || no "chain0 SENT: $(tr '\n' ' ' < "$T/log")"
	node 1201bf8a B 0 1; c0f; [ $? = 0 ] && rebooted && ! grep -q person "$T/log" && ok "chain0: REFUSED -> guarded reboot" || no "chain0 REFUSED: $(tr '\n' ' ' < "$T/log")"
	node 1201bf8a A 1 0; c0f; [ $? = 1 ] && ! rebooted && grep -q person "$T/log" && ok "chain0: WRONG-STATE -> NEEDS-PERSON, no reboot" || no "chain0 WRONG-STATE: $(tr '\n' ' ' < "$T/log")"
	unset -f c0f pr_needs_person say
else no "chain0 rollback block not found in $ROOT/scripts/dv/prov-chain0-254.sh"; fi
# brewrite back_to_a: non-SENT is a failure (round 5 A-MINOR-4 / B-MINOR-1)
eval "$(grep '^back_to_a(){' "$ROOT/scripts/dv/brewrite-254.sh")"
if type back_to_a >/dev/null 2>&1; then
	SSHO=""; NODE=10.0.0.9; bid(){ echo 1201bf8a-0000-0000-0000-000000000000; }; say(){ :; }; waitboot(){ return 0; }; settle(){ return 0; }
	ssh(){ local a; for a; do :; done; nsh "$a"; }; q(){ nsh "$*"; }; timeout(){ shift; "$@"; }
	node 1201bf8a A 1 0; back_to_a; [ $? != 0 ] && ! rolled && ok "brewrite back_to_a: WRONG-STATE returns non-zero" || no "brewrite back_to_a returned 0 on WRONG-STATE"
	node 1201bf8a B 0 0; back_to_a && rolled && ok "brewrite back_to_a: SENT returns 0" || no "brewrite back_to_a on B: $(tr '\n' ' ' < "$T/log")"
	# one ssh, no retry: a dropped answer (rc 255) is not followed by a second try that would run in the new boot
	# (round 6 B-MINOR-4; q retries 6 times on 255, stubbed here as two tries)
	: > "$T/sshn"; ssh(){ echo ssh >> "$T/sshn"; return 255; }; q(){ echo q >> "$T/sshn"; echo q >> "$T/sshn"; echo "WRONG-STATE boot=x active=A trial=1 extra=-"; }
	back_to_a; r=$?; [ "$r" != 0 ] && [ "$(tr '\n' ' ' < "$T/sshn")" = "ssh " ] && ok "brewrite back_to_a: a dropped answer is one ssh, no retry, non-zero" || no "brewrite back_to_a on a drop: rc=$r tries=[$(tr '\n' ' ' < "$T/sshn")]"
	unset -f back_to_a bid say waitboot settle ssh q timeout
else no "back_to_a not found in $ROOT/scripts/dv/brewrite-254.sh"; fi
# brewrite's MAC= precondition (round 5 B-MINOR-6 / round 6 B-MINOR-4)
macl=$(grep '^if \[ -n "${MAC:-}" \]' "$ROOT/scripts/dv/brewrite-254.sh")
if [ -n "$macl" ]; then
	o=$(MAC=88:a2:9e:b5:6c:89; NODE=10.0.0.9; q(){ echo 11:22:33:44:55:66; }; eval "$macl"; echo went-on); case "$o" in *"FAIL at it=0"*"not 88:a2:9e:b5:6c:89"*) case "$o" in *went-on*) no "brewrite went on after a MAC mismatch";; *) ok "brewrite: another board at NODE stops before anything is written";; esac;; *) no "brewrite MAC mismatch: [$o]";; esac
	o=$(MAC=88:a2:9e:b5:6c:89; NODE=10.0.0.9; q(){ echo 88:a2:9e:b5:6c:89; }; eval "$macl"; echo went-on); [ "$o" = went-on ] && ok "brewrite: the right board goes on" || no "brewrite right MAC: [$o]"
else no "brewrite's MAC= precondition not found in $ROOT/scripts/dv/brewrite-254.sh"; fi
# prov-254.sh back_to_a: no answer is not "already on A" (round 6 A-MINOR-4)
eval "$(sed -n '/^field(){/p; /^back_to_a(){/,/^}/p' "$ROOT/scripts/dv/prov-254.sh")"
if type back_to_a >/dev/null 2>&1; then
	qr(){ :; }; say(){ :; }; ST=x
	back_to_a; [ $? != 0 ] && ok "prov back_to_a: an unreadable state returns non-zero" || no "prov back_to_a: an unreadable state counted as 'already on A'"
	qr(){ echo "mac=x slot=A ver=v trial_rc=1 boot=1201bf8a"; }; back_to_a && ok "prov back_to_a: on A returns 0" || no "prov back_to_a on A"
	unset -f back_to_a qr say field
else no "back_to_a not found in $ROOT/scripts/dv/prov-254.sh"; fi
# restore_all's extra condition (fresh-254.sh): the dead-man's sleeping timer (its cmdline names ch1-deadman.sh) is
# not "acting"; its ch1.running marker is (round 5 A-MINOR-3)
cond=$(grep 'ch1-restore "' "$ROOT/scripts/dv/fresh-254.sh" | grep 'rb_guarded' | sed -n 's/.*ch1-restore "\(.*\)")")$/\1/p')
if [ -n "$cond" ]; then
	BASE=$T/base; mkdir -p "$BASE"; eval "cx=\"$cond\""
	setsid sh -c "sleep 20; : $BASE/ch1-deadman.sh" </dev/null >/dev/null 2>&1 & tp=$!
	sleep 0.5
	o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 ch1-restore "$cx"); [ "$o" = SENT ] && ok "restore rollback: the dead-man's sleeping timer does not block it" || no "restore rollback blocked by the dead-man's timer [$o]"
	kill "$tp" 2>/dev/null; pkill -f "sleep 20; : $BASE/ch1-deadman.sh" 2>/dev/null
	mkdir "$BASE/ch1.running"; o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 ch1-restore "$cx"); case "$o" in WRONG-STATE*) ! rolled && ok "restore rollback: refused while the dead-man acts (ch1.running)" || no "rolled back while ch1.running";; *) no "ch1.running: [$o]";; esac
	rmdir "$BASE/ch1.running"; : > "$BASE/ch1.fired"; o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 ch1-restore "$cx"); case "$o" in WRONG-STATE*) ok "restore rollback: refused after the dead-man fired";; *) no "ch1.fired: [$o]";; esac
	rm -f "$BASE/ch1.fired"
else no "restore_all's guarded rollback not found in $ROOT/scripts/dv/fresh-254.sh"; fi
# chain1's dead-man script (extracted as the host writes it): marker first, then the cancel check, one-shot
dmraw=$(sed -n "/<<'DM'\$/,/^DM\$/p" "$ROOT/scripts/dv/chain1-254.sh" | sed '1d;$d')
if [ -n "$dmraw" ]; then
	BASE=$T/dm; RUN=ch1t; D=$BASE/$RUN; DIRTY=$T/dirty; mkdir -p "$D"; : > "$D/p5.img"; echo "$RUN x" > "$DIRTY"
	echo 'echo "P5-RESTORED $2"' > "$BASE/prov-base-254.sh"; printf '#!/bin/sh\n:\n' > "$T/bin/logger"; chmod +x "$T/bin/logger"
	eval "dm=\"$dmraw\""; dm=${dm//\/usr\/lib\/batman\/bootfacts.sh/$H/feed/batman-provision/files/usr/lib/batman/bootfacts.sh}; printf '%s\n' "$dm" > "$BASE/ch1-deadman.sh"
	dmrun(){ rm -rf "$BASE/ch1.running" "$BASE/ch1.fired" "$BASE/ch1.cancel"; node 1201bf8a B 1 0; for f; do case "$f" in run) mkdir "$BASE/ch1.running";; *) : > "$BASE/ch1.$f";; esac; done; nsh "sh $BASE/ch1-deadman.sh" >/dev/null 2>&1; }
	dmrun; rolled && [ ! -e "$BASE/ch1.running" ] && [ -e "$BASE/ch1.fired" ] && ok "dead-man acts: rollback, ch1.fired, its marker removed when done" || no "dead-man normal run: running=$([ -d "$BASE/ch1.running" ] && echo y) $(tr '\n' ' ' < "$T/log")"
	echo 'echo "P5-RESTORE FAILED"; exit 3' > "$BASE/prov-base-254.sh"
	dmrun; ! rolled && [ -d "$BASE/ch1.running" ] && [ ! -e "$BASE/ch1.fired" ] && ok "dead-man: a failed p5-restore -> no rollback, ch1.running kept for a person (round 7 B-MINOR-2)" || no "dead-man after a failed p5-restore: $(tr '\n' ' ' < "$T/log") running=$([ -d "$BASE/ch1.running" ] && echo y)"
	echo 'echo "P5-RESTORED $2"' > "$BASE/prov-base-254.sh"
	(dmrun_a(){ rm -rf "$BASE"/ch1.*; node 1201bf8a A 1 0; nsh "sh $BASE/ch1-deadman.sh" >/dev/null 2>&1; }; dmrun_a); ! rolled && [ ! -e "$BASE/ch1.running" ] && ok "dead-man: the node on A -> nothing (it acts on slot B only)" || no "dead-man acted on A: $(tr '\n' ' ' < "$T/log")"
	echo 1 > "$T/flag"; (STUB_DISARM_FAIL=y; export STUB_DISARM_FAIL; dmrun); ! rolled && [ -d "$BASE/ch1.running" ] && ok "dead-man: a tryboot that will not disarm -> no rollback, ch1.running kept (round 8 A-m1)" || no "dead-man rolled back with the tryboot armed: $(tr '\n' ' ' < "$T/log")"; echo 0 > "$T/flag"
	dmrun cancel; ! rolled && [ ! -e "$BASE/ch1.running" ] && ok "dead-man cancelled: nothing, no marker left" || no "dead-man ignored ch1.cancel / left a marker"
	dmrun run; ! rolled && ok "dead-man: a second instance (ch1.running exists) does nothing" || no "dead-man ran twice"
	(STUB_MKDIR_CANCEL=y; export STUB_MKDIR_CANCEL; dmrun); ! rolled && [ ! -e "$BASE/ch1.running" ] && ok "dead-man: ch1.cancel landing between its first check and its marker -> stands down, marker removed (round 6)" || no "dead-man acted after a cancel that landed before its marker: $(tr '\n' ' ' < "$T/log")"
else no "dead-man script not found in $ROOT/scripts/dv/chain1-254.sh"; fi
# restore_all's side of the handshake (fresh-254.sh), BEFORE its p5-restore: cancel, then the dead-man must be neither
# acting nor done (round 6 A-MINOR-2 / B-MINOR-2)
hc=$(grep 'echo CANCELLED")' "$ROOT/scripts/dv/fresh-254.sh" | sed -n 's/.*o=$(fq "\(.*\)")$/\1/p')
if [ -n "$hc" ]; then
	BASE=$T/hs; mkdir -p "$BASE"; eval "hcx=\"$hc\""; hcx=${hcx//\/opt\/batdata/$T}
	hs(){ rm -rf "$BASE"/ch1.*; for f; do case "$f" in run) mkdir "$BASE/ch1.running";; *) : > "$BASE/ch1.$f";; esac; done; node 1201bf8a B 1 0; nsh "$hcx"; }
	o=$(hs); [ "$o" = CANCELLED ] && [ -e "$BASE/ch1.cancel" ] && ok "restore handshake: ch1.cancel written, dead-man idle -> CANCELLED" || no "restore handshake idle: [$o] cancel=$([ -e "$BASE/ch1.cancel" ] && echo y)"
	o=$(hs run); [ "$o" != CANCELLED ] && ok "restore handshake: the dead-man acting (ch1.running) -> stop before the p5-restore" || no "restore went on while the dead-man acts"
	o=$(hs fired); [ "$o" != CANCELLED ] && ok "restore handshake: the dead-man done (ch1.fired) -> stop" || no "restore went on after the dead-man fired"
	ra=$(sed -n '/^restore_all(){/,/^}/p' "$ROOT/scripts/dv/fresh-254.sh"); lc=$(echo "$ra" | grep -n 'echo CANCELLED' | head -1 | cut -d: -f1); lp=$(echo "$ra" | grep -n 'p5-restore \$RUN' | head -1 | cut -d: -f1)
	[ -n "$lc" ] && [ -n "$lp" ] && [ "$lc" -lt "$lp" ] && ok "restore_all: the handshake (line $lc) comes before its first p5-restore (line $lp)" || no "restore_all: handshake at [$lc], first p5-restore at [$lp]"
else no "restore_all's cancel step not found in $ROOT/scripts/dv/fresh-254.sh"; fi
# ---- the node's shell is busybox ash: the guard commands parse there, and DISARM reads the captured 04 line
if command -v busybox >/dev/null 2>&1; then
	for c in "$(rb_guarded 1201bf8a B 1 x "[ -e /x ]")" "$(reboot_guarded 1201bf8a A 0 x)" "$(release_guarded 1201bf8a B nowait)"; do
		busybox ash -n -c "$c" 2>/dev/null || no "busybox ash cannot parse a guard command: ${c:0:80}"; done; ok "busybox ash parses rb / reboot / release guard commands"
	mkdir -p "$T/bb"; vm(){ printf '#!/bin/sh\ncase "$1" in 0x00030064) echo "%s";; esac\n' "$1" > "$T/bb/vcmailbox"; chmod +x "$T/bb/vcmailbox"; PATH="$T/bb:$PATH" busybox ash -c "$DISARM"; }
	[ "$(vm '0x0000001c 0x80000000 0x00030064 0x00000004 0x80000004 0x00000000 0x00000000')" = tryboot_flag=0 ] && ok "busybox ash: DISARM on the line captured from 04 -> tryboot_flag=0" || no "busybox DISARM on the 04 capture: [$(vm '0x0000001c 0x80000000 0x00030064 0x00000004 0x80000004 0x00000000 0x00000000')]"
	[ "$(vm '0x0000001c 0x80000000 0x00030064 0x00000004 0x80000004 0x00000001 0x00000000')" = tryboot_flag=1 ] && ok "busybox ash: armed -> tryboot_flag=1" || no "busybox DISARM armed"
	[ "$(vm '0x0000001c 0x80000000 0x00030064 0x00000004 0x00000004 0x00000000 0x00000000')" = tryboot_flag=unknown ] && ok "busybox ash: tag not answered -> unknown" || no "busybox DISARM unanswered tag"
	[ "$(vm '0x0000001c 0x80000001 0x00030064 0x00000004 0x80000004 0x00000000 0x00000000')" = tryboot_flag=unknown ] && ok "busybox ash: error response -> unknown" || no "busybox DISARM error response"
else no "busybox missing: the node-shell checks cannot run"; fi

# stubs the converted sites need on the node: commit, firstboot (STUB_FB_RC), a plain reboot (logged, never run), logger
# (logged: the <pre> output), sleep (STUB_NOSLEEP: FI's old `sleep 2; …` lands at once)
cat > "$T/bin/firstboot" <<'STUB'
#!/bin/sh
echo "firstboot $*" >> "$STUB_LOG"; exit "${STUB_FB_RC:-0}"
STUB
cat > "$T/bin/logger" <<'STUB'
#!/bin/sh
echo "logger $*" >> "$STUB_LOG"; [ $# -le 2 ] && cat >/dev/null 2>&1; exit 0   # reads stdin only without a message, as logger
STUB
chmod +x "$T/bin/firstboot" "$T/bin/logger"
ST=x; PL_NAME=prov-claim; BLE_SSHO=(); BT305_SSHO=()

# ---- #254 v1.6 group 4 §4.1: commit_guarded, reboot_guarded's `-` extra and <pre>
committed_log(){ grep -q '^commit$' "$T/log"; }
node 1201bf8a B 0 0; o=$(nsh "$(commit_guarded 1201bf8a B)"); case "$o" in "SENT batman-slot: committed slot B as default"*) committed_log && ! rebooted && ok "commit_guarded: the trial in that boot: SENT + the commit's output, no reboot" || no "commit_guarded: log $(tr '\n' ' ' < "$T/log")";; *) no "commit_guarded matching: [$o]";; esac
node aaaaaaaa B 0 0; o=$(nsh "$(commit_guarded 1201bf8a B)"); case "$o" in WRONG-STATE*) ! committed_log && ok "commit_guarded: another boot -> WRONG-STATE, no commit" || no "committed in another boot";; *) no "commit_guarded other boot: [$o]";; esac
node 1201bf8a B 1 0; o=$(nsh "$(commit_guarded 1201bf8a B)"); case "$o" in WRONG-STATE*) ! committed_log && ok "commit_guarded: already committed -> WRONG-STATE, no commit" || no "commit_guarded committed a committed slot";; *) no "commit_guarded committed: [$o]";; esac
node 1201bf8a A 0 0; o=$(nsh "$(commit_guarded 1201bf8a B)"); case "$o" in WRONG-STATE*) ! committed_log && ok "commit_guarded: a trial on the other slot -> WRONG-STATE, no commit" || no "commit_guarded committed the other slot";; *) no "commit_guarded other slot: [$o]";; esac
node 1201bf8a B 0 0; o=$(nsh "$(commit_guarded "" B)"); case "$o" in WRONG-STATE*) ! committed_log && ok "commit_guarded: an empty boot -> WRONG-STATE" || no "commit_guarded with an empty boot committed";; *) no "commit_guarded empty boot: [$o]";; esac
echo 1 > "$T/flag"; node 1201bf8a B 0 0; o=$(STUB_DISARM_FAIL=y; export STUB_DISARM_FAIL; nsh "$(commit_guarded 1201bf8a B)"); case "$o" in "SENT "*) ! grep -q '^disarm$' "$T/log" && ok "commit_guarded: no DISARM (a commit does not reboot), sent with the flag armed" || no "commit_guarded disarmed";; *) no "commit_guarded armed: [$o]";; esac; echo 0 > "$T/flag"
fb(){ grep -q '^firstboot' "$T/log"; }
node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 x - 'firstboot -y')"); [ "$o" = SENT ] && fb && rebooted && ok "reboot_guarded <pre>: checks hold -> pre runs, then the reboot: SENT" || no "pre ok: [$o] $(tr '\n' ' ' < "$T/log")"
grep -q '^logger -t slot-guard pre-action rc=0$' "$T/log" && ok "reboot_guarded <pre>: its rc / output go to logger -t slot-guard" || no "pre not logged: $(tr '\n' ' ' < "$T/log")"
node aaaaaaaa A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 x - 'firstboot -y')"); case "$o" in WRONG-STATE*) ! fb && ! rebooted && ok "reboot_guarded <pre>: another boot -> WRONG-STATE, pre NOT run, no reboot" || no "pre ran / rebooted on WRONG-STATE";; *) no "pre other boot: [$o]";; esac
echo 1 > "$T/flag"; node 1201bf8a A 1 0; o=$(STUB_DISARM_FAIL=y; export STUB_DISARM_FAIL; nsh "$(reboot_guarded 1201bf8a A 1 x - 'firstboot -y')"); case "$o" in *" extra=0") ! fb && ! rebooted && ok "reboot_guarded <pre>: a tryboot that will not disarm -> pre NOT run, no reboot" || no "pre ran with the tryboot armed";; *) no "pre armed: [$o]";; esac; echo 0 > "$T/flag"
node 1201bf8a A 1 0; o=$(STUB_FB_RC=1; export STUB_FB_RC; nsh "$(reboot_guarded 1201bf8a A 1 x - 'firstboot -y')"); [ "$o" = "PRE-FAILED SENT" ] && rebooted && ok "reboot_guarded <pre> fails -> the reboot still follows: PRE-FAILED SENT" || no "pre fails: [$o] $(tr '\n' ' ' < "$T/log")"
node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 x - "")"); [ "$o" = SENT ] && ! fb && ok "reboot_guarded: extra '-' = true, empty pre = none" || no "extra '-': [$o]"
node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 1 x "[ -e $T/nonexistent ]" 'firstboot -y')"); case "$o" in *" extra=0") ! fb && ok "reboot_guarded: a false extra condition -> pre NOT run" || no "pre ran with a false extra";; *) no "extra false + pre: [$o]";; esac

# ---- the converted call sites (group 4 §4.2 rows 1-12, 15, 19), extracted from ROOT and run against the stub node.
# Each is cut out between two lines that exist before and after the conversion, so ROOT=<b885a2c> runs the OLD lines
# (they reboot / commit whatever the state -> FAIL: the negative control).
# xr <file> <start ERE> <end ERE> [excl]: from the first line matching start to the first (from start on) matching end
# (ENVIRON, not -v: awk -v would eat the backslashes of the patterns); <file> - = stdin
xr(){ local f=$ROOT/$1; [ "$1" = - ] && f=/dev/stdin; XA=$2 XB=$3 XX=${4:-} awk 'f == 0 && $0 ~ ENVIRON["XA"] { f = 1 } f == 1 { if ($0 ~ ENVIRON["XB"]) { if (ENVIRON["XX"] == "") print; exit } print }' "$f"; }
# xf <file> <function header ERE>: the function's lines (to the first line that is exactly "}")
xf(){ XA=$2 awk '$0 ~ ENVIRON["XA"] { f = 1 } f { print } f && /^}$/ { exit }' "$ROOT/$1"; }
# the boot id the HOST read (always 1201bf8a): "another boot" = the node (NB) rebooted after that read
NBF(){ echo "1201bf8a-1111-4222-8333-444455556666"; }
# the node-command stubs every site uses: q / qr / n / fq / bt305_ssh / ssh run the command on the stub node; a
# `cat …boot_id` answers the full boot id
nodecmd(){ case "$1" in *'cat /proc/sys/kernel/random/boot_id'*) NBF ;; *) nsh "$1" ;; esac; }
stubs(){
	q(){ nodecmd "$*"; }; qr(){ nodecmd "$*"; }; n(){ nodecmd "$*"; }; bt305_ssh(){ shift 2; nodecmd "$*"; }
	timeout(){ shift; "$@"; }; ssh(){ local a; for a; do :; done; nodecmd "$a"; }
	bid(){ [ -n "${BID_EMPTY:-}" ] || NBF; }; bootid(){ NBF; }; slot(){ nsh 'batman-slot active'; }
	no(){ echo "FAIL $*"; }; ok(){ :; }; say(){ :; }; inv(){ echo "FAIL $*"; }
	pr_needs_person(){ echo "FAIL person $*"; return 1; }; pr_abort(){ echo "FAIL abort $*"; }; pr_result(){ :; }
	p5_person(){ echo "FAIL person $*"; }; pr_find(){ return 0; }; waitboot(){ return 0; }; settle(){ return 0; }
	ledger_has(){ return 0; }
}
reb(){ sleep 0.2; grep -qE '^(reboot committed|plain-reboot)' "$T/log"; }   # a guarded or a plain reboot reached the node
# site <label> <code> <call> <act reboot|commit>: the code defines (or is) the site; <call> runs it, with the stubs, in a
# subshell (the stubs never leak into this test). Matching state: no FAIL line and the act done; another boot (the node
# rebooted after the host's read): a FAIL line and nothing done
site(){ local l=$1 code=$2 call=$3 act=$4 o done
	[ -n "$code" ] || { no "site $l: not found in $ROOT"; return; }
	node 1201bf8a "${SA:-A}" "${STR:-1}" 0; o=$(stubs; eval "$code"; eval "$call" 2>&1); if [ "$act" = commit ]; then committed_log; else reb; fi; done=$?
	if [ $done = 0 ] && ! grep -q '^FAIL' <<< "$o"; then ok "site $l: the matching state -> $act sent, no FAIL"; else no "site $l: matching state: [$(echo $o | cut -c1-160)] $(tr '\n' ' ' < "$T/log")"; fi
	node aaaaaaaa "${SA:-A}" "${STR:-1}" 0; o=$(stubs; eval "$code"; eval "$call" 2>&1); if [ "$act" = commit ]; then committed_log; else reb; fi; done=$?
	if [ $done != 0 ] && grep -q '^FAIL' <<< "$o"; then ok "site $l: another boot -> refused (FAIL), nothing sent"; else no "site $l: another boot: $act done=$([ $done = 0 ] && echo YES || echo no) [$(echo $o | cut -c1-160)]"; fi
}
export STUB_NOSLEEP=1   # FI's old `setsid sh -c 'sleep 2; …'` must land before the check
eval "$(sed -n '/^field(){/p' "$ROOT/scripts/dv/prov-254.sh")"
site "1 addr-defer reboot_c" "$(xr scripts/dv/addr-defer-reconcile-254.sh '^reboot_c\(\)\{' 't=\$SECONDS$'; echo 'return 0; }')" 'reboot_c' reboot
node 1201bf8a A 1 0; o=$(BID_EMPTY=1; stubs; eval "$(xr scripts/dv/addr-defer-reconcile-254.sh '^reboot_c\(\)\{' 't=\$SECONDS$'; echo 'return 0; }')"; reboot_c 2>&1)
! reb && grep -q '^FAIL' <<< "$o" && ok "site 1 addr-defer: boot id unreadable on the host -> refused, no reboot (was: no reboot proof)" || no "site 1 empty boot: [$o] $(tr '\n' ' ' < "$T/log")"
site "2 ble_reboot_committed" "$(xr scripts/dv/ble-254.sh '^ble_reboot_committed\(\) \{' 'sleep 20$'; echo 'return 0; }')" 'sleep(){ [ "$1" = 20 ] || command sleep "$1"; }; ble_reboot_committed 10.0.0.9' reboot
site "3 bt305_reboot" "$(xr scripts/dv/bt-uart-305.sh '^bt305_reboot\(\) \{' 't0=\$SECONDS'; echo 'return 0; }')" 'bt305_reboot 10.0.0.9 bt305-restore' reboot
site "4 pr_restore_cycle" "sitef(){ s='slot=A trial_rc=1 boot=1201bf8a'; $(xf scripts/dv/prov-254.sh '^pr_restore_cycle\(\)\{' | xr - 'b0=\$\(field "\$s" boot\)' 'pr_find 900')
return 0; }" sitef reboot
site "5 pr_member" "sitef(){ $(xf scripts/dv/prov-254.sh '^pr_member\(\)\{' | xr - 'b0=\$\(field "\$s" boot\)' 'pr_find 900')
return 0; }" "s='slot=A trial_rc=1 boot=1201bf8a'; qr(){ echo \"\$s\"; }; sitef" reboot
site "6 leave-ota" "sitef(){ $(xr scripts/dv/prov-leave-ota-254.sh 's=\$\(qr "\$ST"\); b0=\$\(field "\$s" boot\)$' 'pr_find 900')
return 0; }" "qr(){ echo 'slot=A trial_rc=1 boot=1201bf8a'; }; sitef" reboot
site "7 pl_restore" "sitef(){ $(xr scripts/dv/prov-lib-254.sh '^b0=\$\(bid\)' 'no "reboot after restore')
return 0; }" sitef reboot
site "8 misc L3" "sitef(){ $(xr scripts/dv/prov-misc-254.sh 'b0=\$\(field "\$o" boot\)' 'pr_find 900')
return 0; }" "qr(){ echo 'slot=A trial_rc=1 boot=1201bf8a'; }; sitef" reboot
site "9 overlay-corrupt" "sitef(){ ( $(xr scripts/dv/prov-overlay-corrupt-254.sh '^s=\$\(qr "\$ST"\); b0=\$\(field "\$s" boot\)' 'pr_find 900')
); }" "qr(){ echo 'slot=A trial_rc=1 boot=1201bf8a'; }; sitef" reboot
WIPE=$(xr scripts/dv/prov-overlay-wipe-254.sh '^s=\$\(qr "\$ST"\); b0=\$\(field "\$s" boot\)$' '^pr_find 900')
site "10 overlay-wipe" "sitef(){ ( $WIPE
); }" "qr(){ echo 'slot=A trial_rc=1 boot=1201bf8a'; }; sitef" reboot
if [ -n "$WIPE" ]; then
	wipef(){ stubs; eval "sitef(){ ( $WIPE
); }"; qr(){ echo 'slot=A trial_rc=1 boot=1201bf8a'; }; sitef; }
	node aaaaaaaa A 1 0; o=$(wipef 2>&1); ! fb && ! reb && ok "site 10 overlay-wipe: another boot -> no firstboot, no reboot (the upper is not wiped)" || no "site 10: wiped / rebooted on WRONG-STATE: $(tr '\n' ' ' < "$T/log")"
	node 1201bf8a A 1 0; o=$(wipef 2>&1); fb && reb && [ "$(grep -n '^firstboot' "$T/log" | cut -d: -f1)" -lt "$(grep -n '^reboot committed' "$T/log" | cut -d: -f1)" ] && ok "site 10 overlay-wipe: firstboot -y runs after the checks, before the reboot" || no "site 10 order: $(tr '\n' ' ' < "$T/log")"
	node 1201bf8a A 1 0; o=$(STUB_FB_RC=1; export STUB_FB_RC; wipef 2>&1); reb && grep -q '^FAIL abort firstboot -y failed' <<< "$o" && ok "site 10 overlay-wipe: firstboot fails -> PRE-FAILED SENT: rebooted, the unit FAILs" || no "site 10 pre fails: [$o]"
	unset -f wipef
fi
STR=0; site "11 FI p5 out of the trial" "sitef(){ $(xr scripts/fault-injection.sh 'b2=\$\(bootid\); \[ -n "\$b2" \] \|\| \{ p5_person "P5: AP restore: boot id' 'waitboot "\$b2" 300')
return 0; }" "s=A; sitef" reboot; unset STR
site "12 FI p5 placeholder" "sitef(){ set -- x y A; $(xr scripts/fault-injection.sh 'b2=\$\(bootid\); \[ -n "\$b2" \] \|\| \{ p5_person "P5: boot id unreadable before the placeholder' 'waitboot "\$b2" 300')
return 0; }" sitef reboot
SA=B STR=0; site "15 FI C2 commit" "sitef(){ $(xr scripts/fault-injection.sh 'ledger_has "crash \$EUDC" \|\| \{ no "C2' 'lim=\$\(\(dl' excl)
return 0; }" "b0=1201bf8a-1111-4222-8333-444455556666; tr=B; EUDC=x; sitef" commit; unset SA STR
site "19 FI F1" "sitef(){ local r=1; $(xr scripts/fault-injection.sh 'b=\$\(bootid\); \[ -n "\$b" \] \|\| \{ no "F1 boot_id' 'waitboot "\$b" 400')
return 0; }" sitef reboot
unset STUB_NOSLEEP

# ---- pty-commit stop_commit (row 13; §13.2, §15): commits only the held trial of V on TGT in a boot after b0, through
# commit_guarded, read back; every other outcome a FAIL line + NEEDS-PERSON in $DV_DIR/needs-person.txt
pc=$(xf scripts/dv/pty-commit-254.sh '^stop_person\(\)\{'; xf scripts/dv/pty-commit-254.sh '^stop_commit\(\)\{')
pcst=$(sed -n "s/^ST='\(.*\)'$/\1/p" "$ROOT/scripts/dv/pty-commit-254.sh")
if [ -n "$pc" ] && type commit_guarded >/dev/null 2>&1; then
	eval "$pc"; mkdir -p "$T/dv"
	# the state line the node gives (in order: STS1, then STS2 after a commit); the guard command runs on the stub node
	q(){ if [ "$*" = "$ST" ]; then if [ -e "$T/st2" ]; then printf '%s\n' "$STS2"; else : > "$T/st2"; printf '%s\n' "$STS1"; fi; else nsh "$*"; fi; }
	say(){ :; }
	pcrun(){ rm -f "$T/st2" "$T/dv/needs-person.txt"; node "$1" B "$2" 0; ( DV_DIR=$T/dv; NODE=10.0.0.9; V=9.9; TGT=B; b0=c5faffaa-0000-4000-8000-000000000000; ST=x; stop_commit ); }
	held="slot=B ver=9.9 trial_rc=0 dt_try=00000001 held=1 badslot=[] up=200 boot=1201bf8a"
	np(){ grep -q '^NEEDS-PERSON pty-commit-254 (10.0.0.9): ' "$T/dv/needs-person.txt" 2>/dev/null; }
	STS1=$held STS2="slot=B ver=9.9 trial_rc=1 dt_try=00000000 held=0 badslot=[] up=210 boot=1201bf8a"
	o=$(pcrun 1201bf8a 0); r=$?; [ $r = 0 ] && committed_log && ! np && ok "pty-commit stop: the held trial of V on TGT, landing boot -> commit_guarded SENT, read back, no NEEDS-PERSON" || no "pty-commit stop commit: rc=$r [$o] $(tr '\n' ' ' < "$T/log")"
	o=$(pcrun aaaaaaaa 0); r=$?; [ $r != 0 ] && ! committed_log && np && grep -q 'FAIL pty-commit: trial not committed (WRONG-STATE)' <<< "$o" && ok "pty-commit stop: the boot changed after the read -> WRONG-STATE: FAIL + NEEDS-PERSON, no commit" || no "pty-commit WRONG-STATE: rc=$r [$o]"
	STS1=""; o=$(pcrun 1201bf8a 0); r=$?; [ $r != 0 ] && ! committed_log && np && grep -q 'node unreachable' <<< "$o" && ok "pty-commit stop: node unreachable (the settle-failed path) -> FAIL + NEEDS-PERSON" || no "pty-commit unreachable: rc=$r [$o]"
	STS1="slot=A ver=9.9 trial_rc=1 dt_try=00000000 held=0 badslot=[slot=B version=9.9] up=50 boot=99999999"; o=$(pcrun 99999999 1); r=$?; [ $r != 0 ] && ! committed_log && np && ok "pty-commit stop: already reverted (bad-slot) -> FAIL + NEEDS-PERSON" || no "pty-commit reverted: rc=$r [$o]"
	STS1="slot=A ver=9.9 trial_rc=0 dt_try=00000001 held=1 badslot=[] up=50 boot=1201bf8a"; o=$(pcrun 1201bf8a 0); r=$?; [ $r != 0 ] && ! committed_log && np && ok "pty-commit stop: a trial on the other slot (not TGT) -> no commit, NEEDS-PERSON" || no "pty-commit wrong slot: rc=$r [$o]"
	STS1="slot=B ver=9.9 trial_rc=0 dt_try=00000001 held=0 badslot=[] up=50 boot=1201bf8a"; o=$(pcrun 1201bf8a 0); r=$?; [ $r != 0 ] && ! committed_log && np && ok "pty-commit stop: not held -> no commit, NEEDS-PERSON" || no "pty-commit not held: rc=$r [$o]"
	STS1="slot=B ver=9.8 trial_rc=0 dt_try=00000001 held=1 badslot=[] up=50 boot=1201bf8a"; o=$(pcrun 1201bf8a 0); r=$?; [ $r != 0 ] && ! committed_log && np && ok "pty-commit stop: another version -> no commit, NEEDS-PERSON" || no "pty-commit other version: rc=$r [$o]"
	STS1="slot=B ver=9.9 trial_rc=0 dt_try=00000001 held=1 badslot=[] up=50 boot=c5faffaa"; o=$(pcrun c5faffaa 0); r=$?; [ $r != 0 ] && ! committed_log && np && ok "pty-commit stop: the boot before the OTA (b0) -> no commit, NEEDS-PERSON" || no "pty-commit b0: rc=$r [$o]"
	STS1=$held STS2=$held; o=$(pcrun 1201bf8a 0); r=$?; [ $r != 0 ] && np && grep -q 'no read-back' <<< "$o" && ok "pty-commit stop: SENT but not read back as committed -> FAIL + NEEDS-PERSON" || no "pty-commit no read-back: rc=$r [$o]"
	STS1="slot=B ver=9.9 trial_rc=1 dt_try=00000000 held=0 badslot=[] up=50 boot=1201bf8a"; o=$(pcrun 1201bf8a 1); r=$?; [ $r = 0 ] && ! committed_log && ! np && ok "pty-commit stop: TGT already committed (a stop after step 3) -> nothing to do, no NEEDS-PERSON" || no "pty-commit already committed: rc=$r [$o]"
	case "$pcst" in *' boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id)"') ok "pty-commit: its state line ends with boot= (what stop_commit binds to)";; *) no "pty-commit ST has no trailing boot=: [${pcst: -60}]";; esac
	unset -f q say stop_commit stop_person pcrun np
else no "pty-commit stop_commit / stop_person not found in $ROOT/scripts/dv/pty-commit-254.sh"; fi
grep -q '^	DV_DIR=$DIR V=$v PAY=$DV_OTA_PAYLOAD PSH16=.* bash "$REPO/scripts/dv/pty-commit-254.sh"' "$ROOT/scripts/dv/claim-lock-254.sh" \
	&& ok "claim-lock passes DV_DIR to pty-commit (its NEEDS-PERSON reaches needs-person.txt)" || no "claim-lock-254.sh does not pass DV_DIR=\$DIR to pty-commit-254.sh"

# ---- reboot_and_wait (daily-validation.sh; §4.2 rows 24-31, §13.7, §15): the trigger runs only when the tryboot GET
# answers and the flag reads 0, in the same ssh command; else a FAIL naming the case + needs-person.txt, no trigger.
# fssh runs the command on the stub node (vcmailbox reads $T/flag; `reboot` logs plain-reboot); bootid changes after it
raw=$(sed -n '/^reboot_and_wait() {/,/echo "rebooted: boot_id/p' "$ROOT/scripts/daily-validation.sh")
if [ -n "$raw" ]; then
	eval "${raw//\/proc\/device-tree\/compatible/$T/compatible}"
	DIR=$T/rw; mkdir -p "$DIR"
	fssh(){ nsh "$3"; }; bootid(){ if reb; then echo b-after; else echo b-before; fi; }; dwait(){ return 0; }
	rw(){ rm -f "$DIR/needs-person.txt"; node 1201bf8a A 1 0; ( sleep(){ :; }; reboot_and_wait 10.0.0.9 "${1:-reboot}" 240 ); }
	rwnp(){ grep -q "^NEEDS-PERSON reboot_and_wait (10.0.0.9): tryboot flag $1" "$DIR/needs-person.txt" 2>/dev/null; }
	printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$T/compatible"
	echo 1 > "$T/flag"; o=$(rw); r=$?; [ $r != 0 ] && ! reb && grep -q '^FAIL tryboot flag armed on 10.0.0.9 — not rebooting' <<< "$o" && rwnp armed && ok "reboot_and_wait: flag armed (0x00000001) -> FAIL 'armed', no trigger, needs-person.txt" || no "reboot_and_wait armed: rc=$r reb=$(reb && echo y) [$(echo $o | cut -c1-200)]"
	echo 0 > "$T/flag"; o=$(STUB_W5=0x00000004; export STUB_W5; rw); r=$?; [ $r != 0 ] && ! reb && grep -q '^FAIL tryboot flag not answered (Pi 4) on' <<< "$o" && rwnp 'not answered (Pi 4)' && ok "reboot_and_wait: tag not answered on a Pi 4 -> FAIL 'not answered (Pi 4)', no trigger" || no "reboot_and_wait unanswered Pi 4: rc=$r [$(echo $o | cut -c1-200)]"
	printf 'raspberrypi,3-model-b\0brcm,bcm2837\0' > "$T/compatible"
	o=$(STUB_W5=0x00000004; export STUB_W5; rw); r=$?; [ $r != 0 ] && ! reb && grep -q '^FAIL tryboot flag not answered (Pi 3 firmware) on' <<< "$o" && ok "reboot_and_wait: tag not answered on a Pi 3 -> FAIL 'not answered (Pi 3 firmware)', no trigger" || no "reboot_and_wait unanswered Pi 3: rc=$r [$(echo $o | cut -c1-200)]"
	printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$T/compatible"
	o=$(STUB_RESP=0x80000001; export STUB_RESP; rw); r=$?; [ $r != 0 ] && ! reb && grep -q '^FAIL tryboot flag not answered' <<< "$o" && ok "reboot_and_wait: an error response with value 0 -> not 'clear', no trigger" || no "reboot_and_wait error response: rc=$r [$(echo $o | cut -c1-200)]"
	o=$(rw); r=$?; [ $r = 0 ] && reb && grep -q '^rebooted: boot_id b-before -> b-after' <<< "$o" && ! [ -e "$DIR/needs-person.txt" ] && ok "reboot_and_wait: flag clear (0x00000000, compared numerically) -> the trigger runs, rebooted" || no "reboot_and_wait clear: rc=$r [$(echo $o | cut -c1-200)] $(tr '\n' ' ' < "$T/log")"
	o=$(rw 'sync; echo c > /dev/null; echo trigger-said-hello'); r=$?; [ $r != 0 ] && grep -q 'trigger: trigger-said-hello' <<< "$o" && grep -q '^FAIL reboot did not happen' <<< "$o" && ! grep -q 'tryboot flag' <<< "$o" && ok "reboot_and_wait: the trigger's output is printed; a trigger that does not reboot is not blamed on the flag" || no "reboot_and_wait trigger output: rc=$r [$(echo $o | cut -c1-240)]"
	echo 1 > "$T/flag"; o=$(DV_TEST_NOREBOOT=1; rw); r=$?; [ $r != 0 ] && ! reb && ! grep -q '^disarm\|tryboot' "$T/log" && grep -q '^FAIL reboot did not happen' <<< "$o" && ok "reboot_and_wait: DV_TEST_NOREBOOT=1 replaces the whole command (no GET, no trigger) -> 'reboot did not happen'" || no "reboot_and_wait NOREBOOT: rc=$r [$(echo $o | cut -c1-200)]"; echo 0 > "$T/flag"
	if command -v busybox >/dev/null 2>&1; then
		pcl=$(sed -n "s/^  local pc='\(.*\)'$/\1/p" "$ROOT/scripts/daily-validation.sh")
		[ -n "$pcl" ] && busybox ash -n -c "$pcl; if [ \$a = 1 ] && [ \"\$f\" = 0 ]; then reboot; else echo x; fi" 2>/dev/null && ok "busybox ash parses the reboot_and_wait precheck" || no "busybox ash cannot parse the precheck [$pcl]"
	fi
	unset -f fssh bootid dwait rw rwnp reboot_and_wait
else no "reboot_and_wait not found in $ROOT/scripts/daily-validation.sh"; fi
unset -f fq

# ---- find_base (fresh-254.sh): a restore finds the node on the base version V, or on VB when bench-s0 unclaimed put
# another version into B (2026-11-09); without VB only V. find04 is a stub: the node "is on" $ON, the asked patterns logged
fb=$(sed -n '/^find_base(){/,/; }$/p' "$ROOT/scripts/dv/fresh-254.sh")
if [ -n "$fb" ]; then
	fbt(){ ( [ -n "${VBT:-}" ] && VB=$VBT || unset VB; [ -n "${VBOFF:-}" ] && VB_ON= || VB_ON=1; eval "$fb"; ASKED=""; find04(){ ASKED="${ASKED}[$1]"; [ "$1" = "ver=$ON " ]; }; sleep(){ :; }
		if find_base 1; then echo "found $ASKED" | cut -c1-80; else echo "none $(printf '%s' "$ASKED" | tr ']' '
' | sort -u | tr '
' ' ')"; fi ); }
	o=$(V=1.0 ON=1.0 fbt); [ "$o" = "found [ver=1.0 ]" ] && ok "find_base: no VB, node on V -> found by V" || no "find_base no VB on V: [$o]"
	o=$(V=1.0 ON=2.0 fbt); [ "$o" = "none [ver=1.0  " ] && ok "find_base: no VB, node on another version -> not found, only V asked" || no "find_base no VB other: [$o]"
	o=$(V=1.0 VBT=2.0 ON=2.0 fbt); [ "$o" = "found [ver=1.0 ][ver=2.0 ]" ] && ok "find_base: VB set, node on VB -> found (V asked first)" || no "find_base VB on VB: [$o]"
	o=$(V=1.0 VBT=1.0 ON=2.0 fbt); [ "$o" = "none [ver=1.0  " ] && ok "find_base: VB = V -> only V asked" || no "find_base VB=V: [$o]"
	o=$(V=1.0 VBT=2.0 ON=1.0 fbt); [ "$o" = "found [ver=1.0 ]" ] && ok "find_base: VB set, node on V -> found by V before VB is asked" || no "find_base VB on V: [$o]"
	o=$(V=1.0 VBT=2.0 ON=3.0 fbt); [ "$o" = "none [ver=1.0  [ver=2.0  " ] && ok "find_base: VB set, node on a third version -> not found" || no "find_base third: [$o]"
	# review m3: both first finds of a restore go through find_base
	c1=$(sed -n '/^restore_all(){/,/^}/p' "$ROOT/scripts/dv/fresh-254.sh" | grep -c 'find_base 900'); c2=$(sed -n '/^if \[ "\$MODE" = restore \]; then/,/^fi/p' "$ROOT/scripts/dv/prov-bench-s0-254.sh" | grep -c 'find_base 300')
	[ "$c1" = 1 ] && [ "$c2" = 1 ] && ok "find_base: restore_all and bench-s0 restore both find the node through it" || no "find_base call sites: restore_all=[$c1] restore=[$c2]"
	c3=$(sed -n '/^restore_all(){/,/^}/p' "$ROOT/scripts/dv/fresh-254.sh" | grep -c "PROTB_FROM='\$V' PROTB_TO='\$VB' \")sh \$BASE/prov-base-254.sh compare")
	[ "$c3" = 1 ] && ok "restore_all: its compare names protB V -> VB (with VB_ON)" || no "restore_all compare without PROTB_FROM/TO [$c3]"
	o=$(V=1.0 VBT=2.0 ON=2.0 VBOFF=1 fbt); [ "$o" = "none [ver=1.0  " ] && ok "find_base: VB in the env without VB_ON (chain1) -> only V asked" || no "find_base VB without VB_ON: [$o]"
else no "find_base not found in $ROOT/scripts/dv/fresh-254.sh"; fi

# ---- the field boundary on the real incident line
s='mac=88:a2:9e:b5:6c:89 slot=A ver=1.5.14-wsl.22+2ecf1cb.fwce20a68 trial_rc=1 dt_try=00000000 hold=[] held=0 badslot=[slot=B version=1.5.14-wsl.22+2ecf1cb.fwce20a68] up=40 boot=c5faffaa'
case "$s" in *"slot=B "*) ok "control: the old pattern *\"slot=B \"* does match the A line (the bug)";; *) no "control: old pattern did not match";; esac
case "$s" in *" slot=B "*) no "anchored pattern matches the A line";; *) ok "anchored pattern \" slot=B \" does not match the A line";; esac
case "$s" in *" slot=A "*) ok "anchored pattern finds slot=A";; *) no "anchored pattern misses slot=A";; esac

# the real is_on / find04 from fresh-254.sh (extracted, network stubbed): a state line whose bracket fields carry the
# searched text must not match. The old `*$2*` matched these (ROOT=<HEAD before the fix> FAILs here).
MAC=88:a2:9e:b5:6c:89; V=1.5.14-wsl.22; ST=x; FRESHO=""; NODE=10.0.0.9; SEEN=""; MDNS=none
ping(){ return 0; }; timeout(){ shift; "$@"; }; ssh(){ printf '%s\n' "$STATE"; }; sweep(){ :; }; macips(){ :; }
eval "$(sed -n '/^is_on(){/p; /^find04(){/,/^}/p' "$ROOT/scripts/dv/fresh-254.sh")"
type is_on >/dev/null 2>&1 && type find04 >/dev/null 2>&1 && ok "is_on / find04 extracted from $ROOT" || no "is_on / find04 not found in $ROOT/scripts/dv/fresh-254.sh"
m(){ STATE=$1; is_on 10.0.0.9 "$2" >/dev/null && echo match || echo nomatch; }
A="mac=$MAC slot=A ver=$V trial_rc=1 dt_try=00000000 hold=[] held=0"
[ "$(m "$A badslot=[slot=B ver=$V trial_rc=1 ] up=1 boot=c5faffaa" "slot=B ver=$V trial_rc=1 ")" = nomatch ] && ok "is_on: A committed with badslot=[slot=B ver=… trial_rc=1 ] is not 'slot=B …'" || no "is_on matched slot=B inside badslot=[]"
[ "$(m "mac=$MAC slot=A ver=$V trial_rc=1 dt_try=0 hold=[slot=B ver=$V trial_rc=1 ] held=1 badslot=[] up=1 boot=c5faffaa" "slot=B ver=$V trial_rc=1 ")" = nomatch ] && ok "is_on: hold=[slot=B …] is not 'slot=B …'" || no "is_on matched slot=B inside hold=[]"
[ "$(m "mac=$MAC slot=B ver=$V trial_rc=0 dt_try=1 hold=[] held=0 badslot=[slot=A ver=$V trial_rc=1 ] up=1 boot=1" "slot=A ver=$V trial_rc=1 ")" = nomatch ] && ok "is_on: B trial with badslot=[slot=A …] is not 'slot=A …'" || no "is_on matched slot=A inside badslot=[]"
[ "$(m "$A badslot=[] up=1 boot=c5faffaa" "slot=A ver=$V trial_rc=1 ")" = match ] && ok "is_on: the real A committed line matches 'slot=A ver=… trial_rc=1 '" || no "is_on missed a real A line"
[ "$(m "$A badslot=[] up=1 boot=c5faffaa" "trial_rc=1 ")" = match ] && ok "is_on: a mid-line field pattern still matches" || no "is_on missed trial_rc=1"
[ "$(m "mac=11:22:33:44:55:66 slot=A ver=$V trial_rc=1 boot=1" "slot=A ")" = nomatch ] && ok "is_on: another MAC never matches" || no "is_on matched another MAC"
STATE="$A badslot=[] up=1 boot=c5faffaa"; FIP=""; find04 "slot=A " c5faffaa && no "find04: excluded boot was returned" || ok "find04: the excluded boot is skipped"
STATE="$A badslot=[] up=1 boot=c5faffaa"; find04 "slot=A " faffaa && [ "$FIP" = 10.0.0.9 ] && ok "find04: a boot id that only ends the same is not excluded" || no "find04: suffix boot id excluded [$FIP]"
unset -f ping timeout ssh sweep macips

# ---- lints (#254 v1.6 group 4 §4.3, §13.8, §15). Scope: scripts/dv, scripts/node, fault-injection.sh, ab-selftest.sh,
# negctl-old-slot-254.sh, daily-validation.sh; *.sh only; not test-*.sh, slot-guard-254.sh (the guard) nor
# gen-slot-sites.sh (the inventory's generator). A missing or empty scope is a FAIL, never a clean lint.
# Every line a lint names is also printed as "NAMED <lint> <file><TAB><text>" (text trimmed, tabs as \t): the negative
# control (test-slot-lint-negctl-254.sh) compares those with scripts/dv/data/slot-sites-converted.txt, which this test
# does not read. The allowlists below and the inventory are this checkout's ($H); the scanned tree is ROOT.
LS=(scripts/dv scripts/node scripts/fault-injection.sh scripts/ab-selftest.sh scripts/negctl-old-slot-254.sh scripts/daily-validation.sh)
for p in "${LS[@]}"; do [ -e "$ROOT/$p" ] || no "lint: scope $p missing"; done
LF=$(cd "$ROOT" && find "${LS[@]}" -name '*.sh' ! -name 'test-*.sh' ! -name slot-guard-254.sh ! -name gen-slot-sites.sh -type f 2>/dev/null | LC_ALL=C sort)
nf=$(grep -c . <<< "$LF"); [ "$nf" -ge 50 ] && ok "lint: $nf files in scope" || no "lint: only $nf files in scope"
named(){ printf 'NAMED %s %s\t%s\n' "$1" "$2" "$3"; }
# hits <ERE>: "<file><TAB><trimmed text>" for every non-comment line of the scope that matches (tabs in it as \t)
hits(){ (cd "$ROOT" && while IFS= read -r f; do
	grep -E "$1" "$f" | grep -vE '^[[:space:]]*#' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/\t/\\t/g' | awk -v f="$f" '{ print f "\t" $0 }'
done <<< "$LF"); }
# (1) every command that rolls back, commits, reboots through batman-slot or releases a trial, sent outside the guard:
# allowlisted with a reason (file | text that must be in the line | reason; the text may contain "|"), or a FAIL. Every
# entry must still match a line (a stale entry FAILs).
L1RE=$(cat <<'RE'
(batman-slot["']?|"\$BS")[[:space:]]+["']?(rollback|commit|reboot)|batman-autocommit[[:space:]]+["']?release
RE
)
ALLOW="$T/allow"; cat > "$ALLOW" <<'AL'
scripts/dv/chain1-254.sh|batman-slot rollback >> |the dead-man's own node script: slot B only, one-shot, marker + cancel check first, disarm + flag 0 required before it
scripts/dv/chain1-254.sh|batman-slot reboot committed ch1-deadman >> |the same dead-man script, after its disarm check (group 4 §4.2 row 35)
scripts/dv/prov-bench-s0-254.sh|RESULT="FAIL ($fails) — $NN is on A committed|text for a person (RESULT line)
scripts/dv/prov-wbox-nocommit-254.sh|pr_needs_person "wbox slot B committed|text for a person (NEEDS-PERSON line)
scripts/dv/prov-254.sh|pr_needs_person "the $tgt slot was committed|text for a person (NEEDS-PERSON line)
scripts/fault-injection.sh|echo "    NOTE: R1 broke runc|text for a person (NOTE line)
scripts/fault-injection.sh|HELDWHY="held for operator acceptance (batman-autocommit release)"|the product's log text the R-tests match
scripts/dv/pty-commit-254.sh|'batman-slot commit' < <(sleep 90)|the command under test (#305: a commit from a PTY; group 4 row 14)
scripts/dv/pty-commit-254.sh|say "sleep 90 | ssh -tt root@$NODE batman-slot commit"|text (the step printed)
scripts/fault-injection.sh|c2(){ echo "== C2 trial-crash-274: a manual 'batman-slot commit'|text (the test's title)
scripts/ab-selftest.sh|sshn 'batman-slot rollback' >/dev/null|the A/B self-test owns its node and its tryboot (group 4 row 16)
scripts/negctl-old-slot-254.sh|then v=\$(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build)|one-off PR evidence tool, slot checked node-side in the same command (group 4 row 17)
scripts/negctl-old-slot-254.sh|say "FAIL batman-slot rollback refused on B|text for a person
scripts/daily-validation.sh|suite pty-commit-254 "\`ssh -tt node batman-slot commit\`|text (suite description)
scripts/daily-validation.sh|c2) echo "trial-crash-274: a manual batman-slot commit|text (suite description)
scripts/node/prov-rbarm-254.sh|o=$("$BS" rollback 2>&1); rc=$?|the command under test: the rollback must be refused (group 4 row 39)
scripts/node/prov-rbarm-254.sh|do "$R/usr/sbin/batman-slot" commit >/dev/null 2>&1 && break|recovery on the running committed slot, same process, no reboot (row 40)
scripts/node/prov-rbarm-254.sh|r "FAIL-NEEDS-PERSON rc=$rc|text for a person
scripts/node/prov-rbfix-254.sh|do "$R/usr/sbin/batman-slot" commit >/dev/null 2>&1 && break|boot-bound on the node (row 41)
scripts/node/prov-p9-254.sh|on the release slot run: batman-slot commit"|text for a person
scripts/node/ble-central-254.sh|dm_disarmed || { dm_log "$1" "$DM_NOCLEAR"; mark_set dm-refused "$1"; echo "RECOVER-REFUSED $DM_NOCLEAR"; exit 3; }; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed ble-dm-254; exit 0|role deadman: the disarm check first on the line, exit 3 before any rm (group 4 §15; pinned in lint 2)
scripts/node/ble-periph-254.sh|dm_disarmed || { dm_log "$1" "$DM_NOCLEAR"; mark_set dm-refused "$1"; echo "RECOVER-REFUSED $DM_NOCLEAR"; exit 3; }; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed ble-dm-254; exit 0|role deadman (as ble-central)
scripts/node/bt-uart-305.sh|dm_disarmed || { dm_log "$1" "$DM_NOCLEAR"; mark_set dm-refused "$1"; echo "RECOVER-REFUSED $DM_NOCLEAR"; exit 3; }; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed bt305-dm; exit 0|role deadman (as ble-central)
AL
raw=$(hits "$L1RE")
[ -n "$raw" ] || no "lint (1): no slot command found in scope at all (the scan is broken)"
left=$raw
while IFS= read -r line; do
	[ -n "$line" ] || continue
	f=${line%%|*}; rest=${line#*|}; why=${rest##*|}; txt=${rest%|*}
	n=$(printf '%s\n' "$raw" | F=$f TX=$txt awk 'BEGIN { FS = "\t" } $1 == ENVIRON["F"] && index($0, ENVIRON["TX"]) > 0' | grep -c .)
	[ "$n" -ge 1 ] || { no "lint (1): allowlist entry no longer found: $f [$txt] ($why)"; named 1 "$f" "$txt"; }
	# per file: an allowlisted text hides nothing in another file (round 6 A-MINOR-1 / B-MINOR-1)
	left=$(printf '%s\n' "$left" | F=$f TX=$txt awk 'BEGIN { FS = "\t" } !($1 == ENVIRON["F"] && index($0, ENVIRON["TX"]) > 0)')
done < "$ALLOW"
left=$(printf '%s\n' "$left" | grep . || true)
if [ -z "$left" ]; then ok "lint (1): every slot command in scope is the guard or allowlisted ($(grep -c . <<< "$raw") allowlisted lines)"
else no "lint (1): slot command outside the guard: $(cut -c1-160 <<< "$left" | tr '\t\n' ': ')"; while IFS=$'\t' read -r f t; do named 1 "$f" "$t"; done <<< "$left"; fi
# (1u) #254 v1.6 g4 PR B (254-v16-ud §2): every provclient update-prepare / update-apply goes through pr_pc GUARD=: a
# non-comment line naming either op without "GUARD=" on it is a FAIL unless allowlisted below (file | text | reason);
# pr_pc refuses one at run time as well (test-prov-update-254.sh)
cat > "$T/allow1u" <<'AL'
scripts/dv/prov-254.sh|update-prepare|update-apply)|pr_pc's run-time refusal itself: the case that requires GUARD=
AL
raw=$(hits 'update-(prepare|apply)'); left=$raw
while IFS= read -r line; do
	[ -n "$line" ] || continue
	f=${line%%|*}; rest=${line#*|}; txt=${rest%|*}
	n=$(printf '%s\n' "$raw" | F=$f TX=$txt awk 'BEGIN { FS = "\t" } $1 == ENVIRON["F"] && index($0, ENVIRON["TX"]) > 0' | grep -c .)
	[ "$n" -ge 1 ] || { no "lint (1u): allowlist entry no longer found: $f [$txt]"; named 1 "$f" "$txt"; }
	left=$(printf '%s\n' "$left" | F=$f TX=$txt awk 'BEGIN { FS = "\t" } !($1 == ENVIRON["F"] && index($0, ENVIRON["TX"]) > 0)')
done < "$T/allow1u"
left=$(printf '%s\n' "$left" | grep -v 'GUARD=' | grep . || true)
if [ -z "$left" ]; then ok "lint (1u): every update-prepare / update-apply in scope carries GUARD= ($(grep -c . <<< "$raw") lines)"
else no "lint (1u): update-prepare / update-apply without GUARD=: $(cut -c1-160 <<< "$left" | tr '\t\n' ': ')"; while IFS=$'\t' read -r f t; do named 1 "$f" "$t"; done <<< "$left"; fi
# (2c) the GUARD= sites themselves, pinned with their form
printf '%s\n' 'scripts/dv/prov-update-254.sh:GUARD=apply:"$(boot8)"' 'scripts/dv/prov-update-254.sh:GUARD=prepare:"$(boot8)"' | LC_ALL=C sort > "$T/guard.want"
hits 'GUARD=(prepare|apply):' | while IFS=$'\t' read -r f c; do printf '%s\n' "$c" | grep -oE 'GUARD=(prepare|apply):[^ ]*' | sed "s#^#$f:#"; done | LC_ALL=C sort > "$T/guard.got"
d=$(diff "$T/guard.want" "$T/guard.got")
[ -z "$d" ] && ok "lint (2c): $(wc -l < "$T/guard.got") GUARD= sites, forms as pinned" || { no "lint (2c): GUARD= sites differ: $(echo "$d" | grep '^[<>]' | tr '\n' ' ')"; echo "$d" | sed -n 's/^[<>] //p' | while IFS= read -r l; do named 2 "${l%%:*}" "${l#*:}"; done; }
# (2) every guarded call site, arguments pinned (a changed slot / trial / condition / pre-action is a deliberate edit of
# this table). Any use of a guard word counts, quoted or not (round 6 A-MINOR-1: `rb_guarded $b A 1 x` was not pinned).
cat > "$T/sites.want" <<'SITES'
scripts/dv/addr-defer-reconcile-254.sh:reboot_guarded "${b0:0:8}" "$sl" 1 adr-254
scripts/dv/ble-254.sh:reboot_guarded "${b0:0:8}" "$sl" 1 ble-254
scripts/dv/brewrite-254.sh:rb_guarded "${b0:0:8}" B any e3-254
scripts/dv/bt-uart-305.sh:reboot_guarded "${b0:0:8}" "$sl" 1 "$2"
scripts/dv/chain1-254.sh:rb_guarded "$BA" A 0 ch1-b
scripts/dv/chain1-254.sh:rb_guarded "$BA" A 0 ch1-b
scripts/dv/chain1-254.sh:release_guarded "$BT" B
scripts/dv/fresh-254.sh:rb_guarded "$b" B 1 ch1-restore "[ ! -e $BASE/ch1.fired ] && [ ! -e $BASE/ch1.running ]"
scripts/dv/fresh-254.sh:reboot_guarded "$b" "$sl" 0 ch1-restore
scripts/dv/fresh-254.sh:reboot_guarded "$b" A 1 ch1-restore
scripts/dv/prov-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/prov-254.sh:reboot_guarded "$b0" A 1 prov-dv-254
scripts/dv/prov-254.sh:reboot_guarded "$b0" A 1 prov-dv-254
scripts/dv/prov-254.sh:release_guarded "$rb0" A
scripts/dv/prov-254.sh:prepare_guarded "$gb" "$cmd"
scripts/dv/prov-254.sh:apply_guarded "$gb" "$cmd"
scripts/dv/prov-update-254.sh:reboot_guarded "$b" A 1 prov-update-254
scripts/dv/prov-update-254.sh:release_guarded "$PR_LAND_BOOT" B
scripts/dv/prov-ac-fleetchan-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/prov-bench-s0-254.sh:rb_guarded "$BA" A 1 s0-slota
scripts/dv/prov-bench-s0-254.sh:reboot_guarded "$BA" A 0 s0-slota
scripts/dv/prov-bench-s0-254.sh:reboot_guarded "$BA" A 1 s0-toa2
scripts/dv/prov-bench-s0-254.sh:release_guarded "$BA" A
scripts/dv/prov-bench-s0-254.sh:release_guarded "$BT" B
scripts/dv/prov-chain0-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/prov-chain0-254.sh:reboot_guarded "$b0" B any prov-dv-254
scripts/dv/prov-legacy-upgrade-254.sh:release_guarded "$rb0" "$1" nowait
scripts/dv/prov-leave-ota-254.sh:reboot_guarded "$b0" A 1 prov-dv-254
scripts/dv/prov-lib-254.sh:reboot_guarded "${b0:0:8}" "$sl" 1 "$PL_NAME"
scripts/dv/prov-misc-254.sh:reboot_guarded "$b0" A 1 prov-dv-254
scripts/dv/prov-overlay-corrupt-254.sh:reboot_guarded "$b0" A 1 prov-dv-254
scripts/dv/prov-overlay-wipe-254.sh:reboot_guarded "$b0" A 1 prov-dv-254 - 'firstboot -y'
scripts/dv/prov-wbox-nocommit-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/pty-commit-254.sh:commit_guarded "$b" "$TGT"
scripts/fault-injection.sh:commit_guarded "${b0:0:8}" "$tr"
scripts/fault-injection.sh:reboot_guarded "${b2:0:8}" "$3" 1 p5-ap-placeholder
scripts/fault-injection.sh:reboot_guarded "${b2:0:8}" "$s" 0 p5-ap-restore
scripts/fault-injection.sh:reboot_guarded "${b:0:8}" "$sl" 1 fi-f1
scripts/fault-injection.sh:release_guarded "${HB:0:8}" "$tr"
scripts/fault-injection.sh:release_guarded "${HB:0:8}" "$tr" nowait
scripts/fault-injection.sh:release_guarded "${HB:0:8}" "$tr" nowait
scripts/fault-injection.sh:rb_guarded "${b1:0:8}" B 1 p5-back-to-A
SITES
GW='((rb|reboot|release|commit|prepare|apply)_guarded|_sg_cmd)'
hits "${GW}[[:space:]]" | while IFS=$'\t' read -r f c; do printf '%s\n' "$c" | grep -oE "${GW}[[:space:]]+[^)]*" | sed -E 's/[[:space:]]+$//; s#^#'"$f"':#'; done | LC_ALL=C sort > "$T/sites.got"
LC_ALL=C sort -o "$T/sites.want" "$T/sites.want"
d=$(diff "$T/sites.want" "$T/sites.got")
if [ -z "$d" ]; then ok "lint (2): $(wc -l < "$T/sites.got") guarded call sites, arguments as pinned"
else no "lint (2): guarded call sites differ (< pinned, > found): $(echo "$d" | grep '^[<>]' | tr '\n' ' ')"
	echo "$d" | sed -n 's/^[<>] //p' | while IFS= read -r l; do named 2 "${l%%:*}" "${l#*:}"; done; fi
# (2b) pinned lines, exact text and count: the reboot_and_wait precheck (§13.7) and the role deadmen's line (§15: the
# disarm check first, dm_log to p6, the dm-refused marker, exit 3, then the lease goes, then the reboot)
cat > "$T/lines.want" <<'LINES'
scripts/daily-validation.sh|1|local pc='r=$(vcmailbox 0x00030064 4 4 0 2>/dev/null); set -- $r; a=0; f=unread; if [ "${2:-}" = 0x80000000 ] && [ "${5:-}" = 0x80000004 ]; then case "${6:-}" in 0x[0-9a-fA-F]*) a=1; f=$(( $6 )) ;; esac; fi; soc=$(tr "\0" " " < /proc/device-tree/compatible 2>/dev/null)'
scripts/daily-validation.sh|1|local full="$pc; if [ \$a = 1 ] && [ \"\$f\" = 0 ]; then $cmd; else echo \"TRYBOOT-NOT-CLEAR answered=\$a flag=\$f soc=\$soc\"; fi"
scripts/node/ble-central-254.sh|1|dm_disarmed || { dm_log "$1" "$DM_NOCLEAR"; mark_set dm-refused "$1"; echo "RECOVER-REFUSED $DM_NOCLEAR"; exit 3; }; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed ble-dm-254; exit 0
scripts/node/ble-periph-254.sh|1|dm_disarmed || { dm_log "$1" "$DM_NOCLEAR"; mark_set dm-refused "$1"; echo "RECOVER-REFUSED $DM_NOCLEAR"; exit 3; }; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed ble-dm-254; exit 0
scripts/node/bt-uart-305.sh|1|dm_disarmed || { dm_log "$1" "$DM_NOCLEAR"; mark_set dm-refused "$1"; echo "RECOVER-REFUSED $DM_NOCLEAR"; exit 3; }; rm -f "$BT/lease" "$ST/dm" "$ST/dm.new"; batman-slot reboot committed bt305-dm; exit 0
LINES
pl=0
while IFS= read -r line; do
	f=${line%%|*}; rest=${line#*|}; c=${rest%%|*}; txt=${rest#*|}
	n=$( (cd "$ROOT" && [ -f "$f" ] && sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$f") | grep -cxF -- "$txt")
	if [ "$n" = "$c" ]; then pl=$((pl + 1)); else no "lint (2b): $f: pinned line found $n times, want $c: [${txt:0:100}…]"; named 2 "$f" "$txt"; fi
done < "$T/lines.want"
[ "$pl" = "$(grep -c . "$T/lines.want")" ] && ok "lint (2b): $pl pinned lines (reboot_and_wait precheck, role deadmen) exact"
grep -q 'TRYBOOT-NOT-CLEAR' <<< "$(sed -n '/^reboot_and_wait() {/,/echo "rebooted: boot_id/p' "$ROOT/scripts/daily-validation.sh")" \
	&& ok "lint (2b): the precheck is inside reboot_and_wait" || { no "lint (2b): no precheck inside reboot_and_wait"; }
# (3) plain reboots: every line in scope with `reboot` as a word or `sysrq-trigger` (minus comment lines) is a row of the
# inventory scripts/dv/data/slot-sites.tsv: same file, the EXACT trimmed text, the EXACT count, and a group
# (allowlisted:<reason> | prechecked | text). A hit with no row, a row with no hit, a count that differs, an unknown
# group or an empty inventory / scan FAILs. The guard words (reboot_guarded …) do not hit `\breboot\b`.
INV=$H/scripts/dv/data/slot-sites.tsv
L3RE='\breboot\b|sysrq-trigger'
if [ ! -s "$INV" ] || [ "$(grep -vc '^#' "$INV")" = 0 ]; then no "lint (3): inventory $INV missing or empty"
else
	bad=$(awk -F'\t' '!/^#/ { if (NF != 4 || $2 !~ /^[1-9][0-9]*$/ || $4 == "") print "malformed: " $0
		else if ($3 != "text" && $3 != "prechecked" && $3 !~ /^allowlisted:./) print "group: " $0
		else if ($3 == "prechecked" && !($1 == "scripts/daily-validation.sh" && (index($4, "reboot_and_wait ") || index($4, "cmd=${2:-reboot}")))) print "prechecked is only reboot_and_wait: " $0
		else if (seen[$1 FS $4]++) print "duplicate: " $0 }' "$INV")
	[ -z "$bad" ] && ok "lint (3): inventory well-formed ($(grep -vc '^#' "$INV") rows)" || no "lint (3): inventory rows: $(head -5 <<< "$bad" | cut -c1-160 | tr '\n' '|')"
	h3=$(hits "$L3RE" | LC_ALL=C sort | uniq -c | sed -E 's/^ *([0-9]+) /\1\t/')
	nh=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' <<< "$h3")
	[ "$nh" -gt 0 ] || no "lint (3): zero reboot hits in scope (the scan is broken)"
	# <kind> TAB <file> TAB <text> TAB <detail>: unlisted (a hit with no row), count, norow (a row with no hit)
	diffs=$(awk -F'\t' 'FNR == NR { if (!/^#/) { k = $1 FS $4; cnt[k] = $2; grp[k] = $3 }; next }
		{ k = $2 FS $3; seen[k] = 1
		  if (!(k in cnt)) print "unlisted\t" $2 "\t" $3 "\thit " $1 "x, no row"
		  else if (cnt[k] != $1) print "count\t" $2 "\t" $3 "\thit " $1 "x, row says " cnt[k] }
		END { for (k in cnt) if (!(k in seen)) { split(k, a, FS); print (grp[k] == "text" ? "norow-text" : "norow") "\t" a[1] "\t" a[2] "\trow (" grp[k] ") with no hit" } }' "$INV" <(printf '%s\n' "$h3"))
	if [ -z "$diffs" ]; then ok "lint (3): $nh reboot / sysrq hits in scope, every one an inventory row (exact text and count)"
	else
		no "lint (3): $(grep -c . <<< "$diffs") inventory differences: $(cut -f1,2,4 <<< "$diffs" | head -8 | tr '\t\n' ' |')"
		while IFS=$'\t' read -r k f t dd; do case "$k" in norow-text) named 3t "$f" "$t" ;; *) named 3 "$f" "$t" ;; esac; done <<< "$diffs"
	fi
fi
# (4) the field boundary: no *"slot=A / *slot=B (quoted or not), no "mac=$MAC "*"slot=. Its scope stays scripts/dv and
# fault-injection.sh, as before group 4 (negctl-old-slot-254.sh, a one-off tool outside daily-validation, has unanchored
# patterns and is not in it)
ua=$(hits '\*"?slot=[AB]|"mac=\$MAC "\*"slot=' | grep -E $'^(scripts/dv/|scripts/fault-injection\\.sh\t)')
[ -z "$ua" ] && ok "lint (4): no unanchored slot pattern" || no "lint (4): unanchored slot patterns: $(cut -c1-120 <<< "$ua" | tr '\t\n' ': ')"

echo "================ test-slot-guard: $pass passed, $fail failed ================"
[ "$fail" = 0 ]
