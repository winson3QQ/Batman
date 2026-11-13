# 254-p3-impl v7.6(2f7526e)審查 A — 正確性優先(S5 整份)

範圍:§3.1-5/7、§3.7、§3.8、§3.11、§12、附錄 E–H,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 / 附錄 D 中 S5 用到的列。只讀,沒改 repo,沒上節點。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 18 MINOR。**

- v7.5 的三個 MAJOR(A11-MAJOR-1、B11-MAJOR-1、B11-MAJOR-2)都關了。前兩個我對過原始碼;B11-MAJOR-2 的發布點檢查在 `build-release.yml` 的 release job 成立,但 `github-release.yml` 沒有 artifact 可讀,`publish-packages` job 與手動 `gh release` 也不在範圍內(m14,要使用者決定範圍)。
- 這輪整份重看,沒有找到會讓「舊槽不能用」或「未驗證內容被寫入 / arm」的路徑。我追過的路徑最後都停在三種狀態之一:目前槽可用而目標槽 BAD、目標槽沒動、或沒有 arm。
- 剩下的都是 MINOR。最值得先改的四項:
  - m1:`arm` 要寫明拿鎖;
  - m2、m3:tryboot 旗標在三個角落會被留著 arm,沒有人處理;
  - m5:`precheck-node` 被殺時會把 p5 的唯讀掛載留下來,本次開機的 p5 存檔因此全部失敗。這一項更正我自己在 A11-m15 的建議。

---

## 0. 我自己核對過的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | `check_conflicting_open`:F_RDLCK 只看 `inode_is_open_for_write` → `-EAGAIN`;owner 不符時要 CAP_LEASE;`leases_enable` 預設 1、`lease_break_time` 45 | kernel 6.6.138 `fs/locks.c:1684-1696`、`:1877`、`:93-94` |
| V2 | read lease 只會被「以寫入模式 open」(`fs/open.c:920` `break_lease(…, f_flags)`)與 truncate(`:106`)打斷;斷約訊號送給設約者 TGID | `fs/open.c:106,920`;`fs/locks.c:540` |
| V3 | `CONFIG_FILE_LOCKING=y`(generic,兩板共用) | `target/linux/generic/config-6.6:2015` |
| V4 | Go 1.26.4 的 SIGIO = `_SigNotify`;沒有 `signal.Notify` 時 sighandler 直接 return(忽略) | `go-1.26/src/runtime/sigtab_linux_generic.go:39`;`signal_unix.go:735-755` |
| V5 | helper 是 S89、不進 jail、沒有 capabilities 限制(可以 fchown / setlease / unshare);provd 是 S92(init 在這一步掛 tmpfs) | `batman-provhelper.init:4,10-17`;`batman-provd.init:6,12-25` |
| V6 | 現行 `slot_lock`:`mkdir` 之後才 `echo $$ > pid`;接手是 `rm -rf` 再 `mkdir`(非原子);EXIT trap 只清 MBR 快取、`.busy`、鎖 | `batman-slot:84-96`、`:157` |
| V7 | `node_checks` 在 init namespace 以 ro,noload 掛 p5 到 `/mnt/p5seed.$$`,最多重試 3 次、每次 sleep 1;EXIT trap **不卸** p5 | `batman-slot:556-572`、`:157` |
| V8 | config-save:有 ro 讀者佔著 p5 時,rw 掛載會「成功但其實是唯讀」→ 重試後失敗 | `batman-config-save:36-37`、`:360-378` |
| V9 | `stage-root` 的順序是 slot_lock → precheck → begin_write → clear_root;precheck 先跑 node_checks 再寫 `.busy`;clear_root 把 SQ_MB+64 MiB 清成 0 | `batman-slot:641-657`、`:593-639` |
| V10 | 新動詞要加進 dispatch:`detect_layout` 與 TRACE 的 case 只列了既有動詞 | `batman-slot:895-898` |
| V11 | 鎖的內容只有 autocommit 讀(`:86` `cat lock/pid`,與 batman-slot 同一個套件)。harness 不讀內容(只在 `scripts/rundir-paths.txt:23` 列了名字);`chain1-254.sh:224` 跑的舊 wsl.9 副本只呼叫 `precheck-node`,不拿鎖、不寫 `.busy` | grep 結果 |
| V12 | `provstore.Exec`:`c.Stdin` 由 goroutine 複製;pgid 規則是 TERM,10 s 後 KILL;`WaitDelay` 5 s | `provstore/exec.go:19-46` |
| V13 | `github-release.yml` = tag `v*` → `softprops/action-gh-release@v1`(draft、prerelease、**沒有 files、沒有 artifact**) | `firmware/.github/workflows/github-release.yml` 全檔 |
| V14 | `build-release.yml`:`publish-packages` 與 `release` 兩個 job 並列(都只 needs build);release 下載 `firmware-*`、附 `*.img.gz`、建 draft;五個板子 | `build-release.yml:78-98`、`:148-259` |
| V15 | `batman-build.txt` 只有 bcm2711 / bcm2710 的 artifact 有;halowlink2 / hd01 / venice 沒有 | `build-firmware.yml:210-222` |
| V16 | busybox `flock`、`readlink`、`ln` 都在(預設設定;bcm2711 rootfs 有 `/usr/bin/flock`) | `.config:754,786,1063`;`root-bcm27xx/usr/bin/flock` |
| V17 | autocommit.log 只追加、沒有輪替;`TRIAL-REVERTED` / `COMMITTED` 行的第一欄是型別,後面帶 `slot=$SLOT version=$(version)`(試用的那一版) | `batman-autocommit:65,239,554,568`;`95-batman-storage:460-483`(只有 FW-OVERRIDE*) |
| V18 | autocommit 的 commit 拿不到鎖時會重試(不會退回) | `batman-autocommit:553-557` |

