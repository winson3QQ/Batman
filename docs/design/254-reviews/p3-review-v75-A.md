# 254-p3-impl v7.5(01d7803)審查 A — S5 軟體更新(整份重審)

審查者 A(正確性優先)。2026-11-11。只讀:`/home/yello/Batman-p3`@01d7803、`/home/yello/firmware-2710`@02f0913d、Go toolchain 原始碼;沒有改任何 repo、沒有 ssh 到節點。
範圍:§3.7、§3.8、§3.11、§12(含 §12.5)、附錄 E / F / G,以及它們用到的 §3.1 / §4 / §5 / §6 / §7 / §8 / §10 / §11 / 附錄 D 列。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 15 MINOR。**

- v7.4 的三個 MAJOR(A10-MAJOR-1/2/3)都**真的關了**,而且兩個是拿掉機制;我逐一對過原始碼(§1)。
- 新的 MAJOR 不是 v7.5 的改動造成的,是 `write` 動詞從 v7.2 起就有的漏項,這輪整份重讀才看到:**`write` 的步驟清單沒有 `clear_root`(清 overlay 窗)**,也沒有 `precheck` 的其他項目。照字面實作的話,同一版本退回後重裝,新槽會**沿用上一次試用留下的 overlay**:p5 還原與 uci-defaults 都不會再跑,而且不會報任何錯(MAJOR-1)。修法是一句話加一個測試。
- MINOR 主要三類:v7.5 新規則的邊角(m1–m6)、應拿掉的機制(m7)、A10 沒完全收掉的文字矛盾(m8–m13)。

---

## 0. 我自己核對過的事實

| 項目 | 結果 | 證據 |
|---|---|---|
| Go 的 `Unshareflags & CLONE_NEWNS` 會在子行程把 `/` 設成 `MS_REC\|MS_PRIVATE` | ✅ | go1.26.4 `syscall/exec_linux.go:473-478`(`~/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.26.4…`);go1.22 是 `:463-464`,行為相同 |
| 節點上的 helper 是 go1.26.4 編的 | ✅ | `go version build_dir/target-aarch64_cortex-a53_musl/root-bcm27xx/usr/bin/batman-provhelper` → `go1.26.4`(firmware 的 `feeds/packages/lang/golang` 寫 1.23.12,但 build 實際用 `build_dir/hostpkg/go-1.26.4`) |
| `provstore.Exec` = Setpgid、逾時 TERM → 10 s → KILL 整個 group;helper 本身死掉時子行程**不會**被殺(它在別的 group) | ✅ | `provstore/exec.go`(全文) |
| `tboot_open` 現在會重用 `/proc/mounts` 裡**任何**一個目標分割的掛載;`begin_write` 的順序是 disarm → `tboot_open` → invalidate | ✅ | `batman-slot:409-417`、`:423-436` |
| **串流路徑的 `clear_root` 只在 `stage-root` 做**;`cmd_apply` 只在 payload 自帶 `root.squashfs` 時才 `clear_root` | ✅ | `batman-slot:644`、`:650-657`、`:666-671` |
| `precheck` 除了 `node_checks` 之外還做:寫 `.busy`、**刪 `autocommit-skip-once`**、EEPROM 警告、Pi 3 韌體允許清單、**squashfs + 64 MiB 放得進目標槽** | ✅ | `batman-slot:592-641` |
| fstools 找 overlay 的位置 = `round_up(squashfs bytes_used, 64 KiB)`;那個位置**已經有檔案系統就直接用** | ✅ | firmware `build_dir/…/fstools-2024.07.14~408c2cc4/libfstools/rootdisk.c:18,120-122,136` |
| autocommit.log 的行格式 = `YYYYmmdd-HHMMSS <KEYWORD> boot=<8> slot=<A\|B> version=<全串> …`;時間戳是一欄;95 的 FW-OVERRIDE 行用同一個 `ts` | ✅ | `batman-autocommit:65,239,554,568`;`95-batman-storage:379,460-483` |
| 沒有東西輪替或截斷 autocommit.log | ✅ | 全 repo grep(只有 halow-status、bundle、harness 讀) |
| `batman-slot commit` 失敗時 autocommit 重置 dwell 後重試,不會退回 | ✅ | `batman-autocommit:553-557` |
| autocommit 現在仍用 cmdline 子字串判斷 `slot_writer_alive`,`.busy` 只看存在 | ✅ | `batman-autocommit:79-86,226` |
| helper 已經有 5 s 的 `is-trial` 快取(status 第 6 / 7 列可用,不必在請求路徑跑子程序) | ✅ | `cmd/batman-provhelper/trial.go`、`main.go:613-627` |
| provd 每 4 s poll helper 一次 | ✅ | `provd/server.go:20`(`PollEvery = 4 * time.Second`) |
| CI 的出貨路徑:`build-release.yml` 的每個 job 都 `uses: build-firmware.yml`;stamp 在 `:137`;prov-test gate 在「Stamp in rootfs」步驟(`:229`),對解出的 `witness-root` 跑 | ✅ | firmware `.github/workflows/*.yml` |
| CI 的通道來自**追蹤中的** `batman-release.env`(現在 `BATMAN_CHANNEL=wsl`);stamp 只檢查非空(`:23-24`) | ✅ | `git ls-files batman-release.env`;stamp `:22-24` |
| stamp 的 DIRTY 檢查在寫檔**之前**;`.gitignore` 現在只忽略 `files/etc/batman-build` 與 witness | ✅ | stamp `:38-44`;`.gitignore:38-40` |
| `tests/keys/T.pub` = 130 hex + 換行(131 B) | ✅ | `wc -c` |
| `docs/VERSIONS.md:14`:出貨版去掉後綴;stamp 一律加 `-$CH.$N` | ✅(repo 裡本來就不一致,設計已寫明兩種都收) | `VERSIONS.md:14`;stamp `:57` |
| `92-batman-ramoops-fix` 只改**執行中槽**的 `distroconfig.txt`;不在 `/boot` 上的話用 `mktemp -d` 以 rw 掛,之後卸載 | ✅ | `92-batman-ramoops-fix:14-40` |
| tryboot 旗標斷電後就消失(PM 暫存器) | ⚠️ 推論(Pi 公開行為,未在本節點量) | — |
| F75 / F76 / §9-4(AP client 通過、VLAN 臂)、`bootinfo` 實際耗時、`-F` stage 2 遇到殘留掛載、兩遍解壓實際秒數 | ⚠️ NEEDS-NODE | 本次不能上機 |

