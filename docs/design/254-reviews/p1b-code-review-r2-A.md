# PR-P1b + firmware --wbox 程式碼審查 第 2 輪 — 審查者 A

- Batman `feat/254-p1b-seams` @ c1901db(`origin/main...HEAD`,3 commits:c6601e7 / 19d9373 / c1901db;工作樹乾淨,遠端分支 = c1901db)
- firmware `feat/254-wbox` @ 55fe0459(`e7c2a222..55fe0459`,1fc28b95 + 55fe0459)
- 依據:`254-h23-harness.md` §4.1.1–§4.1.3、§4.2、§6.2 L7、§8 E-H2/E-H6、§15、§16;第 1 輪 A / B 報告。
- 方法:Batman 以 `git archive HEAD` 複製到 `/home/yello/.revr2A`(結束已刪);firmware 腳本以 `git show feat/254-wbox:` 取出;沒在 `/home/yello/firmware-2710` build、沒改它的 checkout;沒碰任何節點;沒 commit / push。Go = firmware staging `go1.26.4`。

## 摘要

第 1 輪的 3 個 MAJOR(A-M1/B-M2 的 sysrq 行、A-M2 的 gate 對 release 變體不檢查、A-M3 的點位置沒有測試)和 B-M1(feeds/batman 不乾淨)都已處理:
- 點位置測試有判別力:8 個搬點 / 拿掉點的 mutant 全部變紅。
- killpoint 檔讀法改成 fd 檢查,7 個 mutant 中 5 個變紅,存活的 2 個見 m1。
- gate 自測 23/23,核心檢查拿掉後自測會變 BAD。
- 真 payload 正反都對。
- 把 `build-board.sh` 的 wbox 區塊抽出來,對假的 feeds/batman 跑 9 個案例,全部符合 §16.7。

沒有 BLOCKER。有 1 個 MAJOR:B-M1 修正(拒絕不乾淨的 feeds/batman,保護開發者未 commit 的修改不被 `clean -fdx` 抹掉)沒有任何回歸測試。我手動證明了它現在是對的,但沒有東西會在它退化時變紅。另有 8 個 MINOR,其中 2 個是第 1 輪的 MINOR 既沒修也沒記錄(A-m4、A-m8)。

## 第 1 輪項目逐條核對

| 第 1 輪 | 狀態 | 證據 |
|---|---|---|
| A-M1 / B-M2 sysrq 行到不了主機 | ✅ 設計改判定(§16.1 a–e),產品不改;E-H6 擴充 | §16.1;`seam_provtest.go:10-12` 註解一致 |
| A-M2 release 變體帶 prov_test helper 假 PASS | ✅ 已修 | `build-board.sh:50` unset;gate `release) … noseam`;自測 w7b;拿掉 noseam 呼叫 → 自測 `22 ok, 1 bad` |
| A-M3 點位置無測試 | ✅ 已修 | `node/seam_points_test.go`;見下方 mutant 表 |
| B-M1 feeds/batman 不乾淨仍套 patch | ✅ 行為正確,❌ 沒有回歸測試 | 見 MAJOR-1 |
| A-m1 `read` 在 `set -e` 下靜默退出 | ✅ 改成 `$(awk …)` | `build-board.sh:120-121`;抽出測試「unknown name」rc=1,有訊息 |
| A-m2 被中斷的 build 留下錯的 stamp | ✅ 寫 `in-progress:` | `:183`、`:197` |
| A-m3 `--card-only --wbox` | ✅ exit 2 | `:51-53` |
| A-m4 init mutant 路徑寫死 `feed/batman-provision/` | ❌ 沒修,也沒記錄 | gate `:241`;見 m4 |
| A-m4b / B-m2 tag 打錯字 | ✅ 兩處都檢查 | `:122`;gate case;自測 wb |
| A-m5 自測只看 rc | ✅ 比對原因字串 | `want FAIL:<reason>` |
| A-m6 CI 沒跑 gate | ✅ 已接上(沒看到實際 CI 執行,❌) | `build-firmware.yml:227-230` |
| A-m7 / B-m5 release 測試只是文件性質 | ✅ 註解已寫明 | `seam_release_test.go:12-14` |
| A-m8 release 帶點名字面值 | ❌ 沒修,也沒記錄;§16.4 讓它變成必然 | 見 m4 |
| A-m9 / B-m6 TOCTOU、特殊位元 | ✅ O_NOFOLLOW + fstat + modeBits | mutant drop-nofollow / drop-special-bits 變紅 |
| A-m10 `select {}` 前無 log | ✅ `reboot did not happen` | `seam_provtest.go:61` |
| A-m11 P1b 的 CI 只跑 release tag | ✅ 記錄為殘項(§16 末) | — |
| B-m4 讀不到的檔 fail-open | ✅ grep rc 2 → FAIL,且在 gate 自己的 shell 內 | 自測 r6;拿掉 rc 檢查 → BAD |
| B-m7 usage / stamp / txn-3 文字 | ✅ | `:57`、§16.5、§16.7 |

