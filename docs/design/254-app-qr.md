# #254 app — QR 相機掃描(認領 QR),設計 v2.2(FROZEN 2026-11-13)

v2.2 FROZEN:第 3 輪 A、B 皆 **APPROVE**(0 BLOCKER、0 MAJOR),v2.2 只收 MINOR(A r3-1~3:§3 改用 take(gen)、gen 用 SecureRandom、第一次解出即 clearAnalyzer;B r3-m1~m2:§3 / §4 文字一致)。
v2.1:第 2 輪 A APPROVE-WITH-CHANGES(1 MAJOR:回覆執行緒)、B APPROVE-WITH-CHANGES(0 MAJOR)→ 槽改為 `Entry(gen, owner, reply)`、
回覆一律主執行緒、白名單閘門每個 variant、其餘 MINOR 見各處 `r2-` 標記。

範圍來源:`254-app-s1.md` §1「做:QR 相機掃描;貼上 hex 只在 dev flavor」— 實作至今只有貼上(claim.dart:45-70)。
**誠實界線(v2 更正)**:field flavor 今天仍不能認領 — 主因不是相機,是沒有正式信任根:field 拒絕所有 dev 憑證
(batman-proto nodecert.rs:12、:36),正式根在 #255。本項讓 dev 版用相機認領,field 版在 #255 後直接可用。
v1 審查(A、B 皆 APPROVE-WITH-CHANGES)的處理見附錄 R1。

## 1. 事實(reality check,2026-11-13)

| 事實 | 證據 |
|---|---|
| 認領 QR 內容 = 一行小寫 hex,CBOR `{1: device_id(18 hex), 2: K(32 B)}`,112 字元 + 換行(`fmt.Println`) | provhelper main.go:570-594 |
| 唯一 parser:Rust `parse_claim_qr(text)`(先 `trim`,hex → CBOR → 正好兩欄、id 18 hex、K 32 B);錯誤字串不含輸入內容 | claim.rs:17-33;cbor.rs Error 變體 |
| 今天 QR 的唯一來源 = 主機 ssh 跑 `batman-provhelper qr`;節點沒有螢幕、沒有貼紙 | s1 §1;main.go:570 |
| `mobile_scanner` 7.5.0 的 Android 解碼 = bundled ML Kit;ML Kit 所有功能收裝置資訊 / 套件 / 識別碼 / 效能,HTTPS 送 Google,「Used for diagnostics and usage analytics」,頁面沒有關閉方式 | pub.dev/packages/mobile_scanner;developers.google.com/ml-kit/android-data-disclosure(2025-05-14) |
| ZXing core 3.5.4(Apache-2.0,2025-11-11);CameraX 1.6.2 穩定(2026-08-26) | Maven Central metadata;developer.android.com/jetpack/androidx/releases/camera |
| app:AGP 9.1.0 / Kotlin 2.4.0 / compileSdk 37 / minSdk 31 / targetSdk 36;MainActivity = FlutterActivity(無 `registerForActivityResult`);已用 request code 4201(BLE)、4202(SAF picker) | settings.gradle.kts:116-117;build.gradle.kts:9,24,28;MainActivity.kt:39-43,137;SwUpload.kt:192 |
| 認領開始前**沒有**「同 device_id 已有紀錄 / pending → 不覆寫」的檢查(s1 §5.1 要求)— 既有缺口,貼上路徑相同 | claim.dart:122-147;claim.rs:148-158(B-m5)→ #254 殘項(§6) |

**決定**:CameraX 1.6.2(`camera-core`、`camera-camera2`、`camera-lifecycle`;**不用 `camera-view`**:PreviewView 會把 appcompat、camera-video、media3、guava 拉進與 K 同一程序 → 預覽改用自己的 `Preview.SurfaceProvider` + SurfaceView(`setSecure(true)`),實作時決定)+ ZXing `core` 3.5.4,
並明確宣告 `androidx.activity`(QrScanActivity 是 `ComponentActivity`,需要 LifecycleOwner / `registerForActivityResult`);
不用 ML Kit / `mobile_scanner` / Play 服務。版本皆發布 ≥ 2 週。

