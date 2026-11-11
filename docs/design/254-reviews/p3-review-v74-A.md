# 254-p3-impl v7.4(b78aa27)審查 A — S5 軟體更新(整份重審)

審查者 A(正確性優先)。2026-11-11。只讀:`/home/yello/Batman-p3`@b78aa27、`/home/yello/firmware-2710`@02f0913d;沒有改任何 repo、沒有 ssh 到節點。
範圍:§3.7、§3.8、§3.11、§12(含 §12.2–12.5)、附錄 E / F,以及它們用到的 §4 / §5 / §6 / §7 / §8 / §10 / 附錄 D 列。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 3 MAJOR / 17 MINOR。**
三個 MAJOR 都是文字層級就能修,而且有兩個的修法是**拿掉**機制:
1. 上傳 PUT「綁建立該 HTTP session 的來源 IP」在正常流程(經 BLE `bulk/open` → 加入 AP → PUT)裡沒有那個 HTTP session → 正常更新路徑的契約不成立;IP 綁定本身也沒有安全價值 → 拿掉。
2. v7.4 新的持有者規則「argv[1] 正好是 `/usr/sbin/batman-slot`」讓操作員以 `./batman-slot`、`sh -x …` 跑的寫入被判成「死了」→ 鎖被接手、兩個寫者同時寫槽。uid 0 + starttime 已足夠 → 拿掉 argv[1]。
3. release gate 寫在 `build-board.sh`「CI 同一支」,但 CI(含 `build-release.yml`)根本不跑 `build-board.sh` → 真正出貨的那條路沒有 gate。

v7.3 的兩個 MAJOR(A9-MAJOR-1 / -2)主體已修好;剩下的邊角列在 m1、m2。

---

## 0. 我自己核對過的事實

| 項目 | 結果 | 證據 |
|---|---|---|
| `slot_lock` 現行判活 = pid 活 + cmdline **含** `batman-slot`(子字串);拿不到鎖立刻 die | ✅ | `batman-slot:84-96` |
| shebang 腳本的 argv[1] 是呼叫時給的路徑:`./batman-slot apply` → `/bin/sh ./batman-slot apply`;`sh -x ./batman-slot` → argv[1] = `-x`;經 PATH → `/bin/sh /full/path/batman-slot` | ✅ | WSL 實跑(本次,假腳本印 `/proc/$$/cmdline`):`/bin/sh ./batman-slot apply` / `sh ./batman-slot apply` / `sh -x ./batman-slot apply` / `/bin/sh /tmp/tmp.499o4c0aVf/batman-slot apply` |
| lock / `.busy` 的讀者:`batman-slot`(`:84-96`)、autocommit `slot_writer_alive`(`:86`)與 `:226`、Go `otaBusy`(`node/wtxn.go:451-454`,只 `Lstat`) | ✅ | grep 全 repo |
| helper 沒有 jail(pid namespace 與 batman-slot 相同,`/proc/<pid>` 看得到) | ✅ | `feed/batman-prov/files/batman-provhelper.init`(無 `procd_add_jail`);`respawn 3600 5 0` |
| `bootConfigOK` 只看兩槽 `distroconfig.txt` 的 `[pi4]` 段 + `vcgencmd`;p3 寫死 `/dev/mmcblk0p3`;每個 tick 都跑 | ✅ | `cmd/batman-provhelper/main.go:693-733`;`health/health.go:223-229` |
| `cmd_reboot`:tryboot 旗標 ≠ 0 → **plain** reboot(`exec reboot`),**不**啟動 240 s 安全網;安全網只在 explicit 模式 | ✅ | `batman-slot:870-888`(`why="tryboot flag is $g"` → `:878-881`;安全網 `:885`) |
| autocommit.log 的行:`COMMITTED boot=… slot=$SLOT version=$(version)`、`TRIAL-REVERTED boot=… slot=… version=… waited=…`、`COMMITTED-BY-OPERATOR boot=… slot=… version=…`;`version()` = `/etc/batman-build` 的 `BATMAN_VERSION` 全串;沒有輪替 / 截斷 | ✅ | `batman-autocommit:65-66,239,554,568`;grep 無 rotate |
| `92-batman-ramoops-fix` 在每個新 overlay 的第一次開機以 **rw** 掛**執行中槽**的 boot FAT 並改 `distroconfig.txt`(不經鎖) | ✅ | `etc/uci-defaults/92-batman-ramoops-fix:14-41` |
| 兩板實際 payload:SUMS 每列符合 §3.7.3 正規式、沒有拒絕清單名字、沒有不在複製類別的檔、沒有大小寫重複;tar 順序仍是 `root.squashfs boot … metadata SHA256SUMS` | ✅ | `bin/targets/bcm27xx/bcm2711/ab-payload-ekh-bcm2711.tar.gz`(361 列,126,309,765 B)、bcm2710(364 列);`build-ab-payload.sh:73`(firmware `local-ab-tar.sh:23` 呼叫它) |
| `stamp-batman-build.sh` 版本 = `$REL-$CH.$N+$F7.fw$W7[.dirty][.wbox-X]`;寫 `files/etc/batman-build`;DIRTY 檢查在寫檔**之前**、看 `files` 下 untracked;`.gitignore` 只忽略 `files/etc/batman-build`、`batman-patch-witness` | ✅ | stamp `:38-44,57,59-77`;`.gitignore:39-40`;`git check-ignore` 對 `files/usr/share/batman/release-root.pub` 無輸出 |
| CI 不跑 `build-board.sh`:`build-firmware.yml` 自己呼叫 stamp(`:137`)與各 gate 腳本(`check-prov-test-gate.sh` `:229`);`build-release.yml` 的五個 job 都 `uses: ./.github/workflows/build-firmware.yml` | ✅ | `.github/workflows/build-firmware.yml:95-137,227-233`;`build-release.yml:20-68` |
| sysupgrade stage 2 = `stage-root`(拿鎖、放鎖)→ 串流 → `apply`(再拿鎖);stage 2 重掛 p1 到 `/boot` | ✅ | `platform-ab.sh:357-379` |
| §12.3 04 唯讀實測、F75 / F76 / §9-4 AP client 通過與 VLAN 臂、`bootinfo` 耗時、`-F` stage 2 殘留掛載 | ⚠️ NEEDS-NODE | 本次不能上機 |