---

## 1. v7.4 的發現:真的關了嗎

| v7.4 發現 | v7.5 | 判定 |
|---|---|---|
| A10-MAJOR-1 PUT 綁 HTTP session 的 IP | 拿掉;bearer 是唯一憑證 | ✅ §3.8.2、§7、§12.5「PUT 不綁 IP」都一致。殘留:§3.8.2「BLE 或**同一個 HTTP session**」是舊文字 → m11 |
| A10-MAJOR-2 argv[1] 規則 | 只看 `<pid> <starttime>` | ✅ 拿掉 uid 也對:檔案在 root 0700 的 RunDir,只有 root 寫得到;pid 在同一個 10 ms tick 內被重用不實際。殘留:zombie → m6 |
| A10-MAJOR-3 CI 沒有 gate | 獨立 `check-release-key-gate.sh`,`build-board.sh` 與 `build-firmware.yml` 都呼叫 | ✅ 位置對(和 `check-prov-test-gate.sh witness-root` 同一步);§12.5 有 CI 負對照 |
| A10-m1 重試 / tick 阻塞 | TryLock;最多每 10 分鐘重試 | ✅;rc 14 的 10 分鐘太久 → m5 |
| A10-m2 快取的鍵 | 整份 manifest bytes | ✅ |
| A10-m3 `armed` | 拿掉;arm 前寫 `apply_boot_id` | ✅;新的邊角 → m1、m2 |
| A10-m4 aclog | 欄位整個相等 | ✅ 和實際行格式相符(§0) |
| A10-m5 worker rc 14 | 同一個 fd 重試 3 次 | ✅;沒有負對照 → m14 |
| A10-m6 pending / bulk.open 呼叫者 | `updMu`;§5.1 | ⚠️ §3.8.2 沒寫呼叫者檢查(§12 說「實作只看 §3」)→ m10 |
| A10-m7 bearer 擁有者 | helper 產生、poll 交付 | ✅;poll 延遲 → m3 |
| A10-m8 apply 前提 | 看槽 | ✅ |
| A10-m9 reason 18 文字 | 改正 | ✅ |
| A10-m10 92 | §3.7.1 key 8、§4 | ✅;沒有測試 → m14 |
| A10-m11 `.gitignore` | §3.7.2 | ✅ |
| A10-m12 D12 / 過渡版 | D12 已照決定 | ⚠️ 過渡版的通道與版本沒寫 → m13 |
| A10-m13 stdin | 只有 dd 讀 stdin | ✅ |
| A10-m14 phase 1 位元組 | provd 經 poll 回報 | ✅ |
| A10-m15 刪除規則三個版本 | §3.8.2、§4 | ❌ 仍然三個版本 → m8 |
| A10-m16 p6 壞 | §6 | ✅ |
| A10-m17 其他段落矛盾 | 大部分改了 | ⚠️ §3.1-5 的 `updating` 起點沒改、§10 清單不完整 → m9、m12 |
| B10-m2 垃圾 rootfs | 第一遍只驗不寫 | ✅ 對外部攻擊者成立;被入侵的 provd 例外 → m4 |
| B10-m11 殘留掛載 | mount namespace | ✅ 原始碼成立(§0);適用範圍要寫清楚 → m15 |
| B10-m14 `slot_is_bad` | §11 | ✅ |

