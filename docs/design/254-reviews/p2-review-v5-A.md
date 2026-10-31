# #254 PR-P2 `batman-provd` 設計 v5 — 對抗式審查 A(第 5 輪,整份重審)

審查者 A,2026-10-31。對象:`scratchpad/254-p2-impl.md` v5 全文 §0–§16。方法:§13–§16 不採信,從現場(認領、10 台一隊、路人、被攻陷的 provd、root 操作員)出發,把第 4 輪的單一 MAJOR(kernel patch 落點 / 閘門 marker)與新加的 session 撤銷規則對原始碼與真機重核;其餘章節抽查介面(擁有權 / 契約 / 生命週期)。

## 0. 我自己核過的事(✅ 原始碼 / 實跑;⚠️ 推論;❌ 沒驗到)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | `BATMAN_FW_COMMIT` = firmware 樹 `git rev-parse HEAD` 的前 7 碼(樹本體,含 `target/linux/bcm27xx/patches-6.6/`),由 `stamp-batman-build.sh` 寫;**`BATMAN_WBOX` 非空時 `DIRTY=1` 強制**(註解「a -wbox test variant is never a release: DIRTY forced」);`BATMAN_PROV_TEST` **不是 stamp 的 key**(key 清單 `:60-75` 固定) | `firmware-2710/scripts/stamp-batman-build.sh:36, 53-57, 60-75`;`254-h23-harness.md:183` 同樣寫「`BATMAN_WBOX` 有值 → `DIRTY=1` 強制」 |
| V2 ✅ | `BATMAN_PROV_TEST=1` 只由 `build-board.sh --wbox <name>` 依 `helpers.list` 的 `prov_test` tag 匯出(`wbox_apply`),harness 今天偵測 prov_test image 的方法 = helper `--version` 第 2 行 `BATMAN_PROV_TEST_BUILD_7f3a` | `scripts/lib-wbox.sh:17-19, 83-84`;`Batman/scripts/dv/prov-254.sh:469`;`dv-sbx.sh:71`;h23 `:103` |
| V3 ✅ | `build-board.sh` 第 2 步:base tree(`package target include …`)有 tracked 修改或 untracked 檔 → **拒絕 build**,除非 `BATMAN_ALLOW_DIRTY_BASE=1`;這個 override 不會出現在 stamp(只在 stdout) | `scripts/build-board.sh:85-95` |
| V4 ✅ | 節點 04 **今天從 Windows 端連得上**(WSL 端 `ssh` timeout,Windows Git Bash 成功):`/rom/etc/batman-build` = `1.5.14-wsl.16+c46dfc9.fw6aa0241`、`BATMAN_FW_COMMIT=6aa0241`、`BATMAN_DIRTY=0`、**無 `BATMAN_WBOX`**;無 `/usr/bin/btmgmt`、無 `/usr/bin/batman-provd`;helper `--version` 只有 1 行(非 prov_test);uptime 4:46(F-P10 的 panic 後重開) | 04 實跑(唯讀) |
| V5 ✅ | 主機 firmware 樹能解析節點的 commit:`6aa0241` → `6aa0241240ce…`(pin wsl.16 的 commit)、是 HEAD(`da30986f`)的祖先;#305 的 `1524084e` 是 `6aa0241` 的祖先;**`git cat-file -e 6aa0241:target/linux/bcm27xx/patches-6.6/999-batman-hci_bcm-close-flow-305.patch` 成立、對 `999-batman-eir-adv-flags-oob-254.patch` 不成立** → 「某 commit 的樹裡有沒有這個 patch 檔」可以不靠「加入 patch 的 commit id」直接問 git | `firmware-2710` 實跑 |
| V6 ✅ | `bt-uart-305.sh` 的閘門是 **FWCOMMIT 相等 → 才 stage kernel 模組**,沒有對應目錄時只印 `NOTE … not staged` 繼續跑;讀的是 `/etc/batman-build`(不是 `/rom`);沒有任何 `merge-base`;harness 沒有「firmware 樹路徑」的設定(只有 `DV_BT305_TOOLS_ROOT` 指向預先 build 好的工具目錄) | `Batman/scripts/dv/bt-uart-305.sh:9-10, 18, 24-33`;`grep -rn merge-base scripts/dv` = 0 |
| V7 ✅ | helper 改 record 的路徑**全部** `Generation+1` 後走 `commit` / `commitTxn`:claim `:548`、ssh_keys `:831`、owner.add `:877`、owner.remove `:904`、net.apply `:1134`、leave `:1192`;`root_password.reset`(`setPassword :461`)、`settings.set`、`diag.bundle` 不改 record;`resolve()` 只在 `p5.Generation > ov.Generation` 時重寫 overlay(gen 往上);`boot.Run` 寫 `Generation: 1` 新 record 或由 p5 重建 | `node/node.go`、`node/txn.go:13-52`、`node/wtxn.go:269-280`、`boot/boot.go:132-211` |
| V8 ✅ | **generation 可以在 provd 自己的一個動詞裡變兩次**:owner-op 動詞進門先 `resolve()`,overlay 比 p5 舊就先重建(gen 變一次,`node.go:753-761`),再做自己的 commit(gen 再 +1);`applyNet` step 3 commit 在 step 4 save 之前(F-P39 正確) | `node/node.go:748-761, 1131-1180` |
| V9 ✅ | **`boot.Run` 在 helper daemon 每次啟動都跑**(不只 `--boot`):helper 重啟(L11)也可能重寫 overlay(gen 1 新 record / 由 p5 重建) | `cmd/batman-provhelper/main.go:579-585` |
| V10 ✅ | kernel mgmt `add_advertising` 對**已存在的 instance 編號**是「就地覆寫」:`hci_add_adv_instance` 找到同號 instance → `memset` 舊資料、改寫 flags / data,**不會拒絕** | `linux-6.6.138/net/bluetooth/hci_core.c` `hci_add_adv_instance`(`:1604-1660` 一帶) |
| V11 ✅ | `info.owners` 的 `owner_key_id` 語意與 helper 一致:`ownerRemove` 用 `sha256(o.Pub)` 比 kid | `node/node.go:884-896` |
| V12 ❌ | F-P41 le_states、`btmgmt add-adv` 在 patched kernel 上的行為:本輪沒有新的實證(設計自己也標 ⚠️) | — |

