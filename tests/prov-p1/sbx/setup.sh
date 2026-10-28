#!/bin/bash
# tests/prov-p1/sbx/setup.sh <root> <loop dev> <case> <mutant|-> — run by scripts/dv-sbx.sh inside
# `unshare --mount --pid --fork --net --uts --ipc --propagation private` (254-p1-impl §4.10): builds the sandbox's
# private mounts, then drops the capabilities and chroots into the case. Host-side bash, root.
set -u
RT=$1; LOOP=$2; CASE=$3; MUT=$4
fail(){ echo "FAIL setup: $*"; echo "CASE $CASE cases=0 fails=1"; exit 1; }
[ $$ = 1 ] || fail "not pid 1 of a new pid namespace (pid $$) — refusing (a reboot -f here would hit the host)"
[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net 2>/dev/null)" ] || true   # /proc is still the host's here
mount -t proc proc "$RT/proc" || fail "mount proc"
[ -e "$RT/proc/device-tree" ] && fail "/proc/device-tree exists in the sandbox's proc"
for p in sys sysrq-trigger; do mount --bind "$RT/proc/$p" "$RT/proc/$p" && mount -o remount,bind,ro "$RT/proc/$p" || fail "ro bind /proc/$p"; done
mount -t tmpfs -o mode=0755 tmpfs "$RT/dev" || fail "tmpfs /dev"
mknod -m 0666 "$RT/dev/null" c 1 3 && mknod -m 0666 "$RT/dev/zero" c 1 5 && mknod -m 0666 "$RT/dev/urandom" c 1 9 || fail "mknod null/zero/urandom"
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
# shellcheck disable=SC2046  # two numbers, split on purpose
set -- $(stat -L -c '%t %T' "$LOOP"); mknod -m 0600 "$RT/dev/mmcblk0p5" b $((0x$1)) $((0x$2)) || fail "mknod mmcblk0p5 -> $LOOP"
: > "$RT/dev/kmsg"   # a regular file: nothing reaches the host's kernel log
mkdir -p "$RT/opt/batdata" "$RT/tmp" && mount -t tmpfs tmpfs "$RT/opt/batdata" && mount -t tmpfs tmpfs "$RT/tmp" \
	&& mkdir -p "$RT/tmp/run" && mount -t tmpfs -o mode=0755 tmpfs "$RT/tmp/run" || fail "tmpfs /opt/batdata /tmp /tmp/run"
mkdir -p "$RT/sbx/run" && mount -t tmpfs tmpfs "$RT/sbx/run" || fail "tmpfs /sbx/run"
printf 'console=serial0,115200 root=PARTUUID=00000000-0002 rootfstype=squashfs batman_slot=A\n' > "$RT/sbx/run/cmdline"
mount --bind "$RT/sbx/run/cmdline" "$RT/proc/cmdline" || fail "fake /proc/cmdline"
[ -z "$(ls -A "$RT/sys" 2>/dev/null)" ] || fail "/sys is not empty in the root"
exec capsh --drop=cap_sys_boot,cap_sys_module,cap_sys_time,cap_sys_rawio,cap_mknod -- -c \
	"exec chroot '$RT' /usr/bin/env -i PATH=/sbx/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root SBX_CASE='$CASE' SBX_MUTANT='$MUT' SBX_MARKER='${SBX_MARKER:-}' SBX_IF='${SBX_IF:-}' /bin/sh /sbx/cases/$CASE.sh"
