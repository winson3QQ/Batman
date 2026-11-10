# #254 app S4 — 看得懂的狀態頁（設計 v4，待審）

範圍：只改 app（狀態頁、`status_view_of`、加入流程的「已連上」判定 = join2 v7.2 §3.3-7），節點零改動。擁有權 / 契約一句話：只讀既有的 `status` 與 `info` 回答（擁有者 session），不寫任何東西、不加新欄位、不加新機制。
來源：S20 實測（#254 comment 6760039272）：「狀態：已加入網路」旁邊寫「網路狀況：中斷」，「原因」是節點的英文 joinwatch 句子而且說錯（KEY PLACEHOLDER：keyguard 擋的是手機 AP `default_radio0`，mesh `wlh0` 是起來的，真正原因是 0 台鄰居），「軟體版本：OpenMANET 1.8.0」是上游版本。

## 1. 事實（節點 Batman-p3 @ e5c89a1；app 7c81813）
| # | 事實 | 證據 |
|---|---|---|
| F1 | status key 1 = 0 / 1 / 2 / 3；擁有者 session 只會是 1（已認領）或 2（成員）；legacy 認領後無線電照樣在跑；已在網路的節點拒絕 network/join | provd/session.go:855-862、server.go:60；node.go:570-571、1024-1026 |
| F2 | key 2 = health.level（OK 0 / WARN 1 / CRIT 2）= 最差值；CRIT 來源：mesh（keyguard、key、**plinks = 0 就是 CRIT**）、電源、電池、過熱、服務；儲存只到 WARN | status.go:187-189；halow-status:63-93（:76）、136 |
| F3 | keyguard：手機 AP 的 key 是 placeholder → 只關 AP 介面；mesh 的 key 是 placeholder → 關整個 radio；任一被擋，mesh 檢查都是 CRIT、reason_code 都是 1 | halow-keyguard:22-33；halow-status:31、72；joinwatch:86 |
| F4 | key 3 = `batctl n` 所有 hardif、含過期項目的鄰居數 → 不用來判定 | halow-status:38；status.go:190 |
| F5 | 節點的「已連上」= plink ≥ 1 且 wlh0 上有 batman 鄰居 = JOINED = **key 5 不存在**；JOINED 來自 joinwatch 的狀態檔（每 15 s），plinks 每次讀即時 | meshjoin.sh:22-24；status.go:196-205；joinwatch:36 |
| F6 | reason_code：1 keyguard（先查，會蓋掉 7–9）、2 key 未設、3 radio 關閉、4 沒起來、5 不在 mesh 模式、6 mesh11sd 關、7 沒聽到任何站台、8 聽到但沒有 plink、9 有 plink 但沒 batman 鄰居；重開機可能有用的只有 4 / 5 / 8 / 9（7 是孤單或太遠，不是故障；連續沒入網還會報 bootloop） | joinwatch:79-104、97-100；halow-status:124 |
| F7 | key 15（只有擁有者）：image、uptime_s、temp_c、throttled、age_s、join.{state, channel, country, snr_db, plinks(可缺)}，可能有 uci_staged（陣列）、settings_restore；snr_db 是字串、可空 | status.go:206-224；halow-status:164 |
| F8 | snr = station dump 裡任何站台最強的 signal avg − 雜訊；讀不到雜訊用 −90 dBm（可能高估約 15 dB）；節點 < 20 dB 算 WARN | halow-status:41-44、80 |
| F9 | 快取超過 30 s 或讀不到 → 擁有者只拿到 {1, 15: {stale: true}} | status.go:181-186 |
| F10 | key 15 image = 上游 OpenMANET 版本；我們的 BATMAN_VERSION = **info key 4** | halow-status:17、156；provd/server.go:549；main.go:52-54 |
| F11 | 「手機 AP 沒設好」沒有結構化欄位（只有 reason_code 1 間接表示）；電池、服務、儲存不在 status → 已知缺口（#254 checklist） | settings.go:142-161；status.go:206-224 |
| F12 | app 現況：status 錯誤碼被丟掉（owner.rs:679-682）；key 2 譯成「網路狀況」、key 5 英文當「原因」、image 當版本；加入後的「已連上」用 k3 ≥ 1 且 plinks ≥ 1（flow.rs:183-184），顯示 k3（owner.rs:433） | owner.rs:1628-1685；member_ui.dart:165-186 |

