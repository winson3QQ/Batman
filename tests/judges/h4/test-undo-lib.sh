#!/bin/bash
# tests/judges/h4/test-undo-lib.sh — offline test of scripts/node/prov-undo-lib-254.sh (254-h4 §5.7), in WSL.
# The real lib (with the real ble-lib-254.sh) runs under busybox sh in a user + mount namespace: tmpfs over /tmp/run and
# /opt, so the lib's own paths (/tmp/run/batman-dv/…, /opt/batdata/…) are used as on the node and files are "root".
# Stubbed: batman-slot, uci / nft / ip (PATH), segment 1's node parts (useg1: tested on 04 by test-h4-undo.sh).
# Each case breaks one property; the negative controls run a deliberately broken copy of the lib and must FAIL.
#   bash tests/judges/h4/test-undo-lib.sh          -> "N PASS / M FAIL", rc 1 on any FAIL
set -u
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
BB=$(command -v busybox) || { echo "FAIL no busybox"; exit 1; }
if [ "${UNDO_T_INNER:-0}" != 1 ]; then
	# real root (daily-validation's WSL delegation): a private mount namespace is enough, and a user namespace would
	# lose DAC override on the repo owner's 0750 home ("Permission denied", 2026-11-03 full run)
	[ "$(id -u)" = 0 ] && exec unshare --mount --propagation private env UNDO_T_INNER=1 bash "$0" "$@"
	exec unshare --user --map-root-user --mount env UNDO_T_INNER=1 bash "$0" "$@"
fi
mount -t tmpfs -o mode=755 none /tmp || { echo "FAIL tmpfs over /tmp"; exit 1; }; mkdir -p /tmp/run; mount -t tmpfs -o mode=755 none /opt || { echo "FAIL tmpfs over /opt"; exit 1; }
mkdir -p /opt/batdata/log /opt/batdata/state; chmod 755 /opt/batdata/log
W=$(mktemp -d /tmp/ut.XXXXXX); mkdir "$W/bin"
cat > "$W/bin/batman-slot" <<'X'
#!/bin/sh
[ "$1" = active ] && cat /tmp/ut.slot
X
cat > "$W/bin/uci" <<'X'
#!/bin/sh
# tiny uci: one file per package in /tmp/ut.uci/<pkg>; export = cat, import = copy stdin to staging, commit = move
d=/tmp/ut.uci; mkdir -p $d; [ "$1" = -q ] && shift
case "$1" in
export) cat "$d/$2" ;; import) cat > "$d/$2.staged" ;; commit) [ -f "$d/$2.staged" ] && mv "$d/$2.staged" "$d/$2"; true ;;
revert) rm -f "$d/$2.staged" "$d/$2.changes" ;; changes) cat "$d/$2.changes" 2>/dev/null ;; *) exit 1 ;; esac
X
chmod 755 "$W/bin/"*
pass=0; fails=0
ok(){ echo "PASS $*"; pass=$((pass + 1)); }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }

# run <lib> <script>: a fresh busybox sh with ble-lib + the given undo lib sourced, useg1 stubbed (prints SEG1)
run() {
	PATH="$W/bin:$PATH" DIR="$W" "$BB" sh -c '
		. "$1"; . "$2"; scratch
		useg1() { echo "SEG1 $1" >> /tmp/ut.trace; }
		provd_present() { return 1; }
		eval "$3"' sh "$REPO/scripts/node/ble-lib-254.sh" "$1" "$2"
}
LIB=$REPO/scripts/node/prov-undo-lib-254.sh
reset() { rm -rf /tmp/run/batman-dv /opt/batdata/state/dv-undo /opt/batdata/log/dv-undo-* /tmp/ut.uci /tmp/ut.trace; echo A > /tmp/ut.slot; }
count() { local c; c=$(grep -c "$1" /tmp/run/batman-dv/undo-test/r1.count 2>/dev/null); echo "${c:-0}"; }

