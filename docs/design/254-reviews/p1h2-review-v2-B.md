# 審查 B 第 2 輪 — `254-p1-impl.md` v2(PR-P1 + PR-H2)

審查者 B(獨立)。審整份 v2,對照上層 `254-stage1-impl.md` v19(md5 989ae66a…,= main f1a1122)、main 原始碼、02 / 04 唯讀實查,以及我在 WSL 對自建的 loop 檔做的一個實驗(沒有碰 repo,也沒有碰節點)。沒有印任何私鑰、密碼或 mesh key;公鑰只比對指紋。

**判定:REJECT** — 0 BLOCKER / 11 MAJOR / 15 MINOR。

v2 的大方向是對的。第 1 輪的 B1–B3 在原則上都解掉了:新槽類測項改到 04、整份快照、隨機金鑰、dirty 標記、`-wbox`。但還原(`restore`)的斷言照寫是做不到的,而且它沒處理「在 trial 裡」「測試把槽 commit 掉了」這兩種情況。有好幾個負對照在正確和錯誤的程式上結果一樣。joinwatch 會在一個 tick 內把 p5 重新 seed,firstboot 和 gate 兩個測項的前提因此被破壞。§5.4 的「p5 身分優先」是一條新的產品規則,會在沒有擁有者授權的情況下把 claimed 降成 unclaimed / legacy。provclient 的放置路徑照樣會 EACCES(第 1 輪的發現沒有解掉)。

---

## 0. 本輪自己驗證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | `/tmp/run/batman-dv` 是 `drwx------ root`;`/tmp/run` 是 0755 | 04 `ls -ld`(本輪) |
| V2 | ext4 只要 **rw 掛載再卸載**(不寫任何檔),整個映像的 sha 就會變;`ro` 或 `ro,noload` 掛載不會變 | WSL loop 檔實驗:`after-write=5917ca08… after-rw-mount-no-write=46b38ee4… after-ro-noload=46b38ee4… after-ro=46b38ee4…` |
| V3 | `--on-join` 的 fp 快取在 `$RUNDIR/cfgsave-onjoin.state`(tmpfs)。重開後第一次 JOINED tick 一定會 **rw 掛 p5**;p5 沒有 `.seeded` 也照寫,最後寫 `.seeded` | `batman-config-save:64,204-236,397`;`joinwatch:145` |
| V4 | `batman-slot apply` 寫完會 **arm tryboot**;`reboot committed` 看到 tryboot 已 arm 就退回 plain reboot → 進 trial | `batman-slot:682-704`、`:759,767` |
| V5 | hold-commit:trial 不會 commit,deadline 照樣 revert;健康時 log 記 `HELD`,不健康時記 `UNHEALTHY first_why` | `batman-autocommit:259-290,470-480` |
| V6 | p5 `overrides.uci` 帶 `wireless.radio1.channel`;fresh 槽由 Lane B 與 `99-batman-chanfix` 把頻道改回 p5 的值 | `batman-config-save` PRESERVE(`:35`)、`99-batman-chanfix:19-40`、96 `:131-142` |
| V7 | wsl.9 的 96:有可用 key **且**有 crypt hash → LOCKED,而且 `ttylogin=1` | `96:162-172` |
| V8 | `halow-setkey` 每次都會 `uci commit wireless` + `wifi reload`,不管值有沒有變 | `halow-setkey:99-101` |
| V9 | 02:slot A committed、eth0 carrier 0、`/dev/watchdog` 由 procd 餵(timeout 30 s)、`kernel.panic=3`;joinwatch 在未入網 3600 s 後會自動重開一次(`reboot_helps` 時) | 02 唯讀;`joinwatch:19-20,151-171` |
| V10 | 兩台今天的 harness 登入方式是 **`none`(空密碼)**。兩台的 `authorized_keys` 都只有 1 行,指紋 = Git Bash 的 `id_ed25519`;`PreferredAuthentications=publickey` 兩台都 `keyok` | `ssh -v`(本輪)。WSL 端的 key 未驗 |
| V11 | 96 直接讀 `/proc/cmdline`(`:63`)、寫 `/dev/kmsg`、用 `hexdump` 讀裝置、呼叫 `dropbearkey`、`uci` | `96:24-28,63,70,118,141` |
| V12 | 這台 WSL 目前**沒有** `qemu-aarch64` binfmt(只有 WSLInterop / llvm / python3.12),也沒有 `qemu-aarch64-static`;有 `unsquashfs`、loop 裝置、go1.22 | WSL `ls /proc/sys/fs/binfmt_misc` |
| V13 | 每個槽的版本由 95 寫在 p6 `state/slot-<X>.protected`;`apply` 寫入目標槽時先刪掉它 | `95-batman-storage:717`、`batman-slot:432-433`;兩台都有這兩個檔 |
| V14 | p5 = 1048576 sectors(512 MiB);04 p6 剩 19 G;p6 另有 H1 的 `dv-prevboot` | 04 唯讀 |
| V15 | keyguard 只寫 syslog / kmsg,不寫 p6 | `halow-keyguard:17` |
| V16 | 上層 §4.2 rc 0 列:overlay identity 缺 → **從 p5 還原**(helper 自己補) | 上層 §4.2 表 |

