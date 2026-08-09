# Building the Morse Micro driver on stock Raspberry Pi OS

Target: Raspberry Pi 4, Raspberry Pi OS (Debian 12), kernel `6.18.29+rpt-rpi-v8`,
Wio-WM6108 (MM6108A1) over SPI.

> If you only want a working mesh node, consider [OpenMANET](openmanet.md) instead —
> it ships this driver plus the S1G userspace already built. These instructions are
> for running the radio under Raspberry Pi OS.

## 1. Prerequisites

```sh
sudo apt install raspberrypi-kernel-headers build-essential git bc
```

## 2. Get the right source

Use the **MM6108** product line. `mm8108-*` tags are a different chip family and will
not work on an MM6108.

```sh
git clone https://github.com/MorseMicro/morse_driver.git
cd morse_driver
git checkout mm6108-2.0.1        # 0-rel_mm6108_2_0_1_2026_Jun_11
```

### Gotcha: the `mmrc` submodule

```
fatal error: mmrc-submodule/src/core/mmrc.h: No such file or directory
```

A plain `git submodule update --init` may fail if the directory already exists but is
not empty. Wipe it first:

```sh
rm -rf mmrc-submodule
git submodule update --init --recursive
```

## 3. Apply the `SPI_NO_CS` patch

**Required on any kernel that does not carry Morse Micro's SPI patch** — which
includes all stock Raspberry Pi OS kernels. See [`root-cause.md`](root-cause.md) for
why.

```sh
git apply /path/to/patches/0001-spi-use-SPI_NO_CS-for-training-sequence.patch
```

> ⚠️ This must be re-applied on **every** rebuild. If you ever upgrade the kernel, the
> module is rebuilt (or silently lost) and the patch goes with it. Packaging the
> driver as **DKMS**, with this patch in the DKMS patch directory, is the durable
> answer.

## 4. Build

### Gotcha: `-Werror=cpp`

```
spi.c:1519:2: error: #warning "SPI_CONTROLLER_ENABLE_CS_GPIOD macro not defined" [-Werror=cpp]
```

That macro comes from Morse Micro's kernel patch and is absent on stock kernels. The
warning is exactly the symptom described in `root-cause.md`, but it is a warning, not
a blocker — demote it:

```sh
make KCFLAGS=-Wno-error=cpp
```

## 5. Install

```sh
sudo make modules_install
sudo depmod -a
```

Firmware and board config file go in `/lib/firmware/morse/`:

```
/lib/firmware/morse/mm6108.bin
/lib/firmware/morse/bcf_fgh100mhaamd.bin
```

## 6. Module parameters

`/etc/modprobe.d/morse.conf`:

```
# Wio-WM6108 (FGH100M-H / MM6108A1) on Seeed WM1302 Pi HAT
options morse enable_ext_xtal_init=1 bcf=bcf_fgh100mhaamd.bin
```

### Gotcha: `bcf=` takes a full filename

The parameter is concatenated as `morse/<value>`, so it needs the complete filename
including prefix and extension. Passing the bare suffix gives:

```
BCF morse/fgh100mhaamd not found
```

✅ `bcf=bcf_fgh100mhaamd.bin`
❌ `bcf=fgh100mhaamd`

## 7. Device tree

See [`hardware.md`](hardware.md) for the overlay contents and GPIO map. In
`/boot/firmware/config.txt`:

```
dtparam=spi=on
dtoverlay=morse-ps
dtoverlay=morse-spi
```

## 8. Verify

```sh
sudo dmesg | grep -i morse
```

Expected:

```
morse_spi spi0.0: Loaded firmware from morse/mm6108.bin, size 468304, crc32 0xbe7b5c8f
morse_spi spi0.0: Loaded BCF from morse/bcf_fgh100mhaamd.bin, size 1251, crc32 0x941b2a82
```

and a new interface in `ip link` / `iw dev`.

## 9. What you still don't have

A loaded driver is **not** a working link. On stock Debian:

- `wpa_supplicant` is v2.10 with **no** S1G / 802.11ah support (`strings` finds zero
  matches for `S1G`, `802.11ah`, `halow`)
- `hostapd` and `morse_cli` are not installed at all
- there is no `/morse` directory, though the driver's `dhcpc_lease_update_script`
  parameter defaults to `/morse/scripts/dhcpc_update.sh`

Morse Micro's patched `wpa_supplicant` / `hostapd` live in their OpenWrt fork. Getting
S1G userspace onto Raspberry Pi OS means building those yourself — which is the point
at which [OpenMANET](openmanet.md) becomes the pragmatic answer.
