#!/bin/sh
# build-ab-payload.sh — assemble a batman A/B sysupgrade image (our dedicated format) from an
# OpenWrt rootfs squashfs + a boot directory. Runs in CI after the firmware build (Linux host with
# coreutils tar) or by hand on a node. The result is fed to `sysupgrade -n <out>` on an A/B card;
# /lib/upgrade/platform.sh (the A/B override) streams it onto the inactive slot and calls
# `batman-slot apply`, which verifies everything it wrote against SHA256SUMS.
# See docs/design/ab-sysupgrade-platform.md and docs/design/209-ab-on-pi3.md.
#
#   build-ab-payload.sh <root.squashfs> <bootdir> <board> <out.tar.gz>
#
# <board> must name the SoC (ekh-bcm2711 / ekh-bcm2710 ...). It is checked against the boot files
# and, when unsquashfs can read it, against the rootfs's own DISTRIB_TARGET (#209 R2): a payload for
# the wrong SoC flashed onto a Pi 3 leaves it unbootable with no fallback.
#
# <bootdir> holds the boot FAT contents. Packed: kernel8.img, *.dtb, overlays/, and every
# start*.elf / fixup*.dat present (Pi 4: start4*; Pi 3: start*, incl. start_cd/fixup_cd that
# gpu_mem=16 loads). NOT packed: bootcode.bin (Pi 3: lives on the never-OTA'd p7, #209 D3),
# autoboot.txt (the A/B control plane), cmdline.txt (per-slot, written by batman-slot), config.txt.
# bcm2710 firmware must be in the allow-list (1.20250430 cannot boot MBR partition 4, #209 D4).
set -eu
SQ=${1:-}; BOOTDIR=${2:-}; BOARD=${3:-}; OUT=${4:-}
[ -f "$SQ" ] && [ -d "$BOOTDIR" ] && [ -n "$BOARD" ] && [ -n "$OUT" ] || {
	echo "usage: build-ab-payload.sh <root.squashfs> <bootdir> <board> <out.tar.gz>" >&2; exit 1; }
[ "$(hexdump -n4 -e '4/1 "%c"' "$SQ" 2>/dev/null)" = hsqs ] || { echo "$SQ is not a squashfs" >&2; exit 1; }
fail() { echo "build-ab-payload: $*" >&2; exit 1; }

case "$BOARD" in *bcm2711*) SOC=bcm2711 ;; *bcm2710*) SOC=bcm2710 ;; *) fail "board '$BOARD' names no known SoC (bcm2711/bcm2710)" ;; esac

# the boot files must belong to that SoC
if [ "$SOC" = bcm2710 ]; then
	for f in start.elf start_cd.elf fixup.dat fixup_cd.dat; do [ -f "$BOOTDIR/$f" ] || fail "bcm2710 payload needs $f in $BOOTDIR"; done
	ls "$BOOTDIR"/bcm2710-*.dtb >/dev/null 2>&1 || fail "board says bcm2710 but $BOOTDIR has no bcm2710-*.dtb"
	ALLOW=${FW_ALLOWLIST:-}
	for c in "$(dirname "$0")/../feed/batman-provision/files/usr/share/batman/firmware-allowlist-bcm2710.sha256" \
	         /usr/share/batman/firmware-allowlist-bcm2710.sha256; do
		[ -n "$ALLOW" ] || { [ -f "$c" ] && ALLOW=$c; }
	done
	[ -f "${ALLOW:-}" ] || fail "bcm2710 firmware allow-list not found"
	for f in "$BOOTDIR"/start*.elf "$BOOTDIR"/fixup*.dat; do
		[ -f "$f" ] || continue
		case "${f##*/}" in start4*|fixup4*) continue ;; esac
		grep -v '^#' "$ALLOW" | grep -qx "$(sha256sum "$f" | cut -d' ' -f1)  ${f##*/}" || fail "${f##*/} is not in the bcm2710 allow-list $ALLOW"
	done
else
	[ -f "$BOOTDIR/start4.elf" ] || fail "board says bcm2711 but $BOOTDIR has no start4.elf"
fi

# the rootfs must agree too, when it can be read here (unsquashfs is optional on the node)
if command -v unsquashfs >/dev/null 2>&1; then
	tgt=$(unsquashfs -cat "$SQ" etc/openwrt_release 2>/dev/null | sed -n "s/^DISTRIB_TARGET='*[^/]*\/\([^']*\)'*$/\1/p") || tgt=""
	if [ -n "$tgt" ]; then
		[ "$tgt" = "$SOC" ] || fail "rootfs is DISTRIB_TARGET=$tgt but board says $SOC"
		echo "rootfs DISTRIB_TARGET=$tgt matches board"
	else
		echo "WARN: could not read DISTRIB_TARGET from $SQ — board checked against the boot files only" >&2
	fi
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cp "$SQ" "$T/root.squashfs"
mkdir -p "$T/boot"
cp "$BOOTDIR/kernel8.img" "$T/boot/" 2>/dev/null || fail "no kernel8.img in $BOOTDIR — refusing (would write a slot with no kernel)"
for f in "$BOOTDIR"/start*.elf "$BOOTDIR"/fixup*.dat "$BOOTDIR"/*.dtb; do
	[ -f "$f" ] && cp "$f" "$T/boot/"
done
[ -d "$BOOTDIR/overlays" ] && cp -r "$BOOTDIR/overlays" "$T/boot/"
SQ_BYTES=$(wc -c < "$SQ" | tr -dc '0-9')
printf 'board=%s\nversion=%s\nsize=%s\n' "$BOARD" "$(date +%Y%m%d-%H%M%S)" "$SQ_BYTES" > "$T/metadata"
# SHA256SUMS: root.squashfs + every boot/ file, relative paths (batman-slot verifies before AND after writing)
( cd "$T" && sha256sum root.squashfs && find boot -type f | sort | while read -r f; do sha256sum "$f"; done ) > "$T/SHA256SUMS"

tar -C "$T" -czf "$OUT" root.squashfs boot metadata SHA256SUMS
echo "wrote $OUT ($(wc -c < "$OUT") bytes): board=$BOARD soc=$SOC squashfs=$SQ_BYTES bytes, $(grep -c ' boot/' "$T/SHA256SUMS") boot files"
