# PR-P1b + firmware --wbox 程式碼審查 第 3 輪 — 審查者 A

- Batman `feat/254-p1b-seams` @ 014778c(`origin/main...HEAD -- feed/batman-prov`,13 檔 +811/−5)
- firmware `feat/254-wbox` @ a0aedd98(`e7c2a222..a0aedd98`,9 檔 +431/−3);`rc/254-p1b` @ c62468e6 的 `scripts/` + `.github/` 與 a0aedd98 相同(`git diff a0aedd98 c62468e6 -- scripts .github | wc -l` = 0)
- rc 的 Batman pin f6ac1f7:`git diff --stat 014778c f6ac1f7 -- feed/batman-prov` 為空,所以 rc 跑的就是本輪審的程式碼(r2 B-MAJOR-1 / A-m7 已解)
- 設計 `254-h23-harness.md` @ cf26d7d:§2.1、§4.1.1–§4.1.3、§4.2、§6.2 L7、§8、§15、§16(含 §16.10–18)
- 做法:唯讀。Batman 以 `git archive 014778c` 解到 `/home/yello/rr3A-go.*`;firmware 腳本以 `git show c62468e6:` 取出;mutant 只在副本;沒在 `/home/yello/firmware-2710` build、沒換 checkout;沒碰節點;沒 commit / push。Go = firmware staging go1.26.4。結束已刪暫存目錄。

## 摘要

這輪從現場出發重看整份變更:操作者 build 各變體(中斷、兩個同時跑)、出貨 image、受攻擊的節點、CI 在新舊 pin 上、合併順序。

- **第 2 輪的 MAJOR 都修好了,且有負對照。**
  - r2 A-MAJOR-1:新增 `lib-wbox.sh` 與 `test-build-board-wbox.sh`(34 案例)。我另做 7 個 lib mutant,其中 6 個讓測試 BAD。
  - r2 B-MAJOR-1:rc 改 pin f6ac1f7,內容等於 014778c;payload 是重 build 的。
- **真 payload 正反都對。** normal 的 helper 沒有任何 seam 字串;wbox-test 的 helper 有 `-tags=prov_test`、armed 字面值與 marker。gate 在兩種模式下判定都正確,也擋得住「normal rootfs + 真 wbox helper」。
- **沒有 BLOCKER、沒有 MAJOR。** 有 6 個 MINOR,都是測試或文字的缺口,或是 build-board 以外的旁路;沒有一個會讓 seam 進到出貨 image 而不被發現。
- **❌ firmware CI 從未在 GitHub 跑過。** 最後一次 run 是 10-08,本分支沒有 run。依「開 PR 後必看 CI」規則,這不算 finding,但 PR 開出前不能宣稱 ready。

## 第 2 輪項目逐條核對

