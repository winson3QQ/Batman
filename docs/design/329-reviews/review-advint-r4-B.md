# Review r4-B: `329-adv-interval.md` v4 (70f0f68)

Reviewer B, round 4. Angle: the person who implements this from the document alone, and the operator who reads
the suite output during an OTA. Whole document reviewed, not the diff.

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER, 0 MAJOR, 9 MINOR.

The product change (two keys in `main.conf`) is supported by source and by the flip test. Every earlier
BLOCKER / MAJOR is closed in the text. What is left are small holes in the judge specifications: each one is a
decision the implementer would otherwise make silently. None gives a wrong verdict if resolved as proposed below;
they can be fixed in the text while implementing (no further review round needed for them).

## 1. What I checked, and how

No device, phone or node was touched (no ssh, no adb). Only this report file was written.

| Checked | How | Result |
|---|---|---|
| `load_defaults` and its call site | WSL, a72 tree `bluez-5.72/src/adapter.c:4869-4896`, `:9383` | as the design says; sent with `NULL` callback (silent on refusal, as §8 says) |
| Key parsing and range | `src/main.c:452-466`, `:566-580` | 0x0020–0x4000, out of range → warn + ignored |
| Kernel default and TLV store | `hci_core.c:2470-2471`, `mgmt_config.c:253-256` | as cited |
| Non-connectable forces 0x00A0 / 0x00F0 | `hci_sync.c:1908-1921` | as cited; the ADV_IND requirement in T1a is needed |
| btmon print format | `monitor/packet.c:2278-2282` (`%.3f msec (0x%4.4x)`); ext variant `:7725`, MGMT `:14337` | as cited |
| `read-sysconfig` exists in bluetoothctl | `client/mgmt.c:1913-1946`, `:6010` | yes; quits `EXIT_FAILURE` on error status |
| Current `main.conf`, `PKG_RELEASE` | `package/batman/batman-ble/files/main.conf`, `Makefile:13` | no `[LE]` group today; `PKG_RELEASE:=3`; not a conffile (`Makefile:6`) |
| The real capture | `Desktop\Batman\a4\a4-btmon-04-default.txt` (1645 lines) | see §2 |
| `rebind_once` / `cmd_rebind`, `lim`, lease | `scripts/node/bt-uart-305.sh:216-248`, `scripts/node/ble-lib-254.sh:45-59`, `scripts/dv/bt-uart-305.sh:67-82` | see §3 |
| Known-failures semantics | `scripts/dv/known-failures.sh`, `scripts/validation-known-failures.txt` | see §4 |
| How node lines become suite lines | `scripts/dv/prov-provd-254.sh:61-68` (`j`), `:184`, `:224-238` | `FAIL x` on the node → `FAIL prov-<unit>-254: <arm>: x`; the suite always passes btmon to the four dep arms and to `adv-data` |
| The arms T1a is put in | `scripts/node/prov-p2-254.sh:279-319`, `:321-347`, `:368-401` | call sites exist as described; details in finding 2 |

## 2. Angle (a): can `adv_int_check` be built from the text? Sketch against the real capture

Layout in the real capture (lines 180-191):

```
< HCI Command: LE Set Advert.. (0x08|0x0006) plen 15  #7 [hci0] 19:14:38.125543
        Min advertising interval: 1280.000 msec (0x0800)
        Max advertising interval: 1280.000 msec (0x0800)
        Type: Connectable undirected - ADV_IND (0x00)
        ...
> HCI Event: Command Complete (0x0e) plen 4           #8 [hci0] 19:14:38.126902
      LE Set Advertising Parameters (0x08|0x0006) ncmd 1
        Status: Success (0x00)
```

- Record headers start in column 1 (`<`, `>`, `@`, `=`, and line 1 `Bluetooth monitor ver 5.72`); every body
  line is indented. "A block ends at the first non-indented line" is enough.
- The Command Complete carries the opcode on its **second** line, so it can be matched reliably: the next
  `> HCI Event: Command Complete` whose second line contains `(0x08|0x0006)`, status on the line after. HCI is one
  command at a time (`ncmd 1`), so "next with this opcode" is the right one even with ACL / MGMT records between.
- The capture holds 6 `< HCI Command` records and exactly **one** `0x08|0x0006` block (one registration, although
  it contains a connection). The MGMT `0x0054` block at lines 143-150 prints the same two labels (0.000 msec) and
  is correctly outside any `< HCI Command` block.

