# 254-p3-impl v7.8(5a2f3a1)審查 B — 安全優先(S5 整份)

範圍:§3.7、§3.8、§3.11、§12(含 §12.5 負對照、§12.5.18)、附錄 E–J,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 用到的列。只讀:沒改任何 repo、沒上節點。原始碼:Batman-p3 @ 5a2f3a1、firmware-2710 @ 02f0913d(rootfs / kernel 6.6.138 / fstools 取自 `build_dir/target-aarch64_cortex-a72_musl/`)。

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | stamp 只在 `build-board.sh` 第 4 步跑;直接 `make` 沿用上一次 `files/` 的內容 | `build-board.sh:141`;`stamp-batman-build.sh:5-8`(「BEFORE make (OpenWrt bakes files/ into the rootfs)」) |
| V2 | stamp 的 DIRTY 只看 `git ls-files --others --exclude-standard`;被 `.gitignore` 的 `files/` 檔案不算 DIRTY | `stamp-batman-build.sh:40-42`;`.gitignore:38-40` |
| V3 | `BATMAN_WBOX` 從環境變數讀;`BATMAN_CHANNEL` 從 **有 commit 的** `batman-release.env` 讀;release.env 每個 DEV build 都 commit 一次 | `stamp-batman-build.sh:22-23,55`;`git log -- batman-release.env`:02f0913d / 7ce6e80a / 0e1d1025 都是「DEV (local) 1.5.14-wsl.2x」 |
| V4 | CI 的 `build-release.yml` 會把建好的 `*.img.gz`、`*sysupgrade.bin` **自動**發成 GitHub release(`softprops/action-gh-release@v2`,`prerelease: false`),**不經** `release-sign.sh`;通道 = release.env 裡的值(現在是 `wsl`) | `build-release.yml:10,182-262`;`batman-release.env` |
| V5 | sysupgrade stage 2 把舊根的 `/tmp` **move** 進 ramfs → `$RUNDIR/batman-slot.flock` 在 stage 2 是同一個 inode;`install_file` 對 symlink 會在 ramfs 建 `→ /bin/busybox` 的連結 → `RAMFS_COPY_BIN` 加 `/usr/bin/flock` 可用 | `lib/upgrade/stage2:30`;`lib/upgrade/common.sh:8-22`;rootfs `usr/bin/flock -> ../../bin/busybox`;`.config:1593` 沒有 SH_STANDALONE |
| V6 | `RAMFS_COPY_BIN` 在 **Batman feed** 的 `platform-ab.sh:38`,不是 firmware repo | `feed/batman-provision/files/usr/lib/batman/platform-ab.sh:38` |
| V7 | A/B 不走 sysupgrade 的 conffiles 搬移(`platform_copy_config() { :; }`)→ overlay 裡的檔案不會經 ssh sysupgrade 帶到新槽 | `platform-ab.sh:386` |
| V8 | fstools 以 `fopivot(..., "/rom")` 掛 overlay;helper 沒有 jail(只有 provd 有 `procd_add_jail`)→ helper 讀得到 `/rom` | fstools `libfstools/mount.c:172`;`batman-provd.init:18-19`;`batman-provhelper.init` 沒有 jail |
| V9 | `F_SETLEASE F_RDLCK`:`inode_is_open_for_write` → `EAGAIN`;`leases_enable` 預設 1 | kernel 6.6.138 `fs/locks.c:1695-1696`、`:93` |
| V10 | autocommit 的 `slot_writer_alive` 有**三個**讀者:`:213`(認領接手)、`:226`(延後)、`:550`(「revert (or a slot write) in progress — not committing」) | `batman-autocommit:86,213,226,550` |
| V11 | `batman-slot` 持鎖期間的背景子程序:`:781`(`setsid openmanetd start &`,commit 內);`:885`(`reboot committed` 的 240 s 安全網,不開 fd 9) | `batman-slot:776-781,885` |
| V12 | harness 的 `tests/keys/README.md`、`signrel.py:4` 現在寫「T 只給 prov_test」 | 檔案原文 |

## 1. v7.7 發現逐條確認

