# #305 根治:mini UART 硬體流量控制(兩個 kernel patch)— 設計 v7(核准)

**狀態**:v7 = v6 + 第 6 輪 MINOR(§8a)。**第 6 輪兩位都 APPROVE-WITH-CHANGES(A 0 / 0 / 11,B 0 / 0 / 10)**,依使用者「沒 MAJOR 就實作」進入實作;兩位都表示不需要再整份重審,MINOR 由 harness PR 的逐條翻轉輸出驗收。

| 版本 | 審查 A | 審查 B |
|---|---|---|
| v6 | APPROVE-WITH-CHANGES(0 / 0 / 11) | APPROVE-WITH-CHANGES(0 / 0 / 10) |
| v5 | REJECT(0 / 2 / 8;M1 標記短路讓負對照變空、M2 SD 負載是 page cache) | REJECT(0 / 1 / 8;M1 同 A) |
| v4 | APPROVE-WITH-CHANGES(0 / 0 / 9) | REJECT(0 / 1 / 10;唯一 MAJOR 在 T2 的負載設計) |
| v3 | REJECT(0 / 2 / 10) | REJECT(0 / 1 / 10) |
| v2 | REJECT(0 / 3 / 8) | REJECT(1 / 5 / 8) |
| v1 | REJECT(1 / 7 / 9) | REJECT(1 / 6 / 9) |

報告在 `h305/review-flow-v{1,2,3,4}-{A,B}.md`。對照表:v4 → v5 在 §12a,v3 → v4 在 §12。兩位第 4 輪都表示兩個 patch 的程式可以凍結。

**使用者決定**(2026-10-24):
- 選「A kernel patch」,不做序列埠對調。
- spike 只上 04。
- 關閉會等 30 s 的問題做根解,也就是 patch hci_bcm。
- 恢復機制暫停,重啟的判準在 §11。

**兩個 patch**(都放在 firmware base tree 的 `target/linux/bcm27xx/patches-6.6/`):

| patch | 內容 | sha256 前 16 碼 |
|---|---|---|
| P1 `999-batman-bcm2835aux-autoflow-305.patch` | mini UART 驅動依 CRTSCTS / RTS 開關 AUTOCTS / AUTORTS;唯讀 sysfs 見證 | `c002892b…`(v4:sysfs 改 0400 + `dev_groups`)。spike 跑的是 `86e8f027…`,只差 sysfs 屬性的權限與註冊方式 |
| P2 `999-batman-hci_bcm-close-flow-305.patch` | `bcm_close()` 斷電前先 `hci_uart_set_flow_control(hu, true)`,**只在 serdev 路徑**(v5,B v4 m3) | `60e0cdc7…`。spike2 跑的是不分條件的 `73ee8d01…`;Pi 上一律走 serdev,所以行為相同 |

兩個 patch 都由 `scratchpad/r305/kpatch/edit*.py` 從原始碼產生,`-Werror` 編譯通過。

**spike**(本機分支 `spike/305-autoflow`,不推、不出貨;04 已回到 wsl.15 S0):

| spike | 版本 | 分支 commit | 內容 |
|---|---|---|---|
| spike1 | `1.5.12-wsl.16+0328e83.fw299d66e` | 299d66e6 | P1 v1 |
| spike2 | `1.5.12-wsl.17+0328e83.fw31e6504` | 31e6504c | P1 v1 + P2 |

**基準**:Batman `main` a62bf78、firmware `build-3aplus` 72814fa4、kernel 6.6.138、fleet wsl.15。

## 1. 問題與範圍

開發用 WM1302 HAT 的 GPS 佔 PL011,藍牙(BCM4345C0,DT `brcm,bcm43438-bt`)走 mini UART(`[pi4] dtoverlay=miniuart-bt`)。mini UART 接收溢位會讓 H4 失去同步,接著運行中卡死或開機 init 失敗。機台因此不廣播,app 找不到它。

**範圍聲明**
- **修的是什麼**:主機中斷延遲超過 8 字元 FIFO 撐得住的時間,所造成的運行中溢位。翻轉證據:舊 kernel 在 §10a,真 patch 在 §10b。
- **開機 init 失敗**:同一機制(init 時 `rx:22 oe:1`),但沒有能分辨好壞的測試(舊 kernel 約 1/30)。→ 只宣稱 ⚠️「機制相同、預期改善」。
- **硬體 RTS 只解決中斷延遲。** serdev 沒有 ldisc、不會 throttle;flip buffer 滿時是軟體層丟資料(`buf_overrun`),本 patch 不處理。
- **⚠️ 持續背壓沒有測過。** §10 的負載約 1.1 KB/s,約為 230400 baud(≈23 KB/s)的 5%。
- **平台**:`[pi4]` 也套用到 CM4 / CM4S(⚠️ 官方文件語意,未上 CM4 實測)。
  - O13(HAT v2 藍牙回 PL011)定案前,量產 CM4 也依賴這兩個 patch。
  - O13 定案後:P1 在沒有 CRTSCTS 使用者時行為不變;P2 讓 PL011 上的 close 也不會因 CTS 卡住。兩者都留著無害。
  - CM4 實測列為 v3.0 前必測(§11)。

## 2. 根因(證據)

| # | 事實 | 證據 |
|---|---|---|
| R1 | 驅動從未開晶片的自動流量控制 | `8250_bcm2835aux.c:10-12`;`:117` `cntl = RXEN \| TXEN`;CNTL 只在 rs485 路徑寫(`:57`、`:81`) |
| R2 | 8250 core 也不會補開 | `:102` 沒有 `UART_CAP_AFE` → `8250_port.c:2834-2838` 不動作 |
| R3 | 實機 CNTL = 0x03、MCR = 0x02 | 04 調查模組唯讀,兩位審查各自讀過 |
| R4 | 藍牙驅動要求 CRTSCTS,並在上電時手動拉低 RTS | `hci_bcm.c:1586-1587` `drive_rts_on_open`;`bcm_open` `:489`(autobaud 分支)/ `:491` → `:504` → `:507`(原始樹行號);`hci_ldisc.c:319-321` 先 `set_flow_control` 再 `set_rts`;`ttyport_open` 設 CRTSCTS(`serdev-ttyport.c:136`) |
| R5 | FIFO 8 bytes、無 DMA | `:107`;手冊 §2.2 |
| R6 | 溢位與每次出錯同時出現;PL011 上 0 次 | #305 留言 6373948374、6378385476 |

