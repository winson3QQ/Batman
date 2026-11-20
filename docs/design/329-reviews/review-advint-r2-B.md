# Review r2-B — `329-adv-interval.md` v2 (b538caa)

Reviewer B, round 2. Whole document reviewed, not only the v2 delta. Read-only: no node, no phone, nothing built.
Emphasis as briefed: each actor, and whether each test can pass on a wrong product / fail on a right one.

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER, 2 MAJOR, 6 MINOR.
The product change (two keys in `main.conf`) is sound and every source claim I re-checked holds. Both MAJORs are
in the test plan (T1b as specified; the known-failures entries during validation of the new image). Neither needs
a new mechanism; both are a few sentences in §8 plus a handful of lines in the harness PR.

## What I verified myself (sources: WSL `/home/yello/firmware-2710`, firmware HEAD 24e63a27; harness: worktree `C:\src\Batman-a4`)

| Claim in the design | Result |
|---|---|
| `main.c:570-579` parses both keys, range 0x0020–0x4000; out of range → warn + ignored (`main.c:459/465`) | Verified (bluez-5.72 `src/main.c`) |
| `adapter.c:9383` is the only call of `load_defaults`, inside `adapter_register`; `4869-4896` sends Set Default System Configuration; early return without entries / kernel support (`4874`) | Verified. Note: it is sent with no reply callback, so a kernel refusal is silent |
| Kernel stores TLV 0x000a/0x000b at `mgmt_config.c:253-256`; no range or min ≤ max check | Verified |
| `mgmt.c:8929-8935`: an Add Ext Adv Params without the interval flag takes `hdev->le_adv_min/max_interval` | Verified |
| `hci_core.c` default 0x0800 | Verified (`hci_core.c:2470-2471`) |
| Non-connectable + non-discoverable forces 0x00A0/0x00F0 (`hci_sync.c:1908-1921`), so T1a must require ADV_IND | Verified (the forcing is at 1917-1921) |
| Legacy path always sends 0x08\|0x0006 before enable | Verified (`hci_sync.c:1927-1933`), and in the capture `a4-btmon-04-default.txt:180-183` (1280 ms, ADV_IND) |
| `read-sysconfig` output format `Type: 0x%04x\tLength: %02hhu\tValue: %s` | Verified (`client/mgmt.c:1903-1911`) |
| `batman-ble`: `main.conf` has no `[LE]` today, `PKG_RELEASE:=3`, not a conffile | Verified (`package/batman/batman-ble/Makefile:6,13,33`) |
| First boot ordering (provd cannot register before the keys are sent) — design marks it "source only" | Verified from source and stronger than stated: `adapter_register` queues the config in one main-loop pass (`adapter.c:9378-9384`), and bluetoothd's mgmt client sends one command at a time (`src/shared/mgmt.c` `wakeup_writer`), so provd's later Add Advertising is behind it in the queue |
| Known-failures: suite is KNOWN only if every FAIL line matches | Verified (`scripts/dv/known-failures.sh`) |
| T1a arms hold a capture and remove `$BMF` afterwards | Verified (`scripts/node/prov-p2-254.sh:281,307,329-333`); `j adv-data` / `dep-*` are called with btmon in `scripts/dv/prov-provd-254.sh` |

