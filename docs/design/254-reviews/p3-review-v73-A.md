# 254-p3-impl v7.3(1a88a8c)審查 A — S5 軟體更新(整份重審)

審查者 A(正確性優先)。2026-11-11。只讀:`/home/yello/Batman-p3`@1a88a8c、`/home/yello/firmware-2710`;沒有改任何 repo、沒有 ssh 到節點。
範圍:§3.7、§3.8、§3.11、§12 全部(含 §12.5)、附錄 E,以及它們依賴的 §4 / §5 / §6 / §7 / §8 / 附錄 D 列。

**判定:APPROVE-WITH-CHANGES — 0 BLOCKER / 2 MAJOR / 17 MINOR。**
兩個 MAJOR 都是 **v7.3 的修正本身帶進來的新洞**:(1) `bootinfo` 讓 helper 每 15 s 拿兩次 `batman-slot.lock`,而 `slot_lock` 拿不到就立刻失敗 → helper 自己的 `write` / `arm` 與所有現場的 `batman-slot apply/commit/rollback` 會隨機 rc 14;(2) `update.check` 依 manifest sha 快取 precheck 結果 → 暫時性的拒絕(`.txn`、p5 stale、E_BUSY)對同一份 manifest 永遠重播,app 無路可走。兩個都只要改文字 / 小規則,不需要新機制。依規則改完要整份再審。

---

## 0. 我自己核對過的事實

| 項目 | 結果 | 證據 |
|---|---|---|
| `slot_lock` 拿不到鎖就**立刻** die(不等),持有者判活 = pid 活 + cmdline 含 `batman-slot` | ✅ | `batman-slot:84-96` |
| `commit` / `rollback` / `stage-root` / `apply` 都先 `slot_lock` | ✅ | `:651`、`:660`、`:754`、`:841` |
| helper health tick 每 15 s,已 commit 且 Powered ≥ 600 s 時**每個 tick** 呼叫 `ConfigOK()`(讀 `/boot` + 掛 p3),寫過 ble-ok 之後也照樣呼叫 | ✅ | `health/health.go:210-247`(`:223` 條件每 tick 重算);`main.go:613-619`、`:695-733` |
| `.busy` 由 `precheck` 在 `node_checks` **之後**建立、EXIT trap 刪;`otaBusy` 只 `Lstat` | ✅ | `batman-slot:155-157`、`:594-595`;`node/wtxn.go:450-454` |
| autocommit revert watchdog 在 `.busy` 存在或鎖持有者活著時延後(≤ 600 s);commit 失敗 → `ok=0` 重來 | ✅ | `batman-autocommit:86`、`:220-232`、`:553-557` |
| `provstore.Exec`:stdin `[]byte`、pgid、TERM → 10 s → KILL → 再 10 s 放棄(unkillable 回 124) | ✅ | `provstore/exec.go:19-65`;`run()` 預設 60 s `main.go:81-91` |
| `flynn/noise` v1.1.0 `Decrypt` 失敗不推進 nonce | ✅ | `vendor/github.com/flynn/noise/state.go:69-80`;`go.mod:6` |
| SO_MARK 需要 CAP_NET_RAW 或 CAP_NET_ADMIN(kernel 6.6.138) | ✅ | firmware `build_dir/.../linux-6.6.138/net/core/sock.c:1388-1395` |
| 兩板實際 payload 的 SUMS 每一列都符合 §12.5.4 正規式,也都在類別白名單內;tar 成員數 = SUMS 列數 + 4(**剛好等於上限**) | ✅ | bcm2711 361 列 / 365 成員;bcm2710 364 / 368(本次 `tar -tzvf` + grep,0 列不符) |
| SUMS 由 build 端列 `root.squashfs` + 所有 `boot/` 檔;不含 `metadata` / config | ✅ | `build-ab-payload.sh:69-73` |
| 既有呼叫者只看 rc ≠ 0:`platform-ab.sh:184`、`:364-366`、`:377-379`;`daily-validation.sh:2068`(`^rc=[1-9]`) | ✅ | 同左 |
| 版本字串**永遠**是 `REL-CH.N+feed.fwX[.dirty][.wbox-X]`,沒有「無後綴的正式版」產生路徑;N 是「該 channel 內第 N 個 build」 | ✅ | firmware `scripts/stamp-batman-build.sh:23`、`:57`;`docs/VERSIONS.md` channel / build 說明 |
| harness 在鎖外掛 boot 分割(含一個 **rw** 掛 p3) | ✅ | `scripts/ab-selftest.sh:73`、`:75`;`scripts/dv/eh13-pre-254.sh:55`、`:62`;`scripts/dv/prov-chain0-254.sh:22` |
| fw-override 有兩個來源:`$RUNDIR/batman-fw-override`(`batman-slot:539`)與 DT 比對(`assert_fw_sane` `:248-249`);§12.5.2 引的 `:556-578` 其實是 p5 seed 檢查 | ✅ | 同左 |
| §12.3 04 唯讀實測、F75/F76 / §9-4 AP client 通過與 VLAN 臂 | ⚠️ NEEDS-NODE | 本次不能上機 |

