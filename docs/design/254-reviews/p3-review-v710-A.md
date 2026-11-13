# 254-p3-impl v7.10(11ade69)審查 A — 正確性優先(S5 整份)

範圍:§3.1-5/7、§3.7、§3.8、§3.11、§12(含 §12.5 負對照、§12.5.18)、附錄 E–L,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 中 S5 用到的列。只讀:沒有改任何 repo,沒有上節點。
原始碼:`/home/yello/Batman-p3` @ 11ade69、`/home/yello/firmware-2710` @ 02f0913d(build_dir、scripts、workflows)。target busybox 1.36.1(`build_dir/target-aarch64_cortex-a72_musl/root-bcm27xx/bin/busybox`)以 `qemu-aarch64-static` 實跑;腳本在 scratchpad `s5/a16/`(`q710.sh`、`writer710.sh`)。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 11 MINOR。**

- B15-MAJOR-1(讀者的共享鎖留在呼叫者的 shell)**在文字上真的關了**:§3.7.3 改成 subshell `( exec 8<"$LOCKF" && flock -s -n 8 )`、Go 寫明 open → Flock → 立刻 Close、lint、§12.5 加了同一個 shell 的負對照。我用 target busybox 實跑:同一個 shell 先跑讀者、再跑寫者 → 寫者 rc 0(V1)。
- A15 的 11 項、B15 的 7 項 MINOR **照正文逐處核對**(沒有看附錄 L 的說法):大部分都關了;有 3 項只關一半(A15-m6 版本文法、A15-m8 孤兒目錄、A15-m9 的 §6 列)。
- v7.10 新帶進來的洞都是 MINOR。最值得在實作前改的兩項:
  - m1:disarm tick 的「`slotMu` 沒有被 apply 持有」沒有規定先後。若先讀 update-last、後 TryLock,會在很小的時間窗裡把擁有者剛同意的 apply 取消掉。
  - m2:鎖的順序漏了最外層、而且已經存在的 `n.mu`(`node/node.go:221-222`)。所有非唯讀動詞都持有它,包括 `update.check`、`prepare`、`apply`、`owner.remove`。
- 有一項 v7.10 新機制**有副作用**:`umask 077` 寫在每個動詞開頭,所以後面所有子程序都繼承 077(m3,qemu 實證)。最簡單的修法是**拿掉**它。

