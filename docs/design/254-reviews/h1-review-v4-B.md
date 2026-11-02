# 審查 B 第 4 輪:`254-h1-harness.md` v4(整份)

本輪獨立審查,範圍是整份 v4,並逐條核對 §13 的對應。節點只做唯讀操作(cat / ls / 讀 `tar -xzOf … metadata`),沒有跑 bluetoothctl / btmgmt,沒有建檔或重啟,也沒有印出任何 IRK。H-U6(deadman 重開 04)是使用者決定,不重議。

**結論:REJECT(窄)。0 BLOCKER / 1 MAJOR / 6 MINOR。**

v4 的方向已經正確:N3 的旗標改寫成「payload 的版本」,不再沿用 `precheck` / `held_trial`,進 trial 後先驗 hold 是否生效,回 A 用 explicit partition。

剩下 1 個 MAJOR:**「payload 的版本」這個字在 payload 裡有一個同名但內容不同的欄位**。payload 的 `metadata` 裡的 `version=` 是建置時間戳(實讀 `20261018-113030`),不是 `BATMAN_VERSION`。照字面去讀 payload 的 version,寫進旗標的值會和 wsl.2 的 `version()` 不符,第 3 輪的 B1 會原樣重現。另外,「hold 沒生效」時的 fallback 沒有處理「autocommit 已經 commit 了」的情況。

---

## 0. 本輪驗證
| 項目 | 結果 |
|---|---|
| payload 的 `metadata` 內容 | ✅ 02 `/opt/batdata/ota.tar.gz`:`board=ekh-bcm2711`、**`version=20261018-113030`**、`size=112631352`;寫入處是 `scripts/build-ab-payload.sh:69`:`version=$(date +%Y%m%d-%H%M%S)` |
| autocommit 拿什麼比對 | ✅ `batman-autocommit:66`:`version()` = `/etc/batman-build` 的 `BATMAN_VERSION`;比對在 `:269-287`(不符就 `HOLD-COMMIT-DISCARDED`) |
| slot B 的版本字串從哪裡可靠取得 | ✅ 02 `/opt/batdata/state/slot-B.protected` = `1.5.12-wsl.2+f2f2bf6.fw9d87d02`;由 `95-batman-storage:717` 從該槽的 `/etc/batman-build` 寫入;OTA 寫入該槽時會刪掉這個檔(`batman-slot:432-433`) |
| hold 只在 tryboot 時被讀取 | ✅ `:269` `dt_tryboot`;旗標放在 p6(`/opt/batdata/state`),兩個槽都看得到 |
| 健康的 trial 多快會被 commit | ✅ `:460-502`:每 `POLL=10` s 檢查一次,服務 `NEED` 次穩定加上 mesh 取樣就 commit,只要數十秒到幾分鐘;commit 時刪 bad-slot(`:502`) |
| revert watchdog | ✅ `:182-232`;deadline 不會短於 `MIN_WINDOW=300`(`:34`、`:382`) |
| 02 目前沒有 bad-slot | ✅ `cat: can't open '/opt/batdata/state/bad-slot'` |
| E28(wsl.2 有版本相符的 hold) | ⚠️ 作者唯讀掛載確認;我沒有重做 |
| E31 / N11 的路徑 | ✅ 和第 3 輪讀到的 `adapter_shutdown` 一致:刪 identity → kill -9 → procd 在上電狀態下 respawn → `set_privacy` 被拒,kernel 繼續用舊 IRK。新的 N11 能做出 E27 的狀態 |

---

## MAJOR

### M1 N3 的 `V2` 來源寫成「從 payload 讀出」,但 payload 裡叫 `version` 的欄位是建置時間戳;hold 沒生效時的 fallback 也沒處理「已經 commit」

**情境**:
1. §4.10 N3 步驟 1 寫「從 payload 讀出版本字串 `V2`(`1.5.12-wsl.2+…`)」。payload 裡**唯一**叫 version 的欄位是 `metadata` 的 `version=`,內容是 `20261018-113030`(`build-ab-payload.sh:69`,02 實讀)。實作者照字面用 `tar -xzOf … metadata | sed -n s/^version=//p`,旗標就會是時間戳。wsl.2 的 `version()` 回的是 `1.5.12-wsl.2+…`,兩者不符 → `HOLD-COMMIT-DISCARDED` → 健康的 trial 照常被 commit。這就是第 3 輪 B1 的原樣重現。設計括號裡寫的值是對的,但「從 payload 讀」指向錯的欄位,兩者互相矛盾。
2. 步驟 4 的保護是「進 trial 後先驗 hold;不符就立刻 `batman-slot reboot committed` 回 A」。但 autocommit 只要數十秒到幾分鐘就會 commit 健康的 trial(`:460-502`)。主機要等 02 經過 mesh 重新連得上,才可能比 autocommit 晚。如果它**已經 commit**(`$R/autocommit.committed` 存在,`[all]` 已經指向 B),`reboot committed` 會**開回 B**,不是 A。步驟 4 的 fallback 在這個最需要它的情況下是錯的。