---

## 1. v7.5 的發現:真的關了嗎

| 發現 | v7.6 | 判定 |
|---|---|---|
| A11-MAJOR-1 `write` 漏了 `clear_root` | §3.7.3 照 `stage-root` 的順序,precheck 全部項目都在(含 Pi 3 允許清單、刪 skip-once、寫 `.busy`);§8 與 §12.5 有負對照 | ✅(V9) |
| B11-MAJOR-1 保留寫入 fd | unlink → fchown/fchmod → `F_SETLEASE F_RDLCK` → 再 fstat(nlink 0、大小) | ✅ V1、V2:有寫入 fd 或可寫的共享 mmap(vma 持有 FMODE_WRITE 的 file)→ EAGAIN;設約之後,非 root 拿不到寫入 fd(inode 已是 root 0400,`may_open` 在 `break_lease` 之前就擋下);硬連結繞道會被 nlink 0 的檢查與權限擋住。殘留:SIGIO 是不必要的機制 → m9 |
| B11-MAJOR-2 發布點 | `--publish`,`build-release.yml` 與 `github-release.yml` | ⚠️ release job 成立。`github-release.yml` 沒有 artifact(V13);`publish-packages` 沒擋;非 bcm 板子沒有 stamp;手動 `gh release` 不在範圍內 → m14 |
| A11-m1 arm 失敗後 disarm 會取消操作員的 arm | arm 失敗、啟動時 disarm 之後都清 `apply_boot_id` | ✅;但 disarm 本身失敗時也會被清 → m2 |
| A11-m2 `rebooting` 的 2 s 窗 | arm 回 0 就立刻寫 | ✅;寫入失敗沒定義 → m4;「寫了之後沒有重開」沒寫成界線 → m3 |
| A11-m3 bearer 經 poll 的延遲 | §3.11-12:10 s 內重試 | ✅ |
| A11-m4 | 由 B11-MAJOR-1 取代 | ✅ |
| A11-m5 孤兒 `write` | rc 14 60 s 後重讀 | ✅;「孤兒占 boot 目錄」放進 batman-slot 的 rc 表不對 → m15 |
| A11-m6 zombie | 看第 3 欄 | ✅ |
| A11-m7 `attempt_boot_id` | 已拿掉 | ✅ |
| A11-m8 刪檔規則三個版本 | §3.8.2 統一成一條 | ⚠️ §4 清理表還有「prepare 發現不符 → 刪」;§6 provd crash 列寫「上傳檔由 helper 刪」→ m6 |
| A11-m9 窗何時關 / `updating` | prepare 回應前 | ⚠️ 被**拒絕**的 prepare 關不關窗,沒寫 → m6 |
| A11-m10 `bulk.open` 擁有者檢查 | §3.8.2 | ✅ |
| A11-m11 文字錯誤 | 已改 | ✅ |
| A11-m12 §10 檔案清單 | 已補 | ✅;dispatch / TRACE 漏了 → m16 |
| A11-m13 過渡版 | §3.7.2 | ✅ |
| A11-m14 負對照 | §12.5 已補 | ✅ |
| A11-m15 namespace 的範圍 | write / arm / disarm / bootinfo | ⚠️ 我當時建議 `precheck-node` 留在 init namespace,**這是錯的**(V7、V8)→ m5 |
| B11-m1 鎖與 `.busy` 的原子性 | symlink 鎖、rename、格式錯 = 忙 | ✅ 建立是原子的;接手不是原子(既有問題);「格式錯 = 忙」沒有出路 → m11、m12 |
| B11-m2 starttime 測試向量 | §3.7.3、§12.5 | ✅ |
| B11-m3 namespace 副作用 | §3.7.3、§7 | ✅ |
| B11-m4 bearer 格式 | §3.8.2 | ✅ |
| B11-m5 兩遍與 boot 檔 | §3.7.5-5 / 6 | ✅ |
| B11-m6 tmpfs 檢查 | `bulk.open` fstatfs + st_dev | ✅;dirfd 什麼時候開沒寫 → m13 |
| B11-m7 舊文字 | 已改 | ✅ |

