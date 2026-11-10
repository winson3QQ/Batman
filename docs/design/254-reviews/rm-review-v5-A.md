# 254-app-remove-member.md v5 — 第 5 輪審查 A(正確性 / 介面 / 生命週期 / 現場;審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v5(375 行,untracked;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 `feat/254-p3` @ fbc01ae(NU v4.1)。唯讀,沒有碰裝置。先自己審整份並逐條走流程,之後才讀第 1–4 輪報告(§5)。

**判定:APPROVE-WITH-CHANGES**。0 BLOCKER / 1 MAJOR / 10 MINOR。

v5 的三個入口拆法是對的:第 4 輪的 BLOCKER(重新邀請 / 加回 / 新節點被擋)和 MAJOR(一人多台第一台換不了)我照程式碼重走一次,都通了(§2 表)。剩下的 MAJOR 不是新機制的洞,而是**自己節點的「joining」項**這個既有狀態和 v5 的規則之間沒有寫清楚的契約:在「加回找回來的節點」這條正常流程裡,join2 收到 5 之後該把 k11 寫成什麼沒有定義;若留在 joining,之後每一次換密碼都被前置 2 擋住,而 joining 的建立節點(creator)又永遠不能忘記。修法是改三個條件,不加機制。

## 0. 事實核對(親自讀原始碼)

| # | 結果 | 依據 / 備註 |
|---|---|---|
| R1 | ✅ | netrec.rs:1-11、:183-252;joinflow.rs:148(`net_config_payload(&net_id, 1, None…)`)、:203、:216、:220 |
| R2 | ✅ | netrec.rs:47-58、:134-151(`member_value` 同時用於 k11 與 mnet k7)、:265-278 |
| R3 | ✅ | netrec.rs:281-283;:316 confirm;:336 forget;bridge owner.rs:98(net_summary 標 creator)、:127(**forget 一律拒絕 creator,不看 state**,與 MAJOR-1 有關) |
| R4 | ✅ | store.rs:1-11(AAD 含 generation、回滾照樣打得開)、:136-145 write_cas 在 `CAS` 鎖下 |
| R5 | ✅ | Keys.kt:91-100 `sign()` 只看 allow-list,沒有 user auth;SignAllowList.kt ADMIN_LABELS = netcfg / members / secrets / invite / msecrets |
| R6 | ✅ | mrec.rs:1-8、:80-124 |
| R7 | ✅ | approve.rs:300-324 `existing()`;TooOld 在 :313-314 |
| R8 | ✅ | approve.rs:156-157(同意包 members = k8 原樣)、:204-216、:281-285;exact_keys `{2}` 實際在 :383-384(設計寫 :385-387,差 2 行) |
| R9 | ✅ | cose.rs:110-134 key 5/6/7 寫死空 |
| R10 | ✅ | netrec.rs:38-44;invite.rs:217-221、:264、:283;approve.rs:69-86 |
| R11 | ✅ | invite.rs:143-153;:167 呼叫 |
| R12 | ✅ | netrec.rs:20;invite.rs:190 |
| R13 | ✅ | conn.rs:12;envelope.rs:13、:66-81 |
| R14 | ✅ | noise.rs:1-5;tests/vectors.rs:44 |
| R15 | ✅ | node.go:1035-1052:`rec.Net != nil` → `EStaleVersion`(=5,node.go:39);否則以 `adminsOf(cfg)` 驗,版本不限 |
| R17 | ✅ | join2flow.rs:333-347(:339-341 target 與 k7 都要 = 登入的 DAC) |
| R20 | ✅ | loginflow.rs:1-5 |
| R22 / R29 | ✅ | flow.rs:117-150 |
| R23 / R24 | ✅ | netrec decode 只讀已知 key;approve.rs:184、invite.rs:285 整份 encode |
| R26 | ✅ | nodecert.rs:138-162 trust_gate + verify_offline |
| R27 | ✅ | approve.rs:401-410 從頭建 MNet;join2flow.rs:238 `MNet { me: e, ..m.clone() }`(新欄位進 struct 後會自動帶過去) |
| R28 | ✅ | node.go:1143 註解;netUpdate 只驗 members 的簽章 / net_id / 版本(:1144-1154) |
| R30 | ✅ | `gh api …/comments/6771853016`:「the payload's helper carries the new checks ("update shape" + the update country string)」 |
| join2 網主模式的 SignAdmin 在 PersistNet **之前** | ✅ | join2flow.rs:297-330 `begin` → `secrets_step`(SignAdmin)→ settings/get → `persist_joining`。所以入口 2 必須在 `begin` 裡、第一次 SignAdmin 之前(MINOR-6) |
| join2 收到 5 → 讀 info → `Applied` 就寫 k11 applied | ✅ | join2flow.rs:693、:707 `(JoinState::Applied, _) => self.applied()` |
| netUpdate 的鏈檢查 | ✅ | node.go:1083-1165:每步前一版 admins、版本 +1、prev_hash、net_id、國碼、members 簽章/版本;最後一步 parseNet + secrets 綁版本(:936-955) |
| 空的 members key 4 合法 | ✅ | 219-protocol.cddl:362 `4 => [* member]`(排除最後一台且沒有隊員時會出現) |
| Manifest 沒有 `allowBackup` | ✅ | grep AndroidManifest.xml 無結果 |

