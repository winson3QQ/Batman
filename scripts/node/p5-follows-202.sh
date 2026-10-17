#!/bin/sh
# p5-follows-202.sh — run ON a node (ssh root@node sh -s < this): daily-validation suite p5-follows-config-202.
# #202 close-out D1 (docs/design/202-config-survival-closeout.md §8): a JOINED node's shared config
# partition p5 must FOLLOW the running per-node config within one joinwatch tick, with no once-per-boot
# latch (G1), under concurrent writers (T6) and under concurrent ro readers (T11); the freshness verdict
# `batman-config-save --check` must exist and agree. Prints PASS/FAIL lines; exit 0 all PASS, 1 any FAIL,
# 3 + SKIP-REASON when it cannot test here. Every FAIL line is a fixed string (known-failures, #290).
# Touches only system.@system[0].hostname (restored) and files in the root-only run dir.
# #280: the harness scratch dir lives under /tmp/run (root 0755 on every OpenWrt image).
H=/tmp/run/batman-dv; { [ -d "$H" ] || mkdir -m 700 "$H"; } && [ -O "$H" ] && [ ! -L "$H" ] || { echo "FAIL harness scratch $H unusable"; exit 1; }
R=/tmp; [ -r /usr/lib/batman/rundir.sh ] && R=/tmp/run/batman   # #280 harness resolver for the run dir
B=/usr/bin/batman-config-save; DEV=/dev/mmcblk0p5
[ -b "$DEV" ] || { echo "SKIP-REASON: no p5 on this card"; exit 3; }
[ "$(hexdump -s 1080 -n 2 -e '2/1 "%02x"' "$DEV")" = 53ef ] || { echo "SKIP-REASON: p5 not plain ext4"; exit 3; }
state=$(cat "$R/joinwatch.state" 2>/dev/null); case "$state" in JOINED*) ;; *) echo "SKIP-REASON: node not JOINED ([$state]) — on-join does not run"; exit 3 ;; esac
mc(){ hexdump -s 1076 -n 2 -e '1/2 "%u"' "$DEV"; }
up(){ cut -d. -f1 /proc/uptime; }
f=0; pass(){ echo "PASS $*"; }; fail(){ echo "FAIL $*"; f=1; }
M=$H/p5
p5host(){ # hostname line on p5, read-only (retry: a concurrent rw writer makes a ro mount EBUSY for a moment, T11)
	i=0; mkdir -p "$M"
	until mount -t ext4 -o ro,noload "$DEV" "$M" 2>/dev/null; do i=$((i + 1)); [ $i -ge 5 ] && { echo UNREADABLE; return; }; sleep 1; done
	grep -F "system.@system[0].hostname" "$M/overrides.uci" 2>/dev/null | sed "s/.*='\(.*\)'$/\1/"
	umount "$M" 2>/dev/null
}
p5file(){ i=0; mkdir -p "$M"; until mount -t ext4 -o ro,noload "$DEV" "$M" 2>/dev/null; do i=$((i + 1)); [ $i -ge 5 ] && return 1; sleep 1; done; cat "$M/$1" 2>/dev/null; umount "$M" 2>/dev/null; }
wait_p5host(){ # $1 expected, $2 seconds
	t=0; while [ $t -lt "$2" ]; do [ "$(p5host)" = "$1" ] && return 0; sleep 5; t=$((t + 5)); done; return 1; }
OLD=$(uci -q get system.@system[0].hostname); [ -n "$OLD" ] || { echo "FAIL cannot read the hostname"; exit 1; }
sethost(){ uci set system.@system[0].hostname="$1"; uci commit system; }
cleanup(){
	sethost "$OLD"; rm -f "$R/config-saved" "$R/cfgsave-writes"
	[ -x "$B" ] && "$B" --save >/dev/null 2>&1
	umount "$M" 2>/dev/null; rmdir "$M" 2>/dev/null
	/etc/init.d/joinwatch running >/dev/null 2>&1 || /etc/init.d/joinwatch start >/dev/null 2>&1
}
trap cleanup EXIT

# precondition: the freshness verdict exists on this image (pre-#202 images fail here and continue: steps 1–3
# still show G1; steps 4–6 are then "not verified")
HAVE_CHECK=1
if ! "$B" --check 2>&1 | grep -q '^batman-config-save: p5 '; then HAVE_CHECK=0; fail "batman-config-save --check unsupported (pre-#202 image)"; fi
echo "info: image $(sed -n 's/^BATMAN_VERSION=//p' /etc/batman-build 2>/dev/null) p5 hostname=$(p5host) live=$OLD check=$HAVE_CHECK"

