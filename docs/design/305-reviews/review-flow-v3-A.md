# #305 mini UART 硬體流量控制設計 v3 + spike patch — 對抗式審查 A(第 3 輪,整份重審)

審查對象:`h305/305-mini-uart-flow.md`(v3)、`r305/kpatch/999-batman-bcm2835aux-autoflow-305.patch`(sha256 `86e8f027…`,與本機分支 `spike/305-autoflow` 299d66e6 上的檔案逐位元相同,已比對)、spike 原始紀錄、kernel 6.6.138 build 樹(含 patch 後的驅動)。節點 02/04 只做唯讀查詢。

## 結論:**REJECT(範圍窄)— 0 BLOCKER / 2 MAJOR / 10 MINOR**

- **patch 程式本身沒有找到正確性問題**:鎖、rs485 參數、throttle 路徑、sysfs 邊界、remove 順序都查過(見「查證過的部分」)。如果 M1 選「乙」,kernel patch 一行都不用改。
- 擋住的是**驗證規格與一個錯誤的已驗證宣稱**:
  - M1:「TX 卡住時 unbind 120 ms」是測試方法造成的假象。這個方法是我第 2 輪提議的,是我的錯(見 M1)。正確極性下,這條路徑仍是 30 s。
  - M2:T5 的兩個斷言,一個沒有分辨力,另一個在第二次 OTA 之後會永遠 FAIL。
- 兩項都只要改 §3/§6/§7/§8 的文字與測試規格,不必重新設計 patch。改完後,這兩項應該可以直接核對關閉,不需要再整輪重審 patch 程式碼。

## 更正我第 2 輪的紀錄

第 2 輪 A-M1 我建議 T3b 用 `r305aux cntl=0x4f`(錯的 CTS 極性)讓 TX 卡住,並預測會量到約 30 s。**這個方法是錯的**:
- unbind 時,`bcm_close` 先把控制器斷電(`hci_serdev.c:406` → `hci_bcm.c:554`),之後才 `serdev_device_close`(`hci_serdev.c:410`)。
- 斷電後 CTS 線變成 1。在 0x4f(active-high)下,1 代表 asserted,FIFO 就送掉了。
- 所以這個方法永遠量不到卡住的情況。作者照我的方法做,得到 120 ms,v3 據此寫成 ✅。這筆錯源自我的建議。我第 2 輪對「正確極性下會等 30 s」的分析仍然成立(M1)。

## MAJOR

### M1 「TX FIFO 有殘留時 unbind 120 ms」不成立;T3b 不管 kernel 好壞都 PASS(第 2 輪 A-M1 / B-M1 仍未關)

**情境(現場)**:控制器韌體卡住,而且它的 RTS 停在 de-asserted(接收緩衝滿了、不再消化)。patch 讓 AUTOCTS 擋住主機 TX,最多 8 bytes 留在硬體 FIFO。接著有人 rebind:人工、harness,或者 §11 準備重啟的恢復機制。

**證據:120 ms 是測試方法的假象**
- `closewait.log`(舊 kernel,0x4f):
  - unbind 前:`CNTL=0x4f … cts_line=0 … tx_fill=4`
  - unbind 後:`CNTL=0x4f … cts_line=1 … tx_fill=0`
  - 舊 kernel 的驅動不會寫 CNTL,所以 0x4f 一直留著。能讓 FIFO 送掉的,只有 CTS 線從 0 變 1 這件事。
- `disc.log`:每一筆 unbound 狀態都是 `cts_line=1`,共 8 筆,0x8b、0x47、0xcf 都一樣。控制器斷電後 CTS 線 = 1,可以重現。
- 卸載順序:`hci_serdev.c:406` `proto->close` → `bcm_close` → `bcm_gpio_set_power(bdev,false)`(`hci_bcm.c:554`),然後才是 `:410` `serdev_device_close`。接著 `ttyport_close`(`serdev-ttyport.c:154-166`)→ `tty_port_close_start` → `tty_wait_until_sent(tty, closing_wait)`(`tty_port.c:654-655`)。
- 極性(§3 表):CTSINV = active-low。
  - 0xcf 或 0x8b 下,線 = 1 是 **de-asserted**,FIFO 永遠送不出去。
  - 0x4f 下,線 = 1 是 asserted,FIFO 送掉。