## 發現

### MAJOR

**MAJOR-1 B-M1 的修正(以及 `build-board.sh` 其他 wbox 邏輯)沒有回歸測試,不符合「每個修正都要有回歸測試與負對照」**(✅ 行為我已實證;❌ repo 內無測試)

- 情境:日後有人整理 `build-board.sh:116-140`,把 `trap … EXIT`(:131)移到乾淨檢查(:125-130)之前,或把 `--ignored` 拿掉。結果就是 B-M1 情境 B 原樣重現:`--wbox X` 拒絕時,trap 照樣 `checkout -- . && clean -fdx`,開發者在 feeds/batman 未 commit 的修改和未追蹤檔一起消失,救不回來。目前沒有任何 CI 或 daily 測項會變紅。同樣沒有測試的還有:`unset BATMAN_*`、`--wbox` 不得與 `--card-only` / `--update-lock` 併用、tag 只能是 prov_test / release、`in-progress` stamp。gate 的 witness 檢查只擋得住「mutant 進了 image」,擋不住「修改被抹掉」。
- 證據:firmware `.github/workflows/*`、`scripts/test-*.sh` 沒有任何測項會執行 `build-board.sh` 的這段。§8 的 E-H2「Ctrl-C → 樹乾淨」是手動、一次性的。我把 `:116-140` 原文抽出,對假的 feeds/batman git repo 跑了 9 個案例(輸出節錄):
  ```
  -- clean feed, variant x (release): rc=0   INSIDE a=mut n=yes PT=unset   AFTER: a=orig status=[]
  -- clean feed, test: rc=0                  INSIDE a=orig n=no PT=1       AFTER: a=orig status=[]
  -- developer edit (tracked) -> refuse, edit kept: rc=1 ...  AFTER: a=mine status=[ M feed/.../a ]
  -- untracked file -> refuse, kept: rc=1 ...                 AFTER: status=[?? feed/.../u ]
  -- ignored file -> refuse, kept: rc=1 ...                   AFTER: status=[!! z.pyc ]
  -- leftover mutant (SIGKILL) -> refuse: rc=1 ...            AFTER: a=mut status=[ M .../a ?? .../n ]
  -- unknown name: rc=1  nope is not in feeds/batman/tests/wbox/helpers.list
  -- tag typo: rc=1      ...: tag 'prov-test' for y (want prov_test or release)
  -- bad name: rc=1      bad --wbox name 'A/../b'
  ```
  所以現在的程式是對的;缺的只是讓它一直保持對的那個測試。
- 修法:把 wbox 區塊抽成一個函式(或維持行號範圍,但用標記行 `# >>> wbox` / `# <<< wbox` 夾住,讓測試照標記抽取),新增 `scripts/test-build-board-wbox.sh`,內容就是上面 9 個案例,外加:
  - 「`--wbox x --card-only` → rc 2」;
  - 「呼叫端已 `export BATMAN_PROV_TEST=1`,跑正常 build → 抽出的 env 為 unset」。

  接進 `build-pr-bcm271{0,1}.yml` 的 paths(`scripts/build-board.sh`)與 build-firmware 同一步驟。負對照:把 trap 移到檢查之前 → 「developer edit」案例變成 `a=orig`,判 BAD。

### MINOR

**m1 `TestRefusals` 的原因比對有一部分是空的:路徑本身就含測試名稱**(✅ 實證)
- `t.TempDir()` 的路徑包含子測試名稱(例如 `…/TestRefusalsfile_symlink…/kp/killpoint`),所以 `r.has("symlink")` 必然成立,跟實際的拒絕原因無關。
  - 實測 file-symlink 的拒絕訊息是 `open …/killpoint: too many levels of symbolic links`,不含 "symlink"。
  - mutant 把 `" is a symlink"` 改成 `" is a s-link"` 後,`go test -tags prov_test ./seam` 仍是 `ok`。
