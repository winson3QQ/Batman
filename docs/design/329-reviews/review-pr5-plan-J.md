# #329 PR 5 plan v5 — review J (round 5)

Reviewer J. Focus: security and fail-safe behaviour of the new parts. I reviewed the whole v5 document. Every claim below was checked against the source in `C:/src/Batman-329pr5` (main 2e18de6). The baseline in §0 is not re-reviewed.

Verdict: **APPROVE-WITH-CHANGES**: 0 BLOCKER, 1 MAJOR, 9 MINOR.

## Earlier MAJORs, checked against source

| Item | Status | Evidence |
|---|---|---|
| G-M1 / H-M1 (hint after `done`) | Closed in design. One remaining hole is in m1. | prober.dart:122-127 is the answer step, inside `run`. The session is disposed only in the cleanup at :188-203, after `result.future`. Putting an `await` before `done` in the answer case keeps `s` alive, except on the paths in m1. |
| H-M2 (`[REQ_FAIL]` counted as sent; no version) | (a) and (b) closed. A new gap: `Applying` (M1). | rekey.rs:430-458: `[UPDATED]` covers `AlreadyCurrent`, `Updated` **and** `Applying`. |
| F-M1 (8.4 drops nodes it cannot read) | Closed in principle. The mapping it relies on does not exist (m3). | rekey.rs:47-52: `PersonNode` has no device id. |
| E-M1 (hint card hidden in the network group) | Closed. | node_page.dart:79-87: the group is drawn only for `nodeState == 1` or a pending net. The card under StatusHero is right. |
| E-M2 (mnet-only phone has no join) | Closed. | node_page.dart:81 and net_pages.dart:352-360 are as the plan describes. |
| D-M2 (fingerprint / same name) | Closed. | rekey.rs:55-65 and :94-96 (`fpr`, `same_name`). The plan's Dart-side check on the full owner is stronger than Rust's. |
| C-M1 / C-M2 / D-M3 (persistent buttons) | Closed. | I checked §2.9 against nodes.dart:1733-1770 one button at a time: 加入網路, 檢查網路 (PR 3), 忘記加入中的節點, 狀態頁, 把新密碼送給節點, 隊員名單／移除, 產生更新包, 貼上更新包, 邀請隊員, 貼上隊員的申請, 貼上邀請, 貼上同意碼, 申請加入, 再顯示申請, 軟體更新 (PR 4). Every member button has a new entry. Nothing is missing. |
| A-M3 / B-M2 (QR size) | Closed. | The limit is set by the version the encoder returns, and paste has no limit at 4096. |

## MAJOR

### M1. 8.4 counts `Applying` as 「已送出」, so a node that has not switched to the new key drops out of the "N nodes still on the old key" warning

- **Scenario.** The leader removes a member and then opens 8.4. They send the new key to a relay node, and the node answers with `info` key 11 = true. Rust ends with `End::Applying` and the text `[UPDATED] 節點 …x 正在套用新密碼，稍後再看狀態頁`. The plan's rule is "starts with `[UPDATED]` → 已送出". So the row turns 已送出, and the top line drops it from N. When N reaches 0, the sentence "被移除的人仍連得上它們" also disappears. The leader walks away. The node is a mountain relay the leader may never read again, so the hint card on the node page never gets a chance to show.
- **Evidence.**
  - updflow.rs:316: `JoinState::Applied { save_pending: true } => End::Applying`. This branch is taken **before**, and independent of, the `k9 == self.version` check on the next line. `Applying` therefore says nothing about the node's version.
  - flow.rs:144: `save_pending` = key 11 true, "saved at the node's next boot".
  - rekey.rs:452: Rust's own text tells the user to check the status page later.
  - The project rule "a failed change restores the previous state" makes "the apply fails and the node goes back to the old key" a designed path. I have **not** reproduced a rollback after `Applying` on a node (⚠️ inferred). But the point does not depend on it: `Applying` is not a confirmation of version V.
- **Why it matters.** The "N nodes not on version V" line exists to close F-M1, the case where a removed member keeps access unnoticed. This hole sits in the same guard. Elsewhere the plan says, in its own words, that the page must not claim more than Rust knows.
- **Fix (small).**
  - Give 8.4 three outcomes. `Updated` and `AlreadyCurrent` count as 已送出. `Applying` gets its own state, 「正在套用（還沒確認）」, which **stays in N** until a later read shows `k9 == V`. That later read can be the node's next NodeLink read with the hint empty, or a re-send that returns `AlreadyCurrent`.
  - Match on the end kind, not on the text prefix. If that needs a Rust change, which is not allowed here, match the exact `Applying` text as a fallback, the way PR 4 matches lines.
  - Negative control: a fake answer `[UPDATED] 節點 …x 正在套用新密碼…` must leave the row counted in N. With the plain prefix rule the test FAILs.

