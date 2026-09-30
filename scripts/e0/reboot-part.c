/*
 * reboot-part — reboot into firmware partition N via the bcm2835_wdt restart handler (#209 E0).
 *
 * busybox `reboot` cannot pass a restart argument; this calls reboot(2) with
 * LINUX_REBOOT_CMD_RESTART2 and the decimal string N, which the RPi downstream bcm2835_wdt
 * handler (OpenWrt bcm27xx patch 950-0073) writes into the PM_RSTS partition bits. N=0 is what
 * every argument-less restart (plain reboot, panic) writes.
 *
 * EXPERIMENT TOOL: it syncs, then restarts IMMEDIATELY — no procd shutdown, no umount. That is
 * the same thing the design's platform_do_upgrade path does after its own sync/umount (§5.2).
 *
 * Build (static, on the machine with the OpenWrt tree):
 *   $STAGING/toolchain-aarch64_cortex-a53_gcc-*_musl/bin/aarch64-openwrt-linux-musl-gcc \
 *       -static -Os -s -o reboot-part reboot-part.c
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

int main(int argc, char **argv)
{
	char *end;
	long n;

	if (argc != 2) {
		fprintf(stderr, "usage: reboot-part N   (N = firmware partition number, 0..62)\n");
		return 2;
	}
	errno = 0;
	n = strtol(argv[1], &end, 10);
	/* 63 is reserved by the firmware for "halt"; the kernel handler ignores values >= 63 */
	if (errno || *argv[1] == '\0' || *end != '\0' || n < 0 || n > 62) {
		fprintf(stderr, "reboot-part: N must be a decimal number 0..62, got '%s'\n", argv[1]);
		return 2;
	}
	sync();
	if (syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		    LINUX_REBOOT_CMD_RESTART2, argv[1]) != 0) {
		fprintf(stderr, "reboot-part: reboot(RESTART2, \"%s\") failed: %s\n", argv[1], strerror(errno));
		return 1;
	}
	return 0; /* not reached */
}
