# Review r3-A: `329-adv-interval.md` v3 (53d953f)

Reviewer A, round 3, independent. Whole document reviewed, not the delta.
Read-only: no device, node or phone touched; nothing built; no other file changed.

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER, 1 MAJOR, 8 MINOR.
The product change (two `[LE]` keys in `main.conf`, PKG_RELEASE 3 -> 4) is sound and every source line
the design cites checks out. The MAJOR is in the test rules (T1b), not in the product.

## What I checked, and how

Verified against source or captured files (✅):

- **§0 numbers vs the six logcats** (counted with my own script over `BMAPP nl attempt ... connected=Nms result=...`
  lines; 04 = ...7d2c, 02 = ...880c):

  | capture | 04 attempts / fails / median | 02 attempts / fails / median |
  |---|---|---|
  | c1 | 26 / 1 / 1631 ms (max 4211) | 29 / 4 / 1652 ms |
  | c2 | 25 / 0 / 510 ms (max 785) | 30 / 6 / 1639.5 ms |
  | c3 | 6 / 0 (493-883 ms) | 7 / 1 |
  | c4 | 7 / 1 (451-4919 ms) | 7 / 1 |
  | c5 | 3 / 0 | 3 / 1 |
  | c6 | 1 / 0 | 1 / 0 |

  Totals: 04 2/68 failed, 0 timeouts; 02 13/77 failed, 7 timeouts (>= 5.0 s) and 6 fast. `reason : 255` x7,
  `reason : 62` x6. 04 at default = 37 attempts, at 100-150 ms = 31. All match §0 (r2-A F1 is fixed).
- `a4-btmon-04-default.txt:149-150` (MGMT 0x0054, 0.000 msec) and `:180-183` (HCI 0x08|0x0006, 1280.000 msec x2,
  ADV_IND). One 0x0006 block in the capture.
- BlueZ 5.72: `src/main.c:445-470` (`strtol(...,0)`, hex accepted; range warnings 459/465), `:567-580`
  (0x0020-0x4000), `src/adapter.c:4869-4896` (`load_defaults`), `:9353/9379/9383` (order inside `adapter_register`).
- Kernel 6.6.138: `hci_core.c:2470-2471`, `mgmt.c:8929-8935`, `hci_sync.c:1900-1929`, `mgmt_config.c:253-256`,
  `hci_debugfs.c:1011,1041`. No other writer of `le_adv_min/max_interval` (grep).
- Firmware tree (24e63a27): `main.conf` has no `[LE]` and no commented Min/Max lines; Makefile `PKG_RELEASE:=3`,
  no conffiles; `boards/ekh-bcm2710/batman-config.lock:1095,1134` (batman-ble, bluez-daemon not set),
  `ekh-bcm2711` `:5716,:5726` (set).
- Harness: `scripts/node/bt-uart-305.sh` (19, 216-248), `scripts/node/ble-lib-254.sh` (53-59, `settings()`),
  `scripts/node/prov-p2-254.sh` (121-122, 279-319, 321-346, 368-396), `scripts/dv/prov-provd-254.sh` (44, 61-68),
  `scripts/dv/bt-uart-305.sh`, `scripts/dv/known-failures.sh`, `scripts/validation-known-failures.txt`,
  `scripts/daily-validation.sh`. No harness script greps or hashes `main.conf` or depends on 1280 / 0x0800.

Not verified (⚠️ / ❌):

- ❌ Real `bluetoothctl mgmt.read-sysconfig` output on a node, and the 1-in-3 segfault §5 reports.
- ❌ The phone air-log figures in §0 (448 create-connection and the bins). I read `snoop.py` and saw the btsnoop
  files in `br.zip` / `br2.zip`, but did not run it.
- ❌ That a rebind allocates a new `hdev` at 0x0800 (`hci_uart` / serdev path not read) — see F5.
- ⚠️ Round-1 reports were read only through the status tables in the two round-2 reports.

## Findings

### F1 — MAJOR — T1b: an unreadable readout on a file without the keys is undefined, and the tool is known to crash

