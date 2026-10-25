# #305 mini UART 硬體流量控制(P1 + P2)設計 v6 — 對抗式審查 B(第 6 輪)

審查對象:`305-mini-uart-flow.md` v6(整份重審,重點 §8、§9)。
對照:使用者全域規則;Batman main a62bf78(`daily-validation.sh:2704-2711`、`validation-known-failures.txt`、`scripts/node/tmp-trust-280.sh:19,56`、`scripts/node/ble-lib-254.sh` deadman/lease);firmware 本機分支 `feat/305-autoflow` 1524084e;rc 產物 `~/out/1.5.13-wsl.1+0328e83.fw1524084/ekh-bcm2711/`;`scratchpad/r305/` 原始紀錄(`t2load-old-noscan.log`、`t2load-old-direct.log`、`t2load-*.sh`、`spike-a.log`、`spike2.log`、`auxmod/r305raw.c`、`hciflood/main.go`)。
節點:02 / 04 只做唯讀(`/etc/batman-build`、`ps`、`/proc/modules`、`/etc/modules.d`、`/proc/tty/driver/serial`、`dmesg | grep -c`、`ls -l /dev/kmsg`、`start-stop-daemon --help`、`command -v batman-slot`、provhelper health)。沒有任何寫入、kill、insmod、rebind、重開。

## 結論:**APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 10 MINOR**

- **兩個 patch 仍可凍結。** 分支上的檔案 sha 核過:P1 `c002892bfd20…`、P2 `60e0cdc74934…`。bcm2711 build_dir 的 `hci_bcm.c:561` 有 `if (hu->serdev)`,而且 `hci_bcm.o`(22:02:46)比 `.c`(21:53:18)新;`8250_bcm2835aux.c` 有 `DEVICE_ATTR_ADMIN_RO(autoflow)` 與 `dev_groups`(2 處相符)。我第 5 輪 m8 說 P2 v5「沒有在任何 kernel 上編過」,這點現在已關。
- **我第 5 輪的 MAJOR(標記短路讓負對照變空)已實質關閉。**
  - T2 翻轉(`r305raw cntl=0x03`)會讓同一份判定在同一個 rc kernel 上跑在舊硬體條件下。P1 的 `update_flow` 只在算出的值和快取不同時才寫,`hciflood` 用 raw HCI socket、不碰 termios,所以 0x03 在整段負載期間都會留著。
  - T3 翻轉(不含 P2 的模組)有實測可以預測結果:`spike-a.log` 的 unbind 是 2 筆(`0x8b,0x03`)、bind 是 5 筆;`spike2.log` 的 unbind 是 1 筆(`0x03`)、bind 是 4 筆。兩段都不同,所以序列判定一定會被觸發。
  - T1 的 nobody 機制有正對照。「沒翻過來就判無效 = FAIL」是 fail-closed。
  - 剩下的缺口是「翻轉要逐條判定證明」(m1):翻轉 FAIL 只要求「任何一條 FAIL」,所以壞掉的 `oe` 解析還是可能被 kmsg 那條蓋過去。這是 v5 M1 想抓的同一類錯,但現在至少有一條真判定被證明會 FAIL,而且修法只是一句規格。所以我降為 MINOR,前提是這一版就修。
- **⚠️ 現場狀況(請 caller 立即處理,不是我能動的):04 上有一個 `t2load-noscan.sh` 留下的 SD 直接讀取迴圈還在跑**(見 E1)。brief 說兩台都「idle」,這不成立。

---

## 查證

