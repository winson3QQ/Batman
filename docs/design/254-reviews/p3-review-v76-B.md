# 254-p3-impl v7.6(2f7526e)審查 B — 安全優先(S5 整份)

範圍:§3.7、§3.8、§3.11、§12、附錄 E–H,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 / 附錄 D 中 S5 用到的列。只讀;沒改任何 repo、沒上節點。原始碼:Batman-p3 工作樹、firmware-2710(kernel 6.6.138 = `build_dir/target-aarch64_cortex-a72_musl/linux-bcm27xx_bcm2711/linux-6.6.138`;busybox 1.36.1;Go = `staging_dir/hostpkg/lib/go-1.26`)。

## 0. 本輪自己查證的事實(file:line)

| # | 事實 | 證據 |
|---|---|---|
| W1 | F_RDLCK lease:inode 有任何寫入開啟(`i_writecount > 0`)→ `-EAGAIN`;插入後再檢查一次(無競態) | `fs/locks.c:1695-1696`、`:1795-1800` |
| W2 | `leases_enable = 0` → `-EINVAL`(只在新增 lease 時);預設 1;firmware `files/` 與 Batman feed 都沒有改它的 sysctl | `fs/locks.c:93`、`:1792-1794`;grep 無 |
| W3 | `generic_setlease`:檔案 owner ≠ 呼叫者 fsuid 且無 `CAP_LEASE` → `EACCES` → 先 `fchown(0,0)` 再設 lease,root helper 一定過 | `fs/locks.c:1870-1880` |
| W4 | 開檔順序:`may_open` → `inode_permission`(權限)**先於** `get_write_access`(`i_writecount++`)與 `break_lease` | `fs/namei.c:3232-3268`、`:3638`;`fs/open.c:895-903`、`:920` |
| W5 | 唯讀 fd 的 `MAP_SHARED` 拿不到 `VM_MAYWRITE` → `mprotect(PROT_WRITE)` 失敗;可寫共享 mmap 要寫入 fd(計入 `i_writecount`,vma 持有 file) | `mm/mmap.c:1327-1329`、`:2934` |
| W6 | `linkat` 不能把 nlink 0 的檔案接回(非 `O_TMPFILE`) | `fs/namei.c:4598` |
| W7 | lease break 只送 SIGIO 給設 lease 的行程(`lease_setup` 的 `__f_setown`);Go 對 SIGIO 是 `_SigNotify`,沒有 `signal.Notify` 時**直接忽略** | `fs/locks.c:519-541`;`runtime/sigtab_linux_generic.go:39`、`signal_unix.go:735-760` |
| W8 | provd 的 jail:`procd_add_jail batman-provd log requirejail`,**沒有 `procfs`** → jail 裡沒有 `/proc`;helper 沒有 jail、沒有 capabilities 限制 | `feed/batman-prov/files/batman-provd.init:19-23`;`batman-provhelper.init`;procd.sh `_procd_add_jail:186-208` |
| W9 | busybox `ln -s X L`:`L` 是既有目錄(或指向目錄的 symlink)時,**在目錄裡建連結並成功**;`-T` 支援(遇目錄就 die) | busybox-1.36.1 `coreutils/ln.c` `ln_main`(`is_directory(src, !(NODEREF\|LINKFILE))` → `concat_path_file`) |
| W10 | busybox `CONFIG_FLOCK=y`(`flock` applet 在映像裡) | busybox-1.36.1 `.config:628` |
| W11 | 現行 `slot_lock` 接手 = `rm -rf "$LOCK"; mkdir "$LOCK"`(不是原子的「比較後取代」);EXIT trap `rm -rf "$LOCK"` | `batman-slot:84-96`、`:157` |
| W12 | `node_checks` 在 `write` / `arm` 裡 ro,noload 掛 p5(`/mnt/p5seed.$$`)、`batman-config-save --check` 也掛 p5;pi3 還掛 p7 | `batman-slot:556-576`、`:470`、`:258`;`batman-config-save:36-37,116,131,299-307` |
| W13 | **實際的公開 release 在 `winson3QQ/Batman`**(v1.5.11 Latest,資產 = `…-rel.1+…-ab-payload.tar.gz`、`…-ab.img.gz`、`SHA256SUMS`;手動上傳,repo 裡沒有任何發布腳本 / workflow);firmware repo 只有一個上游 Draft | `docs/design/254-h23-harness.md:60`(F18,`gh release list/view` 2026-10-28);`grep -rn "gh release create\|upload"` 無結果;`docs/VERSIONS.md:47-65` |
| W14 | firmware `github-release.yml` 只有 checkout + `softprops/action-gh-release@v1`(draft、**沒有任何 files、沒有 build、沒有 artifact**);`build-release.yml` 的 `publish-packages` job 與 `release` job 平行(兩者都只 `needs` build) | `github-release.yml:1-24`;`build-release.yml:78-80,148-150,186-260` |
| W15 | CI 的 `batman-build.txt` 是從 rootfs 抽出的 `/etc/batman-build`(只有 stamp,**沒有** `release-root.pub`) | `build-firmware.yml:212-222` |

