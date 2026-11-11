# 254-app-update.md v0.2 — 設計審查 A(協定 / 流程正確性 + 測試計畫)

審查者 A,2026-11-12。審整份文件。只讀:Batman-p3 @ d9b1428(feat/254-p3)、Batman-app @ ff1805a(feat/254-app-s1)、Android 開發者文件(RouteInfo、wifi-bootstrap、security-config,2026-11-12 讀)。沒動任何 repo、節點或手機。
行號:`node/` `provd/` = Batman-p3 `feed/batman-prov/src/`;P3 = 254-p3-impl.md(L = 檔案行號)。

**判定:APPROVE-WITH-CHANGES**(架構對:BLE 跑全部動詞、只有一個 PUT、狀態只放節點。但有 1 個 BLOCKER 和 8 個 MAJOR,都在流程 / 介面層。改完要整份重審)

---

## BLOCKER

**B1. 明文 HTTP PUT 在 Android 9 以上預設會被擋;設計沒有處理這件事**
- 情境:release 或 debug build 照 D3 用 `Network.openConnection(URL("http://10.41.x.x:8095/..."))` 送 PUT。target API ≥ 28 的 app,系統預設不允許明文流量,HttpURLConnection 會直接丟例外,PUT 一次都送不出去。結果是主流程在 U6 一定失敗,依 §3.4 被當成「I/O 錯」重試 3 次,最後顯示錯誤的診斷。
- 證據:Android security-config 文件寫「Starting with Android 9 (API level 28), cleartext support is disabled by default」,target ≥ 28 的預設是 `<base-config cleartextTrafficPermitted="false">`。app 的 `targetSdk = flutter.targetSdkVersion`(app/android/app/build.gradle.kts:25)。`grep -rn 'leartext|networkSecurity' app/android` 沒有任何結果,main manifest 沒有 `networkSecurityConfig` / `usesCleartextTraffic`。§2 D3、§7 攻擊面、§11 manifest 清單也都沒提。
- 修法(選一個寫進設計,並放進 §7 的安全取捨):
  - (a) 加 `networkSecurityConfig`。`domain-config` 只能寫網域名,不能寫 IP 範圍,節點 IP 又每台不同,實際上只能用 `base-config cleartextTrafficPermitted="true"`,等於全 app 都允許明文 —— 這是安全退步,要寫明。
  - (b)(建議,機制更小)Kotlin 用 `network.socketFactory.createSocket(ip, port)`,自己寫 HTTP/1.1 的 PUT(請求行加 3 個 header、串流 body、讀狀態列)。NetworkSecurityPolicy 是 HTTP 函式庫在執行,raw socket 不受影響,全 app 的明文政策維持關閉;順帶也不會出現 chunked 或自動重試。
- 測試:T8 是 JVM 單元測試,抓不到這個問題(JVM 沒有 NetworkSecurityPolicy)。要加一個**裝置上**的 instrumented 測試,對本機或假節點送 PUT。負對照:用 (a) 的話移掉 config,用 (b) 的話換成 HttpURLConnection,都要觀察到 `CLEARTEXT communication … not permitted` 的 FAIL。

---

## MAJOR

**M1. `update/check` 等回應最多 15 秒,節點最壞要 120 秒以上;owner-op 的 E_BUSY / 「outcome unknown」也沒處理**
- 情境:
  - check 會跑 `PreSave`(可能 config-save)、`precheck-node`(上限 120 s)和目標槽 `bootinfo`(30 s)。app 目前 BLE 請求預設等 15 s,超過就判失敗,但節點已經寫下 pending,使用者看到的是錯的結果。
  - provd 的 ops 連線一次只能處理一個請求,另一個 ops 在跑時直接回 E_BUSY;跑超過 HelperWait 會回 E_BUSY,細節 3 是「outcome unknown」。所以另一支擁有者手機在跑 check 或 apply 的那 2–3 分鐘裡,我們的 `op/nonce`、`bulk/open`、`prepare`、`apply` 都可能拿到 E_BUSY。
  - 設計只在 U7 寫「prepare E_BUSY → 10 s 後再送」。如果那個 E_BUSY 其實是「outcome unknown」而 worker 已經啟動,重送 prepare 會一直拿到 E_BUSY(worker 在跑),app 卡在重送迴圈,永遠進不了 U8。
