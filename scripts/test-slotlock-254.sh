#!/bin/bash
# scripts/test-slotlock-254.sh — offline test of the harness's #254 S5 slot-flock helpers (scripts/node/slotlock-lib-254.sh,
# scripts/lib/slotlock-254.sh) under busybox ash (the node's shell; util-linux flock stands in for busybox's applet when
# the host busybox has none) and dash. No node. Cases:
#   take: no rundir.sh -> nothing taken, the rest runs; batman_rundir fails -> SLOTLK-BUSY, the shell goes on (no exit);
#         the lock file cannot be opened -> SLOTLK-BUSY, the shell goes on; lock held elsewhere -> SLOTLK-BUSY after
#         SLK_TRIES; free -> held on fd 9 until the shell exits (a second taker is refused meanwhile)
#   free: ok; nofile; a verb's child that kept fd 9 -> leak (the negative control of every "lock released" check);
#         a holder from outside -> other; a step-window holder (lo:hi) -> leak
#   host: SLOTLK = the lib + slk_take (no copy of the lib anywhere else in scripts/)
# Zero cases run = FAIL.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB=$REPO/scripts/node/slotlock-lib-254.sh
P=0; F=0
chk(){ if [ "$2" = "$3" ]; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: got [$2] want [$3]"; F=$((F + 1)); fi; }
has(){ if grep -q -- "$3" <<< "$2"; then echo "ok   $1"; P=$((P + 1)); else echo "FAIL $1: [$2] lacks [$3]"; F=$((F + 1)); fi; }
command -v flock >/dev/null || { echo "FAIL no flock on this host"; echo "SLOTLOCK 0 passed, 1 failed"; exit 1; }
SHS="dash"; command -v busybox >/dev/null && SHS="busybox_ash dash"
T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
mkdir -m 0755 "$T/run"
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
	# held by another process for 5 s; 2 tries -> busy
	( flock -x 7; sleep 5 ) 7>>"$T/run/batman/batman-slot.flock" & hp=$!; sleep 0.3
	o=$(SLK_RD=$T/rundir.sh SLK_TRIES=2 sh_ "$SH" -c ". '$LIB'; slk_take || { echo REFUSED; exit 1; }; echo MOUNTED" 2>&1); has "$n take: held elsewhere -> SLOTLK-BUSY" "$o" "^SLOTLK-BUSY held by another for 2 tries"
	has "$n take: held elsewhere -> no FAT work" "$(echo $o)" "REFUSED"
	kill $hp 2>/dev/null; wait $hp 2>/dev/null
	# free: held until the shell ends
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_take && echo HELD; flock -n $T/run/batman/batman-slot.flock true && echo OTHER-GOT-IT || echo OTHER-REFUSED" 2>&1); chk "$n take: free -> held, a second taker refused" "$(echo $o)" "HELD OTHER-REFUSED"
	flock -n "$T/run/batman/batman-slot.flock" true && r=free || r=held; chk "$n take: released when the shell exits" "$r" free
	# free checks
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokA -; echo rc=\$?" 2>&1); chk "$n free: nothing holds it -> ok" "$(echo $o)" "SLKFREE ok t=0 rc=0"
	rm -f "$T/run/batman/batman-slot.flock"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokA -; echo rc=\$?" 2>&1); chk "$n free: no lock file -> nofile" "$(echo $o)" "SLKFREE nofile rc=2"
	# a "verb" that takes the lock and leaves a child holding fd 9 (the missing 9>&- of 254-p3-impl §3.7.3)
	cat > "$T/verb-leak" <<EOF
#!/bin/sh
exec 9>>"$T/run/batman/batman-slot.flock"; flock -n 9 || exit 14
sleep 6 &
exit 0
EOF
	cat > "$T/verb-good" <<EOF
#!/bin/sh
exec 9>>"$T/run/batman/batman-slot.flock"; flock -n 9 || exit 14
sleep 6 9>&- &
exit 0
EOF
	chmod +x "$T/verb-leak" "$T/verb-good"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; DV_SLK=tokL $T/verb-leak; slk_free 1 tokL -; echo rc=\$?" 2>&1); has "$n free: a child kept fd 9 -> leak (negative control)" "$(echo $o)" "SLKFREE leak holders=[0-9]*:sleep:ours rc=1"
	pkill -f "^sleep 6$" 2>/dev/null; sleep 0.2
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; DV_SLK=tokG $T/verb-good; slk_free 1 tokG -; echo rc=\$?" 2>&1); chk "$n free: the child closed fd 9 -> ok" "$(echo $o)" "SLKFREE ok t=0 rc=0"
	pkill -f "^sleep 6$" 2>/dev/null; sleep 0.2
	# one of ours keeps the file open without the lock (the flock is free): still "not released" (item (2): nothing the
	# verb started may keep the lock file open)
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; DV_SLK=tokO /bin/sleep 6 8<$T/run/batman/batman-slot.flock & sleep 0.3; slk_free 1 tokO -; echo rc=\$?" 2>&1); has "$n free: lock free but ours keeps the file open -> leak" "$(echo $o)" "SLKFREE leak holders=[0-9]*:sleep:ours rc=1"
	pkill -f "^/bin/sleep 6$" 2>/dev/null; sleep 0.2
	( flock -x 7; sleep 4 ) 7>>"$T/run/batman/batman-slot.flock" & hp=$!; sleep 0.3
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 tokX -; echo rc=\$?" 2>&1); has "$n free: held by another (not ours) -> other" "$(echo $o)" "SLKFREE other holders=.*:other rc=3"
	o=$(SLK_RD=$T/rundir.sh sh_ "$SH" -c ". '$LIB'; slk_free 1 - 0:\$(slk_ticks); echo rc=\$?" 2>&1); has "$n free: a holder started inside the step window -> leak" "$(echo $o)" "SLKFREE leak holders=.*:ours rc=1"
	kill $hp 2>/dev/null; wait $hp 2>/dev/null
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
