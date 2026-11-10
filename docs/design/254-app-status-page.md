# #254 app S4 — 看得懂的狀態頁（設計 v8.1）

**凍結 v8.1（2026-11-10）**。審查 8 輪，每輪兩位獨立審查者（A / B）；各輪 MAJOR 數 A/B：v1 4/4、v2 4/3、v3 3/3、v4 1/2、v5 1/2、v6 1/1、v7 0/1、v8 0/0（v8：A APPROVE-WITH-CHANGES 4 MINOR、B APPROVE 1 MINOR，v8.1 已處理）。

範圍：只改 app（狀態頁、`status_view_of`、加入流程的「已連上」判定 = join2 v7.2 §3.3-7），節點零改動。擁有權 / 契約一句話：只讀既有的 `status` 與 `info` 回答（擁有者 session），不寫任何東西、不加新欄位、不加新機制。
來源：S20 實測（#254 comment 6760039272）：「狀態：已加入網路」旁邊寫「網路狀況：中斷」，「原因」是節點的英文 joinwatch 句子而且說錯（KEY PLACEHOLDER：keyguard 擋的是手機 AP `default_radio0`，mesh `wlh0` 是起來的，真正原因是 0 台鄰居），「軟體版本：OpenMANET 1.8.0」是上游版本。

