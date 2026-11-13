# 254-p3-impl v7.2(65e6e19)審查 A — S5 軟體更新(§3.7 / §3.8 / §3.11 / §12 + 相依列)

審查者 A(正確性優先)。2026-11-11。只讀:repo `/home/yello/Batman-p3`、firmware `/home/yello/firmware-2710`;沒有改任何檔、沒有 ssh 到節點。
`facts-check.md` 只當線索:下表標 ✅ 的是我自己對過原始碼的;標 ⚠️ NEEDS-NODE 的只能上機確認。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 2 MAJOR / 14 MINOR。** 兩個 MAJOR 都是「契約寫不完整、會讓 app 收到錯的狀態」,改文字(§12)即可,不需要新機制;依規則改完要整份再審一次。

---

## 0. 我自己核對過的事實(證據)

| 項目 | 結果 | 證據 |
|---|---|---|
| §12.1 C1 PRESERVE 已含 ssid、`SKIP_UNSAFE` | ✅ | `batman-config-save:46`、`:58`、`:466` |
| §12.1 C2 `otaBusy` 也擋 `settings.set` | ✅ | `node/node.go:247`;`otaBusy` 只 `Lstat(.busy)`、不看 pid:`node/wtxn.go:450-454` |
| §12.1 C3 `hEReject 24` / `hEInput 25` | ✅ | `provd/helper.go:26-27` |
| §12.1 C5 fw4 自動 include `ruleset-post/*.nft`、目錄不存在 | ✅ | firmware `root-bcm27xx/usr/share/ucode/fw4.uc:817-822`、`:1975`(預設 1);`usr/share/nftables.d/` 只有 `README` |
| §12.2-1 helper 每 15 s 在鎖外 ro 掛 p3 | ✅(原始碼) | `cmd/batman-provhelper/main.go:713-733`;`health/health.go:223`:條件 `poweredFor>=600 && Committed() && ConfigOK()` **每個 tick 都重算**,寫過 ble-ok 之後也照掛 |
| `tboot_open` 會**重用**任何已存在的 TBOOT 掛載點 | ✅ | `batman-slot:409-416`(`awk '$1==d' /proc/mounts` → 有就當 BM、`MOUNTED_HERE=0`) |
| `slot_lock` 拿不到鎖就**立刻 die**(不等) | ✅ | `batman-slot:84-96` |
| `die` 一律 `exit ${DIE_RC:-1}`;`precheck-node` = `node_checks`(與 apply 共用) | ✅ | `batman-slot:40-44`、`:900-911`、`:540-590` |
| `node_checks` 的拒絕有:fw-override、試用中、MBR/FAT、**p5 未 seed**、p5 stale/.txn/lock-busy、`[tryboot]` 指向 | ✅ | `batman-slot:541-590`、`:483-535` |
| 只有 `.busy` 的 EXIT trap,沒有 TERM trap | ✅ | `batman-slot:157` |
| helper 逾時:SIGTERM 整個 pgid → 10 s → SIGKILL | ✅ | `provstore/exec.go`(`Setpgid`;`Kill(-pid, SIGTERM)`、10 s 後 `SIGKILL`) |
| `provstore.Exec` 的 stdin 是 `[]byte`、`run()` 對 batman-slot 預設 60 s | ✅ | `provstore/exec.go:20-27`;`cmd/batman-provhelper/main.go:81-91` |
| `cmd_reboot`:tryboot 旗標 ≠ 0 → plain `reboot`(procd 正常關機,安全網 240 s) | ✅ | `batman-slot:871-892` |
| platform-ab stage 1 只跑 `precheck-node`(不看 `.busy` / 鎖);stage 2 先 kill 所有行程 | ✅ | `platform-ab.sh:~170-186`、`:355-377` |
| autocommit 寫進 p6 `autocommit.log` 的事件:COMMITTED / TRIAL-REVERTED / NOT-COMMITTED / HOLD… ;**沒有「試用開始」的 aclog 行**(只有 otalog `AC START`) | ✅ | `batman-autocommit` aclog 呼叫點 |
| `bad-slot` 內容 = `slot=X version=V`(無 boot_id);commit 時刪 | ✅ | `batman-autocommit` revert 段、commit 段 |
| 95 的 fw-override 只在 `p_req >= 32` 時當成錯落;`p_req` 0 = #133 fallback(會被 autocommit 當 stale fallback 在健康時 commit) | ✅ | `95-batman-storage:426-470`;autocommit stale-fallback 段 |
| CDDL `update-progress` 只有 phase / percent / reason,**沒有版本或 sha** | ✅ | `219-protocol.cddl:305-317` |
| COSE label 當 external_aad;signrel 同法 | ✅ | `cose/cose.go:36-70`;`signrel.py:181` |
| `/etc/batman-build` 有 `BATMAN_BOARD=ekh-bcm2711`、`BATMAN_CHANNEL=wsl` | ✅ | firmware rootfs stamp |
| provd ↔ helper 連線是長連線(4 s poll、30 s idle) → (b)「連續 60 s」可行 | ✅ | `provd/helper.go:63-98`;`sock/sock.go:214` |
| `sock.peerUID` 丟掉 pid | ✅ | `sock/sock.go:178-194` |
| SHA256SUMS 列出**所有** boot 檔(build 端) | ✅ | `build-ab-payload.sh:69-73` |
| §12.3 04 唯讀實測(RAM、RunDir、AP 關、fw4、8095、槽) | ⚠️ NEEDS-NODE | 本次不能 ssh |
| F75/F76:AP client 的 mark 從 bridge 帶到 IP 層、VLAN 臂 | ⚠️ NEEDS-NODE(破壞性) | §9-4 仍開著 |

