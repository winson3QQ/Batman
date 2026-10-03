# shellcheck shell=ash
# bootfacts.sh — firmware boot facts shared by batman-slot, the K90 reboot hook, batdata-mount (the
# boot-time self-check) and the sysupgrade stage 2 (#209 S5, docs/design/explicit-reboot.md).
# Functions only; every one prints exactly one token and returns 0 (safe inside $(...)).
#
# Background: the reboot partition lives in the even PM_RSTS bits (0,2,..,10; mask 0x555). On a
# partition-0 restart the Pi 4 bootloader (EEPROM 2026-09-23) sometimes reads the RAW previous
# PM_RSTS (HADWRF bit 5 always set after a watchdog reset) as the partition number: 0x20 -> 32,
# 0x24 -> 36, 0x30 -> 48. Such a number is always >= 32, never exists, so autoboot.txt is skipped
# and PARTITION_WALK lands on partition 1.

# raw hex of a /proc/device-tree/chosen/bootloader/<name> u32, or "" when absent
bf_dt() { hexdump -v -e '1/1 "%02x"' "/proc/device-tree/chosen/bootloader/$1" 2>/dev/null; return 0; }

# the one-shot tryboot flag right now: 1 | 0 | unknown (never guess: unknown keeps the old behaviour)
bf_get() {
	# shellcheck disable=SC2046
	set -- $(vcmailbox 0x00030064 4 4 0 2>/dev/null)
	if [ "${2:-}" = 0x80000000 ] && [ -n "${6:-}" ]; then
		case "$(( ${6} ))" in 0) echo 0 ;; 1) echo 1 ;; *) echo unknown ;; esac
	else
		echo unknown
	fi
	return 0
}

# the partition number requested through PM_RSTS for THIS boot (DT rsts), un-spread from the even bits;
# "" when the DT has no rsts
bf_preq() {
	h=$(bf_dt rsts); [ -n "$h" ] || { echo ""; return 0; }
	v=$(( 0x$h & 0x555 ))
	echo $(( (v & 1) | ((v >> 1) & 2) | ((v >> 2) & 4) | ((v >> 3) & 8) | ((v >> 4) & 16) | ((v >> 5) & 32) ))
	return 0
}

# decimal value of a DT u32 (dt_partition / dt_tryboot), "" when absent
bf_dtnum() { h=$(bf_dt "$1"); [ -n "$h" ] && echo $(( 0x$h )) || echo ""; return 0; }

# a Pi 4 A/B card: bcm2711 and no Pi 3 firmware partition (p7); the only layout with the bug
bf_pi4() { case "$(cat /proc/device-tree/compatible 2>/dev/null)" in *bcm2711*) [ -b /dev/mmcblk0p7 ] && echo no || echo yes ;; *) echo no ;; esac; return 0; }

# [all] boot_partition from a pi4 autoboot.txt (default: the live /boot = bootA); "" when unreadable
bf_ab_all() { sed -n '/^\[all\]/,/^\[/s/^boot_partition=//p' "${1:-/boot}/autoboot.txt" 2>/dev/null | head -n 1; return 0; }
