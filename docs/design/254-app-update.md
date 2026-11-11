# #254 app S5 — 軟體更新(設計 v0.4 FROZEN)

**狀態:v0.4 FROZEN(2026-11-12):第 2 輪 A、B 皆 APPROVE-WITH-CHANGES,0 BLOCKER;唯一的 MAJOR(A N1)以刪除修掉。** 各輪:v0.2 A APPROVE-WITH-CHANGES(1 BLOCKER / 8 MAJOR)、B REJECT(1 / 5);v0.3 A APPROVE-WITH-CHANGES(0 / 1)、B APPROVE-WITH-CHANGES(0 / 0)。
- v0.4(幾乎都是刪除,附錄 C):
  - PUT 中斷後固定等 31 s,刪掉「百分比停住」與「有人正在上傳」偵測。
  - 中止 socket 一律 `setSoLinger(true, 0)` 再關。
  - 刪掉 targetSdk 的建置檢查(T13)、T12 的負對照 2、U7 在 200 之後的 `bulk/open`。
  - 向量擷取程式改列為本功能的交付物。
  - 其餘是一行修正。
- v0.2:把協調者在 04 的唯讀實測寫進來(F26–F28)。
- v0.3 改了四件事:
  1. 原本 §9 問使用者的設計問題,改成作者已定的決定(§2,2026-11-12);§9 只留兩個真的要使用者決定的點。
  2. 修掉審查 A 的 B1、M1–M8,以及審查 B 的 B1、M1–M5。只要一行就能改的 MINOR 直接改,其餘列在 §12。對照表在附錄 A、B。
  3. 方向是減少機制:
     - PUT 的結果只分「200」和「其他」;
     - 每次 PUT 之前都先送 `bulk/open`;
     - 任何失敗之後,一律先經 BLE 讀 `update/status` 再決定;
     - PUT 用 raw socket 送:不放寬全 app 的明文政策,也不經 proxy;
     - 拿掉獨立的 TCP 探測,改由 PUT 本身的連線來判斷。
  4. targetSdk 固定成 36(v0.4 刪掉了建置檢查)。

範圍原則(使用者 2026-11-07 / 11-09):
- 先跑通一條路,做產品,不加多餘的機制。
- 失敗就回到之前的狀態(2026-10-30)。
- 電量不是檢查項目。

來源:
- 254-p3-impl.md §3.7、§3.8、§3.11(下文稱 **P3**,行號以 Batman-p3 @ d9b1428 為準)。
- 219-protocol.md §4.2、§5.2、§5.3;219-protocol.cddl;219-field-provisioning.md §2.2、§6.9、B19。
- 節點程式 `feed/batman-prov/src/`(下文省略這個前綴)。
- app:Batman-app `feat/254-app-s1` @ ff1805a。
- Go 1.26.4 標準庫。
- Android 開發者文件與 AOSP 原始碼(審查 B 2026-11-12 抓取)。

## 0. 一句話

擁有者在節點頁按「軟體更新」,選手機裡的兩個檔(manifest 和 payload)。接著:
1. app 經 BLE 問節點能不能裝(`update/check`)。
2. 每次上傳前,經 BLE 開啟或延長上傳窗(`bulk/open`)。
3. 手機透過**這台節點的手機 AP**,用 raw socket 送一個 HTTP `PUT`,把 payload 傳上去。
4. 經 BLE 送 `update/prepare`,並輪詢 `update/status`。
5. 使用者按「套用並重開」(`update/apply`)。節點重開後,app 重新經 BLE 連上,顯示「試用中」「完成」或「已退回」。

**除了那一個 PUT,其他全部走既有的 BLE 擁有者 session。結果一律以 BLE 讀到的 `update/status` 為準。**

## 1. 事實(reality check;每一條都附 file:line)

