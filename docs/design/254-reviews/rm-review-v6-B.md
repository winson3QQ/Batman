# 254-app-remove-member.md v6 — 第 6 輪審查 B(安全優先,審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v6(412 行,untracked;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 `feat/254-p3` @ fbc01ae(NU v4.1)。全程唯讀,沒有碰裝置。我先自己審完整份,最後才讀第 1–5 輪的十份報告(§5)。

**判定:APPROVE-WITH-CHANGES**,0 BLOCKER / 1 MAJOR / 10 MINOR。

§2.0 的三個入口,以及 v6 的每一項改動,兩個方向我都照程式碼走過:
- **會不會漏秘密**:被排除或被抓的節點、被移除的人,在網主沒有明確說「是」的情況下,我找不到任何一條路能拿到新的 SAE / net_root。
- **會不會擋掉合法流程**:新節點、同一版本內重新邀請、加回(重設過 / 沒重設回 5)、一人多台、排除最後一台、排除卡在 joining 的那台,都走得通。

唯一的 MAJOR 不是新機制的洞,而是既有的「忘記已同意 / 加入中」和本單互相咬住:**被忘記的項,之後沒有任何直接的方法把它換密碼切掉**。修法只改畫面上的路由,不加機制。

## 0. 自己查的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| dev-trust 是編譯期常數;bridge 的入口用 `#[cfg(feature="dev-trust")]` / `dev_gate()` 擋;feature 名稱是 **`dev-trust`**(沒有叫 `dev` 的 feature) | ✅ | batman-proto/Cargo.toml:12-19;bridge/Cargo.toml:9-11;nodecert.rs:40-42;bridge owner.rs:1020 `dev_gate()` |
| app/rust 不是 Cargo workspace(batman-proto、bridge 各自是 package)→ 另一個工具 package 開 dev-trust 不會因 feature 統一而汙染 bridge | ✅ | app/rust 下沒有 workspace Cargo.toml;`app/tools/` 目前不存在 |
| batman-proto 只有驗證 X.509 的程式碼(x509-cert 沒開 builder);node_cert 的測試資料是節點產的 fixture → 合成工具得自己寫憑證 / 加入申請的產生器 | ✅ | Cargo.toml:31;tests/vectors.rs:310、:342 |
| `check_joinreq`:k11 已有同一個 DAC → 只有「approved 且同一位 owner」才能取代;被排除的 DAC 已從 k11 刪掉 → 會走到同意畫面 | ✅ | approve.rs:69-86 |
| ApproveFlow 的第一個動作就是 SignAdmin(net_secrets),所以「之前被移出過」的確認框必須在 `ApproveFlow::start` 之前 | ✅ | approve.rs:116-130 |
| 同意包的 members = k8 原樣,不重簽 → 符合「同版只簽一次」 | ✅ | approve.rs:156-157 |
| join2 網主模式:`begin` → `secrets_step` → SignAdmin → settings/get → `persist_joining` → 送 | ✅ | join2flow.rs:297-330、:357-370、:593-604 |
| join2 收到 5 → 讀 info → `Applied` 就寫 k11 applied;Unknown → `Keep::Unclear`(項目留在 joining) | ✅ | join2flow.rs:693、:700-712 |
| 節點 netJoin:已在網路裡 → 5;netJoin 以 netcfg 自己的 admins 驗、版本不限;netUpdate 不讀 removed | ✅ | node.go:1035-1052、:1083-1170 |
| member 角色可以送 network/update | ✅ | provd/session.go:79-80 |
| `creator()` = k8 第一筆;bridge 的 forget 一律拒絕 creator(不看 state) | ✅ | netrec.rs:281-283;bridge owner.rs:127-129 |
| `forget_joining` 能刪 joining 和 **approved**(不能刪 applied);刪掉的項**不會進任何 removed** | ✅ | netrec.rs:335-347;bridge owner.rs:131-140 |
| `confirm()` 會把 creator 的項升成 applied,但它用的是**目前登入那台**的 info,不檢查登入的就是 creator(既有行為) | ✅ | netrec.rs:307-329;bridge owner.rs:770-785 |
| ADMIN_SIGN 不需要使用者驗證;只簽 5 種標籤;本單不需要新標籤 | ✅ | Keys.kt:91-100;SignAllowList.kt:11、:25 |
| Kotlin ECDH 把 z 回傳給 Dart(既有做法) | ✅ | MainActivity.kt:78-85 |
| Manifest 沒有 allowBackup;release build 用 debug 簽章;dev / dev2 / field 三個 flavor | ✅ | AndroidManifest.xml;app/build.gradle.kts:31-58 |
| 複製都走 Flutter `Clipboard.setData`(設不了 EXTRA_IS_SENSITIVE);貼上時 `_takeClipboard` 會清空剪貼簿 | ✅ | lib/nodes.dart:604-606、:652 |
| store 不偵測回滾;沒有大小上限 | ✅ | store.rs:1-11 |
| 219-protocol.cddl 的 qr-kind 只有 1(kind 2 / 3 也還沒進 CDDL);members 的 key 5 = removed | ✅ | 219-protocol.cddl:334-337、:400-404 |