## MINOR

### m1. Prober: "cleanup always comes after the hint" is not true on every path, and the 20 s answer timer keeps running during the hint

- The plan says the session is disposed only after the hint finishes or times out (§2.3). Three paths break that while the hint `await` is pending:
  - `cancelled` fires (prober.dart:83), for example `NodeLink._abort` when a lease is taken (node_link.dart:563-572);
  - the `answer` Timer fires (:172, 20 s from msg2);
  - a node sends one more frame, which goes through `inbox.handle` → `run` → `ended` / `failed`.
- On each of these paths `done` completes first and the cleanup runs. The cleanup awaits `sub.cancel()` (:195) before `s.dispose()`. In that gap a late `openNet` can still reach `updateHint` on a live session and call `onHint` for an attempt that ended `noResponse` or `broken`. Each of these cases is only display, and Dart's single thread rules out a use-after-free. But the ownership text is wrong, and the 2 s can turn a good read into `broken` when the status read itself took more than 18 s.
- **Fix.**
  - Cancel `answer` when the answer step is reached, since the read is complete.
  - Call `onHint` only from the answer case, immediately before its own `done`, and only if `!result.isCompleted`.
  - Test: complete `cancelled` while `openNet` is pending, and assert that no `onHint` follows.

### m2. The net record plaintext (SAE, `net_root`) is now opened on every successful automatic read

- netrec.rs:2-3 and :18: the record holds SAE and `net_root`. prober.dart:2-4: plaintext from the platform channel cannot be zeroed in Dart.
- Before this change, the net plaintext entered the Dart heap on user actions and on `NetIndex` recomputes. With v5 it also enters on every read round of every network node in range. Physical capture of a rooted or running phone with a heap dump now finds the team secret far more often.
- H-m8 rightly rejects a plaintext cache. A cheap fix that keeps the Rust entry unchanged:
  - compute the hint only for a node whose `NodePage` is on screen (NodeLink already knows what is on screen, node_link.dart:4), or on that page's next read;
  - list this as an asset change in §5.

### m3. `MemberView.deviceId` does not exist, so the 8.4 mapping cannot be built as written

- rekey.rs:47-52: `PersonNode { last4, dac_hash, state }` has no device id. No `MemberView` exists in the bridge (grep).
- The only bridge entry that gives own nodes with a full device id is `remove_own_nodes(record, owner_pub, person, node)` (rekey.rs:109-115 → batman-proto rekey.rs:86-93). It is `dev_gate`d, and it **drops members whose `device_id` is None** (`filter_map`). `member_base` creates entries without one (netrec.rs:212).
- If the implementer guesses, they will match on `last4`, which is the thing G-m4 / H-m4 rejected.
- **Fix.** Name the source. Call `removeOwnNodes(person: <own owner hex>, node: "")`: target `Person(me)`, so every own node passes the filter at :91. Take the union with `netPeople` isSelf by `dac_hash`, so that an entry without a device id still shows as 「這支手機沒有這台的紀錄」 and never disappears. Test this with a record whose own entry lacks key 6.

### m4. After the 60 s revoke, 「已經完成」 is wrong for operations whose result is a code, or that lead somewhere next

- `makeInvite` and `approve` write PersistNet, and only then is the hex handed over (member.rs `op_step`). If the revoke comes after the write lands but before the hex returns, the record version changed and the page says 「已經完成」. But the leader has **no** code to send. The member waits, and the leader thinks they are done.
- For `startRemove`, 「已經完成」 must still go to 8.4 and set `removedThisRun`. Otherwise the leader gets no bundle flow and no "the removed person can still connect" line.
- For 放棄申請, "version changed" should be "the record is gone".
- **Fix.** Give a per-operation result after a revoke:
  - invite / approve: 「已存好，但碼沒有拿到 — 請再按一次產生」. Re-approving returns a duplicate note with a code (nodes.dart:791).
  - remove: go on to 8.4 exactly as on success.
  - abandon: the record is gone means done.
  - Add a test for each.

