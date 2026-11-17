# Review AD: #329 PR 5 plan v15 (round 15)

Reviewer AD. Focus: security and fail-safe behaviour of the new parts. Central question: can a removed member keep access without anyone noticing, on the leader side or the member side?

Worktree: `C:/src/Batman-329pr5` (feat/329-pr5 @ main 2e18de6). I read the plan's whole body (§0 to §8 and appendix A), the AB review, and the source cited below. I modified no code.

**Verdict: APPROVE-WITH-CHANGES.** 0 BLOCKER / 1 MAJOR / 8 MINOR.

---

## What I verified holds (central question)

| Claim | Evidence | Result |
|---|---|---|
| The leader's `current` means the node's k9 equals the net record's netcfg version | updflow.rs:175 (`self.version = cfg.version`), :251-258, :311-312 | holds |
| The member's `current` means k9 equals `MNet.version` | updflow.rs:159, mrec.rs:93 | holds, and R19 defines `MnetView.version = MNet.version` |
| `MNet.version` after an import is the bundle's netcfg version, so the leader and member numbers are the same counter | mupdate.rs:82-84, :109-111, :345 | holds |
| The "current" sentences are built by Rust from an enum, and last4 comes from the phone record | bridge rekey.rs:430-458 (`update_text`), owner.rs:717 | holds. A node cannot forge the sentence, only k9 (§5, AB-m6) |
| A member-side stale version can only be lower than the truth, so it gives a false alarm, not a false pass | mupdate.rs:204-218 (only advances) | holds (also noted in AB-M1) |
| An own node that was excluded cannot get the new secrets, even when last4 is mistaken | updflow.rs:166-171 (`NotListed`, ecdh_pub check) | holds, as Rust-level fail-closed |
| `sendUpdateFor` reads the record inside the once and defaults to `member: false` | owner_console.dart:507-514 | holds. R17 / X-m2 are correct to force `member: true` for the member branch |
| `NetRun` today treats `Applying` as success | net_run.dart:299-311 (`starts('[UPDATED] ')`) | holds. R14 / D12 fix it |
| The never-make rule: today's :353 branch already returns for mnet-only or mpend-only, and :362 is reached only with no records | net_pages.dart:341-362; NetSnapshot.records net_index.dart:63-72 | holds |
| Old member send had no confirm; leader send confirmed | nodes.dart:1567-1572 | holds. R17 step 2 is faithful |
| Codes carry no secrets (privacy only) | 219-protocol.md:372 (invite "不含秘密"); approval secrets are encrypted to the joiner | holds. R3/R4's "privacy, not secret" framing is right |

Leader side: apart from M-1 below, I found no way for a removed member to stay connected through the leader's own nodes without the leader seeing it.
- 8.4 lists every own node from the network record, including ones that cannot be read.
- Only an anchored `current` counts as done.
- The fixed text always says that an unseen node may still be reachable.

Member side: the two-part check (R14) is sound as long as the leader's number is fresh. M-1 is exactly the case where it isn't.

---

## MAJOR

### AD-M1. R19 re-reads the version only when "this page" opens or writes. 8.1 stays mounted under the removal flow and keeps showing N−1 when the leader returns to it. AB-M1 is not fully closed.

**Scenario.**
1. The network is at version N−1. The leader opens 8.1 (members list). R19 reads `net/<id>`, and the top line says "目前是第 N−1 版".
2. The leader taps Mallory and goes 8.2 → 8.3 → `OfflineOp('移除隊員')`, which writes version N, and then 8.4. These are pushed routes, so 8.1's State stays alive underneath. The plan says 8.1 is where the leader returns after a removal: it shows "還有 N 位隊員沒交更新包" when `removedThisRun` is set (plan :310), and that banner only makes sense on a return visit.
3. 8.4 correctly shows N, because it takes the number from `startRemove`'s record. The leader hands out bundles and then backs out of 8.4 to 8.1.
4. 8.1 has neither opened nor written since step 1, so under R19 it does not re-read. It still says "目前是第 N−1 版".
   - The plan names this very line as the one to compare against: "隊員唸版本號時，隊長對照這一行" (plan :311).
5. Member V never received or imported the N bundle. Alternatively, a malicious member forwarded V a genuine old bundle at N−1, which is the T-M1 / AB-M1 attack. Either way, V's phone holds N−1.
   - V presses send from the hint card or from "更多". The node is at N−1, so Rust returns `AlreadyCurrent` (updflow.rs:256-258). `rekeyEnd` gives `current`.
   - So V sees "這台節點已換成這支手機的版本" and "這支手機是第 N−1 版".
