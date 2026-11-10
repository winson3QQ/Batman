# #254 app S4 — 看得懂的狀態頁（設計 v1，待審）

範圍：只改 app（`status_view_of` / 狀態頁畫面），節點零改動。擁有權 / 契約一句話：只讀既有的 `status` 與 `info` 回答（擁有者 session），不寫任何東西、不加新欄位。
來源：S20 實測（#254 comment 6760039272）：「狀態：已加入網路」旁邊寫「網路狀況：中斷」，「原因」是節點的英文 joinwatch 句子而且說錯（KEY PLACEHOLDER：keyguard 擋的是手機 AP `default_radio0`，mesh `wlh0` 是起來的，真正原因是 0 台鄰居），「軟體版本：OpenMANET 1.8.0」是上游版本。

## 1. 事實（節點 Batman-p3 @ e5c89a1；app 9b070ab / f139951）
| # | 事實 | 證據 |
|---|---|---|
| F1 | status key 1 = 節點狀態數字 0 未認領 / 1 已認領 / 2 成員 / 3 legacy（helper 給字串，provd 轉數字；不認得 → E_REJECTED） | provd/session.go:855-862、server.go:60 |
| F2 | key 2 = health.level 的總結（OK 0 / WARN 1 / CRIT 2），是**所有**檢查的最差值：keyguard、電源、溫度、服務、儲存……不只連線 | node/status.go:189-191；halow-status:63-93、136 |
| F3 | halow-status 的 keyguard 檢查看整個 `/etc/halow-keyguard.blocked`，所以手機 AP 被擋也會讓 mesh 檢查變 CRIT「on-air blocked」→ key 2 = 2（S20 就是這樣） | halow-status:31、72 |
| F4 | key 3 = batman 鄰居數（join.batman_neighbours），快取沒資料時缺 | status.go:192-194；halow-status:41 |
| F5 | key 5 只在 join.state ≠ JOINED 時出現：{1 reason_code, 2 英文句子}；reason_code 1 = keyguard（先檢查，會蓋掉後面的 7 沒鄰居 / 8 有訊號沒 plink / 9 沒 batman 鄰居） | status.go:198-205；joinwatch:85-104 |
| F6 | key 15（只有擁有者）：image、uptime_s、temp_c、age_s、join.{state, channel, country, snr_db, plinks(可缺)}；snr_db 是字串，可空 | status.go:206-211；halow-status:164 |
| F7 | 快取超過 30 s 或讀不到 → 擁有者只拿到 {1, 15: {stale: true}}，成員只拿到 {1} | status.go:181-186 |
| F8 | 成員角色永遠沒有 key 15（helper 不給、provd 再過濾）；app 的狀態頁一律以擁有者登入 | status.go:11、181；session.go:866 |
| F9 | key 15 image = `"OpenMANET " + /etc/openwrt_version`（上游）；我們的 image 版本 = `/etc/batman-build` 的 BATMAN_VERSION = **info key 4**（任何角色都有） | halow-status:16；provd/server.go:549、cmd/batman-provd/main.go:52-54 |
| F10 | 「手機 AP 沒設好」沒有任何結構化欄位：settings/get key 20 只有 SSID；keyguard / key=PLACEHOLDER 只在 halow-status 的英文句子與 checks，status 沒傳 → **不顯示** | node/settings.go:142-161；status.go:206-211 |
| F11 | app 現況：`status_view_of` 把 key 2 譯成「網路狀況」、key 5 英文句子當「原因」、key 15 image 當版本；StatusPageView 逐列顯示 | bridge owner.rs:1628-1685；member_ui.dart:165-186 |

## 2. 畫面
1. 第一行：連線判定 = 顏色 + 一句白話 + 使用者能做的事（下表）。
2. 第二行（小字）：網路歸屬：key 1 = 2 →「網路：<名稱>（已是成員）」（名稱照 M18：info key 10 對到本機 net/、mnet/ 紀錄的 netcfg key 4；對不到 →「網路：別支手機建立的網路」）；1 →「已認領，還沒加入網路」；0 →「未認領」；3 →「舊版節點」。
3. 第三行：軟體版本 = info key 4（BATMAN_VERSION）；缺 → 不顯示。
4. 摺疊的「技術資訊（給維修人員看）」：key 2 等級、key 5 代碼與英文句子、key 15 image / snr_db / plinks / channel / country / age_s / uptime_s / temp_c 原樣。主畫面永遠不出現節點的英文句子或指令。

