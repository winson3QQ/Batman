# Review F — `329-n1-plan.md` v4(整份重審;重點:`bleSide` 的並行/順序、§5 harness 臂能不能照寫的跑)

審查對象:`docs/design/329-n1-plan.md`(v4,144 行),worktree `C:\src\Batman-b8`(`feat/329-b8`,程式未改)。
唯讀;沒有碰任何節點 / 手機 / 網路主機,沒有跑 ssh / adb。原型在 scratchpad 的副本上做,worktree 內只寫了這份檔案。

## 結論(verdict): APPROVE-WITH-CHANGES

產品改動(§3)我找不到錯:鎖序沒有死結,`Close` 與 `Connected=false` 兩種先後順序都收斂,有 `links` 條目的裝置在兩層(`liveLinks` 與既有的 `staleLinks` `:538-540`)都不會被切。我照 §3 在副本上做了原型,§5.1 的單元測試做法(`newBLE(nil, …)` + 手做 `*dbus.Signal` + 直接插 `links` + `bleLink.Close`)可行,五個變異對照有四個會讓對應的列 FAIL。兩個 MAJOR 都在測試:(1) §5.2 新臂的 t0「the new `adv withdrawn reason=connect` line」照寫的做不出來 —— `hold` 在 04 上至少造成兩次 connect(`pick` 的 `read_one` 一次、真正的 hold 一次),標記放在 hold 之前會抓到讀的那一行(rc 上假 FAIL),放在之後則沒有任何新行;(2) T2 的「logged once」照 §3 的寫法測不到 —— `liveLinks` 是純函式,標 `logged` / 印 log 在 `converge`,而 `converge` 沒有 `srv` 就會 nil deref;「只印一次」是唯一擋住「每 5 s 一行(12 行/分,超過 §4.4 契約的 10 行/60 s)」的東西,而且真機臂也驗不到它。另外「有 session 的 link 不會在 30 s 被切」這個 fail-secure 宣告在真機上沒有任何測項(沒有一個 harness central 會寫 RX),建議在已排定的 S20 步驟加 2 分鐘的檢查。其餘是 MINOR(下界 30 可能讀到 29、L80 `watch 8` 餘裕 2–3 s、`+110 s` 低估、§1 留著指向已刪段落的 `§5.5`、步驟順序文字)。全部是計畫文字 / 測試判定的修正,不需要新機制。

---

## 0. 我做了什麼 / 沒做什麼

✅ 驗過(附輸出)
- 整份計畫;`bluez.go` 全檔;`server.go` / `session.go` / `main.go` 相關段;`prov-provd-254.sh`、`prov-p2-central-254.sh`、`known-failures.sh`、`daily-validation.sh:310`、`ci.yml:141`、`254-p2-impl.md` §4.4、`app/lib/claim.dart`、`claim_recovery.dart`、`Keys.kt`。
- 原型:把 `feed/batman-prov/src` 複製到 scratchpad,照 §3 改 `bluez.go`(`devEnt`、`liveLinks`、`resetDevs`、`Close` 的條件式更新、`register()` 重數),加 `n1_test.go`(T1/T2/T3/T4/T5/T7/T8/T9 + 錯 sender 一列)。WSL `go1.26.4`、`GOFLAGS=-mod=vendor GOTOOLCHAIN=local`:

```
$ go1.26 vet ./cmd/batman-provd/            (無輸出)
$ go1.26 test -race -count=1 -v -run 'TestT|TestWrong' ./cmd/batman-provd/
--- PASS: TestT1T2 / TestT3 / TestT4 / TestT5 / TestT7T8T9 / TestWrongSenderIgnored
ok  	batman-prov/cmd/batman-provd	1.010s
```

- 變異對照(每次只改一處、跑完還原):

```
== M0 baseline                                   ok
== M1 Close does not refresh since               --- FAIL: TestT4   n1_test.go:76: T4 counted n=0
== M2 no age check (today)                       [build failed]  ← 我的變異讓 now 變成未使用,不算結果(❌ 沒重做)
== M3 Connected=true overwrites entry            ok              ← 沒有任何一列抓得到(見 m6)
== M4 Close writes unconditionally (T5 control)  --- FAIL: TestT5   T5 n=0 stale=[/org/bluez/hci0/dev_AA]
== M5 no union (double count)                    --- FAIL: TestT3   T3 n=1 stale=[...dev_AA]
```

