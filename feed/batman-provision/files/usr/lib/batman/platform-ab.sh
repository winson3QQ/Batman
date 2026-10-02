#!/bin/sh
# A/B platform.sh — make `sysupgrade` write the INACTIVE slot via batman-slot (#89).
# Installed over the stock /lib/upgrade/platform.sh by 98-batman-sysupgrade (overlay copy; the feed
# cannot ship /lib/upgrade/platform.sh directly — build-time file clash with the base, like the
# /www/index.html case). See docs/design/ab-sysupgrade-platform.md.
#
# Image format (our own dedicated A/B target, so no busybox MBR-parse and no OpenWrt metadata
# trailer — REQUIRE_IMAGE_METADATA=0, we do our own board check): a gzip'd tar containing
#   root.squashfs
#   boot/{kernel8.img, *.dtb, overlays/*, start*.elf, fixup*.dat}   # start4* on Pi 4, start* on Pi 3
#   metadata            # board=<board>\nversion=<...>\nsize=<root.squashfs bytes>
#   SHA256SUMS          # sha256 of root.squashfs and every boot/ file (#209 v4.3 D5)
# assembled by scripts/build-ab-payload.sh.
#
# root.squashfs is STREAMED from the image straight onto the target root partition (#209 D7): on a
# 512 MB Pi 3 the /tmp tmpfs cannot hold the uploaded image AND an extracted copy of it.
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
# #209 v4.3 adds the uncached read-back verification (sha256sum/head/tail/cut/cmp) and the Pi 3
# firmware allow-list (RAMFS_COPY_DATA). Prove the set on the bench with a stage2 log, as #89 did.
# shellcheck disable=SC2034
RAMFS_COPY_BIN='/usr/sbin/batman-slot /usr/bin/vcmailbox /usr/bin/hexdump /usr/bin/tr /usr/bin/sha256sum /usr/bin/head /usr/bin/tail /usr/bin/cut /usr/bin/cmp'
# shellcheck disable=SC2034
RAMFS_COPY_DATA='/usr/share/batman/firmware-allowlist-bcm2710.sha256'

platform_check_image() {
	[ "$#" -gt 1 ] && return 1
	local list=/tmp/ab-check.$$
	# NB: tar is NOT `-z` here. get_image already transparently decompresses a gzip source (it sniffs
	# the 1f8b magic and pipes through `busybox zcat`), so it hands us a PLAIN tar stream; `tar -tzf`
	# would then try to gunzip an already-gunzipped stream and fail with "not a gzip tar". (#89 bench)
	get_image "$@" | tar -tf - >"$list" 2>/dev/null || { echo "not a batman A/B image (not a gzip tar)"; rm -f "$list"; return 1; }
	grep -qx 'root.squashfs' "$list" || { echo "A/B image missing root.squashfs"; rm -f "$list"; return 1; }
	grep -qx 'metadata' "$list"      || { echo "A/B image missing metadata"; rm -f "$list"; return 1; }
	grep -qx 'SHA256SUMS' "$list"    || { echo "A/B image has no SHA256SUMS — rebuild it with the current scripts/build-ab-payload.sh (#209)"; rm -f "$list"; return 1; }
	rm -f "$list"

	# A real OTA must always be gated by batman-autocommit: drop any ab-selftest skip-once token left
	# on p6. Here, not only in batman-slot, because p6 may already be unmounted in the ramfs stage.
	rm -f /opt/batdata/state/autocommit-skip-once

	# Pi 4 bootloader floor (#209 S5) — warn only, here in stage 1 where vcgencmd still exists (the
	# ramfs stage has none). Below 2025-08-20 the EEPROM cannot fall back from a slot that fails at
	# the firmware level; the read-back verification is then the only guard. docs/boards-and-builds.md §1
	local bts
	bts=$(vcgencmd bootloader_version 2>/dev/null | sed -n 's/^timestamp //p' | head -1)
	case "$bts" in ''|*[!0-9]*) ;; *) [ "$bts" -lt 1755648000 ] && echo "WARN: Pi 4 bootloader $(vcgencmd bootloader_version 2>/dev/null | head -1) predates 2025-08-20 — no firmware-level fallback on this node; update the EEPROM" ;; esac

	# Running an uncommitted one-shot TRIAL: the inactive slot is the COMMITTED one. Refuse here, in
	# stage 1, before sysupgrade kills services (batman-slot apply refuses too, ab-autocommit v2.2 G/N6).
	if [ "$(hexdump -v -e '1/1 "%02x"' /proc/device-tree/chosen/bootloader/tryboot 2>/dev/null)" = 00000001 ] \
	   && batman-slot is-trial >/dev/null 2>&1; then
		echo "REFUSING: this boot is an uncommitted trial — sysupgrade would overwrite the committed slot. Commit or revert the trial first."
		return 1
	fi

	# Every node-side apply check that needs no payload (#209 S5 review W3): layout vs SoC, MBR, FAT
	# count, firmware partition vs cmdline, p5 seeded, [tryboot] aim. Here a refusal stops sysupgrade
	# with a visible error and the node untouched; in stage 2 the same refusal comes after services
	# are killed and ends in a silent reboot. NB `sysupgrade -F` ignores a failed check — stage 2
	# then repeats every check (batman-slot precheck) and refuses there instead.
	local pn
	pn=$(batman-slot precheck-node 2>&1) || { echo "REFUSING (node not ready for an OTA): ${pn##*batman-slot: }"; return 1; }

	# /tmp budget (#209 D7): do_upgrade extracts everything EXCEPT root.squashfs (streamed) next to
	# the uploaded image. Refuse here, before the pivot, if that cannot fit. Sizes from `tar -tv`.
	local need_kb free_kb
	need_kb=$(get_image "$@" | tar -tvf - 2>/dev/null | awk '$NF!="root.squashfs"{s+=$3} END{print int(s/1024)+16384}')
	free_kb=$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')
	if [ -n "$need_kb" ] && [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ]; then
		echo "REFUSING: /tmp has ${free_kb} KiB free, the boot payload needs ~${need_kb} KiB"
		return 1
	fi

	# SoC gate (#209 review), first layer: refuses BEFORE the ramfs pivot, so a plain `sysupgrade`
	# of a wrong-SoC image stops here with the node untouched. `sysupgrade -F` ignores a failed
	# check, so platform_do_upgrade repeats the same comparison and refuses there too (#209 v4 D8).
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
	# Fail-closed (#209 S5 review): an image or a node whose SoC cannot be recognised is refused too.
	# Every payload that can still pass the SHA256SUMS check above comes from the #209
	# build-ab-payload.sh, which refuses a board name without a SoC token; the pre-#209 payloads
	# (board=rpi4-mm6108-spi) already fail on the missing SHA256SUMS. So nothing legitimate is lost,
	# and a malformed or foreign payload can no longer slip through as "not gated".
	[ -n "$wt" ] || { echo "REFUSING: image metadata board='$want' names no known SoC"; return 1; }
	[ -n "$rt" ] || { echo "REFUSING: cannot tell this node's SoC (DISTRIB_TARGET='$run')"; return 1; }
	if [ "$wt" != "$rt" ]; then
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

