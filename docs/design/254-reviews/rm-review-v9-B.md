# 254-app-remove-member.md v6.3 — 第 9 輪審查 B(安全優先,審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v6.3(496 行,未 commit;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 @ fbc01ae(NU v4.1、219-protocol.cddl、feed/batman-prov/src)。全程唯讀,沒有碰裝置。先自己審完整份,最後才讀第 1–8 輪(§4)。

**判定:APPROVE-WITH-CHANGES**,0 BLOCKER / 0 MAJOR / 7 MINOR。MINOR 都是補句子、補測試臂或釐清條件順序,不需要新機制;我認為不必再整份重審,改完由作者自查即可。

## 0. 自己核的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| `creator()` 只有四個呼叫點:netrec `confirm`、netrec `forget_joining`、bridge `net_summary`、bridge `net_forget_joining`;Dart 只透過 `MemberView.creator` 旗標 → `forgettable`;Kotlin 沒有 | ✅ | netrec.rs:281-283、:316、:336;bridge owner.rs:98、:127;member_ui.dart:153;nodes.dart:1009、:1013(grep 全 app/rust、app/lib、app/android) |
| `confirm()` 的順序:netcfg → join_state(非 Applied → NoChange)→ k9 ≠ version → OtherVersion → `creator()?` → 升級 | ✅ | netrec.rs:307-329 |
| `Already` 帶的 `save_pending` 來自節點 info → 只在 join_state = Applied 之後才有意義 | ✅ | netrec.rs:309-312;owner.rs:394-399(confirm_text) |
| 「確認網路」按鈕對任何紀錄都在;唯一呼叫點 owner.rs:777 | ✅ | nodes.dart:997-1002、:1132;owner.rs:771-786 |
| pending 紀錄 = `NetRec::made`,list = None,members() 由 k8 推、只有建立者;邀請 / 同意 / join2 都要求 applied → pending 時沒有別的項 | ✅ | netrec.rs:255-258、:273-277;join2flow.rs:304-306 |
| join2 Done(Applied) 先設 state = APPLIED 再呼叫 members() → 建立者項是 Applied;今天沒有「applied 紀錄 + 建立者 joining」的合法路徑需要 confirm 處理 | ✅ | owner.rs:1180-1190 |
| net_summary 用 `creator().ok()`(k8 空不會失敗);bridge forget 用 `.ok()`,netrec forget 用 `?`(k8 空就失敗) | ✅ | owner.rs:98、:127;netrec.rs:336 |
| CDDL members key 4 = `[* member]`;節點 netUpdate 只驗 members 的簽章 / net_id / version,不讀內容 → k8 空的版本節點收 | ✅ | 219-protocol.cddl:362;node.go:1143-1153 |
| 節點 netJoin 只驗 netcfg 由它自己的 admins 簽,版本不限 | ✅ | node.go:1035-1052 |
| 加入申請由 payload 的 owner_pub 驗章、sig_enc 綁 owner_enc_pub → 別人無法冒用某人的 owner_pub 進他的組 | ✅ | approve.rs:39-57 |
| check_joinreq:invite used → InviteUsed;同 DAC 在 k11 只有 approved + 同 owner_pub 能取代 | ✅ | approve.rs:69-86 |
| 同意包匯入:netcfg = 邀請那份;members / secrets / msecrets 都由 cfg.admins 簽、net_id / version 綁定、target 綁 dac_hash / owner_enc_hash | ✅ | approve.rs:275-298 |
| `existing()` +1 / TooOld / SameVersionDifferent / PreviousNode | ✅ | approve.rs:300-324 |
| join2 網主模式 begin:第一個動作 `secrets_step` = SignAdmin,之前沒有寫入;隊員模式只認 k7 + k5 target | ✅ | join2flow.rs:298-366 |
| join2 回 5 → info → Applied 就把項寫成 applied(不比版本) | ✅ | join2flow.rs:485-490、:690-712 |
| 成員角色 = info / network/update / status | ✅ | provd/session.go:76-82 |
| owner TagKey 由節點 claim/finish 給、每台不同 → 抓到一台不能登入網主的其他台 | ✅ | flow.rs:19-29;kdf.rs:27-29 |
| 記錄讀取 = Dart `storeReadSealed`(Rust store)+ Kotlin `open`;同意時按下確認才重讀 | ✅ | nodes.dart:614-621、:696 |
| 貼上時 `_takeClipboard` 一讀就清空 | ✅ | nodes.dart:604-606 |
| store / cbor 沒有整份大小上限(只有 MAX_DEPTH 32) | ✅ | cbor.rs:48;store.rs 無長度檢查 |

