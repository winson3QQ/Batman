# 254-p3-impl v7.4(b78aa27)審查 B — 安全優先(S5 整份)

- 審查者:B(安全優先)。只讀:`/home/yello/Batman-p3`(b78aa27)、`/home/yello/firmware-2710`(02f0913d,含 linux-6.6.138 build 樹、`.github/workflows`)、Go toolchain 1.26.4 原始碼。沒改任何 repo、沒連節點。
- **結論:APPROVE-WITH-CHANGES。0 BLOCKER / 0 MAJOR / 14 MINOR。** B9 的 14 項都有處理;v7.4 新機制沒有找到讓節點被越權控制的洞。但有兩個新機制本身帶進來的退步(m1 持有者規則會把「合法持鎖者」判死 → 鎖被搶;m6 啟動 disarm 依賴 `armed`),一個與事實不符的前提(m3「CI 同一支 build-board.sh」不成立),一個 §7 低估的影響(m2 AP 鄰居可以讓退路槽失效)。標 ★ 的請在實作 PR 第一個 commit 寫回 §3。
- **更正我自己上一輪的錯**:B9-m1 我建議「argv[1] 正好是 `/usr/sbin/batman-slot`」— 這是錯的建議,v7.4 照做後反而變成 fail-open(見 m1)。pid + starttime 已經唯一識別「同一個行程」,uid 與 argv 檢查是多餘機制,應刪。

---

## 0. 自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | harness 以**非標準路徑**執行 `batman-slot` 的副本:`sh /tmp/run/batman-dv/batman-slot.wsl9 precheck-node`、`$d/batman-slot.nosetsid`(pty-commit)、`$R/usr/sbin/batman-slot commit`(rbarm) | `scripts/dv/chain1-254.sh:224`、`scripts/dv/pty-commit-254.sh:70`、`scripts/node/prov-rbarm-254.sh:26,54` |
| V2 | 現行持有者判斷 = `kill -0` + cmdline **子字串** `batman-slot`(上述副本都會被判「活著」) | `batman-slot:84-95`;`batman-autocommit:78-86`(`slot_writer_alive`) |
| V3 | autocommit.log 的行:`COMMITTED boot= slot= version=`、`COMMITTED-BY-OPERATOR …`、**`NOT-COMMITTED boot= slot= version= reason=…`**、`TRIAL-REVERTED boot= slot= version= waited= reason=${why}`、`PRECOMMIT-CANARY-FAIL`;95 寫 `FW-OVERRIDE*`。沒有輪替 / 截斷 | `batman-autocommit:65,193,239,366,554,568`;`95-batman-storage:460,471,483`;全 repo grep 無截斷 |
| V4 | **CI 不跑 `build-board.sh`**:`build-firmware.yml` 自己呼叫 `stamp-batman-build.sh`(:137)、`make`(:175)、`check-prov-test-gate.sh`(:229)、curl 下載 `build-ab-payload.sh`(:272-280);build-board.sh 只出現在註解 | firmware `.github/workflows/build-firmware.yml` |
| V5 | `stamp-batman-build.sh` 對 `BATMAN_CHANNEL` 只檢查非空,不檢查 ∈ {wsl, ci, rel};`VER="$REL-$CH.$N+…"` | firmware `scripts/stamp-batman-build.sh:23-24,57` |
| V6 | build-board 的 gate 讀 image 內 squashfs 的解壓(`gate-rootfs.sh --extract`),payload 的 root.squashfs 與它 `cmp` | firmware `scripts/build-board.sh:198-224` |
| V7 | Go `SysProcAttr.Unshareflags` 含 `CLONE_NEWNS` 時,子行程在 exec 前自動 `mount("none","/",MS_REC\|MS_PRIVATE)` → 子行程的掛載不傳回主機 ns,行程全死後 ns 消失、掛載隨之卸載 | go1.26.4 `src/syscall/exec_linux.go:473-478` |
| V8 | kernel `SO_MARK` 需 CAP_NET_RAW / CAP_NET_ADMIN(§3.8.1 的 iifname 前提成立);`CONFIG_USER_NS=y` | linux-6.6.138 `net/core/sock.c:1387-1395`;bcm2711 kernel `.config:180` |
| V9 | `slot_is_bad` 在目標 boot 分割「沒掛載且掛不上」時回 1(=「不是 BAD」)→ `rollback` 照做(既有行為) | `batman-slot:364-369`、`:844` |
| V10 | `tests/keys/README.md` 與 `signrel.py` docstring 仍寫「T 只被 prov_test 信任、release image 不得含 T」— 與 v7.4「wsl / ci 信任 T」不一致 | `tests/keys/README.md`「Trust.」段;`tests/tools/peer/signrel.py:4` |
| V11 | provd 解密前 `msgs++`、`lastActive = now`(設計已寫要改);`provstore.Exec` stdout/stderr 合併(設計已改用 `ExecReader`) | `provd/session.go:315-322`;`provstore/exec.go:24` |
| V12 | `otaBusy` 現在只 `Lstat` `.busy` 是否存在 | `node/wtxn.go:450-454` |
| V13 | `BATMAN-VERIFIED` 是新檔,repo 內(feed、scripts、tests、firmware scripts)沒有其他讀者 → 格式 `<sha> <boot_id>` 無相容性問題 | 全 repo grep `VERIFIED` |

