# PR D2 — code review round 2, Reviewer A

Reviewed: my checkout `C:/src/Batman-d2-revA` at `7aea4be` (whole PR vs base `b64f5b1`: 20 files, +4876/−238; and the
round-1→2 delta), the runbook `docs/255-rig-runbook-e4.md` and design §8.3/§8.4 in `C:/src/Batman-e13`, the E4 raw
outputs in `Desktop/Batman/255-rig-runbook/results/`. Everything marked "ran" was executed in WSL Ubuntu-24.04,
go1.26.4, `-mod=vendor`, on the fake chip only. No device or LAN host was contacted. Scratch files are under
`scratchpad/revA3/`. Status: complete.

Summary: **0 BLOCKER / 0 MAJOR / 9 MINOR**. Verdicts in §5: merge APPROVE-WITH-CHANGES; runbook §4–§12 APPROVE-WITH-CHANGES.

---

## 1. Round-1 findings: status

(evidence column: what I ran or read in this round)

### Reviewer A, round 1

| R1 | Status | Evidence (this round) |
|---|---|---|
| A-M1 dry run guarded once per command, three untested | **Fixed** | Invocation tiers in `run()`; mutants "lock-data / lock-slot / update-extra / counter-inc dry block removed" each KILLED (`TestDryRunSendsNothingForGood`, `TestExperimentWalk`); "rewritable policy lets for-good through" KILLED (`TestInvocationPolicies`); "for-good tier also in a dry run" KILLED (`TestInvocationPolicyTier`). Two layers, each with its own control. |
| A-M2 allow list tested for lock-slot only | **Fixed** | `TestAllowListBindsEveryChangingCommand` iterates the table; mutants in §4 |
| A-M3 `Provisional` false for six unconfirmed commands | **Fixed as far as this PR can** | `se608.ProvisionalCmds = true` (`se608/cmds.go`); impl §2.2 now says PR 2's CI fails on it. Nothing in this PR fails while it is set (by design: se608's own tests must stay green). ⚠️ I did not check that the #255 checklist carries it. |
| A-m1 printed packet built by other code | **Fixed** | one `Cmd` printed and sent; `sentAs` in the walk; mutants "lock-data sends another CRC than printed", "lock-slot sends slot+1" in §4 |
| A-m2 counter id | **Fixed** | walk asserts `chip.Counters`; literal runbook run ends with `counters=[0 1]` |
| A-m3 `=locked` from bytes for lock-slot only | **Fixed** | `TestLockResultComesFromTheChipsBytes` over `lockCases` (all three Locks) |
| A-m4 lost Lock answer | **Fixed** | `LOCKED_answer_lost`, tested for all three; runbook §3 row |
| A-m5 result key collides with header | **Fixed** | `<cmd>_result=`; the E4 real run printed `lock_config_result=locked` |
| A-m6 lock-slot checks no state | **Fixed** | slots 4/5/6 only, both zones locked, prints SlotConfig/KeyConfig/lockable/already-locked; mutants in §4 |
| A-m7 `counter-inc 0` | **Fixed** | refused; mutant in §4 |
| A-m8 redundant pre-checks untested | **Fixed** (byte-17 check left, as agreed) | tests listed in `prD2-changes.md` exist (`TestForGoodRefusals` cases) |
| A-m9 failed re-read reported as Lock status | **Fixed** | `errReRead`, `TestLockConfigReReadFailure` |
| A-m10 72-byte tail addressing | **Fixed** | `se608/cmds_test.go:423-428` non-zero 72-byte slot |
| A-m11 secert serial / unique IDs | **Fixed** | serial 1–8 and canonical re-encoding; my 20 000-mutant run: 0 panics; mutants in §4 |
| A-m12 fake behaviours without source | **Partly** | marked "inferred", `SecretTailReadOnly` knob + `TestSecretTailWriteRefusedIsReported`. New gap: the fake's watchdog does not charge the new Lock poll time (N-m2 below) |
| A-m13 tool cannot say what build it is | **Fixed** | `tool_rev=7aea4be0…` in every rig output; I rebuilt the rig binary bit-for-bit (§3). Dirty-tree path untested (known item b) |
| A-r1 E11 wrote Counter[0]'s word | **Fixed** | §6 writes words 15 and 16 |
| A-r2 dry runs without expected packets | **Fixed** | every dry run lists a packet; all 8 recomputed by me (§3) |
| A-r3 no lost-answer row | **Fixed** | §3 table has a row per result line |
| A-r4 `-allow` and `-serial` from one variable | **Fixed** | §1.2 compares `info`'s serial with `e1-info.txt` on paper |
| A-r5 E12 before E13/E15 | **Fixed** | E12 last; design §8.1 notes the deviation |
| A-r6 rows missing | **Fixed** | rows for `ecdh 2 compat`, `sign-internal 4/2` |
| A-r7 E15 narrower | **Fixed** | design E15 row states it |