---

## 2. MAJOR

沒有。

## 3. MINOR

**m1 `arm` 沒寫「拿鎖」→ 啟動時的 disarm 可能和孤兒 arm 交錯,旗標被留著 arm。**
- 情境:`update.apply` 寫好 `apply_boot_id` → `arm` 子程序在跑(它有自己的 pgid)→ helper crash → procd 把 helper 重新拉起 → 啟動時看到 `apply_boot_id` = 本次且沒有 `rebooting`,於是 `disarm`,成功後清掉 `apply_boot_id`。如果 `arm` 不拿鎖,孤兒 arm 可能在 disarm **之後**才做 SET → 旗標 = 1,而 `apply_boot_id` 已清掉,再也沒有人處理。下一次任何重開(看門狗、操作員、autocommit 以外的原因)都會開進試用。
- 證據:§3.7.3 動詞表裡 `disarm`、`bootinfo` 寫了「拿鎖」,`write` 經由 `stage-root` 的順序也拿鎖,只有 `arm` 沒寫。現行 `apply` 的 arm 段落是在 `cmd_apply` 開頭的 `slot_lock` 底下跑的(`batman-slot:660`)。`arm` 也會掛目標 FAT(讀 BAD / cmdline / VERIFIED),依「boot 分割只有持鎖的 batman-slot 掛」本來就要拿鎖。
- 修法:動詞表的 `arm` 列加「拿鎖」。這樣孤兒 arm 跑完前,disarm 會拿到 rc 14,下一個 tick 再試。
- 測試:接縫讓 `arm` 在 SET 之後停 20 s → 殺 helper → 新 helper 的 disarm 拿到 rc 14,等 arm 結束後成功,旗標讀回 0。負對照:arm 不拿鎖 → 旗標讀回 1。

**m2 disarm 失敗時,`apply_boot_id` 也照樣被清掉。**
- §3.7.4 寫的是「arm 回非 0 → `disarm`、清掉 `apply_boot_id`」。但 arm 的 rc 可能是 124 / 137(SET 之後才逾時)。這時 disarm 可能拿到 rc 14(arm 還在 D 狀態、還持鎖)。如果仍然清掉 `apply_boot_id`,就和 m1 一樣,留下一個沒人處理的 arm。
- 修法:只在 disarm 回 0 之後才清;disarm 不是 0 時保留 `apply_boot_id`,交給「啟動時 disarm」同一條 tick 重試路徑處理。條件裡要另外加「helper 記憶體裡沒有進行中的 apply」,避免活著的 helper 自己取消自己。