Not verified (could not, read-only): anything on the nodes or the phone; the §0 numbers beyond the files being
present in `C:\Users\yello\Desktop\Batman\a4\`; the segfault of `read-sysconfig`.

## Findings

### MAJOR-1 — T1b is not specified where it can go wrong: retry rule, hung read, time budget, adapter-down case

T1b is the only proof of the "hci0 re-appearing" row and it runs 10 times per node per day on every bcm2711 node
(`bt-uart-rebind-305`, tier A, all `$BLE_A_NODES`). §8 gives it three lines. Four concrete ways it misjudges:

a. **Readable but still 0x0800 on a correct image.** The suite continues as soon as `probe && mgmt_up`
   (`scripts/node/bt-uart-305.sh` `rebind_once`; `mgmt_up` = `readinfo_powered=1`). In bluetoothd, Set Powered is
   queued by the policy plugin inside `load_drivers` (`adapter.c:9379` → `plugins/policy.c:830-835` →
   `adapter.c:7841`), i.e. **before** `load_defaults` (`adapter.c:9383`), and the commands go out one at a time.
   So "powered" is visible to the probe before the keys are in the kernel. The design says "up to 10 tries" and
   "a readout missing either line after the tries = unreadable", but does not say whether a complete readout with
   `0008` ends the tries. If it does, a correct image prints the fixed "image without the interval" line — a false
   FAIL, and one that is classified KNOWN while the entry exists. The design's own reason for the retries ("takes
   the adapter a moment after the probe answers") is right, but it has no evidence line; the citations above are it.
   Fix: state the rule — retry until `a000`/`f000`, or the tries run out; the last readout decides which FAIL line.

b. **A hung read prints its own FAIL line.** `lim` prints `FAIL timeout after Ns: …` on stdout when it kills the
   command (`scripts/node/ble-lib-254.sh:57`). The design itself saw one hang + "Segmentation fault" in three runs
   (§5). If T1b calls `lim … bluetoothctl mgmt.read-sysconfig` without capturing that output, one hang followed by
   a good retry still leaves an unmatched FAIL line in the suite output → the suite is NEW on a correct image.
   `settings()` in the same library already shows the pattern (output captured, 3 tries).
   Fix: say the read's output is captured and only T1b's own verdict line is printed. Add a `DET`/`NOTE` line
   with the number of tries used, so the hang rate (today ❓ unexplained, 1 of 3) becomes a number.

c. **No time bound.** Each rebind runs under a 180 s lease / 185 s deadman (`bt-uart-305.sh:232`), the whole unit
   under a 600 s lease and a 720 s ssh limit (`scripts/dv/bt-uart-305.sh`, `bt305_leased "$n" 600 rebind 10`).
   With the library's usual `lim 10`, ten tries can take 110 s per rebind on top of the rebind itself (up to
   ~27 s) and `settings_ok` (up to 30 s): close to the deadman, and over the lease for ten rebinds. On wsl.32
   (until the pin PR) every rebind uses all ten tries by rule (a), so ≥ 100 s is added to every daily run.
   Fix: give the numbers — the limit per read (2–3 s is plenty: the good runs return at once), the number of
   tries, and the resulting worst case against 180 s / 600 s.

d. **Adapter down or `--flip`.** When `RB_UP != 1` (the case the suite exists to catch, and what `rebind --flip`
   induces on purpose) there is nothing to read; `bluetoothctl` waits for bluetoothd forever when it is down
   (comment at `ble-lib-254.sh` `settings()`). T1b would burn its tries and add an "unreadable" line to a failure
   that is already reported.
   Fix: run T1b only when `RB_UP = 1` and not in `--flip`; one sentence.

None of this asks for a mechanism beyond what §8 already describes; it asks that the description be the one the
harness PR can be reviewed against.

### MAJOR-2 — the known-failures entries hide "new image, keys do not work" during the validation of the new image

Scenario: the harness PR merges with three issue-329 entries. The firmware PR builds the new image. T3 (full
daily-validation on the shipped image) runs **before** the pin PR removes the entries ("Removed by the pin PR").
If on that image the keys do not take effect — the file was not rebuilt into the image, a typo in a key name
(BlueZ ignores unknown or out-of-range keys with a warning), an overlay `main.conf` shadowing the image's, or the
kernel refusing the command (no reply callback, see table) — T1a prints exactly
`adv interval 1280.000 / 1280.000 msec (want …): image without the interval` and T1b exactly the `0008 / 0008`
line. Both match the entries. All three suites are classified KNOWN, on the image the test was written to judge.
The fixed text asserts "image without the interval" but the judge has not looked at the image.

The existing harness distinguishes old images by something read from the node, not by the symptom (the `#305`
gate reads a feature marker; other entries name "pre-P2 image").

Fix, either is enough:
- the judges print the fixed old-image line only when `/etc/bluetooth/main.conf` has no
  `MinAdvertisementInterval` key (one `grep` on the node; with the key present and 0x0800 seen, the line is a
  different one and therefore NEW); or
- no code: §8 T3 states that on the new image the three suites must be **PASS**, KNOWN counts as a failure of the
  image, and the entries are removed in the same harness change that is used for that run.

Also state the expiry date (the design says "with an expiry"; the file needs `YYYY-MM-DD`), and that the 329
entries must not widen the existing `prov-boot-provd-254` / `prov-dep-restart-254` EREs for the pre-P2 image.

### MINOR-3 — T2: what 100 attempts can and cannot show

- Timeouts on 02: baseline 7/77 (9 %). 0 in 100 at that rate has probability about 1e-4: a sound rule.
  On 04 the baseline had 0 timeouts in 68, so "0 timeouts" on 04 discriminates nothing; the median rule
  (1631 ms → ≤ 800 ms) is what decides on 04. Say so, so a reader does not count it as two confirmations.
- Fast failures: baseline 8/145 (5.5 %; 04 alone 2/68 = 2.9 %). 0 in 200 pooled bounds the rate below about
  1.5 % (95 %), and is very unlikely at the old rate (about 1e-5) — enough to say "reduced", not "gone". Per
  node it is weaker: at 04's old rate, 0 in 100 happens 1 time in 20. The design gives no mechanism by which the
  interval would remove this shape. Fix: if 0 → close line 194 with the bound written in the issue
  ("0 of N, < 1.5 %"), judged on the pooled count; keep the per-node counts as reported data.
- `max ≤ 1500 ms` over 100 attempts per node is a rule on the single worst sample; the only data at the new
  interval is n = 25 (max 785 ms). One slow-but-successful attempt (1.5–4.9 s: phone scan pause, a retry) fails
  T2, and the design has no rule for it: it is neither a timeout nor a fast failure. Fix: state what happens —
  the attempt is listed with its air-log lines and attributed (create → complete time on the air vs time before
  the create), or use a percentile.
