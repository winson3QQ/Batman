# 254-p3-impl v7.3(1a88a8c)審查 B — 安全優先(S5 整份:§3.7 / §3.8 / §3.11 / §12 含 §12.5 / 附錄 E,及其引用的 §4 / §5 / §6 / §7 / §8 / 附錄 D 各列)

- 審查者:B(安全優先)。方法:只讀。對照 `/home/yello/Batman-p3`(1a88a8c)、`/home/yello/firmware-2710`(兩板實際 payload、kernel 6.6 標頭)、`~/go/pkg/mod/github.com/flynn/noise@v1.1.0`。沒改任何 repo、沒連節點。
- **結論:APPROVE-WITH-CHANGES。0 BLOCKER、0 MAJOR、14 MINOR。** v7.2 的 B8 兩個 MAJOR 都已關閉;v7.3 新機制本身沒有找到會讓節點被越權控制或退路被默默破壞的洞,剩下的是 DoS 界線、規格縫隙與測試缺口。

---

## 0. 自己查證的事實(✅ 附出處)

| # | 事實 | 證據 |
|---|---|---|
| V1 | flynn/noise v1.1.0 `CipherState.Decrypt`:AEAD 失敗直接 return,`s.n++` 只在成功後 → §12.5.11「失敗不推進 nonce」成立 | `noise@v1.1.0/state.go` Decrypt(約 :69-81) |
| V2 | **但 provd 現行 `onMessage`** 在檢查 err **之前**就做 `ss.msgs++` 與 `ss.lastActive = time.Now()`,AEAD 失敗回 error(= 中止 session) | `provd/session.go:314-322` |
| V3 | 協定 §4.2:`X-Batman-Session` 是 `POST /session`(交握時、認證前)回的 128-bit 隨機值,也用來路由 `/msg`;§12.5.11 寫的 bearer 是「`auth/owner` 成功後產生、只對 PUT 有效」— 兩者沒說是不是同一個值、新值怎麼交給 app | `219-protocol.md` §4.2(`awk '/^### 4.2/'` 輸出);設計 §12.5.11 |
| V4 | 現行 `slot_lock` 與 autocommit `pid_is` 的「持有者活著」= `kill -0` + cmdline **子字串** `batman-slot`;沒有 uid、沒有 starttime | `batman-slot:84-95`;`batman-autocommit:79-81,86` |
| V5 | `PID_MAX_DEFAULT` = 0x8000(32768);4 核 arm64 → pid_max 32768,可在數秒內繞一圈 | linux-6.6 `include/linux/threads.h:28` |
| V6 | `provstore.Exec` stdout 與 stderr 合併到同一個 buffer | `provstore/exec.go:24` `c.Stdout, c.Stderr = &out, &out` |
| V7 | `bootConfigOK` 由 `Tick` 每 15 s 呼叫,條件 `poweredFor >= 600 && Committed() && ConfigOK()`,ble-ok 寫好之後仍每次呼叫 → v7.3 起 = 每 15 s 一次 `batman-slot bootinfo`(拿 `batman-slot.lock`) | `health/health.go:222-223`;`cmd/batman-provhelper/main.go:693-733` |
| V8 | autocommit 的 `batman-slot commit` 失敗會重試(不會因撞鎖就退回) | `batman-autocommit:553-556` |
| V9 | 現行 provd 驅逐規則:只有匿名 / 候選 / 重取可被擠掉,**成員 session 不可驅逐**;交握中與 fake path 也不可 | `provd/session.go:152-165`;`server.go:754-783` |
| V10 | **兩板**實際 payload 的 SUMS 都不含 `autoboot.txt` / `config.txt` / `cmdline.txt` / `distroconfig.txt` / `bootcode.bin`:bcm2711(wsl.25 世代,126,309,765 B)361 列 / 35,053 B;bcm2710(2026-10-27)364 列 / 35,337 B;非 overlays 成員只有 kernel8、start*、fixup*、*.dtb → §12.5.4 的明確拒絕不會擋掉兩板的正常 payload(作者只核了 bcm2711) | `tar -xzOf … SHA256SUMS`(firmware-2710 `bin/targets/bcm27xx/*/ab-payload-*.tar.gz`) |
| V11 | 現行 SUMS 產生法 = `find boot -type f`(任何進 build 樹 `boot/` 的檔都會被列) | `scripts/build-ab-payload.sh:71` |
| V12 | `tests/keys/T.pub` 的格式是「一行 hex」(131 B 檔),私鑰可由任何人以 `_vector_key("release-root-T")` 重算 | `tests/keys/README.md` |
| V13 | VERSIONS:channel = `wsl` / `ci` / `rel`;正式版去掉後綴 | `docs/VERSIONS.md:9-15` |
| V14 | autocommit 對 #133 stale fallback(`p_req` 0)**會** commit;只有 `bad-slot` 記過的同版本不 commit → §12.5.13 的界線描述正確。**更正我在 B8-m11 的說法**(我寫「autocommit 不會 commit stale fallback,`:361`」是錯的) | `batman-autocommit:349-369` |
| V15 | Go 1.22 `archive/tar` reader 會把 `TypeRegA` 正規化成 `TypeReg`/`TypeDir`,PAX `x` / GNU `L` 在 `Next()` 內部合併 → 「只收 TypeReg + 兩個 TypeDir」可實作 | GOROOT `archive/tar/reader.go:145` |
| V16 | 產品 init 與 test init 是兩個檔,Makefile 二選一安裝 → §12.5.12「兩個檔都加」正確 | `feed/batman-prov/Makefile:58` |