- 目前這兩案仍有判別力,是靠另一條斷言 `armed != ""`(mutant drop-nofollow 有變紅)。但「原因字串對得上」這個宣稱不成立。
- `io.LimitReader(fd, 64)` 拿掉後也全綠,因為沒有超長內容的案例。
- 修法:比對前先把路徑換成固定字串,例如 `strings.ReplaceAll(line, filepath.Dir(Dir), "<T>")`;或讓 `check()` 回傳固定的原因代碼,測試比對整行。file-symlink 的 why 改成 `"symbolic links"`(ELOOP)。另加一個超過 64 B 的檔案案例:`"txn-1" + 100×' '` → 預期 armed,證明只讀 64 B 後 TrimSpace;或 `"txn-1"` 加 64 B 垃圾 → 預期 refused。

**m2 gate 自測沒有覆蓋 gate 的全部檢查:5 條拿掉後自測仍 23/23**(✅ 實證)
- 自測仍 23 ok、0 bad 的 gate mutant:
  - `normal-version`(正常模式 `case "$VER" in *wbox*`);
  - `wb-name`(`[ "$WB" = "$NAME" ]`);
  - `pt-marker`(prov_test 變體的 marker ≥ 1);
  - `witness-format`(`WBOX-<name>-<8 hex>` 格式);
  - `elf-nogo`(ELF 但 `go version -m` 讀不到)。
- 另外 `pt-isgo` 的情況已被 tags 檢查順帶擋住,屬於冗餘。
- §16.9「逐條拿掉 gate 的 5 個檢查 → 自測各自 BAD」說的是對的,但只限那 5 條,文件容易被讀成「gate 全覆蓋」。
- `elf-nogo` 有實際意義:release 變體的 ELF helper 在 `GO` 讀不到 buildinfo 時,如果沒有這條,`ISGO=0` 會直接跳過 noseam。我實測 `GO=/bin/false` 時 gate 回 rc=1,這條現在有效,只是沒有測試保護。
- 修法:補 5 個案例:
  - 正常模式 VER 含 wbox 但沒有 BATMAN_WBOX 行;
  - wbox 模式 `BATMAN_WBOX=other`;
  - prov_test 變體的 helper 沒有 marker(用 msrc 同法拿掉 Marker);
  - 見證寫成 `WBOX-x-xyz`;
  - `GO=/bin/false` 加 release 變體的 ELF helper → FAIL `cannot read its build info`。

  §16.9 改寫成列出全部檢查,並寫明哪些是冗餘。

**m3 firmware CI 的 gate 自測把 firmware 綁在 Batman ≥ P1b 上;pin 指向舊 Batman 時 CI 變紅,而且訊息會誤導**(✅ 實證)
- 實測:`BATMAN_SRC=<Batman 7fd2124 = e7c2a222 的 pin>` 跑自測 → `h-mark mutant not applied`,rc=1(前面還有 `stub.go: No such file`、`sed: can't read …seam_release.go`)。
- 影響的生命週期路徑:
  - 合併順序:firmware PR 必須帶「pin 到已含 P1b 的 Batman」才會綠,所以 Batman P1b 要先進 main。§8 步驟 5 的方向一致,但沒寫成硬約束。
  - 降級 / 回滾:日後要把 pin 退回 P1b 之前的 Batman(重 build 舊版、`DV_OLD_PAYLOAD` 類需求),CI 會永久紅。
- 這是 fail-closed,方向對;問題在訊息。
- 修法:
  - 自測開頭加 `[ -f "$SRC/seam/seam_release.go" ] || { echo "pinned Batman has no seam package (pre-P1b): firmware #254 gate needs Batman >= <P1b merge commit>"; exit 1; }`;
  - firmware PR body 寫明「先 merge Batman P1b,再 merge firmware(含 pin)」;
  - 降級的後果記進 #254。