## 3. 連線判定表（由上往下第一個成立的列）
輸入：S = status 回答（沒有 = 讀不到），k1 / k3 / k15 / snr（k15.join.snr_db 解析成整數，失敗 = 未知）/ plinks。
| # | 條件 | 顏色 | 句子 — 能做的事 |
|---|---|---|---|
| 1 | 讀不到 S，或 k15.stale = true，或 k1 缺 | ⚪ | 狀態未知，稍後再查看 |
| 2 | k1 ≠ 2 | 🔴 | 還沒加入網路 — 請先「加入網路」或「加入隊伍網路」 |
| 3 | k3 缺 | ⚪ | 狀態未知，稍後再查看 |
| 4 | k5.1 ∈ {3, 4, 5, 6}（無線電關閉 / 沒起來 / 不在 mesh 模式 / mesh11sd 關） | 🔴 | 這台的無線電沒有正常運作 — 請重新開機；仍然如此請找維修人員 |
| 5 | k3 = 0 且 plinks ≥ 1 | 🟡 | 已收到其他節點的訊號，但還沒接上網路 — 請等一分鐘再查看 |
| 6 | k3 = 0 | 🔴 | 還沒連上其他隊員 — 附近沒有收到其他節點的訊號。請確認其他隊員的節點已開機、距離不要太遠。 |
| 7 | k3 ≥ 1 且 snr < 10 | 🟡 | 已連上，但訊號不穩 — 可以靠近一點或換個位置 |
| 8 | k3 ≥ 1 且 10 ≤ snr < 20 | 🟢 | 已連上，附近有 N 台隊員節點（訊號普通） |
| 9 | k3 ≥ 1（snr ≥ 20 或未知） | 🟢 | 已連上，附近有 N 台隊員節點 |

- **不用** key 2（F2/F3：混入非連線項目，S20 就是誤報）與 key 5 的代碼 1 / 2 / 7–9（F5：代碼 1 會蓋掉真正原因）；只有 3–6 是無線電本身的狀態才用（列 4）。key 2、key 5 全部放技術資訊。
- SNR 門檻 20 / 10 dB **暫定**（halow-status:80 用 20 當 WARN）：畫面在技術資訊註明「暫定，依現場資料調整」。待決：10–20 dB 是 🟢「普通」還是 🟡（使用者定）。
- plinks 缺（F6 選填）→ 列 5 不成立，落到列 6。

## 4. 實作（審過再做）
- Rust（bridge owner.rs）：`StatusView` 改帶結構化欄位（k1、k3、plinks、snr、stale、reason_code、fw_version = info key 4、tech 文字）；判定表寫成純函式 `link_verdict(&StatusView) -> (color, sentence)`，文字在 Rust（同既有慣例），Dart 只排版。
- Dart（member_ui.dart StatusPageView）：第一行判定、第二行歸屬、第三行版本、`ExpansionTile` 技術資訊。nodes.dart `_statusPage` 不變（仍是 status + info 兩次讀）。

## 5. 測試（每項附負對照）
- T1（Rust）判定表每一列各一臂，含 S20 臂：k1 = 2、k2 = 2、k3 = 0、plinks = 0、k5.1 = 1（keyguard）→ 列 6 的句子（不是「無線電」、不是「中斷」）。負對照：用 key 2 決定顏色 → S20 以外的 k2 = 2、k3 ≥ 1 臂 FAIL；把代碼 1 當列 4 → S20 臂 FAIL。
- T2（Rust）stale / 讀不到 / k3 缺 → 列 1 / 3。負對照：stale 當 0 鄰居 → FAIL。
- T3（Rust）SNR 邊界 9 / 10 / 19 / 20 / 空字串。負對照：門檻用 ≤ → FAIL。
- T4（Rust）版本取 info key 4，不取 key 15 image。負對照：用 image → FAIL。
- T5（widget）主畫面第一行是判定、找不到英文 key 5 句子與 image；展開技術資訊後才看得到。負對照：把 reason 放回主畫面 → FAIL。M18 名稱對應照舊。