- 證據:node/update.go:41-42(tPrecheck 120 s、tArm 180 s)、:309-319;provd/server.go:23(HelperWait 330 s)、:206-209(「ErrBusy = another one is in flight」);provd/session.go 的 `ops()` 與 `busyUnknown`(約 :600-628);app/lib/nodes.dart:78、:457(預設 15 s);node/updwork.go:205-207(working → E_BUSY)。§10-11 只把 apply 列為待查。
- 修法:
  - check 和 apply 的等待改成 ≥ 330 s(HelperWait),bulk/open 和 prepare 照一般等待。
  - 所有 owner-op 收到 E_BUSY 一律**先讀 `update/status` 再決定**:prepare 之後看到 phase 2 → U8;apply 之後看到 3 / 4 / 5 / 6 → §6 那一列;都不是才在 10 s 後重送,最多 N 次。
  - check 逾時也照這條:讀 status,或在 10 s 後重送 check(同一位擁有者重送 = 覆寫 pending,update.go:362-366)。
  - 這條要進 T4 / T7:假節點回 E_BUSY{3:"outcome unknown"},且 worker 已在跑 → 下一個請求必須是 `update/status`,不能是 prepare。負對照:直接重送 → FAIL。

**M2. U8 / §3.3 沒處理 phase 0「沒有 reason」和「有 sha 沒 reason」**
- 情境:prepare 之後 helper 重啟(crash 或被 procd 重啟)。pending 和 window 都在記憶體裡,會跟著消失;前一個 helper 的孤兒 `batman-slot write` 還握著 flock,`bootinfo` 拿到 rc 14,要 60 s 後才重讀。這段期間 `cachedSlot` 沒有資料,status 落到最後一列 → `{1:0}`(沒有 reason,甚至可能沒有 sha)。孤兒寫完後才變成 0+23,或者 0+22。
  - 另外,worker 在 `begin_write` 之前失敗、且 pending 過了 30 分,status 也是 0、reason 0,但帶 key 4 / 5(第 11 列)。
  - U8 只寫了「phase 0 + reason → §4,回 U1」,沒有 reason 的情況會被當成「沒有更新」,或卡住。
- 證據:node/updwork.go:874-883(沒有快取或沒有 ul → `progress(0,0,0,nil,"")`)、:917(其他 → 0 + sha)、:198-213(rc 14 → slotsBad 60 s);P3 L35(第 11 列說明)。
- 修法:在 U8 / U10 / §3.3 加一列:「phase 0、沒有 reason,而且這個畫面剛看過 2 / 3 / 4」→「節點的更新程序重新啟動了,結果還不確定 — 1 分鐘後自動再看」,繼續輪詢(例如 2 分鐘)。之後還是 0、沒有 reason → 「這次更新沒有完成,目前版本沒變」(第 11 列的意思:槽沒動)。T6 / T7 每一列都要有一臂。

**M3. 「已寫好、等套用」超過 30 分鐘會變成 15 / 23,設計只會叫使用者整個重來;其實只要重新 check 就能直接 apply**
- 情境:現場最常見的是「寫好了,等這輪 TAK 任務結束再重開」(U9 的 TAK 警告本身就在鼓勵延後)。worker 結束後 pending 只再活 30 分(updwork.go:286-288),之後 apply 回 15(updwork.go:696-700),status 變成 0+23(:913-914)。設計對這兩種的文字分別是「請重新開始更新」和「新版已寫入但沒有啟用,請重新更新」→ 使用者會再傳 126 MB(約 8 分鐘)、再寫一次槽。
- 證據:節點設計和 CDDL 都已經說明這條捷徑 —— cddl「23 ; written but not applied (the pending is gone: check again)」;P3 L7:「已寫好且 VERIFIED 為本次開機的槽仍可直接 apply」。程式上,check 成功會建新的 pending(update.go:366),status 第 4 列(updwork.go:878-879)就直接回 3,apply 只看 `verified = sha + 本次 boot_id`(:709)。
- 修法:apply 回 15,或 status 是 0+23,而且還是同一次開機時:
  - 手上還有 manifest → 自動重送 `update/check`(遵守 10 s 額度),回 ok 之後讀到 phase 3 → 顯示「套用並重開」;
  - 手上沒有 manifest(app 重開過)→ 「請重新選更新檔(只要 manifest)以套用已寫好的新版」。
  - 重開機之後 `verified` 不再符合,才是真正要重來(重開後的 23)。
  - D6 和 §4 的 23 文字要分這兩種。
  - 加測試:T7「worker 結束 31 分鐘後 apply → 15 → check → 3 → apply」,負對照:回 U1 重傳 → FAIL。