**m3 寫了 `rebooting: true` 之後沒有重開:旗標一直留著,status 先報 3、後報 23,兩個都不對。**
- 情境:arm 回 0 → 寫 `rebooting: true` → 回應 → 在 2 s 的計時器到之前,helper crash 或被 `/etc/init.d/batman-provhelper restart`。啟動時因為 `rebooting` 為 true 而不 disarm → 旗標一直留著。status:pending 還有效時第 4 列報 3(「可以 apply」);pending 到期後第 10 列報 23(「已寫入但沒有啟用」)。實際上,下一次任何原因的重開都會開進試用。
- 我在 A11-m2 說過這種情況可以接受,但 v7.6 既沒有把它寫成界線,也沒有處理。
- 修法(擇一):
  - (a,建議,拿掉一個條件)啟動時只要 `apply_boot_id` = 本次開機就 disarm,並寫 `rebooting: false`、清 `apply_boot_id`。最壞的情況是 helper 剛好在 `reboot committed` 執行中被重新拉起,這次試用被取消 → 回到舊槽,status 23。這是 fail-safe。A11-m1 的情境不受影響,因為 arm 失敗時本來就清了。
  - (b)把它寫進 §3.7.4 與 §6 的誠實界線,並寫清楚 app 看到 3 或 23 時的意義。
- 測試(a):接縫在「寫 `rebooting`」與「reboot」之間殺 helper → 旗標讀回 0、status 23。負對照:保留 `!rebooting` 條件 → 旗標讀回 1。

**m4 `rebooting: true` 寫不進去(p6 變唯讀 / 滿)時怎麼辦,沒有定義。** 這時 arm 已經成功。建議照「`reboot committed` 失敗」那一條處理:`disarm` → 清 `apply_boot_id`(寫不進去也沒關係:磁碟上的 `apply_boot_id` = 本次、`rebooting` 為 false,下一次啟動會再 disarm)→ 回 `E_STORAGE`。

**m5 `precheck-node` 在 init namespace,被 TERM / KILL 時會把 p5 的 ro 掛載留下 → 本次開機 p5 的存檔全部失敗。這一項更正我的 A11-m15。**
- 情境:`update.check` 第 3 步呼叫 `precheck-node`。`node_checks` 在 init ns 把 p5 以 ro,noload 掛到 `/mnt/p5seed.$$`,最多 3 s(V7),接著還有 `batman-config-save --check`。helper 的期限到了(§3.7.5-7 沒有列 `precheck-node` 的期限)→ TERM:batman-slot 新的 `trap 'exit 143' TERM` 會跑 EXIT trap,但 EXIT trap 不卸 p5;KILL 就更不用說。之後 config-save 的 rw 掛載會「成功但其實是唯讀」→ 失敗(V8)→ 本次開機的 `--save` / `--on-join` 全部失敗、p5 stale、OTA 被 rc 12 擋住、`settings.set` 回 `E_STORAGE`。
- 修法(拿掉一個例外,不加機制):`precheck-node` 也用 `CLONE_NEWNS` 執行,期限 60 s。被殺時掛載隨 namespace 消失,config-save `--check` 的子程序也一樣。留在 init ns 的只有 `reboot committed`(要撐過關機)與 `is-trial`(不掛載)。我在 A11-m15 建議 `precheck-node` 照舊,是錯的。
- 測試:接縫讓 `precheck-node` 在掛上 p5 之後停 → 期限 → KILL → `/proc/mounts` 沒有 p5 的第二個掛載,接著 `batman-config-save --save` 成功。負對照:在 init ns 跑 → `rw mount came up read-only`(`batman-config-save:369`)。

