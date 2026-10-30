#!/bin/bash
# tests/prov-p1/setkey-checkonly-txn.sh <halow-setkey> <rundir.sh> — #254 wireless-txn v8 §15.1 / §15.6, halow-setkey:
#   --check-only: the write modes' validation, exit 0 / 2 with the SAME message, no lock / uci commit / wifi / persist,
#     no root needed; only --mesh / --mesh-id / --channel.
#   an operator's write (no --no-persist) is refused rc 2 while /etc/batman-prov/.txn exists; the helper (--no-persist)
#     proceeds; --status and --check-only are unaffected.
#   --forget-mesh on a radio switched off by hand (disabled=1, not in the keyguard mark): placeholder + disabled=1, the
#     radio stays OUT of the mark; still verified down.
# Runs the product under busybox ash against lib-wireless-stubs.sh; no root. Zero cases run = FAIL.
# Test-only edits of the copy (sed): rundir.sh / mark / regdb / .txn paths, LOCKWAIT / FORGET_WAIT shortened, id -u.
# Negative control: the shipped (pre-v8) halow-setkey FAILs (no --check-only, no .txn refusal, hand-disabled radio
# added to the mark).
set -u
SK=$(readlink -f "${1:?usage: $0 <halow-setkey> <rundir.sh>}"); RD=$(readlink -f "${2:?usage: $0 <halow-setkey> <rundir.sh>}")
[ -s "$SK" ] && [ -s "$RD" ] || { echo "FAIL product file missing / empty: $SK $RD"; echo "SETKEY-CHECKONLY-TXN cases=0 fails=1"; exit 1; }
command -v busybox >/dev/null || { echo "FAIL busybox missing"; echo "SETKEY-CHECKONLY-TXN cases=0 fails=1"; exit 1; }
command -v flock >/dev/null || { echo "FAIL flock missing"; echo "SETKEY-CHECKONLY-TXN cases=0 fails=1"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=tests/prov-p1/lib-wireless-stubs.sh
. "$HERE/lib-wireless-stubs.sh"
T=$(mktemp -d); trap 'jobs -p | xargs -r kill 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
stubs_init "$T/st"
stub_rundir "$RD" "$ST/rundir.sh"
LOCKF=$ST/run/batman/halow-setkey.lock
mkdir -p "$ST/prov"; TXNF=$ST/prov/.txn
# regdb: country_code,channelizations,default_channelization,bw,s1g_chan,..,..,centre_freq_mhz
printf 'US,1,1,4,40,0,0,922.0\nUS,1,1,2,42,0,0,923.0\nUS,1,1,1,27,0,0,915.5\n' > "$ST/channels.csv"
mkcopy() {   # $1 = uid the copy sees, $2 = output
	sed -e "s#/usr/lib/batman/rundir.sh#$ST/rundir.sh#g" -e "s#^MARK=/etc/halow-keyguard.blocked#MARK=$ST/mark#" \
		-e "s#^REGDB=/usr/share/morse-regdb/channels.csv#REGDB=$ST/channels.csv#" -e "s#^PROVTXN=/etc/batman-prov/.txn#PROVTXN=$TXNF#" \
		-e "s#^LOCKWAIT=90#LOCKWAIT=2#" -e "s#^FORGET_WAIT=30#FORGET_WAIT=2#" -e "s/\$(id -u)/\$(echo $1)/g" \
		-e "s#-b /dev/mmcblk0p5#-e $ST/p5#" "$SK" > "$2"
}
mkcopy 0 "$T/sk"; mkcopy 1000 "$T/sk.user"
PL=CHANGE-ME-NOW
cases=0; fails=0
ok(){ cases=$((cases + 1)); echo "PASS $*"; }; no(){ cases=$((cases + 1)); fails=$((fails + 1)); echo "FAIL $*"; }
run(){ PATH="$ST/bin:$PATH" busybox sh "$T/sk" "$@"; }
runu(){ PATH="$ST/bin:$PATH" busybox sh "$T/sk.user" "$@"; }
reset() {
	cat > "$ST/live" <<EOF
wireless.radio0.type=mac80211
wireless.default_radio0.device=radio0
wireless.default_radio0.mode=ap
wireless.default_radio0.key=$PL
wireless.default_radio0.disabled=1
wireless.radio1.type=morse
wireless.radio1.channel=27
wireless.radio1.country=US
wireless.default_radio1.device=radio1
wireless.default_radio1.mode=mesh
wireless.default_radio1.mesh_id=batmesh
wireless.default_radio1.key=realkey123
EOF
	cp "$ST/live" "$ST/committed"; : > "$ST/commits.log"; : > "$ST/wifi.log"; : > "$ST/cfgsave.log"
	echo " default_radio0" > "$ST/mark"
	echo wlh0 > "$ST/netdev"; echo up > "$ST/radio"; rm -f "$ST/stuck" "$ST/stuck-ubus" "$ST/wifi.sleep" "$ST/p5" "$TXNF"
	chmod 755 "$ST/run"
}
untouched(){ [ "$(commits)" = 0 ] && [ ! -s "$ST/wifi.log" ] && [ ! -s "$ST/cfgsave.log" ] && cmp -s "$ST/live" "$ST/committed"; }

# ---- --check-only ----------------------------------------------------------------------------------------------------
reset
flock -o "$LOCKF" sleep 30 & hp=$!; sleep 0.3          # the lock is held: --check-only must not wait for it
t0=$(date +%s); out=$(printf 'goodkey123\n' | run --check-only --mesh - --mesh-id batmesh --channel 40 2>&1); rc=$?; t1=$(date +%s)
d="check-only accepts a valid key / id / channel: rc 0 ($rc) in $((t1 - t0))s with the lock held :: $(echo "$out" | tail -1)"
if [ "$rc" = 0 ] && [ $((t1 - t0)) -le 1 ] && echo "$out" | grep -q 'would be accepted'; then ok "$d"; else no "$d"; fi
d="check-only accept: no uci commit, no wifi, no persist, live uci unchanged"
if untouched; then ok "$d"; else no "$d"; fi
out=$(printf 'goodkey123\n' | runu --check-only --mesh - --channel 42 2>&1); rc=$?
d="check-only as non-root: rc 0 ($rc) :: $(echo "$out" | tail -1)"
if [ "$rc" = 0 ]; then ok "$d"; else no "$d"; fi
kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
# the refusals: rc 2 and the SAME message the write mode gives (one validation implementation)
refuse() {   # $1 = label, $2 = key on stdin, rest = extra args
	local lbl=$1 key=$2; shift 2
	reset
	co=$(printf '%s\n' "$key" | run --check-only --mesh - "$@" 2>&1); crc=$?
	untouched; cu=$?
	wo=$(printf '%s\n' "$key" | run --mesh - "$@" --no-persist 2>&1); wrc=$?
	d="check-only refuses $lbl: rc $crc (write mode rc $wrc), same message, nothing changed :: $(echo "$co" | tail -1 | cut -c1-90)"
	if [ "$crc" = 2 ] && [ "$wrc" = 2 ] && [ "$cu" = 0 ] && untouched && [ "$(echo "$co" | tail -1)" = "$(echo "$wo" | tail -1)" ]; then ok "$d"; else no "$d"; fi
}
refuse "a key with &" 'op&erator1'
refuse "a key with '" "it's-mine"
refuse 'a key with $' 'pa$$word99'
refuse "a key < 8 chars" 'short7x'
refuse "the placeholder key" "$PL"
refuse "a mesh id with ;" 'goodkey123' --mesh-id 'bad;id'
refuse "channel auto" 'goodkey123' --channel auto
refuse "channel 99 (not legal for US)" 'goodkey123' --channel 99
# --check-only takes only --mesh / --mesh-id / --channel
reset
for a in "--forget-mesh" "--status" "--no-persist --mesh-id x1" "--ap apkey12345 --mesh-id x1" ""; do
	# shellcheck disable=SC2086  # split on purpose
	out=$(run --check-only $a 2>&1 </dev/null); rc=$?
	d="check-only combined with '${a:-nothing}': refused rc 2 ($rc), nothing changed"
	if [ "$rc" = 2 ] && untouched && ! echo "$out" | grep -q 'would be accepted'; then ok "$d"; else no "$d"; fi
done

# ---- an operator's write while .txn exists -----------------------------------------------------------------------------
reset; printf 'abc 1 2 network/join\nprev - - -\n' > "$TXNF"; touch "$ST/p5"
out=$(printf 'operkey123\n' | run --mesh - 2>&1); rc=$?
d=".txn + operator --mesh: rc 2 ($rc), says 'unfinished network change', nothing changed :: $(echo "$out" | tail -1 | cut -c1-90)"
if [ "$rc" = 2 ] && echo "$out" | grep -q 'an unfinished network change — let the helper finish it' && untouched; then ok "$d"; else no "$d"; fi
out=$(run --forget-mesh 2>&1); rc=$?
d=".txn + operator --forget-mesh: rc 2 ($rc), nothing changed"
if [ "$rc" = 2 ] && untouched; then ok "$d"; else no "$d"; fi
rm -f "$TXNF"; ln -s "$ST/nowhere" "$TXNF"
out=$(printf 'operkey123\n' | run --mesh - 2>&1); rc=$?
d=".txn as a dangling symlink + operator: rc 2 ($rc), nothing changed"
if [ "$rc" = 2 ] && untouched; then ok "$d"; else no "$d"; fi
out=$(run --status 2>&1); rc=$?
d=".txn + --status: rc 0 ($rc)"
if [ "$rc" = 0 ]; then ok "$d"; else no "$d"; fi
out=$(printf 'operkey123\n' | run --check-only --mesh - 2>&1); rc=$?
d=".txn + --check-only: rc 0 ($rc)"
if [ "$rc" = 0 ]; then ok "$d"; else no "$d"; fi
out=$(printf 'helperkey12\n' | run --mesh - --no-persist 2>&1); rc=$?
d=".txn + the helper (--no-persist): rc 0 ($rc), one commit"
if [ "$rc" = 0 ] && [ "$(commits)" = 1 ] && [ "$(committed_get wireless.default_radio1.key)" = helperkey12 ]; then ok "$d"; else no "$d"; fi
reset; touch "$ST/p5"
out=$(printf 'operkey123\n' | run --mesh - 2>&1); rc=$?
d="control: no .txn + operator --mesh: rc 0 ($rc), persisted"
if [ "$rc" = 0 ] && [ "$(cat "$ST/cfgsave.log")" = --save ]; then ok "$d"; else no "$d"; fi

# ---- --forget-mesh on a radio switched off by hand ---------------------------------------------------------------------
reset
echo "wireless.radio1.disabled=1" >> "$ST/live"; cp "$ST/live" "$ST/committed"; rm -f "$ST/netdev"; echo down > "$ST/radio"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="hand-disabled forget: rc 0 ($rc), placeholder committed, disabled=1, one commit"
if [ "$rc" = 0 ] && [ "$(commits)" = 1 ] && [ "$(committed_get wireless.default_radio1.key)" = "$PL" ] && [ "$(committed_get wireless.radio1.disabled)" = 1 ]; then ok "$d"; else no "$d"; fi
d="hand-disabled forget: the radio is NOT added to the keyguard mark ('$(cat "$ST/mark")')"
if [ "$(cat "$ST/mark")" = " default_radio0" ]; then ok "$d"; else no "$d"; fi
reset
echo "wireless.radio1.disabled=1" >> "$ST/live"; cp "$ST/live" "$ST/committed"; touch "$ST/stuck"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="hand-disabled forget, netdev still present: rc 3 ($rc) — still verified"
if [ "$rc" = 3 ]; then ok "$d"; else no "$d"; fi
# control: a radio blocked BY keyguard (in the mark) stays in the mark
reset
echo "wireless.radio1.disabled=1" >> "$ST/live"; cp "$ST/live" "$ST/committed"; echo " default_radio0 radio1" > "$ST/mark"
out=$(run --forget-mesh --no-persist 2>&1); rc=$?
d="control: keyguard-blocked radio: rc 0 ($rc), stays in the mark ('$(cat "$ST/mark")')"
if [ "$rc" = 0 ] && grep -qw radio1 "$ST/mark"; then ok "$d"; else no "$d"; fi

echo "SETKEY-CHECKONLY-TXN cases=$cases fails=$fails"
[ "$cases" -gt 0 ] && [ "$fails" = 0 ]
