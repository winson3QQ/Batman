# 254-p3-impl v7.8(5a2f3a1)審查 A — 正確性優先(S5 整份)

範圍:§3.1-5/7、§3.7、§3.8、§3.11、§12(含 §12.5 負對照、§12.5.18)、附錄 E–J,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 中 S5 用到的列。只讀:沒有改任何 repo,沒有上節點。原始碼:`/home/yello/Batman-p3` @ 5a2f3a1(工作樹乾淨)、`/home/yello/firmware-2710`(busybox 1.36.1 build_dir、stamp / build-board / workflows);target busybox 以 `qemu-aarch64-static` 實跑。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 13 MINOR。**

- v7.7 的 MAJOR 兩個都關了:A13-MAJOR-1(ramfs 沒有 flock)已寫進 §3.7.3、§6、§12.5;B13-MAJOR-1(release-guard 可被繞過)隨使用者選 A 整套拿掉。選 A 是「拿掉機制」的修法,我同意。
- v7.8 新帶進來的洞都是 MINOR,但有一個是**實測證實寫了就不會動**的:
  - m1:寫者「每 0.2 s 重試」在這個 busybox 上不成立(`CONFIG_FLOAT_DURATION` 沒開,`sleep 0.2` 立刻以 rc 1 結束)。
- A13-m4 / B13-m2(flock 換掉後的舊文字)附錄 J 說已改,實際上大部分**還在**(m2)。另外 v7.8 自己又留下一批「DEV 信任 T」的舊文字(m3)。
- 其他 MINOR:bench 旗標的來源與殘留、bench 節點裝到沒鑰匙的 image、沒鑰匙時 app 的文字、`apply_boot_id` 與 disarm tick 的先後、刪上傳檔的 tick 與 prepare 的競爭、租約第二次失敗的範圍。

---

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | target busybox **沒開 `CONFIG_FLOAT_DURATION`** → `sleep 0.2` 印 `sleep: invalid number '0.2'`,rc 1,37 ms 就回(qemu 實跑);`sleep 1` rc 0、1015 ms | `build_dir/target-aarch64_cortex-a72_musl/busybox-default/busybox-1.36.1/.config:88`(a53 同 `:88`);`libbb/duration.c`(非 FLOAT 分支只走 `xatoul_sfx`);qemu 輸出見 §5 |
| V2 | busybox `flock`:沒有 flock 時 shell 回 127;`flock -s -n` 在別人持排他鎖時回 1,放鎖後拿得到;`flock FILE …` 形式以 `O_RDONLY\|O_CREAT, 0666` 開檔 | qemu 實跑;`util-linux/flock.c:53` |
| V3 | ramfs 的安裝:`install_file` 遇 symlink 會 `readlink -f` 並在 ramfs 建同名 symlink → `/usr/bin/flock -> /bin/busybox`;`sleep` 在 stock 清單 | firmware `package/base-files/files/lib/upgrade/common.sh:8-36`、`lib/upgrade/stage2:39-55`;rootfs `usr/bin/flock -> ../../bin/busybox` |
| V4 | **`platform-ab.sh` 在 Batman repo**(`feed/batman-provision/files/usr/lib/batman/platform-ab.sh:38`);firmware 樹只有 `feeds/batman/` 的 checkout | `find` |
| V5 | `build-board.sh` 的原則:`BATMAN_WBOX` / `BATMAN_PROV_TEST` 只從 `--wbox` 來,**呼叫端 shell 的同名環境變數一律清掉**(`wbox_env_reset`) | `build-board.sh:65-69`;`scripts/lib-wbox.sh:17-19`(r1 A-M2) |
| V6 | stamp 的版本字串 = `REL-CH.N+feed.fw[.dirty][.wbox-X]`;N 取自手改的 `batman-release.env`;stamp 只寫 `files/etc/batman-build` 與 witness,`.gitignore` 只列這兩個檔 | `stamp-batman-build.sh:21-80`;firmware `.gitignore:38-40` |
| V7 | CI 只對 `ekh-bcm2711` / `ekh-bcm2710` 跑 stamp;通道取自 commit 進去的 `batman-release.env`(現在 `wsl`、N=25) | `build-firmware.yml:133-138`;`batman-release.env` |
| V8 | `batman-slot` 現在的持鎖動詞:`stage-root`、`apply`、`commit`、`rollback`(`:651,660,754,841`);持鎖中的背景子程序只有 `addr_defer_release` 的 `:781`;`reboot committed` 的 `&`(`:885`)不在持鎖動詞內 | `batman-slot` grep |
| V9 | 持鎖動詞呼叫的外部程式(`batman-config-save --check`、`/etc/init.d/openmanetd start`)都**不會**回頭呼叫要鎖的 `batman-slot` 動詞 → flock 沒有自我死鎖 | grep `batman-slot [a-z]` 全 feed;`batman-addr-defer:20-23`(刻意不呼叫 `is-trial`) |
| V10 | sysupgrade stage 2:`stage-root`(以 `$(…)` 取 stdout)→ 鎖外 `dd` 串流 → `apply`;stage 1 跑 `precheck-node` | `platform-ab.sh:173-181,364-379` |
| V11 | autocommit 的讀者:`slot_writer_alive`(`:86`,被 `:213` 認領接手、`:226` 延後、`:550` 用)與 `:226` 的 `.busy`;commit 失敗 → `ok=0` 重新累積 | `batman-autocommit:86,213-231,550-557` |
| V12 | `tests/keys/README.md` 寫「T 只被 prov_test build 信任」;`signrel.py:4` 同;signrel 對任何 payload 都簽,不看 payload 內有沒有根鑰匙 | 兩檔開頭 |