⚠️ 推論(讀碼,沒有執行)
- §5.2 / §5.3 harness 臂的時間分析(從 central 腳本的 sleep 與 `run` 迴圈推的,沒有在節點上量)。
- F9「簽章不會跳使用者提示」:`Keys.kt:84-97` 沒有 `setUserAuthenticationRequired` / Biometric(grep 無結果),所以沒有提示的跡象;沒有在手機上看。

❌ 沒做
- F8(kernel `hci_sync.c:5651-5701`、BlueZ `adapter.c:8496-8519`):我在 WSL build 樹找了兩次沒找到檔案(find 深度不夠),沒有驗;B、C 兩位驗過。
- T6 沒寫進原型(與 T3 同一條程式路徑)。
- 沒有跑完整 `go test ./...`(只跑 `cmd/batman-provd`)。

---

## 1. 從現場看(先於作者的清單)

- 11-18 的事故(F1:04 上 S20 `Connected: yes`、沒有 session、廣播撤掉 40 分鐘):改動後 `devConn` 條目 30 s 過期 → 下一個 tick `register()` → `staleLinks()` → `Device1.Disconnect`(F7 證明當時這個呼叫清得掉)。救得回 ✅(F7 只有一次觀察,計畫有寫)。
- 我另外找的路徑:
  - **有 session 的 link 被誤切**(這個改動唯一會傷到使用者的退化):碼上不會(見 §2),但真機沒有測項 → M3。
  - **stale 條目 + `advOn == true`**(Disconnect 清不掉但 kernel 接受廣播):`converge` 什麼都不做,節點看得到 —— 這正是 §3 末段要的結果 ✅。同路徑的手機真的回來時 BlueZ 不再發 `Connected=true`,寫 RX 之前不被計數、廣播不撤;寫了 RX 就走 `link()` 的 `withdraw("connect")`(`:307`)✅。
  - **dbus 重啟而 bluetoothd 拿到同一個 unique name**:`:491` 不重設;殘留條目 30 s 自癒,表中那列一致 ✅。
- 重現:F1 是真機上抓到的一次(有 log / dumpsys),不是憑記憶;但「按需重現」沒試過,計畫照實寫了(§7 最後一行)。§1 表後那句「§5.5 is one attempt」是 v3 留下的 —— v4 的 §5.5 是全套 + S20,`hciconfig` 重現已刪 → m7。

## 2. 並行 / 順序(我的指定角度)

逐條對 `bluez.go`(行號是現在 main 的):

| 互動 | 結果 | 證據 |
|---|---|---|
| `Close`(fd watcher / session goroutine)對 `deviceChanged`(run 迴圈) | 兩者都只在 `b.mu` 下碰 `devConn`。先 `Connected=false` 後 `Close`:條目已刪,`Close` 不寫(T5 + M4 對照 FAIL ✅)。先 `Close` 後 `Connected=false`:`since` 被更新、隨後條目刪掉 ✅ | `:394-420`、`:688-729` |
| 鎖序 | `Close` 先 `l.mu` 再 `b.mu`,不巢狀;`link()` 只拿 `b.mu`;`converge` 拿 `b.mu` 讀完就放,log 與 D-Bus 都在鎖外。沒有死結 ✅(原型 `-race` 無報告) | `:294-313`、`:394-420`、`:731-735` |
| `register()` / `staleLinks()` 期間 | run 迴圈卡在裡面(最多 15 s),`devConn` 不會變(訊號在 channel 排隊),只有 `links` 會變(`link()` / `Close` 在別的 goroutine)。§3.3 的重數因此只看得到新的 `links` 條目 ✅;排隊中的 `Connected=true` 要等回來才處理,和今天一樣 | `:583-600`、`:657-680` |
| `link()` 在 `Accept` 回 nil 時 `l.Close()` | 會把現有條目的 `since` 更新(給新的寬限),但同一個 `Close` 也呼叫 Disconnect → 無害(D-m9;v4 沒寫這句,不影響) | `:294-313`、`:416-418` |
| `converge` 寫 `logged` | 這是 `devConn` 的**第四個寫入者**,§4 Ownership 只列了三個;要在 `b.mu` 下標、鎖外印 → 併入 M2 | 計畫 §3.2、§4 |
| 剛滿 30 s 時才寫 RX | `staleLinks` 在 Disconnect 前看 `links`(`:538-540`);檢查與 Disconnect 之間的窗是既有的,client 重連。F9 < 9 s,餘裕夠 ✅ | `:518-567` |