## 3. 硬體事實(手冊 + 實測)

**CNTL 位元**(BCM2711 ARM Peripherals RP-008248-DS-1 §2.2.2 Table 13 `AUX_MU_CNTL_REG`):
- bit 0 RXEN、bit 1 TXEN;
- bit 2 AUTORTS、bit 3 AUTOCTS;
- bit 5:4 RTS level,00 = FIFO 剩 3 格時 de-assert;
- bit 6 / 7 是 RTS / CTS 的 assert level,reset 值都是 active-high。

MCR bit 1「If set the UART1_RTS line is low」= active-low;對端也是標準 active-low,所以 `RTSINV | CTSINV` 是標準介面的正確設定。

**極性實測**(舊 kernel,調查模組直接寫 CNTL):

| CNTL | 意義 | 結果 |
|---|---|---|
| 0x07 | AUTORTS,預設極性 | 3/3 失敗 |
| 0x47 | AUTORTS + RTSINV | 5/5 成功 |
| 0x4f | AUTOCTS,預設極性 | 3/3 失敗 |
| 0xcf | 兩者都設 INV | 3/3 成功 |

**init 區辨**(舊 kernel,rebind 時強制 CNTL;`disc.log`):

| 強制值 | 結果 |
|---|---|
| 0x8b(只有 AUTOCTS) | 3/3 成功;patchram 也在硬體 CTS 下送完 |
| 0x47(只有 AUTORTS) | 3/3 失敗 |

這只證明「整段 init 都開 AUTORTS 會失敗」。真 patch 的閘門是否足夠,由 §10b 的 init 結果與 T3 判定。

**close 時間(v4 更正)**

原始碼:
- serdev 一律開 CRTSCTS,所以 `uart_wait_until_sent` 的「2 × FIFO timeout」clamp 不生效(`serial_core.c:1846-1858`)。
- 上限因此是 `closing_wait` = 30 s(`tty_port.c:100`、`:654-655`)。

卸載順序:
1. `bcm_close` 先讓控制器斷電(`hci_bcm.c:554`);
2. 才 `serdev_device_close`(`hci_serdev.c:406-410`);
3. 斷電後 CTS 線 = 1(`closewait.log`、`disc.log`:每次 unbind 後都是 `cts_line=1`)。

正確極性下,1 = de-asserted,所以 TX FIFO 的殘留送不出去。

| kernel | 注入 | `tx_fill` | unbind | 紀錄 |
|---|---|---|---|---|
| 舊 kernel | CNTL 0x01(TXEN 關) | 4 | **30140 ms** | `closewait3.log` |
| 舊 kernel | CNTL 0x4f(CTS 預設極性) | 4 | 120 ms | `closewait.log` |
| spike1(P1) | 0x4f | 4 | 120 ms | `spike-b.log` |
| spike2(P1 + P2) | 0xcd(AUTO* + RXEN,TXEN 關) | 4 | **120 ms** | `spike2.log` |

- 0x4f 那兩行**不是有效的測試**:斷電後 CTS = 1,在預設極性下 1 = 放行,FIFO 自己送光了。v3 根據它說「不會卡 30 s」,是錯的(兩位第 3 輪都指出)。
- **P2 是根解**:CRTSCTS 在斷電前就關掉,有三個效果:
  - P1 hook 關掉 AUTOCTS / AUTORTS;
  - CNTL 依快取重寫,TXEN 回到 1;
  - `uart_wait_until_sent` 回到 clamp。
- 「只有 P1、沒有 P2」在 0xcd 注入下沒有實測,原始碼論證如下(A v4 m5):
  - unbind 時 `bcm_close` 不碰 termios,所以 CRTSCTS 保持開著,`UPSTAT_CTS_ENABLE` 也在;
  - `serdev_device_close` → `uart_close` → `tty_port_close_start` → `tty_wait_until_sent(closing_wait)`(`tty_port.c:654-655`);
  - CTS 已啟用,所以不 clamp(`serial_core.c:1846-1858`);
  - P1 的 shutdown hook 在 `uart_shutdown` 才會執行,而它在等待之後。
  → TXEN 一直是 0,會等滿 30 s。T3b 用「不含 P2 的 `hci_uart.ko`」補上真負對照(§8)。
- ⚠️ 現場的情境是「AUTOCTS 開、控制器斷電使 CTS de-assert」,P2 靠的是「AUTOCTS = 0 時傳送端不看 CTS」(手冊 Table 13 bit 3:「If this bit is clear the transmitter will ignore the status of the CTS line」)。0xcd 注入驗的是「CNTL 依快取重寫、TXEN 回來」,兩者不完全相同。一次性補測:rc 上以 `r305raw` 設 0x8b,讓控制器斷電後 CTS de-assert,再 unbind 計時。

## 4. 設計

### P1 `8250_bcm2835aux.c`

加 `set_termios`、`set_mctrl`、`shutdown`、`rs485_config` 四個 hook。`8250_core.c:1077,1103-1121` 註冊時會複製這四個指標。

```c
struct bcm2835aux_data { ...; u32 cntl; bool crtscts; u8 hist[8]; unsigned int nhist; };

/* 呼叫者持 port lock;mctrl = 這次要設的值;rs485 = 這次生效的 rs485 狀態 */
static void bcm2835aux_update_flow(up, mctrl, rs485)
{
	cntl = data->cntl & ~FLOW_MASK;              /* AUTORTS|AUTOCTS|RTS4|RTSINV|CTSINV */
	on = data->crtscts && !rs485;
	if (on)                        cntl |= AUTOCTS | CTSINV;
	if (on && (mctrl & TIOCM_RTS)) cntl |= AUTORTS | RTSINV;      /* level 00 */
	if (cntl != data->cntl) { data->cntl = cntl; serial_out(CNTL, cntl); hist[nhist++ % 8] = cntl; }
	/* 鎖內不 printk */
}
set_mctrl(port, mctrl):    serial8250_do_set_mctrl(port, mctrl); update_flow(up, mctrl, port->rs485 enabled);
set_termios(port, t, old): lock{ crtscts = CRTSCTS; status &= ~UPSTAT_AUTOCTS; if (crtscts && !rs485) status |= UPSTAT_AUTOCTS; }
                           serial8250_do_set_termios(port, t, old);
                           lock{ update_flow(up, port->mctrl, rs485) }
shutdown(port):            serial8250_do_shutdown(port); lock{ crtscts = false; status &= ~UPSTAT_AUTOCTS; update_flow(up, 0, false) }
rs485_config(port, t, rs485):            /* 兩個呼叫點都已持鎖(serial_core.c:1458、:1507) */
                           ret = serial8250_em485_config(...); if (ret) return ret;
                           on = rs485->flags & ENABLED;        /* 用參數:port->rs485 要等回呼返回才更新 */
                           status &= ~UPSTAT_AUTOCTS; if (crtscts && !on) status |= UPSTAT_AUTOCTS;
                           update_flow(up, port->mctrl, on);
probe(註冊後):            lock{ serial_out(CNTL, data->cntl) }     /* 快取 = 硬體 */
sysfs autoflow:            DEVICE_ATTR_ADMIN_RO(0400),經 platform_driver.driver.dev_groups 註冊;
                           "hw=0x.. cache=0x.. writes=N last=a,b,..."
```