I ran a 12-line awk sketch over the capture (opcode match with `index()`, block = indented lines, Command
Complete matched by its second line): `blocks=1 old=1 ccok=1 pending=0`. So the judge is implementable in busybox
awk as specified. What the text leaves open is in findings 1-3.

## 3. Angle (b): does T1b fit in `bt-uart-305.sh`?

- `lim` is available: `bt-uart-305.sh:20` sources `ble-lib-254.sh`, and `probe()` (`:66`) already uses `lim 10`.
  `lim` prints its timeout line (`FAIL timeout after 4s: …`) on stdout, so capturing with `$(…)` keeps it out of
  the log, as §8 requires.
- Variables at the call site: `i`, `RB_UP`, `flip`, `no` (counts into `FAILS`) all exist in `cmd_rebind`. The
  `e$i` kmsg mark is written before the existing checks, so T1b's time is outside the `r$i`–`e$i` window.
- Lease: `lease_write "$RUN_ID" 180` + deadman 185 at the start of each rebind (`:232`). A normal `rebind_once` is
  a few seconds (unbind, `sleep 2`, probe loop); T1b adds at most 5 × (4 + 2 + 1) = 35 s. 35 s fits. (The baseline
  worst case of `rebind_once` alone — 20 × (1 s + a 10 s probe) — already exceeds 180 s without T1b; T1b only runs
  when `RB_UP = 1`, so it does not add to that path.)
- Suite bound: the 600 s of `acquire` is replaced by the per-rebind 180 s lease from the first rebind on; what
  actually bounds the whole command is the ssh limit `secs + 120` = 720 s (`dv/bt-uart-305.sh:71`). Worst case
  10 × (≈10 s + 35 s) ≈ 450 s. It fits; see finding 5.

## 4. Angle (c): the known-failures flow, step by step

