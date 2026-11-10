# 254-app-remove-member.md v6.2 — 第 8 輪審查 A(正確性 / 介面 / 生命週期 / 現場;審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v6.2(473 行;app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 @ fbc01ae(NU v4.1)。全程唯讀,沒有碰裝置。我先自己審完整份,最後才讀第 1–7 輪的報告(§4)。

**判定:APPROVE-WITH-CHANGES**,0 BLOCKER / 1 MAJOR / 8 MINOR。MAJOR 關掉之前要再審一次;修法只動 §2.1、§2.4、§3.6、§5 各一句,再加兩個測試臂,重審範圍很小。

v6.2 刪掉了兩個機制,我分開查:
- **EXTRA_IS_SENSITIVE 刪掉:沒問題。** 今天的邀請和同意包也是用 Flutter `Clipboard.setData` 複製,沒有敏感標記;貼上時 `_takeClipboard` 會清空剪貼簿(lib/nodes.dart:603-606;lib/claim.dart:54-55)。更新包裡沒有明文秘密,§3.3 / §6 已寫成誠實界線,前後一致。
- **「保留最舊的 k13 一項」與缺口規則刪掉,k13 / k10 的部分沒問題。** 「缺 k10 = k13 最舊一版 − 1」我實際代入算過下面四種情況,都成立:
  - 第一次換密碼:start = 1,成員端拿 mnet k3 / k4 逐 byte 比對;
  - k13 修剪到 32 版之後:start = 目前版本 − 15;
  - 降級再升級:start = 目前版本;
  - 降級再升級之後又換一版:停在升級前一版的成員接得上(第 7 輪 A-m6 已解)。
- **「creator() 改回 k8 第一筆」有問題 → MAJOR-1。** §2.1 說 applied 之後 creator() 只影響畫面,這與程式碼不符。

## 0. 自己核的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| R3:creator() = k8 第一筆;使用者:confirm、forget、bridge 畫面、bridge forget 的重複檢查 | ✅ | netrec.rs:281-283、:316、:336;bridge owner.rs:98、:109、:127;lib/member_ui.dart:153(`forgettable` 用 creator 旗標) |
| **confirm() 在 applied 紀錄上也會跑「creator 升級」**:先呼叫 `rec.creator()?`,再把 dac = creator 而且不是 Applied 的項改成 Applied;用的是目前登入那台的 info,不檢查登入的就是 creator | ✅(MAJOR-1 的依據) | netrec.rs:307-329 |
| 「確認網路」按鈕對任何紀錄都在(applied 也在) | ✅ | lib/nodes.dart:997-1001、:1130-1133;bridge owner.rs:770-785(Upgraded → persist) |
| v1_members 對空的 key 4 回 `[]` → creator() 回 Err("members v1 empty") | ✅ | netrec.rs:265-283 |
| members key 4 可以是空陣列(單獨的網主排除最後一台) | ✅ | 219-protocol.cddl:362 `4 => [* member]`;設計 §2.4、§3.1、T26 |
| forget_joining 的第一行就是 `rec.creator()?` → creator() 回 Err 時,忘記一律失敗 | ✅ | netrec.rs:335-337;bridge owner.rs:127-131(Err 被對成「這台節點不在『加入中』」) |
| 同意包的 members = 網主 k8 原樣(成員端逐 byte 比對才成立) | ✅ | approve.rs:156-157 |
| `existing()`:+1 / TooOld / SameVersionDifferent / PreviousNode | ✅ | approve.rs:300-324 |
| 再貼同意包 → 比 secrets bytes 與 mnet k5 → NoRequest | ✅ | approve.rs:343-351 |
| `check_joinreq`:同一顆 DAC 已在 k11 → 只有「approved + 同一 owner_pub」能取代,applied → AlreadyMember | ✅ | approve.rs:69-86(MINOR-5 的依據) |
| join2 網主模式在第一次 SignAdmin 之前沒有寫入;隊員模式要求 k5 target 與 k7 都 = 這台 | ✅ | join2flow.rs:298-366 |
| 節點 netJoin 已經有網路時回 `E_STALE_VERSION` = 5;版本不限,只驗自己的 admins | ✅ | node/node.go:1035-1052、:39;provd/session.go:43 |
| 成員角色可以送 network/update(R32) | ✅ | provd/session.go:82 |
| NU §3:16 位成員時,14 步 = 8 塊 → 節點一次只能補 ≤ 13 版;§3.2-3 用實算塊數擋 | ✅ | NU §3 大小段;設計 §3.2-3 |
| store:CAS 在一把行程鎖下;回滾打得開 | ✅ | store.rs:1-11、:34、:136-145 |
| R7、R8、R10、R11、R12、R13、R17、R20、R22、R26、R27 抽查 | ✅ | approve.rs、invite.rs:143-194 / :217-221 / :264-283、flow.rs:118-150、conn.rs:12、envelope.rs:13、nodecert.rs:138-163、loginflow.rs:1-5 |

