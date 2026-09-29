# Design: A/B on Pi 3 (bcm2710) —— 退回的責任人按失敗類別劃分 (#209)

Status: **DRAFT v2(待二輪對抗式 review)**
Parent: #209 · 父單 #203 / #89 · 姊妹 #133(Pi 4 A/B)
v1 的 verdict:**NEEDS-REWORK**(獨立 reviewer,2026-09-30)—— v1 主張 U-Boot chainloader,本版改為 **A1 主案 / A2 降為第二期**,理由見 §3。v1 的事實錯誤更正見 §10。
SoT: #75

## 0. 一句話

Pi 3 沒有「一次性試開 + 自動回退」的 firmware 功能;本設計**不引入新的開機元件**,改為按失敗類別分派退回責任 —— **開不起來**交給「寫後驗證 + 有界重試」,**開得起來但功能壞**交給正在運行的系統自己改回去,而**唯一能清零重試額度的事件是 commit 成功**。

## 1. 問題:三個動詞,Pi 3 只有一個

Pi 4 的 A/B(#133 已上機驗證)建立在 EEPROM bootloader 上。Pi 3 家族**沒有 EEPROM bootloader**(SoC ROM → SD 上的 `bootcode.bin` → `start.elf`),整套機制不存在。

| 動詞 | Pi 4 | Pi 3 | 實測依據 |
|---|---|---|---|
| **切換**(指定下次開哪槽) | `autoboot.txt` 的 `boot_partition` | ✅ `os_prefix=B/` | #209 D1,3A+ 實機雙向驗過 |
| **一次性試開**(旗標自清) | `[tryboot]` + `vcmailbox` 觸發 | ❌ 無對應物 —— `os_prefix` 是**持久**設定 | D1 |
| **壞槽自動回退** | firmware fallback | ❌ **完全沒有,且失敗是靜默的** | #209 D7:藏起 `B/kernel8.img` → L2 零反應、無重試無降級,拔卡才救回 |

### 1.1 「持久」這件事的真正後果(v1 漏掉,使用者 2026-09-30 指出)

`batman-autocommit` 對「開得起來但不健康」的處置是最後一行:

```
slot $SLOT NOT healthy after ${TIMEOUT}s — left as trial (reverts on reboot)
```
(`feed/batman-provision/files/usr/bin/batman-autocommit`,迴圈結束處)

**「留成 trial,下次重開就退回」在 Pi 4 是真的**(試開一次性,沒 commit 就自動回舊槽);**在 Pi 3 上是假的** —— `os_prefix` 持久,沒人改它就永遠留在壞槽。

> **開得起來 ≠ 可以 commit。** Pi 4 是靠「一次性試開」**免費**拿到「不健康就退回」;Pi 3 必須自己實作。v1 完全沒處理這條,**兩個方案都中**。

## 2. 我們已有的基礎建設:抽象邊界切得對,只缺一個後端

讀 code 確認(此表經 v1 review 逐項查證為準確):

| 層 | 檔案 | 與 SoC 的耦合 |
|---|---|---|
| 健康 gate + 自動 commit | `feed/batman-provision/files/usr/bin/batman-autocommit` | ✅ **已 SoC-agnostic** —— 只透過 `batman-slot is-trial / active / commit` 講話 |
| 卡版面 | `scripts/build-gpt-ab-card.sh` | 🔴 Pi 4 六分割專用;Pi 3 走五分割 profile(§5.6) |
| payload 打包 | `scripts/build-ab-payload.sh:24` | 🟡 清單寫死 `start4*.elf` / `fixup4*.dat`,且**無條件收 `kernel8.img`** |
| sysupgrade 接縫 | `feed/.../usr/lib/batman/platform-ab.sh` | 🟡 `RAMFS_COPY_BIN` 含 `vcmailbox`;`:55` board check **永遠只 WARN 不拒**(自留 `TODO tighten per-SoC`) |
| **槽機制核心** | `feed/.../usr/sbin/batman-slot` | 🔴 Pi 4 耦合集中在此:`fw_part`(:46)/`count_fats`(:60)/`assert_fw_sane`(:74)/`write_autoboot`(:89)/`committed_fw`(:185)/`is_trial`(:191)+ `cmd_apply` 檔案清單(:163)+ `vcmailbox`(:180) |
| 驗證 | `scripts/ab-selftest.sh` · `tests/ab-card-invariants.sh` · `scripts/daily-validation.sh` | 🔴 **無任何 board guard**,且對 Pi 3 卡是**硬失敗不是 skip**(`ab-selftest.sh:73` 無條件 `vcmailbox`、`:95-96` 讀不到 bootloader partition 就 `exit 2`) |

**結論**:#209 D5「加 SoC 分支,不 fork」成立 —— 上層(dwell、健康判準、revert 語意、#211/#212)一行都不用改。缺的是 `batman-slot` 的 Pi 3 後端。

## 3. 範圍決策的演變(誠實記錄)

1. **2026-09-30 早:使用者拍板「full A/B」**(kernel + rootfs 都受保護),否決 rootfs-only。理由:Pi 3 是民用 tier 量產板,kernel 更新不該需要人到場。
2. **v1 據此提出 U-Boot chainloader,review 判 NEEDS-REWORK。** 其中 **M6** 指出致命前提問題:Pi 的 device-tree overlay 機制(`config.txt` 的 `dtoverlay=`、`overlays/*.dtbo` 參數解析)**是 firmware 的邏輯**,而我們的 overlay 是承重的(morse SPI/PS、ramoops)。若 overlay 與 `config.txt` 留在單一份不受保護的 p1 → **「kernel 更新受保護」是假的**(kernel 與 overlay 通常一起改);若要 U-Boot 自己 `fdt apply` → 得在 U-Boot script 裡重建 Pi 的 overlay 機制,第一個受害者正是 #132 的 morse init 路徑。**→ chainloader 在解決 M6 之前也交不出 full A/B。**
3. **使用者追問「開得起來並不保證功能正常,不該就 commit」** → 見 §1.1 與 §4:這一類**兩案都只能靠正在運行的系統退回**,U-Boot 的 bootcount 對它**毫無幫助**(節點開得起來,計數不會累)。
4. **修正後的決策(使用者 2026-09-30):A1 主案,A2 降為第二期。** 因為 (1) 的「100% vs 99%」對比在 (2)(3) 之後不成立:A2 多付的代價買到的只剩「完全開不起來」那一類,而 A1 對該類也覆蓋了絕大部分。

> ⚠️ 這是對 (1) 的**修改**,不是繞過。若二輪 review 認為 §6 的殘留類別不可接受,應回頭重議,而不是默默放寬。

## 4. 分析核心:按失敗類別看「誰能救」

| 失敗類別 | 唯一可能的救援者 | A1 的做法 | A2(U-Boot)的做法 |
|---|---|---|---|
| **① 完全開不起來**(kernel 半寫/缺失/壞) | 只能是開機前就存在的東西 | 寫後逐 byte 驗證才 flip(**消滅這一類的主要成因**)+ 有界重試(§5.2) | U-Boot bootcount |
| **② 開得起來,但功能壞** | **正在運行的系統自己** —— 它活著,它改得動指標 | 判決失敗 → 主動改回 + 重開(§5.3);兜底同 §5.2 | **計數器完全幫不上**(開得起來,計數不會累)。review M2/M3 正是指出這條在 v1 未定義 |
| **③ kernel 載入成功,但在 preinit 之前就死**(壞 DT、極早期 panic) | 只能是開機前就存在的東西 | ❌ **無自動回退**(§6) | U-Boot bootcount ✅ |
| ④ 健康、已 commit、之後才壞 | 日常監控 / app 層自癒 | 不屬 A/B 範圍(#216 分層健康模型) | 同 |

**A2 的全部溢價 = 類別 ③。** 而類別 ③ 在 Pi 4 上也不是我們保護的 —— 是 firmware 的盲目 fallback 撿回來的。

## 5. A1 設計

### 5.1 寫後驗證才切換(對付類別 ①)

`apply` 的順序**硬性**如下,任一步失敗即中止且**不動 `config.txt`**:

1. 寫非現用槽的 rootfs partition(p2 或 p3)。
2. 寫非現用槽的 boot 子目錄(`A/` 或 `B/`:kernel、dtb、`overlays/`、該槽專屬 `cmdline.txt`)。
3. `sync`,然後**讀回逐 byte 比對 checksum**(rootfs + 每個 boot 檔)。不符 → 中止。
4. 寫「尚未通關」標記 + 重試額度(§5.2)。
5. **最後才** flip `config.txt` 的 `os_prefix=`,並**讀回驗證**(見 §5.5)。

D7 實驗製造的失效(kernel 不存在/不完整)正是第 3 步擋掉的類別。

### 5.2 一個計數器,兩類共用:**清零的唯一條件是 commit 成功**

- `apply` 第 4 步寫入:`unproven=1`、`attempts_left=N`(建議 **N=3**,與 #132 morse SPI 偶發 init 失敗的重開次數量級一致)。
- 每次開機,**早期 userspace**(OpenWrt `preinit` 鉤子)若見 `unproven=1` 則 `attempts_left--`;歸零 → 把 `os_prefix` 改回良好槽並重開。
- **`batman-slot commit` 是唯一會清掉 `unproven` 的動作**,而 commit 只由 `batman-autocommit` 在健康判決通過後呼叫。

於是:

| 情形 | 有人清零嗎 | 結果 |
|---|---|---|
| 開不起來(類別 ①/③) | 沒有東西跑得到清零點 | 額度用盡 → 退回 |
| 開得起來但不健康(類別 ②) | autocommit 永不 commit → 不清零 | 額度用盡 → 退回(且 §5.3 通常更早就退了) |
| 健康 | commit 成功 → 清零 | 留在新槽 |

**「開得起來」自動不算通關,必須功能正常才算。** 這正是使用者要的語意,並且順帶修掉 review **M2**(v1 的 bootcount 會讓健康節點自己莫名跳回舊槽:因為 v1 沒有任何東西清零,而本設計裡健康節點一定 commit 得掉)。

**寫入預算(#104)**:`unproven` 不存在時,`preinit` 鉤子**不寫任何東西**。→ **已 commit 的正常開機零 SD 寫入**,符合 `docs/field-resilience.md` 的 zero-steady-state-write 承諾。這等於把 review M2 建議的 `upgrade_available` 閘門套進來。

### 5.3 不健康就主動退回(對付類別 ②)

`batman-autocommit` 判決失敗時,不能再停在「left as trial (reverts on reboot)」—— 那句在 Pi 3 是假的(§1.1)。Pi 3 後端必須讓它走 **`batman-slot rollback`**:改回 `os_prefix` + 清 `unproven` + 重開。

- **`batman-autocommit` 本身仍不需修改**:它現在的 TIMEOUT 路徑只是 log + `exit 0`。要新增的是一條「負面判決 → rollback」的路徑;**此為對 `batman-autocommit` 的唯一改動點,且應以 SoC 無關的方式寫**(Pi 4 上 rollback 是冗餘但無害的明確化)。
- §5.2 的計數器是**兜底**,處理「判決還沒出來就斷電」與「rollback 寫入失敗」。

### 5.4 `batman-slot` 的 Pi 3 後端:動詞對映

| 動詞 | Pi 4(現況) | Pi 3(本設計) |
|---|---|---|
| `apply <payload>` | 寫非現用槽 + 驗 `[tryboot]` 對準 + `vcmailbox` | §5.1 五步(驗證後才 flip) |
| `is-trial` | 解析 `autoboot.txt` 的 `[all]` | 讀 `unproven` 標記 |
| `commit` | 原子改寫 `[all]` = 現用槽 | 清 `unproven` + `attempts_left`(**唯一清零點**) |
| `rollback` | 原子改寫 `[all]` = 另一槽 | flip `os_prefix` 回良好槽 + 清 `unproven` |
| `active` | 解析 `/proc/cmdline` 的 `batman_slot=` | **不變** —— 該槽專屬 `cmdline.txt` 帶 `batman_slot=<S>`(D1 已證 `os_prefix` 會改讀 `B/cmdline.txt`) |
| `assert_fw_sane` 等價物 | 比對 firmware 實際開的 FAT index | 比對 `config.txt` 的 `os_prefix` 與 `/proc/cmdline` 的 `batman_slot=` 是否一致 |

### 5.5 `config.txt` 是唯一不可復原點 —— 寫法規定

`docs/storage-architecture.md:35` 已認定這點。硬性規定:

- **只寫 `os_prefix=` 那幾個 byte**,不重寫整檔。
- 同目錄 staging → `sync` → rename → `sync`(比照 `batman-slot:89` `write_autoboot()` 的原子策略)。
- 保留 `config.txt.good` 錨點(對應 Pi 4 的 `ab.good`)。
- 寫後**讀回驗證**;不符即視為 apply 失敗。
- ⚠️ **Windows 端絕不可用 `Set-Content` / `>` 寫 boot 分割的檔案**(CRLF → firmware 找不到 include 檔 → 整台開不起來,#208 實際發生過);必用 `[IO.File]::WriteAllBytes`。

### 5.6 卡版面:改採既有的五分割 profile(修正 v1)

v1 寫「沿用 #133 六分割」,**與既有定案衝突**(review SF4,已查證):`docs/storage-architecture.md:32-38` 的 Pi 3A+ profile 是 **單一 boot p1(內含 `A/` `B/` 兩套)+ p2/p3 rootfs + p4 config + p5 data**。本設計**照它**,並同批更新該文件(§11)。

A1 因此與既有版面決策**天然相符** —— 而 A2 需要的 `uboot.env` / raw env 區段才是會逼版面改動的那一方。

### 5.7 計數器與標記放哪裡

候選(留給二輪 review 裁決,**不在此擅自定案**):

- **p4(config partition,ext4)** —— 已存在、可寫、與 `96-batman-config-migrate` 同一塊;`preinit` 階段能否掛載需驗證(**O2**)。
- p1 FAT 上的小檔 —— 最簡單,但把寫入放回「唯一不可復原點」所在的 FAT,重蹈 review **M5** 批評 A2 的同一個錯。**傾向不採**。
- 專用 raw 區段 —— 最安全,但要改版面。

**硬需求(不論選哪個)**:標記寫不進去時**必須是可觀測的失敗,不能被吞掉**。否則 `attempts_left` 永遠不動 → **退回機制靜默失效,而節點外觀健康、daily-validation 全綠**(review M5 點出的 fail-silent 模式)。→ 主機端需有「標記可寫 + 計數器真的在動」的斷言進 `daily-validation.sh`。

## 6. A1 明確**不**保護的範圍(誠實,供 review 挑戰 §3)

**類別 ③:kernel 載入成功,但在 `preinit` 跑到之前就死**(壞 device-tree、極早期 panic)。

- 此時沒有任何我們的程式碼執行過 → 無法遞減計數器 → **無自動回退**。
- `panic=10` 讓它至少是**可觀測的重開迴圈**而非靜默死機(`DEVICE_CMDLINE_EXTRA := rootwait=20 panic=10` 已烤進 bcm2710 image,firmware `dc81f7e`,實機 `/proc/cmdline` 已確認)。
- 現場處置 = 換備用預燒卡(`docs/field-resilience.md:55` 已把它定為實務救援手段)。
- **對照事實**:Pi 4 對這一類的保護**不是我們做的**,是 firmware 盲目 fallback。A2 能覆蓋它,代價見 §8。
- 降低發生率的手段(非回退):CI 的 board-tag 硬拒(§9 S4b)+ bench gate(#113)+ §5.1 的讀回驗證。

## 7. 失效矩陣(**全部待實測**,照 #133 規格)

| 情境 | 期望行為 | 已驗證? |
|---|---|---|
| 新槽 rootfs/kernel 寫一半斷電 | 第 3 步驗證不符 → 中止,`config.txt` 未動 → 下次開機仍在舊槽 | 🔴 未 |
| 新槽 kernel 完整但缺 dtb/overlay | 同上被第 3 步擋下 | 🔴 未 |
| 新槽開得起來但服務全死 | autocommit 負面判決 → `rollback` → 退回並重開 | 🔴 未 |
| 新槽開得起來但**判決前斷電**,反覆如此 | `attempts_left` 每次遞減 → 歸零後自動退回 | 🔴 未 |
| **`config.txt` 寫一半/損毀** | `config.txt.good` 錨點 + 讀回驗證;預設落回良好槽 | 🔴 未 **必須明確處理,否則 = 磚** |
| **標記/計數器寫不進去** | 可觀測失敗 + daily-validation 斷言;**不得靜默** | 🔴 未 |
| kernel 載入成功但 preinit 前就死(類別 ③) | ❌ 無自動回退;`panic=10` → 可觀測重開迴圈;換卡 | 🔴 未 |
| 兩槽都不健康 | 交替退回?需定義上限,避免無限來回(review M3 對 A2 的同一批評也適用於此) | 🔴 未 **設計待補** |
| `cmdline.txt` 缺 `batman_slot=` | `active_slot()`(`batman-slot:26`)回空 → `assert_fw_sane` die / `is-trial`=2 / autocommit 記 "cannot determine" 後退出 / `ab-selftest.sh:94` FATAL | 🔴 未(review SF2 指出 v1 漏了整條退化路徑) |
| bare `rootwait` 混進任何一槽的 cmdline | 必須被 `ab-selftest` 斷言擋掉(`ab-selftest.sh:122-133` 已對兩槽各自斷言) | 🔴 未(Pi 3 卡上該腳本目前硬失敗,見 §2) |

## 8. A2(U-Boot chainloader)= 第二期,進入條件如下

保留為選項,但**必須先滿足 v1 review 的 MUST-FIX**,原樣列出以免被淡化:

- **M1** `apply` 目標為 slot A 時會覆寫 p1 上的 chainloader 自己(Pi 3 firmware 只讀第一個 FAT,而 `batman-slot:31` `slot_bootdev A = p1`;`cmd_apply:163-167` 會寫目標槽 boot FAT;v1 §5.5 又把 `kernel8.img`=U-Boot 列進 payload)→ **每兩次升級覆寫一次正在服役的 bootloader**。必須:(a) p1 寫入硬排除 `kernel8.img`/`config.txt`/env;(b) U-Boot **凍結為出廠燒錄件,永不進 OTA payload**;(c) `platform_check_image` 對 bcm2710 board 不符**硬拒**(現行 `platform-ab.sh:55` 永遠只 WARN)。
- **M2** `bootcount` 需 `upgrade_available` 閘門(否則健康節點自己跳回舊槽)。→ 本版已把此形狀吸收進 §5.2。
- **M3** `altbootcmd` 的 env 變更語意必須寫死,否則「永遠走 altbootcmd」或「無限交替開機」。
- **M4** O1② 用 `os_prefix` 給 chainloader 自己做 A/B **不成立**:`os_prefix` 是整組 OS 檔案的前綴(kernel/cmdline/dtb/overlays),缺一即 D7;且**試開新 U-Boot 沒有任何計數器保護**(會數次數的正是那顆還沒證明自己的 U-Boot)。→ 正解是接受 U-Boot 為凍結的不受保護元件,論證方式是**對等於 Pi 4 的 EEPROM bootloader**(它本來也不受 A/B 保護)。
- **M5** env 不可用 `CONFIG_ENV_IS_IN_FAT`(就地覆寫、非原子、每次開機寫、且與 U-Boot 本體同一個 FAT)→ 改 `CONFIG_ENV_IS_IN_MMC` + `CONFIG_SYS_REDUNDAND_ENVIRONMENT`;`saveenv` 失敗不得靜默。
- **M6** 先回答「誰套用 device-tree overlay」再重算代價(見 §3.2)。**這是 A2 的成敗前提。**
- **M7** `CONFIG_BOOTDELAY=-2`、**禁止停在 prompt**、失敗即 `reset`;並記入矩陣:U-Boot 階段**沒有 watchdog**(procd 還沒起來餵 bcm2835-wdt)。
- **M8** ramfs 需 `fw_setenv` **以及 `/etc/fw_env.config`**(設定檔,`RAMFS_COPY_BIN` 帶不動 → 要 `RAMFS_COPY_DATA`)。少了它會「槽已寫完但 trial 沒 arm」,與當年漏 `tr` 同一類(`platform-ab.sh:22-27` 的血淚註解)。
- 另:**RAUC 從未被評估**(見 §10 更正 1)。若走 A2,應同時評估「RAUC 當介面層 + 我們的機制當它的 backend」,它能在同一介面下同時服務 Pi 4 與 Pi 3。

## 9. 開放問題與實驗(A1)

- **O1 — `preinit` 是否足夠早、能否改 `config.txt` 並重開?** OpenWrt `preinit` 在 rootfs 掛載後、服務啟動前執行。需驗證此時 p1 可掛可寫。**若不行,退路才是 initramfs**(`CONFIG_BLK_DEV_INITRD` 兩個 subtarget 目前都關,需加一個 kernel config symbol —— 但 A1 主案**刻意不依賴它**)。
- **O2 — 標記/計數器落點**(§5.7):p4 在 `preinit` 階段可否掛載?
- **O3 — 兩槽都不健康的上限策略**(§7 待補)。
- **O4 — `os_prefix` 的確切作用範圍**:它是否連 `overlays/` 都前綴(疑為 `overlay_prefix` 跟隨)。這決定 §5.1 第 2 步要寫哪些檔案。**需實測(E3)。**
- **O5 — 讀回驗證要驗到什麼粒度**:整個 rootfs partition 的 checksum 在 3A+ 上的耗時(影響升級視窗長度)。

### 實驗順序(review 通過後)

1. **E1** `preinit` 鉤子最小實驗:開機時能否讀寫標記、能否改 `config.txt` 並重開。(回答 O1/O2)
2. **E2** **端到端退回**:故意讓 B 槽開不起來 → 驗證 `attempts_left` 遞減並自動回 A。(**整個設計的成敗點**)
3. **E2b** **不健康但開得起來**:讓 B 槽開機但服務死 → 驗證 autocommit 負面判決觸發 `rollback`。(§5.3,即使用者指出的那一類)
4. **E3** `os_prefix` 作用範圍(O4)。
5. **S4** 實作:`batman-slot` SoC 分支(**維持單一檔案**)+ `platform-ab.sh` 去 `vcmailbox` 依賴 **且 board check 改硬拒** + `build-ab-payload.sh` per-SoC 清單 + Pi 3 五分割卡 builder。
6. **S5** §7 矩陣全項實測。
7. **S6** **board guard 與 S4 同批落地**(不可延後:`ab-selftest.sh` 對 Pi 3 卡是硬失敗不是 skip,否則 daily-validation 一路紅)+ 新回歸進 `daily-validation.sh`(含 §5.7 的 fail-silent 斷言)。

## 10. v1 的事實錯誤更正(review 指出,我已逐項查證)

1. **「`docs/field-resilience.md` 已列 bootchooser 為 #89 領先候選」→ 誤引。** `field-resilience.md:47` 與 `:64` 的領先候選是 **RAUC + Rtone 的 Raspberry Pi *firmware bootloader* backend**(= Pi 4 tryboot 那條路);barebox bootchooser 只是同列的 prior art。v1 誇大了自身方案的既有支持度,且 **RAUC 從未被評估**(見 §8 末)。
2. **「`kernel8.img` 兩板共用」→ 只有檔名共用。** bcm2711 的 `kernel8.img` 不能在 bcm2710 上執行,而 v1 又讓該檔名在 bcm2710 上改指 U-Boot;加上 `build-ab-payload.sh:24` 無條件收它、`platform-ab.sh:55` 只 WARN 不拒 → 這句正是 M1 磚化路徑的成因。
3. **「沿用 #133 六分割」→ 與 `storage-architecture.md:32-38` 的五分割 profile 衝突。** 本版改採五分割(§5.6)。
4. **「`os_prefix` 在這裡是安全的」→ 錯**(M4)。
5. **「initramfs 方案省不到成本」→ 成本比較不成立。** 加一個 kernel config symbol vs 自建維護一個上游不存在的 bootloader 套件 + 新增開機元件 + 可能重建 overlay 機制,差一個數量級。本版因此不再用該理由否決 initramfs,而是把它降為 O1 的退路。

## 11. 連帶要改的既有文件

`docs/storage-architecture.md:32-38` 現寫 Pi 3A+ 用 **`tryboot.txt`** 切換、且標注「未在 Pi 3A+ 驗證」。D1/D7 已回答該開放問題:**`os_prefix` 可切(雙向)、`tryboot.txt` 無此機制、壞槽靜默死**。應與本設計同批更新。

## 12. Verdict

_(待二輪 review 填寫)_

## 參考

- #209(含 D1/D7 實機結果)· #203 · #89 · #133 · #217(build 規矩 R1–R6)· #105(serial console)· #74 · #142 · #132 · #104(寫入預算)· #216(分層健康模型)
- `docs/design/ab-sysupgrade-platform.md` · `docs/design/ab-autocommit.md` · `docs/field-resilience.md` · `docs/storage-architecture.md` · `docs/productization.md`
