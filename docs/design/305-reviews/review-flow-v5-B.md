# #305 mini UART 硬體流量控制(P1 + P2)設計 v5 — 對抗式審查 B(第 5 輪)

審查對象:`305-mini-uart-flow.md` v5(整份重審)、P1 `999-batman-bcm2835aux-autoflow-305.patch`(sha256 `c002892b…` ✅ 已核)、P2 `999-batman-hci_bcm-close-flow-305.patch`(`60e0cdc7…` ✅ 已核;spike2 跑的是 `.v1.patch` `73ee8d01…`)。
對照:使用者全域規則;BlueZ 5.72 原始碼(build_dir);Batman main a62bf78 的 `daily-validation.sh`、`validation-known-failures.txt`、`scripts/node/ble-lib-254.sh`、`feed/batman-prov/src/health/health.go`;firmware `build-3aplus` 72814fa4 的 `batman-release.env`、`scripts/stamp-batman-build.sh`;kernel build 樹(**目前仍是 spike2 版**:`8250_bcm2835aux.c:211 DEVICE_ATTR_RO`、`hci_bcm.c:560` 無 `if (hu->serdev)`);`scratchpad/r305/` 原始紀錄(`t2load-old.log`、`t2load.sh`、`hciflood/main.go`、`floodab.log`、`spike2.log`)。
節點:02 / 04 只做唯讀(`/etc/batman-build`、`/etc/passwd`、`/proc/modules`、`modinfo`、`/sys/module/hci_uart/`、`/proc/tty/driver/serial`、`ps`、`/tmp/run/batman/batman-prov.health`)。沒有 bluetoothctl、沒有寫入、沒有重開。

## 結論:**REJECT(範圍窄)— 0 BLOCKER / 1 MAJOR / 8 MINOR**

- **兩個 patch 的程式可以凍結。** P2 v5 和 v1 的差別只有 `if (hu->serdev)` 一行加註解與標頭文字(diff 已核);P1 c002892b 與 v1 的差別只有 sysfs 註冊方式(diff 已核)。我沒有找到新的程式缺陷。
- **我第 4 輪的 MAJOR(T2 的 adv-fast 做不出來)已關**:v5 不再靠廣播,改用 DUT 自己的 `hciflood` + `duplicate-data` 掃描 + SD 讀取,不需要對端、不需要 interval 回讀,擁有者問題消失。舊 kernel 的負載證據 `t2load-old.log` 我逐行核過:10 分鐘 `oe` 0→15、Frame 12、tx timeout 15、`hciflood` 17790 B/s、`sd_rd` +3,148,310 sectors。
- **唯一的 MAJOR 是新的**,而且是 v5 自己造成的:§8 第 4 點的「沒有標記就立即 FAIL、不跑負載」讓 harness PR 要附的「wsl.15 FAIL」只證明了「標記不存在」,T2 / T3 / T1 的實際判定程式碼在 merge 前**沒有任何一次**被證明會在真的壞掉時 FAIL(M1)。修法不改 patch,只在 harness 加一個翻轉模式。

### 第 4 輪 B 的項目是否已處理

| B v4 | 狀態 | 證據 / 備註 |
|---|---|---|
| M1 T2 adv-fast | ✅ 已關 | 見上。但負對照的有效性被 §8.4 的短路吃掉 → 新 M1 |
| m1 P1-only 真負對照、P2 標頭 | ✅ 標頭已改(「on a kernel without either patch」「120 ms measured with both patches」);T3b 已加不含 P2 的 `hci_uart.ko` | 機制還缺三點 → m3 |
| m2 rebind 後安全狀態 | ✅ T3 斷言 privacy / secure-conn / 無 bondable | — |
| m3 serdev 限縮 | ✅ P2 v5 `if (hu->serdev)` | 但 v5 這版**沒有在任何 kernel 上編過或跑過**:build 樹仍是 spike2(`hci_bcm.c:560` 無條件呼叫)。rc 會是第一次 → T1 / T3 在 rc 上就是它的驗證,§1 表格的「`-Werror` 編譯通過」要註明是在哪棵樹、哪個 config |
| m4 known-failures 字句 | ⚠️ 大致處理 | 句子缺 `FAIL ` 前綴、T5 不需要短路 → m6 |
| m5 feature 標記 | ✅ 改用 `BATMAN_FEATURES` | 標記是手寫、而且所有板共用一值 → m5 |
| m6 順序 | ✅ | 缺「出貨產物 ≠ rc 時重跑」→ m7 |
| m7 T3b / T4 進全套 | ✅ | — |
| m8 r305raw 只編一次 | ✅(比 `uname -r` 與 vermagic) | 但同樣的「只比 vermagic」**不能**套到 T3b 的 `hci_uart.ko` → m3 |
| m9 build 驗證 | ✅ 大致 | 「`hci_uart.ko` 的 sha 和 wsl.15 不同」沒有分辨力(任何重編都不同)→ m8 |
| m10 行號 | ⚠️ 小 | R4 的 `bcm_open :491 → :504 → :507`:原始樹的 `hci_uart_set_flow_control` 在 `:489`(false)、`:491`(true)、`:507`(false)(P2 的 hunk 在 `:551` 之後,所以 spike 樹這幾行和原始樹相同);`:504` 不是呼叫點 |

