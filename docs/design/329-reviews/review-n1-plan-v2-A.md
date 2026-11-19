# Review A — `329-n1-plan.md` v2 (N1:節點丟掉連上卻不開 session 的裝置)

審查對象:`docs/design/329-n1-plan.md` v2 整份;樹 `C:\src\Batman-b8` @ 6760b78(唯讀)。
對照:`feed/batman-prov/src/cmd/batman-provd/bluez.go`、`provd/server.go`、`provd/session.go`、`scripts/dv/prov-provd-254.sh`、`scripts/node/prov-p2-central-254.sh`、`docs/design/254-p2-impl.md`、v1 的兩份審查、BlueZ 5.72 `src/device.c`、vendored godbus v5.2.4、#329 issuecomment-6981729272。
沒有碰任何真機;沒有跑任何程式(純讀原始碼)。

## 結論(verdict): APPROVE-WITH-CHANGES

方向正確、範圍夠小(只動 `converge` 的計數,沿用既有的 `staleLinks`)。有 3 個 MAJOR,都是小修改,但依規則要改完整份再審一次:

- M1:`devSince` 與 `devConn` 是兩張表,`:412` 與訊號處理的先後不保證 → 會留下孤兒時間戳,同一支手機之後再連上時「一連上就已經過期」,修法對它失效。
- M2:單元測試只測純函式 `liveLinks`,但生命週期表有三列寫「unit」的行為都在這個函式之外(正好是 M1 出事的地方)。
- M3:harness 的 respawn L80 對照臂沒辦法「改成先斷言」,計畫的處理方式對它不適用;`read` 也握著無 session 的 link 約 22–25 s,計畫沒列。

---

## 一、事實查核(F1–F9 與每個 file:line)

| 項 | 結果 | 說明 |
|---|---|---|
| F1 | ✅(issue 有) | #329 comment 6981729272 第 2 節:`adv withdrawn reason=connect`、之後沒有 `connection ble` 也沒有 `adv registered`;22:36 BlueZ `Connected: yes`;S20 `teardown_time` 21:57:28 / 21:59:26。沒有 `connection ble` ⇒ `link()` 沒被呼叫 ⇒ 是「devConn 有、links 無」的情況,新條件抓得到。 |
| F2 | ✅ | `bluez.go:733`(`len(b.links)+len(b.devConn)`)、`:772-776`。 |
| F3 | ✅(行號差 1) | 實際是 `:688-729`;sender 檢查 `:691`;`set` 在 `:694-702`;`InterfacesRemoved` 刪除在 `:721`。 |
| F4 | ✅ | `link()` `:294-313`;刪除 `:412`;`ReadValue` `:121-134` 不呼叫 `link()`。補充:`link()` 的呼叫點是 `WriteValue :143`、`AcquireWrite :166`、`AcquireNotify :183`。 |
| F5 | ✅(行號差 1) | `register()` 是 `:583-600`,`staleLinks()` 呼叫在 `:590`;`staleLinks` `:518-567`,3 輪(`:526`)× 5 s(`:557`),D-Bus 呼叫不持 `b.mu`。 |
| F6 | ✅ | `:656-681`。補充:任何符合的 bluez 訊號(含 `NameOwnerChanged`)都會再跑一輪。 |
| F7 | ⚠️ 無法查證 | 只在 session log;#329 的那則 comment 沒有這段輸出。它是「Disconnect 清得掉 F1 狀態」的唯一證據,原始輸出要貼進 #329(見 m8)。 |
| F8 | ✅ / ⚠️ | `claim.dart:335-370`(`_find`:連線 + 讀 STATUS)、`:497-530`(`_find` 回來後直接 `requestMtu :523`、讀 ctrl、`publicKeys`、`signOwner :531`,中間沒有使用者步驟;`_ask` 都在 `:481` 之前)✅。`app/android` 裡沒有 `setUserAuthenticationRequired` / `BiometricPrompt`,簽章不會等人 ✅。「< 9 s」:`ux/m1.log` 不在 repo;issue comment 的 4.1 s / 8.6 s 與它一致 ⚠️。 |
| F9 | ⚠️ 不完整 | 行號 99–106、125–137、192–200 都對;`hold` 只有這一支腳本在用(全 `scripts/` grep)。**漏掉 `read`**:`read_one`(`prov-p2-central-254.sh:112-124`)連上後固定 sleep 8+2+1+2+1+8+1 = 23 s 才 `drop`,全程只讀 STATUS / CTRL,沒有 `links` 條目(見 M3)。 |
| §3 `:491` | ✅ | `refreshOwner` 在 owner 改變時重設 `devConn`。 |
| §4 `bluez.go:691` | ✅ | |
| §4「dev raw console page」 | ❌ 找不到 | `app/lib/ui/settings_page.dart:2` 寫「PR 6: the old console is gone」;`app/lib` 的四個 `connectToDevice` 呼叫點(`claim.dart:353`、`claim_recovery.dart:99`、`scan.dart:170`、`ble_backend.dart:27`)都是連上就接著做,沒有「連上後等人打字」的頁面。這句要刪或改成實際存在的頁面。 |
| 生命週期表「session ended, phone keeps the link:Today = dark until the phone lets go」 | ❌ 不準確 | 今天 `bleLink.Close` 在 `:417` 就會呼叫 `Device1.Disconnect`。「今天」應寫成「provd 下一次 Disconnect;沒清掉就一直暗」。 |