---

## 1. v7.7 發現:真的關了嗎

| 發現 | v7.8 | 判定 |
|---|---|---|
| A13-MAJOR-1 ramfs 沒有 flock | §3.7.3 `RAMFS_COPY_BIN` 加 `/usr/bin/flock`;flock 不在 → rc 18;§6「ssh sysupgrade(stage 2 在 ramfs)」列;§12.5「ramfs 有 flock」負對照 | ✅(V3 證實 install 會建好 symlink)。殘留:§10 把它寫成 firmware 的改動,實際檔案在 Batman repo(V4)→ m12;「127 → 18」在重試迴圈裡要先判斷 → m1 |
| A13-m1 / B13-m1(b) 讀者試拿撞寫者 | 讀者改共享鎖;寫者「每 0.2 s 重試、共約 3 s」 | ⚠️ 方向對,但 `sleep 0.2` 在 target busybox 上**無效**(V1)→ 重試在幾十 ms 內用完 → **m1** |
| A13-m2 / B13-m1(a) 背景子程序帶鎖 | `9>&-` + lint;`reboot committed` 不開 fd 9 | ✅(V8:持鎖中的 `&` 只有 `:781`)。lint 細節見 m12 |
| A13-m3 disarm 重試 | tick 規則 + apply 從 arm 到 `rebooting` 持 `slotMu` | ⚠️ `apply_boot_id` 在 arm **之前**寫,是否已持 `slotMu` 沒寫;p6 唯讀時 tick 永遠重複 disarm → **m8** |
| A13-m4 / B13-m2 舊文字 | 附錄 J:「§3.7.5-1、§3.7.6、§4、§12.5」已改 | ❌ 大部分還在:§3.7.3 `write` 列「寫 `.busy`」、§3.7.5-7「鎖與 `.busy` 由持有者檢查回收」、§4 兩處 `batman-slot.lock`、§5.1 `batman-slot.lock`(§3.7.6 與 §12.5 已改)→ **m2** |
| A13-m5 / B13-m3 租約的 reason | §3.7.5-1:`EAGAIN` 第一次 15、第二次 21;`EINVAL` 21;§12.5 對齊 | ⚠️ §7「保留寫入 fd」列仍寫「→ reason 21」(m2);「第二次」的範圍沒定義 → **m10** |
| A13-m6 孤兒占 boot 目錄 | §3.7.3 rc 14 列改成「孤兒 `write` 仍持 flock」 | ⚠️ 只處理了「孤兒還活著」。孤兒結束後,舊目錄還在、建目錄時 `EEXIST` 怎麼辦沒寫;§4 清理表仍以 `batman-slot.lock` 判斷 → **m11** |
| A13-m7 刪檔綁 poll | helper 自己每 4 s tick | ✅;但 tick 與 prepare 之間有競爭 → **m9** |
| A13-m8 鎖檔不存在 / 開不了 | 不存在 = 不忙;開不了 = 忙 + log | ✅ Go 那一半。shell 讀者若用 `flock -s -n FILE` 形式會建檔(V2)→ **m13** |
| A13-m9 harness 新 rc 14 | §10 harness 清單 | ✅ |
| A13-m10 joinwatch | §11 checklist | ✅ |
| A13-m11 D 狀態 | §6 列 | ✅;§3.11-9 沒補 app 文字 → m13 |
| A13-m12 / m13 guard / 非 bcm 板 | 隨選 A 拿掉;stamp 本來就只對 bcm 板跑(V7) | ✅ |
| A13-m14 TRACE | 唯讀不加 | ✅ |
| A13-m15 precheck-node 進 `slotMu` | §3.7.4 | ✅ |
| B13-MAJOR-1 guard 繞過 | 選 A:整套拿掉,一般開發版沒有鑰匙 | ✅(危險從 image 拿掉;§7 留「手動公開 bench image」的界線) |
| B13-m4 / m5 | 隨 `--publish` 拿掉 | ✅ |

