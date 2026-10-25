# #305 mini UART 硬體流量控制(P1 + P2)設計 v4 — 對抗式審查 B(第 4 輪)

審查對象:`305-mini-uart-flow.md` v4(整份重審)、P1 `999-batman-bcm2835aux-autoflow-305.patch`(c002892b;spike 跑的是 `.v1.patch` 86e8f027)、P2 `999-batman-hci_bcm-close-flow-305.patch`(73ee8d01)。
對照:使用者全域規則、kernel 6.6.138 build 樹(目前是 spike2 版原始碼)、BlueZ 5.72、Batman main a62bf78 的 harness、`scratchpad/r305/` 原始紀錄、02 / 04 唯讀探測(只讀 /proc、/sys、dmesg、`/opt/batdata/log/*`;沒有寫入、沒有 bluetoothctl、沒有重開)。

## 結論:**REJECT(範圍窄)— 0 BLOCKER / 1 MAJOR / 10 MINOR**

- **兩個 patch 的程式碼我沒有找到缺陷**,可以照現在的版本進 firmware PR:
  - P1 v4 和 v1 的 diff 只有 sysfs(`DEVICE_ATTR_ADMIN_RO` + `dev_groups`,並拿掉 `device_create_file` / `device_remove_file`)。driver core 在 probe 成功後才建 group、在 `->remove` 之前就移除,所以 `autoflow_show` 看到的 `data->line` 一定有效。
  - P2 的所有呼叫點、鎖順序、port 狀態我都查過(E1–E4),serdev 路徑上是安全的。
- **第 3 輪的 MAJOR 都已關**(見下表)。
- **唯一的 MAJOR 在 T2**:`adv-fast` 照 v4 的寫法做不出來。
  - 04 的控制器只有 legacy 廣播。kernel 在 legacy 路徑上,對「不可連線、且 adapter 不是 discoverable」的廣播,會**默默**把 interval 改成 100–150 ms。
  - mgmt 也沒有任何回讀 interval 的方法。
  - 另外,v4 把廣播交給 `ble-periph-254.sh`,但那是 04 的角色腳本;02 當廣播者的那一段沒有擁有者。
  - 照寫實作的結果只有兩種:T2 永遠 FAIL,或實作者默默拿掉檢查。所以 harness PR 動工前要先改設計(M1)。

### 第 3 輪 BLOCKER / MAJOR 是否已關

| 第 3 輪 | 狀態 | 證據 |
|---|---|---|
| B v3 M1 / A v3 M1:close 120 ms 是假象 | ✅ **已關** | 選了根解 P2。`closewait3.log`:舊 kernel 用 0x01(TXEN 關)注入、`tx_fill=4`,unbind **30140 ms**。`spike2.log`:P1 + P2 用 0xcd 注入、`tx_fill=4`,unbind **120 ms**;unbind 後 `CNTL=0x03 tx_fill=0`,而且 `writes` 19→20 只多了 1 筆 0x03 = P2 的 set_termios 依快取重寫 CNTL(TXEN 回來)。⚠️ 負對照是舊 kernel(兩個 patch 都沒有),不是「只有 P1」(m1) |
| A v3 M2:T5 的 `uname -v` 沒有分辨力 | ✅ 已關(改用 `BATMAN_VERSION`) | 版本比較的語意還要補(m5) |
| B v3 m1 / A v3 m1:rebind 序列 | ✅ | 我逐行對過 `spike2.log`:開機 `writes=4 last=0xcf,0x03,0x8b,0xcf`;每次 unbind +1(0x03);每次 bind +4(0xcf,0x03,0x8b,0xcf)。和 §4 一字不差。我也照原始碼推了一次(E5),結果相同 |

---

## 查證(我自己看過的原始資料)

