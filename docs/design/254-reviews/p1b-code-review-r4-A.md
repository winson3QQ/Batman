# PR-P1b + firmware --wbox 程式碼審查 第 4 輪 — 審查者 A

範圍:審整個變更,不只第 3 輪的修正。
- Batman `feat/254-p1b-seams` @ 2563b1b(`feed/batman-prov` 14 檔 +880/−5)
- firmware `feat/254-wbox` @ f0f7d681(對 e7c2a222:9 檔 +492/−3)
- 設計 `254-h23-harness.md` @ e2e013a(§2.1、§2.2、§4.1.x、§4.2、§6.2 L7、§8、§15、§16 全部)
- 前 3 輪報告(r1 / r2 / r3 的 A / B)
- wsl.6 的 payload
- E-H6 證據檔

所有測試都在 `/home/yello/rv4a.POKk` 下的拷貝跑:Batman 用 `git archive` 取整個 repo,firmware 取 `scripts/` 與 `.github/`。我沒有改任何 worktree,沒有 build,沒有碰節點,也沒有以 root 跑 Go 測試。

## 結論

**APPROVE-WITH-CHANGES:0 BLOCKER / 0 MAJOR / 4 MINOR,另有 1 個 ❓ 觀察。**

- 第 1–3 輪的 finding 都已修好(各有負對照,見下表),或已記成殘項。
- 這輪沒有發現會讓 seam 進到出貨 image、或讓單元測試真的重開機的路徑。
- 4 個 MINOR 都是「我們自己的錯」這一類:patch 範圍檢查的旁路、SafeForTests 要每個套件自己加、設計文件的行號過時、鎖檔的擁有者。
- 重切 rc 的計畫是對的,也是必要的,理由見 §「rc 重切」。

## 實跑證據(✅,原始輸出節錄)

```
# Go 1.26.4,git archive 2563b1b(整個 repo),非 root
go test ./...                 → 12 package 全 ok
go test -tags prov_test ./... → 12 package 全 ok(node 9.15s, seam 0.039s)
-race(seam/node/cmd)兩種 tag   → ok
go vet 兩種 tag                → vet-ok
--- SKIP = 4:全部是 sock_test.go:15 "needs root (chown of the socket dir)"
  (非 root 才有,既有測試;§2.2 的 CI 以 root 跑,所以是 0)

# arm64 -trimpath -s -w CGO=0
447c0b79…  h-014778c-rel
447c0b79…  h-2563b1b-rel          ← release helper 位元組相同
03ea4fc0…  h-014778c-prov_test
750d4445…  h-2563b1b-prov_test    ← 只差 Go build ID(cmp 77 bytes;未 strip 的 nm 只差 build-id 項;strings diff 只有 buildid)
h-2563b1b-rel:      killpoint=0 marker=0 armed=0 claim-*=0 txn-3=0 /dev/kmsg=0 sysrq-trigger=0 batman-prov-test=0 SafeForTests=0 ArmForTest=0
h-2563b1b-prov_test: killpoint=7 marker=1 armed=1 … nonexistent/batman-seam-test=0 SafeForTests=0 ArmForTest=0(hook 在 linker 被丟掉)

# Makefile else 分支:golang-package.mk:260  $(if $(strip $(GO_PKG_TAGS)),-tags "$(GO_PKG_TAGS)")
#   → 空字串與沒設定產生相同的命令列

# 真 payload(wsl.6,Batman f6ac1f7 = 014778c)經 f0f7d681 的 gate
normal:   check-prov-test-gate: ok (no test seam; helper tags=[])   [go1.26.4, CGO_ENABLED=1]
wbox-test + test: ok (wbox test, tag prov_test, helper, helper tags=[prov_test])
wbox-test 當 normal: FAIL: /etc/batman-build carries BATMAN_WBOX=test in a normal build

# firmware 自測(f0f7d681)
RESULT gate self-test: 46 ok, 0 bad
RESULT build-board wbox test: 53 ok, 0 bad
舊 pin(Batman origin/main)當 BATMAN_SRC → "predates the #254 P1b seams … pin a Batman that has them",rc=1

# 突變(拷貝內)
Go  at-ignores-arm        → node: FAIL TestClaimLockFailure 0.07s「panic: seam: killpoint claim-after-persist fired in a unit test that did not arm it」(r3 是卡 25s 逾時)
Go  SafeForTests 不換 reboot → FAIL TestSafeForTestsNeverReboots (2.00s)
Go  Arm 取第一個欄位       → FAIL TestKillpointFileOneNameOnly
lib 拿掉 patch 範圍檢查     → 51 ok, 2 bad
lib wbox_normal_check 永遠 0 → 50 ok, 3 bad
lib env 只 unset BATMAN_*   → 52 ok, 1 bad
lib normal check 不看 untracked/ignored → 51 ok, 2 bad
lib trap clean -qfdx→-qfd   → 52 ok, 1 bad(r3 A-m1 已守住)
build-board stamp_done 移到 make 前 → BAD「build-board.sh order — … at line [167], not after make」
gate 拿掉 batman-build symlink 檢查 → 45 ok, 1 bad(r3 A-m3 已守住)
```

