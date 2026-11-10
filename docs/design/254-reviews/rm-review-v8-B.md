# 254-app-remove-member.md v6.2 — 第 8 輪審查 B(安全優先,審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v6.2(473 行;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3(NU v4.1、219-protocol.cddl)。全程唯讀,沒有碰裝置。先自己審完整份,最後才讀第 1–7 輪(§5)。

**判定:APPROVE-WITH-CHANGES**,0 BLOCKER / 1 MAJOR / 7 MINOR。

v6.2 的三個改動:
- 收件人契約:✅ 在我走過的每條路都關掉了第 7 輪 B-M1(§2)。只差一句「同一次讀取」的說明(m2)。
- Rust 強制忘記導向:✅。
- 刪掉剪貼簿敏感標記:✅ 誠實界線成立。

問題出在第四個改動。刪掉「k13 保留最舊一項」、`creator()` 回到 k8 第一筆的理由是「applied 之後 creator 只剩畫面標示」(§2.1)。**這句不對**:`confirm()` 在 applied 紀錄上照樣用 `creator()`,所以建立者被排除之後,它會改到**別人**的項(M1)。

## 0. 自己查的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| `creator()` = k8 members 第一筆;k8 空 → `Err("members v1 empty")` | ✅ | netrec.rs:281-283 |
| `confirm()` 不看紀錄 state,一律 `rec.creator()?`;applied 紀錄上 `changed = false`,但只要 creator 那項不是 Applied,就把它改成 Applied 並寫回 | ✅ | netrec.rs:307-329 |
| 「確認網路」按鈕對任何紀錄、任何登入中的節點都有;走的是 `request_confirm_network` 加上 `info-confirm` | ✅ | nodes.dart:997-1002、:1132;bridge owner.rs:968-980、:771-786 |
| `forget_joining` 先做 `rec.creator()?`(k8 空就整個失敗),bridge 也另外檢查一次 creator | ✅ | netrec.rs:335-347;bridge owner.rs:127 |
| `check_joinreq`:同一顆 DAC 已在 k11 → 只有「Approved 而且同一個 owner_pub」能被取代,其他都是 AlreadyMember | ✅ | approve.rs:75-84 |
| 加入申請用 payload 裡的 owner_pub 驗章;sig_enc 用 owner 金鑰簽 owner_enc_pub → owner_enc_pub 綁在 owner_pub 上,別人塞不進某人的組 | ✅ | approve.rs:39-57 |
| CDDL member-list key 4 = `[* member]`(可以是空的);`member_list_payload` 接受空清單;節點不讀 members 內容 | ✅ | 219-protocol.cddl:358-366;cose.rs:110-134;R28 |
| join2 網主模式 `begin`:第一個動作就是 `secrets_step`(SignAdmin);隊員模式只認 k7 加上 k5 的 target | ✅ | join2flow.rs:296-345 |
| secrets 的加密綁 target 與 net_id / version;匯入時比對 target 是不是自己的 dac_hash / owner_enc_hash | ✅ | approve.rs:263-273、:290-298 |
| 複製用 Flutter `Clipboard.setData`;貼上時 `_takeClipboard` **一讀就清空**(不是匯入成功才清) | ✅ | nodes.dart:604-606、:652 |
| Manifest 目前沒有 allowBackup,也沒有 IS_SENSITIVE(v6.2 已刪) | ✅ | grep android/app/src/main(無結果) |

## 1. MAJOR

### M1 建立者被排除之後,`confirm()` 會把 k8 新的第一筆(可能是別人的 approved 項)升成 applied;k8 空時「確認網路」會報紀錄壞掉

**情境 A(有遠端隊員)**
1. 網主的建立者節點 A 被抓,網主「排除這台」。
2. v+1 的 members:建立者已不在。§2.4 只寫「建立者(若還在)第一」,其他項照 k11 的順序。
3. k11 的順序是加入的先後。網主的第二台 B 若是在遠端隊員 X 被同意之後才用 join2 加的,k8 第一筆就是 X 的項(Approved)。
4. 網主之後對 B 按「確認網路」。B 回 k10 = 本網、k9 = 目前版本,netrec.rs:316-324 就把 X 的項改成 Applied 並寫回。
5. X 的同意包若弄丟了,網主要重新同意 X 的同一台節點,`check_joinreq` 會回 AlreadyMember(approve.rs:78-83)。剩下的出路只有「移除這個人」,也就是全網換一次密碼。

