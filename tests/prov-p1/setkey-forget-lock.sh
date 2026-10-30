#!/bin/bash
# tests/prov-p1/setkey-forget-lock.sh <halow-setkey> <rundir.sh> [wireless-settle.sh] — #254 wireless-txn §6 / §11 /
# §19: halow-setkey --forget-mesh (one commit with the placeholder AND the keyguard block, mark merged, verified
# down), the writer lock (serialised writers, busy -> rc 2, run dir unusable -> rc 2, --status lock-free), and §19:
# the settle gate (rc 2 before any write while netifd is pending / unreadable), the read-back on netifd's word
# (up, not pending, the config just written; retry_setup_failed -> rc 3 at once; no wait when the radio stays
# blocked), and the forget escalation on an orphan (a root wpa_supplicant_s1g by /proc, then `iw dev del`, only while
# netifd reports the radio down+disabled+not pending). Runs the product under busybox ash against the fakes of
# lib-wireless-stubs.sh; no root. A run that executes zero cases FAILs.
# Test-only edits of the copy (sed): rundir.sh / wireless-settle.sh paths, keyguard mark path, LOCKWAIT / FORGET_WAIT /
# SETTLE_WAIT / READBACK_WAIT shortened, id -u = 0, "p5 present" = a file, the fake /sys, S1G_EXE = the real `sleep`
# binary the fake s1g processes run and S1G_UID = this uid (the Uid-mismatch branch is therefore NOT tested here).
# Negative control: the same test on the shipped halow-setkey (ebb9cf4) FAILs the §19 cases (no gate, uci-only
# read-back, no escalation); on main's it FAILs the rest too (no --forget-mesh, no lock).
set -u
# elapsed time from /proc/uptime: the WSL wall clock steps back ~1 s at times (review 4 B m4, 3 of 30 probes)
SK=$(readlink -f "${1:?usage: $0 <halow-setkey> <rundir.sh> [wireless-settle.sh]}"); RD=$(readlink -f "${2:?usage: $0 <halow-setkey> <rundir.sh> [wireless-settle.sh]}")
WS=$(readlink -f "${3:-$(dirname "$RD")/wireless-settle.sh}")
SLEEPX=$(readlink -f "$(command -v sleep)")
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "SETKEY-FORGET-LOCK cases=0 fails=1"; exit 1; }
command -v flock >/dev/null || { echo "FAIL flock missing"; echo "SETKEY-FORGET-LOCK cases=0 fails=1"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/prov-p1/lib-wireless-stubs.sh
. "$HERE/lib-wireless-stubs.sh"
T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
stubs_init "$T/st"
stub_rundir "$RD" "$ST/rundir.sh"
LOCKF=$ST/run/batman/halow-setkey.lock
# busybox sh runs its own `logger` applet, not $ST/bin/logger: the copy gets a shell function (as chanfix-lock.sh does)
printf 'logger(){ echo "$*" >> "%s/logger.log"; }\n' "$ST" > "$T/fns.sh"
mkcopy() {   # $1 = LOCKWAIT for this copy, $2 = output
	sed -e "1r $T/fns.sh" -e "s#/usr/lib/batman/rundir.sh#$ST/rundir.sh#g" -e "s#^MARK=/etc/halow-keyguard.blocked#MARK=$ST/mark#" \
		-e "s#^WSETTLE=/usr/lib/batman/wireless-settle.sh#WSETTLE=$WS#" -e "s#^IEEE80211=/sys/class/ieee80211; NETCLASS=/sys/class/net; PROC=/proc; S1G_EXE=/usr/sbin/wpa_supplicant_s1g; S1G_UID=0#IEEE80211=$ST/sys/ieee80211; NETCLASS=$ST/sys/net; PROC=/proc; S1G_EXE=$SLEEPX; S1G_UID=$(id -u)#" \
		-e "s#^SETTLE_WAIT=30#SETTLE_WAIT=3#" -e "s#^READBACK_WAIT=60#READBACK_WAIT=4#" \
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
wireless.$r.path=platform/soc/fe204000.spi/spi_master/spi0/spi0.0
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
	rm -f "$ST/pending" "$ST/pending0" "$ST/wifi.async" "$ST/wifi.stale" "$ST/stale-until" "$ST/stale-cfg" "$ST/rsf" "$ST/stay-down" "$ST/ubus.fail" "$ST/ubus.nosection" "$ST/orphan" "$ST/s1g.pids" "$ST/committed.prev"
	: > "$ST/iw.log"; : > "$ST/pgrep.log"; : > "$ST/logger.log"
	stub_sys "$r" platform/soc/fe204000.spi/spi_master/spi0/spi0.0
	chmod 755 "$ST/run"
}
up(){ cut -d. -f1 /proc/uptime; }
# a fake root wpa_supplicant_s1g: a real `sleep` process (S1G_EXE = its binary); a decoy = bash (another exe)
spawn_s1g(){ sleep 120 >/dev/null 2>&1 </dev/null & echo $!; }
spawn_decoy(){ bash -c 'sleep 120; :' >/dev/null 2>&1 </dev/null & echo $!; }
alive(){ kill -0 "$1" 2>/dev/null; }
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
flock -o "$LOCKF" sleep 8 & hp=$!; sleep 0.3
t0=$(cut -d. -f1 /proc/uptime); out=$(printf 'thirdkey123\n' | run --mesh - --no-persist 2>&1); rc=$?; t1=$(cut -d. -f1 /proc/uptime)
if [ "$rc" = 2 ] && [ $((t1 - t0)) -ge 3 ] && echo "$out" | grep -q busy; then ok "busy: rc 2 ($rc) after ~LOCKWAIT ($((t1 - t0))s) :: $(echo "$out" | tail -1)"; else no "busy: rc 2 ($rc) after ~LOCKWAIT ($((t1 - t0))s) :: $(echo "$out" | tail -1)"; fi
if [ "$(commits)" = 0 ]; then ok "busy: nothing committed"; else no "busy: nothing committed"; fi
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "busy: --forget-mesh rc 2 ($rc), nothing committed"; else no "busy: --forget-mesh rc 2 ($rc), nothing committed"; fi
# --status is read-only: no lock
t0=$(cut -d. -f1 /proc/uptime); out=$(run --status 2>&1); rc=$?; t1=$(cut -d. -f1 /proc/uptime)
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

# ---- #254 §19: netifd's word ---------------------------------------------------------------------------------------
# (a) read-back waits for netifd up + not pending + the written config: an async reload of 2 s -> rc 0 after >= 2 s
reset; echo 2 > "$ST/wifi.async"
t0=$(up); out=$(printf 'asynckey123\n' | run --mesh - --no-persist 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19a read-back: netifd setup takes 2 s -> rc 0 ($rc) after >= 2 s (${dt}s), logged 'read-back: netifd up after'"
if [ "$rc" = 0 ] && [ "$dt" -ge 2 ] && grep -q "read-back: netifd up after [0-9]* s" "$ST/logger.log"; then ok "$d"; else no "$d"; fi
# (a) stays pending past READBACK_WAIT -> rc 3 unverified, nothing persisted
reset; echo 60 > "$ST/wifi.async"; touch "$ST/p5"
t0=$(up); out=$(printf 'pendkey1234\n' | run --mesh - 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19a read-back: netifd never reports up -> rc 3 ($rc) at ~READBACK_WAIT (${dt}s), persist not attempted"
if [ "$rc" = 3 ] && [ "$dt" -ge 4 ] && [ ! -s "$ST/cfgsave.log" ] && echo "$out" | grep -q "did not report"; then ok "$d"; else no "$d"; fi
rm -f "$ST/pending"
# (a) netifd ends down, not pending, no retry_setup_failed, the new config in place: NOT up -> rc 3 at the deadline
reset; touch "$ST/stay-down"; touch "$ST/p5"
t0=$(up); out=$(printf 'downkey1234\n' | run --mesh - 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19a read-back: netifd settled with the radio down (config in place) -> rc 3 ($rc) at ~READBACK_WAIT (${dt}s), persist not attempted"
if [ "$rc" = 3 ] && [ "$dt" -ge 4 ] && [ ! -s "$ST/cfgsave.log" ]; then ok "$d"; else no "$d"; fi
# (a) the §19.1 ordering mutant: ubus keeps the PRE-reload view (up=true, old key) for 2 s -> not rc 0 before 2 s
reset; echo 2 > "$ST/wifi.stale"; echo 1 > "$ST/wifi.async"
t0=$(up); out=$(printf 'stalekey123\n' | run --mesh - --no-persist 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19a read-back: a stale pre-reload status (old key, up=true) does not satisfy it -> rc 0 ($rc) only after the real up (${dt}s >= 2)"
if [ "$rc" = 0 ] && [ "$dt" -ge 2 ]; then ok "$d"; else no "$d"; fi
# (b) settle gate: pending clears after 2 s -> the reload begins after it; nothing written before
reset; touch "$ST/pending"; ( sleep 2; rm -f "$ST/pending" ) &
t0=$(up); out=$(printf 'gatekey1234\n' | run --mesh - --no-persist 2>&1); rc=$?; wait
wb=$(sed -n 's/^begin .* up=\([0-9]*\)$/\1/p' "$ST/wifi.log" | head -1)
d="19b settle gate: pending for 2 s -> rc 0 ($rc), the reload began >= 2 s after the start (begin at +$(( ${wb:-0} - t0 )) s)"
if [ "$rc" = 0 ] && [ -n "$wb" ] && [ $(( wb - t0 )) -ge 2 ]; then ok "$d"; else no "$d"; fi
# (b) pending never clears -> rc 2, ZERO commits, for --mesh, --ap and --forget-mesh
reset; touch "$ST/pending"
for m in "--mesh -" "--ap apkey12345" "--forget-mesh"; do
	t0=$(up); out=$(printf 'nevkey12345\n' | run $m --no-persist 2>&1); rc=$?; dt=$(( $(up) - t0 ))
	d="19b settle gate: netifd pending for good -> $m rc 2 ($rc) at ~SETTLE_WAIT (${dt}s), zero commits ($(commits)) :: $(echo "$out" | tail -1)"
	if [ "$rc" = 2 ] && [ "$(commits)" = 0 ] && [ "$dt" -ge 3 ] && echo "$out" | grep -q "still reconfiguring"; then ok "$d"; else no "$d"; fi
done
# (b) ubus fails / no section for the morse radio = not settled -> rc 2, zero commits
reset; touch "$ST/ubus.fail"
out=$(printf 'failkey1234\n' | run --mesh - --no-persist 2>&1); rc=$?
d="19b settle gate: ubus exits 1 -> rc 2 ($rc), zero commits ($(commits))"
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "$d"; else no "$d"; fi
reset; touch "$ST/ubus.nosection"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19b settle gate: no section for the morse radio -> --forget-mesh rc 2 ($rc), zero commits ($(commits))"
if [ "$rc" = 2 ] && [ "$(commits)" = 0 ]; then ok "$d"; else no "$d"; fi
# (i) the OTHER radio pending does not delay us
reset; touch "$ST/pending0"
t0=$(up); out=$(printf 'otherkey123\n' | run --mesh - --no-persist 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19i radio0 pending: no wait -> rc 0 ($rc) within 1 s (${dt}s)"
if [ "$rc" = 0 ] && [ "$dt" -le 1 ]; then ok "$d"; else no "$d"; fi
# (e) the radio stays blocked (placeholder mesh key, keyguard mark): --ap alone / --mesh-id alone -> rc 0 with no netifd wait
reset; sed -i "s/^wireless.default_radio1.key=.*/wireless.default_radio1.key=$PL/; s/^wireless.radio1.channel=27$/wireless.radio1.channel=27\nwireless.radio1.disabled=1/" "$ST/live"; cp "$ST/live" "$ST/committed"
echo " default_radio0 radio1" > "$ST/mark"; rm -f "$ST/netdev"; echo down > "$ST/radio"; echo 60 > "$ST/wifi.async"
t0=$(up); out=$(run --ap newapkey123 --no-persist 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19e --ap alone with the mesh key still the placeholder: rc 0 ($rc) without a netifd wait (${dt}s), radio1 stays disabled ($(committed_get wireless.radio1.disabled))"
if [ "$rc" = 0 ] && [ "$dt" -le 1 ] && [ "$(committed_get wireless.radio1.disabled)" = 1 ]; then ok "$d"; else no "$d"; fi
rm -f "$ST/pending"; : > "$ST/commits.log"
t0=$(up); out=$(run --mesh-id newid --no-persist 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19e --mesh-id alone with the placeholder key: rc 0 ($rc) without a netifd wait (${dt}s)"
if [ "$rc" = 0 ] && [ "$dt" -le 1 ]; then ok "$d"; else no "$d"; fi
rm -f "$ST/pending"
# (f) netifd gave up (retry_setup_failed) -> rc 3 at once
reset; touch "$ST/rsf"; touch "$ST/p5"
t0=$(up); out=$(printf 'rsfkey12345\n' | run --mesh - 2>&1); rc=$?; dt=$(( $(up) - t0 ))
d="19f retry_setup_failed: rc 3 ($rc) at once (${dt}s), 'gave up', persist not attempted"
if [ "$rc" = 3 ] && [ "$dt" -le 1 ] && echo "$out" | grep -q "gave up" && [ ! -s "$ST/cfgsave.log" ]; then ok "$d"; else no "$d"; fi
# (c) the orphan of §19.1: netifd reports the radio down+disabled after the forget, but a mesh netdev with a root s1g
# stays -> TERM the s1g (a real process), then `iw dev wlh0 del`, then verified -> rc 0 with the escalation line
reset; echo wlh0 > "$ST/orphan"; sp=$(spawn_s1g); echo "$sp" > "$ST/s1g.pids"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
pg=$(sed -n '1s/^\([0-9]*\) .*/\1/p' "$ST/pgrep.log"); dl=$(sed -n '1s/^\([0-9]*\) .*/\1/p' "$ST/iw.log")
d="19c orphan: rc 0 ($rc); s1g $sp killed ($(alive "$sp" && echo alive || echo gone)); 'iw dev wlh0 del' after the pgrep ($(grep -c 'iw dev wlh0 del' "$ST/iw.log") del, pgrep@${pg:-?} del@${dl:-?}); escalation logged"
if [ "$rc" = 0 ] && ! alive "$sp" && grep -q 'iw dev wlh0 del' "$ST/iw.log" && [ -n "$pg" ] && [ -n "$dl" ] && [ "$dl" -ge "$pg" ] && grep -q "forgotten after escalation (orphan wlh0 s1g:$sp)" "$ST/logger.log"; then ok "$d"; else no "$d"; fi
kill "$sp" 2>/dev/null
d="19c orphan: the pgrep pattern names the netdev and the s1g, anchored ($(sed -n '1s/^[0-9]* pgrep //p' "$ST/pgrep.log"))"
if grep -q 'pgrep -f wpa_supplicant_s1g .\*-i wlh0( |\$)' "$ST/pgrep.log"; then ok "$d"; else no "$d"; fi
# (c) no s1g for the orphan -> straight to the del, logged
reset; echo wlh0 > "$ST/orphan"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19c orphan without an s1g: rc 0 ($rc), del done, 'no wpa_supplicant_s1g' logged"
if [ "$rc" = 0 ] && grep -q 'iw dev wlh0 del' "$ST/iw.log" && grep -q "no wpa_supplicant_s1g for orphan wlh0" "$ST/logger.log"; then ok "$d"; else no "$d"; fi
# (g) a decoy whose argv names the netdev but whose exe is not the s1g binary: not killed; the del still clears the netdev
reset; echo wlh0 > "$ST/orphan"; dp=$(spawn_decoy); echo "$dp" > "$ST/s1g.pids"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19g decoy (exe = bash): not killed ($(alive "$dp" && echo alive || echo gone)), rc 0 ($rc) after the del"
if [ "$rc" = 0 ] && alive "$dp" && grep -q 'iw dev wlh0 del' "$ST/iw.log"; then ok "$d"; else no "$d"; fi
kill "$dp" 2>/dev/null
# (d) netifd still owns the radio (up=true: stuck) -> no escalation: nothing killed, nothing deleted, rc 3
reset; touch "$ST/stuck"; echo wlh0 > "$ST/orphan"; sp=$(spawn_s1g); echo "$sp" > "$ST/s1g.pids"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19d netifd up=true at the deadline: rc 3 ($rc), no kill ($(alive "$sp" && echo alive || echo gone)), no del ($(grep -c del "$ST/iw.log"))"
if [ "$rc" = 3 ] && alive "$sp" && ! grep -q del "$ST/iw.log"; then ok "$d"; else no "$d"; fi
kill "$sp" 2>/dev/null
# (d) netifd down but pending at the deadline -> no escalation either
reset; echo wlh0 > "$ST/orphan"; sp=$(spawn_s1g); echo "$sp" > "$ST/s1g.pids"; echo 60 > "$ST/wifi.async"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19d netifd pending at the deadline: rc 3 ($rc), no kill ($(alive "$sp" && echo alive || echo gone)), no del ($(grep -c del "$ST/iw.log"))"
if [ "$rc" = 3 ] && alive "$sp" && ! grep -q del "$ST/iw.log"; then ok "$d"; else no "$d"; fi
kill "$sp" 2>/dev/null; rm -f "$ST/pending"
# (h) a mesh netdev on the OTHER phy is never touched -> rc 3
reset; echo wlhx > "$ST/orphan"; sp=$(spawn_s1g); echo "$sp" > "$ST/s1g.pids"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19h mesh netdev on the other phy: rc 3 ($rc), no kill ($(alive "$sp" && echo alive || echo gone)), no del ($(grep -c del "$ST/iw.log"))"
if [ "$rc" = 3 ] && alive "$sp" && ! grep -q del "$ST/iw.log"; then ok "$d"; else no "$d"; fi
kill "$sp" 2>/dev/null
# the morse phy unresolvable (no uci path) -> no escalation, rc 3
reset; echo wlh0 > "$ST/orphan"; sed -i '/^wireless.radio1.path=/d' "$ST/live"; cp "$ST/live" "$ST/committed"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="19h no uci path for the radio: rc 3 ($rc), no del ($(grep -c del "$ST/iw.log"))"
if [ "$rc" = 3 ] && ! grep -q del "$ST/iw.log"; then ok "$d"; else no "$d"; fi

echo "SETKEY-FORGET-LOCK cases=$cases fails=$fails"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
