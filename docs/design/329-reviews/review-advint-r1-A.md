# Review r1-A — `docs/design/329-adv-interval.md` @ 72e28f3

Reviewer A, independent, read-only. 2026-11-20.

Scope: the whole document. Baseline `254-stage1-impl.md` decisions were not re-reviewed.

## Verdict: APPROVE-WITH-CHANGES

The change itself (two keys in `main.conf`, `PKG_RELEASE` 3 → 4) is sound, minimal, and the mechanism is
confirmed in source. Two MAJOR findings are open, neither about the two keys: (1) the document attributes all
connect failures to one mechanism while the evidence contains two, and claims to close an issue line that
describes the other one; (2) T1 cannot be built as written, and one lifecycle row cites a test that does not
exist. The design must be revised and reviewed again as a whole before implementation.

## What I checked and how

Sources read (no node, no phone, nothing built, nothing modified but this file):

- Firmware tree in WSL `/home/yello/firmware-2710`: `package/batman/batman-ble/files/{main.conf,bluetoothd.init,bluetooth.conf}`,
  `Makefile`, board patches `patches/ekh-bcm2711/0012|0013|0015`, `feeds/packages/utils/bluez/patches`.
- BlueZ 5.72 as built for the Pi 4: `build_dir/target-aarch64_cortex-a72_musl/bluez-5.72` (`.config` has
  `CONFIG_TARGET_bcm27xx_bcm2711=y`; this tree was built 2026-11-19 and carries the Batman patches. The
  `cortex-a53` tree dates from 10-27 and does not carry them, so its `adapter.c` line numbers are 4 higher).
