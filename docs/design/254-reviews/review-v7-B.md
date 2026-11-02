# #254 階段 1 實作設計 v7 — 獨立審查 B(第 7 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v7(branch `design/254-stage1-impl` @ c2e6b88),加上 v4/v5/v6 中標「同 vN」的小節。原始碼 = main f2f2bf6;firmware `/home/yello/firmware-2710`(sysupgrade、`etc/init.d/boot`、procd `system.c`、fstools `jffs2reset.c` / `libfstools/overlay.c` / `mount_root.c`)。
只做唯讀:讀檔、`ssh root@10.41.1.3` 跑 `grep/ls/cat/mount/readlink/uci show/command -v/pgrep`。沒有寫入、沒有重開、沒有跑 bluetoothctl。

## 0. 結論

**判定:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 11 MINOR。**

- v6 的兩個 MAJOR 都修了。正面哨兵、attempts 寫不進就停、停住時不掛舊 p6、有意圖就上鎖,這四條我逐一對過原始碼,方向都對。fstools 的 PENDING 機制(`jffs2reset.c` 先 `fs_state_set(PENDING)` 再 `overlay_delete`;`overlay.c:451` 下次開機見 PENDING 再刪一次)讓「F4 做到一半」和「F4 之後又有人寫 overlay」兩種情況都安全。
- 剩下的 **1 個 MAJOR** 在「哨兵不在 ⇒ overlay 已清」這條推論被**撤銷流程自己**打破:F3 的 `--reset-intent` 在意圖**已經 rename 進 p5 之後**才做 umount + ro 讀回。讀回失敗回 rc 1,helper 照 §4.5 撤銷,撤銷會**刪哨兵**。結果是:p5 上有意圖、overlay 沒清、哨兵卻不在。下一次開機 W1/W2 會把 p6、p5 清掉,overlay 原封不動,而使用者剛被告知「重置已取消,請換卡」。這會丟掉 p6 上的資料(OTS DB、任務紀錄)。修法是局部的:F3 的結果不確定時不准撤銷。
- 11 個 MINOR 大多是 W 階段的邊角與文件不一致,可以在實作和程式碼審查時收掉。其中 m1–m9 要列成 **PR-P1 的必要條件**(見 §6)。
- 依使用者規則,MAJOR 未關不能核准。v8 只需要改 F3 的失敗處理,加一個負對照。我預期下一輪可以核准。

## 1. 先補:缺的生命週期列與資源

| 缺的路徑 / 資源 | v7 的行為 | 對應 |
|---|---|---|
| **F3 rc 1,但意圖其實已經寫進 p5**(rename 成功,之後 umount / ro 重掛 / 讀回失敗) | 撤銷:刪哨兵、刪 marker、apps 改回、payload 重啟;下次開機 W1/W2 清 p6/p5,overlay 不清 | **M1** |
| **overlay 掛不起來,開機退回 tmpfs overlay**(94-batman-baseline 記錄過的現場事故:「F2FS-fs (loop0): Failed to read root inode」→ tmpfs overlay) | tmpfs 上沒有哨兵 → 判成「overlay 已清」→ W1/W2 清 p6/p5,真正的 overlay 還是前任的 | m1 |
| **哨兵在、意圖不在、marker 不在** | 沒有任何元件處理;helper rc 7 + overlay 有完整身分 →「補 persist」→ 前任的認領被寫回 p5 | m1 |
| **helper 在 F4 的 jffs2reset 之後、F5 之前 crash / respawn** | §4.5 只列「哨兵在」與「無意圖」兩種;「marker 在、意圖在、哨兵不在」沒寫 | m2 |
| **Wa 遇到的是 tryboot trial(不是 EEPROM 開錯槽)** | 文件說「`fw_override_check` 把槽修正」,但 tryboot 時它直接 `return 0`;autocommit 遇到意圖時該 commit 還是 revert 沒寫 | m3 |
| **W2 被打斷**(p5 不是 ext4) | 文件說「96 依 `last_known_state` 上鎖」;但 p6 剛被 W1 清掉,沒有 `prov-state` → 實際上走 4b(開放) | m4 |
| **F5 / W0 的重開機在 Pi 4 slot B 上** | plain `reboot` 會觸發 EEPROM bug(manet02 實測 5/10 次走到 partition 1),p1 = 已被 F2b 作廢的 slot A → panic=10 → 再走一次 | m5 |
| **p6 沒掛的開機**(W1 失敗、W0 停住、Wb) | marker 檢查讀到的是 overlay 上的空目錄 → fail-open;p6 的寫者(96 verdict、`LOCKED`、prov-state)寫進 overlay 的掛載點目錄;執行期 `batdata-mount start/restart` 也會跑 W | m9 |
| 每次開機在 S11 ro 掛 p5 讀意圖(新增的開機期 I/O) | 「讀不到」和「沒有」沒有分開;p5 掛載卡住時 S11 沒有逾時(R71) | m7 |
| 降級:`-F` OTA 到不認得意圖的舊 image | 舊 96 會把 p5(前任)的設定還原 → 回到前任的 legacy 節點 | §7(只列後果) |

