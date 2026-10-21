# 審查 B 第 2 輪:`254-h1-harness.md` v2(整份)

我獨立審了整份 v2,沒有和 A 協調。節點只做唯讀查詢:沒有跑 bluetoothctl 或 btmgmt,沒有建檔,沒有重啟任何東西,也沒有印出任何 IRK。

**結論:REJECT(窄)。0 BLOCKER / 4 MAJOR / 9 MINOR。**

第 1 輪我提的 5 個 MAJOR,方向都修對了:
- 主機擁有時間軸;
- 用拒絕原因判「擋下」;
- deadman + 狀態標記;
- P7 有了算法;
- eth 閘門與執行順序。

但這次重新設計引入了新的問題,其中 4 個是 MAJOR:
- btmon 的過濾規則會把判定要用的行全部丟掉;
- `rekey` 只驗檔案,沒驗 kernel 實際用的 IRK;
- 節點鎖只鎖單一指令,deadman 契約前後矛盾;
- N3 把沒有乙太網的 02 切到舊 build 並 commit,卻沒有救回路徑。

使用者 10-20 的決定(peer.py → H3、coex → P2、N3 做法)我不重新討論;M4 只檢查 N3 的**執行方式**是否安全。

---

## 0. 本輪驗證(✅ 有原始碼或實測)
| 項目 | 結果 |
|---|---|
| E8 `load_irk` | ✅ `adapter.c:4201-4223`:檔案裡沒有 `IdentityResolvingKey` 就 `generate_and_write_irk`。**另外查到**:`set_privacy`(`:4256-4283`)失敗時只在 `set_privacy_complete`(`:4242-4253`)記一行 `Failed to set privacy`,然後照常運作;kernel `mgmt.c` 的 set_privacy 在 `hdev_is_powered` 時回 `MGMT_STATUS_REJECTED`;bluetoothd 啟動流程(`:10340-10366`)**不會先斷電**,只有正常結束時的 `adapter_shutdown`(`:10915-10936`)會送 `SET_POWERED 0` → 見 M2 |
| E10 `adv_use_rpa` | ✅ `hci_sync.c:1046-1067`:basic privacy 下一律回 true,不論 connectable 與否 |
| RPA 何時刷新 | ✅ `hci_sync.c:5140`:hdev open(上電)時設 `HCI_RPA_EXPIRED`;`hci_event.c:1357`:Set Random Address 完成後才開始計時 → 見 m1 |
| btmon 輸出格式 | ✅ PR-F 的 `air-sandwich-04-btmon*.txt`:`LE Connection Complete (0x01)`、`SMP: Pairing Failed (0x05) len 1`、`SMP: Identity Information` **都是縮排的子行**,上一行才是 `< ACL Data TX` / `> HCI Event` 這種方向標頭 → 見 M1 |
| bluetoothctl `--timeout` | ✅ `src/shared/shell.c:1132` 有這個選項 → 見 m3 |
| `batman-slot rollback` / `reboot committed` | ✅ `batman-slot:731-741`:改 `autoboot.txt` 的 `[all]`;`:778` 起是 `reboot committed`;p5 = 兩槽共用的 OpenWrt overlay(`docs/storage-architecture.md:25`)→ 見 M4 |
| E6 非互動 bluetoothctl | ⚠️ 原始碼成立(`client/main.c:491-494`、`:3186-3189`);04 的實際輸出是作者跑的,我依規則沒有重跑 |

---

## MAJOR

### M1 節點端 snoop 過濾會丟掉四態判定所需的每一行;Reason 行失去上下文後會撞碼

**情境**:§4.7 規定過濾後只「保留事件行(`^[<>@=] `)與 `Reason:` 行,丟掉其他所有行」。實際的 btmon 輸出(PR-F 檔案)中:
- `LE Connection Complete (0x01)`、`SMP: Pairing Failed (0x05) len 1`、`SMP: Identity Information (0x08)` 都以 6 個空白開頭,是 `> HCI Event: LE Meta Event` 或 `< ACL Data TX` 底下的子行;
- 這些子行全部會被丟掉。

後果:
1. 「擋下」要求「恰好一個成功的 LE Connection Complete,且 04 **送出** Pairing Failed」。過濾後永遠找不到這兩樣 → 每一輪都是「無效」→ 測項必定 FAIL(假 FAIL)。
2. 外洩條件「04 btmon 有送出的 `SMP: Identity Information`」也被丟掉,外洩判定只剩 02 端那一條。
3. 留下來的 `Reason:` 行沒有所屬區塊與方向。同一輪會同時出現 SMP 的 `Reason: Authentication requirements (0x03)` 和斷線事件的 `Reason: Authentication Failure (0x05)`、`Reason: Unspecified (0x00)`(PR-F r1 檔第 9、12、13 行)。
   - N6 要分辨的「SMP `Pairing not supported (0x05)`」和斷線的 `(0x05)` 數字相同。只比數字就會撞碼,N6 可能因為錯的那一行而 PASS。
   - 「04 送出」這個方向條件也無從檢查:02 也會送 Pairing Failed,例如 PR-F 第 138 行的 `Numeric comparison failed (0x0c)`。
