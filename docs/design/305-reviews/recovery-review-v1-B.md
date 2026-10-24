# #305 設計 v1 — 對抗式審查 B(第 1 輪)

**審查對象**:`305-bt-recovery.md` v1(整份)。**依據**:使用者全域規則 + `docs/design/REVIEW.md`。
**基準**:Batman main a62bf78(已確認 `git log -1`)、firmware build-3aplus 樹、02/04 唯讀(1.5.12-wsl.15)。
**我在節點上做的事**:只讀 `/sys`、`/proc`、dmesg、logread、`docker inspect`、`ls`;沒有跑 bind/unbind、btwedge、bluetoothctl,沒有寫任何檔。

**結論:REJECT(窄)— 0 BLOCKER / 8 MAJOR / 11 MINOR。**
方向是對的:0x1001 探測當活性訊號、rebind 當恢復方法、helper 當擁有者都有根據。問題出在介面:rebind 會改到別人的東西(provd 的註冊、hci index、電源意圖、harness 的 lease),設計裡沒有寫;「不計次數」的 UNBOUND 路徑沒有上限;測試計畫有一半測不到它聲稱的路徑。

---

## 我先查證的事實(附證據)

| # | 事實 | 證據 | 狀態 |
|---|---|---|---|
| V1 | rebind 時 bluetoothd 會**銷毀**該 adapter 的 GATT database 與廣播管理器 → provd 註冊的 advertisement / GATT application 全部消失 | bluez-5.72 `src/adapter.c:6968` `btd_gatt_database_destroy`、`:6971` `btd_adv_manager_destroy`(`index_removed` `:10658` → `adapter_unregister`);04 logread:`09:00:33 Battery Provider Manager destroyed` → `09:00:40 … created`(E7 那次 rebind) | ✅ |
| V2 | 254 設計裡 provd 只在 **bluetoothd 重啟**(`NameOwnerChanged`)時重註冊 | `254-stage1-impl.md:340`(L9–L11) | ✅ |
| V3 | hci index 在 `hci_release_dev()` 才歸還,也就是最後一個參考放掉時;只要有 socket 還綁著舊的 hci0,新的控制器就會變成 hci1 | `hci_core.c:2585` `ida_alloc_max`(取最小的空號)、`:2766` `ida_free` 在 release;`hci_sock.c:829-840` UNREG 只設 `EPIPE`,不放參考;`:1204-1212` 註解寫明 socket 會一直綁著死掉的 dev,直到重新 bind 或 close | ✅ 原始碼 / ⚠️ 未實機誘發 |
| V4 | 非 root 程序可以建立 HCI raw socket、綁到 hci0(不檢查 capability),並送 sec-filter 白名單裡的命令(含 0x1001、OGF1 Inquiry 0x0401) | `hci_sock.c:2192-2213`(create 不檢查)、`:1222-1231`(RAW bind 只做 `hci_dev_get`)、`:1877-1883`(不在白名單又沒有 CAP_NET_RAW 才拒)、`:140-158`(白名單) | ✅ 原始碼 |
| V5 | 只有 init_net 可以用 AF_BLUETOOTH;04 的 OTS 容器都在 `ots-net` bridge → 容器碰不到。但 host 上的非 root daemon(dnsmasq、avahi `nobody`、hostapd `network`、ubus,以及 P2 的 provd uid 471)都在 init_net | `af_bluetooth.c:118`;04 `docker inspect`:5 個容器都是 `net=ots-net`;`ps w` 的使用者欄 | ✅ |
| V6 | kernel 發生 tx timeout 時只做兩件事:把 `cmd_cnt` 設回 1、取消 sync,**不會**自己 reset 控制器;`hci_unregister_dev` 會先 `cancel_work_sync(error_reset)`,所以 rebind 不會和 kernel 自己的 error-reset 互相打架 | `hci_core.c:1457-1477`、`:2703` | ✅ |
| V7 | probe 時 hci_bcm 會先斷電(100–120 ms),open 時再上電(100–120 ms);DT 有 `shutdown-gpios`,04 上是 `gpio-570 BT_ON` | `hci_bcm.c:301`、`:1557`、`:504`;04 `/proc/device-tree/soc/serial@7e215040/bluetooth/shutdown-gpios`、debugfs `gpio-570 (BT_ON |shutdown) out hi` | ✅ |
| V8 | procd 停止時:先送 SIGTERM,5 s 後送 SIGKILL;helper 的 init 沒有設 `term_timeout` | procd `service/instance.c:1621`(`term_timeout = 5`)、`:900/:918` | ✅ |
| V9 | 現在的 SIGTERM handler 是在 goroutine 裡直接 `os.Exit(0)`;沒有身分的路徑走 `select{}`,**沒有** signal handler;另外還有兩處 `os.Exit(1)`(PrepareDir、Listen) | `main.go:396-400`、`:412-425` | ✅ |
| V10 | 這個 kernel 沒有 rfkill(`/sys/class/rfkill` 不存在,02 與 04 都一樣) | 兩台 `ls /sys/class/rfkill/` → No such file | ✅ |
| V11 | E7 的 rebind 用的是 `sleep 2`,不是設計寫的 500 ms;探測工具的期限是 5 s,不是 3 s | `r305/hunt-event.sh`、`r305/btprobe/main.go`(`for time.Since(t0) < 5*time.Second`) | ✅ |
| V12 | 自然發生的「運行中卡死」**還沒有一次**是在有 0x1001 探測、並做過 rebind 的情況下抓到。E3(init 失敗 rebind 1/1)是自然發生的;E6/E7 是誘發的 | `hunt-20261024-075557.log`:120 行裡唯一的 EVENT 是 08:11:35 的 E7 誘發 | ✅ |
| V13 | bcm2710 lock 有 `batman-prov=y`、`kmod-bluetooth=m`,但 `bluez-daemon` 沒選 | `boards/ekh-bcm2710/batman-config.lock:5605,5742,1134` | ✅ |
| V14 | 節點沒有 RTC,牆上時間不可信(04 顯示 2025-07-20,02 顯示 10-22) | 兩台 `ls -la` 的時間戳 | ✅ |