**⚠️ 沒查的**:F75 / F76 / D-1 / D-2(只能上機);kernel `sock.c` SO_MARK(B8 已查,本輪沒重查);04 的權限 / pid(作者實測)。

---

## 1. B8 發現逐條確認

| B8 | v7.3 處理 | 判定 |
|---|---|---|
| M1 照 SUMS 複製會蓋 `autoboot.txt` | §12.5.4:SUMS ∩ 類別白名單、兩邊明確拒絕、SUMS 每列正規式(首字不可 `.`) | ✅ 關閉。V10 補證兩板都不受影響。殘留:拒絕清單比對大小寫(m12)、§3.7.5-4 舊正規式沒同步(m14) |
| M2 SIGKILL 留下 `.busy` / 掛載 | §12.5.3:`.busy` 帶 pid、EXIT 卸載、清死掉的掛載點 | ✅ 關閉。新機制本身的 pid 重用問題見 m1 |
| m1 公開 T | §12.5.10 + §7 兩列 + §6 出口 + 正向 gate | ✅ 關閉(R_dev 替代方案仍待使用者選;gate 範圍見 m9) |
| m2 SO_MARK | §12.5.11 `iifname != "br-ahwlan"` | ✅ 關閉 |
| m3 8095 搶占 | §12.5.11 `http_bind_failed` + §7 界線 | ✅ 關閉 |
| m4 rc 雜項 → 11 | §12.5.2 reason 21 | ✅ 關閉(§3.7.5-6 舊文字未同步,m14) |
| m5 bearer 規格 | §12.5.11 | ⚠️ 大致關閉;與協定 §4.2 的 `X-Batman-Session` 關係沒寫、空 body 取塊未認證(m4、m5) |
| m6 tmpfs inode / unlinkat / 兩個 init | §12.5.12 | ✅ 關閉 |
| m7 tar 邊角 | §12.5.12 | ✅ 關閉(V15) |
| m8 移除擁有者不中止 worker | §12.5.6 | ✅ 關閉;殘留「已寫入未啟用」的槽見 m8 |
| m9 DEV 上 check 搶鎖 | §12.5.10 sha 快取 + 1/10 s | ✅ 關閉(界線在 §7) |
| m10 鑰匙檔 / 實體奪取 | §12.5.10 reason 21、§7 列 | ✅ 關閉;格式定義衝突見 m14 |
| m11 已寫未啟用 | §12.5.13 | ✅ 關閉;並更正我 B8 的錯(V14) |
| m12 負測試 | §12.5.16 | ⚠️ 大部分關閉;仍缺的見 m13 |

---

## 2. 行為者總覽(整份 S5 重看)

| 行為者 | 新輸入 | 擋法 | 判定 |
|---|---|---|---|
| mesh 遠端 | 8095 | bridge 標記 + inet `iifname` + mark | ✅;⚠️ AP 正向與 VLAN 臂仍待 §9-4 |
| 手機 AP 上的裝置(知 AP 密碼) | 8095、明文 session id / bearer、空 body 取塊、PUT | Noise、owner-op 綁 sha、簽章 + 讀回 | 完整性 ✅;DoS 界線比 §7 寫的大(m4、m5、m6、m10) |
| 本機非特權 / docker tenant / host-network 容器 | lo、SO_MARK、搶 8095、**偽造 `batman-slot` cmdline 佔 pid** | iifname、bind 失敗回報 | m1 |
| 被入侵的 provd(471) | 上傳檔、PUT 時機、`update.check` | 白名單 tar、fd + fstat、讀回 | 完整性 ✅;PUT 截斷 worker 正在讀的 inode(m6) |
| 被移除的擁有者 | 已寫入的槽 | 清 pending / 窗 / worker | m8 |
| 成員 | HTTP session(不可驅逐) | 角色 | m10 |
| 實體奪取 | `release-root.pub` | 無 secure boot | 誠實界線 ✅ |
| 供應鏈 / 我們自己的錯 | 公開 T、release-sign、gate、fpr 檔 | 正向 gate | m9 |

