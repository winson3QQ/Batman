# 審查 A 第 4 輪:`254-p1-impl.md` v4(PR-P1 + PR-H2)

審查者 A,2026-10-21。範圍:**整份** v4,對照上層 v19、main f1a1122、firmware-2710(含 fstools 原始碼)、02 / 04 唯讀實查(只跑讀取指令;沒有印任何秘密)。

**判定:APPROVE-WITH-CHANGES**:0 BLOCKER / 1 MAJOR / 11 MINOR。
v3 的 BLOCKER 和 7 個 MAJOR 都已解決,新的機制我逐一對過原始碼。剩下的 MAJOR(M1)是:**直接呼叫 `batman-slot apply` 之後怎麼重開進 trial 沒有寫**,而照預設的方式重開,在這台 EEPROM 上已知會落空。每個測項單位的「B 寫回 V」都要經過這一步,所以必須先修好,並在 E3 實證。依使用者規則,M1 修完之後要再看一次(可以只看改到的段落,另外核對其他段落沒有跟著動)。

---

## 0. 本輪證據(唯讀)

| # | 事實 | 證據 |
|---|---|---|
| X1 | fstools `jffs2reset`:overlay 正在掛載 → `overlay_delete(mp, keep)` 把 upper 的檔案全部刪掉(`keep=0`),並把 fs_state 設成 PENDING。`rootdisk` 驅動把 `rootfs_data` 對應到 squashfs 之後那段的 loop(`v->blk` = `/dev/loop0`)→ 在這個 A/B、f2fs-on-loop 的 layout 上,`firstboot -y` 確實會清空本槽 overlay。下次開機 upper 是空的 → uci-defaults(在 lower)會重新執行。**⚠️ 這是從原始碼推論,沒有在真機跑過**(上層 F22 也只是唯讀查證) | `fstools-2024.07.14/jffs2reset.c` 的 `jffs2_reset`、`libfstools/rootdisk.c:100-224` |
| X2 | 04 的 overlay 裡,有些檔案是 fresh overlay 時由 uci-defaults 產生的:`etc/init.d/batdata-mount`(`/rom` 沒有,由 95 產生,`95:36,369`)、`lib/upgrade/platform.sh`(由 98 產生,`98-batman-sysupgrade:8`)、OTS 的 init stub(95)→ 同槽重建後會重新產生 ✅。overlay upper 共 52 個檔、68 個 whiteout,另有 `etc/rc.d/*` symlink;2 小時內有變動的只有 `openmanetd.db-wal/-shm`;`etc/urandom.seed` 每次開機都會改 | 04 `find /overlay/upper` |
| X3 | autocommit:`held()`(`/tmp` 的 hold、hold-once)會讓 watchdog 退出,**永遠不 revert**;**hold-commit 不會**:到期照樣 revert,寫 `bad-slot`,再 `reboot committed`(`:200-245`)。commit 時才刪 `bad-slot`(`:502`) | 讀檔 |
| X4 | **重開進 trial 的方式**:`batman-slot reboot committed` 遇到已 armed 的 tryboot → 退成 `exec reboot`(procd,`:759`)。ab-selftest 記錄:這台 Pi 4 EEPROM(2026-09-23)上,「raw tryboot + procd reboot」可能 no-op,直接開回 [all](`ab-selftest.sh:233-238`)。sysupgrade stage 2 用的是 `reboot -f`,armed 時約 25/25 正確(`platform-ab.sh:266-267`) | 讀檔 |
| X5 | daily-validation 的 `reflash-survives-config-202` 是對 `MESH_NODE` 跑(`:2111`);預設值不是 02 / 04(`:49`),由執行時的環境變數決定;`OTS_NODE` 預設 = `MESH_NODE`,`DNODE` 預設 = `OTS_NODE` | 讀檔 |
| X6 | 96 Lane A 在 p5 seeded 時還原 host key 與 `authorized_keys`;每台持久化的套件含 `openmanetd`;`99-halow-identity` 看到 `.batman-p5-restored` 就跳過個人化 → 同槽重建後,host key、`dhcpconfigured` 會回到 p5 的值 ✅ | `96:22,96-102`、`99-halow-identity:7` |
| X7 | stage-root / apply 的 `precheck` 會 `rm -f autocommit-skip-once`(`batman-slot:567`) | 讀檔 |

---

## MAJOR

### M1. 直接 `batman-slot apply` 之後「重開進 trial」的方式沒有定義;預設方式在這台 EEPROM 上已知會落空
- **用到的地方**:
  - §4.5.4 B 寫回 V:**每個 tier B 單位都要做,02 與 04 都是**;
  - §4.5.3 跨槽重建;
  - 鏈 0 第 3 步;
  - 鏈 1 第 4 步(「手動重開」)與第 7.6 步。
  
  文件只寫「重開」或「reboot」。
