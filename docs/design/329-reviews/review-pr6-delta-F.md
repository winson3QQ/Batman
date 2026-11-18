# #329 PR 6 — delta F 安全審查（ef4aece，T-U2 guard）

審查者：獨立對抗式（安全重點）。範圍：`app/device_check/t_u2_guard.dart`、`app/device_check/t_u2_main.dart`、`app/test/t_u2_guard_test.dart`，以及它們依賴的 `Keys.kt` / `KeyHandlers.kt` / `MainActivity.kt` / `build.gradle.kts` / `lib/main.dart`。只讀；沒碰任何手機。

## 實跑

```
$ flutter test test/t_u2_guard_test.dart
00:00 +1: any one of the four keys present -> refused, naming it
00:00 +2: records present -> refused
00:00 +3: one of the app's own flavors (dev, dev2, field) or no flavor -> refused, even when empty
00:00 +4: no levels, or a role missing from the answer -> refused (fail-closed)
00:00 +5: All tests passed!
```

`grep -n "tu2\|dev3" app/android/app/build.gradle.kts` → 無輸出（tu2 / dev3 都沒有 commit）。

## 攻擊路徑逐條（證據）

| # | 路徑 | 結果 | 證據 |
|---|---|---|---|
| 1 | 用 `--flavor dev / dev2 / field -t device_check/t_u2_main.dart` 建 | 擋（flavor 名 + 金鑰兩層） | t_u2_guard.dart:16；MainActivity.kt:107 `BuildConfig.FLAVOR` |
| 2 | 新增/改名的 flavor（如事故的 dev3，未 commit），持有金鑰 | 擋（只靠金鑰層；flavor denylist 不認得 dev3） | t_u2_guard.dart:11,18-19；pr6-device-2026-11-18.md「02：擁有者金鑰毀（dev3）」 |
| 3 | keyLevels 部分失敗（某把讀不到） | 擋：`Keys.level` 對非 KEY_NOT_FOUND 會 throw → `levels()` throw → `KeyHandlers.keyLevels` 回 `Err("keystore")` → `invokeMapMethod` 拋 PlatformException → main 的 catch 設 refusal | Keys.kt:35-43；KeyHandlers.kt:31-39；t_u2_main.dart:36-44 |
| 4 | 金鑰存在但 levels() 回 null | 只在 `getKey` 對存在的 alias 回 null 時發生；Keys.kt:29-34 註解引 SDK `AndroidKeyStoreProvider.loadAndroidKeyStoreKeyFromKeystore`：null 只代表 KEY_NOT_FOUND。⚠️ 本審查沒有獨立對 SDK 原始碼驗證，採用該註解的證據。另外 firstRun 只刪/重產同樣四個 alias（Keys.kt:28 `"$prefix-…-v1"`，keyLevels 與 firstRun 都用 `Keys()` 預設 prefix，MainActivity.kt:77,117），所以 levels 看的就是 firstRun 會毀的那四把，沒有「看 A 毀 B」的落差 | Keys.kt:28,62-74,180-191 |
| 5 | 回傳缺 role 名 / 型別不是 Map | 擋（缺名＝held；cast 失敗被 catch） | t_u2_guard.dart:18；test:34-37 |
| 6 | 紀錄放在 `filesDir/records` 以外 | 產品紀錄唯一位置就是 `filesDir/records`（main.dart:213-228、claim.dart:133/164/374、app_link.dart:111）；guard 用 `Directory.existsSync()`（只要目錄存在就擋，比 `storeHasRecords` 嚴，marker 也在裡面） | t_u2_main.dart:40 |
| 7 | 檢查與 firstRun 之間的競態 | Keystore / filesDir 以 UID 隔離，別的 package 寫不進來；同 package 內只有本程式。唯一同 package 並發＝`am start` 兩次起兩個 engine（見 MINOR-3），受害者只有 tu2 自己剛產的金鑰 | — |
| 8 | 照文件新增 tu2 時忘了改 `applicationIdSuffix`（仍是 `.dev`） | flavor 名 `tu2` 通過 denylist；`adb install -r` 會把使用者的 dev app **程式碼**換成 T-U2（資料與金鑰保留）；金鑰層擋下 firstRun。資料不毀，但 dev app 被換掉（見 MINOR-1） | t_u2_main.dart:7-10 |

