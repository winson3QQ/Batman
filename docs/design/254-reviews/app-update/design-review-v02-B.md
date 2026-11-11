# 254-app-update.md v0.2 — 設計審查 B(Android 網路與安全)

審查者 B,2026-11-12。範圍:整份 v0.2(未修改原檔)。證據來源:Batman-p3 @ d9b1428、Batman-app @ ff1805a(唯讀);Android 開發者文件與 AOSP 原始碼(2026-11-12 從 WSL 以 curl 抓取,存在 WSL `/tmp/revB/`);Go 1.26.4 標準庫原始碼(provd 的 go.mod:3 = go 1.26.4)。沒有碰節點或手機。

**結論:REJECT(v0.2 照寫的話,PUT 在任何 build 都送不出去:B1)。** 架構本身我支持:BLE 跑所有動詞、只有一個 PUT、Kotlin 串流、D4-1 優先。修完 B1、M1–M5 後請整份重審。

---

## BLOCKER

### B1 明文 HTTP 被 Android 的網路安全政策擋掉:每個 build 的 PUT 都會失敗
- **情境**:D3 用 `Network.openConnection(URL("http://<ip>:8095/..."))`。app 的 targetSdk 跟著 Flutter 走,目前是 36;main manifest 沒有 `networkSecurityConfig`,也沒有 `usesCleartextTraffic`。
- **證據**:
  - `app/android/app/build.gradle.kts:25` `targetSdk = flutter.targetSdkVersion`;`/home/yello/flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:34` `val targetSdkVersion: Int = 36`。
  - `AndroidManifest.xml:11-15` 的 `<application>` 沒有這兩個屬性。
  - NSC 文件(privacy-and-security/security-config)原文:"Starting with Android 9 (API level 28), cleartext support is disabled by default."
  - `NetworkSecurityPolicy.isCleartextTrafficPermitted()` 文件:不允許時,「the platform's components (e.g. HTTP and FTP stacks…) will refuse」。
  - `<domain>` 只能比對完整主機名稱或子網域,不能寫 IP 範圍。節點 IP 每台不同(04 = 10.41.80.13、02 = 10.41.44.7),沒辦法逐一列出。
- **為什麼測試抓不到**:T8 在 JVM 上跑 `HttpURLConnection`,JVM 沒有 NSC,所以 T8 會綠燈,產品卻是壞的。debug / profile build 也一樣會被擋,因為 NSC 跟 INTERNET 權限無關。
- **修法**(二選一,寫進 D3 與 §7):
  - (a) 加 `res/xml/network_security_config.xml`,內容是 `<base-config cleartextTrafficPermitted="true">`。§7 要明寫:整個程序都允許明文;app 沒有其他 HTTP 流量;bearer 經明文送出本來就是 P3 :488 接受的誠實界線。
  - (b) 用 `network.socketFactory` 開 raw socket,自己寫 PUT。NSC 只約束 HTTP 堆疊,這條路也順便解決 m1 的 proxy 問題、M1 的回應讀取、M3 的寫入逾時。
  - 我傾向 (a) 加 m1 加 M1 的「只看 200」:改動最少。
- **測試**:在 S20 上做 instrumented 測試,對手機本機的 loopback HTTP 伺服器 PUT。負對照:拿掉 config → `UnknownServiceException`("CLEARTEXT communication … not permitted")→ FAIL。

## MAJOR

