# #305 mini UART 硬體流量控制(kernel patch)設計 v3 — 對抗式審查 B(第 3 輪)

審查對象:`305-mini-uart-flow.md` v3(整份重審)+ 真 patch `999-batman-bcm2835aux-autoflow-305.patch`(=`spike/305-autoflow` 299d66e6)。
對照:使用者全域規則、`docs/design/REVIEW.md`、build 樹 kernel 6.6.138 原始碼、BlueZ 5.72 原始碼、Batman main a62bf78(harness)、`scratchpad/r305/` 原始紀錄、02/04 唯讀探測(只讀 /proc、/sys、dmesg、`/opt/batdata/log/*`;沒有寫入、沒有 bluetoothctl、沒有重開)。

## 結論:**REJECT** — 0 BLOCKER / 1 MAJOR / 10 MINOR

- patch 程式碼本身我沒有找到缺陷:所有 `set_mctrl` 呼叫點都持鎖、鎖內沒有 printk、drvdata 在 register 前就設好、rs485 用參數、probe 寫的是快取值。
- spike 紀錄大致撐得起 §10b:每個 tick 都在 spike kernel 上、CNTL 從頭到尾沒變、負載 ≥ 1 KB/s(細節見「查證」)。
- 唯一的 MAJOR 是 §3 / §6 / §7 / T3b 的「TX 卡住時 unbind 120 ms」。原始紀錄本身就能解釋這個 120 ms:它是錯誤極性注入造成的假象。換成正確極性,依原始碼要等 30 s,而 T3b 照現在的寫法測不出來(M1)。這是第 2 輪 M1 沒有真正關掉的部分,也會改變 T3 的預期序列,所以要先定案再凍結 harness。

---

## 查證(我自己看過的原始資料)

| # | 事實 | 證據 |
|---|---|---|
| E1 | 90 分鐘 soak 每個 tick 都在 spike kernel 上 | `soak16-20261024-181701.log`:178 個 tick 的 `up=` 從 161 單調增加到 5542,沒有重開。每一行都讀得到 `autoflow`(wsl.15 沒有這個檔) |
| E2 | CNTL 沒變 | 179 行都是 `hw=0xcf cache=0xcf writes=4`。`writes` 一直是 4,代表驅動沒有寫過。`hw` 每 30 s 讀一次 |
| E3 | 負載 | rx 從 4379 增加到 6077419,共 5381 s,平均 1129 B/s;probe 178/178 |
| E4 | oe = 0 的讀法 | tick 只印 `/proc/tty/driver/serial` 從 `tx:` 開始的部分。serial core 只印不為 0 的計數,所以「沒有 `oe:`」就是 0。這個讀法成立,但 §10b 沒有寫出來 |
| E5 | 第二次 trial 是 **COMMITTED**,不只是 release | 04 `autocommit.log`:`20250720-184517 RELEASED` → `184528 COMMITTED … wsl.16`。之後 `boot-reasons.log`:`trigger=r305-spike-end`、`trigger=r305-restore-A` |
| E6 | 第一次 spike 開機有 2 次 `command tx timeout` | 04 `shutdown_20250720-184337_39adf525.log`:343.74 s 時 `r305aux after: CNTL=0x4f`,345.99 s / 351.19 s 出現 tx timeout = spike-b 的注入。作廢的 soak `txto=2` 也來自這裡 |
| E7 | **close 120 ms 的原因** | `closewait.log`:卡住時 `CNTL=0x4f cts_line=0 tx_fill=4`,unbind 後 `cts_line=1 tx_fill=0`。`disc.log`:每次 unbind 後都是 `cts_line=1`。`hci_serdev.c:406`(`proto->close` → `bcm_close` → `hci_bcm.c:554` 斷電)在 `:410` `serdev_device_close` **之前** |
| E8 | `uname -v` 每個 build 都一樣 | firmware `version.date` = 1750711236。所有 build 都是 `#0 SMP Mon Jun 23 20:40:36 2025`(logbak 2025-07 與 2026-10 的 shutdown log,以及 02/04 現在的值) |
| E9 | 04 現況 | slot A,uptime 573 s,`fe215040.serial/` 沒有 `autoflow`,ttyS0 沒有 oe,dmesg 0 筆錯誤。02:uptime 15.8 h,`oe:2`,dmesg 2 筆(舊 kernel 的自然溢位還在發生) |
| E10 | adv instance 上限 | `mgmt.c:8886` `instance > hdev->le_num_of_adv_sets` → INVALID_PARAMS;沒有 ext adv 時預設是 `HCI_MAX_ADV_INSTANCES` = 5(`hci_core.c:2496`、`hci_core.h:268`) |
| E11 | image 上已經能用 mgmt 送 ext adv | BlueZ 5.72 `client/mgmt.c:5982` `add-ext-adv-params`(`-r` min / `-x` max interval,`:4938-4955`)。harness 的 `ble-periph-254.sh` 已經透過 `bluetoothctl mgmt` 直接管 instance 1(`:45`、`:52`、`:171`) |
| E12 | lease 釋放時不清 adv | `ble-lib-254.sh:202-209` `cmd_release` 只刪 lease 和 deadman。只有 deadman 的 `role_fire_restore`(`ble-periph-254.sh:171-177`)會 `rm-adv 1` 並重啟 bluetoothd。preflight 看到任何殘留的 instance 都判 FAIL(`ble-lib-254.sh:156-157`)。bluetoothd 啟動時會清掉所有 instance(`advertising.c:1892-1893`) |

