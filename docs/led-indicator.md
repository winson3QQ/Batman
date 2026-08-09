# A two-LED field indicator for a HaLow mesh node

Once a node is in a case on a pole, there is no laptop, no web UI and no SSH. The
only bandwidth you have left is two LEDs the Raspberry Pi already has. This is a
definition of what they mean, and a small daemon that drives them.

Scripts: [`scripts/meshled`](../scripts/meshled), [`scripts/meshled.init`](../scripts/meshled.init).

## The rule

> **Solid = good. Faster blink = worse. Red is the system, green is HaLow.**

The two LEDs are layered, not parallel. Red covers everything that must be true
before the radio is even worth looking at — boot, filesystem, services,
configuration, power. Green covers the HaLow link. **Green stays dark until red
says OK**, so there is never a green pattern to interpret while the foundation is
broken.

Frequency is monotonic in severity, with no exceptions:

```
solid   →  0.2 Hz  →  1 Hz  →  2.5 Hz  →  5 Hz
good                                       worst
```

## Red (PWR) — the system layer

| State | Pattern | Timing | Meaning | Action |
|---|---|---|---|---|
| **OK** | **solid** | — | every check passes | read the green LED |
| **UNMANAGED** | 100 ms dip every 5 s | `4900 / 100` | `meshled` installed but not driving the LEDs | LEDs are not trustworthy; SSH in |
| **BOOTING** | 1 Hz | `500 / 500` | uptime < 90 s and checks not yet passing | wait |
| **FAULT** | 2.5 Hz | `200 / 200` | uptime > 90 s and a check still failing | `meshled status` |
| **UNDERVOLT** | 5 Hz | `100 / 100` | supply voltage sagged (**latched**) | replace PSU or cable |

`UNDERVOLT` overrides everything else and is **latched**. Either bit 0 (right now)
or bit 16 (has happened since boot) of `vcgencmd get_throttled` arms it, and it
stays armed until `meshled clear` or a reboot. A brown-out lasting one transmit
burst is exactly the kind of fault that is invisible by the time you SSH in, so it
is deliberately sticky rather than momentary.

`UNMANAGED` is the **boot default**, installed as a uci `config led` section so
`/etc/init.d/led` applies it early, long before `meshled` starts at `START=99`.
`meshled` only replaces it with solid once every check passes, and on exit it
deliberately restores it rather than handing the LED back to the stock
`default-on` trigger.

That last detail is the point of the state: **solid red means one thing and only
one thing — `meshled` is running and says the system is healthy.** A stopped or
crashed daemon can never look like a healthy system.

## Green (ACT) — the HaLow layer

| State | Pattern | Timing | Meaning | Action |
|---|---|---|---|---|
| **LINKED** | **solid** | — | connected, throughput above threshold | done |
| **WEAK** | blip every 2 s | `100 / 1900` | connected, throughput below threshold | move / aim the antenna |
| **NO_BATMAN** | 1 Hz | `500 / 500` | 802.11s peered but batman-adv sees no neighbour | **stop moving** — fix the config |
| **ALONE** | 2.5 Hz | `200 / 200` | radio fine, nobody answering | move, or go power up the other node |
| **RF_DEAD** | 5 Hz | `100 / 100` | the radio itself is not working | check SPI, firmware, module power |
| **DARK** | off | — | red is not OK yet | read the red LED |

`WEAK` and `NO_BATMAN` are close in frequency, so they are separated by **duty
cycle** instead: `WEAK` is a 5 % blip that reads as an occasional wink, while
`NO_BATMAN` is a 50 % square wave that reads as a steady pulse. Frequency alone is
not reliably readable below about a 2× ratio.

### Why `NO_BATMAN` deserves its own state

It is the failure that wastes the most time in the field, because it looks like
success at the layer you can check without tools:

```sh
iw dev wlan0 station dump | grep -c ^Station   # 1  <- peered
batctl n                                       # empty <- no batman neighbour
ping <the other node>                          # fails
```

802.11s peering means the radios found each other and SAE authentication passed —
so channel, bandwidth and mesh key are all correct. But batman-adv exchanges its
OGM routing frames as **multicast**, and if those do not get through, no route is
ever formed and no data moves.

Common causes: `wlan0` never added to `bat0`; the two nodes running different
routing algorithms (BATMAN_IV vs BATMAN_V — the OGM formats are mutually
unintelligible); the group key not agreeing, which kills multicast while unicast
keeps working; `mesh_fwding` disabled; `bat0` down on one side.

The reason it gets a distinct pattern is that **the correct response is the
opposite of the one for `ALONE`**. `ALONE` means walk around. `NO_BATMAN` means
walking around will never help — the problem is in `/etc/config`.

## Reading it

```
red not solid? ──> system-layer problem, ignore green entirely
                   dip = unmanaged │ 1 Hz = booting │ 2.5 Hz = fault │ 5 Hz = power
red solid ─────> read green
                   solid ✅ │ blip = weak │ 1 Hz = misconfigured │ 2.5 Hz = alone │ 5 Hz = radio dead
```

Target state: **both LEDs solid.**

### One impossible combination

```
🔴 solid  +  🟢 dark
```

cannot occur: green is only `DARK` when red is *not* `OK`. If you see it, nothing
is driving the LEDs at all — red is the stock `default-on` trigger and green is
the stock `none`/0. In other words, **`meshled` is not installed on this node.**

