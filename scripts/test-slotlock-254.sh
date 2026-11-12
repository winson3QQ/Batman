#!/bin/bash
# scripts/test-slotlock-254.sh — offline test of the harness's #254 S5 slot-flock helpers (scripts/node/slotlock-lib-254.sh,
# scripts/lib/slotlock-254.sh) under busybox ash (the node's shell; util-linux flock stands in for busybox's applet when
# the host busybox has none) and dash. No node. Cases:
#   take: no rundir.sh -> nothing taken, the rest runs; batman_rundir fails -> SLOTLK-BUSY, the shell goes on (no exit);
#         the lock file cannot be opened -> SLOTLK-BUSY, the shell goes on; lock held elsewhere -> after SLK_TRIES:
#         by an orphan -> "SLOTLK-BUSY LEAK", by a batman-slot or another harness holder -> plain SLOTLK-BUSY;
#         free -> held on fd 9 until the shell exits (a second taker is refused meanwhile)
#   free: ok; nofile; a verb's child that kept fd 9 -> leak (the negative control of every "lock released" check);
#         a holder from outside: an orphan (no batman-slot among its ancestors, not the harness) -> orphan rc 4, a
#         batman-slot -> other (review r3 A-MAJOR-2); a step-window holder (lo:hi) -> leak; a step-window holder that is a
#         batman-slot not started by the helper -> writer (contention: other), one under the helper -> leak (review r2
#         B-m3); a file whose NAME ends in " -> <lock path>", held open with the token -> not a holder (review r2 B-m2)
#   host: SLOTLK = the lib + slk_take (no copy of the lib anywhere else in scripts/)
# Safe to run several at once on one host (review r2 A-m1 / B-m1): every holder is waited for until it holds the lock,
# and killed by its recorded pid (the holder IS the sleep: `exec`), never by name; the long sleeps are a copy of sleep
# named for this run ($SL), so another instance's (or an older version's) kill-by-name cannot reach them. Zero cases
# run = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB=$REPO/scripts/node/slotlock-lib-254.sh
P=0; F=0
chk(){ if [ "$2" = "$3" ]; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: got [$2] want [$3]"; F=$((F + 1)); fi; }
has(){ if grep -q -- "$3" <<< "$2"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: [$2] lacks [$3]"; F=$((F + 1)); fi; }
hasnt(){ if grep -q -- "$3" <<< "$2"; then echo "FAIL $1: [$2] has [$3]"; F=$((F + 1)); else echo "ok   $1"; P=$((P + 1)); fi; }
command -v flock >/dev/null || { echo "FAIL no flock on this host"; echo "SLOTLOCK 0 passed, 1 failed"; exit 1; }
SHS="dash"; command -v busybox >/dev/null && SHS="busybox_ash dash"
T=$(mktemp -d)
killrec(){ [ -f "$T/pids" ] && xargs -r kill < "$T/pids" 2>/dev/null; : > "$T/pids"; return 0; }
trap 'killrec; jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
mkdir -m 0755 "$T/run"
# a sleeper with its own name (comm and argv[0] = the file name): a copy of sleep or, where sleep is a multi-call binary
# that dispatches on argv[0] (GitHub's ubuntu runner: "coreutils: unknown program"), a 3-line C sleeper built here
mksleeper(){ cp "$(command -v sleep)" "$1" && "$1" 0 2>/dev/null && return 0
	printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 0); return 0; }\n' \
		| cc -x c -o "$1" - && "$1" 0; }
SLN=sl${T##*.}; SL=$T/$SLN; mksleeper "$SL"   # sl + mktemp's random suffix
L=$T/run/batman/batman-slot.flock
# hold <secs>: a process that holds the flock on $L for <secs> (it IS the sleep, so its pid frees it); returns once held
# holdb <secs>: the same, the holder named batman-slot (a legitimate writer, e.g. a long write)
hold(){ ( flock -x 7; exec "${HB:-$SL}" "$1" ) 7>>"$L" & HP=$!; echo "$HP" >> "$T/pids"
	local i=0; while flock -n "$L" true && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
unhold(){ kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; }
holdb(){ HB=$T/b/batman-slot hold "$1"; }
mkdir -p "$T/b"; mksleeper "$T/b/batman-slot"
# a rundir.sh like the node's: RUNDIR under $T; batman_rundir as the product's (mkdir 0700 + owner check), or failing
cat > "$T/rundir.sh" <<EOF
RUNDIR=$T/run/batman
batman_rundir(){ mkdir -m 700 "\$RUNDIR" 2>/dev/null; [ -d "\$RUNDIR" ] && [ -O "\$RUNDIR" ]; }
EOF
cat > "$T/rundir-bad.sh" <<EOF
RUNDIR=$T/run/batman
batman_rundir(){ echo "batman-rundir: UNUSABLE" >&2; return 1; }
EOF
cat > "$T/rundir-noopen.sh" <<EOF
RUNDIR=$T/nonexistent/batman
batman_rundir(){ return 0; }
EOF
# "verbs" that take the lock; -leak leaves a child holding fd 9 (the missing 9>&- of 254-p3-impl §3.7.3). Children's
# pids go to $T/pids.
cat > "$T/verb-leak" <<EOF
#!/bin/sh
exec 9>>"$L"; flock -n 9 || exit 14
"$SL" 6 & echo \$! >> "$T/pids"
exit 0
EOF
cat > "$T/verb-good" <<EOF
#!/bin/sh
exec 9>>"$L"; flock -n 9 || exit 14
"$SL" 6 9>&- & echo \$! >> "$T/pids"
exit 0
EOF
# a long-running batman-slot holding the lock (a writer), and a fake helper that starts one
mkdir -p "$T/w"
cat > "$T/w/batman-slot" <<EOF
#!/bin/sh
exec 9>>"$L"; flock 9; echo \$\$ > "$T/w/pid.\$1"; "$SL" 6 9>&- & echo \$! >> "$T/pids"; wait
EOF
# the "helper": a script whose comm is fh<mktemp suffix> (SLK_HELPER in the case below), the parent of a batman-slot
cat > "$T/w/fh${T##*.}" <<EOF
#!/bin/sh
"$T/w/batman-slot" "\$1" & echo \$! >> "$T/pids"; wait
EOF
chmod +x "$T/verb-leak" "$T/verb-good" "$T/w/batman-slot" "$T/w/fh${T##*.}"
waitf(){ local i=0; while [ ! -s "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
sh_(){ case "$1" in busybox_ash) shift; busybox ash "$@" ;; *) "$@" ;; esac; }
for SH in $SHS; do
	n=${SH%%_*}
	rm -rf "$T/run/batman"
	o=$(SLK_RD=$T/none.sh sh_ "$SH" -c ". '$LIB'; slk_take; echo rc=\$?; echo AFTER" 2>&1); chk "$n take: no rundir.sh -> rc 0, the rest runs" "$(echo $o)" "rc=0 AFTER"
	o=$(SLK_RD=$T/rundir-bad.sh sh_ "$SH" -c ". '$LIB'; slk_take || echo REFUSED; echo AFTER" 2>&1); has "$n take: run dir unusable -> SLOTLK-BUSY" "$o" "^SLOTLK-BUSY run dir"
	has "$n take: run dir unusable -> the shell goes on" "$o" "^AFTER"
	o=$(SLK_RD=$T/rundir-noopen.sh sh_ "$SH" -c ". '$LIB'; slk_take || echo REFUSED; echo AFTER" 2>&1); has "$n take: lock file cannot be opened -> SLOTLK-BUSY" "$o" "^SLOTLK-BUSY cannot open"
	has "$n take: open failed -> no shell exit" "$o" "^AFTER"
	# the review A-MINOR-1 construct, as a control: a bare exec redirection that fails ends the shell
	o=$(sh_ "$SH" -c "true && exec 9>>$T/nonexistent/x && echo locked; echo AFTER" 2>/dev/null); chk "$n control: a bare 'exec 9>>missing' ends the shell (what slk_take avoids)" "$o" ""
	rm -rf "$T/run/batman"; mkdir -m 700 "$T/run/batman"
	# review r3 A-MAJOR-2: held for 2 tries by an orphan (no batman-slot ancestor, not the harness) -> SLOTLK-BUSY LEAK
	hold 5
	o=$(SLK_RD=$T/rundir.sh SLK_TRIES=2 sh_ "$SH" -c ". '$LIB'; slk_take || { echo REFUSED; exit 1; }; echo MOUNTED" 2>&1); has "$n take: held elsewhere -> SLOTLK-BUSY" "$o" "^SLOTLK-BUSY LEAK the slot flock is held >= 2 s by [0-9]*:$SLN .*a leaked fd 9"
	has "$n take: held elsewhere -> no FAT work" "$(echo $o)" "REFUSED"
	unhold
	# held by a batman-slot (a legitimate writer) -> plain SLOTLK-BUSY (INVALID), not LEAK
	holdb 5
	o=$(SLK_RD=$T/rundir.sh SLK_TRIES=2 sh_ "$SH" -c ". '$LIB'; slk_take || { echo REFUSED; exit 1; }; echo MOUNTED" 2>&1); has "$n take: held by a batman-slot -> SLOTLK-BUSY (not LEAK)" "$o" "^SLOTLK-BUSY held by another for 2 tries"
	hasnt "$n take: held by a batman-slot -> no LEAK" "$o" "LEAK"
	unhold
	# held by another harness SLOTLK shell (its command line runs slk_take) and its child (DV_SLK_HOLD) -> plain
	# SLOTLK-BUSY, not LEAK
	SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_take && { $SL 5 & echo \Inappropriate ioctl for device >> $T/pids; wait; }" & HP=$!; echo "$HP" >> "$T/pids"; i=0; while flock -n "$L" true && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
	o=$(SLK_RD=$T/rundir.sh SLK_TRIES=2 sh_ "$SH" -c ". '$LIB'; slk_take || { echo REFUSED; exit 1; }; echo MOUNTED" 2>&1); has "$n take: held by another harness holder -> SLOTLK-BUSY (not LEAK)" "$o" "^SLOTLK-BUSY held by another for 2 tries"
	unhold
	killrec
	# free: held until the shell ends
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_take && echo HELD; flock -n $L true && echo OTHER-GOT-IT || echo OTHER-REFUSED" 2>&1); chk "$n take: free -> held, a second taker refused" "$(echo $o)" "HELD OTHER-REFUSED"
	flock -n "$L" true && r=free || r=held; chk "$n take: released when the shell exits" "$r" free
	# free checks
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokA -; echo rc=\$?" 2>&1); chk "$n free: nothing holds it -> ok" "$(echo $o)" "SLKFREE ok t=0 rc=0"
	rm -f "$L"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokA -; echo rc=\$?" 2>&1); chk "$n free: no lock file -> nofile" "$(echo $o)" "SLKFREE nofile rc=2"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; DV_SLK=tokL $T/verb-leak; slk_free 1 tokL -; echo rc=\$?" 2>&1); has "$n free: a child kept fd 9 -> leak (negative control)" "$(echo $o)" "SLKFREE leak holders=[0-9]*:$SLN:ours rc=1"
	killrec
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; DV_SLK=tokG $T/verb-good; slk_free 1 tokG -; echo rc=\$?" 2>&1); chk "$n free: the child closed fd 9 -> ok" "$(echo $o)" "SLKFREE ok t=0 rc=0"
	killrec
	# one of ours keeps the file open without the lock (the flock is free): still "not released" (item (2): nothing the
	# verb started may keep the lock file open)
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; DV_SLK=tokO $SL 6 8<$L & echo \$! >> $T/pids; sleep 0.3; slk_free 1 tokO -; echo rc=\$?" 2>&1); has "$n free: lock free but ours keeps the file open -> leak" "$(echo $o)" "SLKFREE leak holders=[0-9]*:$SLN:ours rc=1"
	killrec
	hold 4
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokX -; echo rc=\$?" 2>&1); has "$n free: held by another (not ours) -> an orphan (no batman-slot ancestor) -> orphan, FAIL (review r3 A-MAJOR-2)" "$(echo $o)" "SLKFREE orphan holders=[0-9]*:$SLN .* rc=4"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 - 0:\$(slk_ticks); echo rc=\$?" 2>&1); has "$n free: a holder started inside the step window -> leak" "$(echo $o)" "SLKFREE leak holders=.*:ours rc=1"
	unhold
	holdb 4
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokX -; echo rc=\$?" 2>&1); has "$n free: held by a batman-slot from outside the step -> other (contention)" "$(echo $o)" "SLKFREE other holders=[0-9]*:batman-slot:other rc=3"
	unhold
	# review r2 B-m3: inside the window, a batman-slot with no helper among its ancestors = another writer (contention)
	rm -f "$T/w/pid.x"; ( exec "$T/w/batman-slot" x ) & echo $! >> "$T/pids"; waitf "$T/w/pid.x"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 - 0:\$(slk_ticks); echo rc=\$?" 2>&1); has "$n free: a batman-slot of another writer in the window -> other (writer), not leak" "$(echo $o)" "SLKFREE other holders=[0-9]*:batman-slot:writer rc=3"
	killrec
	rm -f "$T/w/pid.y"; "$T/w/fh${T##*.}" y & echo $! >> "$T/pids"; waitf "$T/w/pid.y"
	o=$(SLK_RD=$T/rundir.sh SLK_HELPER=fh${T##*.} sh_ "$SH" -c ". '$LIB'; slk_free 1 - 0:\$(slk_ticks); echo rc=\$?" 2>&1); has "$n free: a batman-slot under the helper in the window -> leak" "$(echo $o)" "SLKFREE leak holders=[0-9]*:batman-slot:ours rc=1"
	killrec
	# review r2 B-m2: a file whose name ends in " -> <lock path>", held open by a process carrying the token
	mkdir -p "$T/evil/x -> $T/run/batman"; EV="$T/evil/x -> $L"; : > "$EV"
	( DV_SLK=fb123.bootinfoA exec "$SL" 7 5<"$EV" ) & echo $! >> "$T/pids"; sleep 0.3
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 fb123.bootinfoA -; echo rc=\$?" 2>&1); chk "$n free: a spoofed ' -> <lock path>' name with the token -> not a holder (ok)" "$(echo $o)" "SLKFREE ok t=0 rc=0"
	killrec; rm -rf "$T/evil"
done
# host side: SLOTLK is the lib plus slk_take, and the lib is the only copy
SLOTLK=""; . "$REPO/scripts/lib/slotlock-254.sh"
has "host: SLOTLK carries the lib" "$SLOTLK" "^slk_take(){"
has "host: SLOTLK ends by taking the lock" "$(printf '%s' "$SLOTLK" | tail -1)" "^slk_take || exit 1"
c=$(grep -rl --include='*.sh' -e '^slk_take()' "$REPO/scripts" | sed "s#^$REPO/##" | tr '\n' ' ')
chk "host: one copy of slk_take in scripts/" "$c" "scripts/node/slotlock-lib-254.sh "
c=$(grep -rlE --include='*.sh' 'exec 9>>"[$]RUNDIR/batman-slot[.]flock" && flock 9' "$REPO/scripts" | tr '\n' ' ')
chk "host: no hand-copied SLOTLK prefix left" "$c" ""
mkdir -p "$T/x/scripts/lib"; cp "$REPO/scripts/lib/slotlock-254.sh" "$T/x/scripts/lib/"
o=$(bash -c '. "$1/scripts/lib/slotlock-254.sh"; echo "rc=$? $SLOTLK"' _ "$T/x" 2>/dev/null); has "host: a missing node lib is an error (rc != 0)" "$o" "^rc=[1-9]"
has "host: a missing node lib gives a prefix that refuses, never an empty one" "$o" "SLOTLK-BUSY the harness lacks"
echo "SLOTLOCK $P passed, $F failed"
[ "$P" -gt 0 ] && [ "$F" = 0 ]
