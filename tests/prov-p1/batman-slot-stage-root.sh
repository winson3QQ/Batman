#!/bin/bash
# tests/prov-p1/batman-slot-stage-root.sh <batman-slot> <prov-lock.sh> — #254 claim-lock fix v9.1 §5.6: the stdout of
# `batman-slot stage-root` is exactly one line, the target root device (platform-ab stage 2 captures it as the device).
# Black box on a REAL A/B card (scripts/build-gpt-ab-card.sh on a loop device): the whole batman-slot runs, only
# its fixed paths are pointed at a sandbox — DISK -> the loop device, /boot -> the card's p1, /proc/cmdline and
# /proc/device-tree -> sandbox files (active slot A, SoC bcm2711), /usr/lib/batman, /opt/batdata and the run dir
# /tmp/run/batman -> sandbox
# copies. Nothing is stubbed: vcmailbox / vcgencmd / batman-config-save are absent on this host, and batman-slot
# itself takes its stage-2 path there: the tryboot disarm warns and returns, and the freshness gate reads the stage-1
# verdict, which this test writes as stage 1 would (skip:unseeded / fresh) — the --check itself is NOT exercised here
# (chain 1 7.2 on a node covers them). dd / mount / sysfs act on the loop device only.
# Branches: L44 (unseeded + unclaimed record), seeded, allow-unseeded override, claimed + unseeded (must die); then
# prov-unit-gate's matrix (18 cases). Negative controls: tests/prov-p1/gate-negatives.sh.
# Negative control: a batman-slot whose L44 note goes to stdout (4ebfd6f / 1.5.14-wsl.2) FAILs the L44 branch.
# Root (losetup, mkfs, mount); needs gdisk, dosfstools, squashfs-tools, parted, e2fsprogs. Zero cases -> FAIL.
set -u
BS=$(readlink -f "${1:?usage: $0 <batman-slot> <prov-lock.sh>}"); LIB=$(readlink -f "${2:?}")
[ -f "$BS" ] && [ -f "$LIB" ] || { echo "FAIL missing $BS or $LIB"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (loop device)"; exit 1; }
REPO=$(cd "$(dirname "$0")/../.." && pwd); LIBDIR=$(dirname "$LIB")
T=$(mktemp -d); LOOP=""; cases=0; fails=0
cleanup(){ umount "$T/boot" "$T/p5" 2>/dev/null; [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
ok(){ echo "ok   $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }

# ---- the card (same synthetic source as tests/ab-card-invariants.sh)
mkdir -p "$T/src/p1-bootA" "$T/src/p3-batdata" "$T/rootfs/etc" "$T/bootsrc"
echo "dummy rootfs" > "$T/rootfs/etc/openwrt_release"
mksquashfs "$T/rootfs" "$T/src/p2-rootfs-squashfs.img" -comp xz -b 262144 -no-xattrs -all-root -noappend -nopad -quiet
for f in start4.elf fixup4.dat kernel8.img config.txt bcm2711-rpi-4-b.dtb cmdline.txt; do echo "$f placeholder" > "$T/bootsrc/$f"; done
tar -C "$T/bootsrc" -cf "$T/src/p1-bootA/bootA.tar" .
echo payload > "$T/src/p3-batdata/keepme"
truncate -s 5G "$T/card.img"; LOOP=$(losetup -Pf --show "$T/card.img") || { echo "FAIL losetup"; exit 1; }
DEV="$LOOP" SRC="$T/src" EXPECT_SECTORS="$(blockdev --getsz "$LOOP")" SOC=bcm2711 bash "$REPO/scripts/build-gpt-ab-card.sh" > "$T/build.log" 2>&1 \
	&& grep -q "BUILD DONE" "$T/build.log" || { echo "FAIL card build: $(tail -3 "$T/build.log" | tr '\n' ' ')"; exit 1; }
mkdir -p "$T/boot" "$T/p5"; mount "${LOOP}p1" "$T/boot" || { echo "FAIL mount p1"; exit 1; }

# ---- the sandbox: fixed paths of batman-slot and its libraries point here
mkdir -p "$T/dt" "$T/lib" "$T/opt/state" "$T/opt/log"; mkdir -m 755 "$T/run"   # the run dir (#280): its parent root-owned, not group/other-writable
echo "console=serial0 root=PARTUUID=3276af79-0000-4000-8000-000000000002 batman_slot=A" > "$T/cmdline"
printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$T/dt/compatible"
rw(){ sed -e "s#^DISK=/dev/mmcblk0\$#DISK=$LOOP#" -e "s#^BOOTMNT=/boot #BOOTMNT=$T/boot #" -e "s#/proc/cmdline#$T/cmdline#g" \
	-e "s#/proc/device-tree#$T/dt#g" -e "s#/usr/lib/batman/#$T/lib/#g" -e "s#/opt/batdata#$T/opt#g" -e "s#/tmp/run/batman#$T/run/batman#g" "$1"; }
for l in rundir.sh otatrace.sh; do [ -f "$LIBDIR/$l" ] && rw "$LIBDIR/$l" > "$T/lib/$l"; done
rw "$LIB" > "$T/lib/prov-lock.sh"
rw "$BS" > "$T/batman-slot"; chmod 755 "$T/batman-slot"
grep -q "^DISK=$LOOP\$" "$T/batman-slot" && grep -q "^BOOTMNT=$T/boot " "$T/batman-slot" || { echo "FAIL path rewrite did not apply (batman-slot layout changed?)"; exit 1; }
# the streamed payload stage-root expects: boot files + SHA256SUMS (with a root.squashfs entry) + metadata, no rootfs
P=$T/payload; mkdir -p "$P/boot"; cp "$T/bootsrc/"* "$P/boot/"
( cd "$P" && sha256sum boot/* > SHA256SUMS && echo "$(sha256sum < "$T/src/p2-rootfs-squashfs.img" | cut -c1-64)  root.squashfs" >> SHA256SUMS )
printf 'board=ekh-bcm2711\nversion=test\nsize=%s\n' "$(wc -c < "$T/src/p2-rootfs-squashfs.img")" > "$P/metadata"

# p5 <unseeded-unclaimed|seeded|empty|unseeded-claimed>
p5(){ mkfs.ext4 -q -F -L batconfig "${LOOP}p5" && mount "${LOOP}p5" "$T/p5" || return 1
	case "$1" in
		seeded) : > "$T/p5/.seeded" ;;
		unseeded-unclaimed|unseeded-claimed) s=${1#unseeded-}; printf 'cbor-%s' "$s" > "$T/p5/prov.cbor"
			echo "v=1 state=$s gen=2 sha=$(sha256sum < "$T/p5/prov.cbor" | cut -c1-64)" > "$T/p5/prov.meta" ;;
	esac; umount "$T/p5"; }
# the stage-1 p5 verdict stage 2 reads (batman-slot p5_verdict_gate: $RUNDIR/p5-check.rc, "<verdict> <uptime>", root,
# <= 600 s old) — written here as stage 1 would for that p5: skip:unseeded (L44 / override), fresh (seeded)
verdict(){ { [ -d "$T/run/batman" ] || mkdir -m 700 "$T/run/batman"; } && ( umask 077; echo "$1 $(cut -d. -f1 /proc/uptime)" > "$T/run/batman/p5-check.rc" ); }
# run [ENV=v ...]: stage-root as root with a clean env; stdout / stderr / rc kept apart
run(){ env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@" sh "$T/batman-slot" stage-root "$P" > "$T/out" 2> "$T/err"; RC=$?; }
lines(){ grep -c '' "$T/out"; }
expect(){ cases=$((cases + 1)); if eval "$2"; then ok "$1"; else no "$1 — rc=$RC stdout=[$(tr '\n' '|' < "$T/out")] stderr=[$(tail -3 "$T/err" | tr '\n' '|')]"; fi; }
# shellcheck disable=SC2034  # read inside the eval'd conditions
TGT=${LOOP}p4   # active A -> target B's root

p5 unseeded-unclaimed || { echo "FAIL p5 setup"; exit 1; }; verdict skip:unseeded; run
expect "L44 (unseeded + unclaimed): rc 0, stdout is exactly the target device" '[ "$RC" = 0 ] && [ "$(lines)" = 1 ] && [ "$(cat "$T/out")" = "$TGT" ]'
expect "L44: the note is on stderr" 'grep -q "holds an unclaimed provisioning record — allowed (#254 L44)" "$T/err"'
p5 seeded; verdict fresh; run
expect "seeded p5: rc 0, stdout is exactly the target device, no L44 note" '[ "$RC" = 0 ] && [ "$(lines)" = 1 ] && [ "$(cat "$T/out")" = "$TGT" ] && ! grep -q "L44" "$T/err"'
p5 empty; verdict skip:unseeded; run BATMAN_ALLOW_UNSEEDED=1
expect "allow-unseeded override: rc 0, stdout is exactly the target device" '[ "$RC" = 0 ] && [ "$(lines)" = 1 ] && [ "$(cat "$T/out")" = "$TGT" ]'
p5 unseeded-claimed; verdict skip:unseeded; run
expect "claimed + unseeded: refused (rc != 0), nothing on stdout, 'not seeded' on stderr" '[ "$RC" != 0 ] && [ "$(lines)" = 0 ] && grep -q "is not seeded" "$T/err"'
# ---- prov-unit-gate (254-p1-impl §5.1): .seeded {0,1} x prov.meta {valid, malformed, sha wrong} x state {unclaimed,
# claimed, member}. Allowed iff seeded, or the record is valid AND unclaimed (L44); every other unseeded p5 is refused.
pm(){	# <seeded 0|1> <ok|bad|badsha> <state>
	mkfs.ext4 -q -F -L batconfig "${LOOP}p5" && mount "${LOOP}p5" "$T/p5" || return 1
	[ "$1" = 1 ] && : > "$T/p5/.seeded"
	printf "cbor-%s-%s" "$3" "$2" > "$T/p5/prov.cbor"; h=$(sha256sum < "$T/p5/prov.cbor" | cut -c1-64)
	case "$2" in ok) echo "v=1 state=$3 gen=2 sha=$h" ;; bad) echo "v=1 state=$3! gen=2 sha=$h" ;; badsha) echo "v=1 state=$3 gen=2 sha=$(printf %064d 0)" ;; esac > "$T/p5/prov.meta"
	umount "$T/p5"; }
for sd in 0 1; do for mk in ok bad badsha; do for st in unclaimed claimed member; do
	pm $sd $mk $st || { no "gate p5 setup"; continue; }
	if [ $sd = 1 ]; then verdict fresh; else verdict skip:unseeded; fi; run
	if [ $sd = 1 ] || { [ $mk = ok ] && [ $st = unclaimed ]; }; then
		expect "gate seeded=$sd meta=$mk state=$st: allowed" '[ "$RC" = 0 ] && [ "$(lines)" = 1 ] && [ "$(cat "$T/out")" = "$TGT" ]'
	else
		expect "gate seeded=$sd meta=$mk state=$st: refused" '[ "$RC" != 0 ] && [ "$(lines)" = 0 ] && grep -q "is not seeded" "$T/err"'
	fi
done; done; done
echo "BATMAN-SLOT-STAGE-ROOT cases=$cases fails=$fails"; [ "$cases" -gt 0 ] && [ "$fails" = 0 ]