---

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | v7.10 的讀者 `[ -e "$F" ] && ( exec 8<"$F" && flock -s -n 8 )` 寫成函式,在同一個 shell 先呼叫、再跑 §3.7.3 的寫者 → 寫者 **rc 0**;讀者在別的程序持排他鎖時 rc 1(忙) | qemu + target busybox,`s5/a16/q710.sh`(附 A) |
| V2 | 讀者這個式子的 rc:**沒有鎖檔 → 1;鎖被持有 → 1;沒有 `flock` → 127;沒人持有 → 0**。也就是說,「沒有檔」和「忙」回一樣的值 | 同上 |
| V3 | 寫者照 v7.10(`command -v` → `umask 077; exec 9>>` → 最多 4 次、`sleep 1`):別人持 2.5 s(啟動時已經持了 0.3 s)→ rc 0,花 3083 ms;持 4 s → rc 14,花 3056 ms。「4 次、約 3 s」成立 | 同上 |
| V4 | 寫者跑過 `umask 077; exec 9>>` 之後,它起的子程序 `sh -c umask` 印 **0077**;鎖檔權限 600 | 同上 |
| V5 | helper 所有非唯讀動詞都在 `n.mu.Lock()` 內 dispatch,整段持有(`node/node.go:221-222`);唯讀動詞不拿(`:212-220`)。設計 F37 與 §3.1-5、§3.1-6 也這樣寫 | 原始碼 |
| V6 | `gate-rootfs.sh` 在 **firmware** repo(`firmware-2710/scripts/gate-rootfs.sh`),不在 Batman。只有 `fast-build.yml:189` 以 `--normal` 呼叫它,`local-ab-tar.sh:73` 不帶旗標呼叫。`build-board.sh:206` 只用它的 `--extract`,之後直接呼叫 `check-prov-test-gate.sh`(`:212`)。`build-firmware.yml` **完全沒有呼叫** `gate-rootfs.sh`(直接跑 `check-prov-test-gate.sh`,`:229`) | 原始碼 grep |
| V7 | stamp 從 `batman-release.env` 只讀指定的 key(`get BATMAN_RELEASE/CHANNEL/BUILD_N/MILESTONE/FEATURES/NOTE`,`stamp-batman-build.sh:22-24,61-68`);`BATMAN_WBOX` 從環境讀(`:55`) | 原始碼 |
| V8 | `tests/keys/T.pub` = 130 個 hex 加 `\n`,共 131 bytes | `wc -c`、`xxd` |
| V9 | 兩板 rootfs 都有 `/usr/bin/flock -> ../../bin/busybox`;stage2 的 `install_file` 對 symlink 建同一個 symlink,並複製 busybox(`package/base-files/files/lib/upgrade/common.sh:8-22`)→ `RAMFS_COPY_BIN` 加 `/usr/bin/flock` 可行 | build_dir、原始碼 |
| V10 | shell 讀者只有 autocommit(`:86` 定義,`:213`、`:226`、`:550` 使用);Go 讀者只有 `otaBusy`(`wtxn.go:450-454`)。另外 harness 有:`p3-units.tsv:108` UD18「`.busy` 不在」、`rundir-paths.txt:23-24`(`batman-slot.lock`、`.busy`)、Go 測試 `wtxn_v10b_test.go:59`、`p3review_test.go:147` | grep(全 repo,排除 docs) |
| V11 | `rundir.sh` 永遠不刪、不重建 RunDir(只有 `mkdir -m 700` 加驗證)→ 鎖檔的 inode 在一次開機內不會被換掉 | `usr/lib/batman/rundir.sh:23-33` |
| V12 | `commit` 持鎖期間會起背景子程序:`env -i … setsid /etc/init.d/openmanetd start &`(`batman-slot:780`)。openmanetd init 只跑 procd_* 與 `batman-addr-defer`,不建檔 | `batman-slot:771-784`;rootfs `/etc/init.d/openmanetd` |
| V13 | `92-batman-ramoops-fix` 自己掛的 boot FAT 用完會卸載 → 不會讓 `bootinfo` 永遠 rc 14 | `etc/uci-defaults/92-batman-ramoops-fix:29-44` |
| V14 | autocommit.log 沒有 rotate;只有 autocommit 與 95 追加(與 §3.7.4 的假設相符) | grep |

---

## 1. v7.9 發現:照正文逐處核對

| 發現 | v7.10 正文 | 判定 |
|---|---|---|
| **B15-MAJOR-1** 讀者把共享鎖留在 shell | §3.7.3:subshell、Go Close、lint;§5.3 列;§12.5「讀者不留鎖」 | ✅(V1)。式子的回傳值有歧義 → m4 |
| A15-m1 鎖的順序 | §3.7.4「先 slotMu 後 updMu;持 updMu 不等 slotMu / worker」 | ⚠️ 規則本身對,但漏了 `n.mu`(m2),disarm tick 有 TOCTOU(m1) |
| A15-m2 app 上限 | §3.11-12「prepare 回 15 或 status 0 + 15 合計連續 3 次」 | ✅ |
| A15-m3 / B15-m1 重試、rc 18、權限 | 4 次約 3 s;`command -v` 在 `exec` 前;`umask 077` | ✅ 秒數與 rc(V3);umask 有副作用 → m3 |
| A15-m4 / B15-m1 §5.3 | §5.3:「在子程序 / 立刻 Close 的 fd 上以共享鎖試拿」、「不存在 = 不忙」 | ✅ |
| A15-m5 / B15-m2 / B15-m6 鑰匙狀態、指紋 | §3.7.1、§3.7.4、§5.1、§12.5 一律 24;指紋 = sha256(65 B) | ✅;§3.7.1 與 §3.7.4 的 none / bad 還有一處不一致 → m8 |
| A15-m6 版本文法 | §3.7.1「以本節為準,harness 對齊」 | ⚠️ 沒寫正規式,`+meta` 的字元集沒定義 → m9 |
| A15-m7 `.bench` 位置 | `+F7.fwW7.bench.dirty.wbox-X` | ✅(對過 `prov-254.sh:161`、`prov-dv-254.sh:30`) |
| A15-m8 孤兒 boot 目錄 | §3.7.5-4 的括號改成「由 prepare 同步處理」 | ⚠️ §3.7.3 rc 14 列仍寫「新 worker 建 boot 目錄前」;§3.7.4 prepare 列沒有這條拒絕;條件寫成無條件;§12.5 沒有負對照 → m5 |
| A15-m9 p6 沒掛上 | §3.7.4 st_dev、不建目錄;§12.5 有負對照 | ⚠️ §6「p6 壞 / 滿 / 唯讀」列沒加「沒掛上」→ m10 |
| A15-m10 / B15-m3 stamp 參數、T 釘選 | §3.7.2 | ✅;但留下兩個已經不需要的機制,T 釘選的理由也寫錯 → m7 |
| A15-m11 apply 描述 | §3.7.3 apply 列 | ✅(§5.1 仍是兩列,24 有自己的列,可以接受) |
| B15-m1 draft | §3.7.2「draft」 | ✅ |
| B15-m4 fast-build、轉賣清單 | §3.7.2「併進 `gate-rootfs.sh --normal`,一個入口涵蓋所有」 | ⚠️ 事實不符(V6)→ m6 |
| B15-m5 `/rom` 開檔 | `O_NOFOLLOW`、regular、`st_dev` | ✅。中間路徑的 symlink 由 `st_dev` 檢查擋住 |
| B15-m7 DoS 出路 | §3.11-12、§7 | ✅ |

