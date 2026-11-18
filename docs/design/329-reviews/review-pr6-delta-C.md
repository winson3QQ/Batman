# #329 PR 6 delta 程式碼審查 C（4b0f88a..63161e0）

審查者 C，獨立對抗式審查。範圍：ea18179（T-U2 拒跑有金鑰／紀錄的 package）、7e77b70（test-migration 缺口測試 + 移除 teamLogLine）、63161e0（S20 場次修正：upperLast4、kRunWait、swupd.rs 全形標點 + 掃描測試、refresh 改 secondary、dev 頁預選唯一節點）。

## 實跑證據

- ✅ Rust `cargo test --test swupd`（WSL，C:/src/Batman-329pr6t @ 63161e0）：`test result: ok. 42 passed; 0 failed`。
- ✅ `s6_swupd_sentences_full_width` 負控：把 `T_CANCELLED` 改回 `已取消,目前版本不變` → `s6_swupd_sentences_full_width ... panicked at tests/swupd.rs`（FAIL）；還原後 `git status` 乾淨。
- ✅ upperLast4 負控：`screenText` 拿掉 `upperLast4(...)` → `say_test.dart: upperLast4: the last four upper case on screen, nothing else [E]`；還原後乾淨。
- ⚠️ 全套 `flutter test`：第 1 次 `-2: Some tests failed`（`swupdate_test.dart: pick + refresh ...` 找到 2 個 primary FilledButton；`pr6_dev_test.dart: one node: picked already ...` asked = `[]`），第 2、3 次 `+1816: All tests passed!`，單檔單跑也過。兩個失敗的樣子**正好是修正前程式的行為**（refresh 還是 primary、`_id` 從 null 開始），而同一時間這棵樹裡出現了另一位審查者的 `review-pr6-delta-D.md`——推斷是別的審查者在同一個 worktree 做負控、暫時改了 lib。❓ 未證實（沒有 flip test），但不是本 delta 的產品缺陷證據。**建議：審查者負控不要共用同一棵樹。**

## 發現

### MAJOR-1：T-U2 的守門永遠拒跑——`keyLevels` 的答案除了四把金鑰還有六個布林值

- 情境：在一個全新、從沒有金鑰或紀錄的 package 上跑 `t_u2_main.dart`。
- 證據：
  - `app/device_check/t_u2_main.dart:34-35`：`final levels = await platform.invokeMapMethod<String, dynamic>('keyLevels'); final hasKey = levels != null && levels.values.any((v) => v != null);`
  - `app/android/app/src/main/kotlin/dev/batman/batman_app/keystore/KeyHandlers.kt:34-37`：答案是 `KeyRole.values().associate { it.name to levels[it] } + mapOf("appUsable" to a.appUsable, "claim" to a.claim, "login" to a.login, "recover" to a.recover, "makeNetwork" to a.makeNetwork, "softOwnerEnc" to a.softOwnerEnc)`——這六個是 `Boolean`，永遠不是 null（沒有金鑰時是 `false`）。
  - 所以 `hasKey` 恆為 true，程式一律印 `T-U2 REFUSED: this package already has keys` + `DONE pass=0 fail=1`，連全新 package 也一樣。訊息還會說「已經有金鑰」，誤導操作者。
  - 這個守門是 fail-closed（不會再毀掉節點金鑰，安全面 OK），但 T-U2 從此不可能在任何手機上通過；commit 宣稱的「只在有金鑰／紀錄時拒跑」並沒有用全新 package 實跑過（缺正向控制）。
- 修法：只看四個角色名，例如 `const roles = ['RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC']; final hasKey = levels == null || roles.any((r) => levels[r] != null);`（`levels == null` 時也拒跑＝fail-closed）。另外 `keyLevels` 在 Keystore 打不開時會丟 `PlatformException`（MainActivity.kt keyCall → `result.error("keystore", …)`），目前沒有 catch，程式直接崩、不印 `DONE`；應 catch 後印 `T-U2 REFUSED: keyLevels <e>` + `DONE pass=0 fail=1`。到真機時要補兩個場次：全新 package → 跑到四個 premise；同一 package 再跑第二次 → REFUSED（這次有金鑰），這兩個就是這個守門的正／負控制。

### MINOR-1：註解指示的 `--flavor tu2` 不存在

- 證據：`app/device_check/t_u2_main.dart:7-9` 要 `flutter build apk --flavor tu2`、`dev.batman.app.tu2`；`app/android/app/build.gradle.kts` 只有 `dev`(58)、`dev2`(66)、`field`(72)，沒有 `tu2`（也沒有 `dev3`）。照註解跑會直接 build 失敗；操作者最省事的「解法」是改用現有 flavor——正好是 11-18 毀掉 7C31 擁有者金鑰的那條路（守門修好後會擋，但目前因 MAJOR-1 連全新的也擋）。
- 修法：註解寫明「要先在 build.gradle.kts 臨時加一個 `tu2` flavor（applicationIdSuffix `.tu2`），跑完拿掉」，或把 tu2 flavor 常駐（它只服務 device_check）。

### MINOR-2：kRunWait 的測試允許「限時一次都沒出現」

- 證據：`app/test/ui/net_pages_test.dart:123,145`、`app/test/retest_s_boards_test.dart:380`：`expect(find.textContaining('最多 6 分鐘').evaluate().length, lessThanOrEqualTo(1))`。設計 S5／F49 要的是限時「說一次」；`<= 1` 在步驟那行沒寫限時時（0 次）也會過。實際限時來自 `lib/src/flows/net_run.dart:266/305/335` 的 row line，若之後有人改了那幾行，這三個測試不會抓到。
- 修法：在 gate 持住的那一刻（make／join 步驟正在跑）改成 `findsOneWidget`／`equals(1)`。

