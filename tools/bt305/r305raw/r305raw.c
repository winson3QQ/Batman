// SPDX-License-Identifier: GPL-2.0
/*
 * r305raw (#305 harness tool, never in an image): read or overwrite the BCM2711 mini UART CNTL register behind the
 * driver's back, for the #305 flip segments and the stuck-TX close test.
 *
 *   insmod r305raw.ko            read only: one dmesg line with MCR / CNTL / STAT (no LSR / IO reads: side effects)
 *   insmod r305raw.ko cntl=0xNN  write (NN | RXEN) to CNTL, then print the registers again
 *
 * The module does all its work in init and holds nothing: rmmod it right after every insmod. A write makes the
 * hardware differ from the 8250_bcm2835aux cache (the sysfs witness shows hw != cache); the caller restores it by a
 * rebind (driver rewrites CNTL) or a reboot.
 */
#include <linux/module.h>
#include <linux/io.h>

static int cntl = -1;
module_param(cntl, int, 0);

#define AUX_MU_BASE	0xfe215040UL
#define MCR		0x10
#define CNTL		0x20
#define STAT		0x24

static void dump(void __iomem *b, const char *tag)
{
	u32 s = readl(b + STAT);

	pr_info("r305raw %s: MCR=0x%02x CNTL=0x%02x STAT=0x%08x (rts_status=%u cts_line=%u rx_fill=%u tx_fill=%u rx_overrun=%u)\n",
		tag, readl(b + MCR), readl(b + CNTL), s, (s >> 6) & 1, (s >> 7) & 1,
		(s >> 16) & 0xf, (s >> 24) & 0xf, (s >> 4) & 1);
}

static int __init r305raw_init(void)
{
	void __iomem *b = ioremap(AUX_MU_BASE, 0x40);

	if (!b)
		return -ENOMEM;
	dump(b, "before");
	if (cntl >= 0) {
		writel(((u32)cntl & 0xff) | 0x1, b + CNTL);
		dump(b, "after");
	}
	iounmap(b);
	return 0;
}

static void __exit r305raw_exit(void)
{
}

module_init(r305raw_init);
module_exit(r305raw_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Batman #305 test tool: read/overwrite the mini UART CNTL register");
