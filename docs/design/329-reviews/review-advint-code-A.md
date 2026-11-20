# Code review A — #329 advertising-interval judges (commit 54cc386, parent f89f2e8)

Reviewer A, 2026-11-20. Scope: the whole change (`scripts/node/ble-lib-254.sh`, `scripts/node/prov-p2-254.sh`,
`scripts/node/bt-uart-305.sh`, `scripts/dv/prov-provd-254.sh` comment, `scripts/validation-known-failures.txt`, the two
offline test scripts, `tests/fixtures/advint-329/`). The design (`docs/design/329-adv-interval.md` §8, §11) was taken
as given. No node, no adb, no network host was touched; all mutation work was done in WSL clones under `/tmp/advA`
(made from a git bundle), never in `C:/src/Batman-a4`.

Note on the worktree: while I was reviewing, `C:/src/Batman-a4` gained uncommitted changes that are not mine
(`M scripts/node/ble-lib-254.sh`, `M scripts/test-dv-ble-254.sh`, `M tests/fixtures/advint-329/README`,
`?? tests/fixtures/advint-329/btmon-04-wsl32-dated.txt`). They are the author's fix for finding 1. I reviewed 54cc386 as
committed and, separately, that uncommitted fix (applied to a second clone).

## Verdict

**REJECT for 54cc386 as committed** (finding 1 is a BLOCKER: on today's image all five btmon arms print a NEW line, not
the KNOWN one). With the uncommitted fix that is already in the worktree committed, and finding 2 addressed, this
becomes **APPROVE-WITH-CHANGES**; the rest are MINOR.

## Findings

### 1. BLOCKER — the btmon judge never finds the Command Complete in what the arms really capture (`btmon -T`)