## 2. MAJOR

### B7-M1 — F3 結果不確定時仍然撤銷;撤銷刪掉哨兵,但意圖可能已經在 p5 上 → 下次開機只清 p6/p5、不清 overlay,p6 資料在使用者以為「已取消」之後消失

**情境**(轉賣前,卡片開始老化):
1. 擁有者在 app 按恢復出廠。F0–F2b 正常。
2. F3:`batman-config-save --reset-intent <nonce> --slot B`。依 §4.3,步驟是:寫 `.factory-reset`(tmp + rename)→ sync → umount → **ro 重掛讀回**,內容相同才 rc 0,**否則 rc 1**。
3. 卡片 rename 成功(意圖已在 p5 上),但 ro 重掛失敗,或讀回內容不符(老化的卡常見:寫進去了,讀回來的不對;或者 sync 時才報 I/O 錯誤),結果 → rc 1。
4. helper 依 §4.5 F3「其他 rc → 撤銷、`E_RESET(p5-unwritable)`,app『設定區寫不進去,請換卡』」。撤銷 = `apps.reset → apps`、刪 SD 標記、**刪哨兵**、刪 marker、啟動 dockerd / guardian / joinwatch。
5. 使用者看到「請換卡」,認為重置沒有發生,繼續用這台(OTS 照跑、任務照記),打算之後把資料搬到新卡。
6. 之後任何一次重開(斷電、手動):S11 `boot()` → 意圖在(格式對、slot 對)→ Wa/Wb 不成立 → **哨兵不在** → 走 W1:mkfs p6 → W2:mkfs p5 → W3。
7. overlay 從頭到尾沒清:`identity/`、`prov.cbor`(claimed,擁有者 = 原主)、`authorized_keys`、shadow 都還在。helper:p5 是空的(rc 7)、overlay 有完整身分 → 依 v4 §3 的 rc 7 規則「補 persist」→ 節點以原擁有者的身分回來,但 **p6 全空**:OTS 的 `docker/volumes/ots-{pgdata,appdata}`、`apps/`、log、crash 都沒了。

**為什麼是 MAJOR**:照文件實作會丟資料(使用者明確重視的任務紀錄,見記憶「任務檢討要還原全部紀錄」),而且是發生在系統剛告訴使用者「沒動」之後。這也直接推翻 v7 的核心不變量「哨兵不在 ⇒ overlay 已清」:這條路上破壞它的,是我們自己的撤銷流程。

**證據**:
- v7 §4.3 `--reset-intent` 的順序(rename 在讀回之前、讀回失敗 → rc 1);§4.5 F3 的失敗欄、「撤銷」一段(含「刪哨兵」);W0/W1 只看哨兵在不在。
- v4 §3:`/etc/batman-prov/identity/` 那一列「overlay 有完整而 p5 無 → **補 persist**,絕不重產」。
- 04 實測 OTS 狀態在 p6:`/opt/batdata/docker/volumes/ots-*`(v6 B 審查已記錄)。
- 現行 `batman-config-save` 寫入模式遇到鎖忙是 `exit 1`(`batman-config-save:136`,`*) err "lock busy…"; exit 1`),只有 `--check` 是 rc 8。所以 rc 1 的意思本來就很雜:鎖忙、前提不符、寫後讀回失敗都是 rc 1(見 m8)。

**修法**(局部,不用新機制):
- `--reset-intent` 的 rc 要分清楚三種:
  - **rc 8** = 確定沒寫(鎖忙、已掛載);
  - **rc 1** = 確定沒寫(前提不符、rw 掛不起、在 rename **之前**就失敗);
  - **新 rc(例如 16)** = 已經 rename、但讀回失敗 = **結果不確定**。
- helper 遇到「不確定」或 crash 後無法判斷時:**不准撤銷**。先用 `--check` / `--prov-get` 重讀一次:
  - 讀得到意圖 → 視為已提交,繼續 F4–F5;
  - 確定讀不到(ro 掛起來、檔案不在)→ 才撤銷;
  - 讀不到也掛不起 → 保持凍結(哨兵、marker、`apps.reset` 都不動),狀態 `resetting-unknown`,app 顯示「重置可能已開始,請勿使用,換卡前先讓節點重開一次完成重置」。