---

## 3. Findings

沒有 BLOCKER、沒有 MAJOR。

### MINOR

**m1. `.busy` / lock 的「持有者活著」可被本機非特權行程以 pid 重用 + 假 cmdline 冒充(§12.5.3)**

- **情境**:
  1. §12.5.3 把 SIGKILL 變成**預期路徑**:helper 期限到就 TERM → 10 s → KILL,`.busy` 與 `batman-slot.lock` 留著,判斷改靠「pid 活著且 cmdline 含 `batman-slot`」(V4)。
  2. pid_max 32768(V5)。本機非特權行程(或 docker tenant,同一 pid ns 時)可以快速 fork 到那個 pid,並讓 cmdline 含 `batman-slot`(`exec -a batman-slot sleep 1e9`,或執行任何叫 `batman-slot` 的檔)。
  3. 結果:`otaBusy` 一直是忙 → `settings.set`、`network/*`、`update.*` 回 `E_BUSY` 直到冒充者結束或重開;`slot_lock` 拒絕所有寫入 / commit / rollback(autocommit 的 commit 會一直重試失敗,V8)。只是 DoS,但影響的是唯一的管理通道與退路操作。
  - 前提要先有一次 SIGKILL(期限到),本機重 I/O(例如 tenant 打滿 SD 卡)可以把 600 s 期限推到。
- **證據**:V4、V5;§12.5.3-1「用與 `slot_lock` 相同的規則」。
- **修法**:`.busy` 與 lock 的 `pid` 檔改記 `<pid> <starttime>`(`/proc/<pid>/stat` 第 22 欄),讀者要求三者都成立:starttime 相同、`/proc/<pid>` 的 uid = 0、cmdline 的 **argv[1]** 正好是 `/usr/sbin/batman-slot`(不是子字串)。shell 與 Go 兩邊共用同一規則;§12.5.3-3 清死掉的 `/mnt/slotboot.<pid>` 也用同一規則(否則冒充者讓殘留掛載永不清,`write` 永遠 rc 14)。
- **測試**:殺掉持有者後,以非 root 行程 `exec -a batman-slot` 佔住同一 pid → `settings.set` 不是 `E_BUSY`、`write` 不是 rc 14。負對照:§12.5.3 原規則 → `E_BUSY`(FAIL)。

**m2. `bootinfo` 的輸出契約不夠緊(§12.5.1-2)**

- 輸出經 `provstore.Exec`,stdout 與 stderr **合併**(V6);`batman-slot` 會在 stderr 印 WARN(例如接手 stale lock)。header 與 `--` 之後的 distroconfig 全文也沒有長度執行者(「≤ 64 KiB」只是描述)。
- **修法**:
  - helper 以分開的 stdout / stderr 跑 `bootinfo`(`ExecReader` 加 stdout 參數);
  - header 嚴格:`verified=` 與 `bootcfg=` 各**正好一行**、在 `--` 之前、格式 `^[0-9a-f]{64}$|^-$`,重複或缺 → 當作讀不到(沿用上次,標待重讀);
  - `batman-slot` 端 `head -c 65537`,超過 64 KiB → rc 18;
  - `bootcfg` 在 `config.txt` 或 `distroconfig.txt` 不存在時的定義寫明(建議:缺檔 → rc 18,不要算空字串的雜湊)。
- 只有 root 能寫 FAT,所以這是健壯性而非越權;但 key 8 與 ble-ok 都依賴它。
- **測試**:接縫讓 `bootinfo` 在 stderr 印一行 `verified=<假 sha>` → helper 不採用。

**m3. `bootinfo` 每 15 s 拿一次全域 slot 鎖(V7)**