### M1 PUT 被提早拒絕時,串流中的 client 看不到 409 / 403 / 400:§3.4 的分支實際上走不到
- **情境**:provd 在讀 body **之前**就回錯誤:409(窗沒開、worker 在跑、已有 PUT、窗剩不夠)、403(bearer 錯)、400(Content-Length 不對)。見 `provd/http.go:510-535`。
- **Go 那一側**:handler 沒讀 body 就返回,而剩下的 body 超過 256 KiB(`net/http/server.go:1103-1112`、`:1407`),伺服器就送 Connection: close。接著 `closeWriteAndWait` 只等 500 ms(`server.go:1770`、`:1784-1810`)。Go 原始碼自己的註解寫著:「If client is still writing to the connection, this will cause the write to fail with ECONNRESET … causing our final response to be truncated away too.」
- **Android 那一側**:`HttpURLConnection` 在固定長度模式下,要把 126 MB 全部寫完才讀回應,所以拿到的是寫入 IOException,看不到狀態碼。
- **後果**:§3.4 的「409 窗剩不夠 → 先延長」、「403 → 重開窗一次」、「其他 409 → 讀 status」實際上都會變成「中斷」,算進 3 次,最後顯示「請靠近節點」這句錯的話。§6「provd / helper 重啟 → 403」那一列也一樣。
- **修法(拿掉機制)**:
  - PUT 結果只分兩類:200,或其他(含 io)。
  - **每一次 PUT 之前**(第一次也算)都先重送 `bulk/open`。它是冪等的:同一位擁有者 = 延長同一個窗、回同一個 bearer(`node/bulk.go:83-95`);helper 重啟過則回新的 bearer。這樣「窗剩不夠」與「bearer 換了」兩個分支都不必存在。
  - 失敗後改經 BLE 判斷:`bulk/open` 回 15 → 回 U2;回 E_BUSY → 讀 `update/status`;回 ok → 照 M2 的退讓再 PUT。
  - §3.4 與 T5 照這個改寫。
- **測試(T8 改成實機)**:假節點在讀 body 前就回 409,對象是 ≥ 1 MB 的 PUT。斷言 app 不依賴狀態碼,而是去重送 `bulk/open`。負對照:照 v0.2 依 409 分支寫 → app 走進 io 計次 → FAIL。

### M2 Wi-Fi 閃斷後,節點上舊的 PUT 會佔住唯一的上傳槽最多 30 秒;立刻重試全部失敗
- **情境**:手機 Wi-Fi 掉了又回來,app 依 §3.4「從頭再 PUT,最多 3 次」(加上 10 秒內每秒重試)立刻重送。
- **節點那一側**:舊連線沒收到 FIN / RST,`s.http.putting` 一直是 true(`http.go:539-545`)。要等 `SetReadDeadline(30 s)` 讀逾時(`http.go:571-572`、`uploadRateWindow`)才放掉。
- **後果**:這段時間的新 PUT 都是 409「an upload is in progress」,依 M1 在 client 端又是 io,3 次機會在幾秒內就用完。
- **攻擊面也一樣**:AP 上抓到 bearer 的人以剛好 256 KiB/s 佔住這個槽,使用者看到的卻是「請靠近節點」。
- **修法**:
  - PUT 中斷後至少等 31 秒,或等到經 BLE 讀的 `update/status` phase 1 百分比停止前進,才重送;只有在這之後失敗才算一次。
  - 我們沒在傳、百分比卻還在動 →「有人正在對節點上傳,請換節點 Wi-Fi 密碼」(P3 :517 的同一套誠實界線)。
- **測試**:假節點讓 `putting` 保持 30 秒。斷言 app 等過之後才算一次失敗。負對照:不等就重試 → 3 次立刻用完 → FAIL。

### M3 上傳中沒有卡住偵測,也沒有取消鍵:使用者被困在「不要離開」的畫面
- **情境**:手機走遠但還連著 AP(訊號很差),TCP 寫入被阻塞。
- **證據**:
  - `HttpURLConnection` 沒有寫入逾時:`setReadTimeout` 只管讀,`setConnectTimeout` 只管連線。
  - 節點 30 秒後就切斷了(`http.go:567-585`),但它送的 RST 可能到不了手機。
  - 手機端要等 TCP 重傳放棄;Linux `tcp_retries2` 預設大約 15 分鐘。⚠️ 這是一般知識,本次沒有在 Android 上量。
  - U6 的失敗欄只寫「見 §3.4」,沒有取消鍵;但 D6 明說寫入開始(prepare)之前都可以取消。
