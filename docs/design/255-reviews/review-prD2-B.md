# PR D2 — code review, Reviewer B (independent, adversarial)

Reviewed: the whole diff `d2.diff` (base b64f5b1, head e1e6506 "wip: D2 tests strengthened after mutants") in the
private checkout `C:/src/Batman-d2-revB`, the runbook `docs/255-rig-runbook-e4.md`, against
`255-608b-config.md` (§4, §5, §8), `255-608b-impl.md` (§2.1, §2.2, §2.5, §2.8, §3.1, §4.4, §5, §9),
`608b-facts.md`, the vendor files in `scratchpad/cal/`, and the real-chip outputs in
`Desktop/Batman/255-rig-runbook/results/`.

No device was contacted. Nothing was committed or pushed. Files I added in my checkout (all untracked, tests
only): `cmd/se-lab/revb_test.go`, `cmd/se-lab/revb2_test.go`, `secert/revb_secert_test.go`. `git status` shows no
modified tracked file after the mutant runs.

Counts: **BLOCKER 0 / MAJOR 3 / MINOR 14**

Verdicts are at the end.

---

## Findings

### MAJOR

**M1 (runbook) — every `rc=` the E4 runbook records is `tee`'s exit code, not se-lab's.**

(a) Scenario. The runbook's commands have the form `./se-lab … 2>&1 | tee f.txt; echo "rc=$?" | tee -a f.txt`
and its tables judge on `rc=` in many places: §2 soak `rc=0`; §3 dry run "`rc=3` → read the message, stop"; §3
lock "`rc=3` and `changed since it was read`"; §3 `write-image` "`rc=3`"; §3/§9 after power "`rc=0`"; §4.1
fill-data `rc=0`; §7 `sign` `rc=0`; §10 "`lock_slot5=status_0f`, `rc=1` (**expected**)". Without `set -o pipefail`
the shell reports the status of the last pipeline stage. A refused, failed or crashed se-lab is recorded as
`rc=0`; the one place that expects `rc=1` (§10) can never show it, so a literal operator hits "different from
expected" on a step that actually went as designed, and the evidence files brought back say `rc=0` for commands
that failed.

(b) Evidence. `docs/255-rig-runbook-e4.md`: `grep -c pipefail` = 0; 23 lines use `rc=`. The first runbook does set
it (`docs/255-rig-runbook.md:176`, `:190` "新開的 SSH 連線都要先下 `cd /dev/shm; set -o pipefail`", `:295`,
`:363`); the E4 runbook's own "every new connection" block (§1.2) dropped it, and §1.3 makes the operator open a
new connection after every power cut. Run here (`scratchpad/revB-pipefail.sh`):
`bash`: `without pipefail rc=0` / `with pipefail rc=1` / `with pipefail, exit 3: rc=3`; busybox ash 1.36.1 behaves
the same; dash rejects the option.

(c) Fix. Put `set -o pipefail` into §1.2 (the block that is re-run on each connection) and add a one-line
self-check right after it that must print `rc=1`: `false | tee /dev/null; echo "rc=$?"` — if it prints `rc=0`,
stop. Required before E4.

**M2 (code + tests) — protections on the irreversible commands with no negative control; three of them are the
runbook's "dry run" steps, which are run without `-serial` and before consent.**

(a) Scenario. The runbook runs `-dry-run lock-data` (§4.2), `-dry-run lock-slot 4` (§7) and
`-dry-run update-extra 1 a0` (§9) with `-allow` only. In `run()` a dry run skips both `-serial` checks
(`main.go:271`, `:309`), so the only thing between that command line and a real Lock / UpdateExtra is one
`if c.dry { … return }` inside each command (`cmds.go:738`, `:755`, `:801`). Removing any one of the three leaves
the whole suite green. A later edit that moves or drops that line turns the runbook's "look first" step into the
irreversible action, with no typed serial and no consent. Same class: the allow-list binding — the E4 precondition
in config §8.3 ("鎖定指令綁犧牲晶片序號清單") — is tested for `lock-slot` only.

