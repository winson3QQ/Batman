# The OpenMANET route

[OpenMANET](https://openmanet.github.io/docs/) is a Raspberry Pi–based MANET radio
firmware built on OpenWrt, using Wi-Fi HaLow for the mesh backhaul. It supports
802.11s + batman-adv, ships a custom BCF that raises TX power to roughly 27 dBm, and
includes a GPS-driven range-test tool and a push-to-talk app.

Relevant here because its hardware support list names, verbatim:

> **Seeed WM1302 + Wio-WM6108** — *"Common 'Seeed board' setup; works on all supported
> Pi variants."*

Which is exactly the stack in [`hardware.md`](hardware.md).

## Why it solves the hard part

Getting the driver to probe is only half the job — you still need 802.11ah-capable
userspace, and Debian has none. The OpenMANET image ships it:

```
/usr/sbin/wpa_supplicant_s1g
/usr/sbin/hostapd_s1g
/usr/sbin/hostapd_cli_s1g
/usr/bin/morse-bcf-info
/usr/sbin/batctl
/usr/bin/iperf
```

(verified by mounting the squashfs of the written image)

Image identity:

```
DISTRIB_ID='OpenMANET'
DISTRIB_RELEASE='24.10'
DISTRIB_REVISION='r28739-d9340319c6'
DISTRIB_TARGET='bcm27xx/bcm2711'
DISTRIB_ARCH='aarch64_cortex-a72'
DISTRIB_DESCRIPTION='OpenMANET 24.10 1.7.0'
```

Package manager is `opkg`, with feeds for `morse`, `openmanet`, `routing`, `luci` and
the standard OpenWrt 24.10-SNAPSHOT trees.

## The GPIO map matches

OpenMANET's `overlays/mm610x-spi.dtbo`, decompiled:

```dts
mm6108@0 {
    compatible = "morse,mm610x-spi";
    reg = <0x00>;
    reset-gpios       = <&gpio 0x11 0x00>;                 /* GPIO17     */
    power-gpios       = <&gpio 0x17 0x00 &gpio 0x18 0x00>; /* GPIO23, 24 */
    spi-irq-gpios     = <&gpio 0x05 0x00>;                 /* GPIO5      */
    spi-max-frequency = <0x2faf080>;                       /* 50 MHz     */
    status = "okay";
};
```

plus `cs-gpios = <&gpio 8 1>`, pinctrl pulls for `morse_wake` (23, up),
`morse_busy` (24, down), `morse_irq` (5, up), `morse_reset` (17, up), and both
`spidev@0` / `spidev@1` explicitly disabled.

Identical to the map arrived at independently. Board identity is set via
`dtoverlay=sysinfo,board-name="bcm2711,mm6108-spi",model="RPI RPI4-MM6108 (SPI)"` in
`distroconfig.txt`.

## Network architecture

- **802.11s** mesh at L2, **BATMAN-V** on top
- Each node bridges `bat0` + `eth0` + its local 2.4/5 GHz AP into `br-ahwlan`
- Flat `10.41.0.0/16` for the whole mesh; each node runs its own DHCP server
- A single **mesh gate** does NAT toward upstream via `eth0`
- Per-node SSIDs (`manetNN-24G`), mDNS reflection so `manetNN.local` resolves across hops
- `batctl dc` shows the distributed ARP table

Because this is an **SPI** build, the Pi's onboard Wi-Fi is free and usable as the
client-facing AP. On SDIO builds it is not — the onboard radio shares the bus.

## Management interface

`openmanetd` serves a React single-page app embedded in the binary:

| Port | Purpose |
|---|---|
| `http://<node>:8080` | node management |
| `https://<node>:8081` | browser push-to-talk (needs mic permission, hence TLS) |

Pages: **Dashboard** (mesh peers, link-quality sparklines, alerts, CPU/mem, interfaces),
**Topology** (interactive SVG of everything batman-adv knows about, with per-edge
metrics and latency), **Comms** (PTT + offline speech-to-text), **GPS/GNSS**,
**Settings** (hostname, HaLow/2.4/5 GHz radios, network, firmware upgrade, in-browser
terminal, logs), **BLOS** (Tailscale/Headscale tunnel).

The UI talks to the daemon over **Connect RPC**, so external tooling can do anything
the UI can. LuCI is still present but is being superseded.

CLI equivalents over SSH:

```sh
batctl n                        # neighbours
batctl o                        # originators
batctl dc                       # distributed ARP table
iw dev <halow-if> station dump  # RSSI, bytes, negotiated rate
iw dev <halow-if> link
morse-bcf-info                  # board config file details
```

## Flashing

Image for this hardware:

```
openmanet-1.7.0-rpi4-mm6108-spi-squashfs-sysupgrade.img.gz
sha256  3757367b8994f7c660d9a55fa41b909a6930652137b68494d53a7e7ec39907b6
```

from <https://github.com/OpenMANET/firmware/releases> (the git tag is `1.7.0`, with no
`v` prefix). Always verify against the release's `SHA256SUMS.txt`.

```sh
# ⚠️ Confirm the target device first. Writing to the wrong one destroys it.
lsblk

zcat openmanet-1.7.0-rpi4-mm6108-spi-squashfs-sysupgrade.img.gz \
  | sudo dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress
sync
```

`gzip: decompression OK, trailing garbage ignored` is expected — OpenWrt sysupgrade
images carry metadata appended after the gzip stream.

Resulting layout:

```
mmcblk0p1   64M  vfat      boot
mmcblk0p2    4G  squashfs  (squashfs rootfs + writable overlay)
```

Read-back verification is worth the extra minute:

```sh
zcat image.img.gz > img.raw
SZ=$(stat -c%s img.raw)
sha256sum img.raw
sudo dd if=/dev/mmcblk0 bs=1M count=$((SZ/1048576+1)) 2>/dev/null \
  | head -c $SZ | sha256sum
```

## Boot media selection on a Pi 4

If the EEPROM has no `BOOT_ORDER` set, the Pi 4 factory default is
**SD first, then USB**. So on a system that normally boots from a USB SSD, inserting a
flashed SD card is enough to boot OpenMANET instead — and removing it returns you to
the SSD system. No EEPROM change required, and nothing on the SSD is touched.

Check with:

```sh
sudo rpi-eeprom-config
```

## First boot

1. Boot with the card inserted. The node comes up on static **`10.41.254.1`**.
2. Connect a computer by Ethernet, set it to DHCP.
3. Browse to `http://10.41.254.1` — user `root`, blank password.
4. Run the setup wizard: node type (**Mesh Gate** for the one with upstream,
   **Mesh Point** for the rest), SSID, password, channel, bandwidth. The node reboots
   to apply.

For a second node, the four radio settings — **network name, password, channel,
channel bandwidth** — must match exactly or the mesh will not form.

The docs are explicit about one thing: **do not use 8 MHz bandwidth, and do not use
auto channel.**

## Caveats

- **`sysupgrade` wipes the overlay** unless configuration is preserved. Anything
  installed with `opkg` after flashing needs reinstalling after a firmware update.
- OpenWrt is **musl**, not glibc. Not every ARM64 binary you have lying around will run.
- MM6108's PHY tops out around **32.5 Mbps** — HaLow trades throughput for range, by
  design. Plan the application around that, not around Wi-Fi expectations.
- Check the regulatory notes in [`hardware.md`](hardware.md) before transmitting.