`liveLinks` 的呼叫點:`converge` 與 `register()` 都在 run 迴圈,沒有第二個 goroutine 讀 `logged` ✅。

---

## 3. 發現

### M1(MAJOR)§5.2 新臂的 t0 照寫的做不出來:`hold` 在 04 上不只一次 connect

- **情境**:臂是「02 `hold`s 04;從新的 `adv withdrawn reason=connect` 行(t0)到新的 `link without session for 30 s` 行(t1),30 ≤ t1 − t0 ≤ 37」。
- **證據**:`prov-p2-central-254.sh:155-167` —— `hold` 先跑 `pick`(= 掃描 + `read_one`:連上約 23–26 s、讀 STATUS / CTRL、`drop`),**然後**才再掃描、`connect $A`。依 F12,`read_one` 那次連線在 04 上也印 `adv withdrawn reason=connect`,drop 後印 `adv registered reason=disconnect`;之後真正的 hold 連線再印一次。`hold` 內層最多 3 次 connect,`hold02`(`prov-provd-254.sh:68-69`)外層再 2 次,所以新的 withdrawn 行是 2 到 8 行左右。
  - 標記(`hmark`)放在 `hold02` 之前:「新的 withdrawn 行」第一行是 `pick` 的讀 → t1 − t0 ≈ 26(讀)+ 3(drop)+ 11(掃描)+ 連線 + 30 ≈ 70 s 以上 → **rc 上假 FAIL**。
  - 標記放在 `hold02` 回來之後:hold 連線的 withdrawn 行在標記之前 → 沒有 t0。
  - 另外 `plog` 只會數行數(`grep -c`),取時間戳需要新的 helper;`c02 watch 70` 是阻塞的,所以判定只能事後從 `logread` 讀。
- **修法**(只改判定寫法):
  1. `hmark` 在 `hold02` 之前;`a=$(hold02)`;`c02 watch "$a" 70`;之後一次 `logread` 取標記後的 provd 行。
  2. t1 = 標記後**唯一**的 `link without session` 行(0 行 = 舊版的那一行固定 FAIL;≥ 2 行 = INVALID,表示 `pick` 的讀或失敗的 connect 自己超過 30 s,量到的不是 hold 連線)。
  3. t0 = t1 之前**最後一行** `adv withdrawn reason=connect`,且 t0 與 t1 之間沒有 `adv registered`(有 = INVALID)。
  4. 計畫裡把這四條寫出來,並寫明取時間戳的方式(`logread` 的行首時間 → 秒)。
- **負對照**:wsl.26 上 0 行 → 固定 FAIL 行(計畫已有);rc 上把 t0 改取「第一行」重跑一次應 FAIL,證明選行規則有作用(附在 harness PR)。

### M2(MAJOR)T2 的「logged once」照 §3 的寫法測不到;`converge` 是沒列出的第四個寫入者

- **情境**:§3.2 的 `liveLinks(links, devConn, now) (n, stale)` 是純函式;「對每個還沒 `logged` 的 stale 條目印一次」寫在 `converge`。§5.1 的事件序最後是「then `liveLinks` at a given time」,T2 要驗「stale, logged once」。
- **證據**:`converge`(`:731-741`)在 `name != ""` 時第一件事是 `b.srv.HealthOK()`;單元測試的 `bleSide` 是 `newBLE(nil, …)`,呼叫 `converge` 會 nil deref。所以照字面實作,T2 只驗得到 `stale` 清單,「只印一次」沒有任何測試:
  - 真機臂也驗不到:rc 上 stale 裝置在一個 tick 內就被切,最多 1 行;
  - 壞掉時的後果是真的:一個 stale 裝置排在另一個活 session 後面(§3「留到那個 session 結束」,最久 300 s 以上)時,`converge` 每 5 s 進一次 → 12 行/分,超過 `254-p2-impl.md` §4.4 的「同 reason 每 60 s 最多 10 行」。