---

## MAJOR

### M1. provclient 的目錄 provd 進不去(第 1 輪 A-M1 / B-M2 前半沒有解掉)
- **情境**:§4.3 把 provclient 放在 `/tmp/run/batman-dv/pc-<run_id>/`(0711)。可是父目錄 `/tmp/run/batman-dv` 是 root **0700**(V1),provd 連走過去都不行,`start-stop-daemon -c provd` exec 一定 EACCES。結果是 `prov-sock-254`(tier A,每天跑)每天 FAIL,或者實作的人順手把 `batman-dv` 改成 0711,這就動到了 H1 tmp-trust 的前提。
- **修法**:放在 `/tmp/run` 底下的獨立目錄(例如 `/tmp/run/batman-dv-pc.<run_id>/`,root 0711,`/tmp/run` 本身是 0755),tmp-trust allowlist 加這條;或者經 H1 tmp-trust 審查後明確把 `batman-dv` 改成 0711。負測試照 §4.3。

### M2. `restore` 的「p5 逐位元組 == 快照」做不到,每次都會 FAIL
- **情境**:§4.5 的順序是 `dd` 寫回 → `reboot committed` →(另一槽重新 OTA)→ **斷言 p5 逐位元組 == 快照**。重開之後,joinwatch 第一次 JOINED tick 就會 rw 掛 p5(V3,fp 快取在 tmpfs、重開就沒了),而 ext4 只要 rw 掛載一次,映像 sha 就變了(V2)。「另一槽重新 OTA」那一次 trial 開機也一樣會掛。所以這個斷言在正確的還原上也必然 FAIL,dirty 標記永遠刪不掉。最可能的後果是實作時悄悄放寬,而沒有人審過放寬成什麼。
- **修法**:`dd` 之後、重開之前,以 uncached 讀回比對映像 sha。重開之後改比**檔案層**的清單:p5 掛 `ro` 後,對每個檔(含 `.seeded`、`shadow-root`、`overrides.uci`、`lkg/`、`identity/**`、`prov.*`)的路徑、權限、sha 做清單,與快照時用同樣方法做出的清單比對。§4.5 的負對照(只還原 overlay → FAIL)照留。