30 s 對不對:✅ 夠。`prober.dart:123`:從 connect 到 msg2 全部預算 8 s;`claim_recovery.dart:194, 505`:connect ≤ 15 s 後立刻送 msg1;claim 頁與 dev 的藍牙測試頁(`scan.dart:164-200`,自己 30 s 逾時後 `conn.cancel()`)都沒有等人的步驟。與 `IdleAnon`(`server.go:30`)同長,不需要更短。

---

## 二、指定要查的幾個問題(先給答案)

1. **`converge` 的計數與 `register()`→`staleLinks()` 之間的競爭,會不會切到剛連上的手機?**
   不比今天差。到 `register()` 的兩條路:(a) `!advOn`:此時 provd 沒有廣播,新手機連不進來;寬限期內的裝置會被算進去,根本到不了 `register()`。(b) `rpa_timeout`(`:777-779`):`advOn` 為真,計數快照(`:733`)到 `GetManagedObjects`(`:528`)之間剛連上的手機會被切——這是今天就有的窗(約 15 分鐘一次,窗寬 = `HealthOK` + `adapterOK` 兩次 D-Bus + `KernelInstances`),改動沒有擴大它。
   唯一新的情況:裝置甲自己剛好在 30 s 那一刻才寫 RX(見 m2)。
2. **`:412` 與訊號處理會不會不一致?** 會,見 M1。
3. **過期裝置 + 活著的 session:** 計畫的行為(session 結束後才清)可以接受,理由計畫沒寫:`Sessions() > 0` 時 `:772` 本來就撤廣播,晚清不會多暗一秒;過期裝置不佔 slot(slot 只在 `Accept` 算,`server.go:776-818`)。v1 A-M1 / B-M-1a 要求「按裝置判定、不看全域 `Sessions()`」沒有被採納,這個理由要寫進計畫(m3)。
4. **`staleLinks()` 卡住 converge 迴圈最多 15 s 要不要緊?** 正常情況不要緊:活的 link 在 BlueZ 的 2 s timer(`device.c:69, 1895`)後回覆,第二輪就空了,約 2–3 s;而且到 `staleLinks` 時廣播一定是關的,不影響 health 撤廣播的 9.5 s 預算(L67)。**清不掉的殭屍**才會每次都卡滿 15 s,見 m1。卡住期間訊號不會丟,但 godbus 在 channel(容量 32,`:651`)滿時改用 goroutine 延後送(`default_handler.go:316-333`),**順序可能亂**;改動後亂掉的 `devConn` 會在 30 s 後自己癒合(今天是永遠暗),這是改善。
5. **既有 `hold` 臂:** 見 M3。
6. **有沒有合法 client 連上後超過 30 s 才寫 RX?** app 沒有(上面)。harness 的 `read` 握 ~22–25 s,在邊緣內。HTTP / sock 不經過 BLE link,不受影響。

---

## 三、發現

### M1(MAJOR)`devSince` 與 `devConn` 兩張表會不一致:孤兒時間戳讓「再連上的同一支手機」一開始就過期

