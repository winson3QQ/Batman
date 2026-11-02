# #305 mini UART 硬體流量控制設計 v2 — 對抗式審查 A(第 2 輪,整份重審)

**審查對象**:`305-mini-uart-flow.md` v2(整份,不只看 §12 的改動)。對照:第 1 輪 `review-flow-v1-{A,B}.md`、`docs/design/REVIEW.md`、build 樹 kernel 6.6.138 原始碼(`build_dir/.../linux-6.6.138`)、firmware 樹 build 腳本、02/04 唯讀探測(只做了 `cat /proc/...`、`dmesg`、`which`、`bluetoothd -v`,以及 04 上不帶參數的 `insmod r305aux.ko && rmmod`)。

## 結論:**REJECT(範圍窄)— 0 BLOCKER / 3 MAJOR / 8 MINOR**

patch 的核心邏輯這次是對的。§4 的 hook 結構、鎖、不設 `UPSTAT_AUTORTS`、以 RTS 當 AUTORTS 的閘門,我逐一對過 6.6.138 的呼叫圖都成立,見文末 ✅ 段。第 1 輪的 BLOCKER 已確實關閉。

還沒關的有三件,都在介面和測試:
- **M1 close 會卡 30 s。** B-M5 用來結案的證據是錯的,而且錯誤源頭是我第 1 輪的「已查證」條目,在此更正。
- **M2 出貨見證 T1 照寫的做法不能用。** dmesg 環形緩衝在 04 上已經滾掉開機紀錄,寫下的時序也和實際不符。
- **M3 T2 的「負載保證」沒有可實作的機制。**

M1 和 M2 的修法會改到 patch 本身(closing_wait、sysfs 見證),所以要再整份審一輪。

---

## 更正第 1 輪紀錄(我的錯)

我在 `review-flow-v1-A.md:122` 寫了 ✅「`uart_wait_until_sent` 把等待時間限制在 2 × FIFO timeout,所以 rebind 時就算 AUTOCTS 擋住 FIFO,close 也不會卡 30 s」。**這是錯的。** 那個上限只在 `!uart_cts_enabled(port)` 時才生效(`serial_core.c:1847-1858`)。v2 §3 和 §6 引用這一條,把 B-M5 標成已解。詳見 M1。

---

## MAJOR

### M1 AUTOCTS 擋住 TX FIFO 時,unbind 會等滿 `closing_wait` = 30 s;B-M5 實際上沒有關

**情境(現場)**:控制器韌體卡死,卡死時它的 RTS 停在 de-asserted,例如它的接收緩衝滿了、而且不再消化。主機這時還在送 HCI 命令(bluetoothd、`hci_dev_close_sync` 的命令都會送),最多 8 bytes 卡在硬體 TX FIFO。接著有人 rebind(人工或日後的恢復機制),或者 hci0 被 unregister。

**證據**:
- `serial_core.c:1847-1858`:`if (!uart_cts_enabled(port)) { … timeout = 2 * fifo_timeout; }`。只有 CTS flow 關閉時才有上限。
- `serial_core.h:1009-1012`:`uart_cts_enabled` = `UPSTAT_CTS_ENABLE`;`serial_core.c:222-223`:CRTSCTS 開時設這個位元。`serdev-ttyport.c:136` 會一律設 CRTSCTS。結論:藍牙這個 port 永遠沒有這個上限。
- `tty_port.c:100`:`closing_wait = 3000*HZ/100` = 30 s。`tty_port.c:654-655` 在 close 時呼叫 `tty_wait_until_sent(tty, closing_wait)`,接著走 `uart_wait_until_sent`,一直等到 `tx_empty`。
- 卸載順序:`hci_serdev.c:406-410` 先 `proto->close`(= `bcm_close` 斷電,`hci_bcm.c:554`),後 `serdev_device_close`。§3 自己量到斷電後 `cts_line=1`(CTS de-asserted)。所以在 0xcf 下,只要斷電那一刻 FIFO 還有東西,就永遠送不出去。
- `hci_uart_flush`(`hci_serdev.c:94-111`)只清軟體 xmit buffer(`serdev_device_write_flush`),不清硬體 FIFO。FIFO 要到 `serial8250_do_shutdown` 的 `clear_fifos`(`8250_port.c:2531`)才清,而這一步在 wait **之後**。HUPCL 拉低 RTS 也在 wait 之後(`tty_port_shutdown`)。
- §3 的「120–130 ms」全部是 `tx_fill=0` 下量的(`r305aux/disc.log:1,4,7,10,13,16,20,24`,每一筆都是 `tx_fill=0`)。btwedge 製造的卡死是鮑率錯開,控制器的 RTS 照樣 asserted,所以 FIFO 送得掉,碰不到這個情境。
- 今天這條路徑幾乎走不到。原因是軟體 CTS 的 `hw_stopped` 只在 `uart_change_line_settings` 取樣一次(`serial_core.c:234-236`),硬體 FIFO 照送。**patch 讓「FIFO 卡住」第一次變得可以發生**,所以這是 patch 引入的新行為,不是既有問題。

