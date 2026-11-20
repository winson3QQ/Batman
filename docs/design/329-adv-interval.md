# #329 A4 — the node advertises every 100–150 ms instead of every 1.28 s

Status: **v4.1 FROZEN** (round 4: A APPROVE, B APPROVE-WITH-CHANGES, 0 BLOCKER / 0 MAJOR; their MINORs are §11). v4 (reviews `329-reviews/review-advint-r1-{A,B}.md`, `-r2-{A,B}.md`, `-r3-{A,B}.md` answered; changes
listed in §10). One change:
two keys in the image's `/etc/bluetooth/main.conf` (firmware repo, `package/batman/batman-ble/files/main.conf`).
No app, provd, helper or protocol change. Harness judges in a separate PR, first (#290).

What it closes, and what it does not:
- Closes the "connect itself sometimes takes 4.2 s" half of #329 line 256 (shown on 04 by the flip test; ticked
  from T2's output).
- The connects that end in the phone's 5 s timeout: expected to go, **not yet shown** — all 7 were on 02, which was
  never flipped. Decided by T2 (0 timeouts on 02).
- **Does not claim #329 line 194** ("about 1 in 10 BLE connects is not received by the node"). §0 shows two failure
  shapes; this change explains only the timeout shape. The fast shape is ❓ unattributed. Line 194 is closed only if
  T2 shows 0 fast failures in about 100 attempts on each node (§8 says what that does and does not prove);
  otherwise it stays open with T2's numbers.

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
| **Flip test** c2: only 04's interval changed to 100–150 ms (bind-mounted `main.conf` with the two keys of §1, bluetoothd restarted; 02 untouched as the control, same 25 cycles) | 04: median **510 ms**, max 785, **0 of 25 failed**; in the phone air log 04's connects complete in 0.0–0.3 s. 02 in the same window: median 1640 ms, 6 of 30 failed. |
| c4, 04 restored (interval written back to 0x0800, then the image's file; md5 `41c7ab5d…`, no bind mount, no overlay copy of `main.conf`) | 04, 7 attempts: 2180, 1374, 1637, 2923, failed after 2462, 451, 4919 ms: the old behaviour is back. |

Failed attempts by shape (app log `BMAPP nl attempt … result=noResponse after N ms`; all six runs):

| Run | 04 | 02 |
|---|---|---|
| c1 (both default) | 1 of 26: fast (1150 ms) | 4 of 29: timeout ×2 (5026, 5028), fast ×2 (451, 1620) |
| c2 (04 at 100–150 ms) | 0 of 25 | 6 of 30: timeout ×5, fast ×1 (1496) |
| c3 (04 still at 100–150 ms: its six connects are 661, 667, 883, 518, 507, 493 ms) | 0 of 6 | 1 of 7: fast (4154) |
| c4 (04 restored) | 1 of 7: fast (2462) | 1 of 7: fast (2866) |
| c5, c6 (both default) | 0 of 4 | 1 of 4: fast (656) |
| **Total** | 2 of 68 (0 timeouts, 2 fast) | 13 of 77 (**7 timeouts**, 6 fast) |

- Timeout shape (≥ 5.0 s; phone status 0x02 / `reason : 255`): 7, all on 02 at the default interval. Explained by
  the interval (below).
- Fast shape (0.45–4.2 s; six of the eight are `reason : 62` = HCI 0x3E "Connection Failed to be Established", i.e.
  the phone sent its connect request and the node's link layer did not answer): 8, on both nodes. ❓ Not attributed.
  04 at 100–150 ms had 0 in 31 attempts, at the default 2 in 37: too few to say the interval removes them.
- So the evidence that the change removes timeouts is the mechanism plus 04's air log (connects complete in
  0.0–0.3 s, far from 5 s); 04 itself never showed a timeout at the default in 37 attempts. T2 on 02 is the test.

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
  `main.c:458/464`).
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

No second writer is added. (The kernel's debugfs files for this value, root-only, do not exist on the node:
`/sys/kernel/debug/bluetooth/hci0/` is empty on 04, `adv_min_interval` / `adv_max_interval`: no such file.) `batman-provhelper` is a second privileged mgmt user on the node; it does not write
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
| Restart of bluetoothd (clean, killed, D-Bus restart) | provd re-registers when BlueZ re-appears (unchanged); the kernel value is still there, and `load_defaults` writes it again | T1a in `prov-dep-restart-254` (arms `dep-bluetoothd`, `dep-bluetoothd-kill`, `dep-dbus`). This proves the advertisement after the restart is at 100–150 ms; it cannot prove the re-send (the value survives in `hdev`) — the row after next does |
| Adapter power off / on | `hdev` and its value stay; provd registers again when the adapter is powered | T1a in arm `dep-power` (same suite; its capture holds the registration after power on) |
| hci0 re-appearing (UART re-attach, #305) | new `hdev` starts at 0x0800 (unbind frees it, `drivers/bluetooth/hci_serdev.c:395-402`; bind allocates a new one, `:329` → `hci_core.c:2470`); bluetoothd takes the adapter and sends the keys | **T1b** in `bt-uart-rebind-305` (10 unbind/bind): the kernel value is read back after each rebind. That provd's next advertisement then uses it is ⚠️ source only (`adapter.c:9383`: the keys are queued inside the adapter's registration, before provd can see the adapter object; mgmt commands go out in order) — the suite has no btmon |
| provd restart, a connection ending, the 900 s rotation | the kernel value is untouched; the new registration reads it | T1a (`adv-data` arm restarts provd). Rotation: same code path as any registration; the `rpa` unit's capture filter drops the parameters command and is not changed |
| Upgrade wsl.32 → new image | reboot → new file → new value | T1a / T1b after the OTA |
| Rollback / downgrade to an image without the keys | the slot switch is a reboot: the kernel starts at 0x0800 and the old file sends nothing → 1.28 s, exactly today. Nothing is stored outside RAM and the image. | ⚠️ source only for the switch itself; wsl.32 giving 1280 ms in T1a / T1b shows what an image without the keys does |
| Clean stop (bluetoothd or the node stopped) | not applicable: no advertising while bluetoothd is down, as today; nothing is written at stop | — |
| Crash, crash loop, power loss | no state besides the image file | — |
| Restored backup (`sysupgrade -r`) | no bluetooth conffiles; cannot change the file (`254-stage1-impl.md` L64) | existing `ble-privacy-254` |
| bcm2711 (Pi 4; CM4 has the same CYW43455) | the paths above | T1a runs on 04 only (the prov units are bound to it); 02 gets T1b and T2 |
| bcm2710 (Pi 3A+) | not applicable: that board's image has no `batman-ble` and no bluetoothd (firmware repo `boards/ekh-bcm2710/batman-config.lock:1095`, `:1134`: both "is not set") | — |

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
| The kernel's stored value can be read without btmon | `: \| bluetoothctl mgmt.read-sysconfig` on 04 (wsl.32): `Type: 0x000a	Length: 02	Value: 0008`, `Type: 0x000b	Length: 02	Value: 0008` (little-endian 0x0800), 31 `Type` lines, rc 0, twice. ⚠️ The first of three runs printed "Segmentation fault" and stopped at 0x001e when it was killed after 5 s; not seen again. ❓ unattributed. T1b never takes a readout without both lines as a pass, tries again, and prints how many tries were unreadable so the rate becomes a number |
| btmon prints the interval as `%.3f msec (0x%4.4x)` | `monitor/packet.c:2280`; real capture §0 |
| The phone AP is on 5 GHz on the two bench nodes (not claimed as an image default) | `uci get wireless.radio0.band` = `5g`, channel 36, on 04 and 02 |

## 6. Cost and what is not measured

- Airtime ⚠️ computed, not measured: one ADV_IND with a 31-byte payload is about 0.38 ms on each of the three
  advertising channels, once per ~125 ms: about 0.3 % of each channel per node (scan responses to active scanners
  not counted), while no phone is connected over BLE. Ten nodes in one room: about 3 % of each channel.
- Power ⚠️ estimated: under 1 % transmit duty at a few dBm is in the mW range against a node that draws watts.
  The short receive window after each advertisement is not counted in either estimate.
- Wi-Fi on the same chip ❌ **not measured**. In normal use the phone is on the node's Wi-Fi with the BLE link
  closed, so the node advertises at the new rate all the time its AP carries traffic; the radio is shared between
  2.4 GHz BLE and the 5 GHz AP by the chip's coexistence. The expected cost is the 0.3 %-per-channel order above,
  but that is an estimate. It can only be measured with a Wi-Fi client on the node's AP (the phone; changing its
  Wi-Fi is the user's): on the user's on-site list, an unchecked line in #329's checklist, and stated as
  untested in the PR body. If it shows a loss, the
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

Both judges tell "an image without the keys" from "the keys are there and did not work" by looking at the node's
file: `grep -q '^MinAdvertisementInterval' /etc/bluetooth/main.conf`. Only without the key may the fixed
old-image line be printed (the only line the known-failures entries match). With the key, any wrong result is a
different line, so it is NEW — on the new image nothing of T1 can hide as KNOWN.

**T1a — what the controller is told.** New function `adv_int_check <btmon text file> [main.conf path]` in
`scripts/node/ble-lib-254.sh` (busybox awk; that library is already loaded offline by `test-dv-ble-254.sh`). It
prints exactly one line, `PASS …` or `FAIL …`, and returns 0 / 1; the arm passes that line to its own `ok` / `no`.
The second argument defaults to `/etc/bluetooth/main.conf` and exists for the offline tests.
- blocks are found by opcode only (`0x08|0x0006`, `0x08|0x0036`; btmon truncates the command name in two ways).
  Every `< HCI Command` block of `0x08|0x0006` must contain `Min advertising interval: 100.000 msec (0x00a0)`,
  `Max advertising interval: 150.000 msec (0x00f0)` and `Type: Connectable undirected - ADV_IND (0x00)`; a block of
  `0x08|0x0036` the same two values in its primary interval lines and a connectable property. Only lines inside
  `< HCI Command` blocks are read (the MGMT decoder prints the same labels, `monitor/packet.c:14337`).
- the `> HCI Event: Command Complete` of each such command must say `Status: Success (0x00)`; a refusal by the
  controller is a FAIL with the status seen.
- a missing or empty capture file, or no such block in it = FAIL (nothing was checked).
- called once per arm, unconditionally (not inside another check's guard), after `bm_stop` and before the arm
  removes `$BMF`, in the arms whose capture holds a fresh registration: `adv-data` (suite `prov-boot-provd-254`,
  via unit boot-provd) and `dep-bluetoothd`, `dep-bluetoothd-kill`, `dep-dbus`, `dep-power` (suite
  `prov-dep-restart-254`). `dep-power` shares its code with `power-bondable`, whose capture must not hold a
  registration: the call is made only when the arm is `dep-power`. In that arm btmon is stopped after provd's
  `adv registered` log line, which provd prints after BlueZ answered the registration, so the command is in the
  capture. Runs on 04.
- Result line:
  - PASS `adv interval 100.000 / 150.000 msec, ADV_IND (N blocks)`;
  - file without the key and every block at 1280 / 1280, connectable, status Success: FAIL `adv interval
    1280.000 / 1280.000 msec (want 100.000 / 150.000): image without the interval`;
  - anything else: FAIL with the values, type and status seen (and `main.conf has the key` when it does).

"The file has the key" = `grep -Eq '^[[:space:]]*MinAdvertisementInterval[[:space:]]*=' <main.conf>`. A commented
line does not match. This reads the file, not the daemon: the file is in the read-only image and bluetoothd reads
it once at start, so on an untouched node they agree; a hand-edited overlay copy is an operating mistake (§2). A
misspelled key in a future image reads as "without the key" → the old-image line → KNOWN while the entries exist;
T2 and T3 therefore start by printing this grep's result on both nodes and need a match.

**T1b — what the kernel holds after the adapter re-appears.** In `scripts/node/bt-uart-305.sh`, `rebind <n>`
(suite `bt-uart-rebind-305`, both nodes), after each `rebind_once`, only when `RB_UP = 1` and not with `--flip`
(the existing lines already fail a rebind that did not come up):
- if bluetoothd is not running (`pidof bluetoothd`): FAIL `rebind i: adv sysconfig: bluetoothd not running`, no
  read (bluetoothctl would wait forever).
- one try = `lim 4 bluetoothctl mgmt.read-sysconfig` fed from `:`, its output (and `lim`'s own timeout line)
  captured into a variable, never printed as a result line. A try is **complete** when it has both a
  `Type: 0x000a … Value:` and a `Type: 0x000b … Value:` line; anything else is **unreadable** (bluetoothctl's
  mgmt commands are known to die without output on these nodes: `ble-lib-254.sh` E39, and the one crash in §5).
- Up to 5 tries, 1 s apart, on every image. Unreadable tries never decide; they only use up tries.
  - File without the key: the first complete try decides. `0008` / `0008` → FAIL `rebind i: adv sysconfig 0008 /
    0008 (want a000 / f000): image without the interval`. Any other complete value → FAIL `rebind i: adv
    sysconfig X / Y but main.conf has no key` (somebody else wrote the value; NEW).
  - File with the key: ends at the first complete try with `a000` / `f000` → PASS. A complete try that still says
    `0008` does **not** end the tries: bluetoothd powers the adapter (`adapter.c:9380 `load_drivers` → `plugins/policy.c:834-835``) before it sends the keys
    (`:9383`), and the suite goes on as soon as the adapter is powered. After 5 tries: FAIL `rebind i: adv
    sysconfig X / Y after 5 tries (want a000 / f000)`. NEW.
  - No complete try in 5 on either image: FAIL `rebind i: adv sysconfig unreadable`. NEW on any image
    ("unreadable" is one of the words `dv/known-failures.sh` never accepts as known) — intended: nothing was
    checked.
- Every rebind prints `DET rebind i: adv sysconfig tries=N unreadable=M`, so the rate of dead readouts shows as a
  number even when the check passes.
- Time: a hung try costs 4 s + up to 2 s for `lim` to end it + the 1 s pause, so at most 35 s per rebind (inside
  the per-rebind lease of 180 s / deadman 185 s, `bt-uart-305.sh:232`) and at most 350 s over the 10 rebinds, only
  when every try hangs. The suite's own lease is 600 s (`dv/bt-uart-305.sh:82`); the harness PR prints the suite's
  duration on wsl.32 before and after, and if the worst case cannot fit, the number of tries is lowered to 3 there
  (a lease that ends the suite is a FAIL either way, never a pass). A normal run adds about 1 s per rebind.
- Read-only. It proves the value; see §4 for what stays source-only. `load_defaults` has no reply callback, so a
  kernel that refused the keys would be silent in bluetoothd — this readout is what shows it.

**Known failures (old image).** `scripts/validation-known-failures.txt`, issue 329, `expires=2026-12-20`, one
entry per suite (a suite is KNOWN only if every FAIL line matches): `prov-boot-provd-254`, `prov-dep-restart-254`
(ERE covers the four arm prefixes), `bt-uart-rebind-305` (ERE covers `rebind [0-9]+`). The EREs are written from
the lines wsl.32 actually prints in the harness PR's run. #329 stays open while they exist. They are removed by a
harness PR of their own after T3 (harness changes do not ride in a product PR, #290); that PR is a line in
#329's checklist. In T3 on the new image the three suites must be PASS; KNOWN there is a failure
(it cannot happen by the rule above unless the file lost the key — which is the failure).

**Offline tests.** `adv_int_check` in `scripts/test-dv-ble-254.sh`, the sysconfig judge in
`scripts/test-dv-bt-uart-305.sh` (it loads that node script already):
- the real capture `a4-btmon-04-default.txt`, file without the key → exactly the fixed old-image line; the same
  capture with "file has the key" → the other FAIL line;
- PASS fixture: ⚠️ that capture with the two interval lines hand-edited, marked so in the file; no real PASS has
  been seen by the judge until the new image exists (said in the harness PR body). Replacing the btmon and the
  sysconfig PASS fixtures with real captures is done in that same later harness PR;
- a block with the right interval but a non-connectable type → FAIL; no block → FAIL; a 0x0036 block
  (⚠️ hand-written, see §5) → PASS / FAIL by its values; an MGMT block with the labels outside `< HCI Command` →
  not counted; a block whose Command Complete is not Success → FAIL; a missing capture file → FAIL;
- sysconfig: the real wsl.32 readout without the key → the fixed old-image line; `a000` / `f000` (⚠️ edited) →
  PASS on the first try; `0008` twice then `a000` / `f000` with the key → PASS, tries=3; a `lim` timeout line then
  a good readout → PASS, unreadable=1, no FAIL line printed; truncated every time → unreadable (with and without the key); without the key, an empty try then `0008` /
  `0008` → the fixed old-image line, tries=2, unreadable=1; without the key, `a000` / `f000` → the "no key" line; `0008` five times
  with the key → the "after 5 tries" line.

**Negative control.** The three suites run on wsl.32 in the harness PR (04; the rebind suite also on 02): the new
checks FAIL with the fixed lines and are classified KNOWN; on the new image they PASS.

### T2 (device, on the shipped image, both nodes)

`a4cycle.sh` 100 cycles (each connects to both nodes; about 70 min, unattended, no taps) + the phone air log.
`snoop.py` is fixed first: pair a create with the next connection-complete of the same peer address; count
disconnects with reason 0x3E. Rules, fixed before the run:
- **0 timeouts** on each node (a *failed* attempt with app log ≥ 4.9 s, or air-log status 0x02; a success that
  took that long falls under the 1500 ms rule). The hard rule. It is a real test on 02
  (before: 7 in 77); on 04 it says little (before: 0 in 37).
- Connect median ≤ 800 ms on each node (before: 04 1631 ms in c1, 02 1640 ms in c2; 04 flipped: 510). This is the rule that tests 04.
- A successful connect slower than 1500 ms is listed with its air-log lines. The run needs at least 95 attempts per node; up to 2 such
  connects per node do not fail the run (04 flipped: max 883 in 31, so the limit is a guess); more do, and are ❓ until attributed.
- Fast failures (any other failed attempt) are counted per node and reported with their air-log lines. 0 in the
  ~200 pooled attempts → line 194 is closed, with this written next to the tick: before 8 in 145 (5.5 %), after
  0 in ~200, which bounds the rate below about 1.5 % (95 %) — "not seen again", not "proven gone", and still
  ❓ why the interval would matter. Any → line 194 stays open with the rate, as its own item in #329; no fix is
  designed here.
- The negative control is §0, taken in another session on the same phone, place and nodes; said so in the result.
- A real btmon capture and a sysconfig readout from the new image are taken in this session for the PASS fixtures.

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

## 10. Changes from v1 (round 1) and from v2 (round 2)

| Finding | Answer |
|---|---|
| A-MAJOR-1 / B-MAJOR-1: "closes line 194" not supported; failures not split by shape | Header and §0 rewritten with the per-shape table; T2 has 100 cycles, per-shape rules; line 194 closed only on 0 fast failures |
| A-MAJOR-2 / B-MAJOR-2: T1 not buildable as written (`rpa` filter drops the command; judge runs on the node) | T1a is a node-side function in the arms that hold a full capture; `rpa` and `AJ_KEEP` untouched |
| B-MAJOR-3: hci0 row cited a test that does not exist | T1b (sysconfig readout after each rebind of `bt-uart-rebind-305`) |
| B-MAJOR-4: known-failures file / format / per-suite | `scripts/validation-known-failures.txt`, one entry per suite, fixed line |
| MINORs | Citations corrected and tree named; c4 row with the real seven numbers, p90 dropped; D-Bus / provd / provhelper wording; 100–150 ms = kernel fast-advertising constants; the judge requires ADV_IND; airtime 0.3 % per channel; Wi-Fi argument corrected, stays ❌ on site; rollback and first-boot rows labelled source-only; min > max marked untested; no overlay `main.conf` on 04 |
| r2 A-F1: c3 was not "both default" (04 still at 100–150 ms) | Row and counts corrected: 04 0 of 31 at 100–150 ms, 2 of 37 at the default; 02's c2 median 1640 |
| r2 B-MAJOR-1: T1b retry rule, hung read, time bound, adapter down / `--flip` | §8 T1b: tries continue past a complete `0008`, output captured, 25 s per rebind at most, only when `RB_UP = 1` and not `--flip`, DET line with tries |
| r2 B-MAJOR-2: known-failures would hide "new image, keys do not work" | The old-image line is printed only when `main.conf` lacks the key; expiry given; T3 needs PASS |
| r2 A-F2, A-F9 / B-3: timeouts claimed unconditionally; T2 thresholds | Header conditional on T2; T2 rules fixed before the run, with what 0 in ~200 proves |
| r2 A-F3 / B-6: how the judges are loaded offline; guard; one line per arm | `adv_int_check` lives in `ble-lib-254.sh`; called unconditionally; offline tests split over the two existing test scripts |
| r2 A-F4, A-F5 / B-4, B-5, B-8: INVALID vs FAIL, 04-only, source-only step, fixtures | §5, §4, §8 worded accordingly |
| r2 A-F6: bcm2710 has no `batman-ble` | §4 row: not applicable |
| r2 A-F7: adapter power off / on row missing | §4 row; T1a in arm `dep-power` |
| r2 A-F8 / B-7: Wi-Fi still unmeasured | Not measurable remotely (needs a Wi-Fi client on the node's AP); #329 checklist line + PR body + user's on-site list |
| r3 A-1 / B-1 (MAJOR): one try on the old image; a dead readout gave a false NEW or a hidden KNOWN | §8 T1b: up to 5 tries on every image; only a complete readout decides; "no key but another value" has its own line; offline cases added |
| r3 A-2, A-6 / B-3, B-4: `dep-power` shares its arm; reporting contract; Command Complete status; opcode match; missing file | §8 T1a |
| r3 A-3 / B-2: time bound | §8 T1b: 35 s / 350 s worst case against the 600 s suite lease, measured in the harness PR; `pidof bluetoothd` guard |
| r3 A-4 / B-5: the key grep | §8: regex, what it assumes, printed as a precondition of T2 / T3 |
| r3 B-6: who removes the known-failures entries | a later harness PR, not the pin PR |
| r3 A-5, A-7, A-9 / B-7..B-10: citations, clean stop, debugfs, RX windows, AP band | §1, §2, §4, §5, §6 |
| r3 A-8: T2 rules | ≥ 4.9 s counts only for failed attempts; minimum 95 attempts per node |

## 11. Freeze notes (round-4 MINORs; binding for the implementation, they override §8 where they differ)

- **No `0x08|0x0036` branch.** T1a reads `0x08|0x0006` blocks only; there is no real extended capture to build it
  from, and "no `0x0006` block = FAIL" already fails safe if a kernel ever switches. The hand-written fixture is
  dropped.
- **T1a Command Complete.** For each block: the next `> HCI Event: Command Complete` whose opcode is
  `0x08|0x0006`. None before the capture ends = FAIL. With several blocks the line reports the first one that
  fails, and N counts all of them. A file without the key but blocks at 100 / 150 = FAIL `… but main.conf has no
  key`.
- **Where T1a is called.** In the three `dep-*` restart arms the capture exists only when the arm was given the
  btmon path; the call sits inside that branch, before `rm -f "$BMF"`. The harness PR shows that the suites pass
  that path (so the check cannot be skipped in the regular run).
- **One key test.** A single helper with the anchored `grep -Eq` of §8 is used by both judges.
- **T1b.** PASS line: `rebind i: adv sysconfig a000 / f000`. A try that has both `Value` lines is complete even
  if bluetoothctl dies afterwards. Tries are fixed at 5 (worst case about 350–450 s over 10 rebinds, inside the
  host's 720 s limit; `dv/bt-uart-305.sh:82`). The judge takes its inputs (main.conf path, readout text) as
  arguments so the offline tests need no node.
- **Old-image lines carry the image version** (`… : image without the interval [<version>]`), so a KNOWN on a node
  that should have been upgraded is visible to whoever reads the output.
- **Harness PR reports** the `DET … unreadable=` totals from both nodes (the rate for this command is not known:
  E39's figures are for other mgmt commands), and fixes the stale comment at `scripts/dv/prov-provd-254.sh:44`.
- **Offline tests add**: a capture with two blocks (one wrong → FAIL naming it); the fixed old-image lines run
  through `kf_classify` with the new entries → known, the other FAIL lines → new.
- **T2 outcomes.** #329 line 256 (connect time) is ticked by the median rule on both nodes. A failed rule leaves
  its line open with the numbers. Fewer than 95 attempts on a node = the run is not valid and is repeated.
