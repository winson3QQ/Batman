# 254-app-update.md v0.3 — 第 2 輪設計審查 B(Android 網路與安全)

審查者 B,2026-11-12。範圍:整份 v0.3(456 行,未修改原檔)。證據:Batman-p3 @ d9b1428、Batman-app @ ff1805a(唯讀);AOSP 原始碼與 Android 文件(從 WSL 以 curl 抓取,存在 `/tmp/revB/`)。沒有碰節點或手機。

**Verdict:APPROVE-WITH-CHANGES。沒有 BLOCKER 或 MAJOR。** 我 v0.2 的 B1、M1–M5 都確實修好了(逐項附證據,見 §1)。下面的 MINOR 照收斂規則進 checklist。其中 m1 只要改一行字,建議凍結前順手改掉。另外列出四個可以砍的機制(§3)。

---

## 1. v0.2 的 BLOCKER / MAJOR 逐項核對

### B1 明文被擋 → ✅ 已修(raw socket 確實不受 NetworkSecurityPolicy 約束)
AOSP 的證據:
- **明文政策只在 HTTP handler 這一層檢查**:`external/okhttp` 的 `repackaged/android/src/main/java/com/android/okhttp/HttpHandler.java:122-126`(`CleartextURLFilter`)和 `android/src/main/java/com/squareup/okhttp/HttpHandler.java:118-122`,都呼叫 `NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(host)`。這是 `HttpURLConnection` 的 URL 過濾器,不在 socket 層。
- **socket 層本身不擋**:okhttp `RealConnection.java:101-104` 只檢查 ConnectionSpec;建立連線用的是 `address.getSocketFactory().createSocket()`(:108),這一步沒有任何政策檢查。
- **官方文件**:`NetworkSecurityPolicy.isCleartextTrafficPermitted()` 原文是 "there's no expectation that the Socket API will honor this flag because it cannot determine whether its traffic is in cleartext."
- `network.socketFactory.createSocket()` 拿到的是一般的 `java.net.Socket`(已綁定到該 Network),所以 D4 的做法成立,全 app 也不必放寬明文政策。
- §10-11 可以從 ⚠️ 改成 ✅(附上面三處)。T12 的負對照 1 仍然有價值:它證明全 app 沒有放寬。

### M1 提早拒絕時看不到狀態碼 → ✅ 已修
- D4 只分「200 / 其他」;U4 每次 PUT 之前都送 `bulk/open`;D15 規定任何失敗後先經 BLE 讀 `update/status`。
- `bulk/open` 對同一位擁有者是冪等的:延長同一個窗、回同一個 bearer(`node/bulk.go:83-95`)。
- T8 有「讀 body 前就 409」那一臂,也附了負對照。

### M2 中斷的 PUT 佔住上傳槽 30 s → ✅ 已修(措辭見 m1)
- provd 的讀取期限是「最後一次 `Read` 開始後 30 s」(`http.go:571-572`,每讀一次就重設);`putting` 在 handler 返回時才清掉(`:539-545`)。
- 所以從 app 偵測到失敗算起等 31 s,在 Wi-Fi 掉線(之後沒有資料再到節點)的情況下夠用。
- 「重送 `bulk/open` → 等 31 s → 才計次」與 T5 的負對照都有。

### M3 卡住偵測與取消 → ✅ 已修
- 35 s watchdog、讀狀態列的 SO_TIMEOUT 35 s、U6 的取消鍵、`onLost` 時關 socket,都寫進去了。
- 和 provd 的時間對得上:手機寫入停住 35 s 以前,節點的速率檢查(`http.go:575-579`,每 30 s 少於 256 KiB/s 就切)通常已經先切斷;切斷的 FIN / RST 沒送到手機時,就由 watchdog 收尾。兩邊不會互相卡住。

### M4 targetSdk 浮動 → ✅ 已修(寫死 36,見 §3 可砍項 c)

### M5 Specifier 會斷 TAK → ✅ 已修
- 直連路徑是主要的,而且 `RouteInfo.hasGateway()`、`isDefaultRoute()`、`matches()` 都是公開 API(RouteInfo 文件)。
- 走後備前會先說明;§6 有「斷兩次」那一列;T9(f) 會實測。

## 2. MINOR(進 checklist;m1 建議凍結前順手改)