**m6 窗、prepare、刪檔:還有三處互相矛盾(A11-m8 / m9 的殘留)。**
- §3.8.1 寫「窗開到 `update.prepare` 開始」,§3.7.5-1 寫「窗在 prepare 回應前處理好」,但被**拒絕**的 prepare(同步的 15:大小不符,這是「手機斷 Wi-Fi」的正常路徑)關不關窗,沒寫。
  - 如果關:§3.8.2「prepare 失敗不刪,app 直接重 PUT」不成立(PUT 會得到 409,檔案也會被下一個週期刪掉),app 要先重送 `bulk/open`,這時是新窗、新 bearer。
  - 如果不關:prepare 的「呼叫者 = 上傳窗擁有者」才有意義。
  - 修法:寫明「prepare 通過同步檢查、要啟動 worker 時才關窗;被拒絕的 prepare 不關窗」。
- §4 清理表「上傳檔 / 失敗或到期」還寫著「prepare 發現不符 → helper 刪」,要刪掉。
- §6「provd crash / crash loop」寫「上傳檔由 helper 刪」:依 §3.8.2,provd crash 時窗還開著,會在下一次 poll 取回 bearer,所以不刪。改成「窗與 bearer 不變;未完成的 PUT 從頭重傳;窗到期後才刪」。

**m7 同一位擁有者在 worker 執行中重送 `bulk.open`,會在 worker 期間開出新窗。**
- §3.1-7 的 `otaBusy` 只擋「另一位擁有者」的 `bulk.open`。同一位擁有者在 worker 期間送 `bulk.open`(例如 app 重試)→ 開出新窗:
  - status 第 1 列(窗開著)排在第 2 列(worker 在跑)前面,app 看到的是 phase 1,看不到 worker 的進度;
  - app 照 status 再 PUT 一份 126 MB(tmpfs 與 RAM 多一份);
  - worker 結束後如果再 prepare,會重寫一次剛驗過的槽。
- 修法:worker 在跑時,`bulk.open` 一律回 `E_BUSY`(§3.1-7、§5.1 各加一句)。

**m8 在 poll 延遲(≤ 4 s)內開始的 PUT,會在 worker 期間繼續寫到結束。**
- 409 的檢查只在 PUT 開始時做。prepare 關窗之後、provd 下一次 poll 之前,手上有 bearer 的 AP 鄰居可以開始一個 PUT,建出新 inode,一路寫到 126 MB。這時 worker 手上還握著已 unlink 的那一份 → RAM 多佔一份 payload,而 RAM 預算只算了一份(§3.7.4)。在 2 GB 的 TAK 節點上會把餘裕吃掉。上限仍是 `size=`,所以只是 DoS。
- 修法(不加新東西):provd 在 poll 看到「沒有窗」時,中止進行中的 PUT 並關檔。§7「同 AP 上知道 AP 密碼的人」那一列補一句。
- 測試:窗關之後 2 s 內開始的 PUT,在下一次 poll 後 ≤ 4 s 內被中止;tmpfs 用量回到 0(worker 那一份已 unlink,不在目錄裡)。

**m9(拿掉機制)「收到 lease break(SIGIO)→ 中止」不需要。**
- 能打斷 read lease 的只有「以寫入模式 open 這個 inode」或 truncate(V2)。inode 已經 unlink、是 root 0400,provd 也沒有 fd,所以只有 root 做得到,而 root 本來就能做任何事。
- Go 預設忽略 SIGIO(V4),要接住它得加 `signal.Notify` 的配線,還要處理和 45 s `lease_break_time` 的互動。
- 修法:租約只當作「此刻沒有任何寫入者」的原子探針,拿到後一直持有到 fd 關閉;刪掉 SIGIO 那一句。§12.5「讀取租約」的負對照不變。

**m10 worker 遇到 rc 14 重試時,要從 `lseek(0)` 重新走第二遍。**
- `ExecReader` 的 stdin 由 goroutine 複製(V12)。`batman-slot write` 在讀 stdin 之前就以 rc 14 結束時,串流可能已經被吃掉一段(pipe 緩衝 64 KiB 加上 tar / gzip 的預讀)。
- §3.7.5-7 只寫了「以同一個 fd 重試」,要寫明每次重試都 `lseek(0)` 並從頭重跑第二遍。
- 另外寫一句:`ExecReader` 必須同時把 stdout / stderr 讀走(用 `cmd.Stdout` / `Stderr` 的 buffer,不要自己用 `StdoutPipe` 且不讀),否則 `clear_root` 那段時間 Go 卡在寫 stdin、batman-slot 卡在寫 stderr,會一直耗到 600 s 期限。