---

## 2. MAJOR

無。

---

## 3. MINOR

**m1 寫者的重試迴圈照設計寫會失效:`sleep 0.2` 在 target busybox 上是錯誤**
- **情境**:§3.7.3 寫「拿不到時每 0.2 s 重試、共約 3 s(照 `halow-setkey:152-155`)」。照字面實作:
  ```
  n=0; until flock -n 9; do n=$((n+1)); [ $n -ge 15 ] && exit 14; sleep 0.2; done
  ```
  `sleep 0.2` 立刻以 rc 1 回來(V1)→ 15 次重試在約 0.5 s 內用完(qemu 上每次 37 ms)→ 回 rc 14。A13-m1 / B13-m1 要修的偶發 rc 14(autocommit `commit` 撞到 helper 啟動時的 `bootinfo`、sysupgrade stage 1 撞到 helper 的 `precheck-node`、apply 的 `arm` 撞到 `otaBusy` 的試拿)又回來了。
- `halow-setkey` 用的是 `sleep 1`(`halow-setkey:152-155`)。設計把頻率改成 0.2 s,就違反了「照 halow-setkey」。
- 同一個迴圈裡,`flock` 不存在時也回非 0(127,V2)。不先判斷的話,迴圈結束會回 14 而不是設計說的 18。
- **修法(照抄已證實可用的寫法)**:
  ```
  command -v flock >/dev/null 2>&1 || exit 18
  exec 9>>"$RUNDIR/batman-slot.flock" || exit 18
  n=0; until flock -n 9; do n=$((n+1)); [ $n -ge 3 ] && exit 14; sleep 1; done
  ```
- **測試**:§12.5「讀者用共享鎖」那列(讀者每 10 ms 試拿,寫者 200 次 → 0 次 rc 14)必須用 **target busybox**(qemu 或節點)跑。host 的 coreutils `sleep 0.2` 是合法的,離線用 host shell 跑會假 PASS(與 vcmailbox stub 同一類的坑)。負對照:`sleep 0.2` 版本在 qemu 上出現 rc 14。