| # | 事實 | 證據 |
|---|---|---|
| E1 | **04 上還在跑 T2 證據收集留下的負載** | 04 `ps`:`23267 root sh -c while :; do dd if=/dev/mmcblk0p2 of=/dev/null bs=64k iflag=direct …; done`,以及它的子程序 `678 dd …`;load average 1.26 / 1.41 / 1.43(02 是 0.15)。<br>`t2load-noscan.sh` 啟動 `L=$!` 之後**從來沒有 kill**。<br>`t2load-old-noscan.log` 最後一行把殘留印出來了,腳本照樣正常結束(`grep … \|\| echo "no load left"` 只是印字) |
| E2 | 舊 kernel、不掃描的負載強度 | `t2load-old-noscan.log`:600 s 內 `oe` 33→40(+7)、Frame 23→24(+1)、tx timeout 27→34(+7)、hciflood 19445 B/s、miss 7、`sd_rd` +44,416,237 sectors。<br>有掃描的版本(`t2load-old-direct.log`)是 `oe` +18、Frame +11、txto +12。<br>不掃描時 `oe` 和 tx timeout 多,但 Frame 只有 +1 → 三條判定並不一起出現 |
| E3 | 04 目前的計數 | `/proc/tty/driver/serial`:`rx:34279022 oe:40`(hciflood 結束後 rx 只多 15 B;只有 SD 負載、沒有 RX 流量時不會溢位);health:`bondable=0 privacy=1 sc=1 sc_file=1` |
| E4 | `r305raw` 的寫入值與生命週期 | `r305raw.c:29` `writel((cntl & 0xff) \| 0x1)`,只保留 RXEN(第 2–3 行註解寫「keeping RXEN\|TXEN」,和程式碼不符),所以 `0xcc → 0xcd`、`0x03 → 0x03`。<br>`init` 回傳 0、`exit` 是空函式 → **模組會一直載著**;第二次 insmod 會以 `File exists` 失敗,不會注入 |
| E5 | rebind 序列(翻轉的預期值) | 見上方結論第二點,數字來自 `spike-a.log:7`(`while-unbound writes=6` / `after writes=11`)與 `spike2.log:5`(`writes=5` / `9`) |
| E6 | `start-stop-daemon` | 兩台都是 BusyBox v1.36.1,有 `-S -c USER -n NAME -a NAME0`。<br>`tmp-trust-280.sh:19` 已有可用的用法:`NB(){ start-stop-daemon -S -c nobody -n tmptrust280 -a /bin/sh -- -c "$1"; }`,`:56` 斷言 `id -u` = 65534。<br>`-x` 依 help 是比對 `/proc/PID/cmdline`,所以用 `-n <唯一名稱>` 比用 `-x /bin/cat` 安全 |
| E7 | `/dev/kmsg` | 兩台都是 `crw------- root`(harness 以 root 讀,沒問題) |
| E8 | 模組載入 | `/etc/modules.d/batman-bt` 會載 `hci_uart`;`hci_uart 32768 0`(refcnt 0)、依賴 `btbcm`、`bluetooth`。<br>`/sys/module/module/parameters/sig_enforce` 不存在;兩板 `.config` 都是 `# CONFIG_MODVERSIONS is not set`。<br>→ 任何 6.6.138 aarch64 的 `.ko` 都 insmod 得上 |
| E9 | `batman-slot` | 兩台都有 `/usr/sbin/batman-slot` |
| E10 | **bcm2710 還沒有用這兩個 patch build 過** | bcm2710 build_dir 的 `8250_bcm2835aux.c` 裡 `autoflow` / `dev_groups` 出現 0 次;`.o` 的日期是 2026-10-02。<br>`~/out` 只有 bcm2711 的 rc 產物;`305-rc1-build.log` 只寫 `for ekh-bcm2711`。<br>bcm2710 `.config` 沒有 `CONFIG_BT_HCIUART_BCM`(§9 的「P2 在那裡不會編」正確) |
| E11 | build stamp | rc `batman-build.txt`:`BATMAN_DIRTY=0`、`BATMAN_FW_COMMIT=1524084`、`BATMAN_FEATURES` 含 `mini-uart-autoflow(#305)`。WSL 內 `git status` 是乾淨的(從 Windows git 看到的 `M` 是換行假象) |
| E12 | known-failures 規則 | `NEVER_KNOWN='restore\|cleanup\|CONNECTION-LOST\|…\|not verified\|…'`(`daily-validation.sh:2704`)。§8.4 的句子 `FAIL pre-305 image: test not applicable to this kernel` 不含這些字 ✅ |