| 發現 | v7.8 處理 | 判定 |
|---|---|---|
| B13-MAJOR-1 release-guard 可繞過 | 使用者選 A:guard 整套拿掉,一般 DEV 不放鑰匙 | ✅ 關閉(機制拿掉,不是補洞)。但剩下的「bench image 經 CI 自動發布」這條路沒被涵蓋 → **MAJOR-1**(新) |
| B13-m1(a) 背景子程序繼承 fd 9 | `9>&-` + lint | ✅;lint 只看 `&`,範圍偏窄 → m8 |
| B13-m1(b) 讀者探測讓寫者 rc 14 | 讀者共享鎖、寫者重試約 3 s | ✅ |
| B13-m1(c) 不存在 = 不忙;讀者 `O_NOFOLLOW\|O_CLOEXEC` | 不存在 = 不忙 ✅;開檔旗標沒寫 | ⚠️ 併入 m1(目錄 root 0700,只是寫清楚) |
| B13-m2 flock 之後的舊文字 | 附錄 J 說已改 §3.7.5-1、§3.7.6、§4、§12.5 | ❌ **還有 8 處沒改**,另外漏了 autocommit `:550` → m1 |
| B13-m3 租約失敗的 reason | `EAGAIN` 15 → 同 sha 第二次 21;`EINVAL` 21 | ✅ §3.7.5 已改;§7 仍寫 21 → m1;機制本身達不到目的 → m6 |
| B13-m4 / m5 | 隨 `--publish` / guard 拿掉 | ✅ |
| A13-MAJOR-1 ramfs 沒有 flock | `RAMFS_COPY_BIN` 加 `/usr/bin/flock`、flock 不存在 → rc 18、sysupgrade 臂 | ✅ 機制成立(V5);§10 把它記成 firmware 檔案,但其實在 Batman feed(V6)→ m1 |
| A13-m3 / m7 / m15 | disarm tick、helper 自己的 4 s tick、`precheck-node` 進 `slotMu` | ✅(4 s tick 與 prepare 之間的競態 → m7) |

## 2. v7.8 的攻擊

### 2.1 沒鑰匙的預設是不是處處 fail-closed

| 位置 | 結果 |
|---|---|
| helper `update.check` | 鑰匙檔缺、多行、格式錯 → 21,步驟 1 就停,什麼都不寫 ✅。沒有 pending 就不能 `bulk.open` → 不開窗、HTTP 不為上傳聽、不收 PUT ✅ |
| `update.prepare` / `apply` | 沒有 pending → 15 ✅ |
| `update.status` | 永遠 0 ✅ |
| app | `update.check` 回 21 時,§3.11-5 只定義了 worker 的「0 + 21 → 節點現在無法寫入,請稍後再試」。對「這個 image 永遠不能經 app 更新」來說,這段文字是錯的,使用者會一直重試 → m4 |
| status | 沒有任何欄位告訴 app 這台信任哪把根鑰匙(或都沒有)→ app 分不出「沒鑰匙」、「bench(T)」、「正式(R)」→ m4 |

結論:完整性上是 fail-closed。缺的是**可見性**:app 看不到,操作員也看不到。

### 2.2 一般 build 能不能最後帶著 T

| 路徑 | 結果 |
|---|---|
| stamp | 「一般 = 不放」沒寫清楚要**刪掉**上一次 bench build 留在 `files/usr/share/batman/` 的檔案。這兩個檔都被 gitignore,不會變 DIRTY(V2);直接 `make` 又會沿用 `files/`(V1)。`build-board.sh` 第 7 步與 CI 的 gate 抓得到,但手動 `make` 的路徑抓不到 → m5 |
| prov_test | §3.7.1 寫 prov_test image「信任 T」,但 §3.7.2 放鑰匙的表只有 rel / bench / 一般三列。如果 prov_test 是靠 Makefile 放 T,`release-root.pub` 就有第二個寫者,而且 gate 的「一般 `wsl` 不得有鑰匙」會 FAIL;如果 prov_test 也必須加 `BATMAN_BENCH_TRUST=T`,設計要直接寫出來 → m2 |
| `release-sign.sh` | 拒簽 bench / wbox / dirty / 非 `rel`,並在 payload 的 squashfs 上重跑 gate ✅ |
| harness `signrel.py` | 只會簽出 T → K_test,只有信任 T 的節點收 ✅ |
| CI | **CI gate 被設計成接受 bench build**(「bench build:必須等於 T 且 stamp 有 `BATMAN_BENCH_TRUST=T`」),而 CI 的發布路徑不經 `release-sign.sh`(V4)→ **MAJOR-1** |

