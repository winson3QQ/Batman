# Review C — `329-n1-plan.md` v3 (N1: 30 s 內沒開 session 的 BLE 連線不算 link)

審查者:獨立審查 C(只讀;沒有改任何檔、沒有碰節點、沒有 ssh/adb、沒有跑測試)
審查對象:`docs/design/329-n1-plan.md`(v3,整份),並對照 `329-reviews/review-n1-plan-v2-A.md`、`-B.md`
日期:2026-11-18

**Verdict: APPROVE-WITH-CHANGES** — 0 BLOCKER / 3 MAJOR / 6 MINOR。
核心機制(單一 `devConn` map + `liveLinks` 純函式 + 30 s grace + `register()` 內重算)是最小且正確的;三個 MAJOR 都在「log 限流」與「測試怎麼量、怎麼做」,不在機制本身。改完文字即可實作,不需要新機制。

---

## 0. 我做了什麼 / 沒做什麼

- ✅ 讀完整份計畫、v2 兩份審查、`bluez.go` 全檔(784 行)、`main.go`、`provd/server.go` 相關段、`prov-p2-central-254.sh` 全檔、`prov-provd-254.sh` 1–260 行、`validation-known-failures.txt`、`254-p2-impl.md` 相關列、`ci.yml`、app 端 4 個檔的引用行。
- ✅ 在 WSL 唯讀查 kernel 6.6.138 `net/bluetooth/hci_sync.c` / `hci_core.c` / `drivers/bluetooth/hci_bcm.c`、BlueZ 5.72 `src/adapter.c` / `device.c` / `main.c`、firmware `.config` 與已建好的 rootfs 內容。
- ❌ 沒讀:`provd/session.go`、`prov-p2-254.sh`(H3 judge)、`prov-provd-254.sh` 261–281 行、`prov-provd-wbox-254.sh` 只看了 grep 結果、godbus 內部。
- ❌ 沒有任何真機證據;F1、F7、「< 9 s」這類量測我無法從 repo 驗證(下表標 ⚠️)。

---

## 1. 事實查核(F1–F11 與 file:line)

| 項 | 結果 | 證據 / 備註 |
|---|---|---|
| F1 | ⚠️ 無法從 repo 驗證 | 是 session/issue 的現場證據;「沒有 `connection ble` 行」這句(v2 B-MINOR-1)已補進去 ✅ |
| F2 | ✅ | `bluez.go:54` `devConn map[dbus.ObjectPath]bool`;`converge` 計數 `:733`;分支 `:772-776` |
| F3 | ✅ | `deviceChanged` `:688-729`,sender 檢查 `:691` |
| F4 | ✅ | `staleLinks` `:518-567`(conn 為 nil 直接返回;3 輪 × 5 s;log 無限流 `:565`);呼叫點 `register()` `:590` 與 `converge` `:743` |
| F5 | ✅ | `provd/server.go:30-31` `IdleAnon = 30 s` / `IdleAuthed = 300 s`;`Sessions()` `:835-845` |
| F6 | ✅ | `bleLink.Close` `:394-420`;`watch` `:322-334`(HUP 在 fd goroutine 上呼叫 Close) |
| F7 | ⚠️ 無法從 repo 驗證 | 現場量測 |
| F8 | ✅(行號差 1) | `hci_abort_conn_sync` 在 `hci_sync.c:5651-5701`(計畫寫 5650);BlueZ `disconnect_complete` `adapter.c:8496-8519`;`DISCONNECT_TIMER 2`(`device.c:69`) |
| F9 | ✅ 原始碼部分 / ⚠️ 量測部分 | `prober.dart:123` 8 s 預算;`claim.dart:335-370`、`:497-530` 無使用者步驟;「實測 < 9 s」是 ⚠️ |
| F10 | ✅ | `prov-netjoin-254.sh:63`、`chain1-254.sh:168` 都用 central |
| F11 | ✅ | `main.go:88-100` sock / BLE 互斥 |
| `254-p2-impl.md` 引用 | ✅ | log 契約 `:227`、stale-link 清點 `:224`、F-P17 `:40`、F-P41 `:64`(le_states 仍是未測 ⚠️)、L80 `:294` |
| `ci.yml:141` | ✅ | `go vet ./... && go test ./...`;`:147` 另以 `-tags prov_test`、root 跑 |