### 第 2 輪的 BLOCKER / MAJOR 是否已關

| 第 2 輪 | 狀態 |
|---|---|
| B1 鎖內 printk | ✅ 已關。`update_flow` 沒有 printk;`dev_warn` 只在 probe、鎖外 |
| M1 close 30 s | ❌ **沒關**。原始碼的說法已更正,但結論改成依賴一個被注入方式污染的量測(本輪 M1) |
| M2 見證 | ✅ sysfs 已關。但 §4 的 rebind 序列和實測不符(m1) |
| M3 T2 負載 | ⚠️ 大方向對。instance、擁有權、清理方式有錯(m2、m3) |
| M4 init 閘門 | ✅ 已關。真 patch 開機 2 + rebind 10 = 12/12;T3 改成判定;T4 有 FAIL 判準 |
| M5 T6 | ✅ 不做,理由成立,殘項已列 |

---

## MAJOR

### M1 — 「TX 卡住時 unbind 120 ms」是 0x4f 注入的假象;正確極性下要等 30 s,T3b 測不出來

**機制**(這也就是 §3 標成「未解釋」的那件事):
1. unbind 的順序是:先 `bcm_close` 讓控制器斷電(`hci_bcm.c:554`,由 `hci_serdev.c:406` 呼叫),之後才是 `serdev_device_close`(`:410`)→ `tty_port_close_start` → `uart_wait_until_sent`(`tty_port.c:654-655`;CTS 開著,沒有 clamp,`serial_core.c:1846-1858`)。
2. 控制器斷電後,它的 RTS 輸出、也就是我們的 CTS 輸入,會變成 1(E7:每次 unbind 後都是 `cts_line=1`)。
3. 注入用的 0x4f 是 AUTOCTS 配**預設**極性(assert = high)。斷電前線是 0 → de-asserted → 卡住;斷電後線變 1 → 對 0x4f 來說是 asserted → FIFO 立刻送光 → `tx_empty` 變真 → 120 ms。`closewait.log` 的 `after: cts_line=1 tx_fill=0` 正好是這個過程。
4. 真 patch 是 0xcf(CTSINV,assert = low)。斷電後線是 1 → **de-asserted** → FIFO 不會送 → 等滿 `closing_wait` = 30 s(`tty_port.c:100`),之後 shutdown hook 寫 0x03 才放行。

**現場情境**:控制器卡死(或 init 失敗)時把 RTS 拉成 de-asserted,而主機的 TX FIFO 還有命令(例如 hci core 的重送、`hci up` 時的 HCI_Reset)。之後每一次 rebind 都要約 30 s,不是 §7 寫的「實測 rebind 120 ms 可恢復」。舊 kernel 沒有 AUTOCTS,FIFO 不管 CTS 都會送光,所以這是 patch 帶進來的行為改變。影響:
- 恢復機制(暫停中)的時間預算;
- 人工救援;
- T3 的「unbind < 5 s」只在健康狀態下成立。

**T3b 為什麼不是防線**:用 0x4f 注入時,斷電一定會解開卡住的狀態。不論 patch 對錯,T3b 都會是 120 ms,沒有分辨力。

**修法**(要先選一個,寫進設計):
- (a) **接受 30 s**:更正 §3 / §6 / §7。恢復預算寫 ≥ 30 s。T3b 改成量 serial core 的等待上限:用 `r305aux` 寫一個 **TXEN = 0** 的 CNTL(例如 0xcd),讓 FIFO 不管 CTS 都送不出去 → unbind 計時,預期約 30 s(舊 kernel 也是,因為 serdev 本來就開著 CTS)。再加上 E7 已經量到的「斷電後 `cts_line=1`」,就構成正確極性下約 30 s 的證據鏈。
- (b) **讓 close 有界**:另外 patch `hci_bcm`,在 `bcm_close` 斷電前先 `hci_uart_set_flow_control(hu, true)`(關 CRTSCTS)。這樣 `set_termios` hook 會關掉 AUTOCTS,FIFO 會送光;`UPSTAT_CTS_ENABLE` 也會被清掉(`serial_core.c:223-226`),2 × FIFO timeout 的 clamp 就會生效。
  - 代價:多一個 downstream patch。§4 的 unbind 序列會變,T3 的預期序列也要跟著改。所以 **M1 要在 harness PR 凍結 T3 之前定案**。
  - 負對照:用 (a) 的 TXEN = 0 注入測 unbind。沒有 (b) 約 30 s;有 (b) 應 < 1 s(clamp 生效)。

