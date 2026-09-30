#!/bin/sh
# e0f-prep-card.sh — turn a FRESHLY FLASHED, NEVER BOOTED bcm2710 OpenWrt card into the #209 E0f
# test card. Non-destructive to the image: both boot partitions boot the SAME rootfs (p2); only
# the cmdline marker differs, so whichever partition the firmware picks, the node comes up.
#
#   sudo sh e0f-prep-card.sh /dev/sdX            # a real card (Linux / WSL with usbipd)
#   sudo sh e0f-prep-card.sh card.img            # an image file (attached via losetup)
#
# Resulting MBR layout (all primary, so the firmware partition number == MBR index):
#   p1  FAT  boot (as flashed)   cmdline += " e0=p1"   + autoboot.txt: [all] boot_partition=4
#   p2  rootfs (as flashed)
#   p3  ext4 1 GiB, label batdata — PRE-MADE on purpose: the pre-#230 95-batman-storage keeps an
#       existing ext4 p3 ("already has a filesystem — keeping it") instead of carving/formatting
#       one. Without it, a FAT at p3 would be mkfs.ext4'd on first boot (the bug #230 fixes).
#   p4  FAT 256 MiB "E0TRIAL" = copy of p1 (minus autoboot.txt)   cmdline += " e0=p4"
#
# NB on a post-#230 image the data partition is REFUSED on this 4-partition MBR layout (no GPT
# name 'data', no p6) — harmless for E0f (no /opt/batdata; e0-probe.sh then logs to /root).
set -eu

TARGET=${1:-}
[ -n "$TARGET" ] || { echo "usage: $0 <block-device | image-file>" >&2; exit 2; }
[ "$(id -u)" = 0 ] || [ -n "${E0_TABLE_ONLY:-}" ] || { echo "run as root (sudo)" >&2; exit 2; }
for t in sfdisk mkfs.vfat mkfs.ext4 mount umount losetup blockdev truncate; do
	command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }
done

LOOP=""; MNT1=""; MNT4=""
cleanup() {
	[ -z "$MNT1" ] || { umount "$MNT1" 2>/dev/null; rmdir "$MNT1" 2>/dev/null; }
	[ -z "$MNT4" ] || { umount "$MNT4" 2>/dev/null; rmdir "$MNT4" 2>/dev/null; }
	[ -z "$LOOP" ] || losetup -d "$LOOP" 2>/dev/null
	return 0
}
trap cleanup EXIT

# "start size" per partition, in table order; works on a block device AND on an image file
# (for a file sfdisk names partitions "card.img1", not "/dev/...", so never key off the name).
parts() { sfdisk --dump "$1" | sed -n 's/^.* : *start= *\([0-9]*\), *size= *\([0-9]*\).*/\1 \2/p'; }

# --- preconditions: exactly the flashed image, never booted -----------------------------------
LABEL=$(sfdisk --dump "$TARGET" | sed -n 's/^label: //p')
[ "$LABEL" = dos ] || { echo "expected an MBR (dos) table, got '$LABEL' — is this the bcm2710 OpenWrt image?" >&2; exit 1; }
NPART=$(parts "$TARGET" | wc -l)
[ "$NPART" = 2 ] || { echo "expected exactly p1+p2 (a freshly flashed, never-booted card), found $NPART partitions." >&2
	echo "A booted card already has its expand-to-fill data p3 — reflash and do NOT boot it first." >&2; exit 1; }
set -- $(parts "$TARGET" | sed -n 2p); P2_START=$1; P2_SIZE=$2
[ -n "$P2_START" ] && [ -n "$P2_SIZE" ] || { echo "cannot parse p2 geometry" >&2; exit 1; }

ALIGN=8192                                   # 4 MiB, in 512-byte sectors
P3_START=$(( (P2_START + P2_SIZE + ALIGN - 1) / ALIGN * ALIGN ))
P3_SIZE=$(( 1024 * 2048 ))                   # 1 GiB
P4_START=$(( P3_START + P3_SIZE ))
P4_SIZE=$(( 256 * 2048 ))                    # 256 MiB
NEED=$(( (P4_START + P4_SIZE + ALIGN) * 512 ))