- 不變量寫成規則:**只要 p5 可能有意圖,就不刪哨兵。**撤銷流程的第一步是「確認 p5 沒有意圖」,刪哨兵排在它之後。
- 負對照:白箱 fault seam 讓 `--reset-intent` 在 rename 之後的讀回失敗 → 斷言 (a) helper 沒有撤銷(哨兵、`apps.reset` 都在)、(b) 下一次開機走 W0(清 overlay)而不是直接 W1。照 v7 字面:撤銷、哨兵消失、下次開機 W1/W2 清 p6,overlay 身分被 persist 回 p5。

## 3. MINOR

**m1 — 「哨兵不在 ⇒ overlay 已清」在 overlay 退回 tmpfs 時不成立;「哨兵在、意圖不在」沒有處理,會讓前任的認領復活**
- 證據:fstools `mount_root.c start()`:`FS_NONE` / `FS_DEADCODE` → `ramoverlay()`;f2fs 掛載失敗時 `mount_overlay` 回錯,不會清任何東西。`94-batman-baseline` 的註解記錄過真實事故:「damaged f2fs superblock, so mount_root fell back to a tmpfs overlay ("F2FS-fs (loop0): Failed to read root inode")」。04 實測 overlay = `/overlay type f2fs`,`.fs_state -> 2`(READY)。
- 情境:F4 的 jffs2reset 沒做成(哨兵還在),那次斷電又讓 overlay 掛不起來 → tmpfs overlay → 看起來是 fresh(uci-defaults 會重跑)→ 95 → 哨兵不在 → W1/W2 清掉 p6/p5。之後某次開機 f2fs 又掛得起來 → 哨兵在、意圖不在 → 沒有人處理 → helper rc 7「補 persist」→ 前任的身分與認領寫回 p5,買家無法認領,前任仍保有 owner-op。這需要雙重故障,但後果是「前任在轉賣後仍然控制節點」。
- 修法(PR-P1):
  - (a) W1 的前提加一條:`/overlay` 是持久的 rootdisk 檔案系統(`mount` 顯示 `/overlay` 是 f2fs/ext4,不是 tmpfs,也不是沒有 overlay)。否則 crit `reset-overlay-volatile`、不清、上鎖。
  - (b) 規則:「哨兵在、p5 無意圖、p6 已掛且無 marker」= 重置沒做完 → batdata-mount(或 helper 在任何 persist 之前)清 overlay 並重開,而且**絕不把 overlay 的身分 persist 到 p5**。
  - 負對照:白箱在 overlay 放哨兵、p5 放空的 ext4 → 斷言 helper 不 persist,改清 overlay。

**m2 — helper 啟動時的判斷少一格:marker 在、意圖在、哨兵不在**
- 這格在兩種情況出現:F4 的 jffs2reset 已經刪掉哨兵,但 F5 之前 helper 就 crash(procd respawn);或是 Wa(意圖槽 ≠ 本槽,trial 的 fresh overlay 本來就沒有哨兵)。§4.5 列出的兩格都不符合,實作者只能猜。
- 修法(PR-P1):slot 相符 → 直接 F5(重開,不重做 F4,PENDING 會在下次開機再刪一次);slot 不符 → `resetting`,不重開(交給 m3)。「從 F4 續做」也要先比對 slot。負對照:白箱在 jffs2reset 之後 `kill -9` helper → 斷言 ≤ 30 s 內重開、W1/W2 完成。

**m3 — Wa 靠 `fw_override_check` 修正槽,但 tryboot trial 時它不會動作;autocommit 遇到意圖要不要 commit 沒有定義;Wa 和 Wb 的順序反了**
- 證據:`fw_override_check` 在 `tb != 0` 時直接 `return 0`(95 INITBODY);fresh overlay 時只標 pending,交給 autocommit(`batman-autocommit:307`)。F2b 已經作廢另一槽,所以 EEPROM 開錯槽時會在 kernel 階段 panic,根本跑不到 Wa。實際上 Wa 只會在 trial 遇到:F2b 之後另一槽又被寫過,例如 seam 或旁路。`batman-slot apply` 自己會跑 `precheck → node_checks`(`batman-slot:564`),所以只要 marker / 意圖檢查放在 `node_checks` 裡,直接 apply 也會被擋。
- 後果:如果 autocommit 把那個 trial commit 了,意圖的 slot 就永遠 ≠ committed slot → 每次開機都走 Wa:永遠不清,舊 p6 一直掛著,precheck-node 擋 OTA,provd 在 resetting 只開 status。只能重燒卡。節點是鎖著的,不算開放,但卡住了。
- 修法(PR-P1):autocommit 規則「p5 有意圖 → 這次 trial 一律不 commit(revert)」;`node_checks` 裡要有 marker 檢查和意圖檢查(這樣 apply 和 precheck-node 都會被擋);§4.5 把 Wb 放在 Wa 前面(格式不對就沒有 slot 可以比)。Wa 那一列改寫成實話。