**m4 第 1 輪的兩個 MINOR 沒修,也不在 §16 殘項**(✅ 實證)
- A-m8:release helper 仍含點名字面值。§16.4 改成 `commitTxn(&next, "", "claim-after-persist")` 後,字面值必然留在 release:
  ```
  arm64 release (c1901db): killpoint=0 armed=0 marker=0 cap=1 txn3=1 cbs=0 kpdir=0 sysrq=0
  real 1.5.14-wsl.5 normal payload helper:  killpoint=0 marker=0 cap=1
  ```
  - 不違反 §15.4,因為 gate 只禁 `killpoint` / marker,而且 release 的 `At` 是 no-op。
  - 但 §4.1.2「標記字串只在 tag build」的精神是 release 不帶測試痕跡。
  - 二擇一:(a) 接受,在 §16 寫一句「點名字面值會留在 release(無作用;gate 不禁)」;(b) 讓點名只在 prov_test 檔內定義,例如 `seam.PointClaimAfterPersist` 在 release 檔為 `""`,在 prov_test 檔為字面值。
- A-m4:gate 的 init mutant 偵測只認 `^+++ b/feed/batman-provision/files/etc/init.d/wbox-`。
  - 把模式改成別的套件後,自測 `wbox chan, not enabled` 就變 BAD(mutant init-detect-any-pkg 實測)。這表示自測確實釘住了現行路徑,但等於把「init mutant 只能放在 batman-provision」變成沒寫出來的契約。
  - 同類的還有 `build-board.sh:182` 只 clean `batman-prov batman-provision`。
  - 修法:改成 `^+++ b/feed/[^/]*/files/etc/init.d/wbox-`,並讓 `lint-wbox` 斷言 patch 只碰這兩個套件;或把這條契約寫進 §4.2。

**m5 L7 判定(§16.1)可以多一條便宜又有判別力的證據:新 boot 的 boot-reason**(⚠️ 推論)
- 現在的 (a)–(e) 沒有任何一條能在重開後說明「是 sysrq 造成的重開」。(d) boot_id 改變,在 watchdog、斷電、panic 時也一樣成立。
- `95-batman-storage:640-683` 會把上一次 boot 的 console-ramoops 記錄存起來;看到 `sysrq: ` 就在 reason 加 `hints: sysrq`;沒有 shutdown marker 時給 `UNCLEAN — … sysrq …`。
- 修法:§16.1 加 (f)「新 boot 的 boot-reasons 為 UNCLEAN,且 hints 含 `sysrq`,不含 `panic` / `watchdog`」。若 04 的 console capture 沒開,(f) 改成「只記錄」。
- 進一步(可選):fire 前把 `killpoint <name>: sysrq reboot` 也寫進 `/dev/kmsg`,同一個 console 記錄就會帶著點名過重開。這只多一次 syscall,不影響「無 sync」語意。
- ⚠️ 04 上 console-ramoops 有沒有開,依指示沒上機查;放進 E-H6 一起看(`echo b` 之後的 boot-reasons 行)。

**m6 `main.go` 的接線沒有 Go 測試;其中一條由 gate 間接擋住**(✅ 實證)
- mutant `drop-daemon-arm`(拿掉 `daemon()` 的 `seam.Arm(logf)`)與 `drop-boot-marker`(拿掉 `--boot` 的 marker log),兩種 tag 的 Go 測試都綠。
- `drop-daemon-arm` 的 arm64 prov_test build:`armed=0 marker=1`。`Arm` 沒人呼叫就被 linker 丟掉,所以 gate 的 `killpoint .*: armed` 會 FAIL。✅ 有擋,只是要到 build 才知道。
- `drop-boot-marker` 只能靠未來的 tier A `prov-boot`(§6.2)。
- 修法(便宜):註明 gate 的 armed 檢查同時擔任「Arm 有被呼叫」的守門;`--boot` marker 留給 tier A,並在 §6.2 寫明它是唯一的判定。

**m7 現存的 rc 與 payload 不是本輪審查的程式**(✅ 實證)
- firmware `rc/254-p1b` 的 batman pin 是 `01b12c9`;payload 的 `BATMAN_VERSION=…+01b12c9…`。
- `git diff --stat 01b12c9 HEAD -- feed/batman-prov` = 7 files, +277/−23,沒有 hook_provtest、fd 檢查、位置測試。
- 所以 `~/out/1.5.14-wsl.5+01b12c9*` 拿來當 E-H2 或 L7 證據,驗的是第 1 輪版本。另外 `rc/254-p1b` 上的 CI 自測跑的是 01b12c9 的原始碼。
- 修法:rc 改 pin 到 c1901db(或 merge 後的 main)再重 build 18 個變體,E-H2 重做;PR body 的測試結果只引用新 pin 的產物。