---

## 1. 上一輪逐條:真的修了嗎

| 上輪 | v7.4 | 判定 |
|---|---|---|
| A9-MAJOR-1 `bootinfo` 高頻持鎖 | `slotMu`;只在啟動 / 自己寫後 / check 時跑 | ✅ 主情境解了;**「待重讀、下一個 tick 再試」在永久失敗時又變成每 15 s 持鎖,且 tick 若阻塞等 `slotMu` 會卡 600 s** → m1 |
| A9-MAJOR-2 check 快取 | 只快取簽章驗證 | ✅;快取的鍵要是整份 manifest → m2 |
| A9-m1 `written` | 拿掉;`bad=`、第 9 / 10 列看槽 | ✅ |
| A9-m2 失敗綁 sha | 第 3 列 | ✅ |
| A9-m3 / B9-m11 disarm | 啟動時有條件 disarm | ✅;`armed` 在 arm **之後**才寫 → 新的小窗 → m3 |
| A9-m4 aclog | 第 8 列 | ✅;比對規則要寫清楚 → m4 |
| A9-m5 / m6 / B9-m6 | bulk.open 延長 pending、409、worker unlink | ✅ |
| A9-m7 / B9-m7 update-last 原子 | `updMu` + tmp/fsync/rename | ✅;pending 也有多個寫者 → m6 |
| A9-m8 版本規則 | `REL-CH.N` 表 | ✅ 對得上真實字串;但與 D12 不同,沒說 → m12 |
| A9-m9 harness 鎖外掛載 | §3.7.3 列出 | ✅;產品端還有 92 → m10 |
| A9-m10 / B9-m2 bootinfo 契約 | §3.7.3 / §3.7.4 | ✅ |
| A9-m11 / B9-m14 舊文字 | §3.7 / §3.8 重寫 | ⚠️ §4 / §5 / §7 / §8 / §10 仍有矛盾 → m17 |
| A9-m12 結束碼 | 表補齊 | ✅;worker 的 rc 14 沒定 → m5 |
| A9-m13 apply 中移除 | 不取消 | ✅ |
| A9-m14 / B9-m9 gate 與鑰匙寫者 | §3.7.2 | ⚠️ 寫者對了,**gate 放錯地方** → MAJOR-3;stamp 會讓之後的 build 變 DIRTY → m11 |
| A9-m15 / B9-m13 負對照 | §12.5 表 | ✅(MAJOR-2 要加一案) |
| A9-m16 `-F` 殘留掛載 | 拿到鎖後卸載 | ⚠️ NEEDS-NODE(維持) |
| A9-m17 舊 VERIFIED | 綁 boot_id | ✅ |
| B9-m1 pid 冒充 | pid + starttime + uid 0 + argv[1] | ⚠️ 過緊 → **MAJOR-2** |
| B9-m4 AEAD | §3.8.1 | ✅ |
| B9-m5 bearer | `X-Batman-Upload` | ⚠️ 分開了,但 PUT 與 session 的綁定在正常流程不成立 → **MAJOR-1**;bearer 的擁有者 → m7 |
| B9-m8 / m10 / m12 | 界線、窗模式只收擁有者、不分大小寫 | ✅ |

