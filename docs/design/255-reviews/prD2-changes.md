# PR D2 code review → changes (branch feat/255-se608-d2)

Round 1 (code at e1e6506, runbook draft): Reviewer A (`review-prD2-A.md`) = 0 / 3 / 20, Reviewer B (`review-prD2-B.md`) = 0 / 3 / 14.
Both: merge = APPROVE-WITH-CHANGES; using the build for E4 (config lock) = APPROVE-WITH-CHANGES.
Both ran the code and found no path that sends a Lock, a Counter increment or an UpdateExtra the operator did not confirm, no wrong-zone / wrong-slot / wrong-byte-order Lock packet, and no case that prints "locked" while the chip's bytes say otherwise. Both recomputed E4's packet on their own (A: a Python port of the vendor `atCRC`; B: a separate Python CRC checked against the wake response): CRC `9022`, packet `03 07 17 00 22 90 1d 15`. Mutants: A 101 (60 killed, 37 survived, 4 did not compile), B 74 (46 killed, 25 survived, 3 did not compile).

The round's theme: protections that were present and correct but had no negative control. The fix is structural where it can be: one place decides what an invocation may send.

| Finding | Handling |
|---|---|
| A-M1 / B-M2 a dry run is stopped only by one `if c.dry` per command; three have no test | **Invocation policy** (`cmd/se-lab/main.go`): three tiers — read-only, rewritable, for-good — picked in `run()` from the command table and the flags; the for-good tier only for a for-good command, not dry, listed, serial typed and equal. The rewritable tier refuses Lock, UpdateExtra and Counter increment before the bus (`lab.ForGood`), so a command that forgets its own dry check still sends nothing. Tests: `TestDryRunSendsNothingForGood` (every for-good command, from the table, with a control that the real run does send), `TestInvocationPolicyTier`, `TestInvocationPolicies`, `TestRewritableCommandsCannotSendForGood` |
| A-M2 / B-M2 the allow list is tested for lock-slot only | `TestAllowListBindsEveryChangingCommand` iterates the command table: without `-allow` the bus is not opened; with a list that lacks the chip only Info / Read go out — also with the right serial typed, also in a dry run. `TestEveryCommandHasASample` pins the set of commands that need no list and the set of for-good commands; a new command without a sample fails |
| A-M3 / B-m2 `Provisional = false` while six commands have never met a chip | `se608.ProvisionalCmds = true` (Lock, Nonce, GenKey, Sign, ECDH, CheckMac), separate from `Provisional`. The CI gate that fails on it belongs to PR 2 (impl §2.2 now says so; #255 checklist) |
| B-M3 Lock polled for 35 + 20 ms from a table the sources say does not hold for the 608B; a late answer leaves the outcome unreadable | `se608.LockPoll` = 500 ms for every Lock (still one sequence under the 0.7 s watchdog). `afterLock` retries the read-back (5 tries) and always prints exactly one `<cmd>_result=` line: `locked`, `status_XX`, `status_XX_but_LOCKED`, `LOCKED_answer_lost`, `NOT_LOCKED_answer_lost`, `NOT_LOCKED_after_success_status`, `UNKNOWN_read_back_failed`. Tests: `TestLockResultComesFromTheChipsBytes` (all three Locks × lying chip, garbled answer, unreadable chip, slow Lock, read-back needing a retry), `TestLockIsPolledPastTheTable`. Runbook §3 has a row per result |
| B-M1 runbook records `tee`'s exit code | §1.2: `set -o pipefail` plus a self-check line that must print `rc=1`, on every new connection |
| A-m1 printed packet built by other code than the sent one | One `Cmd` value is printed and sent (`lab.CounterCmd`, `lab.UpdateExtraCmd`, `se608.Lock*Cmd`); the walk asserts printed = received for every for-good packet (`sentAs`) and counts them (8) |
| A-m2 counter commands could address the wrong counter | The walk asserts `chip.Counters` after each step |
| A-m3 "locked from the chip's bytes" tested for lock-slot only | All three Locks (above) |
| A-m4 / A-r3 a lost Lock answer: no result line, no runbook row | Result line and runbook row (above) |
| A-m5 / B-m4 result key collides with the header's `lock_config=` | Results are `lock_config_result=`, `lock_data_result=`, `lock_slotN_result=`; the header keys are unchanged (the first runbook's outputs use them) |
| A-m6 / B-m7 lock-slot checks no state; `lock-slot 8` would end E15 | Only slots 4, 5, 6 (the experiments' three), only with both zones locked; prints SlotConfig, KeyConfig, `lockable=`, `slot_already_locked=` before the packet. Not done: a second `-slot` flag (B's suggestion) — the three-slot limit removes the case it was for |
| A-m7 / B-m5 `counter-inc 0`, `update-extra` before the locks | `counter-inc` only for Counter[1] and only after the config lock; `update-extra` only with both zones locked |
| B-m6 rewritable commands can address the lock bytes | The rewritable and for-good policies refuse a Write to config words 0-3 and 21 and a 32-byte Write to config blocks 0 and 2 |
| A-m8 pre-checks without a test | Tests added for: lock-config / lock-data on a locked chip, lock-data `-expect-crc`, lock-config without `-expect-crc`, fill-data's state checks and exit code, the re-read of each of the four blocks. Left as they are (redundant with a later check, said so by the reviewer): lock-config's byte-17 check (the image comparison covers it) |
| A-m9 a failed re-read reported as the Lock's status | `errReRead`: refused, nothing sent, no result line (`TestLockConfigReReadFailure`) |
| A-m10 WriteSlot's tail addressing for 72-byte slots | Non-zero 72-byte write checked against the fake's memory |
| B-m11 se608's tests cannot see "skip private slots" | Non-zero content right before a private slot; the test asserts its content can tell the two rules apart |
| B-m8 PolicyBurn locks any slot | Slots 0-2 only (and GenKey create for 0-2 only): the certificate slot can never be slot-locked by the burn mode |
| B-m9 PolicyDaemon checks the mode byte only; nil policy panics | Each command pinned to its slot and exact length (Sign: slot 0, ECDH: slot 2, CheckMac: slot 5, public key: slots 0-2, Nonce: 32 bytes, param2 0); a nil policy is the daemon's |
| A-m11 / B-m10 `secert.Parse` accepts a 20-byte serial, an issuerUniqueID | Serial 1-8 bytes; the profile is re-encoded from what was parsed and the to-be-signed bytes must be identical. Controls: 9- and 20-byte serials, ecdsa-with-SHA384, a spliced issuerUniqueID (which the standard library parses and hides), a parseable 417-byte input judged by its error |
| A-m12 fake behaviours with no source | Marked "inferred" in the fake; new knob `SecretTailReadOnly` for the other reading of facts §2.1 (4-byte writes to IsSecret slots refused) with a test that fill-data reports it; the package comment says the fake cannot catch a CRC bug and names the golden vector that does |
| A-m13 the tool cannot say what build it is | `tool_rev=` (VCS revision, `+modified` when the tree was dirty) on every invocation |
| B-m3 se-fail: only the driver half | Stated in impl §2.2 / §9; the killpoint-file half moves to PR 2 with the backend (#255 checklist) |
| B-m12 other survivors | Covered by the table-driven tests above, except N14 ("re-read and Lock in the same sequence" is not asserted) — left: the chip's own CRC check is what makes the property matter, and that is tested |
| A-r1 / B-m1 E11 writes Counter[0]'s bytes | Words 15 and 16 (Counter[1]); Counter[0] read before and after |
| A-r2 dry runs with nothing to compare against | Every dry run lists the expected packet, computed by `artifacts/indep-forgood-packets.py` (no se-lab code): lock-data `be96` / `03 07 17 01 96 be 26 70`, counter-inc, lock-slot 4 / 6 / 5, update-extra. The real lock-data is given `-expect-crc be96` |
| A-r4 `-allow` and `-serial` come from one shell variable | §1.2: compare `info`'s serial with the E1 record on paper, on every new connection |
| A-r5 E12 before E13 and E15 | E12 moved to the end (config §8.1 notes the deviation and why) |
| A-r6 commands without an expectation row | Rows for `ecdh 2 compat`, `sign-internal 4`, `sign-internal 2` |
| A-r7 / B-m14 E15 narrower than the design's | Stated in the runbook and in the design's E15 row |
| B-m13 E9 / E10 order; ECDH "write to a slot" rows | E9 runs before `ecdh 2 slot` (last); the ECDH rows the variant cannot test are named "document only"; PRF to a slot added |
| B-m14 re-run after a power cut mid-E11 | §6: read the counter first; do not increment twice |

Also since round 1 (not from a finding): the power-cut method was measured on the rig (config §8.3) — the smart plug really cuts power, the battery holds for about a second — so the runbook's power cuts are remote, judged by three things together (plug power 0, the Pi boots by itself, `get_rsts=1000`).