| # | 事實 | 證據 |
|---|---|---|
| E1 | `bcm_close` 的所有呼叫點,在 serdev 路徑上 port 都還開著 | `hci_serdev.c:406`(unregister,`:408-410` 才 close);`:385-388`(register 失敗:先 `p->close`,再 `serdev_device_close`)。`hci_uart_close` 只有在 `HCI_QUIRK_NON_PERSISTENT_SETUP` 時才關 port(`:152-157`),而 hci_bcm 沒有設這個 quirk(grep 只命中 qca / mtk / btusb / vhci)→ `bcm_close` 不會碰到已經關掉的 `serport->tty`(那時會是懸空指標) |
| E2 | 睡眠與鎖的情境和上游 `bcm_open` 相同 | P2 在 `bcm_device_lock` 這個 mutex 內呼叫 `serdev_device_set_flow_control` → `tty_set_termios`(termios_rwsem)→ `uart_set_termios`(port mutex)。`bcm_open` `:489-507` 本來就在同一個 mutex 內做同一件事 → 沒有新的鎖順序。`bcm_suspend_device` `:778` 也一樣 |
| E3 | 非 serdev(ldisc)路徑只有 platform / ACPI 的 bcm 裝置會走到 | `bdev` 只有在 `bcm_device_exists` 時才不是 NULL;`bcm_device_list` 只由 platform probe 加入(`hci_bcm.c:1294`)。Pi 用的是 DT serdev → fleet 不會走到。但在 ldisc 路徑上,`hci_uart_tty_close` 是在 driver 已經 `uart_close` 之後才跑,而 `uart_set_termios` 不檢查 `tty_port_initialized`(`serial_core.c:1694-1745`)→ P2 會對已經 shutdown 的 port 呼叫 `ops->set_termios`(m3) |
| E4 | P2 在 `hci_uart.ko` 裡,不在 kernel8.img | `.config`:`CONFIG_BT_HCIUART=m`、`CONFIG_BT_HCIUART_BCM=y`;04 `/proc/modules` 有 `hci_uart 32768 0`;`/lib/modules/6.6.138/hci_uart.ko`。bcm2710 的 `.config` 沒有 `BT_HCIUART_BCM` ✅(§6 的說法成立) |
| E5 | rebind 序列(P2)和原始碼推導一致 | termios 保存在 `driver->termios[idx]`(serial core 沒有設 `TTY_DRIVER_RESET_TERMIOS`)。P2 關閉時已經清掉 CRTSCTS → 下一次 open 的 startup 沒有寫入 → ttyport 設 CRTSCTS(RTS 高)→ 0xcf → `bcm_open` 寫 0x03 → 上電後先開 CRTSCTS(RTS 低)→ 0x8b → 拉高 RTS → 0xcf。沒有 P2 時多一筆(spike1 的 5 筆)→ **T3 的「unbind 1 筆、bind 4 筆」本身就是 P2 在執行期的見證** |
| E6 | **04 控制器只有 legacy 廣播** | `254-reviews/review-v15-B.md:56`:04 `bluetoothctl show` 只有 `SupportedInstances: 0x05`,沒有 `SupportedSecondaryChannels` → `ext_adv_capable == false`(`hci_core.h:1914`) |
| E7 | **legacy 路徑會改寫 interval** | `hci_sync.c:1856-1934` `hci_enable_advertising_sync`:不可連線,而且 `!HCI_DISCOVERABLE \|\| HCI_LIMITED_DISCOVERABLE` → interval 改成 `DISCOV_LE_FAST_ADV_INT_MIN/MAX` = 0xA0 / 0xF0(100 / 150 ms,`hci_core.h:2259-2260`)。mgmt `add_ext_adv_params`(`mgmt.c:8865-8945`)照樣回成功。#254 的設計讓 04 不是 discoverable(`DiscoverableTimeout=0`,provd 斷言 Discoverable==false)。connectable 的定義是 instance 旗標 `-c` 或全域 `mgmt_get_connectable`;04 全域 connectable 的值 ⚠️ 我沒讀到(只有 bluetoothctl 讀得到,不在允許範圍) |
| E8 | BlueZ 5.72 的語法可行 | `client/mgmt.c:4938-4955`:`-r` / `-x` 兩個都給才會帶 `MGMT_ADV_PARAM_INTERVALS`(`:5045-5046`),`-c` = connectable;`advinfo` 輸出不含 interval |
| E9 | BLE 角色是固定的 | `ble-periph-254.sh:2`「BLE_PERIPH = 04」,staged 工具有 btmgmt 與 btmon;`ble-central-254.sh:2`「BLE_CENTRAL = 02」,只 stage lib 與腳本,只有 `bluetoothctl --timeout N scan on`,沒有任何廣播指令;`daily-validation.sh:245-246`:`BLE_PERIPH` 不是 DNODE 就整組 FAIL |
| E10 | 互動式 bluetoothctl 會註冊 agent | `254-stage1-impl.md:505`:session 期間 current settings 會出現 `bondable`。`ble_state`(`ble-lib-254.sh:140-160`)會把帶 `BATMAN_DV_BLE` 的 bluetoothctl 當殘留;§10 用的掃描(`xo2-tick.sh`)正是互動式的 `menu scan / duplicate-data on` |
| E11 | 調查模組只依賴 vermagic | `r305raw.c` 只用 `ioremap` / `readl` / `writel`,沒有其他 symbol;04 `vermagic=6.6.138 SMP mod_unload aarch64`、`# CONFIG_MODVERSIONS is not set`、`# CONFIG_MODULE_SIG is not set` → 同一個 `.ko` 可以載入任何 6.6.138、同一 config 的 rc |
| E12 | build 樹的狀態 | WSL `git status` 乾淨(Windows 端看到的 `M` 是換行字元假象);2711 的 `.prepared_edc6cf90…` 是 10-24 20:26(spike2)建立的;`include/kernel-build.mk:13` 的 prepare stamp 含 patch 目錄的 md5 → patch 一改就會重新 prepare(§9 的 ⚠️ 這點可以改成有證據)。bcm2710 的 build_dir 是 10-02 的,**沒有**套過任何 #305 patch → P1 在 a53 / bcm2710 config 下還沒編過(m9) |
| E13 | known-failures 的「永不 KNOWN」字詞 | `daily-validation.sh:2704` `NEVER_KNOWN='restore\|cleanup\|CONNECTION-LOST\|…\|unreadable\|not verified\|…'`:FAIL 行裡有這些字就一律算 NEW |
| E14 | 退役號碼的規則 | `VERSIONS.md:73-75`:退役的 rc 號碼「never flash or ship them」 |
| E15 | 04 現況 | slot A wsl.15,沒有 `autoflow`,ttyS0 沒有 `oe`;10 分鐘前的重開是 `trigger=r305-restore-A2`(boot-reasons),有交代。02:wsl.15,uptime 16.8 h,dmesg 有 `Frame reassembly failed`(舊 kernel 的自然溢位還在發生) |