**修法**
- 契約寫死 `V2` 的來源:**slot B squashfs 的 `/etc/batman-build` 的 `BATMAN_VERSION`**(唯讀掛載 `mmcblk0p4`)。在 OTA 前另外和 `/opt/batdata/state/slot-B.protected` 交叉比對,兩者必須完全相同(含 `+…` 後綴)。明寫**不得**使用 `metadata` 的 `version=`(它是時間戳)。旗標寫入後讀回,三者並列印出。
- 步驟 4 依序判斷:
  - (a) 先讀 `autocommit.committed` / `batman-slot is-trial`;
  - (b) 若已經 commit:先 `batman-slot rollback`(把 `[all]` 改回 A,這是 wsl.2 的 batman-slot,`:731-741` 那段要先唯讀確認 wsl.2 也有),再 `reboot committed`,回來後斷言 slot A 已 committed;
  - (c) 若還沒 commit 但 hold 沒生效:立刻 `reboot committed`。
- 主機要在步驟 4 第一次連上時就讀 `autocommit.deadline`,步驟 6 的等待時間才有具體數字。連不上時用 `MIN_WINDOW` 加 autocommit 的預設 T 再加 `DEFER_MAX` 估算,並把用的數字寫進 log。
- 補一個白箱前測,不必換槽:拿上面取得的 `V2` 和 slot B 的 `/etc/batman-build` 做字串比對,不相等就不准開始 N3。

---

## MINOR

**m1 過渡期間兩個 deadman 同時活著**。「先 arm 新的再取消舊的」之間若 ssh 斷線,舊 deadman(到期較早)和新 deadman 會同時存在。`dm-fire` 只檢查「lease 仍屬這個 run」。舊的那個會在較早的時間點觸發,在 harness 可能還活著時執行還原,結果是 fail-closed 的假 FAIL。修法:`dm-fire` 觸發時,確認自己的 pgid 等於 `ble-state/dm`(或 `dm.new` 中最新的那個),不是就直接退出。

**m2 btmon fixture 會進公開 repo**。fixture 錄的是「目標段 + 翻轉段」的完整 `btmon -r`。翻轉段除了 04 的 IRK,還有 **02 的 IRK**(02 開了 privacy,會把 Identity Information 交給 04),以及 LTK / EDIV / Rand / CSRK。`canary` 只比對 04 的 `identity`,抓不到 02 的 IRK 和這些值。修法:
- 改用白名單遮蔽:只保留標頭行和白名單裡的子行名稱,其他子行的值一律換成假值;
- canary 也比對 02 的 `identity`;
- 錄完後 02、04 都重開(兩台的 IRK 都在 tmpfs,重開即作廢);
- 進 repo 前跑 gitleaks,並人工核對 diff。

**m3 `bt/<run_id>/` 的清理**。每個 run 都在 tmpfs 留一個目錄,重開才會清掉。要寫明 `release` 時刪掉自己的目錄,`ble-recover` 刪掉 boot_id 已過期的 run 留下的目錄。

**m4 N3 步驟 7 預期會出現的差異**。OTA 寫入 slot B 時會刪 `slot-B.protected`(`batman-slot:432-433`)。這個檔由 `95-batman-storage:717` 在該槽開機時重寫,但它在 uci-defaults 裡,p5 overlay 共用時不一定會再跑一次。步驟 7 比對 `/opt/batdata/state` 時,這一項可能和步驟 1 不同。要預先列為「預期中的差異」並說明原因,否則每次都會被當成意外,或被忽略。

**m5 deadman 重開 04 前要留下紀錄**。H-U6 的重開是在沒有人看的情況下發生的。`dm-fire` 應該先在 p6 上寫一行 `/opt/batdata/log/…`(run_id、原因、時間),再 `batman-slot reboot committed <reason>`,讓 boot-reasons 和下一次 run 都看得到原因。tmpfs 裡的 log 會隨重開消失。

**m6 §13 的對應**:
- B-B1:機制已改對,但 `V2` 的來源有歧義(M1)。
- B-M1 → H-U6:成立。§4.7、§5、§7、N7 已一致。
- N11:成立。
- `dm_arm` 中斷:成立,另見 m1。
- §7 的數字:成立。
- `$SECONDS`:改成主機 `/proc/uptime`,成立(MSYS 和 WSL 都有 `/proc/uptime`)。
- P6 需要 bluetoothd:成立。
- 兩台的 lease:成立。
- plain reboot、bad-slot:成立。E29 說 commit 會刪 bad-slot,和 `:502` 一致。
- A 的各項,我抽查了 N2b(adv-off 之後 5 s / 30 s 各取樣一次,有鑑別力)和 fixture(見 m2),都成立。

---

## 結論
**REJECT(窄)**。只剩 M1:
- 把 `V2` 的來源寫死為 slot B 的 `/etc/batman-build`,並和 `slot-B.protected` 交叉比對;
- 補上「已經 commit」時的 fallback(先 rollback,再 reboot committed)。

這兩點改完之後,我預期可以 APPROVE-WITH-CHANGES(只剩 MINOR)。