# 1. white-box: the once-per-boot latch a LOCKED node used to set (joinwatch < #202 close-out). A current
#    image has no reader for this file; an old one freezes p5 for the rest of the boot (G1).
( umask 077; : > "$R/config-saved" )
# 2. change -> p5 must follow within 60 s (4 ticks)
sethost "$OLD-dv202"
if wait_p5host "$OLD-dv202" 60; then pass "step2 p5 followed the hostname change within 60 s (latch file present)"
else fail "p5 hostname stale after 60 s"; echo "  (G1 latch on an old image, or T11 ro/rw collision — both #202; p5=$(p5host))"; fi
# 3. joinwatch restart (stale lock takeover path), change again
/etc/init.d/joinwatch restart >/dev/null 2>&1; sleep 2
sethost "$OLD-dv202b"
if wait_p5host "$OLD-dv202b" 60; then pass "step3 p5 followed after a joinwatch restart"; else fail "p5 hostname stale after 60 s (after joinwatch restart)"; fi

if [ "$HAVE_CHECK" = 1 ]; then
	# 4. concurrent writers (T6): a --save loop and an --on-join loop at the same time, 30 s, no sleeps
	#    (busybox has no fractional sleep). Assert afterwards: overrides == live, lkg == overrides (one more
	#    on-join rotates lkg), the busy marker appeared (the tight loop blocks >= 8 on-join calls) and is gone,
	#    and p5 mounts <= 2 x saves + 5 (each --save drops the cache -> the next on-join misses and writes once more).
	rm -f "$R/cfgsave-writes"; m0=$(mc)
	n=0; end=$(( $(up) + 30 ))
	( i=0; while [ "$(up)" -lt $end ]; do "$B" --on-join >/dev/null 2>&1; i=$((i + 1)); done; echo $i > "$H/onjoin.n" ) &
	while [ "$(up)" -lt $end ]; do n=$((n + 1)); sethost "$OLD-c$n"; "$B" --save >/dev/null 2>&1; done
	wait
	rm -f "$R/cfgsave-writes"; "$B" --on-join >/dev/null 2>&1; rc=$?
	ov=$(p5file overrides.uci | grep -F hostname | sed "s/.*='\(.*\)'$/\1/"); lk=$(p5file lkg/overrides.uci | grep -F hostname | sed "s/.*='\(.*\)'$/\1/")
	live=$(uci -q get system.@system[0].hostname); m1=$(mc); d=$(( (m1 - m0 + 65536) % 65536 ))
	echo "  step4: saves=$n on-join calls=$(cat "$H/onjoin.n" 2>/dev/null) last on-join rc=$rc p5=$ov lkg=$lk live=$live mounts=+$d busy_now=$([ -f "$R/cfgsave-lock.busy" ] && echo yes || echo no)"
	if [ "$ov" = "$live" ] && [ "$lk" = "$ov" ]; then pass "step4 p5 == live and lkg == overrides after concurrent writers"; else fail "p5 lost an update under concurrent writers"; fi
	[ -f "$R/cfgsave-lock.busy" ] && fail "lock-busy marker left behind after contention" || pass "step4 no lock-busy marker left after short contention"
	[ $d -le $((2 * n + 5)) ] && pass "step4 p5 mounts +$d <= 2x$n+5" || fail "p5 mounted more than expected (+$d for $n saves)"
	# 4c. a STUCK lock holder (white-box: a sleeping process whose argv0 says batman-config-save, so the takeover
	#     rule keeps its hands off): --on-join must be blocked (rc 1), raise the busy marker after 8 calls, --check
	#     must say lock-busy (rc 8); once the holder is gone the next caller takes the lock over and clears the marker.
	rm -rf "$R/cfgsave.lock"; rm -f "$R/cfgsave-lock.busy" "$R/cfgsave-lock.count"
	sh -c 'sleep 90; :' batman-config-save </dev/null >/dev/null 2>&1 & HP=$!   # 'sleep 90; :' keeps the shell (busybox execs a lone command)
	mkdir "$R/cfgsave.lock" && echo $HP > "$R/cfgsave.lock/pid" && up > "$R/cfgsave.lock/uptime"
	bl=0; for i in 1 2 3 4 5 6 7 8 9; do "$B" --on-join >/dev/null 2>&1; [ $? -eq 1 ] && bl=$((bl + 1)); done
	"$B" --check >/dev/null 2>&1; crc=$?
	echo "  step4c: blocked_on_join=$bl/9 check_rc=$crc busy=$([ -f "$R/cfgsave-lock.busy" ] && echo yes || echo no) busy_file=[$(cat "$R/cfgsave-lock.busy" 2>/dev/null)]"
	[ $bl -eq 9 ] && [ -f "$R/cfgsave-lock.busy" ] && pass "step4c stuck holder: --on-join blocked 9/9 and the busy marker was raised" || fail "lock-busy marker not raised by a stuck holder (blocked=$bl)"
	[ $crc -eq 8 ] && pass "step4c --check reports lock-busy (rc 8) under a stuck holder" || fail "--check did not report lock-busy under a stuck holder (rc $crc)"
	kill $HP 2>/dev/null; wait $HP 2>/dev/null
	"$B" --on-join >/dev/null 2>&1
	[ ! -f "$R/cfgsave-lock.busy" ] && [ -f "$R/cfgsave-onjoin.state" ] && pass "step4c lock taken over after the holder died, busy marker cleared" || fail "stale lock not taken over / busy marker not cleared"
