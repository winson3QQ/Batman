# #254 app S6 — 離開網路（設計 v2，待審）

範圍：app 的「離開網路」一個動作，節點零改動（節點已實作：Batman-p3 e5c89a1）。恢復出廠不在本單（#255）。
規格：219-field-provisioning.md §2.2「離開網路：選機台 → 離開網路 → 確認」（:129）、§7 表「離開網路：清除網路部分、保留擁有者與出廠身分」（:486-490）。

## 1. 事實（Batman-p3 e5c89a1；app 6fd233f）
| # | 事實 | 證據 |
|---|---|---|
| L1 | `network/leave` 是 owner-op：body = op-only-req `{31: owner-op}`；只有擁有者角色可用 | cddl:88、:453；provd/session.go:79 |
| L2 | 節點不是成員 → helper E_FORBIDDEN。是成員 → 寫 .txn → commit（Claimed、Left、清 Net / Members / Admins）→ ForgetMesh → 刪 mesh markers → SaveTxn → 回 `{}` | node.go:1197-1240 |
| L3 | 線上錯誤碼（provd mapHelper）：helper E_APPLY / E_STATE（含 Finish 失敗、backoff 內重試）→ **E_REJECTED 11、無 detail**，分不出「沒離開」與「已 commit 但無線電沒清」；E_STORAGE → 10；E_BUSY 7 有兩種：節點在試用槽 / OTA 寫入中（什麼都沒做）與 provd 的逾時 / 斷線 `busyUnknown`（detail key 3 =「outcome unknown — re-read info」）；3 的來源：nonce / 簽章、不是擁有者、不是成員 | session.go:570-582、:585-587；node.go:239、:247-248、:252-255；wtxn.go:387-390 |
| L4 | info（owner session）：key 7 = node-state，來自 provd **每 4 s 的輪詢快取**；key 10 = net_id（成員才有）、key 11 = unfinished（`.txn` 還在）由 `info.net` **每次請求現讀** | server.go:20、:545-567；readonly.go:131-141 |
| L5 | 留下的 `.txn` 在開機（BootFinish）或**下一個會改狀態的動作之前**被 Finish 完成；對 leave 的 .txn，Finish = forget。所以再送一次 leave 會先 forget（失敗則在 backoff 內回 11），之後因已不是成員回 3 | wtxn.go:173-174、:387-390、:413-427；node.go:250-255 |
| L6 | ForgetMesh 只動 mesh（placeholder + keyguard 擋 morse radio），不碰手機 AP（radio0）；§7 表「清除隊伍 AP」與程式不符（協調者記 #254），⚠️ 04 上確認 | provhelper main.go:178-185 |
| L7 | 再加入：network/join 清 Left；管理者 join2 以 DAC 換掉舊項（net/ 需 APPLIED）；隊員模式需要 mnet key 7，送的是**同意時的 secrets** | node.go:1149；join2flow.rs:303-316；254-app-member-join.md:107 |
| L8 | provd 一次 ops 請求最多等 330 s；ForgetMesh 自己最多 30 s 再加升級步驟 | server.go:22；halow-setkey:39 |

## 2. 畫面
- 「離開網路」按鈕在狀態頁最下面、紅字（219 :172），**只在最後一次讀到是成員時出現**（info k10 存在或 status k1 = 2）。
- 確認對話框，標題「要讓節點 …<last4> 離開隊伍網路嗎？」，內文：
  「離開後這台的 HaLow 無線電會關閉，直到再加入網路。其他節點仍留在網路裡；如果有節點靠這台轉送，它們可能會斷線。離開不會把這台從管理者的成員名單移除，也不會撤銷任何東西；要把節點交給別人是轉賣（另案 #255）。手機裡的網路紀錄不會改變。」再接一句（以狀態頁最後一次 info 的 k10 對這支手機的紀錄）：
  - 有 net/<k10> 且 APPLIED（管理者）→「之後可以按「加入網路／繼續加入」再加入。」
  - 有 mnet/<k10> 且有 key 7（隊員）→「之後可以按「加入隊伍網路」再加入。」
  - 其他 →「這支手機沒有這個隊伍網路可用的紀錄：離開後要再加入，需要向管理者要新的邀請。」
  按鈕「取消」/「離開網路」；取消不送任何東西。
- 回 0 之後狀態頁標成過期並自動重讀一次（顯示「已認領，還沒加入網路」的判定，status page §3 k1 = 1）。

## 3. 流程（sans-IO，沿用 owner-op）
bridge `request_leave()` = `owner_op("network/leave", {})`；Dart 以 `_ask(wait: _joinWait（360 s，> 330 s），retry: false，unclear: 「結果不明 — 請重新連線後看狀態頁」)` 送出。回覆：
- **0 → 已離開**（不再讀 info）。
- **7 且沒有「outcome unknown」detail → 節點正在更新**（什麼都沒做，不讀）。
- **其他錯誤碼（含 7 outcome unknown、3、10、11）→ 讀 info → 純函式 `flow::leave_outcome(info)`**，只用現讀的 k10 / k11 判定，k7（快取）只做交叉檢查：

| info | 結果 | 顯示 |
|---|---|---|
| （回 0） | Left | [LEFT] 已離開隊伍網路 |
| （回 7，無 outcome unknown） | Busy | [REQ_FAIL] 節點正在更新軟體，更新完成後再按「離開網路」 |
| k11 = true（不論 k10） | Unfinished | [REQ_FAIL] 節點上還有沒完成的網路變更 — 等一下再按一次「離開網路」，或重新開機一次；仍然如此請找維修人員。完成之前這台可能還在隊伍網路上 |
| k11 = false、k10 缺 | AlreadyOut | [LEFT] 這台已經不在隊伍網路裡 |
| k11 = false、k10 存在 | NotLeft | [REQ_FAIL] 沒有離開網路（節點仍在隊伍網路裡，代碼 N）— 請再按一次；仍然如此請找維修人員 |
| k11 缺；k7 與 k10 矛盾（k7 = 1 且 k10 存在，或 k7 = 2 且 k10 缺）；info 錯誤 / 解不出；傳輸錯誤 | Unknown | [REQ_FAIL] 結果不明 — 請重新連線後看狀態頁 |