(b) Evidence — mutants that SURVIVED `go test ./se608/... ./secert/ ./cmd/ ./cmd/se-lab/`:
- M13 `lock-data`: dry-run sends; M14 `lock-slot`: dry-run sends; M15 `update-extra`: dry-run sends.
  (Tested: `lock-config` M12 and `counter-inc` M16 — killed by `TestExperimentWalk`. `walk_test.go:74`, `:115` are
  the only two `-dry-run` uses besides the helper at `:229`.)
- N04 `lock-config` `gated: false`; M25 `lock-data` `gated: false`; M23 `update-extra` `gated: false`; M24
  `counter-inc` `gated: false`; M26 `raw` `gated: false`. (Only `lock-slot` not gated, M22, is killed. With
  `gated: false` the typed serial still has to match, so what is lost is exactly the sacrificial-list rule.)
- M54 `lock-data`: `-expect-crc` not compared.
- N10 `counter-inc`: counter id not bounded to 0/1.
The current code is correct on all of these — I ran each by hand on a fake holding the real chip's bytes
(`TestRevBCurrentBehaviour`: `lock-config`, chip not listed → `rc=3`, 0 Lock packets; the four dry runs →
`for-good packets sent=0`, config unchanged). The finding is that nothing would notice a regression.

(c) Fix. (1) A table-driven test over `commands`: for every `forGood` command, `-dry-run` (without `-serial`)
sends no Lock/Counter-increment/UpdateExtra packet and leaves the fake unchanged; for every command not in the
read-only set, a chip that is not on the list is refused with nothing but Info/Read sent. Iterating the map means
a command added later is covered without anyone remembering. (2) Better, make it structural rather than
per-command: build the `Dev` with a policy wrapper — when the invocation is not (`forGood` AND not dry-run AND
serial matched), refuse `OpLock`, `OpUpdateExtra` and `OpCounter` with mode bit 0 before the bus. Then a missing
`if c.dry` cannot send, and `raw`'s opcode list (`cmds.go:659`) stops being the only barrier for the non-for-good
commands. Not needed for E4 itself (lock-config's dry run, CRC expectation, image check, serial, allow list at
`main.go:306`, re-read and "result from the chip's bytes" all have killed mutants: M12, M08, M09, M05, M06, N01,
N02, M11); needed before §4.2 of the runbook.

**M3 (code + runbook) — a Lock that the chip executes but answers after the driver's cap is reported as a failure
with no lock state; the cap for Lock comes from a table the sources say does not hold for the 608B.**

(a) Scenario. `Exec` gives a command `MaxExec + 20 ms` (`dev.go:139-148`); for Lock that is 35 + 20 = 55 ms
(`packet.go:63-64`), taken from cryptoauthlib's `device_execution_time_608_m0`. On the real chip at E4, if Lock
takes longer than 55 ms: `Exec` returns "Lock not done within 55ms"; `afterLock` immediately tries to read the
zone back while the chip is still busy, fails, and exits 1. The chip is locked. The operator sees two error lines,
no `lock_config=` result line and no `lock_config_after=` line; the runbook's §3 table has rows only for
`locked`, `status_0f` and `rc=3`. This is not a wrong lock (the packet and CRC are right), it is an unreadable
outcome at the one step that cannot be repeated — and the same cap applies to `lock-data`, `lock-slot`, GenKey and
Sign later, and to the burn mode built on these primitives.

(b) Evidence.
- Vendor: `cal/calib_execution.c:37-38` — "ATECC608B supports only polling mode"; with polling the library waits
  `ATCA_POLLING_MAX_TIME_MSEC`, not the per-command table (`calib_execution.c:498-507`: the table is used only
  under `ATCA_NO_POLL`).
- Facts: `608b-facts.md:407` "608A→608B: … timing of Verify/SecureBoot/**Lock**/Read changed … use polling";
  `:297` calls the table "the library's maximum wait values, used together with polling".
