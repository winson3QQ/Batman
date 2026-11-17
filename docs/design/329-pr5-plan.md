# #329 PR 5 實作計畫 v16（FROZEN 2026-11-17：使用者決定凍結；十五輪審查的處理見附錄 A）

**v10 是重寫，不是補丁。**
- v1–v9 一路打補丁，同一條規則散在好幾節。第七、九輪的 MAJOR（M-M1、R-M1、Q-M1）都是「改了一處、別處留著舊規則」。
- v10 的寫法：
  - 每條規則只寫在一個地方，標成 **規則 Rn**，其他地方只寫「見 Rn」；
  - 正文不再有版本標記，來由都在附錄 A。
- v10 另外拿掉兩個我自己加、又一直出問題的機制：
  - 「清除只清自己複製的」（v8 N-m8）：它要讀剪貼簿才能比對，Android 12 以上每次都會跳系統提示，還造成了 O-M1 / P-M2。
  - 從 Rust 句子裡解析「第 N 版」（v9 P-M1）：有兩種情況拿不到這個數字（R-m1、Q-m4），而且解析顯示文字很脆弱。

上層設計：`docs/design/329-app-uiux.md`（v12.1）。本 PR 用到的章節：
- §12 第 5 列；
- §5.7；
- §4.1、§4.4、§4.7；
- 情境 2、3、6；
- T10、T15；
- 測試 T-Q1、T-Q2、T-V1、T-V2、T-R1、T-S1、T-S5、T-N2。

畫板 7.1、7.3–7.10、8.1–8.5（畫布 v5）。main = 2e18de6。

## 0. 範圍

**行為基準**：以下都已設計、已審、已合併。本 PR 照搬，不重新決定。
- **協定**：`219-protocol.md` §7.4 / §7.6，包括三段式邀請、確認碼（SAS）、qr-object。
- **隊員節點入網**：`254-app-member-join.md` v6.1。
- **移除隊員與換密碼**：`254-app-remove-member.md` v6.5，包括：
  - 前置條件勾選（F32）；
  - 更新包；
  - 隊員匯入；
  - 送新密碼；
  - `update_hint`。
- **掃描器**：`254-app-qr.md`。
- **舊控制台的函式**（`lib/nodes.dart`、`lib/member_ui.dart`）：步驟順序、Rust 呼叫、寫入順序、gate、逾時值照搬。
  - 隊長端：`_makeInvite`（798-812）、`_checkRequest`（815-864）、`SasConfirmView` / `SasShowView`（member_ui.dart:39-101）；
  - 隊員端：`_takeInvite`（867-878）、`_requestJoin` / `_showRequest`（881-910）、`_showPendingBody`（926-954）、`_takeApproval`（957-999）、`_importApproval`（1001-1037）、`_memberJoin`（1040-1062）；
  - 隊員與移除：`_members`（1311-1344）、`_remove`（1348-1421）、`_runRemove`（1425-1448）、`_makeUpdates` / `_updates`（1450-1499）；
  - 換密碼：`_takeUpdate`（1503-1542）、`_sendUpdate` / `_sendUpdateFor`（1546-1582）。
- **Rust 入口的行為全部不改**，含 `dev_gate`（member.rs:17-23）。唯一的 Rust 改動是兩個只讀的顯示欄位（V-M1）：
  - `NetView.version`：網路目前的版本號；
  - `MnetView.version`：這支手機 mnet 的版本號。

  兩者都只讀出紀錄裡已有的數字，不改任何判斷。比照 PR 4 加 `SettingsView` 的做法，附 Rust 測試，綁定照 PR 4 的方式重新產生。
  - 兩者和 `memberUpdatePrepare` 句子裡「更新到第 {to} 版」的 `to`，都是同一個計數：netcfg 的版本。Rust 測試把這三個數字釘在一起（X-m4 / W-m10）。
  - netcfg 解不開時，`net_summary` 現在對國家與名稱用預設值（owner.rs:111）。`version` 不照這個做法：解不開就回 `None`，畫面寫「版本讀不到」，不顯示 0（Y-m5 / Z-m2）。
- **PR 1–4 已合併的機制**：
  - 登入與 console：`loginFor`、`OwnerConsole`（含 persistPend / persistMnet，owner_console.dart:281-307）；
  - 佔用與寫入：`RecordWriter`、佔用（`hold` / `pageGone` / 420 s）；
  - 流程殼：`OpSession.once` / `OpenSession`；
  - 加入網路的等待頁（net_pages.dart）；
  - `SecureScreen`。

**本 PR 新做的**（審查範圍，共 10 項，下面逐項列出）：
1. QR 顯示與收碼元件（2.1、2.2）；
2. 掃描器解析度（2.1）；
3. `OwnerConsole` 加的請求（2.3）；
4. 換密碼提示在讀取那一輪算（2.4）；
5. 不連節點的寫入殼 `OfflineOp`（2.5）；
6. 記憶體 controller（2.6）；
7. 13 個新頁面（2.7、2.8）；
8. 換密碼結果的共用元件 `RekeyResult`（2.9）；
9. 入口（2.10）；
10. `NetIndex` 多記的欄位（2.11）。

**對 PR 1–4 程式的改動**（S-m10：v10 只列了四處，不完整），全部列在這裡：
- `Lease.revoke({String? todo})`，以及首頁待辦卡直接顯示整句（R12）；
- `SessionProber`：在 answer 那一步算提示，並且取消時先交出已經讀到的狀態，改 prober.dart:83（R7）；
- `NodeLink`：`hints` 表與 `netKnown` 回呼（R8）；
- `SecureScreen`：可選的 `fallback`（R3）；
- `OwnerConsole`：`joinreq` / `memberJoin` / `info` 與 `_pendSaved`（2.3）；
- `AppLink`：`devTrust`、`InviteHolds`、`RemoveTicks`（2.6）；
- `NetFormPage` 與 `NetRun`：member 分支（R16），以及新密碼結果改用 `rekeyEnd` 分類，「正在套用」不再算成功（R14，T-M2）。
- `NetIndex`（2.11）、`node_page.dart`（2.10）、首頁待辦卡（R12）。
- 入口與頁面的接線：`home_page.dart` 的 `_act`、`add_pages.dart`（3.6）、`settings_page.dart`（「隊伍與邀請」）、`main.dart`（把 `devTrust` 交給 `AppLink`）（Y-m6）。

**不做**（設計已定）：
- 7.2 一次性預先同意（T10）；
- 分享成圖片（T10）；
- 勾選存檔（T15）；
- 全隊頁 6.x（PR 6）。

舊控制台整個留著，PR 6 才刪。

## 1. 事實（main 2e18de6）

| # | 事實 | 證據 |
|---|---|---|
| P1 | 舊控制台的成員流程走它自己的 BLE `_login` / `_ask`，不經 `NodeLink` / `OwnerConsole` | nodes.dart:194-427、:511-589 |
| P2 | 新 UI 的 mnet 加入、看申請、加入隊長的網路，現在都開舊控制台，而且沒有 devTrust gate | home_page.dart:183-190；add_pages.dart:124-130、:147-151 |
| P3 | 節點頁沒有隊員分組 | node_page.dart:135 |
| P4 | 首頁沒有 mpend 待辦 | home_page.dart:305-330 |
| P5 | `NetIndex` 對 mnet / mpend 只有布林 `anyMnet` / `anyMpend` | net_index.dart:44-45、:60、:183 |
| P6 | `OwnerConsole` 的步驟迴圈已處理 persistPend / persistMnet；`_persistedRel` 只記 persistNet | owner_console.dart:281-292 |
| P7 | `ConsoleReply` 有 `sendUpdate` / `pollLink` / `value`（PR 4），沒有 hex / sas | owner_console.dart:88-128 |
| P8 | 新 UI 裡不連線寫入的先例：`link.acquire(…, session)` + `lease.run(writer…)` | more_pages.dart:80-92；net_pages.dart:307-320 |
| P9 | devTrust 的三層 gate：Dart `DevOnlyButton` / `PasteButton`、Rust `dev_gate`、Kotlin `EcdhPeer.accept`。`request_send_update` / `request_info` 沒有 `dev_gate` | member_ui.dart:105-165；member.rs:17-23；EcdhPeer.kt:41-42；owner.rs:1041 |
| P10 | 舊控制台：貼上後一律清剪貼簿；複製後不清 | nodes.dart:728-732；:789、:899、:1441 |
| P11 | 收下的邀請 `_inviteHex` / `_invite` 在頁面記憶體；收下不寫紀錄 | nodes.dart:116-117、:867-878 |
| P12 | 移除後的「已複製」記號 `_copied` 以 owner 為鍵，存在頁面記憶體 | nodes.dart:130、:1483、:1494 |
| P13 | `_memberJoin` 之後如果有 `_sendAfter`，自動 `_sendUpdateFor`；之後 `_watchLink` | nodes.dart:1056-1060、:687-716 |
| P14 | `update_hint` 依同一個 session 剛讀過的狀態頁；只在 info k10 等於紀錄的網路代號時才有內容 | owner.rs:949-965、:1098-1101；bridge rekey.rs:466-486 |
| P15 | R-8：要求 1280×960 時相機給 1440×1080。QR 佔取景框約一半時，三種碼 5 次裡都至少 4 次在 5 s 內掃到。640×480 時 request 怎樣都掃不到 | #329 留言 6917175962 |
| P16 | 大寫十六進位、ECC L：invite v16、request v26、approval v27 | 同上 |
| P17 | 手機另有 `dev2` flavor，有自己的 applicationId 與 Keystore | build.gradle.kts:66-69 |
| P18 | Kotlin 沒有 QR 產生的程式；ZXing core 3.5.4 已是依賴 | build.gradle.kts:109 |
| P19 | 舊 `_remove` 讀 `removeOwnNodes(對象)`（排除對象）與手機紀錄的交集，每台都登入 | nodes.dart:1353、:1360-1375、:171-174 |
| P20 | 隊員加入只接受 mnet 的入口節點，別台回 `NotThisNode` | join2flow.rs:78、:380-384 |
| P21 | `mnet_summary` 只給入口節點的後四碼 | member.rs:303-327 |
| P22 | 送新密碼的結果：`Updated`「已換成新密碼」、`AlreadyCurrent`「已是新密碼」、`Applying`「正在套用…」，三者都以 `[UPDATED]` 開頭；失敗以 `[REQ_FAIL]` 開頭 | bridge rekey.rs:430-458；updflow.rs:258、:316-317 |
| P23 | 隊員端的 `AlreadyCurrent` 只比節點和手機 mnet 的版本；貼了舊的更新包時，匯入回「已經匯入過」 | updflow.rs:252-258；mupdate.rs:298-299 |
| P24 | 隊員加入確定失敗後，mnet 的入口資料被拿掉，之後回 `NoEntry`「需要新的邀請」 | owner.rs:584、:2577 |
| P25 | `Lease._revoke` 會加入首頁待辦，並讓 `RecordWriter` 拒絕之後的寫入 | lease.dart:140-149；record_writer.dart:27-33 |
| P26 | probe 在 `done` 之後立刻清理並 dispose session；20 s 答覆計時器在 :172 | prober.dart:69-71、:172、:188-205 |

## 2. 做法

### 2.1 Kotlin

- **`qrMatrix(text)` → `{size, version, bits}`**
  - 輸入只接受 `[0-9A-F]`，長度 1–4096；不合就回錯誤 `qr`。
  - 用 ZXing `Encoder.encode(text, L, margin 0)`，版本與點陣都取自同一個 `QRCode`。
  - `bits` 一列一列排，每格一個位元；每一列補到整數個位元組，所以長度是 `size × ⌈size / 8⌉` 個位元組（Y-m9）。
  - 文字不記錄。
- **剪貼簿**
  - `copyCode(text)`：`ClipData` 加上 sensitive 旗標。
    - Android 13 以上用 `ClipDescription.EXTRA_IS_SENSITIVE`；
    - Android 12 用字面字串 `android.content.extra.IS_SENSITIVE`，有沒有作用 ⚠️ 未查證；
    - 接住 `TransactionTooLargeException`，回錯誤 `clipTooLarge`。
  - `clearClip()`：`clearPrimaryClip()`。**只有這一個清除**。
- **錯誤訊息**：Kotlin 回給 Dart 的錯誤訊息都是固定字串，Dart 只記錯誤代碼。
- **掃描器**
  - `QrScanActivity` 的 ImageAnalysis 用 `ResolutionSelector(1280×960, CLOSEST_HIGHER_THEN_LOWER)`（P15；這段已在工作樹裡）。
  - 取景框下方加一行「掃不到時，拿遠一點，讓 QR 在框裡約一半大」。
  - 其他照 254-app-qr。
- **原始碼檢查**：新的 Kotlin 檔不能出現 `Log.`、`println`、`printStackTrace`；負對照是加一行 `Log.d` → FAIL。
- **T-Q1**（JVM）：
  - 三種向量編碼再解回來要和原文相同，版本等於 P16；
  - 4096 個字元的輸入，版本 > 27；
  - 4097 個字元與小寫字元回錯誤；
  - 負對照：改成小寫 → 版本變大 → FAIL。

### 2.2 `CodeView` / `CodeInput`

**R18　後四碼一律用 `sameLast4(a, b)` 比，不分大小寫。**（Y-M1：W-m6 只修了 `rekeyEnd` 一處，這是「規則只改一處」那一類的第六次）
- Rust 給的後四碼保留 device_id 原本的大小寫：`mnet_summary.device_last4`（member.rs:322）、`PersonNode.last4`（rekey.rs:79），以及 `update_text` 的句子（owner.rs:717）。Dart 的 `last4()` 會轉成大寫（home_logic.dart:8），只用在顯示。
- 用到的地方：
  - R16 找入口節點；
  - 8.4 找候選節點；
  - `rekeyEnd` 的錨定句子：用 `sameLast4` 比句子裡的那四個字元，其餘部分逐字比對。
- 原始碼檢查：Rust 給的後四碼欄位，不能用 `==` 或 `last4()` 去比。
- 測試：用含字母的小寫 device_id，三個地方都要比得到；負對照：其中一處改用 `last4() ==` → FAIL。

**R1　QR 何時畫。** 只有在 `qrMatrix` 成功、`version ≤ 27`（R-8 量過的最大版本），而且 `size == 17 + 4 × version`、`bits` 長度等於 `size × ⌈size / 8⌉` 時才畫。其他情形不畫 QR，顯示原因句，「複製文字」照樣可用。
- 例：超過 v27 時顯示「這個碼太長，無法用 QR 顯示，請用「複製文字」傳給對方」。
- 同意碼帶網路紀錄的成員名單，這份名單只在換密碼時重簽（approve.rs:217；rekey.rs:330）。所以第一次移除之前，同意碼都和向量差不多大，之後會變大。判斷一律看編碼器給的版本。
- ⚠️ 實際長度在實作時用 Rust 測試量，回填這裡。