- **情境**:手機做完一次 session,由手機端斷線。BlueZ 發 `Connected=false`(run 迴圈 → `deviceChanged` 刪 `devConn[p]` 與 `devSince[p]`),同時關掉 acquire 的 fd(`watch` goroutine `:322-334` → `Close` → `:412`)。兩者在不同 goroutine,先後不保證;run 迴圈正在跑 `converge` 的 D-Bus 呼叫時,或 bluetoothd 重啟(`refreshOwner :491` 重設表,之後 fd HUP 才到)時,`Close` 會排在後面。計畫 §3-1 第二點寫「links 條目移除時設為 now」沒有條件 ⇒ 寫回一筆沒有 `devConn` 的 `devSince[p]`。
  之後同一支手機(RPA 輪替前路徑相同)再連上:§3-1 第一點「for a path that had no entry」⇒ 已有條目、不更新 ⇒ 年齡從上次算起,超過 30 s ⇒ 一連上就是 stale、不計數。此時 `advOn` 為真(它才連得進來),`converge` 走不到 `:772`,也走不到 `register()`:
  - 不撤廣播、不印 `adv withdrawn reason=connect`(破壞 `254-p2-impl.md:227` 的 log 契約,也破壞 `prov-provd-254.sh:90` 這類見證);
  - 如果這次連線是 F1 那種半開,沒有人會去清它,要等到 `rpa_timeout`(≤ ~17 分鐘)才重註冊。**這正是 F1 的使用型態**(手機當晚先用過 04,之後某次連線半開),修法在這個順序下失效。
  - 孤兒條目沒有人刪;路人換隨機位址可以讓表一直長。
- **證據**:`bluez.go:322-334`(HUP → `Close`)、`:409-415`(`Close` 只看 `links`)、`:688-702`(訊號路徑)、`:489-492`(重設)、`:777-781`(`advOn` 為真且未到 RPA 時沒有任何分支)。
- **修法**(不加機制,反而少一張表):把時間戳併進 `devConn`——`devConn map[dbus.ObjectPath]time.Time`(需要「只印一次」的旗標就用小 struct)。規則三條:`Connected` 由無變有時設 now;`Connected=false` / `InterfacesRemoved` / 重設時刪;`:412` **只在條目存在時**改成 now。一張表就沒有「兩邊不一致」這件事。§4 的「missing entry = treat as now」可以整句拿掉。
- **負對照**:單元測試列「`Connected=false` 之後才 `Close` → 表是空的;60 s 後同路徑再 `Connected=true` → 算 fresh、被計數」。照 v2 文字實作這列 FAIL。

### M2(MAJOR)單元測試只涵蓋純函式;生命週期表三列的「unit」測不到它們宣稱的行為

- **情境**:表裡「session ended, phone keeps the link」「stale device + another live session」「bluetoothd restart(reset)」三列的測試欄都寫 unit,§5-1 也列了「link removed → fresh grace; reset empties both maps」。但 `liveLinks(links, devConn, devSince, now)` 是純函式:`:412` 有沒有寫時間、`:491` 有沒有一起重設、`deviceChanged` 何時設 / 刪,都在它外面。這幾列對真正的程式碼只是「函式存在」等級的檢查;M1 的錯誤就在這個縫裡,v2 的測試抓不到。
- **證據**:計畫 §3-4、§5-1;`cmd/batman-provd/` 目前沒有任何 `_test.go`。
- **修法**(不需要假 bus):這些處理函式本來就不需要連線——`deviceChanged`(`:688`)只用 `b.bluezName` 與 `s`,可以直接餵手做的 `*dbus.Signal`;`bleLink.Close`(`:394-420`)在 `b.conn == nil` 時跳過 D-Bus 呼叫;重設抽成一個小函式給 `refreshOwner` 用。測試用 `newBLE(...)` 建一個沒有 bus 的 `bleSide`,照事件順序跑表格:連上 → 31 s;連上 → link → `Close` → 寬限重新起算;`false` 先於 `Close`(M1);重設後 `Close`;InterfacesAdded 帶 `Connected=true`。CI 已經會跑到(`ci.yml:141` `go test ./...`)。
  「stale 時真的走到 `register()`」這條接線留給真機臂(§5-2)證明即可,那一臂是真的黑箱測試。