---

## MAJOR

### M1 — T2 的 `adv-fast` 照寫做不出來:legacy 會默默改 interval、沒有方法回讀、02 那一段沒有擁有者、DUT 的掃描會在 04 上註冊 agent

**現場 / 實作情境**:實作者照 §8 寫 `ble-periph-254.sh adv-fast`,送出 `add-ext-adv-params -r 0x20 -x 0x20`(不可連線)。

1. **interval 被默默改掉**:kernel 回成功,但實際送給控制器的是 100–150 ms(E7)。
   - §8 要求「記錄控制器實際接受的 interval,不接受 20 ms 就判 FAIL」,可是 mgmt / advinfo 都讀不到 interval(E8)。
   - 唯一看得到的是廣播端的 btmon(`LE Set Advertising Parameters`)。照實記錄,T2 會永遠 FAIL;不記錄,這條判準就是空的,實作者只能默默拿掉。兩種都會讓錯的實作進 main。
2. **擁有者錯了**:
   - `ble-periph-254.sh` 是 04 的角色腳本(E9)。
   - T2 第一段「DUT = 04、對端廣播」的廣播者是 02(§8 還特別說「02 開著 privacy」),但 02 跑的是 `ble-central-254.sh`:沒有廣播指令,也沒有 stage btmgmt / btmon。
   - 「對調 02 / 04」不能靠換角色,因為 `BLE_PERIPH` 必須等於 DNODE(`daily-validation.sh:245`)。
3. **DUT 掃描會碰 #254 的安全狀態**:
   - §10 的負載是 04 自己跑互動式 `bluetoothctl` 的 `duplicate-data` 掃描(`xo2-tick.sh`),這會註冊 agent,current settings 會出現 `bondable`(E10)。
   - 04 是 #254 的 SC-only 目標:30 分鐘的 agent 窗口會改變配對面;`ble_state` 也會把它當成殘留。v4 沒有寫掃描由誰執行、怎麼關 agent、怎麼清。