**m11「格式不對 = 忙」沒有出路,而且每次讀都記 TAMPER。**
- 鎖或 `.busy` 格式不對時:`node_checks` 回 rc 14 → 永遠走不到 precheck,沒有人會覆寫它 → 本次開機的 OTA 都被擋住,`otaBusy` 讓 `settings.set` 與 `network/*` 一直回 `E_BUSY`,直到重開或 root 手動 `rm`。
- 誰會寫出格式不對的內容:只有 root,或者寫入端自己的 bug(例如讀 `/proc/$$/stat` 失敗,寫出 `"1234 "`)。
- 修法:
  - (1) 寫入端建立前先驗證自己的內容,格式不對就 die(rc 18),不建;
  - (2) §6 加一列「格式不對的鎖 / `.busy`:重開或 root 刪除」;
  - (3) TAMPER 每次開機只記一次(Go 的 `otaBusy` 每個請求都會被呼叫)。

**m12(既有問題;可以選擇拿掉機制)鎖的接手不是原子的。**
- 兩個競爭者同時看到同一個已死的持有者時:A `rm`、A `ln -s` 成功 → B `rm`(刪掉的是 A 剛建的鎖)→ B `ln -s` 成功 → 兩個寫者並行。現行 `rm -rf; mkdir` 也有一樣的問題(V6)。§3.7.3 的「原子出現」只對**建立**成立。
- 要發生必須同時滿足:持有者被 SIGKILL,而且兩個競爭者在同一個毫秒內出現。helper 自己的呼叫有 `slotMu` 序列化,所以機率低。
- 選項:
  - (a)寫成已知界線;
  - (b)改用 kernel 的 `flock`(busybox 有,V16):持有者死掉時(包括它還在寫的 `dd` 孫行程)kernel 會自動釋放,starttime 解析、zombie、格式錯、接手、TAMPER 全部都不需要了。讀者用 `flock -n -s` 試探;寫者用 `flock -w` 等幾秒,避免和讀者的瞬間試探撞到。
  - 這是 v7.6 之後唯一能大量拿掉機制的地方,但改動範圍比 (a) 大,交給使用者決定。

**m13 bulk 目錄的 dirfd 要在每次操作時開;「每個 poll 週期」的刪除要在 helper 自己的週期跑。**
- helper 是 S89 啟動、provd 的 init 在 S92 才掛 tmpfs(V5)。helper 如果在啟動時開 dirfd,拿到的是底下 `/tmp` 的目錄:之後的 `unlinkat` / `openat` 都會落在錯的目錄,`bulk.open` 的 fstatfs 會一直回 reason 21。
- 修法:在 `bulk.open`、刪檔、worker 開檔時各自 `open(O_DIRECTORY|O_NOFOLLOW)`,並和 `bulk.open` 檢查時記下的 `st_dev` 比對。
- 「每個 poll 週期刪」:provd 掛掉時就沒有 poll,窗到期後檔案不會被刪(126 MB 留在 RAM)。改成 helper 自己的 4 s 背景迴圈(§3.8.1 已有)。

**m14 發布點的範圍(使用者決定)。**
- (a)`github-release.yml` 只建一個沒有檔案的 draft(V13),沒有 artifact 可讀 `batman-build.txt`。建議從 gate 與 lint 清單拿掉,或寫明它不帶 image、不算發布。
- (b)`build-release.yml` 的 `publish-packages` 和 `release` 並列(V14),會把 `wsl` build 的套件推到公開的 packages-repo。套件不含 `release-root.pub`(鑰匙由 stamp 放進 image 的 `files/`),所以不是信任問題。但「R 之前不發任何公開 release」包不包括 packages-repo,要使用者決定;包括的話,gate 要放在兩個 job 共同 needs 的一個 job。
- (c)非 bcm 板子的 artifact 沒有 `batman-build.txt`(V15)。照「缺 = FAIL」,R 產生之後 release 仍然會永遠失敗。要寫明 gate 只檢查 `ekh-bcm2711` / `ekh-bcm2710`,或其他板子不出。
- (d)手動 `gh release`(v1.0.0 當時就是發在 Batman repo)不經過任何 workflow。發行 runbook 要加「對要發的 `.img.gz` 跑 `check-release-key-gate.sh --publish`」;轉賣工具的「發行 image 清單」也只收過了這一步的檔案。

