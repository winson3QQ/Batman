# Batman HAT v1：電路圖（M2）

設計規格見 [`docs/design/hat-v1-spec.md`](../../docs/design/hat-v1-spec.md)。本資料夾是依規格產生的 **KiCad 7 電路圖**，狀態：**草稿，尚未送板廠**。

## 看圖

- **PDF**：[`out/batman-hat-schematic.pdf`](out/batman-hat-schematic.pdf)，共 10 頁：總覽 1 頁，加上 9 個功能區塊各 1 頁。
- **自動檢查報告**：[`out/check-report.md`](out/check-report.md)
- **材料清單草稿**：[`out/bom-draft.csv`](out/bom-draft.csv)。LCSC 料號在 M3 階段補齊。
- **用 KiCad 開**：開 `batman-hat.kicad_pro`。

### 這份電路圖怎麼讀

- 採用「**標籤式**」畫法：元件之間不拉長線，每支腳旁邊標一個**網路名稱**，**名稱相同就代表接在一起**。
  - 方框形的標籤是跨頁共用的網路。
  - 純文字的標籤只在該頁內使用。
- 腳上打 **×** 的，是刻意不接。
- 被紅色 **×** 劃掉的元件是**預留不焊**（DNP），用來日後微調。
- 每頁左下角的 **NOTES** 寫了每個元件為什麼這樣接、數值怎麼來的。

| 頁 | 檔案 | 內容 |
|---|---|---|
| 2 | `power_in` | 電池焊墊、突波保護、eFuse 與反接保護、整台電流量測（INA226 #1）、電池偵測 |
| 3 | `power_5v` | 5 V 降壓（給 Pi）、理想二極體（防止 Pi 的 USB-C 倒灌）、綠燈 |
| 4 | `power_3v3` | 電源二選一（電池 / Pi 5 V）、3.3 V 降壓（給 HaLow）、HaLow 電流量測（INA226 #2）、濾波 |
| 5 | `softpower` | LTC2955 軟開關機、AUTO-ON 跳線、電源鍵 |
| 6 | `pi_header` | 40-pin 排母、HAT ID EEPROM（預設寫入保護）、固定孔 |
| 7 | `halow` | mPCIe 插座（Wio-WM6108）、大電容 |
| 8 | `security` | TPM 2.0 SLB9672、ATECC608C、RTC RV-3028 與超級電容 |
| 9 | `gnss` | MAX-M10S 定位模組、主動式天線供電、U.FL |
| 10 | `debug` | Tag-Connect 除錯焊墊、所有測試點（值欄寫了正常讀值）、電源旗標 |

## 怎麼產生（不要直接改 `.kicad_sch`）

**唯一的資料來源是 `gen/design.py`**：所有元件、數值、接線都寫在這裡。改完後執行：

```sh
./build.sh      # 需要 KiCad 7（kicad-cli）與 python3
```

依序產生：

1. 電路圖
2. 檢查報告
3. 材料清單
4. PDF

檢查沒過就停下來，並印出錯誤。

| 檔案 | 作用 |
|---|---|
| `gen/design.py` | 設計資料：元件、數值、接線，以及檢查程式要用的規格事實（GPIO 表、電壓上限） |
| `gen/symbols.py` | 元件符號與接腳對照 |
| `gen/gen_sch.py` | 產生 KiCad 7 電路圖 |
| `gen/check.py` | 檢查（見下） |
| `gen/bom.py` | 材料清單草稿 |

## 自動檢查做了什麼

`gen/check.py` 會做以下檢查：

1. **接線比對**：請 KiCad 自己匯出接線表（netlist），和 `design.py` **逐腳比對**，目前 557 支腳全部一致。產生程式若有錯，例如標籤沒對到腳、兩個網路被接在一起，這一步會抓到。
2. **GPIO 表**：Pi 排針的 28 支 GPIO 和規格 §4.2 逐一比對。
3. **I2C 位址**不重複：0x36 / 0x40 / 0x41 / 0x52。
4. **TPM 與 SPI1 網路上沒有任何測試點**（規格 §5.1 的資安要求）。
5. **電壓上限**：
   - 對有耐壓限制的接腳（例如 TPS62933F 的 EN 最高 6 V、LTC2955 的 KILL 最高 6 V），用該網路最壞情況的電壓比對規格書的絕對最大值。
   - 接到 Pi GPIO 的網路都不可超過 3.3 V。
6. **只接到一支腳的網路**：這類網路列為錯誤，除非在 `SINGLE_PIN_OK` 寫明理由（例如只接測試點的除錯腳）。
7. **設定點**：從電阻值反算以下各項，和規格比對：
   - eFuse 的欠壓 / 過壓 / 限流門檻
   - 5 V 與 3.3 V 的輸出電壓
   - 5 V 降壓的硬體欠壓門檻
   - AUTO-ON 門檻

KiCad 7 的命令列沒有 ERC（電氣規則檢查），上面這些自寫檢查就是替代。用 KiCad 圖形介面開啟時，仍可手動執行 ERC 做第二道檢查。

## 已知待辦（送板廠前必須完成）

| 項目 | 狀態 |
|---|---|
| `batman:` 開頭的自製封裝：TI 功率 FET、SLB9672、RV-3028、CPH3225A、mPCIe 5.2H 插座、電池焊墊、卡片固定柱 | M4（畫電路板時）依規格書建立 |
| LCSC 料號、JLC 基礎料 / 擴展料、庫存 | M3 |
| 電感、磁珠的實際型號與規格（Isat、DCR） | M3 查證 |
| MAX-M10S 的 VIO_SEL、V_BCKP 接法 | 需要 MAX-M10S 規格書（UBX-20035208）確認 |
| RV-3028 的 EVI 閒置處理 | 需要 RV-3028 Application Manual 確認（目前先接 100 kΩ 到地） |
| 卡片固定柱高度 | 第一批板子量測（規格 V14） |