**m4 — W2 被打斷時,96 的上鎖提示其實不存在**
- §4.5:「W2 被打斷:p5 magic 可能不是 ext4 → 96 `:71` → unknown + 上鎖(prov-state 的 last_known_state)」。可是同一次開機 W1 已經 mkfs 了 p6,新的 p6 上沒有 `prov-state`。依 §3「沒有提示 → 今天的 4b」,fresh overlay = image 預設(04 實測 `root:::0`、`PasswordAuth on`)→ 開放。之後節點停在 `unknown(p5-not-ext4)`,也不會產新身分。
- 前任秘密的實際暴露有限:mke2fs 預設會先 discard 整個 p5,而且依 A6-m11 的誠實界線,成功重置後也一樣可以 carve。但文件寫的「上鎖」不成立,這是錯的陳述。
- 修法(PR-P1):W1 成功後,先在**新的** p6 寫 `state/factory-reset.w1 <nonce>`(fsync)再做 W2;96 在 `:71` 或 `:64` 看到這個檔 → 上鎖;W3 完成後刪掉,改寫 `log/factory-reset.log`。下一次開機,如果 p5 不是 ext4 而這個檔還在 → batdata-mount 可以直接重做 W2(A6-m2 提過的可選項,現在成了必要)。不採用的話,就把「開放、需要 bench」照實寫成殘項。

**m5 — F5 與 W0 用 plain `reboot`:在 Pi 4 slot B(04 = L16 的位置)會觸發 EEPROM bug,走到已作廢的 slot A**
- 證據:`batman-slot:744-746` 註解「EEPROM 2026-09-23 may ignore autoboot.txt after a partition-0 restart and walk to partition 1 (5/10 plain reboots on manet02)」;`invalidate_slot`(`:377-386`)讓作廢的槽 panic=10 回預設槽,而 panic 又是一次 partition-0 restart。04 是 slot B(`batman_slot=B`)。
- 後果:每次走錯都多一輪 panic 加重開。boot-reasons 和 pstore 的紀錄會混進這些多出來的開機,L16 的計時也不準。不會丟資料,但 W0 的「最多重開 3 次」實際上會多出幾次。
- 修法(PR-P1):F5 用 `batman-slot reboot committed "factory-reset"`;W0 照 `fw_override_check` 的做法:sync、`mount -o remount,ro /overlay`、`/usr/sbin/batman-reboot <[all]>`、失敗時再退回 `reboot -f`,然後 `return`。v7 寫的「照 fw_override_check 的做法」只講了 return,要把重開的方式也寫明。

**m6 — 「活著的 sysupgrade 程序」是用 `pgrep -f` 比對 cmdline,而 cmdline 任何程序都能偽造(本機非 root 程序、tenant 容器)**
- 證據:`pgrep -f` 比對的是 `/proc/*/cmdline`(04 有 `/usr/bin/pgrep`;`pgrep -f '^/bin/sh /sbin/sysupgrade'` 在 04 回 rc 1、沒有誤中)。容器裡的程序在主機的 `/proc` 也看得到。§4.5 F1 的「沒有 `/sbin/sysupgrade` 程序」用的是同一個判斷。
- 後果:
  - 被入侵的 tenant 或本機程序,只要掛一個 cmdline 是 `/bin/sh /sbin/sysupgrade` 的程序,就能讓**恢復出廠永遠在 F1 被撤銷**。F1 的再查在 F2 停 payload **之前**,所以 tenant 還活著。
  - 同一招配合殘留的 `upgraded`,也能讓 procd 的 validate 寫出 `ota-armed.mesh`。不過因為有 boot_id 和 slot 比對,影響很小。
- 另外,procd 的 validate 是同步的(`system.c:643-699`,`vjson_parse` 會阻塞),sysupgrade 卡在 `ubus call system sysupgrade`(`sysupgrade:425`)等它,所以 v7 的前提「validate 期間 sysupgrade 還活著」✅ 成立。但 `ubus call` 預設 30 s 逾時。04 上兩行 S1 相隔 14 s,所以 Pi 4 沒問題;較慢的板子上,sysupgrade 可能先因逾時離開,這時應該 fail-closed。建議在 `platform_check_image` **一開始**就取樣,不要等到檢查做完。
- 修法(PR-P1):比對條件加上 uid 0、`/proc/<pid>/ns/pid` 與 `/proc/1/ns/pid` 相同(在主機上、不在容器裡)、cmdline 裡的映像路徑等於這次 validate 的 `$1`,而且不帶 `-T/-b/-l`。負對照:非 root 帳號跑一個 `exec -a` 偽造的 sysupgrade → F1 不受影響、validate 不寫檔。