## 1. v7.5 發現逐條確認

| 發現 | v7.6 | 判定 |
|---|---|---|
| A11-MAJOR-1 `write` 漏 `clear_root` / precheck | §3.7.3 `write` 照 `stage-root` 順序(`:650-657`)| ✅ 對照 `batman-slot:592-657` |
| B11-MAJOR-1 / A11-m4 保留寫入 fd | unlink → fchown/fchmod → F_RDLCK lease → 再 fstat | ✅ **機制成立**(§2 逐一攻擊);但「持有到第二遍 + SIGIO 中止」是多餘機制、理由文字不對 → m2 |
| B11-MAJOR-2 `wsl` / `ci` 不出貨 | `--publish` 放在 firmware `build-release.yml` / `github-release.yml` | ❌ **放錯地方**:真正的公開發布走 Batman repo 手動上傳(W13);`github-release.yml` 沒有 artifact 可檢查(W14)→ **MAJOR-1** |
| A11-m1 / m2 / m3 / m5 / m6 / m7 / m9 / m10 / m12 / m13 / m14 / m15 | 附錄 H | ✅(抽查 §3.7.3、§3.7.4、§3.8.2、§12.5 表) |
| A11-m8 刪檔規則統一 | §3.8.2 統一 | ⚠️ §4 清理表仍寫「prepare 發現不符 → helper 刪」→ m6 |
| A11-m11 文字錯誤 | 已改 | ✅ |
| B11-m1 原子鎖 | symlink 鎖、`.busy` rename、格式錯 = 忙 | ⚠️ 原子出現 ✅;但 `ln -s` 遇目錄會「成功」、接手不是原子 → m1 |
| B11-m2 starttime 向量 | §3.7.3、§12.5 | ✅ |
| B11-m3 namespace 副作用 | §3.7.3、§7(只寫 boot FAT) | ⚠️ p5 / p7 的掛載也在 namespace 裡 → m3 |
| B11-m4 bearer 格式 | 32 小寫 hex、沒有 bearer 一律拒 | ✅ |
| B11-m5 兩遍與 boot 檔 | §3.7.5-5 / 6 | ✅ |
| B11-m6 tmpfs 沒掛上 | `fstatfs` | ⚠️ 擋了 `bulk.open`,沒擋「沒掛上的目錄仍 rw 進 jail」→ m5 |
| B11-m7 舊文字 | 大部分 | ⚠️ m6 |

## 2. v7.6 新機制的攻擊(逐項)

### 2.1 讀取租約(§3.7.5-1)— 被入侵的 provd(uid 471、jail、無 capabilities、no_new_privs、無 /proc)

