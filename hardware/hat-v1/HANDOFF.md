# HAT v1 交接說明（雲端 session → 本機）

最後更新：2026-09-28（本機接手後見 §6）。本文件說明目前進度、怎麼在本機重現每一步、以及還沒完成的事。
標記：**【事實】** 可在 repo / 報告中查證；**【推論】** 尚未實測。

---

## 1. 現在做到哪

| 階段 | 狀態 |
|---|---|
| 規格書 `docs/design/hat-v1-spec.md` | DRAFT v2，含 §5.5.5 電源樹審查（方案 D）、§2 使用情境 |
| 原理圖（`gen/design.py` → 9 頁 KiCad 7） | 完成，`gen/check.py` PASS：0 錯誤 0 警告【事實】 |
| 模擬（`sim/run_all.py`） | 4 組全部符合設計意圖【事實】 |
| LCSC 料號 | 部分完成（見 `out/lcsc-report.md`）；約 31 項待人工查 |
| 擺位 | 174 顆全部擺好，零件外框無重疊【事實】 |
| 佈線 | **2026-09-28 本機收尾：0 未接、0 間距 / 鑽孔錯誤**（見 `closeout/README.md`）；主電流路徑的線寬尚未處理（§6） |
| Gerber / 鑽孔 / CPL / JLC 檔（M5） | 未開始 |
| 上機指南（M6） | 未開始 |

## 2. 本機需要的工具

| 工具 | 版本 | 備註 |
|---|---|---|
| KiCad | **7.0.x** | 程式使用 KiCad 7 的 `pcbnew` Python 介面與 `kicad-cli`；KiCad 8 / 9 介面有變動，可能要改程式【推論】 |
| Python 3 | 3.11 左右 | `pip install numpy shapely matplotlib`（`pcbnew` 模組隨 KiCad 安裝） |
| ngspice | 共享函式庫 `libngspice` | 只有跑模擬時需要 |
| Java | 21 | 跑 Freerouting |
| Freerouting | 2.1.0（`freerouting-2.1.0.jar`） | 不在 repo 內，從 github.com/freerouting/freerouting 的 Releases 下載 |

以上皆非中國來源（KiCad、ngspice、Freerouting 為開源社群專案；Java 可用 OpenJDK）。

### Freerouting 的三個坑（雲端踩過）【事實】

1. **會傳使用資料**到 `api.freerouting.app`：第一次開啟後在設定（`freerouting.json` 的 `usage_and_diagnostic_data.disable_analytics = true`、`profile.allow_telemetry = false`）關掉，或設環境變數 `FREEROUTING__USAGE_AND_DIAGNOSTIC_DATA__DISABLE_ANALYTICS=true`。
2. **「最多幾輪」只在圖形介面模式生效**：`--gui.enabled=false` 的無介面模式上限寫死 99999 輪、要跑到自己停才存檔，中途砍掉結果全失。本機直接用圖形介面：`java -jar freerouting-2.1.0.jar -de X.dsn -do X.ses -mp 100`。
3. **跑完會跳「使用者設定」視窗**（問 email、是否送資料）擋住存檔：按 Save 才會寫出 `.ses`。

## 3. 重現流程（在 `hardware/hat-v1/` 下）

```sh
./build.sh                                  # 原理圖 + 檢查 + BOM 草稿 + PDF
python3 sim/run_all.py                      # 模擬 → out/sim/sim-report.md
python3 gen/gen_fp.py                       # 自製封裝 batman.pretty
python3 gen/layout.py --no-route            # 擺位（套用 gen/nudges.json、gen/positions.json）
python3 -c "import sys; sys.path.insert(0,'gen'); import layout as L; print(L.prepare_routing())"
#   → out/route/batman-hat.dsn，丟給 Freerouting（上面的指令），得到 batman-hat.ses
python3 -c "import sys; sys.path.insert(0,'gen'); import layout as L; print(L.finish('out/route/batman-hat.ses'))"
#   → 讀回走線、打接地縫合孔、加寬電源線、鋪地、DRC 報告 out/route/drc.txt
```

補線（保留現有走線，只補缺的）：

```sh
python3 -c "import sys; sys.path.insert(0,'gen'); import layout as L; print(L.prepare_reroute())"
#   → out/route/batman-hat-inc.dsn → Freerouting → batman-hat-inc.ses
python3 -c "import sys; sys.path.insert(0,'gen'); import layout as L; print(L.finish('out/route/batman-hat-inc.ses', replace=True))"
```