## 1. v6.3 的改動逐項

| 改動 | 結論 |
|---|---|
| confirm() 對 applied 紀錄不碰 k11 | ✅ 關掉第 8 輪 A / B MAJOR(建立者被排除後改到別人的項;k8 空時 NET_DAMAGED)。條件放在哪一步沒寫清楚 → m1 |
| forget / net_summary 只在 pending 用 creator() | ✅ pending 時只有建立者一項(上表),所以 pending 保護完整;applied 時 Dart 的 `forgettable` 旗標與 Rust 規則一致。bridge owner.rs:127 與 netrec.rs:336 兩處都要改,§2.1 已點名 |
| k8 空或建立者不在 → 不排序 | ✅ 排除最後一台後產得出下一版;§2.4 的措辭沒跟上 → m7 |
| 產包同一次讀取 | ✅ 沒有漏洞:產包不寫紀錄,與 commit 競爭時最多產出舊版的包,收件人在那次讀取時就在 k11、本來就有那一版。說法不精確 → m3 |
| 同意確認框也看歷代的 owner_pub | ✅ 不擋合法流程(仍在 k11 的人不觸發);缺測試臂與修剪後的界線 → m2 |

## 2. 依角色的結論(兩個方向)

| 角色 | 沒有網主明確同意就漏秘密? | 擋合法流程 / 擋換密碼 / 改別人紀錄? |
|---|---|---|
| 被移除的人 | ✅ 不會:收件人契約只看目前 k11;邀請在 commit 時全部作廢;重新申請要 SAS + 網主同意,舊 DAC 或舊 owner_pub → 確認框;換新 app(新 owner_pub)+ 新節點只能靠 SAS 與網主判斷(誠實界線,與今天的邀請相同) | ✅ 開始前檢查只讀網主自己的節點;提早換別人的節點只影響分裂時機(R32,§6 已寫) |
| 被抓的節點(含網主自己的;DAC 私鑰 + owner TagKey;info 會說謊) | ✅ 入口 1 以 k11 為準;入口 2 與同意確認框都在第一次 SignAdmin 之前,由 Rust 參數強制;TagKey 每台不同,不能登入其他台 | ✅ 開始時不查 k4;k9 檢查不含目標、指名、多台 → 關藍牙;謊報 InProgress / NotApplied → 不算;卡在 joining → 前置 2 例外;k8 空 → v6.3 已解 |
| 其他留下的成員 | ✅ 包只加密給自己的金鑰,target 有綁;不能簽 | ✅ 改不到別人的 mnet(鏈 / 取代都要網主簽);owner_enc_pub 不一致只有本人造得出 |
| 剪貼簿 | ✅ 沒有明文秘密;名冊外露是誠實界線 | 換包 → 被拒或「已經匯入過」(只是 DoS);說法殘留 → m4 |
| 惡意 app / 被攻陷的 OS | 與今天相同(SignAllowList 不要使用者驗證、run-as),誠實界線 | 同 |
| 網主手機遺失 | 誠實界線 + §9 | — |
| 成員手機遺失 | ✅ 移除那個人 | — |
| 我們自己的錯 | ✅ 同版只簽一次、k4 fail-closed、allowBackup=false(T31 有真測試)、Debug 衛生(T24)、dev-trust 閘門(T25 / T36) | confirm 的條件位置 → m1 |