**m15 介面契約還有缺口。**
- §2 的 poll `http` 欄位只列了 key 2–5。bearer 的 key 號與格式(16 bytes)、provd 回報已寫 bytes 與 `http_bind_failed` 的方向和欄位都沒寫,§5.3「poll 的 `http` 欄位」那一列指向 §2。
- §5.1 缺的列:
  - `update.check`:pending 屬於另一位擁有者 → `E_BUSY`;
  - `bulk.open`:tmpfs 不對 → reason 21;
  - worker:租約拿不到 → 21。
- §3.11 缺 app 在 prepare 之後看到 phase 0 + 15 / 21 時的處理(重送 `bulk/open` + 重 PUT + prepare),以及 21 的顯示文字。
- §3.7.3 rc 14 列裡的「孤兒占著 boot 目錄」是 helper 端的條件(建目錄時 `EEXIST` → `E_BUSY`),不是 batman-slot 的結束碼,要移到 §3.7.5。
- §4 加一列:worker unlink 之後的上傳檔 inode,擁有者是 helper(root 0400,持有租約)。

**m16 batman-slot 的 dispatch。** `write` / `arm` / `disarm` / `bootinfo` 要加進 `detect_layout` 的 case(`:897-898`,否則 `DISK` 等變數沒有設定)。會改狀態的 `write` / `arm` / `disarm` 也要加進 TRACE(`:895`,OTA flight recorder)。§10 的 `batman-slot` 項目加一句。

**m17 `update.apply` 要不要求「呼叫者 = pending 的擁有者」?** `bulk.open` 與 `prepare` 都要求,`apply` 沒寫(§3.7.4、§5.1)。兩種都說得通(另一位擁有者也同意了同一份已簽章的 image),但要寫明。建議要求,與前兩步一致。

**m18 文字。** §3.7.5-9「`owner/remove` → 目標槽保持 BAD → 第 9 列 22」只對 `begin_write` 之後成立。第一遍(還沒呼叫 `batman-slot`)中止時,目標槽沒動 → 第 11 列 0。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 判定 |
|---|---|
| 目標槽 rootfs / boot / BAD / VERIFIED / overlay 窗、tryboot 旗標、boot 分割的掛載 | ✅ `batman-slot` 持鎖。`arm` 的鎖沒寫 → m1;接手的競爭 → m12 |
| 上傳檔(路徑) | ✅ provd 寫、helper 刪(單一規則)。週期的來源 → m13 |
| 上傳檔(unlink 後的 inode) | ✅ helper(root 0400 + 租約)。§4 沒列 → m15 |
| pending、update-last | ✅ helper `updMu`;update-last 用 tmp → rename |
| `apply_boot_id` / `rebooting` | ✅ 只有 helper 寫。清除條件 → m2、m3 |
| p5 的 ro 掛載(`precheck-node` 期間) | ❌ init namespace 裡可能留下 → m5 |
| `batman-slot.lock` / `.busy` | ✅ 只有 root 寫得到;讀者:autocommit(同一個套件)、Go。harness 不讀內容(V11)→ 舊 harness 讀新格式:沒有影響 |
| nft 表、bit 24、bearer、`http` 欄位 | ✅ 不變 |
| `release-root.pub`、發布 | ✅ build 端;發布點的範圍 → m14 |

## 5. 現場劇本