---

## 1. MAJOR

### MAJOR-1 `update.status` 不綁定「哪一次嘗試」→ 失敗的更新會被報成「已更新(5)」

**情境(使用者列的現場路徑)**:節點 v2 是上一次經 app 成功更新的結果(update-last:`to_slot = 目前槽`、已 commit)。擁有者再更新到 v3:prepare 開始寫(另一槽 BAD)→ **寫入中斷電**,或寫入中 helper crash/重啟。

- 斷電:重開後 pending(tmpfs)消失、helper 記憶體裡的失敗結果消失、`begin_write` 已刪掉 `BATMAN-VERIFIED`。§3.7.4 判讀表往下落到 update-last 的列:「目前槽 = `to_slot` 且已 commit → **5**」;最後一列「版本 ≠ from/to_version → 0」不成立(目前版本就是上次的 to_version)。
- helper 重啟(同一次開機):同上,記憶體結果不見,VERIFIED 不在 → 一樣落到 5。
- 同時有 ssh sysupgrade:sysupgrade 寫同一個目標槽並進試用 → 「目前槽 = to_slot 且 is-trial → 4」,報的是 app 那個版本的試用,實際是 sysupgrade 的版本(表中版本比對列放在最後,優先順序沒寫)。

**後果**:app(§3.11-5)會顯示「已更新 / 已提交」,實際仍是舊版,**而且退路槽已被毀(BAD)**——使用者以為安全修正已裝上。`update-progress` 沒有版本 / sha(`219-protocol.cddl:305-310`),app 也無從比對。

**證據**:§3.7.4 判讀表與 §5.3 update-last 格式;`cddl:305-317`;`batman-slot:423-436`(`begin_write` 讓槽 BAD;設計 §3.7.3 再加刪 VERIFIED)。

**修法(只動契約,不加新機制)**:
1. `update-progress` 加 `4: sha`(這個 phase 說的是哪一個 SHA256SUMS)與 `5: to_version`;app 只在 sha 等於自己要裝的那個時才把 4/5 當成功(§3.11-5 加一句)。
2. 判讀表的優先順序寫死:**先**做「目前槽版本 ∉ {from, to}」與「目前槽版本 ≠ to_version 時不得報 4/5」的檢查。
3. 「這次嘗試寫過另一槽、但沒到 apply」要能在重開後看出來:最省的做法是 `update.prepare` 啟動 worker 前,由**同一個寫者**把 update-last 改寫成 `{attempt_sha, attempt_boot_id, phase: writing}`(update-last 的唯一寫者從「只有 apply」改成「prepare + apply」,仍是 helper 一個 goroutine 序列寫)。判讀:`attempt_sha` ≠ `sha`(沒 apply)且槽 BAD → phase 0 + 新 reason「上次寫入沒完成、退路槽已失效」。
4. 負對照:`prov-update-254` 加「v2 成功更新後,v3 prepare 中斷電 → 重開後 **不是 5**」;拿掉第 1–3 點(wsl 現行判讀)時這個斷言 FAIL。

### MAJOR-2 §12.2-2 的結束碼表沒涵蓋 `update.check` 真正用的動詞,也對不上 §3.7.4 的 reason

