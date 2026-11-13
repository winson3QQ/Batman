# 254-p3-impl v7.9(89b989b)審查 B — 安全優先(S5 整份)

範圍:§3.7、§3.8、§3.11、§12(含 §12.5 負對照、§12.5.18)、附錄 E–K,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 用到的列。只讀:沒有改任何 repo,也沒有上節點。原始碼版本:Batman-p3 @ 89b989b、firmware-2710 @ 02f0913d(fstools 2024.07.14~408c2cc4 與 target busybox 取自 `build_dir/target-aarch64_cortex-a72_musl/`)。實跑只用 qemu-aarch64-static 加 target busybox,腳本放在 scratchpad `s5/flt/`。

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | **照 §3.7.3 字面寫的 shell 讀者 `[ -e $LOCKF ] && { exec 8<$LOCKF; flock -s -n 8; }` 會讓共享鎖一直留在呼叫它的 shell 裡**。同一個 shell 接著跑的寫者(代表 `batman-slot commit`)會回 **rc 14**;改成 subshell `( exec 8<…; flock -s -n 8 )` 則回 rc 0 | qemu 加 target busybox 實跑(`s5/flt/run.sh`),輸出:`MODE=v79 writer rc=14 after 2s`、`MODE=sub writer rc=0 after 0s` |
| V2 | autocommit 的 `slot_writer_alive` 是在**主 shell** 裡呼叫的函式,`:550` 判斷完之後,同一個 shell 在 `:551` 跑 `batman-slot commit` | `batman-autocommit:86,213,226,550-551` |
| V3 | 寫者的重試照 A14 的寫法(`n≥3` 才離開)實際上試 3 次、只等 2 s,不是設計寫的「3 s」 | V1 的輸出(`after 2s`) |
| V4 | fstools 的每一條路都把開機用的 squashfs 放在 `/rom`:overlay(`overlay.c:220,335,461`)、ramoverlay 退路與 failsafe(`mount.c:167-172`)、extroot 的 pivot 與 overlay(`extroot.c:88,102`);沒有 squashfs 時根本沒有 `/rom` | fstools 原始碼 |
| V5 | 產品已經在讀 `/rom/etc/batman-build`:autocommit `:490`、`batman-slot:801`,而且讀不到就拒絕 commit。04 現在是 committed 狀態,代表 A/B 節點上 `/rom` 確實存在,而且就是 squashfs(⚠️ 這是推論,`/rom/usr/share/batman` 本身沒有上機看) | `batman-autocommit:486-527`、`batman-slot:801-803` |
| V6 | rootfs 每次 build 都從頭重建,`files/` 是後來才複製進去的 → stamp 對 `files/` 做 `rm -f` 就夠了,build_dir 裡不會殘留舊鑰匙 | firmware `package/Makefile:96`(`rm -rf $(TARGET_DIR) $(TARGET_DIR_ORIG)`)、`:119`;`include/image.mk:374-396` |
| V7 | `build-release.yml` 建出來的是 **draft** release(`draft: true`),不是設計寫的「自動公開」;不過只差有人按一次 Publish | `build-release.yml:251-256` |
| V8 | `fast-build.yml` 不跑 stamp,也不跑 `build-firmware.yml` 的 gate,只跑 `gate-rootfs.sh --normal`,然後就上傳 `*.img.gz` 與 payload artifact | `fast-build.yml:136-200` |
| V9 | stamp 現在從**環境變數**讀 `BATMAN_WBOX`(`:55`),`build-board.sh` 先 `wbox_env_reset` 再設 → 直接執行 stamp 時,會讀到呼叫端 shell 的環境變數 | `stamp-batman-build.sh:55`、`lib-wbox.sh:19`、`build-board.sh:67-69,141` |
| V10 | Batman feed 沒有任何套件安裝 `release-root.pub` / `release-min-serial`;`/usr/share/batman` 下只有 allowlist 與 guardian 模板。harness 裡也沒有東西會把 T 寫進 firmware 的 `files/` | `feed/batman-provision/Makefile:108-129`;對 `release-root`、`T.pub`、`tests/keys` 做 grep |
| V11 | helper 沒有 jail(讀得到 `/rom`);provd 的 jail 只掛它自己的 binary、`/etc/batman-build` 與兩個 socket 目錄 | `batman-provhelper.init:11-15`、`batman-provd.init:18-19` |
| V12 | status key 15 只給擁有者 → `trust` 不會給成員看到;內容本來就是公鑰的指紋,不是秘密 | §3.4 表格 key 15 那一列 |

