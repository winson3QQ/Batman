# #254 app — second node joins the phone's network (S1.5)

狀態:**凍結 v7.1(2026-11-10)**。審查七輪,每輪兩位:v1 A 4 / B 3 MAJOR;v2 A 3 / B 3;v3 A 2 / B 1;v4 A 1 / B 0;v5 A 1 / B 0;v6 A 1 / B 1;**v7 A APPROVE / B APPROVE(0 MAJOR)**。v7.1 = v7 + 第 7 輪 MINOR(附錄 A「v7 輪」)。
v4 = v3 再**刪兩個東西**(前置「已在網路就擋」、存 secrets + ecdh 比對)並把 CAS 世代、確認網路、國家改回、已連上的判定寫清楚;處理見附錄 A。
方針:少一個機制比多一個好(使用者規則「只做必要的修改」)。
上層:`254-app-s1.md` v8.5.1(凍結;§1 列為不做,§5.4 已定格式)。使用者:接著做第二台入網;只有一支 Android 手機。

## 0. 一句話
同一支手機(網路唯一 admin、各節點唯一擁有者)登入未入網的節點,用手機裡**已確認**的 net 紀錄,為它重新加密 net_secrets,送 `network/join`;
它用**同一份已簽的 net_config v1**加入同一個 mesh。結果:「已套用」(協定確認)與「已連上」(看到同網鄰居)。

