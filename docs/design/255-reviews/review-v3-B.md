# Review v3-B — field use, lifecycle, consistency

Reviewer B, independent, first read of this set. Base: worktree `C:/src/Batman-255`, main `4eba26d` + untracked
`docs/design/255-*`. Reviewed together: `255-key-authority.md` v3, `255-threat-model.md` v2, `255-608b-config.md` v1,
with `255-reviews/608b-facts.md` and `docs/design/REVIEW.md` (binding). Read-only: no device, no build, no commit.
Bit-level decoding of SlotConfig / KeyConfig is the other reviewer's; chip behaviour I rely on comes from
`608b-facts.md` (F§n) and is marked where I could not check it.

Markers: **[checked]** = I opened the source line; **[unverified]** = my inference, not checked on a chip or in a
datasheet.

Verdicts (detail at the end):

| Document | Verdict | BLOCKER | MAJOR | MINOR |
|---|---|---|---|---|
| `255-608b-config.md` v1 | **REJECT** (as authorisation to lock any chip; E1–E3 may run) | 1 | 7 | 11 |
| `255-key-authority.md` v3 | **APPROVE-WITH-CHANGES** | 0 | 5 | 7 |
| `255-threat-model.md` v2 | **APPROVE-WITH-CHANGES** | 0 | 1 | 7 |
| Overall | **REJECT** for "safe to build phase 1 on" until C-B1 and the config MAJORs are closed; direction approved | 1 | 13 | 25 |

Per REVIEW.md, open MAJORs mean the revised documents are reviewed again as a whole.

---

## Part 1 — `255-608b-config.md` (life of the chip and of the product around it)

### C-B1 (BLOCKER) `ReqAuth` on slots 0–2 with slot 3 left writable and unlocked turns any root-level access into permanent destruction of the chip, and Q2 does not tell the user

(a) Scenario. Units ship (or sit on the bench) after chip bring-up and before secure boot lands — the document's own
"state before secure boot, and of development units" (§5.3). Anything that can issue chip commands — a helper bug, a
root exploit, anyone who boots a modified card in the unit (state OFF), a repair shop — sends two commands: write 32
random bytes to slot 3, `Lock(slot 3)`. Neither needs authorisation (F§11, ⚠ E13). From then on no party can pass
the slot-3 comparison, so slots 0, 1, 2 (connection, identity, ECDH) never work again. The chip is soldered to the
radio HAT: the repair is a new HAT, a new identity, a new QR, a new enrolment. A remote root bug does this to every
reachable unit, not to one. Without `ReqAuth` the same attacker can destroy nothing permanent that matters: slots
0–2 and 8 are slot-locked, the claim slots need the current secret, the counter is display-only.
So the "option kept open" is paid for by removing the one property a locked chip otherwise has — that software cannot
kill it — for the whole period in which the option gives no protection (§5.3 says so itself: "等於沒有保護").

(b) Evidence. §3 note 2, §4.2 (`0x03F3`), §5.3, §5.5 bullet 2 ("這顆晶片報廢"). §5.5 justifies it with "威脅模型已把
『有 root 的人能破壞該台』列為無法避免（T-SE6）" — but T-SE6's residual is "it must stay per-node **and be repairable by
the organisation**" and R9 says "repairable by the organisation without the vendor"; R10 forbids a protocol-reachable
action destroying a chip key. A scrapped soldered chip meets neither. §8 Q2 states the cost to the user as
"每次用晶片多約 40–60 ms" and "HAT 與主板成對" only; the brick is not mentioned, nor that if the user later says "no
pairing" slot 3 stays open (the primitive stays forever) or must be locked to a public value. §4.2 itself calls this
"本設計最大的賭注". Also unknown: whether `ReqAuth` gates ECDH at all (F§2.2, E10) — if not, the option protects
signatures only and the decryption oracle (T-SE3) stays.
What the option would buy once enabled is bounded by the threat model's own §3.2: without binding, a holder who wires
the HAT elsewhere gets a relay / decryption oracle *for as long as they hold it*, which C3 (fresh proof) and a rekey
after the loss report already bound.

(c) Fix (remove): drop `ReqAuth` now — the document's own fallback `0x0073` — and keep slot 3 as a plain reserved
secret slot. Record "chip-to-board binding is not available on this chip configuration" as a decided residual. If the
author wants to keep it, the user question must be re-put with the real costs: permanent chip loss from any root-level
access until the lock, pairing afterwards, per-use time, and the unknown about ECDH; and the design must say what
state slot 3 is left in on a unit whose owner never enables pairing. Do not lock any chip on the current Q2 wording.

### C-M1 (MAJOR) There is no lifecycle matrix for the chip; several rows are undefined and two are unsafe as implied

REVIEW.md item 3 binds this document: the chip is the one resource here that survives reflash, OTA and revert.

(a) Scenarios the document leaves open:
1. **Factory sequence interrupted.** §5.1 gives the order (lock config → write initial values → lock data → GenKey
   1, 0, 2 → slot locks → endorsements → read slot-1 public key → manufacturer signature → slot 8 → lock slot 8).
   Not stated: who runs it and on what host, what is recorded per unit and where, and what each half-done chip looks
   like and what is done with it. Concretely: (i) config locked, data unlocked — a private key can be written in clear
   (§5.1, F§3): is a chip found in this state resumed or scrapped, and who can tell it was not injected meanwhile?
   (ii) key generated, slot not yet locked — the key can be regenerated by any bus master; if the public key was read
   before the lock, the certificate is for a key that may no longer exist; (iii) slot 8 written, not locked;
   (iv) label printed for a unit whose step failed (R69 label / unit mismatch). No rule says the helper refuses a
   chip whose slots 0–2 or data zone are not locked — §5.5 says a lock-state mismatch is "回報（不自動停用）".
