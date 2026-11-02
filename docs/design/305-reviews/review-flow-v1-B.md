# #305 mini UART 硬體流量控制(kernel patch)設計 v1 — 對抗式審查 B(第 1 輪)

審查對象:`305-mini-uart-flow.md` v1(整份)。對照:`REVIEW.md`、使用者全域規則、kernel 6.6.138 build 樹原始碼、02/04 唯讀探測。

**結論:REJECT(範圍窄)— 1 BLOCKER / 6 MAJOR / 9 MINOR。**
根因(mini UART 沒開 AUTORTS/AUTOCTS)和交叉試驗的方向我同意,也查證過。但設計照字面實作,會在 8250 core 留下一個 NULL 指標解參考。出貨路徑和專案的 build 閘門衝突。開機 init 失敗「消失」這個說法沒有能分辨好壞的測試,也沒有列替代方案。

---

## 我先查證的事實(附證據)

| # | 事實 | 證據 |
|---|---|---|
| E1 | 04 現在 CNTL = 0x03、MCR = 0x02(已還原) | 04 `insmod r305aux.ko && rmmod`(無參數):`MCR=0x02 CNTL=0x03 STAT=0x0000030e (rts_status=0 cts_line=0 ...)` |
| E2 | mini UART 沒有 tty 節點(serdev 擁有) | 02/04:`ls: /dev/ttyS*: No such file or directory`;只有 `/dev/ttyAMA0`、`/dev/ttyAMA5`(root:dialout 0660) |
| E3 | BT 節點 `compatible = brcm,bcm43438-bt`(→ `drive_rts_on_open`),`max-speed` = 0x00038400 = 230400;沒有 `host-wakeup` / `device-wakeup`,也沒有 `interrupts`(只有 `shutdown-gpios`) | 02/04 `/proc/device-tree/soc/serial@7e215040/bluetooth/` 列表;`hci_bcm.c:1586-1587` |
| E4 | → runtime PM 不會啟用(`bcm_request_irq` 在 `irq <= 0` 時直接返回,`hci_bcm.c:346`),`bcm_suspend_device` / `bcm_resume_device`(`:762-815`)在這個 DT 上走不到 | 同上 |
| E5 | driver 是 built-in,兩個 subtarget 都是;兩棵樹的 `8250_bcm2835aux.c` 完全相同;bcm2710 沒編 `BT_HCIUART_BCM` | bcm2711 `.config:2627 CONFIG_SERIAL_8250_BCM2835AUX=y`、`:1521 CONFIG_BT_HCIUART_BCM=y`;bcm2710 `.config:2624 =y`、`:1527 # CONFIG_BT_HCIUART_BCM is not set`;`cmp` → same |
| E6 | 開機後第一個送到控制器的命令是 `0xfc18`(`hci_serdev.c:205-206` `proto->set_baudrate`,`hci_bcm.c:1318`),在 `bcm_setup`(btbcm_initialize / patchram / finalize)之前 | 原始碼 |
| E7 | `bcm_open`:`set_flow_control(true)`(`:491`)→ `bcm_gpio_set_power(true)`(`:504`)→ `set_flow_control(false)`(`:507`);`:489` 的註解說明 RTS 在上電時的電位會決定控制器是否進 autobaud("Assert BT_UART_CTS_N") | 原始碼 |
| E8 | `ttyport_open` 一律設 `CRTSCTS`(`serdev-ttyport.c` `ktermios.c_cflag \|= CRTSCTS`);`uart_port_startup` 在 open 時拉高 RTS(`serial_core.c:307-308`) | 原始碼 |
| E9 | 卸載順序:`hu->proto->close`(= `bcm_close`,斷電控制器)在 `serdev_device_close` **之前** | `hci_serdev.c:406-410` |
| E10 | autocommit 的 BLE 健康只發警告、不擋 commit | `batman-autocommit:496-499`「not blocking (P-U5)」 |
| E11 | board patch 只能改 `feeds/`;build 時 base tree(`target/` 等)被改過會拒絕 build | `openmanet_setup.sh:147-148`;`build-board.sh:75-84`;`check-board-patches.sh` 只檢查 feeds/ |
| E12 | `validation-known-failures.txt:14` 有一條 `ble-pair-sc-only-254 ... 305` | 檔案 |