| 攻擊 | 結果 | 證據 |
|---|---|---|
| 窗內 `O_RDWR` 開著不關 | lease `EAGAIN` → reason 21、目標槽沒動 | W1 |
| 寫入 fd `dup` / `SCM_RIGHTS` 給 jail 裡另一個行程 | 一樣計入 `i_writecount`(以 inode 計,不分行程) | W1 |
| 可寫 `MAP_SHARED` 後關 fd | vma 持有可寫 file → 仍計入 → `EAGAIN` | W5 |
| `O_RDONLY` 開 + `mmap(MAP_SHARED)` + `mprotect(PROT_WRITE)` | 沒有 `VM_MAYWRITE` → 失敗;`MAP_PRIVATE` 是 COW,不改檔 | W5 |
| `splice` / `vmsplice` / `copy_file_range` / `fallocate` / `MADV_REMOVE` | 寫進檔案都需要寫入 fd(`MADV_REMOVE` 需要 `VM_SHARED\|VM_WRITE`)→ 前一列 | W5 |
| io_uring 固定檔 / AIO | 都是帶 `FMODE_WRITE` 的 file → 計入 | W1 |
| lease 之後經 `/proc/self/fd/N` 以寫入重開 | jail 沒有 `/proc`(W8);就算有,`fchown root` + `0400` 後 `inode_permission` 先擋(W4) | W4、W8 |
| `O_PATH` fd 在 unlink 與 fchown 之間重開成寫入 | 得到寫入 fd → lease `EAGAIN`(順序:fchown → lease 是對的) | W1、W3 |
| `link()` 把開著的 inode 接回目錄 | nlink 0 不能接回;unlink 前先 `link` → 第二次 fstat 要 nlink 0 → 抓到 | W6;§3.7.5-1 |
| 把 `payload` rename 走、放別的檔 | helper unlink 到別的檔、原 inode nlink 1 → 第二次 fstat 抓到 | §3.7.5-1 |
| provd 自己先設 F_WRLCK lease(它是 owner) | helper 的 `O_NONBLOCK` 開檔 `EWOULDBLOCK` → reason 15 = 只有 DoS | `fs/open.c:920` |
| 自己觸發 lease break | 需要以寫入開檔或 truncate → 權限先擋(W4);只有 root 能觸發,且 root 只是等 45 s | W4;`locks.c:94,1517` |
| `leases-enable=0` | `EINVAL` → 「拿不到 → 21」= fail-closed;只有 host root 能改 | W2 |

結論:**租約機制本身成立**,對被入侵的 provd 沒有找到繞過。多餘的部分見 m2。

### 2.2 symlink 鎖、「格式錯 = 忙」、zombie 規則

- 非 root 能不能造格式錯的鎖來 DoS:不能。`/tmp/run` 由 procd 在任何非 root 行程之前建(root 0755),`/tmp/run/batman` 由 `batman_rundir` 驗證 root 0700、非 symlink(`rundir.sh:23-35`);docker / host-net 容器裡的 root 是 root。✅
- root 崩潰會不會留下格式錯的鎖:不會(`symlink(2)` 原子帶內容)。✅
- **新的洞**:busybox `ln -s` 遇到目錄會在目錄裡建連結並回 0(W9);舊版(mkdir 格式)的鎖碰到新版、或新版的 symlink 鎖碰到舊版的 `cat $LOCK/pid` → `rm -rf` 接手(W11),都會變成兩個寫者。另外「持有者死了 → 下一個 `batman-slot` 清掉再 `ln -s`」不是原子的比較後取代:兩個爭奪者都讀到同一個死持有者時,後 `rm` 的會刪掉先建好的活鎖 → 兩個寫者(現行 `rm -rf; mkdir` 也一樣)→ m1。
- zombie 規則:看第 3 欄 `Z` = 死,正確。殘留風險:只殺掉 shell(操作員 `kill -9 <pid>`)時,它的子行程 `dd` 還在寫目標槽,而持有者已被判死 → 另一個寫者接手;讀回會抓到,結果是 BAD / 試用退回,不是完整性缺口。helper 自己是整個 process group KILL,不受影響。用 `flock` 可以一併消掉(m1)。

