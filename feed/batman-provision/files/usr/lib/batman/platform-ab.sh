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
# #280: the root-only run dir helper (rundir.sh) and mktemp — every private temp file and the p6 trace
# mount live in /tmp/run/batman, which crosses into the ramfs with /tmp.
# shellcheck disable=SC2034
RAMFS_COPY_BIN='/usr/sbin/batman-slot /usr/sbin/batman-reboot /usr/bin/vcmailbox /usr/bin/hexdump /usr/bin/tr /usr/bin/sha256sum /usr/bin/head /usr/bin/tail /usr/bin/cut /usr/bin/cmp /bin/mktemp'
# shellcheck disable=SC2034
RAMFS_COPY_DATA='/usr/share/batman/firmware-allowlist-bcm2710.sha256 /usr/lib/batman/otatrace.sh /usr/lib/batman/bootfacts.sh /usr/lib/batman/rundir.sh'

# OTA flight recorder (#209 S5, docs/design/ota-trace.md). Functions only; a missing or broken lib
# degrades to no trace, never to a different upgrade decision.
# shellcheck source=/dev/null
[ -f /usr/lib/batman/otatrace.sh ] && . /usr/lib/batman/otatrace.sh
type otalog >/dev/null 2>&1 || { otalog() { :; }; otalog_k() { :; }; ota_get() { :; }; ota_thr() { :; }; }
# shellcheck source=/dev/null
[ -f /usr/lib/batman/bootfacts.sh ] && . /usr/lib/batman/bootfacts.sh
# shellcheck source=/dev/null
[ -r /usr/lib/batman/rundir.sh ] && . /usr/lib/batman/rundir.sh
RUNDIR=${RUNDIR:-/nonexistent/batman-rundir}
type batman_tmp >/dev/null 2>&1 || batman_tmp() { return 1; }
type batman_rundir >/dev/null 2>&1 || batman_rundir() { return 1; }
# root-owned, not a symlink, single link (#280 D2)
opf() { [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ "$(ls -ln "$1" 2>/dev/null | awk '{print $2}')" = 1 ]; }

# Stage 1 (also run by validate_firmware_image / `sysupgrade -T` / LuCI): trace the verdict ONLY —
# no state file, so a mere validation leaves nothing that a later boot could misread as an OTA.
platform_check_image() {
	local out rc caller
	out=$(_ab_check_image "$@" 2>&1); rc=$?
	[ -n "$out" ] && echo "$out"
	caller=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | cut -c1-60)
	otalog S1 CHECK rc=$rc caller="$caller" msg="$(echo "$out" | tail -1)"
	return $rc
}
_ab_check_image() {
	[ "$#" -gt 1 ] && return 1
	local list
	list=$(batman_tmp ab-check 2>/dev/null || mktemp /tmp/ab-check.XXXXXX) || { echo "cannot create a temp file"; return 1; }
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

# ---- stage 2 flight recorder (#209 S5) ----------------------------------------------------------
# The stage-2 ramfs has lost /opt/batdata (`umount -l /mnt` takes the whole old tree), and the stock
# do_stage2 ignores our return code and always ends in `umount -a; reboot -f` — so without this,
# nothing of stage 2 survives. Re-mount the data partition under $RUNDIR/p6t just for the trace file
# (batdata-mount leaves the real device in $RUNDIR/batdata.dev; /tmp — and so /tmp/run/batman — crosses
# into the ramfs, #280: never spell it /var/run, /var is a fresh dir in the ramfs). The
# mount runs in the background with a 10 s budget (busybox has no `timeout`): if it hangs we give
# up and trace to kmsg only — the upgrade itself never waits on the recorder.
ota_s2_open() {
	local dev mp n
	OTATRACE_FILE=/nonexistent/ota-trace.log; export OTATRACE_FILE   # kmsg-only until p6 is up
	batman_rundir 2>/dev/null || return 0   # no private run dir: trace to kmsg only (never trust /tmp here)
	dev=$(cat "$RUNDIR/batdata.dev" 2>/dev/null); [ -b "$dev" ] || return 0
	[ "$(hexdump -s 1080 -n 2 -e '2/1 "%02x"' "$dev" 2>/dev/null)" = 53ef ] || return 0
	opf /tmp/batman-fault.s2-nomount && return 0   # test seam
	mkdir -p "$RUNDIR/p6t"
	mount -t ext4 -o rw,noatime "$dev" "$RUNDIR/p6t" 2>/dev/null &
	mp=$!; n=0
	while kill -0 "$mp" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
	kill -0 "$mp" 2>/dev/null && { kill -9 "$mp" 2>/dev/null; return 0; }
	grep -q " $RUNDIR/p6t " /proc/mounts || return 0
	mkdir -p "$RUNDIR/p6t/log"
	OTATRACE_FILE=$RUNDIR/p6t/log/ota-trace.log; export OTATRACE_FILE
	return 0
}
ota_s2_close() {
	local up n
	sync
	grep -q " $RUNDIR/p6t " /proc/mounts || return 0
	umount "$RUNDIR/p6t" 2>/dev/null &
	up=$!; n=0
	while kill -0 "$up" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
	return 0
}

# Wrapper: every path through stage 2 ends with an `S2 END rc=…` line and the tryboot flag read back
# as late as we can (do_stage2 only sleeps 1 s, `umount -a` and `reboot -f` after this).
platform_do_upgrade() {
	local abrc
	ota_s2_open
	otalog_k S2 BEGIN p6trace="$([ "$OTATRACE_FILE" = "$RUNDIR/p6t/log/ota-trace.log" ] && echo yes || echo no)" get="$(ota_get)" thr="$(ota_thr)"
	_ab_do_upgrade "$@"; abrc=$?
	otalog_k S2 END rc=$abrc get="$(ota_get)" thr="$(ota_thr)"
	ota_s2_close
	ota_s2_explicit_restart_if_not_armed "$abrc"
	return $abrc
}

# Stage 2 failure path (#209 S5 D3, docs/design/explicit-reboot.md): when nothing was armed (apply
# refused, verification failed) the stock do_stage2 would `reboot -f` with partition 0 — the restart
# the Pi 4 bootloader may misread, walking onto partition 1, possibly the slot just invalidated
# (no rootfs -> panic -> partition 0 again, with no userspace to correct it). So on a Pi 4 with the
# flag certainly CLEAR, restart explicitly to [all]. An armed flag keeps the stock path (the tryboot
# reboot -f, ~25/25 correct); an unreadable flag or [all] also keeps it — never guess.
ota_s2_explicit_restart_if_not_armed() {
	local g n m
	type bf_get >/dev/null 2>&1 || return 0
	[ "$(bf_pi4)" = yes ] || return 0
	g=$(bf_get); [ "$g" = 0 ] || return 0
	[ -x /usr/sbin/batman-reboot ] || return 0
	if grep -q ' /boot ' /proc/mounts; then
		n=$(bf_ab_all /boot)
	else
		m=$(batman_tmp -d s2-p1) || return 0
		mount -t vfat -o ro /dev/mmcblk0p1 "$m" 2>/dev/null && { n=$(bf_ab_all "$m"); umount "$m" 2>/dev/null; }
	fi
	case "$n" in 1|2) ;; *) return 0 ;; esac
	otalog_k S2 EXPLICIT-RESTART to="$n" rc="$1" why=tryboot-not-armed
	umount /boot 2>/dev/null
	sync
	/usr/sbin/batman-reboot "$n"
	return 0   # only if the restart failed: the stock reboot -f follows
}