**m8 設計文字殘留舊名稱**:
- §2.1 表與 §4.1.1 末還寫 `killpoint_provtest.go` / `armKillpoint()`;
- §4.1.3 寫「`test` 的見證 = helper 標記」,但實作(與 §16.8)是 `test` = 空集合。

§16 寫了「與前文衝突時以本節為準」,但 §2.1 / §4.1.1 / §4.1.3 是實作者最先讀的地方。建議在那三處就地改,或加「→ §16」指標。

## 介面與生命週期(本輪增量的檢查)

- **擁有權**:
  - feeds/batman 工作樹:套 patch 與還原只由 `--wbox` 做;開發者修改與殘留 mutant 一律拒絕,不再有兩個寫者(✅ 抽出測試)。
  - `logs/wbox-<board>.stamp` 只有 build-board 寫(:183 / :197)。
  - killpoint 檔:harness 寫、helper 讀完刪(只在可信目錄內)。
- **契約**:
  - `--version`:rc 0;line1 = `batman-provhelper <VER|unknown>`;prov_test 多 line2 marker(TestVersion 兩 tag 都過)。
  - gate 輸入讀不到一律 FAIL:rootfs 缺、helper 缺、ELF 讀不到 buildinfo、grep rc 2(自測 + `GO=/bin/false` 實測)。
- **生命週期**:
  - first run / start:release 的 seam 是 no-op。arm64 release `killpoint=0 marker=0 kpdir=0 sysrq=0`;真 payload 同樣 0。
  - 只有 `daemon()` 會 `Arm`(source:`main.go` `daemon` 內)。
  - restart / crash loop:檔讀完即刪;respawn 後的 daemon 不會再 arm,判定 (b) 會 FAIL,屬 fail-closed;重開清掉 `/tmp`,沒有 reboot 迴圈。
  - upgrade / downgrade:helper 降級到舊版時 `--version` 回 rc 2,preflight 據此辨識;firmware pin 降級見 m3。
  - 平台:兩板用同一個 gate;bcm2710 沒有實跑(❌)。
- **安全**:
  - 沒有新的特權面。helper 的 init 沒有 jail 或 capability 限制(`feed/batman-prov/` grep `jail|seccomp|capab` 無命中),root 寫 sysrq 可行(⚠️ 只由原始碼推得,E-H6 會實證)。
  - 非 root 進不了 `/tmp/run/batman-prov-test`:靠 `/tmp/run` 是 root 0755(設計 F 項;本輪沒上機,⚠️)。
  - 攻擊型負測試都在 Go 單元裡跑,以測試者自己的 uid 當 wantUID;以 root 跑在 CI 是記錄過的殘項。

## 實際執行(✅,原始輸出節錄)

