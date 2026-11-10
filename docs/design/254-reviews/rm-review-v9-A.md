# 254-app-remove-member.md v6.3 — 第 9 輪審查 A(正確性 / 介面 / 生命週期 / 現場;審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v6.3(496 行;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 @ fbc01ae(NU v4.1、219-protocol.cddl)。全程唯讀,沒有碰裝置。先自己審完整份,最後才讀第 1–8 輪的報告(§4)。

**判定:APPROVE-WITH-CHANGES**,0 BLOCKER / 0 MAJOR / 6 MINOR。第 8 輪兩位共同的 MAJOR(applied 紀錄上的 creator())已關閉:我逐一查過 app 裡 creator() 與 confirm() 的每一個呼叫點(§0),也查過其他程式路徑是否假設 k8 非空,沒有找到漏網的。MINOR 都是一句話或一個測試臂,不需要再整份重審(由作者自行決定)。

## 0. 自己核的事實:creator() / confirm() / k8 非空

`grep creator|confirm|first()|[0]`,範圍是 batman-proto/src、bridge/src/api、lib:

| 呼叫點 | 今天的行為 | v6.3 的規則 | 結果 |
|---|---|---|---|
| netrec.rs:281-283 `creator()` | 讀 k8 key 4 的第一筆;key 4 空 → `Err("members v1 empty")` | 定義不變 | ✅ 全 app 只有這一處 `.first()`,其餘 `[0]` 都在 cbor / frame / nodecert 解析 |
| netrec.rs:307-329 `confirm()` | 先檢查 join_state,再檢查 k9 == 版本,然後 `rec.creator()?`,不看 state 就升級 | applied → Already,不碰 k11 | ✅ 關掉了 MAJOR;**檢查順序沒寫 → MINOR-1** |
| netrec.rs:335-337 `forget_joining` | 第一行 `rec.creator()?` | 只在 pending 時呼叫 | ✅ |
| bridge owner.rs:98 `net_summary` | `creator().ok()`,本來就容錯 | 只在 pending 時標示 | ✅ 不會失敗;旗標影響 Dart `forgettable`(member_ui.dart:153)→ **沒有測試臂 → MINOR-2** |
| bridge owner.rs:127 `net_forget_joining` | `creator().ok() == Some(h)` | 只在 pending 時檢查 | ✅ |
| bridge owner.rs:777 `netrec::confirm` | 唯一呼叫者;Upgraded → persist,其他 → 文字 | — | ✅ owner.rs:959-964 走的是 make-network 剛做好的 pending 紀錄,不受影響 |
| Dart `_confirmNetwork` / `_forgetJoiningBody` | nodes.dart:997-1027;按鈕永遠存在(:1132) | — | ✅ |

另外檢查了「k8 是空的」(排除最後一台、沒有其他成員)時其他會讀 members 的路徑:

| 路徑 | 結果 |
|---|---|
| `members()`(netrec.rs:273-278) | applied 紀錄有 k11 → 回 k11;k11 = [] → `Ok([])` |
| `admin_preconditions`(invite.rs:181-194)、`check_joinreq`(approve.rs:69-86)、join2 `begin`(join2flow.rs:298-322) | 只做計數或查找,空清單沒問題 |
| 同意包帶 k8 原樣(approve.rs:156);成員端 `same_net` 只逐項檢查 key 4 | 空陣列可以過 |
| join2 送 `network/join` 時 members 是空的 | 節點 `netJoin` 不讀 body key 2(node.go:1035-1052);CDDL `4 => [* member]`(219-protocol.cddl:362)|
| 節點 `netUpdate` 驗 members 的方式 | 用前一版 admins 驗 Sign1,再核 net_id / version,不讀內容(node.go:1143-1153)|

結論:除了設計已經點名的 confirm / forget / net_summary / 排序之外,沒有其他程式路徑會因為 k8 空或 creator() 換人而出錯。