## 2. 畫面（由上到下）
1. **連線判定**（§3）：顏色 + 一句白話 + 能做的事。
2. ⚠️ 小字，第一個成立的一行：throttled bit 0 →「電源電壓不足 — 請檢查電池／電源線」；temp_c ≥ 80 →「節點過熱 — 請移到陰涼處」；否則（k5 不存在 且 k2 = 2）或 k5.1 = 1 →「這台節點回報有其他問題，手機可能連不上它的 Wi-Fi — 請找維修人員（技術資訊有細節）」。沒入網時 k2 = 2 是常態（F2），不顯示。
3. 網路歸屬（小字）：k1 = 2 →「網路：<名稱>（已是成員）」（M18：info key 10 對本機 net/、mnet/ 的 netcfg key 4；對不到 →「網路：別支手機建立的網路」；info key 10 缺 →「網路：（讀不到名稱）」）；k1 = 1 →「已認領，還沒加入網路」；0 / 3 不顯示。
4. 軟體版本 = info key 4；缺 → 不顯示。
5. 「重新整理」：重讀 status + info；status 回 E_RATE 時保留上一個判定、跳一行「太快了，請稍等一秒」。
6. 摺疊的「技術資訊（給維修人員看）」：key 2、key 5 代碼與英文句子、key 15 的 image / snr_db / plinks / channel / country / age_s / uptime_s / temp_c / throttled / uci_staged / settings_restore，以及：「SNR 門檻暫定；SNR 是最強那個站台的訊號（不一定是隊員），雜訊讀不到時可能偏高」「『已連上』來自節點每 15 秒的判定，剛斷線時最多晚 15 秒才變」。
節點給的字串（版本、k5.2、k15 字串、uci_staged 的每一項）一律經 `display_name` 並截到 64 個字元（主畫面與技術資訊都是）；主畫面不出現英文句子或指令。

## 3. 連線判定表（由上往下第一個成立的列）
輸入：status 結果（成功的回答 / 錯誤碼 / 解不出）、k1、k5（在不在、k5.1）、plinks、snr（k15.join.snr_db 解析為整數；空、非數字 → 未知）、up（k15.uptime_s）。「找維修」= 「仍然如此請找維修人員」。
| # | 條件 | 顏色 | 句子 — 能做的事（k1 = 2） |
|---|---|---|---|
| 1 | status 回 E_UNSUPPORTED | ⚪ | 這台節點的軟體太舊，看不到連線狀態；若是新版節點請找維修人員 |
| 2 | 其他錯誤碼、解不出回答、k15.stale、k1 缺、k15 缺、plinks 缺 | ⚪ | 狀態未知，稍後再查看；一直如此請重新開機或找維修人員 |
| 3 | k5 不存在 且 plinks ≥ 1 且 snr ≥ 20 | 🟢 | 已連上，附近有 P 台隊員節點 |
| 4 | k5 不存在 且 plinks ≥ 1 | 🟡 | 已連上，但訊號偏弱 — 可以靠近一點或換個位置 |
| B | up < 120 且 k5.1 ∈ {4, 5, 7, 8, 9} | 🟡 | 剛開機，正在尋找其他節點 — 請等一分鐘再按「重新整理」 |
| 5 | k5.1 ∈ {3, 6} | 🔴 | 這台的無線電設定被關掉了 — 請找維修人員 |
| 5' | k5.1 ∈ {4, 5} | 🔴 | 這台的無線電沒有正常運作 — 請重新開機；找維修 |
| 6 | k5.1 = 8 | 🔴 | 有收到其他節點，但連不上 — 請對照上面「網路：」的名稱是否和隊長的相同；不同或仍然如此請找維修人員 |
| 7 | k5.1 = 7 | 🔴 | 附近沒有收到其他節點的訊號 — 請確認隊員的節點已開機、在附近、網路名稱和隊長的相同；找維修 |
| 8 | k5 存在 且 k5.1 = 9 或 plinks ≥ 1 | 🟡 | 正在接上網路 — 請等一分鐘再按「重新整理」；仍然如此請重新開機；找維修 |
| 9 | 其他（例：k5.1 ∈ {0, 1, 2}；k5 不存在但 plinks = 0，即 JOINED 落後） | 🔴 | 還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」，仍然如此請重新開機；找維修 |