### M3. `restore` 沒處理「現在在 trial 裡」和「測試把別的槽 commit 了」;「另一槽重新 OTA」沒有定義
1. **在 trial 裡執行 `restore`**:dirty 標記接手(§5、§7.1)時節點可能還在 held trial(firstboot、bypass、trial-busy、lock-failsecure 都在 B 上)。照 §4.5 的順序,overlay 檔會還原到 **B 的** overlay;`reboot committed` 回到 A,A 的 overlay 沒有還原。A 的 helper `--boot` 看到 overlay gen > p5 gen,依上層 §4.4 第 7 步「以 overlay 為準重新 `--prov-only`」→ **restore 自己把 claimed / member 寫回 p5**(就是 B3 的復活,這次由還原工具觸發)。斷言會 FAIL,所以不會靜默,但節點卡在 dirty。**修法**:`restore` 第一步斷言 `is-trial`=1 且 `active` == 快照的槽;不符就 `back_to_a`(H1 N3 的條件式),等開機之後再做。
2. **測試改了 committed 槽**:(7) team OTA 正常會 commit B;§5.3 (9) 第二段「helper 持續死(`-wbox`)→ 只 WARN → commit」等於預期把 **`-wbox` commit 掉**;M7(c) 的改頻道 `-wbox` 實際上不會離網,所以也可能被 commit。這時 `reboot committed` 開進的是 `-wbox`,「另一槽重新 OTA」覆蓋的反而是原本好的槽。**修法**:`restore` 斷言 committed 槽的版本 == 快照版本,且不含 `-wbox`;不符 → 先處理槽(另一槽寫受測 image、rollback),再做其他步驟。§5.3 的每一列都要寫明預期的最終 committed 槽。
3. **「另一槽重新 OTA」本身就是一次 trial 開機**(V4:apply 一定 arm tryboot)。這次開機要不要 hold?會不會 commit?「需要時」指什麼時候?都沒寫。這次 trial 會在另一槽的 overlay 寫出 `/etc/batman-prov`(96 抄 prov、helper 寫),並 rw 掛 p5(和 M2 同一個問題)。**修法**:寫成固定程序:hold-commit = 受測版本 → trial 斷言 → `back_to_a`;並定「需要時」= 該槽的 overlay 被測試寫過,或該槽的版本 ≠ 受測版本。
4. **overlay 還原要「整個目錄取代」**:`/etc/batman-prov/` 裡的 `.txn`、`.stage/`、`ssh_keys.added`,以及 `/etc/.batman-prov-restore`、`authorized_keys` 多出的行,如果用「複製覆蓋」(config-save `:391` 的 `cp -a` 就是這種,不刪多出來的檔),殘留的 `.txn` 會在下一次開機觸發對帳。另外,快照清單漏了 p6 的 `prov-counters`(§5.2 新增)、`autocommit-hold-commit`、`autocommit-hold-once`。**修法**:整個目錄取代、多出來的檔先印出再刪;清單補齊;斷言也比對 overlay 的這些路徑。

### M4. preflight P9「另一槽 overlay 沒有 `/etc/batman-prov`」在每次 `restore` 之後、以及 P1 出貨後的正常機隊上都會 FAIL
- **情境**:P1 出貨後,每一次正常 OTA 之後,舊槽的 overlay 都會有 legacy 的 `/etc/batman-prov`(那個槽跑過 P1 helper)。M3 第 3 點的重新 OTA trial 也會寫出它。所以 P9 會擋掉幾乎每一次 run。
- **修法**:把判斷改成檢查真正的風險:另一槽 overlay 的 `prov.meta` state ∈ {沒有, legacy},**且** identity 的 `sn` == p5 的 `sn`,**且** gen ≤ p5 gen。讀不到 → FAIL。另一槽的版本可以直接讀 p6 `slot-<X>.protected`(V13),不必為了版本去掛 f2fs;但要處理 `apply` 會刪掉這個檔的情況(缺 → 不可判 → FAIL)。

