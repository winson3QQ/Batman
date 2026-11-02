# #305 mini UART 硬體流量控制設計 v6 — 對抗式審查 A(第 6 輪,整份重審)

## 結論:**APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 11 MINOR**

- **兩個 patch:維持凍結。** firmware `feat/305-autoflow` HEAD = `1524084e`,樹內兩個 patch 的 sha256 = `c002892bfd20a992` / `60e0cdc749345aa1`,與 scratchpad 版本相同(E1)。
- **round-5 的兩個 MAJOR 都關了**:
  - M1(標記短路讓負對照變空):手動翻轉段 + wsl.15 `--force` 讓判定程式真的在會溢位的狀態下跑。
  - M2(SD 只有 page cache):`iflag=direct` + 每 5 分鐘門檻;舊 kernel 實測每 10 分鐘 4,440 萬 sectors(E3)。
- 剩下的都是實作規格要寫死的細節(m1–m11),不改設計。其中最重要的三點:
  - **m1**:翻轉段必須「因為偵測通道」FAIL,不是因為負載保證或探測失敗;
  - **m2**:負載必須在節點端自己有時限。**04 上現在就有一個 v6 證據腳本留下的 direct-IO `dd` 迴圈還在跑**(E4);
  - **m3**:不含 P2 的模組不能在產品 build_dir 裡反套編出。
- **harness branch 可以現在開工。** 上機的翻轉段、`--force` 和 rc 驗證需要使用者授權。

---

## 我自己查過的原始資料

