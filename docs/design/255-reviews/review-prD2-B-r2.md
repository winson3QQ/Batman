# PR D2 — code review round 2, Reviewer B (commit 7aea4be; runbook at Batman-e13 1edcd9d)

Scope: the whole PR (b64f5b1..7aea4be) with attention on what changed since e1e6506, the E4+ runbook as it stands
(`docs/255-rig-runbook-e4.md` at 1edcd9d — it changed during this review: §1.1 now builds from a clone on the WSL
file system), config §8.4 against the raw E4 outputs, and the contracts PR 2 will build on.

Counts: **BLOCKER 0 / MAJOR 0 / MINOR 11**

Verdicts:
- **(1) Merging the code: APPROVE-WITH-CHANGES** (m1, m6, m7 before merge; the rest can be checklist items).
- **(2) The runbook's remaining irreversible steps §4–§12 with a binary built from 7aea4be: APPROVE-WITH-CHANGES**
  (m2, m3, m4 and m1's two runbook rows into the runbook before §4; no code change is needed to proceed — on a
  lost Counter / UpdateExtra answer the tool and the runbook already stop with the chip in a readable state. If the
  code is changed for m1 first, the delta needs its own review and a new `tool_rev`).

Test files of this round (kept in the scratchpad, removed from the checkout): `revb_r2_e4state_test.go`,
`revb_r2_fuzz_test.go`; logs `revB-r2-*.log`.

---

## 1. Round-1 findings — status

Evidence keys: **mut** = mutant run in my checkout (`revB-r2-mut.log`, `revB-r2-mut2.log`, `revB-r2-mut3.py` output
below); **E4s** = my runbook/mistake runs from the real chip's post-E4 bytes (`revB-r2-runbook-e4state.log`,
`revB-r2-e4state.log`); **read** = read the code at 7aea4be.

