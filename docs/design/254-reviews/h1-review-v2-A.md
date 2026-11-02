# #254 PR-H1 harness 設計 v2 — 獨立審查 A(第 2 輪,整份)

審查對象:`254-h1-harness.md` v2(整份,含 §11 對應表)。使用者 10-20 的決定(peer.py → H3、coex → P2、負對照 = 白箱 + 02 換到 slot B 一次)不重議,只審執行方式與副作用。
我沒有改任何節點狀態,沒跑 bluetoothctl / btmgmt,沒印出 IRK。

## 本輪查證(證據)
| # | 查證 | 結果 |
|---|---|---|
| W1 | E8 `load_irk` / `generate_and_write_irk`(adapter.c 約 4160–4225) | `identity` 是 GKeyFile `[General] IdentityResolvingKey=`;讀不到 key 時印 `No IRK stored` 後產生新 IRK;用 `getrandom`;以 **`%02x`(小寫)** 寫入 → rekey 的機制成立 ✅ |
| W2 | E6 `client/main.c:491-494` + `src/shared/shell.c:1245` | 只在非 `NON_INTERACTIVE` 時註冊 agent;**mode = `(argc > 0)`**:只有指令放在 argv 上才算非互動,**從 FIFO 餵 stdin 仍是互動模式,會註冊 agent** |
| W3 | E10 `hci_sync.c:1046-1067` `adv_use_rpa` | basic privacy 時一律用 RPA,與 connectable 無關 ✅;`mgmt.c:1016-1028` `rpa_expired`:只在 `HCI_ADVERTISING`(Set Advertising)時主動換新 RPA,adv instance 要重新啟用才會換 → (a) 30 分鐘不變、(c) 重新註冊才換,有原始碼依據 ✅ |
| W4 | PR-F `air-sandwich-04-btmon.txt` 格式 | 事件行是 `< ACL Data TX: …` / `> ACL Data RX: …`;**`SMP: Pairing Failed`、`SMP: Identity Information`、`LE Connection Complete (0x01)` 都是縮排 6 格的子行**,`Reason:` 縮排 8 格 |
| W5 | 02 `eth0/carrier` | `0`:02 沒有乙太網,只能經 mesh 連到 |
| W6 | ssh 往返(閒置) | 02:0.21–0.30 s,偏移抖動 ≤ 0.03 s;04:0.17–0.21 s → §4.4 的「uptime 差 > 2 s」門檻在閒置時夠寬 |
| W7 | `batman-slot` | `cmd_rollback` 只改 `[all]` 預設;`cmd_reboot` 是 committed 重開;`is-trial` 是唯讀 |
| W8 | `bluez main.conf:108` | `#TemporaryTimeout = 30`(預設) |
| W9 | `fault-injection.sh:516` | `FI_SOURCE_ONLY=1` 時 return;`precheck` 用 `q` / `PAYLOAD` / `QT` 等全域變數 |

## §11 對應表逐項檢查
| v1 發現 | v2 的處理是否成立 |
|---|---|
| A-M1 兩個時鐘 | ✅ 改為主機時間軸 + 保護帶;uptime 差檢查可行(W6),方法要寫成取 RTT 中點(m7) |
| A-M2 覆蓋率 | ✅ 2 分鐘桶、頭尾桶、N2 |
| A-M3 中斷 / 殘留 | ⚠️ 大致成立(標記、`ble-state`、rekey、N7),但 deadman 的動作不完整,也沒寫程式碼放在哪(m1) |
| A-M4 privacy off / 解析 | ✅ E7 + power off 流程 + 只解析 `current settings:` + N10 |
| A-M5 tier A 相依 | ✅ tier A 改用非互動 bluetoothctl(W2:argv 形式確實不註冊 agent)。**但 P6 改成不分模式後衍生新問題(R2)** |
| A-M6 coex / fresh overlay / 舊版 | ✅ 依使用者決定;§4.3 寫明 fresh overlay 的取代方式。N3 的執行方式見 R3 |
| A-M7 peer.py | ✅ 延到 H3,§9 有寫 |
| A-M8 P7 | ⚠️ 算法對了(同一台時鐘);門檻與開機那陣 log 見 m5 |
| A-m3 連線對上規則 | ❌ 改成「本輪 btmon 恰好一個成功的 LE Connection Complete」,但過濾規則把這行濾掉了(R1) |
| A-m9 canary | ⚠️ 機制對了,但比對分大小寫(m4) |
| A-m15 F16 | ⚠️ §4.4 說 02 的取樣是「非互動 session 經 FIFO」,與 W2 矛盾(m3) |
| 其他 A-m* | ✅ |

