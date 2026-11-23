# Review of `255-608b-config.md` v3 — Reviewer B, round 3 (field use, lifecycle, bench feasibility)

Reviewer: independent, second reviewer of this round (did not read `review-608b-v3-A.md`). Bound by
`docs/design/REVIEW.md`. Read in this order: REVIEW.md → target v3 → `255-key-authority.md` v3.1 → source → only then
the earlier reviews (`review-608b-A.md`, `review-v3-B.md` Part 1, `review-608b-v2-A.md`, `review-608b-v2-B.md`) and the
author's maps (`608b-v2-changes.md`, `608b-v3-changes.md`).
Source checked (read-only, tree `C:/src/Batman-255`): `feed/batman-prov/src/keystore/keystore.go`, `boot/boot.go`,
`cmd/batman-provhelper/{main,stable,trial}.go`, `node/node.go`, `provstore/provstore.go`, `proto/proto.go`;
`feed/batman-provision/files/usr/bin/{batman-autocommit,batman-config-save}`, `usr/sbin/batman-slot`,
`usr/lib/batman/prov-lock.sh`; `app/rust/batman-proto/src/nodecert.rs`; harness under `scripts/dv`, `scripts/node`,
`tests`. Facts file `608b-facts.md` ("F") for spot checks only. No device contact.

Counts: **0 BLOCKER, 7 MAJOR, 12 MINOR.**

Verdicts (detail in §5):
- **E4 on the first sacrificial (variant) chip:** APPROVE-WITH-CHANGES — only after M6 (the variant image lacks control
  slots that cannot be added after the lock) and the rig choice in M7 (a) are fixed in the document.
- **Locking the final bench image (chip 2 onward, and the bench-node chips):** REJECT for now — M1, M2, M3, M5 must be
  closed in the document, and E/F1 results must be in.
- **Document as a whole:** REJECT under REVIEW.md (MAJORs open; revise and review the whole document again).

---

## 1. Findings

### MAJOR

**M1. The claim secret is lost if anything goes wrong between the data lock and the record, and deleting it after the
QR is printed makes automated validation impossible.**

(a) Scenarios.
1. *Interruption.* §5: step 3 writes a random claim secret into slot 5; step 4 locks the data zone; the secret is
   recorded only at step 8, after a dev-root round trip (steps 6–7) that involves a developer machine and can take
   minutes or hours. The document does not say where the secret lives between step 3 and step 8. If it is only in the
   helper's memory (it must not be on the node's disk, v2-B M4), then a reboot, crash, power loss or a lost SSH session
   anywhere between step 4 and step 8 leaves a chip whose slot 5 holds a secret nobody knows, that can never be read
   (`0x8F9F`: IsSecret, EncryptRead 0) and never be rewritten (WriteConfig Never). The chip is unclaimable for life.
   §7's interruption row does not list this state.
2. *Validation.* Step 8: "認領秘密（印成機身 QR 後從燒錄紀錄刪除）". The harness claims nodes automatically, and it
   gets the secret from the node: `tests/tools/provclient/main.go:517` reads
   `/etc/batman-prov/identity/claim.secret`; `scripts/node/prov-p1-254.sh:39, :64` and
   `scripts/dv/prov-claim-254.sh:48-51` use it as a log canary; `scripts/dv/prov-bench-s0-254.sh:448` hands the operator
   `batman-provhelper qr`, which prints the file (`main.go:598-623`). On a chip unit none of this can work, and §9-10's
   "改成透過 helper 取得" is impossible: the helper cannot read slot 5 either. With the secret deleted from the only
   other copy, every claim needs a human to scan a printed label. Daily validation and the "full validation" rule
   (every claim / re-claim / reset test, unattended) cannot run on a chip node.
3. The production question of a lifetime QR (§10) does not apply to a bench chip. A bench chip is a development unit
   for life (slot 8 is signed by the dev root), so keeping its secret in a private record costs nothing that a bench
   needs to protect.

(b) Evidence: target §3 (slot 5), §5 steps 3–8, §7 interruption row, §9-10; source lines above.

