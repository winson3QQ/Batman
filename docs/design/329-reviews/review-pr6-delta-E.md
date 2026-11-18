# #329 PR 6 — review delta E（ef4aece：T-U2 guard 修正 + delta C / D 的 MINOR）

審查者：獨立審查（第 E 位）。範圍：`git show ef4aece`，對照 Kotlin 原始碼；沒有碰任何手機。

- **BLOCKER 0 / MAJOR 0 / MINOR 5**
- **Verdict：APPROVE-WITH-CHANGES**（MINOR 隨手修即可；guard 本身在離線層面正確，delta C / D 的 MAJOR 已解）

## 結論：guard 是否滿足 (a) / (b)

### (a) 全新的臨時 flavor package 會跑 —— ✅（離線）／⚠️（真機未驗）

- `KeyHandlers.kt:31-36` `keyLevels` 的回答 = `KeyRole.values().associate { it.name to levels[it] }`（四個角色名，null = 沒金鑰）+ 六個非 null boolean。
- `KeyPolicy.kt:9` `enum class KeyRole { RECORD_AES, OWNER_SIGN, ADMIN_SIGN, OWNER_ENC }` 與 `t_u2_guard.dart` 的 `keyRoles` 完全一致。
- 新 guard 只看這四個名字（`!levels.containsKey(r) || levels[r] != null`），六個 boolean 不再算金鑰。
- `t_u2_guard_test.dart` 第一個測試以 KeyHandlers 的真實形狀（四個 null + 六個 false）斷言 `isNull`。
- 真機上「全新 package 會跑、第二次會拒」兩個場次（delta C 的要求）**沒有在本次審查中做**（禁止碰手機）。

### (b) firstRun 之前一律拒絕 —— ✅

`t_u2_main.dart:31-49`：`firstRun`（:51）只在 `refusal == null` 時才會到。逐項：

| 情況 | 路徑 | 結果 |
|---|---|---|
| 任何一把金鑰 | `levels[r] != null` | 拒（列出角色名） |
| 有 records | `Directory('$files/records').existsSync()` | 拒 |
| flavor = dev / dev2 / field | `appFlavors.contains` | 拒 |
| flavor null | `flavor == null` | 拒 |
| levels null（invokeMapMethod 回 null） | `levels == null` | 拒 |
| 少一個角色名 | `!levels.containsKey(r)` | 拒 |
| Keystore 讀不到 | `Keys.level()` 對非 KEY_NOT_FOUND 會 throw（`Keys.kt:28-40` 註解）→ `KeyHandlers.keyLevels` catch → `KeyAnswer.Err("keystore", …)`（:37-39）→ `MainActivity.keyCall` → `result.error`（:85）；`Keys()` 建構本身失敗也被 `keyCall` 的 catch 轉成 Err（:79-81）。Dart 端 `invokeMapMethod` 對 `result.error` 會 throw `PlatformException`，被 `t_u2_main.dart:42` 的 `catch (e)` 接住 | 拒 |
| `flavor` 呼叫失敗 | 同一個 try | 拒 |
| `filesDir` 失敗（:31，在 try 之外） | 未處理例外，main 結束 | 不會到 firstRun（fail-closed，但沒有 REFUSED / DONE 行，見 MINOR-4） |

`flavor` 的來源：`MainActivity.kt` `"flavor" -> result.success(BuildConfig.FLAVOR)`；build.gradle.kts 只有 `dev`(58)、`dev2`(66)、`field`(72)，與 `appFlavors` 一致。

### records 路徑是 app 真正的 records 目錄 —— ✅

`lib/main.dart:134,212-228`（sweep / marker / hasRecords / writeMarker 都在 `$filesDir/records`）、`lib/src/nodelink/app_link.dart:111`（`'$filesDir/records'`）、`lib/claim.dart:133,164,374`、`main.dart:191` UiState 的 `RecordUiStore(a.records, …)`。app 沒有在 `filesDir` 底下其他目錄放紀錄。marker 也在 records 裡，所以「裝過、只有 marker」也會被擋。

## 實測

✅ `flutter test test/t_u2_guard_test.dart test/ui/pr6_dev_test.dart test/swupdate_test.dart`（JAVA_HOME = Android Studio jbr）：

```
00:06 +56: All tests passed!
```

✅ 負向對照 1（guard 改回舊規則 `levels.entries` 任何非 null 即算金鑰）：

```
a fresh temporary flavor (no key, no record) may run — ... [E]
  Expected: null
    Actual: 'this package already has keys (appUsable, claim, login, recover, makeNetwork, softOwnerEnc)'
records present -> refused [E]
no levels, or a role missing from the answer -> refused (fail-closed) [E]
```

✅ 負向對照 2（拿掉 `appFlavors.contains(flavor)`）：

```
one of the app's own flavors (dev, dev2, field) or no flavor -> refused, even when empty [E]
  Expected: not null
    Actual: <null>
Some tests failed.
```

兩次都 `cp` 回原檔，`cmp` 相同（`RESTORED`），`git status --short` 為空。

⚠️ `cargo test --test say_scan` 沒跑成：Windows host 上 `getrandom` 編譯失敗（`dlltool.exe: program not found`），是本機工具鏈問題，與這次改動無關；allow 條目只做了原始碼比對（見下）。
❌ 真機：未做（任務規定不碰手機）。