### 2.3 執行期能不能把一般 image 變成信任某把鑰匙

- 寫得到 `/usr/share/batman/` 的(overlay upper):只有 root。這包括 host root 與掛了 host `/` 的特權容器;provd 在 jail 裡寫不到,成員 / 擁有者的動詞也沒有寫檔的路徑 ✅。
- ssh sysupgrade 不會把 overlay 搬到新槽(V7),app 的 `write` 會 `clear_root` → 植入只留在**那一個槽**,直到那個槽被重寫或 `firstboot -r` ✅。
- 雖然 root 本來就有完全控制權,但「操作員為了測試把 T.pub 複製進一般 DEV 節點、之後忘了」是一個**我們自己的錯**:那台節點從此信任公開的 T,而 status 與 `/etc/batman-build` 都看不出來。改從 `/rom` 讀鑰匙(V8)就能讓這條路消失,而且只是換一個路徑字串 → m3。

### 2.4 bench image 流到現場的殘餘風險

- **能做到什麼**:在信任 T 的節點上,任何能成為擁有者的人(實體奪取後重置再認領,或拿到擁有者的手機)都能經手機 AP **遠端**裝任意韌體,而且這個韌體會留下來。在 secure boot 之前,實體奪取本來就能直接換 SD 卡,所以多出來的只有「被偷的擁有者手機 → 遠端植入」這一項。
- **會怎麼流出去**:(1) 有人手動發布(使用者已接受,§7);(2) CI 自動發布 → MAJOR-1;(3) **角色輪替**:專案記憶寫明 bench / 部署角色會輪替(「Pi3 驗完也轉部署」)。以 bench build 燒的節點換到部署角色、只用 sysupgrade 更新時,只要再裝一次 bench build,就會一直信任 T,而且沒有人看得出來 → m4(要有可見性)。

### 2.5 flock

- 非 root 拿不到、也開不了鎖檔(RunDir root 0700)✅;stage 2 的 ramfs 裡是同一個 inode(V5)✅;共享鎖探測 + 寫者重試約 3 s ✅。
- autocommit `:550` 是第三個 `slot_writer_alive` 讀者,§3.7.6 / §10 沒列(V10)→ m1。
- `9>&-` lint 只抓 `&`;不會抓同步執行、自己 daemonize 的子程序(例如經 start-stop-daemon 起的服務)。這只影響可用性(鎖被一直佔著 → rc 14 直到重開),但修法很便宜 → m8。

### 2.6 租約 `EAGAIN` 15 → 21

- 被入侵的 provd 本來就是唯一的上傳通道,它可以**永遠**擋住更新(丟掉 PUT、截短檔案、內容寫錯)。這是固有的 DoS,§7 應該明列「被入侵的 provd = 更新 DoS,重開後恢復」。
- 它也可以讓 app **無限重傳**:每次把檔案截短一點 → prepare 回 15 →「上傳不完整,請重新上傳」。AP 上抓到 bearer 的人也能這樣做。「同 sha 第二次 `EAGAIN` → 21」只擋住其中一種做法,卻多出一個沒有定義重設規則的狀態(計數存在哪?helper 重啟會不會清?21 會不會永遠卡住同一份 sha?)→ m6:拿掉這個計數,改成在 app 端設重試上限。

### 2.7 helper 4 s 刪檔 tick

- 只用 dirfd + `unlinkat`,不跟隨 symlink;inode 上限 16 ✅。
- 和 `update.prepare` 之間有競態:prepare 先關窗、後啟動 worker。如果 tick 剛好落在「窗已關、worker 旗標還沒設」的空檔,就會刪掉上傳檔 → worker 開檔失敗 → 15。這是 fail-closed,但會讓更新偶發失敗 → m7。

