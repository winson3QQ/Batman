# 254-app-remove-member.md v5 — 第 5 輪審查 B(安全優先,審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v5(375 行,untracked;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 `feat/254-p3` @ fbc01ae(NU v4.1)。唯讀,沒有碰裝置。我先自己審完整份,最後才讀第 1–4 輪八份報告(§5)。

**判定:REJECT(小改)**,0 BLOCKER / 2 MAJOR / 10 MINOR。

§2.0 的三個入口,兩個方向我都逐一查過:
- **會不會漏秘密**:被排除或被抓的節點,以及被移除的人,在網主沒有明確說「是」的情況下,我找不到任何一條路能拿到新的 SAE / net_root。
- **會不會擋掉合法流程**:新節點、同一版本內重新邀請、加回、一人多台,都走得通。

兩個 MAJOR 都不是漏秘密,而是**敵人可以讓緊急換密碼做不成**:
- M1:被抓的節點謊報 k4,就能擋住換密碼,連它自己被排除也擋得住。
- M2:網主自己一台卡在 joining 狀態的節點被抓之後,沒有任何辦法排除它。

兩個的修法都是改一個條件。

## 0. 自己查的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| dev-trust 是編譯期常數;bridge 的入口用 `#[cfg(feature="dev-trust")]` 擋 | ✅ | nodecert.rs:40-42;batman-proto/Cargo.toml:16-19;bridge/Cargo.toml:52-54;bridge/src/api/member.rs:16、:318 |
| `trust_gate`:`dev:` DAC 只在 DEV_TRUST 下接受;加入申請走 `verify_offline` → 同一道閘 | ✅ | nodecert.rs:139-162;approve.rs:59 |
| 加入申請的 owner_pub 要證明持有(Sign1 用它自己驗、sig_enc 綁 owner_enc_pub) | ✅ | approve.rs:39-57 |
| `check_joinreq`:k11 已有同一個 DAC 時,只有「approved 且同一位 owner」才能取代;被排除的 DAC 已經從 k11 刪掉 → 可以重新申請 | ✅ | approve.rs:69-86 |
| join2 網主模式:`begin` 檢查前置 → **第 2 步就 SignAdmin net_secrets**(用登入時驗過的 ecdh_pub)→ 第 3 步國碼(可能先寫 joining + prev_country)→ 第 4 步 PersistNet → 第 5 步送出 | ✅ | join2flow.rs:1-17、:298-325、:357-366 |
| join2 隊員模式:k5 的 target 必須 = 登入的 DAC,而且必須是 k7 → 只在 k10 裡的節點會被拒(NotThisNode) | ✅ | join2flow.rs:328-347 |
| 節點的 netJoin:已經在網路裡 → 5(`EStaleVersion`),**但 secrets 已經隨 request 送到**;被抓的節點有 ecdh 私鑰,本來就解得開 → 守則一定要在「送出」之前 | ✅ | node.go:1035-1052;node.go:39 |
| 節點的 netUpdate:每一步由前一版 admins 驗、版本 / prev_hash 連續、國碼不變;members 只驗簽與 net_id / 版本;secrets 綁 (net_id, 版本) | ✅ | node.go:1083-1170、:936-956 |
| member 角色可以送 `network/update`(不需要 owner-op) | ✅ | provd/session.go:79-82 |
| `E_REJECTED`=11、reason 14 = ReasonCountryJoin(§3.2-4 的「{2:14}」) | ✅ | provd/session.go:48;node/settingsset.go:21 |
| ADMIN 只簽 5 種標籤;本單不需要新增標籤 | ✅ | SignAllowList.kt:11、:25 |
| `confirm()` / `forget_joining()` 用 creator();forget 只能刪 joining / approved,不能刪 applied | ✅ | netrec.rs:296-347 |
| Manifest 沒設 allowBackup;targetSdk = flutter 預設 36 | ✅ | AndroidManifest.xml:9-12;app/build.gradle.kts:25;flutter FlutterExtension.kt:34 |
| 複製用 Flutter `Clipboard.setData`(設不了 EXTRA_IS_SENSITIVE) | ✅ | lib/nodes.dart:652、:745 |
| store 不偵測回滾;AAD 含路徑與 generation | ✅ | store.rs:1-11 |

## 1. MAJOR

### M1 被抓的節點謊報 k4,就能擋住換密碼(連它自己被排除也擋得住);前置 4 沒有排除要排除的那一台,也沒有指出是哪一台

