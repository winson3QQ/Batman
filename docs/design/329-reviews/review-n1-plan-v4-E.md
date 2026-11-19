# 審查 E — `329-n1-plan.md` v4(N1:provd 切掉連上 30 s 卻沒有 session 的 BLE 裝置)

審查對象:`docs/design/329-n1-plan.md` v4 整份(143 行),worktree `C:\src\Batman-b8`(`feat/329-b8`,尚無程式改動)。
方法:先自己從原始碼與現場情境推一遍,再讀 v2-A / v2-B / v3-C / v3-D 對照。全程唯讀,沒有碰任何節點、手機、網路主機。

## 結論(verdict):APPROVE-WITH-CHANGES

0 BLOCKER、2 MAJOR、9 MINOR。

產品改動(§3)我找不到錯:一張表(時間放在 entry 裡)、年齡只影響「算不算數」、切斷沿用既有的 `register()` → `staleLinks()`,沒有新的 Disconnect 呼叫點也沒有新 timer,是能解 F1 的最小改法。兩個 MAJOR 都在測試/harness:(1) 新真機臂的 t0 照字面寫法在 rc 上會量到 60 s 左右而假 FAIL,因為 `hold` 自己會先連一次再斷、再連第二次;(2) known-failures 條目對應的那一行 FAIL,正好也是「rc 壞了」會印的那一行,14 天內真的 regression 會被歸成 KNOWN。兩個都是小修改,不需要加新機制。

---

## 一、從現場看:這個改動救得回 11-18 的事故嗎

F1 的狀態 = BlueZ 說 `Connected: yes`、`links` 空、沒有 session、`advOn=false`。
- 今天:`bluez.go:733` `nlinks = len(b.links)+len(b.devConn)` = 1 → `:772-776` 永遠走「有連線」那支,`register()` 不會被叫到 → 永遠不廣播。✅(原始碼)
- 改後:entry 過 30 s → `n = 0` → 既有的 `!advOn` 分支 → `register()` → `staleLinks()` 對它呼叫 `Device1.Disconnect`(`:518-567`,不看年齡,F5 ✅)。F7 是同一個呼叫在事故當下的那個狀態清掉了它(一次觀察 ⚠️)。
- 所以救得回,而且不需要知道「為什麼沒收到斷線」。✅ 推論成立;真機只有 F7 一次觀察 + §5.2 的替身 central,計畫自己也標 ⚠️,標示正確。

會不會誤切合法使用者(現場最重要的反面):
- App 每個連線路徑都在數秒內寫 RX 或訂閱 TX(`link()` 的三個入口 `bluez.go:143` WriteValue、`:166` AcquireWrite、`:183` AcquireNotify)。有 `links` entry 的裝置在任何年齡都算數(§3.2),不會被判 stale。✅
- 計畫的兩個 ⚠️ 可以從原始碼關掉:
  - 「owner-key 簽章會不會跳使用者確認」:`app/` 裡 grep `BiometricPrompt` / `setUserAuthenticationRequired` / `local_auth` 都沒有結果 → 沒有綁使用者驗證的金鑰,簽章不會等人。✅(原始碼;不是真機量測)
  - 「Windows provclient 的 connect→第一次寫入沒量」:`tests/tools/provclient` 沒有任何 BLE 程式;Windows 端的 BLE client 是 `tests/tools/peer/blebridge.py:77-78`,`connect()` 之後立刻 `start_notify(TX)` → AcquireNotify → `link()`,連上就有 link。✅(原始碼)
- 握手上限 `HandshakeMax = 10 s`(`server.go:29`)、`IdleAnon = 30 s`:一個只訂閱不說話的裝置由 session 自己的限制處理,不靠這條規則。✅

## 二、事實與行號查核

