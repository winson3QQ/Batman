# Flashing OpenWrt with `dd` does not clear the overlay

This one is not specific to HaLow, or to OpenMANET. It applies to **any** OpenWrt
squashfs sysupgrade image written to an SD card with `dd`, and it cost several hours
because every check you would normally trust comes back green.

## Symptom

Flash the image, verify it byte-for-byte, power-cycle the device — and it boots the
**previous** system. Not a stale cache, not a half-written card: SSH host key, root
password, IP address, hostname and setup-wizard state all exactly as they were.

Reflashing does not help. It looks precisely like the write never landed.

## Cause

An OpenWrt squashfs sysupgrade image contains only the **boot partition and the
squashfs rootfs**. For OpenMANET 1.7.0 / rpi4:

```
image size                    121,334,861 bytes  (~116 MiB)
p1  boot (vfat)                        64 MiB
p2  rootfs                              4 GiB
      ├─ squashfs                      ~43 MiB     ← written by dd
      └─ rootfs_data (overlay)        ~4.0 GiB     ← NOT written by dd
```

`dd` writes the first ~116 MiB and stops. The overlay — which is where OpenWrt keeps
*everything* that makes a device "configured": `/etc/config/*`, `/etc/shadow`,
`/etc/dropbear/*_host_key`, uci-defaults state — is left completely untouched.

On boot, OpenWrt finds a valid `rootfs_data`, mounts it over the fresh squashfs, and
the old configuration comes back wholesale.

This is not a bug. `sysupgrade` is the supported path and it handles the overlay
(`-n` to discard settings, default to keep them). Writing the image with `dd`
bypasses that logic entirely — including the part that would have wiped the overlay.

## Fix

After writing the image, zero the region from the end of the squashfs to the end of
the rootfs partition.

```sh
# 1. end of squashfs = p2 start + squashfs bytes_used
#    p2 start comes from the partition table; bytes_used is squashfs superblock @0x28
sudo fdisk -l /dev/mmcblk0                        # p2 start sector
sudo dd if=/dev/mmcblk0p2 bs=1 skip=40 count=8 2>/dev/null | od -An -tu8

# for OpenMANET 1.7.0 / rpi4 this works out to:
SQEND=121334861                    # 75497472 + 45837389
P2_END=$(( 8527871 * 512 + 512 ))  # last sector of p2

# 2. write the image
zcat openmanet-*.img.gz | sudo dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress

# 3. wipe the overlay
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=1M seek=$SQEND oflag=seek_bytes \
        count=$(( (P2_END - SQEND) / 1048576 + 1 )) conv=fsync status=progress
sync
```

> ⚠️ **`seek` must be given in exact bytes via `oflag=seek_bytes`.**
> Using `seek=115` (i.e. 115 MiB = 120,586,240) starts *inside* the squashfs and
> truncates its last ~748 KB. The card then fails to mount with
> `unable to read id index table`. Ask how I know.

## How to tell a flash actually took

Hashing the image region is **not** a useful test — it will match whether or not the
overlay survived, because the overlay lives beyond it. Check the running system
instead, in this order:

| Check | Fresh system |
|---|---|
| **`ssh root@<ip>` with no password** | works — factory `/etc/shadow` is `root:::` |
| IP address | the factory default (`10.41.254.1` for OpenMANET), old address gone |
| SSH host key | **changed** — `/etc/dropbear/` is empty in the squashfs, keys are generated on first boot |
| `uptime` | ~0 min |
| `df -h /overlay` | freshly created loop device |

The blank-password check is the most direct of these. Host keys are a good secondary
signal *once you have confirmed the image does not ship any* — verify by mounting the
squashfs and listing `/etc/dropbear/`.

Note that `known_hosts` is hashed by default, so `grep` will not find an entry:

```sh
ssh-keygen -F 10.41.254.1          # works
grep '^10.41.254.1 ' ~/.ssh/known_hosts   # finds nothing, even when present
```

## Install your SSH key before running the setup wizard

On a fresh flash root has no password, so the key goes in with no authentication at
all. Do this *first* — the wizard sets a password, and if you mistype or forget it
your only way back in is another flash.

```sh
cat ~/.ssh/id_ed25519.pub | ssh root@10.41.254.1 \
 'mkdir -p /etc/dropbear /root/.ssh
  tee -a /etc/dropbear/authorized_keys >> /root/.ssh/authorized_keys
  chmod 600 /etc/dropbear/authorized_keys /root/.ssh/authorized_keys'
```

Both paths are written because OpenWrt's dropbear reads `/etc/dropbear/authorized_keys`
while some builds use `~/.ssh/authorized_keys`. `ssh-copy-id` only writes the latter,
which is why it often appears to do nothing on OpenWrt.

## Hypotheses that were wrong

Recorded because each one looked convincing at the time.

| Hypothesis | How it was eliminated |
|---|---|
| **The SD card is failing** — accepts writes, loses them on power loss | Byte-for-byte comparison: **1 byte** differed out of 121,334,861 — the FAT dirty flag at partition offset 37, `0 → 1`, set by mounting the volume read-write. The card was fine. |
| The Pi boots from some other device | Removing the SD card entirely → does not boot at all |
| The power was never actually cut | Sampled `/sys/class/net/eth0/carrier` and ping once per second; captured the drop and the full boot sequence |
| The image ships a fixed host key, so host keys prove nothing | Mounted the squashfs — `/etc/dropbear/` is empty |
| The region after the squashfs reads as zeros, so there is no overlay | Not conclusive, and it sent the investigation down the wrong path for a while. Wiping that region fixed the problem regardless. |

Two mistakes of my own worth recording:

- I concluded the card was defective and recommended replacing it. It was not. The
  owner's scepticism was correct, and re-examining under that pressure is what
  produced the single-byte diff that cleared the card.
- The first wipe used MiB-granular `seek` and ate the tail of the squashfs. Byte-exact
  offsets only.

## Incidental gotchas

- **A running OpenWrt survives having its SD card pulled.** The squashfs is largely in
  page cache, so the system keeps serving DHCP and answering SSH with no card present.
  Always cut power *before* removing the card, or you will be diagnosing a machine that
  cannot possibly be reading the card you think it is.
- **Desktop automounters touch the card.** udisks2 mounts the FAT partition read-write
  on insert, which sets that dirty flag. Harmless, but it means a freshly flashed card
  no longer matches its image byte-for-byte after you look at it.
- **Verify read-back with `iflag=direct`** so you are reading the card and not the page
  cache.
