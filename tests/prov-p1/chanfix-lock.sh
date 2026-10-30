#!/bin/bash
# tests/prov-p1/chanfix-lock.sh <99-batman-chanfix> <rundir.sh> — #254 wireless-txn §6 / §11: each chanfix reassert
# holds halow-setkey's lock (commit + wifi reload under it, fd 9 closed for wifi), and when the lock is busy or the
# run dir unusable it reasserts ANYWAY (fail open: skipping would strand a fresh slot on morse's default channel).
# Runs the product under busybox ash against lib-wireless-stubs.sh; no root. A run with zero cases FAILs.
# Test-only edits of the copy (sed): p5 = a file and a fake mount that serves overrides.uci, rundir.sh path,
# LOCKWAIT 2 s, no 8 s settle sleeps, the background subshell run in the foreground; busybox applets the test must
# observe (mount, umount, logger) are shadowed by shell functions. Negative control: the shipped chanfix FAILs the
# "lock held at the commit" cases (it takes no lock).
set -u
CF=$(readlink -f "${1:?usage: $0 <99-batman-chanfix> <rundir.sh>}"); RD=$(readlink -f "${2:?usage: $0 <99-batman-chanfix> <rundir.sh>}")
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "CHANFIX-LOCK cases=0 fails=1"; exit 1; }
command -v flock >/dev/null || { echo "FAIL flock missing"; echo "CHANFIX-LOCK cases=0 fails=1"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/prov-p1/lib-wireless-stubs.sh
. "$HERE/lib-wireless-stubs.sh"
T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
stubs_init "$T/st"
stub_rundir "$RD" "$ST/rundir.sh"
LOCKF=$ST/run/batman/halow-setkey.lock
: > "$ST/p5"; echo "set wireless.radio1.channel='40'" > "$ST/overrides.uci"
cat > "$T/fns.sh" <<EOF
mount(){ eval "_m=\\\${\$#}"; cp "$ST/overrides.uci" "\$_m/overrides.uci"; }
umount(){ rm -f "\$1/overrides.uci"; }
logger(){ echo "\$*" >> "$ST/logger.log"; }
EOF
sed -e "1r $T/fns.sh" -e "s#^DEV=/dev/mmcblk0p5#DEV=$ST/p5#" -e 's/\[ -b "\$DEV" \]/[ -e "$DEV" ]/' \
	-e "s#/usr/lib/batman/rundir.sh#$ST/rundir.sh#g" -e "s#^\([[:space:]]*\)LOCKWAIT=90#\1LOCKWAIT=2#" \
	-e 's/sleep 8$/sleep 0/' -e 's/^) &$/)/' "$CF" > "$T/cf"
cases=0; fails=0
ok(){ cases=$((cases + 1)); echo "PASS $*"; }; no(){ cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
reset() {
	printf 'wireless.radio1.type=morse\nwireless.radio1.channel=42\nwireless.default_radio1.device=radio1\nwireless.default_radio1.mode=mesh\n' > "$ST/live"
	cp "$ST/live" "$ST/committed"; : > "$ST/commits.log"; : > "$ST/wifi.log"; : > "$ST/logger.log"
	echo wlh0 > "$ST/netdev"; chmod 755 "$ST/run"
}
run(){ PATH="$ST/bin:$PATH" STUB_LOCKFILE=$LOCKF timeout 60 busybox sh "$T/cf"; }

# 1. lock free: the reassert commits under the lock, wifi without the lock fd
reset
run >/dev/null 2>&1; rc=$?
d="lock free: rc 0 ($rc), channel 42 -> 40 committed"
if [ "$rc" = 0 ] && [ "$(committed_get wireless.radio1.channel)" = 40 ]; then ok "$d"; else no "$d"; fi
d="lock free: the commit ran while holding halow-setkey's lock ($(grep -c UNLOCKED "$ST/commits.log") unlocked)"
if [ "$(commits)" -ge 1 ] && ! grep -q UNLOCKED "$ST/commits.log"; then ok "$d"; else no "$d"; fi
d="lock free: wifi reload with the lock fd closed ($(head -1 "$ST/wifi.log"))"
if grep -q '^begin .*reload fd9=closed' "$ST/wifi.log" && ! grep -q 'fd9=open' "$ST/wifi.log"; then ok "$d"; else no "$d"; fi
d="lock free: lock released after the reassert (a writer can take it)"
if flock -n "$LOCKF" true; then ok "$d"; else no "$d"; fi

# 2. lock busy (a setkey stuck past LOCKWAIT): reassert anyway, logged
reset
flock -o "$LOCKF" sleep 20 & hp=$!; sleep 0.3
run >/dev/null 2>&1; rc=$?
d="lock busy: rc 0 ($rc), reasserted anyway (channel $(committed_get wireless.radio1.channel))"
if [ "$rc" = 0 ] && [ "$(committed_get wireless.radio1.channel)" = 40 ]; then ok "$d"; else no "$d"; fi
d="lock busy: logged 'reasserting anyway'"
if grep -q 'busy.*reasserting anyway' "$ST/logger.log"; then ok "$d"; else no "$d"; fi
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null

# 3. run dir unusable: reassert anyway, logged
reset; chmod 775 "$ST/run"
run >/dev/null 2>&1; rc=$?
d="run dir unusable: rc 0 ($rc), reasserted anyway (channel $(committed_get wireless.radio1.channel))"
if [ "$rc" = 0 ] && [ "$(committed_get wireless.radio1.channel)" = 40 ]; then ok "$d"; else no "$d"; fi
d="run dir unusable: logged 'without the halow-setkey lock'"
if grep -q 'unusable.*without the halow-setkey lock' "$ST/logger.log"; then ok "$d"; else no "$d"; fi
chmod 755 "$ST/run"

# 5. code review 2 (nit): the channel becomes right WHILE chanfix waits for the lock (a setkey holding it sets it) ->
# chanfix re-reads under the lock and neither commits nor reloads wifi (without the re-read it reasserts over it)
reset
flock -o "$LOCKF" sleep 1.2 & hp=$!; sleep 0.2
run >/dev/null 2>&1 & cp_=$!
sleep 0.4; sed -i 's/^wireless.radio1.channel=42$/wireless.radio1.channel=40/' "$ST/live"; cp "$ST/live" "$ST/committed"
wait "$cp_"; rc=$?; wait "$hp" 2>/dev/null
d="channel fixed while chanfix waited for the lock: rc 0 ($rc), chanfix made no commit ($(commits)) and no wifi reload ($(grep -c begin "$ST/wifi.log"))"
if [ "$rc" = 0 ] && [ "$(commits)" = 0 ] && [ ! -s "$ST/wifi.log" ]; then ok "$d"; else no "$d"; fi

# 4. control: channel already right -> nothing committed, no wifi reload
reset; printf 'wireless.radio1.type=morse\nwireless.radio1.channel=40\n' > "$ST/live"; cp "$ST/live" "$ST/committed"
run >/dev/null 2>&1; rc=$?
d="already on 40: rc 0 ($rc), no commit, no wifi"
if [ "$rc" = 0 ] && [ "$(commits)" = 0 ] && [ ! -s "$ST/wifi.log" ]; then ok "$d"; else no "$d"; fi

echo "CHANFIX-LOCK cases=$cases fails=$fails"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
