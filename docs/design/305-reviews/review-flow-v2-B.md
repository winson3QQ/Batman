# #305 mini UART 硬體流量控制(kernel patch)設計 v2 — 對抗式審查 B(第 2 輪)

審查對象:`305-mini-uart-flow.md` v2(整份重審,不只看差異)。對照:使用者全域規則、`REVIEW.md`、build 樹 kernel 6.6.138 原始碼、BlueZ 5.72 原始碼、Batman main a62bf78、02/04 唯讀探測(04 只做了一次不帶參數的 `insmod r305aux && rmmod`)。

## 結論:**REJECT** — 1 BLOCKER / 5 MAJOR / 8 MINOR

第 1 輪的 B1(throttle 解參考 NULL)確實關了。build 路徑、替代方案、擁有權表、極性、生命週期缺列也都補得實在。
但 v2 新加的東西裡有兩處會直接出事:
- **出貨見證** `dev_info_ratelimited` 是在 port lock 內呼叫的。只要 mini UART 是 console,就會自鎖。而 T6 的測試設定剛好會把 console 移到 ttyS0(B1)。
- **§3 / §6 的「close 不會卡 30 s」**,引用的原始碼只在 CTS 沒開時才成立。serdev 永遠開著 CRTSCTS,所以這個上限不存在。實測的 120 ms 是因為 FIFO 剛好是空的(M1)。

另外,T1 的見證在跑了幾小時的節點上讀不到,預期序列也寫錯了(M2)。T2 的負載用 image 上的工具做不出來(M3)。init 路徑沒有通過與否的判準(M4)。T6 的副作用沒有列全(M5)。

---

## 我先查證的事實

| # | 事實 | 證據 |
|---|---|---|
| E1 | 04 現在 CNTL = 0x03 | `r305aux before: MCR=0x02 CNTL=0x03 STAT=0x0000030e (rts_status=0 cts_line=0 rx_fill=0 tx_fill=0 rx_overrun=0)`(dmesg [47223.295530],不帶參數) |
| E2 | 04 的 dmesg 已經 wrap:uptime 46801 s,但第一行是 `[ 9582.521181] flightrec: …`(共 1458 行)。logread 是 128 KB 的 ring,第一行已經是使用者層訊息 | 04 `cat /proc/uptime; dmesg \| head`;`uci get system.@system[0].log_size` = 128 |
| E3 | 02 `/boot/cmdline.txt` 寫的是 `console=serial0`,執行中的 cmdline 被 firmware 換成 `console=ttyAMA0`。aliases:`serial0=/soc/serial@7e201000`(PL011)、`serial1=/soc/serial@7e215040`(mini UART)。`/proc/consoles` = tty1、ttyAMA0、ramoops | 02 唯讀讀取 |
| E4 | image 上的 BT 工具只有 `bluetoothctl`、`bluetoothd`(bluez 5.72-r3),沒有 btmgmt / btmon / hcitool。bluetoothd 以 `-n --noplugin=…` 啟動,**沒有 `-E`**。`CONFIG_BT_DEBUGFS` 沒開,`/sys/kernel/debug/bluetooth/hci0/` 是空的 | 02 `ls /usr/bin /usr/sbin`、`ps`、`/proc/config.gz` |
| E5 | 區辨實驗的原始紀錄(`r305/disc.log`):每次 unbind 時 `tx_fill=0`;0x47 的第 2 次只有 `BCM: Reset failed (-110)`,**沒有** 0xfc18 timeout | `disc.log:11,14,17` |
| E6 | `BCM4345C0.hcd` 63806 bytes 存在;BT 的 `max-speed` = 230400 | 02 `/lib/firmware/brcm/`、DT |
| E7 | 02 distroconfig 寫的是 `uart_enable=1`(不是有效的 key,正確的是 `enable_uart`);`[pi4]` = `miniuart-bt` + `core_freq_min=500` | `r305/02-distro.orig` |

---

## BLOCKER

### B1 — 見證 `dev_info_ratelimited` 在 port lock 內:mini UART 當 console 時會自鎖,而 T6 的設定正好會讓它變成 console

**情境**:
- `update_flow` 規定「呼叫者必須持有 port->lock」,而且在裡面 `dev_info_ratelimited`(§4)。呼叫者包括:
  - `set_mctrl` hook(serial core 持鎖呼叫,`serial8250_do_set_termios` 也在鎖內呼叫,`8250_port.c:2920`);
  - throttle 路徑 `uart_clear_mctrl`;
  - `rs485_config`(`serial_core.c:1458`、`:1507` 持鎖)。
