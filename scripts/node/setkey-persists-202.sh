#!/bin/sh
# setkey-persists-202.sh — block A of daily-validation suite setkey-persists-202 (#202 close-out D2 §8).
# Runs ON the DNODE detached (setsid), because the key changes below take the node off the mesh for a
# while; the harness reads the result file afterwards. Steps 1/2/3/5 of D2:
#   1 a key with forbidden characters is refused before anything changes
#   2 --channel: an illegal channel for the country is refused; the current channel re-applied alone is ok
#   3 a temporary mesh key is applied AND persisted to p5 at once (p5 key == live key), precheck passes
#   5 the original key is restored by the same tool (p5 back to the original), node rejoins
# A 240 s watchdog restores hostname + key by itself if this script dies (connection loss cannot leave the
# node on the temporary key). Never prints a key: only md5 prefixes. Every FAIL line is a fixed string.
# Result file: /opt/batdata/log/dv202.out (p6, survives the mesh outage). Exit code is not used.
OUT=/opt/batdata/log/dv202.out; mkdir -p "${OUT%/*}"; : > "$OUT"
say(){ echo "$(cut -d. -f1 /proc/uptime) $*" >> "$OUT"; }
pass(){ say "PASS $*"; }; fail(){ say "FAIL $*"; }
DEV=/dev/mmcblk0p5; R=/tmp; [ -r /usr/lib/batman/rundir.sh ] && R=/tmp/run/batman
H=/tmp/run/batman-dv; { [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { fail "harness scratch $H unusable"; echo DONE >> "$OUT"; exit 1; }
MESHIF=$(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.mode='mesh'$/\1/p" | head -1)
RADIO=$(uci -q get "wireless.$MESHIF.device")
OLDKEY=$(uci -q get "wireless.$MESHIF.key"); OLDHOST=$(uci -q get system.@system[0].hostname)
CH=$(uci -q get "wireless.$RADIO.channel"); CC=$(uci -q get "wireless.$RADIO.country")
[ -n "$MESHIF" ] && [ -n "$OLDKEY" ] && [ -n "$CH" ] || { fail "cannot read mesh iface/key/channel"; echo DONE >> "$OUT"; exit 1; }
md(){ printf '%s' "$1" | md5sum | cut -c1-8; }
p5key(){ i=0; m=$H/p5k; mkdir -p "$m"
	until mount -t ext4 -o ro,noload "$DEV" "$m" 2>/dev/null; do i=$((i + 1)); [ $i -ge 5 ] && { echo UNREADABLE; return; }; sleep 1; done
	v=$(grep -F "wireless.$MESHIF.key=" "$m/overrides.uci" 2>/dev/null | sed "s/.*='\(.*\)'$/\1/"); umount "$m" 2>/dev/null; rmdir "$m" 2>/dev/null
	[ -n "$v" ] && md "$v" || echo NONE; }
joined(){ case "$(cat "$R/joinwatch.state" 2>/dev/null)" in JOINED*) return 0;; *) return 1;; esac; }
wait_joined(){ t=0; while [ $t -lt "$1" ]; do joined && return 0; sleep 5; t=$((t + 5)); done; return 1; }
HAVE_CHECK=0; batman-config-save --check 2>&1 | grep -q '^batman-config-save: p5 ' && HAVE_CHECK=1
HAVE_CHAN=0; halow-setkey --status 2>/dev/null | grep -q 'channel=' && HAVE_CHAN=1   # new setkey prints channel in --status
say "info: image $(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build) iface=$MESHIF radio=$RADIO ch=$CH cc=$CC key=$(md "$OLDKEY") p5key=$(p5key) check=$HAVE_CHECK"

# watchdog: whatever happens, hostname and key are back after 240 s (hostname first, then the key = --save)
( sleep 240; [ -f "$H/dv202.disarm" ] && exit 0
  uci set system.@system[0].hostname="$OLDHOST"; uci commit system
  [ "$(uci -q get "wireless.$MESHIF.key")" = "$OLDKEY" ] || halow-setkey --mesh "$OLDKEY" >/dev/null 2>&1
  say "WATCHDOG restored hostname+key" ) >/dev/null 2>&1 &
WD=$!; rm -f "$H/dv202.disarm"; say "info: watchdog pid=$WD"

# 1. forbidden characters: refused, nothing changed (an old setkey APPLIES it -> the node drops off; the watchdog covers)
out=$(halow-setkey --mesh 'ab&cd12345' 2>&1); rc=$?
if [ $rc -eq 2 ] && [ "$(uci -q get "wireless.$MESHIF.key")" = "$OLDKEY" ]; then pass "step1 setkey refused a key with forbidden characters (rc 2, nothing changed)"
else fail "setkey accepted an unpersistable key"; say "  rc=$rc: $(echo "$out" | tail -1)"
	[ "$(uci -q get "wireless.$MESHIF.key")" = "$OLDKEY" ] || { halow-setkey --mesh "$OLDKEY" >/dev/null 2>&1; wait_joined 180; }; fi
# 2. channel validation (only the new setkey knows --channel)
if [ "$HAVE_CHAN" = 1 ]; then
	out=$(halow-setkey --channel 36 2>&1); rc=$?
	if [ $rc -eq 2 ] && [ "$(uci -q get "wireless.$RADIO.channel")" = "$CH" ]; then pass "step2 --channel 36 refused for $CC (rc 2, unchanged)"; else fail "--channel accepted an illegal channel"; say "  rc=$rc: $(echo "$out" | tail -1)"; fi
	out=$(halow-setkey --channel "$CH" 2>&1); rc=$?   # re-applies the current channel: one wifi reload (off-mesh ①)
	if [ $rc -eq 0 ] && echo "$out" | grep -q "channel $CH = "; then pass "step2 --channel $CH alone applied and persisted ($(echo "$out" | sed -n 's/^channel [0-9]* = \(.*\)$/\1/p' | head -1))"
	else fail "--channel current value failed"; say "  rc=$rc: $(echo "$out" | tr '\n' '|')"; fi
	wait_joined 180 || say "  info: not rejoined within 180 s after the channel re-apply"
else
	fail "--channel unsupported"
fi
# 3. temporary key: applied and persisted at once (off-mesh ②)
TMPKEY="dv202-tmp-$(cut -c1-6 /proc/sys/kernel/random/uuid)"
out=$(halow-setkey --mesh "$TMPKEY" 2>&1); rc=$?
say "  step3 setkey rc=$rc: $(echo "$out" | grep -E 'persist|applied|keys updated' | tr '\n' '|')"
sleep 3
k=$(p5key)
if [ "$k" = "$(md "$TMPKEY")" ]; then pass "step3 p5 holds the key just set (md5 $k)"; else fail "p5 key not persisted by setkey"; say "  p5key=$k live=$(md "$(uci -q get "wireless.$MESHIF.key")")"; fi
if [ "$HAVE_CHECK" = 1 ]; then
	echo "$out" | grep -q '^persist: saved' && pass "step3 setkey reported persist: saved" || fail "setkey did not report persist: saved"
	batman-slot precheck-node >/dev/null 2>&1 && pass "step3 precheck-node passes with a fresh p5" || fail "precheck-node refused with a fresh p5: $(batman-slot precheck-node 2>&1 | tail -1)"
	v=$(cat "$R/p5-check.rc" 2>/dev/null); case "$v" in fresh*) pass "step3 verdict file says fresh" ;; *) fail "verdict file not fresh after precheck ($v)" ;; esac
fi
# 5. restore by the same door; rejoin
out=$(halow-setkey --mesh "$OLDKEY" 2>&1); rc=$?
sleep 3
[ "$(p5key)" = "$(md "$OLDKEY")" ] && pass "step5 p5 back to the original key" || fail "p5 did not return to the original key"
wait_joined 180 && pass "step5 rejoined the mesh within 180 s" || fail "did not rejoin within 180 s after key restore"
: > "$H/dv202.disarm"; kill "$WD" 2>/dev/null; sleep 1; kill -0 "$WD" 2>/dev/null && say "info: watchdog still alive after kill" || say "info: watchdog disarmed"
uci set system.@system[0].hostname="$OLDHOST"; uci commit system
echo DONE >> "$OUT"
