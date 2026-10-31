# Review A — `254-h23-harness.md` v1(2026-10-28,唯讀審查,未碰節點)

## 摘要

整份設計的骨架(單位骨架 `pr_begin`/`pr_end`、F/R 還原改走鏈 1 程序、`dv-sbx` 改 shell、`-wbox` 改真 build)方向可行,但有兩處讓甲部**開不了跑**:(1) 全套順序把 prov tier B 排在 2g 之後,而 2g 最後一項 `pty-commit-254` 把 04 留在 slot B,違反每個單位的 S0 前置(committed = A);(2) 需要 killpoint 的單位(powerloss ×3、claim killpoint 段、netupdate、lock-failsecure 前置)標成「— / A」,但 `prov_test` helper 只存在於 `-wbox test` 變體,而 `-wbox` 契約是「只進 B、一律 hold」;`test` 變體本身又同時違反 §4.2「DIRTY 必為 1」與 lint「每個 patch 至少改一檔」,且 OpenWrt 的套件重建雜湊看不到 `BATMAN_PROV_TEST` env,`--wbox test` 與正常 build 互相留下 stale helper。另有 8 個 MAJOR:預期 REVERT 之後的 `bad-slot` 無人清(brewrite 前置會擋 → 每個 (1)(4) 單位都 NEEDS-PERSON)、payload `metadata` 的 `version=` 其實是時間戳(§4.2 的斷言不可能成立)、`sync`+`reboot -f` 不是斷電代理、powerloss 負對照照寫法做不出來、legacy-upgrade 負對照把 04 commit 在 wbox 的 A 槽且無路回、provd frame socket 與 killpoint 目錄/ujail 的契約互斥、NEEDS-PERSON 後非 prov 的 D 類測項仍會動 04、autocommit (7) 在這個 fleet 拓撲上做不到。

## BLOCKER

### B1. 全套順序與 2g 的 `pty-commit-254` 衝突:prov tier B 第一個單位就 FAIL S0 前置
- **情境**:`FEATURE_MODE=--destructive` 全套。2g 的順序(`scripts/daily-validation.sh:278-281`)最後是 `pty-commit-254`,它「moves the node to the other slot, so it runs last」(`scripts/dv/claim-lock-254.sh:10`、`daily-validation.sh:296`)。本設計 §4.3 把 prov tier B 排在「2g 之後」,且每個單位 `pr_begin` 斷言「S0 槽條件」= committed = A(§4.5.0 沿用 p1-impl)。04 此時 committed 在 B → 28 個單位全部 FAIL precondition(或全部 NEEDS-PERSON)。
- **證據**:`daily-validation.sh:296`;p1-impl §4.5.0「不符 → 04 自動正規化」在 h23 §4.3/§4.7 沒有對應(h23 只在 run 開始的 P9 看槽,沒有 tier B 開始時的正規化)。
- **修法**:二選一並寫進 §4.3:(a) prov tier B 排在 `pty-commit-254` **之前**(2g 的 chain1 也要求 A,順序自然);(b) `pr_begin` 遇 committed = B、版本 = V、無 wbox 時做 p1-impl §4.5.0 的正規化(hold OTA V 進 A → release → commit A),並明列副作用與時間。(a) 便宜且不新增機制。

