# #305 設計 v1 — 對抗式審查 A(第 1 輪)

**審查對象**:`h305/305-bt-recovery.md`(v1,全文)。**基準**:Batman main a62bf78、firmware build-3aplus 72814fa4、02 / 04 `1.5.12-wsl.15`。

**方法**
- 讀完整設計與 `docs/design/REVIEW.md`。
- 對照產品程式:`health.go`、`batman-provhelper/main.go`、`batman-provhelper.init`、`batman-autocommit:493-500`、`prov-p1-254.sh:43-52`。
- 對照設計文件 `254-stage1-impl.md`:§3 `:123` / `:129`、§6.4 `:420-424`、L9–L11 `:340`。
- 對照 harness:`scripts/dv/ble-254.sh`、`scripts/node/ble-periph-254.sh`。
- 對照上游原始碼:kernel 6.6.138 `hci_sock.c` / `hci_core.c` / `af_bluetooth.c`;BlueZ 5.72 `adapter.c` / `advertising.c`。
- 對照證據:r305(btprobe、hunt log、hunt-event.sh、init 失敗的 dmesg)與 #305 全部留言。
- 02 / 04 只做唯讀讀取:sysfs、health 檔、`ubus call service list`、dmesg 計數、`/proc/tty/driver/serial`、DT 節點。節點上沒有寫入任何東西。

## 結論:**REJECT**(0 BLOCKER / 7 MAJOR / 12 MINOR)

方向是對的:0x1001 探測真的走 UART,serdev rebind 是目前唯一證實不用重開機就能恢復的方法,偵測訊號的選擇也有證據撐。問題出在介面:

- btwatch 實際上變成**藍牙電源與 adapter 存在與否的第二個寫者**,擁有權表沒有列,也沒有「不要動」的契約。
- 「每次開機 3 次,用完永久放棄」在現場撐不住。
- 測試計畫的 T1 / T5 測到的是另一條路徑。
- 安全段對非 root 程序的描述與 kernel 原始碼不符。
- 運行中卡死的恢復只試過 1 次,而且是在「誘發的代理故障、client 先被清掉、間隔 2 s」的條件下。

---

## MAJOR

### M1 `DOWN` 把 Powered=0 當故障 → 和所有「刻意關電源」的寫者打架;擁有權表漏了這個資源
- **情境**:操作員、harness 或將來的 EMCON 用 mgmt `power off`(`btmgmt power off`、`bluetoothctl power off`)讓 hci0 關著超過 45 s。btwatch 判 DOWN → unbind / bind → bluetoothd `index_added` + `[Policy] AutoEnable = true`(`batman-ble/files/main.conf:22`)把電源打開。刻意關閉的狀態被默默推翻,還吃掉一次恢復額度。
- **證據**:
  - `254-stage1-impl.md:123`:`hci0 Powered` 的寫者是 bluetoothd 的 AutoEnable,helper 唯讀。v1 §4 沒有這一列,也沒有「adapter 存在」這一列;rebind 讓 btwatch 成為兩者的寫者。
  - `254-stage1-impl.md:424` §6.4 負對照 (8):「`ble-ok` 在、`bluetoothctl power off` → UNHEALTHY」。btwatch 上線後,這個負對照只有在 45 s 內判定才成立,超過就被推翻,結果看時機。
  - harness 本來就會關電源:`ble-periph-254.sh:62`(privacy-off)、`:68`(restore)、`:96`(rekey)、`:177`(deadman)、`dv/ble-254.sh:71`(N5a power cycle)。今天每段都很短,但契約沒寫;之後任何一段等超過 45 s,都會被 btwatch 打斷。
  - 「EMCON 走 rfkill」在今天的 kernel 做不到:兩台 `ls /sys/class/rfkill/` 都回 `No such file or directory`。所以 §3.2-4 的排除條件永遠不成立;將來的 EMCON 很可能走 mgmt power off,正好撞上 M1。
  - init 失敗在現場的樣子是「沒有 mgmt index」,不是「index 在但 Powered=0」:
    - `hci_core.c:954-976` `hci_power_on` 失敗時不清 `HCI_SETUP`,也不呼叫 `mgmt_index_added`;
    - `hci_sock.c:1676-1680`:`HCI_SETUP` → `MGMT_STATUS_INVALID_INDEX`;
    - 這和 #305 留言的 `No default controller available` 加上 `/sys/class/bluetooth/hci0` 存在相符。
  - 「index 在、Powered=0」這種故障**沒有任何現場證據**。