# 1. undo-add: where / bind / ids; uci-restore writes its backup on p6 first
reset; mkdir -p /tmp/ut.uci; printf "config x 'y'\n\toption a '1'\n" > /tmp/ut.uci/undotest
o=$(run "$LIB" 'undo_add r1 test-count a; undo_add r1 uci-restore undotest; undo_add r1 kill-pg 4242 h4tag; undo_add r1 p5-save')
grep -q '^UNDO-ADDED 1 tmp - test-count a$' <<< "$o" && grep -q '^UNDO-ADDED 2 p6 slot:A uci-restore undotest /opt/batdata/state/dv-undo/r1/uci.undotest.2$' <<< "$o" \
	&& grep -q '^UNDO-ADDED 3 tmp boot:' <<< "$o" && grep -q '^UNDO-ADDED 4 p6 - p5-save$' <<< "$o" \
	&& cmp -s /tmp/ut.uci/undotest /opt/batdata/state/dv-undo/r1/uci.undotest.2 \
	&& [ "$(ls -ln /opt/batdata/state/dv-undo/r1/journal | awk '{print $1}')" = -rw------- ] \
	&& [ "$(ls -ldn /tmp/run/batman-dv/undo/r1 | awk '{print $1}')" = drwx------ ] \
	&& ok "undo-add: journal / bind / ids / backup / modes" || no "undo-add: $o"

# 2. closed list and arguments refused at add time
reset
o=$(run "$LIB" 'for a in "rm-file /etc/passwd" "rm-file /tmp/run/batman-dv/../../etc/passwd" "link-del eth0" "netns-del init" "nft-del-table inet fw4" "uci-revert A;b" "kill-pg 1 x" "kill-pg -5 x" "ap-restore" "pending-del" "frobnicate" "svc-start ../../bin/sh"; do undo_add r1 $a >/dev/null && echo "ACCEPTED $a"; done; echo end')
[ "$o" = end ] && [ ! -e /tmp/run/batman-dv/undo/r1/journal ] && ok "undo-add refuses 12 bad lines (closed list, paths, devs, fw4, pgid 1, P3-only actions)" || no "undo-add accepted: $o"

# 3. segment 2: newest first, each exactly once, done marked, journal dirs removed at the end; segment 1 first
reset
o=$(run "$LIB" 'undo_add r1 test-count a; undo_add r1 test-count b; undo_add r1 test-count c; undo_run r1 deadman; echo "rc=$?"')
seq=$(awk '{print $2}' /tmp/run/batman-dv/undo-test/r1.count | tr '\n' ' ')
[ "$seq" = "c b a " ] && grep -q 'rc=0' <<< "$o" && [ ! -e /tmp/run/batman-dv/undo/r1 ] && grep -q 'SEG1 r1' /tmp/ut.trace \
	&& ok "segment 2 runs newest first, once each, removes the journal: [$seq]" || no "segment 2: [$seq] $o"

# 4. a line that fails stays todo (rc 1); a re-run only redoes it; the others are not run again
reset
o=$(run "$LIB" 'undo_add r1 test-count a; undo_add r1 test-count b fail; undo_run r1 host; echo "rc1=$?"; undo_run r1 deadman; echo "rc2=$?"')
[ "$(count ' a$')" = 1 ] && [ "$(count ' b$')" = 2 ] && grep -q rc1=1 <<< "$o" && grep -q rc2=1 <<< "$o" \
	&& grep -q '^2 todo - test-count b fail$' /tmp/run/batman-dv/undo/r1/journal && grep -q '^1 done ' /tmp/run/batman-dv/undo/r1/journal \
	&& ok "a failed action stays todo, re-entry skips done ones (a once, b twice)" || no "re-entry: a=$(count ' a$') b=$(count ' b$') $o"