- **不設 `UPSTAT_AUTORTS`**:驅動沒有 `port->throttle`(`8250_port.c:1664-1667` 無條件呼叫;`8250_core.c:1075` 複製到 NULL)。
  - throttle 因此走 `uart_clear_mctrl(TIOCM_RTS)`(`serial_core.c:748-749`)→ `set_mctrl` hook → AUTORTS 關 → MCR 讓 RTS de-assert。
  - 和 `8250_dwlib.c:95-100` 同一做法。
- **持鎖證據**:所有 `set_mctrl` 呼叫點都持 port lock(A v3 逐一列出)。`lockdep_assert_held_once` 在出貨設定(沒有 `PROVE_LOCKING`)下會被編掉,不當證據。

### P2 `hci_bcm.c` `bcm_close()`

```c
	if (bdev) {
		...
		hci_uart_set_flow_control(hu, true);   /* #305: 斷電前先關 CRTSCTS(並拉低 RTS),和 bcm_open() 對稱 */
		err = bcm_gpio_set_power(bdev, false);
```

`hci_uart_set_flow_control(hu, true)` 的 serdev 路徑(`hci_ldisc.c:319-321`)會做兩件事:
- `set_flow_control(false)`:CRTSCTS 關 → P1 hook 寫 0x03、清掉 `UPSTAT_AUTOCTS` → serial core 的 `UPSTAT_CTS_ENABLE` 也清掉 → close 的等待回到 clamp;
- `set_rts(false)`:RTS 拉低。

**實際時序**(spike2 sysfs `last=`,`spike2.log`):

| 情況 | 序列 |
|---|---|
| 開機首次 bind | 0xcf → 0x03 → 0x8b → 0xcf(writes = 4) |
| rebind 的 bind | 0xcf → 0x03 → 0x8b → 0xcf(4 筆。P2 關閉時已清 CRTSCTS,所以 open 前 termios 沒有 CRTSCTS;open 時 ttyport 設 CRTSCTS + RTS 高 → 0xcf) |
| unbind | 0xcf → 0x03(1 筆,P2) |

spike1(沒有 P2)的 rebind 是 5 筆:0x8b → 0xcf → 0x03 → 0x8b → 0xcf。T3 以 spike2 序列為準(A v3 m1)。

## 5. 擁有權與契約

| 資源 | 唯一寫者 | 讀者 | 備註 |
|---|---|---|---|
| `AUX_MU_CNTL` | P1 驅動,持鎖寫 `data->cntl` 快取 | 硬體、sysfs | rs485 路徑同鎖、同快取。調查模組(`r305aux` / `r305raw`)是第二個寫者:只在 T3b 與調查時用,用完重開還原。sysfs 的 `hw≠cache` 會顯示這種不一致 |
| `port->status` UPSTAT_AUTOCTS | P1 hook,持鎖 | serial core、8250 IRQ | |
| CRTSCTS / RTS | serial core(open、HUPCL、throttle、suspend),以及 hci_bcm(open 握手、P2 的 close) | P1 hook 以參數判斷 | |
| sysfs `autoflow` | kernel(0400,唯讀) | harness(root)、人 | 沒有寫入路徑,不含秘密 |

**契約**:
- CRTSCTS 開:硬體 CTS 擋 TX。
- CRTSCTS 開且 RTS 拉高:另加硬體 RTS。
- CRTSCTS 關,或 rs485 開:與今天相同。
- **hci_bcm 在控制器斷電前一定先關 CRTSCTS(P2)**;port 關閉後 CNTL = 0x03。

## 6. 生命週期

