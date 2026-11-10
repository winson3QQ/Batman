# #254 app — 隊員節點入網(§7.6 遠端邀請)實作對照表 v6.1

狀態:**凍結 v6.1(2026-11-10)**。審查六輪,每輪兩位(A 一致性 / B 安全),MAJOR 數:v1 A5 / B4;v2 A2 / B1;v3 A2 / B2;v4 A2 / B0;v5 A0 / B1;**v6 A0 / B0**(兩位 APPROVE-WITH-CHANGES,MINOR 已併入 v6.1)。

協定(219 §7.4 / §7.6、CDDL、P3 節點行為)已凍結,本文不重新設計,只寫「app 要做什麼、重用什麼、哪裡偏離」。
版本:app feat/254-app-s1 @ 56b628c;節點 feat/254-p3 @ e5c89a1(= wsl.24);harness main 832fbf8。⚠️ = 未驗證。
v6 = v5 + 第 5 輪文字 / 契約 / 測試臂修正(無新機制)。v5 = v4 **簡化**:隊員手機每個網路最多一筆待處理申請(`mpend/<net_id>`),刪掉多候選選擇機制(附錄 A)。
**用途限制:dev / bench 專用;遠端邀請在協定待決項(SAS 窮舉,§5-5)決定前不得進 field build。**

## 1. 決定實作的事實
| # | 事實 | 證據 |
|---|---|---|
| R1 | §7.6 四種物件都在 CDDL:invite(遠端 kind 1,不含 SAE)、join-request、approval-bundle、member-secrets;qr-object kind 1/2/3 | 219-protocol.cddl:389-395、397-406、408-415、428-440 |
| R2 | 四種物件都有測試向量(sas = "260515");app 目前標「S1 不測」 | vectors.json:98-139;app tests/vectors.rs:41、45 |
| R3 | **節點零改動**:`network/join` 只讀 key 1(netcfg 自簽)與 key 3(secrets,key 3 = 本機 DAC hash,以 netcfg admins 驗);key 2 / 4 不讀;已在網路 → 5 | node.go:1024-1040 |
| R4 | 擁有者可用 network/join、settings/get / set、status、info、op/nonce;成員角色只有 info / network/update / status | provd/session.go:77-82 |
| R5 | invite / join-request / approval 全是 app 對 app → 隊員 app 對**自己的**節點以自己的擁有者 session + owner-op 送 join | 219 §7.6;session.go:77-80 |
| R6 | status:key 1-5;key 15(owner)含 image、uptime_s、temp_c、join.{state, channel, country, snr_db, plinks}。**key 6 電量節點從不送** | status.go:182-226;cddl:243-251 |
| R7 | info key 4 = fw_version;9 / 10 / 11 只給 owner / member | server.go:544-560 |
| R8 | 網路名稱只在 netcfg payload key 4 | cddl net-config |
| R9 | `nodecert::common` 要求 s_node == rs;信任閘門在 verify_first_contact 內 | nodecert.rs:84-115、128-143 |
| R10 | cose.rs 沒有驗 Sign1 / 解密 / OBJECT_HASH;驗點樣式 `PublicKey::from_sec1_bytes` | cose.rs:37-47、135、192 |
| R11 | ECDH 在 Kotlin(`Keys.ecdh`),MainActivity 沒有 ecdh 通道;紀錄明文本來就經 Dart(open / seal) | Keys.kt:103-105;MainActivity.kt:30-85 |
| R12 | 開發版貼上:hex、貼後清空、field 拒絕 | claim.dart:3-4、48-56 |
| R13 | **`prov-bench-s0-254.sh unclaimed 04` 產生新 DAC / 序號**;要 04 插網路線 | prov-bench-s0-254.sh:68、361-373 |
| R14 | net 紀錄一台一項(dac_pub_hash);成員 state 只認 joining / applied(其他值整筆解碼失敗) | netrec.rs:4-6、122-127、217 |
| R15 | dev-trust 由 cargokit.yaml 對所有 flavor 開 | bridge/cargokit.yaml:2-11;build.gradle.kts:34-46 |
| R16 | Kotlin 簽章白名單:admin 只簽 aad ∈ {netcfg, members, secrets} 的 Sig_structure;owner 只簽三個前綴 | SignAllowList.kt:3-4、7-10、15、22-48 |
| R17 | join2 回 3:第一次 `secrets_step(true)`,第二次 TwiceRefused;取代項時保留 prev_country | join2flow.rs:590-595、323-329 |
| R18 | `write_cas` expected 0 = 新紀錄;路徑每段 ≤ 64;`store_remove` 非 CAS;56b628c 只列 node/、net/ | store.rs:44-48、132-153;claim.rs:87-89;owner.rs:35-50 |
| R19 | 原始 node_cert 只在 msg2 處理當下,Verified 只留解析欄位 | loginflow.rs:54-55、147-152;nodecert.rs:46-52 |
| R20 | `store_has_records` 只看 [node, claim-pending, net];它擋住 firstRun 重產(並刪除)金鑰 | bridge simple.rs:29-30、42-45;Keys.kt:160-176 |
| R21 | 第 v+1 版以第 v 版 admins 驗;第 1 版建立者自簽 | 219-protocol.md:314 |
| R22 | SAS 必須經另一條管道核對,不能用傳圖片的同一個聊天 | 219-protocol.md:249 |