| 項 | 結果 | 說明 |
|---|---|---|
| F2 | ✅ | `bluez.go:733`、`:772-776` 相符 |
| F3 | ✅ | sender 檢查 `:691`;`deviceChanged` `:688-729`;重設 `:491` |
| F4 | ✅ | `link()` `:294-313`;`Close` `:394-420`,`delete(b.links…)` `:412`,Disconnect 在 goroutine 內、不看結果 `:416-418`(只有 `conn != nil` 才呼叫);fd-watch `:322-334` |
| F5 | ✅ | `register` `:583-600`、`staleLinks` `:518-567`(3 輪 × 5 s,無年齡判斷) |
| F6 | ✅ | run loop;tick 是 `time.After(5 s)`(`:679`) |
| F7 | ⚠️ | session 觀察,無法由我核對;計畫已寫「一次」 |
| F8 | ✅ 函式層級 / ⚠️ 事件路徑 | 核心 6.6.138 `hci_abort_conn_sync`、BlueZ 5.72 `src/adapter.c` `disconnect_complete` 我讀到的位置是 `:8492-8514`(計畫寫 `:8496-8519`,差幾行,同一個函式)。注意:`disconnect_complete` 只對 SUCCESS 與 NOT_CONNECTED 標記斷線,其他 mgmt 錯誤直接 return(見 m7)。mgmt 事件那條路我沒有追。 |
| F9 | ✅ | `prober.dart:122-123`(8 s 到 msg2)、`claim.dart:335-370`、`update_route.dart:28`、`settings_page.dart:2` 相符 |
| F10 | ✅ 但少一句 | `hold` `:155-167`、`read_one` `:112-124` 相符。**沒寫的是:`hold` 一開始的 `pick` 會先做一次完整的 `read_one`(連線 + 斷線)**,見 MAJOR-1 |
| F11 | ✅ | `server.go:835-845`(`Sessions()` 不含 HTTP)、`main.go:88-100` |
| F12 | ✅ | `converge` 用 `devConn` 計數,無 session 的連線也會印 `adv withdrawn reason=connect`。(v3-D 相反的說法是錯的,計畫這裡是對的。) |
| `daily-validation.sh:310` | ✅ | 檔案在 `scripts/daily-validation.sh`,計畫少寫 `scripts/` 前綴 |
| `ci.yml:141` | ✅ | `go vet ./... && go test ./...` 在 `feed/batman-prov/src` |
| `254-p2-impl.md` §4.4 `:227` | ✅ | 「連線事件 log 同 reason 每 60 s 最多 10 行」在 `:224`/`:227` |

---

## 三、發現

### MAJOR-1 新真機臂的 t0 沒有定義清楚;照字面在 rc 上會假 FAIL

**情境。** §5.2:「02 `hold`s 04. On 04, from the new `adv withdrawn reason=connect` line (t0) to the new `link without session for 30 s` line (t1): 30 ≤ t1 − t0 ≤ 37」。

`hold` 不是「連一次」:
- `scripts/node/prov-p2-central-254.sh:156` `hold` 先呼叫 `pick`,`pick` 內(`:133`/`:137`)會跑 `read_one`:**完整連線、睡 8+2+1+2+1+8+1 = 23 s、斷線**(`:112-124`)。
- 之後 `:160-166` 才是真正要 hold 的那次連線,最多重試 3 次;`pick` 自己最多掃 5 輪;`hold02`(`prov-provd-254.sh`)再包 2 次。

所以一次成功的 `hold`,04 的 log 在 hmark 之後**至少**有兩組:
```
adv withdrawn reason=connect      ← pick 的 read_one(t≈0)
adv registered reason=disconnect  ← read_one 斷線(t≈23–26)
adv withdrawn reason=connect      ← 真正的 hold(t≈35–45)
link without session for 30 s     ← t≈65–80
```
「the new `adv withdrawn reason=connect` line」若取 hmark 後第一行(`plog` + `head -1` 是最自然的寫法),t1 − t0 ≈ 65–80 s → 「over 37 = §2 的宣稱錯了」→ **rc 上 FAIL**。若 02 的 bluetoothctl 重試過,組數更多。

**證據。** 上列行號;F12 已證明無 session 的連線也印 withdraw 行。⚠️ 我沒有在真機跑(唯讀審查),時間是從 sleep 加總推的。

**修法。** 把 t0 寫成可執行的定義:t0 = `link without session` 那一行**之前最後一個** `adv withdrawn reason=connect`,且兩者之間不得有 `adv registered`(有 = 量錯對象,INVALID)。同時斷言 hmark 之後 `link without session` **剛好一行**(順便是「只印一次」在真機上的證據,見 m3)。另外把 F10 補上「`hold` 先做一次 `read`」這個事實,因為它也影響 m2 的時間預算。