**情境 B(網主排除自己最後一台,使用者決定可以;隊伍裡沒有遠端隊員,例如 T26)**
- v+1 的 k8 members 是空的,`creator()` 回 Err。
- 「確認網路」→ `confirm()` 的 `?` → 顯示 `[REQ_FAIL] NET_DAMAGED`,把一份好好的紀錄說成壞掉。
- 若「只在 pending 保護」實作時還是先 `rec.creator()?` 再看 state,之後 join2 新節點一中斷、留下 joining 項,就永遠忘不掉。前置 2 又會擋住除了它以外的每一次換密碼。
- 舊版 app(降級)的 `forget_joining` 一定會這樣失敗(netrec.rs:336)。

**證據**:§2.1「它只用在 pending 紀錄的 confirm 與 forget 保護…applied 之後只剩畫面標示」與 netrec.rs:307-329 不符(confirm 不看 state)。§5 的降級列「只影響畫面與 forget 保護」漏了 confirm 和 k8 空。T38 那一臂「`confirm()` 對建立者的升級在 k13 存在時仍正確」是 v6.1 用 k13 判 creator 時留下的,v6.2 已經沒有意義。第 7 輪 A-m13 提過 confirm 會升級「joining 的建立者」,但沒看到 creator 換人之後升到的是**別人的項**,也沒看到 k8 空的情況。

**修法**(兩行條件,不加機制):
- `confirm()` 只在 `rec.state == PENDING` 時升級 creator 那一項;applied 紀錄回 `Already` / `OtherVersion`,不呼叫 `creator()`。
- `forget_joining` 與 bridge `net_forget_joining` 的 creator 檢查寫成「pending 才查」,而且 applied 紀錄完全不呼叫 `creator()`(不能讓 k8 空的 Err 往外傳)。
- §2.1 那句改成事實。§5 降級列補上「舊 app 的 confirm 會升級 k8 第一筆;k8 空時舊 app 的確認 / 忘記會失敗(誠實界線)」。
- T38 那一臂換成新的 T:
  - 排除建立者,讓 k8 第一筆是 X(Approved),對 B 按確認網路 → 紀錄不變、X 仍是 Approved;負對照用今天的 `confirm()` → X 變 Applied。
  - k8 空的時候確認網路 → 沒有錯誤;忘記 joining 項 → 成功。

## 2. 收件人契約(第 7 輪 B-M1)逐路徑確認

| 路徑 | 結果 |
|---|---|
| 從成員名單重新產包 | ✅ 清單與契約都從 k11 取;owner_pub = 自己 → 拒絕 |
| 第二次移除之後 | ✅ 被移除的人已從 k11 刪掉 → 拒絕,0 次 SignAdmin(T40) |
| 舊畫面 | ✅ 只要 k11 與 k5 / k6 / k13 出自**同一份**解碼的紀錄,就沒有洩漏:任何一份歷史快照裡 k11 的人,本來就拿過那份快照的 secrets。但 T40 要「舊畫面上的人 → 拒絕」,就得在按下時重讀;設計沒說是誰重讀 → m2 |
| k13 歷代 | ✅ 明文不從 k13 取收件人 |
| owner_enc_pub 不一致 | ✅ fail-closed。sig_enc 綁 owner_pub(approve.rs:46-52),只有本人能造成不一致,別人無法用它擋別人的包 |
| 同一版本內重新同意被移除的人 | ✅ 回到 k11、k10 = 目前 → 不在清單(由同意包帶秘密,網主明確同意過) |
| confirm() 誤升級之後的 X | ✅ 仍是 owner_pub ≠ 自己 → 照常拿包(M1 不影響秘密) |

## 3. MINOR

