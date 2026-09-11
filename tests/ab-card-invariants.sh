#!/bin/bash
# Invariants for the GPT A/B card produced by scripts/build-gpt-ab-card.sh.
#
# Builds a real card on a loop device from a synthetic source tree, then asserts the
# properties that #133 established on hardware. These are the ones that, when broken,
# fail *silently* — the node still boots, so no health check catches it:
#
#   * boot_partition is the firmware's index, not the GPT index (#133)
#   * cmdline uses a BOUNDED rootwait plus panic=, never a bare rootwait (#133)
#
# Runs in CI; needs sudo, losetup, gdisk, dosfstools, squashfs-tools, parted, rsync.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
LOOP=""
PASS=0; FAIL=0

cleanup() {
  [ -n "$LOOP" ] && { sudo umount "${LOOP}p"* 2>/dev/null || true; sudo losetup -d "$LOOP" 2>/dev/null || true; }
  sudo rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: got '$2', want '$3'"; fi; }

echo "=== build a synthetic source tree ==="
mkdir -p "$WORK/src/p1-bootA" "$WORK/src/p3-batdata" "$WORK/rootfs/etc"
echo "dummy openmanet rootfs" > "$WORK/rootfs/etc/openwrt_release"
mksquashfs "$WORK/rootfs" "$WORK/src/p2-rootfs-squashfs.img" -comp xz -b 262144 -no-xattrs -all-root -noappend -nopad -quiet
mkdir -p "$WORK/boot"
for f in start4.elf fixup4.dat kernel8.img config.txt bcm2711-rpi-4-b.dtb; do echo "$f placeholder" > "$WORK/boot/$f"; done
echo "placeholder" > "$WORK/boot/cmdline.txt"
tar -C "$WORK/boot" -cf "$WORK/src/p1-bootA/bootA.tar" .
echo "payload" > "$WORK/src/p3-batdata/keepme"

echo "=== attach a 5 GiB loop device ==="
truncate -s 5G "$WORK/card.img"
LOOP=$(sudo losetup -Pf --show "$WORK/card.img")
SECTORS=$(sudo blockdev --getsz "$LOOP")
echo "loop=$LOOP sectors=$SECTORS"

echo "=== run the real build script ==="
DEV="$LOOP" SRC="$WORK/src" EXPECT_SECTORS="$SECTORS" bash "$REPO/scripts/build-gpt-ab-card.sh" >"$WORK/build.log" 2>&1 \
  || { echo "build script FAILED:"; tail -30 "$WORK/build.log"; exit 1; }
grep -q "BUILD DONE" "$WORK/build.log" || { echo "build did not complete"; tail -30 "$WORK/build.log"; exit 1; }
echo "build ok"

sudo mkdir -p "$WORK/a" "$WORK/b"
sudo mount -o ro "${LOOP}p1" "$WORK/a"
sudo mount -o ro "${LOOP}p3" "$WORK/b"

echo
echo "=== A. autoboot.txt lives on bootA only ==="
[ -f "$WORK/a/autoboot.txt" ] && ok "bootA has autoboot.txt" || bad "bootA has no autoboot.txt"
[ -f "$WORK/b/autoboot.txt" ] && bad "bootB must NOT carry autoboot.txt" || ok "bootB has no autoboot.txt"

echo
echo "=== B. boot_partition is the FIRMWARE index, not the GPT index (#133) ==="
# Recompute independently: count FAT partitions in GPT order.
fw_index() {
  local target=$1 n=0 i
  for i in $(sudo sgdisk -p "$LOOP" | awk '/^ *[0-9]+ +[0-9]+/{print $1}' | sort -n); do
    [ "$(sudo blkid -p -s TYPE -o value "${LOOP}p${i}" 2>/dev/null)" = vfat ] || continue
    n=$((n+1)); [ "$i" = "$target" ] && { echo "$n"; return; }
  done
  echo "NONE"
}
WANT_A=$(fw_index 1); WANT_B=$(fw_index 3)
GOT_A=$(awk '/^\[all\]/{s=1;next}/^\[/{s=0}s&&/^boot_partition=/{sub(/.*=/,"");print;exit}' "$WORK/a/autoboot.txt")
GOT_B=$(awk '/^\[tryboot\]/{s=1;next}/^\[/{s=0}s&&/^boot_partition=/{sub(/.*=/,"");print;exit}' "$WORK/a/autoboot.txt")
check "[all] boot_partition == firmware index of bootA" "$GOT_A" "$WANT_A"
check "[tryboot] boot_partition == firmware index of bootB" "$GOT_B" "$WANT_B"
if [ "$GOT_B" = 3 ]; then
  bad "[tryboot] boot_partition=3 is the GPT index — the firmware counts only bootable FAT partitions (#133)"
else
  ok "[tryboot] is not the GPT index"
fi
grep -q '^tryboot_a_b=1' "$WORK/a/autoboot.txt" && ok "tryboot_a_b=1 present" || bad "tryboot_a_b=1 missing — A/B switching is inert"
# The artifact checks above cannot tell a derived number from a hard-coded one that happens
# to be right for today's layout. Guard the source too: a hard-coded value survives a layout
# change silently, and the symptom is a node that boots the OLD slot and looks healthy.
if grep -q 'fw_boot_partition' "$REPO/scripts/build-gpt-ab-card.sh"; then
  ok "build script derives boot_partition from the layout"
else
  bad "build script hard-codes boot_partition — derive it from the FAT partition order (#133)"
fi

echo
echo "=== C. cmdline: bounded rootwait + panic (#133) ==="
for slot in a b; do
  S=$([ $slot = a ] && echo A || echo B)
  CL=$(cat "$WORK/$slot/cmdline.txt")
  if grep -Eq '(^| )rootwait=[1-9][0-9]*( |$)' <<<"$CL"; then ok "slot $S has a bounded rootwait=N"
  else bad "slot $S lacks rootwait=N — a bare rootwait waits forever and a bad slot becomes a silent dead node (#133)"; fi
  if grep -Eq '(^| )rootwait( |$)' <<<"$CL"; then bad "slot $S has a BARE rootwait (#133)"; else ok "slot $S has no bare rootwait"; fi
  if grep -Eq '(^| )panic=[1-9][0-9]*( |$)' <<<"$CL"; then ok "slot $S has panic=N"
  else bad "slot $S lacks panic=N — without it a failed slot never reboots itself (#133)"; fi
  if grep -q "batman_slot=$S" <<<"$CL"; then ok "slot $S carries batman_slot=$S"; else bad "slot $S missing its batman_slot marker"; fi
done
A_ROOT=$(grep -o 'root=PARTUUID=[^ ]*' "$WORK/a/cmdline.txt")
B_ROOT=$(grep -o 'root=PARTUUID=[^ ]*' "$WORK/b/cmdline.txt")
[ "$A_ROOT" != "$B_ROOT" ] && ok "slots point at different rootfs ($A_ROOT vs $B_ROOT)" || bad "both slots point at the same rootfs"

echo
echo "=== D. FAT built with mkfs, not dd (#106) ==="
VA=$(sudo blkid -s UUID -o value "${LOOP}p1"); VB=$(sudo blkid -s UUID -o value "${LOOP}p3")
[ "$VA" != "$VB" ] && ok "boot slots have distinct volume ids ($VA / $VB)" || bad "duplicate FAT volume id — boot slots were dd-cloned (#106)"
for p in 1 3; do
  START=$(sudo cat /sys/class/block/$(basename ${LOOP}p$p)/start)
  HID=$(sudo dd if=${LOOP}p$p bs=512 count=1 2>/dev/null | od -A none -t u4 -j 28 -N 4 | tr -d ' ')
  check "p$p hidden_sectors matches its start LBA" "$HID" "$START"
done

echo
echo "=== E. both root slots hold the same image ==="
SB=$(unsquashfs -s "$WORK/src/p2-rootfs-squashfs.img" | awk '/Filesystem size/{print $3}')
# head -c closes the pipe early, so dd takes SIGPIPE; pipefail would abort the script.
slot_md5() { ( set +o pipefail; sudo dd if="$1" bs=1M count=64 2>/dev/null | head -c "$SB" | md5sum | cut -d' ' -f1 ); }
MA=$(slot_md5 "${LOOP}p2")
MB=$(slot_md5 "${LOOP}p4")
check "rootA and rootB are byte-identical" "$MA" "$MB"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