---

## 2. BLOCKER / MAJOR

無。

---

## 3. MINOR

**m1 disarm tick 讀 update-last 與 TryLock `slotMu` 的先後沒規定 → 可能取消擁有者剛同意的 apply**
- **情境**:§3.7.4 tick 規則的條件是「`apply_boot_id` = 本次、`rebooting` false,**而且** `slotMu` 沒有被 apply 持有 → disarm」。照字面的自然實作是:先在 `updMu` 內讀一份快照,再 `slotMu.TryLock()`,成功就 disarm。
  1. t1:apply 持 `slotMu`,已寫 `{apply_boot_id = now, rebooting: false}`,正在 arm。tick 讀到這份快照。
  2. apply arm 成功,寫 `rebooting: true`,放掉 `slotMu`,回應。
  3. t2:tick 的 TryLock 成功,拿的是 t1 的快照 → `batman-slot disarm` → 清掉 `apply_boot_id`。
  4. 2 s 後 `reboot committed` 看到旗標是 0,走一般重開(explicit)→ 開回舊槽。
  5. status:第 8 列不成立(`apply_boot_id` 已清)→ 第 10 列 23「新版已寫入但沒有啟用」。擁有者同意的更新**被默默取消**。
- 時間窗很小(讀快照與 TryLock 之間),但 tick 每 4 s 一次,而 arm 要數秒,所以 t1 落在 arm 期間的機率並不低。
- **修法**(只規定順序,不加機制):tick 先 `slotMu.TryLock()`,拿到後才在 `updMu` 內讀 update-last 並判斷條件;disarm 在持 `slotMu`、**不持** `updMu` 時跑;回 0 後在 `updMu` 內清。helper 啟動時那一次也照同樣順序。
- **測試**:Go 接縫讓 tick 在「讀 update-last」與「TryLock」之間停 3 s,同時跑 apply → tryboot 旗標仍是 1、`apply_boot_id` 仍在。負對照:先讀後鎖 → 旗標被清。

**m2 鎖的順序漏了 `n.mu`**
- **事實**:所有非唯讀 helper 動詞都在 `n.mu` 內 dispatch,整段持有(V5)。`update.check`、`update.prepare`、`update.apply`、`bulk.open`、`owner.remove` 都是非唯讀動詞。所以實際的層次是 `n.mu` → `slotMu` → `updMu`;§3.7.4 的規則只寫了後兩層。
- **會出事的地方**:
  - worker 或 tick 只要在持 `slotMu` 時拿 `n.mu`(例如透過 Node 的方法清 `updating`、延 pending),而 `apply` 或 `check` 持 `n.mu` 在等 `slotMu` → 死鎖。
  - `owner.remove` 若在 `n.mu` 內等 worker 結束,§3.7.4 的規則沒有禁止(它只禁止「持 `updMu` 時等 worker」)。worker 不拿 `n.mu` 時,這只會等 ≤ 10 s(TERM → KILL);但規則沒寫,實作就可能寫錯。