## 1. NU §3「app 必須處理的事」對表

全部有落點,判定同第 4 輪(只用擁有者連線 → pin DAC / 槽位不適用;同版只簽一次;k9 > v 拒絕而非 max+1,比 NU 嚴;>8 塊不送;不帶 key 7;換 SAE + net_root;wsl.24 = 前置 4 + 5;AP 密碼提示;審核時依使用者決定只提示不擋)。沒有新的缺口。

## 2. 正常與異常流程逐條走(對目前的規則)

| 流程 | 每一步依據 | 結果 |
|---|---|---|
| 第一次建網 | joinflow 不變;沒有 k13 → creator() 回落 k8(§2.1) | ✅ 完成 |
| 網主 join2 全新節點(v ≥ 2) | §2.0 入口 2(不在任何 removed → 照今天);join2 用 k7 / k8 / k5 / k6(目前版);節點 netJoin 不限版本(R15) | ✅ |
| 成員邀請 → 申請 → 同意 → 匯入 → 加入(v ≥ 2) | §3.6 `open_netcfg_current`;check_joinreq;同意用 k8/k5/k6、k10 = 目前;import 的 bind 以 pend netcfg(= 目前版)驗;隊員模式 network/join 送 mnet k3/k4/k5 | ✅ |
| 成員第二台節點,同一版內 | approve::import 同版路;A 是 applied → `existing()` Ok(None) → k7 = B;A 不在 k7、也不在 k10 → 依 §2.0 入口 3 暫時不是「網路裡的自己節點」,但它也不需要換;下一次的包帶 A、B 兩份 → k10 補上(T29) | ✅ |
| 成員第二台節點,同意包比 mnet 新一版 | +1 路:k9 帶、k10 清空(§2.2);之後補 k10 只看 removed(§3.4-6) | ✅ |
| 成員第二台節點,**同意包比 mnet 舊**(先匯入了更新包) | `existing()`:新版號 < 舊+1 → `SameVersionDifferent`(approve.rs:316);B 進不了 k7,隊員模式不能加入 | ❌ 沒定義 → MINOR-3 |
| 移除一個人 | §3.1 前置 → commit(唯一寫入)→ §3.3 產包 → §3.4 匯入 → §3.2 / §3.5 送 | ✅ |
| 第二次移除(第一次還沒全員換好) | §2.4 k9 ≤ v 且在 k13;start 從 k10 起含兩版(T20) | ✅ |
| 同一版本內重新邀請被移除的人 | check_joinreq:他的節點已從 k11 刪 → 不是 AlreadyMember;同意 k10 = 目前;匯入走 +1 路、2b 不沿用 me;隊員模式:節點已離開 → NotApplied → 以目前版加入;節點還在舊版 → 5 → §3.5 鏈接得上 → §3.2 送(入口 3:k7) | ✅(兩條都通) |
| 之後的版本才重新邀請 | §3.6-2 TooOld 取代(舊 admins 簽);2b;節點在舊版且歷代接不上 → 先離開(§3.5) | ✅ |
| 網主加回找回來的自己節點 | 入口 2 確認 → join2;節點被重設 → NotApplied → 以目前版加入 ✅;**節點還在舊版 → 回 5 → §3.5「導向按鈕 / 直接送」,但 k11 這一項要寫成什麼沒定義** | ⚠️ → MAJOR-1(c) |
| 網主排除最後一台,再加新節點 | §3.1 前置 3 允許;§2.4 可以開始;members key 4 可為空(CDDL `[* member]`);之後 join2 入口 2 直接過 | ✅ |
| 成員離開後再加入 | leave 不寫紀錄;隊員模式 k7 + k5(匯入更新包後已是目前版)→ NotApplied → 加入;mnet 落後時先加入舊版、之後按鈕 | ✅ |
| 網主 app 降級再升級 | T10;k13 只剩一項、缺 k10 = 目前版 | ⚠️ 產包清單與 start 公式互相矛盾 → MINOR-2 |
| 包弄丟 | k10 不推進 → 重產(T6/T8) | ✅ |
| 節點關機 | 狀態頁共用規則(T7/T7b) | ✅ |
| 開始時自己節點都連不上 | §2.4「可以開始」vs §5、T15「不開始」 | ⚠️ 矛盾 → MINOR-1 |
| 寫入中斷 | 網主單一 CAS(T2/T4);成員兩段 CAS(T22) | ✅ |
| 自己的節點在 joining 時被抓 | 前置 2 擋 → MAJOR-1(a) | ❌ |

