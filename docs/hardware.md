# Hardware

## Stack

| Layer | Part |
|---|---|
| Host | Raspberry Pi 4 Model B Rev 1.5 (BCM2711) |
| Carrier | Seeed **WM1302 Pi HAT** (mPCIe → 40-pin) |
| Radio card | Seeed **Wio-WM6108** (mPCIe form factor) |
| Module | Quectel **FGH100M-H** |
| SoC | Morse Micro **MM6108A1** |
| Band | 902–928 MHz (S1G / 802.11ah) |
| Bus | **SPI** (not SDIO) |

The mPCIe connector here carries SPI, not PCIe — the WM1302 HAT reroutes it to the
Pi's 40-pin header. This matters: most Morse Micro documentation and most community
reports assume SDIO.

**Practical consequence of choosing SPI:** on SDIO-based HaLow builds the Pi's onboard
Wi-Fi usually shares the SDIO bus and becomes unusable. On SPI builds it stays free,
so the onboard radio can run as a 2.4/5 GHz AP while HaLow carries the backhaul.

## GPIO map

This is the mapping that works. It is also, independently, the mapping OpenMANET's
`mm610x-spi.dtbo` uses.

| Signal | GPIO | Notes |
|---|---|---|
| `reset-gpios` | **17** | active high in DT (`0x11`) |
| `power-gpios` (wake) | **23** | pinctrl: pull-up |
| `power-gpios` (busy) | **24** | pinctrl: pull-down |
| `spi-irq-gpios` | **5** | pinctrl: pull-up |
| SPI CS | **8** | CE0, `<&gpio 8 1>` = active low |
| SPI MOSI / MISO / SCLK | **10 / 9 / 11** | `brcm,function = <4>` (ALT0) |

Note: an earlier vendor overlay shipped for the **EKH01** eval board also drove
`gpio_mm_jtag` on GPIO4. That is EKH01-only — the mPCIe card does not route JTAG —
and leaving it in causes no benefit. Removing it is correct.

## Device tree node

```dts
mm6108@0 {
    compatible = "morse,mm610x-spi";
    reg = <0x00>;
    reset-gpios     = <&gpio 0x11 0x00>;                  /* GPIO17 */
    power-gpios     = <&gpio 0x17 0x00 &gpio 0x18 0x00>;  /* GPIO23, GPIO24 */
    spi-irq-gpios   = <&gpio 0x05 0x00>;                  /* GPIO5  */
    spi-max-frequency = <0x2faf080>;                      /* 50 MHz */
    status = "okay";
};
```

`config.txt`:

```
dtparam=spi=on
dtoverlay=morse-ps
dtoverlay=morse-spi
```

## The SPI clock is a red herring

We lowered `spi-max-frequency` from 50 MHz to 20 MHz, and separately tested 1, 4, 10
and 50 MHz from userspace. **The failure is bit-identical at every frequency.** That
by itself rules out signal integrity and points at the logic layer — see
[`root-cause.md`](root-cause.md).

## Why the chip-select can't be fixed in the device tree

The obvious fix would be to stop using GPIO-descriptor chip-selects and let the
BCM2835 SPI controller drive CS natively. That is not reachable from an overlay:
the base `bcm2711-rpi-4-b.dtb` already contains

```dts
cs-gpios = <&gpio 8 1>, <&gpio 7 1>;
spi0_cs_pins { brcm,pins = <8 7>; brcm,function = <1>; };
```

and a device tree overlay can add or replace properties but cannot cleanly *remove*
`cs-gpios`. Hence the driver-side fix.

## Regulatory note

The Wio-WM6108 is officially a **US-band** card (902–928 MHz). If you are outside the
US, check your local sub-GHz allocation before transmitting — e.g. Taiwan's ISM
allocation is 920–925 MHz, a subset. OpenMANET additionally ships a custom BCF that
raises TX power to roughly **27 dBm**, which may exceed local limits.

Be aware that the regulatory domain can be set in three places that do not
automatically agree: the `country=` module parameter (defaults to `AU`), the kernel
command line (`cfg80211.ieee80211_regdom=`), and whatever `iw reg get` reports.