**單節點測試(04)**:因 R13,unclaimed 後的 04 是新 DAC → bm-ca68 的**新成員**,不取代建網項(v1 前提不成立);建網項(舊身分)成孤兒,無害。
網路只有 04 → 只驗「已套用」;「已連上」要 02 接線。⚠️ 04 是否符合 unclaimed 前置(:362)由 harness 檢查。

## 2. 新的共用元件
- **`cose::verify_sign1(obj, ctype, label, admins)` / `cose::object_hash(obj)`**:tagged 18、protected 恰為 {1: -7, 3: ctype}、unprotected {}、low-s、aad = label、payload deterministic、**未知 key 拒絕,含巢狀**(invite key 4 的 netcfg 以同函式再驗;joinreq key 2 的 node_cert 嚴格解析)。OBJECT_HASH = SHA-256(Sig_structure)。
- **`cose::decrypt(…, z)`**(§7.3 參數)與 **`cose::recipient_eph(enc)`**:只對已通過 verify_sign1 的物件取臨時公鑰,`from_sec1_bytes` 驗點才輸出。
- **ECDH 邊界(誠實版)**:z 走 Kotlin → Dart → Rust,net_root 明文以紀錄明文形式經 Dart 封裝(同 R11 record_plain 等級)。只在記憶體、不 log、不顯示、用完清零;**清零是盡力而為**(codec / FRB / GC 副本)。
- **MainActivity `ecdh` 通道**:`!BuildConfig.DEV_TRUST` → 錯誤。Kotlin 只檢查格式:恰 65 B、首位元組 0x04、x / y < p、**直接以 BigInteger 驗 y² ≡ x³ − 3x + b (mod p)**(不依賴 provider),再以 KeyFactory + ECPublicKeySpec 建公鑰;否則錯誤。
  `Keys.ecdh(OWNER_ENC)` → 32 B;`result.success` 後清零 z;任何例外 → 錯誤,呼叫端什麼都不寫。「只傳 recipient_eph 的輸出」是 Dart 慣例,同 R16 的程序內誠實界線。
- **dev 閘門**:parse_invite、net_make_invite、request_joinreq、net_check_joinreq、net_approve、member_import_prepare / approval、request_member_join 在 `nodecert::DEV_TRUST` 為 false 時直接回錯誤。
  **誠實界線**:今天 cargokit 對所有 flavor 開 dev-trust(R15),所以 Rust 閘門要等 #255 依 flavor 接 feature 後才是 field 屏障;在那之前,屏障是啟動交叉檢查(main.dart:54-58)+ Kotlin BuildConfig 閘門 + Dart 貼上拒絕。
- **`nodecert::verify_offline(node_cert)`**:抽出信任閘門共用(非 `dev:` → Untrusted;`dev:` 且 !DEV_TRUST → Untrusted;否則 dev_rule),只跳過 s_node == rs(只失去新鮮度)。
- **loginflow 保留原始 node_cert**:`Login.node_cert_raw`,只在 :152 verify_pinned 成功後設定,隨 into_conn 交給 OwnerSession;申請只用它。
- **SignAllowList.kt**:ADMIN_LABELS += `batman-invite-v1`、`batman-msecrets-v1`;owner 另接受 aad **恰為** `batman-joinreq-v1` 的 Sig_structure(重用嚴格解析)。

## 3. 紀錄
**管理者 net/ key 12 = 發出的邀請** `[{1 invite_hash(32 B), 2 kind, 3 used}]`;invite_id = 16 B getrandom;同 hash 已在 → 拒。NetRec 加欄位,join2 所有寫入原樣帶上。不撤銷、不清理(~45 B / 張)。
成員項 state 加 **"approved"**:算進前置 d;`forget_joining` 也接受(畫面寫「只從本機清單移除,不會撤銷這台已拿到的網路金鑰」);`confirm()` 不碰;同 dac_hash 的 approved 項照 R14 取代。

