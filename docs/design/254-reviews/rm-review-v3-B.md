# 254-app-remove-member.md v3 — 審查 B 第 3 輪(安全優先,審整份)

對象:WSL `/home/yello/Batman-app/docs/design/254-app-remove-member.md` v3(app `feat/254-app-s1` @ 6574ca4);節點 Batman-p3 `feat/254-p3` @ fbc01ae(NU v4.1)。唯讀,沒有碰裝置。先自己審整份,之後才讀第 1、2 輪四份審查(§5)。

**判定:REJECT(小改)**。1 BLOCKER / 1 MAJOR / 10 MINOR。主路徑(先 CAS、owner 連線 pin DAC、secrets 都要網主簽且綁版本、鏈由前一版 admins 簽、k12 作廢、重新邀請要舊 admins 簽)是對的,我逐條再查過。BLOCKER 是 v3 新加的「排除自己的一台」被 v3 自己的狀態頁按鈕繞過;MAJOR 是 v3 的產包起點規則把第 2 輪 A-MAJOR-2 的情境又帶回來。兩者的修法都是加一條比對 / 刪一條拒絕,不加機制。

## 0. 自己查的事實

| 項目 | 結果 | 依據 |
|---|---|---|
| 節點 update 不讀成員清單、不看 removed | ✅ | node.go:1143「the node neither stores nor reads it」;NU:15、:21、:111、:159「節點擋不了」 |
| 節點上存 owner 的 TagKey,psk_owner = HKDF(TagKey, device_id) | ✅ | node.go:421、:573、:879;proto.go:157;loginflow.rs:1-5 |
| owner 連線只 pin DAC | ✅ | loginflow.rs:1-5 |
| secrets 綁 (net_id, version),不綁哪份 netcfg | ✅ | NU:47 F18、:75 §2.2-5;approve.rs:202-216 `secrets_payload` 帶 cfg.net_id / version |
| 同意包 `bind()` 用 pend netcfg admins 驗 members / secrets / msecrets,target 比對 | ✅ | approve.rs:275-293 |
| `existing()`:+1 版要舊 admins 簽 + prev_hash;+2 以上 TooOld;同 DAC 沿用舊 me(含 state) | ✅ | approve.rs:297-322 |
| `open_netcfg_v1` 只收 v1;`open_invite` 自我證明 | ✅ | invite.rs:143-178 |
| 整條遠端邀請 / 成員路徑由 bridge 擋在 dev-trust | ✅ | invite.rs:12;nodecert.rs:40-42、:146;tests/member.rs:7 |
| ADMIN_SIGN 標籤已涵蓋本單所有簽章(kind 4 頂層不簽,不需新標籤) | ✅ | SignAllowList.kt:11、:25;Keys.kt:88-97 無使用者驗證 |
| `member_list_payload` 5/6/7 寫死空 | ✅ | cose.rs:110-134 |
| `creator()` = members v1 第一筆 | ✅ | netrec.rs:280-283 |
| `join_state` 不看 k9 | ✅ | flow.rs:130-150 |
| store 不偵測回滾,只有能寫 app 私有目錄(root)的人做得到 | ✅ | store.rs:8-11 |
| AndroidManifest 沒設 `allowBackup`(預設 true),紀錄在 `filesDir` | ✅ | app/src/main/AndroidManifest.xml:9-40;MainActivity.kt:33。還原到別台 / 重裝後 Keystore 金鑰不在 → 打不開,不構成回滾(⚠️ 推論,未實測) |

## 1. BLOCKER

### B1 被排除的自己那台節點,v3 自己的狀態頁會提示「把新密碼送給節點」,一按就把新的 SAE / net_root 送給它

情境(實體奪取網主的節點,這正是 v3 新加「排除這台」要擋的人):
1. 攻擊者拿到網主的節點 X。民用版沒有安全晶片,X 上的 DAC 私鑰、owner 的 TagKey(node.go:421 由它算 psk_owner)、舊 SAE / net_root 都可以讀出。
2. 網主按「排除這台」→ commit v2:k11 刪掉 X、X 的 dac_hash 進 removed(§3.1)。**`node/` 擁有者紀錄沒有動**:§3.1 的 commit 只寫 `net/<id>`,§3.5 是「對每一台自己擁有、在這個網路的節點」。
3. 攻擊者把 X 刷成會接受任何 owner 驗證的韌體(或者只是把它放回網主附近)。網主手機連上:psk_owner 對得上,DAC 與節點紀錄 pin 的相同(R20 只 pin DAC),所以 owner 連線成立。info k10 = 本網,k9 = 1 < 紀錄 2。
4. §3.5 共用規則:「這台還在舊密碼 — 把新密碼送給節點」→ §3.2-3「網主:現產」這台的 net_secrets → 送 `network/update`。節點**不看 members / removed**(node.go:1143),一定會套用。攻擊者拿到 v2 的 SAE 與 net_root,能進新 mesh、能算出 v2 的 psk_member。
5. 另一條路:X 被重設成沒入網 → §3.2-1 NotApplied「導向網主的加入網路,用手機的目前版本加入」→ 同樣拿到 v2 secrets。join2 不走 SAS,§3.6 的「之前被移出過」提示也不會出現。