---

## 2. MAJOR

### MAJOR-1 `write` 的步驟清單漏了 `clear_root`(與 `precheck` 的其他項目)→ 同版本重裝會沿用舊 overlay

**情境(現場會發生)**:v2 經 app 裝進 B → 試用不健康 → 退回 A(status 6)。擁有者修好原因(例如 mesh 恢復了)後**重試同一份 v2**,這是 §3.7.1 明文允許的「相等 = 重裝」,§8 也有「同版本重試又退回」的測項。B 的 rootfs 分割上,squashfs 後面還留著第一次試用建立的 f2fs overlay。
§3.7.3 定義的 `write` = `node_checks → begin_write → dd → 複製 boot 檔 → 讀回 → …`。這裡沒有 `clear_root`。現行程式在串流路徑上只有 `stage-root` 會清 overlay 窗(`batman-slot:650-657`);`cmd_apply` 只在 payload 自帶 `root.squashfs` 時才清(`:666-668`)。新的 squashfs 和舊的完全相同,所以 overlay 的位置 `round_up(bytes_used, 64 KiB)` 也相同,fstools 看到那裡有檔案系統就直接用(`rootdisk.c:120-136`)。結果:
- 第二次試用開機時,overlay 不是新的 → uci-defaults 不跑 → **96 不會從 p5 還原、92 不跑**(F71);
- `/etc/config/*`、`/etc/batman-prov/*` 都是第一次試用當時的內容。如果之後 p5 變過(加了擁有者、換了網路、改了國家),新槽跑的是**舊設定 / 舊 prov 紀錄**。後果有兩種:試用因為 mesh / 身分不符被退回;或者被 commit,之後出現「p5 stale: prov-identity」,所有 OTA 都被拒;
- 不會有任何錯誤訊息:讀回只驗 squashfs 的 `SQ_BYTES`(`:694`),overlay 不在驗證範圍內。

另外,`write` 的清單也沒有 `precheck` 的其他項目(`:592-641`):
- 寫 `.busy`(§3.7.3 另外有提到);
- **刪 `autocommit-skip-once`**:沒刪的話,ab-selftest 留下的 token 會讓 app 的試用「不 commit 也不退回」;
- 「squashfs + 64 MiB 放得進目標槽」(worker 只檢查 ≤ 目標槽,沒有算 64 MiB 的 overlay 窗);
- Pi 3 韌體允許清單(bcm2710 只編譯,但檔案兩板共用)。

**證據**:§3.7.3 `write` 列(引 `:592-714`,但步驟清單本身沒有這些項目);`batman-slot:592-657,666-671`;fstools `rootdisk.c:18,120-122,136`。§8 / §12.5 沒有任何測項檢查新槽的 overlay 是新的。

**為什麼是 MAJOR**:這是現場真的會走的路徑(退回後重試同版本),後果是安靜地開進舊設定,還可能把 OTA 永久鎖死;設計是 H4 的契約,而契約裡的步驟清單漏了這一步。

