# Review P — #329 PR 5 plan v8 (round 8)

Reviewer P (independent; focus: security and fail-safe behaviour of the new parts). Read-only against worktree
`C:/src/Batman-329pr5` (main 2e18de6 + the uncommitted plan and the scanner diff in `QrScanActivity.kt`).
Baseline (§0) not re-reviewed; it is used only as a reference to check that behaviour moves faithfully.

## Summary

| | Count |
|---|---|
| BLOCKER | 0 |
| MAJOR | 2 |
| MINOR | 8 |

**Verdict: APPROVE-WITH-CHANGES.** Both MAJORs are cheap to fix and need no new mechanism: a text and contract fix
for the clipboard, and a narrower "done" claim on the member side.

Round 1–7 MAJORs I re-checked against source:
- G-M1 / H-M1: the hint is computed before `done` while `s` is alive. Checked prober.dart:122-127, :188-205 and owner.rs:1098-1101 (`update_hint` is `frb(sync)`, so the `cleaning` check followed by the call is atomic). Closed.
- K-M1: 8.3 has no "skip" control. Closed.
- L-M1 / M-M1: 8.4 / 8.5 use the positive signal, and the strings are verified at rekey.rs:447, :451, :452. Closed for the leader side. The member side has a new hole: see MAJOR-1.
- I-M1: every `node/` record is tried. Matches nodes.dart:1361-1372. Closed.

I also checked the 2.9 table against nodes.dart:1733-1770. Every member button has an entry, including 狀態頁 → the hint card and 再顯示申請.

---

## MAJOR

### MAJOR-1 — 8.5: on the member side, "已是新密碼 / 已換成新密碼" only means "same as this phone's mnet". The plan presents it as "換好", so a removed member can keep access through a member node with no warning

**Scenario (compromised peer = the removed member Eve; honest member Bob makes a human error).**
1. The leader removes Eve, which makes the network version v+1. The leader hands Bob the v+1 bundle in the chat.
2. The chat history also holds the bundle from the previous rekey (version v), which Bob already imported.
3. Bob pastes the old one into 8.5. `memberUpdatePrepare` returns `AlreadyImported` (mupdate.rs:298-299: `c.new.is_empty()` → `AlreadyImported`). The detail line reads 「[UPDATE] 已經匯入過」 (rekey.rs:402).
4. Bob presses 「送到節點」. In updflow, `self.version` is the mnet's v and the node's k9 is v, so the result is `End::AlreadyCurrent` (updflow.rs:256-258). Bob sees 「[UPDATED] 節點 …xxxx 已是新密碼」.
5. Plan 2.6 item 14 and the shared `kRekeyDoneRule` tell Bob that 「看到『已是新密碼』才算換好」. N-m4 adds a tick on that row.
6. Bob is told he is done. His node stays on v, the password Eve knows, so Eve keeps a way into the mesh.
7. Nobody notices: the leader's 「已交出」 is a memo only (T15), and the leader cannot read Bob's node.

The same false "done" happens when Bob missed a whole rekey. Example: Bob's mnet is at v-1 and he pastes the v bundle while the leader is at v+1. The result is `Advance`, then `Updated` 「已換成新密碼」, and the row gets a tick, but the node is still one version behind.

**Why this is new in PR 5.** The Rust lines are baseline. The new parts are the rule text, which turns 「已是新密碼」 into "換好", and the green tick (plan :373-375, :410).
- On the leader side (8.4) the claim is true, because the leader's net record is the source of truth.
- On the member side, the phone cannot know the leader's latest version.
- So v8 makes a fail-open claim on exactly the path the brief asks about: can a removed member keep access unnoticed?

**Evidence:** mupdate.rs:280-281, :298-299; updflow.rs:256-258, :316-317; rekey.rs:400-402, :447, :451; plan :373-375, :410-411.

**Fix (no new mechanism):**
- (a) On 8.5 the tick, and any "換好" wording, only follow a send made after an import on this page that returned `Advance` or `AddSecrets`.
- (b) After `AlreadyImported`, show one fixed line and no tick: 「這份更新包之前已經匯入過；如果隊長剛換過密碼，請確認你貼的是隊長這次給的那一份」.
- (c) The member variant of the rule says what is true: 「『已是新密碼』只表示節點和你貼上的更新包一致；請用電話和隊長確認版本」. The Rust detail 「[UPDATE] 更新到第 N 版」 (rekey.rs:400) already gives N to read out. 8.4 can show the same N from the leader's record.
- Test: paste a bundle that gives `AlreadyImported`, then send and get `AlreadyCurrent` → no tick and the warning line is shown. Negative control: tick on any `AlreadyCurrent` → FAIL.