NU §3「app 必須處理的事」逐項對表,與第 7 輪相同,都有落點:
- pin DAC / 2 個槽位 / psk-rotated:只用擁有者連線,不適用(R20);
- 同版只簽一次;k9 > v 不開始(比 NU 的 max+1 嚴);
- > 8 塊不送;不帶 key 7;換 SAE + net_root;
- wsl.24:前置 5 + 每次送之前查 k4;
- AP 密碼提示;審核時依使用者決定跳確認框;
- 不改國碼;單一網主。

## 1. 流程逐條走(對 v6.2 的文字)

| 流程 | 依據 | 結果 |
|---|---|---|
| 第一次換密碼(舊紀錄沒有 k13 / k10) | §2.1 由 k7 / k8 補一項;缺 k10 = 0 → start 1;成員端 v1 與 k3 / k4 逐 byte 相同、v2 = +1 | ✅ |
| 移除一個人 → 產包 → 成員匯入 → 等 → 送 | §3.1 → §3.3(收件人契約,只取目前的 k11)→ §3.4 → §3.5 → §3.2 | ✅ |
| 第二次移除;畫面開著時再移除另一個人 | §2.4 k9 ≤ v 且在 k13;§2.3 契約 → 對舊畫面上的人拒絕、0 簽章 | ✅(第 7 輪 B-M1 已解,T40) |
| 一人多台(兩種貼上順序;第二台在換密碼前 / 後才同意) | §2.2、§3.4-4、「已經匯入過」補 k10 | ✅;「換密碼前同意、後貼同意包」沒有提示 → MINOR-3 |
| 成員落後 ≥ 2 版又加第二台(TooOld) | §3.4 提示「先貼更新包」 | ✅ |
| 同一版內 / 之後才重新邀請被移除的人 | 2b 先於 PreviousNode;回 5 → 接得上就送 / 接不上先離開 | ✅ |
| 排除自己的一台(含 joining 的、最後一台) | 前置 2 除外;§2.4 可以開始;key 4 可以是空的 | ✅ 換密碼本身 OK;**之後的 confirm / 忘記 / 下一次換密碼 → MAJOR-1** |
| 建立者那台被排除,k8 第一筆換成別人 | §2.1「只剩畫面」 | ❌ confirm() 會改寫 k11 → MAJOR-1 |
| 加回找回來的自己節點(重設 / 沒重設) | 入口 2 確認(Rust 參數)→ join2 → 5 → applied → §3.2 | ✅ |
| 網主 app 降級 / 再升級 | k13 一項、缺 k10 = 目前 − 1 → 一步包 | ✅;標示條件只撐一版 → MINOR-2 |
| 成員落後 > 16 版 / 超出歷代 | 成員端接不上 | ⚠️ 兩處句子互相矛盾 → MINOR-1 |
| 寫入中斷 / 兩段 CAS / 回應遺失 / 節點斷電 | §3.1 單一 commit;§3.4 generation;§3.2-4 再讀 info | ✅ |
| 節點降級 wsl.24 / 正式版 build | k4 規則 fail-closed;build 閘門 | ✅ |

## 2. MAJOR

### MAJOR-1 creator() 改回「k8 第一筆」之後,applied 紀錄上的 confirm() / 忘記 / 下一次換密碼會出錯;§2.1「applied 之後只剩畫面標示」與程式碼不符

**情境 A:k8 第一筆變成別人的項,「確認網路」會改寫它**
1. 網主排除建立者那台 X(v → v+1)。v+1 的 k8 第一筆變成 k11 順序裡的下一項,可能是:
   - 別人已同意、但還沒入網的節點(approved);或
   - 網主自己的另一台 Y,之後 Y 被重新 join2,中斷後留在 joining。
