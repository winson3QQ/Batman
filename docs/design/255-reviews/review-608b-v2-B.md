# Review of `255-608b-config.md` v2 — Reviewer B, round 2 (field use, lifecycle, feasibility)

Reviewer: independent; had not seen the design before this round. Read-only on the repo; no device or network contact.
Base: worktree `C:/src/Batman-255`, main 4eba26d plus the untracked #255 design files.
Read: the target in full; `255-key-authority.md` v3.1; `255-threat-model.md` §3.0–§3.3, §5.1, §5.7, §9 (R1–R9, R14,
R15, R20, R65, R66, R69, R76, R84, R94, R99, R101, R102, R110), Appendix A; `REVIEW.md`; source
`keystore/keystore.go`, `proto/proto.go`, `node/node.go:240-275, 370-430, 574, 662`, `provd/server.go:265-360, 720-780`,
`boot/boot.go:30-200, 400-440`, `cmd/batman-provhelper/main.go:470-500, 600-715`, `stable.go:1-30`,
`batman-provision/files/usr/bin/batman-autocommit:436-530`, `app/rust/batman-proto/src/nodecert.rs:130-200`;
`254-stage1-impl.md:180-336`; `hat-v1-spec.md`, `219-field-provisioning.md:23, 512`; `329-app-uiux.md` (login timings);
harness file list (`scripts/dv`, `scripts/node`, `tests`). Round-1 reviews (`review-608b-A.md`, `review-v3-B.md`
Part 1) and `608b-v2-changes.md` were read after forming the findings below.

Counts: **0 BLOCKER, 8 MAJOR, 16 MINOR.** Verdict: **REJECT** (revise and review the whole document again), with
two notes: the slot plan and the hex values of §3–§4.2 drew no finding from me (decoded bit by bit, see §4 below),
and **E0–E3 may start now** under the conditions in §5.

Most fixes below are narrowings or removals: say this configuration is for the phase-1 bench/dev chips only, put
three more costs to the user before any lock, and remove four options that have no reader.

---

## 1. Findings

### MAJOR