- `uart_wait_until_sent`:`uart_cts_enabled` 為真時沒有 2 × FIFO 上限(`serial_core.c:1847-1860`),而 serdev 永遠開著 CRTSCTS。所以要等到 `closing_wait` = 30 s。
- HUPCL 的 0x8b 和 shutdown hook 的 0x03 都在 wait **之後**(`spike-b.log` 的 `last=…,0x8b,0x03` 是 unbind 的最後兩筆)。patch 沒有任何東西能在 wait 之前解開。
- 從這些證據可以推出:
  - v3 §3 的 ⚠️「為什麼沒有等到 30 s,原始碼上還沒解釋」現在已經有解釋了,就是上面這條因果鏈。
  - §6 那一列「控制器卡死 / 斷電、TX FIFO 有殘留 → unbind 120 ms ✅」是錯的。
  - §7「實測 rebind 120 ms 可恢復」也是錯的。
  - T3b 用 0x4f,在舊 kernel、真 patch、壞 patch 上都會是 120 ms。v3 自己也寫了「舊 kernel 同測:120 ms(用來記錄,不是負對照)」。所以這項**沒有負對照,不可能 FAIL**。
- `disc.log` 有一筆「auto ON + injected wedge → 120 ms」,但那次 `tx_fill=0`:btwedge 用鮑率錯開,控制器的 RTS 照樣 asserted。所以這筆碰不到這個情境。

**影響**:
- 今天 fleet 沒有自動 rebind 的使用者,恢復機制暫停,重開/斷電不受影響(見 m2),所以現場立即風險低。
- 但這是 patch 引入的新行為。設計把錯的時間預算寫成已驗證,§11 一旦重啟恢復機制,就會用錯的預算。

**修法**:
1. 二選一,寫進 §5/§6/§7:
   - **甲**:probe 註冊完後,把該 port 的 `closing_wait` 設成 `ASYNC_CLOSING_WAIT_NONE`。藍牙 close 時控制器已經斷電,丟掉最多 8 bytes 無害。要附證據說明 `port.state` 在 register 後有效,並把 `closing_wait` 列進擁有權表。
   - **乙**(最小):接受最多約 30 s,寫明恢復機制的時間預算 = 30 s + `hci_dev_close_sync` 的逾時。依「後續工作會取代就只做最小止血」,我傾向乙,恢復機制的設計之後會接手這件事。
2. 重寫 T3b,讓卡住在斷電後仍然成立:
   - 用 `r305aux cntl=0xcd`(= 0xcf 去掉 TXEN),送 btprobe,唯讀確認 `tx_fill>0`,對 unbind 計時,重開還原。
   - 依原始碼,unbind 路徑在 wait 之前不會從快取回寫 CNTL。⚠️ 這是我讀原始碼推得的,第一次跑時要用 sysfs `last=` 確認:wait 結束前沒有新的寫入。
   - 判準:甲 < 5 s,負對照是不含甲的 spike build,預期約 30 s。乙 ≤ 31 s,而且之後 20 s 內探測成功;負對照同上。這是驗收一次的項目,會寫 CNTL,要使用者授權。
3. §3 的 ⚠️ 改成上面的因果鏈,§12 對照表更正。

### M2 T5 的兩個斷言:`uname -v` 沒有分辨力;「rollback 後 autoflow 不存在」在第二次 OTA 後會永遠 FAIL

**證據**:
- `uname -v` 是固定的:`firmware-2710/version.date` = `1750711236` = `Mon Jun 23 20:40:36 UTC 2025`。`scripts/get_source_date_epoch.sh` 先用 `try_version`,`include/kernel.mk:10-12` 拿它當 `KBUILD_BUILD_TIMESTAMP`。
  - 02 現在(wsl.15)和 04 都是 `#0 SMP Mon Jun 23 20:40:36 2025`。
  - 02 在 10-21 到 10-22 的多份 shutdown log 跨不同 build,也全都是同一個字串(`logbak-10.41.1.1/log/shutdown_2026102*`)。
  - 所以 wsl.16 spike 的 `uname -v` 幾乎可以確定也一樣。