**m7 — 開機期意圖解析器和 p5 讀取的契約不夠**
- 現在每次開機都會在 S11 ro 掛 p5,這是新增的開機期 I/O。之前非 fresh 開機根本不碰 p5。p5 來自實體 SD,不受信任。要寫明:
  - 只接受一般檔案、不接受 symlink/FIFO/device(`[ -f ] && [ ! -L ]`);用 `head -c 65` 讀,超過 64 B 就判壞;絕不 `eval` / source;
  - `nonce` 必須 `^[0-9a-f]{16}$`,`slot` 必須 `^[AB]$`,`attempts` 是 1–2 位數字(避免 ash 算術溢位或吃到注入);
  - 掛載選項 `ro,nosuid,nodev,noexec`,掛在 RUNDIR 的私有目錄;
  - 「讀不到」(掛不起、I/O 錯誤)和「沒有」分開:讀不到時照今天的流程,但要記 crit `reset-intent-unreadable`(理由是 p6 的 marker 和 `apps.reset` 已經擋住 tenant)。
- 一個 FIFO 會讓 S11 永久卡住(R71:開機階段沒有逾時)。只有實體持有者能放得進去,但成本是零。

**m8 — 文件內部不一致(實作時會照錯的那一份做)**
- §3 的意圖格式有 `slot=`,§4.3 的 p5 版面(`"reset v=1 nonce=<hex16> attempts=<n>"`)沒有。`--reset-intent <nonce>`(§4.3)和 F3 的 `--reset-intent <nonce> --slot <slot>` 不同。照 §4.3 實作,寫出來的意圖會被共用解析器判成壞意圖 → Wb → 永遠卡住。
- F3 寫的「rc 8(鎖忙)」與 §4.3「未掛載(rc 8)」不同,也與現行寫入模式「鎖忙 = rc 1」不同(`batman-config-save:136`)。要寫進 M1 的 rc 表。
- D34 和 §10 還寫「`BATMAN_FIRSTBOOT=1`」,和 §4.5「不靠 `BATMAN_FIRSTBOOT`」矛盾。D35 還寫「無 blkid」,和 R72 矛盾。§0、§2、§8 還寫「95 mkfs p6、p5」,實際上是 batdata-mount 的 `boot()`。
- §5 L16 還指向「§4.5 v6、(a)–(f)」,L50 沒有連到 (g)(h),(i) 沒有對應的 L 列。
- v5 §6.4 的 `expected_in_mesh()` 讀的是 `prov-state` 的「state」欄。v7 把第 3 欄改成 `last_known_state`,並新增 `verdict`(後面欄位跟著位移),但 §6.4 標「同 v5」,沒有更新。autocommit 會讀錯欄。
- D27 / §6.4 還寫「⇔」。加上 rc、live 程序兩個條件後應改成「⇒」(A6-m5 要的寫法)。

**m9 — p6 沒掛的開機(W1 失敗、W0 停住、Wb)的姿態沒有定義**
- dockerd / guardian / joinwatch 的 marker 檢查讀 `/opt/batdata/state/factory-reset.inprogress`。p6 沒掛時讀到的是 overlay 上的掛載點目錄 → 沒有 marker → fail-open(A6-m8 已經指出,v7 沒有處理)。在 W0 停住的情況,overlay 是舊的,`/etc/init.d/batman-payload-*` 和 rc.d 連結都還在(04:`S99batman-payload-opentakserver`),會試著啟動。images 在 p6 上,所以起不來,但會一直 respawn。
- 96 的 verdict、`LOCKED`、helper 的 `prov-state`、`ble-ok` 都會寫進 overlay 的 `/opt/batdata/state/`。之後 p6 掛上就被蓋住,兩份狀態從此分岔。
- 執行期 `/etc/init.d/batdata-mount start|restart`(`start(){ boot; }`)也會跑 W。在 F3–F5 期間或停住狀態下,操作員或 harness 這樣做就會觸發 W0 / W1。要寫明這是預期行為,或在 W 前加「僅開機時」的判斷。
- 修法(PR-P1):marker 檢查改成「p6 沒掛 → 不啟動」(fail-closed);所有 p6 寫者先確認 `/opt/batdata` 是掛載點,否則改寫 RUNDIR;寫明執行期 restart 的行為。

