# Design: A/B on Pi 3 (bcm2710) —— 以 chainloader 補回 firmware 缺少的試開/回退 (#209)

Status: **DRAFT(待對抗式 review)**
Parent: #209 · 父單 #203 / #89 · 姊妹 #133(Pi 4 A/B)
範圍決策:**使用者 2026-09-30 拍板「full A/B」** —— 見 §3
SoT: #75

## 0. 一句話

Pi 3 的 firmware 只給得出「切換」,給不出「一次性試開」與「壞槽自動回退」;本設計把這兩個原語**下移到我們自己引入的第二階段開機器(U-Boot)**,讓 `batman-slot` 既有的動詞契約在 bcm2710 上原封不動成立。

## 1. 問題:三個動詞,Pi 3 只有一個

Pi 4 的 A/B(#133 已上機驗證)建立在 EEPROM bootloader 上。Pi 3 家族**沒有 EEPROM bootloader**(SoC ROM → SD 上的 `bootcode.bin` → `start.elf`),整套機制不存在。

| 動詞 | Pi 4 | Pi 3 | 實測依據 |
|---|---|---|---|
| **切換**(指定下次開哪槽) | `autoboot.txt` 的 `boot_partition` | ✅ `os_prefix=B/` | #209 D1,3A+ 實機雙向驗過 |
| **一次性試開**(旗標自清) | `[tryboot]` + `vcmailbox` 觸發 | ❌ 無對應物 | `os_prefix` 是持久設定,無 one-shot 語意 |
| **壞槽自動回退** | firmware fallback | ❌ **完全沒有,且失敗是靜默的** | #209 D7:藏起 `B/kernel8.img` → L2 層零反應、無重試無降級,拔卡才救回 |

**推論**:能改 `config.txt` 把 `os_prefix` 寫回 A 的,是**正在運行的系統**;而需要回退的情境正是**新槽根本沒起來**。這個循環依賴無法用主機端軟體解開 —— 必須有一個「在 kernel 之前執行、且能自己數次數」的元件。

## 2. 我們已有的基礎建設:抽象邊界切得對,只缺一個後端

讀 code 確認(非推論):

| 層 | 檔案 | 與 SoC 的耦合 |
|---|---|---|
| 健康 gate + 自動 commit | `feed/batman-provision/files/usr/bin/batman-autocommit` | ✅ **已 SoC-agnostic** —— 只透過 `batman-slot is-trial / active / commit` 講話,不碰 `autoboot.txt` |
| 卡版面(GPT 六分割) | `scripts/build-gpt-ab-card.sh` | 🟡 版面無關 SoC;只有 `autoboot.txt` 產生 + `fw_boot_partition()` 要換 |
| payload 打包 | `scripts/build-ab-payload.sh:24` | 🟡 檔案清單寫死 `start4*.elf` / `fixup4*.dat`(`kernel8.img` 兩板共用) |
| sysupgrade 接縫 | `feed/.../usr/lib/batman/platform-ab.sh` | 🟡 結構無關 SoC;`RAMFS_COPY_BIN` 含 `vcmailbox`、board check 特判 `*bcm2711*`(檔案自留 `TODO tighten per-SoC`) |
| **槽機制核心** | `feed/.../usr/sbin/batman-slot` | 🔴 Pi 4 耦合**集中在此**:`fw_part` / `count_fats` / `assert_fw_sane` / `write_autoboot` / `committed_fw` / `is_trial` 六個函式 + `cmd_apply` 的檔案清單 + `vcmailbox` 觸發 |
| 驗證 | `scripts/ab-selftest.sh` · `tests/ab-card-invariants.sh` · `scripts/daily-validation.sh` | 🔴 **無任何 board guard**(= #217 的 R5),整份是 Pi 4 能力集 |

**結論**:#209 D5「加 SoC 分支,不 fork」是做得到的 —— 上層(dwell、健康判準、revert 語意、#211/#212 的 auto-commit)一行都不用改。缺的是 `batman-slot` 的一個 Pi 3 後端,而該後端需要的原語 firmware 不提供。

## 3. 範圍決策(使用者拍板):full A/B,不是 rootfs-only

曾提出兩案:

- **(a) rootfs-only A/B** —— A/B 下移到 initramfs 層,kernel 永遠單一份、永遠在無前綴位置,由 initramfs 依計數器決定掛哪個 rootfs。繞開 D7 的磚化路徑(開機成敗不再取決於新槽 kernel 有沒有寫完),但**kernel 更新失去 A/B 保護**:新 kernel 開不起來就是死板。
- **(b) full A/B** —— kernel + rootfs 都成對切換、都受試開/回退保護。

**裁決:(b)。** 理由(使用者):Pi 3 是民用 tier 的量產板,kernel 更新不該是「需人到場」的事件。

> ⚠️ 本節記錄的是決策,不是本文件自行選擇的結果。若 review 認為 (b) 的代價(§7)不可接受,應回頭挑戰這個範圍決策,而不是偷偷縮成 (a)。

## 4. 方案評估

| 方向 | 裁決 | 理由 |
|---|---|---|
| 1. 接受無自動回退(只靠 `rootwait=20 panic=10` 讓失敗可觀測) | ❌ 否決 | D7 之後不可接受:壞槽 = 靜默死板,而 mesh 是唯一 backhaul(#142)→ 現場當場少一台且無法遠端診斷 |
| 2. **Chainloader(U-Boot)** | ✅ **採用** | 唯一能同時提供「試開」+「自動回退」+「保護 kernel」的方向,符合 §3 的 (b)。`docs/field-resilience.md` 已列 bootchooser 為 #89 領先候選 |
| 3. initramfs 層 A/B | ❌ 否決(範圍不符) | 只保護 rootfs = (a);且 `CONFIG_BLK_DEV_INITRD` **兩個 subtarget 都關**,仍要重編 kernel,省不到成本 |
| 4. commit-forward | ⚠️ **併用,非獨立方案** | 防得了「default 指向未驗證的槽」,救不了「新槽開不起來」。納入 §5 的 commit 政策 |
| barebox bootchooser | ❌ 不可行(現況) | 樹裡**完全沒有** barebox 套件;U-Boot 至少有 `include/u-boot.mk` 的打包形狀可循 |

## 5. 設計

### 5.1 開機鏈

```
SoC ROM → bootcode.bin → start.elf  ──載入──▶  kernel8.img (= U-Boot!)
                                                    │
                          讀 uboot.env 的 bootcount / bootlimit / 槽指標
                                                    │
                        ┌───────────────────────────┴───────────────────┐
                        ▼                                               ▼
              bootcmd:載入試開槽的                          altbootcmd:載入已知良好槽
              Image + dtb + cmdline                         (bootcount 超過 bootlimit 時)
```

關鍵手法:**把 U-Boot 本身冒充成 `kernel8.img`** —— RPi firmware 只負責把「`kernel8.img`」載入並跳進去,它不在意那是 Linux 還是 U-Boot。真正的 Linux kernel 改名(如 `A/Image`、`B/Image`)由 U-Boot 載入。**firmware 層完全不需要 `os_prefix`**,D1/D7 的限制因此變得無關。

### 5.2 槽指標與計數器存放

- U-Boot env 放在 **bootA(p1)FAT 上的 `uboot.env`**(`CONFIG_ENV_IS_IN_FAT`)。
- 沿用 #133 既有的 GPT 六分割版面,**不改版面**(D4 的答案:沿用)。
- 主機端用 `uboot-envtools`(`fw_printenv` / `fw_setenv`)讀寫同一份 env —— 這就是 `batman-slot` Pi 3 後端的實作媒介。
- ⚠️ 單一份 env = 單點。必須用與 `write_autoboot()` 相同的原子策略(同目錄 staging → sync → rename → sync)+ 保留 `uboot.env.good` 錨點(對應 Pi 4 的 `ab.good`)。

### 5.3 `batman-slot` 的 Pi 3 後端:動詞對映

| 動詞 | Pi 4(現況) | Pi 3(本設計) |
|---|---|---|
| `apply <payload>` | 寫非現用槽 + 驗 `[tryboot]` 已對準 + `vcmailbox` 觸發 | 寫非現用槽 + `fw_setenv try_slot=<T> bootcount=0` |
| `is-trial` | 解析 `autoboot.txt` 的 `[all]` | 讀 env:`try_slot` 非空且 ≠ `good_slot` → trial |
| `commit` | 原子改寫 `[all]` = 現用槽 | `fw_setenv good_slot=<A> try_slot=` 清空 + `bootcount=0` + 更新 `uboot.env.good` |
| `rollback` | 原子改寫 `[all]` = 另一槽 | `fw_setenv try_slot=` 清除 → 下次開機回 `good_slot` |
| `active` | 解析 `/proc/cmdline` 的 `batman_slot=` | **不變** —— U-Boot 把 `batman_slot=<S>` 放進它傳給 kernel 的 cmdline |

**`batman-autocommit` 因此完全不用改。** dwell 3×10s、核心服務 + guardian drift 判準、#216 的分層健康模型(只 gate OS/infra)全部原封不動繼承。

### 5.4 自動回退機制

U-Boot 既有的 `CONFIG_BOOTCOUNT_LIMIT`:每次開機 `bootcount++`;超過 `bootlimit` 則執行 `altbootcmd` 而非 `bootcmd`。健康的系統開起來後由 `batman-autocommit` 清零(commit)或明確 rollback。

- `bootlimit` 建議 **3**(容忍兩次偶發失敗;與 #132 morse SPI 偶發 init 失敗的重開次數量級一致)。
- **`bootcount` 清零的責任必須落在「已證明健康」之後,不是開機即清** —— 否則一台「能開機但服務全死」的節點會永遠燒掉回退額度。這與 #216 分層健康模型一致:OS/infra 健康才算數。

### 5.5 payload 內容物(D6)

`build-ab-payload.sh` 的檔案清單改成 per-SoC:

| | bcm2711 | bcm2710 |
|---|---|---|
| firmware blob | `start4*.elf` / `fixup4*.dat` | `start.elf` / `fixup.dat` |
| Linux kernel | `kernel8.img` | `Image`(改名,避免與 U-Boot 的 `kernel8.img` 撞名) |
| chainloader | 無 | `kernel8.img`(= U-Boot) |

⚠️ **U-Boot 自身要不要進 payload、能不能 A/B?** 見 §8 開放問題 O1 —— 這是本設計最大的殘留風險。

## 6. 失效矩陣(照 #133 規格;**全部待實測**)

| 情境 | 期望行為 | 已驗證? |
|---|---|---|
| 新槽 kernel 缺失/損毀 | `bootcount` 累到 `bootlimit` → `altbootcmd` 回良好槽 | 🔴 未 |
| 新槽能開機但服務全死 | `batman-autocommit` 不 commit;重開後仍是 trial;第 N 次觸發回退 | 🔴 未 |
| 寫 payload 途中斷電 | 非現用槽半殘,但 `try_slot` 尚未設 → 下次開機仍走 `good_slot` | 🔴 未 |
| 寫 env 途中斷電 | 原子 rename 保證看到舊 env 或新 env;`uboot.env.good` 為第二道 | 🔴 未 |
| **`uboot.env` 損毀/遺失** | U-Boot 落回內建預設 env → 必須把預設寫成「開 slot A」 | 🔴 **設計必須明確處理,否則 = 磚** |
| **`kernel8.img`(U-Boot 本身)損毀** | ❌ **無回退 —— 磚。** 見 O1 | 🔴 未 |
| 兩槽都壞 | 停在 U-Boot prompt(無 console = 靜默)。需 §8 O3 的決策 | 🔴 未 |

## 7. 代價(誠實記錄,供 review 挑戰 §3 的範圍決策)

1. **我們要在開機鏈引入一個此 target 無人維護的元件。** 查核事實:OpenWrt 樹裡有 **24 個 `uboot-*` 套件,沒有一個是 bcm27xx/RPi**;`target/linux/bcm27xx` 完全不碰 u-boot;`uboot-envtools` 的 per-target 清單**也沒有 bcm27xx**。→ `uboot-bcm27xx` 套件與 envtools 設定**都要我們自建並長期維護**。
2. **多一個不受 A/B 保護的單點**(U-Boot 自身,O1)。
3. bcm2710 的 kernel/boot 路徑要改名 → 動到 `target/linux/bcm27xx/image/Makefile`(**兩板共用**,須比照 `dc81f7e` 的做法:per-device opt-in、bcm2711 逐字不變)。
4. 與 **#74 verified boot** 的關係要另議:Pi 3 無 OTP 金鑰雜湊機制(Pi 4 專屬),chainloader 反而多一段未簽章的可執行碼。惟 Pi 3 定位為民用/Base tier(`docs/productization.md`),#74 原本不覆蓋它 —— 須由 review 確認此前提仍成立。
5. 首次 bring-up 需要 **serial console**(#105,`hw-gated`)才能除錯 U-Boot 階段。無 console 時 U-Boot 停在 prompt = 靜默死板。

## 8. 開放問題(review 前必須有答案或明確風險接受)

- **O1 — U-Boot 自身能否 A/B?** RPi firmware 只認固定檔名 `kernel8.img`(由 `config.txt` 的 `kernel=` 可改)。候選:①接受 U-Boot 為不可 A/B 的單點,靠「極少更新 + 寫後驗證」壓低風險 ②用 `os_prefix`(D1 已驗可用!)讓 U-Boot 本身也有 A/B —— 諷刺地,`os_prefix` 在這裡是安全的,因為此時它切的是 chainloader 而非最終 kernel,且 U-Boot 的回退能力與它無關。**傾向 ②,但需驗證 `os_prefix` 與 `kernel=` 的互動。**
- **O2 — `bootcount` 寫回 env 需要 U-Boot 能寫 FAT。** `CONFIG_ENV_IS_IN_FAT` 的寫入路徑在 RPi 上是否可靠(SD 控制器、寫入時機)**未驗證**。若不可靠,退路是 `CONFIG_BOOTCOUNT_*` 的其他後端(如保留 RAM),但那與 D7 的靜默失敗有相同的斷電語意問題。
- **O3 — 兩槽都壞時的行為。** 停在 U-Boot prompt(無 console = 靜默)vs 無限重試 vs 進入某種最小救援模式。與 #142(離網節點診斷投遞)相關。
- **O4 — U-Boot 版本與 defconfig。** 需確認採用的 U-Boot 版本對 Pi 3A+(BCM2837, arm64)的支援狀態與 SD/MMC + FAT + GPT 驅動齊備度。**本文件未驗證任何 U-Boot 版本;§5 的機制描述基於 U-Boot 既有的 `bootcount` / `altbootcmd` / `ENV_IS_IN_FAT` 功能,尚未在 bcm2710 上實測。**

## 9. 前置擋點(與機制無關,但會讓任何 A/B 實驗撞牆)

目前 2710 image **同時帶 mm6108 + mm8108**。A/B 兩槽共用同一份 `root.squashfs`,雙 S1G 驅動會讓驅動拒載(`morse_sdio already registered`)→ **走 A/B 前必須先補 `-x mm6108only`**(#217 R6)。

## 10. 實作順序(review 通過後才開始)

1. **E1** 最小實驗:手工把一顆 U-Boot 放成 `kernel8.img`,在 3A+ 上開起來、進 prompt、`fw_printenv` 讀得到 env。(回答 O4)
2. **E2** `bootcount` / `altbootcmd` 端到端:故意讓 `bootcmd` 指向不存在的 kernel,驗證第 N 次自動走 `altbootcmd`。(回答 O2,這是**整個設計的成敗點**)
3. **E3** O1 的 `os_prefix` + `kernel=` 互動實驗。
4. **S4a** `uboot-bcm27xx` 套件 + `uboot-envtools` 設定入樹。
5. **S4b** `batman-slot` 加 SoC 分支(**維持單一檔案**)+ `platform-ab.sh` 去 `vcmailbox` 依賴 + `build-ab-payload.sh` per-SoC 清單 + `build-gpt-ab-card.sh` 產 `uboot.env`。
6. **S5** §6 失效矩陣全項實測(含「壞槽是否變成靜默死節點」)。
7. **S6** 回歸進 `daily-validation.sh` + **補 board guard**(#217 R5,不開第二份腳本)。

## 11. Verdict

_(待 review 填寫)_

## 參考

- #209(本單,含 D1/D7 實機結果)· #203(3A+ bring-up)· #89(升級機制)· #133(Pi 4 A/B,失效矩陣規格)· #217(build 規矩 R1–R6)· #105(serial console)· #74(verified boot)· #142(離網診斷)· #132(morse SPI 偶發 init 失敗)
- `docs/design/ab-sysupgrade-platform.md` · `docs/design/ab-autocommit.md` · `docs/field-resilience.md` · `docs/storage-architecture.md`