- autoflow 檔不存在:只有在另一個 slot 還是 #305 以前的 image 時才會成立。出貨後 fleet 做第二次 OTA,兩個 slot 都帶 patch,tier A 的 A/B 套件就會在每次 rollback 斷言 FAIL。違反「測項只能有一套、不能長期紅燈」的前提。

**修法**:
- T5 改成:rollback 後,autoflow 是否存在 = 依該 slot 的 `/etc/batman-build` `BATMAN_VERSION` 推出來的預期值,版本 ≥ 首個含 #305 的版本就應該存在,或在 image 放一個 feature 標記檔。不用 `uname -v`。
- 「rollback 到 pre-#305 後檔案不存在」只留作出貨時的一次性驗收(已有 `soak16-…-180526.log` 尾段 `can't open …/autoflow` 可當紀錄)。

## MINOR

- **m1 rebind 序列寫錯(第 2 輪 A-M2 第 2 點又退回去了)**。
  - `spike-a.log` 第 1 次 rebind:unbind 時 writes 4→6,加了 `0x8b,0x03`;bind 時 6→11,共 **5 筆**:`0x8b,0xcf,0x03,0x8b,0xcf`。後 9 次也一樣,例如 rebind 2 的 `last=0x03,0x8b,0xcf,0x03,0x8b,0xcf,0x8b,0x03`。
  - v3 §4/§6 寫的是 `0x8b → 0x03 → 0x8b → 0xcf`,4 筆,少了 open 時 `uart_port_dtr_rts` 拉高 RTS 造成的 0xcf。T3 斷言「sysfs 序列 = §4 rebind 序列」,照寫會讓正確的 patch FAIL。
  - 那段 0xcf 出現在 `bcm_open` 上電之前,控制器還是斷電的,所以無害。但 §4「0x8b 這段只開 AUTOCTS」要改寫,說明 open 時有一段 AUTORTS 窗口、為什麼無害、證據是 10/10。
- **m2 「正常關機 / 重開:shutdown hook → 0x03」沒有根據**。`hci_bcm.c`、`hci_serdev.c`、`8250_bcm2835aux.c` 都沒有 `.shutdown`(grep `shutdown` 只命中 BT_REG_ON gpio)。重開時 port 不會被關,CNTL 停在 0xcf,直到 SoC 重置。無害,但這一列要照實寫。
- **m3 平台驅動 unbind 後,hook 留在 placeholder port 上**:
  - `serial8250_unregister_port`(`8250_core.c:1220-1229`)把 port 改成 `PORT_UNKNOWN`、`dev = serial8250_isa_devs->dev`,但 `serial8250_init_port`(`8250_port.c:3300-3311`)只重設 `ops`。`port->set_termios`、`set_mctrl`、`shutdown` 仍然指向本 patch 的函式。
  - 如果 root 先 unbind `bcm2835-aux-uart`,再開 ttyS0、做 set_termios,hook 會對 isa device 呼叫 `dev_get_drvdata`,拿到錯的結構或 NULL,而且是在持 port lock 時。
  - 只有 root 做得到。上游很多 8250 驅動,以及本驅動原有的 `rs485_start_tx`,都是同樣的寫法。
  - 修法:§6「平台驅動 rebind」列寫明這是已知的 root-only 限制。或在 hook 開頭加 `if (port->dev->driver != &bcm2835aux_serial_driver.driver) return/降級呼叫 serial8250_do_*`。
- **m4 sysfs `autoflow` 用 0444,非 root 和容器都讀得到**。每次讀都會 `uart_port_lock_irqsave` 加一次 MMIO 讀。一個不斷讀它的非 root 程式或被入侵的容器,會在 UART IRQ 路徑上製造鎖競爭。有了 AUTORTS 之後不會再溢位,只會拖慢,但這是新的攻擊面。
  - 只有 root 的 harness 需要讀,所以改成 `DEVICE_ATTR_ADMIN_RO`(0400)。
  - 改用 `platform_driver.driver.dev_groups`:屬性會在 KOBJ_BIND 前建立、自動移除,也不用處理 `device_create_file` 失敗只 warn 的情況。
  - §7「本機非 root」與「受入侵容器」兩列同步更新。