**錯的只有一處小行號(F8 5650→5651)。** 沒有發現事實錯誤的 F。

---

## 2. v2 findings 是否真的解掉

| v2 finding | v3 處理 | 判定 |
|---|---|---|
| A-M1 兩個 map / 孤兒時間戳 | 單一 `devConn map[path]*devEnt{since, logged}` | ✅ 解掉。goroutine 順序我逐一推過(見 §4) |
| A-M2 單元測試只測純函式 | T1–T8 含 `deviceChanged`、`Close`、`register` 重算 | ✅ 可行性成立(§5),但 `link()` 本身沒被跑到(MINOR-6) |
| A-M3 L80 對照、`read`、時間、離開時 drop | `watch 15`→`watch 8`、`read` 縮短、INVALID 規則 | ⚠️ 部分:見 MAJOR-2、MINOR-1、MINOR-2、MINOR-3 |
| A-m1 stale log 洪水 | 改走 `logLimit` key `stale` | ❌ **沒解,而且讓既有的去重也壞掉** → MAJOR-1 |
| A-m2…m8 | 文字已改 | ✅ |
| B-MAJOR-1 生命週期列錯、session 中靜默斷線、上界 | §4 矩陣重寫、§2 寫明 ~50 s 上界與不涵蓋 authed session(300 s) | ✅ |
| B-MAJOR-2 沒有重現、~50 s、F-P41 | §5.5 用 `hciconfig hci0 down` 在 02 重現 | ❌ **照寫的做不出來** → MAJOR-3 |
| B-MAJOR-3 `read`、L80 對照、kill arm 鑑別力、#290 順序、量測區間 | §5.2–§5.4 | ⚠️ 量測區間照寫的量不到 → MAJOR-2;其餘 ✅ |
| B-MINOR-1…9 | 文字已改 | ✅ |

---

## 3. Findings

### MAJOR-1 — §3.4:`logLimit` 只有一個 `lastWhy` 槽,加入 `stale` key 之後兩行互相打掉,等於不限流;正常情況反而永久吞掉後續的 stale 行

**情境(正是 §3.4 想處理的那個)**:Disconnect 清不掉 + kernel 拒絕 advertise(F-P41 的組合)。每個 tick:
1. `staleLinks` → `logLimit("stale", "disconnected 1 stale link(s)")`
2. `register()` 失敗 → `logLimit("register", "adv register failed …")`

**證據** `bluez.go:617-625`:

```go
func (b *bleSide) logLimit(key, line string) {
    b.mu.Lock()
    same := b.lastWhy == key+line
    b.lastWhy = key + line
    b.mu.Unlock()
    if !same { b.logf("%s", line) }
}
```

`lastWhy` 是單一字串,現有 key `bus` / `app` / `register` 共用。stale 與 register 交替寫入 → 每次 `same == false` → **兩行每個 tick 都印**。今天 `adv register failed` 的去重是有效的,改完之後連它也失效。也就是 v2 A-m1 的洪水沒有解,還多了一行。

**反方向的副作用**:advert 註冊成功的正常路徑上沒有別的 key 插進來,所以相同的 `disconnected 1 stale link(s)` 第一次之後**永遠不再印**(這是去重,不是限流)。`254-p2-impl.md:224` 的 log 契約是「每次清點都有這行」;現場第二支手機走掉時 log 就沒有紀錄了。

**對 harness 的影響(任務指定要查)**:`scripts/` 裡只有 `prov-provd-254.sh:129-133`(L80 kill arm)grep `disconnected [0-9]* stale link`。那是 kill 後的新 provd 行程,`lastWhy` 是空的,所以那行仍會出現 → ✅ 不會壞。但同一行程內第二次以後的清點行會不見,日後任何在同一行程生命期內 grep 第二次的檢查都會假 FAIL。

