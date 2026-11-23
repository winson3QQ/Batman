# Review of `255-608b-config.md` v3 (bench-only 608B configuration)

Reviewer: independent, round 3. I had not seen this design before. I read `REVIEW.md`, the target, the fact base
(`608b-facts.md`, "F§n"), `255-key-authority.md` v3.1 (K13–K16, K20, K21), `255-threat-model.md` v2.1 §5.1 and
Appendix A, and the interoperating source. Only after forming my own view did I read the four earlier reviews and the
two change maps (§4 below).

Primary sources I read myself (downloads under the session scratchpad `rv3/dl/`):
- **[CAL-H]** cryptoauthlib `lib/host/atca_host.c` and `atca_host.h` (main, fetched 2026-11-23 with `gh api`), the
  vendor's host-side model of TempKey and of the internal-sign message.
- **[CAL-C]** cryptoauthlib `lib/calib/calib_command.h` (same fetch): all command mode bits.
- **[TFLX]** ATECC608B-TFLXTLS complete data sheet DS40002249A (ww1.microchip.com), text extracted with pypdf:
  §3 SRAM, §5.1.2 Info(State) Tables 5-9…5-11 (p.34), §5.1.4 Nonce (pp.36–37), §5.2.2 GenKey (pp.47–48),
  §5.2.4 Sign (pp.51–52).
- Source: `feed/batman-prov/src/keystore/keystore.go`, `proto/proto.go`, `node/node.go:380-430`,
  `cmd/batman-provhelper/{main.go,stable.go,trial.go}`, `boot/boot.go:75-110`,
  `feed/batman-provision/files/usr/bin/batman-autocommit:495-515`, `provstore/provstore.go:344`.

No device was contacted, nothing was built, nothing else in the repo was changed.

---

## 1. Summary

The configuration bytes are still correct: I decoded every value in §4 and §8.1 independently (§3) and none of them
needs to change on current evidence. What is not ready is everything the bytes are supposed to *prove*:

- The K16 assumption written into §2 is not the one the security actually rests on, and the only public model of the
  chip's TempKey flags (the vendor's host code) contradicts it. The stated purpose of ReqRandom is false according to
  the TFLXTLS data sheet. The verifier's constant list leaves out the one flag bit that carries the weight (M2).
- E7 is still not complete, and its "positive control on slot 4" does not control anything (M3).
- The fallback "E7 fails → no endorsements" leaves slots 0 and 2 bound to nothing. Read the other way, the bench
  does not need chip endorsements at all: the development root already signs after a trusted read-back (M4).
- The variant image locked at E4 cannot provide several positive controls that §8.2 says it provides. Once E4 runs,
  they can no longer be added (M1).
- §9-5's automatic fall back to a file identity reintroduces the K20 breach that round 2 asked to remove (M5).
- Ownership, contracts and lifecycle are still partial (M6), and the claim-secret handling makes automated
  validation impossible (M7).

**Counts: 0 BLOCKER, 7 MAJOR, 16 MINOR.**

**Verdict, E4 on the first sacrificial (variant) chip: APPROVE-WITH-CHANGES.** E4 may proceed once M1 (the variant's
control slots and the per-test control table) and m1 (ChipMode bit 1) are fixed in §8.1/§8.2. No other finding changes
a byte that chip 1 locks. That makes this a focused re-check rather than another full round. I say this explicitly
because `REVIEW.md` would otherwise require a full round.

**Verdict, locking the final bench image: REJECT (not yet).** M2–M7 are open. The final lock also depends on the E-series
results anyway. The §4 bytes themselves do not need to change.

---

## 2. Findings

### MAJOR

**M1. The variant image, which E4 freezes, cannot supply several of the positive controls §8.2 claims, and one E13 item
cannot run on chip 1 at all.**

(a) Scenarios.
1. E8 says "對照：同樣的指令在槽 3 上成功" for the whole list. Slot 3 = `0x0F8F / 0x003C` (my decode, §3) is a valid
   control only for MAC, Nonce+GenDig+MAC, SHA-HMAC and, perhaps, KDF from a slot. On slot 3 the following are refused
   for the same documented reasons as on slot 5:
   - **AES**: KeyType = 7, and AES needs KeyType 6 and AES_Enable (F§2.2, F§12);
   - **Read**: IsSecret = 1 with EncryptRead = 0 means "reads are never permitted" (F§2.1);
   - **DeriveKey target**: WriteConfig bit 13 = 0 (F§2.1);
   - **CheckMac copy**: ReadKey = F, and copy needs ReadKey = 0 (F§4).

   For these four, "fails on 5 and fails on 3" cannot tell "blocked by policy" from "the harness sent a malformed
   command". That is the vacuous pass C8 forbids.
