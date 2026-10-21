# 審查 A 第 2 輪:`254-p1-impl.md` v2(PR-P1 + PR-H2)

審查者 A,2026-10-21。範圍:**整份** v2(不只差異),對照上層 `254-stage1-impl.md` v19、`254-h1-harness.md` v8、Batman main f1a1122 原始碼、firmware-2710 rootfs(cortex-a72)、02 / 04 唯讀實查(只跑讀取指令,沒有印任何金鑰或密碼)。

**判定:REJECT**:0 BLOCKER / 9 MAJOR / 18 MINOR。
v2 的方向是對的:新槽類測項改到 04、用 held trial、證據留 p5 / p6、每次跑的隨機金鑰、白箱用 tmpfs bind mount 和 `-wbox`、dirty 標記撐過重開,這些都解掉了 v1 的 BLOCKER。但「還原」這個核心機制照寫的做不出來:斷言必然 FAIL、還原到哪一個槽沒定、重寫另一槽之後 tryboot 還 armed 著。另外,provclient 的放置路徑仍然進不去(v1 A-M1 沒解),§6 的過渡期在 CI 和 lint 上也做不到。

---

## 0. 本輪我自己查到的證據(唯讀)

| # | 事實 | 證據 |
|---|---|---|
| V1 | `/tmp/run/batman-dv` 在兩台都是 `drwx------ root`;`/tmp/run` 是 `drwxr-xr-x root` | 04 / 02 `ls -ld` |
| V2 | H1 的工具刻意用 0700 建這個目錄:`prov-tools-254.sh:8` `mkdir -m 700 "$H"`;tmp-trust allowlist `:13` 的理由是「created 0700 and owner-checked」 | 讀檔 |
| V3 | 04 的 p5 = 524288 KiB(512 MiB);p6 剩 19 G;**`/overlay` 是 `/dev/loop0`(f2fs)** | `/proc/partitions`、`df`、`/proc/mounts` |
| V4 | config-save `--on-join` 的「沒變就略過」快取放在 `$RUNDIR/cfgsave-onjoin.state`(`:64`,tmpfs,每次開機清空)。所以每次開機後**第一個 JOINED tick 一定以 rw 掛 p5**(`:236`)。`sbstamp()`(`:111`)讀的是 superblock offset 1072 的 `s_wtime` + `s_mnt_count`,每次 rw 掛載都會改 | 讀檔 |
| V5 | `batman-slot apply` 最後 **arm 一次性 tryboot** 並讀回(`:682-704`);`cmd_reboot` 遇到 tryboot 已 armed → 改做 plain reboot(`:759`,「an armed tryboot」)→ 下一次重開就進 trial。CLI 沒有 disarm 指令(`disarm_tryboot` 只在內部用) | 讀檔 |
| V6 | hold-commit:旗標只在 tryboot 開機被消耗,而且只對版本相符的 build 生效;健康的 trial 會一直等 `release`,deadline 到了 watchdog 仍然 revert(`batman-autocommit:259-290,471-475`) | 讀檔 |
| V7 | fresh image:`99-halow-identity` 設 `10.41.254.(rand%253+2)`、`dhcpconfigured=0`,註解寫「openmanetd reserves the real IP after boot and reboots once (#11)」;openmanetd 由 `bat0` 的 interface up trigger 重啟(`init.d/openmanetd`)。`meshpoint-1.8.0:79` netmask /16;主機在 `10.41.240.10/16` → 同一網段可達。keyguard「Ethernet is never touched — it is the door」。fresh dropbear `PasswordAuth on`、`RootPasswordAuth on` | rootfs、`ipconfig` |
| V8 | OTS 的 init stub 在 fresh overlay 由 95 重新產生(`95-batman-storage:569`)→ 不需要靠 restore 還原;04 overlay 的 crontab 有 1 行;tailscaled 沒在跑 | 讀檔、04 |
| V9 | `check-provisioning-sync.sh:42-43`:任一 pair 缺檔就 `FAIL`、rc=1 | 讀檔 |
| V10 | CI(`.github/workflows/*`)沒有任何下載 firmware image 或 release asset 的步驟;firmware 在本機 WSL build | 讀檔 |
| V11 | `validation-known-failures.txt` 的格式是 `suite<TAB>ERE<TAB>issue`,**沒有到期欄位**;`daily-validation.sh` 沒有任何 expiry 處理(grep `expir` = 0) | 讀檔 |
| V12 | preflight P3 對「fleet versions differ」直接 FAIL(`dv-preflight.sh:42`,#290);也擋殘留的 hold-commit 旗標(`:38`) | 讀檔 |
| V13 | OTA payload 不驗簽章(`platform-ab.sh`、`batman-slot` 裡沒有 cosign / usign / sig)→ `-wbox` payload 不需要額外簽章,也不會多出「已簽章的危險 payload」 | grep |
| V14 | 02:wsl.9、slot A committed、`eth0 carrier=0`、state 有 `mesh-expected` / `mesh-joined`;04:wsl.9、slot A committed、netmask 255.255.0.0、`dhcpconfigured=1` | 唯讀實查 |
| V15 | 上層 L40(§6.4 (7)):「A 在 trial 時 B 跑 stage 1,B 的 image 預設頻道改掉 → B revert」 | 上層 `:370` |
| V16 | 上層 §10 第 5 點把 `ssh_keys`、`root_password` 列在 PR-P2;P-U3 則決定 helper 在 P1 就做全部動詞 | 上層 `:528`、本文件 §1.1 |

---

## MAJOR

### M1. provclient 的放置目錄 provd 進不去(v1 A-M1 沒解)
- **情境**:§4.3 放在 `/tmp/run/batman-dv/pc-<run_id>/`(0711)。父目錄 `/tmp/run/batman-dv` 是 root 0700(V1),而且 H1 是刻意這樣建的(V2)。`start-stop-daemon -c provd` 一執行,在路徑解析時就 `EACCES`。實作的人只能把 `batman-dv` 改成 0711,這會打破 tmp-trust allowlist 的前提,和其他共用這個目錄的測項(halow-fi-263、setkey-202、H1 的 `bt/`)。
- **修正**:直接放在 `/tmp/run` 底下的獨立目錄,例如 `/tmp/run/batman-dvpc/<run_id>/`。`/tmp/run` 是 root 0755(V1),非 root 程序沒辦法預先建立這個名字。目錄 0711、檔案 0755,執行前照原本的驗證。allowlist 與 `rundir-paths.txt` 各加一條;負測試照舊。

### M2. restore 的斷言「p5 逐位元組 == 快照」每次都會 FAIL,負對照因此沒有鑑別力
- **情境**:§4.5 的順序是 dd 寫回 p5 → 還原 overlay / p6 → `reboot committed` → 重寫另一槽 → **然後**斷言 p5 逐位元組相同。重開之後,joinwatch 的第一個 JOINED tick 一定會以 rw 掛 p5(快取在 tmpfs,V4)→ superblock 的 `s_wtime` / `s_mnt_count` 改變(這正是 `sbstamp` 讀的欄位)→ 原始映像不再相同。legacy-upgrade 這類測項還會遇到 P1 helper `--boot` 的 rc 9 寫入 prov。結果是 restore 永遠不會通過 → dirty 標記一直留著 → 之後每一次 run 都被 P9 擋下,或者實作的人把斷言放鬆。§4.5 的負對照(只還原 overlay)也會因為同一個原因 FAIL,所以分不出「p5 有沒有還原」。
- 另外,每個 tier B 測項的 snap 加 restore 都是 2 × 512 MiB 的原始讀寫(V3)。
- **修正**:分兩段斷言:(1) dd 之後、任何掛載之前,原始 sha == 快照;(2) 重開之後改成**檔案層級**比對:以 `ro,noload` 掛到私有目錄,把檔名、mode、內容的清單雜湊後,和快照的檔案清單比對(`shadow-root`、`identity/`、`overrides.uci`、`lkg/`、prov 檔,以及「快照裡沒有的檔案也不能有」)。負對照改成在檔案層級判定。可以考慮快照直接存檔案的 tar 加清單,省掉 512 MiB 的 dd。

### M3. restore 要回到哪一個槽沒有定義;測項會 commit 到另一槽,快照的 overlay 檔會被寫進別的槽或別的版本。legacy-upgrade 的前置在 P1 出貨後做不到(v1 B-M6 仍未解)
- **情境**:`prov-legacy-upgrade` 明寫「autocommit 照今天規則 commit」;`prov-ota`、`prov-leave-ota` 是 member 或 claimed 節點 OTA 之後 commit;`prov-downgrade` 是 claimed + 有鄰居的 wsl.9,照舊規則會 commit。只有 `-wbox` 寫明是 held。測完之後 committed 槽已經換了。restore 卻寫「還原 overlay 檔 → `batman-slot reboot committed`」。結果:(a) 快照是在原來那個槽(例如 A、wsl.9)拍的,還原時寫進了新槽(B、P1 或 wsl.9)的 overlay;(b) 下一個測項的前置(版本、槽位)跟著飄掉;(c) downgrade 之後 committed 停在 wsl.9。
- **legacy-upgrade 的前置**:「p5 沒有 prov」靠的是「snap 的還原映像」。但 P1 出貨後(或第一次跑過之後),測項開始時的 p5 已經有 P1 helper 以 rc 9 寫入的 `prov{legacy}`。config-save 也從不刪 p5 上的檔(F4 `:391`)。所以每次跑的快照都**拿不到**沒有 prov 的 p5:斷言 `rc=9` 會 FAIL,前置做不到。
- **修正**:
  1. 快照記下 slot、版本與兩槽的狀態。restore 先回到**快照的那個槽**:目前 committed 槽和快照不同 → `rollback` + `reboot committed`;到了之後才還原檔案,然後重寫另一槽(M4)。
  2. 每個 tier B 測項明寫開始與結束時的基準(例如 A = 受測 image committed、B = 受測 image fresh),以及會不會 commit。不需要 commit 的 OTA 一律 held。
  3. legacy-upgrade 另外定一個**固定的 pre-P1 基準**:從 wsl.9 時期拍一次的 p5 映像(sha 釘住,放主機與 p6),加上釘住的 wsl.9 payload(DV 工具驗 sha)。這個基準只給這一個測項用,寫進擁有權表。

### M4. 「另一槽重新 OTA」的收尾沒有定義:tryboot 留在 armed 狀態;「(需要時)」沒有定義 → v1 B-B3 只解了一部分
- **情境 1**:`batman-slot apply` 最後一定 arm 一次性 tryboot(V5)。restore 在 `reboot committed` **之後**才重寫另一槽,寫完就結束。之後任何一次重開(下一個測項的 `reboot committed` 也會因為 tryboot 已 armed 而退成 plain reboot,`:759`)都會開進 trial;健康就 commit → committed 槽默默換掉,下一個測項在錯的槽上開始。P3 只擋 is-trial 與 hold 旗標,看不到 armed 的 tryboot。
- **情境 2**:「(需要時)」沒有定義。`prov-ota` 之後,舊槽的 overlay 是 member、**身分和 p5 相同**、gen 比還原後的 p5 高。§5.4 第 6 點的規則只管「identity 不同」的情況。這裡 identity 相同,適用的是上層 §4.4 步驟 7「overlay 新 → 以 overlay 為準重新 `--prov-only`」→ 之後 rollback 或 revert 到那個槽,測試擁有者的 member 狀態就會復活(B-B3 原本的情境)。
- **修正**:
  - 「需要」定義為:snap 之後另一槽被寫入或被開機過,就一律重寫(以 `slot-X.protected` 或 boot-reasons 判定)。
  - 重寫後二選一:(a) 以 held trial 開一次,讓它 revert(同時證明 fresh overlay 開得起來);(b) 加一個經過審核的 `batman-slot disarm`(這是產品改動,要說明歸屬)。
  - 收尾斷言:tryboot GET = 0、`is-trial` = 1、兩槽版本都等於基準。P9 也檢查「tryboot 沒有 armed」。

### M5. (7) team OTA 可能讓 02 停在別的頻道:§4.4「雙台 wireless 不變,不會失聯」和 §4.6 / L40 互相矛盾
- **情境**:§4.6 寫 (4)(7) 用「改頻道」的 `-wbox`;上層 L40 是「A 在 trial 時,B 跑 stage 1,B 的 image 改了頻道 → B 應該 revert」(V15)。設計沒有指定哪一台是 B。如果 B = 02,而 P1 有回歸(該 revert 時卻 commit,這正是這個測項要抓的),02 就會 committed 在別的頻道上,而 02 沒有乙太網(V14)。要救只能透過乙太網把 04 調到 02 的頻道,這要靠 `-wbox` 的頻道值和 04 都還正常,設計沒有寫這條路。
- **修正**:角色固定:B(改頻道)= 04,A = 02,02 只會拿到正常的受測 image(02 最壞的結果是 revert,這是安全的方向)。preflight 斷言這個角色分配;寫出「04 誤 commit 到新頻道」時的救援步驟;§4.4 的文字改正。

### M6. 主機 ↔ provclient 的契約沒有定義:誰簽 owner-op、誰加密 `net_secrets`、fleet mesh key 怎麼流,前後互相矛盾
- **情境**:§3 寫「節點上只出現公鑰、簽章、ECDH 加密後的秘密」→ 擁有者私鑰在主機,由主機簽章。但 `nonce_helper` 是一次性、60 s、綁 `h` → provclient 拿 nonce → 交給主機簽 → 送回 → 送出,要一個互動往返,格式、逾時、ssh 中斷時 helper 那條連線怎麼處理都沒寫。§4.4 (7) 寫 fleet 的 mesh key「由 root 在 04 上讀出、經 stdin 交給 provclient、不落地」。可是 `net_secrets` 是要 ECDH 加密給節點的:如果在主機加密,fleet key 就得離開節點;如果在節點加密,就要寫清楚 provclient 自己做加密、主機只簽密文的雜湊。實作的人最省事的做法是把擁有者私鑰放到節點上,這違反 §3。另外,`$DIR/prov-keys/` 0600 放在 Windows / Git Bash(NTFS)上是無效的。
- **修正**:定一個介面:provclient 的 framed stdin / stdout 互動模式。順序是:節點組好請求,以節點自己的 `ecdh_pub` 加密 `net_secrets`(明文由 root 經 stdin 提供)→ 送出 `args_hash` 與 `nonce_helper` → 主機(WSL ext4 上的 0600 金鑰)簽章 → 節點送出請求。fleet key 不離開 04。逾時固定 < 60 s,中斷 = FAIL,並寫明 helper 端的狀態。canary 加入 fleet key 與測試用 mesh key(m13)。

### M7. §6 的過渡期做不到(v1 A-M8 / B-M4 只解了一部分)
- (a) **lint**:H2 先把 `prov-lock.sh`、99zz 加進 PAIRS。`check-provisioning-sync.sh` 遇到缺檔就 FAIL(V9)→ P1 merge 之前,main 的 CI 一直是紅的。`depersonalise.sh` 的安裝清單是產品的安裝程式,不是 harness,不應由 H2 改。
- (b) **CI 沒有 image**:離線沙箱「從受測 image 的 squashfs 解出 rootfs」,但 CI 沒有任何取得 image 的途徑(V10)。所以「expected-fail:找不到受測 image」**在 P1 出貨後仍然永遠成立** = 變相跳過。§2.2 寫的「CI + WSL」實際上只有 WSL。
- (c) **到期日**:known-failures 沒有到期欄位,daily-validation 也沒有處理(V11)。「到期日 = P1 預計出貨 + 14 天」照現在的格式做不到。
- (d) **混合 fleet**:`ALLOW_MIXED_FLEET=1` 等於替 #290 的 P3 閘(V12)開一個例外,要使用者決定;而且要在 harness PR 裡落地,不能在驗證時臨時加。
- **修正**:
  - (a) lint 支援 `pending` 條目(附 issue 與到期日,缺檔時判 PENDING 而不是 PASS,到期轉 FAIL);或依「測項只有一套」的例外,請使用者核准由 P1 加 PAIRS。安裝清單放進 P1。
  - (b) 沙箱的底用釘住的 release rootfs(1.5.11-rel.1 asset,sha 釘住),疊上 repo 的 feed 檔案;helper 在 CI 以 setup-go 從 feed 原始碼編譯。這樣 P1 出貨前後都有真的覆蓋。不這樣做的話,就明寫「CI 不覆蓋、只有 WSL」,並把 WSL 的執行納入出貨閘。
  - (c) H2 一起加上到期欄位與它自己的測試。
  - (d) 列進 §10,問使用者。

### M8. P1 出貨的 root 動詞有幾個完全沒有測項;「§5 對照表」沒有出現(v1 A-M6 / B-M5 只解了一部分)
- **情境**:P-U3 決定 helper 在 P1 就做全部動詞,但 H2 沒有測下面這些:
  - `root_password.reset`:寫 shadow,接著 `--save` → p5 的 `shadow-root` 改變(這是秘密);
  - `diag.bundle`:SCM_RIGHTS 傳 fd、讀完刪;
  - `owner.add` / `owner.remove`:改 owner 與 admins;
  - `settings.set`;
  - `psks.get`:必須只回 HKDF 導出值,不回 `owner_tag_key` / `net_root`;
  - `sign.peer`、`sign.ecdh_proof`:正向語意。

  `prov-unit-auth` 只涵蓋其中幾項的授權負測試。檔頭寫「補齊上層指派給 P1 的測項(§5 對照表)」,但 v2 的 §5 是測項表,沒有「上層列 → 測項」的對照,審查者無法逐列核對覆蓋率。上層 §10 第 5 點又把 `root_password`、`ssh_keys` 放在 P2(V16)。
- **修正**:補上「上層 §4.1 動詞、§5 L 列、§8 負測試 → H2 測項 / H3 / N/A(理由)」的完整對照表。每個在 P1 出貨的動詞至少要有一個正向測試和一個授權負測試;做不到的,就和使用者確認 P-U3,讓那個動詞在 P1 回 `E_UNSUPPORTED`。

### M9. §5.4 新槽流程在 04 上還有執行不下去的地方
- (a) **mkfs 之後 p5 會被重新 seed**:mkfs 到 OTA 重開之間,A 的 joinwatch 每個 JOINED tick 都會跑 `--on-join`(F9),把 A 的設定和 `.seeded` 寫回 p5。trial 看到的就是 seeded 的 p5,不是 rc 7 / `unseeded`。結果是測項 FAIL(不是假 PASS),但流程跑不起來。snap 的「放鎖、啟動 joinwatch」對這個測項要例外:joinwatch 一直停到重開為止,並寫進副作用清單。
- (b) **§9 第 2 步的實證不是唯讀**:「wsl.9 → wsl.9 同流程」要 mkfs 04 的 p5,而那時 `prov-snap` 還不存在。這不是「唯讀或可還原」。**改用 bypass 流程實證**:wsl.9 payload 寫進 B,用 held,B 的 cmdline 加 `batman_bypass=1`。96 一樣在 `:64` 離開,`99-halow-identity` 一樣設 `dhcpconfigured=0`,p5 完全不動。用它觀察 openmanetd 會不會在 trial 裡重開(V7),並先列出副作用清單(使用者 2026-10-18 規則)。
- (c) **以空密碼登入**:harness 以 `BatchMode` 用空密碼的 root 登入,要靠 dropbear 的 blank password(`none` auth)或 sshpass。fresh 的 dropbear 是 `PasswordAuth on`(V7),但空密碼能不能非互動登入 ⚠️ 沒有證實,要列入第 2 步的實證。
- (d) **02 在 trial 期間也連不到**:firstboot 或 bypass 的 trial 裡,04 的 mesh radio 被 keyguard 關掉,02 連不到;§7.2 沒有列。

---

## MINOR

- **m1** `BATMAN_P5_DEV` 的白名單允許 `/dev/loop[0-9]+`,但正式節點的 `/overlay` 就是 `/dev/loop0`(V3)。操作員設錯值 → `--seed --reformat` 的目標變成 overlay。目前大概會因為「已被 f2fs 掛住 → busy」被拒,但 ⚠️ 沒驗證。**修正**:拒絕任何已掛載或正在支撐 `/overlay` 的裝置;loop 裝置只在背後是測試目錄下的 regular file 時才接受。
- **m2** P9 掛另一槽的 f2fs:要用 `losetup -r` 加 `-o ro,norecovery`(避免 roll-forward 寫入另一槽)。另一槽 overlay 不是乾淨卸載的(例如 `reboot -f` 之後),在唯讀 bdev 上會 `EROFS`「Need to recover fsync data」→ P9「讀不到 = FAIL」會誤擋。overlay window 被 `stage-root` 清掉(沒有 f2fs)時,應判「沒有 prov」= PASS,不是讀不到。
- **m3** H1 的 `bt/lease` 和 H2 的 `lease-prov` 都以 04 為目標,而且都會重開 04。在主機鎖之外,兩者沒有互斥。**修正**:各自 acquire 時,都要檢查另一個 lease 是否有效。
- **m4** dirty 標記「由 `halow-status` 顯示」:這是產品改動,但 P1 的 shell 改動清單沒有它;產品讀 harness 的標記也要定歸屬。
- **m5** §7.2 overlay-wipe 寫「還原後斷言 OTS ready、Tailscale、crontab」,但 §4.5 的快照清單沒有 crontab、uhttpd 憑證、`openmanetd.db`。OTS 的 init 會由 95 重建(V8),那一句可以刪;crontab(04 上有 1 行)不會被還原。兩處要一致。
- **m6** restore 要把「快照時不存在」也當成快照的一部分:測試中新建的 `ota-armed.mesh`、`ble-ok`、`prov-state`、`prov-counters`、`.txn`、`/etc/.batman-prov-restore` 要刪掉,並在斷言中確認。
- **m7** 快照的「`dropbear`」是 `/etc/config/dropbear` 還是 `/etc/dropbear/`(host key)沒寫清楚;跨版本還原整個 `/etc/shadow`(wsl.9 的沒有 provd 那一行)的影響也要寫一句。
- **m8** 02 在 P1 上 02 之前,tier A prov-\* 會在 02 一直 FAIL「no helper」;known-failures 的條目要涵蓋這段期間。
- **m9** 負對照欄是「—」的:`prov-unit-seams`(可以用「接受任何值的 mutant」)、`prov-boot3-254`。`prov-downgrade` 沒有能鑑別的負對照,請標明它是 characterization 測試。
- **m10** tier A 的負對照(停 helper、關 privacy、bind mount 換成 mutant)都會改節點狀態 → 寫明它們只在 lease 內、PR 證據階段跑,不是每天跑。
- **m11** build gate 用字串掃 `--root` / `killpoint` 很脆弱;加上 `go version -m` 的 buildinfo `-tags` 檢查(拒絕 `prov_test`)。
- **m12** killpoint 的契約只涵蓋 `state.apply` 的步驟 n;`prov-claim` 需要的「persist 之後、回應之前」不在契約裡。
- **m13** 秘密 canary 的清單沒有 fleet mesh key((7))和每次跑的測試 mesh key。
- **m14** 成本:每個 tier B 測項 2 × 512 MiB 的 dd、1–2 次重開或 OTA,大約 17 個測項 → 好幾個小時的 OTS 中斷,外加 SD 卡磨耗。請估算全套的時間並讓使用者知道(使用者「不要浪費錢與時間」)。
- **m15** §7.1 缺「snap / restore 進行中斷電」:p5 寫到一半 → 下一次開機 rc 10 / 12 → unknown;restore 可以重跑。要寫出這條路徑和它的白箱測試。
- **m16** dirty 標記的接手方式前後不一致:§5 開頭寫 `acquire` 看到就自動 restore,§7.1 寫 P9 FAIL 並印出指令。建議只有同一個 `run_id` 才自動 restore,其他情況印出指令。
- **m17** P2 之後,helper 只有一條連線 → tier A 的 `prov-sock` 每天都得停 provd = 每天一次正式的 BLE 管理中斷。要寫明,或者 P2 之後把 `prov-sock` 移到 tier B。
- **m18** `boards/common` 讓 bcm2710 image 也帶 helper,但完全沒有測。build 樹裡有 cortex-a53 的 rootfs → 至少在它上面跑一次離線沙箱(成本低),PR body 再寫「真機未測」。

---

## v1 發現的狀態

| v1 | 狀態 |
|---|---|
| A-B1 / B-B1(新槽類測項在 02) | ✅ 主要部分已解(改到 04、held、#202 覆寫、證據放 p5 / p6)。殘留:M5((7) 的角色)、M9 |
| A-B2 / B-B2(網路金鑰、還原) | ⚠️ 隨機金鑰、04 單台已解;還原機制出現新的問題(M2、M3) |
| B-B3(另一槽復活) | ⚠️ 一部分(M4) |
| A-M1(provclient 權限) | ❌ 仍未解(M1) |
| A-M2 / B-m14(第二個寫者) | ✅ |
| A-M3(lease 撐不過重開) | ✅(dirty 標記);m4、m16 |
| A-M4 / B-M1(白箱契約) | ✅;m11、m12 |
| A-M5 / B-M3(鑑別力) | ✅ 大致已解;M2(restore 的負對照)、m9 |
| A-M6 / B-M5(缺測項) | ⚠️ M8 |
| A-M7(tier A 改狀態) | ✅;m10 |
| A-M8 / B-M4(PR 順序) | ⚠️ M7 |
| A-M9(ble-ok × UART) | ✅(P-U5) |
| A-M10(生命週期) | ✅ 大致已解;m15 |
| B-M6(legacy-upgrade 重複跑) | ❌ M3 |
| B-M7(真的 busybox / config-save) | ✅ 設計上已解;CI 實際上跑不到(M7b) |
| 各項 MINOR(rc.button、99zz、rm、uid、(9) 改定、P9、lint 清單、三種 caller、L2 / L3) | ✅;lint 清單見 M7a |

## 我確認成立的部分
- 04 的 fresh trial 經乙太網連得到:br-ahwlan /16,主機在同一網段(V7)。
- hold-commit 的語意符合 §5.4 的用法(V6)。
- `-wbox` 不需要簽章(V13)。
- 99zz 的排序(F14)。
- F3–F11 與原始碼相符。

## 判定
**REJECT**。沒有 BLOCKER,v2 的整體架構可以保留。但 M2–M4(還原機制)照寫做不出來,而且會讓節點的槽位與 overlay 靜默飄掉;M1、M7 會讓實作卡住,或者逼實作的人去改 H1 / #290 的規則;M5、M6 涉及 02 的可達性和秘密的流向。修完後請對整份文件再審一次。