**修法**(先選定再寫進 §8):
- (a) **不要求 20 ms**:
  - adv-fast 只是加負載。判定只看 DUT 端的負載保證:UART ≥ 1 KB/s、看到標記、diskstats。
  - 實際 interval 用廣播端的 btmon 記錄成資訊,寫明 legacy 下預期是 0xA0–0xF0(`hci_sync.c:1913-1918`)。
  - 或 (b) 用 `-c`(connectable)讓 20 ms 生效:要寫清楚 connectable 窗口的副作用(04 是 SC-only 目標;lease 期間、不註冊 agent),並以 btmon 斷言實際 interval = 0x20。
- **每一段都寫明誰廣播、誰掃描、用哪支腳本**:
  - 02 當廣播者 → 在 `ble-central-254.sh` 加 `adv-fast` / `adv-fast-off`。非互動的 `bluetoothctl mgmt.add-ext-adv-params` 就可以用,E6 已經證明非互動 mgmt 不註冊 agent;但要處理 advinfo 偶發 segfault(E39 的重試)。
  - 04 當廣播者 → `ble-periph-254.sh`。
  - 兩支的清理都要做:`rm-adv` 並確認 advinfo = 0;deadman 的 `role_fire_restore` 要清掉新的 instance 號碼(現在只清 instance 1,`ble-periph-254.sh:171`)。central 的 deadman 也要補。
- **DUT 掃描的 session**:
  - 互動式 bluetoothctl 加 `agent off`(`client/main.c:847`),帶 `BATMAN_DV_BLE=1`,在 lease 內,以 process group 啟停。
  - 結束後 `ble_state` 必須 clean,並斷言 current settings 沒有 `bondable`。
- **其他 instance**:斷言 instance 1 沒被佔用(legacy 多 instance 會輪播,負載會減半),或寫明會輪播。

---

## MINOR

**m1 —「只有 P1、沒有 P2」可以很便宜地實測,應該當 T3b 的真負對照;P2 的 commit message 也說過頭了。**
- §6「沒有 P2 = 30 s」那一列的證據欄是 ✅,但 30140 ms 是在兩個 patch 都沒有的舊 kernel 上量的,只有原始碼推論支持 P1-only 的情況。
- P2 標頭寫「measured 30.14 s on the mini UART」,這會讓人以為量的是 P1 硬體 CTS 下的情況。
- **便宜的翻轉測試**(只換 P2,其他相同):
  - `hci_uart` 是模組(E4),vermagic 通用、沒有 MODVERSIONS / 簽章(E11),refcount 0。
  - 用同一棵樹、不套 P2 編一個 `hci_uart.ko`。在 rc 上 `rmmod hci_uart; insmod <無 P2 版>`,跑 T3b,預期約 30 s;重開還原。
- 修法:T3b 加這一段當負對照(和 T3b 本身一樣,每個 rc 一次);P2 標頭改成「measured 30.14 s with TX held off (old kernel); with 999-…-autoflow CTS the same wait applies by source」。

**m2 — T3 每天在部署節點上 rebind 10 次,但沒有斷言 rebind 後的 #254 安全狀態。**
- rebind 會產生新的 hdev,`HCI_SC_ONLY`、privacy、bondable 都要等 bluetoothd 接管後重新設定(patch 900 每次接管都送 SC 模式)。
- 但 `batman-sc` 的 boot_id 和 pid 在 rebind 前後都一樣,`sc_file=1` 分辨不出「重新送過」和「舊檔案」。
- spike2 只在開機時看過 health,3 次 rebind 後都沒看。
- 修法:T3 每次 rebind 後,以非互動 mgmt `READ_INFO` 斷言 current settings 有 `privacy`、`secure-conn`、沒有 `bondable`;`batman-sc` 的 mtime 要比 rebind 新(或 patch 900 的 log 行多一筆)。不符就 FAIL,並 `bluetoothd restart` 還原。§6 的 rebind 列也補上這一點。

