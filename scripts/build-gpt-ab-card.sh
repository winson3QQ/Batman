#!/bin/bash
# Build the GPT six-partition A/B card for Batman #133 (parent #106/#88).
# Layout per docs/storage-architecture.md "Partition scheme v2".
# DESTRUCTIVE: repartitions $DEV. Backup must exist and be verified first.
set -euo pipefail

#   DEV             target block device (default /dev/mmcblk0)
#   SRC             source dir holding the rootfs dump, boot tar and data to restore
#   EXPECT_SECTORS  refuse to run unless DEV is exactly this many sectors (safety interlock)
DEV=${DEV:-/dev/mmcblk0}
SRC=${SRC:?set SRC to the backup dir (see docs/storage-architecture.md B1)}
EXPECT_SECTORS=${EXPECT_SECTORS:-62333952}
SQUASH_SRC="$SRC/p2-rootfs-squashfs.img"   # dump of the v1.1 p2; squashfs sits at offset 0

# Size of the squashfs at offset 0 of SQUASH_SRC; read it rather than hard-coding, so a
# re-squashed rootfs (e.g. after the ETHFIX patch) still copies in full.
#
# Read from the superblock, NOT from `unsquashfs -s | awk '{print $3}'`. Only squashfs-tools
# >= 4.6 prints "Filesystem size <N> bytes"; 4.5 and earlier print "Filesystem size <N.NN>
# Kbytes", so column 3 is a non-integer there and the guard below refuses with a message that
# blames the wrong thing. The squashfs 4.0 superblock has bytes_used as a little-endian u64 at
# offset 40, which is exact and version-independent. unsquashfs stays as the fallback.
squashfs_bytes() {                         # $1 = file with a squashfs at offset 0
  local magic
  magic=$(od -An -tx4 -N4 "$1" 2>/dev/null | tr -d ' \n')
  [ "$magic" = 73717368 ] || return 1      # 'hsqs' little-endian
  od -An -tu8 -j40 -N8 "$1" 2>/dev/null | tr -d ' \n'
}
SQUASH_BYTES=${SQUASH_BYTES:-$(squashfs_bytes "$SQUASH_SRC" \
  || unsquashfs -s "$SQUASH_SRC" 2>/dev/null | awk '/Filesystem size/{for(i=1;i<=NF;i++) if($i=="bytes") print $(i-1)}')}
BOOTTAR="$SRC/p1-bootA/bootA.tar"
DATA_SRC="$SRC/p3-batdata"                 # restored onto the new data partition

# Deterministic PARTUUIDs, traceable to this card's old MBR id 3276af79.
G1=3276af79-0000-4000-8000-000000000001   # bootA
G2=3276af79-0000-4000-8000-000000000002   # rootA
G3=3276af79-0000-4000-8000-000000000003   # bootB
G4=3276af79-0000-4000-8000-000000000004   # rootB
G5=3276af79-0000-4000-8000-000000000005   # config
G6=3276af79-0000-4000-8000-000000000006   # data

say(){ echo; echo "=== $* ==="; }

[[ -b $DEV ]] || { echo "no such device $DEV"; exit 1; }
# mmcblk0/loop0 partitions are mmcblk0p1; sda partitions are sda1. docs/storage-architecture.md
# records this card being built on the Pi 500's USB reader, which enumerates as /dev/sda — with
# a hard-coded "p" every reference below becomes /dev/sdap1 and the first failure lands AFTER
# wipefs and sgdisk have already destroyed the partition table.
[[ $DEV =~ [0-9]$ ]] && P=p || P=""
[[ -f $SQUASH_SRC && -f $BOOTTAR ]] || { echo "backup missing"; exit 1; }
[[ -d $DATA_SRC ]] || { echo "no data source dir $DATA_SRC - refusing (it is needed AFTER the repartition)"; exit 1; }
# An empty or non-numeric SQUASH_BYTES makes every `count=` below evaluate to 0, so dd writes
# NOTHING into either root slot and the script still reports BUILD DONE — a card with no
# rootfs, built silently. Validate before the card is repartitioned, not after.
[[ $SQUASH_BYTES =~ ^[0-9]+$ ]] && (( SQUASH_BYTES > 0 )) \
  || { echo "SQUASH_BYTES='$SQUASH_BYTES' is not a positive integer - refusing"; echo "(no squashfs superblock at offset 0 of $SQUASH_SRC, and unsquashfs -s gave nothing usable)"; exit 1; }