- **修法**(不加機制,只是把標記放到測得到的地方):§3.2 指名一個在 `b.mu` 下跑的小函式(原型叫 `countLocked(now) (n int, fresh []dbus.ObjectPath)`:呼叫 `liveLinks`、把未 `logged` 的 stale 標成 `logged`、回傳這次要印的),`converge` 在鎖外對 `fresh` 印 log。T2 = 同一個 `bleSide` 在 +31 s 呼叫得到 1 個、+40 s 再呼叫得到 0 個(原型 `TestT1T2` 就是這樣,PASS)。§4 Ownership 的寫入者加上這個函式(`logged`)。契約那句「written once per device entry」改成「每個條目每次進入 stale 一次;`Close` 會重新計時」(`Close` 把 `logged` 設回 false,Disconnect 失敗時 30 s 後會再印一行,這是對的)。
- **負對照**:拿掉 `e.logged = true` → T2 的第二次呼叫回 1 個 → FAIL。

### M3(MAJOR,修法很小)「有 session 的 link 不會被切」在真機上沒有測項

- **情境**:§4 Security 的 fail mode:「a device with a `links` entry is never stale」。這是這個改動唯一會傷到合法使用者的退化方向(session 開著 30 s 被切)。
- **證據**:單元 T3 / T6 的 `links` 條目是手插的,不經 `link()`。§5.1 說「the device arm covers the first two(`link()` itself, `converge → register → staleLinks`)」—— 第一項不成立:`hold` / `read` / `watch` 都不寫 RX(`prov-p2-central-254.sh:112-175`),`prov-netjoin-254.sh:63`、`chain1-254.sh:168`、wbox `:112/:119/:229` 也只用 `read`;全套裡沒有一個 BLE central 會開 session。§5.5 的「S20 reads 04 from the app」session 只有幾秒(F9),碰不到 30 s。
- **修法**:不寫新 harness。在 §5.5 已排定的 S20 步驟加一項(約 2 分鐘):S20 開 04 的軟體更新頁(§2 自己說這頁會一直握著 session,`update_route.dart:28`)停 ≥ 90 s;判定 = 04 的 log 在這段期間沒有新的 `link without session` 行、沒有 `disconnected N stale link`、頁面沒有斷線。結果寫進產品 PR 的測試段。同時把 §5.1 那句改成「真機臂涵蓋 `converge → register → staleLinks`;`link()` 由 S20 的更新頁檢查涵蓋(人工)」。
- **附帶**:§3.3 的 `register()` 重數(`staleLinks` 之後再數一次)沒有任何測試涵蓋(單元跑不到 `register()`,真機臂的 central 不寫 RX)。它只把一個今天就存在、5 s 內自己修正的窗縮小。照「只做必要的修改」:要嘛留著並在「Not tested」寫明 ❌,要嘛拿掉。我傾向留(三行、鎖序相容,原型編得過),但要照實標。

### m1(MINOR)下界 30 可能讀到 29;時間戳是牆上時鐘

- `since` 在 `deviceChanged` 設;t0 那行要等 `converge` 跑完 `adapterOK()` 與 `UnregisterAdvertisement` 才印(`:602-615`),晚 `since` 幾十 ms 以上。t1 最早在 `since + 30`。`logread` 是整秒:t0 真實 11.01(`since` 10.97)、t1 真實 40.98 → 讀到 29。計畫只在上界算了取整(「1 s per timestamp rounding」)。安靜時 tick 與 `since` 鎖相(`time.After(5 s)` 從上一次 `converge` 結束起算,`:679`),所以通常是 30–31;但 `hold` 連線期間 BlueZ 會送別的 `Device1` 屬性變更(每個都跑一次 `converge`、重設 5 s),相位會跑掉。
- `logread` 的時間是牆上時鐘;計畫 §3 自己說節點時鐘會被 GPS / NTP 跳。臂跑的 70 s 內跳一次就是假 FAIL。
- **修法**:下界改 29(「< 29 = 沒有寬限」仍然成立:沒有寬限時是 0–5 s);t1 − t0 落在區間外且 04 的 log 在這段有時間跳動跡象時判 INVALID,或乾脆寫明「區間外先重跑一次並附兩次的 log」不行 —— 照規則 FAIL 要歸因,所以建議直接用 29 並在 PR 附 5 次實測的分佈。

### m2(MINOR)L80 control `watch 8` 的餘裕只有 2–3 s