(c) Fix.
- The secret is generated **on the developer machine** and written to the burn record (keyed by chip serial, state
  "pending") **before** it is sent to the node. The node writes it at step 3. The data lock at step 4 uses a CRC over
  the whole data zone, slot 5 included, so a successful lock **proves** the chip holds exactly the recorded secret; the
  record then moves to "locked". An interruption before step 4 is redone with the same or a new secret. An
  interruption after step 4 loses nothing.
- Bench records keep the secret, in the private ops repo or on the developer machine (state which, and who can read
  it). The harness reads it from there (one host-side helper used by `provclient`, `prov-claim-254.sh`, and the
  others), and the secret never touches the node's filesystem or logs. Keep the existing canaries, pointed at the
  host-side copy.
- State in §5 that the burn command never prints the secret to the node's stdout or syslog.

**M2. The burning mode has no operational contract: trigger, coexistence with the running helper, the dev-root round
trip, resumable states. Round-2 B M4 and A m8 / m9 were reworded, not closed.**

(a) Scenarios.
1. *Trigger and coexistence.* §5 says only that "helper 的燒錄模式" does it. It does not say whether this is a CLI mode
   (`batman-provhelper burn …`, like `qr` at `main.go:588`) run by an operator over SSH, or something the daemon does
   by itself. §7's reflash row says "燒錄模式偵測到已燒錄的晶片，寫回標記" (burn mode running at boot), while §9-5 gives
   the same detection to the helper at boot. If it is a CLI, then two helper processes talk to one chip, the daemon
   (which per §7 retries the chip at each login and makes endorsements at start) and the burner. A daemon command
   that lands between the burner's Nonce → GenKey → Sign, or that sends the chip to sleep, clears TempKey in the
   middle of a burner sequence. The project already has the lesson that a second daemon instance takes over the helper
   socket (memory: never run the helper bare). Round-2 A m9 asked for "a single sequencer in the helper" as an owned
   resource; v3 §7 still has four rows.
2. *Dev-root round trip.* Step 6 gives a condition ("只有讀回的設定與影像完全相同、且槽 0–2 都已鎖定時") but not who checks
   it or what crosses to the developer machine. If the node checks and the developer machine signs whatever public key
   the node sends, the dev root signs on the node's word. A bench node someone has root on can then get a dev-root
   certificate for a software key, which the development app accepts. That is K16 at the certificate level. The input
   should be a file holding the raw config-zone dump, the chip serial, the slot 0/1/2 public keys and the two
   endorsements with their nonces. The developer machine re-checks the config CRC and image itself, verifies the
   endorsements with the `batman-proto` verifier, and only then signs. The output is a certificate file that goes back
   to the node. That still trusts the node for the raw dump, which is the bench's inherent trust; say so (m10).
3. *Resumable states.* Round-2 A m8 listed the missing ones: keys locked and slot 8 empty (resume at step 6); slot 8
   written and not locked (rewrite, then lock); a label printed for a unit whose later step failed. v3 §7 still has
   only three generic states, and still says "金鑰已產生但未全鎖 … 只能報廢". With WriteConfig bit 13 = 1 (`0x208x`),
   GenKey may run again on any key slot that is not yet slot-locked (F line 115, "bit 13 = GenKey permission"). Scrapping
   is unnecessary, and with 3 experiment chips it is expensive (m3).
4. *Custody.* Where the dev-root private key lives, who holds it, how it is destroyed or rotated (threat model R69),
   and what happens to the chips whose slot 8 it signed if it leaks (M3), are not stated.

(b) Evidence: target §5, §7 (ownership table, reflash row), §9-5; `main.go:570-596` (modes), `:625-716` (daemon);
round-2 B M4, A m8, A m9.

(c) Fix: add a short §5.1 "burn contract":
- The burner is a root CLI mode. It refuses to run while the daemon runs: it stops the procd service and takes a
  host lock, or the daemon itself owns a chip mutex that the CLI goes through. Pick one.
- Inputs and outputs are files (CSR-like bundle out, certificate in), and the developer machine verifies with the
  shipped verifier.
- Give the resumable-state table: one row per persisted chip state, saying what the burner does and what the daemon
  reports.
- Name the dev-root custody.
- Remove "only scrap" for key slots.
- Add the chip sequencer, the I2C bus, the dev-root key, the image file, the burn record and the label to the
  ownership table.

**M3. Slot 8 is slot-locked forever with a certificate whose format has not been designed.**