- **負對照**:每一列各自對應一個拿掉的寫入點(拿掉 `:412` 的更新、拿掉重設、拿掉年齡規則),寫在測試註解或 PR 內文。

### M3(MAJOR)harness:respawn 的 L80 對照臂不能「改成先斷言」;`read` 沒被列入;25 s 門檻只量一次不夠

- **情境 a(respawn 對照臂,`prov-provd-254.sh:125-127`)**:`hold02` 回來時 link 已經存在一段時間——`hold` 送出 `connect` 後 `sleep 6`,再輪詢最多 10 s(`prov-p2-central-254.sh:160-166`),所以回傳時 link 年齡約 6–16 s;接著 `c02 watch "$a" 15` 要求 **15 s 內都還連著**(`STILL`)。加上 ssh 與 `flock`,到判定時 link 年齡約 22–32 s,而 N1 在 30–35 s 動手。這一臂的斷言本身就是「握滿 15 s」,沒有「先斷言」可言;v1 審查 A(`review-ux-plan-v1-A.md:108`)已經點名這一臂。結果是偶發的 INVALID(`:136`),全套 validation 會被它卡住,而且照規則每個 FAIL / INVALID 都要有歸因。
- **情境 b(`read`)**:`read_one` 的 link 無 session 約 22–25 s(固定 sleep 23 s + `info_of` 重試)。`c02 read` 到處在用(`:86`、`:190`、chain1 reader)。目前在 30 s 內,但只差 5–8 s;計畫 §5-3 只說要量 `hold02` 臂。被切的時間點在兩次讀之後,值不受影響,但會多出 `link without session…` 與 `disconnected 1 stale link(s)` 兩行。
- **情境 c**:§5-3「在 wsl.26 上量一次,> 25 s 的才改」——02 的 bluetoothctl 約 5 次有 1 次 segfault 重試(central 腳本 `:6, :64-65`),一次的量測代表不了分佈。
- **情境 d(新臂的收尾)**:新臂在 wsl.26(負對照)一定 FAIL,此時 02 還握著 link。central 腳本 `:33-36` 記錄過:留下的 link 讓 04 一直撤廣播,害下一個 dep-restart 失敗。計畫沒寫新臂在每條路徑(PASS / FAIL / INVALID)結束前都 `c02 drop`。
- **修法**:
  - 對照臂:把「握住」的時間從連線起算控制在 30 s 內並留餘裕——例如對照的 `watch` 改 10 s,或讓 `hold` 印出 link 年齡、臂內用它判斷;同時讓對照臂讀 04 的新 log 行:窗內出現 `link without session` ⇒ 以這個原因 INVALID(有歸因),不是「原因不明地斷了」。選哪個由作者定,但要在 wsl.26 與 rc 上都穩定。
  - F9 與 §5-3 補上 `read`(量它的 link 壽命;寫明餘裕)。
  - 量測改成「每一臂在 wsl.26 上跑 N 次取最大值」,門檻用最大值。
  - 新臂:任何出口都 `c02 drop`;drop 之後確認 04 回到一個 instance 才離開。

### m1(MINOR)「Disconnect 清不掉」這條路沒有生命週期列,而且會洗 log

- **情境**:F1 的殭屍如果 `Device1.Disconnect` 沒效(原因 ❓ 未知,F7 只有一次觀察)。BlueZ 對已經不在的裝置不回覆 ⇒ 每輪等滿 5 s ⇒ 一次 `staleLinks` 卡 15 s。之後:
  - kernel 接受廣播:節點恢復 ✅;但此後每次重新註冊(每次 session 結束、每次 `rpa_timeout`)都先卡 15 s,手機做完一件事要等 15 s 才看得到節點。
  - kernel 拒絕(F-P41,`le_states` 未實測):每個 tick 重試,每次卡 15 s,節點照樣一直暗(與今天相同,計畫 §3 最後一段有老實寫)。而且 `:560` 的 `n++` 每輪都加,`:565` 每次印 `provd: disconnected 3 stale link(s)`,**沒有限速**,約每 20 s 一行,幾小時內把 logread 的環狀緩衝洗掉——洗掉的正是查 F1 根因需要的那段 log。
