# #305 mini UART 硬體流量控制設計 v4 + P1/P2 patch — 對抗式審查 A(第 4 輪,整份重審)

## 結論:**APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 9 MINOR**

第 3 輪的兩個 MAJOR 都關了(見下方核對)。P2 在所有 `bcm_close` 呼叫點都安全(可睡眠、tty/serdev 有效、沒有新的鎖順序),它的效果和 `spike2.log` 逐筆對得上。剩下的都是 MINOR:測項的分辨力、過渡期,以及 P2 的影響範圍(blast radius)。這些不會改變設計,可以在 harness PR / 產品 PR 裡一起修。**實作計畫(先 harness PR,再產品 PR,版號 1.5.13)可以開始**,條件是 m1、m2、m3 在 harness PR 凍結測項之前修完。

審查範圍:整份 v4 文件;`999-batman-bcm2835aux-autoflow-305.patch`(c002892b)與 `.v1.patch`(86e8f027)的差異;`999-batman-hci_bcm-close-flow-305.patch`(73ee8d01);build_dir 內的 6.6.138 原始碼;`spike2.log`、`closewait3.log`、兩份 `soak16-*.log`、`ota17-04.log`、`restore15*.log`;以及 04/02 的唯讀狀態(sysfs、`/proc/tty/driver/serial`、DT、`/opt/batdata/log`)。節點上沒有做任何寫入。

---

## 第 3 輪 MAJOR 結案核對

| 第 3 輪 | 狀態 | 證據 |
|---|---|---|
| A-M1 / B-M1:close 120 ms 是假象,T3b 沒有分辨力 | ✅ 關閉 | 改採 P2 根解。`spike2.log` 第 9–10 行:`CNTL=0xcd … cts_line=0 tx_fill=4` → `STUCK-TX unbind took 120 ms; … writes=20 … CNTL=0x03 … tx_fill=0`(unbind 只多了 1 筆寫入 = P2 的 0x03)。負對照 `closewait3.log`:舊 kernel `CNTL=0x01 tx_fill=4` → `unbind with TXEN off took 30140 ms`。T3b 已改成 0xcd 注入 |
| A-M2:T5 用 `uname -v`;rollback 斷言會長期紅燈 | ✅ 關閉(有小尾巴,見 m4) | 改成依 slot 的 `BATMAN_VERSION` 推預期值。唯讀確認 02/04 的 `uname -a` 都是 `#0 SMP Mon Jun 23 20:40:36 2025`,不能當分辨依據 |

第 3 輪 MINOR m1–m10 的對照(§12)我逐條看過,都已處理。

---

## P2 逐項查證(你指定的重點)

**呼叫點與執行環境**(`hci_bcm.c` 已打 P2 的 build_dir 版本,P2 在 `:560`):

| 呼叫點 | 環境 | `hu->tty` / `hu->serdev` | 可睡眠 | 判定 |
|---|---|---|---|---|
| `hci_serdev.c:406` `hci_uart_unregister_device`(rebind / rmmod / serdev remove) | process context;`proto->close` 在 `serdev_device_close`(`:410`)**之前** | serdev 仍開著 | 是 | ✅ fleet 唯一實際路徑 |
| `hci_serdev.c:386` register 失敗的 err path | probe context,serdev 已開(`err_open` 在後) | 有效 | 是 | ✅ |
| `hci_ldisc.c:557` `hci_uart_tty_close` | ldisc close,持 ldisc 寫鎖;`tty_set_termios` 內部的 `tty_ldisc_ref` 是 trylock,拿不到時回 NULL,不會死鎖;`termios_rwsem` 沒被持有 | `hu->tty` 有效 | 是 | ✅(只影響非 serdev 使用者,見 m6) |
| `hci_ldisc.c:198` `hci_uart_init_work` 失敗 | workqueue | 有效;但與 tty close 之間有上游既有的 race(先清 `PROTO_READY` 再 close,`tty_close` 因此不會 `cancel_work_sync`)。P2 在這個窗口裡多碰了 tty | 是 | ⚠️ 上游既有問題,只影響 ldisc(m6) |
| `hci_ldisc.c:692` `hci_uart_register_dev` 失敗(ioctl) | process context | 有效 | 是 | ✅ |