---

## 查證

| # | 事實 | 證據 |
|---|---|---|
| E1 | bluetoothctl 一啟動就會自動註冊 agent | `client/main.c:3186-3189`:沒給 `--agent` 時 `auto_register_agent = ""`;`:486-494` 看到 `AgentManager1` proxy 就 `agent_register`(只有 `NON_INTERACTIVE` 才跳過) |
| E2 | stdin 要等 client ready 才接上,所以 `agent off` 一定晚於自動註冊的「送出」 | `main.c:3168-3171` `client_ready → setup_standard_input()`;`main.c:101` `bt_shell_attach(fileno(stdin))` |
| E3 | **`agent off` 有競爭**:如果 `RegisterAgent` 的回覆還沒處理,`agent off` 什麼都不做,之後回覆到了 agent 就留著整個 session | `cmd_agent`(`main.c:1172-1179`)→ `agent_unregister`(`client/agent.c:455-460`)先看 `agent_registered`,而它只在 `register_agent_reply` 裡設成 TRUE(`agent.c:381`)。不成立就印 `No agent is registered` 然後 return;`auto_register_agent` 已經是 NULL,之後不會再有任何 unregister |
| E4 | 從原始碼看,只有「default agent」會讓 bluetoothd 打開 bondable | `src/agent.c:964-995` `register_agent` 只放進 `agent_list`;`add_default_agent → set_io_cap → adapter_set_io_capability`(`agent.c:136-151`、`adapter.c:9081-9090`:`AlwaysPairable=false` 時才設 BONDABLE)只在 `RequestDefaultAgent` 走到。**但** `254-stage1-impl.md:505` 記錄「互動式 bluetoothctl 註冊 agent,session 期間 current settings 會出現 `bondable`,04 實測」。兩者不一致,機制未明 → 只能靠觀測,不能靠推論 |
| E5 | `t2load.sh` 把 bluetoothctl 輸出丟到 `/dev/null`,所以 `agent off` 是否生效**沒有任何紀錄** | `t2load.sh:6` |
| E6 | 已有一個每 15 s 的 bondable 觀測點 | `health.go:138-140`:`batman-provhelper` 每 15 s 以 mgmt READ_INFO 寫 `/tmp/run/batman/batman-prov.health`,含 `bondable=0|1`;04 現在 `bondable=0` |
| E7 | 掃描對溢位的貢獻是實質的 | `floodab.log`:只有 hciflood + SD(CNTL 0x03)每 180 s 只多 1–2 次 `oe`;`t2load-old.log` 加上掃描後 600 s 多 15 次。掃描的位元組 = UART rx 增量 − flood 位元組 = 11,196,196 − 10,674,300 = 521,896 B / 600 s ≈ **870 B/s** |
| E8 | `BATMAN_FEATURES` 是手寫的一行,所有板共用 | `batman-release.env:5`「One value serves every board」、`:10`;`stamp-batman-build.sh:69` 原樣抄進 `/etc/batman-build`。04 wsl.15 的 `/etc/batman-build` 沒有 #305 標記 ✅(pre-#305 image 不可能帶著它,除非有人手改 env) |
| E9 | 既有的 #275 patch witness 只涵蓋 `patches/$BOARD/` 的 feed patch,不涵蓋 `target/linux/.../patches-6.6/` | `stamp-batman-build.sh:52-55`、`daily-validation.sh:815-842` `chk_patches_275` |
| E10 | known-failures 只看以 `FAIL ` 開頭的行;沒有 FAIL 行 = NEW | `daily-validation.sh:2708-2709` |
| E11 | 04 沒有 `su`;有 `start-stop-daemon`、`ujail`;`nobody` 的 shell 是 `/bin/false` | 04 唯讀探測 |
| E12 | `hci_uart` 可以 rmmod(refcnt 0,依賴 bluetooth、btbcm);`/sys/module/hci_uart/` 沒有 `srcversion`;vermagic 只有 `6.6.138 SMP mod_unload aarch64`,沒有 MODVERSIONS | 04 `/proc/modules`、`modinfo`、`ls /sys/module/hci_uart` |
| E13 | 04 上現在跑著 `batman-provhelper`(#254 P1),它只用 mgmt 讀 READ_INFO、不向 bluetoothd 註冊任何東西;`ble-ok` 每次開機只寫一次,rebind 不會撤銷 | 04 `ps`;`health.go:145-157` |
| E14 | `ble_state` 只把帶 `BATMAN_DV_BLE` 的程序和本次開機的 lease 當殘留 | `ble-lib-254.sh:142-160`、`:241-244` |

---

## MAJOR

### M1 — §8.4 的短路讓所有新判定的負對照都變成「標記不存在」;T2 / T3 / T1 的判定程式碼在 merge 前從沒被證明會 FAIL

**情境**:照 §8 實作 harness branch。第 3 步要附「wsl.15 必須 FAIL(負對照)」。但第 4 步規定:沒有 `mini-uart-autoflow(#305)` 標記就立即印 pre-305 句子並 FAIL,「不做任何 rebind 或負載」。wsl.15 沒有標記(E8),所以 T1、T2、T3、T5 在 wsl.15 上全部都在第一行就 FAIL。

- T2 表格的負對照寫「同一支腳本在 wsl.15 → FAIL,證據 `t2load-old.log`」。這兩句互相矛盾:同一支腳本在 wsl.15 不會跑負載;`t2load-old.log` 是 scratch 腳本 `t2load.sh` 的輸出,不是 harness 的 T2。
- 結果:harness PR 附上的「舊版 FAIL + rc PASS」對 T2 的實際判定(`/proc/tty/driver/serial` 那一行的解析、`oe` 欄位沒有 = 0 的規則、dmesg 計數、四個負載保證)完全沒有分辨力。只要 harness 的 `oe` 解析寫錯(例如 regex 對不上,一律當成 0),T2 在 rc 上一定 PASS,在 wsl.15 上也一定 FAIL,看起來完全正確,然後進 main。T2 是這次修正唯一的運行中回歸測試。
- T3 一樣:它的負對照是「spike1:5 筆」,但 spike 號碼已退役(VERSIONS.md:73-75),不能再燒;wsl.15 又被短路。T3 的序列判定也沒有被證明會 FAIL。
- T1 的「以 nobody 讀必須被拒」:OpenWrt 沒有 `su`(E11)。如果用來切換到 nobody 的機制本身失敗(找不到指令、`/bin/false` shell、ujail 參數錯),讀取「失敗」會被當成「被拒」→ 永遠 PASS。這是 A v4 m9 要的檢查,現在仍是空的。

這違反使用者規則「a claimed fix needs a negative control」與專案規則「新判定附舊版 FAIL + rc PASS」(`feedback_one_validation_set`)的本意:舊版 FAIL 要來自**判定本身**。

**修法**(不動 patch,只動 harness 設計;建議寫成 §8 的「翻轉段」,只在 harness PR 的證據與 rc 驗收時跑):
1. **T2 翻轉(同 kernel,只改一個因素)**:在 rc 上 init 完成後以 `r305raw cntl=0x03` 把 CNTL 壓回舊值(P1 的快取仍是 0xcf,而 `update_flow` 只在算出的值和快取不同時才寫,所以 0x03 會留著,和 §10a 舊 kernel 的條件相同),跑**同一支 T2 的判定本體**,必須因 `oe` / Frame / tx timeout 而 FAIL;結束後重開還原。T2 正常段要另外斷言 `hw == cache`,翻轉段則要求 `hw=0x03 cache=0xcf`,證明翻轉真的生效。
   - 替代做法:加一個只在 harness PR 證據裡用的 `BT305_IGNORE_MARKER=1`,讓本體在 wsl.15 上真的跑。報告標題會顯示 NOT CANONICAL。比上面弱:T1 / T3 在 wsl.15 上的 FAIL 只是「檔案不存在」。
2. **T3 翻轉**:用 T3b 已經要準備的「不含 P2 的 `hci_uart.ko`」跑一次 T3 的序列判定,必須因序列不符而 FAIL(E5 第 4 輪:沒有 P2 時 rebind 多一筆)。
3. **T1 的 nobody 檢查要有正對照**:同一個切換機制(例如 `start-stop-daemon -S -c nobody -x /bin/cat -- <file>`)必須讀得到一個 world-readable 的檔案(例如 `/proc/version`),才算機制有效。正對照失敗 → FAIL(不是 PASS)。
4. 翻轉段不翻(T2 在 0x03 下沒有 FAIL、T3 在不含 P2 的模組下序列相符)→ **整個測項判無效 = FAIL**,和 #254 夾心測試「翻轉段不外洩 → 全部作廢」同一規則。

---

## MINOR

**m1 — T2 的 `agent off` 不能保證沒有 agent;T2 也沒有寫 lease、`BATMAN_DV_BLE` 與 bondable 斷言。**
- `agent off` 有競爭(E1–E3):RegisterAgent 的回覆晚於 stdin 第一行時,agent 會留著整整 30 分鐘。就算沒有競爭,也有一段毫秒級的註冊窗口。
- 原始碼說非 default agent 不會打開 bondable(E4),但 #254 的 04 實測紀錄說會。機制未明,而 `t2load.sh` 把輸出丟掉(E5),所以「agent off 不碰 #254 安全狀態」目前**沒有證據**。
- 修法:
  - 掃描 session 的輸出寫進 run dir,斷言出現 `Agent unregistered` 或 `Agent registration disabled`;出現 `No agent is registered` 就判 FAIL(那就是競爭的情況)。或者改用 `bluetoothctl --agent=off`:RegisterAgent 會因為 capability 無效被拒(`src/agent.c:982-984`),一定不會註冊。但這是走錯誤路徑,要附一次實測輸出。
  - T2 期間每 15 s 讀 `batman-prov.health`(E6),全程 `bondable=0`;結束時再以 btprobe 的 READ_INFO 斷言 privacy / secure-conn / 無 bondable(和 T3 相同)。
  - T2 在 DUT 上取 BLE lease;三個負載都以 `bg_start`(帶 `BATMAN_DV_BLE=1`)啟動,這樣 `ble_state` 抓得到殘留(E14),並發的 BLE 套件也會被 lease 擋下,不會和掃描或 hciflood 搶 HCI。

**m2 — T2 的負載保證沒有證明掃描真的在跑;dmesg 計數會受 ring buffer 影響。**
- `hciflood` 單獨給的溢位壓力弱很多(E7)。如果 `menu scan / duplicate-data on / scan on` 沒生效,rc 上的 PASS 用的負載會比負對照弱。
- 修法:加一條保證「UART rx 增量 − hciflood 位元組 ≥ 400 B/s」(舊 kernel 實測 ≈ 870 B/s)。Frame / tx timeout 改用起點之後的 dmesg 行數(或 `dmesg` 的序號)計算,不要用整份 `grep -c`。

**m3 — T3b 的負對照模組:綁定、身分、無效判定、斷線還原都沒寫。**
- **綁定**:沒有 MODVERSIONS(E12),vermagic 對所有 6.6.138 都相同。一個用別棵樹(或別的 kernel patch 組合)編的 `hci_uart.ko` 也能 insmod 成功,結構體配置不同時會直接記憶體損壞。r305raw 只用 `ioremap` / `readl` / `writel`,所以「只比 vermagic」對它夠;對 `hci_uart.ko` 不夠。修法:這個模組必須和 rc 用**同一棵樹、同一個 firmware commit**,只把 P2 拿掉來編;SHA256SUMS 依 `BATMAN_FW_COMMIT` 分組;節點的 `BATMAN_FW_COMMIT` 對不上就 FAIL、不 insmod。每個改 kernel 的 rc 都要重編(和「r305raw 只編一次」不同,要寫清楚)。
- **身分**:`/sys/module/hci_uart` 沒有 `srcversion`(E12)。insmod 後節點上分不出載入的是哪一個。修法:負對照段的 unbind 必須 ≥ 25 s,否則整個 T3b 判**無效 = FAIL**(不是 PASS);同時記錄 insmod 前檔案的 sha。
- **步驟**:先 `rmmod hci_uart`(這一步本身跑的是現有含 P2 的 `bcm_close`,會關 port),確認 `/sys/bus/serial/drivers/hci_uart_bcm` 消失,再 `insmod <path>`(依賴 bluetooth、btbcm 都還在),等自動 bind 與 init,探測成功後才注入。OpenWrt 不會依 modalias 自動 modprobe,但要在步驟裡斷言 rmmod 與 insmod 之間沒有被重新載入。
- **斷線**:harness 若在 insmod 之後斷線,節點會帶著不含 P2 的模組直到重開。修法:在節點上以 setsid 執行,並先排一個到期就 `batman-slot reboot committed` 的 deadman(可沿用 lease 的 deadman 機制)。

**m4 — T3 每天在部署節點上 rebind,但沒寫由誰執行;斷線會讓節點停在 unbind。**
- 如果每一步都是 harness 端的 ssh,unbind 之後 ssh 斷掉,節點會一直沒有藍牙,直到有人重開。§8 的「再 rebind 一次;不行就重開」也假設 harness 還連著。
- 修法:整段 rebind × 10 寫成節點端腳本,以 setsid 執行,結果寫進 run dir;lease 的 deadman 的 restore 步驟要包含「hci_uart_bcm 沒有綁定就 bind;20 s 內探測失敗就重開」。

**m5 — `BATMAN_FEATURES` 標記的信任邊界寫清楚,並限定在 bcm2711。**
- 誰寫:人手改 `batman-release.env`,stamp 原樣抄進去(E8),不是從 patch 推導出來的;#275 的 witness 也不涵蓋 kernel patch(E9)。這沒問題,因為「有標記卻沒有 `autoflow`」= NEW,T3 的序列也會抓到「有 P1 沒 P2」。但 §5 的契約表要寫明:標記是**宣稱**,T1 / T3 才是**見證**。
- 一值給所有板:bcm2710 image 也會帶著這個標記,但 Pi 3 上沒有 BT 使用者(`[pi3] disable-bt`),mini UART 甚至可能沒有 probe。T5 在 bcm2710 bench 上會期待 `autoflow` 存在 → 假 FAIL。修法:T1 / T5 的期待改成「標記存在**且** `BATMAN_BOARD=ekh-bcm2711`」,bcm2710 標 N/A 並寫理由。
- 比對方式:以逗號切開後整個 token 相等,不要用子字串比對(要考慮 `(`、`#` 的跳脫)。

**m6 — known-failures 的字句與範圍。**
- §8.4 寫的是「印 `pre-305 image: test not applicable to this kernel` 並以 FAIL 結束」。classify 只看以 `FAIL ` 開頭的行(E10)。修法:固定成 `FAIL <suite>: pre-305 image (<BATMAN_VERSION>, no mini-uart-autoflow(#305)) — not applicable`,ERE 以 `^FAIL <suite>: pre-305 image ` 起頭。我核過,這句不含 `NEVER_KNOWN` 的任何字。
- **T5 不需要短路**:它自己的規則(沒有標記 → `autoflow` 必須不存在)在 pre-#305 的 slot 上本來就會 PASS。短路反而讓 T5 失去「pre-#305 slot 不該有 autoflow」這個真檢查。修法:T5 不短路,也不用 known-failures 條目。
- §8.4 說「所有新測項」都短路,但條目只列 T1 / T2 / T3 / T5。T3b、T4 也短路的話,要嘛補條目,要嘛寫明它們在過渡期是 NEW(在別張單的 release gate 上會出現)。

**m7 — 出貨產物和 rc 不同時的重跑,沒有寫。**
- 使用者規則第 8 步:出貨的不是驗證過的產物,就在出貨產物上重跑全套。firmware PR squash merge 之後,版本字串的 `fw<sha>` 會變;如果出貨 image 從 `build-3aplus` 重編(`1.5.13-wsl.N` 或 rel),就是另一個產物。
- 修法:§8 / §9 寫明:
  1. 第 5 步的全套從 **main**(harness 已 merge)跑在 rc 上,結果寫進產品 PR,之後才請使用者 merge 產品 PR;
  2. merge 後如果重編,在出貨 image 上再跑一次全套(含 T3b 的負對照模組要依新的 `BATMAN_FW_COMMIT` 重編,見 m3)。

**m8 — 文件內部不一致與小項。**
- §11 還列著「只有 P1、沒有 P2 在 0xcd 下的 close 時間沒有實測(推論 30 s)」,但 T3b 已經把它變成每個 rc 的實測負對照 → 改成「由 T3b 負對照實測」。
- §3 的「一次性補測:rc 上以 `r305raw` 設 0x8b,讓控制器斷電後 CTS de-assert,再 unbind 計時」沒寫怎麼做到。P2 在斷電**之前**就寫 0x03,FIFO 在幾百微秒內就送完了。要測的「AUTOCTS 開、控制器還上電但 RTS 一直 de-assert」需要一個不靠斷電、讓 CTS 維持 de-assert 的方法。不是把 BT_REG_ON GPIO 當第二個寫者,就是另想辦法。要嘛寫成具體步驟並放進 T 表,要嘛明說維持 ⚠️(手冊 Table 13 bit 3)、不做補測。影響只是 wedge 時 rebind 要等 30 s,不影響安全。
- §9 的「`hci_uart.ko` 的 sha 和 wsl.15 不同」沒有分辨力(任何重編都不同)。改成「build_dir 的 `hci_bcm.c` 有 `if (hu->serdev)` 這行,且 `hci_bcm.o` 比它新」;執行期的見證是 T3 的序列。
- §1 的「兩個 patch 都 `-Werror` 編譯通過」:build 樹目前仍是 spike2(E 開頭的說明),要寫明 c002892b / 60e0cdc7 是在哪棵樹、哪個 config 下編的;bcm2710 要等 §9 的實編。

---

## 各面向逐項(從現場用法出發)

**P1 / P2 程式**:與第 4 輪結論相同,沒有新問題。P2 的 `if (hu->serdev)` 和 `hci_ldisc.c:319-321` 的 serdev 分支一致;ldisc 路徑完全不碰(E3 第 4 輪)。

**T2(現場:BLE 範圍內大量廣播 + 主機忙)**:負載設計合理,而且不依賴 RF 環境。三個保證對兩個 kernel 都是 fail-closed:整行不存在 → FAIL;rx < 10 KB/s → FAIL;SD < 門檻 → FAIL。
- 舊 kernel 實測 rx 18.7 KB/s、SD 每 10 分鐘約 3.1 M sectors,遠高於門檻。
- `miss ≤ 1%` 在舊 kernel 上是 0.02%,所以它不是分辨條件,只是負載健康度,這樣用沒問題。
- 缺的是:掃描確實在跑(m2)、agent / bondable(m1)、判定本體的負對照(M1)。

**#254 安全狀態**:
- T3 的斷言 ✅。
- T2 的 `agent off` 只有推論、而且有競爭(m1)。
- provhelper 不向 bluetoothd 註冊任何東西,rebind 不會撤銷 `ble-ok`(E13),所以 §8 的「目前沒有 provd 註冊」前提在 wsl.15 上成立 ✅。

**過渡期與標記**:pre-#305 image 不會帶著標記 ✅(E8)。字句與範圍見 m6,板別見 m5。

**順序(harness branch → rc 1.5.13-wsl.1 → harness PR → 產品 PR)**:符合「測項只能有一套」:harness 先進 main,出貨只認 main 的全套。缺的是第 5 步全套與產品 PR 的先後,以及出貨後重跑(m7)。

**生命週期**:§6 我逐列對過。新增的缺口只在 harness 自己的生命週期:
- T3 / T3b 執行中斷線或當機(m3、m4);
- 板別(m5)。

產品端的路徑都有:install、start、stop、restart、OTA、rollback、downgrade、crash、斷電、各依賴重啟,以及各平台。

**安全(逐 actor)**:
- 遠端:⚠️ 預期改善,同意。
- 本機非 root:sysfs 0400 ✅,但檢查方法要有正對照(M1-3)。
- 被入侵的 peer / 容器:碰不到。
- 我們自己的錯:T3b 的負對照模組對不上會讓 DUT 記憶體損壞(m3);判定本體沒有負對照(M1)。
- 供應鏈:patch 套不上 build 就失敗 ✅;工具附 SHA256SUMS ✅。
- 秘密:無新增。P2 標頭的 `From:` / `Signed-off-by:` 是使用者自己的信箱,屬作者署名,不是秘密。

## 判定

**REJECT(範圍窄)**:
- P1 `c002892b…`、P2 `60e0cdc7…` 可以凍結,firmware 端可以照 §9 準備。
- 開 harness branch 之前,§8 要先加 M1 的翻轉段(T2 以 `r305raw cntl=0x03` 在 rc 上翻轉、T3 以不含 P2 的模組翻轉、T1 nobody 的正對照、翻轉不翻 = 無效)。這會改變 harness PR 的內容與證據形式。
- m1–m8 同一版修完;下一輪整份重審。
