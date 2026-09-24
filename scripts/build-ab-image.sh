#!/bin/bash
# build-ab-image.sh — assemble a DISTRIBUTABLE GPT A/B .img (#201/#133) into a loop FILE.
#
# The sibling scripts/build-gpt-ab-card.sh partitions a REAL device and lets p6(data) run to the
# device end, so it can only be run on the physical target. That is why the historical A/B
# distributable (ab-fleet.img.gz) was hand-made and shipped a fixed tiny p6 that never grew (#201).
# This script builds a size-portable .img instead: a SMALL fixed p6, grown to fill the card on
# first boot by 95-batman-storage step 1b/3b (#201). Reproducible: same inputs -> same image.
#
# Layout matches build-gpt-ab-card.sh exactly (bootA/rootA/bootB/rootB/[300M rescue gap]/config/
# data) so a card flashed with this image is identical to one built on-device, except p6 is small
# until first boot.
#
# Inputs:
#   SRC_IMG   a DECOMPRESSED single-slot OpenMANET spi sysupgrade image (p1=boot FAT, p2=rootfs
#             squashfs). We source the boot files and the rootfs squashfs from it, so the A/B image
#             carries the exact same build (must be a build that INCLUDES the #201 fix).
#   OUT       output .img path (a matching .img.gz is written next to it)
#   P6_MB     size of the pre-made data partition (default 200; first boot grows it to fill)
# Run as root (losetup/mount/mkfs). Designed for the WSL build host.
set -euo pipefail

SRC_IMG=${SRC_IMG:-}   # optional when BOTH ROOTFS and BOOTDIR are supplied
OUT=${OUT:?set OUT to the output .img path}
P6_MB=${P6_MB:-200}
if [ -n "$SRC_IMG" ] && [ ! -f "$SRC_IMG" ]; then echo "SRC_IMG set but not found: $SRC_IMG"; exit 1; fi

# Deterministic PARTUUIDs (same scheme as build-gpt-ab-card.sh, traceable to the original card).
G1=3276af79-0000-4000-8000-000000000001   # bootA
G2=3276af79-0000-4000-8000-000000000002   # rootA
G3=3276af79-0000-4000-8000-000000000003   # bootB
G4=3276af79-0000-4000-8000-000000000004   # rootB
G5=3276af79-0000-4000-8000-000000000005   # config
G6=3276af79-0000-4000-8000-000000000006   # data

say(){ echo; echo "=== $* ==="; }
cleanup(){
  set +e
  [ -n "${MB:-}" ] && mountpoint -q "$MB" && umount "$MB"
  [ -n "${MSA:-}" ] && mountpoint -q "$MSA" && umount "$MSA"
  [ -n "${MSB:-}" ] && mountpoint -q "$MSB" && umount "$MSB"
  [ -n "${SLO:-}" ] && losetup -d "$SLO" 2>/dev/null
  [ -n "${OLO:-}" ] && losetup -d "$OLO" 2>/dev/null
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}
trap cleanup EXIT

TMP=$(mktemp -d)

# --- 1. boot files: from BOOTDIR if given, else harvest from the source image's p1 ------------
mkdir -p "$TMP/boot"
if [ -n "${BOOTDIR:-}" ]; then
	[ -d "$BOOTDIR" ] || { echo "BOOTDIR not found: $BOOTDIR"; exit 1; }
	cp -a "$BOOTDIR"/. "$TMP/boot/"
	echo "boot files from BOOTDIR $BOOTDIR"
else
	say "loop-mount source image ${SRC_IMG:-<unset>} for boot files"
	[ -f "${SRC_IMG:-}" ] || { echo "need BOOTDIR or a valid SRC_IMG for boot files"; exit 1; }
	SLO=$(losetup --show -fP "$SRC_IMG"); partprobe "$SLO" 2>/dev/null; sleep 1
	echo "src loop=$SLO"
	[ -b "${SLO}p1" ] || { echo "source image has no p1"; exit 1; }
	MSA=$(mktemp -d)
	mount -o ro "${SLO}p1" "$MSA"
	cp -a "$MSA"/. "$TMP/boot/"
	umount "$MSA"; rmdir "$MSA"; MSA=""
fi
# cmdline.txt/autoboot.txt are regenerated for A/B; drop any single-slot ones we copied.
rm -f "$TMP/boot/cmdline.txt" "$TMP/boot/autoboot.txt"
echo "boot files: $(ls "$TMP/boot" | tr '\n' ' ')"

# rootfs squashfs: PREFER a pristine ROOTFS file (build_dir/.../root.squashfs) over extracting
# from the source image's p2 — a gzip'd release .img can be a few hundred bytes short of 512
# alignment ("trailing garbage"), which truncates the squashfs tail and makes root unmountable
# (kernel panic: "No filesystem could mount root"). The pristine build_dir squashfs is always
# complete (size == superblock bytes_used). Fall back to p2 extraction only when ROOTFS is unset.
if [ -n "${ROOTFS:-}" ]; then
	[ -f "$ROOTFS" ] || { echo "ROOTFS not found: $ROOTFS"; exit 1; }
	m=$(od -An -tx4 -N4 "$ROOTFS" | tr -d ' \n')
	[ "$m" = 73717368 ] || { echo "ROOTFS is not squashfs (magic=$m)"; exit 1; }
	bu=$(od -An -tu8 -j40 -N8 "$ROOTFS" | tr -d ' \n')
	fs=$(stat -c %s "$ROOTFS")
	[ "$bu" = "$fs" ] || { echo "ROOTFS incomplete: bytes_used=$bu != file size=$fs"; exit 1; }
	cp "$ROOTFS" "$TMP/root.squashfs"
	SQUASH_BYTES=$fs
	echo "using pristine ROOTFS $ROOTFS ($SQUASH_BYTES bytes, complete)"