- 6.6 的 printk 是同步的 legacy console:這棵樹沒有 nbcon,`kernel/printk/` 只有 printk.c / ringbuffer / safe。拿到 console lock 的 CPU 會直接呼叫 `serial8250_console_write`,而它會 `spin_lock_irqsave(&port->lock)`(`8250_port.c:3445-3448`)。
- 所以只要 ttyS0 是 console,任何一次 CNTL 改變都會在同一顆 CPU 上對同一把 spinlock 再拿一次 → 硬死鎖。`CONFIG_PROVE_LOCKING` 沒開,不會有任何警告。

**T6 就是這個設定**:
- 02 的 `cmdline.txt` 寫 `console=serial0`(E3)。
- 把 `miniuart-bt` 拿掉、再加上 `enable_uart=1` 之後,primary UART(serial0)會變成 mini UART,firmware 會把它換成 `console=ttyS0`。⚠️ 這是 Raspberry Pi 文件的語意,我沒有在 02 上實測。
- T6 接著對 ttyS0 `stty crtscts`,再讓它 throttle。每一步都會呼叫 `update_flow` → printk → 死鎖。02 是遠端的部署角色節點,要人到現場斷電才救得回來。

**同一個情境下的第二個問題**:
- console 在 ttyS0、又開了 AUTOCTS 時,只要 CTS 沒有 asserted(T6 的 GPIO16 沒有 mux 成 ALT5,mini UART 的 CTS 輸入是什麼電位不知道,⚠️),`wait_for_lsr` 每個字元會 busy-wait 10 ms,而且是關中斷、持鎖(`8250_port.c:2087-2104`)。
- 一行 100 字的 printk 就是 1 秒。

**修法**:
- `update_flow` 內**不准 printk**。見證改成資料:在鎖內把狀態記到 `data` 裡(目前的 cache、最後 N 次轉換、crtscts、mctrl),由唯讀 sysfs 屬性輸出(和 M2 一起處理)。
- 一定要留 log 的話,只能在鎖外,例如 `set_termios` / `shutdown` hook 放開鎖之後。
- §6「n_tty + crtscts(Pi 3、CM4)」那一列要加上「mini UART 是 console」這個情況。
- T6 的設定要避開 console 落在 ttyS0(見 M5)。

**負對照**:只能用程式審查,不要真的去觸發死鎖。實作後 grep `update_flow` 的呼叫鏈,確認持鎖路徑上沒有 printk。

---

## MAJOR

### M1 — 「close 上限 2 × FIFO timeout、不會卡 30 s」不成立:serdev 永遠開著 CTS,上限是 closing_wait = 30 s

**證據**:
- `uart_wait_until_sent` 的 clamp 包在 `if (!uart_cts_enabled(port))` 裡(`serial_core.c:1846-1858`)。
- `uart_cts_enabled` = `UPSTAT_CTS_ENABLE`(`serial_core.h:1009-1011`),而這個 bit 只要 CRTSCTS 開著就會設(`serial_core.c:223-224`)。
- `ttyport_open` 一律設 CRTSCTS(`serdev-ttyport.c:136`)。unbind 時 hci_bcm 不會先關掉它:`bcm_close` 只斷電(`hci_bcm.c:554`)。
- 所以 close 會走 `tty_port_close_start` → `tty_wait_until_sent(tty, closing_wait)`(`tty_port.c:654-655`),預設 `closing_wait` = 30 s(`tty_port.c:100`),而且不受 clamp 限制。
- `hci_uart_flush` 只清軟體 circ buffer(`hci_serdev.c:94-105`),硬體 TX FIFO 清不到。
- 今天(沒有 AUTOCTS)FIFO 不管 CTS 都會送光。patch 開了 AUTOCTS 之後,只要控制器的 RTS 是 de-asserted,FIFO 就不動,`tx_empty` 一直是 false。

**為什麼實測是 120 ms**:`disc.log` 每次 unbind 都是 `tx_fill=0`(E5)。FIFO 本來就是空的,所以測到的是「沒有殘留」的情況,不是上限。

