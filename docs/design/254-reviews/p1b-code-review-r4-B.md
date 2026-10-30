# PR-P1b + firmware --wbox 程式碼審查 第 4 輪 — 審查者 B

(審查者 agent 無法寫檔,全文由主 session 依其回報存入。)

範圍(整體):Batman `feat/254-p1b-seams` @ 2563b1b(對 origin/main 14 檔 +880/−5)、firmware `feat/254-wbox` @ f0f7d681(對 e7c2a222 9 檔 +492/−3)、rc `rc/254-p1b` @ 9cc6f3a5、設計 harness/254-h23 @ e2e013a、兩個 wsl.6 payload、E-H6 證據檔。測試都在 /home/yello 下 git archive 拷貝跑(用完已刪、無殘留程序);prov_test Go 測試一律非 root、PATH 前放假 `reboot`;未改 worktree、未 build、未碰節點。

## 結論
**APPROVE-WITH-CHANGES:0 BLOCKER / 0 MAJOR / 7 MINOR。** 合併前條件:rc 重切(見「rc 計畫」)、m7 殘項寫進 #254。
- 第 3 輪 MAJOR(B-M1)已修,負對照重跑成立;第 3 輪雙方 MINOR 已修或記殘項。
- 本輪發現沒有一條會讓 seam 不被發現地進出貨 image。

## 實跑證據(✅)
- Go 1.26.4(2563b1b 拷貝,非 root):兩 tag 12 package 全 ok(node 11.8 s);`-v`(seam/node/cmd)49 PASS / 0 SKIP / 0 FAIL;`-race` 兩 tag ok;`go vet` 兩 tag 乾淨。
- arm64 helper(`-trimpath -s -w`,CGO=0):

| commit / tag | sha256 前 16 | killpoint | marker | armed | 點名 | /dev/kmsg | sysrq-trigger | 單元測試字串 | go version -m |
|---|---|---|---|---|---|---|---|---|---|
| 014778c release | 447c0b793c97d046 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 無 -tags |
| 2563b1b release | 447c0b793c97d046(位元相同) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 無 -tags |
| 014778c prov_test | 03ea4fc0ebd39a43 | 7 | 1 | 1 | 1 | 1 | 1 | 0 | -tags=prov_test |
| 2563b1b prov_test | 750d4445b9eb7d59 | 7 | 1 | 1 | 1 | 1 | 1 | 0 | -tags=prov_test |

  兩個 prov_test helper 同大小(4456610 B),`cmp -l` 77 byte 不同,`strings` 差異只有 Go build ID;`SafeForTests` 未被引用被 linker 丟掉。014778c→2563b1b 非測試產品差異只有 Makefile `else GO_PKG_TAGS:=` 與 `hook_provtest.go`;`seam_provtest.go` 沒改(014778c 本就拒絕一行多名,第 3 輪補的是測試)。
