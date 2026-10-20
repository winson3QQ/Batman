# #254 PR-H1 harness 設計 v7 — 獨立審查 A(第 7 輪,整份)

審查對象:`254-h1-harness.md` v7 整份(與 v6 diff)。H-U7(tier B 收尾以 `reboot committed` 重開 02)不重議。節點全程唯讀;沒跑 bluetoothctl / btmgmt;沒印出 IRK。

## 更正紀錄(我第 6 輪漏掉的)
第 6 輪我只核對了「在 slot B 上執行 `rollback`」的語意(`[all]`=A,無害),就判 APPROVE。我沒有去找所有會呼叫 `rollback` 的路徑:EXIT trap 在正常結束時也會觸發,那時節點已經在 slot A;`rollback` 在 A 上執行會把預設改成 B(E34),02 下次重開就會以 committed 開進 wsl.2。B 抓到的 BLOCKER 是對的,我第 6 輪的 APPROVE 不成立。這一輪我改成逐一列出每個 `rollback` / `reboot` 的呼叫點,並對照節點當時可能所在的槽來審。

## 每個呼叫點 × 節點所在的槽
| 呼叫點 | 節點可能在哪 | v7 的行為 | 結果 |
|---|---|---|---|
| 步驟 4 hold 沒生效 | B(trial,已 commit 或還沒) | `back_to_a`:active=B 且版本==V2 → rollback + `reboot committed` | ✅ `[all]`=A;這條路徑與 autocommit 自己 revert 時用的是同一個指令(R4 已驗) |
| 步驟 6 回 A | B(held trial) | 同上 | ✅ |
| EXIT,`PHASE=returned`(正常結束) | A | 只印狀態 | ✅ 不呼叫 rollback(stub 案例 3) |
| EXIT,`PHASE=trial` | B,或已被 revert 到 A | `back_to_a` 是條件指令,在 A 上不動作 | ✅(案例 5) |
| EXIT,`PHASE=ota` | 還沒重開(A)/ tryboot 落在 A / B | 等新的 boot:落在 B 且版本==V2 → `back_to_a`;落在 A → 只印狀態 | ✅(案例 1、4) |
| 指令送出後 ssh 斷線 | 不確定 | 條件與動作在同一個節點端指令內完成,沒有主機端的檢查時間差 | ✅ |
| `back_to_a` 內 rollback 成功、reboot 前中斷 | B,`[all]`=A | 下次重開回 A | ✅ 安全 |

結論:`rollback` 只會在「active = B 且版本 == V2」時執行,B1 已關閉。

## §16 對應表逐項檢查
| v6 發現 | 結果 |
|---|---|
| B-B1 | ✅(上表) |
| B-m1 覆寫 `dm.new` 會留下孤兒 | ⚠️ 修法引入一個沒有 deadman 的窗口,見 w1 |
| B-m2 revert 時限 | ✅ 以 wsl.2 為準(E35),從 OTA 送出起算 ≤ 2280 s |
| B-m3 EXIT 在正常結束也觸發 | ✅ |
| A-u1 / u2 02 的 IRK、重開方式 | ✅ H-U7 + E36;§4.5、§7、§8 都已更正。canary 的範圍見 w2 |
| A-u3 殘留的 hold 旗標 | ✅ P6 列為殘留並 FAIL,N3 結尾附安全清除步驟 |

---

## MAJOR
無。

## MINOR
- **w1 `dm_arm`「先取消既有的 `dm.new`」會開一個沒有 deadman 的窗口**:`dm.new` 存在,代表上一次 arm 在 `mv` 之前中斷了。那時舊的 `dm` 可能已經被取消,所以 `dm.new` 那個 deadman 可能是**唯一**還在保護節點狀態的。v7 先殺掉它、再 arm 新的:中間如果 ssh 斷了,就完全沒有 deadman,而節點可能正處於 `flipped` 或有 adv instance 的狀態(下一次 preflight 會因標記 FAIL,但空中狀態不會被還原)。另外,B-m1 擔心的孤兒其實無害:它的 pgid 既不在 `dm` 也不在 `dm.new`,依 v6 的規則醒來時只會退出。修法:先把既有 `dm.new` 的 pgid 記進變數 → arm 新的、寫 `dm.new` → 再取消舊的 `dm` 與舊的 `dm.new` 兩個 → `mv`。保持「任何時刻至少有一個 deadman」。N7b 加一個變體:「上一次 arm 中斷留下 `dm.new`,這一次 arm 在取消步驟中斷」。
- **w2 一般 run 的 canary 也要比對 02 的 IRK,並排在 02 重開之前**:v7 已確認 02 的 IRK 會經空中外洩(E36)。但「`canary` 同時比對 04 與 02 的 IRK」只寫在錄 fixture 的段落;一般 tier B run 的 canary(§4.7)仍然只送給 04 比對。抓回的 log 裡雖然目前沒有輸出金鑰值的來源(btmon-judge 不輸出值、bluetoothctl 不印金鑰),但 canary 正是用來擋這類「目前沒有」的錯。修法:收尾順序寫明為「抓回 log → 04 與 02 各自跑 canary → 04 rekey → … → 02 `reboot committed`(H-U7)」。02 的 canary 必須在 02 重開之前跑,因為重開後 identity 就換了。
- **w3 「tryboot 落在 A」之後的 slot B 狀態要記錄**:這個情況下 slot B 已被重寫為 wsl.2,OTA 也刪掉了 `slot-B.protected`(E32)。建議 N3 在「無法執行」的報告中印出 `batman-slot verify`、autoboot 的 `[all]` / `[tryboot]`,以及 hold 旗標狀態,讓人確認下一次重開不會意外進入 B。

## 新設計的其他部分(查過,沒有發現)
- `back_to_a` 的條件用 `batman-slot active` 與 `/etc/batman-build`。`active` 的輸出是 `A` / `B`(02 上已確認:`batman-slot active` → `A`);V2 來自 root 擁有的 squashfs,放進指令字串沒有注入的疑慮 ✅。
- H-U7 的 02 重開排在 BLE 區塊收尾、ab-selftest 之前;`reboot committed` 回到 committed 的 slot A,滿足 ab-selftest 的前提(BENCH 在 slot A)✅。

## 裁決
**APPROVE**:BLOCKER 0、MAJOR 0、MINOR 3。v6 的 BLOCKER 已確實關閉(每個呼叫點都核過,見上表)。w1 建議在實作前先改回「任何時刻至少一個 deadman」的順序;w2、w3 在實作時吸收。