---

## MAJOR

### R1 btmon 過濾規則與四態判定互相矛盾 → 「擋下」與 04 端的「外洩」都判不出來
- **情境**:§4.7 的過濾只保留 `^[<>@=] ` 開頭的行和 `Reason:` 行。但判定需要三樣東西:`LE Connection Complete` 加成功狀態、04 **送出**的 `SMP: Pairing Failed` 加 reason 0x03、04 送出的 `SMP: Identity Information`。W4 顯示這三者都是縮排子行,會被濾掉。留下的 `Reason:` 行分不出是 SMP Pairing Failed 的 reason,還是 Disconnect 的 reason(r1 證據裡兩種都有:`Authentication requirements (0x03)` 與 `Authentication Failure (0x05)`),也分不出方向。
- **後果**:每輪都判「無效」,目標段因此 FAIL。這是 fail-closed,但 B-M2 的修正實際上做不出來。外洩判定也退化成只看 02 的輸出,04 btmon 那條「送出的 Identity Information」證據消失。
- **修法**:過濾改成在節點上解析出結構化的結論行,不回傳原始行。例如 `TX SMP PairingFailed reason=0x03`、`TX SMP IdentityInformation`(只有名稱)、`EV LEConnComplete status=0x00`,依前一個事件行的 `<` / `>` 判方向。或者改用白名單:只保留事件行之後、指定名稱的子行(`SMP: <名稱>`、`LE (Enhanced )?Connection Complete`、`Status:`、SMP 區塊內的 `Reason:`)。任何值欄位(`Identity resolving key:`、`Long term key:` 等)一律不出節點。N10 的 stub 要用 W4 這份真實輸出(擋下段與外洩段各一份)做正例與反例,並驗證過濾後的輸出不含任何 32 位 hex。

### R2 P6 不分模式檢查產品狀態,一個 BLE 缺陷會讓整個 run 什麼都不跑
- **情境**:P6 現在只要 fleet 裡有 bcm2711 節點就檢查 `hci0` 存在,以及 `batman-sc` 為本次開機、bluetoothd 活著、mode 2,FAIL 時不跑任何 suite。PR-F 有一筆未歸因紀錄:02 暖開機 1/4 次 hci0 初始化失敗。也就是 02 每重開一次,約 1/4 的機率下一次每日 run 完全沒有結果:mesh、OTS、A/B、soak 全部被一個 BLE 問題蓋掉,而且每次都要等有人重開 02。
- **原則問題**:preflight 該擋的是「這次 run 的設定或 harness 狀態錯了,跑了也白跑」,例如版本不一致、P1–P5、BLE 殘留標記、deadman 還活著。「受測產品壞了」應該由 suite 回報為 FAIL。`ble-privacy-254` 的斷言 1 本來就會抓到 hci0 / `batman-sc` 的問題。
- **修法**:P6 只保留 harness 相關的部分:殘留標記、deadman / btmon / harness bluetoothctl 是否還活著、adv instance、工具 sha、`--version`、`ble-ah --selftest`、BLE 節點角色。`hci0` / `batman-sc` 只在 `FEATURE_MODE=--destructive` 且是 BLE_PERIPH / BLE_CENTRAL 時留在 preflight(tier B 需要它,而且之後要重開)。其他節點的這類問題交給 `ble-privacy-254` 判 FAIL。§5「hci0 初始化失敗」那一列要跟著改。