| 劇本 | 結果 |
|---|---|
| 正常:BLE check → `bulk.open` → 加入 AP → PUT → prepare → worker → apply → 試用 → commit | ✅ 一路對過:prepare 檢查大小、寫嘗試紀錄、關窗;worker 租約 → 第一遍 → 第二遍串流 → `write`(含 clear_root)→ VERIFIED;apply 前提看槽 → arm → rebooting → 重開 → autocommit → 第 7 列 5 |
| 上傳中斷 / 手機斷 Wi-Fi | ✅ 從頭重 PUT。被拒絕的 prepare 關不關窗 → m6 |
| PUT 已寫完、200 遺失,app 接著 prepare | ✅ provd 回 200 之前已關檔 → 租約拿得到 |
| 每一步斷電 | ✅ 第一遍中 → 0;`begin_write` 之後 → 22;VERIFIED 寫完 → 23(下次開機 arm 不認舊的 boot_id);arm 之後 → 試用一次 |
| 新版不健康 | ✅ TRIAL-REVERTED 行帶 to_slot / to_version(V17)→ 6;沒有那行 → 6 + 18 |
| 同版本重裝 | ✅ clear_root,overlay 是新的 |
| 兩位擁有者 | ✅ 窗 / pending / prepare 互斥;apply 的呼叫者 → m17;同一位擁有者在 worker 中重開窗 → m7 |
| 移除擁有者 | ✅ worker 中止;第一遍中止時 status 的說法 → m18 |
| 成員 | ✅ 沒有 `update/*` 與 `bulk/*`;窗期間 HTTP 不收成員 |
| 降級、跨通道 | ✅ key 6 / key 7 規則;P3 之前的 payload 不能經 app 裝(界線) |
| helper crash:check / 窗 / 第一遍 / `write` / arm / rebooting 之後 | ✅ 前五種都停在 0 / 22 / 23 或已 disarm;arm 的鎖 → m1;rebooting 之後 → m3 |
| provd crash:PUT 中 / worker 中 | ✅ 重新取得 bearer、重 PUT;§6 的文字 → m6 |
| 孤兒 `write`(helper 死掉) | ✅ stdin EOF 或 SIGPIPE → 讀回失敗 → BAD;已經串完的話寫 VERIFIED → 新 helper 回 phase 3(正確) |
| 同時 sysupgrade(無 -F) | ✅ worker 執行 `write` 期間 rc 14;第一遍期間 stage 1 會通過,但 stage 2 會殺掉所有行程 → 由 sysupgrade 寫槽(操作員優先,可接受) |
| 同時 sysupgrade -F | ✅ stage 2 殺掉 helper 的 `write` → namespace 跟著消失;ramfs 裡 pid 重用 → starttime 不同 → 接手 |
| 操作員手動跑 `batman-slot` | ✅ 鎖互斥;worker 重試 3 × 10 s 後 21。重試的串流位置 → m10 |
| 舊 autocommit / harness 讀新的鎖格式 | ✅ 唯一的內容讀者是同一個套件裡的 autocommit(§10 已列 `:79-86`);wsl.9 副本只跑 `precheck-node`(V11) |
| `precheck-node` 被殺 | ❌ p5 掛載外洩 → m5 |
| bcm2710 | 只編譯(使用者決定);`write` 有 Pi 3 允許清單(precheck) |

## 6. 生命週期矩陣缺的列

- 寫了 `rebooting` 之後 helper 重啟、沒有重開(m3)
- `precheck-node` 被殺(m5)
- 格式不對的鎖 / `.busy`(m11)
- provd crash 那一列的文字要改(m6)

其他列(安裝、啟動、停止、重開、升級 / 回滾、降級、crash loop、斷電 / 斷網、依賴重啟、平台)都有,也和 §3 一致。

## 7. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 18 MINOR)。**

v7.6 的三項修正都對:clear_root、讀取租約、發布點。我對過的 kernel 與 Go 行為都支持租約的保證(V1–V4),而且租約只是一次原子檢查,不是新的常駐機制。

18 項 MINOR 都是文字補齊或單句修正,沒有一項要加新的元件。其中有幾項是拿掉東西:
- m3(a) 拿掉 `!rebooting` 條件;
- m5 拿掉 `precheck-node` 的 init namespace 例外;
- m9 拿掉 SIGIO;
- m12(b) 改用 flock,可以拿掉整套持有者規則。

建議實作前先改 m1–m6(都會影響「旗標」或「p5」的實際狀態)。m14 需要使用者決定 packages-repo 與手動發布的範圍。