| 第 2 輪 | 狀態 | 證據(本輪實跑) |
|---|---|---|
| A-MAJOR-1 wbox 步驟無回歸測試 | ✅ | `test-build-board-wbox.sh` 34 ok;lib mutant:no-trap 4 BAD、no-ignored 2 BAD、no-inprogress 1、no-flock 1、prov-test-always 1、in-progress 當完成 1;**`clean -qfdx`→`-qfd` 存活**(m1) |
| B-MAJOR-1 rc 不是審過的程式 | ✅ | pin f6ac1f7 對 014778c 的 `feed/batman-prov` diff 為空;payload `BATMAN_FEED_COMMIT=f6ac1f7`、`BATMAN_FW_COMMIT=739c163` |
| A-m1 / 原因比對 + 64 B | ✅ | `refusedWith` 比對結尾;mutant no-maxfile → `TestRefusals` FAIL |
| A-m2 gate 自測覆蓋 | ✅ | 自測 45 ok / 0 bad;r2 列的 5 條(normal-version r7、wb-name ro、pt-marker rc、witness-format rd、elf-nogo ra)都有案例 |
| A-m3 / B-m8 舊 pin 訊息 | ✅ | BATMAN_SRC = 7fd2124 → `predates the #254 P1b seams … pin a Batman that has them` rc=1 |
| A-m4 / B-MINOR-7 init 路徑寫死 | ✅ gate 改 `feed/[^/]*/`(自測 ri / rj);⚠️ `wbclean` 仍只清兩個套件,沒有記錄(m5) | |
| A-m4 / B-MINOR-7 release 帶點名 | ✅ | arm64 release:`claim-after-persist=0 claim-before-shadow=0 txn-3=0`;真 payload 同為 0 |
| A-m5 kmsg / boot-reason (f) | ✅ 程式;⚠️ kmsg 行能否進 console capture 未證(m4) | mutant no-kmsg → `TestFireWritesKmsgThenSysrq` FAIL |
| A-m6 main.go 接線 | ✅ 記為殘項(§16 末) | — |
| A-m8 設計舊名 | ⚠️ 部分:§2.1 已改;**§4.1.3 仍寫「`test` 的見證 = helper 標記」**(m2) | `grep -n` 第 178 行 |
| B-MINOR-1 txn-3 rc≠0 分支 | ✅ | mutant txn3-rc0-only → `TestKillpointTxn3AfterLateProvOnlyFailure` FAIL |
| B-MINOR-2 鎖 | ✅ | 測試「second build refused」;mutant no-flock → BAD |
| B-MINOR-3 `same` 欄 | ✅ | 自測 rf / rg |
| B-MINOR-4 symlink helper | ✅ helper;**❌ `etc/batman-build` 同理沒做,也沒記錄**(m3) | 構造案例見 m3 |
| B-MINOR-5 §6.2 L7 列文字 | ✅ | 第 362 行改為「全部:§16.1 的判定」 |
| B-MINOR-6 fallback 證據缺席 | ✅ | `sysrq write failed` 立即 log + kmsg;mutant sysrq-fail-silent → FAIL |

## 發現

### BLOCKER
無。

### MAJOR
無。

### MINOR

**m1 `test-build-board-wbox.sh` 沒有守住 trap 的 `-x`:「變體在 build 期間產生的 ignored 檔」沒有案例**(✅ 實證)

- 情境:日後有人把 trap 的 `clean -qfdx` 改成 `-qfd`。之後 wbox patch 或 build 在 `feeds/batman` 留下 ignored 檔(例如 `__pycache__`)時,trap 就不會清掉它。
  - 下一次 build 的乾淨檢查會拒絕(fail-closed),不會疊加 mutant。
  - 但操作者會被一個與自己無關的拒絕擋住。
  - §16.13 寫的「8 個 lib 突變各自 BAD」不包含這一條。
- 證據:lib mutant `no-clean-x`(`clean -qfdx" EXIT` → `clean -qfd" EXIT`)跑出 `RESULT build-board wbox test: 34 ok, 0 bad`。
- 修法:`chan` 的假 patch 另新增一個符合 `/ignored-*` 的檔(例如 `+++ b/ignored-mut`),`ok_case` 斷言結束後 `clean`(含 `--ignored`)為空。順手在 SIG 迴圈加 `HUP`:ssh 斷線是操作者最常見的中斷方式。我實測過 HUP 下真 lib 會還原(rc=129,status 空),只是沒有測試保護。

**m2 設計 §4.1.3 仍寫「`test` 的見證 = helper 標記」,與實作和 §16.8 衝突**(✅)

- 實作與 §16.8 的規則都是 `test` = 空集合。自測 w4b 證明:`test` 帶任何見證都會 FAIL。
- harness 作者若照 §4.1.3 去找 helper 標記當見證,會跟 gate 對不上。
- 修法:就地改成「`test` 的見證集合 = 空(§16.8)」。

**m3 gate 讀 `etc/batman-build` 時會跟隨絕對 symlink,讀到 build 主機的檔**(✅ 構造實證;r2 B-MINOR-4 的後半)

- 證據:取真 wbox-test rootfs,換上 release helper,再把 `etc/batman-build` 換成指向主機檔(內容只有 `BATMAN_VERSION=1.5.14-wsl.6`)的絕對 symlink。normal 模式結果是 `ok (no test seam; helper tags=[])`,rc=0。
- 影響有限:helper 的四條 noseam 檢查與見證掃描照常生效,seam 不會因此漏過。被繞過的只有「wbox 標籤」這一條。觸發者只可能是我們自己的錯或惡意 patch。
- 修法:比照 helper,加 `[ ! -L "$R/etc/batman-build" ] || fail …`,並補一個自測案例;或在 §16 寫明不做。

