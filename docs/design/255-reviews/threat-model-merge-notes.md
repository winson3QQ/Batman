# Merge notes — `255-threat-model.md` v2

What was merged: base = `threat-model-independent.md` (blind, English, R1–R80); mined = the author's v1 of
`255-threat-model.md` (Traditional Chinese, R1–R21, replaced by the merge) and the four reviews
`review-v1-A.md`, `review-v1-B.md`, `review-v2-A.md`, `review-v2-B.md`. Reference only: `docs/design/REVIEW.md`,
`docs/threat-model.md` (not changed).

Worktree `C:/src/Batman-255`, main `4eba26d`. Nothing was run on a device, built, committed or pushed. Only two
files were written: `docs/design/255-threat-model.md` and this file.

Counts: requirements 80 -> 117 (R81–R117 new). Assumptions S1–S21 -> S31. Actors X1–X17 -> X21. Assets A1–A11 ->
A13. Boundaries B1–B14 -> B16. Threats: +4 T-SE, +5 T-OR, +3 T-PH, +3 T-ND, +5 T-MS. Flows F1–F12 -> F15.
Lifecycle L1–L12 -> L16. §8.1 questions 25 -> 34. §8.2 items 14 -> 19. Residual risks 10 -> 15. New sections: §3.0,
§3.2, §3.3, "AT additions", §11, Appendix A, Appendix B. No base identifier was renumbered.

The author's v1 used R1–R21 for other requirements; they are written v1-R1 … v1-R21 here and in the document.

## 1. What was added to the base, and from which source

### 1.1 Requirements

| New | One-line title | Source |
|---|---|---|
| R81 | Delegated authority cannot be re-delegated; a node's key confers nothing | author v1-R2; v1-A B2; v1-B M4 |
| R82 | Root-equivalent rights on a node only from that node's top authority, node-named | author v1-R3; v1-A M6 |
| R83 | Signed objects bound to kind / organisation / network / node / signer | author v1-R4; v1-A m1; v2-A m8 |
| R84 | Node credential only for a key freshly proven to be in the chip in custody | author v1-R5; v2-A m10; v2-B M1 |
| R85 | Revoked credential refused on a fresh or reset-and-re-enrolled node | author v1-R6; v1-A M1 |
| R86 | Revocation minimum not settable by the revoked party, not poisonable | v2-A B1 |
| R87 | Revocation state bounded, sized, defined behaviour at the bound | author v1-R7; v1-A M1; v2-B M10 |
| R88 | No reuse of an earlier "verified" result | author v1-R8 |
| R89 | Defined effect of revocation on applied state and in-flight objects | v1-B M2 |
| R90 | A replayable object only updates what the node holds; never enters, never survives leave / reset | author v1-R9; v1-A B3, M3; v1-B B1; v2-B m6 |
| R91 | A network is bound to its authority; a secondary authority is capped | author v1-R11; v1-A M3, M4; v2-A M7 |
| R92 | No unrecoverable version state, no stranding, no automatic spread | author v1-R12 (corrected); v1-A M2; v1-B M1; v2-A M3; v2-B M5(b) |
| R93 | Concurrent edits never re-admit a removed party; the loser is told | v1-B m6; v2-B M5(a) |
| R94 | No organisation-wide symmetric secret; no permanent non-rotatable node identifier | author v1-R14; v1-A M5; v2-A M4, M5 |
| R95 | Rotating a recognition secret never locks out a node or phone that missed it | v1-B M5 |
| R96 | Recovery material only replaces the top authority; not removable by the top key alone; replaced after use | author v1-R16 (residual corrected); v1-A M9, m10; v1-B M6; v2-A m9; v2-B m2 |
| R97 | Top-authority key not on, or derivable from, the daily issuing host | author v1-R10; v1-A M7 |
| R98 | Ceremony inputs checked against an independent record; signed log | v2-A m11 |
| R99 | Until commit, a new image leaves the previous image able to manage the node | author v1-R18; v1-A M8; v1-B M7; v2-A m6; v2-B M7 |
| R100 | Missing / stale / unknown authority data -> refuse; fail-open exceptions listed | author v1-R20 |
| R101 | Defined behaviour when the SE is absent / silent / swapped; never a fallback identity | author v1-R21; v2-B M8; v2-A m12; v1-A m7 |
| R102 | Only the root authority component can reach the SE; non-root code and containers cannot | v2-A m1; REVIEW.md item 5 |
| R103 | Management inputs reachable from mesh / AP / Ethernet: bounded before verification; L2 presence grants nothing | v1-A m8; v1-B M8 |
| R104 | Reach of one administrator credential and phone bounded, stated in numbers, enforced by nodes | v1-B M3; v1-A B2; v2-A m13; v2-B m5 |
| R105 | A rekey excludes a revoked party without waiting for the revocation to arrive | v2-A M2 |
| R106 | Network secret to a person only under that person's certified key; never readable by the radio-facing process | v2-A M1 |
| R107 | A second administrator can take over with nothing from the first phone, station unreachable | v1-B B2 |
| R108 | A change object discloses nothing to the removed party or beyond a viewer's need | v1-A m5; v2-B m5 |
| R109 | User-presence scope stated per operation; key-invalidation events never silently lose the top authority | v2-B M4 |
| R110 | Enrolment and factory reset are all-or-nothing; never "manageable only by the offline root" | v1-B M6; v2-B M6; v2-A m3, m4 |
| R111 | A member can use whichever node they were handed with the station unreachable | v1-B M9; v2-B M3 |
| R112 | Rekey delivery never isolates a node unannounced; no slower than the hand-over it replaces | v1-B M8; v2-B M2 |
| R113 | Clock comparisons never lock out a legitimate administrator while sparing a thief | v1-B m3 |
| R114 | Replacing the top authority keeps networks updatable and the organisation's identity stable | v2-A M6; v2-B B2; v1-A M9 |
| R115 | Authority to start a signed update is separate from root-equivalent rights | v2-A M8; v2-B M9 |
| R116 | Every request type assigned to exactly one authority class; unlisted = refused | v2-A m7; v2-B m3 |
| R117 | Station-to-phone synchronisation confidential, per-account, need-based | v2-A m14 |