### M5. joinwatch 的 `--on-join` 會在一個 tick 內重新 seed p5,破壞 firstboot 與 gate 的前提;L1 的核心斷言只是「加分」
- **firstboot**:§5.4 第 1 步先 `snap`(結束時會重新啟動 joinwatch),第 2 步 `mkfs` p5,然後 OTA。A 是 JOINED 的,joinwatch 每個 tick 都跑 `--on-join`,而 `--on-join` 對未 seed 的 p5 照寫,最後寫 `.seeded`(V3)。只要 OTA 前過了一個 tick(poll 15 s),p5 就又是 seeded 的:#202 閘不擋、B 的 96 走正常還原 → 根本不是 firstboot。P1 和 wsl.9 都會「AP 開著」,負對照也就沒有鑑別力。
- **gate**(`prov-gate-254`):接在 firstboot 之後,要從 A 送 `sysupgrade -n`(trial 裡 `apply` 會被拒,`batman-slot:523`)。revert 回 A 之後,A 的 joinwatch 在 harness 連得上之前就可能已經 seed 了 p5 → 閘在 **wsl.9 也不擋** → 測項在正確和錯誤的程式上都 PASS。
- **L1**:「`iw dev` 沒有 AP 介面」是上層 L1 的核心斷言,但 §5.4 第 3 步只把它當 trial 中的加分,p6 上沒有任何東西記錄 AP 狀態。「keyguard 的 log 行」也不在 p6(V15)。
- **修法**:從 `mkfs` 到 OTA reboot 這段期間停掉 joinwatch(在 lease 的還原清單裡);gate 測項在 A 開機後先斷言 p5 仍然沒有 `.seeded`(有 → 測項作廢,不算 PASS),或者需要一個 p6 一次性旗標讓 joinwatch 在這次開機不 seed(產品 seam,要列契約)。L1 的「沒有 AP」必須是硬性斷言:§9 第 2 步先實證 trial 中連得到(注意 fresh 位址是 `10.41.254.x`,它的網段遮罩與主機路由要先查);連不到就 FAIL,不算加分。keyguard 證據改看 pstore(`console-ramoops`)或者拿掉這一條。

### M6. §5.4 第 6 點「p5 身分優先」是一條新的產品狀態轉換,而且是 fail-open
- **對 committed 槽 A 的後果**:A 是非 fresh 的,overlay 的 claimed / member(身分 X)整份丟掉,換成 p5 的 unclaimed / legacy(身分 Y)。沒有 owner-op、沒有 `network.leave`,節點的擁有權就被降級了。helper 把 `prov-state` 的 `last_known_state` 更新成 unclaimed / legacy → **96 在「讀不到 p5」時靠的 p6 上鎖提示(上層 §4.3)也跟著消失**。另外 99zz 只在 fresh 槽跑,所以 A 會是「unclaimed 但 AP 開著」,和上層 L1 / L60「unclaimed 沒有 AP」的不變式不一致。P2 之後,unclaimed = 任何人都能經 BLE 認領。
- **現場觸發(不只測試)**:claimed 節點 → 操作員 `batman-config-save --seed --reformat`(p5 修復路徑,`config-save:109-183`,prov 被清掉)→ 沒重開就 OTA → fresh B:rc 9 + overlay 沒有 identity → 產生 `prov{legacy}` Y → 之後 rollback / revert 到 A → 依「p5 優先」,A 從 claimed 變成 legacy。
- **修法**:上層定案之前,P1 一律做 fail-closed 的 `unknown(identity-mismatch)`:不改狀態、不改鎖定欄位、不 persist、`--check` 報 stale 擋 OTA、`halow-status` 顯示、log。測試用的 `restore` 本來就會處理這個狀態,所以 §5.4 不需要這條規則。§10 第 1 點改成「建議 fail-closed,請上層 / 使用者定案」,並把上面這個現場觸發寫進去。

