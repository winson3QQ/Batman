# 審查 B 第 5 輪 — `254-p1-impl.md` v5(PR-P1 + PR-H2)

審查者 B(獨立)。審查整份 v5(657 行),對照的依據:
- 上層 v19;
- main f1a1122 的原始碼;
- 02 / 04 與 WSL 的唯讀實查。

我沒有寫入節點、沒有重開、沒有重啟服務,也沒有印出任何秘密。

**判定:APPROVE-WITH-CHANGES**:0 BLOCKER / 0 MAJOR / 9 MINOR。

第 4 輪我提的 4 個 MAJOR、A 提的 1 個 MAJOR,在設計上都已經處理:
- E4 基線 + `uci export` + 附證據的允許清單;
- 沙箱只在 CI 跑,出貨產物由 `prov-artifact-match` 接上;
- P-U11 先補 02 的 p3;
- 02 只允許逐檔還原,正規化不帶 `ALLOW_STALE_P5`;
- 寫槽改走 `sysupgrade -n`,並做落點斷言。

剩下的都是 MINOR。其中三項在實作前要先補寫或實證:
- p3 那一行要放在哪一段(m1);
- 落點落空時要先 disarm tryboot(m2);
- Git Bash ↔ wsl.exe 的雙向 pipe(m3)。

---

## 0. 本輪驗證的事實

| # | 事實 | 證據 |
|---|---|---|
| Y1 | 02 的 p1 `distroconfig.txt` 以 `[pi0w] [pi3] [pi4] [cm4] [all]` 分段。`core_freq_min=500` 在 **`[pi4]`** 段,和 `dtoverlay=miniuart-bt` 在一起。**檔案的最後一段是 `[all]`**。`config.txt` 用 `include distroconfig.txt` 引入它 | 02 `cat /boot/distroconfig.txt`、`grep` config.txt |
| Y2 | `apply` 只複製 `kernel8.img`、`start*.elf`、`fixup*.dat`、`*.dtb`、`overlays/*` 到目標槽的 boot FAT;驗證時跳過 `cmdline.txt / config.txt / distroconfig.txt / autoboot.txt / bootcode.bin`;`invalidate_slot` 只寫 `cmdline.txt` 與 BATMAN-BAD → **OTA 不會覆蓋 p3 的 `distroconfig.txt`**。P-U11 的修改會一直保留 | `batman-slot:641-646,663,381-385` |
| Y3 | 02 的 `autoboot.txt`:`[all] boot_partition=1`、`[tryboot] boot_partition=2`。pi4 以 FAT 的順序編號,所以第 2 個 FAT = p3 = bootB。P-U11 改的檔案就是上層說的那一份 | 02 `cat /boot/autoboot.txt`;`batman-slot:21-22` |
| Y4 | 02 與 04 的 EEPROM 都是 `2026/09/23`,高於 2025-08-20 的下限。所以 p3 萬一在韌體層級壞掉,也有 PARTITION_WALK 退回,不會卡在 4 閃 | `vcgencmd bootloader_version` |
| Y5 | **WSL 其實 ssh 得到 04**(`ssh … true` rc=0,以 `none` 登入)。F32 說「NAT,mirrored 失敗」是對的,但「連不到節點」不對;WSL 缺的只是 key,以及看不到 L2 的 MAC | WSL 實測(第 4 輪) |
| Y6 | `batman-slot verify` 只檢查 layout / FAT 數 / MBR / 開機分割區是否一致,**不回報 tryboot 是否 armed**。要用 `vcmailbox 0x00030064` 的 GET 讀回(每日 `chk_trybootget_209` 的做法) | `batman-slot:798-800`;`daily-validation.sh:615-627` |

---

## MINOR

- **m1(P-U11 放的位置)**:§9 只寫「只加 `core_freq_min=500`」。
  - 如果直接加在檔尾,這行會落在 **`[all]`** 段(Y1)。Pi 4 照樣生效,但上層 `ble-ok` 的條件是「兩個 boot FAT 的 `[pi4]` 都有 `dtoverlay=miniuart-bt` 與 `core_freq_min=500`」,依段落判讀時不成立。
  - 修法:插在 p3 的 `[pi4]` 段、`dtoverlay=miniuart-bt` 之後,讓 p3 的 `[pi4]` 段與 p1 的逐位元組相同。P9 改用依段落判讀的解析;改前改後各印一次 diff。
  - Y2 說明 OTA 不會覆蓋這一行,請把它寫進 §1.2。
  - 04 的 p3 也要一起唯讀確認,因為 `ble-ok` 要兩個 FAT 都符合。