---

## 1. B9 逐條確認

| B9 | v7.4 | 判定 |
|---|---|---|
| m1 pid 冒充 | §3.7.3 pid+starttime+uid0+argv[1] | ⚠️ 冒充擋住了,但 argv[1] 是我建議錯的多餘機制,造成新 fail-open → **m1** |
| m2 bootinfo 輸出契約 | 只讀 stdout、header 嚴格、`head -c 65537`、缺檔 rc 18 | ✅ 關閉;負對照表沒有「stderr 假 header」那一列(m13) |
| m3 每 15 s 拿鎖 | 只在啟動 / 自己寫後 / check 時跑;`slotMu` | ✅ 關閉 |
| m4 AEAD 副作用 | 不改 msgs / lastActive | ✅ 關閉;新加的「per-IP 429」本身可被反用(m10) |
| m5 bearer | 獨立 128-bit、在加密的 `bulk.open` 回應裡給 | ✅ 關閉;PUT 綁「哪個 session 的 IP」沒定義(m8) |
| m6 O_TRUNC 截斷 | worker 開檔後立刻 unlink | ✅ 關閉;另一條路徑(完整 PUT 搶在 prepare 前)仍能毀掉退路(m2) |
| m7 update-last 原子 | `updMu` + tmp/fsync/rename/fsync(dir) | ✅ 關閉(§4 寫者列表與 §3.7.4 不一致,m13) |
| m8 被移除擁有者寫入的槽 | 界線 | ✅ 關閉(界線文字要補「DEV 下有簽章不代表什麼」,m13) |
| m9 供應鏈 | ci = DEV 待使用者;app 釘指紋;release-sign 拒簽 | ⚠️「CI 同一支」與事實不符(m3);channel 未白名單(m4);release-sign 沒驗鑰匙(m5) |
| m10 成員佔槽 | 窗模式只收擁有者 | ⚠️ 窗與備援同時成立、或窗開前已建立的成員 session 沒寫(m9) |
| m11 啟動 disarm 有條件 | `apply_boot_id` = 本次 && `armed` && !`rebooting` | ⚠️ 依賴 `armed` 有洞(m6) |
| m12 FAT 不分大小寫 | §3.7.3 | ✅ 關閉 |
| m13 負測試 | §12.5 表 | ✅ 大部分;缺項見 m13 |
| m14 文件不一致 | §3.7 / §3.8 重寫 | ✅ 大部分;新的不一致見 m13 |

---

## 2. 行為者總覽(整份 S5 重看)