4. rpa 段的「任何 LE Connection Complete → 無效」也看不到,這個前提會靜默變成 PASS。

**修法**
- 過濾改成「區塊感知」:記住最近一行方向標頭(`^[<>@=] `),只輸出 `(方向, 子事件名稱)` 與 `(方向, SMP Pairing Failed 的 Reason 全文)`。子事件名稱白名單:`LE Connection Complete`、`LE Enhanced Connection Complete`、`Disconnect Complete`、`SMP: <名稱> (0x..)`。
- 一律丟掉帶值的行,例如 `Identity resolving key`、`Long term key`、`Public key` 與 hex dump。
- 判定改成比對完整文字,例如 `< SMP: Pairing Failed` 加上 `Reason: Authentication requirements (0x03)`,不只比數字。
- N10 的 stub 樣本要用 PR-F 的真實 btmon 片段(含縮排子行與斷線 Reason),並加一個「斷線 Reason 0x05 存在、SMP Reason 是 0x03」的撞碼案例。

### M2 `rekey`(以及 deadman / `restore`)只驗「檔案的雜湊變了」,沒驗 kernel 是否真的換了 IRK

**情境**:v2 用 `rekey`(停 bluetoothd → 刪 `identity` → 啟動)取代重開機來作廢外洩的 IRK,判斷成功的依據是 `identity` 的雜湊改變。但 kernel 只在**未上電**時接受新 IRK。bluetoothd 啟動時不會先斷電,只有正常結束時 `adapter_shutdown` 才送 `SET_POWERED 0`。以下情況 adapter 會帶電進入下一個 bluetoothd:
- 停止時 bluetoothd 卡住,procd 等 TERM 逾時後改送 KILL;
- bluetoothd crash 後被 respawn(§5 自己列了 `respawn 3600 5 0`);
- deadman 在 bluetoothd 不正常時觸發 `restore`。

這時的結果:
- 新的 bluetoothd 從 getrandom 產生新 IRK 並寫檔 → 檔案雜湊**改變**;
- `SET_PRIVACY` 被拒,只留一行 `Failed to set privacy: Rejected (0x0b)`;
- kernel 繼續用**已外洩的舊 IRK** 產生 RPA,`current settings` 仍顯示 `privacy`,tier A 全部通過;
- `rekey` 判成功 → `irk-exposed` 標記被刪 → 外洩的 IRK 實際上仍有效,報告卻說已作廢(**假 PASS**,而且影響安全)。

`batman-sc` 只記錄 SC 的結果,不記錄 privacy 的結果,所以也無法用它佐證。

**修法**(至少做第一項)
- `rekey` 收尾用 kernel 端的證據:04 以 non-connectable 廣播 30 s,02 取樣一次,主機 `ah()` 用**新** IRK 必須 match(新 IRK 照舊經 pipe 傳;舊 IRK 不留在主機,所以「舊的不 match」改由「新的 match」加上「新、舊雜湊不同」共同推得)。
- 停 bluetoothd 前先用已放上去的 `btmgmt power off`,確認 `powered` 不在 current settings 之後才刪檔、才啟動。
- 啟動後斷言本次 pid 的 log 沒有 `Failed to set privacy`(在 ring 內立刻讀)。
- deadman 的 `restore` / `rekey` 路徑也照此處理;如果無法驗證,就**保留** `irk-exposed` 標記,讓下一次 preflight 失敗,直到 04 重開。
- 加一個負對照:`kill -9 bluetoothd` 後直接啟動,再跑 `rekey` → 必須 FAIL,不能刪掉標記。

### M3 節點鎖只鎖單一指令,擋不住第二個 run;deadman 的「至多一個」與「每次改狀態前都 arm」互相矛盾

