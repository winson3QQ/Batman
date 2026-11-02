# P1b 程式碼審查 第 2 輪 — 審查者 B

範圍(整體變更,不只第 1 輪的修正):
- Batman `feat/254-p1b-seams` @ c1901db(= origin,`origin/main...HEAD -- feed/batman-prov`,vendor 除外)
- firmware `feat/254-wbox` @ 55fe0459(`e7c2a222..`;1fc28b95 + 55fe0459)。`rc/254-p1b` 上的 d834177a 與 55fe0459 在 `scripts/`、`.github/` 無差異(`git diff 55fe0459 d834177a` 空)
- 設計 `254-h23-harness.md` @ 5b277e8:§4.1.1–§4.1.3、§4.2、§6.2 L7 列、§8 E-H2/E-H6、§15、§16

做法:唯讀。Go 測試、arm64 編譯、mutant 都在 `git archive` 出來的 `/tmp/revr2B*` 副本裡跑(自己的 GOCACHE,跑完已刪);firmware 樹沒 build、沒換 checkout;沒碰節點;沒 commit / push。

## 摘要

- Go 這半邊:第 1 輪的 A-M3、B-m6、A-m9、A-m10 都真的修好,且有負對照。`seam_points_test.go` 對 13 個 mutant 有 12 個變紅;**唯一存活的是「txn-3 只在 `--prov-only` rc 0 分支觸發」**:§16.5 說 rc≠0 讀回分支也會觸發,但沒有測試覆蓋。
- firmware 這半邊:B-M1(樹不乾淨)修好,舊版負對照重現了疊加和刪掉開發者修改,新版都會拒絕。gate 的 14 個檢查逐條拿掉,有效的 12 個 mutant 自測各自變 BAD。兩個真 payload 用新 gate 判,模式都正確。
- 1 個 MAJOR:**rc 1.5.14-wsl.5 釘的 Batman 01b12c9 不含第 1 輪的 Go 修正**(19d9373、c1901db)。而 `feat/254-wbox` 自己釘的 7fd2124 沒有 seam 套件,自測會失敗。所以現在沒有任何一棵樹或任何一個 payload 同時是「審過的 firmware 腳本 + 審過的 Batman 程式碼」。
- 8 個 MINOR(見下)。

## Findings

### MAJOR-1 rc 與審查對象錯位:現有的 wsl.5 payload 跑的是第 1 輪之前的 Go 程式碼;`feat/254-wbox` 單獨無法通過自己的 CI
- 證據(✅):
  ```
  c6601e7 in 01b12c9
  19d9373 NOT in 01b12c9      # killpoint 位置測試 + fstat 讀法 + commitTxn 點名重構
  c1901db NOT in 01b12c9
  git diff --stat 01b12c9 HEAD -- feed/batman-prov: node.go 2, txn.go 8, seam_provtest.go 51, +seam_points_test.go, +hook_provtest.go …
  feat/254-wbox:feeds.conf.default → Batman ^7fd21246…(main,pre-P1b)
  self-test, BATMAN_SRC = 7fd2124 → "h-mark mutant not applied"(rc≠0,沒有 RESULT 行)
  ```
- 情境:
  - 操作者或 harness 拿 `~/out/1.5.14-wsl.5+01b12c9.fwd2a4bfd*` 去做 E-H2/E-H6 或 tier B,以為測的是審過的程式碼。實際上節點跑的 `Arm` 是舊的 Lstat + `ReadFile(path)` 寫法,`commit()` 也還是用 `what` 推點名。
  - 那兩個 payload 是在 55fe0459(gate 強化)之前 build 的,build 時 step 7 跑的是舊 gate。
  - firmware PR 若以 `feat/254-wbox` 原樣開出,`build-firmware.yml` 的自測會紅,而且錯誤訊息 `h-mark mutant not applied` 指不到真正原因(pin 早於 P1b)。
- 修法:
  1. 從 c1901db 加 harness 的 `tests/wbox` 重切 `rc/254-p1b`。
  2. firmware rc 改釘新 commit,`BATMAN_BUILD_N` 加 1(wsl.6),免得兩份不同內容都叫 wsl.5。
  3. 用新的 build-board 重 build normal 與 `--wbox test`,E-H2 重跑,包含 step 7 gate 的輸出。
  4. firmware PR 的 pin 必須指向含 seam 的 Batman(依 §8,PR-P1b 先進 main 再 bump)。
  5. 自測加前置檢查(見 MINOR-7)。