- Go 突變:M1 `At` 忽略 arm → seam 2 FAIL、node 0.071 s FAIL(`panic: seam: killpoint claim-after-persist fired in a unit test that did not arm it`);M2 = M1 + 刪 node TestMain → `test timed out after 40s`、假 reboot 被呼叫 1 次(→ m1);M3 SafeForTests 不換 reboot → FAIL;M4 arm 取 `Fields[0]` → FAIL;M5 不改 sysrqPath → FAIL;M6 拿掉 afterPersist 點 → 3 位置測試 FAIL;M7 `version()` 無條件印 marker → FAIL。
- Makefile 語意(⚠️ 最小 makefile):`GO_PKG_TAGS=prov_test make` → `tags=[] origin=file`;`BATMAN_PROV_TEST=1` → `tags=[prov_test]`;`make -e` / 命令列賦值仍可蓋過,build-board 兩者都沒用。
- firmware(f0f7d681 拷貝):`test-build-board-wbox.sh` 53/0;`test-prov-test-gate.sh`(2563b1b)46/0;pre-P1b main 來源 → 明確訊息。lib / build-board 突變:normal 檢查拿 `-o` 2 BAD、normal 檢查 no-op 3 BAD、拿範圍檢查 2 BAD、env 不 unset GOFLAGS 1 BAD、trap `clean -qfd` 1 BAD、normal check 移到 make 後 → 順序 BAD;**存活**:拿掉「patch 什麼都沒改」(m4)、`wbox_env_reset` 被註解掉(m2)、gate 呼叫拿掉 `${WBOX:+"$WBOX"}`(m2);等價突變:第二個 `wbox_apply` 放 make 後、`trap - HUP`。
- 真 payload 新 gate:SHA256SUMS 三檔 OK;normal → `ok (no test seam; helper tags=[])`;test → `ok (wbox test, tag prov_test, helper, helper tags=[prov_test])`;test 當 normal → `FAIL: /etc/batman-build carries BATMAN_WBOX=test in a normal build`。
- shellcheck:只有刻意 SC2064 / SC2148 與 `need()` SC1072/1073 誤報;`test-build-board-wbox.sh:124` 自訂 `ln()` 遮住 `/bin/ln`(SC2226,建議改名)。
- E-H6 證據檔與 §16.25 一致;⚠️ 該次有 `sync` 且由 shell 寫 sysrq;helper init 無 jail / capability(`batman-provhelper.init` 只有 command/respawn/stdout),推論 helper 可寫 sysrq 與 kmsg,未上節點驗。

## MINOR
- **m1** `SafeForTests` 要每個 package 自己在 TestMain 呼叫,且無測試守住 node 有呼叫(M2 實證)。`cmd/batman-provhelper` 無 TestMain:現在測試碰不到 `daemon()` / `seam.Arm`,但補 main.go 接線測試後 root 下會讀真 `/tmp/run/batman-prov-test`、`fire` 也是真的。修(擇一):`seam_provtest.go` 加 `init(){ if strings.HasSuffix(os.Args[0], ".test") { SafeForTests() } }` 集中保護 + 測試斷言 `reboot` 不是 `fire`;或 node 加「未 arm 觸發 → panic」測試並在 §16.19 規定新 prov_test package 要有 TestMain。
- **m2** `test-build-board-wbox.sh` 的「有呼叫」與「順序」用子字串比對,註解行也算;gate 呼叫少了 name 參數也過。fail-closed 但要等整個 build。修:排除註解行;gate 那條比對帶參數的完整呼叫。
- **m3** `wbox_normal_check` 在 git 失敗時 fail-open:非 repo → `NORMAL-OK rc=0`;`.git/index` 不可讀 → `NORMAL-OK rc=0`。`wbox_apply` 對 `git status` 有查 rc,這裡沒有。修:`o=$(git … ls-files -m -o) || { …; exit 1; }` + 「git 失敗 → 拒絕」案例。
- **m4**「patch 什麼都沒改」這條拒絕無測試(突變存活)。修:只有檔頭無 hunk 的 patch 案例,斷言 `changes nothing`。
- **m5** `bb_lock` 在「不准 root build」檢查之前:root 誤跑(或在無鎖檔的樹跑 `--card-only`)會建 root 擁有的 0644 鎖檔,之後 tree owner 每次 build 停在 `cannot open the build lock`(exit 2)(⚠️ 讀碼推論)。修:root 檢查移到 `bb_lock` 前;card-only 時鎖檔不存在就拒絕,不自己建。
- **m6** 設計 §3 擁有權表、§5 生命週期矩陣沒涵蓋 build 端:`logs/.build-board.lock`(SIGKILL 後孤兒 make 仍握 fd 9,正好防兩 build 共用 build_dir)、`logs/wbox-<board>.stamp`(三態)、`files/etc/batman-build`、build_dir 兩個 Go 套件、normal build 也讀 `feeds/batman`;§5 缺 SIGKILL、Ctrl-C / HUP、併行 build、wbox 後 `--card-only`、stamp 停在 in-progress;舊句:§4.2「trap 寫 stamp」、§2.1 Makefile 無 `else`。
- **m7** 第 3 輪殘項沒寫進 #254(`gh issue view 254` body + 33 則留言搜 `local-ab-tar|fast-build` = 0):r3 A-m6、r3 B-m6、r3 B-m8 只在設計 §16,依規則要補進 #254。

