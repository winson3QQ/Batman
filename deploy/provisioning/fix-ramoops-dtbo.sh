#!/bin/sh
# fix-ramoops-dtbo.sh — fix the malformed ramoops reserved-memory reg in the OpenMANET image
# so kernel panics are captured to pstore (#61). Run ON the golden node during image prep.
#
# ROOT CAUSE (validated on OpenMANET 1.8.0, Pi 4): /boot/overlays/ramoops.dtbo declares
#   ramoops@b000000 { reg = <0xb000000 0x10000>; }   // 2 cells, written for #address-cells=1
# but the reserved-memory parent uses #address-cells=<2>, so the kernel logs
#   "invalid reg property in 'ramoops@b000000', skipping node"
# ramoops never probes, /sys/fs/pstore stays empty — the "empty pstore" mystery from the
# stress-reboot investigation. Fix: add the high address cell -> reg = <0x0 0xb000000 0x10000>.
#
# PROVEN end-to-end on hardware (2026-09-11): after this fix + reboot, dmesg shows
#   "OF: reserved mem: 0x0b000000..0x0b00ffff ramoops@b000000"
#   "pstore: Registered ramoops as persistent store backend"
# and a test panic (echo c > /proc/sysrq-trigger) is captured to /sys/fs/pstore/dmesg-ramoops-0
# and survives the reboot. No kernel rebuild — a boot-partition dtbo edit.
#
# Idempotent. Needs dtc (opkg install dtc, or install the .ipk offline).
set -e
DTBO=/boot/overlays/ramoops.dtbo
command -v dtc >/dev/null 2>&1 || { echo "need dtc (opkg install dtc)"; exit 1; }
[ -f "$DTBO" ] || { echo "$DTBO not found (is dtoverlay=ramoops in distroconfig.txt?)"; exit 1; }

if dtc -I dtb -O dts "$DTBO" 2>/dev/null | grep -q "reg = <0x0\?0 0xb000000"; then
  echo "ramoops.dtbo already fixed (reg has the high address cell)"; exit 0
fi

cp "$DTBO" "$DTBO.orig-badreg"
dtc -I dtb -O dts "$DTBO" -o /tmp/ramoops.dts 2>/dev/null
sed -i 's/reg = <0xb000000 0x10000>/reg = <0x0 0xb000000 0x10000>/' /tmp/ramoops.dts
grep -q "reg = <0x0 0xb000000 0x10000>" /tmp/ramoops.dts || { echo "reg line not matched — image differs, inspect /tmp/ramoops.dts"; exit 1; }
dtc -I dts -O dtb /tmp/ramoops.dts -o "$DTBO" 2>/dev/null
echo "fixed $DTBO -> reg = <0x0 0xb000000 0x10000> (backup at $DTBO.orig-badreg)"
echo "reboot, then confirm: dmesg | grep 'Registered ramoops'  and  ls /sys/fs/pstore"