**影響**:恢復動作(rebind)最壞要 30 s,再加上 `hci_dev_close_sync` 的命令逾時。T3 的「unbind < 5 s」只在 FIFO 空的路徑上量,分辨不出這個情況。§6「close 上限 2 × FIFO timeout(實測 120 ms)」這一列是錯的。

**修法**(要在設計裡選一個,再上測試):
1. 甲(建議):probe 註冊完後,把這個 port 的 `state->port.closing_wait` 設成很短的值,或 `ASYNC_CLOSING_WAIT_NONE`。藍牙在 close 時丟掉最多 8 bytes 無害,因為控制器已經斷電。要附證據說明 `serial8250_get_port(line)->port.state` 在 register 之後就有效,並且寫進 §5 擁有權表:`closing_wait` 的寫者是驅動,serial core 的 TIOCSSERIAL 是第二個寫者,但 serdev 沒有使用者能呼叫它。
2. 乙:接受最多 30 s,寫進 §6、§7,並寫明恢復機制的時間預算。
3. 不論選哪個,都要加一個白箱測試 **T3b**(要使用者授權):在 rc 上用 `r305aux cntl=0x4f`(錯的 CTS 極性。§3 量過,0x4f 時 TX 被擋,探測 3/3 失敗)讓 TX 卡住 → 送一次 btprobe → 用 r305aux 唯讀確認 `tx_fill>0` → 對 unbind 計時 → 重開還原。甲:斷言 < 5 s,負對照是不帶修法的 rc,應該 ≈ 30 s。乙:斷言 ≤ 31 s,而且確實會恢復。

### M2 出貨見證 T1 照寫的做法不能用:dmesg 會滾掉、時序寫錯、在 port lock 下 printk

**證據**:
1. **環形緩衝**:04 現在 `dmesg | head -1` 是 `[ 9883.161753] flightrec: …`,uptime 13 h,`CONFIG_LOG_BUF_SHIFT=17`,開機那段已經被 flightrec 和 Frame reassembly 擠掉了(04 目前有 108 行 Frame reassembly)。T1 放在 tier A 每天跑,對象又是長時間開機的 fleet 節點。照「找不到 → FAIL」的寫法,會天天出現假 FAIL。照「放寬」的寫法,就變成什麼都證明不了。logread 也是環形緩衝,同樣的問題。
2. **時序寫錯**:`hci_uart_set_flow_control` 的 serdev 路徑是先改 CRTSCTS、再改 RTS,分兩步(`hci_ldisc.c:319-321`)。每一步各走一次 `set_termios`→`set_mctrl` 或 `tiocmset`→`set_mctrl`(`serial_core.c:1121-1135`、`8250_port.c:2920`)。實際的見證序列:
   - **首次 bind**:`0xcf`(ttyport_open)→ `0x03`(`:491` 關 CRTSCTS,當時 RTS 還是高)→ `0x8b`(`:507` 開 CRTSCTS,RTS 還是低)→ `0xcf`(RTS 拉高)。
   - **rebind**:tty termios 跨 open 保留(serial 驅動沒有 `TTY_DRIVER_RESET_TERMIOS`),所以 `uart_port_startup`→`uart_change_line_settings` 一開始就帶 CRTSCTS,而 RTS 還是低(上次 close 被 HUPCL 拉低)。序列是 `0x8b → 0xcf → 0x03 → 0x8b → 0xcf`。`ttyport_open` 的 `tty_set_termios` 因為 cflag 沒變,在 `serial_core.c:1725-1731` 直接跳過。
   - **unbind**:`0x8b`(HUPCL)→ `0x03`(shutdown hook)。

   §4 寫的「0xcf → 0x03 → 0xcf」和 T1 的「時序符合 §4」,會讓正確的實作 FAIL。0x8b 這段窗口本身無害:控制器已上電,RTS 是手動 de-asserted,和今天一樣。但是要寫對。