| 路徑 | 之後 | 證據 / 測試 |
|---|---|---|
| 首次開機 / 開機 | §4 序列,init 後 0xcf | ✅ spike1 開機 2/2、spike2 1/1;privacy / sc / sc_file = 1 只在 spike1 第 1 次與 spike2 有紀錄(`spike-a.log`、`spike2.log`);T1、T4 |
| rebind | spike2 序列;unbind 120–130 ms | ✅ spike1 10/10、spike2 3/3;T3 |
| 運行中 | 硬體 RTS/CTS | §10b、T2 |
| 控制器卡死 / 斷電,TX FIFO 有殘留 | P2 → unbind 120 ms(沒有 P2 = 30 s) | ✅ spike2 0xcd 120 ms、舊 kernel 30140 ms;T3b |
| `hci_uart` 模組 rmmod / modprobe | 等同 rebind | T3 涵蓋 |
| bluetoothd restart、hci down/up | port 不關,CNTL 不變(`hci_serdev.c:150-157`) | 既有 BLE 套件 |
| 運行中卡死,控制器的 RTS 一直 de-assert | 有了 P1,主機 TX 會被硬體 CTS 擋住 → HCI_Reset 這類軟恢復送不出去,只剩 rebind(P2 讓它不卡 30 s)。這是將來恢復機制的前提(A v4 m8) | §11 |
| 正常關機 / 重開 | **port 不關**(`hci_bcm`、`hci_serdev`、`8250_bcm2835aux` 都沒有 `.shutdown` callback;A v3 m2 更正)→ CNTL 停在 0xcf,直到 SoC 重置 | — |
| 斷電 / watchdog reset | SoC 重置,CNTL 回到 reset 值 | 間接實證(A v4 m7):從 0xcf 狀態退回舊 kernel 後,作廢那份 soak 第 9 行是 `tx:65595 rx:4349`(patchram 下載完成,與乾淨開機相同) |
| kernel oops 在 hook 內(持鎖、關中斷) | 整台當掉。commit 前開機就當:tryboot trial 會退回(spike1 第一次就有 600 s 期限退回的實例);commit 後只有 rebind 才觸發:靠 watchdog 或斷電 | 程式審查 + T1/T3 |
| n_tty + crtscts + throttle(Pi 3 / CM4 上當一般 tty) | 軟體拉 RTS → AUTORTS 關;CTS 由硬體擋(契約改變:今天的 TX 幾乎不看 CTS,之後硬體會擋) | ⚠️ 只有原始碼分析(§8 說明為什麼不做 T6) |
| rs485 在 crtscts 之後才開 | hook 用參數 → auto 清掉 | 程式審查(fleet 無 rs485 使用者) |
| 平台驅動 `bcm2835-aux-uart` 被 root unbind | hook 留在 placeholder port 上(`8250_core.c:1220-1229`);之後 root 若再開 ttyS0 並 set_termios,hook 會拿到錯的 drvdata。與上游 8250 驅動、本驅動原有的 rs485 callback 相同的已知限制,只有 root 能觸發 | 寫明限制,不修 |
| runtime PM / suspend | N/A:DT 沒有 host-wakeup irq,`runtime_status = unsupported` | — |
| earlycon / console 在 mini UART | N/A 今天;若將來發生,hook 鎖內沒有 printk | 程式 |
| OTA stage 1/2 | 新 kernel 寫進新 slot 的 boot FAT,重開才生效 | ✅ spike OTA |
| autocommit commit / revert | autocommit 不看 BT → BT 壞掉的 kernel 會被 commit | 出貨前全套是唯一閘門(§7、§11) |
| rollback / 降版 | 依該 slot 的 `BATMAN_VERSION` 判斷 `autoflow` 應不應該存在 | ✅ spike rollback 後檔案不存在;T5 |
| bcm2710 | patch 也會編進(同 target);`[pi3] disable-bt` → 沒有使用者;bcm2710 沒編 `BT_HCIUART_BCM`,P2 無作用 | 只 build:確認 build_dir 帶著兩個 patch;VERSIONS 標「只 build、未開機驗證」 |
| bcm2712 | 同 target 會編進;fleet 沒有 Pi 5 | N/A |
| CM4 量產 | O13 前依賴兩個 patch | ⚠️ v3.0 前實測 |

## 7. 安全

| Actor | 影響 |
|---|---|
| 遠端(BLE 範圍內) | **今天**:大量廣播 → 溢位 → 卡死。**之後**:控制器被 RTS 擋住,自己丟廣播 → ⚠️ 預期改善(只在約 1 KB/s 下測過)。控制器被弄卡且 RTS de-asserted 時,主機 TX 停住;rebind 時 P2 讓 close 不等 30 s(spike2 120 ms) |
| 本機非 root / 受入侵的容器 | 沒有 `/dev/ttyS*`,碰不到 termios。sysfs `autoflow` 是 0400,非 root 讀不到,不能靠反覆讀取在 UART IRQ 路徑上搶鎖(A v3 m4) |
| root / 我們自己的錯 | 鎖內沒有 printk。平台驅動 unbind 後 hook 懸空(root-only 已知限制,§6)。極性或閘門錯 = `miniuart-bt` 機台都沒有 BLE;autocommit 不擋 → 出貨前全套是閘門。T1 / T3 對「閘門錯」敏感(0x47 3/3 失敗)。另記到 #254:autocommit 改用走真 UART 的探測判斷 BT |
| 供應鏈 | 兩個 downstream patch,自己 review;標頭註明 kernel 版本與 rebase 責任 |
| 實體 / 秘密 | 無新增 |

## 8. 驗證

**放哪裡與順序**(遵守「測項只能有一套」)

1. **harness branch**
   - `scripts/dv/bt-uart-305.sh` 放 T1、T2、T3、T5;T3b、T4 放進 daily-validation,標成破壞性 / 慢項。
   - 工具進 harness bt-tools(附 SHA256SUMS,不進 image):
     - `btprobe`:0x1001;加印 mgmt READ_INFO 的 current settings 位元。
     - `hciflood`。
     - 調查模組 `r305raw`:原始碼 + build 方法;insmod 前比對 vermagic。
     - 「不含 P2 的 `hci_uart.ko`」:用同一個 `BATMAN_FW_COMMIT` 的樹、只反套 P2 編出,檔名帶 commit。每個會改 kernel 的 rc 都要重編(B v5 m3:沒有 MODVERSIONS,別棵樹的模組也 insmod 得上,但結構可能不同)。
2. **產品 branch**
   - firmware `feat/305-autoflow` 1524084e,兩個凍結的 patch:P1 `c002892b…`、P2 `60e0cdc7…`。
   - rc `1.5.13-wsl.1+0328e83.fw1524084` **已 build**,產物檢查見 §9。
3. **在 rc 上跑 harness branch 的新測項,每個測項都含「翻轉段」**(兩位 v5 M1)
   - 翻轉段只能手動打開(`--flip`);在 daily-validation 底下拒絕執行。
   - 翻轉後同一份判定**必須 FAIL**。沒有翻過來,整個測項判無效 = FAIL。
   - 另外附 wsl.15 上 `--force`(跳過標記短路)的完整輸出:必須是因為實際判定而 FAIL,不能只是「標記不存在」。
   - 以上輸出都附進 harness PR。之後 harness PR 先 merge,再 merge 產品 PR。
4. **過渡期**(harness 已進 main、產品還沒上 fleet)
   - 測項先查兩件事:板別是不是 bcm2711(`/proc/device-tree/compatible`),以及 `BATMAN_FEATURES` 有沒有 `mini-uart-autoflow(#305)`。
   - **非 bcm2711**:印 `SKIP not a bcm2711 board`。bcm2710 也會帶這個標記,但 `fe215040` 是 bcm2711 的路徑(A v5 m6)。
   - **bcm2711、沒有標記**:印 `FAIL pre-305 image: test not applicable to this kernel` 並結束,不做 rebind 或負載。
     - `validation-known-failures.txt` 為 T1 / T2 / T3 各加一條 ERE,只匹配這一句、掛 #305。
     - 每條都以 `FAIL ` 開頭(classify 只看這種行),不含 `NEVER_KNOWN` 的字(B v5 m6)。
   - **有標記卻沒有 `autoflow`**:印 `FAIL autoflow missing on a 305 image`。這句不在 known-failures,算 NEW。
   - **T5 不短路**:pre-#305 slot 本來就應該通過「`autoflow` 不存在」。
   - **到期機制**:issue 關閉後,gh 檢查會讓那幾條 known-failures 變回 NEW。
