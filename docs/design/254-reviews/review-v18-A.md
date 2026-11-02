# #254 第 18 輪審查 — 審查者 A — design v18(e5f9d2e)+ firmware `feat/254-ble` 全部(到 07f20637)

**Verdict:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 5 MINOR**

v17 我列的三個 MAJOR 都收了:
- **R1**:SC 的證據從 logread 改成 bluetoothd 寫在 root-only 儲存區的狀態檔。patch 900 的 C 我逐行讀過,正確。
- **R2**:provd 白名單放行了 `Device1.Disconnect`。
- **R3**:配對測試改用「02 是否看到 04 的 public 位址」判定,加上同一 build 的翻轉負對照。我從 kernel 原始碼確認,這個判定在目標與負對照上**會得到不同結果**。

RPA 測試的三段設計也有判定力。剩下 5 個 MINOR 都是測試步驟與收尾的細節(重跑前置、廣播 session 存活、要驗的拒絕原因、測試主機上的 IRK 副本),不需要再審一輪,改字即可。

範圍:
- v18 全文與 `git diff 6feb29d e5f9d2e`(§13「v17 → v18」逐列);
- firmware `07f20637`(0013 patch 全文);
- linux-6.6.138 與 BlueZ 5.72 原始碼;
- wsl.8 出貨 rootfs(我自己解開);
- 04 / 02 唯讀查詢。

wsl.9 的 build 我沒碰。

---

## 0. patch 900 的 C 程式碼(0013,`07f20637`)

| 點 | 判定 | 證據 |
|---|---|---|
| 檔案路徑 | ✅ | `create_filename(…, "/batman-sc")` 在沒有 `STATE_DIRECTORY` 時用 `STORAGEDIR` 當前綴(`textfile.c:39-55`)。wsl.8 的 bluetoothd 內 `STORAGEDIR` 字串 = `/var/lib/bluetooth`;procd 不設 `STATE_DIRECTORY` |
| 權限、原子性 | ✅ | `g_file_set_contents` = 同目錄暫存檔 + rename;bluetoothd `umask(0077)` → 0600。儲存區 0700,init 驗證擁有權 |
| 只在拿到結果時記錄 | ✅ | 完成回呼 `batman_sc_complete` 先記 status 再分流;`mgmt_send` 回 0 時記 `0xff`。LE-only 時 kernel 的 `set_secure_conn` 走 `!HCI_BREDR_ENABLED` 分支,直接設 `HCI_SC_ONLY` 並回 success(`mgmt.c:6906-6921`)→ `status=0` 確實代表 only 已生效 |
| 成功時的設定同步 | ✅ | 成功時呼叫 `new_settings_callback(dev_id, length, param, adapter)`,和上游 `set_mode_complete` 一樣(`adapter.c:736-741`);沒有動 `pending_settings`,因為沒經 `set_mode()`,正確 |
| `adapter` 指標壽命 | ✅ | 和上游 `set_mode` 的 `data->adapter` 相同模式(destroy 為 NULL),沒有新的壽命問題 |
| 寫檔失敗 | ✅ fail-closed | 只記 error;舊檔的 pid 不是現在的 bluetoothd → helper 判 `sc_file=0` |
| 格式 | ✅ | `index=%u` 的 `dev_id` 是 uint16、`mode=%u` 的 enum/int,經整數提升後與 `%u` 相容 |
| witness | ✅ | wsl.8 bluetoothd 內 `Batman: SecureConnections mode %u requested` 1 次 |

小建議(不列 finding):`0xff` 那條路沒有 `btd_error`,可以補一行。

## 1. 空中測試的判定力(協調者問)

### `ble-pair-sc-only-254`:✅ 有判定力