## 3. MINOR

1. **confirm() 的「applied → Already」放在哪一步沒寫清楚。**
   - 情境:網主在一台別的網路的節點、被排除還停在舊版的自己節點、或 info 回 Unknown 的節點上按「確認網路」。若實作照字面「紀錄 applied → 直接回 Already」放在 join_state 檢查之前,畫面會說「網路已確認(本來就是已建立)」,而 `save_pending` 沒有來源(它來自 info,netrec.rs:309-312)。
   - 不漏秘密、不改紀錄,但會對一台被排除 / 被抓的節點說「已確認」,誤導網主。
   - 修法:§2.1 寫成「join_state 與版本檢查照舊(NoChange / OtherVersion 不變);applied 紀錄只略過『呼叫 creator() 與升級』那一步,回 Already」。T38 加一臂:applied 紀錄 + OtherNetwork 的 info → NoChange,不是 Already。

2. **歷代 owner_pub 觸發確認框:沒有測試臂,修剪後的界線沒寫。**
   - 第 8 輪 B-m3 要求「測試一臂」,§7 沒有(T35 / T38 都沒提)。
   - removed 會累積,所以 DAC 那個判斷不受修剪影響;但 owner_pub 只在 k13 的 members 裡,32 版之後就看不到,確認框不會跳。
   - 修法:T38 或 T35 加一臂:被移除的人用同一個 owner_pub、全新 DAC 申請 → 跳框,按否 → 0 次 SignAdmin;負對照:只比 DAC → 不跳框。§3.6 加半句:「歷代被修剪後,這個 owner_pub 的判斷就沒有了(DAC 的判斷仍在)—— 誠實界線」。

3. **「由 Kotlin 重讀一次紀錄」不準確。**
   - 讀取是 Dart `_readRecord` = Rust `storeReadSealed` 加 Kotlin `open`(nodes.dart:614-621),同意那條路也是在 onConfirm 時重讀(nodes.dart:696)。
   - 修法:寫成「按下時照同意的做法重讀(nodes.dart:696),解碼一次交給 Rust」。另加一句理由:產包不寫紀錄,與 commit 競爭時最多產出舊版的包,而收件人在那次讀取時就在 k11 → 不漏。

4. **剪貼簿的說法仍與程式不同**(第 8 輪 B-m5 沒改)。
   - §3.3 寫「成員匯入後清空剪貼簿」,§3.4 第二段寫「匯入成功後清空剪貼簿(B-m7)」;實際上是貼上那一刻就清空(nodes.dart:604-606)。
   - 網主手機的剪貼簿會留著最後一份包,直到下一次複製;這句誠實界線也沒寫。
   - 修法:兩處改成「貼上時清空」,§3.3 補網主端那半句。

5. **commit 要明寫 k11 一定寫成實際的清單。**
   - list = None 時 `members()` 由 k8 推(netrec.rs:273-277)。今天 list = None 的 applied 舊紀錄只會有建立者,所以 commit 時換掉 k8 不會出錯。但這要靠「list = None 時 k8 只有一項」這個隱含前提。
   - 修法:§3.1 commit 句寫「k11 寫成明確的清單(不留 None)」;T3 斷言 commit 後 k11 存在。

6. **文字殘留**(第 8 輪 A-m8 的 i / ii / iii / v 沒改):
   - §1 標題仍寫「第 1、2 輪四位審查逐條核過」;
   - R30 排在 R32 之後;
   - §2.4、§3.2 仍有裸的「k9」(「k9 > v」「k9 = 手機版本」);§2.0 已說要寫明是哪一個;
   - §12–§15 的歷史列仍寫「§3.3 敏感標記」「§2.1 修剪保留最舊一項」「EXTRA_IS_SENSITIVE 經 Kotlin;T36」「T34」,沒有標「v6.2 已刪」(§10 的「以正文為準」只放在 §10)。