5. **全套**
   - harness 與產品都 merge 之後,用 **main** 的 harness 在 rc 上跑正式驗收全套,含 T3b、T4、T7。結果放進產品 PR 再 merge(B v5 m7)。
   - merge 後若重 build,要在出貨產物上重跑(A v5 m7)。

| # | 測什麼 | 方法 | 判 FAIL | 翻轉段 / 負對照 | 層級 |
|---|---|---|---|---|---|
| T1 | 出貨 kernel 帶著 patch,init 後是 0xcf | root 讀 `.../fe215040.serial/autoflow`:`hw=0xcf cache=0xcf`、權限 `0400`。以 nobody 讀必須被拒;同一個 nobody 機制要讀得到 `/proc/version`(正對照)。切換方式沿用 `tmp-trust-280.sh:56` 的 `start-stop-daemon -c nobody`,並斷言 uid = 65534(A v5 m8)。探測成功 | 檔案不存在、權限不是 0400、nobody 讀得到、正對照失敗、`hw≠cache`、`hw≠0xcf` | wsl.15 `--force`:檔案不存在 → FAIL | tier A,02 與 04 |
| T2 | 運行中不再溢位 | DUT 上同時跑 30 分鐘:`hciflood` + SD 直接讀取(`dd … iflag=direct`)。**不掃描、不開 bluetoothctl**(理由見下)。先 04、再 02 | 從測試開始時擷取的 `/dev/kmsg` 出現 Frame reassembly / tx timeout;`/proc/tty/driver/serial` 那一行的 `oe` / `fe` / `pe` / `bo` 增加;探測失敗;或負載保證不足 | 翻轉:rc 上 init 後 `r305raw cntl=0x03`(與快取不同,所以 0x03 會留著)→ 同一份 T2 必須 FAIL → rebind 還原。wsl.15 `--force` → FAIL。基準:舊 kernel 同負載 10 分鐘 `oe` +7、tx timeout +7(`t2load-old-noscan.log`) | tier B |
| T3 | init 閘門(判定) | rebind × 10(翻轉段的預期見 §8a:不含 P2 時 unbind 2 筆、bind 5 筆),節點端以 `setsid` 執行(斷線不會留在半途),每次斷言:unbind < 5 s;20 s 內探測成功;sysfs 新增序列 = §4 spike2 序列(bind 4 筆、unbind 1 筆);kmsg 沒有 `tx timeout` / `failed`;current settings 有 `privacy`、`secure-conn`,沒有 `bondable` | 任一次不符 | 翻轉:insmod「不含 P2 的 `hci_uart.ko`」→ 序列會不同(spike1 實測:unbind 2 筆 `0x8b,0x03`、bind 5 筆)→ 必須 FAIL → 重開還原 | tier A |
| T3b | 控制器斷電且 TX 卡住時,close 不會久等 | `r305raw cntl=0xcc`(→ 0xcd,`tx_fill>0`)→ unbind 計時 → 重開還原 | unbind ≥ 5 s | 負對照段:同一個 rc 上 rmmod `hci_uart` → insmod「不含 P2 的 `hci_uart.ko`」→ 同測,必須量到 ≥ 25 s,否則判無效(`/sys/module/hci_uart` 沒有 srcversion,只能靠行為分辨;B v5 m3)。舊 kernel:30140 ms | daily-validation 破壞性項 |
| T4 | 開機 init | 掃描中重開 × 20 | 任一次 init 失敗 → FAIL,並重啟恢復機制的設計(§11) | ⚠️ 舊 kernel 20 次全過的機率約 0.51 → 只能抓退化,不能證明修好 | daily-validation 慢項 |
| T5 | OTA / rollback | A/B tier A。依每個 slot 的 `BATMAN_FEATURES` 判斷(限 bcm2711):有標記 → T1 必須 PASS;沒有 → `autoflow` 必須不存在 | 不符 | — | tier A(A/B 套件) |
| T7 | 原始症狀 | `ble-pair-sc-only-254` 在 rc 上重跑 × 3,不再出現 `VERDICT invalid` | 出現 invalid | wsl.14 / wsl.15 上 2/2 次 invalid(⚠️ 只有 2 筆舊資料,分辨力弱) | 全套 |

**T2 的負載保證**(要全部成立,否則 FAIL)
- `/proc/tty/driver/serial` 必須有 `^0: uart:16550 mmio:0xFE215040` 這一行。沒有 `oe:` 等欄位代表 0;整行不存在要 FAIL。
- UART 平均收 ≥ 10 KB/s。`hciflood` 確定提供約 18–19 KB/s,不靠 RF 環境。
- `hciflood` `miss` ≤ 1%。這是負載健康度,舊 kernel 實測約 0.02%。
- 每 5 分鐘一段,`/proc/diskstats` mmcblk0 讀取 sectors 增量 ≥ 10,000,000。舊 kernel 直接讀取實測:10 分鐘約 44,000,000。
- 每 15 s 讀 provhelper health:`bondable=0`、`privacy=1`、`sc=1`。

**為什麼 T2 不再掃描**(2026-10-24 實測)
- piped `bluetoothctl` 先送 `agent off`,實際回的是 `No agent is registered`:`agent off` 比自動註冊早到,這正是 B v5 指出的競態。
- agent 因此留在整段測試裡。health 在測試結束當下是 `bondable=1`,bluetoothctl 結束後才回到 0(`t2load-old-direct.log`)。
- 這在 #254 的 SC-only 目標上是不可接受的安全狀態變化。
- 不掃描、只用 `hciflood` + SD 直接讀取,完全不碰 bluetoothd,舊 kernel 10 分鐘仍穩定溢位。
- 掃描型負載(非請求式事件流)的證據,沿用 spike1 的 90 分鐘 soak:6.07 MB、0 溢位(§10b)。

**不做 T6**(n_tty throttle 的實機測試)

在 02 上做這個測試,要拿掉 `miniuart-bt` 並加 `enable_uart=1`。這會帶來三個副作用:
- console 移到 mini UART(⚠️ RPi 文件語意);
- ttyAMA0 改給藍牙用,gpsd 失效;
- `bootConfigOK` 變成 false。