**現場情境**:控制器卡死,同時把 RTS 拉成 de-asserted。主機還在送 HCI 命令,FIFO 會被塞到 8 bytes 然後停住。接著人工或恢復機制 rebind,每次要等約 30 s。T3(健康狀態下 rebind)碰不到這條路徑。
這個錯誤是第 1 輪我提出、審查 A 回答「clamp」,而 v2 直接採用了那個回答。那個回答本身是錯的,要在設計裡更正。

**修法**:
1. 更正 §3、§5、§6 的說法。
2. 加一個誘發測項:在 rc 上用 `r305aux cntl=0x4f`(AUTOCTS + 錯誤極性,已知 3/3 探測失敗)讓 TX 卡住,送一次探測讓 FIFO 有殘留,再 unbind 計時。預期是 patch 前的對照很快、patch 後約 30 s,這就是負對照。
3. 選一個修法再用同一個測項驗證。例如:
   - (a)接受 30 s,寫進恢復機制的時間預算,並把 T3 的上限改成有根據的值;
   - (b)另外 patch `hci_bcm`,在 `bcm_close` 斷電前先 `serdev_device_set_flow_control(false)`,讓 FIFO 送進已斷電的控制器;
   - (c)把這個 port 的 `closing_wait` 設成 NONE,或縮短。這會影響 n_tty 使用者,要寫明取捨。

### M2 — T1 / T5 的見證在實際節點上讀不到、預期序列寫錯,而且有 ratelimit

1. **dmesg 會 wrap**:04 跑 13 小時,開機那段已經不在了。logread 是 128 KB 的 ring,也一樣(E2)。T1 放在 tier A,每次 daily-validation 都跑,所以在 uptime 長的節點上會**假 FAIL**。實作的人遇到假 FAIL,很可能改成「找不到就算了」,那 T1 就只剩下存在檢查。T5 的「rollback 後見證不存在」用 dmesg 判斷沒有意義:舊 kernel 沒有見證,和 log 被擠掉看起來完全一樣。
2. **預期序列錯了**:依原始碼,bind 實際會是 **0xcf → 0x03 → 0x8b → 0xcf**,不是 §4 / §8 寫的 0xcf → 0x03 → 0xcf。原因:
   - `:507` 的 `set_flow_control(false)` 先 `set_flow_control(true)`(CRTSCTS 開),再 `set_rts(true)`(`hci_ldisc.c:320-321`);
   - CRTSCTS 開的那一刻,`serial8250_do_set_termios:2920` 用的是 `port->mctrl`,這時 RTS 還是低的 → 0x8b;
   - unbind 會再多兩筆:HUPCL 讓 RTS 掉下去 → 0x8b,shutdown hook → 0x03(serdev 沒有清 HUPCL,`serdev-ttyport.c:125-140`)。
   照現在的文字實作,正確的 patch 會讓 T1 FAIL。
3. **ratelimit**:預設每 5 s 最多 10 筆,每個 call site 共用。一次 rebind 約 6 筆,T3 連續 rebind 時,見證可能被吞掉,「最後一行」就會是舊值。

**修法**(和 B1 一起):
- 唯讀 sysfs 屬性(0444,沒有寫入路徑),例如 `…/fe215040.serial/auto_flow`。內容包括:`cntl_cache`、在鎖內讀到的即時 `CNTL`、`crtscts`、這次 open 以來的轉換紀錄(最近 8 筆)。
- T1 斷言:即時值 == cache == 0xcf,轉換紀錄 == 原始碼推出的序列(要寫在設計裡)。
- T5 斷言:新 slot 有這個屬性,rollback 後屬性不存在。這個判斷才有分辨力。
- 舊 kernel 沒有這個屬性 → 必 FAIL,這就是負對照。
- 它也讓 T6 不必再依賴 `r305aux`。

### M3 — T2 的「02 以最短間隔廣播」用 image 上的工具做不到,負載最後還是靠環境

**證據**:
- bluetoothd 沒有 `-E`(E4)。BlueZ 5.72 的 `MinInterval` / `MaxInterval` 是 experimental 屬性,沒開 `-E` 時會被直接忽略(`bluez-5.72/src/advertising.c:1127-1129`;文件 `org.bluez.LEAdvertisement.rst:173-187` 標 `[Experimental]`)。
- kernel 預設廣播間隔是 0x0800 = 1.28 s(`hci_core.c:2470-2471`)。
- 沒有 BT debugfs 可以改間隔,也沒有 btmgmt(E4)。