| 行為者 | 輸入 | 擋法 | 判定 |
|---|---|---|---|
| mesh 遠端 | 8095 | bridge mark + inet iifname | ✅(AP 正向 / VLAN 臂仍待 §9-4) |
| 手機 AP 上知道 AP 密碼的人 | 明文 PUT(含 bearer)、IP 偽造、取塊、偽造 `/msg` | Noise、owner-op 綁 sha、簽章 + 讀回 | 完整性 ✅;**能讓退路槽失效**(m2),§7 寫成「只 DoS」 |
| 本機非特權 / tenant | lo、SO_MARK、搶 8095、pid 重用 | iifname、bind 回報、starttime | ✅ |
| 容器內 root(無 userns) | 冒充持有者 | starttime 擋 pid 重用 | ✅(只要保留 starttime) |
| 被入侵的 provd | 上傳檔、改名 / 保留 fd、塞滿 tmpfs | fd + fstat + unlink、白名單 tar、讀回 | 完整性 ✅;能毀退路 = 誠實界線(同 m2) |
| 被移除的擁有者 | 已寫入的槽 | 中止 worker、界線 | ✅ |
| 成員 | HTTP 槽 | 窗模式只收擁有者 | m9 |
| 實體奪取 | `release-root.pub` | 無 secure boot | 界線 ✅ |
| 供應鏈 / 我們自己的錯 | channel 拼錯、CI 路徑、簽錯 image、`sh -x batman-slot` | gate、release-sign | m1、m3、m4、m5 |

---

## 3. Findings

沒有 BLOCKER、沒有 MAJOR。

### MINOR

**m1 ★ 持有者規則的 argv[1] 精確比對會把合法持鎖者判死 → 鎖被搶(v7.4 新機制,源自我 B9-m1 的錯誤建議)**

- **情境**:持鎖者是 `sh -x /usr/sbin/batman-slot commit`(除錯常用,argv[1] = `-x`)、或 harness 的副本(V1:`/tmp/run/batman-dv/batman-slot.nosetsid`、`$R/usr/sbin/batman-slot`)。新規則判「不活著」→ 下一個 `batman-slot`(helper 的 `write`、`disarm`)接手鎖並與它並行寫 autoboot / tryboot / 目標槽;autocommit `slot_writer_alive` 也判不忙 → 試用退回時直接重開,可能打斷正在寫 p7 的 commit。現行子字串規則(V2)這些情況都判「活著」→ v7.4 是退步。
- **證據**:V1、V2;§3.7.3「argv[1] 正好是 `/usr/sbin/batman-slot`」。
- **修法(拿掉機制)**:持有者活著 = `/proc/<pid>` 在 **且** starttime 相同。pid 重用(包括容器內 root)的 starttime 必然不同,uid 與 argv 檢查多餘,刪掉。starttime 取法寫明:`/proc/<pid>/stat` **最後一個 `)` 之後**的第 20 個欄位(comm 可含空白與 `)`,直接 `awk '{print $22}'` 會被位移);shell 與 Go 共用同一個取法。
- **測試**:`sh -x /usr/sbin/batman-slot` 持鎖(接縫 hold)時 helper `write` → rc 14;負對照:argv[1] 規則 → 鎖被接手(FAIL)。原有「非 root `exec -a` 佔 pid」那列保留(starttime 擋)。

**m2 ★ AP 鄰居可以用一份完整的 PUT 讓退路槽失效;§7 寫「只造成 DoS」低估**