**R2　QR 怎麼畫。** `CustomPaint`，白底黑格，四邊各留 4 格。
- 格寬取整數個實體像素：⌊可用寬度的實體像素 ÷ (size + 8)⌋。原點也對齊實體像素。不做抗鋸齒。
- 格寬算出來是 0 時，照 R1 當作不能畫。
- widget 測試：把畫面讀回來，每一格的**每一個像素**都要和 `bits` 一致。因為 FLAG_SECURE，真機上截不到圖，這是唯一的驗證。

**R3　防截圖。** 每個 QR 與每個確認碼各自包在一個 `SecureScreen` 裡。
- 防的是什麼（V-m9）：碼不是秘密，但同意碼帶著全隊的名單與節點名稱，申請碼帶著節點名稱，這是隱私。所以照上層設計 §8，設不了防截圖時不顯示 QR。複製文字仍然保留，因為碼一定要傳得出去。`SecureScreen` 多一個可選的 `fallback`：
- `CodeView` 不另外以文字顯示碼本身，只有 QR 與「複製文字」按鈕；所以沒有一段碼的文字落在 `SecureScreen` 外面（X-m6）。
- 沒給 `fallback` 時行為完全不變。新增一個測試：平台回答「設不了」時，Wi-Fi 頁照樣顯示原本那一句。
- 等待 Android 回答時（`_on == null`），什麼都不顯示，和現在一樣。
- QR 的 fallback：「這支手機無法防止截圖，所以不顯示 QR」，「複製文字」照樣可用。
- 確認碼的 fallback：照樣顯示確認碼，加一行「這支手機無法防止截圖」（D6）。
- 這種手機上，剪貼簿那一句警告一直顯示。

**R4　剪貼簿。**
- 「複製文字」：`copyCode`，複製原本的小寫十六進位。
- 新頁面不自動複製，和舊程式不同（舊程式一做完就複製）。
- 複製之後出現「清除剪貼簿」，按下就是 `clearClip()`，清掉剪貼簿上的任何內容。這是使用者自己按的。
- 按鈕旁固定一行：「鍵盤 app 自己的剪貼簿紀錄，這裡清不到」。
- 離開這一頁時，如果複製過、又還沒按清除，用 SnackBar 提醒一次。
- **貼上之後一律 `clearClip()`**，照 P10。測試：貼上別的 app 複製的碼，剪貼簿要被清空；負對照：不清 → FAIL。

**R5　收碼。** `CodeInput(onText)` 有兩顆按鈕：「掃描 QR」（現有的 `scanQr`）與「貼上文字」（只在 devTrust，照 `PasteButton`）。
- 被拒絕的貼上（太長、解析失敗）也一樣先清剪貼簿，測試涵蓋這兩種情形（Z-m6）。
- 兩條路都把文字原樣交給 Rust 解析。`from_hex` 接受大寫與空白（T-Q2）。
- 貼上的文字超過 300 000 字元時不送進 Rust，顯示「這段文字太長，不是 app 產生的碼」。128 KiB 的更新包是 262 144 字元。

### 2.3 `OwnerConsole` 加的請求

每一個都是搬過來的舊程式 `_ask` 呼叫，`wait` 與 `unclear` 都照舊程式的值。

| 方法 | 舊程式 | wait / unclear | 回傳 |
|---|---|---|---|
| `joinreq(inviteHex, name, pendGen, pendPlain)` | `_requestJoin` | 15 s；斷線時回 `joinreqLostLine(saved: _pendSaved)` | `value` = `(hex, sas, renewed)` |
| `memberJoin(mnetGen, mnetPlain)` | `_memberJoin` | 360 s；`_joinUnclear` | `sendUpdate` / `pollLink`（P7） |
| `info()` | `requestInfo` 的使用處 | 15 s | `value` = `NodeInfo` |

- `_pendSaved`：步驟迴圈在 persistPend 寫好時設為真，做法同 `_persistedRel`。負對照：在 persistPend 之前與之後各斷一次線。
- 紀錄的 `(gen, plain)` 一律在佔用之內讀，也就是在 `once` 的 requests 裡讀。
- `memberJoin` 之後、`sendUpdateFor` 之前，重讀 mnet（nodes.dart:1573）。

### 2.4 換密碼提示（`update_hint`）在讀取那一輪算

這是凍結基準 remove-member §3.5 的共用規則（:184-185；T7、T7b）：自己的節點版本落後時，節點頁要出現「這台還在舊密碼 — 把新密碼送給節點」。舊控制台在讀狀態時算（nodes.dart:1158-1177）。新 UI 改由 `SessionProber` 在讀取時算（D8）。

**R6　什麼時候算。** 下面三個條件都成立才算：
- devTrust 版本；
- `netKnown(netId)` 為真：net 與 mnet 都算，所以隊員端也算得到提示（Y-m3）；這是注入的唯讀回呼，背後讀 `NetIndex`，`NodeLink` 自己不碰 `NetIndex`；
- 這台的節點頁正開著（`core` 的頁面狀態是 node，id 相符）。

所以 field 版、以及節點頁沒開時，`openNet` 一次都不會被呼叫，測試要驗。

**R7　怎麼算。** 在 answer 那一步、`done` 之前：
1. 取消 20 s 的答覆計時器，先算出 `StatusView`；
2. 依序打開 `net/<netId>`、`mnet/<netId>`，用第一筆打得開的呼叫 `session.updateHint`，`member` 依打開的是哪一種決定：net 帶 false，mnet 帶 true，帶錯提示會靜默不出現（AD-m3），然後丟掉明文。整段上限 2 s，例外在本地接住，只記 `runtimeType`；
3. `done(Outcome(...StatusView...))`。

- 等提示的這段時間，如果讀取被取消，立刻放棄提示，照常 `done`（帶 StatusView）。所以 prober.dart:83 的取消處理要改：已經有 StatusView 時交出它，而不是 `noResponse`（S-m5）。測試：等 `openNet` 時取消 → 結果是讀到的狀態；負對照：不改 :83 → FAIL。
- `probe` 一開始清理就設 `cleaning`。`openNet` 回來後，先看這個旗標，已經在清理就不呼叫 `updateHint`。`updateHint` 是同步呼叫，所以檢查和呼叫之間不會被 dispose 插進來。
- session 的生命週期不變：只有 `probe` 的清理會 dispose 它。
- 白箱測試：
  - 假 session 在 dispose 之後呼叫會丟例外：照這個順序，提示出現；把提示改到 `done` 之後算 → FAIL。
  - `openNet` 丟例外、`openNet` 3 s 才回來、等提示時讀取被取消：三種情形，讀取的結果都照常。

**R8　`hints` 表。**
- 只有這一輪讀取成功（`Res.body`）時才更新；讀取失敗、被限速或錯誤的那一輪保留舊值。所以 info 讀不到時，不會用空提示清掉「還在舊密碼」（V-m3）。
- info 讀不到時，那一輪的 `StatusView.netId` 是空的（owner.rs:949-965）。所以：`netId` 空、而且節點狀態不是「沒加入網路」（`nodeState != 1`）→ 保留舊值；節點狀態是「沒加入網路」→ 清掉，因為節點真的離開了（Z-m1 / Y-m2：v13 的「沒有 k9 就保留」Dart 看不到 k9，做不出來）。
- 只有 `NodeLink` 寫：`onHint(id, hint)`。寫之前再確認那台的節點頁還開著。空的提示（`line` 是空字串）不存，等於清掉那台的提示，所以不會出現空的警告卡（S-m12）。
- 有變化時觸發 `changed`。算失敗或逾時的那一輪保留舊值。
- 測試（AB-m5）：讀取失敗的那一輪，舊提示還在；節點回報「沒加入網路」的那一輪，提示被清掉；負對照：對調這兩條 → FAIL。
- 離開節點頁、忘記節點、紀錄被移除時清掉。
- 不進 `UiState`。`Outcome.extra` 不變。

**R9　提示只是「要送」，不是「換好了」。** 提示卡不見，不代表換好了。換好的判斷只有 R14。

### 2.5 不連節點的寫入：`OfflineOp`

```
static Future<OfflineReply<T>> run<T>(AppLink a, String name, OfflinePlatform p,
    Future<T> Function(Lease l, RecordWriter w) work)
```

**R10　流程。**
`runNetOp(step, lease, writer, platform)`：把舊程式的 `_runOp` / `_runRemove`（nodes.dart:773-795、:1425-1448）抽出來，做 SignAdmin → PersistNet 的迴圈，只回傳 `(hex?, detail, note)`。所有「簽章再寫 net 紀錄」的 `work` 都用它（Y-m7）。

1. 拿 session 佔用；拿不到就回 `busy(佔用者名稱)`。
2. 執行 `work`。
3. 放掉佔用。

- `work` 的例外由 `OfflineOp` 接住，回 `failed(line)`。`line` 是 Rust 的拒絕原句，照舊程式原樣顯示。文字紀錄只寫 `runtimeType`。其他例外的句子照舊程式（S-m8）：`PlatformException` →「手機的金鑰無法使用：〈代碼〉」；佔用被拒（`NoLease`）→「另一個操作還在進行」；CAS 衝突 → `staleRecordLine`（nodes.dart:57、:1532）。
- 進行中，頁面用 `PopScope` 擋返回。`OfflineOp` 回來或被收回時解除。
- `OfflinePlatform` 提供 seal、open、signAdmin、ecdh。
  - ecdh 回來的位元組先複製一份（`_ownCopy`）；
  - `z` 在 `work` 的 `finally` 歸零；
  - signAdmin 失敗時經 `keyCheck`（X26）。
- `work` 只回傳顯示用的字串與 hex，不回傳紀錄明文。剪貼簿與對話框（`showDupNote`）都在 `OfflineOp` 回來之後才做。
- 操作名稱一律用常數，不帶隊員或網路的名稱。這些名稱會進 `debugPrint` 與待辦。

**R11　在佔用裡重讀。** 用到紀錄的 `work`，一開始先重讀紀錄，用讀到的 generation：邀請、同意、移除、產生更新包、匯入同意、匯入更新包、放棄申請（T-m5 / S-m11：v10 漏了邀請）。

**R12　60 s 上限。**
- `work` 超過 60 s，就呼叫 `Lease.revoke(todo: '上一個操作可能沒有存完：<名稱>，請重新打開那一頁確認')`：
  - 新的公開方法，內部呼叫既有的 `reg._revoke`（P25）；只有 `OfflineOp` 能呼叫，用原始碼檢查鎖住（V-m7）；負對照：在別的檔案呼叫一次 `revoke(` → 原始碼檢查 FAIL（AB-m5）；
  - 沒給 `todo` 時用既有的句子。
- `unsavedTodos` 是一串整句，首頁待辦卡就直接顯示整句，不再另外加「請到那台節點的頁面」。既有的節點操作，那半句改放進預設句子裡。
- 收回之後，`RecordWriter` 拒絕這個佔用後續的寫入。被收回的 `work` 一直不回來時，頁面停在「結果不明，等一下再查」，有「再查一次」；`PopScope` 已經解除，可以離開（W-m12）。
- 等 `work` 真的結束之後，在新的佔用裡重讀，依操作判斷：重讀要拿新的佔用，拿不到（別的操作正在用）時，畫面顯示「結果不明，等一下再查」，加一顆「再查一次」，不排隊（U-m / V-m6）。

| 操作 | 判斷 | 畫面 |
|---|---|---|
| 移除（對象是人） | 這個人的完整 owner 已不在名單，不用名字比（AB-m3：同名的兩組會騙過名字比對；不看版本號，V-M1 / U-m1） | 「已經移除」→ `RemoveTicks.removed` → 8.4；否則「結果不明」，加一顆「到換密碼檢查清單」→ 8.4（沒有移除那一段），以及「到隊員名單確認」（T-m4） |
| 排除自己的節點 | 那台的 dac_hash 已不在自己那一組，不用後四碼比（AA-m5；U-m2） | 「已經排除」→ 8.4；否則「結果不明」，同上兩顆按鈕 |
| 匯入同意 | 用同一份碼、**`pendPlain: null`** 重跑 `memberImportPrepare`，回 `AlreadyImported`。回 `NeedsNewInvite` 時顯示「結果不明」加 `kNeedNewInvite`（Y-m9）。mpend 還在時，prepare 會走 bind → `Ready`（approve.rs:468-487），所以一定要不帶 mpend（W-m1） | 「已經匯入」；如果 mpend 還在，就在同一個新佔用裡刪掉。否則「結果不明」 |
| 匯入更新包 | 用同一份包重跑 `memberUpdatePrepare`，回 `AlreadyImported` | 「已經匯入」；否則「結果不明」 |
| 放棄申請 | mpend 不在了 | 「已經放棄」；否則「結果不明」 |
| 邀請、同意、產生更新包 | 碼已經丟了 | `unknown`：「結果不明，請再做一次」（重複的同意，Rust 會給 dup 說明） |

- 測試：
  - signAdmin 永遠不回來 → 60 s 收回、之後的寫入被拒絕、待辦出現；
  - 寫入在收回之前已經落地 → 移除判斷為「已經移除」；
  - 邀請不能顯示「已經完成」。

### 2.6 記憶體 controller

**`AppLink.devTrust`**
- `AppLink` 建構時從 main.dart 拿到值（main.dart:104-107 已經讀過，也做了版本一致的檢查）。`AppLink` 存在之前沒有任何入口。

**`InviteHolds`**
- 最多一份 `(hex, InviteView)`，記憶體。
- 7.8 收下時寫入；申請成功時、按「不用這份邀請」時、或 app 關掉時清掉。
- 不寫紀錄，所以不用佔用。

**`RemoveTicks`**
- 結構是 `netId → (removedThisRun, Set<owner>)`。
- 只能經它自己的方法改：8.3 呼叫 `removed(netId)`，它清空勾選、設 `removedThisRun`；8.4 呼叫 `tick`。
- 鍵是完整的 owner。
- 不參與任何判斷（T15、T-R1）。

### 2.7 隊長端頁面

**R13　選網路。**
- 照舊 `_pickNet`：隊員名單、邀請、產生更新包、收申請只列已套用的網路（nodes.dart:802、:1313；S-m7）。
- 同名的網路後面加建立日期與代號後四碼。