---

## MINOR

**m1 — §4 / §10b 的 rebind 序列與實測不符,照寫的 T3 會讓正確的 patch FAIL。**
- `spike-a.log` 的 `writes` 每次 rebind 增加 7:unbind 2 筆(0x8b、0x03),bind 5 筆:**0x8b → 0xcf → 0x03 → 0x8b → 0xcf**。§4 寫的是 4 筆的 `0x8b → 0x03 → 0x8b → 0xcf`。
- 多出來的 0xcf 來自 `uart_port_startup` 的 `dtr_rts(true)`,早於 `bcm_open:491`。那時控制器在 rebind 情況下還沒上電,應該無害,但要寫進 §4,也要寫明這段為什麼無害。
- 一次 rebind 是 7 筆,`hist` 只有 8 格,只剩 1 格餘裕。T3 應該用 `writes` 的差值(+7)加上最後 7 筆來比對。
- 若採用 M1(b),序列要重新推導。

**m2 — T2 的 `btadv`:instance 0x0f 不合法、和既有的擁有者重疊、「lease 釋放清理」不成立。**
- (i)控制器沒有 ext adv 時上限是 5,0x0f 會 INVALID_PARAMS(E10)。BCM4345C0 支不支援 ext adv,⚠️ 我沒查到。
- (ii)不需要新工具:`bluetoothctl mgmt.add-ext-adv-params -r 0x20 -x 0x20 <inst>` + `add-ext-adv-data` 就可以(E11)。
- (iii)02 上 adv instance 的擁有者已經是 `ble-periph-254.sh`(instance 1,lease + deadman)。T2 應該透過它新增一個 `adv-fast` 指令,而不是另一個寫者。
- (iv)`cmd_release` 不會移除 instance(E12)。照 §8 的寫法,殘留的 instance 會讓下一個 BLE 套件的 preflight 判 FAIL(fail-closed,但歸因錯)。release 前必須 `rm-adv` 並確認 `advinfo` = 0。
- (v)02 開著 privacy(RPA),「掃描看到對端的廣播」要靠廣播內容裡一個唯一標記判斷,不能靠位址。
- (vi)20 ms 的 non-connectable legacy 廣播,控制器要是 5.0 才接受。不接受時要判 FAIL,不能默默退回 1.28 s。負載保證可以兜底,但要寫明。

**m3 — 負載保證只看 UART rx,沒有看造成溢位的中斷延遲來源(SD 讀取)。**
- `xo2-tick.sh` 每個 tick 會補起 `dd`,但紀錄裡沒有任何證據顯示它在跑:`spike-stop` 的「no scan/load left」是殺掉之後的結果。
- rc 那次如果 dd 沒在跑,T2 PASS 很便宜。
- **修法**:每段記錄 `/proc/diskstats` 中 mmcblk0 讀取 sectors 的差值,設門檻,不到就 FAIL。§10b 的 soak 結論也要標明「SD 負載沒有紀錄」。

**m4 — harness 先進 main 時,新測項在 wsl.15 fleet 上的行為沒寫清楚。**
- T3 若在檔案不存在時照樣 rebind,每天會在舊 kernel 上 rebind 20 次。舊 kernel 的 init 失敗率約 1/30,等於每天約一半機率把某台的 BT 弄壞。
- **修法**:T3 / T5 在 `autoflow` 不存在時立即 FAIL,不做任何動作;known-failures 也要涵蓋 T3 / T5,不只 T1。
- `validation-known-failures.txt` 的格式是 `suite<TAB>ERE<TAB>issue`,沒有到期日欄位。「到期」實際上是靠 issue 關閉後 gh 檢查變成 NEW(`daily-validation.sh` 約 :2700)。§8 的「附到期日」要改成這個機制。

**m5 — 破壞性測項的還原沒有寫全。**
- T3 是每天跑的 tier A,在部署角色的節點上每天 rebind 10 次。如果某次 rebind 後 init 失敗(T4 本來就是 ⚠️),由誰、用什麼還原?例如再 rebind 一次,不行就 `batman-slot reboot committed`。
- P2(provd 註冊廣播)上線後,每天的 rebind 會把它的註冊清掉,§8 只寫了「P2 之前」。
- T2 的負對照跑在 wsl.15 上,90 分鐘內可能卡死約 3 次(§10a),跑完要寫還原步驟,避免下一個套件被它拖垮。