### M7. 有四類負對照在錯誤的程式上也不會 FAIL
- **(a) 「`-wbox` 96 不抄 prov」**(`prov-ota`、`prov-overlay-wipe`):96 不抄,helper `--boot` 會看到「rc 0 + overlay identity 缺 → 從 p5 還原」(V16),最後 gen / state / `device_id` 都是對的 → mutant 測不出來。要嘛斷言 96 那一刻的證據(`/etc/.batman-prov-restore` 的 verdict、helper log 寫「overlay 已有 prov(96)」與「從 p5 還原」的差別),要嘛換一個 mutant(例如 helper 的「從 p5 還原」壞掉)。
- **(b) `prov-lock-failsecure` 的「舊版 = 不上鎖」**:認領會把 root 密碼 hash `--save` 進 p5 `shadow-root`(上層 §6.1 第 4 步),04 又有 lab key → wsl.9 的 96 也會 LOCKED,而且 `ttylogin=1`(V7)。所以舊版負對照也是「上鎖」。要有鑑別力,前提必須是 legacy 4b 不會上鎖的狀態:p5 `prov.meta=claimed` 但沒有 `shadow-root`(例如 killpoint 打在 §6.1 第 3、4 步之間,也就是第 1 輪 B-m9 提的「`--save` 失敗」真實狀態)→ wsl.9 判 UNPROVISIONED、P1 鎖。
- **(c) 「改頻道 `-wbox`」**((4)、(7) / L40):member 的頻道在 p5 `overrides.uci` 裡,fresh 槽的 Lane B 和 `99-chanfix` 會把它改回去(V6)→ trial 照樣入網 → 應該 revert 卻 commit(還會把 `-wbox` commit 掉,見 M3 第 2 點)。`-wbox` 必須在 chanfix **之後**改頻道(例如晚於 chanfix 的一次性 init),並先實證 trial 確實離網。上層 L40 的寫法有同樣的問題,回報上層。
- **(d) 以 bind mount 做開機路徑的 mutant**:bind mount 重開就消失,也到不了 fresh 槽(§4.6 自己這樣寫)。可是 §5.3 把 bind mount 指派給開機路徑:`prov-legacy-upgrade`(rc 9 發生在 OTA 後 B 的第一次開機)、`prov-overlay-corrupt`(gen 比對在 `--boot`)、`prov-misc` 的 L38 / L42 / L43 / L51(autocommit 在 trial 開機時決策)。這些都要用 `-wbox`;或者先證明 helper 重啟會重跑 `--boot` 的對帳,在同一槽上用「改狀態 + bind mount + 重啟 helper」做(要寫明,並實證)。

### M8. autocommit 測項與 hold-commit 的關係沒定;(2) 沒有可行的程序
- 用 hold:每個 trial 最後都 revert(V5),所以「revert」類的結果((1)(4)(5)(6))沒有鑑別力,除非判讀改看 `HELD` 對 `UNHEALTHY first_why`。不用 hold:「commit」類((2)(3)(8)(9))會真的把受測 image 或 `-wbox` commit 掉。
- **(2) claimed + placeholder**:要 unclaimed 才認領得到 placeholder 狀態,而 trial 上認領會回 `E_BUSY`(上層 §4.1)。所以 04 必須先 **commit 一個 unclaimed 的 fresh 槽**(mesh 被 keyguard 關、AP 被 placeholder 關,只剩 eth),再認領,再 OTA。設計完全沒寫,而這正是只有 04 能做、而且要明列副作用的步驟。
- **修法**:每一列寫明:hold 或不 hold、判讀的 log 字串、預期最終 committed 槽、以及怎麼回到快照的槽。(2) 寫出完整程序與副作用(04 committed 在沒有 mesh 的槽的那段時間,OTS 中斷)。

### M9. `prov-legacy-upgrade-254` 仍然不能重複跑(第 1 輪 B-M6 沒解)
- **情境**:「前置由 `snap` 的還原映像保證」不成立:`snap` 是在每個測項開始時拍「現在」的 p5。P1 出貨後,p5 已經有 legacy prov(rc 9 產生的),拍不出「p5 沒有 prov」的快照。「committed 在 wsl.9」也要先 OTA 降級。降級後 p5 的 prov 檔還在(wsl.9 不刪)→ 再 OTA 到 P1 走的是 rc 0,不是 rc 9。
- **修法**:定一個 harness 的「移除 p5 prov」步驟(在 `cfgsave.lock` 內、helper 停止、`ro` 驗證後只刪 `prov.*` 與 `identity/prov/`,在 §3 列為測試例外寫者),前置程序寫成:降級 OTA(或 rollback 到舊版槽)→ 移除 p5 prov → 斷言 `--prov-get` 不存在(wsl.9 上可以用 `ro` 掛載看)→ OTA P1 rc → helper log `rc=9`。舊版 payload 要釘死(版本 + sha)。