7. **§2.4 的排序措辭與 §2.1 不一致。**
   - §2.4 寫「建立者(若還在)第一」,§2.1 寫「k8 第一筆若還在 key 4 就排第一」。建立者被排除過一次之後,k8 第一筆已經不是建立者了。
   - 其餘的順序也沒寫(第 8 輪 B-m7);T1 要斷言 bytes 需要這句。
   - 修法:§2.4 與 T1 改用 §2.1 的說法,加「其餘照 k11 順序」。

## 4. 第 1–8 輪逐項確認(自己審完之後才讀)

| 項目 | v6.3 | 確認 |
|---|---|---|
| v8 A-MAJOR-1 / B-M1 creator 在 applied 紀錄上仍被用 | §2.1 三條;R31;§5 降級列;T26、T38 | ✅(條件位置 → m1) |
| v8 B-m1 兩台 joining 與前置 2 矛盾 | §3.6 改「其他先忘記」+ 誠實界線 | ✅ |
| v8 B-m2 同一次讀取 | §2.3 | ✅(說法 → m3) |
| v8 B-m3 被移除者換新節點 | §3.6 比 owner_pub | ✅ 正文;測試臂 → m2 |
| v8 B-m4 之前的擁有者「不明」 | §3.6 | ✅ |
| v8 B-m5 剪貼簿說法 | — | ❌ 沒改 → m4 |
| v8 B-m6 T38 殘句 | T38 換成 confirm 的具體斷言 | ✅ |
| v8 B-m7 排序 | §2.1 | ⚠️ §2.4 / T1 沒跟上 → m7 |
| v8 A-m1 §3.4-2 句子 | 改成「離開再重新邀請」 | ✅ |
| v8 A-m2 「版本不明」條件 | §3.3 | ✅ |
| v8 A-m3 換密碼前的同意包 + 先貼更新包 | §3.4 產包畫面提示 | ✅ |
| v8 A-m4 §3.2-3 依 k7 分句 | §3.2-3 | ✅ |
| v8 A-m5 owner_enc_pub 不一致的出路 | §2.3 | ✅ |
| v8 A-m6 T31 | aapt2 + 負對照 | ✅ |
| v8 A-m7 測試臂(T24 / T28 / T37) | §7 | ✅ |
| v8 A-m8 文字殘留 | R31 行號、入口 1 句、回 5 的效果 | ⚠️ (iv)(vi) ✅;(i)(ii)(iii)(v) 仍在 → m6 |
| v7 B-M1 收件人契約 | §2.3、T40 | ✅ 重走:舊畫面、第二次移除、自己、不一致都拒,0 次 SignAdmin |
| v7 其餘、v6 A-MAJOR-1 / B-MAJOR、v5 及以前(三個入口、k10 不推進、k12 標 used、secrets 要簽、TooOld 要舊 admins 簽、2b 先於 PreviousNode、+1 路清 k10、commit 後 / 匯入後不自動送、start 公式與一律產包、128 KiB 解碼後、k4 正則、前置 5、開始不查 k4、前置 2 例外、240 s 觀察、allowBackup=false、dev-trust 閘門、合成工具不進 workspace) | 正文 | ✅ 抽查都在正文,沒被 v6.3 改壞 |

## 5. 判定

0 BLOCKER / 0 MAJOR / 7 MINOR → **APPROVE-WITH-CHANGES**。

- 第 8 輪兩位共同的 MAJOR 已關。我照每個 `creator()` / `confirm()` / `forget_joining` 的呼叫點(Rust、bridge、Dart)逐一走過,沒有剩下的路徑。
- 每個角色兩個方向都沒有找到新的洞。
- 7 條 MINOR 都是補字或補測試臂。其中 m1(confirm 條件的位置)和 m2(owner_pub 觸發的測試臂)建議在實作前改,其餘可以在實作 PR 一起收。
