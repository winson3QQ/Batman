# #209 E0 — Pi 3A+ firmware experiments (bench kit)

Gate for design v3.1 (`docs/design/209-ab-on-pi3.md` §8). **Run E0f first**; its result picks A0-auto vs A0-prefix. Everything here is **non-destructive to the image**: both boot partitions boot the same rootfs, and the cmdline marker `e0=pN` says which one the firmware used.

| File | What | Tested on the DEV machine (no DUT) |
|---|---|---|
| `reboot-part.c` | `reboot(RESTART2, "N")`; busybox `reboot` cannot pass N | host gcc `-Wall -Wextra -Werror` clean; bad args (`''`, `x`, `63`, `-1`, `1x`) → rc 2 before any reboot. DUT machine 2026-09-30: static aarch64 build clean (gcc 13.3.0 musl). **Not tested yet:** the actual reboot |
| `e0f-prep-card.sh` | fresh bcm2710 OpenWrt card/image → p3 ext4 1G + p4 FAT copy of p1, markers, `autoboot.txt` | `sh -n`; table step run on a real image file (`E0_TABLE_ONLY=1`): p3/p4 placed 4 MiB-aligned, file grown, refuses a 4-partition or GPT image. DUT machine 2026-09-30: full run as root on `openmanet-1.8.0-rpi3-mm6108-spi-squashfs-sysupgrade.img` (1.4.14) → rc 0, mkfs/mount/copy done, loop released, no CR, p2 squashfs byte-identical to `root.squashfs` |
| `e0-probe.sh` | per-boot record: marker, DT `chosen/bootloader`, PSCI, restart handlers, blob versions → persistent log | `sh -n` only |

## 0. Build the tool (machine with the OpenWrt tree)

```sh
TC=$(ls -d ~/firmware-2710/staging_dir/toolchain-aarch64_cortex-a53_gcc-*_musl | head -1)   # gcc-13.3.0 on the bench tree
export STAGING_DIR=~/firmware-2710/staging_dir        # otherwise only a warning
$TC/bin/aarch64-openwrt-linux-musl-gcc -static -Os -s -o reboot-part scripts/e0/reboot-part.c
file reboot-part        # expect: ELF 64-bit ARM aarch64, statically linked
```

## 1. Prepare the card

Use a **freshly built / flashed bcm2710 image that has never booted**. A booted card already has its expand-to-fill data p3, and the script refuses it.

- **Card reachable from Linux / WSL:** flash it, then `sudo sh scripts/e0/e0f-prep-card.sh /dev/sdX`.
- **Card only reachable from Windows:** prep the **image file** instead: `sudo sh scripts/e0/e0f-prep-card.sh openwrt-…-bcm2710-…-ext4-factory.img` (gunzip first). The script grows the file. Then flash the result with the usual burner / Imager.
- ⚠️ **Do not edit the boot files from Windows with `Set-Content` / `>`** (CRLF, #208). The script writes LF and refuses if it finds a CR.

Why p3 is a pre-made ext4 and the trial FAT is p4: the pre-#230 `95-batman-storage` keeps an existing ext4 p3. It would `mkfs.ext4` a FAT at p3, which is the exact bug #230 fixes. On a post-#230 image the data partition is refused on this layout instead. That is harmless: the probe then logs to `/root`.
On 1.4.14 (feed `8685c5a`), the `PARTCOUNT -eq 2` refusal (line 62) sits **inside** `if [ ! -b "$PART" ]`. With p3 pre-made, that branch is skipped. The hook sees the ext4 magic on p3, keeps it and mounts it at `/opt/batdata`. So the pre-made p3 is what actually protects the card, and the probe logs to `/opt/batdata/e0.log`. Confirm on first boot: `logread | grep batman-storage` should say p3 already has a filesystem.

## 2. Boot and copy the tools

Reach the node the usual way (USB-RJ45 dongle; the IPv6 link-local anchor comes from the dongle MAC, #203). Then:

```sh
scp reboot-part scripts/e0/e0-probe.sh root@[fe80::…%N]:/root/
chmod +x /root/reboot-part
```

## 3. E0f sequence (record `sh /root/e0-probe.sh <step>` after EVERY boot)

| Step | Action | A0-auto holds if | Notes |
|---|---|---|---|
| ① | cold boot (power on) | `e0 marker: p4` | `autoboot.txt` `boot_partition=4` honoured |
| ② | `/root/reboot-part 1` | `p1` | the argument overrides `boot_partition` once |
| ③ | plain `reboot` | `p4` | back to the default |
| ④ | `/root/reboot-part 1`, then `echo c > /proc/sysrq-trigger` | `p4` | panic (`panic=10`) passes NULL, so partition 0 |
| ⑤ | `/root/reboot-part 1`, then pull power | `p4` | power-on reset |
| ⑥ | edit p1 `autoboot.txt` → `boot_partition=1` (on the node: `mount /dev/mmcblk0p1 /mnt`, `printf '[all]\nboot_partition=1\n' > /mnt/autoboot.txt`, `sync`), reboot | `p1` | the "commit" verb |
| ⑦ | from ⑥ state: `/root/reboot-part 4` | `p4`, then plain `reboot` → `p1` | the trial verb in the other direction |

**Decision:**
- ①, ②, ③, ⑥ and ⑦ all hold → **A0-auto**.
- ① lands on `p1` (autoboot ignored) but ②–⑤ show `reboot-part` works (use `reboot-part 4` from p1 to see it) → **A0-prefix**.
- `reboot-part N` never changes the marker → **A0 fails, fall back to v2 (A1)**. First check the probe's `restart handlers` / `psci` lines: a PSCI restart handler might be preempting `bcm2835_wdt`. That would be a kernel-config finding, not a firmware one.

If a step leaves the node unreachable for more than 3 minutes: pull the card and read p1/p4 on the PC. Nothing in E0f writes the rootfs, so a reflash is never needed.

## 4. Report back

Paste the full `e0.log` plus a one-line verdict per step into #209. Update the design doc §8/§12 (PR #231) only after that.

E0a–E0e (watchdog-triggered reset, partition table types, corrupt `autoboot.txt`, bad DTB / VFS panic) come after E0f; see design §8.
