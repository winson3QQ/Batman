# 審查 J：`docs/design/329-ble-settle.md` v1（BleGate settle + 連線失敗狀態碼）

審查者 J（獨立、唯讀）。範圍：整份設計 + `app/lib/src/nodelink/{ble_gate,node_link,ble_backend,handoff}.dart`（branch test/329-retest-a @ c795d63）+ plugin 原始碼（reactive_ble_mobile 5.6.0 / flutter_reactive_ble 5.6.0）+ 原始證據 `b2/f22/`、`b2/f22flip/`（逐 run 檔重算，不用 `*.out` 摘要）。
重算的逐筆表在 `b2/revJ-all.txt`（每個 run 取最後一個 `BMAPP nl 0.0 round 0` 之後的行；f22 run18 的午夜後行被原腳本的無日期過濾丟掉，見 m-3）。

**結論：REJECT（v1 照寫不實作；方向可能對，改動小，但證據數字不成立、對照有混淆、settle 放的位置讓每個 close 都付錢）。修 M-1…M-5 後整份再審一次。**

---

## 重算的證據（✅ 逐 run 檔）

| | 基線 f22（20 次） | 翻轉 f22flip（20 次） |
|---|---|---|
| 有 attempt 行的嘗試 | 33（run18 第 2 輪的那次被過濾掉） | 33 |
| 失敗（`connected=-1`，全部是 Android `status=133`、connect() 後 5.0 s） | **5** | **1** |
| ├ 「連著的連結 cancelOpen 後 ≤ 12 ms 就 connect 別台」→ 133 | 2（run07 `4AA574_C`、run18 `60AC6E_0`，都是 04） | 0 |
| └ **冷啟動第一條連線**（此 process 之前沒有任何連線）→ 133 | **3**（run08/12/14，都是 02 的 `452DD3_A`） | 1（run08，02 的 `5C1799_D`） |
| 「連著的連結斷後立刻（≤ 12 ms）換台」次數 / 失敗 | 6 / 2（run02,05,07,10,17,18） | —（全部 ≥ 1 s）：10 次 / 0（+2 次 5–6.5 s 的） |
| 「失敗的連線後立刻（≤ 7 ms）連別台」次數 / 失敗 | 4 / 0（run07 →`452DD3_A`；run08/12/14 →04） | 1 / 0（run08，間隔 1 s） |
| 冷啟動到 `round end {7d2c: read}`（nl 時鐘）中位數 | 6.9 s（run18 未知、≥ 41 s） | 9.05 s |

設計文件寫的「37 次對 04 的嘗試 3 次失敗」「36 輪」「對 04 0/35」「33/33」用這些檔重算不出來（M-1）。

---

## MAJOR

**M-1 證據數字重算不出來，而且漏掉了基線一半以上的失敗類別。**
- 情境：讀者照 §1 的表會以為基線 3 次失敗都是「剛斷線就連」，修完 0 次。實際基線 5 次失敗中 3 次是**冷啟動第一條連線**（run08/12/14：`connect() - device: 452DD3_A` 在 `onScannerRegistered` 後 26–670 ms，此 process 沒有任何前一條連線），settle 不可能影響它們。
- 證據：`f22/run08.phone` 23:45:13.257 connect → 23:45:18.267 `status=133`；run12 23:50:46.423 → 51.432；run14 23:53:35.627 → 40.639；三者都是 process 的第一個 connect()。設計 §1 只提到翻轉組的那 1 次。
- 修：§1 的表照上表重寫（分「斷線後立刻換台」「冷啟動第一條」「失敗後立刻連」三類，各給次數 / 失敗），數字附產生它的指令；把 `*.out` 摘要錯的事寫明。

**M-2 翻轉測試有混淆，負向對照不成立；樣本也撐不起「修好了」。**
- 情境：基線 23:35–00:03、翻轉 05:45–06:12，相隔 6 小時；04 / 02 的位址全換了（基線 `7C7116_D/4AA574_C/60AC6E_0`，翻轉 `7E10C1_C/473774_F/42ECB7_B`）；02 是 dev2 的節點、行為不受控。**settle 碰不到的那一類（冷啟動第一條 → 133）也從 3/11 降到 1/13**，說明兩個場次的環境本身就不同；「改善」有多少來自 settle、多少來自環境，分不出來。
- 數字：真正被 settle 影響的那一類，基線 2/6 失敗、翻轉 0/10（另 2 次間隔更長）。Fisher 精確檢定：2 次失敗都落在 6 筆那組的機率 = C(6,2)/C(16,2) = 15/120 ≈ **0.125**——不顯著。
- 另外：「失敗的連線後立刻連別台」基線 4/4 成功，這是對「任何斷線後立刻連都會 133」的反例，支持更窄的假設「前一條**真的連上過**的連結還沒真正拆掉時就連別台」（M-3）。
- 修：同一場次內交錯 A/B（同一個 build 加一個 debug 開關或兩個 build 每 run 輪替），預先定好指標「連著的連結 cancel 後 < 50 ms 換台 → 133 率」；最好加一個只做「02 讀完 → 立刻連 04」的定向腳本，每組 ≥ 30 次換台。判準寫在動手前。真機 §8 的「對 04 失敗 ≤ 1 次」不能分辨 settle 有沒有效（冷啟動那類會稀釋）。

