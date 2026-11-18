# #329 PR 6 delta 審查 D（安全與失敗模式）— 4b0f88a..63161e0

審查者：獨立對抗式 code review（D）。範圍：ea18179（T-U2 device-check guard）、7e77b70（測試缺口 + 刪 dead code）、63161e0（S20 場次修正：upperLast4、kRunWait、swupd.rs 全形標點 + source-scan test、更新頁「重新整理」改 secondary、dev 頁預選唯一節點）。
只在 `C:/src/Batman-329pr6t` 讀檔與跑測試；沒碰 `C:/src/Batman-329pr6` 或任何手機。所有負向對照改動都已 `git checkout --` 還原，`git status --short` 為空。

## 結論

- BLOCKER 0 / MAJOR 1 / MINOR 4
- Verdict：**APPROVE-WITH-CHANGES**（M-1 必須修：guard 在安全上是 fail-closed，不會再毀金鑰，但它對**每一個**套件都拒絕，T-U2 程式從此不能跑，而且沒有任何測試證明它分辨得出「新套件 / 有金鑰的套件」）

## MAJOR

### M-1 T-U2 guard 永遠成立：`keyLevels` 的回答裡有 6 個永不為 null 的 boolean，所以 `hasKey` 恆為 true

**情境**：照註解在一個全新的套件上跑 `device_check/t_u2_main.dart`。期望：沒有金鑰 → `firstRun` → 四個案例。實際：一定印 `T-U2 REFUSED: this package already has keys` + `DONE pass=0 fail=1`。

**證據**：
- `KeyHandlers.kt:31-36`：`keyLevels` 回 `KeyRole.values().associate { it.name to levels[it] } + mapOf("appUsable" to …, "claim" to …, "login" to …, "recover" to …, "makeNetwork" to …, "softOwnerEnc" to …)`。
- `KeyPolicy.kt:68-90`：`Abilities` 六個欄位都是非 null `Boolean`（沒有金鑰時是 `false`，不是 null）。
- `KeyHandlersTest.kt:129-135` 釘住完整形狀：key set = 4 個 role + 6 個 ability，`m["makeNetwork"] == false`。
- `t_u2_main.dart`：`final hasKey = levels != null && levels.values.any((v) => v != null);` → 6 個 boolean 一定 `!= null` → 恆為 true。
- 註解指示 `--flavor tu2`，但 `android/app/build.gradle.kts:56-77` 只有 `dev` / `dev2` / `field`，沒有 `tu2`（也沒有 `dev3`）。照註解 build 會失敗；最順手的「修法」是換成 `--flavor dev`，也就是持有真紀錄的套件。
- 這個 guard 沒有任何測試（Dart / Kotlin / 真機都沒有），所以「拒絕有金鑰的套件、放行新套件」兩邊都沒被證明過。design 表 T-U2 那格的「✅ 端到端補測 2026-11-18 4/4 PASS」是 guard 之前、毀掉 7C31 owner key 的那次執行；repo 裡現在這版從沒跑過。

**安全面判定**：目前**不會**再毀金鑰（fail-closed：拒絕一切；`invokeMapMethod` 若丟例外也會讓 `main` 在 `firstRun` 之前結束）。問題在：(a) T-U2 這條回歸檢查從此是死的，每次都 fail=1；(b) 下一個想讓它跑起來的人最可能的作法是刪掉 / 放寬 guard，或在 `dev` 上跑——正好重演事故。

**修法**：
1. 只看四個 role：
   ```dart
   const roles = ['RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'];
   final hasKey = levels == null || roles.any((r) => !levels.containsKey(r) || levels[r] != null);
   ```
   （缺 key 或形狀不對 = 當成有，fail-closed。）