遠端機台出錯救不回來,fleet 也沒有備用機。所以只做原始碼分析,列為 bcm2710 / CM4 bench 殘項。

**破壞性測項的副作用與還原**
- **T3**(每天 tier A,會 rebind):
  - 節點端以 `setsid` 跑,附 deadman:5 分鐘內沒完成就 `batman-slot reboot committed`。
  - rebind 會清掉 bluetoothd 的 adapter 物件。P2 落地前沒有 provd 註冊,影響只有 harness 自己的廣播 → T3 在 BLE 套件之外跑,並取 BLE lease。
  - 前提「沒有 provd 註冊」不成立時,T3 判 FAIL(不是 skip),#254 P2 落地時重看。
  - 任一次 rebind 後 init 失敗:先再 rebind 一次;還不行就 `batman-slot reboot committed`,該次判 FAIL。
- **T3 / T3b 的翻轉段與負對照**:
  - 只用 insmod 換模組,不寫進 rootfs。開機時 `modules.d` 會載回 rootfs 那份,所以重開即還原。
  - 開始前先確認節點在 committed slot,並附 deadman 重開。
- **T4**:重開 20 次會擠掉關機紀錄(只留 10 份)→ 先整份備份 `/opt/batdata/log`。
- **T2**:
  - 結束時停掉兩個負載(process group),並確認沒有殘留。
  - 翻轉段或 wsl.15 上可能卡死 → 結束時探測;沒回應就 rebind,不行就 `batman-slot reboot committed`。

## 9. 出貨路徑與版號

- **firmware PR**(`build-3aplus` ← `feat/305-autoflow` 1524084e)
  - 兩個 patch 放在 `target/linux/bcm27xx/patches-6.6/`。
  - rc `1.5.13-wsl.1+0328e83.fw1524084` 的產物檢查(2026-10-24,`verify-rc.sh`):

| 檢查 | 結果 |
|---|---|
| build_dir 原始碼 | 有 `dev_groups = bcm2835aux_groups`、`DEVICE_ATTR_ADMIN_RO(autoflow)`;`hci_bcm.c` 有 P2 的 `#305` 註解區塊 |
| kernel8.img | 有見證字串;wsl.15 沒有 |
| 開機分割區 | 只有 kernel8.img 不同 |
| `hci_uart.ko` | 與 wsl.15 不同,vermagic 相同 |
| build stamp | `BATMAN_DIRTY=0`;`BATMAN_FEATURES` 帶 `mini-uart-autoflow(#305)` |
| payload sha | `ebe8d37c…` |

  - ⚠️ 兩個 patch 只在 bcm2711 config 下編過(out-of-tree `-Werror` 檢查,以及這次 rc)。**bcm2710 還沒有 build**:它的 build_dir 沒套過 patch(B v6 m10),要在產品 PR 前 build 一次,確認 P1 套上、編得過;P2 在 bcm2710 不會編(沒有 `BT_HCIUART_BCM`)。
  - morse 模組照常載入:在 rc 開機時確認。
- **版號**:1.5.13。spike 用過的 `1.5.12-wsl.16`、`wsl.17` 列為退役號碼,記入 VERSIONS。
- **`boards-and-builds.md`**:記錄兩個 downstream kernel patch 與 rebase 責任;bcm2710 image 標「只 build」。

## 8a. 第 6 輪 MINOR(實作時落實,harness PR 附證據)

| 來源 | 要做的事 |
|---|---|
| A m1 / B m1 | 翻轉段與 `--force` 必須**因偵測通道 FAIL**:T2 程式自己解析出 `oe` 增量 ≥ 1,而且 kmsg tx timeout 增量 ≥ 1(逐條判定,不是整份 FAIL)。只因負載保證或探測失敗而 FAIL → 翻轉段判無效 |
| A m2 / B m3 | 負載在節點端自帶時限(`timeout` 由腳本自己算),process group 帶 `BATMAN_DV_BLE` 標記;結束時有殘留就印 `FAIL cleanup`,並納入 deadman |
| A m3 / B m6 | 不含 P2 的 `hci_uart.ko`:out-of-tree 編(不在產品 build_dir 反套,build_dir 不受 git 管、`DIRTY=0` 看不到);綁 `BATMAN_FW_COMMIT`;上傳到 root-only run dir,insmod 前一刻在節點上比對 sha;重開後驗證 rootfs 版本回來。T3b 的負對照段只在 `--flip` 跑,不每天跑 |
| A m4 / B m2 | `r305raw` 用完立即 rmmod;注入前後斷言 `hw` / `cache` / `tx_fill`;翻轉期間每 15 s 斷言 `hw=0x03 cache=0xcf`、writes 不變;還原後斷言 `hw=cache=0xcf` |
| A m5 | 非 bcm2711 用 harness 的 `na()`,不印 SKIP |
| A m6 | T5 沒有負對照:寫明它是回歸保護 |
| A m7 | T3 翻轉預期更正為 unbind 2 筆、bind 5 筆 |
| A m8 | 三個 suite 名稱先定:`bt-uart-flow-305`(T1)、`bt-uart-load-305`(T2)、`bt-uart-rebind-305`(T3);known-failures 依名稱比對 |
| A m9 | 出貨 rc 與每日回歸都**沒有**掃描型負載,寫進 PR 的「沒測到」;掃描型證據只有 spike1 soak |
| A m10 | `verify-rc.sh` 改 grep `Batman #305` 註解(原檔本來就有 3 處 `if (hu->serdev)`) |
| A m11 / B kmsg | `/dev/kmsg` 擷取寫起點、終點標記行,驗證擷取程序到結束都活著;EPIPE(ring 溢位)= FAIL |
| B T3 deadman | 每次 rebind 前延長 deadman,不是固定 5 分鐘 |
| B 過渡期 T3b | T3b 在 wsl.15 上同樣走標記短路與 known-failures |
| B T1 / T5 翻轉 | T1 以 `--flip` 讀一個不存在的路徑必須 FAIL;T5 以假的 FEATURES 字串驗判定分支 |
| B 02 門檻 | T2 門檻在 02 也量一次舊 kernel 基準 |
| B §6 | 「`hci_uart` rmmod / modprobe 由 T3 涵蓋」不正確 → 改由 T3b 負對照段涵蓋 |
| 現場 | 我的 `t2load-noscan.sh` 漏掉停止 SD 迴圈,04 上 dd 跑了約 41 GB 才被發現、以 SIGINT 停掉;這段期間沒有量測。harness 負載一律自帶時限 + 殘留檢查(上面 A m2) |