- **m5 `lockdep_assert_held_once` 在出貨 build 裡不會執行**:`.config` 沒有設 `CONFIG_PROVE_LOCKING`。§4 不要把它當持鎖的證據。持鎖的證據是呼叫點,我逐一查過全部 set_mctrl 呼叫點,見下方 ✅。
- **m6 `btadv` 的 instance 0x0f 很可能被拒**:
  - `add_ext_adv_params` 要求 `instance ≤ hdev->le_num_of_adv_sets`(`mgmt.c:8886`)。這個值預設是 `HCI_MAX_ADV_INSTANCES` = 5(`hci_core.c:2496`、`hci_core.h:268`),只有控制器支援 LE ext adv 時才會改成控制器回報的數(`hci_event.c:1829`)。
  - BCM4345C0 支不支援,我在節點上唯讀查不到:沒有 debugfs、沒有 dbus-send,⚠️ 未查證。
  - 修法:btadv 先 `MGMT_OP_READ_ADV_FEATURES`,取 `max_instances`,用最大號 instance,並斷言它沒有被占用;不符就 FAIL。20 ms non-connectable legacy 間隔能不能被接受,也要在第一次實跑時記錄實際 interval。
- **m7 T3b 和調查用的 `r305aux.ko` 在 scratchpad,不在 harness**。依「測項只能有一套」,它的原始碼要進 harness,附 SHA256SUMS。每個 rc kernel 都要對應的 vermagic 版本,寫明怎麼 build。另外,T3 依賴「P2 之前沒有 provd 註冊」:前提不成立時要 FAIL,不能 skip,並在 #254 P2 落地時重看。
- **m8 生命週期少了 crash 列**。hook 在持 port lock、IRQ 關閉時出 oops,等於整台當掉。commit 前開機就當:Pi 4 tryboot trial 會退回(有 spike 期間 600 s 期限退回的實例)。commit 後只有 rebind 才觸發:靠 watchdog 或使用者斷電。另外 `hci_uart` 是模組(`CONFIG_BT_HCIUART=m`),rmmod/modprobe 等同 T3,補一句即可。
- **m9 §10b 證據的細節要照實寫**:
  - 第 2 次開機(`ota16b-04.log`)沒有 btprobe 輸出:`/tmp/run` 重開後不存在。探測成功的證據是 soak 第一筆 `up=161 probe_rc=0`。privacy/sc 只有第 1 次開機有(`spike-a.log`)。
  - 作廢的那份 soak(`…180526.log`)第一筆 `up=410 txto=2` 在 spike kernel 上。要明確歸因到 spike-b 故意製造的 0x4f 卡住(btprobe × 2)。
  - `oe` = 0 是從 `/proc/tty/driver/serial` 這一行沒有 `oe:` 欄位推出來的(02 現在有 `oe:2`,所以非零時這個欄位會出現)。T2 的解析要求這一行必須存在(`^0: uart:16550 mmio:0xFE215040`),不存在就 FAIL,不能當 0。
- **m10 harness PR 的「rc PASS」**:harness 比產品 PR 先進 main,所以那份 PASS 只能在 spike build 上跑。要寫明:產品 PR 的 patch sha 必須等於 `86e8f027…`,否則產品 rc 要重跑 T1/T2/T3。

## 第 2 輪 BLOCKER / MAJOR 結案核對

| 第 2 輪 | 狀態 | 依據 |
|---|---|---|
| B-B1 鎖內 printk | ✅ 關 | patch 鎖內沒有任何 printk。唯一的 `dev_warn` 在 probe、鎖外 |
| A-M1 / B-M1 close 30 s | ❌ **未關** → 本輪 M1 | 120 ms 是 0x4f 方法的假象(我第 2 輪的方法錯了) |
| A-M2 / B-M2 見證 | ✅ 大致關(sysfs、硬體讀回、沒有 ratelimit) | 序列寫錯 → m1 |
| A-M3 / B-M3 T2 負載 | ✅ 設計上關 | instance 號 → m6 |
| B-M4 init 閘門 | ✅ 關 | 開機 2/2(`ota16*-04.log` `writes=4 last=0xcf,0x03,0x8b,0xcf`)、rebind 10/10(`spike-a.log`)、`disc.log` 0x8b 3/3 / 0x47 3/3 失敗 |
| B-M5 T6 | ✅ 關(不做,理由與 bench 殘項成立) | — |