## 3. MAJOR

### MAJOR-1 自己節點的「joining」項與 v5 規則之間沒有契約:加回的節點可能永遠卡在 joining,而 joining 會擋住所有之後的換密碼(含緊急排除)

三個互相咬住的點:

**(a) 前置 2 擋掉「排除一台 joining 的自己節點」。** §2.0 把「網主的網路裡的自己節點」定義為 k11 中 owner_pub = 自己的項「不論 joining / approved / applied」,§3.1 說自己那組每台都有「排除這台」,但前置 2 是「沒有 joining 的成員項」(沒有例外)。現場:網主正在加第二台,BLE 斷了(join2 停在 `Keep::Unclear`,join2flow.rs:705/711,k11 留 joining),節點隨後遺失 / 被抓。網主要排除它 → 前置 2 拒絕。唯一的出路是「忘記加入中」,但忘記會把它從 k11 刪掉,之後「排除這台」就沒有對象,而 v5 沒有「單純換密碼」的入口 —— 若它其實已經入網(Keep::Unclear 本來就是結果不明),就**沒有任何方法把它切出去**,直到下次有人要被移除。§3.6 忘記對話框那句「下次換密碼時它會被切出網路」在這情境是空頭支票。

**(b) 建立者(creator)永遠不能忘記。** bridge owner.rs:127 `if r.creator().ok() == Some(h) { return Err("建立網路的節點不能忘記") }`,不看 state;v5 §2.1 把 creator 固定成 k13 最舊一項的第一筆。情境(使用者決定的現場):網主一人一台,那台(= creator)被抓 → 排除最後一台 → 之後找回 → 入口 2 確認 → join2 中斷留下 joining。這時前置 2 擋住所有換密碼,而這一項又不能忘記 → **永久卡死**,只能重建網路。forget 對 creator 的保護原意只在 record pending 時有用(netrec.rs:331-334 註解:「confirm network」會把它升成 applied)。

