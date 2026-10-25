# #305 mini UART 硬體流量控制設計 v5 + P1/P2 patch — 對抗式審查 A(第 5 輪,整份重審)

## 結論:**REJECT — 0 BLOCKER / 2 MAJOR / 8 MINOR**

- **兩個 patch 的程式:同意凍結。** P1 `c002892b…` 和第 4 輪相同;P2 `60e0cdc7…` 和 spike2 跑的 `73ee8d01…` 只差 `if (hu->serdev)` 與註解,Pi 上 `hu->serdev` 一律非 NULL(DT serdev),行為相同。
- **兩個 MAJOR 都在 §8 的測試設計,不在產品程式**:
  - M1:過渡期的 feature 標記短路,讓 harness PR 的「wsl.15 必須 FAIL」變成只驗了短路句,T2 偵測邏輯本身沒有負對照。
  - M2:T2 的「SD 讀取」負載實際上只有第一分鐘左右在讀 SD,之後都從 page cache 讀;負載保證 `≥ 1,000,000 sectors / 30 分` 一趟就達標,所以是存在性檢查。
- 兩個 MAJOR 修起來都不大(加 force 模式、`iflag=direct` 加分段門檻、重量 10 分鐘舊 kernel 基準)。不過依規則,MAJOR 還開著就要改設計再整份重審。
- round-4 的 MAJOR(B v4 M1)只關了一半:(1)(2) 已關,因為不再用廣播;(3) agent / lease / 標記的部分沒有完整帶進 v5(m4)。我自己第 4 輪的 m1–m9 都已處理(見最後一節)。

---

## 我自己查過的原始資料

