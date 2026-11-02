# #254 PR-H1 harness 設計 v5 — 獨立審查 A(第 5 輪,整份)

審查對象:`254-h1-harness.md` v5 整份(與 v4 diff)。節點全程唯讀;沒跑 bluetoothctl / btmgmt;沒印出 IRK。

## 本輪查證
| # | 查證 | 結果 |
|---|---|---|
| Z1 | `batman-autocommit:376-383` | 時限 `DEADLINE` 是**絕對 uptime**,= max(T, START+300)。T 取自 `/opt/batdata/state/autocommit.timeout`;沒有這個檔時 bcm2711 = 600、bcm2837 = 900;下限 300、上限 3600 |
| Z2 | `batman-slot:432-433` | OTA 會刪目標槽的 `slot-<T>.protected` ✅(E32) |
| Z3 | E32 / E33 | 與我第 4 輪讀到的 `version()`、POLL / NEED 一致 ✅ |

## §14 對應表逐項檢查
| v4 發現 | 結果 |
|---|---|
| B-M1 V2 來源 | ✅ V2 只取自 slot B 的 `/etc/batman-build`,並與 `slot-B.protected` 交叉比對,明文禁止用 metadata 的 `version=` |
| A-n1 已 commit 在 B 的分支 | ✅ 步驟 4 (a)(b)、EXIT trap 都涵蓋 |
| A-n2 舊 deadman 在 lease 延長後動作 | ⚠️ 加了「lease 已到期 + pgid == `dm`」兩個條件,但 pgid 那個條件引入新的缺口,見 T1 |
| A-n3 等鎖不放棄 | ✅ 10 分鐘上限,每個持鎖指令都有 watchdog |
| A-n4 EXIT trap | ✅ 刪旗標並讀回、依停在哪個槽分別處理 |
| A-n5 rekey 期間死掉仍重開 | ✅ 已明寫 |
| B-m2 fixture 含 02 的金鑰 | ⚠️ 方向對;但與 `UNPARSED` 規則、§3 的擁有權衝突,見 t1、t2 |
| B-m3 / m4 / m5 | ✅ |

---

## MAJOR

### T1 `dm-fire` 的「pgid == `dm`」條件,讓 arm 中斷時兩個 deadman 都不動作
- **情境**:`dm_arm` 的順序是 arm 新的(寫 `dm.new`)→ 取消舊的(最多等 10 s)→ `mv dm.new dm`。設計說「中間 ssh 斷線也至少有一個 deadman 在」,但 v5 規定 `dm-fire` 動作前要「自己的 pgid == `ble-state/dm` 記錄的那一個」。假設 ssh(或 harness)在 arm 之後、`mv` 之前斷了:
  - 新的 deadman:pgid 只在 `dm.new`,不等於 `dm` → 只寫 log 退出;
  - 舊的 deadman:如果已經被取消就不存在;沒被取消的話,它的 pgid 等於 `dm`,但 lease 已經延長到新的期限,醒來時「lease 已到期」不成立 → 退出。
  - 結果:**沒有任何 deadman 會還原**。這正是 v4「先 arm 新、再取消舊」要防的那個窗口,而且發生在每一次狀態變更(包括 flip)。下一次 preflight 會因標記 FAIL(fail-closed),但在那之前 04 可能一直停在 `flipped`、帶著 adv instance 或外洩過的 IRK,沒人還原。
- **修法**:
  - `dm-fire` 接受「pgid ∈ {`dm`, `dm.new`}」,並且 lease 已到期才動作;舊的那個會因為 lease 已延長而自然退出,所以不會兩個都動作。
  - 明寫 lease 延長發生在 arm 新 deadman 之前或同一個鎖內步驟:新 deadman 的期限 ≥ lease 期限,保證到期時至少有一個合格的 deadman 醒來。
  - 補一個白箱負對照:在 `mv` 之前殺掉 harness,到期後必須有還原動作(04 `ble-state` 乾淨,或因為有 `irk-exposed` 而重開)。

---

## MINOR
- **t1 fixture 遮蔽與 `UNPARSED` = 0 互相矛盾**:遮蔽規則是「白名單以外的子行,值一律換成假值」,所以 fixture 裡仍有 `Identity resolving key: <假值>`、`IO capability: …` 等子行。但判讀規則說「無法歸類的子行計數成 `UNPARSED`」。照字面,fixture 的 `UNPARSED` 不可能是 0。修法:判讀器另設「已知、刻意忽略」的欄位清單(列出名稱,例如 `IO capability`、`Authentication requirement`、`Identity resolving key`、`Peer address`、`Handle`…),只有不在白名單、也不在忽略清單的才算 `UNPARSED`。
- **t2 §3 擁有權要配合 fixture 錄製的步驟**:§3 寫「02 `identity` / `settings` 的擁有者是 bluetoothd,harness 不可改」,但 fixture 錄完要刪 02 的 `identity` 來換 IRK。要在 §3 加一個例外列:錄 fixture 時由一次性程序改寫 02 `identity`。說明這次換 IRK 沒有 kernel 驗證:02 的停止走 SIGTERM,會先斷電(E31),所以啟動時新 IRK 會進 kernel;如果要確認,用 04 掃 02 的 RPA 不可行(02 不廣播),所以接受為 ⚠️。另外,`reset` 的「前後雜湊不變」檢查不能跨過這一步。
- **t3 N3 步驟 6 的「保守上限」並不保守**:讀不到時限時,設計寫「從 MIN_WINDOW 300 s 起算」。但 Z1 顯示時限至少是 T(bcm2711 預設 600,`autocommit.timeout` 可設到 3600),所以只用 300 s 起算會低估,可能過早判定「需要實體處理 02」,讓人做沒必要的實體介入。修法:步驟 1 先從 02 讀 `/opt/batdata/state/autocommit.timeout`(沒有就用 600,範圍 300–3600)。上限 = max(T, 開機到 autocommit 啟動的時間 + 300) + DEFER_MAX + 餘裕,全部以 02 的 uptime 計。
- **t4 deadman 重開(H-U6)記錄的 p6 log**:`/opt/batdata/log/ble-dm-254.log` 是新的節點寫入路徑。要寫明 owner root、不跟隨 symlink(`/opt/batdata/log` 是 root 目錄,與 autocommit.log 同一個目錄,同一個等級),也要寫明誰負責清它、多久清一次(或不清,與 autocommit.log 一樣)。

## 新設計的其他部分(查過,沒有發現)
- N3 步驟 4 的兩個分支加上 EXIT trap,涵蓋了「沒 commit / 已 commit 在 B / 中途中斷」三種情況;回 A 一律用 explicit partition ✅。
- 每個持鎖指令都有 watchdog,配合 10 分鐘後不拿鎖直接還原,解決了卡死持鎖者的問題 ✅。
- `bt/<run_id>/` 的清理:先印出再刪,只刪 lease 已不在或不是本次開機的 run 目錄 ✅。

## 裁決
**APPROVE-WITH-CHANGES**:BLOCKER 0、MAJOR 1(T1,v5 新引入,修法是一行條件加上期限順序)、MINOR 4。v4 我與 B 的發現都已正確對應。依規則,T1 修完後再審一次;T1 是局部修改,但規則要求整份。

未驗 ⚠️:無新的(本輪讀碼 Z1、Z2 都有原始碼依據)。