| # | 事實 | 證據 |
|---|---|---|
| E1 | 產品分支與 patch 已凍結 | WSL `~/firmware-2710`:`feat/305-autoflow`,`1524084e #305: mini UART hardware flow control…`,parent `72814fa4`;`git status` 乾淨;`patches-6.6/999-batman-*305*.patch` sha256 `c002892bfd20a992`、`60e0cdc749345aa1`;commit 只動兩個 patch + `batman-release.env` |
| E2 | §9 產物檢查重跑結果相符 | 我重跑 `verify-rc.sh`:`BATMAN_VERSION=1.5.13-wsl.1+0328e83.fw1524084`、`BATMAN_DIRTY=0`、`mini-uart-autoflow(#305)`;kernel8 `533552ab…` witness=1 vs wsl.15 `479cbe92…` witness=0;`hci_uart.ko` `9d1f73cc…` vs `85b5590d…`,vermagic 都是 `6.6.138 SMP mod_unload aarch64`;boot 只差 1 個檔;payload `ebe8d37ca7142b3b`。**但** `serdev-guard=4` 不能證明 P2 存在:原始 `hci_bcm.c` 本來就有 3 處 `if (hu->serdev)`(build_dir `:172`、`:462`、`:538`,P2 的在 `:561`),見 m10 |
| E3 | 新舊負載的舊 kernel 基準 | `t2load-old-direct.log`(掃描 + flood + direct):`oe` 15→33(+18)、frame +11、txto +12、sd_rd +44,289,517、flood 18887 B/s、miss 10/44450。`t2load-old-noscan.log`(flood + direct):`oe` 33→40(+7)、frame +1、txto +7、sd_rd +44,416,237、flood 19445 B/s、miss 7/45759。04 目前 `/proc/tty/driver/serial` `oe:40`,與 log 結尾相同 |
| E4 | **04 上留著證據腳本的負載** | 04 `ps`:`23267 root … sh -c while :; do dd if=/dev/mmcblk0p2 of=/dev/null bs=64k iflag=direct …`;loadavg `1.41 1.44 1.45`;mmcblk0 讀取 sectors 現在 172,532,089(noscan log 結尾是 92,657,940,之後又讀了約 8,000 萬 sectors ≈ 41 GB)。原因:`t2load-noscan.sh` 沒有 `kill`,最後的 `ps` 有印出殘留,但沒人處理。log 最後一行就是這個 PID。依規則我沒有 kill 它 |
| E5 | 02 閒置時也有溢位 | 02 uptime 65610 s:`rx:311015 oe:2`。BLE 閒置負載下仍有溢位,是現場觸發的佐證 |
| E6 | 翻轉後 0x03 會留著 | P1 `bcm2835aux_update_flow`(build_dir `8250_bcm2835aux.c:106-119`):`if (cntl == data->cntl) return;`,只有算出的值與快取不同才寫。快取停在 0xcf 時,`set_termios` / `set_mctrl` 算出的都是 0xcf,不會寫 |
| E7 | 穩態時沒有東西會切 flow control | `hci_bcm.c` 的 `hci_uart_set_flow_control` 只在 `bcm_open`(`:489`、`:491`、`:507`)、P2(`:562`)和 suspend / resume(`:780`、`:791`、`:822`,runtime PM 是 unsupported)。`bcm_setup` 的 `host_set_baudrate`(`:620`、`:635`)走 `set_termios`,算出 0xcf == 快取 → 不寫。所以 hci down/up、bluetoothd 重啟、HCI 重新 setup 都不會蓋掉翻轉值 |
| E8 | 翻轉的 RX 路徑等同舊 kernel | 0x03 = AUTORTS / AUTOCTS 都關;MCR 仍由 `serial8250_do_set_mctrl` 設成 RTS asserted;P1 不在 IRQ 路徑加任何東西。唯一差別在 TX:P1 設了 `UPSTAT_AUTOCTS`,所以 `uart_softcts_mode` 為假,serial core 不做軟體 CTS(`serial_core.c:234-235`、`:3519-3528`)。舊 kernel 在 mini UART 上(`UART_CAP_MINI`,`:235`)軟體 CTS 也幾乎不起作用。溢位是 RX 現象,所以翻轉忠實 |
| E9 | 還原正確 | rebind 時 P2 清掉 CRTSCTS → update_flow 算出 0x03 ≠ 快取 0xcf → 寫 0x03、快取 = 0x03;bind 依 spike2 序列回到 0xcf。快取與硬體重新一致 |
| E10 | spike1 的 rebind 序列(T3 翻轉段的預期) | `spike-a.log:7`:unbind 時 writes 4→6(`0x8b,0x03`,2 筆),bind 6→11(`0x8b,0xcf,0x03,0x8b,0xcf`,5 筆)。spike2(`spike2.log:5`):unbind 1 筆(`0x03`)、bind 4 筆。**unbind 與 bind 兩邊都不同**;§8 T3 寫「unbind 序列會不同(spike1 實測 5 筆)」,把 bind 的 5 筆說成 unbind 的(m7) |
| E11 | r305raw 的行為 | `auxmod/r305raw.c`:寫入 `(cntl & 0xff) \| 0x1`,不持 port lock;init 回 0,所以模組會留在記憶體;位址寫死 `0xfe215040`。`cntl=0x03` → 0x03、`0xcc` → 0xcd,與設計相符 |
| E12 | harness 的機制 | `daily-validation.sh:2704` `NEVER_KNOWN`,`:2706-2725` classify(依 suite 名稱逐行比對 `FAIL ` 行;gh 回 CLOSED → NEW);`:77-104` `suite()`(rc 3 + `SKIP-REASON:` 才算 SKIP);`:105-110` `na()` = 依 SoC 判定的 N/A,不算 SKIP。BLE lease / leftover 檢查在 `ble-lib-254.sh:84-193`,只認環境變數帶 `BATMAN_DV_BLE=` 的程序 |
| E13 | 樹內已有不註冊 agent 的掃描方式 | `ble-central-254.sh:7`、`:52`:非互動的 `bluetoothctl --timeout N scan on`(不註冊 agent,該設計的 E6)。不過非互動模式設不了 `duplicate-data`(它是單一 client 的 discovery filter),所以頻率低很多 |

---

## round-5 MAJOR 關閉狀況

| round 5 | v6 | 判斷 |
|---|---|---|
| A M1 / B M1:標記短路 | T1 正對照 + `--force`;T2 翻轉 0x03;T3 / T3b 換模組;沒翻過來 = 無效 = FAIL;翻轉段在 daily 底下拒絕執行 | ✅ 關閉。細節:FAIL 原因必須是偵測通道(m1);T5 還沒有負對照(m6) |
| A M2:page cache | `iflag=direct`、每 5 分鐘 ≥ 1,000 萬 sectors | ✅ 關閉。舊 kernel 實測約 2,200 萬 / 5 分鐘,門檻約為一半,符合我 v5 的建議 |

---

## 逐項回答指定的重點