- **情境**:知道 AP 密碼的人(WPA2-PSK 可解出同 AP 流量、注入 frame)從擁有者的明文 PUT 看到 bearer 與整份 payload。他打斷擁有者的 PUT(TCP RST),偽造擁有者的 IP 自己 PUT 一份「前段(SUMS、metadata、boot)照抄、root.squashfs 是垃圾」的同大小檔並完成。app 收到 409 後依 status(phase 1 百分比到 100%)認為完成 → prepare。worker 步驟 2–4 全過(前段是真的)→ `begin_write` 把退路槽標 BAD → dd 垃圾 → 讀回不符 → 0 + 22,且可每次重複。節點仍跑目前槽,但 A/B 退路被非擁有者、以擁有者沒同意過的內容毀掉。
- **證據**:§3.7.5-2/4/5(rootfs 只在 dd 之後讀回驗證);§3.8.2(bearer 明文、PUT 綁 IP、409 只擋「進行中」);§7「同 AP 上知道 AP 密碼的人 … 只造成 DoS」。
- **修法**:worker 在 `begin_write` **之前**先對已 unlink 的 fd 做一遍完整驗證:tar 解析到 `root.squashfs`、串流算 sha256、與 `SHA256SUMS` 的 `root.squashfs` 列比對;不符 → reason 11、目標槽沒動。過了才 `lseek(0)` 走現行的第二遍(寫入 + 讀回不變)。檔已在 RAM(tmpfs),多一遍在 Pi 4 約 1–2 s(⚠️ 估計,未實測)。unlink 之後再 `fstat` 確認 `nlink == 0`(防刪錯名字)。這把「壞上傳在動退路之後才被發現」整類拿掉;被入侵的 provd 保留 fd、在兩遍之間改內容仍做得到 → 寫進 §7 誠實界線(它本來就能 DoS)。§7 該列改成「能讓更新失敗;內容在動退路前先驗」。
- **測試**:有效簽章、前段正確、rootfs 改 1 byte 的 payload → reason 11,目標槽沒有 `BATMAN-BAD`、cmdline 不變。負對照:拿掉第一遍 → 目標槽 BAD(0 + 22)。

**m3 ★ release gate「CI 同一支 build-board.sh」與事實不符**

- **情境**:CI 的 firmware build(`build-firmware.yml`)不呼叫 `build-board.sh`,而是逐一呼叫各 gate 腳本(V4)。照 §3.7.2 把 gate 寫進 `build-board.sh`,CI 出的 `rel` image 沒有鑰匙檢查;正式發行若走 CI(`build-release.yml` / `github-release.yml`),R / T 放錯不會被擋。
- **證據**:V4。
- **修法**:gate 寫成獨立腳本(例 `scripts/check-release-root.sh <extracted-root> <channel>`,與 `check-prov-test-gate.sh` 同模式),`build-board.sh` 與 `build-firmware.yml` 都呼叫;§3.7.2 改正文字。CI lint 斷言兩邊都呼叫它。
- **測試**:lint:`build-firmware.yml` 沒呼叫 → FAIL;三個負對照照舊在腳本層跑。

**m4 通道不是白名單**

- **情境**:`BATMAN_CHANNEL` 手寫(V5),拼錯(`release`、`REL`)時:stamp 步驟不知道放哪把鑰匙、gate 對未知通道行為沒定義;裝上去後版本解析失敗 → 之後每次 `update.check` 都是 reason 11,只能 ssh。
- **修法**:stamp 步驟 `CH ∉ {wsl, ci, rel}` → exit 1;gate 對未知通道 FAIL(預設拒絕);§3.7.2 寫明。
- **測試**:`BATMAN_CHANNEL=release` → stamp FAIL。

**m5 `release-sign.sh` 要在「它要簽的那份 payload」上重跑 gate**

- **情境**:簽章是最後、不可逆的一步。現在只拒 wbox / dirty / 非 rel,讀的「stamp」是哪一份沒寫。若有人手動 `build-ab-payload.sh` 從別的 rootfs 打包、或 gate 被繞過(m3),一份內建 **T** 的 `rel` image 會被 K 簽 → PROD 節點裝上後改信任公開的 T(之後任何人都能簽出它能裝的版本,只剩 owner-op 一道)。
- **修法**:`release-sign.sh` 從 payload 的 `root.squashfs` 取 `/etc/batman-build`(`unsquashfs -cat`,不是 `metadata`、不是 build 樹的 log),要求 `metadata release=` = 該檔的 `BATMAN_VERSION`;取 `/usr/share/batman/release-root.pub`,指紋 = `release-root.fpr`;跑 `check-prov-test-gate.sh`(Go 接縫不在)。任一不符 → 拒簽。
- **測試**:對內建 T 的 `rel` payload 跑 `release-sign.sh` → 拒簽(不需要 YubiKey)。