1. **8.1 隊員名單**（`netPeople`）
   - 以人分組，「我（隊長）」排第一。每組顯示：
     - 名字；
     - owner 指紋（前 8 碼）；
     - 每台節點的後四碼，加入中的標「加入中」。
   - 同名：用完整的 owner 比，名字相同、owner 不同的兩組標「另有同名的一組：〈指紋〉（要一起移除得各按一次）」；指紋也相同的兩組，加一句「請用加入時間分辨」。
     - 已知限制：形似字可以騙過同名比對，所以每組都一直顯示指紋。
   - 固定一行：「移除隊員之後，要用『產生更新包』把新密碼交給每位留下的隊員，並把新密碼送到你的每台節點」。
   - `removedThisRun` 為真、還有沒勾的隊員時，頂端顯示「還有 N 位隊員沒交更新包」。
   - 頂端固定顯示「目前是第 N 版」，N 取自 `NetView.version`（V-M1）。來源照 R19。隊員唸版本號時，隊長對照這一行。
   - 底部有「邀請隊員」「收隊員的申請」「產生更新包」。
2. **7.1 邀請隊員**：「在旁邊 / 不在旁邊」兩列。兩條都 → `OfflineOp('邀請隊員', makeInvite)` → 7.3，只差下一頁的說明（D3）。
3. **7.3**：`CodeView`，加「下一步：收隊員的申請」→ 7.4。
4. **7.4 收申請**：`CodeInput` → `netCheckJoinreq`。
   - 之前被移出過 → 照舊程式的對話框（:829）；
   - `updateFirst` → 照舊程式的提示（:835）。
   - 一張邀請可以收多份申請。
5. **7.5 核對確認碼**：`SasConfirmView` 原樣搬過來。
   - 標題照 nodes.dart:839。
   - 「數字一樣，同意加入」→ `OfflineOp('同意加入', approve)` → 7.6。
   - busy 或 failed 時，用新的 key 重建畫面，按鈕回到可按。
6. **7.6**：`CodeView`；重複的同意顯示 `showDupNote`。
7. **7.7 確認碼不同**：不寫任何東西。文字寫「不要同意這份申請。請重新邀請，並換一種方式傳送」（D7）。
8. **8.2 單一隊員**：顯示指紋與同名提示。
   - 別人：「移除〈名字〉，全隊換密碼」。
   - 自己：每台節點一行「排除 …xxxx（遺失 / 被抓；換全隊密碼）」，加入中的節點也有。
9. **8.3 移除確認**
   1. 要讀的節點照 P19：`removeOwnNodes(對象)` 與手機紀錄的交集。每台一個 `OpSession.once(那台, c.info)`，一台一台讀，顯示「正在讀第 i / n 台…」。每台的時間上限就是 `loginFor` 與 `info` 自己的時限，**不另外加外層的計時器**（S-m6：外層計時器會讓下一台碰到 busy，K-M1）。
      - 沒有「略過」。
      - 讀不到的寫「節點 …x 讀不到（不檢查這台）」。
      - 測試：第 1 台逾時，第 2 台仍然被讀到。
   2. 跑 `removeCheck`。`reads` 照舊帶上**每一台自己的節點**：讀到的帶 info，讀不到的帶空的 info，不只帶交集（AA-m4；nodes.dart:1361-1375）。
      - 畫面顯示 `RemovePlanView.text`，包括順序說明與「⚠️ 未確認」那一句。
      - `ok` 為假時，不給按鈕，照舊程式（nodes.dart:1380-1397）。
   3. 前置條件勾選用 `removeTickText()`，放在按鈕之前（F32）。
   4. 再顯示一次名字、指紋與同名提示。
   5. 按鈕「移除並換密碼」→ `OfflineOp('移除隊員', startRemove)` → `RemoveTicks.removed` → 8.4。
10. **8.4 換密碼檢查清單**
    - 頂端固定顯示「目前是第 N 版」（`NetView.version`；V-M1）。來源照 R19。
    - **隊員段**：每位留下的隊員一列（`netRecipients`），照舊 `_updates`，顯示：
      - 名字、指紋、節點；
      - Rust 的 `note`；
      - 「複製更新包」：`OfflineOp('產生更新包', startBundle)` → `copyCode`，剪貼簿照 R4；
      - 「已交出」的勾，加一行「這些勾只是幫你記，app 不知道對方換好了沒」。
    - **自己的節點段**：`netPeople` 裡自己那一組的每一台都列出來，讀不到的也列。
      - 對回手機紀錄：手機紀錄的後四碼和那台相同的都算候選，用 `sameLast4` 比（R18）。比對由 `sendNewKey` 的 `expectDac` 做（R17）。後四碼撞號時逐一試。
      - 加入中的標「加入中」。
      - 後四碼是空的、或手機沒有候選紀錄的，標「這支手機從這裡送不了」，並寫下一步：
        - 「到那台的節點頁按『更多』→『把新密碼送給節點』」；
        - 手機沒有那台的紀錄時：「得在擁有它的手機上做，或讓它離開網路」。
      - 每台一顆「送出」→ `sendNewKey(那台)`（R17）。另外要求 `infoNetId` 等於這一頁的網路，否則不送。
    - 沒勾完也能離開。

### 2.8 隊員端頁面

11. **7.8 加入隊伍的網路**
    - `CodeInput` → `parseInvite` → `InviteHolds`。這一步不佔用。
    - 有「不用這份邀請」。
    - 名字：必填，上限 32 個 UTF-8 位元組，顯示「還可以輸入 N 個位元組（約 M 個中文字）」（T-V1、T-V2）。
    - 選節點：列出手機**所有**的 `node/` 紀錄，不依狀態篩選。
      - 被移除後重新邀請的節點，還留在舊的設定裡，它也要能申請（remove-member :147、:186；`request_joinreq` 不檢查節點狀態）。
      - 讀到的照顏色顯示；在網路裡的標「已在網路「…」」；沒讀到的標「還沒讀到」。
      - 只有一台時直接用。
      - 測試：一台已在網路裡的節點也出現在清單上。
    - 「申請加入」→ `OpSession.once(節點, '申請加入', c.joinreq)`；成功後清 `InviteHolds` → 7.9。
12. **7.9 我的申請**
    - 申請碼用 `CodeView`。確認碼用 `SasShowView`，加一句「不要用傳邀請的同一個聊天室核對」。兩者各包一個 `SecureScreen`（R3）。
    - `renewed` 時顯示「申請已換新，要重新核對確認碼」。
    - 「我收到隊長的同意了」→ 7.10。
    - 「放棄申請」：確認句「放棄後，隊長已經給或之後給的同意碼都不能再匯入，要重新申請」→ `OfflineOp` 刪掉 mpend。
13. **7.10 匯入同意與加入**
    1. `CodeInput` → `approvalNetId` → `memberImportPrepare`；之後的對話框照舊程式 957-999。
    2. 核對確認碼：`SasConfirmView`，按鈕「確認碼相同，匯入」。
    3. `OfflineOp('匯入同意', ecdh + memberImportApproval + 刪 mpend)`。
    4. 匯入完成後停在這一頁，顯示「讓這台加入隊長的網路」的按鈕，按了才開始 R16，不自動開始；舊程式匯入後也是停下來，等使用者再按「加入網路」（Y-m8）。
    - 原因句都用 Rust 的原句。
14. **8.5 收到新密碼**
    - 只能貼上（更新包沒有 QR，T10），剪貼簿照 R4。
    - `nodeRecords` 照舊程式：手機所有的 `node/` 紀錄。
    - `updateNetId` → `memberUpdatePrepare` → `OfflineOp('匯入新密碼', ecdh + memberUpdateImport)`。ecdh 只在 `Advance` 時呼叫，照舊程式（S-m8）。
    - **原樣顯示 Rust 的 prepare 原句**，例如「更新到第 {to} 版」（rekey.rs:400），版本號以頁面頂端的「這支手機是第 N 版」為準，請隊員照 R14 的兩件事和隊長核對（Z-M1）（T-M1）。這是顯示 Rust 原句，不是解析文字。
    - 回「已經匯入過」時，警告「這份更新包你之前匯入過了，可能不是最新的」。
    - 頁面頂端固定顯示「這支手機是第 N 版」（`MnetView.version`；X-M1）。匯入成功後重新讀一次 mnet，更新這個數字（Z-m4）。
    - 接著列出手機在這個網路裡的每台節點：逐台讀 `info`，`infoNetId` 相符的就列；讀不到的也列。
      - 每台一顆「送出」→ `sendNewKey(那台)`（R17）。照 T30：不按就不送。
      - 隊員送出前也出確認框：「隊長說大家都拿到更新包了嗎？太早送，你的節點會和還沒換的人斷線」。這和 Rust 匯入後的句子一致（rekey.rs:421；AA-m7）。這個確認框只在 8.5 出現；R17 的 `confirm` 對隊員維持原本的行為。
      - 清單的來源（V-m8）：手機所有的 `node/` 紀錄逐台讀 `info`。`infoNetId` 等於這個網路的列為「這個網路的節點」；讀不到的列為「讀不到，不知道是不是這個網路」，也可以按送出，R17 會再檢查一次。
    - 結果用 `RekeyResult(member: true)`，見 R14。

### 2.9 換密碼的結果：`RekeyResult`

**R17　送新密碼只有一條流程：`sendNewKey(nodeId, {confirm = true, expectDac, expectNet})`。**（U-M1；這是同一類錯誤第五次出現，所以改用結構來防）
1. 第一個 `once`：讀 `info` → `infoNetId` → 判斷手機的紀錄是 `net/<id>`（隊長）還是 `mnet/<id>`（隊員），然後放掉佔用。有給 `expectDac` 時（8.4 從 `PersonNode.dacHash` 帶入），先用 `nodeDacHash()` 比對，對不上就不送，顯示「這台的身分和網路紀錄不符」。
   - 有給 `expectNet` 時（8.4、8.5 帶入這一頁的網路），`infoNetId` 不等於它就不送，顯示「這台不在這個網路」（W-m2）。
   - `infoNetId` 是空的、或手機沒有那筆紀錄時，照舊程式的句子（nodes.dart:1546-1563；W-m12）。
   - `member` 旗標取自這一步判斷出的紀錄種類，`RekeyResult` 也用同一個值（W-m3）。
   - 斷線重登照 `OwnerConsole` 現有的做法（PR 4 的 `OpenSession`：沒有登入時會重新登入）。`OwnerConsole` 沒有搬舊的 `retry: true`（owner_console.dart:6-9），本 PR 也不加（Y-m1：v13 寫「照舊用 retry」是錯的）。
2. 隊長、而且 `confirm` 為真時：在佔用之外出舊程式的確認框（nodes.dart:1568-1572），按取消就停。
3. 第二個 `once`：再讀一次 `info`，`infoNetId` 必須和第 1 步相同，否則不送（U-m）；接著 `sendUpdateFor(rel, member)`。
4. 結果經 `rekeyEnd` 分類，交給 `RekeyResult`（R14）。
5. 從節點頁（提示卡、「更多」）送出之後，對那台觸發一次提前讀取（`NodeLink.refresh`），提示卡跟著更新。舊程式送完也會重讀（nodes.dart:1141-1142；Z-m5）。從設定頁進來時，讀取本來就是停的，不觸發。

呼叫的地方：
- 使用者按下的入口，都用預設的 `confirm = true`：8.4 自己的節點段、8.5、節點頁「更多」、換密碼提示卡。照舊程式，由使用者按的送出預設要確認（nodes.dart:1141、:1558、:1567）。
- `NetRun` 加入之後的自動送出：照舊程式用 `confirm: false`（nodes.dart:668、:1059），在已經握著的 session 上直接送，不再重讀 info（舊程式沒有這一步；W-m4）。
  - 隊員那一支一定要帶 `member: true`，因為 `sendUpdateFor` 的預設是 false（owner_console.dart:507；X-m2）。
  - 結果經 `rekeyEnd`，那一列的狀態照 R14。

原始碼檢查（R14 共用同一份允許清單，W-m5 / X-m3）：
- `sendUpdateFor` 只能出現在三個地方：它自己的定義（owner_console.dart）、`sendNewKey`、`NetRun`；
- 沒有任何地方呼叫 `sendNewKey` 時帶 `confirm:` 參數，一律用預設值（Z-m3：v13 的「`confirm: false` 只能出現在 `NetRun`」是空檢查，因為 `NetRun` 直接呼叫 `sendUpdateFor`）；
- 舊控制台 nodes.dart 是明寫的例外。

測試：
- 按提示卡上的按鈕 → 出確認框，按取消 → 沒有送出；
- 8.4 的「送出」同樣要先出確認框（W-m5）；
- 後四碼撞號：`expectDac` 對不上的那一台自動換下一個候選，全部都對不上才顯示錯誤（X-m1）；
- 負對照：提示卡直接呼叫 `sendUpdateFor` → 原始碼檢查 FAIL。


**R14　送新密碼的結果，一律先經 `rekeyEnd(line, kind)` 分類，再由 `RekeyResult(member, line)` 顯示。** 結果只會從 R17 的兩個地方來：`sendNewKey` 與 `NetRun`。
- `NetRun`：舊的判斷 `starts('[UPDATED] ')` 會把「正在套用」當成成功。改成看 `rekeyEnd`：
  - `current` → 那一列是「已加入」；
  - `applying` → 那一列仍是「已加入」（加入本身已經成功），但用 warn 樣式，不是成功樣式，免得整排全綠藏住沒換完的節點（X-m7）。note 寫「新密碼正在套用，稍後到節點頁再送一次確認」。不走 `_failed`，不跳「繼續 / 停」，也沒有「再試這一台」（V-m2 / U-m3）；
  - 那一列下面用 `RekeyResult` 顯示 Rust 原句與固定文字（W-m4：v12 只寫了「列」，沒寫用 `RekeyResult`）；
  - 其他 → 照舊走 `_failed`。

**`rekeyEnd(line, kind)` → `current` / `applying` / `unfinished` / `unclear` / `failed`**（S-m4 / T-m2；比對順序與預設值依 V-m1 / U-m4）。依序比對，第一個符合的就是結果：
1. `kind` 是 unclear，或句子等於 `_sendUnclear` → `unclear`。這一步要先比，因為 `_sendUnclear` 本身以 `[REQ_FAIL]` 開頭。
2. 整句、頭尾錨定，等於 `[UPDATED] 節點 …{last4} 已是新密碼` 或 `[UPDATED] 節點 …{last4} 已換成新密碼`（rekey.rs:447、:451）→ `current`。`last4` 取自手機的紀錄（owner.rs:717），節點無法偽造。
   - 句子裡的後四碼照 R18 比對（W-m6、Y-M1）。