## 1. 事實（節點 Batman-p3 @ e5c89a1；app 2654dbc）
| # | 事實 | 證據 |
|---|---|---|
| F1 | status key 1 = 0 / 1 / 2 / 3；擁有者 session 只會是 1（已認領）或 2（成員）；legacy 認領後無線電照樣在跑；已在網路的節點拒絕 network/join | provd/session.go:855-862、server.go:60；node.go:570-571、1024-1026 |
| F2 | key 2 = health.level（OK 0 / WARN 1 / CRIT 2）= 最差值；CRIT 來源：mesh（keyguard、key、**plinks = 0 就是 CRIT**）、電源、電池、過熱、服務；儲存只到 WARN | status.go:187-189；halow-status:63-93（:76）、136 |
| F3 | keyguard：手機 AP 的 key 是 placeholder → 只關 AP 介面；mesh 的 key 是 placeholder → 關整個 radio；任一被擋，mesh 檢查都是 CRIT、reason_code 都是 1 | halow-keyguard:22-33；halow-status:31、72；joinwatch:86 |
| F4 | key 3 = `batctl n` 所有 hardif、含過期項目的鄰居數 → 不用來判定。plinks = station dump 的 ESTAB 數（快取 ≤ 30 s）：802.11s 的 plink 不會逾時（mesh_plink_timeout = 0），**已走遠 / 關機的隊員可能一直算在內**；batman 約 200 s 後才移除鄰居 | halow-status:38、164；status.go:190；Batman-p3 181-survival-strategy.md:26（F6 實測）、:97 |
| F5 | 節點的「已連上」= plink ≥ 1 且 wlh0 上有 batman 鄰居 = JOINED = **key 5 不存在**；JOINED 來自 joinwatch 的狀態檔（每 15 s）。所以隊員離開後，「已連上」最多還會維持約 200 s（batman 移除）+ 15 s（joinwatch）+ age_s（≤ 30 s），之後落到代碼 9 | meshjoin.sh:22-24；status.go:196-205；joinwatch:36；F4 |
| F6 | reason_code：1 keyguard（先查，會蓋掉 7–9）、2 key 未設、3 radio 關閉、4 沒起來、5 不在 mesh 模式、6 mesh11sd 關、7 沒聽到任何站台、8 聽到但沒有 plink、9 有 plink 但沒 batman 鄰居；reason_code 0 = 檢查都過了但 joinwatch 還沒寫 JOINED（≤ 15 s），或沒有判定（reason_code 缺或不是數字 → 0）。reason_code 是即時的 `joinwatch code`；join.state 則來自 joinwatch 的狀態檔：NOT_RUNNING = 這次開機 joinwatch 還沒寫過狀態檔；joinwatch 停掉時狀態檔不會刪，會留著最後的 JOINED / NOT_JOINED（procd 無限重啟，少見）。**只要有任何東西被 keyguard 擋住（GUARD ≠ none，包括只擋手機 AP）就一律報 1，看不到 3–9**。重開機可能有用的只有 4 / 5 / 8 / 9；joinwatch 自己的自動重開機要**連續 3600 s 沒入網**，而且 reboot_helps 成立（要求 GUARD = none、key 已設等），連續沒入網開機次數、間隔等條件也都要過才會做 → **有任何東西被擋時，joinwatch 永遠不會自動重開**（7 是孤單或太遠，不是故障；連續沒入網還會報 bootloop） | joinwatch:36-37、79-104、86-95、147、168、97-100（:99）、171-195（NOREBOOT :174-175）、205；halow-status:124、162-163；status.go:149、197-200 |
| F6b | 已認領、還沒入網的節點：mesh key 是 placeholder（認領不設 key）、RadioManaged = true → keyguard 關掉 morse radio → 代碼 1、k2 = 2 是**正常**（開機流程也當作預期） | Batman-p3 254-p3-impl.md:127（F74）；node.go:571；halow-keyguard:22-27；boot.go:361-375 |
| F6c | **從未認領狀態被認領的節點（app 流程）加入成為成員後，手機 Wi-Fi（AP）都是 placeholder，直到擁有者用「手機 Wi-Fi」設定**：未認領的節點開機時 99zz / helper `--apply-state --firstboot` 把所有 `mode=ap` 的 key 設成 placeholder（就算 image 有預設 AP key）；認領、network/join（wtxn）都不碰 AP；只有 settings/set key 20（`halow-setkey --ap`）會設。keyguard 就把 AP 關掉 → 代碼 1、k2 = 2。halow-keyguard 開頭「正常佈署不會遇到」指的是舊的批次 key 模式：對 app 流程的節點不成立，但對 legacy 已在網路的成員仍成立（它們保留批次 AP key，所以 JOINED 時的 CRIT 不一定是 AP）。設好之後 halow-setkey 當場清掉 keyguard 的標記並 reload wifi，不用重開。真實資料：04 的 halow-status 是 JOINED 而唯一的 CRIT 是 keyguard | 99zz-batman-prov-state:7-8、30-37、16；254-p3-impl.md:446；wtxn.go（只動 mesh：225、321）；settingsset.go:3-4、46；halow-keyguard:1-11（:10-11）、29-34；halow-setkey:277-285；testdata/halow-status-04-wsl22.json |
| F7 | key 15（只有擁有者）：image、uptime_s、temp_c、throttled、age_s、join.{state, channel, country, snr_db, plinks(可缺)}，可能有 uci_staged（陣列）、ssid_unsaved（true）、settings_restore；snr_db 是字串、可空 | status.go:206-224（ssid_unsaved :212-222）；halow-status:164 |
| F8 | snr = station dump 裡任何站台最強的 signal avg − 雜訊；讀不到雜訊用 −90 dBm（可能高估約 15 dB）；節點 < 20 dB 算 WARN | halow-status:41-44、80 |
| F9 | 快取超過 30 s 或讀不到 → 擁有者只拿到 {1, 15: {stale: true}} | status.go:181-186 |
| F10 | key 15 image = 上游 OpenMANET 版本；我們的 BATMAN_VERSION = **info key 4** | halow-status:17、156；provd/server.go:549；main.go:52-54 |
| F11 | 「手機 AP 沒設好」沒有結構化欄位（只有 reason_code 1 間接表示）；電池、服務、儲存不在 status → 已知缺口（#254 checklist） | settings.go:142-161；status.go:206-224 |
| F12 | app 現況：status 錯誤碼被丟掉（owner.rs:679-682）；key 2 譯成「網路狀況」、key 5 英文當「原因」、image 當版本；加入後的「已連上」用 k3 ≥ 1 且 plinks ≥ 1（flow.rs:183-184），顯示 k3（owner.rs:433） | owner.rs:1628-1685；member_ui.dart:165-186 |

