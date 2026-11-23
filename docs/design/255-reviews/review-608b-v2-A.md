# Review A, round 2: `255-608b-config.md` v2 (ATECC608B configuration and slots)

Reviewer A (independent; v1 not seen before this round). Read: the v2 design in full; `608b-facts.md` in full;
`255-key-authority.md` K16 / K20 / K21; `255-threat-model.md` T-SE1…T-SE16 headings and §5.1 rows;
`REVIEW.md`; `proto/proto.go:1-120`; `provd/server.go:320-370, 730-790`; `keystore/keystore.go:60-125, 236-275`;
`nodecert.rs:130-200`; `219-protocol.md` §3, §5.3, §5.4, §6, §7.3, §8, §9; `254-stage1-impl.md:210-220`. After forming
the findings below: `review-608b-A.md`, `review-v3-B.md` Part 1, `608b-v2-changes.md`.

Public sources fetched (saved under the session scratchpad `rv2/dl/`), cryptoauthlib `main`:
- `lib/calib/calib_device.h:234-249` (ChipOptions macros: bits 0, 1, 2, 8-9, 10-11, 12-15; **no bit 3**);
- `lib/calib/calib_command.h:431-443` (ECDH modes), `:478-489` (GenKey modes incl. `0x10`), `:541-558` (KDF source /
  target incl. TempKey and slot), `:632-650` (Nonce targets TempKey / MsgDigBuf / AltKeyBuf, 64-byte input),
  `:746-759` (SHA modes, `SHA_MODE_TARGET_MASK 0xC0`), `:771-778` (Sign: `SIGN_MODE_MASK 0xE1`,
  `SIGN_MODE_SOURCE_MSGDIGBUF 0x20`);
- `lib/cryptoauthlib.h:132-136`: `SHA_MODE_TARGET_TEMPKEY 0x00`, `SHA_MODE_TARGET_MSGDIGBUF 0x40`,
  `SHA_MODE_TARGET_OUT_ONLY 0xC0`;
- `lib/calib/calib_sha.c:176-180` (`calib_sha_end` sends mode `0x02` with target bits `00`), `:499-502, :540`
  ("For ATECC608, can be SHA_MODE_TARGET_TEMPKEY, SHA_MODE_TARGET_MSGDIGBUF, or SHA_MODE_TARGET_OUT_ONLY").

No device was contacted. The 608B complete data sheet was not available to me either.

---

## 1. Summary

The configuration bytes are right. Every hex value in §4 decodes to its prose, and every documented constraint holds
(§3 below). Removing the three v1 mechanisms closed both round-1 BLOCKERs and did not open a configuration hole.

What is still not ready is the gate in front of the lock and the contract with phase 1:

- K16 rests on an assumption the document never states: only GenKey can leave TempKey with the "GenKey" flags of slot
  0 or 2, and Sign(internal) signs only TempKey. The 608 has TempKey writers that the 508A-based fact base does not
  have, among them a plain SHA-256 whose **default** target is TempKey (cryptoauthlib `cryptoauthlib.h:132`,
  `calib_sha.c:176-180`). E7 does not try any of them, so a chip that would endorse an attacker's key passes every row
  of §8 and gets locked (B1).
- §9 leaves out protocol items the configuration depends on. One is that `peers/challenge` is signed today by the key
  that v2 makes internal-sign-only (M1).
- E4 locks a "variant" image that is written down nowhere (M2), and several negative tests are missing or have no
  positive control (M3).

Counts: **1 BLOCKER, 3 MAJOR, 15 MINOR.** Verdict: **REJECT** under `REVIEW.md` (a BLOCKER is open). On current
evidence the fix is to add tests and text; no configuration byte needs to change.

**E0–E3:** E0, E1 and E2 may start now, under the conditions in §7. E3 may start once the image it writes is attached
to the document. E4 may not.

---

## 2. Findings

### BLOCKER

**B1. The K16 gate (E7) misses the 608's TempKey writers and the Message-Digest-Buffer sign source; the assumption
K16 rests on is not stated.**