3. 整句錨定，等於 `Applying` 的句子（rekey.rs:452）→ `applying`。
4. 整句錨定，等於 `Unfinished` 的句子（rekey.rs:445）→ `unfinished`。
5. 其他一律 `failed`，包括沒有前綴的句子。這是 fail-closed。
- 兩邊各一個釘住字面的測試：Rust 測試列出 `update_text` 的每一種 `End` 與它的句子；Dart 測試用同一批字面跑 `rekeyEnd`。任一邊改了句子，就會 FAIL。

原始碼檢查：見 R17（同一份允許清單）。`sendUpdateFor` 的結果只能交給 `rekeyEnd`。

`RekeyResult` 的行為：
- 一律顯示 Rust 的原句。樣式依 `rekeyEnd`，不看前綴：只有 `current` 是成功樣式，其他都是中性。
- 原句是 `Applying` 時，下面加一行「狀態頁就是那台的節點頁」。
- 結果不明（360 s）時，顯示舊的 `_sendUnclear` 句子。
- 固定文字：

| member | 固定文字 | 什麼時候打勾 |
|---|---|---|
| false（隊長） | `kRekeyDoneRule`：「每台都要看到『已是新密碼』或『已換成新密碼』才算換好。沒看到的，再按一次『送出』確認。看到『正在套用』或『還有沒完成的變更』時，等幾分鐘再按；超過 10 分鐘仍如此，重新開機一次。沒看到這兩句、或讀不到的節點，被移除的人仍可能連得上。」 | `rekeyEnd == current` |
| true（隊員） | 分成兩件事，分開顯示（Z-M1）：
1. **手機拿到的更新包是不是最新的**：一直顯示「這支手機是第 N 版」（N 照 R19 讀這一筆 mnet；版本讀不到時寫「版本讀不到」，不寫 0），以及「請把這個版本號唸給隊長聽，和他手機上的『目前是第 N 版』比對；不一樣的話，請他重新產生你的更新包」。
2. **這台節點有沒有換好**：只有 `rekeyEnd == current` 時，才寫「這台節點已換成這支手機的版本」；其他結果一律寫「這台還沒換好，先不要跟隊長說換好了」。

兩件都成立，才算這台換好。 | **一律不打勾**（T-M1，fail-closed）。隊員的手機沒辦法知道自己拿到的是不是最新版本：舊的、隊長真簽章的更新包也會被接受（mupdate.rs:263-268） |

- 隊長的「被移除的人仍可能連得上」那一句一律顯示，不看 `removedThisRun`，因為 app 被殺之後它就不在了（T-m3）。
- 隊長的固定文字再加一句：「app 看不到其他隊員有沒有把新密碼送到他們自己的節點，要請他們各自確認」（X-m5；這是基準的限制，只加說明）。要確認的就是兩件事：他的手機版本和你的「目前是第 N 版」一樣，而且他的每台節點都看到「已換成這支手機的版本」（Z-M1）。
- 測試：
  - 原句是 `Applying` 與 `[REQ_FAIL]` 時，不打勾；
  - 第一次送出回 `Applying`、第二次回 `AlreadyCurrent`：只有第二次之後打勾；
  - 隊員端任何結果都不打勾；
  - 回 `[REQ_FAIL]`、`Applying` 或結果不明時，畫面上**沒有**「已換成這支手機的版本」，而且有「先不要跟隊長說換好了」；負對照：改成一律顯示 → FAIL（Z-M1）；
  - `NetRun` 加入後送出回 `Applying` → 那一列是「已加入」，有 note、沒有「再試這一台」；回 `[REQ_FAIL]` → 走 `_failed`；負對照：改回看前綴 → FAIL；
  - `rekeyEnd` 每一步各一個測試，另加「不認得的句子 → failed」；
  - 負對照：任一處繞過 `RekeyResult` 直接顯示原句 → 原始碼檢查 FAIL。

### 2.9.1 版本號的來源

**R19　畫面上的版本號一律直接讀紀錄，不用 `NetIndex` 的快照。**（AB-M1：版本號舊了，舊更新包就能通過唸號核對）
- 隊長端（8.1、8.4 的「目前是第 N 版」）：
  - 讀的時機（AC-M1：v15 只寫了「打開時、自己寫入後」，8.3 移除完回到 8.1 時就沒有重讀）：
    - 頁面打開時；
    - 頁面重新顯示時（從疊在上面的頁面返回）；
    - `NetIndex` 通知變化時。`NetIndex` 只當觸發，數值一律重讀紀錄。
  - 讀法：`storeReadSealed` + open + `netSummary`。讀紀錄不需要佔用。
  - 8.4 也照這個時機讀，所以從 8.3、從 R12 收回後、從「產生更新包」進來都一樣，不需要 `work` 回傳紀錄（AC-m6：v15 寫「用剛寫進去的那筆」，和 R10 的「`work` 不回傳紀錄明文」矛盾）。
  - 負對照：8.3 移除後返回 8.1，必須顯示新的 N → 不重讀就 FAIL。
- 隊員端（`RekeyResult(member: true)`、8.5 的「這支手機是第 N 版」）：讀「這次送出或匯入的那一筆」`mnet/<id>`，旁邊同時顯示網路名稱（AB-m1）。那一筆的來源（AC-m5）：
  - `sendNewKey`：R17 第 3 步交給 Rust 的那同一份紀錄，讓兩件事看的是同一份（AD-m2）；
  - 8.5：這一頁匯入的那一筆；
  - member 模式加入後 `NetRun` 自動送出：這次加入用的那一筆。
  - `MnetView.version` 定義成 `MNet.version`（mrec.rs:93），因為 `current` 比的就是這個欄位（updflow.rs:159）。
  - 「netcfg 解不開時回 `None`」只適用於 `NetView`（AB-m1）。
- 讀取中顯示「正在讀取版本」，不顯示任何數字；讀不到時寫「版本讀不到」。
- 負對照：用重算之前的 `NetIndex` 快照建 8.4，畫面出現舊的 N−1 → FAIL。

### 2.10 入口

**R15　「隊伍與邀請」。**
- 設定頁有一列「隊伍與邀請」，只在 devTrust 版本。
- 頁裡的每一列都**一直在**，不看紀錄。沒有可用的紀錄時，點進去的頁面說明原因。
- 這一頁對應舊控制台隨時能按的那一群按鈕（見 2.12）。
- 測試 T-P5-E：
  - 沒有任何紀錄時，每一列都在而且可以按；
  - field 版這一頁不存在；
  - 負對照：拿掉任何一列 → FAIL。

**R16　隊員的加入（member 模式）。** 只能在 mnet 的入口節點上做（P20、D10）。入口節點用後四碼找（P21），用 `sameLast4` 比（R18）。後四碼撞號、選錯台時，Rust 在寫入前回 `NotThisNode`（join2flow.rs:380-384），頁面顯示原句，改試另一台。v10 寫的「登入後用 `nodeDacHash()` 比對」做不到，因為 `MnetView` 沒有入口節點的 dac hash（T-m1 / S-m1），拿掉。
- 節點頁的「加入網路」：
  - **隊員那一支**：這台是手機某筆 mnet 的入口節點，就出現，不看 nodeState。
    - Rust 在 `PersistFailed{applied:true}`、`_joinUnclear` 以及節點已是成員時（remove-member :186），都叫使用者「在這台按加入網路」，那時節點已經不是 nodeState == 1（U-m：v11 這裡誤寫成「R22」）。
  - **隊長那一支**：照 PR 3，`nodeState == 1 && netFiles > 0`。
  - 兩支都可以時，照舊 `joinChoice` 問「這支手機建立的網路 / 隊長的網路（我是隊員）」。
- **`NetFormPage` 有明確的模式參數 `mode: leader | member`，由入口決定**（AA-M1；v14 的三種情形表套用得太廣，會擋住隊長加入自己的網路，也讓 `joinChoice` 消失）：
  - 入口看到的紀錄如果還在計算中（`records == unknown`），模式在頁內等計算完再決定，照同一份表；「絕不建網」照樣成立（AD-m6）。
  - 入口怎麼決定模式：
    - 手機只有 net → `leader`（PR 3 現有的隊長表單，不變）；
    - 手機只有 mnet（`netFiles == 0`）→ `member`；
    - 兩者都有 → 照舊 `joinChoice` 問「這支手機建立的網路 / 隊長的網路（我是隊員）」（nodes.dart:1777-1786；PR 2 B-M2「兩條路都不能消失」），使用者選的就是模式；
    - 「隊伍與邀請」的「讓我的節點加入隊長的網路」、7.10 匯入之後 → `member`。
  - `leader` 模式：完全照 PR 3，勾選與多選都不變。
  - `member` 模式**不看勾選的節點**，固定在那筆 mnet 的入口節點上跑。手機有多筆 mnet 時，先選網路（`_pickMnet`）。從 7.10 進來時，直接用剛匯入的那個 netId，不再選（AC-m3）。同名的 mnet 照 R13 加上代號後四碼分辨。後四碼撞號、有兩台候選時，列出兩台讓使用者選，不自動挑（AC-m4）。之後依入口節點分三種情形（AA-m1 / AB-m2：首頁第 6 列帶的那一台不一定是入口節點，從「隊伍與邀請」或 7.10 進來時也沒有帶節點）：

  | 入口節點 | 顯示 |
  |---|---|
  | 在手機上（R18 比對） | 在那一台上開始；畫面寫「用節點 …xxxx 加入」 |
  | 手機上沒有那一台 | `kNotEntryNode`，不給開始 |
  | 入口資料已經沒有了 | `kNeedNewInvite`，加「收隊長的邀請」 |
  | mnet 打不開（例如金鑰暫時出錯） | 「這筆隊伍網路的紀錄現在打不開」，加「再試一次」；不叫隊員重新申請（AC-m8） |
  | 手機一筆 mnet 都沒有 | 舊程式的原因句「手機裡沒有匯入過的隊伍網路（先貼上同意碼）」（nodes.dart:1107-1109；AC-m3） |

  - **手機沒有 net 紀錄時，絕不落到「建立網路」**（Y-M2）：net_pages.dart:362 的 `_makes = true`，只在手機一筆網路紀錄都沒有（沒有 net、mnet、mpend）時才成立。
  - `member` 分支讀 `AppLink.devTrust`，不靠呼叫端傳進來（AA-m2：node_page.dart:73、:96 沒有傳）。
  - net_pages.dart:352-360 那個「只給舊控制台」的分支改成：只有 mnet → `member` 模式；只有 mpend → 7.9。
  - 測試：
    - 手機同時有 net 與 mnet、選「這支手機建立的網路」→ 隊長表單，勾選的節點照常可以開始；負對照：套用三種情形表 → FAIL（AA-M1）。
    - 只有 mnet、從首頁第 6 列帶入非入口節點 → 在入口節點上開始（入口節點在手機上時）或顯示 `kNotEntryNode`，都沒有「建立網路」；負對照：拿掉不建網的條件 → FAIL（Y-M2）。
- member 模式的流程：
  1. 用 PR 3 的加入等待頁跑 `memberJoin`（360 s）；
  2. 回 `sendUpdate` 時，照 R17 的 `NetRun` 那一條送出，結果用 `RekeyResult`；
  3. 回 `pollLink` 時做 PR 3 的連線檢查。
- **需要新的邀請**（S-m2）：Rust 的原句**包含**「需要新的邀請」時，顯示原句，加一顆「收隊長的邀請」→ 7.8。`NoEntry` 的句子以括號結尾（owner.rs:584），確定失敗的句子以「需要新的邀請」結尾（:586-590），所以用「包含」，不用「結尾」（V-m4 / U-m5）。
  - **入口資料已經不在的 mnet**（後四碼是空的）：節點頁上沒有任何一台會出現 member 分支。從首頁第 6 列與「隊伍與邀請」進來時，顯示 `kNeedNewInvite`：「這筆隊伍網路的加入資料已經沒有了，需要隊長的新邀請」，加同一顆按鈕（V-m5）。
  - **入口節點不在手機上**：顯示 `kNotEntryNode`：「這台不是你加入隊伍時用的節點；要讓它加入，請隊長再邀請一次」。
  - 這兩句是兩種不同情形，分開命名（U-m：v11 都叫「R16 的那句話」）。
- 測試：
  - 只有 mnet、入口節點已在網路裡 → 隊員那一支照樣在；
  - 非入口節點 → 沒有隊員那一支；
  - 負對照：改成看 nodeState → FAIL。

**其他入口**（都是捷徑，看紀錄；只在 devTrust 版本）：
- **進 `NetFormPage` 的每一個入口，都由入口給定 `mode`**（AC-m1 / AC-m2）。頁內不再改模式；net_pages.dart:352-360 改寫後，只在入口沒給模式時，依紀錄套用上面 R16 的規則。
  - 首頁「建立網路」、`goMake`（node_page.dart:73）、3.6 的「建立網路」：建網，不是加入，照 PR 3。
  - 首頁第 6 列的「加入網路」、3.6 的「加入網路」、節點頁的「加入網路」、待辦「加入沒有做完」：都照 R16 決定模式；兩者都有時問 `joinChoice`。
  - `joinChoice` 的對話框從 nodes.dart 搬到新的 UI 檔案，因為 PR 6 會刪掉 nodes.dart（AC-m1）。
- **首頁第 6 列**（T-N2 的分流不變，只換目的地）：
  - mnet 的「加入網路」→ `NetFormPage`，帶入第 6 列那一台，照 R16 的三種情形顯示（Y-M2：v13 的「入口節點在手機上就做」和 R16 的「只在勾選的那一台上跑」矛盾）；
  - 「看我的申請」→ 7.9；
  - 「加入隊長的網路」→ 7.8。
- **3.6 新增完成頁**：
  - 「我是隊員，加入隊長的網路」→ 7.8；
  - 「加入網路」照 R16。
- **首頁待辦**「你的加入申請還在等隊長同意」→ 7.9。
  - 條件：有 `mpend/<id>`，照上層設計 :699，不加別的條件（V-M1 / U-m1）。匯入後 mpend 沒刪掉的殘留，由 R12「匯入同意」那一列在新佔用裡刪掉（W-m7：理由改正）。
  - 重算時機照 T-H3。