**情境**:`update.check` 第 3 步跑的是**既有**的 `batman-slot precheck-node`(§3.7.4),要對應出 reason 1(試用中)、2(p5 未 seed)、12(`.txn`)、17(p5 stale)。§12.2-2 只替**新動詞** `write` / `arm` / `bootcfg-sum` 定結束碼;`precheck-node` 仍是 `die` → rc 1(`batman-slot:40-44`、`:904`)。即使把 `node_checks` 一起改,表裡也**沒有「p5 未 seed」(reason 2)與 fw-override** 的碼(`batman-slot:543`、`:556-578`)→ 落到「其他 → reason 11(內容與簽章不符)」。

**後果**:未 seed 的節點、剛被 firmware 開錯槽的節點,app 會收到「映像簽章 / 內容不符」,使用者會去懷疑映像或重下載,而不是處理真正原因。逾時(RCTimeout 124)與 exec 失敗(127)也落到 11,同樣誤導。

**修法**:
1. 結束碼改在 `node_checks` 層(`write` / `arm` / `precheck-node` 共用)定義;表加:`16` p5 未 seed → reason 2、`17` fw-override(firmware 開錯槽)→ 新 reason 或 15、`18` 卡片 / layout 健全性(MBR、FAT 數、`[tryboot]` 指向)→ 新 reason「節點端無法寫入」;**逾時 / 127 / 其他**不要用 11,用同一個「節點端無法寫入」reason(CDDL 加一號,或明定用 15)。
2. 既有呼叫者只看 rc ≠ 0 的事實要附證據:`platform-ab.sh:186`(`|| {`)、`:366`、`:375`(`[ "$r" = 0 ]`);`daily-validation.sh:2068`(`^rc=[1-9]`,10–18 也符合);`chain1-254.sh:220`(`rc=0*`)。`is-trial` 的 `DIE_RC=2` 不受影響(`batman-slot:894`)——寫進 §12.2-2。
3. §5.1 `update.apply` 補 rc 14 → `E_BUSY`(現在只列 `E_REJECTED{11/12/1/5/17}`)。
4. 負對照:每個 rc 一個誘發案例(已寫),**加上**「`precheck-node` 在未 seed 的 p5 上 → `update.check` 回 reason 2」;現行 rc 1 → helper 回 11 → FAIL。

---

## 2. MINOR

**m1 §12.2-1 的失敗模式寫錯,做法 (a)+(b) 夠用但根因該在單一擁有者那邊修。**
- 設計說撞上時「EBUSY → write 中途 die」。依原始碼,`tboot_open`(`batman-slot:409-416`)先看 `/proc/mounts`,**看到 helper 的 ro 掛載就直接重用**(`MOUNTED_HERE=0`),不會去 mount → 主要分支不是 EBUSY,而是:`invalidate_slot` 寫進 ro 掛載失敗 → die;或在 helper 剛 umount 之後,batman-slot 把檔案寫進 helper 留下的**tmpfs 空目錄**、讀回也從那裡讀 → 自以為驗證通過。我逐支追過:所有分支最後都 fail-closed(真 FAT 上仍是 `begin_write` 留下的 BAD + 無效 cmdline;`arm` 若重新掛載去讀真 FAT 上的 `BATMAN-VERIFIED` 會拒絕;sysupgrade 路徑則是試用時 panic 退回)。但這依賴 `arm` **不重用**現有掛載點。
- (a)+(b) 對 bootConfigOK 足夠(剩 sysupgrade 的毫秒窗,且 stage 2 會先殺掉 helper)。**另外兩個要寫明的**:(i) §3.7.4「helper 在啟動與每次 write/arm/disarm 後快取 `BATMAN-VERIFIED`」也是鎖外讀 FAT,而 helper 重啟時正好可能有孤兒 `batman-slot write` 在跑——這個讀取必須同樣走 (b),而且**鎖消失後要重讀**(否則孤兒 write 完成後快取永遠是舊的,phase 3 重建失敗);(ii) 最省的單一擁有者修法:`tboot_open` 只重用 `/boot`(p1),其他 TBOOT 已被掛著 → rc 14(busy)、不重用;`BATMAN-VERIFIED` / bootConfigOK 的讀取改成 `batman-slot` 的唯讀動詞(鎖內、拿不到鎖 rc 14 → 這輪跳過)。這樣 boot FAT 只有一個寫者兼掛載者。
- 負對照缺:(b) 沒有測試;建議 seam「helper 的 p3 掛載延長 2 s」+ 同時 `batman-slot write` → 沒修時 write 失敗 / 寫錯地方,修後 rc 14 或跳過。

