# #329 PR 7 程式碼審查 B（安全 + 失敗模式）

範圍：`git diff 3020374..6d763d8`（74 檔）。依據：`docs/design/329-pr7-plan.md` §2 T1/T2/T3/T14/T19/T20、§6、§10/§11。
只在 `C:/src/Batman-329pr7b` 讀檔與跑測試；沒有碰 `C:/src/Batman-329pr7`、手機或模擬器；沒有跑 gradle connected*/install*。

## 結論

**0 BLOCKER / 0 MAJOR / 4 MINOR — APPROVE-WITH-CHANGES**（MINOR 可在本 PR 修或寫進 #329 殘項；沒有一條會讓金鑰在既有紀錄上被重產或刪掉）。

## 實測證據

| 項目 | 結果 |
|---|---|
| Kotlin JVM `VARIANTS=devDebug tools/kotlin-unit-tests.sh` | ✅ `PASS kotlin devDebug: 101 tests in 18 classes` / `ALL PASS`（只跑 devDebug；dev2Debug / fieldDebug 沒跑） |
| 負向對照 1：`KeyHandlers.open` 改成經四把 `keys::levels` + 拿掉 `deliver` 的 `fill(0)` | ✅ 5 FAIL：`open_recordAesFits_…`、`open_recordAesNotAllowedOrMissing_…`、`open_anotherKeyUnreadable…_stillOpens`、`open_recordAesUnreadable_…`、`deliver_wipe_zeroesTheBytesAfterSuccess_notBefore`（16 tests completed, 5 failed）；已還原，`git diff` 空 |
| 負向對照 2：`KeyHandlers.open` 完全不經閘門 | ✅ 4 FAIL（open 的四條）；已還原 |
| Rust `cargo test --lib simple`（WSL Ubuntu-24.04，`CARGO_TARGET_DIR` 在 WSL home，非 root） | ✅ 6 passed，含 `t14_permission_denied_folder_is_an_error`（真的 mode 000，非 root）。Windows 本機 cargo 因缺 `dlltool.exe` 編不動 |
| 負向對照 3：`store_has_records` 的 read_dir 錯誤改回吞掉（等同 `unwrap_or(false)`） | ✅ 3 FAIL：`t14_kind_path_not_a_folder_is_an_error`、`t14_a_record_beside_an_error_is_true`、`t14_permission_denied_folder_is_an_error`；已還原 |
| Flutter：`t_g5_record_write_src_test`、`open_key_level_test`、`key_abilities_test`、`claim_flow_test`、`pr7_claim_boards_test`、`pr7_pages_test`、`raw_use_test`、`scan_page_test` | ✅ `+110: All tests passed!`（其餘 flutter 測試沒跑） |
| T-G5 負向對照：新檔 `import … as s; s.storeRemove(...)` | ✅ FAIL（別名繞不過） |
| T-G5 繞過探測：新檔用 `RustClaimStore(dir).sealWrite/remove`、`RecordUiStore(...).remove()` | ❌ 仍 PASS → MINOR-2 |
| T2 前提：Flutter `MethodChannel` 的 `Result.success` 同步編碼 | ✅ `javap` flutter_embedding_debug-1.0.0-89c39ed…jar `MethodChannel$IncomingMethodCallHandler$1.success`：`encodeSuccessEnvelope(result)` 後直接 `reply.reply(ByteBuffer)`，所以 `deliver` 在 `success` 回來後清零不會清到還沒編碼的資料 |

## 逐 actor 檢查（沒有發現問題的部分）