# 5. a tampered line (rm-file /etc/passwd written straight into the journal) = CRIT, skipped, the file stays
reset; mkdir -p /tmp/ut.etc; echo root > /tmp/ut.etc/passwd
run "$LIB" 'undo_add r1 test-count a' >/dev/null
echo "9 todo - rm-file /tmp/ut.etc/passwd" >> /tmp/run/batman-dv/undo/r1/journal
o=$(run "$LIB" 'undo_run r1 deadman; echo "rc=$?"')
[ -f /tmp/ut.etc/passwd ] && grep -q 'CRIT line 9 refused: rm-file /tmp/ut.etc/passwd' <<< "$o" && grep -q rc=1 <<< "$o" \
	&& grep -q '^9 todo ' /tmp/run/batman-dv/undo/r1/journal && [ "$(count ' a$')" = 1 ] \
	&& ok "a tampered rm-file line is CRIT, the file stays, the line stays for P9" || no "tampered line: $o"

# 5n. negative control: a lib that does not re-validate at run time deletes the file
reset; echo root > /tmp/ut.etc/passwd; NEG5=$W/undo-noval.sh
sed 's/^\t\t\tuvalid "\$_ur" "\$@" || { ulog "\$_ur" "CRIT line/\t\t\ttrue || { ulog "$_ur" "CRIT line/' "$LIB" > "$NEG5"
grep -q '^			true || { ulog' "$NEG5" || no "negative control 5n: the edit did not apply"
run "$NEG5" 'undo_add r1 test-count a' >/dev/null
echo "9 todo - rm-file /tmp/ut.etc/passwd" >> /tmp/run/batman-dv/undo/r1/journal
run "$NEG5" 'undo_run r1 deadman' >/dev/null
[ -f /tmp/ut.etc/passwd ] && no "negative control 5n: the unvalidated lib left the file (the case proves nothing)" || ok "negative control: without run-time validation the tampered line deletes the file"

# 6. slot binding: a p6 line registered on A is not run on B (NEEDS-PERSON), runs once back on A
reset; mkdir -p /tmp/ut.uci; echo "orig" > /tmp/ut.uci/undotest
run "$LIB" 'undo_add r1 uci-restore undotest' >/dev/null; echo "changed" > /tmp/ut.uci/undotest; echo B > /tmp/ut.slot
o=$(run "$LIB" 'undo_run r1 deadman; echo "rc=$?"')
b=$(cat /tmp/ut.uci/undotest); echo A > /tmp/ut.slot
o2=$(run "$LIB" 'undo_run r1 deadman; echo "rc=$?"')
[ "$b" = changed ] && grep -q 'NEEDS-PERSON line 1 (uci-restore undotest .*) is bound to slot:A, running B' <<< "$o" && grep -q rc=1 <<< "$o" \
	&& [ "$(cat /tmp/ut.uci/undotest)" = orig ] && grep -q rc=0 <<< "$o2" && [ ! -e /opt/batdata/state/dv-undo/r1 ] \
	&& ok "slot-bound line: left on the other slot, restored on its own" || no "slot binding: [$b] $o / $o2"

# 7. a boot-bound line from an earlier boot is void (done, not run)
reset
run "$LIB" 'undo_add r1 test-count a' >/dev/null
echo "5 todo boot:00000000-dead-beef-0000-000000000000 test-count z" >> /tmp/run/batman-dv/undo/r1/journal
o=$(run "$LIB" 'undo_run r1 deadman; echo "rc=$?"')
[ "$(count ' z$')" = 0 ] && grep -q 'line 5 (test-count z): another boot, void' <<< "$o" && grep -q rc=0 <<< "$o" \
	&& ok "boot-bound line of another boot is void" || no "boot void: $o"

# 8. restoring marker: segment 1 only, the journal stays
reset
run "$LIB" 'undo_add r1 test-count a' >/dev/null; touch /tmp/run/batman-dv/bt/restoring.r1
o=$(run "$LIB" 'undo_run r1 deadman; echo "rc=$?"')
[ "$(count ' a$')" = 0 ] && grep -q 'restoring marker: segment 2 left to pr_restore' <<< "$o" && grep -q 'SEG1 r1' /tmp/ut.trace \
	&& grep -q '^1 todo ' /tmp/run/batman-dv/undo/r1/journal && ok "restoring: segment 1 only" || no "restoring: $o"