## 1. MAJOR

### M1 被「忘記」的已同意項 / 加入中項,之後沒有任何直接的方法換密碼把它切掉;v6 的「下次換密碼時它會被切出網路」在這種情況沒有人能觸發

**情境 A(遠端隊員,現場最常見)**
1. 網主同意 Carol。k11 加一筆 approved(approve.rs:164-182)。Carol 匯入同意包,用隊員模式加入,她的節點拿到目前版本的 SAE / net_root。
2. **網主這邊 Carol 那一項永遠停在 approved**:沒有任何流程會把遠端隊員的項改成 applied,網主也看不到她是否入網(§0「不做」最後幾項)。
3. 所以每一位遠端隊員的項上,永遠都有「忘記已同意的項」可以按(R18;owner.rs:131 只拒絕 applied)。網主整理清單時按了,v6 的對話框也只說「下次換密碼時它會被切出網路」。
4. 之後 Carol 的手機遺失,或她變成要被移除的人。§3.1 的成員名單以 k11 分組,**Carol 已經不在 k11** → 沒有「移除這個人」可以按。§3.1 只有「移除別人」和「排除自己的一台」兩個入口,v2 之後也沒有「單純換密碼」。Carol 手上的密碼一直有效。
5. 唯一的繞路:網主排除自己的一台(或隨便移除另一個人)來硬換一次密碼,之後再用入口 2 的確認框把自己那台加回。現場不會有人想得到,而且網主沒有自己的節點、也沒有別人可以移除時,這條繞路也不存在。

**情境 B(網主自己的節點)**
自己的 join2 停在 `Keep::Unclear`(join2flow.rs:711),k11 留 joining,但 network/join 其實已經送出,節點可能已經入網。網主按了「忘記加入中」(非 creator,或 v6 起 applied 紀錄裡的 creator 也可以忘記),之後這台遺失 / 被抓。v6 的前置 2 例外救的是「還在 k11 的 joining 項」;**已經忘記的就沒有「排除這台」可以按**(§2.0 的定義是「k11 中的項」)。同時它也從來沒進 removed,所以以後被拿來 join2、或拿它的 DAC 送加入申請時,都不會跳「之前被移出過」的確認框。第 5 輪 B 建議在忘記對話框加「如果這台遺失 / 被抓,請改用『排除這台』」,v6 沒有採用。

**為什麼是 MAJOR**
- 目標是「被移除的人拿不到新密碼,而且沒有人能擋住緊急換密碼」。這裡是**網主自己沒辦法發起**對那個人的換密碼。
- 觸發的是一個今天就有、而且每位遠端隊員身上都看得到的按鈕,再加上一句聽起來像保證的對話框。
- 這不是攻擊者造成的,是「我們自己的錯」那一類:介面讓網主以為忘記就沒事了。

**證據**:netrec.rs:335-347(approved 可以忘記、不進 removed);bridge owner.rs:131-140(對話框的句子);approve.rs:164-182(遠端隊員只會是 approved);設計 §3.1(入口只有「移除這個人」「排除這台」,都以 k11 為準)、§3.6(忘記對話框那一句)、§2.0(自己節點 = k11)。