- **證據**:`bluez.go:526-566`、`:590-594`(只有 register 失敗那行走 `logLimit`)。v1 A 的 minor 3 提過,v2 沒處理。
- **修法**:表加一列「Disconnect 沒清掉」(今天 / 之後 / 測試欄寫 ❌ 未測、原因);`:565` 那行在內容重複時走既有的 `logLimit`;§2 的「at most the grace time plus one disconnect」加上這個但書。不要求加升級處置(RemoveDevice / 重啟 bluetoothd):F7 顯示 Disconnect 有效,沒有證據需要它。

### m2(MINOR)裝置在第 30 秒才寫 RX:被放過之後 `register()` 仍會在有活 link 時註冊廣播

- **情境**:甲 30 s 整被判 stale,`converge` 進 `register()`;甲在 `staleLinks` 檢查 `links`(`:538-540`)之前寫了 RX ⇒ 被放過(對),但 `register()` 繼續 `RegisterAdvertisement`(`:591`)。kernel 可能拒絕(印一行 register failed),也可能接受 ⇒ `adv registered reason=disconnect` 緊接著 `adv withdrawn reason=connect`,session 進行中多出一對 log 行。
- **證據**:`bluez.go:583-600`。`rpa_timeout` 那條路今天就有同型的窗。
- **修法**:二選一——`staleLinks()` 回來後、`:591` 之前重新數一次(有活 link 就 return,兩行);或在計畫寫明接受並說明 harness 的行數判定不受影響。

### m3(MINOR)「過期裝置 + 活 session 留到 session 結束」的理由沒寫;sock 也算

- `Sessions()` 把 sock 也算進去(`server.go:835-845`)。v1 兩位都要求按裝置判定。v2 的選擇可以接受(見二-3),但 §3 只寫「another phone」,沒寫 sock,也沒寫為什麼不會更暗。補一句,並寫明現場誰會長時間握著 sock session(⚠️ 我沒有查到常駐的 sock client;若有,過期裝置會一直留到它斷)。

### m4(MINOR)年齡要用單調時鐘

- 節點沒有 RTC(民用 tier),GPS / NTP 對時會讓牆鐘往前跳幾年。年齡必須是兩個 `time.Now()` 值的 `Sub`(Go 會用單調讀數);不要經過 `Unix()` / `Round(0)` / 序列化,否則對時那一刻所有寬限期內的 link 一起過期。計畫寫明這一點,單元測試的 `now` 用 `base.Add(...)` 建。

### m5(MINOR)log 契約與「只印一次」的狀態

- 新行 `provd: link without session for 30 s, dropping` 要加進 `254-p2-impl.md:227` 的 log 契約(§4 只說 harness 會讀)。
- 「logged once per device」需要一個每裝置旗標,§4 的擁有權清單沒有列它;照 M1 併表後放在同一個 struct 即可,隨條目一起刪。

### m6(MINOR)新真機臂的判定細節

- 04 上的臨時裝置斷線後物件會被 BlueZ 移除:斷言要接受「`Connected: no` 或 not available」(central 腳本的 `conn_state` 已經這樣分,`:77-80`)。
- 「one advertising instance」是節點自己的說法。再加一個 central 端的結果:臂的最後 `c02 read "$LAST4"` 成功(02 真的又掃得到、連得上 04)。這才是使用者的症狀;動詞現成,不是新機制。
- 等 50 s 夠(從連線起算最慢約 40 s)。

### m7(MINOR)生命週期表缺列

- **clean stop**:`stop()`(`:431-447`)只關有 `links` 的;無 session 的裝置留著,下次啟動由 `:743` 清——與今天相同,寫一列。
- **dbus 重啟 / provd 的 bus 連線斷掉**:`connect()`(`:473-475`)不重設 `devConn`;只有 bluez 的 unique name 變了才重設(`:489-491`)。名稱沒變而訊號漏掉時,今天會留下永遠的假條目(永遠暗),改動後 30 s 自己癒合——這是改善,值得寫進表,既有的 `dep-dbus` 臂涵蓋。

### m8(MINOR)重現與證據的交代