**M-3 「系統回報斷線後再等 1 s」的機制描述是錯的：gate 等的「斷線」是 plugin 自己合成的，不是協定堆疊的回報。**
- 證據：`reactive_ble_mobile-5.6.0/.../ble/DeviceConnector.kt` `disconnectDevice()`：先 `sendDisconnectedUpdate(deviceId)`（直接送 `DISCONNECTED`）**再** `disposeSubscriptions()`（這時才真的叫 RxAndroidBle 斷線）。Dart 端 `flutter_reactive_ble-5.6.0/lib/src/device_connector.dart:73` `onCancel: () => _blePlatform.disconnectDevice(id)`。所以 `GateLink.close()` 的 `_gone` 在 cancel 後幾 ms 就完成——不管鏈路層斷了沒。f22 run07：attempt 行 54.218 → `cancelOpen()` 54.229 → GattService `onDisconnected` 54.232（3 ms，是 client 層的回報，不是 LL 斷線）→ 下一個 `connect()` 54.239。設計 §4.2 的「M-1 實測 3–14 ms」量的就是這個合成事件。
- 影響：(a) §2.1、§3 契約「系統回報斷線（或 5 s）後再 1 s」實際上是「要求斷線後約 1 s」；(b) 為什麼是 1 s 沒有機制（⚠️ 推論：Android 在最後一個 GATT client 離開後由 idle timer 拆 ACL，舊 ACL 還在時對別台發 LE create connection 失敗；這要 btsnoop / `bt_stack` 行驗證），換手機 / Android 版本可能需要不同值。§1 引的 `Creating le direct connection`、`on_create_connection_timeout`、`Connection Accept Timeout` 在 `f22/` 的檔裡**沒有**（f22.sh 的 grep 沒收 bt_stack 行），scratchpad 也搜不到；目前無法覆核。
- 修：§2/§3 照實寫「plugin 在送出斷線要求時就回報 disconnected；settle 是時間上的保守值，不是等堆疊」；把 §1 引的 Android log 原文存檔（含 bt_stack 行）；若要知道真正的拆鏈時間，收一次 btsnoop（HCI Disconnection Complete 對 cancelOpen 的時間差），用它定值，而不是只靠一次 1 s 翻轉。

**M-4 settle 放在 `close()` 裡，讓每個 close 的呼叫端都多等 1 s，包括後面根本沒有下一條連線的情況；讀到的結果也晚 1 s 才給。**
- 證據（翻轉組本身）：基線 `round 0 end {…read}` 在最後一次 attempt 行後 5 ms；翻轉組在 **1.0 s 後**（例 flip run02 attempt 05:46:38.353 → round end 05:46:39.360）。原因 `node_link.dart:573-580`：`await mine?.close();` 在 `core.result(...)` 之前——讀到的狀態晚 1 s 才進 core / 畫面，中位數 6.9 → 9.05 s 的一部分就是這個。
- `close()` 的呼叫點（全部，file:line）與多等的代價：
  - `node_link.dart:575` `_run`：每次嘗試後 +1 s，**且延後 core.result**（上面）。
  - `node_link.dart:594` `_abort`：`l?.close().then(_pump)`，下一輪 +1 s。
  - `node_link.dart:397` `_lfAttempt`（流程登入）：每次失敗 / 別人的節點 +1 s → R-7「正在連到節點…」。
  - `node_link.dart:605-608` `_dropAll`（`acquire` 209、`dispose` 617）：以 100 ms 輪詢 `gate.links`，**上限 50 次 = 5 s**；`close()` 最壞變成 `closeMax 5 s + 1 s = 6 s` → 超過這個上限時 `reg.acquire` 照樣拿到 lease，gate 仍有一條連結（流程的 loginFor 會在 `node_link.dart:299/313` 等 `gate.links == 0`，不會 Refused，但吃掉 60 s 登入預算）。每次 acquire 至少 +1 s（R-7 起點）。
  - `handoff.dart:87` `LoginHandoff.close()` ← `owner_console.dart:672`、`op_session.dart:110/114/126/167/175/187/197`、`net_run.dart:133/212/229/252/277/291/402/430`、`node_link.dart:306`：每個流程結束 / 每台之間 +1 s；`op_session.dart:126` 註明 console 先關再放 lease → **lease 釋放晚 1 s**，NodeLink 的「釋放後 6 s 一輪」也順延。
  - `ble_gate.dart:246` `revoked()`：不 await，gate 多佔 1 s 的 link 名額；`_links.remove` 在 `finally`（`ble_gate.dart:126`），這 1 s 內任何 `gate.connect` 都 `Refused('a link is already open')`。現在只有 NodeLink 會 connect 且都先看 `gate.links`，所以目前不會出錯，但契約要寫明。
  - `claim_recovery.dart:531/627`、ClaimPage：自己用 FlutterReactiveBle，不經 gate——**它們之後連 NodeLink 的下一條沒有 settle**（設計 §3 已承認，但 raw lease 釋放後 NodeLink 6 s 才開一輪，⚠️ 推論不會撞；寫進去）。