### 2.3 `clear_root` 在串流之前

`clear_root` 清 `ZERO_MB = SQ_MB + 64`,`SQ_BYTES` 在串流模式取自未簽的 `metadata size=`(`batman-slot:614-617`)。helper 要求 tar header 大小 = `metadata size=`,且那個成員剛好那麼長的內容 sha = SUMS(已簽)→ `size=` 實際上被簽章鎖定。target root 掛著 → precheck 拒絕(`:585`)。✅

### 2.4 發布點 → MAJOR-1

### 2.5 過渡版(T 簽、內建 R)

DEV 節點本來就接受任何 T 簽的東西(T 公開,§12.5.18-1),過渡版沒有增加對 DEV 的風險;R 信任的節點不收 T。✅ 但它繞過 `release-sign.sh` 的拒簽檢查(dirty / wbox / 在 payload 上重跑 gate),而它正是之後 PROD 節點的起點 → m4。

### 2.6 bearer 格式

`crypto/rand` 128 bit、32 小寫 hex、沒有 bearer 一律拒、constant-time;經 poll(helper socket 只收 uid 471)。✅

### 2.7 `fstatfs` 檢查

擋住「init 沒掛上時在 `/tmp` 上的普通目錄開窗」。✅ 但沒掛上時那個普通目錄仍被 rw 掛進 jail → m5。

### 2.8 mount namespace 副作用

FAT 部分 v7.6 已寫。漏了 p5(ext4)/ p7 → m3。`unshare` 失敗 = exec 失敗 → reason 21,fail-closed ✅。KILL 後 namespace 消失 → 掛載清掉,比現狀好 ✅。

## 3. 行為者總覽(整份 S5)

| 行為者 | 結果 |
|---|---|
| mesh 遠端 | 打不到 8095(bridge mark + iifname,F75)✅ |
| 手機 AP 上的裝置(知道 AP 密碼) | 搶 bearer / 搶 PUT / 打斷取回 = DoS;垃圾 rootfs 第一遍擋 ✅ |
| 本機非特權行程 / docker tenant / host-net 容器 | 鎖 / `.busy` / RunDir 寫不到;FAT 掛不了;`SO_MARK` 由 iifname 擋;佔 8095 = DoS(已列)✅ |
| 被入侵的 provd | 內容完整性 ✅;保留 fd 毀退路 ✅(lease,§2.1);佔 RAM ≤ `size=` ✅;**tmpfs 沒掛上時可塞滿 `/tmp`** → m5 |
| 被移除的擁有者 | 窗、pending、worker 都清 ✅ |
| 成員 | 不能 `update/*`、`bulk/*` ✅ |
| 實體奪取 | 無 secure boot 前的誠實界線;**若公開 image 信任 T,奪取 + 重置 + 認領 = 經 app 裝任意韌體** → MAJOR-1 |
| 供應鏈 / 維護者 | 能同時改兩個 repo 的人可換鑰匙(已列界線);**發布檢查不在真正的發布路徑** → MAJOR-1 |
| 我們自己的錯 | 混版本鎖 / 接手競態 → m1;過渡版沒有拒簽檢查 → m4 |

## 4. Findings

### MAJOR

**MAJOR-1 `--publish` 放在不會發布 Batman image 的地方;使用者決定「R 之前不發公開 release」在真正的發布路徑上沒有機制(B11-MAJOR-2 未真正關閉)**