| # | 事實 | 證據 |
|---|---|---|
| E1 | `t2load-old.log` 的 SD 讀取量剛好是 p2 一整趟 | `sd_rd` 706327 → 3854637,增量 **3,148,310** sectors。04 `/proc/partitions`:`mmcblk0p2 1572864` KB = **3,145,728** sectors。10 分鐘只讀了 p2 一次(另有約 2.6k sectors 是別的 IO) |
| E2 | dd 走 page cache,第二趟以後不碰 SD | `t2load.sh`、`xo2-tick.sh` 都是 `dd if=/dev/mmcblk0p2 of=/dev/null bs=64k`,沒有 `iflag=direct`。04 RAM 7966824 kB,p2 只有 1.5 GiB,cache 裝得下。p2 正是執行中的 rootfs(`/dev/mmcblk0p2 on /rom type squashfs`),一開始就有一部分在 cache 裡。Pi4 SD 約 40 MB/s,1.5 GiB 約 40 s 讀完,剩下 9 分多都是 memcpy |
| E3 | busybox dd 支援 direct | 04 `dd --help`:`[iflag=skip_bytes\|count_bytes\|fullblock\|direct]`(BusyBox 1.36.1) |
| E4 | T2 舊 kernel 有分辨力(以這個負載而言) | `t2load-old.log`:`oe` 空 → 15、frame 0 → 12、txto 0 → 15;flood `ok=41860 miss=9`(0.02%)、17790 B/s;UART rx 4349 → 11,200,545 ≈ 18.5 KB/s(約 80% 線速)。04 現在 `/proc/tty/driver/serial`:`oe:15`,和 log 相符。以每分鐘 1.5 次估,30 分鐘新 kernel 0 次的機率約 e^-45 |
| E5 | 02 的 dmesg ring 已經繞回 | 02 uptime 62249 s,`dmesg \| head -1` 是 `[13.396640]`,只剩 1223 行(`CONFIG_LOG_BUF_SHIFT=17`)。04(uptime 2186 s)還沒繞回 |
| E6 | `hci_uart` 換模組可行 | 兩台:`hci_uart 32768 0`(refcnt 0)、`btbcm 1 hci_uart`、`bluetooth 15 hci_uart,btbcm`;`# CONFIG_MODVERSIONS is not set`、`# CONFIG_MODULE_SIG is not set`、`modules_disabled=0`、沒有 lockdown。自動載入只有 `/etc/modules.d/batman-bt`(bluetooth / btbcm / hci_uart,開機時)。repo 裡除了 `halow-fi-263.sh` 的 mm6108 之外,沒有會 rmmod / modprobe hci_uart 的東西。04 的 `hci_uart.ko` md5 `0cb280a9…`,55568 bytes |
| E7 | unregister 順序 | `hci_serdev.c:395-413`:`hci_unregister_dev` → `hci_free_dev` → `proto->close`(`bcm_close`,P2 在這裡)→ `PROTO_READY` 才 `serdev_device_close`。P2 的 serdev 路徑(`hci_ldisc.c:319-323`)只用 `hu->serdev`,不碰已經 free 的 `hu->hdev` |
| E8 | bluetoothctl 的 agent 預設會自動註冊 | BlueZ 5.72 `client/main.c:3186-3189`:沒給 `--agent` 時 `auto_register_agent = ""`(非 NULL);`:491-494`:`AgentManager1` proxy 出現時,只要不是 `NON_INTERACTIVE` 就註冊;`cmd_agent off`(`:1173-1177`)才 unregister。piped 的 `agent off` 和 D-Bus proxy 出現誰先,沒有保證。`--agent off` 這個 CLI 參數會被當成 capability 字串 "off",不是關閉 |
| E9 | 板子共用同一份 feature 字串 | firmware `files/etc/batman-build:12` 的 `BATMAN_FEATURES=…` 是 base tree 共用檔;one-tree-both-boards(#209)→ bcm2710 image 也會帶 `mini-uart-autoflow(#305)` |
| E10 | 非 root 執行已有前例 | `scripts/node/tmp-trust-280.sh:56`:`start-stop-daemon` 以 nobody 執行,並斷言 `id -u` = 65534。節點沒有 `su` |
| E11 | spike2 的 0xcd 序列 | `spike2.log`:stuck `CNTL=0xcd tx_fill=4 cts_line=0`;unbind 120 ms,之後 `CNTL=0x03 tx_fill=0 cts_line=1`,writes 19 → 20(只多一筆 0x03 = P2 的 set_termios)。§3 / §4 的說法成立 |

---

## MAJOR

### M1 — 過渡期標記短路讓 harness PR 的負對照變空的(T2 最嚴重)

**情境**:實作者照 §8 寫。第 4 點:沒有 `mini-uart-autoflow(#305)` 標記 →「立即 FAIL,不做任何 rebind 或負載」。第 3 點:「wsl.15 必須 FAIL(負對照),兩份輸出附進 harness PR」。T2 的負對照欄:「同一支腳本在 wsl.15 → FAIL」。

這三句同時成立的唯一做法,就是 wsl.15 的 FAIL 只印出 `pre-305 image: test not applicable to this kernel`。那麼 T2 真正的判定程式碼從來沒有在會溢位的 kernel 上跑過:
- `oe` 解析(設計自己寫了「沒有 `oe:` 欄位代表 0」,這正是最容易寫成永遠 0 的地方);
- frame / txto 的計數差;
- 門檻比較。

這段程式和 `t2load-old.log` 的 `t2load.sh` 不是同一支。結果就是一個永遠 PASS 的 T2 可以帶著「有負對照」的標籤進 main。這違反「每個宣稱的修正都要有會在沒修時 FAIL 的測試」。T1 也一樣:「檔案不存在」那一支判定不會被執行到。

**修法**:
- 加一個只能手動使用的 force 開關(例如 `BT305_FORCE_PRE305=1`):
  - 開著時跳過標記判斷、照常跑完整測試;
  - 在 daily-validation 底下拒絕使用,或印出不在 known-failures 的另一句,避免被拿來繞過。
- harness PR 附的 wsl.15 負對照,要是 **force 模式的完整輸出**:
  - T2 必須以 `oe` / Frame / txto 增加判 FAIL,不是以負載保證不足判 FAIL;
  - T1 必須以「檔案不存在」判 FAIL。
- 標記短路句只當過渡期的 daily 行為。

### M2 — T2 的 SD 負載只在前約 1 分鐘存在,負載保證是存在性檢查

**情境**:T2 寫的是「SD 讀取」,保證寫成「mmcblk0 讀取 sectors 增量 ≥ 1,000,000 / 30 分(舊 kernel 實測 10 分鐘約 3,100,000)」。

E1 / E2 顯示,那 3.1M 剛好是 p2 讀一趟,之後的 dd 全部從 page cache 拿。所以:
- 30 分鐘的 T2,實際 SD IO(sdhci IRQ、block 完成的 softirq,真正會拉長中斷延遲的部分)只有前約 40–60 s;
- 門檻一趟就達標,SD 停了也不會 FAIL → 這是存在性檢查,不是負載保證;
- §8 那句「舊 kernel 實測 10 分鐘約 3,100,000」誤讀了自己的 log。§10a 的 `xo2-tick.sh` 是同一行 dd,所以 §10a 的「SD 讀取」大部分時間也不存在(⚠️ 已經標了,但原因寫錯)。

對翻轉證據本身影響不大:兩邊負載相同,`t2load-old` 仍然 10 分鐘 15 次溢位(E4)。影響在宣稱:報告會寫成「在 SD 負載下 0 溢位」,但現場的 SD 負載(log、OTS / docker 在 p6)沒有測到。這正是第 4 輪 MAJOR 要求的「負載保證要具體」。

**修法**:
- dd 改 `iflag=direct`(E3)。或讀比 RAM 大的範圍(整張 `mmcblk0`,31 GB),但要考慮讀到尾端時怎麼辦。
- 門檻改成**分段**:每 5 分鐘一段,每段 sectors 增量 ≥ 下限,任一段不足就 FAIL。下限以舊 kernel direct 模式實測值的一半訂。
- **重新量一次 10 分鐘舊 kernel 基準**:04 現在就在 wsl.15,同樣 rebind 後跑。負載變了,舊證據不能沿用;如果 direct IO 的 CPU / IRQ 型態改變了溢位率,也要記下來。
- §10a 的 ⚠️ 改寫成「dd 走 page cache,SD IO 只在第一趟」。

---

## MINOR

**m1 dmesg 計數在 02 上不可靠(E5)**
- T2 用 `dmesg | grep -c` 取前後差。02 的 ring 已經繞回,30 分鐘內最舊的行會被擠掉。
- 舊的 `Frame reassembly` 行被擠掉時,可能抵銷新增的行:差 ≤ 0 → 假 PASS。在 wsl.15 負對照上更可能發生,因為開機時就有舊錯誤。
- 修法:只數時間戳 > T2 開始時間的行,或用 klog 游標 / logread 的時間範圍;另外 after < before 一律 FAIL(這代表計數方法壞了)。

**m2 加上 `bo`(buf_overrun)與 `fe` / `pe` / `brk`**
- 有了硬體 RTS,瓶頸會從 FIFO 移到 flip buffer。範圍聲明說本 patch 不處理 `buf_overrun`,但 T2 應該**偵測**它:`/proc/tty/driver/serial` 的 `bo:` 增加就 FAIL,或至少列為獨立判定。不要只靠 Frame reassembly 間接看到。

**m3 掃描負載沒有保證**
- ≥ 10 KB/s 只靠 `hciflood` 就達標。現場真正的觸發是**非請求式**的廣播報告,但 `duplicate-data` 掃描有沒有在跑、送了多少,完全沒有量。
- 修法:`hciflood` 的 filter 再加 event 0x3e(LE Meta),計數 adv report。或用 mgmt 讀 discovering 狀態並計數,要求每分鐘 ≥ N 筆(以舊 kernel 實測訂)。
- 另外記錄控制器的 Data Buffer Overflow(0x1a)當資訊:AUTORTS 之後,控制器端丟廣播是預期的取捨,應該留下紀錄,不算 FAIL。
- 回答 brief 的問題:`hciflood` 是一問一答、一次一筆,加上 AUTOCTS / AUTORTS **不會掩蓋 H4 失步**,因為失步一定會留下 Frame / txto / `oe`;它掩蓋的只是「非請求式長時間背壓」,而範圍聲明已經標了 ⚠️。新 kernel 在這個負載下合法出現 `miss` > 1% 或 tx timeout 的情況,我推不出來:只有控制器長時間拉住 RTS(主機 CTS)超過 2 s 才會有 txto,真發生就是真問題,判 FAIL 是對的。`miss ≤ 1%` 在舊 kernel 也成立(0.02%),所以它只是「flood 真的有跑」的保證,沒有分辨力,這沒關係。

**m4 B v4 M1 第 (3) 點只帶進一半:agent 視窗、lease、標記**
- E8:piped 的 `agent off` 和自動註冊之間有競態,可能有短暫的 agent 視窗(`bondable` 會亮)。
- v5 的 T2 沒有寫:
  - 取 BLE lease;
  - 帶 `BATMAN_DV_BLE` 標記,讓 `ble_state` 認得;
  - 在前、中、後各斷言一次 mgmt current settings 沒有 `bondable`(btprobe 已經會印 settings 位元)。
- 修法:三點都寫進 T2;`bondable` 出現就 FAIL。如果競態真的會發生,改成等 `AgentManager1` 出現後再送 `agent off`,或另找不註冊 agent 的掃描方式。

**m5 T3b 真負對照的細節要寫死**
- `hci_uart.ko` 從哪來:最簡單的是 wsl.15 出貨的 `/lib/modules/6.6.138/hci_uart.ko`(04 md5 `0cb280a9…`)。它只比 rc 少 P2,P1 不改任何 `hci_uart` 看得到的結構;vermagic 相同,沒有 MODVERSIONS、沒有簽章(E6)。sha 記進 SHA256SUMS。
- 步驟:
  1. 確認 `refcnt` = 0;
  2. `rmmod hci_uart`(這一步本身走 P2 的 close,等同一次 unbind);
  3. `insmod <path>`;
  4. 等 init 完成、探測成功;
  5. 注入 0xcc、unbind 計時;
  6. 重開。rootfs 的 `hci_uart.ko` 沒動,`modules.d` 開機會載入有 P2 的那份。
- 順手:用這個非 P2 模組跑一次 T3 的序列判定,預期是 spike1 的 5 筆 rebind → FAIL。這樣 T3 也有了真負對照(現在 T3 的負對照只有舊證據)。
- 寫明負對照只在 harness PR 跑一次,還是每次 daily 破壞性項都跑(每次多約 30 s 再加一次重開)。

**m6 平台閘門(E9)**
- bcm2710 image 也會帶 `mini-uart-autoflow(#305)` 標記,但沒有 mini UART 藍牙,路徑 `fe215040` 也是 bcm2711 的位址。Pi 3 一回到 fleet,T1 / T3 / T5 就會印 `autoflow missing on a #305 image` = NEW。
- 修法:測項先依 board 判斷;非 bcm2711 印一句明確的 N/A,附 board 證據(不是乾淨 PASS)。或者把標記改成依 board 加入。

**m7 出貨產物與 harness 版本**
- 第 5 點只寫「rc 的正式驗收全套」。依全域規則第 8 步與記憶(正式驗收 = merge 加 pin bump 之後,用 main 的 harness 在出貨 image 上跑):
  - 若出貨的不是那個 rc 產物(例如重 build 或 pin bump),要在出貨 image 上用 **main** 的 harness 再跑全套;
  - 第 3 點用 harness branch 跑出的結果,只能當 PR 證據,不能當出貨判定(「出貨只認 main 的 harness」)。

**m8 T1 的「nobody 讀被拒」要真的以 nobody 執行**
- 節點沒有 `su`。沿用 `tmp-trust-280.sh:56` 的 `start-stop-daemon` 加 `id -u` = 65534 斷言(E10)。uid 不對就 FAIL,不能讓「讀不到」是因為根本沒切換身分而誤判 PASS。

---

## 生命週期 / 資源補查(先找缺漏)

| 路徑 | 判斷 |
|---|---|
| install / 首次開機、開機、rebind、OTA、rollback | §6 有,證據足夠(spike1 / spike2 log 我第 4 輪逐行對過;本輪抽查 spike2,E11) |
| clean stop / 關機 | §6 已更正為 port 不關,成立 |
| crash / crash loop | §6 有(hook 內 oops);tryboot 會退回,commit 後靠 watchdog |
| 斷電 | §6 有間接實證 |
| 依賴重啟:bluetoothd、hci_uart、btbcm / bluetooth | 前兩者有;btbcm / bluetooth 重載必須先 rmmod hci_uart,等同 rebind,可以併入 T3 列 |
| 降版 | T5 靠標記,方向正確(標記和 kernel 不一致時兩邊都 fail-closed:有標記沒 patch → T1 NEW;沒標記但有 patch → `autoflow` 不應存在 → FAIL) |
| 平台 | bcm2710 少了測項閘門(m6) |
| **新資源:T2 的三個負載程序** | 擁有者 = T2,以 process group 啟停、結束確認無殘留,有寫。lease / 標記缺(m4) |
| **新資源:非 P2 的 `hci_uart.ko`** | 擁有者 = T3b;只存在 tmpfs、重開還原。來源和驗證缺(m5) |

## 安全(逐 actor)

- **遠端 BLE**:不變。T2 不需要對端,沒有新增空中暴露面。
- **本機非 root**:`autoflow` 是 0400;`hciflood` 用 raw HCI socket,要 CAP_NET_RAW,只有 root 能用;非 P2 模組只有 root 能 insmod。沒有新的非 root 輸入。
- **受入侵的 peer / 容器**:沒有 `/dev/ttyS*`、沒有 CAP_NET_RAW,碰不到。
- **我們自己的錯**:
  - force 開關(M1 修法)本身是新輸入,必須確定 daily-validation 底下不能用;
  - 非 P2 模組萬一沒有重開還原,節點會留在「close 等 30 s」的狀態 → T3b 結束一定要重開,並在重開後驗證 `hci_uart.ko` 的 sha 是 rc 那份。
- **秘密**:無新增。

## 你指定的重點,逐項回答

1. **T2 對新 kernel 是否有效**:
   - 偵測面有效:失步一定留痕,hciflood 加 AUTO* 掩蓋不了;
   - 負載面有兩個洞:SD 幾乎不存在(M2)、掃描沒有量(m3);
   - 新 kernel 合法出現 `miss` > 1% 或 txto 的情況我推不出來,發生了就應該 FAIL;
   - 偵測程式本身沒有負對照(M1)。
2. **負載保證是否具體**:rx ≥ 10 KB/s 和 miss ≤ 1% 具體;SD 那條不具體(M2);掃描那條沒有(m3)。
3. **T3b 真負對照是否可行**:可行(E6、E7),細節見 m5。換模組本身就是一次走 P2 的 unbind,沒有額外風險;重開後由 `modules.d` 載回 rootfs 那份。
4. **BATMAN_FEATURES 標記**:T5 和過渡期判斷成立,兩個方向都 fail-closed。缺板別閘門(m6),而且標記短路吃掉了負對照(M1)。
5. **能不能開工**:
   - 可以先動、而且不受影響的:
     - firmware 端的 patch commit 和 rc `1.5.13-wsl.1` build(patch 已凍結);
     - harness 的 `btprobe` / `hciflood` / `r305raw` 打包。
   - 要等 v6 處理完 M1 / M2 才寫的:`bt-uart-305.sh` 的 T2 和過渡期邏輯。
   - M2 的舊 kernel 基準可以趁 04 還在 wsl.15 時先量(需要使用者授權:這會在 04 上跑負載並 rebind)。

## 第 4 輪我自己的 MINOR 處理狀況

| A v4 | 狀態 |
|---|---|
| m1 分不出 P1 v1 / v4 | ✅ T1 斷言 0400 加非 root 被拒;§9 比對 `dev_groups` 與 `if (hu->serdev)` |
| m2 T2 在舊 kernel 不短路 | ✅ 已短路,但連帶造成 M1 |
| m3 改 `ble-periph-254.sh` 要附回歸 | ✅ 不再改它 |
| m4 T5 版號比較 | ✅ 改用標記 |
| m5 AUTOCTS = 0 的模型邊界 | ✅ §3 補了原始碼論證、0x8b 一次性補測、T3b 真負對照 |
| m6 P2 的條件 | ✅ 只在 serdev |
| m7 斷電後 CNTL 回 reset 值 | ✅ §6 |
| m8 軟恢復送不出去 | ✅ §6、§11 |
| m9 0400 / `dev_groups` 的驗證 | ✅ T1 加 rc 開機 |

## 審查過程的副作用(照實說)

我在 04 上跑了一個唯讀的 `grep -r hci_uart /etc/init.d /usr/bin /usr/sbin /usr/libexec`,想找會重載模組的程式。它超過 120 s 沒結束,我停掉了本機那端,但 **04 上的 grep 還在跑**(PID 15421 `ash -c grep …`、PID 27157 `grep -rn hci_uart …`,最後一次看時是 R 狀態)。它只讀不寫,讀完會自己結束;規則禁止我在節點上 kill 程序,所以我沒有動它。如果在它結束前要在 04 上跑任何時間敏感的量測,請先確認它已經結束。

## 判定:**REJECT**(0 / 2 / 8)

patch 凍結、可以 build rc。§8 的 T2 和過渡期的負對照要改成 v6,再整份重審。下一輪重點只需要看 M1 / M2 的修法,以及 direct-IO 的新舊 kernel 基準。