- **修法**:
  - Kotlin 加 watchdog:已寫出的 bytes 35 秒沒前進 → `disconnect()`,算一次中斷(並套用 M2)。
  - U6 加「取消」= `disconnect()` + `bulk/close`。
  - Specifier 網路的 `onLost` 也直接 `disconnect()`。
- **測試**:假節點停止讀取(不關連線)。斷言 ≤ 40 秒回報 io。負對照:沒有 watchdog → 卡住超過 60 秒 → FAIL。

### M4 targetSdk 跟著 Flutter 浮動:升到 37 之後,沒有 `ACCESS_LOCAL_NETWORK` 就連不到節點
- **證據**:
  - compileSdk 已經是 37(`build.gradle.kts:9`);targetSdk = `flutter.targetSdkVersion`(目前 36)。
  - Local network permission 文件(privacy-and-security/local-network-permission)原文:「Starting in Android 17 (API level 37), local network protections are enforced for apps targeting Android 17 or higher」。對外的 TCP 連線(Making an outgoing TCP connection → yes)會被擋,而且「apply to all networking APIs … OkHttp」。targetSdk < 37 時,有 INTERNET 就隱含授予。
- **情境**:哪天 `flutter upgrade` 把預設 targetSdk 改成 37,PUT 會靜悄悄地失敗,沒有任何程式碼改動。
- **修法**(二選一,並加一個會失敗的檢查,例如建置後斷言 merged manifest 的 targetSdk ≤ 36 或已宣告這個權限):
  - (a) 在 `build.gradle.kts` 把 targetSdk 寫死成 36,加註說明原因;
  - (b) 本功能就宣告並在執行時要求 `ACCESS_LOCAL_NETWORK`。它和 BLUETOOTH_* 同屬 NEARBY_DEVICES 群組,文件說已授予過同群組權限的使用者不會再被問。
- ⚠️ 未查到:WifiNetworkSpecifier 帶起的 local-only 網路是否豁免。

### M5 單 STA 手機的 Specifier 會斷掉手機現在的 Wi-Fi(包括同一個 SSID 的已存網路),放掉後還會再斷一次
- **證據**(AOSP `packages/modules/Wifi` main 的 `service/java/com/android/server/wifi/WifiNetworkFactory.java`):
  - 「Already connected to the same network」這條捷徑,只適用於先前同樣經 Specifier 連上的網路(約 :1546-1556)。
  - 其他情況一律「Disconnect from the current network before issuing a new connect request」,而且在主 STA 上會停掉 auto-join(約 :1559-1566)。
  - 放掉請求時 `disconnectAndRemoveNetworkFromWifiConfigManager` 會再斷一次(:1098-1113)。
  - 只有在 `config_wifiMultiStaLocalOnlyConcurrencyEnabled` 而且建得出第二個 STA 介面時,才走 STA+STA。建不出來時連「記住同意」都會被撤回,每次都跳對話框(:915-927)。
- **現場**:手機平常就連著自己節點的 AP 跑 TAK(F24)。只要 D4-1 沒命中,TAK 就會斷,而且斷兩次。v0.2 的 §6「手機已連著這台的 AP → 不跳對話框、不切網路」只在 D4-1 命中時成立。
- **修法**:
  - D4-1 定為主要路徑,Specifier 只當後備。
  - U3 / U5 的文字要明說:「手機會暫時離開目前的 Wi-Fi(TAK 會中斷),傳完自動回來」。
  - §6 補一列:「已連著同 SSID 但 D4-1 沒命中」= 斷線兩次。
  - 這也算 §10-1 的文件答案;T9 加 (f):強制停用 D4-1、手機連著同一個 SSID → 觀察到兩次斷線(記錄行為,S20 實測)。
  - §9-3 請使用者決定時附上這個事實。

## MINOR

