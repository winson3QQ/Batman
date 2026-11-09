#!/bin/bash
# scripts/dv/test-slot-guard-254.sh — offline: rb_guarded / reboot_guarded (slot-guard-254.sh) against a stub node, the
# real call sites that use them (extracted and run), and lints over the harness (review 2026-11-09 B-MAJOR-2, round 5):
#   - no `batman-slot rollback` outside the guard, except an allowlist (file + text + reason) that must all still exist;
#   - every guarded call site with its exact (boot, slot, trial, reason, condition): a changed argument FAILs;
#   - no slot match without the field boundary.
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
chmod +x "$T/bin/batman-slot" "$T/bin/cut" "$T/bin/ps"
export REALCUT REALPS; REALCUT=$(command -v cut); REALPS=$(command -v ps)
# node <boot> <active> <trial-rc> <rollback-rc>: the stub node's state for nsh
node(){ NB=$1 NA=$2 NT=$3 NR=$4; : > "$T/log"; }
nsh(){ PATH="$T/bin:$PATH" STUB_BOOT=$NB STUB_LOG="$T/log" STUB_ACTIVE=$NA STUB_TRIAL_RC=$NT STUB_RB_RC=$NR sh -c "$1"; sleep 0.3; }
run(){ local cmd; node "$1" "$2" "$3" "$4"; shift 5; cmd=$(rb_guarded "$@"); nsh "$cmd"; }
rolled(){ grep -q '^rollback$' "$T/log"; }
rebooted(){ grep -q '^reboot committed' "$T/log"; }

# ---- rb_guarded
o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 ch1-restore); [ "$o" = SENT ] && rolled && rebooted && ok "matching state: SENT, rollback + reboot" || no "matching state: [$o] $(tr '\n' ' ' < "$T/log")"
o=$(run c5faffaa A 1 0 -- c5faffaa B 1 ch1-restore); case "$o" in "WRONG-STATE boot=c5faffaa active=A trial=1") ! rolled && ok "the 2026-11-08 case (node on A, caller thought B): WRONG-STATE, no rollback" || no "rolled back on A";; *) no "node on A: [$o]";; esac
o=$(run aaaaaaaa B 1 0 -- 1201bf8a B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "another boot (read before a reboot): WRONG-STATE, no rollback" || no "rolled back in another boot";; *) no "another boot: [$o]";; esac
o=$(run 1201bf8a A 1 0 -- 1201bf8a A 0 ch1-b); case "$o" in WRONG-STATE*) ! rolled && ok "the trial already committed / fell back (want trial): WRONG-STATE" || no "rolled back a committed slot";; *) no "trial mismatch: [$o]";; esac
o=$(run 1201bf8a A 0 0 -- 1201bf8a A any x); [ "$o" = SENT ] && ok "trial any: SENT" || no "trial any: [$o]"
o=$(run 1201bf8a B 2 0 -- 1201bf8a B 1 x); case "$o" in *" trial=2") ! rolled && ok "is-trial rc 2 (unknown) is not 'committed': WRONG-STATE" || no "rolled back on rc 2";; *) no "rc 2: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 x "[ -e $T/nonexistent ]"); case "$o" in WRONG-STATE*) ! rolled && ok "extra condition false (e.g. the dead-man acting): WRONG-STATE" || no "rolled back with the extra condition false";; *) no "extra condition: [$o]";; esac
o=$(run 1201bf8a B 1 1 -- 1201bf8a B 1 x); [ "$o" = REFUSED ] && ! rebooted && ok "batman-slot refuses: REFUSED, no reboot" || no "refused rollback: [$o] $(tr '\n' ' ' < "$T/log")"
o=$(run 1201bf8a B 1 0 -- "" B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "empty expected boot: WRONG-STATE (fail-closed)" || no "rolled back with an empty expected boot";; *) no "empty boot: [$o]";; esac
o=$(run "" B 1 0 -- "" B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "node boot id unreadable + empty expected boot: WRONG-STATE" || no "rolled back with no boot id on either side";; *) no "unreadable boot: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- 1201bf8a C 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "invalid slot argument: WRONG-STATE" || no "rolled back on an invalid slot argument";; *) no "invalid slot: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- "1201bf8a' ] || touch $T/PWN; [ 'x" B 1 x); case "$o" in WRONG-STATE*) [ ! -e "$T/PWN" ] && ! rolled && ok "a boot argument carrying shell is not run, never matches (round 5 B-MINOR-3)" || no "boot argument ran shell / rolled back";; *) no "boot injection: [$o] pwn=$([ -e "$T/PWN" ] && echo y)";; esac
o=$(run 1201bf8a B 1 0 -- 1201BF8A B 1 x); case "$o" in WRONG-STATE*) ok "boot argument: 8 lower-case hex only";; *) no "upper-case boot: [$o]";; esac
# ---- reboot_guarded: never a rollback
node 1201bf8a A 0 0; o=$(nsh "$(reboot_guarded 1201bf8a A 0 s0-slota)"); [ "$o" = SENT ] && rebooted && ! rolled && ok "reboot_guarded: SENT, reboot only" || no "reboot_guarded: [$o] $(tr '\n' ' ' < "$T/log")"
node 1201bf8a A 1 0; o=$(nsh "$(reboot_guarded 1201bf8a A 0 s0-slota)"); case "$o" in WRONG-STATE*) ! rebooted && ok "reboot_guarded: committed, want trial: nothing" || no "reboot_guarded rebooted a committed slot";; *) no "reboot_guarded mismatch: [$o]";; esac

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
	unset -f back_to_a bid say waitboot settle ssh q timeout