第 2 輪我的 MINOR:
- m1 rs485 用參數:✅,patch `bcm2835aux_rs485_config` 用 `rs485->flags`,而且有清 `UPSTAT_AUTOCTS`。
- m2、m3、m5、m6:✅。
- m4 T7 分辨力:有標 ⚠️,接受。
- m7:隨 T6 移除。
- m8:§7 有補,但內容錯 → M1。

## 查證過、成立的部分(✅ 附證據)

- **set_mctrl hook 的所有呼叫點都持 port lock**:
  - `serial_core.c`:181-186(`uart_update_mctrl`)、1507-1514(rs485)、2433-2436(suspend)、2527-2529 / 2539-2541(resume)、2656-2658(configure)。
  - `8250_port.c`:2392→2399(startup)、2516→2523(shutdown)、2920(set_termios 內)。
  - `set_termios` 和 `shutdown` hook 自己拿鎖,呼叫者不持鎖(`serial8250_do_set_termios` 本身也要拿這把鎖)。沒有自鎖。
- **sysfs show**:
  - 在行程上下文用 irqsave 拿 port lock,安全;鎖內沒有 printk。
  - 最長輸出約 85 bytes,遠小於 PAGE_SIZE。
  - `nhist` 在 2³² 繞回時,因為 2³² 能被 8 整除,索引仍然連續,只是 `first` 會少列幾筆,無害。
  - `device_remove_file` 在 `serial8250_unregister_port` 之前執行,kernfs 會等進行中的 show 結束。
- **probe 時寫 CNTL**:`CONFIG_SERIAL_8250_BCM2835AUX=y`、`CONFIG_BT_HCIUART=m`,所以 BT 的 serdev probe 一定在 probe 之後。寫入的是快取值,就算順序相反也是冪等的。
- **throttle**:hook 先 `serial8250_do_set_mctrl`(此時 AUTORTS 還開著,MCR 不起作用),再關 AUTORTS,MCR 接手讓 RTS de-assert。順序正確。
- **soak**(`soak16-20261024-181701.log`):
  - 178/178 `probe_rc=0`。
  - 沒有任何一行出現 `frame` 或 `txto` 非 0,沒有任何一行出現 `oe:`,`writes=4` 全程不變。
  - rx 從 4379 到 6,077,419,約 6.07 MB / 90 分,約 1.1 KB/s,與 §10b 相符。
- **節點現況**(唯讀,10-24):
  - 02/04 都是 `1.5.12-wsl.15+0328e83.fw84cede4`,沒有 `autoflow`。
  - 02:`oe:2`,Frame reassembly 加 tx timeout 共 2 行。04 剛開機,0 行。
- **patch 檔與分支一致**:兩者 sha256 都是 `86e8f02746c3…`。

## 安全(逐 actor)

- **遠端(BLE)**:讓控制器 RTS 停在 de-asserted 的攻擊,在 patch 後會讓主機 TX 卡住,恢復要約 30 s(M1)。§7 要照實寫。
- **本機非 root / 受入侵容器**:sysfs 讀取會造成鎖競爭(m4)。沒有寫入路徑。
- **root / 我們自己的錯**:平台 unbind 後 hook 懸空(m3);T3b 依賴 scratchpad 模組(m7)。
- **實體 / 秘密**:無新增。
- **供應鏈**:patch 標頭已寫明 kernel 版本與 rebase 責任。

## 判定:**REJECT(範圍窄)**

- patch 程式可以維持原樣(選乙時)。
- M1、M2 都是驗證與宣稱的問題。修正 §3/§6/§7/§8/§12 與 T3b/T5 規格後,這兩項只需要核對關閉。
- MINOR 建議在 harness PR 前一起改,特別是 m1:不改的話 T3 會讓正確的 patch FAIL。