- Code's own note: `packet.go:60-62` "Not timed on a chip"; `doc.go` "Not yet run on a real chip at all: Lock, …".
- Reproduced on the fake (`TestRevBLockSlowerThanCap`, the Lock answered late):
  ```
  config_crc=9022
  lock_packet=03 07 17 00 22 90 1d 15
  se-lab: lock_config: se608: no response: Lock not done within 55ms (read the chip again before doing anything else)
  se-lab: lock_config: read back: config block 0: se608: no response: Read not done within 25ms
  rc=1          # chip byte 87 = 00: locked
  ```
- No test covers this branch of `afterLock`: mutants M58 / N11 (transport error on the Lock, bytes say locked →
  report `locked` / exit 0) and N08 (read-back failure → exit 0) all survive.

(c) Fix. For Lock (and the other for-good commands) poll well past the table — nothing is gained by giving up on
an irreversible command early; e.g. 500 ms, still under the 0.7 s minimum watchdog for the lock-config sequence
(4 reads + Lock). In `afterLock`, retry the read-back for a second or two before giving up, and always print one
unambiguous result line under the same key the runbook reads, e.g. `lock_config=LOCKED_command_error` /
`lock_config=UNKNOWN_read_back_failed`. Add the fake test (a `BusyPolls` that outlasts the cap; the knob already
exists). Runbook §3 / §4.2 / §7 / §10: add the row "`rc=1` and no `…=locked` line → run `info`, record
`lock_config=`, stop". At minimum the runbook row is required before E4; the code change before merge.

### MINOR