其他抽查過的事實:
- R3、R7、R10、R11、R12、R22、R31 的行號:invite.rs:143-153、netrec.rs:20、flow.rs:118-150、approve.rs:300-324 / :343-351。
- provd 角色表:owner 與 member 兩種角色都能送 `network/update`(session.go:79-82)。
- 節點的鏈規則:第一步 = 節點版本 + 1;secrets 只在最後一步;members 用前一版 admins 驗(node.go:1094-1160)。
- 剪貼簿在**貼上當下**就被清空(nodes.dart:603-607)→ MINOR-4。

## 1. 流程逐條走(對 v6.3 的文字)

| 流程 | 依據 | 結果 |
|---|---|---|
| 第一次移除(舊紀錄沒有 k13 / k10):commit → 產包 start = 1 → 成員比對 k3 / k4 → +1 → 匯入 → 等 → 送 | §2.1、§2.3、§3.1、§3.3、§3.4、§3.2;node.go 鏈規則 | ✅ |
| 網主送給自己的節點:鏈 (節點版本, 目前] + 現簽的 net_secrets;節點用儲存的 admins 驗 | §3.2-3;node.go:1094-1160 | ✅ |
| 成員以擁有者連線送給自己的節點(用 mnet k10 / k5 的 secrets) | §3.2;session.go:79 | ✅ |
| 一人多台:同意包先貼 / 後貼、換密碼前 / 後才同意 | §2.2、§3.4-4、§3.4 提示;approve.rs `existing()` 會把 k7 換成新的那台(另一台的 secrets 只剩 k10)| ✅ 三種順序都代入走過 |
| 同一版內重新邀請被移除的人(他的節點沒重設):確認框 → +1 路 → 2b → 隊員模式加入回 5 → 歷代接得上 → 直接送 | §3.6、§3.5、§2.0 入口 3 | ✅ |
| 被移除的人換一台新節點申請 | §3.6:比對 owner_pub | ✅ |
| 排除建立者那台 → 在另一台按「確認網路」 | §2.1 confirm | ✅ k11 不變;**節點版本不同時會顯示的句子 → MINOR-1** |
| 排除最後一台 → join2 新節點(members 是空的)→ 確認 / 忘記 / 下一次換密碼 | §2.1、§3.1、T26 | ✅ |
| 建立者那台在 applied 紀錄裡被 join2 中斷、留在 joining → 忘記 → 再加回 | §3.6、R31 | ✅ 忘記後它不在 k11,下一次換密碼就會把它切掉,出路是 join2 回 5 → applied → 送;與「只忘記不會撤銷」那句一致 |
| 加回找回來的自己節點(沒重設) | 入口 2(SignAdmin 之前確認)→ join2 → 5 → applied → §3.2 | ✅ |
| 第二次移除 / 第 17 次以上換版 / 降級再升級 | §2.4、§2.3 start 公式、§3.3 標示 | ✅ |
| commit 前被殺 | 簽過的 v+1 只在記憶體,從沒離開手機 → 重來會重簽,但不會分叉 | ✅(「同版只簽一次」實際上是「同版只**發出**一次」;沒有害處,不列項)|
| 兩段 CAS 衝突 → 「請再貼一次」 | §3.4 | ⚠️ 剪貼簿已經被清空 → MINOR-4 |

NU §3「app 移除成員設計必須處理的事」逐項對過,與第 8 輪相同,都有落點:
- 只用擁有者連線,pin DAC / 2 個槽位 / psk-rotated 不適用;
- 同版只簽一次;k9 > v 不開始;
- > 8 塊不送;不帶 key 7;換 SAE + net_root;
- wsl.24:前置 5 + 每次送之前查 k4;
- AP 密碼提示;審核時擋 removed(確認框);
- 不改國碼;只有一位網主。

## 2. MINOR

1. **confirm() 的「applied → Already」沒有說排在哪一步之後。**
   - §2.1 寫「紀錄 applied → 直接回『已建立』(Already)」。
   - 今天的 confirm() 先做 join_state 檢查(NoChange)、再做 k9 == 版本檢查(OtherVersion),之後才看 creator(netrec.rs:309-315)。
   - 如果實作照字面把 applied 判斷放在最前面:分裂期間,網主在還停在 v 的節點上按「確認網路」(紀錄已是 v+1),或在另一個網路的節點上按,都會看到「網路已確認(手機紀錄本來就是『已建立』)」(owner.rs:398)。今天這兩種情況會顯示 OtherVersion / NoChange。
   - **修法**:一句話——「join_state / 版本兩個檢查照舊在前;只有通過之後,applied 紀錄才回 Already、不跑 creator 迴圈」。
   - **測試**:T38 加一臂:applied 紀錄、節點 k9 = 紀錄 − 1 → OtherVersion。負對照:applied 判斷放在最前面 → Already。

