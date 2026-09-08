# Bringing the MM6108 up on a Raspberry Pi 5 / Pi 500 (RP1)

> **Pi 5 / Pi 500 only.**
> Everything on this page is specific to **BCM2712 + RP1**. The Pi 4 (BCM2711) setup is
> unchanged and still uses the vendor `morse-spi` / `morse-ps` overlays plus
> `patches/0001-*` on their own. Do not apply the Pi 5 overlays or `patches/0002-*` to a
> Pi 4 node — see [`docs/building-the-driver.md`](building-the-driver.md) for that path.

Verified on: `Raspberry Pi 500 Rev 1.0` (revision `d04190`, board type `0x19`),
Raspberry Pi OS, kernel `6.18.39+rpt-rpi-2712`, Wio-WM6108 (MM6108A1) on a WM1302 Pi HAT.

## Result

Cold boot, no manual intervention:

```
morse_spi spi0.0: morse_of_probe: Reading gpio pins configuration from device tree
Resetting Morse Chip
morse_spi spi0.0: Loaded firmware from morse/mm6108.bin, size 468304, crc32 0xbe7b5c8f
morse_spi spi0.0: Loaded BCF from morse/bcf_fgh100mhaamd.bin, size 1251, crc32 0x941b2a82
```

```
$ ip -br link
wlan1   DOWN   a8:dd:9f:4d:c7:60
```

Both crc32 values match the Pi 4 node, so the same firmware/BCF pair is in use.

## Two RP1-specific root causes

### 1. The vendor overlays never mux the SPI pins on BCM2712

`morse-spi` is written for BCM2835/2711: it re-uses the base DTB's existing `spi0_pins`
node and only overrides `brcm,pull`. BCM2712 has no such node, so the overlay *creates*
one containing a pull setting and no `brcm,pins` / `brcm,function` — a pinctrl map that
mentions no pins at all. GPIO9/10/11 stay unmuxed (`pinctrl get 9-11` → `none`).

`morse-ps` uses `function = "gpio_in"`, which RP1's pinctrl does not have (only `gpio`
plus `alt0..alt8` and the peripheral names), so boot logs

```
pinctrl-rp1 1f000d0000.gpio: invalid function gpio_in in map table
```

three times and none of the three pin states are applied. Direction comes from the
presence or absence of `output-high`, not from the function name.

**Fix:** [`overlays/morse-spi-pi5-overlay.dts`](../overlays/morse-spi-pi5-overlay.dts)
points `pinctrl-0` at RP1's own `rp1_spi0_gpio9` node (it is in `__symbols__`), with
GPIO8 kept as a plain GPIO chip-select in a separate node — do **not** fold it into
`rp1_spi0_cs_gpio7`, that is the native CS.

### 2. The reset pin floats LOW on RP1 — this is the one that costs days