## 1. v7.8 發現逐條確認(看原文,不看附錄 K 的說法)

| 發現 | v7.9 原文 | 判定 |
|---|---|---|
| B14-MAJOR-1 bench 經 CI 公開 | §3.7.2:bench 旗標只從 `--bench` 來、release.env 裡出現就讓 stamp 失敗、CI 遇到 bench 一律 FAIL、有負測試 | ✅ 關閉。§7「公開發布了開發版」那列沒有跟著改寫(沒提到 CI 會拒絕 bench)→ m1 |
| B14-m1 舊文字 | §3.7.3 write 列 ✅、§3.7.5-7 ✅、§4 兩處 ✅、§5.1 ✅、§7 provd fd → 15 ✅、§10 autocommit 四個行號 ✅、`RAMFS_COPY_BIN` 的 repo ✅;**§5.3 `batman-slot.flock` 列仍寫「(`flock -n` 試拿)」** | ⚠️ 一處沒改 → m1 |
| B14-m2 DEV 信任 T、prov_test | §12.2-5、§10 harness、§3.7.1 / §3.7.2 都改成「只經 `--bench`」 | ✅ |
| B14-m3 從 overlay 讀鑰匙 | 只讀 `/rom`;負對照「overlay 放 T.pub → 24、`trust`=`none`」 | ✅(V4、V5;開檔方式的強化 → m5) |
| B14-m4 可見性 | reason 24、`trust`、§3.11-5 的文字 | ✅;但「格式錯 → 21」仍是一個永遠不會好的狀態 → m2 |
| B14-m5 stamp 先刪 | `rm -f` 加負測試 | ✅(V6:這樣就夠了) |
| B14-m6 EAGAIN 計數 | 拿掉計數、app 最多重試 3 次、列進 §7 | ✅;附錄 J 的舊描述只是歷史紀錄,可以留 |
| B14-m7 刪檔 tick 與 prepare | 同一個 `updMu` | ✅ |
| B14-m8 lint 範圍 | 補 `setsid` / `nohup` / `start-stop-daemon` / init.d,加通用測試 | ✅ |
| A14-m1 `sleep 0.2` | `sleep 1` × 3、`command -v flock` → 18 | ✅(實際等 2 s,V3 → m1) |
| A14-m2 / m3 / m4 / m5 / m6 / m7 / m8 / m9 / m10 / m11 / m12 | 逐項看過原文 | ✅ |
| **A14-m13 shell 讀者的寫法** | A14 建議的是 **subshell** `( exec 8<"$f"; flock -s -n 8 )`。v7.9 寫成**大括號群組** `{ exec 8<$LOCKF; flock -s -n 8; }`,在目前的 shell 裡執行,鎖不會放掉 | ❌ **沒有關,而且改出了一個新 bug** → **MAJOR-1** |

附錄 K 說 v7.9「以 grep 逐處改,並在送審前重跑」。結果仍漏了 §5.3 的 `flock -n`,也漏了 §12.5「鑰匙檔」那列的 21(見 m1、m2)。

## 2. 攻擊 v7.9(整份 S5)

### 2.1 bench(信任 T)的 image 還能不能流到公開

