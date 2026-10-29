#!/bin/bash
# tests/prov-p1/setkey-forget-lock.sh <halow-setkey> <rundir.sh> — #254 wireless-txn §6 / §11: halow-setkey
# --forget-mesh (one commit with the placeholder AND the keyguard block, mark merged, verified down) and the writer
# lock (serialised writers, busy -> rc 2, run dir unusable -> rc 2, --status lock-free). Runs the product under
# busybox ash against the fakes of lib-wireless-stubs.sh; no root. A run that executes zero cases FAILs.
# Test-only edits of the copy (sed): rundir.sh path, keyguard mark path, LOCKWAIT / FORGET_WAIT shortened, id -u = 0,
# "p5 present" = a file. Negative control: the same test on the shipped halow-setkey FAILs (no --forget-mesh, no lock).
set -u
SK=$(readlink -f "${1:?usage: $0 <halow-setkey> <rundir.sh>}"); RD=$(readlink -f "${2:?usage: $0 <halow-setkey> <rundir.sh>}")
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "SETKEY-FORGET-LOCK cases=0 fails=1"; exit 1; }
command -v flock >/dev/null || { echo "FAIL flock missing"; echo "SETKEY-FORGET-LOCK cases=0 fails=1"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/prov-p1/lib-wireless-stubs.sh
. "$HERE/lib-wireless-stubs.sh"
T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
stubs_init "$T/st"
stub_rundir "$RD" "$ST/rundir.sh"
LOCKF=$ST/run/batman/halow-setkey.lock
mkcopy() {   # $1 = LOCKWAIT for this copy, $2 = output
	sed -e "s#/usr/lib/batman/rundir.sh#$ST/rundir.sh#g" -e "s#^MARK=/etc/halow-keyguard.blocked#MARK=$ST/mark#" \
		-e "s#^LOCKWAIT=90#LOCKWAIT=$1#" -e "s#^FORGET_WAIT=30#FORGET_WAIT=2#" -e 's/\$(id -u)/$(echo 0)/g' \
		-e "s#-b /dev/mmcblk0p5#-e $ST/p5#" "$SK" > "$2"
}
mkcopy 4 "$T/sk"
PL=CHANGE-ME-NOW
cases=0; fails=0
ok(){ cases=$((cases + 1)); echo "PASS $*"; }; no(){ cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
run(){ PATH="$ST/bin:$PATH" busybox sh "$T/sk" "$@"; }

reset() {   # $1 = morse radio name (default radio1)
	local r=${1:-radio1}
	cat > "$ST/live" <<EOF
wireless.radio0.type=mac80211
wireless.default_radio0.device=radio0
wireless.default_radio0.mode=ap
wireless.default_radio0.key=$PL
wireless.default_radio0.disabled=1
wireless.$r.type=morse
wireless.$r.channel=27
wireless.$r.country=US
wireless.default_$r.device=$r
wireless.default_$r.mode=mesh
wireless.default_$r.mesh_id=batmesh
wireless.default_$r.key=realkey123
EOF
	cp "$ST/live" "$ST/committed"; : > "$ST/commits.log"; : > "$ST/wifi.log"; : > "$ST/cfgsave.log"
	echo " default_radio0" > "$ST/mark"   # what halow-keyguard wrote for the placeholder AP key
	echo wlh0 > "$ST/netdev"; echo up > "$ST/radio"; rm -f "$ST/stuck" "$ST/stuck-ubus" "$ST/wifi.sleep" "$ST/p5"
	chmod 755 "$ST/run"
}
# no committed state may hold a placeholder mesh key on an enabled radio (§9)
never_placeholder_enabled() {   # $1 = radio
	awk -v r="$1" -v pl="$PL" '
		/^--- commit/ { if (n++) chk(); key = ""; dis = "" ; next }
		index($0, "wireless.default_" r ".key=") == 1 { key = substr($0, index($0, "=") + 1) }
		index($0, "wireless." r ".disabled=") == 1 { dis = substr($0, index($0, "=") + 1) }
		function chk() { if (key == pl && dis != "1") bad = 1 }
		END { if (n) chk(); exit bad }' "$ST/commits.log"
}

# ---- --forget-mesh ----------------------------------------------------------------------------------------------
reset
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "forget: rc 0 ($rc) :: $(echo "$out" | tail -1)"; else no "forget: rc 0 ($rc) :: $(echo "$out" | tail -1)"; fi
if [ "$(commits)" = 1 ]; then ok "forget: exactly ONE uci commit ($(commits))"; else no "forget: exactly ONE uci commit ($(commits))"; fi
if [ "$(committed_get wireless.default_radio1.key)" = "$PL" ]; then ok "forget: committed key = placeholder"; else no "forget: committed key = placeholder"; fi
if [ "$(committed_get wireless.radio1.disabled)" = 1 ]; then ok "forget: committed radio1 disabled=1"; else no "forget: committed radio1 disabled=1"; fi
if never_placeholder_enabled radio1; then ok "forget: no commit with the placeholder on an enabled radio"; else no "forget: no commit with the placeholder on an enabled radio"; fi
if [ "$(committed_get wireless.default_radio1.mesh_id) $(committed_get wireless.radio1.channel)" = "batmesh 27" ]; then ok "forget: mesh id / channel unchanged"; else no "forget: mesh id / channel unchanged"; fi
if [ "$(tr -s ' ' '\n' < "$ST/mark" | grep -v '^$' | sort | tr '\n' ' ')" = "default_radio0 radio1 " ]; then ok "forget: keyguard mark merged (AP entry kept): '$(cat "$ST/mark")'"; else no "forget: keyguard mark merged (AP entry kept): '$(cat "$ST/mark")'"; fi
if [ "$(committed_get wireless.default_radio0.disabled)" = 1 ]; then ok "forget: AP stays blocked"; else no "forget: AP stays blocked"; fi
if grep -q "^begin .*reload fd9=closed" "$ST/wifi.log"; then ok "forget: wifi reloaded with the lock fd closed"; else no "forget: wifi reloaded with the lock fd closed"; fi
if [ ! -s "$ST/cfgsave.log" ]; then ok "forget: --no-persist -> no config-save"; else no "forget: --no-persist -> no config-save"; fi
if ! grep -q UNLOCKED "$ST/commits.log"; then ok "forget: lock held at the commit"; else no "forget: lock held at the commit"; fi
# idempotent
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(tr -s ' ' '\n' < "$ST/mark" | grep -c '^radio1$')" = 1 ]; then ok "forget again: rc 0 ($rc), radio1 listed once in the mark"; else no "forget again: rc 0 ($rc), radio1 listed once in the mark"; fi
# verification fails: netdev stays -> rc 3, no persist
reset; touch "$ST/stuck" "$ST/p5"
out=$(run --forget-mesh 2>&1); rc=$?
if [ "$rc" = 3 ]; then ok "forget, netdev still present: rc 3 ($rc)"; else no "forget, netdev still present: rc 3 ($rc)"; fi
if [ ! -s "$ST/cfgsave.log" ]; then ok "forget, netdev still present: persist not attempted"; else no "forget, netdev still present: persist not attempted"; fi
if never_placeholder_enabled radio1; then ok "forget, netdev still present: still never placeholder+enabled"; else no "forget, netdev still present: still never placeholder+enabled"; fi
reset; touch "$ST/stuck-ubus"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
if [ "$rc" = 3 ]; then ok "forget, netdev gone but netifd says disabled=false: rc 3 ($rc)"; else no "forget, netdev gone but netifd says disabled=false: rc 3 ($rc)"; fi
# persist as the other modes: without --no-persist it runs batman-config-save --save
reset; touch "$ST/p5"
out=$(run --forget-mesh 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$ST/cfgsave.log")" = --save ]; then ok "forget + persist: rc 0 ($rc), config-save --save ran"; else no "forget + persist: rc 0 ($rc), config-save --save ran"; fi
# the morse radio is found, never hard-coded radio1
reset radio7
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="forget on radio7: rc 0 ($rc), radio7 disabled, mark has radio7, no radio1 written"
if [ "$rc" = 0 ] && [ "$(committed_get wireless.radio7.disabled)" = 1 ] && grep -qw radio7 "$ST/mark" && ! grep -q 'wireless.radio1' "$ST/committed"; then ok "$d"; else no "$d"; fi
if never_placeholder_enabled radio7; then ok "forget on radio7: never placeholder+enabled"; else no "forget on radio7: never placeholder+enabled"; fi
# no key from argv / stdin: --forget-mesh with a key is refused before anything
reset
out=$(printf 'realkey999\n' | run --forget-mesh --mesh - --no-persist 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "forget + --mesh -: refused rc 2 ($rc), nothing committed"; else no "forget + --mesh -: refused rc 2 ($rc), nothing committed"; fi
out=$(run --forget-mesh --mesh realkey999 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "forget + --mesh <key>: refused rc 2 ($rc), nothing committed"; else no "forget + --mesh <key>: refused rc 2 ($rc), nothing committed"; fi
# the placeholder as a key stays refused
out=$(run --mesh "$PL" --no-persist 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "--mesh CHANGE-ME-NOW: refused rc 2 ($rc), nothing committed"; else no "--mesh CHANGE-ME-NOW: refused rc 2 ($rc), nothing committed"; fi
# re-join after a forget releases only the radio (keyguard's AP entry stays)
reset; run --forget-mesh --no-persist >/dev/null 2>&1
out=$(printf 'newkey12345\n' | run --mesh - --no-persist 2>&1); rc=$?
d="re-join after forget: rc 0 ($rc), radio1 released, mark keeps default_radio0 only"
if [ "$rc" = 0 ] && [ -z "$(committed_get wireless.radio1.disabled)" ] && [ "$(tr -s ' ' '\n' < "$ST/mark" | grep -v '^$' | tr '\n' ' ')" = "default_radio0 " ]; then ok "$d"; else no "$d"; fi

# ---- the writer lock ----------------------------------------------------------------------------------------------
# two concurrent writers serialise: the second waits, the wifi calls never overlap
reset; echo 1.5 > "$ST/wifi.sleep"
export STUB_LOCKFILE=$LOCKF
( printf 'firstkey123\n' | run --mesh - --no-persist > "$T/a.out" 2>&1; echo $? > "$T/a.rc" ) &
sleep 0.4
( printf 'secondkey12\n' | run --mesh - --no-persist > "$T/b.out" 2>&1; echo $? > "$T/b.rc" ) &
wait
seq=$(awk '{print $1}' "$ST/wifi.log" | tr '\n' ' ')
if [ "$(cat "$T/a.rc") $(cat "$T/b.rc")" = "0 0" ]; then ok "two writers: both rc 0 ($(cat "$T/a.rc") $(cat "$T/b.rc"))"; else no "two writers: both rc 0 ($(cat "$T/a.rc") $(cat "$T/b.rc"))"; fi
if [ "$seq" = "begin end begin end " ]; then ok "two writers: wifi calls serialised ($seq)"; else no "two writers: wifi calls serialised ($seq)"; fi
if ! grep -q UNLOCKED "$ST/commits.log"; then ok "two writers: every commit under the lock"; else no "two writers: every commit under the lock"; fi
if [ "$(committed_get wireless.default_radio1.key)" = secondkey12 ]; then ok "two writers: the second's key is the final one"; else no "two writers: the second's key is the final one"; fi
unset STUB_LOCKFILE
# busy longer than LOCKWAIT -> rc 2, nothing changed
reset
flock "$LOCKF" sleep 8 & hp=$!; sleep 0.3
t0=$(date +%s); out=$(printf 'thirdkey123\n' | run --mesh - --no-persist 2>&1); rc=$?; t1=$(date +%s)
if [ "$rc" = 2 ] && [ $((t1 - t0)) -ge 3 ] && echo "$out" | grep -q busy; then ok "busy: rc 2 ($rc) after ~LOCKWAIT ($((t1 - t0))s) :: $(echo "$out" | tail -1)"; else no "busy: rc 2 ($rc) after ~LOCKWAIT ($((t1 - t0))s) :: $(echo "$out" | tail -1)"; fi
if [ "$(commits)" = 0 ]; then ok "busy: nothing committed"; else no "busy: nothing committed"; fi
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "busy: --forget-mesh rc 2 ($rc), nothing committed"; else no "busy: --forget-mesh rc 2 ($rc), nothing committed"; fi
# --status is read-only: no lock
t0=$(date +%s); out=$(run --status 2>&1); rc=$?; t1=$(date +%s)
if [ "$rc" = 0 ] && [ $((t1 - t0)) -le 1 ]; then ok "busy: --status rc 0 ($rc) without waiting ($((t1 - t0))s)"; else no "busy: --status rc 0 ($rc) without waiting ($((t1 - t0))s)"; fi
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
# run dir unusable (parent group-writable, #280) -> rc 2 fail closed
reset; chmod 775 "$ST/run"
out=$(printf 'fourthkey12\n' | run --mesh - --no-persist 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "run dir unusable: rc 2 ($rc), nothing committed"; else no "run dir unusable: rc 2 ($rc), nothing committed"; fi
chmod 755 "$ST/run"
# rundir.sh missing -> rc 2
sed "s#$ST/rundir.sh#$ST/no-such-rundir.sh#g" "$T/sk" > "$T/sk.nord"
out=$(printf 'fifthkey123\n' | PATH="$ST/bin:$PATH" busybox sh "$T/sk.nord" --mesh - --no-persist 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "rundir.sh missing: rc 2 ($rc), nothing committed"; else no "rundir.sh missing: rc 2 ($rc), nothing committed"; fi
# control: lock free, run dir fine -> the same write works
out=$(printf 'sixthkey123\n' | run --mesh - --no-persist 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(commits)" = 1 ]; then ok "control: lock free -> rc 0 ($rc), one commit"; else no "control: lock free -> rc 0 ($rc), one commit"; fi

echo "SETKEY-FORGET-LOCK cases=$cases fails=$fails"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
