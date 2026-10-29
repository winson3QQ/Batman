# #254 P1b 安全審查(test seams + firmware `-wbox` build + 13 個 `-wbox` mutant)

- 審查者:獨立安全審查(與四輪一般程式碼審查互補,不重複)
- 日期:2026-10-28
- 範圍:
  - Batman `feat/254-p1b-seams` @ `1f82e36`(對 `origin/main` = `5914f03`):`feed/batman-prov`
  - firmware `feat/254-wbox` @ `6235f6ee`(對 `e7c2a222`):`build-board.sh`、`lib-wbox.sh`、`stamp-batman-build.sh`、`check-prov-test-gate.sh`、CI
  - harness `harness/254-h23` @ `b6d562a`:`tests/wbox/*.patch`、`helpers.list`、`gen/`、`lint-wbox.sh`、設計 §4.1/§4.2/§7/§16
- 方法:全部在 `/home/yello` 下的 `mktemp` 副本跑(`git archive` / `git show`),以 uid 1000 執行。firmware 工作樹只用 `git show`/`git diff` 讀,沒有碰正在跑的 build。暫存目錄已刪掉。

## 結論

**OK WITH FIXES**:沒有 CRITICAL,也沒有 HIGH。

- 程式碼本身:release helper 的行為與攻擊面沒變,只多了 `--version`。killpoint 讀檔的防護經實測成立。正常 build 的 gate 會擋下 test seam 與 mutant 殘留。
- 缺口:**節點上沒有任何東西會拒絕 commit 一個 `-wbox` image**(F1,MEDIUM)。設計裡的「一律 hold」與 P9 目前只在文件裡,harness 程式還不存在。
- 建議在第一次真的 build `-wbox` payload 之前處理 F1。最晚也要在 harness PR merge 之前。

---

## 發現

### F1 — MEDIUM:mutant image 進了槽之後,節點會照常 auto-commit(防線只在 build 端與尚未實作的 harness)

- **情境(actor = 我們自己 / 供應鏈)**:有人拿 `~/out/<VER>.dirty.wbox-<name>/…/ab-payload.tar.gz` 對任何節點跑 `sysupgrade -n`。可能是手動、拿錯檔,或 harness 有 bug 沒寫 hold 旗標。結果:
  - trial 健康時,`batman-autocommit` 就 `batman-slot commit`。
  - 下列 mutant 會削弱驗證:
    - `helper-nojoinop`:`net.apply` 不驗 owner-op。
    - `helper-clientchal`:採用 client 給的 ClientChal。⚠️ 推論:這會讓觀察過一次 claim 交換的人能重放。
    - `rc9-unclaimed`:legacy 節點變成 unclaimed,第一個 claim 的人就成了擁有者。
    - `helper-notrial`:trial 槽也接受改狀態的請求。
  - P2 provd(BLE)上線後,這些就成了遠端可達的接管路徑。
- **證據**:
  - ✅ `git grep -i 'wbox|PROV_TEST_BUILD'` 在 Batman `1f82e36` 的 `feed/` 與 `scripts/` 只命中 seam 本身。`batman-autocommit` 的 commit 路徑(`:536` `if batman-slot commit`)只看健康狀態與 `HOLDCOMMIT_FLAG`(`:270-291`),不看 `BATMAN_WBOX` 或 `.dirty`。`batman-slot` 也沒有這類檢查。
  - ✅ harness 分支 `b6d562a` 沒有 `scripts/node/prov-wbox-254.sh`、`scripts/dv/prov-254.sh`,也沒有 P9 實作(`ls` → No such file)。設計 §4.2、§4.7、§7 的「只進非 committed 槽;一律 hold;P9」目前只在文件裡。
  - ✅ 現在已經存在的防線:
    - 正常 build 的 gate(見下面驗證表 N2/N4/N5/N10)。
    - `--card-only` 不接受 `--wbox`(`build-board.sh` 的參數檢查),而且 gate 在 card-only 時拒絕 wbox stamp(N4)。
    - VER 與 payload 檔名帶 `.dirty.wbox-<name>`(`stamp-batman-build.sh`,`build-board.sh` step 8)。
    - rootfs 裡有 `BATMAN_WBOX=` 這一行。
    - `batman-version` 會印 `DIRTY`。

    這些都是「標示」,不是「拒絕」。
