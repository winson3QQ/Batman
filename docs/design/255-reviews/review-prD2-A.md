# PR D2 — code review, Reviewer A

Reviewed: `C:/src/Batman-d2-revA` at HEAD `e1e6506` (base `b64f5b1`), 20 files, +3903/−238; the runbook
`docs/255-rig-runbook-e4.md` in `C:/src/Batman-e13`; against `255-608b-config.md` §4, §8, `255-608b-impl.md`
§2.1/§2.2/§2.5/§2.8/§3.1/§9, `608b-facts.md`, and the pinned cryptoauthlib files in `scratchpad/cal/`.
Everything below marked "ran" was executed in WSL (Go from go.mod's toolchain, `-mod=vendor`), on the fake chip only.
No device was contacted. My checkout is back to a clean tree (`git status --short` empty).

Summary: **0 BLOCKER / 3 MAJOR / 20 MINOR** (13 on the code, m1–m13; 7 on the runbook, r1–r7).
I found no path by which this build sends a Lock, a Counter increment or an UpdateExtra that the operator did not ask
for, no wrong-zone / wrong-slot / wrong-byte-order lock packet, and no case where it prints `=locked` while the chip's
bytes say otherwise. The MAJORs are (1, 2) protections on the irreversible paths that exist in the code but have no
negative control — I removed them and every test still passed — and (3) a design gate that this PR leaves disarmed.

---

## Findings

### MAJOR

**M1. `-dry-run` is the only thing between three runbook commands and an irreversible send, it switches the `-serial`
requirement off, and for lock-data, lock-slot and update-extra nothing tests it.**
- (a) Scenario. The runbook runs `-dry-run lock-data` (§4.2), `-dry-run lock-slot 4` (§7) and `-dry-run update-extra 1 a0`
  (§9) deliberately *without* `-serial`. `main.go:271` and `:309` skip the serial requirement whenever `c.dry` is set,
  so in dry mode the whole protection is one `if c.dry { … return }` block inside each command function
  (`cmds.go:738`, `:755`, `:801`; counter at `:136`, lock-config at `:692`). If any one of those blocks is lost or
  moved in a later edit, the "dry run" locks the data zone / a slot / writes byte 85 with no typed serial and no consent.
- (b) Evidence (ran). Mutants: deleting the dry block in `cmdLockData` → **all tests pass**; in `cmdLockSlot` → **all
  pass**; in `cmdUpdateExtra` → **all pass**; making the flag effective only for lock-config and counter-inc
  (`dry: *dry && (name == "lock-config" || name == "counter-inc")`) → **all pass**. Only lock-config's and
  counter-inc's dry runs are covered (`TestExperimentWalk`). On the unmodified code the dry runs are correct: my
  runbook-literal run shows `dry_run=nothing sent` for all five and exactly 5 Lock / 1 Counter-inc / 2 UpdateExtra
  packets reaching the fake, all from the non-dry invocations.
- (c) Fix. Enforce it once, not five times: in dry mode build the `Dev` with a policy that refuses `OpLock`,
  `OpUpdateExtra` and `OpCounter` mode 1 (then a missing check fails closed with ErrRefused). Add a table test over
  every `forGood` command: `-dry-run` without `-serial` → rc 0, `dry_run=nothing sent`, zero Lock/UpdateExtra/Counter-inc
  opcodes on the fake, config and counters unchanged.

**M2. The sacrificial-list gate has no negative control for lock-config, lock-data, counter-inc, update-extra, or for
12 of the other gated commands.**
- (a) Scenario. Design §8.0 ("能下鎖定指令的建置也受這個清單限制") and the E4 precondition table in §8.3 ("鎖定指令綁犧牲
  晶片序號清單 ❌ … PR D2") make the allow list a stated condition for E4. `TestForGoodRefusals` always passes the
  walker's own allow file, and the one "not listed" case is `lock-slot` only. A command table entry that loses
  `gated: true` would let `lock-config` run on any 608B whose serial the operator types (the serial is printed by
  `info`, so it is a copy-paste, not an independent check); for `genkey`, `priv-write`, `fill-data`, `slot-write`, `raw`
  it would let the rig tool overwrite keys or slot 8 (the certificate; not slot-locked on bench nodes) of a chip that
  is to become a node.
- (b) Evidence (ran). Setting `gated: false` on each entry in `main.go:157-180`, one at a time: **SURVIVED** for
  lock-config, lock-data, counter-inc, update-extra, genkey, priv-write, raw, fill-data, slot-write, config-write,
  write, kdf. KILLED only for lock-slot (and, from the D1 tests, write-image / random / data-write). Also survived:
  skipping the allow-list check in dry mode.
- (c) Fix. One test that iterates the `commands` map: every `gated` command is refused (rc 3, bus not opened) with no
  `-allow`, and refused with zero non-read opcodes sent when the list does not contain the chip. Plus a pin of the
  non-gated set (info, dump, compare, soak, pubkey, counter-read, read, slot-read, image) so a new command cannot be
  added ungated without a test changing.

**M3. `se608.Provisional` is `false` while six of the nine product commands have never run on a chip; the gate the
design relies on for PR 2 is disarmed.**
- (a) Scenario. impl §2.2: "PR D 的狀態碼與位元組格式標為暫定；E1 / E8 / E17 擷取的真實回應回填後才拿掉標記，PR 2 的 CI
  在標記還在時失敗". D2 adds Lock, Nonce, GenKey, Sign, ECDH, CheckMac (and every status code except 0x00/0x0F is still
  from the datasheet summary — `doc.go:14-17` says so itself), but the mark was already cleared after E1–E3
  (`doc.go:24-26`) and `TestWireFormatsConfirmed` (`cmds_test.go:21`) now only asserts that it stays cleared, with the
  message "E1-E3 must run". PR 2 can therefore link the driver into the chip image's helper with CheckMac / Sign / ECDH
  formats nobody has seen a chip accept, and no CI step objects.
- (b) Evidence. `se608/doc.go:14-26`, `se608/cmds_test.go:20-25`, `se608/cmds.go:8-10` ("None of these has run on a
  real chip yet"), impl §2.2 line 71, fake-chip row §4.4 ("格式標為暫定").
- (c) Fix. Keep a mark for what D2 adds, e.g. `ProvisionalCmds = true` (Lock/Nonce/GenKey/Sign/ECDH/CheckMac and the
  status codes) cleared by the commit that back-fills E4/E6/E8/E17 results, and make the consumer test fail while it is
  set *in the package PR 2 gates on* (not in se608's own unit tests, which must stay green now). Or change the design
  sentence — but then say so in the design, not only in a comment.

### MINOR

**m1. "Prints the exact packet first" is untested for four of five commands, and for two of them the printed packet is
built by different code from the sent one.** `counter()` prints `se608.Cmd{Op: OpCounter, P1: 0x01, P2: id}` but sends
`lab.CounterInc(s, id)` (`cmds.go:134` vs `:141`); `cmdUpdateExtra` likewise (`:799` vs `:806`). Mutants that print a
different packet from the one sent survive for counter-inc, update-extra, lock-data (CRC field) and lock-slot; only
lock-config is pinned. Today all five match (ran: printed lines equal the packets the fake received; counter-inc 1 =
`03 07 24 01 01 00 06 f7`, update-extra 1 a0 = `03 07 20 01 a0 00 03 e9`, lock-slot 4 = `03 07 17 12 00 00 8e 08`,
lock-slot 6 = `03 07 17 1a 00 00 cd 89`, all equal to my independent CRC computation). Fix: build the `Cmd` once, print
it, send that same value; assert in the walk that each printed `packet=` / `lock_packet=` equals `chip.Pkts[last]`.

**m2. counter-inc / counter-read can address the wrong counter without any test noticing.** Mutant `fn(s, 1-id)` (both
commands swapped) survives: the walk only looks at the tool's own output, never at `chip.Counters` or the packet.
The runbook says "不要動 Counter[0]". Fix: assert `chip.Counters == [2]uint32{0, 1}` after `counter-inc 1`.

**m3. `=locked` from the chip's bytes is tested for lock-slot only.** Replacing the predicate with `true` for
lock-config and for lock-data survives (`cmds.go:708`, `:743`); `TestLockResultComesFromTheChipsBytes` sets `LockLies`
only around `lock-slot 6`. E4 is the lock-config path. Fix: run the same test for all three.

**m4. A Lock whose response is lost is not tested, and the output for it is easy to misread.** Ran: with the Lock's
response CRC corrupted on the fake (chip did lock) the tool prints `lock_config_after=00`, then an error on stderr,
rc 1, and no `lock_config=` result line. That is safe, but mutant "report locked even when err != nil" survives, and
the runbook's E4 table has no row for it (see r3). Fix: print an explicit `lock_config=LOCKED_response_lost` /
`…=UNKNOWN`; add the test.

**m5. Result keys collide with the header.** Every invocation prints `lock_config=55|00` and `lock_data=…` in its
header, and the lock commands then print `lock_config=locked` / `lock_data=locked` / `…=status_0f` under the same key
(`main.go:298`, `cmds.go:708,743,771,783`). The runbook's E4 table says "`lock_config=` | `locked`" while the file
also contains `lock_config=55` four lines above. For the one step that cannot be repeated, rename the result
(`lock_config_result=`), and print it before the `_after` lines or keep the order but document it.

**m6. lock-slot checks no state.** `cmdLockSlot` (`cmds.go:748`) sends on any chip state. Ran on the fake: after the
config lock and before the data lock `lock-slot 4` succeeds, after which `priv-write 4` and `genkey 4` are refused for
good — on the single chip 1 that loses E6's control and E17. It needs `-serial`, so it is an explicit command, but an
operator who jumps to §7 after a power cycle gets no warning. E13 only needs the chip to refuse a *non-lockable* slot;
requiring "both zones locked" (or printing a loud warning and the slot's Lockable / SlotLocked bits before sending)
costs nothing. The burn flow also locks slots only after the data lock (`cmds_test.go` burn()).

**m7. `counter-inc 0` is accepted.** Design E11: "不動 Counter[0]". Ran: `-serial … counter-inc 0` increments it.
Refuse counter 0 in se-lab (raw cannot send Counter either, so this is the only way).

**m8. Redundant pre-checks with no test** (each mutant survives; in each the chip or a later check still stops the
action, so these are defence-in-depth without a control): lock-config "already locked" (`cmds.go:677`), lock-config
byte-17 check (`:679`, covered by the image diff), lock-data "already locked" (`:717`), lock-data optional
`-expect-crc` (`:735`), lock-config "`-expect-crc` is mandatory" (`main.go:255`; without it the code would nil-deref —
ran: with the check it is rc 2), fill-data "config must be locked" (`cmds.go:266`), fill-data exit code (`:299`),
the in-sequence re-read of block 0 (`:697`, the test only changes byte 84).

**m9. `afterLock` labels a failed re-read as the Lock's status.** In `cmdLockConfig` a StatusError from one of the four
in-sequence Reads is printed as `lock_config=status_xx` (`cmds.go:770`). Not locked either way; wrong attribution.

**m10. WriteSlot's tail addressing is untested for 72-byte slots.** Mutant "tail word index always 0" survives: a
36-byte slot's tail is word 0 anyway, and every test writes zeros to slots 9–15. Slots 9–15 are unused today; add one
non-zero 72-byte round trip so the function is right when someone needs it.

**m11. secert.Parse does not enforce the serial-number length of the profile.** impl §3.1: "序號欄位用 1–8 位元組".
Ran: a certificate with a 20-byte serial, otherwise in profile, is 403 bytes and `Parse` returns nil. Build enforces
1–8, Parse does not. Also: removing Parse's `MaxLen` check survives (the "417 bytes" case is 417 zero bytes, which fail
DER parsing first — not a control); removing the Version/SignatureAlgorithm check survives (no test certificate signed
with ECDSA-SHA384; I built one: the real code refuses it). Add the serial check and the two controls.

**m12. Fake-chip behaviours with no source behind them, or against the only source** (the fake's package comment is
honest in general; these are the ones to mark):
- 4-byte tail writes to IsSecret slots (3, 5, 7 in the variant) are accepted (`fakechip.go:417-436`). facts §2.1 bit 7
  (from the 508A table) says IsSecret prohibits 4-byte reads/writes. So `fill-data` passing on the fake says nothing
  about E6; the runbook's "36-byte slot FAILED → 停" row is the real guard. Add a fake knob (like `OTPReadOnly`) and a
  test that fill-data reports it and lock-data is then refused.
- Lock(slot) allowed between the config lock and the data lock (only "needs config locked" is marked inferred).
- UpdateExtra accepted before the config lock.
- CheckMac needs the data lock; GenKey-public and external Sign work before it; ECDH is not lock-gated at all.
- A CRC mismatch on Lock answers 0x0F (status code not measured); the fake computes the config CRC with the driver's
  own `se608.CRC`, so it cannot catch a CRC bug — the independent golden (`TestChip1LockPacketGolden`, and my own
  recomputation below) is what does.
- Blank data zone and OTP are all zero.

**m13. se-lab cannot say what build it is.** The runbook asks for commit + sha256 by hand. A `version` line (vcs
revision via `debug.ReadBuildInfo`) in every header would put it in every `tee`'d file.

Runbook (`255-rig-runbook-e4.md`):

**r1. E11 writes the wrong counter's bytes.** §6: `config-write 13 00000000` = config bytes 52–55 = the first half of
**Counter[0]**. The step is meant to show Counter[1] (bytes 60–67 = words 15, 16) cannot be lowered, design E11 says
"位元組 52–67", and the same paragraph says "不要動 Counter[0]". The config zone is locked by then so the expected
answer is 0x0F either way, but if the chip did accept it the runbook would have damaged the counter it promises not to
touch and still not tested Counter[1]. Use words 15 and 16.

**r2. Dry runs with nothing to compare against.** §4.2, §6, §7, §9 say "先乾跑…看過再拿掉" but give no expected packet
except for E4. Add them: counter-inc 1 `03 07 24 01 01 00 06 f7`; lock-slot 4 `03 07 17 12 00 00 8e 08`; update-extra 1
a0 `03 07 20 01 a0 00 03 e9`; lock-slot 6 `03 07 17 1a 00 00 cd 89`; lock-slot 5 `03 07 17 16 00 00 0d 8a`
(independently computed, and equal to what the tool prints). For lock-data the tool prints `data_crc=be96`,
`03 07 17 01 96 be 26 70` for this serial with OTP fill 00 — tool-computed only, ⚠️ not independently checked.
§10 has no dry run at all for `lock-slot 6` / `lock-slot 5`, against the rule in the runbook's own preamble.

**r3. E4 table: missing row for a lost response.** If `rc=1` and there is no `lock_config=locked` /
`status_0f` line but `lock_config_after=00`: the chip is locked, the answer was lost. Say so, and say "do not run
lock-config again; run `info`, bring the output back".

**r4. `-allow` and `-serial` come from the same shell variable** (§1.2 `echo "$SN" > allow.txt`, then `-serial "$SN"`).
The second factor is not independent of the first. Acceptable on a rig with one soldered chip; say it, and have the
operator compare `$SN` with the serial in `e1-info.txt` once per session (the `info` row in §2 does this — keep it
mandatory after every reconnect, not only in §2).

**r5. E12 before E13 and E15.** (Design order, so not the runbook's invention.) If the ChipMode-bit-0 assumption is
wrong the chip leaves 0x60 after the power cycle and se-lab has no `-addr`; E13 and E15 are then lost on chip 1. Either
move E12 last or add `-addr` before that step.

**r6. Commands run without an expectation row:** `ecdh 2 compat`, `sign-internal 4`, `sign-internal 2` (§8 loop).

**r7. E15 is narrower than the design's E15** ("憑證寫入槽 8、讀回、驗章"): the runbook writes a pattern and defers the
certificate to F1. Stated in the runbook; record it in the design's E15 row too.

---

## What I verified, and how

✅ **Build / tests (ran).** `go vet` clean and `go test -count=1 ./se608/... ./secert/ ./cmd/ ./cmd/se-lab/` all `ok`,
with and without `-tags prov_test`; 83 test runs, no SKIP; `se608/fakechip` has no test files of its own (exercised
through the others). CI (`.github/workflows/ci.yml:146,152`) runs `go test ./...` on Linux for both tag sets, so the
`//go:build linux` se-lab tests are not silently empty there.

✅ **Lock packet layout vs vendor.** `calib_lock.c`: param1 = mode, param2 = summary CRC; `calib_command.h:589-595`
LOCK_ZONE_CONFIG 0x00, DATA 0x01, DATA_SLOT 0x02 (`| slot << 2`), NO_CRC 0x80, bit 6 reserved. Code: `packet.go`
constants, `cmds.go:104-114`, `policy.go` PolicyBurn, `dev.go:125` (refuses 0x80 and 0x40 before any policy).
se-lab reaches Lock only through `LockConfigCmd / LockDataCmd / LockSlotCmd`; `raw` refuses 0x17/0x24/0x20.

✅ **E4's numbers, independently.** I ported `atCRC` (`calib_command.c:706-729`) to Python
(`scratchpad/revA/crc.py`) and ran it over the 128 bytes of the real chip's final dump (`results/e3-verify.txt`):
```
config crc 9022 bytes(le) 22 90
packet 03 07 17 00 22 90 1d 15
```
Same as design §8.3, the runbook, and `TestChip1LockPacketGolden`. The variant image in `image.go` equals design §4 +
§8.1 and equals the chip's read-back (`e3-image.txt` / `e3-verify.txt`).

✅ **Other formats vs vendor (read).** Execution caps = `device_execution_time_608_m0` (all 21 values);
ECDH 0x0C = slot source + clear + output buffer (`calib_command.h:433-443`); KDF mode/details/keyID
(`calib_kdf.c`, `:541-581`; packets seen on the fake: `56 52 05 00 02 00 00 10 …`, `56 12 … 01 00 00 10`,
`56 4a 03 06 …`); Counter mode/id and little-endian value (`calib_counter.c`); UpdateExtra (`calib_updateextra.c`);
clear PrivWrite 36 + 32 zero bytes (`calib_privwrite.c`); HMAC start 0x04 / 608 end 0x02; GenDig NoMac OtherData
(`atca_host.c:849+`). ⚠️ `HostMAC` I checked by structure only (the include-data helper was not in my extract).

✅ **The runbook, literally (ran).** A test in my checkout fed every command line of runbook §2–§11 (shell-split, with
`$SN`, `$B17`, `$BLOB` substituted) to `run()` on a fake that starts from the real chip's E1 dump
(`fakechip.RealBlank()`); output in `scratchpad/revA/runbook.out`. Every expected string in the runbook appears as
written (`compare=EQUAL`, `config_crc=9022`, `lock_packet=03 07 17 00 22 90 1d 15`, `dry_run=nothing sent`,
`lock_config=locked`, `lock_config_after=00`, `config_write_word17=status_0f`, `slot_locked_after=ffef`,
`lock_slot5=status_0f` with rc 1, `slot_write_slot8=written_416_bytes`, …). ⚠️ hmac / kdf / aes answer `status_03` on
the fake (not modelled): for those only the packets were checked. ⚠️ What the fake answers for E4–E17 is the design's
expectation, not a measurement.

✅ **Operator slips (ran).** `lock-slot 6 -dry-run` → rc 2 (flag after the command is an extra argument); missing
slot → rc 2; `lock-slot 16`, `counter-inc 2`, `update-extra 3 00`, `update-extra 1 1a0` → rc 2; `raw 17 …` → rc 3;
`raw 0x17` / `raw 117` → rc 2; empty `-serial ""` → rc 3 before the bus; lock-config without `-expect-crc` → rc 2;
wrong `-byte17` → rc 3; lock-config on a locked chip → rc 3; lock-data on a locked chip → rc 3. Lock opcodes on the
fake after all of them: only the five intended.

✅ **Secrets.** Nothing secret is taken on the command line by design: fill-data / checkmac / priv-write use values
derived from the serial (`cmds.go:28-45`); no key material, PEM or password in the diff (grep). `slot-write`, `write`
and `raw` do take data as arguments — fine for the rig, and the header says no real claim secret goes through se-lab.

✅ **Shipping gate.** `cmd/deps_test.go`: importing `se608/lab` into batman-provhelper → KILLED; importing `se608`
into batman-provd → KILLED; it has its own "list is not empty" control. Seam: arming it in a release build → KILLED
(everything fails); never decrementing → KILLED; off by one → KILLED (`TestSeFailSeam`, prov_test).

### Mutants (101 tried, 4 did not compile, 60 killed, 37 survived; scripts `scratchpad/revA/mut.py`, `m1.py`, `m2.py`; raw results `m1.py.out`, `m2.py.out`)

KILLED (protection has a working negative control):
no-CRC Lock refusal removed / reduced to bit 6 (`TestNoCRCLockNeverSent`); `-serial` not required; `-serial` not
compared with the chip; lock-config: `-expect-crc` not compared, image diff not enforced, re-read compare limited to
block 0, dry-run ignored, CRC byte-swapped, packet printed ≠ sent; counter-inc dry-run ignored; raw sends Lock /
Counter / UpdateExtra; `=locked` from status alone (lock-slot); LockSlotCmd shift; LockConfig↔LockData swapped (both
directions); DataCRC includes private slots; ConfigCRC skips bytes 0–15; revision check removed; lock-data before the
config lock; each of lock-config / lock-data / lock-slot / counter-inc / update-extra losing `forGood`; lock-slot
losing `gated`; every PolicyDaemon / PolicyBurn relaxation I tried (11); CheckMac status handling (2); Exec accepting
a non-zero status; `New()` returning the burn policy; lab.Policy allowing every opcode; fill-data writing private
slots; write-image on a locked chip; lock-slot locking slot+1; counter-read incrementing; SlotLocked bit order;
`-otp-fill` ignored; secert: critical flag, issuer, validity, subject CN, map size; deps test (2); seam (3).
Four more "failed" only because the mutant did not compile (allow-list check, re-read compare, soak compare, secert Matches serial) —
not counted as evidence; the allow-list one is covered by M2's finer mutants.

SURVIVED (no test fails): see M1 (4 mutants), M2 (13), m1 (4), m2 (1), m3 (2), m4 (1), m8 (8), m10 (1), m11 (2),
plus `secert` curve check (equivalent: a non-P-256 key fails the 65-byte check next).

### Not verified

❌ Nothing here ran on a real chip; I did not touch the rig.
❌ `proto.CheckMacInput` / `proto.OtherData` (baseline, not in this diff) I did not re-derive against `atcah_check_mac`.
❌ The data-zone CRC rule (private slots skipped) and the 4-byte tail write are still paper (facts §1.3, §2.1); a wrong
guess makes the chip refuse (if it checks as documented) — E6 is the measurement.
❌ I did not review D1 code except where D2 calls it (`wake`, `Do`, `Exec` polling, `OpenI2C`).

---

## Verdicts

**(1) Merging the code: APPROVE-WITH-CHANGES.** M1, M2, M3 before merge; the MINORs can ride along or go to the PR's
checklist. No defect found in the behaviour of the irreversible paths themselves.

**(2) Using this se-lab build for the first irreversible step (E4, config lock): APPROVE-WITH-CHANGES.**
The lock-config path as built at `e1e6506` does what the design asks: it refuses unless the chip holds the image, the
CRC equals the one brought in, the allow list and typed serial match, re-reads in the same sequence, sends
`03 07 17 00 22 90 1d 15` (independently recomputed), cannot send a no-CRC lock, and reports `locked` only from byte 87.
Conditions:
1. If E4 is run from this exact commit, runbook §0–§3 can be followed as written once r3 (lost-response row) and m5's
   note on the two `lock_config=` lines are added to §3. If the code changes first (M1/M2 fixes), rebuild, re-run the
   suite, and record the new sha256 — and the M2 test for lock-config must be in that build.
2. Runbook §4 onward (lock-data, counter, slot locks, byte 85) should wait for M1 (dry-run controls), r1 (E11 word)
   and r2 (expected packets). None of these touch E4.
