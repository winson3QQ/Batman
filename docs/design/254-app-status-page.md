# #254 app S4 — 看得懂的狀態頁（設計 v2，待審）

範圍：只改 app（`status_view_of` / 狀態頁畫面），節點零改動。擁有權 / 契約一句話：只讀既有的 `status` 與 `info` 回答（擁有者 session），不寫任何東西、不加新欄位、不加新機制。
來源：S20 實測（#254 comment 6760039272）：「狀態：已加入網路」旁邊寫「網路狀況：中斷」，「原因」是節點的英文 joinwatch 句子而且說錯（KEY PLACEHOLDER：keyguard 擋的是手機 AP `default_radio0`，mesh `wlh0` 是起來的，真正原因是 0 台鄰居），「軟體版本：OpenMANET 1.8.0」是上游版本。

## 1. 事實（節點 Batman-p3 @ e5c89a1；app 9b070ab / f139951）
| # | 事實 | 證據 |
|---|---|---|
| F1 | status key 1 = 節點狀態 0 / 1 / 2 / 3（provd 把 helper 的字串轉數字）。擁有者 session 只會是 1（已認領）或 2（成員）；legacy 認領後 RadioManaged = false，無線電照樣在跑 | provd/session.go:855-862、server.go:60；node.go:570-571 |
| F2 | key 2 = health.level（OK 0 / WARN 1 / CRIT 2），是所有檢查的最差值（keyguard、電源、溫度、服務、儲存） | status.go:187-189；halow-status:63-93、136 |
| F3 | keyguard 擋的是整組 radio（含手機 AP，halow-keyguard:20-37），mesh 檢查看整個 blocked 檔 → AP 沒設好也讓 key 2 = CRIT | halow-status:31、72 |
| F4 | key 3 = `batctl n` 所有 hardif、含過期項目的鄰居數；有效回答一定有（$nb 是 grep -c 的數字） | halow-status:38、164；status.go:190 |
| F5 | 節點自己的「已連上」= plink ≥ 1 且 wlh0 上有 batman 鄰居（meshjoin.sh:22-24）= join.state JOINED = **key 5 不存在**；key 5 = {1 reason_code, 2 英文句子} | status.go:196-205；joinwatch:85-104 |
| F6 | reason_code 先查 keyguard（1），會蓋掉 7（沒聽到任何節點）、8（聽到但沒有 plink）、9（沒 batman 鄰居） | joinwatch:79、86、93 |
| F7 | key 15（只有擁有者）：image、uptime_s、temp_c、throttled、age_s、join.{state, channel, country, snr_db, plinks(可缺)}，可能有 uci_staged、settings_restore；snr_db 是字串、可空 | status.go:206-224；halow-status:164 |
| F8 | snr = 最強那台鄰居的 signal avg − 雜訊；讀不到雜訊時用 −90 dBm（可能讓 SNR 高估約 15 dB）；節點自己 < 20 dB 算 WARN | halow-status:41-44、80 |
| F9 | 快取超過 30 s 或讀不到 → 擁有者只拿到 {1, 15: {stale: true}}；成員角色沒有 key 15（本頁一律擁有者） | status.go:181-186、11 |
| F10 | key 15 image = "OpenMANET " + openwrt 版本（上游）；我們的 image 版本 BATMAN_VERSION = **info key 4** | halow-status:17、156；provd/server.go:549；main.go:52-54 |
| F11 | 「手機 AP 沒設好」沒有任何結構化欄位（settings/get key 20 只有 SSID；key / guard 狀態只在英文句子）→ 不顯示；電池、服務、儲存也不在 status → 已知缺口（記 #254 checklist） | settings.go:142-161；status.go:206-224 |
| F12 | app 現況：key 2 譯成「網路狀況」、key 5 英文當「原因」、image 當版本；狀態頁是一次讀取的快照 | bridge owner.rs:1628-1685；member_ui.dart:165-186 |