- **情境**:
  - 用 `batman-slot reboot committed`:tryboot 已 armed → 它退成 procd 的 `reboot`(X4)。這台 EEPROM 在這條路徑上可能 no-op(ab-selftest 已記錄)→ 節點開回 A,沒有進 trial。
  - 結果:p6 的 hold 旗標**沒有被消耗**(只在 tryboot 開機時消耗)→ 留下來 → 之後每次 run 都被 P3 的「leftover hold-commit flag」擋住(`dv-preflight.sh:38`);`slot-B.protected` 沒有更新;第 3 步的斷言 FAIL。tryboot 也可能還 armed 著,下一次任何重開都會意外進 trial。
  - 02 上的影響和 04 一樣,只是必須全程經 mesh 處理。
- **修正**:
  - 寫明重開方式:沿用 sysupgrade stage 2 的做法,`sync` 後 `reboot -f`(X4,約 25/25),或者整段改走 `sysupgrade -n`(fault-injection 的 `ota_boot` 就是這樣)。
  - 開機後斷言落點正確:DT `tryboot` = 1、`batman_slot` = 目標槽、`HOLD-COMMIT` 那一行出現。
  - 落空時:清掉 hold 旗標(H1 N3 的 `flag_clear` 規則:只在旗標還沒被消耗時清)、disarm、重試一次,仍然落空就 FAIL。
  - E3 要實測這個流程:至少連續 10 次「B 寫回 V」,10/10 都落在 B trial,沒有 `bad-slot`,也沒有殘留的旗標。

---

## MINOR

- **m1** 同槽重建依賴 `firstboot -y` 會產生 fresh overlay(X1:原始碼推論,沒有真機證據)。**把它加進 §9 第 2 步的實證**(E4):在 04 跑一次同槽重建,斷言 uci-defaults 重新執行過(`/etc/.batman-p5-restored` 被 99 刪掉的紀錄、96 的 verdict)、host key 指紋與 `dhcpconfigured` 等於 p5 的值、openmanetd 沒有重開。也要寫明 `firstboot -y` 之後由 `batman-slot reboot committed` 重開(不要用 `jffs2reset -r` 的 `reboot(RB_AUTOBOOT)`,它會繞過 explicit reboot)。
- **m2** overlay 清單的範圍只有 `etc/ root/ usr/ www/` 的**檔案**。應該改成整個 `/overlay/upper`:要含 `lib/`(98 產生的 `platform.sh`,X2)、`.cache/`,並記錄 symlink(`etc/rc.d/*` = 服務是否啟用)、whiteout(char 0:0)與目錄的權限。allow-list 依 X2 的實測至少要有 `etc/urandom.seed`(每次開機都變)、`openmanetd.db-wal/-shm`;這兩項會因為 F16 被寫回而內容不同,要寫明比對規則。
- **m3** §4.5.2 第 2 步只有「逐檔還原」分支寫了「p6 state 寫回或刪除」。R 類(同槽 / 跨槽重建)也要做,否則測項留下的 `bad-slot`(X3:held 的 trial 到期 revert 時會寫)、`ota-armed.mesh`、hold 旗標會殘留,第 4 步的「沒有 `bad-slot`」會 FAIL。
- **m4** §4.5.4 第 4 步「在 deadline 之前回 A」:trial 期限是 600 s,從 autocommit 啟動開始算。`HELD` 要等健康判定(services 與 mesh 取樣)才會出現。要寫明時限,例如 trial 開機後 480 s 內沒看到 `HELD` → 立刻 `back_to_a` 並 FAIL,以免到期 revert 寫出 `bad-slot`。另外,B trial 期間要停 joinwatch,或在 back_to_a 之後斷言 p5 清單沒變(B 的 `--on-join` 可能寫 p5)。
- **m5** 正規化與 02:`reflash-survives-config-202` 跑在 `MESH_NODE` 上(X5)。如果它是 02,正規化就需要在 02 上做跨槽重建,和 §4.5.3「02 不走跨槽重建」矛盾。修正:P9 斷言 `MESH_NODE` = 04,或寫出 02 的正規化路徑。另外,正規化的跨槽重建沒有快照可以依據,**不應該**帶 `BATMAN_ALLOW_STALE_P5=1`(會丟掉還沒存進 p5 的現場設定),要先讓 p5 fresh。
- **m6** `dv-sbx` 剩下的隔離缺口:
  - `/proc/sys` 是可寫的,`kernel.*` 等設定是全域的;
  - `/sys` 掛不掛、怎麼掛沒有寫;
  - 保留 `CAP_MKNOD` 的話,沙箱裡的程式可以 mknod 出真的 p5(179:5)。

  修正:`/proc/sys` 唯讀、不掛 `/sys` 或唯讀掛、建好 `/dev` 之後丟掉 `CAP_MKNOD`;負測試加上「mknod 179:5 失敗」「寫 `/proc/sys/kernel/printk` 失敗」。
