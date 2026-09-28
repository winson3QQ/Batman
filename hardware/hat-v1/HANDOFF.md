# HAT v1 交接說明（雲端 session → 本機）

最後更新：2026-09-28。本文件說明目前進度、怎麼在本機重現每一步、以及還沒完成的事。
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
| 佈線 | **未完成**：repo 內最新完整版本剩約 8–10 個未接（見 §4）；其餘電氣 DRC 錯誤為 0 |
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

## 5. 最新佈線狀態

（由 session 在收尾時填入）