**修法(不加機制,照抄 `stage-root`)**:§3.7.3 `write` 改成 `slot_lock → precheck(含 .busy、刪 skip-once、大小、Pi 3 清單)→ begin_write → clear_root(SQ_MB + 64 MiB,SQ_BYTES 來自 metadata size=)→ 從 stdin dd → …`,也就是「`stage-root` + 串流 + `apply` 去掉 arm」。§12.5 加一列負對照:先裝 v2 再退回,重裝同一份 v2 → 第二次試用的 overlay 是新的(例如:第一次試用在 overlay 留一個標記檔,第二次試用時不在;或者 96 的 log 又出現一次)。負對照:`write` 不做 `clear_root` → 標記檔還在。

---

## 3. MINOR

**m1 啟動時的 disarm 會取消操作員之後手動做的 arm。** 情境:app 的 `update.apply` 先寫 `{apply_boot_id = 本次, rebooting: false}`,arm 回 rc 14 或 15 → 失敗(什麼都沒 arm)。同一次開機裡,操作員 ssh `batman-slot apply` 並打算自己重開;接著 helper 因為任何原因重啟(crash、`/etc/init.d/batman-provhelper restart`)→ 條件「`apply_boot_id` = 本次且沒有 `rebooting`」成立 → 操作員的 arm 被 disarm。§3.7.4 說「操作員手動 `apply` 等自己重開時不被取消」,§12.5 的負對照只測了「之前沒有失敗的 app apply」那一種。**修法(不加欄位)**:arm 回非 0 時,helper 先 `disarm`,再把 `apply_boot_id` 清掉(helper 活著、知道結果);啟動時的 disarm 成功之後,也把 `apply_boot_id` 清掉,避免同一次開機每次 respawn 都 disarm 一次。負對照:arm 失敗 → 操作員 apply → 重啟 helper → 旗標仍是 1。

**m2 「回應後 2 s 才寫 `rebooting: true`」留下一個沒必要的窗。** arm 成功到寫 `rebooting` 之間有 2 s。如果這段時間節點被別的東西重開(joinwatch 的 `reboot committed`、看門狗、操作員),而試用在 kernel 就 panic 了(沒有 TRIAL-REVERTED 行),回到 from_slot 後第 8 列沒有 `rebooting` → 往下走 → 第 10 列報 **0 + 23**,實際應該是 6 + 18。**修法**:arm 回 0 就立刻寫 `rebooting: true`,然後才回應、等 2 s、重開。helper 在這段 crash 的話:啟動時不 disarm,節點維持已 arm;status 第 4 列 = 3,app 可以再 apply。這是擁有者同意過的版本,可以接受。

**m3 bearer 經 poll 交給 provd,最多延遲 4 s;provd 也要等 poll 才知道要 bind。** 正常流程是 BLE `bulk/open` → 手機加入 AP → PUT。如果手機本來就連在這台 AP 上,PUT 可能比 provd 的下一次 poll 早到,得到 TCP 拒絕或 409「窗沒開」。這時 status 第 1 列說窗開著,§3.11-12 的「409 → 依 status 判斷」沒有出路。**修法(擇一、不加機制)**:§3.11-12 寫明「`bulk/open` 之後 10 s 內的連線拒絕或 409 一律重試(間隔 1 s)」;或者 helper 的 `bulk.open` 回應要等到 provd 下一次 poll 收到 bearer 之後才回(較複雜,不建議)。

**m4 「第一遍只驗不寫」對被入侵的 provd 不成立。** unlink 只擋住**新的** open;provd 在 PUT 時開的寫入 fd 仍然指向同一個 inode。被入侵的 provd 可以留著那個 fd,在第一遍驗完之後、第二遍讀之前改內容。結果:第二遍寫進去的是垃圾 → 讀回不符 → 槽 BAD → 退路被毀。誠實 provd 不會這樣:它是循序寫到 `Content-Length` 就關檔,寫過的位置不會再改,所以 §7「同 AP 抓 bearer 的人」那一列的結論仍然成立。**修法**:§7「被入侵的 provd」加一列「兩遍之間改 inode → 毀退路(DoS),誠實界線」;§3.7.5-6 寫明第二遍要重跑與第一遍相同的 header / 白名單檢查(不能假設和第一遍相同)。不建議為此加機制(複製一份需要 2 倍 RAM)。