**m1 (runbook, E11) — the "cannot be brought back down" write targets Counter[0], not the counter that was
incremented.** §6 runs `config-write 13 00000000`. Word 13 = bytes 52–55 = the first word of Counter[0]
(`e3-verify.txt`: `config[ 48]=9f 8f 9f 8f ff ff ff ff 00 00 00 00 ff ff ff ff` — Counter[0] = 52–59, Counter[1] =
60–67), while the step incremented Counter[1] and the same section says "**不要動 Counter[0]**" (design E11: "不動
Counter[0]"). After E4 the write is expected to be refused either way, so the risk is small, but the test does not
test what it claims, and if the lock did not hold it would alter Counter[0]. Fix: write words 15 and 16 (bytes
60–67) with the blank value `ffffffff` / `00000000`.

**m2 (design vs code) — `se608.Provisional` is already `false` while six commands this PR adds have never run on
a chip.** impl §2.2: "PR D 的狀態碼與位元組格式標為暫定；E1 / E8 / E17 擷取的真實回應回填後才拿掉標記，PR 2 的 CI
在標記還在時失敗". The mark was cleared after E1–E3 (base commit), and D2 adds Lock, Nonce, GenKey, Sign, ECDH,
CheckMac under it (`doc.go`: "Not yet run on a real chip at all"). `TestWireFormatsConfirmed` (`cmds_test.go:21`)
therefore passes for formats that are unconfirmed, and PR 2's CI gate no longer does what the design gives it.
Fix: a second mark for the D2 commands (cleared when E6 / E8 / E17 / E10 results are back-filled) with the same
kind of consumer test.

**m3 (scope, impl §2.2 / §9 "`se-fail` 接縫") — only the driver half exists.** `fail_provtest.go` gives
`FailSequences(n)`; nothing reads `se-fail=<N>` from the killpoint file (`seam.Arm`), and no non-test code calls
it. The file comment says PR 2 does the reading. Acceptable if the issue checklist records it as moved to PR 2;
today §9 lists the seam as PR D2's.

**m4 (se-lab output interface) — the same key is printed twice with two meanings.** Every invocation prints the
header `lock_config=55|00` / `lock_data=…` (the byte), and `afterLock` prints `lock_config=locked|status_0f` /
`lock_data=locked` (the outcome). The runbook's tables say "`lock_config=` → `locked`"; a `grep '^lock_config='`
returns two lines, and the runbook's own filter `grep -v '^lock_'` (§5, §8) would also drop `lock_slotN=` result
lines if reused. Fix: name the header `lock_config_byte=` or the result `lock_config_result=`.

**m5 (se-lab) — `counter-inc 0` and `update-extra` before the locks are accepted.** With `-serial`,
`counter-inc 0` increments Counter[0] (`TestRevBOutOfOrder`: `counters=[1 2]`), which design E11 and the runbook
forbid; `update-extra 1 a0` before the config lock is sent and succeeds on the fake, changing the CRC the E4
pre-computation depends on (then `lock-config` refuses: `computed CRC 94b9, -expect-crc 9022: nothing sent` — fail
closed, but chip 1 would need a new independent CRC). Fix: refuse counter 0 without an extra explicit flag; refuse
`update-extra` unless both zones are locked (the design order puts E12 after E6).

**m6 (se-lab) — non-for-good commands can address the lock bytes and the counters.** `config-write 21 …`,
`write config 15 …`, `write config 10 <32 bytes>` and `raw 12 00 0015 …` put a Write to config word 21 (bytes
84–87: UserExtra, UserExtraAdd, LockValue, LockConfig) on the bus with `-allow` only (`TestRevBWritesNearLockBytes`:
"Write packet reached the chip: 0b 12 00 15 00 …"). That Write cannot change those bytes is vendor-documented
(`cal/calib_write.c:335-336`) but unmeasured on our chip (fakechip.go:401 "E3 never wrote them, so untested").
Fix: refuse config words 0–3 and 21 (and a 32-byte write to block 2) outside a for-good command.

**m7 (se-lab) — `lock-slot` gives the operator nothing to check but a packet.** No slot state is shown or
required: `lock-slot 8` on chip 1 locks the certificate slot for good (`TestRevBOutOfOrder`:
`lock_slot8=locked`), after which E15 cannot run. Fix: in the dry run and before sending, print the slot's
KeyConfig.Lockable, its current SlotLocked bit and SlotConfig; consider requiring the slot to be named a second
time (`-slot N`) the way the serial is.

**m8 (driver) — `PolicyBurn` lets the burn mode lock any slot.** `policy.go:67` accepts every slot number; the
design locks only slots 0–2 and says slot 8 is never slot-locked on the bench (config §5.3). Fix: restrict to
slots 0–2 (PR 2 may do it where the burn steps are written, but the policy is the place the design names).

**m9 (driver) — `PolicyDaemon` checks the mode byte only.** Nonce: the 32-byte length check has no test (M33
survived) and P2 is not checked; GenKey/Sign/ECDH/CheckMac: slot number (P2) and data length are not checked (the
`Session` helpers do, a raw `Exec` does not). The chip enforces the slot rules; this is defence in depth against a
confused caller. Also `NewPolicy(bus, nil)` panics on first use.

**m10 (secert) — `Parse` accepts more than the profile, contrary to its comment (`secert.go:127`).**
`TestRevBParseOutsideProfile`: a 20-byte certificate serial → `Parse err = <nil>` (Build limits it to 8; impl §3.1
"序號欄位用 1–8 位元組"); an `issuerUniqueID` inserted before the extensions → `Parse err = <nil>`, `Matches =
<nil>`. No impact on trust (the node never trusted the signature, the app pins the DER and verifies), and 300 000
random mutants produced no panic; but the node-side "structure is fixed" claim is not true. Also N06 survived
(version / signature-algorithm check has no test) and M44 survived: `secert_test.go:234` "Parse accepted 417
bytes" passes zeros, which fail to parse anyway — a presence check, not a control. Fix: check serial length and
re-encode-and-compare (or reject unique IDs); test the cap with a parseable 417-byte certificate.

**m11 (tests) — se608's own tests cannot see the "skip private slots" rule of `DataCRC`.** The CRC starts at 0,
so leading zero bytes do not change it; in the final image the private slots (0–2) are first and hold zeros in the
test, so including them gives the same CRC. Mutant M39 is killed only by se-lab's variant walk (slot 4 after a
non-zero slot 3), not by `TestBurnedChip…` / `TestLockRefusedOnWrongCRC`. Consequence for the rig: E6 on the
variant does discriminate (good), but F1 on the final image will not confirm the rule again. Fix: a `DataCRC` unit
test with a private slot after non-zero data, against the fake's independent `dataSummary`.