**M4. `update/status` 不分擁有者,§3.3 續行表會對別人的更新顯示「套用」或「放棄上一次」**
- 情境:兩位擁有者。A 在上傳或已寫好時,B 打開更新頁:status 回的是 A 的 phase 1 / 3 和 A 的 sha。照 §3.3,B 會看到「套用並重開」(sha 取自 status key 4),或「放棄上一次」(`bulk/close`)。
  - B 按下去,apply 回 15、bulk/close 回 15。B 看到的文字是「上一步的條件不成立(可能超過 30 分鐘)」,接著走 U2,check 又回 E_BUSY。
  - app 自己被殺後重開也是同樣的情況:D5 不存任何東西,所以 app 根本分不出那是不是「自己的」更新。
- 證據:node/updwork.go:860-879(status 只看 pending、不看擁有者);:696-699(apply 要求擁有者);bulk.go:109-112(別人的窗 → 15);update.go:284-288(別人的 pending → E_BUSY)。
- 修法:
  - §3.3 的 phase 1 / 3 一律只說「節點上有一個進行中的更新(<key 5>)」,不先假設是自己的。按鈕先送 owner-op(apply / bulk/close / bulk/open);回 15 就說「這個更新不是這支手機開始的(或已過期)」,不要用「重新開始」那一句。
  - §6 的「第二位擁有者同時更新」那一列要寫 B 這一側實際看到的畫面。
  - T6 加一臂:status = 別人的 phase 3,apply 回 15 → 對應文字。負對照:沿用 15 的通用句 → FAIL。

**M5. §3.4 的 409 分類靠的是「沒寫明的契約」(HTTP body 文字);有一種 409 沒有規則**
- 情境:
  - provd 的 4 種 409 只在 body 文字上不同(「no upload window」「the update is being written」「the window ends too soon: bulk/open again first」「an upload is in progress」),§3.4 卻要依「窗剩不夠」和「其他」分流,§5.2 也寫「HTTP 只看狀態碼」。
  - 「已有 PUT 在進行」:app 被殺後重開、手機重開或 Wi-Fi 斷掉時,provd 那個 PUT 要等 30 s 讀取期限才會結束。這段時間 status 仍是 1,§3.4 的「讀 status:窗沒開 → U4;worker → U8」對 phase 1 沒有規則。
- 證據:provd/http.go 的 `httpPut`(約 :509-541,4 個 `http.Error(…409)`)、`copyUpload` 的 `SetReadDeadline(30 s)`(約 :573-574)。
- 修法(同時減少機制):**每次 PUT 前都先重送 `bulk/open`**(同一位擁有者 = 同一個 bearer、延長窗,bulk.go:83-94)。「窗剩不夠」這種 409 就不會發生,也不用解析 body。剩下的 409 一律「讀 status:1 → 每 5 s 重試最多 60 s(涵蓋 provd 4 s poll 和 30 s 讀取期限);2 → U8;0 → U4」。T5 / T8 要有「已有 PUT」那一臂。

**M6. prepare 的 15、status 0+15 / 0+11 都只寫「重 PUT」;實際上有三種情況,只有一種可以直接 PUT**
- 情境:
  - (a) prepare 回 15 而窗還開著(上傳不完整)→ 直接重 PUT 是對的。
  - (b) prepare 回 15,原因是沒有 pending 或沒持有窗(helper 重啟、pending 過期、別人)→ PUT 會 409,而且 §3.4 會把它算進「3 次」,最後顯示「有人干擾,換密碼或重燒」—— 誤導。
  - (c) worker 失敗後的 0+15 / 0+11:prepare 已經把窗關了(updwork.go:234),worker 也 unlink 了上傳檔(:320)→ 必須從 U4 `bulk/open` 開始,不是「重 PUT」。U8 寫的「回 U1」又要重選檔、重 check,多做了。
- 證據:node/updwork.go:208-218(prepare 回 15 的 3 種原因)、:234、:320;P3 L44(EAGAIN → 15、app 重傳)。
- 修法:
  - 收到 prepare 15 先讀 status:phase 1 而且是我們的 sha → 重 PUT,計次;其他 → U4,窗沒了就到 U2,**不計次**。
  - status 0+15 / 0+11 → U4(保留已選的兩個檔),計次。
  - 寫明計數器的範圍:放在記憶體、這一次流程有效,app 被殺就歸零 —— 這是誠實界線。
