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
#   p3-payloads.sh badpayload <V.tar.gz> <V sha256> <out>   UD4 / E-H13: root.squashfs through badroot, its SHA256SUMS
#       line updated (every other line kept), repacked in V's member order (also UD20c's Y: its sums_sha != V's)
#   p3-payloads.sh malicious <1|2|3|4> <V.tar.gz> <V sha256> <out>   UD8 (254-v16-ud.md §3.3):
#       1 the first listed boot/overlays/*.dtbo becomes a symlink of the same name ("is not a regular file")
#       2 one extra regular member after root.squashfs ("members after root.squashfs")
#       3 V itself + exactly 4096 random bytes after the gzip stream ("data after the gzip stream"); sign V with
#         signrel --size-of <out> (the tar stream is V's, byte for byte — stricter than a repack)
#       4 one extra boot/overlays/ directory entry before root.squashfs ("too many members": V has exactly
#         len(SHA256SUMS) + 4 members)
#   p3-payloads.sh mutate <V.tar.gz> <V sha256> <out>   UD8c: V's tar stream with a region of root.squashfs zeroed, the
#       file exactly V's length (p3-accept.py mutate-make)
#   p3-payloads.sh accept <kind> <V.tar.gz> <out>   the per-generator acceptance (p3-accept.py; kind = mal1..mal4 |
#       mutate | badpayload). Every generator runs it on its output; "PAYLOAD-SHA <sha>" is printed last only on a pass.
# Shared repack (§3.3): `tar --no-recursion -T <V's own member list, in V's order>` from the extracted tree with the one
# delta inserted, never `tar -C dir .` (members "./…": the worker wants SHA256SUMS first, metadata second).
# Run in WSL (GNU tar, python3) with plain arguments only.
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

