#!/bin/sh
# build-ab-payload.sh — assemble a batman A/B sysupgrade image (our dedicated format) from an
# OpenWrt rootfs squashfs + a boot directory. Runs in CI after the firmware build (Linux host with
# coreutils tar) or by hand on a node. The result is fed to `sysupgrade -n <out>` on an A/B card;
# /lib/upgrade/platform.sh (the A/B override) unpacks it and calls `batman-slot apply`.
# See docs/design/ab-sysupgrade-platform.md and feed/batman-provision/files/usr/lib/batman/platform-ab.sh.
#
#   build-ab-payload.sh <root.squashfs> <bootdir> <board> <out.tar.gz>
#
# <bootdir> is a directory holding the boot FAT contents (kernel8.img, *.dtb, overlays/,
# start4*.elf, fixup4*.dat) — e.g. the mounted boot partition of the built image, or the build's
# boot staging dir. autoboot.txt / cmdline.txt / config.txt are deliberately NOT included (per-slot
# cmdline is written by batman-slot; autoboot.txt is the A/B control plane and must never travel).
set -eu
SQ=${1:-}; BOOTDIR=${2:-}; BOARD=${3:-}; OUT=${4:-}
[ -f "$SQ" ] && [ -d "$BOOTDIR" ] && [ -n "$BOARD" ] && [ -n "$OUT" ] || {
	echo "usage: build-ab-payload.sh <root.squashfs> <bootdir> <board> <out.tar.gz>" >&2; exit 1; }
[ "$(hexdump -n4 -e '4/1 "%c"' "$SQ" 2>/dev/null)" = hsqs ] || { echo "$SQ is not a squashfs" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cp "$SQ" "$T/root.squashfs"
mkdir -p "$T/boot"
for f in kernel8.img start4.elf start4cd.elf start4x.elf fixup4.dat fixup4cd.dat fixup4x.dat; do
	[ -f "$BOOTDIR/$f" ] && cp "$BOOTDIR/$f" "$T/boot/$f"
done
# shellcheck disable=SC2015  # cp-or-true: no .dtb is not fatal here
ls "$BOOTDIR"/*.dtb >/dev/null 2>&1 && cp "$BOOTDIR"/*.dtb "$T/boot/" || true
[ -d "$BOOTDIR/overlays" ] && cp -r "$BOOTDIR/overlays" "$T/boot/"
[ -f "$T/boot/kernel8.img" ] || { echo "no kernel8.img in $BOOTDIR — refusing (would write a slot with no kernel)" >&2; exit 1; }
printf 'board=%s\nversion=%s\n' "$BOARD" "$(date +%Y%m%d-%H%M%S)" > "$T/metadata"

tar -C "$T" -czf "$OUT" root.squashfs boot metadata
echo "wrote $OUT ($(wc -c < "$OUT") bytes): board=$BOARD squashfs=$(wc -c < "$SQ") bytes"