- **m2(落點落空的處理)**:§4.5.0 寫「清掉 hold 旗標,用 `batman-slot verify` 確認 tryboot 狀態」。但 `verify` 不回報 tryboot(Y6)。
  - 如果落空時 tryboot 還 armed,而 hold 旗標已經清掉,下一次任何重開都會開進 B 的 trial,而且沒有 hold → 健康時 autocommit 會 **commit B**。在 02 上這等於 S0 被破壞,需要人處理。
  - 修法:落空時先以 `vcmailbox` 讀 tryboot 旗標;armed 就 disarm(`0x00038064`)並讀回 0;之後才依 H1 N3 的 `flag_clear` 規則(只在旗標還沒被消耗時)清 hold。E3 加一個落空的白箱。
- **m3(Git Bash ↔ wsl.exe 的雙向 pipe)**:簽章往返要把 `ssh.exe`(節點的 provclient)和 `wsl.exe … provclient sign` 兩個 Windows 程序的 stdin / stdout 交叉接起來。在 MSYS 下這要靠 `coproc` 或 FIFO,而 MSYS 的 FIFO 是模擬出來的。另外 wsl.exe 有啟動時間與緩衝,這些都沒有實證。一旦卡住,nonce 的 60 s 會過期 → 所有認領 / 建網測項 FAIL。
  - 修法:§9 加 **E6**:在 Git Bash 下連續 20 次往返,每次 ≤ 20 s,`SIG` 正確。
  - 退路:Y5 顯示 WSL 本來就連得到節點,可以整條主機端都放在 WSL,另外在 WSL ext4 放一份 lab key(列進 §8);MAC 的查找仍在 Windows 做(`arp -a`)。
  - F32 依 Y5 更正。
- **m4(在掛著的 overlay 底下改寫 upper)**:逐檔還原(§4.5.2 第 2 步)與重建第 4 步,都在 A 正在執行、overlayfs 掛著的情況下,直接以 tar 覆蓋 `/overlay/upper`、刪檔、建 whiteout。Kernel 的 overlayfs 文件寫明:overlay 掛著時改動底層是 undefined behaviour(不會 crash,但看到的內容不保證一致)。之後雖然會重開,但 procd shutdown 期間的寫入(例如 `urandom.seed`)會再經由合併視圖 copy-up。
  - 修法:寫入前停掉全部會寫 overlay 的服務 → 寫 → `sync` → 立刻重開;重開時的落點規則照 §4.5.0。E4 再加一輪「tar 寫回 + 重開 → §4.5.5 比對」,證明這條路徑本身會收斂。
- **m5(文件內前後不一致)**:
  - §5 開頭仍寫 tier B「人在場時跑」,和 P-U12 衝突;
  - §7.1「平台」列仍寫「主機端在 WSL;沙箱在 CI arm64 + 04」,和 §2.2 / §4.10 衝突;
  - 鏈 1 第 7.6 步用 `batman-slot apply` + 「重開進 A 的 trial」,可是 §4.5.0 說只有第 4 步用直接 apply。要寫明第 7.6 步也走受控的 `reboot -f`,或改用 `sysupgrade -n`。
- **m6(P-U12 的通知)**:沒寫推播用什麼機制、token 存在哪裡(不得進 log 與 canary 範圍)。另外,「停在安全點」沒說清楚「單位中途 FAIL 且 restore 也失敗」時,節點會停在什麼狀態。例如 04 在測試網路或 fresh 槽上(OTS 停擺、02 被隔離),02 的 joinwatch 在 3600 s 後自動重開一次,之後依 `unjoined_boots_max` 不再自動重開。要寫出最壞情況下會持續多久,以及 04 部署角色受到的影響。
- **m7(02 的正規化)**:§4.5.0 說 02 不符 S0 就「FAIL 給人」。可是「B ≠ V」(例如發版時 ab-selftest 或 N3 動過 B 之後)在 02 上的修法,就是 §4.5.4 的 held trial,這在 restore 裡本來就允許 02 做。建議:02 的「B ≠ V」自動以 §4.5.4 修正;只有「A 側不符」才交給人。否則每次發版之後,P-U12 的無人值守 run 一開始就會停下。
- **m8(沙箱底的保真度)**:CI 的底是 1.5.11 的 rootfs,受測的是 rc。`prov-artifact-match` 要再比對 rc rootfs 與沙箱底的 `busybox`、`uci`、`dropbearkey`、`mount`、`mkfs.ext4` 的 sha。不同就列出,並寫明沙箱結論的適用範圍。
- **m9(Windows 那一側的秘密)**:WSL ext4 上的 0600,擋不住同一個 Windows 使用者經 `\\wsl.localhost` 讀取。§8 的「ext4 上才是真的 0600」要照實改寫:擁有者金鑰每次 run 隨機產生、短命,暴露程度和 Git Bash 的 lab key 同一級。簽章往返上的 `SIGN` / `SIG` 只有雜湊、密文、簽章,我沒找到明文秘密經過 Windows 端 ✅。

