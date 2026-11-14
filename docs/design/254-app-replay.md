# 254-app-replay — 把 claim REPLAY 接進 app(v2,待審)

對應:#254;凍結設計 `254-app-s1.md` §5.1 / §5.2 / §5.3、`254-app-claim-noover.md` v2.1(R1 / R2 / R4)。
v1(口頭計畫)被兩位審查者 REJECT;本版照兩份意見整份重寫。行號 = `feat/254-app-replay` @ f0138bd。
標記:✅ = 讀過原始碼行號;⚠️ = 推論或模擬;❌ = 沒做。

## 0. 現況(✅ 讀碼)

- 協定層 `batman-proto/src/replayflow.rs` 已能跑**一次** replay(Ecdh → NXpsk0 → claim/begin → op/nonce → Sign → claim/replay),結局
  `Replayed(Recovered|…)/Msg2Undecryptable/CertRejected/Refused/Broken`。bridge、Dart、畫面都沒接。
- 節點:每次 replay 成功都換 root 密碼(node.go:661-665);成功或 13 讓該 session 成 owner 並砍掉其他 session(session.go:696-702、
  server.go:847-860);replay 失敗 10 次/小時 → 12(node.go:617-627,只在記憶體);握手上限 10 s、nonce 55 s(server.go:28-29);
  已認領的 STATUS 不帶末四碼(server.go:599-613);不是對象的節點回等長假 msg2(noise.go:109-111,長度 = 32 + 48 + cert + 16)。
- app:`claim.dart` 的 `_find`(l.116-164)逐台連線讀 STATUS,只收「未認領且末四碼相符」;已認領的只計數(`_claimedNear`)。所以
  **節點已提交認領之後,使用者重掃 QR 的實際結果是 60 秒後 NOT_FOUND**,不是 9。`claim_finish`(flow.rs:54-69)的 13 / OK 無憑證
  = Committed、9 = TryReplay、其他 = Unknown,目前三者都只顯示文字。
- **app 裡沒有任何握手預算**(grep 只中 loginflow.rs:7 的註解);`nodes.dart` `_login`(l.341-390)對每個廣播者都握手。v1 寫「共用
  既有預算」是錯的。
- `keyLevels` 的 `recover` 能力 Kotlin 有算(KeyPolicy.kt:44,58),Dart 沒讀。field 版 `ecdh` 回 "dev builds only"(MainActivity.kt:121-127)。

## 1. 範圍