**m12 (tests) — other survivors, low impact.** M27 / M28 / N09 (`genkey`, `fill-data`, `slot-write` not gated:
a write to an unlisted chip — e.g. a bench node's slot 8 — would go unnoticed by the suite; covered by the
table-driven test of M2); M60 (`fill-data` state refusals); M56 (`lock-config` on an already locked chip still
sends — the chip refuses); M57 (`lock-config` without `-expect-crc`); M53 (byte-17 refusal — redundant with the
image diff); M45 (Build's size cap — unreachable with this profile); N14 (the "same sequence" property of the
re-read before the Lock is claimed in `cmds.go:672-674` but not tested).

**m13 (runbook) — E9 / E10 differ from the design's list and order.** Design §8.1: E9 then E10; the runbook
generates keys in slots 1 and 2 and runs the E10 loop first, then E9. Slot 0 stays empty, so the stated reason
holds, but `ecdh 2 slot` (if it unexpectedly succeeded) would overwrite slot 3, the source key of E9's control.
E9 is run with KDF-HKDF targets only; the design names "ECDH 與 KDF「寫入指定槽」" for targets 5 / 15 / 4 / 0 — ECDH
can only target slot N+1 and the variant has no slot that permits it, so those rows are "document only"; PRF to a
slot is not run. Fix: say so in the runbook, and run E9 before `ecdh 2 slot`.

**m14 (runbook) — smaller gaps.** (i) §4.2: the real `lock-data` is not given `-expect-crc <the dry run's
data_crc>`; the tool supports it (untested, M54). (ii) No instruction for a re-run after a power cut or dropped
connection in the middle of §6: `counter-inc` is not idempotent — say "run `counter-read 1` first". (iii) §11
writes a blob, not a certificate, and reads it back — design E15 says "憑證寫入槽 8、讀回、驗章"; the runbook states
the real certificate waits for F1, which should be noted in the design's E15 row.

---

## What I verified, and how

Commands (WSL Ubuntu-24.04, go1.26.4, `GOFLAGS=-mod=vendor`, no `GOTOOLCHAIN`):

- `go vet ./... && go test -count=1 ./...` — all 20 packages `ok` (whole module, including `cmd` 5.3 s with the
  `go list -deps` test). `go vet -tags prov_test` and `go test -count=1 -tags prov_test ./se608/... ./secert/
  ./cmd/ ./cmd/se-lab/` — `ok`. Not run as root (CI's second step is); no `t.Skip` in the D2 packages, so CI's
  "no SKIP under root" rule is not at risk from this PR. `deps_test` shells out to `go` with the inherited
  environment (`GOFLAGS`, `GOTOOLCHAIN`, `GOCACHE`), which CI's `sudo env PATH=…` line preserves.
- **E4 packet, three ways.** (1) The PR's code on the real chip's bytes after E3 (`e3-verify.txt` final dump
  loaded into the fake): `config_crc=9022`, `lock_packet=03 07 17 00 22 90 1d 15`. (2) My own CRC in Python
  written from the datasheet description, checked first against the wake response `04 11 33 43`
  (`scratchpad/revB-crc.py`): `config crc = 9022`, `lock packet = 03 07 17 00 22 90 1d 15`. (3) Design §8.3's
  independent value: the same. Format against vendor: `cal/calib_lock.c:81-82` (param1 = mode, param2 = summary
  CRC), `calib_command.h:589-595`.
- **The runbook, literally, on a fake holding the real chip's config** (`TestRevBRunbook`, log in
  `scratchpad/revB-runbook.log`): every `key=value` the runbook expects is what the tool prints (§2–§11),
  including `slot_locked_after=ffef`, `counter1_after_inc=`, `byte85_after=a0`, the 780 + 52 characters of §11,
  `lock_slot5=status_0f` with exit 1. The only expectations that cannot appear are the `rc=` values (M1). On the
  fake, hmac / kdf / aes answer `status_03` for both the claim slot and the control (not modelled): those rows have
  no control until the real chip answers, as the runbook says.