- 修（擇一，建議 a）：(a) **把 settle 移到 gate 的「開下一條」**：gate 記 `lastUpAt`（最後一條**曾經 connected** 的連結被要求斷線的時間），`connect()` 時若距今 < settle 才延後送出 backend.connect（延後算在 8 s 預算內或另加，寫明）；`close()` 契約不變。這樣只在真的要換台時付錢，結果、lease 釋放、dispose、撤回都不延後，也自動涵蓋「失敗的連線後不必等」（M-2 的 4/4 證據）。(b) 至少在 `_run` 把 `core.result` 移到 close 之前，並讓 settle 只在連結曾經 `up` 時才等。不論哪個，§3 契約、§6 生命週期、§8 測試都要跟著改。

**M-5 成本估算只用了桌上 2 台的情境；現場（隊員手機周圍都是隊友的節點）每一次對別人位址的嘗試都 +1 s。**
- 情境：一人一台節點（§6）時，隊員手機看到的其他隊友節點全部是「解不開」。§4.3.7 的上限算法（`⌊87 / A1⌋`、T-L2(e) 12 個別人位址每個 5 s、T-L21 12 台）每次嘗試都變成 A1 + 1 s；R-7 的 loginFor 每試一個別人的位址 +1 s；net run / 多台加入 / 8.4 換鑰匙送多台：每台 +1 s（handoff close）＋ 每個失敗 +1 s。設計 §4 只寫「一輪 2 台最多多 2 s」「R-7 多 ≤ 2 s」。
- 修：§4 依 §4.3.7 的最壞情境（12 個別人位址、12 台自己的）重算：一輪長度、每台最長讀取間隔（T-L21(b) 的 ≤ 300 s 會不會破）、R-3、R-7；T-L2(e)/T-L21 的假時鐘測試把 settle 放進去重跑並列在 §8。若採 M-4(a)，大部分代價會消失（只有換台時才等），要重算的是換台次數 × settle。

## MINOR

**m-1 8 s 等待 vs 5 s 堆疊逾時：每次 133 白等 3 s，比 settle 的代價還大。** `node_link.dart:555-559` `link.state.firstWhere((s) => s, orElse: () => false)` 只等 `true`；plugin 的失敗更新是 `DISCONNECTED` + failure（`ProtobufMessageConverter.kt:64-72`），`ReactiveBackend.connect` 映成 `false`，firstWhere 跳過它，嘗試一直等到 `due`（8 s）。證據：所有失敗都是 133 @ 5.0 s、attempt 結束 @ 8.00 s。建議（另一個獨立小改）：連上之前收到 `false` 就結束這次嘗試（noResponse），每次失敗省 3 s；冷啟動那類（settle 管不到）也受益。若要做「133 後同一嘗試內重試一次」，剩 3 s 不夠（connected 量到 0.4–4.9 s），不建議。

**m-2 狀態碼 log 的資料流沒有定義。** `BleBackend.connect` 回 `Stream<bool>`（`ble_gate.dart:15`），`ReactiveBackend`（`ble_backend.dart:24-29`）沒有 log 出口，failure 在 `.map` 被丟掉。要寫明：介面改成帶 failure 的型別（或 `connect` 多一個 `onFailure` 回呼），由 NodeLink 的 `trace` + `mask` 寫 `BMAPP nl …`（擁有者是 NodeLink，不是 backend）；只在 `connect()` 那條串流記，不在 `linkStates`（`connectedDeviceStream` 也會收到別頁、舊頁的失敗，會重複 / 混入）。