結果:「排除的節點拿不到新密碼」這個目標,被我們自己的畫面引導破掉。不需要偽造任何簽章,只要網主照畫面按一下。遺失後撿回(不是被抓)的情況也一樣:設計沒有定義被排除的節點之後是什麼狀態。

證據:§3.1(commit 只刪 k11)、§3.2-1 / -3(網主現產 secrets,沒有檢查目標是否在目前 members)、§3.5(依 `node/` + info 列節點);node.go:1143;NU:111、:159。

修法(一條比對,不加機制):
- §3.2 加前置:網主路徑的目標 dac_hash 必須在**目前版本 members key 4**(= k11 中 applied / approved 的項),而且不在 removed;net_secrets 的 ecdh_pub 只取自那一項。否則 → 「這台已被排除在隊伍網路外」,不送;只提供「離開網路」。
- 網主的 join2(NotApplied 導向)與成員的隊員模式加入,目標 DAC 在目前 removed → 同一句,不送;要重新加入就走一般的重新邀請 / 同意(會看到 §3.6 的「之前被移出過」)。
- §3.5 的共用規則跳過被排除的節點,改顯示「已排除」。可以不動 `node/` 紀錄(只做必要的)。
- 測試:X 被排除後,info k9 舊 / k10 本網 → §3.2 送出 0 次、句子 = 已排除;NotApplied → join2 送出 0 次;負對照:拿掉這條比對 → 送出 1 次。加進 mutation 清單。

## 2. MAJOR

### M1 §2.3 的「start > k10 + 1 就不產包」會讓**一直都有跟上**的成員,在第 17 次換版後被拒、被迫重新邀請(第 2 輪 A-MAJOR-2 的情境回來了)

情境:Carol 在 v1 被同意,k10 = 1,而且 k10 依設計永遠不前進(§2.1「複製更新包不推進它」)。她每一次都準時匯入。到 v18:start = max(1 + 1, 18 − 15, 最舊) = 3 > k10 + 1 = 2 → §2.3「不產包,請讓他的節點離開網路、再重新邀請」。Carol 的 mnet 其實是 v17,只缺一版。全隊最早加入的人最先被卡住,而且所有人最終都會被卡住(包含網主排除自己的節點、將來的改頻道 / 改名都走同一條版本線)。

證據:§2.1 k10 語意;§2.3 start 公式與拒絕句;第 2 輪 A-MAJOR-2 的修法原文是「真的落後超過的人得到『你的資料太舊』」(由**成員端**判斷),v3 改成在**網主端**拒絕;§3.4-2 成員端本來就會去掉已有的前綴,第一版 > mnet + 1 時回「你的資料太舊」。

修法(刪掉一條):網主一律產 [start, 目前] 的包(start = max(目前 − 15, k13 最舊),k10 只用來決定「誰在清單上」);拒絕只在成員端(§3.4-2「你的資料太舊,請網主…」改成「請讓節點離開網路、請網主重新邀請你」)。若要保留網主端提示,只能是提示(「這位可能落後太多」),不能不產包。測試:k10 = 1、目前 v18、成員 mnet v17 → 產包、匯入成功;負對照:照 v3 公式 → 不產包。成員 mnet v1、包從 v3 起 → 成員端拒絕、mnet 不變。

## 3. MINOR