做:使用者按「認領」之後,在**同一次動作內**接上 replay。不做(寫回 #254 checklist,不開新單):
- 沒有 QR 的「需恢復」入口與 `list_pending()`(v1 加了函式卻沒有畫面用它 → 刪掉);
- `forgotten-pending/` 當候選(noover §9);
- 把 `nodes.dart` `_login` 改接握手閘(它現在不符 §5.3;本 PR 不宣稱共用);
- 真機 P7(2)/(3)(要重燒 / 改節點狀態,需使用者授權)。

## 2. 觸發(只有使用者按了「認領」之後;開頁不做任何事)

| # | 條件 | 動作 |
|---|---|---|
| T1 | 本次 claim/finish 的結局 = TryReplay(9)/ Committed(13、OK 無憑證)/ Unknown | 斷線 → 等 15 s(§5.1:PollEvery 4 s + CtlWait 10 s)→ replay |
| T2 | 手機有**同一 K** 的 pending,且 `_find` 沒找到未認領的對象 | 直接 replay(不等);此時 `_find` 只找 20 s(不是 60 s),畫面顯示「沒找到未認領的這台,改試恢復先前的認領」 |
| T3 | T1 或 T2 成立,**而且手機已有這台的 node 紀錄** | 先問一次:「恢復會更換這台節點的 root 密碼,並中斷它目前的其他連線。如果它在『我的節點』還能用,不需要恢復。」確認才做 |

- 沒有 node 紀錄時不另外問:手機沒有密碼可失效,而節點只有一位擁有者(replay 的前提,node.go:628),被砍的 session 只可能是這支手機自己的。
- 不依 key 9 做任何決定(noover R2 不動);有 node 紀錄 + pending 的情況由 T3 的確認處理。
- 結局用結構化欄位傳給 Dart:`ClaimStep` 加 `finish: Option<FinishKind>`(列舉),Dart 不比對文字。

## 3. 一輪、限制、停止規則

候選 = `_find` 這次看到的 STATUS ∈ {claimed, member, 讀不到} 的裝置(未認領的不試:它是 NX 模式,必回假 msg2),RSSI 強的先試,
**每輪最多 6 台**(超過 → 提示把手機貼近節點)。握手 ≥ 10 s 一次(= §5.3 的 6 次/分)、同時 1 條。
**1 次嘗試 = 掃完一輪候選**;最多 3 輪,輪與輪間隔 ≥ 15 s。ECDH 在連線之前做完(握手上限 10 s)。

| 一台候選的結果 | 動作 | 算不算被拒 |
|---|---|---|
| 連不上 / 沒收到 msg2 / 逾時(連線 15 s、msg2 10 s、整次 55 s) | 換下一台 | 否 |
| msg2 解不開 | **立即斷線**,換下一台 | 否 |
| CertRejected(解得開但 DAC ≠ pending 的) | 斷線、全部停止,警示「節點身分與認領紀錄不符」 | — |
| claim/begin 回 7、op/nonce 回 3、Broken、claim/replay **送出前**斷線 | 這輪結束,下一輪再試這台 | 否 |
| claim/replay 已送出、沒收到回覆 | 同上(節點可能已換密碼;下一輪成功時拿到的是最新的) | 否 |
| Recovered | §4 寫紀錄 → 結束 | — |
| 13 | 斷線 → 等 15 s → 新連線再 replay;連續 ≤ 5 次,之後停:「節點上鎖尚未完成,請稍後再試」 | 否(node.go 不計) |
| 12 | 全部停止:「嘗試太多次,請一小時後再試」 | — |
| 其他拒絕(9 / 3 / 4 …,握手解得開、replay 被拒) | **全部停止,不重試**:§5.2 的中性文字 | 是 |

- 「第一次被拒就停」取代 v1 的「每小時 3 次」計數:app 不必存計數,重開 app 也不會把節點推到 10 次/小時(每按一次「認領」最多 1 次被拒)。
- 3 輪都沒有結果 → 「找不到這台或還無法恢復:請把手機貼近節點、確認節點開機後再試(節點也可能已重燒或被他人認領)」。pending 一律保留。
- 文字修正:claim.rs:271 的「節點已被別人認領」違反 §5.2,改成 §5.1 的中性句;claim.rs:371 的斷言一起改。Recovered 顯示「已恢復;
  root 密碼已更換,先前抄下的密碼失效」。

## 4. 紀錄

- pending 解碼(bridge):輸入是開封後的明文;只收 key 1–7、長度固定、**device_id 必須等於路徑上的 id**,不合 → 錯誤、不 replay、
  pending 不動。round-trip 測項用 `pending_record()`(claim.rs:146-156)的產物。
- Recovered → 用現有的 `ClaimRecords.claimed()`(claim_records.dart:77):舊 node 紀錄複製到一旁、寫新紀錄(key 與認領路徑相同)、
  再刪 pending。複製失敗仍寫:新密碼是節點上唯一有效的,不寫才是損失(記 log)。
- 中途被殺:pending 還在 → 下次按「認領」從 T2 再來;節點若已換密碼,下一次 Recovered 拿到新的。

## 5. 擁有權

| 資源 | 唯一寫入者 | 其他 |
|---|---|---|
| `claim-pending/<id>`、`node/<id>` | `ClaimRecords`(認領與恢復同一個) | nodes 頁唯讀 |
| 認領頁的 BLE 連線 | `_ClaimPageState`(`_busy` 期間 1 條;`ClaimRecovery` 由它建立、用它的連線函式) | nodes 頁是另一個 route;⚠️ 推論:從首頁只能二選一進入,兩頁不同時握手 |
| 握手節拍(10 s 一次、每輪 6 台、3 輪) | `ClaimRecovery` 實例(記憶體;一次「認領」一個) | 無讀者 |
| 節點的 root 密碼、失敗計數、session | 節點(helper / provd) | app 只靠回應碼得知 |

## 6. 契約

| 介面 | 寫 / 讀 | 壞掉時 |
|---|---|---|
| `ClaimStep.finish`(列舉) | bridge 寫、claim.dart 讀 | None = 不觸發 replay(fail-closed) |
| `ReplaySession`(bridge):`start(pending 明文, frame_limit)` → Ecdh / Write / Sign / Ended(kind, detail) / Recovered(node 紀錄) | bridge 寫、`ClaimRecovery` 讀 | detail 與 Broken 文字**不含** z / K / psk / 密碼(測項:掃字串) |
| `ecdh`(Kotlin,owner_enc × pending.ecdh_pub) | Kotlin 寫 z、Dart 轉交 Rust 後 `fillRange(0)` | 金鑰不在 / field 版 → 「這支手機(這個版本)無法恢復」,不連線;S1 現場版不能 replay 是已知限制,PR 寫明 |
| `keyLevels.recover` | Kotlin 寫、恢復前即時讀 | false → 同上 |

## 7. 生命週期

| 路徑 | 之後的行為 | 測 |
|---|---|---|
| 第一次認領、節點未認領 | 不變(不進 replay) | 現有測項 |
| finish 得 13 / 9 / 無回覆 | T1 | Rust + Dart 假 BLE |
| app 在 finish 等回覆時被殺、節點已提交 | 重掃 QR → T2 | Dart 假 BLE;真機 ❌ |
| 快取過期視窗(節點已提交、STATUS 仍是未認領) | `_find` 找到 → NX → 9 → T1(等 15 s) | 假節點狀態機(§8) |
| 有 node 紀錄 + pending | T3 先問 | Dart |
| 節點重燒 / 被別人認領 / 另一支手機同 QR | 握手解不開 → 3 輪後中性文字;pending 保留 | Dart |
| 藍牙關 / 沒權限 | 現有檢查(claim.dart:228)在 replay 前就擋 | 現有 |
| 恢復中斷電 / 斷線 | §3 表;pending 保留 | Rust |
| app 升版 / 降版 | node 紀錄格式不變(key 與認領相同);pending 格式不變 | round-trip 測項 |
| field 版 | 「無法恢復」 | Dart |
| iOS | 不在範圍 | — |

## 8. 測試

- 假節點(tests/replayflow.rs)改成對照真節點:假 msg2 長度 = 32 + 48 + cert + 16 並加斷言(現在多 16 B);狀態 未認領(NX)/ 已認領 /
  上鎖未完成;每次成功回**不同**密碼;成功後同 session 再 replay 得 13;失敗計數到 10 回 12。每條附 node.go / session.go 行號。
- §3 表每列一個 Rust 測項(純函式 `replay_next(結果) → 動作`,沒有計數器參數)。
- Dart(`ClaimRecovery` + 假 BLE):T1 / T2 / T3、候選排序與每輪 6 台、解不開立即斷線、第一次被拒就停、13 的 15 s 等待(假時鐘)。
- **負向對照(症狀層)**:節點已認領、手機只有 pending → 拿掉 replay:手機沒有 node 紀錄、之後登不進假節點(FAIL);有 replay:node 紀錄
  存在,且用它存的 tag key 能登入假節點、存的是最後一次的密碼。
- 攻擊對照:附近 10 台假「已認領」裝置 → 每輪只握手 6 次、不洩漏任何東西(msg1 只有臨時金鑰 ⚠️ 依 Noise 規格)、畫面提示靠近節點。
- 真機:❌ 未做。PR 內所有「節點會怎樣」標 ⚠️ 模擬,P7(2)/(3) 留在 #254 checklist。

## 9. 安全

- 資產:節點控制權(root 密碼、owner session)、K、z、psk_replay。
- 遠端 / 附近攻擊者:沒有 owner_enc 私鑰算不出 psk_replay → 只能拖延(假裝置佔候選名額;以 RSSI 排序 + 每輪上限限制)。假裝置回可解的
  msg2 需要 psk → 做不到;DAC 不符另有 CertRejected。
- 我們自己的錯:無聲換密碼 / 砍連線 → T3 的確認;自己把節點鎖一小時 → 第一次被拒就停。
- 本機其他 app:pending / node 紀錄是 Keystore 封存、路徑在 app 私有目錄(不變)。
- 祕密不進 log / 例外字串 / 畫面;新密碼只寫進封存的 node 紀錄(本版沒有顯示密碼的畫面)。
- 失敗一律 fail-secure:任何不明結果都保留 pending、不寫 node 紀錄。

## 10. v1 → v2 刪掉的機制

`list_pending()`、每小時計數器、依 key 9 分支、「共用預算」、開頁自動 replay。