## 2. 畫面（由上到下）
1. **連線判定**（§3）：顏色 + 一句白話 + 能做的事；下面小字「讀取於 HH:MM:SS」（app 讀取時間，只顯示）。列 3 / 4 另加小字「隊員剛離開或關機時，這裡最多約 4 分鐘後才會改變」。
2. ⚠️ 小字，第一個成立的一行：throttled bit 0 →「電源電壓不足 — 請檢查電池／電源線」；temp_c ≥ 80 →「節點過熱 — 請移到陰涼處」（throttled / temp_c 解析不出 → 不顯示）；否則 k1 = 2 且 k5.1 = 1 →「這台給手機連的 Wi-Fi 還沒設定（或被關閉）— 可在「手機 Wi-Fi」設定，設好後這頁才看得到連不上的真正原因；設好仍然如此請找維修人員」（只有這種情況才確定是 AP，F6c）；否則 k5 不存在 且 plinks ≥ 1 且 k2 = 2（列 3 / 4）→「節點回報異常（可能是手機 Wi-Fi 還沒設定）— 設好仍然如此請找維修人員」（中性句：legacy 成員的 AP 可能已設好；key 15 沒有逐項檢查，app 分不出其他 CRIT，所以不寫「技術資訊有細節」）。沒入網時 k2 = 2 是常態（F2），已認領的節點代碼 1 也是常態（F6b），都不顯示。
3. 網路歸屬（小字）：k1 = 2 →「網路：<名稱>（已是成員）」（M18：info key 10 對本機 net/、mnet/ 的 netcfg key 4；對不到 →「網路：別支手機建立的網路」；info key 10 缺 →「網路：（讀不到名稱）」）；k1 = 1 →「已認領，還沒加入網路」；0 / 3 不顯示。
4. 軟體版本 = info key 4；缺 → 不顯示。
5. 「重新整理」：重讀 status + info；status 回 E_RATE 時保留上一個判定（連同它的「讀取於」時間）、跳一行「太快了，請稍等一秒」。
6. 摺疊的「技術資訊（給維修人員看）」：key 2、key 5 代碼與英文句子、key 15 的 image / snr_db / plinks（= 直接連到的站台數 P）/ channel / country / age_s / uptime_s / temp_c / throttled / uci_staged / ssid_unsaved / settings_restore，以及：「SNR 門檻暫定；SNR 是最強那個站台的訊號（不一定是隊員，也可能是已離開的站台），雜訊讀不到時可能偏高」「隊員離開或關機後，『已連上』最多還會維持約 4 分鐘（節點約 200 秒才移除鄰居，再加上判定與快取）；站台數可能包含已離開的隊員」「joinwatch 停掉時節點會留著最後的狀態（少見），判定可能停在 🟢 或「之前連上的隊員現在收不到」」（v8.1 on-device fix 2）。
節點給的字串（版本、k5.2、k15 字串、uci_staged 的每一項）一律經 `display_name` 並截到 64 個字元（主畫面與技術資訊都是）；主畫面不出現英文句子或指令。