---

## MINOR

**m1 — 翻轉段要逐條判定證明,不能只要求「整份 FAIL」(v5 M1 的殘留)。**
- **情境**:T2 的判定有四條獨立的子判定:`oe/fe/pe/bo` 解析、kmsg 的 Frame / tx timeout、探測、負載保證。假設實作把 `oe` 的解析寫錯,一律讀成 0。翻轉時 kmsg 的 tx timeout 照樣 +7(E2),整份還是 FAIL → 判成「翻轉有效」→ 壞掉的 `oe` 判定進了 main。
- E2 顯示這三種錯並不一起出現:不掃描時 Frame 只有 +1。所以單靠 kmsg 不能保證 `oe` 解析是對的。
- T3 也一樣:翻轉若因「探測失敗」而 FAIL,序列比對有沒有寫對就沒被證明。
- **修法**:
  - 翻轉段的報告要逐條列出子判定的結果。
  - T2 翻轉時,`oe` 增量、kmsg(Frame 或 tx timeout)**各自**都必須 > 0,翻轉才算有效。
  - T3 翻轉時,必須是「序列不符」這一條 FAIL(預期 unbind `0x8b,0x03`、bind 5 筆;E5)。
  - 只有負載保證或探測 FAIL → 判無效。

**m2 — 注入有沒有生效、是否一直保持,要斷言;`r305raw` 會一直載著(E4)。**
- **T3b 可能空轉 PASS**:前一次(T2 翻轉或中斷的 run)留下 `r305raw` → 這次 insmod 以 `File exists` 失敗 → 沒有注入 → unbind 很快 → 「< 5 s」PASS。
- spike2 當時有在 unbind 前斷言 `hw=0xcd cache=0xcf tx_fill=4`(`spike2.log:8`),但 v6 的 T3b 沒寫這一步。
- **修法**:
  - 每次注入前,`/proc/modules` 不得有 `r305raw`;注入後立即 `rmmod r305raw`。
  - T3b 在 unbind 前斷言 `hw=0xcd`、`cache=0xcf`、`tx_fill>0`,不成立就判無效 = FAIL。
  - T2 翻轉在開始與結束時斷言 `hw=0x03 cache=0xcf`,證明整段都在舊條件下。
  - T2 正常段在開始與結束時斷言 `hw=cache=0xcf`。這樣能抓到「上一輪翻轉沒還原」:結果仍是 fail-closed,但歸因會正確。
  - 順便修正 `r305raw.c` 第 2–3 行的註解。

**m3 — 負載與殘留的清理要用 process group,殘留 = FAIL;04 的現況證明了這一點(E1)。**
- §8 的「確認沒有殘留」,在 scratch 腳本裡只是印字。
- **修法**:
  - 每個負載各自 `setsid`,記下 pgid,結束時 `kill -TERM -<pgid>`,等 10 s。
  - 用 `ps` 找 `dd if=/dev/mmcblk0`、`hciflood`、`r305raw`(`/proc/modules`);有殘留就印 `FAIL … cleanup: leftover …`。`cleanup` 屬於 `NEVER_KNOWN`,所以不可能被列成 known。
  - 負載也要納入 ble-lib 的 `kill_run_groups` / deadman,harness 斷線時才會被收掉。
  - **另外**:請 caller 現在就停掉 04 上的 pid 23267(先 INT 再 TERM,依使用者的程序安全規則),然後用 `ps` 確認。它會持續佔用 SD 頻寬、增加 IRQ 延遲,所有在 04 上跑的測項(包括另一位審查者的唯讀判斷,以及之後的 rc 驗證)都在一個不乾淨的基準上。

