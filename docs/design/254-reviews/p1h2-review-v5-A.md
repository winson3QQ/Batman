# 審查 A 第 5 輪:`254-p1-impl.md` v5(PR-P1 + PR-H2)

審查者 A,2026-10-21。範圍:**整份** v5,對照上層 v19、main f1a1122、firmware-2710、02 / 04 唯讀實查(只跑讀取指令;沒有印任何秘密)。

**判定:APPROVE-WITH-CHANGES**:0 BLOCKER / 0 MAJOR / 12 MINOR。

v4 我的 M1(trial 開機落空)與 B 的 4 個 MAJOR 都已解決;新機制我逐一對過原始碼或真機:
- `sysupgrade -n` 加落點斷言;
- `ALLOW_STALE_P5` 的檔案版旗標;
- 沙箱只在 CI 跑、`prov-artifact-match`;
- 主機端改在 Git Bash、簽章在 WSL;
- 02 p3 修補後會不會被 OTA 覆蓋;
- B 寫回 V 的 480 s 時限。

剩下的都是文件前後不一致,或實證範圍要補的 MINOR,可以在實作與實證階段處理,不需要再整份審一次。但 m1 和 m2 會直接影響無人值守時跑不跑得完,實作前請先改。

---

## 0. 本輪證據(唯讀)

| # | 事實 | 證據 |
|---|---|---|
| Y1 | 02 的 p1 `[pi4]` 已有 `dtoverlay=miniuart-bt` 與 `core_freq_min=500`;`vcgencmd get_config core_freq_min` = 500;state 目前沒有 `ble-ok` | 02 唯讀 |
| Y2 | `batman-slot apply` 寫 boot FAT 時只複製 `kernel8.img`、`start*.elf`、`fixup*.dat`、`*.dtb`、`overlays/`;驗證時跳過 `config.txt` 與 `distroconfig.txt` → **P-U11 補在 02 p3 的那一行不會被之後的 OTA 覆蓋** ✅ | `batman-slot:640-666` |
| Y3 | `allowed STALE_P5` 先讀 env,再讀 root 擁有的 `/tmp/batman-slot.allow-stale-p5`(opf);stage 1 寫入 `stale-allowed`,stage 2 讀到後放行 → §4.5.3 的「檔案版旗標走 sysupgrade」成立 ✅ | `batman-slot:80-82,477-517` |
| Y4 | sysupgrade stage 2 的結尾是 `umount -a; reboot -f`,不是單獨一個 `reboot -f` | `platform-ab.sh:213,246-247` 的註解 |
| Y5 | kernel 的 overlayfs 文件:overlay 掛載期間修改底層的 upper / lower,行為未定義。OpenWrt 的 `jffs2reset` 也是線上刪 upper,但緊接著重開 | `Documentation/filesystems/overlayfs.rst`(「Changes to underlying filesystems」);fstools `jffs2reset.c` |

---

## MINOR

- **m1** 鏈 1 第 7.6 步還寫著「`batman-slot apply` rc 進 A … → 重開進 A 的 trial」,沒有指定重開方式。這和 §4.5.0「寫另一槽一律走 `sysupgrade -n`(只有鏈 0 / 鏈 1 第 4 步例外)」矛盾,也正是 v4 M1 那一類的落空風險(F29)。**修正**:改成 `sysupgrade -n`(hold 旗標先寫好),或同樣走受控重開,再做落點斷言。`prov-legacy-upgrade` 的「apply 進 B / A」也明寫走 sysupgrade。
- **m2** §4.5.5 的允許清單以 E4 產生,但 F30 自己列出的改寫時間點有 3851 s(firewall)與 6340 s(system)。只要 E4 的快照是在開機不久後做的,就抓不到「快照時已被晚期改寫、還原重開後又回到開機時的內容」這種差異 → 無人值守時,restore 會零星 FAIL 而停下。**修正**:
  - E4 的快照至少要在 uptime > 2 h(> F30 最晚那一筆)時做;
  - 至少重複兩次,確認差異是確定性的;
  - 能找出寫入者的,改成只比對它不會改寫的 key。
