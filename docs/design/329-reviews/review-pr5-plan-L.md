# Review L — #329 PR 5 plan v6 (round 6)

Reviewer L. Focus: security and fail-safe behaviour of the new parts (the hint, the simplified 8.4 / 8.5, OfflineOp + `Lease.revoke`, the QR limit, the SecureScreen fallback, the clipboard, gates and logging). Whole plan read (`docs/design/329-pr5-plan.md`, 833 lines). Source checked in `C:/src/Batman-329pr5` (main 2e18de6). Baseline (§0) was not re-reviewed; I used it only to check that the plan moves it faithfully.

Counts: **0 BLOCKER / 1 MAJOR / 6 MINOR**. Verdict at the end.

## Closure of earlier MAJORs (checked against source)

- I-M1 (8.3 reads every own node): closed. `_nodes = listNodes(...)` (nodes.dart:170-173) holds every `node/` record, and 2.6 item 9 now tries each one.
- J-M1 / H-M2 (the 8.4 "已送出" mechanism): closed by removing it. But the replacement, "the hint card is the only signal", opens L-M1 below.
- G-M1 / H-M1 (the hint computed after dispose): closed in the design. The hint is awaited inside the `answer` case of `run` (prober.dart:122-127), before `done`. Dispose happens only in the cleanup after `result.future` (prober.dart:188-203). `updateHint` is `frb(sync)` (owner.rs:1099), so the `cleaning` check followed by the call cannot be interleaved by Dart.
- 2.9 against nodes.dart:1733-1770: every member button maps to a new entry (加入網路 :1735, 狀態頁 hint :1744, 把新密碼送給節點 :1745, 隊員名單 :1750, 產生更新包 :1751, 貼上更新包 :1752, 邀請隊員 :1757, the three paste buttons :1758-1760, 申請加入 :1763-1766, 再顯示申請 :1768). The forget dialog's 「排除這台」 (:1277-1283) is also covered. 「檢查網路」 and 「軟體更新」 are not member buttons. Nothing is missing.

## MAJOR

### L-M1 — 8.4 / 8.5 treat "the hint card is gone" as proof that a node changed key. A missing card also means "could not tell", so a removed member keeps access through a node the leader thinks is done (fail-open)

**What the plan says.** 2.6 item 10 (plan :350-354) and item 14 (:386) have the leader or the member send the update, show Rust's line, and then say:

> 「送出之後，請到每台的節點頁確認『這台還在舊密碼』那一行已經消失。」

So the absence of the card is the confirmation. Hints are also cleared when the node page is left (:201). Failures and timeouts keep the old value (:191), but that old value was already cleared when the user left the page.

**Why no card does not mean "updated".** `update_hint_of` (bridge rekey.rs:466-486) returns the *same* empty result for "up to date" and for every "can't tell" case:

- `page_info` is None. owner.rs:960-963 sets `page_info = None` on any `info` error, E_RATE included. A fresh probe session has `page_status == None`, so E_RATE on the status read is not kept as an earlier read (owner.rs:938). That leaves `(Some(info), Some(node)) else none` → empty.
- k9 is missing, so `behind` is false → empty.
- k10 is missing or does not match → empty.
- `netcfg()` fails → empty.
- Member side: `!behind(m.version)` → empty. Also, if the member's mnet was not updated, there is no hint at all.

The plan adds more "no card" cases of its own:

- the 2 s cap on `openNet` + `updateHint` → no hint this round;
- `openNet` fails → no hint;
- the `cleaning` flag is set → no hint;
- the window between opening the page and the first read finishing, which is up to 8 s to msg2 plus 20 s. Entering the node page starts a read (core.dart:196), but the hint was cleared when the page was last left.

The hint also ignores the unfinished-change flag (k11). updflow.rs:247 deliberately treats `Applied{save_pending:true}` as `Unfinished`, not as current. update_hint only compares k9, so during `Applying` (updflow.rs:316) the card can disappear before the node has actually switched its SAE.

**Field scenario.** The leader removes member X. In 8.4 the leader presses 送出 for the hilltop relay and gets `Applying`, or `[REQ_FAIL] 讀不到節點的網路狀態` (`End::Unknown`). The leader opens the relay's node page. The first read's `info` comes back E_RATE, or the hint misses its 2 s cap, or the leader looks during the connect. No card appears. Following the plan's fixed text, the leader concludes the relay is done. The relay is still on the old SAE, and X keeps using it.

**This departs from the baseline.** The frozen baseline gives a positive signal: remove-member §3.2-2 (doc :157) says 「k9 = 手機版本 → 『已是新密碼』」. In Rust that is `End::AlreadyCurrent` → `[UPDATED] 節點 …x 已是新密碼` (rekey.rs:445). It is reached only after the node is `Applied` without `save_pending` and passes the k4 check (updflow.rs:247-258). It writes nothing and signs nothing; it returns before `SignAdmin`. The baseline uses the status-page hint as a prompt to act, not as the confirmation of being done. Turning "the card has gone" into the confirmation is new in v6.