## rc 計畫:判定正確,是合併前條件
現況:firmware rc 9cc6f3a5 scripts = f0f7d681;Batman pin 仍 f6ac1f7(= 014778c),少了 Makefile `else` 與第 3 輪測試 → 依 §16.18 不是本輪審過的程式碼。實際影響很小(release 位元相同、prov_test 只差 build ID、wsl.6 兩 payload 新 gate 兩模式 ok),所以 wsl.6 只當「行為等價」佐證。重切:(1) Batman `rc/254-p1b` 對最終 P1b commit 的 `git diff -- feed/batman-prov` 為空;(2) pin 指它、`BATMAN_BUILD_N=7`、`BATMAN_NOTE` 寫 wsl.7 / 新 rc / P1b commit;(3) normal 與 `--wbox test` 都附 step 7 gate ok 行、`go version -m`、helper sha,release 與 prov_test sha 不同(以 OpenWrt toolchain 為準);(4) stamp 現在 `in-progress:test|1`,下次 build log 必有 `wbox variant changed`;(5) wsl.6 不上節點。第 4 輪若再修改要再切一次。

## 第 1–3 輪對照
r3 B-M1 ✅;r3 B-m1 ✅(⚠️ 最小 makefile);r3 B-m2 ✅(註解漏洞 → m2);r3 B-m3 ✅;r3 B-m4 ✅(git 失敗 fail-open → m3);r3 B-m5 / A-m4 ✅(E-H6 ramoops 307–308);r3 B-m6/m7/m8、A-m6 只在 §16(→ m7);r3 A-m1 / A-m2 / A-m3 / A-m5 ✅;r1 / r2 抽驗 ✅。

## 介面 / 生命週期 / 安全
- 擁有權:killpoint 檔 harness 寫、helper 讀完即刪;`feeds/batman` flock 下單一寫者;stamp 每板一個;表格缺項見 m6。
- 契約:`--version` 新版 rc 0、舊版 usage rc 2;killpoint 檔不符 → refused;gate 讀不到 / 缺項 / symlink → FAIL;`helpers.list` 打錯 → build 與 gate 都擋;例外 m3。
- 生命週期:normal → wbox → normal、Ctrl-C / TERM / HUP 還原;SIGKILL 後下次 build 提早拒絕;wbox 後 `--card-only` 被 gate 擋;舊 pin 下 CI 明確失敗(刻意)。bcm2710 殘項;GitHub CI ❌ 未實跑。
- 安全:release 只多 argv `--version`(euid 檢查前、只讀 world-readable `/etc/batman-build`、binary 位元相同);test 映像 killpoint 目錄 Lstat、檔 `O_NOFOLLOW|O_NONBLOCK` + fstat(nlink、特殊位元);`/tmp/run` 由 `/etc/init.d/boot:26` root 建(⚠️ 推論 0755);只有 DNODE 跑這種映像;我們自己的錯 m1–m5;秘密不涉及。

## 分類
- ✅ Go 兩 tag + race + vet;arm64 四份;Go 突變 7;lib / build-board 突變 11(7 抓、4 存活其中 2 等價);自測 53 / 46;pre-P1b 訊息;真 payload gate 兩模式 + 反向;git 失敗 fail-open;E-H6 檔;#254 搜尋。
- ⚠️ Makefile 語意(最小 makefile);m5;`/tmp/run` 權限;helper 節點寫 sysrq / kmsg 能力;prov_test 差異只看 strings。
- ❌ GitHub CI、bcm2710、OpenWrt toolchain 重 build、節點檢查。