1. **m1 等待規則的「或」**(§3.4 的 PUT 失敗第 1 步):「至少 31 s,**或者**看到百分比停住為止」。
   - 如果照「先到的那個」實作:Wi-Fi 一斷,provd 的已收 bytes 馬上就停了(它正卡在讀取,`http.go:571`),兩次讀到相同值只要約 10–20 s。這時重 PUT,provd 還在等 30 s 期限 → 409 → 白白算掉 3 次中的 1 次。
   - 「百分比停住」在兩種情況下都會成立,分辨不出任何東西。
   - 修法:改成「中斷後等 31 s」一條就好。
2. **m2 abort 時用 `setSoLinger(true, 0)` 再關 socket**(watchdog、取消、`onLost` 都一樣)。
   - 預設的 `close()` 會讓核心繼續把送出緩衝區裡的資料(可能好幾 MB)慢慢送完。訊號恢復時,節點還會繼續收這些資料,`putting` 就會撐過 app 的 31 s 等待。
   - linger 0 會改送 RST,丟掉緩衝區,讓 31 s 的前提成立。
   - ⚠️ 手機的送出緩衝大小沒有量。
3. **m3 T12 的 localhost**:`CleartextURLFilter` 依主機名稱判斷(HttpHandler.java:126)。`127.0.0.1` 有沒有例外沒查,v0.3 的 ⚠️ 備案(改綁手機的 Wi-Fi IP)保留即可。
4. **m4 連線逾時 3 s 等於「不是這台的 AP」**:對的 AP 上,ARP 或省電可能讓第一次連線變慢,於是誤判去走 Specifier,讓 TAK 斷兩次。
   - 建議逾時之後先重試一次 3 s,再走 Specifier。
   - ⚠️ 沒有量測過;T9(a) 記錄第一次連線花多久。
5. **m5 PUT 的寫入迴圈與 `requestNetwork` callback 不能跑在 UI thread**:實作細節,§11 加半句就好。

## 3. v0.3 可以砍的機制(最小端到端路徑用不到)

- **(a) §3.4「或者看到百分比停住」**:見 m1。不提供資訊,拿掉。
- **(b) §3.4 第 2 步「我們沒在傳,百分比卻在增加 →『有人正在對節點上傳』」與對應的 T5 一臂**:
  - 這是我 v0.2 提的,現在建議砍。原因:被搶的情況,最後一定會落到計次規則(0 + 11 / 0 + 15 或 PUT 一直失敗),而 P3 :517 的原句已經叫使用者「換節點 Wi-Fi 密碼」。
  - 它還需要「我們現在有沒有在傳」的跨 Kotlin / Rust 狀態,加上百分比趨勢判斷。
  - 代價:被佔住上傳槽時,使用者看到的是「傳送一直中斷 — 請靠近節點」,比較不精確。仍然只是 DoS。
- **(c) D6 的建置檢查 task**:`targetSdk = 36` 寫死成字面值,`flutter upgrade` 就改不到它了。檢查 task 只防「有人手動改那一行」,這是 code review 的事。保留註解即可;T13 的那個負對照跟著拿掉。
- **(d) T12 的負對照 2**(另外建一個加了 `usesCleartextTraffic` 的變體):負對照 1(`HttpURLConnection` 被擋)已經證明全 app 沒有放寬,所以不需要另外做一個 manifest 變體。

## 4. 其他核對(沒有問題)
- **owner-op 的簽章**:Keystore 的 owner key 只看前綴 `batman-owner-op-v1`(`SignAllowList.kt:9`),不需要逐一列動詞,新動詞不用改 Kotlin。key 沒有要求使用者驗證(`keystore/*.kt` 沒有 `setUserAuthentication*`),所以「每次 PUT 前都送 `bulk/open`」不會跳生物辨識。
- **check / apply 等 ≥ 340 s 不會被閒置斷線**:provd 在 ops 執行中不判定閒置(`session.go:287-288` `inflight`),結束時會刷新 `lastActive`(`:615`)。
- **raw PUT 的格式**:`Host`、`Content-Length`、`Connection: close`,沒有 `Expect`;Go 不會送 100,讀到的狀態列就是最終回應。
- **逐 actor 分析**:v0.3 §7 與我 v0.2 的分析一致,沒有新增的攻擊面(raw socket 只少了 proxy)。

**Verdict:APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR;MINOR m1–m5 進 checklist,m1 建議順手改;建議砍 §3 的 a–d)。