1. Harness PR, node on wsl.32: `adv-data` prints one FAIL line, the four dep arms one each, `rebind` ten. All
   are the fixed old-image lines → KNOWN (#329), exit status still 1. None of the fixed lines contains a
   NEVER_KNOWN word (`restore|cleanup|…|unreadable|not verified|…`). The `DET … unreadable=M` line is not a FAIL
   line, so `kf_classify` never sees it (it reads `^[[:space:]]*FAIL ` only).
2. Any other failure in the same suite (a `seq-bind`, a dep arm that did not re-register) is an unmatched FAIL
   line → the whole suite is NEW. A real failure is not hidden.
3. New image, keys work → PASS. New image, keys present but not effective → different line → NEW.
4. New image where the node's `main.conf` has no key (misspelled key, or an overlay copy shadowing the image's
   file) → the old-image line → KNOWN until 2026-12-20. The design says so and relies on the T3 rule ("KNOWN on
   the new image is a failure") and the grep printed in T2 / T3. That is a rule a person must remember; finding 6
   makes the suite output itself show it.
5. Entries removed by a later harness PR, or expired, or #329 closed (`gh` → NEW): a node still on wsl.32 is then
   NEW. Correct.
6. Healthy node reported broken: only if all 5 readouts die on one rebind (→ `unreadable`, NEW). With the rates
   in `ble-lib-254.sh` E39 (≤ 4/30 per call) that is negligible, and the DET line gives the number.

## 5. Angle (d): T2 against the header claims

- "Timeouts go" → the 0-timeouts rule on 02 (before: 7 in 77). Decides it.
- Line 194 → 0 fast failures in ~200 pooled attempts, written with the bound (3/200 ≈ 1.5 %, correct) and the
  ❓ on the mechanism. Decides it, with the stated limits.
- Line 256, the "4.2 s" half → not tied to a named rule; finding 7.

## 6. Findings

### 1 — MINOR — T1a: Command Complete matching and three result cases are not specified

**Scenario.** §8 says "the `> HCI Event: Command Complete` of each such command must say Success". The
implementer must decide (a) how a Command Complete is matched to its command, (b) what a block **without** a
Command Complete is (capture stopped in between), (c) which block's values go into the FAIL line when several
blocks differ, (d) the verdict for "file without the key, but every block is 100 / 150" (T1b has its own line for
this; T1a by list order gives PASS).

**Evidence.** Capture lines 180-191 (the opcode is on the event's second line); §8 T1a result-line list.

**Fix.** State: matched by the opcode on the Command Complete's second line, the next one after the command;
no Command Complete for a block = FAIL (`no Command Complete`); the FAIL line reports the first offending block
and `(k of N blocks)`; no key + 100 / 150 = PASS (the controller is told the right thing; T1b reports the odd
state) — or FAIL like T1b, but say which.

### 2 — MINOR — T1a call site in the three `dep-*` arms: "unconditionally" conflicts with the optional btmon

**Scenario.** `dep-bluetoothd | dep-bluetoothd-kill | dep-dbus` take btmon as an optional argument; `bm_stop`
and `$BMF` exist only inside `if [ -n "${2:-}" ]` (`prov-p2-254.sh:306-318`). "Called unconditionally, not inside
another check's guard" read literally puts the call outside that `if`, where `$BMF` is unset → FAIL "missing
capture" on every by-hand run without btmon. The suite always passes btmon (`dv/prov-provd-254.sh:231-233`), so
suite verdicts are not affected.

**Fix.** Say: inside the arm's btmon branch, after `bm_stop`, before `rm -f "$BMF"`, and not inside the
`[ -n "$ad" ]` test. In `dep-power`: between `:389` and `:394`, under `[ "$a" = dep-power ]`.

### 3 — MINOR — the `0x08|0x0036` branch is a mechanism with no real input

**Scenario.** This controller has no extended advertising; no real `0x0036` capture can exist on this kernel
(§5 says so), and the fixture is hand-written. "The same two values in its primary interval lines and a
connectable property" is not a specification (btmon's property lines for 0x0036 are not quoted anywhere). If the
kernel ever switches to extended commands, a judge that knows only `0x0006` already fails safe: "no such block =
FAIL (nothing was checked)".

**Fix.** Drop the `0x0036` branch and its fixture (only necessary changes; a stub must have the real tool's
format). Keep one sentence: a capture with `0x0036` and no `0x0006` FAILs as "no block", and the judge is
extended then from a real capture.

### 4 — MINOR — T1b: PASS line, the key regex, and the offline seams are not given

**Scenario.** (a) The PASS line of T1b is not written (the offline cases assert "PASS on the first try",
"PASS, tries=3"). (b) The T1 introduction gives `grep -q '^MinAdvertisementInterval'`, the paragraph after T1a
gives `^[[:space:]]*MinAdvertisementInterval[[:space:]]*=`; two regexes for one rule. (c) T1a has a second
argument for the `main.conf` path; T1b has nothing: the offline test needs the file path, the readout command,
`pidof bluetoothd` and the 1 s pause to be replaceable, in the style of the script's `BT305_*` variables
(`bt-uart-305.sh:22-27`). (d) the loop must not reuse `i`, `k`, `n`, `e`, `r` of `cmd_rebind` / `rebind_once`
or `_t _p _w _r` of `lim`.

**Fix.** PASS `rebind i: adv sysconfig a000 / f000`; the second regex is the rule for both judges (one helper in
`ble-lib-254.sh`); name the seams (e.g. `BT305_MAINCONF`, `BT305_SYSCONF_CMD`, a pause variable set to 0
offline); read through the library's `clean` as `settings()` does.

### 5 — MINOR — the number of tries is left conditional

**Scenario.** "If the worst case cannot fit, the number of tries is lowered to 3 there" leaves the constant, and
with it the offline case "`0008` five times → the 'after 5 tries' line", to be decided during the harness PR.
The cited bound is also not the real one: the 600 s of `acquire` is overwritten by the 180 s per-rebind lease
(`bt-uart-305.sh:232`); the command is bounded by the ssh limit of 720 s (`dv/bt-uart-305.sh:71`).

**Fix.** Decide now: 5 tries. Worst case ≈ 450 s against 720 s; per rebind 35 s against 180 s. Keep the
before / after duration in the PR body as evidence, not as a condition.

### 6 — MINOR — operator view: the old-image lines do not say which image

**Scenario.** During an OTA the fleet is mixed. The suite shows `KNOWN #329` for `bt-uart-rebind-305` and the
two prov suites. Whether that is "02 is still on wsl.32" (fine) or "the upgraded node has no key in its
`main.conf`" (the failure of §4 step 4) cannot be read from the line; the T3 rule exists only in this document.

**Evidence.** The SD6 entry of `validation-known-failures.txt` prints the image version in its fixed line for
this reason.

**Fix.** Append the node's image version to the three fixed lines (`…: image without the interval (<version>)`),
with the ERE accepting `1\.5\.14-wsl\.[0-9]+…` as SD6 does. An operator then sees a new version next to "without
the interval" at once. No new mechanism: one more field in a line that is being defined now.

### 7 — MINOR — T2: which rule ticks line 256, and what a failed rule means

**Scenario.** The header says the 4.2 s half of line 256 is "ticked from T2's output". §8 does not name the
rule. As written, two successful connects of 4.2 s on each node pass (the "up to 2 slower than 1500 ms" rule),
and the line would be ticked. Also not stated: what happens when the hard rule fails (the image is already
shipped by then), and when a node has fewer than 95 attempts.

**Fix.** One sentence each: line 256's connect half is ticked when the median rule and the 1500 ms rule pass on
both nodes, and the slow connects that were tolerated are quoted next to the tick; a failed rule = the line stays
open with the numbers and ❓, the image is not rolled back for it (or is — the user's call, but say it);
fewer than 95 attempts on a node = the run is repeated, not judged.

### 8 — MINOR — offline cases: "every block" and the ERE are not exercised

**Scenario.** The real capture has one block, so no listed case has two. "Every block must…" can be implemented
as "the last block" and all listed cases still pass. And nothing checks that the fixed lines match the EREs that
will be written into `validation-known-failures.txt` (the existing gate test does this for its line,
`test-dv-bt-uart-305.sh:30`).

**Fix.** Add: two blocks, first 1280 and second 100 / 150, with the key → FAIL; two good blocks → PASS
`(2 blocks)`. Add: each fixed old-image line, with the prefix `j()` gives it, is classified `known` by
`kf_classify` against the real file, and the "has the key" variant is classified `new`.

### 9 — MINOR — one citation

`adapter.c:9379` is `fix_storage(adapter)`. The power-on before `load_defaults` (`:9383`) comes from
`load_drivers` (`:9380`) → the policy plugin (`[Policy] AutoEnable = true` in the image's `main.conf`). The
order the design relies on (power first, keys after) holds; only the line is wrong.

## 7. Earlier BLOCKER / MAJOR findings: closed in the text?

| Finding | Closed? | Where |
|---|---|---|
| r1 A-MAJOR-1 / B-MAJOR-1 (line 194 claimed; shapes not split) | yes | header, §0 per-shape table, T2 |
| r1 A-MAJOR-2 / B-MAJOR-2 (T1 not buildable) | yes | T1a is a node function in arms with a full capture; confirmed against `prov-p2-254.sh` and the capture (§2) |
| r1 B-MAJOR-3 (hci0 row cited a missing test) | yes | T1b |
| r1 B-MAJOR-4 (known-failures format / per suite) | yes | §8; format checked against `kf_check` |
| r2 A-F1 (c3 mislabelled) | yes | §0 table and counts |
| r2 B-MAJOR-1 (T1b retry, hung read, time, adapter down / `--flip`) | yes | §8 T1b; arithmetic checked (§3) |
| r2 B-MAJOR-2 (known-failures hiding a broken new image) | yes | key-in-file rule + T3 PASS rule; residual is finding 6 |
| r3 A-F1 / B-MAJOR-1 (one try on the old image; dead readout → false NEW or hidden KNOWN) | yes | 5 tries on every image, only a complete readout decides, "no key but another value" has its own line, offline cases listed |

## 8. Rules check

1. Ownership: one writer per resource; `batman-provhelper` and root-by-hand named. Agree.
2. Contracts: missing / out-of-range / min > max stated; fail-open to 1.28 s with its reason. Agree.
3. Lifecycle: all paths present, not-applicable ones carry a reason; source-only steps are marked ⚠️.
4. Evidence: citations verified except finding 9.
5. Security: no new input, privilege or secret; a compromised provd cannot set the interval (no `-E`). Agree.
6. Tests: negative control = wsl.32; "nothing checked" FAILs in both judges (no block, missing file, unreadable).
7. Necessary changes only: finding 3 (the `0x0036` branch).

## 9. Not done

- ❌ Nothing was run on a node; the busybox-awk sketch ran under Git Bash awk against the saved capture only.
- ❌ The app-side numbers of §0 were not recounted this round (r2 / r3 did).
- ⚠️ The crash rate of `mgmt.read-sysconfig` is still one observation (§5); T1b's DET line will give it.
