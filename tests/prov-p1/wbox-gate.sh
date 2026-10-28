#!/bin/bash
# tests/prov-p1/wbox-gate.sh <batman-slot> <batman-autocommit> — #254 security review F1 (docs/design/254-h23-harness.md
# §18.1, §19.3, §20.4, §21.2): a -wbox TEST image is never made the default slot. The real functions / blocks are
# extracted from the two product scripts and run in a sandbox with their fixed paths pointed at fixtures:
#   batman-slot: wbox_gate_self (commit) / wbox_gate_target (rollback), and that both run before write_autoboot,
#                the rollback one before rollback_lock_gate (so neither the legacy return nor the override skips it);
#   autocommit:  the WBOX_STATE detection and the why-folding (HOLDUNSAFE -> held_commit -> wbox), dry-run untouched.
# No root, no node. A run that executes zero cases FAILs. Negative control: the pre-gate scripts -> FAIL.
set -u
BS=$(readlink -f "${1:?usage: $0 <batman-slot> <batman-autocommit>}"); AC=$(readlink -f "${2:?}")
[ -f "$BS" ] && [ -f "$AC" ] || { echo "FAIL missing $BS or $AC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fails=0; cases=0
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails+1)); }
expect(){ cases=$((cases+1)); if eval "$2"; then ok "$1"; else no "$1 — $(tr '\n' ' ' < "$T/log" 2>/dev/null | cut -c1-240)"; fi; }
SH=$(command -v busybox >/dev/null 2>&1 && echo "busybox sh" || echo sh)   # the product shell when available

# ---------- batman-slot ----------
fns=$(awk '/^wbox_stamp\(\) \{/,/^\}/; /^wbox_gate_self\(\) \{/,/^\}/; /^wbox_gate_target\(\) \{/,/^\}/' "$BS")
for f in wbox_stamp wbox_gate_self wbox_gate_target; do
	cases=$((cases+1)); echo "$fns" | grep -q "^$f() {" && ok "batman-slot has $f()" || no "batman-slot: $f() missing"