Scenario: every arm captures with `"$1" -T > "$BMF"` (`scripts/node/prov-p2-254.sh:121`). With the date in the header
btmon shortens the event name to `> HCI Event: Command Comp.. (0x0e) plen 4 …`. The judge looks for
`/^> HCI Event: Command Complete/` (`scripts/node/ble-lib-254.sh:409` at 54cc386), so `st[]` stays empty and the result
is the "block N of M … status [no Command Complete]" line. On wsl.32 that is a NEW FAIL in adv-data, dep-bluetoothd,
dep-bluetoothd-kill, dep-dbus and dep-power, instead of the fixed old-image line; on an image with the key it would be a
false FAIL too. The repo already knew about the truncation (`prov-p2-254.sh:167`: "btmon without a terminal truncates
the event name"). The committed fixture `btmon-04-wsl32.txt` was taken without `-T` although its README said `-T`, so
the offline tests could not see it.

Evidence (54cc386 judge, the real `-T` capture now in the worktree, copied to scratch; same output from dash and from
busybox 1.36.1 ash + awk):

```
FAIL adv interval block 1 of 1: min [1280.000 msec (0x0800)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [no Command Complete] (want 100.000 / 150.000 msec, ADV_IND, Success); main.conf has no key
rc=1
```

The uncommitted fix (`/^< HCI / && index($0,"(0x08|0x0006)")`, `/^> HCI Event:/ && index($0,"(0x0e)")`, plus the dated
fixture and one test) is correct as far as I can check: applied to a clone, `test-dv-ble-254.sh` gives
`114 passed, 0 failed`, and on the dated capture (dash and busybox):

```
nokey: FAIL adv interval 1280.000 / 1280.000 msec (want 100.000 / 150.000): image without the interval [..]   rc=1
key:   FAIL adv interval block 1 of 1: … status [Success (0x00)] …; main.conf has the key                     rc=1
dated capture with the two values edited, key:    PASS adv interval 100.000 / 150.000 msec, ADV_IND (1 block) rc=0
same, no key: FAIL adv interval 100.000 / 150.000 msec (1 block) but main.conf has no key                     rc=1
```

It also survives a longer packet index (`< HCI Comma.. (0x08|0x0006) … #123455`, `> HCI Event: Comm.. (0x0e) … #123456`
-> PASS).

Fix: commit that change. Add to it: (a) a PASS case in the `-T` format (the dated fixture with the two values edited —
today the only PASS fixture is in the non-`-T` format, which no arm produces); (b) the PR body must show the five arm
lines from a real wsl.32 run classified KNOWN — the offline suite was green while the judge was wrong on the device, so
only the device run proves this.

### 2. MAJOR — the arm glue is not tested: a judge that is never called, or always prints PASS, keeps every test green

Scenario: the offline tests exercise `adv_int_check` / `adv_sys_check` only. What the arms do with the result is
checked by `grep -c adv_int_arm = 3` (`scripts/test-dv-ble-254.sh`) and one `grep -A2` (`test-dv-bt-uart-305.sh`):
presence checks. Mutations that survive (all tests green, rc 0):

| mutation | result |
|---|---|
| M12 `adv_int_arm` in adv-data replaced by `: adv_int_arm` (never runs) | 113 passed, 0 failed |
| M14 same in the dep-* arm | 113 passed, 0 failed |
| M13 `[ "$a" = dep-power ] &&` removed (power-bondable judged too; the test's name says "dep-power only") | 113 passed, 0 failed |
| M16 `adv_int_arm`: `*) no …` changed to `*) ok …` (every FAIL printed as PASS) | 113 passed, 0 failed |
| S7b `false && adv_sys_check && pass … \|\| no …` (line kept, judge not called) | 50 checks, fails=0 |

M16 is the "passes without checking" path the review rules ask about. The suite-level consequence of M12/M14 on a new
image is a silently missing check.

Fix (either is enough): test `adv_int_arm` itself offline (define `ok`/`no`/`BMF`, take the function from
`prov-p2-254.sh` with `sed -n '/^adv_int_arm()/p'`, assert `PASS …` for the pass fixture, `FAIL …` and `fails=1` for the
old one); and state in the PR body the device evidence per node: exactly 5 arm lines (adv-data, dep-bluetoothd,
dep-bluetoothd-kill, dep-dbus, dep-power) and 10 `rebind N: adv sysconfig` lines + 10 `DET … tries=` lines, none for
power-bondable and none in a `--flip` run. After T2, the same counts as PASS lines are the positive control.

### 3. MINOR — "its Command Complete" (§11: opcode 0x08|0x0006) has no negative control

M11 (`cc && index($0,"(0x08|0x0006)") { ccm = 1 }` -> `cc { ccm = 1 }`, i.e. the status of any Command Complete
counts) passes all tests, on 54cc386 and on the fixed version (`114 passed, 0 failed`). No fixture has another
command's Command Complete between the 0x0006 command and its own. Fix: one generated case — insert a
`> HCI Event … (0x0e)` record for `(0x08|0x0008)` with `Status: Invalid …` between the block and its Command Complete
and expect PASS; and the reverse (own Command Complete refused, a later foreign one Success) expecting FAIL.

### 4. MINOR — `adv_sys_read` (the only code that talks to bluetoothctl) is never executed by the tests

The tests replace `adv_sys_read`, `pidof` and `sleep`. S8 (remove `lim 4` and the `: |` stdin) and S9 (remove the 1 s
sleep) pass (`50 checks, fails=0`). `settings()` has a hang case in `test-dv-ble-254.sh`; this one has none, and a
bluetoothctl that hangs without `lim` would stall a rebind inside its 180 s lease. I ran the real function by hand
with stub `bluetoothctl` under busybox ash: real fixture -> the old-image line, tries=1; hanging stub -> `adv sysconfig
unreadable`, tries=5 unreadable=5 in 33 s (design: <= 35 s), and no stub process left afterwards (checked with a
unique `sleep 777` marker; an earlier "leftover" was my own `pgrep -f` matching its caller); segfault text -> unreadable;
ANSI/CR-wrapped output -> parsed. So the code is right; it is only unguarded. Fix: one offline case with a stub
`bluetoothctl` on PATH that hangs (expect unreadable within ~35 s) and one that prints the fixture.

### 5. MINOR — misattributed status when a block has no Command Complete

`st[++done]` assigns statuses in order. If block 1 has no Command Complete and block 2 has one, block 2's status is
shown for block 1 and block 2 reads "no Command Complete". The result is still FAIL (never PASS, never the KNOWN line
unless every block is complete), only the message names the wrong block. This is from reading the code; I did not run
a fixture for it. Fix: attach the status to the last block seen, or say so in the comment.

### 6. MINOR — small things

- `AS_OK` is set and documented but nothing reads it (`grep -rn AS_OK scripts` -> only `ble-lib-254.sh:441,447,460`;
  shellcheck SC2034). Remove it.
- An awk that prints nothing (awk missing/killed) gives `FAIL ` with empty text from `adv_int_arm` (read from the code,
  not run). Still a NEW FAIL; a text such as "adv interval: judge printed nothing" would be kinder.
- `tests/fixtures/advint-329/README` at 54cc386 says the non-dated fixture was taken with `-T`; it was not (fixed in
  the uncommitted change).

## Checked and found correct

- Suites pass the btmon path to every judged arm (`scripts/dv/prov-provd-254.sh`: boot-provd `j adv-data "$PCD/btmon"`,
  dep-restart for dep-bluetoothd / -kill / dbus / dep-power); the host prefix `FAIL prov-<suite>-254: <arm>: …` that
  the known-failures tests build by hand is what `j()` prints; bt-uart node lines are printed raw and the wrapper adds
  no extra FAIL line.
- Known-failures EREs: anchored `^…$`, literal values, arm list closed. Widening them is caught (M15, S11). The fixed
  lines contain no NEVER_KNOWN word; an empty version (`[]`) does not match `\[[^]]+\]` -> NEW (fail-closed). One
  unreadable rebind among old-image lines -> NEW (tested). Day after expiry -> NEW (tested).
- The KNOWN line cannot appear on an image with the key: both judges print it only with `!key` (M5 caught), and the key
  test is anchored (M9, M10 caught: commented key, `FooMin…`, indented key).
- By design, not a finding: an image that lost the key reads as KNOWN until 2026-12-20; the version in brackets is what
  shows it. `pidof bluetoothd` is checked once, not per try; `lim 4` covers a bluetoothd that dies in between.
- Safety: both judges only read (`mgmt.read-sysconfig`, a file in root-0700 `$H`, `/etc/bluetooth/main.conf`,
  `/etc/batman-build`); no secret is printed; `printf` format is constant; no node state is changed; worst-case added
  time per rebind 33 s, inside the 180 s lease.
- shellcheck (WSL, parent vs commit): 0 errors in all five scripts before and after; new warnings are SC3043 `local`
  (already used throughout), SC2015 `A && B || C` (`pass` cannot fail), SC2034 `AS_OK` (finding 6).
- Not verifiable offline: that the dep-power / dep-dbus / dep-bluetoothd captures on wsl.32 hold only 1280/1280 ADV_IND
  Success blocks (only an adv-data capture is in the fixtures). The device run decides.

## What was run

- `bash scripts/test-dv-ble-254.sh` in a real git clone at 54cc386: `113 passed, 0 failed`, rc 0.
  In the Windows worktree through WSL: 111 passed, 1 failed — the one `FAIL negative controls: the fixed commits are
  not in this clone` (test lines 47–50, `git show fbb14e4~1 / 2ecf1cb`; WSL git cannot read the worktree). It passes in
  the clone, so it is unrelated to this change. The `Terminated` lines come from the existing hang cases.
- `bash scripts/test-dv-bt-uart-305.sh` at 54cc386: `test-dv-bt-uart-305: 50 checks, fails=0`, rc 0.
- Both judges under busybox v1.36.1 ash + awk with the fixtures (old line, key, edited pass, missing file, mixed,
  CRLF capture -> FAIL, no main.conf -> old line) — outputs as the tests expect.
- Mutations (clone restored with `git checkout -- .` after each; "caught (n)" = the test script exited 1 with n
  failing checks):

| id | mutation | result |
|---|---|---|
| M1 | Min/Max read outside the HCI block | caught (3) |
| M2 | Type not checked | caught (1) |
| M3 | Status not checked | caught (2) |
| M4 | PASS without the key | caught (1) |
| M5 | old-image line even with the key | caught (1) |
| M6 | `old > 0` instead of `old == n` | caught (1) |
| M7 | no-block FAIL removed | caught (1) |
| M8 | `[ -s ]` removed | caught (2) |
| M9 / M10 | key grep unanchored / no leading space | caught (3 / 7) |
| M11 | any Command Complete status counts | **survives** (finding 3) |
| M12 / M14 | arm call made a no-op | **survives** (finding 2) |
| M13 | power-bondable judged too | **survives** (finding 2) |
| M15 | dep-restart ERE arm list widened | caught (1) |
| M16 | `adv_int_arm` prints PASS for a FAIL | **survives** (finding 2) |
| S1 | 3 tries | caught (4) |
| S2 | an unreadable try decides | caught (5) |
| S4 | one of the two lines is enough | caught (3) |
| S5 | no pidof check | caught (1) |
| S7 | judged in `--flip` too | caught (1, static grep) |
| S7b | judge call short-circuited | **survives** (finding 2) |
| S8 / S9 | no `lim` / no sleep | **survives** (finding 4) |
| S10 | no key: any readout is the old line | caught (1) |
| S11 | rebind ERE widened | caught (2) |
| S12 | key: 0008 ends the tries | caught (3) |