### M10. 離線 rootfs 沙箱:測的是哪一份程式碼沒定;qemu-user 未實證;cmdline 接縫沒定;產品接縫多餘
- **測哪一份**:§2.2 說從「受測 image 的 squashfs」解出 rootfs。可是 P1 PR 的 CI 跑的是 PR 的 shell 改動,那些改動還不在任何 image 裡。Batman CI 也沒有地方拿到 firmware image。結果不是測舊碼,就是永遠 expected-fail。**修法**:定成「基底 rootfs(釘版本 + sha,從哪裡下載要寫)+ 把 PR tree 的 `feed/batman-provision/files` 與 helper(PR tree 以 `prov_test` build)疊上去」。§6 三個時期依此改寫。
- **未實證**:這台 WSL 現在沒有 qemu-aarch64 binfmt(V12)。「busybox ash 在 chroot 裡跑 96 / config-save、helper exec config-save(binfmt 要 F 旗標)、經 qemu-user 呼叫 mount(2)」都沒有證據。§9 第 2 步的實證清單要加這一項(在 WSL 與 CI 各跑一次 96 的正常出口)。
- **cmdline**:96 與 config-save 直接讀 `/proc/cmdline`(V11),`:64` bypass 出口要在沙箱裡 bind mount 一個假檔蓋在 chroot 的 `/proc/cmdline` 上。沒寫的話「每個出口」做不到。
- **產品接縫**:在 `unshare -m` chroot 裡,可以直接把 loop 裝置的節點做成 `/dev/mmcblk0p5`,所以 `BATMAN_P5_DEV/MNT` 不需要放進 release 程式碼。而且白名單 `/dev/loop[0-9]+` 在節點上包含 `/dev/loop0` = **overlay 的 f2fs**(04 `/proc/mounts`)。「我們自己的錯」加上 `--seed --reformat` = mkfs 掉 overlay。**修法**:拿掉這個接縫;一定要留的話,拒絕任何已經被掛載的 loop 裝置,並且要求 `/dev/mmcblk0p5` 不存在。