**m6 啟動時 disarm 依賴 `armed`,但 `armed` 可能沒寫到**

- **情境**:(a) `batman-slot arm` 在自己的 process group(`Setpgid`)跑;helper 在 arm 途中被 SIGKILL / respawn → arm 自己跑完並 arm 了,但 `armed: true` 沒寫 → 新 helper 依條件不 disarm → tryboot 一直 armed,下一次任何原因的重開都進試用。(b) arm rc 0 後寫 `armed: true` 失敗(p6 滿 / 唯讀)設計沒寫怎麼處理。兩者還會讓判讀第 8 列(要求 `armed`)被跳過 → 試用退回後報 23 而不是 6。
- **修法(拿掉欄位)**:啟動 disarm 的條件改為 `apply_boot_id` = 本次開機 **且** 沒有 `rebooting`(`apply_boot_id` 在 arm 之前就寫了;disarm 冪等,rc 14 → 下個 tick 重試,會等到 arm 放鎖)。arm 失敗時清掉 `apply_boot_id`。第 8 列改看 `apply_boot_id` 存在。`armed` 欄位可刪。
- **測試**:arm 進行中(接縫 `arm-hang` 5 s)KILL helper → 重啟後 tryboot 旗標 = 0。負對照:以 `armed` 為條件 → 旗標 = 1(FAIL)。

**m7 autocommit.log 的比對要精確到欄位,讀取要有上限**

- **情境**:`NOT-COMMITTED … slot=<to_slot> version=<to_version>` 含子字串 `COMMITTED`(V3)→ 第 8 列照字面以子字串比對會報 0(曾 commit)而不是 6。`version=1.5.14-wsl.2` 是 `1.5.14-wsl.25` 的前綴。`TRIAL-REVERTED` 行尾 `reason=${why}` 是自由文字。helper 以 root 讀 p6 上的檔、從 `aclog_off` 讀到尾,沒寫上限。
- **修法**:每行以空白切,第 2 欄**正好**是 `COMMITTED` / `COMMITTED-BY-OPERATOR` / `TRIAL-REVERTED`;`slot=`、`version=` 取固定欄位(第 4、5 欄)並整個 token 相等;`O_NOFOLLOW` 開、必須是 regular file、從 `aclog_off` 起最多讀 1 MiB。
- **測試**:log 只有 `NOT-COMMITTED … slot=B version=<to>` 與 `TRIAL-REVERTED … slot=B version=<to>` → 6(不是 0);`version=<to>5` 不算。

**m8 PUT 綁「哪個 HTTP session 的來源 IP」沒定義**

- **情境**:HTTP 平常不聽,`bulk.open` 多半經 BLE 送出;§3.8.2「來源 IP = 建立該 HTTP session 的來源 IP」在這種流程下沒有對應的 session,§3.11-12 的 app 流程也沒有「PUT 前先建 HTTP session」。實作時要嘛默默拿掉 IP 綁定、要嘛擋掉正常流程。
- **修法**:擇一寫明:(a) PUT 前 app 必須在窗內以窗擁有者建立並 `auth/owner` 一個 HTTP session,PUT 的來源 IP = 該 session 的來源 IP,沒有 → 409;或 (b) 拿掉 IP 綁定(bearer 已在加密回應裡;IP 綁定對能偽造 IP 的 AP 鄰居本來就無效,m2)。建議 (b):少一個機制。
- **測試**:依所選寫一個 Go 測試。

**m9 「窗模式只收擁有者」與備援模式同時成立時的優先順序**