- STILL 判定時的 link 年齡 = `hold` 回來時 0–16 s(F10)+ `hold02` 回傳與下一個 `c02` 的 ssh 建立 1–2 s + `watch` 8 s(迴圈每圈 `conn_state` + `sleep 1`,會多 1 s)≈ 最多 27 s;計畫寫「at most about 25」。N1 在 30–35 s 切。餘裕 2–3 s,02 的 bluetoothctl 一慢就 INVALID,而 INVALID 會讓整個 suite rc 2,每次都要歸因。
- **修法**(擇一):`watch 5`(control 要證的是「不殺 provd 時不會馬上掉」,kill 臂另有 `stale link` 行數與 pid 變更把關,鑑別力不靠這 3 s);或讓 `hold` 在 `HELD` 行印出「從 `conn_state` 第一次回 yes 起的秒數」,control 用它算剩餘時間。計畫已經要量 5 次,把「最大值 ≤ 22 s 才用 8,否則用 5」寫成判準。

### m3(MINOR)「the arm adds at most about 110 s」低估,lease 預算要用量的

- rc 上:`hold02` 一次約 40(pick)+ 17–27(掃描 + connect + 輪詢)s,`watch` 到 GONE 約 35 s,等 `adv registered` ≤ 20 s,`c02 read` 約 40 s → 約 150–160 s;wsl.26 上 `watch 70` 跑滿 → 約 180 s;`hold02` 第二次嘗試再加 60 s 以上。
- **修法**:計畫改成「約 3 分鐘,最壞約 5 分鐘」,harness PR 附 `boot-provd` 在 rc 與 wsl.26 的實際總秒數對 `lease 1500`(D-m5 要的就是這個數字,v4 只給了估計)。

### m4(MINOR)新臂:`watch` 自己會 drop;GONE 之後的檢查順序

- `watch` 在 GONE 與 STILL 兩條路都呼叫 `drop`(`:168-175`)。所以舊版路徑上 link 是 `watch` 放掉的,「every exit path runs `c02 drop`」只需要補 `hold02` 成功但 `watch` 沒跑完(ssh 逾時 `timeout 300`)那條。寫明即可。
- 舊版路徑「skips the dependent checks」之後仍然要做「04 回到一個 instance」的檢查 —— 它若失敗會是第二行 FAIL,known-failures 就不匹配(每一行都要對上),那是對的(真的殘留),但請在計畫寫一句,免得實作者把它也跳過。

### m5(MINOR)§6 步驟順序的文字

- 「rc image → 04 OTA → harness PR(arm FAIL on wsl.26 / PASS on rc)」:04 OTA 到 rc 之後就拿不到 wsl.26 的 FAIL(除非再降版)。順序應該是:harness 分支先在還是 wsl.26 的 04 上跑(FAIL + 既有臂的 5 次年齡量測)→ OTA rc(先問使用者)→ 同一個 harness 跑 PASS。寫清楚,省一次重燒 / 降版。

### m6(MINOR)「已存在的條目不動」沒有測試列

- §3.1:「`Connected` turns true for a path with no entry → new entry. An entry that exists is not touched.」原型變異 M3(改成無條件覆寫)所有列都 PASS。實務上 BlueZ 不會對已經 true 的屬性再發 true,而 `InterfacesAdded` 帶 `Connected=true` 之後接 `PropertiesChanged true` 的情況覆寫只會讓 `since` 晚幾 ms。
- **修法**(擇一):加一列(條目 `since` 手動往前挪 31 s,再送一次 `Connected=true` → 仍然 stale;覆寫時 FAIL),或把這條規則從 §3 拿掉(兩種行為都安全:覆寫只會多給寬限,而對手要讓 BlueZ 重發 true 就得真的斷線重連,那本來就會重新計時)。不要留一條沒有對照的規則。

### m7(MINOR)文字殘留與單元測試的時間