## 2. 介面與擁有權

| 資源 | 唯一寫者 | 讀者 | 說明 |
|---|---|---|---|
| `QrScan.slot`(程序內單一槽,`AtomicReference<Entry?>`,`Entry(gen: Long, owner: Any, reply: Reply)`;`Reply` 是兩個方法的小介面 `done(text: String?)` / `fail()`,不依賴 Flutter,MainActivity 包 MethodChannel.Result) | `scanQr` 放入(`compareAndSet(null, e)`;gen = `SecureRandom().nextLong()`,程序重啟後不會與舊 Intent 的 gen 相撞,A r3-2);**取出 = `take(gen)`:只有 gen 相同才 `compareAndSet(e, null)`**,誰取到誰回覆;MainActivity.onDestroy 只清**自己 owner** 的(`dropOwner(this)`) | QrScanActivity(以 Intent extra 帶自己的 gen)、MainActivity | 保證**最多回覆一次**、只回覆給開啟這個 Activity 的那次呼叫(舊 Activity 的結果不會回給新的呼叫,B r2-m5;舊 MainActivity 晚銷毀不清掉新的槽,A r2-m3);取不到 = 丟棄、不記 log |
| 回覆執行緒 | **一律主執行緒**:analyzer 執行緒只做 `take(gen)`,取到後 `runOnUiThread { reply… ; finish() }`(與 MainActivity.kt:68… / SwUpload.kt:164 相同);逐影格 catch **只包解碼**,不包回覆(A r2-M1、B r2-m4) | | |
| CAMERA 權限 | QrScanActivity(自己 `registerForActivityResult(RequestPermission)`) | — | 不經 MainActivity.onRequestPermissionsResult,不用 request code |
| 掃到的文字 | QrScanActivity(記憶體) | Dart 經 pending 回覆 | **不走 Intent extras / setResult**(不經 system_server);不 log、不存、不進剪貼簿 |
| 相機 / 預覽 | CameraX(綁 QrScanActivity lifecycle) | — | |

契約 `scanQr`(通道 `dev.batman/platform`):
- 呼叫時槽非空 → error `busy`;否則放入並 `startActivity(QrScanActivity, extra gen)`(不是 for-result);`startActivity` 丟例外
  → `take(gen)?.fail()`(不留卡住的槽,A r2-m1)。
- QrScanActivity.onCreate:槽裡不是自己的 gen(例如程序被殺後從「最近使用」還原)→ 立刻 `finish()`,**不綁相機**(B r2-m3)。
- 成功:第一個解出、長度 ≤ 4096 的 QR 文字 → 主執行緒上 `take(gen)?.done(text)`,**不論取到與否都 `finish()`**(A r2-m6)。
  > 4096 的忽略繼續掃:沒有任何合法 payload 這麼長,也不把大字串送過通道;≤ 4096 的非認領 QR 照樣回傳,由 Rust 拒絕並顯示
  「這不是認領用的 QR 碼」(使用者看得到為何沒反應)。
- 取消 / 返回 / Activity 銷毀(`isFinishing`)而未解出 → `take(gen)?.done(null)`。
- 權限拒絕 / 無相機 / CameraX 綁定失敗 → `take(gen)?.fail()`(Dart 收到 error `camera`)→ `finish()`。
- MainActivity.onDestroy(引擎要走了)→ `QrScan.dropOwner(this)`(只清自己的;舊 Dart Result 不再回覆)。
- 每一影格:`STRATEGY_KEEP_ONLY_LATEST`;Y 平面複製 `buffer.remaining()` 位元組(最後一列常比 rowStride 短,A r2-m2);
  `try { 解碼 } catch (e: Exception) { /* 不記訊息 */ } finally { image.close() }`。