- Kernel 6.6.138 `build_dir/target-aarch64_cortex-a72_musl/linux-bcm27xx_bcm2711/linux-6.6.138/net/bluetooth`.
- Evidence in `C:\Users\yello\Desktop\Batman\a4\`: `a4-btmon-04-default.txt`, the four app logcats (c1–c4),
  `a4cycle.sh`, `snoop.py`. The `br.zip` phone bug reports were not opened, as instructed.
- Harness in the worktree: `scripts/dv/prov-provd-254.sh`, `scripts/node/prov-p2-254.sh`,
  `scripts/dv/advid-judge-329.sh`, `scripts/dv/known-failures.sh`, `scripts/dv/prov-dv-254.sh`,
  `scripts/dv/bt-uart-305.sh`.
- provd: `feed/batman-prov/src/cmd/batman-provd/bluez.go`.

### Verified correct

| Claim in the design | Result |
|---|---|
| `main.c:570-579` parses the two keys, range 0x0020–0x4000 | right |
| `main.c:459/465` out-of-range warning, key ignored | right |
| `hci_core.c:2470-2471` default 0x0800 | right |
| `mgmt_config.c:253-256` stores the TLVs; no range check, no min ≤ max check (only TLV length, 140-211) | right |
| `advertising.c:1127-1129` D-Bus `MinInterval`/`MaxInterval` only with experimental mode | right; `bluetoothd.init` has no `-E` |
| `load_defaults` runs on every bluetoothd start and every adapter index added | right. Only call site is `adapter_register` ← `read_info_complete` ← index added |
| The keys reach the kernel before provd's registration | right. `load_defaults` is queued on the mgmt socket inside `adapter_register`; provd's `RegisterAdvertisement` can only be dispatched after that function returns, and the mgmt queue is FIFO |
| Advertisement registered without interval uses the adapter default | right. `advertising.c:988-992` sets the interval flag only for non-zero client values; btmon lines 143-150 show `Add Extended Advertising Parameters (0x0054)` with 0x0000, lines 180-183 the HCI command with 0x0800 |
| Legacy HCI command 0x08\|0x0006 on this controller | right (btmon line 180) |
| Nothing else writes the interval | right. No board or BlueZ patch touches it; `CONFIG_BT_DEBUGFS` is not set, so the debugfs writers in `hci_debugfs.c` do not exist; `Set Default System Configuration` is not in the untrusted mgmt command set, so it needs CAP_NET_ADMIN |
| Rollback / downgrade return to 1.28 s; nothing persists | right. The value lives in `hdev` (RAM) and the image file only; `batman-ble` declares no conffiles |
| §0 app-log numbers, baseline: 04 median 1631, max 4211, 1 of 26 failed; 02 6 of 30 failed in the flip run | right (recomputed from the `BMAPP nl attempt` lines) |
| §0 flip: 04 median 510, max 785, 0 of 25 | right |
| provd's advertisement is connectable (`Type: peripheral`, `bluez.go:317`), interval never set | right |
| RPA rotation / provd re-registration do not reset the kernel value | right. The value is per `hdev`; a re-added instance reads it again at add time (`mgmt.c:8929-8935`) |

### Not verified

- The phone air-log numbers in §0 (448 creates, 64 with status 0x02, the 1.2 / 2.5 / 3.8 s clusters, "0.07–0.3 s"
  after the flip): they come from `br.zip`, which I did not open.
- That min > max "would stop advertising" (§3, §7): the kernel does not check, so the controller decides. No
  capture shows it. Plausible, unproven.
- Any behaviour on a live node. Everything above is source and captured files.
- No btmon capture with 0x00a0 / 0x00f0 exists in the evidence folder; the flip state is evidenced by connect
  timing only (see MINOR-4).

## Findings

### MAJOR-1 — Two failure modes in the evidence; the design explains and measures one, and claims to close the other

Scenario. A user taps connect. Today it fails about 1 time in 10. After the change the design promises that
line 194 of #329 ("about 1 in 10 BLE connects is not received by the node") is closed.

Evidence. The four logcats contain 15 failed attempts. Split by the phone's own reason code:

| Kind | Count | Where | Time to failure |
|---|---|---|---|
| `reason : 255` — create-connection timed out (the design's "status 0x02 after 5 s") | 7 | all on node 02 | about 5.03 s |
| `reason : 62` = HCI 0x3E, Connection Failed to be Established: the phone sent the connect request and the node never answered | 6 | both nodes; c1 = 2, c2 = 1, c3 = 1, c4 = 2 | 1150–4154 ms |
| other, fast | 2 | — | 451, 656 ms |

- Both failures of node 04 in its unflipped state are the 0x3E kind (c1 15:48:41 after 1150 ms; c4 17:04:25
  after 2462 ms, `on_le_disconnect Handle : 0x41, Reason : 62`). Node 04 never showed a 5 s timeout in any log.
- 0x3E is the literal symptom of line 194 ("not received by the node"). §0 and the "Why" paragraph (design
  line 32) name only status 0x02.
- The flip evidence for this mode is not significant: 04 unflipped 2 failures in 37 attempts, flipped 0 in 31.
  With a true rate of 5.4 % the chance of 0 in 31 is about 0.18.
- A lost connect request is a per-attempt event. A shorter advertising interval gives the phone more chances
  before its 5 s timer, which explains the timeout mode well; it does not obviously reduce the chance that one
  connect request is missed. The c2 run still has one 0x3E failure while the interval was flipped on 04 (it
  was on the other node, so it does not settle the question either way).
- `snoop.py`'s summary counts connection-complete status ≠ 0 only; a 0x3E arrives as a disconnect after a
  successful complete, so the "64 of 448" figure cannot contain this mode.

Consequence. If 0x3E stays at about 5 % per attempt, T2's "0 failed of 25 on both nodes" passes about 8 % of
the time (0.95^50). T2 already says a remaining failure is reported ❓ and line 194 stays open, which is
honest, but the header promises the opposite and the design gives no account of the second mode.

Fix.
1. §0: split the failure counts by reason (timeout vs 0x3E vs other), per node, per run.
2. Header and §9: the change closes the *timeout* failures and the connect-time half of line 256. Whether
   line 194 closes is decided by T2, not stated up front. Say that 0x3E is not explained by this design.
3. T2: state the pass rule per mode — zero create-connection timeouts; 0x3E failures counted and reported
   with their air-log lines; line 194 closes only if both are zero over a stated number of attempts.
   25 per node cannot show a 5 % rate is gone; either raise the count or say what the run can and cannot show.
4. `snoop.py` (evidence tool): count disconnect reason 0x3E in the summary.

### MAJOR-2 — T1 cannot be built as written, and one lifecycle row cites a test that does not exist

Scenario. The regular suite is supposed to fail when an image advertises at 1.28 s, on every path of the
lifecycle table.

Evidence.
- §8 says the judge reads "text on stdin, runs offline" over the btmon spans of the units `adv-data`, `rpa`
  and `dep-restart`. In `scripts/dv/prov-provd-254.sh`:
  - the unit `adv-data` is "by hand; in no suite" (line 44). Only its judge is called, from `boot-provd`
    (line 184);
  - the `dep-restart` arms run btmon on the node inside `scripts/node/prov-p2-254.sh` (`bm_start`, a `mktemp`
    file) and judge there. That text never reaches the host;
  - only `rpa` brings btmon text to the host (line 327). It is the roughly 50-minute tier-B unit, and the text
    is filtered through `AJ_KEEP`, which keeps the 0x0055 and 0x08|0x0008 / 0x0037 blocks and drops 0x0006.
- §4 row "hci0 re-appearing": "`bt-uart-305` units run with T1 active, so a wrong value there fails T1".
  `scripts/dv/bt-uart-305.sh` and its node script do not run btmon at all. The row has no test.
- So the rows "restart of bluetoothd", "provd restart / rotation" and "hci0 re-appearing" in §4 name a proof
  that does not exist yet, and the design does not say what has to change to make it exist.
- A false PASS is possible if the judge looks only at the two interval lines: for an advertisement that is
  neither connectable nor discoverable the kernel itself forces 0x00A0 / 0x00F0 (`hci_sync.c:1908-1921`,
  `hci_core.h:2259-2260`), the same values the design picks. provd's advertisement is connectable today, so
  this is not live, but the judge should not depend on that.

Fix.
1. §8 states the data flow per span: which unit, where btmon runs, how the text reaches the judge (host-side
   fetch, or a node-side judge in `prov-p2-254.sh`), and the change to `AJ_KEEP` (it is shared with the
   advid judge and its fixtures, so say what happens to those).
2. The judge also requires `Type: Connectable undirected - ADV_IND (0x00)` in each 0x0006 block it accepts.
3. "No block in the span = FAIL" is stated per span, not once for the run.
4. §4 "hci0 re-appearing": either add a btmon span to a `bt-uart-305` unit (harness PR) or mark the row
   ⚠️ source only with no test, and drop the sentence about T1.
5. Say which of these spans run in the daily (tier A) suite. If the only host-visible span stays the tier-B
   `rpa` unit, the regular suite does not check the interval.

### MINOR-1 — Citations that are wrong or off

| Design | Actual (Pi 4 build) |
|---|---|
| `mgmt.c:8739-8740` as the place the default is copied in | Those lines are the legacy Add Advertising path. btmon shows opcode 0x0054, whose code is `mgmt.c:8929-8935` |
| `hci_sync.c:1896-1901` | interval chosen at 1900-1906, command built at 1923-1929 |
| `adapter.c:9387`, `4873-4891`, `4878` | 9383, 4869-4896, 4874-4876. The design's numbers match the unpatched `cortex-a53` tree, not the shipping build |

Fix: correct them and name the tree the numbers come from.

### MINOR-2 — §0 "04 restored" row

"6 cycles: 1374–4919 ms, 1 failed". The c4 log has seven attempts on 04: 2180, 1374, 1637, 2923, a failure
at 2462 ms, 451, 4919. The 451 ms connect is left out of the range. The conclusion (old behaviour is back)
holds; the numbers should be the real ones. The p90 values (2913 / 664) also differ from mine (2582 / 641),
which is a quantile-method difference; name the method or drop p90.

### MINOR-3 — §3 and §7: "org.bluez on D-Bus is denied to everyone but root"

`bluetooth.conf` allows user `provd` to call `RegisterAdvertisement`, `UnregisterAdvertisement`,
`RegisterApplication` and others. The conclusion still holds, because the interval properties are behind
the experimental gate and provd cannot reach mgmt. But the actor analysis should say it correctly: a
compromised provd cannot change the interval; it can register further advertisements, which now go out
eight to thirteen times as often. Also name `batman-provhelper` in §2 as a second privileged mgmt user that
does not write this value (btmon shows its mgmt sockets).

### MINOR-4 — The PASS fixture is synthetic, and no capture shows the new values on the air interface

The evidence folder has one btmon capture and it is the default state. "Seen in the flip test" for the
0x00a0 / 0x00f0 HCI values has no capture behind it, and no capture shows the `Set Default System
Configuration` command either; the flip is evidenced by timing only. The design already marks the edited
fixture ⚠️. The edited lines do match btmon's print format (`monitor/packet.c:2280`,
`"%s: %.3f msec (0x%4.4x)"` → `100.000 msec (0x00a0)`), so the fixture is format-correct. Better: take one
real capture during the next flip (bind mount, read-only otherwise) and use it instead.

### MINOR-5 — Value choice and cost

Only one point (100–150 ms) was measured. It equals the kernel's own fast-advertising constants, which is
a reasonable justification; say so in §1. The multi-node airtime and Wi-Fi coexistence cost is unmeasured
and the design says so (§6); keep that ❌ visible in the PR body. No unnecessary mechanism found: the design
adds no code, no state and no second writer.

## Checklist against the review rules

- Ownership: one writer (bluetoothd from the image file). Confirmed in source. Add provhelper as read-only (MINOR-3).
- Contracts: correct except the D-Bus sentence (MINOR-3). Missing / malformed is fail-open to 1.28 s, with a reason.
- Lifecycle: all paths present. Three rows cite a proof that does not exist (MAJOR-2).
- Assumptions: mechanism verified; three citations off (MINOR-1).
- Security: no new input, no new privilege. Negative test "not applicable" is acceptable for two constants in
  a root-owned image file.
- Negative control: T1 on wsl.32 is a real one once T1 exists. T2's control is §0, which needs the split of MAJOR-1.
