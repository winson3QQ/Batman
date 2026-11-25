# Batman repo — 給每個 session 的規則

**動到 build、A/B 程式(OTA、slot、autocommit、storage)、或要上 Pi 3A+ / Pi 4 驗證之前:先讀 `docs/boards-and-builds.md`。** 那是正本,這裡只列規則。

## 板子與角色
- 兩塊板:`ekh-bcm2711`(Pi 4:manet02、manet04)、`ekh-bcm2710`(Pi 3A+:manet03)。OTS 只出在 Pi 4。
- **模擬已部署角色的節點只能用 `sysupgrade` 更新,不能重燒卡**;破壞性測試先問使用者。角色會輪替,先查 `docs/boards-and-builds.md` §1 的現況。
- v1.1 開發期間,每塊板的燒卡 image 都要在 bench 角色的機台上實燒驗證。

## build
- 只用 firmware fork(`winson3QQ/firmware`,分支 `build-3aplus`)的 `scripts/build-board.sh <board>`。不要自己拼配方,不要裸跑 `make defconfig`(會掉 brcmfmac → OTA 後節點 stranded)。
- 兩塊板從同一個 commit build,版本號相同;`/etc/batman-build` 由 build 產生,不要手改。版本規則見 `docs/VERSIONS.md`。
- release 只發實機驗過的那一批(以 sha256 為準)。

## 改共用 A/B 程式
- 以下是**兩塊板共用**的 A/B 檔案,完整清單見 `docs/boards-and-builds.md` §6(和 CI 的 `paths` 是同一份):
  - `batman-slot`
  - `platform-ab.sh`
  - `95` / `96` / `98` 的 uci-defaults
  - `batman-autocommit`(含 init 腳本)
  - `meshjoin.sh`、`joinwatch`、`batman-config-save`
  - Pi 3 firmware 白名單
  - `deploy/provisioning` 裡的複本
  - `feed/batman-payload-host/`
  - 建卡與打包腳本
- 改到上面任何一個,兩塊板都要實機驗證。PR body 必須有 `### bcm2711` 和 `### bcm2710` 兩個實測段落;CI 的 `ab-shared-change` 只檢查有沒有交代,內容要由人讀。
- Pi 3 沒有 EEPROM:firmware 缺檔或 `autoboot.txt` 壞掉都會卡死。p7 只能經由 `batman-slot` 寫入。
- 新功能的回歸測試加進 `scripts/daily-validation.sh`;因 SoC 本來就不適用的 suite 用 `na`,不要用 SKIP。

## 驗證(#290,使用者 2026-10-14 / 10-15)
- **驗證的東西只有一套,只在 main**:`scripts/daily-validation.sh`、`scripts/dv/*`、節點端測試工具、CI lint(`check-*.sh`、`test-*.sh`)及其資料(allowlist、`rundir-paths.txt`、known-failures)只能經由**先進 main 的 harness PR** 修改。產品 PR 不碰它們;唯一例外是刪掉產品 PR 自己移除的檔案在 allowlist / 路徑表裡的條目,兩邊 PR body 都要寫明。
- **新增或修改的測項要先證明自己**:PR 附「舊版 FAIL(負對照)」與「新版 PASS」兩個結果。
- **小修正**用它自己的回歸測項(含負對照)加 OTA / A-B 基本測項驗證,PR body 寫明跑了哪些、為什麼夠;**全套**每次出貨跑一次(幾個 issue 合併 → pin-bump build → OTA → 從 main 跑全套)。出貨判定只認從 main(或即將成為 main 的 harness PR head)跑的結果,報告要寫 harness commit。
- `scripts/dv-preflight.sh` 不過就不跑;`DV_PREFLIGHT=off` 只給 harness 自測,不能當結果。
- `scripts/validation-known-failures.txt` 每條要有 issue 與到期日;延期要寫理由,移除要附該測項在新版 PASS。

## 流程
- 動手前先給計畫,計畫裡標出**審查等級** L0–L3。**下面只是摘要,不完整**;判斷等級前一定要讀 `docs/design/REVIEW.md` § Review level 的完整定義和 L3 觸發清單。作者或 reviewer 發現碰到更多時往上升(已有程式就以新等級重審);只有使用者能往下降:
  - L0 文件(不是程式、也不是定規則的檔案):不用設計、不用審查。定規則的檔案只做同步(改名、milestone、連結)是 L1:PR 附上依據的決定,diff 不增減或放寬任何規則,由 `/code-review medium` 確認。
  - L1 介面(**看 diff,不看資料夾**:只改畫面上看到的文字、版面、樣式;或程式檔裡只改註解,lint/analyzer 指令除外。改到任何對 `src/`、Rust bridge、store、link、flow 的呼叫或其結果處理,就不是 L1;`app/lib/ui/` 裡多數檔案都有這種呼叫):issue 內幾行計畫 + `/code-review medium`。
  - L2 一般(含新增或收緊驗證測項、修改定規則文件的規則、L3 審查留下的 MINOR 後續修正(只有設計審查降為一位;diff 碰到 L3 觸發條件時,`/security-review` 和 L3 的實測要求照舊)):設計文件 + 一位 reviewer(第 2 輪後還有 BLOCKER/MAJOR 就**停下來問使用者**,通常是升 L3)+ `/code-review high`。
  - L3 關鍵(例如:金鑰/憑證/608B/OTP/LUKS、供裝/認領/成員/權限、開機鏈/A-B/OTA/autocommit/LKG、mesh/網路/防火牆/BLE 協定、網路或 BLE 可達的新輸入(CGI、port、訊息)、root 服務與 payload/guardian、p5/p6 與 overlay 的持久狀態、kernel patch 與 overlay、效能(附前後量測)、相依套件、build 與建卡腳本、firmware 白名單、共用 A/B 檔、CI、放寬驗證閘門):設計必寫擁有權/介面契約/生命週期矩陣/依賴證據/安全(威脅模型),兩位獨立 reviewer 審整份直到沒有 BLOCKER/MAJOR(第 5 輪還有 BLOCKER/MAJOR 就停下來問使用者),開 PR 前 `/code-review high` + `/security-review`。
  - 硬體設計用 `docs/design/REVIEW-hw.md`。
- PR 的 Review 段寫等級、設計審查、code review、security review 各一行;PR 附實測結果(哪台、做什麼、原始輸出;沒測到的要寫出來);PR 由使用者 merge。
- 回覆使用繁體中文。
