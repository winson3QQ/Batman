# 254-p3-impl v7.9(89b989b)審查 A — 正確性優先(S5 整份)

範圍:§3.1-5/7、§3.7、§3.8、§3.11、§12(含 §12.5 負對照、§12.5.18)、附錄 E–K,以及 §4 / §5 / §6 / §7 / §8 / §10 / §11 中 S5 用到的列。只讀:沒有改任何 repo,沒有上節點。原始碼:`/home/yello/Batman-p3` @ 89b989b、`/home/yello/firmware-2710` @ 02f0913d(build_dir、stamp / build-board / lib-wbox / workflows);target busybox 1.36.1(a72 build)以 `qemu-aarch64-static` 實跑。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 0 MAJOR / 11 MINOR。**

- B14-MAJOR-1(bench image 經 CI 自動公開)在文字上關了:bench 旗標只從 `--bench` 來、`batman-release.env` 出現就 stamp 失敗、CI gate 遇 bench 一律 FAIL;我對過 workflow 結構,沒有第二條會發布 bench 的 CI 路徑(V5、V6)。
- A14 的 13 項、B14 的 8 項 MINOR,**照文字逐處核對**(不看附錄 K):18 項已關;3 項只關一半(m1 的 §5.3、m4 的「3 s」、m10 的 app 上限範圍)。
- v7.9 新帶進來的洞都是 MINOR。其中有兩項**實測證實**照字面寫不會動:
  - 寫者的重試實際只等約 2 s,不是 3 s;`exec 9>>… || exit 18` 在 busybox ash 上不會走到 `exit 18`(m3,qemu)。
  - harness 的 `signrel.py` 判官拒絕 `.wbox-*` 與無後綴的版本字串,和 §3.7.1「以 signrel 為準」互相矛盾;`.bench` 的位置若放在 `.wbox-` 之後,會讓 `prov-254.sh:161` 把版本判成錯的 wbox 名字(m6、m7)。
- 最該在實作前補的是 m1:`slotMu` / `updMu` 兩把鎖的順序沒寫。設計裡已經有「slotMu → updMu」(apply),也有只寫「在 updMu 內」的路徑(prepare、tick、owner/remove 中止 worker)。實作者照直覺寫,很容易做出 helper 死鎖。