2. E9's control ("指向槽 6 時成功") is a prediction with no evidence. Which target-slot bits the 608 requires for ECDH
   `0x04/0x05` or KDF target = slot is NOT FOUND (F§2.4, F§16 U4/U5). If the 608 applies the DeriveKey-target rule,
   slot 6 (`0x0F0F`, bit 13 = 0) refuses as well, and E9 proves nothing. E9 matters: ECDH with an ephemeral TempKey key
   and output to slot 5 would write a value the attacker can compute (they hold the peer private key and receive the
   ephemeral public key from GenKey `0x04/0xFFFF`, TFLX §5.2.2.2). That replaces the claim secret (T-SE4).
3. E13 "產生金鑰前先鎖一個金鑰槽" needs an empty, lockable key slot. On the variant the only key slots are 0–2 (E7 needs
   them) and 4 (E7's control needs it). Round-2 A-M2 named exactly this, and it is still open.
4. E6 "私鑰槽的明文與加密寫入要失敗" has no control. No variant slot has PrivWrite enabled (bit 14 = 1 with a WriteKey). A
   control is also possible without a config change: PrivWrite in clear to slot 4 in the config-locked, data-unlocked
   window (F§3, "without regards to the SlotConfig value"). It is not listed.

After E4 none of this can be added to chip 1. The only remedy is another chip.

(b) Evidence: §3 decode; F§2.1, F§4, F§12, F§16; TFLX §5.2.2.2; design §8.1, §8.2 E6/E8/E9/E13; round-2 A-M2 and A-M3.

(c) Fix, before E4:
- Write a per-test control table. For every "must fail" row, name the control (a slot, or a sibling command that differs
  only in the field under test) and both expected status codes.
- Where no variant slot can succeed, either add a control slot in a variant-unused slot (7, 9–15; they are unused in
  the final image too), or mark the row "relies on documentation [508A …]" and drop the C8 claim for it. Suggested
  controls: a DeriveKey/ECDH-target candidate with bit 13 = 1; an odd slot with ReadKey = 0 for copy; an empty lockable
  `0x2083`-style key slot for E13.
- Hard rule for every added slot: no WriteKey, ReadKey or AuthKey nibble may name slot 5, and slot 5's own neighbour
  (it is odd, so the copy target is itself) must be unchanged. That keeps E8's verdict on slot 5 transferable to the
  final image.
- Order rule: run E6 and E9 before E13 locks slot 6.

---

**M2. The K16 assumption in §2 is not the one the security rests on. The vendor's own model contradicts it, ReqRandom's
stated purpose is false, and the verifier constants omit SourceFlag.**

(a) Scenario and facts.
1. §2 states: "任何會覆寫暫存區的指令都會改掉這些旗標". The only public model of the flags is cryptoauthlib's host code.
   It sets `gen_key_data = 1` in `atcah_gen_key_msg` ([CAL-H] `atca_host.c:1571-1572`) and **never clears it anywhere**.
   Nonce random (`:153-161`), Nonce fixed (`:188-196`, `:203-207`), GenDig (`:998-1007`, `:1128-1133`) and CheckMac
   copy (`:661-663`) reset `key_id`, `gen_dig_data`, `no_mac_flag` or `source_flag`, but not `gen_key_data`. This is a
   host model, not the silicon, but it is the vendor's best public statement. It raises the prior that E7 (a)/(d)
   "fails" in the dangerous direction.
2. If GenKeyData does stick, what separates a genuine endorsement from a forged one is the rest of the flags byte:
   KeyID nibble, GenDigData and **SourceFlag** (TFLX Table 5-11, p.34; message byte 40, [CAL-H] `:1674-1678` (SourceFlag at `:1676`)).
   - After `GenKey(0x08, slot 0)` then `Nonce(pass-through, X)`, the model gives flags = KeyID 0, Source = fixed,
     GenKey = 1. The 55-byte message then differs from a genuine slot-0 endorsement **only in SourceFlag**. The
     32-byte field is X, which the attacker chose as the GenKey-format digest of their own key Q′ (round-2 A-B1 step 2).
   - §2's constant list ("由 GenKey 產生、非 GenDig、無 NoMac、槽號") does not name SourceFlag. An implementer who
     builds the flags byte from the four named fields, or who accepts either Source value "because ReqRandom forces
     random anyway", accepts the forgery. The result is T-SE1 (a software key accepted as the node's connection key
     forever).