**m2 D-14 的做法要選「`.busy` 帶 pid」,`trap 'exit 143' TERM` 不夠。** helper 逾時先 TERM 整個 pgid、10 s 後 SIGKILL(`provstore/exec.go`);busybox ash 的 trap 要等前景 `dd` 回來才跑,`dd` 卡在慢卡的 fsync(D-state)超過 10 s → shell 被 SIGKILL → `.busy` 留下;`otaBusy` 只 `Lstat`(`wtxn.go:450-454`)→ `settings.set` / `network/*` 到下次重開前都是 `E_BUSY`,app 沒有重開動詞。§12.2-8 寫「照附錄 D-14」(兩選一)→ 寫死用 pid(或兩者都做),測試要包含 SIGKILL 臂。

**m3 6 + 18 的界線寫小了。** 「`rebooting: true` 到真正重開之間的毫秒級斷電」實際上是整個 procd 關機(停服務、docker / OTS,安全網 240 s,`batman-slot:885-890`)**加上**整段試用(autocommit 決定前斷電 / 卡死 / 看門狗重開,都不會寫 TRIAL-REVERTED 也不寫 bad-slot)。這些都會報「新版沒有開機成功」。另外 D-10「`reboot committed` 失敗時 disarm」也要同時把 update-last 改回 `rebooting: false`(同一個寫者),否則下一次無關的重開會報 6 + 18。建議:試用 image 的 helper 在啟動時看到 update-last `to_version` = 自己 → 這是 app 不能寫的資料,不能由它寫 update-last(單一寫者);改用 autocommit 已有的 otalog `AC START` 或在 aclog 加一行 `TRIAL-START boot=… version=…`(autocommit 是 autocommit.log 的唯一寫者),判讀時「有 TRIAL-START、沒有 COMMITTED/REVERTED」= 「試用中斷」而不是「沒開機」。至少把 §3.7.4 的界線文字改正確。

**m4 兩位擁有者:pending 是全域的,bulk.open 不帶 sha。** 擁有者 A `update.check`(pending = vA)→ 擁有者 B `update.check`(覆寫成 vB)→ A `bulk.open` 成功(有 pending)、傳 8 分鐘 → `prepare{sha_A}` → reason 15,原因看不出來。修法:pending 記 `owner_key_id`;`bulk.open` 帶 sha(由 owner-op 綁定)且要等於 pending;另一位擁有者的 `update.check` 在有別人的 pending 時回 `E_BUSY`(或覆寫時讓前一位的 `update.status` 報 15 + 「被另一位擁有者取代」)。`owner/remove` 在 worker 跑時清 pending → worker 完成後無 pending、phase 判讀落空(報 0 或 MAJOR-1 的錯值)——一起寫。

**m5 上傳的 HTTP 語意沒定:** 重新 PUT 是否 `O_TRUNC`(provd 重啟 / 手機斷 Wi-Fi 後重傳)、有沒有續傳、上傳跨過窗到期時(helper 在「窗到期且沒有 worker」就刪檔,provd 寫到已 unlink 的 inode → 回 200 → prepare 15、白傳 8 分鐘)。§3.11 補:app 在 PUT 前若窗剩 < 10 分鐘先重送 `bulk/open` 延長;§3.8.2 補:PUT 一律 `O_TRUNC|O_CREAT|O_NOFOLLOW`。§6 加一列「手機斷 Wi-Fi / 上傳中斷」(現在沒有)。

**m6 `write` 讀 stdin 串流 vs 現行 `provstore.Exec`。** `Exec` 的 stdin 是 `[]byte`(`exec.go:20-27`),照現在的介面做會把 ~111 MiB squashfs 整個放進記憶體(RAM 預算 §3.7.4 沒算這份);`run()` 對 batman-slot 預設 60 s(`main.go:81-91`)。§12 加一句:worker 用 `io.Reader` 版的 Exec(同樣的 pgid / TERM→KILL 規則)與 §3.7.5-6 的期限。

**m7 版本規則沒有表。** D12 只定「正式 > -channel.N」。沒寫:同版本重裝(§8 測「重裝同版本退回 → 6」,若同版本被當降級就測不了)、`-wsl.N` vs `-ci.N` 誰大、`+` 之後忽略時兩個 dirty/wbox build 算相等。請把比較表寫進 §3.7.1(或 VERSIONS.md 的條文列在本文件),Go 測試「版本規則表」照它。

