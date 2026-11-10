# #254 app S6 — 離開網路（設計 v1，待審）

範圍：app 的「離開網路」一個動作，節點零改動（節點已實作：Batman-p3 e5c89a1）。恢復出廠不在本單（#255）。
規格：219-field-provisioning.md §2.2「離開網路：選機台 → 離開網路 → 確認」（:129）、§7 表「離開網路：清除網路部分、保留擁有者與出廠身分」（:486-490）。

## 1. 事實（Batman-p3 e5c89a1；app 6fd233f）
| # | 事實 | 證據 |
|---|---|---|
| L1 | `network/leave` 是 owner-op：body = op-only-req `{31: owner-op}`；只有擁有者角色可用 | cddl:88、:453；provd/session.go:79 |
| L2 | 節點不是成員 → helper E_FORBIDDEN（線上 3）。是成員 → 寫 .txn → commit（Claimed、Left、清 Net / Members / Admins）→ ForgetMesh → 刪 mesh markers → SaveTxn → 回 `{}` | node.go:1197-1240 |
| L3 | commit 前任何失敗與 commit 後 ForgetMesh 失敗都是 helper E_APPLY；provd 把 E_APPLY（無 reason）一律對應成 **E_REJECTED 11、沒有 detail** → app **分不出「沒離開」與「已離開但無線電沒清」** | node.go:1210-1229；session.go:574-575 |
| L4 | E_FORBIDDEN 3 也是 owner-op 的 nonce / 簽章錯誤（同 join2 §5.4）→ 3 本身也分不出原因 | flow.rs `network_join`；session.go:41 |
| L5 | info（owner session）：key 7 = node-state（1 已認領、2 成員）、key 10 = net_id（成員才有）、key 11 = unfinished = `.txn` 還在 | cddl:161-175；readonly.go:131-141 |
| L6 | 留下的 `.txn`（leave 已 commit）會在**開機**（BootFinish）或下一個會改狀態的動作之前被 Finish 完成，Finish 對 leave = forget | wtxn.go:173-174、:413-427；node.go:250-255 |
| L7 | ForgetMesh = `halow-setkey --forget-mesh`：只動 mesh（placeholder + keyguard 擋 morse radio），**不碰手機 AP**（radio0）。§7 表寫「清除…隊伍 AP」與程式不符 → 以程式為準，⚠️ 04 上確認 | provhelper main.go:178-185；halow-setkey:6 |
| L8 | 再加入：network/join 會清 Left；管理者的 join2 以 DAC 找到舊項並換成 joining；隊員模式需要 mnet **key 7**（自己節點項） | node.go:1149；join2flow.rs:313-316；254-app-member-join.md:107 |
| L9 | 狀態頁對 k1 = 1 已有句子，並點名這支手機的加入按鈕 | statuspage.rs `JoinButton`（6fd233f） |

## 2. 畫面
- 誰能按：登入（owner session）該節點的手機——管理者手機與隊員手機都擁有自己的節點。按鈕「離開網路」放在「我的節點」最下面，紅字（219 :172），只在登入時出現。
- 確認對話框：標題「要讓這台節點離開隊伍網路嗎？」內文「離開後這台的 HaLow 無線電會關閉，直到再加入網路。隊伍裡其他節點不受影響。手機裡的網路紀錄不會改變，之後可以按「<這支手機的加入按鈕>」再加入。」按鈕「取消」/「離開網路」。取消 → 不送任何東西。
- 結果一行（log marker 照既有慣例）：見 §3 表。之後狀態頁自然顯示「這台還沒加入隊伍網路 — 請按「…」」（L9），不另做。

## 3. 流程（sans-IO，沿用 owner-op）
bridge `request_leave()` = `owner_op("network/leave", {})`（op/nonce → Sign → network/leave + key 31）。回覆：
- **0（`{}`）→ 已離開**，不再讀。
- **其他錯誤碼 → 讀 info（tag `info-leave`）→ 純函式 `flow::leave_outcome(info)`**；傳輸錯誤 / BLE 斷 / 逾時 → session 結束，結果不明（不讀、不猜）。