3. **在 port lock 下 printk**:`update_flow` 從 `set_mctrl` 被呼叫時一定持有 port lock、IRQ 關著(`serial_core.c:181-186`、`8250_port.c:2817/2920`)。如果這個 port 是 console(Pi 3 或日後 `console=serial0` 對到 ttyS0 的板子),printk 會同步呼叫 `serial8250_console_write` 去拿同一把鎖,結果是自鎖。今天 console 是 ttyAMA0(02/04 `/proc/cmdline`),所以現在不會發生。但另一個問題現在就在:ttyAMA0 接 GPS,console 是 polling 輸出,印一行時這顆 CPU 會在 IRQ 關閉下停留好一段時間。
4. **只印一次**:`dev_info_ratelimited` 每個呼叫點的預設上限是 5 s 內 10 次。n_tty + crtscts(T6、Pi 3 GPS)每次 throttle/unthrottle 都會切換一次 AUTORTS,會被洗版。
5. REVIEW.md §2 把「其他工具解析的 log 行」列為契約。§5 沒有寫這個契約(寫者、格式、不存在時怎麼處理)。

**修法**:見證改成**唯讀 sysfs 屬性**,例如 platform device 下的 `auto_flow`,讀回**硬體暫存器** CNTL 和快取 `data->cntl`。T1 斷言 init 後 HW == cache == `0xcf`。舊 kernel 沒有這個屬性 → FAIL(確定的負對照,而且不會被滾掉)。同時還能抓到 `r305aux cntl=` 造成的快取不一致(§5)。給人看的 log 改用 `printk_deferred`,只在 hook 外(set_termios、shutdown 回來之後)印。§4 的時序改成上面的實際序列,T1 不再斷言序列。序列只在開發 build 對照一次,用 log 存證。T5「rollback 後見證不存在」也改成看屬性。

### M3 T2 的「負載保證」沒有可以實作的機制

**證據**:
- 02/04 image 上沒有 `btmgmt`、`btmon`、`hcitool`、`hciconfig`、`hcidump`(兩台 `which` 都是 none),只有 `bluetoothctl` 和 `bluetoothd` 5.72,而 `bluetoothctl` 會卡住。harness 有 `scripts/dv-bt-tools.sh` 會把 `btmgmt`/`btmon` 帶上去,但 §8 沒有寫要用它,也沒寫用哪個命令。
- 「02 以最短間隔廣播」沒有寫:用什麼設間隔(btmgmt add-adv 或 ext-adv 參數)、間隔多少、connectable 還是 non-conn(legacy non-conn 最短 100 ms,connectable 20 ms)、和 02 上 provd 或 harness 自己的 adv instance 怎麼並存(`ble-lib-254.sh:157` 的 leftover adv instance 檢查會把它當殘留)、BLE lease 由誰拿。
- 「掃描看到 02 的廣播」沒有寫怎麼數。duplicate-data 掃描是誰開的(bluetoothd D-Bus `SetDiscoveryFilter` 還是 btmgmt)?用 btmon 依 02 的位址過濾計數?
- 舊 kernel 上 02 自己也會卡死(02 今天 `[22027.67] Frame reassembly failed`,`oe:2`)。負對照那一段如果因為 02 掛掉而「負載不足 → FAIL」,這個 FAIL 的理由是錯的,不能算負對照。

**修法**:§8 寫出具體的指令與工具來源(dv-bt-tools 的 btmgmt/btmon 加上 SHA256SUMS)、廣播參數、計數方式。速率用 04 的 `/proc/tty/driver/serial` rx 差值除以時間。另外寫明 02 adv 的建立和清除,並納入 BLE lease 與 leftover 檢查。負對照的 FAIL 理由必須是 `oe`/reassembly/tx timeout 增加,而且同一時段負載保證成立;因為負載不足造成的 FAIL 不算負對照。估算:20 ms 間隔、在 100% 掃描 duty 下,約 50 events/s × 約 48 B ≈ 2.4 KB/s,高過 500 B/s 門檻,所以可行。這個估算要用一次實測確認。

---

## MINOR