else no "back_to_a not found in $ROOT/scripts/dv/brewrite-254.sh"; fi
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
	eval "dm=\"$dmraw\""; printf '%s\n' "$dm" > "$BASE/ch1-deadman.sh"
	dmrun(){ rm -rf "$BASE/ch1.running" "$BASE/ch1.fired" "$BASE/ch1.cancel"; node 1201bf8a B 1 0; for f; do case "$f" in run) mkdir "$BASE/ch1.running";; *) : > "$BASE/ch1.$f";; esac; done; nsh "sh $BASE/ch1-deadman.sh" >/dev/null 2>&1; }
	dmrun; rolled && [ -d "$BASE/ch1.running" ] && [ -e "$BASE/ch1.fired" ] && ok "dead-man acts: ch1.running made, rollback, ch1.fired" || no "dead-man normal run: running=$([ -d "$BASE/ch1.running" ] && echo y) $(tr '\n' ' ' < "$T/log")"
	dmrun cancel; ! rolled && [ ! -e "$BASE/ch1.running" ] && ok "dead-man cancelled: nothing, no marker left" || no "dead-man ignored ch1.cancel / left a marker"
	dmrun run; ! rolled && ok "dead-man: a second instance (ch1.running exists) does nothing" || no "dead-man ran twice"
else no "dead-man script not found in $ROOT/scripts/dv/chain1-254.sh"; fi
unset -f fq

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

