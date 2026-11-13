#!/bin/bash
# tests/prov-p1/s5-bulk-mount.sh <batman-provd.init> — #254 P3 S5 (254-p3-impl §3.8.2): the init (root) mounts provd's
# upload tmpfs: nodev / nosuid / noexec / 0700 / nr_inodes=16 / size per board / provd:provd; never stacked, never
# through a symlink, not for an unknown board or without the stamp. _bulk_mount is extracted from the real init; only
# the stamp path and BDIR point at a scratch dir. Root (mounts). Nothing checked = FAIL. Both boards (ekh-bcm2711 and
# ekh-bcm2710 share one size today; each is mounted and its size checked). An EXIT trap unmounts whatever is left (a
# mutant that follows the symlink mounts on $T/other). Known limit asserted as such: a tmpfs someone else (root) already
# mounted on BDIR is taken as ours, whatever its options (design §7: only root can do it).
exec </dev/null
INIT=$(readlink -f "${1:?usage: $0 <batman-provd.init>}")
[ "$(id -u)" = 0 ] || { echo "FAIL needs root (tmpfs mounts)"; exit 1; }
grep -q '^_bulk_mount()' "$INIT" || { echo "FAIL $INIT predates the S5 upload tmpfs: expected red until feat/254-p3 S5 lands (#254)"; exit 1; }
T=$(mktemp -d /tmp/bmt.XXXXXX)
fail=0; n=0
umount_all() { for d in "$T/bulk" "$T/other"; do while awk -v d="$d" '$2 == d' /proc/mounts | grep -q .; do umount "$d" || break; done; done; }
trap 'umount_all; rm -rf "$T"' EXIT
F=$T/fn.sh
sed -n '/^BDIR=/,/^}/p' "$INIT" | sed "s#/etc/batman-build#$T/stamp#; s#^BDIR=.*#BDIR=$T/bulk#" > "$F"
grep -q '_bulk_mount()' "$F" || { echo "FAIL: function not extracted"; exit 1; }
SH=$(command -v busybox >/dev/null && echo "busybox sh" || echo dash)
echo "shell: $SH"
run() { $SH -c ". $F; _bulk_mount"; }
ck() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi; }
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

echo "BATMAN_BOARD=ekh-bcm2710" > $T/stamp   # the other board (two-board rule)
run; ck bcm2710-rc $? 0
m=$(awk -v d="$T/bulk" '$2 == d { print $3, $4 }' /proc/mounts)
case "$m" in tmpfs*nosuid*nodev*noexec*) ck bcm2710-opts ok ok ;; *) ck bcm2710-opts "$m" "tmpfs nosuid,nodev,noexec" ;; esac
case "$m" in *size=246700k*|*size=246704k*) ck bcm2710-size ok ok ;; *) ck bcm2710-size "$m" "size=252619530 B" ;; esac
case "$m" in *nr_inodes=16*) ck bcm2710-inodes ok ok ;; *) ck bcm2710-inodes "$m" nr_inodes=16 ;; esac
cleanup
echo "BATMAN_BOARD=ekh-bcm2711" > $T/stamp

# known limit (review r1 B-m5, design §7): a foreign tmpfs already on BDIR (only root can mount one) is accepted as
# ours — rc 0, left as it is (here: no noexec, 1 MiB). If the product starts refusing it, change this case.
mkdir -p $T/bulk; mount -t tmpfs -o size=1m,mode=0755 none $T/bulk
run; ck foreign-tmpfs-accepted-rc $? 0
m=$(awk -v d="$T/bulk" '$2 == d { print $4 }' /proc/mounts)
case "$m" in *noexec*) ck foreign-tmpfs-left-as-is "$m" "its own options (no noexec)" ;; *) ck foreign-tmpfs-left-as-is ok ok ;; esac
ck foreign-tmpfs-not-stacked "$(awk -v d="$T/bulk" '$2 == d' /proc/mounts | wc -l)" 1
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

cleanup
[ "$n" -ge 23 ] || { echo "FAIL only $n checks ran, want >= 23"; fail=1; }
[ $fail = 0 ] && { echo "S5-BULK-MOUNT checks=$n ALL PASS"; exit 0; } || { echo "S5-BULK-MOUNT checks=$n SOME FAIL"; exit 1; }