else
	magic=$(od -An -tx4 -N4 "${SLO}p2" | tr -d ' \n')
	[ "$magic" = 73717368 ] || { echo "p2 is not squashfs (magic=$magic)"; exit 1; }
	SQUASH_BYTES=$(od -An -tu8 -j40 -N8 "${SLO}p2" | tr -d ' \n')
	[ "$SQUASH_BYTES" -gt 0 ] 2>/dev/null || { echo "bad squashfs size"; exit 1; }
	psz=$(cat "/sys/class/block/$(basename "$(readlink -f "${SLO}p2")")/size" 2>/dev/null)
	[ -n "$psz" ] && [ "$SQUASH_BYTES" -le "$((psz * 512))" ] || { echo "p2 squashfs ($SQUASH_BYTES) exceeds partition ($((psz*512))) — source image truncated; pass ROOTFS instead"; exit 1; }
	echo "squashfs bytes = $SQUASH_BYTES (extracted from source p2)"
	dd if="${SLO}p2" of="$TMP/root.squashfs" bs=1M count="$SQUASH_BYTES" iflag=count_bytes status=none
fi
[ -n "${SLO:-}" ] && { losetup -d "$SLO"; SLO=""; } || true

# --- 2. create the output image file and GPT (small p6) ----------------------------------------
TOTAL_MB=$(( 4016 + P6_MB + 2 ))
say "create ${TOTAL_MB} MiB image $OUT"
rm -f "$OUT"
truncate -s "${TOTAL_MB}M" "$OUT"

say "GPT (bootA/rootA/bootB/rootB/[300M rescue gap]/config/data ${P6_MB}M)"
sgdisk -a 2048 \
  -n 1:4M:+64M      -t 1:0700 -c 1:bootA  -u 1:$G1 \
  -n 2:68M:+1536M   -t 2:8300 -c 2:rootA  -u 2:$G2 \
  -n 3:1604M:+64M   -t 3:0700 -c 3:bootB  -u 3:$G3 \
  -n 4:1668M:+1536M -t 4:8300 -c 4:rootB  -u 4:$G4 \
  -n 5:3504M:+512M  -t 5:8300 -c 5:config -u 5:$G5 \
  -n "6:4016M:+${P6_MB}M" -t 6:8300 -c 6:data -u 6:$G6 \
  "$OUT"

OLO=$(losetup --show -fP "$OUT")
echo "out loop=$OLO"
for i in 1 2 3 4 5 6; do [ -b "${OLO}p${i}" ] || { echo "missing ${OLO}p${i}"; exit 1; }; done

# --- 3. boot slots: mkfs.vfat + populate -------------------------------------------------------
say "mkfs.vfat boot slots + populate"
mkfs.vfat -F 16 -n BOOTA -i 0xBA710001 "${OLO}p1" >/dev/null
mkfs.vfat -F 16 -n BOOTB -i 0xBA710003 "${OLO}p3" >/dev/null
MB=$(mktemp -d)
for slot in A B; do
  if [ "$slot" = A ]; then dev="${OLO}p1"; g=$G2; else dev="${OLO}p3"; g=$G4; fi
  mount "$dev" "$MB"
  cp -a "$TMP/boot/." "$MB/"
  # rootwait=20 panic=10 (bounded wait + auto-return to the other slot on a dead slot — see
  # build-gpt-ab-card.sh). PARTUUID-rooted so it survives partition-table rewrites.
  echo "console=serial0 console=ttyUSB0,115200 console=tty1 rootfstype=squashfs,ext4 rootwait=20 panic=10 root=PARTUUID=$g batman_slot=$slot" > "$MB/cmdline.txt"
  sync; umount "$MB"
done
# autoboot.txt on bootA (first FAT partition): firmware boot_partition is the FAT-only index, so
# bootA(gpt1)=1, bootB(gpt3)=2 (NOT 3) — bench-verified in #133.
mount "${OLO}p1" "$MB"
printf '%s\n' '[all]' 'tryboot_a_b=1' 'boot_partition=1' '' '[tryboot]' 'boot_partition=2' > "$MB/autoboot.txt"
sync; umount "$MB"; rmdir "$MB"; MB=""

# --- 4. rootfs slots: zero then write the squashfs to each ------------------------------------
SQUASH_MB=$(( (SQUASH_BYTES + 1048575) / 1048576 ))
ZERO_MB=$(( SQUASH_MB + 64 ))
say "rootfs slots: zero ${ZERO_MB}M then write ${SQUASH_BYTES}-byte squashfs to p2 & p4"
for p in 2 4; do
  dd if=/dev/zero of="${OLO}p${p}" bs=1M count=$ZERO_MB status=none conv=fsync
  dd if="$TMP/root.squashfs" of="${OLO}p${p}" bs=1M count="$SQUASH_BYTES" iflag=count_bytes status=none conv=fsync
done

# --- 5. config + data: ext4 (data stays small; grown on first boot by #201) --------------------
say "mkfs.ext4 config + data (data ${P6_MB}M, first-boot grows to fill — #201)"
mkfs.ext4 -q -F -L batconfig "${OLO}p5"
mkfs.ext4 -q -F -L batdata   "${OLO}p6"

sync
say "final layout"
sgdisk -p "$OUT"
losetup -d "$OLO"; OLO=""

say "gzip -> ${OUT}.gz"
gzip -1 -kf "$OUT"
ls -la "$OUT" "${OUT}.gz"
echo
echo "BUILD-AB-IMAGE DONE"
