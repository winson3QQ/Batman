# 審查 B 第 6 輪:`254-h1-harness.md` v6(整份)

本輪獨立審查,範圍是整份 v6,並逐條核對 §15。節點只做唯讀操作:`ls` `/opt/batdata/state`、`/opt/batdata/log`。沒有跑 bluetoothctl / btmgmt,也沒有印出任何 IRK。

**結論:REJECT(窄)— 1 BLOCKER / 0 MAJOR / 3 MINOR。**

§15 的各項對應方向都對。但有一個新問題,是我第 5 輪 m1 的建議被 v6 改寫成「**一律** rollback」造成的,我也有責任:
- `batman-slot rollback` 的意思是「把預設改成**另一個**槽」(`batman-slot:731-741`,以**當下執行中**的槽為準)。
- v6 在三個地方執行它時,都沒有先確認 02 真的在 B 上:步驟 4 的「hold 沒生效」分支、步驟 6、依階段的 EXIT trap。
- 只要 02 其實在 A 上,`rollback` 就會把預設改成 **B(wsl.2)**,接著 `reboot committed` 讓 02 以 committed 身分開進 wsl.2。
- 依 v6 的文字,至少有一條路徑**每次成功執行都會走到**:正常結束時 EXIT trap 也會觸發,而且 `PHASE` 還停在 `ota`。

---

## §15 對應核對
| 發現 | 結果 |
|---|---|
| B-M1 階段式 EXIT trap(OTA 之後不刪旗標) | ✅ 不刪旗標的規則成立,stub 負對照也成立;❌ 但 trap 後半「等新 boot → 走步驟 4 → 回 A」會引出 B1 |
| A-T1 `dm` / `dm.new`、deadman 期限 ≥ lease | ✅ 推演三種中斷時點,都恰好有一個 deadman 動作:arm 完成前、lease 延長前、`mv` 前。另見 m1 |
| B-m1 一律先 rollback | ❌ 見 B1。這條需要「在 B 上」這個前提 |
| B-m2 fixture 錄完重開 02 | ✅ |
| B-m3 信任說明、刪除條件 | ✅ |
| B-m4 只殺同 run_id 的群組 | ✅ |
| B-m5 revert 時限 | ✅ 公式與 `batman-autocommit:376-383` 一致:bcm2711 預設 600,範圍 300–3600。02 上沒有 `autocommit.timeout`(實讀),所以 T = 600。另見 m2 |
| A-t4 p6 log | ✅ `/opt/batdata/log` 是 root 0755(02 實讀) |

---

## BLOCKER

### B1 `rollback` 執行前沒有確認「目前在 B」;在 A 上執行會把 02 commit 進 wsl.2

**原始碼**:`cmd_rollback` 先取 `A=$(active_slot); T=$(other_slot "$A")`,再用 `write_autoboot "$FT" "$FA"` 把 `[all]` 寫成**另一個槽**(`batman-slot:731-741`)。它是相對於當下執行中的槽,不是「回 A」。

**情境 1:正常成功結束(依設計文字,每次必然發生)**
1. 步驟 6 在 B 上 `rollback` 加 `reboot committed`;步驟 7 斷言 02 已回到 A,腳本以 0 結束。
2. `PHASE` 從 OTA 之後一直是 `ota`,設計只定義了 `pre` 和 `ota` 兩個階段。
3. bash 的 EXIT trap 在正常結束時也會觸發。trap 的 `PHASE=ota` 分支是「等新的 boot_id(相對於 OTA 前)→ 走步驟 4 的判斷與回 A」。
4. 這時 02 已在 A,boot_id 已經不同,條件立刻成立。步驟 4 讀到 `BATMAN_VERSION` ≠ V2,判為「hold 沒生效」,於是「一律先 `batman-slot rollback` 再 `reboot committed`」。
5. 在 A 上 `rollback` → `[all]` = B → 02 以 committed 身分開進 wsl.2。