**m-3 錯誤訊息內容：** RxAndroidBle 的 `BleDisconnectedException` 訊息含 `MAC='…'`（遮不遮取決於 RxBleLog 的設定），設計只擷取數字是對的；另兩種訊息要列出期望：plugin 的 Rx `timeout`（`DeviceConnector.kt` `connectDevice`）→ `TimeoutException` 無訊息 → `"Unknown error"` → `status=?`；`"Device is not in queue"` → `status=?`。單元測試把這三種都餵一次，並斷言輸出不含 `:` 分隔的 6 組十六進位。

**m-4 plugin 的 `ConnectionQueue` 在「連線中被取消」時不會移除該 id（⚠️ 讀原始碼，未上機）。** `DeviceConnector.kt` `establishConnection` 只在 `doOnNext/doOnError` 呼叫 `removeFromQueue`；`disposeSubscriptions()` 直接 dispose，沒有 `doOnDispose`。之後對**別台**的 connect 卡在 `waitUntilFirstOfQueue`（`queue.first() != deviceId`），plugin 自己的 timeout 在那之後才套用 → 每次 8 s noResponse，直到 app 重啟。可觸發路徑：`_abort`（輪被 core 切、`acquire→_dropAll`）、`_lfAttempt` 60 s 預算切、以及 app 8 s `due` 比 plugin 8 s timeout 先到（plugin 的計時晚啟動）而堆疊又沒在 5 s 回 133 的手機。f22 資料裡每次失敗都有 5 s 的 133，所以沒碰到；這不是本設計的原因，但「換台失敗」的歸因要排除它：建議在真機上做一次「連線中取消 → 立刻連別台」探查，有重現就寫進 #329 殘項（不在本 PR 修）。

**m-5 `_dropAll` 上限 5 s = `closeMax`。** 加 settle 後最壞 6 s（M-4）。若保留 settle 在 close()，把 `_dropAll` 上限改成 `closeMax + settle` 並加一個假時鐘測試；若採 M-4(a)，此項消失。

**m-6 §6 生命週期缺項：**「app 進背景 / NodeLink.dispose」寫 n/a，但 `dispose → _dropAll` 會等 settle（+1 s）；「同一台位址立刻重連」（loginFor 對同一位址重試、net_run 同一台重連）沒有證據也沒有列；「藍牙關閉時 close」：合成 DISCONNECTED 仍會到（M-3），等 1 s 無害，寫明；iOS 標「沒有」即可。

**m-7 R-3 門檻 160 → 165 的計算**只把 L 加 2 s；§4.3.5 的「+15 s（BleGate 延後掃描、等斷線完成）」那一項本身也含 close，若 settle 留在 close() 應一起檢查。採 M-4(a) 時重算。

**m-8 安全（對抗角色）：** 會廣播服務 UUID 的 BLE 攻擊者能讓手機對它的（輪替）位址連線，每次現在多付 1 s（設計 §4.3.7 的位址上限仍是界線），等於把既有的拖慢攻擊放大約 20–30%；log 只多一個整數，不受遠端控制（狀態碼來自本機堆疊）。本機其他 app / 被攻陷的節點：無新輸入。§7 補一句攻擊者情境與上限即可。M-4(a) 也降低這個放大（失敗的連線不等）。

## 需要的負向對照（逐項）

1. settle 本身：同場次交錯 A/B（M-2），指標「連著的連結 cancel 後立刻換台 → 133 率」，A 組必須重現 > 0 次，否則對照無效。
2. 單元：假時鐘，settle = 0 → 「換台間隔 ≥ 1 s」斷言 FAIL（設計已有）；若採 M-4(a)：「讀到後 `core.result` 不晚於 attempt 結束」與「失敗連線後下一個 connect 不延後」各一條，把 settle 放回 close() → FAIL。
3. m-1（若做）：假 backend 在 5 s 回 `false` → 嘗試在 5 s 結束；拿掉改動 → 8 s → FAIL。
4. log：failure `status 133` → `status=133`；三種無碼訊息 → `status=?`；log 不含完整 MAC；把擷取改成記全文 → FAIL。

## Verdict

**REJECT（v1）**。改動小、方向（換台前留間隔）可能是對的，但：數字重算不出來且漏掉 3/5 的失敗（M-1）、前後場次混淆 + 統計不足（M-2）、「等堆疊斷線」的前提在 plugin 原始碼上不成立（M-3）、放在 close() 讓結果 / lease / dispose 全部延後（M-4，翻轉資料本身就看得到 1 s 延後）、現場代價低估（M-5）。建議 v2：settle 移到 gate 的 connect 端且只在前一條曾經連上時等；交錯 A/B 重測；順手評估 m-1（失敗不白等 3 s）。