## 前 3 輪 finding 逐條核對

| finding | 狀態 | 證據 |
|---|---|---|
| r3 B-M1 單元測試會真的 sysrq / reboot | ✅ 已修(範圍見 m2) | at-ignores-arm 在 0.07 s 內清楚 FAIL;拿掉 SafeForTests 的 reboot 替換 → FAIL |
| r3 B-m1 env 的 GO_PKG_TAGS / GOFLAGS | ✅ | Makefile `else GO_PKG_TAGS:=` + golang-package.mk:260;envpartial 突變 → BAD |
| r3 B-m2 步驟順序 | ✅ | 順序突變 → BAD |
| r3 B-m3 一行一個點名 | ✅ | first-field 突變 → FAIL |
| r3 B-m4 SIGKILL 後的殘留 mutant | ✅ | nonormal 突變 3 BAD;註解已改 |
| r3 B-m5 / A-m4 kmsg 進 ramoops | ✅ | E-H6:`console-ramoops-0:307 e-h6: probe-… kmsg`、`:308 sysrq: Resetting`、boot-reasons `prev=UNCLEAN … hints: sysrq` |
| r3 B-m6 fast-build、B-m7 bcm2710、B-m8 帶 patch 的真 Ctrl-C | 殘項已記(§16 殘項) | — |
| r3 A-m1 `-x` | ✅ | no-x 突變 → BAD |
| r3 A-m2 §4.1.3「test 見證 = 標記」 | ✅ | §16.26 |
| r3 A-m3 batman-build 是 symlink | ✅ | 自測 rt;突變 → BAD |
| r3 A-m5 patch 範圍 | ✅ 部分 | 一般的 hunk / 刪除 / 往外 rename 都擋;**往內 rename 沒擋**(m1) |
| r3 A-m6 local-ab-tar 不經過 gate | 殘項已記 | — |
| r1 / r2 全部 | ✅ | r3 A / B 已核對;本輪再跑 arm64 strings、gate 46、lib 53,沒有退步 |

## 發現

### BLOCKER
無。

### MAJOR
無。

### MINOR

**m1 patch 範圍檢查可以用「往內 rename」繞過,繞過時會刪掉別的套件或 `tests/wbox/` 的檔案**(✅ 實證)

- 情境:有人寫 wbox patch 時打錯,或是 pin 進來一個惡意 patch,內容是 `rename from feed/other/y` / `rename to feed/batman-prov/…`。
  - `git apply --numstat` 對 rename 只列出**目的路徑**,所以 `lib-wbox.sh` 的 `while read -r _ _ p` 只檢查到 `feed/batman-prov/…`,判定通過。
  - 套用後,`feed/other/y` 就從 feed 消失了。
  - 被刪的是第三個套件的檔:`wbclean` 不會清它,gate 也看不到,image 可能帶著舊檔或少一個檔。
  - 被刪的是 `tests/wbox/helpers.list`:要等整個 build 跑完,gate 才報「no helpers.list」(fail-closed,但白跑一次 build)。
- 證據(真 lib,假 feed):
  ```
  0	0	feed/batman-prov/WBOX-ren-0c0c0c0c
  wbox variant ren (tag release): applied; … is restored on exit
  ls: cannot access '…/feed/other': No such file or directory
  ```
  對照組:往外 rename(`feed/batman-prov/x → feed/other/…`)與一般刪除(`0 1 feed/other/y`)都正確拒絕。
- 修法:改用 `git apply --numstat -z`(rename 時會給來源與目的兩個路徑),兩邊都要落在兩個套件內;或直接拒絕 `git apply --summary` 裡出現 `rename` / `copy` 的 patch(mutant 不需要 rename)。`test-build-board-wbox.sh` 補「往內 rename」案例;改之前它要 BAD。

**m2 `SafeForTests` 要每個 prov_test 測試套件自己加 TestMain;漏加的套件仍會走到真的 `fire`**(✅ 實證;目前沒有被觸發的路徑)