**修法(只改畫面上的路由,不加紀錄欄位)**
1. 紀錄是 applied 時,approved 項的「忘記」改成走「移除這個人」(§3.1 的同一個流程:它本來就處理 approved)。`check_joinreq` 的 `replaces_approved` 已經涵蓋「重新同意同一台」,所以重新同意不需要先忘記(approve.rs:78-80)。若一定要保留「只忘記」,對話框改成兩個按鈕:「移除並換密碼(他已拿到的密碼會失效)」/「只從清單拿掉(他已拿到的密碼仍有效,之後無法從這支手機移除他)」。
2. 自己的 joining 項:忘記對話框加第 5 輪 B 那一句,並給「排除這台」按鈕(走 v6 的前置 2 例外)。
3. 已經被忘記的情況寫進 §6 的誠實界線,附上繞路(排除自己的一台,再用入口 2 加回)。

**測試**
- (a) 紀錄 applied 時,approved 項的介面沒有「只忘記」,或必須明確選第二個按鈕;選「移除並換密碼」→ 走 §3.1,v+1 的 removed 有它、它不在 key 4。負對照:照 v6 → 忘記之後名單沒有這個人,移除入口 0 個。
- (b) joining 的自己節點:忘記對話框有「排除這台」,按下 → T32 那條路。

## 2. MINOR

1. **兩台以上被抓的自己節點謊報 k9 > v,會互相擋住;開始時讀不到 info / 逾時沒有定義。** §2.4 的出路是「先排除那一台」,但檢查只扣掉本次目標。A、B 兩台都在 BLE 範圍內謊報:排除 A 時 B 擋,排除 B 時 A 擋。關掉藍牙可以脫困(§2.4「一台都連不上 → 可以開始」),但設計沒寫,現場不會有人想到。另外,攻擊者讓 info 一直回 Unknown / E_RATE,或讓握手一直不結束,算不算「連不上」也沒寫。
   修法:§2.4 寫明「Unknown / 限速 / 握手逾時(固定秒數)= 連不上,不擋」;k9 > v 的告警要給出路「這台可能被抓 → 關掉藍牙後再開始,或先排除這台」。測試:T15 加「Unknown → 可以開始」一臂。
2. **重新同意一個「之前被移出過」的 DAC 時,確認框要由 Rust 強制,而且沒有負對照。** ApproveFlow 的第一個動作就是 SignAdmin(approve.rs:116-130),確認框必須在 `start` 之前。建議把「網主已確認」當成 `ApproveFlow::start` 的參數:是 removed 的 DAC、參數又沒給 → Refused,0 次 SignAdmin。這樣 Dart 漏掉確認框也不會出事,和入口 2 的「0 次 SignAdmin」同一個等級。T27 只測了 join2 那一邊,要補:removed 的 DAC → 確認框;按否 → 0 次 SignAdmin、紀錄不變;負對照:拿掉檢查 → 同意包產出。
3. **確認框要說明這台之前是誰的。** 被移除的人 P 若拿到網主的新邀請(網主決定重新邀請他),他可以用自己抓到的「網主的被排除節點 X」的 DAC 送加入申請。確認框只寫「之前被移出過 …〈後 4 碼〉」,網主很可能當成 P 自己的舊節點而按是。k13 / members 的歷代裡有那一項的 owner_pub,所以可以比對:之前的 owner_pub ≠ 這次申請的 owner_pub(尤其之前是網主自己)→ 加一句「這台之前是〈你自己 / 別人〉的節點」。不會漏出網主沒同意的東西(網主本來就要讓 P 回來),但能防止網主看錯。
4. **同一個人的第二組身分。** 「一個人」= owner_pub。重裝 app 或換手機之後,同一個人會出現成兩組(第 1 輪 B-m10;§11 寫「換手機 = 兩組(寫進說明)」,正文 §3.1 沒有寫)。網主移除「Bob」那一組,另一組「Bob」照樣會拿到更新包。修法:確認對話框若發現有別的組名稱相同,列出來並提示「要一起移除嗎?」。
5. **allowBackup=false 關不掉 debuggable build 的 `run-as`;T31 只是存在檢查。** dev flavor 的 debug build 用 `adb shell run-as <pkg>` 就能讀寫 app 私有目錄,把封存紀錄換回舊檔,不需要 root,也不靠 backup。§6 的「本 PR 設 allowBackup=false」要補一句:「只關掉 adb backup;debuggable build 仍可經 run-as 回滾(dev 機的誠實界線)」。依通用規則,存在檢查不算測試:T31 至少改成對合併後的 manifest(aapt dump)斷言;最好在 dev debug build 上跑 `adb backup` 後斷言備份裡沒有 app data。
6. **合成第三人工具的說法要修正。**
   - (a) feature 叫 `dev-trust`,不是「dev feature」。
   - (b) 工具端的編譯閘門保護不了任何東西:任何人都能自己寫出同樣的工具。真正的閘門只有 app 的 `DEV_TRUST`(nodecert.rs:139-150)。「兩道編譯期閘門」要改寫成「一道安全閘門 + 一道防誤用」。
   - (c) 憑證 / 加入申請的產生器寫在工具裡,不要加進 batman-proto(batman-proto 會被編進 app)。
   - (d) 工具產的 owner / owner_enc 私鑰不寫進專案目錄,用完就丟。它解得開第三人那份 member_secrets,也就是 v1 的 net_root。
   - (e) 工具不可以和 bridge 放進同一個 Cargo workspace,避免 feature 統一。