**Scenario.** §8 T1b retries (up to 5) only when `main.conf` has the keys; on a file without them it is "one try".
§5 itself records a segfault in 1 of 3 `read-sysconfig` runs (❓), and `ble-lib-254.sh` documents the same class
for `mgmt.advinfo` (04 4/30, 02 1/31) and `mgmt.info`. Until the pin PR, both nodes run wsl.32: 10 rebinds x 2 nodes
= 20 single-try readouts per daily run. One crash gives no `000a`/`000b` line at all. The design does not say what
line that produces. If it is an "unreadable" FAIL, `NEVER_KNOWN` (`known-failures.sh`: `...|unreadable|not verified|...`)
makes `bt-uart-rebind-305` NEW on the old image — a false NEW caused by the tool, about once per few daily runs at
the observed rate. If it is any other FAIL text matching the new known-failures entry, a truly unreadable state is
hidden as KNOWN. Either way the verdict is wrong, and it contradicts §5 ("tries again").

**Evidence.** Design §5 (segfault row), §8 T1b; `scripts/node/ble-lib-254.sh` `settings()` comments and 3-try loop;
`scripts/dv/known-failures.sh` `NEVER_KNOWN`.

**Fix.** Split "readout did not complete" from "readout complete with the wrong value". Retry an incomplete readout
up to 5 times on **both** branches; only a complete readout (both 0x000a and 0x000b lines present) decides. Keep
"one try, no retry" only for a complete 0x0800 readout on a keyless file. After 5 incomplete readouts: a FAIL line
whose text is in `NEVER_KNOWN` on both branches. Add the offline case (crash, crash, complete-0x0800 on a keyless
file -> the known FAIL line, not "unreadable").

### F2 — MINOR — T1a call site: `dep-power` shares its case arm with `power-bondable`

**Scenario.** §8 says `adv_int_check` is called unconditionally, one line per arm, in `dep-power`. In
`prov-p2-254.sh:368-394` that arm is `dep-power|power-bondable)`. In `power-bondable`, provd registers only after
`bm_stop` (line 396), so its capture holds no registration. An unconditional call there reports "no block" and FAILs
on every image (and the text would not be a known failure on the new image -> NEW). An implementer following §8
literally hits this on the first run, so it is caught, but the design should say it.

**Fix.** State: call only when `$a = dep-power`, between `bm_stop` (389) and `rm -f "$BMF"` (394). For the three
`dep-*` restart arms state that the call is inside `if [ -n "${2:-}" ]` (no capture otherwise) and that the host
always passes the btmon path (`dv/prov-provd-254.sh` aborts the unit when the upload fails), so "no capture" cannot
pass silently.

### F3 — MINOR — T1b time bound is understated

`lim 4` on a hang costs up to 4 s + 2 s (`lim_kill`: TERM, `sleep 2`, KILL; `ble-lib-254.sh:53-59`). Worst case is
5 x (6 + 1) = 35 s per rebind, 350 s for ten — not 25 / 250 s. It still fits: lease 180 s / deadman 185 s per rebind
(`bt-uart-305.sh:232`), host limit 600 + 120 s. Correct the numbers. Also: `bluetoothctl` waits without bluetoothd,
so follow `settings()`'s `pidof bluetoothd` guard; and say which `rebind_once` the readout follows when line 243
runs a second one (it should be after the last).

### F4 — MINOR — old/new image discrimination by `grep '^MinAdvertisementInterval'`

