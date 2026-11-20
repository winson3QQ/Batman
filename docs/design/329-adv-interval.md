# #329 A4 — the node advertises every 100–150 ms instead of every 1.28 s

Status: v1, in review. One change: two keys in the image's `/etc/bluetooth/main.conf` (firmware repo,
`package/batman/batman-ble/files/main.conf`). No app, provd, helper or protocol change. One harness judge
(separate PR, first, per #290).

Closes #329 line 194 ("about 1 in 10 BLE connects is not received by the node") and the "connect itself
sometimes takes 4.2 s" half of line 256.

## 0. Reproduced on the real system (2026-11-20, phone S20, nodes 04 …7D2C and 02 …880C on 1.5.14-wsl.32)

Evidence files: `Desktop\Batman\a4\` (`a4-c1.logcat` … `a4-c4.logcat`, `br.zip` / `br2.zip` with the phone's
`btsnoop_hci.log`, `a4-btmon-04-default.txt`); scripts `a4cycle.sh` (no taps: background 8 s → launch → 30 s,
N times; the home round connects to both nodes) and `snoop.py`; #329 `issuecomment-7035194695`.

| What | Seen |
|---|---|
| Phone air log, 448 LE create-connection commands | create → complete clusters at 1.2–1.3 s (138), 2.5–2.6 s (94), 3.8–3.9 s (27); 64 of 448 end with status 0x02 after the 5 s timeout. The nodes' advertising reports arrive 1.28 / 2.56 / 3.84 s apart. |
| 04's own HCI traffic (btmon, the harness's copy, passive) | `< HCI Command: LE Set Advert.. (0x08\|0x0006) plen 15` / `Min advertising interval: 1280.000 msec (0x0800)` / `Max advertising interval: 1280.000 msec (0x0800)`; the MGMT Add Extended Advertising Parameters (0x0054) before it carries `Min/Max advertising interval: 0.000 msec (0x0000)` = "use the default". |
| App log, 25 cycles, both nodes untouched | 04: connect median 1631 ms, p90 2913, max 4211, 1 of 26 failed. |
| **Flip test**: only 04's interval changed to 100–150 ms (bind-mounted `main.conf` with the two keys of §1, bluetoothd restarted; 02 untouched as the control, same 25 cycles) | 04: median **510 ms**, p90 664, max 785, **0 of 25 failed**; in the phone air log 04's connects complete in 0.0–0.3 s. 02 in the same window: median 1642 ms, 6 of 30 failed. |
| 04 restored (interval written back to 0x0800, then the image's file; md5 `41c7ab5d…`, no bind mount) | 6 cycles: 1374–4919 ms, 1 failed: the old behaviour is back. |

Cause, from source:
- provd registers its advertisement without an interval (`feed/batman-prov/src/cmd/batman-provd/bluez.go:318`:
  `Type`, `ServiceUUIDs`, `Discoverable`, `ManufacturerData` only). BlueZ's `MinInterval` / `MaxInterval`
  advertisement properties are experimental (`src/advertising.c:1127`); bluetoothd runs without `-E`.
- The kernel then uses the controller default: `hdev->le_adv_min_interval = 0x0800; le_adv_max_interval = 0x0800`
  (`net/bluetooth/hci_core.c:2470-2471`, Linux 6.6.138), copied into the instance when it is added
  (`mgmt.c:8739-8740`) and sent at `hci_sync.c:1896-1901`.
- A phone that scans with a duty cycle below 100 % needs several advertisements to catch one; at one per 1.28 s
  that is 1.3 / 2.6 / 3.8 s, and past 5 s the phone gives up (status 0x02; Android reports 133).
  ⚠️ The exact scan window of the S20 was not read; the 1.28 s steps and the flip test are the evidence.

## 1. The change

`package/batman/batman-ble/files/main.conf` (firmware repo), appended; `PKG_RELEASE` 3 → 4:

```
# Batman #329: the kernel default is one advertisement per 1.28 s (hci_core.c le_adv_min/max_interval = 0x0800);
# a phone then needs 1.3-3.8 s to connect and gives up about 1 time in 10. Unit 0.625 ms: 100-150 ms.
# bluetoothd sends these to the kernel when it takes the adapter (adapter.c load_defaults); an advertisement
# registered without an interval (provd) uses them.
[LE]
MinAdvertisementInterval = 0x00A0
MaxAdvertisementInterval = 0x00F0
```

How it takes effect (all read from source, and seen in the flip test):
- `src/main.c:570-579` parses the two keys (accepted range 0x0020–0x4000; out of range → a warning, key ignored).
- `adapter.c:9387` `load_defaults()` runs each time bluetoothd takes an adapter (start, restart, the adapter
  re-appearing) and sends `MGMT_OP_SET_DEF_SYSTEM_CONFIG` with TLV 0x000a / 0x000b (`adapter.c:4873-4891`).
  Needs no `-E`.
- Kernel: `mgmt_config.c:253-256` stores them in `hdev`; the next advertisement added without an interval gets
  them. provd registers after bluetoothd is up, and again after every connection, so no ordering step is added.

Why 100–150 ms: it is the value measured in §0. A larger one was not measured, and the cost of this one is small
(§6); 20–60 ms would add airtime for a gain the phone's own scan duty cycle hides (connects already complete in
0.0–0.3 s). Why `main.conf` and not provd: the interval is adapter policy like the other keys in that file, and the
per-advertisement properties need bluetoothd's experimental mode, which would switch on unrelated experimental
interfaces.

Not changed: the advertisement's content, the address / identifier rotation (900 s), the two-connection cap,
withdrawal while a phone is connected, the app's timeouts.

## 2. Ownership

| Resource | Owner (only writer) | Readers |
|---|---|---|
| `/etc/bluetooth/main.conf` | the image (`batman-ble`; not a conffile, `254-stage1-impl.md` §3) | bluetoothd at start |
| `hdev->le_adv_min/max_interval` (kernel, RAM) | bluetoothd (`load_defaults`), once per adapter take-over | kernel, when an advertisement without an interval is added |
| The advertisement instance and its registration | provd (unchanged) | BlueZ / kernel |

No second writer is added. root running `bluetoothctl mgmt.*` by hand stays what `254-stage1-impl.md` §3 calls it:
an operating mistake, undone by the next bluetoothd restart **only for values present in `main.conf`** — which
after this change includes the interval.

## 3. Contracts

| Interface | Writer → reader | Valid | Missing / malformed |
|---|---|---|---|
| `[LE] MinAdvertisementInterval`, `MaxAdvertisementInterval` in `main.conf` | image → bluetoothd | hex or decimal, 0x0020–0x4000, unit 0.625 ms, min ≤ max | Missing or out of range: BlueZ ignores the key (`main.c:459/465` warning) and the kernel keeps 0x0800 = today's behaviour (slow, still works). **min > max is not checked** by BlueZ or by this kernel (`mgmt_config.c:160-190` checks only the TLV length): the controller would refuse LE Set Advertising Parameters and the node would not advertise. Guarded by the fixed values in the image and by test T1 (and every BLE unit of the suite, which could not connect). |
| TLV 0x000a / 0x000b of Set Default System Configuration | bluetoothd → kernel | kernel ≥ 5.9 (`KERNEL_SET_SYSTEM_CONFIG`); 6.6.138 here | Kernel without it: `load_defaults` returns early (`adapter.c:4878`), 0x0800 stays. |
| Who can write | root only: the file is in the read-only image (root can shadow it in the overlay); org.bluez on D-Bus is denied to everyone but root (`bluetooth.conf`); mgmt needs CAP_NET_ADMIN | | |

## 4. Lifecycle

"Today" = 1.28 s everywhere.

| Path | After the change | Proof |
|---|---|---|
| First boot of a new image (flash or sysupgrade; both reboot) | bluetoothd starts, sends the keys, provd registers: 100–150 ms from the first advertisement | T1 on the shipped image |
| Start / clean stop / restart of bluetoothd (respawn after a crash too) | `load_defaults` runs again; provd re-registers when BlueZ re-appears (unchanged) | T1 runs inside unit `dep-restart`'s btmon spans as well (every 0x0006 block in the run is judged) |
| provd restart, a connection ending, the 900 s rotation | the kernel value is untouched; the new registration reads it | T1 (the `adv-data` and `rpa` spans contain re-registrations) |
| hci0 re-appearing (UART re-attach, #305) | new `hdev` starts at 0x0800; bluetoothd takes the adapter and sends the keys before provd can register (provd waits for the adapter object) | ⚠️ source only (`adapter.c:9387`); `bt-uart-305` units run with T1 active, so a wrong value there fails T1 |
| Upgrade wsl.32 → new image | reboot → new file → new value | T1 after the OTA |
| Rollback / downgrade to an image without the keys | the slot switch is a reboot: the kernel starts at 0x0800 and the old file sends nothing → 1.28 s, exactly today. Nothing is stored outside RAM and the image. | T1's negative control (wsl.32 FAILs T1) |
| Crash, crash loop, power loss | no state besides the image file | — |
| Restored backup (`sysupgrade -r`) | no bluetooth conffiles; cannot change the file (`254-stage1-impl.md` L64) | existing `ble-privacy-254` |
| bcm2711 (Pi 4; CM4 has the same CYW43455) / bcm2710 (Pi 3A+, not supported for now) | same package, same kernel source (`hci_core.c:2470`), same value | T1 runs on whatever board the suite runs on; Pi 3 not run |

A note for whoever tests by hand: removing the keys and restarting bluetoothd on a **running** node does not bring
back 1.28 s (`load_defaults` sends nothing when no key is set, the kernel keeps the last value until reboot). This
cost one wrong "restored" on 04 during §0. It does not affect any path above, all of which reboot.

## 5. Assumptions and their evidence

| Relied on | Evidence |
|---|---|
| The keys reach the kernel without experimental mode | Flip test §0 (bluetoothd command line unchanged: `-n --noplugin=…`); `adapter.c:4873-4891` |
| An advertisement registered with interval 0 uses the adapter default | btmon §0 (0x0054 with 0x0000 → HCI 0x0800); `mgmt.c:8739-8740` |
| The controller (CYW43455) accepts 100–150 ms for ADV_IND and keeps advertising | Flip test: 25 cycles, 0 failures, air log 0.0–0.3 s |
| The node uses legacy advertising commands (0x08\|0x0006), not extended | btmon §0. T1 also accepts the extended command (0x08\|0x0036) so a kernel change does not blind it |
| While a phone is connected the node does not advertise | `bluez.go:354`, `:521` ("a connection withdraws the advertisement") |
| The phone AP is on 5 GHz | `uci get wireless.radio0.band` = `5g`, channel 36, on 04 and 02 |

## 6. Cost and what is not measured

- Airtime ⚠️ computed, not measured: one ADV_IND with a 31-byte payload is about 0.38 ms on each of 3 channels,
  1.1 ms per event; every 125 ms that is about 0.9 % of the three advertising channels per node, and only while no
  phone is connected. Ten nodes in one room: about 9 %.
- Power ⚠️ estimated: under 1 % transmit duty at a few dBm is in the mW range against a node that draws watts.
- Wi-Fi on the same chip ❌ not measured: the phone AP is on 5 GHz and BLE on 2.4 GHz, and the node does not
  advertise while a phone is connected over BLE, so the expected effect is small. To be measured on site (phone
  on the node's Wi-Fi, throughput with the image before and after): on the user's on-site list. If it shows a
  loss, the fallback is a larger value in the same two keys.
- HaLow (sub-GHz, separate radio) and LoRa are not involved.

## 7. Security

- Assets / actors: availability of the BLE path; the node's observability.
  - Remote attacker: the node already advertises continuously and its 5 GHz AP beacons about every 100 ms; ten
    times more BLE advertisements make it no more identifiable (same resolvable address and identifier rotation,
    same content). A direction finder gets more BLE packets per second from a node with no phone connected; the AP
    beacons already give that. Connecting is as possible as before (the attacker's scanner can be 100 % duty), the
    two-connection cap and all authentication are unchanged.
  - Local unprivileged process / compromised tenant: no new input. It cannot write the file, the D-Bus policy
    denies org.bluez, mgmt needs CAP_NET_ADMIN.
  - Physical capture, supply chain: nothing new; the file is part of the image like the rest of `main.conf`.
  - Our mistakes: a typo that makes min > max would stop advertising (§3) → T1 and every BLE unit fail before a
    release.
- Attack-surface delta: none (two constants in a root-owned file).
- Privilege, secrets: unchanged, none.
- Failure mode: a missing / ignored key falls back to 1.28 s. That is fail-open to today's behaviour, chosen
  because the alternative (no advertising) cuts the owner off from the node.
- Negative test: not applicable to an attack; the functional negative control is T1 on wsl.32.

## 8. Tests

**T1 (harness PR, first; in the regular suite).** `scripts/dv/prov-provd-254.sh` already records 04's HCI traffic
with btmon in the units `adv-data`, `rpa` and `dep-restart`. New judge `scripts/dv/advint-judge-329.sh`
(`ai_judge`, text on stdin, runs offline like `advid-judge-329.sh`):
- every `< HCI Command` block of opcode `0x08|0x0006` or `0x08|0x0036` in the span has
  `Min advertising interval: 100.000 msec (0x00a0)` and `Max advertising interval: 150.000 msec (0x00f0)`
  (for 0x0036: the same two values in its primary interval lines);
- no such block in the span = FAIL (nothing was checked);
- offline test in `scripts/test-dv-ble-254.sh` with the real capture `a4-btmon-04-default.txt` (must FAIL) and a
  capture from the new image (must PASS; added when the image exists — until then the PASS fixture is the same
  capture with the two lines edited, marked ⚠️ in the file).
- Negative control: wsl.32 FAILs with exactly `FAIL adv interval: 1280.000 / 1280.000 msec on 04 (<version>): an
  image without the interval`; that line goes into `known-failures.sh` with an expiry, removed by the pin PR.

**T2 (device, on the shipped image, both nodes).** `a4cycle.sh` 25 cycles + the phone air log:
- per node: connect median ≤ 800 ms, max ≤ 1500 ms, 0 failed attempts of 25; create → complete ≤ 0.5 s for
  every connect in the air log.
- Negative control: §0 (wsl.32: median 1631 / 1642 ms, failures 1 of 26 and 6 of 30).
- If a failure remains, it is reported ❓ with its air-log lines; line 194 is then not closed.

**T3.** The full daily-validation on the new image (the shipped artifact), as for every image.

**On site (user's list):** Wi-Fi throughput on the node's AP before / after (§6).

## 9. What comes after, and what this does not do

- `batman-ble` is to move from the firmware tree to the Batman feed (`254-stage1-impl.md` §4.6): the file moves
  as it is; this change is kept.
- CM4 (production board): same chip and package; T1 / T2 are run again there when the board exists.
- Not handled here: the 30 s wait on a remembered address (#329 line 221), the ~1 s pause every 5 min on home,
  the app's 5 s connect timeout and retry spacing (left as they are: with connects under 1 s they are no longer
  what the user waits for; revisited only if T2 shows failures).