- **Packet formats against the vendor source**, from the packets the fake recorded in that run: Lock slot
  `17 12 00 00` / `17 1a 00 00` (`calib_command.h:591`), Lock data `17 01 <crc>`; PrivWrite `46 00 04 00` + 4
  zeros + key + 32 zeros (`calib_privwrite.c:182-185`); Counter `24 00 00 00`, `24 01 01 00`, value little-endian
  (`calib_counter.c:111-114`); UpdateExtra `20 01 a0 00`, `20 02 00 00` (`calib_updateextra.c:81-82`,
  `calib_command.h:787-790`); KDF `56 52 05 00 02 00 00 10 …`, `56 4a 03 06 …` (`calib_kdf.c:90-124`,
  `calib_command.h:541-581`); AES `51 00 05 00` + 16; SHA-HMAC `47 04 05 00`, End `47 02 <len>`
  (`calib_command.h:751-755`); Nonce `16 03 00 00` + 32 and `16 00 00 00` + 20; GenKey `40 04 …` / `40 00 …`;
  Sign `41 80 …`; ECDH `43 0c|08|0e|04|00 …` (`calib_command.h:433-443`); GenDig `15 02 05 00` + 4 for a NoMac
  slot; host MAC / GenDig formulas against `cal/atca_host.c:473-` and `:849-`. No mismatch found.
- **Operator mistakes** (`TestRevBFlagsAfterCommand`, `TestRevBOutOfOrder`, `TestRevBSilentAfterLock`,
  `TestRevBWritesNearLockBytes`; log `scratchpad/revB-extra.log`): flags typed after the command name are refused
  with exit 2 and nothing sent (5 cases); `lock-data` before the config lock, without `fill-data`, and after a
  stray `data-write 6` → refused by the tool or by the chip's CRC, nothing locked; repeats of `lock-config` /
  `lock-data` → `refused: … already locked`; `raw 17 …` → refused; `raw 0x17` → usage.
- **Policy boundary**: read `policy.go` against impl §2.2; daemon policy passes nothing that writes EEPROM
  (Info 0, plain Read, pass-through Nonce, GenKey 0x00, Sign 0x80, ECDH 0x0C, CheckMac 0); a no-CRC or reserved-bit
  Lock is refused in `Exec` under any policy (M01, N05 killed, with a control that the fake honours such a Lock).
- **Secrets**: se-lab's data-zone content is derived from the chip serial (`cmds.go:28`), nothing secret is on a
  command line, in output, or in the repo; the runbook says the real claim secret never goes through se-lab.
- **Shipped binaries**: `deps_test` has a self-check that the listing is non-empty and a positive control;
  adding an import of `se608/lab` to batman-provhelper (M51) or of `secert` to batman-provd (M52) fails it.