**m10 — cancel 與正在執行的 F 步驟沒有互斥;F1 遇到殘留的 `upgraded` 時 app 給什麼訊息**
- A6-m9 的殘項:helper 是否單執行緒處理 F0–F5 與 cancel 沒有寫(例如 F2b 正在 `invalidate-other` 時收到 cancel)。要寫明:單執行緒,或靠 marker 的 flock。
- F1 的再查遇到本次開機中止過的 OTA 留下的 `$RAM_ROOT/sbin/upgraded` → 撤銷。要給 `E_PRECOND(ota-residue)`,app 顯示「請先重開機」,不要給籠統的錯誤。

**m11 — 誠實界線補兩項**
- `31_dropbear_persistent_storage`(每次 fresh overlay 都會跑,04 `/rom/etc/uci-defaults`)會用 `persistent_vars_storage.sh READ dropbear_authorized_keys` 讀 **EEPROM bootloader_config**。如果有值,就寫進 `authorized_keys`。恢復出廠不清 EEPROM。前任若曾以 root 用 `rpi-eeprom-config` 寫入這個鍵,重置之後仍保有 SSH。現行工具在 bcm2711 上不能寫(`WRITE … isn't implemented on bcm2711`),所以這只是殘留風險。§4.5 的誠實界線加一行,並在 L16 斷言 `vcgencmd bootloader_config | grep dropbear` 是空的。
- F4 之後到 F5 之間:overlay 已清,`ttylogin` 回到 rom 預設。serial console 在這幾秒內不要密碼(dropbear 是用啟動時的旗標執行,不受影響)。只有實體接觸才能利用,寫一行即可。

## 4. v6 發現 → v7 核對(一條一行)

| v6 | 判定 | 說明 |
|---|---|---|
| A6-m1 trial 槽 / sysupgrade 空窗 | partial | slot 記進意圖 ✅、F1 再查 ✅;Wa 對 tryboot 的說法錯,autocommit 遇到意圖的規則沒寫(m3);再查可被偽造(m6) |
| A6-m2 attempts / 95 再跑 | addressed | 正面哨兵 + 寫不進就停;tmpfs overlay 的例外見 m1 |
| A6-m3 helper F3 後 crash | partial | 少「哨兵不在」那一格(m2) |
| A6-m4 prov-state 語意 | addressed | 拆欄、兩個寫者同規則;v5 §6.4 讀錯欄見 m8 |
| A6-m5 procd validate 殘留 / rc | addressed | rc=0 + live 程序;D27 仍寫 ⇔、比對可偽造(m6、m8) |
| A6-m6 意圖時不上鎖 | addressed | W2 被打斷的例外見 m4 |
| A6-m7 守門 / 3b / 「只有」 | addressed | INITBODY 自帶、`return`、PARTNAME、mkfs 參數、跳過 3/3b、「只有」已改寫 |
| A6-m8 reboot 非同步 / 紀錄 | partial | `return` ✅、`factory-reset.log` ✅;重開方式(m5)、執行期 restart、p6 未掛的 fail-open(m9)沒寫 |
| A6-m9 `mv -T` / 時段 / 鎖忙 | partial | `mv -T` ✅、時段一致 ✅;rc 8 和現行 rc 1 對不上(m8/M1);cancel 互斥沒寫(m10) |
| A6-m10 app 契約 / 連線佔用 | addressed | 契約已寫;「殺掉 app 再 replay」的 L 測試要進 S5 |
| A6-m11 殘留資料 | addressed | 誠實界線已寫;EEPROM 那一項見 m11 |
| A6-m12 R72 / §8 / 三寫者 | partial | R72 ✅、§8 ✅、§3 依時段列 ✅;D35 還寫「無 blkid」(m8) |
| B6-M1 W0 判準 / 無上限 / 掛舊 p6 | addressed | 哨兵、寫不進就停、不掛舊 p6;但撤銷會破壞哨兵語意(M1),tmpfs overlay 見 m1 |
| B6-M2 resetting 不上鎖 | addressed | 96 有意圖就鎖;W2 被打斷的例外見 m4 |
| B6-m1 95 對舊 p6 跑 3/3b | addressed | |
| B6-m2 守門不在 INITBODY | addressed | |
| B6-m3 W0 重開競態 | partial | `return` ✅;重開方式見 m5 |
| B6-m4 壞意圖讀者不一致 | addressed | 共用 `reset-intent.sh`;解析器的強度要求見 m7 |
| B6-m5 F3 rc 對應 | partial | rc 8 重試 ✅;rc 定義和現行程式碼不一致,而且 rc 1 混了「已寫」的情況(M1、m8) |
| B6-m6 §6.4 rc / stale upg | addressed | 偽造見 m6 |
| B6-m7 psk_replay app 契約 | addressed | |
| B6-m8 prov-state 兩寫者 | addressed | |
| B6-m9 resetting-pending 動詞 | addressed | |
| B6-m10 負對照 (e) | addressed | |
| B6-m11 p6 壞不能重置 | addressed | |

