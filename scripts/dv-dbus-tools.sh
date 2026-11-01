#!/bin/bash
# scripts/dv-dbus-tools.sh — copy dbus-send (the real ELF, not the libtool wrapper) out of a firmware build tree into the
# harness's own fixed directory, with SHA256SUMS (#254 254-h23 §4 prov-sec-dbus-254; F16: the image has no dbus-send,
# libdbus-1.so.3 is there). A test tool: never part of an image. Run in WSL.
#   scripts/dv-dbus-tools.sh [firmware tree] [dest]
# The a72 tree only (bcm2711; the a53 tree has a file of the same name): ELF magic 7f454c46 and e_machine b700 (aarch64)
# are asserted. dest defaults to $DV_DBUS_TOOLS or /mnt/c/Users/yello/batman-dv-tools/dbus (the Git Bash harness's
# ~/batman-dv-tools/dbus). Refuses to overwrite a different existing copy.
set -eu
fw=${1:-/home/yello/firmware-2710}
dst=${2:-${DV_DBUS_TOOLS:-/mnt/c/Users/yello/batman-dv-tools/dbus}}
src=$fw/build_dir/target-aarch64_cortex-a72_musl/dbus-1.14.10/tools/.libs/dbus-send
[ -f "$src" ] || { echo "FAIL $src missing"; exit 1; }
[ "$(head -c 4 "$src" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || { echo "FAIL $src is not an ELF (the libtool wrapper?)"; exit 1; }
[ "$(dd if="$src" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = b700 ] || { echo "FAIL $src is not aarch64"; exit 1; }
new=$(sha256sum < "$src" | cut -c1-64)
mkdir -p "$dst"
if [ -f "$dst/SHA256SUMS" ]; then
	old=$(awk '$2 == "dbus-send" {print $1}' "$dst/SHA256SUMS")
	[ "$new" = "$old" ] && { echo "ok   $dst already holds this dbus-send ($new)"; exit 0; }
	echo "FAIL $dst holds a different dbus-send — move it away first (old: $old new: $new)"; exit 1
fi
cp "$src" "$dst/dbus-send"
(cd "$dst" && sha256sum dbus-send > SHA256SUMS && sha256sum -c --quiet SHA256SUMS && cat SHA256SUMS)
echo "ok   dbus-send copied to $dst"