2. **Trial boot / automatic revert.** Chip state written by a trial image is not reverted with the slot (threat model
   L8, R76, R99). `node/node.go:251-259` [checked] refuses the *verbs* in a trial, but nothing here says "no chip
   write, no slot lock, no counter step, no claim-slot rewrite while the slot is a trial" for boot-time code — and
   §5.3 / §5.4 plan exactly such writes (slot 3, slot 6) for a later release.
3. **OTA from the file backend to the chip backend, and its revert.** If a release converts a unit in place, the
   previous image refuses the identity: `keystore/keystore.go:266-267` [checked] "backend is not file … refuse".
   After an automatic revert the node cannot be logged in to — K13 / R99 broken by the release that introduces the
   chip. Key-authority §6 says "兩台節點換上" and nothing about how.
4. **Downgrade** of a chip unit to a pre-chip image (same refusal; is the mesh still up? not stated).
5. **Power loss** in each chip-writing flow: claim (counter vs record, see C-M7), claim-secret rotation (§5.2 covers
   it), the later slot-3 / slot-6 write-and-lock (not covered).
6. **Both boards.** Key-authority §6 puts chips on "兩台節點". State which boards are in scope and that the I2C bus
   number and overlay are the same on each.

(b) Evidence: the document has no matrix; §5.1, §5.5, §6; REVIEW.md item 3; `keystore/keystore.go:266-267`;
`node/node.go:251-259`; threat model L8, L12, L13, L15, L16.

(c) Fix: add one table — rows above, columns "chip state / node behaviour / test". Three rules do most of the work and
add no mechanism: (1) a unit changes backend only by reflash at the bench or factory, never by OTA; (2) nothing
writes or locks the chip while the slot is a trial; (3) the helper treats "data zone or any of slots 0, 1, 2, 8 not
locked" as identity-unavailable, not as a report.

### C-M2 (MAJOR) First boot of an official image on a chip unit can create a software identity; the fate of the file backend is undefined