### MINOR-1 txn-3 的「rc≠0 + 讀回 gen 已前進」分支沒有測試(§16.5 的宣稱沒有負對照)
- 證據(✅):mutant `txn3-rc0-only` 把 `seam.At(afterPersist)` 改成只在 `rc == 0` 時呼叫,結果 `go test -tags prov_test -run Killpoint ./node ./seam` 得到 **rc=0**。其餘 12 個 mutant 都紅:txn4 搬到 RemoveTxn 前、拿掉 cbs、txn-1 放進 commit、拿掉 cap、txn-2 移到 setkey 前、拿掉 txn-5、只比 Perm、拿掉 Nlink、在不可信目錄 unlink、目錄 mode 不檢查、拿掉 O_NOFOLLOW、檔案不刪。
- 情境:`--prov-only` 在 p5 已寫入後回 rc≠0(例如 `--save` 階段的非致命錯誤)正好是 L7 txn-3 想覆蓋的現場路徑。點若被移出這個分支,CI 全綠,要到 04 硬重開才發現。
- 修法:在 rig 加一個開關,讓 `Persist` 回 rc≠0、`GetP5` 回 gen = next,接著 `stopAt(t, r, "txn-3", …)`,斷言和 rc 0 的情況相同。

### MINOR-2 build-board 沒有鎖:兩個 build 同時跑時,`feeds/batman` 有兩個寫者
- 證據(✅,假 `feeds/batman` 上直接跑 build-board 的 wbox 區塊):兩個 `--wbox`(ma、mb)同時起跑,兩邊都通過乾淨檢查,也都 apply 成功。B 看到 `WBOX-ma-…` 和 `WBOX-mb-…` 疊在一起;B 結束時的 trap 把樹還原,A 跑到一半 patch 就沒了(A rc=1)。
- 影響:fail-closed。step 7 的見證集合會擋下(B 有兩個見證、A 沒有見證),但兩次完整 build 白費。18 個變體批次 build 時,很自然會想平行跑。`.config`、`files/etc/batman-build`、`build_dir` 早就是共用的(既有問題),`--wbox` 又多了一個共用資源。
- 修法:非 `--card-only` 路徑一開始就 `exec 9>logs/build-board.lock; flock -n 9 || { echo "another build-board is running" >&2; exit 1; }`。

### MINOR-3 gate 不看 `helpers.list` 第 3 欄:`same` 類的 release 變體帶非 Go 的 helper 會 PASS
- 證據(✅):`96-noprov release same` 搭配 `#!/bin/sh exit 1` 的 helper,結果 `check-prov-test-gate: ok (wbox 96-noprov, tag release, helper tags=[])` rc=0。
- 應該只有 `helper` 類(`helper-exit1`)可以是非 Go。`dv-prov-tools.sh` 的「same → sha = release」(§15.5)之後還會擋,但 gate 本身是 fail-open。
- 修法:`KIND=$(awk … print $3)`;`release` 且 `same` 時要求 `ISGO=1`,並跑 `noseam`;自測補這一案。

### MINOR-4 gate 會沿著 rootfs 裡的絕對 symlink 讀到 build 主機上的檔案
- 證據(✅):把 rootfs 的 `usr/bin/batman-provhelper` 換成指向主機 Go 工具的絕對 symlink,normal 模式結果是 `ok (no test seam; helper tags=[])` rc=0。`[ -f "$H" ]`、`go version -m`、`strings` 全部跟著 symlink 走。在節點上,這個 helper 是 dangling link。
- 觸發者只可能是我們自己的錯誤或惡意 patch(供應鏈),機率低。
- 修法:`[ -L "$H" ] && fail "helper is a symlink"`,`etc/batman-build` 同理。

### MINOR-5 §6.2 L7 列的文字還沒改
- 證據(✅):`design.md:362` 仍寫「全部:sysrq 行、key 登入」。§16.1 宣布這條作廢,但表格本身沒動。harness 是照 §6.2 的表實作的,很容易照抄出一條不可能成立的判定。
- 修法:把該格改成「全部:§16.1 (a)–(e)、key 登入」。