### B2. killpoint 單位拿不到 `prov_test` helper;`test` 變體的 build 契約自相矛盾
- **情境 1**:`prov-powerloss-254`(txn-2/3/4)、`prov-claim-254` killpoint 段、`prov-netupdate-254`、`prov-lock-failsecure-254` 的前置(`claim-before-shadow`)都標「— / A / F」(§6.2),即在 **A 槽(release build)** 上注入。但 `--killpoint` 只在 `prov_test` build(§4.1.1),而 `prov_test` 只隨 `-wbox test` 變體存在,`-wbox` 的契約是「只進 B、一律 hold」(§3 B 槽列、§4.2)。設計只在 `prov-netjoin` 那一列順帶一句「用 `-wbox` 的 helper 檔 bind,不另建」。接縫怎麼到 A 槽沒有契約:bind 來源(從哪個 payload 解出 helper、驗什麼 sha、`.protected` 不變)、bind 後 `procd restart` 等於再跑一次 `boot.Run`(`cmd/batman-provhelper/main.go:439`,會改 prov-state 的 verdict 行)、killpoint 的 `reboot -f` 之後 bind 消失、A 槽以 release helper 做恢復(這其實是對的,但要寫明「恢復路徑 = release build」)。
- **情境 2**:`test` 變體「無 mutant,只有 `prov_test` tag」(§4.2 表)。這和 §4.2「DIRTY 必為 1,因 feeds/batman 修改」矛盾(沒有 patch 就沒有修改,`scripts/stamp-batman-build.sh:44` 的 `git status --porcelain` 為空 → `BATMAN_DIRTY=0`,VER 沒有 `.dirty`),也和 §4.2 末「每個 patch 必須至少改一個 `feed/` 下的檔,否則 lint FAIL」矛盾(`test` 沒有 patch,或是空 patch 必 FAIL)。
- **情境 3(我們自己的錯,題目 (b))**:`BATMAN_PROV_TEST=1` 只經 env 進 Makefile(§4.1.2)。OpenWrt 的重建判定是套件目錄的檔案雜湊(`include/package.mk:114` `STAMP_PREPARED` ← `find_md5 ${CURDIR}`,`include/depends.mk:14` 以 `%p%T@` 算),**不含 env**。`--wbox test` 不改任何檔 → `batman-prov` 不重編 → 「test 變體」裡是上一次的 release helper → gate 反向檢查 FAIL → 變體永遠 build 不出來;反方向(先 `--wbox test` 再正常 build)只有 gate 擋得住,`build-board.sh:124-140` 第 5 步的 clean 只對 golang rules 變動做。
- **修法**:
  1. §4.2 新增「`prov_test` helper 到 A 槽的方法」:`pr_begin` 從 `-wbox test` payload 的 `root.squashfs` 以 `unsquashfs -cat usr/bin/batman-provhelper` 取出 helper(主機端,sha 記錄)→ 推到 04 `/tmp/run/batman-dv/wbox/<run>/batman-provhelper`(root 0700)→ `prov-wbox-254.sh bind` → `arm-killpoint` → restart;斷言 `batman-provhelper --version` 第 2 行 = 標記字串、`/proc/$(pidof batman-provhelper)/exe` 的 sha = 推上去的檔(claim-lock §11.4 的 mutant helper 規則);寫明「重開後恢復邏輯由 A 槽 release helper 執行,bind 隨 tmpfs 消失」。
  2. `test` 變體:`--wbox <name>` 一律 `export BATMAN_WBOX`,`stamp-batman-build.sh` 在 `BATMAN_WBOX` 有值時**強制 `DIRTY=1`**(不靠 git status);lint 的「至少改一檔」對 `test` 例外(或 `test` 以一個只加註解行的 patch 存在並改 lint 規則)。
  3. `build-board.sh`:`BATMAN_WBOX`/`BATMAN_PROV_TEST` 與 `logs/wbox-<board>.stamp` 記的上次值不同 → `make package/batman-prov/clean`(同 #252 的 GOSTAMP 做法);E-H2 驗收加「`--wbox test` → 正常 build → 正常 build 的 helper `go version -m` 無 tags **且** helper sha ≠ test 變體(證明真的重編)」。

## MAJOR

### M1. 預期 REVERT 之後的 `bad-slot` 沒有擁有者;brewrite 前置會擋 → (1)(4)(7-04)(9 release 後)每個單位都 NEEDS-PERSON
- **情境**:autocommit (1) `radio1-off`、(4) `chan`、(7) 04 角色都是「不 hold → REVERT」。`TRIAL-REVERTED` 一定寫 `bad-slot`(`feed/batman-provision/files/usr/bin/batman-autocommit:238-244`,另 `:195`);只有同槽同版本 COMMITTED 才刪(`:537`)。`pr_end` 的 B 寫回 V 走 `brewrite-254.sh`,前置 `badslot=[]`(`scripts/dv/brewrite-254.sh:21` → `stop`)。§3 擁有權表沒有 `bad-slot` 列;§4.3/§6.2 沒說誰在 REVERT 之後清它。鏈 1 的 `restore_all` 有做(`scripts/dv/chain1-254.sh:145`「residue of this run — removing」),本設計沒有沿用。
- **另一面**:§3 B 槽列寫「一律 hold」,與 §6.2 (1)(4)(7) 不 hold 矛盾;非 hold 的 `-wbox` trial 若**誤 commit**(= 該單位要抓的 bug)→ 04 committed 在 wbox B,prov deadman「不碰槽」→ harness 若此時死掉,04 一直以 mutant image 跑 OTS 直到有人來。
- **修法**:`pr_end`(與 `pr_abort`)在 REVERT 類單位:斷言 `bad-slot` 內容 = `slot=B version=<wbox ver>`、印出、刪除,然後才 brewrite;§3 加 `bad-slot` 列(寫者 autocommit;刪除者:product COMMITTED,或 harness 在「預期 REVERT 且版本相符」時);§3 B 槽列改成「hold 或預期 REVERT,兩者都列在單位表」;生命週期矩陣加「harness 死於非 hold wbox trial 期間」(deadline revert 接手 → bad-slot → dirty → P9 印 restore 指令)與「誤 commit 後 harness 死」(04 停在 wbox B,需人;deadman 不處理,寫明理由)。

### M2. §4.2「payload 的 `metadata` 版本含 `.wbox-`」斷言不可能成立:`metadata` 的 `version=` 是時間戳
- **證據**:`scripts/build-ab-payload.sh:69`:`printf 'board=%s\nversion=%s\nsize=%s\n' "$BOARD" "$(date +%Y%m%d-%H%M%S)" "$SQ_BYTES"`。`platform-ab.sh:11` 的註解也只說 `version=<...>`。鏈 1 自己是用 out 目錄的 `batman-build.txt` + `SHA256SUMS` 證版本(`chain1-254.sh:185-188`)。
- **修法**:`pr_ota_b` 的版本斷言改成:主機端對 `~/out/<VER>/ekh-bcm2711/SHA256SUMS` 驗 payload 與 `batman-build.txt` 的 sha,讀 `BATMAN_VERSION`/`BATMAN_WBOX` 行;推上節點後再以 `tar -xzf … -O root.squashfs | unsquashfs -cat - etc/batman-build`(或 stage 目錄)讀一次,兩者一致才 `sysupgrade -n`。

### M3. `sync` + `reboot -f` 不是斷電代理(題目 (f));txn-1 / txn-5 列了卻沒有單位用
- **情境**:§4.1.1「到點:log → `sync` → `reboot -f`」。先 `sync` 等於保證 helper 到那一點之前的每個寫入都落盤,所以 txn-2/3/4 測到的只是「狀態機在該點被切斷後的恢復邏輯」,測不到 L7 真正要防的「寫入順序 / fsync 缺漏」(`.txn` 的 fsync、`--prov-only` 寫 p5 的 journal 順序、overlay rename 的目錄 fsync)。kernel 有 `CONFIG_MAGIC_SYSRQ=y`、`CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1f6`(含 0x80 reboot;`build_dir/…/linux-bcm27xx_bcm2711/linux-*/.config:6904-6905`),`echo b > /proc/sysrq-trigger` 立即重開、不 sync、不卸載,是標準的 crash-consistency 代理;本設計的沙箱契約也已假設 `/proc/sysrq-trigger` 存在(§4.4)。
- **另外**:§4.1.1 的封閉清單有 `txn-1`、`txn-5`,§6.2 沒有任何單位注入它們(L7 說三個點);清單裡不測的點要嘛刪,要嘛加單位(txn-1 = `.txn` 已寫、setkey 未做 → 開機應只刪 `.txn` 不改 wireless;txn-5 = `--save` 之後、`prov-state` 之前 → 下次開機 `--check` 不報 stale)。
- **修法**:killpoint 動作改為 `echo b > /proc/sysrq-trigger`(無 `sync`),失敗才退回 `reboot -f` 並在 log 標 `killpoint … fallback reboot -f`;harness 記錄用的是哪一種(sysrq 版才算 L7 PASS,`reboot -f` 版只算 ⚠️);`sysctl kernel.sysrq` 在 P9 讀一次(≥ 128 位元)。txn-1/txn-5 二擇一處理。

### M4. `prov-powerloss` 的負對照照寫法做不出來;`prov-netupdate` 負對照的斷言對象錯
- **powerloss**:§6.2「`txn-2` 後把 `.txn` 刪掉(bind 空檔)→ 開機不對帳」。`.txn` 由 `WriteTxn` 以 `.txn.tmp` + `os.Rename` 寫(`feed/batman-prov/src/provstore/txn.go:21-33`);在它上面 bind 一個空檔 → rename 到 mountpoint 失敗 → `EApply`(`node/node.go:1101-1105`)→ 連 setkey 都沒做,killpoint 到不了。若改成 killpoint 之後、重開之前刪:killpoint 是立即重開,沒有「之後」;重開後 helper 在 S89 自己跑 `boot.Run`(`main.go:439`),harness 來不及。
- **修法**:負對照 = 注入前 `/etc/init.d/batman-provhelper disable`(只拿掉 rc.d symlink,執行中的 daemon 不受影響)→ net-apply + killpoint → 重開(helper 不自啟)→ 斷言 `.txn` 存在、wireless ≠ prov → `rm .txn` → `enable` + `start` → 斷言 helper log 沒有「txn … NOT committed」且 wireless 仍 ≠ prov → FAIL = 負對照成立;正向不 disable。這也給了「txn-2 之後、helper 還沒跑之前」的觀測窗(設計裡本來沒有)。
- **netupdate**:§6.2「bind 不讓路的 `--on-join`(去掉 txn 檢查)→ gen 前進 → FAIL」。`--on-join` 從不寫 prov(stage1 §4.4 步驟 6;`batman-config-save:162-172` 只是 txn-live 時拒做),去掉檢查它寫的是 **overrides**(含 setkey `--no-persist` 後 uci 裡尚未提交的新 key),p5 gen 不會動。斷言改成「p5 `overrides.uci` 的 radio1 key/mesh_id 前進到未提交值 → FAIL」。

### M5. `prov-legacy-upgrade-254` 的負對照把 04 commit 在 wbox 的 A 槽,而 B 是 wsl.9:沒有路回 S0
- **情境**:正向「rc(V)apply 進 A → A commit」標「不 hold / A / R」;負對照「`-wbox rc9-unclaimed` → `prov{unclaimed}` → FAIL」走同一條路 → A committed 在 wbox 版本。§4.3 跨槽還原「在 B 上 p5-restore → rollback → A 開機 → F」預設 B = V;這裡 B = wsl.9、A = wbox,rollback 回到 wsl.9,之後要再 OTA V 進 A 並 commit,設計沒寫;P9 下次會因 A `.protected` 含 wbox 整個 run FAIL(`95-batman-storage:717` 寫的是完整 `BATMAN_VERSION`)。
- **修法**:負對照改成 **held trial**:04 在 B(wsl.9,有 HOLD-COMMIT:`git show f2f2bf6:…/batman-autocommit` 8 處)→ hold OTA `-wbox rc9-unclaimed` 進 A → trial 內斷言 helper log `rc=9` + `prov{unclaimed}` → `rollback` 回 B(deadline 內,無 bad-slot)→ 再做正向(V 進 A,不 hold,commit)。單位表的「最終槽」欄對負對照也要填。

### M6. provd frame socket / `BATMAN_PROVD_TEST_*` / CI `peer-vs-provd` 的契約互斥或缺漏
- **目錄互斥**:§3 把 `/tmp/run/batman-prov-test/` 定為 root 0700(killpoint 契約 §4.1.1),又把 provd 的 `gatt.sock`(uid provd 0600)放在同一個目錄 → uid 471 在 root 0700 目錄裡建不了 socket。
- **ujail**:stage1 §4.7 provd「只掛 `/tmp/run/batman-prov` 與 dbus socket」,`/tmp/run/batman-prov-test` 不在 jail 裡,provd 看不到。
- **env 開關**:`BATMAN_PROVD_TEST_NO_OWNEROP` / `FAST_FAKE` 是 procd 服務的 env,沒有寫「誰、用什麼機制設(init 讀某個 root 0600 檔?)、信任邊界、缺檔/壞值行為」(審查規則 6)。
- **CI 執行模型**:「provd(amd64 build,fakeSys)直接本機」— fakeSys 是 helper 的介面(`node.go:62`),provd 要的是 helper socket 的對手;runner 上要 root helper(`main.go:373` 非 root 直接退出)+ uid 471 存在(`sock.go:52` chown gid 471)+ provd 以 471 跑、沒有 bluetoothd/hci0/dbus(provd 只在 health 為真時註冊廣播,stage1 §8)→ provd 必須有「無 BLE 只開 frame socket」模式,這是一個沒列在 §4.1.2/§4.8.3 封閉清單裡的 `prov_test` 行為。
- **修法**:socket 搬到 provd 的 jail 內目錄(例如 `/tmp/run/batman-prov/gatt.sock`,目錄 0750 root:provd 已由 `PrepareDir` 建),killpoint 目錄維持 root 0700 分開;§4.8.3 加「`prov_test` 下 provd 在 `BATMAN_PROVD_TEST_SOCK_ONLY=1` 時不碰 dbus」並寫進封閉清單;env 的寫者 = harness 寫 `/tmp/run/batman-prov-test/provd.env`(root 0600、非 symlink、link count 1),init 在 `prov_test` build 才讀,release init 不讀;CI job 寫明 `useradd -u 471 provd`、helper 以 sudo 跑、provd 以 `sudo -u provd`。

### M7. NEEDS-PERSON 之後「其餘非 prov 測項照跑」會讓 D 類測項動到非 S0 的 04
- **情境**:prov tier B 停在安全點時 04 可能在 B trial、LOCKED、member 狀態、或 bind 殘留(deadman 到期前)。§4.3 順序之後還有 `ab-selftest`(BENCH_NODE)、`fault-injection`(`OTS_NODE` = 04,`daily-validation.sh:335`,會 OTA/重燒並 `restore_node`)、`reflash-survives-config-202`。這些會覆寫 B、commit 槽、動 p6,毀掉需要人看的證據,也可能把 wbox 槽 commit 掉。p1-impl §7.4「節點的狀態不是 S0 時,絕不往下一個單位跑」沒有延伸到非 prov 的 D 類測項。
- **修法**:daily-validation 遇 rc 2:之後所有 `kind=D` 且目標含 DNODE 的 suite 印 `FAIL blocked: DNODE needs a person (<step>)` 並不執行;只動其他節點的 D 類(ab-selftest on 02)仍可跑,但要寫明 02 此時可能被隔離。

### M8. autocommit (7)(L40 team OTA)在這個 fleet 拓撲上做不到
- **情境**:主機到 02 只有一條路:04 的 eth → br-ahwlan → mesh(E1a:fresh trial 在 `10.41.254.x/16` 經 eth;記憶:乙太網只在 04)。(7) 要 04 跑 `-wbox chan` 不 hold trial(= 04 不在 mesh)期間斷言 02 `HELD`、必要時 `release` 02;04 離開 mesh 的那一刻起主機就連不到 02。而 02 的 held trial(legacy,`.seeded` → NEED_MESH=1)需要鄰居 04 才會 HELD;04 一換頻道,02 的健康判定失去鄰居 → deadline revert → 02 寫 `bad-slot`,p1-impl §7.4 本來就把「02 的 B trial 到期 revert」列為要人處理。時序(02 trial 先 HELD,再 OTA 04,04 revert ≥ 600 s,02 的 deadline 多久)設計沒有算。
- **修法**:(a) 改成 L40 的本意:02 **先**完成 held trial 並 **release/commit**(04 仍在 A、在 mesh),之後 04 才 OTA `-wbox chan`;要證的是 04 的 stage 1 在「02 剛 commit、本機 `lastjoined` 為真」時寫 `ota-armed.mesh … joined` → 04 revert;02 那邊只需在 04 回來後讀 log(02 已 committed,不需在 04 離線時觀測)。或 (b) 明列 ❌ 不做真機、改沙箱 + DRYRUN,寫進 §9。不論哪個,(7) 的時間預算(兩台各一次 OTA + 600 s revert)與 02 的還原(`bad-slot`、B 寫回 V 在 02 上怎麼做,p1-impl §7.4「B ≠ V 自動修包括 02」)要寫出來。

## MINOR

### m1. build gate 放錯地方;`helper-exit1` 不是 Go 二進位;release-scan 沒有 asset 步驟
- `check-image-manifest.sh` 只收 `<manifest> <board>`(`scripts/check-image-manifest.sh:13-14`),`build-board.sh:146-148` 第 6 步也只給 manifest;rootfs 目錄在第 6 步是 `root-bcm27xx`(`:151`,給 `check-go-toolchain.sh`)、第 7 步是 `$WR/r`(`:168-172`,`check-pvs-shim.sh`)。gate 應掛在第 7 步旁邊(對真正進 payload 的 squashfs 做)。`go version -m` 對 shell 檔(`helper-exit1`)無輸出 → `BATMAN_WBOX` 反向檢查要定義這個情況。`.github/workflows/release-scan.yml` 目前是 dependency-check + SBOM,沒有下載 release asset 的步驟;release asset 由 firmware repo 的 CI 產,放哪邊掃要寫明。

### m2. 時間預算:chain1 已經 > 3000 s,且 02 的重開要變成可歸因的行
- §4.3「超過的單位(鏈 0 + autocommit (7))拆成兩個 lease」;鏈 1(既有,60–90 分,`claim-lock-254.sh:11`)本來就超過,`chain1-254.sh:362` 只 `warn` 02 重開。要嘛列為已接受的例外,要嘛拆。每個單位 `pr_end` 應記錄 02 的 `boot_id` 前後相同(鏈 1 已這樣做)。joinwatch `t_reboot 3600` 是每個未入網 episode 計(`etc/init.d/joinwatch:14`、`usr/bin/joinwatch:37`),單位之間 04 回 mesh 就重置,所以 < 3000 s 的規則本身成立。

### m3. F4「tar 覆蓋 + 刪多出 = 重建」的證據沒有涵蓋刪除(whiteout)與 opaque 目錄(題目 (a))
- 鏈 1 / prov-claim 的還原 PASS 只動過新增與修改的檔。單位裡若刪掉 lower 的檔(whiteout = char 0:0)或 `rm -rf` 後重建 lower 也有的目錄(overlayfs `trusted.overlay.opaque` xattr),busybox tar 不帶 xattr,`tree_manifest` 也只看 upper 清單不看合併視圖(`scripts/node/prov-base-254.sh:65-78`)。`jffs2reset` 的做法(`fstools-2024.07.14/libfstools/overlay.c:139-142` `overlay_delete` → `foreachdir(handle_rmdir)`,掛著刪再 `sync()` `:342`)和 `overlay-restore` 的「刪多出」機制相同,所以 L60 的模擬和 R 類「等於重建」在機制上合理;但缺一個負對照:單位內刪一個 lower 檔(如 `/etc/banner`)→ restore 後檔案回來;跳過「刪多出」時 compare 要 FAIL。opaque 目錄是否存在於 04 的 upper 沒有查(節點沒有 getfattr);至少在設計寫明「未查,風險接受」。

### m4. BLE lease 與 prov lease 的互斥用了兩個不同的鎖原語
- BLE 用 `flock $BT/lock`(`scripts/node/ble-lib-254.sh:78-82`);prov lease 是另一個檔(§3),§4.3 沒說 acquire 在哪個鎖內。兩邊各自「先看對方 lease 再寫自己」有 TOCTOU。prov `acquire` 也走 `$BT/lock` 的 flock(同一把)。

### m5. 事實計數與 known-failures 到期欄
- F21 說 6 行,`scripts/validation-known-failures.txt` 第 10、19–24 行共 **7** 行是 #254;F3 說 12 個,列出的是 13 個。p1-impl §2.2「known-failures 增第 4 欄到期日」在 h23 §2.2 消失(默默縮範圍;`feedback_one_validation_set` 也要它)。

### m6. P9:`.protected` **缺** 的情況要明寫 FAIL
- `batman-slot apply` 一開始就刪目標槽的 `.protected`(`feed/batman-provision/files/usr/sbin/batman-slot:428-433`),所以「推了 wbox 進 B 但還沒開機」的殘局是 `.protected` 不存在而不是含 wbox。p1-impl §4.7 寫「缺 = FAIL」,h23 §4.7 只寫「含 wbox → FAIL」。

### m7. `/tmp/run/batman-prov-test/` 目錄沒有刪除者
- helper 讀完只刪 `killpoint` 檔(§4.1.1);目錄留到重開。沒重開的單位(killpoint 沒觸發、或 claim 段失敗)會留下目錄 → 下一次 P9 FAIL。`pr_end`/`pr_abort`/prov deadman 加 `rm -rf /tmp/run/batman-prov-test`。

### m8. `peer.py` 傳輸契約相對 219 §4.1 要補三件事(題目 (d))
- 協定外的 `0xC0`/`0xC1` 單位元組包:要定義「長度 < 3 且不是這兩個值 → abort」,以及它們只允許在交握前(否則是一個未認證的 side channel);socket 上的 `CTRL.max_frame` 值是多少(BLE 是 MTU−3,sock 沒有 MTU);「同時 BLE 連線 ≤ 2」(219 §8)是否把 socket 連線算進去(`prov-sec-hog` 假設 2 sock + 1 BLE = 第 3 個被拒)。這三條都要寫回 P2 設計與 219 §4.1,不然 `peer.py` 的 hog 測項對 provd 沒有定義。框架格式(`flags(1)‖seq(2 BE)‖data`、每則從 0 起算、序號不連續或超 `max_msg` → 斷)與 219 §4.1 一致 ✅。

### m9. `dv-sbx`(題目 (c))可行;三個細節
- `prov-unit-gate` 需要 GPT 卡 / FAT / `/boot/autoboot.txt` / DT `compatible`(p1-impl §4.10 另一套 loop 卡做法),h23 §6.1 把它列在同一個 `prov-sandbox` 案例表裡而 §4.4 又寫 `/proc/device-tree` 不存在;要分開寫。`timeout-minutes` 只算執行時間,arm64 runner **排隊**時間不受它限制(「排隊久 = FAIL」不成立,只是 CI 變慢);F14(公開 repo 免費 arm64 runner)我沒有辦法核對。E-H3 之前這個 job 不要擋 PR。namespace / capability / 負測試五條(§4.4)對 p1-impl §4.10 逐條對應 ✅。

### m10. autocommit (8)(9) 的判定文字
- (8) 兩臂都寫「WARN」沒有鑑別力:`ble-ok` 在 → `batman-autocommit:496-499` 印 `WARN ble: ble-ok present but BLE health is not good`;不在 → 那段根本不跑,**沒有任何行**。斷言改成「在:有該行 + HELD;不在:無該行 + HELD」。(9) `helper-flap` 在 hold 下「不 commit」沒有鑑別力(hold 本來就不 commit);04 若有 `ble-ok`,health-stale 只是 WARN(P-U5)→ `release` 後會 commit。要寫清楚:hold → HELD + WARN 行;之後 `release` → 預期 commit(P-U5)還是不 commit(若意圖是 stale 擋 commit,和 P-U5 衝突,要決定)。

### m11. `prov-claim-254` 的「空 `authorized_keys` 視圖(bind)」會把 harness 自己鎖在外面
- bind 期間新的 ssh 連線看不到 lab key,`none` 又已被關(claimed)。要在**同一條** ssh 批次內 bind → provclient → unbind,並寫進 §7「我們自己」列(deadman 的 `unbind-all` 是最後防線)。

### m12. `verify.py` 改成可 import、`peer.py` selftest、裁判獨立性
- `tests/vectors/219-protocol/verify.py:181` 等模組層已經 `cbor2.loads(NC_RAW)` 讀向量;改 `def main()` 時所有依向量的模組層物件要一起搬,否則 import 就讀檔。`peer.py --selftest` 要逐位元組重現 NX/NXpsk0,必須注入向量的臨時金鑰,設計要寫。「第二裁判(`peer.py` ↔ provd)」和第一裁判共用 `verify.py` 的程式碼與 `dissononce`,不是獨立實作——可接受(向量本身來自 `noiseprotocol`),但 §4.8.1 不要寫成「兩個裁判」,寫成「向量 + 共用判定碼的對手」。

## 已核對的假設(file:line)
- F1:`feed scripts tests .github` 對 `killpoint|prov_test|wbox` 0 命中(grep,2026-10-28)。
- F2:`prov-p1-254.sh` 未接線(`scripts/daily-validation.sh` 只有 `prov-p1-stubs`,無 `prov-p1-254` suite)。
- F4:`scripts/dv/chain1-254.sh:122-176` `restore_all`;`scripts/node/prov-base-254.sh:190-220` p5-restore / overlay-restore;無 `firstboot`。
- F5:`tests/prov-p1/overlay-allow.txt` 3 條帶證據。
- F6:`feed/batman-provision/files/usr/lib/batman/platform-ab.sh:11-12,156,329,374`;`feed/batman-provision/files/usr/sbin/batman-slot:591-600` sha 驗證、無簽章。
- F7:`firmware-2710/scripts/stamp-batman-build.sh:38-44,54`(DIRTY 來源、VER);`feeds/packages/lang/golang/golang-package.mk:106-111,260`(`GO_PKG_TAGS` → `-tags`)。
- F8:`feed/batman-prov/src/cmd/batman-provhelper/main.go:380-404` CLI;`node/node.go:62-81` `Sys` 20 個方法;`node/txn.go:17-41` commitTxn;`node/node.go:1088-1124` applyNet(txn 標記 → setkey → commitTxn → `--save`)。
- F9:`tests/tools/provclient/main.go:490-558` 動詞;`:420` setuid 471;`:470` `unixpacket`。
- F10:`batman-autocommit:26-28,44-60,97-100,151-165,260-282`。
- F11:`feed/batman-provision/files/etc/uci-defaults/99-batman-chanfix:47,53` 字串逐字相符。
- F15:`verify.py` 661 行、無 `main()`/`__main__`、頂層 import + 向量載入(`:181`);`ci-check.sh:12,17-26` MIN_CHECKS 195 + 竄改負對照。
- F16:`feed/batman-prov/src/go.mod` 只有 `golang.org/x/crypto`;`src/` 有 `proto cbor cose shacrypt`,無 noise。
- F18:`scripts/node/ble-periph-254.sh:43-52` adv-on/off(`add-adv -g -u 181c`);`scripts/node/ble-lib-254.sh:78-120` lock/lease/deadman。
- F19:`scripts/dv/prov-lib-254.sh` 全部函式;`scripts/dv/brewrite-254.sh:19-38`。
- F20:`chain1-254.sh:72-85` `find04`;`:205-222` 一次性 deadman(只在 B)。
- F21:7 行(非 6)。F3:13 個(非 12)。
- 02 joinwatch 3600 s:`feed/batman-provision/files/etc/init.d/joinwatch:14`;`usr/bin/joinwatch:37`。
- hold-commit 在 wsl.9:`git show f2f2bf6:feed/batman-provision/files/usr/bin/batman-autocommit` 含 `HOLD-COMMIT` 8 處。
- wsl.9 的 96 鎖規則(給 `prov-lock-failsecure` 負對照):key **且** 密碼都在才 LOCKED,否則 UNPROVISIONED(`git show f2f2bf6:…/96-batman-config-migrate:157-175`)→ 負對照有鑑別力 ✅。
- `bad-slot`:寫 `batman-autocommit:195,244`;刪 `:537`(同槽同版本 COMMITTED);`:361` 只用來擋 stale fallback。
- `.protected`:寫 `feed/batman-provision/files/etc/uci-defaults/95-batman-storage:717`(完整 `BATMAN_VERSION`);apply 時刪目標槽的 `batman-slot:428-433`。
- payload `metadata` `version=` 是時間戳:`scripts/build-ab-payload.sh:69`。
- OpenWrt 套件重建雜湊只看套件目錄檔案(含 mtime),不看 env:`firmware-2710/include/package.mk:114`、`include/depends.mk:14`。
- kernel sysrq:`CONFIG_MAGIC_SYSRQ=y`、`CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x1f6`(含 reboot 位元)。
- `jffs2reset` 是掛著刪 upper:`firmware-2710/build_dir/target-aarch64_cortex-a53_musl/fstools-2024.07.14~408c2cc4/libfstools/overlay.c:139-142,322-342`。
- helper socket 目錄 `PrepareDir` 0750 root:provd(`feed/batman-prov/src/sock/sock.go:37-78`);單連線序列化(`sock.go:107-116`)。
- helper init `respawn 3600 5 0`(`feed/batman-prov/files/batman-provhelper.init:13`);daemon 每次啟動跑 `boot.Run`(`main.go:439`)。
- `--on-join` 在 txn live 時拒做、從不寫 prov(`feed/batman-provision/files/usr/bin/batman-config-save:162-172`)。
- 主機沒有 `bleak`(`python -c "import bleak"` → ModuleNotFoundError,Python 3.12.10)— F13 ✅。
- `firmware-2710/scripts/check-go-toolchain.sh` 的 REQUIRED 不含 helper;`go version` 略過非 Go 檔(`:6-9`)。
- `feed/batman-provision/Makefile:62-140` install 行:54 個 `files/` 檔,lint-install 可行。

## 無法核對的假設
- F12(節點沒有 python3 / dbus-send / busctl / unshare;firmware 樹有編好的 dbus-send)、F17(04 BLE current settings)、F22、F23(04 的 S0 狀態)— 需要節點或作者的原始輸出,本審查未碰節點。
- F14 GitHub `ubuntu-24.04-arm` 對公開 repo 免費、排隊時間 — 無法上網核對;E-H3 之前視為 ⚠️。
- busybox `reboot -f` 是否 `sync()`(halt.c 不在 build_dir 可讀路徑)— 設計本身已先 `sync`,所以 M3 的結論不依賴它。
- `provgen.py` 用 `pycose` 產 COSE 與 helper 的 Go `cose` 互通 — 向量只證明解碼方向;`pycose` 產出的 Sign1 header 順序 / deterministic 編碼是否與 `gen.py`(手組 Sig_structure)相同,未查;`provgen.py --selftest` 必須逐位元組等於 `vectors.json` 的 `net_config`(設計已寫)而不是只驗簽。
- `dissononce` 能否注入臨時金鑰做 selftest(m12)— 依記憶,未讀套件原始碼。
- 04 upper 是否有 opaque 目錄(m3)。
- 主機 MediaTek 藍牙到 04 的 RSSI(D-H8)— 設計已列 E-H1。

## 範圍對照(題目 7)
- p1-impl §5.3 全部、§5.4 鏈 0、§5.5 (1)(3)–(10)、§5.1 沙箱、§5.2 tier A 都有對應單位 ✅;`prov-base-254` 去掉「同槽 A 重建一次」與 F4 的改法一致。
- 默默縮小:known-failures 到期欄(m5);p1-impl §4.3「provclient 放置負測試:預先放 provd 可寫的檔或 symlink → 拒絕執行」在 h23 沒有(`pl_prep` 也沒做);(7) 事實上做不到(M8)。
- 多出來但沒有覆蓋的風險:13 個 `-wbox` 真 build(每個都是完整 image + payload;E-H2 要量單次時間並乘以 13,寫進 §7.3)。

## 裁決

**REJECT**(BLOCKER 2:B1、B2)。B1 是順序問題,改一行就能解;B2 要把「`prov_test` helper 怎麼到 A 槽」與「`test` 變體 / 重建雜湊」寫成契約並在 E-H2 實證。M1–M8 都是在無人值守 15–20 h 的跑法下會把 04 留在壞狀態或讓單位無法判定的問題,v2 一併修正後整份再審。