**1. T2 翻轉在 P1 kernel 上是否忠實?中途會不會被改寫?**
- 忠實:RX 路徑等同舊 kernel(E8)。
- 穩態不會被改寫(E6、E7)。即使控制器失步後 bluetoothd 做 down/up 或 HCI 重新 setup,也只走 `set_termios`,值 0xcf == 快取,不寫。
- 唯一會改寫的是 open / close / rs485 / suspend,T2 期間都不會發生。
- 這要**量**,不能只推論:翻轉期間每 15 s 讀 sysfs,要求一直是 `hw=0x03 cache=0xcf`,而且 `writes` 沒有增加;只要有一次不符,翻轉段就判無效(m4)。

**2. 用 rebind 還原是否正確?**
- 正確(E9)。
- 但要斷言:還原後 `hw=cache=0xcf`、探測成功、`r305raw` 已 rmmod;不符就 `batman-slot reboot committed`(m4)。

**3. 舊 kernel 10 分鐘 `oe` +7,夠不夠讓 30 分鐘 T2 有分辨力?**
- 以 Poisson 估:λ ≈ 0.7 / 分,30 分鐘約 21,P(0) ≈ e^-21。
- 只有一筆樣本時,取 7 次的 95% 單側下界(10 分鐘約 2.8 次):30 分鐘 λ ≥ 8.4,P(0) ≤ 2.2×10^-4。
- §10a 顯示每 30 分鐘的速率在 20–42 之間變動,有過度離散,但下界仍夠。
- 更重要的是,翻轉段在**同一個 rc、同一台、同一天**跑,本身就重新量了一次分辨力。只要翻轉段要求 `oe` 增量 ≥ 1,這個問題每次都會實測。
- 結論:足夠。建議把上述下界算式寫進 §8,讓「為什麼 30 分鐘夠」有數字。

**4. 不掃描,現場涵蓋度能不能接受?**
- 能接受,理由如下:
  - 現場觸發是非請求式的廣播流;
  - spike1 的 90 分鐘掃描 soak 在 **P1 v1** 上 0 溢位,而 v1 的 flow 邏輯與 `c002892b` 相同(只差 sysfs 註冊,第 4、5 輪我逐行比過);
  - 同樣掃描負載在舊 kernel(§10a 0x03)90 分鐘有 88 次;
  - 所以掃描型負載的翻轉證據存在,而且是在相同的邏輯上。
- 但要寫明兩個限制:
  - 出貨的 rc 本身沒有跑過掃描型負載;
  - 之後 kernel rebase 的每日回歸也不會跑。
- 另外,v6 的「掃描只能用 piped bluetoothctl」說法不完整:樹內已有不註冊 agent 的非互動掃描(E13),只是設不了 duplicate-data。
- 低成本的補法見 m9:在 rc 上做一次「先等 AgentManager1 出現再 `agent off`,斷言 `bondable=0` 後才 `scan on`」的掃描段。不做的話,§1 範圍聲明加一行 ⚠️。

**5. `--flip` / `--force` 防呆與 known-failures 字句能不能實作?**
- 可以,但要寫死四件事:
  1. `scripts/dv/*.sh` 是被 source 的函式檔(`ble-254.sh:1-7`),沒有命令列。`--flip` / `--force` 只能放在另一個手動入口,例如 `scripts/bt-uart-305-manual.sh`。
     - 防呆:入口檢查自己不是被 `daily-validation.sh` source,而且沒有 daily 專用的環境(例如 `DIR` 指向 results dir)。
     - dv 函式本身不接受這兩個開關。
  2. known-failures 是「suite 名稱 + ERE」。T1 / T2 / T3 要各自是 daily 的一個 suite,名稱現在就要定下來(m8)。
     - `FAIL pre-305 image: test not applicable to this kernel` 這句不含 `NEVER_KNOWN` 的字(E12),可以用。
  3. 「非 bcm2711 印 `SKIP`」會被 `suite()` 當成「該驗沒驗」。要改用 `na()` 的 SoC N/A(m5)。
  4. 輸出要讓翻轉與 `--force` 的結果和 daily 結果分得開,例如加 `FLIP-SEGMENT` 前綴,以免被當成 daily 證據。

