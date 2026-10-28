#!/bin/sh
# tests/prov-p1/sbx/cases/escape.sh — prov-unit-sbx, the in-sandbox half (254-p1-impl §4.10): each escape attempt must
# fail or stay inside; scripts/dv-sbx.sh checks the host side (boot_id, the interface, dmesg marker, hostname).
# Accident isolation only (dv-sbx.sh header): a case running as root that WANTS out can get out.
n=0; f=0
ok(){ n=$((n + 1)); echo "ok   $*"; }; no(){ n=$((n + 1)); f=$((f + 1)); echo "FAIL $*"; }
# reboot -f: busybox's own applet (not the stub): no CAP_SYS_BOOT, and only the pid namespace would go down anyway
if busybox reboot -f 2>/dev/null; then no "busybox reboot -f returned success"; else ok "reboot -f refused (rc $?)"; fi
# mknod of a host disk (8:0 = sda, 179:0 = mmcblk0): no CAP_MKNOD
for d in "8 0" "179 0"; do
	if mknod /tmp/sbx-disk b $d 2>/dev/null; then no "mknod b $d succeeded"; rm -f /tmp/sbx-disk; else ok "mknod b $d refused"; fi
done
# a new interface stays in the sandbox's netns: a random name (SBX_IF) the host side looks for — not dummy0, which the
# dummy module creates in the INITIAL namespace when this very command autoloads it (dv-sbx run 1, 2026-10-28)
if ip link add "${SBX_IF:-sbxnone}" type dummy 2>/dev/null; then ok "ip link add $SBX_IF (inside the netns)"; else ok "ip link add $SBX_IF not possible here — the host check still applies"; fi
if ip link set eth0 down 2>/dev/null; then no "ip link set eth0 down succeeded (a host interface is visible)"; else ok "no eth0 in the sandbox"; fi
[ "$(ls /sys 2>/dev/null | wc -l)" = 0 ] && ok "/sys not mounted" || no "/sys has entries"
if { echo x > /proc/sys/kernel/hostname; } 2>/dev/null; then no "/proc/sys/kernel/hostname writable"; else ok "/proc/sys read-only"; fi
if { echo c > /proc/sysrq-trigger; } 2>/dev/null; then no "/proc/sysrq-trigger writable"; else ok "/proc/sysrq-trigger read-only"; fi
echo "${SBX_MARKER:-SBX-KMSG-none}" > /dev/kmsg && [ -f /dev/kmsg ] && ok "/dev/kmsg is a plain file" || no "/dev/kmsg is not a regular file"
[ -b /dev/mmcblk0p5 ] && ok "p5 is a block device (the sandbox loop)" || no "no /dev/mmcblk0p5"
[ ! -e /proc/device-tree ] && ok "no /proc/device-tree" || no "/proc/device-tree present"
grep -q ' /opt/batdata tmpfs ' /proc/mounts && grep -q ' /tmp/run tmpfs ' /proc/mounts && ok "/opt/batdata and /tmp/run are private tmpfs" || no "private tmpfs mounts missing"
# setup.sh set the hostname of the sandbox's UTS namespace to the marker (OpenWrt's busybox has no hostname applet and
# /proc/sys is read-only here); the host side checks its own hostname is unchanged
if [ "$(cat /proc/sys/kernel/hostname)" = "${SBX_MARKER:-none}" ]; then ok "the UTS namespace has its own hostname (the marker)"; else no "hostname here is not the marker set in this UTS namespace"; fi
if chroot / /bin/true 2>/dev/null; then no "chroot still possible (cap_sys_chroot not dropped)"; else ok "no chroot (cap_sys_chroot dropped)"; fi
reboot -f; grep -q '^reboot -f' /tmp/run/sbx-calls.log && ok "plain reboot resolves to the call-logging stub" || no "the reboot stub did not record the call"
echo "CASE escape cases=$n fails=$f"
