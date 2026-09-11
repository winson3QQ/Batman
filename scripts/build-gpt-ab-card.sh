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
# Size of the squashfs at offset 0 of SQUASH_SRC; read it rather than hard-coding,
# so a re-squashed rootfs (e.g. after the ETHFIX patch) still copies in full.
SQUASH_BYTES=${SQUASH_BYTES:-$(unsquashfs -s "$SRC/p2-rootfs-squashfs.img" 2>/dev/null | awk '/Filesystem size/{print $3}')}
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
[[ -f $SQUASH_SRC && -f $BOOTTAR ]] || { echo "backup missing"; exit 1; }
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

say "boot slots: mkfs.vfat (NOT dd) with distinct labels + volume ids"
sudo mkfs.vfat -F 16 -n BOOTA -i 0xBA710001 "${DEV}p1"
sudo mkfs.vfat -F 16 -n BOOTB -i 0xBA710003 "${DEV}p3"

say "rootfs slots: zero head, then write the 52.7 MB squashfs to each"
for p in 2 4; do
  sudo dd if=/dev/zero of="${DEV}p${p}" bs=1M count=96 status=none conv=fsync
  sudo dd if="$SQUASH_SRC" of="${DEV}p${p}" bs=1M count=$(( (SQUASH_BYTES + 1048575) / 1048576 )) status=none conv=fsync
done

say "config + data: ext4"
sudo mkfs.ext4 -q -F -L batconfig "${DEV}p5"
sudo mkfs.ext4 -q -F -L batdata   "${DEV}p6"

say "populate boot slots"
T=$(mktemp -d); sudo mkdir -p "$T/a" "$T/b"
sudo mount "${DEV}p1" "$T/a"; sudo mount "${DEV}p3" "$T/b"
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
    [ "$(sudo blkid -p -s TYPE -o value "${DEV}p${i}" 2>/dev/null)" = vfat ] || continue
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
sudo mkdir -p /mnt/newdata && sudo mount "${DEV}p6" /mnt/newdata
sudo rsync -aHAX "$DATA_SRC/" /mnt/newdata/
sudo sync; sudo umount /mnt/newdata; sudo rmdir /mnt/newdata

say "final layout"
sudo sgdisk -p "$DEV"
sudo blkid "${DEV}p1" "${DEV}p2" "${DEV}p3" "${DEV}p4" "${DEV}p5" "${DEV}p6"
echo
echo "BUILD DONE"