(a) Scenario. A root process on a captured node, or any bus master, wants slot 1 to endorse its own P-256 key `Q'` as
"the decryption key of this chip" (T-SE2: every later `net_secrets` for this node goes to the attacker).
1. `Nonce(random)` → `GenKey(0x08, slot 2)`. TempKey now holds the true digest of slot 2, with flags
   GenKeyData = 1 and KeyID = 2.
2. The attacker computes on the host `D' = SHA-256(TempKey_prev ‖ 40 08 02 00 ‖ SN[8] ‖ SN[0:1] ‖ 0^25 ‖ Q'.x ‖ Q'.y)`.
   They know every input: RandOut came back from step 1 and NumIn was theirs.
3. `SHA(start)`, `SHA(update/end)` over that 88-byte preimage, with target = TempKey. The 608 accepts a target field
   in the SHA command: `SHA_MODE_TARGET_MASK 0xC0`, and `SHA_MODE_TARGET_TEMPKEY` is `0x00`, i.e. the default
   (`calib_command.h:759`, `cryptoauthlib.h:132-136`). `calib_sha_end` sends mode `0x02` with no target bits
   (`calib_sha.c:176-180`). So after any plain SHA-256 computed on the chip, TempKey holds a digest the host chose.
4. `Sign(internal, slot 1)`.

If step 3 overwrites TempKey **without** clearing GenKeyData and KeyID, step 4 signs a 55-byte message identical to a
genuine endorsement of slot 2, except that the 32-byte field is `D'`. The reference verifier then accepts `Q'`. The
§2 rule "rebuild the 55 bytes from constants" does not stop this: every constant matches, including SlotConfig,
KeyConfig and SlotLocked of slot 2, because the flags still say "GenKey, slot 2".

The same question applies to:
- the other TempKey writers: SHA-HMAC end with target TempKey (`calib_sha.c:499-502, :540`), KDF with target TempKey
  or TempKey-upper (`calib_command.h:548-549`), ECDH with output to TempKey (`0x08` / `0x09`, `:442`), Nonce with
  64-byte input (`:641`), GenKey ephemeral (KeyID `0xFFFF`) followed by a digest mode, GenDig in the KeyConfig and
  shared-nonce zones (`:462-464`; Reviewer A asked for both in round 1, M1(c), and v2 dropped them), and GenKey
  `0x10` on slots 0–2;
- Sign mode `0x20` / `0x60` (internal, message source = Message Digest Buffer). `SIGN_MODE_MASK 0xE1` allows bit 5
  with bit 7 = 0 (`calib_command.h:771-778`). If the chip accepts it, the 32-byte field comes from a buffer that
  `Nonce` pass-through fills with any value (`:645`), while the flags still describe the last GenKey.

None of these is in E7. Only Nonce pass-through, random Nonce and GenDig on data / config / OTP / counter are listed.
The fact base cannot answer any of them, because its message layout and flag rules come from the 508A, which has no
SHA-to-TempKey, no KDF and no Message Digest Buffer. If any of them works, **no configuration closes it**: IntSign is
the only attestation mechanism the chip has, so K16 is lost for every unit. That is why it has to be answered on the
variant chip, before chip 2 is locked. As written, a chip with this hole passes E7 and F1.

(b) Evidence: cryptoauthlib lines above; [F] §2.3 (55-byte message, flags from the last TempKey producer; 508A
source); design §2 "常數包括…暫存區旗標（由 GenKey 產生、不是由 GenDig 產生、槽號）", §8 E7 list; K16
(`255-key-authority.md:84`) binds phase 1 (`:94`).

(c) Fix (tests and text only).
- In §2, state the assumption **A-K16**: "after GenKey(digest) on slot k, any command that writes TempKey (or that
  Sign(internal) reads instead of TempKey) either clears GenKeyData and the KeyID nibble, or is refused, and
  Sign(internal) never takes its 32-byte field from the Message Digest Buffer or Alternate Key Buffer". Mark it ⚠️ and
  tie it to E7.