# The running SoC as an OpenWrt subtarget name, from the device tree (works inside the sysupgrade
# ramfs). Empty = unrecognised. No `tr` here: the ramfs does not stage it (see RAMFS_COPY_BIN).
soc_running() {
	local c
	c=$(cat /proc/device-tree/compatible 2>/dev/null)
	case "$c" in
		*bcm2711*) echo bcm2711 ;; *bcm2837*) echo bcm2710 ;;
		*bcm2836*) echo bcm2709 ;; *bcm2835*) echo bcm2708 ;;
		*) echo "" ;;
	esac
}

platform_do_upgrade() {
	local dir=/tmp/ab-payload troot
	rm -rf "$dir"; mkdir -p "$dir"
	# everything but root.squashfs (streamed below). -x not -xz: get_image already un-gzips.
	echo 'root.squashfs' > /tmp/ab-exclude
	get_image "$@" | tar -xf - -C "$dir" -X /tmp/ab-exclude || { echo "A/B image unpack failed"; return 1; }
	[ -f "$dir/SHA256SUMS" ] && [ -f "$dir/metadata" ] || { echo "image lacks SHA256SUMS/metadata"; return 1; }

	# SoC gate, second (and under `sysupgrade -F`, the ONLY) layer. -F makes sysupgrade ignore a
	# failed platform_check_image and call us anyway, and the fleet tooling routinely uses -F
	# (#209 E0). Returning 1 here is a real refusal: nothing has been written yet, stage2 then
	# reboots without an argument and the node comes back on its untouched default slot.
	# The running SoC comes from the device tree, which the ramfs still sees (/etc/openwrt_release
	# and board_name are not reliable here: board_name carries no SoC token at all, e.g.
	# "raspberrypi,3-model-a-plus"). bcm2837 is the Pi 3 SoC that OpenWrt builds as bcm2710.
	local want run wt rt
	want=$(sed -n 's/^board=//p' "$dir/metadata" 2>/dev/null)
	run=$(soc_running)
	wt=$(soc_token "$want"); rt=$(soc_token "$run")
	# fail-closed, as in platform_check_image (this is the only layer under -F)
	if [ -z "$wt" ] || [ -z "$rt" ]; then
		echo "REFUSING: SoC not recognised (image board='$want', running='$run') — not writing anything"
		return 1
	fi
	if [ "$wt" != "$rt" ]; then
		echo "REFUSING: image is for $wt but this node is $rt — not writing anything"
		return 1
	fi

	# batman-slot's [tryboot] read + boot write need bootA (autoboot.txt) mounted; the sysupgrade
	# ramfs pivot may have unmounted /boot, so re-mount p1 there if needed (mkdir first — in the
	# ramfs /boot may not exist).
	mkdir -p /boot
	grep -q ' /boot ' /proc/mounts || mount -t vfat -o rw /dev/mmcblk0p1 /boot 2>/dev/null

	# 1) every check, then clear the target overlay window — nothing is streamed before this passes
	troot=$(batman-slot stage-root "$dir") || { echo "batman-slot stage-root refused"; return 1; }
	[ -b "$troot" ] || { echo "stage-root gave no target device ('$troot')"; return 1; }
	# 2) stream the rootfs straight onto the target root partition (no /tmp copy)
	get_image "$@" | tar -xOf - root.squashfs | dd of="$troot" bs=1M conv=fsync 2>/dev/null \
		|| { echo "rootfs stream to $troot failed"; return 1; }
	sync
	# 3) boot files, uncached read-back of rootfs + boot against SHA256SUMS, then arm + read back
	#    the one-shot tryboot. A failed verification invalidates the target slot and arms nothing,
	#    and stage2's plain reboot then lands on the untouched default slot.
	batman-slot apply "$dir" || { echo "batman-slot apply failed"; return 1; }
	# the harness reboots next; the firmware then trials the freshly-written inactive slot. Commit
	# (making it the default) happens later, gated on a soaked-healthy verdict — NOT here.
	return 0
}

# config crosses A/B slots via p5 (96-batman-config-migrate); no stock single-slot tar handling.
platform_copy_config() { :; }
platform_restore_backup() { :; }
