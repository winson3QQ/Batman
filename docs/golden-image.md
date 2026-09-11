# Golden image — build, flash, verify (SOP)

How to produce a flashable OpenMANET 1.8.0 golden image that **self-provisions on first boot**
(storage + crash-capture), and how to flash + verify it **on a Pi with no card reader**.
Validated end-to-end on real hardware 2026-09-11. Scope: the storage-provisioning (#88) +
crash-debug (#61) content. The mesh/security/identity model (per-deployment credential, unique
identity) is a separate decision (#13/#54) — see "Production" below.

## What the golden contains
- OpenMANET **1.8.0** base.
- `/etc/uci-defaults/95-batman-storage` — first-boot storage provisioning (carves the SD free
  space into an expand-to-fill data partition + mount; #88). Runs once, self-deletes.
- Fixed `/boot/overlays/ramoops.dtbo` — kernel-panic capture to pstore (#61).
- `parted` (+ deps) — needed by the storage hook.

## 1. Build the golden node
Start from a node running **stock OpenMANET 1.8.0** (fresh flash, or `sysupgrade`).

**Upgrade gotchas (if sysupgrading from an older release):**
- **`gpsboard.init` hangs `sysupgrade` at "Saving config files".** Its `enabled` handler blocks,
  so the config-save loop (`for s in /etc/init.d/*; do $s enabled`) never returns. Move it aside
  first: `mv /etc/init.d/gpsboard.init /root/` (or use `-n` to skip config-save entirely).
- **1.8.0 first-boot regenerates config** (board.d + a random wifi key), so `keep-config` does
  **not** survive — the node comes up stock (IP `10.41.254.1`, SSH off). Regain access via LuCI
  (`http://10.41.254.1`) or ubus (root has an empty password): write your key with
  `ubus … file write /etc/dropbear/authorized_keys`.
- **ETHFIX (bug #1) is NOT needed on 1.8.0** — eth0 comes up in `br-lan` fine (verified), despite
  `03_openmanet_eth`'s case list still missing `bcm2711,mm6108-spi`.

Then on the node:
1. Install `parted` (the storage hook needs it). opkg over 借網 often fails (IPv6/feed) — the
   reliable path is: download the `.ipk`s on a machine with internet and `opkg install ./*.ipk`.
2. Fix ramoops: `deploy/provisioning/fix-ramoops-dtbo.sh` (needs `dtc`; same offline-ipk trick).
3. Install the storage hook: `install -m0755 deploy/provisioning/uci-defaults/95-batman-storage
   /etc/uci-defaults/95-batman-storage`. (Or run `scripts/depersonalise.sh`, which installs it +
   the identity hook + strips secrets — do this for a distributable golden.)
4. **Clean build cruft** before imaging: remove any `/etc/hosts` 借網 entries, `dtc`/`libfdt`
   (build-only), `*.orig` backups, and the borrowed-net default route. **Keep `parted`.**
5. Make it look blank for the customer's first boot: no `/opt/batdata` mount, no `mmcblk0p3`
   (`umount /opt/batdata; /etc/init.d/batdata-mount disable; rm /etc/init.d/batdata-mount;
   parted -s /dev/mmcblk0 rm 3`), storage hook **staged** in `/etc/uci-defaults/`.

## 2. Capture the golden image
The card's data is only p1+p2 (~4.2 GB); the rest is unpartitioned free space. dd just p1+p2 and
gzip — the mostly-empty overlay compresses to ~68 MB:
```sh
# on a host, over SSH; count covers p1+p2 (end-of-p2 sector / 8192)
ssh root@<node> 'sync; dd if=/dev/mmcblk0 bs=4M count=1042 2>/dev/null | gzip -1' > golden-1.8.0.img.gz
gzip -t golden-1.8.0.img.gz   # verify; decompresses to ~4168 MB
```

## 3. Flash — **on the Pi, no card reader** (the key trick)
A Pi boots from its only SD slot, so you can't overwrite it with a normal `dd`. But
`sysupgrade` runs its stage2 **from RAM** (pivots off the SD), so it can rewrite the Pi's own
card. Force it to take our raw full-disk image:
```sh
scp golden-1.8.0.img.gz root@<node>:/tmp/
ssh root@<node> 'sysupgrade -F -n /tmp/golden-1.8.0.img.gz'
#   -F  force (skip the sysupgrade-format check — ours is a raw dd image)
#   -n  don't keep config = flash as blank (also skips the gpsboard config-save hang)
```
SSH drops as stage2 pivots to RAM; the node writes the image and reboots into the fresh golden.
No USB reader, no second machine.

## 4. Verify (fresh-flash self-provision)
After it reboots, confirm the first-boot chain ran with **zero touch**:
```sh
ssh root@<node> '
  ls /etc/uci-defaults/95-batman-storage 2>/dev/null && echo "hook NOT run" || echo "hook ran+self-deleted"
  grep -c mmcblk0p3 /proc/partitions          # 1 = data partition auto-created
  mount | grep /opt/batdata                    # auto-mounted, expand-to-fill
  dmesg | grep "Registered ramoops"            # crash capture active
'
```
Expected: hook ran+self-deleted, p3 created, `/opt/batdata` mounted (card-sized), ramoops
registered, and SSH works via the baked credential. That is "flash a blank card → boot → zero
config → auto-provision + connect."

## Production notes (beyond this validation)
- This validation baked a **maintainer SSH key** as a stand-in credential. A real per-deployment
  golden replaces it: `depersonalise.sh` strips secrets + installs the identity first-boot hook
  (unique hostname/IP per card); the deployment's mesh key + credential are provisioned per batch
  (the zero-config-vs-security tension, #13/#54).
- **LUKS at-rest encryption (#47) needs a kernel rebuild** (`CONFIG_DM_CRYPT`) — the stock image
  lacks dm-crypt, so the storage hook provisions unencrypted until that lands.
- **Regulatory**: set `country`/channel per region before shipping (#92).