2. 再加一層與資料無關的檢查：`platform.invokeMethod('flavor')` 必須是專用的 flavor（例如 `tu2`），否則拒絕；並在 `build.gradle.kts` 真的建立該 flavor（`applicationIdSuffix = ".tu2"`、`DEV_TRUST` 與 Rust feature 一致），或把註解改成「臨時加這個 flavor、跑完移除」的確切步驟。
3. `keyLevels` / `filesDir` 包進 try/catch：例外時印 `T-U2 REFUSED: keyLevels unreadable` + `DONE pass=0 fail=1`（現在是未捕捉例外，logcat 沒有 DONE 行，抓 `grep T-U2` 的人看到的是「沒結果」）。
4. 把判斷抽成純函式（例如 `tu2Refuses(Map? levels, bool hasRecords, String flavor)`）放 `lib/` 或 `device_check/` 並加 `flutter test`：真實形狀（4 role 皆 null + 6 個 false）→ 放行；任一 role 非 null / 缺 role / null map / 有 records / flavor 不對 → 拒絕。負向對照：換回現在的 `values.any((v) => v != null)` → 「全新套件放行」那條 FAIL。
5. 修好後在全新套件上真機重跑一次 T-U2，並在有金鑰的套件（例如 S20 的 `dev`，**只讀**）上確認印出 REFUSED、`keyLevels` 前後一樣；design 表那格改成引用這次結果。

**其他路徑確認（現行 guard 下皆 fail-closed）**：
- 部分金鑰（某 role 有、某 role null）：拒絕（修法 1 後仍拒絕）。
- Keystore 讀取錯誤：`Keys.level` 用 `getKey`，非 KEY_NOT_FOUND 會丟（`Keys.kt:30-41`）→ `keyCall` 回 `Err("keystore")` → Dart `PlatformException` → `main` 中止，`firstRun` 不會被呼叫。
- records 目錄名：app 一律用 `'$filesDir/records'`（`main.dart:134,212-228`、`claim.dart:133,164,374`），guard 一致。
- `firstRun` 失敗時刪四把（`Keys.kt:180-191`）：在「確定沒有任何 role」的前提下無害；Keystore alias 以 app UID 隔離，不影響其他套件。

## MINOR

### m-1 SSH 頁預選後，若該節點紀錄在頁面開著時被移除，「送出」仍可按，但畫面上沒有任何節點被勾

**情境**：只有一台節點 A → 進 SSH 金鑰頁，`_id = A`。頁面開著時 A 被忘記（`NodeLinkCore.setRecords` 移除 `states[A]`），之後打字觸發 rebuild：`NodePickCard` 不再列 A，沒有任何 radio 被勾，但 `can = … && _id != null` 仍為 true。
**評估**：不會送錯節點——`_id` 是 device id 不是索引，`OpSession.once` → `d.login(lease, id)` 以 id 登入，紀錄已不在只會失敗；新加入的節點 B 不會被當成 A。手動點選本來就有同樣的 stale 問題，預選沒有讓「送錯台」變容易。
**修法**：`can` 加 `widget.app.link.core.states.containsKey(_id)`（NodeSettingsPage 的「讀取設定」同理）。

### m-2 「a double tap on 離開網路 sends network/leave once」沒有分辨 `_running` guard

**證據**：把 `more_pages.dart` 的 `onPressed: _running || d == null ? null : _leave` 改成 `onPressed: d == null ? null : _leave`，`more_pages_test.dart` 仍只有 T-L4（另一個同時植入的改動）FAIL，雙擊測試 PASS。保護來自下一層（lease：第二次 `OpSession.once` 拿不到 lease → `OpEnd.busy`，不登入、不送）。
**影響**：「只送一次」這個安全性質確實被測到；但 guard 退化時第二次 `_leave` 會把 `_running=false, _done=true` 和 busy 句子蓋在仍在跑的第一次上（畫面顯示已結束 + 「完成」按鈕），這個測試抓不到。
**修法**：同一測試再斷言第二次點擊後畫面沒有 busy 句子、`_done` 前仍顯示「正在離開…」（或直接斷言 `_leave` 只進入一次）。

### m-3 `upperLast4` 也作用在節點回傳的設定文字與使用者可控的名字上