**m8 §12.2-5 的信任:** (i) §3.7.1 的鑰匙表仍寫「T 只有 prov_test 信任」,與 §12.2-5(DEV `wsl` 通道內建 T)矛盾,要同步改;(ii) DEV image 只信任 T → 之後的 PROD(K 由 R 背書)**不能經 app 裝到 DEV 節點**,只能 ssh / 重燒——寫進 §6 升級列與 §11(或讓 DEV 同時信任 T 與 R);(iii) release gate「`BATMAN_CHANNEL ≠ wsl` 且含 T → 不出貨」沒有負對照:加一個「CHANNEL=rel 的 build 放進 T.pub → gate FAIL」;`ci` 通道的 image 也因此不能經 app 更新,寫明。信任 T 不擴權的理由要寫:擁有者本來就能 `ssh_keys/set`(F2),T 簽的 image 不給擁有者更多權限。

**m9 「寫完未 apply」是新的長存狀態,§6 沒有這一列。** `write` 成功後目標槽已是真 cmdline、無 BAD、未 arm(`batman-slot:704-714` 的段落),pending 到期後也不會被清。若之後韌體做 #133 fallback(`p_req` 0,95 不當錯落,`95-batman-storage:436-446`)落到這一槽,autocommit 的 stale-fallback 路徑會在健康時 **commit 一個擁有者沒按 apply 的版本**(它有簽章、讀回過,所以不是安全問題,但要寫明);擁有者放棄時節點沒有退路(§3.7.5 界線已寫一半)。§6 加列、§3.11 加「已寫入、未啟用」的說明;update.status 在這種狀態不該報 0(與 MAJOR-1 一起)。

**m10 同時 ssh sysupgrade:** stage 1 只跑 `precheck-node`,不看 `.busy` / 鎖(`platform-ab.sh:~186`);stage 2 會殺掉 helper 與它的 `batman-slot write`(lock 由 pid 檢查回收)→ 擁有者的更新被默默打斷。P3 之前 `.busy` 只存在於 sysupgrade 自己。建議 stage 1 看到 `.busy`(且持有者活著)就拒絕(`-F` 照舊略過),或至少寫進 §6 / §7 誠實界線。

**m11 bulk tmpfs 要同時加在 `batman-provd-test.init`。** facts-check §2.3 已指出 Makefile 依 `BATMAN_PROV_TEST` 二選一安裝 init(`batman-provd-test.init` 已有 `procd_add_jail_mount_rw`);§12 沒寫 → prov_test image 上 bulk 路徑不存在,`prov-upload-254` 在 wbox 上會測到「沒有 tmpfs」那條(D-15)而不是正常路徑。

**m12 update-last 沒有格式版本。** 讀它的是**下一個版本**的 helper(試用中的新 image)與退回後的舊 helper;§5.3 只寫 map 欄位。加 `0: format` 並寫「未知 key 忽略、未知 format → phase 0」,避免之後改格式時試用 image 誤判。

**m13 §12 的決定缺負對照:** 12.2-1 (b)(見 m1)、12.2-4(S key 2 = `bcm2711` 短字串 → reason 3;`metadata board=` 與 S 不同 → 11;現行 provd 短字串比對時 FAIL)、12.2-5(m8 iii)、12.2-7(Go verifier 與 `signrel.py --verify` 互相驗:signrel 產的正向物件 Go 接受、每個負向旗標 `--bad-sig / --wrong-board / --unparsable-version / --mismatch-size / --key other` Go 都拒絕;拿掉 Go 的任一檢查會 FAIL)。12.2-3 已由 `provd-id-pid` 涵蓋;12.2-2 見 MAJOR-2;12.2-8 見 m2。

**m14 小的契約補漏:** (i) `batman-slot disarm`(helper 啟動時)要拿 slot_lock、拿不到 → rc 14 並延後重試(現在 §3.7.3 沒說,孤兒 write 在跑時不該被 disarm 打斷,雖然 `begin_write` 本身也會 disarm);(ii) `write <dir>` 的 dir 除了 `boot/` 還要放 helper 自己驗過的 `SHA256SUMS` 與 `metadata`(precheck 讀 `$PAYLOAD/SHA256SUMS`、`metadata size=`,`batman-slot:609-627`)——§3.7.5 只寫 boot 檔;(iii) p6 滿 / 唯讀時寫 update-last 失敗 → `E_STORAGE`、不 arm(§3.7.4 只寫「未掛載」)。

---

## 3. 擁有權逐項(一個寫者?)