### MINOR-6 §16.1(c) 用「串流裡沒有 fallback 行」區分 sysrq 與 fallback,這是靠證據缺席
- 情境:fallback 路徑會先 `sync` 再 `reboot -f`,寫入變得持久,斷電語意因此不同。txn-3 等點可能照樣滿足 (b)(d)(e) 而判成 PASS,這時唯一的分辨依據是 `logread -f` 串流裡有沒有那一行。串流在 2 s 內斷掉(ssh 卡住、logd 忙)就漏掉,等於 fail-open。
- 程式碼:`seam_provtest.go` 的 reboot 函式寫 sysrq 失敗時不 log 錯誤,先睡 2 s。
- 修法(擇一):
  - (a)fallback 在 `sync` 前寫一個持久標記(p6 或 overlay 上的 `batman-killpoint-fallback`),harness 重開後看到就 FAIL;
  - (b)至少在 sysrq 寫入失敗的當下立刻 log 錯誤。
- 也可以接受現狀,但要寫明理由:E-H6 證明 04 的 sysrq 可用,F29 證明 mask 不影響寫入。

### MINOR-7 第 1 輪有兩項既沒修、也沒進 §16 的殘項
- A-m4:gate 的 init mutant 偵測仍寫死 `^+++ b/feed/batman-provision/files/etc/init.d/wbox-`(`check-prov-test-gate.sh:241`)。
- A-m8:release helper 仍含 `claim-after-persist` 字面值。arm64 `-s -w` 實測:release `cap=1`,`txn-3` 行 1,但 `killpoint=0`,所以不違反 gate。
- 修法:修掉,或寫進 §16「仍是殘項」。

### MINOR-8 `test-prov-test-gate.sh` 對前置條件與 h-mut 沒有自我檢查
- 問題:
  - `mv … seam_provtest.go`、`rm`、`sed` 失敗都不會停(沒有 `set -e`)。
  - Batman 原始碼沒有 seam 套件時,失敗訊息是 `h-mark mutant not applied`(MAJOR-1 實測)。
  - h-mut 沒有像 h-mark / h-kp 那樣做「mutant 已套用」的 grep。
- 修法:
  - 開頭加 `[ -f "$SRC/seam/seam_provtest.go" ] || { echo "BATMAN_SRC has no seam package (pin predates P1b)"; exit 1; }`;
  - h-mut 編完斷言 marker ≥ 1 且 armed = 0。
- shellcheck 只有 SC2046(`$(mk …)` 沒加引號;路徑是 mktemp 產生、沒有空白,無害)。gate、build-board、stamp 沒有 warning。

## 第 1 輪 findings 對照

| 第 1 輪 | 狀態 | 證據 |
|---|---|---|
| B-M1 樹不乾淨 → 疊加 / 刪修改 | ✅ 修好 | 假 feed:新版 SIGKILL 殘留 → 下一次拒絕;開發者修改 → 拒絕且 `wip.go` 還在。舊版(1fc28b95)負對照:疊加 `WBOX-ma`+`WBOX-mb`、`wip.go` NO-LOST |
| B-M2 / A-M1 sysrq 行到不了主機 | ✅ 設計改判定(§16.1);留 MINOR-5、6 | 程式碼不變(依設計) |
| A-M2 release 變體帶 prov_test helper | ✅ | `unset`(build-board:50);gate mutant `no-release-noseam` → 1 BAD |
| A-M3 點位沒測試 | ✅(缺 rc≠0 分支 → MINOR-1) | 12/13 mutant 紅 |
| B-m1 / A-m1 `read` 靜默退出 | ✅ | `nope is not in …helpers.list` rc=1 |
| B-m2 / A-m4 tag 驗證 | ✅ tag;init 路徑沒修(MINOR-7) | mutant `no-tag-validate` → 1 BAD |
| B-m3 env 繼承 | ✅(檢視程式碼,⚠️ 沒實跑整個 build) | build-board:50 |
| B-m4 讀不到的檔 | ✅ | mutant `no-grep-rc` → 1 BAD;真 rootfs 非 symlink 的讀不到檔 = 0 |
| B-m5 / A-m7 release 測試的宣稱 | ✅ 註解 | seam_release_test.go 檔頭 |
| B-m6 mode 特殊位元 | ✅ | mutant perm-only → file_setgid、dir_sticky 紅 |
| B-m7 txn-3 rc≠0 | 文件 ✅;測試 ❌(MINOR-1) | |
| A-m2 stamp in-progress | ✅(檢視) | build-board:183,197 |
| A-m3 card-only + wbox | ✅ | build-board:51 |
| A-m5 自測對原因 | ✅ | 23 案例都比對原因字串 |
| A-m6 CI 跑 gate | ✅ 已接上;❌ 沒在 GitHub 跑過 | `gh run list --branch feat/254-wbox` 空 |
| A-m8 release 點名字面值 | ❌ 沒修也沒記(MINOR-7) | cap=1 |
| A-m9 fstat | ✅ | mutant follow-symlink → file_symlink 紅 |
| A-m10 reboot 失敗 log | ✅ | `reboot did not happen` |
| A-m11 P1b CI 只跑 release tag | 殘項 ✅ 已記 | Batman CI c1901db `ci` success(只有 release tag) |