### M11. P-U3 的動詞有幾個沒有任何測項;與上層 §10 的切法衝突沒有回報
- 沒有測項的:`root_password.reset`(新密碼 → shadow → `--save`、只回一次)、`diag.bundle`(fd O_RDONLY、讀完刪)、`owner.add/remove`、`settings.set`(包含 hostname 嗎?上層 L23 rename ⚠️ 探針還沒做,#202 兩次實證改 hostname 會讓 openmanetd 重保留 IP 並重開)、`psks.get` 的內容(不得含 `owner_tag_key` / `net_root`)、`info.counter`。§5.1 的「每項:拿掉該檢查的 mutant」是籠統的說法,不是測項。
- 上層 §10:認領 / 鎖定 / `ssh_keys` / `root_password` 屬 P2,建網 / 加入 / 診斷 / 離開 / 改名屬 P3。P-U3 改成全部放 P1 是使用者的決定,但 §10 沒有列出來回報上層。
- **修法**:一張「動詞 → 測項(正向 + 拿掉檢查就 FAIL 的 mutant)」表;`settings.set` 在 P1 明確只開哪些 key,不含 hostname(或等 U5 探針);§10 加一點。

---

## MINOR

- **m1** `prov-downgrade-254` 預期「`ttylogin=0`(fail-open)」和程式碼矛盾:04 有 key,認領後有 `shadow-root` → wsl.9 96 判 LOCKED 並設 `ttylogin=1`(V7)。上層 L12 的 fail-open 只針對「沒有 key、有密碼」。斷言改正;要測 fail-open,另做沒有 key 的情境。
- **m2** §4.4「雙台用 fleet 實際值 → wireless 不變 → 不會失聯」不成立:`net.apply` 第 2 步 `halow-setkey --no-persist` 每次都 `wifi reload`(V8),02 的 wlh0 會被拆掉重建,而 Morse churn 下的 panic / hang 是已知問題(#132)。02 的恢復路徑(V9):hw watchdog 30 s、`panic=3`、joinwatch 在未入網 3600 s 後自動重開。要寫進 §7.2,並且順序上 04 先做、確認無誤才做 02。
- **m3** 單台網路測項期間 02 會累積 unjoined episode,未入網超過 3600 s 時 joinwatch 會讓 02 自動重開一次(V9)。列進 §7.2;單次 lease 的時間上限要低於這個值,或者接受並記錄。
- **m4** owner-op / COSE 的簽章在哪裡做沒寫。`nonce_helper` 是一次性的、60 s 內有效,所以簽章要嘛在主機上(要一個 node ↔ host 的往返中繼),要嘛擁有者私鑰放到節點上(§4.3 的目錄檔案是 0755,provd 讀得到,和 §3「節點上只出現公鑰」矛盾)。選一種寫進契約;雙台測項的 fleet mesh key 若在主機上加密,就會到主機上,canary 清單要含它。
- **m5** `restore` 的 `dd` 要以 `setsid` 在節點端執行,撐過 ssh 斷線;讀回用 uncached;快照的 sha 同時記在主機上,不能只放在映像旁邊(同一個目錄裡,兩者可以一起被改)。
- **m6** bind mount 在「harness 死了但沒重開」時會一直留著(一支拿掉檢查的 root helper)。§3 / §7.1 要寫明 deadman 的還原動作包含 `umount` + 重啟 helper。另外 §5 寫「下一次 acquire 執行 restore」,§7.1 寫「P9 FAIL 並印 restore 指令」,兩處矛盾,選一個。
- **m7** fresh trial 的連線:`99-halow-identity` 給的是 `10.41.254.x`,遮罩與回程路由沒查;主機從 `10.41.x.y/16` 不一定連得到。併入 M5 的實證。
- **m8** P9 讀另一槽版本用 p6 `slot-<X>.protected` 就可以(V13);`apply` 會先刪掉它 → 缺 = 不可判 = FAIL。
- **m9** build gate 用 `--root` 字串掃描 Go 二進位會誤判(stdlib 或其他字串裡可能也有)。改成 `prov_test` tag 才會編進去的唯一標記字串。provd uid 471 改在組好的 rootfs 斷言 `/etc/passwd` 與 `/etc/group`,不要依賴 postinst 失敗(opkg 在建 image 時 postinst 失敗不一定讓 build 失敗)。
- **m10** 今天兩台都以 `none` 登入(V10)。認領之後只剩 key。Git Bash 的 key 已驗過;WSL 端的跑法(ab-card 等)沒驗。preflight 在認領 02 之前斷言「每個 runner 以 `PreferredAuthentications=publickey` 都登得進兩台」。
- **m11** `halow-status` 顯示 dirty 標記是產品改動,§2.1 沒有列;依「測項只能有一套」規則要明寫歸屬。
- **m12** 「發行清單與轉賣工具清單拒收 `-wbox`」沒有實作元件也沒有測項(轉賣工具在 P3 才有)。`-wbox` payload 在主機上的存放位置與清理也沒寫。
- **m13** `prov-netupdate` 的 mutant「`-wbox` `--on-join` 不讓路」:`--on-join` 是執行期的行為,用 bind mount 就可以,不需要 `-wbox`。而且 `--on-join` 依契約從不寫 prov,所以不可能讓「p5 gen 前進」;斷言改成 overrides 不前進。
- **m14** `prov-sock` 的「補充群組 provd」要改 `/etc/group`,等於在 tier A 寫節點。改用 `start-stop-daemon -c nobody:provd`(主群組),或者寫明做法。
- **m15** 開頭說有「§5 對照表」,但沒有一張逐列的「上層列 → 測項 / 不在 P1 + 理由」表。我對過之後,缺的有:L9 / L10 的 helper 那一側(bluetoothd / dbus 重啟後 health 與 D-Bus 重連)、`sysupgrade -b` 實際 tar 不含 `etc/batman-prov` 的黑箱測試(現在只有 keep.d 的靜態檢查)、M11 的動詞。另外 `:89` 的注入寫「loop 不可讀」,但 root 什麼都讀得到。要寫成「magic 正確、superblock 其他欄位壞掉」。`ALLOW_MIXED_FLEET` 是 H1 preflight 的改動,要列進 §2.2。

---

## 第 1 輪發現的狀態

| 第 1 輪 | 狀態 |
|---|---|
| B-B1 / A-B1 新槽類在 02 | ✅ 改到 04、hold、覆寫只開一次。⚠️ 新問題見 M5(joinwatch 重新 seed)、M8 |
| B-B2 / A-B2 還原不完整、公開金鑰 | ✅ 隨機金鑰、整份快照、兩台的順序。⚠️ 斷言與槽的處理見 M2、M3 |
| B-B3 另一槽復活 | ⚠️ 方向對(重新 OTA),但沒有定義,而且和 P9 衝突(M3 第 3 點、M4);identity 不一致的規則見 M6 |
| B-M1 / A-M4 白箱契約 | ✅ tmpfs bind mount 與 `-wbox`。❌ 開機路徑仍然指派 bind mount(M7(d)) |
| B-M2 / A-M1 秘密與放置 | ✅ stdin、sha 前 8 碼、canary。❌ 放置路徑仍 EACCES(M1);簽章位置(m4) |
| B-M3 / A-M5 鑑別力 | ⚠️ 大多補上;新的無鑑別力項目見 M7 |
| B-M4 / A-M8 PR 順序、三個時期 | ⚠️ 補上;沙箱測哪份程式碼沒定(M10) |
| B-M5 / A-M6 缺測項 | ⚠️ 大多補上;動詞(M11)、(2)(M8)、m15 |
| B-M6 legacy-upgrade 重複跑 | ❌ 未解(M9) |
| B-M7 只用假的測 | ⚠️ 沙箱方向對,未實證(M10) |
| A-M2 第二寫者 | ✅ §3 例外 + 鎖;p6 / overlay 的例外寫者也要列(M3 第 4 點) |
| A-M3 lease 撐不過重開 | ✅ dirty 標記;M3 第 1 點、m6 |
| A-M7 tier A 改狀態 | ✅ |
| A-M9 ble-ok × UART | ✅ P-U5 |
| A-M10 生命週期 | ⚠️ 補上;02 的副作用(m2、m3) |
| 第 1 輪 MINOR | 大多處理完。B-m4 / A-m1 的接縫:loop 白名單在節點上包含 overlay(M10);B-m9:由沙箱涵蓋 ✅ |

## 其他確認成立(✅)
- F3 / F4 / F6 / F8 / F9 / F10 / F14 / F16 與原始碼和節點一致;04 overlay = f2fs on loop0 ✅;02 沒有 eth、有 core_freq_min(p1)✅。
- hold-commit 的語意(不 commit、deadline 照樣 revert)支持 §5.4 把 04 當成會自動回來的路 ✅(V5)。
- 02 只在雙台測項被動到;我沒找到會讓 02 **永久**失聯的路徑:fleet 值不變,02 有 watchdog 與 joinwatch 自動重開,trial 也有 revert。但 02 的 wifi reload 風險要寫明(m2)。
- `-wbox` 的 payload 可以裝:OTA 只驗 SHA256SUMS,沒有簽章(`platform-ab.sh:12,122,295`)。這也代表 `-wbox` 跟正式 payload 在節點上分不出來,只能靠版本字串(m12)。

## 判定
**REJECT**(0 BLOCKER / 11 MAJOR / 15 MINOR)。沒有找到會讓 02 永久失聯、或讓機隊留在公開金鑰上的路徑,這比 v1 好很多。但 `restore` 照寫會每次 FAIL,而且有沒處理的路徑(M2–M4)。M5 和 M7 有幾個測項在對錯兩邊結果相同。M6 是一條 fail-open 的新產品規則。修完請整份重審。