| info（讀到的） | 結果 | 顯示 |
|---|---|---|
| reply 0 | Left | [LEFT] 已離開隊伍網路；要再加入請按「<加入按鈕>」 |
| k7 = 1 且 k11 = false | AlreadyOut | [LEFT] 這台已經不在隊伍網路裡 |
| k7 = 1 且 k11 = true | LeftPending | [LEFT] 已離開隊伍網路，但節點的無線電還沒清完 — 請把節點重新開機一次（開機時會清掉） |
| k7 = 2 | NotLeft | [REQ_FAIL] 沒有離開網路（節點仍在隊伍網路裡，代碼 N）— 請再按一次；仍然如此請找維修人員 |
| info 錯誤 / 解不出 / k7 缺或其他值；傳輸錯誤 | Unknown | [REQ_FAIL] 結果不明 — 請重新連線後看狀態頁 |

- 「再按一次」在 LeftPending 不用：節點已是 Claimed，再送 leave 會回 3；重開機由 BootFinish 確定完成（L6）。
- 判定只看節點自己的狀態（k7 / k11），從不因為「送出了」就說已離開（fail-closed）。

## 4. 手機紀錄：不改
- 管理者 net/、隊員 mnet/、mpend/ **一律不寫**。理由：(1) leave 不改網路的已簽成員名單（移除成員是另一個動作，219 :135、:404 要換密碼），net/ 的「applied」對應的正是那份名單；(2) 再加入照現有流程就成立（L8：管理者 join2 換掉舊項；隊員模式需要 key 7，留著才能「加入隊伍網路」）；(3) 沒有寫入就沒有 CAS / 中途被殺的紀錄修補。
- 代價（誠實界線）：管理者手機的成員清單仍把這台列為「已加入」，直到它再加入或被移除；app 不另外標記。

## 5. 擁有權 / 契約 / 生命週期
- 擁有權：節點 p5 紀錄只由節點 helper 寫；本流程在手機上**不寫任何紀錄**。契約：network/leave（app 寫、provd 讀，owner-op 簽章）、回覆碼、info key 7 / 10 / 11（節點寫、app 只讀；缺或怪 → Unknown，fail-closed）。
- 生命週期：送出後 app 被殺 / BLE 斷 → 節點照做；下次登入看狀態頁即知（手機沒有要補的紀錄）。節點在 commit 前重開 → Finish 回到成員（狀態頁仍是成員）；commit 後重開 → BootFinish forget（L6）。leave 後再加入 → 照 L8。OTA 寫入中 → 節點回 7（EBusy）→ info k7 = 2 → NotLeft。app 升降版：無紀錄格式變更，不適用。
- 安全：只有擁有者能做（owner-op 簽章，L1）；文字與 log 不含任何秘密（只有代碼與狀態）；destructive 但可逆（再加入），所以要確認對話框。

## 6. 測試（每項附負對照）
- T1（Rust）`leave_outcome` 每列一臂，加：k7 = 1 + k11 缺 → AlreadyOut；k10 存在但 k7 = 1 → 照 k7。負對照 mutant：錯誤碼不讀 info 直接 Left、忽略 k11、info 缺當 Left、k7 = 2 當 Left。
- T2（bridge，FakeNode）verbs 順序：0 → [op/nonce, network/leave]，不讀 info；11 → [op/nonce, network/leave, info]；3 + k7 = 1 → AlreadyOut；全程**沒有任何 Persist 步驟**；文字無秘密、以 marker 開頭。負對照：拿掉 info 讀取 → 11 被說成已離開 → FAIL。
- T3（widget）確認對話框：取消不呼叫；確認呼叫一次；內文含「手機裡的網路紀錄不會改變」與這支手機的加入按鈕名。負對照：跳過對話框。
- T4（04 實機，授權後）：04 = N0 成員 → 狀態頁 🟢 → 離開網路 → 「已離開」→ 狀態頁「這台還沒加入隊伍網路 — 請按「加入網路／繼續加入」」、info k11 = false、`halow-setkey --status` 看 mesh 被擋、手機 AP 仍可連（L7）→ 再按一次離開 → 「已經不在」→ 管理者手機「加入網路／繼續加入」→ 🟢 → 結束狀態 = 開始狀態（N0 成員 A committed）。負對照：不按離開的同一時間點維持 🟢。