SZ=$(sudo blockdev --getsz "$DEV")
[[ $SZ -eq $EXPECT_SECTORS ]] || { echo "unexpected device size $SZ sectors (want $EXPECT_SECTORS) - refusing"; exit 1; }

say "unmount everything on $DEV"
for m in $(mount | awk -v d="$DEV" '$1 ~ "^"d {print $3}'); do sudo umount "$m" && echo "umounted $m"; done

say "wipe old signatures + partition table"
sudo wipefs -a "$DEV"
sudo sgdisk --zap-all "$DEV"

say "create GPT (bootA/rootA/bootB/rootB/[300M rescue gap]/config/data)"
sudo sgdisk -a 2048 \
  -n 1:4M:+64M      -t 1:0700 -c 1:bootA  -u 1:$G1 \
  -n 2:68M:+1536M   -t 2:8300 -c 2:rootA  -u 2:$G2 \
  -n 3:1604M:+64M   -t 3:0700 -c 3:bootB  -u 3:$G3 \
  -n 4:1668M:+1536M -t 4:8300 -c 4:rootB  -u 4:$G4 \
  -n 5:3504M:+512M  -t 5:8300 -c 5:config -u 5:$G5 \
  -n 6:4016M:0      -t 6:8300 -c 6:data   -u 6:$G6 \
  "$DEV"
sudo partprobe "$DEV"; sleep 2
for i in 1 2 3 4 5 6; do
  [[ -b ${DEV}${P}${i} ]] || { echo "expected partition ${DEV}${P}${i} does not exist after partprobe - refusing"; exit 1; }
done

say "boot slots: mkfs.vfat (NOT dd) with distinct labels + volume ids"
sudo mkfs.vfat -F 16 -n BOOTA -i 0xBA710001 "${DEV}${P}1"
sudo mkfs.vfat -F 16 -n BOOTB -i 0xBA710003 "${DEV}${P}3"

# Zero past the end of the new squashfs, not a fixed 96 MiB: fstools looks for the overlay
# immediately behind the squashfs, so if a re-squashed rootfs grows past the zeroed window a
# stale f2fs overlay from the card's previous life is re-mounted and the node comes up as
# "new squashfs + old settings" (docs/upgrade-1.8.0.md: the classic 'reflash didn't take').
SQUASH_MB=$(( (SQUASH_BYTES + 1048575) / 1048576 ))
ZERO_MB=$(( SQUASH_MB + 64 ))
# Copy EXACTLY SQUASH_BYTES, not the MiB-rounded count. SQUASH_SRC is a dump of the whole old
# p2 — squashfs at offset 0 followed by that card's previous f2fs overlay — so a rounded-up
# copy drags up to 1 MiB of the OLD overlay back over the zeros just written, and fstools looks
# for the overlay at ceil(SQUASH_BYTES/64KiB)*64KiB, which is inside that overshoot. That is
# exactly the "new squashfs + old settings" case the zeroing above exists to prevent.
say "rootfs slots: zero the first $ZERO_MB MiB, then write the $SQUASH_BYTES-byte squashfs to each"
for p in 2 4; do
  sudo dd if=/dev/zero of="${DEV}${P}${p}" bs=1M count=$ZERO_MB status=none conv=fsync
  sudo dd if="$SQUASH_SRC" of="${DEV}${P}${p}" bs=1M count=$SQUASH_BYTES iflag=count_bytes status=none conv=fsync
done

say "config + data: ext4"
sudo mkfs.ext4 -q -F -L batconfig "${DEV}${P}5"
sudo mkfs.ext4 -q -F -L batdata   "${DEV}${P}6"