解碼(純函式 `QrDecode.decode(y: ByteArray, rowStride: Int, w: Int, h: Int): String?`,JVM 可測):
- `PlanarYUVLuminanceSource(y, rowStride, h, 0, 0, w, h, false)` — dataWidth = rowStride 處理對齊填充
  (Y 平面 pixelStride 依 Android `ImageFormat.YUV_420_888` 文件為 1;非 1 → 回 null 不猜)。
- `QRCodeReader().decode(BinaryBitmap(HybridBinarizer(src)))`(實作時 U4 拿掉 TRY_HARDER 仍 PASS → 依 U4 規則不設 TRY_HARDER);NotFound → 再以 `InvertedLuminanceSource(src)` 一次
  (終端機 `qrencode -t ansiutf8` 常是深底亮碼)。

Dart(claim.dart):所有 flavor 一個「掃描 QR」按鈕 → `scanQr` → null:不改 `_qr`;error `camera`:「需要相機權限才能掃描
(可到系統設定開啟)」;文字 → `parseClaimQr` → 與貼上相同的後續。讀到後顯示「節點編號末 4 碼 …XXXX」
(B-M1;今天外殼沒有印字,「請和外殼編號比對」的提示與 #255 外殼印字一起上,B r2-m2)。貼上 / 輸入仍只限 dev。

Manifest:`QrScanActivity` `exported="false"`、`taskAffinity=""`、`launchMode` 預設(standard)、`screenOrientation="portrait"`
(大螢幕可能被系統忽略 — Activity 無狀態,重建 = 重新掃,不影響正確性);`FLAG_SECURE`。
`<uses-permission CAMERA>`、`<uses-feature android.hardware.camera required="false">`。

## 3. 生命週期

| 情況 | 行為 | 證明 |
|---|---|---|
| 第一次用 | 系統問 CAMERA;允許 → 開預覽 | 實機 M2 |
| 拒絕 / 拒絕兩次後(系統不再問,Android 11+ 行為,不加機制) | error `camera` → 提示訊息 | 實機 M2(拒絕兩次) |
| 旋轉 / 大螢幕忽略直向 | 重建 = 重新掃;槽不動(只有 onDestroy 且 `isFinishing` 才 `take(gen)?.done(null)`) | 實機 M1 |
| 背景 / 鎖螢幕 | CameraX 隨 lifecycle 停 / 續 | 實機 M3 |
| MainActivity 被回收、程序還在(「不保留活動」) | 新 MainActivity 不持有舊 Result;舊 MainActivity 的 `dropOwner(this)` 已清槽 → QrScanActivity 解出時 `take(gen)` 拿到 null→ 丟棄、不 log;使用者回到首頁重來;Dart 無任何寫入 | 實機 M5(開發者選項「不保留活動」);單元 U6:清槽後 deliver 不呼叫任何 Result、不丟例外 |
| 程序被殺 | 結果丟失;掃描前後都沒寫入 | 程式審查 |
| 解出後還有影格到 | 第一次解出即 `clearAnalyzer()`(A r3-3);仍排入的 `take(gen)` 第二次為 null → 不重複回覆 | 單元 U6 |
| 相機被佔用 / 綁定失敗 | error `camera`(綁定丟例外,或之後的 CameraState 錯誤:`CameraErrors.endsScan`,R2 A-M1) | 單元 `CameraErrorsTest`(對應表);觀察者接線 = 實機 M4(⚠️ 若無法重現,標註) |
| 惡意 / 畸形 QR 讓 ZXing 丟 runtime 例外 | 該影格捨棄,繼續掃 | 單元 U2 |
| 升級 / 降版 | 無持久狀態 | n/a |
| iOS | 不在本版(s1 §1) | n/a |

## 4. 安全

- **資產**:K(可完成認領);認領後網路祕密會加密給該節點的 `ecdh_pub`(s1 §6)。
- **actor**:
  - *鏡頭前的惡意 QR*:長度上限 + 唯一 Rust parser;ZXing 例外逐影格捕捉。
  - *換貼紙(B-M1,v1 寫過頭,更正)*:攻擊者用自己那台**真的**未認領節點的 QR 蓋住受害者的,節點藏在附近 → app 依 QR 的
    device_id 找廣播、證書驗證**會通過**(dev:自簽 TOFU;field:#255 後那是真節點)→ 使用者認領的是攻擊者的節點。
    證書只證明「這是一台真節點、編號 = QR」,不證明「是你手上那台」。**本版不擋**(貼上路徑相同,只在 dev);緩解:
    app 顯示末 4 碼(外殼比對提示隨 #255 外殼印字一起上,B r3-m2);**工廠 / #255 殘項**:防拆貼紙、外殼印末 4 碼、認領時節點 LED 指認 → 記入 #255 checklist,
    並列入 s1 §6 已接受缺口。
  - *同機其他 app*:Activity 不 export、taskAffinity 空、結果不走 Intent → 拿不到;啟動不了。
  - *依賴供應鏈(B-M2)*:新依賴與 K 同程序且 app 有 INTERNET。處理:PR 附 `:app:dependencies --configuration
    fieldReleaseRuntimeClasspath` 加依賴前後差異;**build 時的閘門(group 白名單,B r2-m1)**:build.gradle.kts 一個檢查任務,
    掛在**每個 variant**(dev / dev2 / field × debug / release)的 `pre<Variant>Build` 前,解析該 variant 的 runtimeClasspath,
    出現白名單外的 group 就讓 build 失敗,classpath 為空也失敗。白名單 = 加依賴前實際解析出的 group(PR 附清單)+ androidx.camera
    與 com.google.zxing 帶進的新增 group(實作:camera、camera.featurecombinationquery、zxing、dagger、auto.value、jakarta.inject、javax.inject;共 39 個,與實際解析出的完全相同)。`com.google.android.gms` / `com.google.mlkit` / `com.google.firebase` /
    `com.google.android.datatransport` 永不進白名單。負對照:加 `com.google.mlkit:barcode-scanning` → FAIL;加白名單外的
    `com.squareup.okhttp3:okhttp` → FAIL。`androidx.activity` 釘在加依賴前 Flutter embedding 已解析出的版本(不拉高,A r2-m4);
    **實作更正**:CameraX 仍把 annotation-experimental 1.4.0→1.4.1、exifinterface 1.4.1→1.4.2、tracing 1.2.0→1.3.0、
    kotlinx-coroutines 1.7.1→1.9.0 拉高(camera-core / camera2 / lifecycle 要求的版本),未強制降回。
    **R2(B-M1 / B-m1)後的閘門**:白名單改為精確 `group:module`(9 個 variant 實際解析出的 79 個);另解析該 variant 的
    `android-classes-jar` 產物(要被 dex 的),不是白名單模組也不是 project 的(`:app` 或 plugin project 裡的 `files(...)`)→ FAIL。
    **閘門範圍**:只管 Gradle 的 JVM / AAR 依賴;Dart pub 套件與 Rust / FFI 的 .so 不經這裡。**仍不擋**:白名單內 group 的被入侵版本(與 K 同程序、app 有 INTERNET)
    → 要靠 Gradle 依賴鎖 + 驗證(s1 §2 早已要求、全 app 都還沒有)→ #254 殘項,不在本項。
  - *實體取得手機*:預覽上就是 K → `FLAG_SECURE`(截圖 / 最近使用縮圖黑);K 不落地。
- **權限**:新增 CAMERA(執行時、只在按掃描時要)。
- **失敗**:任何錯誤 = 沒有結果(fail-closed)。

## 5. 測試

| # | 類型 | 內容 | 負對照(沒有這項修改 → FAIL) |
|---|---|---|---|
| U1 | JVM `QrDecodeTest` | ZXing `QRCodeWriter` 產生真的認領 QR(provhelper 格式 112 hex)→ 填成 **rowStride = w + 64**、**最後一列短**(長度 rowStride·(h−1)+w)的 Y buffer → 經與 Activity 共用的 `QrDecode.fromPlane(buffer, rowStride, pixelStride, w, h)` → 回原字串 | dataWidth = w(忽略 stride)→ FAIL;配置 rowStride·h 讀滿 → FAIL |
| U2 | JVM | 雜訊 → null;4097 字元的 QR → null;畸形影像(全黑、1×1)→ null 不丟例外 | 拿掉長度上限 → FAIL |
| U3 | JVM | 反色 QR(亮碼深底)→ 解出 | 拿掉 InvertedLuminanceSource 重試 → FAIL |
| U4 | JVM | 旋轉 90° 的 QR → 解出 | 實作結果:拿掉 TRY_HARDER 仍 PASS → 已刪掉 TRY_HARDER 與此宣稱(不留沒證據的設定);本測試留作旋轉的行為測試 |
| U5 | Rust(既有) | `parse_claim_qr` 拒非 hex / 錯欄位 / 錯長度,且接受結尾換行 | 既有 |
| U6 | JVM `QrScanTest`(只用 `Reply` 假物件,不載 Flutter,A r2-m5) | 第二次放入 → busy;同 gen take 兩次只回覆一次;舊 gen 的 take 不回覆給新呼叫;`dropOwner(舊)` 不清新的槽;start 失敗 → fail 且槽清空(只測 QrScan;MainActivity 的 `catch` 接線 = ⚠️ 程式審查) | `take` 不比 gen → 舊結果回給新呼叫 → FAIL;`dropOwner` 改無條件清 → FAIL;`take` 只 `get()` 不清槽 → 重複回覆 → FAIL。**更正(R2)**:所有槽操作都在主執行緒,CAS 換成 `slot.set(null)` 測不出差異(審查的突變體存活),CAS 不是正確性的依據、不宣稱有負對照 |
| G1 | build | 依賴閘門(每個 variant):目前 PASS;加 mlkit → FAIL;加 okhttp(白名單外)→ FAIL;空 classpath → FAIL | 即負對照本身 |
| M0 | 實機(S20) | 回覆在主執行緒:dev 版掃描後 Dart 收到文字(與 M1 同次) | 回覆改在 analyzer 執行緒 → Dart 卡住 / 例外(記錄) |
| M6 | 實機 | 掃描中 `am kill` → 從最近使用回來 → 不開相機(無預覽、無隱私指示燈) | 拿掉 onCreate gen 檢查 → 相機開 |
| D1 | Dart widget test | 所有 flavor 都有「掃描 QR」;scan 回 null → `_qr` 不變;error `camera` → 權限訊息 | 隱藏 field 按鈕 → FAIL |
| M1 | 實機(S20,**需要人**) | 04 `batman-provhelper qr` → 主機 `qrencode -t ansiutf8`(反色)與 PNG(正色)各一 → 掃描 → **dev flavor** 認領成功 | — |
| M2–M5 | 實機(**需要人**) | 權限拒絕兩次;背景;相機佔用(M4:另一 app 佔用 → error `camera` 提示 → 放開相機 → 再按掃描能開預覽,驗觀察者接線與 LiveData 最後值重播,R2 A r2-m2/m3);「不保留活動」 | — |
| S1 | 實機秘密 | logcat 全程 grep:QR 全文、K hex(大小寫)、K base64 = 0;擷取為空或 QR 文字未取得 → FAIL | 暫加一行 `Log.d(text)` → FAIL |
| S2 | 實機 | 掃描畫面 `adb exec-out screencap` 為黑;`am start -n …/.QrScanActivity` 被拒(not exported) | 拿掉 FLAG_SECURE → 截圖看得到預覽;暫改 `exported="true"` → `am start` 成功 → FAIL(B r2-m6) |

使用者遠端時:U1–U6、G1、D1、S2 的 `am start` 部分完成;M1–M5、S1、S2 截圖需要人在手機旁(⚠️ 標註)。
**field flavor 的端到端認領驗不到**(#255 前沒有正式根)。

## 6. 不做 / 殘項

- 邀請 / 申請 / 核准 / 成員名單的 QR(member-join §5-5 阻擋 field;名單 4.6 KB 放不進一張 QR;當面邀請無設計)— 之後可接同一 `scanQr`。
- 節點端貼紙 / 列印、防拆、外殼印字、LED 指認 → #255 checklist。
- **既有缺口**(B-m5):認領前未檢查同 device_id 已有紀錄 / pending(s1 §5.1)→ #254 checklist,下一項做(含 Rust 測試)。
- Gradle 依賴鎖 → #254 checklist。
- 本 PR 實際修改 `254-app-s1.md` §6,把「換貼紙」列入已接受缺口(B r2-m7;不只寫在本附錄)。
- iOS。

## 附錄 R1 — v1 審查處理

| 發現 | 處理 |
|---|---|
| A-M1 介面 / 擁有權未定義 | §2 擁有權表 + 契約;程序內單槽 `getAndSet`;權限在 QrScanActivity 內;不用 request code |
| A-M2 MainActivity 回收 | §3 新列 + M5 + U6 |
| A-M3 YUV stride | `PlanarYUVLuminanceSource(dataWidth = rowStride)` 純函式;U1 用填充 buffer,負對照忽略 stride |
| A-M4 U1 負對照無效 / U3 非必要 / 缺 Dart 測試 | U1 負對照改 stride;U4 規則(無效即刪設定);D1;S1 加負對照 |
| A-M5 QR 來源 / 反色 / field 驗不到 | §1 來源事實;反色重試 + U3;M1 用 qrencode 兩種;寫明 field 驗不到 |
| A-M6 依賴相容性 | §1 artifact 清單、明確 `androidx.activity`;PR 附 dependencies 差異 |
| A-m1 大螢幕直向 | Activity 無狀態,重建 = 重掃 |
| A-m2 / B-m3 Intent 經 system_server | 改程序內回覆,不走 Intent |
| A-m3 不再詢問 | 系統行為,不加機制;M2 拒兩次 |
| A-m4 錯誤字串含 K? | 已證:cbor Error 不含輸入(B 查證) |
| A-m5 長度上限語意 | §2 寫明 |
| B-M1 換貼紙 | §4 更正 + 末 4 碼比對提示 + #255 殘項 + s1 §6 已接受缺口 |
| B-M2 遙測無證據 | build 閘門 G1 + dependencies 差異;Gradle 鎖 → 殘項 |
| B-m1 S1 負對照 | S1 改寫 |
| B-m2 FLAG_SECURE 測試 | S2 |
| B-m3 宣告 / 結果回傳 | §2 manifest;`am start` 負測 |
| B-m4 ZXing 例外 | 逐影格 catch + U2 |
| B-m5 既有 pending 覆寫 | 既有缺口 → §6 / #254 |

## 附錄 R2 — code review r1(5079b47..6768c35,A、B 皆 APPROVE-WITH-CHANGES)

| 發現 | 處理 | 負對照 |
|---|---|---|
| B-M1 閘門看不到 `files(...)` 依賴(`:app` 與 plugin project) | 閘門另解析 variant 的 `android-classes-jar` 產物:不是白名單模組、也不是 project → FAIL;仍 configuration-cache 安全 | init script 加 `files(probe.jar)` 到 `:app`、到 `:reactive_ble_mobile` → 各自 FAIL `not a module or project: probe.jar` |
| A-M1 相機被佔用 / 停用 / 數量上限是非同步的,`bindToLifecycle` 不丟例外 → 黑畫面 | 觀察 `cameraInfo.cameraState`;`CameraErrors.endsScan` → `fail()`(r2 起的規則見下一列 A r2-m1) | `CameraErrorsTest`;觀察者接線 ⚠️ 實機 M4 |
| B-m1 白名單以 group 為單位,camera-view / camera-video / 完整 guava 可能悄悄回來 | 改為精確 `group:module`(79 個) | 加 `androidx.camera:camera-view` → FAIL;mlkit、okhttp、空 classpath → FAIL |
| A-m3 QrScanActivity 沒有 configChanges,被重建時舊實例可能回覆 | 解出後的主執行緒 runnable 先檢查 `isDestroyed` | ⚠️ 程式審查(需 Activity 重建,JVM 測不到) |
| A-m4 掃描中可再按 → busy | Dart `_scanning` 旗標讓按鈕失效;`camera` 訊息涵蓋「相機無法使用」 | D1:拿掉旗標 → FAIL |
| A-m5 讀到非認領 QR 後仍可認領前一台 | `_read` 失敗 → `_qr = null`;await 後檢查 `mounted` | D1:拿掉 `_qr = null` → FAIL |
| U6 的「CAS 改 get() → FAIL」宣稱不實 | §5 U6 改寫:槽操作都在主執行緒,`set(null)` 突變體存活;`aFailedStartFailsAndFreesTheSlot` 只測 QrScan,MainActivity 的 catch 為 ⚠️ 程式審查 | — |
| `setSecure(true)` | 縱深防禦;視窗的 `FLAG_SECURE` 已讓截圖全黑,沒有單獨的負對照 | — |
| 閘門範圍 | §4:只管 Gradle JVM / AAR 依賴,不含 Dart pub 套件與 FFI .so;也不含 pub plugin 自己的 `android/src` 原始碼(那是 project,`ProjectComponentIdentifier` 一律放行,B r2-m1) | — |
| Viewfinder 長寬比 | 緩衝 = 請求解析度、縮放到 view,可能變形;解碼讀 ImageAnalysis 不受影響 | ⚠️ 實機 M1 |
| 測試檔 UTF-8 BOM | 已移除 | — |

### R2 續 — code review r2(25612b1,A APPROVE-WITH-CHANGES 0 MAJOR;B APPROVE-WITH-CHANGES 1 MAJOR)

| 發現 | 處理 | 負對照 |
|---|---|---|
| A r2-m1 STREAM_CONFIG 在 camera-core 1.6.2 是 CRITICAL,r1 卻留給 CameraX | `endsScan` = 有錯誤且不是 ERROR_OTHER_RECOVERABLE_ERROR。證據(`javap -c CameraState$StateError`,getType):`if_icmpeq` 比 2、1,`if_icmpne` 比 3 → `RECOVERABLE`,其餘 → `CRITICAL`。IN_USE / MAX_CAMERAS_IN_USE 對 CameraX 雖可恢復,仍結束掃描(使用者要知道原因) | STREAM_CONFIG 不結束 → FAIL;OTHER_RECOVERABLE 結束 → FAIL |
| B r2-M1 manifest 保證只靠實機 | `check<Variant>ManifestGate`(每個 variant,`package<Variant>` 前;合併 manifest 在 pre<Variant>Build 時還不存在):QrScanActivity 必須 `exported="false"` 且沒有 intent-filter;權限集合必須**完全等於**下列 11 項(field release 合併 manifest,`${applicationId}` 換成該 variant 的):`uses-permission`:BLUETOOTH_SCAN、BLUETOOTH_CONNECT、INTERNET、CHANGE_NETWORK_STATE、ACCESS_NETWORK_STATE、CAMERA、BLUETOOTH、BLUETOOTH_ADMIN、`${applicationId}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`;`uses-permission-sdk-23`:ACCESS_COARSE_LOCATION、ACCESS_FINE_LOCATION | 暫改 `exported="true"` → FAIL;多一個 RECORD_AUDIO → FAIL |
| S1 / S2 | S2 的 `am start`(及 `exported="true"` 對照)要把 APK 裝到 S20,等擁有者同意;S1 logcat 與 S2 截圖需要人在手機旁 → PR 標 ⚠️ | 未跑 |
| B r2-m1 閘門範圍 | 見上表「閘門範圍」:pub plugin 的 `android/src` 原始碼不在閘門內 | — |
| B r2-m2 別的 repository 的同名模組會通過閘門 | 屬 #254 的 Gradle 鎖殘項:要 Gradle dependency verification(`verification-metadata.xml` 檢查碼),不只 locking | — |
| B r2-m3 APK 來源 | r1 的 APK 已從乾淨的 committed tree 25612b1 重建並記 sha256 → 關閉;之後每次照做 | — |
| A r2-m2 / m3 觀察者接線、LiveData 最後值重播 | 仍 ⚠️ 實機 M4;M4 加子步驟「佔用 → error → 放開相機 → 再掃描能開」 | 未跑 |

### R2 續 — code review r3(5c7b9fe,A APPROVE 1 MINOR;B APPROVE-WITH-CHANGES 1 MAJOR)

| 發現 | 處理 | 負對照 |
|---|---|---|
| B r3 MAJOR:plugin manifest 裡的 `<activity-alias … targetActivity=QrScanActivity exported="true">`(含 intent-filter)與 `<uses-permission-sdk-m RECORD_AUDIO>` 都進了合併 manifest,r2 閘門仍 PASS | 一般化:**權限** = 所有 tag 以 `uses-permission` 開頭的元素(含 -sdk-23、-sdk-m 與日後新增的),以 `tag:name` 與預期集合**完全相等**(多 / 少都 FAIL);**匯出元件** = activity / activity-alias / service / receiver / provider 中 `exported="true"`,或有 intent-filter 卻沒寫 exported 的(fail-closed;targetSdk 36 在合併 / 安裝時就會拒絕這種,理論上看不到),必須在精確名單內;**任何** targetActivity 是 QrScanActivity 的 activity-alias → FAIL;QrScanActivity 本身規則不變 | batman_bridge plugin manifest 加 activity-alias → FAIL(fieldRelease、devDebug) |
| (同上) | 匯出元件名單(field release 合併 manifest,2026-11-13):`activity:dev.batman.batman_app.MainActivity`、`receiver:androidx.profileinstaller.ProfileInstallReceiver` | plugin 加 `uses-permission-sdk-m` RECORD_AUDIO → FAIL |
| B r3 m1 plugin 的 exported service 會通過 | 由上面的匯出元件規則涵蓋 | plugin 加 `<service com.evil.Svc exported="true">` → FAIL;既有對照(app 的 `exported="true"`、RECORD_AUDIO)仍 FAIL |
| A / B r3 m2 AAB(`bundle<Variant>`)不跑 manifest 閘門 | 閘門也掛在 `package<Variant>Bundle` 前(`bundleFieldRelease --dry-run` 列出 `checkFieldReleaseManifestGate` 與 `packageFieldReleaseBundle`) | activity-alias 走 `bundleFieldRelease` → 在 `checkFieldReleaseManifestGate` FAIL |
| r4 B MINOR(A APPROVE 0/0/0、B APPROVE):`android:exported="@bool/evil_exp"`(資源參照,安裝時為 true)的 plugin service 通過,因為只認字面 `"true"` | 匯出 = exported 值不是字面 `"false"`,且(有值 或 有 intent-filter) | plugin service `exported="@bool/evil_exp"`(res `evil_exp`=true)→ FAIL(fieldRelease、devDebug);修改前同一對照 PASS(rc=0) |