---

## 1. 上一輪(A8)逐條:真的修了嗎

| A8 | v7.3 | 判定 |
|---|---|---|
| MAJOR-1 status 不綁嘗試 | §12.5.5 key 4/5、prepare 起寫 update-last、有序表、22/23 | ✅ 原情境(v2 → v3 寫入中斷 → 不再報 5)已解;**有序表本身有 4 個新的誤報路徑** → m1–m4 |
| MAJOR-2 結束碼 | §12.5.2 node_checks 層、16–18、reason 21 | ✅;剩少數 die 沒歸類 → m12 |
| m1 tboot_open 重用 | §12.5.1 單一掛載者 `bootinfo` | ✅ 掛載衝突解了,**但把 helper 變成高頻持鎖者** → **MAJOR-1**;harness 掛載者沒列 → m9 |
| m2 `.busy` | §12.5.3 帶 pid、EXIT 卸載、清死掛載 | ✅;ramfs 階段的殘留掛載待實測 → m16 |
| m3 6+18 界線 | §12.5.5 改寫 | ✅ 文字對了;同版本重試 / 已 commit 後回退仍誤報 → m4 |
| m4 兩位擁有者 | §12.5.6 | ✅;apply 中移除擁有者沒寫 → m13 |
| m5 上傳語意 | §12.5.7 | ⚠️ 部分:pending 到期與窗關後 PUT 沒定 → m5、m6 |
| m6 串流 stdin | §12.5.8 | ✅(負對照缺 → m15) |
| m7 版本規則 | §12.5.9 | ⚠️ 表與真實版本字串對不上 → m8 |
| m8 信任 T / gate | §12.5.10 | ✅ 方向對;gate 在哪跑、誰放 pub 檔沒寫 → m14 |
| m9 已寫未啟用 | §12.5.13 | ✅ |
| m10 同時 sysupgrade | §12.5.14 | ✅ |
| m11 test init | §12.5.12 | ✅ |
| m12 update-last format | §12.5.5 key 0 | ✅;寫入原子性 / 多 goroutine → m7 |
| m13 負對照 | §12.5.16 | ⚠️ 新決定(12.5.7/8/13/14/15)缺 → m15 |
| m14 disarm 拿鎖、dir 內容、p6 滿 | §12.5.15 | ✅ |

---

## 2. MAJOR

### MAJOR-1 `bootinfo` 讓 helper 成為高頻持鎖者,`slot_lock` 又不等 → helper 自己的寫入與所有現場 `batman-slot` 寫入隨機 rc 14

**情境**:已 commit 的節點(常態)。§12.5.1 把 `bootConfigOK` 改成呼叫 `batman-slot bootinfo`(A、B 兩槽),而 `bootinfo` 要拿 `batman-slot.lock`。`ConfigOK()` 在已 commit + Powered ≥ 600 s 時**每 15 s tick 都跑**(`health.go:223`,寫過 ble-ok 後也一樣)→ helper 每 15 s 持鎖兩次(每次一個 busybox sh 啟動 + vfat 掛載 + 兩次 sha256 + 卸載,估 50–300 ms,⚠️ 時間未實測)。`slot_lock` 看到持有者活著且 cmdline 含 `batman-slot` 就**立刻 die**(`batman-slot:84-96`),不等。