**m4 — `/dev/kmsg` 擷取的起點、溢位與存活要寫成規格。**
- `open(/dev/kmsg)` 會從 ring 裡最舊的那筆開始讀,不是從「現在」開始。
- reader 落後、紀錄被覆寫時,`read` 回 `EPIPE`;BusyBox `cat` 會直接結束,之後的錯誤就靜默漏掉,這是 fail-open。
- **修法**:
  - 開始時以 root 往 `/dev/kmsg` 寫一行唯一標記(`bt-uart-305 start <run_id>`),只計標記之後的行。
  - 結束時再寫一行結束標記。結束標記沒被讀到,或擷取程序已經不在 → FAIL。
  - 擷取檔放在 #280 的 root-only run dir。

**m5 — 每天跑的 T3 的 deadman 不能是固定 5 分鐘。**
- 10 次 rebind,每次最多 5 s + 20 s,再加上「失敗再 rebind 一次」,最壞約 250–300 s。一個慢但合法的 run 可能在 rebind 途中被 deadman 重開。
- **修法**:沿用 ble-lib 的 `arm <secs>`,每次 rebind 前延長 lease 並更換 deadman;總時限依迭代數推算。

**m6 — 載入 `.ko` 的信任邊界。**
- 沒有 MODVERSIONS、沒有 `sig_enforce`(E8):root insmod 任何檔案,等於任意 kernel 程式碼。
- T3 / T3b 的「不含 P2 的 `hci_uart.ko`」與 `r305raw.ko` 由 harness 上傳。如果放在 `/tmp` 這類非 root 也能寫的地方,本機非 root 程序可以在「比對 sha」和「insmod」之間把檔案換掉(TOCTOU)。
- **修法**:
  - 只放在 #280 的 root-only run dir(0700、root 擁有、`lstat` 確認不是 symlink、link count = 1)。
  - 在節點上、insmod 前一刻,用 `sha256sum` 比對 SHA256SUMS 裡依 `BATMAN_FW_COMMIT` 分組的值;不符就 FAIL、不 insmod。
  - 這條要寫進 §7 安全表的「root / 我們自己的錯」那一列。

**m7 — 過渡期:T3b、T4 在 pre-#305 節點上的行為沒寫(v5 m6 第三點未處理)。**
- §8.4 只為 T1 / T2 / T3 加 known-failures。T3b 在 wsl.15 上會真的注入,然後等 30 s → FAIL → **NEW**,而且每天的破壞性全套都會出現。
- **修法**:T3b 也走同一個標記短路,並補一條 known-failures;或者寫明它在過渡期就是 NEW、由使用者接受。T4 沒有「應有 / 不應有」之分,寫明不短路即可。

**m8 — T1 / T5 的判定本體也可以低成本翻轉。**
- T1 目前只有正對照與「檔案不存在」,`hw≠cache`、`hw≠0xcf` 這兩條從沒 FAIL 過。修法:在 T2 翻轉狀態(`hw=0x03 cache=0xcf`)下跑 T1,必須因 `hw≠cache` FAIL。
- T5 可以白箱翻轉:餵判定函式一份「有標記」的假 build 檔,配上 `autoflow` 不存在的 slot,必須 FAIL。

**m9 — T2 的門檻只在 04 量過。**
- SD ≥ 1,000 萬 sectors / 5 分鐘、rx ≥ 10 KB/s、翻轉時的溢位率,都只有 04 的單一 10 分鐘樣本(E2)。§8 寫「先 04、再 02」,但 02 的 SD 卡速度與翻轉 FAIL 都沒有數據。
- 門檻偏高時是 fail-closed(假 FAIL),不會漏判,但會讓 02 的 T2 變成每天的假 FAIL。
- **修法**:harness PR 證據裡,02 也要有一次翻轉輸出,並附 SD 實際讀取量。
- **場景覆蓋**:「不掃描」我接受。溢位的機制是「IRQ 延遲 × RX 位元組」,和封包是哪一種無關。舊 kernel 不掃描仍有 `oe` +7 / 10 分鐘。掃描型的事件流已有 spike1 的 90 分鐘證據,T7 另外覆蓋原始症狀。以 30 分鐘、預期約 20 次來看,翻轉落空的機率很低;而且翻轉本身每次都在量分辨力,只要套用 m1 的逐條要求就夠可靠。