### 2.8 行為者總覽

| 行為者 | 結果 |
|---|---|
| mesh 遠端 | 8095 被 bridge mark + iifname 擋;更新動詞只走 Noise 擁有者 session ✅ |
| 手機 AP 上的裝置 | bearer 被搶 / 先 PUT / 截短 → 只造成 DoS;垃圾 rootfs 在第一遍就被擋 ✅;會無限重傳 → m6 |
| 本機非特權行程 / docker / host-net 容器 | 碰不到鎖、RunDir、FAT、`/usr/share/batman` ✅;`SO_MARK` 被 iifname 擋 ✅ |
| 被入侵的 provd | 內容完整性由租約 + unlink + fchown 保住 ✅;DoS 是固有的 → m6(列 §7) |
| 被移除的擁有者 / 成員 | 和 v7.7 相同 ✅ |
| 實體奪取 | secure boot 之前的界線;bench 節點多一條「被偷的擁有者手機 → 遠端植入」→ m4 的可見性 |
| 供應鏈 / 維護者 | 能改兩個 repo 的人(界線)✅;CI 自動發布 bench → MAJOR-1 |
| 我們自己的錯 | stale 鑰匙檔(m5)、操作員手動放的鑰匙(m3)、角色輪替(m4)、prov_test 契約(m2)、舊文字(m1) |

## 3. Findings

### MAJOR

**MAJOR-1 bench build 可能經 CI 被自動公開發布:`BATMAN_BENCH_TRUST` 從哪裡來沒有規定,CI gate 又被設計成接受 bench build,而 CI 的發布路徑不經 `release-sign.sh`**

- **情境**:實作的人把 `BATMAN_BENCH_TRUST=T` 寫進 `batman-release.env`。這很自然,因為 `BATMAN_CHANNEL` 就在那裡(V3)。這個檔每個 DEV build 都會 commit。之後某次在這個 commit 上打 tag 或手動觸發 `build-release.yml`,CI 就會建出信任 T 的 image,而 `build-firmware.yml` 的 gate 依 §3.7.2 判定「bench build、鑰匙 = T」→ PASS。接著 `softprops/action-gh-release` 把 `*.img.gz` 與 `*sysupgrade.bin` 發成**非 prerelease 的公開 release**(V4)。§3.7.2 / §7 說的「`release-sign.sh` 拒簽」完全不在這條路上。結果就是使用者選 A 要避免的後果:一份信任公開鑰匙、誰都能簽的 image 被公開發布。
- **證據**:§3.7.2 的 gate 規則(bench 在 CI 也 PASS);`build-release.yml:251-262`;`stamp-batman-build.sh:22-23`(通道來自 release.env)、`:55`(WBOX 來自 env);`git log -- batman-release.env`。
- **修法**(只加規定,不加機制):
  - (a) `BATMAN_BENCH_TRUST` **只能**從環境變數讀,和 `BATMAN_WBOX` 相同;`batman-release.env` 裡出現它 → stamp 失敗。
  - (b) `check-release-key-gate.sh` 在 CI(`build-firmware.yml`)遇到 `BATMAN_BENCH_TRUST` 一律 FAIL:CI 不建 bench build,bench build 只能用本機 `build-board.sh` 建。
  - (c) 負測試:release.env 寫 `BATMAN_BENCH_TRUST=T` → stamp 失敗;CI gate 收到 bench stamp → FAIL。
  - §7「公開發布了開發版」那列改寫成:CI 路徑建不出 bench;剩下的只有手動發布(界線)。

### MINOR

**m1 flock / 租約改版留下的舊文字(B13-m2 沒改完),以及漏掉的讀者**