## 3. 連線判定表（由上往下第一個成立的列）
輸入：status 結果（成功的回答 / 錯誤碼 / 解不出）、k1、k5（在不在、k5.1）、plinks、snr（k15.join.snr_db 解析為整數；空、非數字 → 未知）、up（k15.uptime_s）。「找維修」= 「仍然如此請找維修人員」。
| # | 條件 | 顏色 | 句子 — 能做的事（k1 = 2） |
|---|---|---|---|
| 1 | status 回 E_UNSUPPORTED（節點軟體太舊，或節點的設定紀錄讀不到：status.go:270-272） | ⚪ | 這台節點看不到連線狀態（軟體太舊，或節點的設定紀錄讀不到）— 請找維修人員 |
| 2 | k15.stale、解不出回答、k1 缺、k15 缺、plinks 缺 | ⚪ | 狀態未知 — 請按「重新整理」；一直如此請重新開機或找維修人員（重開機會重啟 halow-status / joinwatch） |
| 2' | 其他錯誤碼（E_FORBIDDEN、E_REJECTED、沒有上一個判定時的 E_RATE 等） | ⚪ | 狀態未知 — 請按「重新整理」；一直如此請找維修人員 |
| 3 | k5 不存在 且 plinks ≥ 1 且 snr ≥ 20 | 🟢 | 已連上隊伍網路 |
| 4 | k5 不存在 且 plinks ≥ 1 | 🟡 | snr < 20：已連上，但訊號偏弱 — 可以靠近一點或換個位置；snr 未知：已連上（訊號強度讀不到） |
| B | up < 240 且（k5.1 ∈ {0, 4, 5, 7, 8, 9}，或 k1 = 2 且 k5.1 = 1） | 🟡 | 剛開機，正在尋找其他節點 — 請等一分鐘再按「重新整理」 |
| 5 | k5.1 ∈ {3, 6} | 🔴 | 這台的無線電設定被關掉了 — 請找維修人員 |
| 5″ | k5.1 = 2 | 🔴 | 這台的網路金鑰沒有設定 — 請找維修人員（等待或重開機都沒用） |
| 5' | k5.1 ∈ {4, 5} | 🔴 | 這台的無線電沒有正常運作 — 請重新開機；找維修 |
| U | k5.1 > 9（不認得的代碼） | 🔴 | 還沒連上 — 請找維修人員 |
| 6 | k5.1 = 8 | 🔴 | 有收到其他節點，但連不上 — 請對照下面「網路：」的名稱是否和隊長的相同；不同或仍然如此請找維修人員 |
| 7 | k5.1 = 7 | 🔴 | 附近沒有收到其他節點的訊號 — 請確認隊員的節點已開機、在附近、網路名稱和隊長的相同；找維修 |
| 8a | k5 存在 且 k5.1 = 0 且 plinks ≥ 1（即時檢查已過：剛接上、joinwatch 還沒寫 JOINED，或 joinwatch 沒在跑） | 🟡 | 正在接上網路 — 請等一分鐘再按「重新整理」；一直如此請找維修人員 |
| 8 | k5 存在 且（k5.1 = 9 或 plinks ≥ 1） | 🔴 | 之前連上的隊員現在收不到（可能走遠或關機），或還在連線中 — 請確認隊員在附近、已開機；等一分鐘按「重新整理」；找維修。**k1 = 2 且 k5.1 = 1**（被擋的成員，不會自動重開）：「找維修」前加「隊員就在旁邊仍然如此，請重新開機一次」 |
| 9 | 其他（例：k5.1 ∈ {0, 1}；k5 不存在但 plinks = 0，即 JOINED 落後） | 🔴 | (a) **k1 = 2 且 k5.1 = 1**（手機 Wi-Fi 沒設，F6c）：還沒連上其他隊員 — 請確認隊員的節點已開機、在附近、網路名稱和隊長的相同（看下面「網路：」）；隊員就在旁邊仍然如此，請重新開機一次；仍然如此請找維修人員。（(b) 已移到列 5″。）(c) 其他：還沒連上其他隊員 — 請確認隊員的節點已開機、在附近；等一分鐘再按「重新整理」，仍然如此請重新開機；找維修 |