## 1. 第 4 輪 MAJOR 的實際修復狀態(不看 §16)

| 第 4 輪 | v5 處置 | 判定 |
|---|---|---|
| A4-M1 / B4-M1 patch 落點與 marker 無寫者 | 落點改 `target/linux/bcm27xx/patches-6.6/999-…`(一份兩板共用)✅ 正確(V5 證實這條路有既有 patch 且 git 可問);閘門改 `/rom/etc/batman-build` 的 `BATMAN_FW_COMMIT` 祖先檢查 + `DIRTY=0` + `WBOX` + `PROV_TEST` | **落點關閉;閘門沒關**:四個條件裡 `DIRTY=0 ∧ WBOX≠空` 在今天的 stamp 腳本下**永遠不可能同時成立**(V1)、`PROV_TEST` 不是 stamp 的 key(V2)、harness 主機端沒有 firmware 樹的設定與「加入 patch 的 commit id」的來源(V6)→ M1 |
| A4-m3 / B4-m1 旁路 generation → 撤銷既有 session | §1.3 新列 + §4.3「session 撤銷」 | **規則本身對,但缺了「怎麼分 provd 自己的動詞 vs 旁路」**;照字面實作會在每次 join / update / leave / claim 把擁有者自己斷掉(V7 / V8)→ M2 |
| 其餘 m(ERate 不計新鮮、Disconnect async、L80 負對照、proxy 列 H3、accept 只計首次 Read 成功) | 已寫進 §4.1 / §4.4 / §3 / L80 / §2 | 關閉(與原始碼不衝突) |

## 2. BLOCKER

無。

## 3. MAJOR