---

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | busybox ash 的 `exec 9>>/nonexistent/x \|\| exit 18`:**整個 shell 以 rc 1 結束**,`\|\| exit 18` 與下一行都不執行;包在 `{ …; } 2>/dev/null \|\| exit 18` 也一樣(rc 1,EXIT trap 有跑) | qemu 實跑(§附 A) |
| V2 | 照 A14 給的迴圈(`until flock -n 9; do n=$((n+1)); [ $n -ge 3 ] && exit 14; sleep 1; done`):別人持鎖 2 s → 第 2 次重試拿到(2057 ms);持鎖 4 s → **2045 ms** 就回 rc 14。也就是 3 次嘗試、總共只等 2 s | qemu 實跑 |
| V3 | 共享鎖的 fd 形式讀者 `( exec 8<$L; flock -s -n 8 )`:沒人持鎖 → 拿到;有人持排他鎖 → busy;`PATH` 裡沒有 flock 時 `command -v flock \|\| exit 18` → rc 18 | qemu 實跑 |
| V4 | `exec 9>>file` 在 umask 022 下建出 **0644** 的檔(不是 §5.3 寫的 0600);在 0700 的 RunDir 裡功能上無害 | qemu 實跑 |
| V5 | stamp 從**環境變數**讀 `BATMAN_WBOX`(`stamp-batman-build.sh:55`);`build-board.sh` 先 `wbox_env_reset` 再依 `--wbox` 設(`build-board.sh:65-69`、`lib-wbox.sh:19`)。所以「只從參數來」只在 `build-board.sh` 路徑成立;直接跑 stamp 或 CI 會吃環境變數 | 原始碼 |
| V6 | CI 有三條 build 路徑:`build-firmware.yml`(被 `build-release.yml` / `build-pr-*.yml` 呼叫;stamp 只對兩個 bcm 板,`:135-137`)、`fast-build.yml`(**沒有 stamp**、只上傳 5 天的 artifact、不發布)、`github-release.yml`(只建 draft prerelease,不 build)。`build-release.yml` 的 release job `needs` 全部 build job(`:150`),gate 失敗 → 不發布 | workflow grep |
| V7 | OpenWrt 每次 `make` 都 `rm -rf $(TARGET_DIR)` 再 `prepare_rootfs … files`(`package/Makefile:96,119`);`build-board.sh` 第 7 步比對 rootfs 裡的 stamp 與 `logs/stamp-*.txt` → stamp 的 `rm -f` 鑰匙檔再放的做法可行,舊鑰匙不會殘留在 rootfs | 原始碼 |
| V8 | `signrel.py` 判官的版本規則 `^\d+\.\d+\.\d+-[A-Za-z0-9]+\.\d+(\+[A-Za-z0-9.]+)?$`(`:47`,`verify()` `:210` 使用):`…+fbc01ae.fw02f0913.dirty.wbox-test` → **False**;`1.5.14`(無後綴出貨形式)→ **False**;`….fw02f0913.bench` → True | python 實跑 |
| V9 | harness 解析 wbox 版本:`prov-254.sh:161` 取 `${sv##*.wbox-}` 必須 = `BATMAN_WBOX`;`prov-dv-254.sh:30` 以 `%%.dirty.wbox-*` / `%%.wbox-*` 截掉後綴 | 原始碼 |
| V10 | `batman-slot` 的 RunDir 由 `rundir.sh` 給(`/tmp/run/batman`,root 0700);拿不到時 `RUNDIR=/nonexistent/batman-rundir`、`need_rundir` → die(`batman-slot:61-65`) | 原始碼 |
| V11 | helper 現有的 p6 寫者(`SetLastKnown` 等,`cmd/batman-provhelper/main.go:339-355`)不檢查 `/opt/batdata` 是否為掛載點;它們靠「檔案本來就在」(先讀再寫),不 `MkdirAll` | 原始碼 |
| V12 | autocommit 的退回走 `batman-slot reboot committed`(不拿 flock,`batman-autocommit:246`);`commit` 失敗會重新累積(`:553-556`) → 寫者 rc 14 只會延後 commit,不會讓壞版本留下 | 原始碼 |

---

## 1. v7.8 發現:照文字逐處核對

| 發現 | v7.9 文字 | 判定 |
|---|---|---|
| B14-MAJOR-1 bench 經 CI 公開 | §3.7.2:`--bench`、release.env 有就 stamp 失敗、`rel` + bench 失敗、CI gate 遇 bench FAIL;§12.5 兩列負對照 | ✅(V5、V6:release job `needs` 所有 build;`fast-build.yml` 沒有 stamp 所以不可能是 bench)。建議見 m10 |
| A14-m1 `sleep 0.2` | §3.7.3:`sleep 1` × 3、先 `command -v flock` → 18 | ⚠️ 改了,但實際等待 2 s,文字寫 3 s;`exec` 開檔失敗走不到 18 → **m3** |
| A14-m2 / B14-m1 舊文字 | §3.7.3 write 列、§3.7.5-7、§4 兩處、§5.1、§7、§10 | ⚠️ 都改了,**§5.3 `batman-slot.flock` 列仍寫「autocommit(`flock -n` 試拿)」**(`254-p3-impl.md:617`)→ **m4** |
| A14-m3 / B14-m2 「DEV 信任 T」 | §12.2-5 整點標 v7.8 取代;§10 改成「只有 bench build(含以 `--bench` 建的 prov_test)」 | ✅ |
| A14-m4 prov_test 怎麼信任 T | 只經 `--bench` | ✅ |
| A14-m5 / B14-m5 旗標來源、白名單、殘留、版本 | `--bench`、只收 `T`、`rm -f`、`+… .bench` | ✅(V7 證實 `rm -f` 有效)。`.bench` 的位置沒定 → **m7** |
| A14-m6 bench 節點裝一般 image | §6 列;`signrel.py` 預設拒簽、`--allow-no-key`;負對照改 Go + 離線 gate | ✅ |
| A14-m7 / B14-m4 沒鑰匙的文字、可見性 | reason 24、§3.11-5 文字、status `trust` | ✅;但 §12.5「鑰匙檔」列仍寫「缺 → 21」,`trust` 的指紋輸入沒定義 → **m5** |
| A14-m8 `apply_boot_id` 與 tick | 拿到 `slotMu` 才寫;`updMu` 讀-改-寫;記憶體「已 disarm」 | ✅;但兩把鎖的順序沒寫 → **m1** |
| A14-m9 / B14-m7 刪檔 tick 與 prepare | 同一個 `updMu` | ✅ |
| A14-m10 / B14-m6 EAGAIN 計數 | 拿掉計數;app 重試 3 次 | ⚠️ app 的上限只數「prepare 回 15」,租約失敗卻是 worker 經 status 回報的 → **m2** |
| A14-m11 孤兒 boot 目錄 | §3.7.5-4:flock 沒被持有就刪了重建;被持有 → `E_BUSY` | ⚠️ 這一步在非同步的 worker 裡,回不了 `E_BUSY`,而且上傳檔已經 unlink → **m8** |
| A14-m12 repo、lint 範圍 | §10 改 Batman feed;§3.7.3 lint 範圍 | ✅ |
| A14-m13 shell 讀者 fd 形式、D 狀態文字 | §3.7.3、§3.11-9 | ✅(V3 證實可用);§5.3 沒跟著改 → m4 |
| B14-m3 從 overlay 讀鑰匙 | 只讀 `/rom` | ✅;`/rom` 不在時 `trust` 回什麼沒寫 → m5 |
| B14-m8 lint 只抓 `&` | lint 加 `setsid` / `nohup` / `start-stop-daemon` / init start + 通用測試 | ✅ |