### m5. 8.4 top line: 「沒換到第 V 版」 overclaims when 8.4 is opened from 「產生更新包」

- With no removal in this run, every own node starts as 「還沒送」. Nodes that were updated in an earlier run are counted as "not on V".
- The direction is safe, but the sentence states as fact something the app does not know. Use 「這次開 App 還沒確認送到第 V 版的節點：N 台」.
- Also state that a send made from the node page (the 「更多」 entry or the hint card) does not mark 8.4. That keeps one writer, but say it.

### m6. The member side (8.5) has no matching "not yet updated" list built from the record

- 8.5 lists the member's nodes by reading `info` on each `node/` record (§2.6-14). The phone cannot tell whether a node it cannot read belongs to this network. There is no top line, and nothing persists.
- A member's node left on the old key is the same leak as F-M1. The mnet carries the signed member list, and `owner_pub ==` this phone gives the member's own nodes.
- **Fix.** Build the 8.5 list from the mnet, the same way as 8.4, with the same three states, M1's `Applying` rule, and the same top line.

### m7. Two owners of `devTrust`

- main.dart:104-107 already reads the flavor once and disables the whole app when Rust and the flavor disagree. v5 adds `AppLink.devTrust`, "read once at start" from the platform: a second reader of the same fact, with its own failure path.
- Set `AppLink.devTrust` from main.dart's value, after `agree`, as the single owner. Fail-closed stays false until then (G-m6).

### m8. Logging guard covers Dart only

- T-P5-L captures `debugPrint` and the NodeLink trace. The new Kotlin methods (`qrMatrix`, `copyCode`, `clearClip`) are only promised not to log.
- Add the existing style of source lint (MainActivityKeyUseLintTest) that fails on any `Log.` or `println` in the new handlers. Negative control: add `Log.d(TAG, text)` and the lint FAILs.

### m9. A compromised node chooses which of the phone's records the prober opens

- `netId` comes from the node's own `info` key 10. A node can name any network the phone holds, for example a phone that is a leader in A and a member in B. The phone then opens that record. The result is only display, such as `NOT_LISTED` (rekey.rs:490-492), and nothing is sent.
- This is acceptable, but record it in §5 (attack-surface delta). It ties in with m2: the node also controls how often the record is opened.

## Things I checked and found sound

- **RecordWriter after `Lease.revoke()`.** `_revoke` sets `_ended`, gives the token back, and adds the todo (lease.dart:140-149). `RecordWriter._check` then refuses (record_writer.dart:27-33), and `lease.run` throws (lease.dart:47). A `writeCas` that has already passed the check can still land. The plan says so, and CAS keeps a new holder safe. A later `hold()` cancel or `release()` after a revoke does nothing (`_ended`). `signAdmin` has no user-auth prompt (no `UserAuthentication` / BiometricPrompt in the Kotlin keystore), so 60 s is not hit by a waiting user.
- **SecureScreen fallback.** Today `false` shows a fixed sentence and `null` shows nothing (secure_screen.dart:42-46). An optional `fallback` keeps both, and a channel error maps to `false` (:30), so it fails closed. Showing only "copy text" on such phones is a stated choice: the approval and bundle are ECDH-sealed (the 8.5 / 7.10 `ecdh` step), so the clipboard holds no plaintext secret.
- **Clipboard.** minSdk is 31 (build.gradle.kts:39), so `clearPrimaryClip` is always available. `EXTRA_IS_SENSITIVE` takes effect on Android 13+ only, as the plan says. Background clipboard reads by other apps are blocked from Android 10, so the remaining reader is the IME, which the plan names.
- **QR version limit.** It is decided from `QRCode.version`, with size and bit-length checked in Dart, and failure falls back to copy only. No secret goes into the QR.
- **Gates.** The hint is never computed in a field build (with a test). `request_send_update` has no `dev_gate` (owner.rs:1041), and the plan lists it under T-S5. Every new entry is devTrust only.
- **D10.** join2flow.rs:76-77 has `NotThisNode`. `memberEntryOf` matches the entry node by `last4` (member_ui.dart:256), and Rust still refuses a wrong node, so a `last4` collision cannot write anything.

## Not verified

- ⚠️ Whether a node in `save_pending` can come back on the old version (M1). This is inferred from flow.rs:144 and updflow.rs:316, not reproduced.
- ⚠️ How often NodeLink reads in the foreground (it scales m2). I did not measure it.