- 現況(✅):`grep` 確認只有 `node/` 與 `seam/` 的測試會走到 `seam.At` / `ArmForTest`,這兩個都有 TestMain。`cmd/batman-provhelper` 的測試(main_test、version_test)不呼叫 `daemon()`。所以目前沒有缺口。
- 情境:P2 會加 provd 的測試接縫,也可能有人在 cmd 加 daemon 測試。新套件若忘了 TestMain,遇到回歸或做突變負對照時,root 下就會寫 sysrq `b`(CI runner 或使用者的 WSL VM 硬重開,沒有 sync)。這正是 r3 B-M1 的情境,只是換了一個套件。
- 證據:拷貝內刪掉 `node/main_provtest_test.go`,再加 at-ignores-arm 突變,非 root、PATH 前放假的 `reboot`:
  ```
  panic: test timed out after 30s
  FAIL	batman-prov/node	30.038s
  FAKE reboot -f        ← 假 reboot 被執行(sysrq / kmsg 因非 root 拿到 EACCES)
  ```
- 修法(擇一):
  - (a) 讓保護不依賴每個套件的 TestMain:prov_test 的 `fire` 開頭判斷自己是不是測試二進位(例如 `strings.HasSuffix(os.Args[0], ".test")`,或檢查 `flag.Lookup("test.v") != nil`),是就 panic。只增加 prov_test 二進位的字串,release 不受影響,但 gate 的 strings 計數要重驗。
  - (b) 在 §16 寫明規則「任何 import `node` 或 `seam` 的 prov_test 測試套件都要有 TestMain 呼叫 `SafeForTests`」,並由 `seam` 的一個測試(或 CI lint)掃 `*_test.go` 來檢查。
  - 負對照:新增一個不含 TestMain 的套件,配上 at-ignores-arm 突變,結果要立即 FAIL,不能走到 `reboot`。

**m3 設計 §6.2 L7 列(harness 作者的依據)引用的行號已經過時**(✅)

- `main.go:491`(`not committed: restored`)現在是 **:504**。
- `main.go:492-494`(`RemoveTxn`)現在是 **:506**。
- `node.go:1118-1120`(txn-4 位置)現在是 **:1122-1125**。
- 原因:P1b 在 main.go 加了 `--version` / `seam`,在 node.go 加了 `seam.At`,行號都往後推。harness 的 L7 判定要靠這些行找 log 字串,行號不對會讓審查者核錯。
- 另有兩處是被 §16 取代的舊文字,依「§16 為準」規則不算錯,但會誤導:§2.1 表的 Makefile 寫 `ifeq … endif`,沒有 else(§16.21);§4.1.3 寫 `grep -rl 'WBOX-'`(實作是 `WBOX-[a-z0-9-]+-[0-9a-f]{8}`,§16.8)。
- 修法:行號改成引用 log 字串或函式名;兩處舊文字就地改掉。

**m4 若 `--card-only`(root)先在乾淨的 `logs/` 跑過,`logs/.build-board.lock` 會變成 root 擁有,之後擁有者的 build 一律 exit 2**(⚠️ 推論,未以 root 實測)

- `bb_lock` 在 `--card-only` 的「no $STAMP」檢查**之前**就做 `exec 9>>`,所以 root 會建出 root:0644 的鎖檔。擁有者之後 `exec 9>>` 會 EACCES,印出「cannot open the build lock」並 exit 2。
- 後果是 fail-closed,訊息也清楚,擁有者可以刪掉(logs/ 是他的)。只有「沒 build 就先 card-only」這種誤操作才會遇到。
- 修法:root 時用 `exec 9<` 開(flock 用唯讀 fd 也可以),或建檔後 `chown --reference=. `;或者只在 §16 記一行。

### ❓ 觀察(不是程式碼的 finding,請作者說明)

- E-H6 的 `before.txt` 是 `uptime=38122.81 version=1.5.14-wsl.4… active=A trial=1`,`after.txt` 是 `uptime=50.04 … active=A trial=1`。
- 如果 `trial=1` 的意思是「A 槽仍在 trial、還沒 commit」,那 04 在 A 上以 trial 狀態跑了約 10.6 小時。這會影響 harness 的前置條件(P9 的「committed 槽」判定),也影響「04 回 A wsl.4」這個說法。
- 我沒有碰節點,無法判斷這個欄位的語意。標 ❓,請作者用 `batman-slot is-trial` 的輸出說明。

## rc 重切(第 4 點)

- **第 3 輪沒有改到 release helper**(✅):arm64 CGO=0 下 014778c 與 2563b1b 的 release helper sha 相同(447c0b79…);Makefile 的 else 分支經 golang-package.mk:260 產生相同的命令列。
  - ⚠️ OpenWrt 用 CGO=1 的 toolchain 沒有重跑。