2. 網主在任何一台已到 v+1 的節點上按「確認網路」:
   - 這個按鈕對 applied 紀錄也在(nodes.dart:1130-1133);
   - confirm() 不管紀錄是不是 applied,都會把 dac = creator()、而且不是 Applied 的那一項改成 Applied,然後寫回(netrec.rs:316-328;owner.rs:777-781)。
3. 結果:
   - 別人的 approved 項變成「已加入」,畫面誤導;
   - 或者 Y 明明沒有入網,卻被記成 Applied(只看了另一台的 info)。這會讓 §3.6 / R31 為卡在 joining 的節點設計的處理,與前置 2,都看不到它。

第 6 輪 B-m9(iii) 已經指出「confirm() 用任何一台的 info 升級 creator 項」。v6.1 時 creator 固定是最舊 k13 項裡的原建立者,被排除後不在 k11,所以這個迴圈不會動到任何項。v6.2 改回 k8 第一筆,這條路才變成可以走到。

**情境 B:單獨的網主排除最後一台(使用者決定的情境,T26)→ k8 是空的 → creator() 回 Err**
- 「確認網路」:`confirm()` 第一步 `rec.creator()?` 失敗 → 畫面顯示 NET_DAMAGED(owner.rs:784),看起來像紀錄壞了。
- 忘記:`forget_joining` 第一行 `rec.creator()?` 失敗 → 之後 join2 新節點中斷留下的 joining 項永遠忘不掉。bridge 把錯誤對成「不在加入中」(owner.rs:131)。在下一次排除它之前,前置 2 都會擋住其他換密碼。
- 下一次換密碼:§2.4「建立者(若還在)第一」如果照現有寫法用 `creator()?` 取 → v+2 根本產不出來,緊急換密碼被擋。

**證據**:
- netrec.rs:281-283、:307-329、:335-337;bridge owner.rs:98、:127;nodes.dart:997-1001、:1130-1133。
- 219-protocol.cddl:362(`[* member]`)。
- 設計 §2.1:「它只用在 pending 紀錄的 confirm 與 forget 保護…applied 之後只剩畫面標示」。
- 設計 §3.6:「建立者的『忘記』保護只在紀錄 state = pending 時生效」。這句沒有說明 creator() 可能失敗,也沒有涵蓋 confirm。
- T38「`confirm()` 對建立者的升級在 k13 存在時仍正確」沒有定義什麼叫正確。

**修法(只改條件,不加機制)**:
1. `confirm()`:紀錄已經是 applied → 直接回 Already / OtherVersion,不呼叫 creator()、不動 k11。升級 creator 項只發生在 pending → applied 那一次(今天的正常路徑行為不變)。
2. `forget_joining` 與 bridge `net_forget_joining`(owner.rs:127):先判斷 `state == pending`,是 pending 才取 creator() 比對;applied 時不呼叫 creator()。
3. `net_summary` 的 creator 旗標只在 pending 時標;否則 Dart 的 `forgettable` 會把 applied 紀錄裡 k8 第一筆的 joining 項藏起來,與 Rust 的規則不一致。
4. §2.4 寫成:「v 的 k8 第一筆若還在 key 4 就排第一;k8 是空的就不排序」。不得因為 creator() 失敗而停止換密碼。
5. §2.1 與 §5 降級那一列改寫:舊 app 的 confirm / forget 仍有情境 A 和 B 的行為,寫成誠實界線。

**測試(各附負對照)**:
- T26 加一臂:單獨的網主排除最後一台(k8 = [])→ join2 新節點 → 「確認網路」回「本來就是已建立」→ 中斷留下的 joining 項忘得掉 → 再排除一台能 commit。負對照:今天的 confirm / forget → NET_DAMAGED / 忘不掉。
- T38 改成具體的斷言:applied 紀錄、k8 第一筆是別人的 approved 項 → confirm 後 k11 逐 byte 不變。負對照:今天的 confirm → 那一項變成 Applied。

## 3. MINOR