else
	fail "pre-#202 image: step4 concurrent writers untestable"
fi

# 4b. ro readers (T11): a reader HOLDS p5 ro,noload (>= 60 % duty) while --save runs. The writer must see its
#     rw mount come up read-only at least once, retry, and still land every write. Runs on old images too (safe:
#     only the hostname suffix changes) — there it is the T11 negative control.
held=0; : > "$H/reader.stop"; rm -f "$H/reader.stop"
( h=0; mkdir -p "$H/rd"; while [ ! -f "$H/reader.stop" ]; do
	if mount -t ext4 -o ro,noload "$DEV" "$H/rd" 2>/dev/null; then h=$((h + 1)); sleep 2; umount "$H/rd" 2>/dev/null; fi
	sleep 1; done; echo $h > "$H/reader.held"; rmdir "$H/rd" 2>/dev/null ) &
sleep 2
seen=0; ok=1; k=0
while [ $k -lt 12 ]; do
	k=$((k + 1)); sethost "$OLD-r$k"
	out=$("$B" --save 2>&1); rc=$?
	echo "$out" | grep -q "rw mount came up read-only" && seen=1
	[ $rc -eq 0 ] || { ok=0; echo "  step4b --save #$k rc=$rc: $(echo "$out" | tail -1)"; }
	[ "$(p5host)" = "$OLD-r$k" ] || { ok=0; echo "  step4b --save #$k reported rc=$rc but p5 hostname=$(p5host)"; }
	[ $seen = 1 ] && break
	# shellcheck disable=SC3028  # busybox ash has RANDOM; $$ is the fallback
	sleep $((3 + ${RANDOM:-$$} % 2))   # jitter against the writer's 1 s retry cadence
done
: > "$H/reader.stop"; wait; held=$(cat "$H/reader.held" 2>/dev/null)
echo "  step4b: saves=$k retry_seen=$seen reader_held=$held mount.failed=$([ -f "$R/cfgsave-mount.failed" ] && echo yes || echo no)"
# the reader is stopped as soon as the retry is seen, so a short run holds few times; without a retry it must have held long
if [ $seen = 1 ]; then [ "${held:-0}" -ge 1 ] || fail "T11 reader could not hold p5 (held=$held)"; else [ "${held:-0}" -ge 5 ] || fail "T11 reader could not hold p5 (held=$held)"; fi
if [ $ok = 1 ] && [ ! -f "$R/cfgsave-mount.failed" ]; then pass "step4b every --save landed under a holding ro reader"; else fail "writer silently read-only under ro readers"; fi
[ $seen = 1 ] && pass "step4b the rw-came-up-read-only retry path was exercised" || fail "T11 not exercised"

if [ "$HAVE_CHECK" = 1 ]; then
	# 5. a stale mount-failure marker must not block when --check says fresh, and must be cleared by the next write
	( umask 077; echo "0 test" > "$R/cfgsave-mount.failed" )
	if batman-slot precheck-node >/dev/null 2>&1; then pass "step5 precheck-node ignores a stale mount.failed marker when p5 is fresh"; else fail "precheck-node refused with a stale mount.failed marker and a fresh p5"; fi
	sethost "$OLD-m"; rm -f "$R/cfgsave-writes"; "$B" --on-join >/dev/null 2>&1
	[ -f "$R/cfgsave-mount.failed" ] && fail "mount.failed marker not cleared by a successful write" || pass "step5 mount.failed marker cleared by the next write"
	# 6. restore, verdict, non-root negative
	rm -f "$R/cfgsave-writes" "$R/config-saved"; sethost "$OLD"
	out=$("$B" --save 2>&1); [ $? -eq 0 ] && [ "$(p5host)" = "$OLD" ] && pass "step6 restored hostname persisted" || fail "restore --save failed: $(echo "$out" | tail -1)"
	t=0; while [ $t -lt 30 ] && ! "$B" --check >/dev/null 2>&1; do sleep 5; t=$((t + 5)); done
	"$B" --check >/dev/null 2>&1 && pass "step6 --check reports fresh after restore" || fail "--check not fresh after restore: $("$B" --check 2>&1)"
	nr=$(sh -c "start-stop-daemon -S -c nobody -x $B -- --check >/dev/null 2>&1; echo rc=\$?")
	case "$nr" in rc=0) fail "non-root --check succeeded" ;; *) pass "step6 non-root --check refused ($nr)" ;; esac
else
	fail "pre-#202 image: step5 marker and step6 verdict untestable"
	sethost "$OLD"
fi
exit $f