照預設值,02 一個廣播源在 04 上大約只有每秒幾十 bytes。T2 要求的 ≥ 500 B/s 只能靠周圍的裝置,這正是第 1 輪 M6 指出的問題。另外,image 上沒有 btmon,「看到 02 的廣播」只能用 `bluetoothctl devices` 判斷有沒有出現過,不能用來算量。

**修法**:
- 在 harness 的 bt-tools(SHA256SUMS)加一個工具,用 mgmt socket 的 `MGMT_OP_ADD_EXT_ADV_PARAMS`(`mgmt.c:8866`,不需要 experimental)把 02 設成 20 ms 間隔,測完 `REMOVE_ADVERTISING`。
- 寫明 02 的廣播 instance 歸誰管:和 bluetoothd、日後 provd 的廣播不能衝突,要取 BLE lease,並寫還原步驟。
- 04 的負載用 `/proc/tty/driver/serial` 的 rx 差值計算(✅ 可行),而且要分得出 02 的貢獻:先關掉 02 的廣播量一段基準,再打開量。
- 第 1 輪 A-M4 要求 T2 也在 02 上當 DUT 跑,v2 沒有處理,也要補上。

### M4 — init 路徑:閘門夠不夠還沒證明,§3 的結論寫過頭,T3 / T4 沒有判準

1. **區辨實驗只證明一件事**:在整段 init(open → 上電窗 → 0xfc18 → 63806 B patchram → Launch RAM 重置 → 兩次 baud 切換 → finalize)都強制 AUTORTS,init 會失敗。它沒有證明「只有上電窗內的 AUTORTS 有害」。
   - E5 顯示,0x47 第 2 次的失敗出現在 0xfc18 **之後**(只有 `Reset failed`),也就是 patch 會開著 AUTORTS 的那一段。
   - 引用的 `hci_bcm.c:489` 註解屬於 `use_autobaud_mode` 分支,不是這顆晶片走的 `drive_rts_on_open` 分支。
   - patch 實際的組合是「`:507` 之後的 setup 期間開著 AUTORTS」,從來沒跑過。
   - 所以 §3 的「→ 失敗原因是 AUTORTS 讓上電時的手動 RTS 拉低失效」要改標 ⚠️ 推論。
2. **0x8b 對 CTS 的部分是夠的**:硬體 AUTOCTS 從頭開到尾,patchram 也是在硬體 CTS 擋著的情況下送完,3/3 成功。那次實驗同時還有軟體 CTS,但真 patch 拿掉軟體 CTS 之後,線上的閘門只會更少,不會更多。
   - 差別在於:被擋住的位元組會留在硬體 FIFO,而不是 circ buffer,flush 清不掉。這個差別在 init 中沒有影響,因為每個命令都等到回應才換 baud;但在 close 會造成 M1。
3. **T3 其實才是閘門的判定**:0x47 是 3/3 失敗,代表 T3 對「閘門錯」這一類錯誤很敏感,這個不需要另做負對照。但 §8 把 T3 標成「只當回歸」,T4 也「只收數據」。結果是:就算 rc 在 30 次 init 裡失敗 3 次,設計裡也沒有任何一條會判 FAIL。
   **修法**:
   - T3(10 次)和 T4(20 次)合併判定。出現任何 `0xfc18 tx timeout` 或 `Reset failed` → FAIL,回到設計。沒有這兩個簽名的失敗,超過基準(1/30)就 FAIL,門檻要事先寫定。
   - 事先寫好退路:如果確認是 setup 期間的 AUTORTS 造成的,改成「setup 完成後才開 AUTORTS」,而不是到時臨場調整閘門。

### M5 — T6 的副作用與還原沒有列全,斷言也可能空過

除了 B1 之外,T6 還會碰到:
- **(1)** 02 的 distroconfig 寫的是 `uart_enable=1`(E7,不是有效的 key)。T6 要另外**新增** `enable_uart=1`,這會改到兩個項目,不是一個。只有 p1 會改,p3 不動。
- **(2)** console 會跟著 serial0 移到 ttyS0(E3),ttyAMA0 變成 BT 用的序列埠。gpsd 讀不到 GPS。
- **(3)** `bootConfigOK` 會變成 false(`batman-provhelper/main.go:465-489` 會檢查 p1 和 p3),那次開機的 `ble-ok` 不會更新(`health.go:151`)。
- **(4)** GPIO16 沒有 mux 成 CTS,CTS 是什麼電位不知道。
- **(5)** **斷言可能空過**:如果 throttle 根本沒有發生,「沒有 oops」就是空的 PASS。要附證據證明 throttle 真的發生了:
  - 用 M2 的 sysfs 轉換紀錄看到 0x8b,STAT 的 RTS de-asserted;
  - 讀出資料後回到 0xcf。

