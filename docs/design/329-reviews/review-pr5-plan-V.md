# Review V — #329 PR 5 plan v11 (round 11)

Reviewer V. Focus: security and fail-safe behaviour of the new parts (R14 / `RekeyResult` / NetRun D12, R6–R9 hint and
prober.dart:83, R10–R12 `OfflineOp` and revoke, R1–R4 QR / SecureScreen / clipboard, R15 / R16 gates, logging).
Source checked read-only in `C:/src/Batman-329pr5` (main 2e18de6 + the working-tree QrScanActivity change).

**Verdict: APPROVE-WITH-CHANGES. 0 BLOCKER / 1 MAJOR / 9 MINOR.**

## What I checked and found to hold (with evidence)

- **R14 success sentences.** `update_text` (bridge rekey.rs:430-458) has exactly two `[UPDATED]` success sentences, `AlreadyCurrent` :447 and `Updated` :451. `Applying` :452 also starts with `[UPDATED]`. `last4` comes from the phone's node record (owner.rs:717), not from the node. `Updated` is decided only when `k9 == self.version` and `save_pending` is false (updflow.rs:316-318). `AlreadyCurrent` is decided only when `k9 == cur` (:257-259). So the anchored match plus "only `current` ticks" is a sound positive signal.
- **T-M2 / D12.** NetRun's only `[UPDATED]` prefix test is net_run.dart:302. A grep of `lib/` finds no other prefix test outside nodes.dart. The allowlist source check covers it.
- **T-M1 premise.** mupdate.rs:263-268 and :293-299 accept any genuine, newer-than-stored bundle addressed to this phone. Member-side "never tick" is the right fail-closed choice.
- **R16 / NotThisNode.** join2flow.rs:376-383 refuses before any write (the first request is `settings/get`). The last-4 lookup is fail-closed.
- **Gates.** `request_member_join` and `request_joinreq` have `dev_gate` (owner.rs:1255, :1284). `request_send_update` and `request_info` do not (owner.rs:1027, :1041), so the T-S5 Dart-gate test is required, as the plan says. `AppLink.devTrust` comes from main.dart:104-107, after the flavor/library agreement check.
- **R10–R12.** `RecordWriter._check` refuses a revoked or non-current lease before the store call (record_writer.dart:27-33). `_revoke` ends the lease, adds the todo and releases it (lease.dart:140-149). A write already in flight when revoke fires can still land; the R12 recheck table covers that case.
- **R7 / prober.** The `cleaning` check followed by a synchronous `updateHint` is atomic on Dart's single isolate. Disposal happens only after `result.future` (prober.dart:188-203). The :83 change returns a real `StatusView`, never a planted result.
- **R3.** The default `SecureScreen` behaviour is unchanged when no `fallback` is given (secure_screen.dart:42-46). `sasRule` is on both `SasConfirmView` and `SasShowView` (member_ui.dart:35, :70, :97), so the leader is also told to compare over another channel.
- **Logging.** The existing log sites log types, record-path prefixes or counts only (owner_console.dart:174-373; op_session.dart:123, :183). No new path in the plan logs a reply text.
- **§2.12.** It matches nodes.dart:1733-1770 button for button.
- **Appendix A.** I grepped the plan for the terms of the old rules ("消失", "略過", "已送出", `clearOwnClip`, `starts('[UPDATED]`). Each hit is in appendix A, or is the R9 / §2.7 wording that now states the opposite rule. I found no stale rule left in the body.

## MAJOR

### V-M1 — The plan depends on network version numbers that no frozen Rust entry gives to Dart. The leader never sees the current version, so the T-M1 fix cannot be carried out.

**Scenario (compromised peer).**
1. Member M is removed. The network goes from version 5 to version 6.
2. M still holds a genuine v5 bundle that was made for member X earlier and that X never imported (for example, it was posted in a group chat).
3. M forwards it to X.
4. X pastes it. Rust replies `Advance`, "[UPDATE] 更新到第 5 版" (rekey.rs:400). X sends it to his node, which answers `Updated`.
5. The plan's only defence (T-M1, `kMemberRekeyRule`) is "read 第 N 版 to the leader, who confirms it is the latest". But nothing in the new UI shows the leader that the current version is 6. X's node stays on v5, which M knows, and nobody notices.