---

## BLOCKER

### B1 — 只設 `UPSTAT_AUTORTS`、沒有提供 `port->throttle`:n_tty throttle 會解參考 NULL 指標
**情境**:設計 §4 刻意設 `UPSTAT_AUTORTS`,理由是讓 `uart_throttle` 改呼叫 `ops->throttle`。在 8250 上,`ops->throttle` = `serial8250_throttle`,它無條件呼叫 `port->throttle(port)`(`8250_port.c:1664-1667`)。`port->throttle` 只會從註冊者那裡複製(`8250_core.c:1075`),bcm2835aux 沒有設,也沒有預設值(對整個 8250 目錄 grep `throttle`,只有 omap、bcm7271、aspeed 有設)。
所以只要 mini UART 是一般 tty,有人設了 `crtscts`,而 n_tty 的緩衝高於水位(`serial_core.c:741-746`,`port->status & UPSTAT_AUTORTS` → `port->ops->throttle`),就會在 kernel 解參考 NULL,導致 oops 或 panic(cmdline 有 `panic=10`)。會走到這條路的例子:Pi 3 上 mini UART 當主控台或 GPS(`ekh-bcm2710` 也會編進這個 patch,E5)、CM4 / HAT v2 把 GNSS 或除錯台放在 mini UART,或任何以 root 執行的 `stty -F /dev/ttyS0 crtscts`。
**另外**:就算補了 throttle,`serial8250_handle_irq` 的 `skip_rx`(`8250_port.c:1936-1939`)也要靠 throttle 清掉 `read_status_mask` 的 `UART_LSR_DR`,並且關掉 RX 中斷。否則 IRQ 會一直觸發但沒有人讀 FIFO,變成中斷風暴(omap 的 `omap_8250_throttle` 會關 IER,`8250_omap.c:801-830`)。
**§4 的描述對 serdev 也不成立**:serdev 沒有 ldisc,`ttyport_receive_buf` 不會 throttle。flip buffer 滿時,8250 IRQ 照樣把 FIFO 讀空,位元組在軟體層被丟掉(`buf_overrun`,不是 `oe`)。所以硬體 RTS 只解決中斷延遲,解決不了主機端的軟體背壓。這點要明寫。
**修法(擇一)**:
- (建議)仿 `8250_dwlib.c:95-100`,**只設 `UPSTAT_AUTOCTS`,不設 `UPSTAT_AUTORTS`**。這樣 `uart_throttle` 會走軟體路徑 `uart_clear_mctrl(TIOCM_RTS)`(`serial_core.c:748-749`),觸發本設計的 `set_mctrl` hook:RTS 拉低 → 關掉 AUTORTS → 手動 RTS 去斷言。unthrottle 時再自動恢復。這和設計自己的閘門剛好吻合,不需要新的 throttle 程式碼。
- 或者完整實作 `up.port.throttle` / `unthrottle`(關 RX IER、清 DR,照 omap 的做法),並說明 mini UART IER 的位元配置(手冊勘誤)。

**負對照**:找一台 mini UART 是一般 tty 的機台(Pi 4 拿掉 `miniuart-bt` 的測試卡,或 Pi 3),`stty crtscts`,對端灌資料、讀取端不讀。照 §4 原文實作會 oops,修正後不會。

---

## MAJOR