**修法(不是新機制,是把現有的做對)**:`lastWhy` 改成每個 key 一個值(`map[string]string`),或 stale 用獨立欄位並在「stale 數回到 0」時清掉,讓下一次事件再印一次。
**負對照**:單元測試餵序列 `stale,register,stale,register` → 預期 2 行;單槽實作得到 4 行(FAIL)。再加一列:stale → (清乾淨) → 另一次 stale → 預期 2 行。

---

### MAJOR-2 — §5.2:「GONE 時 link 年齡 25–55 s」照現在的 central 腳本量不到;照字面實作會在 rc 上假 FAIL

**證據**:
- `prov-p2-central-254.sh:168-175` `watch` 的秒數從**它自己開始**算(`t0=$(up)`)。
- `:155-167` `hold`:掃描 11 s → connect → `sleep 6` → 最多再 poll 10 s;只印 `HELD <addr> connected=…`,**沒有任何時間戳**。
- 所以 watch 開始時 link 已經 ≈ 6–18 s(加上兩次 ssh 往返),且這個值沒被記下來。

**推算**:provd 在 link 年齡 ≈ 30 s 判定過期,加上 converge tick 與 Disconnect 往返 ≈ 30–38 s 斷線 → `watch` 看到的 n ≈ **14–32 s**。
- 若實作者把 `watch` 的 n 直接拿去比 25–55 → rc 上經常 FAIL(假 FAIL)。
- 若要量真正的年齡 → 需要改 central 腳本(`hold` 印 uptime、`watch` 印 GONE 時的 uptime),但計畫沒寫這個改動,而 central 是 7+ 個 suite 共用的 verb(#290:harness 改動要先獨立 PR)。
- 另外 `watch` 的時長必須 ≥ ~50 s 才看得到 GONE;計畫沒有寫這個 arm 的 watch 參數。

**25–55 這個窗本身對不對**:以真實年齡來說下界 25 太鬆(grace 是 30,早於 30 斷線就是 bug,25 會放過「grace 被算短 5 s」),上界 55 對 §2 的 ~50 s 上界合理。問題不在數字,在於量測點。

**修法(擇一,寫進 §5.2)**:
- (建議)**以 04 自己的 log 判定 grace**:同一份 logread 裡 `adv withdrawn reason=connect` 到 `link without session for 30 s`(或計畫定的那行)的時間差應在 30–38 s;再加 central 端「watch 60 內出現 GONE」當黑箱佐證。兩邊各判各的,不需要跨機對時,也不用改 `hold`。
- 或:`hold` 印 connect 當下的 02 uptime、`watch` 印 GONE 當下的 uptime,窗改為 30–55,並在計畫寫明誤差來源(±poll 間隔)。這是 central 腳本的改動,要列進 §5.3 的 harness PR。

**另外兩點要寫清楚**:
- unit 名稱是 `boot-provd`(計畫寫 "boot");它只在 release image、lease 1500 下跑,新增 ~60 s 要確認 lease 夠。
- 舊 image(wsl.26)上這個 arm 必須**只吐一條固定文字的 FAIL 行**。`validation-known-failures.txt` 是逐條 FAIL 行比對 ERE,suite 內任何一條沒對到整個 suite 就算 NEW;如果 FAIL 行帶秒數或同時連帶讓後面的檢查 FAIL,known-failures 條目就蓋不住。

---

### MAJOR-3 — §5.5:`hciconfig hci0 down` 在 02 上做不出來;替代做法不是「靜默斷線」;副作用沒列

**(a) 工具不存在。** ✅ 已查:
- `/home/yello/firmware-2710/.config`:`CONFIG_PACKAGE_bluez-daemon=y`,`bluez-utils` 未選。
- 已建好的 rootfs(兩個 target)只有 `bluetoothctl`、`bluetoothd`;沒有 `hciconfig`、`btmgmt`、`hcitool`,也沒有 `rfkill` 執行檔(只有 `/etc/rc.button/rfkill`)。
- `prov-p2-central-254.sh:5` 自己的註解:「02 has no btmgmt」。

**(b) 能用的那個指令語意不同。** `bluetoothctl power off` 走 mgmt SET_POWERED → `hci_power_off_sync`(`hci_sync.c:5735-5762`)→ `hci_disconnect_all_sync(HCI_ERROR_REMOTE_POWER_OFF)`,是**乾淨的 LL terminate**,04 會立刻收到斷線事件 → 重現不到 N1 要修的症狀,會得到「修之前也 PASS」的無效對照。
真正靜默的是 HCIDEVDOWN / rfkill 路徑:`hci_dev_do_close` → `hci_dev_close_sync`(`hci_sync.c:5235`,只跑 vendor shutdown,不送 disconnect)+ `hci_bcm.c` `bcm_close` `:527` → `bcm_gpio_set_power(false)` `:564`(晶片直接斷電)。這條路在 image 裡沒有現成工具可觸發。

**(c) 就算推一個工具上去,02 上的副作用計畫沒列**(使用者規則:破壞性測試先列每個碰到的資源 + 還原):
- 02 自己也跑 provd:health 的 `hci0_powered` 會變、它會撤掉自己的 advert 並寫 log。
- 02 的 bluetoothd:電源狀態、advertising instance、settings 在 `up` 之後是否完整回來 ⚠️ 未驗證(BCM 需要重新載 firmware patch)。
- `radio_restore`(`ble-lib-254.sh:220-232`)由 04 的 lease/deadman 觸發;**02 沒有 lease/deadman**,host 中途斷線 02 就停在 hci0 down。
- central 的 `p2c.lock` 與 watchdog(`prov-p2-central-254.sh:33-49`)在 hci0 down 期間的行為沒寫。
- 這是「改節點狀態」的動作,需要使用者同意,計畫沒列在需要決定的點。

**修法(擇一)**:
- (建議,最少)把 §5.5 改成**不需要新工具的靜默斷線**:讓 02 的 central 連上後**什麼都不做、保持連線**(就是 `hold` 不 `drop`)。對 04 的 provd 而言,「連著但 30 s 沒開 session」與「靜默走掉但 supervision timeout 前還算連著」是同一個輸入;這正是 §5.2 的 arm。然後在計畫誠實寫:**真正的 RF 靜默消失(走出範圍)沒有在自動化裡重現**,以 F1 的現場紀錄為重現證據 ⚠️,並請使用者在現場做一次人工驗證(手機連上後關藍牙/走遠,04 在 ~50 s 內重新 advertise)當收尾項。
- 或保留 §5.5,但寫明:用什麼工具(從哪裡來、怎麼推到 02 的 tmpfs)、為什麼它走 `hci_dev_close_sync`、上面 (c) 每一項的前後檢查(`Powered: yes`、02 的 provd `adv registered`、instance 數 = 1)、中斷時的還原、以及取得使用者同意。

依「只做必要的修改」,第一個做法就夠。

---

### MINOR-1 — `read` 的 sleep 先決定要砍、再量;砍的位置有風險

`read_one`(`prov-p2-central-254.sh:112-124`)固定 sleep 8+2+1+2+1+8+1 = 23 s,連線壽命 ≈ 22–24 s,**本來就小於 30 s grace**(餘裕 ~6 s)。`:116-117` 的註解寫明 CTRL 後的 8 s 是 wbox encrypt-read 錯誤行需要的(「with 2 s the error line never came」),`prov-provd-wbox-254.sh:229-234` 靠 `ERRS` / `ERRLINES` 判定。
- 修法:先量(`read` 從 connect 到 disconnect 的實際秒數,5 次),**不超過 ~25 s 就不改**;真的要砍,不要動 CTRL 的 8 s,並依 #290 附 wbox gatt arm 新舊兩版的結果。
- 「每個使用者各跑 5 次計時」範圍過大(rpa 一輪 ~50 分鐘):量 verb 本身 + 每個 `hold` 使用者的 hold→drop 間隔即可。

### MINOR-2 — `boot-provd` 的 hold arm(`prov-provd-254.sh:99-106`)沒有 INVALID 規則

這個 arm 在 drop 前才取 `rd0`(`:104`),drop 時 link 年齡 ≈ 17–28 s。離 30 s 只有 2–13 s;ssh 慢一點 N1 就先斷,`rd0` / instance 數檢查會 FAIL 而且沒有歸因。`sec-dbus`(`:192-200`)同型但餘裕較大。
- 修法:這兩處加與 L80 相同的 INVALID 規則(04 log 在 mark 之後出現 N1 的斷線行 → INVALID,不是 FAIL),或把 N1 新 arm 放在這個 arm 之後並重用同一條連線。

### MINOR-3 — L80 對照 `watch 15`→`watch 8` 是輕微弱化,要寫明理由

對照 arm 的 STILL 時 link 年齡 ≈ 18–27 s(最壞餘裕 3 s),而 kill arm 的觀察窗仍是 15 s,兩者不再對稱。可以接受,因為 kill arm 另外要求新 provd 的 `disconnected N stale link` 行(獨立證據)。請在 §5.3 寫明這點。
kill arm 的 INVALID 規則用「provd pid 沒變」一條就夠(kill 有沒有發生的直接證據),不需要再疊別的條件。

### MINOR-4 — `liveLinks` 的計數語意要寫死並加一列測試

今天 `:733` 是 `len(links) + len(devConn)`,同一裝置在兩邊會算兩次。v3 的 `liveLinks(links, devConn, now)` 必須是**聯集**:`links` 有而 `devConn` 沒有的算 1(fd 已 accept、PropertiesChanged 還沒到);兩邊都有的算 1,且有 `links` 就永不過期。請在 §3.2 明寫,T 表加「只在 links」「兩邊都有且 since 已過 30 s」兩列。

### MINOR-5 — `register()` 重算後直接返回的路徑

重算在 `staleLinks`(`:590`)之後、只短暫拿 `b.mu`,與現有鎖序相容 ✅。但 rpa_timeout 路徑若重算後 n>0 而不註冊,下一個 tick 會以 `reason=disconnect` 補回 — 行為正確,只是 log 的 reason 會與實際原因(rpa)不同。在 §4 契約寫一句即可,不需要改碼。

### MINOR-6 — T 表沒有真的跑 `link()`

§5.1 用手寫 map 模擬 `link()` 的插入,因為 `link()`(`:294-313`)要呼叫 `b.srv.Accept`。可行,但 `link()` 寫入 `links` 與清 `devConn` 項的那幾行就沒有測試。若 `provd.Server` 能以零值/最小設定建出來(❌ 我沒讀 `session.go` 確認),用 `socketpair` 跑一次真 `link()` 較好;否則在 §5.1 標明這段是 ⚠️ 只靠 harness 涵蓋。

---

## 4. 任務指定的探查點

**`deviceChanged` 與 `bleLink.Close` 在單一 map 下的 goroutine 順序** — ✅ 全部順序推過,沒有孤兒:
- `Connected=false` → `Close`:false 已刪項,Close 的 `delete(b.links…)`(`:412`)不寫 `devConn`。
- `Close` → `Connected=false`:Close 留下的 `devConn` 項由 false 刪掉;false 永遠不來(F1 的情況)就由 30 s grace 接手 — 這正是設計本意。
- `refreshOwner` reset(`:491`)→ 晚到的 `Close`:不寫入。
- 同一 path 重連後晚到的舊 `Close`:最多把 grace 重新起算一次,無害。
- 前提:`Close` 若要「補一筆 since」必須在 `b.mu` 內做「不存在才建立」,不可覆寫既有 `since`(否則 peer 可用反覆開關 fd 延長 grace)。請在 §3 寫明。

**`register()` 內重算** — ✅ 符合鎖序;`staleLinks` 不在 `b.mu` 內跑(它會等 5 s × 3),重算在它之後另外拿鎖即可。

**§5.1 測試可行性** — ✅
- `newBLE`(`:63-67`)不需要 bus。
- `deviceChanged` 只用 `b.bluezName` 與 signal → 手做 `*dbus.Signal` 可驅動,**測試要自己設 `b.bluezName` 與 `s.Sender`**(否則 `:691` 直接丟掉,測試會「空過」— 請讓 T 表每列都斷言 map 真的變了)。
- `bleLink.Close`:`c := b.conn`(`:414`)、`if c != nil { go …Disconnect }`(`:416-418`)→ nil conn 不碰 D-Bus ✅;之後 `b.kick()`。
- `staleLinks` conn 為 nil 直接返回 → `register()` 重算的單元測試跑不到「Disconnect 後重算」那段,只測得到重算本身;寫明。
- build tag:`testenv_provtest.go` / `testenv_release.go` 對 `package main` 測試沒問題;CI 兩種 tag 都會跑(`ci.yml:141`、`:147`)。

**25–55 s 窗** — 見 MAJOR-2。

**§5.5 副作用** — 見 MAJOR-3。

---

## 5. 所有權 / 契約 / 生命週期

- **所有權** ✅:`devConn`、`links` 唯一擁有者是 `bleSide`(`b.mu`);advert 由 `converge` 單一寫入;BlueZ 的 Device1 連線狀態是 bluetoothd 擁有,provd 只讀 + 請求 Disconnect。沒有雙寫入者。
- **契約**:新 log 行的格式、何時出現、誰讀(harness grep)要在 §4 列成一列,並與 MAJOR-1 的限流語意一致。缺 `since`(舊行程升級上來不適用,map 在記憶體內)→ 不存在持久化格式問題 ✅。
- **生命週期矩陣** ✅ 涵蓋 start / restart(L80)/ dependency restart(bluetoothd、dbus → `refreshOwner` reset)/ crash / 降版(純記憶體,無殘留)/ 兩個 board(同一份 Go 碼)。
  缺一列建議補上:**authed session 進行中靜默消失** — 計畫 §2 已說不在範圍(靠 `IdleAuthed` 300 s),但矩陣要有這一列並寫「今天 = 改後 = 最長 ~300 s 不 advertise」,免得被讀成 N1 也涵蓋。

## 6. 安全

- 新輸入:無。`deviceChanged` 的 sender 檢查(`:691`)不變;本機非特權行程無法偽造 `org.bluez` 的 signal(system bus policy)⚠️ 依賴既有 L-sec-dbus 測試,不是這次新增的面。
- 遠端 radio peer:每 30 s 重連一次仍可讓節點大部分時間不 advertise(計畫已明說,現況是「連一次永久不 advertise」,所以是嚴格改善)。N1 沒有讓攻擊變容易。
- 被入侵的 peer:最多佔一個 link 30 s;`Close` 不可覆寫 `since`(§4 已提)是唯一要守的點。
- 失敗模式:`Disconnect` 失敗 → 仍然不計入 link、照樣 advertise(fail-open 於「可被連線」)。對可用性是對的;理由請在 §4 寫一句(kernel 最多 1 條 peripheral 連線時 advert 註冊會被拒 → 落到 MAJOR-1 的情境)。
- 負測試:§5.2 的 arm 即是(舊 image FAIL / rc PASS),前提是 MAJOR-2 修好。

## 7. 計畫裡不必要的東西

- `read` 的 sleep 縮短(MINOR-1):目前證據顯示不需要。
- §5.5 的 `hciconfig` 重現(MAJOR-3):用 hold-不-drop + 現場人工驗證即可。
- 「每個使用者 5 次計時」:量 verb 即可。

## 8. 要作者決定 / 回覆的點

1. MAJOR-1:`lastWhy` 改 per-key(建議)還是 stale 另開欄位。
2. MAJOR-2:grace 以 04 log 判定(建議)還是改 central 印 uptime。
3. MAJOR-3:§5.5 改成「hold 不 drop + 現場人工一次」(建議)還是保留並補齊工具/副作用/同意。

三項改完後請整份再審一次(依規則:有 MAJOR 未關就重審整份)。