`gen/layout.py` 裡的輔助函式：

| 函式 | 用途 |
|---|---|
| `stitch_gnd()` | 在接地焊盤旁、孤立銅箔、3 mm 網格打接地孔（在 `finish()` 內自動呼叫） |
| `remove_dangling()` | 清掉拆線後的懸空殘段（`finish()` 內自動呼叫） |
| `clear_for_gnd()` | 為打不下孔的接地焊盤打孔，並拆掉擋路的內層 / 背面走線 |
| `nudge_for_gnd(targets, rip_front=...)` | 零件挪 ≤ 1 mm 讓接地焊盤能打孔，結果記在 `gen/nudges.json` |
| `repack(refs)` | 某顆晶片轉向後，把它周邊的小零件就近重擺，記在 `gen/positions.json` |

## 4. 還沒完成的事（依優先順序）

1. **佈線收尾**（見 §5 最新狀態）：左側 eFuse（U1）那一欄的 VBAT_RAW / VBAT_DAMP / EF_DRV，以及 TPM 的 SPI1_SCLK 等少數幾條；建議在 KiCad 裡手動拉線，比再跑自動佈線有效【推論】。
2. **H1 禁佈區警告**：H1 已改成不鍍銅孔，禁佈區範圍待拿到 Raspberry Pi 4 機構圖後修正。
3. **待補的封裝**：Seiko CPH3225A 超級電容（需規格書）、卡片支撐柱 H5/H6（量完卡片高度，規格 V14 後定）。
4. **LCSC 料號**：`out/lcsc-report.md` 中標 SEARCH 的項目。
5. **法規**：HaLow 在台灣 920–925 MHz 的功率上限需對照 LP0002 原文（repo 內兩個來源矛盾：27 dBm vs 17 dBm）。
6. **M5**：Gerber、鑽孔、CPL、BOM 給 JLC；Tier A 元件（TPM、ATECC、RTC、GNSS）不交 JLC 打件。
7. **M6**：上機指南。

## 5. 最新佈線狀態（2026-09-28 雲端 session 收尾）

**repo 內的 `batman-hat.kicad_pcb` 與擺位程式一致**（U1 角度 0°、無 `gen/positions.json`）。
用 KiCad 7 打開後跑 DRC 應得到：10 個未接、0 個間距 / 防焊 / 鑽孔錯誤【事實】。

| # | 網路 | 位置 | 說明 |
|---|---|---|---|
| 1–2 | VBAT_RAW | 左側 eFuse U1 第 5 腳附近 | U1 左排腳面對板邊（距板邊 1.6 mm），拉不出去 |
| 3 | VBAT_DAMP | R19 ↔ C33 | 同一區，左側欄只有 8 mm 寬 |
| 4 | EF_DRV | U1 第 4 腳 | 同上 |
| 5 | PG_5V | 5 V 降壓 U3 附近 | 拆線補線的殘留短斷點 |
| 6 | VCC_5V | U3 第 6 腳 ↔ R17 | 同上 |
| 7 | 5V_BUCK | C17（不打件的前饋電容）焊盤 | 焊盤仍需接上 |
| 8 | HALOW_RESET_N | 內層 In2 一小段 | 殘留短斷點 |
| 9 | SPI1_SCLK | TPM U11 第 19 腳 | 孔已在腳旁，差最後一段 |
| 10 | — | 另 1 個接地銅箔碎塊 | — |

**建議做法**【推論】：
- 5–9 多是很短的斷點，在 KiCad 裡手動補一小段線或一個孔即可。
- 1–4（eFuse 左側欄）：手動拉線；必要時把 R19 / C33 往右挪 0.5–1 mm 讓出走線空間。

**試過但失敗、已撤回的做法**（避免重蹈覆轍）【事實】：
把 U1 逆時針轉 90°（讓空腳 19–24 面向板邊），再用 `repack()` 把周邊 11 顆零件就近重擺。
結果未接從 8 變 19，還多出 19 個間距、15 個防焊錯誤：重擺的零件壓到附近既有的孔和走線。
若要走這條路，應該**整板重新擺位 + 重新佈線**，而不是在已佈好的板上局部改。

**佈線成果的演進**（每一步都有提交可查）：