- E7, for each writer X in the list above: positive control `Nonce(random) → GenKey(0x08, slot k) → Sign(internal)`
  is accepted for the true key. Negative: `Nonce(random) → GenKey(0x08, slot k) → X (aimed at the endorsement
  preimage of a host key Q', where X allows a chosen digest) → Sign(internal)`. Pass = the chip refuses, or the
  reference verifier rejects `Q'` **and** the message's flags byte differs from the endorsement constant. Run it for
  k = 0 and 2, and for Sign modes `0x00 / 0x40 / 0x20 / 0x60`.
- Failure outcome "停，回到設計", the same as E8.

### MAJOR

**M1. §9 is missing phase-1 items the configuration relies on; one current verb cannot run on the new slot map.**

(a) Scenarios.
1. `peers/challenge` is signed today by the DAC key: `ES256_DAC("batman-peer-v1" ‖ nonce_app ‖ nonce_node ‖ h)`
   (`219-protocol.md` §5.3; `keystore.go:74-77, :90-93` `PurposePeer`). In v2 the certificate key is slot 1, which is
   IntSign-only (`0x2082`). Sign(external) on it is refused, which E7 makes a pass condition. §9 says nothing about
   moving the verb to slot 0. Reviewer A m5 asked for exactly this mapping in round 1; it is still open.
2. C3 is claimed through "slot 0 signs the handshake hash at every login" (§2). §9 has no item saying where that
   signature travels (message-2 payload or the first transport message), what exactly is signed, or that the app
   **refuses the session and sends nothing (claim response, `owner_pub`, PSK-protected requests) until it has
   verified that signature** against the endorsed slot-0 key. Without that line, a phase-1 implementation can keep
   today's behaviour, where the static `node_cert` and the PSK are enough, and C3 is not delivered.
3. Domain separation. The labels removed in v2 were the only thing stopping a slot-0 signature made for one purpose
   from counting for another. Slot 0 still signs at least two kinds of digest (session `h` and `peers/challenge`). §9
   needs the rule: "every digest slot 0 signs is `SHA-256(label ‖ …)` and contains a value the verifier chose fresh
   (`h`, `nonce_app`); no verifier accepts any other slot-0 signature". This rule is what closes T-SE1 (pre-signed
   statements outliving custody). Today it lives only in `219` §3.6 for labels that v2 deletes.
