#!/bin/bash
# tests/prov-p1/s5-bulk-mount.sh <batman-provd.init> — #254 P3 S5 (254-p3-impl §3.8.2): the init (root) mounts provd's
# upload tmpfs: nodev / nosuid / noexec / 0700 / nr_inodes=16 / size per board / provd:provd; never stacked, never
# through a symlink, not for an unknown board or without the stamp. _bulk_mount is extracted from the real init; only
# the stamp path and BDIR point at a scratch dir. Root (mounts). Nothing checked = FAIL.
exec </dev/null
INIT=$(readlink -f "${1:?usage: $0 <batman-provd.init>}")
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (tmpfs mounts)"; exit 1; }
grep -q '^_bulk_mount()' "$INIT" || { echo "FAIL $INIT predates the S5 upload tmpfs: expected red until feat/254-p3 S5 lands (#254)"; exit 1; }
T=$(mktemp -d /tmp/bmt.XXXXXX)
fail=0
F=$T/fn.sh
sed -n '/^BDIR=/,/^}/p' "$INIT" | sed "s#/etc/batman-build#$T/stamp#; s#^BDIR=.*#BDIR=$T/bulk#" > "$F"
grep -q '_bulk_mount()' "$F" || { echo "FAIL: function not extracted"; exit 1; }
SH=$(command -v busybox >/dev/null && echo "busybox sh" || echo dash)
echo "shell: $SH"
run() { $SH -c ". $F; _bulk_mount"; }
ck() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi; }
cleanup() { while awk -v d="$T/bulk" '$2 == d' /proc/mounts | grep -q .; do umount "$T/bulk"; done; rm -rf "$T/bulk"; }

echo "BATMAN_BOARD=ekh-bcm2711" > $T/stamp
run; ck fresh-rc $? 0
m=$(awk -v d="$T/bulk" '$2 == d { print $3, $4 }' /proc/mounts)
echo "  mount: $m"
case "$m" in tmpfs*nosuid*nodev*noexec*) ck fresh-opts ok ok ;; *) ck fresh-opts "$m" "tmpfs nosuid,nodev,noexec" ;; esac
case "$m" in *size=246700k*|*size=246704k*) ck fresh-size ok ok ;; *) ck fresh-size "$m" "size=252619530 B" ;; esac
case "$m" in *nr_inodes=16*) ck fresh-inodes ok ok ;; *) ck fresh-inodes "$m" nr_inodes=16 ;; esac
case "$m" in *mode=700*) ck fresh-mode ok ok ;; *) ck fresh-mode "$m" mode=700 ;; esac
ck fresh-owner "$(stat -c %u:%g $T/bulk)" 471:471
run; ck again-rc $? 0
ck not-stacked "$(awk -v d="$T/bulk" '$2 == d' /proc/mounts | wc -l)" 1
cleanup

mkdir -p $T/other; mount --bind $T/other $T/other 2>/dev/null
mkdir -p $T/bulk; mount -t ramfs none $T/bulk
run; ck foreign-mount-rc $? 1
ck foreign-not-stacked "$(awk -v d="$T/bulk" '$2 == d' /proc/mounts | wc -l)" 1
cleanup; umount $T/other 2>/dev/null

ln -s $T/other $T/bulk
run; ck symlink-rc $? 1
ck symlink-no-mount "$(awk -v d="$T/other" '$2 == d' /proc/mounts | wc -l)" 0
rm -f $T/bulk

: > $T/bulk
run; ck file-rc $? 1
rm -f $T/bulk

echo "BATMAN_BOARD=ekh-unknown" > $T/stamp
run; ck unknown-board-rc $? 1
ck unknown-board-no-mount "$(awk -v d="$T/bulk" '$2 == d' /proc/mounts | wc -l)" 0
rm -f $T/stamp
run; ck no-stamp-rc $? 1

cleanup; rm -rf "$T"
[ $fail = 0 ] && { echo "S5-BULK-MOUNT ALL PASS"; exit 0; } || { echo "S5-BULK-MOUNT SOME FAIL"; exit 1; }