- ble-ok 寫好之後 `bootConfigOK` 仍每 tick 呼叫 → 每 15 s 一次 `batman-slot.lock`。撞上操作員的 `batman-slot commit / rollback / apply`、ab-selftest、daily-validation 會 rc 14(現在是 rc 1 die);autocommit 會重試(V8),但其他呼叫者是一次性的 → 間歇失敗、harness 誤報。
- **修法**:`bootConfigOK` 在本次開機的 ble-ok 已寫好後**不再呼叫** `bootinfo`(只有 `write` / `arm` / `disarm` / 啟動時刷新快取);或 `bootinfo` 拿不到鎖時等 ≤ 2 s。§12.5.2 寫明「rc 14 = 可重試」,並讓 harness 對 rc 14 重試一次。
- **測試**:commit 迴圈 200 次與 helper 並行 → 0 次 rc 14(或全部重試成功)。

**m4. `/msg` AEAD 失敗「不中止」需要同時改 provd 的兩個副作用(§12.5.11)**

- §12.5.11 對 flynn/noise 的主張成立(V1)。但現行 provd 在 AEAD 失敗**之前**就 `msgs++`、`lastActive = now`(V2)。照搬到 HTTP:
  - 偽造的 `/msg` 會刷新 idle 計時 → 知道 session id 的人可以讓一個被放棄的 session 永遠佔住 HTTP 的 2 槽之一;
  - 偽造 2^20 次會觸發「2^20 messages: re-handshake」→ 等於可以踢掉擁有者。
- **修法**:AEAD 失敗時不改 `msgs`、不改 `lastActive`;每個 session 的失敗另計數(例如 1 分鐘 > 32 次 → 只對來源 IP 回 429,不中止 session)。
- **測試**:「偽造 `/msg` 後 session 仍可用」再加:持續偽造 11 分鐘 → session 照樣因閒置被關;偽造計數不影響 `msgs`。

**m5. bearer 與協定 `X-Batman-Session` 的關係、取塊請求的認證沒寫(§12.5.11、§3.8.1)**

- 協定:`X-Batman-Session` 在 `/session`(認證前)明文回傳並路由 `/msg`(V3)。設計:PUT 的 bearer 在 `auth/owner` 後產生。沒寫:是不是另一個值、怎麼交給 app(明文 header 或 Noise 內的回應 body)。若實作直接沿用 `/session` 回的值當 PUT bearer,任何旁聽 `/session` 的人在擁有者認證後即可 PUT。
- 「空 body 的 `POST /msg` = 取下一塊」沒有認證:知道 session id 的人可以先取走一塊 → app 的下一塊 nonce 對不上 → session 中止。§12.5.11「偽造的 `/msg` 踢不掉擁有者」對空 body 不成立。
- **修法**:
  - 寫明兩個值:路由用 session id(`/session` 明文)、PUT bearer(另一個 128-bit,放在 `auth/owner` 或 `bulk/open` 的**加密**回應 body 裡交給 app);PUT 只認 bearer。
  - 取塊改成加密的 `{type: "more"}` 信封,或把「旁聽者可以打斷分塊取回」寫進 §7 的 DoS 界線。
  - 協定 §4.2 同步改(§10)。
- **測試**:用 `/session` 回的 id 當 PUT bearer → 401;旁聽者送空 body `/msg` → 擁有者的分塊取回照樣完成(或 §7 寫明不擋)。

**m6. PUT 的 `O_TRUNC` 可以截斷 worker 正在讀的 inode**

- worker 開 fd 後才關窗,provd 從 poll 得知關窗最多晚 4–8 s;§12.5.7 每次 PUT `O_TRUNC` 同一個路徑 → 這段時間內的 PUT(旁聽者拿 bearer;被入侵的 provd;app 的重送 bug)會截斷 worker 正在讀的**同一個 inode**。結果是 fail-closed(讀回不符),但發生在 `begin_write` 之後 → 退路已被標 BAD(reason 22)。
- **修法**:worker 開 fd、fstat 通過之後,立刻 `unlinkat(dirfd, "payload")`(helper 本來就是唯一刪除者);之後的 PUT 只會建新 inode,不影響 worker。provd 端:poll 顯示 worker 在跑或沒有窗 → PUT 回 409。
- **測試**:worker 開檔後 1 s 內再 PUT 一份垃圾 → worker 照樣成功。負對照:不 unlink → worker 失敗(FAIL)。

**m7. update-last 的寫入要原子且落盤(§12.5.5)**

