# pi3-fwpart.sh — Pi 3 (bcm2710) A/B card helpers shared by scripts/build-ab-image.sh and
# scripts/build-gpt-ab-card.sh (#209 design v4.3 D1/D3/D4). Source it; it defines functions only.
#
# Why a Pi 3 card differs from the Pi 4 one (all measured on manet03, see #209):
#   * The Pi 3 boot ROM does not read a pure GPT card (E0d). The card keeps the Pi 4 GPT layout
#     but adds a HYBRID MBR whose entries the ROM/bootcode.bin can see.
#   * There is no EEPROM: bootcode.bin and autoboot.txt are read from MBR entry 1. They live on
#     a dedicated firmware partition p7 ("batfw", 1-4 MiB gap before bootA) that OTA never writes,
#     so a torn OTA write to a boot slot can no longer take both slots down (D3).
#   * p7 needs an (empty) config.txt next to bootcode.bin + autoboot.txt, or the board stays dark
#     with no ACT activity at all (E0g V1-V3 vs V5/V6).
#   * The Pi 3 firmware numbers boot partitions by MBR ENTRY ORDER (E0f/E0d), so with
#     MBR 1=p7 2=bootA 3=bootB 4=ee, bootA is 2 and bootB is 3. `ee` must be the LAST entry.
#
# Callers set: SUDO (empty when already root) and use these functions on a disk that may be a
# block device or an image file. MBR bytes are read/written with dd at fixed offsets so the same
# code works on both.

PI3_P7_FIRST=2048        # 1 MiB
PI3_P7_LAST=8191         # 4 MiB - 1 sector: the gap in front of bootA (which starts at 4 MiB)
PI3_P7_GUID=3276af79-0000-4000-8000-000000000007
PI3_P7_NAME=batfw
PI3_FAT16_MIN_CLUSTERS=4085

# $1 = disk (device or image file). Adds GPT entry 7 in the 1-4 MiB gap.
pi3_add_p7() {
	$SUDO sgdisk -n "7:${PI3_P7_FIRST}:${PI3_P7_LAST}" -t 7:0700 -c "7:${PI3_P7_NAME}" -u "7:${PI3_P7_GUID}" "$1" >/dev/null
}

# MBR entry $2 (1..4) of disk $1 -> "TYPE START COUNT BOOTFLAG" (hex type, decimal LBAs, hex flag)
pi3_mbr_entry() {
	local o=$((446 + 16 * ($2 - 1)))
	echo "$($SUDO od -An -tx1 -j $((o + 4)) -N1 "$1" | tr -d ' ') $($SUDO od -An -tu4 -j $((o + 8)) -N4 "$1" | tr -d ' ') $($SUDO od -An -tu4 -j $((o + 12)) -N4 "$1" | tr -d ' ') $($SUDO od -An -tx1 -j "$o" -N1 "$1" | tr -d ' ')"
}

# $1 = disk, $2 $3 $4 = start LBA of p7, bootA, bootB (GPT). Writes the hybrid MBR
# (1=p7 2=bootA 3=bootB 4=ee), sets FAT32-LBA type 0x0c on 1-3 and the active flag on 1.
# 0x0c on FAT16 volumes is deliberate: it is the type the Pi 3 booted with in E0d/E0g.
pi3_hybrid_mbr() {
	local d=$1 n o
	$SUDO sgdisk --hybrid=7:1:3:EE "$d" >/dev/null
	for n in 1 2 3; do
		o=$((446 + 16 * (n - 1)))
		printf '\x0c' | $SUDO dd of="$d" bs=1 seek=$((o + 4)) conv=notrunc status=none
	done
	printf '\x80' | $SUDO dd of="$d" bs=1 seek=446 conv=notrunc status=none
	pi3_assert_mbr "$d" "$2" "$3" "$4"
}

# Read-back assertion of the hybrid MBR. Returns 1 (and says why) on any deviation.
pi3_assert_mbr() {
	local d=$1 p7=$2 a=$3 b=$4 e1 e2 e3 e4 bad=0
	e1=$(pi3_mbr_entry "$d" 1); e2=$(pi3_mbr_entry "$d" 2); e3=$(pi3_mbr_entry "$d" 3); e4=$(pi3_mbr_entry "$d" 4)
	set -- $e1; [ "$1" = 0c ] && [ "$2" = "$p7" ] && [ "$4" = 80 ] || { echo "pi3 MBR[1] = '$e1', want type 0c start $p7 active (p7/batfw)" >&2; bad=1; }
	set -- $e2; [ "$1" = 0c ] && [ "$2" = "$a" ]                   || { echo "pi3 MBR[2] = '$e2', want type 0c start $a (bootA)" >&2; bad=1; }
	set -- $e3; [ "$1" = 0c ] && [ "$2" = "$b" ]                   || { echo "pi3 MBR[3] = '$e3', want type 0c start $b (bootB)" >&2; bad=1; }
	set -- $e4; [ "$1" = ee ] && [ "$2" = 1 ] && [ $(($2 + $3)) -le "$p7" ] \
		|| { echo "pi3 MBR[4] = '$e4', want type ee from LBA 1 ending before p7 ($p7)" >&2; bad=1; }
	[ "$bad" = 0 ]
}