4. Endorsements. §4.2 says the verifier's challenge enters through the random-mode Nonce. §9-1 puts "two endorsements
   (with the chip's random output)" into the static `node_cert`. Both cannot be true. Not stated: who makes the
   endorsements and when (factory step 6 only? helper at every boot, which C6 needs after a reflash?), what NumIn is
   for a static endorsement, and that `node_cert` carries NumIn as well as RandOut. Reviewer B C-M6 item 4 is still
   open.
5. `net_secrets`: `219` §7.3 "網主加密前一律驗 `sig_ecdh`" has to become "verify the slot-2 endorsement chain". This
   is the actual T-SE2 consumer, and it is not in §9.
6. Downgrade (§7.3): "舊映像會拒絕啟動 helper（`keystore.go:266-267`）". That refusal runs only if an identity
   directory exists whose `backend` file is not `file` (`keystore.go:238-268`). Nothing requires a chip image to
   write such a marker. Without it, an OTA downgrade to a pre-chip image takes the "no identity → generate one" path
   (`254-stage1-impl.md:196`) and creates a software identity on a chip unit (K20, R101).

(b) Evidence: as cited per item.

(c) Fix: add to §9:
- `peers/challenge` moves to slot 0;
- the session-proof message, its signed input, and the app's refusal rule;
- the slot-0 label and freshness rule;
- the endorsement producer and timing, NumIn / RandOut in `node_cert`, and the regeneration rule after a reflash;
- the `net_secrets` check;
- a `backend=se` marker that survives sysupgrade.

Make §4.2 and §9-1 agree. Static endorsements are enough for K16, because the keys are locked forever.

**M2. E4 irreversibly locks a variant image that nobody has written down or reviewed; the chip budget is unverified.**

(a) Scenario. §8 chip 1 is "各個不確定的候選設定放在不同的槽上". E3 writes it and E4 locks it. The document never
gives it. Several experiments only make sense on specific variant slots:
- E8 needs a non-NoMac control slot;
- E9 needs a writable store-to-slot target (its positive control, M3);
- E13 needs a key slot to lock while empty, which cannot be slot 0, 1 or 2 if E7 is to run on the same chip;
- E5 / E6 need a PrivWrite target.

Results also transfer to the final configuration only if the variant keeps the final non-slot bytes: 16–19, 68–83
and 90–95. E12, E14 and E16 test ChipMode, the address and ChipOptions, which are global. Anything not reviewed
before E4 costs one of the three chips, and that is the same irreversible mistake T-SE11 describes, one chip at a
time.

Budget: Q3 says 10 chips (3 for experiments, 7 left). The project memory records `ATECC608B-SSHDA-B ×3` bought on
2026-09-29 ("只有 1 顆備品"). If that is still the stock, the three-chip plan uses every chip. Logistics (SOIC on the HAT
U3 pad, which is empty on the units inspected; clip, socket or which HAT) are unstated. Reviewer B C-m4 raised this
and it is still open.

(b) Evidence: §8 chip-1 paragraph, E3, E4; project memory `project_secure_element_design.md:11, :56`.

(c) Fix: attach the variant image (per slot, with the reason each slot is there) and its CRC to the document, and have
it reviewed with this revision. The variant uses the final values for every non-slot byte. Confirm the chip count
with the user before asking Q3, and state the mounting plan.

**M3. Several C8 negative tests are missing or have no positive control.**

(a)
- **Writes to the claim slot.** Write (clear 32-byte, 4-byte, encrypted) to slot 5 and to one never-write slot after
  the data lock is in no experiment. E8 lists reads, DeriveKey and copy; E9 covers ECDH and KDF. Overwriting slot 5
  is the most direct R5 failure: the attacker sets their own claim secret. Control: the same Write to slot 8 before
  its slot lock succeeds.
- **E9 has no positive control.** If every store-to-slot attempt "fails", a wrong mode byte passes the test. Control:
  ECDH `0x05` (or KDF target slot) into a writable variant slot succeeds, and the stored value is shown by a later
  operation.
- **E12 has no control.** Control: UpdateExtra on byte 84 succeeds once.
- **E10 asks for something impossible.** It wants the "三種輸出方式" to match software, but with ChipOptions bit 1 = 0
  there is no IO protection key, so the encrypted mode (`0x0E` / `0x0F`) must be **refused**. Note that ChipOptions
  bits 15–12 = 0 name slot 0, a private key, as the IO key. E10 should show that encrypted ECDH and encrypted KDF
  output are refused with bit 1 = 0. If they are not refused, the chip is using a private key as a symmetric key.
- **External signing on slot 0.** The per-login proof depends on Sign(external) on slot 0, which has ReqRandom = 1.
  There is no positive test of the exact production path (Nonce pass-through or Message Digest Buffer, then
  Sign `0x80` / `0xA0`). It is inferred from the TFLX precedent only. Add it to E7 as a positive row.
- **E7's positive control** should be the same verifier code the app ships (`batman-proto`), not a second
  implementation, so that the experiment validates the code that decides in the field.

(b) Evidence: §8 rows E8–E12; §1 C8 "沒有對照的負向測試不算數".

(c) Fix: add the rows and controls above.

### MINOR

**m1. "One image plus its CRC" cannot be literally true.** The config-lock CRC covers all 128 bytes ([F] §1.3),
including SN[2:7] and RevNum (bytes 4–7, 8–12), which differ per chip. Define the reviewed artefact as bytes 16–127
except 84–87, plus its SHA-256. The CRC is computed per chip from the read-back. Byte 17 (reserved, must be 0) is
missing from §4.1.

**m2. The data-lock CRC must be computable, and OTP content has no reader.**
- The data zone and OTP cannot be read before the data lock ([F] §1.3, §10). The host therefore has to know every byte
  the CRC covers: the 4-byte tail of each 36-byte slot (3, 4, 6, 7) and, if E5 shows OTP cannot be written, the
  default OTP content. Whether a 4-byte write to an IsSecret slot is accepted before the data lock is not documented
  ([F] §2.1 IsSecret: "4-byte reads/writes prohibited").
- E5 / E6 must establish both, and §5 must give the fallback.
- "OTP = 設定版本與批號" has no reader in §7.2. Drop it, writing zeros if OTP is writable, so the only reason to touch
  OTP is the CRC.

**m3. §6.5 UI wording runs the wrong way.** Increment-before-commit, power-loss extra steps and root increments all
make the counter ≥ the number of enrolments. "至少被入庫過 N 次" is false; the honest reading is "0 = never enrolled
by official software; N > 0 = enrolled at most N times". The first bullet of §6.5 says the right thing, and the UI line
contradicts it. Reviewer B C-M7 proposed "at most".

**m4. C4 overclaims.** GenDig(slot 5) followed by Sign(internal, slot 1) is expected to **succeed** and returns a
signature over `H(K ‖ …)`. CheckMac is a match oracle. Both are outputs that depend on K. They are harmless only
because K is 256-bit random. Restate C4 as "no command outputs K or anything from which K is cheaper to find than
2^256 guesses". Add the GenDig(5) → Sign(internal) row to E8 as "succeeds; reference verifier rejects".

**m5. The 11 unused slots hold publicly known content.** `0x8F9F / 0x001C` is valid; it is TFLX slot 7 ([F] §2.1).
Its rules are documented for after the data lock, and before it most write restrictions are ignored ([F] §1.3), so
the factory can fill these slots. With zeros, each one is a NoMac key everyone knows. It can serve as a CheckMac key
(it sets AuthValid, which is inert with no ReqAuth) and as a GenDig key with host-chosen OtherData (an
attacker-computable TempKey carrying GenDig flags, which is what round-1 M1 used). This is inert today only because
no slot's WriteKey / ReadKey / AuthKey selects them as a working key (every WriteKey / ReadKey nibble is F, which
points at slot 15 but is unused, since Never-write / EncryptRead = 0) and because verifiers check KeyID and the config
constants. Either state that, or write random values (CRC computed, then discarded) so the slots are not a known key.

