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
- `batman-slot`、`platform-ab.sh`、`95-batman-storage`、`batman-autocommit`、`meshjoin.sh`、`98-batman-sysupgrade`、`feed/batman-payload-host/`、`scripts/build-ab-payload.sh`、`scripts/build-gpt-ab-card.sh` 是**兩塊板共用**的。改了就要兩塊板都實機驗證。PR body 必須有 `### bcm2711` 和 `### bcm2710` 兩個實測段落,CI 的 `ab-shared-change` 會檢查。
- Pi 3 沒有 EEPROM:firmware 缺檔或 `autoboot.txt` 壞掉都會卡死。p7 只能經由 `batman-slot` 寫入。
- 新功能的回歸測試加進 `scripts/daily-validation.sh`;因 SoC 本來就不適用的 suite 用 `na`,不要用 SKIP。

## 流程
- 動手前先給計畫;設計要先過對抗式 review;PR 附實測結果(哪台、做什麼、原始輸出;沒測到的要寫出來);PR 由使用者 merge。
- 回覆使用繁體中文。