- 規則是「真機重現才修;重現不出來要寫試過什麼並先問」。F1 是當場擷取到的一次(證據在 issue ✅),但沒有再觸發過;v1 兩位都要求試「手機連上後、第一次 GATT 存取前關藍牙 / 飛航 / 殺 app」。v2 沒寫試過沒有。請寫明(試過什麼、結果;或沒試、原因),並把 F7 的原始輸出貼到 #329。
- #329 checklist 那一項在 PR 內文與勾選時標 ⚠️(以 `hold` 代替;真的殭屍尚未見過 provd 自己清掉),不要寫成 ✅ 已修好 F1。計畫 §5 最後一行已經有這個意思,收尾時照做。

---

## 四、安全

- **遠端無線對手**:沒有新能力。一條閒置 link 讓節點變暗的時間從「永遠」降到 30–40 s;每 30 s 重連仍可壓住單一 BLE 槽(計畫 §2 有寫,與 `254-p2-impl.md:105` 的既有誠實界線一致)。讀 STATUS 不會延長寬限(`ReadValue` 不碰表)✅。對手能影響的輸入只有「哪個裝置路徑、何時連上」,路徑來自 BlueZ 自己的訊號。M1 的孤兒條目是唯一對手可以累積的狀態,併表後消失。
- **本機非特權程序**:不能偽造 `Connected`(`:691` sender 檢查 + dbus policy);N1 沒有新輸入 ✅。它可以用 sock session 讓廣播撤掉——今天就可以,沒有變。
- **被攻陷的 peer / 權限**:provd 沿用既有的 `Device1.Disconnect` 權限(`prov-provd-254.sh:195-196` 的 471 測項在驗),沒有新的呼叫點 ✅。特權程式碼作用的對象仍是 BlueZ 回報的 `Connected` 裝置,沒有路徑 / 檔案類的 TOCTOU。
- **失敗模式**:缺時間戳 ⇒ 照舊計數(對可用性是舊行為,不是更糟)✅;併表後這個分支不存在。
- **負向測試**:新臂用非擁有者的 central(02)✅。

## 五、v1 審查的 N1 發現是否解決

| v1 發現 | v2 | 判定 |
|---|---|---|
| A-M1 / B-M-1b:`staleLinks` 無年齡會切到剛連上的 | 寬限期內的裝置被計數 ⇒ 到不了 `register()` | ✅ 解決(理由見二-1) |
| A-M1:不持 `b.mu` | 沿用 `staleLinks`,在鎖外 | ✅ |
| A-M1:D-Bus 呼叫不阻塞 converge | 仍阻塞(沿用) | ⚠️ 正常情況可接受;殭屍情況見 m1 |
| A-M1 / B-M-1a:按裝置、不看全域 `Sessions()` | 沒採納 | ⚠️ 可接受,要寫理由(m3) |
| B-M-1c:每裝置時間戳、重啟後從哪算 | `devSince` + 重設 | ⚠️ 有洞(M1) |
| A-M1:claim 掃描頁保留連線等人確認 | F8:沒有使用者步驟 | ✅ 我讀原始碼確認 |
| A-M2 / B-1:Disconnect 的療效沒有證據 | F7(一次)+ 廣播不再等 provd 自己的計數 | ⚠️ 部分:證據未入 issue、缺生命週期列(m1、m8);升級處置沒做,我同意不做 |
| B-1-3 / A-M2:重現殭屍 | 「Not tested」 | ⚠️ 要寫試過什麼(m8) |
| A:respawn L80 對照臂撞上寬限 | §5-3 的通則 | ❌ 對這一臂不適用(M3) |
| B m-3:log 要能與 L80 分開 | 新增一行 | ✅(契約文件要補,m5) |
| A minor 3:退避與 log 限速 | 沒處理 | ❌(m1) |
| B-M-2:生命週期缺列 | 補了大部分 | ⚠️ 還缺(m1、m7) |

## 六、沒有查的

- F7 與 `ux/m1.log` 的原始內容(不在 repo / issue)。
- BCM43455 的 `le_states`(F-P41 仍是 ⚠️ 未實測);有殭屍時 kernel 是否接受 connectable 廣播。
- 現場是否有常駐的 sock client。
- Windows 端 provclient 的 BLE 流程(Hx)從連線到第一次寫 RX 的時間。