**m6. ReqRandom = 1 on slots 0–2 has no stated purpose.** §4.2 lists its consequences: RandOut and NumIn have to
travel in `node_cert`, and SourceFlag becomes a constant. It gives no benefit, and none of the three uses needs it.
Drop it (`0x0033`) or give the reason. If it is kept, M3's external-sign positive row is mandatory.

**m7. "未入庫的節點則限制頻率" is a new mechanism with no number.** C3 comes from signing a node-produced `h`, not from
the limit. The only reason for a limit is chip time, and `219` §8 already caps handshakes globally (20 per minute).
Cite it instead of adding one.

**m8. §7.3 factory-failure row is incomplete, and the helper does not check lock state.**
- Missing states:
  - keys locked but slot 8 empty: resumable at step 7;
  - slot 8 written but not locked: rewrite, then lock;
  - label printed for a unit whose later step failed (R69).
- "金鑰已產生但未全部鎖定 → 報廢" is safe but not necessary: bit 13 allows a regeneration before the lock.
- The helper should treat "config or data zone unlocked, or any of slots 0, 1, 2, 8 not slot-locked" as
  identity-unavailable. Slot 1's and slot 8's lock state is attested by nothing. This is Reviewer B C-M1 rule 3, not
  carried into §6.7.

**m9. §7.1 does not mark which rows the chip enforces.** It says the rows are enforced by C9, but C9 (K21) binds
non-root local processes only, not another root process or a repair-shop bus master.
- Mark each row as chip-enforced (config, locks, slots after lock) or software-only (counter 1; counter 0 and bytes
  84 / 85, which are harmless only because ChipMode bit 0 = 0 and no LimitedUse).