**情境 A(網主排除被抓的那台)**
1. 網主的節點 X 被抓。X 有 DAC 私鑰與 owner TagKey,所以網主手機和它的擁有者連線照樣成立(R20、R28)。
2. 攻擊者把 X 帶在網主的 BLE 範圍內,或用 X 的金鑰模擬它,info 的 k4 回 `1.5.14-wsl.24`(或任何解析不出的字串)。
3. 網主按「排除這台(…X)」。前置 4:「連得上的網路裡的自己節點 k4 都要通過 §3.6」。X 這時還在 k11,而這條前置**沒有說要排除這次的目標**(§2.4 的 k9 檢查有說「不含這次要排除的那台」,k4 這條沒有)。X 不通過 → 不開始。
4. 結果:被抓的節點擋住了把它自己切掉的換密碼,手上的舊密碼一直有效。

**情境 B(移除一個人)**
網主一台還沒發現被抓的節點謊報 k4 → 不開始,畫面是「這台要先更新軟體」之類的句子,而且**沒有指出是哪一台**。§2.4 對 k9 謊報已經要求指名(第 4 輪 B-m6),k4 漏了同一件事。

**為什麼是 MAJOR**:目標寫的是「沒有人能用新流程破壞網路」。這裡攻擊者只要做一件很便宜的事(回一個假字串),就能讓排除自己的節點這條緊急路徑整條停住。

**證據**:§3.1 前置 4 的原文;§2.4「(不含這次要排除的那台)」只套在 k9;§3.6 的 k4 規則是 fail-closed;§3.2-2 每次送出前本來就會查 k4。

**修法(改一個條件)**:
- 開始時的 k4 檢查**拿掉**。理由:送出前每一台都會查 k4(§3.2-2);別人的節點也只能靠前置 5 的勾選。開始時再查一次,沒有多擋到什麼。
- 如果要保留:「不含這次要排除的那台」,不通過時**指名**(device_id 後 4 碼),並且給出路「先排除那一台」。

**測試**:T15 加兩臂:
- 目標節點的 k4 = wsl.24 → 排除照樣可以開始。負對照:照 v5 的前置 4 → 被擋。
- 另一台自己的節點 k4 不通過 → 錯誤訊息帶它的後 4 碼。

### M2 網主自己一台卡在 joining 的節點被抓之後,沒有任何辦法換密碼把它切掉;之後 join2 / 同意它也不會出現任何「之前被排除」的提示

**情境**
1. 網主用 join2 加節點 X,結果落到 `Keep`(Unclear7 / Unclear / CountryUnknown / TwiceRefused)。X 的 k11 項停在 joining,但第 5 步已經把目前版本的 SAE / net_root 送給 X,X 可能已經套用了(join2flow.rs:12-17)。
2. X 被抓。網主按 X 的「排除這台」:前置 2「沒有 joining 的成員項」→ 不開始。
3. 網主唯一的出路是「忘記」(forget_joining 可以刪 joining 的項,netrec.rs:335-347)。忘記之後 X 不在 k11,所以「排除這台」也沒有對象;排除是唯一能觸發換密碼的動作,於是**換密碼根本開始不了**。X 手上的密碼一直有效。
4. 就算網主改用移除別人、或排除另一台自己的節點來硬換一次:X 從來沒有進 removed。之後 X 被重設再拿回來,join2 的入口 2 不會跳確認;攻擊者用 X 的 DAC 送加入申請,SAS 畫面也不會有「之前被移出過」。

**證據**:§3.1 前置 2;§2.0「網路裡的自己節點 = k11 中 owner_pub = 自己的項(**不論 joining** / approved / applied)」,而 §3.1 的「排除這台」又被前置 2 擋住,兩者互相矛盾;join2flow.rs 的 Keep 分支會讓項目停在 joining;§2.4 的 removed 只加「本次排除對象」。

**修法(改一個條件)**:前置 2 改成「除了這次要排除的那一台之外,沒有 joining 的成員項」。排除 joining 的項時:從 k11 刪掉,dac_hash 加進 removed,它本來就不在 key 4。其他 joining 項維持擋住(理由不變)。忘記對話框可以加一句:「如果這台遺失 / 被抓,請改用『排除這台』」。

**測試**:T26 / T27 加一臂:自己的 joining 項 X → 可以排除,X 的 dac_hash 在 v+1 的 removed,之後 join2 X 會跳確認。負對照:照 v5 的前置 2 → 不開始。

## 2. MINOR

