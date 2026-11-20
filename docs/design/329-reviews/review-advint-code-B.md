# Code review B — harness(#329) advertising-interval judges

Reviewer B (independent; reviewer A's report not read).
Reviewed: `54cc386` (parent `f89f2e8`) as briefed, and `6cfcd8c`, which landed on the branch while this review was
running and changes the reviewed judge. Binding spec: `docs/design/329-adv-interval.md` §8 + §11 (not under review).

Everything below was run on copies (`git archive` of `scripts/` + `tests/` extracted in WSL `/tmp`). No node, no adb,
no network host was touched; nothing in the worktree was changed except this file.

## Verdict: APPROVE-WITH-CHANGES

One BLOCKER in `54cc386` — already fixed by `6cfcd8c` (fix verified here). One MAJOR (offline tests do not hold three
of the claimed behaviours; code is correct today). Seven MINOR. At `6cfcd8c` the code implements §8/§11 as far as can
be checked offline.

## Result groups

**Verified (output below)**
- Line trace node -> host prefix -> suite log -> `kf_classify` for both judges, by reading and by running the
  known-failures cases.
- Offline tests at `54cc386`, `6cfcd8c`, and the parent, under dash+gawk, mawk, and BusyBox v1.36.1 sh/awk/sed/grep.
- 32 mutations on a copy (31 valid), results in the table.
- Edge probes (two blocks, CRLF, commented key, missing build file).

**Inferred, not run**
- Timing: worst case per rebind 5 x (4 s `lim` + 2 s TERM->KILL) + 4 x 1 s = 34 s, against the 180 s lease / 185 s
  deadman per rebind; x10 rebinds = at most ~340 s added, inside the host limit of 720 s (`bt305_leased "$n" 600`,
  ssh limit secs+120) only if the existing rebind work stays under ~380 s. Read from source; no device timing.
- `lim` kills the whole tree and its watchdog holds no stdout, so `$(adv_sys_read)` cannot hang on the pipe (read from
  `lim_tree`/`lim_kill`, not exercised with a real hung `bluetoothctl`).
- BusyBox here is Ubuntu's 1.36.1, not the node's OpenWrt build.

**Not done**
- Anything on a device: the wsl.32 run that §11 requires in the PR (EREs against real suite-log lines, suite duration
  before/after, DET unreadable totals) cannot be checked by this review. The PR body must carry it.
- Real `/etc/batman-build` format and real `mgmt.read-sysconfig` output were only seen through the fixtures.

## Findings

### 1. BLOCKER (in `54cc386`; fixed in `6cfcd8c`) — the arm's real capture printed a NEW line, not the KNOWN one
Scenario: the arms capture with `btmon -T`. With the date in the header btmon shortens the event name to
`> HCI Event: Command Comp.. (0x0e)`. `54cc386` matched `/^> HCI Event: Command Complete/`, so no status was found and
the judge printed the detailed line. That line does not match the known-failures ERE, so on today's image every arm
would have been NEW instead of KNOWN #329. The only "real" fixture in `54cc386` was taken without `-T` (time-only
stamps) although the README said `-T`, so the offline tests were green.

Evidence (`54cc386` lib on the real `-T` capture added by `6cfcd8c`, dash and busybox identical):
```
new|dash|btmon-04-wsl32-dated.txt|nokey => FAIL adv interval block 1 of 1: min [1280.000 msec (0x0800)] max [1280.000 msec (0x0800)] type [Connectable undirected - ADV_IND (0x00)] status [no Command Complete] (want 100.000 / 150.000 msec, ADV_IND, Success); main.conf has no key rc=1
head|dash|btmon-04-wsl32-dated.txt|nokey => FAIL adv interval 1280.000 / 1280.000 msec (want 100.000 / 150.000): image without the interval [1.5.14-wsl.32] rc=1
head|busybox sh|btmon-04-wsl32-dated.txt|nokey => FAIL adv interval 1280.000 / 1280.000 msec (want 100.000 / 150.000): image without the interval [1.5.14-wsl.32] rc=1
```
Status: fixed. `6cfcd8c` finds records by opcode `(0x08|0x0006)` and event code `(0x0e)` only
(`scripts/node/ble-lib-254.sh:408-409`), adds the real `-T` fixture and a case that fails on the old lib (the first
line above is that negative control, reproduced here). No further change needed for this finding.
Residual: `btmon-edited-pass.txt` (the only PASS fixture) is still in the non-`-T` format; when it is replaced by a
real capture after T2 (README already says so), take it from the arm.

### 2. MAJOR — offline tests do not hold three claimed behaviours (mutations survive)
The code is correct today; these are missing negative controls. Each mutant below passed both offline suites
unchanged (`111 passed, 1 failed` / `50 checks, fails=0`, same as unmutated):