| 位置 | 現在寫的 | 應改成 |
|---|---|---|
| §3.7.3 `write` 列 | precheck「寫 `.busy`」 | 刪掉(寫入進行中 = 持有 flock) |
| §3.7.5-7 | 「鎖與 `.busy` 由持有者檢查回收」 | 「持有者與子程序都結束時由 kernel 釋放」 |
| §4 擁有權「目標槽」列 | 「`batman-slot.lock` 互斥(F35)」 | `batman-slot.flock` |
| §4 清理表「解出的 boot 檔」 | 「`batman-slot.lock` 持有者活著就不刪」 | 「共享鎖試拿失敗(有寫者)就不刪」 |
| §5.1 `update.check` | 「`bootinfo` 拿不到 `batman-slot.lock`」 | flock |
| §5.3 `batman-slot.flock` 列 | 「(`flock -n` 試拿)」 | 讀者用 `flock -s -n`;開檔用 `O_RDONLY\|O_NOFOLLOW\|O_CLOEXEC`,不建檔 |
| §7「被入侵的 provd 保留寫入 fd」 | 「→ reason 21」 | 與 §3.7.5-1 一致(或依 m6 改) |
| §10 `batman-autocommit` | 「以 `flock -n` 判斷」、只列 `:79-86`、`:226` | `flock -s -n`;加上 `:213`、`:550`(V10) |
| §10 `RAMFS_COPY_BIN` | 寫成 firmware 檔案 | 在 Batman feed `platform-ab.sh:38`(V6)→ 跟著產品 PR 走,不是 firmware PR |

**m2 v7.8 的信任文字沒改乾淨,prov_test 的鑰匙契約沒定義**

- §10 的 harness 項目寫「`tests/keys/README.md` 與 `signrel.py:4` 的『T 只給 prov_test』改為 **DEV + prov_test**」,這正好是 v7.8 推翻的東西,應該改成「bench build(+ prov_test,見下)」(V12)。
- §12.2-5 第 3、4 點還寫「`prov-update-254` 用一般 DEV image」、「DEV image 信任公開的 T」→ 改成 bench build。
- prov_test:規定「prov_test **不**隱含 T;要經 app 更新的 prov_test 節點以 `BATMAN_BENCH_TRUST=T` 建」。這樣 `release-root.pub` 就只有 stamp 一個寫者,gate 的規則也不用改。Makefile 不得依 `BATMAN_PROV_TEST` 放鑰匙。負測試:prov_test 但沒有 `BATMAN_BENCH_TRUST` 的 build → image 沒有鑰匙、`update.check` 回 21。

**m3 helper 從 overlay 讀根鑰匙 → 執行期放一個檔就能讓一般 image 信任它,而且看不出來**

- **情境**:操作員為了測 app 更新,把 `tests/keys/T.pub` 複製到一般 DEV 節點的 `/usr/share/batman/release-root.pub`。overlay 會一直保留它(只有那個槽,V7)。從此這台節點信任公開的 T,但 `/etc/batman-build` 沒有 `BATMAN_BENCH_TRUST`,status 也什麼都不顯示。
- **修法**:helper 讀 `/rom/usr/share/batman/release-root.pub` 與 `release-min-serial`(squashfs 下層,執行期不可寫;helper 沒有 jail,V8)。這樣執行期就沒有任何方法改變信任,「image 裡有什麼就信任什麼」也成為字面上的事實。⚠️ 上機唯讀確認 `/rom/usr/share/batman` 在 A/B 節點上存在。負測試:在一般 image 的 `/usr/share/batman/` 放 T.pub → `update.check` 仍回 21。

**m4 可見性:沒鑰匙時 app 的文字是錯的;bench image 在現場時沒有人看得到**

- `update.check` 回 21 時,app 只有「稍後再試」可以顯示,但這種情況永遠不會好。
- 在 status key 15(擁有者)加一個欄位 `update_root`:值是 `release-root.pub` 的 sha256 指紋,沒有鑰匙時是 `none`。app 拿去和它釘的 R 指紋(§3.7.2 已經有)與 T 指紋比對:
  - `none` →「此版本不支援經 app 更新」;
  - T →「測試信任(bench)」橫幅,並且需要擁有者另外確認才更新;
  - R → 正常。
- 這樣角色輪替或手動發布造成的 bench 外流在 app 上看得到,節點端只多一個唯讀欄位,不加任何判斷。§3.11 加這兩段文字;負測試:三種 image 的 status 各回對的值。

**m5 stamp 的「不放」要寫明是「刪掉」**