3. ReqRandom's stated purpose ("讓背書訊息一定含有晶片產生的亂數，攻擊者無法用直通的 nonce 完整決定暫存區內容") is
   contradicted by TFLX §5.1.4.1, p.36: with Param2 = `0x8000`, "a value stored in TempKey is used to generate a new
   nonce instead and the random number generator is not run … Upon completion, the TempKey.SourceFlag is set to Rand".
   Pass-through X followed by `Nonce(0x00, Param2 0x8000)` therefore gives a TempKey the host fully knows, with
   Source = random and without any chip randomness. The "RandOut" attached to an endorsement is not evidence of chip
   randomness. This is harmless only because endorsements are static.
4. The data sheet contradicts itself on SourceFlag polarity. Table 5-11 (p.34) says "0: TempKey is fixed source,
   1: … random"; the Nonce notes (pp.36–37) and [CAL-H] `:153`, `:188` say 0 = random, 1 = fixed. A verifier constant
   taken from the document can be wrong.
5. The real argument K16 rests on, which §2 should state:
   - (i) the verifier pins the **whole** flags byte, plus mode, KeyID, SlotConfig, KeyConfig and SlotLocked of the
     endorsed slot, and bytes 41–42, 53 and 54, at the values measured from a genuine endorsement;
   - (ii) no command can leave a TempKey whose value the host chose as a SHA-256 of a 128-byte GenKey-format preimage
     **and** whose flags byte equals that pinned value.

   The writers that can place a host-chosen value or digest in TempKey are Nonce pass-through (32 and 64 bytes) and SHA
   with target TempKey (any preimage, so exactly the GenKey format). Everything else (KDF-HKDF/PRF, SHA-HMAC, ECDH,
   Nonce random, Nonce `0x8000`) outputs a hash of a different format, or a value the host cannot choose. KDF-AES would
   be a third, attacker-choosable writer; it is off only because ChipOptions bit 2 = 0. Say so, because that bit is now
   load-bearing.