- **ID key 會被要求**:02(initiator)只要有 `HCI_RPA_RESOLVING`,就會要求 04 分發 ID key(`smp.c:666-667,706-707`)。這個旗標由 `set_privacy` 與 `load_irks` 設定(`mgmt.c:7031-7033,7142`),而 02 跑的 PR-F 是 `Privacy=device` → 一定會要。04 的 responder 分發 = `req->resp_key_dist & local_dist`(`smp.c:718`),`local_dist` 在 `HCI_PRIVACY` 下含 ID_KEY(`smp.c:669-670`)。
- **翻轉負對照會洩漏**:04 `mgmt.sc on` 會清掉 `HCI_SC_ONLY`(`mgmt.c:6913-6916`)→ 02 送不帶 bonding 的 legacy 請求被接受(04 是 NoIO → Just Works,不問 user space,`smp.c:885-888`)→ 04 送出 IRK 與身分位址 → kernel 把 `hcon->dst` 換成身分位址(`smp.c:1056-1066`)→ mgmt 的 Pair 回覆以 `conn->dst` 填位址(`mgmt.c:3377-3378`)→ 02 看到 `88:A2:9E:B5:6C:8B (LE Public)`。
- **目標會被拒**:04 只要 SC-only,一收到 Pairing Request 就回 Authentication Requirements(`smp.c:1760-1761`),沒有任何金鑰分發 → 02 只看得到 RPA。
- **判定與修法一致**:判定看位址或 Pair 回覆,不看存檔,避開了 v17 R3 的「不持久就不存」(`adapter.c:8980`)。

### RPA 測試:✅ 有判定力

- (a) 不重新註冊、同一個 RPA:就是 F28 的對照。legacy 單一 instance 重新排程時不送 HCI 指令(`hci_sync.c:2050-2056`)。
- (b) timeout 前重新註冊、RPA 不變;(c) 超過 900 s 後重新註冊、RPA 換新(`hci_get_random_address` 看 `rpa_expired`)。
- 用「最高兩位元 = 01」加上 `ah(IRK, prand) == hash` 斷言,排除了 NRPA / static random 混進來的可能。

---

## 2. 發現(全部 MINOR)

### S1 配對測試:02 每次重啟 bluetoothd 後要重做步驟 1;目標判定要鎖定拒絕原因 0x03

- 步驟 4「每輪之間重啟 02 的 bluetoothd」之後,02 的狀態會跑掉:
  - 02 自己的 patch 900 會把 SC 改回 only;
  - 02 上互動式 bluetoothctl 的 agent 一重新註冊,BlueZ 就把 bondable 打開(`adapter.c:9089-9090`)。
- 這時再跑:
  - 「必須外洩」那一輪會因為 02 送的是 SC 請求而失敗(假 FAIL);
  - 「必須失敗」那一輪可能因為 02 帶 bonding、被回 Pairing Not Supported(0x05,`smp.c:1756-1758`)而失敗,也就是**失敗的原因不對**,但看起來像 PASS。
- 修法:
  - 每次重啟 02 bluetoothd 後重做步驟 1,並印出 `mgmt.info`(沒有 bondable、沒有 secure-conn);
  - 目標判 PASS 要求失敗原因**正好是 0x03 Authentication Requirements**;其他原因 = 這一輪無效,不算 PASS。

### S2 D25 後半段(SC Just Works 因為沒有 agent 而被拒)沒有空中測試

- 程序只測了 legacy。建議加一輪:02 `sc on`、bondable off、NoIO → 對 SC-only 的 04 配對。
- 預期:04 的 bluetoothd 回 confirm 拒絕(`adapter.c:8028-8034`)→ 配對失敗(依 kernel 實作,可能是 Numeric Comparison Failed 或逾時)、02 看不到 public 位址。
- 判 PASS 前先斷言 04 上沒有任何 agent。辦法是看 04 current settings 沒有 `bondable`:BlueZ 只在有 agent 時才打開它。

### S3 RPA 測試的廣播 session

- **`agent off` 之前會先註冊**:互動式 bluetoothctl 在 AgentManager1 出現時就自動註冊 agent(`client/main.c:491-494`,預設 `auto_register_agent=""`,`:3186-3190`),早於使用者打 `agent off`。註冊期間 04 的 bondable 會短暫打開(`adapter.c:9089`),unregister 後關回。
  - 修法:「前後斷言 04 沒有 bondable」要改成在 **`advertise on` 之後**、以及**整段測試期間定時**檢查,而不只在開始前看一次。