1. **兩台自己的節點同時卡在 joining 時,v6.2 的說法與前置 2 互相矛盾**(第 7 輪 B-m4 的處理變成新問題)。§3.6 說「一次排除一台,另一台**先不要忘記**,在下一次排除它」;但 §3.1 前置 2 的例外只有「本次要排除的**那一台**」,所以排除第一台時,第二台的 joining 就把前置 2 擋住了。照設計的指示做,換密碼開始不了;網主只能違反指示去忘記另一台。這不是攻擊者造成的,網主也有出路,所以列 MINOR。但這是緊急換密碼的路徑,T32 照兩句一起寫也寫不出來。修法擇一:
   - (a) 前置 2 的例外改成「本次排除對象的集合」,「排除自己的一台」可以一次勾多台(§2.4 的「不含要排除的那台」也改成集合);
   - (b) 最小改法:刪掉「先不要忘記」,改成「其他卡在 joining 的自己節點要先忘記(它不在 k11,拿不到新密碼;代價是之後加回不會跳確認框,§6 誠實界線)」,前置 2 不成立時的說明也這樣寫。
2. **產包的快照要寫清楚。** §2.3 加一句:「k11、k5 / k6、k13 出自同一次讀取(同一個 generation);按下產包時由 Kotlin 重讀紀錄再交給 Rust,不用畫面保存的明文」。否則 T40 的「舊畫面 → 拒絕」那一臂要嘛測不到,要嘛實作會從不同讀取拼出 k11 和 k5 / k6(那才會漏)。
3. **被移除的人用同一支手機、換一台全新節點申請時,沒有提示。** 「之前被移出過」只比 DAC(§2.0 入口 2、§3.6)。被移除的人 P 若拿到網主新發的邀請(邀請經剪貼簿 / 聊天群組流通),用一台從沒入網的節點、取別人的名字申請,同意畫面不會有任何提示。網主仍然要比對 SAS 並按同意,所以不是沒經同意就漏;但網主看到的身分可能是錯的。修法(畫面一句,同一個確認框):申請的 owner_pub 出現在 k13 任何一版的 members、卻不在目前 k11 →「這支手機(〈指紋〉)之前的節點被移出過」。測試一臂。
4. **「之前的擁有者」在歷代被修剪後要有退路。** k13 只留 32 版。之前被移出、但已經不在任何保留版本 members 裡的 DAC,入口 2 仍會判「之前被移出過」(removed 會累積,這點沒問題),只是找不到之前的擁有者。§3.6 寫明顯示「之前的擁有者:不明」(第 7 輪 B 已建議,正文沒寫)。
5. **剪貼簿的說法與程式不同。** §3.3 / §3.4 說「成員匯入**成功後**清空剪貼簿」,實際上是貼上那一刻就清空(nodes.dart:604-606),比設計說的更嚴,正文照實寫。另外加一句誠實界線:網主手機的剪貼簿會留著最後一份包,直到下一次複製;包裡只有密文和名冊。
6. **T38 / §5 的殘句**:T38「`confirm()` 對建立者的升級在 k13 存在時仍正確」與 v6.2 不符(併入 M1);§16 說 T34 已刪,§14 的歷史列保留可以。
7. **§2.4 members 的排序沒寫完。** 只寫「建立者(若還在)第一」,其餘的順序沒定。M1 修好以後順序就不再影響行為,但 T1 要能斷言 bytes,所以寫明「其餘照 k11 順序」。

## 4. 依角色的結論(兩個方向)

| 角色 | 漏秘密? | 擋合法流程 / 擋換密碼? |
|---|---|---|
| 被移除的人 | ✅ 收件人契約只看目前 k11;偽造的鏈或重新邀請要網主簽;邀請在 commit 時全部作廢;用舊 DAC 申請 → 確認框;用新節點申請 → 要網主同意(提示 → m3) | ✅ 擋不住:§2.4 只查網主自己的節點;提早切換別人的節點只影響時機(R32,誠實界線) |
| 被抓的節點(含網主自己的;有 DAC 私鑰與 owner TagKey;會謊報 info) | ✅ 入口 1 以 k11 為準;入口 2 與同意都在第一次 SignAdmin 之前確認,由 Rust 參數強制 | ✅ 開始時不查 k4;k9 檢查不含目標;多台互擋 → 關藍牙;Unknown 算連不上;卡在 joining → 前置 2 例外;**兩台 joining → m1** |
| 其他留下的成員 | ✅ 包只加密給自己的金鑰;target 有綁;寫入走 CAS;owner_enc_pub 不一致只有本人能造成 | 提早切換、串通 → 誠實界線 |
| 剪貼簿 / 惡意 app | ✅ 沒有明文秘密;名冊外露是誠實界線(與今天的同意包相同) | 換成別的包 → 被拒或「已經匯入過」(只是 DoS) |
| 被攻陷的 OS / 網主手機遺失 | 與今天相同 → 誠實界線加 §9 | — |
| 成員手機遺失 | ✅ 移除那個人 | — |
| 我們自己的錯 | ✅ 同版只簽一次、k4 fail-closed、allowBackup=false、Debug 衛生、dev-trust 閘門 | **建立者被排除後 confirm 改到別人的項 / k8 空 → M1** |

