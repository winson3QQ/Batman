#!/bin/bash
# scripts/dv/test-slot-guard-254.sh — offline: rb_guarded (slot-guard-254.sh) against a stub batman-slot, and a lint that
# no harness script sends a raw rollback or matches the slot without the field boundary (review 2026-11-09 B-MAJOR-2).
# The incident line is the real one chain1's restore read on 04 at 14:12 on 2026-11-08.
# ROOT=<tree> lints another checkout (the negative control: ROOT=<a6104c4 export> must FAIL the lint).
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); ROOT=${ROOT:-$H}
. "$H/scripts/dv/slot-guard-254.sh"
pass=0; fail=0
ok(){ echo "ok   $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fail=$((fail + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
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
chmod +x "$T/bin/batman-slot"
# run <boot-on-node> <active> <trial-rc> <rollback-rc> -- <rb_guarded args…>: prints the output, leaves the call log in $T/log
run(){
	local nb=$1 na=$2 nt=$3 nr=$4; shift 5
	echo "$nb-0000-0000-0000-000000000000" > "$T/bootid"; : > "$T/log"
	local cmd; cmd=$(rb_guarded "$@")
	PATH="$T/bin:$PATH" RB_BOOTID="$T/bootid" STUB_LOG="$T/log" STUB_ACTIVE=$na STUB_TRIAL_RC=$nt STUB_RB_RC=$nr sh -c "$cmd"
	sleep 0.3   # the reboot is started in the background
}
rolled(){ grep -q '^rollback$' "$T/log"; }
rebooted(){ grep -q '^reboot committed' "$T/log"; }

o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 ch1-restore); [ "$o" = SENT ] && rolled && rebooted && ok "matching state: SENT, rollback + reboot" || no "matching state: [$o] $(tr '\n' ' ' < "$T/log")"
o=$(run c5faffaa A 1 0 -- c5faffaa B 1 ch1-restore); case "$o" in "WRONG-STATE boot=c5faffaa active=A trial=1") ! rolled && ok "the 2026-11-08 case (node on A, caller thought B): WRONG-STATE, no rollback" || no "rolled back on A";; *) no "node on A: [$o]";; esac
o=$(run aaaaaaaa B 1 0 -- 1201bf8a B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "another boot (read before a reboot): WRONG-STATE, no rollback" || no "rolled back in another boot";; *) no "another boot: [$o]";; esac
o=$(run 1201bf8a A 1 0 -- 1201bf8a A 0 ch1-b); case "$o" in WRONG-STATE*) ! rolled && ok "the trial already committed / fell back (want trial): WRONG-STATE" || no "rolled back a committed slot";; *) no "trial mismatch: [$o]";; esac
o=$(run 1201bf8a A 0 0 -- 1201bf8a A any x); [ "$o" = SENT ] && ok "trial any: SENT" || no "trial any: [$o]"
o=$(run 1201bf8a B 1 0 -- 1201bf8a B 1 x "[ -e $T/nonexistent ]"); case "$o" in WRONG-STATE*) ! rolled && ok "extra condition false (e.g. the dead-man running): WRONG-STATE" || no "rolled back with the extra condition false";; *) no "extra condition: [$o]";; esac
o=$(run 1201bf8a B 1 1 -- 1201bf8a B 1 x); [ "$o" = REFUSED ] && ! rebooted && ok "batman-slot refuses: REFUSED, no reboot" || no "refused rollback: [$o] $(tr '\n' ' ' < "$T/log")"
o=$(run 1201bf8a B 1 0 -- "" B 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "empty expected boot: WRONG-STATE (fail-closed)" || no "rolled back with an empty expected boot";; *) no "empty boot: [$o]";; esac
o=$(run 1201bf8a B 1 0 -- 1201bf8a C 1 x); case "$o" in WRONG-STATE*) ! rolled && ok "invalid slot argument: WRONG-STATE" || no "rolled back on an invalid slot argument";; *) no "invalid slot: [$o]";; esac

# the field boundary on the real incident line
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
# lint scope: the #254 harness (scripts/dv) and fault-injection.sh. ab-selftest.sh / negctl-old-slot-254.sh keep their
# own rollback paths (checklist on #254). A missing scope is a FAIL, never a clean lint.
LS=("$ROOT/scripts/dv" "$ROOT/scripts/fault-injection.sh")
for p in "${LS[@]}"; do [ -e "$p" ] || no "lint: scope $p missing"; done
nf=$(find "${LS[@]}" -name '*.sh' 2>/dev/null | wc -l); [ "$nf" -ge 10 ] && ok "lint: $nf files in scope" || no "lint: only $nf files in scope"
raw=$(grep -rnE "(fq|fqlong|q|qr|qp|n) +[\"']batman-slot rollback" "${LS[@]}" --include='*.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[ -z "$raw" ] && ok "lint: no raw 'batman-slot rollback' sent from the host" || no "lint: raw rollback sends: $(echo "$raw" | cut -d: -f1-2 | tr '\n' ' ')"
ua=$(grep -rnE '\*"slot=[AB]|"mac=\$MAC "\*"slot=' "${LS[@]}" --include='*.sh' | grep -v 'test-slot-guard-254.sh' || true)
[ -z "$ua" ] && ok "lint: no unanchored slot pattern" || no "lint: unanchored slot patterns: $(echo "$ua" | cut -d: -f1-2 | tr '\n' ' ')"

echo "================ test-slot-guard: $pass passed, $fail failed ================"
[ "$fail" = 0 ]