**情境**
- §4.7 寫「**每個指令**以 `flock -n …/lock` 執行」,所以指令和指令之間鎖是空的。rpa 的 (a) 段有 30 分鐘不下任何 04 指令;配對各輪之間也有空檔。第二個 run(或操作者的 `DV_ONLY` 重跑)只要落在空檔,每個指令都拿得到鎖 → 同時有兩個 run 寫 04 的 adv instance 1、`sc`,以及 02 的 cache。§5 宣稱「節點 `flock` 擋第二個 harness」不成立。
- deadman「每台至多一個」,而且「`dm_arm` 拒絕在已有活著的 deadman 時 arm」;但同一段又要求「**每一次**改變節點 BLE 狀態之前先 arm」。配對一輪內依序有 adv-on、btmon-start、flip,第二次 arm 就會被拒 → 測項 FAIL。如果實作改成先取消再重新 arm,兩步之間 harness 死掉就沒有 deadman。
- deadman 的動作(`restore` / `rekey`)沒有寫是否要拿鎖。它可能在 harness 的某個指令執行中觸發,例如每輪 300 s 加一次重做就會超時。

**修法**
- 改成**租約**:在 `ble-state/owner` 寫 `run-id boot_id expiry`,由 suite 開頭取得、結尾釋放。每個指令都要帶 run-id 並比對,不符 = FAIL「另一個 run 擁有 BLE」。`flock` 只用來保護「讀改寫租約」那一小段。
- deadman 改為「每台一個,可**原子替換**」:`dm_rearm <seconds> <action>` 在鎖內取消舊的並 arm 新的,只延長或替換,不留空窗。
- deadman 動作在執行前先取得租約,或確認租約已過期。
- 期限以「該段最長路徑(含重做一次)+ 餘裕」計算,並寫出每段的數字。
- §5 加一個測試:run 1 處於 (a) 段時啟動 run 2 → run 2 的第一個 BLE 指令必須 FAIL。

### M4 N3 讓沒有乙太網的 02 以 committed 方式開進舊 build,卻沒有救回路徑;副作用清單不完整

**情境**(不重議「要不要做 N3」,只看做法)
- N3 = `batman-slot rollback`(把 `[all]` 改到 slot B,`batman-slot:731-741`)→ `reboot committed`。02 會以 **committed** 的方式開進 wsl.2。
- 02 沒有乙太網(`eth0 carrier=0`,第 1 輪實測),主機只能經 04 → mesh 連到它。wsl.2 如果開不起來,或沒有回到 mesh,就**沒有自動退回**:它是 committed,不是 trial。救回只能靠實體接觸。使用者 10-18 的規則要求先寫好這種情況的處理。
- p5 是兩槽共用的 overlay(`storage-architecture.md:25`)。wsl.2 開機會在 wsl.9 寫過的 p5 上執行自己的 uci-defaults 與 migrate(96);回到 wsl.9 後讀到的是 wsl.2 動過的設定。副作用清單只寫了「重開兩次、p3 沒有 `core_freq_min`」。沒列出的有:`autoboot.txt` 被寫兩次(p1)、ota-trace / boot-reasons 的紀錄、p5 上可能被改的 UCI、slot B 的 BADMARK 狀態。
- 執行方式也有矛盾:preflight P3 要求「fleet 版本一致」,02 在 wsl.2 時 preflight 一定 FAIL,但設計沒說 N3 是用 `DV_PREFLIGHT=off` 還是單獨跑 suite。

**修法**
- 先唯讀確認 slot B:沒有 BADMARK、版本 = wsl.2、`batman-slot verify` 通過。
- 盡量用 one-shot tryboot 進 slot B:失敗就在下一次重開自動回到 A。同時寫清楚 autocommit 會不會把 wsl.2 commit 掉,以及怎麼避免。如果一定要用 committed,就寫明「N 分鐘內沒回到 mesh → 需要實體救回」,並請使用者在場。
- 列出 p5 在 wsl.2 開機前後的 UCI 差異(之前先存一份,之後比對),回到 slot A 後斷言兩者相同。
- 寫明 N3 怎麼跑:例如 `DV_PREFLIGHT=off DV_ONLY='ble-privacy-254|prov-tools-254'`,報告頁首會標示 BYPASSED,只當負對照證據。

---

## MINOR

**m1 T0 時 RPA 不一定是新的**。kernel 只在上電時(`hci_sync.c:5140`)或計時到期後產生新 RPA,計時從 Set Random Address 完成時開始(`hci_event.c:1357`)。如果 T0 前 900 s 內 04 已經有過 RPA(例如上一個死掉的 run 在 15 分鐘內重跑),T0+150 重新註冊時 RPA 可能已過期 → (b) 段看到兩個位址 → 假 FAIL。修法:T0 前先 `restore` 一次(斷電再上電,強制產生新 RPA),並記錄本次的 pid。

**m2 §11 對 B-M1 的對應不成立**。N5 寫「依 RPA 是否換新而定」。但依原始碼,在 **T0+900 之後**(例如 T0+1200)重新註冊,RPA 一定會換 → 判定必須 FAIL。這是有鑑別力的白箱注入。N5 應該固定在 T0+1200,預期 FAIL。T0+900 之前重新註冊不會換 RPA,這已經是 (b) 段本身在驗的事。

