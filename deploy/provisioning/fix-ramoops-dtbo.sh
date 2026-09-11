#!/bin/sh
# fix-ramoops-dtbo.sh — make kernel-panic AND hang evidence survive a reset on the OpenMANET
# image (#61/#105). Run ON the golden node during image prep (depersonalise.sh calls step 1).
#
#   fix-ramoops-dtbo.sh                 both steps (step 2 needs dtc: opkg install dtc, or the .ipk offline)
#   fix-ramoops-dtbo.sh --console-only  step 1 only (no dtc needed)
#
# STEP 1 — rolling CONSOLE capture: the ramoops overlay exposes a `console-size` override, so no
# binary edit is needed — it is passed on the dtoverlay line in /boot/distroconfig.txt. The
# kernel log is then mirrored into the reserved RAM continuously; after a pure hang -> hardware
# watchdog reset (no panic, no clean shutdown) pstore still holds the last 32 KB as
# console-ramoops-0. Region 64 KB = 2 x 16 KB dmesg records (panic) + 32 KB console. Zero SD writes.
#
# STEP 2 — the malformed reg. ROOT CAUSE (validated on OpenMANET 1.8.0, Pi 4):
# /boot/overlays/ramoops.dtbo declares ramoops@b000000 { reg = <0xb000000 0x10000>; } — 2 cells,
# written for #address-cells=1 — but the reserved-memory parent uses #address-cells=<2>, so the
# kernel logs "invalid reg property in 'ramoops@b000000', skipping node", ramoops never probes and
# /sys/fs/pstore stays empty. Fix: add the high address cell -> reg = <0x0 0xb000000 0x10000>.
# PROVEN end-to-end on hardware (2026-09-11): "pstore: Registered ramoops as persistent store
# backend", and a test panic (echo c > /proc/sysrq-trigger) is captured and survives the reboot.
#
# Idempotent. Both steps only take effect after a reboot.
set -e
DTBO=/boot/overlays/ramoops.dtbo
CFG=/boot/distroconfig.txt
CONSOLE_ONLY=0; [ "$1" = "--console-only" ] && CONSOLE_ONLY=1
changed=0

[ -f "$CFG" ] || { echo "$CFG not found"; exit 1; }
[ -f "$DTBO" ] || { echo "$DTBO not found (is dtoverlay=ramoops in $CFG?)"; exit 1; }
# preconditions before any mutation
[ "$CONSOLE_ONLY" = 1 ] || command -v dtc >/dev/null 2>&1 || { echo "need dtc (opkg install dtc) for the reg fix; use --console-only for step 1 alone"; exit 1; }

# --- step 1: console capture on the dtoverlay line (bare or with other params; never twice) ----
if grep -qE '^dtoverlay=ramoops(,|$)' "$CFG" && ! grep -qE '^dtoverlay=ramoops.*console-size=' "$CFG"; then
	# `t` ends the script for a line once the first substitution matched, so the bare form is
	# rewritten exactly once and a parameterised line gets the option prepended.
	sed -i -e 's/^dtoverlay=ramoops$/dtoverlay=ramoops,console-size=0x8000/; t' \
	       -e 's/^dtoverlay=ramoops,/dtoverlay=ramoops,console-size=0x8000,/' "$CFG"
	grep -qE '^dtoverlay=ramoops.*console-size=0x8000' "$CFG" || { echo "failed to set console-size in $CFG"; exit 1; }
	echo "step 1: enabled ramoops console capture -> $(grep -E '^dtoverlay=ramoops' "$CFG")"; changed=1
else
	echo "step 1: console capture already set ($(grep -E '^dtoverlay=ramoops' "$CFG" || echo 'no dtoverlay=ramoops line!'))"
fi

# --- step 2: the malformed reg (needs dtc) ----------------------------------------------------
if [ "$CONSOLE_ONLY" = 0 ]; then
	if dtc -I dtb -O dts "$DTBO" 2>/dev/null | grep -q "reg = <0x0\?0 0xb000000"; then
		echo "step 2: ramoops.dtbo already fixed (reg has the high address cell)"
	else
		cp "$DTBO" "$DTBO.orig-badreg"
		dtc -I dtb -O dts "$DTBO" -o /tmp/ramoops.dts 2>/dev/null
		sed -i 's/reg = <0xb000000 0x10000>/reg = <0x0 0xb000000 0x10000>/' /tmp/ramoops.dts
		grep -q "reg = <0x0 0xb000000 0x10000>" /tmp/ramoops.dts || { echo "reg line not matched — image differs, inspect /tmp/ramoops.dts"; exit 1; }
		dtc -I dts -O dtb /tmp/ramoops.dts -o "$DTBO" 2>/dev/null
		echo "step 2: fixed $DTBO -> reg = <0x0 0xb000000 0x10000> (backup at $DTBO.orig-badreg)"; changed=1
	fi
fi

[ "$changed" = 1 ] && echo "REBOOT to apply, then confirm: dmesg | grep 'Registered ramoops'; cat /sys/module/ramoops/parameters/console_size  (32768)"
exit 0