- 判讀表全靠 update-last;prepare 前寫、worker 後寫、apply 寫三次,中間任何一次斷電若留下半個檔 → 第 5 列「壞 → 0」,把「寫到一半」(該報 22)報成「沒有更新」。
- **修法**:寫 tmp → `fsync(file)` → `rename` → `fsync(dir)`;§5.3 寫明。
- **測試**:Go 單元測試在 rename 前中止 → 讀到的是上一版,不是壞檔。

**m8. 被移除的擁有者「已寫入、未啟用」的槽仍留著當 #133 的落點(§12.5.6、§12.5.13)**

- `owner/remove` 中止的是**正在跑**的 worker。worker 已完成(written: true、未 arm)時只清 pending;那一槽仍是有效、可開機的槽(V14:#133 fallback 會 commit 它)。被移除的擁有者可能就是遺失 / 被偷的手機。
- PROD 下它只能是 K 簽過的版本,風險低;DEV 下(公開 T)可以是任何東西。
- **修法**:`owner/remove` 移除的若是 update-last / pending 的擁有者且 `written: true`、未 arm → `batman-slot` 把目標槽標 BAD(新動詞或 `write` 的 `invalidate` 子集)。status 報 0 + 22。否則在 §12.5.13 界線寫明「包括被移除的擁有者寫入的版本」。
- **測試**:worker 完成後 `owner/remove` → 目標槽有 `BATMAN-BAD`。

**m9. 供應鏈:release gate 與簽章工具的範圍(§12.5.10、§3.7.2)**

- (a) `ci` 通道(V13)不是 `wsl`:照 gate 規則,R 產生之前**所有 ci build 都 FAIL**。沒寫 ci image 信任什麼。這會誘使人放寬 gate。要明定:ci = 與 wsl 同(信任 T,不出貨),或 ci 不帶任何根鑰匙(update.check → 21)。
- (b) `scripts/release-root.fpr` 與 `release-root.pub` 同一個 repo:能寫 repo 的人可以兩個一起換。gate 擋的是「我們自己的錯」,不是被入侵的 repo — §7 寫明;建議 app 端也釘同一個指紋(app 不同 repo)。
- (c) `release-sign.sh` 要拒絕簽:`BATMAN_WBOX` 非空、版本含 `.wbox-`、`BATMAN_DIRTY=1`、channel ≠ rel。因為版本比較忽略 `+meta` 與 CH(§12.5.9),一份被 K 簽到的 wbox / ci build 在 PROD 節點上等同同號正式版(wbox 不會被 commit,但會進試用)。
- **測試**:對 wbox / dirty / ci payload 跑 `release-sign.sh` → 拒絕(不需要 YubiKey,在讀 stamp 時就停)。

**m10. HTTP 接受成員 session,而成員 session 不可驅逐(V9)**

- 上傳窗期間,知道這台 AP 密碼的成員(或被移除、但仍是網路成員的前擁有者)可以開兩個 psk_member session、每幾秒 `status` 保活 → HTTP 2 槽全滿、擁有者連不進來。§7 的 DoS 列只寫「知道 AP 密碼的人」,沒寫成員能長時間佔槽。
- **修法**:上傳窗模式只收 psk_owner;psk_member 只在備援模式收。或在 HTTP 池讓「擁有者候選」可以驅逐成員 session。
- **測試**:兩個成員 session 佔槽時,擁有者 `PUT` 流程仍可完成。

**m11. helper 啟動時的 `disarm` 要有條件(§12.5.15、§12.5.5 第 6 列)**

- §12.5.15 寫「helper 啟動時的 `batman-slot disarm`」,沒有條件。照字面:操作員手動 `batman-slot apply`(已 arm、等自己重開)時 helper 剛好 respawn → 操作員的更新被默默取消。
- **修法**:只在 update-last 的 `apply_boot_id` = 本次開機且 `armed` 時 disarm(第 6 列的條件)。
- **測試**:手動 `apply` 後重啟 helper → tryboot 旗標仍是 1。

**m12. 拒絕清單在 FAT 上要不分大小寫(§12.5.4,縱深)**

- FAT 不分大小寫:`boot/AUTOBOOT.TXT`、`boot/batman-verified` 通過 §12.5.4 的正規式,也不在(分大小寫的)拒絕清單裡。現在靠「∩ 類別白名單」擋住(類別 glob 不會配到這些名字),但兩道防線應該各自成立。
- **修法**:拒絕清單與類別比對都先轉小寫;SUMS 內大小寫折疊後重複的名字 → 拒絕(兩列指到 FAT 上同一個檔)。SUMS 同名重複列也拒絕(`sum_of` 取第一個、Go 可能取最後一個)。
- **測試**:有效簽章 + SUMS 列 `boot/AutoBoot.txt` → rc 13 / reason 11。

**m13. 仍缺的負測試**

| 性質 | 狀態 |
|---|---|
| tmpfs `nr_inodes=16`(provd 建第 17 個 inode → ENOSPC,其他服務正常) | §12.5.16 沒有 |
| helper 刪檔不跟隨 symlink(provd 把 `payload` 換成指向 `/etc/shadow` 的 symlink、或目錄) | 沒有 |
| PUT 409(第二個 PUT;剩餘時間不夠) | 沒有 |
| `bulk.open` 帶錯的 sha → 15 | 沒有 |
| 版本規則:相等重裝、`+meta` 不同、跨通道同號 | §12.5.9 只有 Go 表測,沒有負對照列進 §12.5.16 |
| pid 冒充(m1)、bootinfo 假 header(m2)、截斷(m6)、已寫入槽在移除擁有者後(m8)、release-sign 拒簽(m9) | 新 |

**m14. 文件內部不一致(會讓實作照舊文字做)**

- §3.7.5-4 仍是 `^boot/[A-Za-z0-9._-]+$`(允許 `boot/..`),§12.5.4 已改;§3.7.5-6 仍寫「逾時 → reason 11」與 `bootcfg-sum`;§3.7.4 步驟 1 仍寫「R;prov_test 另加 T」(與 §12.5.10「正好一把」衝突),步驟 4 仍寫 `bootcfg-sum`;§3.8.1 仍寫「本機 lo 上的行程也被丟(沒有標記)」(已被 §12.5.11 推翻)。請直接改原段落,不要只靠「§12.5 取代」。
- 鑰匙檔格式:§12.5.10「正好一個 65 B 的點」vs. 現行 `T.pub` 是一行 hex(V12)。寫明:一行、130 個小寫 hex、解碼後是曲線上的非壓縮點;`release-min-serial`:一行、`^[1-9][0-9]{0,9}$`。
- SUMS 上限 64 KiB:現在兩板約 35 KB(V10),overlays 再多約 80% 就會撞上 → 寫進 checklist,或上限改成 256 KiB(仍在 helper 記憶體內)。

---

## 4. 確認沒問題的部分(✅)

- **單一掛載者**(§12.5.1):`tboot_open` 只重用 `/boot`、其他掛著 → rc 14,加上 helper 不再自己掛 FAT,把 B8 時期 helper ro 掛載與 `write` 相撞的整類問題拿掉了。
- **結束碼**(§12.5.2):既有呼叫者只看 rc ≠ 0(B8 V15),新增 10–18 不影響 sysupgrade;reason 21 讓基礎設施錯誤不再被報成「簽章不符」。
- **嘗試綁定**(§12.5.5):prepare 先寫 update-last、判讀表有序、每個 phase 帶 sha / to_version → A8 的「舊成功被當成新成功」不會再發生。
- **iifname**:本機產生的封包 iif = lo,`--network host` 容器帶 NET_RAW 打 mark 也進不來;bridge 網路的 tenant 跨 netns 時 mark 被清(B8 V12)。
- **完整性鏈**:先驗簽才寫;SUMS 用 helper 驗過的那份;boot 檔先複製到 root 0700 目錄再雜湊;rootfs 讀回以 RSUM 比對;owner-op 綁 sha(prepare、apply、bulk.open)。被入侵的 provd 或 AP 上的人都改不了「裝什麼」。
- **tar 規則**(§12.5.12):Go 1.22 會把 `TypeRegA` 正規化、PAX / GNU long name 在 `Next()` 內合併(V15),只收 TypeReg + 兩個 TypeDir 可實作;成員數上限 SUMS+4 與兩板實際內容相符。
- **`trap 'exit 143' TERM`**:對 commit 的 p7 寫入反而更安全(ash 等前景指令結束才跑 trap)。
- **公開 T**:擁有者同意仍是必要條件(owner-op);T 不擴大擁有者的權限(本來就能 `ssh_keys/set`)— 屬使用者已接受的界線,§7 已寫。

---

## 5. 判定

**APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR / 14 MINOR)。

- m1、m5、m6 是實作前要先寫進 §12.5 的規格(都很小,附負對照)。
- m14 請直接改原段落。
- m9(a) 的 ci 通道信任要使用者決定;R_dev 替代方案(B8-m1)也仍待使用者選。
- 其餘進附錄 D,每項附測試。
