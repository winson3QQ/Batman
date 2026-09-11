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
SQUASH_BYTES=${SQUASH_BYTES:-55290510}     # from `unsquashfs -s`
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

echo "console=serial0 console=ttyUSB0,115200 console=tty1 root=PARTUUID=$G2 rootfstype=squashfs,ext4 rootwait batman_slot=A" | sudo tee "$T/a/cmdline.txt" >/dev/null
echo "console=serial0 console=ttyUSB0,115200 console=tty1 root=PARTUUID=$G4 rootfstype=squashfs,ext4 rootwait batman_slot=B" | sudo tee "$T/b/cmdline.txt" >/dev/null

# autoboot.txt lives on the FIRST FAT partition (bootA) and is read for every boot.
# rpi-eeprom #499: never put EEPROM updates on an A/B boot partition.
printf '%s\n' '[all]' 'tryboot_a_b=1' 'boot_partition=1' '' '[tryboot]' 'boot_partition=3' | sudo tee "$T/a/autoboot.txt" >/dev/null

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
