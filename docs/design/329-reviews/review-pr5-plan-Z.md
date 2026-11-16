# Review Z — #329 PR 5 plan v13 (round 13)

Reviewer Z (independent, adversarial). Focus: security and fail-safe behaviour of the new parts. Central question: **can a removed member keep access without anyone noticing, on the leader side or the member side?**

Scope: plan §0 "本 PR 新做的" items and §2–§7, against main 2e18de6 in `C:/src/Batman-329pr5`. The baseline (219 §7.4/§7.6, member-join v6.1, remove-member v6.5, qr, old console logic, Rust entries, PR 1–4 mechanisms) is used only as reference.

## Verdict: APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 7 MINOR

Leader side: I found no way for a removed member to keep access through the leader's own nodes unnoticed. R17 + R14 + 8.4 hold:
- every own node is listed, including unreadable ones;
- the tick is given only for the two anchored Rust sentences;
- `current` is decided by Rust from info k9 == the phone's record version (updflow.rs:256-258, :317);
- `last4` comes from the session (owner.rs:717, :745).

Member side: one hole is left (Z-M1). The new read-aloud check uses the phone's version. That number is shown together with the instruction to read it out, even when the node did not take the new key.

## Checks done (evidence)

| Item | Result | Evidence |
|---|---|---|
| R14 sentences and line numbers | Correct: Unfinished :445, AlreadyCurrent :447, Updated :451, Applying :452; `_sendUnclear` begins with `[REQ_FAIL]`, so checking unclear first is needed | bridge/src/api/rekey.rs:430-458 |
| `current` cannot be forged by the sentence text | `last4` comes from the phone's node record, not from the node. A lying node could still report k9 = current; that is in the Rust baseline and out of scope | owner.rs:717, :1090; updflow.rs:252-258 |
| A compromised node points k10 at another network the phone holds (hint / 「更多」 path) | Safe: the member path sends only `secrets_for(dac_hash)` of that node; an unlisted node gets `NotListed`, and the admin path checks `listed` | rekey.rs:494-497 (update_hint_of), updflow.rs:268-280 |
| D9 (field build never holds a newer record) | Holds: `start_remove`, `start_bundle`, `member_update_prepare` and `member_update_import` all call `dev_gate` | rekey.rs:255, :268, :397, :411 |
| Old `_sendUpdateFor` confirm applies only to the admin | R17 step 2 matches it | nodes.dart:1567-1572 |
| SAS out-of-band rule on both sides | `sasRule` already in `SasConfirmView` and `SasShowView`, so the leader is warned too | member_ui.dart:36, :73, :97 |
| §2.12 against nodes.dart:1733-1770 | Every member button has a destination, including the ungated old :1745 send (now devTrust-only, D9) | nodes.dart:1733-1770 |
| Appendix A MAJORs | X-M1 (R14 / 8.5 version line), U-M1 (R17), V-M1 (two version fields), T-M2 (R14 NetRun) and T-M1 (member never ticks) all appear in the body. Z-M1 below is a new consequence of the X-M1 fix, not a reopening | plan :366, :374-399, :402-439 |
| Previously removed person re-requesting with an intercepted invite | 7.4 keeps the `previous` dialog (nodes.dart:828-833) | plan :300 |

## MAJOR

### Z-M1 — The member's read-aloud version check passes even when the member's node did not take the new key

**Scenario.** The leader removes R; the network goes to version 6. Member V imports the v6 bundle, so V's phone mnet is at version 6. V then presses 「送出」 on V's own node, and the result is a failure:
- `[REQ_FAIL] 讀不到節點的網路狀態` (Unknown), `NotChanged`, `Broken`, `Unfinished`, or 360 s unclear;
- or V never presses it at all (T30).

`RekeyResult(member: true)` still shows, as fixed text (plan :429):
- 「這支手機是第 6 版」;
- `kMemberRekeyRule`: 「這只代表節點換成了這支手機有的版本。請把上面那一行（第 N 版）唸給隊長聽…」.

V reads 「第 6 版」 to the leader. The leader's 8.1 / 8.4 shows 「目前是第 6 版」, so it matches. Both believe V is done. V's node is still on v5 keys, which R knows, and nothing on the leader side can see V's node (X-m5, baseline). The page also tells V to read the bundle's 「更新到第 {to} 版」 right after the import, before any node send (plan :364, :366). The only check the leader gets is therefore about the phone, never about the node.

**Evidence.**
- The plan's member row makes the version line and the rule fixed for every outcome (plan :429).
- 「這只代表節點換成了…」 is false for every outcome except `current`.
- `MnetView.version` comes from the mnet record. It says nothing about the node (mrec.rs:93; updflow.rs:159).
- The leader's text asks only for 「請他們各自確認」, without saying what to confirm (plan :432).

This is the central question on the member side: the removed person keeps reaching V's node, and the one confirmation channel the plan adds tells both people it is fine.

**Fix (keep the T-M1 fail-closed rule, no new mechanism).**
1. In `RekeyResult(member: true)`, show the read-aloud block only when `rekeyEnd == current`. The block is 「節點 …xxxx 換好了；這支手機是第 N 版。請把這兩件事唸給隊長聽」.
2. For every other outcome, show 「這台節點還沒換好，先不要跟隊長說換好了；照上面那一句處理後再按一次送出」, and no version line to read out.
3. In 8.5, label the import-time sentence as a bundle check, for example 「先核對：你拿到的是第 {to} 版」. Keep it separate from the node confirmation.
4. Extend the leader text (X-m5 line) so the leader asks each member two things: whether every one of their nodes showed 「已是新密碼」 or 「已換成新密碼」, and which version they have.
5. Tests:
   - for every non-`current` outcome, no read-aloud block and the "not yet" line is present;
   - for `current`, the block is present;
   - negative control: show the block unconditionally → FAIL.