**6. harness branch 能不能現在開工?**
- 能。patch 凍結、rc 已 build、測試設計沒有 MAJOR。m1–m11 都可以邊寫邊落實。
- 上機項目要使用者授權:翻轉段、`--force`、rc 開機、T2 / T3 / T3b。
- 開工前先處理 04 上殘留的 `dd`(m2 / E4)。

---

## 生命週期 / 資源補查(先找缺漏)

| 路徑 / 資源 | 判斷 |
|---|---|
| 首次開機、開機、rebind、OTA、rollback、降版 | 與 v5 相同,證據足夠;T5 用標記判斷,兩邊都 fail-closed |
| 關機、斷電、crash / crash loop | §6 有;翻轉段與負對照都只改記憶體狀態,重開即還原 |
| **網路中斷(主機 ↔ DUT)**,T2 進行中 | **缺**。負載以 `setsid` 跑在節點上,主機斷線後,`hciflood` 有 DUR 會自己結束,但 `dd` 迴圈是無限迴圈,會一直跑。E4 就是活生生的例子。§8「結束時停掉」只靠主機端 → m2 |
| 依賴重啟:bluetoothd、hci down/up | 不影響翻轉值(E7);一般狀態 CNTL 不變 |
| 新資源:`r305raw` 模組 | 第二個寫者(§5 已承認);init 回 0,會留在記憶體;下次 insmod 會 `File exists` → m4 |
| 新資源:不含 P2 的 `hci_uart.ko` | 來源與 build 方式 → m3;與 rc 的綁定 → m3;T3b 每天要不要跑負對照段 → m3 |
| 新資源:`/dev/kmsg` 擷取程序 | 30 分鐘長的 reader;ring 被蓋過時讀取端會拿到 EPIPE。擷取程序死掉就是 0 行 = 假 PASS → m11 |
| 平台 | bcm2710 SKIP → 改 N/A(m5) |

## 安全(逐 actor)

- **遠端 BLE**:不變;T2 不掃描,不需要對端。
- **本機非 root / 受入侵的容器**:新工具(`r305raw`、`hciflood`、非 P2 模組)都只有 root 能用(insmod、CAP_NET_RAW)。`autoflow` 是 0400,T1 以 `start-stop-daemon -c nobody` 驗證。沒有新的非 root 輸入。
- **我們自己的錯**(這輪的主要面):
  - `--flip` / `--force` 開關不能被 daily 用到(第 5 點的 1);
  - 不含 P2 的模組若沒有還原,節點會留在「close 等 30 s」→ 重開後要驗證 `hci_uart.ko` 的 sha 是 rc 那份(round 5 已提,v6 §8 只寫「重開即還原」,沒有驗證這一步,併入 m3);
  - 在產品 build_dir 反套 P2,可能讓下一個 rc 不帶 P2 卻標 `DIRTY=0`(m3);
  - 負載殘留(m2,E4)。
- **秘密**:無新增。T2 不再碰 bluetoothd 的 agent,**降低**了 #254 的 bondable 風險,而且有每 15 s 的 `bondable=0` 斷言。這是正確的處理。

---

## MINOR

**m1 翻轉段 / `--force` 必須因「偵測通道」FAIL**
- v6 第 3 點寫「因為實際判定而 FAIL」。T2 的判定也包含負載保證不足和探測失敗。翻轉時控制器失步卡住,flood 的 `miss` 會先超標,或探測先失敗。這種 FAIL 不能證明 `oe` 解析(設計自己寫了「沒有 `oe:` 欄位 = 0」,這正是最容易寫成永遠 0 的地方)和 kmsg 擷取是好的。
- 修法:翻轉段的有效條件寫成「T2 的程式自己解析出 `oe` 增量 ≥ 1,**而且** kmsg 的 tx timeout 增量 ≥ 1」,兩者都要印出數字。
  - frame 只要求印出,不設門檻(noscan 10 分鐘只有 +1)。
  - 只因負載保證或探測失敗而 FAIL → 翻轉段判無效。
  - 判定要先把所有通道算完再印,不能遇到第一個 FAIL 就結束。