### 替代方案

| 方案 | 現場效果 | OTA 送得到? | 與 HAT v2 | 維護 |
|---|---|---|---|---|
| **A. kernel patch(採用)** | 運行中溢位歸零(§10) | 是 | O13 前量產 CM4 也受益 | 每次 kernel 升版要 rebase |
| B. 藍牙回 PL011、GPS 改 mini UART 9600 | 藍牙 0 溢位 | 否(`distroconfig.txt` 不隨 OTA;`bootConfigOK` 要求 `miniuart-bt`) | 同 O13 方向 | 低 |
| C. 降鮑率 | 容忍時間 ×2,不消除 | 是 | — | 低 |
| D. 只做恢復 | 卡死照舊發生 | 是 | — | 恢復機制的介面問題 |

close 30 s 的處理(使用者 2026-10-24 選根解):

| 選項 | 判斷 |
|---|---|
| **P2(採用)** | 根解 |
| 接受 30 s | 只是延後 |
| port 不等待(`closing_wait` = NONE) | 會影響所有 mini UART 使用者,關閉時可能丟資料 → 不採用 |

## 10. 翻轉證據

### 10a. 舊 kernel,調查模組切換 CNTL(init 一律 0x03、init 後才設 0xcf)— #305 留言 6381933317

負載:`duplicate-data` LE 掃描(約 1060 B/s)+ SD 讀取,30 分鐘一段輪流(⚠️ SD 負載沒有直接紀錄,只有 tick 腳本每次都補起 `dd`)。

| 條件 | 時間 | UART 收 | `oe` | Frame reassembly | tx timeout | 探測失敗 | 卡死 |
|---|---|---|---|---|---|---|---|
| 0x03 | 3 × 30 分 | 3.1 MB | 88(42 / 26 / 20) | 71 | 82 | 8 | 3 |
| 0xcf | 3 × 30 分 | 4.5 MB | 0 | 0 | 0 | 0 | 0 |

### 10b. 真 patch(spike1 = P1 v1;spike2 = P1 v1 + P2)— #305 留言 6383004795、6383922541(close 部分已在 6384535906 更正)

| 項目 | 結果 | 紀錄 |
|---|---|---|
| spike1 開機 | 2/2,`hw=0xcf cache=0xcf writes=4`;morse 模組載入。第 1 次開機有 privacy / sc / sc_file = 1(`spike-a.log`)。第 2 次開機沒有 btprobe 輸出(`/tmp/run` 重開後清空),探測成功的證據是 soak 第一筆 `up=161 probe_rc=0` | `ota16-04.log`、`ota16b-04.log`、`spike-a.log`、`soak16-*.log` |
| spike1 rebind × 10 | 10/10,120–130 ms,沒有 init 錯誤 | `spike-a.log` |
| spike1 90 分重負載 | 第二份 `soak16-*.log`:179 行全在 spike kernel(`up=` 161 → 5542 單調增加,每行都讀得到 `autoflow`);平均 1129 B/s;`oe` 0(該行沒有 `oe:` 欄位)、Frame reassembly 0、tx timeout 0;探測 178/178;CNTL 全程 `0xcf / 0xcf / writes=4`。⚠️ SD 負載沒有直接紀錄 | 第二份 `soak16-*.log` |
| 作廢的 soak | 第一份 `soak16-*.log`:held trial 在 600 s 期限到時被退回(我誤以為 hold 不會到期)。只有前 5 分鐘在 spike kernel 上;第一筆的 `txto=2`,歸因於 spike-b 故意以 0x4f 讓 TX 卡住時的兩次探測(343.74 s 注入 → 345.99 s / 351.19 s 逾時) | 第一份 `soak16-*.log` |
| spike1 第二次上 04 | held trial → `batman-autocommit release` → **COMMITTED** slot B(不只是 release),之後 rollback 回 A | `ota16b-04.log`、`autocommit.log` |
| spike2 開機 | 0 錯誤,`hw=0xcf`,privacy / sc / sc_file = 1 | `spike2.log` |
| spike2 rebind × 3 | 3/3,120–130 ms,序列見 §4 | `spike2.log` |
| spike2 TX 卡住 unbind | 0xcd、`tx_fill=4` → 120 ms | `spike2.log` |
| rollback 回 wsl.15 | `autoflow` 檔不存在 | 收尾紀錄 |

## 11. 殘項(寫進 #305,不另開單)

- CM4 實測:極性、走線、O13 決定前的依賴。v3.0 前做。
- HAT v2 若加電平轉換,確認極性。
- bcm2710:開機冒煙、n_tty throttle bench(03 故障、P-U14)。
- 恢復機制的判準:若 T4 或現場仍見 init 失敗或卡死,就重啟恢復機制設計。不論結果如何,「走真 UART 的 0x1001 探測」都記到 #254,當 autocommit BLE gate(P2)的 BT 健康訊號。
- T7 通過、產品出貨後,以 harness PR 移除 `validation-known-failures.txt:14` 與 T1 / T3 / T5 的過渡條目。
- `boards-and-builds.md` / `VERSIONS.md` 的更新(§9)。
- `distroconfig.txt` 的 `uart_enable=1` 不是有效 key(和本單無關,只記一行)。
- 04 p6 的 spike payload(`ota-wsl16-spike.tar.gz`、`ota-wsl17-spike.tar.gz`):收單時先列出,再刪除。

## 12b. 對照(v5 → v6)