**隊員 `mpend/<net_id hex>`(每個網路最多一筆)**:`{1 invite_hash, 2 invite netcfg Sign1, 3 joinreq_hash, 4 own DAC hash, 5 SHA-256(owner_enc_pub), 6 device_id, 7 joinreq Sign1}`(公開資料,仍封裝:aad("mpend/<hex>", gen))。
- 申請時:同 net_id 已有 mpend 且 key 4 = 本次 DAC hash、key 1 = 這張邀請 → 直接給 key 7(不重簽,SAS 不變;名稱照存的顯示,改名不生效);其他(含解不開)→ 發 SignOwner(sig_enc)再 SignOwner(joinreq),以**讀到的世代**覆寫
  (write_cas;不出現 STALE_RECORD 文字),畫面寫「申請已換新,要重新核對 SAS」。「再顯示申請」從 key 7 重出 hex + SAS。
- **舊申請的 approval**:approval 本身不綁 joinreq(CDDL approval-bundle 沒有該欄),所以能接受舊申請的 approval 是協定本質,不是取捨。匯入只綁 mpend 的 netcfg(逐位元組)、DAC hash、owner_enc hash;
  三者相同 → 給的是同一台節點、同一把金鑰、同一網路的秘密,可匯入(它的 SAS 與畫面上的不同,照規則核對會擋);任一不同 → 失敗。mnet key 8 存的是 mpend 的 invite_hash(僅供顯示;節點不讀 invite_id)。
- **偽造的同 net_id 邀請 I′**:貼上並申請 → 取代真的 mpend;攻擊者以自己的 admins 簽的 approval 能通過 7a 的所有密碼檢查。**唯一擋住它的是隊員端 7a 的 SAS(I′, J′) 以電話 / 當面核對**(人為閘門,§5-5 窮舉界線適用);
  使用者照做就會發現對不上。恢復:管理者發新邀請、隊員新申請(新邀請 → 新 key 1;覆寫路徑每次先重簽 sig_enc 再簽 joinreq,ECDSA 隨機 → 新 joinreq hash;若管理者已把舊邀請標 used,舊的申請會被拒)。

**隊員 `mnet/<net_id hex>`**:`{1 net_id, 2 net_version, 3 netcfg, 4 members, 5 secrets, 6 net_root, ?7 自己節點項(netrec Member 編碼), 8 invite_hash}`;封裝 aad("mnet/<hex>", gen),write_cas。
「刪項」= 去掉 key 7。**已有 mnet 時**:新 netcfg 須逐位元組相同,或 version = 既有 + 1、以既有 admins 簽、新 key 3 prev_hash = OBJECT_HASH(既有 netcfg)、新 key 1 net_id = mnet key 1(R21);落後 ≥ 2 版 → 「這支手機的網路資料太舊」(network/update 實作前的已知限制);同 version 不同位元組 / 其他 → 拒(「同編號的不同網路」);舊 key 7 的 DAC == 新 secrets key 3 → 帶上 state / prev_country;
不同 DAC 且舊項 joining 或有 prev_country → 拒(「先完成或忘記前一台」);其他 → 新 key 7 = joining、無 prev_country。匯入成功 → `store_remove` mpend/<net_id>(非 CAS,接受的 fail-closed:匯入與刪除之間若有新申請寫入,新申請會被刪 → 使用者要再按一次申請;刪失敗 → 留著無害)。
**再貼已匯入的 approval(mpend 已刪)**:7a 的 pend 可缺;此時以既有 mnet netcfg 的 admins 驗 approval 的 secrets Sign1,且與 mnet key 5 逐位元組相同且 mnet 有 key 7 → 「已匯入」(無 key 7 → 「需要新的邀請」),不寫;否則 → 「找不到申請」。
**RECORD_KINDS 加 `mnet`、`mpend`**(R20)。

| 資源 | 唯一寫者 | 讀者 |
|---|---|---|
| net/ key 11 / 12 | 管理者 app(write_cas) | 管理者 app |
| mpend/、mnet/ | 隊員 app(write_cas;mpend 刪除用 store_remove) | 隊員 app |
| 隊員節點 p5 / 國家 | 該節點 helper | — |

| 路徑 | 行為 |
|---|---|
| 安裝 / 第一次 | 無 mpend / mnet;只有 mnet / mpend、沒有 marker → store_has_records = true,金鑰不重產 |
| mpend 寫入前被殺 / 寫入後被殺、剪貼簿被蓋掉 | 重做申請 / 「再顯示申請」 |
| 匯入後、join 前被殺 | mnet key 7 joining → 「繼續加入」 |
| join 中被殺 / BLE 斷 | 照 join2(info 判定,保持 joining) |
| 再貼同一份 approval | mpend 在 → 同結果;mpend 已刪 → 驗 secrets 並與 mnet key 5 相同 → 「已匯入」,否則「找不到申請」 |
| app 重裝 | 金鑰不在 → mnet / mpend 無用;要新邀請 |
| 匯入後節點被重燒 / unclaimed | DAC 變 → 前置 c 不成立 → 「需要新的邀請」 |
| 邀請與同意之間 netcfg 換版 | 與 mpend 的不同 → 拒(network/update 實作前不會發生) |
| 降版到 56b628c | 不列 mpend/、mnet/;net/ 有 "approved" → 整筆解碼失敗,停到升版;否則 key 12 被丟 → 申請全拒(都 fail-closed) |
| 平台 | 只 Android |