| 回合 | 未接 |
|---|---|
| 第一輪（零件間距 0.2 mm） | 68 |
| 放寬間距（晶片 1.0 mm、被動 0.5 mm） | 53 |
| 修 MOSFET 封裝與間距規則 | 37 |
| 補線模式 + 接地縫合孔 | 19 → 17 |
| 零件微調讓接地焊盤打孔（`gen/nudges.json`） | 10 |

## 6. 本機接手（2026-09-28）

- 工具：WSL Ubuntu 24.04 + KiCad 7.0.11（apt）+ OpenJDK 21 + Freerouting 2.1.0；流程在 `closeout/run.sh`。
- §5 的 10 個未接全部解掉。其中左側 eFuse 欄是擺位問題，不是補線問題：U1、Q1 各轉 90°，主電流改走鋪銅。細節見 `closeout/README.md`。
- 結果【事實，`pcbnew.WriteDRCReport`】：**0 未接**；間距、鑽孔、防焊、`starved_thermal` 都是 0。剩下 `items_not_allowed` ×2（H1，§4-2）與 6 段橋接型懸空線（warning）。
- **新發現（雲端版就有）**：主電流路徑的最窄處只有 0.35 mm，包括 VSYS→U3、5V_BUCK、5V_PI→J2、3V3_BUCK。3.5–3.85 A 的路徑不能只靠 0.35 mm。用 `closeout/bottleneck.py` 可以量。這是下一步。
- §5 建議的「手動拉線」對 1–4 項不成立：Q1 的 source 腳面向板邊，只放得下一個 0.3 mm 的孔，卻要走整顆電池的電流。
- 坑：`build.sh` 會洗掉 `.kicad_pro` 的 PCB 規則（跑 DRC 前要還原）；Freerouting 無介面模式不理會 `-mp`。

## 7. 2026-09-28 本機第二段：電源分配（未完成，下個 session 照正規流程重來）

### 7.1 現況
- 板子 = commit `b1f344a`：0 未接、0 間距 / 鑽孔錯誤（§6）。這一段的實驗**沒有進板子**。
- 電源鋪銅的實驗存成 `closeout/experiments/power-pours.patch`（對 `closeout/closeout.py`），**未通過 0 未接檢查**，僅供參考。
- 工具已改進並提交：
  - `bottleneck.py`：會量鋪銅的真實細頸，並指出位置。
  - `rt.py`：修正 KiCad「fractured」鋪銅的零寬切縫；不修的話，收縮運算會量出假細頸。
  - `run.sh`：Freerouting 改成無介面模式，不再跳對話框；加上逾時和 .ses 檢查。
  - `post.py`：收尾時移除佈線用的禁止走線區。

### 7.2 發現（雲端版就有，已量測）
| 主電流路徑 | 需要的電流 | 最窄處（b1f344a） | 實驗中做到 | 限制 |
|---|---|---|---|---|
| J1→Q1 / Q1→U1 / U1→R9 | 約 3.5 A | 2.87 / 1.67 / 1.47 mm（鋪銅） | EF_OUT 1.95 | — |
| **VSYS R9→U3（5 V 降壓輸入）** | 約 3.5 A | **0.35 mm，窄段總長 49 mm，經過 6 個孔** | 1.52（但切斷了 SW 節點，撤回） | 通道要穿過 L1、U3 下方，和降壓的 SW / BOOT 迴路搶空間 |
| 5V_BUCK L1→Q3 | 約 3.85 A | 0.35 | 0.99（Q3 轉 90° 可到 1.72，但 Q3↔U4 必然交叉，撤回） | Q3 左側是 Pi 4 WiFi 禁佈區 |
| 5V_PI Q3→J2.2/J2.4 | 約 3.85 A | 0.35 | 0.87（僅 F 層；In2 另有並聯） | 排針第二排腳縫只有 0.84 mm |
| 3V3_BUCK L2→R22 | 約 1.2 A 突波 | 0.35 | 1.17 | C27.2 / C28.2 兩個 GND 焊盤之間的縫 |
- **5 V 降壓的 SW 節點**（U3.8→L1.1）只有 0.35 mm，為了繞開 C12 繞行約 7 mm；BOOT（C12→U3.7）和它交錯。這違反降壓佈局的基本原則（SW 迴路要短而寬），而且就在 HaLow 附近。
- **分壓電阻 R1–R4 直立排成一欄**：R1 的 VBAT 端正下方就是 R3 的 OVP 端，任何 VBAT_RAW 的接法都會和 U1 的控制線交叉。Freerouting 在這一區連續 3 次失敗，`b1f344a` 那次是剛好成功。
- C6（1210）在降壓附近找不到位置；courtyard 掃描過，這一帶沒有 3.2×4.6 mm 的空位。**這塊板的密度已經到頂**。
- 還是 §6 的老問題：C13（U3 的 VCC 旁路電容）離 VCC 腳約 6 mm。

