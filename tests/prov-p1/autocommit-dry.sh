#!/bin/bash
# tests/prov-p1/autocommit-dry.sh <batman-autocommit> <lib dir> — #254 L96 (docs/design/254-v16-group1.md §3): a dry run
# (AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1) writes nothing real: no run-dir file outside
# autocommit.dry.d / autocommit.dry.lock is created or removed, p6 state (ota-armed.mesh) is untouched, no OTA trace
# line; two dry runs in a row both reach the watchdog's REVERT decision; a second dry run while one runs exits 1; a
# planted symlink autocommit.dry.d is removed as a link (its target untouched).
# The REAL script runs (sh) with its fixed paths (/tmp/run/batman, /opt/batdata, /usr/lib/batman) moved into a sandbox
# by sed, nothing else changed; batman-slot, logger, pgrep… are stubs. No root, no node.
# Nothing checked = FAIL. Negative control: main 4b61b3c -> FAIL (real autocommit.decided / wd made, ota-armed.mesh
# removed, an otalog line, the second run's watchdog exits silently).
set -u
AC=$(readlink -f "${1:?usage: $0 <batman-autocommit> <lib dir>}"); LIB=$(readlink -f "${2:?}")
[ -f "$AC" ] && [ -d "$LIB" ] || { echo "FAIL missing $AC or $LIB"; exit 1; }
T=$(mktemp -d) || { echo "FAIL mktemp"; exit 1; }; trap 'rm -rf "$T"' EXIT
fails=0; cases=0
ok(){ echo "ok   $*"; cases=$((cases+1)); }; no(){ echo "FAIL $*"; cases=$((cases+1)); fails=$((fails+1)); }
mkdir -p "$T/run" "$T/opt/batdata/state" "$T/opt/batdata/log" "$T/lib" "$T/bin"; chmod 755 "$T/run"
# the real files with their fixed paths moved into the sandbox (nothing else changed)
for f in rundir.sh meshjoin.sh; do
	[ -f "$LIB/$f" ] || { echo "FAIL $LIB/$f missing"; exit 1; }
	sed -e "s#/tmp/run/batman#$T/run/batman#g" -e "s#/opt/batdata#$T/opt/batdata#g" "$LIB/$f" > "$T/lib/$f"