---

## 2. BLOCKER / MAJOR

無。

---

## 3. MINOR

**m1 `slotMu` / `updMu` 的鎖順序沒有寫 → 實作很容易做出 helper 死鎖**
- **情境**:設計裡已經有兩種順序:
  - `update.apply`:持 `slotMu` → 在裡面寫 update-last(`updMu`)(§3.7.4);
  - 只寫「在 `updMu` 內完成」的:`update.prepare`(關窗、設 `updating`、啟動 worker)、4 s 刪檔 tick、`owner/remove`「一併清掉窗與 pending、中止 worker」(§3.8.2、§3.7.5-9)、`update.check` 第 6 步寫 pending。
- 自然的實作:`owner/remove` 拿 `updMu` → 中止 worker → **等 worker 結束**。worker 這時持 `slotMu`(正在 `write`),結束時要拿 `updMu` 記失敗 / 清 `updating` → 兩邊互等。另一個:`update.check` 若持 `updMu` 判斷「worker 在跑 / 窗開著 / pending 屬於別人」再去跑 `bootinfo`(`slotMu`),同時另一位擁有者的 `apply` 持 `slotMu` 等 `updMu` → 互等。
- **後果**:helper 卡死,BLE 管理、更新、設定全部停住;§3.7.6(a)只看 procd instance 在不在 → 看不出來,直到重開。
- **修法(只加一條規則,不加機制)**:§3.7.4 寫明「順序永遠是 `slotMu` → `updMu`;持 `updMu` 時不准等 `slotMu`、不准等 worker 結束(只送取消信號後放鎖)」;`update.check` 先在鎖外跑 `batman-slot`,最後才在 `updMu` 內重新判斷 busy 條件並寫 pending。
- **測試**:Go `-race` + 接縫讓 worker 的 `write` 停 30 s,期間同時跑 `owner/remove`、`update.check`(另一位擁有者)、tick → 10 s 內全部回應。負對照:`owner/remove` 在 `updMu` 內等 worker → 逾時。

**m2 app「重試 3 次」只數 prepare 的回應,但租約失敗與步驟 1 的其他失敗都是 worker 經 status 回報的**
- §3.7.5-1:「`EAGAIN` → 15(app 重傳;app 端最多重試 3 次,§3.11-12)」。§3.11-12:「prepare **連續 3 次回 15** → 節點拒絕上傳檔」。
- 但 `update.prepare` 一啟動 worker 就回 phase 2(§3.7.4);租約、link count、fstat 的失敗都在 worker 裡,結果是 `update.status` = 0 + 15。照 §3.11-12 寫的 app 不會把它算進 3 次 → B14-m6 要擋的「被入侵的 provd 讓 app 無限重傳 126 MB」仍然存在。
- **修法**:§3.11-12 改成「同一份 sha,prepare 回 15 **或** status 0 + 15,合計 3 次 → 提示重開節點」。
- **測試**:app 端單元測試(U9);節點端不用改。