6. V reads out "N−1". The leader's 8.1 says N−1. Both parts of the R14 check pass.
7. V's nodes stay on the key Mallory knows, and nobody notices. This is exactly the failure AB-M1 described, now reached through a page that stays mounted instead of through the `NetIndex` snapshot.

**Evidence.**
- Plan :470: the re-read happens "頁面打開時，以及這一頁每次寫入之後". Nothing covers a mounted page whose record another page rewrote.
- Existing pages refresh only when they opt in to `NetIndex` (net_index.dart:113-145 notifies; net_pages.dart:173 and node_page.dart:39 listen). The plan forbids taking the number from `NetIndex` (R19) but gives no other trigger.
- No source in the app uses `RouteAware` or `didPopNext` (grep of app/lib: no hits), so there is no existing resume hook that would cover it either.
- The member list on 8.1 (`netPeople`) has the same gap: if it is read at open, Mallory is still listed when the leader returns.

**Fix (state it once, in R19).**
- Every screen that shows "目前是第 N 版" re-reads `net/<id>` whenever the screen becomes visible again (route resume) and whenever `NetIndex` notifies. The notification is only a trigger; the number still comes from the record read, so the "no snapshot" rule stands.
- Between the trigger and the finished read, the line shows "正在讀取版本", never the old number.
- The same applies to the `netPeople` list on 8.1.
- Test: 8.1 → 8.2 → 8.3 remove → 8.4 → pop back to 8.1, and 8.1 shows N.
- Negative control: drop the resume re-read and the test shows N−1 → FAIL.

---

## MINOR

### AD-m1. `RekeyResult(member: true)` after `NetRun`'s auto-send has no version source
- R19's member source is "the mnet that R17 step 1 resolved" (plan :472). R14 / R16 also show `RekeyResult(member: true)` under the `NetRun` row after `memberJoin` (plan :426, :518). That path does not go through R17 (plan :406), so no source is defined.
- An implementer will reach for `NetIndex.mnets.version` (2.11), which R19 forbids.
- **Fix:** take it from the mnet re-read that 2.3 already requires between `memberJoin` and `sendUpdateFor` (plan :197).

### AD-m2. Parts 1 and 2 of the member check should be provably about the same read
- Part 2 (`current`) is computed by Rust against the mnet plaintext that `sendUpdateFor` reads inside step 3's once (owner_console.dart:509).
- Part 1's number comes from the step-1 read (plan :472). In practice nothing writes in between, but the guarantee is by convention only.
- **Fix:** take part 1's number from the same plaintext that step 3 passed to Rust. For example, `sendNewKey` summarises that plaintext before it drops it. Add a test that a different mnet version written between step 1 and step 3 shows the step-3 number.

### AD-m3. R7 does not say which `member` flag `updateHint` gets
- The old code passes `false` for `net/` and `true` for `mnet/` (nodes.dart:1163-1169).
- With the wrong flag, `update_hint_of` fails to decode and silently returns "none" (bridge rekey.rs:470-479). A member whose node is behind then never sees the hint, which is a quiet fail-open of the D-M1 rule.
- **Fix:** state the pairing in R7. Test: an mnet-only phone with the node behind gets the hint; negative control: pass `false` → FAIL.

### AD-m4. The "mnet written, mpend not deleted, then killed" row cannot run as written
- Plan :620 reconciles by re-running prepare (`pendPlain: null`) with the approval code. That code is memory-only (`CodeInput`), so after an app kill it is gone.
- "An mnet with the same id exists" is not a safe stand-in. A removed member who was re-invited legitimately holds an old mnet and a new mpend for the same net id (remove-member :147, :186).
- **Fix:** without the code, 7.9 says "如果你已經匯入過同意碼，請在 7.10 再貼一次". The 7.10 path, re-run with `pendPlain: null`, returns `AlreadyImported` and then deletes mpend inside the lease. Test both the re-invited case (mpend kept) and the leftover case (mpend deleted).

### AD-m5. `NetIndex.mnets` carries `version` (2.11), which invites a display use that R19 forbids
- **Fix:** drop `version` from `NetIndex.mnets`, or add a source check that no widget showing "第 N 版" reads `NetIndex` for the number.

