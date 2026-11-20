# Review r1-B — `329-adv-interval.md` v1 (HEAD 72e28f3)

Reviewer B, independent. Read-only: no node, no phone, nothing built, no file written but this one.
Focus: app side and the system as a whole. Baseline designs (254-stage1-impl, 329-rotating-id-plan,
329-ble-settle) were read as reference only and are not re-reviewed.

## Verdict: APPROVE-WITH-CHANGES

The change itself (two keys in `main.conf`) is right, minimal, and its mechanism is confirmed in source on
every hop. No BLOCKER. Four MAJOR findings, all in the claims and the tests around the change, not in the change:
the failure-rate claim ("closes line 194") is not supported by the design's own logs, T1 cannot be built as
described, one lifecycle proof is false, and T1's known-failures handling is under-specified in a way that turns
other suites red.

## What was verified, and how

| Claim | Result |
|---|---|
| `main.c:570-579` parses the keys, range 0x0020–0x4000 | RIGHT (BlueZ 5.72 build tree, WSL) |
| `main.c:459/465` warnings | RIGHT |
| `adapter.c:9387` `load_defaults()` | WRONG LINE: the call is at 9383, inside `adapter_register` (9387 is `btd_gatt_database_restore_svc_chng_ccc`). Claim holds. |
| `adapter.c:4873-4891` / early return `:4878` | OFF: function body 4869–4896, early return 4874–4876. Claim holds. |
| `advertising.c:1127` experimental gate | RIGHT (1127–1129) |
| `hci_core.c:2470-2471` default 0x0800 | RIGHT (Linux 6.6.138) |
| `mgmt.c:8739-8740` "copied into the instance" | WRONG FUNCTION: that is `add_advertising` (legacy 0x003e). provd's path, per the design's own btmon (MGMT 0x0054), is `add_ext_adv_params`, `mgmt.c:8929-8935` (`flags & MGMT_ADV_PARAM_INTERVALS ? cp->min_interval : hdev->le_adv_min_interval`). Conclusion holds. |
| `hci_sync.c:1896-1901` | OFF: 1900–1906 (instance vs hdev) and 1923–1924 (cp.min/max). Claim holds. |
| `mgmt_config.c:253-256` stores TLVs; `:160-190` length check only, no min ≤ max | RIGHT |
| `bluez.go:318`, `:354`, `:521` | RIGHT. Also confirmed: rotation `rpaBase` 900 s + jitter, advert content unchanged by this design. |
| bluetoothd runs without `-E` | RIGHT (`bluetoothd.init`: `-n --noplugin=hostname,autopair,battery,neard,sap`) |
| Current `main.conf` has no `[LE]` section; `PKG_RELEASE:=3`; not a conffile | RIGHT (firmware-2710 @ 24e63a27) |
| btmon capture `a4-btmon-04-default.txt` | RIGHT: one `LE Set Advert.. (0x08\|0x0006)` block with 1280.000 msec (0x0800) twice, preceded by MGMT 0x0054 with flags 0x1 and 0.000 msec (0x0000). |
| btmon prints the 0x0036 intervals in the same `%.3f msec (0x%4.4x)` form | RIGHT (`monitor/packet.c:7725-7746`). The MGMT decoder prints the same label (`packet.c:14337`), so the judge must stay inside `< HCI Command` blocks, as the design says. |
| a53 (Pi 3) kernel vs a72 | `hci_core.c`, `mgmt_config.c` identical; `mgmt.c` / `hci_sync.c` differ only in the #254 D3b patch area, not on the interval path. |
| §0 app-log counts | Reproduced from `a4-c1..c4.logcat` (`nl attempt` lines): c1 04 1/26, 02 4/29; c2 (flip) 04 0/25, 02 6/30; c4 (restored) 04 1/7. Medians not recomputed. |

Not verified: the 448-command air-log statistics (btsnoop in `br*.zip` not re-parsed); the S20's scan parameters;
anything on a node or phone; whether a copy of `main.conf` remains in 04's overlay after the flip test; BlueZ
a53-vs-a72 source identity (comparison output was cut); Wi-Fi coexistence (nobody has measured it).

## Findings

### MAJOR-1 — "Closes #329 line 194" does not follow from the evidence; half of the failures are not the 5 s timeout

Scenario: the image ships, T2 passes 0/25 by chance, line 194 is closed, and in the field about 1 in 20 connects
still fails.

