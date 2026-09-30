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
# so every binary we invoke there must be staged into that ramfs. batman-slot + vcmailbox + hexdump
# are ours/separate. dd/mount/awk/grep/sed/wc/cp/printf/tar ARE in the stock sysupgrade ramfs, but
# `tr` is NOT (stock sysupgrade never uses it) — batman-slot's `wc -c | tr -dc 0-9` size sanitise
# then dies "empty squashfs" with `tr: not found`, aborting apply before any write. So stage tr too.
# (#89 bench: confirmed via a stage2 log on p6 — tr was the sole MISSING tool of the set apply uses.
#  If a future bench run reports another missing tool, add its path here.)
# shellcheck disable=SC2034
RAMFS_COPY_BIN='/usr/sbin/batman-slot /usr/bin/vcmailbox /usr/bin/hexdump /usr/bin/tr'

platform_check_image() {
	[ "$#" -gt 1 ] && return 1
	local list=/tmp/ab-check.$$
	# NB: tar is NOT `-z` here. get_image already transparently decompresses a gzip source (it sniffs
	# the 1f8b magic and pipes through `busybox zcat`), so it hands us a PLAIN tar stream; `tar -tzf`
	# would then try to gunzip an already-gunzipped stream and fail with "not a gzip tar". (#89 bench)
	get_image "$@" | tar -tf - >"$list" 2>/dev/null || { echo "not a batman A/B image (not a gzip tar)"; rm -f "$list"; return 1; }
	grep -qx 'root.squashfs' "$list" || { echo "A/B image missing root.squashfs"; rm -f "$list"; return 1; }
	grep -qx 'metadata' "$list"      || { echo "A/B image missing metadata"; rm -f "$list"; return 1; }
	rm -f "$list"

	# SoC gate (#209 review). This MUST live here, not in platform_do_upgrade: by the time
	# do_upgrade runs, sysupgrade has already accepted the image and pivoted to the ramfs, so a
	# complaint there cannot stop anything — and the pre-existing check there only echoed "WARN".
	# Consequence on a single-SoC fleet: none. Consequence once bcm2710 cards exist: a bcm2711
	# image sysupgraded onto a Pi 3A+ is written into the slot, flipped to, and the board is
	# SILENTLY dead (no EEPROM bootloader, so no fallback) — recoverable only by pulling the card.
	# NB the payload's kernel is always named kernel8.img on both SoCs, so neither the tar listing
	# above nor any checksum of it can catch this; only the board token can.
	# Running SoC comes from DISTRIB_TARGET (bcm27xx/bcm2710) — available here because check_image
	# still runs in the full system, before the ramfs pivot.
	local want run wt rt
	want=$(get_image "$@" | tar -xOf - metadata 2>/dev/null | sed -n 's/^board=//p')
	run=$(sed -n "s/^DISTRIB_TARGET='*[^/]*\/\([^']*\)'*$/\1/p" /etc/openwrt_release 2>/dev/null)
	wt=$(soc_token "$want"); rt=$(soc_token "$run")
	# Refuse only on a POSITIVE mismatch of two recognised tokens. If either side is unrecognisable
	# we fall through (board_name spelling has always been allowed to differ — that is why the old
	# check was a warning); what is removed is the `*bcm2711*` wildcard, which made every bcm2711
	# image pass on every board, including the one it cannot boot.
	if [ -n "$wt" ] && [ -n "$rt" ] && [ "$wt" != "$rt" ]; then
		echo "REFUSING: image is for $wt but this node is $rt — flashing it would silently brick the node"
		return 1
	fi
	return 0
}

# bcm2708/9/10/11 = the RPi SoC generations OpenWrt splits bcm27xx into. Empty = unrecognised.
soc_token() {
	case "$1" in
		*bcm2711*) echo bcm2711 ;; *bcm2710*) echo bcm2710 ;;
		*bcm2709*) echo bcm2709 ;; *bcm2708*) echo bcm2708 ;;
		*) echo "" ;;
	esac
}

platform_do_upgrade() {
	local dir=/tmp/ab-payload
	rm -rf "$dir"; mkdir -p "$dir"
	get_image "$@" | tar -xf - -C "$dir" || { echo "A/B image unpack failed"; return 1; }  # -x not -xz: get_image already un-gzips (see platform_check_image)
	[ -f "$dir/root.squashfs" ] || { echo "no root.squashfs in image"; return 1; }

	# board sanity: refuse a grossly-wrong image (best-effort — warn, don't false-refuse on a string
	# mismatch, since board_name spelling can differ from the build's board tag). TODO tighten per-SoC.
	local want run
	want=$(sed -n 's/^board=//p' "$dir/metadata" 2>/dev/null)
	run=$(cat /tmp/sysinfo/board_name 2>/dev/null)
	# Second layer only — the gate that can actually refuse is in platform_check_image above. The
	# `*bcm2711*` wildcard that used to be in this case is GONE: it matched every bcm2711 image on
	# every board, so the one check that existed passed the one case that bricks.
	[ -z "$want" ] || [ -z "$run" ] || case "$run" in *"$want"*) : ;; *) echo "WARN: image board='$want' vs running='$run'";; esac

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