done
# otatrace: a recorder (the real one writes only with p6 mounted) — any otalog / otalog_k call is a line in $T/otalog
printf 'otalog(){ echo "$*" >> %s/otalog; }
otalog_k(){ otalog "$@"; }
ota_get(){ :; }
ota_thr(){ :; }
' "$T" > "$T/lib/otatrace.sh"
# named as on a node: dry_alive / pid_is match the cmdline "batman-autocommit"
mkdir -p "$T/sbin"; sed -e "s#/usr/lib/batman#$T/lib#g" -e "s#/opt/batdata#$T/opt/batdata#g" -e "s#/tmp/run/batman#$T/run/batman#g" "$AC" > "$T/sbin/batman-autocommit"
AC=$T/sbin/batman-autocommit
# stubs
for c in logger pgrep pidof docker nft hexdump; do printf '#!/bin/sh\nexit 1\n' > "$T/bin/$c"; done
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
cat > "$T/bin/batman-slot" <<'STUB'
#!/bin/sh
case "$1" in active) echo B ;; is-trial) exit 0 ;; *) exit 0 ;; esac
STUB
chmod 755 "$T"/bin/*
export PATH="$T/bin:$PATH"
ST=$T/opt/batdata/state; echo "bootx B radio" > "$ST/ota-armed.mesh"
. "$T/lib/rundir.sh"; batman_rundir || { echo "FAIL the scratch run dir is not usable"; exit 1; }
snap(){ { (cd "$RUNDIR" && find . -mindepth 1 -maxdepth 1 ! -name autocommit.dry.d ! -name autocommit.dry.lock ! -name autocommit-dryrun.log | sort); echo ---; (cd "$T/opt/batdata" && find . | sort); md5sum "$ST/ota-armed.mesh"; } 2>/dev/null; }
# AD_SH: the shell (CI runs dash and busybox sh — the node's; code review A m4 / B m7)
SH=${AD_SH:-sh}
dry(){ AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1 timeout 240 $SH "$AC" run 2>&1; }
b=$(snap)
o1=$(dry); a1=$(snap)
grep -q 'DRYRUN decision: REVERT' <<< "$o1" && ok "dry run 1 reached the watchdog's REVERT decision" || no "dry run 1: no REVERT decision [$(tail -3 <<< "$o1" | tr '\n' ' ')]"
[ "$a1" = "$b" ] && ok "dry run 1 changed nothing real (run dir outside dry.d, p6)" || no "dry run 1 changed real state: $(diff <(echo "$b") <(echo "$a1") | grep '^[<>]' | tr '\n' ' ')"
[ -f "$ST/ota-armed.mesh" ] && ok "ota-armed.mesh kept" || no "ota-armed.mesh removed"
n=$(grep -c . "$T/otalog" 2>/dev/null); n=${n:-0}
[ "$n" = 0 ] && ok "no OTA trace line" || no "$n OTA trace line(s): $(head -2 "$T/otalog" | tr '
' ' ')"
o2=$(dry); a2=$(snap)
grep -q 'DRYRUN decision: REVERT' <<< "$o2" && ok "dry run 2 (same boot) also reached REVERT" || no "dry run 2: no REVERT decision (a leftover marker from run 1?) [$(tail -3 <<< "$o2" | tr '\n' ' ')]"
[ "$a2" = "$b" ] && ok "dry run 2 changed nothing real" || no "dry run 2 changed real state"
# a second dry run while one runs
( AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$(( $(cut -d. -f1 /proc/uptime) + 20 )) timeout 240 $SH "$AC" run > "$T/bg.out" 2>&1 ) & bp=$!   # the deadline is an uptime: alive ~20 s
for _ in $(seq 1 50); do [ -s "$RUNDIR/autocommit.dry.lock/pids" ] && break; sleep 0.1; done
o3=$(AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=1 timeout 30 $SH "$AC" run 2>&1); r3=$?
[ $r3 = 1 ] && grep -q 'another dry run is running' <<< "$o3" && ok "a concurrent dry run exits 1" || no "concurrent dry run: rc=$r3 [$o3]"
wait $bp
grep -q 'DRYRUN decision: REVERT' "$T/bg.out" && ok "the first of the two still reached REVERT" || no "the background dry run did not finish [$(tail -2 "$T/bg.out" | tr '\n' ' ')]"
[ ! -e "$RUNDIR/autocommit.dry.lock" ] && ok "the lock is gone after the runs" || no "the lock stayed: $(cat "$RUNDIR/autocommit.dry.lock/pids" 2>/dev/null)"
# a dry run killed with TERM (the harness's `kill $p`) leaves no lock behind (code review A m3 / B m3)
AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 AUTOCOMMIT_TIMEOUT=$(( $(cut -d. -f1 /proc/uptime) + 60 )) $SH "$AC" run > "$T/kill.out" 2>&1 & kp=$!
for _ in $(seq 1 50); do [ -s "$RUNDIR/autocommit.dry.lock/pids" ] && break; sleep 0.1; done
sleep 1; kill -TERM $kp; wait $kp 2>/dev/null
for _ in $(seq 1 50); do [ -e "$RUNDIR/autocommit.dry.lock" ] || break; sleep 0.1; done
[ ! -e "$RUNDIR/autocommit.dry.lock" ] && ok "a dry run killed with TERM removed its lock" || no "TERM left the lock: $(cat "$RUNDIR/autocommit.dry.lock/pids" 2>/dev/null)"
o5=$(dry); grep -q 'DRYRUN decision: REVERT' <<< "$o5" && ok "the next dry run is not blocked" || no "the next dry run after a TERM: [$(tail -2 <<< "$o5" | tr '\n' ' ')]"
# a planted symlink in place of the dry dir
mkdir -p "$T/target"; : > "$T/target/keep"; rm -rf "$RUNDIR/autocommit.dry.d"; ln -s "$T/target" "$RUNDIR/autocommit.dry.d"
dry > /dev/null
[ -f "$T/target/keep" ] && [ -d "$RUNDIR/autocommit.dry.d" ] && [ ! -L "$RUNDIR/autocommit.dry.d" ] && ok "planted symlink removed as a link, target untouched" || no "planted symlink: target keep=$([ -f "$T/target/keep" ] && echo yes || echo no) dir=$(ls -ld "$RUNDIR/autocommit.dry.d" 2>&1)"
echo "AUTOCOMMIT-DRY cases=$cases fails=$fails"
[ $cases -gt 0 ] && [ $fails = 0 ]