- **節點頁**：
  - **換密碼提示卡**：放在 `StatusHero` 下方、所有分組之前。只要 `hints` 裡有這台就顯示，不看節點狀態。
    - 樣式用 warn；`button` 為真時，卡上有「把新密碼送給節點」→ `sendNewKey(這台)`（R17，有確認框）。
    - 測試：已入網的節點有提示時卡在；把卡放進「網路」分組 → FAIL。
  - **「隊員」分組**：手機有 net 紀錄時出現。這台套用了某個 net 就直接進那個網路，否則選網路。
  - **「更多」**：
    - 「把新密碼送給節點」→ `sendNewKey(這台)`（R17）。
    - 「貼上隊長給的新密碼」：手機有 mnet 時出現 → 8.5。
- **T-S5**：所有新入口在 field 版都不存在。「把新密碼送給節點」的 Rust 入口沒有 `dev_gate`（P9），所以這一列的 Dart gate 一定要測。

### 2.11 `NetIndex` 多記的欄位

- `mpendIds`：`listPends` 的路徑。
- `mnets`：`(netId, netName, entryLast4)`。不存版本號；版本號只照 R19 直接讀紀錄（AC-m7）。用 `mnetSummary` 算完就丟明文。打不開的也記下 id，標成打不開（Y-m4）。
- 計算中的快照保留新欄位的舊值，不清空，畫面不會閃；比對要不要重算的 `_key` 也包含 mnet 與 mpend 的檔案清單（AA-m3；net_index.dart:131-138）。
- 首頁第 6 列照舊看 `anyMnet`。壞的紀錄照 T-L19。

### 2.12 舊控制台每一顆成員按鈕的去處

舊控制台的成員按鈕（nodes.dart:1733-1770），加上舊控制台以外的一顆：

| 舊按鈕 | 「隊伍與邀請」裡（一直在） | 捷徑 |
|---|---|---|
| 隊員名單／移除（:1750） | 「隊員名單」→ 選網路 → 8.1 | 節點頁「隊員」分組 |
| 產生更新包（:1751） | 「產生更新包」→ 選網路 → 8.4（沒有移除那一段） | 8.1 底部 |
| 貼上更新包（:1752） | 「貼上隊長給的新密碼」→ 8.5 | 節點頁「更多」 |
| 邀請隊員（:1757） | 「邀請隊員」→ 選網路 → 7.1 | 8.1 底部 |
| 貼上隊員的申請（:1758） | 「收隊員的申請」→ 選網路 → 7.4 | 7.3、8.1 底部 |
| 貼上邀請（:1759） | 「收隊長的邀請」→ 7.8 | 首頁第 6 列、3.6、R16 的「需要新的邀請」 |
| 申請加入（:1763-1766） | 在 7.8 裡 | — |
| 再顯示申請（:1768） | 「再顯示申請」→ 7.9（多筆時先選） | 首頁待辦 |
| 貼上同意碼（:1760） | 「匯入隊長的同意」→ 7.10 | 7.9 |
| 加入網路，隊員那一支（:1735） | 「讓我的節點加入隊長的網路」→ 選 mnet → R16 | 節點頁、首頁第 6 列、7.10 |
| 把新密碼送給節點（:1745） | — | 節點頁「更多」、提示卡、8.4、8.5（W-m11） |
| 狀態頁的提示（:1744） | — | 節點頁提示卡（2.4） |
| 「忘記加入中的節點」裡的「排除這台」（:1277-1283） | — | 8.2 自己那一組 |
| 忘記加入中的節點（:1741） | 不變（PR 3 已放在開發者選項） | — |
| 3.6「我是隊員，加入隊長的網路」（add_pages.dart:124-130） | — | 改開 7.8，只在 devTrust |

## 3. 介面 / 生命週期

### 3.1 擁有權

| 資源 | 唯一寫入者 | 只讀 |
|---|---|---|
| net / mnet / mpend 紀錄 | 目前的佔用者，經 `RecordWriter`（`OfflineOp` 的 `work`，或 `OwnerConsole` 的步驟迴圈） | `NetIndex`、各頁 |
| `NodeLink.hints` | `NodeLink`（R8） | 節點頁 |
| `netKnown` 回呼 | `AppLink` 注入 | `NodeLink` |
| `AppLink.devTrust` | 建構時由 main.dart 給（2.6） | 所有入口 |
| `NetIndex.mpendIds` / `mnets` | `NetIndex` 的重算 | 首頁、節點頁、各頁 |
| `InviteHolds` | 7.8 | 7.8 |
| `RemoveTicks` | 它自己的方法，由 8.3 與 8.4 呼叫 | 8.1、8.4 |
| 剪貼簿 | 「複製文字」、「清除剪貼簿」、貼上之後（R4） | — |
| `unsavedTodos` | `LeaseRegistry` 加入；首頁在使用者點掉時刪除（S-m13：兩個寫入者，各做一件事，PR 1 就是這樣） | 首頁 |
| 相機、防截圖旗標 | 不變 | — |

### 3.2 契約

| 介面 | 格式 | 缺 / 壞時 |
|---|---|---|
| `qrMatrix` | 大寫十六進位 1–4096 字元 → `{size, version, bits}` | 錯誤或不符合 R1 → 不畫 QR，複製照樣可用 |
| `copyCode` / `clearClip` | 文字 / 無 | 失敗時顯示「複製失敗」或「清除失敗」，不重試 |
| `CodeInput.onText` | 掃描 ≤ 4096、貼上 ≤ 300 000 字元 | 交給 Rust 解析；解析失敗 → 現有錯誤句，什麼都不寫 |
| `ConsoleReply.value` | 見 2.3 | 沒有值 → 顯示 `line` |
| `OfflineReply` | `done` / `busy` / `failed(Rust 原句)` / `unknown`；收回後的重讀結果是 `done`（已經完成）、`unknown`（結果不明），或 `retry`（拿不到佔用，加一顆「再查一次」） | 見 R10、R12 |
| `Lease.revoke({todo})` | 一整句 | 沒給 → 用既有的句子 |
| `NetView.version` / `MnetView.version` | `Option<u32>` | 紀錄解不開時，整個 view 照舊回錯誤；netcfg 解不開時 `version` 是 `None`，畫面寫「版本讀不到」 |

### 3.3 生命週期矩陣

| 路徑 | 之後 | 測試 |
|---|---|---|
| 首次安裝 | 「隊伍與邀請」的每一列都在；捷徑看紀錄 | T-P5-E、T-N2 |
| 頁面中途離開 | 邀請留在 `InviteHolds`；mpend 由待辦接回；勾選留在 `RemoveTicks` | T-P5-1 |
| `OfflineOp` 進行中 | 擋返回（R10） | widget |
| `OfflineOp` 60 s | 收回、待辦、重讀判斷（R12） | T-P5-2 |
| `memberJoin` 進行中 | PR 3 的等待頁 | 既有 |
| app 被殺 / Activity 重建 | `InviteHolds`、`RemoveTicks`、`hints` 都丟；紀錄還在 | T-H3 |
| PersistNet 寫好、碼還沒交到頁面時被殺 | 邀請重新產生；同意重新核對（Rust 給 dup 說明） | widget |
| 移除寫好、還沒進 8.4 就被殺 | 8.1 的固定一行、提示卡、「隊伍與邀請」→「產生更新包」 | widget |
| mnet 寫好、mpend 還沒刪時被殺（AB-m4 / AA-m6） | 照基準處理（member-join :65、:78：殘留的 mpend 無害）。隊員可以在 7.10 重貼同意碼，或在 7.9 按「放棄申請」。v15 的「打開時對帳」拿掉（AC-M2）：app 被殺之後同意碼已經不在手機上，重跑不了 prepare（approve.rs:462-476），硬做只能「有 mnet 就刪 mpend」，會刪掉被移除後重新申請的合法申請 | — |
| 8.3 讀到一半被殺 | 讀取不寫紀錄，重來就好 | — |
| joinreq 中斷線 | `joinreqLostLine(saved)` | T-P5-3 |
| 隊員加入確定失敗 | R16 的「需要新的邀請」 | widget |
| 隊長排除自己最後一台節點 | 「隊伍與邀請」照樣可以進 8.1 / 8.4 | T-P5-E |
| 同意碼超過 v27 | 只能複製文字（R1） | T-Q1 + widget |
| 設不了 FLAG_SECURE | R3 | T-S1 |
| field 版 | 沒有入口；`openNet` 不會被呼叫 | T-S5、R6 |
| 降版到 PR 4 | 紀錄格式不變 | — |
| 相機不能用 | 現有的錯誤句 | 既有 |

## 4. 和設計不同的地方

- **D1**：設計說「掃不到的那一種只留複製文字」。改成依大小決定，見 R1。
- **D2**：改掃描器的解析度（P15）。
- **D3**：7.1 的兩條路做的事一樣。
- **D4**：不做存成圖片、分享。
- **D5**：8.4 只有「已交出」一個勾。
- **D6**：設不了 FLAG_SECURE 的手機上，確認碼照樣顯示（R3）。碼與確認碼都不是秘密。
- **D7**：確認碼不同時，只能不同意這份申請；Rust 沒有撤銷邀請的入口。
- **D8**：`update_hint` 改在讀取那一輪算（2.4），規則不變。
- **D9**：「把新密碼送給節點」只在 devTrust 版本出現。field 版永遠沒有比節點新的紀錄：換密碼與匯入更新包都要過 `dev_gate`。
- **D10**：隊員的加入只在入口節點上做（R16）。舊程式讓使用者任選一台，再由 Rust 拒絕。
- **D11**：Rust 多兩個只讀的版本欄位（§0；V-M1）。
- **D12**：`NetRun` 加入之後的自動送出，「正在套用」不再算成功（R14）。這改了 PR 3 已審過的行為，理由是它會讓被移除的人在隊長不知道的情況下仍連得上。

## 5. 安全

- **資產**：
  - 三種碼與更新包；
  - 確認碼；
  - 管理者金鑰；
  - `z`；
  - mnet / mpend 紀錄。
- **攻擊面**：
  - `qrMatrix` 的輸入由 Kotlin 再檢查一次；
  - 掃描與貼上走同一個 Rust 解析器；
  - 沒有新的埠、intent 或深層連結。
- 剪貼簿警告在 Android 12 一律顯示，因為那裡的 sensitive 旗標效果沒有查證（T-m8）。
- **截圖**：R3。設不了 FLAG_SECURE 時只剩複製文字，這不是 fail-secure，因為剪貼簿更容易外洩；碼本身不是秘密。
- **剪貼簿**：R4。不自動清，這是設計 §8 寫明的殘留。
- **記錄**：
  - 新程式的紀錄行只寫種類、時間、後四碼；
  - 操作名稱是常數；
  - T-P5-L 攔下 `debugPrint` 與 `NodeLink` 的紀錄，搜尋假的碼、確認碼、名稱，負對照是加一行 `debugPrint` 名稱 → FAIL；
  - Kotlin 有原始碼檢查。
  - T-P5-L 再加一個情形：`failed(line)` 帶出的 Rust 句子含有名字時，名字不會進 `debugPrint` 或待辦（Z-m7）。另外涵蓋 `joinreq` 回傳 value 的那條路（AB-m7）。
  - T-P5-L 加一個情形：例外訊息裡含有碼（prober.dart:185 的兜底 catch 會記 `$e`）。新程式碰到碼的地方，例外一律在本地接住，只記型別（T-m7）。
- **`current` 靠的是什麼**（AB-m6）：靠節點自己回報的 k9。被入侵的自有節點可以謊稱已換好，app 沒辦法分辨。「節點無法偽造」只對句子裡的後四碼成立，因為它取自手機的紀錄。
- **被入侵的節點**：
  - key 10 只能讓手機打開 `net/` 或 `mnet/` 底下 16 位元組十六進位的路徑（owner.rs:2260）；
  - 影響只在提示卡的顯示，而提示卡不是「換好」的判斷（R9）。
- **被移除的人仍連得上**：
  - 只認 R14 的正向信號；
  - 8.4 列出全部自己的節點；
  - 隊員端不能宣稱是最新的版本。
- **實體被奪**：節點頁開著時，每一輪都會打開 net 明文，Dart 裡無法歸零。拿到解鎖手機的人本來就能打開所有紀錄，所以列為殘留風險。
- **佔用**：每個寫入都經 `RecordWriter`（T-G5）；收回之後 fail-closed。
- **gate**：見 T-S5。`EcdhPeer`、`dev_gate` 不變。
- **負對照**：
  - 拿掉 `SecureScreen` → T-S1 FAIL；
  - 繞過 Rust 解析 → T-Q2 FAIL；
  - 寫入不經佔用 → T-G5 FAIL；
  - 拿掉 gate → T-S5 FAIL；
  - 繞過 `RekeyResult` → 原始碼檢查 FAIL。

## 6. 步驟（每步都附測試與負對照）

1. **Kotlin**：`qrMatrix`、`copyCode` / `clearClip`、解析度、提示行、原始碼檢查（2.1）。
2. **`CodeView` / `CodeInput`**（R1–R5）。
3. **`OfflineOp`** 與 `runNetOp`，以及 `Lease.revoke` 與待辦卡（R10–R12）。
4. **`OwnerConsole`**：`joinreq` / `memberJoin` / `info`（2.3）。
5. **提示**：`SessionProber` 與 `hints`（R6–R8）。
6. **controller**（2.6）。
7. **隊長端頁面**（2.7）。
8. **隊員端頁面**（2.8）。
9. **`RekeyResult`**（R14）。
10. **入口**：R15、R16、其他入口、2.11、T-S5。
11. **layout_test** 涵蓋新頁面；T-U6、T-P5-L。
12. **全套**：`flutter test`、`dart analyze`、`cargo test`、APK 建置。

每一步做完都用 grep 檢查：本計畫的規則編號在程式與測試裡都有對應。

## 7. 真機（S20；開始前先列副作用，取得同意）

- **不碰節點狀態**：
  - `dev` 產生邀請、各頁面的畫面、剪貼簿；
  - `dev2` 收下邀請；
  - 新入口；
  - 認領 QR 重掃，不按「認領」。
- **R-8 補量**：用電腦螢幕顯示 v31 / v35 / v40 各掃 5 次。通過的話放寬 R1 的上限；不通過維持 27。
- **要動節點、要另外問**：申請要登入隊員自己的節點（04、02 都是 `dev` 的），所以要讓一台節點回到未認領，再由 `dev2` 認領。移除與排除會讓全隊換密碼。
- **做不到**：手機對手機的 QR（只有一支手機）。
- **⚠️ 只在 S20 量過**：解析度只在 S20 量過；大的更新包放進剪貼簿沒有在真機試過。

