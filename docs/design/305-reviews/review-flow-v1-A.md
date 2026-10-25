# #305 mini UART 硬體流量控制設計 v1 — 對抗式審查 A(第 1 輪)

**審查對象**:`305-mini-uart-flow.md` v1(整份)。對照:`305-bt-recovery.md` 與兩份舊 REJECT、`docs/design/REVIEW.md`、build 樹實際編進 image 的 kernel 6.6.138 原始碼、firmware 樹 build 腳本、02/04 唯讀探測。

## 結論:**REJECT** — 1 BLOCKER / 7 MAJOR / 9 MINOR

根因與方向我同意,而且查證後是對的:R1/R2/R4/R5 的原始碼證據、datasheet 位元定義、04 現在 CNTL=0x03,我都重新驗過(見文末)。§10 的交叉試驗(關 88 oe / 開 0 oe)是很強的證據。問題在 patch 本身的介面:照 §4 實作的話,kernel 會有一條 NULL 指標路徑(B1);patch 用設計寫的方式帶進 build 會被 build 系統擋下(M1);平台表把 CM4 寫錯(M2);init 握手的「硬性條件」只是推論(M3);測試大多不能分辨修好沒修好(M4、M5)。這些都是改設計文字就能修的,改完請送整份重審。

---

## BLOCKER

### B1 設定 `UPSTAT_AUTORTS` 但驅動沒有 `port->throttle` → `serial8250_throttle()` 會解參考 NULL

**情境**:任何以一般 tty(n_tty)使用 mini UART、而且開了 CRTSCTS 的使用者(bcm2710 image 的 ttyS0、`254-stage1-impl.md:312` 規劃中的 3A+ `miniuart-bt`、未來任何把 GPS/console 放 ttyS0 再 `stty crtscts` 的板子)。只要讀端慢、n_tty 到達高水位,就會呼叫 `uart_throttle()`。

**證據**:
- `serial_core.c:729-755`:`mask` 含 `UPSTAT_AUTORTS`(C_CRTSCTS)→ `if (port->status & mask) port->ops->throttle(port);`
- `8250_port.c:1664-1667`:`serial8250_throttle()` 無條件呼叫 `port->throttle(port);`
- `8250_core.c:1075-1076`:`uart->port.throttle = up->port.throttle;`,無條件複製;`8250_bcm2835aux.c` 沒有設定這兩個欄位(整個 8250 目錄 grep `throttle`:只有 omap、aspeed、bcm7271 有設)→ 值是 NULL。
- 也就是說,§4 第 2 點「UPSTAT_AUTORTS 讓 serial core 的 throttle 改呼叫 ops->throttle(停收 → FIFO 滿 → 硬體 de-assert RTS)」的前提不成立:這個驅動沒有停收的實作。
- 照抄的範本只抄了一半:`8250_omap.c:491` 設 `UPSTAT_AUTORTS`,但同時有 `omap_8250_throttle`(`:1456`);`8250_dwlib.c:98-100` 沒有 throttle,所以只設 `UPSTAT_AUTOCTS`。8250 core 自己的 AFE(`8250_port.c:2834-2838`)也完全不碰 UPSTAT,把 throttle 留給軟體 RTS。
- 藍牙路徑碰不到這條,因為 serdev 不走 ldisc:`serdev-ttyport.c` 裡沒有任何 throttle。所以這個 bug 不會在 T1–T3 出現,只會在設計宣稱「不變」的其他使用者身上變成 oops。

**修法(擇一,建議甲)**:
- 甲:仿 dwlib,**不設 `UPSTAT_AUTORTS`**,只設 `UPSTAT_AUTOCTS`。serial core 的軟體 throttle 照舊清 `TIOCM_RTS` → 走 set_mctrl hook → `update_flow` 關掉 AUTORTS、MCR 讓 RTS de-assert,正好是正確行為(與 CAP_AFE 同模式);unthrottle 時再打開。
- 乙:仿 omap 實作 `throttle`/`unthrottle`(關/開 IER RDI),並說明它和 `skip_rx`(`8250_port.c:1937-1940`)的互動。

**測試**:白箱。在一個以 n_tty 開啟、設了 CRTSCTS 的 mini UART 上讓讀端停住,直到 throttle 觸發,斷言沒有 oops、RTS 確實 de-assert。bcm2711 上的 mini UART 被 BT 佔用,沒有 n_tty 可測,所以至少要在設計中寫明路徑分析,並列為 bcm2710 bench 殘項。

---

## MAJOR