Evidence (failure durations from the design's own logcats, `nl attempt … connected=-1ms result=noResponse after N ms`):

| Log | Node | Attempts | Failed | Failed after |
|---|---|---|---|---|
| c1 (default) | 04 | 26 | 1 | **1150 ms** |
| c1 (default) | 02 | 29 | 4 | **451**, 5026, **1620**, 5028 ms |
| c2 (04 flipped) | 04 | 25 | 0 | — |
| c2 (02 = control) | 02 | 30 | 6 | 5030, 5030, 5031, 5026, 5029, **1496** ms |
| c3 | 02 | 7 | 1 | **4154** ms |
| c4 (04 restored) | 04 / 02 | 7 / 7 | 1 / 1 | **2462** / **2866** ms |
| c5 | 02 | 3 | 1 | **656** ms |

- 15 failures; 7 are the 5.03 s timeout, **8 fail in 0.45–4.2 s**. That second shape is the one
  `329-ble-settle.md` already recorded ("133 at 0.4–2.9 s without a create-connection timeout"). The design's
  cause section explains only the timeout shape and never mentions the other.
- **04 at the default interval had zero 5 s timeouts** (0 of 33 in c1 + c4); both of its failures were the fast
  shape. So for the failure rate the flip test on 04 has no negative control: "1 of 26 → 0 of 25" compares one
  fast failure with none. At 04's observed fast rate (2/33, about 6 %) the chance of 0 in 25 with no fix at all
  is about 0.2.
- The latency claim (median 1631 → 510 ms) is solid: deterministic mechanism, large effect, restore test.
- T2 "0 failed of 25" per node cannot separate 0 % from 3–5 % (0 in 50 at 3 % happens about 1 time in 5).

Fix:
1. §0: add the failure-shape split above; say the interval explains the timeout shape and the long connects,
   and that the fast shape is ❓ unattributed (it may or may not shrink with the interval).
2. Header: this closes the "4.2 s" half of line 256; line 194 closes only on T2's result.
3. T2: classify each failure by shape from the air log (0x02 timeout vs anything else); run enough cycles to
   mean something — 100 per node (unattended, about an hour) — and state the pass rule per shape: 0 timeouts;
   fast-shape failures counted and reported, line 194 closed only if 0 of 100.
4. Either flip 02 as well before the image (it is the node that shows timeouts) or say plainly that the
   timeout fix is so far shown only by mechanism plus 04's air log.

### MAJOR-2 — T1 cannot be built as written: the btmon text never reaches the host, and one span drops the 0x0006 block

Scenario: the harness PR is written from §8 and finds no text to feed `ai_judge`; it is then improvised.

Evidence:
- `scripts/node/prov-p2-254.sh`: `bm_start` writes `btmon -T` to a temp file **on the node**, the arms judge
  it there and `rm -f` it. This covers the `adv-data` arm and every `dep-*` / `power-*` arm of `dep-restart`.
  Nothing is returned to the host, so a host-side offline judge "like `advid-judge-329.sh`" has no input.
- Unit `rpa`: the host fetches only `awk "$AJ_KEEP"` output = MGMT 0x0055 and HCI 0x08|0x0008 / 0x0037 blocks.
  0x0006 / 0x0036 are filtered out before the text leaves the node.
- `prov-provd-254.sh` header: unit `adv-data` is "(by hand; in no suite)". What runs in a suite is the
  adv-data **arm** inside `boot-provd` (line 184). The design's unit list (`adv-data`, `rpa`, `dep-restart`)
  is wrong on one of three and incomplete (boot-provd).
- `rpa` is suite `prov-rpa-254`, about 50 min, tier B.

Fix: state the plumbing. The smallest version: extend the kept-block filter (or add one) to include HCI
0x08|0x0006 and 0x0036, return those blocks from each span that contains a registration, and judge on the host.
Name the spans exactly (boot-provd's adv-data arm, the dep-restart arms that re-register, rpa) and which suite
each belongs to. Keep "no block in the span = FAIL" only for spans that must contain a registration; a span
with no re-registration must not FAIL for that reason — list which arms are expected to have one.

### MAJOR-3 — the hci0 re-appear row cites a test that does not exist

Evidence: §4 says "`bt-uart-305` units run with T1 active, so a wrong value there fails T1".
`scripts/dv/bt-uart-305.sh` and `scripts/node/bt-uart-305.sh` contain no btmon at all. After a UART re-attach the
new `hdev` starts at 0x0800 and nothing in the suite looks at the next 0x0006 block. This is the one path where
the kernel value is reset without a reboot, i.e. the path most able to silently return to 1.28 s.

Fix: either add a T1 span after the #305 re-attach unit (record, wait for provd's re-registration, judge), or
mark the row ❌ not tested with the source reasoning (`adapter_register` → `load_defaults` at `adapter.c:9383`
before the adapter object exists for provd) and drop the sentence. The first is preferred: it is the only
non-reboot reset of the value.

### MAJOR-4 — the known-failures entry as described makes other suites NEW failures on wsl.32

Evidence: `scripts/dv/known-failures.sh` marks a suite KNOWN only if **every** FAIL line of that suite matches
an unexpired entry, and entries are per suite (4 TAB columns in `scripts/validation-known-failures.txt`). T1 will
FAIL inside at least three suites on wsl.32 (the one holding boot-provd, the one holding dep-restart,
`prov-rpa-254`), and in dep-restart once per arm. §8 speaks of one line in one place ("that line goes into
`known-failures.sh`"; the entries live in the `.txt`, not the `.sh`).

Fix: list one entry per suite, with expiry; make the judge print one byte-identical line however many blocks or
spans fail (as `advid-judge-329.sh` does), or the pattern must cover all of them; add an offline test that the
wsl.32 capture yields exactly that one line.

### MINOR-5 — PASS fixture is a hand edit

A PASS fixture edited from the FAIL capture tests the judge against the author's idea of the output. The format
risk here is low (`print_slot_625` verified, same form for 0x0036), but a real one is cheap: the bind-mount flip
of §0 with btmon running gives it. Fix: take the real capture at the next authorised flip, or keep the ⚠️ and
make replacing it a checklist item of the pin PR (not "when the image exists"). The 0x0036 arm has no real
capture and cannot get one on this kernel: say so in the judge's test.

### MINOR-6 — Wi-Fi coexistence: the stated mitigation does not apply to normal use; measure on the bench, not only on site

§6 leans on "the node does not advertise while a phone is connected over BLE". In field use the phone sits on
the node's Wi-Fi and the BLE link is normally closed (the app parks and drops links; provd's `linkGrace` is
30 s). So the node advertises at 100–150 ms during practically all Wi-Fi traffic. The design is honest that
nothing is measured (❌), and the airtime is small, so shipping to a DEV image first is defensible. But the
measurement needs no site visit: iperf over 04's AP with the flip on and off, during T2. Fix: drop the
"while connected" argument from the Wi-Fi bullet, move the throughput check into T2 (bench), keep the on-site
item as the confirmation. Also: "0.9 % of the three advertising channels" is 0.3 % per channel (0.38 ms / 125 ms);
scan responses to nearby actively scanning phones are not counted. Both small; state them.

### MINOR-7 — rollback and first-boot rows claim more proof than they have

- Rollback: "T1's negative control (wsl.32 FAILs T1)" shows an old image is slow, not that new → old returns to
  0x0800. The reasoning (slot switch = reboot = fresh `hdev`) is sound; label it source-only.
- First boot: T1 judges re-registrations later in the suite, not "the first advertisement". Equivalent in
  effect (the value is set once at adapter take-over); word it that way.
- 04 was edited during §0 ("then the image's file"). If that left a copy in the overlay upper, it shadows the
  new image's file if the overlay survives the upgrade; T1 after the OTA would catch it, but check 04 for
  `/overlay/upper/etc/bluetooth/main.conf` before T2 so a FAIL there is not misread.

### MINOR-8 — citation lines

Fix the four citations in the table above (`adapter.c:9383`, `4869-4896` / `4874-4876`, `mgmt.c:8929-8935`,
`hci_sync.c:1900-1906, 1923-1924`). `mgmt.c:8739` names the wrong MGMT command, which matters to a reader
checking the path.

### MINOR-9 — air-log pairing in `snoop.py`

`snoop.py` pairs each create-connection with the next connection-complete of any peer, not by address. With two
nodes in one round this can mis-assign a completion. T2's "create → complete ≤ 0.5 s for every connect" should
pair by peer address before it is used as a pass rule.

## App and system side: nothing found

- Scan path: `ble_backend.dart:27` scans `lowLatency`, plugin `CALLBACK_TYPE_ALL_MATCHES`; each result →
  `BleGate.scan` → `NodeLink._hint` (one sync Rust call, one tag computation per known record, `owner.rs:236`) →
  `core.onScan` (map update; logs once per address per round via `likeLogged`). Ten times more results is tens
  of cheap callbacks per second with several nodes near; no per-result log line, no growth of state.
- No app or provd constant is derived from 1.28 s: connect 5 s / gap 6 s (`core.dart`), msg2 8 s, scan slot
  4 in 30 s, `scanRetry` 500 ms, `closeMax` 5 s, `parkedMax` 120 s, memo expiry 20 min, provd's 2 s
  foreign-instance grace and 30 s `linkGrace`. All are upper bounds that get more slack; none is a lower bound.
- Android scan-start throttling depends on scan starts, not on results: unchanged.
- Rotating identifier: content and rotation untouched; the resolver is stateless per result.
- Security: agree with §7. More packets per second for a direction finder, same identifiers, same rotation; the
  5 GHz AP beacon already gives a stronger, non-rotating signal. No new input, root-only file.
- Unnecessary mechanism: none. Accepting 0x0036 in the judge is one extra pattern and justified.
- Leaving the app's 5 s timeout and retry spacing alone is right for this change; MAJOR-1 decides whether they
  come back.