- §1 表後「§5.5 is one attempt」指向 v3 已刪的 `hciconfig` 重現;改成指向「Not tested」裡的現場人工檢查(飛航模式 / 走出範圍),並寫明它不擋 PR、由使用者決定何時做。
- §5.1 沒寫 T4 / T5 的「30 s 後 / 60 s 後」怎麼做:`Close` 與 `deviceChanged` 用 `time.Now()`,只有 `liveLinks` 收 `now`。原型的做法是「問的時間往後挪」(T4:`now + 29 s` / `+ 31 s`)與「把條目的 `since` 往前挪」(T5),不需要注入時鐘 ✅;請寫進計畫,免得實作時加一個 clock 介面。
- §5.1「each row first asserts the entry it expects exists」✅ 必要(原型的錯 sender 列證明訊號會被 `:691` 丟掉);T5 的中間步驟「`Connected=false` 之後條目不存在」也要斷言,否則 T5 可能因為別的原因 PASS。
- D-m9(`Accept` 回 nil 的 peer 反覆寫 RX 拿到新寬限,但同一個 `Close` 會 Disconnect)v4 的 §4 Security 沒寫;無害,補一句即可。

---

## 4. 事實查核(F1–F12 與 file:line)

| 項 | 結果 |
|---|---|
| F2 `:733`、`:772-776` | ✅ |
| F3 `:688-729`、`:691`、`:491`(只在 owner 名稱變了才重設,`:480-495`) | ✅ |
| F4 `link()` `:294-313`、`Close` `:394-420`(`:411-413` 刪、`:416-418` `go …Disconnect`)、watcher `:322-334` | ✅ |
| F5 `:583-600`、`:518-567`(3 輪 × 5 s、沒有年齡檢查、`:565` 不走 `logLimit`) | ✅ |
| F6 `:656-681` | ✅ |
| F8 | ❌ 我沒驗(找不到檔案);B / C 驗過 |
| F9 `claim.dart:335-370`、`:497-530`;`prober.dart:123` | ✅ 行號對;`:531` 附近 `signOwner` 在 msg1 之前,Keystore 金鑰沒有 user-auth 設定(`Keys.kt:84-97`,grep 無 `setUserAuthenticationRequired`)⚠️ 推論不會跳提示;`claim_recovery.dart` 的等待都在 msg1 之後(有 `links` 條目) |
| F10 `hold` `:155-167`、`read_one` `:112-124`(sleep 合計 23 s)、`prov-provd-254.sh:99-106 / 125-137 / 192-200`、`prov-netjoin-254.sh:63`、`chain1-254.sh:168` | ✅;「wbox encrypt-read arm(`:116-117`)」的行號是 central 腳本的,不是 wbox 腳本的,寫清楚 |
| F11 `server.go:835-845`、`main.go:88-100` | ✅ |
| F12 `prov-provd-254.sh:99-102` | ✅ |
| `ci.yml:141`、`daily-validation.sh:310`(在 `scripts/` 下)、`lease 1500` `:80`、`254-p2-impl.md` §4.4 契約句 `:227`、`p3-units.tsv:11` | ✅ |
| known-failures:suite 每一行 FAIL 都要對上、`NEVER_KNOWN` 字樣、到期日 | ✅ 固定字樣 `no 'link without session' line in 70 s` 不含那些字 |
| `IdleAnon 30 s` / `IdleAuthed 300 s`(`server.go:30-31`)、`session.go:280-295`、`:611-615` | ✅ |

## 5. 所有權 / 契約 / 生命週期

- **所有權**:`devConn`、`links`、廣播都只屬於 `bleSide`(`b.mu`);BlueZ 擁有 `Device1.Connected`,provd 只讀 + 請求 Disconnect。沒有雙擁有者 ✅。寫入者清單少了 `converge`(`logged`)→ M2。
- **契約**:新 log 行的寫者 / 讀者 / 何時 / 進 §4.4 ✅;「once」的精確語意 → M2。缺、舊、壞:狀態只在記憶體,沒有持久格式 ✅;訊號遺失 → 30 s 自癒 ✅。
- **生命週期表**:start / clean stop / restart(L80)/ 依賴重啟(bluetoothd、dbus)/ crash loop / 斷電 / OTA·rollback·降版(無儲存狀態,舊版 = 今天的行為)/ bcm2711 / bcm2710(註明不跑的原因)都有 ✅。install / first run:沒有列,但與 start 相同(無狀態),補半句即可。

## 6. 安全

