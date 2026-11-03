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

# badpayload <payload.tar.gz> <its sha256> <out.tar.gz>: the whole E-H13 / UD4 payload — the input checked against the
# given sha, root.squashfs through badroot, its SHA256SUMS line replaced by the new sha, every other line kept; checked
# again on the repacked tar. Prints "PAYLOAD-SHA <sha of out>" last. Run in WSL with plain arguments only (shell code
# passed through wsl.exe is expanded twice: 2026-11-03 the inline version lost every $ and the run aborted).
cmd_badpayload() ( # a subshell: its EXIT trap removes the work dir on every exit, die included (a RETURN trap fires
	# when the inner cmd_badroot returns: the first version lost its work dir there)
	bp_in=$1 bp_want=$2 bp_out=$3	# own names: cmd_badroot sets in / out
	[ "$(sha256sum "$bp_in" | cut -d' ' -f1)" = "$bp_want" ] || die "$bp_in does not match the given sha"
	t=$(mktemp -d "$(dirname "$bp_out")/badpayload.XXXXXX") || die "mktemp"
	trap 'rm -rf "$t"' EXIT
	mkdir "$t/p" && tar -xzf "$bp_in" -C "$t/p" || die "unpack $bp_in"
	[ -f "$t/p/root.squashfs" ] && [ -f "$t/p/SHA256SUMS" ] && [ -d "$t/p/boot" ] || die "payload layout: no root.squashfs / SHA256SUMS / boot"
	old=$(awk '$2=="root.squashfs"{print $1}' "$t/p/SHA256SUMS"); [ -n "$old" ] || die "SHA256SUMS has no root.squashfs line"
	[ "$(sha256sum "$t/p/root.squashfs" | cut -d' ' -f1)" = "$old" ] || die "root.squashfs does not match its SHA256SUMS line"
	cmd_badroot "$t/p/root.squashfs" "$t/bad.sq" || die "badroot acceptance"
	mv "$t/bad.sq" "$t/p/root.squashfs"
	new=$(sha256sum "$t/p/root.squashfs" | cut -d' ' -f1)
	cp "$t/p/SHA256SUMS" "$t/sums.orig"
	awk -v n="$new" '$2=="root.squashfs"{$1=n} {print $1 "  " $2}' "$t/sums.orig" > "$t/p/SHA256SUMS"
	[ "$(grep -c "^$new  root.squashfs\$" "$t/p/SHA256SUMS")" = 1 ] && echo "ok   SHA256SUMS: root.squashfs line = the bad rootfs" || die "SHA256SUMS not updated"
	[ "$(awk '$2!="root.squashfs"{print $1, $2}' "$t/sums.orig")" = "$(awk '$2!="root.squashfs"{print $1, $2}' "$t/p/SHA256SUMS")" ] \
		&& echo "ok   SHA256SUMS: every other line kept ($(grep -vc ' root.squashfs$' "$t/p/SHA256SUMS"))" || die "SHA256SUMS changed other lines"
	tar -czf "$bp_out" -C "$t/p" . || die "repack"
	[ "$(tar -xzOf "$bp_out" ./root.squashfs | sha256sum | cut -d' ' -f1)" = "$new" ] && echo "ok   repacked tar carries the bad rootfs" || die "repacked tar"
	echo "PAYLOAD-SHA $(sha256sum "$bp_out" | cut -d' ' -f1)"
)

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	badroot) [ $# = 2 ] || die "usage: badroot <root.squashfs> <out>"; cmd_badroot "$@" ;;
	badpayload) [ $# = 3 ] || die "usage: badpayload <payload.tar.gz> <sha256> <out.tar.gz>"; cmd_badpayload "$@" ;;
	*) die "usage: badroot | badpayload" ;;
esac