撞到的人:
1. **helper 自己的 worker**:`batman-slot write` 第一步 `slot_lock` → rc 14。§12.5.1 同時**拿掉了** §12.2-1 (a)「helper 在自己的 worker / apply 進行中不跑 p3 掛載」。worker 是非同步的,rc 14 對它沒有定義的 reason(§12.5.2 只把 14 對應到線上 `E_BUSY`)→ status 會是 phase 0 + ?,上傳檔在 worker 結束時被刪 → 擁有者**白傳 126 MB**。
2. `update.apply` 的 `arm` → `E_BUSY`(app 可重試,較輕)。
3. `update.check` 自己的 `bootinfo` 與 tick 的 `bootinfo` 互撞 → `E_BUSY`。
4. 現場其他 `batman-slot` 寫入者:操作員的 `commit` / `rollback`、`ab-selftest`、`eh13-pre-254`(`apply` / `stage-root`)、daily-validation → 新的隨機失敗(以前 helper 不拿這把鎖)。sysupgrade stage 2 不受影響(那時 helper 已被殺)。
5. trial 中 helper 啟動時的 `bootinfo` 與 autocommit `commit` 互撞機率低(trial 中 `Committed()` 為假,tick 不跑),而且 commit 失敗會重試,只是 dwell 重來。

**後果**:每次 app 更新約 1–4%(⚠️ 推估,待實測)機率在上傳完後失敗;既有的 OTA / 測試路徑多出不可重現的 rc 14。這是 v7.3 修正新加的共享資源競爭,§12.5.16 沒有負對照會抓到它。

**修法(擇一或合用,都很小)**:
1. helper 內所有 `batman-slot` 呼叫走**同一個 mutex**;health tick 在 worker / apply / check 進行中**跳過** `bootinfo`、沿用上次結果(把 §12.2-1 (a) 放回來)。
2. `bootConfigOK` 不必每 15 s 重讀:boot 設定只會被 `batman-slot write/apply` 或操作員改 → 每次開機讀一次、每次 `write` / `arm` 後重讀,或至少降到每 10 分鐘一次。
3. 寫入者的 `slot_lock`:持有者是唯讀的 `bootinfo` 時**等它**(例如 ≤ 10 s),不立刻 die。
4. 測試 + 負對照:接縫讓 tick 的 `bootinfo` 持鎖 2 s,同時跑 worker `write` 50 次 → 0 次 rc 14;拿掉修法 → 出現 rc 14(FAIL)。

### MAJOR-2 `update.check` 依 manifest sha 快取 precheck 結果 → 暫時性拒絕對同一份 manifest 永遠重播

**情境**:§12.5.10 末段(B8-m9):「`update.check` 只在 manifest 的 sha 與上一次不同時才跑 `bootinfo` / `precheck-node`,相同就用快取的結果」。擁有者第一次 check 拿到:reason 12(`.txn` 未完成)、17(p5 stale)、2(p5 未 seed)、1(試用中)、21(fw-override)、或 `E_BUSY`(鎖被佔;再加上 MAJOR-1 會更常見)。他照 app 的提示等網路變更完成 / 入網 / 等 commit,再按一次「檢查更新」——**同一份 manifest** → 快取 → 同樣的拒絕,直到 helper 重啟或節點重開(app 沒有重開動詞)。§3.11-10 的「重讀」也救不了。反過來,快取的**通過**會讓節點狀態已變(例如之後出現 `.txn`)時仍寫 pending、開窗、讓擁有者上傳完,才在 worker 的 `node_checks` 失敗 → 又白傳一次。

**證據**:§12.5.10 末段;拒絕的來源都是會隨時間改變的節點狀態(`batman-slot:537-589` 的 node_checks、`p5_freshness_gate :483-535`)。