- **k1 = 1**（已認領、不在隊伍網路；legacy 同）：顏色照表（句子已說明，不另改色）。列 3 / 4 →「已連上附近 P 台節點，但這台還沒加入隊伍網路 — 要跟隊伍通訊請按「加入隊伍網路」」；列 6 / 7 / 8 / 9 →「這台還沒加入隊伍網路 — 請按「加入隊伍網路」」；列 5 / 5' 與 B 用原句（無線電壞了或剛開機不是「請加入」），B 句尾加「；還沒加入隊伍網路」。k1 = 2 的列 6 不叫人「加入隊伍網路」（F1：節點已在網路會拒絕）。
- P = plinks（直接連到的 HaLow 站台），P ≥ 1 才寫數字；k3 只在技術資訊。🟢 只在節點自己判定 JOINED 且 snr ≥ 20；snr 未知不算良好。
- 只有列 5'、8、9 會叫人重新開機（F6 的可能有用者，以及代碼 0–2 的退路：代碼 1 會蓋掉無線電故障）；每個重開機階梯都以「找維修」結尾。節點端後續（代碼 1 只算 morse radio 的 guard）記 #254 checklist。
- 暫定：up < 120、SNR 20 dB。⚠️ 未驗證、進硬體測試清單：入網要多久；開機後多久 wlh0 才在、代碼 4 / 5 何時出現；不同金鑰的站台是否出現在 station dump 並有 signal avg；dev 節點 04 / 02 的手機 AP 是 placeholder → 會一直顯示「其他問題」⚠️（預期）。

## 4. 實作（審過再做）
- Rust：`link_verdict(status 結果, info) -> (顏色, 句子, ⚠️ 行)` 純函式，文字在 Rust（既有慣例）；bridge 的 status-page 讀取保留錯誤碼（F12）。
- 加入後的「已連上」（`flow::link_state`）照 join2 v7.2 §3.3-7：stale / age_s 早於 join → 照舊不算；列 1–2 → Unknown，列 3–4 → Connected{P}，其餘 → NotYet；`link_text` 顯示 P。
- Dart（member_ui.dart StatusPageView、nodes.dart `_statusPage`）：§2 排版、「重新整理」、E_RATE 保留。

## 5. 測試（每項附負對照；每臂寫明 up）
- T1（Rust）每列一臂，含：S20（k1 = 2、k2 = 2、plinks = 0、k5.1 = 1、up 600 → 列 9 + ⚠️ 其他問題）；k3 = 1、plinks = 0、k5.1 = 7、up 600 → 列 7（無「重新開機」、非 🟢）；up 30 + 代碼 4 / 7 / 8 → B；k1 = 2 + 代碼 8 + up 600 → 無「加入隊伍網路」；k1 = 1 + 代碼 1 + up 600 → 「這台還沒加入隊伍網路」；k1 = 1 + JOINED → 列 3 的 k1 = 1 句；k1 = 1 + 代碼 4 + up 600 → 列 5' 原句；代碼 8 + plinks 1 → 列 6；k5 存在 + 代碼 0 + plinks 0 → 列 9；k5 不存在 + plinks 0 → 列 9；代碼 3 → 無「重新開機」。負對照：v1 規則（k3 ≥ 1 就 🟢）、看 k3、用 key 2 定顏色、k1 定顏色、代碼 1 當列 5、拿掉剛開機規則、v3 列 8 的句子（叫代碼 7 重開機）。
- T2（Rust）E_UNSUPPORTED → 列 1；E_REJECTED / E_FORBIDDEN / E_RATE / 解不出 / stale / k15 缺 / plinks 缺 → 列 2。負對照：錯誤落到其他列。
- T3（Rust）snr 19 / 20 / −3 / "" / "abc"。負對照：門檻用 ≤、未知當良好。
- T4（Rust）版本取 info key 4；⚠️：throttled "0x50005" / "0x50000"、temp 79 / 80、JOINED + k2 = 2 → 其他問題；k5.1 = 1 → 其他問題；沒入網（代碼 7、8；up 30 與 600）+ k2 = 2 → 無 ⚠️；k2 = 1 → 無。負對照：用 image、v3 規則（k2 = 2 就顯示）。
- T5（Rust）真實資料 `testdata/halow-status-04-wsl22.json` 照 status.get 編碼（status.go:187-224）→ 判定與欄位如預期。
- T6（Rust）RLO / 換行 / 超過 64 字元的節點字串（含 uci_staged 每一項）在主畫面與技術資訊都被過濾、按字元截斷。負對照：不過濾。
- T7（Rust）`flow::link_state`（取代 join2 T11 的臂）：stale、age_s 早於 join → Unknown / 不算；JOINED + plinks ≥ 1 → Connected{plinks}；k3 缺 + JOINED + plinks 1 → Connected；k5 不存在 + plinks 0 → NotYet；代碼 9 + k3 ≥ 1 + plinks ≥ 1 → NotYet。負對照：舊規則（k3 與 plinks）、只看 JOINED。
- T8（widget）第一行是判定；主畫面找不到 k5 英文與 image；展開技術資訊才看得到；「重新整理」呼叫讀取；E_RATE 保留上一個判定。負對照：reason 放回主畫面。M18 照舊。
- T9（widget，f139951）360×640 下「加入隊伍網路」可以捲到並點到。負對照：原本的版面。