7. **mnet 沒有 k7 時,k5 要寫成什麼沒有定義。** §2.2 / §3.4 第二段都寫「k5 = k7 那台的新 secrets」。§3.4-4 允許 mnet 沒有 k7(只要包裡至少有一份配到自己的節點),這時 k5 是留舊版、清空、還是取第一台?今天隊員模式沒有 k7 會回 NoEntry(join2flow.rs:336),所以不會漏東西,但要寫明:「沒有 k7 → k5 不動」。
8. **EXTRA_IS_SENSITIVE 只在 API 33 以上有效。** minSdk 是 31(build.gradle.kts:24),Android 12 / 12L 上旗標不起作用。包裡沒有明文秘密,所以只要在 §3.3 寫明「API 31–32 沒有這個標記」就好,T36 依 API 分兩臂。
9. **測試缺口。**
   - (i) T27(2) 的負對照仍是「入口 2 放在 PersistNet 之後」。第 5 輪 A-m6 要求改成「放在第一次 SignAdmin 之後」,斷言 SignAdmin 0 次、settings/set 0 次;放在 PersistNet 之後的 mutant 本來就會被「0 次 SignAdmin」抓到,抓不到「放在第 2 步與第 4 步之間」。
   - (ii) 目標節點自己謊報 k9 > v → 排除照樣可以開始(§2.4 的「不含這次要排除的那台」)。T33 只測了 k4,這一臂沒有測試。
   - (iii) 建立者被排除後,`creator()` 仍回 k13 最舊一項的建立者,而 `confirm()` 會用任何一台的 info 把同 DAC 的 joining 項升成 applied(netrec.rs:316-322)。要加一臂:加回中斷留下 joining 的建立者 → 在別台按「確認網路」→ 不應因此變成 applied。或者寫明這是既有行為:它只影響畫面和前置 2,不影響秘密,因為入口 1 本來就允許 k11 裡的項。
10. **文字。** §1 的 R31 / R32 排在 R30 前面;R31 沒有行號(join2flow.rs:693、:707;bridge owner.rs:127)。§0 寫「kind 4 與剪貼簿只在 dev-trust build(同邀請,invite.rs:12)」,但 invite.rs:12 只是註解,真正的閘門在 bridge(owner.rs:1020 `dev_gate()`、member.rs 的 cfg)。

## 3. 依角色的結論(v6 每項改動,兩個方向)