- **影響**:只要一次人為失誤,一台 fielded 節點就可能 committed 在一個驗證被削弱的 helper 上。
- **修法(建議;要使用者決定)**:在產品端加 fail-secure。`batman-autocommit` 在 `/etc/batman-build` 含 `BATMAN_WBOX=` 時永不 COMMIT:記一行 `WBOX-NO-COMMIT`,deadline revert 照舊。`batman-slot commit` 碰到 wbox 時也拒絕,除非帶一個明確的 `--allow-wbox`,讓 harness 的 `pr_needs_person` 可以用。
  - 與設計相容:「一律 hold」本來就不 commit。
  - 衝突點:§6.2 (9) 的 dry-run 斷言 `DRYRUN decision: COMMIT …`。這需要只在非 dry-run 時拒絕,或者改 (9) 的斷言。
  - 這比 P9(事後偵測)早一層,而且不依賴 harness 正確。
- **負測試**:在 sandbox(`dv-sbx`)或節點白箱放一份 `/etc/batman-build`,含 `BATMAN_WBOX=chan`,跑 `AUTOCOMMIT_DRYRUN=1 AUTOCOMMIT_FORCE_TRIAL=1 batman-autocommit run`(或真 trial),要看到「不 commit + revert 仍 armed」。拿掉那一行,同樣情況下應 COMMIT,這是負對照。

### F2 — LOW:兩條產出 payload 的路徑沒跑 gate(手動 `local-ab-tar.sh`、`fast-build.yml`)

- **情境(actor = 我們自己)**:
  - `build-board.sh --wbox test` 之後,有人用舊流程手動跑 `stamp-batman-build.sh` + `make` + `local-ab-tar.sh`。`test` 變體不改任何檔案,只靠 env 的 `BATMAN_PROV_TEST=1`。OpenWrt 的 rebuild 判斷看不到 env 的差異(lib-wbox 註解自己也這麼說)。結果可能是:沿用 `prov_test` helper 的 ipk,而 stamp 乾淨、不是 dirty。
  - `local-ab-tar.sh` 不跑 gate,`bin/targets/.../ab-payload-<board>.tar.gz`(檔名沒有版本)就會帶著 seam 出來。
  - `fast-build.yml` 會 upload `ab-payload`,也沒有 gate(這次只改了 `build-firmware.yml`)。
- **證據**:
  - ✅ `git show 6235f6ee:scripts/local-ab-tar.sh` 只跑 `check-image-manifest.sh`,沒有 `check-prov-test-gate`。
  - ✅ `fast-build.yml` 的步驟裡沒有 gate(`grep` 結果)。
  - ⚠️ OpenWrt 沿用舊 ipk 這一點是從 lib-wbox 的註解與 OpenWrt 機制推論,沒有實測。
- **影響**:只限 `test` 變體或 seam(killpoint 只有 root 能 arm,見 F6),所以不會削弱驗證。mutant 變體會因為檔案 mtime 改變而重編(⚠️ 推論)。
- **修法**:`local-ab-tar.sh` 在 carve 出 `root.squashfs` 之後,unsquashfs 到暫存目錄,依 rootfs 自己的 `BATMAN_WBOX` 跑 `check-prov-test-gate.sh`:有就傳名字,沒有就是正常模式。`fast-build.yml` 在 A/B payload 之前也加同一步。
- **負測試**:在 `test-build-board-wbox.sh` 加一案,用 `prov_test` helper + 乾淨 stamp 的假 rootfs 跑 `local-ab-tar` 的 gate 段,要 FAIL。

### F3 — LOW:正常 build 的 gate 只檢查 `/usr/bin/batman-provhelper` 有沒有 marker 和 killpoint 字串