This matters because a node with nothing installed otherwise looks exactly like a
healthy one: stock red is solid, and solid red is our "everything is fine". The
`UNMANAGED` dip does *not* catch this case — that pattern comes from the uci
section, which is missing too when nothing was installed. The contradiction is
what catches it.

## Power-on self test

Watching a boot does **not** work as a way of telling an equipped node from a bare
one, which is worth stating because it sounds like it should. Measured on a real
boot:

```
14:54:31  /etc/rc.d/S96led: setting up led PWR unmanaged
14:54:32  meshled: OK RF_DEAD
```

`UNMANAGED` exists for about **one second** before the daemon overrides it, and
the pattern is lit 98 % of that time. The odds of the 100 ms dip landing inside
that window are roughly one in five, and it is a single brief flicker even then.
From the outside, red is simply solid from power-on to ready — indistinguishable
from a node with nothing installed.

So `meshled` does a deliberate self test on startup instead, the way a car
dashboard lights every warning lamp for a moment:

```
1 s   red off,   green off      <- red fully dark is impossible in any live state
1 s   red solid, green solid
      -> live state
```

Red going dark and coming back is unambiguous: none of the five live red states is
"off", so a node that does this has `meshled` running. It also verifies both LEDs
still work. Measured cost is about 2.2 s of delayed indication, once, at boot.

`sleep` in this busybox takes whole seconds only, which is why the phases are 1 s
each rather than something tighter.

## What "system OK" actually checks

| Group | Check | Failure tag |
|---|---|---|
| health | `/` is a writable overlay | `rootfs-ro` |
| | `/overlay` exists, below 90 % full | `no-overlay` / `overlay-full` |
| | clock year ≥ 2020 | `clock` |
| network | `br-ahwlan` has an IPv4 address | `no-ip` |
| radio | `wlan0` exists | `no-wlan0` |
| | `batman_adv` loaded, `bat0` exists | `no-batman` / `no-bat0` |
| services | `openmanetd`, `netifd`, `dropbear`, `wpad` running | `svc:<name>` |
| config | `wireless.default_radio3.mesh_id` set | `no-mesh-id` |
| | `radio3` not disabled | `radio-disabled` |
| | hostname is not the factory default | `default-hostname` |

Failure tags go to `/tmp/meshled.state`, to syslog, and to `meshled status`.

> **Do not test for a `morse_spi` module.** OpenMANET compiles SPI support into a
> single `morse` module; there is no separate `morse_spi`, so that check reports a
> failure on a perfectly healthy node. The meaningful test that the driver probed
> is whether the `wlan0` netdev exists.

There is no "wizard completed" flag anywhere in uci, so two proxies stand in for
it: `mesh_id` being set, and the hostname having been changed away from the
factory default. Neither is true unless somebody configured the node.

## Cost

Patterns are produced by the kernel `timer` LED trigger, so the daemon writes
sysfs only when the state actually changes and sleeps the rest of the time.
Measured CPU use on an idle Pi 4: **0 %**.

The trigger is also why `UNMANAGED` is not a liveness heartbeat. The kernel keeps
oscillating whether or not the daemon is alive, so the pattern proves that
`meshled` configured the LED at some point since boot — not that it is running
right now. True liveness would need the script itself to toggle `brightness`, and
this busybox has neither `usleep` nor fractional `sleep`, and no `oneshot` LED
trigger compiled in. Liveness is left to procd's `respawn` and to `meshled status`.

## Install

```sh
scp scripts/meshled      root@node:/usr/bin/meshled
scp scripts/meshled.init root@node:/etc/init.d/meshled
ssh root@node 'chmod +x /usr/bin/meshled /etc/init.d/meshled'

ssh root@node '
  uci set system.led_pwr_unmanaged=led
  uci set system.led_pwr_unmanaged.name="PWR unmanaged"
  uci set system.led_pwr_unmanaged.sysfs="PWR"
  uci set system.led_pwr_unmanaged.trigger="timer"
  uci set system.led_pwr_unmanaged.delayon="4900"
  uci set system.led_pwr_unmanaged.delayoff="100"
  uci set system.led_pwr_unmanaged.default="1"
  uci commit system
  /etc/init.d/led restart
  /etc/init.d/meshled enable
  /etc/init.d/meshled start'
```

On a Pi 4 running OpenMANET, `ACT` is free — this build gives SD-card activity its
own `mmc0` LED, so taking `ACT` over costs nothing. `PWR` is taken over from
`default-on`; the firmware's undervoltage warning is not lost, because `meshled`
reads `get_throttled` itself and re-encodes it as the 5 Hz pattern.

If the LEDs are not visible once the node is in a case, everything above still
holds — only the `LED_RED` / `LED_GRN` paths at the top of the script change.
GPIO 6, 13, 16, 17, 19, 20, 21, 22, 23, 24, 26 and 27 are unused by the WM1302
HAT and are available for panel LEDs.

## Verify

```sh
meshled status    # every check, and why the current state was chosen
meshled test      # walks all eight patterns, 12 s each, so you can learn them
meshled clear     # reset the undervoltage latch
```

## Not yet calibrated

`TPUT_WEAK` (default `2.0` Mbit/s) is the `LINKED` / `WEAK` boundary and is a
**placeholder**. It needs a real measurement from `batctl n` with a second node on
the air. S1G at 2 MHz bandwidth plausibly lands somewhere in the 1–5 Mbit/s range,
but that is an expectation, not a measurement.