- **k1 = 1**（已認領、不在隊伍網路；legacy 同）：顏色照表（句子已說明，不另改色）。列 3 / 4 →「已連上附近的節點，但這台還沒加入隊伍網路 — 要跟隊伍通訊請按「加入隊伍網路」」；列 6 / 7 / 8a / 8 / 9 →「這台還沒加入隊伍網路 — 請按「加入隊伍網路」」；列 5 / 5″ / 5' / U 與 B 用原句（無線電壞了或剛開機不是「請加入」），B 句尾加「；還沒加入隊伍網路」。k1 = 2 的列 6 不叫人「加入隊伍網路」（F1：節點已在網路會拒絕）。
- 主畫面不寫站台數（F4：可能含已離開的隊員）；P 只在技術資訊；k3 也只在技術資訊。🟢 只在節點自己判定 JOINED 且 snr ≥ 20；snr 未知不算良好。
- **誠實界線**：隊員離開或關機後，🟢 / 🟡「已連上」最多還會維持約 4 分鐘（F5）；之後落到列 8 的「之前連上的隊員現在收不到」。這是節點資料的特性，app 不另外推測。
- 列 8 是 🔴、沒被擋時不叫人重開機：隊員離開後 plink 不會逾時（F4），所以「隊伍不在附近」會一直停在列 8，直到 joinwatch 連續 3600 s 沒入網且條件都過才自動重開（F6）；**有任何東西被擋時（例如手機 Wi-Fi 沒設的成員）joinwatch 永遠不自動重開**，列 8 會一直維持。這是**列 8 的常態**，不是故障；多半是隊員離開，重開機只會打斷其他連線。重開機只在列 2（stale / 解不出：重開機會重啟 halow-status / joinwatch）、列 5'、被擋成員（k1 = 2 且代碼 1）的列 8 與列 9 (a)、列 9 (c)：被擋成員有條件（隊員就在旁邊仍然如此），因為代碼 1 蓋掉 3–9（列 8 時藏著的常是代碼 9，重開機可能有用：joinwatch:99），joinwatch 又不會自動重開，這是唯一的退路；沒被擋的節點在列 8 不叫人重開機（joinwatch 1 h 後會自己判斷）；(c) 是代碼 0 / JOINED 落後。代碼 2 不叫人重開機（key 沒設）。k1 = 1 的代碼 1 是設計上關掉無線電（F6b），重開機沒用，它的句子本來就沒有重開機。每個階梯都以「找維修」結尾。節點端後續（代碼 1 只算 morse radio 的 guard）記 #254 checklist。
- 剛開機列 B 含代碼 0（joinwatch 還沒寫狀態）與成員的代碼 1（F6c：每台成員都有，否則剛開機會一直看到列 9）；不含 2 / 3 / 6 與 k1 = 1 的代碼 1：那些是設定狀態（key、radio 被關），等多久都一樣。代碼 0 且 k5 存在：plinks ≥ 1 → 列 8a（即時檢查已過，不該是 🔴）；plinks = 0 → 列 9 (c)。
- **AP ⚠️ 為什麼要一直顯示（不要當雜訊拿掉）**：手機 Wi-Fi 沒設的成員 (1) 代碼 1 蓋掉 3–9，app 看不到連不上的真正原因；(2) joinwatch 不會自動重開（F6）；(3) k2 一直是 CRIT，會蓋掉其他 CRIT（電源、服務等）。所以不設手機 Wi-Fi 的隊伍也會一直看到它；設好之後 halow-setkey 當場清掉標記（halow-setkey:277-285），約 20–30 秒內消失（status 快取 ≤ 16 s：status.go:23、28-30；更早按「重新整理」可能還看得到）。
- k1 = 1 的「請按加入隊伍網路」假設這支手機握有該網路的紀錄（目前單一管理者）；多支手機管理同一隊伍時的用字記 #254 checklist。
- 暫定：up < 240（JOINED 在 ≤ 180 / 240 s 的實測預算，Batman-p3 202-config-survival-closeout.md:203、214）、SNR 20 dB。⚠️ 未驗證、進硬體測試清單：入網要多久；開機後多久 wlh0 才在、代碼 4 / 5 何時出現；不同金鑰的站台是否出現在 station dump 並有 signal avg；Pi4 上 `halow-status json` 跑多久（超過 status 的首次 2 s 等待 → 第一次讀常是列 2，所以列 2 先叫人按「重新整理」）；**隊員離開**：JOINED 時關掉另一台，在 0 / 60 / 240 / 600 s 記錄本頁（負對照：不關機的同一時間點維持 🟢）；每一台 app 流程的成員節點在設定「手機 Wi-Fi」之前都會一直顯示 AP 的 ⚠️（F6c，預期；設好後等 ≥ 16 s + 實測的 `halow-status json` 執行時間再按「重新整理」（或重試）消失 = 負對照）。

## 4. 實作（審過再做）
- Rust：`link_verdict(status 結果, info) -> (顏色, 句子, ⚠️ 行)` 純函式，文字在 Rust（既有慣例）；bridge 的 status-page 讀取保留錯誤碼（F12）。
- 加入後的「已連上」（`flow::link_state`）照 join2 v7.2 §3.3-7：stale → Unknown，age_s 早於 join → NotYet（都與今天相同）；列 1–2 → Unknown，列 3–4 → Connected，其餘 → NotYet；`link_text` 不寫站台數。
- Dart（member_ui.dart StatusPageView、nodes.dart `_statusPage`）：§2 排版、「重新整理」、E_RATE 保留。