- **m1 `rs485_config` hook 寫錯(第 1 輪 A-m2/B-m3 沒有真的關)**:`uart_set_rs485_config` 是先呼叫 `port->rs485_config(port, &tty->termios, &rs485)`,成功後才 `port->rs485 = rs485`(`serial_core.c:1508-1510`)。hook 裡的 `update_flow` 看的是 `up->port.rs485.flags`,也就是**舊值**。所以第一次開 rs485 時 auto 不會被清掉。關閉的方向沒問題,因為之後 `:1514` 會以新值呼叫 `set_mctrl`。另外 `UPSTAT_AUTOCTS` 沒清,所以 rs485 下軟體 CTS 被關掉,而 em485 的 `stop_rx` 會讓 `skip_rx` 成立(`8250_port.c:1936-1939`)。修法:hook 用傳入的 `rs485->flags` 判斷,同時清 `UPSTAT_AUTOCTS`。§4 的「⚠️ 確認持鎖」可以刪掉:兩個呼叫者都持有 port lock(`serial_core.c:1458-1460`、`:1507-1515`)。
- **m2 §5 事實錯誤**:「suspend 路徑不更新 `port->mctrl`(`:2436`)」不對,`:2439` 有 `uport->mctrl = 0`。結論(用參數,不讀 `port->mctrl`)仍然正確。
- **m3 harness 先進 main 之後的每日 FAIL**:`bt-uart-305.sh` 的 T1 一進 tier A,wsl.15 fleet 在 patch 出貨前每天都會 FAIL。§8 沒寫怎麼處理。照前例(`validation-known-failures.txt` 的 `pre-#202 image: .*untestable`),要讓 suite 印一行固定的 `pre-#305 kernel` FAIL,掛在 known-failures、對應 305,出貨後移除。單關掉後 known-failures 會自動變成 NEW,所以要在關單前移除。
- **m4 T7 分辨力**:舊的資料只有 2/2 invalid,新的跑 3 次。要寫出舊 kernel 的失敗率估計(例如舊 kernel 再跑 N 次),否則「3/3 通過」的負對照強度不明。
- **m5 probe 明寫 CNTL**:快取假設硬體是 reset 值 0x03(`:116-117`),但 GPU 韌體或上一次的狀態(例如 `r305aux` 留下的值)不保證。probe 時寫一次 `CNTL = data->cntl`,§6「平台驅動 rebind ⚠️ 推論」那一列就不用再靠推論。
- **m6 T2 只有 04 當 DUT**(第 1 輪 A-M4 最後一點沒回應)。02 也是現場硬體,現在 `oe:2`。至少要角色對調跑一次。
- **m7 T6 的空結果**:要斷言 throttle **真的發生過**,例如用 r305aux 讀到 MCR RTS 清掉、`rts_status` 改變,或用 `/proc/tty/driver/serial` 確認。沒發生就 FAIL,不能報沒有 oops 就算過。T6 會把 BT 移到 PL011,而 cmdline 有 `console=ttyAMA0`:要引用 02 先前翻轉實驗的設定作為可行的證據,或寫明怎麼避開 console 輸出灌進 H4。
- **m8 §7 遠端 actor 補一句**:攻擊者若讓控制器卡死、而且它的 RTS 停在 de-asserted,AUTOCTS 會擋住主機 TX,再加上 M1 的 close 等待。症狀和今天的卡死相同,但恢復時間取決於 M1 的選擇。

---

## 第 1 輪 BLOCKER / MAJOR 結案核對

| 第 1 輪 | v2 | 我的判定 |
|---|---|---|
| A-B1 / B-B1 throttle NULL | 不設 UPSTAT_AUTORTS | ✅ 關。`serial_core.c:729-755`:沒有 AUTORTS 時走 `uart_clear_mctrl(TIOCM_RTS)` → `serial_core.c:181-186` → `set_mctrl` hook;`UPSTAT_SYNC_FIFO` 只有 aspeed_vuart 設(grep);`8250_dwlib.c:95-100` 同模式 |
| A-M1 / B-M1 build 路徑 | base tree 999 patch | ✅ 關。`include/kernel-build.mk:12-13`:`STAMP_PREPARED` 含 `PATCH_DIR` 的 md5,改 patch 會自動重新 prepare;已 commit 的 base tree 改動能通過 `build-board.sh:75-87`(只擋未 commit 的改動);前例 `999-batman-enable-memcg*.patch` 都在 |
| A-M1 / B-M2 出貨見證 | dev_info + T1 | ❌ 未關 → M2 |
| A-M2 CM4 | §1、§6、§11 | ✅ 關 |
| A-M3 init 握手推論 | 區辨實驗 | ✅ 關(`disc.log`:0x8b 3/3 成功、0x47 3/3 `0xfc18 tx timeout`) |
| A-M4 / B-M3 分辨力 | T1–T4 | 部分:T3 標為回歸 ✅、T4 只收數據 ✅;T1 → M2;T2 → M3 |
| A-M5 / B-M6 原始症狀、harness 先進 main | T7、§8 | 大致關;m3、m4 |
| A-M6 / B-m5 autocommit | §6、§7、§11 | ✅ 關(接受風險、寫明全套是閘門) |
| A-M7 擁有權 | §5 | ✅ 關(m2 是小事實錯誤) |
| B-M4 替代方案 | §9 | ✅ 關 |
| B-M5 close 30 s | §3、T3 | ❌ 未關 → M1(而且證據來自我第 1 輪的錯誤) |