### M1 「OpenWrt kernel patch 由 firmware board patch 帶入」與 build 系統衝突;出貨 image 也證明不了自己帶著 patch

**證據**:
- `scripts/openmanet_setup.sh:147-148`:「patches/<board>/ must only touch feeds/ … a patch of package/ or target/ would be "previously applied" on the second -i and stop setup.」
- `scripts/build-board.sh:75-87`:base tree(`target` 在清單內)有改動就拒絕 build(#275)。
- #275 的 witness(`patch-witness.sh`)只涵蓋 board patch,而且只看 rootfs/manifest。kernel 在 `kernel8.img`(boot FAT,`boards-and-builds.md:10,135`)。結果是 1.5.5-wsl.2 那種「以為帶了其實沒帶」的事故這次沒有任何機制能抓。
- 前例 `999-batman-enable-memcg.patch`(firmware 1f997e71)是直接 commit 在 base tree 的 `target/linux/bcm27xx/patches-6.6/`,而且特別強調「DTS-only → kernel binary 與 vermagic 不變」。這次會改 kernel binary,設計卻沒做這層分析。

**修法**:
1. 改為 firmware base tree commit:`target/linux/bcm27xx/patches-6.6/999-batman-bcm2835aux-auto-flow.patch`。
2. 寫明它會同時編進 bcm2710 與 bcm2712 的 kernel(`bcm2710/config-6.6:425`、`bcm2711/config-6.6:436` 都是 `CONFIG_SERIAL_8250_BCM2835AUX=y`)。
3. 寫明 kernel8.img 會變:vermagic 由 .config 雜湊決定,所以不變;out-of-tree kmod(morse 等)的 ABI 也不受影響,因為只加 static 函式、不改 struct。要附證據:build 後比對 `.vermagic`,並確認 morse 模組載入。
4. 增量 build 要確認 patch 真的落進 `build_dir/.../linux-6.6.138/drivers/tty/serial/8250/8250_bcm2835aux.c`(必要時 `make target/linux/{clean,compile}`),再加一個出貨產物的見證:例如驅動第一次啟用 auto 時印一行固定的 `dev_info`,或提供唯讀的 CNTL 回讀。daily-validation 在節點上斷言這個見證存在。節點上沒有 `/dev/mem`(02/04 已確認),所以不能靠 devmem。

### M2 平台列錯誤:CM4 上 patch 會生效;bcm2710 的未來計畫沒寫

- `distroconfig.txt` 的 `[pi4]` 段落有 `dtoverlay=miniuart-bt`。依 Raspberry Pi config.txt 的條件過濾規則,`[pi4]` 同時套用到 Pi 4B、Pi 400、CM4、CM4S(⚠️ 這是官方文件的語意,我沒有上 CM4 實測)。所以在 O13 落地之前,**量產 CM4 的藍牙同樣走 mini UART,patch 會生效**。§6「mini UART 若無人開 CRTSCTS 則不變」不成立。CM4 模組內 BT 走線與極性未測,要列入 v3.0 前的必測項。
- bcm2710:今天 `[pi3] dtoverlay=disable-bt` → BT 關閉,mini UART 在我們的 image 裡沒有 CRTSCTS 使用者,所以目前無影響(有證據,可寫進表裡)。但 `254-stage1-impl.md:312` 規劃 3A+ 改成 `miniuart-bt`,到時 BCM2837 的極性與 B1 都會碰到。依 `project_cm4_no_pi3` 可以降為殘項,但要寫進 #305 的 checklist。

### M3 §3 的「硬性條件」是推論;AUTOCTS 在 init 第一個命令時的行為沒測過

- 實測只有一種:rebind 時 CNTL 一律 0xcf → `0xfc18 tx timeout`、`Reset failed`。0xfc18 是 serdev `oper_speed` 預設下 setup 前送出的第一個命令,也就是上電後的第一次收發就失敗了。至少有兩種解釋:(a) 設計採用的「AUTORTS 讓上電握手時的手動 RTS 失效」;(b) **AUTOCTS 擋住了主機 TX**,因為控制器剛上電還沒 assert 它的 RTS。
- 設計的狀態機在 `set_flow_control(false)`(`hci_bcm.c:507`)之後就同時開 AUTOCTS 與 AUTORTS,第一個 0xfc18 就是在 AUTOCTS 下送出的。如果 (b) 才是原因,patch 會讓**每次 init 都失敗**。
- 今天的軟體 CTS 不能拿來當「CTS 在 init 時一定是 asserted」的證據。原因:mini UART 沒有 MSI(`UART_BUG_NOMSI`),`hw_stopped` 只在 `uart_change_line_settings()`(`serial_core.c:234-236`)那一刻取樣一次;950-0440 的輪詢只在已經 `hw_stopped` 時才會啟動。所以今天的 TX 實際上幾乎不看 CTS,AUTOCTS 比今天嚴格得多。
- §10 的交叉試驗全程 `port->status` 沒有 UPSTAT_AUTO*,軟體 CTS 也還在。這表示真 patch 會改變的 core 互動都沒被測到:軟體 CTS 關閉、`skip_rx`(`8250_port.c:1937`)、baud 切換時的 set_termios、auto 開著時的 firmware 下載。

**修法**:設計核准前先做唯讀以外的區辨探針(要使用者授權,用同一個調查模組):rebind 時強制 0x8b(只有 AUTOCTS)與 0x47(只有 AUTORTS)各 N 次。結果決定狀態機,例如 AUTOCTS 是否要延到 setup 之後。另外,§3 的寫法要從「原因:」改成「推論 ⚠️」,直到有區辨資料為止。

### M4 測試多數不能分辨修好沒修好

- **T1**:舊 kernel 的 init 失敗率約 1/30,20 次全過的機率是 (29/30)^20 ≈ 0.51。所以「init 失敗消失」這個宣稱沒有負對照。修法二選一:(甲) 找出能抬高舊 kernel 失敗率的誘發方式(例如掃描中重開或 rebind,同時加上 SD 讀取與 CPU 負載,先在舊 kernel 量出基準率,夠高才當判定);(乙) 誠實標成 ⚠️「init 路徑的修正由機制推論」,並保留偵測與恢復來處理 init 失敗(見 m8)。
- **T3**:負對照是「CNTL 一律 0xcf」這個假想的錯誤實作,舊 kernel 跑 T3 也會 PASS。T3 只能算回歸保護,要這樣標示。
- **T4**「待定」不能當測試列。可行版本:用唯讀模式的 r305aux 在 unbind 後(port 關閉)與 init 握手窗口讀 CNTL,斷言 auto 位元不在。這也能抓到 M7 的殘留 AUTOCTS。
- **T2**:負對照不能引用 §10 的舊數據(那是另一套腳本 xo2-*)。必須是 **T2 這支腳本本身**在舊 kernel 上 FAIL。更好的做法是同一 image 翻轉:新 kernel 上用 r305aux `cntl=0x03` 關掉 auto → T2 必須 FAIL → 重開還原。
- T2 只在 04 跑。02 的錯誤率低,但它是另一台硬體,也要跑。

### M5 原始症狀沒有回到驗收裡;回歸測試沒有進 daily-validation

- #305 的標題與本體是 `ble-pair-sc-only-254` 的 LE 連線偶發失敗。`scripts/validation-known-failures.txt:14` 還掛著 `ble-pair-sc-only-254 … 305`,本單 checklist 也寫著「歸因後:回來把 known-failures 那條拿掉」。設計 §8 沒有任何一項重跑這個 suite,也沒寫要移除那條規則。依規則,「Done = 原始症狀消失 + 驗證」。
- 依「每個 fix 的回歸測試進常規全套」與「測項只能有一套(#290)」:T2(或縮短版的 oe 計數 + 探測)與 M1 的見證檢查,要先走 harness PR 進 main,產品 PR 不碰 harness。設計沒有提到。

### M6 升級 / autocommit 列缺:BT 壞掉的 kernel 會被 commit 到整個 fleet

- `feed/batman-provision/files/usr/bin/batman-autocommit` grep `hci|bluetooth|ble` 沒有任何結果。autocommit 只看 mesh,不看 BT。`254-stage1-impl.md:420` 的 `ble-ok` health gate 還沒落地,而且就算落地,它看的 `hci0_powered` 在 UART 卡死時仍然是 1(#305 留言 E6)。
- 情境:極性在某批硬體上不對(CM4、新 HAT 加了電平轉換、M3 的 (b))→ OTA 試用開機 → mesh 正常 → commit → 每台都沒有 BLE。BLE 是 app 找機台的唯一管理面(`254-stage1-impl.md:72`)。
- 修法:生命週期表加「autocommit commit / revert」與「sysupgrade stage 1/2」兩列。明寫風險是接受,還是把 0x1001 探測(走真 UART 的活性訊號)納入 commit 前的健康判定。這正好是恢復機制(§9)裡值得留下的那一半。

### M7 擁有權與契約表不完整,「其他情況與今天完全相同」不成立

1. **RTS(`port->mctrl`)有多個寫者**:serdev client(hci_bcm 經 `hci_ldisc.c:319-321`)、serial core 開啟時 `uart_port_dtr_rts(true)`(`serial_core.c:307-308`)、關閉時 HUPCL 拉低、throttle(B1)、suspend 的 `ops->set_mctrl(uport, 0)`(`serial_core.c:2436`,**不更新 `port->mctrl`**)。設計的 `update_flow` 讀 `port->mctrl`,在 suspend 路徑上會讓 AUTORTS 繼續開著,但 MCR 已經被要求 de-assert,MCR 又被忽略。→ 用 hook 收到的 `mctrl` 參數判斷,不要讀 `port->mctrl`。(Pi 不做 system suspend,所以現場影響小,但契約要對。)
2. **`port->status` 與 serial core 共用**:serial core 在 lock 內改 `UPSTAT_CTS_ENABLE/DCD_ENABLE`(`serial_core.c:222-229`),hook 在 lock 外做 read-modify-write。dwlib 也是這樣寫,目前同一條呼叫鏈內是循序的,但要寫明這個前提。
3. **關閉後殘留**:shutdown 時 HUPCL 讓 RTS 掉下去,所以 AUTORTS 會關;但 `UPSTAT_AUTOCTS` 留在 `port->status`,CNTL 保持 AUTOCTS|CTSINV。下次 open 時,`serial8250_do_startup` → `set_mctrl`(`8250_port.c:2399`)比 `uart_change_line_settings`(`serial_core.c:301`)早,會用殘留的 status 寫 CNTL。再加上 tty termios 跨 open 保留,而且 `ttyport_open` 會設 CRTSCTS(`serdev-ttyport.c` ttyport_open),所以每次 bind 在 `bcm_open` 的 `set_flow_control(true)` 之前,都有一段 0xcf 窗口。這段窗口在控制器上電(`hci_bcm.c:504`)之前結束,所以目前推論無害,但必須寫進生命週期表。修法:在 shutdown 清掉 auto 位元與 UPSTAT_AUTO*。
4. **CNTL 的第二個寫者**:調查用 `r305aux cntl=` 會繞過 `data->cntl` 快取直接寫暫存器。若用在新 kernel(M4 建議的翻轉),快取與硬體會不一致,直到下一次 set_termios/set_mctrl。要列入擁有權表,並寫明用完要重開還原。
5. rs485 callbacks(`:57`、`:81`)也寫同一份 `data->cntl`,在同一把 port lock 下所以沒問題。這點要寫明是靠 lock 成立。

---

## MINOR

- **m1 鎖**:`serial8250_do_set_termios` 已經在 port lock 內呼叫 `serial8250_set_mctrl`(`8250_port.c:2920`),會走到 hook → `update_flow`。所以 set_termios 之後那次顯式的 `update_flow` 是多餘的。如果實作成 `update_flow` 自己拿 lock,從 set_mctrl(已持鎖)呼叫會死鎖。規定 `update_flow` 必須由持鎖者呼叫(`lockdep_assert_held_once`),不要自己拿 lock。
- **m2 rs485 晚開**:先設 CRTSCTS、後用 TIOCSRS485 開 rs485,不會重跑 set_termios;而 rs485 開著時 `serial8250_set_mctrl` 直接 return(`8250_port.c:2061-2062`)。結果 auto 與 rs485 同時開著,違反 `:10-12` 的註解。修法:包一層 `rs485_config`,開啟時清掉 auto。
- **m3 極性是不是通用的**:datasheet 寫 MCR bit1「If set the UART1_RTS line is low」(set = asserted,active-low)、MSR CTS 是「the inverse of the UART1_CTS input」、CNTL bit 6/7 reset 值 = 「assert level high」。所以對標準 active-low 的對端,INV 本來就是正確設定,不是這塊板子特有的。把這段推理寫進 §3,實測當確認用。只有中間加了反相電平轉換的 HAT 才會不同(HAT v2 要檢查)。
- **m4 用詞**:§3 / §10 的「0xcc」實際寫入的是 0xcf(`r305aux.c` 會 `| 0x3`),請統一,免得誤以為 RX/TX 被關掉。
- **m5 安全段補充**:✅ 節點上沒有 `/dev/ttyS0`(02/04 `ls` 確認),非 root 碰不到這個 port。要補兩個 actor:(1) 遠端攻擊者讓控制器韌體當掉並卡住它的 RTS → AUTOCTS 會在 FIFO 中途擋住 TX(今天的軟體 CTS 幾乎不擋,見 M3),症狀與恢復需求和今天的卡死相同;(2) 我們自己的錯誤:極性錯會讓整個 fleet 失去唯一的管理面。這是 fail-secure,但對可用性是 fail-closed,要和 M6 一起處理。
- **m6 T2 的 1 MB 下限**:舊 kernel 段平均約 1.03 MB / 30 分(3.1 MB / 3),離門檻太近。改用速率門檻(例如 ≥ 500 B/s 持續),另外要求「掃描真的在跑(adv report 計數增加)」和「M1 的見證顯示 auto 已開」。
- **m7 破壞性測試的副作用**:T1 重開 20 次會把關機紀錄擠掉(只留 10 份,#305 前次就先整份備份 `/opt/batdata/log`);T3 rebind 會清掉 provd 的廣播 / GATT,而且有 socket 綁著時 hci index 會變(舊審查 B-M1、B-M2)。要列出每個碰到的資源與還原方式,並在啟動前驗證。
- **m8 恢復機制(§9)**:給一個明確的判準,寫進 #305 的 checklist,不要開新單。我建議至少保留「走真 UART 的 0x1001 探測」當偵測訊號,因為現有 health 在卡死時會說謊。理由有三:init 路徑的修正目前沒有負對照(M4)、0xfc18 誘發的卡死與溢位無關、autocommit 需要一個不會說謊的 BT 訊號(M6)。
- **m9 生命週期表缺的列**:
  - 正常關機:bcm_close 斷電 → HUPCL → AUTORTS 關,AUTOCTS 殘留(M7-3)。
  - 斷電:等同開機。
  - sysupgrade stage 1/2:kernel 到重開才換。
  - bluetoothd restart / hci power off:port 不關,因為 bcm 沒有 `HCI_QUIRK_NON_PERSISTENT_SETUP`(`hci_serdev.c:150-157`)。
  - runtime PM N/A:有證據,02/04 的 `serial0-0/power/runtime_status = unsupported`,DT 沒有 host-wake irq,所以 `bcm_suspend_device` / `bcm_resume_device`(`hci_bcm.c:762-812`)不會跑;就算跑,它也是走 `set_flow_control(true/false)`,與設計一致。
  - system suspend N/A。
  - earlycon / console N/A:cmdline 沒有 earlycon,`console=ttyAMA0`;`early_bcm2835aux_setup` 不走驅動 ops。
  - kernel oops / crash loop:B1。

---

## 我查證過、成立的部分(✅ 附證據)

- R1:`8250_bcm2835aux.c:10-12, 27-28, 117`,CNTL 只在 rs485 路徑(`:57/:81`)寫入。R2:`:102` capabilities 沒有 AFE。
- R3:04 現在 `r305aux before: MCR=0x02 CNTL=0x03 STAT=0x0000030e`(dmesg [44295.846754],只讀,沒帶參數)。02 上沒有 r305aux.ko,沒跑。
- R4:`hci_bcm.c:489-507`(`bcm_open`)、`:1586-1587, 1606`;兩台 DT BT 都是 `brcm,bcm43438-bt`(mini UART 下 `status=okay`,PL011 下 `disabled`)。`hci_ldisc.c:319-322` 的 serdev 路徑確認。
- `ttyport_open` 會設 CRTSCTS。`serdev-ttyport.c` 沒有 throttle,所以藍牙路徑不受 B1 影響。
- hook 會被複製:`8250_core.c` 的 `set_termios` / `set_mctrl`(register_8250_port 內的 `if (up->port.xxx)` 段)。
- pinmux:`uart1_bt_pins` = GPIO 32/33/30/31 alt5,其中 GPIO30(CTS)上拉。所以控制器沒上電時 CTS 是 de-asserted,AUTOCTS 會擋 TX,這是合理的行為。
- `uart_wait_until_sent` 把等待時間限制在 2 × FIFO timeout(`serial_core.c:1857-1858`)。所以 rebind 時就算 AUTOCTS 擋住 FIFO,close 也不會卡 30 s。
- 平台:`[pi3] disable-bt`、`[pi4] miniuart-bt` + `core_freq_min=500`(distroconfig.txt);kernel 在各 slot 的 boot FAT(`boards-and-builds.md:10, 135`),rollback = 舊 kernel,這點成立。

## 判定:**REJECT**

B1 必須修,而且修法很小(只設 UPSTAT_AUTOCTS)。M1、M2、M6、M7 是改設計文字與 build 方式。M3 需要一次區辨實驗(要使用者授權)。M4、M5 是測試計畫重寫。改完請送整份重審。