**m3 — P2 建議限縮在 serdev 路徑:`if (hu->serdev) hci_uart_set_flow_control(hu, true);`。**
- 在 ldisc 路徑上,`bcm_close` 是在 driver 已經 `uart_close` 之後才跑(E3),P2 會對已經 shutdown 的 port 呼叫 `ops->set_termios`。像 PL011 這類 shutdown 時關 clock 的驅動,這是碰暫存器的風險。
- fleet 走不到這條路,但 patch 是放在共用樹裡的 downstream 改動,限縮沒有成本,行為也和 spike2 相同。

**m4 — known-failures 的 FAIL 字句要先定,而且要能分辨「pre-#305 image」和「宣稱有 #305 卻沒有」。**
- 如果 T1 / T3 / T5 的 FAIL 行含 `unreadable` / `not verified` 等字,會被 `NEVER_KNOWN` 擋成 NEW(E13)。
- 如果 ERE 寬鬆到 rc 上真的少了 patch 也匹配,出貨前的全套會把真回歸標成 KNOWN。
- 修法:
  - 照 `prov-p1-stubs` 的做法,固定一句 `FAIL bt-uart-305: pre-#305 image (<依據>) — no autoflow`。只有 image 判定為 pre-#305 時才印這句;判定為 #305 卻沒有 autoflow 時印另一句(NEW)。
  - §8 寫明:rc 與出貨驗收時,T1 / T3 / T5 必須 PASS,KNOWN 不算過。

**m5 — T5 的「版本 ≥ 產品版號」語意沒寫,建議改用 feature 標記。**
- `1.5.13-wsl.N` 和 `1.5.13` 誰大(SemVer 的 pre-release 小於正式版)要寫死比較規則。
- harness PR 先進 main,門檻號碼要事先猜:如果其他單先用掉 1.5.13,門檻就錯了。
- 修法:產品 PR 在 `batman-release.env` 的 `BATMAN_FEATURES` 加 `miniuart-autoflow(#305)`(它會進 `/etc/batman-build`)。T1 / T5 依各 slot 的 FEATURES 推預期,m4 的「pre-#305 image」也用同一個依據。這也是 A v3 M2 提過的「feature 標記」那一選項。

**m6 — §8.3「harness PR 的 rc PASS 只能在 spike 上跑」和 §9「spike 號碼退役」矛盾。**
- 退役號碼依 `VERSIONS.md:73-75` 永不再燒(E14)。v1 spike 的 P1 sha 和產品也不同。
- 修法:順序改成:
  1. 開 harness PR;
  2. 從 firmware 的 issue branch(patch 已 commit)build `1.5.13-wsl.1`(rc,DIRTY = 0);
  3. 用 harness branch 跑:wsl.15 FAIL(KNOWN 字句)+ rc PASS;
  4. merge harness;
  5. 從 main 在 rc 上跑全套;
  6. 開 firmware PR。
- 這樣 §8.3 那段「patch sha 不同 → 重跑」就可以刪掉。

**m7 — T3b 與 T4 沒有進常規全套。**
- 使用者規則:每個 fix 的回歸測試都要進常規 validation suite,破壞性的也算。
- 「每個 rc 驗收一次」若只是手動工具,就不在「全套」裡。
- 修法:T3b(含 m1 的負對照)與 T4 進 `daily-validation.sh`,標成破壞性 / 慢項(像 `ble-pair-sc-only-254` 的 `D`),全套就會跑到。P2 的每日回歸由 T3 的序列承擔(E5),這點也寫進 §8。

**m8 — r305raw「每個 rc 依 vermagic 重編」沒有必要,反而多了一個每次都會變的產物。**
- E11:同一個 `.ko` 可以用於所有 6.6.138 rc。
- 修法:
  - 編一次,放進 harness bt-tools,附 SHA256SUMS;
  - insmod 前斷言 `modinfo -F vermagic` 等於節點上 `hci_uart.ko` 的 vermagic,不符就 FAIL,不 insmod;
  - kernel 升版時才重編。
- 補充:insmod 後 kernel 會帶 `O` taint,T3b 的重開會清掉。r305raw 原始碼的註解「8250 driver never rewrites CNTL」在 P1 之後已經不成立,要更新。

