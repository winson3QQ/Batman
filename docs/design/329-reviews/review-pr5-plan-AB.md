# Review AB — #329 PR 5 plan v14 (round 14)

Reviewer AB. Focus: security and fail-safe behaviour of the new parts. Read-only against `C:/src/Batman-329pr5` @ 2e18de6 (plan file `docs/design/329-pr5-plan.md`, 1087 lines). Baseline (§0) not re-reviewed; used only to check the plan moves it faithfully.

## Central question: can a removed member keep access unnoticed?

**Leader side.** The only "done" signal is `rekeyEnd == current`. It requires an anchored full-sentence match of `AlreadyCurrent` / `Updated` (rekey.rs:447, :451). Rust builds those sentences from the `End` enum only (`update_text`, rekey.rs:430-458). The node-influenced text (`Broken(w)`) always starts with `[REQ_FAIL] 中斷（`, so anchoring defeats injection. `Applying` and `Unfinished` are not success (R14; updflow.rs:248, :316). `NetRun`'s old prefix test (net_run.dart:302) is replaced (D12). 8.4 lists every own node, including unreadable ones and ones this phone cannot send to. `kRekeyDoneRule` always says the unconfirmed nodes may still let the removed person in. I found **no hole in the logic**. The one gap is the **source of the version number** the leader shows (MAJOR AB-M1). It defeats the member-side check below in exactly the T-M1 attack.

**Member side.** The R14 two-part check closes Z-M1 correctly:
- Part 2, "這台節點已換成這支手機的版本", appears only on `current`. For a member, that means node k9 == `MNet.version` (updflow.rs:159, :256).
- Part 1 is a spoken comparison of the phone's version against the leader's "目前是第 N 版". It is the only defence against T-M1: an old, genuine, never-imported bundle gives `Advance` (mupdate.rs:263-268) and then `Updated`.
- The check is only as good as both displayed numbers being fresh and belonging to the same network. See AB-M1 and AB-m1.

Residual risks the plan already states, and I accept: other members' own nodes can't be seen (X-m5); a malicious remaining member can simply not update; physical capture.

---

## MAJOR

### AB-M1 — "目前是第 N 版" on 8.1 / 8.4 has no defined freshness. A stale value equals the old version, which is exactly the T-M1 attack's version, so the attack passes the spoken check.

**Scenario.**
1. The network is at version N−1. The leader removes R in 8.3, giving `OfflineOp('移除隊員')`, PersistNet at N, and then 8.4.
2. 8.4 shows "目前是第 N 版", taken from `NetView.version`.
3. The plan does not say where 8.4 gets the `NetView`. The natural source is `a.nets.now.nets`.
4. `NetIndex` recomputes only after the lease release, in a microtask, and then awaits `compute()`, which lists and opens every record (net_index.dart:128-145, :189).
5. While it computes, the snapshot keeps the **old** `nets` with `computing: true` (net_index.dart:131-138).
6. `OfflineOp` returns right after it releases the lease, and the page pushes 8.4 straight away. So 8.4's first build sees version N−1.
7. 8.4 may not listen to `NetIndex`. Existing pages do so only when they opt in (net_pages.dart:173, node_page.dart:39, home_page.dart:114), and the plan doesn't require it for 8.1, 8.4 or `RekeyResult`. Then the leader keeps seeing "第 N−1 版" for the whole hand-out.
8. Meanwhile a malicious member (or someone who intercepted messages in the chat app) hands victim V an old, genuine bundle at N−1 that V never imported. That gives `Advance`, then the send gives `Updated`, and part 2 shows "已換成這支手機的版本".
9. V reads out "第 N−1 版". The leader's screen says N−1, so they match, and the check passes.
10. V's nodes stay on the key R knows, and nobody notices.