## 其他 MINOR 修正的檢查

- **claim.dart 重新認領對話框**：`:332` 改 `.substring(14).toUpperCase()`，修掉 delta C MINOR-3 指的那一處 ✅。沒有測試斷言對話框標題是大寫（見 MINOR-3）。
- **dev_pages SSH can**：`can` 多了 `widget.app.link.core.states.containsKey(_id)`（`core.dart:130` `Map<String, NodeState> states`，鍵為 device id）✅。但見 MINOR-2。
- **swupdate_test fixture**：376-377 改為全形「，」，與 `swupd.rs` 實際字串一致 ✅。
- **say_scan allow**：新增 `swupd.rs` / `上傳中的更新（{ver}）`，對應 `swupd.rs:936` `format!("節點上有一個上傳中的更新（{ver}）")` 原文完全一致；理由（使用者值：版本）合理 ✅（未實跑，見上）。

## MINOR

### MINOR-1：flavor 用 deny-list，`flavor` channel 註解仍寫「display only」
- 證據：`t_u2_guard.dart` `appFlavors = {'dev','dev2','field'}`；任何其他名字（包括 11-18 出事的 `dev3`）都通過 flavor 這一關，只靠金鑰／records 擋。`MainActivity.kt` `"flavor"` 註解：「the product flavor's name (dev / dev2 / field), display only」——現在它已是安全判斷的輸入。
- 影響：真正的保護（金鑰 + records）仍在，所以不是 MAJOR。但若有人把 tu2 複製 dev 區塊時忘了改 `applicationIdSuffix`（仍是 `.dev`），flavor 名是 `tu2`、package 卻是 `dev.batman.app.dev`：dev app 有金鑰時會被擋（OK），但 `install -r` 已經把 dev app 換成 T-U2 程式。
- 修法：改成 allow-list `flavor == 'tu2'`；並在 guard 加一條 package 名（或 applicationId 後綴）必須以 `.tu2` 結尾（需要一個回傳 `packageName` 的 channel method，或沿用 `filesDir` 路徑含 `dev.batman.app.tu2` 判斷）。更新 MainActivity 註解。

### MINOR-2：SSH 頁的 `can` 只在重建時重算；NodeSettingsPage 沒有同樣處理
- 證據：`dev_pages.dart` `SshKeysPage` 只 `_text.addListener`（:118），沒有訂閱 `NodeLink.changed`；節點在頁面開著時被移除、使用者沒有打字，`can` 不會重算，按鈕仍可按。`_send`（:126-128）也沒有再檢查 `states.containsKey(id)`。`NodeSettingsPage` 的「讀取設定」（:275 `_id == null || _reading ? null : _read`）delta D m-1 說「同理」，未改。也沒有任何測試覆蓋這個修正（拿掉 `containsKey` 測試仍會全過）。
- 影響：delta D 已查證不會送錯台（以 id 登入，紀錄不在只會失敗），只是顯示／可按狀態不一致。
- 修法：在 `_send` / `_read` 開頭加同樣的 `containsKey` 檢查（或訂閱 `changed`），補一個 widget 測試：`setRecords([])` 後 `ssh-send.onPressed == null`。

### MINOR-3：大寫後四碼的修正沒有回歸測試
- 證據：`grep -rn 已經認領過 test` 無結果。
- 修法：claim_scan_test 加一條：已認領的小寫 deviceId → 對話框標題含大寫後四碼。

### MINOR-4：`filesDir` 在 try 外；拒絕後無法重跑的步驟沒寫
- 證據：`t_u2_main.dart:31` 若 throw，main 以未處理例外結束（fail-closed，但 logcat 沒有 `T-U2 REFUSED` / `T-U2 DONE`，照註解 `grep T-U2` 看不到任何結論）。另外第一次跑完 `firstRun` 已產生金鑰，第二次一定被拒；註解沒說要重跑必須先移除 **tu2** 這個臨時 package（而專案慣例是手機只准 `adb install -r`，操作者可能誤以為不能 uninstall，或誤把別的 package 卸掉）。
- 修法：把 `filesDir` 也放進 try；註解加一行「重跑：`adb -s <phone> uninstall dev.batman.app.tu2`（只限這個臨時 package）」。

### MINOR-5：delta C 的 MINOR-2 / MINOR-5(1293) 與 delta D 的 m-2 未處理、也沒說明
- 證據：`net_pages_test.dart` / `retest_s_boards_test.dart` 仍是 `lessThanOrEqualTo(1)`（未查行號是否變動，commit 未觸及這兩檔）；`swupd.rs` 測試 1293 仍是 `"再試一次： bulk/open again， then the check again"`；more_pages 雙擊測試未加強。commit 訊息只列了修掉的。
- 修法：修掉，或在 PR / issue checklist 寫明不修的理由（依規則，縮掉的項目要進原單 checklist）。

## 未做
- ❌ 真機「全新 tu2 會跑／第二次會拒」。
- ⚠️ say_scan Rust 測試未在本機跑成（工具鏈），allow 條目只做原始碼比對。