**修法**:拿掉這個快取(B8-m9 的搶鎖風險已由 helper 的全域 1 / 10 s 額度封頂:`bootinfo` 約 0.1 s / 10 s ≈ 1% 佔用);若一定要快取,只快取**簽章驗證**(與節點狀態無關),`precheck-node` / `bootinfo` 每次都跑,或快取 ≤ 10 s。負對照:check → 12;完成 `.txn`;同一份 manifest 再 check → 通過;有快取的版本仍回 12(FAIL)。

---

## 3. MINOR

**m1 有序表第 11 / 12 列用 `written` 旗標,不是目標槽的實況 → 三種誤報。**
(a) worker 在 `begin_write` 之前就失敗(簽章 / tar 拒絕、`write` 的 precheck rc 10/11/12/14、prepare 寫完 update-last 後 helper 掛了、§12.5.6 在寫入開始前移除擁有者):重開後 `written: false` → 第 11 列 **0 + 22「退路已失效」**,其實目標槽完全沒動。
(b) worker 成功、helper 在寫 `written: true` 之前掛掉:pending 到期 / 重開後 → 22,其實槽已寫好、可用(應為 23)。
(c) arm 成功、`armed: true` 已寫、`rebooting: true` 之前斷電:第 12 列要求 `armed` 為 false → 落到第 13 列 **0「沒有更新」**,其實是「已寫入、未啟用」。
**修法**:`bootinfo` 多印一行 `bad=0|1`(`BATMAN-BAD` 在不在);第 11 列改成「目標槽 BAD」、第 12 列改成「目標槽 `verified` = sha 且 `rebooting` 為 false」;`written` 可以拿掉(少一個 update-last 欄位、少一次 p6 寫入)。表測各加一案。

**m2 第 3 列(helper 記憶體裡的失敗)沒有綁定嘗試。** 同一個 helper 生命週期內:第一次 worker 失敗 → 擁有者重來(check、bulk.open、上傳、prepare)且成功 → 第 3 列排在第 4 列之前 → 一直報 0 + 舊 reason;§3.7.4 `update.apply` 要求 phase 3 → reason 15 → 卡到 helper 重啟。**修法**:記憶體結果帶 sha / 嘗試序號,`update.prepare` 時清掉;第 3 列只在 sha = 目前 pending 的 sha 時成立。

**m3 第 6 列「boot_id = apply_boot_id → disarm,報 3」。** (i) `update.status` 是 ro、只讀快取,disarm 只能是 helper **啟動時**的動作,表裡要寫清楚,否則 apply 後那 2 s(加 procd 關機最多 240 s)裡 app 一輪詢就 disarm、重開落回舊槽、報 6 + 18。(ii) 會走到第 6 列時第 4 列已不成立(pending 無效),此時報 3 但 `update.apply` 會回 15 → 狀態與動詞矛盾,應報 0 + 23。

**m4 第 9 / 10 列沒有納入 autocommit.log。** (i) 同一版本先前已被退回過、這次又退回:`bad-slot` 內容與 `bad_slot_at_apply` 相同 → 落到第 10 列 6 + 18(D-10 已寫要比對 TRIAL-REVERTED,但「寫死」的表沒有它)。(ii) 已更新到 v2 並 **commit**,之後操作員 rollback / #133 fallback 回 from_slot:`bad-slot` 在 commit 時被刪(`batman-autocommit:554`)→ 第 10 列 6 + 18「新版沒有完成試用」—— 錯,它完成並 commit 過。**修法**:第 9 / 10 列先看 apply 之後的 aclog(autocommit 是唯一寫者,helper 唯讀):有 `COMMITTED slot=to_slot version=to_version` → 0;有 `TRIAL-REVERTED slot=to_slot` → 6;都沒有 → 6 + 18。