**m3 寫者重試的實際行為與文字不同,`exec` 開檔失敗走不到 rc 18,鎖檔權限不是 0600**
- (a)「`sleep 1` 重試 3 次」照 A14 的迴圈 = 3 次嘗試、**總共等 2 s**(V2)。§3.7.3 寫「由寫者的 3 s 重試吸收」。`bootinfo` 實際耗時還是 ⚠️ NEEDS-NODE(§12.5 末)。超過 2 s 時,autocommit 的 `commit` 撞到 helper 啟動時的 `bootinfo` 會 rc 14(V12:只延後 commit,不危險)。**修法**:寫死成「第 1 次 + 3 次重試,每次間隔 1 s,共 3 s」(`[ $n -gt 3 ]`),或把文字改成 2 s;§12.5「寫者重試」那列的持鎖時間改成 2.5 s(在兩種寫法之間能分辨)。
- (b)`exec 9>>$RUNDIR/batman-slot.flock` 開不了時(RunDir 不能用),busybox ash **直接以 rc 1 結束**,`|| exit 18` 不會執行(V1)。rc 1 落在「其他 → reason 21」,結果仍是 fail-closed,但與「鎖相關失敗 = 18」的表不一致。**修法**:開檔前先 `[ "$RDOK" = 1 ] || exit 18`(現有 `need_rundir` 改成 exit 18),不要依賴 `exec … || exit`。
- (c)`exec 9>>` 依 umask 建 0644(V4)。§5.3 寫 root 0600。**修法**:`( umask 077; : >> "$f" )` 先建,或 §5.3 改成「權限由 RunDir 0700 保證」。
- **測試**:(a)(b) 都在 target busybox(qemu)跑;負對照:`exec … || exit 18` 版本在 RunDir 不存在時回 1。

**m4 §5.3 的 flock 列沒改(B14-m1 只關一半)**
- `254-p3-impl.md:617`:「batman-slot(持有)→ batman-slot、helper、autocommit(`flock -n` 試拿)」。§3.7.3 已改成讀者用共享鎖的 fd 形式。實作者看介面表會做成排他試拿 → 讀者會讓寫者偶發 rc 14(A13-m1 的原問題)。
- **修法**:改成「讀者:共享鎖試拿(shell:`exec 8<$f; flock -s -n 8`;Go:`os.Open` + `Flock(LOCK_SH|LOCK_NB)`),不建檔」;「缺」欄補「不存在 = 不忙;開不了 = 忙 + log」。

**m5 鑰匙檔的狀態對應不完整、互相矛盾**
- §12.5 負對照「鑰匙檔 | 缺、多行、壞點、min-serial 0 → reason 21」(`:877`)與 §3.7.1「缺檔 → reason 24」矛盾。照負對照寫的測試會要求錯的值。
- 兩個檔只缺一個時是 24 還是 21,沒寫(§3.7.1 只說「缺檔 → 24」)。只有 pub 沒有 min-serial,是 build 壞了,不是「這個 image 本來就不接受 app 更新」。
- `trust` 欄位:`/rom` 不存在時回 `none` 還是 `bad`,沒寫;「sha256 指紋」對**哪些 bytes** 算(65 B 點、130 字元 hex、含不含換行)沒寫。gate 比 `release-root.fpr`、app 釘指紋、status 的 `trust` 三處要同一個定義,否則 app 比不到 R、也認不出 T。
- **修法**:一張小表:兩檔都不在 → 24 / `none`;只有一個、格式錯、`/rom` 不在 → 21 / `bad`;指紋 = sha256(65 B 非壓縮點),`trust` = 前 8 bytes hex,`release-root.fpr` = 全 32 bytes hex。gate 的「一般 build 不得有鑰匙」也包含 `release-min-serial`。§12.5 那列改成「缺 → 24;只缺一個、多行、壞點、min-serial 0 → 21」。