**m5 helper 重啟時,如果前一個 helper 的 `batman-slot write` 還在跑(孤兒),啟動時的 `bootinfo` 會拿到 rc 14,之後最多 10 分鐘 status 都報 0(沒有更新)。** helper 死掉時 `write` 子行程不會被殺(它在別的 group,§0);它讀到 stdin EOF 後讀回失敗並 invalidate,大約需要數十秒。在這段時間裡,新 helper 的槽快取是「讀不到」→ 第 9 / 10 列不成立 → 第 11 列報 0。app 顯示「沒有更新」,使用者可能以為什麼都沒發生。另外,孤兒還在用 `/tmp/run/batman/update/boot/`,新的 worker 用 `O_EXCL` 建這個目錄會失敗,失敗碼沒有定義。**修法**:rc 14 改成 60 s 後重讀(rc 18 / 輸出壞掉維持 10 分鐘);boot 目錄被持鎖的孤兒占用時 → worker 回 rc 14 的對應(`E_BUSY`,可重試)。

**m6 持有者規則要把 zombie 當成死掉。** 持有者被 KILL 之後到 parent 收屍之前,`/proc/<pid>/stat` 還在、starttime 相同,但狀態是 `Z`(第 3 欄)。parent 是 harness 的 shell、而且正在阻塞的話,這段時間會很長 → rc 14。**修法**:同一次讀取順便看第 3 欄,`Z` = 死掉(一個條件,不是新機制)。

**m7(拿掉機制)update-last 的 `attempt_boot_id` 沒有任何讀者。** 判讀表第 1–11 列與啟動時的 disarm 只用 `apply_boot_id`。拿掉這個欄位(§3.7.4、§5.3)。

**m8 上傳檔的刪除時機仍有三個版本(A10-m15 沒關)。**
- §3.8.2:worker、`bulk.close`、窗到期(沒有 worker)、helper 啟動;
- §4 清理表:另外多了「prepare 發現不符」;
- §7 與 §8 `prov-upload-254`:「窗外 helper 每個 poll 週期刪檔」。

這三者行為不同:worker 開檔 unlink 之後,如果有人在窗被 prepare 關掉的同時再 PUT 建了新檔,依 §3.8.2,沒有「到期」這件事會發生,檔案就一直留到下次啟動;依 §7,4 s 內就被刪。**修法**:統一成 A10-m15 建議的一條規則:「helper 每個 poll 週期:沒有窗且沒有 worker → 刪;啟動時刪」;prepare 失敗**不**刪(app 直接重 PUT,PUT 本來就從頭寫)。

**m9 窗在什麼時候關、`updating` 從什麼時候為真,三處寫法不同(A10-m17 最後一條沒改)。**
- §3.1-5:`updating` 「從 worker 開檔起」為真;
- §3.8.1:窗「到 `update.prepare` 開始」為止;
- §3.7.5-1:unlink 之後「才關上傳窗」。

另外,worker 第 1 步(fstat / 大小 / link count)失敗對應哪個 reason 沒寫。**修法**:一個旗標,在 `update.prepare` 回應前設好;窗在同一點關。§3.7.5-1 刪掉「之後才關上傳窗」;第 1 步失敗 → reason 15(上傳不完整)。

**m10 `bulk.open` 要求「呼叫者 = pending 的擁有者」只寫在 §5.1,§3.8.2 沒有。** §12 說「實作只看 §3」,實作者照 §3 做就會漏掉這一條,A10-m6 的情境(B 拿 A 的 sha 開窗,A 的 prepare 因此失敗)會回來。**修法**:§3.8.2 前提加一句,與 §5.1 一致(reason 15)。

**m11 文字錯誤(會讓實作者照錯的做)。**
- (a) §3.7.3 結束碼表 rc 14 還寫「殘留掛載卸不掉」(v7.4 的做法)。應改為「目標分割(major:minor)在 `/boot` 以外的地方被掛著」;同時寫明這條規則也適用於 `arm` / `bootinfo` 自己的掛載。
- (b) §3.7.4 判讀表下的 bullet「arm 後、`rebooting` 前斷電:helper 啟動時 disarm → 第 10 列 23」:斷電之後是新的開機,`apply_boot_id` ≠ 本次,所以**不會** disarm,也不需要(tryboot 旗標斷電就沒了)。結果 23 是對的,但理由寫錯。啟動時 disarm 對應的是「helper crash、沒有斷電」。
- (c) §3.8.2「app 接著 `update/prepare`(BLE 或**同一個 HTTP session**)」:正常流程沒有 HTTP session(MAJOR-1 of A10 之後)。
- (d) §12.5 索引「12.5.8 串流 stdin → §3.7.5-5」:現在是 §3.7.5-6。
- (e) §3.11 的編號:12 夾在 5 和 6 之間。