### MAJOR-2 — The v8 clipboard rule contradicts the paste-then-clear guard: received codes are no longer cleared from the clipboard

**The contradiction.**
- §0 item 3, 2.2 (:155), and §5 (:612) promise that the clipboard is cleared right after a paste, the `_takeClipboard` behaviour (nodes.dart:728-732 clears unconditionally with `setData('')`; P10).
- 2.2 (:151) says the paste path now clears with `clearClip`.
- 2.1 (:129, v8 N-m8) defines `clearClip` as clearing only when the clipboard still holds the code that this app last copied, compared against Kotlin's memory.
- A pasted code was copied by the messaging app, not by us. Under 2.1, `clearClip` therefore never clears it.

**Scenario (local unprivileged app or clipboard reader; the Android 13+ clipboard preview).**
- A member pastes an approval code. The approval carries the signed member list (approve.rs:305-319, `members`), so team names and fingerprints are in it.
- A leader pastes a join request, which carries the joining node's name and the owner's public keys.
- After the paste, the text stays in the primary clip. Before this change, it was cleared.
- This is a regression of moved baseline behaviour, and of a guard that §5 lists. The plan's logging rules refuse to write the same data (names, network names) into a log line.
- It is not a key leak: per 219 §7.6 the codes carry no plaintext secrets, which is why this is MAJOR and not a BLOCKER.

**Fix:** split the contract into two methods.
- `clearOwnCopy()`: CodeView's 「清除剪貼簿」 and the leave reminder; only our own clip (N-m8 stays).
- `clearAfterPaste(text)`: clear when the primary clip still equals the text just read, which covers the pasted text itself; or clear unconditionally, as the old `_takeClipboard` did.

Then fix the 2.2 / §5 wording, and add the test: paste text that another app placed → the clipboard is empty afterwards. Negative control: the paste path uses own-clip-only → FAIL.

---

## MINOR

**m1 — 8.4 send is not bound to the page's network.**
- Each row runs `info → infoNetId → net/<id> → sendUpdateFor` (plan :365). `infoNetId` is whatever key 10 the node reports (rekey.rs:360-361).
- If the node is now in another network Y that this phone also owns, Rust sends Y's record and answers relative to Y, for example 「已是新密碼」. Row X then gets a tick.
- This is not a direct exposure: a node in Y holds no X password. But the tick is wrong.
- Fix:
  - require `infoNetId == the page's netId`, else 「這台在別的網路」, as 8.5 already does (:413);
  - match the tick on the full expected string, including the row's `last4`, so a tick never lands on the wrong row when `last4` values collide.

**m2 — §5 cites the wrong place for the key-10 validation.**
- §5 says the path is limited to `net/<16-byte hex>` (owner.rs:2260). That filter exists only for `StatusView.net_id`, which the hint uses.
- The send paths use `info_net_id`, which has no length check (rekey.rs:361). It is still hex-only, so there is no path traversal.
- Fix: correct the sentence, or add the length check in Dart before building `rel`.

**m3 — The node page's 「把新密碼送給節點」 result has no `kRekeyDoneRule`.**
- That route (2.7 :449) is the third place a send result is shown, and it is where the hint card's button leads.
- Without the rule there, the old implicit signal, "the hint card went away", is what users see on this route. The L-M1 fail-open survives here.
- Fix: show the same constant, and the same neutral styling, under that result. MAJOR-1's member wording also applies when the record is an mnet.

**m4 — Homoglyph names defeat the new full-owner same-name check (2.6 item 1, :308).**
- Rust rejects Cc / Cf characters (invite.rs:101-118, `check_name`), so zero-width and bidi tricks are blocked.
- But 「Bob」 with Latin letters and 「Воb」 with Cyrillic letters compare unequal, so no 「另有同名」 line appears.
- A malicious member who got two identities approved can survive removing "Bob". This is the D-M2 scenario.
- Fix: compare a confusable skeleton (or at least NFKC + case fold + a Latin/Cyrillic/Greek fold) for the warning. The check is for display only, so a false positive costs nothing.