# ---- lints. Scope: the #254 harness (scripts/dv) and fault-injection.sh. ab-selftest.sh / negctl-old-slot-254.sh keep
# their own rollback paths (checklist on #254). A missing scope is a FAIL, never a clean lint.
LS=("$ROOT/scripts/dv" "$ROOT/scripts/fault-injection.sh")
for p in "${LS[@]}"; do [ -e "$p" ] || no "lint: scope $p missing"; done
nf=$(find "${LS[@]}" -name '*.sh' 2>/dev/null | wc -l); [ "$nf" -ge 10 ] && ok "lint: $nf files in scope" || no "lint: only $nf files in scope"
rel(){ sed "s#^$ROOT/##"; }
nocomment(){ grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'; }
# (1) any `batman-slot rollback` (any quoting, any position) outside the guard and this test, minus the allowlist
ALLOW="$T/allow"; cat > "$ALLOW" <<'AL'
scripts/dv/chain1-254.sh|batman-slot rollback >> |the dead-man's own node script: slot B only, one-shot, marker + cancel check first
scripts/dv/prov-bench-s0-254.sh|RESULT="FAIL ($fails) — $NN is on A committed|text for a person (RESULT line)
scripts/dv/prov-wbox-nocommit-254.sh|pr_needs_person "wbox slot B committed|text for a person (NEEDS-PERSON line)
scripts/dv/prov-254.sh|pr_needs_person "the $tgt slot was committed|text for a person (NEEDS-PERSON line)
scripts/fault-injection.sh|echo "    NOTE: R1 broke runc|text for a person (NOTE line)
AL
raw=$(grep -rnE "batman-slot[[:space:]]+[\"']?rollback" "${LS[@]}" --include='*.sh' | rel | nocomment | grep -vE '^scripts/dv/(slot-guard-254|test-slot-guard-254)\.sh:' || true)
left=$raw
while IFS='|' read -r f txt why; do
	n=$(printf '%s\n' "$raw" | grep "^$f:" | grep -cF -- "$txt")
	[ "$n" -ge 1 ] || no "lint: allowlist entry no longer found: $f [$txt] ($why)"
	left=$(printf '%s\n' "$left" | grep -vF -- "$txt" || true)
done < "$ALLOW"
left=$(printf '%s\n' "$left" | grep . || true)
[ -z "$left" ] && ok "lint: every 'batman-slot rollback' in scope is the guard or allowlisted ($(printf '%s\n' "$raw" | grep -c .) allowlisted lines)" || no "lint: unguarded rollback: $(echo "$left" | cut -d: -f1-2 | tr '\n' ' ')"
# (2) every guarded call site, arguments pinned (a changed slot / trial / condition is a deliberate edit of this table)
cat > "$T/sites.want" <<'SITES'
scripts/dv/brewrite-254.sh:rb_guarded "${b0:0:8}" B any e3-254
scripts/dv/chain1-254.sh:rb_guarded "$BA" A 0 ch1-b
scripts/dv/chain1-254.sh:rb_guarded "$BA" A 0 ch1-b
scripts/dv/fresh-254.sh:rb_guarded "$b" B 1 ch1-restore "[ ! -e $BASE/ch1.fired ] && [ ! -e $BASE/ch1.running ]"
scripts/dv/prov-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/prov-ac-fleetchan-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/prov-bench-s0-254.sh:rb_guarded "$BA" A 1 s0-slota
scripts/dv/prov-bench-s0-254.sh:reboot_guarded "$BA" A 0 s0-slota
scripts/dv/prov-bench-s0-254.sh:reboot_guarded "$BA" A 1 s0-toa2
scripts/dv/prov-chain0-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/dv/prov-chain0-254.sh:reboot_guarded "$b0" B any prov-dv-254
scripts/dv/prov-wbox-nocommit-254.sh:rb_guarded "$b0" B any prov-dv-254
scripts/fault-injection.sh:rb_guarded "${b1:0:8}" B 1 p5-back-to-A
SITES
grep -roE '(rb|reboot)_guarded "[^"]*" [^ ]+ [^ ]+ [^ ")]+( "[^"]*")?' "${LS[@]}" --include='*.sh' | rel | grep -vE '^scripts/dv/(slot-guard-254|test-slot-guard-254)\.sh:' | sort > "$T/sites.got"
sort -o "$T/sites.want" "$T/sites.want"
d=$(diff "$T/sites.want" "$T/sites.got")
[ -z "$d" ] && ok "lint: $(wc -l < "$T/sites.got") guarded call sites, arguments as pinned" || no "lint: guarded call sites differ (< pinned, > found): $(echo "$d" | grep '^[<>]' | tr '\n' ' ')"
# (3) the field boundary: no *"slot=A / *slot=B (quoted or not), no "mac=$MAC "*"slot=
ua=$(grep -rnE '\*"?slot=[AB]|"mac=\$MAC "\*"slot=' "${LS[@]}" --include='*.sh' | rel | grep -v '^scripts/dv/test-slot-guard-254.sh:' || true)
[ -z "$ua" ] && ok "lint: no unanchored slot pattern" || no "lint: unanchored slot patterns: $(echo "$ua" | cut -d: -f1-2 | tr '\n' ' ')"

echo "================ test-slot-guard: $pass passed, $fail failed ================"
[ "$fail" = 0 ]