**情境 2:tryboot 開錯槽(EEPROM 的 no-op)**
- `fault-injection.sh:224-226` 會專門擋「trial 沒有離開 committed 槽」,E30 也記錄了 Pi 4 EEPROM 開錯槽的問題。
- 這時 02 開回 A(wsl.9)。步驟 4 讀到 `BATMAN_VERSION` ≠ V2 → 「hold 沒生效」→ 在 A 上 `rollback` → 結果同情境 1。

**情境 3:步驟 6 送出 reboot 後、步驟 7 之前,主機端出錯**
- 02 已回到 A,trap 走同一條路 → 同樣結果。

**後果**:02 被 commit 在 wsl.2,和 v3 B1 相同。之後每次全套都會因版本不一致在 P3 FAIL;如果 wsl.2 進不了 mesh,沒有乙太網的 02 就要實體救回。

**修法**
- 所有 `rollback` 都改成節點上單一指令,先檢查目前的槽:`[ "$(batman-slot active)" = B ] && [ "$(sed -n s/^BATMAN_VERSION=//p /etc/batman-build)" = "$V2" ] && batman-slot rollback && batman-slot reboot committed`。條件不成立就**不做任何動作**,只回報。在 A 上絕不 rollback。
- `PHASE` 至少分成四個階段:`pre` → `ota`(OTA 已送出,尚未確認在 B)→ `trial`(已確認在 B)→ `returned`(步驟 7 斷言在 A 之後)。
  - `returned`(以及正常結束)時,trap 只印最終狀態。
  - `ota` 時,如果等到的新 boot 在 A,就判「trial 沒有切換」,N3 記為無法執行,**不做任何動作**。
- 步驟 4 的分支加入 `active` 判斷:在 A 上 = 沒有切換,報告即可,不做動作;在 B 上,hold 沒生效 → 執行上面那條有前提檢查的指令。
- 補 stub 負對照(`test-negctl-old-slot-254.sh`),三個案例都斷言**沒有**送出 `rollback`:
  - 「正常完成後 trap 觸發」;
  - 「tryboot 落在 A」;
  - 「步驟 6 之後中斷」。

---

## MINOR

**m1 `dm.new` 被覆寫後留下孤兒 deadman**。如果上一次 `dm_arm` 在 `mv` 前中斷,下一次 `dm_arm` 會直接覆寫 `dm.new`,前一個 `dm.new` 記錄的 deadman 就沒有任何記錄了。它到期時兩項檢查都不通過,會自行退出,沒有危害;但它活著期間 preflight 的「沒有活著的 deadman」檢查找不到它。修法:`dm_arm` 開始時,如果已有 `dm.new`,先把它當作舊的一起取消。

**m2 revert 時限要用 wsl.2 的預設,而且要寫清楚從哪一刻起算**。實際執行 trial 的是 wsl.2 的 autocommit,我讀的 `:376-383` 是 main(wsl.9 這一代)的程式碼,要從唯讀掛載的 slot B 確認 wsl.2 的 `DEF` / `MIN_WINDOW` 相同。另外,`autocommit.deadline` 是 trial 那次開機的 uptime 絕對值;ssh 一直連不上時,主機不知道 trial 何時開機。主機端的等待應從「OTA 送出」起算:寫入加開機的上限 600 s(`waitboot`),加 `max(T, 300)`,加 `DEFER_MAX` 600 s,加 180 s。把總數寫出來(約 33 分鐘)。

**m3 正常結束時 trap 的行為要寫明**。即使已照 B1 分出階段,也要在設計裡明寫:EXIT trap 在成功結束時也會觸發,`returned` / `done` 階段只印狀態。stub 測試要涵蓋「成功結束」這個案例。

---

## 結論
**REJECT(窄)**。只剩 B1,修法很直接:每個 `rollback` 都先在節點上確認「現在在 B 而且是 V2」,`PHASE` 加上 `trial` 和 `returned`,在 A 上一律不做動作。我上一輪的 m1 建議沒寫清楚「只在 B 上」這個前提,這次一併更正。B1 改完並補上 stub 負對照後,我預期可以 APPROVE-WITH-CHANGES。