1. **m1 Proxy**:AOSP `packages/modules/Connectivity/framework/src/android/net/Network.java` 的 `openConnection(URL)` 會套 `cm.getProxyForNetwork(this)`,包括全域 / PAC / MDM proxy。有 proxy 時,bearer 和 payload 會送到 proxy。修法:`openConnection(url, Proxy.NO_PROXY)`。
2. **m2 拿掉 D4-1 的 TCP 探測**:PUT 本身就是探測。連線逾時 3 秒 → 換 Specifier;被拒 → 照 F12 每秒重試。探測連線會佔掉 provd 8 條連線上限中的一條,最多 5 秒(`http.go:35` `httpMaxConns`、`:339` `ReadHeaderTimeout`)。少一個機制。
3. **m3 列出網路的 API**:`getAllNetworks()` 在 API 31 已棄用(而 minSdk = 31),要改用 `registerNetworkCallback`(TRANSPORT_WIFI)。`getLinkProperties`、`getActiveNetwork` 都需要 `ACCESS_NETWORK_STATE`(ConnectivityManager 文件)。這解了 §10-2 的後半;前半(INTERNET)請改成引用 `android.permission.INTERNET` 文件。
4. **m4 §10-10 已有答案**:Specifier 連上的網路標成 `ephemeral` + `fromWifiNetworkSpecifier`,放掉時從 WifiConfigManager 移除(`WifiNetworkFactory.java:1111-1113`、`:1175-1179`)→ 密碼不會留成「已儲存網路」。但「同意」(app + SSID / BSSID / 安全類型)會落地保存(`saveToStore`,:1945),這是本功能造成的持久副作用,要列進 §5.1。OEM ROM 可能不同 → T9 看一次系統設定。
5. **m5 免再問的條件**:只設 SSID、沒設 BSSID = 「single network」,可以跳過對話框(:1783-1795、:1993-1997),D4 的說法對。但要加上 M5 的例外:STA+STA 機型建不出第二個介面時每次都會問。T9(e) 的期望要容許這種情況。
6. **m6 只有前景 app 能發 Specifier 請求**(:810-817):app 在背景時請求會失敗 → 走 `onUnavailable` 的文字即可,不必加機制。
7. **m7 手機 Wi-Fi 關著**:v0.2 沒定怎麼偵測。app 不能代開(P3 §3.11-1 要帶使用者去系統設定)。建議:不偵測,60 秒逾時的文字改成「請確認手機 Wi-Fi 已開啟」+ 開系統的 Wi-Fi 面板。⚠️ `Settings.Panel.ACTION_WIFI` 與 `isWifiEnabled` 需要的權限本次沒有查文件。
8. **m8 manifest 讀取上限**:「依內容分辨」代表 app 會讀使用者選的任意檔。解 CBOR 前先限制大小,上限用 BLE 請求的上限(重組後約 64 KiB,`provd/session.go:94-98`);payload 只讀開頭 2 bytes。避免選到大檔時把記憶體吃光。
9. **m9 `http_bind_failed` 沒處理**:status key 15 會帶這個值(`node/status.go:230-232`),P3 §3.8.1 要求 app 顯示。U4 之前檢查,顯示「節點的上傳埠被占用,請重開節點」。
10. **m10 秘密經過 Dart 與 log**:
    - `upload` 的 MethodChannel 在 D4-1 路徑也帶著 AP 密碼 → 只在需要走 Specifier 時才傳。
    - 現有 `nodes.dart:26` 用 `debugPrint` 把每一個 `st.detail`(:242、:289、:295)和例外 `$e`(:311)都印出來,release build 也會進 logcat。
    - T4 只掃 detail 不夠:Kotlin 的 `result.error` 不得帶參數;T8 / T9 要在實機上抓 `logcat`,grep bearer、密碼和它們的 hex。