**m12 §10 檔案清單仍不完整。**
- `batman-slot`:漏了持有者規則(`<pid> <starttime>`)、TERM trap、結束碼表、「只重用 `/boot`、別處掛著 → rc 14」、`write` 的 `clear_root`(MAJOR-1)。
- `batman-autocommit`:漏了持有者規則(`:79-86`、`:226`)。
- Go:漏了 `otaBusy` 的持有者規則(`node/wtxn.go:450-454`)、`provstore.ExecReader`、`sock` 的 peer pid。
- Batman:漏了 `scripts/release-root.fpr`(#255 之前不存在,gate 依此 FAIL `rel`)。

**m13 DEV → PROD 過渡版的通道與版本沒寫(A10-m12 後半)。** 過渡版內建 R,所以 gate 要求它是 `rel`;它用 T 簽(`signrel.py`,因為 `release-sign.sh` 只用 YubiKey);它的 REL 與節點現行的 DEV 版相同時是跨通道 → 要 key 6 列出 DEV 版本。在 §3.7.2 寫一句。

**m14 缺的負對照(§12.5)。**
- (a) worker 遇 rc 14 重試:外部持鎖 15 s → worker 成功;負對照:不重試 → reason 21。
- (b) provd 在窗開著時重啟 → 下一次 poll 取回 bearer → PUT 成功;負對照:bearer 只在 provd 記憶體產生 → 401 / 409。
- (c) key 8 清單只列 92 改前的 sha → 槽第一次開機之後 → reason 5;同時列改後的 sha → 通過(這是發行端的契約,放 `signrel.py` / `release-sign.sh` 的測試)。

**m15 寫明哪些 `batman-slot` 呼叫用新的 mount namespace。** 「helper 以 `Unshareflags = CLONE_NEWNS` 執行 `batman-slot`」沒有限定動詞。`reboot committed` 在沒有 arm 時會 `setsid` 出一個 `sleep 240` 的安全網(`batman-slot:885`)。它如果在新的 namespace 裡,這個 namespace(以及其中所有掛載的副本,包含 p6)會在關機期間多留 240 s,procd 的卸載只卸掉 host 那一份。**修法**:只對 `write` / `arm` / `disarm` / `bootinfo` 用新的 namespace;`reboot committed`、`precheck-node`、`is-trial` 照舊。另外,被 KILL 時會留下空的 `/mnt/slotboot.<pid>` 目錄(`:412`),寫一句「無害、下次開機前不清」即可。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 寫者 | 判定 |
|---|---|---|
| 目標槽 rootfs / boot / BAD / VERIFIED、tryboot 旗標、boot 分割的掛載 | `batman-slot`(鎖);helper 的呼叫經 `slotMu`、在自己的 namespace | ✅;**rootfs 分割上的 overlay 窗**也屬於這一列,但 `write` 沒清 → MAJOR-1 |
| 執行中槽的 `distroconfig.txt` | 92(鎖外,只在槽第一次開機) | ✅ 不與 helper 的寫入同時發生(uci-defaults 在 S10,helper 在 S89) |
| `batman-slot.lock` / `.busy` | `batman-slot` | ✅;讀者 4 個(batman-slot、autocommit ×2、Go `otaBusy`)都要換規則 → m12;zombie → m6 |
| pending | helper(`updMu`) | ✅ |
| update-last | helper(`updMu`、原子寫入) | ✅;`attempt_boot_id` 沒有讀者 → m7 |
| 槽資訊快取 | helper | ✅;rc 14 重讀間隔 → m5 |
| 上傳檔 | provd 寫、helper 刪 | ✅ 刻意的兩方;刪除時機 → m8 |
| 上傳 bearer | helper 產生,provd 只比對 | ✅;交付延遲 → m3 |
| 窗、`updating` | helper | ⚠️ 起點不一致 → m9 |
| `release-root.pub` / `release-min-serial` | firmware stamp;gate 只讀 | ✅ |
| autocommit.log | autocommit + 95(只追加) | ✅ helper 只讀;格式相符 |
| `$RUNDIR/p5-check.rc` | `batman-slot` 的 `node_checks`(helper 的 `precheck-node` / `write` / `arm` 也會寫) | ✅ 既有語意 |

## 5. 現場劇本

| 劇本 | 結果 |
|---|---|
| 正常:BLE `bulk.open` → 手機加入 AP → PUT → prepare → apply | ✅ 成立(A10-MAJOR-1 已修);手機原本就在 AP 上時,前 4 s 可能 409 → m3;AP client 通過 ⚠️ D22 |
| 上傳中斷 / 手機斷 Wi-Fi | ✅ 從頭 PUT;provd 重啟後重新取得 bearer(沒有測試 → m14b) |
| 寫入中斷電 | ✅ 槽 BAD → 22 |
| arm 中 / arm 後、`rebooting` 前斷電 | ✅ 23(理由的文字 → m11b) |
| arm 後 2 s 內被別人重開 + 試用 panic | ⚠️ 報 23,應為 6 + 18 → m2 |
| 重開 / 試用中斷電 | ✅ 6 + 18 |
| 新版不健康 | ✅ 6 |
| **同版本退回後重試** | ❌ **沿用舊 overlay → MAJOR-1** |
| 兩位擁有者 | ✅(§3.8.2 的文字 → m10) |
| 更新中移除擁有者 | ✅ worker 中止 → 22;apply 之後不取消 |
| 成員 | ✅ 沒有 update 動詞;開窗時關掉成員的 HTTP session |
| 降級(key 6)/ 到 P3 之前 | ✅;P3 之前的 payload 只能走 ssh(已寫) |
| 跨通道 | ✅ key 6;過渡版 → m13 |
| helper 在各步 crash | worker 中:孤兒 `write` 讀到 EOF → 讀回失敗 → BAD ✅,但 status 最多 10 分鐘顯示 0 → m5;arm 後:啟動時 disarm ✅;arm 失敗之後:會取消操作員的 arm → m1 |
| provd 在各步 crash | ✅ 窗留著;bearer 由 poll 重新取得 |
| 同時 ssh sysupgrade(沒有 `-F`) | ✅ `write` 期間 stage 1 rc 14;第一遍驗證期間(還沒有 `.busy`)stage 1 會通過 → stage 2 殺掉 helper → 寫入操作員的 image → 第 5 列 0(fail-safe) |
| 同時 ssh sysupgrade(`-F`) | ✅ TERM trap 清掉鎖與 `.busy`;helper 的掛載隨 namespace 消失;非 helper 的殘留 ⚠️ NEEDS-NODE |
| 操作員手動跑 `batman-slot` | ✅ `./batman-slot`、`sh -x` 都算活著(A10-MAJOR-2 已修);worker 遇到操作員持鎖時重試 30 s,之後 reason 21(fail-closed) |
| 不健康的 image 帶壞的 nft include | ✅ D-17(autocommit 要求 `inet fw4`) |
| p6 壞 | ✅ `E_STORAGE`(§6) |
| bcm2711 | 全部待上機 |
| bcm2710 | 只編譯(使用者決定);`write` 的 Pi 3 允許清單 → MAJOR-1 一併處理 |

## 6. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 15 MINOR)。**

v7.4 的三個 MAJOR 都關了,v7.5 的拿掉機制方向也正確:IP 綁定、argv / uid 規則、`armed` 欄位、鎖後卸載都拿掉了。我追過的失敗路徑最後都停在「舊槽可用、目標槽 BAD 或沒有 arm」。

唯一的 MAJOR 是 `write` 契約從 v7.2 起就有的漏項:沒有 `clear_root` 與 `precheck` 的其他項目。現場路徑「退回後重試同一版本」會因此安靜地開進舊 overlay。修法是照抄 `stage-root`,再加一個負對照。

MINOR 中:
- m1、m2、m5 是 v7.5 新規則的邊角,各自都是一句話的修法;
- m7 建議再拿掉一個欄位;
- m8–m12 是文字一致性,A10-m15 / m17 還沒收完。

依使用者規則,MAJOR 改完之後要整份再審。

⚠️ NEEDS-NODE(維持):F75 / F76 / §9-4、`bootinfo` 耗時、`-F` stage 2 遇到殘留掛載、兩遍解壓的實際時間、tryboot 旗標斷電後消失(推論)。