- **m7** §4.2「root 密碼在節點上以 `cryptpw` 驗證」:明文在 provclient(provd uid)手上,如果把明文交給 root 比對,唯一的通道是 stdout,而 stdout 接到 WSL。修正:root 在降權前經 fd 把 shadow 的 hash 交給 provclient,provclient 在程序內比對 `crypt(pw, salt)`,只輸出 OK / FAIL。
- **m8** 鏈 1 第 7.3 步寫入 lab key 時,要寫明 dropbear 對權限的要求(`/etc/dropbear` 0700、`authorized_keys` 0600、root 擁有),並以 `-o IdentitiesOnly=yes` 只用 lab key 驗證,避免主機的 agent 用別的 key 登入,造成假的通過。
- **m9** 成本是 15–20 小時,而 H1 §7 規定 tier B 要「人在場時跑」。要寫明:每個單位之間都回到 S0,所以可以中斷、分好幾段跑(以 lease / 單位為斷點),報告合併;或者請使用者對有乙太網救援的 04 單位放寬「在場」要求(列入 §10 或 §1.1)。
- **m10** 快照在 §4.5.1 第 4 步做清單,第 6 步才寫 `/etc/.dv-prov-mark-<run_id>`;restore 第 4 步比對清單時,標記還在 → 多一個檔 → FAIL。要寫明排除它,或在比對之前刪掉。
- **m11** §5.7 的 L63 寫「上層已接受」太含糊。L63 的回到舊槽,實際上由 H1 N3(只在 PR 證據階段)與 `prov-downgrade` 涵蓋;要寫清楚是哪一個,以及 P-U8 之後 B 不再是舊版時,N3 要怎麼跑(先把舊版寫進 B)。

---

## v3 發現的狀態

| v3 | 狀態 |
|---|---|
| B1 鏈 1 鎖死 04 | ✅ 認領前先寫 key,以新連線驗證,失敗就中止;認領後再驗一次(細節見 m8) |
| M1 作廢 B | ✅ P-U8:B = V 且可開機、全套順序、P9 斷言 `.protected`;重開方式 → 本輪 M1 |
| M2 A 的漂移 | ✅ R 類重建、完整的內容清單、指紋 / IP / `dhcpconfigured` 斷言,X6 已確認重建能還原這些;細節見 m1–m3、m10 |
| M3 閘放寬 | ✅ 照 L44 |
| M4 沙箱隔離 | ✅ namespace、私有 `/dev` / `/tmp` / `/opt/batdata`、stub、負測試;gate 只在 CI 的 loop 卡跑;殘留缺口見 m6 |
| M5 gate 判讀 | ✅ 正向證據(`p5-check.rc` 的 mtime 加內容、預期的 die 訊息) |
| M6 `sysupgrade -b` | ✅ 改用 `-l` |
| M7 PENDING | ✅ P-U9:紅燈加 KNOWN 加到期日 |
| m1–m11 | ✅ 全部處理(p5 先寫回、直接 apply、成本重估、install lint、§5.7、killpoint 目錄、hold 先斷言生效、`release`、powerloss 拆單位、bcm2710 smoke、payload 副本以 sha 驗證) |

## 我確認成立的部分
- 同槽重建的機制在原始碼上成立(X1、X6),只差真機實證(m1)。
- 跨槽重建以 env `BATMAN_ALLOW_STALE_P5=1` 直接呼叫 `apply` 是有效的(`allowed()` 會讀 env)。
- 用 `batman-autocommit release` commit 會刪 `bad-slot`(X3)。
- 在 deadline 之前 `back_to_a`,不會寫 `bad-slot`(X3)。
- §4.8 的判斷順序(先比 identity 再比 gen;`--check` 在 rc 7 之前比對)可以擋住「混合寫入」。
- §5.7 對照上層 L1–L65 已經完整(只剩 m11)。
- 以 Go 的 `syscall.Setuid` 降權,在 go ≥ 1.16 會套用到所有 thread(go1.22 可用)。

## 判定
**APPROVE-WITH-CHANGES**。條件:M1 要寫進設計,並在 E3 以 ≥ 10 次連續的「B 寫回 V」實證通過;m1(firstboot 重建的真機實證)列入 §9 第 2 步。其他 MINOR 可以在實作時處理。依使用者規則,M1 修完後要再看一次。