### MINOR-3：upperLast4 只在 screenText／LeavePage 生效，其他直接 `Text(title)` 的 last four 仍是小寫

- 證據：`app/lib/claim.dart:332` `_ask('節點 …${q.deviceId.substring(14)} 已經認領過', …)` → `claim.dart:341` `AlertDialog(title: Text(title))`，沒經 screenText；`claim_scan_test.dart:66` 顯示 deviceId 是小寫 hex（`…4f2a`）。註解說「upper case everywhere」不完全成立。
- 修法：這個 title 改 `screenText(title)`／`upperLast4(title)`，或在 `say_src_test` 的規則加一條「`title: Text(<變數>)` 未經 screenText」。

### MINOR-4：upperLast4 也套到節點回傳的字串（設定頁）

- 證據：`app/lib/ui/dev_pages.dart:267` `SelectableText(screenText(_text))`；`_text` 含節點自己的名稱／SSID（`owner.rs:676 settings_text`、`:1770` 範例 `BCM2711-6c89`）。SSID 是任意 UTF-8，若含 `…ab12` 這種片段會被顯示（與複製）成大寫，和節點上的實際值不同。機率很低，且只影響顯示。
- 修法：可接受；若要嚴格，settings 頁對節點字串不做 upperLast4（只對 Rust 句子做）。記一行即可。

### MINOR-5：轉換腳本也改了測試的英文斷言訊息

- 證據：`app/rust/batman-proto/tests/swupd.rs:1293` `"再試一次： bulk/open again， then the check again"`——英文句子裡的逗號被改成全形。只是斷言訊息，不影響判定；但說明腳本是「整個檔案、含 Han 的字串一律轉」，並非只轉 src。另 `app/test/swupdate_test.dart:376-377` 的 fixture 仍是半形（`新版不健康,已退回…`、`已取消,目前版本不變`），測試照樣過（`swHero` 只看 `contains('退回')`），但 fixture 已不是真輸出。
- 修法：1293 改回半形；swupdate_test 的兩個 fixture 換成全形（或直接用 Rust 常數的字面值）。

## 檢查過、沒有問題的

- **upperLast4 正確性**：regex `…([0-9a-fA-F]{4})(?![0-9a-fA-F])` 只在 U+2026 之後恰好 4 個 hex 才動；`bm-…` 網路 id、版本、指紋（`SHA256:` 開頭，無 `…`）、SAS（純數字，大寫不變）都不受影響。所有 Rust／Dart 的 `…{x}` 來源（`rekey.rs:134/139/168/354/356/453/457/458/519`、`flow.rs:273`、`claim.rs:328`、`member.rs:106`、`replay.rs:340`、`owner.rs:536/1734`、`teamview.rs:344`）都是 last four。`screenText` 只用在顯示（`say.dart:82` SayLine、`widgets.dart:120/124` StatusHero、`dev_pages.dart:267`、`net_pages.dart:48 plain`——`plain` 無其他呼叫者）；`logText`、送出的字串、`node-{last4}` 名稱、任何比較都沒經過它。技術部分（`techText`）不動，測試 `say_test.dart:98` 有證。
- **swupd.rs 轉換**：`git diff ea18179..63161e0 -- src/swupd.rs` 每一個改動的字面值都是顯示句或 `測試信任：{t}`（tech 行，只顯示在技術資訊）。沒有協定／log／格式字串含 Han。Dart 端唯一比對 swupd 文字的 `swHero`（`lib/swupdate.dart:82-83`）用 `startsWith('更新完成')`、`contains('退回')`、`contains('回到原本的版本')`、`tech.contains('代碼')`，都與標點無關；`T_REVERTED_18` 仍含「回到原本的版本」。全 repo grep 舊半形版本（`更新完成:`、`測試信任:`、`上一次更新:`、`檔案不對:` …）只剩一行註解（tests/swupd.rs:779）與上述兩個 fixture。`owner.rs:3455` 的 bridge 測試已同步。掃描測試有 `scanned > 40` 防空集合，負控 FAIL 已實跑。
- **T-U2 records 路徑**：`$files/records` 與 `lib/main.dart:213-228`、`app_link.dart:111` 一致；`t-u2-records` 是它自己的目錄。`Keys.firstRun` 失敗時會刪掉**所有**角色的 key（Keys.kt:180-191），守門正確修好後也一併擋住這條。
- **onlyNode 預選**：`late String? _id = onlyNode(...)` 只在第一次讀取時評估。開著頁面時 0→1 個節點：維持 null（與舊行為相同，要點一下）；1→2：第一台維持被選、畫面上 radio 有標示，使用者看得到；唯一節點被忘記：`_id` 指向已不存在的節點——與舊版「點了之後被移除」相同，不是新問題。負控在上述第 1 次全套中意外「實跑」到了（`_id` 從 null 開始 → asked `[]`）。
- **refresh secondary**：`BtnKind.secondary` → `OutlinedButton`（`widgets.dart:334`）；新測試在正確程式上通過。
- **7e77b70 測試**：lagNote fresh/old、double tap leave 一次、T19 10 分鐘不送——都是黑箱驅動介面並斷言結果；`teamLogLine` 全 repo 無呼叫者（grep 確認），移除正確。

## 結論

BLOCKER 0／MAJOR 1／MINOR 5。

**Verdict：APPROVE-WITH-CHANGES**——MAJOR-1 必修（守門改為只看四個角色名 + catch keyLevels 例外），並在真機補「全新 package 會跑／第二次會拒」兩個場次；MINOR 可隨手修。