## 8. 要使用者決定的事

只有 §7 的真機範圍。

## 附錄 A. 審查處理

### 第一輪（v1 → v2；docs/design/329-reviews/review-pr5-plan-A.md、-B.md）

A：APPROVE-WITH-CHANGES，0 BLOCKER / 3 MAJOR / 13 MINOR。B：APPROVE-WITH-CHANGES，0 / 2 / 12。

兩位都抓到的兩個 MAJOR 是同一件事，合併處理。每一項我都對過原始碼。

**MAJOR**

| 項目 | 問題 | 本人查證 | v2 處理 |
|---|---|---|---|
| A-M1 / B-M1 | 8.5 與「送新密碼給節點」綁在 `update_hint`，現場永遠不會出現；隊長自己的節點不換密碼，被移除的人仍連得上（fail-open） | rekey.rs:476-478；prober.dart:123、:193-209 | 2.3、2.6 第 10 / 14 項、2.7：改成常駐入口，照舊 nodes.dart:1745 與 `_sendUpdate`；8.4 列出隊長自己的每台節點；本 PR 不用 `update_hint` |
| A-M2 | 「隊員」入口綁在節點上；排除自己最後一台節點後就進不去 | 254-app-remove-member :19、:151、:250 | 2.6 入口：看手機有沒有 net 紀錄，不看節點；設定頁加一列 |
| A-M3 / B-M2 | 「三種碼都有 QR」只量了一人網路的同意碼；大的碼超過 v27 或 4096；貼上若也設 4096 上限，大的碼就貼不進來 | approve.rs:312-319；cddl :486-491；QrDecode.kt:42 | 2.1：依編碼器給的實際版本決定，≤ 27 才畫 QR；2.2：貼上不設上限；D1 改寫；T-Q1 加 4096 字元的輸入 |

**MINOR**

| 項目 | 處理 |
|---|---|
| A-m1 / B-m8 | joinreq 斷線的句子：步驟迴圈記 `_pendSaved`，套用 `joinreqLostLine(saved:)`（2.3），有負對照 |
| A-m2 | 同意、移除、匯入在佔用裡重讀紀錄（2.4） |
| A-m3 | 剪貼簿與對話框在 `OfflineOp` 結束之後才做（2.4） |
| A-m4 | 「排除這台」只在自己那一組（2.6 第 8 項；nodes.dart:1334-1338） |
| A-m5 / B-m4 | `RemoveTicks` 以完整 owner 為鍵（2.5） |
| A-m6 | mpend 待辦要求同一個 netid 沒有 mnet（2.7） |
| A-m7 | 7.10 與 mnet「加入網路」用入口節點（2.6 第 13 項） |
| A-m8 / B-m2 / B-m12 | `SecureScreen` 加可選的 `fallback`，預設行為不變；確認碼頁的 fallback 見 D6 |
| A-m9 / B-m3 | `copyCode`（sensitive 旗標）與 `clearClip`；8.5 只能貼上；說明鍵盤 app 的剪貼簿紀錄清不到（2.1） |
| A-m10 | `memberJoin` 用 `ConsoleReply` 既有的 `sendUpdate` / `pollLink`（2.3） |
| A-m11 / B-m6 | `OfflineOp` 自己持有佔用到 `work` 結束，不寫 420 s（2.4） |
| A-m12 | `nodeRecords` 的搬移寫進 8.5（2.6 第 14 項） |
| A-m13 | 顯示 QR 時調亮螢幕：不做。R-8 沒有量出亮度是問題。記在 #329 當作延伸想法 |
| B-m1 | 7.7 照實寫，不說「已作廢」（D7） |
| B-m5 | `work` 不回傳紀錄明文；8.5 的 `z` 也要歸零（2.4） |
| B-m7 | 確認碼頁遇到 busy / failed 時重建，按鈕回到可按（2.6 第 5 項） |
| B-m9 | field 版不顯示「加入隊長的網路」，T-S5 鎖住（2.7） |
| B-m10 | 紀錄行不寫隊員名稱與網路名稱；T-U6 加假名稱（§5） |
| B-m11 | 真機重測認領 QR（§7） |

### 第二輪（v2 → v3；review-pr5-plan-C.md、-D.md）

C：APPROVE-WITH-CHANGES，0 BLOCKER / 2 MAJOR / 15 MINOR。D：APPROVE-WITH-CHANGES，0 / 3 / 10。

第一輪 MAJOR 的關閉情形：
- A-M3 / B-M2：兩位都確認已關。
- A-M1 / B-M1：入口修好了，但修法本身開出了 D-M1。
- A-M2：只關了一半，見 C-M1 / D-M3。

**MAJOR**

| 項目 | 問題 | 本人查證 | v3 處理 |
|---|---|---|---|
| D-M1 | v2 拿掉 `update_hint`，等於拿掉凍結基準的共用規則；節點落後時新 UI 沒有任何提示（fail-open），而且沒列成偏離 | remove-member :27、:184-185、:235-236；nodes.dart:1158-1177；owner.rs:960-965 | 2.3：在 `NodeLink` 讀取的那一輪算 hint（`SessionProber` 打開 net / mnet 紀錄）；2.7 加提示行；D8。**這是我在 v2 犯的錯** |
| D-M2 | 8.1 / 8.2 / 8.3 沒有搬指紋與「另有同名的一組」；惡意隊員用兩組身分時，隊長只移掉一組 | remove-member :139、:531；nodes.dart:1324-1338、:1397 | 2.6 第 1、8、9 項 |
| C-M1 / D-M3 | 8.1 沒有通往 8.4 的路；離開 8.4 之後更新包就不能重新產生 | nodes.dart:1450-1454、:1751；設計 :192 | 2.9：設定頁「隊伍與邀請」→「產生更新包」，另在 8.1 底部 |
| C-M2 | 7.8 只有一個入口（首頁只在沒有紀錄時才給）；Rust 說「需要新的邀請」的情形都走不到 | home_logic.dart:95；member.rs:258；owner.rs:574-581；nodes.dart:1759 | 2.9：「收隊長的邀請」常駐 |

C-M1、C-M2、D-M3 與 C-m4 是同一類（常駐按鈕沒搬）。所以 v3 把舊控制台的成員按鈕**全部**列成對照表（2.9），每一顆都要有新入口，並用 T-P5-E 鎖住。

**MINOR**

| 項目 | 處理 |
|---|---|
| C-m1 | §6 第 8 步的提示行測試現在有意義了（D-M1） |
| C-m2 | D1 改正：同意碼在第一次移除之前都和向量差不多大，餘量約 50 字元；實際長度實作時量 |
| C-m3 | 3.2 的 `CodeInput` 契約改成「掃描 ≤ 4096、貼上 ≤ 300 000」 |
| C-m4 | 7.4 常駐（2.9），一張邀請可以收多份申請 |
| C-m10 | 8.5「送到節點」走 info → infoNetId → `sendUpdateFor`（2.7） |
| C-m13 | `runNetOp` 的金鑰失敗接到 X26（2.4） |
| C 的其他 MINOR | 7.10 原因句、7.8 選節點、同名網路標示、8.4 對回節點：2.7.1。「再顯示申請」：2.9。`RemoveTicks` 拿掉版本號。引用改正（mupdate.rs:87、程式碼註解改成 v26 / v27）。解析度只在 S20 量過：§7 |
| D-m1 | §7 加 R-8 補量 v31 / v35 / v40 |
| D-m2 | `fallback` 只在確定設不了時顯示；Wi-Fi 頁加「設不了」的測試 |
| D-m3 | 不自動複製；8.4 用同一組剪貼簿處理；貼上後用 `clearClip` |
| D-m4 | `OfflineOp` 只記 `runtimeType` |
| D-m5 | `OfflinePlatform` 有 ecdh；先 `_ownCopy` 再歸零 |
| D-m6 | `startBundle` 也在佔用裡重讀 |
| D-m7 | T-S5 涵蓋所有新入口；「把新密碼送給節點」只有 Dart 一層 gate，所以一定要測 |
| D-m8 | 送出結果不明時顯示 `_sendUnclear`（nodes.dart:55） |
| D-m9 | 版本來自 `Encoder.encode`；Dart 檢查 size 與 bits 的長度 |
| D-m10 | 貼上上限 300 000 字元 |
| D 的範圍外觀察（6 位數確認碼沒有 commitment） | 是 219 §5.5 的前提，不屬於本 PR，記在 #329 |

### 第三輪（v3 → v4；review-pr5-plan-E.md、-F.md）

E：APPROVE-WITH-CHANGES，0 BLOCKER / 2 MAJOR / 12 MINOR。F：APPROVE-WITH-CHANGES，0 / 1 / 8。

前兩輪的 MAJOR：
- 兩位都確認：除了 D-M1 之外都已關。
- F 核過 2.9 的對照表，每一顆成員按鈕都有新入口；E 補了一項漏掉的（「忘記加入中的節點」對話框裡的「排除這台」）。

**MAJOR**

| 項目 | 問題 | 本人查證 | v4 處理 |
|---|---|---|---|
| E-M1 | 換密碼提示與 8.5 入口放在「網路」分組，但已入網的節點不畫這個分組，所以提示永遠看不到（D-M1 只修好了「算」，沒修好「顯示」） | node_page.dart:76-104；bridge rekey.rs:466-486（k10 要等於紀錄的網路代號） | 2.7：提示改成 `StatusHero` 下方獨立的一張卡；8.5 入口移到「更多」與「隊伍與邀請」 |
| E-M2 | 只有 mnet 的隊員手機，節點頁沒有「加入網路」；`NetFormPage` 只給舊控制台 | node_page.dart:81；net_pages.dart:352-360；nodes.dart:1065-1094 | 2.7：條件加上 mnet；`NetFormPage` 照 `joinChoice` 分流；「隊伍與邀請」加一列 |
| F-M1 | 8.4「自己的節點」用當下讀得到的節點對清單，讀不到的（例如山頂中繼）被悄悄略過；被移除的人經由它繼續連網，隊長看不出來 | v3 的 2.7.1「對不上的節點不列」 | 2.6 第 10 項：清單從網路紀錄來，每台都列出狀態；頂端固定顯示還沒換到的台數 |

**MINOR**

| 項目 | 處理 |
|---|---|
| E / F：prober 的 hint 失敗會拖垮讀取 | 先交讀取結果再算提示；try/catch 加 2 s 逾時；用獨立的 `hints` 表，`Outcome.extra` 不變（2.3） |
| F-m2 | 只在 devTrust、而且 `NetIndex` 有這個網路時才打開紀錄 |
| E：收申請的網路 | 先選網路（2.9 改正） |
| E：選網路的篩選 | 照舊 applied 篩選（2.7.1） |
| E：8.4 隊員那幾列 | 照搬名字、指紋、節點與 `note` |
| E：漏掉的「排除這台」 | 2.9 加一列，對應 8.2 |
| E：8.5 送到哪一台 | 2.6 第 14 項 |
| E：只在入口節點加入比舊程式嚴 | D10 |
| E：`AppLink` 沒有 devTrust | 2.5 |
| E：「把新密碼送給節點」改成只在開發版 | D9 |
| E：大的更新包放進剪貼簿沒試過 | §7 ⚠️ |
| E：放棄申請的確認句 | 2.6 第 12 項 |
| F-m3 | `OfflineOp` 進行中擋返回 |
| F-m4 | `OfflineOp` 上限 60 s，之後的寫入由 `RecordWriter` 拒絕 |
| F-m5 | 同名用完整 owner 比 |
| F-m6 | T-P5-L 攔下 log 搜尋 |
| F-m7 | 不再說是 fail-secure；這種手機上剪貼簿警告一直顯示 |
| F-m8 | `RemoveTicks.removedThisRun` |

### 第四輪（v4 → v5；review-pr5-plan-G.md、-H.md）

G：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 10 MINOR。H：APPROVE-WITH-CHANGES，0 / 2 / 8。

- 兩位都核過 2.9 的對照表，沒有漏項。
- 前三輪的 MAJOR 都已關，只有 D-M1 / E-M1 的「算提示」那一半沒關，就是本輪的 G-M1 / H-M1。

**MAJOR**

| 項目 | 問題 | 本人查證 | v5 處理 |
|---|---|---|---|
| G-M1 / H-M1 | v4「先 `done` 再算提示」：`done` 之後 `probe` 立刻 dispose session，`updateHint` 打在已 dispose 的物件上，例外被吞掉，提示永遠不出現；假 session 不模擬 dispose，所以測試抓不到 | prober.dart:69-71、:180-205 | 2.3：在 `done` 之前、session 還在時算，上限 2 s；session 的生命週期不變；白箱負對照（假 session 在 dispose 後丟例外）。**這是我在 v4 的設計錯誤** |
| H-M2 | 8.4「已送出」：(a) `[REQ_FAIL]` 也是 answer 種類，會被當成成功；(b) 沒綁紀錄版本，第二次移除後全部顯示「已送出」 | owner.rs:1090；rekey.rs:430-458 | 2.6 第 10 項：`[UPDATED]` 才算成功；以 `(netId, 版本)` 為鍵；兩個負對照 |

**MINOR**

| 項目 | 處理 |
|---|---|
| G-m1 / H-m3 | 「網路分組」的舊文字全部改掉（§0、2.6 第 14 項、2.9 兩列） |
| G-m2 / H-m2 | `hints` 的契約：觸發 `changed`、失敗保留舊值、忘記時刪、送完提前重讀（2.3） |
| G-m3 | D10 改正：隊員加入只在入口節點（join2flow.rs:78 `NotThisNode`）；節點頁的條件跟著改 |
| G-m4 / H-m4 | 8.4 用 `deviceId` 全碼找紀錄，登入後用 `nodeDacHash()` 驗 |
| G-m5 | `NetIndex` 記下打不開的 mnet |
| G-m6 | `devTrust` 讀到之前是 false |
| G-m7 / H-m1 | 60 s 上限改用收回（`Lease.revoke()`，一行的公開包裝），之後重讀紀錄再說結果 |
| G-m8 | 3.1 擁有權表加四列 |
| G-m9 | 8.3 只讀看得到的節點，有進度，可略過（照舊 :1363） |
| G-m10 | joinreq 的 mpend 在佔用裡讀 |
| H-m5 | 「被移除的人仍連得上」只在這次做過移除時才顯示 |
| H-m6 | `copyCode` 接住 `TransactionTooLargeException` |
| H-m7 | 提示的記錄只寫 `runtimeType`；`openNet` 失敗不走 `keyCheck` |
| H-m8 | 不快取明文（理由見 2.3） |