## 5. 測試（每項附負對照；每臂寫明 up）
- T1（Rust）**表格驅動的性質測試**：「重新開機」出現 ⇔ 列是 2（stale / 解不出）、5'、k1 = 2 且代碼 1 的列 8、9 (a)、k1 = 2 的 9 (c)；其他每一列都是它的負對照，至少含列 2'（E_FORBIDDEN）、6（代碼 8）、8a、B、5″、U（代碼 10 →「還沒連上 — 請找維修人員」）、k1 = 1 + 代碼 1 + plinks 1（已認領節點的列 8 不得出現成員的那一句）。每列一臂，含：S20（k1 = 2、k2 = 2、plinks = 0、k5.1 = 1、up 600 → 列 9 (a)：含網路名稱對照與「隊員就在旁邊仍然如此，請重新開機一次」+ AP ⚠️；負對照：v6 的句子（沒有重開機）→ FAIL）；k1 = 2 + 代碼 1 + plinks 1 + up 600 → 列 8，含「隊員就在旁邊仍然如此，請重新開機一次」（負對照：v7 列 8 句子 → FAIL）；同上 up 30 → B；代碼 0 + plinks 1 + up 600 → 列 8a 🟡（負對照：v6 落到列 8 🔴 → FAIL）；k1 = 2 + 代碼 2 + up 600 → 列 5″「這台的網路金鑰沒有設定」，無「重新開機」、無「等一分鐘」（負對照：v7 的 9 (b)、9 (c) 句 → FAIL）；k1 = 2 + 代碼 1 + up 30 → B；代碼 0 + up 30 → B；JOINED → 列 3 句子沒有數字；代碼 9 + plinks 1 + up 600 → 列 8、🔴、無「重新開機」；up 200 + 代碼 7 → B；up 300 + 代碼 7 → 列 7；k3 = 1、plinks = 0、k5.1 = 7、up 600 → 列 7（無「重新開機」、非 🟢）；up 30 + 代碼 4 / 7 / 8 → B；k1 = 2 + 代碼 8 + up 600 → 無「加入隊伍網路」；k1 = 1 + 代碼 1 + up 600 → 「這台還沒加入隊伍網路」，無「重新開機」；k1 = 1 + JOINED → 列 3 的 k1 = 1 句；k1 = 1 + 代碼 4 + up 600 → 列 5' 原句；代碼 8 + plinks 1 → 列 6；k5 存在 + 代碼 0 + plinks 0 → 列 9 (c)；k5 不存在 + plinks 0 → 列 9；代碼 3 → 無「重新開機」。負對照：v1 規則（k3 ≥ 1 就 🟢）、看 k3、用 key 2 定顏色、k1 定顏色、代碼 1 當列 5、拿掉剛開機規則、v3 列 8 的句子（叫代碼 7 重開機）。
- T2（Rust）E_UNSUPPORTED → 列 1；解不出 / stale / k1 缺 / k15 缺 / plinks 缺 → 列 2（有重開機）；E_REJECTED / E_FORBIDDEN / E_RATE → 列 2'（無重開機）；E_RATE 只在沒有上一個判定時（第一次讀）才是列 2'，有上一個判定就保留它（T8）。負對照：錯誤落到其他列。
- T3（Rust）snr 19 / 20 / −3 / "" / "abc"；"" 與 "abc" → 列 4「已連上（訊號強度讀不到）」、沒有「靠近一點」（負對照：v7 句子 → FAIL）。負對照：門檻用 ≤、未知當良好。
- T4（Rust）版本取 info key 4；⚠️：throttled "0x50005" / "0x50000" / "xyz"、temp 79 / 80 / ""（解析不出 → 無）、JOINED + plinks 1 + k2 = 2 → 中性句「節點回報異常（可能是手機 Wi-Fi 還沒設定）」（負對照：v6 的「這台給手機連的 Wi-Fi 可能還沒設定」→ FAIL）；k5 不存在 + plinks 0 + k2 = 2 → 無；k1 = 2 + 代碼 1 → AP 行，含「設好後這頁才看得到連不上的真正原因」（負對照：v5 的「其他問題…技術資訊有細節」句、v6 的 AP 句 → FAIL）；k1 = 1 + 代碼 1 + up 600 → 無；沒入網（代碼 7、8；up 30 與 600）+ k2 = 2 → 無；k2 = 1 → 無。負對照：用 image、v3 規則（k2 = 2 就顯示）、v4 規則（代碼 1 不看 k1、JOINED 不看 plinks）。
- T5（Rust）真實資料 `testdata/halow-status-04-wsl22.json`（從 Batman-p3 e5c89a1 `feed/batman-prov/src/node/testdata/` 複製）照 status.get 編碼（status.go:187-224）→ 判定與欄位如預期。
- T6（Rust）RLO / 換行 / 超過 64 字元的節點字串（含 uci_staged 每一項）在主畫面與技術資訊都被過濾、按字元截斷。負對照：不過濾。
- T7（Rust）`flow::link_state`（取代 join2 T11 的臂）：stale → Unknown、age_s 早於 join → NotYet（與今天相同）；JOINED + plinks ≥ 1 → Connected{plinks}；k3 缺 + JOINED + plinks 1 → Connected；k5 不存在 + plinks 0 → NotYet；代碼 9 + k3 ≥ 1 + plinks ≥ 1 → NotYet。負對照：舊規則（k3 與 plinks）、只看 JOINED。
- T8（widget）第一行是判定，下面有「讀取於」；列 3 / 4 有「最多約 4 分鐘」小字（負對照：拿掉 → FAIL）；E_RATE 保留時顯示的是上一次的讀取時間；主畫面找不到 k5 英文與 image；展開技術資訊才看得到（含 ssid_unsaved；負對照：漏掉 → FAIL）；「重新整理」呼叫讀取；E_RATE 保留上一個判定。負對照：reason 放回主畫面。M18 照舊。
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
| v3 M5 與凍結的 join2 §3.3-7 衝突 | join2 升 v7.2（同一 commit）重寫 §3.3-7 與 T11；T7 負對照；link_text 顯示 P（v4 M2 拿掉） |
| v3 minors | 列 9 = 純「其他」（含 JOINED 落後）；剛開機優先、k1 = 1 用字附加；列 5 / 5' 不換成「請加入」；電源 / 過熱附行動；⚪ 長久不變的退路；JOINED 落後寫進技術資訊；dev 節點 ⚠️ 進硬體清單；k1 = 1 不另改色；uci_staged 每項過濾 |
| v4 M1 已認領未入網的節點一直顯示 ⚠️ | 代碼 1 的 ⚠️ 只在 k1 = 2；JOINED 的 ⚠️ 需 plinks ≥ 1；F6b（F74）；T4 臂與負對照 |
| v4 M2 隊員離開 / 關機 | F4 / F5 改正（plink 不逾時、batman 約 200 s）；主畫面 🟢 不寫數字；列 8 改為「之前連上的隊員現在收不到…」、不叫人重開機（joinwatch 會自動重開）；誠實界線；硬體清單加關機測試與負對照；join2 §3.3-7 同步 |
| v4 minors | join2 §3.3-7 刪「key 3 缺」、§5 列改名；T7 stale → Unknown、早於 join → NotYet；剛開機 240 s（202 預算）；列 B 為何不含 1 / 2 / 3 / 6；halow-status 執行時間進硬體清單、列 2 先按重新整理；SNR 可能來自已離開的站台；throttled / temp 解析不出 → 無 ⚠️；k1 = 1 用字假設單一管理者 |
| v5 M1 成員的手機 AP 沒設是常態 | 先查證（F6c：99zz 把未認領節點的 AP key 設成 placeholder，認領 / join 不碰 AP，只有 settings/set key 20 會設；04 真實資料）；k1 = 2 + 代碼 1 → AP 行；JOINED 的 ⚠️ 改成 AP 優先的句子；列 9 對 k1 = 2 + 代碼 1 不叫人重開機；列 B 納入；硬體註記改為「每台成員」；T4 / T1 臂 |
| v5 M2 一般使用者看不到落後界線 | 列 3 / 4 小字「最多約 4 分鐘後才會改變」；「讀取於 HH:MM:SS」；E_RATE 保留舊時間；T8 |
| v5 M3 列 8 是隊伍離開的常態 | 列 8 改 🔴（文字不變）；F6 改正自動重開機的時機（3600 s + 條件）；誠實界線；T1 臂 |
| v5 minors | 「上面」→「下面」；JOINED ⚠️ 不寫「技術資訊有細節」；代碼 0 剛開機 → B；E_UNSUPPORTED 也可能是設定紀錄讀不到；joinwatch 沒在跑的落點；v3 M5 註記；列 8 條件加括號；T5 資料來源 |
| v6 M1（A = B）手機 Wi-Fi 沒設的成員沒有重開機的路 | F6 改正（任何東西被擋就報 1、蓋掉 3–9；guard 時 joinwatch 永不自動重開，joinwatch:86-95、99、174-175）；列 9 (a) 加網路名稱對照與「隊員就在旁邊仍然如此，請重新開機一次」；AP ⚠️ 加「設好後才看得到真正原因」；§3 重開機說明改正（k1 = 1 的代碼 1 重開機沒用）；列 8 誠實界線（被擋時永不自動重開）；T1 臂，負對照 = v6 句子 |
| v6 minors | AP ⚠️ 為什麼一直顯示（halow-setkey:277-285）；F7 / 技術資訊加 ssid_unsaved；代碼 0 + plinks ≥ 1 → 列 8a 🟡；F6c 限於 app 流程的節點、JOINED 的 ⚠️ 改中性句；代碼 2 不叫人重開機（列 9 (b)）；T1 加 k1 = 2 + 代碼 1 + plinks ≥ 1 的 up 600 / 30 臂；T2 寫明 E_RATE 何時是列 2；A-m7 由網路名稱對照涵蓋 |
| v7 M1（B）被擋成員的列 8 沒有重開機的路 | 列 8 對 k1 = 2 且代碼 1 加「隊員就在旁邊仍然如此，請重新開機一次」（藏著的代碼 9 重開機可能有用，被擋時又不會自動重開，joinwatch:99、174-175）；沒被擋的列 8 不變；§3 重開機說明更新；T1 臂，負對照 = v7 列 8 句子 |
| v7 minors | 列 9 (b) 改「這台的網路金鑰沒有設定 — 請找維修人員」+ T1 負對照；F6：NOT_RUNNING 的意思、joinwatch 停掉時留著舊狀態（技術資訊加一句）、代碼 0 也代表沒有判定；列 4 snr 未知 →「已連上（訊號強度讀不到）」+ T3；AP ⚠️ 約 20 秒內消失、硬體步驟等 ≥ 20 s；A-m4 不改（列 8 句子已涵蓋） |
| v8 minors | 列 2 拆成 2（stale / 解不出，有重開機）與 2'（其他錯誤碼，無重開機），§3 重開機清單加列 2；T1 改成表格驅動的「重新開機」性質測試（含列 6、8a、B、已認領節點的列 8）；代碼 > 9 → 列 U「還沒連上 — 請找維修人員」+ T1 臂；代碼 2 移到列 5″（設定故障那一組）；AP ⚠️ 約 20–30 秒、硬體步驟等 ≥ 16 s + 實測 halow-status 執行時間 |
| v8.1 on-device fixes（S20，#254 comment 6762364489；不改規則） | (1) k1 = 1 的句子點名這支手機真正有的按鈕：有 net/ 紀錄（管理者）→「加入網路／繼續加入」、只有 mnet/（成員）→「加入隊伍網路」、都沒有 →「可按「建立網路」，或向管理者要邀請」（bridge 傳 has_net / has_mnet，判定本身不看 UI）；(2) 技術資訊說明「列 8」改成白話「之前連上的隊員現在收不到」；(3)「重新整理」讀取中停用並顯示「讀取中…」，連按第二下不會再讀（E_RATE 的提示不變）；各附測試與負對照 |
| 跨文件：S6 離開網路 v3（254-app-leave.md §2；審查 v2 B-M2） | 狀態頁加一行：info key 11 = true（unfinished，現讀）時在 ⚠️ 行之後顯示「節點上還有沒完成的網路變更（加入中也會這樣）— 等一下再按「重新整理」；離開網路後仍然如此，可以再按「離開網路」或重新開機一次」。理由：離開網路已 commit 但無線電沒清（k10 缺、k11 = true）時，判定只會說「這台還沒加入隊伍網路」，而無線電可能還在隊伍網路上；括號一句是因為加入進行中 k11 也是 true（readonly.go:134-136）。不改判定表；測試在 S6 T3 |