- **情境**:P3 合併後、#255 之前,照過去的做法把一個 `-wsl.N` / `-ci.N`(內建公開 T)的 `.img.gz` 與 `ab-payload.tar.gz` 手動上傳成 `winson3QQ/Batman` 的 release(v1.5.11 就是這樣發的,W13)。firmware 的 `build-release.yml` 根本沒跑,`--publish` 不會被呼叫。燒了這份 image 的節點信任 T;任何人都能算出 T 的私鑰(`tests/keys/README.md`)→ 奪取 / 撿到節點的人重置、認領後經 app 裝任意韌體並放回車隊。現場修不回來(只能 ssh / 重燒)。
- **證據**:W13(公開 release 只在 Batman repo、手動、沒有腳本或 workflow);W14(`github-release.yml` 沒有 build、沒有 artifact → §3.7.2「讀每個板子 artifact 的 `batman-build.txt`」在那裡無法實作;`publish-packages` 與 `release` 平行,gate 放在 `release` job 開頭擋不到它);W15(`batman-build.txt` 只有 stamp → `--publish`「只接受 `rel` + R 指紋」拿不到 `release-root.pub`,只能驗通道);另外 `workflow_dispatch` / tag push 用的是**那個 ref 上的** workflow 檔,從沒有 gate 的分支 / 舊 commit 觸發就沒有檢查(lint 只看 main)。
- **修法**(把同一支檢查搬到資產真正出去的地方,不加新的檢查邏輯):
  1. Batman repo 加 `scripts/publish-release.sh` 作為**唯一**的發布方式(寫進 `docs/VERSIONS.md`):對每個要上傳的 `*-ab-payload.tar.gz` / `*.img.gz` 取出 rootfs 的 `/etc/batman-build` 與 `/usr/share/batman/release-root.pub`,跑 `check-release-key-gate.sh --publish`(`rel` + 指紋 = `scripts/release-root.fpr`),過了才 `gh release create/upload`。
  2. 偵測型的第二道(擋繞過腳本的手動上傳):Batman repo workflow `on: release: [published, edited]`,下載資產、跑同一支檢查,FAIL → `gh release edit --draft` 並開 issue。誠實界線:發布到被改回草稿之間有幾分鐘的窗。
  3. firmware:`--publish` 改成一個獨立 job,`release` **與** `publish-packages` 都 `needs` 它;CI 的 rootfs 抽取步驟(`build-firmware.yml:218` 同一處)把 `release-root.pub` 也複製進 artifact;`github-release.yml` 沒有資產 → 不呼叫(或直接刪掉這個 workflow),不要寫一條無法實作的規則。
  4. 文件寫明:檢查只擋我們自己的錯;能改 workflow / 從別的 ref dispatch 的維護者可以繞過(與現有 gate 界線相同)。
- **負測試**:`publish-release.sh` 對 `wsl` / `ci` payload、`rel` 但內建 T 的 payload → 拒絕、沒有任何 `gh` 呼叫(用 PATH 裡的假 `gh` 記錄);fork / 測試 repo 發布一個 `wsl` 資產 → workflow 把它改回 draft;firmware:`release` 或 `publish-packages` 少了 `needs: publish-gate` → lint FAIL。負對照:拿掉檢查 → 假 `gh` 被呼叫 / release 保持 published。

### MINOR

**m1 symlink 鎖:`ln -s` 遇目錄會成功、舊版會把新鎖當死鎖刪掉、接手不是原子 → 兩個寫者;建議改用 `flock` 一次拿掉整組機制**