## 2. 畫面（由上到下）
1. **連線判定**（§3）：顏色 + 一句白話 + 能做的事。永遠是即時連線狀態，**不看 key 1**。
2. ⚠️ 小字（只在成立時）：key 15 throttled 的 bit 0 →「電源電壓不足」；temp_c ≥ 80 →「節點過熱」（同 halow-status:84-88 的 CRIT 條件）。不因 key 2 顯示任何泛用警告（AP 沒設好的節點 key 2 永遠是 CRIT）。
3. 網路歸屬（小字）：key 1 = 2 →「網路：<名稱>（已是成員）」（名稱照 M18：info key 10 對到本機 net/、mnet/ 的 netcfg key 4；對不到 →「網路：別支手機建立的網路」）；1 →「已認領，還沒加入網路」。
4. 軟體版本 = info key 4；缺 → 不顯示。
5. 「重新整理」按鈕：重讀 status + info。
6. 摺疊的「技術資訊（給維修人員看）」：key 2 等級、key 5 代碼與英文句子、key 15 的 image / snr_db / plinks / channel / country / age_s / uptime_s / temp_c / throttled / uci_staged / settings_restore，以及「SNR 門檻為暫定；SNR 是最強那台的訊號，雜訊讀不到時可能偏高」。
節點給的字串（版本、k5.2、k15 字串）一律經 `display_name` 並截到 64 字元；主畫面不出現英文句子或指令。

## 3. 連線判定表（由上往下第一個成立的列）
輸入：status 的結果（成功的回答 / 錯誤碼 / 讀不到）、k3、k5（在不在、k5.1）、plinks、snr（k15.join.snr_db 解析為整數；空、非數字 → 未知）。
| # | 條件 | 顏色 | 句子 — 能做的事 |
|---|---|---|---|
| 1 | status 回 E_UNSUPPORTED | ⚪ | 這台節點的軟體太舊，看不到連線狀態 |
| 2 | 讀不到、E_RATE / E_BUSY、k15.stale、k1 缺 | ⚪ | 狀態未知，稍後再查看 |
| 3 | k5 不存在 且 plinks ≥ 1 且 snr ≥ 20 | 🟢 | 已連上，附近有 N 台隊員節點（N = k3） |
| 4 | k5 不存在 且 plinks ≥ 1（snr < 20 或未知） | 🟡 | 已連上，但訊號偏弱 — 可以靠近一點或換個位置 |
| 5 | k5.1 ∈ {3, 4, 5, 6} | 🔴 | 這台的無線電沒有正常運作 — 請重新開機；仍然如此請找維修人員 |
| 6 | k5.1 = 8，或（k5 存在 且 plinks = 0 且 k3 = 0 且 snr 已知） | 🔴 | 有收到其他節點，但連不上 — 可能不是同一個隊伍網路，請向隊長確認後重新「加入隊伍網路」 |
| 7 | k5 存在 且（plinks ≥ 1 或 k3 ≥ 1） | 🟡 | 正在接上網路 — 請等一分鐘再按「重新整理」；仍然如此請重新開機 |
| 8 | 其他（k5 存在、沒有 plink、沒有鄰居、沒聽到任何節點） | 🔴 | 還沒連上其他隊員 — 附近沒有收到其他節點的訊號。請確認其他隊員的節點已開機、距離不要太遠；如果隊員的節點就在旁邊仍然如此，請重新開機，再不行請找維修人員 |

- 🟢 只在節點自己判定 JOINED（k5 不存在）且有 plink 且訊號 ≥ 20 dB；k3 只用來報數量（F4：含其他 hardif 與過期項目）。snr 未知永遠不算「良好」。
- 不看 key 1（F1：legacy 認領的節點照樣在 mesh）；不看 key 2（F2/F3）；代碼 1 / 2 不用（F6：手機 AP 被擋就會出現，還會蓋掉 7–9），所以列 8 對「無線電其實壞了但被代碼 1 蓋住」的情況只能靠「重新開機 / 找維修」這句升級。節點端後續（代碼 1 只算 morse radio 的 guard）記 #254 checklist。
- 列 6 的「聽到不同金鑰的站台」⚠️ 未驗證（不同金鑰的站台是否出現在 station dump 且有 signal avg）→ 加進硬體測試清單（之後在 04 / 02 探測）。
- SNR 門檻 20 dB **暫定**，與節點 rf WARN 相同（F8），依現場資料調整。