---

## 我查證過、成立的部分(✅ 附證據)

- **hook 會被複製**:`8250_core.c:1103-1121`(set_termios / set_mctrl / startup / shutdown 是 `if (up->port.x)` 有條件複製);`:1087` 的 `rs485_config` 無條件複製(probe 本來就設 `serial8250_em485_config`,`8250_bcm2835aux.c:110`)。`port->status` 不會被複製,一開始就是 0。
- **set_mctrl hook 真的會被呼叫**:`serial8250_set_mctrl` 在 rs485 關閉時呼叫 `port->set_mctrl`(`8250_port.c:2059-2067`),`ops.set_mctrl = serial8250_set_mctrl`(`:3274`)。
- **所有呼叫 set_mctrl 的地方都持鎖**:`uart_update_mctrl`(`serial_core.c:181-186`)、`do_startup`(`8250_port.c:2387-2399`)、`do_shutdown`(`:2515-2524`)、`do_set_termios`(`:2817` lock 到 `:2920`)、`uart_set_rs485_config`(`serial_core.c:1507-1515`)、suspend/resume(`:2433-2436`、`:2526-2541`)、`uart_configure_port`(`:2655-2658`)。所以 `update_flow` 用 `lockdep_assert_held_once` 成立,不會自己拿鎖、不會死鎖。`set_termios` hook 本身是在沒有持鎖的情況下被呼叫(`serial_core.c:216`,只有 port mutex),所以 hook 自己拿鎖改 status 是對的。`shutdown` hook 由 `serial8250_shutdown` 在沒有持鎖時呼叫(`:2557-2562`),hook 自己拿鎖也對。
- **軟體 CTS 不會和 AUTOCTS 衝突**:`uart_softcts_mode` = `CTS_ENABLE && !AUTOCTS`(`serial_core.h:1014-1018`)。`uart_change_line_settings` 在 set_termios 之後重新計算 `hw_stopped`,如果原本被停住就 `__uart_start`(`serial_core.c:234-242`)。950-0440 的輪詢只在 `hw_stopped` 時啟動(`8250_port.c:1533-1534`、`:1875-1877`)。`skip_rx` 需要 `read_status_mask` 沒有 DR(`:1936-1939`),而 `do_set_termios` 一律設 DR(`:2845`),只有 `stop_rx`(close、suspend、em485)才會清。close 時 RDI 中斷也同時關掉,所以不會中斷風暴。
- **擋 open 時序的前提**:`ttyport_open` 設 CRTSCTS 與 CLOCAL(`serdev-ttyport.c:136-139`);`uart_port_startup` 的順序是 startup → line settings → `dtr_rts(true)`(`serial_core.c:283-308`)。
- **bluetoothd restart / hci down 不會關 port**:`hci_serdev.c:150-157`。
- **現況**:04 現在 `r305aux before: MCR=0x02 CNTL=0x03 STAT=0x0000030e (… tx_fill=0 …)`(dmesg `[46948.537920]`,不帶參數,已卸載)。02/04 `/proc/tty/driver/serial`:`oe:2`、`oe:111`,cmdline `console=ttyAMA0`,kernel 6.6.138,BlueZ 5.72。
- **build**:兩個 subtarget 共用 `target/linux/bcm27xx/patches-6.6/`(950-0225、950-0440 已在 build_dir 的檔案裡),新 patch 編號接在後面,不會衝突。

## 判定:**REJECT(範圍窄)**

patch 邏輯(§4 結構、鎖、閘門、B1 修法)我核准。要再審一輪的是三件:
1. M1:決定 `closing_wait` 的處理方式,並加上 T3b。
2. M2:見證改成 sysfs 讀回,並改正時序。
3. M3:寫出 T2 的具體工具和計數方式。

MINOR 中 m1(rs485 hook)要一起修,其餘可以在實作時處理。改完請送第 3 輪整份重審。