| 路徑 | 結果 |
|---|---|
| PR build(`build-pr-*.yml` → `build-firmware.yml`) | CI 不會設 bench;即使設了,gate 也排在上傳 artifact **之前**,而且不是 `continue-on-error`(`build-firmware.yml:227-233` → `:285`)→ FAIL 就不會上傳 ✅ |
| `build-release.yml` / `repro-108.yml` | 一樣經 `build-firmware.yml` ✅。發出來的是 draft(V7):設計對事實的描述錯了,但 CI 拒絕 bench 的規定照樣需要 |
| `fast-build.yml` | 不 stamp、不跑 release-key gate(V8)。checkout 是乾淨的,鑰匙檔被 gitignore → 現在**做不出** bench。但「一般 image 不得有鑰匙」這條不變式,在一條會上傳 artifact 的 CI 路上沒有人檢查 → m4 |
| 本機 `build-board.sh --bench` | 輸出帶 `.bench` 的版本;有人手動上傳仍擋不住(使用者接受的界線)✅ |
| 直接執行 `stamp-batman-build.sh` 再 `make`(不經 build-board) | 如果旗標是經環境變數交給 stamp(V9,和 WBOX 同一種做法),呼叫端 shell 留著的 `export BATMAN_BENCH_TRUST=T` 會做出 bench,而且不經 step 7 的 gate → m3 |
| 轉賣工具的內建清單(§3.9) | 清單是發行 image;R 之前沒有 `rel`。清單加 image 的那一步沒有檢查 stamp 裡有沒有 bench → 併入 m4 |

### 2.2 有沒有東西能把 T 放進一般 image

- stale 檔:`rm -f` 加上 rootfs 從頭重建(V6)✅。
- 環境變數:經 build-board 時被 `wbox_env_reset` 清掉;直接執行 stamp 時會讀到 → m3。
- feed checkout:T 取自 `feeds/batman/tests/keys/T.pub`。feed 被改過只會讓 build 變 DIRTY,不會被拒絕(`stamp:44`)。gate 說「必須等於 T」,但沒寫拿什麼比對:拿 feed 裡同一個檔比,就等於沒比 → m3(在 gate 裡釘 T 的指紋常數)。
- 套件、harness:沒有任何寫者(V10)✅。
- 執行期:只讀 `/rom` ✅。但 squashfs 裡的 symlink 可以把讀取導回 overlay → m5。

### 2.3 `/rom` 是不是真的 squashfs,只讀它站不站得住

- 在 overlay、ramoverlay、failsafe、extroot(pivot 與 overlay)這些模式下,`/rom` 都是開機用的那份 squashfs(V4);沒有 squashfs 就沒有 `/rom` → fail-closed。產品已經依賴 `/rom/etc/batman-build`(V5)。firstboot 時 `mount_root` 在 preinit 就跑了,helper 是 S89 → 這時 `/rom` 已經在。failsafe 不跑 helper。
- 只有 root 能 bind mount 蓋住 `/rom/...`,這是刻意的動作,不屬於「我們的錯」這一類;特權容器同理(界線)✅。
- 附帶好處:`firstboot -r` / LuCI reset 不會動到信任。

### 2.4 `trust` 欄位

只給擁有者(V12);內容是公鑰指紋,不是秘密。「這台是 bench」的資訊對攻擊者沒有額外用處,他照樣需要擁有者的 session。缺的是指紋的**定義**:算在 65 B 的點上、hex 行上,還是含不含換行?`release-root.fpr` 與 app 釘選要用同一個定義 → m6。

### 2.5 reason 24 與 21

§3.7.1 寫「缺檔 → 24;多行、格式錯、沒有 `/rom` → 21」。但這三種都是 image 本身的狀態,**永遠不會自己變好**;21 的 app 文字卻是「節點現在無法寫入,請稍後再試」(§3.11-5),使用者會一直重試。§12.5「鑰匙檔」那列又寫「缺 → 21」,與 §3.7.1 互相矛盾。另外,只有 pub、缺 min-serial(或反過來)時怎麼判,沒有寫 → m2。

### 2.6 flock 的共享鎖讀者