## MINOR

### Z-m1 — R8 "info failed / k9 missing → keep the old hint" has no mechanism, and the obvious implementation clears the hint (fail-open)

`page_info` is reset to None on every status read and stays None when info errors or is rate-limited. The round still ends as a normal `[STATUS] 狀態已更新` answer (owner.rs:949-965), so it counts as `Res.body`. `update_hint_of` then returns an empty line (rekey.rs:466-470). Under R8 「空的提示…等於清掉」, the 「這台還在舊密碼」 card disappears on any round where info failed. The old console also skips the record loop when `v.netId` is empty (nodes.dart:1166).

Also, "k9 missing → keep" (X-m8) cannot be told apart from "node current" through the frozen API: `update_hint_of` returns none in both cases (rekey.rs:474, :486).

Fix:
- state the rule as 「`StatusView.netId` 是空的 → 不更新 `hints`」, with a test (info error → the card stays; negative control: clear it → FAIL);
- drop the k9 claim, or say it is not detectable without a Rust change.

R9 limits the harm, which is why this is MINOR.

### Z-m2 — `NetView.version` contract versus the existing `net_summary` default

`net_summary` already swallows a netcfg decode failure with `unwrap_or_default()` for name and country (owner.rs:110). If `version` is added to that tuple, a damaged netcfg shows 「目前是第 0 版」. Plan §3.2 instead says the whole view returns an error. Fix: write the Rust side so that a netcfg error makes `net_summary` fail, or make `version` optional and show 「讀不到版本」. Add a Rust test with a record whose netcfg is corrupt.

### Z-m3 — The R17 source check "`confirm: false` only in NetRun" is vacuous

R17 says NetRun calls `sendUpdateFor` directly on the held session (plan :386-387), so `confirm: false` would appear nowhere. The real risk is a user-pressed entry passing `confirm: false` to `sendNewKey`.

Fix: reword the check to "no call of `sendNewKey` passes `confirm:`", and NetRun is the only `sendUpdateFor` caller besides `sendNewKey`. Negative control: add `confirm: false` at the hint card → FAIL.

### Z-m4 — 8.5's 「這支手機是第 N 版」 must be re-read after the import

8.5 shows `MnetView.version` at the page top (plan :366). The plan does not say it is re-read after the import `OfflineOp`. If it is not, the member reads the old number. That error goes the safe way (a false mismatch, so the bundle is regenerated), but it breaks the T-M1 check in the field. Fix: re-read `MnetView` after the import returns, and test that the top line changes from N to N+1.

### Z-m5 — No hint re-read after `sendNewKey` from the hint card

The old `_sendFromPage` re-reads the status page right after the send (nodes.dart:1141-1145). In the plan, the card waits for the next probe round. A stale "still old" card after success goes the safe way, but the old behaviour was a fresh read. Fix: after `sendNewKey` from the card or 「更多」, request one probe round, or say that the next round is accepted.

### Z-m6 — Clipboard clear after paste: rejected inputs

R4 says 「貼上之後一律 `clearClip()`」, and R5 rejects pastes over 300 000 characters before Rust sees them. It should say explicitly that the clear also happens on a rejected paste: too long, a parse failure, or a wrong kind of code. Otherwise an implementer may clear only on success. If the user pasted the wrong thing (for example a password from another app), it would stay on the clipboard. Add that case to the R4 test.

### Z-m7 — `OfflineReply.failed(line)` shows Rust text that can contain names

Rust refusal and answer lines can include member or network names: `invite::display_name`, and 「申請（名稱「…」）」 (member.rs:297). The plan already logs only `runtimeType`. T-P5-L should also feed a fake name through a `failed(line)` path and assert that the name does not appear in `debugPrint` or in todos. Today T-P5-L lists only codes, SAS and names in general (plan :608).

## Lifecycle and actor sweep (no further findings)

- **Remote attacker (intercepts codes in chat).**
  - Invite plus own request: stopped by the SAS check on another channel. `sasRule` is on both sides, and 7.9 adds a line.
  - Update bundle: encrypted to the recipient (ECDH Advance, rekey.rs:396-399), so it is useless to R.
- **Local app (clipboard / screen).**
  - The sensitive flag is set on Android 13+; the warning is always shown on Android 12 and where FLAG_SECURE fails.
  - The IME history limit is stated.
  - With FLAG_SECURE refused, the QR is hidden, which is the right call for the privacy asset.
- **Compromised peer.**
  - A malicious member forwarding a stale bundle: caught only by the verbal check, so it depends on Z-M1.
  - A compromised node: can only hide or show a hint, never take another node's secrets (see the table above).
- **Physical capture.** Covered by the residual risk in §5. `InviteHolds` stays in memory only.
- **Our own mistakes.**
  - R17 / R14 have source checks; see Z-m3 for the vacuous one.
  - The Rust–Dart sentence pins sit on both sides.
- **Crash, kill and restart.**
  - 8.4 results are lost, so the leader must send again to see the tick (fail-closed).
  - `removedThisRun` is lost, but the 8.1 line and the kRekeyDoneRule sentence are always shown (T-m3).
- **Network or BLE loss during send.** Gives `unclear`, which is not ticked.
- **Downgrade to PR 4.** Records are unchanged; the version fields are read-only.