## 4. 步驟 → 元件(bridge:參數 → 回傳;可寫)
| §7.6 步驟 | 誰 | Rust sans-IO | bridge | 可寫 |
|---|---|---|---|---|
| 1 出邀請 → admin Sign1 → kind 1 hex | 管理者 | `invite.rs::make_invite` | `net_make_invite(record_plain, record_gen) -> OwnerStep`(SignAdmin → PersistNet → hex) | net/ key 12(CAS 成功才給 hex) |
| 2 貼邀請:open_invite(verify_sign1 + 巢狀 netcfg 以**它自己的** admins 驗為 v1 自簽,同 node.go:1031 adminsOf(cfg);admin_pub ∈ admins;key 1 一致) | 隊員 | `invite.rs::open_invite` | `parse_invite(hex) -> InviteView{net_name, net_id_hex, invite_hash_hex}` | 無 |
| 3 認領自己的節點 | 隊員 | claimflow | 既有 | 既有 |
| 4 **先重跑 open_invite**,再用 `node_cert_raw` → joinreq owner Sign1 → mpend → kind 2 hex + SAS | 隊員 | `invite.rs::make_joinreq`、`sas()` | `OwnerSession.request_joinreq(invite_hex, name, pend_gen: u64, pend_plain: Option<Vec<u8>>) -> OwnerStep`(pend_plain 缺 = 無或解不開 → 以 pend_gen 覆寫)(SignOwner → PersistPend → {hex, sas}) | mpend/ |
| 5 貼申請:verify_sign1 以 payload owner_pub;sig_enc;key 1 = 這筆 net/ key 12 的 unused hash;verify_offline;同 DAC 已在 → 拒,除非 approved 且同 owner_pub;名稱 → SAS → 「SAS 一致」 | 管理者 | `approve.rs::check_joinreq` | `net_check_joinreq(record_plain, hex) -> JoinReqView{sas, name, device_suffix, replaces_approved, joinreq_hash}` | 無 |
| 6 同意:對同一份 record_plain 重跑步驟 5,OBJECT_HASH = joinreq_hash;secrets + msecrets → approval;used + approved 項 | 管理者 | `approve.rs::approve` | `net_approve(record_plain, record_gen, hex, joinreq_hash) -> OwnerStep`(SignAdmin ×2 → PersistNet → hex) | net/(CAS 成功才給 hex) |
| 7a Dart 先 `approval_net_id(hex)`(只解析、不信任:結果只用來選要讀的檔名 mpend/、mnet/<小寫 hex>,錯了就是讀錯檔 → 後續驗證失敗;無寫入)→ 讀 mpend/<id>、mnet/<id> → 驗(除 ECDH / AEAD)→ SAS、eph | 隊員 | `approve.rs::prepare_import` | `member_import_prepare(hex, pend: Option<(gen, plain)>, mnet: Option<plain>) -> {sas, eph_pub, pend_gen} / AlreadyImported / NoRequest` | 無 |
| 7b Kotlin `ecdh(eph_pub)` → z | 隊員 | — | MainActivity `ecdh` | 無 |
| 7c 以 7a 的同一世代重驗全部 + 使用者確認的 SAS 字串 = 由 mpend 算的 → 解 msecrets → mnet | 隊員 | `approve.rs::import` | `member_import_approval(hex, pend: (gen, plain), expected_pend_gen, mnet: Option<(plain, gen)>, z, confirmed_sas) -> OwnerStep`(PersistMnet{plain, expected_gen};世代由 Rust 決定,AAD = expected_gen + 1,同 join2 §3.1) | mnet/(CAS)後 remove mpend |
| 8 join | 隊員 | join2flow 隊員模式 | `OwnerSession.request_member_join(mnet_plain, mnet_gen) -> OwnerStep` | mnet/(CAS,PersistMnet) |
| 9 狀態頁 | 兩者 | status.rs 欄位列表 | request_status | 無 |