- **prov_test helper 的程式碼相同,但 sha 不同**(✅):只差 Go build ID(`hook_provtest.go` 的內容進了 build ID 的雜湊);SafeForTests / ArmForTest 被 linker 丟掉,strings 內沒有它們。所以 wsl.6 的 wbox-test helper sha **不會**等於重 build 後的 sha。
- 所以重切是必要的,原因有四:
  1. §16.18 要求 rc pin 必須含審過的 commit;
  2. helper 的 sha 會變(P9 / `dv-prov-tools.sh` 要比 sha);
  3. firmware 腳本已從 739c1636 / c62468e6 改成 f0f7d681,gate 的輸出要用新腳本重抓;
  4. `fwdb6693d` 那組 wsl.6 payload 也在 `~/out`,舊目錄容易拿錯。
- 計畫要成立的條件:
  - Batman `rc/254-p1b` 重切成 2563b1b + harness(e2e013a 或之後);
  - firmware rc = f0f7d681 + pin + `BATMAN_BUILD_N=7`;
  - 兩個 payload 用新 gate 各跑一次,附 step 7 的輸出;
  - E-H2 重記 helper sha;
  - 兩組舊的 wsl.6 payload 不上節點,最好改名或另外標明。

## 介面 / 生命週期 / 安全(整體)

**擁有權**
- `feeds/batman` 工作樹:build 期間只有一個寫者(`bb_lock` flock)。✅ 自測「second build refused」。
- killpoint 檔:harness 寫,helper 的 daemon 啟動時讀一次並刪掉。
- `logs/wbox-<board>.stamp`:每板一個,只由 build-board 寫。
- 沒有發現兩個寫者共用一個資源。

**契約**
- `--version`:release 會印一行,prov_test 印兩行,rc 0;舊 helper 回 usage rc 2。✅ TestVersion / TestVersionNoStamp。
- killpoint 檔格式不符 → refused(fail-closed)。✅ TestRefusals、OneNameOnly。
- gate 讀不到或缺項 → FAIL。✅ 自測 46。
- helpers.list 缺少 → `--wbox` 拒絕;它在 harness PR 裡(§8 第 5 步:harness 先 merge),與 §16.17 的合併順序一致。

**生命週期**

| 路徑 | 結果 | 依據 |
|---|---|---|
| 首次 build(沒有 stamp) | `unknown → clean` | ✅ 自測 |
| 正常 → wbox → 正常 | 每次切換都清;in-progress 中斷後會再清 | ✅ 自測 |
| Ctrl-C / TERM / HUP | 還原 | ✅ 自測 |
| SIGKILL | 下次正常 build 拒絕 | ✅ |
| trap 執行中又被打斷 | 下次的檢查會擋 | ⚠️ 推論 |
| wbox 後跑 `--card-only` | gate FAIL | ✅ 真 rootfs |
| 降級到沒有 P1b 的 pin | 正常 build 的 gate 照樣 PASS(helper 沒有 seam);`--wbox` 因沒有 helpers.list 而拒絕;firmware CI 的自測刻意明確失敗 | ✅ rc=1 + 訊息 |
| 兩板同一棵樹 | stamp 每板一個;build_dir 依 CPU 分開 | ⚠️ 推論 |
| bcm2710 | 殘項 | — |
| 節點的 crash / respawn | Arm 讀完就刪,所以 respawn 後不會再 arm | ✅ 程式碼 |
| `--boot` | 不 Arm,只印標記 | ✅ 程式碼 |

**安全**
- 出貨的 release image:新增的攻擊面只有 argv `--version`(讀 `/etc/batman-build`,不需要 root)。✅ strings 全 0,payload 經 gate。
- test image:killpoint 目錄必須是 root 0700、非 symlink;檔案用 `O_NOFOLLOW|O_NONBLOCK` 開,對 fd 做 fstat,要求恰為 0600、link 1、≤ 64 B。✅ 單元測試。
- `/tmp/run` 在節點上是否為 root 0755:⚠️ 未上節點確認(沿用 r3)。
- supply chain / 我們自己的錯:m1(patch 範圍)、m2(單元測試的保護)。
- 秘密:無新增。

## 分類

- ✅:Go 兩種 tag + race + vet;arm64 sha 與 strings;Makefile 的空 tag;真 payload 經 gate 三種模式;自測 46 / 53;舊 pin 明確失敗;3 個 Go 突變 + 4 個 lib 突變 + 1 個順序突變 + 1 個 gate 突變全被抓;rename 旁路實證;SafeForTests 缺席時走到真 `fire` 的實證;E-H6 證據檔。
- ⚠️:m4;OpenWrt CGO=1 toolchain 下 release helper 相同(只由原始碼與 Makefile 推論);兩板共樹;trap 被二次打斷;節點上的 `/tmp/run` 權限。
- ❌:GitHub CI 實跑(要 pin bump 後);以 root 跑 Go 測試(依指示不跑);bcm2710 build;節點端任何檢查。
