#!/bin/bash
#
# flash-card.sh - write an OpenMANET image to an SD card and actually clear it.
#
# `dd` alone is not enough. An OpenWrt squashfs sysupgrade image contains only
# the boot partition and the squashfs; everything after that inside the rootfs
# partition is the rootfs_data overlay, which dd never touches. The device then
# boots with its entire previous configuration restored while every check you
# would normally run comes back green. See docs/flashing-and-recovery.md.
#
# So this script writes the image, then zeroes from the exact end of the
# squashfs to the end of the partition, and verifies the result mounts.
#
#   usage: flash-card.sh /dev/mmcblk0 [image.img.gz]
#
# With no image argument it downloads the pinned release with `gh`.
#
set -euo pipefail

VERSION="1.7.0"
ASSET="openmanet-${VERSION}-rpi4-mm6108-spi-squashfs-sysupgrade.img.gz"
REPO="OpenMANET/firmware"

DEV="${1:-}"
IMG="${2:-}"

die() { echo "error: $*" >&2; exit 1; }

[ -n "$DEV" ] || die "usage: $0 /dev/mmcblk0 [image.img.gz]"
[ -b "$DEV" ] || die "$DEV is not a block device"

# --------------------------------------------------------------- safety check
# Refuse to write to anything that is currently mounted as a system directory.
# Getting this wrong costs you the machine you are working from.
while read -r src mnt _; do
	case "$src" in
		"$DEV"*)
			case "$mnt" in
				/|/boot|/boot/*|/home|/usr|/var)
					die "$DEV holds $mnt — refusing" ;;
			esac ;;
	esac
done < /proc/mounts

echo "target : $DEV  ($(lsblk -dno SIZE "$DEV" | tr -d ' '), $(lsblk -dno MODEL "$DEV" | tr -d ' ' || true))"
lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT "$DEV" | sed 's/^/         /'
read -rp "This erases it completely. Type YES to continue: " ok
[ "$ok" = YES ] || die "aborted"

# ------------------------------------------------------------------ get image
if [ -z "$IMG" ]; then
	IMG="$ASSET"
	if [ ! -f "$IMG" ]; then
		command -v gh >/dev/null || die "gh not found; pass an image path instead"
		echo "==> downloading $ASSET"
		gh release download "$VERSION" --repo "$REPO" --pattern "$ASSET" --clobber
	fi
fi
[ -f "$IMG" ] || die "image not found: $IMG"

# `gzip -t` reports "trailing garbage ignored" on these images; that is normal,
# the release appends metadata after the gzip stream. Only the exit status here
# would indicate real corruption, and zcat stops at the stream end regardless.
gzip -t "$IMG" 2>/dev/null || true
RAW_SIZE=$(zcat "$IMG" | wc -c)
echo "image  : $IMG  -> $RAW_SIZE bytes uncompressed"

# ---------------------------------------------------------------------- write
for p in "$DEV"?*; do sudo umount "$p" 2>/dev/null || true; done

echo "==> writing image"
zcat "$IMG" | sudo dd of="$DEV" bs=4M conv=fsync status=progress
sync
sudo partprobe "$DEV" 2>/dev/null || true
sleep 2

# ---------------------------------------------------------- wipe the overlay
# The end of the squashfs is the rootfs partition's start plus the squashfs
# superblock's bytes_used field, at offset 0x28. Both are read from the card
# rather than hardcoded, so this keeps working when the image layout changes.
P2="${DEV}p2"; [ -b "$P2" ] || P2="${DEV}2"
[ -b "$P2" ] || die "no second partition after flashing"

P2_START_SECTORS=$(cat "/sys/class/block/$(basename "$P2")/start")
P2_SIZE_SECTORS=$(cat "/sys/class/block/$(basename "$P2")/size")
P2_START=$(( P2_START_SECTORS * 512 ))
P2_END=$(( (P2_START_SECTORS + P2_SIZE_SECTORS) * 512 ))
BYTES_USED=$(sudo dd if="$P2" bs=1 skip=40 count=8 2>/dev/null | od -An -tu8 | tr -d ' ')
SQEND=$(( P2_START + BYTES_USED ))

echo "==> layout"
printf '         %-14s %s\n' "p2 start"  "$P2_START"
printf '         %-14s %s\n' "squashfs"  "$BYTES_USED"
printf '         %-14s %s\n' "squashfs end" "$SQEND"
printf '         %-14s %s\n' "p2 end"    "$P2_END"
printf '         %-14s %s MiB\n' "to wipe" "$(( (P2_END - SQEND) / 1048576 ))"

[ "$SQEND" -gt "$P2_START" ] || die "bad squashfs size — refusing to wipe"
[ "$SQEND" -lt "$P2_END" ]   || die "squashfs larger than partition?"

# seek MUST be byte-exact. Using MiB-granular seek starts inside the squashfs
# and truncates its tail; the card then fails with "unable to read id index
# table" and looks like a bad write.
echo "==> zeroing overlay region"
sudo dd if=/dev/zero of="$DEV" bs=1M seek="$SQEND" oflag=seek_bytes \
        count=$(( (P2_END - SQEND) / 1048576 + 1 )) conv=fsync status=progress
sync

# --------------------------------------------------------------------- verify
echo "==> verifying"
MP=$(mktemp -d)
sudo mount -o ro,loop "$P2" "$MP" || die "squashfs will not mount — the wipe overlapped it"
echo "         version: $(sudo grep DESCRIPTION "$MP/etc/openwrt_release" | cut -d= -f2)"
echo "         host keys in image: $(sudo ls "$MP/etc/dropbear/" 2>/dev/null | wc -l) (must be 0)"
sudo umount "$MP"; rmdir "$MP"

NONZERO=$(sudo dd if="$DEV" bs=1M skip=$(( SQEND / 1048576 + 2 )) count=50 iflag=direct 2>/dev/null | tr -d '\0' | wc -c)
echo "         non-zero bytes after squashfs: $NONZERO (must be 0)"
[ "$NONZERO" -eq 0 ] || die "overlay region is not clean"

sync
cat <<'EOF'

Done. Next, in this order:

  1. boot the node, then SSH in at 10.41.254.1 with no password
  2. install your SSH key BEFORE the wizard - it sets a password, and a typo
     there means another flash
  3. configure it: run the wizard, or clone an existing node
     (see docs/cloning-a-node.md)
  4. sync before cutting power

A fresh system is confirmed by a blank root password, a changed host key,
uptime near zero, and a newly created overlay - not by hashing the card,
which matches whether or not the overlay survived.
EOF