**M1. §4.8 臂 2 的閘門照 v5 寫法永遠 FAIL(條件互斥),而且 harness 主機端沒有它需要的兩樣東西;實作者要嘛「修」成拿掉 `DIRTY=0`,要嘛臂 2 永遠不跑 — 兩者都不是設計要的。**
- 情境:臂 2 要在 prov_test image 上跑(需要 `btmgmt`,只有 `-wbox` 變體有,D9)。`-wbox` 變體的 stamp **一定** `BATMAN_DIRTY=1`(`stamp-batman-build.sh:56`,h23 :183 同一句)。閘門要 `BATMAN_DIRTY=0 ∧ BATMAN_WBOX≠空` → 不可能。接著:(a) `BATMAN_PROV_TEST=1` 不在 `/rom/etc/batman-build` 裡(V2),harness 讀不到這個 key;(b) `git merge-base --is-ancestor <加入 999 patch 的 commit> $BATMAN_FW_COMMIT` 需要主機上有 firmware 樹、而且要知道那個 commit id — 工作順序 §12 是 **H3 harness 先 merge、firmware PR 在後**,H3 寫單位時那個 commit 還不存在;harness 今天也沒有任何 firmware 樹路徑設定(V6:`bt-uart-305.sh` 是「預先 build 的工具目錄 FWCOMMIT 相等」,對不上就 `NOTE` 繼續跑,**那是寬鬆的 stage 邏輯,不是 fail-closed 閘門**,設計說「同一套」不成立);(c) `DIRTY=0` 想擋的是「本地把 patch 拿掉」,但 `build-board.sh:85-95` 本來就拒絕 base tree 有修改,除非 `BATMAN_ALLOW_DIRTY_BASE=1`,而這個 override 不進 stamp(V3)→ 就算 wbox 不強制 DIRTY,DIRTY 也只反映「有沒有改」不反映「改了什麼」。
- 證據:V1、V2、V3、V5、V6;設計 §4.8 第 2 段、§9「臂 2 前置閘」、§16 第 1 列。
- 修(全部用既有寫者,不發明自我宣稱的 marker):
  1. **patch 存在性**:不用「加入 patch 的 commit id」,改問 git 那個 commit 的樹:`git -C $DV_FW_TREE rev-parse --verify --quiet "$FW^{commit}"`(7 碼解不出 / 歧義 → FAIL)→ `git cat-file -e $FW:target/linux/bcm27xx/patches-6.6/999-batman-eir-adv-flags-oob-254.patch`(V5 已實證這條指令在 `6aa0241` 上對 305 patch 成立、對 254 patch 不成立 = 現成的負對照)→ 再 `git show $FW:<path> | sha256sum` 等於 harness 內記錄的 sha(Batman repo 一個小檔,firmware PR / pin bump PR 更新;sha 檔不存在 → FAIL)。這樣 H3 可以先 merge(單位永遠 FAIL 直到 pin bump 補 sha),不需要事先知道 commit id。
  2. **主機端設定**:`DV_FW_TREE`(或 `daily-validation` 既有的設定機制)必填;未設、不是 git 樹、commit 不在樹裡 → 單位 **FAIL**(不是 `NOTE`),寫進 h23 §4.8 / 單位 header。
  3. **DIRTY**:stamp 腳本(唯一合法寫者)多印一行它已經算好的理由,例如 `BATMAN_DIRTY_WHY=<why>`(`stamp-batman-build.sh:38-56` 的 `$why`,去前導空白);閘門要求 `BATMAN_DIRTY_WHY` **恰等於** `wbox-<name>`(= 只有 wbox 這一個理由,樹本體沒有 tracked 修改 / untracked / feeds override)。舊 image 沒這個 key → FAIL(fail-closed)。`check-prov-test-gate.sh` / `build-board.sh:190` 的 stamp 比對不受影響(同一腳本兩邊都產)。h23 §4.2 的 key 清單同步。
  4. **PROV_TEST**:閘門改讀 harness 既有的判定 = helper `--version` 第 2 行 `BATMAN_PROV_TEST_BUILD_7f3a`(`prov-254.sh:469`)加 `/rom/etc/batman-build` 的 `BATMAN_WBOX=<name>` 且 `helpers.list` 標 `<name>` 為 `prov_test`;把「`BATMAN_PROV_TEST=1`」這個字從 §4.8 / §9 拿掉。
  5. §6 的「kernel patch 落點與 stamp 產生者 ✅」加一行:**閘門的證據鏈 = fw commit → 該 commit 樹裡的 patch 檔 sha → `BATMAN_DIRTY_WHY` 只有 wbox**;誠實界線照舊(kernel 不在 #275 見證內)。

**M2. session 撤銷規則沒有「誰造成這次 generation 變化」的判定方式;照 §1.3 / §4.3 字面實作,provd 自己的每個改狀態動詞都會把擁有者 session 斷掉。**
- 情境(認領現場):擁有者手機送 `network/join`。helper `applyNet` step 3 就 commit(gen+1),step 4 `SaveTxn` 與動詞本體還要 ≤ 180 s(最壞 ≈ 960 s,F-P32 / F-P39)。`ctl` 每 4 s 輪 `info.state`,在動詞回應前就看到 `Generation != 上次`。設計說「非 provd 自己的動詞造成 `Generation` 變化 → 所有已認證 / 候選 session 立即 Disconnect」、「provd 自己的改狀態動詞成功後 → 以新集合逐 session 比對」,但 **provd 此刻沒有任何規則判斷這次變化是不是自己的**:`ops` 上的回應還沒回來、helper 的回應不帶 generation。最直接的實作(「gen 變了且沒有剛完成的自家動詞」→ 旁路)會在 join 進行中斷掉擁有者,join 的回應落空,app 只能重連讀 `unfinished`;`claim/finish` 同樣(`claimVerify :548` 在回應前 commit)、`network/update`、`network/leave`、`ssh_keys/set` 全中。而且 V8:一個 owner-op 動詞內 gen 可以變兩次(`resolve()` 重建 + 自己的 commit),「等回應後比對 owners / PSK」也不能靠「變化次數 = 1」。L75(join 後立刻斷線)與 `cache_test` 的兩臂都測不到這個(它們不測「join 進行中擁有者**不**被斷」)。
- 證據:V7、V8;設計 §1.3「協定 §3.5 / §5.3 被移除者」列、§4.3 快取段最後一句;`node.go:548, 753-761, 1131-1180`。
- 修(把判定寫成擁有權):
  1. **「預期的 generation 變化」由 `ops` goroutine 擁有**:送出任何改狀態動詞(`claim.verify`、`claim.replay`、`net.apply`、`network.leave`、`ssh_keys.set`、`root_password.reset` 不算)前設 `expectGen=true`;回應處理完(含 `HELPER_WAIT` 到期的「outcome unknown」分支,因為動詞仍在 helper 跑)**且 `ctl` 之後又成功輪過一次**才清。`expectGen` 期間 `ctl` 看到 gen 變 → 只標「待重拉」(既有 stale-while-revalidate),**不撤銷 session**;清掉後的第一次比對用新 `info.owners` / PSK 集合逐 session 做(設計已有),這一步同時涵蓋被 `expectGen` 遮住的旁路變化(root `provclient` 在 `n.mu` 下本來就排不進自家動詞中間,只有 `resolve()` 重建這一種,它不改 owners 集合以外的東西時比對自然通過)。
  2. `HELPER_WAIT` 到期分支:動詞仍在 helper 跑,gen 之後才變 → `expectGen` 要撐到 `ctl` 看到 gen 變、或 1 + 960 s 上限,寫明。
  3. `cache_test` 加臂:自家 `net.apply` 進行中 gen +1 → 擁有者 session **不**斷、回應後比對仍是擁有者 → 不斷(負對照:拿掉 `expectGen` → 斷);`prov-netjoin-254` 正向臂斷言 join 回應前 02 的 session 沒收到 Disconnect(log 無 `session revoked`)。
  4. §3 快取列、§1.3 該列、§4.3 快取段三處同步寫這條;log 契約加 `provd: session revoked reason=<generation|owner-removed|psk-rotated>`(H3 讀)。

## 4. MINOR

**m1. 臂 2 的 `btmgmt add-adv -d <31 B> 1` 會就地覆寫 provd 的 instance 1(V10),測完 provd 的廣播資料是 harness 的 31 B、BlueZ 不知道;副作用清單沒列。**
- 證據:`hci_core.c` `hci_add_adv_instance`(同號 → `memset` + 改寫,不拒);BlueZ 從 1 開始配 instance(`advertising.c`,前幾輪已核);設計 §4.8「`btmgmt add-adv -d <31 B> 1`」。
- 修:臂 2 用 provd 不會拿到的號碼(`SupportedInstances` = 5 → 用 5),或在 BLE lease 下先停 provd 再做、測完 `rm-adv` + restart provd;副作用清單加「覆寫 / 新增 instance、`rm-adv` 還原、provd log `foreign instance count` 是預期」;前後 `advinfo` 一起 log(2026-10-18 規則)。

**m2. helper 重啟 = `boot.Run` 重跑(V9),overlay 可能被重寫成 gen 1 新 record 或由 p5 重建;設計 L11 只寫「快取失效」沒說為什麼,且失效鍵只看 `Generation`。**
- 情境:gen 1 的 Legacy record 被 `boot.Run` 換成 gen 1 的 Unclaimed(`boot.go:179-211` 四處都寫 `Generation: 1`,state 不同)→ `Generation` 不變、`state` 變;今天兩者都是 NX 模式、PSK 都空,所以無害,但「只看 gen」這個契約留了洞給之後的 state。
- 修:失效鍵改成 `(state, Generation)` 二元組(`info.state` 本來就回兩個);L11 加「helper 重啟會重跑 `boot.Run`(`main.go:585`),record 可能被改寫;`ops` 重連 + 二元組失效涵蓋」。

**m3. L80 臂 (1)「kill provd → ≤ 10 s 02 `Connected=false`」預算太緊。**
- 情境:procd `respawn 3600 5 0` = 死後 5 s 才重啟;新 provd 連 bus、等 `Adapter1`、`GetManagedObjects`、`Device1.Disconnect` → BlueZ 2 s `DISCONNECT_TIMER` 才送 mgmt(F-P50)→ 常態 ≈ 8–9 s,抖一下就 FAIL 且會被歸因成產品 bug。
- 修:斷言改 ≤ 15 s(或用 `/etc/init.d/batman-provd restart` 不走 respawn 延遲、斷言 ≤ 10 s),寫明算法。

**m4. 閘門的「prov_test」與「`/rom`」來源要寫實際的檔與工具。**
- `bt-uart-305.sh:18` 讀 `/etc/batman-build`(可寫層),設計說「與 #305 同一套」但自己要 `/rom`;H3 的 254 單位不能重用 `bt305_fw`,要自己 `sed /rom/etc/batman-build`。prov_test 偵測 = helper `--version` 第 2 行(V2)。兩處各補一句。

**m5. §4.8 的 `DIRTY=0` 理由「dirty build 可能本地拿掉 patch」要對回 `build-board.sh:85-95`。**
- base tree 有修改時 build 本來就被拒,除非 `BATMAN_ALLOW_DIRTY_BASE=1`;閘門真正要排除的是這個 override 被用過的 build(M1 修法 3 的 `BATMAN_DIRTY_WHY` 剛好能看出:override 下 `why` 會含 `tracked-changes` / `untracked:`)。§4.8 的文字照這個寫,§6 加 `build-board.sh:85-95` 當證據。

**m6. 文字**:第 3 行「狀態:v4」應為 v5;§4.8 同一段落把「A3 M3:這個動作在未 patch 的 kernel 上 = F-P10 的 panic;副作用清單…」重複貼了兩次;§9 把 `prov-sec-adv-len-254` 臂 2 前置閘與 `prov-respawn-254` 兩臂各列了兩次。

## 5. 其餘抽查(沒有新發現,列出讓第 6 輪不用重核)

- 擁有權表 §3:每個資源一個寫者成立;kernel 作為廣播 instance 第二寫者、root 手動第三寫者都寫明;M1 的閘門資料(`BATMAN_DIRTY_WHY`)寫者 = stamp 腳本,讀者 = harness,trust boundary = `/rom`(squashfs)— 補進表就齊。
- 契約 §4.3 錯誤碼表與 `node.go:30-48` 一致;`info.owners` 與 `owner_key_id = sha256(pub)` 一致(V11);`psks.get` 仍持鎖、1/s 額度與 `psks(rec)` 需要 record 一致。
- 生命週期:L1–L81 加上 M2 的「自家動詞進行中」這一列就齊;L13 bcm2710 的理由(F-P49)對。
- 安全 §8:被攻陷 provd 的面沒變;M1 不是新攻擊面(harness 是 root 操作員),是「我們自己」這個 actor 的 fail-closed。
- 04 連線:WSL 端 ssh 不通、Windows 端通(V4)— 與記憶「節點測試走 Git Bash、ab-card 走 WSL」一致,不是設計問題;寫進 H3 單位的執行環境備註即可。

## 6. 結論

- **BLOCKER 0 / MAJOR 2 / MINOR 6**。
- **判定:APPROVE-WITH-CHANGES**。M1 是「閘門不可能成立」+「主機端缺機制」,修法全部用既有寫者(stamp 腳本、git 樹、helper `--version`),不需要新的自我宣稱 marker;M2 是契約缺一條擁有權規則(「預期的 gen 變化」歸 `ops`),加上一個負對照單元。兩個都關了再出 v6,整份重審一次(規則:MAJOR 開著就不進實作)。
