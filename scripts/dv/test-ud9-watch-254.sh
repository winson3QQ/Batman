#!/bin/bash
# scripts/dv/test-ud9-watch-254.sh [WATCHER] — offline test of scripts/node/ud9-watch-254.sh (254-v16-ud.md §1.5, §9)
# against a stub /proc tree (UD9_TEST_ROOT): a fresh stream dd of a uid-0 `batman-slot write`, its fdinfo pos, the
# helper; stub logger / sync / ubus on PATH and a stub kill (UD9_KILL). The watcher runs under sh (dash: busybox ash
# would run its own applets instead of the PATH stubs) in a session of its own (setsid -w); busybox sh -n checks the
# node's shell parses it. Cases: no action without ud9.go; a dd older than the watcher and clear_root's dd ignored;
# timeout at the deadline; kill writes its line after the kill; cut writes FIRE and PRE-B, re-reads pos, and a late or
# unreadable p3 means no sysrq; one global sync only (before any stream); one-shot; pgid; stop; observe ok / bad.
# Prints "test-ud9-watch: N passed, M failed"; zero cases = FAIL.
set -u
H=$(cd "$(dirname "$0")/../.." && pwd); W=${1:-$H/scripts/node/ud9-watch-254.sh}
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
P=0; F=0; ok(){ echo "ok   $*"; P=$((P + 1)); }; no(){ echo "FAIL $*"; F=$((F + 1)); }
command -v busybox >/dev/null && { busybox sh -n "$W" && ok "busybox sh parses the watcher" || no "busybox sh -n $W"; }
command -v setsid >/dev/null || { no "no setsid"; echo "test-ud9-watch: $P passed, $F failed"; exit 1; }
SQ=117471808; RUNID=pupdate2541123120000; B=$T/bin; mkdir -p "$B"
cat > "$B/logger" <<'X'
#!/bin/sh
shift 2; echo "LOG $*" >> "$UD9_TEST_ROOT/trace"; [ -x "$UD9_TEST_ROOT/hook.sh" ] && "$UD9_TEST_ROOT/hook.sh" "$*"; exit 0
X
cat > "$B/sync" <<'X'
#!/bin/sh
echo SYNC >> "$UD9_TEST_ROOT/trace"
X
cat > "$B/ubus" <<'X'
#!/bin/sh
printf '{\n\t"batman-provhelper": {\n\t\t"instances": {\n\t\t\t"instance1": {\n\t\t\t\t"running": true,\n\t\t\t\t"pid": 4204,\n'
X
cat > "$B/kill" <<'X'
#!/bin/sh
echo "KILL $*" >> "$UD9_TEST_ROOT/trace"
printf 'pos:\t70000000\nflags:\t01\n' > "$UD9_TEST_ROOT/proc/5001/fdinfo/1"
( sleep 1; rm -rf "$UD9_TEST_ROOT/proc/5001" ) &
X
chmod 755 "$B"/*
stat_line(){ echo "$1 ($2) S $3 $3 $3 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 $4 0 0"; }
mkproc(){	# <dd start> <dd cmdline words…>
	local st=$1; shift; R=$T/r; rm -rf "$R"; mkdir -p "$R/proc/5001/fd" "$R/proc/5001/fdinfo" "$R/proc/5000" "$R/proc/4204" "$R/opt/batdata/log" "$R/tmp/run/batman-dv/$RUNID"
	echo "100.00 50.00" > "$R/proc/uptime"
	echo dd > "$R/proc/5001/comm"; stat_line 5001 dd 5000 "$st" > "$R/proc/5001/stat"; printf '%s\0' "$@" > "$R/proc/5001/cmdline"
	ln -s 'pipe:[4711]' "$R/proc/5001/fd/0"; ln -s /dev/mmcblk0p4 "$R/proc/5001/fd/1"; printf 'pos:\t60000000\nflags:\t01\n' > "$R/proc/5001/fdinfo/1"
	echo sh > "$R/proc/5000/comm"; stat_line 5000 sh 1 900 > "$R/proc/5000/stat"; printf 'Name:\tsh\nUid:\t0\t0\t0\t0\n' > "$R/proc/5000/status"
	printf '%s\0' /bin/sh /usr/sbin/batman-slot write /tmp/run/batman/update > "$R/proc/5000/cmdline"
	ln -s /usr/bin/batman-provhelper "$R/proc/4204/exe"; printf 'Uid:\t0\t0\t0\t0\n' > "$R/proc/4204/status"; echo batman-provhel > "$R/proc/4204/comm"
	: > "$R/trace"; touch "$R/proc/sysrq-trigger"; : > "$R/proc/sysrq-trigger"
}
STREAM=(dd of=/dev/mmcblk0p4 bs=1M conv=fsync)
go(){ touch "$R/tmp/run/batman-dv/$RUNID/ud9.go"; }
bump(){ ( sleep "${1:-2}"; echo "100000.00 50.00" > "$R/proc/uptime" ) & }
runw(){	# <mode> [nosetsid]: the watcher, waited for
	local pre=(setsid -w); [ "${2:-}" = nosetsid ] && pre=()
	env -i PATH="$B:/usr/bin:/bin" UD9_TEST_ROOT="$R" UD9_KILL="$B/kill" UD9_MYSTART=1000 timeout 60 "${pre[@]}" sh "$W" "$1" "$RUNID" "$SQ" /dev/mmcblk0p4 </dev/null >/dev/null 2>&1
	RC=$?; LOGL=$(tr -s ' ' < "$R/opt/batdata/log/dv-ud9-$RUNID.log" 2>/dev/null | sed 's/ *$//' | grep .)
}
nosync(){ [ "$(grep -c '^SYNC' "$R/trace")" = 1 ]; }
acted(){ grep -q '^KILL' "$R/trace" || [ -s "$R/proc/sysrq-trigger" ]; }

mkproc 2000 "${STREAM[@]}"; bump 2; runw cut
grep -qx 'UD9-MISS timeout (no ud9.go)' <<< "$LOGL" && ! acted && ok "no ud9.go: nothing acts, UD9-MISS timeout at the deadline" || no "no-go: [$LOGL] $(cat "$R/trace" | tr '\n' '|')"
mkproc 500 "${STREAM[@]}"; go; bump 2; runw kill
grep -qx 'UD9-MISS timeout' <<< "$LOGL" && ! acted && ok "a dd older than the watcher is ignored (UD9-MISS timeout)" || no "old dd: [$LOGL]"
mkproc 2000 dd if=/dev/zero of=/dev/mmcblk0p4 bs=1M count=8; go; bump 2; runw kill
grep -qx 'UD9-MISS timeout' <<< "$LOGL" && ! acted && ok "clear_root's dd (if=/dev/zero) is ignored" || no "clear_root dd: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; rm "$R/proc/5001/fd/0"; ln -s /dev/null "$R/proc/5001/fd/0"; go; bump 2; runw kill
grep -qx 'UD9-MISS timeout' <<< "$LOGL" && ! acted && ok "a dd whose fd 0 is not a pipe is ignored" || no "fd0: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; printf 'Uid:\t471\t471\t471\t471\n' > "$R/proc/5000/status"; go; bump 2; runw kill
grep -qx 'UD9-MISS timeout' <<< "$LOGL" && ! acted && ok "a dd whose parent is not uid 0 is ignored" || no "uid: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; go; runw kill
f=$(grep -n '' "$R/trace" | grep -E 'KILL|UD9-FIRE' | tr '\n' ' ')
if grep -qx "UD9-FIRE mode=kill pos=60000000 pos_final=70000000 sq=$SQ orphan=5000 dd=5001" <<< "$LOGL" && [ "$(grep -c . <<< "$LOGL")" = 1 ] \
	&& [ "$(grep -n 'KILL -9 4204' "$R/trace" | cut -d: -f1)" -lt "$(grep -n 'LOG UD9-FIRE' "$R/trace" | cut -d: -f1)" ] && nosync && [ ! -s "$R/proc/sysrq-trigger" ]; then
	ok "kill: SIGKILL of the helper first, then one UD9-FIRE line with pos_final (one-shot, one sync only)"
else no "kill: [$LOGL] trace [$f] syncs=$(grep -c SYNC "$R/trace")"; fi
[ "$(ls -ln "$R/opt/batdata/log/dv-ud9-$RUNID.log" | awk '{print $1, $5}')" = "-rw------- 4096" ] && ok "the log is 0600 and stays 4096 bytes (in-place writes)" || no "log: $(ls -ln "$R/opt/batdata/log/dv-ud9-$RUNID.log")"
mkproc 2000 "${STREAM[@]}"; go; rm "$R/proc/4204/exe"; ln -s /bin/sh "$R/proc/4204/exe"; runw kill
grep -q '^UD9-MISS pid 4204 is not /usr/bin/batman-provhelper' <<< "$LOGL" && ! acted && ok "kill: a pid procd names that is not the helper binary is never killed" || no "helper exe: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; go; runw cut
if grep -q "^UD9-FIRE mode=cut pos=60000000 sq=$SQ t0=10000$" <<< "$LOGL" && grep -qE '^UD9-PRE-B pos=60000000 fsync_s=[0-9]+\.[0-9]{2}$' <<< "$LOGL" \
	&& [ "$(cat "$R/proc/sysrq-trigger")" = b ] && nosync; then ok "cut: FIRE, PRE-B, then b to sysrq (no global sync after the start)"
else no "cut: [$LOGL] sysrq=[$(cat "$R/proc/sysrq-trigger")] syncs=$(grep -c SYNC "$R/trace")"; fi
# p3 is re-read after PRE-B: the hook moves pos past SQ - 8 MiB right after the PRE-B line
mkproc 2000 "${STREAM[@]}"; go
printf '#!/bin/sh\ncase "$1" in UD9-PRE-B*) printf "pos:\\t115000000\\n" > "$UD9_TEST_ROOT/proc/5001/fdinfo/1" ;; esac\n' > "$R/hook.sh"; chmod 755 "$R/hook.sh"; runw cut
grep -qx 'UD9-MISS late p3=115000000' <<< "$LOGL" && [ ! -s "$R/proc/sysrq-trigger" ] && ok "cut: p3 >= SQ - 8 MiB after PRE-B -> UD9-MISS late, no sysrq" || no "cut late: [$LOGL] sysrq=[$(cat "$R/proc/sysrq-trigger")]"
mkproc 2000 "${STREAM[@]}"; go
printf '#!/bin/sh\ncase "$1" in UD9-PRE-B*) rm -f "$UD9_TEST_ROOT/proc/5001/fdinfo/1" ;; esac\n' > "$R/hook.sh"; chmod 755 "$R/hook.sh"; runw cut
grep -qx 'UD9-MISS late p3=none' <<< "$LOGL" && [ ! -s "$R/proc/sysrq-trigger" ] && ok "cut: p3 unreadable (stream dd gone) -> UD9-MISS late p3=none, no sysrq" || no "cut p3 none: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; printf 'pos:\t112000000\n' > "$R/proc/5001/fdinfo/1"; go; runw kill
grep -qx "UD9-MISS late pos=112000000 sq=$SQ" <<< "$LOGL" && ! acted && ok "first pos already past SQ - 8 MiB -> UD9-MISS late, no kill" || no "late first: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; go; touch "$R/tmp/run/batman-dv/$RUNID/ud9.stop"; printf 'pos:\t100\n' > "$R/proc/5001/fdinfo/1"; runw cut
grep -qx 'UD9-MISS stop' <<< "$LOGL" && ! acted && ok "ud9.stop ends it without action" || no "stop: [$LOGL]"
mkproc 2000 "${STREAM[@]}"; go; runw kill nosetsid
grep -q '^UD9-MISS pgid' <<< "$LOGL" && ! acted && ok "not its own process-group leader -> UD9-MISS pgid, no action" || no "pgid: [$LOGL]"
# observe: pos grows under a background writer; fd 1 = bdev -> ok, fd 1 elsewhere -> bad
for want in ok bad; do
	mkproc 2000 "${STREAM[@]}"; go; [ $want = bad ] && { rm "$R/proc/5001/fd/1"; ln -s /dev/null "$R/proc/5001/fd/1"; }
	( i=0; while [ $i -lt 400 ]; do i=$((i + 1)); printf 'pos:\t%s\n' $((i * 1048576)) > "$R/proc/5001/fdinfo/1.t" && mv "$R/proc/5001/fdinfo/1.t" "$R/proc/5001/fdinfo/1"; sleep 0.02; done ) & wp=$!
	runw observe; kill $wp 2>/dev/null; wait $wp 2>/dev/null
	grep -qE "^UD9-OBS fd1=$([ $want = ok ] && echo /dev/mmcblk0p4 || echo /dev/null) pos=[0-9]+,[0-9]+,[0-9]+ sq=$SQ result=$want$" <<< "$LOGL" && ! acted \
		&& ok "observe: fd 1 $([ $want = ok ] && echo is || echo is not) B's root -> result=$want" || no "observe $want: [$LOGL]"
done
echo "test-ud9-watch: $P passed, $F failed"; [ $F = 0 ] && [ $P -gt 0 ]