| 角色 | 漏秘密? | 擋合法流程 / 擋換密碼? |
|---|---|---|
| 被移除的人 | ✅ 不漏。包只加密給 k11 裡別人的節點和 owner_enc_pub;偽造的鏈或重新邀請要網主簽 / 舊 admins 簽(approve.rs:304-317);被重新邀請要經網主同意(加上 removed 的確認框) | ✅ 擋不了。他不在 §2.4 的檢查範圍,也沒有任何入口。殘留:F10(wsl.24)、提早切換別人的節點(R32)、串通,都已寫成誠實界線 |
| 被抓的節點(含網主自己的;有 DAC 私鑰與 owner TagKey、會謊報 info) | ✅ 不漏。入口 1 以 k11 為準;入口 2 在第一次 SignAdmin 之前確認;同意時同一個確認框(強制位置 → m2;說明是誰的 → m3) | ✅ 謊報 k4:開始時不查(v6)。卡在 joining:前置 2 例外(v6)。謊報 k9:目標本身不算;兩台以上互相擋住 → m1(關藍牙可以脫困)。**被忘記之後沒有入口 → M1** |
| 其他留下的成員 | ✅ 不漏。包只對自己的金鑰;同意包綁 mpend;CAS | 提早切換、串通 → 誠實界線(已寫) |
| 剪貼簿 / 惡意 app | ✅ 沒有明文秘密;名冊外露已寫;貼上時清空 | 換成別的包 → 被拒或「已經匯入過」,只是 DoS |
| 被攻陷的 OS / 網主手機遺失 | 與今天相同(ADMIN_SIGN 不需要使用者驗證);新的影響面:拿到手機的人可以把全隊移除 → 已在 §9 checklist | — |
| 成員手機遺失 | 移除那個人 ✅(但前提是他還在 k11 → M1) | — |
| 我們自己的錯 | 送錯 DAC ✅;同版只簽一次 ✅(CAS 失敗的簽章不會送出);k4 規則 ✅;回滾:debuggable build 的 run-as → m5;降級 ✅;dev 測試路徑:app 閘門 ✅,工具的說法 → m6 | 忘記之後無法移除 → **M1**;第二組身分 → m4 |

v6 的每一項改動:

| 改動 | 結論 |
|---|---|
| 前置 2:本次排除的那一台除外 | ✅ 只有網主自己的 join2 會產生 joining 項;排除時它進 removed((v 的 removed ∪ 排除對象) − key 4);其他 joining 項照樣擋(也剛好防止 join2 和換密碼交錯) |
| 開始時不查 k4 | ✅ §3.2-2 每次送出前都查;別人的節點本來就只能靠前置 5 |
| 建立者的忘記保護只在 pending 時生效 | ✅ pending 時沒有 k11、也不能換密碼;applied 之後能忘記卡住的建立者,不影響秘密。副作用 → m9(iii)、M1(B) |
| 回 5 → 寫 applied → 送 update | ✅ 只會發生在入口 2 按「是」之後,或從來不在 removed 的節點;§3.2 的步驟 2 / 3 照常檢查 k4、k9、鏈 |
| 同意 removed 的 DAC 用同一個確認框 | ✅ 方向對;強制位置與測試 → m2;說明是誰的 → m3 |
| allowBackup=false | ✅ 關掉 adb backup;run-as 的界線與測試 → m5 |
| EXTRA_IS_SENSITIVE 經 Kotlin | ✅;API 範圍 → m8 |
| build 閘門(kind 4、移除這個人、排除自己的一台都只在 dev-trust) | ✅ 編譯期常數;工具的說法 → m6 |

## 4. 生命週期補查

| 路徑 | 結論 |
|---|---|
| 首次 / 第一次換密碼 | T3 ✅ |
| commit 前失敗 / commit 後被殺 | T2、T4 ✅ |
| 重開 / 節點晚開機 | T7、T7b ✅ |
| 升級 / 降級 / 再升級 | T10、§2.3 的一步包 ✅(第 5 輪的矛盾已修) |
| 斷電 / 斷線 | 節點 Finish;T5 ✅ |
| 依賴重啟(Keystore) | T2 ✅ |
| 平台 | 只有 Android(已寫) |
| **缺的路徑** | 被忘記的已同意 / 加入中項之後要移除(M1);兩台以上被抓的節點同時在附近(m1) |

## 5. 第 1–5 輪逐項確認(讀完自己的審查之後才讀)