1. **入口 2 的檢查時機要寫成「join2 第 2 步(SignAdmin)之前」**(join2flow.rs:298-325 的 `begin`、:357-366)。§2.0 的總則寫「任何寫入或 SignAdmin 之前」,入口 2 自己又寫「PersistNet 之前」。PersistNet 是第 4 步,而第 2 步已經簽了 secrets、第 3 步可能已經寫入 joining + prev_country。T27(2) 的 mutation「放在 PersistNet 之後」抓不到「放在第 2 步與第 4 步之間」這種錯。mutation 要改成「放在 SignAdmin 之後」,斷言 SignAdmin 0 次、紀錄 bytes 不變、settings/set 0 次。
2. **「之前被移出過」兩處用的判斷不同。** 入口 2 看 k13 任何一版的 removed;§3.6 的 SAS 提示只看目前的 removed。建議統一用 k13 任何一版,只多一行。
3. **同意一個在 removed 裡的 DAC,只有 SAS 畫面上的一句話。** 這和入口 2 的風險一樣:被抓的節點拿著攔到的邀請來申請,會拿到目前版本的 secrets。入口 2 是另外跳出確認框,這裡只是一行字,畫面上很容易漏看。建議用同一個確認框(仍然不擋,符合使用者的決定)。第一道防線還是 SAS 比對,所以是 MINOR。
4. **拿到更新包的人,可以提早替別人切換節點。** member 角色可以送 `network/update`(session.go:82)。包裡就是鏈加上成員節點的 net_secrets。任何還在舊網路的人(包括手上有舊 net_root 的被移除者)從剪貼簿 / 傳遞管道拿到 M 的包,就能用舊的 psk_member 把 M 的節點提早換到新網路。秘密不會外洩,但會打亂 §3.1 / §3.4 刻意安排的「包都發完再換」順序。§3.7 / §6 補一句誠實界線即可。
5. **成員端入口 3 允許只在 k10 裡的節點,但 §3.2-1 的 NotApplied 會導向隊員模式,而 join2 隊員模式一定回 NotThisNode**(join2flow.rs:339-341)。§3.2-1 要寫明:非 k7 的節點 NotApplied → 直接說「請網主重新邀請這台」,不要導向一條注定失敗的路。
6. **降級再升級的產包規則仍然自相矛盾**(第 4 輪 A-m4 只修了一半)。§2.3 寫:缺 k10 = k13 最舊一項 = 目前版本 → 「成員已在目前版本 → 不產包」;同一段又寫「產只含目前版本一步的包」。§3.3 的清單條件 k10 < 目前版本,在這種情況下是空的。要寫明:k13 只有一項、目前版本 > 1、而且 k10 缺 → 列出、標示、產一步的包,不套「不產包」那一條。T10 加一臂。
7. **allowBackup:把 ⚠️ 改成有證據的說法,並直接設定。**
   - targetSdk 36(flutter 預設):Android 12 以上,`adb backup` 對 targetSdk ≥ 31 的 app 不含 app data,除非 app 是 debuggable。dev flavor 的 debug build 是 debuggable,所以 dev 機上回滾是真的可能;release 大致不會。
   - 建議這個 PR 直接設 `android:allowBackup="false"`。只有一行,而且 §3.2「同版只簽一次」的推論靠的就是「回滾要 root」。不要只放進 checklist。
8. **EXTRA_IS_SENSITIVE 要走 Kotlin。** Flutter 的 `Clipboard.setData` 設不了這個旗標(lib/nodes.dart:652、:745 現在都走它)。設計要寫明「經 MethodChannel 由 Kotlin 設 ClipDescription extras」,並加一個 Android 儀器 / 單元測試斷言旗標存在。否則這一項驗證不了。
9. **合成第三人的工具「只接受 dev-trust 的邀請」做不到**:邀請本身不帶信任模式。真正的閘門是兩道:遠端邀請只存在 dev-trust 的 app(bridge member.rs:16);`dev:` DAC 只在 dev-trust 的網主端通過 `verify_offline`(nodecert.rs:139-162)。改寫成這兩道,並加一個負對照:非 dev-trust build 的 `open_joinreq` 拿到工具的輸出 → `Untrusted`。
10. **留下的成員串通。** 每位留下的成員都拿得到新的 net_root(member_secrets),交給被移除的人,他就算得出新版的 psk_member(member 角色:info / network/update / status)。這擋不住,寫進 §6 的誠實界線就好。

## 3. 依角色的結論