2. **net_summary 的建立者旗標「只在 pending 時標」沒有測試。**
   - T26 / T38 測了 confirm 與 forget,但沒測 `MemberView.creator`。這個旗標會決定 Dart `forgettable` 給不給「忘記」(member_ui.dart:153)。
   - 情境:建立者那台在 applied 紀錄裡卡在 joining(§3.6 / A-M1b 要能忘記)。如果旗標照舊,Rust 允許忘記,畫面卻把它藏起來。
   - **修法**:T32 或 T26 加一臂:applied 紀錄、k8 第一筆是 joining 項 → `net_summary(...).members[i].creator == false`,Dart 會提供「忘記」。負對照:今天的 `creator().ok()` → true、被藏起來。

3. **入口 1 的句子兩處不一致**(第 8 輪 A-m8(iv) 只改了一半)。
   - §2.0 已改成「這台不在隊伍網路的成員名單裡(被排除或被忘記)…」。
   - §3.5 網主那一句仍寫「入口 1 的句子『這台已被排除在隊伍網路外,只能…』」,而且它的條件「不在 k11」也包括被忘記的節點。
   - **修法**:§3.5 直接引用 §2.0 的句子。T27 斷言用同一個字串。

4. **剪貼簿清空的時機寫錯**(第 8 輪 B-m5;§17 列為已處理,正文沒有改)。
   - §3.3「成員匯入後清空剪貼簿」、§3.4「匯入成功後清空剪貼簿」。
   - 實際上 `_takeClipboard` 一讀就清空(nodes.dart:603-607)。
   - 後果:§3.4 / T22 的「請再貼一次」在剪貼簿已清空時貼不出東西;成員必須回到收到包的地方(聊天訊息)再複製一次,或請網主再複製一次。
   - **修法**:正文照實寫「貼上時就清空」。「請再貼一次」改成「請從收到的訊息再複製一次並貼上」。網主手機剪貼簿會留著最後一份包,直到下一次複製,這點寫成誠實界線(只有密文 + 名冊)。不加機制。

5. **members 的排序規則可以不要**(依「只做必要的」)。
   - v6.3 之後,app 在 applied 紀錄上已經不讀 k8 的順序(creator() 只在 pending;pending 不可能換密碼);節點也不讀內容。排序唯一的受益者是**降級後的舊 app** 的 creator(),而 §5 已把降級寫成誠實界線。
   - k11 本身就讓建立者排第一:make-network 建 k11 = [建立者];join2 / approve 只做 push 或原位取代(join2flow.rs:223-235、approve.rs:178-181)。
   - 另外,T1 寫的是「建立者(若在)第一」,§2.1 寫的是「k8 第一筆」。建立者被排除之後,這兩者指的不是同一台。
   - **修法擇一**:
     - (a) 刪掉排序,寫「key 4 照 k11 的順序」,並刪掉 mutation 清單的「建立者第一」;
     - (b) 保留,但寫明理由是「降級後的舊 app」,並把 T1 改成「k8 第一筆(若在)第一,其餘照 k11 順序」。

6. **文字殘留**(第 8 輪 A-m6 / A-m8 沒處理完的部分)。
   - (i) §1 標題仍是「第 1、2 輪四位審查逐條核過」。
   - (ii) R30 排在 R32 之後。
   - (iii) §2.0 說「下文的『k9』一律寫明是哪一個」,但 §2.4 / §3.2 仍有裸的「k9 > v」「k9 = 手機版本」。
   - (iv) §12–§15 歷史表仍列「§3.3 敏感標記」「§2.1 修剪保留最舊一項」「EXTRA_IS_SENSITIVE 經 Kotlin」「T34」。建議在 §10 以外的表頭也加「以正文為準」,或在這幾列加「v6.2 已刪」。
   - (v) T31 只寫「建出來的 APK」;第 8 輪 A-m6 要的是 dev 與 release 兩種 APK 都斷言。