- Missing resources:
  - TempKey / Message Digest Buffer / AltKeyBuf / AuthValid, with a single sequencer in the helper so that no other
    chip command, a SHA included, interleaves a multi-command sequence (B1);
  - the I2C bus itself (shared with batpower and the RTC);
  - the development root key;
  - the experimental-chip list;
  - the image file;
  - the per-chip factory record;
  - the body label.

**m10. Replace the experimental-chip list with a check that already exists in the flow.** The station signs a
certificate only after reading back bytes 16–127 and finding them equal to the image. That also covers slot 1, whose
config no endorsement attests. A serial list is a second mechanism with its own owner and missing or stale states.

**m11. Development root.** `219` v0.7 §9 removed the development root ("公開 repo 裡的 CA 私鑰等於假的信任根"). §6.6
brings it back without saying so. State the reversal, where the key is kept (not in any repo), and its blast radius
(development app only). K20 says "任何情況下都不產生…軟體身分", but §9-4 allows a file backend in development builds.
Scope K20 to production builds, or cite the exception.

**m12. §2 "沿用 Microchip 在預先設定版上的分法" is inaccurate.** TFLX slot 0 `0x0085` and slots 2–4 `0x2085` combine
external signing with ECDH ([F] §2.1). Microchip separates only the internal-sign attestation key. v2's split is
stricter, which is fine; say so instead of citing precedent.

**m13. ChipMode bit 1 has a deadline but no rule.** For a 3.3 V bus with VCC = 3.3 V both settings meet VIH; pick 0
(fixed levels, [F] §9) unless E1 shows a reason otherwise. ChipOptions IO-key nibble: see M3 (E10).

**m14. Certificate.** KA D3 keeps X.509, so slot 8 holds DER. `ClientChal` hashes the DER the node sends
(`proto.go:50-52`). If slot 8 ever holds a compressed certificate rebuilt from a host template, a template change
breaks `claim/replay` for apps holding the old `node_cert`. Write "slot 8 holds the complete DER". Also state the
validity period (field life) and one CA versus per-batch intermediates (Appendix A item 9; Reviewer B C-m9).