## 介面、生命週期、安全(從現場出發)

- **擁有權**
  - killpoint 檔:harness 寫,helper 讀完就刪,在可信目錄內不論結果都刪 → 符合 §3。
  - `feeds/batman`:設計說 build-board 是唯一寫者,但沒有鎖(MINOR-2)。
  - `logs/wbox-<board>.stamp`:只有 build-board 寫,每板一份。
- **契約**
  - `--version`:rc 0 加第 1 行;prov_test 版多第 2 行。舊版回 rc 2,preflight 用它區分(第 1 輪 A 已證)。stamp 不存在時印 `unknown` rc 0(測試覆蓋)。
  - killpoint 檔缺 → 什麼都不做,也不 log。不良 → `refused`,fail-closed。名字不在清單 → refused。
  - `helpers.list` 缺 → build / gate FAIL。tag 不對 → FAIL。第 3 欄沒用上(MINOR-3)。
- **生命週期**
  - 首次安裝:wbox 不能做卡(build-board:51)。只走 OTA 進 B,且 hold(harness 負責)。
  - 啟動:只在 daemon 啟動時 `Arm`;`--boot` / `--apply-state` 不 arm。
  - restart / crash loop:檔案第一次 `Arm` 就刪了,respawn 不會再 arm(程式碼:可信目錄內 `defer os.Remove`)。
  - 斷電 / sysrq:`/tmp` 是 tmpfs,arm 不會跨重開。
  - logd 重啟:`armed` 行掉了 → (a) 不成立 → FAIL(fail-closed)。
  - 升級 / 回退:回到 A(release)後 seam 就不在。
  - 降級到 pre-P1b:`--version` rc 2。
  - bcm2710:build-board 允許 `--wbox`,gate 相同。⚠️ 沒有實 build 驗證。
- **安全**
  - release 二進位沒有 `killpoint`、`batman-prov-test`、`sysrq-trigger`、marker,也沒有 prov_test tag。arm64 實測與真 payload 都是 0。
  - prov_test 版只有 root 能 arm(目錄 root 0700,且由 `/tmp/run` root 0755 保護)。⚠️ `/tmp/run` 的擁有者沿用設計 F 事實,這輪沒上機重驗。
  - 非 root 與 provd(471)進不去;root 本來就能重開,沒有提權。
  - symlink / hardlink / 特殊位元 / FIFO(`O_NONBLOCK`+fstat)都會 refused,且有測試與 mutant。
  - 供應鏈方面的 gate 缺口:MINOR-3、MINOR-4。見證藏在 `.gz` 內、symlink 目標或檔名裡,gate 也看不到(實測 ok)。現有 patch 慣例不會這樣放,記為資訊,不列 finding。

## 實跑紀錄