- **m3** F-類與 R-類第 4 步「以快照 tar 覆蓋 A 的 upper、刪除多出的檔」是在 overlay **掛載中**直接改 upper。kernel 文件說這是未定義行為(Y5)。**修正**:
  1. 停掉所有寫 overlay 的服務(列出清單);
  2. 解 tar 之後 `sync` 加 `echo 3 > /proc/sys/vm/drop_caches`;
  3. 不在中間做任何其他事,立刻 `batman-slot reboot committed`;
  4. 開機後再做 §4.5.5 的比對(這一步已經寫了)。

  在設計裡明寫「解 tar → 重開」之間是一個不可中斷的區段;中途 harness 死掉時,dirty 標記會讓下一次重跑。
- **m4** 鏈 0 與鏈 1 第 4 步的受控重開寫的是「停 docker / OTS、`sync`、`reboot -f`」;stage 2 是 `umount -a` 之後才 `reboot -f`(Y4)。p6(ext4 + docker)與 A 的 f2fs overlay 會被髒停機。**修正**:比照 stage 2:停服務 → `sync` → 把 p6 與 `/overlay` remount 成唯讀(或 `umount -a`)→ `reboot -f`。E1 要記錄下一次開機的 boot-reasons 與 fsck / f2fs recovery 的 log。
- **m5** P-U11 修補後,02 會符合 `ble-ok` 的全部條件(Y1:p1 已有,p3 補上,vcgencmd = 500),helper 就會在 02 寫 `ble-ok`。§5.2 寫的「04 有,02 沒有」會變錯;§5.5 (8) 與 tier A 用到的「02 是天然的負對照」也沒了。**修正**:更新 §5.2 的預期;`ble-ok` 的負對照改用白箱(例如 bind mount 一個讀不到 `core_freq_min` 的 `vcgencmd` stub)。
- **m6** 正規化:
  - (a) 04 的正規化寫「依 §4.5.3 跨槽重建,不帶 `ALLOW_STALE_P5`」,但 §4.5.3 第 4 步要用快照 tar 覆蓋,而正規化時**沒有快照**。要另外寫:sysupgrade V 進 A(hold)→ release → 然後依 §4.5.4 寫回 B。
  - (b) 「02 不自動」太寬了。只要有任何每日測項 OTA 過 02,02 的 B ≠ V,每次 prov run 一開始就會停下等人。但 §4.5.4 的「B 寫回 V」每個單位本來就在 02 上做。要改成:02 允許自動做 B 寫回 V,只禁止 A 重建或跨槽。
- **m7** 文件內還有幾處和 v5 的決定互相矛盾:
  - §5 開頭寫「人在場時跑」,和 P-U12 衝突;
  - §7.1 的「平台」列寫「主機端在 WSL;沙箱在 CI arm64 + 04」,和 §2.2、§4.10 衝突;
  - §4.2 的「root 以 `cryptpw` 對 shadow 驗」和 §2.2 的 fd 4 程序內比對衝突;
  - §4.2「stdin / stdout 經 ssh 接到 WSL」要改成「Git Bash 把 ssh 的 stdout 接到 `wsl … provclient sign`」,並寫明逐行去掉 `\r`(Windows pipe)。