The member side has the same issue in a milder form:
- `RekeyResult(member)` takes N from `NetIndex.mnets` (plan R14 table). Right after the 8.5 import, the snapshot may still be the pre-import one.
- 8.5's top line re-reads the mnet directly (Z-m4). So one page can show two different numbers.
- A member-side stale value is lower than the real one, so it causes a false alarm, not a false pass. Only the leader side gives a false pass.

**Evidence.** Plan §2.7 items 1 and 10 and §2.9 R14 name only the field, not the read. The source lines are net_index.dart:131-145 and :189.

**Fix (one rule, stated once).** Every screen that shows a version number (8.1, 8.4, 8.5, `RekeyResult`) follows one rule:
- It reads the number either from a record read in the page's own lease, or from `NetIndex` with a listener.
- While `computing` is true, it shows "正在讀取版本", never the old number.
- For 8.4 entered from 8.3, the number comes from the record `startRemove` just wrote (or from a re-read after `OfflineOp` returns).

Tests:
- After `OfflineOp('移除隊員')` returns, 8.4 shows N, never N−1.
- Negative control: build 8.4 from the pre-recompute snapshot → FAIL.
- Member side: right after the 8.5 import, `RekeyResult` and the top line show the same number.

---

## MINOR

### AB-m1 — The member's version must be the counter that `current` compares, and it must be for the network that was sent to
- **Which mnet.** `RekeyResult(member)` takes N "from `NetIndex.mnets`" without saying which mnet. A phone in two teams could show the wrong team's number. **Fix:** use the mnet that R17 step 1 resolved from `infoNetId`, and show the network name next to the number.
- **Which field.** §0 and §3.2 say that `version` is `None` when the netcfg can't be decoded, and that it is "the netcfg version". But the member's `current` compares node k9 against the mandatory record field `MNet.version` (mrec.rs:93, :157; updflow.rs:159). That field always decodes when `MNet::decode` succeeds. **Fix:** define `MnetView.version = MNet.version`. The `None` case then applies only to `NetView`, where updflow.rs:175 uses `cfg.version`. Pin that equality in the planned Rust test.

### AB-m2 — The R16 three-way table is missing cases, and two of its paths mislead the user
- **(a) Unopenable mnet.** An mnet that can't be opened (2.11, Y-m4) has no row. State that it shows "讀不到隊伍網路紀錄" plus retry, never `_makes` and never `kNotEntryNode`.
- **(b) Home row 6 picks the wrong node.** Home row 6 passes `notIn.first.id` (home_page.dart:186-188). When the member has an unjoined entry node and a second, non-entry node first in that list, they get `kNotEntryNode`, which says "請隊長再邀請一次". That costs a needless new invite even though the right node is on the phone. **Fix:** when an entry node matching `sameLast4` is on the phone, `kNotEntryNode` names it ("改用節點 …xxxx") and links to it.
- **(c) Settings doesn't say which node.** The settings row "讓我的節點加入隊長的網路 → 選 mnet → R16" doesn't say which node `NetFormPage` gets. **Fix:** tick the `sameLast4` candidates and list them when there is more than one.

### AB-m3 — The R12 "移除" check must compare the full owner
"這個人已不在名單" has to be checked by the full `owner`, not by name. With two same-name groups (D-M2), checking by name would report the wrong result. State this in the R12 table and add a same-name test case.

### AB-m4 — Lifecycle: the app is killed after the mnet is written but before the mpend is deleted
The old order is: write mnet, then remove mpend, failure ignored (nodes.dart:1017-1027). R12 cleans up the leftover mpend only on the revoke path. After a kill:
- the home to-do stays "你的加入申請還在等隊長同意", because the condition is just mpend (upper design :699);
- 7.9 keeps offering the request again.

This is not a security risk, but it misleads the member. **Fix:** when 7.9 or 7.10 opens and `mnet/<id>` exists next to `mpend/<id>`, run the same R12 check: `memberImportPrepare(pendPlain: null)` → `AlreadyImported` → delete the mpend under a new lease. Add this as a row in 3.3.