| Mutant | What it breaks | Result |
|---|---|---|
| M12 drop the max check in `adv_int_check` | 100 / 1280 ms would PASS | not detected |
| M13 drop the min check in `adv_int_check` | 1280 / 150 ms would PASS | not detected |
| S7 `adv_sys_check` passes on min = a000 alone | `a000 0008` would PASS | not detected |
| S11 old-image line when only min is 0008 | `0008 f000` without key would print the KNOWN line | not detected |
| M11 status taken from any Command Complete | Success of LE Set Advertising Data would cover a refused 0x0006 | not detected |
| M15 `adv_int_arm` maps every result to `ok` | T1a can never fail in the suite | not detected |
| M17 `adv_int_arm` reads `$BM` instead of `$BMF` | judges the wrong file | not detected |
| M16 `dep-power` guard dropped | `adv_int_arm` runs in every power arm | not detected |

Why it matters: a one-sided wrong value is the likely real failure of the firmware change (a typo in one of the two
keys, or the kernel rejecting one), and M15/M17 are the whole link between the judge and the suite verdict. The
wiring checks are presence checks: `scripts/test-dv-ble-254.sh:337` counts `adv_int_arm` lines (= 3), and
`scripts/test-dv-bt-uart-305.sh:139` greps the literal `cmd_rebind` line (S9/S10 were caught only because the text
changed, not because behaviour was run).

Proposed fix (tests only, no new mechanism):
- `ai_case`: min right / max wrong, min wrong / max right (with key -> detailed FAIL; without key -> not the
  old-image line); a capture where the 0x0006 Command Complete is an error but a neighbouring 0x0008 one is Success
  in the same order as the real capture.
- `adv_sys_check`: readouts `a000 0008` and `0008 f000`, with and without the key.
- `adv_int_arm`: source `prov-p2-254.sh`'s function with stub `ok`/`no` and `BMF` set to each fixture; assert
  `ok`/`no` and the text. For `dep-power`: assert by running the arm selector with a stubbed `adv_int_arm`, or at
  least assert the guard line itself.

### 3. MINOR — Command Complete is attributed by count, not by position
`st[++done]` (`ble-lib-254.sh:414`) gives the k-th matching Command Complete to block k. If an earlier 0x0006 command
has no Command Complete in the capture (capture started/stopped mid-exchange), a later block's status moves up.
Evidence (block 1 without CC, block 2 complete):
```
FAIL adv interval block 1 of 2: min [1280.000 msec (0x0800)] ... status [Success (0x00)] ...; main.conf has no key
```
Still a FAIL (the last block ends with no status), and never the KNOWN line, so the verdict is safe; only the block
named is wrong. Fix: `st[n] = val($0)` (the status belongs to the latest command seen).

### 4. MINOR — `adv_int_haskey` accepts the key in any section and with any value
`printf '[General]\nMinAdvertisementInterval = 0x0800\n'` -> rc 0 (probe). Consequence is only fail-safe (with "key"
the KNOWN line cannot be printed), and a commented key is correctly rejected (rc 1). No change required; recorded so
the comment "only when the file has no key" is read as "no such line anywhere".

### 5. MINOR — empty version / empty awk output give uninformative lines
Missing `/etc/batman-build` -> `...image without the interval []` (probe). `[]` does not match `\[[^]]+\]`, so it is
NEW — correct, but the reason is not stated. If awk prints nothing, the tail prints an empty line and the arm shows
`FAIL ` with no text. Fix (optional): `[ -n "$_l" ] || _l="FAIL adv interval: the judge printed nothing"`.

### 6. MINOR — `AS_OK` is set and never read
`ble-lib-254.sh:441/454`; shellcheck SC2034. The caller uses the return code. Not in the design; remove it.

### 7. MINOR — commit message counts are off
`54cc386` says "29 + 21 new checks". Measured: ble 84 -> 111 (= 27), bt-uart 30 -> 50 (= 20); at `6cfcd8c` 28 + 20.

### 8. MINOR — the offline tests never run the judges under busybox
They run with `sh` = dash and the host awk, while the code runs under busybox ash/awk. I ran them under BusyBox
1.36.1: all new checks pass (28 at `6cfcd8c`, 20 in bt-uart). The suite also shows 4 other failures under busybox
(`settings parse gave []`, `bondable in current line missed`, two `adv-id` cases); they fail identically on the
parent `f89f2e8` (`80 passed, 5 failed` there, `107 passed, 5 failed` on `54cc386`), so they are not from this
change. Whether they are test-side sed/grep differences or node-side bugs was not investigated: unattributed, out of
scope here.

### 9. MINOR — long comment line, README wording
`ble-lib-254.sh:399` is one ~190-column line after the `6cfcd8c` edit. The dated fixture's header shows
`2025-08-14` (node clock without RTC); worth one word in the README so nobody takes it for an old capture.

## Checked and found correct
- T1a line: node `FAIL adv interval ... [ver]` -> `no "<arm>: ..."` via `j()` -> `FAIL prov-boot-provd-254: adv-data:
  ...` / `FAIL prov-dep-restart-254: dep-(bluetoothd|bluetoothd-kill|dbus|power): ...` -> matches its ERE; the
  detailed, no-capture, no-command and "no key but 100/150" lines are NEW (cases run; K2/K3 mutants detected).