**Evidence.**
- `NetView` has no version field (owner.rs:97-104), and neither does `RecipientView` (rekey.rs:303-310).
- The bundle answer gives no version (rekey.rs:232).
- The only leader-side text with the version is the `Committed` line "[REKEY] 已換成第 {version} 版…" (rekey.rs:208). The plan's 8.3 → `OfflineOp('移除隊員')` → `RemoveTicks.removed` → 8.4 path never says this line is shown. Even if it were shown, it is gone after the leader leaves 8.4 or the app is killed. 8.4 re-entered from "隊伍與邀請" → "產生更新包" has no version at all.
- §0 says "Rust 入口全部不改", so Dart cannot decode the version itself.

**The same missing data also breaks other rules.**
- **R12 table:**
  - remove needs "網路版本加了 1";
  - 匯入同意 needs "mnet 的網路與版本符合這次的碼" (`MnetView` member.rs:303-309 has no version; `approval_net_id` member.rs:219 returns the id only);
  - 匯入更新包 needs "mnet 的版本符合".
- **D11:** it needs "沒有同一個 id、版本比它新的 mnet". The mpend version exists only inside the netcfg Sign1 (mrec.rs:45-53), and §2.11 `mpendIds` / `mnets` carry no version.

As written, these cannot be built. An implementer will guess, for example "mnet generation changed ⇒ 已經匯入". That guess can claim a success that did not happen.

**Fix.**
1. Allow one additive, read-only Rust field (`version` on `NetView` and `MnetView`, and on the mpend view if D11 stays), and list it in §0 under the changes.
2. Show "目前是第 N 版" as a fixed line at the top of 8.4 and 8.1, from the record read under the lease.
3. Add a test that the 8.4 header shows the record's version, with a negative control that removes the line → FAIL.
4. If the Rust change is refused: at least show the `Committed` line on 8.4, keep its number in `RemoveTicks`, and say plainly on 8.4 re-entry that the number is unavailable. The T-M1 text must then not promise a check the leader cannot make.
5. R12 judgments:
   - remove: "target not in `NetView.members`" only;
   - the two imports: re-run `memberImportPrepare` / `memberUpdatePrepare` on the re-read record and treat `AlreadyImported` as "已經匯入", which needs no version.
6. D11: use the new field or drop the condition.

## MINOR

### V-m1 — `rekeyEnd(line)` ignores `ConsoleReply.kind` and has no stated default
- The old `starts()` required `kind == answer` (owner_console.dart:123). `rekeyEnd` takes only the text.
- It does not say what these lines map to:
  - `notSentLine`;
  - `loginLine(...)`;
  - "這個操作已經停止。" (net_run.dart:217);
  - the Dart `[REQ_FAIL] 操作沒有成功：…` (net_run.dart:203, owner_console.dart:424).
- The class `unfinished` is listed, but the rules map every `[REQ_FAIL]` line to `failed`. That includes the `Unfinished` line (rekey.rs:445), so `unfinished` can never occur.
- **Fix:**
  - take the `ConsoleReply` (kind + text);
  - require `kind == answer` for `current` / `applying`;
  - make every unmatched input `failed`;
  - either define `unfinished` by its anchored sentence or delete it;
  - add a test case for each non-answer kind.

### V-m2 — NetRun's row state for `applying` (D12) is not specified
- If the implementer routes `applying` through `_failed`, the row shows `RowState.failed` and the "繼續下一台 / 停" dialog appears (net_run.dart:229-240).
- Worse, `canRetry` is true for a join row (:79), so "再試這一台" runs the **whole join again** on a node that is already applied. What a second join does on an applied node is not in the plan and I did not verify it.
- **Fix:**
  - `applying` keeps `RowState.ok` with the note, and nothing is retried;
  - `failed` / `unclear` keep today's `_failed` path;
  - add a test that an `Applying` row is ok, has the note and offers no "再試這一台".