- 情境 (a):`$LOCK` 是舊版 `mkdir` 格式的目錄(同一次開機跑了舊版 `batman-slot` 副本,例如 harness 的 pre-254 腳本)→ 新版 `ln -s "<pid> <st>" $LOCK` 在目錄**裡**建連結、回 0 → 自以為拿到鎖(W9)。反向:舊版 `cat $LOCK/pid` 讀不到 → 「stale」→ `rm -rf $LOCK` 刪掉活的 symlink 鎖(W11)。
- 情境 (b):持有者被 KILL 後,兩個 `batman-slot`(例如 helper 的 `write` 重試與 autocommit 的 `commit`)同時讀到同一個死持有者;A `rm` + `ln -s` 成功,B 晚一步 `rm` 掉 A 的活鎖再 `ln -s` → 兩個寫者(現行 `rm -rf; mkdir` 同樣有,W11)。
- 情境 (c):只殺 shell 時子行程 `dd` 還在寫,持有者已被判死(§2.2)。
- 修法(建議,拿掉機制):`batman-slot` 用 `exec 9>$RUNDIR/batman-slot.lock; flock -w 5 -x 9 || rc 14`(W10;kernel 在**最後一個** fd 關閉時才放 → 繼承 fd 的 `dd` 還活著就還算持有;不需要 pid、starttime、zombie、`)` 解析、測試向量、TAMPER、接手;`reboot committed` 的背景安全網要 `9>&-`)。`.busy` 的「持有者活著」改成「`.busy` 存在 **且** 鎖被持有」:shell `flock -n -s 9` 失敗、Go `syscall.Flock(LOCK_SH|LOCK_NB)` 回 `EWOULDBLOCK`(讀者的瞬間共享鎖由寫者的 `-w 5` 吸收)。
- 若保留現設計:`ln -snT`(W9;遇目錄 → 失敗 → readlink 失敗 → 格式錯 = 忙,與 fail-closed 一致),接手寫明是非原子的、並加負對照。
- 測試:兩個 `batman-slot write` 在死持有者後同時啟動 200 次 → 永遠只有一個通過鎖;`$LOCK` 預先是目錄 → rc 14;只 KILL shell、`dd` 仍在 → 另一個 `write` rc 14。負對照:現行 `rm; ln -s` 接手 → 出現兩個持有者。

**m2 租約:「持有到第二遍 + 收到 SIGIO 就中止」是多餘機制;理由文字不對;`EINVAL` 與 reason 的對應**

- lease 取得的那一刻已證明 `i_writecount == 0`(W1);之後 inode 是 root 0400、nlink 0,非 root 新的寫入開啟會先被 `inode_permission` 擋(W4)。所以持有 lease 只多防「root 寫入」,而 root 不在威脅模型裡,且 root 的寫入只會被延後 45 s。SIGIO 在 Go 沒有 `signal.Notify` 時被忽略(W7);要實作「收到就中止」得加整個行程的 SIGIO 處理,而且分不出是哪個 fd。修法:`F_SETLEASE F_RDLCK` 成功後立刻 `F_UNLCK`(或不釋放也行),**刪掉 SIGIO 那句**。
- §3.7.5-1 括號「provd 不能再經 `/proc/self/fd` 以寫入重開」:provd 的 jail 根本沒有 `/proc`(W8)。fchown / fchmod 仍值得留(將來 jail 加 `procfs` 時的縱深),理由改寫。
- 寫明 `EINVAL`(`leases-enable=0`,W2)也走「拿不到」。`EAGAIN` 時上傳檔已被 unlink,app 的補救是重開窗、重傳 —— 回 reason 21(「節點端現在無法寫入槽」)會把 app 導向錯的文字;建議 `EAGAIN` 回 15(上傳不完整 / 被改),`EINVAL` 才回 21。
- 測試:既有的保留 fd 臂;加一臂 `sysctl fs.leases-enable=0`(root、bench)→ reason 21、目標槽沒動。

**m3 namespace 副作用只寫了 boot FAT;`write` / `arm` 裡還會掛 p5(ext4)與 p7**