**m4 「console capture 帶著點名過重開」(§16.11、`seam_provtest.go` 檔頭)的前提沒有證據**(⚠️ 推論)

- `kmsg()` 寫進 `/dev/kmsg` 的 `<4>` 行要進 ramoops console capture,需要兩個條件:
  - `kernel.printk_devkmsg` ≠ `off`(`off` 時 `devkmsg_write` 會靜默丟棄);
  - console_loglevel > 4。
- 目前查到的事實(✅):
  - kernel `.config` 有 `CONFIG_CONSOLE_LOGLEVEL_DEFAULT=7`;
  - `logs/bootdir-ekh-bcm2711/cmdline.txt` 沒有 `quiet` / `loglevel=`;
  - rootfs 的 `etc/sysctl.d` 沒有 `printk` 設定;
  - `95-batman-storage:420` 自己就記錄 `devkmsg=$(cat /proc/sys/kernel/printk_devkmsg)`,表示這個值在節點上可能不是預設。
- 節點上的實際值沒有查(依指示)。
- (f) 的判定只看核心自己的 `sysrq: ` 行。核心印這行時會暫時拉高 loglevel,所以 (f) 不受影響;受影響的只是「點名也在 capture 裡」這個宣稱。
- 修法:E-H6 用 `logger` / `echo b` 之外,再加一行 `echo '<4>e-h6 kmsg-probe' > /dev/kmsg`,重開後在存下的 console 記錄 grep 它。不在 → 把檔頭與 §16.11 的宣稱降為「若 devkmsg 可寫」。

**m5 wbox patch 的範圍沒有約束:可以碰 `tests/wbox/helpers.list`,也可以碰 `batman-prov` / `batman-provision` 以外的套件**(✅ 程式碼;⚠️ 情境為推論)

- `wbox_apply` 在套 patch **之前**讀 `helpers.list` 決定 tag;gate 在 step 7 讀的是套 patch **之後**的同一個檔(`check-prov-test-gate.sh:212-216`)。patch 若改到 `helpers.list` 的那一行,build 與 gate 用的是兩份不同的契約。
- `wbclean` 只清兩個套件(`build-board.sh` `wbclean()`)。patch 碰到第三個套件時,只能靠 OpenWrt 的 mtime rdep 觸發重 build。
- 能擋這兩件事的 `lint-wbox` 在 harness PR,本輪不在範圍;§4.2 也沒寫「patch 只能碰 `feed/batman-prov/**`、`feed/batman-provision/**`」。這是 r2 A-m4 後半,沒有修,也沒有記錄。
- 修法(便宜):`wbox_apply` 在 `git apply --check` 前加一行:`grep '^+++ b/' "$feed/$wp" | grep -vqE '^\+\+\+ b/feed/batman-prov(ision)?/' && { echo "wbox patch touches files outside the two packages"; exit 1; }`,並在 `test-build-board-wbox.sh` 補一個案例;或把這條契約寫進 §4.2 / §16,交給 lint-wbox。

**m6 build-board.sh 以外的路徑不經過 gate**(✅ 程式碼;⚠️ 情境需要人為偏離流程)

- `scripts/local-ab-tar.sh` 從 `bin/targets` 打 payload 時只跑 `check-image-manifest.sh`,不跑 `check-prov-test-gate.sh`。
- wbox build 結束後,`files/etc/batman-build` 仍是 `…dirty.wbox-test` / `BATMAN_WBOX=test`(✅ 現況就是如此),`build_dir` 裡也還是 prov_test helper,要到下一次 build-board 的 `wbox_stamp_begin` 才會清。
- 這時有人單獨跑 `stamp-batman-build.sh` 加 `make` 再加 `local-ab-tar.sh`,就會得到一個標成 normal、但 helper 帶 seam 的 payload,而且沒有任何 gate 擋。
- 單獨跑 `make` + `local-ab-tar.sh` 時,產物仍標 wbox(標籤正確),風險較低。
- 節點端還有 P9 / tier A 的標記檢查兜底。
- 修法:`local-ab-tar.sh` 在打包前呼叫 `check-prov-test-gate.sh <rootfs> $(sed -n 's/^BATMAN_WBOX=//p' …)`;或在 §9 殘項寫明「只有 build-board.sh / CI 的產物受 gate 保護」。