### 7.3 為什麼要停：打地鼠
雲端的擺位是自動打包出來的，沒有考慮訊號流向；本機則是一區一區修，每修一區就在隔壁冒出新問題（VSYS → SW 節點 → Q3/U4 → 分壓電阻）。自己犯的錯：
- 鋪銅前沒先列出不能碰的走線（SW / BOOT），把開關節點拆斷了。
- 把 In2 的 EF_SHDN / 5V_PI 看成 VBAT_RAW，**沒有先用程式確認網路名稱**就下手。

### 7.4 下個 session 的正規流程（建議）
1. **先定驗收標準**，全部可以用 `bottleneck.py`、DRC、courtyard 檢查自動驗證：
   - 主電流路徑最窄處：≥1.5 mm（≥3 A），≥1.0 mm（3V3）
   - SW 迴路：≤3 mm、≥1.5 mm
   - C10、C12 貼近 U3
   - 0 未接、0 錯誤
2. **整板訊號流向規劃**：列出每一區的「關鍵走線」（電流路徑、SW 迴路、Kelvin、差動、RF），以及每顆 IC 每一排腳往哪個方向出線。先畫在紙上或圖上，**過獨立的對抗式 review**，通過才動板子。
3. **依規劃重擺**。只擺零件和鋪銅、不佈線，就量 courtyard 和鋪銅細頸（每次約 2 分鐘）；達標才佈線。擺不下就回到上游：換小封裝（例如 C6 的 1210）、部分零件放背面，或放寬規格。
4. 最後才交給 Freerouting，只處理細訊號，並且**要求連續兩次都 0 未接**，證明穩定。

### 7.5 本機環境與坑（補 §6）
- Freerouting 2.1.0：
  - 圖形介面模式跑完會跳「User Settings」對話框，擋住存檔（有一次卡了 1 小時 45 分）。
  - 無介面模式不理會 `-mp`，但會遵守環境變數 `FREEROUTING__ROUTER__MAX_PASSES` 和 `FREEROUTING__ROUTER__JOB_TIMEOUT`，跑完會自己存檔、退出（實測 245 秒）→ 已寫進 `run.sh`。
  - 它把 DSN 裡的鋪銅（plane）當成擋不住的區域，也不擅長「接到鋪銅」這種目標；要保護鋪銅就得加禁止走線區。
  - 設定檔在 WSL 的 `/tmp/freerouting/freerouting.json`。
- `pcbnew.LoadBoard` 要有同名的 `.kicad_pro` 在旁邊，netclass 間距才會對；把板子複製到 `/tmp` 會讓 router 行為改變。
- 在 WSL 裡找程序要用 PID；`pkill -f` 或 `grep` 加 `awk` 的模式比對經常抓錯，甚至把自己殺掉。
- 查 DRC 或未接的網路名稱時，**一律用程式讀 `GetNetname()`**，不要看渲染圖的顏色判斷。

## 8. 2026-09-28 ~ 09-29：擺件重做（layout v2）交接

**完整紀錄在 [`layout-v2/PLAN.md`](layout-v2/PLAN.md)**：§1 驗收標準、§2 分區、§6–§9 三輪對抗式審查與回應。本節只寫接手要知道的事。

### 8.1 決定（使用者）
- **砍掉重練擺件和佈線**；電路圖凍結，唯一例外是新增 **C34**（2.2 nF，EN_5V → GND，放 U3 EN 腳旁；check.py PASS）。
  - 退路：本地 tag `hat-v1-baseline-drc-clean` = `b1f344a`。
- **WiFi 禁佈區**只留天線條 `(0,0)–(6.3,20)`；不保留螢幕、攝影機排線的空間。
- **方案 A**：5 V 降壓放左上角（和規格 §5.5.2 不同，理由見 PLAN §0）；3.3 V 降壓放插座端。
- **卡片下方限高 1.9 mm**：卡片背面無零件（使用者照片）。這個數字**綁定 5.2H 插座的推算高度**，見 8.3。
- **疊層與製程**：外層 2 oz、內層 1 oz；照 JLC 2 oz 規則，線寬 / 線距 ≥ 0.15（設計用 0.2 / 0.21）、過孔 0.3 / 0.8。
  - **舊專案規則（0.127、過孔 0.6 / 0.3）不符合 2 oz。**