| # | Finding (round 1) | Status | Evidence |
|---|---|---|---|
| B-M1 / — | runbook `rc=` was `tee`'s | **fixed** | §1.2 `set -o pipefail` + self-check; under the rig's busybox 1.36.1 (OpenWrt tree, qemu) `false \| tee` → `rc=1`, without pipefail `rc=0` (`revB-r2-ash.log`); on the real rig `selfcheck rc=1` (`results/e4-p-checks.txt`, `e4-after-power.txt`) |
| B-M2 / A-M1 / A-M2 | irreversible-step protections without negative controls | **fixed** | table-driven tests iterate `commandNamesSorted()` over the real `commands` map (`walk_test.go:286-292, 377-438`); `TestEveryCommandHasASample` pins the open and for-good sets. Mutants killed: A04 dry run → for-good tier, A05 serial not compared, A06/A07/A08 policy holes, A09/A10 read-only policy, A11, A14 lock-data dry block removed, A15 allow check skipped in dry run, B05–B12. Survivors A01 / A13 are equivalent with today's commands (A01 = first Dev gets the for-good policy: nothing in a rewritable command tries a for-good opcode except `raw`, which refuses on its own; A03 = A01 + raw's refusal removed is killed) |
| B-M3 | Lock polled 35+20 ms; late answer = unreadable outcome | **fixed for Lock; same gap left for Counter and UpdateExtra → new m1** | `LockPoll` 500 ms (C01 killed); `afterLock` 5 read-backs (B02 killed), one `_result=` line (B03 killed). E4 on the real chip: `lock_config_result=locked` |
| B-m1 / A-r1 | E11 wrote Counter[0]'s bytes | **fixed** | runbook §6 words 15, 16 = bytes 60–67 (Counter[1]); E4 dump bytes 60–67 `ff ff ff ff 00 00 00 00` |
| B-m2 / A-M3 | `Provisional=false` too early | **fixed (mark); gate moved to PR 2** | `se608.ProvisionalCmds = true` (`se608/cmds.go:16`); no consumer test in D2 — impl §2.2 / §9 now say PR 2's CI fails on it. Acceptable; it must be on the #255 checklist |
| B-m3 | se-fail only driver half | **declined → moved to PR 2, documented** | impl §2.2, §9 row PR D2 |
| B-m4 / A-m5 | result key = header key | **fixed** | `<cmd>_result=`; my E4s run asserts at most one `_result=` line and no repeated header key |
| B-m5 / A-m7 | counter-inc 0, update-extra before the locks | **fixed** | B07, B08, B11 killed; E4s scenario: `counter-inc 0` refused |
| B-m6 | rewritable commands reach config words 0-3/21 | **fixed** | A07, A08 killed; `TestRewritableCommandsCannotSendForGood` |
| B-m7 / A-m6 | lock-slot shows nothing / any slot | **fixed** | slots 4/5/6 only, both zones locked (B05, B06 killed), prints SlotConfig/KeyConfig/lockable/already-locked (B10 killed). Declined `-slot` repeat: accepted, the 3-slot limit removes the case |
| B-m8 | PolicyBurn locks any slot | **fixed** | C02, C03 killed |
| B-m9 | PolicyDaemon mode-only, nil panics | **fixed** | C04–C09 killed |
| B-m10 / A-m11 | secert.Parse wider than profile | **fixed** | re-encode-and-compare; D01, D02, D03, D05 killed; D04 (version/alg check) survives but is redundant with D01's check. 60 000 random mutants of a worst-case certificate: no panic (see §4) |
| B-m11 | DataCRC private-slot rule invisible to se608 tests | **fixed** | E01 (include private slots) killed by `TestLockRefusedOnWrongCRC` alone; E02 (drop OTP) killed |
| B-m12 | other survivors | **partly** | gated-ness of genkey/fill-data/slot-write now covered by the table test; N14 "re-read and Lock in one sequence" declined — E03 survives. Moot for chip 1 now (config already locked); PR 2's burn S0 must not copy the two-sequence shape — leave the comment |
| B-m13 / A-r5 | E9/E10 order, ECDH rows | **fixed** | runbook §8 |
| B-m14 | smaller runbook gaps | **fixed** | (i) `-expect-crc be96` on the real lock-data, B09 killed; (ii) §6 "read the counter first"; (iii) E15 narrower stated in runbook and design |
| A-m1 | printed ≠ sent packet | **fixed** | one `Cmd` printed and sent; E4s run: the 7 for-good packets that reached the fake equal the printed `lock_packet=` / `packet=` lines |
| A-m2, A-m3, A-m4 | counters asserted; all three Locks; lost answer | **fixed** | B11 killed; `TestLockResultComesFromTheChipsBytes` covers lock-config/data/slot × lie / garble / no read-back / slow / retry. Gap: the `status_XX_but_LOCKED` row has no test (B04 survives) — but my E4s scenario (e) shows the code prints it for a repeated `lock-slot 4` |
| A-m8, A-m9 | pre-checks; re-read failure labelled as status | **fixed** | `TestLockConfigReReadFailure`; B05–B09 killed |
| A-m10 | 72-byte WriteSlot tail | **not re-verified by me** | author says checked against fake memory |
| A-m12 | fake behaviours without source | **fixed** | "inferred" marks; `SecretTailReadOnly`, `OTPReadOnly` knobs with tests |
| A-m13 | tool cannot say its build | **fixed, with a runbook fix after it** | `tool_rev=`; a worktree on /mnt/c builds with no vcs info → `tool_rev=unknown`; a clean clone on WSL ext4 → revision, `vcs.modified=false`; dirty → `true` (`revB-r2-vcs.log`). Runbook 1edcd9d now builds from such a clone and stops on `unknown` / `+modified`. The `+modified` branch has no unit test (A12 survives) |
| A-r2, A-r3, A-r4, A-r6, A-r7 | runbook expectations | **fixed** | every packet recomputed by me independently (§3) equals the runbook; rows present |

---

## 2. New findings

### MINOR