- **m8** `prov-artifact-match`:沙箱用的是 `prov_test` build 的 helper,出貨的是 release build,兩者本來就是不同的二進位。所以它對 helper 能證明的最多只是「原始碼相同」,而且 OpenWrt 在打包後還會 strip,E5 很可能重現不了。設計已經寫了退路(只由節點 tier A / B 涵蓋)✅,但 §2.2 的說法要改成「腳本:逐位元組接到出貨產物;helper:只證明原始碼相同,行為由節點 tier A / B 驗」。
- **m9** §4.5.4 的 480 s:04 有 OTS,payload converge 或 first-load 期間 `HELD` 可能比較晚(B v4 m4)。E3 要記錄 04 上「開機到 `HELD`」的時間分布(10 次的最大值)。如果最大值接近 480 s,就調整時限或先停 OTS,否則無人值守時會頻繁停下。
- **m10** P-U12 的推播通知沒有定義通道:用什麼服務、token 放哪裡(只能放主機 0600,不能進 repo)、內容不能含秘密。「節點連不到超過 10 分鐘」時,節點並不在安全點;要寫明這時 harness 怎麼處理:不再送任何改狀態的指令,只通知,deadman 也不動作。
- **m11** §3 的受測 payload 副本是 `/opt/batdata/dv-prov/payload-<ver>/`(目錄),但 `sysupgrade -n` 吃的是檔案。要寫明副本是 `.tar.gz` 加上 SHA256SUMS,以及 sysupgrade 實際收到的路徑。
- **m12** 02 在 restore 時的 B 寫回 V 是經 mesh 的 OTA(約 120 MB)。如果 B 的 trial 沒能入網,`back_to_a` 送不出去 → 等到期限 revert → 寫 `bad-slot` → S0 FAIL → 依 §7.4 停下(02 不會失聯 ✅)。這條路徑要列進 §7.4「需要人處理」的清單,並寫明清除 `bad-slot` 的條件:只有在 `release` commit 了同一版之後才清。

---

## v4 發現的狀態

**我(A)的 v4**

| 發現 | 狀態 |
|---|---|
| M1 trial 開機落空 | ✅ §4.5.0:`sysupgrade -n`、落點斷言、重試一次、E3 10/10;殘留一處(m1) |
| m1 firstboot 實證 | ✅ E4 |
| m2 upper 全覆蓋 | ✅ tar 含 symlink / whiteout、清單含型別;晚期改寫的時間窗見 m2 |
| m3 R 類的 p6 | ✅ |
| m4 B 寫回的時限 | ✅ 480 s;時間分布見 m9 |
| m5 正規化與 02 | ⚠️ 不帶 `ALLOW_STALE_P5` ✅、`reflash-survives` 回 A ✅;正規化的具體步驟與 02 的 B 寫回見 m6 |
| m6 沙箱 caps | ✅(改成只在 CI) |
| m7 root 密碼比對 | ✅ fd 4;§4.2 文字待更新(m7) |
| m8 dropbear 權限 | ✅ |
| m9 長時間 | ✅ P-U12、§7.4;通道見 m10 |
| m10 標記順序 | ✅ |
| m11 L63 / N3 | ✅ |

**B 的 v4**

| 發現 | 狀態 |
|---|---|
| M1 overlay 比對沒有基線 | ✅ `uci export` 加 E4 允許清單;時間窗見 m2 |
| M2 節點沙箱做不到隔離 | ✅ 只在 CI 跑,加 `prov-artifact-match`(限制見 m8) |
| M3 02 落到 B | ✅ P-U11(Y2:修補不會被 OTA 覆蓋);副作用見 m5 |
| M4 02 的失聯路徑 | ✅ 02 不做重建、不帶 stale 正規化 |
| m1 WSL 沒有 key / NAT | ✅ 主機端改在 Git Bash |
| m2 鏈 1 第 4 步 stale | ✅ |
| m3 R 類的 p6 | ✅ |
| m4 HELD 遲到 | ✅ 480 s;分布見 m9 |
| m5 dumpable / stdin | ✅ |
| m6 chanfix 的 log 行 | ✅(實作時取確切字串,150 s 內沒出現 → FAIL) |

## 判定
**APPROVE-WITH-CHANGES**。沒有 BLOCKER / MAJOR。m1–m12 請在實作前改進文件(m1、m2 會直接影響無人值守跑不跑得完)。E1–E5 與 02 p3 的修補照 §9 先做,結果寫回設計;E1 / E4 的結果如果推翻某個前提,就把那一段送回審查。