---

## 2. MAJOR

### MAJOR-1 PUT「來源 IP = 建立該 HTTP session 的來源 IP」:正常流程沒有那個 session;IP 綁定也沒有安全價值 → 拿掉

**情境(正常更新)**:擁有者 app 在節點 AP 之外 → 經 **BLE** `bulk/open`(§3.11-1:拿回 SSID / 密碼才能加入 AP)→ 手機加入 AP → `PUT /batman/v1/bulk/0` + `X-Batman-Upload`。§3.8.2 要求「來源 IP = 建立該 HTTP session 的來源 IP」,但 bearer 是在 BLE session 發的,沒有任何 HTTP session;§3.11-12 的上傳流程也沒有寫 app 要先做 HTTP 交握 + `auth/owner`。照字面實作 → provd 找不到 session → 拒絕 → **正常路徑永遠上傳失敗**;或實作者自行決定 → app(U9)與節點各做各的。這正是 v7.4 把 bearer 從 `X-Batman-Session` 拆出來(B9-m5)帶進來的新洞:v7.3 的 bearer 就是 HTTP session id,所以「該 session」有定義。

**證據**:§3.8.2 上傳列;§3.11-1、-12;§7「同 AP 上知道 AP 密碼的人 … PUT 綁來源 IP」。

**為什麼拿掉而不是補定義**:能從空中抓到明文 bearer 的人(同一台 AP、知道 AP 密碼 —— §3.8.2 自己的界線)也在同一個 L2,可以 ARP 毒化 / 用同一個 IP;IP 綁定擋不住它擋的那個行為者,只多一個狀態(session ↔ IP 對照)與一個失敗模式。內容的真偽本來就由簽章 + 讀回把關,搶先 PUT 只是 DoS(已列界線)。

**修法**:§3.8.2 刪掉「來源 IP = …」;PUT 的唯一憑證 = bearer(constant-time、只對這個端點、窗開著、窗擁有者的 bearer);§7 那一列改成「bearer 明文,只造成 DoS」;§3.11-12 明寫「PUT 不需要 HTTP session」。測試:經 BLE `bulk/open`、不做 HTTP 交握直接 PUT → 200 → prepare 成功(負對照:要求 session 的實作 → FAIL)。

### MAJOR-2 持有者規則的「argv[1] 正好是 `/usr/sbin/batman-slot`」讓操作員的寫入被判成死掉 → 鎖被接手,兩個寫者

**情境**:操作員在節點上 `cd /usr/sbin && ./batman-slot apply /tmp/p`,或除錯時 `sh -x /usr/sbin/batman-slot apply …`。它的 argv[1] 是 `./batman-slot` / `-x`(WSL 實測,見 §0)。依 §3.7.3 的規則,`slot_lock`、`node_checks`、autocommit `:226`、Go `otaBusy` 全部判它「死了」:
- helper 的 worker(或另一個操作員的 `batman-slot`)`slot_lock` 時把鎖當成殘留接手 → **兩個行程同時 dd 同一個目標槽**;
- `otaBusy` = 不忙 → `settings.set` / `network/*` 在寫入中跑;
- autocommit 的 revert watchdog 不延後。

現行程式用子字串比對(`batman-slot:88`),這兩種呼叫都算活著 → **v7.4 的修正讓互斥比今天更弱**(fail-open)。後果在 Pi 4 上多半止於讀回不符 → 槽 BAD(fail-closed),但「一個寫者驗過並 arm、另一個還在寫」的交錯會讓 trial 開一個寫壞的槽(Pi 4 panic 回來;Pi 3 撕裂的 `start.elf` 會卡死)。

