# Upgrading a Pi 4 node to OpenMANET 1.8.0 (mm6108-spi)

This is the field-tested procedure for taking a Pi 4B + Wio-WM6108 node from a
fresh flash of the stock **OpenMANET 1.8.0** image to a working batman-adv mesh
member managed over Ethernet and HaLow, together with the two image/wizard bugs
that will otherwise stop you, and the end state that proves it worked.

Reference hardware: Raspberry Pi 4B, Seeed WM1302 HAT, Wio-WM6108 (MM6108A1).
Board identity reported by the image: `bcm2711,mm6108-spi` (set via
`distroconfig.txt: dtoverlay=sysinfo,board-name=...`), **not**
`raspberrypi,4-model-b`. That single fact is behind bug #1.

---

## 0. Flash the card (do the wipe!)

```sh
# On a host with the card at /dev/mmcblk0 (verify it is NOT your rootfs disk):
# 1. Zero the front of the card FIRST. dd writes only ~125 MiB, but p2 is 4 GB;
#    a stale f2fs overlay left behind the squashfs is re-mounted on boot and you
#    boot "new squashfs + old settings" — the classic "reflash didn't take".
dd if=/dev/zero of=/dev/mmcblk0 bs=4M count=1280 conv=fsync   # ~5 GiB, ~70 s

# 2. Write the image (use the ETHFIX image if you have it — see bug #1).
gunzip -c openmanet-1.8.0-rpi4-mm6108-spi-...img.gz | dd of=/dev/mmcblk0 bs=4M conv=fsync

# 3. Verify byte-for-byte.
```

First-boot state of the **stock** image (read from the image source):

| Thing            | Value                                                             |
|------------------|------------------------------------------------------------------|
| eth0             | LAN, `10.41.254.1/16`, runs a DHCP server (`board.d/99-lan-ip`)   |
| root password    | from EEPROM `device_password`; a self-built Pi 4 has none → blank |
| SSH (dropbear)   | **disabled** by default (`31_dropbear_default_disable`)           |
| AP SSID / PSK    | SSID = hostname; PSK from EEPROM `default_wifi_key`, else random 8 chars |
| green LED        | bound to HaLow in userspace (`distroconfig.txt: act_led_trigger=none`) — solid green is stock behaviour, not a leftover daemon |

`openmanetd` reassigns the LAN IP after the wizard, so **do not memorise the IP** —
use mDNS (`<hostname>.local`) once the hostname is set.

---

## Bug #1 — stock image never makes eth0 a LAN interface on a Pi 4

**Symptom.** After flashing stock 1.8.0, the wired port is completely dead:
`carrier=1` but the node emits **zero frames** (tcpdump on the peer shows only
your own packets), no DHCP, no ARP reply on any 10.41 address. Reflashing changes
nothing because the cause is in the image, not your config.

**Cause.** `etc/board.d/03_openmanet_eth` only calls
`ucidef_set_interface_lan "eth0"` for board names in a fixed `case` list. The list
has `bcm2712,mm6108-spi` (Pi 5) and `raspberrypi,4-model-b`, but **not**
`bcm2711,mm6108-spi` — which is exactly what this image reports on a Pi 4. The case
never matches, eth0 is left out of every network interface, and the wired port has
no L3 at all. (Firewall is a red herring; there is nothing to firewall.)

**Fix (ETHFIX).** Add the Pi 4 board names to the case list. Unsquash the rootfs,
edit one file, re-squash, write back at the 72 MiB offset:

```sh
# in the case "$board" in ... list, alongside bcm2712,mm6108-spi:
bcm2711,mm6108-sdio |\
bcm2711,mm6108-spi  |\
bcm2711,mm8108-sdio |\
bcm2711,mm8108-spi  |\
```

Only `03_openmanet_eth` changes (932 → 1022 bytes); every other file's
perms/owner/size is identical to stock. The patched file is committed here as
[`patches/03_openmanet_eth.1.8.0-ethfix`](../patches/03_openmanet_eth.1.8.0-ethfix).

After ETHFIX, eth0 comes up as LAN + DHCP server and a directly-wired peer gets a
`10.41.x/16` lease. Verified: 935 Mbit/s both directions (gigabit line rate).

---

## 1. Get in and set identity + SSH

Stock SSH is off, so the first entry is the LuCI web UI (or ubus JSON-RPC) over
the wired link, at whatever IP the DHCP lease gives you (`http://10.41.254.1`
before the wizard). Run the setup wizard → **Mesh Point**, matching the other
nodes exactly:

