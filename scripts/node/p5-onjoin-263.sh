#!/bin/sh
# p5-onjoin-263.sh — run ON a node (ssh sh -s <): M0 of Batman #263 against the INSTALLED batman-config-save.
# `--on-join` (joinwatch, every ~15 s while the node is open) must mount p5 at most once per change, not per tick.
# Counts p5 mounts with the ext4 superblock s_mnt_count (offset 1076, read without mounting). Touches only an
# appended comment line in authorized_keys (restored, and re-saved, before exit). Prints PASS/FAIL lines.
B=/usr/bin/batman-config-save; AK=/etc/dropbear/authorized_keys; ST=/tmp/cfgsave-onjoin.state
[ -b /dev/mmcblk0p5 ] || { echo "SKIP-REASON: no p5 on this card"; exit 3; }
[ "$(hexdump -s 1080 -n 2 -e '2/1 "%02x"' /dev/mmcblk0p5)" = 53ef ] || { echo "SKIP-REASON: p5 not seeded (not ext4)"; exit 3; }
grep -q 'cfgsave-onjoin.state' $B || { echo "FAIL installed batman-config-save has no on-join cache (pre-#263-M0 image)"; exit 1; }
mc(){ hexdump -s 1076 -n 2 -e '1/2 "%u"' /dev/mmcblk0p5; }
f=0; step(){ # $1 label, $2 expected mount delta
	a=$(mc); o=$($B --on-join 2>&1); r=$?; d=$(( $(mc) - a ))
	if [ "$d" = "$2" ] && { [ $r = 0 ] || [ $r = 4 ]; }; then echo "PASS $1: rc=$r p5 mounts +$d"
	else echo "FAIL $1: rc=$r p5 mounts +$d (want +$2) — $(echo "$o" | tail -1)"; f=1; fi; }
cp -p $AK /tmp/ak.p5dv 2>/dev/null; restore(){ [ -f /tmp/ak.p5dv ] && cp -p /tmp/ak.p5dv $AK; rm -f /tmp/ak.p5dv; }
# joinwatch calls `--on-join` on its own every ~15 s for the whole boot (rc 4 "unchanged" never latches
# /tmp/config-saved). Its compare after an invalidation is legitimate, but it makes THIS caller see the cache
# already refreshed (+0 instead of +1) — 2026-10-08 the "another writer" step failed that way on 1.5.5-wsl.8
# (s_mnt_count moved between steps with nobody in this script mounting). Pause it so this script is the only
# caller, wait out an in-flight one, and start it again on exit (joinwatch has no stop action of its own).
jw=0; if /etc/init.d/joinwatch running >/dev/null 2>&1; then /etc/init.d/joinwatch stop >/dev/null 2>&1; jw=1; fi
i=0; while pgrep -f "$B" >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
pgrep -f "$B" >/dev/null 2>&1 && { echo "FAIL a batman-config-save is still running after 30 s — not verified"; [ $jw = 1 ] && /etc/init.d/joinwatch start; exit 1; }
cleanup(){ restore; [ $jw = 1 ] && /etc/init.d/joinwatch start >/dev/null 2>&1; }
trap cleanup EXIT
[ $jw = 1 ] && echo "joinwatch paused for the test (restarted on exit)"
rm -f $ST
step "first call this boot compares once" 1
step "unchanged -> cached, no mount" 0
step "unchanged again -> cached, no mount" 0
echo "# p5-onjoin-263 $(date +%s)" >> $AK
step "identity changed -> exactly one save" 1
step "after the save -> cached again" 0
restore
step "identity restored -> exactly one save" 1
mkdir -p /tmp/p5dv && mount -t ext4 /dev/mmcblk0p5 /tmp/p5dv && umount /tmp/p5dv && rmdir /tmp/p5dv
step "another writer mounted p5 rw -> cache invalid, compare once" 1
step "-> cached again" 0
$B --save >/dev/null 2>&1; [ -f $ST ] && { echo "FAIL --save left the on-join cache in place"; f=1; } || echo "PASS --save drops the on-join cache"
step "after --save: compare once (and rotate lkg if it differs)" 1
[ $f = 0 ] && echo "ok: --on-join mounts p5 only when something changed" ; exit $f