**m2 負載必須在節點端有時限,並帶標記(E4)**
- 證據腳本 `t2load-noscan.sh` 沒有停掉 `dd`,04 上的 direct-IO 迴圈到現在還在跑(PID 23267,已多讀約 41 GB)。這正是「主機端負責清理」的失敗型態,也代表「04 閒置」的前提目前不成立。
- 修法:
  - 節點端的 `dd` 迴圈自帶結束時間(例如每圈檢查 `/proc/uptime` 超過 T0 + DUR + 60 就 exit);
  - deadman 觸發時也要殺負載;
  - 程序帶 `BATMAN_DV_BLE=` 環境變數,讓 `ble-lib-254.sh:151-153` 的 leftover 檢查抓得到;
  - 結尾發現殘留要印 `FAIL cleanup …`(這句在 `NEVER_KNOWN` 裡,不可能被當成 known)。
- **立即動作**(主 agent / 使用者):停掉 04 的 PID 23267,先 SIGINT 或 TERM(它不持有硬體),再 `ps` 確認 `dd` 子程序也結束。在這之前不要在 04 上做任何量測。

**m3 不含 P2 的 `hci_uart.ko`:build 位置、綁定、還原驗證**
- **build 位置**:不要在產品 build_dir 反套 P2 再編。build_dir 不受 git 管,`BATMAN_DIRTY` 看不到它,下一個 rc 可能不帶 P2 卻標成乾淨。改用 out-of-tree:把 `drivers/bluetooth/` 複製到 tmp,反套 P2,`make -C $K M=$tmp`(和先前 `-Werror` 檢查同一套)。編完驗證產品 build_dir 的 `hci_bcm.c` 仍含 `Batman #305` 註解。
- **綁定**:vermagic 不能分辨不同的樹(兩個 build 都是 `6.6.138 SMP mod_unload aarch64`,E2)。測項要拿節點 `/etc/batman-build` 的 `BATMAN_FW_COMMIT` 比對模組檔名或 SHA256SUMS 的條目;不符就 FAIL,不是 SKIP。
- **還原驗證**:重開後讀 `/lib/modules/*/hci_uart.ko` 的 sha,並比對已載入模組的行為(或至少確認 `modules.d` 載入的是 rootfs 那份),寫成斷言。
- **T3b 每天要不要跑負對照段**:寫清楚。若每天跑,每個出貨 build 都要有一份對應的模組;若只在 harness PR 和 rc 驗收時跑,daily 的 T3b 就只有正向判定。

**m4 `r305raw` 的生命週期與翻轉期間的監看**
- `r305raw` init 回 0,會留在記憶體(E11)。每次用完要 `rmmod r305raw`,否則下一次 insmod(例如 T3b)會失敗。
- 翻轉期間每 15 s 讀 sysfs,要求 `hw=0x03 cache=0xcf writes` 不變;不符 → 翻轉無效。
- 還原後斷言 `hw=cache=0xcf`、探測成功;不符就 rebind 一次,還不行就 reboot committed,並判 FAIL。

**m5 非 bcm2711 用 `na()`,不要印 SKIP**
- `daily-validation.sh:105-110`:SoC 不適用要用 `na`;SKIP 代表「該驗沒驗」(rc 3 + `SKIP-REASON:`)。照 v6 寫 `SKIP`,Pi 3 回到 fleet 時,每天都會多出 SKIP。
- SoC 判斷要在 host 端 `suite` / `na` 那一層做,和現有的 SoC 閘門同一個位置。

**m6 T5 沒有負對照**
- T5 的翻轉欄是「—」。可以加 `--force` 段:在 rc slot 上把預期反過來(假裝沒有標記)→ 必須 FAIL;在 wsl.15 slot 假裝有標記 → 必須 FAIL。
- 成本很低,補上才符合「每個新測項都有負對照」。

**m7 T3 翻轉段的預期序列寫錯(E10)**
- 不含 P2 時,unbind 是 2 筆(`0x8b,0x03`),bind 是 5 筆(`0x8b,0xcf,0x03,0x8b,0xcf`)。v6 寫成「unbind 序列會不同(spike1 實測 5 筆)」。
- 照字面實作,只檢查 unbind 是否 5 筆,會在錯的地方對照。改寫成兩段的確切序列,翻轉段要求兩段都不符合 spike2 序列。