**證據**:§3.7.3「.busy 與鎖的持有者」;`batman-slot:84-96`;§0 的 argv 實測。

**修法(拿掉機制)**:持有者活著 = `/proc/<pid>` 在 + starttime 相同 + uid 0。這兩項已經擋住 B9-m1 的兩種攻擊:非 root 行程(uid)與 pid 重用(starttime —— 重用的 pid 不會有同一個 starttime)。argv[1] 沒有多擋任何東西。§12.5 負對照加一案:`./batman-slot` 與 `sh -x` 呼叫的 `write-hang` 持鎖時,第二個 `batman-slot write` → rc 14、`otaBusy` = true(負對照:argv[1] 精確比對 → 第二個寫者拿到鎖)。

### MAJOR-3 release gate 只放在 `build-board.sh`,但 release 是 CI 建的,而 CI 不跑 `build-board.sh`

**情境**:§3.7.2「release gate(firmware `scripts/build-board.sh`,image 組好之後;CI 同一支)」。實際上 `build-release.yml` 的每個 job 都 `uses: ./.github/workflows/build-firmware.yml`,而 `build-firmware.yml` 自己逐一呼叫 stamp(`:137`)與各個 gate 腳本(例如 `check-prov-test-gate.sh` `:229`),**不**呼叫 `build-board.sh`。照 §3.7.2 實作 → 本機 build 有 gate,**真正出貨的 CI release 沒有**。「`rel` + T.pub」正是這道 gate 要擋的錯誤(PROD 機群信任公開的 T = 任何人都能簽更新),而它只會在 release 那條路發生。§12.5 的負測試「`rel` + T → FAIL」若以 `build-board.sh` 跑也會通過,抓不到。

**證據**:§0 的 workflow 引用;§3.7.2;§4 `release-root.pub` 列。

**修法**:gate 寫成一支獨立腳本(例如 `scripts/check-release-key.sh <rootfs-dir> <channel>`,與 `check-prov-test-gate.sh` 同型),由 `build-board.sh` 第 7 步與 `build-firmware.yml` 的 rootfs gate 步驟**都**呼叫;§3.7.2、§4、§10 改寫。負測試在 CI 以假 rootfs 跑(像 `test-build-board-wbox.sh`):`rel` + T → FAIL、`rel` 無釘選 → FAIL、`wsl` 放別把 → FAIL;負對照:從 `build-firmware.yml` 拿掉呼叫 → CI 的 workflow lint / 測試 FAIL。

---

## 3. MINOR

**m1 `bootinfo` 的重試仍可能變成週期性持鎖,且 tick 不能阻塞等 `slotMu`。** §3.7.4「上一次拿到 rc 14 或輸出壞掉(標待重讀,下一個 tick 再試)」:rc 18(目標槽 FAT 掛不起來 / `config.txt` 缺,例如斷電寫壞的 FAT)或輸出壞掉是**永久**的 → helper 每 15 s 拿一次 `batman-slot.lock` + vfat 掛載,直到重開 —— 正是 A9-MAJOR-1 在降級狀態下回來(撞操作員的 `commit` / `rollback` 與 trial 的 autocommit `commit`,後者讓 dwell 重來)。另外重試若在 health tick 的 goroutine 裡用阻塞的 `slotMu.Lock()`,worker 的 `write`(上限 600 s)期間 tick 會停住 → health 檔 > 60 s 沒更新(§3.7.6 的新鮮度檢查變 WARN)、ble-ok 不更新。**修法**:只有 rc 14 重試(上限,例如每 60 s、最多 10 次);rc 18 / 輸出壞 → 本次開機標「讀不到」(bootConfigOK = false、key 8 → reason 21),到下一個事件(check / 自己的寫入)才再讀;tick 用 `TryLock`,拿不到就跳過。

**m2 簽章驗證快取的鍵要是整份 manifest。** §3.7.4「簽章驗證結果可依 manifest sha 快取」:若「manifest sha」被實作成 key 4(`sha256(SHA256SUMS)`),同一個 key 4 配一份**壞簽章**的 `[E, S]` 會命中「已驗過」→ 繞過簽章。**修法**:鍵 = sha256(整份 `update-manifest` CBOR,含 key 5 的 E、S bytes);manifest 1–4、6 與 S 的一致性每次重算。負對照:先送正確 manifest,再送 key 4 相同、S 簽章改一個 bit → reason 11(把鍵改成 key 4 → 通過 = FAIL)。