- `node_checks` 在 helper 的私有 namespace 裡 ro,noload 掛 p5,`batman-config-save --check` 也掛(W12)。init namespace 的 `/proc/mounts` 看不到;config-save 的診斷與 `--reformat` 守門都看 `/proc/mounts`(`batman-config-save:131,299,307`)。同一 superblock 的 ro / rw 衝突(#202 T11)與現在一樣由 config-save 重試處理,`mke2fs` 被 bdev 獨占擋住 → 沒有新的資料風險,但 §3.7.3 / §7 應列出 namespace 裡所有掛載(target FAT、p5、pi3 的 p7),說明「其他 namespace 看不到、同一 sb 行為與今天相同」。
- 測試:`write` 期間(接縫暫停在 `node_checks` 掛 p5 後)跑 `batman-config-save --save` → 重試後成功或明確 rc,不留下 `cfgsave-mount.failed` 讓下一次 OTA 被擋。

**m4 過渡版經 `signrel.py` 簽,繞過 `release-sign.sh` 的拒簽檢查**

- 過渡版是所有 DEV 節點轉成 PROD 信任後的第一個 image,但它不經 `release-sign.sh`(§3.7.2),所以沒有「拒簽 dirty / wbox / 非 `rel`、在 payload 的 squashfs 上重跑 stamp 檢查、`check-release-key-gate.sh` 與 prov-test gate」。
- 修法:`signrel.py` 加 `--transition`,跑同一組檢查(或 `release-sign.sh --root-test` 改用 T→K_test 簽、其餘檢查共用)。測試:dirty / wbox / 內建 T 的 `rel` payload 以 `--transition` → 拒簽。

**m5 bulk tmpfs 沒掛上時,`/tmp` 上的普通目錄仍 rw 進 jail → 被入侵的 provd 可塞滿 `/tmp`**

- `fstatfs` 只擋 `bulk.open`。若 init 掛載失敗後照樣 `procd_add_jail_mount_rw /tmp/run/batman-provd-bulk`,provd 隨時能寫那個目錄,上限是整個 `/tmp`(RAM 的一半),會壓到 RunDir、log、procd —— 比 `size=` 的界線大得多。
- 修法:init 掛不上時**不加** rw 掛載(或把目錄留成 root 0755,provd 寫不進去)。測試:接縫讓 mount 失敗 → provd(uid 471)在該路徑建檔 → `EACCES` / `EROFS`。

**m6 還沒跟上的文字**

- §4 清理表「上傳檔 / 失敗:helper 刪(`bulk.close`、窗到期且沒有 worker、**prepare 發現不符**)」≠ §3.8.2「prepare 失敗**不**刪」(A11-m8)。
- §3.7.5-7「`write` 回 rc 14 … 目標槽沒動」:第二次 `tboot_open`(複製 boot 檔時)的 rc 14 發生在 `begin_write` 之後,槽已 BAD。重試仍正確(`begin_write` 冪等),只改文字。
- §3.7.2「`github-release.yml` 讀每個板子 artifact」→ 照 MAJOR-1 改。

## 5. 確認沒問題的部分(✅)

- 租約對被入侵 provd 的所有寫入路徑(§2.1 表,W1–W8)。
- 鎖 / `.busy` / RunDir 非 root 寫不到;格式錯 = 忙只可能來自 root 或版本混用(fail-closed)。
- `clear_root` 的長度實質上被簽章鎖定(§2.3)。
- DEV / 過渡版對 DEV 節點的風險沒有增加(T 本來就公開)。
- bearer:產生、傳遞(只有 uid 471 的 socket)、格式、空值、constant-time。
- `fstatfs` 能分辨掛載點(`st_dev`),非 root 無法在 helper 的 namespace 裡掛東西。
- `Unshareflags` 失敗 → exec 失敗 → reason 21;KILL 後掛載隨 namespace 消失。
- 白名單 tar、兩遍、SUMS 名字規則、版本規則、key 6 / 7 / 8、判讀表、`rebooting` 時機、啟動時 disarm 條件 —— 本輪重看沒有新問題。

## 6. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 6 MINOR)。**

- v7.6 的核心新機制(讀取租約)成立,我找不到被入侵的 provd 繞過它的路;它還能再簡化(m2)。
- MAJOR-1:使用者明確決定「R 之前不發公開 release」,但設計把檢查放在 firmware workflow,而 Batman 的公開 release 實際上是手動上傳到 Batman repo。這是 B11-MAJOR-2 同一個後果(信任公開 T 的 image 流到現場),修法是把同一支檢查搬到真正的發布路徑。
- m1 建議用 `flock` 取代 pid / starttime / zombie / symlink / TAMPER 整組(拿掉機制,同時修掉接手競態與孤兒 `dd`)。

依規則,MAJOR 改完後整份再審。
