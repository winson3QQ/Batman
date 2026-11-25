# Review A — `255-608b-config.md` v1 (ATECC608B configuration zone and slot design)

Reviewer A, independent, 2026-11-23. Base: worktree `C:/src/Batman-255`, main 4eba26d plus the untracked design files.
Rules applied: `docs/design/REVIEW.md`, the task brief, threat model v2 §5.1 / §8.2 / Appendix A, key-authority v3 (K16).
No device was contacted. Nothing was built.

## 0. What I read, and how far the evidence goes

| Tag | Source | How read |
|---|---|---|
| [D] | `docs/design/255-608b-config.md` | whole document |
| [F] | `docs/design/255-reviews/608b-facts.md` | whole document |
| [TM] | `docs/design/255-threat-model.md` | §5.1, §8.2, Appendix A, requirement rows R1–R15, R66, R76, R79, R84, R101, R102, R106, R110 |
| [KA] | `docs/design/255-key-authority.md` | whole document |
| [SRC] | `feed/batman-prov/src/keystore/keystore.go` (whole), `proto/proto.go:15-80`, `provd/server.go:320-362`, `app/rust/batman-proto/src/nodecert.rs:130-190`, `docs/design/219-protocol.md` §3.3, §3.6, §5.4, §7.3, §9, `docs/design/254-stage1-impl.md:205-222` | the cited ranges |
| [CAL] | MicrochipTech/cryptoauthlib `main`, fetched today with `gh api …/contents/<path>`: `lib/calib/calib_device.h` (279 lines), `lib/host/atca_host.c` (1936 lines) | field macros read in full; `atcah_nonce`, `atcah_check_mac`, `atcah_gen_dig`, `atcah_write_auth_mac`, `atcah_decrypt`, `atcah_gen_key_msg`, `atcah_sign_internal_msg` read |
| [TFLX] | ATECC608B-TFLXTLS complete data sheet DS40002249A, fetched today from `ww1.microchip.com/downloads/en/DeviceDoc/ATECC608B-TFLXTLS-CryptoAuthentication-Data-Sheet-DS40002249A.pdf`, converted with `pdftotext -layout` | §2.2 (slot notes), Table 5-11 (Info device state), §5.1.4 Nonce, §5.2.1 ECDH, §5.2.2 GenKey (all four sub-sections), §5.2.4.1 Sign internal, §5.3.2 CheckMac, §5.3.3.3 / §5.3.3.5 GenDig, error-code table |

Limits. I did not read the ATECC508A complete data sheet; every statement [F] attributes to it is taken from [F] and
marked "per [F]". The ATECC608B complete data sheet is NDA-only and unread by anyone here. `atca_host.c` is Microchip's
host-side model of the chip, not the chip; where I use it as evidence I say "host model". Nothing below was observed on
a chip.

## 1. Summary

The three-key split (endorsement IntSign-only / session ExtSign-only / ECDH-only) is the right shape and every
SlotConfig / KeyConfig / ChipOptions value decodes to exactly what its row in §4.2 / §4.1 says. No bit-position or
byte-order error was found.

The problems are in three places where the value is internally consistent but does not do what another section of the
design needs, and in the experiments:

- the claim-secret slots are keyed to themselves while §5.2 describes cross-authorisation, and Microchip's own host
  model refuses the encrypted-write flow for a NoMac key under either keying;
- `ReqAuth` with an unlocked, replayable slot 3 adds a permanent, unauthenticated kill switch for all five keys and an
  untested command sequence in front of every endorsement, in exchange for an option whose configured form is defeated
  by a passive bus tap;
- K16 holds only if the verifier checks the outer 55-byte message field by field; the design states a weaker check, and
  two fields the fact base treats as trustworthy are host-supplied on some command paths;
- §7 can pass vacuously in several rows, has no positive controls, and its fall-backs each cost a chip that the budget
  does not have.

Counts: **2 BLOCKER, 6 MAJOR, 12 MINOR.** Verdict: **REJECT** (§6). Most fixes remove configuration; none needs a new
mechanism.

## 2. Findings

### BLOCKER

**B1. Claim-secret slots 5 / 7: the hex and §5.2 disagree about who authorises a rewrite, and the configured flow is
refused by Microchip's host model.**

(a) Scenario.
1. §4.2 sets slot 5 = `0x459F` (WriteKey = 5) and slot 7 = `0x479F` (WriteKey = 7): each slot is rewritten under its
   **own current value**. §5.2 says the holder of the current QR "knows the current secret and can compute the
   authorisation to rewrite the **other** slot". With the configured values that is false: rewriting slot 7 needs slot
   7's current value. Nothing in [D] says the QR holder knows it (§6-5 puts only the current secret in the QR). After
   the first rotation the old slot is "rewritten to random"; whoever does not keep that random can never write that slot
   again, so the second rotation is impossible for a buyer who received only the QR.
2. E9 is worded "authorise rewriting the other slot with the current secret → …". If the tester initialises both slots
   to the same value, or computes the MAC with the target slot's own value because that is what the chip accepts, E9
   passes and the mismatch is locked into every chip.