- **鎖**:`bcm_close` 持有 `bcm_device_lock`(mutex)。`bcm_open` 本來就在同一個 mutex 下呼叫 `hci_uart_set_flow_control`(`:489/491/507`),所以沒有新的鎖順序。serdev 路徑是 `ttyport_set_flow_control` → `tty_set_termios` → `uart_set_termios`(port mutex)→ P1 hook(port spinlock),全都可以睡眠,呼叫端也沒有持 spinlock。
- **runtime PM**:P2 放在 `irq_acquired` 分支之後,也就是 `pm_runtime_disable` 之後。`bcm_suspend_device`(`:778`)也做同一個呼叫,重複呼叫是冪等的。Pi 的 DT 只有 `shutdown-gpios`,沒有 host-wakeup(唯讀確認 04 的 bluetooth 節點屬性),所以 `irq_acquired` = false,這條路徑 N/A。
- **其他板子**:bcm2710 的 `.config` 是 `# CONFIG_BT_HCIUART_BCM is not set`(唯讀確認),P2 不會被編進去。bcm2711 是 `CONFIG_BT_HCIUART_BCM=y`,沒有 `PROVE_LOCKING`。
- **上游前例**:`hci_qca.c:1400/1408` 在送 power pulse 時,也用 `hci_uart_set_flow_control(hu, true)` 關掉流量控制。

**P2 的效果是否就是 spike2 顯示的那樣**:是。
- `hci_uart_set_flow_control(hu, true)` 的 serdev 分支(`hci_ldisc.c:319-321`)是 `set_flow_control(false)` 加 `set_rts(false)`。
- 第一步走 set_termios hook:`crtscts=false` → `cntl = 0xcf & ~FLOW = 0x03` ≠ 快取 → 寫入,而且 TXEN 也從快取一起回寫。`uart_change_line_settings` 清掉 `UPSTAT_CTS_ENABLE` → `uart_wait_until_sent` 的 `!uart_cts_enabled` 分支重新生效,上限是 2 × FIFO timeout(`serial_core.c:1847-1858`,已讀)。
- 第二步 `set_rts(false)` 時 `crtscts` 已經是 false,所以快取不變,不會多寫。
- 和 `spike2.log` 的 unbind `writes 4→5`、`last=…,0x03` 一致;stuck 情況下是 `19→20`。
- rebind 的 bind 序列 `0xcf,0x03,0x8b,0xcf` 也和 `ttyport_open`(`serdev-ttyport.c:122` 先 open,`:136` 才設 CRTSCTS)加上 `bcm_open` 的三次呼叫推出來的完全吻合。關閉時存下的 termios 沒有 CRTSCTS(`tty_save_termios`),所以 `uart_startup` 那一步沒有寫入。

**0xcd 注入是否忠實代表現場**:部分忠實,見 m5。注入測到的是「P2 讓 CNTL 在 wait 之前回寫成 0x03」這條程式路徑,這和現場相同。現場額外依賴一個硬體語意:AUTOCTS = 0 時,發送端完全不看 CTS 線。這點只有手冊依據,注入沒有直接測到。

---

## MINOR

**m1 T1 分不出 spike 的 P1 v1 和產品的 P1 v4;§9 的「build_dir 帶著 patch」檢查也分不出來**
- 情境:build_dir 現在放的是 v1(spike2)的原始碼。v1 和 v4 的 `hw=0xcf cache=0xcf` 輸出完全一樣。
- 證據:
  - 我在 copy 上 `patch -R` v1 + P2,得到 pristine,v4 + P2 都能乾淨套上(dry-run OK)。
  - `include/kernel-build.mk:13` 的 `STAMP_PREPARED` 含 patch 目錄的 md5;目前的 stamp 是 `.prepared_edc6cf90…`。所以 patch 換了就會重新 prepare,殘留風險低,但 §9 的檢查本身沒有分辨力。
- 修法:
  - T1 加斷言 `stat -c %a …/autoflow` = `400`(v1 是 0444)。
  - §9 的 build_dir 檢查改成比對內容,例如 `grep -q 'dev_groups = bcm2835aux_groups'`,或比對 patch 後檔案的 sha,不要只看「有沒有 patch」。

**m2 過渡期:T2 在 wsl.15 上沒有被短路,也沒有 known-failure 條目**
- 情境:harness PR 進 main 之後、產品出貨之前,任何一次 `--destructive` 全套都會在 wsl.15 上跑 T2:60 分鐘以上的負載。
  - 結果是 NEW FAIL,而且依 §10a,約每 30 分鐘就有卡死。
  - 節點要走 rebind / reboot 還原,浪費時間和機台,也把「已知紅燈」變成 NEW。
