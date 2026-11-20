# Review r3-B: 329-adv-interval.md v3 (53d953f)

Reviewer B, round 3. Whole document reviewed, not only the v2 -> v3 delta.
Read-only: no device, node or phone was touched; nothing was built; no file
other than this report was written.

**Verdict: APPROVE-WITH-CHANGES** (0 BLOCKER, 1 MAJOR, 9 MINOR)

The product change (two `[LE]` keys in `main.conf`, `PKG_RELEASE` 3 -> 4) is
sound. I traced every path I could think of and found none where a connectable
advertisement leaves the new image at 1280 ms. The one MAJOR is in the T1b
judge: on the old image it can give a NEW (non-KNOWN) failure for a reason
unrelated to the interval.

## 1. What I verified, and how

Source trees: BlueZ 5.72 and kernel 6.6.138 under
`/home/yello/firmware-2710/build_dir/target-aarch64_cortex-a72_musl/`;
harness in `C:/src/Batman-a4/scripts`; captures in
`C:/Users/yello/Desktop/Batman/a4/`.

| # | Claim in the design | Result | Evidence |
|---|---|---|---|
| V1 | Kernel default is 0x0800 and is set in one place only | holds | `net/bluetooth/hci_core.c:2470-2471` (hdev alloc); not reset on power off/on |
| V2 | bluetoothd sends the two keys as TLV 0x000a / 0x000b | holds | `src/adapter.c:4733-4745` (`load_le_defaults`), `:4869-4896` (`load_defaults`), key table `src/main.c:567-579`, range 0x0020-0x4000 |
| V3 | Keys reach the kernel before provd's advertisement | holds | `load_defaults` is called at `src/adapter.c:9383` inside `adapter_register`; `src/shared/mgmt.c:227-253` sends one request at a time, so any Add Ext Adv Params queued later is processed after the Set Def System Config |
| V4 | Kernel accepts the config while the adapter is powered | holds | `net/bluetooth/mgmt_config.c:253-256`: no powered check, no range check, no min <= max check |
| V5 | Instance interval comes from the hdev default when the client gives none | holds | `net/bluetooth/mgmt.c:8929-8935` (ext params), `:8739-8740` (legacy add_advertising); bluetoothd sends interval props only with experimental on, `src/advertising.c:988-992`, `:1127-1129` |
| V6 | HCI 0x0006 carries the instance interval for connectable adv | holds | `net/bluetooth/hci_sync.c:1900-1906`; non-connectable is forced to 0x00A0/0x00F0 at `:1908-1921` (not our case) |
| V7 | Re-enable after power off/on re-sends parameters | holds | `hci_powered_update_adv_sync` reschedules with force; the skip at `hci_sync.c:2053-2055` applies only to the same instance already advertising without force |
| V8 | The old-image capture shows 1280 ms | holds | `a4-btmon-04-default.txt:143-150` (MGMT 0x0054, interval 0), `:180-183` (HCI 0x0006, `1280.000 msec (0x0800)` twice, ADV_IND), `:189-191` Success |
| V9 | §0 table of slow / failed connects (04 2/68, 02 13/77) | holds | I recounted the logcat: same cycles, same values, `reason : 62` x6, `reason : 255` x7 |
| V10 | `read-sysconfig` output format used by T1b | holds | `client/mgmt.c:1896-1945`, `print("Type: 0x%04x\tLength: %02hhu\tValue: %s")`; 31 TLVs returned by the kernel |
| V11 | btmon text format used by T1a | holds | `monitor/packet.c:2280`, `"%s: %.3f msec (0x%4.4x)"` |

Paths traced for "1280 ms on the new image" (my angle a): first boot,
bluetoothd restart, bluetoothd kill + procd respawn, dbus restart, adapter
power off/on, hci0 detach/re-attach (new hdev -> defaults back to 0x0800 ->
`adapter_register` runs again -> keys re-sent before any client can register),
provd started before bluetoothd. None gives 1280 ms. ⚠️ This is from source
reading; the device run T2 and the five T1a arms are what prove it on the
real image.

One thing the trace did show: `load_defaults` passes no reply callback
(`mgmt_send_tlv(..., NULL, NULL, NULL)`, `src/adapter.c:4869-4896`), so a
kernel refusal would be silent in bluetoothd's log. T1b's readout is the only
thing that would catch it, which makes T1b's own correctness matter (MAJOR-1).