## 介面與生命週期(整體)

**擁有權**

| 資源 | 寫者 | 讀者 | 本輪判斷 |
|---|---|---|---|
| `feeds/batman` 工作樹 | `wbox_apply` 套、EXIT trap 還原;乾淨檢查在 trap 之前 | step 7 gate | ✅ 單一寫者(鎖 + 乾淨檢查);m5 |
| `logs/.build-board.lock` | `bb_lock`(fd 9 活到 exit) | 第二個 build-board | ✅;fd 9 會被 make 子程序繼承。實證:連續 build 之間沒有殘留持有者 |
| `logs/wbox-<board>.stamp` | `wbox_stamp_begin` / `_done` | 同上 | ✅;現況 `in-progress:test|1`(= ctrlc2-test 中斷後的狀態,與 log 一致) |
| `files/etc/batman-build` | `stamp-batman-build.sh` | image、gate | ✅;m6 |
| killpoint 檔 | harness 寫;helper `Arm` 讀完即刪(只在可信目錄) | — | ✅ |
| `seam.armed`(記憶體) | `Arm`(daemon 啟動、serve 之前)/ `ArmForTest` | `At` | ✅;`-race -shuffle -count=2` 兩種 tag 都 ok |

**契約**

- `--version`:在 root 檢查之前處理,任何 uid 都能跑;只讀 world-readable 的 `/etc/batman-build`。line 1 = `batman-provhelper <VER|unknown>`;prov_test 多一行 marker;rc 0。舊版回 usage rc 2。✅ `TestVersion` / `TestVersionNoStamp`;mutant version-no-marker → FAIL。
- killpoint 檔:缺 → 無動作、無 log;任何不符 → `refused`(fail-closed)。✅ 13 個拒絕或位置 mutant 在 r2 已紅,本輪另加 no-maxfile、wrong-owner-ok、at-any、cbs-before-lastknown 也全紅。
- gate:讀不到就 FAIL。自測 45/45,其中包含 no strings、no Go、no helpers.list、unreadable、symlink helper 等案例;m3 是例外。
- `helpers.list`:tag 與 kind 都是封閉清單,build 與 gate 雙邊檢查。✅

**生命週期**

| 路徑 | 行為 | 證據 |
|---|---|---|
| install / 首次 | wbox 不能做卡(`--card-only --wbox` → exit 2);卡片 step 7 跑 normal gate,wbox rootfs 會 FAIL | ✅ 程式碼 `build-board.sh:49-51`;gate(normal) 對 wbox rootfs → `carries BATMAN_WBOX=test` |
| start | 只有 daemon 會 `Arm`;`--boot` 只印 marker | ✅ diff |
| clean stop / restart / crash loop | 檔讀完即刪,respawn 不會再 arm;tmpfs 重開即清 | ✅ 程式碼 + `TestArmedLineIsTheGateLiteral` |
| 操作者中斷 build | INT / TERM / HUP / 只 TERM bash:EXIT trap 還原;SIGKILL:下次拒絕(殘留留給人查) | ✅ 測試 INT / TERM;本輪另測 HUP rc=129、只 TERM bash rc=143,status 都為空 |
| 兩個 build | 第二個 exit 2 | ✅ 測試 |
| 變體切換 / 中斷後 | in-progress → 下次必清 | ✅ log:`wbox variant changed (in-progress:none\|0 -> test\|1)` |
| upgrade / rollback / downgrade | wbox 只走非 committed 槽 + hold(harness);pre-P1b 的 `--version` 回 rc 2 | ⚠️ harness 不在本輪 |
| 斷電 / sysrq | 刻意不 sync;`/proc/sysrq-trigger` 不受 mask 影響;bcm2711 / bcm2710 的 kernel config 都有 `CONFIG_MAGIC_SYSRQ=y` | ✅ config 檔;⚠️ 節點未測(E-H6) |
| CI 新 pin / 舊 pin | 新:自測 45 ok;舊 pin:明確失敗(§16.17 刻意) | ✅ 本機;❌ GitHub 未跑 |
| 合併順序 | harness → P1b → firmware(pin 指向 main 上含 P1b 的 commit)。feat 現 pin 7fd2124,PR 開出時 CI 必紅,要先 bump | ✅ `feeds.conf.default` |
| 平台 | bcm2711 已 build 兩種;bcm2710 未 build | ❌ bcm2710 |

