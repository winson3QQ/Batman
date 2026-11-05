#!/bin/bash
# scripts/dv/eeprom-sbx-254.sh — #254 H4 rootless sandbox for running a node image's first-boot scripts in WSL
# (docs/design/254-h4-harness.md §8.2, H4-U12). NO real root, NOT dv-sbx.sh (CI only, F-H22).
#
#   eeprom-sbx-254.sh prep   <payload.tar.gz> <sha256> <dir>   unpack root.squashfs into <dir>/rootfs (as the user)
#   eeprom-sbx-254.sh escape <dir>                             the escape negatives (each with its control) — FAIL on
#                                                              any that does not hold; run before every arm
#   eeprom-sbx-254.sh run    <dir> <script-in-rootfs> [args]   run one script inside the sandbox
#
# The sandbox: fds >= 3 closed, fd 0 = /dev/null, fd 1/2 = pipes to this shell; env -i; unshare --user
# --map-root-user --mount --pid --fork --net --uts --ipc; inside: bind the rootfs onto itself, pivot_root from the
# HOST cwd, cd /, unmount the old root with the NEW root's busybox (the host umount is gone after pivot_root and
# an old root left mounted keeps the host reachable: v6-A M2), rmdir /old; only /, /proc, /tmp and the three /dev
# binds remain. qemu-aarch64 runs the aarch64 binaries through binfmt with the F flag (F-H31).
set -u
die() { echo "FAIL eeprom-sbx: $*"; exit 1; }
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; RC=1; }
RC=0

# ---- the inner setup, run as "root" of the new user namespace ----
inner() {	# $1 rootfs, $2 old-root mode (keep = the control), $3.. command
	SR=$1; MODE=$2; shift 2
	mount --bind "$SR" "$SR" || exit 90
	for d in null zero urandom; do : > "$SR/dev/$d" 2>/dev/null; mount --bind "/dev/$d" "$SR/dev/$d" || exit 91; done
	mkdir -p "$SR/old" "$SR/proc" "$SR/tmp" || exit 92
	mount -t tmpfs -o size=64m tmpfs "$SR/tmp" || exit 93
	pivot_root "$SR" "$SR/old" || exit 94          # run from the HOST cwd (a `cd $SR` first would hide the cwd escape)
	[ "$MODE" = keep-cwd ] || cd / || exit 95
	mount -t proc proc /proc || exit 96
	if [ "$MODE" != keep-old ]; then
		/bin/busybox umount -l /old || exit 97
		/bin/busybox rmdir /old || exit 98
	fi
	exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

sbx() {	# $1 rootfs, $2 mode (strict | keep-old | keep-cwd | keep-fd), $3.. command (aarch64, inside the rootfs)
	SR=$1; MODE=$2; shift 2
	if [ "$MODE" = keep-fd ]; then
		# the control: a host file left open on fd 7 crosses into the sandbox
		env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/nonexistent \
			unshare --user --map-root-user --mount --pid --fork --net --uts --ipc \
			bash -c "$(declare -f inner); inner \"\$@\"" inner "$SR" strict "$@" </dev/null 7>>"$FDCANARY"
	else
		( for fd in /proc/$BASHPID/fd/*; do fd=${fd##*/}; [ "$fd" -gt 2 ] && eval "exec $fd>&-"; done
		  exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/nonexistent \
			unshare --user --map-root-user --mount --pid --fork --net --uts --ipc \
			bash -c "$(declare -f inner); inner \"\$@\"" inner "$SR" "$MODE" "$@" </dev/null )
	fi
}

cmd_prep() {
	P=$1; SHA=$2; D=$3
	[ -f "$P" ] || die "no payload $P"
	[ "$(sha256sum "$P" | cut -d' ' -f1)" = "$SHA" ] || die "payload sha256 is not the pinned $SHA"
	mkdir -p -m 0700 "$D" || die "cannot create $D"
	tar -xzf "$P" -C "$D" root.squashfs || die "no root.squashfs in the payload"
	rm -rf "$D/rootfs"
	unsquashfs -no-xattrs -q -d "$D/rootfs" "$D/root.squashfs" >/dev/null 2>"$D/unsquashfs.err" || {
		# device nodes cannot be created as a user: that is the only tolerated error
		grep -v -i 'mknod\|device\|create_inode' "$D/unsquashfs.err" | grep -q . && die "unsquashfs: $(head -3 "$D/unsquashfs.err")"
	}
	rm -f "$D/root.squashfs"
	[ -x "$D/rootfs/bin/busybox" ] || die "unpacked rootfs has no /bin/busybox"
	mkdir -p "$D/rootfs/dev"
	ok "prep: $(basename "$P") -> $D/rootfs"
}