if [ -f "$TARGET" ]; then
	# an image file: grow it so p3+p4 fit, then flash the RESULT with any burner / Imager
	[ "$(stat -c %s "$TARGET")" -ge "$NEED" ] || truncate -s "$NEED" "$TARGET"
	HAVE=$(stat -c %s "$TARGET")
else
	[ -b "$TARGET" ] || { echo "$TARGET is neither a block device nor a file" >&2; exit 2; }
	HAVE=$(blockdev --getsize64 "$TARGET")
	[ "$(blockdev --getss "$TARGET")" = 512 ] || { echo "unexpected sector size" >&2; exit 1; }
fi
[ "$HAVE" -ge "$NEED" ] || { echo "too small for p3+p4: have $HAVE bytes, need $NEED" >&2; exit 1; }

echo "== adding p3 (ext4 1GiB @${P3_START}s) and p4 (FAT 256MiB @${P4_START}s) to $TARGET"
printf '%s\n%s\n' "start=${P3_START}, size=${P3_SIZE}, type=83" \
                  "start=${P4_START}, size=${P4_SIZE}, type=c" | sfdisk --append --no-reread "$TARGET"
[ "$(parts "$TARGET" | wc -l)" = 4 ] || { echo "table does not show 4 partitions after append" >&2; exit 1; }
[ -z "${E0_TABLE_ONLY:-}" ] || { echo "E0_TABLE_ONLY set — stopping after the table (test seam)"; sfdisk --dump "$TARGET"; exit 0; }

if [ -f "$TARGET" ]; then
	LOOP=$(losetup --show -fP "$TARGET"); DEV=$LOOP
else
	DEV=$TARGET; partprobe "$DEV" 2>/dev/null || true
fi
# partition device names: /dev/sdX1 vs /dev/loop0p1 / /dev/mmcblk0p1
case "$DEV" in *[0-9]) P=${DEV}p ;; *) P=$DEV ;; esac
sleep 1
[ -b "${P}3" ] && [ -b "${P}4" ] || { echo "kernel does not see ${P}3/${P}4 — replug the card, then run the mkfs/copy steps by hand" >&2; exit 1; }

mkfs.ext4 -q -F -L batdata "${P}3"
mkfs.vfat -F 32 -n E0TRIAL "${P}4" >/dev/null

# --- copy p1 -> p4, then mark both cmdlines ----------------------------------------------------
MNT1=$(mktemp -d); MNT4=$(mktemp -d)
mount "${P}1" "$MNT1"; mount "${P}4" "$MNT4"
cp -r "$MNT1"/. "$MNT4"/
rm -f "$MNT4/autoboot.txt"
[ -f "$MNT1/cmdline.txt" ] || { echo "no cmdline.txt on p1" >&2; exit 1; }
# cmdline.txt must stay ONE line, LF only, no CR (a CR breaks the firmware parse — #208)
mark() { c=$(tr -d '\r\n' < "$1/cmdline.txt"); case "$c" in *" e0="*) echo "already marked: $1" >&2; exit 1 ;; esac
	printf '%s e0=%s\n' "$c" "$2" > "$1/cmdline.txt"; }
mark "$MNT1" p1
mark "$MNT4" p4
printf '[all]\nboot_partition=4\n' > "$MNT1/autoboot.txt"
sync

echo "== result"
echo "p1 cmdline: $(cat "$MNT1/cmdline.txt")"
echo "p4 cmdline: $(cat "$MNT4/cmdline.txt")"
echo "p1 autoboot.txt:"; sed 's/^/    /' "$MNT1/autoboot.txt"
if grep -q "$(printf '\r')" "$MNT1/cmdline.txt" "$MNT4/cmdline.txt" "$MNT1/autoboot.txt"; then
	echo "CR found in a boot file — refusing to call this card good" >&2; exit 1; fi
sfdisk --dump "$DEV" | grep '^/dev/'
echo "== done. Card ready for E0f (see scripts/e0/README.md)."