## 安全

- **攻擊面增量**
  - release helper:只多了 `--version`(唯讀,資訊本來就 world-readable)。
  - prov_test helper:多一個 root 0700 目錄下的 root 0600 檔,以 `O_NOFOLLOW|O_NONBLOCK` + fstat 讀取,另有 nlink、特殊位元、64 B 上限。
  - 結論:沒有新增可遠端觸及的輸入。
- **release 二進位**:arm64 `-s -w -trimpath` 與真 payload 的這些字串都是 0:`killpoint`、armed 字面值、marker、點名、`sysrq-trigger`、`batman-prov-test`、`/dev/kmsg`、`reboot -f`。✅
- **非 root 本機**:進不了 `/tmp/run/batman-prov-test`(靠 `/tmp/run` 是 root 0755,⚠️ 沿用設計事實,未上機);即使預建了也會因 owner / mode 被 refused(Go 單元)。
- **攻陷的 root 元件**:本來就能重開,沒有提權。
- **特權碰低權路徑**:`--card-only` 以 root `exec 9>>logs/.build-board.lock`,這個路徑由樹的擁有者控制(可放 symlink → root 建立空檔)。但 `--card-only` 本來就以 root 執行樹內的腳本,樹擁有者早已等同 root,所以沒有新增的信任邊界。記為資訊,不列 finding。
- **供應鏈 / 我們自己的錯**:
  - step 7 與 CI 會擋 seam 進 normal image;自測對 5 類 release mutant(marker-only / killpoint-only / names-only / prov_test tag / 實作在 `_test.go`)都 FAIL。
  - build-board 以外的旁路見 m6;batman-build symlink 見 m3。

## 實際執行(✅,原始輸出節錄)