### Reviewer B, round 1

| R1 | Status | Evidence |
|---|---|---|
| B-M1 `rc=` is tee's | **Fixed** | §1.2 `set -o pipefail` + self-check; rig output `selfcheck rc=1` (`e4-p-checks.txt`, `e4-after-power.txt`) |
| B-M2 protections without negative control | **Fixed** | as A-M1/A-M2 |
| B-M3 Lock polled 35+20 ms | **Fixed, introduced two MINORs** | `LockPoll` 500 ms, retries, one result line; tested. But: the fake's watchdog still charges Lock 35+20 ms (N-m2) and the timing tests run on the wall clock and flake under load (N-m1) |
| B-m1 E11 word | **Fixed** | |
| B-m2 Provisional | as A-M3 | |
| B-m3 se-fail half | **Accepted, recorded** | impl §2.2 states the PR-2 half |
| B-m4 key collision | **Fixed** | |
| B-m5 counter 0, update-extra early | **Fixed** | mutants in §4 |
| B-m6 rewritable writes to lock bytes | **Fixed** | `protectedConfigWrite`; `TestInvocationPolicies`, `TestRewritableCommandsCannotSendForGood`; mutants in §4 |
| B-m7 lock-slot gives nothing to check | **Fixed** | dry run prints the slot state; the runbook lists every value |
| B-m8 PolicyBurn any slot | **Fixed** | slots 0–2; mutants in §4 |
| B-m9 PolicyDaemon mode only | **Fixed** | slot and length pins; mutants in §4 |
| B-m10 secert | **Fixed** | as A-m11 |
| B-m11 DataCRC private-slot rule invisible | **Fixed** | `se608/cmds_test.go:430-433` |
| B-m12 other survivors | **Fixed except N14** (accepted with reason) | |
| B-m13 E9/E10 order | **Fixed** | |
| B-m14 smaller runbook gaps | **Fixed** | `-expect-crc be96`; §6 "read first"; E15 note |

### Items the brief says were already found (judged, not re-found)

- (a) first Dev built with the for-good policy under the name "rewritable": see §4 — with the timing flake removed
  it SURVIVES; each command's own dry check still stops it. MINOR, folded into N-m3.
- (b) dirty tree in `tool_rev` untested; (c) a worktree on /mnt/c gives `tool_rev=unknown` (I reproduced: my
  worktree build has no vcs stamp and a different sha256). The runbook's §1.2 check (`tool_rev=` must equal the commit)
  then stops the operator — fail-closed, but §1.1 should say "a clone, not a worktree". MINOR, N-r1.
- (d) own-policy-refusal branch and `status_XX_but_LOCKED` untested: confirmed by mutants (§4). MINOR, N-m3.

---

## 2. New findings

No BLOCKER, no MAJOR. I found no path by which this commit sends a Lock, a Counter increment or an UpdateExtra the
operator did not ask for with `-allow` + `-serial` and without `-dry-run`; no wrong packet among the eight the
runbook will send from §4 on; and no case where it prints `_result=locked` while the chip's bytes say otherwise.

### MINOR — code and tests