- **session 要撐過 30 分鐘以上**:ssh 一斷,bluetoothctl 結束、廣播被撤;重連後重新註冊,等於一次重新註冊,會污染 (a) 段。
  - 修法:用 `setsid` 加 FIFO 當 stdin 讓它常駐,並記錄每次 `advertise on/off` 的時間戳;(a) 段期間出現任何一次重新註冊,這段就作廢。
- **措辭**:bluetoothctl 的 `scan on` 是 active scan,不是被動掃描。它送 SCAN_REQ,但不會讓廣播重新啟用,所以不影響判定;只是文字要改。

### S4 Q8 收尾漏了測試主機上的 IRK 副本

- `ah()` 驗證需要把 04 的 `identity` 帶到計算的地方(02 或 PC)。這把 IRK 在測試主機上是秘密。
- 重開 04 讓它作廢是對的;收尾清單再加:刪除測試主機上的副本並列出確認,而且只放在 root-only 或 scratch 位置。

### S5 Q8 前置檢查

- 02 目前(唯讀確認):`1.5.12-wsl.2`,p1 `/boot/distroconfig.txt` 的 `[pi4]` 已有 `dtoverlay=miniuart-bt`、沒有 `core_freq_min`。和 v18 的計畫一致:OTA 到 slot A,而 slot A 讀 p1。
- 建議再補兩點:
  - OTA 後在 02 上斷言 `hci0` 出現、`batman-sc` 為 `mode=2 status=0`,再開始測試;沒有就停,不要繼續;
  - 02 OTA 之後要在 autocommit 的窗口內 commit(02 與 04 要入網),否則測到一半 02 會 revert。

---

## 3. v17 發現的去向

| v17 | v18 | 判定 |
|---|---|---|
| R1 log 當證據 | `batman-sc` 狀態檔(patch 900 完成回呼);§3 health 為唯一契約,`sc_file` | ✅(§0) |
| R2 `Device1.Disconnect` | 白名單放行;正向與負向測試 | ✅ |
| R3 配對判定分辨不了 | 判定看 public 位址;同一 build 翻轉 | ✅(§1);細節見 S1 / S2 |
| R4 廣播者 / 順序 | RPA 先做、`agent off`、三段、ah() 驗證 | ✅;細節見 S3 |
| R5 反方向 dbus 規則 | §4.6 列出 + PR-P2 正向測試 | ✅ |
| R6 GATT 只是 smoke | §9 | ✅ |
| R7 D27 | 改成狀態檔 | ✅ |

## 4. 我實際跑過或讀過的東西

- **wsl.8 rootfs**(`/home/yello/out/1.5.12-wsl.8+f2f2bf6.fw3ec5e9b`,用完即刪):
  - `etc/bluetooth/` 只有 `main.conf`(keys 目錄已移除 ✅);
  - init 有 `store_ok`;
  - bluetoothd 有 witness 字串、`/var/lib/bluetooth` 字串;
  - `check-pvs-shim.sh` → `OK` rc=0。
- **02 唯讀**:`BATMAN_VERSION=1.5.12-wsl.2+f2f2bf6.fw9d87d02`;`/boot`(p1)distroconfig 的 `[pi4] dtoverlay=miniuart-bt`。
- **原始碼行號**:
  - kernel `smp.c:666-670,706-718,885-888,1045-1066,1756-1761`、`mgmt.c:3371-3378,6906-6921,7031-7033,7142`、`hci_sync.c:2050-2056`;
  - BlueZ `adapter.c:723-741,8028-8034,8975-8982,9089-9090`、`textfile.c:39-55`、`client/main.c:491-494,3186-3190`。

沒有變更 04 / 02,也沒跑 bluetoothctl。

## 5. 沒做或做不到的

- ❌ wsl.9:build 還在跑。patch 900 的 C 我只讀了原始碼,沒有在節點上看到 `batman-sc` 檔。
- ❌ 空中測試本身(由作者照 Q8 執行)。