## 5. 第 1–7 輪逐項確認(自己審完之後才讀)

| 項目 | v6.2 | 確認 |
|---|---|---|
| v7 B-M1 收件人來源 | §2.3 契約、T40 | ✅(快照說明 → m2) |
| v7 A-m1 / B-m3 忘記導向在 Rust 強制 | §3.6、T39 在 bridge 層 | ✅ |
| v7 A-m2 正式版的忘記對話框 | 限 dev-trust、T36 | ✅ |
| v7 A-m3 / B-m1 §3.5 分成員 / 網主 | §3.5 | ✅ |
| v7 A-m4 / A-m7 / B-m5 貼上順序 | §3.4 提示 | ✅ |
| v7 A-m5 只在 k10 的節點、leave 句 | §3.5 | ✅ |
| v7 A-m6 缺 k10 = 最舊 − 1 | §2.1 | ✅ |
| v7 A-m8 只算 Applied | §2.4 | ✅ |
| v7 A-m9 回 5 後直接送 | §3.5 | ✅ |
| v7 A-m10 文字 / 測試殘留 | T27 / T38 | ✅;T38 又有一條新的殘句 → m6 |
| v7 A-m11 已忘記的繞路 | §3.6 | ✅ |
| v7 A-m12 刪 EXTRA_IS_SENSITIVE | §3.3 誠實界線 | ✅ 包裡沒有明文秘密,與今天的同意包一樣(nodes.dart:652);說法 → m5 |
| v7 A-m13 刪「保留最舊一項」 | §2.1 | ⚠️ 刪除本身可以(removed 會累積,入口 2 不受影響;start 公式不受影響),但理由「applied 只剩畫面」不對 → **M1** |
| v7 B-m2 join2 確認由 Rust 強制 | §2.0 入口 2 | ✅ |
| v7 B-m4 兩台同時 joining | §3.6 | ❌ 新的說法與前置 2 矛盾 → m1 |
| v7 B-m6 owner_enc_pub 不一致 | §2.3 | ✅ |
| v7 B-m7 既有結構的 Debug | §6 | ✅ |
| v7 B-m8 合成工具 workspace | §7 | ✅ |
| v7 B-m9 +1 路 members prev_hash | §2.2 | ✅ |
| v6 B-m3 之前的擁有者(修剪後「不明」) | — | ⚠️ 正文沒寫 → m4 |
| v1–v6 各項 | §10–§15 | ✅ 抽查都還在正文:三個入口;k10 不推進;k12 標 used;secrets 要簽;TooOld 取代要舊 admins 簽;2b 先於 PreviousNode;+1 路清 k10;commit 後 / 匯入後不自動送;start 公式與一律產包;128 KiB 以解碼後計;k4 正則;前置 5;開始時不查 k4;前置 2 例外;≥ 240 s 鄰居觀察;allowBackup=false |

## 6. 判定

0 BLOCKER / 1 MAJOR / 7 MINOR → **APPROVE-WITH-CHANGES**。

- **M1**:`confirm()` 只在 pending 時碰 creator;forget 在 applied 紀錄上不呼叫 `creator()`;改 §2.1 的理由與 §5 的降級列;加 T(含負對照)。程式改兩行條件,文件改兩句。
- m1 要選 (a) 或 (b)。(b) 只改文字,不加機制。
- 其他 MINOR 都是補一句或補一個測試臂。
- 依規則 M1 關掉後仍要整份重審;改動範圍很小。