**m10 — 文件小項。**
- **§9 bcm2710 的說法超出證據(E10)**:原文「P1 在 bcm2710 只確認原始碼套上、build 成功」,但 bcm2710 根本還沒用這兩個 patch build 過。改成「❌ 未做:firmware PR 前要做 bcm2710 實編(同一棵樹兩板出貨),確認 P1 套上、`-Werror` 通過」,並放進 §9 的檢查表。
- **§9 檢查表**:
  - 「`hci_uart.ko` 與 wsl.15 不同」沒有分辨力。改成我已核過的兩項:「`hci_bcm.c` 有 `if (hu->serdev)`(:561)」、「`hci_bcm.o` 比 `.c` 新」。
  - 加上分支上兩個 patch 的完整 sha256。
  - **以上加完,§9 足以開 harness branch。** 開機見證(T1 / T3 / morse)本來就在 rc 上做。
- **T3 翻轉的說明**:原文「unbind 序列會不同(spike1 實測 5 筆)」不準確。5 筆是 bind;unbind 是 2 筆 vs 1 筆。照 E5 改寫。
- **§6「`hci_uart` rmmod / modprobe 等同 rebind,T3 涵蓋」**:T3 走的是 sysfs unbind/bind,沒有走 rmmod。rmmod 路徑第一次會出現在 T3b 負對照。改成「T3b 負對照首次涵蓋;deadman 保底」。

---

## 各面向逐項

**擁有權**:
- CNTL 的第二寫者(`r305raw`)只出現在手動翻轉與 T3b。§5 已寫明,用完要重開還原。
- 新增的資源:`r305raw` 的模組槽(m2)、負載程序群組(m3)、kmsg 擷取程序(m4)、上傳的 `.ko`(m6)。§5 / §8 要寫明它們的擁有者都是「該 run 的 lease 持有者」,收尾與 deadman 都要涵蓋。

**契約**:
- `--flip` / `--force` 只能手動使用,在 daily-validation 底下拒絕執行 ✅。
- 「翻轉沒翻過來 = 無效 = FAIL」✅,但要逐條判定(m1)。
- known-failures 的句子 ✅(E12)。

**生命週期(harness 自身)**:
- 斷線:T3 有 setsid + deadman ✅;T2 的負載沒納入 deadman(m3)。
- 當機 / 重開還原:insmod 不寫 rootfs,重開時 `modules.d/batman-bt` 會載回原版(E8)✅。
- 重跑時的殘留:m2、m3。
- 板別:bcm2711 才跑,其他板 SKIP ✅。

**證據**:
- 新的負載證據逐行核過(E2)。
- rc 的原始碼與 build 時序核過(結論第一點)。
- bcm2710 的說法超出證據(m10)。

**安全(逐 actor)**:
- 遠端:不變。
- 本機非 root:sysfs 0400,檢查方式有正對照 ✅;上傳的 `.ko` 有 TOCTOU 風險(m6)。
- 被入侵的 peer:碰不到。
- 我們自己的錯:殘留負載(E1 已實際發生)、空轉的注入(m2)。
- 秘密:無新增。

## 判定

**APPROVE-WITH-CHANGES。**
- 兩個 patch 凍結,rc 產物可以用來開 harness branch(§9 先照 m10 改寫)。
- m1、m2、m3、m6 必須寫進 §8 再實作:前三個決定翻轉與注入是否真的有分辨力、是否 fail-closed;m6 是安全邊界。
- 其餘可以在同一版文字修正。
- 不需要再一輪完整重審;由下一份 harness PR 的證據(逐條翻轉輸出)驗收。
- 04 的殘留程序請先處理(m3)。