- 現在的文字之所以沒出事,靠的是 §3.1-7:worker 在跑時 `otaBusy` 先讓 `check` 回 `E_BUSY`;而 worker 只能經 `prepare`(在 `n.mu` 內)啟動。
- **修法**:§3.7.4 改成「`n.mu` → `slotMu` → `updMu`;worker 與所有 tick **永遠不拿 `n.mu`**;持 `n.mu` 或 `updMu` 時不等 worker 結束;`apply` 在 Lock `slotMu` 之前先判斷『沒有 worker 在跑』(在 `n.mu` 內不會變)」。
- **測試**:把 §12.5「鎖的順序」那列的接縫測試擴大:worker 卡在 `write` 時,`owner.remove`、另一位擁有者的 `update.check`、tick 都在 10 s 內回應;加 Go `-race`。

**m3 `umask 077` 會被之後所有子程序繼承(v7.10 新加的副作用)**
- **證據**:V4。寫者跑過 `umask 077; exec 9>>…` 之後起的子程序,umask 是 0077。§3.7.3 把它放在「每個動詞開頭」,於是 `node_checks` 呼叫的 `batman-config-save --check`、`commit` 的 `/etc/init.d/openmanetd start`(V12)、`otalog` 第一次建立的 p6 記錄檔,全都是 077。
- **影響**:今天看起來無害(讀者都是 root,openmanetd 由 procd fork、不繼承)。但這是全域的、看不見的副作用,之後任何持鎖動詞起的子程序只要建一個需要給非 root 讀的檔,就會壞掉。
- **修法(拿掉機制)**:刪掉 `umask 077`,§5.3 改成「權限由 RunDir root 0700 保證」(B15-m1 原本的建議;§3.7.3 自己也寫了「真正的保護是 RunDir 0700」)。若一定要 0600,就只在 subshell 裡建檔:`( umask 077; : >>"$F" ); exec 9>>"$F"`。
- **測試**:持鎖動詞的子程序 `umask` = 呼叫者的 umask。

**m4 shell 讀者的式子,回傳值把「沒有鎖檔」與「忙」混在一起**
- **證據**:V2。§3.7.3 給的式子 `[ -e "$LOCKF" ] && ( exec 8<"$LOCKF" && flock -s -n 8 )` 只在「檔存在而且沒人持有」時回 0。正文另一句說「鎖檔不存在 = 不忙」,所以實作者必須自己把式子轉成正確的布林。照抄成 `slot_writer_alive(){ ! { 式子; }; }` 的話,沒有鎖檔就會被當成「有人在寫」。
- **後果**:helper 沒有跑過任何 `batman-slot` 持鎖動詞時(例如試用中 helper 壞了,這正是該退回的情況),鎖檔不存在。這時 autocommit `:226` 的退回會延後到 `DEFER_MAX`,而 `:213` 的認領也不能接手。結果還是會退回(DEFER_MAX 有上限),但會晚。
- 這個專案已經出過兩次「照文字抄錯」(附錄 K、L)。
- **修法**:§3.7.3 寫出完整函式,例如 `slot_writer_alive(){ [ -e "$F" ] || return 1; ( exec 8<"$F" && flock -s -n 8 ) 2>/dev/null && return 1; return 0; }`(0 = 有寫者)。§12.5 加一列:「沒有鎖檔(新開機、helper 不在)→ 不忙:autocommit 照常 commit / 退回、`otaBusy` false」;負對照:照抄式子取反 → 忙。

**m5 A15-m8 只關一半:孤兒目錄檢查的位置、條件、負對照**
- §3.7.3 rc 14 列仍寫「新 worker 建 boot 目錄前先試拿鎖,拿不到 → `E_BUSY`」。§3.7.4 的 `update.prepare` 列,前提與拒絕欄都沒有這條。現在它只寫在 §3.7.5-4 的括號裡。實作者看動詞表會漏掉。
- 條件寫成「flock 被持有 → prepare 回 `E_BUSY`」,沒有附帶「目錄存在」。所以 helper 自己的 tick `bootinfo` 刷新、autocommit 的 `commit`、操作員的 `precheck-node`,只要剛好持鎖,prepare 就會回 `E_BUSY`。依 §5.2,app 看到 `E_BUSY` 會去讀 status,而 status 是 phase 1(窗還開著),app 沒有規則可循。
- **修法**:§3.7.4 prepare 列加這條拒絕,條件改成「`update/boot/` **存在**且 flock 被持有 → `E_BUSY`;存在而沒被持有 → 刪了再啟動 worker;不存在 → 照常」;§3.7.3 rc 14 列改成同一句。
- **測試**(§12.5 現在沒有):外部 `batman-slot` 持鎖、目錄存在 → prepare `E_BUSY`、上傳檔仍在、窗沒關;放鎖後 prepare 成功;持鎖但目錄不存在 → prepare 成功。負對照:在 worker 裡才檢查 → 上傳檔被 unlink、0 + 21。