### MAJOR-2 known-failures 條目會把 rc 的真 regression 歸成 KNOWN;移除條目的步驟與 #290 衝突

**情境。** §5.2/§5.4:舊 image 上新臂只印一行固定的 `no 'link without session' line in 70 s`,並給一條 14 天的 known-failures。但這一行**同時也是**「rc/新 image 的 N1 壞了(grace 沒生效、log 行改字、converge 沒走到)」會印的那一行。`scripts/dv/known-failures.sh` 的規則是 suite 裡每一行 FAIL 都對得上未過期條目就算 KNOWN → 在條目存在的 14 天內,rc 與 pin bump 後的出貨 image 上這個 regression 是 KNOWN 而不是 FAIL。這正是新檢查最該有鑑別力的期間(§5.5 的 rc 全套、pin bump 驗證)。

**證據。** 本 repo 既有做法不是這樣:`scripts/dv/prov-p3-verbs-254.sh:50-55`(「pre-P3 只用來說名單上且沒有 feature marker 的版本;其他一律是 plain FAIL」)、`scripts/validation-known-failures.txt` 最後一條(SD6:regex 綁版本字串,且註明其他 SD6 FAIL 都是 NEW)、`scripts/dv/pre-team-status-versions.txt` / `pre-p3-versions.txt`。

