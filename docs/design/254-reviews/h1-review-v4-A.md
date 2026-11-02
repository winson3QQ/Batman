# #254 PR-H1 harness 設計 v4 — 獨立審查 A(第 4 輪,整份)

審查對象:`254-h1-harness.md` v4 整份(與 v3 diff)。H-U6(harness 死掉而 IRK 已外洩時,deadman 重開 04)不重議。節點全程唯讀;沒跑 bluetoothctl / btmgmt;沒印出 IRK。

## 本輪查證
| # | 查證 | 結果 |
|---|---|---|
| Y1 | `batman-autocommit:66` | `version()` = 開機那個 rootfs 的 `/etc/batman-build` 裡的 `BATMAN_VERSION`;hold 比對的就是這個字串 |
| Y2 | `batman-autocommit:30-34` | `POLL=10`、`NEED=3`、`JOIN_NEED=3`、`MIN_WINDOW=300`:hold 沒生效時,健康的 trial 最快約 30 s 的停留就會 commit |
| Y3 | `fault-injection.sh:118` | `trap … restore_node … EXIT` 在第 516 行 `FI_SOURCE_ONLY` return **之前**就設好了 → source 之後這個 trap 已經裝上(v4 寫了要換成自己的 trap ✅);`restore_node` 會刪 hold 旗標 |
| Y4 | Git Bash `/proc/uptime` | 讀得到(`504776.50 …`)→ §4.4 改用主機 uptime 當單調時鐘可行 ✅ |
| Y5 | E29 / E30 | 與第 3 輪讀到的 `bad-slot` 寫入與刪除(revert 時寫、commit 時刪)、`cmd_reboot` 註解一致 ✅ |

## §13 對應表逐項檢查
| v3 發現 | 結果 |
|---|---|
| A-S1 N3 hold 版本 | ✅ 旗標寫 V2、不用 `precheck` / `held_trial`、進 trial 先驗、回 A 一律 explicit partition、`bad-slot` 副作用都寫了。剩下一個時序的邊角,見 n1 |
| A-S2 deadman rekey | ✅ H-U6;§4.7、§5、§7、N7 已一致(N7 翻轉後的預期改成「重開、新 boot_id、IRK 雜湊不同」) |
| A-m1 btmon fixture | ✅ 改成實錄完整輸出、值欄位換假值、canary 先過、`UNPARSED`=0 |
| A-m2 N2b | ✅ adv-off 後 5 s 與 30 s 取樣,並比對 FAIL 原因 |
| A-m3 lease 邊角、staging | ✅ `bt/<run_id>/`、`dm-fire` 重試、`acquire` 的三種情況。新的邊角見 n2、n3 |
| A-m4 rekey 前提、路徑 | ✅ |
| A-m5 比對 FAIL 原因 | ✅(§4.10 最後一列) |
| A-m6 N3 比對項 | ✅ |
| B 的各項(N11、dm.new、§7 數字、`$SECONDS`、P6 adv、兩台 lease、plain reboot) | ✅ 都已對應。N11 改成刪 identity + `kill -9`,有 E31 / E27 的路徑支持,是真的注入故障 |

---

## MAJOR
無。

## MINOR
- **n1 N3:hold 沒生效時的「立刻回 A」可能已經太晚**:02 沒有乙太網,主機要等 02 在 trial 裡加入 mesh 後才 ssh 得到。而加入 mesh 正是 commit 的前提;hold 沒生效時,最快約 30 s 就會 commit(Y2)。所以步驟 4 驗出「hold 沒生效」時,trial 可能已經 commit 了。這時 `reboot committed` 會回到 **B**(wsl.2)。不會失聯(能 commit 代表 mesh 健康),但與步驟 4「停下來回報」的描述不符。修法:
  - (a) V2 從**唯讀掛載的 slot B rootfs** 的 `/etc/batman-build` 用與 `version()` 相同的 sed 取得,不要從 payload metadata 推,讓旗標與 `version()` 的比對必定一致(Y1);
  - (b) 步驟 4 加一個分支:看到 `autocommit.committed` 或 slot B 已是預設 → `batman-slot rollback`(回 A)→ `reboot committed`,N3 記為「無法執行」;
  - (c) 步驟 2 的讀回比對改成「旗標 == slot B 的 `BATMAN_VERSION`」。