`files/usr/share/batman/{release-root.pub,release-min-serial}` 被 gitignore(不會 DIRTY,V2),直接 `make` 又會沿用(V1)→ bench build 之後的一般 build 會帶著上一次的 T,只有 `build-board.sh` 或 CI 的 gate 抓得到。修法:stamp 對一般 build 先 `rm -f` 這兩個檔,再依表放鑰匙;§3.7.2 的表把「不放」改成「刪除既有的」。負測試:同一棵樹先建 bench、再建一般 → 不經 gate,直接看 rootfs 裡沒有鑰匙。

**m6 「同一份 sha 第二次 `EAGAIN` → 21」達不到目的,還多出一個重設規則沒定義的狀態**

被入侵的 provd 有很多種方法讓 app 無限重傳:截短檔案 → 15、丟掉 PUT、內容寫錯 → 11。AP 上抓到 bearer 的人也能截短。所以這個計數只擋住其中一種做法,而計數存在哪裡、什麼時候清掉都沒有定義(會不會讓同一份 sha 永遠卡在 21?)。建議:

- 拿掉這個計數,`EAGAIN` 一律回 15;
- §3.11 加「同一份 sha 自動重傳最多 N 次(例如 3 次),之後顯示『節點的上傳通道異常,請重開節點後再試』」;
- §7 明列「被入侵的 provd 可以讓更新一直失敗(DoS),重開節點後恢復」。

這是用規定換掉一個機制。

**m7 4 s 刪檔 tick 與 `update.prepare` 之間的競態**

prepare 先關窗、後啟動 worker。如果 tick 剛好落在「窗已關、worker 旗標還沒設」之間,就會刪掉上傳檔 → worker 開檔失敗 → 15,使用者得重新上傳。修法:規定 tick 與「關窗 + 設定 worker 在跑」拿同一個 mutex(或先設 worker 旗標再關窗)。測試:接縫讓 prepare 在關窗與啟動 worker 之間停 5 s → worker 仍開檔成功。

**m8 `9>&-` lint 的範圍**

lint 只抓 `&`。同步執行、但會自己 daemonize 的子程序(例如經 start-stop-daemon 起的服務)也會繼承 fd 9,讓鎖被佔到它結束為止。修法:lint 也要標出鎖動詞裡的 `setsid`、`nohup`、`start-stop-daemon`、`/etc/init.d/* start|restart`;另外加一條通用測試:**每個**鎖動詞回來後 1 s 內 `flock -n` 拿得到(包含 `commit` 時用接縫讓 `openmanetd start` 慢 30 s)。這條測試涵蓋所有動詞,不只 `addr_defer_release`。

## 4. 確認沒問題(✅)

- 不放鑰匙 = 21,在 `update.check` 的第一步、寫任何東西之前就停;沒有 pending 就不能開窗,也不收 PUT。
- `rel` + `BATMAN_BENCH_TRUST` 會讓 stamp 失敗;`release-sign.sh` 拒簽 bench / wbox / dirty / 非 `rel`,並在 payload 上重跑 gate。
- 過渡版(`--test-key`)只有信任 T 的節點收。
- 讀取租約:有寫入 fd 或可寫的共享 mmap → `EAGAIN`(V9);unlink 之後再 fstat 要求 link count 0,擋得住 link / rename 的 TOCTOU。
- stage 2 的 ramfs 用的是同一個 RunDir inode,`RAMFS_COPY_BIN` 的 symlink 處理可行(V5)。
- 非 root 碰不到鎖、RunDir、boot FAT 與 `/usr/share/batman`;provd 在 jail 裡。

## 5. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 8 MINOR)。**

- MAJOR-1:規定 `BATMAN_BENCH_TRUST` 只能從環境變數讀,並讓 CI gate 拒絕 bench build。這樣 bench image 就不會經 CI 自動公開發布;CI 的發布路徑本來就不經過 `release-sign.sh`。
- 優先改的 MINOR:m3(從 `/rom` 讀鑰匙,拿掉執行期改變信任的路)、m4(status 指紋與 app 文字,讓 bench 外流看得到)、m6(拿掉沒有效果的計數)。
- 依規則:MAJOR 改完後整份再審。