**m6 harness 的版本判官與 §3.7.1 不一致(「格式以 signrel 為準」反而會錯)**
- §3.7.1 接受無後綴的出貨形式,並說 `+meta`(含 `.wbox-*`)一律忽略;§3.7.1 同時說「格式契約以 `signrel.py` 為準」。
- `signrel.py:47,210` 的判官**拒絕** `….dirty.wbox-test` 與 `1.5.14`(V8)。v7.9 的 bench prov_test(`--bench --wbox`)payload 都帶 `.wbox-`,harness 自己的 `--verify` 會說它「unparsable」;Go 若照「以 signrel 為準」也拒,所有要在 prov_test image 上跑的 app 更新負對照都跑不起來。
- **修法**(harness PR,#290 先進 main):`VERSION_RE` 改成 `^\d+\.\d+\.\d+(-[a-z]+\.\d+)?(\+[A-Za-z0-9.-]+)?$`(通道收 `wsl|ci|rel`);selftest 加 `.wbox-x`、`.bench`、無後綴三案。設計 §3.7.1 寫出這條正規式,兩邊同一條。

**m7 `.bench` 放在版本字串的哪裡沒寫;放在 `.wbox-` 之後會讓 harness 誤判**
- stamp 現在組 `REL-CH.N+F7.fwW7[.dirty][.wbox-X]`(`stamp-batman-build.sh:57`)。§3.7.2 只寫「加 `+… .bench`」。
- 若加在最後(`….wbox-test.bench`),`prov-254.sh:161` 取 `${sv##*.wbox-}` = `test.bench` ≠ `BATMAN_WBOX` → FAIL「version names wbox variant test.bench」;`prov-dv-254.sh:30` 截掉後綴的結果也不同(V9)。
- **修法**:規定 `.bench` 緊接在 `fwW7` 之後、`.dirty` / `.wbox-` 之前:`REL-CH.N+F7.fwW7.bench[.dirty][.wbox-X]`;stamp 的測試加一案 bench + wbox。

**m8 孤兒 boot 目錄的檢查放在非同步 worker 裡,回不了 `E_BUSY`,而且那時上傳檔已經沒了(A14-m11 只關一半)**
- §3.7.5-4 把「目錄已存在:flock 沒被持有 → 刪了重建;被持有 → `E_BUSY`」寫在 worker 第 4 步。但 worker 是 prepare 回應之後才跑的(§3.7.4),而且第 1 步已經 `unlinkat` 了上傳檔。這時只能記成失敗(哪個 reason 沒寫),使用者要重傳 126 MB。§3.7.3 rc 14 列寫的是「新 worker 建 boot 目錄**前**先試拿鎖,拿不到 → `E_BUSY`」,兩處不一致。
- **修法**:這個檢查(試拿 flock + 清孤兒目錄)搬到 `update.prepare` 同步的前提檢查裡、在啟動 worker 之前;拿不到 → prepare 回 `E_BUSY`,窗與上傳檔都保留。§3.7.5-4 只留「目錄已由 prepare 準備好」。
- **測試**:接縫讓一個外部 `batman-slot` 持鎖 → prepare 回 `E_BUSY`、上傳檔仍在;放鎖後 prepare 成功。負對照:在 worker 裡檢查 → 上傳檔被 unlink、status 0 + 21。

**m9 update-last 在 p6 沒掛上時會寫到 overlay**
- §6「p6 壞 / 滿 / 唯讀」列只寫寫入失敗的情況。p6 沒掛上時,`/opt/batdata` 是 overlay 上的普通目錄;helper 若照常見寫法 `MkdirAll(state)` 再寫,寫入「成功」,但檔案在**這個槽**的 overlay 上。重開進 `to_slot` 後讀不到 → 第 5 列 → 0(「沒有更新」),而試用其實在跑。現有的 p6 寫者不檢查掛載點,只是剛好不建目錄(V11)。
- **修法**:§3.7.4 寫明 update-last 只寫在既有的 `/opt/batdata/state/`(不建目錄),且 `/opt/batdata` 的 `st_dev` ≠ `/` 的;否則 prepare / apply 回 `E_STORAGE`。§6 那列加「沒掛上」。
- **測試**:Go 單元測試(state 目錄不存在 / 與 `/` 同一個 st_dev → `E_STORAGE`)。負對照:`MkdirAll` → 成功寫進 overlay。

**m10 建議:bench 旗標改成 stamp 的參數,不經環境變數(拿掉機制)**
- 現在的設計照 `BATMAN_WBOX` 的做法:`build-board.sh` 先 unset,再把 `--bench` 轉成環境變數給 stamp(V5)。所以「只從 `--bench` 來」只在 `build-board.sh` 成立;直接跑 stamp、或 CI 的 job `env:` 設了它,stamp 照樣做出 bench build,只能靠 gate 事後擋。
- **修法**:stamp 改收參數 `stamp-batman-build.sh <board> [--bench]`,**完全不讀** `BATMAN_BENCH_TRUST` 環境變數;`build-board.sh` 只在 `--bench` 時傳。這樣 release.env 檢查、`wbox_env_reset` 的 unset 都不再需要,CI 的 stamp 呼叫(`build-firmware.yml:137`)本來就不帶參數 → CI 在結構上建不出 bench;gate 的「CI 遇 bench FAIL」留作第二道。
- **測試**:環境變數設了 `BATMAN_BENCH_TRUST=T`、沒有 `--bench` → stamp 產出一般 build。負對照:讀環境變數的版本 → bench。

**m11 小的一致性**
- §3.7.3「`apply`(既有)= `write` + `arm`」:sysupgrade 的 stage 2 是 `stage-root` → **鎖外**由 platform 串流 `dd` → `apply`(`platform-ab.sh:173-181,364-379`),`apply` 不讀 stdin,也不會做 `write` 新加的 `clear_root`。「= write + arm」會讓實作者以為 sysupgrade 也清 overlay。**修法**:改成「`apply` 的 boot 複製、讀回、arm 與 `write` / `arm` 共用同一組函式;rootfs 由 stage 2 串流、不做 `clear_root`(與現在相同)」。若要 sysupgrade 同版本重裝也清 overlay,另寫並列進 §6。
- §5.1 `update.check` 的 ok 回應列(`1 / 2 / … / 17 / 21`)沒有 24;24 另有一列。合併成一列,避免實作漏掉。

---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 判定 |
|---|---|
| `batman-slot.flock` | ✅ 只有 `batman-slot` 持排他鎖;讀者共享鎖試拿(V3)。權限與開檔失敗 → m3;§5.3 舊字 → m4 |
| 目標槽、tryboot 旗標、boot FAT 掛載 | ✅ |
| update-last(`apply_boot_id`、`rebooting`) | ✅ 寫者只有 helper、`updMu`、apply 在 `slotMu` 內寫。鎖順序 → m1;p6 沒掛 → m9 |
| 上傳檔 | ✅ 刪除者只有 helper,tick 與 prepare 同一把 `updMu` |
| `/tmp/run/batman/update/boot/` | ⚠️ 清孤兒的時機 → m8 |
| `release-root.pub` / `release-min-serial` | ✅ 寫者只有 stamp;`rm -f` 有效(V7)。旗標經環境變數 → m10 |
| pending、bearer、`provd-stable` | ✅ |

## 5. 生命週期(S5)

| 路徑 | v7.9 行為 | 判定 |
|---|---|---|
| install / 一般 DEV 第一次開機 | 沒有鑰匙 → 24、`trust = none`、app 文字「請用 ssh / 重燒」 | ✅(只缺一個檔的情況 → m5) |
| bench 節點(02 / 04 從 wsl.25 ssh 升上來) | stage 1 / 2 用 wsl.25 的舊 `batman-slot`(mkdir 鎖)→ 可行;之後 T → K_test | ✅ |
| 啟動 / 停止 / 重啟 helper | 啟動時刪上傳檔、`bootinfo`、disarm tick | ✅;孤兒目錄 → m8 |
| crash loop(helper) | 每次啟動 `bootinfo` 短暫持鎖 | ✅(寫者實際等 2 s → m3) |
| 正常 OTA | check → bulk.open → PUT → prepare → 兩遍 → write → apply → 試用 → commit | ✅;鎖順序 → m1 |
| 上傳被干擾(provd 被入侵 / AP 鄰居) | 每次 15,app 上限 3 次 | ⚠️ 上限漏數 worker 的 15 → m2 |
| 試用退回 | `reboot committed`(不拿 flock) | ✅(V12) |
| sysupgrade(stage 2 在 ramfs) | `RAMFS_COPY_BIN` 帶 flock | ✅;「apply = write + arm」字面 → m11 |
| 降級到沒有 P3 的版本 | ssh:stage 2 用 P3 的 `batman-slot`;經 app 不行(既有界線);update-last 留著,版本對不上 → 0 | ✅ |
| 斷電 | RunDir 消失 → 鎖跟著消失 | ✅ |
| p6 壞 / 唯讀 / **沒掛上** | 前兩者 `E_STORAGE`;沒掛上沒寫 | ⚠️ m9 |
| 依賴重啟(procd、openmanetd start 在持鎖中) | `9>&-` + lint + 通用測試 | ✅ |
| DEV → PROD | bench:T 簽、內建 R 的 `rel` 過渡版 | ✅ |
| bench 節點裝一般 image | signrel 預設拒簽;§6 界線 | ✅ |
| bench prov_test(`--bench --wbox`) | 可建;版本帶 `.wbox-` | ⚠️ harness 判官拒絕 → m6;`.bench` 位置 → m7 |
| CI 建 bench | gate FAIL、release job 不跑(V6) | ✅;結構上可以更簡單 → m10 |
| bcm2710 | 同一份腳本、同一個 busybox 設定 | 只編譯(使用者決定);m3 兩板都適用 |

## 6. 現場劇本(抽查)

- **擁有者 A 更新到一半,另一位擁有者 B 把 A 移除**:`owner/remove` 中止 worker。若實作在 `updMu` 內等 worker 結束,而 worker 持 `slotMu`、結束時要 `updMu` → helper 卡住,BLE 管理全斷,直到重開(m1)。
- **被入侵的 provd 每次 PUT 後都留著寫入 fd**:prepare 回 phase 2 → worker 租約 `EAGAIN` → status 0 + 15。照 §3.11-12 的 app 不算這一次 → 無限重傳(m2)。
- **helper 在 worker 寫入中 crash、重啟**:孤兒 `write` 讀到 stdin EOF → 讀回失敗 → 槽 BAD、結束;孤兒結束前 app 又來 prepare → worker 先 unlink 上傳檔,才發現鎖被持有 → 重傳(m8)。
- **開發者建 bench prov_test 給 04**:版本 `….wbox-x.bench`(若放最後)→ daily-validation 的 wbox 名字比對 FAIL;signrel `--verify` 判 unparsable(m6、m7)。

## 7. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 0 MAJOR / 11 MINOR)。**

- v7.8 唯一的 MAJOR(B14-MAJOR-1)在文字與 workflow 結構上都已關閉。
- 建議**實作前**一定要改:
  - m1:鎖順序一條規則。否則最可能出現的是死鎖,而且測試不容易抓到;
  - m5、m6:鑰匙狀態表與版本正規式。兩邊(Go 與 harness)照現在的字會寫出不同的東西;
  - m3:重試的實際秒數與 rc。
- 其餘可在實作 PR 一起處理,每項都附了測試與負對照。m10 是拿掉機制的建議(stamp 不讀環境變數),不改也安全。

---

### 附 A:qemu 實跑原始輸出

腳本(target busybox:`/usr/bin/qemu-aarch64-static -L root-bcm27xx root-bcm27xx/bin/busybox sh …`):

```
t1: exec 9>>/nonexistent/x || exit 18 ; echo after
t2: trap 'echo EXITTRAP' EXIT; { exec 9>>/nonexistent/x; } 2>/dev/null || exit 18; echo after
w : command -v flock || exit 18; exec 9>>$L || exit 18
    n=0; until flock -n 9; do n=$((n+1)); [ $n -ge 3 ] && exit 14; sleep 1; done; echo GOT n=$n
```

```
/tmp/tmp.9EdN0o2cUS/t1.sh: line 1: can't create /nonexistent/x: nonexistent directory
rc=1                         (t1;"after" 沒印)
EXITTRAP
t2 rc=1
GOT n=2
w rc=0 ms=2057               (別人持排他鎖 2 s)
w4 rc=14 ms=2045             (別人持排他鎖 4 s → 只等了約 2 s)
notbusy                      (共享鎖 fd 形式,沒人持鎖)
busy                         (有人持排他鎖)
nf rc=18                     (PATH 沒有 flock)
644                          (umask 022 下 exec 9>> 建檔的權限)
```

### 附 B:signrel 版本正規式實跑

```
1.5.14-wsl.25+fbc01ae.fw02f0913                 True
1.5.14-wsl.25+fbc01ae.fw02f0913.dirty.wbox-test False
1.5.14-wsl.25+fbc01ae.fw02f0913.bench           True
1.5.14                                          False
```
(`tests/tools/peer/signrel.py:47` 的 `VERSION_RE`,`verify()` 在 `:210` 使用)