### R3 N3(02 換到 slot B)沒有寫出失聯風險與救回方法,而且照 harness 的流程跑不起來
- **情境 1(失聯)**:W5 顯示 02 沒有乙太網。N3 用 `rollback` 加 `reboot committed`,把 slot B 變成**預設**,開進的是 slot B **原本的 overlay**:那是 wsl.2 時期留下的 mesh / 金鑰 / 頻道設定,不是 fresh firstboot,不會從 p5 還原。如果那之後 mesh 設定改過(setkey、頻道、`.seeded` 等),02 開在 B 上就加不進 mesh,主機連不到它,也下不了 `rollback`。救回只能靠實體:拔卡或接 serial。這正是現有 tier B「只對有乙太網的 DNODE 做破壞性動作」要避免的情況,也是 1.4.12 讓 02 失聯那次的同一類風險。§4.10 的副作用段只寫了「重開兩次、離網數分鐘」。
- **情境 2(跑不起來)**:02 在 wsl.2 時,preflight 的 P3(fleet 版本一致)與 P6(`batman-sc`)都會 FAIL,所以不會跑到 `ble-privacy-254`。設計沒寫 N3 怎麼執行(`DV_PREFLIGHT=off` + `DV_ONLY`?報告頁首就會是 BYPASSED)。
- **修法**:
  1. 切換前先唯讀比對:掛起 slot B 的 overlay(唯讀),比對 mesh 設定與 slot A 現行設定(mesh_id / key / channel / radio)。不一致就先停下來問使用者。
  2. 優先用 one-shot 的 tryboot 進 B:沒連上時,斷電重開會回到 A。如果 `batman-slot` 不支援「不 apply 只 tryboot」,寫明實體救回方法:有人在現場、serial 線已接好、拔卡用的 image 在手邊。
  3. 寫明執行方式:`DV_PREFLIGHT=off DV_ONLY='ble-privacy-254|prov-tools-254'`。preflight 在這個狀態下 FAIL,本身就是 P6 的舊版負對照,要一起記錄。
  4. 回到 A 之後除了既有斷言,還要檢查 02 重新加入 mesh(batctl neighbor 看得到 04),以及 `ble-state` 乾淨。

---

## MINOR
- **m1 deadman 的實作缺口**:
  - (a) 節點腳本是用 `ssh … "sh -s" < script` 送過去的,節點上沒有檔案。deadman 到期時要執行的 `restore` / `rekey` 邏輯放在哪裡沒有寫:要放一份到 `bt/`,沿用 owner / 非 symlink / link count 的檢查。
  - (b) 04 的 deadman 動作沒有殺 harness 的 btmon、也沒刪 snoop。中斷後 btmon 會一直錄,snoop 在 tmpfs(記憶體)裡持續長大,而且含金鑰。`ble-state` 會報 btmon 還活著,但 deadman 本身沒把它清乾淨。
  - (c) deadman 動作要用**會等待**的 `flock`(不是 `-n`)拿節點鎖,避免和還在跑的 harness 同時寫;harness 之後會看到 pid 變了而 FAIL,這樣是對的。
  - (d) pgid 從 `/proc/<pid>/stat` 讀,不要假設 `$!` 就是 pgid(busybox `setsid` 遇到 process group leader 時會 fork)。busybox `kill -TERM -- -<pgid>` 要附實測證據。