### 第五輪（v5 → v6；review-pr5-plan-I.md、-J.md）

I：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 9 MINOR。J：APPROVE-WITH-CHANGES，0 / 1 / 9。

- 兩位都確認 G-M1 / H-M1 在設計上已關，殘留的空檔由 v6 的 `cleaning` 旗標處理。
- 2.9 對照表逐顆核過，沒有漏項。

**MAJOR**

| 項目 | 問題 | 本人查證 | v6 處理 |
|---|---|---|---|
| I-M1 | v5 的 8.3 只讀「看得到的」節點，削弱凍結基準 §2.4 的背書（`NodeNewer`）。這是因為我照 G-m9 改，沒有追 `_nodes` 是從哪來的 | nodes.dart:171-174（`_nodes = listNodes(...)`，是所有紀錄） | 8.3 改回每台都嘗試讀，可略過；上限改正為 60 s |
| J-M1 | 8.4 把 `Applying` 當成「已送出」；它在 `k9` 比對之前就判定，不代表節點已經換好 | updflow.rs:316；bridge rekey.rs:451-453 | **拿掉 8.4 整個「已送出 / 還有 N 台」的機制**（v4 / v5 是我自己加的，H-M2 和 J-M1 都出在它身上）。只顯示 Rust 原句，有沒有換好看基準的提示卡 |

**MINOR**

| 項目 | 處理 |
|---|---|
| I-m1 | 版本號的來源問題，隨「已送出」機制一起消失 |
| I-m2 / J-m1 | `cleaning` 旗標：清理開始之後就不呼叫 `updateHint` |
| J-m2 | 只為開著的節點頁算提示 |
| I-m3 | 離開節點頁時清掉提示；第一筆打得開的紀錄就用 |
| I-m4 | net + mnet 都有時，只有入口節點才問隊員那一支 |
| I-m5 | 第 6 列只有在入口節點本身可以加入時才給隊員的「加入網路」 |
| I-m6 / J-m3 | 8.4 的節點清單用 `removeOwnNodes` 合併 `netPeople`；處理沒有編號的舊節點與加入中的節點 |
| I-m7 | `memberJoin` 的 mnet 在佔用裡讀 |
| I-m8 / J-m4 | 收回之後，邀請與同意的碼已經丟了，改說「結果不明」；移除成功就直接進 8.4 |
| I-m9 | `RemoveTicks` 只有一個擁有者；入口節點用完整 device_id；D1 的餘量受網路名稱影響 |
| J-m5 | 隨「已送出」機制一起消失 |
| J-m6 | 8.5 和隊長端用同一種做法 |
| J-m7 | `AppLink` 接收 main.dart 已經讀到的 devTrust |
| J-m8 | Kotlin 新檔案的記錄用原始碼檢查鎖住 |
| J-m9 | 被入侵的節點能選的路徑已有格式驗證，而且只影響顯示（§5） |

### 第六輪（v6 → v7；review-pr5-plan-K.md、-L.md）

K：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 11 MINOR。L：APPROVE-WITH-CHANGES，0 / 1 / 6。

- 兩位都核過 2.9 的對照表；K 找到一顆不在舊控制台裡的按鈕（3.6 的「我是隊員」），已補進表裡。
- 前幾輪的 MAJOR：I-M1 的修法本身被 K-M1 重新打開，其他都已關。

**MAJOR**

| 項目 | 問題 | 本人查證 | v7 處理 |
|---|---|---|---|
| K-M1 | v6 新加的「略過這台」做不到：`once` 要等登入結束才看 `gone`；讀不到的節點等滿 60 s，下一台會拿到 busy | op_session.dart:104-129；core.dart:731-736；node_link.dart:183 | 拿掉「略過」，照舊 `_remove` 一台一台讀；加「第 1 台逾時、第 2 台仍被讀」的測試 |
| L-M1 | 8.4 / 8.5 叫使用者看「提示卡消失」當成換好；但讀取錯誤、逾時、`Applying` 時提示一樣是空的（fail-open）；基準有明確的正向信號 | bridge rekey.rs:466-486；updflow.rs:247-258、:316 | 改成「再按一次送出，看到『已是新密碼』才算」；文字斷言與負對照 |

這兩個 MAJOR 都出在我前一輪**新加**的東西上（「略過」、「看提示卡消失」）。v4–v6 的「已送出」也是同一類。v7 的原則：要修就回到舊程式或凍結基準的做法，不再發明新的控制或判斷。

**MINOR**

| 項目 | 處理 |
|---|---|
| K-m1 | 入口節點用後四碼比對（`mnet_summary` 只給後四碼），`NotThisNode` 照樣 fail-closed |
| K-m2 | 進到 answer 那一步就取消 20 s 的答覆計時器 |
| K-m3 | 同 L-M1 |
| K-m4 | 拿掉沒有作用的「送出後提前讀取」 |
| K-m5 / L-m1 | `onHint` 寫入前確認頁面還開著 |
| K-m6 | 3.6 的按鈕改開 7.8 並加 gate；D9 的理由改正 |
| K-m7 | 「把新密碼送給節點」拆成兩次 `once`，確認框放在佔用之外 |
| K-m8 | 8.4 的節點清單改用 `netPeople` 加上登入後比對 `dacHash` |
| K-m9 | 收回後的待辦句子依操作種類選 |
| K-m10 | `netKnown` 回呼注入，`NodeLink` 不碰 `NetIndex` |
| K-m11 | mnet 分流放在 `noneOpens` 檢查之前 |
| L-m2 | 重讀等 `work` 結束之後才做 |
| L-m3 | 送不了的那一列寫出下一步 |
| L-m4 | 2.4 的例外寫法前後一致 |
| L-m5 | `PopScope` 何時解除 |
| L-m6 | 提示路徑的例外在本地接住，T-P5-L 涵蓋 |

### 第七輪（v7 → v8；review-pr5-plan-M.md、-N.md）

M：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 9 MINOR。N：APPROVE-WITH-CHANGES，0 / 1 / 9。兩位的 MAJOR 是同一個。

**MAJOR**

| 項目 | 問題 | 本人查證 | v8 處理 |
|---|---|---|---|
| M-M1 / N-M1 | L-M1 只改了 8.4。8.5 與 §5 還寫「看提示卡消失」，8.4 也留著一行矛盾的舊句子。**這是我改文字沒改完** | 計畫 v7 :362、:399、:596 | 全文搜尋「消失」與「只看」，三處都改；8.4 / 8.5 共用一個文字常數 `kRekeyDoneRule`，8.5 也加上文字測試與負對照 |

為了避免再發生這種事：從這一版起，每改一個規則，就用 grep 全文搜尋同一個概念的所有出現處，再一起改。

**MINOR**

| 項目 | 處理 |
|---|---|
| M-m1 / M-m8 | 2.8.1：設定頁只有「隊伍與邀請」一列；裡面每一列都一直在 |
| M-m2 | 隊員加入確定失敗後，給 Rust 的原句與「收隊長的邀請」 |
| M-m3 | 3.6 的「加入網路」照 D10 |
| M-m4 | 7.5 的標題照舊（nodes.dart:839） |
| M-m5 | `memberJoin` 與 `sendUpdateFor` 之間重讀 mnet |
| M-m6 | 固定文字加上 `Applying` / `Unfinished` 時要等的說明 |
| M-m7 | 3.3 加四列 |
| M-m9 | 7.8 有「不用這份邀請」；`InviteHolds` 列進 3.1 |
| N-m1 | 收回後依操作種類判斷結果，不只看 generation |
| N-m2 | 8.1 固定一行提醒；3.3 列為已知限制 |
| N-m3 | 「已換成新密碼」也算正向信號 |
| N-m4 | 結果樣式中性，只有兩句正向原句才加勾 |
| N-m5 | 操作名稱一律常數 |
| N-m6 | Kotlin 回的錯誤訊息固定 |
| N-m7 | Android 12 用字面字串，效果 ⚠️ 未查證 |
| N-m8 | `clearClip` 只清自己複製的那一段 |
| N-m9 | `Applying` → `AlreadyCurrent` 的行為測試 |

### 第八輪（v8 → v9；review-pr5-plan-O.md、-P.md）

O：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 11 MINOR。P：APPROVE-WITH-CHANGES，0 / 2 / 8。O 的 MAJOR 和 P 的第二個是同一個。

**MAJOR**

| 項目 | 問題 | 本人查證 | v9 處理 |
|---|---|---|---|
| O-M1 / P-M2 | v8（N-m8）讓 `clearClip` 只清自己複製的；貼上也用它，所以貼上後永遠清不掉，比舊 `_takeClipboard` 退步。**這是我在 v8 弄出的矛盾** | nodes.dart:728-732；設計 :774；remove-member :163 | 拆成 `clearOwnClip`（按鈕、離開提醒）與 `clearClip`（貼上後一律清）；兩條都有負對照 |
| P-M1 | 隊員端的「已是新密碼」只代表和手機的版本一樣；貼了舊的更新包時，照樣會回這句 | mupdate.rs:298-299；updflow.rs:256-258；rekey.rs:400 | 8.5 用自己的文字 `kMemberRekeyRule`，請隊員和隊長核對版本；只有這一頁剛匯入過新版本才打勾 |

**MINOR**

| 項目 | 處理 |
|---|---|
| O-m1 | 8.3 照舊讀 `removeOwnNodes(對象)` 與手機紀錄的交集 |
| O-m2 | 入口條件的舊文字刪掉 |
| O-m3 | 「送出後提前讀取」的殘留刪掉 |
| O-m4 | 2.9 的隊員加入直接用入口節點；引用改成 join2flow.rs:78、:383 |
| O-m5 | 7.8 不依狀態篩選節點 |
| O-m6 | 入口節點上隊員那一支的「加入網路」不看 nodeState |
| O-m7 | `revoke(todo:)` 帶整句；PR 1 的增量共兩處 |
| O-m8 | `OfflineReply` 加 `unknown`；產生更新包、邀請、同意的收回後句子；`removed()` |
| O-m9 | `failed` 顯示 Rust 原句，只有紀錄限制成 `runtimeType` |
| O-m10 | 3.1 的重複列刪掉 |
| O-m11 | 「被移除的人」只在做過移除時出現；「狀態頁就是節點頁」 |
| P-m1 | 送出前比對 `infoNetId` 與後四碼 |
| P-m2 | `info_net_id` 只產生十六進位，不會指到別的路徑（記錄，不改） |
| P-m3 | 「更多」送出的結果也用 `kRekeyDoneRule` |
| P-m4 | 形似字可以繞過同名警告，記為已知限制，靠指紋分辨 |
| P-m5 | 併入 O-m8 |
| P-m6 | Kotlin 只記 SHA-256；讀不到剪貼簿就算清除失敗 |
| P-m7 | QR 每格是整數個像素，並加讀回比對的 widget 測試 |
| P-m8 | 實體被奪的殘留風險寫進 §5 |

### 第九輪（v9 → v10；review-pr5-plan-Q.md、-R.md）

Q：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 9 MINOR。R：APPROVE-WITH-CHANGES，0 / 1 / 8。

**MAJOR**

| 項目 | 問題 | v10 處理 |
|---|---|---|
| Q-M1 | O-m5（7.8 不依狀態篩選）與 O-m6（隊員那一支不看 nodeState）只改了一處，:404、:448、:473、:480 還留著舊規則 | 整份重寫：7.8 的規則只寫在 2.8 第 11 項；隊員的加入只寫在 R16 |
| R-M1 | P-M1 的隊員文字只套在 8.5；隊員從節點頁「更多」或提示卡送出時，只看到 Rust 的「已是新密碼」 | R14：四個送出結果都只能由 `RekeyResult` 顯示，並用原始碼檢查鎖住 |

**根本原因與處理**：第七、九輪的 MAJOR 都是「規則改了一處、別處沒改」。v10 整份重寫，每條規則只寫一次（R1–R16），其他地方只引用編號。

同時拿掉兩個我自己加的機制：
- `clearOwnClip`：它要讀剪貼簿才能比對；Q-m6 指出 Android 12 以上每次都會跳系統提示；它也是 O-M1 / P-M2 的來源。
- 從 Rust 句子解析「第 N 版」（R-m1 / Q-m4）。

**MINOR**

| 項目 | 處理 |
|---|---|
| Q-m1 / R-m2 | R12：待辦是一整句，首頁待辦卡直接顯示；`revoke({todo})` |
| Q-m2 / Q-m3 / R-m4 | R15：「隊伍與邀請」的每一列都一直在；3.3 改寫 |
| Q-m4 / R-m1 | 不再解析版本號，`kMemberRekeyRule` 不帶數字 |
| Q-m5 | R7：等提示時讀取被取消，立刻 `done` |
| Q-m6 / R-m8 | 拿掉 `clearOwnClip` |
| Q-m7 | 2.10：隊員從「更多」送出時，在同一個 `once` 裡送，沒有確認框 |
| Q-m8 | R16：登入後用 `nodeDacHash()` 驗證入口節點 |
| Q-m9 | 2.6：`devTrust` 在 `AppLink` 建構時給定 |
| R-m3 | R12 的表格是唯一的判斷規則；v9 的殘留句子已刪 |
| R-m5 | R2：原點對齊、每個像素都比對、格寬 0 的處理 |
| R-m6 | R3：QR 與確認碼各自包一層 |
| R-m7 | R12：匯入同意被收回、mpend 還在時，在新的佔用裡刪掉 |

### 第十輪（v10 → v11；review-pr5-plan-S.md、-T.md）

S：APPROVE-WITH-CHANGES，0 BLOCKER / **0 MAJOR** / 13 MINOR。附錄 A 的 MAJOR 逐條對過原始碼，全部已關；§2.12 每一顆舊按鈕都有新入口。
T：APPROVE-WITH-CHANGES，0 / 2 / 8。

**MAJOR**

| 項目 | 問題 | 本人查證 | v11 處理 |
|---|---|---|---|
| T-M1 | 隊員端的勾只代表「這一頁剛匯入過」；惡意隊員可以轉一份舊的、隊長真簽章、對方沒用過的更新包，匯入會回 `Advance`、送出回 `Updated`，節點卻停在被移除的人知道的版本 | mupdate.rs:263-268；rekey.rs:400 | 隊員端**一律不打勾**（fail-closed）；8.5 原樣顯示 Rust 的「更新到第 N 版」，請隊員唸給隊長核對 |
| T-M2 | R14 漏了 `NetRun` 加入之後的自動送出；它只看 `[UPDATED] ` 前綴，把「正在套用」當成功 | net_run.dart:299-311；rekey.rs:451-453 | R14 列五處；新的 `rekeyEnd` 分類用整句錨定比對，兩邊釘住字面；`NetRun` 改用它（D12） |