# ---- shared: input check, extraction, repack in V's order -------------------------------------------------------------
v_in() {	# <V> <sha> -> the tree in $t/p and V's member list in $t/list (the caller's subshell traps the cleanup of $t)
	[ -s "$1" ] || die "$1 missing or empty"
	[ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || die "$1 does not match the given sha"
	mkdir "$t/p" && tar -xpzf "$1" -C "$t/p" || die "unpack $1"
	tar -tzf "$1" > "$t/list" || die "list $1"
	[ "$(sed -n 1p "$t/list")" = SHA256SUMS ] && [ "$(sed -n 2p "$t/list")" = metadata ] && [ "$(tail -1 "$t/list")" = root.squashfs ] \
		|| die "$1 is not in build-ab-payload order (SHA256SUMS, metadata, ..., root.squashfs)"
}
# repack <tree> <V's member list> <out> [after-root <name>] [before-root <name>]: V's order, the extra name at its place
repack() {
	rp_d=$1 rp_l=$2 rp_o=$3; shift 3; rp_after=""; rp_before=""
	while [ $# -ge 2 ]; do case "$1" in after-root) rp_after=$2 ;; before-root) rp_before=$2 ;; *) die "repack: $1" ;; esac; shift 2; done
	awk -v a="$rp_after" -v b="$rp_before" '$0 == "root.squashfs" && b != "" { print b } { print } $0 == "root.squashfs" && a != "" { print a }' "$rp_l" > "$rp_l.repack"
	tar -C "$rp_d" --no-recursion --numeric-owner --owner=0 --group=0 -czf "$rp_o" -T "$rp_l.repack" || die "repack"
}
# acc <kind> <V> <out>: the per-generator acceptance (254-v16-ud §3.3); "ACCEPT <kind> ok|FAIL" last, rc 0 = ok
acc() { python3 -I "$(dirname "$0")/p3-accept.py" "$@"; }
done_out() {	# <kind> <V> <out>: acceptance, then PAYLOAD-SHA
	acc "$1" "$2" "$3" || die "$1: acceptance failed"
	echo "PAYLOAD-SHA $(sha256sum "$3" | cut -d' ' -f1)"
}

# badpayload <payload.tar.gz> <its sha256> <out.tar.gz>: the whole E-H13 / UD4 payload — the input checked against the
# given sha, root.squashfs through badroot, its SHA256SUMS line replaced by the new sha, every other line kept; repacked
# in V's member order and accepted (listing = V's, sums_sha != V's). Prints "PAYLOAD-SHA <sha of out>" last.
cmd_badpayload() ( # a subshell: its EXIT trap removes the work dir on every exit, die included
	bp_in=$1 bp_want=$2 bp_out=$3	# own names: cmd_badroot sets in / out
	t=$(mktemp -d "$(dirname "$bp_out")/badpayload.XXXXXX") || die "mktemp"
	trap 'rm -rf "$t"' EXIT
	v_in "$bp_in" "$bp_want"
	old=$(awk '$2=="root.squashfs"{print $1}' "$t/p/SHA256SUMS"); [ -n "$old" ] || die "SHA256SUMS has no root.squashfs line"
	[ "$(sha256sum "$t/p/root.squashfs" | cut -d' ' -f1)" = "$old" ] || die "root.squashfs does not match its SHA256SUMS line"
	cmd_badroot "$t/p/root.squashfs" "$t/bad.sq" || die "badroot acceptance"
	touch -r "$t/p/root.squashfs" "$t/bad.sq"; chmod --reference="$t/p/root.squashfs" "$t/bad.sq"; mv "$t/bad.sq" "$t/p/root.squashfs"
	new=$(sha256sum "$t/p/root.squashfs" | cut -d' ' -f1)
	cp -p "$t/p/SHA256SUMS" "$t/sums.orig"
	awk -v n="$new" '$2=="root.squashfs"{$1=n} {print $1 "  " $2}' "$t/sums.orig" > "$t/p/SHA256SUMS"; touch -r "$t/sums.orig" "$t/p/SHA256SUMS"
	[ "$(grep -c "^$new  root.squashfs\$" "$t/p/SHA256SUMS")" = 1 ] || die "SHA256SUMS not updated"
	repack "$t/p" "$t/list" "$bp_out"
	done_out badpayload "$bp_in" "$bp_out"
)
cmd_malicious() (
	n=$1 m_in=$2 m_want=$3 m_out=$4
	t=$(mktemp -d "$(dirname "$m_out")/malicious.XXXXXX") || die "mktemp"
	trap 'rm -rf "$t"' EXIT
	case "$n" in
	1)	v_in "$m_in" "$m_want"
		f=$(grep -m1 '^boot/overlays/.*\.dtbo$' "$t/list") || die "no boot/overlays/*.dtbo in V"
		rm "$t/p/$f" && ln -s ../config.txt "$t/p/$f" || die "symlink $f"
		repack "$t/p" "$t/list" "$m_out" ;;
	2)	v_in "$m_in" "$m_want"
		printf 'dv-ud8-2 extra member\n' > "$t/p/dv-extra"
		repack "$t/p" "$t/list" "$m_out" after-root dv-extra ;;
	3)	[ -s "$m_in" ] && [ "$(sha256sum "$m_in" | cut -d' ' -f1)" = "$m_want" ] || die "$m_in does not match the given sha"
		cp "$m_in" "$m_out" && head -c 4096 /dev/urandom >> "$m_out" || die "append" ;;
	4)	v_in "$m_in" "$m_want"
		repack "$t/p" "$t/list" "$m_out" before-root boot/overlays/ ;;
	*) die "malicious 1|2|3|4" ;;
	esac
	done_out "mal$n" "$m_in" "$m_out"
)
cmd_mutate() (
	[ -s "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ] || die "$1 does not match the given sha"
	python3 -I "$(dirname "$0")/p3-accept.py" mutate-make "$1" "$3" || die "mutate"
	done_out mutate "$1" "$3"
)
cmd_accept() { [ $# = 3 ] || die "usage: accept <kind> <V> <out>"; [ -s "$2" ] || die "no V $2"; acc "$@"; }

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	badroot) [ $# = 2 ] || die "usage: badroot <root.squashfs> <out>"; cmd_badroot "$@" ;;
	badpayload) [ $# = 3 ] || die "usage: badpayload <payload.tar.gz> <sha256> <out.tar.gz>"; cmd_badpayload "$@" ;;
	malicious) [ $# = 4 ] || die "usage: malicious <1-4> <payload.tar.gz> <sha256> <out.tar.gz>"; cmd_malicious "$@" ;;
	mutate) [ $# = 3 ] || die "usage: mutate <payload.tar.gz> <sha256> <out.tar.gz>"; cmd_mutate "$@" ;;
	accept) cmd_accept "$@" ;;
	*) die "usage: badroot | badpayload | malicious | mutate | accept" ;;
esac