1. **§3.4-2 的句子和 §2.3 / §5 矛盾,而且叫成員做沒有用的事。**
   - §3.4-2:「第一版 > mnet 版本 + 1 →『你的資料太舊,請網主重新產生更新包』」。
   - §2.3:「成員端若接不上…『你的資料太舊,請網主讓你的節點離開網路、再重新邀請你』」;§5 T8b 那一列也是這樣寫。
   - start 只由 k10(不前進)、−15 上限、k13 最舊一版決定,網主重產會得到同一個起點 → 成員和網主會來回白跑。
   - **修法**:§3.4-2 改用 §2.3 的句子。

2. **「升級前的版本不明」的標示只撐一版。**
   - §3.3 的條件是「k13 只剩目前版本而目前版本 > 1」。降級再升級之後,只要再換一次版,k13 就有兩項,標示消失;可是缺 k10 的項,實際版本仍然不明。
   - **修法**:條件改成「這個人有缺 k10 的項,而且 k13 最舊一版 > 1」(只有這時,預設值才可能不準)。T10 加一臂。

3. **第 7 輪 A-m4 沒有真正處理。**
   - 情境:第二台的同意包在**換密碼前**產生,成員**先貼更新包**、再貼同意包 → SameVersionDifferent → 只能重新邀請。
   - v6.2 加的提示(同意畫面:「請他先貼更新包,再貼這份同意」)是給**換密碼後**才產的同意包用的(TooOld 那一類),方向相反。原情境還是沒有提示。
   - **修法(只改字)**:§3.3 產包時,若這個人有 approved 項的 k10 < 目前版本,在那一列加「請他先貼〈後 4 碼〉那份同意包,再貼這份更新包」。測試:出現條件一臂。

4. **第 7 輪 A-m5 的殘留:§3.2-3「這台落後太多版,請讓它離開網路再重新加入」沒有依 k7 分句。**
   - 只在 k10、不是 k7 的成員節點照做離開之後,§3.2-1 才會說「這台要請網主重新邀請」。§3.5 已經分句,§3.2-3 沒有。
   - **修法**:成員端、而且不是 k7 → 「請讓它離開網路,再請網主重新邀請這台」。T5 加一臂。

5. **owner_enc_pub 不一致時的出路說錯。**
   - §2.3 說「請讓他重新加入」。可是他已經入網(applied)的節點再申請,`check_joinreq` 會回 AlreadyMember(approve.rs:78-84),只有 approved 項能被取代 → 不一致永遠消不掉,而這個人永遠拿不到包。
   - **修法**:句子改成「請先移除這個人,再重新邀請他的每一台節點」。T40 的那一臂斷言句子。

6. **T31 只是存在檢查。**
   - 「Manifest `allowBackup=false`(建置產物檢查)」照使用者規則不算測試。
   - **修法**:對建出來的 dev 與 release APK 用 `aapt2 dump xmltree`,斷言合併後的 manifest 是 `allowBackup=false`。負對照:拿掉這個屬性 → 測試 FAIL(合併後預設是 true)。

7. **第 7 輪 B 的測試臂沒有落進 §7。**
   - B-m7:T24 沒有「流程的 Action(`invite::Action::Persist{plain}`、`NetRecord`)經 `{:?}` 後不含 SAE / net_root hex」這一臂。
   - B-m9:T28 沒有「+1 路的 members prev_hash 不對 → 拒絕」的負對照。
   - 第 7 輪 A-m10(vi):T37 的狀態頁句子沒有負對照。
   - **修法**:各補一臂。

8. **文字殘留。**
   - (i) §1 標題仍是「第 1、2 輪四位審查逐條核過」,但 R27–R32 是之後加的。
   - (ii) R30 排在 R32 之後;R31 沒有行號(join2flow.rs:661-712)。
   - (iii) §12–§15 的歷史表仍寫「§3.3 敏感標記」「§2.1 修剪保留最舊一項」「EXTRA_IS_SENSITIVE 經 Kotlin;T36」「T34」。§10 那句「以正文為準」只放在 §10;建議在這幾列加「v6.2 已刪」。
   - (iv) 第 7 輪 B-m1 的後半沒有做:入口 1 的句子「已被排除」也會顯示在被**忘記**的自己節點上 → 改成「這台不在隊伍網路的名單裡(可能已被排除或被忘記)」。
   - (v) 第 7 輪 A-m10(iii):正文仍有裸的「k9」(§2.4、§3.2)。
   - (vi) §3.5「隊員模式加入回 5 → 直接走 §3.2 送新密碼」:成員在網主還在發包時按了「加入網路」,節點就會被直接換掉,和 §3.4「等網主說…再按」的原則不同。作者在第 7 輪選了直接送,可以接受;建議在那一句後面加「(會讓這台立刻進入新的一邊)」,讓行為寫在明處。