(a) Scenario. The SD card of a fielded unit dies; the user flashes a new official image. Today's first boot generates
a file identity when the overlay has none (`254-stage1-impl.md:196`, `:288`, `:332` [checked]: "helper rc 7、overlay 無
identity → 產新身分"). How the new image knows it is on a chip unit is not stated. If it probes, a chip that does not
answer once at that boot (cold start, brown-out, bus held) yields a file identity on a chip unit — two identities for
one unit (threat model L13; R101 "in no case does it create or fall back to a software identity"). §6-3 only covers
the case where the helper already knows it is a chip unit.
Also undefined: whether the file backend continues to exist (bench units without a HAT, CI, emulator tests,
`tests/tools/peer`), and if so whether it speaks the old `node_cert` or the new three-key format. Two formats in the
app is a second trust path that must be dev-only and tested as such.
The same gap covers the two bench nodes being converted: their device ids change (`254-stage1-impl.md:215` "焊上 608B
= 新身分、新 QR、重新認領"), so the app's records (pinned DAC, owner keys per device id), the two-node network and the
harness's node records are all void; each node's `prov.cbor` still names the old owner. Nothing says: reflash both,
claim again, rebuild the network, re-seed the harness.
After a reflash on a chip unit, what is lost with the card is also unstated: "which claim slot is active" (§5.2 keeps
it on the data partition), the slot-3 value the helper uses before the lock, and the "factory record" that §5.5
compares lock states against (where does that record live?).

(b) Evidence: §6-3, §5.2, §5.5; `254-stage1-impl.md:196, 215, 288, 332`; `boot/boot.go:51-57`;
`keystore/keystore.go:68-69, 266-267`; threat model L13, L14, R101.

(c) Fix (narrow): state as §6 conditions — the backend is fixed per image build ("production images have no file
backend" is the simplest) or by a fact that survives reflash; a chip unit never generates identity files; the file
backend, if kept for development, uses the same wire format with software keys under the development root. Add the
bench conversion as an explicit procedure. Say what the node does after reflash for the active claim slot (try the
slot the QR names) and for the lock-state expectation (a constant in the image, not a per-unit record).

### C-M3 (MAJOR) QR replacement can leave a unit that nobody can ever enrol again, and under the decisions already taken it buys almost nothing

(a) Scenario (resale, user says yes to Q1). The buyer claims with the body QR, the app replaces the secret, the
printed QR is void. The new secret now exists only in the buyer's app (no cloud backup: threat model S15). The buyer
loses the phone or reinstalls the app — today's S2 / S12, where the answer is "reflash and claim again". With the
chip, a reflash does not reset the claim secret (C7). Nobody knows it: not the buyer, not the seller, not the vendor.
The unit can never be claimed again. Even while still logged in as owner, the buyer cannot set a new secret, because
the write needs the current one (§5.2). The same end state follows a rotation interrupted after step 3 on a unit
whose "active slot" pointer is then lost with the card.
Q1 tells the user the cost is "新的要由持有人自己保存". It is "lose it and the hardware is unusable for good" — worse
than today on S2 and S12, which K15 says must be put to the user.

What it protects against, given what is decided: a claim is possible only on an unclaimed unit; there is no reset
over the protocol (`provd/session.go:641-642` [checked]: `reset` → E_UNSUPPORTED) and no anti-theft lock (user
decision), so making an enrolled unit claimable again needs the unit in hand and a reflash — and whoever holds the
unit can read the body. The remaining case is "a previous holder kept a photo and gets the unit back in hand
briefly", which the enrolment count the user asked for is meant to expose. The dangerous use of a permanent QR is the
planned "QR + button replaces the owner, network kept" recovery (`219-field-provisioning.md:432`), which is a phase-2
problem (key-authority §5-3), not a chip-configuration one.

(b) Evidence: §5.2, §8 Q1, C5, C7; threat model S15, R65; key-authority S2, S12, K15.

(c) Fix (remove the flow, keep the chip option): keep slots 5 / 7 as configured if E9 passes — the capability costs
nothing while unused and cannot be added later. Take the replacement *flow* and the "active slot" pointer out of
phase 1; phase 1 uses slot 5 as the body QR and leaves slot 7 at an unknown random value. Move Q1 to phase 2 and ask
it with the orphan outcome stated. This also removes the app's "show the QR again" screen (a long-lived secret shown
routinely, R40) from phase 1.

### C-M4 (MAJOR) "Chip not answering → mesh keeps running, no login" is the right direction, but as written it can latch on one glitch, it is worse than today without a user decision, and it is applied to cases where it is not argued

(a) Scenarios.
1. Mid-incident the chip misses one wake (I2C glitch, brown-out on transmit, bus held by another device). §6-3:
   "helper 啟動後進入『身分不可用』狀態". Nothing says whether this is re-evaluated — per login, on a timer, or only at
   the next start. A state that latches the first failure for the rest of the boot is the #265 pattern named in
   REVIEW.md's own table. For a fire crew the difference is "one failed login, retry works" versus "this unit cannot
   be rekeyed, updated or have its phone Wi-Fi changed until someone power-cycles it".
2. A real chip death: the unit keeps relaying (consistent with the user's 2026-09 decision quoted in §5.8 — good),
   keeps its phone AP, and cannot be logged in to. At the next mesh password change it drops out (threat model R101
   residual). It can also never be updated except by reflash, because `update/*` needs an owner login
   (`provd/session.go:77-81` [checked]). Today there is no such dependency. K15 requires "差的地方要寫明並由使用者決定";
   there is no user question for it.
3. "換掉的晶片（背書公鑰與資料分割區的紀錄不符）同樣處理": for an *unclaimed* spare whose HAT was swapped in repair this
   leaves a unit with nothing to protect stuck until reflash; for a card moved into another unit it keeps a second
   unit on the mesh under a network record it never enrolled into. Both are defined as "same", neither is argued.

Is it the right call for a fire crew? Yes for a silent chip on a unit already in a network: availability of the mesh
outranks manageability of one unit, and the alternatives are a software identity (forbidden, R101) or taking a
healthy relay down (`254-stage1-impl.md:215` "helper 拒絕啟動"). It is consistent with K13 only if it never latches,
and with K15 only once the user has accepted the loss of management. It supersedes `254-stage1-impl.md:215` and the
refusal at `keystore/keystore.go:266-267`; both have to be amended in the same change, and threat model §8.1
question 29 closed.

(b) Evidence: §6-3; REVIEW.md "Why" table (#265); `provd/session.go:74-84`; key-authority K13, K15;
`254-stage1-impl.md:215`; threat model T-SE14, R101, §8.1-29.

(c) Fix: state the contract in three lines — the chip is probed again at every use (bounded retries inside the
watchdog budget) and the state is never stored; a mismatch on an unclaimed record adopts the chip, a mismatch on a
claimed or member record is identity-unavailable; add the user question "a unit whose chip dies keeps relaying but
cannot be managed or updated until its HAT is replaced — accept?". Add the case to key-authority §4 (see K-m6).

### C-M5 (MAJOR) The "option kept open" for slots 3 and 6 is not shown to be exercisable on units already in the field

(a) Scenario. Secure boot lands some releases after bring-up. The bench units, and any unit that left the bench in
between, have slot 3 unlocked and slot 6 empty. §5.3 describes the lock only as a factory step ("出廠時寫入亂數秘密、
同一份放進主板…然後把槽 3 鎖定"). For an existing unit somebody must: enable secure boot on that board (one-time
programmable; whether that can be done outside a factory jig is not examined here — [unverified], #115), write the
same secret to a board store that only signed code can read (location unknown, §9), write slot 3, verify, lock. All
irreversible, none authorised by the chip (any root can do it), all of it new image code that would first run in a
trial boot (C-M1 row 2). A power cut between the board write and the slot lock, or a partial one-time write, must
not end in "slot locked, value unknown" — C-B1's brick. And "all builds" includes development units: do they get a
development boot key, or stay unlocked for life?
If the honest answer is "only units still at the factory", then for every unit made before secure boot the option
does not exist, and those units carry C-B1's cost for nothing.

(b) Evidence: §5.3, §5.4, §9 ("主板端哪裡能放…"); threat model §3.0 ("mixed states are not analysed"), X12, A12.

(c) Fix: say which it is. Either "units provisioned before secure boot are never bound; they are development /
pre-production units and are replaced" (simplest, and with C-B1's fix nothing remains to decide), or give the field
procedure with its owner, its ordering (board store first, read back, then slot write, compare, lock; never in a
trial boot) and its kill-point test.

### C-M6 (MAJOR) The phase-1 scope implied by §2 / §6 is larger than "bring-up", and items needed for bring-up are missing

What §6 already implies (protocol change, device-id definition, QR content, helper as only I2C user, chip-absent
state) is realistic only if it is called what it is: a protocol and app revision. Missing from the list:

1. **Device certificate format, its signer, and the app's trust gate.** The app accepts only an X.509 DAC whose CN
   starts with `dev:` and is self-signed (`app/rust/batman-proto/src/nodecert.rs:146-156, 177-190` [checked];
   `x509_cert::Certificate` at `:19, :196`); a non-`dev:` DAC is `Untrusted` because no production root exists.
   `254-stage1-impl.md:215` expects "鏈長 2 → 製造商根驗證" (X.509). §3 slot 8 holds "原廠根對背書公鑰的簽章與相關欄位"
   with X509format = 0; key-authority D3 says "不引入 X.509"; `608b-facts.md` E15 rebuilds an X.509. Three formats in
   four documents. And nothing says who holds the development root key, on which machine, or how the development app
   build gets its public key. Without these a provisioned chip cannot be verified by any app build. The field build
   still rejects everything after phase 1 (no production root, #256) — say so.
2. **The claim proof changes.** The chip's CheckMac hashes its own hardware serial bytes SN[8], SN[0:1] (F§4, F§8:
   `EE` and `01 23` on standard parts). Today the proof uses the bytes of `sn = device_id`
   (`proto/proto.go:53-70`, `keystore/keystore.go:65-67` [checked]; `219-protocol.md:240-247`: "SN = node_cert 裡的
   608B 序號"). §2 redefines `device_id` as the hash of the endorsement key and says this "維持 app 今天…的檢查". It
   does for the id check — and it splits `sn` from `device_id` in the proof, in `node_cert` key 7 and in the QR.
   E8 "用我們實際的認領證明做比對" fails as written unless the test uses the chip's serial bytes.
3. **`node_cert` outside a handshake.** `verify_offline` (`nodecert.rs:158-170` [checked]) checks a `node_cert`
   embedded in a join request with no session. A per-connection proof cannot apply there; the endorsements can.
   Say whether these development-only flows are updated, frozen or dropped (key-authority Q5 proposes dropping them
   in phase 2 — then phase 1 breaks them first).
4. **Where the endorsements of slots 0 and 2 live** and who produces them: once at the factory (then stored where —
   the data partition is lost at reflash; slots 10–13 are 72 bytes) or by the helper on demand (then slot 1 is used
   in the field at boot, with its own authorisation and timing).
5. **Unauthenticated callers now trigger chip work.** Today the identity key signs twice per boot by design
   (`219-protocol.md:78` [checked]: "608B 每次開機只簽兩次…手機另做一次新鮮的 `peers/challenge`";
   `provd/server.go:337-351`). §6-1 moves a chip signature of up to 115 ms (plus 40 ms authorisation if C-B1 stands)
   into every connection, including anonymous ones from anyone in BLE range (threat model T-ND4, R47). The existing
   fresh-proof verb (`sign.peer`, `node/node.go:412-429` [checked]; `peers/challenge`, E_UNSUPPORTED today at
   `provd/session.go:68-69`) already signs `nonce_app ‖ nonce_node ‖ h`. Requiring that proof before any trust
   decision meets C3 / R1 without a chip operation per stranger. §6-1 should state the property and leave the choice
   to the implementation design; as written it prescribes the costlier mechanism.
6. Documents and vectors to change in the same phase: `219-protocol.md` §3.3, §5.4, §9; `254-stage1-impl.md:215`;
   `tests/tools/peer/nodecert.py`; the harness's node records.

(b) Evidence: as cited per item.
(c) Fix: add these as §6 conditions (one line each), and name the phase honestly in key-authority §6
("打通 608B + 協定 / app 的身分改版").

### C-M7 (MAJOR) The enrolment counter can under-count without root, and its ordering against the record is not stated

(a) Scenario. C6: "答案不能被節點上的軟體造假". §5.6 only says a failed increment must not block enrolment. If the
increment follows the record commit, someone with the unit and the QR claims it, cuts power after the commit and
before the increment, uses it, reflashes: the next buyer sees a count that hides that enrolment — no root needed.
If the increment precedes the commit, a power cut over-counts, which errs in the harmless direction. The document
does not choose. Also unstated: that the signed read carries the phone's nonce (otherwise an old, lower count is
replayed), whether an unauthenticated session may ask for it (the buyer wants it before enrolling; that is another
chip sequence a stranger can trigger), and that a power loss can step the counter by more than one (F§7).

(b) Evidence: §5.6; threat model L15, R76, R110; F§7.
(c) Fix: one sentence each — increment first, then commit; UI wording "at most N enrolments"; the proof covers a
phone nonce; who may request it.

### Config MINOR

- **C-m1** §5.5 bullet 1 is wrong as stated: "槽 3 被鎖成攻擊者知道的值 → …攻擊者與我們都能授權". We can authorise only if
  *we* know the value. A value only the attacker knows is the brick of bullet 2. Bullet 1 holds only for our own
  code locking the value it currently uses.
- **C-m2** Experiment order: with `ReqAuth`, GenKey itself needs a prior slot-3 authorisation (F§2.2: "GenKey …
  checks for usage authorization even when generating a new key"). E7 does not mention it, and E-A (which writes
  slot 3) is listed after E13. As written E7 fails for a reason unrelated to what it tests.
- **C-m3** The combination the design depends on is not an experiment: authorise → GenKey(digest) of slot 0 (which
  consumes the authorisation) → authorise again → Sign(internal) with slot 1. Whether the second comparison leaves
  the digest in TempKey intact is not in the fact base ([unverified] either way). Same for the signed counter read
  (E11). Add it to E-A; if it fails, that is one more reason for C-B1's fix.
- **C-m4** Chip budget and logistics: every "停" outcome sends the design back to review, and a changed
  configuration needs two fresh sacrificial chips; 10 chips allow three such rounds before only the two bench chips
  and two spares remain. The chips are SOIC parts on HAT pads and §7 runs on "節點現有的 I2C 介面": each sacrificial
  chip occupies one of four HATs until it is desoldered. State the plan (clip / socket, or which HATs).
- **C-m5** The QR label belongs to the chip and the chip to the HAT. Say where the label is fixed so that a HAT swap
  in repair cannot leave an old label on a unit (R69).
- **C-m6** Spare key slots 4 and 9 (regenerable, unlocked) have no user in any phase and no authority rule for
  rotating to them, and the app's endorsement check ("locked") would reject them. Keep the bits (they must be chosen
  now) but say "nothing uses them; the app accepts endorsements for slots 0 and 2 only". Same for slot 14.
- **C-m7** §6-2 "現況誰在讀 I2C 還沒對程式" — checked: `feed/batman-provision/files/usr/bin/batpower:44-45, 59-61`
  (root, `i2cget` on bus 1, address from uci, default 0x40; source default `none` per
  `feed/batman-provision/files/etc/init.d/batpower:11, 20-21`). No other I2C user under `feed/`. The address is a
  uci value: a setting of 0x60 would point `i2cget` at the chip — exclude that address in batpower.
- **C-m8** Cost per login is given in pieces (115 ms in §2, 40–60 ms in Q2). Give one total per login and per
  `net.apply` (wake + authorisation + sign or ECDH + bus time at 100 kHz), and make E14 measure exactly those.
- **C-m9** Appendix A items not answered: 12 (key disable for decommissioning — say "not used"); 9 (one CA or
  per-batch intermediates, and what fits in 416 bytes); 17 (say explicitly that no host-usable value derived from
  the claim secret exists); 16 (say counter 0 is "left unattached", the wording the threat model asks for).
- **C-m10** The identity key is permanent for the life of the chip (slot 1 locked). R66 ("changes or disables
  whatever in the chip would let the previous holder be recognised") and K9 / R94 are therefore not met by the chip;
  they must be met by the protocol not showing the identity to an unauthenticated peer. State this as a condition
  on phase 2 so that it is not discovered later.
- **C-m11** App-side verification of the endorsement checks 608-specific message layouts and config bits (§6-1). That
  ties the phone to the chip family, against D7's wording. Carry a "proof type" in `node_cert` so that a later TA101
  is a new type, not a format break.

---

## Part 2 — `255-key-authority.md` v3 (the rule set)

### Rule by rule

"Testable" = a later reviewer can tick it with a negative test as written. The R-numbers are my mapping; the
document gives none.

| Rule | Threat-model requirement | Testable as written? | Note |
|---|---|---|---|
| K1 | R81, R55 (T-OR10a) | Yes | — |
| K2 | R81 | First half yes | "層數固定" is a mechanism; threat model §11 lists "the shape and depth of a chain" as a design choice and says v1-R2 was deliberately reduced to R81 |
| K3 | R82 | Yes | — |
| K4 | R90 (R51, R58) | Yes | — |
| K5 | R83 | Yes | — |
| K6 | R85, R86 (R23) | Yes | — |
| K7 | R91, R114 | Ambiguous | "建立它的那個授權者" read as a person contradicts D2, S5 and R107 (a second administrator takes over); read as the trust anchor it is fine. See K-M3 |
| K8 | R35, R92 (R29) | **No** | "任何情況下都有辦法…辦不到時寫明代價" cannot be failed by any design. See K-M1 |
| K9 | R94; R53, R54 | First half yes | The second half has no bound ("長期") |
| K10 | R43, R106 | Yes | The mesh password already does not cross provd today (threat model S26); the rule is about not regressing and about new secrets |
| K11 | R105 | Yes | In tension with K8 / R107 and K15: see K-M1 |
| K12 | R88, R44 | Yes | "在 helper 內" names a component; the property is R88 / R44. Acceptable, the split exists |
| K13 | R99; R71, R77 | First half yes; second half **no** | "任何升級或回退路徑" includes physical downgrade, which the threat model lists as a residual no design removes (§10-14, L9) |
| K14 | R100, R116 | Yes | — |
| K15 | R112, R109, R111 (U2) | **No** | No baseline numbers; "today" is not measured anywhere |
| K16 | R3 (R2) | Yes (config E7) | — |
| K17 | R49, R59, R34, R45 | Yes | — |

No rule is a mechanism in disguise apart from the second half of K2 and, mildly, K12.

### K-M1 (MAJOR) Three rules cannot be ticked, and the rule table carries no R-numbers although the text says each rule maps to one

(a) Scenario. Phase 2 presents a design in which a stolen administrator key burns a network's version to the maximum
(threat model T-MS6). The author writes "cost: rebuild in person" and K8 is satisfied by its own escape clause; a
reviewer cannot object. Same for K15 (no measured "today") and the second half of K13 (unachievable, so every design
fails it and it gets waived by habit). And K8 + K10 + K11 + K15 pull against each other on exactly §5 item 2 (how a
second administrator gets the current secret): every known answer breaks one of them. The document does not say
which gives way.
(b) Evidence: §3 header line "每條對應威脅模型的需求" versus the 來源 column (review ids only); K8, K13, K15 text;
threat model R92, R35, §10-13, §10-14, Appendix B2.
(c) Fix (wording only): add the R column (table above). K8 → R92's property: "nobody below the trust anchor can put
a network or a node into a state the trust anchor cannot recover offline and without a physical visit; exceptions
are listed as residual risks and accepted by the user". K13 second half → "through the update path" (physical
downgrade is residual §10-14). K15 → "measured against a baseline recorded before phase 2 starts", naming the three
numbers. Add one line of precedence: where rules conflict, K1–K14, K16 and K17 win over K15, and the loss is a user
decision (this is U2).

### K-M2 (MAJOR) "K16 applies to phase 1, the rest from phase 2" exempts phase 1 from the rules it most obviously touches

(a) Scenario. Phase 1 changes the handshake, the device id, the QR and the login time, and adds a state in which a
unit cannot be managed (C-M4), an upgrade the previous image cannot read (C-M1 row 3) and irreversible chip writes.
By the sentence under the table, none of K13 (revert keeps login), K14 (default deny, exceptions listed) or K15 (not
worse, or the user decides) binds it. The requirements that are irreversible in phase 1 and have no K at all: R1 / R2
(fresh node proof — only in the config's C3), R101 (never a fallback identity), R102 (only the helper reaches the
chip), R76 / R110 (chip and record consistent across power cut and revert), R14 / R15.
(b) Evidence: §3 last line; config §2, §6; threat model Appendix A.
(c) Fix: replace the sentence with "phase 1 must meet K13, K14, K15, K16 and the config document's C1–C11; C1–C11
are rules of the same standing". No new rule text is needed.

### K-M3 (MAJOR) The words the rules are written in are not defined

(a) Scenario. A phase-2 designer reads K7 "網路只能被建立它的那個授權者更新" as "the administrator who created it" and
designs a closed administrator set — review v1-B's B2 again. Another reads K3's "發證站" and K2's "發證者" as the same
thing. The config document says 認領 for the secret and 入庫 for the counter of the same event; the code says
`ClaimedCounter`.
(b) Evidence: K2, K3, K7, K8 ("授權者", "發證者", "發證站", "信任錨"); config §3, §5.6; `node/node.go:592`.
(c) Fix: a six-line glossary in §1 — 信任錨, 授權者 (the trust anchor and what it delegated, never a person),
發證者 / 發證站, 管理員, 擁有者, 入庫 (= 認領 in the family deployment). Delete "層數固定" from K2.

### K-M4 (MAJOR) Requirements that later phases cannot cheaply retrofit and that have neither a rule nor a §5 problem

1. **The top-ranked threat.** One administrator signature replaces the administrator set (threat model rank 1,
   T-PH1 / T-PH2, R33; `node/node.go:1192, 1227` [checked]). K8 speaks of taking a network *back*; nothing says a
   single administrator must not be able to take it. §5 item 5 covers concurrent honest edits only.
2. **Two authority models on one node.** Review v1-B B3, threat model §8.1 question 30, R70, R71, L2: between the
   first release with the new model and the last with the old, exactly one governs a node. No rule, no problem
   entry. Cheap now (no external deployment, §2 item 12), expensive after the first customer.
3. **Possession of one node gives nothing over another** (R12; threat model §3.2 property ii). K1 / K2 imply it for
   credentials, not for what is stored on the card.
4. **Field operation without the station, with a bounded field credential** (R30, R31; T-OR9, "the centre of the
   design"). Present only as Q2 / Q4, which ask two special cases.
5. **Fresh node proof** (R1) and **never a fallback identity** (R101) — see K-M2.
6. R65 (no vendor-held capability over an enrolled node): relevant now because phase 1 creates a manufacturer root.

(b) Evidence: as cited; key-authority §3, §5.
(c) Fix: items 1, 2, 4 as §5 problems (one line each — they are problems, not rules); items 3, 5, 6 as one line each
in §3 or by reference to the R-number. No mechanism.

### K-M5 (MAJOR, cross-document) The secure-boot decision is not reflected, and no document says whether anything ships before it lands

(a) Scenario. The user has decided secure boot ON for all builds (threat model header; config C9, §5.3).
Key-authority §7 Q1 still asks the user that question and says the answer affects "晶片要不要啟用匯流排加密", which the
config document has meanwhile settled differently (keep both possible). The decision table U1–U7 lacks it, and lacks
"no anti-theft lock for now" and "the app shows the enrolment count" (both in the threat model header and config
C6). The phase table in §6 has no row or dependency for secure boot (#115 / #47 / #111), so nothing says whether the
phase-2 "家庭部署" — which ends in a red-team test — is designed for, tested in, or shipped in state OFF. The threat
model header says state OFF is "not a shipping product state"; if that is the rule, phase 2 cannot ship before
secure boot and the phase table should say so; if it is not, state OFF is a shipping state and §10-1 applies to
customers.
(b) Evidence: key-authority §1, §6, §7 Q1; threat model lines 19–23; config C9.
(c) Fix: move Q1 to U8 (decided), add U9 / U10, and add "secure boot + data-partition encryption" as a line in §6
with the statement of which phases may ship without it.

### Key-authority MINOR

- **K-m1** D3 "不引入 X.509" contradicts the source: the node certificate is X.509 today
  (`keystore/keystore.go:105-135` [checked], `x509.CreateCertificate`; `nodecert.rs:19, 196`) and
  `254-stage1-impl.md:215` plans an X.509 chain to a manufacturer root. Reword to "authority objects are COSE / CBOR;
  the device certificate format is decided in phase 1" (C-M6 item 1).
- **K-m2** §2 item 2 "須為硬體、不可匯出": the development build — the only one that can claim today — accepts a
  SOFTWARE `owner_enc` key (`keystore/KeyPolicy.kt:63-65`; `KeyPolicyTest.kt:50-57` [checked]). The threat model's
  S14 has it right.
- **K-m3** §2 item 10 can be marked verified against code: every non-HaLow AP is put on network `ahwlan`
  (`feed/batman-provision/files/usr/bin/meshpoint-1.8.0:66-70`), the bridge's ports are the Ethernet device and
  `bat0` (`:85, :111-113`), the helper requires the phone AP to be a port of `br-ahwlan`
  (`feed/batman-prov/src/cmd/batman-provhelper/bulk.go:19, 122`), and port 8095 is filtered on that bridge
  (`feed/batman-prov/files/batman-http.nft:24`). This is the configured layout in the source, not a capture from a
  node; the Ethernet port is added only when the board has one.
- **K-m4** Q1–Q6 here and Q1–Q3 in the config document collide. Prefix them or number through.
- **K-m5** D7 (interface not tied to 608B commands) holds for the helper; the phone necessarily verifies a
  chip-specific proof (C-m11). Say so.
- **K-m6** §4 has no hardware-failure scenario although phase 1 creates them: chip silent mid-incident, HAT replaced,
  SD card replaced with an official image, board replaced, resale. Add them with today's answer ("reflash, claim
  again" in each case) so that K15 has a baseline for them.
- **K-m7** D1 "家庭：信任錨…等於今天的擁有者金鑰": today the owner key authorises entering a network and a separate
  admin key signs updates (`Keys.kt:89`; `node/node.go:774-787, 1192`). Harmless, but the sentence should not be read
  as "one key today".

Nothing in D1–D7 or §6, other than D3 and the secure-boot omission, is contradicted by the source or by the threat
model. All other §2 citations I opened are correct (items 1, 3, 4, 5, 6, 7, 8, 9, 11).

---

## Part 3 — `255-threat-model.md` v2 (as a working document)

Usable: a designer can go from a flow (§5.6) or a lifecycle path (§5.7) to requirements, and Appendix A / B give the
chip designer and the phase-2 designer their subsets. The actors of REVIEW.md item 5 are all covered (mapping at the
end of §4: X1 / X5 / X15, X19, X20, X2 / X3, X11 / X16, X12) and each has at least one threat.

### T-M1 (MAJOR) The two platform states are no longer applied consistently, and the period this set is actually about is not one of them

(a) Scenario. The chip designer reads Appendix A item 19 ("in state ON this is the difference…") and the header
("secure boot ON for all builds") and concludes that binding is worth its cost; the bring-up, the bench units and
everything until #115 / #47 / #111 land are in state OFF with a chip, where the same item says it "buys nothing" —
and where the cost (C-B1) is fully present. Places that still treat the state as an open product choice or silently
assume one:
1. §3.0 "Whether a given SKU ships with it is a product decision that this document does not make"; §8.1 question 8
   "decide per product, and separately for platform state ON"; S22 — superseded by the header.
2. §3.0 "mixed states are not analysed": the two halves are separate issues and will land at different times, so
   the mixed states are exactly what the fleet passes through. Config §5.4 depends on both halves.
3. State ON is defined as secure boot + encrypted *data partition*. The writable overlay holds init scripts and
   configuration (B8 lists it); if the overlay is not covered by the encryption and by the verified chain, a card
   reader gives code execution on an ON node and S1-ON is false [unverified — #111 has no design]. State the
   assumption.
4. There is no statement of which requirements phase 1 can claim in state OFF with a chip (R2, R3, R5, R14, R84 by
   chip configuration; R102 against non-root only) and which it cannot (R4 against a holder; anything resting on
   item 19).
5. §10-1 and several "state OFF" residuals now describe "development and pre-secure-boot units"; say whether any
   such unit reaches a customer (K-M5).
(b) Evidence: lines 19–23, §3.0, §3.1 S22, §3.3, §8.1-8, §10, Appendix A items 10 and 19.
(c) Fix: a short "state in each phase" table (phase 1 = OFF + chip; then mixed; then ON) and delete the three
"product choice" sentences. No new analysis is needed for ON; the mixed state needs two lines.

### Threat-model MINOR

- **T-m1** Stale citation, twice: §3.0 and S22 cite `docs/design/255-key-authority.md:248` and quote "Pi 3 目前不支援".
  v3 of that file has 145 lines and no such sentence. Cite the user decision, not the replaced document.
- **T-m2** Header: "Fixed versus replaceable body-QR secret is decided in `255-608b-config.md`" — it is an open
  user question there (§8 Q1).
- **T-m3** §8.1 question 29 and T-SE14 say two documents disagree about a silent chip; config §6-3 now decides it.
  §10-11 still carries the [A] marker the header says is superseded. Close both in place.
- **T-m4** Appendix A: "Requirements with a negative test marked SE (must be run on a real locked chip before the
  batch is locked): R2, R3, R5, R9, R14, R84, R101, R102, R110". R84, R101, R102 and R110 need node and app software
  that does not exist when the bench chips are locked (config §7). Split into "gates the lock" (chip-only: R2, R3,
  R5, R9, R14) and "gates shipping".
- **T-m5** T-SE6 / R9 cover counters and regenerable keys; they do not name the case the config creates — a
  deferred, unauthenticated write-and-lock that disables locked keys (C-B1). Add it to T-SE6 so the requirement
  reads on it directly.
- **T-m6** No threat or requirement for "an unauthenticated peer makes the node spend chip time" (per-connection
  signature, counter proof). R47 is about sessions; extend it or T-ND4 by one clause.
- **T-m7** The 117 requirements have no index by phase. One column in §9 ("phase 1 / 2 / 3 / ICS") would let each
  later design list what binds it; it also gives key-authority §3 its R-numbers.

### [V] citations checked

All of the following match the source at the cited lines: `release/release.go:57-58`; `keystore/keystore.go:1-5`,
`:42-46`, `:60-61`, `:68-69`, `:78-98`, `:266-267`; `node/node.go:251-259`, `:587, 609`, `:592`, `:672`,
`:778-787`, `:832-838`, `:954, 983-984`, `:966-995`, `:1057`, `:1106-1113`, `:1169-1171`, `:1192, 1227`,
`:1200-1202`, `:1214`; `provd/session.go:60-65`, `:71-73`, `:82`, `:641-642`; `provd/noise.go:20-21, 38-39, 74-76`;
`provstore/provstore.go:10, 59-61, 66, 112-131, 147, 181`; `boot/boot.go:270-271`; `sock/sock.go:2, 189`;
`rekey.rs:102-103`; `joinflow.rs:157`; `Keys.kt:79-98`; `AndroidManifest.xml:29-30`; `KeyPolicyTest.kt:50-53`;
`batman-provd.init:34-36, 39`; `feed/batman-prov/Makefile:40`; `batpower:44-45`;
`batman-autocommit:621-622, 629-631`. **No wrong [V] found.** The only bad references are the two [D] citations in
T-m1.

---

## Part 4 — Consistency across the three documents

| Item | Key-authority v3 | Threat model v2 | 608B config v1 |
|---|---|---|---|
| Secure boot for all builds | still asked (Q1) | decided (header), but the body treats it as a product choice | decided (C9) |
| No anti-theft lock; show the enrolment count | absent | header | C6 |
| Body QR fixed or replaceable | not mentioned | "decided in the config doc" | open (Q1) |
| Silent chip | no rule, no scenario | "two documents disagree" (§8.1-29) | decided (§6-3), supersedes 254 |
| Device id | "the phase-1 design will handle it" | S29, T-SE13, item 18 | decided (§2), overrides 219 §3.3 |
| Device certificate format | "no X.509" (D3) | "compressed certificate" as an option (item 9) | raw signature in slot 8; the fact base rebuilds an X.509 |
| Chip-to-board binding | not asked | item 19: decide now | asked as Q2 with partial cost |
| Question numbering | Q1–Q6 | — | Q1–Q3 (collide) |
| Enrol / claim wording | 入庫 | enrol / claim | 認領秘密, 入庫次數 |
| Factory process and its secrets | phase 1 includes "出廠燒錄與 QR" | L1, R69, A4 | out of scope, "#256"; #256 is in no phase table |
| Which rules bind phase 1 | K16 only | Appendix A: 19 items, 9 SE tests | cites K16, R14, R15, R102 |

User questions asked twice: none exactly; secure boot is asked after being answered. Not asked at all: accept a unit
that cannot be managed when its chip dies (C-M4); accept permanent chip loss from root access as the price of the
binding option (C-B1); accept that losing a replaced QR orphans the unit (C-M3); whether units made before secure
boot may reach a customer (K-M5).

---

## Part 5 — Process: the pattern of the two rejected rounds

v3 itself does not repeat it: it removed mechanisms, and what is left is rules and problems (two wording slips: K2
"層數固定", K12 "在 helper 內"). The chip configuration does repeat it in three places — each a mechanism added to
answer a threat that the decisions already taken, or something that already exists, already bound:

| New mechanism | Need it answers | Simplest removal |
|---|---|---|
| `ReqAuth` + slot 3 (binding option) | T-SE1…6 from another host in state ON | Remove `ReqAuth` (C-B1). The residual is bounded by custody time (threat model §3.2) |
| Two claim slots with an "active slot" pointer, four-step replacement, app re-display | T-SE5 permanent QR | Keep the slot bits, build no flow in phase 1 (C-M3) |
| A chip signature for every connection | T-SE1 / R1 | Require the existing `peers/challenge` proof before trust (C-M6 item 5) |

Options that are fine to keep because they cannot be added after the lock and cost nothing while unused: slot 6 with
ECDHPROT = 0, reserved slots 10–14, spare key slots 4 / 9 (with C-m6's sentence).

---

## Wrong or unsupported facts (collected)

1. Config §5.5 bullet 1: a slot 3 locked to a value only the attacker knows does not leave the keys usable by us
   (C-m1).
2. Config §5.5 citing T-SE6 as covering a scrapped chip: T-SE6 / R9 require repairability by the organisation (C-B1).
3. Config §2: the device-id redefinition "維持 app 今天…的檢查" — true for the id check, but it changes the claim proof
   and `node_cert` key 7, which the document does not list (C-M6 item 2). `219-protocol.md:240-247`,
   `proto/proto.go:53-70`.
4. Config Q2 cost statement incomplete (C-B1); Q1 cost statement incomplete (C-M3).
5. Key-authority D3 "不引入 X.509": the device certificate is X.509 today (K-m1).
6. Key-authority §2 item 2: a software `owner_enc` key is accepted in the development build (K-m2).
7. Key-authority §3: "每條對應威脅模型的需求" — no R-number is given for any rule (K-M1).
8. Key-authority §7 Q1 asks a question the user has answered (K-M5).
9. Threat model §3.0 and S22 cite `255-key-authority.md:248`, which does not exist in v3 (T-m1).
10. Threat model header: the QR question "is decided in" the config document — it is not (T-m2).
11. Unsupported in the fact base and relied on by the design: TempKey surviving a second authorisation between
    GenKey(digest) and Sign(internal) (C-m3); `ReqAuth` gating ECDH (acknowledged, E10); a place on the board only
    signed code can read (acknowledged, #115); that secure boot can be enabled on a unit outside the factory (C-M5).

Verified by this review and usable by the author: key-authority §2 item 10 (K-m3); the list of I2C users (C-m7).

Not done by this review: nothing was run on a chip or a node; chip behaviour is taken from `608b-facts.md`; the
[D ICS …] statements and issues #115 / #111 / #256 were not opened; attack trees (§6) and the likelihood scores (§7)
of the threat model were read only in part.

---

## Verdicts

- **`255-608b-config.md` v1 — REJECT.** One BLOCKER (C-B1) and seven MAJORs (C-M1 … C-M7). The core of the slot plan
  — three keys, internal-only endorsement, comparison-only claim slot, generate after the data lock — is sound from
  the life-cycle side and should be kept. What must change before any chip is locked: the `ReqAuth` decision put to
  the user with its real cost (or removed), a lifecycle table with the three rules in C-M1, the backend / first-boot
  conditions, the chip-silent contract, and the scope list. E1–E3 are read-only or reversible and can run now, on
  the user's go-ahead for touching the bench node; E4 onward waits for the re-review.
- **`255-key-authority.md` v3 — APPROVE-WITH-CHANGES.** Direction D1–D7 and the decision to hold only rules are
  right. Five MAJORs, all wording, mapping or omissions (K-M1 … K-M5); none asks for a mechanism.
- **`255-threat-model.md` v2 — APPROVE-WITH-CHANGES.** Citations hold; actor coverage is complete; one MAJOR (T-M1,
  platform states) and index / staleness fixes.
- **Overall — REJECT** as the basis for the irreversible part of phase 1; the direction and the rule set are
  approved subject to the listed changes. Totals: 1 BLOCKER, 13 MAJOR, 25 MINOR.
