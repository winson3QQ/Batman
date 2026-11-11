#!/bin/bash
# tests/prov-p1/s5-slot-lock.sh <feed/batman-provision/files> — #254 P3 S5 (254-p3-impl §3.7.3): the slot lock is a
# kernel flock; readers (rundir.sh slot_busy) take a SHARED lock only inside a subshell; batman-slot's slot_lock tries
# 4 times 1 s apart (rc 14), no flock = rc 18; SHA256SUMS names (sums_check) and the copy set (boot_class).
# The PRODUCT functions are extracted verbatim and run by busybox sh with every external command forced to its busybox
# applet (the node's tools). Negative control in the test itself: the brace-group reader (the v7.9 bug) must make a
# writer in the same shell fail. Nothing checked = FAIL.
set -u
F=$(readlink -f "${1:?usage: $0 <feed/batman-provision/files>}")
SLOT=$F/usr/sbin/batman-slot; RDSH=$F/usr/lib/batman/rundir.sh
BBX=$(command -v busybox) || { echo "FAIL busybox missing"; echo "S5-SLOT-LOCK pass=0 fail=1"; exit 1; }
grep -q '^slot_busy()' "$RDSH" && grep -q '^slot_lock()' "$SLOT" || {
	echo "FAIL the product predates the S5 slot lock (no slot_busy / slot_lock): expected red until feat/254-p3 S5 lands (#254)"
	echo "S5-SLOT-LOCK pass=0 fail=1"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
for a in awk flock sleep cat grep tr sed head wc sha256sum cut mkdir rm ls chmod touch sh env id true false tail; do
	printf '#!/bin/sh\nexec %s %s "$@"\n' "$BBX" "$a" > "$T/bin/$a"; chmod +x "$T/bin/$a"
done
# Ubuntu's busybox is built without the flock applet (the node's has it: /usr/bin/flock -> busybox). Then the host's
# util-linux flock stands in: the same flock(2), the same -s / -n meaning.
if ! "$BBX" flock 2>&1 | grep -qi usage; then
	UF=$(command -v flock) || { echo "FAIL no flock applet in busybox and no util-linux flock"; echo "S5-SLOT-LOCK pass=0 fail=1"; exit 1; }
	printf '#!/bin/sh\nexec %s "$@"\n' "$UF" > "$T/bin/flock"; chmod +x "$T/bin/flock"
	echo "note: busybox has no flock applet here; using $UF"
fi
P=$T/bin
pass=0; fail=0
ok(){ if [ "$1" = "$2" ]; then pass=$((pass+1)); echo "ok   $3 (got $1)"; else fail=$((fail+1)); echo "FAIL $3 (got $1, want $2)"; fi; }
fn(){ sed -n "/^$1() {/,/^}/p" "$SLOT"; }
{ echo 'die_c() { _rc=$1; shift; echo "die_c $_rc: $*" >&2; exit "$_rc"; }'
  echo 'need_rundir() { :; }'
  fn slot_lock; fn sums_check; fn boot_class; } > "$T/slotfns.sh"
n=$(grep -c '() {' "$T/slotfns.sh"); [ "$n" = 5 ] || { echo "FAIL extracted $n functions (want 5)"; fail=$((fail+1)); }
mkdir -m 700 "$T/rd"
cat > "$T/holder.sh" <<'EOS'
exec 9>>"$LOCKF"; flock -n 9 || exit 3; sleep "$HOLD"
EOS
cat > "$T/writer.sh" <<'EOS'
. "$FNS"; LOCKF=$LOCKF; slot_lock; echo locked
EOS
run(){ PATH=$P RUNDIR="$T/rd" LOCKF="$T/rd/batman-slot.flock" FNS="$T/slotfns.sh" T="$T" "$BBX" sh -c "$1"; }
RD=". $RDSH; RUNDIR=$T/rd"

rm -f "$T/rd/batman-slot.flock"
ok "$(run "$RD; slot_busy; echo \$?")" 1 "slot_busy: no lock file -> not busy"
: > "$T/rd/batman-slot.flock"
ok "$(run "$RD; slot_busy; echo \$?")" 1 "slot_busy: idle lock file -> not busy"
ok "$(run "$RD; HOLD=3 sh $T/holder.sh & sleep 1; slot_busy; r=\$?; wait; echo \$r")" 0 "slot_busy: a writer holds the lock -> busy"
ok "$(run "$RD; PATH=/nonexistent; slot_busy; echo \$?")" 0 "slot_busy: no flock -> busy (cannot tell)"
if [ "$(id -u)" != 0 ]; then
	chmod 000 "$T/rd/batman-slot.flock"
	ok "$(run "$RD; slot_busy; echo \$?")" 0 "slot_busy: cannot open -> busy, the caller lives on"
	chmod 644 "$T/rd/batman-slot.flock"
fi
ok "$(run "$RD; slot_busy; sh $T/writer.sh 2>&1 | tail -1")" locked "same shell: slot_busy, then slot_lock -> locked (B15-MAJOR-1)"
ok "$(run "$RD; [ -e \$RUNDIR/batman-slot.flock ] && { exec 8<\$RUNDIR/batman-slot.flock; flock -s -n 8; }; sh $T/writer.sh >/dev/null 2>&1; echo \$?")" 14 \
	"negative control: a brace-group reader keeps the lock -> the writer gets rc 14"
t0=$(date +%s%3N); r=$(run "HOLD=2 sh $T/holder.sh & sleep 1; sh $T/writer.sh 2>&1 | tail -1; wait"); t1=$(date +%s%3N)
ok "$r" locked "slot_lock: a 2 s holder -> locked after a retry ($((t1-t0)) ms)"
t0=$(date +%s%3N); r=$(run "HOLD=6 sh $T/holder.sh & sleep 1; sh $T/writer.sh >/dev/null 2>&1; echo \$?; wait"); t1=$(date +%s%3N)
ok "$r" 14 "slot_lock: a 6 s holder -> rc 14 ($((t1-t0)) ms, about 4 s)"
ok "$(run "PATH=/nonexistent; . $T/slotfns.sh; LOCKF=\$LOCKF; (slot_lock) 2>/dev/null; echo \$?")" 18 "slot_lock: no flock -> rc 18"

# sums_check: what build-ab-payload.sh produces (kernel8 / start* / fixup* / dtbs / overlays incl. README, root.squashfs)
h=$(printf '%064d' 0 | tr 0 a)
for n in boot/kernel8.img boot/start4.elf boot/start4cd.elf boot/fixup4.dat boot/fixup4cd.dat boot/bcm2711-rpi-4-b.dtb \
         boot/bcm2711-rpi-cm4.dtb boot/overlays/vc4-kms-v3d.dtbo boot/overlays/README boot/overlays/hat_map.dtb root.squashfs; do
	echo "$h  $n"; done > "$T/sums.ok"
ok "$(run ". $T/slotfns.sh; sums_check $T/sums.ok >/dev/null; echo \$?")" 0 "sums_check: a payload's names accepted"
for c in "boot/autoboot.txt" "boot/AutoBoot.TXT" "boot/config.txt" "boot/distroconfig.txt" "boot/cmdline.txt" "boot/bootcode.bin" \
         "boot/BATMAN-VERIFIED" "boot/batman-bad" "boot/..x" "boot/.hidden" "boot/sub/x" "boot/overlays/a/b" "../etc/shadow" "boot/a b"; do
	{ cat "$T/sums.ok"; echo "$h  $c"; } > "$T/sums.bad"
	ok "$(run ". $T/slotfns.sh; sums_check $T/sums.bad >/dev/null; echo \$?")" 1 "sums_check refuses '$c'"
done
{ cat "$T/sums.ok"; echo "$h  boot/KERNEL8.img"; } > "$T/sums.bad"
ok "$(run ". $T/slotfns.sh; sums_check $T/sums.bad >/dev/null; echo \$?")" 1 "sums_check refuses a case-folded duplicate"
{ cat "$T/sums.ok"; echo "${h%a}  boot/x.dtb"; } > "$T/sums.bad"
ok "$(run ". $T/slotfns.sh; sums_check $T/sums.bad >/dev/null; echo \$?")" 1 "sums_check refuses a 63-hex line"
for c in boot/kernel8.img boot/start4.elf boot/fixup4cd.dat boot/bcm2711-rpi-4-b.dtb boot/overlays/vc4-kms-v3d.dtbo boot/overlays/README; do
	ok "$(run ". $T/slotfns.sh; boot_class $c; echo \$?")" 0 "boot_class copies $c"
done
for c in boot/config.txt boot/cmdline.txt boot/bootcode.bin boot/autoboot.txt boot/sub/x.dtb boot/BATMAN-BAD root.squashfs; do
	ok "$(run ". $T/slotfns.sh; boot_class $c; echo \$?")" 1 "boot_class skips $c"
done
echo "S5-SLOT-LOCK pass=$pass fail=$fail"
[ "$fail" = 0 ] && [ "$pass" -gt 0 ]