- **情境**:`prov_test` helper 以另一個路徑或檔名進了 rootfs,例如誤改的 install 或另一個 package。正常模式只靠 witness 掃全 rootfs,而 `test` 變體沒有 witness。
- **證據**:✅ N8:release helper 放標準路徑,`prov_test` helper 複製到 `/usr/sbin/batman-provhelper-alt`,gate 回 `rc=0 ok (no test seam; helper tags=[])`。
- **修法**:`witnesses()` 已經全樹 `grep -r` 了。同一趟順便掃 `BATMAN_PROV_TEST_BUILD_7f3a` 和 `killpoint [^ ]*: armed`,正常模式命中就 FAIL。
- **負測試**:就是 N8,修好之後要 FAIL。

### F4 — LOW:殘留 mutant 的檢查 `wbox_normal_check` 漏掉 staged 與 quotePath 檔名

- **證據**:
  - ✅ SIGKILL 殘留(工作樹修改)會被正確拒絕:「still carries a wbox mutant」。
  - ✅ `git add` 之後(staged、工作樹等於 index),`git ls-files -m -o` 看不到它,所以檢查通過(`normal_check PASSED`)。
  - ✅ 非 ASCII 檔名:`ls-files` 輸出 `"feed/batman-prov/src/\303\244.go"`(加了引號),`[ -f ]` 為假,也通過。
- **後備**:stamp 用 `git -C feeds/batman status --porcelain`,所以 DIRTY 仍會成立。gate 的 rootfs witness 掃描還能擋第二次(前提是 witness 有編進去;lint 有保證 .go 的 witness 在字串常數裡)。
- **修法**:改用 `git -C "$feed" status --porcelain=v1 -z --ignored --untracked-files=all` 加上 `git diff --cached --name-only -z`,以 NUL 分隔讀。
- **負測試**:上面兩案(staged、非 ASCII 檔名)要 FAIL。

### F5 — LOW:gate 會讀呼叫端 env 的 `WBOX_DIR`、`GO`,而 `wbox_env_reset` 沒清掉它們

- **證據**:
  - ✅ W5:`WBOX_DIR` 指向一份把 `helper-notrial` 標成 `release same` 的 `helpers.list`,release helper 就被當成合格的 wbox 變體:`ok (wbox helper-notrial, tag release, same …)`。
  - ✅ N9b:`GO=/bin/echo` 時 `go version -m` 是假的,但 `strings` 檢查仍在(N9:`prov_test` helper 仍然 FAIL)。
- **影響**:只影響 wbox 模式分類是否正確,或在正常模式拿掉一層防線。不會讓 seam 進正常 build。
- **修法**:`wbox_env_reset` 加上 `unset WBOX_DIR GO`。gate 只在 `PROV_GATE_SELFTEST=1` 時才採用 `WBOX_DIR` 與 `GO`。
- **負測試**:W5 修好之後要 FAIL。

### F6 — INFO:killpoint 檔的 TOCTOU、symlink、hardlink、FIFO、特殊權限位 — 經實測防住

- ✅ 現有單元測試以 uid 1000 全過:`go test -tags prov_test ./seam/ ./cmd/batman-provhelper/ ./node/` 回 `ok`;release tag 也是 `ok`。
- ✅ 我另外補的探針(臨時 `zz_probe_test.go`,跑完已刪):
  - FIFO:不會卡住,回 `has the wrong type`,而且在受信任目錄裡被刪掉。
  - killpoint 是目錄:回 `wrong type`。
  - `"txn-1\x00"`、`"TXN-1"`、`"txn-1\ntxn-2"`:拒絕。
  - `" txn-1 \n\n"`:arm(TrimSpace)。
- 既有測試已經涵蓋:目錄 0777、檔案 0644、setgid、sticky、symlink(ELOOP)、第二個 hardlink、目錄本身是 symlink、owner 不符、太長、不受信任的目錄不 unlink。
- ⚠️ 剩下的競態:helper 先 `Lstat(Dir)`,再用路徑 `open`,沒有用 `openat`。要利用它,必須能寫 `/tmp/run`。base-files `etc/init.d/boot:26` 用 root 執行 `mkdir -p /var/run`,umask 022,所以應該是 0755(推論;**沒上節點看**)。唯一的非 root 使用者是 provd(471)。所以非 root 碰不到。可選的強化:`open(Dir, O_DIRECTORY|O_NOFOLLOW)` + fstat + `openat`。
- ⚠️ O_NONBLOCK 開一個裝置節點時,fstat 之前就有開檔副作用(例如 watchdog)。只有 root 能把它放進那個 0700 目錄,所以不是權限邊界。