```
# Go 1.26.4,git archive 014778c(只解 feed/batman-prov/src)
vet tags=[] rc=0 ; vet tags=[prov_test] rc=0
test tags=[]          rc=1:cbor/cose/keystore/proto FAIL "open ../../../../tests/vectors/219-protocol/vectors.json: no such file"
  → 歸因(翻轉):只把來源換成整棵 git archive 014778c → tags=[] rc=0 ok=12 FAIL=0 ; tags=[prov_test] rc=0 ok=12 FAIL=0
     = 我只解了子目錄,測試向量在 repo 根;不是產品問題
SKIP 4 / 4(既有 root-only,同 r2)
-race -shuffle=on -count=2 ./seam ./node ./cmd/... 兩種 tag → ok ×3

# arm64 -trimpath -s -w CGO=0
tags=[]          killpoint=0 armed=0 marker=0 claim-after-persist=0 claim-before-shadow=0 txn-3=0 sysrq-trigger=0 batman-prov-test=0 /dev/kmsg=0 reboot -f=0 (no -tags line)
tags=[prov_test] killpoint=7 armed=1 marker=1 cap=1 cbs=1 txn-3=1 sysrq-trigger=1 batman-prov-test=1 /dev/kmsg=1 reboot -f=1 ; build -tags=prov_test

# Go mutants(-tags prov_test)— 全紅
no-kmsg              FAIL TestFireWritesKmsgThenSysrq
no-maxfile           FAIL TestRefusals
txn3-rc0-only        FAIL TestKillpointTxn3AfterLateProvOnlyFailure
at-any               FAIL TestAtFiresOnlyTheArmedPoint / TxnPositions / ClaimPositions
cbs-before-lastknown FAIL TestKillpointClaimPositions
version-no-marker    FAIL TestVersion
sysrq-fail-silent    FAIL TestFireWritesKmsgThenSysrq
wrong-owner-ok       FAIL TestWrongOwnerRefused

# 真 payload
normal  a837adf4…-ab-payload.tar.gz  SHA256SUMS OK ; BATMAN_VERSION=1.5.14-wsl.6+f6ac1f7.fw739c163 DIRTY=0 無 WBOX 行
        helper 78b2e482… CGO_ENABLED=1 無 -tags ; 上列字串全 0
        gate(normal) → ok (no test seam; helper tags=[]) rc=0 ; gate(test) → FAIL BATMAN_WBOX=[], want test rc=1
wbox    b4c5741d…-ab-payload.tar.gz  SHA256SUMS OK ; …fw739c163.dirty.wbox-test DIRTY=1 BATMAN_WBOX=test
        helper 0affc692… -tags=prov_test ; killpoint=7 armed=1 marker=1 /dev/kmsg=1
        gate(normal) → FAIL carries BATMAN_WBOX=test rc=1 ; gate(test) → ok (wbox test, tag prov_test, helper, helper tags=[prov_test]) rc=0
(unsquashfs 非 root rc=2 = 屬主/xattr,r2 B 已歸因;gate 的 grep 沒遇到讀不到的檔)
構造:normal rootfs + 真 wbox helper → FAIL "helper built with -tags prov_test" rc=1
構造:wbox rootfs + release helper + etc/batman-build→主機檔 symlink → ok rc=0   ← m3

# build log(作者的,本輪讀)
eh2-wsl6b-normal: "wbox variant changed (test|1 -> none|0): cleaning…" ; step 7 "check-prov-test-gate: ok (no test seam; helper tags=[])"
eh2-wsl6b-test:   "wbox variant test (tag prov_test): applied" ; "(none|0 -> test|1)" ; step 7 "ok (wbox test, tag prov_test, helper, …)"
ctrlc2-normal / ctrlc2-test:停在 step 5;後者 "(in-progress:none|0 -> test|1)"。樹現況:feeds/batman status --ignored 空、stamp in-progress:test|1

# firmware 腳本(c62468e6 取出)
gate 自測 BATMAN_SRC=014778c → RESULT gate self-test: 45 ok, 0 bad
gate 自測 BATMAN_SRC=7fd2124 → "predates the #254 P1b seams …" rc=1
test-build-board-wbox.sh → RESULT 34 ok, 0 bad
lib mutants:no-trap 30/4 · no-ignored 32/2 · no-inprogress 33/1 · no-flock 33/1 · prov-test-always 33/1 · in-progress-as-done 33/1 · no-clean-x 34/0 ← m1
HUP 到 job 的 group → rc=129 restored ; 只 TERM bash → rc=143 restored
shellcheck -S warning:SC2064(lib trap 的 $feed 當下展開,刻意且值固定)、SC2034(測試未用的 i)、SC2148(lib 無 shebang)— 無實害
```

## 分類

- ✅ 已實證:上方所有輸出、第 2 輪項目表、pin 內容相等、兩板 kernel config 的 MAGIC_SYSRQ、CI 的 if 只對 ekh 兩板生效(`Stamp in rootfs (#209)` 步驟)。
- ⚠️ 推論:
  - kmsg 行能否進 console capture(m4);
  - `/tmp/run` 在節點是 root 0755;
  - fd 9 被長命子程序繼承(實際未見);
  - test-build-board-wbox 的計時型案例(`sleep 0.5` 取鎖、5 s 等 patch)在忙碌的 CI runner 上的穩定度;
  - m5 / m6 的情境。
- ❌ 沒做:
  - firmware CI 在 GitHub 執行(`gh run list -R winson3QQ/firmware` 最新是 10-08,本分支無 run);
  - bcm2710 的 normal / wbox build;
  - Go 單元以 root 跑;
  - 節點上任何驗證(E-H2 的上機部分、E-H6)。

## 結論

**APPROVE-WITH-CHANGES**:0 BLOCKER / 0 MAJOR / 6 MINOR。

- 程式碼可以進;第 1、2 輪的所有 MAJOR 都已修好並有負對照。
- 建議這輪就改:m1(補 `-x` 與 HUP 案例)、m2(§4.1.3 一句話)、m3(batman-build symlink:修,或寫明不做)。
- m4 併入 E-H6;m5、m6 修,或寫進 #254 checklist(§9 殘項)。
- PR 開出前:firmware 的 pin 必須先 bump 到 main 上含 P1b 的 commit,並等 GitHub CI 全綠或每個紅燈都歸因;不能只憑本機的自測宣稱 ready。