## 4. 第 1–7 輪逐項確認(在自己的審查之後才讀)

| 項目 | v6.2 | 確認 |
|---|---|---|
| v7 B-M1 收件人來源 | §2.3 契約;T40 | ✅ 只從目前的 k11 取 ecdh_pub / owner_enc_pub / k10;沒有 / 是自己 → 0 簽章;不一致時的出路句子 → MINOR-5 |
| v7 A-m1 / B-m3 忘記導向在 Rust | §3.6;T39 在 bridge 層 | ✅;但 forget 前面那道 creator 檢查 → MAJOR-1 |
| v7 A-m2 正式版的忘記對話框 | 限 dev-trust;T36 | ✅ |
| v7 A-m3 / B-m1 狀態頁分成員 / 網主 | §3.5 | ✅;被忘記的節點的句子 → MINOR-8(iv) |
| v7 A-m4 / A-m7 / B-m5 貼上順序 | 同意畫面 + 取代確認框 | ⚠️ A-m7 / B-m5 ✅;A-m4 沒做 → MINOR-3 |
| v7 A-m5 只在 k10 的節點、離開那句 | §3.5;R19 結論更正 | ⚠️ §3.2-3 沒改 → MINOR-4 |
| v7 A-m6 缺 k10 = 最舊 − 1 | §2.1、§2.3、§3.3、T3 | ✅ 代入四種情況都成立;標示條件 → MINOR-2 |
| v7 A-m8 只算 Applied | §2.4 | ✅ |
| v7 A-m9 回 5 後的行為 | 統一成直接送 | ✅(註記 → MINOR-8(vi)) |
| v7 A-m10 文字 / 測試殘留 | T27 / T38 一致;前者 / 後者;join2 確認由 Rust 強制 | ✅ (i)(ii)(iv);(iii)(v)(vi) 仍在 → MINOR-7、-8 |
| v7 A-m11 已忘記的繞路 | §3.6 | ✅ |
| v7 A-m12 EXTRA_IS_SENSITIVE | 刪除 | ✅ 沒有破壞任何東西(§0) |
| v7 A-m13 最舊一項 / 缺口規則 | 刪除;creator 回到 k8 第一筆 | ⚠️ k13 部分 ✅;creator 部分比第 7 輪的建議(回落到 k13 最舊項的第一筆)多走了一步 → MAJOR-1 |
| v7 B-m2 / m4 / m6 / m8 / m9 | §2.0、§3.6、§2.3、§7、§2.2 | ✅ 正文都在;B-m9 的測試臂沒有 → MINOR-7 |
| v7 B-m7 既有結構的 Debug | §6 | ✅ 正文;測試臂 → MINOR-7 |
| v6 A-MAJOR-1、B-MAJOR | §3.4-4、§3.6 | ✅ 重走成立 |
| v6 B-m9(iii) confirm 用任何一台的 info 升級 creator 項 | T38 一句 | ⚠️ v6.2 起可以走到,而且有害 → MAJOR-1 |
| v5 以前各項(三個入口、k10 不推進、k12 標 used、secrets 要簽、TooOld 要舊 admins 簽、2b、+1 路清 k10、commit 後 / 匯入後不自動送、start 公式、128 KiB、k4 正則、前置 5、開始不查 k4、前置 2 例外、240 s、allowBackup) | 正文 | ✅ 抽查都在 |

## 5. 判定

0 BLOCKER / 1 MAJOR / 8 MINOR → **APPROVE-WITH-CHANGES**。

- MAJOR-1 是 v6.2 刪除機制時新引入的:applied 紀錄上的 confirm / 忘記 / 換密碼排序還依賴 creator()。修法是三個條件(只在 pending 時用 creator、k8 是空的不排序)加兩個測試臂,不加機制。
- 依規則 MAJOR 關掉之前要再整份重審;這次的修改範圍很小。
- 另一個刪除(EXTRA_IS_SENSITIVE)和缺 k10 的新預設,我照程式碼與公式走過,都沒有破壞任何流程。