- **情境**:BLE 不健康(備援開)時擁有者開窗 → 兩個條件同時成立;或窗開之前,成員已在備援模式建立 2 個 session(「已建立的 session 繼續到結束或 10 分鐘」)→ 窗期間擁有者最多 10 分鐘連不進來。
- **修法**:窗開著 = 只收 psk_owner,不論備援;開窗時驅逐既有的成員 HTTP session。
- **測試**:停 BLE 5 分鐘 + 兩個成員 session 在線 → 開窗 → 擁有者 PUT 完成。

**m10 AEAD 失敗的 per-IP 429 是多餘機制,且可被反用**

- **情境**:失敗的 `/msg` 已經不改任何狀態、直接丟掉。「同一 session 1 分鐘 > 32 次 → 對該來源 IP 回 429」讓 AP 鄰居偽造擁有者 IP 送垃圾 `/msg`,就能讓擁有者自己的請求(含 PUT)被 429。
- **修法**:拿掉 429,只靠既有的連線上限(8)、body 上限、交握額度。若要留,只關**那條連線**,不對 IP。
- **測試**:偽造擁有者 IP 送 100 個壞 `/msg` → 擁有者的 PUT 照常完成。

**m11 殘留掛載:用私有 mount namespace 取代「卸載別人的掛載」**

- **情境**:§3.7.3「拿到鎖後把目標分割除了 `/boot` 以外的掛載都卸載並 rmdir」:(a) 會 rmdir 任意掛載點(操作員把 p3 掛在 `/mnt` → `/mnt` 被刪);(b) 以 `/proc/mounts` 第 1 欄字串比對裝置(`tboot_open` 現在也是,`batman-slot:409-417`),用別的名字掛的看不到;(c) 其他 mount namespace 的掛載看不到。而殘留掛載的**主要來源**正是 helper 期限到時 KILL 自己啟動的 `batman-slot`。
- **修法**:helper 以 `SysProcAttr{Setpgid: true, Unshareflags: CLONE_NEWNS}` 執行 `batman-slot write/arm/disarm/bootinfo`(V7:Go 自動把 `/` 設成 rprivate;ujail 已證明這顆 kernel 有 mount ns)→ 它的 FAT 掛載只存在於該 ns,KILL 後隨 ns 消失,不需要清理。「拿到鎖後」改成:以 `/proc/self/mountinfo` 的 major:minor 找目標分割的其他掛載,有 → rc 14(不卸載、不 rmdir);只有掛載點是 `batman-slot` 自己的命名(`/mnt/slotboot.<pid>`、`tmpd slotchk`)且該 pid 已死(m1 的規則)才卸載。這也從構造上解掉 §12.5 ⚠️ NEEDS-NODE「`-F` stage 2 的殘留掛載」中由 helper 發起的那部分。
- **證據**:V7;`batman-slot:409-417`。
- **測試**:`write` 期限到被 KILL → 主機 `/proc/mounts` 沒有 p3;操作員在 `/mnt` 掛 p3 → `write` rc 14、`/mnt` 還在。

**m12 跨通道時 key 7(min_from)怎麼比沒寫**

- **情境**:版本規則表寫「REL 相同、CH 不同 = 沒有順序」,但 key 7「目前版本必須 ≥ min_from」在沒有順序時的結果沒定義。
- **修法**:沒有順序 → 不符(reason 4,fail-closed);版本規則 Go 表測加這一列。

**m13 文件 / 測試不一致(會讓實作照舊文字做)**

- §4 update-last 寫者列「`update.prepare`、worker 結束、`update.apply`;§12.5.5」vs §3.7.4「prepare、apply、`reboot committed` 失敗」。
- §5.1:`update.check` 的 reason 清單少 21;worker 失敗「3: 1 / 11 / 12 / 17」少 2、5、21;`update.apply` arm 失敗少 2、21;§5.3「rc 依 §12.5.2」→ 改 §3.7.3。
- §7「同 AP 上 … 解出明文 `X-Batman-Session`、搶先 PUT」→ v7.4 PUT 用 `X-Batman-Upload`;空 body 取塊打斷的 DoS 也要列進 §7(§3.8.1 說「列 §7」但表裡沒有);m2 的影響改寫。
- §3.7.4 第 10 列界線「有簽章」:DEV(公開 T)下不代表什麼,寫明。
- worker 的 `write` 回 rc 14(E_BUSY)時,非同步結果記成什麼 phase / reason 沒寫(建議 0 + 21,可重試)。
- harness:`tests/keys/README.md`、`signrel.py:4` 仍寫「T 只給 prov_test、release image 不得含 T」(V10)→ harness PR 改成「wsl / ci 信任 T,rel 不得含 T」。
- §12.5 負對照表缺:`bootinfo` 在 stderr 印 `verified=<假 sha>` → helper 不採用(B9-m2 的測試);以及 m1、m2、m6、m7、m11 的新列。