**修法**:
- 用 cmdline 指定一個不在 ttyS0 的 console,而且不能在 ttyAMA0(那時是 BT)。例如測試期間只留 `console=tty1`。這也要先備份、印出 sha,測完還原。
- 列出每個資源和它的還原方式,包括:p1 distroconfig、cmdline.txt、gpsd、`ble-ok`,以及 10 份關機紀錄(先備份 `/opt/batdata/log`)。
- 還原後重開,確認以下都正常:
  - 見證 = 0xcf;
  - 探測成功;
  - `bootConfigOK` 為真;
  - `ble-ok` 已更新。

---

## MINOR

1. **rs485_config hook 讀到的是舊的 `port->rs485`**:`uart_set_rs485_config` 是在 callback 返回之後才更新 `port->rs485 = rs485`(`serial_core.c:1508-1510`)。所以先開 crtscts、再開 rs485 時,`update_flow` 看到的還是 rs485 關閉,auto 會一直開著。這正是這個 hook 要防的情況。關閉 rs485 時沒問題(`:1514` 會再呼叫 set_mctrl)。修法:把 `rs485->flags` 當參數傳進 `update_flow`。持鎖的 ⚠️ 可以拿掉,兩個呼叫點都已持鎖(`:1458`、`:1507`)。
2. **probe 時寫一次 CNTL**,讓 cache 和硬體一致。這樣可以拿掉「平台驅動 rebind ⚠️ 推論」那一列,也能消除 `r305aux` 造成的不一致。
3. **§7「遠端 → 改善」是推論**:§10 的負載約 1060 B/s,大約只有 230400 baud(約 23 KB/s)的 4.6%。在接近滿速率、持續背壓的情況下,控制器會怎麼反應沒有測過。標 ⚠️。
4. **§4 時序第 3 點**少了 0x8b 這個中間態,§6 也一樣(與 M2 一致)。
5. **bcm2710**:這個 commit 編出來的 Pi 3 image 是「只有 build、沒開機驗證」。在 VERSIONS 或 release notes 標明,不能當成已驗證的版本發布。
6. **證據附原始紀錄**:§3 的區辨實驗和 close 時間,在 #305 留言裡只有表格。請附上 `disc.log` 的原始行,特別是 `tx_fill=0` 那幾行(它決定了 M1 的解讀)。
7. **`dev_info_ratelimited` 的其他問題**:就算 B1 解了,Pi 3 / CM4 的 n_tty 使用者每次 throttle 都會產生一筆 log。改用 sysfs 之後,這個問題就不存在了。
8. **`uart_enable=1` 不是有效的 key**(E7):和本單無關,但 T6 的前提依賴它。只在 #305 記一行,不另開單。

---

## 第 1 輪發現的關閉狀態(我的 B 與 A)

| 第 1 輪 | 狀態 | 依據 |
|---|---|---|
| B-B1 / A-B1 throttle NULL | ✅ 關閉 | 沒有設 `UPSTAT_AUTORTS` → `uart_throttle` 走 `uart_clear_mctrl`(`serial_core.c:741-750`);`skip_rx` 需要 `read_status_mask` 沒有 DR(`8250_port.c:1936-1938`),這只有 omap 的 throttle 才會清 → 不會觸發;設了 `UPSTAT_AUTOCTS` 後 `uart_softcts_mode` = false(`serial_core.h:1014-1018`),`hw_stopped` 會在 `serial_core.c:234-241` 重算並 start_tx,NOMSI 輪詢(`8250_core.c:259-265`、`8250_port.c:1533`、`:1875`)只在 `hw_stopped` 時才會跑 → 不會殘留 |
| B-M1 / A-M1 build 路徑 | ✅ 關閉 | `build-board.sh:75-84` 的 BASE 包含 `target` → 必須先 commit;`kernel-build.mk:12-13` 的 STAMP_PREPARED 會對 PATCH_DIR 取 md5 → 會重新 prepare;`kernel-defaults.mk:130` 的 vermagic 只取 `.config` → 不變 |
| B-M2 / A-M1 見證 | ❌ 沒有關閉 → B1、M2 | |
| B-M3 / A-M3 init | ⚠️ 部分:CTS 那一半已有證據;RTS 的組合沒測過,也沒有判準 → M4 | |
| B-M4 替代方案 | ✅ | §9 |
| B-M5 close 30 s | ❌ 沒有關閉 → M1(引用的 clamp 不適用) | |
| B-M6 / A-M5 harness 先進 main、原始症狀 T7 | ✅ 文字已處理;T2 工具做不到 → M3 | |
| A-M2 CM4 | ✅ | §1、§6、§11 |
| A-M4 T2 要在 02 上跑 | ❌ 沒有處理 → M3 | |
| A-M6 autocommit | ✅ | §6、§7、§11(接受風險,出貨全套是閘門) |
| A-M7 擁有權 | ✅ | §5;調查模組是第二個寫者,已寫明 |
| 鎖、mctrl 參數、極性、0xcc→0xcf、生命週期缺列、維護 | ✅ | |
| rs485(B-m3 / A-m2) | ⚠️ 加了 hook,但讀到舊的 flags → MINOR 1 | |

