#!/bin/sh
# scripts/node/prov-sec-254.sh — #254 tier A prov-sec-helper-uid-254 / prov-sec-key-perms-254 judge (docs/design/
# 254-h23-harness.md §4.5; F10, F11). Read-only; run as root via `ssh node sh -s`. busybox ash.
#   helper-uid  the helper runs as uid / gid 0; its socket dir /tmp/run/batman-prov is a root:471 0750 directory (not a
#               symlink); helper.sock is a root:471 0660 socket and the only entry in the dir
#   key-perms   /etc/batman-prov/identity is root 0700; node.key, ecdh.key, claim.secret are root 0600 regular files with
#               one link (a bind-mounted 0644 copy is the white-box negative control, run by the host under a lease)
# Each check prints PASS / FAIL; the last line "PROV-SEC fails=<n>".
set -u
fails=0
ok(){ echo "PASS $*"; }; no(){ echo "FAIL $*"; fails=$((fails + 1)); }
lsn(){ ls -ldn "$1" 2>/dev/null | awk '{print $1, $3, $4, $2}'; }   # mode uid gid links
p=$(pidof batman-provhelper | awk '{print $1}')
if [ -n "$p" ]; then
	u=$(awk '/^Uid:/ {print $2 "/" $3}' /proc/$p/status); g=$(awk '/^Gid:/ {print $2 "/" $3}' /proc/$p/status)
	[ "$u" = 0/0 ] && [ "$g" = 0/0 ] && ok "helper pid $p runs as uid 0 / gid 0" || no "helper pid $p uid [$u] gid [$g]"
else no "the helper is not running"; fi
D=/tmp/run/batman-prov
[ -L "$D" ] && no "$D is a symlink"
set -- $(lsn "$D"); [ "${1:-}" = drwxr-x--- ] && [ "${2:-}" = 0 ] && [ "${3:-}" = 471 ] && ok "$D root:471 0750" || no "$D [$(lsn "$D")] (want drwxr-x--- 0 471)"
set -- $(lsn "$D/helper.sock"); [ "${1:-}" = srw-rw---- ] && [ "${2:-}" = 0 ] && [ "${3:-}" = 471 ] && ok "helper.sock root:471 0660" || no "helper.sock [$(lsn "$D/helper.sock")] (want srw-rw---- 0 471)"
x=$(ls -A "$D" 2>/dev/null | grep -vx helper.sock | tr '\n' ' '); [ -z "$x" ] && ok "$D holds helper.sock only" || no "$D holds more: $x"
I=/etc/batman-prov/identity
[ -L "$I" ] && no "$I is a symlink"
set -- $(lsn "$I"); [ "${1:-}" = drwx------ ] && [ "${2:-}" = 0 ] && ok "$I root 0700" || no "$I [$(lsn "$I")]"
for f in node.key ecdh.key claim.secret; do
	[ -f "$I/$f" ] && [ ! -L "$I/$f" ] || { no "$I/$f is not a regular file"; continue; }
	set -- $(lsn "$I/$f"); [ "$1" = -rw------- ] && [ "$2" = 0 ] && [ "$4" = 1 ] && ok "$f root 0600, one link" || no "$f [$(lsn "$I/$f")] (want -rw------- 0 _ 1)"
	# a bind mount over the file (the negative control's shape) shows up in mountinfo
	grep -q " $I/$f " /proc/self/mountinfo && no "$I/$f is a mount point (bind-mounted over)"
done
echo "PROV-SEC fails=$fails"; [ $fails = 0 ]