### 1.2 Other additions

| Added | Source |
|---|---|
| Header / status block, markers, identifier rule | task statement |
| §3.0 two platform states, §3.2 per-state consequence, §3.3 per-state table; S-table column "Differs between OFF and ON?" in place of "Civil / Tactical"; wording changes in X2, T-SE7, T-SE9, T-MS1, F12, L9, AT1-4.2, AT5-1, §8.1-8, §8.2-10, §10-1 | task statement (CM4 decision 2026-10-23; issues #115, #74, #111) |
| A12 boot-chain signing key | consequence of the premise correction |
| A13 recognition secrets and directories of them | author v1 V9; v2-A m13, m14 |
| B15 local code <-> helper socket / SE device; B16 station <-> phone sync | v2-A m1, m14; v1-B M12; REVIEW.md item 5 |
| S22 (secure boot is a choice); S23–S31 (verified baseline facts the reviews rely on) | reviews as tagged per row; each [V] opened |
| X18 low-privilege credential holder | author v1 T3 |
| X19 local non-root process, X20 compromised container, coverage paragraph | REVIEW.md item 5; v2-A m1 |
| X21 intermediate issuer acting beyond its delegation | v1-A B1, B2; v1-B M4 |
| T-SE13 label does not commit to the chip key | v2-B M1; v2-A m10 |
| T-SE14 SE absent / silent / swapped | author v1-R21; v2-B M8; v2-A m12 |
| T-SE15 non-root code or container reaches the SE bus | v2-A m1 |
| T-SE16 printed secret as a standing key | v2-A M4, M5; v2-B B1(a) |
| T-OR10 intermediate over-reach | v1-A B1, B2; v1-B M4; author v1-R1, R2 |
| T-OR11 revocation lost at re-enrolment / self-referential or poisoned minimum | author v1-R6, R7; v1-A M1; v2-A B1; v2-B M10 |
| T-OR12 root-equivalent rights and update authority | v1-A M6; v2-A M8; v2-B M9; author v1-R3 |
| T-OR13 root on the daily host; ceremony inputs | v1-A M7; v2-A m11; author v1-R10 |
| T-OR14 top-authority replacement orphans networks; recovery copy outranks the owner | v1-A M9, m10; v2-A M6, m9; v2-B B2, m2; author v1-R16 |
| T-PH9 secret-returning request as an oracle; provd sees the reply | v2-A M1, M2; v1-B B2 |
| T-PH10 user presence per use | v2-B M4 |
| T-PH11 stale edit undoes a removal | v1-B m6; v2-B M5(a) |
| T-ND6 management inputs reachable from the mesh | v1-A m8; v1-B M8 |
| T-ND7 unassigned verbs | v2-A m7; v2-B m3 |
| T-ND8 cached verification; revocation vs stored state | author v1-R8; v1-B M2 |
| T-MS5 bearer-object replay after leave / reset | v1-A B3, M3; v1-B B1; author v1-R9 |
| T-MS6 version exhaustion / stranding / spread | v1-A M2; v1-B M1; v2-A M3; v2-B M5(b) |
| T-MS7 authority crossing its context | v1-A M3, M4, m1; v2-A M7, m8; v1-B m5; author v1-R4, R11 |
| T-MS8 rekey delivery splits the mesh / slower than today | v1-B M8; v2-B M2 |
| T-MS9 change object informs the removed party | v1-A m5; v2-B m5 |
| F13 second administrator takes over; F14 software update; F15 member at turn-out | v1-B B2, M9; v2-A M1, M2, M8; v2-B M3, M9 |
| L13 identity backend change; L14 SE failure / HAT swap; L15 interrupted enrolment / reset; L16 automatic revert in the trial | v1-A m7, M8; v1-B M6, M7, M11; v2-A m3, m4, m6, m12; v2-B M1, M6, M7, M8; author v1-R18 |
| "AT additions" table (17 new leaves) | as per threat |
| §7 second table (self-assessed scores for added threats) | merging author |
| §8.1 questions 26–34 | v1-A m2; v1-B B1, B3, M12, m1, m2, m3; v2-A B1; v2-B M6, M8, M10; premise correction |
| §8.2 items 15–19 and the note on item 11 | v2-B B1(a)(b)(c), M1; v2-A M4; premise correction |
| §10 residuals 11–15 | author v1 §6-7; v2-A m9; v2-B m2; v2-A M3; v1-B M7; premise correction |
| §11 design-neutral rewording of R1, R14, R15, R19, R21, R25, R32, R33, R41, R43, R44, R45, R60, R62, R76 | task statement |
| Appendix A (the §8.2 list indexed to R-numbers) | task statement |
| Appendix B (nine open problems with pitfalls) | task statement; pitfalls from all four reviews |
| "Out of scope: cryptographic primitives"; follow-up note on `docs/threat-model.md:38` | author v1 §3 and header |

## 2. What from the author's v1 was dropped or absorbed, and why

| v1 item | Outcome | Why |
|---|---|---|
| Language (Traditional Chinese), ✅ / ⚠️ marks | Dropped | Target language is English; marks replaced by [V] / [D] / [A] |
| Assets V1–V10 | Absorbed into A1, A3, A5–A9; V9 -> A13; V3 (node root access) stays in A8 | Same things under the base's ranking; no new loss class except V9's recognition secrets |
| Actors T1, T2, T4–T10 | Absorbed into X1, X5, X4, X2, X8, X10, X7, X11, X12 | Same actors |
| Actor T3 | Added as X18 | The base had no "current low-privilege holder who escalates" |
| v1-R1 (anchor object signed only by the anchor itself) | Not a requirement; property is in R55 + R81 | Names a mechanism (an object and who signs it) |
| v1-R2 (fixed chain shape) | Property -> R81 | "anchor -> one issuer -> leaf" is a design choice (§11) |
| v1-R3 | -> R82; the update part -> R115 | |
| v1-R4 | -> R83 | |
| v1-R5 | -> R84 (R7, R3 already cover custody and key binding) | |
| v1-R6 | -> R85, R86 | "the floor travels with enrolment" is the mechanism review v2-A B1 broke; kept as property |
| v1-R7 | -> R87 | |
| v1-R8 | -> R88 | |
| v1-R9 | -> R90, S23 | |
| v1-R10 | -> R97 (R24 already separates purposes) | |
| v1-R11 | -> R91 | |
| v1-R12 | -> R92, **corrected** | "always, by signing a higher version" is false at the top of the version space (§3 below) |
| v1-R13 (member entries carry a node-credential hash; app lists only own-organisation nodes) | Dropped as a requirement; covered by R56, R57, R104 | Mechanism; and enforced only by an honest app (v1-B M3, v1-A m4), which R104 now forbids relying on |
| v1-R14 | -> R94 | |
| v1-R15 | Covered by base R32, R25, R26; usability side -> R109 | |
| v1-R16 | -> R96, **residual corrected** | §3 below |
| v1-R17 (checks in the helper, provd passes bytes) | Covered by base R44 | Same property; mechanism wording dropped |
| v1-R18 | -> R99 | |
| v1-R19 (no in-place downgrade after commit; re-enrol) | Covered by base R71, R75, R77; residual 14 added | A procedure, not a property |
| v1-R20 | -> R100 | |
| v1-R21 | -> R101, **contradiction left open** | §4 below |
| Role names (VIEW / USE / NET / MAINT / OWN / NET_ONLY), "trust list", "issuer certificate", "generation", "identification key" | Not used | Design vocabulary; the requirements must hold for any design (§11) |
| Premise "phone OS and hardware keystore are trusted" | Dropped | The base keeps X13 (compromised phone OS / app update) as an actor with a stated residual (T-OR5, T-PH5); the stricter view wins |
| Premise "no secure boot on the civil build; Pi 4 secure boot for tactical" | Replaced | §3.0: CM4, secure boot is a product choice |
| §6 item 7 (608B has no FIPS 140 module validation; TA101 as the alternative) | Kept as §10-11, marked [A], product suggestion (TA101) dropped | Not verifiable here; see §4 below |
| §7 test table | Dropped | Every v1 test is restated as the negative test of the corresponding R81+ row, with the cases the reviews said were missing (revoked issuer, maximum version, replay after reset) |
| Header note "after approval, summarise into `docs/threat-model.md` and correct the single-root-CA sentence there" | Kept as a follow-up line in the header | `docs/threat-model.md` must not be changed by this task |

Design *fixes* proposed in the reviews (random organisation id, authority as an entry class, one record with one
commit point, drop the password-read verb, second chip slot for a derived value, no in-place conversion, …) were
deliberately **not** imported: only the threat and the property were. They appear, if at all, as pitfalls in
Appendix B.

## 3. Contradictions between the sources, and how each was resolved

| # | Contradiction | Resolution |
|---|---|---|
| 1 | Base and author v1: "the civil build has no secure boot". Task statement: production is the CM4, secure boot is available. | Two platform states OFF / ON throughout (§3). Only the four stated facts about the mechanism are used; everything else about state ON is marked [A] |
| 2 | Author v1-R16 residual: a parent whose recovery card was photographed "uses the card to switch back". Reviews v2-A m9 and v2-B m2: the copy-holder can also replace the recovery entry, so the parent cannot. | Reviews are right by the design's own rule (only the recovery key signs a recovery change). R96 and §10-12 state the corrected residual |
| 3 | Author v1-R12: the legitimate authority can "always" regain control by signing a higher version. Reviews v2-A M3, v2-B M5(b): false at the maximum version; tie-break grindable. | R92 written as the property ("recoverable offline without physical reset"); the ceiling is in T-MS6 and §10-13 |
| 4 | Author v1 §2: provd holds "only helper-derived PSKs". Base S21 and review v2-A facts-1: provd terminates the session and sees every reply in clear. | Verified in source: the PSK statement is true of the poll (`node/node.go:433-436`) and the base is true of the session (`provd/noise.go:38-39`, `provd/session.go:390-392`). S21 kept, S26 added to say exactly what does and does not cross provd today |
| 5 | Base R75: an image that cannot read the authority state "fails closed". Author v1-R18: after a revert "the node still logs in and is in the network". | Not in conflict: R75 is the state after a new format has been committed (downgrade); v1-R18 is before commit (automatic revert). Both kept: R75 and R99; lifecycle rows L8/L9 and L16 |
| 6 | Base S8: code accepts only a contiguous chain; spec (`219-protocol.md:367`) says smaller hash wins. | Already flagged by the base; both statements re-verified and left as a documented code/spec difference (Appendix B5) |
| 7 | Base R33 ("changing the administrators needs more than one administrator's signature") vs the design direction both reviewers called sound ("any holder of the network right may sign a change"). | Not in conflict once R33 is read as a property (§11): no single administrator-level credential may change who the administrators are. A design where that set is decided one level up satisfies it |
| 8 | Base R6 (no authority from a printed secret alone) vs the design's label-derived login path for recovery. | Base stands. The path is recorded as T-SE16 and Appendix B3, not accepted |
| 9 | Author v1-R15 (user authentication on every use) vs review v2-B M4 (unworkable per node; key invalidation). | R32 kept (property in §11); R109 added for scope; left as open problem B7 |
| 10 | Review v2-B's time figures (5–10 min for 8 nodes, etc.) are estimates, the base asks for evidence. | Quoted only as "reviewer's estimate, unmeasured" |

## 4. Contradictions that could NOT be resolved

1. **SE does not answer: "helper refuses to start" or "keep the network, refuse new settings"?**
   `docs/design/254-stage1-impl.md:215` (earlier decision) says the former; the author's v1-R21 says the latter;
   review v2-B M8 shows that under either, no session exists in which "a new setting" could be refused. This is a
   product decision. The document records both (S29, T-SE14), asks it as §8.1 question 29, and R101 requires that
   it be decided, stated and tested — it does not pick.
2. **FIPS 140 status of the ATECC608B.** The author's v1 says the chip is not in the NIST CMVP list; the first
   design draft cited a CMVP certificate number (5371), which reviewer v1-A listed among external facts not
   checked. No network access was allowed in this task. §10-11 is marked [A] and says to check before any customer
   statement.
3. **Whether each SKU ships in state ON.** Not a contradiction between documents but an undecided input: the user's
   CM4 decision makes secure boot possible; no document says which product enables it. Everything that differs is
   in §3.3; §8.1 question 33 asks for the key custody.
4. **`docs/threat-model.md:38`** still describes one root CA signing node and TAK client certificates, which
   conflicts with R24 / R97. That file was out of bounds for this task; the header carries the follow-up.

## 5. Citations checked, and corrections made

Every [V] kept from the base and every [V] added was opened in this worktree during the merge.

| Where | Was | Now | Reason |
|---|---|---|---|
| Base L8 | `provstore/provstore.go:55-58` | `:59-61, 112-131` | 55-58 are struct fields; the "older images demand exactly 11 keys" comment is 59-61 and the strict decode is 112-131 |
| Base B14 | `release/release.go:26-31,57-58` | `:30, 54-58` | The downgrade reason code is line 30; "root key … read-only squashfs" is the comment at 54-55; `Root` / `MinSerial` are 57-58 |
| Base S5 | `keystore/keystore.go:76-103` | `:78-98` | The body of `SignPurpose` |
| Base S6 | `node/node.go:954,983` | `:954, 983-984` | The last-owner refusal spans two lines |
| Base S8 | `node/node.go:1200` | `:1200-1202` | The check and its error |
| Base S11 | `node/node.go:609` | `:587, 609` | Password generated at 587, returned at 609 |
| Base S15 | manifest only | + `res/xml/data_extraction_rules.xml` | The manifest line only names the rules file; the exclusions are in it |
| Base S21 | `provd/noise.go:38-39` | + `provd/session.go:390-392` | The cipher states are held by provd (38-39); encryption of replies happens in provd (392) |
| Base B6 | `batman-provd.init:34-36` | + `:39`, `files/batman-provd.json`, `Makefile:40` | 34-36 show user, group and jail only; "no capabilities" is the all-empty JSON referenced at line 39; uid 471 is in the Makefile |
| Base B2, S20, T-OR4 | `[D ICS threat_model …]` | same, marked "not in this worktree" | ICS_COMMAND is not in the worktree; could not be opened |
| Base S1, S3 | "task statement" per build | restructured per state | Premise correction |
| Review v2-A M1 | `provd/session.go:72-73` (secret-bearing replies) | `:71-73` | The comment line is 71 |
| Review v2-B M7 | `node/node.go:250-259` (trial refusal) | `:251-259` | Map starts at 251, check at 258 |
| Review v2-B m6 | `node/node.go:1208-1212` (country rule) | `:1208-1213` | Used in R90's wording only |
| Review v2-B M7 | "batman-autocommit … line 621" | `:621-622, 629-631` | Confirmed; added the operator-commit comment lines |

Confirmed unchanged (line still says what is claimed): `release/release.go:1-4, 57-58`; `files/batman-http.nft`;
`provstore/provstore.go:10, 66, 112-131, 147, 181`; `keystore/keystore.go:1-5, 42-46, 60-61, 68-69, 266-267`;
`node/node.go:433-436, 592, 609, 672, 778-787, 832-838, 966-995, 1057, 1106-1113, 1169-1171, 1192, 1214, 1227`;
`provd/session.go:60-65, 82, 641-642`; `provd/noise.go:20-21, 38-39, 74-76`; `provd/server.go:738-781`;
`provd/http.go:3-6` (author v1; not cited in the merged text, covered by B5 / B11); `boot/boot.go:270-271`;
`sock/sock.go:2, 189`; `feed/batman-provision/files/usr/bin/batpower:44-45`; `Keys.kt:79-98` and the empty grep for
`setUserAuthentication` / `setAttestationChallenge` under `app/android`; `KeyPolicyTest.kt:50-53`;
`AndroidManifest.xml:29-30`; `app/rust/batman-proto/src/rekey.rs:102-103`, `joinflow.rs:157`.
[D] lines also opened and confirmed: `219-field-provisioning.md:27, 78, 333, 335, 432, 492, 512`;
`219-protocol.md:78, 260, 315, 341, 367` and sections §4.1, §5.3, §5.4, §5.7, §7.3–§7.6, §9;
`254-p3-impl.md:62`; `254-stage1-impl.md:215`; `255-key-authority.md:248`.

Not verified (kept as [A] or attributed to the reviewer in the text): every ATECC608B behaviour; Android behaviour
on new-biometric enrolment and on a missing lock screen (review v2-B M4); mesh dual-password support (review v1-B
M8); the reviewers' time and size estimates; all ICS_COMMAND statements; the CM4 / secure-boot facts beyond
`255-key-authority.md:248` and the four facts given in the task; issue numbers #111, #115, #74, #174.

## 6. Notes for the next reader

- A [V] mark means "the cited line says this", not "the behaviour was observed on a node". Nothing here was
  reproduced on hardware.
- The second table in §7 (scores for added threats) is the merging author's own judgement and is the least
  independent part of the document.
- §11 changes the normative wording of 15 base requirements without editing their rows; a reviewer ticking §9
  should read §11 first.