**m2 flock 換掉之後的舊文字(A13-m4 / B13-m2 沒有關)**

實作者照這些寫會做錯:
- §3.7.3 `write` 列:「`precheck`(…、寫 `.busy`、…)」→ 刪掉「寫 `.busy`」。
- §3.7.5-7:「鎖與 `.busy` 由持有者檢查回收(§3.7.3)」→「持有者與它的子程序都結束時 kernel 自動放鎖」。
- §4 擁有權「目標槽 …」列:「`batman-slot.lock` 互斥(F35)」→ `batman-slot.flock`。
- §4 清理表「解出的 boot 檔 / helper 重啟」:「`batman-slot.lock` 持有者活著就不刪」→ 見 m11。
- §5.1:「`update.check` | `bootinfo` 拿不到 `batman-slot.lock`」→ flock;`precheck-node` 拿不到也一樣。
- §7「被入侵的 provd / 保留寫入 fd」列:「拿不到 → reason 21」→「第一次 15、同一份 sha 第二次 21」(§3.7.5-1)。
- §10 檔案清單:「`batman-autocommit`(以 `flock -n` 判斷寫入中」→「以共享鎖試拿」(`-s -n`,fd 形式,見 m13)。

**m3 v7.8 自己留下的「DEV 信任 T」舊文字**
- §12.2-5 只在第一點標「v7.8 取代」,後面三點與 v7.8 矛盾:
  - 「`wsl` / `ci` 信任 T、不能發布」;
  - 「`prov-update-254` 的『T 簽 → 試用 → commit → 5』用一般 DEV image」。照做的話,bench 節點 commit 一份沒有鑰匙的 image,之後的每一臂都回 21(見 m6);
  - 界線「DEV image 信任的是公開的 T」。
- §10 harness 一項:「`tests/keys/README.md` 與 `signrel.py:4` 的『T 只給 prov_test』改為 **DEV + prov_test**」→ 應改為「bench build + prov_test」(V12 的現行文字反而比較接近 v7.8)。
- **修法**:§12.2-5 整點標「v7.8 取代,見 §3.7.2」,只留 R / YubiKey 那一句;§10 改字。

**m4 prov_test image 怎麼信任 T 沒定義,和 gate 互相矛盾**
- §3.7.1 寫「只有 bench build 與 **prov_test image** 信任」。但 §3.7.2 的放鑰匙表只有三列(`rel` / bench / 一般),而 gate 規定「一般 `wsl` / `ci`:不得有 `release-root.pub`」。
- prov_test image 是 `--wbox` 的變體,通道 `wsl`(V5、V6)。它沒有 `BATMAN_BENCH_TRUST` 就放 T → gate FAIL;不放 → 所有要在 prov_test image 上跑 app 更新路徑的負對照(`update-no-attempt-record`、`bootinfo-hold` 等 Go 接縫)都跑不起來。
- **修法**(拿掉一條特例):prov_test / wbox **只經同一個 bench 旗標**拿到 T;§3.7.1 刪掉「與 prov_test image」,或改成「(prov_test 也要加 bench 旗標)」。gate 負測試加一案:wbox 沒有 bench 旗標卻有 T → FAIL。

**m5 bench 旗標的來源與殘留:與 build-board 既有原則相反,而且舊鑰匙檔會留在樹裡**
- (a)**來源**:設計用環境變數 `BATMAN_BENCH_TRUST=T`。`build-board.sh` 對同類旗標的既有原則是「只從 `--wbox` 來,呼叫端 shell 的同名變數一律清掉」(V5,r1 A-M2,理由正是「shell 裡留著的變數會默默改變 build」)。開發者某次 `export` 過,之後每個 build 都會是 bench build(信任公開 T),而且版本字串一模一樣(V6)。
- (b)**殘留**:鑰匙檔放在 firmware `files/usr/share/batman/`,而且設計要它進 `.gitignore`。同一棵樹先建 bench、再建一般 build 時,stamp 只寫「不放」,沒有寫「刪掉」→ 上一次的 T 還在 → gate FAIL。這是 fail-closed,但會讓一般 build 莫名其妙失敗。
- (c)**分辨不出來**:bench build 與同號的一般 build 版本字串相同(N 是手改的,V6)。`batman-version`、daily-validation、§3.11 的版本顯示都分不出哪一份帶 T。使用者規則「出貨的不是驗過的那份 → 在出貨那份上重跑全套」也需要能分辨。
- **修法**:
  - `build-board.sh --bench`,`wbox_env_reset` 一併 `unset BATMAN_BENCH_TRUST`;
  - stamp 的值只接受 `T`(和通道白名單同一種寫法),不放鑰匙時 `rm -f` 兩個檔;
  - bench 進版本的 `+meta`(例如 `.bench`,版本規則本來就忽略 `+meta`)。
- **負測試**:shell 先 `export BATMAN_BENCH_TRUST=T` 再跑沒有 `--bench` 的 build → image 沒有鑰匙;同一棵樹先 bench 再一般 → 一般 build 的 gate PASS、image 沒有鑰匙;`BATMAN_BENCH_TRUST=1` → stamp 失敗。

**m6 bench 節點可以經 app 裝上一份沒有鑰匙的 image,之後就不能再經 app 更新;§12.5 的負對照會把 02 / 04 變成這樣**
- `signrel.py` 對任何 payload 都簽(V12)。同一個 N 的一般 build 與 bench build 外觀相同(m5)。把一般 build 經 app 裝上 bench 節點 → 試用 → commit → 之後 `update.check` 一律 21,只能 ssh sysupgrade 回來。§6 沒有這一列;§12.2-5 第三點還**指示**這樣做(m3)。
- §12.5「一般 DEV image 沒有鑰匙」的負對照(一般 `wsl` image 的 `update.check` → 21)要在節點上跑一般 image → 同一個結果。這是破壞性測試,沒有列副作用與還原(使用者規則「破壞性測試先列副作用」)。
- **修法(不加產品機制)**:
  - `signrel.py` 預設拒簽 root.squashfs 裡沒有 T 的 payload(`unsquashfs -cat usr/share/batman/release-root.pub`),負測試另加 `--allow-keyless`;
  - §12.5 那列改成 Go 單元測試(鑰匙路徑可注入:缺、多行、壞點 → 21),外加一次離線 gate 檢查(一般 build 的 rootfs 沒有鑰匙檔),不在 02 / 04 上裝一般 image;
  - §6 加一列「bench 節點裝了沒有鑰匙的 image → 只能 ssh 回來(誠實界線)」。

**m7 沒有鑰匙的 image:app 收到 reason 21,文字是「請稍後再試」,但這個狀態是永久的**
- v7.8 之後,所有一般 DEV 節點的 `update.check` 都回 `{1: false, 2: 21}`(§3.7.1)。§3.11-5 把 21 顯示成「節點現在無法寫入,請稍後再試」→ 使用者會一直重試,也看不出要改用 ssh / 重燒。21 原本的意思是「節點端暫時無法寫入」(結束碼表的卡片、layout、逾時)。
- **修法**:鑰匙檔缺 / 壞用另一個 reason。可以沿用 reason 7(「這台沒有這個能力」,§3.1-8;不加新碼),或新增 24(CDDL 同步)。§3.11-5 加文字「這台節點的 image 不接受 app 更新(開發版),請用 ssh 或重燒」。
- **測試**:Go 單元測試,鑰匙缺 → 該 reason,不是 21。負對照:沿用 21。

**m8 `apply_boot_id` 與 disarm tick 的先後;p6 唯讀時 tick 會一直重複**
- (a)§3.7.4 寫「**arm 之前**寫 update-last `{apply_boot_id …}`」與「從 arm 到寫好 `rebooting` 全程持有 `slotMu`」。沒寫寫 `apply_boot_id` 時是否已經持有 `slotMu`。如果還沒有:
  1. tick 的 `TryLock` 在中間成功;
  2. 看到 `apply_boot_id` = 本次、`!rebooting` → disarm(旗標本來就是 0)→ 清掉 `apply_boot_id`;
  3. apply 接著 arm、寫 `rebooting: true`。若這次寫入是「讀檔、改一欄、寫回」,`apply_boot_id` 就丟了;
  4. 重開、試用退回後,第 8 列的條件「`apply_boot_id` 有值」不成立 → 報 23 或 0,而不是 6。
- (b)「`rebooting` 寫不進 → disarm、回 0 後清 `apply_boot_id`」:p6 唯讀時,清除本身也寫不進 → `apply_boot_id` 一直留著 → **每個 tick** 都跑一次 `batman-slot disarm`(拿 flock、寫 trace)。之後操作員手動 `batman-slot apply` 的 arm 也會在下一個 tick 被 disarm(違反「操作員手動 apply 不受影響」)。
- **修法**:
  - `update.apply` 在寫 `apply_boot_id` **之前**就拿 `slotMu`;update-last 一律整筆寫(從記憶體組,不讀改寫);
  - tick 的條件簡化成「`TryLock` 成功」(拿得到就代表 apply 沒在跑);
  - helper 記憶體記「這個 `apply_boot_id` 已 disarm 成功」,之後不再重跑;清不掉的情況列 §6 界線(p6 唯讀時操作員手動 apply 可能被取消一次)。
- **測試**:接縫在「寫 `apply_boot_id`」與「拿 `slotMu`」之間停 5 s,期間跑 tick → 試用退回後 status = 6。負對照:先寫後拿鎖 → 23。p6 唯讀 → apply 回 `E_STORAGE` 後 60 s 內 disarm 只跑 1 次。

**m9 刪上傳檔的 4 s tick 與 `update.prepare` 的競爭**
- §3.8.2:tick「沒有窗且沒有 worker → 刪」;§3.1-5:`updating` 在 prepare 回應前設好、「上傳窗在同一點關」。兩個狀態沒有寫在同一把鎖下改。
- tick 是另一個 goroutine。它可能在「窗已關、worker 旗標還沒設」的那一瞬間執行 → 刪掉 `payload` → worker 開檔 `ENOENT` → 15 → 使用者重傳 126 MB。機率小,但每次更新都會經過這一點。
- **修法**:窗、`updating`、worker 狀態放在同一個 mutex(例如 `updMu`)下一次切換;tick 讀狀態與刪檔也在這把鎖下。
- **測試**:接縫讓 prepare 在關窗與啟動 worker 之間停 5 s → 檔案仍在、worker 成功。負對照:分開兩步 → 15。

**m10 「同一份 sha 第二次 `EAGAIN` → 21」的範圍沒定義**
- 計數存在哪裡、什麼時候歸零都沒寫。如果是「helper 這次執行期間,同一個 sha 永遠 21」:一次合法的 `EAGAIN`(例如手機斷線後,provd 端舊連線到最低速率逾時前還開著檔,而 app 已經對新 PUT 拿到 200 並送 prepare)再加上任何一次重來,這個版本就要等重開才能裝。app 看到的又是「請稍後再試」(m7)。
- **修法**:計數綁在 pending 上(pending 被覆寫、到期,或 worker 成功都歸零)。21 的 log 帶「租約」字樣,讓操作員知道去看 provd。
- **測試**:同一 pending 兩次 `EAGAIN` → 21;重新 `update.check` 產生新 pending 後再 `EAGAIN` → 15。

**m11 A13-m6 殘留:孤兒結束後的 boot 目錄**
- helper 重啟時,孤兒 `write` 還活著 → 啟動清理跳過(§4 清理表)。孤兒結束後,`/tmp/run/batman/update/boot/` 仍在。下一個 worker「建 boot 目錄前先試拿鎖」拿得到,但設計沒寫目錄已存在時怎麼辦(§3.7.5-4 寫的是「helper **新建**的 0700 目錄」、`O_CREAT|O_EXCL`)→ 實作照字面會 `EEXIST` → 21,直到下一次 helper 重啟。
- **修法**:§3.7.5 開頭寫明「worker 開始時:flock 試拿得到 → 以 dirfd + `O_NOFOLLOW` 清掉整個 `/tmp/run/batman/update/boot/` 與舊的 `SHA256SUMS` / `metadata` 再建;拿不到 → `E_BUSY`」。§4 清理表的「啟動時刪」改成同一條規則。

**m12 §10 的 repo 標錯;`&` lint 的範圍**
- §10「firmware `RAMFS_COPY_BIN` 加 `/usr/bin/flock`(`platform-ab.sh:38`)」:這個檔在 Batman feed(V4),改動走 Batman PR,firmware 只是 bump 釘選版本。照現在的寫法,firmware PR 會改 `feeds/batman/`(不是 git 追蹤的檔),結果被 `-i` 蓋掉,或讓 build 變 DIRTY。
- lint「每個 `&` 都有 `9>&-`」:`batman-slot` 裡有 `&&`、`2>&1`、`$(( 0x$t & 0x1 ))`(`:292`)。要寫明 lint 只看「行尾或 `;` 前的背景 `&`」,並以 `:781` 與 `:885` 當正、負樣本。

**m13 shell 讀者的寫法與 app 文字補漏(A13-m8、A13-m11 的另一半)**
- autocommit 若用 `flock -s -n "$f" true` 形式,會以 0666 `O_CREAT` 建鎖檔(V2)。這和「鎖檔不存在 = 不忙」與 §5.3「root 0600」不一致。功能上無害(目錄是 0700),但契約要寫死:讀者用 `( exec 8<"$f" ) 2>/dev/null` 判斷存在,再 `( exec 8<"$f"; flock -s -n 8 )`,不建檔(與 `payload-stop.sh:34` 同型)。
- §3.11-9 補一句:D 狀態造成的長時間 `E_BUSY` →「節點忙碌,若持續請重開節點」(§6 已列界線)。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 判定 |
|---|---|
| `batman-slot.flock` | ✅ 只有 `batman-slot` 持排他鎖;讀者只試拿共享鎖。沒有自我死鎖(V9)。重試失效 → m1;讀者建檔 → m13 |
| 目標槽、tryboot 旗標、boot FAT 掛載 | ✅ `batman-slot` 持鎖;helper 經 `slotMu` |
| `apply_boot_id` / `rebooting`(update-last) | ⚠️ 寫者只有 helper、經 `updMu`;但 apply 與 tick 誰先拿 `slotMu` 沒寫 → m8 |
| 上傳檔(路徑) | ⚠️ 刪除者只有 helper;tick 與 prepare 的狀態沒有同一把鎖 → m9 |
| `/tmp/run/batman/update/boot/` | ⚠️ m11 |
| `release-root.pub` / `release-min-serial`(image 內) | ⚠️ 寫者 = stamp,但旗標從環境變數來、殘留不刪、prov_test 怎麼拿到 T 沒定義 → m4、m5 |
| pending、upload bearer、`provd-stable` | ✅ |

## 5. 生命週期(S5,只列 v7.8 有影響的)

| 路徑 | v7.8 行為 | 判定 |
|---|---|---|
| install / 一般 DEV image 第一次開機 | 沒有鑰匙 → `update.check` 21 | ⚠️ 狀態永久,文字卻說「稍後再試」→ m7 |
| bench image(02 / 04 從 wsl.25 升上來) | ssh sysupgrade:stage 1 / 2 用 wsl.25 的舊 `batman-slot`(mkdir 鎖,不需要 flock)→ 可行;之後 app 路徑 T → K_test | ✅(V10)。bench 與一般 build 分不出來 → m5 |
| bench 節點經 app 裝一般 image | commit 後失去 app 更新 | ⚠️ §6 沒列、§12.2-5 還指示這樣做 → m3、m6 |
| 啟動 / 停止 / 重啟 helper | 啟動時 `bootinfo`、disarm tick | ✅;tick 先後 → m8;孤兒目錄 → m11 |
| sysupgrade stage 2(ramfs) | `RAMFS_COPY_BIN` 帶 flock | ✅;重試迴圈 → m1 |
| 降級到沒有 P3 的版本 | ssh:stage 2 用 P3 的 `batman-slot` + ramfs flock → 可行;經 app:P3 之前的 payload 不能裝(既有界線) | ✅ |
| crash loop(helper) | 每次啟動都跑 `bootinfo` → 短暫持鎖;寫者重試 3 s 可以吸收 | ✅(前提:m1 修好) |
| 斷電 | RunDir 消失,鎖跟著消失;tryboot 旗標一次性 | ✅ |
| 依賴重啟:procd 卡住時跑 `openmanetd start` | `9>&-` → 不帶鎖 | ✅ |
| DEV → PROD | bench:T 簽、內建 R 的 `rel` 過渡版;一般 DEV:ssh / 重燒 | ✅ |
| bcm2710 | 同一份腳本、同一個 busybox `.config`(a53 `:88` 一樣沒有 FLOAT_DURATION) | 只編譯(使用者決定);m1 兩板都適用 |

## 6. 現場劇本(抽查)

- **正常 OTA(bench 節點)**:BLE check → `bulk.open` → PUT → prepare(關窗 + 設 `updating`)→ 兩遍 → `write`(flock)→ apply(`apply_boot_id` → `slotMu` → arm → `rebooting`)→ 重開 → 試用 → commit → 5。
  - 每一步都對過 §3.7.4 / §3.7.5;
  - 兩個縫:prepare 的狀態切換(m9)、`apply_boot_id` 與 `slotMu` 的先後(m8)。
- **試用中,autocommit 的 `commit` 撞到 helper 啟動時的 `bootinfo`**:寫者應重試 3 s → 0 次 rc 14。依現在的 0.2 s 寫法 → rc 14 → `ok=0`,重新累積 → 延後 commit,仍在 MIN_WINDOW 內(m1)。
- **一般 DEV 節點的擁有者用 app 更新**:check → 21「稍後再試」→ 使用者一直重試(m7)。
- **開發者 `export` 過 `BATMAN_BENCH_TRUST=T`,之後建「一般」image 給別人**:image 信任公開的 T,版本字串和一般 build 一樣(m5)。

## 7. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 13 MINOR)。**

- 選 A 把危險從 image 本身拿掉,取代一整套發布檢查,方向正確,而且確實少了機制。flock 加上 ramfs 修正後,我找不到兩個寫者並行,也找不到自我死鎖的路徑(V9)。
- **建議實作前一定要改的**:
  - m1:`sleep 1` 與先判斷 flock 存不存在。不改的話,A13-m1 的修法實際上不存在;
  - m2、m3:舊文字,實作者與 harness 會照著做錯;
  - m5、m6:bench 旗標的來源、殘留與分辨,以及 bench 節點裝到一般 image。
- 其餘 MINOR 可以在實作 PR 一起處理,每項都附了測試與負對照。

---

### 附:qemu 實跑原始輸出(V1、V2)

```
sleep: invalid number '0.2'
sleep 0.2 rc=1 elapsed_ms=37
sleep 1 rc=0 elapsed_ms=1015
EXok
SH-probe-while-EX: busy rc=1
SH-probe-free: got
sh: flock: not found
rc=127
```
(`qemu-aarch64-static -L root-bcm27xx root-bcm27xx/bin/busybox …`;busybox 1.36.1,a72 build)
