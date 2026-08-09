# `CMD63 (ret:-71)` — symptom, diagnosis, root cause

## 1. Symptom

Raspberry Pi OS (Debian 12), stock kernel `6.18.29+rpt-rpi-v8`, Pi 4 Model B.
Driver loads, device tree node binds, and then:

```
morse_spi spi0.0: failed to init SPI with CMD63 (ret:-71)
```

`-71` is `-EPROTO`. Nothing else is logged. The netdev never appears.

## 2. What the driver is actually doing

`morse_spi_cmd()` builds an SD/SDIO-over-SPI command frame into a 20-byte buffer
(`SPI_COMMAND_BUF_SIZE`), of which the first 7 bytes (`SPI_COMMAND_SIZE`) are the
command:

```
cp[0]     = 0xFF                       /* one idle byte  */
cp[1]     = 0x40 | cmd                 /* start + tx bit */
cp[2..5]  = argument, big endian
cp[6]     = crc7_be(cp+1, 5) | 0x01    /* CRC7 + end bit */
```

The response is searched from `SPI_RESP_OFFSET = 8` by `morse_spi_find_response()`:

```c
while (cp < end && (*cp == 0xff)) cp++;          /* skip idle       */
if (cp == end)   return -ENODATA;                /* nothing came back */
if (*cp == 0xFE) { /* "SPI response bit shifted" */ return -ECOMM;  }
if (*cp != 0x00) { /* "SPI response error"       */ return -EPROTO; }  /* ← -71 */
```

So `-71` means: **something came back, it just wasn't `0x00`.** That is a much more
useful error than it first appears — the bus is alive, the slave is driving MISO, and
the response simply doesn't land where the driver expects.

Note the driver *already* special-cases one misalignment (`0xFE`, a response that
began 7 bit-times late). That is a strong hint that bit-phase problems are a known
failure mode on this interface.

## 3. Diagnosis

Rather than guess, we took the driver out of the loop and reproduced its exact frame
from userspace.

Rebind `spi0.0` from `morse_spi` to `spidev`:

```sh
sudo modprobe spidev
echo spidev | sudo tee /sys/bus/spi/devices/spi0.0/driver_override
echo spi0.0 | sudo tee /sys/bus/spi/drivers/spidev/bind
```

Then send byte-for-byte what the driver sends — see
[`tools/driver_replica.py`](../tools/driver_replica.py).

### The observation

The first non-`0xFF` byte in the response window was consistently:

```
0xC0  =  1 1 0 0 0 0 0 0
         ^^^ ^^^^^^^^^^^
          |         └─ first six bits of the real response (0x00)
          └─ two trailing idle bits
```

The response **is** `0x00`. It arrives **exactly 2 bit-times late** relative to the
byte boundary the master is sampling on.

Confirmed independently with `CMD5` (`IO_SEND_OP_COND`): shift the received bytes left
by 2 bits and you get a perfectly valid SDIO R4 response —

```
R1  = 0x00
OCR = 0xA0FF8000
```

So the chip is alive, correctly powered, correctly wired, and speaking SDIO-over-SPI
properly. It is simply **2 bits out of phase with the master**.

### Ruling out signal integrity

Identical result — same `0xC0`, same 2-bit offset — at **1, 4, 10 and 50 MHz**.
A signal-integrity or setup/hold problem scales with clock rate. This does not.
Therefore it is a **logic-layer** problem, not an electrical one.

*(This also invalidated an earlier hypothesis: lowering `spi-max-frequency` from
50 MHz to 20 MHz in the overlay changed nothing, because clock speed was never
involved.)*

## 4. Root cause

`morse_spi_initsequence()` must send **144 training clocks** (18 bytes of `0xFF`) with
chip-select **deasserted** — this is the standard SD-over-SPI wake-up requirement of
"at least 74 clocks with CS high". The driver arranges that by temporarily inverting
CS polarity:

```c
spi->mode |= SPI_CS_HIGH;
if (spi_setup(spi) != 0) {
        dev_warn(&spi->dev, "can't change chip-select polarity\n");
        spi->mode &= ~SPI_CS_HIGH;
} else {
        memset(mspi->data, 0xFF, MM610X_BUF_SIZE);
        morse_spi_xfer(mspi, 18);            /* 18 bytes = 144 clocks */
        spi->mode &= ~SPI_CS_HIGH;
        ...
}
```