- 「已離開」只在回 0 或 k10 缺 ∧ k11 = false 時說；k7 快取可能落後 4 s，剛離開就讀到 k7 = 2 ∧ k10 缺會落到 Unknown（fail-closed，狀態頁之後會對）。
- Unfinished 時再按一次會先跑 Finish（= forget，L5）；重開機由 BootFinish 完成。

## 4. 手機紀錄：不改
- 管理者 net/、隊員 mnet/、mpend/ **一律不寫**。理由：(1) leave 不改網路的已簽成員名單（移除成員是另一個動作，219 :135、:404 要換密碼）；(2) 再加入照現有流程（L7）；(3) 沒有寫入就沒有 CAS / 中途被殺的紀錄修補。
- 誠實界線：管理者手機的成員清單仍把這台列為「已加入」，直到它再加入或被移除；隊員模式再加入送的是同意時的 secrets，若網路之後升到 v > 1，會加回舊版本（app 還沒有 network/update 流程）。

## 5. 擁有權 / 契約 / 生命週期 / 安全
- 擁有權：節點 p5 紀錄只由節點 helper 寫；本流程在手機上不寫任何紀錄。契約：network/leave（app 寫、provd 讀，owner-op 簽章）、回覆碼與 7 的 detail、info key 10 / 11（現讀）與 key 7（快取，只交叉檢查）；缺或矛盾 → Unknown。
- 生命週期：送出後 app 被殺 / BLE 斷 → 節點照做，app 顯示結果不明；下次登入看狀態頁即知（手機沒有要補的紀錄）。commit 前重開 → Finish 回到成員；commit 後重開 → BootFinish forget（L5）。試用槽 / OTA 中 → Busy。leave 後再加入 → L7。app 升降版：無紀錄格式變更，不適用。
- 安全：只有擁有者能做（owner-op 簽章）；文字與 log 只有代碼與狀態，不含秘密；可逆（再加入）所以要確認對話框。

## 6. 測試（每項附負對照）與回歸
- T1（Rust）`leave_outcome` 每列一臂，含 **回 11 + k7 = 2 + k10 缺 + k11 = true → Unfinished（不得是 NotLeft）**、k7 = 2 + k10 缺 + k11 = false → Unknown、k11 缺 → Unknown。負對照 mutant：v1 的 k7 優先表、錯誤碼不讀 info 直接 Left、忽略 k11、k11 缺當 false。
- T2（bridge，FakeNode）verbs：0 → [op/nonce, network/leave]；7（無 detail）→ 同上、Busy；7 outcome unknown / 11 / 3 → […, info]；全程沒有 Persist 步驟；文字無秘密、以 marker 開頭。負對照：拿掉 info 讀取、7 一律當 Busy。
- T3（widget）按鈕只在成員時出現（k10 缺且 k1 = 1 → 不出現）；對話框三種再加入句各一列；取消不呼叫、確認呼叫一次；送出用 wait 360 s、retry false、unclear 句（以可注入的 ask 參數驗）。負對照：跳過對話框、一律說可再加入。
- 回歸：app 端 T1–T3 在 test-all.sh；節點端 leave 已有 Go 單元測試（node_test.go、wtxn_*_test.go）與 harness `scripts/dv/prov-leave-ota-254.sh`（wbox `helper-noleave` 負對照）。
- T4（04 實機，授權後）：04 = N0 成員 → 狀態頁 🟢 → 離開網路 → 「已離開」→ 0 / 30 / 60 s 讀狀態頁：「這台還沒加入隊伍網路 — 請按「加入網路／繼續加入」」、info k11 = false、`halow-setkey --status` 看 mesh 被擋、手機 AP 仍可連（L6）→ 按鈕消失 → 管理者手機「加入網路／繼續加入」→ 🟢 → 結束狀態 = 開始狀態（N0 成員 A committed）。負對照：不按離開的同一時間點維持 🟢。

## 附錄 A. 審查處理
| 輪 / 項目 | 處理 |
|---|---|
| v1 A-M1 k7 是 4 s 快取 | L4 改正；判定改用現讀的 k10 / k11，k7 只交叉檢查；T1 臂「11 + k7 = 2 + k10 缺 + k11 = true ≠ NotLeft」，負對照 = v1 表 |
| v1 A-M2 LeftPending 的前提錯 | 改為中性的 Unfinished 句（再按一次會先 Finish，或重開機）；L5 改正；只有回 0 或 k10 缺 ∧ k11 = false 才說已離開；加「完成之前可能還在隊伍網路上」（B-m3） |
| v1 B-M1 呼叫策略 | `_ask` wait 360 s、retry false、unclear 句（L8）；T3 |
| v1 B-M2 一律說可再加入 | 對話框依 k10 對手機紀錄分三句；T3 三列 |
| v1 minors | 按鈕只在成員時出現；對話框點名節點、說不移除名單 / 不撤銷 / 轉賣是 #255、「可能會斷線」取代「不受影響」；回 0 後重讀狀態、T4 0 / 30 / 60 s；L3 列全錯誤碼（10、7 兩種、11、3 的來源）；隊員模式加回舊版本的界線；回歸位置 |
