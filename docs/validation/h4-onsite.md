# H4 現場步驟(H4-U7)

`docs/design/254-h4-harness.md` 的一次現場:依序做完、收到證據,才開 H4 的 harness PR。
每一步的細節以設計文件為準;這份只列順序、誰做、檢查點與「不成立時怎麼辦」。存取細節(IP、帳號)在私有運維 repo。

## 0. 出發前(遠端,現場前一天)
- 主機:`harness/254-h4` 最新、WSL venv 與 Windows bleak 照 hash 釘選(`requirements*.txt`)。
- 04:A committed、P9 乾淨(`undo=0`、無 dirty 旗標、無 harness bind)。E-H12 / E-H15 / test-h4-undo / E-H13 前置都已 ✅(設計 §17)。
- 手機:A 段已完成(`docs/validation/s20-setup.md`),從 WSL 用專用鑰匙登入成功、無鑰匙登入被拒。
- 準備:兩張 wsl.22 燒卡用的卡、02 用的網路線、手機充電器。

## 1. 重燒 02 / 04(使用者)
- 依現有燒卡流程燒 wsl.22。**檢查點**:兩台都開機、主機在實驗室網段找得到(依 eth MAC)。
- **不成立**:停在這一步,回報;不往下做。

## 2. 02 暫時接網路線(使用者)
- 02 接到實驗室交換器。兩條路同時存在時由 batman 的 BLA 避免迴圈(設計 F-H52)。
- **檢查點**:主機能直接 ssh 到 02。

## 3. 建 S0-pre(使用者用 app,harness 檢查)
- 認領與加入網路用正式 app 手動做:`docs/validation/h4-manual-cases.md` 的 **M1、M2**(2026-11-03 使用者決定;
  自動化版本被工具的安全機制擋下)。
- **檢查點**:`s0_assert`(S0-pre 版)兩台都成立。
- **最後**:使用者拔掉 02 的網路線,再跑一次 `s0_assert`(含「02 的 eth0 沒有載波」)。
- **不成立**:INVALID,harness 印出重建步驟;依指示重做,不要手動改節點。

## 4. 手機設定(使用者,B 段)
- `docs/validation/s20-setup.md` 的 B 段。
- C0 由使用者在手機上手動輸入,步驟與檢查見 `docs/validation/h4-manual-cases.md` 的 **M4**。
- **檢查點**:M4 的 a–d 都通過。

## 5. §7 探針在 04(harness,lease 底下)
- 設計 §7 的 7 步:基準 → listener → 載入規則 → 正向 → 負向 → 鑑別力 → undo。
- **檢查點**:每一步附原始輸出;第 7 步回到基準(`nft -s` 與 `netstat` 相同)。
- **不成立**:改用備案規則加短審查,由使用者決定(設計 §7)。

## 6. E-H13 本體(harness,04)
- 設計 §8.1:apply 壞 rootfs → 重開 → 觀察 panic 行、ext4 嘗試、回到 A 的時間。
- **收尾一定要做**:brewrite B,斷言 B = V、沒有 `BATMAN-BAD`,再 `s0_assert`。否則之後任何 rollback 都會讓 04 陷入 panic 迴圈。

## 7. 收工
- 兩台 `s0_assert`;04 / 02 的 P9 乾淨;手機留在實驗室、接著充電。
- 結果回填設計 §17 與 #254;齊了才開 harness PR。