## 3. 對每個行為是否都有附負對照的測試

我逐一核過 §2.0、§2.1、§2.2、§2.3、§2.4、§3.1–§3.6 的每條規則與 §7 的對應:

- 都有附負對照的測試。
- 例外是 MINOR-1(confirm 的檢查順序)與 MINOR-2(net_summary 旗標),各缺一臂。
- 真機:T13 / T14 的負對照(轉交前確實分裂、被移除者的鄰居 5 分鐘仍沒有恢復)仍然成立。合成第三人的工具只在 dev-trust 生效,負對照有寫。

## 4. 第 1–8 輪逐項確認(自己審完之後才讀)

| 項目 | v6.3 | 確認 |
|---|---|---|
| v8 A-MAJOR-1 / B-M1:applied 紀錄上的 creator() | §2.1 三條件;§5 降級列;T26、T38 | ✅ 每個呼叫點都核過(§0);順序 → MINOR-1,旗標的測試 → MINOR-2 |
| v8 A-m1 §3.4-2 句子 | §3.4-2 | ✅ |
| v8 A-m2 「版本不明」的條件 | §3.3 | ✅ |
| v8 A-m3 換密碼前的同意包 + 先貼更新包 | §3.4 提示 | ✅ |
| v8 A-m4 §3.2-3 依 k7 分句 | §3.2-3 | ✅ |
| v8 A-m5 owner_enc_pub 不一致的出路 | §2.3 | ✅ |
| v8 A-m6 T31 | aapt2 + 負對照 | ⚠️ 只寫一種 APK → MINOR-6(v) |
| v8 A-m7 測試臂(T24 Persist、T28 prev_hash、T37 負對照) | §7 | ✅ |
| v8 A-m8 文字殘留 | R31 行號 ✅;回 5 的效果 ✅ | ⚠️ (i)(ii)(iii)(iv) 仍在;入口 1 的句子只改了一半 → MINOR-3、MINOR-6 |
| v8 B-m1 兩台 joining | §3.6 選了 (b) | ✅ 與前置 2 一致 |
| v8 B-m2 同一次讀取 | §2.3 由 Kotlin 重讀 | ✅ |
| v8 B-m3 被移除者換新節點 | §3.6 比對 owner_pub | ✅ |
| v8 B-m4 「之前的擁有者:不明」 | §3.6 | ✅ |
| v8 B-m5 剪貼簿清空時機 | §17 列為已處理 | ❌ 正文未改 → MINOR-4 |
| v8 B-m6 T38 殘句 | T38 已換成具體斷言 | ✅ |
| v8 B-m7 排序沒寫完 | §2.1 | ⚠️ 其餘的順序仍沒定;規則可以刪 → MINOR-5 |
| v1–v7 各項 | 正文 | ✅ 抽查都還在正文:三個入口(各在第一次 SignAdmin 之前)、k10 不推進、k12 標 used、secrets 要簽、TooOld 取代要舊 admins 簽、2b 先於 PreviousNode、+1 路清 k10 並驗 members prev_hash、commit 後 / 匯入後不自動送、start 公式、一律產包、128 KiB 以解碼後計、k4 正則與 fail-closed、前置 5、開始時不查 k4、前置 2 例外、收件人契約、忘記導向由 Rust 強制、allowBackup=false、Debug 衛生 |

## 5. 判定

0 BLOCKER / 0 MAJOR / 6 MINOR → **APPROVE-WITH-CHANGES**。

- 第 8 輪的 MAJOR 已真正關閉:app 裡 creator() / confirm() 的每一個呼叫者都落在新規則下;沒有其他路徑假設 k8 非空,也沒有其他路徑假設換密碼後 creator() 一定成功。
- 6 個 MINOR 都只改一句或補一個測試臂,不加機制。MINOR-5 是建議刪掉一條規則。