done
order(){ # $1 function body, $2 first pattern, $3 second pattern -> first occurs before second
	local a b; a=$(echo "$1" | grep -n -- "$2" | head -1 | cut -d: -f1); b=$(echo "$1" | grep -n -- "$3" | head -1 | cut -d: -f1)
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
cm=$(awk '/^cmd_commit\(\) \{/,/^\}/' "$BS"); rb=$(awk '/^cmd_rollback\(\) \{/,/^\}/' "$BS")
cases=$((cases+1)); order "$cm" '^	wbox_gate_self' 'write_autoboot' && ok "cmd_commit: wbox_gate_self before write_autoboot" || no "cmd_commit: wbox_gate_self not before write_autoboot"
cases=$((cases+1)); order "$rb" '^	wbox_gate_target "\$T"' 'rollback_lock_gate "\$T"' && ok "cmd_rollback: wbox_gate_target before rollback_lock_gate" || no "cmd_rollback: wbox_gate_target not before rollback_lock_gate"
cases=$((cases+1)); order "$rb" '^	wbox_gate_target "\$T"' 'write_autoboot' && ok "cmd_rollback: wbox_gate_target before write_autoboot" || no "cmd_rollback: wbox_gate_target not before write_autoboot"
echo "$fns" | sed -e "s#/rom/etc/batman-build#$T/rom/etc/batman-build#g" -e "s#mktemp -d /tmp/#mktemp -d $T/#" > "$T/slotfns.sh"
cat > "$T/slotstubs.sh" <<'STUBS'
die(){ echo "DIE $*" >> "$LOG"; exit 1; }
st(){ echo "st $*" >> "$LOG"; }
slot_rootdev(){ echo "$G_T/slot$1"; }
mount(){ local _d _s; eval "_d=\${$#}; _s=\${$(($# - 1))}"; [ "$G_MOUNTFAIL" = 1 ] && return 32; cp -a "$_s"/. "$_d"/; }
umount(){ rm -rf "${1:?}"/* "${1:?}"/.[!.]* 2>/dev/null; }
STUBS
# stamp <dir> <kind>: release | wbox | wboxempty | wboxonly | veronly | nover | absent | symlink
stamp(){ rm -rf "$1"; mkdir -p "$1/etc"; case "$2" in
	release)   printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\nBATMAN_BOARD=ekh-bcm2711\n' > "$1/etc/batman-build" ;;
	wbox)      printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb.dirty.wbox-96-noprov\nBATMAN_WBOX=96-noprov\n' > "$1/etc/batman-build" ;;
	wboxempty) printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\nBATMAN_WBOX=\n' > "$1/etc/batman-build" ;;
	veronly)   printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb.dirty.wbox-chan\n' > "$1/etc/batman-build" ;;
	nover)     printf 'BATMAN_BOARD=ekh-bcm2711\n' > "$1/etc/batman-build" ;;
	wboxonly)  printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\nBATMAN_WBOX=helper-flap\n' > "$1/etc/batman-build" ;;   # the name only (review B-m1)
	symlink)   printf 'BATMAN_VERSION=1.5.14-wsl.8+aaaaaaa.fwbbbbbbb\n' > "$T/elsewhere"; ln -s "$T/elsewhere" "$1/etc/batman-build" ;;   # review A-m4
	absent)    ;;
esac; }
slot(){ # $1 self|target, [$2 mountfail]
	rm -f "$T/log"; : > "$T/log"
	env -i PATH=/usr/bin:/bin LOG="$T/log" G_T="$T" G_MOUNTFAIL="${2:-0}" $SH -c '. "$G_T/slotstubs.sh"; . "$G_T/slotfns.sh"; if [ "$0" = self ]; then wbox_gate_self; else wbox_gate_target B; fi; echo PASSED >> "$LOG"' "$1" </dev/null >/dev/null 2>&1
	RC=$?; }
passed(){ [ "$RC" = 0 ] && grep -q '^PASSED$' "$T/log"; }
died(){ [ "$RC" != 0 ] && grep -q "^DIE .*$1" "$T/log" && ! grep -q '^PASSED$' "$T/log"; }
noleft(){ ! ls -d "$T"/.rbwbox.* >/dev/null 2>&1; }
for k in release wboxempty; do stamp "$T/rom" $k; slot self; expect "commit: $k stamp -> allowed" passed; done
for k in wbox veronly wboxonly; do stamp "$T/rom" $k; slot self; expect "commit: $k stamp -> refused (never committed)" "died 'never committed'"; done
for k in nover absent symlink; do stamp "$T/rom" $k; slot self; expect "commit: $k stamp -> refused (unreadable)" "died 'build stamp is unreadable'"; done
for k in release wboxempty; do stamp "$T/slotB" $k; slot target; expect "rollback: target $k -> allowed, gate logged, no temp dir left" "passed && grep -q 'ROLLBACK-WBOX-GATE target=B ok=1' $T/log && noleft"; done
for k in wbox veronly wboxonly; do stamp "$T/slotB" $k; slot target; expect "rollback: target $k -> refused (holds a -wbox test image), no temp dir left" "died 'holds a -wbox test image' && noleft"; done
for k in nover absent symlink; do stamp "$T/slotB" $k; slot target; expect "rollback: target $k -> refused (unreadable, NOT the wbox message)" "died 'build stamp unreadable' && ! grep -q 'holds a -wbox' $T/log && noleft"; done
stamp "$T/slotB" release; slot target 1; expect "rollback: target squashfs cannot be mounted -> refused (unreadable)" "died 'build stamp unreadable' && noleft"

# ---------- batman-autocommit ----------
st=$(awk '/^WBOX_STATE=release$/,/^fi$/' "$AC")
cases=$((cases+1)); [ -n "$st" ] && ok "autocommit has the WBOX_STATE block" || no "autocommit: WBOX_STATE block missing"
echo "$st" | sed "s#/rom/etc/batman-build#$T/rom/etc/batman-build#g" > "$T/acstate.sh"
acstate(){ stamp "$T/rom" "$1"; env -i PATH=/usr/bin:/bin $SH -c '. "$0"; echo "$WBOX_STATE"' "$T/acstate.sh" 2>/dev/null; }
for kv in release:release wboxempty:release wbox:wbox:96-noprov veronly:wbox: wboxonly:wbox:helper-flap nover:unreadable absent:unreadable symlink:unreadable; do
	k=${kv%%:*}; want=${kv#*:}; got=$(acstate "$k"); : > "$T/log"; echo "got=$got want=$want" > "$T/log"
	expect "autocommit WBOX_STATE: $k -> $want" "[ \"$got\" = \"$want\" ]"
done
fold=$(awk '/^\tif \[ -z "\$why" \] && \[ "\$HOLDUNSAFE" = 1 \]; then$/{f=1} f{print} f && /^\tfi$/{exit}' "$AC")
h=$(echo "$fold" | grep -n 'HOLDUNSAFE" = 1' | head -1 | cut -d: -f1); c=$(echo "$fold" | grep -n 'held_commit' | head -1 | cut -d: -f1); w=$(echo "$fold" | grep -n 'WBOX_STATE' | head -1 | cut -d: -f1)
cases=$((cases+1)); [ -n "$h" ] && [ -n "$c" ] && [ -n "$w" ] && [ "$h" -lt "$c" ] && [ "$c" -lt "$w" ] && ok "autocommit fold order: HOLDUNSAFE -> held_commit -> wbox" || no "autocommit fold order: HOLDUNSAFE=${h:-none} held_commit=${c:-none} wbox=${w:-none}"
echo "$fold" > "$T/fold.sh"
cat > "$T/acstubs.sh" <<'STUBS'
log(){ echo "log $*" >> "$LOG"; }
otalog(){ echo "otalog $*" >> "$LOG"; }
held_commit(){ [ "$G_HELD" = 1 ]; }
STUBS
# fold <WBOX_STATE> <held 0|1> <DRY> <ok> <why-in> [REVERT, default 1]: runs the fold twice (two polls), prints why
fold(){ : > "$T/log"; W=$(env -i PATH=/usr/bin:/bin LOG="$T/log" G_HELD="$2" WBOX_STATE="$1" DRY="$3" ok="$4" NEED=3 why="$5" REVERT="${6:-1}" HOLDUNSAFE=0 SLOT=B DEADLINE=600 \
	$SH -c '. "$0"; . "$1"; w0=$why; . "$1"; why=$w0; . "$1"; echo "$why"' "$T/acstubs.sh" "$T/fold.sh" 2>>"$T/log"); echo "why=[$W]" >> "$T/log"; }
fold release 0 0 3 "";              expect "fold: release, healthy, no hold -> nothing folded (commit path open)" "[ -z \"\$W\" ]"
fold wbox:96-noprov 0 0 3 "";       expect "fold: wbox, no hold -> never auto-committed + WBOX-NOCOMMIT logged once" "echo \"\$W\" | grep -q 'wbox test image (BATMAN_WBOX=96-noprov) — never auto-committed' && [ \$(grep -c 'otalog AC WBOX-NOCOMMIT' $T/log) = 1 ]"
fold wbox:96-noprov 1 0 3 "";       expect "fold: wbox + hold -> HELD (not the wbox reason)" "echo \"\$W\" | grep -q 'held for operator acceptance' && grep -q 'otalog AC HELD' $T/log && ! grep -q 'WBOX-NOCOMMIT' $T/log"
fold wbox:96-noprov 0 1 3 "";       expect "fold: wbox, dry-run -> nothing folded (dry-run still decides COMMIT)" "[ -z \"\$W\" ]"
fold unreadable 0 0 3 "";           expect "fold: unreadable stamp -> not committing + STAMP-UNREADABLE (not the wbox reason)" "echo \"\$W\" | grep -q 'build stamp unreadable' && grep -q 'otalog AC STAMP-UNREADABLE' $T/log && ! grep -q 'WBOX-NOCOMMIT' $T/log"
fold wbox:96-noprov 0 0 3 "mesh lost"; expect "fold: unhealthy trial keeps its own reason (wbox not folded, FIRSTWHY untouched)" "[ \"\$W\" = 'mesh lost' ] && ! grep -q 'otalog' $T/log"
fold wbox:96-noprov 0 0 1 "";       expect "fold: wbox, dwell not reached -> not committing, nothing logged yet" "echo \"\$W\" | grep -q 'wbox test image' && ! grep -q 'otalog' $T/log"
fold release 1 0 3 "";              expect "fold: release + hold -> HELD (unchanged behaviour)" "echo \"\$W\" | grep -q 'held for operator acceptance'"
# stale fallback + wbox (§22.6 / v12 A-m9): a non-tryboot boot into an uncommitted wbox slot has REVERT=0 and goes
# through the SAME poll loop, so the fold holds it too (it never reads REVERT) — and no `batman-slot commit` may
# exist outside that loop: every one sits after the wbox fold, and the #133 stale-fallback block commits nothing
fold wbox:96-noprov 0 0 3 "" 0;     expect "fold: stale fallback (REVERT=0) + wbox -> never auto-committed" "echo \"\$W\" | grep -q 'never auto-committed'"
wl=$(grep -n '^	elif \[ -z "\$why" \] && \[ "\$DRY" != 1 \] && \[ "\$WBOX_STATE" != release \]; then$' "$AC" | head -1 | cut -d: -f1)
cl=$(grep -nE '(^|[;&|]|[[:space:]](if|then|else|do))[[:space:]]*batman-slot commit([[:space:];]|$)' "$AC" | grep -v '^[0-9]*:[[:space:]]*#' | cut -d: -f1 | tr '\n' ' ')
early=""; for x in $cl; do [ "$x" -gt "${wl:-999999}" ] || early="$early $x"; done
: > "$T/log"; echo "wbox fold line=${wl:-none} commit lines=[$cl] before the fold=[$early]" > "$T/log"
expect "autocommit: every 'batman-slot commit' comes after the wbox fold" "[ -n \"$wl\" ] && [ -n \"$cl\" ] && [ -z \"$early\" ]"
sf=$(awk '/^# #133 stale fallback, guarded/{f=1} /^# hold \(N3\/R2\)/{f=0} f' "$AC")
: > "$T/log"; echo "$sf" | grep -n 'commit\|exit' | grep -v '^[0-9]*:[[:space:]]*#' > "$T/log" || true
expect "autocommit: the stale-fallback block commits nothing (it only exits on NOT-COMMITTED)" "[ -n \"\$sf\" ] && ! echo \"\$sf\" | grep -v '^[[:space:]]*#' | grep -q 'batman-slot commit' && [ \"\$(echo \"\$sf\" | grep -c 'exit 0')\" = 1 ]"

[ "$cases" -gt 0 ] || { echo "FAIL no case ran"; exit 1; }
echo "WBOX-GATE cases=$cases fails=$fails"; [ "$fails" = 0 ]
