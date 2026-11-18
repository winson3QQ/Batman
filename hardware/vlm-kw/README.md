# VLM-KW USB 語音 / PTT 介面板（VLMKW0100）

Batman 節點 `ptt` 能力用的外接周邊（見 `docs/design/219-field-provisioning.md`：「CM108 / OpenVLM USB 音訊裝置」）。
它是**獨立的一塊板**，透過 USB 接到主機，**不是** Batman HAT 的一部分，和 `hardware/hat-v1/` 沒有共用電路或零件。

- 主晶片：C-Media CM108B（USB 音訊 + HID + GPIO，LQFP-48）
- 介面：USB-C（主機端）、3.5 mm + 2.5 mm Kenwood 2-pin PTT 插孔、JST SH 擴充座
- PCB：53 × 26.5 mm，2 層，板厚 1.6 mm（外殼依 1.6 mm 板 dry-fit，不可改板厚）

## 檔案

| 檔案 | 內容 |
|---|---|
| `VLMKW0100_GERBER.zip` | Gerber、鑽孔、ODB++、上游貼片檔（Eagle / Fusion CAM 輸出） |
| `VLMKW0100_BOM_original.xls` | 上游原始 BOM（designator / footprint / value；內含的 JLCPCB C 料號不使用） |
| `VLMKW0100_BOM_sourcing_compliance.csv` | 非中國料源對照：每行的廠牌、MPN、通路與信心等級 |
| `VLMKW0100_CPL_placement.csv` | 貼片座標（單位 mm，全部在 Top；SW1/SW2 本批不裝） |
| `enclosure/vlm-pt1-enclosure.stl` | 3D 列印外殼，一個 STL 含上下兩殼半，列印前要先分割 |
| `enclosure/parts.txt` | 外殼五金：5 × M3×3 mm 熱熔螺母、5 × M3×6 mm 平頭螺絲 |
| `enclosure/UPSTREAM-README.md` | 外殼上游 README 原文（文中引用的 `pics/` 照片未一併收錄） |

### BOM 注意事項

- `sourcing_compliance.csv` 的 `Confidence` 欄：`LOW` / `MED` 的料下單前要再核對，特別是 J7（USB-C，footprint 是從 BOM 推的，要對 Fusion 檔）與 U2（93C46 的電壓變體和 ORG 腳）。
- `SPEC` 行（被動元件）只定規格，由通路依規格配料。
- 標成 `OPTION` 的 SW1 / SW2（音量鍵）本批不裝。

## 來源與授權

這個資料夾裡的檔案都是**第三方設計**，各自沿用上游的授權，**不適用本 repo 根目錄的 MIT 授權**。

| 範圍 | 上游 | 授權 |
|---|---|---|
| 電路板（Gerber、BOM、CPL） | [OpenMANET/OpenVLM](https://github.com/OpenMANET/OpenVLM) | CERN-OHL-W-2.0 |
| 外殼（`enclosure/`） | [OpenMANET/enclosures](https://github.com/OpenMANET/enclosures) — Sunkworks VLM PT1 Enclosure | CC BY-NC 4.0 |

- `VLMKW0100_BOM_sourcing_compliance.csv` 的料源對照是本專案整理的，其餘檔案沒有修改。
- 外殼為 **CC BY-NC 4.0（非商業）**：自用列印或委外代印自用可以，**不得販售**列印成品或以外殼檔營利。
- 再散布電路板檔案時，要依 CERN-OHL-W-2.0 保留來源與授權聲明。