- 另外,0+21(worker 逾時)和第二遍發生的 0+11 時,目標槽已經是 BAD(P3 L50:「逾時 → reason 21,目標槽保持 BAD」)。§4 對 21 的文字「節點現在無法寫入,請稍後再試」暗示什麼都沒動。phase 2 之後出現的 0+21 應該說「這次寫入失敗,退路可能已失效,請再更新一次」(pending 過期後 status 會變成 0+22)。

**M7. reason 16 → 設定 AP → 回來「直接 U4」,但 AP 和防火牆檢查需要時間,會先回 16 / 21**
- 情境:§3.5 是 app 流程節點的**常態**(F27)。`settings/set` key 20 套用之後,radio0 要先 up;helper 每 4 s 的背景檢查(兩張 nft 表 + `phy*` 前提,快取 ≤ 10 s)要先看到新的 AP port,`HTTPAddr()` 才會是 ok。在那之前 `bulk/open` 會回 16(`AP()` 還沒 up)或 21(「HTTP firewall rules are not in place」)。設計對 21 的處理是「節點現在無法接收,請稍後再試」然後停住 → 主路徑在第一次使用時就斷掉。
- 證據:node/bulk.go:54-56、:73-82;BulkSys 註解 bulk.go:21-23(「every 4 s, fresh <= 10 s」);P3 L80。
- 修法:剛設好 AP 回來的這一次,`bulk/open` 回 16 或 21 時每 5 s 重試,最多 30 s,之後才顯示文字。T4b 加一臂:假節點先回 21 兩次再回 ok → 流程繼續。負對照:不重試 → FAIL。
- 實機 ⚠️:這個時間差要在 §3.5 實機測試時量。

**M8. 測試計畫:全部流程測試都對「我們自己寫的假節點」;唯一的實機測試(T10)只測拒絕路徑;T11 沒排**
- 情境:B1、M2、M4、M5 和下面的 m1 都是「作者對節點行為的假設」,和節點程式不一致。T4–T7 的假節點照這些假設寫,只會全綠(使用者的記憶規則「stub 要照真工具輸出格式」就是這個坑)。T11 是唯一能證明 U1–U10 跑得通的測試,本稿明寫「列出但不跑」,也沒排時間。這和「先跑通一條」的原則相反。
- 證據:§8 T4「照 leave T2 的假節點寫法」、T11「本稿不跑」;Batman-p3 已經有真 helper 的主機測試(`provd/realhelper_update_test.go`、`provd/rig_test.go`)。
- 修法:
  - (1) 假節點的 status / 409 / 錯誤回應,從真 Go 程式擷取(用 rig 跑一次 check→open→PUT→prepare→status→apply,把每個回應存成向量),或直接讓 T4 對主機上跑的真 provd+helper(用假的 batman-slot);
  - (2) 把「04 換 bench build → T11 正路徑」列為完成條件,不是附錄;
  - (3) 加 M1–M7 的每一臂,每臂都附負對照。

---

## MINOR