## 生命週期矩陣:要改寫或新增的列

| 路徑 | v2 寫的 | 實際 | 測試 |
|---|---|---|---|
| bind 見證序列 | 0xcf → 0x03 → 0xcf | 0xcf → 0x03 → 0x8b → 0xcf;unbind 再加 0x8b → 0x03 | M2 sysfs 轉換紀錄 |
| 控制器卡死且 RTS de-asserted 時 rebind | 120 ms、上限 2 × FIFO | FIFO 有殘留時最多約 30 s | M1 誘發測項 |
| mini UART 是 console(Pi 3 / CM4 預設,或 T6) | 沒寫 | 見證 printk → 死鎖;AUTOCTS + CTS 沒 asserted → 每字 busy-wait 10 ms | B1 程式審查;T6 避開 |
| init(patch 實際的組合) | ⚠️ 只能在真 patch 上驗 | 同上,但要有 FAIL 判準和事先寫好的退路 | M4 |
| rs485 在 crtscts 之後才開 | hook 會清 auto | 讀到舊 flags,不會清 | MINOR 1 |

## 安全(逐 actor)

- **遠端(BLE)**:同意「溢位造成的 DoS 會改善」,但在持續背壓下控制器怎麼反應沒有測過(MINOR 3)。新增的影響:控制器被弄卡、RTS 被拉成 de-asserted 時,主機 TX 會完全停住,rebind 恢復要多等約 30 s(M1)。這是可用性問題,症狀和今天的卡死相同。
- **本機非 root**:✅ 沒有 `/dev/ttyS*`(第 1 輪已確認)。M2 的 sysfs 屬性要設成唯讀、沒有寫入路徑,內容不含任何秘密。
- **root / 我們自己的錯**:B1(T6 會讓遠端節點死鎖)、M5(副作用沒列)、M2(假 FAIL 會讓人放寬斷言)。
- **供應鏈 / 實體 / 秘密**:同意 v2 的寫法。

## 我查證過、成立的部分

- `8250_core.c:1122-1138` 會複製 `set_termios` / `set_mctrl` / `shutdown`,`:1077` 一律複製 `rs485_config`。`serial8250_set_mctrl` 在 rs485 開著時直接返回(`8250_port.c:2059-2068`)。
- `bcm_open` 的時序(`hci_bcm.c:488-507`)。setup 在 hci power-on 時才跑(`hci_serdev.c:178-215`),而且只跑一次(沒有 `NON_PERSISTENT_SETUP`,`:150-157`)。卸載時是先 flush、`proto->close`,最後才 `serdev_device_close`(`:395-412`)。
- 手冊 Table 13 的位元定義和 reset 值(`bcm2711.txt`),rx/tx enable 的 reset 值都是 1 → 0x03。
- `ttyS0` 計數可以從 `/proc/tty/driver/serial` 讀到(02 `oe:2`、04 `oe:111`)→ T2 的速率門檻做得到。

## 判定:**REJECT**

B1 修法很簡單:鎖內不 printk,見證改成 sysfs。但這個 BLOCKER 不修,T6 會讓遠端節點死鎖。M1 要先用誘發測項量出真實的 close 時間,再決定修法。M2–M5 是測試設計和工具的問題。改完請送整份重審。