| 資源 | 寫者(設計) | 判定 |
|---|---|---|
| 目標槽 rootfs / boot / BAD / VERIFIED | batman-slot(鎖) | ✅ 寫者唯一;**讀 / 掛載**者有 helper(bootConfigOK、VERIFIED 快取)在鎖外 → m1 |
| tryboot 旗標 | batman-slot(arm / disarm / begin_write / apply) | ✅;helper 啟動 disarm 要經鎖 → m14 |
| `batman-slot.lock` / `.busy` | batman-slot | ✅;SIGKILL 殘留 `.busy` → m2 |
| `BATMAN-VERIFIED` | batman-slot(write 寫、begin_write 刪) | ✅ |
| pending | helper | ✅ 寫者唯一,但**兩位擁有者共用一份** → m4 |
| update-last | helper(只有 apply) | ✅;MAJOR-1 建議改成 prepare + apply(仍是 helper 單一序列) |
| bulk tmpfs / 上傳檔 | init 掛、provd 寫、helper 刪 | 刻意的多方,已寫;測試 init 缺 → m11 |
| nft 表 / bit 24 | fw4 | ✅(D-3 / D-8 lint) |
| `provd-stable` | helper | ✅ |
| `bad-slot`、`autocommit.log` | autocommit | ✅(helper 只讀) |
| `p5-check.rc` | batman-slot(`update.check` 經 `precheck-node` 也會寫) | ✅ 同一個寫者,寫進「fresh」不擴大 sysupgrade 的 600 s 視窗以外的東西 |

## 4. 生命週期:缺的列

- 手機斷 Wi-Fi / 上傳中斷 / 重傳(m5)。
- 「已寫入、未 apply」長存與 #133 fallback(m9)。
- prepare 中斷電 → 重開後的 phase(MAJOR-1)。
- 同時 ssh sysupgrade(m10)。
- `reboot committed` 失敗(D-10,m3)。
- DEV → PROD 的信任轉換(m8)。
- bcm2710:只編譯、不上機——理由(使用者 2026-10-23 決定量產 CM4、Pi 3 暫不支援;firmware 樹的 bcm2710 payload 是舊的)成立;但 `batman-slot` 的 rc / trap / `tboot_open` 改動會進 Pi 3 的 sysupgrade 共用路徑,CI 的 ab-card(pi3 layout)要跑過,寫進 §8。
- 04(Pi 4 8 GB):RAM 預算夠(7.1 GB available ⚠️ NEEDS-NODE 數字來自 §12.3);AP 目前關著 → 上傳測試前一定要先走 key 20 配對,§12.3 已寫。

## 5. 現場劇本逐條(結論)

| 劇本 | 結果 |
|---|---|
| 擁有者經手機 Wi-Fi 更新(正常) | 流程成立;防火牆的 AP client 通過仍 ⚠️ D22 未測 |
| 上傳中斷 / 手機斷 Wi-Fi | fail-closed(prepare 15),語意未定 → m5 |
| 寫入 / arm / 重開中斷電 | 槽 fail-closed ✅;**狀態回報錯** → MAJOR-1、m3 |
| 新版不開機 / 不健康 | 退回 ✅;6 vs 6+18 的界線 → m3 |
| 兩位擁有者 | 不會壞機,會白傳 → m4 |
| 成員嘗試 | 角色表擋住 ✅(`update/*`、`bulk/*` 只給擁有者;PUT 要窗擁有者的 session) |
| 降級 | key 6 + min-serial,界線已寫 ✅;同版本規則 → m7 |
| helper / provd 每一步 crash | 槽都 fail-closed ✅;helper 重啟後的 phase 重建依賴鎖外讀 VERIFIED → m1、MAJOR-1 |
| 同時 ssh sysupgrade | sysupgrade 贏、app 的更新被打斷,未寫 → m10 |
| 04 / bcm2710 | 見 §4 |

## 6. 判定

**APPROVE-WITH-CHANGES。** 沒有 BLOCKER:我追過的每條失敗路徑最後都留在「舊槽可用、新槽 BAD 或未 arm」。兩個 MAJOR 都會讓 app 收到錯的狀態(把失敗報成成功;把未 seed / 開錯槽報成簽章錯),要在 S5 開工前改 §12(加 `update-progress` 的 sha/version、判讀優先順序、prepare 起點的紀錄;`node_checks` 層的結束碼表)。MINOR 可以進附錄 D,每項附一個沒修會 FAIL 的測試。依使用者規則,MAJOR 改完後要整份再審一次。