- **我們自己的錯誤 — 金鑰在紀錄上被重產/刪掉**：`firstRun` 的 Dart 呼叫點只有 `main.dart:_install`（grep）與 device_check。`_install` 順序：`storeSweep`（錯 → `_run` catch，不 firstRun）→ marker（有 → 不碰）→ `storeHasRecords`（Err → `_recordsUnread`，return，不 firstRun；true → 不碰）→ 只有 `Ok(false)` 才 firstRun。即使拿掉 `_install` 的 try，Err 也會落到 `_run` 的 catch（「啟動檢查失敗」+ 再試一次），一樣不 firstRun：兩層都 fail-closed。`_recordsUnread` 在每次 `_run` 開頭歸零，再試一次會重新判斷。Rust：先掃完所有種類，看到任何有效紀錄就 `Ok(true)`；`records` 根目錄本身讀不到（EACCES/ENOTDIR）→ 每個種類 read_dir 都是非 NotFound 錯誤 → Err。T-U2 守門（`t_u2_guard.dart`）用 `Directory('$files/records').existsSync()` 與四把金鑰都不存在，比 `storeHasRecords` 更嚴，本 PR 只改註解。
- **T1 等級閘門**：`open` 的 level 與解密都用寫死的 `alias(KeyRole.RECORD_AES)`，Dart 不能指定別名或角色；`Keys.open` 改 private（`KeysWiringLintTest` 鎖住），`MainActivityKeyUseLintTest` 要求 `"open" -> keyCall(result, wipe = true) { it.open(`。`KeyPolicy.refused` 對 null / UNKNOWN / 99 / SOFTWARE 都拒絕（測試列出）。較低等級的 RECORD_AES 拿不到解密結果。錯誤碼：拒絕 = `keyLevel`/`RECORD_AES`/level，讀不到 = `keystore`，與其他用途一致；`KeyAbilities.refusedBy` 只認 `keyLevel`，所以 X26 只吃真正的等級拒絕。
- **keyLevel 被當成「沒有紀錄」覆寫？** `ui_state.read`（catch 全部 → null）與 `console.readRecord`（PlatformException → null）確實會把 open 的 keyLevel 當成「打不開」。但會覆寫的路徑都要再 `seal`，`seal` 也只看 RECORD_AES 的等級（`KeyOp.SEAL`），所以 RECORD_AES 等級不符時寫入一樣被拒絕，不會覆寫。`claim_records`（`store.open` 丟出去，不當「沒有」）、`openSealedRecord` / `openRecord` / `NetSource.open`（丟出去）不受影響。剩下的是暫時性 `keystore` 錯誤 → MINOR-1。
- **T2**：`deliver` 是「先 success 再清零」，JVM 白箱測試會抓到清零被拿掉；ecdh 的 z 也走同一個 `deliver`（lint 強制 `wipe = true`），`selfTest` 內部的 ECDH 自己清零沒變。沒有任何地方在 success 之前清零。殘留副本（codec 的 direct ByteBuffer、Cipher 內部、Dart 的 Uint8List、`seal` 收到的明文參數）計畫已寫成 N5，不宣稱清乾淨，與程式碼註解一致。
- **祕密不進 log**：新增的 log 只有 claim 的 `_say(...tech('BLE 位址 $id'))`（經 `_log` 進 logcat，與既有的 `_log('found $id')` 相同內容）。BLE 位址不是祕密。Rust T14 錯誤字串只有種類名 + `io::Error` 的 Display（例如 `Not a directory (os error 20)`，不含路徑），進「技術資訊」與 `BMAPP` 那行；沒有金鑰、密碼或紀錄內容。
- **被入侵的節點（新顯示位置）**：claim 的 `last4` 來自 `decode_status`，Rust 驗證 4 位小寫 hex、且只在 unclaimed/legacy（status.rs:71-82），不能塞控制字元或假的技術段；StatusHero 的 `text`/`next` 都經 `screenText`（去掉標記與 U+001E…U+001F 段）。節點頁「網路：」行：網路名稱只從手機自己的 `nets` / `opens` 的 `mnets` 取，節點只能控制 `netId` 與 `nodeState`（它本來就能謊報自己的成員關係），再經 Rust `membership_line` 與 `screenText`；例外 → 不顯示（只是顯示）。隊員名字放進危險按鈕（`nameIn('移除', person.name, …)`）只是加空白，暴露面與 PR 7 前相同。
- **本機無權限 app / 實體取得**：本 PR 沒有新增剪貼簿寫入、檔案、export、intent 或權限；`SelectableText(_tech)` 原本就有。實體取得面沒有變（金鑰仍在 Keystore，紀錄仍是密文）。
- **T19**：舊 `_open` 的 lease 分支只在 `_app != null` 時走，而 `_ok && _app == null` 才顯示那一頁，確實是死碼；刪除後行為不變（NodeLink start 失敗時 `_app` 一樣是 null，之前也走「沒有 lease」那條）。

## 發現

### MINOR-1 T1 多一次 Keystore 讀取；暫時性 `keystore` 錯誤仍會被兩個呼叫者當成「打不開」而覆寫

- 情境：`KeyHandlers.open` 現在先 `keys.level(RECORD_AES)`（`getKey` + `SecretKeyFactory.getKeySpec(KeyInfo)`）再解密。Keystore 暫時出錯（binder / keystore2 忙）時回 `keystore`。`RecordUiStore.read`（ui_state.dart:227-231，catch 全部 → `plain = null`，「overwritten by CAS」）與 `console.readRecord`（app_link.dart:200-207，PlatformException → null → `joinreq` 把 `pendPlain: null` 交給 Rust 重產 mpend）把它當成「打不開」。下一步 `seal` 若已恢復就會寫：ui/state-v1 的暱稱、或一筆 mpend 被換掉。
- 證據：Keys.kt `level()`；KeyHandlers.kt:165-168；`AEADBadTagException`（真的打不開）與暫時錯誤都是同一個碼 `keystore`，Dart 分不出來。KeyHandlers.kt 的註解「an unreadable other key must not make a record unopenable (the Dart callers would take it for "no record" and write over …)」說的風險，在 RECORD_AES 自己的等級讀取上仍然存在。
- 程度：PR 7 前 `open` 自己的 `getKey` 也會這樣失敗（同類、已知，plan 第 105 行 D-4 接受），T1 只加了一個失敗點；ui/state-v1 是設計 §4.6 的 fail-open 顯示資料。所以 MINOR。
- 修法（擇一）：(a) Kotlin `open` 把 `AEADBadTagException` 回成獨立的碼（例如 `notOpen`），`ui_state` / `readRecord` 只把那個當「打不開」、其他錯誤往上丟（不寫）；或 (b) 至少把「暫時 keystore 錯誤 → ui/state-v1 / mpend 被覆寫」寫進 #329 殘項（附 T1 多一次讀取這件事），不要讓 KeyHandlers 的註解看起來像已經處理掉。