**m3 02 取樣的寫法自相矛盾,「看見」也沒定義**。「新的非互動 bluetoothctl `scan on` session 經 FIFO」:經由 FIFO 就是互動模式,會註冊 agent。應改用 `bluetoothctl --timeout 10 scan on`(`shell.c:1132`)。「看見」只算 discovery 開始後、帶 RSSI 的 `[NEW]`/`[CHG]` 行;session 一開始列出的 cache 裝置不算。也要說明 50 s 的間隔大於 bluetoothd 暫存裝置的 30 s 逾時,舊位址不會被當成新的看見而落入 (c) 段。

**m4 時間來源**。主機的「時間軸」要用單調時鐘;bash `SECONDS` 和 `date +%s` 會被 Windows / WSL 的校時跳動影響。量主機與節點 uptime 的差時,02 經過 mesh,ssh 來回延遲可能超過 2 s → 假 FAIL。改成取 N 次量測中 RTT 最小的那一次,門檻也要寫出理由。

**m5 P7 在剛開機的節點會假 FAIL**。開機那一陣(加上 bluetoothd 每行記兩次)很容易在 60 s 內超過 200 行。修法:uptime < 600 s 時改用「隔 10 s 讀兩次最後一行時間戳」,或排除比開機時間早的行;N8 補一個「剛開機」的 stub 案例。

**m6 `sh -s` 的 stdin 用途衝突**。腳本本身經 stdin 傳給 `sh -s`,但 `canary` 也要從 stdin 收 log;另外 `setsid` detach 出去的長時間工作需要呼叫 `ble-lib` 的函式,而腳本並不在磁碟上。節點端腳本應該放到 `bt/`(root 0700、檢查 owner、非 symlink、link count 1),之後以檔案路徑執行。

**m7 `canary` 的比對方式**。要不分大小寫(`grep -i`):btmon 的 hex 和 `identity` 檔的大小寫不一定相同。也要涵蓋以空白分隔的位元組格式(btmon 的 hex dump)。範圍應涵蓋整個 `$DIR` 和主機 console log,不只 BLE 的 log。

**m8 04 p3 的 `core_freq_min` 沒有證據**。fault-injection(在 tier B BLE 之後)可能把 04 留在 slot B,而 tier A 的 `ble-privacy-254` 在那之後才跑。設計只寫了 02 的 p3,04 的 p3 有沒有 `core_freq_min=500` 沒有證據(要掛載 p3 才看得到,我沒有做)。要嘛補上證據,要嘛把 tier A BLE 排在換槽 suite 之前,要嘛在 hci0 失敗時印出實際所在的槽和 p3 狀態。

**m9 `rekey` 契約寫了兩種說法**。§3 寫 `rekey` 只刪 `identity`;§4.5 收尾又寫「`rekey` 時刪掉該裝置目錄(02 的 IRK)」。04 是 bondable off,BlueZ 不會存 02 的資料;02 的 IRK 在 kernel 裡,斷電時由 `hci_smp_irks_clear` 清掉。統一成一種說法,並以「斷電」作為清除依據(這也和 M2 相關)。

---

## §11 對應抽查
| 第 1 輪發現 | 是否成立 |
|---|---|
| B-M1 時間軸、取樣、connectable | 大致成立;N5 的寫法不對(m2),取樣細節見 m3、m4,T0 新鮮度見 m1 |
| B-M2 擋下用代理訊號 | 判定邏輯成立,**但過濾規則讓它實作不出來**(M1) |
| B-M3 中途死掉、殘留、兩個寫入者 | 標記和 `ble-state` 成立;**鎖與 deadman 契約有破洞**(M3);`rekey` 取代重開機引入了 M2 |
| B-M4 P7 | 成立;剛開機的假 FAIL 見 m5 |
| B-M5 閘門與順序 | 成立(P4 要求 `BLE_PERIPH == DNODE`、eth 閘門、排在 ab-selftest 之前、只重開 04 一次) |
| B-m1 到 B-m12 | 成立,除了:B-m7 白名單已做,但 M2 是新的;B-m6 的 02 IRK 處理說明與 §3 不一致(m9) |

## 結論
**REJECT(窄)**。4 個 MAJOR 都可以只改設計文字:
- M1:區塊感知的過濾;
- M2:用 kernel 端證據確認 `rekey`;
- M3:租約 + 可原子替換的 deadman;
- M4:N3 的救回路徑與副作用清單。

改完後請送整份重審。