- **m1.** 「0 + 18」不存在。節點只會產生 6(TRIAL-REVERTED,reason 0)和 6+18(有 rebooting、沒有判定)(updwork.go:900-908;P3 L27)。要把 U10、§4、T7 的「0 + 18」刪掉,6+0 和 6+18 分開寫(6+0 =「新版不健康,已退回」;6+18 =「新版沒有完成試用」)。另外 F16「arm 失敗 → disarm」不精確:rc 10–18 不會 disarm(updwork.go:733-742)。
- **m2.** apply 的拒絕原因不只 15:slotReason 會給 1 / 12 / 17 / 11 / 5 / 2 / 21,還有 E_BUSY(rc 14)和 E_STORAGE(updwork.go:727-756、update.go:46-66)。§4 用「來源」分列,所以 apply 或 status 的 12 / 17 / 2 會落到通用句。建議 §4 改成只用 reason 對應(文字本身不依賴來源),只有 15 和 21 依「在 phase 2 之前或之後」分。
- **m3.** U10:試用期間退回會**再重開一次**(autocommit 退回)。phase 4 輪詢中 BLE 再斷一次,要沿用「重試登入」規則,不能當失敗。phase 5 / 6 會一直保留到下一次 prepare(ul 不會清):之後每次進頁都會看到「更新完成」或「已退回」,文字要改成「上一次更新:…」。沒選檔時也不要說成「節點上有另一個更新」(§3.2 末段)。
- **m4.** D6「bulk/close 節點刪檔,回到原狀」說多了:bulk/close 只把窗設成 nil(bulk.go:109-115),pending 還留到「窗到期 + 5 分」(最多約 20 分),這段時間其他擁有者 check 會 E_BUSY(update.go:284-288)。U3 取消也是一樣,pending 留 30 分。文字改成「另一支擁有者手機約 30 分鐘內不能開始更新」,或接受並寫成誠實界線。
- **m5.** D4-1:`RouteInfo.matches` 對 default route(prefix 0)永遠是 true(RouteInfo 文件:`isDefaultRoute` = prefix length 0;`matches` =「destination and prefix length cover the given address」)。任何有 default route 的 Wi-Fi 都會「符合」。應該只看 `!isDefaultRoute() && !hasGateway()` 的直連路由。另外:
  - TCP 探測要分清楚:RST(拒絕)= 封包有到節點,只是還沒 bind,在這個 Network 上繼續等;逾時 = 不是這台的 AP(F13 是 drop)→ 才走 Specifier。
  - 探測成功不代表對方就是這台節點(同 IP 的其他主機)→ PUT 的 200 本來就不被信任(§5.2),但要寫明這樣送出 bearer 和公開 image 的後果只是 DoS。
- **m6.** status key 15 的 `http_bind_failed`(node/status.go:228-230;P3 L82「app 顯示」)沒有用到。bind 失敗時 PUT 一直被拒,會退到 Specifier,最後顯示「傳送一直中斷 — 請靠近節點」,診斷是錯的。U4 前和 409 / 拒絕時讀它 →「節點的上傳埠被佔用,請重開節點」。
- **m7.** PUT 回 200 到 prepare 之間,最壞只剩約 60 s 的窗:窗剩 ≥ size/256KiB+60 s 才放行 PUT,如果剛好以最低速率傳完,只剩 60 s。這段時間 BLE 斷過的話,重新交握加 `op/nonce` 要在 60 s 內完成。M5 的「PUT 前先 bulk/open」只延長到 PUT 開始那一刻。建議 BLE 重連後先 `bulk/open` 一次(延長)再 prepare,或接受並列入 §6。
- **m8.** 0+11 的 3 次規則:如果使用者選錯了同樣大小的 payload,會傳 3 × 約 8 分鐘,最後顯示「有人干擾、換密碼、重燒」。§9-6 的本機比對(只解 gzip 第一個 tar 成員、算 sha = key 4)可以在傳之前抓到。這是使用者要做的取捨;至少讓 0+11 第一次的文字先提「檔案可能不是同一份」。
- **m9.** E_RATE:helper 的全域 `lastCheck` 在 E_BUSY 回應時也會更新(update.go:279-283)。另一支手機剛 check 過時,我們會拿到 E_RATE。U2「10 s 後自動再送一次」夠用,但第二次再拿到 E_RATE 要顯示文字,不能無限重送。
- **m10.** F4、F14 的行號和語意都對;F10「worker 在跑或別人的窗 → E_BUSY」對,但要補上:同一位擁有者在**窗開著**時重送 check 也會 E_BUSY(update.go:280-283)→ §3.3「1 / 否 / 選檔繼續」一定要先 `bulk/close` 再 check,現在的表沒有寫這個順序。

---

## 審查範圍外 / 留給 B
Specifier 在單 STA 手機上會不會斷掉原本的 Wi-Fi、會不會存密碼(§10-1、§10-10)、field flavor 的信任政策、權限清單:只確認了 wifi-bootstrap 文件沒有說會斷線或存密碼(只說「stores the approval for the particular access point」),維持 ⚠️,要在 T9 實測。

## 判定
**APPROVE-WITH-CHANGES** —— B1 必修。M1–M8 修完後要整份重審。最小可行的改法同時能減少機制:PUT 前一律 `bulk/open`(拿掉 409 分類)、所有拒絕和 E_BUSY 都先讀 status(拿掉多套分流)、用 raw socket 送 PUT(不需要放寬全 app 的明文政策)。