- **修法**:
  - (a) DOWN 只認 `READ_INFO` 回 `Invalid Index`,而且 `/sys/class/bluetooth/hci*` 存在(= setup 卡住)。Powered=0 只回報(`bt_state=off`),不恢復。
  - (b) 定義一個 root-only 的抑制契約,例如 `$RUNDIR/bt-hold`,內容 `owner=<harness|emcon|operator> until=<uptime>`。過期就忽略,回到會恢復的狀態(fail-open);理由是忘記清掉的 hold 不能永久關掉 BLE。harness 的 BLE 測試段與將來的 EMCON 都走它。
  - (c) §4 加三列:`hci0 Powered`、adapter 存在、`bt-hold`。
  - (d) 測試:power off 90 s → 不 rebind、`bt_recover` 不變。負對照:v1 的規則會 rebind。

### M2 測試計畫測不到它說要測的東西
- **T1**:`unbind` 之後不 bind,依 §3.2-1 是 **UNBOUND**(立即 bind、不計次數、`why=unbound`),不是 DOWN。斷言「log 一行 `why=down`」照設計一定 FAIL;如果 PASS,就表示實作和設計不一致。init 失敗(DOWN)這條路徑沒有任何誘發方式。
- **T5**:「T1 連做 4 次 → gaveup」。UNBOUND 不計次數,所以永遠到不了 gaveup。就算到了,這次開機剩下的時間 btwatch 都不會再恢復,而 T5 沒寫怎麼還原;同一輪 daily-validation 裡排在後面的 T2 和 BLE 套件,會在「已放棄」的節點上跑,結果歸因錯誤。
- **T4**:斷言「`bt_recover` 只在有探測失敗紀錄時增加」是循環論證。誤判本來就是「健康的控制器上探測失敗」;用 btwatch 自己的紀錄來判 btwatch,分辨不出來。T4 沒有負對照,也沒有涵蓋高風險時段:開機 patchram、bluetoothd restart、掃描 + 廣播 + 連線同時進行、cmd_q 有積壓。
- **T3**:測試自己 unbind 再 kill helper,等於「外部 unbind」。測不到「helper 在自己的 unbind→bind 之間收到 SIGTERM 會延後退出」,也測不到 SIGKILL。
- **缺少的測試**:rebind 時有活著的 client(見 M4)、`-ENETDOWN` 競爭、M1 的 power off、M3 的退避、M5 的非 root 洪流。
- **修法**:
  - DOWN 的誘發要真實,分兩層:
    - 白箱:用注入的 READ_INFO 測 btwatch 的狀態機(單元測試)。
    - 現場:「掃描中重開」N 次的 soak(自然觸發率 1/30,#305 已量過)。驗收時至少抓到 1 次 init 失敗,並由 btwatch 救回、記 `why=down`。
  - T5 改成用 T2(會計次數的那條路徑)連做,並先定義還原方式:root-only 的 `batman-provhelper --btwatch-reset`,或重開。
  - T4 改用獨立裁判:測試主機自己用另一個 socket、以不同節奏探測,再加上 dmesg `tx timeout` 計數。斷言「獨立裁判全程成功 ⇒ `bt_recover` 不變」。負對照是把探測期限調成 1 ms 的測試版,它必須 FAIL。

### M3 「每次開機 3 次,之後永久放棄」在現場撐不住
- **情境**:
  - 一台節點跟著人跑好幾天不重開,而 BLE 是唯一的管理面(`254-stage1-impl.md:72`)。
  - #305 量到的是:30 段 5 分鐘的掃描中出錯 4 次、卡死 1 次。P2 之後節點會一直廣播、被手機連線,那時的卡死率未知。
  - 第 4 次卡死之後,這次開機剩下的時間都沒有 BLE:手機 app 找不到機台,現場唯一的辦法是拔電。
  - 被攻陷的元件或非 root 程序(M5)可以在大約 20 分鐘內把額度用完,讓 DoS 一直持續。
- **證據**:設計沒說 3 這個數字從哪來。rebind 本身的代價是每次約 15 s 沒有 BLE(其中 patchram 約 3.5 s,04 dmesg 14227.9→14231.6),而且不碰 HaLow。
- **修法**:
  - 不要永久放棄。改用指數退避(60 s → … → 上限例如 30 min)加上速率上限(例如每小時 ≤ 4 次),一律用單調時鐘。
  - 只有 `bind` 寫入本身連續失敗 N 次,才進 `gaveup`。
  - `bt_state` 要看得出「退避中」。
  - 測試:連續誘發 6 次 → 間隔符合退避表,第 6 次仍然恢復。

### M4 rebind 對 bluetoothd client(將來的 provd)的契約沒寫;恢復的證據是在 client 先被清掉的情況下拿到的
- **情境**:P2 之後,provd 持有 LEAdvertisement 和 GATT application,可能還有手機正連著做認領。rebind 時:
  - `index_removed` → `adapter_unregister`(BlueZ `adapter.c:10658-10671`);
  - 廣播 client 被 `Release`(`advertising.c:166-178`),GATT app 被移除,連線斷掉;
  - bluetoothd 的 pid 不變,所以 `254-stage1-impl.md:340` L9–L11 的「provd 在 `NameOwnerChanged` 時重新註冊」**不會觸發**。
  
  結果是恢復之後 adapter 是好的,卻沒有人重新廣播,app 還是找不到機台。這正是 §1 要解決的現場後果。
- **證據**:
  - `r305/hunt-event.sh` 在 rebind 前先 `kill -INT` 所有 `bluetoothctl --timeout` 掃描 client,unbind→bind 中間 `sleep 2`。
  - E3、E7 都是 1/1,而且都沒有 client、沒有廣播 instance、沒有連線。
  - v1 的 500 ms 間隔沒有試過。
- **修法**:
  - §3.4 / §4 加一份給 provd 的契約:「`/org/bluez/hci0` 的 `InterfacesRemoved` / `InterfacesAdded` → 撤掉並重新註冊廣播與 GATT;這段期間如果有交易進行中,依協定中止」。同時寫進 P2 的需求與測試。
  - 現在先在 04 實測一次:在 `btmgmt add-adv` 的 instance、進行中的 discovery session、500 ms 間隔的條件下做 rebind。斷言:bluetoothd 沒有 crash、`batman-sc` 換新、client 收到 Release、新的註冊可以成功。

### M5 安全段對非 root 程序的描述與 kernel 不符
- **設計寫的**:「非 root……能讓控制器真的忙(例如非 root 不能開掃描……)」;「HCI raw socket(皆 root / kernel 提供)」。
- **事實**:
  - 在 init netns 裡,非 root 也能建 HCI raw socket:`hci_sock_create`(`hci_sock.c:2192-2214`)沒有權限檢查,只有 `af_bluetooth.c:118` 要求 `init_net`。
  - `hci_sec_filter`(`hci_sock.c:134-160`、`:1875-1884`)允許非 root 送一批 OGF 1–5 的命令,包括 0x1001 和 OGF_LINK_CTL 的 inquiry 位元。這些命令會進 `cmd_q`,和 bluetoothd、探測搶同一份 command credit(`:1890-1900`)。
  - 有 `CAP_NET_RAW` 的程序可以送任何 vendor 命令(`ogf==0x3f` → `raw_q`,`:1890-1892`),包括 E7 用來誘發卡死的 `0xfc18`。
  - 有這些能力的對象:將來的 provd(uid 471,在 host netns)、任何非 root daemon、用 `--network host` 的容器。OTS 的 spike 就是這樣跑的(`deploy/ots/footprint-spike.sh:22`),正式 payload 的 netns 還要確認;cap-drop=ALL 只擋得住 vendor 命令,擋不住 raw socket 本身。
- **攻擊**:非 root 灌允許的命令,讓 cmd_q 積壓 → btwatch 的 3 s 期限連兩次沒等到 → 誤判 WEDGED → rebind。反覆 3 次就進 `gaveup`;配合 M3,這次開機永久沒有 BLE。
- **修法**:
  - 改正威脅描述。
  - 加負測試:非 root 程序灌 0x1001 或其他允許的命令 10 分鐘 → `bt_recover` 有上限(配合 M3 的速率限制),而且不會進永久 gaveup。
  - 考慮把一次失敗的定義改成「探測沒回應**而且** kernel 自己也記到 `tx timeout`(或 `cmd_cnt` 卡住)」。
  - 確認並寫下每個 payload 的 netns。

### M6 「運行中卡死能恢復」只有代理故障的 1/1 證據
- **事實**:
  - 自然卡死(02,`oe:1` → 從 `0x200c` 開始一路錯下去)從來沒有用 rebind 救過,當時是重開機。
  - E7 是鮑率不符(`0xfc18`),和自然的「接收溢位 → H4 失去同步」不是同一個機制。
  - E7 恢復時 client 已經被清掉,間隔 2 s(見 M4)。
  - E8 的獵捕到現在只有 08:11 那一筆,而設計說那筆是 E7 誘發的。
- **依規則**:宣稱修好某個現場症狀,要在真實症狀上證明,不能只靠代理故障。
- **修法**:
  - 獵捕繼續跑,直到至少 1 次**自然**卡死被「和 btwatch 完全相同的序列」(500 ms、不清 client)救回;或者把 T2 明確標為 ⚠️ 代理,交給使用者決定是否接受。
  - 500 ms 的間隔要有證據;沒有的話就用 2 s。

### M7 和 BLE tier-B harness 的互動沒定義,測試會被默默弄壞
- **情境**:`dv/ble-254.sh` 的 RPA (a) 段要求「≥ 30 分鐘不重新註冊 → 同一個 RPA」。這段期間 02 一直掃描、04 一直廣播,正是會自然卡死的條件。如果 btwatch 在這時做一次 rebind:
  - 廣播 instance 消失;
  - patch 900 重送 SC-only,把 `ble-periph flip` 的白箱狀態改回去;
  - RPA 換掉;
  - harness 的 pid 守衛(`ble-254.sh` 的 `pid0` 比對)看不出來,因為 bluetoothd 沒有重啟。
  
  結果是一個歸因錯誤的 FAIL 或 PASS。
- **修法**:harness PR 先做。每個 BLE 套件開始前、結束後讀 `bt_recover` 和 `bt-recover.log`,有變化就判該次 run **無效**(既不是 PASS 也不是 FAIL);白箱段用 M1 的 `bt-hold`。這些屬於「測項只有一套」規則下的 harness 改動,要先進 main。

---

## MINOR

1. **SIGTERM 延後的說法和程式不一致**
   - `main.go:425` 收到訊號後,在另一個 goroutine 直接 `os.Exit(0)`。
   - 沒有身分的路徑(`:399` `select{}`)根本沒裝訊號處理,SIGTERM 會照預設行為直接結束。
   - `:414`、`:421` 的 `os.Exit(1)` 在 btwatch 提前啟動之後,可能剛好落在 unbind→bind 中間。
   - 「兩次寫入中間不讓出」和 500 ms 的 sleep 互相矛盾。
   - procd `term_timeout=5`(兩台 `ubus call service list` 都是 5),逾時後 SIGKILL;SIGKILL 和 OOM 都擋不了。
   - → 用一個 rebind mutex,所有退出路徑都先拿這個鎖;訊號處理要在 btwatch 啟動前安裝;明寫「SIGKILL 留下的殘局由 UNBOUND 收」。
2. **UNBOUND 規則不計次數、不退避**
   - `bind` 一直失敗時(`hci_uart` 被 rmmod、driver 目錄不在;或 probe 出錯),每 15 s 寫一次 bind,每次都寫一行 p6 log:SD 卡持續寫入,log 一直被截斷。
   - 外部刻意的 unbind(harness 或人)會在 15 s 內被推翻。
   - → 只有在 state 檔記著「btwatch 自己 unbind 到一半」時才自動 bind;bind 失敗要計次數、要退避。
3. **index 會不會重用**
   - index 只在最後一個 reference 放掉時才釋放(`hci_release_dev`,`hci_core.c:2766`)。E3、E7 的 2/2 都是在沒有連線的情況下。
   - 新裝置如果拿到 hci1:health(`ReadInfo` 寫死 index 0)、`batman-sc` 的 `index=0`、btwatch 本身都會判 DOWN,又吃掉一次額度。
   - → 寫下這個假設和證據;用 `/sys/class/bluetooth/` 列出實際的 index;M4 的實測要包含有連線的情況。
4. **探測在 kernel 裡的副作用**
   - 0x1001 的 Command Complete 被溢位吃掉時(沒有卡死),kernel 會等 2 s 的 cmd timeout,這段期間 bluetoothd 的命令被擋住。
   - 探測如果是在 `req_status` PEND 時送出,會成為 `req_skb`(`hci_core.c:4064-4068`)。逾時時 `hci_cmd_timeout` 會取消那個進行中的 sync 操作(`:1462-1467`),bluetoothd 的 mgmt 操作因此回 ETIMEDOUT(例如將來 provd 的 add-adv)。
   - dmesg 會多出 `0x1001 tx timeout` 的行。
   - → 寫進設計;`-ENETDOWN` 視為略過,不算失敗;每次探測都開新 socket,用完就關,不要常駐綁在 hci0 上。
5. **`btwatch.state` 的契約沒寫**:格式、要不要帶 boot_id、寫壞或缺檔時往哪邊失敗,都沒有定義;halow-status 是它的讀者。`scripts/rundir-paths.txt` 要加 `btwatch.state`(走 harness PR);p6 的路徑表與備份清單要加 `bt-recover.log`。
6. **時鐘**:兩台的牆上時間都不對(實際是 10-24;02 顯示 2026-10-22,04 顯示 2025-07-20)。`<UTC>` 沒有意義,mesh 對時之後還會跳。→ 間隔和退避一律用 uptime / CLOCK_MONOTONIC;log 行以 `boot= up=` 為準,牆上時間只當參考。
7. **p6 log**:寫之前先確認 `/opt/batdata` 是已經掛好的 p6(查 `/proc/mounts`),沒掛就不寫,免得寫進 overlay。截斷時用同目錄的 tmp + rename(O_NOFOLLOW、0600);讀者要容忍最後一行殘缺。
8. **平台列**
   - 「bcm2710 沒有 `serial0-0`」不對:Pi 3A+ 的藍牙同樣是 `hci_uart_bcm` serdev。真正的原因是 bcm2710 的 image 裡沒有 batman-prov(`bin/targets/.../bcm2710.manifest` 只有 batman-provision;⚠️ manifest 可能過期)。
   - 缺 CM4 列,而 CM4 是量產板。沒有無線的 CM4 版本,DT 仍然有 BT 節點 → setup 永遠卡住 → 每次開機都會反覆恢復。
9. **goroutine 的耦合**
   - 「與 health tick 同步」語意不清。health tick 在 10 分鐘後,每 15 s 都會跑 `bootConfigOK`(mount p3 + vcgencmd + batman-slot),有可能卡住。
   - → btwatch 用自己的 ticker;定義 `hci0_alive` / `bt_state` 怎麼交給 health(mutex 加時間戳,超過 30 s 視為 0);每個 goroutine 都要 recover,免得 btwatch panic 把 helper 的 socket server 一起帶走。
   - 45 s 和「連續 2 次」的計時都放在記憶體裡,helper crash loop 時每次都歸零,永遠恢復不了。→ 計時要存進 state 檔。
10. **autocommit 將來的閘門**:現在的比對還在看 `hci0_powered=1`,而 E6 證實這個欄位在卡死時是假的。→ 寫給 P2:閘門要改看 `hci0_alive` / `bt_state`;也要決定「trial 期間 btwatch 做過恢復」算健康還是不健康。
11. **`btdPid` 只看 comm**(既有問題):非 root 可以把自己的 comm 改成 `bluetoothd`,btwatch 的「bluetoothd 在跑」閘門會被騙(影響小)。→ 改看 `/proc/<pid>/exe == /usr/bin/bluetoothd`,而且 uid 是 0。
12. **rfkill 分支是死碼**:kernel 沒有 rfkill 裝置,這個分支測不到。→ 要嘛拿掉,要嘛列為將來 EMCON 的前置條件,和 M1 的 `bt-hold` 一起設計。

## 生命週期矩陣缺的列(REVIEW.md 第 3 項)
- **OTA stage 1 / 2**:sysupgrade 的 kill_remaining TERM→KILL 剛好打在 rebind 中間也沒關係,接著就會重開;寫一句說明即可。
- **autocommit commit / revert**:trial 期間做過恢復要怎麼算,見 MINOR 10。
- **dbus restart**:bluetoothd 會跟著重啟。
- **hci_uart 模組被 reload**:見 MINOR 2。
- **CM4**:見 MINOR 8。
- **「helper crash loop」列**:只寫了次數,沒寫計時會歸零(MINOR 9)。
- **「乾淨關機」列**:K15 時正在退避也沒影響,寫一句即可。

## 驗證過、成立的部分
- 卡死時只有 0x1001 說實話(E6),和 hunt log 08:11 那筆相符:`readinfo_powered=1 hci_version=noreply ms=5239`。
- raw socket 送的非 vendor 命令走 `cmd_q` 和 command credit,不會繞過 kernel 的排序(`hci_sock.c:1893-1900`)。它的 Command Complete 不帶 req_complete,所以 `hci_req_cmd_complete`(`hci_core.c:3901-3950`)不會把 bluetoothd 的請求誤判為完成。
- 兩台都有 `serial0-0` → `hci_uart_bcm`;04 的 BT DT 節點有 `shutdown-gpios`。helper 是 `respawn 3600 5 0`、`term_timeout 5`(兩台的 ubus 輸出)。
- patch 900 在 index 重新加入時會重寫 `batman-sc`,內容帶 `index=<dev_id>`。
- health 行尾加欄位不會打壞現有讀者:autocommit 用有順序的 glob(`:498`),`prov-p1-254.sh:48` 逐鍵 `grep " $k=[01]"`。