**Fix. No new mechanism, no Rust change.**
1. In 8.4 and 8.5, change the fixed text so the confirmation is positive: 「要確認某台換好了，再按一次那台的「送出」：看到『已是新密碼』才算換好。其他句子（正在套用、讀不到、沒有送出）都表示還沒確認，被移除的人可能仍連得上。」 Re-pressing is safe: `on_info` ends at `AlreadyCurrent` before any signature or `network/update` (updflow.rs:255-258). If wanted, skip the "包都交給隊員了嗎" dialog on this re-press; otherwise keep it, which is harmless.
2. Never say or imply "the card is gone, so the node is done". The hint card stays as it is in the baseline: a prompt that appears when the node is behind.
3. Test:
   - fake session where `info` errors (page_info None) while the node is behind → no card. The 8.4 text must not read as "done": assert the text in (1).
   - re-send on a current node → `[UPDATED] …已是新密碼` and zero `SignAdmin` calls.
   - Negative control: the v6 text → FAIL. (The negative control here is a text assertion, but the path it guards is the user's decision.)

## MINOR

### L-m1 — The hint can be stored for a page that has already closed
2.3 checks 「這台的節點頁正開著」 *before* `openNet`. The user can leave the page (which clears hints) during the up-to-2 s await. `onHint` then writes a value for a page that is closed, so the next time that page opens it shows a stale card, or a stale empty, until the new read lands.

Fix: `NodeLink.onHint` drops the value unless `Page.node` with this id is still current. Test: leave the page during `openNet` → `hints` has no entry.

### L-m2 — Re-reading after `revoke` can race a write that is still in flight (two writers on one record)
2.4 (:259-260) admits that a `writeCas` already past `_check` (record_writer.dart:39-44) can still land after the revoke. The page then re-reads 「在新的佔用裡」 and says 「沒有完成，請再試一次」 when the version is unchanged. But the old store call may still be pending at that moment, so the message can be wrong. The retry is protected by CAS, so no data is corrupted, but the leader can be told "removal not done" while it actually lands a moment later.

Fix: when the old `work` future has not returned yet, say only 「結果不明，稍後再看」 and re-read again after it returns. Or say "not done" only when the old work's write has provably not started, which `OfflineOp` can track with a flag set just before `writeCas`.

### L-m3 — 8.4's legacy-node row gives no way forward
「這台沒有編號紀錄，不能從這裡送」 (:344) leaves the leader with nothing to do. These nodes stay on the old key, which is exactly the removed-member path. The node page 「更多」→「把新密碼送給節點」 works for them, because it goes through info → infoNetId (nodes.dart:1546-1563) and does not need the device_id.

Fix: add 「請到那台的節點頁，按「更多」→「把新密碼送給節點」」 to that row.

### L-m4 — 2.4 contradicts itself on exceptions
:231 says 「例外照常往外丟，也一定釋放」. :250 says 「`OfflineOp` 接住 `work` 的例外，回 `failed(line)`」. Pick one: the second, since pages use `OfflineReply`. Otherwise a page can get an uncaught exception after the PopScope is lifted.

### L-m5 — The 60 s revoke leaves PopScope state undefined
After the cap fires, the stuck `work` may still be running, and its `finally` (the `z` zeroing, :247) runs only when it returns. The plan does not say whether PopScope is lifted at the revoke or when `work` returns.

State it: lift it at the revoke, and show 「結果不明」. The stuck work can no longer write (fail-closed), so this is safe. Test: after the revoke, the page can be popped, and a later return from `work` neither throws nor writes.

### L-m6 — Hint log lines
The existing prober catch-alls log `$e` (prober.dart:166, :175, :185). The plan's own try/catch logs only `runtimeType` (:194). Make sure the hint code cannot fall through to `run(st).catchError` at :174. Any exception from inside `openNet` or `updateHint` must be caught by the hint's own try/catch, or its message (a Rust error string) goes to the log. Add the hint path to T-P5-L: a fake `openNet` throws an exception whose message contains a fake secret, and the captured log must not contain it.

## Checked, no finding

- **QR limit.** The decision uses the encoder's actual version (≤ 27), with a size and bit-length check in Dart. Copy-text is the fallback, and that is fail-safe for delivery. The scanner's `MAX_LEN` 4096 (QrDecode.kt:18, :42) is far above v27's capacity. `from_hex` accepts uppercase and whitespace (batman-proto invite.rs:75-81), so uppercase QR plus lowercase copy both parse.
- **SecureScreen fallback.** `_held` reference counting (secure_screen.dart:21, :27, :37) keeps the flag on when a secure page is pushed over another. `onError → false` (:30) shows the fallback, and the fallback shows no QR. Showing the SAS without protection is accepted by D6, since the SAS is not secret.
- **Clipboard.** minSdk 31 (build.gradle.kts:39), so `clearPrimaryClip` is always available. `EXTRA_IS_SENSITIVE` only takes effect on 33+, which the plan states.
- **Gates.** `AppLink.devTrust` comes from main.dart's single read, which also runs the agree check (main.dart:104-107), before the AppLink is built (:150-158). Field builds never open net records in reads, because the hint is gated on devTrust. `request_send_update` has no `dev_gate` (owner.rs:1041), and T-S5 covers that Dart-only gate, as the plan says.
- **Compromised node.** k10 can only select `net/<hex>` or `mnet/<hex>`. A lying k9 only changes what is displayed. With L-M1 fixed, a false "no card" no longer reads as "done", which closes that residue too.
- **Kotlin logging.** The only `Log.` in the app's Kotlin is MainActivity.kt:27 (BleRx). The planned source check on the new files is adequate.

## Verdict

**APPROVE-WITH-CHANGES.** The one MAJOR is a text and semantics change: the confirmation becomes the baseline's positive `AlreadyCurrent` line, not the absence of a card. It needs no new mechanism. The MINORs can be folded in during implementation.