- **屏蔽框**：只留焊墊環，不裝框。
- **J2 排針手焊**：焊點周圍 ≥ 1 mm 不放 SMD；第 2 / 4 腳用寬輻條。

### 8.2 工具（都在 `layout-v2/`）
| 檔案 | 用途 | 怎麼跑 |
|---|---|---|
| `export_fp.py` | 從板檔匯出每顆零件的佔位框、焊墊、高度 → `fpdata.json`。design.py 有、板上沒有的零件（如 C34），會複製同封裝的零件補上 | WSL：`python3 export_fp.py` |
| `sketch.json` + `sketch.py` | **G0**：座標級擺件 + 驗收標準的距離規則；檢查正面與背面重疊、禁佈區、卡片下限高 → `sketch.png` | Windows 或 WSL：`python sketch.py` |
| `padinfo.py` | 印出零件在世界座標的焊墊範圍（規劃出線用） | `python padinfo.py U1 Q1` |
| `escape.json` + `escape.py` | **G0.5 / G2 預演**：用真實封裝建實驗板 → 計畫鋪銅 → 手畫的關鍵出線 → GND 過孔 → 確定性 A* 繞線（`closeout/router.py`）→ KiCad DRC → 最窄處量測（只侵蝕 + 焊墊入口豁免；含 In2 過孔到過孔） | WSL：`python3 -u escape.py > escape-full.log`（約 30 分鐘）；只量已存的板：`MEASURE_ONLY=1 python3 escape.py` |

**踩過的坑**：
- 相鄰的鋪銅矩形要**重疊**，只是邊對邊碰在一起，KiCad 不算相連。
- 量頸部不能用開運算，會高估（審查 r3 抓到），已改成只侵蝕。
- 「0 未接」要同時看有沒有**懸空過孔**，有一輪就是這樣被騙的。
- `FootprintLoad` 在 `LoadBoard` 之後會 segfault，改成複製板上同封裝的零件。
- `build.sh` 會覆寫 `.kicad_pro`，跑完要還原。

### 8.3 目前結果（2026-09-29）
- **電源與四個關鍵角落（U1 上 / 下排、U3、U7）**：每一輪都穩定通過。已繞網路 0 未接，GND 過孔全部有位置（最多 52 顆，每顆輸出電容 3 顆）。
- **主電流最窄處**：

| 路徑 | 最窄 |
|---|---|
| VBAT_RAW J1 → Q1 | 2.45 mm |
| VSYS R9 → C10 / C10 → U3 | 1.95 / 1.19 mm（與審查手量一致） |
| 5V_BUCK L1 → Q3 | 1.71 mm |
| 5V_PI Q3 → J2 | 0.96 mm（F）+ B 並聯 |
| 3V3_BUCK L2 → R22 | 1.30 mm（要保護通道，見 8.4） |

- **全板訊號預演**：65 條剩餘網路中，貪婪繞線器最多拉通 45 條。失敗集中在：
  - 排針往下的訊號，被擺件築成的牆擋住。
  - TPM 的 SPI 腳朝向插座那一側。
  - RTC 周邊。
- 最新一輪已照結構問題重排：R40–R48 改成 Tag-Connect 左邊的兩條直立列；Tag-Connect 右移；TPM 轉 90°；R64 放到 EVI 腳旁；TP2 / TP3 移到上方長條左側。**這一輪的結果寫在 `layout-v2/escape-full.log`**，交接時還在跑。
- **5V_PI 往 Z3 的饋線目前在 B 層**，In2 空給排針訊號；GND 過孔已確認避開。