### AD-m6. NetFormPage's mode is decided "at the entry", but the entry can see `records == unknown`
- While `NetIndex` computes, the home page maps `unknown` to `joinNetwork` → `_form(makes: false)` (home_logic.dart:93; home_page.dart:186-187). The R16 mode table has no row for `unknown`.
- The never-make rule (plan :510) does keep this fail-safe.
- **Fix:** state that the mode is resolved inside NetFormPage after `computing` ends: mnet only → `member`; net and mnet → `joinChoice`. Add a widget test: enter during computing on an mnet-only phone → member mode, and neither "建立網路" nor the :389 make button appears.

### AD-m7. Member send without a confirm on the hint card and "更多", but with a confirm on 8.5
- R17 keeps the old behaviour of no confirm for a member (nodes.dart:1568-1569). 8.5 adds one (plan :387).
- Right after an 8.5 import, the member's node is behind, so the hint card appears with a button. One tap there sends early, which is exactly what 8.5's confirm warns against.
- This is availability, not access, and it is baseline behaviour. Either show 8.5's confirm sentence in `RekeyResult(member)` before sending, or say in D-notes why the hint path stays without one.

### AD-m8. 8.4's version after the R12 path
- R19 says "from 8.3, the record `startRemove` just wrote". When the remove was revoked (R12, "已經移除" from the re-read), there is no such return value.
- **Fix:** state that the number comes from the R12 re-read's record.

---

## Other parts checked, no finding

- **R18 `sameLast4`.** A case-insensitive match can only widen the candidate set, and each widened match is caught fail-closed: `expectDac` in 8.4, `NotThisNode` in R16 (join2flow.rs:380-384), and the Rust-built sentence in `rekeyEnd`. It cannot make a false `current`.
- **R6–R9 hint.**
  - The hint is display only and never counts as done (R9).
  - A compromised node can steer `netId` through k10, but only to `net/` or `mnet/` hex paths (owner.rs:2260), and `update_hint_of` re-checks k10 against the record (bridge rekey.rs:476, :486).
  - With the `cleaning` flag and the fix to prober.dart:83, the dispose race is covered.
- **R10–R12 OfflineOp.** After a revoke, `RecordWriter._check` refuses (record_writer.dart:27-33). A write already inside `store.writeCas` is protected by CAS. `_revoke` releases the lease and so triggers a `NetIndex` recompute (lease.dart:142-149, net_index.dart:189). The todo text holds only a constant name.
- **R1–R4 QR, SecureScreen, clipboard.**
  - Codes hold no secrets (219 :372). The approval's and the bundle's secrets are encrypted to the recipient.
  - Pasting always clears the clipboard, including when the paste is refused.
  - The sensitive flag is ⚠️ unverified on Android 12, and the plan says so.
  - The clipboard size of a 262 KB bundle is ⚠️ untested on a real phone (§7 says so).
- **R15 / R16 gates and the never-make rule.** All new entries are devTrust only, and T-S5 covers the Dart-only gate of the send button (`request_send_update` has no `dev_gate`, P9). The never-make rule matches today's :353 / :362 logic. AD-m6 is only about stating where the mode is resolved.
- **Logging.**
  - T-P5-L covers `debugPrint` and NodeLink, the `failed(line)` names (Z-m7) and the joinreq value (AB-m7).
  - `RecordWriter` logs the `net/<id>` path (record_writer.dart:28), which is not a secret.
  - The prober's catch-all `$e` (prober.dart:185) is avoided by catching locally (T-m7).

## Actors

- **Remote attacker (intercepts codes in a chat app).** Sees invite, request and approval codes, which carry no secrets, and bundles, which are encrypted to the member. Can forward an old genuine bundle, which is the T-M1 attack: blocked by the version check, except for AD-M1.
- **Local unprivileged app.** Screenshots: blocked by FLAG_SECURE, and the fallback hides the QR. Clipboard: the sensitive flag, clearing after a paste, and the user's clear button, plus the stated keyboard-history residual.
- **Compromised peer.**
  - A node can lie about k9. This is a residual stated in §5.
  - A node can steer k10 only to records it is listed in, so Rust refuses others.
  - A member can forward an old bundle. Covered by AD-M1 once fixed.
- **Physical capture.** Plaintext is opened in the hint round. This is a stated residual.
- **Our own mistakes.** The single-flow R17 plus the source allowlist, and R14's fail-closed default. AD-M1, m1, m3 and m5 are the remaining "rule stated in one path only" gaps.