**m5 pending 到期與上傳。** `bulk.open` 不延長 pending(只有 prepare 延長);§3.7.4 說上傳窗開著時 `update.check` → `E_BUSY`,與 §12.5.6「同一位擁有者 → 覆寫」矛盾;§12.5.7 的 409 規則只看窗。劇本:check → 擁有者照 §3.11-1 去系統設定輸入 20 字密碼、找訊號花了 22 分鐘 → bulk.open → 上傳 8 分鐘 → prepare 15(pending 已到期)→ 而窗開著時又不能重 check。**修法**:`bulk.open` 把 pending 到期延到窗到期 + 5 分;409 也在「pending 會在上傳完成前到期」時回;§3.7.4 / §12.5.6 的 E_BUSY 規則二擇一寫清楚。

**m6 窗關之後的 PUT。** 沒寫「prepare 關窗後 PUT → 409」。誠實的 app 若重送 PUT(例如沒收到 200),provd 以 `O_TRUNC` 開**同一個路徑** → 截斷 worker 正在讀的同一個 inode(worker 結束才刪)→ worker 讀短 → reason 11,擁有者再傳一次。fail-closed 但會白傳。**修法**:PUT 只在窗開著時收(否則 409);另外 worker 在 fstat 驗完後立刻 `unlinkat` 上傳檔(helper 本來就是唯一刪除者),之後 provd 的 `O_CREAT` 只會建新 inode。

**m7 update-last 的「同一個 goroutine 依序寫」不成立。** 寫者是 prepare handler、worker goroutine、apply handler、`reboot committed` 失敗路徑、owner/remove 取消——是不同 goroutine。要寫明一個 mutex,以及 temp + fsync + rename(p6 上斷電時「壞 → 當作沒有」是 fail-safe,但會讓 22 / 23 退化成 0)。

**m8 版本規則表與真實版本字串對不上。** stamp 一律產生 `REL-CH.N+…`(`stamp-batman-build.sh:57`),「無後綴的正式版 N = ∞」沒有產生路徑;N 是**每個 channel 自己數**(VERSIONS.md)→「CH 不參與比較」會讓 `1.6.0-rel.3` < `1.6.0-wsl.25`。PROD 節點只信任 R,所以眼前不會出事;但表要對得上:定義 `rel` 怎麼排(或改 stamp 讓 rel 不帶後綴),並把「跨 channel 同 REL」的表測改成真實字串。

**m9 boot 分割「唯一掛載者 = batman-slot」不成立:harness 還在鎖外掛。** `ab-selftest.sh:73`(ro)、`:75`(**rw** 掛 p3 並寫入)、`eh13-pre-254.sh:55,62`、`prov-chain0-254.sh:22`。現在它們與 helper 的 `bootinfo` 互撞(vfat 同一裝置 rw / ro 並掛會 EBUSY),結果是測試或 bootConfigOK 隨機失敗。列進 §4,並照 #290 走 harness PR 改成在鎖內(或改用 `bootinfo`)。

**m10 `bootinfo` 的輸出契約不完整。** 缺:`config.txt` / `distroconfig.txt` 不存在時印什麼、`distroconfig.txt` > 64 KiB、`verified=` 不是 64 hex、讀取端遇到這些時的行為(建議:ConfigOK 為 false、key 8 → reason 21、VERIFIED 當作沒有)。加 `bad=`(m1)。掛載點命名必須是 `/mnt/slotboot.<pid>`,§12.5.3-3 的清理才清得到。

**m11 被 §12.5 取代的舊文字仍在主文,彼此矛盾。** §4 清理表「update-last 下一次 `update.apply` 覆寫」;§4 目標槽列與 §5.1 仍寫 `bootcfg-sum`;§3.7.5-6 期限寫 `bootcfg-sum 30 s`;§10 檔案清單 `bootcfg-sum`;§3.7.5 步驟 4 的正規式允許開頭 `.`(§12.5.4 不允許);§3.7.4 的「上傳窗開著 → E_BUSY」vs §12.5.6。凍結前把 §12.5 併回主文,實作者只看一份。