**On Linux ≥ 6.1, when the SPI controller uses GPIO-descriptor chip-selects
(`cs-gpios`), the SPI core sets `SPI_CS_HIGH` itself** and expresses the real polarity
through the GPIO descriptor's own active-low flag. The bit is already set before the
driver touches it, so `spi->mode |= SPI_CS_HIGH` is a **no-op**, `spi_setup()` returns
0, and the 144 training clocks go out with CS **asserted** — i.e. as if they were real
bus traffic.

The chip consumes them as part of the transaction stream. Its bit counter ends up
2 bits ahead of the master's, and stays there. Every subsequent response is
mis-framed, and the first thing the driver checks — the `0x00` for `CMD63` — reads
back as `0xC0`.

The Pi 4 cannot avoid this: its base device tree wires `cs-gpios` unconditionally
(see [`hardware.md`](hardware.md)).

### The build warning was the clue

Compiling the driver against a stock kernel emits:

```
spi.c:1519:2: error: #warning "SPI_CONTROLLER_ENABLE_CS_GPIOD macro not defined" [-Werror=cpp]
```

That macro is defined by **Morse Micro's own kernel patch**, carried in their
`MorseMicro/rpi-linux` fork and in their OpenWrt builds. Stock Raspberry Pi OS does
not have it. The driver is written for a patched kernel, and silently misbehaves on
an unpatched one.

## 5. Fix

Use `SPI_NO_CS` rather than `SPI_CS_HIGH`. The core then skips chip-select handling
entirely for that transfer, and the CS pin simply stays deasserted (high) throughout
the training burst — which is what was wanted in the first place.

```c
spi->mode |= SPI_NO_CS;
if (spi_setup(spi) != 0) {
        dev_warn(&spi->dev, "can't disable chip-select for training\n");
        spi->mode &= ~SPI_NO_CS;
} else {
        memset(mspi->data, 0xFF, MM610X_BUF_SIZE);
        morse_spi_xfer(mspi, 18);
        spi->mode &= ~SPI_NO_CS;
        if (spi_setup(spi) != 0)
                dev_err(&spi->dev, "can't restore chip-select\n");
}
```

Full patch: [`patches/0001-spi-use-SPI_NO_CS-for-training-sequence.patch`](../patches/0001-spi-use-SPI_NO_CS-for-training-sequence.patch)

## 6. Hypotheses that were tested and eliminated

Recorded because each one cost time, and because seeing them ruled out may save
someone else the same detour:

| Hypothesis | How it died |
|---|---|
| SPI clock too fast | Identical failure at 1 / 4 / 10 / 50 MHz |
| Module not powered | `CMD5` decodes to a valid OCR — the chip is alive and answering |
| Wiring / GPIO map wrong | Same map is used by OpenMANET's shipping overlay |
| `GPIO18` POWER_EN not asserted | Control experiment: driving it low changed nothing |
| JTAG pin (GPIO4) left floating | EKH01-only signal; not routed on the mPCIe card |
| RESET not actively driven | Manual reset sequencing changed nothing |
| Needs a cold power cycle | Tried; no change |
| Wrong driver version alone | Necessary but not sufficient — see below |
| Pi 5-provenance system image on Pi 4 | Controller is `brcm,bcm2835-spi @ 7e204000` (Pi 4 native, not RP1); firmware selects the correct DTB and `+rpt-rpi-v8` kernel |

## 7. What was actually required

All three, none of them optional:

1. **Driver from the MM6108 product line** — tag `mm6108-2.0.1`
   (`0-rel_mm6108_2_0_1_2026_Jun_11`). We had initially been using `mm8108-2.0.0`,
   which is a different chip family.
2. **The `SPI_NO_CS` patch.** This is the actual root-cause fix.
3. **Module parameters** `enable_ext_xtal_init=1 bcf=bcf_fgh100mhaamd.bin`.

Result:

```
morse_spi spi0.0: Loaded firmware from morse/mm6108.bin, size 468304, crc32 0xbe7b5c8f
morse_spi spi0.0: Loaded BCF from morse/bcf_fgh100mhaamd.bin, size 1251, crc32 0x941b2a82
```

No errors in `dmesg`, netdev present, new `phy` registered.