| 審查 | v6 |
|---|---|
| A v5 M1 / B v5 M1:標記短路讓負對照變空 | 每個測項加手動翻轉段:T1 正對照、T2 `cntl=0x03`、T3 / T3b 換成不含 P2 的模組;沒翻過來就判無效。另附 wsl.15 `--force` 的實際判定 FAIL。翻轉段在 daily-validation 底下拒絕執行 |
| A v5 M2:SD 負載只有 page cache | `dd iflag=direct`;每 5 分鐘 ≥ 1,000 萬 sectors。舊 kernel 重量:10 分鐘約 4,400 萬 sectors(`t2load-old-direct.log`);不掃描版 `oe` +7(`t2load-old-noscan.log`) |
| A v5 m1:dmesg ring 繞回 | 從測試開始時擷取 `/dev/kmsg` |
| A v5 m2:`bo` / `fe` / `pe` | 加入判定 |
| A v5 m3 / B v5 m2:掃描負載 | 實測 `agent off` 的競態造成 `bondable=1` → T2 不掃描;掃描型負載沿用 spike1 soak 的證據 |
| A v5 m4 / B v5 m1:agent 競態 | 同上;T2 每 15 s 斷言 `bondable=0` |
| A v5 m5 / B v5 m3:不含 P2 的模組從哪來 | 依 `BATMAN_FW_COMMIT` 從同一棵樹反套 P2 編出;負對照段 ≥ 25 s,否則判無效;附 deadman 重開 |
| A v5 m6 / B v5 m5:bcm2710 | 先判板別,非 bcm2711 → SKIP |
| A v5 m7 / B v5 m7:出貨產物 | 全套從 main 的 harness 跑;merge 後重 build 要重跑 |
| A v5 m8:節點沒有 `su` | `start-stop-daemon -c nobody` + uid 斷言 + `/proc/version` 正對照 |
| B v5 m4:T3 每天 rebind 時斷線 | 節點端 setsid + deadman |
| B v5 m6:known-failures 字句 | 以 `FAIL ` 開頭;T5 不短路 |
| B v5 m8:殘項過時、§9 sha 比對、R4 行號 | 已改 |
| B v5:P2 v5 從沒編過 | rc 已 build(§9),開機驗證在 rc 上做 |

## 12a. 對照(v4 → v5)

| 審查 | v5 |
|---|---|
| B v4 M1:T2 的 `adv-fast` 做不出來 | 改成 `duplicate-data` 掃描(agent off)+ `hciflood` + SD 讀取,不需要對端;負載保證改成 rx ≥ 10 KB/s、flood miss ≤ 1%、SD sectors 門檻;舊 kernel 10 分鐘 15 次溢位當負對照證據(`t2load-old.log`) |
| A v4 m1:分不出 P1 v1 與 v4 | T1 斷言 0400 + 非 root 被拒;§9 比對 `dev_groups` 與 `if (hu->serdev)` 兩行 |
| A v4 m2:T2 在舊 kernel 不短路 | 過渡期 feature 標記判斷,沒有標記就立即 FAIL、不跑負載 |
| A v4 m3:改 `ble-periph-254.sh` 要附回歸 | 不再改它 |
| A v4 m4 / B v4 m5:T5 的版號比較 | 改用 `BATMAN_FEATURES` 標記 |
| A v4 m5:AUTOCTS = 0 只有手冊依據、P1-only 30 s 只寫推論 | §3 補原始碼論證與一次性補測(0x8b);T3b 真負對照 |
| A v4 m6 / B v4 m3:P2 的條件 | 只在 serdev(P2 `60e0cdc7…`)。不加 `drive_rts_on_open` 條件:30 s 問題對任何 serdev + CRTSCTS 的 BCM 控制器都成立,包括 CM4 的 PL011 |
| A v4 m7:斷電後 CNTL 回 reset 值 | §6 引用間接實證 |
| A v4 m8:軟恢復送不出去 | §6、§11 |
| A v4 m9:0400 沒有測項、`dev_groups` 沒開機驗證 | T1 非 root 讀取被拒;rc 開機即驗證 |
| B v4 m1:P1-only 負對照 | T3b:同 rc insmod 不含 P2 的 `hci_uart.ko`;P2 標頭的「measured」改寫成「在兩個 patch 都沒有的舊 kernel 上量的」 |
| B v4 m2:rebind 後的安全狀態 | T3 斷言 privacy、secure-conn、沒有 bondable |
| B v4 m4:known-failures 字句 | §8 第 4 點 |
| B v4 m6:spike 號碼退役與 rc PASS 衝突 | §8 順序:先 build `1.5.13-wsl.1`,用 harness branch 驗,再依序 merge |
| B v4 m7:T3b、T4 進常規全套 | daily-validation 破壞性 / 慢項 |
| B v4 m8:r305raw 只編一次 | 比對 vermagic |
| B v4 m9:build 驗證 | §9 兩板檢查項 |
| B v4 m10:行號 | 文中行號一律指原始 6.6.138(未 patch);引用 spike 樹的地方已改寫成函式名 |

## 12. 對照(v3 → v4)

| 審查 | v4 |
|---|---|
| A v3 M1 / B v3 M1:close 120 ms 是假象 | §3 更正;使用者選根解 → P2;spike2 實測 120 ms 對舊 kernel 30140 ms;T3b 改用 0xcd 注入 |
| A v3 M2:T5 不能用 | 依 slot 的 `BATMAN_VERSION` 推預期;不用 `uname -v` |
| A v3 m1 / B v3 m1:rebind 序列 | 以 spike2 實測序列為準(§4) |
| A v3 m2:關機時 port 不關 | §6 更正 |
| A v3 m3:平台驅動 unbind 後 hook 懸空 | §6 寫明 root-only 已知限制 |
| A v3 m4:sysfs 0444 | 改 0400 + `dev_groups`(P1 `c002892b…`) |
| A v3 m5:lockdep 不當證據 | §4 |
| A v3 m6 / B v3 m2:T2 廣播 instance 與擁有者 | `ble-periph-254.sh adv-fast`、instance 由 advinfo 決定、唯一標記、rm-adv 後才釋放 lease |
| A v3 m7:r305raw 進 harness、T3 依賴 P2 前提 | §8 |
| A v3 m8:crash 列、hci_uart 模組 | §6 |
| A v3 m9 / B v3 m7:證據細節 | §10b |
| A v3 m10:patch sha 綁定 | §8 第 3 點 |
| B v3 m3:SD 負載沒有證據 | T2 加 `/proc/diskstats` 門檻;§10 標 ⚠️ |
| B v3 m4:過渡期 | T3 / T5 立即 FAIL、known-failures 三條、到期 = issue 關閉 |
| B v3 m5:破壞性測項的還原 | §8 |
| B v3 m8:出貨路徑與版號 | §9(1.5.13、退役號碼、兩板 build 驗證、DIRTY = 0) |
| B v3 m9:n_tty 契約改變 | §6 |
| B v3 m10:sysfs 0400、skip_rx 證據 | 0400 已做;skip_rx:8250 IRQ 的 `skip_rx` 條件只在 `read_status_mask` 沒有 DR 時成立(`8250_port.c:1936-1939`),本 patch 不改 `read_status_mask` |