- **遠端 BLE peer**:沒有新能力。一條閒置 link 讓節點變暗從「永遠」變成約 50 s;每 30 s 重連仍可壓住(§2 有寫)。讀 STATUS 不延長寬限(不碰表)✅。`Accept` 回 nil 的反覆寫入:拿到新寬限但同時被 Disconnect ✅。
- **本機非特權程序**:不能偽造 `Connected`(`:691` sender 檢查;原型 `TestWrongSenderIgnored` PASS)✅;沒有新的輸入(檔案 / 埠 / 設定鍵)。
- **被攻陷的 peer / 權限**:沒有新的 Disconnect 呼叫點,沿用 `staleLinks`;沒有路徑 / 檔案類 TOCTOU ✅。
- **自己的錯**:最壞的錯是切掉有 session 的 link —— 兩層保護都在碼裡,但真機沒有負向測試 → M3。
- **fail mode**:錯誤路徑都落在「照舊計數」或「重試」✅。
- **負向測試**:非擁有者 central(02)✅;「有 session 不被切」→ M3。

## 7. 先前審查的發現是否真的解掉

| 發現 | v4 狀態 |
|---|---|
| A-M1 / B-m3(兩張表不一致) | ✅ 一張表;T5 + 我的 M4 對照 FAIL |
| A-M2(單元測試只測純函式) | ✅ 做法可行(原型);剩「logged once」→ M2 |
| A-M3 / B-M3(L80、`read`、量 5 次、每條路徑 drop、#290 順序) | ✅ 大致;`watch 8` 餘裕 → m2;順序文字 → m5 |
| A-m1 / D-m1 / C-M1(Disconnect 清不掉的 log) | ✅ 照實寫(約 3 行/分,在契約內),`logLimit` 不改 |
| A-m2 / C-m5(`register()` 重數、reason) | ✅ 有寫;沒有測試 → M3 附帶 |
| A-m3、m4、m5、m7、B-m8(理由、單調時鐘、log 契約、表列、sock/BLE 互斥) | ✅ |
| B-M1(表錯列、session 中靜默的上限) | ✅ §2 寫 350 / 650 s |
| B-M2(沒有重現、50 s、F-P41) | ⚠️ 50 s ✅;F-P41 仍「not measured」(B 建議 rc 上機時順手讀 `le_states`,v4 沒排);重現仍未試,且留著錯的 `§5.5` 指向 → m7 |
| C-M2 / D-M1(年齡從 central 量不到) | ⚠️ 改成量 04 自己的兩行 —— 方向對,但 t0 選行照寫的做不出來 → M1 |
| C-M3(`hciconfig` 做不出來) | ✅ 拿掉,改人工檢查 |
| D-M2(`read` 不動) | ✅ |
| D-M3(更新頁握著 session) | ✅ §2 |
| C-m1…m6、D-m2…m8 | ✅(D-m5 的 lease 只有估計 → m3;D-m9 沒寫 → m7) |

## 8. 不必要的東西 / 缺的東西

- 不必要:沒有發現新的多餘機制。`register()` 重數是唯一「可有可無」的一段(見 M3 附帶)。「已存在的條目不動」是沒有對照的規則(m6)。
- 缺的:測得到的「只印一次」函式(M2);新臂的選行規則(M1);有 session 的真機負向檢查(M3)。

## 9. 發現一覽

| # | 級別 | 一句話 |
|---|---|---|
| M1 | MAJOR | 新臂 t0 選行:`hold` 至少兩次 connect,照寫的在 rc 上假 FAIL 或找不到 t0 |
| M2 | MAJOR | T2「logged once」測不到(`converge` 需要 `srv`);`converge` 寫 `logged` 沒列在 Ownership |
| M3 | MAJOR | 「有 session 的 link 不被切」真機沒有測項;§5.1 說真機臂涵蓋 `link()` 不成立;`register()` 重數沒有測試 |
| m1 | MINOR | 下界 30 會讀到 29;牆上時鐘跳動 |
| m2 | MINOR | L80 control `watch 8` 最壞約 27 s,餘裕 2–3 s |
| m3 | MINOR | 「+110 s」低估,lease 要附實測 |
| m4 | MINOR | `watch` 自己會 drop;舊版路徑的 instance 檢查不要跳 |
| m5 | MINOR | §6 順序:先在 wsl.26 跑 FAIL 再 OTA rc |
| m6 | MINOR | 「已存在的條目不動」沒有對照(變異 M3 全 PASS) |
| m7 | MINOR | `§5.5` 殘留指向;T4/T5 的時間做法、T5 中間斷言、D-m9 一句 |

BLOCKER:無。