### AB-m5 — Missing negative controls
- **R8 hint retention:** the rules "`netId` empty and `nodeState != 1` → keep the old hint" and "`nodeState == 1` → clear it" have no test.
  - Add both cases.
  - Negative control: clear the hint when `netId` is empty → the "還在舊密碼" card disappears after a failed read → FAIL.
- **R12 `Lease.revoke` source check:** no negative control is stated. Add a call from a non-`OfflineOp` file → FAIL.

### AB-m6 — Correct the §5 wording that `current` cannot be forged
R14 says "`last4` 取自手機的紀錄，節點無法偽造". That holds for the last4 only. `current` itself rests on the node's self-reported k9 (updflow.rs:254-258, :316-317). A compromised own node can claim `AlreadyCurrent`. This is acceptable, since a compromised mesh node already defeats the rekey, but §5 "被入侵的節點" should say so rather than implying the result can't be forged. Documentation only.

### AB-m7 — Logging check (no change needed; recorded as verified)
- Only types are logged: owner_console.dart:225, :305 (store reason or type, no record bytes), op_session.dart:123 and :183.
- The only `$e` log is the prober catch-all (prober.dart:185). R7's local catch keeps code text out of it, and T-P5-L covers it.
- The `[JOINREQ] …名稱「{name}」` detail (member.rs:297) is shown, never logged. Make sure T-P5-L also covers `joinreq`'s `value` path, not only `failed(line)`.

---

## Other areas checked (no finding)

- **R17 `sendNewKey`.**
  - `sendUpdateFor` reads the record itself (owner_console.dart:499-507).
  - The record type is chosen net-first, as in the old code (nodes.dart:1555-1560).
  - The confirm dialog is leader-only, as in the old code (nodes.dart:1567-1572).
  - `expectNet` and `expectDac` both fail closed.
  - The allowlist plus "no `confirm:` argument" is a non-empty check.
- **R18.** Rust keeps the original case (owner.rs:717 `last4`; member.rs:322), while Dart's `last4()` uppercases. The single-rule approach plus a source check is right.
- **R6–R9.** Compromised node: `update_hint_of` (rekey.rs:466-500) can only produce the three fixed lines. k10 can only name a hex path (owner.rs:2260). R9 keeps the hint out of the "done" decision. Field builds never call `openNet`.
- **R10–R12.** Revoke goes through `Lease._revoke`, and `RecordWriter` then refuses (lease.dart:140-149; record_writer.dart:27-33). That is fail-closed. Removal is reported as "已經移除" only after a re-read. `z` is zeroed in `finally`. Op names are constants.
- **R1–R4.**
  - With `SecureScreen` and no fallback, behaviour is unchanged: secure_screen.dart:46-50 shows a placeholder when the flag fails.
  - The QR fallback hides the QR but keeps "copy".
  - The SAS is shown with a warning (D6). That is acceptable: the SAS is a comparison value, not a secret, and 7.9 says to compare it over a different channel.
  - The clipboard is cleared after every paste, including rejected ones, and `clearClip` is the only clear.
- **R15/R16 gates and "never make a network".**
  - `makes: true` reaches `NetFormPage` only when the phone holds no record at all (home_page.dart:186; add_pages.dart:135), or from CheckNetPage when a leader net is pending (node_page.dart:66-73).
  - For an mnet- or mpend-only phone, :353 returns early today, so line :362 is reached only with no records at all. R16 has to keep that early return for every mnet case; AB-m2(a) covers the gap.
  - The Dart gate on the "send new key" entry is required, since `request_send_update` has no `dev_gate` (owner.rs:1041).
- **§2.12.** Every member button in nodes.dart:1733-1770 maps to a new entry.

## Verdict

**APPROVE-WITH-CHANGES.** 0 BLOCKER / 1 MAJOR / 7 MINOR.

AB-M1 must be fixed before implementation. The spoken version check is the only member-side defence against an old-bundle replay, and a stale leader-side number turns that check into a false pass.