## 2. Earlier BLOCKER / MAJOR findings: answered in the text?

| Finding | Answered | Where |
|---|---|---|
| r1 "line 194" claim not supported | yes | §0 now cites lines 180-183 and the Command Complete |
| r1 T1 not buildable as written | yes | §8 T1a names the arms and the file the judge lives in |
| r1 hci0 re-attach row had no test | yes | §4 row + T1b after each rebind |
| r1 known-failures format | yes | §8 uses the file's real format; `kf_classify` rule stated |
| r2-A F1 (c3 mislabel, 31/37, 1640) | yes | §0 table matches my recount |
| r2-B MAJOR-1 (T1b retry rule, hung read, time, RB_UP + --flip) | partly | new-image side answered; old-image side is MAJOR-1 below; unit-level time is MINOR-2 |
| r2-B MAJOR-2 (known-failures hiding a broken new image) | yes | old-image line printed only when the file lacks the key; expiry 2026-12-20; T3 PASS rule |

## 3. Findings

### MAJOR-1: T1b takes one try on the old image, and an unreadable try is never KNOWN

**Scenario.** The harness PR lands first and runs against wsl.32 (no key) as
its negative control, and then daily until the pin PR. On an image without the
key, §8 T1b reads the sysconfig once. `bluetoothctl mgmt.*` is known in this
harness to die or hang without output: `scripts/node/ble-lib-254.sh` records
"mgmt.advinfo segfaults now and then without output (E39: 04 4/30, 02 1/31,
2026-10-20)" and a `mgmt.info` segfault on 2026-10-21, and the design's own §5
says 1 of 3 `read-sysconfig` runs gave nothing. That is why `settings()` and
`adv_instances()` read three times.

With one try, an empty readout prints `adv sysconfig unreadable`.
`scripts/dv/known-failures.sh` has `unreadable` in `NEVER_KNOWN`, so the line
can never match the issue-329 entry, and the suite is NEW instead of KNOWN.
The unit does 10 rebinds on each of 04 and 02, so 20 reads per daily run. At
the rates above, a NEW failure on most days is the expected outcome on the
old image, for a reason that has nothing to do with the interval.

**Why MAJOR.** Wrong test verdict, and it is the harness PR's own negative
control that would be hit: "old image gives exactly the KNOWN line" would not
be reproducible.

**Fix.** On a no-key image, retry only while the readout is unreadable (up to
3, same as `settings()`), and stop at the first complete readout. Keep the
single-readout judgment (no retry on a wrong value). Also state the verdict
for the cell the text leaves open: file has no key but the readout is
`a000/f000` (suggest FAIL with its own wording, since image and kernel
disagree).

### MINOR-2: T1b time is checked against the per-rebind lease only

A hung try costs 4 s (`lim`) + up to 2 s (`lim_kill`: TERM, `sleep 2`, KILL)
+ the 1 s pause, so three tries are up to about 21 s, not the figure in §8,
and "old image at most 5 s" is 6-7 s. The design compares this with the 180 s
per-rebind lease (`scripts/node/bt-uart-305.sh:232`) but not with the unit's
600 s lease and 720 s ssh limit (`scripts/dv/bt-uart-305.sh:82`,
`bt305_leased "$n" 600 rebind 10`). Ten worst-case rebinds still fit, but the
margin should be written with the real numbers.

### MINOR-3: T1a does not look at the controller's answer

T1a reads the `< HCI Command` 0x0006 block. A controller that refuses the
parameters (the §3 row "min > max: expected, it refuses") would still give a
block with the right numbers and T1a would PASS. Require `Status: Success` in
the matching Command Complete, or name the existing baseline line in each arm
that proves advertising is actually enabled afterwards.

### MINOR-4: T1a details that decide whether it can be built as written

- Match on the opcode `(0x08|0x0006)` only. The command name is truncated
  differently in the two sources: `LE Set Advertising..` in
  `scripts/tests/fixtures/btmon-254/*.txt`, `LE Set Advert..` in the a4
  capture.