- **V1 / V2 → MAJOR-1**。
- Go 的讀者:`os.Open` 預設帶 `O_CLOEXEC`,子程序不會繼承;但 helper 自己若把 fd 留著(快取),它的 OFD 會一直佔著共享鎖,讓自己起的 `batman-slot write` 回 rc 14。設計寫了「拿到立刻放」,但沒寫「關 fd、不快取」→ 併入 MAJOR-1 的修法。
- 寫者的 `exec 9>>` 會依 umask 以 0644 建檔,不是 §5.3 寫的 0600。真正的保護來自 RunDir 0700,沒有安全影響,只是契約寫錯 → m1。
- 非 root 碰不到鎖檔;sysupgrade stage 2 用的是同一個 inode(B14 V5)✅。

### 2.7 app 重試上限與 DoS 的邊界

- 「prepare 連續 3 次 15 →『請重開節點後再試』」:對被入侵的 provd 有用(重開後恢復)。但對**手機 AP 上知道 AP 密碼、抓到 bearer 的鄰居**沒用:重開後他還在。他要先有 AP 密碼才看得到明文 bearer,所以有效的出路是**換 AP 密碼(key 20)**→ m7。
- 同一個窗裡 bearer 不變,擁有者的 PUT 完成之後,鄰居可以拿同一個 bearer 再 PUT 一次(`O_TRUNC`)蓋掉 → 只造成 DoS,設計已經列為界線 ✅。可選的改法:bearer 收完一次 200 就作廢(m7)。
- 目標槽:垃圾 rootfs 在第一遍就被擋,不會動到退路;unlink 加租約之後,也不會有第二個寫者 ✅。

### 2.8 行為者總覽

| 行為者 | 結果 |
|---|---|
| mesh 遠端 | 8095 被 bridge mark 加 iifname 擋;更新動詞只走 Noise 擁有者 session ✅ |
| 手機 AP 上的裝置 | 只造成 DoS;app 的出路文字不對 → m7 |
| 本機非特權 / docker / host-net 容器 | 碰不到 RunDir、鎖、FAT、`/rom`;`SO_MARK` 被 iifname 擋 ✅ |
| 被入侵的 provd(uid 471,jail) | 內容完整性有租約、unlink、fchown 保護;DoS 是固有的,重開後恢復 ✅ |
| 被移除的擁有者 / 成員 | 與 v7.8 相同 ✅ |
| 實體奪取 | secure boot 之前的界線 ✅ |
| 供應鏈 / 維護者 / CI | CI 拒絕 bench ✅;fast-build 沒有 key gate → m4;feed 被改過的 T → m3 |
| 我們自己的錯 | 讀者寫法(**MAJOR-1**)、舊文字(m1)、24/21(m2)、環境變數(m3)、squashfs symlink(m5) |

## 3. Findings

### MAJOR

**MAJOR-1 §3.7.3 規定的 shell 讀者寫法會讓共享鎖留在 autocommit 的主 shell 裡 → autocommit 自己的 `batman-slot commit` 永遠 rc 14 → 每一次試用(app 更新與 ssh sysupgrade 都一樣)都不會 commit,最後在期限到時退回**

- **情境**:實作照 §3.7.3 的寫法改 `slot_writer_alive`:`[ -e $LOCKF ] && { exec 8<$LOCKF; flock -s -n 8; }`。大括號群組在目前的 shell 裡執行,`exec 8<` 會一直開著,共享鎖不會放掉。autocommit 在 `:550` 呼叫它(沒有寫者 → 判定「不忙」),接著在 `:551` 由同一個 shell 跑 `batman-slot commit`。commit 的 `flock -n 9`(另一個 OFD,要排他鎖)和這個共享鎖衝突,重試 3 次後 rc 14 →「commit failed — retrying」。每次迴圈又重新 `exec 8<`,所以每次都失敗,直到 watchdog 在期限到時退回。結果是**所有更新都失敗**:不會留下壞槽(fail-closed),但產品的核心功能完全無法使用。
- **證據**:V1(target busybox 在 qemu 下實跑:大括號版的寫者 rc 14;subshell 版 rc 0)、V2(`batman-autocommit:550-551`)。A14-m13 原本建議的是 subshell,v7.9 寫成了大括號。§12.5 的負對照沒有一項會抓到這個問題:「讀者共享鎖」那列量的是另一個程序裡的寫者;「持鎖動詞不留鎖」量的是寫者自己。只有 H4 在節點上跑的 `prov-autocommit-p3-254` 正向臂才會發現,那時已經燒好卡、上了機。
- **修法**(只改字,不加機制):
  - shell 讀者寫死成 subshell:`slot_busy(){ [ -e "$F" ] || return 1; ( exec 8<"$F" && flock -s -n 8 ) 2>/dev/null && return 1; return 0; }`(沒有檔 = 不忙;拿得到 = 不忙;其他 = 忙)。
  - Go 讀者寫明:`Open` 之後 `Flock(LOCK_SH|LOCK_NB)`,接著立刻 `Close`,不快取 fd。
  - lint:持鎖相關檔案中,`exec [0-9]<` 只能出現在 `( … )` 裡。
  - 負對照(進 §12.5):在同一個 shell 先呼叫讀者、再跑 `batman-slot commit` → rc 0;拿大括號版當對照 → rc 14(本報告的 `s5/flt/run.sh` 就是這個測試的雛形,必須用 target busybox 跑)。