**m1 (driver + runbook §6, §12) — Counter increment and UpdateExtra keep the table's poll cap (45 ms / 30 ms): the
same "executed but answer given up" gap B-M3 closed for Lock.** `se608/packet.go:63` `execMs` OpCounter 25,
OpUpdateExtra 10 (+20 ms `pollMargin`); `lab.Try` uses `MaxExec(op)`; only Lock got `LockPoll`. cryptoauthlib on the
608B only polls (`cal/calib_execution.c:37-38`, `:498-507`), so the table is not evidence of the 608B's Counter /
UpdateExtra time either (F§14.15 is about Lock; the others are simply unmeasured). Reproduced (E4s scenario c, d):
a fake that answers Counter after 150 NACKed polls →
`se-lab: counter1_after_inc: se608: no response: Counter not done within 45ms`, `rc=1`, no `counter1_after_inc=`
line, **the counter did go 0 → 1**; the operator repeating the command (dry run shows only the packet) → `counter1_after_inc=02000000`.
UpdateExtra the same: `UpdateExtra not done within 30ms`, `rc=1`, no `byte85_after=` line, byte 85 = `a0`; a repeat
is refused by the chip (`status_0f`) and harmless. Consequence on chip 1: no damage the runbook does not already stop
(§1.4: no row → stop, do not resend; §6's note), but E11's and E12's answer lines are lost and the operator is left
with a stop and an `info` that does not show the counter or byte 85. Fix: give Counter-increment and UpdateExtra
the same long poll (or one `ForGoodPoll` for all three), and after a transport error read the state back the way
`afterLock` does (`counter-read`, bytes 84/85) and print one `_result=` line; add the two rows to the runbook (§6:
"no `counter1_after_inc=` line, rc=1 → do not resend; `counter-read 1`"; §12: "no `update_extra_mode1=` → `-dry-run
update-extra 1 a0` shows `byte85_before=`").

**m2 (runbook, all 🔒 steps from §4) — no instruction for a dropped ssh / power cut in the middle of lock-data,
lock-slot or update-extra; and the dry runs are not used as the "where am I" check.** §1.4 covers "an unexpected
result"; a dropped connection gives no result at all (SIGHUP kills se-lab and `tee`; a power cut also wipes
`/dev/shm`). What happens if the operator then re-runs the step (E4s scenarios b, c, d, e):

| step | state after interruption | tool on a repeat | harm |
|---|---|---|---|
| `lock-data` | locked or not | locked: `refused: the data zone is already locked`, rc 3; not locked: sends again, chip re-checks the CRC | none |
| `lock-slot 4/6` | locked or not | dry run prints `slot_already_locked=yes` (runbook expects `no` → stop); real run → `lock_slot4_result=status_0f_but_LOCKED`, rc 1 | none |
| `counter-inc 1` | +1 (power loss: possibly more, facts §7) | **sends again: 1 → 2** | one extra irreversible increment (low cost on chip 1) |
| `update-extra 1 a0` | written or not | dry run shows `byte85_before=a0`; real run → chip `status_0f` | none |

So the tool is safe on repeat except counter-inc, which §6's note covers — but only "if the value is already 1";
after a power loss it may be more than 1 (facts §7, "may increment by more than one"). Fix: one paragraph in §1.4 —
"connection or power lost during a 🔒 step: do not resend; reconnect (§1.2), run that step's `-dry-run` (lock-slot:
`slot_already_locked`; update-extra: `byte85_before`; lock-data: header `lock_data`) or `counter-read 1`, and decide
from that"; §6: "not 0 → do not increment". Optionally run 🔒 lines under `nohup` / `setsid` with the output to a
file, so a dropped ssh cannot kill the process between Lock and read-back.

**m3 (runbook §1.1–§1.3, security) — root runs `/dev/shm/se-lab` and writes `allow.txt` / `*.txt` in a
world-writable directory with fixed names.** `/dev/shm` is 1777. A local unprivileged process (any non-root daemon
on the rig image) can pre-create `/dev/shm/se-lab` owned by itself before the operator's `scp -O`; scp opens and
truncates the existing file, the owner stays the attacker, and after the operator's `sha256sum` matches the attacker
can rewrite it before `./se-lab` runs as root (TOCTOU) — root code execution and arbitrary Lock/Counter/UpdateExtra
on the chip, i.e. falsified irreversible experiments. Same for a pre-created `allow.txt` (attacker-chosen serials:
the second serial check still holds, so this one alone does not unlock anything). Each power cut empties `/dev/shm`,
so the window recurs at every §1.3 step 5. Not verified on the rig (I may not touch it): whether any non-root process
runs there and the `fs.protected_regular` setting. Fix (one line): `D=$(mktemp -d /dev/shm/selab.XXXXXX)` (0700,
root) and copy/run/tee inside it; or check `ls -ln /dev/shm/se-lab` shows uid 0 right before running.

**m4 (runbook §4.1/§4.2) — E5 can be read directly before the data lock, and the runbook does not.** The OTP fill
that lock-data's CRC assumes (`00`) is inferred from the write status only; `status_00` from a chip that silently
ignored the write (one reading of facts §1 "OTP ... now read only") gives a CRC mismatch at the lock (`status_0f`,
nothing locked — fail-safe, but the runbook then just says stop). After the config lock the OTP zone is readable;
`./se-lab read otp 0000 32` and `read otp 0008 32` (read-only commands, no allow list needed) after `fill-data` would
show what the chip holds and let the operator pick `-otp-fill` from evidence (`00` → `be96`, `ff` → `3c9f`; any other
content → stop). Add the two lines and a row.

**m5 (config §8.4 — record accuracy) — two claims are looser than the raw outputs.** (i) "鎖後 dump：位元組 16–127
與影像相同": `rig-shm/e4-dump.txt` vs the image differs at 52–55, 60–63 (counters `ff`) and 86 (`55`); those are
excluded by the compare rule, but the sentence says "相同". The strong, true statement is: **the dump after the lock
differs from the pre-lock dump (`e3-verify.txt`) only at byte 87 (55 → 00)** — computed: `dump vs pre-lock differ
at: [87]`. (ii) "新 `boot_id`": only the pre-cut `boot_id=bd5cd417…` is in `e4-power-cut.txt` / `e4-after-power.txt`;
the post-boot evidence in the files is `up 1 min` + `get_rsts=1000`. Either add the new boot_id line or drop the
claim. Everything else in §8.4 matches the raw files (selfcheck, soak 300/0/0, dry run, packet, `locked`, `00/55`,
`status_0f`, two different randoms, `rc=3`, 61 s at 0.0 W ×4 readings, scan `60 2d 43`, sha256 `0eeaf15e…1140`,
`tool_rev=7aea4be…`).

**m6 (tests, CI) — the slow-Lock tests are wall-clock dependent.** `TestLockIsPolledPastTheTable` (200 real 1-ms
sleeps against a 520 ms deadline) and the slow case of `TestLockResultComesFromTheChipsBytes` (150) run on
`time.Sleep`/`time.Now` (`NewPolicy` → real clock). Measured on WSL, 4 vCPU: 0/50 failures with 4 or 8 busy loops,
**3/50 with 16**, and both tests failed with 32 (`Lock not done within 520ms`, `lock_slot6_result=LOCKED_answer_lost`)
(`revB-r2-stress.log`, `revB-r2-stress2.log`). A heavily shared CI runner can flake. Fix: `Dev.SetClock` already
exists — give these tests a fake clock (and an `env.clock` for se-lab's run()).

**m7 (driver, contract for PR 2) — `PolicyDaemon`'s comment overclaims "compromised caller".**
`policy.go:16-17`: "this is what a confused or compromised caller inside the daemon cannot even put on the bus".
A compromised caller in the same process can call the exported `se608.NewBurn` / `NewPolicy(bus, anything)` or use
the open fd, and PR 2's helper binary will contain both the daemon and `se-burn`. The policy is a bug-catcher; the
trust boundary is the process (root, `/dev/i2c-1` 0600, the flock). Fix: say "confused", and state in impl §2.7
that a compromised helper owns the chip.

**m8 (tests) — result rows without a test.** `status_XX_but_LOCKED` (B04 survives; code verified by my scenario e),
`NOT_LOCKED_answer_lost`, the ErrRefused branch of `afterLock` (B01 survives; unreachable today — if reached it would
print `NOT_LOCKED_answer_lost` for a Lock that was never sent), `byte85_after` read from the chip when the chip
refuses (B13 survives; my scenario g shows the code reads it: `byte85_before=11 … status_0f … byte85_after=11`),
and `toolRev`'s `+modified` (A12). Add one case each to `TestLockResultComesFromTheChipsBytes` and the walk.

**m9 (se-lab) — the counter-inc dry run shows no current value.** The one non-idempotent 🔒 step is also the one
whose dry run cannot tell the operator it already happened (lock-slot shows `slot_already_locked`, update-extra
shows `byte85_before`). Fix: print `counter1_before=` (Counter read is allowed in the rewritable tier) in both the
dry and the real run.

**m10 (runbook §7) — order inside E17 is not enforced.** `lock-slot 4` before `genkey 4` locks the slot holding the
§4.1 `priv-write` test key (E4s scenario e: `lock_slot4_result=locked`, then `genkey_slot4=status_0f`): E17's
"pubkey after = genkey before" and "a generated key locked" are lost for good on chip 1. The tool can't know the
intended order; the runbook's dry-run row could add "`genkey 4` above printed 128 hex chars" as a precondition.

**m11 (runbook §10) — the 390-byte blob is not checked before the write.** If `seq` were missing or `printf`
behaved differently, `BLOB` would be 2 bytes and the slot write would still succeed (zero-padded). Under the rig's
busybox it is 780 chars (`revB-r2-ash.log`), so low risk; add `echo ${#BLOB}` → must print 780.

---

## 3. What I verified, and how

- **Tests at 7aea4be** (`revB-r2-mut2.log` head): `go vet` + `go test` on se608/..., secert, cmd, cmd/se-lab pass,
  also with `-tags prov_test`; `-race` passes (`revB-r2-stress.log`). Module-wide CI commands: see §5.
- **Mutants** (39 total, one at a time, restored): A01–A15, B01–B13, C01–C11, D01–D05, E01–E04. Survivors: A01, A13
  (equivalent today), A12, B01, B04, B13 (m8), D04 (redundant check), E03 (declined N14), E04 (no test of the Counter
  cap — m1).
- **Packets, independently** (`revB-r2-pkts.py`: my own atCRC loop from `calib_command.c`, checked on the real wake
  response `04 11 33 43`; config bytes read from `results/e3-verify.txt`; private slots from the chip's KeyConfig bit 0
  = [0,1,2,4]): lock-config `9022` / `03 07 17 00 22 90 1d 15` (= what E4 sent and the chip accepted); lock-data
  `be96` / `03 07 17 01 96 be 26 70` (OTP `ff`: `3c9f`); counter-inc 1 `03 07 24 01 01 00 06 f7`; lock-slot 4/6/5
  `…12 00 00 8e 08` / `…1a 00 00 cd 89` / `…16 00 00 0d 8a`; update-extra 1 a0 `03 07 20 01 a0 00 03 e9`; 2 00
  `03 07 20 02 00 00 03 f8`; slot 4/5/6 SlotConfig/KeyConfig/lockable `2083/0073/yes`, `8f9f/001c/no`, `0f0f/003c/yes`.
  All equal to the runbook; `indep-forgood-packets.py` agrees. Vendor slot lock: `calib_lock.c:235` sends
  `0x02|slot<<2` with summary 0 — same as ours.
- **Runbook §4–§12 literally from the real chip's post-E4 bytes** (`TestRevBR2RunbookFromE4`: fake Config =
  `results/rig-shm/e4-dump.txt`, every se-lab line of §4–§12 with its stated values): 0 mismatches; 7 for-good packets
  reached the fake, each equal to the printed one; final state `00/00`, SlotLocked `ffaf` (4, 6), Counter[1]=1,
  byte 85 `a0` — the runbook's §13 end state. (The earlier run from the E3 state, `revB-r2-runbook.log`, also 0.)
- **Operator actors** (`TestRevBR2FromE4State`, log `revB-r2-e4state.log`): lock-data before fill-data → chip
  `status_0f`, not locked; lost lock-data answer → `LOCKED_answer_lost`, repeat refused rc 3; slow counter / update-extra
  (m1); early lock-slot and repeat (m10, m2); `update-extra 0 a0` typo writes byte 84 for good (harmless: no effect
  with this ChipMode, but irreversible — the runbook could say "MODE is `1`"); wrong serial digit refused; upper-case
  serial accepted (EqualFold, fine).
- **Shell lines** under the rig's busybox 1.36.1 via qemu (`revB-r2-ash.log`): pipefail, `printf %.0s` + `seq` → 780,
  unquoted `$c` splitting, `grep -v '…\|…'` keeps `*_result=` lines, the loop shape with pipefail.
- **Power-cut section vs evidence**: §1.3 (poweroff → ssh gone + 20 s → plug off ≥ 60 s at 0.0 W → on → self-boot →
  `get_rsts=1000`) matches §8.3's measurements and the E4 log (ssh gone 15:09:25, off 15:09:45, on 15:10:46 = 61 s,
  4 readings of 0.0 W, `get_rsts=1000`, `up 1 min`, chip `00/55` at 0x60).
- **Interfaces for PR 2**: `PolicyDaemon` = exactly impl §2.1's chip backend (Info rev; Read; Nonce pass-through 32;
  GenKey public 0-2; Sign external slot 0; ECDH clear slot 2 with 64 bytes; CheckMac mode 0 slot 5 with 77 bytes);
  `PolicyBurn` adds exactly config §5.2 S0–S3's needs (plain Write 4/32, Lock config/data with CRC, Lock slot 0-2,
  GenKey create 0-2); no-CRC Lock refused in `Exec` under every policy. Note for PR 2: `PolicyBurn` lets a Write
  address config words 0-3/21 (se-lab's protected set) — harmless per vendor, but PR 2 could share se-lab's check.
- **secert**: re-encode-and-compare; 60 000 random mutations of a worst-case certificate → no panic (§4).
- **Secrets**: none in the diff (grep for key material); se-lab's slot content is derived from the serial and is
  printed nowhere; `checkmac` prints a status only.

## 4. secert mutation run

`TestRevBR2ParseMutations` (bit flips, byte sets, deletions, insertions on a worst-case certificate from `Build`):
`60000 mutants: 9350 accepted by Parse, 3715 of those with a TBS different from the original`, no panic. The
accepted ones change the signature (outside the TBS) or land on another valid point / serial inside the profile:
structurally valid by design — `Parse` does not verify the signature (`VerifyRoot` does) and `Matches` compares
against the chip's keys. (I did not separately assert that each accepted TBS is canonical; that is what the re-encode comparison does, and D01 shows a test fails without it.)

## 5. CI

`revB-r2-ci.log` (WSL Ubuntu 24.04, the module's vendored deps, my checkout at 7aea4be with my two extra test files
moved out for the first run):
- `go vet ./... && go test -count=1 ./...` → every package `ok` (se608 1.2 s, cmd/se-lab 23.2 s, cmd 4 s; provstore
  118 s), `rc=0`.
- `go test -count=1 -v -tags prov_test ./...` **as my user, not root** → `rc=0`, every package `ok`; 12 `--- SKIP`
  (TestBulkTmpfs, TestSlotNamespace, TestExecAbandonsDState, TestIdleConnectionClosed, TestOnPeer, TestAllowedPeer,
  TestWrongPeerClosed, TestOversizeAndMalformedClose, TestPrepareDirRefusals, TestSecondConnectionNotBlocked,
  TestFifthConnectionClosed, TestAcceptRate) — all root-only tests of provhelper / provstore / sock, none in a package
  this PR touches. ⚠️ CI's root run (which fails on any SKIP) was not reproduced: no sudo here.
- `-race` on se608/..., cmd/se-lab, secert → ok.
- Wall-clock flake risk: m6.

## 6. Note on my own runs

My stress runs (16–32 busy loops in the shared WSL VM, about 15:25–15:33 on 2026-11-27) could have slowed the
concurrent mutation run in `C:/src/Batman-d2`; any timing failure there in that window (Lock-poll tests, `soak`)
should be re-run before being attributed.