**m3 `armed: true` 在 arm **之後**才寫 → helper 在 arm 完成與寫檔之間死掉時,旗標留著、啟動時不 disarm、之後的判讀錯。** `batman-slot arm` 在自己的 process group(F72),helper 死了它照樣完成。重啟後 `armed` 為 false → 不 disarm → 節點留著已 arm 的 tryboot,下一次任何原因的非斷電重開(joinwatch `reboot committed` `joinwatch:194`、看門狗、操作員)就試用新版。擁有者同意過,可接受;但若試用被退回,第 8 列要求 `armed` → 跳過 → 第 10 列報 **0 + 23「已寫入未啟用」**,其實是 6。**修法(不加欄位)**:把 `armed` 的語意改成「已開始 arm」,在呼叫 `arm` **之前**寫;啟動時條件不變。arm 失敗時的判讀不變(第 8 列沒有 aclog 行、`rebooting` false → 往下 → 23)。

**m4 aclog 的比對規則要寫死。** (a) `version=` 要**整個 token** 相等(以空白或行尾結束):`X` 是 `X.dirty` 的前綴,同版號的 dirty 重建會被前綴比對誤中。(b) `COMMITTED-BY-OPERATOR … slot= version=`(`batman-autocommit:568`)也算「曾 commit」;只比 `COMMITTED ` 開頭的實作會把它漏掉 → 之後被換回時報 6 + 18。(c) `SKIP-ONCE`、`FW-OVERRIDE*` 不算。表測各一案。

**m5 worker 的 `batman-slot write` 回 rc 14(或其他 `node_checks` 拒絕)時沒定義,而且上傳檔已經 unlink。** rc 14 → §3.7.3 只寫「`E_BUSY`(可重試)」,但 worker 是非同步的,沒有線上回應;§5.1 的 worker 失敗清單只有 1 / 11 / 12 / 17。現場會發生:`--check` 等 cfgsave 鎖 5 s 失敗(joinwatch `--on-join` 正在存,`batman-slot:506` → rc 14)、操作員手上的 `commit`、p5 在 check 之後變 stale(rc 12)。步驟 1 已 unlink → 擁有者要重傳 126 MB。**修法**:`node_checks` 的拒絕發生在 `begin_write` 之前,上傳檔的 fd 還在(regular tmpfs 檔可 `Seek(0)`)→ rc 14 時 worker 重試 `write`(例如 3 次、間隔 10 s,重新解析);仍失敗 → phase 0 + reason 21;§5.1 補齊 worker 的完整對應(1 / 2 / 5 / 11 / 12 / 17 / 21)。

**m6 pending 也有多個寫者,要與 update-last 同一把鎖;`bulk.open` 要檢查呼叫者 = pending 的擁有者。** 寫 pending 的有:`update.check`、`bulk.open`(延長)、`update.prepare`(延長)、worker 結束(延到 +30 分)、`owner/remove`(清掉)、到期。worker goroutine 與 ops handler(`owner/remove`)會並行。另外 `bulk.open` 只比 `2` = pending 的 sha,沒有比 pending 的 `owner_key_id`:擁有者 B 拿到 A 的 sha 就能在 A 的 pending 上開窗,A 的 prepare 因「呼叫者 ≠ 窗擁有者」失敗。**修法**:pending 經 `updMu`(或自己的 mutex);`bulk.open` 要求 caller = pending 的 owner,否則 `E_BUSY`。

**m7 上傳 bearer 的擁有者與 provd 重啟。** §3.8.2:bearer 由 provd 在 `bulk.open` 產生,「重送 `bulk/open` 回同一個值」。窗由 helper 持有、撐過 provd 重啟;bearer 只在 provd 記憶體 → provd crash 之後窗還開著、bearer 沒了 → app 的 PUT 被拒(碼未定;§3.11-12 只處理 409)。§4 沒有這個資源。**修法**:§4 加一列「上傳 bearer:provd(記憶體),provd 重啟即失效」;provd 沒有 bearer 時 PUT 回 409「窗沒開(對這個 provd)」→ app 重送 `bulk/open` 拿新值;「回同一個值」限定在同一個 provd 生命週期。