### MINOR

**m1 還沒改乾淨的文字**
- §5.3 `batman-slot.flock` 列:「(`flock -n` 試拿)」→ 改成「讀者用 subshell 的 `flock -s -n`(fd 形式,不建檔)」。
- §5.3 同一列:「root 0600」→ 改成「權限由 RunDir 0700 保護」(`exec 9>>` 會依 umask 以 0644 建檔)。
- §3.7.3:「寫者的 3 s 重試」→ 實際是 3 次、約 2 s(V3)。
- §7「公開發布了開發版」那列加上「CI(`build-firmware.yml`)遇到 bench 一律 FAIL」。
- §3.7.2 與 §7 把 `build-release.yml`「自動公開發布」改成「自動建 **draft** release,有人按 Publish 就公開」(V7)。

**m2 鑰匙檔的所有錯誤都用 24,不要 21**
- 格式錯、多行、壞點、沒有 `/rom`、只缺 pub 或只缺 min-serial:這些都是 image 本身的狀態,不會自己變好。用 24 的文字(「請用 ssh 或重燒」)才是對的,21 的「稍後再試」是錯的。`trust` = `bad` 加上 log 已經分得出差別。這樣也拿掉一個分支。
- §12.5「鑰匙檔」那列改成「缺、多行、壞點、min-serial 0、只有其中一個檔 → 24」,與 §3.7.1 一致。

**m3 bench 旗標交給 stamp 的方式,以及 T 的比對基準**
- stamp 以**參數** `--bench` 接收這個旗標,不讀環境變數(V9)。這樣直接執行 stamp 也不會被留著的 `export` 影響。`wbox_env_reset` 照樣 `unset BATMAN_BENCH_TRUST`。負測試:`BATMAN_BENCH_TRUST=T sh scripts/stamp-batman-build.sh <board>`(沒有 `--bench`)→ stamp 不帶旗標,`files/` 沒有鑰匙。
- gate 的「bench 的 pub 必須等於 T」:拿 gate 腳本裡釘死的 T 指紋常數來比,不要拿 `feeds/batman/tests/keys/T.pub`。feed 被改過只會變 DIRTY,不會被拒絕(`stamp:44`)。

**m4 一般 image 不帶鑰匙的檢查,要涵蓋每一條產出 image 的 CI 路**
- 「一般 image 沒有 `release-root.pub`」併進 `gate-rootfs.sh --normal`。`fast-build.yml`、`build-board.sh` step 7 都已經呼叫它(V8),`build-firmware.yml` 也加上去。這樣檢查只有一個入口,也不必在 workflow 裡多一步。
- 發行流程「更新轉賣工具清單」那一步(§3.9 / §3.7.2):加進清單的 image,stamp 不得含 `BATMAN_BENCH_TRUST`(拿 `unsquashfs -cat` 讀出來的 stamp 判斷,和 `release-sign.sh` 同一個檢查)。