**M1. The document calls §4 the production configuration, but the production board carries a different part, and two
production questions are decided implicitly by it.**
(a) Scenario. §6.6 / R15: "鎖定工具只接受 §4 的影像" and §6.3: "被擄節點的防護，改由 secure boot 加資料分割區加密負責。晶片端
不再為它預留". So every production unit would get this exact config. But the CM4 base-board verification design
`hat-v1-spec.md` places **ATECC608C-TFLXTLS at 0x36** (config zone fixed by Microchip, not writable) plus a TPM
SLB9672 (`hat-v1-spec.md:33, 95, 138-142, 546, 557, 567`), while `219-field-provisioning.md:23, 512` decided a blank
608B-SSHDA at 0x60 "→ 換料". The production part (608B vs 608C, blank vs TrustFLEX; TPM as identity backend, D7) is
therefore open. A 608C reports a different revision, so E1's "版本 `00 00 60 03`" cannot hold for it.
(b) Evidence: as cited; target §6.6, §7.3 row "開發版與量產版", E1.
(c) Fix (narrowing): state the scope as "phase-1 bench / development chips: ATECC608B-SSHDA on the WM1302 HAT U3";
the production configuration is decided with the production part and the secure-boot design (#256 / #115), reusing
whatever this one proves. Drop "量產" wording from §6.6, §7.3 and §9-4, or mark it ⚠️ pending the hardware decision.
Add the part choice as a user question (it is money and hardware, so it is the user's).

**M2. "No chip–board binding" is presented as covered by secure boot; the threat model says the opposite. If §4 is the
production image, this is an irreversible product decision the user has not been asked.**
(a) Scenario. Shipping state ON (U8). A node is captured; the holder lifts the HAT (or clips onto the 40-pin header)
and wires it to their own host. Secure boot protects the CM4's software, not the chip: slot 0 signs any digest, slot 2
does ECDH with any public key, slot 1 endorses. With the node in hand they impersonate it in logins (C3 holds only
after return) and use slot 2 as a decryption oracle for every bundle ever addressed to the node (T-SE3; slot 2 is
locked, so it never rotates). Threat model §3.2 item 1: "T-SE1 … T-SE6 therefore remain in state ON until that
[Appendix A item 19] is decided"; §3.3 row "capture of a node": "SE still usable from another host unless Appendix A
item 19 is decided". v2 decides item 19 = "never" for every unit, while §6.3 tells the reader secure boot replaces it.
The round-1 removal of `ReqAuth` was right (round-1 A-B2 / B-C-B1); what moved is the claim that nothing is lost.
(b) Evidence: target §6.3; threat model §3.2, §3.3, T-SE3, R4; key-authority U8 (user decided secure boot "for all
builds"; the premise that it covers captured nodes is the design's, not the user's).
(c) Fix: delete the sentence in §6.3 that secure boot takes over; write the residual: "in every state, whoever holds
the HAT can use all three keys while holding it; slot 2 decrypts every bundle addressed to this node, past and
future, until the node is reported lost and rekeyed". If M1's narrowing is taken, this residual binds only the bench
chips and the production decision goes to #256; otherwise add it to §10 as a user question before any lock.

**M3. Q1 states only half of the cost of a lifetime QR: losing or damaging the label makes the unit unenrollable
forever.**
(a) Scenario. A fire crew's unit is factory-reset (reflash — the only reset, `reset` → E_UNSUPPORTED) after the label
has worn off or the paper copy is lost. Today `batman-provhelper qr` prints a fresh secret after reflash
(`main.go:600-626`; `254-stage1-impl.md:329`). With the chip, slot 5 is never-readable (§3) and a reflash does not
change it; no one but the label (and whoever kept a copy) knows it. The unit is "unenrolled but refusing enrolment"
for the rest of its life — R110's forbidden end state, and the exact outcome round-1 B C-M3 named for the replaced QR.
Removing rotation removed the rotation-specific trigger, not this one. The way out — the factory keeps every claim
secret — is a vendor-held lifetime credential per unit, which R65 / R69 require to be listed as an asset with custody
and destruction rules, and which §5 / §7.1 do not mention either way.
(b) Evidence: target §6.2, §10 Q1, §5 step 8 (records list has no claim secret, and no rule says it is not kept);
threat model R65, R69, R110, T-SE5; `main.go:600-626`.
(c) Fix: extend Q1 with "lose or deface the label → the unit can never be enrolled again" and a second, explicit
choice: "the factory keeps / does not keep the claim secret" with its custody rule if kept. Say where the label is
fixed (round-1 B C-m5 is still open).

**M4. Who runs the factory sequence, on what, and with which records is undefined; on the bench it creates a second
writer on the chip.**
(a) Scenario. Bench conversion (§7.4). The chip is on a HAT that is on node 02 or 04. §5 needs: a tool that writes and
locks config and data; a random claim secret (from where — the chip's RNG through the host, so the host sees it); the
dev-root signature of the slot-1 public key (the dev root is "on the developer's machine", §6.6, so the public key
must leave the node and a certificate come back); a printed QR; a record (§5 step 8 — kept where, by whom, for how
long). None of the who / where is stated. If the tool runs on the node, it is a second program opening the chip, and
C9 / K21 ("only helper") need an explicit exception: helper stopped and disabled for the duration, and a rule for
the I2C bus. Nothing says how the claim secret reaches the QR without passing through a log (today's rule: "stdout 不進
任何 log", `254-stage1-impl.md:215`), or whether the HAT can be provisioned on a jig before it is mounted.
(b) Evidence: target §5, §6.6, §7.1 ("出廠站" owns everything, but is not defined), C9; threat model L1, R69;
round-1 B C-M1 item 1 ("who runs it and on what host, what is recorded per unit and where") — reworded into §7.3
row "出廠中途失敗", not answered.
(c) Fix: one short subsection: phase-1 factory = a root CLI on the node with the helper stopped (or a jig Pi, say
which); claim secret from the chip RNG, shown once on the console, never logged; dev-root signing step (offline CSR
file in, certificate file out) and where the dev-root key is kept (R69: custody + destruction); per-unit record
contents and location (no claim secret unless M3 decides otherwise). Add the factory tool and the dev root to §7.1.

**M5. Where the slot-0 / slot-2 endorsements come from is still ambiguous (round-1 B C-M6 item 4 not closed), and the
answer decides whether strangers drive slot 1 at every handshake.**
(a) Scenario. §5 step 6 makes the endorsements at the factory; §4.2 says "驗證者的挑戰要經由亂數模式的 nonce 進入" (a
per-verifier, fresh endorsement); §9-1 puts "兩份背書（含晶片產生的亂數輸出）" in `node_cert`. If static: the factory's
endorsements must be stored somewhere that survives reflash (slot 8 is the certificate only, ≤416 B; the data
partition is lost at reflash — C6), or regenerated by the helper in the field, which means slot 1 is used on nodes
after all. If fresh: every NX handshake to an unclaimed node (anyone in BLE range) costs two internal signs plus one
external sign, i.e. three chip signatures per stranger — the per-connection chip cost round-1 B C-M6 item 5 asked to
avoid. The app's verifier differs in each case.
(b) Evidence: target §2, §4.2, §5 step 6, §9-1; `provd/server.go:337-357` (today `node_cert` is built once per helper
boot and sent in msg2 to every handshake, `:744`).
(c) Fix: choose one and say it. The simplest: endorsements are made once by the helper at first boot after each
reflash (or at the factory and re-made by the helper if missing), with a fixed NumIn, cached on the overlay as public
data; `node_cert` carries them; freshness comes only from the per-login slot-0 signature. Then slot 1 runs only in
that one place (and for the phase-2 counter proof), and the §4.2 sentence about the verifier's challenge is removed.

**M6. §2 still has a chip signature at every login, contrary to the v2 header and the change map; its cost is not
stated and K15's baseline lets it slip through.**
(a) Scenario. Header: the three rejected mechanisms, including "每次連線都由晶片簽章", "v2 把這三個都拿掉". §2: "節點在每次登入時，
以槽 0 簽這次交握的雜湊". The mechanism is defensible (it is what makes C3 hold against a copied card), but it is a
protocol change (a new message or field after msg2, since `h` is final only after msg2, which already carries
`node_cert`) that §9 does not list, and it adds wake + nonce + sign + I2C time to every login. The app logs in to each
node every 60 s in the foreground (`329-app-uiux.md:518, 882`); the user spent #329 on seconds of login time. K15
binds phase 1 (key-authority §3) but measures against "第 2 期開始前量測的基準" — a baseline taken after phase 1 would
absorb phase 1's regression. Round-1 B C-m8 ("one total per login") is not closed: no number appears anywhere.
(b) Evidence: target header, §2, §9, E14; key-authority K15 and "第 1 期也受約束"; `329-app-uiux.md:518`.
(c) Fix: correct the header and change map ("per-login slot-0 proof kept, for C3; per-connection endorsement
removed"); add the protocol change to §9; state the expected added time per login (from F§9 typicals) and make E14's
pass condition "≤ X ms added, measured against the v1.6 login time"; say that K15's baseline for phase 1 is v1.6.

**M7. The lifecycle matrix has no test column and misses the trial/commit interaction that v2's new
"identity-unavailable, not latched" state creates (round-1 B C-M1 reworded, not closed).**
(a) Scenarios.
1. **Trial commit on a silent chip.** Today an identity that does not load makes the helper "serve nothing" and never
   listen (`main.go:615-619`, `select{}` before `srv.Listen` at `:706`), so provd never connects, `provd-stable` is
   never written (`stable.go:3-5`) and autocommit never commits the trial (`batman-autocommit:500-512`) → automatic
   revert. §6.7 changes this: the helper must stay up and retry the chip at each login, so it listens, provd connects,
   `provd-stable` appears after 60 s and **a trial image whose chip driver is broken commits** and leaves the unit
   unmanageable on the committed slot — the outcome the A/B mechanism exists to prevent (R99, K13).
2. **OTA across backends.** "不支援從檔案身分原地升級" is a statement, not a mechanism. The bench harness OTAs routinely
   (the deployed role is "OTA only"); nothing refuses an `update/*` of a chip image onto a file-identity node or the
   reverse. What the chip image's helper does with an existing `backend=file` identity dir is not stated (use it →
   K20; ignore it → record mismatch → item 1).
3. **Downgrade.** The row cites `keystore.go:266-267` ("backend is not file → refuse"), which fires only if the chip
   image leaves an identity dir with `backend=se`. §9 does not say it does. Without one, the old image's boot table
   decides (`254-stage1-impl.md:198-210`; `boot.go:80-200`): rc 13 → `unknown(identity-lost)`, but rc 7 / 9 with no
   identity → **generates a software identity** on a chip unit (K20).
4. Rows required by REVIEW.md and missing: clean shutdown / reboot (chip asleep vs. mid-sequence), restart of the
   helper and of provd (today `node_cert` is rebuilt on helper boot_id change, `server.go:442-449`), crash loop
   (wake per start), restart of dependencies (I2C driver / overlay).
(b) Evidence: as cited; REVIEW.md item 3 (test column); round-1 B C-M1 fix ("columns chip state / node behaviour /
test"; rule 1 "a unit changes backend only by reflash … never by OTA").
(c) Fix: add the test column; add rule "in a trial slot, identity-unavailable fails the commit gate (helper writes
no `provd-stable` / a prov-state verdict that blocks commit)" with a kill test (trial image with the chip held → must
revert); make the chip image refuse a `backend=file` identity and the release tooling refuse an OTA that changes
backend (or state that the harness never does it, and how that is enforced); fix the downgrade row's mechanism.

**M8. K20 ("never a software identity") conflicts with §9-4's development file backend, and §9 is missing items a
working bring-up cannot do without.**
(a) Scenario 1 (K20). There is no production/development image split for identity today: one image per board, plus
the `prov_test` wbox variant (`feed/batman-prov/Makefile:27`). §7.3 relies on "量產映像沒有檔案身分後端"; for phase 1
(where every image is a development image) a file-backend development image flashed on a chip unit generates a
software identity on first boot (rc 7 → generate, `boot.go:186-200`) — two identities for one unit (threat model
L13) and a direct K20 breach. The development app would then accept two trust paths (self-signed `dev:` and dev-root
chip certificates), so no negative test of K16 / K20 can be shown in the development app. Round-1 B C-M2 asked for
"the file backend, if kept, uses the same wire format … under the development root"; not answered.
Scenario 2 (missing scope). Required for a working phase 1 and absent from §9:
- the boot reconciliation and persistence (`boot.go`, `254-stage1-impl.md` §4.2 rc table, `identity/prov/` on p5,
  `cfgsave-identity-*` tests), all built around an identity directory;
- a record ↔ chip binding (which identity a `prov.cbor` was made with) — needed for §6.7's "背書公鑰與資料分割區紀錄不符",
  and a new schema field that older images reject (`provstore.go:112-131` strict parse);
- the harness: 33 files under `scripts/dv`, `scripts/node`, `tests` read `identity/`, `claim.secret` or call
  `provhelper qr` (e.g. `prov-claim-254.sh:48-51`, `prov-p1-254.sh:39-66`, `prov-bench-s0-254.sh:448`). With slot 5
  unreadable every automated claim needs the secret from a host-side record; the "one validation set" rule means a
  harness PR lands on main first, before the converted nodes can run full validation;
- vectors and peer tools: `tests/vectors/219-protocol/*`, `tests/tools/peer/nodecert.py`, `tests/tools/provclient`,
  `219-protocol.md` §3.3 / §5.4 / §9 (round-1 B C-M6 item 6, partly dropped);
- the chip driver itself (cryptoauthlib is C; the helper is Go — cgo in the OpenWrt build or a Go I2C implementation)
  and the factory tool (M4);
- the per-login proof message (M6).
(b) Evidence: as cited; key-authority K20, §6 phase 1.
(c) Fix: simplest removal — **no flashable image has a file backend**; a software fake of the `Keystore` interface
lives only in host tests, under a test root that no app build trusts; the app's `dev:` TOFU path is removed in the
same phase. If a HAT-less node must still run the product, it is "identity unavailable", not a file identity. Then
add the six bullets above to §9, and say plainly that phase 1 is a protocol, app and harness revision.

### MINOR

- **m1. The experiment-chip list has no reader, and contradicts the lock tool.** §6.6: the lock tool accepts only §4's
  image; §8 E4 locks chip 1 with a variant config and "把它的序號列入「實驗晶片」清單". Nobody consumes the list. Replace
  both with one rule: the dev-root signer reads the full config zone and signs only if it equals §4's image (CRC);
  the variant chip is locked by the experiment tool, which never signs. Then no list exists.
- **m2. OTP "設定版本與批號" has no reader** (§7.2 lists none). Remove it; leave OTP as shipped; E5 goes away. The
  data-lock CRC covers whatever OTP holds.
- **m3. The chip serial is not needed in the QR.** CheckMac hashes only SN[8] and SN[0:1] (F§4, F§8), which are fixed
  per part family (`01 23 EE` expected on standard parts). `proto.go:53-70` needs those three bytes, read once from
  the chip (E1) and carried in `node_cert`. Remove the serial from §9-9.
- **m4. Counter order with respect to the proof.** §6.5 says "先加一、再提交紀錄" but not "only after the claim proof
  and the owner's signature have verified". Otherwise a stranger in BLE range steps the count with wrong secrets (rate
  limited, not prevented). Also state that a root-advanced counter cannot be repaired (R9) and shows a large number
  for life.
- **m5. No positive control for slot 0 external sign under ReqRandom = 1.** E7 lists "槽 1 外部簽章" (must fail) but not
  "slot 0, pass-through nonce, external sign → succeeds". If ReqRandom blocks it, slot 0 is useless for life. Make it
  the explicit control in E7 (F1 too).
- **m6. Helper behaviour for a partly provisioned chip** (config locked, data unlocked; or slot 0, 1, 2, 8 not locked)
  is not in §6.7 (round-1 B C-M1 rule 3). State: identity unavailable, never "report only".
- **m7. How the user learns the chip is dead.** §6.7's state is invisible from the app (logins fail as "no response"
  or "身分不符"). Add a public status flag so the user replaces the HAT instead of chasing Bluetooth (honest errors,
  #329).
- **m8. HAT replacement needs a reflash**, because the old record names the old identity and `reset` is unsupported;
  the row says only "要重新入庫". Say it, and where the label goes (round-1 B C-m5).
- **m9. Proof type in `node_cert`** (round-1 B C-m11, D7) is not in §9-1. Add one field so a later TPM / TA101 is a new
  type, not a format break.
- **m10. The reference verifier is two programs** (factory side and app Rust). Add it to §7.2 with shared vectors;
  state the domain separation between an endorsement message and a counter-proof message (E7 expects counter GenDig
  + internal sign to be refused as an endorsement, E11 expects it to verify as a counter proof).
- **m11. Boards of the bench nodes.** §7.4 converts "兩台"; §7.3 says Pi 3 is unsupported. State which boards 02 and
  04 are; if one is bcm2710, either it is in scope for phase 1 (bus and overlay check) or it stays without a chip,
  which M8 makes "identity unavailable".
- **m12. Chips locked in phase 1 are development units for life** (slot 8 locked with a dev-root certificate). Add to
  Q3 so the 7 remaining chips are not assumed to be production stock.
- **m13. Wake token on a shared bus.** The wake pulse is a transaction to address 0x00 (general call). The bench bus
  has an INA at 0x40 (batpower) and the planned board an INA226 pair and RV-3028 (`hat-v1-spec.md:95`). ⚠️ unverified
  whether any of them reacts to a general call; add it to E0.
- **m14. Permanent identity → phase-2 condition** (round-1 B C-m10): a claimed node never shows `node_cert` or its id
  to an unauthenticated peer. Today an unclaimed node sends `node_cert` in msg2 to any NX handshake
  (`server.go:744-747`) and `status/public` carries the last 4 characters of the id. Write the condition in §9 or the
  key-authority phase-2 list.
- **m15. CM4 row.** On an eMMC CM4 the data partition is on the module, so "CM4 dies" = "card dies". Say both.
- **m16. Citation.** `keystore.go:118-120` is the subject encoding; the id derivation is `:113-115` and `:206-207`.

---

## 2. Round-1 findings: closed or not

| Round-1 | State in v2 |
|---|---|
| A-B1 / B-C-M3 QR rotation | Closed by removal. The orphan outcome moved to the lifetime QR (M3) |
| A-B2 / B-C-B1 `ReqAuth` | Closed by removal. "Nothing lost, secure boot covers it" is new and unsupported (M2) |
| A-M1 verifier | Closed for message construction; endorsement provenance open (M5) |
| A-M2 experiments | Three chips and positive controls: closed. Slot-0 external-sign control missing (m5). Logistics (B-C-m4: which HAT, clip or solder, which node) still open |
| A-M3 ChipOptions | Closed |
| A-M4 / B-C-M7 counter | Mostly closed; proof-before-increment open (m4) |
| A-M5 / B-C-M1 ownership, contracts, lifecycle | Tables added; test column, trial-commit, OTA enforcement, factory definition open (M4, M7) |
| A-M6 C1 | Closed |
| B-C-M2 file backend | Production half closed; development half open and in conflict with K20 (M8) |
| B-C-M4 chip silent | Not-latched and Q2 closed; the new state's interaction with autocommit is new (M7-1) |
| B-C-M5 option for slots 3 / 6 | Closed by removal |
| B-C-M6 phase-1 scope | Items 1–3 closed; item 4 open (M5); item 5 reversed without saying so (M6); item 6 partly dropped (M8) |
| B-C-m5, m8, m10, m11 | Open (m8, M6, m14, m9) |

## 3. Wrong or unsupported statements

1. §6.3 "被擄節點的防護，改由 secure boot 加資料分割區加密負責" — contradicted by threat model §3.2 item 1 and §3.3 (M2).
2. Header / change map "每次連線都由晶片簽章 … 拿掉" vs §2 per-login slot-0 signature (M6).
3. §7.3 "量產映像沒有檔案身分後端" as the answer for today's units: no such image split exists (M8).
4. §7.3 downgrade row's mechanism (`keystore.go:266-267`) applies only if the chip image writes `backend=se` (M7-3).
5. §6.6 / §7.3 "量產晶片" — the production board design carries 608C-TFLXTLS (M1).
6. §6.7 "已在跑的網路照常運作" is true of the mesh but needs the helper to keep serving; today it serves nothing on an
   identity failure (`main.go:615-619`), so the statement describes new behaviour that §9-6 must implement (and M7-1
   must constrain).

## 4. Hex check (no finding)

Decoded with the 508A bit layout as used by the fact base: slots 0 / 1 / 2 `0x2081 / 0x2082 / 0x2084` = secret,
sign-external / sign-internal / ECDH-to-output, GenKey on, PrivWrite off; KeyConfig `0x0073` = Private, PubInfo, P-256,
Lockable, ReqRandom, no ReqAuth. Slot 5 and unused `0x8F9F / 0x001C` = WriteConfig Never, IsSecret, NoMac, unreadable,
non-ECC, not lockable. Slot 8 `0x0F0F / 0x003C` = write Always until slot lock, clear read, lockable. Byte 16 `0xC0`;
SlotLocked `0xFFFF`. These match §4.2's prose. ChipOptions bit 3 rests on round-1 A's reading; not re-derived.

## 5. Experiments E0–E3: may start now

They write nothing irreversible, and nothing in M1–M8 changes what they measure. Conditions:
1. User consent per node action (the document already requires it), and not while the other session's v1.6 run holds
   the node (take the harness lease or wait for its end).
2. State which HAT carries chip 1 and whether it is soldered or clipped; the variant chip stays on that HAT until
   desoldered (round-1 B C-m4).
3. E0 from source first (round-1 B C-m7 already found batpower only), then on the node: batpower's address with
   `uci -q get` (never `uci show`), the bus scan in read mode or limited to 0x60, and m13's general-call check.
4. The tool used for E1–E3 is built without the Lock opcode, so E3 is reversible by construction (a config write
   before lock can be rewritten). Negative control: the tool refuses a lock request.
5. E1: if the revision is not `00 00 60 03` (for example a 608C), stop — that is M1.

E4 and later (first lock, even of the sacrificial chip) wait for the revised document.

## 6. Options without a present use (the standing lesson)

Remove: the experiment-chip list (m1); OTP version/batch (m2); the chip serial in the QR (m3); the file backend in
flashable images and the app's `dev:` TOFU path (M8). Narrow: "production image" → "phase-1 bench image" (M1).
None of these removals moves a problem elsewhere; each takes away a resource that §7 would otherwise have to own.

## 7. Verdict

**REJECT** — 0 BLOCKER, 8 MAJOR, 16 MINOR. The chip configuration itself is sound for bench chips; what is not ready
is the claim that it is the production configuration (M1, M2), the costs put to the user (M3), the factory and
lifecycle contracts (M4, M5, M7), the per-login cost (M6) and the phase-1 scope (M8). Revise and send the whole
document to review again. E0–E3 may start now under §5.