## 1. 範圍
**做**:第 N 台入網(含國家檢查與確定失敗時改回);確認網路(升紀錄狀態);net 紀錄 key 11 成員清單;紀錄寫入 CAS;`list_nets`;忘記加入中。
**不做(寫進 #254 checklist,附修復路徑)**:
- 成員表 v2 + 各台 `network/update`。偏離 219 §7.5「加成員 = 出新版本」:目前無害(節點不讀成員表;psk_member 由 net_root + net_id + version 導出,各台相同);
  P3 的 member app 驗對方 DAC 在成員表、`peers/challenge` 在 v2 前會把新成員當外人。修復不需重加入(各台存同一份 v1、prevHash 相同,v1→v2 鏈都收)。
- 移除節點 / 換金鑰(§8)。§5.4 自動重試(另一項)。多 admin、iOS。

## 2. 事實(main 832fbf8;feat/254-p3 e5c89a1;app 36e2f57 / 55ea0d8;兩位審查者三輪核對)
| # | 事實 | 證據 |
|---|---|---|
| F1 | `network/join` 只在節點不在網路時接受,否則 E_STALE_VERSION = 5 | node.go netJoin(main :1002-1003) |
| F2 | net_config 以自己 key 8 的 admins 驗簽;版本 1..2^32-1 | node.go netJoin / adminsOf / parseNet :954 |
| F3 | join 的 key 2(成員表)不讀;applyNet 不寫成員;mesh_expect 只看 state | node.go :1004-1005、:1131-1137;boot.go :365 |
| F4 | net_secrets 的 key 3 必須 = SHA256(本機 DAC pub)(wtxn.go :127-131,否則 → 4);secrets 的 net_id ‖ version 進 KDF;節點不比對它與 netcfg | wtxn.go :133-142;node.go :984 |
| F5 | applyNet 只把 SAE / mesh_id / channel 交給 setkey;psk_member 各台相同 | node.go :1144、:399-403 |
| F6 | 頻道依節點自己的國家驗;netJoin 不比國家;P3 改國家只在 `rec.Net == nil`(reason 14)、legacy → reason 20,**這兩個在動 radio 之前就擋下**;EApply 對映成 11,**帶 reason 時保留**(setkey rc 2 / 3 / 6 都是 E_REJECTED{2: 13},線上分不出「已還原」與「還原沒驗過」);setkey rc 4 → E_STORAGE(10) | halow-setkey :88-100;P3 settingsset.go :34-56、:113-124;session.go :47、:571-576、:905-908;apply_reason_test.go |
| F7 | 本次登入的 node_cert 以釘住的 DAC 驗過 | loginflow.rs :54-55、:152 |
| F8 | 建網只在直接收到 Applied 時寫 applied;ReadInfo / check_network 只顯示;check_network 用 session 記憶體的 net_id | owner.rs :333-338、:437-446 |
| F9 | 紀錄檔頭 "BMR" ‖ ver ‖ gen(u64 BE),AAD 含 gen;`write` 不比對世代;claim.rs / simple.rs 以 next_generation / 固定 1 呼叫 write | store.rs :7-8、:45-51、:101-125;claim.rs :78-84;simple.rs :53 |
| F10 | 紀錄 key 8 = members v1 Sign1(成員 key:1 dac_hash 2 ecdh 3 name 4 owner_pub 5 owner_enc),key 9 = 第一台 secrets;**36e2f57 沒有任何 net/ 讀取者** | owner.rs :116-133;cose.rs :105-111 |
| F11 | info 9 / 10 / 11 只給 owner / member;key 11 = TxnPresent(save 失敗時 .txn 留到下次開機);`join_state` 不看 key 9 | server.go :536-551;readonly.go :131;flow.rs :121-150 |
| F12 | status key 3 鄰居數(Neighbours 為 nil 時缺)/ key 15(owner)plinks、age_s、join.state;plinks 選填;stale → key 15 = {stale: true};key 3、plinks、join.state 都來自同一份 halow-status 快取(≤ 30 s,age_s 標出),join.state 另依 joinwatch 每 15 s 的狀態檔 | P3 status.go :22-31、:180-226;joinwatch :36;halow-status :19、:38 |
| F13 | 未入網節點的 radio 被 keyguard 擋住(沒有 placeholder mesh 鄰居) | wtxn.go :51 |
| F15 | 7 有三種來源:試用開機 / OTA 寫入中(dispatch,節點沒動,無 detail);provd 等不到 helper(detail key 3 = "outcome unknown");**請求送出後 helper 斷線(ErrGone,無 detail)**— 後兩種節點可能已經改了。所以 7 不分 detail 一律「結果不明,先讀」。verdict 未知 → EState → 11(這時 settings.set 也同樣被擋,改回國家會失敗 = 預期) | node.go :238-248;session.go :574-609;helper.go :137-141、:222;server.go :22 |
| F14 | 04 建網實測:v1 自簽、`bm-<net_id[..6]>`、ch 40 → member,`network: applied` | #254 comment 6753077927 |

⚠️ 只有真機能證:同網兩台成為 batman 鄰居、加入到看見鄰居要多久、第一台關機時加入 / 回來後連上(T5)。

## 3. 設計
### 3.1 紀錄
- key 1–10 不變;**key 11 = 成員清單**,一項 = `{1 dac_pub_hash, 2 ecdh_pub, 3 name, 4 owner_pub, 5 owner_enc_pub, 6 device_id(可缺), 8 state, 9 prev_country(可缺)}`。
  key 1–5 與 members v1 的成員 key 同號;state ∈ {joining, applied};**不存 net_secrets**(每次送出重新產生,§3.3-3)。
- **成員身分 = dac_pub_hash**:同一台永遠只有一項(取代,不新增)。
- **建網**(改既有):Applied 時一併寫 key 11 = [第一台 applied]。
- **舊紀錄(無 key 11)**:從 key 8 解出第一台 1–5,device_id 缺,state = 紀錄 key 10 是 applied → applied,其他(pending)→ joining。
- **CAS**:新增 `Store::write_cas(rel, expected_gen, sealed)`:process 全域 Mutex 內讀檔頭世代 = expected_gen 才寫,以 **expected_gen + 1** 寫入(檔頭由 write 自己寫;
  sealed 是不透明密文);Kotlin 封裝用的 AAD 取自同一個 OwnerStep.generation = expected_gen + 1(Rust 唯一決定世代)。檔頭世代不符 → 停,「紀錄已被別處更新,請重新開啟再試」。**expected_gen 來自讀紀錄時 `store_read_sealed` 回傳的 generation**,一路傳進 join / 確認網路 / 忘記;同一流程的下一次寫入用上一次成功寫入的世代。
  既有的 `write`(claim、marker、node 紀錄)不變。applied 那次 CAS 失敗可恢復(重送 → 5 → info → 已套用)。
- `list_nets(dir)`(檔名,不開紀錄)。Dart 不 log、不顯示紀錄位元組。

### 3.2 確認網路(F8:建網回覆遺失 → 紀錄卡 pending)
登入任一節點 →「確認網路」→ 選一筆本機紀錄 → 讀 info,用**紀錄的** net_id:key 10 = net_id **且 key 9 = netcfg version**(實作另加比對,`join_state` 不看 key 9)→
紀錄升 applied,其中推導 / 既有的建網節點成員項也升 applied(CAS)。key 11 = true(.txn 還在,p5 已是提交點)也算已套用,另顯示「存檔要等這台節點下次開機才完成」。
其他(key 10 缺 / 不同)→ 不改。**不新增成員項**(防謊報 key 10 的節點混進成員清單)。建網的 ReadInfo / check_network 改走這裡。

### 3.3 加入(`OwnerSession.request_join_network(record_plain, record_gen, admin_pub)`)
1. 前置,任一不成立 → 停,什麼都不寫、不送:a 紀錄解得開且 state = applied;b 本次登入有 `Verified`;c 紀錄 netcfg key 8 含本機 admin_pub;
   d 成員數(**不算同一個 dac_hash 的舊項**)< 16(app 實務上限;節點無上限)。
   (「這台已在網路」不在前置擋:節點回 5 → info 判定;重燒 / 送修回來的同一台照常加入並取代舊項。)
2. **secrets 先做好**(每次送出都重新產生):netcfg 的 net_id、version(從已簽 netcfg 解出),同 SAE / net_root,ECDH-ES 給本次 Verified 的 ecdh_pub,
   key 3 = SHA256(本台 DAC pub);admin Sign1。**簽章失敗 → 停,這時還沒有寫入、也沒改國家**。
3. **國家**,對照**紀錄 netcfg 的 key 5**:
   - `settings/get` 回 E_UNSUPPORTED 且 detail = {1: "settings/get"}、沒有 reason → P2 → 繼續,結果標「國家未驗證」。其他錯誤 → 停。
   - 相同 → 繼續。不同 → 「這台的國家是 XX,要改成 YY 才能加入」,使用者確認 → 先寫成員項 joining + prev_country = XX(CAS)→ `settings/set` YY:
     回 0 → 繼續。**明確拒絕只有 reason 14 / 20**(動 radio 之前就擋下,F6)→ 成員項**回到寫入前的樣子**(原本沒有 → 刪;原本是 applied 等 → 還原),停。
     **其他任何回覆**(11 不論有無 reason、7 不論有無 detail、10、斷線、逾時)→ 讀 `settings/get`:等於 YY → 繼續;其他(含等於 XX:helper 斷線時
     halow-setkey 可能還在跑,讀到的是舊值)/ 讀不到 → **保留成員項與 prev_country**,停,顯示「國家狀態不明,稍後在這台按『繼續加入』」
     (之後改回時若已是原值,只會清掉 prev_country)。
   - **改回只在確定失敗時**:回 4、OtherNetwork、NotApplied、送出前放棄 → 先 `settings/get`:已經等於 prev_country → 只清除 prev_country;否則 `settings/set` prev_country;
     **改回失敗 → 成員項與 prev_country 保留**(不刪),顯示「國家可能仍是 YY,原本是 XX,未能改回;稍後在這台按『繼續加入』或手動改回」。
     **沒有 prev_country(國家本來就相同)→ 確定失敗時直接刪成員項。**
     回 7、InProgress、Unknown、斷線且讀不到 info → 不改回(節點可能正在套用、已加入或稍後可再試),保留 prev_country,下次登入此台再判斷。
4. PersistNet(CAS):成員項 joining(**取代同 dac_hash 的舊項,保留其 prev_country**)— 落地後才送。
5. op/nonce → owner-op → `network/join` {1: 紀錄裡原封不動的已簽 netcfg, 2: 紀錄的 members, 3: secrets}。
6. 回覆:
   - 0 → **已套用**;成員項 applied(CAS),prev_country 清除。
   - 3 → 新 op/nonce,重送一次(secrets 重新產生)。
   - 4 → 「節點不接受這份網路設定(回覆碼 4)」,國家改回(改回成功才刪成員項)。
   - 5 → 讀 info:key 10 = 本 net_id → 已套用;不同 → 「這台已在別的網路」,國家改回(改回成功才刪成員項);缺 → 保持 joining。
   - **7 → 讀 info**:Applied → 已套用;其他 → 保持 joining,不改回國家;文字一律「結果不明(節點可能正在更新或連線中斷),稍後在這台按『繼續加入』」(F15:無 detail 的 7 也可能是 helper 斷線)。
   - 11 / 其他 / 斷線 / 逾時 → 讀 info(`join_state`):Applied → 已套用;**NotApplied → 「節點沒有套用這個網路(回覆碼 N)。常見原因:國家或頻道不合、
     無線電被關、手動改過網路設定、節點剛更新完還沒穩定」,國家改回(改回成功才刪成員項)**;InProgress(key 10 缺、key 11 true)/ Unknown / 讀不到 info → 保持 joining。
7. **已連上**(owner 的 P3 節點):join 回 0 後每 10 s 讀 `status`,直到視窗結束;**已連上 = 同一次回覆中 key 15 不是 stale、`age_s` < 自 join 回覆起的秒數、
   plinks 存在且 > 0、key 3 存在且 > 0**(不靠 JOINED)。視窗 = T5 實測「加入 → 已連上」時間的 2 倍(實測前暫定 120 s)。
   視窗內未成立 → 「已套用,還沒看到其他成員(請確認其他節點已開機、在範圍內)」;stale / plinks 缺 / key 3 缺 / 讀不到 → 「已套用,連線狀態未知」。P2 → 只「已套用」。

### 3.4 繼續加入 / 忘記
- 「繼續加入」= 從步驟 2 再走一次(國家已改的不會再改,secrets 重新產生)。
- 「忘記加入中」:刪 joining 成員項(CAS);有 prev_country 時提示「這台的國家可能仍是 YY」。

## 4. 擁有權
| 資源 | 唯一寫者 | 讀者 |
|---|---|---|
| `net/<net_id>` 紀錄 | app 紀錄儲存層(Rust 產明文、Kotlin 封裝、`write_cas`) | app |
| 被加入節點的 p5 / overlay / wireless / 國家 | 該節點 helper(applyNet / halow-setkey) | — |
| 其他成員節點 | **不動**(確認網路只讀 info) | — |
| admin 金鑰 | Keystore(只簽 COSE Sig_structure) | — |

## 5. 契約
| 介面 | 寫 → 讀 | 格式 | 缺 / 舊 / 壞 |
|---|---|---|---|
| net 紀錄 | Rust → Kotlin → store → Kotlin → Rust | §3.1;AAD = 路徑 + 世代;write_cas | 解不開 / state 不對 / 世代不符 → 停;無 key 11 → §3.1 推導 |
| `network/join` | app → provd → helper | CDDL net-join | 節點驗 F2、F4;錯 → 4 |
| net_secrets | app → 被加入節點 | F4;net_id / version = netcfg 的 | 給錯台 → 4 |
| info 9 / 10 / 11 | 節點 → app | CDDL info | 缺 → 不改紀錄 / 保持 joining |
| status key 3 / 15 | 節點 → app(owner) | P3 status | stale / plinks 缺 → 「連線狀態未知」 |

## 6. 生命週期
| 路徑 | 之後 | 證明 |
|---|---|---|
| 未入網 → join | 已套用 → 已連上 | T1、T5 |
| 第一台關機時加入 | 已套用,還沒看到其他成員;第一台回來 → 鄰居 | T5 arm b |
| 回覆遺失 / 斷線 / 逾時 / 手機重開 | info → 已套用 / 無法套用 / 保持 joining | T3 |
| 已加入的節點再加(回 5,同 net_id) | 已套用 | T4 arm a |
| 在別的網路(回 5) | 別的網路,刪項,國家改回 | T4 arm b |
| 已套用成員重燒 / 送修回來(DAC 不變) | 照常加入,取代舊項 | T2 d 臂改、T5 選測 |
| 建網回覆遺失(pending) | 確認網路 → applied(含 .txn 未完成) | T6 |
| 國家不同(P3) | 先記 prev_country → 改 → join;確定失敗 → 改回;不明 → 保留,下次再判 | T7 |
| P2 / legacy / 其他 settings 錯誤 | P2 → 標未驗證;legacy / 其他 → 停 | T7 |
| P2 頻道不合法(國家未驗證) | 11 → info NotApplied → 「無法套用(國家或頻道)」 | T3 |
| admin 金鑰遺失 | SignAdmin 失敗,在寫入與改國家之前 → 沒寫、沒改、沒送 | T8 |
| app 重裝 / 紀錄 AES 遺失 | 不能再加節點;提示「新建網路會讓整隊分成兩個網路,舊節點要重燒」 | T8 |
| app 降版 | 舊版(36e2f57)不讀 net/,不會覆寫 | F10 |
| 被加入節點在試用開機 / OTA 寫入中 | 回 7 → 保持加入中,稍後「繼續加入」;國家不改回 | T3 7 臂 |
| 換掉第一台 | 同流程加新的一台 | — |
| 被加入節點斷電在 apply 中 | 節點 .txn 收尾(既有) | 既有 P2 測試 |
| 平台 | 只 Android | — |

## 7. 測試(每一項有負對照)
- T1(Rust):步驟序列;body key 1 = 紀錄 netcfg 逐位元組;secrets 以本台 ecdh 解得開、key 3 = 本台 DAC hash、net_id / version = netcfg 的;顯示文字與 log 不含 SAE。
  負對照:加密給第一台 / version 用 2 → FAIL。
- T2(Rust):前置 a–d 各一臂 → 拒,沒有寫入 / 送出。負對照:a–d 各自一個突變 → 對應臂 FAIL。
- T3(Rust 假回應):§3.3-6 每一列(含 11 → NotApplied → 沒有套用 + 國家改回;InProgress → 保持;**7 → info:Applied → 已套用,其他 → 保持、不改回**)。負對照:拿掉「11 → info」/ 7 不讀 info / 7 當 NotApplied → FAIL。
- T4(Rust 假回應):5 → info,arm a 同 net_id → 已套用,arm b 不同 → 別的網路。負對照:5 直接判別的網路 → arm a FAIL。
- T5(真機,**需 02 接網路線**):join 前兩台不是鄰居;join 後互為鄰居、互 ping、info key 10 相同;第一台 p5 世代 / uptime 不變;**量「join 回覆 → 已連上」秒數**;
  arm b 第一台斷電時加入 → 0 鄰居,開機後 → 鄰居。負對照:第二台用另一筆紀錄加入 → 不成為鄰居(證明「網路設定不同就不會成為鄰居」,不單獨證明 SAE)。
- T6(Rust 假回應):pending → 確認網路(key 10 / key 9 相符)→ applied;key 9 不同 → 不升;key 11 = true → 升 + 提示。負對照:今天的程式 → 仍 pending;拿掉 key 9 比對 → 該臂 FAIL。
- T7(Rust 假回應):settings/get JP → 先寫 prev_country、再 settings/set {2: netcfg key 5};使用者拒絕 → 沒有 join;回 4 / NotApplied → settings/set 原值;
  斷線且讀不到 info → 不改回;settings/set YY 被拒(reason 14 / 20)→ 刪項、不送 settings/set 原值;**settings/set 回 11 / 11{2:13} / 7(有無 detail)/ 斷線 → settings/get:
  XX → 刪項,YY → 繼續,讀不到 → 保留項與 prev_country**;改回失敗 → 項與 prev_country 保留、文字含 XX;
  改回前 settings/get 已是原值 → 不送 set;**重建 session、只從 store 讀紀錄後回 NotApplied → 仍改回原值**;
  settings/get E_UNSUPPORTED{1:"settings/get"} → 繼續 + 標未驗證;其他錯誤 / reason 20 → 停。負對照:拿掉國家步驟 → FAIL;prev_country 只存記憶體 → 重建臂 FAIL;set 回 11 / 13 就刪項 → 該臂 FAIL;改回失敗就刪項 → 該臂 FAIL。
- T8(Rust):admin 簽章失敗(國家相同 / 不同兩臂)→ 沒有寫入、沒有 settings/set。負對照:國家步驟在簽章前的版本 → 不同臂 FAIL。
- T9(Rust):36e2f57 產生的舊紀錄(pending 與 applied 各一)→ 推導出第一台,state 對應正確。負對照:pending 對應成 applied → FAIL。
- T10(Rust):`write_cas`:讀紀錄後、PersistNet 前,另一次寫入改了紀錄 → 這次加入停止、不送出;寫入後以 aad(rel, expected + 1) 讀回解得開。負對照:在寫入時才取世代 → 該臂 FAIL。忘記加入中 → 刪項、世代 +1。
- T11(Rust 假回應):已連上 —— stale、age_s 早於 join、plinks 缺 / 0、key 3 缺 / 0 → 不判已連上。負對照:只看 key 3 → FAIL。

## 8. 安全
- 資產:SAE / net_root。只在手機 net 紀錄(Keystore 封裝)與加密給本次登入驗過 node_cert 的節點的 net_secrets;**v4 起紀錄的成員項不再存 secrets**。
- 新輸入:選紀錄(本機)、被加入節點的 node_cert(已驗)、P3 的 settings/get、status(owner session)。節點端零改動。
- 攻擊:冒充節點 → 登入失敗;重放 → owner-op nonce;謊報 info key 10 → 確認網路只升狀態,不加成員;本機其他 app → 私有目錄 + Keystore;Dart 不 log 紀錄。
- **誠實界線**:每加一台,SAE / net_root 就多一份在節點未加密的 rootfs;沒有換金鑰路徑 → 一台遺失 = 全網金鑰外流,唯一補救是整網重建。寫進 #254 checklist。
- 失敗模式:fail-closed(§3.3-1、T2、T8);國家只在確定失敗時改回。

## 9. 待使用者決定
- 02 接網路線(T5)。成員表 v2 / 換金鑰延後(§1)。

## 附錄 A. 審查處理(v3 輪;v1 / v2 輪見 v3 文件 254-app-join2-v3.md)
| 項目 | 處理 |
|---|---|
| A M1 CAS 預期世代沒有來源 | §3.1 expected_gen 來自讀紀錄、write_cas 斷言 sealed = expected + 1;T10 讀後被改臂 |
| A M2 / B M1 前置 d 擋住重燒的成員 | **刪掉前置 d**;5 → info 判定;§6 加「重燒 / 送修回來」列 |
| A m1 / B m4 國家改回時機、原值只在記憶體 | §3.3-2 只在確定失敗改回;prev_country 存成員項 |
| A m2 / B m7 舊紀錄 state、建網寫 key 11、確認時升成員項 | §3.1、§3.2 |
| A m3 plinks 選填、stale 先排除、60 s 無據 | §3.3-7、T11;視窗 = T5 實測 2 倍 |
| A m4 ecdh 重燒不一定變 | 不再比對 ecdh:每次重新產生 secrets(B m9) |
| A m5 / B m2 key 9、.txn 卡 pending | §3.2 key 9 另比、key 11 true 也升;T6 臂 |
| B m3 P2 頻道不合法 → 11 → NotApplied | §3.3-6 NotApplied 列、T3 |
| B m5 JOINED 落後 | §3.3-7 改用同次取樣 plinks + key 3 |
| B m6 T9 後半一定過 | 刪;§6 降版列改「舊版不讀 net/」 |
| B m8 CAS 的簽名 / 影響其他呼叫端 | §3.3 簽名帶 record_gen;§3.1 新增 write_cas,既有 write 不變 |
| B m9 存 secrets + ecdh 比對可刪 | **刪**;§3.3-3 每次重新產生 |
| B m10 P2 判定 | §3.3-2 比對 detail {1:"settings/get"}、無 reason |

### v4 輪
| 項目 | 處理 |
|---|---|
| A M1 7 / EState 被當成國家或頻道 | §3.3-6 7 → 保持、不改回;NotApplied 文字列出常見原因、帶回覆碼;§6 試用開機列改正;F15;T3 7 臂 |
| A m1 斷線改不改回矛盾 | §3.3-3「斷線且讀不到 info → 不改回」,T7 同 |
| A m2 / B m1 write_cas 的 sealed 世代 | §3.1 以 expected + 1 寫入、AAD 同源;T10 改讀回臂 |
| A m3 / B m3 settings/set 失敗、放棄的成員項 | §3.3-3 刪剛寫的項;只有 set 回 0 過才需改回 |
| A m4 key 3 缺 | §3.3-7、T11 |
| A m5 F12 措辭 | F12 改 |
| B m2 取代時丟 prev_country | §3.3-4 保留;T7 重建 session 臂 |
| B m4 簽章在改國家之後 | §3.3 先簽(步驟 2)再國家(步驟 3);T8 兩臂 |
| B m5 上限擋住取代 | §3.3-1d 不算同 dac_hash |
| B m6 NotApplied 文案 | §3.3-6 列出常見原因 |

### v5 輪
| 項目 | 處理 |
|---|---|
| A M1 / B m2 settings/set 模糊回覆被當成「沒動」→ 刪掉 prev_country | §3.3-3 只有明確拒絕才刪;其他先 settings/get 再決定;T7 臂 |
| A m2 / B m1 join 回 7 不一定是忙碌 | §3.3-6 7 → 讀 info;F15 改寫;T3 臂 |
| A m3 EState 時改回必失敗 | F15 寫明為預期 |
| B m3 有 prev_country ≠ 已改過 | 改回前 settings/get;忘記的文字改「可能」 |
| B m4 T9 無負對照 | T9 加 |

### v6 輪
| 項目 | 處理 |
|---|---|
| A M1 / B M1 11{2:13} 與 7(無 detail)被列為明確拒絕 | §3.3-3 明確拒絕只剩 reason 14 / 20,其他一律 settings/get;F6、F15 改寫;T7 臂 |
| A m1 / B m1 「4 = setkey 已還原」錯(rc 4 = E_STORAGE 10) | 字眼刪除(落在「其他 → get」) |
| B m2 EState 時改回失敗、prev_country 被刪 | 改回失敗 → 保留項與 prev_country,文字含原值 XX |

### v7 輪(兩位 APPROVE)
| 項目 | 處理 |
|---|---|
| A m1 / B m2 明確拒絕時刪掉被取代的 applied 項 | 回到寫入前的成員項 |
| A m2 7 的文字 | 統一「結果不明」 |
| B m1 settings/get 讀到 XX 也可能是舊值 | 結果不明時一律保留項與 prev_country |
| B m3 沒有 prev_country 時 | 確定失敗直接刪項 |