**m12 結束碼表沒涵蓋的 die。** `p5_freshness_gate` 的 cfgsave lock-busy(`:506`,暫時性,應為 14)與 `error:mount`(`:510-514`)、`target root is mounted`(`:585`)、`[tryboot]` 指向錯(`:588`,應為 18)、`need_rundir`(`:65`)。fw-override 兩個來源(`:539` 與 `:248-249`)都要是 17。§12.5.2 引的 `:556-578` 是 seed 檢查,行號要改。

**m13 `update.apply` 進行中 `owner/remove`。** §12.5.6 只取消 worker。apply 已過 sha 檢查、正在 arm 或在重開前 2 s 時移除擁有者 → 重開照樣進試用。擁有者在 apply 時已同意,可接受;但要寫明「apply 之後不取消」,並列進 §6。

**m14 release gate 與 `release-root.pub` 的寫者沒定。** `BATMAN_CHANNEL` 在 firmware 的 `batman-release.env`,feed 套件看不到 → 誰決定 image 裡放 T 還是 R?`scripts/release-root.fpr` 的 gate 在哪一步跑(`build-board.sh`?CI?release workflow)?`ci` 通道的 build 是否因此一律 FAIL gate(R 產生前)?§4 的「build(image 內)」要具體到檔案與步驟。

**m15 §12.5.16 缺的負對照。** §12.5.7(窗剩餘時間 409、`O_TRUNC` 重傳)、§12.5.8(`ExecReader`:worker 期間 helper RSS 不隨 payload 大小成長;拿掉 → 長 ~111 MiB)、§12.5.13(已寫未啟用 → 23)、§12.5.14(stage 1 拒絕;拿掉 `.busy` pid 檢查 → stage 1 通過)、§12.5.15(啟動時 disarm 拿鎖;孤兒 write 在跑時不被打斷)、MAJOR-1 / MAJOR-2 的修法。

**m16 ⚠️ NEEDS-NODE:sysupgrade `-F` 在 app 寫入中強制時,stage 2 會不會被殘留掛載擋下。** stage 2 殺掉 `batman-slot write`(或 `bootinfo`)時它可能正掛著 `/mnt/slotboot.<pid>`;§12.5.1 改成「目標分割在別處被掛著 → rc 14」,而 §12.5.3-3 只清 `/mnt/slotboot.<pid>` 這個路徑。ramfs pivot 之後這個掛載的路徑會變(或被 lazy 卸載後仍佔住 superblock)。若清不到 → `-F` 的 stage 2 rc 14 → 靜默重開回舊槽。以 `write-hang` + `sysupgrade -F` 實測一次;不成立時清理改成「`/proc/mounts` 裡 `$TBOOT` 的任何掛載,持有 pid 已死 → 卸載」。

**m17(附在 m1 的同一修法裡,另列因為它跨降級路徑)舊的 `BATMAN-VERIFIED` 可以比內容活得久。** P3 之前的 `batman-slot`(降級後在跑的舊 image)的 `begin_write` 不刪 `BATMAN-VERIFIED`。經 ssh 來回降 / 升級後,目標槽可能留著某份 sha 的 VERIFIED,而內容已是別的 image。擁有者之後 check 同一份 sha → 第 4 列「pending 有效且 verified = sha → 3」(§3.7.4「helper 重啟後也能重建」)→ app 直接 apply(不上傳)→ `arm` 只比 VERIFIED → 試用的是別的 image。重開後第 5 列版本比對會報 0,所以不會被當成功,但「arm 只開擁有者同意的內容」這條保證破了。**修法**:VERIFIED 內容 = `sha boot_id`(寫入那次開機);第 4 列與 `arm` 都要求 boot_id = 本次開機(pending 本來就綁 boot_id)。§6「降級到沒有 P3 的版本」列加一句。


---

## 4. 擁有權逐項(一個寫者?)