**m8 `update.apply` 的前提「本次開機的 worker 已成功」要以槽的實況定義,不是 helper 記憶體。** helper 在 worker 成功之後重啟(同一次開機):pending 讀回有效、目標槽 `verified = sha + 本次 boot_id` → status 第 4 列 = 3(§8 也要求「helper 重啟後 phase 3 重建」),但若 apply 看的是記憶體 → reason 15 → 狀態與動詞矛盾(A9-m3 (ii) 的同型)。**修法**:apply 的前提 = 第 4 列的條件(pending 有效 + 目標槽 `verified = <sha> <本次 boot_id>`、`bad=0`);`arm` 自己也會再驗一次。

**m9 reason 18 的「安全網 240 s」引用不成立。** tryboot 已 arm 時 `cmd_reboot` 走 plain reboot(`batman-slot:878-881`),**不**啟動 `:885` 的安全網。所以 apply 之後若 procd 關機卡住,節點就停在舊槽(`rebooting: true`),沒有任何東西會再重開。結果的判讀仍對(重開後 6 + 18;沒重開 → helper 已被 K15 停掉)。**修法**:改文字,不加機制;「`reboot committed` 失敗 → disarm」那一支在實務上不會走到(`cmd_reboot` 從不 die,`exec reboot` 立刻回),可以保留但不必為它寫測試。

**m10 「boot 分割只有 `batman-slot` 掛(產品端)」不成立;key 8 與 92 的改寫。** `92-batman-ramoops-fix` 在每個新 overlay 第一次開機以 rw 掛**執行中槽**的 boot FAT 並改 `distroconfig.txt`(§0)。它在 uci-defaults(helper S89 之前)跑、目標是執行中槽,不會撞到寫入 —— 但要寫進 §3.7.3 / §4 並說明為什麼不衝突。另一個後果:一個槽**開過一次**之後,它的 `distroconfig.txt`(進而 `bootcfg=`)就與出廠不同;發行端若用 key 8,清單必須同時含兩種內容,否則這類節點永遠 reason 5,app 沒有出路。§3.7.2 簽章步驟註明。

**m11 stamp 放鑰匙檔會讓之後的 build 變 DIRTY。** `stamp-batman-build.sh` 的 DIRTY 檢查看 `files` 下 untracked 的檔(`:40-42`),而 `.gitignore` 只忽略 `files/etc/batman-build` 與 witness。新的 `files/usr/share/batman/release-root.pub`、`release-min-serial` 不在忽略清單 → 第一次 build 之後,每一次 build 都 `.dirty` → `release-sign.sh` 拒簽。**修法**:`.gitignore` 加這兩個路徑(§10 firmware 那一列)。

**m12 版本規則與 D12 不一致,沒有說明;過渡版的通道沒寫。** D12(使用者決策):同 REL 時「正式版(無後綴)> 任何 `-<channel>.N`」。§3.7.1:無後綴或不同通道 → 沒有順序、要 key 6。現在 stamp 不會產生無後綴版本,所以實務上差別小,但這是改了使用者決定 → 要嘛照 D12(`rel` > `wsl` / `ci`),要嘛請使用者改 D12。另外 §3.7.2 的 DEV → PROD 過渡版(T 簽、內建 R):它是 `rel` 通道(否則 gate 要求 T)、用 `signrel.py` 以 T 簽(`release-sign.sh` 只用 YubiKey)、版本與現行 DEV 同 REL 時要 key 6 列出 DEV 版本 —— 寫進 §3.7.2。

**m13 `write` 從 stdin 讀 rootfs:`node_checks` 的子程序不可繼承這個 stdin。** `write` 在 dd 之前會跑 `batman-config-save --check`、`mount`、`hexdump`、`vcmailbox` 等。現在它們都不讀 stdin,但任何一個將來讀了(或 busybox applet 在錯誤時讀)就會吃掉 rootfs 的開頭 → 每次更新讀回失敗。**修法**:`write` 一開始 `exec 3<&0 </dev/null`,只有 dd 讀 fd 3;Go 端對 EPIPE(batman-slot 提早結束)以錯誤處理,不當成功。

