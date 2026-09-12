# Golden image — build, flash, verify (SOP)

How to produce a flashable OpenMANET 1.8.0 golden image that **self-provisions on first boot**
(storage + crash-capture), and how to flash + verify it **on a Pi with no card reader**.
Validated end-to-end on real hardware 2026-09-11. Scope: the storage-provisioning (#88) +
crash-debug (#61) content. The mesh/security/identity model (per-deployment credential, unique
identity) is a separate decision (#13/#54) — see "Production" below.

## What the golden contains
- OpenMANET **1.8.0** base.
- **Mesh baseline** (`deploy/provisioning/meshpoint-1.8.0.sh`, run by `depersonalise.sh`): the
  post-wizard Mesh Point + bridge config without the LuCI wizard — HaLow `radio1` in 802.11s mesh
  (default **ch 40 = 4 MHz**, US), batman-adv `bat0` (BATMAN_V, BLA) with hardif `batmesh0`,
  `br-ahwlan` = eth0 + bat0 + onboarding AP, mesh11sd `enabled=1 / mesh_fwding=0 / mesh_nolearn=1`
  (the wizard's `nolearn` typo fixed). Reproduced from the wizard's JS; validated against manet02.
- **Addressing = OpenMANET two-stage** (#11 decision): the image carries only a bootstrap
  `10.41.254.x` + `openmanetd.config.dhcpconfigured=0`; on first boot openmanetd reserves a
  mesh-unique IP + 16-lease DHCP window via alfred gossip and **reboots once**. Address nodes by
  `<hostname>.local`, never by IP.
- **Keys**: the deployment batch key is baked with `depersonalise.sh --mesh-key/--ap-key`. Without
  it the public placeholder `CHANGE-ME-NOW` is baked and **`halow-keyguard`** (S18, #103) keeps the
  HaLow radio and the onboarding AP **down** (meshled red) until `halow-setkey --mesh <key> [--ap
  <key>]` is run over Ethernet (the M12 → RJ45 port on the V3 enclosure). Ethernet is never touched.
- `/etc/uci-defaults/95-batman-storage` — first-boot storage provisioning (carves the SD free
  space into an expand-to-fill data partition + mount; #88). Runs once, self-deletes. It installs
  the `batdata-mount` init (S11), which also does the crash/reboot capture (#61): pstore records
  → `/opt/batdata/crash/`, a reason line for every boot + the syslog ring at every clean
  shutdown → `/opt/batdata/log/` (openmanetd's addressing reboot is named as such).
- `/etc/uci-defaults/99-halow-identity` — per-card hostname (OpenMANET's own `BCM2711-xxxx`
  scheme), AP SSID = hostname, random bootstrap IP, fresh SSH host keys.
- `meshled` (1.8.0 variant) — two-colour status LED; `halow-setkey` — the key door.
- `batpower` (S95, #122) — battery watchdog, `source=mock` until the INA226 is fitted;
  `flightrec` (S99, #105) — 60 s heartbeat into the kernel log for the ramoops console record.
- openmanetd `dbFile: /tmp/openmanetd.db` (#104) — its SQLite WAL was the only steady writer on
  the rootfs overlay; `dtoverlay=ramoops,console-size=0x8000` (#105) — rolling console capture.
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
- **ETHFIX (bug #1) IS needed on 1.8.0.** *(Corrected 2026-09-11 — this bullet previously claimed
  the opposite.)* Stock `03_openmanet_eth` still has no `bcm2711,*` in its case list, so on a Pi 4
  `ucidef_set_interface_lan "eth0"` is never called and the wired port has no L3 — the node boots
  normally and is simply unreachable. The earlier "verified" observation was made on manet01,
  whose rootfs had **already** been patched (`03_openmanet_eth` 932 → 1022 bytes, md5
  `9e2c0dcb…`), so what was verified was the patched behaviour, not stock. Confirmed 2026-09-11
  on the #133 card: stock squashfs → no eth0; after applying
  `patches/03_openmanet_eth.1.8.0-ethfix` to the same image, eth0 came up in `br-lan` at
  `10.41.254.1` immediately. Identify which one you have by that md5 — stock is
  `c32e6357…`.

Then on the node:
1. Install `parted` (the storage hook needs it). opkg over 借網 often fails (IPv6/feed) — the
   reliable path is: download the `.ipk`s on a machine with internet and `opkg install ./*.ipk`.
2. Fix ramoops: `deploy/provisioning/fix-ramoops-dtbo.sh` (needs `dtc`; same offline-ipk trick).
3. Stage the repo on the node (`scripts/` + `deploy/provisioning/`, LF line endings — convert
   with `sed 's/\r$//'` if copying from Windows) and run **`sh scripts/depersonalise.sh`**:
   `--mesh-key K --ap-key K` for a deployment batch (cards come up on the air),
   `--mesh-id`, `--channel` (40 = 4 MHz, 42 = 2 MHz), `--country` as needed, and **`--bench`** for
   a test image only (keeps the maintainer SSH key + SSH enabled, stamps `/etc/BENCH-IMAGE` —
   never publish one). It bakes the mesh baseline, resets addressing to bootstrap, strips
   secrets/identity/openmanetd's peer DB, and installs the hooks + services listed above.
   (busybox has no `install(1)`; the scripts use `cp`+`chmod`.)
4. **Clean build cruft** before imaging: remove any `/etc/hosts` 借網 entries, `dtc`/`libfdt`
   (build-only), `*.orig` backups, `/root/batman` staging, and the borrowed-net default route.
   **Keep `parted`.**
5. Make it look blank for the customer's first boot: no `/opt/batdata` mount, no `mmcblk0p3`
   (`umount /opt/batdata; /etc/init.d/batdata-mount disable; rm /etc/init.d/batdata-mount;
   parted -s /dev/mmcblk0 rm 3`), storage hook **staged** in `/etc/uci-defaults/`. (On the bench
   you may keep p3: the hook keeps an existing filesystem and only regenerates the init.)

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
  cat /opt/batdata/log/boot-reasons.log        # one line per boot: PANIC / CLEAN / UNCLEAN
'
```
Expected: hook ran+self-deleted, p3 created, `/opt/batdata` mounted (card-sized), ramoops
registered, a boot-reason line written, and SSH works via the baked credential. That is "flash
a blank card → boot → zero config → auto-provision + connect." Optional deeper check: `reboot`
→ the next line says `CLEAN: … trigger=reboot/halt command …` and `log/shutdown_*.log` holds
the pre-reboot syslog; `echo c > /proc/sysrq-trigger` → `PANIC`, record under `crash/`.
(A reflash itself shows as `UNCLEAN` on the next boot — sysupgrade runs no clean shutdown.)

Then the mesh/identity chain (validated end-to-end 2026-09-11 on the Pi 4 bench node against
manet02, image built with `depersonalise.sh --bench` and **no** batch key):
```sh
ssh root@<node> '
  cat /proc/sys/kernel/hostname; uci get wireless.default_radio0.ssid   # BCM2711-xxxx, same
  uci get network.ahwlan.ipaddr; uci get openmanetd.config.dhcpconfigured   # 10.41.254.x, 0
  halow-setkey --status; meshled status | head -3    # PLACEHOLDER, radios disabled, red
  halow-setkey --mesh <batch-key> --ap <ap-key>      # the door (skip if keys were baked)
'
# ~2.5 min later openmanetd has reserved the final IP and rebooted once; reach the node by name:
ssh root@<hostname>.local '
  tail -1 /opt/batdata/log/boot-reasons.log   # CLEAN: … trigger=openmanetd address reservation
  uci get network.ahwlan.ipaddr; uci get openmanetd.config.dhcpconfigured   # 10.41.x.y (not 254), 1
  batctl n; meshled status | head -3          # peer(s) listed; red OK / green LINKED
'
```
With `--mesh-key/--ap-key` baked, the guard never triggers: the card joins the mesh on its
first boot and only the reservation reboot remains.

**Two golden cards, over the mesh (validated 2026-09-11):** the same image (keys baked, MBR
stripped of p3 — see below) was pushed by scp *through the running mesh* to manet02 and
applied with `sysupgrade -F -n` from RAM (no Ethernet, no card reader); the golden node was then
rebooted into its own first boot. Both came up zero-touch: `BCM2711-47ee` → 10.41.37.130 (DHCP
window 100/16) and `BCM2711-45d7` → 10.41.196.21 (116/16), 802.11s ESTAB within a minute, each
naming the reservation reboot in `boot-reasons.log`, ping 0 % loss. That is a remote fleet
re-image with no hands on the hardware (the manual precursor of #89).

## 5. Publishing: strip p3 from the image's partition table
The golden node's own card has p3 (its data partition); a published image must carry only
p1+p2 so a target with a *different* p3 is never overwritten (`sysupgrade` rewrites the whole
disk when the partition maps differ). Capture raw, zero the third MBR entry **in the image
file**, then compress:
```sh
dd if=/dev/mmcblk0 of=/opt/batdata/golden/v11.img bs=4M count=1042
dd if=/dev/zero of=/opt/batdata/golden/v11.img bs=1 seek=478 count=16 conv=notrunc   # MBR entry 3 @ 0x1DE
parted -sm /opt/batdata/golden/v11.img unit s print | grep -E '^[0-9]+:'               # expect 1: and 2: only
gzip -1 -c /opt/batdata/golden/v11.img > /tmp/golden-v11.img.gz
```
The golden node's own partition table is not touched.

## Production notes (beyond this validation)
- This validation baked a **maintainer SSH key** as a stand-in credential. A real per-deployment
  golden replaces it: `depersonalise.sh` strips secrets + installs the identity first-boot hook
  (unique hostname/IP per card); the deployment's mesh key + credential are provisioned per batch
  (the zero-config-vs-security tension, #13/#54).
- **LUKS at-rest encryption (#47) needs a kernel rebuild** (`CONFIG_DM_CRYPT`) — the stock image
  lacks dm-crypt, so the storage hook provisions unencrypted until that lands.
- **Regulatory**: set `country`/channel per region before shipping (#92).