**N-m1. The two tests that pin the new Lock polling run on the wall clock and fail under load; the 500 ms itself is
pinned only by a constant range.** `se608/cmds_test.go:531` (`TestLockIsPolledPastTheTable`, `SlowLockPolls = 200`
"polls of 1 ms") and the `SlowLockPolls = 150` case of `TestLockResultComesFromTheChipsBytes` use a `Dev` with
`time.Sleep` / `time.Now`, so "200 polls" is however long 200 sleeps of 1 ms take. Evidence: while my probe tests
ran in parallel, these two tests failed for mutants that cannot affect them (a `cmd/se-lab/main.go` change failing
`TestLockIsPolledPastTheTable` in package `se608`; a `lab.ForGood` change failing it too). Flip: the same mutant 6,
re-run with nothing else running, passes every test. ❓ I could NOT reproduce a failure on the unmodified code
(12 busy loops on 4 cores, `-count=5`; and three full suites run two at a time: all `ok`, `revA3/flake*.out`), so the
cause is load-sensitivity by the code's construction plus one flip, not a clean-code reproduction. The probe in §3
shows 380 fake polls taking 540 ms of real time. Fix: `d.SetClock` with a fake
clock (sleep advances now), then assert the boundary by behaviour: a Lock answered at 519 ms gives `locked`; at
521 ms `LOCKED_answer_lost`. That replaces the `400 ms <= LockPoll <= 550 ms` range check and cannot flake.

**N-m2. The fake's watchdog still charges a Lock the table's 35 + 20 ms, while the driver now lets it run 520 ms; its
own comment ("a sequence that could outlast the watchdog on a slow chip fails here") is no longer true for Lock.**
`fakechip.go:203-204` charges `se608.MaxExec(op) + 20 ms`; `MaxExec(OpLock)` = 35, while `LockConfigCmd`,
`LockDataCmd`, `LockSlotCmd` use `LockPoll` = 500. se-lab's own sequences are fine (lock-config: 4 x 25 + 520 =
620 ms < 700 ms; lock-data and lock-slot: the Lock alone). The exposure is PR 2's burn mode built on these
primitives: config §5.2 S2 is "GenKey, read the public key, lock the slot"; written as one `Do` it is 135 + 135 + 520 =
790 ms worst case. Ran (`TestRevA3WatchdogLockCharge`): GenKeyCreate + PubKey + LockSlot in one `Do`, Lock answered
late: 540 ms of real time, the fake's 700 ms watchdog never fired, slot locked. On the real chip the likely outcome
is a 0xEE refusal or a lost answer (facts §9: the chip refuses a command it cannot finish), i.e. safe, but a burn
step that fails on the bench and never on the fake. Fix: charge `se608.LockPoll + 20 ms` for `OpLock` in the fake,
add the GenKey+PubKey+Lock control that must fail at 700 ms, and say on `Session.LockConfig/LockData/LockSlot`
"uses up to 520 ms of the 0.7 s sequence budget: keep a Lock alone or after short reads".

