# 254-app-remove-member.md v6.1 — 第 7 輪審查 B(安全優先,審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v6.1(445 行;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 `feat/254-p3` @ fbc01ae(NU v4.1,297 行)。全程唯讀,沒有碰裝置。先自己審完整份,最後才讀第 1–6 輪的報告(§5)。

**判定:APPROVE-WITH-CHANGES**,0 BLOCKER / 1 MAJOR / 9 MINOR。

v6.1 的改動(規則 4 放寬、狀態頁「沒有新密碼」那句、忘記導向)兩個方向我都照程式碼走過,都成立。唯一的 MAJOR 是新發現的,不是 v6.1 引入的:**產更新包的對象從哪裡來,設計沒有寫成契約,也沒有負對照**。這正是本單的核心性質(被移除的人拿不到新秘密),而 §3.3 的清單又明寫「存在記憶體」。修法是一句契約加一個測試。

## 0. 自己查的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| 網主簽章是 Keystore ECDSA P-256(DER → low-S raw),不是確定性簽章 → 回滾後重簽同一版會產生不同的 bytes,§3.4-2 的逐 byte 比對抓得到分叉 | ✅ | approve.rs:133-137 `sig::der_to_raw_low_s`;Keys.kt ADMIN_SIGN |
| `check_joinreq`:邀請必須在 k12 且未用;同一顆 DAC 已在 k11 → 只有「approved + 同一 owner_pub」能取代,否則 AlreadyMember;被排除的 DAC 已從 k11 刪掉 → 會走到同意 | ✅ | approve.rs:70-86 |
| 加入申請的 Sign1 用 payload 自己的 owner_pub 驗,sig_enc 由 owner 金鑰簽 owner_enc_pub → 別人不能冒用某人的 owner_pub 把節點塞進那一組;但 **owner_enc_pub 由申請者自選**(只要自己簽) | ✅ | approve.rs:39-57 |
| `ApproveFlow::begin` 的第一個動作就是 SignAdmin(net_secrets) | ✅ | approve.rs:116-130 |
| 遠端隊員的 k11 項只會是 approved(ApproveFlow 寫入),joining 只來自網主自己的 join2 | ✅ | approve.rs:164-182;join2flow.rs:298-330 |
| join2 網主模式 `begin` → `secrets_step`(SignAdmin)在任何寫入前 | ✅ | join2flow.rs:298-330、:357-370 |
| 隊員模式加入:k7 缺 → NoEntry;k5 的 target ≠ 這台或 k7 ≠ 這台 → NotThisNode | ✅ | join2flow.rs:333-342 |
| 同意包匯入的 +1 路:只驗 **netcfg** 由舊 admins 簽、prev_hash、net_id;**members 沒有驗 prev_hash 鏈** | ✅ | approve.rs:304-317(`existing`) |
| 同一版本貼第二台的同意包:me 是另一顆 DAC 且 applied → `Ok(None)` → k7 換成新那台 | ✅ | approve.rs:319-323 |
| `AlreadyImported` 比的是 secrets bytes == mnet k5 → 匯入更新包後再貼舊同意包 → NoRequest | ✅ | approve.rs:345-351 |
| `forget_joining`(netrec)與 bridge `net_forget_joining` 都接受 approved 項,**不看紀錄 state**;bridge 另有一份 creator 檢查 | ✅ | netrec.rs:335-347;bridge owner.rs:119-141 |
| `confirm()` 只把 creator 那一項升 applied,用的是傳進來那台的 info | ✅ | netrec.rs:307-329 |
| `NetRecord`(含 sae / net_root)**derive Debug**;`invite::Action::Persist { plain }`(整份紀錄明文)derive Debug | ✅(既有) | joinflow.rs:54-64;invite.rs `#[derive(Debug, PartialEq)] pub enum Action` |
| dev-trust 是編譯期常數;bridge 只對 `rust/bridge` 這個 package 建置;app/rust 沒有 workspace Cargo.toml;`app/tools/` 還不存在 | ✅ | nodecert.rs:140-150;bridge/Cargo.toml:10-11;rust_builder/*/CMakeLists(manifestDir = rust/bridge) |
| test-all.sh 以 `cargo tree -e features,no-dev` 斷言 release 樹沒有 dev-trust / test-vectors | ✅ | batman-proto/test-all.sh:26-28 |
| Manifest 沒有 allowBackup;minSdk 31 | ✅ | AndroidManifest.xml;build.gradle.kts:24 |
| 複製走 Flutter `Clipboard.setData`;貼上時 `_takeClipboard` 清空 | ✅ | lib/nodes.dart:604-606、:652 |
| store 沒有大小上限、不偵測回滾 | ✅ | store.rs |
| 219 §7.5 原意是「網主把各成員節點最新的 net_secrets 同步給**所有**成員 app」;v6.1 只給本人那幾台(更嚴),§9 會補 219 | ✅ | 219-protocol.md:357 |
| NU §3 交給 app:「網路裡還有 wsl.24 節點時不得開始移除」;app 以前置 5 的勾選承接(app 看不到別人的節點) | ✅ | NU:123;設計 §3.1-5 |
| NU §3 建議用新 psk_member 握手判斷 update 結果;app 以「擁有者連線 pin DAC + 只有一位網主 + 同版只簽一次」改用 info k9,理由寫在 §3.2 | ✅(理由成立;F10 污染的殘留已寫成誠實界線) | NU:112、:241;設計 §3.2 |

## 1. MAJOR

### M1 更新包的收件對象沒有契約:「這個人」若已不在 k11(被移除了),產包必須拒絕;設計沒寫,也沒有負對照

**情境**
1. 網主做第一次移除(v → v+1),進 §3.3 產包畫面。畫面列出 Bob、Carol…「這次已複製 / 未複製」**存在記憶體**(§3.3)。
2. 網主決定連 Carol 也要移除:從成員名單「移除這個人」(第二次移除不必等第一次結束,§2.1),commit v+2,Carol 的項從 k11 刪掉。
3. 若畫面或 bridge 的「產包」入口吃的是畫面上保存的那個人(owner_pub / owner_enc_pub / 節點清單),而不是**在產包當下從目前紀錄重新取**,那麼按到舊畫面上的 Carol 就會產出 v+2 的 member_secrets(新 net_root)給 Carol。
4. 另一條同樣的路:§3.6 的確認框要顯示「之前的擁有者」,實作會有一個「從 k13 歷代找某人資料」的函式;若產包對 k11 找不到的人退回去用歷代裡的 owner_enc_pub,結果一樣。

**後果**:新 net_root → 新版 psk_member(F20)。拿不到 SAE(進不了 HaLow mesh),但能和已換到新版的節點建立成員連線(R32:成員角色能送 network/update 等)。這正是目標「被移除的人拿不到新秘密」的反面,而且是**沒有網主明確同意**的。

**證據**:設計 §2.3「3: 給這個人在 k11 的每一台節點各一份」「4: 給這個人的 owner_enc_pub」—— 第 4 項沒說 owner_enc_pub 從哪裡取;§3.3「按一位 → 產 §2.3 的包」、「已複製」存在記憶體;§2.1 第二次移除可以隨時做。§7 的 T11 只測「被移除者拿到**別人的**包 → 解不開」,T1 只測 members 的內容;沒有任何測試斷言「commit 後對被移除的人產包 → 拒絕」。前 6 輪的報告也沒有提這一點(我讀完後確認)。

**修法(一句契約 + 一個測試,不加機制)**
- §2.3 加:產包的入口只收 owner_pub;在產包那一刻**從目前紀錄的 k11** 取這個 owner_pub 的所有項(net_secrets 的 ecdh_pub、member_secrets 的 owner_enc_pub 都只從這些項取);**一項都沒有 → 拒絕,0 次 SignAdmin**;owner_pub = 自己 → 拒絕。
- T 新增(或併入 T11):commit 移除 X 之後,以 X 的 owner_pub 呼叫產包 → Refused、0 次 SignAdmin;負對照:改成用快取 / 歷代裡的 X → 產出 member_secrets。第二臂:在 §3.3 畫面開著時做第二次移除,再按舊畫面上的那個人 → 拒絕。

## 2. MINOR

1. **狀態頁「這支手機沒有它的新密碼」那句在網主手機上會說錯話。** §3.5 第一點的條件(擁有、info k10 = 本網、版本落後、手機沒有它的目前版 secrets)沒有限定成員端。網主手機上,被排除、但仍在 `node/` 的自己節點(找回來還沒重設)正好符合,畫面會叫網主「請網主重新產生你的更新包」。對網主應顯示入口 1 那句(「已被排除…只能『離開網路』;要加回請用『加入網路』」)。第 6 輪 A-m11 的殘留(從沒在 k11 / 被忘記的自己節點也被說成「已被排除」)一併:入口 1 的句子改成「這台不在隊伍網路的名單裡(可能已被排除或被忘記)」。修法:§3.5 第一點寫明「成員手機」;網主手機對不在 k11 的自己節點用入口 1 的句子。T37 加網主端一臂。
2. **入口 2 的確認也要是 Rust 參數。** 同意那邊已寫成 `ApproveFlow::start` 的參數(B-m2),入口 2 只寫「begin 階段查」。為了同一個等級(Dart 漏掉對話框也不會出事),§2.0 入口 2 寫明:join2 `begin` 收一個「網主已確認」參數;目標在 removed 而參數沒給 → Refused、0 次 SignAdmin、0 次寫入。T27(2) 的負對照改成「不傳參數 → 0 次 SignAdmin」。
3. **忘記導向只在畫面上;Rust 仍接受。** `net_forget_joining` / `forget_joining` 對 applied 紀錄裡的 approved 項照樣刪(netrec.rs:335-347;owner.rs:119-141)。舊畫面路徑、之後的改版或測試工具都能繞過 v6.1 的導向,而被忘記的人就再也無法「移除這個人」(第 6 輪 B-MAJOR 的情境)。修法:在 Rust 拒絕「紀錄 applied 時忘記 approved 項」(一行條件),T39 改在 bridge 層測,負對照 = 拿掉條件 → 刪得掉。
4. **兩台以上自己的節點卡在 joining(都被抓)時,只能排除一台;另一台得先「忘記」,於是失去 removed 的保護。** 前置 2 的例外是「本次要排除的**那一台**」。A、B 都是 joining:排除 A 時 B 擋住前置 2,只好忘記 B;B 不進 removed,之後拿 B 來 join2 或用 B 的 DAC 申請都不會跳確認框(§3.6 已承認「已忘記的」是誠實界線,但這裡是設計把網主逼進去的)。修法(最小):「排除自己的節點」允許一次勾選多台,前置 2 的例外 = 本次排除對象的集合(§2.4 的「不含這次要排除的那台」也改成集合)。若不改,至少在忘記對話框寫「忘記不會把它列入排除名單;若它是被抓的節點,請改用『排除這台』,一次一台」,並在 §6 寫明。
5. **TooOld 取代會在合法情境觸發,讓那個人的第一台節點擱淺。** 成員 mnet 在 v、網主已換到 v+2、網主同意他的第二台 B → B 的同意包對 mnet 是 TooOld → §3.6-2 的「要換成新的嗎?」→ 按是:k9 只剩 v+2、k10 清空、k7 = B。接著貼更新包(含 A):「已經匯入過」分支補進 A 的 secrets,但 A 在 v,鏈需要 v+1,而歷代已沒有 → §3.2「落後太多版,離開再加入」,而 A 不是 k7 → 隊員模式不能重新加入 → 要網主重新邀請 A。若順序反過來(先貼更新包到 v+2,再貼同意包 = 同版)就全部正常。修法:TooOld 對話框加一句「如果網主也給了你更新包,請先貼更新包,再貼這份同意」,並把 §3.6-2 的說明從「重新邀請被移除的人」擴大成「任何落後 ≥ 2 版的同意包」。T17 加一臂。
6. **同一個 owner_pub 的各項 owner_enc_pub 不同時沒有定義。** owner_enc_pub 由申請者自選(approve.rs:39-57,只要 owner 自己簽),所以同一組裡可能有兩個值(例如成員 app 換過加密金鑰)。§2.3 的「這個人的 owner_enc_pub」是哪一個?修法:同一組的 owner_enc_pub 不一致 → 不產包並說明(fail-closed),或明定取最新同意的那一項;併入 M1 的契約句。
7. **秘密衛生要涵蓋流程的 Action,不只「新結構」。** 換密碼流程的寫入會把含新 SAE / net_root 的整份紀錄明文放進 Persist 動作;今天的 `invite::Action::Persist { plain }` 與 `joinflow::NetRecord` 都 derive Debug(joinflow.rs:54)。任何 `{:?}`(panic 訊息、錯誤路徑、日誌)都會把新秘密印出。§6 的「新結構不 derive Debug」改成「換密碼流程與產包流程的 Action / 中間結構都不 derive Debug(或明文包在自訂 Debug 只印長度的型別裡)」;T24 加一臂:流程每一步的 Action 經 `format!("{:?}")` 後不含 SAE / net_root 的 hex。
8. **合成第三人工具的兩點沒寫進正文(第 6 輪 B-m6 (e))。** 工具不可以和 bridge / batman-proto 放進同一個 Cargo workspace(避免 feature 統一把 dev-trust 帶進 bridge);依賴 batman-proto 時不得開 `dev-trust` / `test-vectors`(它不需要)。現在 app/rust 不是 workspace,所以今天沒事;寫一句,並讓 test-all.sh 的 release feature 樹檢查維持只對 bridge 跑。
9. **同意包 +1 路寫進 mnet k9 的 members 沒驗鏈。** §2.2 讓 +1 路「k9 帶過去並加上新的 k3 / k4」;但 `existing()` 只驗 netcfg 的 prev_hash,members 的 prev_hash / 簽章版本沒驗(approve.rs:304-317)。之後 §3.4-2 拿 k9 裡的 members 逐 byte 比對、§3.2 拿它組鏈送節點(節點只驗簽章與 net_id / 版本)。都是網主簽的,不會漏秘密;但歷代裡會有一筆沒驗過鏈的物件。修法:+1 路寫進 k9 之前,用與 §3.4-2 相同的 members 規則驗(prev_hash = 舊 k4 的 OBJECT_HASH、net_id / version);T28 加負對照。

## 3. 依角色的結論(兩個方向)

| 角色 | 漏秘密? | 擋合法流程 / 擋換密碼? |
|---|---|---|
| 被移除的人 | ✅ 不漏,前提是 M1 的契約:包只加密給 k11 裡的節點 ecdh_pub 與 owner_enc_pub;偽造的鏈 / 重新邀請要網主簽、TooOld 取代要舊 admins 簽;邀請在 commit 時全標 used;重新邀請要網主新邀請 + 確認框 | ✅ 擋不了:§2.4 只查網主自己的節點;他的舊 psk_member 只能對還在舊版的節點開成員連線,送不出網主簽的新鏈;提早切換別人的節點(R32)只影響時機,已寫成誠實界線 |
| 被抓的節點(含網主自己的,有 DAC 私鑰 + owner TagKey、會謊報 info) | ✅ 入口 1 以 k11 為準;入口 2 / 同意在第一次 SignAdmin 之前確認(入口 2 要寫成 Rust 參數 → m2);拿它的 DAC 申請 → 確認框顯示之前的擁有者 | ✅ 謊報 k4:開始時不查;謊報 k9:目標本身不算,多台互擋 → 關藍牙(已寫);Unknown / 限速 = 連不上(已寫);卡在 joining:前置 2 例外,但多台 joining → m4 |
| 其他留下的成員 | ✅ 包只對自己的金鑰;同意包綁 mpend;CAS | 提早切換、串通 → 誠實界線(已寫);TooOld 順序 → m5 |
| 剪貼簿 / 惡意 app | ✅ 沒有明文秘密(SAE / net_root 都在加密裡);名冊外露已寫;EXTRA_IS_SENSITIVE 的 API 範圍已寫 | 換成別的包 → 拒絕或「已經匯入過」(只是 DoS) |
| 被攻陷的 OS / 網主手機遺失 | 與今天相同(ADMIN_SIGN 無使用者驗證)→ 誠實界線 + §9 | — |
| 成員手機遺失 | 移除那個人 ✅;v6.1 的忘記導向讓「被忘記」不再發生(m3:要在 Rust 擋) | — |
| 我們自己的錯 | 送錯 DAC ✅;同版只簽一次 ✅(ECDSA 隨機,重簽可偵測);k4 fail-closed ✅;回滾:allowBackup=false + run-as 界線 ✅;降級 ✅(已寫界線);測試路徑:dev-trust 編譯期閘門 ✅、工具 → m8;**產包對象 → M1**;Debug → m7 | 狀態頁句子 → m1 |

v6.1 的改動逐項:

| 改動 | 結論 |
|---|---|
| 規則 4:只有版本前進時要求 k7 | ✅ 「已經匯入過」分支仍跑規則 3(網主簽、net_id / 版本 = 目前)、5、6,而且鏈必須全部逐 byte 相同;能補進 k10 的只有網主為這支手機擁有的節點加密的目前版 secrets。沒有新的漏洞 |
| 狀態頁「這支手機沒有它的新密碼」 | ✅ 只顯示、不放寬送出;網主端的句子 → m1 |
| 「忘記」導向 | ✅ 方向對(approved 項已拿到目前秘密,只有換密碼能撤銷;`replaces_approved` 讓重新同意不需要先忘記);要在 Rust 擋 → m3 |

## 4. 生命週期補查

| 路徑 | 結論 |
|---|---|
| 首次 / 第一次換密碼 | T3 ✅ |
| commit 前失敗 / commit 後被殺 / CAS 交錯(approve、invite、join2 與 commit 互搶) | ✅ 全部是同一份紀錄的 CAS:先寫者贏,後寫者什麼都沒送出(approve.rs:182、join2 PersistNet 在送之前);T2、T4、T22 |
| 第二次移除時舊的產包畫面 | ❌ 沒定義 → **M1** |
| 重開 / 節點晚開機 | T7、T7b ✅ |
| 升級 / 降級 / 再升級 | T10、§2.3 一步包 ✅ |
| 斷電 / 斷線 / 回應遺失 | 讀 info 判斷;T5 ✅ |
| 依賴重啟(Keystore) | T2 ✅ |
| 多台自己的節點同時卡 joining | ⚠️ → m4 |
| 平台 | 只有 Android(已寫) |

## 5. 第 1–6 輪逐項確認(讀完自己的審查之後才讀)

| 項目 | v6.1 | 確認 |
|---|---|---|
| v6 A-MAJOR-1 第二台同意包先貼、更新包後貼 | §3.4-4 只在版本前進時要 k7;句子改「重新產生你的更新包」;狀態頁那句;T37 | ✅ 照 approve.rs:319-323 重走:+1 路 k7 換成 B、k10 清空 → 貼更新包走「已經匯入過」→ 補進 A。成立 |
| v6 B-MAJOR 被忘記的項無法換密碼切掉 | §3.6 忘記導向;已忘記的寫成誠實界線;T39 | ✅ 文字;只在畫面上 → m3 |
| v6 A-m1 §0-2 自動送 | §0「做」第 2 點已改 | ✅ |
| v6 A-m2 §5 降級列 / §2.1 定義 | §5、§2.3、§3.3 一致;§2.1 的定義仍沒有降級條件(§3.3 有) | ⚠️ 小殘留,不影響(以 §3.3 為準) |
| v6 A-m3 T14 判別力 | §7 T14 改寫 | ✅ |
| v6 A-m4 mnet 沒有 k9 的 +1 路 | §2.2 | ✅ |
| v6 A-m5 比 mnet 舊的包 | §3.4「已忽略」 | ✅ |
| v6 A-m6 「重新同意」做不到 | 改「重新邀請」 | ✅ |
| v6 A-m7 / B-m6 合成工具 | §7 改寫(吃邀請、私鑰不落地、閘門只有 app 端) | ✅;workspace 一句 → m8 |
| v6 A-m8 §2.4 逐台、離開的不算 | §2.4 | ✅ |
| v6 A-m9 測試缺口 | T38 | ✅ |
| v6 A-m10 k9 三義 | §2.0 用語 | ✅(正文仍有幾處寫「k9」指 info k9,但 §2.0 已定義) |
| v6 A-m11 引用 / 入口 1 句子 | R10、R30 已改;入口 1 句子未改 | ⚠️ → m1 |
| v6 B-m1 多台謊報、Unknown 算連不上 | §2.4 | ✅ |
| v6 B-m2 確認由 Rust 強制 | 同意端 ✅;入口 2 未明寫 | ⚠️ → m2 |
| v6 B-m3 確認框顯示之前的擁有者 | §3.6 | ✅(歷代修剪後可能找不到之前的擁有者 → 顯示「不明」即可) |
| v6 B-m4 第二組 owner_pub | §3.1 | ✅ |
| v6 B-m5 run-as | §6 | ✅ |
| v6 B-m7 mnet 沒有 k7 的 k5 | §2.2 | ✅ |
| v6 B-m8 EXTRA_IS_SENSITIVE API 33 | §6 | ✅ |
| v6 B-m9 / m10 測試與文字 | T38、§1 排序 | ✅ |
| v1–v5 各項 | §10–§14 | ✅ 抽查正文仍在:三個入口(§2.0)、k10 不推進、k12 標 used、secrets 要簽(§3.4-3)、TooOld 取代要舊 admins 簽、2b 先於 PreviousNode、+1 路清 k10、commit 後 / 匯入後不自動送(T19 / T30)、start 公式與一律產包、128 KiB 以解碼後計、k4 正則、前置 5、開始時不查 k4(T33)、前置 2 例外(T32)、≥ 240 s 鄰居觀察、allowBackup=false(T31) |

## 6. 判定

0 BLOCKER / 1 MAJOR / 9 MINOR → **APPROVE-WITH-CHANGES**。

- **M1**:§2.3 寫明產包當下從目前 k11 取收件人,一項都沒有 / 是自己 → 拒絕、0 次 SignAdmin;加負對照(含「第二次移除後按舊畫面上的人」)。
- MINOR 1–9 都是改字、補一句、把確認寫成 Rust 參數或補測試臂;m4 若要改成「一次排除多台」是唯一碰到流程的,也可以只補說明。
- 依規則 M1 關掉前仍要整份重審;修法只動 §2.3 一句與 §7 一個測試,重審範圍小。