say "populate boot slots"
T=$(mktemp -d); sudo mkdir -p "$T/a" "$T/b"
sudo mount "${DEV}${P}1" "$T/a"; sudo mount "${DEV}${P}3" "$T/b"
# vfat has no ownership: --no-same-owner, else tar exits 2 on chown and set -e kills us
sudo tar --no-same-owner -C "$T/a" -xf "$BOOTTAR"
sudo tar --no-same-owner -C "$T/b" -xf "$BOOTTAR"

# rootwait=20 panic=10, NOT a bare `rootwait`. Bare rootwait waits for the root device
# *forever*: a slot whose rootfs is missing or corrupt then hangs before procd starts, so
# /dev/watchdog is never opened and nothing ever resets the board — a silent dead node, not
# a boot loop. The firmware's tryboot fallback does not help here; it already handed off to
# the kernel successfully. Bounded wait + panic turns that into an automatic return to the
# other slot. Do NOT drop rootwait entirely: mmc probes asynchronously and a healthy slot
# then races and panics too. Bench-verified on 6.6.138 (#133): corrupt rootfs 62 s to
# recover, absent root device 77 s, healthy slot unaffected.
CMDLINE_COMMON="console=serial0 console=ttyUSB0,115200 console=tty1 rootfstype=squashfs,ext4 rootwait=20 panic=10"
echo "$CMDLINE_COMMON root=PARTUUID=$G2 batman_slot=A" | sudo tee "$T/a/cmdline.txt" >/dev/null
echo "$CMDLINE_COMMON root=PARTUUID=$G4 batman_slot=B" | sudo tee "$T/b/cmdline.txt" >/dev/null

# autoboot.txt lives on the FIRST FAT partition (bootA) and is read for every boot.
# rpi-eeprom #499: never put EEPROM updates on an A/B boot partition.
#
# boot_partition is the FIRMWARE's partition number, NOT the GPT index. The firmware
# counts only the partitions it can boot from (the FAT ones), so with the v2 layout
# (bootA=gpt1, rootA=gpt2, bootB=gpt3, ...) bootA is 1 and bootB is *2*, not 3.
# Bench-verified on EEPROM 2026-01-09 (#133): boot_partition=3 pointed at nothing,
# and the firmware cleanly failed over to partition 1 instead of switching slots.
# Derived, never hard-coded: hard-coding it means any future change to the partition
# order silently mis-aims the tryboot switch, and the failure mode is "the node comes
# back healthy on the old slot", which no health check would flag.
fw_boot_partition() {            # $1 = GPT index -> the firmware's boot_partition number
  local target=$1 n=0 i
  for i in $(sudo sgdisk -p "$DEV" | awk '/^ *[0-9]+ +[0-9]+/{print $1}' | sort -n); do
    [ "$(sudo blkid -p -s TYPE -o value "${DEV}${P}${i}" 2>/dev/null)" = vfat ] || continue
    n=$((n + 1))
    [ "$i" = "$target" ] && { echo "$n"; return 0; }
  done
  echo "fw_boot_partition: GPT $target is not a FAT partition" >&2; return 1
}
FW_A=$(fw_boot_partition 1)
FW_B=$(fw_boot_partition 3)
echo "firmware numbering: bootA(gpt1)=$FW_A  bootB(gpt3)=$FW_B"
printf '%s\n' '[all]' 'tryboot_a_b=1' "boot_partition=$FW_A" '' '[tryboot]' "boot_partition=$FW_B" \
  | sudo tee "$T/a/autoboot.txt" >/dev/null

sudo sync; sudo umount "$T/a" "$T/b"; sudo rmdir "$T/a" "$T/b" "$T"

say "restore data partition"
# mktemp, not a fixed /mnt/newdata: a run that dies mid-way leaves the fixed path mounted and
# every later run then fails on it.
D=$(mktemp -d); sudo mount "${DEV}${P}6" "$D"
sudo rsync -aHAX "$DATA_SRC/" "$D/"
sudo sync; sudo umount "$D"; rmdir "$D"

say "final layout"
sudo sgdisk -p "$DEV"
sudo blkid "${DEV}${P}1" "${DEV}${P}2" "${DEV}${P}3" "${DEV}${P}4" "${DEV}${P}5" "${DEV}${P}6"
echo
echo "BUILD DONE"