**管理者前置(net_make_invite、net_approve;不成立 → 不簽、不寫)**:紀錄 applied;本機 admin_pub ∈ netcfg admins;成員數(不算同 DAC 舊項,approved 也算)< 16。
**名稱**:≤ 32 B UTF-8,含 Cc / Cf(含 bidi)→ 拒;只顯示(旁附 device_id 末 6 碼),不參與判斷。
**匯入條件(7a 與 7c 都跑)**:approval key 1 缺或與 mpend netcfg 逐位元組相同;key 2 / 3 / 4 三個 Sign1 都以 mpend netcfg 的 admins 驗過;三者 net_id、version = 它的;secrets key 3 = mpend key 4;
msecrets key 3 = mpend key 5;§3 既有 mnet 規則;7c 另加:pend 的世代 = 7a 回傳的 pend_gen(保留:擋住 7a 之後 mpend 被新申請取代)、confirmed_sas = mpend 算出的、eph 在曲線上、AEAD 通過、明文恰為 `{2: bstr32}`(「version 不小於既有」已由 §3 既有 mnet 規則涵蓋)。
**join2flow 隊員模式**:記錄 = mnet;前置 a = mnet 解得開**且有 key 7**(照 join2 §3.3-1:applied 也照送,回 5 → info key 10 判定);c = mnet secrets key 3 = 本次 Verified DAC hash;d 不適用;secrets = mnet key 5 原樣(不 SignAdmin);netcfg / members = mnet key 3 / 4;
寫入一律發 **`PersistMnet`**(從不發 PersistNet);國家、prev_country、回覆判讀、已連上照 join2;**回 3 → 直接 ask_nonce(Op::Join) 重送同一份一次,再 3 → TwiceRefused**;**回 4 → 「需要新的邀請」**,照 join2 §3.3-6:先改回國家,改回成功才以 PersistMnet 去掉 key 7。