| 角色 | 結論 |
|---|---|
| 被移除的人 | 拿不到新 secrets ✅:加密給別人的 ecdh_pub / owner_enc_pub,而且綁版本;偽造的包或重新邀請都要網主簽 / 舊 admins 簽(approve.rs:300-308)。殘留:wsl.24 的 F10、提早切換別人的節點(m4)、串通(m10) |
| 被抓的節點(含網主自己的) | 入口 1 由 k11 擋 ✅;入口 2 在送出前確認 ✅(時機寫法 → m1);謊報 k4 擋住換密碼 → **M1**;卡在 joining 時排除不了 → **M2** |
| 其他留下的成員 | 偽造不了網主簽章、蓋不掉別人的 mnet ✅;串通 → m10 |
| 剪貼簿 / 惡意 app | 沒有明文秘密 ✅;名冊外露(已寫);換成別的包會被拒 ✅;sensitive 旗標的實作 → m8;提早切換 → m4 |
| 被攻陷的 OS / 網主手機遺失 | 與今天相同;已寫成誠實界線 ✅ |
| 成員手機遺失 | 移除那個人 ✅ |
| 我們自己的錯 | 同版只簽一次 ✅(CAS 失敗時簽好的物件沒有送出;重讀後版本前進);送錯 DAC ✅(ecdh_pub 取自 k11);k4 規則 ✅(start 時的用法 → M1);回滾 / adb → m7;降級 ✅(已寫);測試路徑:編譯期閘門 ✅,工具說法 → m9 |

## 4. 生命週期補查

| 路徑 | 結論 |
|---|---|
| install / 首次:第一次換密碼(T3) | ✅ |
| start / 被殺 / 重開 | T4、T7、T7b ✅ |
| 升級 / 降級 / 再升級 | T10 ✅;產包規則 → m6 |
| 斷電 | 節點 Finish ✅ |
| 依賴重啟(Keystore 失敗) | T2 ✅ |
| 平台 | 只有 Android(已寫) |
| **缺的路徑** | 自己的 joining 節點被抓(M2);目標節點不配合時的開始條件(M1) |

## 5. 第 1–4 輪逐項確認(讀完自己的審查之後才讀)

| 項目 | v5 | 確認 |
|---|---|---|
| v4 A-BLOCKER-1 / B-M1 / B-M2 守則擋掉重新邀請、加回、新節點 | §2.0 三個入口;T27、T17b、T26 | ✅ 我自己走過:同版重新邀請(2b 新 joining、入口 3 = k7 → 送)、加回(入口 2 確認 → join2 建 k11 → 入口 1)、新節點(不在 removed)。入口 2 的時機 → m1 |
| v4 A-M1 一人多台第一台換不了 | +1 路清空 k10、取用時比對版本;規則 6 只看 removed | ✅;非 k7 節點的 NotApplied → m5 |
| v4 A m1(k13 缺口) | §2.1、§2.3 最近連續段 | ✅ |
| v4 A m2 / B m6(k9 不在 k13、指名) | §2.4 | ✅(k9 部分);k4 沒有指名 → **M1** |
| v4 A m3(連不上的不對稱) | §2.4 | ✅ |
| v4 A m4(版本不明的清單是空的) | §2.3、§3.3 | ⚠️ 仍然自相矛盾 → m6 |
| v4 A m5(2b 和 PreviousNode 的順序) | §3.6-2b | ✅ |
| v4 A m6(匯入後自動送) | §3.4 不自動送;T30 | ✅;別人仍可提早切換 → m4 |
| v4 A m7 / m8 | §7;§2.0 入口 3 | ✅ |
| v4 B m1–m3、m5、m7–m10 | §5、§2.3、§3.6、§2.5、§6、§3.1-1、§7 | ✅;m10 工具的說法 → m9 |
| v4 B m4(allowBackup) | §6、§9 checklist | ⚠️ 只進了 checklist → m7 |
| v3 B-B1(被排除的節點經狀態頁 / NotApplied → join2 拿到新密碼) | 入口 1(k11,commit 時已刪)+ 入口 2(送出前確認) | ✅ 兩條路都關了;joining 的變形 → **M2** |
| v3 A-M1 / A-M3 / A-M4 / B-M1 / A-M5 | §2.4、§3.1、§2.3、§2.2 | ✅ |
| v3 其餘 MINOR、v1–v2 全部 | 第 4 輪兩位已經逐項確認;v5 沒有改回這些段落 | ✅ 抽查:k10 不推進、k12 標 used(approve.rs:72-73)、secrets 要簽、重新邀請要舊 admins 簽(approve.rs:303-308)、kind 4 的編譯期閘門 |

## 6. 判定

0 BLOCKER / 2 MAJOR / 10 MINOR → **REJECT(小改)**。

- **M1**:開始時的 k4 檢查拿掉;或者不含目標、指名那一台。
- **M2**:前置 2 不擋要排除的那一台;排除 joining 項時把它加進 removed。

兩項都只改一個條件,各自附了負對照。依規則,修完要整份重審。
