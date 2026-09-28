# HAT v1 佈線收尾（本機接手，2026-09-28）

雲端交接時板上還有 10 個未接（`HANDOFF.md` §5）。這個資料夾把收尾的每一步寫成可重播的腳本：
從雲端交接那一版（commit `8041361`）開始，用 `run.sh` 重播。

⚠️ **Freerouting 的結果不固定**：同一份輸入，一次跑到 0 未接，下一次剩 2 個。commit 的板子是 0 未接的那一次，已用 `pcbnew.WriteDRCReport` 驗證。重跑時 `run.sh` 最後會檢查未接數，不是 0 就失敗，要重跑。

## 做了什麼

| 項目 | 做法 |
|---|---|
| SPI1_SCLK（U11.19） | TPM_CS_N 的孔挪約 0.3 mm；C16.2 的 GND 孔移位，讓出換層位置；SCLK 走 F→B |
| GND 孤島 ×2 | C16.2 補孔；J5.3（Tag-Connect）被 TC_* 走線圍住，在 J5.2、J5.3 之間放一個 0.5/0.25 mm 的蓋油孔 |
| VCC_5V / 5V_BUCK / PG_5V | 補短斷點 |
| HALOW_RESET_N | 兩端都是死路殘段：整條拆掉，從 J2.11 重拉到 J3.22 |
| **輸入級重擺**（VBAT_RAW ×2、VBAT_DAMP、EF_DRV） | 這不是補線能解的擺位問題，見下節 |
| 其餘連線 | Freerouting 增量佈線（保留既有銅箔） |
| 收尾 | U1 散熱孔與 J2.25 改實心連接（解 `starved_thermal`）；刪除懸空殘段，但只刪 KiCad 連通性判定不會斷線的 |

### 輸入級為什麼要重擺
- Q1（反接 B-FET）的 source 腳 1–3 走整顆電池的電流（2S 低電量約 3.5 A，最壞 3.8 A）。原本這幾腳面朝板邊，下方又被 gate 擋住，只放得下一個 0.3 mm 的孔。
- U1 的腳 3–5（BGATE、DRV、IN_SYS）要擠進 0.77 mm 寬的板邊窄條，放不下。

改法：
- **U1 轉 90°**：空腳 19–24 面向板邊；IN 腳朝下對 Q1，OUT 腳朝上對 R9。
- **Q1 轉 90°**：source 朝下對 D1 和電池。
- 主電流改走 F 層鋪銅：J1→D1→Q1、Q1→U1 IN、U1 OUT→R9。
- VBAT_RAW 的次要分配改走 In2 鋪銅。鋪銅範圍另設 In2 禁止走線區，避免佈線器把它切斷。
- U1 底排、頂排腳的出線順序是固定的拓撲，用手拉通道處理。
- R19/C33/C8 阻尼網路改成直疊，兩顆電容的 VBAT_DAMP 焊盤面對面相連。

## 檔案

| 檔案 | 用途 |
|---|---|
| `run.sh` | 整條流程 |
| `closeout.py` | 手動修正與輸入級重擺（從基準板重播） |
| `export.py` / `finish.py` | 呼叫 `gen/layout.py` 的 `prepare_reroute()` / `finish()` |
| `post.py` | 收尾清理並產生 DRC 報告 |
| `bottleneck.py` | 主電流路徑上最窄的線（最寬路徑分析） |
| `rt.py` / `router.py` / `ops.py` | 幾何、網格 A* 補線器、板上編輯工具 |

## 本機環境與坑（KiCad 7.0.11 在 WSL Ubuntu 24.04）
- KiCad 7 的 `kicad-cli` **沒有 `pcb drc`**：DRC 一律用 `pcbnew.WriteDRCReport`。
- **`build.sh`（gen_sch.py）會重寫 `batman-hat.kicad_pro`，把 PCB 的 netclass 和規則洗掉**：之後跑 DRC 會多出幾百個假錯誤。跑 DRC 前要先把 `.kicad_pro` 還原（`git checkout`）。尚未修正。
- Freerouting 2.1.0：`run.sh` 用無介面模式，靠環境變數 `FREEROUTING__ROUTER__MAX_PASSES` 和 `FREEROUTING__ROUTER__JOB_TIMEOUT` 控制，跑完會自己存檔、退出。圖形介面模式跑完會跳「User Settings」對話框擋住存檔，無介面模式則不理會 `-mp`。`-da` 加上環境變數可以關掉資料回傳。細節見 `HANDOFF.md` §7.5。
- pcbnew SWIG：迴圈裡刪除物件要用 `board.Delete()`，用 `Remove()` 會把 board 物件弄壞。
- DSN 裡的鋪銅會匯出成 `plane`，但**擋不住別的網路穿過去**；要保護鋪銅，得另加禁止走線區。

## 還沒做（見 `HANDOFF.md` §7；電源鋪銅的實驗在 `experiments/power-pours.patch`，尚未通過 0 未接）
- **主電流路徑的電源分配**：VSYS→U3、5V_BUCK、5V_PI→J2、3V3 等路徑最窄只有 0.35 mm（PWR netclass 的預設值）。雲端版就已經如此。用 `bottleneck.py` 可以量。
- C13（U3 的 VCC 旁路電容）離 VCC 腳約 6 mm。
- H1 禁佈區警告：等 Pi 4 機構圖。
- 6 段橋接型懸空線（warning）：電氣上已連通，端點尚未對齊。