## 附錄 A. 審查處理
| 輪 / 項目 | 處理 |
|---|---|
| v1 M1 假 🟢 | 🟢 需 k5 不存在 + plinks ≥ 1 + snr ≥ 20 |
| v1 M2 legacy 顯示沒加入 | 顏色不看 k1（v2 M1 再細分用字） |
| v1 M3 聽到但連不上 | 列 6（代碼 8）；⚠️ 不同金鑰站台進硬體清單 |
| v1 M4 代碼 1 蓋掉故障 | 列 9 的重開機退路；節點端後續進 checklist |
| v1 M5 非連線故障消失 | ⚠️ 行（電源 / 過熱 / 其他問題） |
| v1 minors | SNR 20 dB、錯誤碼、重新整理、display_name、真實資料、f139951 測試、行號 |
| v2 M1 k1 = 1 的用字 | 顏色照表、用字換成「這台還沒加入隊伍網路」 |
| v2 M2 錯誤 | 列 2 = 其他錯誤 / 解不出 / k15 缺 / plinks 缺；保留錯誤碼 |
| v2 M3 剛開機 | 剛開機列（v3 M2 擴大到代碼 4 / 5） |
| v2 M4 加入流程的已連上 | `flow::link_state` 改用同一判定（v3 M5：join2 升 v7.2） |
| v2 M5 非連線 CRIT 看不到 | ⚠️「其他問題」（v3 M1 收窄條件） |
| v2 minors | 代碼 3 / 6 直接找維修；P = plinks；snr 是任何站台；E_RATE 保留；info key 10 缺；k1 0 / 3 不顯示；按字元截斷 |
| v3 M1 ⚠️ 其他問題在沒入網時一直出現 | 只在（JOINED 且 k2 = 2）或 代碼 1；F2 / F3 改正；T4 臂 |
| v3 M2 剛開機也要涵蓋代碼 4 / 5 | 剛開機列 B 涵蓋 4 / 5 / 7 / 8 / 9；硬體清單加 wlh0 出現時間；T1 臂 |
| v3 M3 代碼 7 不該叫人重開機 | 代碼 7 獨立一列（確認 + 找維修）；重開機只在列 5' / 8 / 9，都以找維修結尾；T1 臂 |
| v3 M4 k1 = 2 的代碼 8 不該叫人加入 | 列 6 改為對照網路名稱；「加入隊伍網路」只在 k1 = 1 用字；T1 臂 |
| v3 M5 與凍結的 join2 §3.3-7 衝突 | join2 升 v7.2（同一 commit）重寫 §3.3-7 與 T11；T7 負對照；link_text 顯示 P |
| v3 minors | 列 9 = 純「其他」（含 JOINED 落後）；剛開機優先、k1 = 1 用字附加；列 5 / 5' 不換成「請加入」；電源 / 過熱附行動；⚪ 長久不變的退路；JOINED 落後寫進技術資訊；dev 節點 ⚠️ 進硬體清單；k1 = 1 不另改色；uci_staged 每項過濾 |