| 項目 | v6 | 確認 |
|---|---|---|
| v5 A-MAJOR-1(a) joining 的自己節點不能排除 | 前置 2 例外;T32 | ✅ |
| v5 A-MAJOR-1(b) creator 永遠不能忘記 | §3.6 只在 pending;T32 | ✅(副作用 → m9(iii)) |
| v5 A-MAJOR-1(c) 回 5 時 k11 寫什麼 | §3.6 照今天寫 applied 再送;T32 | ✅ |
| v5 A-MAJOR-1 的「忘記對話框是空頭支票」 | 只解了「還在 k11 的 joining」 | ⚠️ 被忘記的項(含遠端 approved)→ **M1** |
| v5 A-m1 §5 / T15 與 §2.4 矛盾 | §5 那一列、T15 已改 | ✅ |
| v5 A-m2 降級再升級的一步包 | §2.3、§3.3 的清單條件與 start | ✅ |
| v5 A-m3 第二台的同意包比 mnet 舊 | §3.4 的句子 | ✅ |
| v5 A-m4 §5 被排除節點那一列 | §5 T27 列 | ✅ |
| v5 A-m5 正式版 commit 送不出去的版本 | 排除自己的一台只在 dev-trust | ✅ |
| v5 A-m6 / B-m1 入口 2 的位置 | 第一次 SignAdmin 之前 | ✅ 正文;T27 的負對照沒有跟著改 → m9(i) |
| v5 A-m7 §3.4-4 k7 必須在包裡 | 作者保留 fail-closed,附理由 | ⚠️ 作者已接受:不漏秘密,只是那個人要被重新邀請;我同意不列為阻擋 |
| v5 A-m8 判定理由沒提回滾 | §3.2 | ✅ |
| v5 A-m9 測試缺口 | T13 斷言、T34、T35 | ✅ |
| v5 A-m10 R8 行號 / k4 前提句 | :383-384;§3.6 前提句 | ✅ |
| v5 B-M1 謊報 k4 擋住換密碼 | 開始時不查 k4;T33 | ✅ |
| v5 B-M2 joining 的被抓節點 | 前置 2 例外、進 removed | ✅(已忘記的變形 → M1) |
| v5 B-m2 「之前被移出過」判斷不一 | 統一 | ✅ |
| v5 B-m3 同意 removed 的 DAC | 同一個確認框 | ✅;強制位置 / 測試 → m2 |
| v5 B-m4 其他成員提早換 | §6 | ✅ |
| v5 B-m5 只在 k10 的節點 NotApplied | §3.2-1 | ✅ |
| v5 B-m6 降級一步包 | 同 A-m2 | ✅ |
| v5 B-m7 allowBackup | 設 false;T31 | ✅;run-as / 測試 → m5 |
| v5 B-m8 EXTRA_IS_SENSITIVE | 經 Kotlin;T36 | ✅;API 33 → m8 |
| v5 B-m9 合成工具的閘門 | 兩道閘門 + 負對照 | ⚠️ feature 名稱、工具端閘門不是安全閘門 → m6 |
| v5 B-m10 串通 | §6 | ✅ |
| v4 / v3 / v2 / v1 各項 | §10–§13 | ✅ 抽查正文仍在:三個入口(§2.0)、k10 不推進(§2.1)、k12 標 used(§3.1)、secrets 要簽(§3.4-3)、偽造重新邀請要舊 admins 簽(§3.6-2)、2b 先於 PreviousNode、+1 路清 k10、commit 後不自動送(T19)、匯入後不自動送(T30)、start 公式與一律產包(§2.3)、128 KiB 以解碼後計、k4 正則(超過 9 位不通過)、wsl.24 前置 5、≥ 240 s 的鄰居觀察。第 1 輪 B-m10「換手機 = 兩組寫進說明」:正文沒有 → m4 |

## 6. 判定

0 BLOCKER / 1 MAJOR / 10 MINOR → **APPROVE-WITH-CHANGES**。

- **M1**:紀錄是 applied 時,「忘記已同意的項」改成走「移除這個人」,或給「移除並換密碼 / 只拿掉(之後無法移除)」兩個按鈕;joining 的自己節點,在忘記對話框給「排除這台」;已經忘記的情況寫進 §6 並附繞路。附 (a)(b) 兩個測試與負對照。
- MINOR 1–10 都是改字、補一句、補測試臂,或把確認的位置寫進 Rust 參數(m2),不加機制。

依規則,M1 關掉之前仍要整份重審;修法只動畫面路由與對話框,重審範圍小。
