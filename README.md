# Batman — Wi-Fi HaLow mesh on Raspberry Pi 4

Field notes from getting a **Morse Micro MM6108** Wi-Fi HaLow (802.11ah) radio working
over **SPI** on a Raspberry Pi 4, and building it into a batman-adv mesh node.

Hardware: Raspberry Pi 4 Model B + **Seeed WM1302 Pi HAT** + **Seeed Wio-WM6108**
mPCIe card (Quectel FGH100M-H / Morse Micro MM6108A1).

---

## TL;DR — the finding

The Morse Micro `morse_spi` driver fails to probe on a **stock** Raspberry Pi OS kernel:

```
morse_spi spi0.0: failed to init SPI with CMD63 (ret:-71)
```

The driver's SPI init sequence must send 144 training clocks with **chip-select
deasserted**. It does that by temporarily setting `SPI_CS_HIGH` to invert CS polarity.

On kernels **≥ 6.1** with **GPIO-descriptor chip-selects** (`cs-gpios`, which the
Pi 4 base device tree always uses), the SPI core sets `SPI_CS_HIGH` *itself* and
handles polarity through the GPIO descriptor flags. The driver's `|= SPI_CS_HIGH`
therefore becomes a **no-op**, and the training clocks go out with CS **asserted**.
The chip counts them as real bus traffic and its bit counter ends up exactly
**2 bits out of phase** for the rest of the session.

**Fix:** use `SPI_NO_CS` instead, so the core skips CS toggling entirely and the pin
stays high during training. → [`patches/0001-spi-use-SPI_NO_CS-for-training-sequence.patch`](patches/0001-spi-use-SPI_NO_CS-for-training-sequence.patch)

This is only needed because stock Raspberry Pi OS does **not** carry Morse Micro's
kernel patch (the one that defines `SPI_CONTROLLER_ENABLE_CS_GPIOD`). Their own
OpenWrt / `MorseMicro/rpi-linux` builds do.

Three things were required, all necessary:

1. Driver from the **MM6108 product line** — tag `mm6108-2.0.1`, *not* `mm8108-*`
2. The **`SPI_NO_CS` patch** above
3. Module parameters `enable_ext_xtal_init=1 bcf=bcf_fgh100mhaamd.bin`

Result:

```
morse_spi spi0.0: Loaded firmware from morse/mm6108.bin, size 468304, crc32 0xbe7b5c8f
morse_spi spi0.0: Loaded BCF from morse/bcf_fgh100mhaamd.bin, size 1251, crc32 0x941b2a82
```

---

## Then: the shortcut we should have found first

After all of the above, the driver worked — but a HaLow *link* still could not be
established, because Debian's stock `wpa_supplicant` (v2.10) contains **zero** S1G /
802.11ah support, and `hostapd` / `morse_cli` were not present at all.

It turns out **[OpenMANET](https://openmanet.github.io/docs/)** publishes a prebuilt
OpenWrt image for *exactly* this hardware combination — it lists
"Seeed WM1302 + Wio-WM6108" as a supported SPI setup, and the image ships
`wpa_supplicant_s1g`, `hostapd_s1g`, `morse-bcf-info` and `batctl` alongside the driver,
with 802.11s + BATMAN-V already wired up.

Its `mm610x-spi.dtbo` uses the **identical GPIO mapping** we had arrived at by hand.

**Lesson:** search for prebuilt firmware before rebuilding a vendor driver. The
`SPI_NO_CS` finding still stands for anyone running the Morse driver on a stock,
unpatched kernel — but if you just want a working mesh node, flash OpenMANET.

See [`docs/openmanet.md`](docs/openmanet.md).

---

## Contents

| Path | What |
|---|---|
| [`docs/hardware.md`](docs/hardware.md) | Hardware stack, GPIO map, device tree |
| [`docs/root-cause.md`](docs/root-cause.md) | Symptom → diagnosis → root cause, in full |
| [`docs/building-the-driver.md`](docs/building-the-driver.md) | Build instructions and the gotchas |
| [`docs/openmanet.md`](docs/openmanet.md) | The OpenMANET route |
| [`docs/flashing-and-recovery.md`](docs/flashing-and-recovery.md) | **Why `dd`-flashing an OpenWrt image leaves the old config intact**, and how to tell |
| [`docs/led-indicator.md`](docs/led-indicator.md) | Two-LED field status indicator — what each pattern means and why |
| [`patches/`](patches/) | The `SPI_NO_CS` patch |
| [`scripts/`](scripts/) | `meshled`, the daemon behind the LED indicator |
| [`tools/`](tools/) | Python SPI diagnostic scripts (via `spidev`) |

## Also worth reading

If you flash OpenWrt to SD cards with `dd`, [`docs/flashing-and-recovery.md`](docs/flashing-and-recovery.md)
is the most generally useful thing here. The image covers only the boot partition and
the squashfs — the `rootfs_data` overlay after it is never written, so the device boots
with its entire previous configuration restored while every verification you would
normally run comes back green.

## Status

- ✅ Driver probes, firmware + BCF load, netdev appears
- ✅ Root cause understood and patched
- ✅ OpenMANET 1.7.0 `rpi4-mm6108-spi` flashed, overlay wiped, **booted and verified**
- ✅ HaLow radio up under OpenMANET: `RPI RPI4-MM6108 (SPI)`, `wlan0`, 923 MHz @ 2 MHz BW, 27 dBm
- ✅ Node 1 configured: 802.11s mesh + SAE, BATMAN_V, hostname `manet01`, 2.4 GHz off
- ✅ Two-LED field status indicator installed and verified — [`docs/led-indicator.md`](docs/led-indicator.md)
- ⏳ TX path not yet verified end-to-end (needs a second node or a spectrum analyser)
- ⏳ Two-node mesh not yet brought up — second Pi 4 and SD card not ready

## License

Repository content is MIT (see [`LICENSE`](LICENSE)).
The patch in `patches/` applies to Morse Micro's driver, which is GPL-2.0-or-later;
the patch is offered under the same terms as the code it modifies.