### F7 — INFO:拒絕訊息原樣輸出 killpoint 檔內容(可偽造「armed」行)

- **證據**:✅ 內容 `"txn-9\nkillpoint txn-1: armed"` 產生的 log 是 `killpoint: refused (unknown point txn-9\nkillpoint txn-1: armed)`,換行原封不動。⚠️ OpenWrt logd 與 logread 會不會把它切成兩行,我沒上節點驗。如果會切,§16.1 和 P9 用 `killpoint .*: armed` 判定時就會被騙。
- **影響**:只有 root 能寫那個檔,所以不跨權限。但它影響 harness 證據的完整性。
- **修法**:`refuse(logf, fmt.Sprintf("unknown point %q", name))`。
- **負測試**:就是上面的探針,要斷言 log 只有一行、不含換行。

### F8 — INFO:release helper 的差異(遠端與本機攻擊面)

- ✅ 以 Go 1.26.4(tree 的 hostpkg)從 `origin/main` 和 `1f82e36` 各 build arm64 release(`-trimpath -ldflags='-s -w'`):
  - `go tool nm`(未 strip 版)的符號差異只有 `> main.version`。
  - `strings -n 8` 的差異只有版本相關字串、`strings/iter.go` 和 build ID。
  - release 的 `killpoint`、`BATMAN_PROV_TEST_BUILD`、`batman-prov-test`、`sysrq-trigger`、`/dev/kmsg`、`claim-after-persist`、`txn-3`、`reboot -f` 全是 0。
  - `prov_test` 版對應是 8/1/1/2/1/1/1/1。
  - `go version -m` 的 release 沒有 `-tags`,`prov_test` 版有 `-tags=prov_test`。
- ✅ 行為(amd64,非 root):

  | 版本 | `--version` | `--version x`、`--boot`、空參數、`qr` |
  |---|---|---|
  | 舊 | 2 `root only` | 2 `root only` |
  | 新 release | rc 0,`batman-provhelper unknown` | 2 `root only` |
  | 新 `prov_test` | 第二行多 marker | 2 `root only` |

  也就是說,`--version` 只在剛好兩個 argv 時才繞過 euid 檢查,讀的是寫死的 `/etc/batman-build`,沒有 env 或參數輸入。洩漏的只有版本字串;⚠️ `/etc/batman-build` 在節點上應該本來就可讀(沒驗權限)。
- claim 與 txn 的呼叫點在 release 裡是 no-op(`seam_release.go`),`commit` 的行為等價(`commitTxn(next,"",seam.None)`)。

### F9 — INFO:秘密

- ✅ 讀過 13 個 patch、seam、gate、lib-wbox。log 與 kmsg 只有 point 名、錯誤字串、頻道、狀態字。`helper-clientchal` 只寫「adopted」,不寫 chal 的位元組。
- ✅ `wbox-chan` 以唯讀方式掛 p5 到 `mktemp -d /tmp/wbox-chan.XXXXXX`(root 0700),只用 sed 取 channel。掛載期間非 root 進不去。
- build log 只有 witness 和名字。沒發現任何秘密。

### F10 — INFO:feed 還原與 build 中斷 — 經實測

- ✅ 用一個假 feed 加上 `lib-wbox.sh` 的副本:`wbox_apply` 之後對 process group 送 INT、TERM、HUP,三種情況 `git status` 都是空的(EXIT trap 有跑)。只有 SIGKILL 會留下殘留,下次正常 build 會被 `wbox_normal_check` 拒絕(F4 例外)。
- ✅ CI 的順序:gate 在 `Stamp in rootfs (#209)` step(`:229`),早於 `Build A/B OTA payload`(`:241`)和所有 upload(`:284+`)。gate FAIL 會讓 job 失敗,`build-release.yml` 的 release job 依賴它。
- ✅ `--wbox` 和 `--card-only`、`--update-lock` 互斥(程式碼)。root 不會建立 build lock(程式碼)。

### F11 — INFO:13 個 mutant 的危險分級(誤 commit 時)