11. **m11 螢幕關掉**:`FLAG_KEEP_SCREEN_ON` 擋不了按電源鍵。⚠️ 螢幕關掉後 light doze 可能限制網路(一般知識,未驗)。依使用者 §9-4 可以接受,但 U3 的文字要加「不要關螢幕」。
12. **m12 field 的開放條件(§9-2)只是 UI 閘門**:真正的把關是節點驗簽。`trust` 只是根鑰匙指紋的前 8 bytes(64 bit)→ 只用來決定顯示,不當作安全邊界;§7 要明寫這點。
13. **m13 測試環境**:
    - T8 在 JVM 上測不到 NSC、proxy 與 Android 的 okhttp 行為 → header / 串流 / NSC / M1–M3 的測試要搬到實機 instrumented。
    - INTERNET 權限只在 debug / profile 的 manifest 裡(已驗證)→ debug build 會蓋掉「main 少 INTERNET」這個錯。T9 / T11 至少要跑一次 release build(field 與 dev 兩個 flavor)。
14. **m14 Android 12 / 12L**:minSdk 31 包含 Android 12,但 Specifier 在 12 上的行為(包括是否要定位)本次沒有驗證 → T9 註明測的版本,或列為 ⚠️。

---

## 逐 actor(B 的結論)

| Actor | 能做什麼 | 結果 | 設計需要改的 |
|---|---|---|---|
| 同 AP 上知道 AP 密碼的人(被動抓明文 bearer) | 整個窗期間(900 秒,可延長;重送 `bulk/open` 都回**同一個** bearer,`bulk.go:83-91`)可以:在我們收到 200 到 BLE prepare 之間塞垃圾 PUT(`O_TRUNC`);以剛好 256 KiB/s 佔住上傳槽;灌高 phase 1 的百分比。沒有 GET,讀不到任何東西 | 只造成 DoS(節點驗簽、第一遍驗完才動槽) | M2:偵測「不是我們在傳」並給對的文字 |
| 同上,主動 ARP 冒充或假 AP | 拿到 bearer 和 payload,回假的 200 | DoS;結果只信 BLE | 無 |
| 不知道密碼的人 | 錄下 WPA2 四向交握後離線猜密碼 | 猜中就變成上一列 | §3.5 的密碼強度缺口(已記 checklist)讓這件事更容易 |
| 本機程序先佔住 8095 | 收到 bearer 和 payload | DoS | m9 |
| 使用者選到惡意檔 | 讓 Rust 解 CBOR、讓 Kotlin 讀檔 | 解析面小 | m8 |
| 被入侵的手機 / app | 擁有者能做的 owner-op 都能做 | 沒有新增權限(只能裝已簽的版本) | 無 |
| 我們自己的錯 | 秘密進 log;明文被擋;targetSdk 浮動;proxy | — | m10、B1、M4、m1 |

## 生命週期(B 補的)
- **app 在 Specifier 連線中被殺**:系統應該會在程序死亡時放掉請求,手機回到原來的 Wi-Fi。⚠️ 本次沒有查 ConnectivityService 的 binder-death 原始碼 → T9 實測。
- **上傳中節點重開**:照 v0.2 寫法會先燒掉 3 次 PUT 重試,而且顯示錯的文字。照 M1 改成「失敗就經 BLE 重送 `bulk/open`」之後,會拿到 15 或連不上 BLE → 顯示「節點還沒回來」→ 回 U2。
- **手機離開 AP**:要套 M2 的退讓和 M3 的 watchdog。
- **第二位擁有者**:v0.2 的處理正確(E_BUSY,`node/update.go:280-288`)。

## 已核對、與原文相符的事實
F1(`http.go:508-564`)、F10(`bulk.go:37-97`)、F11(`http.go:509-585`)、F12(`server.go:21` PollEvery 4 s)、F20(`server.go:30-31` 300 s、2 槽)、F21(manifest :3-8、`build.gradle.kts:24` minSdk 31)、D4 的 `CHANGE_NETWORK_STATE`(requestNetwork 文件)、NEARBY_WIFI_DEVICES 的 API 清單不含 requestNetwork(wifi-permissions 文件)、`bindProcessToNetwork` 文件建議改用個別綁定。

**Verdict: REJECT**(B1 一個、M1–M5 五個未解;架構方向同意,修完後整份重審)。