(b) Evidence: [CAL-H] lines above; TFLX pp.34, 36–37, 51; design §2; round-2 A-B1 (whose fix asked for "flags byte
differs from the endorsement constant"; v3 dropped that clause, see M3).

(c) Fix.
- Replace the §2 assumption with (i)+(ii) above.
- Add SourceFlag, and the measured polarity, to the constant list. Define the verifier as "pin every byte of the 55
  except TempKey(32); the TempKey field is recomputed".
- Delete the ReqRandom rationale (keep the byte, which is harmless) or restate it truthfully.
- State that ChipOptions bit 2 (KDF-AES) = 0 is load-bearing for K16.
- Use **Info(State)** (opcode `0x30`, mode `0x02`, TFLX Tables 5-9…5-11; `INFO_MODE_STATE` [CAL-C] `:517`) in E7 to
  read the flags after every step. That turns E7 from a black-box guess into a direct measurement of the assumption.
  It also settles the polarity.

---

**M3. E7 is still incomplete, and its controls do not discriminate.**

(a)
1. **Missing TempKey writers and Sign modes** ([CAL-C] lines; TFLX pages):
   - GenKey `0x04` with KeyID `0xFFFF` (ephemeral private key into TempKey, TFLX §5.2.2.2) followed by Sign(internal);
   - Nonce random with Param2 `0x8000` (M2-3);
   - Nonce pass-through with target Message Digest Buffer / Alternate Key Buffer (`0x43/0x83/0x63`). The host model sets
     `TempKey.valid = 0` ([CAL-H] `:203-207`), so the remaining flags have to be observed;
   - SHA mode `0x03` (public key of a slot into the context) and `0x07` (write context), and SHA end with target
     Message Digest Buffer followed by Sign `0x20`/`0x60` ([CAL-C] `:750`, `:758-759`);
   - KDF with **AES** algorithm into TempKey (must be refused with ChipOptions bit 2 = 0; M2-5);
   - ECDH `0x09` (ephemeral TempKey key, output TempKey);
   - Sign `0x01`/`0x41` (internal, "for Verify(Invalidate)", [CAL-C] `:773`; message byte 53 = `0x01`, [CAL-H]
     `:1707`);
   - TempKey and flag retention across **idle**: cryptoauthlib idles after every command (F§15), so any interleaving
     can span idles;
   - an explicit statement that CheckMac copy and SecureBoot are N/A, and why: no ReadKey = 0 slot; SecureBoot `0000`.
2. **"Control on slot 4" is not a positive control.** Whether an overwrite clears the flags is a chip-global behaviour,
   not a per-slot one. Slot 4 differs from slot 1 only by adding ExtSign. If the chip behaves correctly, Sign(internal)
   on slot 4 after (a)–(f) is refused exactly as on slot 1 ("TempKey must be generated using either the GenDig or the
   GenKey command", TFLX §5.2.4.1). The "control" fails, and nothing distinguishes that from a broken harness. The
   dangerous false pass is "Sign command malformed → error → counted as 'failed as expected'". What controls a row:
   - **baseline**: the identical byte sequence minus the attack step succeeds, and the shipped verifier accepts it;
   - **step proof**: the attack step returned `0x00`, Info(State) shows the new flags, and for SHA/pass-through,
     Sign(external, slot 4, source TempKey) over the expected value verifies. That proves TempKey really holds the
     attacker's D′.
3. **Pass criterion is weaker than the round-2 fix.** Round-2 A-B1 asked for each negative to be *aimed at the
   endorsement preimage of a host key Q′*, with pass = refusal, or verifier rejection **and** a flags byte that differs
   from the constant. v3 says "失敗或產生參考程式拒絕的訊息". A rejection caused by a wrong D′ (host-side bug) passes.
   That is reworded, not closed.
4. The reference verifier must be the shipped `batman-proto` code (round-2 A-M3 last bullet, still open), not a
   second program.

(b) Evidence: [CAL-C] `:485-489`, `:632-646`, `:746-778`; [CAL-H] `:188-207`, `:1653-1712`; TFLX pp.36–37, 47, 51;
design §8.2 E7.

(c) Fix: add the rows in (1). For each row, specify the baseline, the step proof (Info(State) and, where relevant, the
slot-4 external sign over the expected TempKey), the forged target Q′ and the pass rule "refused, or flags byte ≠
pinned value". Run it for k = 0 and 2 and Sign modes `0x00/0x40/0x20/0x60/0x01/0x41`. Verifier = `batman-proto`.

---

**M4. "E7 fails → phase 1 drops endorsements" leaves C2/C3 with nothing to stand on. Turned around, the endorsement
mechanism has no present use on the bench.**

(a) Scenario. If endorsements are dropped, the app receives slot-0 and slot-2 public keys in `node_cert` with nothing
binding them to the chip. §5 step 6 has the dev root sign "憑證" but never says what is in it (slot 1 only, by
implication of §2). Then:
- anyone with the PSK presents their own "slot-0" key and signs the login proof (C3 lost, T-SE1);
- `net_secrets` are encrypted to an unbound "slot-2" key (C2 lost, T-SE2).

The fallback in §2 and E7 does not say what protects C2.

The fix is already in the flow. §5 step 6 reads back the configuration and lock state **on the bench, by trusted
tooling, before the dev root signs**. If the dev-root certificate binds `{chip serial, slot-1 pub, slot-0 pub,
slot-2 pub}`, C2 and C3 hold without any chip endorsement, and K16 holds by construction, because no verifier accepts
any chip-made signature as a key binding. On the bench, the endorsement then adds no protection. What it does add:
- boot-time chip work (2 × Nonce + GenKey-digest + Sign);
- `node_cert` fields (RandOut, NumIn, two signatures);
- the M2 verifier subtleties;
- the E7 gate on every phase-1 item.

Production uses a different part (§10; the 608C TrustFLEX slot map is Microchip's), so what the bench learns about
608B endorsements may not transfer. This is the project lesson: the mechanism exists for a later product, not for a
present use. Its cost: every risk in M2/M3 sits on the critical path of phase 1.

(b) Evidence: design §2 (fallback), §5 step 6, §9-1, §10; threat model T-SE1/T-SE2 and R3 (a chip-internal attestation
path is the production requirement where the binder is not trusted; on the bench the binder is the developer).

(c) Fix. The dev-root certificate binds all three public keys and the serial. Phase-1 `node_cert` carries no
endorsements. Run E7 as a non-gating information experiment for the production-part decision (§10); its failure no
longer stops phase 1. Keep the §4 bytes as they are. If the author keeps endorsements, at minimum the fallback must
say "dev-root cert binds slots 0 and 2", which makes the endorsement redundant anyway.

---

**M5. §9-5 automatically falls back to a file identity when no marker and "no chip" are seen. That is the K20 breach
round 2 asked to remove, and it is reachable in normal bench use.**

(a) Scenarios.
1. A bench node with a burned chip is reflashed (the C6 row). The data-partition marker is gone, or is on a partition
   the reflash recreates. At the first boot the chip does not answer once: a T-SE14 transient, a slow wake, or a bus
   held by `batpower`. Rule "沒有標記也沒有晶片 → 檔案後端" applies, and the node generates a software identity
   (`boot.go` generates on rc 7/9, round-2 B-M7.3). K20 says "任何情況下都不產生或退回軟體身分".
2. "偵測到已燒錄的晶片" is undefined. The variant chip (chip 1, config ≠ image), a partially burned chip, a blank chip,
   a 608C/TNG at another address, and a chip whose read-back fails CRC are each "a chip" or "no chip" depending on an
   unstated test. Each one that is classed "no chip" falls through to a file identity.
3. Round-2 B-M8 recommended the removal: no flashable image has a file backend; a HAT-less node is
   "identity unavailable"; the software fake exists only in host tests. v3 does the opposite and gives no reason.

(b) Evidence: design §9-5, §7 (reflash row); `boot/boot.go:75-110`; K20 (`255-key-authority.md:88`); threat model
T-SE14 ("the node quietly makes itself a software identity" is listed as a dangerous outcome).

(c) Fix: no automatic fallback. The file backend only by an explicit build or configuration flag that the
chip-capable bench image does not carry, or by an explicit console command on a HAT-less development machine. With no
marker and no chip, the result is "identity unavailable". Define the chip-state classifier (blank / variant /
partial / foreign / burned / no answer after N retries) and the behaviour for each. Name the partition that holds the
marker and say whether a reflash erases it.

---

**M6. Ownership, contracts and lifecycle are still partial (round-2 A-m9, B-M7.4, B-m10 not closed), and one
ownership statement is wrong.**

(a)
1. **Missing resources** (`REVIEW.md` item 1):
   - the I2C bus, and the chip's volatile state: TempKey, Message Digest Buffer, Alternate Key Buffer, SHA context,
     AuthValid;
   - the development-root key;
   - the image file and its hash;
   - the per-chip burn record (which holds the claim secret);
   - the label;
   - the experiment tool;
   - slot 8's certificate;
   - bytes 84/85 (any bus master can UpdateExtra them once, F§9).

   Two writers on the chip's volatile state are possible today: the helper daemon and the helper burn mode, which is
   the same binary run as a second process. Concurrent daemon requests (login proof, `peers/challenge`, boot
   endorsement, counter proof) are a third case. Interleaved Nonce/GenKey/Sign sequences corrupt each other, and with
   sticky flags (M2) can produce signatures over the wrong TempKey. Nothing says that a single in-process sequencer
   serialises chip sequences and that burn mode refuses while the daemon holds the bus (for example `flock` plus
   "daemon stopped"). Project memory already records the bare-daemon trap.
2. **Contracts missing:**
   - the marker: location, format, writer, what happens when malformed, and who can write it;
   - `node_cert` and the dev-root certificate contents;
   - the read-back channel from the bench node to the dev-root holder (the dev root trusts the node's report).
3. **Lifecycle rows missing** (`REVIEW.md` item 3):
   - clean shutdown or reboot in the middle of a chip sequence;
   - helper restart, provd restart, and crash loop (each start wakes the chip; boot endorsements use Nonce random,
     whose mode `0x00` may update the EEPROM seed — F§9, endurance 400k per byte, F§14.14 — so a procd respawn loop
     is an EEPROM-wear question; use mode `0x01` or measure it);
   - restart of the I2C driver;
   - both boards (are 02/04 bcm2711 or bcm2710? round-2 B-m11);
   - the burn-mode-during-trial path: burn mode must be manual-only and refused while `batman-slot is-trial`, because
     chip operations are irreversible and A/B cannot revert them.
4. **Wrong owner**: §7 says "provd 不寫入穩定標記". The helper writes `$RUNDIR/provd-stable` when provd's connection has
   been open 60 s (`stable.go:3-5`, `main.go:705-707`), and autocommit reads it (`batman-autocommit:508-512`). The
   mechanism v3 needs, "helper does not listen while the chip fails in a trial", does keep provd from connecting
   (today `main.go:633-636` serves nothing). The rule must be stated against the real owner.

(b) Evidence as cited.

(c) Fix: add the resources with single owners, the sequencer and exclusion rule, the three contracts, the missing
rows with tests, and correct the trial row's owner.

---

**M7. The claim-secret handling makes automated bench validation impossible.**

(a) Scenario. §5 step 8: the claim secret is printed on the QR and then deleted from the burn record. §9-10: the ~33
harness files that read `claim.secret` or call `provhelper qr` "要改成透過 helper 取得". The helper cannot obtain it:
slot 5 is never readable (C4, the whole point of E8), and `provhelper qr` today reads the file (`main.go:615-622`). So
after conversion no automated claim test can run on a chip node. `daily-validation` and the "one validation set" rule
then cannot cover the phase-1 product. Round-2 B-M8 noted "every automated claim needs the secret from a host-side
record".

(b) Evidence: design §5-8, §9-10, C4; `cmd/batman-provhelper/main.go:615-622`.

(c) Fix: for bench chips, keep the claim secret in the private host-side test-credential store (Batman-P, never the
public repo), where the harness reads it. State that this is a bench-only exception to "delete after printing", and say
why it is acceptable (development units, dev root only trusted by development apps).

### MINOR

- **m1. ChipMode bit 1 has no decision rule** (round-2 A-m13, open). "依 E1 決定" cannot work: E1 reports only the blank
  value. The variant shares the final non-slot bytes, so this must be fixed **before E4**. At 3.3 V either value meets
  VIH. Pick 0 (fixed levels, F§9) unless the HAT's 608 VCC is not 3.3 V.
- **m2. Half-finished chips.** "金鑰已產生但未全鎖 → 只能報廢" is unnecessary: SlotConfig bit 13 = 1 allows GenKey to
  regenerate an unlocked key slot, so step 5 is resumable. The states "slot 8 written but not locked" and "cert signed,
  slot 8 not locked" are missing. The helper's partial-state rule should include "slot 8 not locked" (round-2 A-m8 /
  B-m6, partly open).
- **m3. The downgrade row's mechanism.** `keystore.go:266-267` refuses only when `identity/backend` exists and is not
  `file` (`provstore.go:344` puts `identity/` on the overlay, persisted to p5). v3's marker is on "資料分割區", and v3
  never creates a chip identity directory, so the old helper does not see "晶片身分目錄". Either write
  `identity/backend=se` (overlay + p5) from the chip image, or say plainly that a downgrade generates a software
  identity (round-2 A-M1.6 / B-M7.3, reworded, not closed).
- **m4. The trial rule needs a retry count and a definition.** One transient chip failure in a trial reverts a good OTA.
  Retry N times with backoff before declaring trial failure. Define "驗證失敗" (which check, against which constant).
- **m5. E12 pass criterion.** UpdateExtra has no authorisation (F§9), so writing byte 84/85 once is expected to
  **succeed**. Pass = the address is still 0x60 after a power cycle, with ChipMode bit 0 = 0. The control
  "讀回 84/85 為原值" contradicts that. Round-2 A-M3 asked for "UpdateExtra on byte 84 succeeds once".
- **m6. E10.** ChipOptions bits 15–12 = 0 name slot 0, a private key, as the IO key (my decode, §3). E10 must also cover
  KDF encrypted output (`0x14`), and must say: if encrypted output is not refused, change the IO-key nibble to a
  never-write unused slot on chip 3 before the final lock.
- **m7. Certificate size can be computed offline today.** Slots 9–15 become never-write in the final image, so if the
  dev-root DER exceeds 416 bytes there is no on-chip fallback. Build the certificate on the host and measure it before
  E4. Also state "slot 8 holds the complete DER" and its validity (round-2 A-m14, open). With M4, the certificate
  carries three keys.
- **m8. §6 counter has no bench use.** It adds a second message type signed by slot 1 (GenDig-flagged) that every
  endorsement verifier must keep apart, and an E11 gate. Round-2 B-m4 (increment only after the claim proof verifies)
  is still open. Leave the counter untouched in phase 1 and move §6 to §10.
- **m9. The experiment tool contradicts C9.** E7–E12 need commands the product helper must never contain (UpdateExtra,
  KDF/SHA attacks, Lock of key slots before keygen). State: experiment tool = a separate build, run only on the
  experiment node, never in any image, with the helper daemon stopped.
- **m10. Chip 2's fate.** F1 runs "E6–E15 適用的項目" on chip 2. E13 "lock a key slot before keygen" destroys it as an
  identity. Say whether chip 2 becomes a bench chip, and list exactly which items F1 runs.
- **m11. The budget pressure is self-imposed.** The production part is not the 608B (§10), so all 10 chips are
  bench-only. Allowing a second variant chip, if M1's controls need it, costs a ~$1 part and a rework. Also state how
  many WM1302 HATs are available and whether SOIC rework or a socket is planned.
- **m12. A compromised provd is a slot-0 signing oracle.** provd supplies the handshake hash `h` (today `sign.static`
  takes `sp` from provd, `node.go:390-402`). A compromised provd can therefore have slot 0 sign "label ‖ any h" at 2/s.
  This is equivalent to provd compromise, since provd holds the session keys, so no new hole opens. State the trust
  assumption. Note also that the global 2/s signing limit (`node.go:384-386`) is shared with stranger-initiated claim
  proofs.
- **m13. `ClientChal` binds `SHA-256(DAC DER)`** (`proto.go:48-52`). §9-4 changes only `sn`. Say what "DAC DER" becomes
  (the dev-root certificate) so that the claim proof keeps committing to the identity key (T-SE13).
- **m14. Message-layout facts the verifier needs, which §2 should state:**
  - KeyID at bytes 34–35 is the **signing** slot (1), not the TempKey slot ([CAL-H] `:1667-1668`); the TempKey slot is
    only the low nibble of byte 40;
  - SlotLocked byte 52 is `0x00` when locked ([CAL-H] `:1702`);
  - byte 53 depends on invalidate mode and public-key validity ([CAL-H] `:1707`).
- **m15. The unused slots hold known zeros** (round-2 A-m5, not mentioned in v3). They act as known NoMac keys for
  GenDig/CheckMac. This is inert only because no WriteKey/ReadKey/AuthKey selects them and verifiers pin KeyID. State it.
- **m16. Earlier MINORs not addressed and not mentioned in the change map:**
  - B-m7: how a user learns the chip is dead;
  - B-m9: a proof-type field in `node_cert`;
  - B-m14: `node_cert` is sent to unauthenticated peers (a phase-2 condition);
  - A-m15 / B-C-m7: `batpower` should refuse 0x60 in code, not only by today's uci value.

---

## 3. My decode of §4 and §8.1

Bit fields from F§2.1/§2.2 (508A tables, consistent with the 608 field positions in CAL `calib_device.h`). Script:
`rv3/scripts/decode.py`. Bytes on the bus are little-endian.

| Slot | SlotConfig (bus) | Decode | KeyConfig (bus) | Decode | Matches stated purpose |
|---|---|---|---|---|---|
| 0 | `0x2081` (`81 20`) | GenKey 1, PrivWrite 0, IsSecret 1, NoMac 0, ExtSign 1, IntSign 0, ECDH 0 | `0x0073` (`73 00`) | Private, PubInfo, P-256, Lockable, ReqRandom, no ReqAuth | yes |
| 1 | `0x2082` (`82 20`) | as 0, IntSign only | `0x0073` | as 0 | yes |
| 2 | `0x2084` (`84 20`) | as 0, ECDH only, ECDH→next 0 (clear output) | `0x0073` | as 0 | yes |
| 5 | `0x8F9F` (`9F 8F`) | WriteConfig 1000 Never, DeriveTarget 0, WriteKey F, IsSecret 1, EncRead 0, NoMac 1, ReadKey F | `0x001C` (`1C 00`) | KeyType 7, not lockable, ReqRandom 0 | yes (odd slot, copy target = itself, ReadKey ≠ 0) |
| 8 | `0x0F0F` (`0F 0F`) | Always write, IsSecret 0 (clear read), NoMac 0, ReadKey F | `0x003C` (`3C 00`) | KeyType 7, Lockable | yes |
| 3,4,6,7,9–15 | `0x8F9F` | as 5 | `0x001C` | as 5 | yes |
| ChipOptions | `0x0008` (`08 00`) | POST 0, IOProt 0, KDF-AES 0, HTF auto-clear 1, ECDHPROT 0, KDFPROT 0, **IO-key slot 0** | | | yes; IO-key nibble → m6 |

Variant (§8.1):

| Slot | Value | Decode | As a positive control |
|---|---|---|---|
| 3 | `0x0F8F / 0x003C` | Always write, IsSecret 1, EncRead 0, **NoMac 0**, ReadKey F, DeriveTarget 0; KeyType 7, Lockable, ReqRandom 0 | valid for MAC, GenDig+MAC, SHA-HMAC, (KDF from a slot ⚠️); **not** for AES, Read, DeriveKey target or copy (M1) |
| 4 | `0x2083 / 0x0073` | key slot, ExtSign + IntSign, GenKey, no PrivWrite; Private P-256, Lockable, ReqRandom | valid for "slot 1 ext-sign refused", "slot 0 int-sign refused" and "slot 2 any sign refused"; **not** for E7 (a)–(g) (M3-2); occupied, so E13's empty-key-slot lock cannot run (M1-3) |
| 6 | `0x0F0F / 0x003C` | identical to final slot 8 | valid for E6 plain write and E13 lock/no-write-after-lock; E9 control unproven (M1-2) |

None of the three variant slots has a WriteKey, ReadKey or AuthKey nibble naming slot 5 (all F or 0, with no
encrypt or derive use). The variant therefore does not change slot 5's effective policy, so E8's verdict on slot 5
transfers to the final image. The variant also does not make a final-image claim untestable: the 36-byte
unused-slot behaviour is still tested on slot 7, the 72-byte behaviour on slots 9–15, and F1 re-tests on chip 2.
One caveat: on the variant, slot 2's N+1 (slot 3) is writable, so any ECDH output-to-next-slot result on chip 1 does
not transfer. That is harmless, because in the final image slot 3 is unused.

---

## 4. Earlier findings: closed or not

| Finding | State in v3 |
|---|---|
| v2-A B1 (TempKey writers; assumption) | **Partly.** Assumption written, but not the operative one (M2). Several writers and Sign modes missing (M3-1). Pass rule weaker than the requested fix (M3-3) |
| v2-A M1 (phase-1 items) | Closed in substance (§9 1–13). Item 6 (downgrade marker) reworded, not closed (m3) |
| v2-A M2 (variant image, chips) | **Partly.** Image written and chip count confirmed. E13's empty key slot still impossible. Controls not reviewed per test (M1) |
| v2-A M3 (missing controls) | **Partly.** E6 and E14 closed. E9 control unproven, E12 control reworded (m5), E10 covers ECDH only (m6), verifier ≠ shipped code (M3-4) |
| v2-A m5 (known-zero slots) | Open (m15) |
| v2-A m6 (ReqRandom purpose) | Purpose stated, but false (M2-3) |
| v2-A m8 (partial states, scrap not needed) | Partly open (m2) |
| v2-A m9 (missing resources) | Open (M6) |
| v2-A m13 (ChipMode bit 1) | Open (m1) |
| v2-A m14 (DER in slot 8, validity) | Open (m7) |
| v2-A m15 | Open (m16) |
| v2-B M1, M2, M3 | Closed by the scope change (§10) |
| v2-B M4 (factory / second program) | Closed for burning (helper mode). The experiment tool is the same issue again (m9) |
| v2-B M5 (endorsement origin) | Closed (boot, in memory). M4 questions whether it is needed at all |
| v2-B M6 (per-login cost) | Closed (135 ms, #329 baseline) |
| v2-B M7 (trial commit; test column; rows) | **Partly.** Trial rule and test column added. Owner misattributed. Rows still missing (M6). Downgrade mechanism (m3) |
| v2-B M8 (K20 vs file backend; scope) | **Not closed.** The recommended removal was reversed into an automatic fallback (M5). Harness item conflicts with the deletion of the secret (M7) |
| v2-B m4, m7, m9, m14 | Open (m8, m16) |
| v2-B m10 (verifier two programs; domain separation) | Open (M3-4, m8) |
| v2-B m11 (boards) | Open (M6-3) |

v3 opened these new problems:
- the automatic file fallback (M5);
- the harness "via helper" item (M7);
- the slot-4 "control" (M3-2);
- the false ReqRandom rationale (M2-3).

---

## 5. Wrong or unsupported facts in v3

1. §2: ReqRandom "讓背書訊息一定含有晶片產生的亂數". False. Nonce with Param2 `0x8000` sets SourceFlag = Rand without
   running the RNG (TFLX §5.1.4.1, p.36).
2. §2: "任何會覆寫暫存區的指令都會改掉這些旗標" is presented as the assumption to test. The vendor host model never
   clears GenKeyData ([CAL-H] `atca_host.c`). It is plausible that it is false, and the security argument should not
   depend on it (M2-5).
3. §8.2 E8: "同樣的指令在槽 3 上成功" is false for AES, Read, DeriveKey target and copy (M1-1).
4. §8.2 E7: "(a)–(g) 在槽 4 上照做 … 證明測試程式能產生成功的內部簽章". On a correct chip these are refused on slot 4 too
   (M3-2).
5. §7 trial row: "provd 不寫入穩定標記". The helper writes `provd-stable` (`stable.go:3-5`).
6. §7 downgrade row: relies on a chip identity directory that v3 never creates (m3).
7. §9-10: claim secret "透過 helper 取得". Impossible by C4 (M7).
8. TFLX Table 5-11 and its own Nonce notes disagree on SourceFlag polarity. Any constant must be measured (M2-4).

---

## 6. Options without a present use (the standing lesson)

- Chip endorsements on the bench (M4). The dev-root certificate after the trusted read-back already gives the binding.
  Removing them takes E7 off phase 1's critical path and deletes the node_cert nonce fields, the boot-time chip work
  and the M2 verifier subtleties.
- The §6 counter proof (m8).
- The automatic file-identity fallback (M5): remove it, do not refine it.
- ReqRandom's rationale (M2-3): keep the byte, delete the claim.

None of these removals changes a configuration byte.

---

## 7. Verdict

- **E4 on chip 1 (variant): APPROVE-WITH-CHANGES.** Preconditions:
  - M1: a per-test control table, plus any added control slots in variant-unused slots 7 and 9–15 that never reference
    slot 5, or rows downgraded to "documentation only";
  - m1: ChipMode bit 1 decided;
  - recommended, at no cost: m7 (certificate size measured offline).

  No other finding changes chip 1's locked bytes. A focused check of the revised §8.1/§8.2 is enough for E4.
- **Final bench image lock: REJECT (not yet).** M2–M7 must be resolved and the document reviewed again as a whole. The
  E-series results (E5, E7 as information, E8, E9, E10 including m6, E12, E13) must be in hand first. On current
  evidence, no byte of §4 needs to change.
