# 審查 B 第 5 輪:`254-h1-harness.md` v5(整份)

本輪獨立審查,看的是整份 v5,並逐條核對 §14 的對應。節點只做唯讀操作,也沒有印出任何 IRK;這一輪的結論全部來自設計文字與前幾輪已讀過的原始碼,沒有新的節點讀取。

**結論:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 5 MINOR。**

第 4 輪 M1 的兩個部分都已修好:V2 只取自 slot B 的 `/etc/batman-build`,並與 `slot-B.protected` 交叉比對;另外補上了「已 commit 在 B」的分支。dm-fire 加的三項檢查(lease 屬於本 run、lease 已到期、pgid == `dm`)也成立。

剩下的 MAJOR 是 v5 新增的 **N3 EXIT trap**:它無條件「刪 hold 旗標」。如果 trap 在 OTA 已經啟動、但 trial 還沒開機之前觸發,02 就會開進一個沒有 hold 的 wsl.2 trial,健康時 autocommit 會把它 commit。這正是 v3 B1 想擋住的結果,只是換了一條路徑。

---

## §14 對應核對
| 發現 | 結果 |
|---|---|
| B-M1 V2 來源 | ✅ 步驟 1 寫死只用 slot B squashfs 的 `/etc/batman-build`,與 `slot-B.protected` 交叉比對,並明文禁用 metadata 的 `version=`(E32 與我第 4 輪實讀一致) |
| B-M1 後半:已 commit 在 B | ✅ 步驟 4(b)先 `rollback` 再 `reboot committed`;另有 TOCTOU 小洞,見 m1 |
| B-m1 舊 deadman | ✅ dm-fire 驗 lease 已到期 + pgid == `dm` |
| B-m2 fixture | ✅ 白名單遮蔽、兩台各自 canary、gitleaks;但「換 02 IRK」與 §3 衝突,見 m2 |
| B-m3 清理 | ✅;preflight 的「信任」說明要跟著改,見 m3 |
| B-m4 預期差異 | ✅ 步驟 7 已列 |
| B-m5 重開前記原因 | ✅ 寫進 p6 log,`reboot committed ble-dm-254` |
| A-n3 等鎖上限、持鎖 watchdog | ✅ |
| A-n4 EXIT trap | ❌ 新問題,見 M1 |
| A-n5 rekey 中途死掉 | ✅ `irk-exposed` 只在驗證通過後才刪,所以會重開 |

---

## MAJOR

### M1 N3 的 EXIT trap 無條件刪 hold 旗標;OTA 啟動後才觸發時,會讓 02 開進沒有 hold 的 trial 並被 commit 在 wsl.2

**情境**:步驟 3 依 fault-injection 的做法,用 `setsid` 在背景跑 `sysupgrade -n`(`fault-injection.sh:191`),然後等新的 boot(`waitboot` 上限 600 s,`:192`)。在下面任一情況,腳本會在 sysupgrade 還在寫入、或節點正在重開時就結束:
- 寫入加開機超過 600 s;
- 操作者按 Ctrl-C;
- 主機端某一步出錯。

腳本結束時 EXIT trap 第一步就是「刪 hold 旗標並讀回確認」。這時節點的 ssh 還連得上(stage 1 尚未重開),所以刪除會成功。接著節點 tryboot 進 slot B 時:
- p6 上已經沒有旗標,wsl.2 的 autocommit 不會 hold(`batman-autocommit:269` 的條件不成立);
- trial 健康時,幾十秒到幾分鐘內就會 commit(E33);
- trap 接下來判斷「節點停在哪個槽」時讀到的還是 A(還沒重開),於是放心結束。

結果:02 被 commit 在 wsl.2,沒有人知道,直到下一次全套的 P3 版本一致檢查 FAIL。

反過來,如果**不刪**旗標:旗標內容是 V2,只會影響「之後某次 tryboot 剛好開進 wsl.2」。到時那個 trial 會被 hold,deadline 一到就 revert,是無害的(E28)。也就是說,刪旗標的風險遠大於留著它。

**修法**:把 EXIT trap 寫成依階段決定的狀態機:
- **OTA 啟動前**(還沒送出 `sysupgrade`):刪旗標、讀回確認,和現在一樣。
- **OTA 啟動後**:**絕不刪旗標**。在有上限的時間內等新的 boot,出現後走步驟 4 的判斷。等不到就印出「02 可能正在進入 trial;旗標保留 = trial 會被 hold,deadline 一到會 revert」,並以 FAIL 結束。
- 只有確認「新 boot 是在 slot A、非 tryboot、committed」(例如 EEPROM 開錯槽的 no-op),或確認 sysupgrade 失敗且 boot_id 沒變時,才刪旗標。
- 加一個負對照:用 stub ssh 模擬「OTA 已啟動 → 腳本被中斷」,斷言 trap **沒有**送出刪旗標的指令。

---

## MINOR

**m1 步驟 4(a)有 TOCTOU**。讀到「尚未 commit」到送出 `reboot committed` 之間,autocommit 仍可能 commit。commit 後 `[all]` 指向 B,這時 `reboot committed` 會開回 B。修法:(a)、(b) 兩個分支一律先 `batman-slot rollback` 再 `reboot committed`。在 B 上執行 `rollback` 一定會把 `[all]` 設成 A(`batman-slot:731-741`,以目前執行中的槽為準;A 沒有 BADMARK),兩種情況都安全。回來後由步驟 7 斷言落在 slot A。

**m2 「換 02 的 IRK」違反 §3 的擁有權**。fixture 程序要「停 bluetoothd → 刪 02 的 `identity` → 啟動」,但 §3 寫的是「02 `identity`:harness **不可**改」。這步也沒有 kernel 驗證:只靠 SIGTERM 正常停止時的斷電(E31),碰上 E27 的路徑就沒有作廢。修法(二擇一):
- 改成**錄完後重開 02**:tmpfs 清空,IRK 一定換,也不必動 §3;
- 或在 §3 加一條「僅 fixture 錄製程序可改,先 power off,事後重開確認」的例外。

**m3 preflight 現在會刪檔**。§4.1 的「信任」寫著「只讀節點(P6 staging 例外)」,但新增的 `bt/<run_id>/` 清理讓 preflight 會刪目錄。要更新「信任」那一段;刪除條件也要多一項「該 run 沒有活著的 deadman」(用 `dm` / `dm.new` 記錄的 pgid 判斷),不能只看 lease 在不在。

**m4 「持鎖指令卡死,10 分鐘後 dm-fire 不拿鎖直接還原」**。要寫明:dm-fire 只殺**同一個 run_id** 的群組(依 `bt/<run_id>/` 與 `dm` 記錄判斷)。如果持鎖的是另一個 run 的 `acquire`,不應被殺。另外,不拿鎖直接還原時,先在 p6 log 寫一行說明。

**m5 步驟 6 的保守上限**。讀不到 deadline 時,設計寫「MIN_WINDOW 300 s 起算的保守上限」,但 deadline 實際是 `max(T, start+MIN_WINDOW)`(`batman-autocommit:382`),而 T 是 autocommit 的設定值,不是 300。要寫出 T 的來源和實際數字(從 slot B 的 squashfs 唯讀讀出預設值),否則主機可能太早判定「回不來」,並寫出「需要實體處理 02」的錯誤結論。

---

## 結論
**REJECT(窄)**。只剩 M1:EXIT trap 要依階段處理,OTA 啟動之後絕不刪 hold 旗標。另外建議把 m1 的「一律先 rollback」一起改掉。改完之後,我預期可以 APPROVE-WITH-CHANGES(只剩 MINOR)。