# $1 = boot-file dir. Every Raspberry Pi firmware blob present must be in the allow-list, and the
# set a Pi 3 boots with must be complete. FW_ALLOWLIST overrides the list (tests use placeholders).
pi3_check_firmware() {
	local dir=$1 list=${FW_ALLOWLIST:-$(dirname "${BASH_SOURCE[0]:-$0}")/firmware-allowlist-bcm2710.sha256} f h bad=0
	[ -f "$list" ] || { echo "firmware allow-list not found: $list" >&2; return 1; }
	for f in bootcode.bin start.elf start_cd.elf fixup.dat fixup_cd.dat; do
		[ -f "$dir/$f" ] || { echo "bcm2710 boot set incomplete: $f missing in $dir" >&2; bad=1; }
	done
	for f in "$dir"/bootcode.bin "$dir"/start*.elf "$dir"/fixup*.dat; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in start4*|fixup4*) continue ;; esac   # Pi 4 blobs: a Pi 3 never loads them
		h=$(sha256sum "$f" | cut -d' ' -f1)
		grep -v '^#' "$list" | grep -qx "$h  $(basename "$f")" \
			|| { echo "firmware $(basename "$f") ($h) is not in the bcm2710 allow-list $list" >&2; bad=1; }
	done
	[ "$bad" = 0 ]
}

# $1 = p7 block device, $2 = bootcode.bin, $3 = [all] firmware index, $4 = [tryboot] index.
# FAT16 with 1 sector/cluster (a 3 MiB FAT16 needs 512-byte clusters to clear the FAT16 minimum;
# mkfs would otherwise pick FAT12, which the Pi 3 was never tested with).
pi3_fill_p7() {
	local dev=$1 bc=$2 all=$3 try=$4 m clus spc tot res nf fsz re
	$SUDO mkfs.vfat -F 16 -s 1 -n BATFW -i 0xBA710007 "$dev" >/dev/null
	spc=$($SUDO od -An -tu1 -j13 -N1 "$dev" | tr -d ' ');  res=$($SUDO od -An -tu2 -j14 -N2 "$dev" | tr -d ' ')
	nf=$($SUDO od -An -tu1 -j16 -N1 "$dev" | tr -d ' ');   re=$($SUDO od -An -tu2 -j17 -N2 "$dev" | tr -d ' ')
	tot=$($SUDO od -An -tu2 -j19 -N2 "$dev" | tr -d ' ');  fsz=$($SUDO od -An -tu2 -j22 -N2 "$dev" | tr -d ' ')
	[ "$tot" = 0 ] && tot=$($SUDO od -An -tu4 -j32 -N4 "$dev" | tr -d ' ')
	clus=$(( (tot - res - nf * fsz - (re * 32 + 511) / 512) / spc ))
	[ "$clus" -ge "$PI3_FAT16_MIN_CLUSTERS" ] || { echo "p7 has $clus clusters (< $PI3_FAT16_MIN_CLUSTERS): not a valid FAT16" >&2; return 1; }
	m=$(mktemp -d)
	$SUDO mount "$dev" "$m"
	$SUDO cp "$bc" "$m/bootcode.bin"
	printf '%s\n' '[all]' 'tryboot_a_b=1' "boot_partition=$all" '' '[tryboot]' "boot_partition=$try" | $SUDO tee "$m/autoboot.txt" >/dev/null
	: | $SUDO tee "$m/config.txt" >/dev/null     # REQUIRED and empty (E0g): without it the board stays dark
	sync; $SUDO umount "$m"; rmdir "$m"
}

# MBR entry index (1..4) whose start LBA is $2 on disk $1; the Pi 3 firmware's partition number.
pi3_fw_index() {
	local n s
	for n in 1 2 3 4; do
		s=$(pi3_mbr_entry "$1" "$n" | cut -d' ' -f2)
		[ "$s" = "$2" ] && { echo "$n"; return 0; }
	done
	echo "pi3_fw_index: no MBR entry starts at $2" >&2; return 1
}
