# Design review, round 2, reviewer A: `329-adv-interval.md` v2 (b538caa)

Scope: the whole document, not the delta from v1. Baseline (provd, the app, `254-stage1-impl.md`, the
existing harness suites) was not re-reviewed; only the design's claims about it were checked.
Method: read-only. No node, no phone, no build, no state-changing git. Sources read: the design, both
round-1 reports, the harness in `C:\src\Batman-a4\scripts`, BlueZ 5.72 and kernel 6.6.138 in the WSL
build tree, the firmware tree (HEAD 24e63a27), and the evidence in `C:\Users\yello\Desktop\Batman\a4\`.

## Verdict: APPROVE-WITH-CHANGES

No BLOCKER. One MAJOR (F1: the §0 evidence table mislabels one run, and three numbers the header and
§0 lean on are wrong as a result; conclusions survive, the record must be corrected). Eight MINOR.
The mechanism, ownership, contracts and security sections hold against source. No unnecessary
mechanism was found; the change is one config stanza plus two judges, which is proportionate.

## What was verified, and how

Verified against source or captured output (file:line given in the findings or here):

- Kernel default 0x0800: `net/bluetooth/hci_core.c:2470-2471`. Instance copies the hdev default:
  `mgmt.c:8929-8935`. Legacy path sends the interval on every enable: `hci_sync.c:1900-1929`
  (non-connectable is forced to 0x00A0/0x00F0 at 1908-1921, so the design's "ADV_IND required" in
  T1a is the right guard). `mgmt_config.c:253-256` sets the values with no powered check.
- BlueZ 5.72: `src/main.c:567-579` (keys, range 0x0020-0x4000); `src/adapter.c:4869-4896`
  `load_defaults`, only call at 9383 in `adapter_register`; `load_bredr_defaults` returns true for
  LE-only mode (4667-4668); `client/mgmt.c:1909,1935` (`read-sysconfig` output format, index 0
  default); `monitor/packet.c:2280` (`"%s: %.3f msec (0x%4.4x)"`), 2188 (`ADV_IND` text).
- provd sets no interval: `feed/batman-prov/src/cmd/batman-provd/bluez.go:317-318`.
- Firmware: `package/batman/batman-ble/files/main.conf` has no `[LE]` today; `PKG_RELEASE:=3`; not a
  conffile.
- Captured default on 04: `a4-btmon-04-default.txt:143-150` (MGMT 0x0054) and 180-183 (HCI
  0x08|0x0006, 1280.000 msec (0x0800) twice, ADV_IND).
- §0 numbers: recomputed from the six logcats' `BMAPP nl attempt` lines (table under F1).
- Harness: `scripts/node/prov-p2-254.sh`, `scripts/dv/prov-provd-254.sh`, `scripts/dv/prov-254.sh`,
  `scripts/dv/known-failures.sh`, `scripts/validation-known-failures.txt`,
  `scripts/node/bt-uart-305.sh`, `scripts/dv/bt-uart-305.sh`, `scripts/bt-uart-305-flip.sh`,
  `scripts/daily-validation.sh`, `scripts/test-dv-ble-254.sh`.
- No harness script depends on the 1.28 s interval (grep for 1280 / 0x0800 / adv timing waits).

Inferred only (not run by me): the real output of `bluetoothctl mgmt.read-sysconfig` on a node, the
segfault the design mentions, behaviour of the controller if min > max, anything on the phone side.
The phone air log (`br.zip`) was not opened; `snoop.py` was read but not run.

## Findings

### F1 (MAJOR): run c3 is labelled "both default", but 04 was at 100-150 ms; three §0 numbers are wrong

Scenario: a reader (or the PR body) takes "04: 0 timeouts in 25 at 100-150 ms, 2 in 43 at default"
and "never a timeout at the default in 43 attempts" as the evidence base. The split is wrong.

Evidence, recomputed from the logcats (connected time in ms; failures listed separately):

| run | 04 attempts / failed | 04 connected (median, max) | 02 attempts / failed |
|---|---|---|---|
| c1 | 26 / 1 | 1631, 4211 | 29 / 4 |
| c2 | 25 / 0 | 510, 785 | 30 / 6 |
| c3 (16:56) | 6 / 0 | 661, 667, 883, 518, 507, 493 (median 589.5, max 883) | 7 / 1 |
| c4 (17:01) | 7 / 1 | 2180, 1374, 1637, 2923, 451, 4919 | 7 / 1 |
| c5 | 3 / 0 | - | 3 / 1 |
| c6 | 1 / 0 | - | 1 / 0 |

c3's six connects on 04 have the c2 shape (all under 900 ms), not the c1 shape (median 1631). §4's
own note admits one restore went wrong; c3 is that run, and c4 is the real restore. So 04's split
is 31 attempts at 100-150 ms (c2 + c3) with 0 failures, and 37 at the default (c1 + c4 + c5 + c6)
with 2 failures. Round-1 reviewer A already used 37 / 31. Totals (145 attempts, 15 noResponse,
reason 62 x6, reason 255 x7) do match the design.

Also: c2's median on 02 is 1639.5 ms, the design says 1642.

Effect on conclusions: none in direction (the flip on 04 gets slightly stronger: 31 clean instead
of 25). But this is the evidence the fix rests on and the user's rule is that the record is
correct, so it is not a wording nit.

Fix: relabel the c3 row ("04 still at 100-150 ms, restore not applied; 02 default"), change 25 -> 31
and 43 -> 37 in every place they appear (header, §0, §10), correct 1642 -> 1639.5.

### F2 (MINOR): the header closes the 5 s timeouts unconditionally; §0 only supports it conditionally

Scenario: the PR is merged and line 256 of #329 is ticked on the header's wording. All 7 timeouts
(reason 255) were on 02 (c1 2, c2 5). 02 was never flipped. §0 itself says the support is the
mechanism plus 04's air log and that "T2 on 02 is the test".

Fix: header says "expected to close ..., proven only if T2 on 02 shows 0 timeouts in 100", and the
#329 checklist item for the timeout half is ticked from T2's output, not from the merge.

### F3 (MINOR): T1a is buildable, but the offline test as written is not

Buildable: yes. The arms the design names do hold a btmon text capture in `$BMF`
(`scripts/node/prov-p2-254.sh:279-319` and 321-346), the legacy path always emits 0x08|0x0006 on
enable, and a node `FAIL x` reaches the suite as `FAIL prov-<unit>-254: <arm>: x` through `j()`
(`scripts/dv/prov-provd-254.sh:61-68`), which is what known-failures matches.

Three gaps:

1. "The node functions run offline there already" is true only for single-line functions pulled out
   by grep (`scripts/test-dv-ble-254.sh:284` does this for `adv_field`). `prov-p2-254.sh` cannot be
   sourced offline (it exits FAIL without `/usr/lib/batman/rundir.sh`, around line 69), and the
   multi-line `adv_len_check` (143) has no offline test today. State how `adv_int_check` is
   extracted: write it as one line, or extract a sed range, with `ok`/`no` stubs and `BMF` set.
2. In the dep arms `adv_len_check` is called only `if [ -n "$ad" ]` and btmon is optional
   (`[ -n "${2:-}" ]`). `adv_int_check` must run whenever the arm had a capture, independent of
   `$ad`; and an arm that was supposed to capture but has an empty `$BMF` must FAIL (the design says
   this; the call site must not sit under the `$ad` guard or it becomes a silent skip).
3. The fixtures in `tests/fixtures/btmon-254/*.txt` have the interval lines `<masked>`. The design's
   hand-edited PASS fixture is acceptable for the harness PR, with the pin-PR item to replace it
   with a real capture (it is in the checklist; keep it there). The host awk is not busybox awk;
   keep the function to POSIX awk and no `%d` on values that can exceed 31 bits (not an issue for
   16-bit intervals, say so).

Emit exactly one fixed result line per arm, whatever the number of enable blocks, so the
known-failure ERE has one shape to match.

### F4 (MINOR): T1b is buildable; six details to state

Buildable: yes. The command exists and exits non-interactively (`client/mgmt.c:1935`), the line
format is fixed (1909), the value is little-endian hex so 0x00A0 prints as `a000`, and `lim` is
available through `ble-lib-254.sh`. Hook point: after `rebind_once` reports up
(`scripts/node/bt-uart-305.sh:216-248`).

1. §5 says an unreadable result is INVALID; §8 says FAIL. The suite has only PASS/FAIL/DET/FLIP/NOTE.
   Pick FAIL and fix §5.
2. A FAIL line containing "unreadable" is in `NEVER_KNOWN` (`scripts/dv/known-failures.sh`), so it
   is always NEW even while the known-failure entry is live. That is the right behaviour; say it is
   intended, and make the "wrong value" line not contain that word.
3. The design reports one segfault of `bluetoothctl` in three runs. That is an unattributed flake
   in a suite that will now call it 10 times per node per day. Either attribute it (what input, is
   it the read path) before the harness PR, or define the judge so a crash is FAIL "unreadable" and
   accept NEW failures until attributed. Do not add a retry: a retry would hide it.
4. When `RB_UP != 1` the existing FAIL stands; skip the read and say so, so one fault is one line.
5. Budget: up to +10 s x 10 rebinds fits the 600 s lease and the 185 s per-rebind deadman
   (`scripts/dv/bt-uart-305.sh`, `bt305_leased "$n" 600 rebind 10`). State it.
6. T1b proves the kernel holds the value after hci0 re-appears. It does not prove the ordering
   "defaults loaded before provd re-registers"; that is source-only (`adapter.c:9383`, same
   function that creates the adv manager, one FIFO mgmt queue). Label the §4 row as verified by
   T1b for the value and source-only for the ordering. T1a on 04's dep arms covers the bluetoothd
   restart path on air; nothing covers the hci0 re-appear path on air, and that is acceptable if
   stated.

The flip harness is not disturbed: `scripts/bt-uart-305-flip.sh:30` requires `^FAIL seq-unbind` and
has an empty forbidden pattern. The offline tests for the parser belong in
`scripts/test-dv-bt-uart-305.sh` (via `BT305_LIB_ONLY=1`), or put the helper in `ble-lib-254.sh`.

### F5 (MINOR): the known-failures plan works with the real rules; two things to write down

Checked against `kf_check` / `kf_classify`: four TAB columns, numeric issue, `expires=YYYY-MM-DD`;
a suite is KNOWN only if every `^\s*FAIL ` line matches an unexpired entry of that suite; several
entries per suite are allowed (both prov suites already have entries); `pr_result` prints no
FAIL-prefixed summary line that would escape the ERE (`scripts/dv/prov-254.sh:47,630-632`); the
fixed T1a/T1b lines contain no `NEVER_KNOWN` word. With `gh`, a CLOSED issue makes the entry NEW, so
#329 must stay open until the pin PR removes the entries.

1. The prov units run on `$DNODE0` only (`scripts/daily-validation.sh:310,312`), so T1a covers 04.
   02 is covered by T1b and T2 only. Say so in §8 instead of implying both nodes get T1a.
2. Between the harness merge and the pin PR, an image that lost the keys for any other reason is
   also KNOWN. Give the entries a short expiry and make their removal a line in the pin PR
   checklist, with the full run after removal as the acceptance.

### F6 (MINOR): §4 platform row is wrong for bcm2710

`boards/ekh-bcm2710/batman-config.lock:1095` has `# CONFIG_PACKAGE_batman-ble is not set`, and
bluez-daemon is not set either. The Pi 3 image has no BLE stack, so "same package, same value" is
not true. Fix: "not applicable: no batman-ble in that image". (Pi 3 is not a blocker per the
2026-10-23 decision; the row should just be right.)

### F7 (MINOR): missing lifecycle row, adapter power off/on

The baseline already exercises it (dep-power, power-bondable, power-provdkill arms get btmon in
`scripts/dv/prov-provd-254.sh:230-239`). `hdev` persists across power off/on so the default is
kept; that is source-only. Add the row; T1a can cover it for free by running `adv_int_check` in
those arms too, since they already hold a capture.

### F8 (MINOR): Wi-Fi coexistence is still not measured

§6 marks it not measured (round-1 B MINOR-6 was not taken to the bench). On the Pi 4 the BLE and
2.4 GHz Wi-Fi share one chip and antenna, and the phone's Wi-Fi link to its own node is the field
use. Advertising airtime rises about 10x from a very small base, so a problem is unlikely, but
"unlikely" is not evidence. Acceptable for a DEV image if it is a checklist line in #329 (one
iperf pair, before/after, phone on the node's AP) and the PR body lists it under not tested.

### F9 (MINOR): T2 pass thresholds

Median <= 800 ms and max <= 1500 ms come from 31 samples on 04 only. State what one sample over the
max in 100 means on 02 (report with the air log, or fail), before the run, so the result is not
argued afterwards. 0 timeouts is the hard criterion; say that.

## Round-1 findings

Resolved:
- A MAJOR-1 / B MAJOR-1 (two failure shapes conflated): resolved by the per-shape table and the
  narrowed header. Residue: F1, F2.
- A MAJOR-2 / B MAJOR-2 (T1 not buildable, hci0 re-appear row): resolved by T1a + T1b. Residue: F3.
- B MAJOR-3 (rebind path untested): resolved by T1b. Residue: F4.
- B MAJOR-4 (harness-first with known failures): resolved. Notes: F5.
- MINORs resolved: source citations corrected; c4 row added; D-Bus / provd / provhelper wording;
  ADV_IND required in the judge; airtime figure; rollback and first-boot rows labelled source-only;
  `snoop.py` fix planned in T2.

Not resolved or only accepted:
- B MINOR-6 (Wi-Fi bench measurement): not done, see F8.
- PASS fixture is hand-edited until the pin PR: accepted, tracked in the checklist (F3.3).

## Against the review rules

- Ownership: stated, one writer per resource (image owns `main.conf`, bluetoothd owns the mgmt
  default, provd read-only on it). No second writer found.
- Contracts: stated, including missing / out-of-range keys (BlueZ warns and keeps the kernel
  default, `src/main.c` ~458-466), which fails to today's behaviour.
- Lifecycle matrix: present; gaps are F6 (wrong row), F7 (missing row), F4.6 (label).
- Evidence for assumptions: all source citations I checked are correct. Unverified items are named
  above.
- Security: no new input reachable by an unprivileged process (the file is root-owned in a
  read-only image layer; no new port, API or env var). Faster advertising makes the node slightly
  easier to find by a scanner; identity exposure is unchanged (rotating identifier baseline). I
  agree with the design's assessment.
- Negative controls: T1a and T1b fail on today's image (kernel default 0x0800), which is the
  negative control, and the known-failure entries make that visible rather than hidden. T2's
  negative control is c1 / c4.