**m6 `gate-rootfs.sh --normal`「一個入口涵蓋所有」與事實不符;同一條規則有兩份實作**
- **事實**(V6):`gate-rootfs.sh` 在 firmware repo,只有 `fast-build.yml` 以 `--normal` 呼叫它。出貨路徑 `build-firmware.yml` 與 `build-board.sh` 第 7 步都不呼叫 `--normal`。
  - 所以 §7「CI(`gate-rootfs.sh --normal`)遇 bench 一律 FAIL」對 release 路徑不成立。release 路徑靠的是 §3.7.2 另外寫的 `check-release-key-gate.sh`。
  - 「一般 image 不得有鑰匙」因此有兩份實作:`check-release-key-gate.sh`(Batman)與 `gate-rootfs.sh --normal`(firmware)。這違反 `gate-rootfs.sh` 檔頭寫的「one implementation」(review A-M3)。
- 另外,`check-release-key-gate.sh` 怎麼知道「這是 CI,bench 要 FAIL」,沒有寫成介面(參數?)。
- §10 自相矛盾:firmware 那一點把 `scripts/check-release-key-gate.sh(新)` 列成 firmware 的檔,同一節又寫「Batman `scripts/check-release-key-gate.sh`」;`gate-rootfs.sh` 的修改根本沒列。
- **修法**:
  - 定一個 CLI:`check-release-key-gate.sh <rootdir> [--ci]`(`--ci` = bench 一律 FAIL)。
  - `gate-rootfs.sh --normal` 在解出的 rootfs 上呼叫它(帶 `--ci`)。
  - `build-firmware.yml` 也呼叫同一支(帶 `--ci`),`build-board.sh` 第 7 步不帶。
  - §7 那列改寫;§10 改正 repo,並列入 `gate-rootfs.sh` 與 `fast-build.yml`。
- **測試**:fast-build 路徑:一般 image 放了 `release-root.pub` → `gate-rootfs.sh --normal` FAIL;放 bench stamp → FAIL(§12.5 現在沒有 fast-build 的列)。

**m7 留下已經不需要的機制;T 釘選的理由寫錯**
- 「`batman-release.env` 裡出現 `BATMAN_BENCH_TRUST` → stamp 失敗」:stamp 只從 release.env 讀指定的 key(V7),而 v7.10 已規定 bench 只從參數來,所以那一行**永遠不會被讀到**。這個檢查擋的是不存在的路徑(A15-m10 原本就建議一併拿掉)。§12.5「bench 旗標來源」列的前半也一起刪。
- 「`wbox_env_reset` 先 unset」:stamp 不讀這個環境變數,所以 unset 不影響結果;可刪,或標明是多一層的保險。
- 「gate 釘死 T 指紋(不拿 feed 的 `T.pub` 比:feed 被改只會讓 build 變 DIRTY,不會被拒)」:gate 腳本**本身也在同一個 feed 裡**(§3.7.2:「firmware 經 `feeds/batman/` 呼叫」),改得了 `T.pub` 的人也改得了釘選值。釘選實際擋的只是「有人在 Batman repo 換了 `T.pub` 卻沒改 gate」。理由請照實寫;或者乾脆拿掉,以「bench 的鑰匙 = feed 釘選 commit 的 `tests/keys/T.pub`」為準(簽章端 `signrel.py` 用的是同一把)。

**m8 鑰匙檔狀態的文字還有一處不一致;「一行」沒定義換行**
- §3.7.1:「`/rom` 不存在、不是 regular、symlink → **當作沒有鑰匙**」(聽起來是 `none`)。§3.7.4:「symlink、不是 regular = **`bad`**」。§12.5:symlink → `bad`。`/rom` 不存在時 `trust` 是哪一個,沒寫。
- 「一行、130 個小寫 hex」:`T.pub` 有結尾的 `\n`(V8)。Go 與 gate 若一邊要求有換行、一邊不准,bench 就會變成 24 / `bad`。
- **修法**:一張小表:兩檔都不在、或 `/rom` 不存在 → `none`;其他任何異常 → `bad`;一律 24。格式寫死:`^[0-9a-f]{130}\n?$`、`^[1-9][0-9]{0,9}\n?$`。