**m15. Open MINORs from Reviewer B, unaddressed and not mentioned in `608b-v2-changes.md`:**
- C-m5: the label is fixed to the HAT;
- C-m7: batpower should refuse 0x60 in code (E0 checks only today's uci value);
- C-m10: a phase-2 condition that the identity is not shown to unauthenticated peers. `node_cert` goes to anyone in
  NX today.
- C-m11: a proof-type field in `node_cert`.

---

## 3. Per-slot decode (my decode; Python, bit fields from [F] §2.1–2.2)

| Slot | SlotConfig | Decode | KeyConfig | Decode | Matches prose |
|---|---|---|---|---|---|
| 0 | `0x2081` (`81 20`) | b15 0, PrivWrite(b14) 0, GenKey(b13) 1, b12 0, WriteKey 0, IsSecret 1, EncRead 0, LimitedUse 0, NoMac 0, ExtSign 1, IntSign 0, ECDH 0, ECDH→next 0 | `0x0073` (`73 00`) | Private 1, PubInfo 1, KeyType 4, Lockable 1, ReqRandom 1, ReqAuth 0, AuthKey 0, PersistDis 0, b13 0, X509id 0 | yes |
| 1 | `0x2082` (`82 20`) | as slot 0 but ExtSign 0, IntSign 1 | `0x0073` | as slot 0 | yes |
| 2 | `0x2084` (`84 20`) | as slot 0 but ExtSign 0, ECDH 1, ECDH→next 0 | `0x0073` | as slot 0 | yes |
| 5 | `0x8F9F` (`9F 8F`) | WriteConfig `1000` (Never; b13 = 0 so never a DeriveKey target), WriteKey F, IsSecret 1, EncRead 0, LimitedUse 0, NoMac 1, ReadKey F | `0x001C` (`1C 00`) | Private 0, PubInfo 0, KeyType 7, Lockable 0, ReqRandom 0, ReqAuth 0, AuthKey 0, X509id 0 | yes |
| 8 | `0x0F0F` (`0F 0F`) | WriteConfig `0000` (Always), WriteKey F, IsSecret 0, EncRead 0, NoMac 0, ReadKey F | `0x003C` (`3C 00`) | Private 0, KeyType 7, Lockable 1, ReqRandom 0, ReqAuth 0, X509id 0 | yes |
| 3, 4, 6, 7, 9–15 | `0x8F9F` | as slot 5 | `0x001C` | as slot 5 | yes |

Constraints checked:
- **IsSecret.** IsSecret = 1 wherever WriteConfig ≠ Always (slots 3–7 and 9–15). Slot 8 is Always with IsSecret 0,
  which allows clear reads. Every private key has IsSecret = 1.
- **ReadKey ≠ 0 everywhere.** For the CheckMac/Copy pairs: even slots 4, 6, 8, 10, 12, 14 copy into 5, 7, 9, 11, 13,
  15, all ReadKey F. Slots 0 and 2 are private (CheckMac refuses them); their N+1 neighbours are slot 1 (ReadKey
  nibble 0x2 ≠ 0) and slot 3 (F).
- **AuthKey = 0 with ReqAuth = 0**, all slots. X509id = 0 throughout.
- **KeyType.** 7 for every non-ECC slot, 4 for the keys.
- **Lockable polarity.** 1 = lockable, per the 508A table and the TFLX hex; set on 0, 1, 2 and 8 only.
- **GenKey / PrivWrite** are bits 13 / 14, not cryptoauthlib's 8 / 9.

Can the factory fill the unused slots, and is slot 8 usable as §5 requires?
- **Unused slots before the data lock:** yes. Before the data lock, Write ignores most restrictions ([F] §1.3, §10;
  508A source; Microchip ships `0x8F9F` in TFLX). The open question is the 4-byte tails (m2).
- **Slot 8 after the data lock:** writable, because Always-write stays writable until its SlotLocked bit clears
  ([F] §11), and Lock(slot) is allowed because Lockable = 1.
- **Data-lock CRC:** writing the certificate after the data lock does not break it. The CRC is checked once, at the
  Lock command, over the contents at that moment (zeros). Later contents are covered by step 7's read-back, not by
  the CRC.

Non-slot bytes:
- **ChipOptions** `0x0008` = bytes `08 00`: POST 0, IO protection 0, KDF-AES 0, bit 3 = 1, bits 7–4 = 0, ECDHPROT 0,
  KDFPROT 0, IO-key slot 0 (unused because bit 1 = 0; see M3). Bit 3 exists only in the TFLX data sheet;
  cryptoauthlib has no macro for it (`calib_device.h:234-249`, read). TFLX ships `0E 60`, which has bit 3 set, so the
  choice agrees with Microchip's reference.
- **ChipMode:** bit 0 = 0, bit 2 = 0, bits 7–3 = 0 (M0, the fastest clock), bit 1 open (m13). So `0x00` or `0x02`.
- **Other bytes:**
  - SlotLocked `FF FF`; 68–83 all `0x00`; CountMatch `0x00`; X509format `0x00`;
  - 52–67, 84–87 and 0–15 untouched;
  - byte 17 not stated (m1).

**No hex value in §4 is wrong.**

---

## 4. Round-1 findings: closed or not

| Finding | State in v2 |
|---|---|
| A-B1, A-B2, B-C-B1 | Closed by removal; nothing replacing them opens a hole |
| A-M1 | **Partly.** Constants rule added. E7 omits the KeyConfig and shared-nonce GenDig zones that A-M1(c) listed, and every 608-specific TempKey writer (B1) |
| A-M2 | **Partly.** Three chips and controls added, but the variant image is missing (M2), E9 and E12 have no control, and the "Write to slot 15" row was dropped (M3) |
| A-M3 | Closed (`0x0008`, reason stated) |
| A-M4 / B-C-M7 | Closed in substance; the UI sentence contradicts it (m3) |
| A-M5 / B-C-M1 | Tables added; gaps in m8 and m9; B-C-M1 rule 3 (refuse partial lock states) not carried over |
| A-M6 | Closed |
| A-m5 | **Open**: `peers/challenge` / `PurposePeer` → slot 0 not stated (M1) |
| A-m6 | Stated, but §4.2 and §9-1 contradict each other on where the challenge comes from (M1 item 4) |
| A-m10 | Partly: the "image + CRC" wording is not achievable as written (m1) |
| B-C-M2 | Closed, except the backend marker that makes the downgrade row true (M1 item 6) |
| B-C-M6 | Items 1–3 closed; item 4 (where endorsements live, who makes them) open; item 5 replaced by an unnumbered rate limit (m7) |
| B-C-m4, C-m5, C-m7, C-m9 (item 9), C-m10, C-m11 | Not addressed (M2, m14, m15) |

The removals did not open configuration holes. The one new mechanism v2 adds, the experimental-chip serial list,
can be replaced by a check the flow already needs (m10).

## 5. Wrong or unsupported facts in v2

1. §4: "完整的 128 位元組影像加上它的校驗值": the CRC is per chip (m1).
2. §6.5: "至少被入庫過 N 次": the wrong direction (m3).
3. §7.3 downgrade row: `keystore.go:266-267` refuses only when a non-file backend marker exists; nothing requires one
   (M1 item 6).
4. §8 E10: "三種輸出方式…相同" cannot hold for the encrypted mode with IO protection off (M3).
5. §2: "沿用 Microchip…分法": TFLX combines external signing and ECDH (m12).
6. §1 C4: "其他指令都算不出與它有關的輸出": GenDig + Sign(internal) does (m4).
7. §10 Q3: "剩 7 顆" conflicts with the recorded purchase of 3. Unverified either way (M2).
8. §4.2 vs §9-1: the endorsement is fresh in one and static in the other (M1 item 4).

## 6. Standing lesson: what is still an unneeded option

- OTP version / batch content has no reader (m2).
- ReqRandom = 1 on the keys has no stated purpose (m6).
- The rate limit for unclaimed nodes adds nothing to C3 (m7).
- The experimental-chip list (m10).
- Optional narrowing, not required: permanent keys generated before the data lock (TFLX-style `0x0081/0x0082/0x0084`
  with KeyConfig Lockable 0). This would remove the slot-lock step and the "key generated but not locked" state. It
  depends on GenKey working before the data lock, which is only inferred ([F] §10), so v2's choice is defensible.

## 7. Verdict

**REJECT** (`REVIEW.md`: a BLOCKER is open; revise and review the whole document again). The configuration bytes
themselves are correct and, on current evidence, need no change. B1, M1–M3 are fixed with tests and text.

**May E0–E3 start now?** Yes for **E0, E1, E2**, and **E3** only as described below, under these conditions:
1. **User consent per node.** On a bench node, only after the other session's v1.6 validation on that node is
   finished (§7.4).
2. **A tool that cannot lock.** The tool used for E0–E3 cannot send Lock (`0x17`), UpdateExtra (`0x20`), GenKey after
   a lock, or anything else outside Info / Read / Write-config / Random / Nonce. Build it without them; do not rely
   on "not calling them".
3. **Gentle probing.** E0 probes the bus without quick-write probing of unknown addresses. Wake with the general-call
   byte as already recorded in project memory.
4. **E2 is not strictly read-only.** It attempts Data-zone writes and GenKey before the config lock. These are
   expected to fail and are harmless if they do not, because nothing is locked. Label it that way.
5. **E3.** It writes and reads back only an image attached to the document: the §4 candidate filled in from E1, or the
   variant image once M2 is done. Keep byte 16 = `0xC0` and the final ChipMode. E3 is reversible; **E4 is not, and
   waits for this document's next review.**
6. **A chip must be mounted.** E1 and later need one; the U3 pad was empty on the units inspected (project memory,
   2026-11-21).