✅ Go(go1.26.4,副本)
```
vet tags=[] ok ; vet tags=[prov_test] ok
test tags=[]          12 packages ok ; test tags=[prov_test] 12 packages ok
-race seam/node/cmd  兩種 tag ok ; -shuffle=on -count=3 兩種 tag ok
TestKillpointTxnPositions / ClaimPositions / NotOnOtherPaths  PASS
SKIP(非 root)4 個 = 既有 root-only(TestAllowedPeer、TestWrongPeerClosed、TestOversizeAndMalformedClose、TestPrepareDirRefusals)
arm64 -trimpath -s -w:
 tags=[]          killpoint=0 armed=0 marker=0 cap=1 cbs=0 sysrq=0 kpdir=0 WBOX=0
 tags=[prov_test] killpoint=6 armed=1 marker=1 cap=1 cbs=1 sysrq=1 kpdir=1 WBOX=0 ; build -tags=prov_test
mutants(-tags prov_test):txn4-before-remove / drop-cbs / txn1-in-commit / cap-dropped / txn2-before-setkey / txn5-dropped /
 perm-only / no-nlink / unlink-untrusted / dir-perm / follow-symlink / keep-file → 全部 FAIL(紅);txn3-rc0-only → rc=0(MINOR-1)
```
✅ gate(feat/254-wbox 的腳本,副本)
```
bash -n ×4 ok ; shellcheck -S warning:只有 test 腳本的 SC2046
self-test src=HEAD(c1901db) → 23 ok, 0 bad ; src=01b12c9 → 23 ok, 0 bad ; src=7fd2124 → "h-mark mutant not applied"
gate mutants(每拿掉一條 → BAD 數):tags 2, marker 1, killpoint 1, grep-rc 1, exact-set 3, tag-validate 1, release-noseam 1,
 armed 1, BATMAN_WBOX 行 1, version 1, isgo-normal 1, normal-witness 1;no-initcheck / no-witness-format 的 sed 弄壞了 case/if
 語法(各 8 BAD)= 我的 mutant 無效,不算
真 payload(新 gate):
 1.5.14-wsl.5+01b12c9.fwd2a4bfd           helper sha 6097b7…, tags 無, killpoint 0 → normal ok ; test → FAIL BATMAN_WBOX=[]
 …fwd2a4bfd.dirty.wbox-test               helper sha 3f2c8f…, -tags=prov_test, killpoint 5 armed 1 marker 1
                                          → normal FAIL "carries BATMAN_WBOX=test" ; test ok
 (unsquashfs 以非 root 解 rc=2 = 屬主 / xattr;find ! -readable 命中的 5 個都是絕對 symlink,非 symlink 讀不到 = 0)
構造:96-noprov+shell helper → ok(MINOR-3);helper=絕對 symlink → ok(MINOR-4);見證只在 symlink/檔名/.gz → ok(資訊);
 見證夾在別的位元組中間 → FAIL(正確);GO=/nonexistent → FAIL(正確)
```
✅ build-board wbox 區塊(從 feat/254-wbox 與 1fc28b95 抽出,在假 `feeds/batman` git repo 上跑)
```
[new] SIGKILL 殘留 ma → 下一次 mb:refused( M n.go)      [old] → APPLIED,WBOX-ma + WBOX-mb 疊加
[new] 開發者修改 → refused,wip.go 還在                   [old] → APPLIED,wip.go NO-LOST,修改消失
[new] patch 套不上 → "does not apply",trap 還原,樹乾淨
[new] 只有 ignored 的 __pycache__/ → refused(fail-closed,訊息附清法)
[new] 兩個同時跑 → 兩邊都 applied,B 看到兩個見證,A 的 patch 被 B 的 trap 抹掉(MINOR-2)
```
❌ 沒做:firmware 實 build(依指示);firmware CI 沒在 GitHub 跑過(沒有 run 或 PR);以 root 跑 Go 測試(CI 的 sudo 路徑);bcm2710 的 wbox build;節點上的任何驗證(E-H2/E-H6、`/tmp/run` 擁有者)。

## Verdict

**APPROVE-WITH-CHANGES**:0 BLOCKER / 1 MAJOR / 8 MINOR。

- 程式碼本身可以進。
- 上節點之前必須先處理 MAJOR-1:重切 rc、新 pin、BUILD_N+1、重 build 並重跑 E-H2。
- MINOR-1(txn-3 rc≠0 測試)與 MINOR-5(§6.2 表格)建議這輪就修;其餘可以同 PR 修,或寫進 §16 殘項。
