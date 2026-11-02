#!/bin/sh
# e0-probe.sh — run on the node after every boot of a #209 E0 experiment. Prints one record and
# appends it to a log that survives reboots, so the whole sequence can be pasted into #209 as-is.
#   sh e0-probe.sh [step-label]
# The node has no RTC: records are keyed by boot_id + a running sequence number, not wall time.
LOG=/opt/batdata/e0.log
mount | grep -q ' /opt/batdata ' || LOG=/root/e0.log
STEP=${1:-}
SEQ=$(( $(grep -c '^=== e0 record' "$LOG" 2>/dev/null || echo 0) + 1 ))

hexnode() { [ -e "$1" ] && hexdump -v -e '1/1 "%02x"' "$1" 2>/dev/null || printf 'absent'; }

{
	echo "=== e0 record #$SEQ ${STEP:+step=$STEP}"
	echo "boot_id   : $(cat /proc/sys/kernel/random/boot_id)"
	echo "uptime_s  : $(cut -d' ' -f1 /proc/uptime)"
	echo "e0 marker : $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^e0=//p')"
	echo "slot      : $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^batman_slot=//p')"
	echo "cmdline   : $(cat /proc/cmdline)"
	echo "model     : $(tr -d '\0' < /proc/device-tree/model)"
	B=/proc/device-tree/chosen/bootloader
	if [ -d "$B" ]; then
		echo "dt bootloader/: $(ls "$B" | tr '\n' ' ')"
		echo "  partition : $(hexnode $B/partition)"
		echo "  rsts      : $(hexnode $B/rsts)"
		echo "  tryboot   : $(hexnode $B/tryboot)"
	else
		echo "dt bootloader/: absent"
	fi
	echo "psci      : $([ -e /proc/device-tree/psci ] && echo present || echo absent)"
	echo "restart handlers (dmesg): $(dmesg | grep -iE 'bcm2835-wdt|psci|restart' | tr '\n' '|' | cut -c1-300)"
	echo "reset reason (dmesg): $(dmesg | grep -iE 'watchdog|reset reason|last reset' | head -3 | tr '\n' '|')"
	for p in 1 4; do
		d=/dev/mmcblk0p$p
		[ -b "$d" ] || continue
		m=$(mktemp -d); mount -o ro "$d" "$m" 2>/dev/null && {
			echo "p$p start.elf VC_BUILD: $(strings "$m/start.elf" 2>/dev/null | grep -m1 -E 'VC_BUILD_ID_(TIME|VERSION)' || md5sum "$m/start.elf" | cut -c1-32)"
			echo "p$p bootcode.bin md5  : $(md5sum "$m/bootcode.bin" 2>/dev/null | cut -c1-32)"
			[ -f "$m/autoboot.txt" ] && echo "p$p autoboot.txt       : $(tr '\n' ';' < "$m/autoboot.txt")"
			umount "$m"; }
		rmdir "$m"
	done
	echo
} | tee -a "$LOG"
echo "(appended to $LOG)"