## 5. 偏離與誠實界線
1. 剪貼簿 hex 取代 QR,只在 dev / dev2;新貼上畫面在 DEV_TRUST = false 時拒絕(同 claim.dart:48-52);bridge 與 Kotlin 也擋(§2)。
2. approval key 2 用 members v1、不出 v2 —— 沿用 join2 §1 已核准偏離。
3. 管理者成員項 state "approved"(§3)。**待使用者決定**。
4. 同一張未用邀請的第二份不同申請:不記第一份、不告警,靠 SAS 閘門。記錄第一份也擋不住第 5 項。
5. **SAS 窮舉(協定待決,不在此改)**:看得到申請 J 的攻擊者可離線變換名稱或自己的擁有者金鑰(OBJECT_HASH 不含簽章,不需新 DAC),約 10^6 次便宜嘗試做出 SAS 相同的 J′ 並搶先送達。
   **遠端模式的 SAS 擋不住「看得到 J 又能送出 J′」的攻擊者** → 只供 dev / bench;協定項決定前不得進 field build(已記在 #254 留言)。
   隊員端同理:能換掉邀請(I′)的攻擊者,只被隊員 7a 的 SAS 核對擋住;核對被繞過 → **隊員的節點加入攻擊者的網路**(§3 偽造邀請)。
6. 兩個 SAS 畫面都是**畫面閘門**,文字:「請用電話或當面核對，不要在傳圖片的同一個聊天裡核對」(R22);程式只保證按下前不呼叫。
7. node_cert 不綁擁有者:受邀者可以拿別人的 node_cert 申請;管理者會把那個 DAC 記成 approved、配申請者的 owner_pub,真正的擁有者之後申請會被拒(§4 步驟 5)。
   **只有阻斷服務**:secrets 加密給受害節點的 ecdh_pub,申請者解不開;申請者照樣拿到成員層級的 net_root(同任何被同意的受邀者);管理者紀錄把受害者的 DAC 記在申請者的 owner_pub 名下。

## 6. 規格沒講、app 要決定的失敗處理(失敗 → 回到之前的狀態)
- 出邀請 / 同意:簽章或 CAS 失敗 → 不給 hex,紀錄不變。approval 遺失 → 新邀請、新申請(同 DAC、同 owner_pub 的 approved 項可取代)。
- 匯入:任一條件不成立、ecdh 失敗、AEAD 失敗 → 不寫;join 失敗照 join2 + §4。
- 剪貼簿:invite / joinreq 無秘密;approval 的 SAE / net_root 只以密文存在;貼後清空。

## 7. 測試(每一新檢查一個負臂 + 負對照)
- M1 向量:以向量輸入重建 invite / joinreq / approval / msecrets / sas,逐位元組相同。負:改 1 B → FAIL。check_joinreq 另用 dev-cert fixture。
- M2 verify_sign1 / object_hash:high-s、unprotected 非空、未知 payload key、invite 內 netcfg 未知 key、node_cert 未知 key、未 tag、錯 ctype、錯 label 各一臂拒;n−s / 加 unprotected → OBJECT_HASH 不變。負:hash 整個 Sign1 → FAIL。
- M3 open_invite:admin_pub 不在 admins、簽章壞、kind 0、invite key 1 ≠ 內嵌 netcfg key 1 → 拒。負:拿掉 admins 檢查 / 不比 key 1 → 對應臂 FAIL。
- M4 request_joinreq:admin_pub ∉ admins / 巢狀 netcfg 壞的 invite → 不出 SignOwner、不寫 mpend(負:略過 open_invite → FAIL);node_cert_raw 為 None → 拒;verify_pinned 失敗時仍是 None(負:驗證前就設 → FAIL);
  同 DAC、同邀請再申請(改了名稱)→ 同 hex / SAS / 舊名稱、不出 SignOwner(負:每次重簽 → SAS 變 → FAIL);不同 DAC、或 pend_plain = None 且 pend_gen = 3 → 依序 SignOwner(sig_enc)、SignOwner(joinreq),以世代 3 覆寫 + 「重新核對」文字(負:以 0 覆寫 / 沿用舊 sig_enc → FAIL)。verify_offline:非 `dev:` / 無 dev-trust 編譯 → Untrusted(負:不呼叫閘門 → FAIL)。
- M5 check_joinreq:hash 不在 key 12 / 已用、net A 的申請貼到 net B、Sign1 簽者 ≠ payload owner_pub、sig_enc 壞、建網節點或別的成員 node_cert 配不同 owner_pub → 拒且不寫;approved + 同 owner_pub → 允許。負:不查 used / 不查既有 DAC / 任意 key 驗簽 → 對應臂 FAIL。
- M6 SAS:換 owner_enc_pub 或換邀請 → SAS 變。負:只算 invite_id → FAIL。
- M7 net_make_invite / net_approve:CAS 先於輸出;世代不符 → 無輸出;key 12 撐過 join / confirm / forget;重複 invite hash → 拒;approve 傳入 hash ≠ joinreq_hash → 無輸出;key 12 已 used → 無輸出;
  紀錄 pending / 本機 admin 不在 admins / 已滿 16(approved 計入)→ 不簽、不寫。負:encode 不帶 key 12 / approve 不重跑檢查 / 前置不算 approved → 對應臂 FAIL。
- M8 import:無 mpend、key 1 ≠ mpend netcfg、同 admin 金鑰不同 net_id、任一 Sign1 非 mpend admins、net_id / version 不一致、secrets / msecrets key 3 不符、明文多 key、version 較舊、eph 不在曲線上、AEAD 失敗、
  **7a 之後 mpend 以同內容重寫(世代 +1、SAS 相同;合成臂,代表約 10^-6 的 SAS 碰撞)→ 7c 以舊 pend_gen 呼叫 → 不寫**、confirmed_sas ≠ mpend 的 SAS、既有 mnet + 外來 admins、既有 mnet 同 version 不同位元組、**version + 1 但 prev_hash ≠ OBJECT_HASH(既有)**、**version + 1 但 net_id 不同**、落後 ≥ 2 版(「太舊」文字)→ 各一臂不寫;
  version = 既有 + 1、既有 admins 簽、prev_hash / net_id 相符 → 可匯入;偽造同 net_id 邀請取代 mpend 後,真 approval → 拒;**偽造 I′ 的 mpend + 偽造 admins 簽的 approval → 7a 顯示 SAS(I′, J′);以該 SAS 確認 → 程式接受(斷言接受:記錄這只靠人為閘門),以不同的 confirmed_sas → 不寫**;
  舊申請的 approval(同 netcfg / DAC / owner_enc)→ 可匯入、SAS 不同。mpend 已刪:approval secrets 與 mnet key 5 相同且有 key 7 → 「已匯入」;無 key 7 → 「需要新的邀請」;不同 → 「找不到申請」。
  負:只驗兩個 Sign1 → msecrets 臂 FAIL;7c 只比 SAS 不比世代 → 重寫臂 FAIL;不查 prev_hash / net_id → 對應臂 FAIL;已匯入不看 key 7 → 無 key 7 臂 FAIL;只比 net_id → 外來 admins 臂 FAIL;已匯入只比 net_id → 「找不到申請」臂 FAIL。
- M9 隊員 join / 再匯入:join2 T3 / T4 / T7 / T11 隊員模式重跑;3 → 重送同一份、再 3 → TwiceRefused、不出 SignAdmin;4 → 「需要新的邀請」;**隊員模式從不發 PersistNet**(負:沿用 PersistNet → FAIL);
  回 4 → 先改回國家,成功才去掉 key 7;改回失敗 → key 7 與 prev_country 保留(負:先刪 key 7 → FAIL);mnet 無 key 7 → 前置 a 拒(負:只看解得開 → FAIL);**key 7 applied + 節點不在網路 → 照送、回 0 → 已套用**(負:applied 就不送 → FAIL);
  同 DAC 再匯入保留 prev_country;不同 DAC + 舊項 joining / 有 prev_country → 拒;不同 DAC + 舊項 applied → 新 joining。負:不看 DAC 一律帶上 → FAIL;隊員模式要 admin_pub → NotAdmin。
- M10 approved:前置 d 計入、forget 可刪且文字含「不會撤銷」、confirm 不升。負:forget 只認 joining → FAIL。
- M11 SignAllowList(Kotlin):admin 拒 joinreq aad;owner 拒 invite / msecrets / netcfg aad;既有臂不變。負:「owner 接受任何 Sig_structure」→ FAIL。
- M12 生命週期:mpend 寫後重建 session → 「再顯示申請」同 hex;mnet 匯入後重建 → 「繼續加入」;換路徑讀 mpend → 解不開;
  匯入寫完 mnet、刪 mpend 前插入新申請 → 新 mpend 被刪,再申請可恢復(記錄已接受的 fail-closed 行為)。負:mpend 用 expected 0 覆寫 → FAIL。
- M13 名稱:33 B、含 U+202E、含 Cc → 拒。負:只量字元數 → 多位元組臂 FAIL。
- M14 dev 閘門:不帶 dev-trust 編譯,§2 列出的每個 bridge 入口(含 request_member_join)回錯誤、不寫;Kotlin `ecdh` 在 DEV_TRUST = false 回錯誤;貼上畫面拒絕(widget)。負:拿掉任一檢查 → 該臂 FAIL。
- M15 RECORD_KINDS:只有 `mnet/x` 或 `mpend/x`、沒有 marker → store_has_records = true。負:今天的清單 → FAIL。
- M16 Kotlin ecdh(JVM 單元,不依賴 provider):64 B、0x02、x ≥ p、不在曲線上(BigInteger 方程式)、無窮遠點 → 錯誤;合法點 → 32 B 且與軟體 ECDH 相同。負:拿掉方程式檢查 → FAIL。
- M17 SAS 畫面(widget):兩畫面都有 R22 文字;「申請已換新」之後的 7a 畫面也有;member_import_approval 只在按下後以畫面上的 SAS 字串呼叫;按下前 net_approve 不可達。負:進畫面就呼叫 / 拿掉文字 → FAIL。
- M18 狀態頁(widget):info key 10 沒有相符的本機紀錄 → 不顯示網路名稱;相符 → 顯示 netcfg key 4。負:把 key 10 hex 當名稱顯示 → FAIL。
- 日誌:Rust 與 Dart(log 攔截)不含 SAE、net_root、z。負對照:注入一個 z 到 log → 攔截器抓到。

04 真機(dev = 管理者、dev2 = 隊員):1 `unclaimed 04`;2 dev 開 bm-ca68 → 邀請 → 複製;3 dev2 貼 → 認領 04 → 登入 → 申請 → 複製;4 dev 貼申請 → SAS 相同 → 同意 → 複製;
5 dev2 確認 SAS → 匯入 → 加入 →「已套用」;6 info key 10 = bm-ca68、key 9 = 1;每 10 s 讀 status 至 120 s,key 5 原因 ∈ {7, 8};dev 多一項 approved、key 12 used;
7 負對照:同一份申請再貼 → 拒(「另一網路的 approval」只在 Rust M8:04 單機沒有第二個網路);8 `restore 04 <run>`。⚠️「已連上」需 02。

## 8. 狀態頁欄位(只列節點真的有給的)
| 顯示 | 來源 | 有沒有 |
|---|---|---|
| 是否入網 / 原因 | status key 1、key 5 | ✅ |
| 網路名稱 | 本機 net/ 或 mnet/ 的 netcfg key 4,以 info key 10 對應 | ✅(app 端) |
| 鄰居數 / 網路狀況 | status key 3 / key 2 | ✅(快取空時缺) |
| 訊號 | key 15 join.snr_db | ✅ 只有自己擁有的節點 |
| 軟體版本 | key 15 image / info key 4 | ✅ |
| 電量 | key 6 | ❌ 節點不送 |

用 psk_member 看別人的節點:要新的 PSK 成員交握,節點只回 key 1-5 → 不在 MVP。

## 9. dev2 flavor(build.gradle.kts)
```kotlin
create("dev2") {
    dimension = "trust"
    applicationIdSuffix = ".dev2"
    resValue("string", "app_name", "Batman dev2")
    buildConfigField("boolean", "DEV_TRUST", "true")
}
```
cargokit.yaml 已對所有 flavor 開 dev-trust(R15),啟動檢查(main.dart:54-58)一致。自己的 applicationId → 自己的 Keystore alias / 紀錄。

## 附錄 A. 審查處理(v1–v3 輪摘要;逐項表見 v4)
- v1:匯入綁定 mpend、key 12 存 OBJECT_HASH、同 DAC 只取代 approved 同 owner、verify_offline 信任閘門、Kotlin 白名單、mnet / mpend / 隊員模式定義、verify_sign1 / object_hash、再匯入保留 prev_country;不採「記錄第一份申請 + 告警」(§5-4)。
- v2:再匯入只在同 DAC 帶狀態、ECDH 邊界誠實版 + ecdh 通道、SAS 窮舉列誠實界線(§5-5)、mpend 存 joinreq、降版列、node_cert_raw、巢狀未知 key、bridge 簽名、名稱限制。
- v3:7c 綁 7a(v5 簡化取代)、既有 mnet 鏈規則、net_approve 重驗綁 hash、RECORD_KINDS、管理者前置、Kotlin ecdh 格式檢查、畫面閘門、dev 閘門、生命週期列。

### v4 輪
| 項目 | 處理 |
|---|---|
| A-MAJOR-1 / B-m2 多候選 mpend 選擇 | 刪除;mpend 以 net_id 為鍵、每網路一筆、新申請取代舊的;§3 寫明舊 approval 規則(三者相同 → 等價可匯入,SAS 不同會被人擋;否則 fail-closed)與偽造邀請;M8 改臂 |
| A-MAJOR-2 request_joinreq 不驗邀請 | §4 步驟 4 先重跑 open_invite;簽名 `pend: Option<(gen, plain)>`;M4 臂 + 負對照 |
| A-m1 7c 綁 7a | 7c 收 confirmed_sas 字串、比 7a 讀到的世代;M8 |
| A-m3 7a 參數 | Dart 先 `approval_net_id` 再讀 mpend / mnet 傳入 |
| A-m4 隊員模式寫入 | PersistMnet;M9 臂 + 負對照 |
| A-m5 同 DAC 同 SAS 負對照 | M4 |
| A-m6 mpend 解不開 | 以讀到的世代覆寫(§3);M4 |
| B-m1 SAS 文字 | §5-6;M17 |
| B-m3 / A-m2 Kotlin ecdh dev 閘門、request_member_join、x / y < p | §2;M14、M16 |

### v5 輪
| 項目 | 處理 |
|---|---|
| B-MAJOR-1 偽造邀請說成 fail-closed | §3 改寫:只靠隊員 7a 的 SAS 人為核對擋;§5-5 加隊員端後果;恢復 = 新邀請 + 新申請;M8、M17 臂 |
| B-m1 舊申請的 approval | §3 改為協定本質;mnet key 8 僅供顯示 |
| B-m2 7c 世代檢查 | 保留:7a 回傳 pend_gen、7c 收 expected_pend_gen;M8 用「同內容重寫、世代 +1」區分 |
| A-m3 / B-m3 刪 mpend | 記為接受的 fail-closed(新申請被刪 → 再申請);M12 臂 |
| B-m4 node_cert 不綁擁有者 | §5-7 誠實界線(只有阻斷服務) |
| A-m1 request_joinreq 簽名 | `pend_gen: u64, pend_plain: Option<Vec<u8>>`;M4 臂 |
| A-m2 mpend 已刪再貼 | 7a pend 可缺;驗 secrets 並比 mnet key 5;M8 臂 |
| A-m4 既有 mnet 規則 | 逐位元組相同或 version + 1 且既有 admins 簽;M8 臂 |
| A-m5 回 4 | 照 join2 §3.3-6,改回成功才去掉 key 7;M9 臂 |
| A-m6 前置 a | 需 key 7;applied → 不送;M9 臂 |
| A-m7 改名再申請 | 顯示存的名稱(§3);M4 |
| A-m8 真機步驟 7 | 只留在 Rust M8 |

### v6 輪(兩位 APPROVE-WITH-CHANGES,0 MAJOR → 凍結 v6.1)
| 項目 | 處理 |
|---|---|
| A-m1 前置 a | 照 join2 §3.3-1:有 key 7 就送,applied 也送、回 5 → info 判定;M9 臂 |
| A-m2 落後 ≥ 2 版 | 「這支手機的網路資料太舊」(已知限制);7c「version 不小於」由既有 mnet 規則涵蓋;M8 臂 |
| A-m3 sig_enc 是否重簽 | 覆寫路徑每次先重簽 sig_enc 再簽 joinreq;同 DAC 同邀請的重用路徑兩個都不簽;§3 恢復說明對應改寫;M4 |
| A-m4 7c 回傳 | OwnerStep(PersistMnet;世代由 Rust 定,AAD = expected_gen + 1) |
| A-m5 M8 臂標記 | 偽造 I′ 臂改為斷言「SAS 相符時程式接受」(人為閘門);pend_gen 臂標為合成(SAS 碰撞) |
| A-m6 已匯入需 key 7 | §3;M8 臂 |
| A-m7 狀態頁 / approval_net_id / 路徑 / §5 編號 | M18;§4 7a 說明只解析為何安全;小寫 hex;§5 依序 1–7 |
| B-m1 version + 1 規則 | 加 prev_hash = OBJECT_HASH(既有)、net_id 相同;M8 兩臂 |
| B-m2 Rust 閘門的時效 | §2 誠實界線:#255 前屏障是啟動交叉檢查 + Kotlin + Dart |
| B-m3 曲線檢查 | §2 BigInteger 直接驗;M16 JVM |
| B-m4 §5-7 | 補成員層級 net_root 與紀錄歸屬 |
| B-m5 邀請內 netcfg | §4 步驟 2 以自己的 admins 驗為 v1 自簽(node.go:1031) |