# 9. stuck host executor: deadman STOPs it, waits for its tool, TERMs + CONTs its group, then does both segments;
#    every other action exactly once
stuck_case() {	# <lib> -> prints a verdict line
	reset
	run "$1" 'undo_add r1 test-count a; undo_add r1 test-count b stall; undo_add r1 test-count c' >/dev/null
	# the host executor: a process whose cmdline names "prov-lease-254.sh undo" (its own session = group)
	cat > "$W/prov-lease-254.sh" <<X
. "$REPO/scripts/node/ble-lib-254.sh"; . "$1"; scratch
useg1() { echo "SEG1 \$1" >> /tmp/ut.trace; }; provd_present() { return 1; }
undo_run r1 host
X
	PATH="$W/bin:$PATH" DIR="$W" setsid "$BB" sh "$W/prov-lease-254.sh" undo </dev/null >/dev/null 2>&1 &
	n=0; while [ $n -lt 50 ] && [ "$(count 'host b$')" = 0 ]; do sleep 0.2; n=$((n + 1)); done
	hp=$(awk '{print $1}' /tmp/run/batman-dv/bt/undo-doing.r1 2>/dev/null); hg=$(awk '{print $2}' /tmp/run/batman-dv/bt/undo-doing.r1 2>/dev/null)
	o=$(UNDO_KID_WAIT=3 run "$1" 'undo_run r1 deadman; echo "rc=$?"')
	sleep 1; alive=0; for s in /proc/[0-9]*/stat; do [ "$(cut -d' ' -f5 "$s" 2>/dev/null)" = "$hg" ] && alive=1; done
	echo "a=$(count ' a$') b=$(count ' b$') c=$(count ' c$') alive=$alive hp=$hp $(grep -o 'rc=[0-9]' <<< "$o" | tail -1) doing=$([ -e /tmp/run/batman-dv/bt/undo-doing.r1 ] && echo 1 || echo 0) gone=$(grep -c "host executor group $hg gone" <<< "$o")"
}
v=$(stuck_case "$LIB")
case "$v" in "a=1 b=2 c=1 alive=0 hp="[0-9]*" rc=0 doing=0 gone=1") ok "stuck host: killed, both segments done, a/c once ($v)" ;; *) no "stuck host: $v" ;; esac

# 9n. negative control: the v5 rule (deadman leaves segment 2 to the stuck host: no stop, segment 1 only) -> FAIL
NEG=$W/undo-v5.sh
sed 's/^\telif ! ustop_host "\$_ur"; then$/\telif [ -f "$BT\/undo-doing.$_ur" ]; then/' "$LIB" > "$NEG"
grep -q 'elif \[ -f "$BT/undo-doing.$_ur" \]; then' "$NEG" || no "negative control: the v5 edit did not apply"
v=$(stuck_case "$NEG")
case "$v" in "a=1 b=2 c=1 "*) no "negative control (v5 rule) passed too: $v" ;; *) ok "negative control: the v5 rule leaves segment 2 undone ($v)" ;; esac
pkill -f "$W/prov-lease-254.sh" 2>/dev/null

# 10. host stopper refuses a bogus pgid (1 / own group) and does not kill anything
reset; mkdir -p /tmp/run/batman-dv/bt; echo "$$ 1 $(cat /proc/sys/kernel/random/boot_id)" > /tmp/run/batman-dv/bt/undo-doing.r1
o=$(run "$LIB" 'ustop_host r1; echo "rc=$?"')
grep -q rc=0 <<< "$o" && ok "doing record of a process that is not an executor: dropped, nothing killed" || no "bogus doing: $o"

echo "$pass PASS / $fails FAIL"; [ $fails = 0 ]