`morse_hw_reset()` does not release reset by driving the pin high. It releases it by
floating the pin, deliberately (source comment: *"setting gpio as float to avoid forcing
3.3V High"*):

```c
gpio_direction_output(reset_pin, 0);   /* low = assert reset  */
mdelay(20);
gpio_direction_input(reset_pin);       /* float = expect high */
```

A BCM2711 pad floats high, so the Pi 4 overlay gets away with `bias-disable`.
**An RP1 pad floats low**, which leaves the MM6108 permanently in reset. It then never
drives MISO.

**Fix:** [`overlays/morse-ps-pi5-overlay.dts`](../overlays/morse-ps-pi5-overlay.dts) sets
**`bias-pull-up`** on GPIO17. The driver still drives the pin low to assert reset; the
pull-up only decides the level after the pin goes back to input. (Verified:
`gpio_direction_input()` does not clear the pull setting.)

## The error codes lie — do not chase them

With the chip held in reset nobody drives MISO, so what comes back is decided entirely by
the pull on GPIO9, and the driver misreads *both* cases:

| Pull on GPIO9 | RX buffer | Driver reports | Reality |
|---|---|---|---|
| none (`pn`) | all `0x00` | CMD63/CMD52 "succeed", then `cmd53 (ret:-71)`, `find_data_ack failed` | `0x00` *is* the R1 OK code — every response fakes success |
| pull-up (`pu`) | all `0xFF` | `CMD63 (ret:-61)` ENODATA | no response at all |

`-71` looks like more progress than `-61`; it is the same fault wearing a different mask.
Dump the RX buffer instead of reading the return code — add a `print_hex_dump()` at the
`exit:` label of `morse_spi_cmd53_write()`, and load with `debug_mask=1` (the
`find_response` failure messages are DBG level and invisible by default).

## Ruled out — do not re-investigate

- Pull-ups on GPIO9/10/11 are **not** required on RP1 (the Pi 4 overlay sets them; `a0 pn`
  works fine here). Once out of reset the chip drives MISO itself.
- spi-dw DMA, and `tx_buf == rx_buf` pointing at one buffer
- `spi_post_write_status_bytes` being too small
- 20 MHz vs 50 MHz clock
- `XTAL_TRANSFER_DELAY_BYTES = 4096` inflating every register access to a ~4122-byte
  transfer — that is by design

## Install

```sh
# 1. Driver: mm6108-2.0.1 source with patches/0001 and patches/0002 applied,
#    built against 6.18.39+rpt-rpi-2712. See docs/building-the-driver.md.

# 2. Overlays
dtc -@ -I dts -O dtb -o morse-spi-pi5.dtbo overlays/morse-spi-pi5-overlay.dts
dtc -@ -I dts -O dtb -o morse-ps-pi5.dtbo  overlays/morse-ps-pi5-overlay.dts
sudo cp morse-{spi,ps}-pi5.dtbo /boot/firmware/overlays/

# 3. Module options
echo 'options morse enable_ext_xtal_init=1 bcf=bcf_fgh100mhaamd.bin' \
  | sudo tee /etc/modprobe.d/morse.conf
```

`/boot/firmware/config.txt` — keep both boards working off one card:

```ini
[pi4]
dtoverlay=morse-ps
dtoverlay=morse-spi
[pi5]
dtoverlay=morse-ps-pi5
dtoverlay=morse-spi-pi5
[all]
```

The `[pi5]` filter does cover the Pi 500 (board type `0x19`) — verified, no board-type
filtering needed.

GPIO map (same as the Pi 4 node): MISO/MOSI/CLK/CS = 9/10/11/8, IRQ = 5, reset = 17,
wakeup = 23, busy = 24, 20 MHz.

## Checking it worked

```sh
sudo pinctrl get 17                        # expect: ip pu | hi
sudo dmesg | grep -iE 'morse|dot11'        # expect the two crc32 lines above
ip -br link                                # expect wlan1
```

`Morse Micro SPI device found, chip ID=0x0306` is `MORSE_SPI_DBG` level and is **not**
printed unless you load with `debug_mask=1` — its absence does not mean probe failed.
Firmware loaded plus a `wlan1` netdev is proof enough.

Fast iteration loop — anything other than an overlay change only needs a module reload,
and a manual `pinctrl set` survives it (DT pinctrl is applied once, at boot):

```sh
sudo modprobe -r morse; sudo dmesg -C
sudo modprobe morse enable_ext_xtal_init=1 bcf=bcf_fgh100mhaamd.bin debug_mask=1
sleep 2; sudo dmesg | grep -iE 'morse|dot11'; ip -br link
```

## Still open

- **Regulatory falls back to AU.** The firmware regdb has no TW entry:

  ```
  Country TW with channelization scheme 3 (IEEE802.11-REVmf) is not supported
  Failed to set regulatory to country TW, staying in AU
  ```

  Harmless for probe, but channel plan and TX power must be settled before this radio
  transmits.

- **No S1G userspace.** This Raspberry Pi OS install has no S1G `wpa_supplicant`,
  `hostapd` or `morse_cli`, so `wlan1` cannot join a mesh yet. The Pi 500 is the
  management and debug reference; the field mesh is still manet01 / manet02 running
  OpenMANET.

  **Resolved 2026-09-06** — S1G `wpa_supplicant` / `hostapd` / `morse_cli` were built for
  Debian 13 and the Pi 500 now peers with manet01. See the mesh section below.

## Mesh bring-up — everything needed to rebuild this box

Four files. Copies live in `scripts/` so the setup is reproducible if the card dies.

| install to | copy from |
|---|---|
| `/etc/modprobe.d/morse.conf` | `scripts/pi500-morse-modprobe.conf` |
| `/etc/halow/mesh-wlan1.conf` (mode 600, contains the PSK) | `scripts/pi500-mesh-wlan1.conf` |
| `/etc/systemd/system/halow-mesh.service` | `scripts/pi500-halow-mesh.service` |
| `/etc/systemd/system/halow-batman.service` | `scripts/pi500-halow-batman.service` |

```bash
sudo systemctl enable --now halow-mesh.service halow-batman.service
```

`halow-batman` has `Requires=halow-mesh`, so it follows the mesh unit up and down. Both are
`enabled`, so a cold boot restores the whole path: driver -> `wlan1` mesh point -> `bat0` at
`10.41.250.1/16`.

## Verifying after a reboot

```bash
sudo ./scripts/pi500-halow-healthcheck.sh        # add -t to push traffic first
```

Checks the driver params, both units, peering, batman, and — the one that matters —
**PMF and A-MPDU aggregation**. Exits non-zero on any failure.

That last check exists because of #33. The mesh can look completely healthy — peer `ESTAB`,
data flowing, `batctl ping` at 0% loss — while aggregation is silently dead and throughput
is stuck at a third of what the link can do. The two symptoms to look for:

```
MFP:  no                                    <- ieee80211w=2 missing from mesh-wlan1.conf
AGG A-MPDUs : 1175375 0 0 0 0 0 0 ...       <- every A-MPDU carries exactly one MPDU
TX BlockAck : 0
```

Nothing else in `iw`, `batctl` or `ping` will tell you. See `docs/field-test-log.md`.
