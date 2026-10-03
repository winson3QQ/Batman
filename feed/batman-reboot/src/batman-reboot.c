/*
 * batman-reboot — restart into an EXPLICIT Raspberry Pi firmware boot partition (#209 S5).
 *
 * Why: the Pi 4 bootloader (EEPROM 2026-09-23, see docs/design/explicit-reboot.md) sometimes treats
 * the raw PM_RSTS reset flags as the reboot partition when the OS restarts with partition 0 (every
 * plain `reboot`, `reboot -f`, panic). The resulting number is always >= 32, does not exist, so the
 * bootloader skips autoboot.txt and walks to partition 1 — the wrong slot whenever [all] is 2.
 * With an explicit partition N the bootloader boots N (10/10 on manet02, including from the bad
 * state). The RPi downstream bcm2835_wdt restart handler spreads N into PM_RSTS bits 0,2,..,10.
 *
 * Usage: batman-reboot N    N = 1..31, plain decimal (no leading zero: the kernel parses with
 *                           base 0, so "02" would be octal). The CALLER must pass a partition that
 *                           exists on this card ([all] from autoboot.txt) — this tool only refuses
 *                           what can never be right (0 is the buggy path, >31 is a bootloader
 *                           special range, 63 is halt).
 * It syncs and restarts immediately: no procd shutdown. Callers either let procd shut down first
 * (the K90 hook /etc/init.d/batman-reboot) or run at a point where nothing needs stopping.
 * Exit 2 on a bad argument; returns only if reboot(2) itself fails (exit 1).
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

int main(int argc, char **argv)
{
	const char *a;
	int n = 0;

	if (argc != 2) {
		fprintf(stderr, "usage: batman-reboot N   (N = firmware boot partition, 1..31)\n");
		return 2;
	}
	a = argv[1];
	/* ^[1-9][0-9]?$ */
	if (a[0] < '1' || a[0] > '9' || (a[1] && (a[1] < '0' || a[1] > '9')) || (a[1] && a[2])) {
		fprintf(stderr, "batman-reboot: N must be 1..31 without a leading zero, got '%s'\n", a);
		return 2;
	}
	n = a[0] - '0';
	if (a[1])
		n = n * 10 + (a[1] - '0');
	if (n > 31) {
		fprintf(stderr, "batman-reboot: N must be 1..31, got %d\n", n);
		return 2;
	}
#ifdef BATMAN_REBOOT_DRYRUN	/* host-side argument tests only (never set by the package build) */
	printf("WOULD reboot RESTART2 \"%s\"\n", a);
	return 0;
#endif
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART2, a);
	fprintf(stderr, "batman-reboot: reboot(RESTART2, \"%s\") failed: %s\n", a, strerror(errno));
	return 1;
}