**(c) join2 收到 5、節點版本較舊時,k11 寫成什麼沒定義。** 這是「加回找回來的節點」的**正常**路徑:被排除的節點沒被重設時仍在舊網路裡,network/join 回 5(node.go:1036-1037)。今天的程式在 info = Applied 時寫 applied(join2flow.rs:707)。§3.5 改成「不只看 join_state:k9 較舊 → 導向同一個按鈕;接得上 → 直接送」,T23 的負對照是「只看 join_state → 判『已加入』」—— 實作者很自然會把這條路改成不寫 applied。若 k11 留在 joining(PersistNet 在送之前已寫,join2flow.rs:412-416):§3.2 送出成功之後也不會改 k11(§3.2 沒有寫入),於是這台永遠 joining,下一次移除被前置 2 擋,而網主要麼忘記它(= 再被切出去),要麼它是 creator 就卡死(b)。

**修法(三個條件,不加機制)**:
1. 前置 2 改成「沒有 joining 的成員項(**本次排除的那一台除外**)」。
2. forget 對 creator 的保護只在 `state == pending` 時生效(或寫明 creator 只在 pending 時有意義,applied 之後不保護)。
3. §3.5 寫明 join2 回 5 時的紀錄:info = Applied(本網)→ **照今天寫 k11 applied**,然後 k9 = 手機版 → 結束;k9 較舊且接得上 → 同一個 session 接著做 §3.2(入口 1 此時一定過);接不上 → 句子「請先離開網路再加入」,k11 仍寫 applied(節點確實在本網)。隊員模式同理寫 mnet me applied。

**測試**:T27 加一臂「被排除的節點沒重設、回 5、k9 舊 → k11 = applied、update 送出 1 次;之後前置 2 通過」;負對照:回 5 時不寫 applied → 下一次移除被前置 2 擋。T26 加「creator 被排除 → 加回 → join2 中斷 → 可以忘記」;負對照:今天的 owner.rs:127 → 拒絕。T15 / 前置測試加「唯一的 joining 項就是排除對象 → 可以開始」;負對照:前置 2 不留例外 → 被擋。

## 4. MINOR

