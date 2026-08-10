# Cloning a configured node onto a fresh one, without the setup wizard

The second node in a mesh has to match the first in a dozen places, and a setup
wizard is a poor tool for that: every value is retyped by hand, a mismatch in any
one of them produces a mesh that half-works, and nothing about the result is
reproducible. Copying the first node's configuration is both exact and repeatable
— once you know which parts must *not* be copied.

This was done on OpenMANET 1.7.0, but nothing here is OpenMANET-specific. It
applies to any OpenWrt device you want to replicate.

## The wizard's output is entirely in uci

Worth checking before committing to this approach. On OpenMANET:

```sh
ls /etc/openmanet/          # empty
ls /etc/uci-defaults/       # empty
uci show openmanetd         # dhcpconfigured='0'  <- the wizard flips this to 1
```

No certificates, no state files, no database. The wizard writes uci and nothing
else, so reproducing its uci output reproduces the wizard.

If a device keeps wizard state outside uci, this method silently produces a node
that looks configured and isn't. Check first.

## Convert `uci show` back into config files

Replaying a dump as `uci set` commands does not work well. Anonymous sections are
addressed by index (`firewall.@rule[9]`), so the commands only land correctly if
the target already has the same sections in the same order — which a fresh device
does not. Writing `/etc/config/<pkg>` directly sidesteps ordering entirely.

[`scripts/uci-dump-to-config.py`](../scripts/uci-dump-to-config.py) does the
conversion:

```sh
ssh root@node1 uci show > node1.txt
python3 uci-dump-to-config.py node1.txt ./out network wireless dhcp firewall system mesh11sd
```

**Verify the round trip before trusting it.** Copy the generated files somewhere
harmless on the target and read them back with uci's alternate config dir:

```sh
scp out/* root@node2:/tmp/verify/
ssh root@node2 'for p in network wireless dhcp firewall system mesh11sd; do
                  uci -c /tmp/verify show $p; done' > roundtrip.txt
diff <(sort node1.txt | grep -E '^(network|wireless|...)\.') <(sort roundtrip.txt)
```

280 lines in, 280 lines out, no differences. A converter that loses a `list`
somewhere will show up here rather than as a mesh that mysteriously won't form.

`uci -c` is also what makes this safe: the whole config can be staged and
inspected in `/tmp` before anything touches `/etc/config`.

## What must not be copied

Seven values. Copying any of them produces two devices that conflict rather than
cooperate.

| Setting | Why it must differ |
|---|---|
| `system.@system[0].hostname` | mDNS name collision — `.local` stops resolving for both |
| `network.<lan>.ipaddr` | IP conflict |
| `network.@device[0].macaddr` (the bridge) | **Two bridges with one MAC on a shared L2 breaks forwarding** |
| `network.globals.ula_prefix` | IPv6 address collision |
| `wireless.radioN.path` | **See below — this one is easy to miss** |
| `system.@system[0].default_wifi_key` | Per-device factory value; harmless but confusing |
| SSIDs derived from the chip ID | Cosmetic |

### The `path` trap

`wireless.radioN.path` pins a radio to a physical device location, and for
anything on USB that location includes the **port**:

```
node 1:  .../usb1/1-1/1-1.2/1-1.2:1.0      <- dongle in one port
node 2:  .../usb1/1-1/1-1.4/1-1.4:1.0      <- same dongle, different port
```

Copy node 1's value and node 2's radio matches no device at all. The section
stays in the config, looks entirely correct, and silently does nothing.

Onboard radios are safe to copy — SDIO and SPI paths are fixed by the board:

```
radio1 (5 GHz, brcmfmac)  platform/soc/fe300000.mmcnr/...     identical
radio3 (S1G, MM6108 SPI)  platform/soc/fe204000.spi/...       identical
```

So: copy paths for onboard radios, keep the target's own for anything on USB.

### Addresses that get reassigned anyway

On OpenMANET, `openmanetd` picks a fresh random `10.41.x.y` at every boot, so
whatever you set for `ipaddr` is only an initial value. The practical consequence
is that **you should never record a node's IP anywhere** — use `<hostname>.local`,
which is stable across reboots. Changing the hostname needs an avahi restart to
take effect:

```sh
uci set system.@system[0].hostname='manet02'; uci commit system
/etc/init.d/system reload
/etc/init.d/avahi-daemon restart      # else mDNS keeps advertising the old name
```

## What the diff caught that a wizard would not have

Two settings differed between a freshly flashed node and a configured one, and
neither is something you would think to check:

**`mesh11sd.mesh_params.mesh_fwding`** — `1` out of the box, `0` on a configured
node. With batman-adv layered over 802.11s, batman does the forwarding; leaving
the 802.11s layer forwarding as well is exactly the kind of mismatch that produces
peered radios with no batman neighbours.

**`network.bat0.routing_algo`** — must match on both nodes. BATMAN_IV and
BATMAN_V OGM formats are mutually unintelligible, so a mismatch gives you two
nodes that pair at 802.11s and never form a route.

Both are invisible in a wizard, which asks about SSIDs and passwords and nothing
about the routing layer.

## Backups are not a substitute for reading the live device

The configuration dump used as the source here was several days old, and node 1
had been edited since. The drift was small and entirely in the 5 GHz AP — a
changed SSID, a changed key, an added `txpower` — but it was enough that a
comparison table built from the backup asserted the two nodes' APs were identical
when they were not.

Diff the **live** device before drawing conclusions from a saved dump. The mesh
parameters had not drifted, so the clone was still correct, but that was luck
rather than method.

## Order of operations

The SSH key goes in first, before anything can set a password:

```sh
# 1. fresh boot, root has no password
cat ~/.ssh/id_ed25519.pub | ssh root@10.41.254.1 \
 'mkdir -p /etc/dropbear /root/.ssh
  tee -a /etc/dropbear/authorized_keys >> /root/.ssh/authorized_keys
  chmod 600 /etc/dropbear/authorized_keys /root/.ssh/authorized_keys'

# 2. stage the config and check it
scp out/* root@10.41.254.1:/tmp/verify/
ssh root@10.41.254.1 'uci -c /tmp/verify set system.@system[0].hostname=manet02
                      ...one line per per-node override...
                      uci -c /tmp/verify commit'

# 3. install
ssh root@10.41.254.1 'cp -a /etc/config /root/config-factory-backup
                      cp /tmp/verify/* /etc/config/
                      uci set openmanetd.config.dhcpconfigured=1
                      uci commit
                      sync'

# 4. reboot, then reach it by name
ssh root@manet02.local
```

Keep `/root/config-factory-backup` — it is the only copy of the factory config
once `/etc/config` is overwritten, and it survives on the overlay.

`sync` before any power cut. This overlay is f2fs with `fsync_mode=posix`; a file
written over SSH sits in page cache, and pulling the plug can commit the inode
without the data. See [`flashing-and-recovery.md`](flashing-and-recovery.md).

## Result

Node 2 came up matching node 1 on all nine parameters that decide whether a mesh
forms — `mesh_id`, key, encryption, `beacon_int`, channel, country,
`routing_algo`, `mesh_fwding`, `network` — with the seven per-node values
correctly distinct, and the radio confirming the intended RF setup:

```
Operating Frequency: 923000 kHz     Operating BW: 2 MHz    Primary BW: 1 MHz
wlan0  type mesh point   txpower 27.00 dBm
```

No wizard was run.