| 等級 | mutant | 誤 commit 的後果 |
|---|---|---|
| 削弱驗證或擁有權 | `helper-nojoinop` | 不驗 owner-op |
| | `helper-clientchal` | 採用 client 給的 chal(⚠️ 可重放) |
| | `rc9-unclaimed` | legacy 變 unclaimed,可被搶先 claim |
| | `helper-notrial` | trial 槽也接受改狀態 |
| 破壞一致性或持久化 | `helper-notxn`、`helper-norebuild`、`96-noprov`、`96-norestore` | 一致性或持久化出錯 |
| | `helper-noleave` | leave 後留下 mesh marker |
| 可用性 | `radio1-off`、`chan`、`helper-exit1`、`helper-flap` | 斷網或 helper 不在 |
| | `test` | 只有 seam(root 才能 arm) |

所以 F1 的影響以第一組為準。

---

## 證據分類

### ✅ 驗證過(原始輸出節錄)

- Release 與 `prov_test` helper 的 build 和比對(F8):符號差異只有 `> main.version`。release 字串計數:`killpoint=0 BATMAN_PROV_TEST_BUILD=0 batman-prov-test=0 sysrq-trigger=0 /dev/kmsg=0 claim-after-persist=0 txn-3=0 reboot -f=0`。
- 非 root 行為(F8):`new-rel-amd64 [--version] rc=0 out=[batman-provhelper unknown]`,`[--boot] rc=2 out=[batman-provhelper: root only]`。
- seam、cmd、node 單元測試以 uid 1000 執行:`ok batman-prov/seam`、`ok batman-prov/cmd/batman-provhelper`、`ok batman-prov/node`(`prov_test` 與 release 兩種 tag 都是)。
- killpoint 探針(F6、F7)的結果如上。
- gate 副本對造出來的 rootfs:

  | 案例 | 結果 |
  |---|---|
  | N1 release helper | ok |
  | N2 `prov_test` helper | FAIL `-tags prov_test` |
  | N3 helper 是 symlink | FAIL |
  | N4 正常模式但有 `BATMAN_WBOX=test` | FAIL |
  | N5 rootfs 有 witness | FAIL |
  | N6 有不可讀的檔 | FAIL(grep rc 2) |
  | N7 沒有 host Go | FAIL |
  | N8 `prov_test` helper 在別的路徑 | **ok(F3)** |
  | N9 `GO=echo` + `prov_test` | FAIL(marker) |
  | N9b `GO=echo` + release | ok |
  | N10 版本含 wbox 但沒有那一行 | FAIL |
  | N11 沒有 helper | FAIL |
  | N12 stamp 不可讀 | FAIL |
  | N13 helper 不可讀 | FAIL |
  | N14 rootfs 有 FIFO | ok,不會卡 |
  | W1 `helper-notrial` | ok |
  | W2 `test` 用 release helper | FAIL |
  | W3 `test` | ok |
  | W4 名字 `../x` | FAIL |
  | W5 用 `WBOX_DIR` 改分類 | **ok(F5)** |

- lib-wbox 的信號與殘留測試(F4、F10)的結果如上。
- 節點端沒有 wbox 拒絕、harness 沒有 P9 的 grep 結果(F1)。

### ⚠️ 推論或部分驗證

- 節點上 `/tmp/run` 的權限(由 base-files 推論)。
- logd 是否切斷換行(F7)。
- OpenWrt 會不會沿用 `prov_test` ipk(F2)。
- `helper-clientchal` 的重放可行性(F11)。
- 節點上 `/etc/batman-build` 是否 world-readable(F8)。

### ❌ 沒做

- 沒在 arm64(qemu)或節點上跑 helper,沒有 ssh。
- 沒跑 firmware 的 `test-prov-test-gate.sh` 與 `test-build-board-wbox.sh` 原檔。我改以副本直接驅動同一份 `check-prov-test-gate.sh` 與 `lib-wbox.sh`。
- 沒跑 `lint-wbox.sh` 和 `gen.sh`。
- 沒實際跑 `build-board.sh` 或 `make`(依指示不碰正在 build 的 tree)。
- 沒驗 `fast-build.yml` 的 cache 內容。
