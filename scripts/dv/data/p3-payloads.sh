#!/bin/bash
# scripts/dv/data/p3-payloads.sh — #254 H4 payload generators (docs/design/254-h4-harness.md §8.1).
#
#   p3-payloads.sh badroot <root.squashfs in> <out>    the "new version does not boot" rootfs (UD4, E-H13):
#       the squashfs magic "hsqs" is KEPT (batman-slot's precheck refuses a payload whose rootfs is not a squashfs,
#       batman-slot:614-618), s_major (offset 28, u16 LE, = 4) becomes 0xFFFF, the length is unchanged. The kernel
#       refuses s_major != 4 at mount (fs/squashfs/super.c:158-166, F-H54) -> "VFS: unable to mount root" -> panic
#       -> panic=10 (F-H16) -> the one-shot tryboot falls back to the default slot.
#       Offline acceptance (non-root): magic still hsqs, `unsquashfs -s` fails, offset 1080 is not the ext4 magic
#       0xEF53 (rootfstype=squashfs,ext4 must not find an ext4 there either), length unchanged.
#   (malicious tars, SHA256SUMS order, version-parse and the UD8c repack come with the update units)
set -u
die() { echo "FAIL p3-payloads: $*"; exit 1; }

u16le() { od -An -tu2 -j "$2" -N2 --endian=little "$1" | tr -d ' '; }

cmd_badroot() {
	in=$1; out=$2
	[ "$(head -c4 "$in")" = hsqs ] || die "$in is not a squashfs (no hsqs magic)"
	[ "$(u16le "$in" 28)" = 4 ] || die "$in: s_major is $(u16le "$in" 28), not 4"
	cp --reflink=auto "$in" "$out" || die "copy"
	printf '\377\377' | dd of="$out" bs=1 seek=28 count=2 conv=notrunc status=none || die "patch"
	# acceptance
	rc=0
	[ "$(head -c4 "$out")" = hsqs ] && echo "ok   magic kept: hsqs" || { echo "FAIL magic changed"; rc=1; }
	[ "$(u16le "$out" 28)" = 65535 ] && echo "ok   s_major = 0xFFFF" || { echo "FAIL s_major not patched"; rc=1; }
	[ "$(stat -c %s "$in")" = "$(stat -c %s "$out")" ] && echo "ok   length unchanged ($(stat -c %s "$out") B)" || { echo "FAIL length changed"; rc=1; }
	unsquashfs -s "$out" >/dev/null 2>&1 && { echo "FAIL unsquashfs -s still reads it"; rc=1; } || echo "ok   unsquashfs -s refuses it"
	unsquashfs -s "$in" >/dev/null 2>&1 && echo "ok   control: unsquashfs -s reads the original" || { echo "FAIL control: the original is unreadable too (no discrimination)"; rc=1; }
	[ "$(u16le "$out" 1080)" != 61267 ] && echo "ok   offset 1080 is not the ext4 magic 0xEF53" || { echo "FAIL ext4 magic at 1080"; rc=1; }
	echo "sha256 $(sha256sum "$out" | cut -d' ' -f1)"
	return $rc
}

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	badroot) [ $# = 2 ] || die "usage: badroot <root.squashfs> <out>"; cmd_badroot "$@" ;;
	*) die "usage: badroot" ;;
esac