(a) Scenario. §5 step 7 writes "開發根簽的憑證" into slot 8 and locks it individually. §9-1 leaves the `node_cert`
redesign (fields, what the certificate binds, the proof-type field, round-2 B m9) to the phase-1 implementation
design, which does not exist yet. Round-2 A m14 asked for "slot 8 holds the complete DER", a validity period, and one
CA versus intermediates; v3 says none of these. If the bench chips are burned now, and the phase-1 design later
changes the subject, the extensions, the key the certificate names (slot 1 versus slot 0), or the dev-root key itself,
every burned bench chip carries a permanently wrong certificate. The cheapest outcome is a host-side workaround that
becomes a second trust path. The expensive one is new chips, when only 7 are left after the experiments.

(b) Evidence: target §3 row 8, §5 step 7, §9-1; `nodecert.rs:146-156` (today's gate is CN-based); round-2 A m14.

(c) Fix: split the burn. Steps 1–5 (config lock, data lock, key generation and slot locks) may run once the E/F1 results
are in. Steps 6–7 (certificate written and slot 8 locked) run only after the phase-1 design has frozen the
certificate profile. Slot 8 stays writable until then: a root process overwriting it is only a denial of service,
because the certificate is verified against the dev root. State the profile (complete DER, subject, the key it names,
validity, CA structure) in this document or point to the phase-1 section that will.

**M4. The trial rule (§7) is a statement without a mechanism, and the obvious implementation commits a trial whose
chip fails.**

(a) Today's code does what §7 wants only because the helper never listens without an identity.
`main.go:632-636`: `keystore.Load` fails → "serving nothing" → `select {}` before `srv.Listen` (`:706-708`). provd
never connects, so `stableWriter.onPeer` never runs (`stable.go:30-50`), so `provd-stable` is never written. Then
`health_ok` fails ("batman-provd not stable for 60 s yet this boot", `batman-autocommit:510-512`), the trial is never
committed and the watchdog reverts it. ✅ for a chip that fails before the helper starts serving. Four things break
once v3 is implemented:
1. *Retry at each login needs a listening helper.* §7 "正常運作中晶片無回應 … 每次嘗試登入時重試一次" requires the helper
   to listen while it has no identity; otherwise no login reaches it. Once it listens, provd connects, and after 60 s
   `provd-stable` is written regardless of the chip. A trial image with a broken chip driver then commits, which is
   exactly what round-2 B M7 described. §7 says "helper 不進入可服務狀態" in a trial but not how the same binary is
   both listening (committed) and not listening (trial), nor what happens at the moment of commit.
2. *Latched gate (#265 pattern).* `provd-stable` is latched (`done` flag, `stable.go:41-48`). A chip that works for the
   first 60 s and then fails (a driver bug after the first sleep, a watchdog-timing bug in a long sequence) still
   commits. REVIEW.md names #265 for this reason. `autocommit` re-reads the file at every poll (`:511`), so the helper
   could withdraw it, but the design does not say so.
3. *One transient failure reverts a good image.* "晶片無回應 = 試用失敗" with no retry inside the trial deadline: a
   single bus glitch at boot (the bus is shared with batpower and an RTC) reverts a good OTA.
4. *"Unknown" is treated as trial.* `execIsTrial` returns trial for any rc ≠ 1 (`trial.go:31-35`). `batman-slot
   is-trial` returns 2 when it cannot tell (`batman-slot:914-920`; e.g. a card without A/B slots, or an unreadable
   autoboot). Under §7, a chip failure on such a boot makes the helper never serve, and no revert will ever come.

(b) Evidence: as cited; target §7 rows "試用開機" and "正常運作中晶片無回應", §9-9.

(c) Fix: write the mechanism into §7 / §9-9.
- The helper always listens.
- While `is-trial` is not "committed" (rc ≠ 1), it writes `provd-stable` only after a successful chip operation in
  this boot, and deletes it at once on any chip failure. It retries the chip every N s until the autocommit deadline.
- Add `chip_ok=<0|1> ts=` to `batman-prov.health`, and make autocommit require it fresh (≤ 60 s), blocking, at the
  commit decision: the same freshness rule as the BLE line at `:569-573`, but blocking.
- Say what "unknown" does (suggestion: like committed, i.e. serve and retry).
- Tests, each with a negative control on today's code or on a build without the change:
  - trial image with the chip held from boot → reverts;
  - chip held at t = 90 s, after `provd-stable` → still reverts;
  - one glitch at boot, then the chip recovers → commits;
  - committed image with the chip held → serves "identity unavailable", and recovers when the chip is released.

**M5. The chip-identity marker rule (§9-5) cannot deliver K20 by probing, and the OTA / downgrade rows rest on
artefacts the design never creates.**

(a) Scenarios.
1. *Reflash plus a transient chip failure.* After an SD reflash the marker (on the data partition) is gone. That
   partition is reflashed with the card, recreated when damaged, and sometimes not mounted at all, which is why
   autocommit checks it (`batman-autocommit:493`). The first boot finds "no marker" and probes. If the probe fails
   transiently (bus glitch, the i2c module not yet bound, the HAT not seated), §9-5 says "no marker, no chip → file
   backend". `boot.Run` case 7 then generates and persists a software identity to p5 (`boot.go:186-210`). On the next
   boot the chip answers: "no marker, burned chip → write the marker back". Now p5 and the overlay hold a file
   identity, the chip holds another, and the rule says the file one is never used. What the record (made with the
   file id) means, and whether §9-6 then voids it, is undefined. K20 ("任何情況下都不產生…軟體身分") is broken in step 1
   on a chip unit.
2. *OTA from today's image.* Nodes 02/04 run file identities today, and the deployed-role node is "sysupgrade only"
   (project rule). §7 says an in-place upgrade from file to chip is unsupported, but nothing refuses it: the harness's
   routine OTA will do it. The chip image boots in trial, finds no marker and a burned chip, and writes the marker (on
   p6, which survives a revert). It then sees a record made with the file id, and §9-6 "不符 → 視為新機，舊紀錄作廢" voids
   a claimed record during a trial. `node.go:258-259` blocks state-changing verbs in a trial, but `boot.Run` writes
   regardless. The node is now unclaimed. autocommit treats unclaimed as "no mesh required"
   (`batman-autocommit:447`), so the trial can commit a node that has silently lost its owner.
3. *Downgrade row.* "舊 helper … 看到晶片身分目錄會拒絕（`keystore.go:266-267`）" assumes an identity directory whose
   `backend` is not `file`. §9-5 puts the marker on the data partition and nowhere creates such a directory. Without
   it, the old image's `boot.Run` generates a software identity (case 7 or 9) or freezes with `unknown(identity-lost)`
   (case 13), depending on what p5 holds. Round-2 A M1 item 6 and B M7 item 3 are not closed.
4. *Missing phase-1 machinery.* The whole persistence path assumes a 7-file identity directory:
   - `prov-lock.sh:7` `PROV_IDFILES`;
   - `batman-config-save --prov-get` rc 13 "identity incomplete" and `prov_ident_ok` (`batman-config-save:31-32, :229`);
   - `boot.go:80-258`.

   §9-6 / §9-7 do not mention any of these (round-2 B M8 item 1, partly closed).

(b) Evidence: as cited; K20 (`255-key-authority.md:88`) binds phase 1 (`:94`).

(c) Fix.
- **A probe never creates a software identity.** A file identity is created only by an explicit act (harness or
  operator CLI, e.g. `batman-provhelper --init-file-identity`) on a unit declared HAT-less, and that declaration is
  stored with the identity on p5.
- After a reflash, "no marker and no chip" is "identity unavailable, retry", never generate. CI and HAT-less dev nodes
  run the explicit command once (`fresh-254.sh` gains that step).
- On a chip unit, write a `backend=se` identity stub (serial, node id, cert hash) to the overlay and p5 through the
  existing persistence path, so that the old helper refuses at `keystore.go:266`, the reconciliation keeps working,
  and the marker survives exactly as long as the identity does. That replaces the separate p6 marker.
- The chip image treats an existing `backend=file` identity as "identity unavailable" (→ trial failure → revert), and
  never voids it.
- Add `prov-lock.sh`, `batman-config-save` and the `cfgsave-identity-*` tests to §9.
- Amend K20's text to "on a unit that has a chip" (m9).

**M6. The variant image (locked at E4) lacks the control slots several listed negatives need; they cannot be added
after the lock.**

(a) §8 promises "每個「應該失敗」的測試都有一個…「應該成功」的對照" (C8), and E8 says "對照：同樣的指令在槽 3 上成功". Decoding
§8.1 slot 3 (`0x0F8F / 0x003C`) with F §2.1 (lines 115-121, 141, 372):
- **Read**: IsSecret = 1 and EncryptRead = 0 → "Reads are never permitted". The control fails on slot 3 exactly as the
  negative does on slot 5.
- **CheckMac copy**: slot 3 is odd, so the target is itself, which needs ReadKey = 0. It is F → fails.
- **DeriveKey target**: WriteConfig = 0 → bit 13 = 0 → "can never be a DeriveKey target" → fails.
- **AES**: needs KeyType 6. It is 7 → fails.

Four E8 negatives therefore have no working control, and a negative that "fails" for a wrong reason (a wrong mode
byte, a wrong length) passes unnoticed. Other gaps:
- **E13**, "產生金鑰前先鎖一個金鑰槽": needs a key slot that is still empty and not locked. Slots 0, 1, 2 and 4 are all
  used by E7. Round-2 A M2 raised this and it is still open.
- **E6**, "私鑰槽的…加密寫入" must fail: no slot has PrivWrite enabled (bit 14), so there is no positive PrivWrite
  control either (round-2 A M2: "E5 / E6 need a PrivWrite target").

All of these are properties of the variant chip's configuration, which E4 locks. Afterwards the only remedy is
another chip, and the budget has one spare.

(b) Evidence: target §8.1, E6, E8, E13; F lines 115-121 (SlotConfig bits), 141 (Private), 372 (AES needs KeyType 6).

(c) Fix before E4. Either add control slots to the variant (slots 7, 9–15 are free), for example:
- a KeyType 6 slot with ReadKey 0, so read, copy and AES have a positive path, or split these over two slots;
- a slot with WriteConfig bit 13 set as a DeriveKey target;
- a spare `0x2083 / 0x0073` key slot left empty for E13;
- a PrivWrite-enabled key slot.

Or drop the negatives whose failure is structural (KeyType, ReadKey ≠ 0) and say why. Then have the new values
decoded bit by bit.

**M7. The experiments and lifecycle tests are not yet runnable on the real bench.**

(a)
1. *Which rig.* The chip goes on a WM1302 HAT's U3, and on the bench nodes that HAT is the carrier for HaLow (project
   notes). Putting the chip HAT on 02 or 04 changes the rig the other session is validating v1.6 on. E4 and E11
   require power cycles ("斷電後"), and §7's tests require one power cut after every burn step. These collide with that
   session and with the deployed-role "sysupgrade only" rule. "實驗前寫明用哪一片 HAT、哪一台節點" defers exactly the
   decision that decides feasibility.
2. *Tests that cannot be done as written.*
   - "拔晶片開機": the chip is soldered.
   - "短暫拉住匯流排": no method is given, and holding the bus also stalls batpower and any RTC.
   - "換 HAT": needs a second burned HAT.
   - "每一步後斷電": a cut after step 5 scraps a final-image chip under today's §7 (m3), and none is budgeted. The budget
     (variant / final / spare) covers the experiments, not §7's tests.
3. *Missing lifecycle rows* (REVIEW.md item 3, round-2 B M7 item 4 still open):
   - clean shutdown / reboot (chip asleep versus mid-sequence);
   - OTA stage 1 / stage 2;
   - helper restart (endorsements regenerated, two internal signs);
   - provd restart (`node_cert` rebuilt);
   - crash loop;
   - power loss outside burning;
   - both boards (which board each bench node is, round-2 B m11).

(b) Evidence: target §7, §8 header and last paragraph; key-authority U6 (4 HATs).

(c) Fix.
- Name a dedicated experiment rig: a third Pi of the **same board** as the target node, with a spare HAT, no HaLow
  needed for E0–E13 and E15–E16. Run E14 later on a bench node.
- Give each §7 test its method: a chipless HAT for "chip absent", a GPIO-driven SDA hold on the rig for "bus held",
  and so on.
- Budget the chips per test.
- Add the missing rows with "N/A + reason" where that fits.

### MINOR

- **m1. E12's expected result is wrong, and the tool cannot run it.** UpdateExtra writes byte 84 and byte 85 once
  while they are 0x00, with no authorisation (F lines 82-83, 283). So "改不動" will fail on a correct chip and trigger
  "停". What must hold is "the address is unchanged after a power cycle, because ChipMode bit 0 = 0". The control
  round-2 A M3 asked for (UpdateExtra on byte 84 succeeds once) was replaced by "讀回 84 / 85 為原值", which is not a
  control. Also, §5 says the tool is built without alternate-address commands, yet E12 needs UpdateExtra. Say which
  tool runs E12.
- **m2. E7's reference verifier must be the shipped `batman-proto` code** (round-2 A M3, last bullet). "參考驗證程式"
  leaves room for a second implementation.
- **m3. Partially generated key slots need not be scrapped** (round-2 A m8, not closed; see M2 (3)).
- **m4. §9-6 auto-voids a claimed record on a node-id mismatch.** That is destructive on a read result, and unlike
  today's rule, which freezes a mismatch (`boot.go:111-113`, `unknown(identity-mismatch)`, P-U6). Freeze it and require
  a reflash (round-2 B m8).
- **m5. Counter.**
  - U9 (key-authority §1, a user decision) says "至少被入庫過幾次", and §6 says "最多". The correction is right, but a
    user decision is being changed: put it to the user and update U9.
  - The counter proof (E11, slot-1 internal sign over the counter) has no consumer in §9's phase-1 list. It adds a
    second slot-1 message type that E7 (f) must tell apart from an endorsement. Remove it from bench scope; keep
    E11 = "increments, persists across power loss".
  - Round-2 B m4 ("increment only after the claim proof and the owner signature verify") is still not stated.
- **m6. Ownership table missing resources** (round-2 A m9): chip volatile state / sequencer, the I2C bus, the dev-root
  key, the image file, the burn record, the label (see M2).
- **m7. E0 inventories only programs that open `/dev/i2c-*`.** Kernel-bound clients (`/sys/bus/i2c/devices`, e.g. an RTC
  driver at 0x68 if fitted) also share the bus. Add them. Round-2 C-m7, "batpower refuses 0x60 in code", is still not
  in §9.
- **m8. Unused slots written with zeros are a publicly known NoMac key** (round-2 A m5). State why that is inert (no
  WriteKey / ReadKey / AuthKey points at them; verifiers check KeyID), or write random values.
- **m9. K20's text needs a scope.** As written ("任何情況下"), every phase-1 file-backend node breaks it. Amend it in
  key-authority to "on a unit with a chip", or cite §9-5 as the exception (round-2 A m11, half closed).
- **m10. What a dev-root certificate means.** It means "a developer burned this chip on a node they controlled", not
  chip attestation. Say so in §5. The development app must not present it as more.
- **m11. ⚠️ EEPROM wear from the per-login random Nonce.** Endurance is 400 000 writes per byte (F line 406), and the
  app logs in every 60 s in the foreground. Whether the Nonce random mode used per login updates an EEPROM seed is not
  stated. Find out in E14, or use a mode that does not update the seed.
- **m12. C9 says "不另開程式", but §5 / §8 use separate experiment tools** ("E0–E3 用的版本"). That is fine for sacrificial
  chips. Say that the experiment tools are a stated exception to C9 / K21, valid only on the rig.

---

## 2. Earlier findings: closed or not

| Finding | Status in v3 |
|---|---|
| v2-A B1 (K16 assumption, TempKey writers) | Closed: assumption stated in §2, E7 (a)–(j) extended, failure outcome defined |
| v2-A M1 (phase-1 items) | Mostly closed (§9-1..13). Item 6 (a `backend=se` marker visible to old images) **not closed**: the marker went to the data partition (M5) |
| v2-A M2 (variant image, budget, E13 slot) | Variant written; **E13's empty key slot and the PrivWrite target not addressed** (M6) |
| v2-A M3 (controls) | E6, E9, E10, E14 added. **E12 control replaced by a read (m1); E7 verifier not pinned to `batman-proto` (m2)** |
| v2-A m1, m2, m3, m4, m6, m7, m10, m12, m13 | Closed or folded |
| v2-A m5 (zero slots = known key) | **Not closed** (m8) |
| v2-A m8 (resumable states; scrap unnecessary) | **Not closed** (M2, m3) |
| v2-A m9 (missing resources, sequencer) | **Not closed** (M2, m6) |
| v2-A m11 (dev root reversal; K20 scope) | Reversal stated; K20 scope half closed (m9) |
| v2-A m14 (slot 8 DER, profile) | **Not closed**, and it now matters more (M3) |
| v2-A m15 (C-m7 batpower 0x60; C-m10) | **Not closed** (m7); C-m10 moved out with production scope, acceptable for bench |
| v2-B M1, M2, M3 | Closed by the scope change (§10) |
| v2-B M4 (factory / bench burn: who, where, secret path, dev-root step, custody) | **Reworded, not closed**: "helper 的燒錄模式" names a binary, not a procedure (M1, M2) |
| v2-B M5 (endorsement origin) | Closed (helper at boot, in memory) |
| v2-B M6 (per-login cost) | Closed (§9-13; baseline #329) |
| v2-B M7 (trial commit; OTA across backends; downgrade; missing rows) | Rule stated, **mechanism missing** (M4); OTA / downgrade **not closed** (M5); missing rows **not closed** (M7) |
| v2-B M8 (K20 vs file backend; missing bring-up work) | Marker rule added but **not enforceable** (M5); harness item added but **contradicted by deleting the secret** (M1); persistence path **missing** (M5 (4)) |
| v2-B m4 (counter order) | **Not closed** (m5) |
| v2-B m8 (HAT swap) | Replaced by auto-void, which is worse (m4) |
| v2-B m11 (boards) | **Not closed** (M7) |
| v2-B m13 (general call in E0) | Closed |
| v2-B other MINORs | Closed or moved to §10 with the production scope |

New in v3, not opened by the earlier reviewers:
- M3: slot-8 lock order versus the undesigned certificate format.
- M4 (2–4): the latched gate, transient revert, and "unknown" read as trial.
- M5 (2): an OTA voids the record and commits the trial.
- m5: U9 conflict.
- m11: Nonce wear.

## 3. Wrong or unsupported statements

1. §7 downgrade row: "舊 helper … 看到晶片身分目錄會拒絕" — no chip identity directory is created anywhere in v3; the
   refusal at `keystore.go:266-267` needs one (M5 (3)).
2. §8.2 E8: "對照：同樣的指令在槽 3 上成功" — false for read, CheckMac copy, DeriveKey target and AES under slot 3's
   values (M6).
3. §8.2 E12: "改不動" — UpdateExtra on bytes 84 / 85 succeeds once by design (m1).
4. §7 reflash row ("燒錄模式偵測…") versus §9-5 (the helper detects at boot): two different owners for one action (M2).
5. §1 C9 "不另開程式" versus §5 / §8 experiment tools (m12).
6. §6 "最多" contradicts user decision U9 "至少" without saying so (m5).

## 4. Options without a present use

- Counter proof by slot-1 internal sign (§6, E11): no phase-1 consumer; remove (m5).
- The separate p6 marker: replaced by a `backend=se` identity stub that the existing persistence path already carries
  (M5). Removes one resource and its missing / stale states.
- Everything else in the configuration has a stated present use on the bench.

## 5. Verdicts

- **E4 on chip 1 (variant): APPROVE-WITH-CHANGES.** Nothing in M1–M5 touches chip 1: it is never signed, never claimed
  and never a node identity. Before locking:
  - fix §8.1 / §8.2 per M6 and have the new slot values decoded;
  - name the rig per M7 (1), not 02/04 while v1.6 runs there;
  - complete E0–E3 (byte 17 and ChipMode bit 1 come from E1);
  - fix E12's expectation (m1), which may be done before E12.
- **Locking the final bench image: REJECT for now.**
  - The config lock of chip 2 may follow once E1–E16 are in and M6 is fixed (the config bytes need no change today).
  - The **data lock** needs M1 (secret flow) and M2 (burn contract).
  - The **slot-8 lock** needs M3 (certificate profile frozen).
  - Bench-node chips additionally need M4 and M5 in the phase-1 design before they are used as node identities.
- **Document: REJECT** (0 / 7 / 12). The config values stand. The open items are procedure, lifecycle and phase-1
  mechanism, and most are short text changes.