**m5 讀 `/rom` 的開檔方式**
- 每個鑰匙檔都用 `O_NOFOLLOW` 開,並要求 `S_ISREG`、`st_dev` = `/rom` 的 `st_dev`。否則只要 image 裡有任何一個 symlink(例如某個套件把 `/usr/share/batman` 做成指向 p6 或 `/etc` 的連結),執行期改信任的路又會回來。
- gate 同時要求 squashfs 裡這兩個檔是 regular file。
- 負測試:image 裡放 `release-root.pub` → `/etc/x` 的 symlink → 24 / `trust` = `bad`。

**m6 `trust` 指紋的定義**
- 寫死成:sha256(65 B 非壓縮點);`release-root.fpr`、app 釘選、gate 都用這個定義;`trust` = 前 8 bytes 的小寫 hex,app 以前綴比對。
- 不定義的話,app 與 gate 可能各算各的(hex 行含不含換行),bench 橫幅就會判錯。

**m7 DoS 的出路文字(以及可選的一次性 bearer)**
- §3.11-12 改成:「節點拒絕上傳檔(可能有人在同一個 Wi-Fi 干擾):請換這台節點的 Wi-Fi 密碼(配對)後再試;若仍失敗再重開節點」。要抓到 bearer 必須先知道 AP 密碼,所以換 AP 密碼才真的趕得走 AP 鄰居,重開趕不走。§7「抓到 bearer 的 AP 鄰居」那列同步改。
- 可選:bearer 在一次 PUT 收完(回 200)之後就作廢,下一次 PUT 要重送 `bulk/open` 拿新的。這樣能拿掉「完成後被覆寫」這一種 DoS,代價是 `bulk/open` 重送語意多一條規則。這只是 DoS,不做也可以。

## 4. 確認沒問題(✅)

- CI 的 PR / release / repro 路徑都經 `build-firmware.yml`,gate 排在上傳 artifact 之前;release 是 draft;release.env 的通道白名單與「出現 bench 旗標 → stamp 失敗」都寫明了。
- stamp 的 `rm -f` 加上 rootfs 從頭重建(V6),同一棵樹先 bench 後一般 build 不會殘留 T。
- `/rom` 在每一種掛載模式下都是開機用的 squashfs(V4、V5);helper 沒有 jail,讀得到。
- 沒有套件或 harness 會寫鑰匙檔(V10);`release-root.pub` 只有 stamp 一個寫者。
- `trust` 只給擁有者(V12)。
- 鑰匙缺 → 24,在 `update.check` 第一步就停,不寫任何東西;沒有 pending 就不開窗、不收 PUT。
- 租約、unlink、fchown、第一遍完整驗證:被入侵的 provd 或 AP 鄰居都只能造成 DoS,動不到退路。
- v7.8 的其他發現都依原文改了(§1)。

## 5. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 7 MINOR)。**

- MAJOR-1 只要改一行字(subshell),再加一條負對照。但照現在的字面實作,所有更新都會失敗,而 §12.5 沒有一項抓得到。依規則,MAJOR 改完之後整份再審。
- 優先改的 MINOR:m2(24 / 21,外加一處自相矛盾)、m5(`/rom` 開檔)、m3(stamp 以參數接收旗標)。
- 附錄 K 宣稱的「grep 逐處改」並不完整(§5.3、§12.5「鑰匙檔」列)。下一版送審前,建議把 grep 的指令與輸出一起附上。

### 附:qemu 實跑原始輸出(V1)

```
$ wsl -d Ubuntu-24.04 -u yello -- bash .../scratchpad/s5/flt/run.sh
reader rc=0
MODE=v79 writer(batman-slot commit stand-in) rc=14 after 2s
reader rc=0
MODE=sub writer(batman-slot commit stand-in) rc=0 after 0s
```
(寫者 = §3.7.3 的 A14 寫法:`command -v flock || exit 18; exec 9>>"$F"; until flock -n 9; …sleep 1…; exit 14`;使用 target busybox `build_dir/target-aarch64_cortex-a72_musl/root-bcm27xx/bin/busybox`,經 `qemu-aarch64-static -L`。)