1. **m1 §2.4 與 §5、T15 對「自己節點都連不上」的行為相反。** §2.4:「網路裡還有自己節點但一台都連不上 … → 可以開始,對話框寫明…」(第 4 輪 A-m3 的修法)。§5「網主紀錄被還原成舊檔」那列仍寫「一台都連不上 → 不開始」,T15 也斷言「網路裡有自己節點但一台都連不上 → 不開始」。測試會把錯的那一邊固定下來。改 §5 那列與 T15(改成「可以開始、對話框有那句;負對照:不顯示那句」)。
2. **m2 降級再升級後的「只含目前版本一步」包,清單與 start 公式都產不出來。** §2.1:缺 k10 = k13 最舊一項 = 目前版本;§3.3 只列「k10 < 目前版本」的人 → 清單是空的;§2.3 start = max(k10 最小 + 1, …) = 目前 + 1 > 目前 → 鏈是空的。§2.3 那句「缺 k10 的成員 → 產只含目前版本一步的包」因此沒有入口(第 4 輪 A-m4 只改了 §2.3 的文字)。修法:k13 只有一項且目前版本 > 1 時,缺 k10 當作「目前版本 − 1」(只影響產包),§3.3 就會列出每個人、start = 目前版本;T10 加一臂。
3. **m3 成員第二台的同意包比 mnet 舊時(先匯入了更新包)沒有定義。** 情境:M 有 A(k7);網主在 v1 同意 B;網主移除別人 → v2;M 先貼更新包(A、B 的 v2 secrets 都進 k10),再貼 B 的同意包 → `existing()` 回 `SameVersionDifferent`(approve.rs:316,「同一號碼的另一個網路」句),B 不是 k7,隊員模式不能加入(join2flow.rs:339-341),§3.2-1 的 NotApplied 會「導向隊員模式」然後被 NotThisNode 拒。出路存在(網主重新邀請 B:check_joinreq 的 `replaces_approved`),但句子錯、順序沒寫。修法:同意包版本 < mnet 版本、且其 netcfg 與 mnet k9 同版號那一份逐 byte 相同 → 句子「這份同意已經過時,請網主重新邀請這台(…後 4 碼)」;§3.4 匯入成功畫面加「如果你還有沒匯入的同意,先匯入同意再匯入更新包」;§3.2-1 NotApplied 對非 k7 的節點直接給「請網主重新邀請這台」。測試:T21 加這一臂。
4. **m4 §5「被排除的自己節點回到 BLE 範圍 / 被重設」那列仍是 v4 的「不送、不 join」**,與 §2.0 入口 2(確認後 join)矛盾。第 4 輪 B-M1 明確要求改成「不送;只給『離開網路』;要加回 → join2 + 確認」,沒有改到。
5. **m5 正式版可以 commit 一個送不出去的版本。** §3.6 build 閘門:「排除自己的一台」所有 build 都有,k4 規則在正式版一律不通過。前置 4 只檢查連得上的自己節點 → 正式版下若自己的節點都連不上,可以開始、commit v+1,之後每台都「要先更新軟體」,紀錄永遠領先所有節點(新 join2 的節點卻會進新版 → 自己的節點彼此分裂)。最小修法:正式版的 k4 規則定下來之前,「排除自己的一台」也只在 dev-trust build(和「移除這個人」同一個閘門);T25 擴一臂。
6. **m6 入口 2 的位置寫成「PersistNet 之前」,但 join2 第一次 SignAdmin 在 PersistNet 之前**(join2flow.rs:329 `secrets_step` 在 `begin` 裡)。設計同時要求「按否 = 0 次 SignAdmin」,兩句合起來只有「在 `begin` 裡、`secrets_step` 之前」做得到;直接寫明,並寫出新的 Action(類似 `ConfirmCountry`)。T27 的負對照改成「放在第一次 SignAdmin 之後」(放在 PersistNet 之後的 mutant 本來就會被 0 次 SignAdmin 抓到)。
7. **m7 §3.4-4「mnet 有 k7 時包裡必須有 k7 那台」會把其他節點一起擋掉,沒有必要。** k7 是被網主忘記的 approved 項時(R18),整包被拒 → 這個人的其他節點(例如已入網的 A)也拿不到新密碼,等於被移除。拒絕的理由是 k5 要換成 k7 的新版;但 k5 舊了的後果只是隊員模式加入 k7 時被節點拒(E_BAD_OBJECT → join2 把 k7 拿掉 → 「需要新邀請」),不會漏東西。修法:照樣寫入包裡有的 secrets,k7 那台沒有時只顯示 A-m7 那句;T12 / T29 加一臂。
8. **m8 §3.2「k9 = 目前就足以判定」的理由沒有提紀錄回滾。** §6 已承認回滾可能不需要 root(allowBackup,⚠️ 未驗證);回滾後網主可能重簽同一版號(F18)。第 4 輪 B-m4 要求在 §3.2 的理由加「或紀錄被回滾(§6)」,沒有加。
9. **m9 測試缺口。** (i) 第 4 輪 A-m7:T13 要斷言 02 在轉交前 k9 = 1(證明分裂來自版本差,不是別的原因),沒有加。(ii) 第 4 輪 A-m1:k13 修剪後的缺口(33 版以上,start ≥ 連續段第一版)沒有測試臂;§2.1 的修剪規則與 §2.3 的 start 第三項是新規則,應進 T8b 與 mutation 清單。(iii) §2.4「告警指名是哪一台(後 4 碼)」、§3.6 SAS 畫面「之前被移出過 …後 4 碼」只有真機 T14,沒有 Rust 單元與負對照。
10. **m10 文字 / 證據小錯。** R8 的 `approve.rs:385-387` 實為 :383-384;§3.6 k4 規則沒有補第 4 輪 B-m3 要的前提句(wsl.N 單調、≥ 25 都從含 fbc01ae 的 feed 編;分支 build 可能打破,dev 才有的界線)。