_ab_do_upgrade() {
	local dir troot t0 r ex
	# #280: the boot payload and the exclude list are what stage 2 writes to the slot — private, never /tmp
	dir=$(batman_tmp -d ab-payload) && ex=$(batman_tmp ab-exclude) || { echo "run dir unusable (#280)"; otalog S2 REFUSE why=rundir-unusable; return 1; }
	# everything but root.squashfs (streamed below). -x not -xz: get_image already un-gzips.
	echo 'root.squashfs' > "$ex" || { otalog S2 REFUSE why=exclude-write; return 1; }
	get_image "$@" | tar -xf - -C "$dir" -X "$ex" || { echo "A/B image unpack failed"; otalog S2 REFUSE why=unpack-failed; return 1; }
	[ -f "$dir/SHA256SUMS" ] && [ -f "$dir/metadata" ] || { echo "image lacks SHA256SUMS/metadata"; otalog S2 REFUSE why=no-sums-or-metadata; return 1; }
	otalog S2 PAYLOAD "$(tr '\n' ' ' < "$dir/metadata" 2>/dev/null)"

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
		otalog S2 REFUSE why=soc-unrecognised image="$want" running="$run"
		return 1
	fi
	if [ "$wt" != "$rt" ]; then
		echo "REFUSING: image is for $wt but this node is $rt — not writing anything"
		otalog S2 REFUSE why=soc-mismatch image="$wt" running="$rt"
		return 1
	fi

	# batman-slot's [tryboot] read + boot write need bootA (autoboot.txt) mounted; the sysupgrade
	# ramfs pivot may have unmounted /boot, so re-mount p1 there if needed (mkdir first — in the
	# ramfs /boot may not exist).
	mkdir -p /boot
	grep -q ' /boot ' /proc/mounts || mount -t vfat -o rw /dev/mmcblk0p1 /boot 2>/dev/null

	# 1) every check, then clear the target overlay window — nothing is streamed before this passes
	troot=$(batman-slot stage-root "$dir"); r=$?
	otalog S2 STAGE-ROOT rc=$r dev="$troot"
	[ "$r" = 0 ] || { echo "batman-slot stage-root refused"; return 1; }
	[ -b "$troot" ] || { echo "stage-root gave no target device ('$troot')"; return 1; }
	# 2) stream the rootfs straight onto the target root partition (no /tmp copy)
	t0=$(cut -d. -f1 /proc/uptime)
	get_image "$@" | tar -xOf - root.squashfs | dd of="$troot" bs=1M conv=fsync 2>/dev/null; r=$?
	otalog S2 STREAM rc=$r secs=$(( $(cut -d. -f1 /proc/uptime) - t0 ))
	[ "$r" = 0 ] || { echo "rootfs stream to $troot failed"; return 1; }
	sync
	# 3) boot files, uncached read-back of rootfs + boot against SHA256SUMS, then arm + read back
	#    the one-shot tryboot. A failed verification invalidates the target slot and arms nothing,
	#    and stage2's plain reboot then lands on the untouched default slot.
	batman-slot apply "$dir"; r=$?
	otalog S2 APPLY rc=$r
	[ "$r" = 0 ] || { echo "batman-slot apply failed"; return 1; }
	# the harness reboots next; the firmware then trials the freshly-written inactive slot. Commit
	# (making it the default) happens later, gated on a soaked-healthy verdict — NOT here.
	return 0
}

# config crosses A/B slots via p5 (96-batman-config-migrate); no stock single-slot tar handling.
platform_copy_config() { :; }
platform_restore_backup() { :; }