**m14 phase 1 的「已收」位元組數由誰提供沒寫。** `update.status` 是 helper 的 ro 動詞、只讀快取;已收位元組只有 provd 知道。**修法**:poll 的 `http` 欄位加「已收」(provd → helper 唯讀),或 helper 以 `fstatat(dirfd, "payload", AT_SYMLINK_NOFOLLOW)` 取大小(寫明)。

**m15 上傳窗與上傳檔的刪除規則有三個版本。** §3.8.2:worker、`bulk.close`、窗到期(無 worker)、helper 啟動;§4 清理表另有「prepare 發現不符」;§7 與 §8 `prov-upload-254` 是「窗外的上傳檔一個 poll 週期內被刪」。另外失敗的 `update.prepare`(reason 15,上傳不完整)是否關窗沒寫(§3.8.1「到 `update.prepare` 開始」)。**修法**:一份清單 —— 建議「helper 每個 poll 週期:沒有窗且沒有 worker → 刪」+ 啟動時刪(這就涵蓋到期與 close),prepare 失敗**不**關窗、不刪(app 直接重 PUT)。

**m16 生命週期矩陣缺「p6 壞 / 沒掛上」。** update-last 寫不進去 → prepare `E_STORAGE` → 這台節點不能經 app 更新(fail-closed;可能那個更新正是修法)。誠實界線,寫進 §6 與 §3.11(app 的文字:「節點儲存異常,請以維護方式更新」)。

**m17 §4 / §5 / §7 / §8 / §10 仍與重寫後的 §3.7 / §3.8 矛盾(實作者會照錯的那份做)。**
- §5.1 `update.check` 列少 reason 21;`update.apply` arm 失敗列寫 `11 / 12 / 1 / 5 / 17`,§3.7.3 是 `1 / 2 / 5 / 11 / 12 / 17 / 21` + rc 14 → `E_BUSY`;worker 失敗列見 m5;reason 21 / 22 / 23 在 §5.1 都沒有(§3.1-8 說「完整對應在 §5.1」)。
- §5.3 `batman-slot write / arm …` 列「rc 依 §12.5.2」→ 應為 §3.7.3。
- §4 `update-last` 寫者列「worker 結束」→ v7.4 worker 不寫(`written` 已拿掉);§4 清理表「上傳檔 正常結束 = worker 用完刪」→ 現在是開檔後立刻 unlink。
- §7「同 AP … 解出明文 `X-Batman-Session`、搶先 PUT … PUT 綁來源 IP」→ 見 MAJOR-1。
- §8 `prov-update-254`「arm 前斷電 → 0」→ 依第 10 列應為 **0 + 23**;「之前退回過同一槽的 `bad-slot` 不造成假 6」→ 改成 aclog 的說法。
- §10 檔案清單:`batman-slot` 漏了持有者規則、TERM trap、殘留卸載、結束碼;autocommit 漏了持有者規則;firmware 那一列只有 `flash.js`,漏 `stamp-batman-build.sh`(放鑰匙)、gate 腳本 + `build-board.sh` + `build-firmware.yml`(MAJOR-3)、`.gitignore`(m11);Batman 漏 `scripts/release-root.fpr`。
- §3.1-5「`updating` 從 worker 開檔起為真」與 §3.7.4 第 2 列 / §3.8.2 409「worker 在跑」:用同一個旗標、從 `update.prepare` 回應前就成立(否則 prepare 與 worker 開檔之間的 PUT 不會 409)。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 寫者 | 判定 |
|---|---|---|
| 目標槽 rootfs / boot / BAD / VERIFIED、tryboot 旗標 | `batman-slot`(鎖) | ✅;**互斥的判活規則過緊** → MAJOR-2 |
| boot 分割的掛載 | `batman-slot`;harness(已列);**`92-batman-ramoops-fix`(執行中槽,rw)** | ⚠️ m10(不衝突,但要寫) |
| `batman-slot.lock` / `.busy` | `batman-slot` | ✅;讀者 4 個(§0),都要換規則 |
| pending | helper(check、bulk.open、prepare、worker 結束、owner/remove) | ⚠️ 多 goroutine → m6 |
| update-last | helper(`updMu`) | ✅(§4 文字要改,m17) |
| 槽資訊快取 | helper | ✅;重試規則 m1 |
| 上傳檔 | provd 寫、helper 刪 | ✅ 刻意的兩方;刪除時機三個版本 → m15 |
| 上傳 bearer | provd | ⚠️ 不在 §4、重啟語意未定 → m7 |
| `release-root.pub` / `release-min-serial` | firmware stamp;gate | ✅ 寫者;⚠️ gate 位置 → MAJOR-3;DIRTY → m11 |
| `bad-slot`、autocommit.log | autocommit(+95 的 FW-OVERRIDE 行) | ✅ helper 只讀;比對 → m4 |