- 修法:T2 和 T3/T5 一樣,`autoflow` 不存在時立即 FAIL,不施加負載;known-failures 加一條。真正要跑的負對照,用一個明確的 `--negative-control` 旗標手動跑一次。

**m3 `adv-fast` 會改到 #254 BLE 套件共用的 `ble-periph-254.sh`**
- 依「測項只能有一套」,harness PR 要在 PR body 附上 BLE tier A/B 現有套件仍然 PASS 的紀錄,證明新增指令沒有改變既有指令的行為(lease / deadman / `release` 路徑,`ble-periph-254.sh:5,174,191`)。

**m4 T5 的版本比較要寫清楚 prerelease 怎麼處理**
- 依 SemVer,`1.5.13-wsl.1` < `1.5.13`。照字面「版本 ≥ 產品版號」實作,產品 rc 會被判成「應該沒有 autoflow」→ FAIL。
- 修法:寫明只比較 `MAJOR.MINOR.PATCH` 三段,忽略 `-channel.N` 和 `+meta`。另外寫明 `1.5.12-wsl.16/17`(退役號碼,帶 patch)出現在任一 slot 都判 FAIL,不是 PASS。

**m5 0xcd 注入的模型邊界要寫進 §3 / T3b**
- 現場:控制器斷電或卡死時,RTS de-assert,AUTOCTS 擋住 TX。P2 的 0x03 解開它,靠的是 AUTOCTS = 0 時發送端不看 CTS。
- 注入:TXEN = 0,P2 的 0x03 靠快取把 TXEN 回寫成 1。兩者走同一筆 CNTL 寫入、同一個時間點(wait 之前),但解開的位元不同。
- 「AUTOCTS = 0 時不看 CTS」目前只有手冊(Table 13)支持。
- 修法:§3 標 ⚠️ 手冊依據。
  - 若想補實測:舊 kernel 上用 `r305raw cntl=0x0b`(AUTOCTS + 預設極性;控制器上電時 `cts_line=0` 會被當成 de-asserted)讓 `tx_fill>0`,再寫 0x03,確認 `tx_fill→0` 而且 `cts_line` 仍是 0。只要一次,不在每個 rc 跑。
- 另外,P2 的負對照(舊 kernel 30140 ms)和 P2 之間差了兩個變數(P1 和 P2)。依原始碼,P1 在 close 的 wait 之前沒有任何寫入:`ttyport_close` → `tty_port_close_start` → wait,之後才 shutdown / HUPCL。這段論證請引原始碼寫進 §3,代替「推論也是 30 s」一句。

**m6 P2 不分條件執行,而 `bcm_open` 的對應動作有條件**
- `bcm_open` 只在 `use_autobaud_mode` 或 `drive_rts_on_open` 時動流量控制(`:488-491`)。P2 對所有 hci_bcm 裝置都動,包括 ldisc / ACPI 使用者。
- ldisc 分支(`hci_ldisc.c:325-345`)的 `enable=true` 會把 DTR、RTS、OUT1、OUT2、LOOP 全部清掉(`set=0` → `clear=~0`)。tty 若在 ldisc 換回 N_TTY 後繼續被使用,狀態會被改掉。
- fleet 沒有這類使用者,但 patch 註解寫「Mirrors bcm_open()」並不精確。
- 修法(擇一):
  - 加 `if (bdev->drive_rts_on_open || bdev->use_autobaud_mode)` 和 `bcm_open` 對稱,或 `if (hu->serdev)`;
  - 或在標頭寫明影響範圍:「所有 hci_bcm 使用者;ldisc 分支會清 DTR / OUT2」。
- 我傾向前者:只在驗證過的路徑上改行為。

**m7 §6「斷電 / watchdog reset → CNTL 回 reset 值 ⚠️ 推論」其實有實機證據,降版那一列可以引用**
- `soak16-20261024-180526.log` 第 9 行:spike1 在 CNTL = 0xcf 時被 autocommit 退回,舊 kernel 開機後是 `up=30 … tx:65595 rx:4349`。
  - 這和 04 現在 wsl.15 開機後 `/proc/tty/driver/serial` 的 `tx:65595 rx:4349` 一樣,代表 patchram 下載完成。
  - 如果 CNTL 跨重開留在 0xcf,舊 kernel 的 init 會 100% 失敗(xo-comment:0xcf rebind → `Reset failed`)。
- 這對「降版到沒有 patch 的版本」很重要,請把它寫成 ✅ 證據。
- 「冷斷電」仍然是 ⚠️:SoC 冷重置的語意更強,風險低。