- **m2 鎖的語意**:「每個指令 `flock -n`」只在單一 ssh 指令期間持有鎖,40 分鐘測項中間大部分時間鎖是空的。真正擋住第二個 run 的是「deadman 還活著 → `dm_arm` 拒絕、preflight FAIL」。要寫清楚這一點,或者改成測項層級的租約(在 `ble-state` 寫入 run id,每個指令比對)。
- **m3 bluetoothctl 模式**:W2 顯示 FIFO session 是互動模式,會註冊 agent。§4.4 寫成「非互動 bluetoothctl … 經 FIFO」是錯的。02 的取樣可以改用 `bluetoothctl --timeout 10 scan on`(argv 形式,真正非互動,也不需要節點上的 `timeout`);如果保留 FIFO,就寫明 02 會註冊 agent,以及為什麼不影響(02 不是受測對象)。另外寫明不會把殘留物件算成看見紀錄的前提:`TemporaryTimeout` 預設 30 s(W8),兩次取樣間隔約 50 s,而且只計 `Discovery started` 之後的行。
- **m4 canary 要不分大小寫**:`identity` 是小寫(W1 `%02x`),btmon 也印小寫;但 bluetoothd 的裝置 `info` 檔用大寫,其他工具也可能用大寫。改成 `grep -i -F -f`。
- **m5 P7 門檻**:(a) 任一節點開機後 60 s 內跑 preflight 會因開機那陣 log 誤 FAIL:要嘛 uptime < 300 s 時先等,要嘛隔 60 s 量兩次,兩次都超標才 FAIL。(b) 節點時鐘往回跳時 now − t < 0,要判 FAIL,不能判 PASS(#174 開機還原會讓時鐘跳)。(c) 「60 s 內 200 行」大約是 3.3 行/s,ring 約 6 分鐘就整個換掉;慢速灌爆(例如 1 行/s,約 18 分鐘換掉)也會讓長跑期間的 log 證據消失。建議門檻改成以 ring 換一輪的時間計:(now − t) × 1100 / 200 必須 ≥ 預期 run 長度(例如 6 h)。
- **m6 N5 沒有鑑別力**:可以補兩個真正會 FAIL 的注入:(a) 段中途 power off / on 一次(會換 RPA,W3)→ (a) 必須 FAIL;(c) 改在 T0+600 重新註冊(timeout 前)→ 位址不變 → (c) 必須 FAIL。這樣 (a)、(c) 的判定都有負對照。
- **m7 uptime 偏移的量法**:寫成「主機記 ssh 前後兩個時間,取中點減節點 uptime」,RTT > 1 s 的那次樣本作廢重量。W6 顯示閒置時誤差 ≤ 0.03 s。
- **m8 P5 用 `FI_SOURCE_ONLY` 的前提**:`precheck` 依賴 `q`、`PAYLOAD`、`QT`、`no` 等全域變數與目標節點變數(W9)。要寫明 preflight 怎麼設定這些變數,並附一個 stub 案例證明 source 之後真的會判 FAIL(例如給錯的 payload)。

## 新設計引入的其他檢查(無發現)
- rekey:W1 證實刪掉 identity 再啟動會產生新 IRK;getrandom 失敗時 privacy 不會開,`irk-exposed` 也不會刪 → 下一次 preflight FAIL(fail-closed)✅。
- non-connectable 廣播:W3 證實仍用 RPA;不連線可以避免斷線後重開廣播換 RPA ✅。
- 主機時間軸的取樣密度:(b)、(c) 扣掉保護帶後各約 240 s,也就是 2 個桶、每桶約 2 次取樣,夠但沒有餘裕;漏一次 ssh 就缺桶 FAIL(fail-closed)。可以考慮每 30 s 取樣一次。
- 時間軸順序 rpa → pair → reboot、BLE tier B 排在 ab-selftest 之前、`BLE_PERIPH == DNODE`:✅。

## 裁決
**APPROVE-WITH-CHANGES**:BLOCKER 0、MAJOR 3(R1、R2、R3)、MINOR 8。v1 的 8 個 MAJOR 大部分都有實質處理(§11 檢查見上表)。剩下的 3 個 MAJOR 修法明確、範圍集中。依規則,這 3 個 MAJOR 修完後仍要整份再審一輪。

未驗 ⚠️:busybox `kill -- -pgid` 與 `setsid` 的行為;bluetoothd 5.72 的 adv manager 實際走 `ADD_ADVERTISING` 還是 `ADD_EXT_ADV_*`(E15 的說法;不影響判定);slot B overlay 的實際 mesh 設定(要掛載才看得到,這是唯讀審查做不到的,R3 要求作者先查)。