- The negative control is §0 (another session). Acceptable — a same-session control would need a re-flash — but
  the PR body should say the two sides were not measured in one session.

### MINOR-4 — T1a runs on 04 only

The `prov-*` units are bound to 04 (`scripts/dv/prov-provd-254.sh`, `DNODE`). What the controller is told is
therefore never checked on 02; 02 has T1b (kernel value) and T2 (behaviour). §4's last row ("T1 runs on whatever
board the suite runs on") reads wider than that. One sentence in §8.

### MINOR-5 — T1b proves the kernel value, not the advertisement after the re-attach

The hci0 row's proof is "the kernel value is read back". That the re-registered advertisement then uses it
follows from the command order (table above: one queue, config before provd's Add), which is source-only. Label
it so in the row, as the first-boot row already is.

### MINOR-6 — where the offline sysconfig tests live

§8 puts them in `scripts/test-dv-ble-254.sh`. The function is in `scripts/node/bt-uart-305.sh`, which
`scripts/test-dv-bt-uart-305.sh` already loads whole with `BT305_LIB_ONLY=1`; `test-dv-ble-254.sh` pulls single
one-line functions out of `prov-p2-254.sh` with `eval "$(grep '^name() ' …)"` (line 284). Put the sysconfig cases
in `test-dv-bt-uart-305.sh`; for `adv_int_check`, note that it must be loadable the way that file loads functions
(a multi-line awk function is not picked up by that `grep`). Add the two cases from MAJOR-1: "complete readout,
0008, then a000 on the next try → PASS" and "hung read then good read → no stray FAIL line".

### MINOR-7 — Wi-Fi on the same chip is still ❌, and stays the user's

Round-1 B-MINOR-6 (measure throughput in the bench session) was not adopted; the reason given (needs a Wi-Fi
client; the phone's Wi-Fi is the user's) is fair. It is the one cost of this change with no number, on the path
every user is on all the time. Keep it visible: an unchecked item in #329's checklist, not only the PR body.

### MINOR-8 — hand-edited PASS fixtures until the pin PR

The PASS side of T1a and T1b is judged offline only against edited text until a real capture exists (stated,
marked ⚠️). Accepted, with one condition that the design half-states: the harness PR's own results section must
say that no PASS of T1a / T1b has been seen on a real node yet, and the pin PR's checklist item must cover both
fixtures (btmon and sysconfig), not only btmon.

## Actors

- Remote attacker: no new input; more packets per second of the same rotating address. Agree with §7.
- Local unprivileged process: cannot write the file or the mgmt value. It can **read** the value
  (`read_def_system_config` is `HCI_MGMT_UNTRUSTED`, `mgmt.c:9397-9398`); nothing secret in it.
- Compromised provd: `-E` is not set (`bluetoothd.init`: `-n --noplugin=…`), so the per-advertisement interval
  properties stay ignored. Nothing new.
- root by hand: `mgmt` and debugfs (`hci_debugfs.c:1011,1041`) can change the value; the next bluetoothd restart
  rewrites it. This is the one place the change improves on today.
- Physical capture, supply chain: nothing new.
- Our own mistakes: this is where both MAJORs sit (a wrong or ineffective file judged KNOWN; a test that
  misfires). The §4 note about "removing the keys does not restore 1.28 s on a running node" is the right warning.

## Round-1 findings

| Finding | Status in v2 |
|---|---|
| A-MAJOR-1 / B-MAJOR-1 (line 194 claim; failure shapes) | Resolved (§0 table, T2 per-shape rules). Residual: MINOR-3 |
| A-MAJOR-2 / B-MAJOR-2 (T1 not buildable) | Resolved: T1a is in arms that hold a capture; confirmed against the scripts |
| B-MAJOR-3 (hci0 row had no test) | Resolved in substance (T1b); its specification is MAJOR-1 |
| B-MAJOR-4 (known-failures per suite) | Resolved as to file, format, per suite; new concern MAJOR-2; expiry date still not given |
| MINOR citations | Resolved; all re-checked, see table |
| MINOR c4 numbers, D-Bus / provd wording, value choice, ADV_IND requirement, airtime | Resolved |
| MINOR `snoop.py` pairing by peer address | Resolved (T2) |
| MINOR rollback / first boot source-only | Resolved (labelled); first boot now also checked by me from source |
| MINOR min > max untested | Resolved (labelled ⚠️; guarded by fixed values) |
| MINOR hand-edited PASS fixture | Not resolved, deferred to the pin PR with a marker — accepted, MINOR-8 |
| B-MINOR-6 Wi-Fi coexistence in the bench session | Not adopted, reason given — MINOR-7 |

## Unnecessary mechanisms

None found. The T1b retries are needed (MAJOR-1a shows why); the 0x0036 branch of T1a is cheap and marked as
unproven on a real capture.