**m8 運行中卡死:P1 之後的軟恢復路徑改變了,§6 / §11 要寫明**
- 舊 kernel(0x03)在卡死時,主機還在送資料:`xo2-…131635.log:7-8`,tx 297253 → 297293。
- P1 之後,如果卡死的控制器 RTS 一直 de-asserted,主機的 HCI 指令(包括 `hci down/up` 時的 HCI_Reset)完全送不出去。這時只有 rebind(P2 + 斷電)能恢復。
- 卡死時控制器的 RTS 狀態沒有紀錄:`recover:` 那行是恢復後才讀的。
- 修法:§6 加一列「運行中卡死(P1 沒處理的 `buf_overrun` 等)」:軟恢復可能無效,恢復機制要用 rebind;時間預算依 P2 = 120 ms + init。§11 重啟恢復設計時,把它當成前提。

**m9 產品 rc 的驗收清單要明列「v4 sysfs 註冊路徑」**
- v4 改用 `dev_groups`,屬性在 probe 成功**之後**才由 driver core 建立,remove 時先移除。這和 `autoflow_show` 依賴 `data->line` 正好相容,但 v4 從沒開機過。
- §8 第 3 點已經要求產品 rc 重跑 T1/T2/T3/T3b,這點足夠。另外請加一次唯讀檢查:非 root 讀取應該失敗。例如在 rc 上 `su nobody -s /bin/sh -c 'cat …/autoflow'` 必須回 Permission denied,作為 §7 的負對照(0400 的宣稱目前沒有測項)。

---

## 生命週期 / 資源補查(先找缺漏)

| 路徑 / 資源 | 判定 |
|---|---|
| 首次開機、開機、rebind、hci_uart 模組 rmmod/modprobe、bluetoothd restart、OTA stage、rollback | v4 已涵蓋,有證據 |
| 降版到沒有 patch 的版本 | 有證據(m7,文件要升級成 ✅) |
| 運行中卡死後的恢復 | 缺(m8) |
| 平台驅動 unbind 後 hook 懸空 | 已寫明 root-only 已知限制,接受 |
| probe 期間 serdev 子裝置同步 probe | 查證:`platform_set_drvdata` 在 `serial8250_register_8250_port` 之前。hook 若在 register 期間被呼叫,拿得到 drvdata;之後 probe 再把快取寫回硬體,兩者一致。✅ |
| build_dir 殘留 spike 原始碼 | stamp 含 patch md5,會重新 prepare;但檢查方式要能分辨(m1) |
| 過渡期全套 | T2 缺(m2) |
| bcm2710 / bcm2712 | P1 編進 bcm2710(`SERIAL_8250_BCM2835AUX=y`),沒有使用者;P2 不會被編進去。✅ |
| CM4 | ⚠️ v3.0 前實測,已列殘項,接受 |

## 安全(逐 actor)

- **遠端(BLE 範圍內)**:同意 ⚠️ 預期改善。補充 m8:卡死時的恢復手段只剩 rebind。
- **本機非 root / 受入侵的容器**:sysfs 改 0400,攻擊面縮小。缺負向測試(m9)。沒有其他新輸入。
- **受入侵的同層元件(bluetoothd / provd)**:能做的只有 mgmt / HCI,碰不到 termios。T3 的 rebind 會打斷它的廣播,已寫明。
- **root / 我們自己的錯**:鎖內不 printk。`r305raw` 進 harness 不進 image,root 本來就能 insmod,不是新的權限。最大的風險是「閘門錯 → BLE 全失」,而 autocommit 擋不住;唯一的閘門是 T1/T3 + 全套,已寫明。
- **供應鏈**:兩個 downstream patch,標頭寫了 kernel 版本與 rebase 責任。P2 的影響範圍見 m6。
- **秘密**:沒有新增。

## 計畫能否開工

可以。順序:
1. 修 m1–m4,寫進 v4.1,不需要再審整份(都是測項規格);
2. harness PR(含 m3 的 BLE 回歸紀錄);
3. 產品 PR(P2 視 m6 決定是否加條件;若改了 P2,sha 會變,產品 rc 要重跑 T3/T3b,§8 第 3 點已經涵蓋);
4. 1.5.13 rc 的驗收照 §8,另加 m9。

m5–m8 是文件與證據的補強,可以和 harness PR 同時做。

## 判定:**APPROVE-WITH-CHANGES**(0 / 0 / 9)