1. **重新邀請走 +1 版時,舊 me 仍被沿用。** §3.6-2 的「me 在新版 removed 就不沿用」只寫在 TooOld 取代那條。被移除者只落後一版(mnet v1、邀請 v2)時,`existing()` 走 +1 路(approve.rs:303-308),同 DAC 時沿用舊 me,包括舊的 state(approve.rs:319-320)。同意包的 members = k8 = v2,而他在 v2 的 removed 裡。修法:+1 路也套同一條(me 在同意包 members 的 removed → 新的 joining 項)。T17 加這一臂。
2. **approve 匯入時 mnet k9 怎麼更新沒寫。** §2.2 只寫「從第一次匯入起」;+1 版的 approve 匯入、TooOld 取代之後 k9 是保留、補一項還是重設,都沒寫。歷代中間缺一版時,§3.4-2 的「逐 byte 比對」也沒定義。這是分叉偵測,不是信任錨(錨是 mnet k3 的 admins + prev_hash),所以是 MINOR。修法:approve 匯入時 k9 加上新的 k3 / k4(取代時重設為只有這一版);缺的那一版當作「沒有,不比」。
3. **紀錄回滾的說法太滿。** §6「紀錄回滾(k9 檢查;一台都連不上不開始)」:只要有一台連得上的自己節點也停在舊版,而 v 版的那台連不上,就會重簽同一個版號(F18 分叉;§3.2 判「k9 = 目前就成功」的前提也跟著失效)。store.rs:8-11 寫明只有 root 做得到,而 root 本來就能直接叫金鑰。修法:§6 改寫為「只擋得住部分情況;回滾要 root,與被攻陷的 OS 同一條誠實界線」,不加機制。
4. **creator() 會隨歷代修剪而換人。** §2.1「creator = k13 最舊一項的 members 第一筆」:保留 32 版、修剪之後,最舊一項的第一筆可能是另一個人的節點(建立者被排除時),forget 保護就落到別人身上。修法:修剪時保留最舊那一項;或寫明 creator 只用在 first-join 與 forget,修剪後的後果只是畫面上的。
5. **build 閘門要寫全。** 遠端邀請 / 成員路徑只在 dev-trust(invite.rs:12),所以正式版沒有隊員,只會有「排除自己的一台」。要寫明:哪些入口在正式版開放(移除一個人?排除自己的一台?kind 4 匯入?)。再加一個負測:非 dev-trust build 的 bridge 拒絕 kind 4(比照邀請)。另外,k4 規則在正式版是 fail-closed,「排除自己的一台」在正式版等於不能用,這點要寫明(§9 checklist 已經有一部分)。
6. **「之前被移出過」的提示分不出是哪一台。** 移除一個人時,他所有的 DAC 都進 removed。他之後回來,每一台都會跳這句,網主很快就會習慣直接按掉。被抓的那台若混在其中,網主認不出來。修法:提示裡帶 device_id 後 4 碼(§3.1 已經有顯示格式),讓網主對得上遺失的那台。
7. **剪貼簿衛生。** 包裡沒有明文秘密 ✅,但 net_secrets / member_secrets 的密文和名冊會留在剪貼簿歷史,也可能經同步送到別台裝置。修法:複製時標成敏感內容(ClipDescription EXTRA_IS_SENSITIVE,Android 13+);匯入成功後清空剪貼簿。成本很低。
8. **生命週期缺「節點降級到 wsl.24」一列。** NU:139 說降級後 F10 漏洞重新出現。§3.2 每次送之前都重新檢查 k4,所以 app 會擋。已經換好的節點降級後,被移除者算不出它的新 psk_member(net_root 已換),開不了成員連線,所以 F10 實際上只威脅還沒換好的節點,與前置 5 同一條界線。加一列,寫明結論與 T5 的 k4 分支就是它的測試。
9. **k4 規則的邊界。** `-wsl\.(\d+)` 的數字溢位或過長要算不通過;版本字串取第一個匹配。T5 的 k4 三種情況要再加「數字溢位」。另外,「wsl.25 一定包含 fbc01ae 的修正」這個前提,要在 §1 加一條證據(哪個 build 號開始帶 F10 的修正)。
10. **§3.4 規則 6 的句子會冤枉人。** mnet k7 被網主「忘記」(R18)時,它不在 members,畫面會說「你已被移出這個網路」,但他其實沒被移除。改成通用句:「你這台節點不在新的成員名單裡,請向網主確認」。

## 4. 依角色的結論