## 4. 實作（審過再做）
- Rust（bridge owner.rs）：`StatusView` 帶結構化欄位（狀態錯誤碼、k1、k3、k5 在不在 / 代碼、plinks、snr、stale、throttled、temp_c、fw_version = info key 4、技術資訊文字）；判定表 = 純函式 `link_verdict`；文字在 Rust（既有慣例），Dart 只排版。
- Dart（member_ui.dart StatusPageView + nodes.dart `_statusPage`）：§2 的排版與「重新整理」（重跑同一個 `_statusPage` 讀取）。

## 5. 測試（每項附負對照）
- T1（Rust）判定表每列一臂，含：S20 臂（k1 = 2、k2 = 2、k3 = 0、plinks = 0、k5.1 = 1 → 列 8）；k3 = 1、plinks = 0、k5.1 = 7 → 不是 🟢（列 7）；legacy 臂 k1 = 1、k5 不存在、k3 ≥ 1、plinks ≥ 1、snr 25 → 🟢；k5.1 = 8 → 列 6。負對照：v1 規則（k3 ≥ 1 就 🟢）、用 key 2 決定顏色、看 key 1、把代碼 1 當列 5 → 對應臂 FAIL。
- T2（Rust）E_UNSUPPORTED / E_RATE / stale / 讀不到 → 列 1 / 2。負對照：stale 當 0 鄰居。
- T3（Rust）snr 19 / 20 / −3 / "" / "abc"。負對照：門檻用 ≤、未知當良好。
- T4（Rust）版本取 info key 4 而非 image；⚠️ 列：throttled "0x50005"（bit 0 = 1）、"0x50000"、temp 79 / 80。負對照：用 image、用 key 2 出警告。
- T5（Rust）一筆真實資料：`testdata/halow-status-04-wsl22.json` 照 status.get 的編碼（status.go:187-224）轉成 status 回答 → 判定與欄位如預期。
- T6（Rust）RLO / 換行 / 超長的節點字串在主畫面與技術資訊都被過濾、截斷。負對照：不過濾。
- T7（widget）第一行是判定；主畫面找不到 k5 英文句子與 image；展開技術資訊才看得到；「重新整理」呼叫讀取。負對照：把 reason 放回主畫面。M18 照舊。
- T8（widget，f139951）360×640 下「加入隊伍網路」可以捲到並點到。負對照：改回原本的版面（Column 不捲）→ FAIL。

## 附錄 A. v1 審查處理（A / B 各 4 MAJOR，重疊合併）
| 項目 | 處理 |
|---|---|
| M1 假 🟢（k3 含所有 hardif / 過期項目） | 🟢 需 k5 不存在 + plinks ≥ 1 + snr ≥ 20；k3 只報數量；T1 臂 |
| M2 legacy 認領顯示「還沒加入網路」 | 第一行不看 key 1；歸屬只在第三行；T1 legacy 臂 |
| M3 聽到但連不上 | 列 6（k5.1 = 8 或 snr 已知但 plinks = 0、k3 = 0）；⚠️ 不同金鑰站台進硬體測試清單 |
| M4 代碼 1 蓋掉無線電故障 | 列 8 的行動升級；§3 寫明限制；節點端後續進 checklist |
| M5 非連線故障從主畫面消失 | ⚠️ 小字只用 throttled bit 0 / temp ≥ 80；不用 key 2；電池等記缺口 |
| m SNR 門檻 | 對齊節點 20 dB；刪「普通」；註明最強鄰居與 −90 dBm 的偏差 |
| m 錯誤處理 | E_UNSUPPORTED 單獨一句；「稍後」只給 E_RATE / E_BUSY / stale |
| m 快照 / 按鈕名稱 / 節點字串 / uci_staged / 真實資料 / f139951 | 「重新整理」；按鈕名照實際；display_name + 64 字元；技術資訊列出；T5、T6、T8 |
| m F2 / F4 / F9 行號與 F4 說法 | 改正；k3 在有效回答一定有，原列 3 併入列 2 |