**N-m3. No negative control for five details** (the brief's items a and d, plus two of mine; all SURVIVED, §4):
building the first `Dev` with the for-good policy while the tier name stays "rewritable" (#6); dropping the
own-policy-refusal branch of `afterLock` (#31); reporting `status_XX_but_LOCKED` as `locked` with exit 0 (#30);
lock-slot's "locked" predicate also true when the *neighbouring* slot is locked (#37) — in the runbook's own order
(§9: lock 6, then lock 5) that would turn the expected `lock_slot5_result=status_0f` into `status_0f_but_LOCKED`,
and no test locks one slot after another; `update-extra` accepting mode 3 (#24; the chip would refuse an undefined
mode, so low). Today each is
backed by something else (each command's own dry check; the refusal still exits non-zero; a chip that answers a
status and locks anyway is not a known behaviour). Fix: `TestInvocationPolicyTier` should probe the installed
policy, not its name (e.g. an `env` hook that runs `c.d`'s policy on a Lock `Cmd` and records the error), and add the
two afterLock cases (a policy that refuses the Lock: rc 3, no `_result=` line; a fake knob that answers 0x0F but locks:
`status_0f_but_LOCKED`, rc 1).

**N-m4. update-extra and counter-inc report a lost answer on stderr only and never read back; a chip refusal exits
0.** Ran (`TestRevA3ForGoodAnswerLost`): `update-extra 1 a0` with the answer corrupted: chip byte 85 = `a0`; output
is the packet plus `se-lab: update_extra_mode1: ... CRC mismatch`, rc 1, no `byte85_after=`. `counter-inc 1` the
same (Counter[1] = 1). With byte 85 already set: `update_extra_mode1=status_0f` and rc **0**. The lock commands got
`afterLock` for exactly this (B-M3); the other two for-good commands did not. The runbook covers it only through the
general §1.4 rule, and §1.4's `info` shows neither byte 85 nor Counter[1] (N-r2). Fix: after sending, always read
the bytes back (84/85, or the counter) and print one `update_extra_result=` / `counter_inc_result=` line from them;
exit 1 on a status where the runbook needs success (§12), or document exit 0 in the header.

**N-m5. `secert.Parse` now depends on Go's x509 encoder byte for byte, and no golden certificate pins it.** Parse
re-encodes with `x509.CreateCertificate` and requires an identical TBS. Within one binary that is exact (Build calls
Parse. Ran: 600 Build then Parse with random keys, serials and issuer CNs including `é`, `@x`, `a*`: 0 failures;
20 000 random mutants: 0 panics; cost about 0.1-1 ms per call). Across toolchains nothing guarantees it: a Go upgrade
that changes how CreateCertificate encodes anything in this profile makes every certificate burned by an older
se-sign fail Parse on a node built with the newer toolchain, and per config §5.3 a certificate cannot be replaced
without a reflash. Fix: commit one DER built today (`secert/testdata/golden.der` and its Keys) and assert Parse
accepts it and returns those Keys; the toolchain bump then fails in CI, not on the bench.

### MINOR — runbook and design record

**N-r1. §1.1 does not say "a clone, not a worktree".** Built in a git worktree on /mnt/c the binary has no VCS stamp
(`tool_rev=unknown`; reproduced: my worktree build is `00ea833c…` with no `vcs.*` lines). §1.2 then stops the
operator (fail-closed, good), but the reason is not written down. Say: build in a clone on the WSL file system;
`tool_rev=` must be the 40-hex commit with no `+modified`.

**N-r2. §12 (E12) has no row for a lost answer, its for-good line records no `rc`, and §1.4's recovery step cannot
show what is needed.** §12's `update-extra 1 a0` has no `echo "rc=$?"`, and the next step is the power cut, the one
step that can make the chip leave 0x60. If `update_extra_mode1=` is missing (N-m4), §1.4 says "run `info`", which
prints only the lock bytes. Add: record rc; "no `update_extra_mode1=` line: do not power-cycle, run `./se-lab dump`
(byte 85 is the 6th byte of `config[ 80]`), stop". For §6 the preamble already says "read `counter-read 1` first".

**N-r3. The §5 and §8 loops filter out `tool_rev=`.** The `grep -v '^tool_rev=\|…'` drops the build id from
`e8.txt`, `e9.txt`, `e10.txt`, against the runbook's own "every output carries tool_rev". Filter only
`revision|serial|lock_config|lock_data`, or run `./se-lab info` once at the top of each file.

**N-r4. Design §8.4 states two things the raw outputs do not show.** "新 `boot_id`": `e4-power-cut.txt` records only
`before: boot_id=bd5cd417…`; no post-boot boot_id is in any results file (the reboot evidence that is there:
`up 1 min`, `get_rsts=1000`). "乾跑後仍 55/55": the lines appear only in the hand-assembled `results/e4-dry.txt`
(after `rc=0`, without their own header), not in `rig-shm/e4-dry.txt`. Both are probably true; the record should
carry the raw lines or say what the evidence is. Everything else in §8.4 matches the raw files (§3).

### Notes (no finding)

- Flag semantics: `-dry-run=0`, `-dry-run=false`, or `-dry-run ... -dry-run=false` make an invocation real (Go's
  flag package, last value wins). Ran: each sent the Lock when `-serial` was also given. The runbook never uses them;
  a dry run without `-serial` cannot send in any spelling (refused before the bus).
- `afterLock`: if the Lock succeeds but `Do`'s idle write fails, the result is `LOCKED_answer_lost` (rc 1): a
  conservative mislabel; the runbook row ("do not send again") is right for it.
- PolicyDaemon / PolicyBurn against config §5.2 and impl §2.1: everything the daemon needs (Info, Read incl. slot 8,
  Nonce pass-through 32 B, GenKey public 0-2, Sign external slot 0, ECDH slot 2 clear 64 B, CheckMac slot 5 77 B) and
  the burn mode needs (plain Write, Lock config/data with CRC, Lock slot 0-2, GenKey create 0-2, CheckMac slot 5) is
  allowed; nothing else.
- Secrets: no key material on any command line, in logs or in the diff; se-lab's test values derive from the serial
  (not secret, stated); the runbook passes only the serial, a CRC and hex patterns. Nothing to report.

---

## 3. What I verified, and how

- ✅ Build / tests (ran, clean checkout 7aea4be): `go vet` OK; `go test -count=1 ./se608/... ./secert/ ./cmd/
  ./cmd/se-lab/` all ok, same with `-tags prov_test` (`revA3/base.out`).
- ✅ **The rig's binary is this commit, bit for bit (ran).** Sparse clone of 7aea4be on WSL ext4,
  `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath`, go1.26.4:
  `0eeaf15eca0588bb5810bba208a7c31e375cf9301fb2d3232466f6ee11881140`, `vcs.revision=7aea4be0…`, `vcs.modified=false`
  — equal to the sha256 recorded on the rig (`e4-p-checks.txt`, `e4-after-power.txt`). The temp clone in WSL /tmp was
  deleted afterwards.
- ✅ **E4 raw outputs vs design §8.4 (read + recomputed, `revA3/indep3.py`, my vendor-atCRC port).**
  `rig-shm/e4-dump.txt` differs from `e3-verify.txt` only at byte 87 (55 → 00); its CRC with byte 87 = 55 is `9022`;
  serial `0123ba99e2ca248cee`. `e4-lock.txt`: `lock_packet=03 07 17 00 22 90 1d 15`, `lock_config_after=00`,
  `lock_data_after=55`, `slot_locked_after=ffff`, `lock_config_result=locked`, `rc=0`. After: `config_write_word17=status_0f`,
  two different `random=` values, `write-image` rc 3; power cut 61 s, four readings `0.0W`, `get_rsts=1000`,
  `up 1 min`, scan `60`. All §8.4 rows hold except the two in N-r4.
- ✅ **Runbook §1–§12 literally (ran, `cmd/se-lab/reva3_runbook_test.go` in my checkout, output `revA3/runbook.out`).**
  The 83 `./se-lab` lines are extracted from the markdown file itself (sh blocks, both for-loops expanded) and run
  in order on `fakechip.RealBlank()` after write-image; the expectation list is hand-written from the tables in the
  same order and the extracted list equals it. Every key=value and every stated rc is what the tool prints. For-good
  packets that reached the fake: exactly 8, in order `03 07 17 00 22 90 1d 15`, `03 07 17 01 96 be 26 70`,
  `03 07 24 01 01 00 06 f7`, `03 07 20 02 00 00 03 f8`, `03 07 17 12 00 00 8e 08`, `03 07 17 1a 00 00 cd 89`,
  `03 07 17 16 00 00 0d 8a`, `03 07 20 01 a0 00 03 e9`; final `counters=[0 1]`. All 8 equal my own recomputation
  (private-slot set {0,1,2,4} taken from the real chip's E4 dump) and the author's `indep-forgood-packets.py`
  (`be96` / `3c9f` for OTP fill 00 / ff). ⚠️ What the fake answers from §4 on is the design's expectation, not a
  measurement; hmac / kdf / aes answer `status_03` (not modelled).
- ✅ Probes (ran, `revA3/mod` = archive of 7aea4be; `probe.out`, `probe2.out`): flags, lost answers, the watchdog
  charge, secert canonical form, cost — results quoted in the findings and notes above.
- ❌ Nothing ran on the real chip; no device or LAN host was touched.

## 4. Mutants (61 tried; script `revA3/mut.py`, raw `revA3/mut.out`; each = go vet + `go test -tags prov_test` over
se608/..., secert, cmd, cmd/se-lab; a mutant counts as killed only on `--- FAIL`)

KILLED (52): the four dry blocks (lock-data, lock-slot, update-extra, counter-inc); rewritable policy letting
for-good through; for-good tier in a dry run; `lab.ForGood` missing Counter-inc / UpdateExtra; `protectedConfigWrite`
never (v2) / word 21 dropped / block 2 dropped / missing from the for-good policy; allow list unchecked / unchecked
for for-good commands; serial not compared / prefix accepted / not required; counter-inc 0; counter-inc before the
config lock; lock-slot any slot / slot 8 added / before the data lock; update-extra before the data lock; lock-data
`-expect-crc` ignored / `-otp-fill` ignored / sends another CRC than printed; lock-slot sends slot+1; afterLock:
locked from status alone, one read-back try, UNKNOWN exits 0, lost-but-locked reported locked, not-locked-after-
success exits 0, lock-data predicate = config byte; LockPoll 35 ms and 900 ms; PolicyDaemon: Sign / ECDH / CheckMac
any slot, GenKey public any slot, Nonce any length / any P2, ECDH / CheckMac any length, Info any mode, encrypted
read; PolicyBurn: Lock any slot, GenKey create any slot, Lock with data; nil policy = burn; secert: canonical compare
removed (v2), serial length, MaxLen; no-CRC Lock allowed.

SURVIVED (5): #6 first Dev with the for-good policy (killed only under load by the timing tests, survived alone:
N-m1, N-m3); #24 update-extra mode 3; #30 status+locked reported locked; #31 own-refusal branch; #37 lock-slot
predicate true for the neighbour (all N-m3); #57 secert version/algorithm check removed — equivalent now (the
canonical comparison rejects the same certificates), not a finding.

Did not compile (2, replaced by v2 variants above): #9 (vet: unreachable code), #54 (unused variable).

---

## 5. Verdicts

**(1) Merging the code at 7aea4be: APPROVE-WITH-CHANGES.** No BLOCKER or MAJOR. All three round-1 MAJORs of each
reviewer are fixed with negative controls I could kill. The changes: N-m1 (fake clock for the Lock-poll tests) and
N-m3's tests are cheap and should go in before merge; N-m2, N-m4, N-m5 may ride along or go to the PR's checklist
(N-m2 and N-m5 must be done before PR 2 / PR 3 build on the burn primitives and Parse).

**(2) Runbook §4–§12 (the remaining irreversible steps: lock-data, counter-inc, lock-slot 4/6/5, update-extra 2 and
1) with a binary built from 7aea4be: APPROVE-WITH-CHANGES.** The binary on the rig is this commit bit for bit; every
command line of the runbook, run literally on a fake in the chip's real post-E4 state, prints exactly what the
runbook expects and sends exactly the eight for-good packets the runbook lists, each recomputed independently. No
rebuild is needed. Conditions (document edits only): N-r2 before §12 (record rc, a row for a missing
`update_extra_mode1=` line, `dump` not `info`, no power cut until byte 85 is known); N-r3 before §5; N-r1 and N-r4
whenever. If the code is changed for (1) first, rebuild, re-run the suite and this literal runbook run, and record the
new sha256 / `tool_rev`.

Counts: **0 BLOCKER / 0 MAJOR / 9 MINOR** (code N-m1–N-m5, runbook/record N-r1–N-r4).