| Field       | Value        |
|-------------|--------------|
| mesh id     | `openmanet1` |
| encryption  | SAE          |
| key         | `CHANGE-ME` — set your own; lab value not published |
| channel     | 42           |
| bandwidth   | 2 MHz        |
| country     | US           |

The wizard sets the hostname and root password. Then enable SSH. Over ubus this
needs no web clicks (root session has full rw ACL):

```sh
# login → uci set dropbear.<section>.enable=1 → commit → write authorized_keys
uci set dropbear.main.enable=1 && uci commit dropbear
# install the peer's public key into /etc/dropbear/authorized_keys (mode 0600)
```

dropbear does **not** bind an interface (`Interface` empty = listens on
`0.0.0.0`); what may reach it is decided by the firewall zone. eth0 + bat0 + the
local AP are all bridged into `br-ahwlan` (the `ahwlan` interface) in the **lan**
zone (input ACCEPT), so SSH is reachable over wired, mesh and AP alike — only
`wan` is blocked.

From here on, address the node by mDNS name: `ssh root@<hostname>.local`. The IP
churns; the name does not.

---

## Bug #2 — wizard mesh joins batman but all unicast is dropped

**Symptom.** Mesh peers (802.11s plink ESTAB), batman originators are mutually
visible, green LED is solid LINKED — but **every unicast is lost**: `batctl ping`
100 %, ARP FAILED, IP ping dead. Broadcast/OGM traffic flows (that is why batman
"sees" the peer), unicast does not. RSSI is healthy (tested down to −54 dBm), so
it is not proximity/saturation, and `mesh_fwding` is already 0, so that is not it
either.

**Cause.** `mesh_nolearn` asymmetry. batman-over-802.11s needs the 802.11s layer
to be a dumb L2 pipe: `mesh_fwding=0` **and** `mesh_nolearn=1` on every node. The
wizard sets `mesh_fwding=0` but leaves `mesh_nolearn=0`, so with a peer that has
`mesh_nolearn=1` the two ends disagree on path learning and unicast never lands.

**Fix.** Align `mesh_nolearn` to 1 on the node (commit for persistence, and apply
live without a restart):

```sh
uci set mesh11sd.mesh_params.mesh_nolearn=1 && uci commit mesh11sd
iw dev wlh0 set mesh_param mesh_nolearn 1
```

Unicast recovers immediately: `batctl ping` 5/5, ~3 ms, both directions; the TT
entry flips from `[...T]` (temporary/phantom) to `[....]`.

> Triage rule: **broadcast OK + unicast lost + good RSSI → compare
> `iw dev <if> get mesh_param mesh_nolearn` (and `mesh_fwding`) on both ends
> first.** Do not blame distance or firmware until those are symmetric.

Required trio on every node: `mesh11sd: enabled=1 + mesh_fwding=0 + mesh_nolearn=1`.

---

## 2. LED daemon (meshled) on 1.8.0

`scripts/meshled` in this repo targets 1.7.0. On 1.8.0 the HaLow interface and
radio names changed, so patch before deploying:

- `wlan0` → `wlh0` (HaLow netdev; `morse_wifi_version=2`)
- `wireless.default_radio3` → `wireless.default_radio1` (mesh_id lives on radio1)
- `wireless.radio3.disabled` → `wireless.radio1.disabled`

LEDs are unchanged: red = `/sys/class/leds/PWR`, green = `/sys/class/leds/ACT`.
Install to `/usr/bin/meshled` + `/etc/init.d/meshled`, then
`/etc/init.d/meshled enable && start`. Solid red = system OK, solid green =
peered + routed. Cold-boot verified: state restores automatically.

---

## 3. End state (verified 2026-09-08)

- Node: OpenMANET 1.8.0, hostname `manet01`, morse FW `rel_mm6108_2_0_1`
- Wired: eth0 = LAN (ETHFIX), **935 Mbit/s** both ways to the wired peer
- Mgmt: `ssh root@manet01.local` (pubkey, passwordless) + LuCI
- Mesh: 802.11s ESTAB, batman neighbour fresh, **unicast 0 % loss ~3 ms both ways**
- LED: red OK + green LINKED, restores on cold boot
- Persistence: all `uci commit`ed to overlay; `S99meshled`, `S19dropbear` enabled

Before pulling power after any SSH-written change, `sync` the node — the f2fs
overlay is `fsync_mode=posix` and a page-cache-only write becomes NUL on power loss.