**修法。**(沿用既有慣例,不是新機制)
1. 固定那一行只在「04 的版本在 pre-N1 名單上(或沒有 feature marker)」時印,例如 `pre-N1 image (<version>)`;其他 image 缺那一行就印另一個文字(plain FAIL,不在 known-failures)。known-failures 的 regex 只對得上前者。
2. §6 寫「product PR … removes the known-failures entry after the pin bump」有兩個問題:(a) 測項只有一套(#290):`scripts/validation-known-failures.txt` 是 harness,產品 PR 不碰;(b) 時序上 pin bump 在產品 PR merge 之後,產品 PR 不可能「在 pin bump 之後」移除它。改成:pin bump 後由 harness PR 移除條目,#329 開到那時(§5.4 已這樣寫,§6 要跟它一致)。做了第 1 點之後,條目留著也不會遮到新 image,移除只是清理。

### m1(MINOR)下限 30 s 會偶爾讀到 29

`since` 在 `deviceChanged` 收到 `Connected=true` 時記;t0 那一行是之後 `converge` → `withdraw("connect")` 做完 D-Bus 往返(UnregisterAdvertisement 等)才印,差 δ(數十到數百 ms)。t1 在 `since + 30 s` 之後的第一個 tick 印。真實的 t1 − t0 ≥ 30 − δ;logread 時間戳截到 1 s,所以顯示值可能是 29。計畫的「+1 s per timestamp rounding」只加在上限。
另外 logread 是牆上時鐘(計畫 §3.1 自己說 GPS/NTP 會讓它跳):差值為負或離譜時應判 INVALID,不是 FAIL(`rpa` unit 已有 86400 換日處理可沿用)。
**修法:** 下限寫 ≥ 29 並寫明原因;差值 < 0 或 > 某個明顯不合理的值 → INVALID。

### m2(MINOR)「the arm adds at most about 110 s」低估

`hold` ≈ 掃描 15 + `read_one` 23–28 + 掃描/連線/輪詢 ≈ 17–26 → 約 60 s;等 t1 與 `watch 70` 最多 70 s;最後的 `c02 read` ≈ 掃描 15 + 28 ≈ 43 s。PASS 路徑約 150 s,FAIL 路徑(等滿 70 s)約 135 s,02 重試再加。`lease 1500`(`prov-provd-254.sh:80`)與 `daily-validation.sh:310` 的描述、central 的 270 s watchdog / `c02` 的 `timeout 300` 都要用量到的數字對一次(`watch 70` 單次呼叫在 270 s 內 ✅,但別把 hold+watch 併成一次呼叫)。⚠️ 推算,未實跑。

### m3(MINOR)「logged once」照 §5.1 的寫法測不到

T2 寫「stale, logged once」,但測試只呼叫 `liveLinks`(純函式);「對每個未 `logged` 的 stale entry 印一次並設 `logged`」那一步寫在 `converge` 裡(§3.2),而 `converge` 需要 srv 與 bus(§5.1 自己說不涵蓋)。結果:拿掉 `logged = true` 或拿掉 `Close` 裡的 `logged = false`,T2/T4 都還是 PASS = 沒有負向對照。
**修法:** 把「標記並印」做成一個小函式(吃 stale 清單、用 `b.logf`),`converge` 呼叫它;T2 呼叫兩次斷言只印一行,T4 斷言 `Close` 之後會再印一次。真機面由 MAJOR-1 的「剛好一行」補上。順帶:測試手工建的 `bleLink` 要有 `gone` channel(`Close` 會關它,`:394-420`),計畫可加一句。

### m4(MINOR)`register()` 裡的重新計數沒有測試、沒有負向對照

§3.3 的 recount(v2-A m2 要求的)在 §5 沒有任何一列涵蓋:單元測試明寫不含 `register`,真機臂也不會在 `staleLinks` 的 15 s 窗內寫 RX。拿掉它所有測試照過。它防的是「stale 裝置自己在被切的那幾秒寫了 RX → 帶著活 link 註冊廣播 → 下一輪又 withdraw」的一次廣播抖動(廣播關著時別的裝置連不進來,所以只可能是它自己),今天就存在、對 F1 無關。
**修法(擇一):** (a) 把「`staleLinks` 之後還要不要註冊」抽成吃 `(links, devConn, sessions, now)` 的純判斷並加一列單元測試;或 (b) 在 §5「Not tested」明列 ❌。不要兩邊都不寫。

### m5(MINOR)負向對照寫死 wsl.26;§6 的順序拿不到舊版 FAIL

§4 生命週期表與 §5.4/§6 寫「FAIL on wsl.26」。交接紀錄裡 02 已重燒 wsl.29,04 現在跑哪一版要以真機為準 ⚠️(我不能上機查)。寫成「04 在 OTA 前跑的版本」並把版本字串記進 PR。
另外 §6 的順序是「rc image → 04 OTA → harness PR(arm FAIL on wsl.26 / PASS on rc)」:OTA 之後 04 已經不是舊版,舊版 FAIL 那一跑必須在 OTA **之前**取,或寫明用 A/B 回退去取。把順序寫清楚。

### m6(MINOR)`read` 離 grace 只有約 4–7 s,而 `read` 臂沒有 INVALID 防護

`read_one` 的連線活 23–26 s(F10),02 的 bluetoothctl 慢一點就會碰到 30 s。§5.3 的 INVALID 防護只加在 hold 臂;`read` 的使用者很多(`prov-netjoin-254.sh:63`、`chain1-254.sh:168`、rpa、wbox…)。碰到時 `read` 會以不相干的理由 FAIL,歸因要花時間。
**修法:** 不必改每個臂:在 `c02 read` 的包裝(或 `pr_result` 前)加一個共用檢查,「這個 unit 期間 04 出現新的 `link without session` 行且不是新臂自己」→ 在結果上加註(INVALID 或至少一行 note)。§5.3 的「量 5 次取最大」保留,並寫下餘裕門檻(例如最大值 > 27 s 就要處理)。

### m7(MINOR)生命週期「Disconnect does not clear the device」一列只講了一半

表寫「dark; retried each tick, 3 log lines a minute」。這只在 `RegisterAdvertisement` **被拒**時成立(§3 末段自己有寫條件)。若 BlueZ 接受註冊(F-P41 未量 ⚠️),`advOn = true`,之後沒有任何東西再對那個裝置重試,直到下一次 `rpa_timeout`(930–1020 s)重新 `register()` 才再跑一次 `staleLinks`(又多 15 s 無廣播)。這個分支其實是好結果(節點看得到了),但表要兩個分支都寫。同一列可補一句:BlueZ `disconnect_complete` 對 SUCCESS / NOT_CONNECTED 以外的狀態不標記斷線(`adapter.c:8492-8514`),那就是「清不掉」的具體入口之一。

### m8(MINOR)還有一處引用 `bluez.go` 行號

§5.3 只列 `scripts/dv/data/p3-units.tsv:11`。`tests/tools/peer/blebridge.py:16-17` 的註解也引用 `bluez.go:771-774`。它在 `tests/` 下(不是 harness 測項),跟著產品 PR 一起改即可;列進 §6。

### m9(MINOR)文字

- §5.2 `daily-validation.sh:310` → `scripts/daily-validation.sh:310`。
- §4 Security 與 F9 的兩個 ⚠️ 可依第一節改成 ✅(附行號)。
- §4 Contracts「written once per device entry」:`Close` 會把 `logged` 設回 false,所以是「每個 entry 每次變成 stale 一次」;契約文字照這個寫,`254-p2-impl.md` §4.4 也用同一句。
- §5.2「Every exit path runs `c02 drop`」:02 的 `watch` 在 GONE 與 STILL 兩種結果都已經自己 drop(central `:168-175`),多一次無害,但「one instance」的檢查要等 `adv registered` 之後再看,否則會撞上 `staleLinks` 還在跑的 15 s。

---

## 四、介面、擁有權、生命週期(整份看)

- **擁有權** ✅:`devConn`(含 `since`/`logged`)、`links`、廣播都只有 `bleSide` 在 `b.mu` 下寫;`Close` 只改既有 entry 的兩個欄位,不新增不刪除。沒有第二個寫入者。`staleLinks` 在鎖外呼叫 Disconnect(既有),期間 `deviceChanged` 可以照常刪 entry,不衝突。
- **`Close` 更新 `since` 是必要的** ✅:不更新的話,每個超過 30 s 的 session 結束時,在 Disconnect 生效前的那一兩個 tick 都會被判 stale → 多印 `link without session` 與 `disconnected N stale link(s)`,既有 harness 斷言會壞。它不給對手任何東西:`Close` 一定會呼叫 Disconnect,而且有 link 的裝置本來就算數。
- **HTTP session 不擋切斷** ✅:`Sessions()` 不含 HTTP(`server.go:835-845`)。
- **沒有找到的洞**:我試著找「stale 裝置存在、`advOn` 為 true、卻沒人處理」的路徑,只有 m7 的那個分支(而那是節點可見的好結果)。也試了「signal 遺失 → entry 留著」:過 grace 後走 stale 路徑自癒,計畫寫的對。
- **生命週期表**:路徑齊全;要改的是 m7 那一列與 m5 的版本名稱。bcm2710 標「不跑」附理由 ✅(2026-10-23 決定)。

## 五、安全(逐 actor)

- **遠端 BLE 對手**:今天連一次就讓節點永遠隱形;改後要每 30 s 重連一次才能維持,計畫 §2 已明寫不處理 ✅。沒有新的輸入、沒有對手能累積的狀態(一張表,大小 = BlueZ 的裝置清單)✅。對手不能讓別人的 session 被切:有 `links` entry 的裝置永不 stale ✅。
- **本機非特權程序**:`Connected` 只來自 sender 檢查過的 BlueZ unique name(`:691`),偽造不了;provd 的 D-Bus 權限沒有擴大(本來就呼叫 `Device1.Disconnect`)✅。單元測試自己設 `bluezName`/`Sender`,所以 `:691` 的檢查在測試裡仍然生效(v3 C-m6 已解)✅。
- **被入侵的 peer(已 claim 的手機)**:沒有新能力;它本來就能開 session 佔住廣播。
- **自己的錯**:主要風險就是 MAJOR-1(假 FAIL 後被誘導去放寬門檻)與 MAJOR-2(真 FAIL 被歸成 KNOWN)。
- **fail mode** ✅:錯誤路徑都落在「仍算數」或「重試」,往「不可見」的方向失敗、不往「切掉活 session」失敗;理由成立。
- **負向測試**:§4 寫「用非擁有者 central 的真機臂」。那是功能臂,不是攻擊被擋的證明;這個改動沒有新增攻擊面,所以我接受,不列為發現。

## 六、先前審查的發現是否真的解了

| 來源 | 發現 | 狀態 |
|---|---|---|
| v2-A M1 | 兩張表不一致、孤兒時間戳 | ✅ 一張表;`:412` 只寫既有 entry;T5 是對照 |
| v2-A M2 | 單元測試只測純函式 | 大部分 ✅(依事件順序驅動寫入點);「只印一次」仍測不到 → m3 |
| v2-A M3 / v2-B MAJOR-3 | L80 對照臂、`read` 未列、#290 順序 | ✅ `watch 8`、kill 臂看 pid、`read` 列入 F10、順序有 known-failures;殘留 → MAJOR-2、m5、m6 |
| v2-A m1 / v2-B MAJOR-1、2 | Disconnect 清不掉的路徑、時間上限、未重現 | ✅ 有列、上限約 50 s、明寫沒重現;表只寫一個分支 → m7 |
| v2-A m2 | 第 30 秒才寫 RX 仍註冊廣播 | ✅ recount;沒有測試 → m4 |
| v2-A m3 / v2-B MINOR-8 | stale + 活 session、sock | ✅ §3 末段、F11、T7 |
| v2-A m4 | 單調時鐘 | ✅ §3.1 |
| v2-A m5 / v2-B MINOR-4 | log 契約、文字不含 dropping | ✅;契約用字 → m9 |
| v2-B MINOR-1、2 | F1 沒寫「無 `connection ble`」、F3 少 `:491` | ✅ 都補了 |
| v3-C M1 / D-m1 | `logLimit` 單槽會遮掉正常重複 | ✅ 不改 log 程式;3 行/分在契約內 |
| v3-C M2 / D-M1 | central 報不出連線年齡 | 方向 ✅(改量 04 自己的 log);t0 定義 → **MAJOR-1** |
| v3-C M3 | image 沒有 `hciconfig` | ✅ 拿掉,改列現場手動項(不擋 PR) |
| v3-D M2 | 不要動 `read` | ✅;餘裕 → m6 |
| v3-D M3 | 更新頁今天就保持 session | ✅ §2 寫 350 s / 650 s(讀程式,非量測,已標) |
| v3 minors(C-m4/m6、D-m2/m6/m9) | 直接插 link、sender、unit 名稱、`resetDevs`、`Close` 更新的理由 | ✅ |

v3-D 說「無 session 的連線不會印 `adv withdrawn reason=connect`」是錯的(見 F12 查核),計畫沒有照它改,是對的。

## 七、不必要 / 缺少的機制

- 不必要的:沒有發現。recount(§3.3)對 F1 不是必要的,但它是前一輪要求的、成本一行;留著可以,只是要有測試或明列未測(m4)。
- 缺少的:沒有需要新增的產品機制。要補的都在測試的定義(MAJOR-1、m1、m3)與 harness 的歸類(MAJOR-2)。

## 八、我做了什麼、沒做什麼

- ✅ 讀完計畫全文;逐行核對 `bluez.go`(783 行)、`server.go`/`session.go`/`main.go` 相關段、`prov-p2-central-254.sh`、`prov-provd-254.sh`、`prov-254.sh`、`known-failures.sh`、`validation-known-failures.txt`、`prov-p3-verbs-254.sh`、`254-p2-impl.md` §4.4、app 的連線路徑、`blebridge.py`;在 WSL 讀了核心 `hci_abort_conn_sync` 與 BlueZ `disconnect_complete`。
- ⚠️ MAJOR-1 與 m2 的時間是從腳本的 sleep 加總推出來的,沒有真機數字。F8 只核到函式層級。04 目前的版本(m5)沒有查。
- ❌ 沒有跑 `go vet` / `go test`:這台的 Git Bash 與 `C:\Program Files\Go` 都找不到 `go`,我沒有再去 WSL 找(目前沒有程式改動,基準結果對這份審查沒有鑑別力)。
- ❌ 沒有碰任何節點、手機、ssh、adb(審查條件)。

## 九、判定

**APPROVE-WITH-CHANGES。** 產品改動(§3)可以照寫的做。動 harness 之前先改 MAJOR-1(t0 = stale 行之前最後一個 withdraw 行、其間不得有 register、stale 行剛好一行)與 MAJOR-2(固定 FAIL 行只給 pre-N1 名單上的版本;條目由 harness PR 在 pin bump 後移除)。MINOR 以文字與測試定義為主,可在同一版一起改;改完不需要為這些再加任何機制。