- **n2 舊的 deadman 可能在 lease 已延長後動作**:先 arm 新的、再取消舊的,中間 ssh 斷了的話,舊的 deadman 會留著。舊的 `dm-fire` 醒來後只驗「lease 仍屬該 run」就執行還原,但這時 lease 已被新 arm 延長,harness 可能還在正常跑,於是在測項中途 restore → 假 FAIL。修法:`dm-fire` 動作前再驗兩件事:lease 到期時間 ≤ 現在;自己的 pgid 是 `ble-state/dm`(或 `dm.new`)記錄的那一個。任一不成立就安靜退出,只寫 log。
- **n3 `dm-fire` 等鎖不放棄,遇到卡死的持鎖者會永遠等下去**:持鎖的若是一個卡住的指令(例如 D-Bus 卡住的 bluetoothctl;節點上沒有 `timeout`),deadman 就永遠不動作,04 可能停在 `flipped` 或帶著 adv instance。這正是 deadman 要處理的故障情境。修法:重試超過一段時間(例如 10 分鐘)後,先殺掉 lease 擁有者記錄的 harness 群組,再不拿鎖直接還原(H-U6 的重開也一樣),並寫 log。另外,每個持鎖的指令都要有上限:用腳本內的 `sleep` + kill,或 bluetoothctl `--timeout`。
- **n4 N3 的 EXIT trap 要負責清 hold 旗標**:步驟 2 寫了 V2 旗標之後,如果步驟 3 的 OTA 失敗,或腳本在重開前被中斷,旗標會留在 p6。之後任何一次 tryboot 開機都會先把它吃掉(版本不符就丟棄並刪除),所以不會擋住別的 OTA。但步驟 7 的「旗標已不在」只在正常路徑檢查。N3 自己的 EXIT trap 要做 `rm` + 讀回驗證(沿用 `restore_node` 的那兩行,Y3),並把結果寫進 log。
- **n5 deadman 重開(H-U6)與 lease**:翻轉之後每一段配對各 arm 一次 900 s 的 deadman,`irk-exposed` 一直存在到 rekey 驗證成功為止 → 在這期間任一段 harness 死掉都會重開 04 ✅。建議在 §4.7 明寫「rekey 驗證通過、刪除 `irk-exposed` 之後,下一次 arm 的還原動作才會退回 `restore`」,讓實作者不會漏掉 rekey 期間(bluetoothd 停止、identity 已刪)那一段:那段 harness 若死掉,標記還在,同樣會重開,行為正確,但要寫出來。

## 新設計的其他部分(查過,沒有發現)
- 兩台 lease 永遠先 04 再 02,所有 run 同一個順序,不會死鎖 ✅。
- lease 的 boot_id 不是本次開機就視為作廢、可以接手:重開後 tmpfs 上的狀態都已清空 ✅。
- P6 在 bluetoothd 沒跑時只讓那一台的 tier B 測項 FAIL,不擋整個 run ✅(延續 R2 的原則)。
- §7 的窗口數字(900 s / 3300 s)與 §4.7 的 deadman 期限一致 ✅。

## 裁決
**APPROVE**:BLOCKER 0、MAJOR 0、MINOR 5。n1–n5 都是實作時就能吸收的邊角,不需要再一輪整份審查。其中 n1(a)/(b) 與 n4 牽涉 02 會不會停在舊版槽,建議在實作 N3 腳本時先做,並在 PR body 附上它們的結果。

未驗 ⚠️:wsl.2 image 內的 `batman-autocommit:286`(作者已唯讀掛載確認,我沒有重看);02 在 trial 中加入 mesh 所需的實際時間(決定 n1 的時序風險有多大)。