| 資源 | 寫者 | 判定 |
|---|---|---|
| 目標槽 rootfs / boot / BAD / VERIFIED、tryboot 旗標 | `batman-slot`(鎖) | ✅ 寫者唯一;**掛載者**還有 harness(m9);P3 前的 `batman-slot` 不刪 VERIFIED(m17) |
| `batman-slot.lock` | `batman-slot` | ✅;**新的高頻持有者 = helper 的 `bootinfo`** → MAJOR-1 |
| `batman-slot.busy`(帶 pid) | `batman-slot`(precheck 建、EXIT 刪;死持有者由下一個 `batman-slot` 清) | ✅ 讀者不刪,單一寫者成立 |
| pending | helper | ✅(owner_key_id 已加) |
| update-last | helper 更新序列 | ⚠️ 名義上一個角色、實際多個 goroutine → m7 |
| helper 記憶體的失敗結果 | helper worker | ⚠️ 未綁嘗試 → m2 |
| 上傳檔 | provd 寫、helper 刪 | ✅ 刻意的多方;窗關後 PUT → m6 |
| `release-root.pub` / `release-min-serial` / `release-root.fpr` | build | ⚠️ 哪個步驟、哪個檔案 → m14 |
| `bad-slot`、`autocommit.log` | autocommit | ✅ helper 只讀(m4 建議多讀 aclog) |
| nft 表 / bit 24 | fw4 | ✅ |

## 5. 生命週期 / 現場劇本

| 劇本 | 結果 |
|---|---|
| 正常:手機 Wi-Fi 更新 | 流程成立;~1–4% 機率 worker rc 14 → **MAJOR-1**;AP client 通過 ⚠️ D22 |
| 上傳中斷 / 手機斷 Wi-Fi | prepare 15 → 從頭 PUT ✅;pending 到期 → m5;窗關後重送 PUT → m6 |
| 寫入 / arm / 重開 / 試用中斷電 | 槽都 fail-closed ✅;狀態:寫入前失敗誤報 22、arm 後誤報 0 → m1 |
| 新版不健康 | 退回 ✅;同版本重試、已 commit 後回退的誤報 → m4 |
| 兩位擁有者 | ✅(§12.5.6) |
| 擁有者在更新中被移除 | worker 中止 ✅;apply 中未定 → m13 |
| 成員 | 動詞只給擁有者 ✅ |
| 降級 | key 6 ✅;到 P3 之前的版本後的 VERIFIED 殘留 → m17 |
| 同版本重裝 | 允許(§12.5.9)✅;狀態列靠槽區分 ✅ |
| helper 每一步 crash | 槽 fail-closed ✅;prepare 後 / worker 成功後掛 → m1(a)(b);同一生命週期內重試 → m2 |
| provd crash 上傳中 | 重新交握、O_TRUNC 重傳 ✅ |
| 同時 ssh sysupgrade | stage 1 rc 14 ✅;`-F` stage 2 殘留掛載 ⚠️ m16 |
| 預檢被拒後重試 | **同一份 manifest 永遠被拒 → MAJOR-2** |
| bcm2711(Pi 4) | 全部實測(待上機) |
| bcm2710(Pi 3) | 使用者決定只編譯(2026-10-23 CM4 量產、Pi 3 暫不支援);`batman-slot` 改動走共用 sysupgrade 路徑 → CI ab-card(pi3)要跑(§12.5.15 已寫)✅;firmware 樹的 bcm2710 payload 是 2026-10-27 的舊版,SUMS 名字仍符合新正規式 ✅ |

## 6. 判定

**APPROVE-WITH-CHANGES。** 沒有 BLOCKER:我追過的失敗路徑最後都停在「舊槽可用、目標槽 BAD 或未 arm」。兩個 MAJOR 是 v7.3 修正自己帶進來的:`bootinfo` 讓 helper 高頻持鎖,而鎖不等待(MAJOR-1);check 的快取讓暫時性拒絕無法解除(MAJOR-2)。兩個都只要改幾句規則(helper 內 mutex + tick 不在寫入中探測 / 降頻;拿掉 check 快取)。MINOR 大多是 §12.5.5 有序表的邊角(m1–m4,其中 m1 / m17 一個 `bootinfo` 的小改就能一起收),以及 §12.5 併回主文(m11)。依使用者規則,MAJOR 改完後整份再審。