### MINOR-2 T-G5 原始碼鎖可被允許檔案裡的公開包裝類別繞過

- 情境：任何 `lib/` 檔案寫 `RustClaimStore(dir).sealWrite('net/…', …)` 或 `.remove('node/…')`、`RecordUiStore(dir, ch).remove()`，就能在沒有 lease、不經 RecordWriter 的情況下寫或刪任何紀錄（`rel` 不受限）；T-G5 照樣 PASS。
- 證據：我在 `lib/zz_review_probe.dart` 加上這三個呼叫，`flutter test test/t_g5_record_write_src_test.dart` → `+2: All tests passed!`（已刪檔，`git status` 乾淨）。檔頭寫「A key record is written or deleted only through RecordWriter」，比實際鎖住的範圍大。目前 `RustClaimStore(` 只在 claim.dart:239/481、`RecordUiStore(` 只在 main.dart:197（grep），所以今天沒有真的繞過。
- 修法：同一個測試加第二張表：`RustClaimStore(` 只准出現在 `claim.dart`（2 次）、`RecordUiStore(` 只准 `main.dart`（1 次）；或把這兩個類別的寫入方法收窄（`RustClaimStore` 只接受 `node/` / `claim-pending/` 的 rel）。並把檔頭的說法改成「直接呼叫 + 這兩個包裝類別的建構」。

### MINOR-3 ScanPage：「搜尋」等待舊掃描取消時按「停止」，新掃描會在沒有 lease 的情況下開始

- 情境（dev build 才有這頁）：上一次掃描還在跑時按「搜尋」。`_startScan` 拿到/保留 `_scanHold`、把 `_scan` 設成 null、`await old.cancel()`；這段期間沒有 `setState`，畫面上的「停止」還是可按（上一次 build 時 `_scan != null`）。這時按「停止」：`_stop` → `_dropScanHold()` 交回 lease。`await` 回來後 `mounted`，照樣 `scanForDevices`，但 `_scanHold == null`，掃描在沒有 raw lease 時跑，NodeLink 可以同時用藍牙（T20 要防的就是這個）。
- 證據：scan.dart `_startScan`（hold 在 await 之前取得，await 之後沒有再檢查）、`_stop`（無條件 `_dropScanHold()`）、build 的「停止」`onPressed: _scan == null ? null : _stop`。窗口是 cancel 完成的那幾毫秒，所以 MINOR；`scan_page_test.dart` 沒有這條。
- 修法：`await cancelling` 之後，若 `widget.use != null && _scanHold == null` 就 return（或 `_stop` 在 `_starting` 時只設一個「已停止」旗標，`_startScan` await 後看到就不開始）；加一條 widget 測試：卡住舊 cancel → 按停止 → 放行 → 斷言沒有新的 scan 且 lease 已交回。

### MINOR-4 T14：種類資料夾「裡面某一項」讀取錯誤的分支沒有被測試誘發

- 情境：`store_has_records` 的 `for e in entries { Err(e) => err.get_or_insert(...) }`（simple.rs）把逐項錯誤當成 Err。測試只誘發了 `read_dir` 本身的錯誤（ENOTDIR、mode 000）；把逐項 `Err(e)` 分支改成 `Ok(_) | Err(_) => {}` 不會有任何測試 FAIL（照使用者規則，白箱要誘發該處理的錯誤）。
- 程度：逐項錯誤在 Linux/Android 上很少見（`readdir` 中途 EIO），而且 plan §9 把「目錄中某一項讀取錯誤」列成今天真正的毀損路徑之一，所以值得一條，但不擋。
- 修法：把逐項迭代抽成接受 `impl Iterator<Item = io::Result<DirEntry>>` 的小函式（或接受一個 `io::Result<bool>` 的判斷），用假的 `Err(io::Error::other(..))` 驅動；負向對照 = 吞掉逐項錯誤 → FAIL。或在 #329 寫明這個分支只有原始碼審查、沒有測試。

## 沒有驗到的（⚠️ / ❌）

- ⚠️ `KeyHandlersDeviceTest.open_gatedOnTheLiveRecordAesLevelOnly`（instrumented）沒跑：規則禁止碰模擬器/手機。只讀過原始碼：用 `bmtest-` 別名、前後刪除，不會碰 `batman-` 金鑰。
- ⚠️ 真機上 open 多一次 `KeyInfo` 讀取的耗時與暫時錯誤率沒量（plan T1 寫 S20 讀 log）。
- ❌ dev2Debug / fieldDebug 的 Kotlin 測試、完整 flutter 測試套件、Windows 原生 cargo（缺 dlltool）沒跑。