| # | 事實 | 證據 |
|---|---|---|
| F1 | **不需要在 HTTP 上建 Noise session。** PUT 唯一的憑證是 bearer:放在 `X-Batman-Upload`,32 個小寫 hex,以 constant-time 比對;不看 session,也不綁來源 IP。設計原文:「正常流程經 BLE 開窗,沒有對應的 HTTP session」。`update/prepare` 可以經 BLE 送 | provd/http.go:508-564;P3 :488、:491 |
| F2 | 擁有者在 BLE 上可以用所有更新動詞;其中後四個是 owner-op | provd/session.go:78-81、:90-92 |
| F3 | `update/check {1: update-manifest}`:<br>• manifest 是 CBOR **map**,上限 64 KiB。<br>• 有兩層限速:每條連線 1 / 10 s,helper 全域 1 / 10 s。回 E_BUSY 時也會更新全域的時間戳。<br>• 回應是 `{1: ok, ?2: reason, 3: RAM}`;拒絕也是用 ok 回應帶 reason。 | provd/update.go:12-48;node/update.go:35、:265-283;cddl:304、:336 |
| F4 | check 在這些情況回 E_BUSY:上傳窗開著或 worker 在跑(**同一位擁有者也一樣**),或有效的 pending 屬於另一位擁有者。同一位擁有者在沒有窗、也沒有 worker 時再送 check → 覆寫 pending | node/update.go:280-288、:358-366 |
| F5 | check 先驗簽章;image 裡沒有根鑰匙 → 24。pending 只存在 helper 的記憶體,30 分鐘(以 uptime 計)到期,helper 重啟就消失。check 會跑 `precheck-node`(最多 120 s)和目標槽的 `bootinfo` | node/update.go:36、:41、:291-303、:366 |
| F6 | manifest = `{1 version, 2 board, 3 大小, 4 sha256(SHA256SUMS), 5 bstr([E, S]), ?6}`。key 1–4 和 6 必須等於 S 裡的值,否則回 11 | cddl:305-315 |
| F7 | bench 用 `signrel.py <payload> --board B --out DIR` 產生 `DIR/manifest.cbor`(canonical) | Batman-h-s5 tests/tools/peer/signrel.py:15、:179-185 |
| F8 | 一般 `wsl` / `ci` image 沒有根鑰匙(→ 24);bench build 信任 T;`rel` 只信任 R(要到 #255 才有) | P3 :296、:338-340 |
| F9 | `status` key 15 的 `trust` 是 `"none"`、`"bad"`,或 16 個 hex(根鑰匙指紋 = sha256(65 B 點)的前 8 B);`http_bind_failed` 表示 8095 被別人佔用 | node/status.go:230-234、:258-260;P3 :315、:427、:471 |
| F10 | `bulk/open` 的結果:<br>• 沒有 pending、不是擁有者、sha 不符 → 15;AP 關著 → 16;tmpfs 沒掛上或防火牆檢查沒過 → 21;worker 在跑或窗是別人的 → E_BUSY。<br>• 回應 `{ssid, AP 現行密碼, IPv4, 8095, 900, bearer}`。<br>• 同一位擁有者重送 = 延長同一個窗、回**同一個** bearer;helper 重啟後才會回新的 bearer。<br>• 防火牆檢查由 helper 在背景每 4 s 做一次,結果快取 ≤ 10 s。 | node/bulk.go:13-14、:21-23、:54-97 |
| F11 | PUT 在**讀 body 之前**就會拒絕的情況:409(窗沒開 / worker 在跑 / 已有 PUT / 窗剩的時間不夠)、403(bearer 錯)、400(Content-Length 不對)。此時 Go 送出 Connection: close,只再等 500 ms(`rstAvoidanceDelay`),Go 的註解明說「client 還在寫的話,最後的回應會被截掉」→ **送 126 MB 的那一端多半看不到狀態碼**。其他行為:<br>• 每次 PUT 都從頭寫。<br>• 30 s 內低於 256 KiB/s 就切斷。<br>• 關好檔案才回 200。<br>• header 期限 5 s、上限 4 KiB。<br>• 同時最多 8 條連線。 | provd/http.go:34、:339-340、:509-564、:567-578;Go 1.26.4 net/http/server.go:1770、:1784-1794 |
| F12 | 中斷的 PUT 會一直佔住唯一的上傳槽(`putting`),直到 30 s 讀取逾時才放掉 | provd/http.go:46、:540、:571-572 |
| F13 | provd 要等下一次 poll(每 4 s)才拿到 bearer、才開始 bind → `bulk/open` 之後 10 s 內連線被拒是正常的 | provd/server.go:21;P3 :517 |
| F14 | HTTP 只 bind 手機 AP 的 bridge、埠 8095。不是從手機 AP 進來的封包會被**丟棄**(drop),所以對方看到的是逾時 | P3 :461-471 |
| F15 | `update/prepare` 回 15 的三種原因:沒有 pending / sha 不符、呼叫者沒有持有窗、上傳不完整;這時窗不關、上傳檔不刪。其他:孤兒寫入或 worker 在跑 → E_BUSY;寫不進 update-last → E_STORAGE;成功 → 關窗,回 phase 2 | node/updwork.go:196-240 |
| F16 | worker:<br>• 第一遍只驗證,開檔後就 unlink 上傳檔。<br>• 第二遍才寫入;`begin_write` 之後,退路就被覆寫了。<br>• 逾時 → 21,目標槽保持 BAD。<br>• worker 結束後,pending 再活 30 分鐘。 | node/updwork.go:280-290、:320;P3 :433-443 |
| F17 | `update/apply`:<br>• 只接受 pending 的擁有者,而且目標槽的 VERIFIED 要等於 sha + 本次 boot_id,否則回 15。<br>• arm 最多 180 s。arm 回 10–18 → 拒絕,不 disarm;其他非 0 → disarm。<br>• 其他拒絕原因是 1 / 2 / 5 / 11 / 12 / 17 / 21;E_BUSY;E_STORAGE。<br>• 回應送出 2 s 後重開。 | node/updwork.go:49、:690-760;node/update.go:42、:46-66 |
| F18 | `update/status` 是唯讀的,**不分擁有者**:<br>• 沒有槽資訊或 update-last → `{1: 0}`。<br>• 退回只有 6(reason 0)和 6 + 18 兩種。<br>• 22 / 23 只會在 from_slot 出現。<br>• 其他情況 → 0 + sha。<br>• 5 / 6 會一直留著,直到下一次 prepare。<br>• phase 1 的百分比 = provd 已收的 bytes(每次 PUT 開始時歸零)。 | node/updwork.go:853-917;provd/http.go:554 |
| F19 | ops 連線一次只處理一個請求,同時有別的在跑 → E_BUSY;超過 330 s → E_BUSY,附 「outcome unknown」 | provd/server.go:23、:206-207;provd/session.go:603-624 |
| F20 | app 目前的 BLE 請求預設等 15 s | app/lib/nodes.dart:78、:457 |
| F21 | P3 列給 app 的需求 | P3 :504-517 |
| F22 | BLE 擁有者 session 閒置 300 s 就斷 | provd/server.go:30-31 |
| F23 | app 現況:<br>• 沒有 HTTP client,也沒有 Wi-Fi 加入的程式碼。<br>• main manifest 沒有 `INTERNET`(只有 debug / profile 有)。<br>• 沒有 `networkSecurityConfig`。<br>• targetSdk 跟 flutter 走,目前是 36;compileSdk 37。<br>→ 全 app 不允許明文 HTTP(security-config 文件:API 28 起預設關閉) | AndroidManifest.xml:3-15;src/debug/AndroidManifest.xml:6;build.gradle.kts:9、:24-25;flutter FlutterExtension.kt:34 |
| F24 | targetSdk 37(Android 17)起強制 local network protection:沒有 `ACCESS_LOCAL_NETWORK` 就不能對本地網路發起 TCP 連線(local-network-permission 文件) | 審查 B M4 |
| F25 | 單 STA 手機上,Specifier 會先斷掉目前的 Wi-Fi(包括同一個 SSID 的已存網路);請求放掉時會再斷一次。「已連上就沿用」只適用於之前也是經 Specifier 連上的。Specifier 連上的網路是 ephemeral,放掉時移除 → 密碼不留存;但「同意」會存檔。只有前景 app 能發請求 | AOSP WifiNetworkFactory.java :1546-1566、:1098-1113、:1945、:810-817(審查 B) |
| F26 | `Network.openConnection(URL)` 會套用該網路的 proxy(包括全域 / PAC / MDM) | AOSP Network.java(審查 B m1) |
| F27 | **04 實測**(唯讀):手機 AP = `default_radio0`,`encryption='psk2'` → WPA2 | 04 = 10.41.80.13 |
| F28 | **04 的手機 AP 是關著的**(`disabled='1'`):app 流程的節點在擁有者設定 key 20 之前都是這樣 → `bulk/open` 會回 16。app 已經有 key 20 的設定那一列 | 04 唯讀探測;P3 :511;app/lib/nodes.dart:1508-1528;owner.rs:707-713 |
| F29 | **04 跑 `1.5.14-wsl.25+fbc01ae.fw02f0913`,沒有 `release-root.pub` → trust 是 none → check 回 24** | 04 唯讀探測 |
| F30 | 節點已經有主機端的更新路徑測試,可以從那裡擷取真實回應 | node/updwork_test.go:318、:592;provd/http_test.go:421-535 |
| F31 | `nodes.dart` 會用 `debugPrint` 印出每一個 `st.detail` 和例外 `$e`,release build 也會進 logcat | app/lib/nodes.dart:26、:242、:289、:295、:311(審查 B m10) |
| F32 | 現場:每人一台節點,手機平常連著自己節點的 AP 跑 TAK;更新在維護時、人在節點旁邊做;payload ≤ 約 126 MB;流程上限 4 步 | memory;219-field-provisioning.md:136、:448 |

## 2. 決定(作者定,2026-11-12;每項附一行理由)

- **D1 更新包 = 用 SAF 選手機裡的兩個檔**(可以多選)。依內容分辨:開頭是 `1f 8b` 的是 payload;manifest 先限制 ≤ 64 KiB 才解碼(F3);payload 只讀開頭 2 bytes。下載與背景下載 → #255。理由:發行管道和 R 都還沒有;bench 已經能用 signrel 產出這兩個檔。
- **D2 手機上只比大小和 gzip 開頭,不比 SHA256SUMS。** 理由:節點本來就會驗;app 不需要新增 tar 解析面。代價:選錯一個大小剛好相同的檔,要傳完才會知道(§4 的 11 第一句會提醒)。
- **D3 BLE 跑所有動詞;HTTP 只有一個 PUT。** 理由:F1、F2。
- **D4 PUT 用 Kotlin `network.socketFactory.createSocket()` 開 raw socket,手寫 HTTP/1.1。** 全 app 的明文政策維持關閉(不加 `networkSecurityConfig`,不用 `usesCleartextTraffic`)。理由:明文政策只約束 HTTP 堆疊(F23);raw socket 也不經 proxy(F26),不會 chunked,不會自動重試。
  - 送出:`PUT /batman/v1/bulk/0 HTTP/1.1`,接著 `Host`、`X-Batman-Upload`、`Content-Length`、`Connection: close` 四個 header 和空行;body 從 `ContentResolver.openInputStream` 以 64 KiB 為單位串流。
  - **結果只分兩類:讀到狀態列 `200`,或「其他」**(任何其他狀態碼、I/O 錯、逾時、取消)。理由:提早拒絕時多半根本看不到狀態碼(F11)。
  - **watchdog**:已寫出的 bytes 35 s 沒有增加 → 中止 socket,結果算「其他」。讀狀態列的 SO_TIMEOUT 設 35 s。理由:寫入可能卡住,TCP 自己要很久才放棄(審查 B M3)。
  - **取消**(U6)= 中止 socket + `bulk/close`。Specifier 網路 `onLost` → 中止 socket。
  - **中止 = `setSoLinger(true, 0)` 再 `close()`**(送 RST、丟掉送出緩衝區)。理由:一般 close 會讓核心繼續送完緩衝區,節點的 PUT 就可能撐過 31 s 的等待(v0.3 B m2、A N1)。
  - PUT 迴圈與 `requestNetwork` 的 callback 都不在 UI thread(v0.3 B m5)。
- **D5 連上節點 AP:手機目前的 Wi-Fi 是主要路徑,Specifier 只是後備。**
  - 用 `registerNetworkCallback(TRANSPORT_WIFI)` 收集網路(不用已棄用的 `getAllNetworks`)。如果某個網路有**直連**路由涵蓋節點 IP(`RouteInfo.matches(ip) && !isDefaultRoute() && !hasGateway()`),就直接在那個 Network 上 PUT。
  - **不另外做 TCP 探測:PUT 自己的連線就是探測。**
    - 連線逾時 3 s → 再試一次 3 s;兩次都逾時 → 不是這台的 AP(F14 是 drop)→ 改用 Specifier(v0.3 A m2、B m4:訊號差或 ARP 慢時,避免誤走 Specifier 讓 TAK 斷兩次)。
    - 連線被拒 → 封包到了節點,只是還沒 bind(F13)→ 每秒重試,最多 10 s。
    - 理由:少一個機制;結果和審查 A m5 要的「RST 和逾時分開」一樣;也不會多佔 provd 8 條連線中的一條(審查 B m2)。
  - 後備是 Specifier:`setSsid` + `setWpa2Passphrase`(F27),移除 INTERNET capability,`requestNetwork(…, 60 s)`。**這個網路保留到整個上傳階段結束**(進 U8、取消,或 3 次用完)才 `unregisterNetworkCallback`;重試不重新請求(v0.3 A m1:否則每次重試 TAK 都斷兩次)。
    - 走這條之前要先告訴使用者:「手機會暫時離開目前的 Wi-Fi(TAK 會中斷),傳完自動回來」(F25)。
    - 只在前景發請求;在背景失敗 → 走 `onUnavailable` 的文字。
  - 不讀 SSID、不需要定位權限、不用 `bindProcessToNetwork`。
- **D6 targetSdk 固定成字面值 36**(`build.gradle.kts` 寫死,加註解說明原因);不另加建置檢查。理由:F24;寫死之後 `flutter upgrade` 就改不到它,有人手動改那一行由 code review 把關(v0.3 B 可砍項 c)。要升到 37 時,另外處理 `ACCESS_LOCAL_NETWORK`(§12)。
- **D7 狀態只放在節點上。** app 不寫紀錄,也不存 bearer、密碼或檔案位置。重試計數只在記憶體裡,app 被殺就歸零(誠實界線)。理由:節點是唯一的真相來源。
- **D8 秘密只在需要時經過 Dart。** Kotlin 分三個呼叫:`findNodeNetwork(ip)`、`joinAp(ssid, pass)`(只有沒找到時才呼叫)、`upload(uri, size, ip, port, bearerHex)`。`result.error` 不帶任何參數。更新流程不 `debugPrint` 步驟文字和例外(F31)。理由:審查 B m10。
- **D9 不做 foreground service。** 螢幕保持亮;U3 的文字寫明「不要離開這個畫面,也不要關螢幕」。理由:最小可行;中斷了就從頭重傳(F11)。
- **D10 用字**:「寫入開始後不能取消」、「寫好後舊版本的退路已失效」。理由:F16。
- **D11 apply 之後最多等 5 分鐘重開、15 分鐘試用**,之後說「請稍後在狀態頁確認」。理由:autocommit MIN_WINDOW 是 300 s(P3 :453)。
- **D12 reason 16 → 帶到節點頁既有的「設定 Wi-Fi」那一列**,設好再回來繼續。理由:F28。
- **D13 信任**:field flavor 只有在 `trust` 等於 app 內建的 production 根鑰匙指紋時才開放更新(在 #255 之前等於關閉);dev / dev2 開放,並顯示「測試信任:<16 hex>」。**這只是 UI 的閘門,真正把關的是節點驗簽**(trust 只有 64 bit)。理由:P3 :347;bench image 萬一外流,field 版也不會裝。
- **D14 等待時間**:`update/check`、`update/apply` 等 ≥ 340 s;其他照原本的 15 s。理由:F5、F17、F19。
- **D15 一條總規則:任何失敗之後,先經 BLE 讀 `update/status` 再決定下一步。** 理由:status 是唯一的真相;不解析 HTTP。
- **D16 iOS 不在這一版。**

## 3. 流程與畫面

入口:節點頁(擁有者 session)最下面的「軟體更新」。

### 3.1 進頁(只讀)
1. 讀 `status` 的 key 15(`trust`、`tenants`、`http_bind_failed`),再讀 `update/status`。
2. 依 `trust` 決定:
   - `"none"` 或沒有這個欄位 →「這台節點的軟體不能經 App 更新,只能用電腦(ssh)更新或重燒卡」。
   - `"bad"` →「這台節點的更新設定損壞 — 請找維修人員」。
   - field 版而指紋不符(D13)→「這版 App 還不能更新節點」。
   - 以上三種都不顯示選檔按鈕。
3. `http_bind_failed` →「節點的上傳埠被佔用,請重開節點後再更新」。
4. `update/status` 不是閒置 → 依 §3.3 處理。

### 3.2 一次完整更新

| 步 | app 做什麼 | 畫面 |
|---|---|---|
| U1 選檔 | SAF 選兩個檔。manifest:≤ 64 KiB、嚴格 CBOR,key 1 / 2 是 tstr、3 是 uint、4 是 32 B、5 是 bstr。payload:開頭 `1f 8b`,大小 = key 3(用 `statSize`;−1 → 拒絕) | 「選好的版本:<key 1>」(**還沒驗證**);不符 →「檔案不對:<哪一項>」 |
| U2 檢查 | `update/check`,等 ≥ 340 s | 等待中:「節點正在檢查,最多約 6 分鐘,這段時間不能取消」;ok →「可以從 <info key 4> 更新到 <key 1>」;拒絕 → §4;E_RATE → 10 s 後再送一次,第二次還是 E_RATE → 顯示文字;E_BUSY 或逾時 → §3.4 |
| U3 確認 | 「開始傳送後請留在這個畫面,不要離開、不要關螢幕。寫入開始後不能取消;寫好後舊版本的退路已失效。」 | 取消 = 什麼都不送(pending 30 分鐘後自己到期;這段時間別的擁有者手機不能開始更新) |
| U4 開窗 | owner-op `bulk/open`。**每次 PUT 之前都送**,包括第一次、每次重試,以及 BLE 重連之後 | 16 → §3.5;其他失敗 → §3.4 |
| U5 連 AP | D5:手機目前的 Wi-Fi;沒有的話先跳出 Specifier 說明 → 系統對話框 | 拒絕或 60 s 沒連上 →「沒有連上節點的 Wi-Fi — 請確認手機 Wi-Fi 已開啟」+ 開系統 Wi-Fi 面板 /「再試一次」/「取消」(取消 = `bulk/close`) |
| U6 上傳 | D4 的 PUT;同時每 10 s 經 BLE 讀 `update/status`(讓 BLE 不會閒置斷線) | 進度條(本機已送出的 bytes)+「取消」(= 中止 socket + `bulk/close`) |
| U7 寫入 | 收到 200 → BLE 斷過就先重新登入 → `update/prepare`(不再先送 `bulk/open`,v0.3 A m3)。界線:200 之後窗至少還剩 60 s(F11 的放行條件);BLE 重連超過這段時間 → prepare 回 15 → §3.4 → 重傳 | phase 2:「節點正在驗證並寫入新版,可以離開這個畫面」 |
| U8 等寫完 | 每 5 s 讀 status | 2 → 百分比;3 →「套用並重開」;其他 → §3.3 / §3.4 |
| U9 套用 | `tenants` 裡有 TAK → 先確認「重開約 2 分鐘,全隊 TAK 中斷」;`update/apply`,等 ≥ 340 s | 「節點重新開機中…」 |
| U10 重開後 | 每 10 s 重試登入,最多 5 分鐘;試用期間節點退回時會再重開一次,沿用同樣的重試 | 4 → 試用中(每 30 s 讀一次,最多 15 分鐘);5 →「更新完成:<key 5>」;6 →「新版不健康,已退回原本的版本」;6 + 18 →「新版沒有完成試用,已回到原本的版本」;時間到 →「請稍後在狀態頁確認」 |

### 3.3 讀到的 `update/status` 怎麼解讀

status 不分擁有者(F18);「我們的」= status key 4 等於我們選的 manifest 的 key 4。

| status | app 做什麼 |
|---|---|
| 1 | 「節點上有一個上傳中的更新(<key 5>)」。<br>• 是我們的:上一個 PUT 剛中斷 → §3.4 的等待規則,然後 U4。<br>• 不是我們的,或還沒選檔 →「放棄這個上傳」= `bulk/close`,成功後才可以 check。<br>• `bulk/close` 回 15 →「這個更新不是這支手機開始的(或已經過期)— 請稍後再試」。 |
| 2 | 進 U8 |
| 3 | 「節點上有一個已寫好、還沒套用的更新(<key 5>)」+「套用並重開」。apply 回 15 → 照 §3.4 最後一條(先重送 check 那一步只在 apply 回 15 之後才做);仍然不行 →「不是這支手機開始的」。 |
| 4 | 進 U10 的試用畫面 |
| 5 / 6 | 前面加「上一次更新:」;之後可以選新檔 |
| 0 + reason | 依 §4 |
| 0、沒有 reason,而這個畫面剛看過 2 / 3 / 4 | 「結果還不確定 — 1 分鐘後自動再看」。每 30 s 讀一次,最多 2 分鐘;還是一樣 →「這次更新沒有完成,目前版本沒變」 |
| 0、沒有 reason,其他情況 | 閒置 |

### 3.4 任何失敗:先讀 status(D15)

先讀 `update/status`,照 §3.3 處理。只有讀了之後還是同一個 phase、沒有新資訊時,才在 10 s 後重送同一個動詞,最多 3 次,然後顯示文字。

- **prepare 收到 E_BUSY 或 outcome unknown** → 讀 status,是 2 → 進 U8,**不再送 prepare**。
- **apply 收到 E_BUSY、逾時或回應遺失** → status 是 3 → 可以再按「套用」;是 4 / 5 / 6 → 已經生效。
- **check 逾時** → 讀 status;沒有新資訊 → 10 s 後再送(同一位擁有者 = 覆寫 pending)。
- **PUT 的結果是「其他」**:
  1. **先固定等 31 s**,沒有其他條件(中斷的 PUT 最多佔住上傳槽 30 s,F12;socket 已用 linger 0 中止,D4)。
  2. 等完之後,依 status 走:
     - 1 / 0 → U4(重送 `bulk/open`;回 15 → 回 U2;回 E_BUSY → 再讀 status;BLE 連不上 →「節點還沒回來」)→ 再 PUT。
     - 2 → U8。
  3. 等完之後的每一次失敗算一次,連續 3 次 →「傳送一直中斷 — 請靠近節點後再試」。有人搶先 PUT 或佔住上傳槽的情況,由下面的計次規則(P3 :517 原句叫使用者換密碼)涵蓋,不另外偵測(v0.3 A N1)。
- **prepare 回 15** → 讀 status:
  - 1 而且是我們的 sha → 先等(同上),再 U4 + PUT,**計次**。
  - 其他 → U4,**不計次**;U4 也回 15 → 回 U2。
- **status 是 0 + 15 或 0 + 11** → U4,保留已選的兩個檔,**計次**。
- **計次**:prepare 回 15、0 + 15、0 + 11 合起來連續 3 次 → P3 :517 原句「節點拒絕上傳檔:請重開節點;若仍失敗,可能有人在節點 Wi-Fi 上干擾,請換節點 Wi-Fi 密碼;換了仍失敗,只能重燒」。
- **apply 回 15,而且還在同一次開機** → 手上有 manifest:自動重送 check 一次,回到 3 就再給「套用」。沒有 manifest:「請重新選 manifest 檔,就能套用已寫好的新版」。

### 3.5 手機 Wi-Fi 關閉中(`bulk/open` 回 16)
這是 app 流程節點的常態(F28)。
1. 「節點給手機連的 Wi-Fi 還沒設定(或被關閉),要先設定才能傳更新檔」+「去設定手機 Wi-Fi」/「取消」。
2. 「去設定」→ 回到節點頁,捲到「設定 Wi-Fi」那一列(nodes.dart:1508-1528)。
3. 設好之後回來 → U4。這一次如果回 16 或 21,每 5 s 重試,最多 30 s(F10:AP 要先起來,防火牆檢查也要先過);pending 過期回 15 → 回 U2。
4. 取消 = 什麼都不送。

## 4. 原因 → 使用者看到的文字(依 reason 對應;15、21、23 依當時情況區分;代碼放在「技術資訊」裡)

| reason | 文字 |
|---|---|
| 1 | 節點正在試用新版,等它確認(約 5 分鐘)後再更新 |
| 2 | 節點的設定還沒存好,不能更新 — 請重開節點;仍然如此請找維修人員 |
| 3 | 這個更新檔是給別種板子的 |
| 4 | 要先裝中間版本才能更新到這版 |
| 5 | 這版需要重燒卡,不能經 App 更新 |
| 6(拒絕) | 不允許降回這個版本 |
| 8 | 節點的記憶體不夠放這個更新檔 — 請重開節點再試 |
| 11 | 更新檔內容與簽章不符 — 檔案可能不是同一份(請確認 manifest 和更新檔是一起產生的),或傳輸中被換掉;請重新選檔或重新上傳 |
| 12 | 節點有一個沒完成的網路變更 — 請等一下再試 |
| 15(U4 之前 / 沒有窗) | 這個更新不是這支手機開始的,或已超過 30 分鐘 — 請重新開始更新 |
| 15(status 0 + 15) | 上傳不完整,請重新上傳 |
| 16 | §3.5 |
| 17 | 節點的設定沒有存到最新 — 請重開節點後再試 |
| 18(只會出現 6 + 18) | 新版沒有完成試用,節點已回到原本的版本 |
| 21(phase 2 之前) | 節點現在無法寫入,請稍後再試 |
| 21(phase 2 之後) | 這次寫入失敗,舊版本的退路可能已失效,請再更新一次 |
| 22 | 上次寫入沒有完成,退路已失效,請再更新一次 |
| 23 | 手上有 manifest → 先自動重送 check;還是 23 →「新版已寫入但沒有啟用(節點重開過),請重新更新」。手上沒有 →「請重新選 manifest 檔;若節點重開過,要整個重新更新」 |
| 24 | 這台節點的軟體不能經 App 更新,請用電腦(ssh)更新或重燒卡 |
| E_BUSY(讀過 status 仍不明) | 節點正在處理另一個更新(可能是另一支擁有者手機)— 請稍後再試 |
| E_STORAGE | 節點的儲存區寫不進去,這次沒有開始 — 請重開節點後再試 |
| E_RATE(第二次) | 太快了,請稍等 10 秒再按 |
| E_UNSUPPORTED | 這台節點的軟體太舊,不能經 App 更新 |
| 其他 | 更新沒有成功 — 請再試一次;一直如此請找維修人員 |

## 5. 擁有權與契約

### 5.1 擁有權
| 資源 | 唯一寫者 | app 的角色 |
|---|---|---|
| pending、窗、bearer、上傳檔、worker、目標槽、update-last、試用 / commit | 節點 | 只送動詞、只讀 status |
| 選的兩個檔 | 操作員 | 透過唯讀的 SAF URI 讀 |
| 流程的記憶體狀態(manifest、sha、bearer、密碼、Network / callback、計數) | app 程序 | 不落地;結束時清掉 |
| 手機的 Wi-Fi 連線 | Android | 只發 request / unregister;已經連著的網路不動 |
| **Android 存下的「同意」**(app + 這個 AP,F25) | Android | **本功能留下的持久副作用**:密碼不留存;使用者可以在系統設定「忘記」這個網路來撤銷 |
| 手機上的紀錄 | — | 本功能不寫 |

### 5.2 契約
| 介面 | 寫者 → 讀者 | 格式 | 缺 / 壞 |
|---|---|---|---|
| manifest 檔 | 操作員 → app → 節點 | ≤ 64 KiB 的嚴格 CBOR map;原樣重新編碼(T1) | 不送(fail-closed);能不能信由節點判斷 |
| payload 檔 | 操作員 → Kotlin → 節點 | gzip 開頭,大小 = key 3;不解 tar | 不送;內容有錯 → 節點回 11 / 15 |
| `bulk/open` 回應 | 節點 → Rust → Kotlin | 6 個 key,型別正確;bearer 16 B;IPv4;port 1–65535 | 停下、`bulk/close` |
| `findNodeNetwork` / `joinAp` / `upload` / `cancelUpload` | Dart → Kotlin | D8;一次只跑一個 | 回 `ok200` / `other` / `no_network` / `denied`;不認得的 → `other` |
| PUT(raw socket) | Kotlin → provd | D4 | 只分 200 / 其他(D4) |
| `update/status` | 節點 → app | update-progress;key 3 / 4 / 5 可能不存在 | 「讀不到更新狀態」+ 重新整理 |

信任界線:兩個檔都不信任;BLE 擁有者 session 可信;HTTP 那一段只看 200,最終結果以 BLE 讀到的為準。

## 6. 生命週期矩陣

| 路徑 | 之後的行為 | 證明 |
|---|---|---|
| 第一次用 | 沿用目前的 Wi-Fi:不會跳對話框;走 Specifier:跳對話框,之後同一個 AP 不再問(但在 STA+STA 建不出第二介面的機型每次都會問) | T9 |
| 進頁 / app 重開 | §3.1、§3.3,只讀 | T6 |
| 正常完成 | unregister,清掉記憶體 | T8 |
| 上傳中 app 被殺 | 節點 30 s 後放掉 PUT;重開 app → status 1(是我們的,要重新選檔)→ 等待規則 → U4 | T5、T6 |
| 上傳中 app 被殺,而且正在用 Specifier | 系統應該會放掉請求,手機回到原本的 Wi-Fi ⚠️ | T9 |
| 寫入中 app 被殺 | 回來後進 U8 | T6 |
| 手機走遠、訊號很差(寫入卡住) | 35 s watchdog → 其他 → 等待規則 | T8 |
| 手機離開 AP、Wi-Fi 關掉 | `onLost` 或 I/O 錯 → 其他 → 等待規則 | T8、T11 |
| 使用者在 U6 按取消 | 中止 socket + `bulk/close`;目前版本不變 | T8、T5 |
| 上傳中 BLE 斷線 | PUT 不受影響;U7 先重新登入再 prepare(窗至少剩 60 s;超過 → 15 → 重傳) | T4、T11 |
| apply 時 BLE 斷線 | 讀 status:3 → 可以再套用;4 / 5 / 6 → 已經生效 | T7 |
| 寫好之後超過 30 分鐘才套用 | 同一次開機內:重送 check → 3 → 套用,不必重傳 | T7 |
| 上傳中節點重開 / 斷電 | `bulk/open` 回 15,或 BLE 連不上 →「節點還沒回來」→ 回 U2 | T5、T11 |
| 寫入中節點重開 / 斷電 | 0 + 22;目前版本不變 | T6、T11 |
| prepare 之後 helper 重啟 | 0、沒有 reason → §3.3 那一列 | T6 |
| 試用失敗 | 6 或 6 + 18 | T7;用 wbox |
| provd 或 helper 重啟 | PUT 失敗 → 等待 → `bulk/open`(helper 重啟會拿到新的 bearer)→ 重新 PUT;pending 沒了 → 15 → 回 U2 | T5 |
| 第二位擁有者 | 看到中性的文字;按下去回 15 →「不是這支手機開始的」;check 回 E_BUSY → 讀 status | T6 |
| 節點的手機 AP 關著 | 16 → §3.5 | T4b、T10 |
| 手機已經連著這台的 AP | 直連路由 → 不跳對話框、不切網路 | T9 |
| 手機連著同一個 SSID,但直連路由沒命中 | 走 Specifier:**TAK 斷兩次**(連上時一次、放掉時一次;F25)→ 先跳說明 | T9(f) |
| 手機連著別的 AP | 連線逾時 → Specifier | T9 |
| 8095 被佔 | 顯示文字,不開始 | T3 |
| app 在背景 | Specifier 請求失敗 → 顯示文字;PUT 可能被系統停掉 → 等待規則 | T9 |
| 電量低 | **不檢查** | — |
| app 升級 / 降級 | 沒有落地狀態 | — |
| 舊節點 / 一般 DEV image | 顯示文字 | T3、T10 |
| Android 12 / 12L | ⚠️ 還沒驗證(T9 會註明手機的版本) | T9 |
| iOS | 不在這一版 | — |

## 7. 安全

- **資產**:誰能控制節點要裝什麼 image、AP 密碼、上傳 bearer、節點能不能用。
- **秘密**(D8):
  - 密碼只在需要走 Specifier 時,才經過 Dart 一次;bearer 只出現在 `upload` 呼叫裡。
  - 兩者都不會進入 `OwnerStep.detail`、log、`result.error`、例外字串、URL、剪貼簿或任何紀錄。
  - 更新流程不 `debugPrint`。
  - Rust 用完就 zeroize;Dart / Kotlin 的字串沒辦法清零,這是既有的誠實界線。
  - Specifier 不會留下密碼(F25)。
- **明文**:只有那一條 raw socket 是明文,而且不經 proxy;全 app 仍然禁止明文。bearer 會以明文出現在 AP 上:同一個 AP 上知道密碼的人抓得到,但只能拿來 DoS(P3 :488)。payload 本身是公開的。
- **攻擊面增量**:
  - 使用者選的兩個檔:先限制大小、嚴格 CBOR、檢查 magic,不解 tar;節點給的字串一律經 `display_name` 處理並截到 64 字。
  - 一條 PUT。
  - 權限:`INTERNET`、`CHANGE_NETWORK_STATE`、`ACCESS_NETWORK_STATE`,都是 normal 權限,不需要定位。
- **逐 actor 分析**:
  - **給假檔的人**:簽章不對 → 回 11 / 24,節點什麼都沒寫;舊版本 → 被版本規則擋下;前段照抄、rootfs 是垃圾 → 第一遍就驗出來。
  - **同一個 AP 上抓到 bearer 的人**:窗開著的 900 s 內(可以延長)能搶先 PUT、以 256 KiB/s 佔住上傳槽、把百分比灌高。結果只是 DoS;連續 3 次失敗後,P3 :517 原句會叫使用者換密碼(§3.4)。
  - **ARP 冒充或假 AP**:能拿到 bearer 和公開的 image,回一個假的 200。結果只是 DoS;最終結果只信 BLE。
  - **不知道密碼的人**:可以錄下 WPA2 交握後離線猜密碼。密碼強度的缺口記在 §12。
  - **本機先佔住 8095 的程序**:status 會帶 `http_bind_failed` → 顯示文字。
  - **選到惡意檔**:有大小上限,解析面很小。
  - **擁有者本人、被入侵的 app**:沒有新增權限,只能裝已簽章的版本。
  - **我們自己的錯**:B1(明文)、targetSdk 浮動、proxy、秘密進 log → 分別由 D4、D6、D8 處理,並有 T12 / logcat 檢查。
- **Fail-secure**:解析失敗就不送;HTTP 的結果不採信;狀態只信 BLE;`trust` 只是 UI 閘門(D13)。

## 8. 測試(每一項都附負對照)

**向量來源**:T4–T7 的假節點回應,從節點真的 Go 程式擷取(F30):check → bulk/open → PUT(含提早拒絕)→ prepare → status 各列 → apply 成功 / 15 / E_BUSY / outcome unknown;回應存成 CBOR,PUT 的部分存成 TCP 層的行為。
- **擷取程式是本功能的交付物,要在寫 T4–T7 之前完成**(v0.3 A m6)。
- 它跑的是節點的 Go 測試,所以放在 Batman-p3 節點測試旁邊,依 #290 以 harness PR 先進 main;產出的 fixture 連同來源 commit 複製進 app 的 testdata。

- **T1(Rust)manifest**:
  - signrel 產生的 manifest → 接受,而且重新編碼後 bytes 完全相同。
  - 突變:非最短編碼、key 順序錯、尾端多 bytes、缺 key 5、key 4 只有 31 B、key 1 是 bstr、含 RLO、> 64 KiB → 拒絕或過濾。
  - 負對照:每拿掉一項檢查,對應的突變就會被接受。
- **T2(Rust)本機檢查**:大小不符、不是 gzip、兩個都是 manifest、statSize −1 → 不送。負對照:拿掉大小檢查 → 送出 check。
- **T3(Rust)文字**:§4 逐列比對;6 和 6 + 18 分開;21 前後兩種;`http_bind_failed`;E_UNSUPPORTED;reason 99。負對照:少一列 → FAIL。
- **T4(Rust)正常路徑**:
  - 動詞順序:`check → (op/nonce → bulk/open) → [Upload] → (op/nonce → bulk/open) → op/nonce → prepare → status… → op/nonce → apply`。
  - 掃描所有步驟文字與 Dart 端的 log 輸出,都不能出現密碼或 bearer(原字串和 hex 都要掃)。
  - check / apply 的等待 ≥ 340 s。
  - `bulk/open` 回應缺 key → 停下 + `bulk/close`。
  - 負對照:把 bearer 放進 detail → FAIL;等待只設 15 s → FAIL。
- **T4b reason 16**:顯示 §3.5;回來後先回 21 兩次再 ok → 流程繼續;30 s 後還是 16 → 顯示文字;回 15 → U2。負對照:不重試 → FAIL。
- **T5(Rust)§3.4**:
  - prepare 回 outcome unknown,而 worker 已經在跑 → 下一步是讀 status,不是 prepare(負對照:重送 prepare → FAIL)。
  - 每次 PUT 之前都有 `bulk/open`(負對照:少一次 → FAIL)。
  - PUT 結果是其他 → 固定等 31 s 才重試、才算一次;負對照:不等就重試 → 3 次立刻用完 → FAIL。
  - Specifier 網路在重試之間不放掉、不重新請求(負對照:每次重試都 requestNetwork → FAIL)。
  - prepare 15 + 我們的 phase 1 → 計次;15 + 其他 → 不計次(負對照:一律計次 → FAIL)。
  - 0 + 15 / 0 + 11 計次;連續 3 次 → P3 原句;中間成功一次就歸零。
  - 取消 → 送出 `bulk/close`。
  - 節點重開(BLE 連不上)→「節點還沒回來」→ U2。
- **T6(Rust)§3.3 每一列**:
  - 別人的 3,apply 回 15 →「不是這支手機開始的」。
  - 1 但不是我們的 → 先 `bulk/close` 才 check。
  - 剛看過 2,讀到 0 + 沒有 reason →「結果還不確定」→ 2 分鐘 →「沒有完成」。
  - 5 / 6 →「上一次更新:」。
  - 每一臂的負對照 = v0.2 的規則。
- **T7(Rust)apply 之後**:
  - 4 / 5 / 6 / 6 + 18 / 時間到。
  - 回應遺失 + 3 → 可以再套用。
  - worker 結束 31 分鐘後 apply → 15 → 自動 check → 3 → apply(負對照:回 U1 重傳 → FAIL)。
  - 試用退回時第二次斷線 → 繼續重試。
- **T8(Android instrumented,在 S20)raw PUT**:測試裡開一個本機 ServerSocket 當假節點,行為照 provd/http.go 寫,包括「讀 body 之前就回 409 然後關掉」。
  - 位元組層級:請求行加 4 個 header 完全一致,沒有 `Transfer-Encoding`。
  - 200 MB 的檔:heap 增量 < 16 MB。
  - 讀 body 前就 409、≥ 1 MB 的 PUT → 結果 = 其他(不依賴狀態碼)。
  - 假節點停止讀取 → ≤ 40 s 內回報「其他」(watchdog)。
  - 取消 / watchdog → 假節點收到 RST(linger 0),不是 FIN 之後還繼續收資料。
  - **A N1 負對照臂**:app 中止 socket 之後,假節點繼續讀 → app 不得顯示任何「有人在上傳」的文字,而且等滿 31 s 才重試(v0.3 的偵測版本 → FAIL)。
  - 直連路徑:第一次連線逾時、第二次成功 → 不走 Specifier(負對照:逾時一次就走 Specifier → FAIL)。
  - **logcat** 抓整段,grep 密碼和 bearer(含 hex)→ 0 筆。
  - 負對照:改成 chunked → 假節點回 400;改成 `readBytes()` → heap 檢查 FAIL;拿掉 watchdog → 卡超過 60 s → FAIL;依 409 分支寫(v0.2 的寫法)→ FAIL。
- **T9(實機 S20,要先有 bench 節點,§9)D5**:
  - (a) 已經連著節點 AP → 沒有對話框,`activeNetwork` 不變。
  - (b) 沒連 → 先出說明,再出對話框 → PUT。
  - (c) 使用者拒絕 → 顯示文字。
  - (d) 手機 Wi-Fi 關 → 「請確認 Wi-Fi 已開啟」。
  - (e) 第二次 → 通常不再問;STA+STA 機型可能還是會問,兩種都接受。
  - (f) **強制停用直連路徑,手機連著同一個 SSID → 走 Specifier,記錄斷線次數(預期 2 次)**。
  - (g) 連著別的 AP → 逾時 → 走 Specifier。
  - (h) app 在 Specifier 期間被殺 → 手機回到原本的 Wi-Fi ⚠️。
  - 之後看系統設定:沒有留下已存網路(F25)。
  - 註明 Android 版本。
  - 負對照:(a) 改成一律走 Specifier → 跳對話框、切網路。
- **T10(實機 04 現況,不寫槽)**:04 是一般 DEV image、trust none(F29)→ 顯示 24 的文字;`bootinfo` 前後一樣。**這是今天唯一能在實機做的更新測試。**
- **T11(實機 04 bench build,破壞性)— 完成條件**:
  - 正常路徑 U1–U10 → 5、`info` key 4 = 新版。
  - 負路徑:上傳中關手機 Wi-Fi、上傳中重開節點、寫入中重開節點(→ 22)、apply 回應前斷 BLE、wbox 版本(→ 6)、16 → 設 AP → 繼續(同時量 M7 的時間差)、U6 取消。
  - 動手前先列出副作用和還原方式並問使用者(§9)。
- **T12(instrumented,在 S20)明文政策**:
  - raw socket PUT 對本機假節點 → 成功。
  - 負對照:同一個 app 用 `HttpURLConnection` 對同一個 `http://` → 出現「CLEARTEXT communication … not permitted」(同時證明全 app 沒有放寬)。
  - ⚠️ 如果 localhost 不受這個政策管(§10-15),就把假節點改綁到手機的 Wi-Fi IP。
  - **至少跑一次 release build**(field 和 dev 兩個 flavor),在 S20 上做 T8 / T12 / T9(b):確認 main manifest 真的有 `INTERNET`(debug build 會把缺少這件事蓋過去)。

## 9. 要使用者決定的點(只剩這兩個)

1. **把 04(或另一台)換成 bench build**(`build-board.sh --bench`,信任 T):T9、T11 的實機部分,以及 §3.5 的實機測試,都要先有它。這一步有破壞性(要重燒或 ssh sysupgrade,04 的狀態會改變)。要不要做、什麼時候做、用哪個方法?動手前我會先列出副作用和還原方式。
2. **在 04 上用 key 20 設一組手機 AP**(04 的 AP 目前是關的,F28):這會改變 04 的設定,AP 也會開始發射。還原方式 = 再設回去,或保持現狀。

## 10. 待查(⚠️,審查前要補證據)

1. ✅ 已解(F25):單 STA 手機上 Specifier 會斷兩次;同一個 SSID 也一樣。剩下:OEM ROM 可能不同 → T9。
2. ⚠️ `INTERNET` 權限要引用 `android.permission.INTERNET` 的文件;`ACCESS_NETWORK_STATE` 已確認需要(ConnectivityManager 文件,審查 B m3)。
3. ✅ 已解(F27):AP 是 psk2。剩下:02 和出貨 image 的預設是否也一樣。
4. ⚠️ 每一台的 `br-ahwlan` 子網是否不同(相同的話,靠連線逾時退到 Specifier)。
5. ⚠️ ≥ 256 KiB/s、和 BLE 同時用 → 在 T11 量。
6. ⚠️ SAF `statSize` 的可靠性。
7. ⚠️ 怎麼判斷有 TAK:提案是 `tenants` 裡有 `opentakserver` 就算(halow-status:177;04 的實例)。
8. ⚠️ cbor.rs 和 signrel 能不能互通 → T1。
9. ✅ 已解(F29):04 是 trust none。
10. ✅ 已解(F25):密碼不留存,「同意」會留存(§5.1)。
11. ✅ 已解(v0.3 審查 B 的 AOSP 證據):raw socket 不受明文政策約束。
    - 政策只在 HTTP handler 的 URL 過濾器檢查:okhttp `HttpHandler.java:122-126`(`CleartextURLFilter`)。
    - socket 層不檢查:`RealConnection.java:101-108` 只看 ConnectionSpec,建連線用的是 `getSocketFactory().createSocket()`。
    - `NetworkSecurityPolicy.isCleartextTrafficPermitted()` 文件原文:「there's no expectation that the Socket API will honor this flag」。
    - T12 仍在實機確認。
12. ⚠️ `Settings.Panel.ACTION_WIFI` 要什麼權限。
13. ⚠️ WifiNetworkSpecifier 帶起的 local-only 網路,在 targetSdk 37 時是否不受 local network protection 限制(在 D6 之後才會碰到)。
14. ⚠️ 螢幕關掉之後,light doze 是否會限制網路。
15. ⚠️ T12 的 localhost:`CleartextURLFilter` 依主機名稱判斷(HttpHandler.java:126),`127.0.0.1` 有沒有例外沒查;備案是改綁手機的 Wi-Fi IP(v0.3 B m3)。
16. ⚠️ 手機的 TCP 送出緩衝大小沒量過(linger 0 讓它無關,v0.3 B m2);直連路徑第一次連線要多久 → T9(a) 記錄(v0.3 B m4)。

## 11. 實作(審過再做)

- Rust `batman-proto/src/swupd.rs`(新檔):manifest 解析、流程狀態機(sans-IO)、§3.3 / §3.4、§4。bridge `owner.rs` 加 `St::SwUpdate` 和 `request_sw_*`。
- Kotlin `SwUpload.kt`(新檔):SAF、D5、D4(raw socket、watchdog、linger 0 中止、取消);PUT 迴圈和 `requestNetwork` callback 都跑在背景 thread;MethodChannel 加 `pickUpdateFiles`、`findNodeNetwork`、`joinAp`、`upload`、`cancelUpload`。
- Batman-p3(harness PR,#290):向量擷取程式 + fixture(§8),先於 T4–T7。
- Dart:一個「軟體更新」按鈕和一頁進度畫面;更新流程不 `debugPrint`。
- `build.gradle.kts`:`targetSdk = 36` 寫死 + 註解(沒有檢查 task)。
- Manifest:`INTERNET`、`CHANGE_NETWORK_STATE`、`ACCESS_NETWORK_STATE`。**不加** `networkSecurityConfig` / `usesCleartextTraffic`。
- 不加任何 HTTP 套件。

## 12. Checklist(不在本設計做;寫進 #254)

1. (v0.4 移出:向量擷取程式改成本功能的交付物,§8、§11。)
2. 「設定 Wi-Fi」那一列沒有密碼強度提示(P3 :511 建議 ≥ 20 個隨機字元);弱密碼會讓離線猜密碼變容易(審查 B 的 actor 分析)。
3. 下載、背景下載、R 指紋(#255)。
4. iOS。
5. foreground service(如果現場常因為切到背景而要重傳)。
6. 要升到 targetSdk 37 時,處理 `ACCESS_LOCAL_NETWORK`(NEARBY_DEVICES 群組)。
7. 既有的 `nodes.dart` 對其他流程也會把 detail 和例外 `debugPrint` 出來(F31)→ 全 app 一併處理(本設計只管更新流程)。

## 附錄 A. v0.2 審查 A(APPROVE-WITH-CHANGES:1 BLOCKER / 8 MAJOR / 10 MINOR)→ 改在哪

| 項目 | 處理(已對照節點 file:line 查證) | 位置 |
|---|---|---|
| B1 明文被擋 | raw socket + 手寫 HTTP/1.1;全 app 不放寬;T12 + 負對照 | F23、D4、§7、T12 |
| M1 等待時間、E_BUSY / outcome unknown | 等 ≥ 340 s;一律先讀 status(session.go:603-624、update.go:41-42) | D14、D15、§3.4、T5 |
| M2 0 卻沒有 reason | §3.3 加一列(updwork.go:882-883、:917) | §3.3、T6 |
| M3 超過 30 分鐘才套用 | 重送 check → 3 → 套用(updwork.go:286-288、:696-709) | §3.3、§3.4、§4、T7 |
| M4 status 不分擁有者 | 中性文字;15 →「不是這支手機開始的」(updwork.go:696-699;bulk.go:109-112) | §3.3、§4、§6、T6 |
| M5 409 分類 | 每次 PUT 前都送 `bulk/open`;不解析 HTTP 結果(審查 B M1 更進一步:只分 200 / 其他) | D4、U4、§3.4 |
| M6 prepare 15 的三種情況;0 + 21 | 先讀 status 再分流;只對真正的上傳失敗計次;21 依前後分開 | §3.4、§4、T5 |
| M7 設好 AP 之後回 16 / 21 | 每 5 s 重試,最多 30 s(bulk.go:21-23) | §3.5、T4b |
| M8 假節點是自己寫的 | 從真的 Go 程式擷取;T11 改成完成條件 | §8、§12-1 |
| m1 不存在 0 + 18;arm 10–18 不 disarm | 改正(updwork.go:733-742、:900-910) | F17、F18、§4 |
| m2 依 reason 對應 | §4 | §4 |
| m3 再重開一次;5 / 6 會一直留著 | U10;「上一次更新:」 | U10、§3.3 |
| m4 `bulk/close` 不刪 pending | U3 的文字 | U3 |
| m5 default route;RST vs 逾時 | 只看直連路由;由 PUT 的連線結果區分 | D5 |
| m6 `http_bind_failed` | 進頁時讀 | §3.1 |
| m7 PUT 之後只剩 60 s 窗 | v0.3 曾在 BLE 重連之後先送 `bulk/open`;v0.4 刪掉,接受這條界線(附錄 C) | U7、§6 |
| m8 選錯但大小相同的檔 | 11 的文字;不做本機 SHA 比對 | D2、§4 |
| m9 E_RATE | 第二次就顯示文字 | U2 |
| m10 1 但不是我們的 | 先 `bulk/close` | §3.3 |

## 附錄 B. v0.2 審查 B(REJECT:1 BLOCKER / 5 MAJOR / 14 MINOR)→ 改在哪

| 項目 | 處理(已查證) | 位置 |
|---|---|---|
| B1 明文被擋 | raw socket(`network.socketFactory`)+ 手寫 PUT;全 app 不放寬;T12 + 負對照(flutter FlutterExtension.kt:34 確認 targetSdk 36) | D4、§7、T12 |
| M1 提早拒絕時看不到 409 / 403 / 400 | PUT 結果只分 200 / 其他;每次 PUT 前都送 `bulk/open`;失敗後經 BLE 讀 status 決定(Go server.go:1770、:1784-1794;http.go:509-535 已查) | F11、D4、§3.4、T8、T5 |
| M2 中斷的 PUT 佔住上傳槽 30 s | 中斷之後等 31 s 才重試(http.go:46、:540 已查);v0.3 另外加的「百分比停住」與「有人正在上傳」偵測,v0.4 已刪(附錄 C) | F12、§3.4、T5 |
| M3 卡住偵測、取消 | 35 s watchdog;U6 取消 = 關 socket + `bulk/close`;`onLost` → 關 socket | D4、U6、§6、T8 |
| M4 targetSdk 跟著浮動 | 固定字面值 36(v0.4 刪掉建置檢查);升 37 的事進 checklist | F24、D6、§12-6 |
| M5 Specifier 會斷掉目前的 Wi-Fi | 直連路徑為主、Specifier 為後備;走後備前先說明 TAK 會中斷;§6 加一列;T9(f) | F25、D5、U5、§6、T9 |
| m1 proxy | raw socket 不經 proxy | F26、D4 |
| m2 拿掉 TCP 探測 | 拿掉;PUT 的連線本身就是探測(連線逾時 → Specifier;被拒 → 重試),仍滿足審查 A m5 | D5 |
| m3 `getAllNetworks` 已棄用;`ACCESS_NETWORK_STATE` | 改用 `registerNetworkCallback` | D5、§10-2 |
| m4 「同意」會存檔 | 列為持久副作用;密碼不留存 | F25、§5.1、§10-10 |
| m5 免再問的例外 | T9(e) 兩種結果都接受;§6 | §6、T9 |
| m6 只有前景能發請求 | 背景時失敗 → 顯示文字 | D5、§6 |
| m7 手機 Wi-Fi 關著 | 不另外偵測;逾時的文字 + 開 Wi-Fi 面板 | U5、§10-12 |
| m8 manifest 讀取上限 | ≤ 64 KiB;payload 只讀 2 bytes | D1、U1、T1 |
| m9 `http_bind_failed` | 進頁時讀 | §3.1 |
| m10 秘密經過 Dart / log | 分三個呼叫、密碼只在需要時傳;不 `debugPrint`;`result.error` 不帶參數;用 logcat grep 驗 | D8、§7、T4、T8、§12-7 |
| m11 螢幕關掉 | U3 加「不要關螢幕」;doze 列為 ⚠️ | D9、U3、§10-14 |
| m12 `trust` 只是 UI 閘門 | §7 / D13 寫明 | D13、§7 |
| m13 測試環境 | T8 改成 instrumented;release build 至少跑一次 | T8、T12 |
| m14 Android 12 / 12L | 列為 ⚠️,T9 註明版本 | §6、T9 |
| 生命週期:Specifier 期間 app 被殺 | ⚠️,T9(h) | §6、T9 |
| 生命週期:上傳中節點重開 | `bulk/open` 回 15 或連不上 →「節點還沒回來」→ U2 | §3.4、§6、T5 |

## 附錄 C. v0.3 審查(A:APPROVE-WITH-CHANGES 0 BLOCKER / 1 MAJOR / 6 MINOR;B:APPROVE-WITH-CHANGES 0 / 0 / 5 + 可砍項 a–d)→ v0.4 的修改

| 項目 | 修改 | 位置 |
|---|---|---|
| A N1(= B m1、可砍項 a、b)「百分比停住」會提早重試;「有人正在上傳」會誤報 | **刪除**:中斷後固定等 31 s;刪掉偵測、§6 那一列和 T5 那一臂;搶先 PUT 由 P3 :517 計次句涵蓋;T8 加負對照臂(假節點在 app 中止後繼續讀 → 不得出現該文字) | §3.4、§6、§7、T5、T8 |
| B m2 中止時送 RST | 中止 = `setSoLinger(true, 0)` + close(watchdog、取消、`onLost`);T8 斷言收到 RST | D4、§6、T8 |
| B 可砍項 c targetSdk 建置檢查 | **刪除** task 和 T13;保留字面值 36 + 註解 | D6、§11、T12 |
| B 可砍項 d T12 負對照 2 | **刪除**;負對照 1 同時證明沒有放寬 | T12 |
| A m3 U7 收到 200 後的 `bulk/open` | **刪除**;界線(窗至少剩 60 s)寫進 U7 / §6 | U7、§6、附錄 A m7 |
| A m6 擷取程式不能延後 | 改成本功能的交付物,在 T4–T7 之前;放在 Batman-p3 節點測試旁,依 #290 走 harness PR | §8、§11、§12-1 |
| A m1 每次重試都重新請求 Specifier | 網路保留到上傳階段結束;T5 臂 | D5、T5 |
| A m2 / B m4 直連逾時 3 s 就走 Specifier | 先重試一次(3 s × 2);T8 臂;第一次連線時間 → T9(a) | D5、T8、§10-16 |
| A m4 §3.3 第 3 列多送一次 check | 移到 apply 回 15 的那一條 | §3.3 |
| A m5 U2 最多 340 s 沒有說明 | 「節點正在檢查,最多約 6 分鐘,這段時間不能取消」 | U2 |
| B m5 UI thread | PUT 迴圈和 `requestNetwork` callback 放背景 thread | D4、§11 |
| B m3 T12 的 localhost | §10-15 | §10 |
| B §1 B1 的 AOSP 證據 | §10-11 → ✅ | §10-11 |
| B §4 其他核對(SignAllowList 前綴、沒有生物辨識、inflight 不判閒置) | 無需修改 | — |
