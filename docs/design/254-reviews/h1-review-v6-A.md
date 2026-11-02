# #254 PR-H1 harness 設計 v6 — 獨立審查 A(第 6 輪,整份)

審查對象:`254-h1-harness.md` v6 整份(與 v5 diff)。節點全程唯讀;沒跑 bluetoothctl / btmgmt;沒印出 IRK。

## §15 對應表逐項檢查
| v5 發現 | 結果 |
|---|---|
| A-T1 `mv` 前中斷,兩個 deadman 都不動作 | ✅ `dm-fire` 認 `dm` 或 `dm.new` + lease 已到期 + deadman 期限比 lease 晚 5 s(在同一個鎖內設定)+ N7b。推演三種情況:(1)舊的沒被取消:它醒來時 lease 已延長、未到期 → 退出;新的在 lease 到期後動作。(2)舊的醒來時拿不到鎖、一路重試到 lease 到期:兩個都會通過檢查,但第一個還原完就刪了 lease,第二個驗「lease 屬於該 run」不成立 → 退出,不會重複還原。(3)更舊的(不在 `dm` / `dm.new`):退出。✅ |
| B-M1 EXIT trap 在 OTA 後刪旗標 | ✅ 依 `PHASE` 分段、OTA 之後絕不刪、有 stub 負對照。另見 u3 |
| B-m1 讀與動作之間的 TOCTOU | ✅ 一律先 `rollback` 再 `reboot committed`。核對 `cmd_rollback`(`batman-slot:731-741`):在 B 上執行時,A=B、T=A → `[all]`=A。trial 沒 commit 時 `[all]` 本來就是 A,所以無害;已 commit 在 B 時會把預設改回 A ✅ |
| A-t1 `UNPARSED` | ✅ 加了已知忽略欄位清單 |
| A-t2 / B-m2 02 identity | ✅ 改成重開 02,不碰 §3 禁止改的 `identity`。重開的方式見 u2 |
| A-t3 / B-m5 revert 時限 | ✅ max(T, 啟動+300) + 600 + 180,T 在步驟 1 讀取 |
| A-t4 p6 log | ✅ 擁有者、symlink / link count 檢查、清理方式都寫了 |
| B-m3 / m4 | ✅ |

---

## MAJOR
無。

## MINOR
- **u1 「02 的 IRK 不外流」的理由與事實不符**:§4.5 收尾寫「02 的 IRK 在翻轉段交給 04……只存在 04 的 tmpfs 儲存區 → 不外流」。但翻轉段是 **legacy Just Works** 配對(PR-F btmon:`Authentication requirement: No bonding, No MITM, Legacy`,TK = 0)。金鑰分發雖然在加密連線上,加密金鑰卻能從空中錄到的配對過程推出來(crackle 這類被動攻擊就是這樣做)。所以每次 tier B 翻轉段,BLE 範圍內的被動監聽者都能同時拿到 **04 與 02** 的 IRK。04 的 IRK 有 rekey 或重開處理;02 的 IRK 則一直有效,直到 02 下次重開。v6 在錄 fixture 時重開 02,卻在每次例行 tier B 時不處理,兩邊標準不一致。修法:
  - 更正 §4.5 與 §7 的說法:02 的 IRK 也經空中外洩給被動監聽者;
  - 由使用者決定:要嘛 tier B 收尾也以 `batman-slot reboot committed` 重開 02(02 沒有乙太網,但這是 committed 槽的正常重開),要嘛明文接受,並寫出理由(02 是 bench / central 角色),與 H-U6 並列。
- **u2 「02 重開」要寫成 `batman-slot reboot committed`**:fixture 錄完(以及 u1 若決定重開)要用 explicit partition 重開(E30:plain reboot 約 5/10 會開到錯的槽)。02 沒有乙太網,開到錯的槽會更難救。這次重開也要列進 §8 的副作用:02 離網數分鐘、經 mesh 回來。
- **u3 OTA 失敗後留下的 V2 hold 旗標要讓人看得到**:旗標留著不會擋 OTA(下一次任何 tryboot 都會先吃掉它:版本不符就丟棄並刪除;是 wsl.2 的話會 hold,到時限 revert),這點設計說得對。但 `fault-injection.sh` 的 `p5` 案例(約 459 行)與 `restore_node`(約 104–105 行)都把「旗標存在」當成 FAIL 或拒絕執行。如果之後有人對 02 跑 fault-injection,就會得到一個原因不明的 FAIL。修法:preflight 把「任一節點有 `autocommit-hold-commit`」列為 harness 殘留狀態並印出內容(FAIL 或至少 WARN,由作者決定並寫明);N3 結束訊息附上安全的清除步驟:確認沒有待開的 trial(`batman-slot is-trial` rc 1、tryboot 沒有 arm)後才 `rm`。

## 新設計的其他部分(查過,沒有發現)
- 鎖逾時後只殺同一個 run_id 的群組,並先寫 log ✅。
- preflight 刪 run 目錄的條件加了「沒有活著的 deadman」,避免刪掉 deadman 還要執行的腳本 ✅;§4.1 的信任說明也同步更新了 ✅。
- EXIT trap 的 `PHASE` 在送出 OTA 指令的前一行就設定:中斷若發生在設定之後、OTA 真正送出之前,只會留下一個無害的旗標,偏向安全的一邊 ✅。

## 裁決
**APPROVE**:BLOCKER 0、MAJOR 0、MINOR 3。u1 需要使用者決定(02 的 IRK 是否也要在 tier B 收尾作廢);u2、u3 可在實作時吸收。不需要再一輪整份審查。