**MINOR**：S-m1–m13、T-m1–m8 都已寫進對應的規則，內文標了來源編號。

### 第十一輪（v11 → v12；review-pr5-plan-U.md、-V.md）

U：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 12 MINOR。V：APPROVE-WITH-CHANGES，0 / 1 / 9。兩位都核過：附錄 A 的 MAJOR 都已關，§2.12 沒有漏項。

**MAJOR**

| 項目 | 問題 | 本人查證 | v12 處理 |
|---|---|---|---|
| U-M1 | 換密碼提示卡上的「把新密碼送給節點」沒有隊長的確認框；這張卡正好在移除之後出現，一按，還沒拿到更新包的隊員就斷線 | nodes.dart:1138-1143、:1567-1572（預設 `confirm = true`） | 新增 R17：所有送出只有 `sendNewKey` 一條流程，由使用者按的預設要確認；`sendUpdateFor` 只能出現在 R17 的兩處，用原始碼檢查鎖住 |
| V-M1 | 計畫要用網路版本號，但凍結的 Rust 入口沒有一個交給 Dart；隊長看不到現在是第幾版，T-M1 的核對做不到；R12 與 D11 的判斷也實作不出來 | owner.rs:97-104；member.rs:303-309 | `NetView` / `MnetView` 各加一個只讀的 `version`（D11 改成這一條）；8.1、8.4 顯示「目前是第 N 版」；R12 改成看名單與重跑 prepare；mpend 待辦照上層設計，拿掉 v11 加的條件 |

U-M1 是同一類錯誤（規則只寫在一條路上）的第五次：R-M1、Q-M1、T-M2、U-M1。v12 用 R17 把「送新密碼」收成一個函式，加上原始碼檢查。之後再多一個入口，也只能呼叫它。

**MINOR**：U-m1–m12、V-m1–m9 都已寫進對應的規則，內文標了來源編號。

### 第十二輪（v12 → v13；review-pr5-plan-W.md、-X.md）

W：APPROVE-WITH-CHANGES，0 BLOCKER / **0 MAJOR** / 12 MINOR。R17 涵蓋所有送出的地方（舊控制台以外，`sendUpdateFor` 只在 net_run.dart:301 被呼叫）。
X：APPROVE-WITH-CHANGES，0 / 1 / 8。核心問題「被移除的人能不能在沒人發現的情況下繼續連得上」：隊長那一端找不到漏洞，隊員那一端只剩 X-M1。

**MAJOR**

| 項目 | 問題 | 本人查證 | v13 處理 |
|---|---|---|---|
| X-M1 | `MnetView.version` 加了卻沒有一頁顯示；隊員之後從提示卡或「更多」送出時，畫面上沒有版本號，無法和隊長核對 | 計畫 v12 全文只有 :41、:534 提到；rekey.rs:400、:421 | `RekeyResult(member: true)` 與 8.5 都固定顯示「這支手機是第 N 版」；`kMemberRekeyRule` 改成請隊員唸這一行；Rust 測試把三個版本號釘成同一個計數 |

**MINOR 中會影響實作結果的**

| 項目 | 處理 |
|---|---|
| W-m6 | `rekeyEnd` 的 `last4` 用 Rust 那一份（保留原本大小寫）。Dart 的 `last4()` 會轉成大寫（home_logic.dart:8），照 v12 寫，大部分節點會永遠比對不到「已換好」 |
| W-m1 | 收回後判斷「匯入同意」時，重跑 prepare 要帶 `pendPlain: null`。帶著 mpend 時，prepare 只會回 `Ready`（approve.rs:468-487） |
| W-m2 / W-m3 / W-m8 / W-m12 | R17 加 `expectNet`；`member` 旗標的來源；照舊用 `retry: true`；照舊的失敗句 |
| W-m4 / W-m5 / X-m2 / X-m3 | `NetRun` 的寫法統一；同一份允許清單，並鎖住 `confirm: false`；隊員那一支要帶 `member: true` |

其餘 MINOR 都寫進了對應的規則，內文標了來源編號。

### 第十三輪（v13 → v14；review-pr5-plan-Y.md、-Z.md）

Y：APPROVE-WITH-CHANGES，0 BLOCKER / 2 MAJOR / 9 MINOR。Z：APPROVE-WITH-CHANGES，0 / 1 / 7。兩位都核過：附錄 A 的 MAJOR 在正文都已關，§2.12 沒有漏項；隊長端「被移除的人仍連得上」找不到漏洞。

**MAJOR**

| 項目 | 問題 | 本人查證 | v14 處理 |
|---|---|---|---|
| Y-M1 | 後四碼的大小寫陷阱只修了 `rekeyEnd` 一處；R16 找入口節點、8.4 找候選節點時，Rust 的後四碼保留小寫，Dart 的 `last4()` 轉成大寫，含字母的大多比不到 | member.rs:322；rekey.rs:79；home_logic.dart:8 | 新增 R18：所有比對都用 `sameLast4`，並用原始碼檢查禁止 `==` |
| Y-M2 | 只有 mnet、勾選的節點又不是入口節點時，`NetFormPage` 會掉到 :362 的 `_makes = true`，變成「建立網路」，隊伍會分裂 | net_pages.dart:362 | R16：依勾選的那一台分三種情形；手機有 mnet 或 mpend 時絕不建網；附負對照 |
| Z-M1 | 隊員端不管送出結果如何，都顯示版本號與「唸給隊長聽」；節點沒換好時，核對照樣會通過 | 計畫 v13 :429 | R14：隊員端分成兩件事分開顯示，「已換成這支手機的版本」只在 `current` 時出現 |

Y-M1 是「規則只改一處」的第六次，所以這次也用一條單一規則（R18）加上原始碼檢查來防，而不是逐處修補。

**MINOR**：Y-m1–m9、Z-m1–m7 都寫進了對應的規則，內文標了來源編號。

### 第十四輪（v14 → v15；review-pr5-plan-AA.md、-AB.md）

AA：APPROVE-WITH-CHANGES，0 BLOCKER / 1 MAJOR / 7 MINOR。AB：APPROVE-WITH-CHANGES，0 / 1 / 7。

- AB 核過隊長端：「換好」只認 Rust 從列舉產生的整句，節點偽造不了。R14 把隊員端拆成兩件事是對的。
- 兩位都核過 §2.12，沒有漏項。

**MAJOR**

| 項目 | 問題 | 本人查證 | v15 處理 |
|---|---|---|---|
| AA-M1 | v14 修 Y-M2 時修過頭：三種情形表在手機也有 net 時照樣套用，擋住隊長把新節點加進自己的網路，`joinChoice` 也不見了 | net_index.dart:78；home_page.dart:186-191；nodes.dart:1777-1786 | `NetFormPage` 加明確的 `mode`；兩者都有時照舊 `joinChoice`；三種情形表只用在 `member` 模式；`member` 模式固定用入口節點，不看勾選（同時解掉 AA-m1、AB-m2） |
| AB-M1 | 「目前是第 N 版」沒規定什麼時候算新的；`NetIndex` 重算期間保留舊值，8.4 會停在 N−1，舊的 N−1 更新包就能通過唸號核對 | net_index.dart:131-145、:189 | R19：版本號一律直接讀紀錄；從 8.3 進 8.4 用剛寫入的那一筆；讀取中不顯示數字；附負對照 |

**MINOR**：AA-m1–m7、AB-m1–m7 都已寫進對應的規則，內文標了來源編號。其中 AA-m7 的引用改正為 rekey.rs:421。

### 第十五輪（v15 → v16；review-pr5-plan-AC.md、-AD.md）

AC：APPROVE-WITH-CHANGES，0 BLOCKER / 2 MAJOR / 8 MINOR。AD：APPROVE-WITH-CHANGES，0 / 1 / 8。AD 的 MAJOR 和 AC-M1 是同一個。

**MAJOR**

| 項目 | 問題 | v16 處理 |
|---|---|---|
| AC-M1 / AD-M1 | R19 只在頁面打開時、這一頁自己寫入後讀版本號。在 8.3 移除完返回 8.1，8.1 還是 N−1；隊員手機也是 N−1 時，唸號核對會通過 | R19：頁面重新顯示時、`NetIndex` 通知時也重讀，數值一律直接讀紀錄；附負對照 |
| AC-M2 | v15（照 AB-m4）加的「打開 7.9 / 7.10 時對帳」做不到：app 被殺後同意碼已經不在；硬做只能「有 mnet 就刪 mpend」，會刪掉合法的新申請 | 拿掉，照基準處理（member-join :65、:78）。**這又是我為了回應 MINOR 新加的機制** |

**MINOR**：AC-m1–m8、AD-m2、AD-m3、AD-m6 已寫進對應的規則；AD-m1、AD-m4、AD-m5、AD-m8 由 v16 的修改涵蓋；AD-m7（隊員從提示卡送出沒有確認框）是舊程式的行為，不改。

### 凍結（2026-11-17）

使用者決定凍結 v16，不再開第十六輪。決定時的事實：
- 十五輪、30 位審查者，各輪 MAJOR 數：5、5、3、2、2、2、1、2、2、2、2、1、3、2、2。
- 最近四輪的安全審查者都說：隊長端「被移除的人仍連得上」找不到漏洞。隊員端最後一個洞（版本號會舊掉）在 v16 修好了。
- 第十五輪的 MAJOR 修法（R19 重讀時機、拿掉對帳），沒有再經過審查者看過。

接下來由這些防線抓剩下的問題：
- 每一條規則的負對照測試；
- 實作後的兩位程式碼審查；
- `/security-review`。

## 附錄 B. 實作時和計畫不同的地方（2026-11-17）

凍結後實作時的偏差，每一項都附理由。行為上的偏差另有測試。

| 編號 | 計畫 | 實作 | 理由 |
|---|---|---|---|
| B1 | R12：待辦存整句 | 待辦清單只存標題，句子放在 `LeaseRegistry.unsavedText`（標題 → 句子） | 舊的節點待辦沿用原本的標題清單，不必改它的型別 |
| B2 | 2.3：`info` | `OwnerConsole.info()` 的 `value` 是 info 的位元組 | 8.3、R17、8.5 都要拿位元組給 `infoNetId` / `removeCheck` |
| B3 | R16 / AA-m2：`AppLink.devTrust` | `AppLink.devTrust` 是可設定的欄位，只在 `main` 設一次；`NetFormPage` 原本的 `devTrust` 參數拿掉 | 入口不必再傳，測試可以直接設 |
| B4（D13） | 7.5 / 7.10：`SasConfirmView` 原樣搬過來 | 用 `SasCheck`：同樣的 Key、`sasRule`、只能按一次，另包 `SecureScreen`（R3） | `SasConfirmView` 是整個 `Scaffold`、顏色寫死，放不進 `BatPage`。7.9 照計畫用 `SasShowView` 包 `SecureScreen` |
| B5（D14） | R13：同名網路加「建立日期與代號後四碼」 | 名稱 + mesh id，同名時加代號後四碼 | `NetView` 沒有建立日期（owner.rs `NetView`），只讀欄位以外不改 Rust |
| B6 | 2.8：8.5 / 7.9 / 7.5 的按鈕樣式未寫 | 7.5「數字不一樣」改次要按鈕、7.9「放棄申請」改文字按鈕（仍先問） | T-C3：一頁只有一個主要按鈕 |
| B7 | R16：兩者都有時「照舊 `joinChoice` 問」（對話框） | 4.1 頁內兩列選項（同樣兩句）；舊對話框沒有搬 | 入口都不給模式時由 4.1 自己問，入口不必各自開對話框；`joinChoice` 函式照樣搬出 nodes.dart |
| B8 | R14：所有送出結果都經 `RekeyResult` | `SendKeyButton`：在讀到紀錄之前就停下（沒有網路、沒有紀錄、沒連上）時顯示原句，不經 `RekeyResult` | 這些情形沒有送出任何東西，`RekeyResult` 的固定文字不適用 |
| B9 | 8.3：「再顯示一次名字、指紋與同名提示」 | 同名提示由 8.2 算好帶進 8.3 | 8.3 不再讀一次 `netPeople` |
| B10 | 2.10：提示卡的 gate | 卡片本身也只在 devTrust 版本顯示（不只按鈕） | 提示只在 devTrust 版本收集（`HintSource.wanted`），卡片跟著 gate，T-S5 一起測 |
| B11 | — | 新增 `TeamDeps`：team 頁面讀寫的唯一注入點 | 讓 widget 測試能換掉平台與 Rust 呼叫；不改行為 |
| B12 | 2.7 第 1 項：同名且指紋也相同時加「請用加入時間分辨」 | 改成「指紋也相同：兩組都移除，再重新邀請要留的那位」 | app 沒有任何地方顯示加入時間，原句叫隊長做做不到的事（審查 A m8）；改成畫面上做得到的動作，不加新機制 |
| B13 | R12：判斷時「拿新的佔用」 | 判斷用一個名為「確認結果」的 `OfflineOp`（`judgeAfterRevoke`），等被收回的 `work` 真的結束才開始 | 新佔用要有名字（會進紀錄與待辦，R10 要常數）；用同一套 `OfflineOp` 就有 busy／失敗／收回的同樣處理 |
| B14 | m6：舊程式的 `staleRecordLine` | `offline_op.dart` 另訂 `kStaleRecordLine`（同一句，owner.rs:65） | nodes.dart 會在 PR 6 刪除，新頁面不 import 它 |

另外發現、已照計畫修正的實作錯誤（不是偏差）：
- 8.4 的更新包原本畫了 QR，違反 T10（更新包只有文字）→ `CodeView(qr: false)`。
- `NetRun` 送出「正在套用」原本只寫 note → 改成照 R14：warn 樣式、`RekeyResult`、首頁不全綠（X-m7）。
- 隊長固定文字少了 X-m5 那一句 → 補上。
- 8.3 少了同名提示 → 補上（B9）。

待提給程式碼審查者：
- 同名句「請用加入時間分辨」：app 沒有任何地方顯示加入時間。

還沒做（等 WSL）：
- Rust `NetView.version` / `MnetView.version` 與 R19 的版本號顯示（8.1、8.4「目前是第 N 版」；8.5 與隊員 `RekeyResult` 的「這支手機是第 N 版」）。
- `rekey.rs` 的 R14 字面釘住測試（已寫，未跑）。