- `dep-power` stops btmon right after `provd: adv registered`
  (`scripts/node/prov-p2-254.sh:389`, no sleep; the other dep arms sleep 2 at
  `:307`), and the baseline accepts `enable_before_add = none`. Say that the
  wsl.32 run must show at least one 0x0006 block in each of the five arms;
  the fixed `1280` line in each arm is the proof.
- The dep arms take the btmon file as an optional argument
  (`prov-p2-254.sh:279-319`). No capture, or a capture with no 0x0006 block,
  must be FAIL. §8 says this for the block; say it for the missing file too.
- `scripts/dv/prov-provd-254.sh:301` notes that btmon text on a non-terminal
  stdout can be lost at SIGINT in the setsid case. The five arms here use
  `bm_start`/`bm_stop`, which the existing `adv_len_check` already relies on,
  so I expect it to hold; one line saying so would close the question.

### MINOR-5: the "is this an old image" test reads the file, not the daemon

`grep '^MinAdvertisementInterval' /etc/bluetooth/main.conf`: GKeyFile also
accepts leading whitespace; only Min is checked; and the file can differ from
what the running bluetoothd read. All three are fine for a read-only image
that we build ourselves. Say that this is the assumption.

### MINOR-6: which PR removes the known-failures entries

§8 says the entries go "in the pin PR". The project rule is that harness
files, the known-failures list included, change only through a harness PR
(#290). Name the PR, and say that the post-merge validation on the shipped
image runs with the entries already removed. Until then, a new image built
without the key is KNOWN, and only the written T3 PASS rule catches it; the
design says so, which I accept.

### MINOR-7: cost side (my angle c)

- Wi-Fi coexistence rests on the AP being on 5 GHz, read from the uci of two
  nodes. It is not shown to be the image default. With a 2.4 GHz AP the
  CYW43455 shares one radio and the airtime estimate would not carry over.
  Cite the default (file:line) or add the condition.
- The power estimate counts the TX of three ADV_IND per event but not the RX
  window after each one. Still in the mW range against a Pi; the conclusion
  does not change, the number should say what it leaves out.
- About 10x more SCAN_REQ/SCAN_RSP when an active scanner is near: stated as
  uncounted. Accepted.
- §7 privacy: more events per second make the node easier to notice, not
  easier to identify (the address and payload are unchanged). The argument
  that the node is already visible depends on its AP being on; say so.
- "Wi-Fi throughput: ❌ not measured" is stated plainly. Accepted; T3's tput
  item is the place it would show.

### MINOR-8: ownership table

The kernel defaults have a second root-only writer: debugfs
`adv_min_interval` / `adv_max_interval` under `/sys/kernel/debug/bluetooth/hci0/`.
Nothing in the image writes them. Name it as "exists, unused", next to the
note that `load_defaults` has no reply callback.

### MINOR-9: citations

- `boards/ekh-bcm2710/batman-config.lock:1095,1134` and the bcm2711 lock
  lines exist, but in the firmware repo, not in the Batman worktree. Say
  which repo.
- `src/main.c:459/465` are at 458/464 in the 5.72 tree I read.

### MINOR-10: lifecycle matrix

No significant row is missing. "Clean stop" has no row; one line marking it
not applicable (bluetoothd stopped = no advertisement at all) completes it.

## 4. Actors

- Remote: no new input; the advertisement content is unchanged. More events
  per second only (see MINOR-7).
- Local unprivileged process: cannot write `main.conf`, the mgmt socket
  config, or debugfs (all root). `LEAdvertisingManager1` still gives no
  interval control without experimental (`src/advertising.c:988-992`).
- Compromised root component: could already do anything to the adapter; no
  delta.
- Supply chain / our own mistake: an image built without the key is the real
  risk, covered by T1b + the T3 rule (MINOR-6).
- Physical capture: no secret involved.

No mechanism in the design looks unnecessary.

## 5. What this review did not do

- ❌ No run on a node or phone; every "holds" above is from source or from
  the existing captures.
- ❌ I did not execute the harness or its offline tests.
- ⚠️ The mgmt failure rates in MAJOR-1 are for `advinfo`/`info` plus the
  design's own 1-of-3 for `read-sysconfig`; the exact rate for
  `read-sysconfig` on 02 is not measured.
