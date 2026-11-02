#!/bin/bash
# scripts/dv/wsl-rootfs.sh — runs IN WSL for scripts/dv/prov-254.sh (Git Bash): one file of an A/B payload's rootfs.
# A script file, not an inline `wsl.exe bash -c "…"`: wsl.exe expands $variables of an inline command on its way in
# (2026-10-28: the stamp read failed that way). unsquashfs needs a seekable file (F44), so root.squashfs is untarred
# into a private mktemp dir first.
#   wsl-rootfs.sh stamp <payload.tar.gz>        etc/batman-build, EXTRACTED (never -cat: a symlink is not followed);
#                                               rc 1 unless it is a regular file in a real etc/
#   wsl-rootfs.sh cat <payload.tar.gz> <path>   that file's bytes (unsquashfs -cat); rc != 0 when it cannot be read
set -u
op=${1:?usage: wsl-rootfs.sh stamp <payload> | cat <payload> <path>}; p=${2:?payload}
[ -f "$p" ] || { echo "no payload $p" >&2; exit 2; }
t=$(mktemp -d) || exit 2; trap 'rm -rf "$t"' EXIT
tar -xzf "$p" -C "$t" root.squashfs || { echo "no root.squashfs in $p" >&2; exit 2; }
case "$op" in
	stamp)
		unsquashfs -q -no-xattrs -d "$t/r" "$t/root.squashfs" etc/batman-build >/dev/null 2>&1
		f=$t/r/etc/batman-build
		[ -d "$t/r/etc" ] && [ ! -L "$t/r/etc" ] && [ -f "$f" ] && [ ! -L "$f" ] || { echo "etc/batman-build is not a regular file in a real etc/" >&2; exit 1; }
		cat "$f" ;;
	cat)
		unsquashfs -cat "$t/root.squashfs" "${3:?path}" ;;
	*) echo "unknown op $op" >&2; exit 2 ;;
esac