## 5. 指定重點逐項

- **「哨兵在 ⇔ overlay 沒清」**:
  - F4 做到一半:✅。`jffs2reset.c jffs2_reset()` 在 `overlay_delete` **之前** `fs_state_set(PENDING)`,下次開機 `overlay.c:451` 會再刪一次;volume 找不到時什麼都沒做,哨兵還在,走 W0。
  - PENDING 第二輪:✅,F4 之後別的服務寫進 overlay 的非 dot 檔也會被刪。dot 檔不會(R43);F4 之後新寫的 dot 檔會留下,內容不是身分,可以接受。
  - 另一槽 fresh trial:靠 Wa 先擋 ✅(m3 要修說法和 autocommit)。
  - helper 在 F4 之後又寫 overlay:被 PENDING 處理 ✅。
  - **不成立的兩條**:撤銷刪了哨兵、意圖卻可能在(M1);tmpfs overlay(m1)。
- **W0 讀回**:規格夠(寫不進就停、不重開、不掛舊 p6)✅。寫的方式要 tmp + rename + sync + 讀回,與 config-save 一致(實作)。
- **Wa slot 不符 + `fw_override_check`**:見 m3。
- **Wb 壞意圖**:不清、不掛 p6、上鎖 ✅;順序要在 Wa 之前(m3);解析器強度(m7)。
- **95 略過 3/3b**:✅。另外,95 如果在步驟 4 之前就 exit 0(例如 `:86` 認不出 data 分割),fresh overlay 上就沒有 `batdata-mount` init,W 永遠不會再跑。節點會停在上鎖的 resetting,是 fail-closed。前置條件已要求 `PARTNAME=data`,所以實際上碰不到,寫一行即可。
- **INITBODY 守門用 `return`**:✅,`return` = 不掛 p6,和「不掛舊 p6」一致。
- **96 有意圖就上鎖**:fresh overlay ✅。非 fresh 的開機 96 不會跑,鎖的狀態沿用上一次 fresh 開機,而那次 96 已經鎖了 ✅。W0 停住時用的是舊 overlay 的姿態:claimed/member 本來就鎖著;legacy 節點用 SD 標記觸發時是開放的,但這和今天一樣,不是退步。§1.4 的 resetting 列要補這句。
- **helper restart 續做 F4**:見 m2;另外要先比對 slot。
- **F3 rc 8 重試**:見 M1、m8。
- **§6.4 ota-armed + live sysupgrade**:我對了原始碼。`sysupgrade:403` TEST exit → `:406 install_bin` → `:425 ubus call system sysupgrade`,同步;procd `system.c:792` 在 handler 裡 validate,`:825` 之後才 exec upgraded;`validate_firmware_image_call` 會阻塞,等 pipe 回應。所以 validate 期間 sysupgrade 確實還活著 ✅。04 ota-trace:每次 OTA 都有兩行(`caller=/bin/sh /sbin/sysupgrade … upg=n` → 14 s 後 `caller=/sbin/procd upg=y`),`-F` 那次 procd 是 `rc=1`。偽造與 ubus 逾時見 m6。
- **prov-state 拆欄**:§3 ✅;v5 §6.4 讀錯欄(m8)。

## 6. 逐 actor

- **BLE 路人 / 只看過 QR 的人**:本輪沒有變化(psk_replay、§8 界線)✅。
- **本機非 root 程序**:p6 `state/`、`apps/` 是 root 0755,建不了 marker ✅;`/etc` 寫不進,種不了哨兵 ✅;**可以偽造 sysupgrade 的 cmdline**,讓重置做不了(m6)。
- **被入侵的 tenant 容器**:同 m6。容器裡的程序在主機的 pgrep 看得到,而 F1 的再查在停 payload 之前。
- **被入侵的 provd**:發不出 F0 或 cancel(要 owner-op)✅;碰不到 overlay 或哨兵 ✅。
- **前任擁有者**:成功路徑全清 ✅;M1 的路徑會讓 overlay 留下;m1 的雙重故障可能讓認領復活;EEPROM 的 authorized_keys 見 m11。
- **實體 SD**:寫一個格式正確的意圖 = 觸發清除,等同重燒卡,已寫明 ✅;FIFO / symlink 意圖會讓 S11 卡死(m7)。
- **供應鏈**:沒有新的依賴(mkfs.ext4、jffs2reset、flock、hexdump 都在 image 裡,04 實測)。
- **我們自己**:M1(撤銷破壞不變量)、m8(文件互相矛盾,實作一定會照錯的那份做)、m5(L16 在 04 上會多出 panic 開機,干擾判讀)。