### M1 — 出貨路徑和 build 閘門衝突:「由 firmware board patch 帶入」行不通
**情境**:§4 寫的是把 patch 檔放進 `target/linux/bcm27xx/patches-6.6/`,再「由 firmware board patch 帶入」。可是 board patch 只能改 `feeds/`(`openmanet_setup.sh:147-148`:改 `target/` 的 patch 在第二次 `-i` 時會變成 "previously applied" 而中斷 setup),而 `build-board.sh:75-84` 只要看到 base tree 被改過就拒絕 build(#275)。`check-board-patches.sh` 也只檢查 feeds/。
**修法**:把 patch 直接 commit 到 firmware fork(`build-3aplus`)的 `target/linux/bcm27xx/patches-6.6/`(編號要接在 950-* 之後,並寫明來源)。後果要寫出來:兩個 subtarget(bcm2710 / bcm2711)的 `kernel8.img` 都會變,兩塊板一起換版本號(`VERSIONS.md`、firmware pin bump),bcm2710 至少要 build 並開機冒煙測試一次,或明列 ⚠️ 未測(Pi 3 是殘項,依 2026-10-23 決定)。另外要確認 OpenWrt 會因為 patch 目錄變動而重新 prepare kernel,也就是從 build_dir 的 `8250_bcm2835aux.c` grep 到新程式碼。

### M2 — 沒有「出貨的 kernel 真的帶了這個 patch」的檢查;CNTL 在節點上讀不到
**情境**:節點沒有 `/dev/mem` / devmem,`r305aux` 是調查用模組,不出貨,而且要和每個 kernel build 的 vermagic 對上。§8 全部是行為測試,其中 T2 還依賴周圍的廣播量。專案有前例:1.5.5-wsl.2 出貨時少了 0011。
**修法**:patch 裡加一個確定的、低頻的標記。例如在 `update_flow` 狀態改變時印 `dev_info_ratelimited`/`dev_dbg`,或在 probe 時印一行 `"auto RTS/CTS supported (#305)"`;開機後再印一行目前生效的 CNTL。harness 斷言「hci0 init 完成後的 CNTL == 0xcf」或「標記存在」,舊 image 必 FAIL(負對照)。也可以把讀暫存器的唯讀 debugfs 檔一起做進 patch。

### M3 — 「開機 init 失敗也會消失」沒有證據;T1 的負對照在統計上分辨不出好壞;patch 的 init 路徑從來沒在 auto 開著時跑過
**情境**:
1. T1 = 20 次重開。舊 kernel 的失敗率約 1/30,舊 kernel 通過 T1 的機率 = (29/30)^20 ≈ **0.51**。依使用者的規則,這不算負對照。
2. 調查期間 init 時一律是 0x03,init 完才切 0xcc(§3、§10)。唯一一筆「init 時 auto 開著」的資料是 0xcf rebind → **失敗**。設計把失敗歸因於上電握手期間 RTS 被強制斷言;依 E7(`hci_bcm.c:489` 的 autobaud 註解),這個解釋很合理,但仍然是推論。patch 實際走的順序是:`bcm_open:507` 之後 auto 就開了,從第一個 `0xfc18`(E6)、patchram、兩次 `host_set_baudrate`(`hci_bcm.c:609-625`)到 finalize 都在 auto 下進行。調查完全沒有測過這段。
**修法**:
- §2 / §3 的「原因」改標 ⚠️,證據寫成 `hci_bcm.c:488-491`,不要寫成已證實。
- 開發 build 時把每次 CNTL 寫入(含 CRTSCTS、mctrl)記到 dmesg,證明時序是:上電窗內 0x03 → `:507` 之後 0xcf → baud 切換時維持。
- T1 改用靈敏的指標:每次 init 期間 ttyS0 的 `oe` 增量(用 `/proc/tty/driver/serial` 的前後值),在固定負載下做 rebind × N(SD 讀 + 控制器在上一段持續送事件)。先用舊 kernel 量出 init 期間 `oe>0` 的比率,再決定 N,讓舊 kernel 通過的機率 < 5%。如果做不到,就把「init 失敗消失」從聲明裡拿掉,只聲明運行中溢位歸零,並寫明 ⚠️。

### M4 — 沒有列替代方案和下游取代;「只做止血」規則沒有交代
**情境**:使用者規則要求「之後的工作會取代它就只做最少的」。§6 只寫了一句「HAT v2 提案藍牙回 PL011(O13)」,沒有寫:
- (a) **這個 patch 在 O13 定案後就是開發 / P1 專用**,量產不會用到;如果 O13 沒被採納,它就變成量產必要,要在 CM4 上驗證。
- (b) 只改設定的替代方案:**BT 回 PL011、GPS 改走 mini UART(GPIO14/15 ALT5,也就是 RPi 的預設佈局)**。GPS 在 9600 baud 下,8 字元 FIFO 可以容忍約 8.3 ms 的中斷延遲(現在是 0.35 ms),而 gpsd 本來就容忍掉字。02 的翻轉測試已經量到 BT 在 PL011 上 0 次溢位(#305 留言)。
- 反方向、支持 kernel patch 的最強理由也該寫:`distroconfig.txt` 不隨 OTA 更新(`219-field-provisioning.md:439`),而 `bootConfigOK` 要求 `miniuart-bt`(`batman-provhelper/main.go:463`)。所以替代方案要重燒卡,並且要同時改 #254 閘門;kernel patch 則可以經 OTA 送到已出廠的機台。
- 還有長期成本:每次 kernel 升版都要 rebase 這個 downstream patch。要決定送不送 upstream;要送的話,至少得用 DT(`uart-has-rtscts` / `UPF_HARD_FLOW`)當閘門。

**修法**:加一節「替代方案」(kernel patch / BT↔GPS 對調 / 降 baud / 不動)。每個方案寫現場效果、能不能經 OTA 送達、和 HAT v2 的關係、維護成本。最後把「dev/P1 過渡、O13 定案後角色」寫成一句明確的範圍聲明,交給使用者拍板。

### M5 — AUTOCTS 是新的硬依賴:主機送資料被控制器的 RTS 擋住;rebind / close 路徑可能卡 30 s,沒有分析
**情境**:今天的 CTS 只是軟體 `hw_stopped`,停的是「餵 FIFO」,已經在 FIFO 裡的位元組照樣送出。開 AUTOCTS 之後,只要控制器的 RTS 不斷言,硬體 TX FIFO 就完全不動。依 E9,`bcm_close` 先斷電,之後才 `serdev_device_close` → `uart_close` → `tty_port_close_start` → `tty_wait_until_sent(closing_wait)`(預設 30 s)→ `uart_wait_until_sent` 等 `tx_empty`。如果控制器卡死或斷電時 RTS 腳是浮接或去斷言,而 TX FIFO 裡還有殘留(卡死時正是 CTS 被擋的時候),unbind 就可能卡到 30 s。#305 的恢復手段(人工 rebind,或之後的 btwatch)全靠這條路徑。斷電時 CTS 腳的電位(pull 設定)沒有證據。
**修法**:生命週期矩陣加兩列:「控制器卡死 / 斷電時 RTS 去斷言」和「rebind 所需時間」。實作後在 04 做兩件事:用 `r305aux`(無參數)讀斷電狀態下的 `cts_line`;在 0xfc18 故障注入後 rebind 並計時。T3 加上時間上限(例如每次 < 5 s),舊 kernel 的時間當基準。

### M6 — 測試沒有對到常規全套,沒有遵守 harness 先進 main;T2 的負載依賴 RF 環境;T4 / T5 不是測試
**情境**:
- 依「🔥 測項只能有一套」:T1–T3 要成為 `scripts/dv/*.sh` 的 suite,先用 harness PR 進 main,附「舊 image FAIL + rc PASS」。§8 沒有寫要放在哪裡、哪個 PR、`btprobe` 和負載工具是否進 `dv-bt-tools` 的 SHA256SUMS。
- T2 的「UART 收 ≥ 1 MB」要靠周圍裝置的廣播(`duplicate-data` 約 1060 B/s 是 04 現場的量)。換一個環境就可能變成 FAIL,而且與產品無關。應改用確定的負載,例如不靠 RF 的大回應 HCI 命令連發(像 `Read_Local_Name 0x0c14`,每次約 255 B),或由另一台節點用最小間隔廣播。
- T4「⚠️ 待定」:fleet 上 mini UART 沒有其他使用者(E2、Pi 3 是 `disable-bt`)。要嘛改成 N/A 並附證據,要嘛用 B1 的負對照機台去測。
- T5「A/B tier A 既有流程」沒有斷言任何與本修正有關的事。應改成:新 slot 有 M2 的標記 / CNTL=0xcf;rollback 到舊 slot 後標記消失、CNTL=0x03。
- `validation-known-failures.txt:14` 掛在 #305 名下。修好之後這條要檢討(關單後會自動變成 NEW;要確認那時 `ble-pair-sc-only` 的 invalid 確實消失,再從 harness 移除)。

---

## MINOR

1. **鎖**:§4 在 `serial8250_do_set_termios` 之前改 `port->status`,沒有拿 port lock,會和 IRQ 裡讀 `port->status`(`8250_port.c:1937`)競爭。應在 lock 內改。
2. **用參數,不用 `port->mctrl`**:`set_mctrl` hook 應該用傳進來的 `mctrl` 判斷 RTS(omap `__omap8250_set_mctrl` 用的是 `mctrl & TIOCM_RTS`)。
3. **rs485 互斥不完整**:rs485 開啟時 `serial8250_set_mctrl` 會直接返回(`8250_port.c:2061-2062`)。如果先開 CRTSCTS 再 `TIOCSRS485`,auto 會一直開著,違反 driver 註解 `:10-12`。應包一層 `rs485_config`,在裡面清掉 auto。
4. **極性**:手冊寫「Auto flow polarity … interface with any existing hardware」,預設「high*」不是標準的低態有效,所以固定 `RTSINV|CTSINV` 對標準 TTL 介面是對的。這要寫進註解。bcm2710 的極性沒有實測,標 ⚠️。要不要用 DT 控制,和 M4 的 upstream 決定一起處理。
5. **§7 失敗模式寫得太輕**:極性錯或 init 退化 = 所有 `miniuart-bt` 機台都沒有 BLE,app 找不到機台。autocommit 不擋(E10),health 的 `Powered` 也看不出卡死(#305 留言)。所以壞 kernel 會被 commit,只能經 mesh SSH 手動 rollback 或再 OTA。要明寫,並說明出貨前全套是唯一的閘門。
6. **生命週期缺的列**(請補上,並寫行為與理由):runtime PM / system suspend(N/A,E3/E4);`bluetoothd` restart、`hci down/up`(serdev 一直開著,CNTL 不變);`bcm2835-aux-uart` 平台 driver rebind(probe 不寫 CNTL,快取假設硬體是 0x03;remove 後 AUTOCTS 可能殘留在硬體上);kernel crash / watchdog reboot(SoC 重置,CNTL 回 0x03,⚠️ 未實測);首次開機(和開機相同)。
7. **open 時序**:依 E8,`ttyport_open` 時就會進入 CRTSCTS + RTS 高 → 0xcf,早於 `bcm_open:491` 的握手。這時的線電位和今天相同(手動 RTS=1 也是斷言),控制器也還沒上電,所以無害。但設計說「init 握手期間手動、握手後自動」,沒有提到這一段,要補一句。
8. **§3「以 0x03 init、完成後才設 0xcc → 探測 3/3 成功」**不能當成 patch 閘門的證明:調查時 driver 從來不寫 CNTL,軟體 CTS(`hw_stopped` + NOMSI 輪詢,950-0440)和 0xcf 是同時存在的。patch 會換掉軟體 CTS,這是另一條 TX 路徑。標 ⚠️,交給 T2/T3。
9. **維護**:patch 註明對應的 kernel 版本(6.6.138);kernel 升版時的 rebase 責任要寫進 `boards-and-builds.md`。

---

## 生命週期矩陣(我要求補上或改寫的列)

| 路徑 | 今天 | 之後 | 測試 |
|---|---|---|---|
| serdev open(`ttyport_open`)到 `bcm_open` 握手前 | 手動 RTS 斷言 | 0xcf(線電位相同) | M3 的開發 build CNTL 記錄 |
| 上電窗(`:491`–`:507`) | 手動 RTS 去斷言 | 0x03 + 手動去斷言 | 同上 + T3 |
| 第一個命令 0xfc18、patchram、baud 切換 | 無 flow | auto 開 | T3(加時間上限)、M3 |
| n_tty 使用者 + crtscts + throttle | 軟體拉 RTS | **照原設計:NULL 解參考** → 修正後走軟體拉 RTS 並關掉 AUTORTS | B1 負對照 |
| 控制器卡死 / 斷電且 RTS 去斷言 | TX FIFO 照送 | TX 被擋,close 可能等 30 s | M5 |
| rs485 在 crtscts 之後才開 | — | auto 殘留 | MINOR 3 |
| OTA → 新 slot / rollback / 降版 | — | 新 slot 有標記;舊 slot 沒有 | T5(改寫,M2) |
| bcm2710 | 同 driver,BT 關閉 | 編進去,沒有 CRTSCTS 使用者時無影響 | build + 開機冒煙,或 ⚠️ |
| CM4 量產 | — | 取決於 O13 | M4 範圍聲明 |
| runtime PM / suspend | N/A | N/A | E3/E4 |

## 安全(逐 actor)

- **遠端(BLE 範圍內)**:今天的溢位觸發條件本身就是 RX 流量。附近有人大量廣播,就能讓 H4 失步、BT 卡死,這是遠端 DoS。patch 讓控制器被 RTS 擋住、自己丟掉廣播報告,所以**改善**了這一點。這應寫進 §7,T2 就是它的負對照。
- **本機非 root**:沒有 `/dev/ttyS*`(E2),碰不到 termios;HCI raw 需要 CAP_NET_RAW。✅ 同意 §7。不過非 root 的 D-Bus 用戶端可以要求開掃描、製造負載,這點已被 patch 緩解。
- **root / 我們自己的錯誤**:B1(root `stty crtscts` 就能讓 kernel oops)、MINOR 5(壞 kernel 會被 commit)。
- **供應鏈**:downstream kernel patch,由我們自己 review;要記錄來源和 kernel 版本(MINOR 9)。
- **實體**:無新增面。
- 不涉及任何 secrets。

## 我同意、而且已驗證的部分
- R1 / R2 / R5 的原始碼行號正確(`8250_bcm2835aux.c:10-12, 27-28, 102, 107, 117`)。
- 04 的暫存器現況(E1)、DT(E3)、driver 是 built-in 且兩棵樹相同(E5)。
- 以 CRTSCTS && RTS 為閘門的方向正確,而且涵蓋 hci_bcm 在這個 DT 上所有的 RTS 操作:open 握手、`set_flow_control`;suspend / resume 在這個 DT 上走不到(E4)。
- 交叉試驗(3×30 分開 0 / 關 88 次溢位)足以支持「運行中溢位的根因是沒有硬體 flow control」。

## 判定:**REJECT(範圍窄)**
1 BLOCKER / 6 MAJOR / 9 MINOR。B1 改一行(不設 `UPSTAT_AUTORTS`)就能解。M1 是改出貨路徑的文字和流程。M2、M3、M6 是測試設計。M4 需要使用者對範圍拍板。M5 需要實作後在 04 量測。改完請送整份重審。
