#!/bin/sh
# A/B platform.sh — make `sysupgrade` write the INACTIVE slot via batman-slot (#89).
# Installed over the stock /lib/upgrade/platform.sh by 98-batman-sysupgrade (overlay copy; the feed
# cannot ship /lib/upgrade/platform.sh directly — build-time file clash with the base, like the
# /www/index.html case). See docs/design/ab-sysupgrade-platform.md.
#
# Image format (our own dedicated A/B target, so no busybox MBR-parse and no OpenWrt metadata
# trailer — REQUIRE_IMAGE_METADATA=0, we do our own board check): a gzip'd tar containing
#   root.squashfs
#   boot/{kernel8.img, *.dtb, overlays/*, start4*.elf, fixup4*.dat}
#   metadata            # board=<board>\nversion=<...>
# assembled by scripts/build-ab-payload.sh.
#
# Config crosses slots via p5 + 96-batman-config-migrate, so the stock single-slot config tar dance
# is neutralised below — invoke as `sysupgrade -n <image>`.

# shellcheck shell=ash  # OpenWrt runs /lib/upgrade/* under busybox ash (local is supported)
. /lib/functions.sh
# shellcheck disable=SC2034  # read by the sysupgrade harness, not by this file
REQUIRE_IMAGE_METADATA=0
# sysupgrade pivots to a ramfs and unmounts the squashfs rootfs BEFORE calling platform_do_upgrade,
# so every non-busybox binary we invoke there must be staged into that ramfs. batman-slot + vcmailbox
# + hexdump are ours/separate; dd/mount/awk/grep/sed/wc/cp/printf/tr/tar are busybox applets already
# copied. (If a bench run reports 'batman-slot: not found' or a missing tool, add it here.)
# shellcheck disable=SC2034
RAMFS_COPY_BIN='/usr/sbin/batman-slot /usr/bin/vcmailbox /usr/bin/hexdump'

platform_check_image() {
	[ "$#" -gt 1 ] && return 1
	local list=/tmp/ab-check.$$
	get_image "$@" | tar -tzf - >"$list" 2>/dev/null || { echo "not a batman A/B image (not a gzip tar)"; rm -f "$list"; return 1; }
	grep -qx 'root.squashfs' "$list" || { echo "A/B image missing root.squashfs"; rm -f "$list"; return 1; }
	grep -qx 'metadata' "$list"      || { echo "A/B image missing metadata"; rm -f "$list"; return 1; }
	rm -f "$list"
	return 0
}

platform_do_upgrade() {
	local dir=/tmp/ab-payload
	rm -rf "$dir"; mkdir -p "$dir"
	get_image "$@" | tar -xzf - -C "$dir" || { echo "A/B image unpack failed"; return 1; }
	[ -f "$dir/root.squashfs" ] || { echo "no root.squashfs in image"; return 1; }

	# board sanity: refuse a grossly-wrong image (best-effort — warn, don't false-refuse on a string
	# mismatch, since board_name spelling can differ from the build's board tag). TODO tighten per-SoC.
	local want run
	want=$(sed -n 's/^board=//p' "$dir/metadata" 2>/dev/null)
	run=$(cat /tmp/sysinfo/board_name 2>/dev/null)
	[ -z "$want" ] || [ -z "$run" ] || case "$run" in *"$want"*|*bcm2711*) : ;; *) echo "WARN: image board='$want' vs running='$run'";; esac

	# batman-slot's [tryboot] read + boot write need bootA (autoboot.txt) mounted; the sysupgrade
	# ramfs pivot may have unmounted /boot, so re-mount p1 there if needed (mkdir first — in the
	# ramfs /boot may not exist).
	mkdir -p /boot
	grep -q ' /boot ' /proc/mounts || mount -t vfat -o rw /dev/mmcblk0p1 /boot 2>/dev/null

	# write the inactive slot + arm the one-shot tryboot (batman-slot NEVER touches autoboot.txt).
	batman-slot apply "$dir" || { echo "batman-slot apply failed"; return 1; }
	# the harness reboots next; the firmware then trials the freshly-written inactive slot. Commit
	# (making it the default) happens later, gated on a soaked-healthy verdict — NOT here.
	return 0
}

# config crosses A/B slots via p5 (96-batman-config-migrate); no stock single-slot tar handling.
platform_copy_config() { :; }
platform_restore_backup() { :; }