**PR-P1 必要條件**:M1 + m1、m2、m3、m4、m5、m6、m7、m8、m9。m10、m11 可以在實作時一併補。

## 7. 使用者決策的後果(不重開,只列)

- U4 全清含身分:F3 結果不確定時,M1 的修法會讓「請換卡」改成「節點必須先重開一次完成重置」。也就是說,卡片在換掉之前會被清掉。如果使用者想先把 p6 的資料搬走,就要在**按恢復出廠之前**先備份。app 文字要寫明。
- U3 與 SSH 脫鉤:重置完成的 unclaimed 節點是 image 預設(空密碼 root)。m4 的 W2 被打斷也落在同樣的姿態,這點要照實寫。
- `-F`:D27 的 rc=0 條件代表 `-F` 的 OTA 永遠不寫 `ota-armed.mesh` → member 節點在家單獨 `-F` 升級會 fail-closed(要求鄰居 → revert)。另外,`-F` 降級到不認得意圖的舊 image,會把前任的 p5 設定還原。這是操作員自己的選擇,說明書寫一行。
- Q5(L16 在 04):04 是 slot B,F5 / W0 的 plain reboot 有一半機率走到已作廢的 slot A(m5)。排 L16 之前,先把重開方式改成 explicit。
- Q6(04 已裝 lab 公鑰):L16 之後 overlay 清空,lab key 會跟著消失,而且 EEPROM 裡沒有 `dropbear_authorized_keys`(m11 的斷言)。還原步驟照 §12 Q5 經乙太網用空密碼重裝,與這點一致 ✅。

## 8. 本輪唯讀探針(原始輸出摘要)

- 04 `ota-trace.log`:
  - `20250714-182059 … S1 CHECK rc=1 caller=/bin/sh /sbin/sysupgrade -F -n … upg=n` → `182104 … rc=1 caller=/sbin/procd … upg=y`;
  - `20250714-221004 rc=0 caller=/bin/sh /sbin/sysupgrade -n … upg=n` → `221018 rc=0 caller=/sbin/procd … upg=y`;
  - `20250715-025609` → `025623`,同樣的格式。
- 04 `mount`:`/mmcblk0p4 on /overlay type f2fs (rw,…,nodiscard,…)`、`overlayfs:/overlay on / type overlay (…upperdir=/overlay/upper…)`;`readlink /overlay/.fs_state` = `2`(READY)。
- 04 `command -v`:pgrep、jffs2reset、mkfs.ext4、flock、hexdump、sgdisk、blkid、fsync、readlink 都有;`timeout`、`stat` MISSING;`/sbin/reboot -> ../bin/busybox`;`pgrep -f "^/bin/sh /sbin/sysupgrade"` → rc=1。
- 04:`batman-slot active` = B;cmdline `… panic=10 root=PARTUUID=…0004 batman_slot=B`;`/sys/class/block/mmcblk0p5/uevent PARTNAME=config`、`p6 PARTNAME=data`;`/etc/shadow root:::0`;`dropbear PasswordAuth=on`;`/etc/batman-prov` 不存在;RUNDIR 裡沒有 `ramroot/`;rc.d 有 `S95done`(PENDING → READY 的時間點)、`S99batman-payload-opentakserver`。
- 04 `/rom/etc/uci-defaults`:`31_dropbear_persistent_storage` 讀 EEPROM 的 `dropbear_authorized_keys`;`persistent_vars_storage.sh` WRITE「isn't implemented on bcm2711」;`94-batman-baseline` 記錄 tmpfs overlay 事故;ttyd `enable=0`、`command=/bin/login`。
- firmware:
  - `jffs2reset.c jffs2_reset()`:掛載中 → `fs_state_set(PENDING)` → `overlay_delete` → remount;
  - `overlay.c mount_overlay()`:UNKNOWN / PENDING → `overlay_delete(…, true)`;
  - `mount_root.c start()`:FS_NONE / DEADCODE → `ramoverlay()`;`done()` → READY;
  - `sysupgrade:370,403,406,425`;
  - procd `system.c:643-699`(同步 fork + pipe)、`:792`、`:825`;
  - `etc/init.d/boot:14` `( . "./$file" ) && rm -f "$file"`。
- Batman 原始碼:
  - 95 INITBODY `boot()`、`fw_override_check`(`tb != 0 → return 0`;uci-defaults 還在 → pending);
  - `batman-slot:84-96` slot_lock、`:377-386` invalidate_slot、`:561-564` apply → precheck → node_checks、`:744-779` cmd_reboot;
  - `batman-config-save:118-142`(寫入模式鎖忙 = exit 1;`--check` = 8);
  - `platform-ab.sh` platform_check_image 的 caller/upg、`_ab_ramroot_guard`。
