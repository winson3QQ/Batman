# 254-p3-impl v7.7(4aacc47)審查 A — 正確性優先(S5 整份)

範圍:§3.1-5/7、§3.7、§3.8、§3.11、§12、附錄 E–I,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 / 附錄 D 中 S5 用到的列。只讀:沒改任何 repo,沒上節點。原始碼:`/home/yello/Batman-p3` @ 4aacc47(工作樹乾淨)、`/home/yello/firmware-2710`(02f0913d;busybox 1.36.1、kernel 6.6.138、Go 1.26)。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 15 MINOR。** 依規則,MAJOR 修完後整份再審。

- v7.6 的發現(A12 18 項、B12 1 MAJOR + 6 MINOR)大部分確實關了。flock 取代整組持有者規則是對的方向:原子、行程死就放鎖、孫行程 `dd` 還在寫時鎖仍在,我對過 kernel 與 busybox。
- **MAJOR-1(v7.7 新帶進來的)**:sysupgrade stage 2 跑在 ramfs 裡,而 ramfs 裡**沒有 `flock`**。`stage-root` / `apply` 一律拿不到鎖 → rc 14 → 每一次 ssh sysupgrade 都會在 stage 2 靜默失敗、重開回舊槽。設計還寫著「sysupgrade 路徑行為不變」。修法是一行(`RAMFS_COPY_BIN` 加 `/usr/bin/flock`),但沒寫進設計就一定會漏:`platform-ab.sh:24-30` 的註解記錄過同一類事故(#89 `tr` 缺、apply 中止)。
- 其他都是 MINOR。最值得先改的四項:
  - m1:讀者以 `flock -n` 試拿,會讓寫者的 `flock -n` 偶發失敗;
  - m2:`commit` 的背景子程序帶著鎖;
  - m3:disarm 的重試與進行中的 apply 會互相踩到;
  - m4:多處還是 `.lock` / `.busy` / 持有者規則的舊文字。

---

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | 兩板 rootfs 都有 `/usr/bin/flock -> ../../bin/busybox`;busybox `CONFIG_FLOCK=y`;busybox flock 只有 `-sxun`(**沒有 `-w`**) | `build_dir/target-aarch64_cortex-a72_musl/root-bcm27xx/usr/bin/flock`、a53 同;`busybox-1.36.1/.config:628`;`util-linux/flock.c:16-23,49` |
| V2 | **sysupgrade stage 2 的 ramfs 只裝固定清單 + `RAMFS_COPY_BIN`**,清單裡**沒有 flock**;`install_bin` 依 `command -v` 找路徑後複製或建 symlink | firmware `package/base-files/files/lib/upgrade/stage2:39-55`;`common.sh:8-36` |
| V3 | Batman 的 `RAMFS_COPY_BIN` = batman-slot、batman-reboot、vcmailbox、hexdump、tr、sha256sum、head、tail、cut、cmp、mktemp —— **沒有 flock** | `platform-ab.sh:38` |
| V4 | busybox ash 只在 `FEATURE_SH_STANDALONE` 時把 applet 當內建;這個 build 沒開(`PREFER_APPLETS=y` 只影響 `BB_EXECVP`,ash 的 `tryexec` 直接 `execve` PATH)→ ramfs 裡 `flock` = 127 | `.config:33,1198`;`shell/ash.c:8256-8280`;`include/libbb.h:1216-1222` |
| V5 | stage 2 的 `_ab_do_upgrade` 在 ramfs 裡呼叫 `batman-slot stage-root` 再 `batman-slot apply`,rc ≠ 0 → `return 1` → stage 2 一般重開回原槽 | `platform-ab.sh:364-379`;`:24-30` 的註解(#89:ramfs 缺 `tr` → apply 中止) |
| V6 | flock 鎖掛在 open file description 上,最後一個參照關閉(`__fput`)才 `locks_remove_flock` → fork / dup 繼承的子程序活著就仍持有 | kernel 6.6.138 `fs/file_table.c:376`、`fs/locks.c:2627-2642` |
| V7 | `commit` 在持鎖中背景啟動 `setsid /etc/init.d/openmanetd start &`(會繼承 fd);openmanetd init 是 procd 註冊,很短 | `batman-slot:753-784`(`:781`);rootfs `/etc/init.d/openmanetd` |
| V8 | 產品已有的 fd 9 flock 慣例:`halow-setkey` 用 `exec 9>…; until flock -n 9; do sleep 1` 輪詢(註解寫明 busybox 沒有 `-w`),而且每個可能活得比它久的子程序都 `9>&-` | `halow-setkey:144-155,184,223,226`;`payload-stop.sh:34` |
| V9 | `.busy` / `batman-slot.lock` 的讀者:autocommit `:86`(`slot_writer_alive`,被 `:213`、`:226`、`:550` 用)、Go `otaBusy`(`node/wtxn.go:450-454`,被 `node.go:247` 用)、Go 測試 `wtxn_v10b_test.go:59`、`p3review_test.go:147`(建 `.busy` 檔)、harness `scripts/rundir-paths.txt:23-24` | grep |
| V10 | 會因為「另一個持鎖者」拿到新 rc 14 的 harness 呼叫(rc ≠ 0 就 FAIL):`daily-validation.sh:2067-2069`、`setkey-persists-202.sh:65`、`p5-follows-202.sh:121`(precheck-node,**v7.7 新上鎖**);`negctl-old-slot-254.sh:29`、`ab-selftest.sh:325`(rollback);`fault-injection.sh:426`(commit) | grep |
| V11 | joinwatch:沒入網 ≥ `t_reboot`(預設 3600 s)而且 `reboot_helps` → `batman-slot reboot committed`。這條路**不看任何 slot 寫入狀態** | `joinwatch:37,97-100,171-196` |
| V12 | Go `Unshareflags & CLONE_NEWNS` → 子程序裡 `mount("none", "/", MS_REC\|MS_PRIVATE)`;`syscall.Flock` 在 linux/arm64 存在 | go-1.26 `syscall/exec_linux.go:473-478`;`zsyscall_linux_arm64.go:452` |
| V13 | firmware `build-release.yml`:五個板子(bcm2711、bcm2710、halowlink2、hd01-v2、venice);`publish-packages` 與 `release` 都只 `needs` 五個 build;`batman-build.txt` 只在 bcm2711 / bcm2710 產生 | `build-release.yml:20-80,148-150`;`build-firmware.yml:209-222` |

---

## 1. v7.6 發現:真的關了嗎

| 發現 | v7.7 | 判定 |
|---|---|---|
| B12-MAJOR-1 / A12-m14 發布檢查不在發布路徑 | `publish-release.sh` + `release-guard.yml` + firmware gate 獨立 job | ✅ 方向對,三條路都有東西擋。殘留:(c) 非 bcm 板子的範圍沒定義 → m13;guard 的觸發缺口 → m12 |
| A12-m12 / B12-m1 持有者規則 → flock | §3.7.3 | ✅ 機制本身成立(V6)。新洞:ramfs 沒有 flock → **MAJOR-1**;讀者試拿撞寫者 → m1;背景子程序 → m2 |
| A12-m1 arm 拿鎖 | 所有動詞都拿 | ✅ |
| A12-m2 disarm 回 0 才清 | §3.7.4 | ⚠️ 啟動時那條路成立。apply 自己的「arm 失敗 → disarm 失敗」沒有人重試;tick 重試和進行中的 apply 沒有互斥 → m3 |
| A12-m3 rebooting 後沒重開 | 寫成界線(選項 b) | ✅ |
| A12-m4 rebooting 寫不進 | disarm → `E_STORAGE` | ✅;disarm 本身 rc 14 的情況 → m3 |
| A12-m5 precheck-node 進 namespace | §3.7.3 | ✅ |
| A12-m6 窗 / prepare / 刪檔 | §3.8.2、§4、§6 | ✅ |
| A12-m7 worker 中重開窗 | `E_BUSY` | ✅ |
| A12-m8 poll 延遲的 PUT | 接受,「`size=` 已涵蓋」 | ✅ 接受為決定。注意 RAM 預算只算了一份 payload,2 GB 節點那條已經在 checklist |
| A12-m9 / B12-m2 SIGIO | 拿掉 | ✅ |
| A12-m10 重試從 `lseek(0)` | §3.7.5-7 | ✅(stdout / stderr 要同時讀走,仍沒寫,併入 m4) |
| A12-m11 格式錯 = 忙 | 隨 flock 拿掉 | ✅ |
| A12-m13 dirfd 時點 | 每次操作才開 | ✅;刪檔週期仍綁 provd 的 poll → m7 |
| A12-m15 契約缺口 | §2 / §5.1 / §3.11 補了 | ⚠️ rc 14 列裡的「孤兒占 boot 目錄」、§4 的 unlink 後 inode 列都還沒改 → m6 |
| A12-m16 dispatch | §3.7.3 | ⚠️ 寫成「都加進 TRACE」,把唯讀的 `bootinfo` 也算進去 → m14 |
| A12-m17、m18 | §3.7.4、§3.7.5-9 | ✅ |
| B12-m2 租約拿不到的 reason | §3.7.5-1 = 15 | ⚠️ §7 與 §12.5 仍寫 21 → m5 |
| B12-m3 / m4 / m5 / m6 | — | ✅ |

---

## 2. MAJOR

**MAJOR-1:sysupgrade stage 2 的 ramfs 沒有 `flock` → v7.7 之後每一次 ssh sysupgrade 都會在 stage 2 失敗**

- **情境**:操作員 `sysupgrade <payload>`。下面三種情況都依賴這條路:
  - 設計明列的出路:P3 之前建的 payload、DEV → PROD、`-F`;
  - 現役 legacy 節點的升級;
  - harness 的 sysupgrade 臂。
- **經過**:
  1. stage 1(live)`precheck-node` 正常,因為 rootfs 有 flock;
  2. procd 殺掉服務,pivot 到 `$RUNDIR/ramroot`;
  3. stage 2 `_ab_do_upgrade` 呼叫 `batman-slot stage-root`(`platform-ab.sh:364`);
  4. 依 v7.7 的 §3.7.3,`stage-root` 開頭是 `exec 9>>…; flock -n 9`。ramfs 裡沒有 `flock`(V2–V4)→ 127 →「拿不到 → rc 14」→ `stage-root refused` → `return 1` → stage 2 一般重開,回到原槽。
- **後果**:
  - 槽本身沒事:鎖在 `begin_write` 之前,屬於 fail-closed;
  - 但**所有 sysupgrade 都裝不上**,操作員只在 stage-2 trace 裡看得到原因;
  - 這也讓設計自己指定的恢復路徑(§3.7.2 的界線「P3 之前建的 payload 只能 ssh sysupgrade」、§6「DEV → PROD … 或 ssh / 重燒」)失效。
- **與設計的矛盾**:§3.7.3 寫「`busybox flock` 已在兩板 build 的 rootfs(⚠️ 節點上待確認)」、「app 的 `write` 在跑時,sysupgrade stage 1 的 `precheck-node` 拿不到鎖」、`apply` 列「sysupgrade 路徑行為不變」;§6「同時 ssh sysupgrade」那一列。這些都只考慮了 rootfs,沒有考慮 stage 2 的 ramfs。§10 的檔案清單也沒有 `platform-ab.sh`。
- **證據**:V2、V3、V4、V5。`platform-ab.sh:24-30` 自己記錄了同一類事故:#89 時 ramfs 缺 `tr`,apply 中止。
- **修法(只加一個路徑,不加機制)**:
  - `platform-ab.sh:38` 的 `RAMFS_COPY_BIN` 加 `/usr/bin/flock`。`install_file` 會跟 symlink,在 ramfs 建 `/usr/bin/flock -> /bin/busybox`,而 busybox 本來就在 ramfs(`common.sh:11-19`、`stage2:40`)。
  - §3.7.3 改寫成「rootfs **與 stage 2 ramfs**」;§10 加 `platform-ab.sh`。
  - 另外寫明「`flock` 不存在」的行為。照 halow-setkey 的做法(`:148`,`command -v flock` 不在 → 拒絕),回 rc 18 而不是 14,讓 log 指向「工具不在」而不是「有人持鎖」。
- **測試 / 負對照**:
  - `prov-update-254` 的 sysupgrade 臂斷言 stage-2 trace 有 `STAGE-ROOT rc=0` 與 `APPLY rc=0`,而且試用開進新槽;
  - 負對照:`RAMFS_COPY_BIN` 不含 flock → `STAGE-ROOT rc=18`(或 14 / 127),目標槽沒動、仍在原槽。
  - 離線也能測:在 chroot 裡只放 stage2 清單 + `RAMFS_COPY_BIN`,跑 `batman-slot stage-root` 到拿鎖那一步。

---

## 3. MINOR

**m1 讀者用 `flock -n` 試拿,寫者也只用 `flock -n` → 試拿的瞬間會讓真的寫者回 rc 14**
- 情境:§3.7.3 規定讀者(Go `otaBusy` 每個 `settings.set` / `network/*` / `update.check` 都會呼叫、autocommit 的 `slot_writer_alive` 每 5–10 s 呼叫)以 `LOCK_EX|LOCK_NB` 拿到後立刻放;寫者 `flock -n 9`,拿不到就 rc 14。兩者同時發生時寫者失敗:
  - autocommit 的 `batman-slot commit` → `ok=0`,重新累積(`batman-autocommit:553-557`);
  - sysupgrade stage 1 → REFUSING;
  - apply 的 `arm` → `E_BUSY`;
  - arm 失敗後的 `disarm` → 留下 m3 的情況;
  - harness → 假 FAIL。
- 機率低(微秒窗),但這是不確定的失敗來源。§12.5 的「外部 `batman-slot commit` 迴圈 200 次與 helper 並行 → 0 次 rc 14」在 helper 同時處理請求時可能會偶發失敗。
- 修法:寫者照 halow-setkey 的輪詢(V8):`n=0; until flock -n 9; do n=$((n+1)); [ $n -ge 3 ] && exit 14; sleep 1; done`。busybox 沒有 `-w`(V1)。讀者維持試拿即放。
- 測試:讀者以 1 kHz 迴圈試拿 60 s,同時 `commit` 200 次 → 0 次 rc 14。負對照:沒有輪詢 → 出現 rc 14。

**m2 持鎖動詞的背景子程序繼承 fd 9**
- `cmd_commit` → `addr_defer_release` 在持鎖中背景啟動 `env -i … setsid /etc/init.d/openmanetd start &`(`batman-slot:781`)。`env -i` 只清環境、不關 fd → init script 跑完前鎖都在(V6、V7)。平常是毫秒級;ubus / procd 卡住時,鎖會一直被持有 → `otaBusy` 一直忙、OTA 一直 rc 14。
- 產品對 halow-setkey 的鎖已有慣例(`9>&-`,V8)。§3.7.3 寫「fd 9 由子程序繼承」是**刻意**要讓 `dd` 繼承,但要寫明例外:
  - 會活得比動詞久的背景子程序一律 `9>&-`(`:781`;以及之後任何 `&` / `setsid`);
  - `reboot committed` 與其他不在清單上的動詞不開 fd 9(否則 `:885` 的 240 s 安全網會帶著鎖進關機流程)。
- 測試:接縫讓 openmanetd init 卡 30 s → `commit` 結束後 1 s 內 `flock -n` 拿得到。負對照:沒有 `9>&-` → 30 s 內拿不到。

**m3 disarm 的重試:apply 中的失敗沒有人重試;tick 的重試會和進行中的 apply 互相踩到**
- (a)`update.apply` 的「arm 回非 0 → disarm,回 0 後才清」與「rebooting 寫不進 → disarm」:disarm 回 14(m1,或孤兒 arm 還在 D 狀態持鎖)時保留 `apply_boot_id`。但 §3.7.4 的重試只寫在「helper 啟動時」那一段。helper 不重啟的話,旗標可能一直 arm 著,下一次任何原因的重開都會開進試用(這個版本有簽章、讀回過、擁有者同意過 → 不是越權,但 app 收到的是 `E_STORAGE` / 失敗)。
- (b)如果把重試做成每個 tick 都檢查「`apply_boot_id` = 本次 ∧ `rebooting` 為 false → disarm」,它會在**進行中的 apply** 寫好 `apply_boot_id`、arm 回 0、還沒寫 `rebooting` 之間成立 → 把使用者的 apply 取消 → 寫 `rebooting: true`、重開,但沒有試用 → status 6 + 18(誤報)。
- 修法:
  - 一條通用規則:「任何 tick:`apply_boot_id` = 本次 ∧ `!rebooting` ∧ 記憶體裡沒有進行中的 apply → disarm」;
  - 寫明 apply 從「寫 `apply_boot_id`」到「寫 `rebooting`」全程持有 `slotMu`(或 `updMu`),tick 的 disarm 也要拿同一把。
- 測試:接縫讓 arm 回 124 且 disarm 第一次回 14 → 下一個 tick 旗標讀回 0。負對照:只在啟動時重試 → 旗標 1。接縫在 arm 成功與寫 `rebooting` 之間停 5 s、tick 期間跑 → 旗標仍是 1。

**m4 flock 換掉之後還留著的舊文字(實作照這些寫會做錯)**
- §3.7.5-7:「鎖與 `.busy` 由持有者檢查回收(§3.7.3)」→ 改為「kernel 在持有者與子程序都結束時釋放」。另外補 A12-m10 的後半句:`ExecReader` 要同時讀走 stdout / stderr。
- §3.7.6:「`.busy`:改用 §3.7.3 的持有者規則(`:226`)」→ 改為 flock 試拿。
- §4 擁有權「目標槽 … `batman-slot.lock` 互斥(F35)」→ `batman-slot.flock`。
- §4 清理表「解出的 boot 檔 / helper 重啟:啟動時刪(`batman-slot.lock` 持有者活著就不刪)」→ 見 m6。
- §5.1「`update.check` | `bootinfo` 拿不到 `batman-slot.lock`」→ flock(而且 `precheck-node` 也會拿不到)。
- §12.5「同時 sysupgrade」的負對照「拿掉 `.busy` 檢查」→「`precheck-node` 不拿鎖」。

**m5 租約拿不到的 reason:三處不一致**
- §3.7.5-1(與附錄 I B12-m2)= **15**;§7「被入侵的 provd / 保留寫入 fd」列 = **21**;§12.5「讀取租約」負對照 = **21**。
- 改成 15,因為 app 的出路是重傳(§3.11-5)。

**m6 A12-m15 的殘留:孤兒占著 boot 目錄**
- §3.7.3 rc 14 列仍有「上一個 helper 的孤兒 worker 還占著 `/tmp/run/batman/update/boot/`」。這是 helper 端的條件(建目錄 `EEXIST`),不是 batman-slot 的結束碼。
- §4 清理表把啟動時的刪除綁在「持有者活著就不刪」:helper 重啟時只要任何人持鎖(autocommit 的 `commit`、操作員、harness),這次就跳過。之後每個 worker 都會遇到 `EEXIST`,直到下一次 helper 重啟 → 一直回 `E_BUSY` / reason 21。
- 修法(flock 讓它變簡單):worker 開始時,目錄在且 flock 沒人持有 → 依 §3.8.2 的 dirfd 規則清掉再建;持有中 → `E_BUSY`。把這句從 §3.7.3 搬到 §3.7.5;§4 加「worker unlink 後的上傳檔 inode:helper(root 0400,持有租約)」那一列。

**m7 A12-m13 的殘留:上傳檔的刪除仍綁在 provd 的 poll**
- §3.8.2 / §4:「每個 poll 週期,沒有窗且沒有 worker → 刪」。provd 停掉、crash loop,或 jail 起不來時就沒有 poll → 窗到期後,最多 `size=`(≈ 241 MiB)的 tmpfs 一直留到 helper 重啟。在 2 GB 的 TAK 節點上不小。
- 修法:用 helper 自己已有的 4 s 背景迴圈(§3.8.1 檢查防火牆的那個)。
- 測試:窗開、PUT 完成、停 provd、窗到期 → 8 s 內檔案消失。負對照:綁 poll → 還在。

**m8 flock 讀者的契約沒定義「檔案不存在 / 開不了」**
- §5.3 `batman-slot.flock` 列只寫了「持有者結束 → 自動釋放」。讀者有兩個:Go `otaBusy` 會擋使用者的設定;autocommit `:550` 遇到「忙」會 `exit 0` 不 commit。開檔失敗被當成「忙」→ 這次試用永遠不 commit(watchdog 會退回);被當成「不忙」→ 少一道保護。
- 修法:
  - `ENOENT` = 不忙(本次開機還沒有任何 batman-slot 拿過鎖);
  - 其他開檔錯誤 = 忙,並記 log 一次;
  - Go 用 `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`,不建檔;busybox `flock FILE` 會以 0666 `O_CREAT`(`flock.c:53`),所以 shell 讀者改用 `( exec 8<"$f" && flock -n 8 )`,不建檔(與 `payload-stop.sh:34` 同型)。
- 測試:刪掉鎖檔 → `otaBusy` false、autocommit 會 commit。

**m9 新的 rc 14 來源會打到既有呼叫者(harness 與 Go 測試),而 §10 沒列**
- `precheck-node` 是 v7.7 才上鎖;helper 的 `bootinfo` / `precheck-node` 也是新的持鎖者 → V10 列出的 harness 呼叫(rc ≠ 0 = FAIL)會出現假 FAIL。
- Go 測試 `wtxn_v10b_test.go:59`、`p3review_test.go:147` 用建 `.busy` 檔模擬寫入中,要改成持有 flock。
- 修法:harness PR(#290,先進 main)讓這些呼叫在 rc 14 時重試(或用 m1 的輪詢)。`rundir-paths.txt` 加 `batman-slot.flock`(§10 已提 tmp-trust allowlist)。§10 把這兩組列進去。

**m10 joinwatch 的自動重開不看 slot 寫入**
- 已入網、後來卡住(key 已設、driver 卡住)的節點,沒入網滿 3600 s 就 `batman-slot reboot committed`(V11)。這正是擁有者可能想用 OTA 修好的那類節點。app 在這段時間上傳(約 8 分)+ 寫入(≤ 600 s)時,joinwatch 可能在 `begin_write` 之後重開 → 0 + 22,退路已失效。
- sysupgrade 不受影響(stage 1 會殺掉服務);app 路徑的 helper 不會停 joinwatch。這個問題 v7.6 之前就有,但 v7.7 讓判斷變便宜了(一次 `flock -n`)。
- 修法(擇一):
  - joinwatch 在 AUTOREBOOT 前,flock 被持有就延後(上限與 autocommit 的 `DEFER_MAX` 相同);
  - 或在 §6 加一列誠實界線。
- 測試:接縫讓 `t_reboot` = 60 s、`write-hang` → 不重開 / 延後。

**m11 §6 缺一列:持鎖者的子程序卡在 D 狀態**
- `write` 的 `dd` 卡在壞掉的 SD 卡上 → 鎖一直被持有到重開 → `otaBusy` 一直忙,`settings.set`、`network/*`、`update.*` 全部回 `E_BUSY`;app 唯一的出路是重開。這和以前殘留 `.busy` 是同一類問題,但現在是由設計直接決定的行為。
- 修法:§6 加一列(誠實界線 + app 顯示「節點忙碌,請重開」),§3.11-9 補一句。

**m12 `release-guard.yml` 的觸發缺口(⚠️ 依 GitHub 文件推論,未實測)**
- (a)`release` 的 `published` / `edited` 是針對 release 本身;**對已發布的 release 追加資產**(`gh release upload`)⚠️ 很可能不會觸發任何 `release` 事件。
- (b)`release` 事件執行的是 tag 所指 commit 上的 workflow 檔 → tag 打在還沒有 guard 的 commit 上,就沒有檢查。兩者都屬於「我們自己的錯」那一類,正是 guard 要擋的。
- (c)`publish-release.sh` 寫「以 `unsquashfs -cat` 讀 image / payload」:`.img.gz` 要先解壓並取 rootA 的分割偏移,payload 要先從 tar 取出 `root.squashfs`。這些要寫明,否則實作時會發現讀不到。
- 修法:負測試加兩案(對已發布的 release 追加 `wsl` 資產;tag 打在沒有 guard 的 commit);(a) 成立時在 runbook 寫明「追加資產也必須經過 `publish-release.sh`」並列為界線。

**m13 A12-m14(c) 仍開著:firmware gate job 的板子範圍**
- 獨立的 gate job 讀所有 `firmware-*` artifact。halowlink2 / hd01 / venice 沒有 `batman-build.txt`,也沒有 `release-root.pub`(V13)。照「缺 = FAIL」,R 產生之後五板的 release 永遠失敗;不檢查又沒有寫明。
- 修法:寫明 gate 只檢查 `ekh-bcm2711` / `ekh-bcm2710`,其他板子不帶 Batman、不算發布範圍(或不出)。lint 也照這個範圍。

**m14 TRACE 範圍**
- §3.7.3「新動詞都加進 `detect_layout` 與 TRACE」→ 唯讀的 `bootinfo`(helper 啟動時、每次 check)也會寫 p6 的 ota-trace,違反 `batman-slot:47-49` 的規則(唯讀動詞不 trace,不寫 p6)。
- 改成:`detect_layout` 加四個;TRACE 只加 `write`、`arm`、`disarm`。

**m15 `precheck-node` 沒列進 `slotMu`**
- §3.7.4 寫 helper 對 batman-slot 的所有呼叫都經 `slotMu`,但列舉時漏了 `update.check` 的 `precheck-node`。它現在也拿 flock。不列進去的話,它會和啟動時的 disarm 重試互相 rc 14。
- 列進去即可。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 判定 |
|---|---|
| `batman-slot.flock`(鎖) | ✅ 唯一的持有語意是 kernel;寫者都是 batman-slot。讀者試拿 → m1;開檔失敗 → m8;背景子程序 → m2 |
| 目標槽 rootfs / boot / BAD / VERIFIED、tryboot 旗標、boot FAT 的掛載 | ✅ batman-slot 持鎖。stage 2 拿不到鎖 → **MAJOR-1**;tryboot 旗標的 disarm 重試 → m3 |
| `apply_boot_id` / `rebooting` | ✅ 只有 helper 寫;tick 與 apply 的互斥 → m3 |
| `/tmp/run/batman/update/boot/` | ⚠️ 啟動時的刪除條件 → m6 |
| 上傳檔(路徑)/(inode) | ✅ / §4 少一列 → m6;刪除時鐘 → m7 |
| pending、update-last | ✅ |
| 發布(Batman release、firmware release、packages) | ✅ 三條路都有;範圍 → m13;觸發 → m12 |
| p5 的 ro 掛載(precheck-node) | ✅ 在 namespace 裡 |

## 5. 生命週期(只列 v7.7 有變動的)

| 路徑 | v7.7 行為 | 判定 |
|---|---|---|
| install / 第一次開機 | helper 啟動時對兩槽跑 `bootinfo`(持鎖) | ✅;啟動時與 autocommit 的 `commit` 撞 → m1 |
| 啟動 / 停止 / 重啟 helper | 子程序有自己的 pgid;孤兒 `write` 持鎖直到結束 | ✅;孤兒目錄 → m6 |
| sysupgrade stage 1 | `precheck-node` 拿鎖,app 寫入中 → 拒絕 | ✅ |
| **sysupgrade stage 2(ramfs)** | `stage-root` / `apply` 拿鎖 | ❌ **沒有 flock** → MAJOR-1 |
| `sysupgrade -F` 在 app 寫入中 | stage 2 殺掉 helper 與 `write`,`dd` 若卡在 D 狀態 → rc 14 → 回原槽 | ✅ fail-closed(與以前的「接手」不同,但更安全) |
| 升級 / 降級 | 鎖檔在 tmpfs,版本之間不混用 | ✅ |
| crash / crash loop | 行程死了鎖就放 | ✅ |
| 斷電 | tmpfs 消失 | ✅ |
| 子程序卡在 D 狀態 | 鎖到重開 | ⚠️ §6 沒列 → m11 |
| 依賴:joinwatch 自動重開 | 不看鎖 | ⚠️ m10 |
| 依賴:openmanetd init 卡住 | `commit` 的背景子程序持鎖 | ⚠️ m2 |
| 平台 bcm2710 | rootfs 有 flock;ramfs 同 MAJOR-1 | 只編譯(使用者決定) |

## 6. 現場劇本(抽查)

- 正常 OTA(BLE check → 開窗 → PUT → prepare → 兩遍 → `write` → apply → arm → `rebooting` → 重開 → 試用 → commit → 5):✅ 一路對過 §3.7.4 / §3.7.5;flock 下 helper 的序列化不變。
- 操作員在 app OTA 中 ssh sysupgrade:stage 1 拒絕 ✅;`-F` → stage 2 殺 worker,目標槽 BAD,stage 2 再寫(本來就是操作員優先)。但目前 stage 2 會因 MAJOR-1 失敗。
- 已入網、driver 卡住的節點用 app 更新:joinwatch 第 3600 s 可能在寫入中重開 → 0 + 22(m10)。
- 試用開機:helper 啟動時的 `bootinfo` 與 autocommit 的 `commit` 撞 → commit rc 14 → 多一輪累積,仍在 MIN_WINDOW 內 ✅(m1 讓它不會發生)。

## 7. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 15 MINOR)。**

- flock 是對的簡化,v7.6 的持有者規則全拿掉後,我找不到兩個寫者並行的路徑。
- MAJOR-1 是 flock 帶進來的:stage 2 的 ramfs 沒有這個工具,會讓所有 sysupgrade 靜默失敗。修法是 `RAMFS_COPY_BIN` 加一個路徑,外加一個 stage-2 的負對照。
- MINOR 裡,m1–m3 會影響實際行為(偶發 rc 14、鎖被背景子程序帶走、旗標留著 arm);m4–m6 是 flock 之後沒跟上的文字;其餘是契約與範圍補齊。
- 依規則,MAJOR 修完後整份再審。