| 角色 | 結論 |
|---|---|
| 被移除的人(舊 mnet / net_root / psk_member、他的節點、攔到的包、偽造的重新邀請) | 拿不到新 secrets ✅:加密給別人的 DAC / owner_enc_pub,而且綁版本。新 net_root 讓他算不出新 psk。偽造的同 net_id 邀請:TooOld 取代要舊 admins 簽,+1 路也要舊 admins 簽(approve.rs:303-308)✅。把攔到的包轉給別人的節點只會幫對方更新 ✅。殘留:wsl.24 污染(只靠網主勾選,已接受的誠實界線)、MINOR-1 |
| 其他留下的成員 | 偽造不了網主簽章、改不了別人的 mnet ✅ |
| 讀 / 換剪貼簿的 app | 看得到名冊(誠實界線)、換掉內容只會被拒(DoS)✅;MINOR-7 |
| 惡意 app / 被攻陷的 OS | 與今天相同 ✅;回滾 → MINOR-3 |
| 網主手機遺失 | ADMIN_SIGN 沒有使用者驗證,誠實界線 + checklist ✅ |
| 成員手機遺失 | 移除那個人,其他節點用新手機重新認領 ✅ |
| 節點被抓:成員的 | 移除整個人 ✅;他回來時的提示 → MINOR-6 |
| 節點被抓:網主自己的 | **B1** |
| 我們自己的錯 | 同版只簽一次 ✅;送錯 DAC ✅(pin + 依 dac_hash);k4 規則 fail-closed ✅(正式版不能用 → MINOR-5);降級 ✅(T10);測試路徑漏進正式版:第三人的 `dev:` DAC 在非 dev-trust build 會被 nodecert 拒(nodecert.rs:146;tests/member.rs:557)✅,kind 4 的 build 閘門要測 → MINOR-5;產包規則 → **M1** |

## 5. 前兩輪逐項確認(讀完自己的審查之後才讀)

| 項目 | v3 | 確認 |
|---|---|---|
| 第 1 輪 A-BLOCKER-1 / B-M4(k10 推進) | k10 只在同意時設 | ✅;但產包端的拒絕 → 本輪 M1 |
| 第 1 輪 A-M1 / B-M2(舊邀請) | k12 全標 used;通用句 | ✅ |
| 第 1 輪 A-M2 / B-M3(重新加入) | §3.6 三步 | ✅;+1 路沿用 me → MINOR-1 |
| 第 1 輪 A-M3 / B-M6(版號) | §2.4 | ✅;回滾的說法 → MINOR-3 |
| 第 1 輪 A-M4 / B-M7(wsl.24) | 前置 4、5;§3.5 提示 | ✅(已接受的誠實界線) |
| 第 1 輪 A-M5 / B-m10(共用規則) | §3.5 | ✅;排除的節點 → **B1** |
| 第 1 輪 B-M1(secrets 要簽) | §3.4-3 | ✅ |
| 第 1 輪 B-M5(一人多台) | mnet k10 | ✅ |
| 第 1 輪 B-M8 / B-M9 | §3.5 末;T14 | ✅ |
| 第 1 輪 B-m3(kind 4 上限) | 128 KiB / 16 步 | ✅ |
| 第 1 輪 B-m4(網主手機) | 誠實界線 + checklist | ✅ |
| 第 1 輪 B-m7(dev-trust 閘門) | §0 | ⚠️ 只寫了 kind 4;正式版開放哪些入口 → MINOR-5 |
| 第 1 輪 B-m12(members prev_hash) | §3.4-2 | ✅ |
| 第 1 輪 A-m1 至 A-m18 | 各處 | ✅ |
| 第 2 輪 A-M1(先換自己的節點) | commit 後不送;T19 | ✅ |
| 第 2 輪 A-M2 / B-m11(鏈長) | start 公式 | ⚠️ 網主端的拒絕讓原情境回來 → **M1** |
| 第 2 輪 B-M1(偽造重新邀請) | 舊 admins 簽、net_id 相同、version 較大;拿掉「k7 不在 members」 | ✅;+1 路 → MINOR-1 |
| 第 2 輪 B-M2(wsl.24 污染) | 前置 5;§3.2 例外;§3.5 提示 | ✅(誠實界線) |
| 第 2 輪 B-M3(缺 k10) | 缺 = 最舊 | ✅ |
| 第 2 輪 B-M4(網主自己的節點) | 使用者決定可排除 | ✅ 範圍;實作有洞 → **B1** |
| 第 2 輪 A-m1 / B-m2 | §2.4 | ✅ |
| 第 2 輪 A-m2 / B-m6(k4 規則) | §3.6 正文 | ✅;邊界 → MINOR-9 |
| 第 2 輪 A-m3 至 A-m14 | 各處 | ✅ |
| 第 2 輪 B-m1 / m3 / m4 / m5 / m7 / m8 / m9 / m10 / m12 / m13 | 各處 | ✅;m3 的歷代缺口在 approve 匯入時 → MINOR-2 |

## 6. 判定

1 BLOCKER / 1 MAJOR / 10 MINOR → **REJECT(小改)**。B1 要加一條比對:目標必須在目前 members 而且不在 removed,網主的送、join2 與隊員模式加入都要套,並附負對照。M1 要刪掉網主端的拒絕。改完之後整份重審。