**m8 suite 名稱與 known-failures 條目現在就要定**
- classify 依 suite 名稱比對(E12)。§8 只寫「T1 / T2 / T3 各加一條 ERE」,沒有 suite 名稱,也沒寫 T1 是 tier A 的哪個 suite。
- 定下來,例如 `bt-autoflow-305`(T1)、`bt-uart-load-305`(T2)、`bt-rebind-305`(T3);ERE 用 `^FAIL pre-305 image: test not applicable to this kernel$` 錨定整行。

**m9 掃描型負載:補一次 rc 掃描段,或在範圍聲明加 ⚠️**
- 建議在 rc 上做一次 10 分鐘掃描段,方法:
  - 互動 bluetoothctl;
  - 等 `AgentManager1` 出現(例如先 `sleep 3` 或等 `Agent registered`)後才送 `agent off`;
  - 斷言 health `bondable=0` 後才 `duplicate-data on` + `scan on`;
  - 每 15 s 斷言 `bondable=0`;
  - 結束後確認 agent 已註銷、`bondable=0`。
- 這次只當一次性證據,不進 daily。
- 不做的話,§1 加一行:「出貨 rc 沒有在非請求式掃描負載下測過;依據是 spike1(相同 flow 邏輯)90 分鐘 0 溢位」。

**m10 `verify-rc.sh` 的 P2 檢查不能分辨有無**
- `grep -c 'if (hu->serdev)'` 印出 4,原始檔本來就有 3 處(E2)。改成 grep P2 的註解字串 `Batman #305: drop hardware flow control`,要求正好 1 處。§9 表格的描述已經是對的,只是腳本對不上。

**m11 `/dev/kmsg` 擷取的存活與起點**
- 30 分鐘的 `cat /dev/kmsg`:如果 ring 被蓋過,讀取端會拿到 EPIPE,busybox `cat` 會結束。擷取死掉 = 0 行 = 假 PASS。
- 修法:
  - 結束時要求擷取程序還活著,而且讀到的最後一筆序號 ≥ 結束時的序號(例如結束前寫一行 `/dev/kmsg` 標記,要求擷取檔裡看得到它);
  - 起點用 kmsg 的 seq / 時間戳過濾,不靠 `dmesg -c`。
- 這也讓 daily(沒有翻轉段)時的擷取有自我證明。

---

## 第 5 輪我自己的 MINOR 處理狀況

| A v5 | 狀態 |
|---|---|
| m1 dmesg ring 繞回 | ✅ 改擷取 `/dev/kmsg`;存活細節見 m11 |
| m2 `bo` / `fe` / `pe` | ✅ |
| m3 掃描負載沒有保證 | ✅ 改成不掃描,理由有實測(agent 競態);涵蓋度見第 4 點與 m9 |
| m4 agent / lease / 標記 | ✅ 不碰 bluetoothd,加 `bondable=0` 每 15 s。lease 有寫(T3);T2 的 lease 與標記在 m2 補 |
| m5 T3b 真負對照 | ✅ 大致;build 位置、綁定、還原見 m3 |
| m6 平台閘門 | ✅ 有板別判斷;要用 `na()`(m5) |
| m7 出貨產物 / main harness | ✅ |
| m8 nobody | ✅ `start-stop-daemon -c nobody` + uid 斷言 + `/proc/version` 正對照 |

## 審查過程的副作用(照實說)

- 節點上只跑了唯讀指令:`/proc/uptime`、`ps w | grep`、`/proc/tty/driver/serial`、`/proc/diskstats`、`/proc/loadavg`、`lsmod`,每台一次,25 s 逾時。
- 主機端在 WSL 重跑了 `verify-rc.sh`(只在 mktemp 解開產物,結束時刪除),並 grep build_dir 原始碼。
- 在 scratchpad `h305/revA6.sh` 留了一個小的 grep 腳本。
- 沒有寫入節點、沒有 kill 任何程序。04 的 PID 23267(E4)不是我啟動的,依規則沒有動它。
- round 5 我在 04 留下的 `grep -r`:這次 `ps` 沒看到,已經結束。

## 判定:**APPROVE-WITH-CHANGES**(0 / 0 / 11)

v6 不需要再整份重審。m1–m4 是實作 harness 時必須落實的規格(寫進 `bt-uart-305.sh` 的設計註解和 harness PR 的測試段),m5–m11 是小修。開工前先停掉 04 上殘留的 `dd`。