Not fooled by a commented line (anchored; the shipped file has none) nor by an overlay copy (grep reads the same
merged file bluetoothd reads). It checks Min only: a missing Max reads as "new image" -> NEW, the safe direction.
Two ways it reads "old image" on a new image: a misspelled Min key, or a key with leading whitespace (GKeyFile
accepts it). Then every T1a/T1b FAIL is KNOWN until 2026-12-20; only the human rule in T3 ("KNOWN is a failure on
the new image") catches it. Fix: `^[[:space:]]*MinAdvertisementInterval[[:space:]]*=`, and add to T2 preconditions
one line: `grep -c` of both keys on each node = 1, output attached.

### F5 — MINOR — "a rebind gives a new hdev at 0x0800" has no evidence

§4 (hci0 rebind row) relies on it; nothing cites the serdev re-allocation or a capture. On a passing new image T1b
cannot tell "bluetoothd re-sent the keys" from "the old value survived", so the row's "after" is right either way,
but the stated mechanism is an assumption. Fix: cite the `hci_uart` path, or mark it ⚠️ and record `DET tries=N`
in T2 (N > 1 at least once would show the 0x0800 window exists).

### F6 — MINOR — `adv_int_check` reporting contract is not stated

`ble-lib-254.sh` has `fail()`/`die()` only; `ok`/`no` live in `prov-p2-254.sh` and `no` increments `fails`. The host
`j()` counts `FAIL` lines, so the host verdict is right either way, but with `fail()` the node's own
`PROV-P2 <arm> fails=` line and exit code would disagree with it. State: the function prints nothing and returns
0/1 plus a reason on stdout, the caller does `ok`/`no`; argument is the capture **file** (`$BMF`); the `main.conf`
path is a variable so the offline test can point it at a fixture.

### F7 — MINOR — citations and one number

- `boards/ekh-bcm2710/batman-config.lock` is in the firmware repo, not in this repo; name the repo.
- T2 "before: 1631 / 1640 ms": 02's median with both nodes at default (c1) is 1652 ms; 1640 is c2. Say which.
- `load_defaults` sends with no reply callback (`adapter.c:4869-4896`): a kernel refusal is silent in the log.
  One line in §3 (only T1b / T1a would show it).

### F8 — MINOR — T2 rules

They decide what they claim (0 timeouts on 02 discriminates: 7/77 before; the median rule tests 04). Two fixes:
100 cycles produce about 100-115 attempts per node (c1: 26 and 29 for 25 cycles), so write the limit as a count
over the attempts actually seen, with a minimum attempt count below which the run is void (FAIL, not pass). And
c4 has a **successful** connect at 4919 ms: say the ">= 4.9 s = timeout" rule applies to failed attempts only.

### F9 — MINOR — lifecycle

No missing row that changes behaviour. Two to add for completeness: "clean stop" (nothing persists; N/A with the
reason), and the bound for "advertisement added before the keys reach the kernel" (the instance keeps the interval
copied at Add time, `hci_sync.c:1900-1906`; `adapter.c:9353` vs `9383` makes this impossible today, and it would heal
at the next registration). Wi-Fi coexistence at the shorter interval stays ❌, on the on-site list (accepted in r2).

## Round 1 / round 2 findings

| finding | status in v3 text |
|---|---|
| r2-A F1 MAJOR (c3 mislabelled, 31/37 split) | fixed; recounted, matches |
| r2-A F2-F7, F9 MINOR | answered in the text |
| r2-A F8 (Wi-Fi coexistence) | still ❌, stated as on-site item — accepted |
| r2-B MAJOR-1 (T1b retry rule, hung read, time budget, adapter down) | answered, except the keyless-file unreadable case (F1) and the arithmetic (F3) |
| r2-B MAJOR-2 (known-failures hiding "new image, keys don't work") | answered by the `main.conf` discrimination + T3 rule; residual in F4 |
| r2-B MINOR-3..8 | answered |
| r1 BLOCKER/MAJOR | resolved per both r2 reports; I found nothing in v3 that reopens them |

## Rules check

1. **Ownership** — one writer per resource (`main.conf`: batman-ble package; hdev defaults: bluetoothd; instance
   interval: kernel at Add). Agree.
2. **Contracts** — complete except F6 and the silent-refusal line in F7.
3. **Lifecycle** — F9 only.
4. **Evidence** — all cited lines verified; F5 is the one uncited assumption.
5. **Security** — no new input, no new privilege, no secret; root-only file; debugfs is root-only. Agree.
6. **Tests** — negative control present (old image FAILs T1a/T1b); "nothing to check must FAIL" holds for T1a
   ("no block" = FAIL) once F2 is stated, and for T1b once F1 is fixed.
7. **Necessary changes only** — nothing extra found.
8. **Real use** — fleet OTA, rollback and downgrade rows are right: the file is replaced with the image, no state
   outlives it.