```
# Go 1.26.4,git archive c1901db
vet tags=[] ok ; vet tags=[prov_test] ok
test tags=[]          12 × ok, SKIP=4(既有 root-only:TestAllowedPeer/TestWrongPeerClosed/TestOversizeAndMalformedClose/TestPrepareDirRefusals)
test tags=[prov_test] 12 × ok, SKIP=4(同上)
-race -shuffle=on -count=3 -tags prov_test ./seam ./node ./cmd/... → ok ×3

# 位置 / 讀檔 mutant(-tags prov_test)
txn4-before-RemoveTxn        FAIL TestKillpointTxnPositions
claim-after-persist-dropped  FAIL TestKillpointClaimPositions
txn1-in-commit               FAIL TestKillpointsNotOnOtherPaths
claim-before-shadow-after-lock FAIL TestKillpointClaimPositions
txn3-after-overlay           FAIL TestKillpointTxnPositions + ClaimPositions
txn2-before-setkey           FAIL TestKillpointTxnPositions
txn5-before-save             FAIL TestKillpointTxnPositions
txn1-before-WriteTxn         FAIL TestKillpointTxnPositions
drop-nlink                   FAIL TestRefusals/second_hardlink
drop-nofollow                FAIL TestRefusals/file_symlink
drop-dir-check               FAIL dir_0777 / dir_sticky / dir_is_a_symlink / TestUnlinkOnlyInTrustedDir
drop-special-bits            FAIL file_setgid / dir_sticky
no-delete                    FAIL TestArmedLineIsTheGateLiteral / TestUnlinkOnlyInTrustedDir
unlink-untrusted             FAIL TestUnlinkOnlyInTrustedDir
symlink-msg-renamed          ok   ← m1
no-64-limit                  ok   ← m1
arm-in-boot / drop-daemon-arm / drop-boot-marker  ok ← m6(drop-daemon-arm 的 arm64 build armed=0 → gate 擋)

# arm64 -trimpath -s -w CGO=0
release   killpoint=0 armed=0 marker=0 cap=1 cbs=0 txn3=1 sysrq=0 kpdir=0 ; 無 -tags 行
prov_test killpoint=6 armed=1 marker=1 cap=1 cbs=1 txn3=1 sysrq=1 kpdir=1 ; build -tags=prov_test

# gate 自測(feat/254-wbox 的腳本,BATMAN_SRC=c1901db)
RESULT gate self-test: 23 ok, 0 bad
gate mutant → 自測 BAD:noseam-tags(2) noseam-marker noseam-killpoint normal-wboxline normal-isgo normal-witness
  scan-rc wb-version pt-tags pt-armed rel-noseam rcd exact-set(3) init-detect-any-pkg
gate mutant → 自測仍 23/23:normal-version wb-name pt-marker witness-format elf-nogo  ← m2
自測對 Batman 7fd2124(pre-P1b)→ "h-mark mutant not applied" rc=1  ← m3

# 真 payload(在 55fe0459 之前 build;feed 01b12c9)
normal 1.5.14-wsl.5+01b12c9.fwd2a4bfd (CGO=1, 無 -tags), normal 模式 → ok (no test seam; helper tags=[])
wbox-test …dirty.wbox-test (BATMAN_WBOX=test, -tags=prov_test), test 模式 → ok (wbox test, tag prov_test, helper tags=[prov_test])
wbox-test, normal 模式 → FAIL: /etc/batman-build carries BATMAN_WBOX=test in a normal build
normal, test 模式     → FAIL: /etc/batman-build BATMAN_WBOX=[], want test
normal rootfs + CGO=0 prov_test helper → FAIL: normal build: helper built with -tags prov_test
normal rootfs + 真 wbox helper         → FAIL: normal build: helper built with -tags prov_test
real helpers: normal killpoint=0 marker=0 cap=1 ; wbox killpoint=5 armed=1 marker=1

# witness 相鄰:Go 字面值在 rodata 中與其他字串無分隔相連 → grep -o 仍正好取出 WBOX-helper-flap-1a2b3c4d
```

一開始的失敗歸因:第一次跑 gate 自測時 `cd …/feed/batman-prov/src: No such file`。原因是我把工作目錄放在 WSL 的 `/tmp`,兩次 `wsl` 呼叫之間 `/tmp` 被清空。之後改放 `/home/yello/.revr2A` 重跑,結果就是上面那份。這是審查環境的問題,不是產品問題;翻轉證據:只換工作目錄位置,同一份自測就從 build failed 變成 23 ok。

## 分類

- ✅ 已實證:上面所有輸出;wbox 區塊 9 個案例;第 1 輪項目狀態表。
- ⚠️ 推論:helper 以 root 寫 sysrq 可行(原始碼無 jail);`/tmp/run` 在節點上是 root 0755;04 的 console-ramoops 有沒有開(m5)。
- ❌ 沒做:firmware CI 實際執行(本機沒有 gh、firmware 沒有 remote,看不到 run);bcm2710 的 gate 實跑;Go 單元以 root 跑;任何節點上的動作(依指示)。

## 結論

**APPROVE-WITH-CHANGES**:0 BLOCKER / 1 MAJOR / 8 MINOR。

- MAJOR-1:把 wbox 區塊的 9 個案例做成 `scripts/test-build-board-wbox.sh`,接進 firmware CI,並附負對照(trap 移到檢查之前 → BAD)。我上面的抽出法可以直接拿來用。
- 同一輪建議修:m1、m2、m3(訊息與合併順序)、m4(修或記錄)。
- m5 併入 E-H6;m7 在 E-H2 之前完成(改 pin 並重 build);m8 改文字。