**m9 A15-m6 只關一半:版本文法沒寫成正規式,`+meta` 的字元集沒定義**
- §3.7.1 只寫 `REL[-CH.N][+meta]`。Go 與 `signrel.py` 對 meta 可用哪些字元可能各寫各的。wbox 名字含 `-`(`wbox-test`)。meta 若不收 `-`,所有 `--wbox` 的 bench prov_test payload 都會變成 reason 11。
- **修法**:§3.7.1 寫出唯一的正規式(例:`^[0-9]+\.[0-9]+\.[0-9]+(-(wsl|ci|rel)\.[0-9]+)?(\+[A-Za-z0-9.-]+)?$`),harness PR 照抄;selftest 加 `.bench.dirty.wbox-x`、無後綴、`-foo.1`(要拒)三案。

**m10 §6「p6 壞 / 滿 / 唯讀」列沒有加「沒掛上」(A15-m9 只關一半)**
- §3.7.4 與 §12.5 都有了,§6 沒有。修法:§6 加「p6 沒掛上 → `st_dev` 檢查 → `E_STORAGE`,不寫 overlay」,測試欄指向 §12.5 那列。

**m11 harness 裡依賴舊鎖的項目沒列進 §10;其中一項會變成恆真**
- `scripts/dv/data/p3-units.tsv:108` UD18 的斷言是「`.busy` 不在」。改成 flock 之後 `.busy` 永遠不存在,這個斷言**永遠 PASS**,無法區分對錯(使用者規則:找不到東西可驗的測試必須 FAIL)。
- `scripts/rundir-paths.txt:23-24` 仍列 `batman-slot.lock`、`.busy`,沒有 `batman-slot.flock`(tmp-trust 的路徑表)。
- 這兩處都不在 §10 的 harness 清單裡(§10 只列 `daily-validation.sh:2067`、`setkey-persists-202.sh:65`、`p5-follows-202.sh:121`、`negctl-old-slot-254.sh:29`、兩個 Go 測試)。
- **修法**:§10 的 harness 一點加這兩處。UD18 改成 §12.5「flock 鎖」那列的斷言(KILL shell、`dd` 仍在 → rc 14;子程序都結束 → 釋放);`rundir-paths.txt` 換成 `batman-slot.flock`(照 #290 走 harness PR)。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 判定 |
|---|---|
| `batman-slot.flock` | ✅ 排他鎖只有 `batman-slot` 拿;讀者只用共享鎖、在 subshell 或立刻 Close 的 fd 上(V1);inode 一次開機內不換(V11)。umask → m3;讀者回傳值 → m4 |
| 目標槽、tryboot 旗標、boot FAT 掛載 | ✅(V13:92 會自己卸載) |
| update-last | ✅ 寫者只有 helper;`updMu`;st_dev 檢查。disarm tick 的先後 → m1 |
| helper 記憶體狀態(`updating`、失敗結果、worker 旗標) | ⚠️ 由哪一把 mutex 保護沒寫;`n.mu` 不在順序裡 → m2 |
| 上傳檔、bearer、pending、`provd-stable` | ✅ |
| `/tmp/run/batman/update/boot/` | ⚠️ 條件與位置 → m5 |
| `release-root.pub` / `release-min-serial` | ✅ 寫者只有 stamp(參數);gate 入口 → m6;多餘的檢查 → m7 |

## 5. 生命週期(S5)

| 路徑 | v7.10 行為 | 判定 |
|---|---|---|
| install / 一般 DEV 第一次開機 | 沒有鑰匙 → 24、`none` | ✅ |
| bench 節點(02 / 04 從 wsl.25 經 ssh 升上來) | stage 1 / 2 用 wsl.25 的舊 `batman-slot`;之後全用 flock | ✅ |
| 啟動 | helper `bootinfo` × 2(短暫持鎖)、刪上傳檔、disarm tick | ✅;tick 的先後 → m1;helper 沒跑過時沒有鎖檔 → m4 |
| 正常停止 / 重開 | RunDir 是 tmpfs → 鎖跟著消失;update-last 撐過重開 | ✅ |
| 正常 OTA | check → bulk.open → PUT → prepare → 兩遍 → write → apply → 試用 → commit | ✅;鎖的層次 → m2 |
| 試用中 autocommit commit | 讀者在 subshell → commit 拿得到鎖(V1) | ✅ |
| crash loop(helper) | 每次 `bootinfo` 持鎖,autocommit 的 commit 可能 rc 14、重新累積 | ✅(只會延後) |
| helper crash 在 write 中 | 孤兒 `write` stdin EOF → 讀回失敗 → BAD;prepare 遇到孤兒 | ⚠️ m5 |
| ssh sysupgrade(stage 2 在 ramfs) | flock 經 `RAMFS_COPY_BIN`(V9) | ✅ |
| 升級 / 回滾 / 降級到沒有 P3 的版本 | ssh:stage 2 用 P3 的 `batman-slot`;舊 image 用自己的 mkdir 鎖(RunDir 每次開機都是新的) | ✅ |
| 斷電 | 鎖消失;判讀表 9 / 10 列 | ✅ |
| p6 壞 / 唯讀 / 沒掛上 | `E_STORAGE` | ✅(§6 文字 → m10) |
| 依賴重啟:procd 重啟 openmanetd(commit 中) | `9>&-` + lint + 通用測試 | ✅;umask → m3 |
| CI / fast-build / 本機 build | stamp 只收參數 | ✅;gate 入口 → m6 |
| bcm2711 | 實測項目照 §8 | — |
| bcm2710 | 只編譯(使用者決定);同一份腳本、同一個 busybox 設定(V9 a53 也有 flock) | ✅ |

## 6. 現場劇本(抽查)

- **擁有者按下「安裝」那一刻碰上 4 s tick**:tick 讀到 apply 進行中的快照,arm 一結束就 TryLock 成功 → disarm → 開回舊槽 → app 顯示「已寫入但沒有啟用,請重新更新」(m1)。
- **兩位擁有者,A 的 worker 在寫,B 按「檢查更新」**:`otaBusy` 先回 `E_BUSY`,不會卡住。但若實作讓 worker 的收尾去拿 `n.mu`,B 的請求剛好在 `apply` 等 `slotMu` → helper 卡死(m2)。
- **試用中 helper 起不來(本來就該退回)**:沒有鎖檔。若讀者照式子取反,`:226` 會把退回延到 DEFER_MAX(m4)。
- **helper 剛做完 tick `bootinfo`,擁有者 prepare**:目錄不存在,但 flock 正被持有 → prepare 回 `E_BUSY`,而 app 讀 status 看到的是 phase 1(m5)。

## 7. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 11 MINOR)。**

- B15-MAJOR-1 已真的關閉(正文加上 target busybox 實跑)。
- 實作前一定要改的:m1(tick 先鎖後讀)、m2(把 `n.mu` 寫進順序,並規定 worker 與 tick 不拿它)、m4(讀者寫成完整函式)、m5(prepare 的條件與位置)。這四項都只改字,不加機制。
- m3、m7 是**拿掉機制**的建議(umask、release.env 檢查、多餘的 unset)。
- 其他項可在實作 PR 一起處理,每項都附了測試與負對照。
- 範圍外的觀察(不列發現):Pi 3 上 `DiagBundle` 跑的 `batman-slot verify` 與 trial cache 的 `is-trial` 會唯讀掛 p7(`batman-slot:255-262`);被逾時殺掉時會讓之後的 commit 死在「p7 is mounted」。`batman-addr-defer` 檔頭已經記了 `is-trial` 的這個問題;bcm2710 目前是只編譯,建議記進 #254 checklist。

---

### 附 A:qemu 實跑原始輸出(`s5/a16/q710.sh`,target busybox 1.36.1 a72)

```
reader(no file) rc=1
reader(file,free) rc=0
writer after reader same shell rc=0
holder 2.5s: writer rc=0 after 3083 ms
holder 4s: writer rc=14 after 3056 ms
child umask=0077 lockfile mode=600
reader while held rc=1
reader no-flock rc=127
```
寫者(`writer710.sh`)= §3.7.3 v7.10:`command -v flock >/dev/null || exit 18; umask 077; exec 9>>"$F"; n=1; until flock -n 9; do [ $n -ge 4 ] && exit 14; n=$((n+1)); sleep 1; done`。持鎖者用 host 的 `flock -x $F sleep H`,寫者啟動前它已經持鎖 0.3 s。