## 5. 現場劇本

| 劇本 | 結果 |
|---|---|
| 正常:手機 Wi-Fi 更新 | **PUT 綁 HTTP session 在 BLE 開窗的正常流程不成立 → MAJOR-1**;其餘流程成立;AP client 通過 ⚠️ D22 |
| 上傳中斷 / 手機斷 Wi-Fi | 從頭 PUT ✅;provd 在中途 crash → bearer 沒了 → m7 |
| 寫入 / arm / 重開 / 試用中斷電 | 槽都 fail-closed ✅;判讀:arm 後、`rebooting` 前斷電 → 23 ✅;helper 在 arm 完成與寫 `armed` 之間死 → m3 |
| 新版不健康 | 6 ✅(aclog 比對細節 m4) |
| 兩位擁有者 | ✅;B 在 A 的 pending 上開窗 → m6 |
| 擁有者在更新中被移除 | worker 中止 → 22 ✅;apply 後不取消 ✅ |
| 成員 | 動詞只給擁有者 ✅ |
| 降級(key 6)/ 到 P3 之前 | ✅;舊 VERIFIED 由 boot_id 擋 ✅ |
| 同版本重裝 | 允許;第 6 / 7 列靠槽區分 ✅ |
| 跨通道 | key 6 ✅;與 D12 不同 → m12 |
| helper crash 各步 | worker 中 → BAD / 22 ✅;worker 成功後 → 3,但 apply 前提 → m8;arm 中 → m3 |
| provd crash | 上傳檔留著、app 重 PUT ✅;bearer → m7 |
| 同時 ssh sysupgrade(無 `-F`) | worker 已進 `write` → stage 1 rc 14 ✅;worker 還在解析(沒有 `.busy`)→ stage 1 通過、stage 2 殺掉 helper、操作員的 image 寫進去 → 之後第 5 列版本不符 → 0 ✅(fail-safe) |
| 同時 ssh sysupgrade(`-F`) | stage 2 殺掉 write(TERM trap 清 `.busy` / 鎖)→ 照常寫;殘留掛載 ⚠️ NEEDS-NODE |
| 操作員手動 `batman-slot` | `./batman-slot` / `sh -x` → **鎖被接手 → MAJOR-2**;手動 apply 後 helper 重啟不 disarm ✅;手動 apply 之後 helper 的槽快取過期(下一次 check 才更新)→ 狀態可能暫時不準,可接受 |
| check 被拒後重試 | 每次重跑 precheck ✅(A9-MAJOR-2 已修) |
| p6 壞 | 不能更新 → m16 |
| bcm2711 | 全部待上機實測 |
| bcm2710 | 使用者決定只編譯(2026-10-23);payload SUMS 名字符合新規則 ✅(§0);`bootConfigOK` 的 `[pi4]` 段在 Pi 3 永遠 false(既有,不在 S5) |

## 6. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 3 MAJOR / 17 MINOR)。** 沒有 BLOCKER:我追過的失敗路徑最後都停在「舊槽可用、目標槽 BAD 或未 arm」。三個 MAJOR 都是 v7.4 的文字讓實作會照錯的方向做:正常上傳路徑的 PUT 綁定沒有定義(MAJOR-1,建議拿掉 IP 綁定)、持有者規則比現行更容易被判死而讓鎖被接手(MAJOR-2,建議拿掉 argv[1])、release gate 放在 CI release 不經過的腳本(MAJOR-3)。兩個的修法是拿掉機制,第三個是把 gate 抽成一支兩邊都呼叫的腳本。MINOR 大多是邊角與文字一致性(m17 一次掃完)。依使用者規則,MAJOR 改完後整份再審。

⚠️ NEEDS-NODE(維持):F75 / F76 / §9-4(AP client 通過、VLAN 臂)、`bootinfo` 實際耗時、`sysupgrade -F` 在 app 寫入中強制時 stage 2 的殘留掛載(A9-m16)。