**證據**：`screenText` 現在一律套 `upperLast4`；`dev_pages.dart:267` `SelectableText(screenText(_text))` 顯示節點回傳的設定；含使用者名字的句子（`display_name`）也經過 `SayLine → screenText`。
**評估**（已逐一查證，皆只影響顯示）：
- 送到節點的：`node-{last4}` 在 Rust 產生，不經 `screenText`。
- 判斷用的：`rekeyEnd` 用原始 `u.text` / `s.text`（`net_run.dart:320`、`rekey_send.dart:150`），且 `sameLast4` 不分大小寫（`rekey_send.dart:20`）。
- SAS：`SasConfirmView` 用 `Text(widget.sas)`，`onConfirm(widget.sas)` 原值（`member_ui.dart:66,76`），不經 `screenText`。
- 指紋 `fpr` = 8 位小寫 hex，包在「（）」裡、前面不是「…」（`rekey.rs:21`、`batman-proto/src/rekey.rs:76-78`），regex 不會碰；5 位以上 hex、`bm-…` 網路 id 也不碰（say_test 已測）。
- 複製：`logText(_text)` / `diagCopy` 用原文（`dev_pages.dart:279`、`diag_page.dart:126`），所以設定頁「畫面」與「複製出來」在含 `…xxxx` 時大小寫不同。
- 使用者名字裡含 `…ab12` 會被顯示成 `…AB12`：冒充節點後四碼本來就做得到（攻擊者可直接打大寫），不是新增面。
**修法**：可選——設定頁改用不做 `upperLast4` 的版本（例如 `splitCode(stripMarkers(_text)).$1`），讓節點原始資料照原樣顯示。

### m-4 T-U2 guard 被拒時的訊息在只有 records 沒有 keys 時才正確

`'${hasKey ? 'keys' : 'records'}'`：因 M-1 恆為 'keys'。修 M-1 後兩者都有時只報 keys；建議兩個都列出（診斷用）。

## 其他檢查（無發現）

- **swupd.rs 全形標點**：diff 只改字串常值；所有改到的字串都是顯示用（`Action::Send { note }`、`screen` / `done` / `wait` 文字、`tech`）。`send(verb, read, note)` 的 `body` 由 `self.body(verb)` 產生，與文字無關（`swupd.rs:658-662`）。Dart 端判斷只用 `startsWith('更新完成')`、`contains('退回' / '回到原本的版本' / '代碼')`（`swupdate.dart:79-84`），不含標點，判定不變。全 repo 搜尋 `更新完成:`、`檔案不對:`、`測試信任`、`上一次更新:` 沒有任何依 ASCII 標點比對的程式。bridge `owner.rs` / `sw*.rs` 沒有殘留半形標點的中文常值。
- **refresh → secondary**：只影響按鈕樣式；`apply` / `start` 仍是 danger。
- **kRunWait**：每一步自己的句子帶時限（`net_run.dart:266,305,335`：6 / 6 / 2 分鐘），移除重複無安全影響。
- **刪 `teamLogLine`**：全 repo 無其他引用（測試皆過）。
- **NodeSettingsPage 預選**：唯讀操作。

## 測試與負向對照（實跑）

✅ 正向：
```
flutter test test/say_test.dart test/ui/pr6_dev_test.dart test/ui/more_pages_test.dart test/swupdate_test.dart test/ui/team_pages_test.dart
00:08 +97: All tests passed!
cargo test --test swupd   (WSL, CARGO_TARGET_DIR=$HOME/tgt-329pr6-rd)
test result: ok. 42 passed; 0 failed
```

✅ 負向對照（每個都已 `git checkout --` 還原，`git status --short` 空）：
| 植入的退化 | 結果 |
|---|---|
| `dev_pages.dart` `late String? _id = onlyNode(...)` → `String? _id;` | `T6-3 SSH keys page one node: picked already…` **FAIL**（`Expected: [ … Actual: []`） |
| `swupdate.dart` 刪 `SwButton.refresh => BtnKind.secondary` | `pick + refresh: one solid button` **FAIL**（Found 2 FilledButton） |
| `say.dart` `screenText` 拿掉 `upperLast4` | `upperLast4: the last four upper case on screen` **FAIL** |
| `more_pages.dart` `Text(upperLast4(d[0]))` → `Text(d[0])` | `T-L4` **FAIL** |
| `node_page.dart` 拿掉 `n.fresh &&`（lagNote） | `lagNote: not shown on old data` **FAIL** |
| `swupd.rs` T_TAK 的「，」改回「,」 | `s6_swupd_sentences_full_width` **FAIL**（`swupd.rs:74: 重開約 2 分鐘,全隊 TAK 中斷`）；另有 `scanned > 40` 防空掃 |
| `more_pages.dart` 拿掉 `_running ||` | 雙擊測試仍 **PASS** → 見 m-2 |

⚠️ 未做：T19（RekeyPage 自己送）負向對照沒植入；T-U2 guard 沒有可跑的測試，只做了原始碼 + `KeyHandlersTest` 形狀推論（見 M-1）；未上任何真機。