- **Fake chip, what no source supports** (so a test's meaning depends on the fake, not on the chip): slot lock
  and counters need the config lock; external Sign under ReqRandom; encrypted ECDH refused with ChipOptions 0;
  UpdateExtra write-once and mode 2 refused; the data CRC's composition (508A data sheet, inferred for the 608B).
  The fake says so itself (package comment and "Inferred" marks). `TestExperimentWalk` therefore proves what
  se-lab sends and how it reads answers, not what the chip will answer — as its comment says.

Mutants (my choice, applied one at a time in my checkout by `scratchpad/revB-mutants.py` and `revB-mutants2.py`,
suite = `go test -count=1 ./se608/... ./secert/ ./cmd/ ./cmd/se-lab/`; M50 with `-tags prov_test`). 74 written;
3 did not compile (M07, M10, M47) and were redone as N01–N03. Of the 71 valid: **46 killed, 25 survived.**

| Killed (test) | |
|---|---|
| M01 no-CRC Lock refusal removed (TestNoCRCLockNeverSent, TestRandomAndPolicy) | N05 Lock refusal bit 7 only (TestNoCRCLockNeverSent) |
| M02 / M03 / M04 raw sends Lock / Counter / UpdateExtra (TestForGoodRefusals) | M05 typed serial not compared, M06 missing `-serial` (TestForGoodRefusals) |
| N01 allow-list not checked (TestForGoodRefusals, TestRefusals) | M08 `-expect-crc` not compared, M09 image diff not required (TestForGoodRefusals) |
| N02 re-read compare removed (TestLockConfigCatchesAChangeInBetween) | M11 / N12 "locked" not from the chip's bytes (TestLockResultComesFromTheChipsBytes) |
| M12 lock-config dry-run sends, M16 counter-inc dry-run sends (TestExperimentWalk) | M17–M21 a for-good command not `forGood` (TestForGoodRefusals) |
| M22 lock-slot not gated (TestForGoodRefusals) | M29 revision check removed (TestRefusals) |
| M30 / M31 / M32 daemon GenKey / Sign / ECDH any mode (TestPolicies) | M34 / M35 / N13 burn Lock P2, Write mask, any Lock mode (TestPolicies) |
| M36 unknown opcodes allowed, M37 policy not consulted (4 tests) | M38 CheckMac: any status = "wrong response" (TestBurnedChipAsTheDaemonSeesIt) |
| M39 DataCRC private slots (se-lab tests only — see m11) | M40 / M41 Lock packet builders (6 tests) |
| M42 / M43 / M46 / M48 / M49 secert.Parse checks (TestParseRefusesOtherProfiles) | N03 Matches serial (TestBuildParseVerify), N07 MaxLen (TestWorstCaseFitsSlot8) |
| M50 se-fail seam (TestSeFailSeam) | M51 / M52 shipped binary links rig code (TestShippedBinariesDoNotLinkRigCode) |
| M55 lock-data state refusals (TestForGoodRefusals) | M59 lab.Policy allows everything (TestRandomAndPolicy) |

Survived: M13, M14, M15, M23, M24, M25, M26, N04, M54, N10 (→ M2); M58, N08, N11 (→ M3); M27, M28, N09, M33, M44,
M45, M53, M56, M57, M60, N06, N14 (→ m9, m10, m12).

Not verified: anything on a real chip; CI's root + `prov_test` step; the firmware-fork items of impl §2.8; the
app-side parser of the certificate (not in this PR).

---

## Verdicts

**(1) Merging the code: APPROVE-WITH-CHANGES.** No path was found by which a Lock, a counter increment or an
UpdateExtra is sent without the allow list plus the typed serial, no way to get "locked" printed when the chip's
bytes say otherwise, and no wrong-but-accepted lock (se-lab can only lock the variant image, with the CRC the
operator brought, and the chip checks it again). Before merge: M2 (tests, preferably the policy wrapper) and M3
(Lock polling cap, `afterLock` read-back and result line, test). m2 and m3 should be settled in the same PR or
written into the issue checklist.

**(2) Using this se-lab build for the first irreversible step (E4, config lock): APPROVE-WITH-CHANGES.** The
lock-config path itself is the best-covered part of the PR and its packet is confirmed three independent ways. Two
changes first, both in the runbook and both small: M1 (`set -o pipefail` + the self-check line in §1.2) and the
M3 runbook row (what to do on `rc=1` with no `lock_config=locked` line: run `info`, record, stop). The M3 code
change is strongly preferred before E4 as well, since E4 is where Lock first runs on a chip. This verdict covers
§0–§3 of the runbook only; §4.2 onwards (lock-data, lock-slot, update-extra) additionally needs M2 and m1.