**m6 — T5 的 `uname -v` 沒有分辨力**(E8)。改用 `/etc/batman-build` 的 `BATMAN_VERSION`,加上 `autoflow` 不存在。

**m7 — §6 / §10b 的證據敘述要精確。**
- (a)§6 寫開機 1/1,§10b 寫 2/2。第二次開機沒有 health / privacy 的紀錄:`ota16b-04.log` 只有 autoflow 和 morse 計數,`btprobe` 不在 → 「privacy / sc / sc_file = 1」只對第一次成立。
- (b)要寫出第一次開機的 2 次 tx timeout,並附上歸因(E6)。依使用者規則,每個 FAIL 都要歸因。
- (c)第二次 trial 是 COMMITTED(E5),spike kernel 一度是 04 的 committed slot。
- (d)「rollback 後 `autoflow` 不存在」的證據在作廢的 soak 的結尾(`soak16-20261024-180526.log`:自動退回 A 後 `can't open … autoflow`)和現在的探測(E9),不是某份「收尾」紀錄。
- (e)寫明 oe = 0 是怎麼讀出來的(E4)。
- 附帶:作廢的 soak 在退回 wsl.15 後 60 s 內就出現 `oe:7 frame=5`。但那時 `/tmp/run` 不存在,掃描與 dd 疊了好幾份,只能當參考,不能當負對照。

**m8 — 出貨路徑還不夠具體,動手前要補一段。**
- **firmware PR**:patch 放在 `target/linux/bcm27xx/patches-6.6/`,bcm2710 / 2711 / 2712 共用。base 是當時的 `build-3aplus` HEAD(現在是 72814fa4)。同一個 PR 改 `batman-release.env`。
- **版號**:依 `VERSIONS.md`「fix 出貨升 PATCH、rc 是那個號碼的 -wsl.N、不准出比 rc 低的號碼」→ 本單出貨為 **1.5.13**,rc 是 1.5.13-wsl.N。spike 的 1.5.12-wsl.16 要列為退役號碼,永不燒錄、永不出貨。
- **兩個 subtarget**:build 時驗證兩板的 kernel 都有套到 patch,例如 quilt series 或 vmlinux 裡有 `autoflow` 字串。bcm2710 必須 `-Werror` 編過。
- **build 樹**:`build_dir` 現在是 spike 改過的原始碼(OpenWrt 會依 patch md5 重新 prepare,⚠️ 沒有實證)。第一個 rc 要確認 `BATMAN_DIRTY` = 0。
- **順序**:harness PR(T1 / T2 / T3 / T5 + known-failures)→ firmware PR + Batman docs PR(`boards-and-builds.md`、`VERSIONS.md`)→ merge 後在出貨 image 上跑全套。feed pin 要不要動,要寫明。

**m9 — n_tty 使用者的契約改變沒有列進生命週期。**
- 今天,mini UART 上的 CRTSCTS 只有軟體 CTS(NOMSI,只在 termios 改變時看一次);patch 之後是硬體持續生效。
- 若 CTS 沒有接線(3 線)又開了 crtscts,TX 會永久停住。
- 現在 fleet 沒有這種使用者,但 bcm2710、CM4、選項 B 都可能有。在 §5 契約與 §6 加一列。

**m10 — 小項。**
- `autoflow` 用 0444,任何本機使用者都能高頻讀取、搶 port lock。現在影響很小,但 harness 用 root 讀,改成 0400 沒有成本。
- 設 `UPSTAT_AUTOCTS` 後,8250 IRQ 在 stop_rx 之後會跳過 RX(`8250_port.c:1936-1939`)。這是新依賴的行為,要列進 §4 證據表:stop_rx 同時清掉 RDI,所以不會造成 IRQ storm。

---

## 安全(逐 actor)

- **遠端**:同意 ⚠️ 預期改善。M1 補一點:卡死後的 rebind 時間在正確極性下約 30 s。
- **本機非 root**:沒有 tty 節點;sysfs 唯讀。見 m10。
- **我們自己的錯**:T1 釘死 `hw=0xcf`、T3 釘死序列,極性或閘門寫錯都抓得到。autocommit 不看 BT(E5:spike 被 commit 就是實例),所以出貨前全套是唯一閘門。這點設計已經承認。
- **供應鏈**:patch 套不上時 build 會失敗(fail-closed)。
- **秘密**:沒有新增。

## 判定

REJECT(1 MAJOR)。M1 只要選 (a) 或 (b),並把 T3b 換成 TXEN = 0 的注入,就能關掉;它同時決定 T3 的預期序列,所以要先定。m1–m10 可以和 M1 同一版修完,再整份重審。patch 程式碼本身可以照 spike 版保留(若採用 (b),另加 hci_bcm 的改動)。