3. Independently of the keying: the write is authorised by GenDig on the WriteKey slot. Both candidates are NoMac
   slots. Host model: GenDig on a NoMac slot sets `no_mac_flag = 1` ([CAL] `atca_host.c:1000-1003`), and
   `atcah_write_auth_mac` refuses a TempKey whose `no_mac_flag` is set ([CAL] `atca_host.c:1161-1168`, comment
   "TempKey.CheckFlag must be 0"); `atcah_decrypt` has the same condition (`:1476`). So the best available evidence says
   an encrypted Write keyed by a NoMac slot fails. [F] §4 lists this as NOT FOUND and also states the opposite ("the
   resulting TempKey can still serve as the data-protection key for encrypted Read/Write") without a source.
4. `ReqRandom = 0` on these slots lets the GenDig nonce be a pass-through value, so a recorded encrypted Write is
   replayable for as long as the authorising slot is unchanged.

(b) Evidence: decode table §3; [D] §4.2, §5.2, §6-5, §7 E9; [CAL] lines above; [TFLX] §5.3.3.3 notes ("TempKey.NoMacFlag
will be set to … 1 if it is not [allowed]").

(c) Fix. Decide before E4, not after:
- Preferred (removes an option): slots 5 and 7 become `0x8F9F / 0x001C` (never writable), one of them unused; C5 is
  recorded as not met. [TM] R6 / R7 already require that the printed secret alone gives no authority over an enrolled
  node, which is the control T-SE5 actually relies on; a rotatable QR adds a marker file, a two-slot protocol and a
  power-loss matrix for a secondary benefit.
- If the user wants C5: the authorising key cannot be a NoMac slot unless a chip proves otherwise. Test it on the
  variant chip of M2 (self-keyed, cross-keyed, and non-NoMac-keyed candidates side by side) and bring the result back
  to review. Do not carry "授權金鑰 = 自己" and "改寫另一個槽" in the same document.
- Either way delete the "current slot" marker (m7).

**B2. `ReqAuth` (slots 0, 1, 2, 4, 9 → AuthKey slot 3) is not safe to lock as configured.**

(a) Scenarios.
1. *The option that is being preserved is already defeated.* Slot 3 KeyConfig = `0x003C`, `ReqRandom = 0`. CheckMac
   mode 0x00 and modes 0x01/0x05 hash the same layout; only the second block differs (host challenge vs TempKey)
   ([TFLX] Table 5-82; [CAL] `atcah_check_mac`, `atca_host.c:620-644`). A bus tap records one authorisation by the
   honest helper in any mode, computes the TempKey from the visible RandOut / NumIn if needed, and replays it as mode
   0x00 with `ClientChal` = that value. After slot 3 is locked ("binding active", §5.3) the tap can authorise the keys
   on any host, which is exactly the "另接一個主控端" case §5.3 says the binding stops. KeyConfig cannot be changed
   later, so the option kept for C9 is permanently the weak one. (Whether `ReqRandom = 1` closes mode 0x00 is itself
   unverified, [F] §4 last bullet.)
2. *Kill switch.* While slot 3 is "Always-write, lockable, not locked" — every chip from the factory until an
   unscheduled secure-boot phase — two commands from any bus master (Write slot 3 with random; Lock slot 3) make slots
   0, 1, 2, 4, 9 unusable for ever. Lock carries no authorisation ([F] §11). Actors: a process that is root once
   (remotely, on every node it reaches), a repair shop, anyone with clips on header pins 3/5 for a minute. [D] §5.5
   states the outcome and cites T-SE6, but T-SE6 / R9 ask for damage that is "repairable by the organisation without
   the vendor"; a chip soldered on the HAT is not. Without `ReqAuth`, slot-locked keys in slots 0–2 cannot be destroyed
   by any command at all.
3. *Every endorsement needs an untested sequence.* AuthValid is cleared by any command that uses a ReqAuth key
   ([F] §2.2). Endorsing slot 0 or 2 is: authorise → Nonce → GenKey(digest) on the target (uses a ReqAuth key, clears
   AuthValid) → **authorise again** → Sign(internal, slot 1). Whether TempKey survives a CheckMac in between is not
   stated in any source read ([TFLX] §5.3.2 is silent; the host model does not model it). If it does not survive, slot
   1 can never endorse slot 0 or 2 and the K16 mechanism does not exist. E7 does not mention authorisation; E-A tests
   only authorise → external sign.
4. *If never activated* the cost is all of 2 and 3, plus one CheckMac per use and authorisation before every
   public-key read at boot (GenKey "checks for usage authorization", [F] §2.2), for zero protection ([D] §5.3 second
   bullet says so).
5. *If activated* the gain is narrow: it stops use of a HAT that was separated from its board and never observed
   talking to it. An attacker with clips on a running node issues their own command after the helper's CheckMac and
   before its Sign.

(b) Evidence: decode table §3; [D] §4.2, §5.3, §5.5, Q2 (which tells the user the cost is "40–60 ms" and omits 2 and 3);
[F] §2.2, §11; [TFLX] Table 5-82; [TM] T-SE6, R9, Appendix A items 12 and 19.

(c) Fix. Take it out: KeyConfig `0x0073` for slots 0, 1, 2 (and 4, 9 if kept, m1); slots 3 and 14 become
`0x8F9F / 0x001C`. Record Appendix A item 19 as "decided: no; not available on this hardware generation" and item 12
as "no key-disable feature exists". If the user still wants the option after seeing scenarios 2 and 3, it needs at
least `ReqRandom = 1` on slot 3 (`0x007C`), slot 3 written and locked at the factory with a recoverable value, a stated
answer for "SD card replaced", and its own experiments for 1 and 3 — that is a new design and another review round.

### MAJOR

**M1. What the verifier must check to make K16 true is under-specified, and two fields the fact base trusts are
host-supplied.**

(a) Scenario. [D] §6-1 says the app "checks the slot's configuration bits and lock state". [F] §3 and §17 E7 go
further and treat the GenKey mode byte inside the digest as evidence. But:
- GenKey mode 0x10 (digest of a stored public key, slots ≥ 8) hashes **host-supplied OtherData[0..2] in the positions
  of Param1 / Param2** — "the 3 bytes in OtherData will be used to generate the digest and the mode and KeyID bytes
  will be ignored" ([TFLX] §5.2.2.4). An attacker who can get a public key of their own into a slot that accepts mode
  0x10 produces a TempKey byte-identical to the digest of "GenKey 0x08 / 0x0C on slot 2" and has slot 1 sign it. The
  only things that then separate "attacker's key" from "key in slot 2" are in the **outer** message: SlotConfig /
  KeyConfig of TempKey.KeyID, the KeyID nibble in TempKeyFlags, and SlotLocked.
- GenDig on a NoMac slot hashes 4 host-supplied bytes in place of opcode / zone / KeyID ([CAL] `atca_host.c:905-909`;
  [TFLX] Table 5-89). Slots 3 and 14 are NoMac and Always-writable, so the first 36 bytes of that GenDig message are
  attacker-chosen. Example: slot 3 := 32 zero bytes, OtherData = `15 04 01 00` gives exactly the TempKey of
  "GenDig(Counter 1) with counter = 0". Again only TempKeyFlags (GenDigData = 1, NoMacFlag = 1, KeyID = 3) and the
  SlotConfig / KeyConfig bytes differ.
- Slot 9 has the same SlotConfig / KeyConfig as slot 0, slot 4 the same as slot 2, and any bus master can generate and
  lock them. The only difference in an endorsement is the KeyID.
- The session key signs any digest, including `"batman-node-ecdh-v1" ‖ attacker_pub` in today's format
  (`keystore.go:86-103`, `provd/server.go:343`). If any verifier still accepts a label-format `sig_ecdh` or
  `sig_static`, T-SE2 is back.

In the present configuration mode 0x10 should be refused (all slots ≥ 8 that are writable have KeyType 7; GenKey "on a
non-ECC slot will result in an error", [TFLX] §5.2.2.1) — unverified on a chip, and not in E7.

(b) Evidence: sources above; 55-byte layout [TFLX] §5.2.4.1 and note 2; [CAL] `atca_host.c:1676-1679`; [TM] R3 negative
test "by every command path available".

(c) Fix (narrowing only).
- §6-1: the verifier **reconstructs all 55 bytes from constants** and verifies the signature over that; it never parses
  a message supplied by the node. Constants per endorsed key: Sign opcode / mode / KeyID = 1; SlotConfig and KeyConfig
  of the one allowed slot; TempKeyFlags with GenKeyData = 1, GenDigData = 0, NoMacFlag = 0, KeyID nibble = the allowed
  slot, SourceFlag as specified; SlotLocked = locked; SN bytes. The inner digest's mode / KeyID bytes are not evidence.
- §6-1: no verifier accepts a slot-0 signature as an endorsement of any key; the label-format `sig_ecdh` and
  `sig_static` are removed, not kept beside the new format.
- E7 adds, each as "must fail or yield a message the reference verifier rejects": Nonce(pass-through) → Sign(internal);
  Nonce(random) → Sign(internal); GenDig(each data slot, incl. NoMac with chosen OtherData) → Sign(internal);
  GenDig(Config / OTP / KeyConfig / shared-nonce zones) → Sign(internal); GenKey 0x10 on slots 8–13 and on 9;
  endorsement of slots 4 / 9; Sign(internal) with the SN-less mode.
- Remove the primitives rather than test around them: slots 3 / 14 (B2), 4 / 9 (m1), 10–13 (m2).

**M2. §7 cannot fail in several rows, has no positive controls, and its fall-backs cost chips that are not budgeted.**

(a) Scenario.
- *Order.* The outcomes of E8, E9, E10, E-A change configuration bytes (`0x8F9F`, `0x0073`, or "back to design"). All
  four run after E4. One fall-back makes chip 1 a different configuration from the final one; chip 2 is then the first
  chip with the final configuration and there is no chip left for "repeat the final configuration in full". Two
  fall-backs are likely on current evidence (B1 item 3; B2 item 3). Two sacrificial chips are not enough for the plan
  as written.
- *Vacuous passes.* E9 (B1 item 2). E8 / E6 / E7 / E12 / E13 "must fail": a command also fails for a wrong length,
  wrong mode or a missing Nonce. Without a control slot where the same command sequence **succeeds**, a harness bug
  passes every negative test. E2 and E5 have no pass condition ("record"). E7's "record whether the digests differ" is
  not a pass condition for C1.
- *Unverified behaviours with no experiment:* TempKey survival across CheckMac (B2-3); CheckMac replay / mode 0x00 on a
  ReqRandom key (B2-1); authorisation before GenKey public read; ECDH mode 0x05 and KDF with a slot target aimed at
  slots 5, 7, 15 and at slot-locked slots ([TFLX] Table 5-46 "Results stored in specified slot" — which policy bit
  gates the target is not in any source read; if a claim slot can be overwritten this way, R5 fails); ECDH 0x0E with
  slot 6 unwritten and with slot 6 attacker-written; Write to slot 15; Lock(slot) on a key slot **before** GenKey (a
  locked empty key slot); UpdateExtra on byte 84; the health-test latch (M3); everything in M1(c).
- *Missing step.* A data lock "with CRC" needs the host to know every non-private slot and the OTP, and the data zone
  cannot be read before the lock ([F] §1.3). E6 must therefore write all of them, including the unused ones. Not
  stated.
- *Pre-lock item left open.* [TM] §8.2 note on item 11: bus sharing and address are closed before the lock. [D] §6-2
  says who else reads the bus "has not been checked".

(b) Evidence: [D] §7, §4.2 notes; [TM] R15, Appendix A 11 and 14.

(c) Fix.
- Chip 1 is a **variant chip**, not the candidate configuration: spare slots carry the alternatives side by side (a
  ReqAuth key and a plain key; a self-keyed, a cross-keyed and a non-NoMac-keyed secret; a NoMac and a non-NoMac
  control secret; one never-write slot). Every open [A] is answered on it. Chip 2 gets the final configuration and the
  full list. Budget a third from the six spares and say so in Q3.
- Every "must fail" row names its positive control and the expected status code.
- Add E0 (read-only, before E1): list every device and every program on the HAT bus.
- Give E2, E5 and E7's digest comparison a pass condition or delete them.

**M3. ChipOptions bit 3 is set to 0 without a decision.**

(a) Scenario. `0x6002` leaves bit 3 clear. [F] §5 names it "Health-Test-Failure auto-clear" (TFLX only). The TFLX part
sets it and documents the effect: "The Health Test Failure bit is cleared after any time that a command fails as a
result of a health test failure … the command may pass when run a second time" ([TFLX] §2.2). With the bit clear, error
0x08 means "the chip fails subsequent commands requiring a random number until it is cleared" ([TFLX] error table); how
it is cleared in that mode is in no source read. Sign, GenKey and random Nonce all need the RNG. An unattended relay
whose chip latches a transient RNG failure loses its identity until an unknown event — possibly a power cycle of the
HAT, which a reboot of the Pi may not give.

(b) Evidence: decode §3; [D] §4.1 row 90–91 ("其餘 0", no reason); [TFLX] as quoted; `calib_device.h:234-249` has no
macro for bit 3, so the library gives no second source.

(c) Fix. Make it a stated decision with the latch-clearing behaviour as evidence. Absent a reason to differ from
Microchip's reference configuration, set bit 3 (`0x600A`, bytes `0A 60`; `0x0008` if IO protection is dropped, m3).

**M4. C6 (enrolment counter) is not met as written, and its evidence mark is wrong.**

(a) Scenario.
- §5.6 calls the counter a one-way indicator of "at least N enrolments". Any bus master can increment it without an
  enrolment; a root-level helper can enrol without incrementing. The value bounds the number of enrolments in neither
  direction.
- §5.6 does not put a verifier nonce into the signed value. A recorded attestation of count 3 is replayed when the
  count is 9: the display goes down.
- "The chip can include the counter value in the signed message, F§7 ✅": [F] §7 says GenDig(Counter) folds the value
  into TempKey and *concludes* it can be signed. [TFLX] §5.3.3.5: after GenDig(Counter) "TempKey.GenDigData will be set
  to 0" (host model `atca_host.c:1005-1008` also sets KeyID = 0). Sign(internal) requires a TempKey "generated using
  either the GenDig or the GenKey command" ([TFLX] §5.2.4.1). Whether the chip accepts a TempKey with neither flag set
  is unknown. If it does, the same must be shown *not* to hold for a bare Nonce (M1).

(b) Evidence: as quoted; [D] §1 C6, §5.6, E11.

(c) Fix. Restate C6 as "a number that cannot go down, shown only with a fresh app nonce; it is not a count of
enrolments". Mark the Sign-over-counter claim ⚠️. E11 adds: replay of an old attestation is rejected by the reference
verifier. If the user wants a real count, that is a phase-2 question, not a chip bit; the chip configuration is
unaffected either way.

**M5. REVIEW.md items 1–3 are absent: no ownership table, no contracts, no lifecycle matrix.**

(a) Scenario. The chip is shared state with irreversible transitions. Rows whose answer is missing and matters:
- *SD card replaced / restored.* The "current claim slot" marker, the "factory record of expected lock states" (§5.5)
  and (if B2 stays) the slot-3 value live on the data partition. After a card swap: which slot is current, what is the
  lock-state check compared against, and is the chip still usable?
- *Enrolment and factory reset.* Who increments Counter 1, at which step, and what a power cut between the increment
  and the record commit leaves ([TM] R76, R110). [F] §7: a power loss can add more than one.
- *Factory reset / resale.* What in the chip changes ([TM] R66). As configured: nothing (identity fixed, QR fixed unless
  B1's rotation works). Say so.
- *HAT replaced, board replaced, chip blank / absent / swapped.* §6-3 gives the behaviour for three of these; the test
  for each and the "transient bus failure at boot" case of T-SE14 are missing.
- *Factory.* Which station writes, generates and locks each slot, in what order, and what it records per unit.
- *Dev vs production chips.* Where a bench chip's dev-root certificate comes from and what stops a bench chip's
  configuration (possibly from the variant set) reaching a production unit ([TM] R15: "the lock tool refuses a
  configuration that differs").
- *Ownership.* For each of slots 0–15, both counters, bytes 84 / 85 and each SlotLocked bit: the single component
  allowed to write / generate / lock / increment, and the fact that the chip enforces none of it.

(b) Evidence: `docs/design/REVIEW.md` "The design must state" 1–3; [D] has none of the three sections.

(c) Fix. Add the three tables. Several rows shrink to "nothing changes" once B1, B2, m1 and m2 are applied — a reason
to apply them first.

**M6. C1 claims more than the configuration or the experiments deliver.**

(a) Scenario. C1: keys are generated in the chip "and the verifier can confirm this". For slot 1 the design says the
assurance is the factory (§5.1 third bullet). For slots 0 and 2 the endorsement shows "not writable, locked, in the
chip whose slot-1 key signed this". It does not show "generated", because a key injected in the open window and then
locked gives the same SlotConfig / KeyConfig / SlotLocked. The only candidate evidence is the GenKey mode byte (0x0C vs
0x08) in an endorsement made at creation time: an inference ([F] U19), reachable only through the untested sequence of
B2-3, needing ~150 bytes of stored evidence per key that no slot is assigned to, and worthless against the one actor
that can inject (whoever controls the open window also controls slot 1). [TM] R14 says "factory included".

(b) Evidence: [D] §1 C1, §5.1, E7; [F] §3; [TM] R14 and its §11 reading.

(c) Fix. State C1 as: "after the data lock nobody can write a private key; a verifier can confirm non-writable, locked
and in-chip; on-chip generation rests on the factory procedure (#256)". Drop the mode-byte comparison from E7. Record
R14 as partly met.

### MINOR

**m1. Spare key slots 4 and 9 have no stated use and are regenerable and lockable by any bus master.** Slot 1 (the
identity) cannot rotate, so rotating 0 / 2 changes nothing a verifier anchors on; nothing says who would authorise a
rotation. They double the keys an endorsement verifier must tell apart (M1), and slot 9 is the only private slot in the
≥ 8 range that GenKey mode 0x10 addresses. Fix: `0x8F9F / 0x001C`, or name the phase and the authorising party.

**m2. Slots 10–13 "reserved public data, Always-write, lockable" reserve nothing.** The first bus master to write and
lock one owns it. They are 288 bytes of storage that survives reflash and factory reset for any root process (a tag a
previous owner or malware leaves behind), and the only place an attacker-chosen public key could sit (M1). [TM] §8.2
item 15 asks to reserve by policy class; "anyone, once" is not a class a later use can rely on. Fix: write and lock at
the factory what is needed (certificate overflow, m9), make the rest never-write.

**m3. IO protection enabled with ECDHPROT = 0 and slot 6 empty and unlocked.** It weakens nothing today (clear output
is allowed anyway), and protects nothing later against an active bus master, who asks for mode 0x0C. It helps only
against a passive tap when the host chooses 0x0E, with a key that sits on the same card. Slot 6 has NoMac = 0, so until
it is locked any bus master can set and lock it. Fix: `ChipOptions` without bit 1 / slot nibble and slot 6 never-write,
or keep it and state that it is passive-tap-only; if real protection is wanted the bit is ECDHPROT = 1, which needs
slot 6 provisioned at the factory — not this phase.

**m4. §6 does not list the split between `device_id` and the chip serial number.** The app computes the claim response
with `sn[8]`, `sn[0:2]` from `node_cert` key 7 (`proto.go:53-70`, `219-protocol.md` §5.4 "SN = node_cert 裡的 608B
序號"), and `219` §3.3 fixes `device_id = hex(sn)`. With `device_id = SHA-256(endorsement pub)[:9]` these become two
values; if key 7 carries the hash, every claim on a real chip fails. `device_id` itself is consistent with
`nodecert.rs:177-180` and `keystore.go:118-120` provided "DAC public key" is defined as the slot-1 public key in SEC1
uncompressed form. Fix: add both sentences to §6; state the expected SN[8] (0xEE per [F] §8, to be read in E1).

**m5. §6-1 understates the `node_cert` change.** Keys 5 / 6 (`sig_static`, `sig_ecdh`) are replaced by a session
public key, two endorsements with their nonces, and a per-handshake signature; `verify_offline` requires exactly keys
1–7 (`nodecert.rs:160-168`); `trust_gate` rejects every non-`dev:` certificate (`:146-156`); `ClientChal` hashes the DAC
DER (`proto.go:50-52`), so slot 8 must hold bytes that never change. `SignPurpose` (`keystore.go:86-103`) maps onto
slot 0 for `PurposePeer` only; `PurposeStatic` and `PurposeECDH` have no chip equivalent by design. List these as
requirements so the phase-1 design cannot keep the old fields "for compatibility".

**m6. `ReqRandom = 1` on the key slots has consequences the design does not state.** An endorsement of slot 0 / 2
needs a random-mode Nonce (the verifier's nonce goes in NumIn; RandOut must be returned to it), and SourceFlag is part
of the signed flags byte. External signing is unaffected by precedent (TFLX slot 0 = `0x0053` signs TLS digests). Also
§2's "one more signature, ≤ 115 ms" omits the Nonce / digest load (20 ms) and, while B2 stands, a CheckMac (40 ms).

**m7. The "current claim slot" marker is a second writer-less resource with no benefit.** The chip accepts a CheckMac
on either slot regardless; tampering is only a denial; a restored card image points at a scrubbed slot. Fix: no
marker — try both slots (moot if B1 ends at a single fixed slot).

**m8. Appendix A items with no statement in the design:** 8 (trust anchor: rejected in §5.8 on the strength of secure
boot and partition encryption that do not exist yet — say what protects it in state OFF, or that nothing does), 12
(key-disable features: none wanted; today B2 is one by accident), 17 (no host-usable value derived from the printed
secret exists, and phase 2 may not assume one — [KA] §5 problem 3), 3 / R66 (ECDH and identity keys are not
regenerable: no resale privacy, stated as a choice). Table in §4.

**m9. Slot 8 format and size are undefined.** "Factory signature and related fields" in 416 bytes; `node_cert` and
`ClientChal` expect X.509 DER, and a P-256 leaf is in that size range before any intermediate ([TM] §8.2 item 9,
per-batch intermediates). Check the fit before E4; E15 has no size criterion.

**m10. The reviewed artefact should be the 128-byte image.** §4 gives fields and "keep the blank value" for bytes not
yet read. Before E4 the document should carry the full image (bytes 16–127 as written), the bytes excluded from later
comparison (0–15 device-specific, 52–67 counters, 84–85 UpdateExtra, 86–89 locks), and its CRC, and the lock tool should
refuse anything else ([TM] R15). ChipMode bit 1 "keep blank" should become a chosen value once E1 has read it.

**m11. §4.1 wording.** "Counter initial value = keep blank (= 0)": the count is 0 but the bytes are expected to be
`FF FF FF FF 00 00 00 00` ([F] §7); write "do not touch bytes 52–67". Bytes 84 / 85 cannot be written before the lock
at all (UpdateExtra only, [F] §1.2); "set to 0x00" should read "left".

**m12. Factory exposure in the open window is not stated.** Claim secrets (and slot 3 / 6 if kept) are written in
clear on the bus between the two locks ([F] §10). Acceptable — the station prints the QR — but it belongs in the
factory row of M5 and in #256.

## 3. Per-slot decode

Bit tables: SlotConfig 15–12 WriteConfig, 11–8 WriteKey, 7 IsSecret, 6 EncryptRead, 5 LimitedUse, 4 NoMac, 3–0 ReadKey
(private slots: bit 0 ExtSign, 1 IntSign, 2 ECDH, 3 ECDH-to-next; bit 13 GenKey, bit 14 PrivWrite). KeyConfig 0
Private, 1 PubInfo, 4–2 KeyType, 5 Lockable, 6 ReqRandom, 7 ReqAuth, 11–8 AuthKey, 12 PersistentDisable, 13 RFU, 15–14
X509id. Positions checked against [CAL] `calib_device.h:170-201, 251-275` (bits 13 / 14 against [F] §2.1 and the TFLX
values, since the library macros for them are wrong as [F] says). Decoded mechanically, then by hand.

| Slot | SlotConfig (bus bytes) | KeyConfig (bus bytes) | Decode | Matches the row's prose |
|---|---|---|---|---|
| 0, 9 | `0x2081` (`81 20`) | `0x03F3` (`F3 03`) | WriteConfig 0010: GenKey = 1, PrivWrite = 0; WriteKey 0 (unused); IsSecret 1; EncryptRead 0; LimitedUse 0; ExtSign 1, IntSign 0, ECDH 0. Private, PubInfo, P-256 (4), Lockable, ReqRandom, ReqAuth, AuthKey 3, X509id 0 | yes |
| 1 | `0x2082` (`82 20`) | `0x03F3` (`F3 03`) | as above with IntSign 1, ExtSign 0, ECDH 0 | yes |
| 2, 4 | `0x2084` (`84 20`) | `0x03F3` (`F3 03`) | as above with ECDH 1, to-next-slot 0, no signing | yes |
| 3, 14 | `0x0F9F` (`9F 0F`) | `0x003C` (`3C 00`) | WriteConfig Always; WriteKey F (unused); IsSecret 1; EncryptRead 0 (never read); NoMac 1; ReadKey F. Not private, KeyType 7, Lockable, ReqRandom 0, ReqAuth 0, AuthKey 0 | yes — but ReqRandom = 0 defeats the purpose in §5.3 (B2) |
| 5 | `0x459F` (`9F 45`) | `0x001C` (`1C 00`) | WriteConfig 0100 Encrypt, bit 13 = 0 (no DeriveKey target); WriteKey 5 (self); IsSecret 1; EncryptRead 0; NoMac 1; ReadKey F. KeyType 7, not Lockable, ReqRandom 0 | yes for §4.2 ("授權金鑰 = 自己"); **no** for §5.2 (B1) |
| 7 | `0x479F` (`9F 47`) | `0x001C` (`1C 00`) | as slot 5 with WriteKey 7 (self) | same as slot 5 |
| 6 | `0x0F8F` (`8F 0F`) | `0x007C` (`7C 00`) | Always; IsSecret 1; EncryptRead 0; NoMac 0; ReadKey F. KeyType 7, Lockable, ReqRandom 1. Equals TFLX slot 6 | yes |
| 8, 10–13 | `0x0F0F` (`0F 0F`) | `0x003C` (`3C 00`) | Always; IsSecret 0; EncryptRead 0 (clear read); NoMac 0; ReadKey F. KeyType 7, Lockable | yes |
| 15 | `0x8F9F` (`9F 8F`) | `0x001C` (`1C 00`) | WriteConfig 1000 Never; IsSecret 1; never read; NoMac 1; ReadKey F. KeyType 7, not Lockable. Equals TFLX slot 7 | yes |

Constraint checks, all slots:

| Constraint ([F] §2, §14) | Result |
|---|---|
| IsSecret = 1 where WriteConfig ≠ Always or EncryptRead = 1 | holds (5, 7, 15; EncryptRead is 0 everywhere) |
| IsSecret = 1 on every private key | holds (0, 1, 2, 4, 9) |
| ReadKey ≠ 0 on every slot, including each CheckMac/Copy target (N+1 for even N, N for odd N) | holds: nibbles are 1, 2, 4, F, 4, F, F, F, F, 1, F, F, F, F, F, F for slots 0–15 |
| AuthKey = 0 where ReqAuth = 0 | holds |
| KeyType 7 on SHA-type secrets and data, 4 on ECC keys | holds |
| ECDH-to-next-slot only on even slots | not used anywhere |
| X509id = 0 on non-public-key slots | holds (0 everywhere) |
| Lockable polarity (1 = lockable) | used correctly; 5, 7, 15 not lockable |
| GenKey = bit 13, PrivWrite = bit 14 | bit 13 set, bit 14 clear on all five key slots |
| LimitedUse, PersistentDisable, RFU | 0 everywhere |
| No slot's ReadKey / WriteKey / AuthKey points at a claim slot other than itself | holds (the F nibbles point at slot 15, never-write, never read) |

Non-slot bytes:

| Item | Design | Check |
|---|---|---|
| Byte order | "low byte first" | correct ([F] §1.2; TFLX `0x0085` example) |
| ChipOptions | `0x6002`, written `02 60` | bit 1 IO-protection enable = 1; bits 15–12 = 6; POST 0; KDF-AES 0; bit 3 = 0; ECDHPROT 0; KDFPROT 0. Matches the prose. Bit 3 is undecided (M3) |
| ChipMode | bit 0 = 0, bit 2 = 0, bits 7–3 = 0, bit 1 blank | consistent with [F] §9; bit 1 needs a value after E1 (m10) |
| SlotLocked | `0xFFFF` | correct polarity (1 = not locked) |
| I2C address | `0xC0` | 7-bit 0x60, bit 0 = 0; blank value inferred, E1 confirms |
| CountMatch, UseLock, VolatileKeyPermission, SecureBoot, KDF bytes, X509format | 0 | equal to the documented "off" values ([F] §9, AN3539 Table 4-1 per [F]) |
| Counters 52–67 | keep blank | correct intent; wording m11 |
| 84 / 85 | 0x00 | cannot be written before lock; wording m11 |

**No hex value is arithmetically wrong.** Values that are wrong for what the design wants from them: the WriteKey
nibbles of slots 5 / 7 against §5.2 (B1); `ReqRandom` in slot 3's KeyConfig against §5.3 (B2); ChipOptions bit 3 not
decided (M3).

## 4. Appendix A, item by item

| Item | Status in the design | Comment |
|---|---|---|
| 1 Slot map, separate attester | made | sound; verifier contract M1 |
| 2 External sign per key | made | slot 0 (and 9) only |
| 3 ECDH policy | made | clear output, slot 2 not regenerable; R66 trade-off unstated (m8) |
| 4 In-chip generation, checkable | made, over-claimed | M6 |
| 5 Claim secret commands / rewrite | made, defective | B1; compare-only part rests on E8, which needs positive controls (M2) |
| 6 Deferred per-slot locks | made | "anyone may lock" is the kill switch of B2 and the non-reservation of m2 |
| 7 Counters | made, over-claimed | M4; behaviour at ceiling stated |
| 8 Trust anchor in chip | decided "no" | reason depends on a platform state that does not exist yet (m8); the reserved slots could not serve it later (m2), so this "no" is final for this hardware — say so |
| 9 Certificate storage, CA model | partly | slot 8 chosen; format, size, intermediates open (m9); no configuration byte depends on it if 10–13 are provisioned at the factory |
| 10 IO protection | deferred | deferral cannot force a config change only if "passive-tap-only" is the accepted ceiling (m3) |
| 11 Address, watchdog, clock, bus sharing | partly | values chosen; bus sharing open and must close before E4 (M2 E0) |
| 12 Key disable features | missing | none configured deliberately; B2 creates one |
| 13 Dev vs production | made | by issuing root; no chip-level marker with force — acceptable; lock-tool gate missing (M5, m10) |
| 14 Batch procedure | partly | M2 |
| 15 Policy for every slot | made | every slot has bits; four classes are liabilities (m1, m2, B2) |
| 16 Second counter unattached | made | Counter 0 unused, no LimitedUse anywhere |
| 17 Host-usable value from the printed secret | missing | m8 |
| 18 Label commits to identity key; certificate location | made | `device_id` = hash of slot-1 public key; slot 8; consequences m4, m5 |
| 19 Chip use tied to a host secret | made as "keep the option" | B2 |

## 5. Facts checked and found wrong, incomplete or over-marked

| # | Where | Statement | What the source says |
|---|---|---|---|
| X1 | [F] §2.3 (GenKey modes) and §3 / U19 | mode 0x10 uses the same digest formula with Param1 / Param2 | [TFLX] §5.2.2.4: OtherData[0], OtherData[1:2] replace them; "the mode and KeyID bytes will be ignored". The inner mode / KeyID bytes are not evidence on that path (M1) |
| X2 | [F] §4, GenDig bullet | a TempKey from GenDig on a NoMac slot "can still serve as … the data-protection key for encrypted Read/Write" | no source given; host model refuses it ([CAL] `atca_host.c:1161-1168`, `:1476`) |
| X3 | [F] §4 "NOT FOUND whether [self-rotation] works when that same slot has NoMac = 1"; [D] §4.2 "文件查不到" | — | evidence exists and points to "no" (same lines as X2) |
| X4 | [D] §5.6 "F§7 ✅" (counter value inside an internal signature) | documented | [F] §7 infers it; [TFLX] §5.3.3.5 sets GenDigData = 0 after GenDig(Counter); whether Sign(internal) accepts that TempKey is unverified (M4) |
| X5 | [F] U15 | whether CheckMac validates OtherData is "not stated" | [TFLX] Table 5-80 note 1 says only "must match the values used in the original MAC command"; still not a statement that the chip checks them. No change, noted for E8 |
| X6 | [D] §2 | "每次登入多一次晶片簽章，上限 115 ms" | omits Nonce / digest load 20 ms and, with ReqAuth, CheckMac 40 ms ([F] §9 table) |
| X7 | [D] §5.3 | binding "更直接地關掉晶片被當成簽章工具" | not with slot 3 as configured (B2-1), and not against clips on a running node (B2-5) |

Confirmed as stated: every bit position in [F] §2.1 / §2.2 / §5 against `calib_device.h`; the TempKeyFlags byte layout
(b7 NoMacFlag, b6 GenKeyData, b5 GenDigData, b4 SourceFlag, b3:0 KeyID) in [TFLX] §5.2.4.1 note 2 and
`atca_host.c:1676-1679`; the 55-byte internal message; the CheckMac hash layout against `proto.go:53-70`; ECDH modes
0x0C / 0x0E / 0x08 and the ECDHPROT note; the `GEN_KEY_SHIFT (8)` / `PRIV_WRITE_SHIFT (9)` macro discrepancy
(`calib_device.h:198-201`). Useful for the experiments and not in [F]: Info mode 0x02 returns the TempKey flags and an
AuthComplete valid bit and KeyID ([TFLX] Table 5-11), so authorisation and TempKey state can be observed directly.

## 6. Verdict

**REJECT.** Two BLOCKERs and six MAJORs are open; under `REVIEW.md` the design is revised and the whole document
reviewed again.

What stands: the three-key split, the lock order in §5.1, `device_id` from the endorsement key, no fall-back software
identity, and every hex value as arithmetic.

The shortest route to an approvable v2 is subtraction: no `ReqAuth` and no slot-3 / slot-14 secrets (B2); a fixed
claim secret unless a variant chip proves a rotation flow (B1); no spare key slots, no open "reserved" slots, no
half-enabled IO protection (m1–m3); the verifier contract written as "rebuild 55 bytes from constants" (M1); a variant
chip before the candidate chip, with positive controls (M2). That leaves a configuration in which nothing is writable,
lockable or regenerable after the factory except the counter.