**m5 — Revocation outcomes are incomplete in 2.4.**
- `startBundle` is not in the per-operation list. Its hex is lost and it writes nothing, so it should say 「沒有產生，請再按一次」, not "結果不明".
- On the remove path "version +1 → 已經移除 → 8.4", the plan does not say that `RemoveTicks.removed(netId)` is called. Without it, the 8.1 line 「還有 N 位隊員沒交更新包」 never appears for that removal.
- State both explicitly.

**m6 — The own-clip comparison: memory and focus.**
- Kotlin keeps the last copied code (up to about 262k characters for a bundle) in memory indefinitely. Keep a SHA-256 plus the `ClipDescription` timestamp instead.
- On Android 10+, `getPrimaryClip()` returns null without input focus. Define null as 「清除失敗」, never as silently "not ours".

**m7 — The QR rendering itself is not validated anywhere.**
- R-8 measured ZXing output on a PC monitor.
- CodeView draws 133 modules (v27 + quiet zone) across 「螢幕寬減 32」 logical pixels. That gives a non-integer module size in device pixels, and anti-aliased seams.
- The S20 cannot be screenshotted (FLAG_SECURE) and there is no second phone, so the on-device QR is never checked.
- Fix:
  - snap the module size to whole device pixels (`devicePixelRatio`) and paint with `isAntiAlias = false`;
  - add a widget golden that renders CodeView off-screen and decodes it, for example with ZXing in the JVM test, for v16 / v26 / v27.

**m8 — The hint opens records only while the page is open, but the page's lifetime has no upper bound.**
- J-m2 cut the exposure to "the open node page". A leader who leaves the node page open in the field still decrypts `net/<id>` (net_root, SAE) on every read round. Dart cannot zero those copies.
- This is acceptable per H-m8, but list it in §5 under physical capture with the actual read cadence, so the residual risk is stated rather than implied.

---

## Checked, no finding

Each item below was verified against the source or the plan.

**Hint**
- Gated on devTrust, `netKnown`, and the open node page.
- `update_hint` is sync (owner.rs:1098), and the `cleaning` check is sound.
- A wrong or missing hint never counts as "done" on 8.4.
- The hint path catches errors locally, so the `$e` logging at prober.dart:174 / :185 is not reached.

**OfflineOp revoke**
- `_revoke` (lease.dart:140-149) sets `_ended`. `RecordWriter._check` (record_writer.dart:27-33) then refuses every later write, which is fail-closed.
- Only a `writeCas` that had already passed `_check` can still land. The plan's "結果不明" plus the re-read after `work` ends covers it.
- The two-write import (mnet, then delete mpend) is judged on mnet, and the mpend todo is suppressed by A-m6.
- No signing key needs user authentication (no `setUserAuthentication*` in the Kotlin sources), so 60 s is not hit by a biometric prompt.

**QR limit**
- Input `[0-9A-F]{1,4096}` fits v40-L alphanumeric (4296), so the >27 test holds.
- The size and bits checks fail closed, and copy stays available.
- The scanner change matches the plan (the diff in QrScanActivity.kt).

**SecureScreen fallback**
- The ref-counted `_held` (secure_screen.dart:21-37) handles CodeView and SasShowView on one page.
- `onError → false` hides the QR, which is fail-closed. Showing the SAS is fine per D6.

**Gates**
- `main.dart:104-107` disables the app on a flavor/core mismatch, so the startup `AppLink.devTrust` is a sound single source.
- `request_send_update` and `request_info` have no `dev_gate` (owner.rs:1027, :1041), so T-S5 must cover them, and it does (§6 step 8).

**Logging**
- Lease names reach `unsavedTodos` (lease.dart:144) and `debugPrint` (op_session.dart:121). The constant-name rule (N-m5) plus T-P5-L covers both.
- `RecordWriter` logs only `rel` (a network id, no name).

**Remote interception**
- Invite, request, approval and bundle carry no plaintext secret (219 §7.6, §7.4). Integrity rests on SAS over another channel; 7.9 adds 「不要用傳邀請的同一個聊天室核對」.
- 「放棄申請」's claim that a later approval cannot be imported matches 254-app-member-join §3 (no mpend and no mnet → 「找不到申請」).