## 5. 第 1–4 輪逐項確認(讀完自己的審查之後才讀)

| 項目 | v5 | 確認 |
|---|---|---|
| v4 A-BLOCKER-1 / B-M1 / B-M2 對象守則太寬 | §2.0 三個入口 | ✅ 三條路(重新邀請、加回、新節點)照程式重走都通(§2 表);入口 2 位置 → m6;§5 殘留列 → m4;加回的 k11 狀態 → MAJOR-1(c) |
| v4 A-M1 一人多台第一台換不了 | §2.2 +1 路清 k10、取用比版本;§3.4-6 只看 removed;T29 | ✅ |
| v4 A-m1 k13 缺口 | §2.1、§2.3 start 第三項 | ✅ 文字;測試 → m9(ii) |
| v4 A-m2 k9 不在 k13 | §2.4 不擋、由 §3.2 處理 | ✅ |
| v4 A-m3 連不上的不對稱 | §2.4 | ⚠️ §5 與 T15 沒跟著改 → m1 |
| v4 A-m4 「版本不明」空清單 | §2.3 一句 | ❌ §3.3 清單條件與 start 公式沒改,仍產不出來 → m2 |
| v4 A-m5 2b 與 PreviousNode | §3.6-2b | ✅ |
| v4 A-m6 匯入後自動送 | §3.4 不自動送;T30 | ✅ |
| v4 A-m7 負對照 | T26、T27 補了 | ⚠️ T13 的 k9 = 1 斷言沒加 → m9(i) |
| v4 A-m8 成員端定義 | §2.0 入口 3 | ✅ |
| v4 B-m1 §5 殘留「不產包」 | §5 T8b 列 | ✅ |
| v4 B-m2 128 KiB 解碼後 | §2.3 | ✅ |
| v4 B-m3 k4 正則 | §3.6 `\d+` + 超過 9 位不通過 | ✅;前提句 → m10 |
| v4 B-m4 allowBackup | §6、§9 | ⚠️ §3.2 的理由沒加回滾 → m8 |
| v4 B-m5 降級沒有守則 | §5 | ✅ |
| v4 B-m6 指名謊報 k9 的節點 | §2.4 | ✅;測試 → m9(iii) |
| v4 B-m7 removed 只增 | §2.5 | ✅ |
| v4 B-m8 共同擁有者 | §6 | ✅ |
| v4 B-m9 單一網主前置 | §3.1-1 | ✅ |
| v4 B-m10 工具位置 | §7 `app/tools/synth-joinreq/`,不進 app build | ✅ |
| v3 各項(A-M1…M5、A-m1…m11、B-B1、B-M1、B-m1…m10) | §12 表 | ✅ 抽查:k9 ≤ v(§2.4)、一律產包(§2.3)、InProgress(§3.2-1)、k11 長 true 句子、owner_pub ≠ 自己(§3.3)、2b、≥ 240 s、build 閘門(→ 見 m5)、creator 修剪保留最舊(→ 見 MAJOR-1(b))、敏感剪貼簿、wsl.24 降級列 |
| v2、v1 各項 | §10、§11 | ✅ 抽查仍在:k10 不推進、k12 標 used、secrets 要簽(§3.4-3)、偽造重新邀請要舊 admins 簽(§3.6-2)、commit 後不自動送(T19)、wsl.24 前置 5 |

## 6. 判定

0 BLOCKER / 1 MAJOR / 10 MINOR → **APPROVE-WITH-CHANGES**(MAJOR-1 修完即可凍結;依規則 MAJOR 未關前仍需整份重審,但修法只是三個條件句,重審範圍小)。

- **MAJOR-1**:前置 2 不算本次排除的那一台;creator 的 forget 保護只在 pending;§3.5 寫明 join2 / 隊員模式回 5 時照今天寫 applied、再接著送 update。附 T26 / T27 / 前置測試的正反臂。
- MINOR 1–10 都是改字、補一句或補測試臂,不加機制(m5 是把一個入口收進既有閘門)。