---

## v4 發現的狀態

| v4(B) | 狀態 |
|---|---|
| M1 overlay 比對沒有基線 | ✅ E4(重開一次、重建一次)產生允許清單,每條附證據;`config/*` 比 `uci export`;R 類以完整 tar 覆蓋。剩 m4 |
| M2 節點沙箱 | ✅ 只在 CI;`/proc/sys`、`sysrq` 唯讀;丟 `CAP_MKNOD`;`prov-artifact-match` + E5。剩 m8 |
| M3 02 落到 B | ✅ P-U11。剩 m1(放的位置) |
| M4 02 失聯路徑 | ✅ 正規化不帶 `ALLOW_STALE_P5`;02 只允許逐檔還原;需要重建就 FAIL + 通知 |
| m1 WSL 沒有 key、NAT | ✅ 主機端改在 Git Bash。新的風險見 m3;F32 要更正(Y5) |
| m2 鏈 1 第 4 步 stale | ✅ 加上 `ALLOW_STALE_P5` 並寫明理由 |
| m3 R 類的 p6 | ✅ §4.5.3 寫回 p6 |
| m4 B 寫回的時限 | ✅ 480 s |
| m5 dumpable、stdin | ✅ |
| m6 chanfix 的 log 行 | ✅ 從原始碼取字串,150 s 沒出現 → FAIL |

| v4(A) | 狀態 |
|---|---|
| M1 trial 落空 | ✅ `sysupgrade -n` + 落點斷言 + E3 10/10。剩 m2(落空時 disarm) |
| m1 firstboot 實證 | ✅ E4 |
| m2 整個 upper、whiteout、symlink | ✅ |
| m3 R 類的 p6 | ✅ |
| m4 480 s、B 的 `--on-join` | ✅ 改比檔案清單 |
| m5 MESH_NODE 與 02 | ✅ 正規化不帶 stale,02 不自動重建。建議見 m7 |
| m6 沙箱 caps | ✅ |
| m7 root 密碼比對 | ✅ fd 4 + 程序內比對 |
| m8 dropbear 權限、`IdentitiesOnly` | ✅ |
| m9 長時間 | ✅ P-U12 + §7.4。剩 m6 |
| m10 標記的順序 | ✅ |
| m11 L63 / N3 | ✅ |

## 其他確認成立(✅)
- P-U11 改的檔案就是上層說的那一份(Y3),之後的 OTA 不會蓋掉它(Y2)。兩台的 EEPROM 都高於下限(Y4),p3 改壞也會退回。
- 產品端與上層對得上:
  - 閘只放行 unclaimed;
  - 先比 identity,才比 gen;
  - `--check` 在 rc 7 之前比對;
  - `--persist-now` 遇到不一致拒絕;
  - `settings.set` 沒有可寫的 key;
  - `owner.*` 已回報上層(§10 第 10 點)。
- 我沒有找到會讓 02 或 04 失聯的路徑:
  - 鏈 1 認領前有 key 守門;
  - 04 的 trial 開機與重建都有 eth;
  - 02 只做逐檔還原,和 held 的「B 寫回 V」。
- 白箱不會外洩:
  - `-wbox` 只進 B,之後被寫回 V;
  - P9 擋掉 `-wbox`;
  - test helper 放在 tmpfs,以 bind mount 蓋上;
  - build gate 檢查 tags 與標記字串;
  - 沙箱不上節點。
- 秘密:
  - 擁有者私鑰只在 WSL;
  - fleet key 經 fd 3,只在節點上;
  - root 密碼在節點的程序內比對;
  - `sysupgrade -l` 不產生 archive。

## 判定
**APPROVE-WITH-CHANGES**(0 / 0 / 9)。條件:
1. 實作前把 m1(p3 段落與 P9 解析)、m2(落空時先 disarm)、m5(不一致處)寫進設計;
2. §9 加 E6(Git Bash ↔ WSL 往返)並實證;
3. E4 包含 tar 寫回 + 重開(m4)。

其他 MINOR 可以在實作時處理。