### V-m3 — R8: an info read that fails clears the "還在舊密碼" card
- `update_hint_of` returns `""` when `page_info` is None (rekey.rs:468-469). `page_info` is None after an info error (owner.rs:960-963) and on the rate-limited answer (owner.rs:940-941).
- R8 treats `""` as "clear", which contradicts its own rule "算失敗或逾時的那一輪保留舊值".
- Field effect: on one bad radio round the warning card disappears. R9 and `kRekeyDoneRule` limit the harm, but the card is still the main reminder.
- **Fix:**
  - call `onHint` only when the answer's `StatusView` has a non-empty `net_id` (owner.rs:2251) and is fresh;
  - otherwise keep the old value;
  - test: a failed info round keeps the card; negative control: clear on `""` → FAIL.

### V-m4 — R16's "ends with「需要新的邀請」" misses `NoEntry`
- owner.rs:584 is "…需要新的邀請（手機裡已沒有這台節點的加入資料）". It ends with "）", so a suffix match never fires for the case the plan cites first.
- **Fix:**
  - match either both literal forms (an anchored match, pinned by a Rust test as in R14), or `contains`;
  - better, drive the button from `MnetView.entry_state == ""` re-read after the reply.

### V-m5 — R16: the node-page entry for an mnet whose entry is gone is not reachable
- The member branch appears only on "the entry node by last 4". After `NoEntry` or a definite failure, `device_last4` is `""` (member.rs:316-324), so no node page shows the branch.
- R16 nevertheless says the same sentence is shown "從節點頁…進來".
- **Fix:** state that the node page has no member branch then, and that the sentence appears from home row 6 and "隊伍與邀請" only. Or say which node page shows it.

### V-m6 — R12: the recheck needs a new lease, but its behaviour when the lease is busy is not stated
- After a revoke, another operation can take the lease (lease.dart:124-129) before the stuck `work` finally returns.
- **Fix:** if the recheck cannot acquire the lease, show "結果不明" and leave the todo in place, never a success. Add a test.

### V-m7 — `Lease.revoke({todo})` is a new public method on a security-relevant object
- Any holder of a `Lease` could call it. It is harmless today, but it is a new way to end another flow's lease.
- **Fix:** mark it `@internal` / `@visibleForTesting` with a single caller (`OfflineOp`), and lock that with a source check, the same way as `rekeyEnd`.

### V-m8 — 8.5 "讀不到的也列" does not say from which set
- "手機在這個網路裡的每台節點" with unread nodes included can only come from the phone's node records. It does not say whether those are filtered by the mnet's own entries (`me` / key 10 dac hashes).
- If it means all node records, unrelated nodes get a "送出" button. They fail closed on `infoNetId`, but the list is confusing.
- **Fix:** list the phone's node records whose last 4 matches the mnet's own entry or key-10 nodes. Put the others under "沒讀到".

### V-m9 — The R3 QR fallback has no stated threat
- §5 says the codes are not secret, yet the QR is hidden on a phone that cannot set FLAG_SECURE, while "複製文字" (more exposed: clipboard, keyboard history) stays.
- This is not a hole, but the rule has no stated threat. That invites a future change that removes the copy path too, or one that removes the QR guard.
- **Fix:** write one line on why the QR is withheld (for example, a screen recorder captures a scannable code without the user acting), or show the QR like the SAS (D6).

## Lifecycle / actor sweep (no further findings)

- **Remote attacker who intercepts an invite:** the SAS is checked on another channel on both sides (sasRule). 7.7 does not claim the invite is revoked (D7).
- **Local unprivileged app:**
  - there is no auto-copy;
  - the clipboard is always cleared after a paste;
  - the sensitive flag is set;
  - the keyboard-history residue is stated.
- **Compromised node:**
  - k10 only picks a 16-byte hex path (owner.rs:2251);
  - `sendUpdateFor` sends only to a listed, DAC-verified node (updflow `secrets_payload` to `entry.ecdh_pub`).
- **Physical capture:** this residual risk is stated in §5.
- **Crash / kill:** the in-memory ticks, holds and hints are lost, and every "done" claim falls back to a fresh positive signal (fail-closed).
- **Downgrade:** the record formats do not change, so there is no impact.