結論：在這個程式裡，「持有任一把金鑰的 package 跑 firstRun」沒有找到可行路徑。金鑰層是真正的防線，flavor denylist 只是附加。

## Findings

### BLOCKER
無。

### MAJOR
無。

### MINOR

**MINOR-1 flavor 是 denylist，不是 allow-list；事故的 dev3 本身就是「臨時 flavor」。**
- 情境：文件教人「臨時加一個 flavor、不 commit」（t_u2_main.dart:6-7），這正是 dev3 的來歷（build.gradle.kts 沒有 dev3，卻被拿來當真 app 認領 7C31）。denylist `{'dev','dev2','field'}`（t_u2_guard.dart:11）對 dev3 / dev4 / 任何本機臨時名都無效，只剩金鑰層。另外忘了改 suffix 時（表格 #8），`install -r` 會把真的 dev app 換掉。
- 修法：改成正面 allow-list：`flavor != 'tu2'` 就拒（一行，測試把 'dev3' 加進拒絕清單）；文件第 7 行加「`applicationIdSuffix` 一定要是 `.tu2`，install 前 `adb shell pm list packages | grep tu2` 應為空」。

**MINOR-2 防線在呼叫端，不在 `Keys.firstRun` 本身（縱深）。**
- 情境：Keys.kt:177-178 的契約是「The caller has checked there is no install marker and no record」，MainActivity.kt:114 也標 not gated。這次修好的是 T-U2 這個呼叫者；任何下一個呼叫 `firstRun` 的 Dart 程式（另一支 device_check、或產品 `_install` 在「marker 與 records 都不在、但金鑰還在」時，main.dart:215-226）一樣會重產金鑰。產品路徑是既有行為，不是本 delta 引入。
- 修法（建議，非本 PR 必要）：`firstRun` 開頭 `check(KeyRole.values().all { level(it) == null }) { "keys exist" }`，例外留給「上一次 firstRun 失敗、已全刪」的情況（本來就全 null）。同時保護兩個呼叫者，且把競態（MINOR-3）一起關掉。若不做，至少在 #329 checklist 記一行。

**MINOR-3 `am start` 連按兩次 → 兩個 engine 各跑一次 firstRun。**
- 情境：兩個 engine 都在對方 firstRun 前通過 guard；第二個 firstRun 刪掉第一個剛產的 tu2 金鑰，第一個的 t-u2-records 解不開 → 假 FAIL。不毀真資料，只影響結果可信度。
- 修法：MINOR-2 的 Kotlin 端檢查即可涵蓋；或文件寫「只 start 一次，FAIL 時看 logcat 有沒有兩條 `T-U2 DONE`」。

**MINOR-4 main 的接線沒有測試（只測了純函式）。**
- 情境：t_u2_guard_test 證明 `tu2Refusal` 本身正確，但沒有任何東西證明 `t_u2_main.dart` 在 `firstRun` 之前呼叫它、refusal 時 return、`hasRecords` 用的是 `$files/records`。日後有人把 diag 段挪到 guard 前面不會有紅燈。
- 修法：加一個原始碼 lint 測試（像 KeysWiringLintTest 的作法）：在 t_u2_main.dart 裡 `tu2Refusal(` 出現在第一個 `'firstRun'` 之前，且之間有 `return;`，且含 `'$files/records'`。

## 文件指示是否安全照做
- 建置指令用 `adb -s <phone> install -r`，符合「手機只准 install -r」規則；沒有 `flutter install` / `flutter run` / connected* ✅。
- tu2 未 commit ✅（grep 無輸出）。
- 風險只在 suffix 抄錯（MINOR-1）；即使抄錯，金鑰層擋下 firstRun，資料不毀，但真 dev app 程式碼被覆蓋，要重裝。

## Verdict
**APPROVE**（0 BLOCKER / 0 MAJOR / 4 MINOR）。建議至少做 MINOR-1（一行 allow-list）與 MINOR-4（接線 lint）；MINOR-2 是縱深建議，若不做請記進 #329 checklist。