**m14 (既有,列 checklist)`slot_is_bad` 掛不上時回「不是 BAD」**

- V9:目標 boot 分割沒掛載且掛不上(FAT 損壞、EBUSY)→ `slot_is_bad` 回 1 → `rollback` 把它設成預設。這是 P3 之前就有的 fail-open;S5 讓「寫到一半被 KILL」成為預期路徑,接觸面變大。
- **修法**:掛不上 → 當作 BAD(rollback / commit 拒絕,rc 18)。不在 S5 範圍可以,寫進 #254 checklist。

---

## 4. 確認沒問題的部分(✅)

- **完整性鏈**:先驗簽才寫;根鑰匙只有一把、格式嚴格、缺 → reason 21 不預設;簽章快取只快取簽章(不含節點狀態);SUMS 用 helper 驗過的那份;只複製 SUMS ∩ 類別白名單,不分大小寫的拒絕清單;讀回以它為準;owner-op 綁 sha(bulk.open / prepare / apply)。
- **上傳檔處理**:`O_NOFOLLOW|O_NONBLOCK` + fstat(regular、nlink 1、uid 471、大小)+ 立刻 unlink、之後只用 fd;Go 白名單 tar(只 TypeReg + 兩個 TypeDir、尾端 EOF、gzip 無尾資料、成員數 / 總量上限);boot 檔以 `O_EXCL|O_NOFOLLOW` 寫進 root 0700 目錄;刪除只用 `unlinkat`。
- **`VERIFIED` 綁 boot_id**(V13):新檔、無其他讀者;擋住「別次開機的驗證被拿來 arm」。
- **bearer**:與 session id 分開、在 Noise 加密回應裡交付、constant-time、不進 log。
- **防火牆**:`iifname != br-ahwlan` 擋 lo 與 SO_MARK(V8);fw4 載入失敗三道關;表不在就不聽。
- **`trap 'exit 143' TERM`**:ash 等前景指令結束才跑 trap,commit 寫 p7 時被 TERM 反而更安全。
- **bootinfo 只讀 stdout、不定期跑**:拿掉了 B9-m2 / m3 的整類問題。
- **條件式 disarm 的方向**正確(操作員手動 apply 不被取消),只是條件要改(m6)。

---

## 5. 判定

**APPROVE-WITH-CHANGES**(0 BLOCKER / 0 MAJOR / 14 MINOR)。

- ★ m1、m2、m3 請在實作 PR 第一個 commit 寫回 §3(m1 是**拿掉** uid / argv 檢查;m2 是動退路前多一遍驗證;m3 是把 gate 抽成兩邊共用的腳本)。
- m4–m12 進附錄 D,每項附負對照(m6、m8、m10 都是拿掉機制)。
- m13 直接改原段落;harness 文字走 harness PR(#290)。
- m14 進 #254 checklist。
- 待使用者決定的仍是 §12.5.18 兩題(R_dev、`ci` 信任),本輪沒有新增。

⚠️ 沒查的:§9-4 / D-1 / D-2(只能上機);m2 第一遍的實際耗時;`/opt/batdata/log` 在 04 上的權限(m7 的讀取上限是縱深,不依賴它);sysupgrade stage 2 的實際掛載狀態(A9-m16;m11 只解掉 helper 發起的那部分)。