---

## MAJOR

### M1 — rebind 會清掉 provd(P2)的廣播與 GATT 註冊,沒有任何契約讓它恢復 →「恢復成功」但 app 照樣找不到機台
- **情境**:現場節點已在 P2,provd 有註冊 advertisement 和 GATT。發生卡死後 btwatch rebind,bluetoothd 銷毀 adapter 物件(V1)。bluetoothd **沒有重啟**,所以 provd 收不到 `NameOwnerChanged`,依 254 L9–L11(V2)它不會重註冊。結果 log 寫 `result=ok`,health `hci0_alive=1`,`adv_registered_once=1` 仍然是 1(它是 latch,#265 的同一類錯),**機台不廣播**。這正好是 #305 要修的現場症狀。另外 RPA 輪替也靠 provd 重新註冊(F28),也一起斷掉。
- **修法**:
  1. 在設計裡寫出 btwatch ↔ provd 的契約:provd 要監聽 `org.freedesktop.DBus.ObjectManager.InterfacesAdded/Removed`(`/org/bluez/hciN`、`LEAdvertisingManager1`、`GattManager1`),看到 adapter 重新出現就重註冊;這一條寫進 254 L9–L11,當成 P2 的必做項。
  2. health 改用現況欄位(`adv_registered=0|1`,由 provd 經 helper socket 回報、帶世代號)取代 latch 的 `_once`,或至少讓 btwatch 每次 rebind 後把它歸零。
  3. 定義 `result=ok`:P2 之前 = 探測 `status0` + index 存在 + Powered=1 + privacy=1 + sc=1 + sc_file=1;P2 之後再加「T 秒內 adv 已重新註冊」。
  4. 補一個測試:P2 的 tier-B 在廣播中誘發 T2,斷言 rebind 後 central 在 N 秒內又看得到廣播。負對照:provd 不處理 InterfacesAdded 時這個測試要 FAIL。

### M2 — 綁著 hci0 的 socket 會讓新控制器變成 hci1;所有寫死 index 0 的消費者都會壞,btwatch 自己會把 3 次額度用完
- **情境**:任何 init_net 裡的程序(非 root 也可以,V4)開一個 raw socket 綁著 hci0 不關。btwatch rebind 後,舊 hdev 的參考還在 → index 0 沒有歸還 → 新的是 **hci1**(V3)。接下來:health `ReadInfo` 問的是 index 0(`health.go:73`),回 Invalid Index;patch 900 寫 `index=1`,所以 `sc_file` 檢查(`index == "0"`,`health.go:121`)= 0;btwatch 判 DOWN,再 rebind → hci2 … 3 次後 `gaveup`。但其實藍牙在 hci1 上是好的。P2 的 provd 若寫死 `/org/bluez/hci0` 也會壞。被攻陷的 dnsmasq / avahi(遠端碰得到的 daemon)只要 `socket()+bind()` 一次就能做到,而且這是**由 btwatch 放大**的:沒有 btwatch 的時候,同樣的 socket 什麼也不會發生。
- **修法**:index 從 sysfs 動態取(`/sys/bus/serial/devices/serial0-0/bluetooth/hci*` 或 `/sys/class/bluetooth/hci*/device` 指回 serial0-0);health、batman-sc 檢查、探測、provd 一律用「目前 index」;rebind 前讀 `/proc/net/hci` 記下有沒有非 root 的 raw socket(有就寫進 log);設計的假設表要列出 V3 / V4。
- **測試**:白箱測試 — 用非 root(provd uid)開一個綁 hci0 的 socket 留著,再誘發 T2,斷言恢復後 `bt_state=ok` 且在 hciN 上一切正常(index 不等於 0 也算過)。負對照:寫死 index 0 的版本要 FAIL。

### M3 — UNBOUND 路徑「立即 bind、不計次數」沒有上限;寫入 state 的時機也會造成無限 rebind;而且和 T1 / T5 互相矛盾
- **情境 a**:bind 本身失敗(probe 回錯誤,裝置就留在 unbound)。每 15 s bind 一次,每次都要斷電再上電、下載 patchram(約 4 s),永遠不停,也不計入次數。
- **情境 b**:btwatch 在 unbind 後、寫 state 前 crash(Go panic、`os.Exit(1)`(V9)、procd 在 5 s 後 SIGKILL(V8)、OOM)。respawn → UNBOUND bind(不計)→ 仍然卡死 → WEDGED → 讀回的次數**沒有增加** → 再 unbind → 又 crash … 無限迴圈。
- **情境 c(設計內部矛盾)**:T1 是「unbind 後不 bind」,斷言 `why=down`;但依 §3.2(1),這個狀態是 UNBOUND,會立刻 bind,寫的是 `why=unbound`。T5「T1 連做 4 次 → gaveup」因此永遠到不了 gaveup。
- **修法**:
  1. **先寫 state 再動作**(write-ahead):`n+1`、`phase=unbinding`、uptime 先原子寫入,再 unbind;bind 完成後寫 `phase=bound`。
  2. UNBOUND 只在 state 是 `phase=unbinding`(也就是我們自己死在中間)時才免計次數,而且每個 phase 記錄只能免一次;其他 unbound(人為、模組卸載、probe 失敗)要計次數,或者不動作只寫 log。
  3. 所有離開程序的路徑(SIGTERM、`os.Exit`、panic recover)都要取 rebind 鎖。
  4. 修正 T1 / T5 的誘發方式(見 M7)。

### M4 — 「Powered=0 持續 45 s → DOWN → rebind」會蓋過人為的關電,包括現有的 254 負對照,以及未來的 EMCON
- **情境**:有人刻意把藍牙關電:今天的 `bluetoothctl/btmgmt power off`、254 負對照(8)「`ble-ok` 在、`bluetoothctl power off` → UNHEALTHY」(`254-stage1-impl.md:424`),或未來的無線電靜默(EMCON)。45 s 後 btwatch rebind → bluetoothd 的 AutoEnable 把電源打開 → **又開始發射**。設計說 EMCON 走 rfkill,但這個 kernel 根本沒有 rfkill(V10)→ §3.2(4)的條件永遠為假,EMCON 實際上只能用 mgmt 關電來做,正好被這條規則蓋掉。這是「兩個寫者寫同一個資源」(hci0 電源狀態):bluetoothd 的 policy / 操作員一邊,btwatch 透過 rebind 一邊。擁有權表(§4)沒有列出這個資源。
- **證據顯示需要的範圍**:init 失敗的實際特徵是「`/sys/class/bluetooth/hci0` 存在,但 mgmt 沒有 index」(#305 第一則留言、`hci_core.c` 的 `hci_power_on` 失敗後 `HCI_SETUP` 不會清掉)。「有 index 但 Powered=0」目前沒有任何實證是卡死造成的。
- **修法**:DOWN 只認「hci0 在 sysfs、mgmt 沒有 index」。Powered=0 要動作的話,前提是有一個明確的「藍牙應該開著」意圖檔,由唯一擁有者(之後的 EMCON / 操作員介面)寫入;沒有這個檔就不動作。擁有權表補上「hci0 電源意圖」一列。254 的負對照(8)要在設計裡註明它和 btwatch 之間的互動。

### M5 — 自然卡死的偵測與恢復仍是推論;誘發方式(0xfc18)和自然機制不同,還有幾個沒測過的參數
- **事實**:自然的運行中卡死還沒有在有探測 + rebind 的情況下抓到過(V12)。0xfc18 是讓控制器改鮑率,所以 rebind 後主機以 init_speed 115200 重新開啟,本來就和控制器對得上;它證明的是「rebind 會重新設定 UART」,**證明不了**「斷電重置能清掉自然卡死時控制器端的狀態」。自然卡死也有可能只卡住 LE 掃描的狀態機(dmesg 只看到 0x200c 一直 timeout),這時 0x1001 仍會回應,探測就不會觸發。另外,實測用的是 2 s 間隔、5 s 期限(V11),設計寫的是 500 ms、3 s;rebind 的樣本數是 1/1 + 1/1。
- **修法**:
  1. 驗收條件裡寫明:要抓到 ≥ 1 次自然的運行中卡死,而且在**同一份 btwatch 程式碼**下自動恢復,證據附 dmesg、ttyS0 計數、探測結果。在那之前,§2 和 PR 都把運行中卡死標 ⚠️。
  2. 獵捕期間每次 tick 也記下 0x200c / 0x2042 之類的掃描命令是否 timeout,但同時 0x1001 正常 → 量化「探測看不到的卡死」。如果真的出現,偵測要加一條:「kernel 的 tx timeout 計數(從 dmesg 或 btmon)持續增加」。
  3. 500 ms 與 3 s 要嘛改回實測值,要嘛在誘發條件下重測(各 ≥ 5 次)。

### M6 — 現場範圍:gaveup = 這次開機都沒有 BLE,沒有任何人看得到,也沒有分 prov 狀態
- **情境**:254 明文「BLE 是唯一管理面」(`254-stage1-impl.md:72`)。一台 **unclaimed** 的節點如果 gaveup,就完全無法佈建,而且使用者沒有任何訊號(只有要 ssh 才能看的 `halow-status`)。這時重開完全沒有代價(還沒有加入 mesh)。一台 **member** 節點 gaveup 則是這次任務期間 app 都管不到它。另外,gaveup 是**永久**的:就算 M8 那種 flood 停了,這次開機也不會再試。
- **修法**:
  1. 依 prov 狀態分開:unclaimed / legacy 的節點用完次數後允許 `batman-slot reboot`(每次開機至多一次,用 p6 計數防開機迴圈);member 不重開,但改成長間隔重試(例如每 30 分鐘一次),不要永久放棄。
  2. 狀態要讓現場看得到:meshled 加一種燈號,或透過 mesh 讓隊友看到 `bt_state`。
  3. §1 補一張現場觸發清單:peripheral 角色(手機連進來、GATT 寫入、RPA 輪替)vs central 角色(harness 用 02 當 central)。目前所有實證都是 central 掃描負載;現場節點是 peripheral,恢復的頻率和副作用(例如把正在佈建的連線打斷,這部分有 219 §4.2 的冪等 / `claim/replay` 可以承接,`219-protocol.md:155`,設計應引用)都要分開說明。

### M7 — 測試計畫:T1 測不到 DOWN,T4 分辨不出好壞,T5 會讓節點這次開機沒有 BLE 而且沒寫還原方式,沒有 lease,也沒有 known-failures
- T1:unbind 會讓 sysfs hci0 消失、driver 連結消失,走的是 UNBOUND,不是 init 失敗的特徵(hci0 在、沒有 index)。**DOWN 路徑完全沒有誘發測試。** 建議:(a)單元測試用假的 READ_INFO;(b)真機用「掃描中重開」迴圈(#305 實測約 1/30)跑到 ≥ 1 次 init 失敗,斷言自動恢復 — 這屬於慢測項,依規則不能省,要先問使用者;(c)可以試試先 0xfc18 再 `btmgmt power off/on`,看會不會造成「有 index、power-on 失敗」(要先唯讀查證這個行為)。
- T4:「`bt_recover` 只在有探測失敗紀錄時增加」是套套邏輯(恢復本來就一定由探測失敗觸發)。要改成:在合法的忙碌負載下(長時間掃描 + 廣播 + 連線 + bluetoothd restart + power 循環 + RPA 輪替)斷言 `bt_recover=0`,**而且**探測次數 ≥ N(依規則,沒東西可檢查必須 FAIL);同時用另一個長期限(10 s)的獨立探測當裁判。
- T5:會讓節點用完次數 → 這次開機都沒有 BLE,同一輪後面的 BLE 套件全部受影響。要列出副作用與還原方式(重開?或提供 root-only 的 `--bt-reset`?),見 `feedback_destructive_test_side_effects`。
- T3 的誘發不是它聲稱的那個時間窗:外部 unbind 再 TERM,測到的是「別人 unbind」,不是「helper 死在自己的 unbind 和 bind 之間」。需要白箱鉤子(例如 root-only run dir 裡的 fault 檔,讓 btwatch 在 unbind 之後 `os.Exit`),並說明這個鉤子的信任邊界。
- 每個破壞性測項都要取 harness 現有的 BLE lease(`scripts/node/ble-lib-254.sh:84-175`),避免和 `bchk_ble_rpa_254`(約 45 分鐘)等套件同時跑。反過來,既有的 tier-B BLE 套件要在測試前後比對 `bt-recover.log`,如果有恢復發生,FAIL 要歸因為「btwatch rebind」(依規則,FAIL 必須有歸因)。
- negative control 在 wsl.15 上會 FAIL → main 上的 harness 在產品 merge 前會是紅的 → 要寫進 `scripts/validation-known-failures.txt`(有到期日與單號),並附「舊版 FAIL + rc PASS」的翻轉證據(`feedback_one_validation_set`)。
- 誘發工具 btwedge / btprobe 目前只在 scratchpad。依 PR-H1 的做法,要放進 repo 並以 SHA256SUMS 上傳(參考 `scripts/dv-bt-tools.sh`),不能進 image。
- harness 資料:`scripts/rundir-paths.txt` 要加 `btwatch.state`(以及 M3 需要的 lock 檔);`280-tmp-trust.md §11.2` 的寫者 / 讀者表、`prov-p1-254.sh` 的欄位清單都要更新 — 全部走 harness PR 先進 main。§7 只寫了「先進 harness PR」,沒有列出這些。

### M8 — 安全章節的「非 root 不能讓控制器忙」不成立;本機非 root 的 DoS 會被恢復機制放大成整個開機都沒有 BLE
- **事實**:非 root 可以綁 hci0,並送白名單裡的命令(V4)。不需要 CAP_NET_RAW 就可以大量送 0x1001,或送 Inquiry(0x0401)。`hci_sock_sendmsg` 把命令排進 `hdev->cmd_q`,而 cmd_q 是 FIFO,沒有上限(每個 socket 只受 sndbuf 限制;開多個 socket 就能疊加)。btwatch 的探測排在後面超過 3 s → 連續 2 次 → rebind;重複 3 次 → gaveup。再加上 M2 的 index 綁定。被攻陷的 provd(P2,uid 471)、dnsmasq、avahi、hostapd 都在 init_net(V5)。
- **修法**:§6 改寫為實際的攻擊面(V3、V4、V5);探測失敗後先查 `/proc/net/hci` 裡有沒有非 root 的 raw socket,有的話改成「疑似干擾」,寫 log 但不計入恢復次數(或給較長的退避);P2 的 provd 用 seccomp / 沙箱禁止 `socket(AF_BLUETOOTH, SOCK_RAW, BTPROTO_HCI)`(它只需要 D-Bus)。負向測試:以 provd uid 跑 flood 與綁定,斷言 btwatch 不會 gaveup、index 處理正確。

---

## MINOR

1. **SIGTERM 延後的範圍與時間**:不只 SIGTERM — 所有 `os.Exit` 路徑、沒有身分時的 `select{}` 路徑(沒有 handler,V9)都要納入。「≤ 1 s」沒有量過:控制器卡死時 unbind 會跑 `hci_dev_close_sync`,裡面每個命令都可能等 2 s;procd 5 s 後就 SIGKILL(V8)。要在 T2 的誘發條件下量出 unbind 實際花多久。
2. **`btwatch.state` 的契約沒寫**:格式、原子寫入、欄位(n、每次的 uptime、phase)、壞檔時怎麼辦。建議壞檔視為 gaveup(fail-closed,不動作)並寫 log,說明理由;讀者(halow-status)要容忍缺檔。
3. **btwatch 與 health 是兩個 goroutine 還是一個**:§3.2 寫「與 health tick 同步」。如果 rebind 擋住 health tick,health 會過期(> 60 s → 讀者當全 0)。建議 btwatch 單獨一個 goroutine,透過有鎖的共享狀態把 `hci0_alive` / `bt_state` 交給 health;rebind 期間 health 照常寫 `bt_state=recovering`。
4. **兩個 helper daemon 同時跑**:root 手動執行不帶參數的 `batman-provhelper`,依新的啟動順序(btwatch 在 Listen 之前)會短暫出現第二個 bind/unbind 寫者。加 `flock($RUNDIR/btwatch.lock)`。
5. **health 移到讀 keystore 之前**:沒有身分的節點以前沒有 health 檔,之後會有,也就可能被寫上 `ble-ok`。要在生命週期表裡列出這個行為變化,並確認 harness tier A 對這類節點的預期。
6. **bt-recover.log**:「超過 64 KiB 就截成後半」是重寫既有 log,中途斷電會整份遺失 → 改成 rename 到 `.1` 輪替。寫入前要確認 p6 真的有掛載(否則會寫進 overlay)。`<UTC>` 不可信(V14)→ 以 `boot=`、`up=` 為主,UTC 欄標為參考。
7. **bcm2710 列的理由不對**:Pi 3A+ 的藍牙同樣是 `hci_uart_bcm` 在 serdev 上(kmod-bluetooth=m,V13),很可能也有 `serial0-0`。實際上不會動作,是因為沒有 bluetoothd(DOWN 的條件)而且 auto-off 讓 Powered=0。要改寫理由,加上「沒有 bluetoothd 套件 → btwatch 不啟動」的明確判斷和單元測試;03 壞了,標 ⚠️。
8. **路徑寫死**:`serial0-0` 和 `hci_uart_bcm` 都寫死。PL011(量產 O13)應該也會叫 serial0-0(serdev 控制器編號),但這是推論;建議從 driver 目錄找出 of_node compatible 是 `brcm,bcm43*-bt` 的那個裝置。`hci_uart` 模組被卸載時 bind 檔不存在,要計入次數並寫 log,不能一直重試。
9. **`hci0_alive` 的定義**:Powered=0 或 bluetoothd 不在、沒送探測時,值是什麼要寫清楚(建議 0)。`ble-ok` 改成「`hci0_alive=1` 連續 10 分鐘」我同意。
10. **autocommit 之後改成阻擋時**:P-U5 寫的是「卡死修好前 WARN-only」。這張單就是那個前提,所以現在就應該寫下之後 gate 要讀的是 `hci0_alive` / `bt_state`,不是 `hci0_powered`(E6 已證明它會說謊),以及 `recovering` 時不重置 dwell、`gaveup`(硬體問題,不是 image 問題)不 revert,免得之後誤 revert 好的 image。
11. **擁有權表缺列**:hci0 電源意圖(M4)、bluetoothd 的 adapter D-Bus 物件與 provd 的註冊(M1;rebind 等於刪掉它們)、hci index(M2)、正在進行的 BLE 連線、harness 的 BLE lease、`/var/lib/bluetooth/batman-sc`(rebind 後 bluetoothd 會重寫)。另外 harness 的 bind/unbind 是第二個(只限測試)寫者,要列出來並說明它和 lease 的關係。表裡「hci0 控制器:btwatch 只送唯讀命令」也不對,rebind 本身就是對控制器最重的寫入。

---

## 生命週期矩陣缺的列

- **autocommit revert**(REVIEW.md 有列):trial 被 revert 後重開,state 在 tmpfs 歸零 — 寫出來。
- **OTA stage 2**:sysupgrade 會殺掉所有程序,可能剛好在 unbind 和 bind 之間;下一次開機 probe 本來就會重新上電,沒有影響,但要寫出來。
- **dbus 重啟 / bluetoothd crash loop**:respawn 每 5 s 一次的期間 Powered 可能一直是 0(若 M4 沒改)。
- **hci_uart 模組卸載 / 重新載入**(MINOR 8)。
- **harness BLE tier-B 進行中**(M7)。
- **P2 provd 已註冊**(M1)。
- **index ≠ 0**(M2)。

## 我同意、而且已驗證的部分
- READ_INFO / Powered 會說謊,0x1001 會真的走 UART:E5、E6 和 hunt log 一致(探測往返 1 ms,數百次 `status0`)。
- rebind 後 SC-only 與 privacy 會由 bluetoothd 恢復:patch 900 在 `read_info_complete`(`adapter.c:10236`)每次都送;04 logread 有 `09:00:40 Batman: SecureConnections mode 2 requested`,而且 rebind 後沒有新的 `Generated IRK`(IRK 從 tmpfs 讀回)。
- kernel 自己的 error-reset 不會和 rebind 互相打架(V6)。
- probe 本身就會斷電再上電(V7),所以 rebind 確實會讓控制器重新上電 — 但這一點對 E7 的證據力不夠(見 M5)。
- 由 helper 擁有恢復動作、權限分配的理由成立;只寫 root-only 路徑成立。
- 拆成 harness PR 先進 main、再上產品 PR 的方向符合規則(細節見 M7)。

## 判定:**REJECT(窄)**
0 BLOCKER / 8 MAJOR / 11 MINOR。M1、M2、M3、M4 是介面與上限問題,改設計文字和狀態機就能解決;M5 需要更多實證,M6 需要使用者決定 gaveup 的現場策略;M7、M8 是測試和安全章節要重寫。改完請送整份重審。

**需要使用者決定的事**:
(a)unclaimed 節點 gaveup 後是否允許自動重開;member 節點要長間隔重試,還是永久放棄。
(b)自然卡死的獵捕要跑多久、還是要先抓到 ≥ 1 次才 merge。
(c)「掃描中重開」的 init 失敗 soak(慢測項)是否列入全套驗證。