### 8.4 還沒解、下一步
1. **讀 `escape-full.log`**：看 `FAIL`、`NO SPOT`、DRC 那一行、頸部表。貪婪繞線器大約只能到 45 / 65；**不要再逐條硬試**。結構問題修完就進 G1。
2. **G1**：寫 `place_v2.py`，把 `sketch.json` 的座標寫進正式板檔，順序照 PLAN §5。**G2**：電源用預畫的鋪銅，訊號交給 Freerouting，要求連續兩次 0 未接。
3. **卡片高度 / 固定柱：已定案（PLAN §11）**：WM1302 照片量得卡片底面約 3.15 mm；H5 / H6 用 Würth WA-SMSI M2，3.0 mm（9774030243R，另備 3.5 mm），Ø5.3 焊墊 + Ø3.0 NPTH。封裝和 design.py 已更新。以下是定案前的背景：：
   - 規格書沒標卡片底面高度，3.0–3.3 mm 是推論。
   - 專用 mPCIe 固定螺帽常見高度是 4.15（JAE NT4R1600）、4.6（Attend 119A-NUT-70）。
   - 候選：**Würth WA-SMSI M2**（9774030243R / 9774035243R，要 Ø5.3 焊墊 + Ø3.0 NPTH）、**JAE NT4R1600**（SMT、說是不用打孔，未驗證）。
   - 使用者要去看孔 / 量 WM1302（電路圖上的固定件料號是 SJH01-005、插座 ST-PC-007，都是 Seeed 內部編號）。
   - 另一個選項：改用 Attend 或 JAE 這類有配套螺帽資料的插座。
   - escape 目前**暫時**用 Würth 的 Ø3.5 全層禁佈區建模。
4. **製造前**：
   - 封裝散熱過孔焊環 0.15（U1 / U3 / H 共 41 處，影響 U3 散熱）
   - VSON（Q1 / Q3）與 TSOT-23-8（U9）的焊墊間距 0.14–0.15
   - GNSS 射頻線離 J4 GND 焊墊要 ≥ 0.3（射頻網路類別）
5. **G1 裡要做**：
   - U3 散熱實算（粗估：實際負載 Tj 約 75 °C；3.85 A 時約 128 °C，只當暫態）
   - In2 預算（排針第 1 / 3 腳沿兩排腳之間的縫走、Kelvin、3V3_PI、FLT、EN_5V）
   - 屏蔽框焊墊環
   - 保護 3V3_BUCK / VSYS 通道，不讓訊號線穿過
6. **軟體配合**：#223（#224 poweroff 斷電、#225 電源鍵、#226 HaLow 上電時序）與 #122 的留言。
7. **Git**：`hat-v1-local` 已有本地 commit `43f522f`（layout-v2 工具 + C34）；本節和之後的修改另外 commit。**都還沒 push 到 PR #222**，push 要使用者同意。

## 9. 2026-09-29 白天：固定柱換正式封裝、G2 預演（先讀這節）

- **固定柱**：escape 改用正式 Würth 封裝。`layout-v2/src_board.py` → `src-board.kicad_pcb`（主板不動，不進版控，重跑即可產生）；escape / export_fp 用 `SRC_BOARD=src-board.kicad_pcb`，會印出實際讀的板檔。
- **H6 周邊**：最小位移搜尋 + 對抗式審查（PASS WITH CHANGES）。
  - C6 / R9 x −0.3、U2 / R6 y +0.1、C34 x +2.0；EN_5V 手畫線跟著改。
  - J1 不動，J1 × H5 的 courtyard 用 `courtyard_exempt` 豁免（KiCad DRC 仍會報，G1 前要收 J1 courtyard）。
  - H5 / H6 周圍 r 3.05 禁過孔、NPTH 禁佈 r 1.8。
  - 細節見 PLAN §12.0。
- **完整 escape**：電源 31 / 31 繞通；VSYS 頸部 1.90 / 1.19；H5 / H6 的 r 3.05 內 0 顆過孔；其餘訊號 45 / 65。DRC 抓到 H5 / H6 實心焊墊蓋在 NPTH 上 → **封裝要改成環形**。
- **G2 預演（PLAN §13）**：Freerouting 只繞訊號（電源保留計畫的形狀），兩次都不通過（DRC 未接 102 / 95）。卡住的是非電源區、主要在卡片下；懷疑 5V_PI 的 B 層饋線帶縱貫全板把卡片下切開。**G1 暫緩。**
- **備案（PLAN §12，使用者擱置）**：板子往左延伸 3 mm、重擺電源區；審查建議 VSYS 走 V1B（§12.7）。
- **下一步**：5V_PI B 層帶的診斷實驗（只改這條，其他不動，比 Freerouting 未接數）→ 依結果改擺件 / 饋線 → 再預演兩次 0 未接 → G1。
