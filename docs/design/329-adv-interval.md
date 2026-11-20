# #329 A4 — the node advertises every 100–150 ms instead of every 1.28 s

Status: v2 (round-1 reviews `329-reviews/review-advint-r1-{A,B}.md` answered; changes listed in §10). One change:
two keys in the image's `/etc/bluetooth/main.conf` (firmware repo, `package/batman/batman-ble/files/main.conf`).
No app, provd, helper or protocol change. Harness judges in a separate PR, first (#290).

What it closes, and what it does not:
- Closes the "connect itself sometimes takes 4.2 s" half of #329 line 256, and the connects that end in the phone's
  5 s timeout.
- **Does not claim #329 line 194** ("about 1 in 10 BLE connects is not received by the node"). §0 shows two failure
  shapes; this change explains only the timeout shape. The fast shape is ❓ unattributed. Line 194 is closed only if
  T2 shows 0 fast failures in 100 attempts on each node; otherwise it stays open with T2's numbers.

Source citations are from the Pi 4 shipping tree: WSL `/home/yello/firmware-2710/build_dir/target-aarch64_cortex-a72_musl/`
`bluez-5.72` and `linux-bcm27xx_bcm2711/linux-6.6.138` (the a53 tree's bluez is unpatched; its lines are 4 lower).

## 0. Reproduced on the real system (2026-11-20, phone S20, nodes 04 …7D2C and 02 …880C on 1.5.14-wsl.32)

Evidence files: `Desktop\Batman\a4\` (`a4-c1.logcat` … `a4-c6.logcat`, `br.zip` / `br2.zip` with the phone's
`btsnoop_hci.log`, `a4-btmon-04-default.txt`); scripts `a4cycle.sh` (no taps: background 8 s → launch → 30 s,
N times; the home round connects to both nodes) and `snoop.py`; #329 `issuecomment-7035194695`.

| What | Seen |
|---|---|
| Phone air log, 448 LE create-connection commands | create → complete clusters at 1.2–1.3 s (138), 2.5–2.6 s (94), 3.8–3.9 s (27); 64 of 448 end with status 0x02 after the 5 s timeout. The nodes' advertising reports arrive 1.28 / 2.56 / 3.84 s apart. |
| 04's own HCI traffic (btmon, the harness's copy, passive) | `< HCI Command: LE Set Advert.. (0x08\|0x0006) plen 15` / `Min advertising interval: 1280.000 msec (0x0800)` / `Max advertising interval: 1280.000 msec (0x0800)` / `Type: Connectable undirected - ADV_IND (0x00)`; the MGMT Add Extended Advertising Parameters (0x0054) before it carries `Min/Max advertising interval: 0.000 msec (0x0000)` = "use the default". |
| App log c1, 25 cycles, both nodes untouched | 04: connect median 1631 ms, max 4211, 1 of 26 failed. 02: 4 of 29 failed. |
| **Flip test** c2: only 04's interval changed to 100–150 ms (bind-mounted `main.conf` with the two keys of §1, bluetoothd restarted; 02 untouched as the control, same 25 cycles) | 04: median **510 ms**, max 785, **0 of 25 failed**; in the phone air log 04's connects complete in 0.0–0.3 s. 02 in the same window: median 1642 ms, 6 of 30 failed. |
| c4, 04 restored (interval written back to 0x0800, then the image's file; md5 `41c7ab5d…`, no bind mount, no overlay copy of `main.conf`) | 04, 7 attempts: 2180, 1374, 1637, 2923, failed after 2462, 451, 4919 ms: the old behaviour is back. |

Failed attempts by shape (app log `BMAPP nl attempt … result=noResponse after N ms`; all six runs):

| Run | 04 | 02 |
|---|---|---|
| c1 (both default) | 1 of 26: fast (1150 ms) | 4 of 29: timeout ×2 (5026, 5028), fast ×2 (451, 1620) |
| c2 (04 at 100–150 ms) | 0 of 25 | 6 of 30: timeout ×5, fast ×1 (1496) |
| c3 (both default) | 0 of 6 | 1 of 7: fast (4154) |
| c4 (04 restored) | 1 of 7: fast (2462) | 1 of 7: fast (2866) |
| c5, c6 (both default) | 0 of 4 | 1 of 4: fast (656) |
| **Total** | 2 of 68 (0 timeouts, 2 fast) | 13 of 77 (**7 timeouts**, 6 fast) |

- Timeout shape (≥ 5.0 s; phone status 0x02 / `reason : 255`): 7, all on 02 at the default interval. Explained by
  the interval (below).
- Fast shape (0.45–4.2 s; six of the eight are `reason : 62` = HCI 0x3E "Connection Failed to be Established", i.e.
  the phone sent its connect request and the node's link layer did not answer): 8, on both nodes. ❓ Not attributed.
  04 at 100–150 ms had 0 in 25 attempts, at the default 2 in 43: too few to say the interval removes them.
- So the evidence that the change removes timeouts is the mechanism plus 04's air log (connects complete in
  0.0–0.3 s, far from 5 s); 04 itself never showed a timeout at the default in 43 attempts. T2 on 02 is the test.

Cause, from source:
- provd registers its advertisement without an interval (`feed/batman-prov/src/cmd/batman-provd/bluez.go:318`:
  `Type`, `ServiceUUIDs`, `Discoverable`, `ManufacturerData` only). BlueZ's `MinInterval` / `MaxInterval`
  advertisement properties are experimental (`src/advertising.c:1127-1129`, parsed at `:988-992`); bluetoothd runs
  without `-E` (`bluetoothd.init`: `-n --noplugin=hostname,autopair,battery,neard,sap`).
- The kernel then uses the adapter default: `hdev->le_adv_min_interval = 0x0800; le_adv_max_interval = 0x0800`
  (`net/bluetooth/hci_core.c:2470-2471`), copied into the instance when it is added without the intervals flag
  (`mgmt.c:8929-8935`, `add_ext_adv_params`) and sent at `hci_sync.c:1900-1906` / `:1923-1929`.
- A phone that scans with a duty cycle below 100 % needs several advertisements to catch one; at one per 1.28 s
  that is 1.3 / 2.6 / 3.8 s, and past 5 s the phone gives up (status 0x02; Android reports 133).
  ⚠️ The exact scan window of the S20 was not read; the 1.28 s steps and the flip test are the evidence.

## 1. The change

`package/batman/batman-ble/files/main.conf` (firmware repo), appended; `PKG_RELEASE` 3 → 4:

```
# Batman #329: the kernel default is one advertisement per 1.28 s (hci_core.c le_adv_min/max_interval = 0x0800);
# a phone then needs 1.3-3.8 s to connect and sometimes runs into its 5 s timeout. Unit 0.625 ms: 100-150 ms.
# bluetoothd sends these to the kernel when it takes the adapter (adapter.c load_defaults); an advertisement
# registered without an interval (provd) uses them.
[LE]
MinAdvertisementInterval = 0x00A0
MaxAdvertisementInterval = 0x00F0
```

How it takes effect (read from source, and seen in the flip test):
- `src/main.c:570-579` parses the two keys (accepted range 0x0020–0x4000; out of range → a warning, key ignored,
  `main.c:459/465`).
- `adapter.c:9383`: `adapter_register` calls `load_defaults()` (its only call site), i.e. each time bluetoothd
  takes an adapter: its own start or restart, and the adapter index re-appearing. `load_defaults`
  (`adapter.c:4869-4896`) sends `MGMT_OP_SET_DEF_SYSTEM_CONFIG` with TLV 0x000a / 0x000b. Needs no `-E`.
- Kernel: `mgmt_config.c:253-256` stores them in `hdev`; the next advertisement added without an interval gets
  them. provd registers after bluetoothd is up, and again after every connection, so no ordering step is added.

Why 100–150 ms: it is the value measured in §0, and it is the kernel's own "fast advertising" pair
(`DISCOV_LE_FAST_ADV_INT_MIN/MAX`, `hci_core.h:2259-2260`). A larger one was not measured, and the cost of this one
is small (§6); 20–60 ms would add airtime for a gain the phone's own scan duty cycle hides (connects already
complete in 0.0–0.3 s). Why `main.conf` and not provd: the interval is adapter policy like the other keys in that
file, and the per-advertisement properties need bluetoothd's experimental mode, which would switch on unrelated
experimental interfaces.

Not changed: the advertisement's content, the address / identifier rotation (900 s), the two-connection cap,
withdrawal while a phone is connected, the app's timeouts.

## 2. Ownership

| Resource | Owner (only writer) | Readers |
|---|---|---|
| `/etc/bluetooth/main.conf` | the image (`batman-ble`; not a conffile, `254-stage1-impl.md` §3) | bluetoothd at start |
| `hdev->le_adv_min/max_interval` (kernel, RAM) | bluetoothd (`load_defaults`), once per adapter take-over | kernel, when an advertisement without an interval is added |
| The advertisement instance and its registration | provd (unchanged) | BlueZ / kernel |

No second writer is added. `batman-provhelper` is a second privileged mgmt user on the node; it does not write
this value (it sends no Set Default System Configuration). root running `bluetoothctl mgmt.*` by hand stays what
`254-stage1-impl.md` §3 calls it: an operating mistake, undone by the next bluetoothd restart **only for values
present in `main.conf`** — which after this change includes the interval.

## 3. Contracts

| Interface | Writer → reader | Valid | Missing / malformed |
|---|---|---|---|
| `[LE] MinAdvertisementInterval`, `MaxAdvertisementInterval` in `main.conf` | image → bluetoothd | hex or decimal, 0x0020–0x4000, unit 0.625 ms, min ≤ max | Missing or out of range: BlueZ ignores the key and the kernel keeps 0x0800 = today's behaviour (slow, still works). **min > max is not checked** by BlueZ or by this kernel (`mgmt_config.c:140-211` checks only each TLV's length). ⚠️ What the controller does with min > max was not tried (expected: it refuses LE Set Advertising Parameters). Guarded by the fixed values in the image and by T1a, which accepts only 0x00a0 / 0x00f0. |
| TLV 0x000a / 0x000b of Set Default System Configuration | bluetoothd → kernel | kernel ≥ 5.9 (`KERNEL_SET_SYSTEM_CONFIG`); 6.6.138 here | Kernel without it: `load_defaults` returns early (`adapter.c:4874-4876`), 0x0800 stays. |
| Who can write the interval | root: the file is in the read-only image (root can shadow it in the overlay); mgmt needs CAP_NET_ADMIN. User `provd` may call org.bluez on D-Bus (`bluetooth.conf`: RegisterAdvertisement and others) but the interval properties are ignored without `-E`, so a compromised provd cannot change the interval. It can register further advertisements, as today. | | |

## 4. Lifecycle

"Today" = 1.28 s everywhere.

| Path | After the change | Proof |
|---|---|---|
| First boot of a new image (flash or sysupgrade; both reboot) | bluetoothd starts, sends the keys, provd registers: 100–150 ms from the first advertisement | T1a in `prov-boot-provd-254` (its capture starts by restarting provd, not at boot; the boot order itself is ⚠️ source only: provd can register only after bluetoothd has registered the adapter object, and `load_defaults` runs inside that registration) |
| Restart of bluetoothd (clean, killed, D-Bus restart) | provd re-registers when BlueZ re-appears (unchanged); the kernel value is still there, and `load_defaults` writes it again | T1a in `prov-dep-restart-254` (arms `dep-bluetoothd`, `dep-bluetoothd-kill`, `dep-dbus`). This proves the advertisement after the restart is at 100–150 ms; it cannot prove the re-send (the value survives in `hdev`) — the next row does |
| hci0 re-appearing (UART re-attach, #305) | new `hdev` starts at 0x0800; bluetoothd takes the adapter and sends the keys | **T1b** in `bt-uart-rebind-305` (10 unbind/bind): the kernel value is read back after each rebind |
| provd restart, a connection ending, the 900 s rotation | the kernel value is untouched; the new registration reads it | T1a (`adv-data` arm restarts provd). Rotation: same code path as any registration; the `rpa` unit's capture filter drops the parameters command and is not changed |
| Upgrade wsl.32 → new image | reboot → new file → new value | T1a / T1b after the OTA |
| Rollback / downgrade to an image without the keys | the slot switch is a reboot: the kernel starts at 0x0800 and the old file sends nothing → 1.28 s, exactly today. Nothing is stored outside RAM and the image. | ⚠️ source only for the switch itself; wsl.32 giving 1280 ms in T1a / T1b shows what an image without the keys does |
| Crash, crash loop, power loss | no state besides the image file | — |
| Restored backup (`sysupgrade -r`) | no bluetooth conffiles; cannot change the file (`254-stage1-impl.md` L64) | existing `ble-privacy-254` |
| bcm2711 (Pi 4; CM4 has the same CYW43455) / bcm2710 (Pi 3A+, not supported for now) | same package, same kernel source, same value | T1 runs on whatever board the suite runs on; Pi 3 not run |

A note for whoever tests by hand: removing the keys and restarting bluetoothd on a **running** node does not bring
back 1.28 s (`load_defaults` sends nothing when no key is set, the kernel keeps the last value until reboot). This
cost one wrong "restored" on 04 during §0. It does not affect any path above, all of which reboot.

## 5. Assumptions and their evidence

| Relied on | Evidence |
|---|---|
| The keys reach the kernel without experimental mode | Flip test §0 (bluetoothd command line unchanged); `adapter.c:4869-4896` |
| An advertisement registered with interval 0 uses the adapter default | btmon §0 (0x0054 with 0x0000 → HCI 0x0800); `mgmt.c:8929-8935` |
| The controller (CYW43455) accepts 100–150 ms for ADV_IND and keeps advertising | Flip test: 25 cycles, 0 failures, air log 0.0–0.3 s |
| The node uses legacy advertising commands (0x08\|0x0006), not extended | btmon §0. T1a also reads the extended command (0x08\|0x0036) so a kernel change does not blind it; no real 0x0036 capture can be made on this kernel, its fixture is hand-written and marked so |
| A 100 / 150 ms line in an HCI block means our keys worked | Only for a connectable advertisement: for a non-connectable, non-discoverable one the kernel itself forces 0x00A0 / 0x00F0 (`hci_sync.c:1908-1921`). T1a therefore also requires `Type: Connectable undirected - ADV_IND (0x00)` |
| The kernel's stored value can be read without btmon | `: \| bluetoothctl mgmt.read-sysconfig` on 04 (wsl.32): `Type: 0x000a	Length: 02	Value: 0008`, `Type: 0x000b	Length: 02	Value: 0008` (little-endian 0x0800), 31 `Type` lines, rc 0, twice. ⚠️ The first of three runs printed "Segmentation fault" and stopped at 0x001e when it was killed after 5 s; not seen again. The helper treats a readout without both lines as INVALID, never as a pass, and retries (T1b) |
| btmon prints the interval as `%.3f msec (0x%4.4x)` | `monitor/packet.c:2280`; real capture §0 |
| The phone AP is on 5 GHz | `uci get wireless.radio0.band` = `5g`, channel 36, on 04 and 02 |

## 6. Cost and what is not measured

- Airtime ⚠️ computed, not measured: one ADV_IND with a 31-byte payload is about 0.38 ms on each of the three
  advertising channels, once per ~125 ms: about 0.3 % of each channel per node (scan responses to active scanners
  not counted), while no phone is connected over BLE. Ten nodes in one room: about 3 % of each channel.
- Power ⚠️ estimated: under 1 % transmit duty at a few dBm is in the mW range against a node that draws watts.
- Wi-Fi on the same chip ❌ **not measured**. In normal use the phone is on the node's Wi-Fi with the BLE link
  closed, so the node advertises at the new rate all the time its AP carries traffic; the radio is shared between
  2.4 GHz BLE and the 5 GHz AP by the chip's coexistence. The expected cost is the 0.3 %-per-channel order above,
  but that is an estimate. It can only be measured with a Wi-Fi client on the node's AP (the phone; changing its
  Wi-Fi is the user's): on the user's on-site list, and stated as untested in the PR body. If it shows a loss, the
  fallback is a larger value in the same two keys.
- HaLow (sub-GHz, separate radio) and LoRa are not involved.

## 7. Security

- Assets / actors: availability of the BLE path; the node's observability.
  - Remote attacker: the node already advertises continuously and its 5 GHz AP beacons about every 100 ms; ten
    times more BLE advertisements make it no more identifiable (same resolvable address and identifier rotation,
    same content). A direction finder gets more BLE packets per second; the AP beacons already give that.
    Connecting is as possible as before (the attacker's scanner can be 100 % duty), the two-connection cap and all
    authentication are unchanged.
  - Local unprivileged process / compromised tenant: no new input. It cannot write the file; mgmt needs
    CAP_NET_ADMIN. A compromised provd: see §3 (cannot change the interval; nothing new).
  - Physical capture, supply chain: nothing new; the file is part of the image like the rest of `main.conf`.
  - Our mistakes: a wrong value in the file → T1a / T1b accept only the two intended values.
- Attack-surface delta: none (two constants in a root-owned file).
- Privilege, secrets: unchanged, none.
- Failure mode: a missing / ignored key falls back to 1.28 s. That is fail-open to today's behaviour, chosen
  because the alternative (no advertising) cuts the owner off from the node.
- Negative test: not applicable to an attack; the functional negative control is T1 on wsl.32.

## 8. Tests

### T1 (harness PR, first; in the regular suites)

**T1a — what the controller is told.** New node-side function `adv_int_check` in `scripts/node/prov-p2-254.sh`
(busybox awk over the arm's btmon text `$BMF`, next to `adv_len_check`):
- every `< HCI Command` block of `0x08|0x0006` must contain `Min advertising interval: 100.000 msec (0x00a0)`,
  `Max advertising interval: 150.000 msec (0x00f0)` and `Type: Connectable undirected - ADV_IND (0x00)`; a block of
  `0x08|0x0036` the same two values in its primary interval lines and a connectable property. Only lines inside
  `< HCI Command` blocks are read (the MGMT decoder prints the same labels, `monitor/packet.c:14337`).
- no such block in the capture = FAIL (nothing was checked).
- called in the arms that already hold a capture containing a fresh registration: `adv-data` (suite
  `prov-boot-provd-254`, via unit boot-provd) and `dep-bluetoothd`, `dep-bluetoothd-kill`, `dep-dbus` (suite
  `prov-dep-restart-254`), before the arm removes `$BMF`.
- Result lines: PASS `adv interval 100.000 / 150.000 msec, ADV_IND (N blocks)`. On an image without the keys, one
  fixed text: `adv interval 1280.000 / 1280.000 msec (want 100.000 / 150.000): image without the interval`. Any
  other mismatch prints the values seen, a different line.

**T1b — what the kernel holds after the adapter re-appears.** In `scripts/node/bt-uart-305.sh`, after each
`rebind_once` of `rebind <n>` (suite `bt-uart-rebind-305`): read `bluetoothctl mgmt.read-sysconfig` under the
script's time limit, up to 10 tries 1 s apart (bluetoothd takes the adapter a moment after the probe answers);
pass = `Type: 0x000a … Value: a000` and `Type: 0x000b … Value: f000`. A readout missing either line after the
tries = FAIL `rebind i: adv sysconfig unreadable`. On an image without the keys: `rebind i: adv sysconfig
0008 / 0008 (want a000 / f000): image without the interval`. Read-only; no btmon in that suite.

**Known failures (old image).** `scripts/validation-known-failures.txt`, issue 329, with an expiry, one entry per
suite (a suite is KNOWN only if every FAIL line matches): `prov-boot-provd-254`, `prov-dep-restart-254` (ERE covers
the three arm prefixes), `bt-uart-rebind-305` (ERE covers `rebind [0-9]+`). The EREs are written from the lines
wsl.32 actually prints in the harness PR's run. Removed by the pin PR.

**Offline tests** in `scripts/test-dv-ble-254.sh` (the node functions run offline there already):
- the real capture `a4-btmon-04-default.txt` → exactly the one fixed "image without the interval" line;
- PASS fixture: ⚠️ that capture with the two interval lines hand-edited, marked so in the file; replaced by a real
  capture from the new image (checklist item of the pin PR);
- a block with the right interval but a non-connectable type → FAIL; no block → FAIL; a 0x0036 block
  (⚠️ hand-written, see §5) → PASS / FAIL by its values; an MGMT block with the labels outside `< HCI Command` →
  not counted;
- sysconfig text: the real wsl.32 readout → the fixed old-image line; `a000` / `f000` (⚠️ edited) → PASS; a
  truncated readout → unreadable.

**Negative control.** Both suites and the rebind suite run on wsl.32 (04) in the harness PR: the new checks FAIL
with the fixed lines and are classified KNOWN; on the new image they PASS.

### T2 (device, on the shipped image, both nodes)

`a4cycle.sh` 100 cycles (each connects to both nodes; about 70 min, unattended, no taps) + the phone air log.
`snoop.py` is fixed first: pair a create with the next connection-complete of the same peer address; count
disconnects with reason 0x3E.
- Per node, of ~100 attempts: connect median ≤ 800 ms, max ≤ 1500 ms, **0 timeouts** (app log ≥ 4.9 s, or air-log
  status 0x02). These three decide whether this change did what it claims.
- Fast failures (any other failed attempt) are counted per node and reported with their air-log lines. 0 on both
  nodes → line 194 is closed. Any → line 194 stays open with the rate (before: 8 in 145 attempts), ❓ unattributed,
  as its own item in #329; no fix is designed here.
- Negative control: §0 (wsl.32: 04 median 1631 ms; 02 7 timeouts in 77 attempts).
- A real btmon capture from the new image is taken in this session for the PASS fixture.

### T3

The full daily-validation on the new image (the shipped artifact), as for every image.

### On site (user's list)

Wi-Fi throughput on the node's AP before / after (§6).

## 9. What comes after, and what this does not do

- `batman-ble` is to move from the firmware tree to the Batman feed (`254-stage1-impl.md` §4.6): the file moves
  as it is; this change is kept.
- CM4 (production board): same chip and package; T1 / T2 are run again there when the board exists.
- Not handled here: the fast failure shape (§0); the 30 s wait on a remembered address (#329 line 221); the ~1 s
  pause every 5 min on home; the app's 5 s connect timeout and retry spacing (left as they are).

## 10. Changes from v1 (round 1)

| Finding | Answer |
|---|---|
| A-MAJOR-1 / B-MAJOR-1: "closes line 194" not supported; failures not split by shape | Header and §0 rewritten with the per-shape table; T2 has 100 cycles, per-shape rules; line 194 closed only on 0 fast failures |
| A-MAJOR-2 / B-MAJOR-2: T1 not buildable as written (`rpa` filter drops the command; judge runs on the node) | T1a is a node-side function in the arms that hold a full capture; `rpa` and `AJ_KEEP` untouched |
| B-MAJOR-3: hci0 row cited a test that does not exist | T1b (sysconfig readout after each rebind of `bt-uart-rebind-305`) |
| B-MAJOR-4: known-failures file / format / per-suite | `scripts/validation-known-failures.txt`, one entry per suite, fixed line |
| MINORs | Citations corrected and tree named; c4 row with the real seven numbers, p90 dropped; D-Bus / provd / provhelper wording; 100–150 ms = kernel fast-advertising constants; the judge requires ADV_IND; airtime 0.3 % per channel; Wi-Fi argument corrected, stays ❌ on site; rollback and first-boot rows labelled source-only; min > max marked untested; no overlay `main.conf` on 04 |