- T1b line: printed raw by the host; ERE anchored `^FAIL rebind [0-9]+: ...\[[^]]+\]$`; `unreadable` is a
  never-known word; a mix of old-image and unreadable lines is NEW; expiry day+1 is NEW (cases run).
- The KNOWN line cannot be printed with the key: `old == n && !key` (M5 detected), `_k = 0` branch only (S8 detected).
- No silent skip in the regular run: boot-provd fails explicitly without btmon; dep-restart requires a verified btmon
  before passing it to the four arms; no capture / no 0x0006 command = FAIL (M7, M8 detected).
- `set -u` in `bt-uart-305.sh`: all `AS_*` are assigned before use; `${1:-}`/`${2:-}` defaults present.
- `--flip` runs are excluded from T1b; `DET` line is not a FAIL line.
- Portability: `return` inside the trailing `{ }` of the pipeline returns only from the pipeline subshell, whose rc
  is the function's last status — same under dash and busybox (rc cases pass under both); `local` is already used in
  this lib; awk uses only `index`, `sub`, POSIX classes; mawk and busybox awk give identical lines.
- Security: both judges only read (`main.conf`, `/etc/batman-build`, the btmon text, one mgmt read command); capture
  text reaches only `awk` as data and `echo "$_l"` quoted; no secrets printed; no node state changed.
- No 0x0036 branch, tries fixed at 5, stale comment at `prov-provd-254.sh:44` fixed — as §11 asks.

## What was run
```
# real worktree, WSL
bash scripts/test-dv-ble-254.sh        -> 111 passed, 1 failed   (54cc386)   112 passed, 1 failed (6cfcd8c copy)
bash scripts/test-dv-bt-uart-305.sh    -> test-dv-bt-uart-305: 50 checks, fails=0
# parent f89f2e8 (git archive copy)
ble -> 84 passed, 1 failed     bt-uart -> 30 checks, fails=0
```
The one failure everywhere is `FAIL negative controls: the fixed commits are not in this clone` (+ `Terminated`):
identical on the parent, so not from this change (WSL git cannot read the Windows worktree).
```
# busybox first in PATH (sh awk sed grep head cut tr cat tail -> BusyBox v1.36.1)
old ble: 80 passed, 5 failed    new ble: 107 passed, 5 failed (same 5 lines)    6cfcd8c: 108 passed, 5 failed
new adv_int / known-failures checks ok under busybox: 27 (54cc386), 28 (6cfcd8c); bt-uart 50 checks, fails=0
# mawk as awk: 111 / 1 and 50 / 0
# shellcheck: SC3043 (local), SC2034 (AS_OK); nothing else in the new lines
```

## Mutations (on a copy of `54cc386`; "ble"/"uart" = number of offline checks that turned FAIL)
| # | Mutation | Result |
|---|---|---|
| M1 | read interval labels outside HCI blocks | ble 3 |
| M2 | drop the Type check | ble 1 |
| M3 | drop the status check | ble 2 |
| M4 | PASS without the key | ble 1 |
| M5 | old-image line even with the key | ble 1 |
| M6 | old-image line when any block is old | ble 1 |
| M7 | drop the `-s` guard | ble 2 |
| M8 | drop the no-command guard | ble 1 |
| M9 | rc always 0 | ble 9 |
| M10 | `adv_int_haskey` unanchored | ble 3, uart 3 |
| M11 | status from any Command Complete | **not detected** |
| M12 | drop the max check | **not detected** |
| M13 | drop the min check | **not detected** |
| M14 | only the first block judged | ble 3 |
| M15 | `adv_int_arm` maps everything to ok | **not detected** |
| M16 | `dep-power` guard dropped | **not detected** |
| M17 | `adv_int_arm` reads the wrong file | **not detected** |
| S1 | no key: keep trying instead of deciding | uart 3 |
| S2 | key: first complete non-good readout ends | uart 3 |
| S3 | 3 tries | uart 4 |
| S4 | unreadable not counted | uart 5 |
| S5 | max line may be missing | uart 3 |
| S6 | `pidof` guard removed | uart 1 |
| S7 | PASS on min alone | **not detected** |
| S8 | old-image line regardless of key | uart 3 |
| S9 | `--flip` not excluded | uart 1 (grep of the literal line only) |
| S10 | rebind result always pass | uart 1 (grep of the literal line only) |
| S11 | old-image line when only min is old | **not detected** |
| S12 | an unreadable try decides | uart 2 |
| K1 | rebind ERE loosened | invalid mutant: my edit kept the trailing `\[[^]]+\]$`, so the NEW cases still could not match; says nothing about the test |
| K2 | adv-data ERE loosened | ble 2 |
| K3 | dep ERE without the arm list | ble 1 |

23 detected, 8 not detected (finding 2), 1 invalid.