cmd_escape() {
	D=$1; SR=$D/rootfs
	[ -x "$SR/bin/busybox" ] || die "no prepared rootfs in $D (run prep first)"
	CAN=$HOME/.batman-dv/sbx-canary; mkdir -p -m 0700 "$HOME/.batman-dv"
	# 0. the sandbox runs at all (a sandbox that never starts would make every negative below "hold")
	o=$(sbx "$SR" strict /bin/busybox echo alive 2>&1); [ "$o" = alive ] && ok "sandbox starts, aarch64 busybox runs (qemu binfmt)" || { bad "sandbox did not start: [$o]"; return; }
	# 1. absolute host path: $HOME is not in the new root
	echo clean > "$CAN"
	sbx "$SR" strict /bin/busybox sh -c "echo pwn > $CAN" >/dev/null 2>&1
	[ "$(cat "$CAN")" = clean ] && ok "absolute path to the host canary: not reachable" || bad "absolute path wrote the host canary"
	echo pwn >> "$CAN.ctl" 2>/dev/null && ok "control: the same write outside the sandbox works" || bad "control: cannot write outside either (no discrimination)"
	rm -f "$CAN.ctl"
	# 2. cwd escape: started from the canary's dir, a relative write
	CD=$HOME/.batman-dv/sbx-cwd; mkdir -p -m 0700 "$CD"; echo clean > "$CD/canary"
	( cd "$CD" && sbx "$SR" strict /bin/busybox sh -c "echo pwn > canary" ) >/dev/null 2>&1
	[ "$(cat "$CD/canary")" = clean ] && ok "cwd escape: blocked (cd / after pivot_root)" || bad "cwd escape: the host file was written"
	( cd "$CD" && sbx "$SR" keep-cwd /bin/busybox sh -c "echo pwn > canary" ) >/dev/null 2>&1
	[ "$(cat "$CD/canary")" = pwn ] && ok "control: without cd / the host file IS written (the test discriminates)" || bad "control: keep-cwd did not write (the cwd test proves nothing)"
	# 3. inherited fd
	FDCANARY=$HOME/.batman-dv/sbx-fd; echo clean > "$FDCANARY"
	( exec 7>>"$FDCANARY"; sbx "$SR" strict /bin/busybox sh -c "echo pwn >&7" ) >/dev/null 2>&1
	[ "$(cat "$FDCANARY")" = clean ] && ok "inherited fd: closed before the sandbox" || bad "inherited fd: the host file was written"
	sbx "$SR" keep-fd /bin/busybox sh -c "echo pwn >&7" >/dev/null 2>&1
	grep -q pwn "$FDCANARY" && ok "control: an fd left open DOES write the host file (the test discriminates)" || bad "control: keep-fd did not write (the fd test proves nothing)"
	# 4. old root
	echo clean > "$CAN"
	o=$(sbx "$SR" strict /bin/busybox sh -c "cat /proc/self/mountinfo | /bin/busybox awk '{print \$5}' | /bin/busybox sort | /bin/busybox tr '\n' ' '; [ -e /old ] && echo OLD; echo pwn > /old$CAN" 2>/dev/null)
	case "$o" in *OLD*) bad "old root: /old still exists";; *) ok "old root: /old gone";; esac
	extra=$(echo "$o" | tr ' ' '\n' | grep -v -x -E '/|/proc|/tmp|/dev/null|/dev/zero|/dev/urandom|' )
	[ -z "$extra" ] && ok "mountinfo has only the whitelist (/ /proc /tmp /dev/{null,zero,urandom})" || bad "mountinfo has more: $extra"
	[ "$(cat "$CAN")" = clean ] && ok "old root: the host canary is not reachable through /old" || bad "old root: wrote the host canary"
	sbx "$SR" keep-old /bin/busybox sh -c "echo pwn > /old$CAN" >/dev/null 2>&1
	[ "$(cat "$CAN")" = pwn ] && ok "control: with the old root kept, the canary IS written (the test discriminates)" || bad "control: keep-old did not write (the old-root test proves nothing)"
	# 5. sanity (not discriminating): host hostname, reboot
	h0=$(hostname); sbx "$SR" strict /bin/busybox hostname sbxtest >/dev/null 2>&1
	[ "$(hostname)" = "$h0" ] && ok "sanity: the host hostname is unchanged" || bad "sanity: the host hostname changed"
	b0=$(cat /proc/sys/kernel/random/boot_id); sbx "$SR" strict /bin/busybox reboot -f >/dev/null 2>&1
	[ "$(cat /proc/sys/kernel/random/boot_id)" = "$b0" ] && ok "sanity: reboot -f in the sandbox did not reboot WSL" || bad "sanity: boot_id changed"
	rm -f "$CAN" "$FDCANARY"; rm -rf "$CD"
	[ $RC = 0 ] && echo "EEPROM-SBX escape: PASS" || echo "EEPROM-SBX escape: FAIL"
	return $RC
}

cmd_run() {
	D=$1; shift
	sbx "$D/rootfs" strict "$@"
}

c=${1:-}; [ $# -gt 0 ] && shift
case "$c" in
	prep) [ $# = 3 ] || die "usage: prep <payload> <sha256> <dir>"; cmd_prep "$@" ;;
	escape) [ $# = 1 ] || die "usage: escape <dir>"; cmd_escape "$1"; exit $? ;;
	run) [ $# -ge 2 ] || die "usage: run <dir> <cmd...>"; cmd_run "$@" ;;
	*) die "usage: prep | escape | run" ;;
esac