**m9 — §9 的 build 驗證要涵蓋 P2 所在的模組,以及 bcm2710 的實際編譯。**
- `strings kernel8.img` 只證明 P1;P2 在 `hci_uart.ko`(E4),沒有字串可以見證。
- bcm2710 的 build_dir 從沒套過 #305 patch(E12),「-Werror 編譯通過」只在 2711 config 下做過。
- 修法:
  - 兩板的 build_dir 都 grep `Batman #305`(兩個檔案);
  - 確認 rootfs 裡的 `hci_uart.ko` 比 build_dir 的 `hci_bcm.c` 新,或比對 `hci_bcm.o` 的 objdump 有多出的呼叫;
  - 執行期的見證寫明是 T3 的序列(E5)。
- §9 的「OpenWrt 會重新 prepare(⚠️)」可以引用 `kernel-build.mk:13`,改成有證據。

**m10 — 小項。**
- §2 / §4 的行號是 spike2 樹上的偏移:`hci_bcm.c:1586-1587` 實際是 `bcm_serdev_remove`,`drive_rts_on_open = true` 在 `:1595`(加了 P2 之後)或 `:1587`(原始樹)。`bcm_open` 是 `:490` / `:506`,不是 `:491` / `:504` / `:507`。全部改成以原始樹為準並註明。
- T3b「結束時重開還原」:`spike2.log` 顯示 rebind 後已經是 `hw=0xcf cache=0xcf`,驅動自己就把狀態還原了。重開可以保留(也順便清 taint),但判定應該加上「rebind 後 hw == cache」。

---

## 各面向逐項

**P2 的範圍(所有呼叫點)**:
- serdev unregister、register 失敗兩條路徑都在 port 開著時(E1);
- ldisc 的三條路徑(`hci_ldisc.c:198`、`:557`、`:692`)在 Pi 上 `bdev` 都是 NULL(E3);
- runtime PM:`pm_runtime_disable` 在前;即使之前已 suspend(RTS 已低),再呼叫一次也是冪等的;
- 下一次 open 的 RTS 握手由 `bcm_open` 自己重做(E5)。
- → 安全。建議 m3。

**§4 序列 vs `spike2.log`**:✅ 完全一致。

**P1-only 沒有實測**:影響的只有「P2 是必要的」這個說法,以及 §6 那一列的 ✅ 標記。設計本身不受影響,可以用 m1 便宜補上。

**T2**:M1。

**T3b 在 harness 的可行性**:可行,而且比設計寫的簡單(m8)。但要進全套(m7)。

**版號與 build 計畫**:1.5.13、兩板、DIRTY = 0 都具體,DIRTY 機制也是用 git 判定(`stamp-batman-build.sh`)。要補 m5、m6、m9 才能開始。

**生命週期**:補 m2(rebind 後的安全狀態)。其他列我逐列對過,沒有缺漏:
- install / start / clean stop / restart / OTA / rollback / downgrade / crash / 斷電 / 各依賴重啟都有;
- 平台:bcm2710 只 build、bcm2712 N/A、CM4 ⚠️ 殘項。

**安全(逐 actor)**:
- 遠端:同意 ⚠️ 預期改善。
- 本機非 root:沒有 tty 節點,sysfs 是 0400 ✅。
- 被入侵的 peer / 容器:碰不到。
- 我們自己的錯:
  - T3 用 `writes` 序列釘住 P1 的閘門與 P2;
  - T2 若照 v4 實作會變成空判準(M1);
  - T3 每天 rebind 帶來的安全狀態風險(m2);
  - r305raw 是 root 才能載入的暫存器寫入工具,要放在 0700 的 run dir 並驗 sha(m8)。
- 供應鏈:patch 套不上 build 就失敗(fail-closed)。
- 秘密:沒有新增。

## 判定

**REJECT(範圍窄)**:
- P1 c002892b 與 P2 73ee8d01 的程式碼可以凍結。P2 可以考慮 m3 的一行限縮;若採用,T3 / T3b 要在新 sha 上重跑。
- 要改的是 §8 的 T2(M1:interval 的判準、每一段的擁有者、DUT 掃描的 agent),這會改變 harness PR 的內容,所以要先定。
- m1–m10 和 M1 同一版修完,再整份重審。
