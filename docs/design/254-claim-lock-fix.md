# Design: #254 認領後的上鎖修正 + commit 放行的 PTY 競態 — v6(核准)

**狀態**:**v6 = 核准版**(v5 兩位 APPROVE-WITH-CHANGES、0 MAJOR,MINOR 已併入)。v4:A APPROVE-WITH-CHANGES 0 / 1 / 4、B REJECT(窄)0 / 1 / 4(同一個 MAJOR);v3:A APPROVE-WITH-CHANGES 0 / 1 / 6、B REJECT(窄)0 / 1 / 5(同一個 MAJOR);v2:A APPROVE-WITH-CHANGES 0 / 3 / 8、B REJECT(窄)0 / 2 / 6;v1 兩位都 REJECT(摘要見 §14)。
**基準**:Batman `main` 92f091c(= 出貨 1.5.13-wsl.1);firmware `build-3aplus` 081e7be1。
**單號**:#254(P1 殘項,不另開單)。**證據留言**:#254 6405534555(認領)、6405829438(延伸影響)、6406148692(PTY)。

標記:✅ = 本次在真機或原始碼查過(附位置);⚠️ = 推論 / 尚未實測。

## 1. 問題(都已在 04 真機重現)

### 1.1 認領後不會上鎖(主要)
- ✅ 04(1.5.13-wsl.1,legacy)跑 `scripts/dv/prov-claim-254.sh`:`claim.verify code=0`、`state=claimed`,但 `lock=UNPROVISIONED pw=on rootpw=on tty=0 hash=`(空);helper log:`claim committed but the lock step failed: cryptpw rc=127 (the next boot completes it)`。
- ✅ 根因:`main.go:177-184` 以 `cryptpw -s -m sha512` 產生 hash;image 沒有 `cryptpw`(firmware `.config`:`CRYPTPW`、`MKPASSWD`、`USE_BB_CRYPT` 都未開;04 `command -v cryptpw` 找不到)。
- ✅ 單元測試沒抓到:`node_test.go:62` 的 `fakeSys.CryptPassword` 直接回 `"$6$x$"+pw`。
- ✅ 「the next boot completes it」**不存在**:`boot/boot.go` 沒有上鎖補做;96 只在 fresh overlay 跑。
- ✅ 失敗時 claim **仍回成功並交出沒設進去的密碼**(`node.go:436-445`),且**不呼叫 `--save`** → p5 有 claimed prov 卻沒 `.seeded` → gate「claimed / member 未 seed → 擋」(`batman-slot:546-553`)擋掉之後所有正常 OTA(繞過只有 `/tmp/batman-slot.allow-unseeded`,操作員手動)。
- ✅ `claim.replay`(`node.go:498`)與 `root_password.reset`(`:655`)用同一個 `CryptPassword` → 目前**一定** `E_APPLY`。
- ✅ 上鎖有**三套**實作:Go `ApplyLock`(`main.go:136-175`)、sh `prov_apply_lock`(`prov-lock.sh` 尾段)、96 的 fallback(`96:65-73`),兩套還共用暫存檔名 `/etc/shadow.prov`。

**現場後果**:被認領的節點 root 免密碼、ssh 密碼登入開著、序列埠免密碼、app 拿到假密碼、之後不能正常 OTA。目前沒有 app、沒有任何節點被認領過 → 現場沒有受影響的節點。

### 1.2 commit 的放行 start 在 PTY 下是賽跑(次要)
- ✅ `batman-slot:746-752`:`env -i … setsid /etc/init.d/openmanetd start … &`;fork 到子程序 `setsid()` 之間它仍在 PTY session 的 foreground pgrp,session leader 退出時 kernel 送 SIGHUP。
- ✅ 白箱(`setsid-race-254.sh`,同一寫法、子程序是 marker、parent 比產品早退出 → 比產品嚴苛):存活 3/50、2/50;子 shell 內 `trap '' HUP` 50/50;不 setsid 0/30;setsid 前延遲 0/30。**這是 marker harness 的數字,不是產品的遺失率**。
- ✅ 端到端(真的 `batman-slot`):normal 3/3 放行、拿掉 setsid 的 flip VALID。**舊碼 3/3 通過 → 端到端分不出新舊**;負對照只有白箱(§11.6)。輸了由 joinwatch reconcile 15 s 內補(#254 6405829438)。

## 2. 現場觸發與威脅(逐 actor)

| actor | 情境 | 今天 | 修正後 |
|---|---|---|---|
| 擁有者 | app 認領 | 不鎖、假密碼、不能 OTA | 鎖定、密碼可用、p5 seed、可 OTA |
| 擁有者 | 回應遺失 → `claim/replay`;`root_password/reset` | 一定 `E_APPLY` | 成功 |
| 擁有者 | 上鎖在寫 shadow **之前**失敗 | — | `ELockIncomplete` → 協定 `E_LOCK_INCOMPLETE`(新,§5.3、§7),走 replay |
| 本機非特權程序 | 讀 / 換 shadow、搶暫存檔名 | 共用 `/etc/shadow.prov`(root 0755 的 `/etc`,非特權不能寫) | 每次 `mktemp`,不變的權限 |
| 本機非特權程序 | 卡住 procd / dropbear 的 flock(`/var/lock` 1777,既有面 #280 類) | — | S13 不經 procd 寫 uci,不受影響;dropbear 由 procd 啟動時才讀 uci |
| 被攻陷的 provd | 送 claim / replay / reset | helper 驗授權(既有) | 不變;新增的 `ELockIncomplete` 不洩漏任何秘密 |
| 實體接觸(拿到裝置) | 序列埠 / 拔 SD 卡 | 免密碼 | 序列埠要密碼;**誠實界線**:階段 1 rootfs / p5 未加密(608B 設計 doc),拔卡即可讀寫,序列埠防護只擋「不拆機」的人 |
| 網路上的人 | ssh 密碼 | 開著 | `-s -g`(只收 key);**誠實界線**:LuCI / rpcd 以 root 密碼登入(24 字元隨機,約 139 bit,猜不到);ttyd(`@lan`,04 停用)走 `/bin/login` |
| 供應鏈 / 我們自己 | 縮 image、換 CM4、升 busybox | 再次靜默壞掉 | 不依賴外部指令;CI + 真機回歸 |
| 操作員 | 網頁終端機 / ssh 下 `batman-slot commit` | 放行偶爾遺失 | 不受 hangup 影響 |

## 3. 之後的工作會不會取代這次修改

| 後續工作 | 碰到同一塊? | 這次的修改 |
|---|---|---|
| PR-P2(provd、GATT) | 呼叫 claim / replay / reset | 保留:只呼叫 |
| #255 608B | 換節點私鑰、ECDH、CheckMac | 保留:root 密碼雜湊不是 keystore 秘密 |
| CM4 量產、民用 tier | image 內容會變 | 保留,而且是這次改法的理由 |
| PR-P3 / app | 呼叫認領,實作 §7 的 `E_LOCK_INCOMPLETE → replay` | 保留;協定文件這次就寫(§7) |

## 4. 方案比較(hash 的產生)

| 方案 | 依賴 | 判斷 |
|---|---|---|
| A. `openssl passwd -6 -stdin` | ✅ `openssl-util` 現在有,但不是 batman-prov 的依賴(`feed/batman-prov/Makefile:31`) | ✗ 同一類外部依賴 |
| B. busybox 開 `CRYPTPW` | 兩板 firmware config | ✗ 仍是外部指令 |
| **C. Go 實作 SHA-crypt `$6$`** | 標準庫 `crypto/sha512`、`crypto/rand` | **✓** |
| D. `x/crypto/bcrypt`(`$2a$`) | ✅ `x/crypto v0.58.0` 已在 `go.mod`,但 **vendor 只含 chacha20、chacha20poly1305、internal** → 要再 vendor `bcrypt` + `blowfish`;musl 支援 `$2a$` | ✗(可行的次佳) |

**C 而不是 D 的理由**:`$6$` 是 OpenWrt / `openssl passwd -6` / `mkpasswd` 共用的格式,現場人員可以用手邊工具產生或比對(恢復、除錯);bcrypt 有 72 byte 截斷與 `$2a$`/`$2b$` 變體的歷史包袱;C 的正確性由三層外部驗證把關(§11.1、§11.3),原型已過:規格向量 7/7、與 openssl 3.0.13 隨機交叉 200/200(scratchpad 原型,未進 repo)。

驗證端:✅ busybox `USE_BB_CRYPT` 未開 → login 用 musl `crypt()`;dropbear 也是 `crypt()`;musl `crypt_sha512.c:203-207`:KEY_MAX 256、SALT_MAX 16、ROUNDS_MIN 1000、**ROUNDS_MAX 9 999 999(超過直接拒絕)**。

## 5. 設計

### 5.1 `shacrypt` 套件(新,`feed/batman-prov/src/shacrypt/`)
- `Hash512(key []byte, setting string) (string, error)`:**完全照規格**(Drepper)——salt 截斷到 16;`rounds=` 低於 1000 拉到 1000;有 `rounds=` 前綴就輸出 `rounds=`;只有在 musl 會拒絕的情況回 error(rounds > 9 999 999、key > 256 byte、salt 含 `$` 以外的 `:` 或 `\n`),讓我們永遠不產生 musl 驗不過的 hash。
- `New512(password []byte) (string, error)`:salt 16 字元取自 `crypto/rand`(64 字元集整除 256,直接取模無偏差),rounds 預設 5000(輸出不帶 `rounds=`)。輸出自我檢查 `^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$`,不符 → error。
- `realSys.CryptPassword` 改呼叫 `New512`。密碼只在 helper 記憶體。
- 註:Go ≥ 1.24 的 `crypto/rand.Read` 失敗會直接讓程式中止(go.mod `go 1.26.4`),不會回 error;CryptPassword 的錯誤分支只在 fakeSys 測試中可達。

### 5.2 `genPassword` 去掉取餘數偏差
`node.go:369-375`:56 字元集 → `b >= 224` 重抽(224 = 256 − 256 % 56)。長度與字元集不變。

### 5.3 單一上鎖實作 `prov_apply_lock [--hash-stdin]`(`prov-lock.sh`,四個呼叫者共用)
介面明確:**只有帶 `--hash-stdin` 才讀 stdin**(讀一行;沒帶就絕不讀 → 手動執行、tty 上重跑 96 都不會卡住,v2 審查 A-m1 / B-m2)。sh 端驗的是**root 欄的通用格式**:以 `$` 或 `!` 開頭、不含 `:` 與換行(也用於 §5.3 的「還原舊值」);**新產生**的 hash 由 Go 端另外驗 `^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$`。不符 → 回 3、shadow 不動。

**順序「先鎖門,最後才換密碼」**,每一步都檢查 rc;stdout 最後一行 `LOCK <ok|uci|dropbear|shadow> rc=<n>`:

| 步 | 動作 | 失敗時 |
|---|---|---|
| 1 | **所有** `dropbear` section(`dropbear.init:399` 每個 section 一個 instance,v2 A-m3)設 `PasswordAuth=off`、`RootPasswordAuth=off`;system `ttylogin=1`;`uci commit dropbear` + `uci commit system` | 記 rc=1,**仍做第 3 步的「不帶 hash」版本**(把空的 root 變 `!`,v2 B-m1),回 1 |
| 2 | `ubus call service list '{"name":"dropbear"}'` **本身失敗 = 第 2 步失敗**(fail-closed,v2 A-m2);有 instance → `/etc/init.d/dropbear reload` → 再讀回:**每一個** instance 的 command 都必須含 `-s` 與 `-g`;沒有 instance → 略過(啟動時會讀 uci)。契約:讀回只證明 procd 記錄的參數,舊 master 程序由 procd 非同步換掉(✅ 04 2026-10-26:目前一個 instance,未鎖時 command 無 `-s -g`) | 同上:記 rc=2,仍做「不帶 hash」的第 3 步,回 2 |
| 3 | shadow root 欄:`--hash-stdin` 給了合法 hash → 寫 hash;沒給 → 只在目前不是 `$…` / `!…` 時寫 `!`。`mktemp /etc/.shadow.XXXXXX` → 寫 → `chmod 600` → `sync` → `mv` → `sync` | 回 3(rename 原子:舊行不變) |
| 4 | p6 掛著時 `lock-status`:tmp + `mv`,0644 | 只 log(給人看的狀態;不影響 rc) |

**Go 端**:`ApplyLock(hash)` 執行 `sh -c '. /usr/lib/batman/prov-lock.sh && prov_apply_lock --hash-stdin'`,hash 走 stdin,解析最後一行。Go 不再自己寫任何鎖定欄位。

**新的 helper 碼 `ELockIncomplete = 23`**,**只在 p5 已 commit 之後**回(v2 A-M1:`EApply` 也用於 commit 之前的 stage 失敗,`txn.go:21, 26`,意思不唯一)。

**規則(v3 審查 A-M1 / B-M1):claimed / member 的 root 密碼只以 p5 為準。密碼「生效」= 已寫進 p5;helper 只在 `--save` 成功之後才交出密碼。** 理由:S13 每次開機把 live 收斂到 p5(§5.4);若 `--save` 失敗仍交出密碼,下次開機那個密碼就被靜默改回(雙向同步、兩個寫入者)。

| 呼叫者 | 第 1–3 步成功 **且** `--save` 成功 | 第 1–3 步成功、`--save` 失敗 | 第 1 或 2 步失敗(第 3 步只把空的 root 變 `!`) | 第 3 步失敗 |
|---|---|---|---|---|
| claim(commit 之後) | 回 `{tag, adv, pw}` | **不回密碼**,`ELockIncomplete`;**先把 root 欄還原成呼叫前的值**(§5.3 還原規則)| 不回密碼,`ELockIncomplete`;**仍 `--save`**(p5 已是 claimed,不 seed 就不能 OTA) | 同左 |
| claim.replay | 回 `{tag, adv, pw}` | 不回密碼,`ELockIncomplete`(v1 只 log,`node.go:501-503`);先還原 root 欄 | 同 claim | 同左 |
| root_password.reset | 回 `{pw}` | 不回密碼,協定 `E_STORAGE`(密碼沒有生效);先還原 root 欄 | `ELockIncomplete`(密碼沒換),仍 `--save` | 同左 |
| S13 開機補鎖(§5.4) | — | — | log WARN,下次開機再試 | 同左 |
| 96(fresh) | 呼叫同一函式(不帶 hash、`--no-reload`);**依 rc 記錄**:rc ≠ 0 → `LOCKWORD=LOCK-INCOMPLETE`、log `LOCK <step>`(v2 A-m4) | — | 同左 | 同左 |

**還原規則(v4 審查 A-M1 / B-M1)**:helper 在呼叫 `prov_apply_lock --hash-stdin` 之前記下 live 的 root 欄;`--save` 失敗時,**在回錯誤之前**以同一個函式把它寫回(原本是空的 → 寫 `!`,不還原成空)。還原本身失敗 → log CRIT、`lock-status` 寫 `LOCK-INCOMPLETE`。理由:joinwatch 每 15 s 的 `--on-join` 會把 live 的 root 行帶進 p5(fingerprint 含它),若不還原,暫時性的 `--save` 失敗(例如 config-save 的鎖被佔住:`--save` 等 10 s 後回 rc 1 並印「another batman-config-save is writing p5」,✅ `batman-config-save:190-224`)一過,沒交出去的 hash 就成了 p5 的真相。還原後 live == 呼叫前 == p5(或 p5 尚無 shadow-root 而 live 為 `!`),joinwatch 存進去的也是舊值 → **沒交出的密碼不會出現在 live 或 p5**。

**鎖被佔住的交錯(v5 審查 A-m1;B-m1:`--save` 撞鎖是等 10 s 後 rc 1,不是 rc 8——rc 8 只有 `--check` 與 `--prov-*`)**:佔住 config-save 鎖的最常見者是 joinwatch 自己的 `--on-join`;若它在第 3 步之後才 stage,會把**新** hash 存進 p5,同時 helper 拿到 rc 8 而把 live 還原成舊值。對策:(1)helper 的 `--save` 遇到「撞鎖」(rc 1 + 上述訊息)**只重試一次**(每次 config-save 內部已等 10 s;helper 在 `n.mu` 底下最多約 20 s,其他動詞排隊——列入 provd / app 的 timeout 預算,PR-P2);(2)仍失敗 → 還原 live 之後**再盡力跑一次 `--save`**,讓 p5 跟上已還原的 live。殘留窗口(誠實界線,v5 B-m2):joinwatch 在 helper 寫入新 hash 之後才讀 shadow 時,p5 會短暫是新 hash、live 是舊的;根治要讓「寫 shadow + `--save`」在同一把鎖底下完成(擴大範圍,不做,列 §13)。殘留窗口:重試與補存都失敗,且在下一個 joinwatch tick(15 s)前就重開 → S13 會把 live 收斂成 p5 裡那個未交出的 hash;恢復路徑 = replay(claim)或重新 reset,`lock-status` 為 `LOCK-INCOMPLETE` 可見。

**操作員手動 `passwd`**:改完要 `batman-config-save --save` 才算數;已入網的節點由 joinwatch 每 15 s 的 `--on-join` 自動帶進 p5(✅ `joinwatch:141-150`;fingerprint 含 shadow 的 root 行,`batman-config-save:273`);沒入網或改完 15 s 內就重開 → 下次開機被 S13 改回 p5 的值。寫進操作說明。

**為什麼不選「S13 只補空的 root」**(審查 A 列的另一個選項):legacy 節點認領後 rollback 到認領前的槽,live 是操作員的 hash,S13 不動它;joinwatch 15 s 後把它存回 p5 → 蓋掉 app 的密碼,整台失效。以 p5 為準就不會發生。

**96 的 fallback**(`96:65-73`,只在 `prov-lock.sh` 缺的時候用)是唯一不走單一實作的例外;改成至少「空 root → `!`」並記 `LOCK-INCOMPLETE`(v3 B-m2)。

**為什麼這個順序**:shadow 是最後一步,所以「shadow 已換、卻沒人知道新密碼」不會發生(v1 A-M1、B-M4)。代價(寫明,v2 A-m8):unclaimed 認領時,從第 1 步寫入 `ttylogin=1` 到第 3 步寫入 hash 之間(或第 3 步本身失敗,例如 ENOSPC),root 仍是空的;busybox login 遇到空密碼欄直接放行(✅ `login.c:515`),序列埠在這段時間仍免密碼。這不是回歸:認領前本來就開著。第 1/2 步失敗時第 3 步把空 root 改成 `!`,所以不會一直開著。

**持續失敗的死路(接受,fail-secure)**:若 1–2 步每次都失敗(例如 overlay 滿),replay 也一直 `ELockIncomplete`。unclaimed 認領不要求 ssh key(`node.go:413-418` 只檢查 legacy),S13 讓 root 變 `!` → 沒有密碼、沒有 key → 只能重燒卡(U8 的轉賣工具)。理由:另一個選擇是讓已認領的節點維持開放,違反 fail-secure。**CM4 eMMC** 量產機沒有 SD 卡,重燒要 rpiboot,轉賣工具目前只寫讀卡機 → 列 #254 殘項。

### 5.4 開機補鎖:新 init `batman-prov-lock`(START=13,`batman-provision`)
- **時機**:S11 掛 p6、S12 faketime 之後,**S18 keyguard、S19 dropbear 之前**,所以 dropbear 一啟動就讀到鎖定的 uci,不需要 reload(✅ `batman-faketime:3-9` 的順序註解、dropbear START=19)。不放在 helper:helper 每次 respawn 都跑 `boot.Run`(✅ `main.go:392`、`batman-provhelper.init:13` `respawn 3600 5 0`),會變成持續覆寫(v1 審查 A-M3、B-M2)。
- **判斷依據 = p5(擁有權的真相來源),與 96 用同一個決策函式**(v2 A-M3 / B-M1:overlay 的 meta 與 p6 在「認領後沒重開就 rollback」「overlay 寫失敗」時都是舊的):
  1. 以 `ro,noload` 掛 p5(同 gate 的寫法,✅ `batman-slot:540-544`;S13 時沒有其他程序用 p5)→ `prov_meta_status $m/prov.meta $m/prov.cbor`;
  2. `prov_lock_decision <p5 讀得到 0|1> <status> <state> <p6 last_known_state> [any]`(✅ 96 用的同一個函式)。**新的第 5 個參數 `any`**(S13 帶,96 不帶):p5 讀得到時,只要 p5 **或** p6 任一邊是 claimed / member 就 LOCK,兩邊矛盾時 log(v3 A-m1:`ro,noload` 不重播 journal,斷電在 config-save umount 前時 p5 可能讀到舊的 meta);
  3. p5 讀不到 → 依 p6 `last_known_state`(該函式本來的行為)。
- **p6 `last_known_state` 跟上**:helper 在 claim / replay **commit 成功後**立刻更新 p6 prov-state,**只改第 3 欄**,其他欄(含 autocommit OTA gate 讀的第 6 欄 `mesh_expect`)原樣保留;tmp + rename,0600(✅ 格式 `boot.go:276-301`;今天寫它的 `boot.Run`、99zz、`applyNet` 都在 helper 內,序列化)。
- **動作**:LOCK →
  - **收斂 root 只在以下條件全成立時做**:p5 的狀態是 `ok claimed` 或 `ok member`(不是只看 meta 是否 ok,v4 A-m2:在 `any` 規則下 p5 為 unclaimed、p6 為 claimed 也會判 LOCK,此時 p5 可能留著前一任擁有者的 shadow-root——config-save 用 `cp -a`、從不刪檔——不能裝到轉賣後的節點上;這種矛盾只維持一次開機,S89 `boot.Run` 之後 p6 就跟上 p5);p5 與 overlay 的 identity 相同(與 config-save 的 identity_mismatch 判斷一致,v3 A-m4);p5 有合法的 `identity/shadow-root`(`root:$6$…`,同 96);且與 live 的 root 欄不同 → 經 `--hash-stdin` 交給 `prov_apply_lock --no-reload`;
  - 否則 `prov_apply_lock --no-reload`(不帶 hash;空 root → `!`)。
  - 已鎖且 root 已等於 p5 → 不寫(冪等)。TODAY → 不動(legacy、unclaimed、dev-open 行為不變)。
  - `--no-reload`(新旗標,96 與 S13 帶):明確跳過第 2 步(dropbear 還沒啟動,不靠 ubus 判斷,v3 A-m3)。
  - 結果寫一行 log;stdin 一律 `</dev/null`(rcS 已如此,✅ `procd rcS.c:97-98`)。
  - crash loop:每次開機都 ro 掛一次 p5(不寫入);掛不上 → 依 p6(v3 B-m4)。
- **誠實界線**:procd 在 rcS 之前就啟動 askconsole(✅ `procd state.c:160-166`),login.sh 在使用者按 Enter 的那一刻才讀 `ttylogin`。只有在「上一次上鎖連 uci 都沒寫成」的那一次開機,S13 之前按 Enter 的人才拿得到 root shell。實體接觸在階段 1 本來就能拔卡改 rootfs(§2),這個窗口不增加能力;不改上游 `login.sh` / inittab(overlay 蓋上游不耐久,#264 教訓)。**CM4 eMMC** 量產機沒有卡可拔,這個前提較弱(要 rpiboot + USB),列殘項,到 CM4 時重評。

### 5.5 `addr_defer_release` 改寫
`batman-slot:750` 改為在**父程序 fork 之前**忽略 HUP:
```sh
trap '' HUP
env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin setsid /etc/init.d/openmanetd start </dev/null >/dev/null 2>&1 &
trap - HUP
```
子程序 fork 時就繼承 SIG_IGN,跨 exec 保留(ash 只重設有自訂 handler 的訊號),所以 fork 到 `setsid()` 之間沒有窗口(v1 審查 A-M5:子 shell 內的 trap 仍有窗口)。✅ batman-slot 只有 EXIT trap(`:157`),沒有 HUP trap 會被 `trap - HUP` 蓋掉。openmanetd 由 procd fork,不繼承;openmanetd init 的 hook(`batman-addr-defer`)會繼承 SIG_IGN,無害。

## 6. 擁有權

| 資源 | 唯一實作 | 呼叫者(時機互斥) | 只讀 |
|---|---|---|---|
| shadow root 行、dropbear `PasswordAuth`/`RootPasswordAuth`、`system.ttylogin`、p6 `lock-status`(鎖定方向) | `prov_apply_lock` | 96(uci-defaults,S10 內)→ S13 `batman-prov-lock` → helper(S89 之後,claim / replay / reset;`n.mu` 序列化,✅ `node.go:138`) | login、dropbear、config-save、halow-status |
| 同上(**解鎖 / 今天規則**方向) | 96 `lockdown_today`(legacy、fresh) | 96 | — |
| shadow root 行(操作員) | `passwd`(legacy 節點的操作員) | 人 | — |
| p5 `.seeded`、`identity/shadow-root` | `batman-config-save --save` | helper、joinwatch、操作員 | 96 |
| p5 prov | `--prov-only` | helper commit | 96、gate、S13(ro 掛 p5) |
| p6 prov-state `last_known_state` | helper(`boot.Run`、99zz、applyNet,**新增:claim / replay commit 之後**,只改第 3 欄) | helper 內序列化 | 96、S13、autocommit(第 6 欄) |
| **root 行的同步方向**:claimed / member 時 **p5 → live**(S13,每次開機一次);**live → p5** 只經 `--save` / `--on-join` | p5 是唯一真相;helper 只在 `--save` 成功後交出密碼(§5.3);`passwd` 未存進 p5 → 下次開機被改回 | S13 在 joinwatch、helper 啟動前跑完,與 live → p5 的寫入在時間上互斥 | — |

claimed / member 節點上,這幾個鍵在**每次開機**被 S13 收斂到鎖定、root 收斂到 p5 的 shadow-root;執行期別人改了(例如測試),到下次開機才會被改回 — 測試不得切換它們(§11.3 改用不碰 uci 的驗法)。Go `ApplyLock` 不再自己寫任何欄位。

## 7. 契約


| 介面 | 寫 / 讀 | 格式 | 缺 / 壞 |
|---|---|---|---|
| `prov_apply_lock [--hash-stdin]` | §6 呼叫者 | 帶旗標才讀 stdin 一行 hash(sh 端驗格式);stdout 最後一行 `LOCK <ok\|uci\|dropbear\|shadow> rc=<n>`;rc 0 = 第 1–3 步都成功 | `prov-lock.sh` 與 helper、S13 同包出貨(`batman-provision`;batman-prov 依賴它),實務上必定存在;缺 → helper 回 `ELockIncomplete`(不回密碼)、S13 log。執行期沒有其他備援(96 只在 fresh overlay 跑),寫明 |
| helper 碼 → 協定碼(provd 對應,PR-P2 實作;本次寫進協定) | helper → provd → app | helper `ELockIncomplete`(23)→ 協定 **13 `E_LOCK_INCOMPLETE`**:「已 commit,上鎖未完成 → 以 `psk_replay` session 走 `claim/replay`」(claim / replay);reset 時 = 「密碼沒換,可重試」。commit **之前**的失敗(helper `EApply` / `EStorage`)→ 協定 `E_CLAIM_FAILED`(9)/ `E_STORAGE`(10),維持「不說明原因」 | `219-protocol.md` §5.2 加碼 13、§5.3 寫 claim/finish 與 claim/replay 的語意、CDDL 向量各一;目前沒有 app,無相容問題。單元測試證明:stage 失敗 → 非 23;commit 後上鎖失敗 → 23 |
| claim / replay / reset 成功回應 | 同上 | `{1: tag, 2: adv, 3: pw}` / `{1: pw}` | — |
| p5 `prov.meta` / `prov.cbor` / `identity/shadow-root`(S13 ro 讀) | helper(`--prov-only`)/ config-save | `prov_meta_ok`;shadow-root `root:$6$…` | meta 壞 → LOCK(fail-secure,同 `prov_lock_decision`);shadow-root 不合法 → 不帶 hash 上鎖(空 → `!`);p5 掛不上 → 依 p6 last_known_state |

## 8. 生命週期矩陣

| 路徑 | 今天 | 修正後 | 測試 |
|---|---|---|---|
| 首次開機(新卡,unclaimed) | 不鎖 | 不變(S13 判 TODAY) | 鏈 1 第 5 步 |
| 認領 | 不鎖、假密碼、不 seed | 鎖、密碼可用、seed、p6 last_known=claimed | `prov-claim-254`(tier B);鏈 1 第 8.3 步 |
| 認領時上鎖失敗(第 1–2 步 / 第 3 步) | 回成功 + 假密碼 | `ELockIncomplete`、`--save`、空 root → `!` | fakeSys + CI loop 對每一步注入 |
| replay / reset | 一定 `E_APPLY` | 成功 | `prov-claim-254` replay 段;reset 以 socket 測試 |
| 重開機(已認領,上鎖曾失敗或被改掉) | 一直不鎖 | S13 在 dropbear 前鎖、root 收斂到 p5 | §11.4 |
| **認領後沒重開就 rollback 到另一槽(同版本)**(v2 B-M1) | — | 另一槽開機時 S13 讀 p5 = claimed → 鎖、root 換成 p5 的 hash(app 的密碼有效) | §11.5:04 上 claim → `batman-slot rollback` → reboot → 斷言 LOCKED + probe MATCH;負對照 = v2 寫法(只看 overlay)|
| **overlay 寫失敗**(p5 已 commit,`txn.go:36-39`)(v2 A-M3) | — | 下次開機 S13 讀 p5 → 鎖 | §11.4 的注入變體:helper 寫 overlay 前 bind 一個唯讀目錄 → 重開一次 → 斷言鎖 |
| helper respawn / crash loop | — | 不補鎖(S13 才補);claim 中途 crash:commit 已寫 → replay 接手 | 程式審查 + 既有 L34 killpoint |
| clean stop / dropbear 重啟 | — | dropbear 重啟讀已鎖 uci | §11.4 讀回 |
| OTA(已認領) | gate 擋 | 可 OTA;fresh overlay 由 p5 shadow-root 還原、96 鎖定 | 鏈 1 第 8.6 步 |
| reset 時 `--save` 失敗(暫時性)→ joinwatch 照常 → 重開 | — | 不回密碼(`E_STORAGE`);helper 先把 root 欄還原 → joinwatch 存進 p5 的仍是舊值 → 重開後 app 手上的舊密碼仍有效 | §11.4b(一次性 lock-busy 注入、joinwatch 不停);負對照 = v4 寫法(不還原)以白箱 variant 跑:p5 shadow-root 的 sha 變、舊密碼 NOMATCH |
| `passwd` → 重開 | — | 已入網:15 s 內進 p5,保留;沒進 p5 → 改回 | 真機:停 joinwatch → `passwd` → 重開 → 改回;`--save` 後重開 → 保留 |
| `batman-slot rollback`(claimed / member)到**不能維持鎖定的版本**(例如 1.5.13) | — | **拒絕**(v3 B-m3,這次就做):rollback 前 ro 掛目標槽 rootfs(squashfs),`/etc/init.d/batman-prov-lock` **與** `/etc/rc.d/S13batman-prov-lock`(已啟用)兩者缺一 → die「target slot cannot keep this claimed node locked」;覆寫 `BATMAN_ALLOW_UNLOCKED_ROLLBACK=1`(操作員明示)。這兩個路徑是介面(§7),CI lint 斷言 image 內兩者都在 | 真機:claimed + 目標槽 1.5.13 → 拒絕;覆寫 → 放行;legacy → 不擋。改到兩板共用的 batman-slot → 兩板 CI(bcm2710 只 build) |
| tryboot 試跑失敗的**自動退回**(不經 `batman-slot rollback`) | — | 試跑期間會改狀態的動詞(含 claim)一律 `E_BUSY`(✅ `node.go:161-162` `IsTrial`),所以已認領的節點不會在試跑中產生 → 自動退回不會讓已認領節點落到沒有 S13 的舊槽(推論,依此證據) | 既有 `prov-p1` 的 trial `E_BUSY` 測項 |
| 還原本身失敗(`--save` 失敗後寫回舊 root 欄也失敗) | — | 不回密碼;log CRIT;`lock-status` = `LOCK-INCOMPLETE`;live 留著未交出的 hash,joinwatch 可能把它存進 p5 → 恢復路徑只有 replay(claim)或重新 reset(v5 A-m2) | fakeSys 注入「還原失敗」→ 斷言 CRIT log、`LOCK-INCOMPLETE`、不回密碼 |
| 降版 OTA 到沒有修改的版本 | — | fresh overlay:舊 96 依 p5 claimed → 鎖 | ✅ 原始碼(舊 96 也呼叫 `prov_apply_lock`) |
| 斷電 | — | shadow:tmp + sync + mv + sync;uci commit 中斷 → S13 下次開機補 | ⚠️ 只做乾淨重開;真斷電列殘項 |
| 每個平台 | — | bcm2711 實測;bcm2710(P-U14)只 build;CM4 無硬體 | PR body 兩節 |

## 9. 依賴的證據

| 假設 | 證據 |
|---|---|
| login / dropbear 驗 `$6$` 用 musl `crypt()`,且接受我們產生的 hash | ✅ `.config` `USE_BB_CRYPT` 未開;✅ 04 2026-10-26:static musl probe(toolchain musl 1.2.5 = 節點 `/lib/libc.so` 「Version 1.2.5」)對 Go 原型產生的 hash(預設 rounds、`rounds=12345`)→ MATCH,錯密碼 → NOMATCH;openssl 產生的同樣 MATCH |
| image 沒有 cryptpw / mkpasswd | ✅ `.config`、04 `command -v` |
| musl 的 `$6$` 規則 | ✅ `musl-1.2.5/src/crypt/crypt_sha512.c:203-207, 265, 273` |
| dropbear 只在啟動時組 `-s -g`;`uci commit` 不觸發 reload;每個 section 一個 instance | ✅ `dropbear.init:322-327, 399, 406`;✅ 04 `ubus call service list`:一個 instance,未鎖時 command 無 `-s -g` |
| helper 每次 respawn 都跑 `boot.Run` | ✅ `main.go:392`、init `respawn 3600 5 0` |
| procd 在 rcS 前跑 askconsole;rcS 的 stdin 是 /dev/null | ✅ `procd state.c:160-166`、`rcS.c:97-98` |
| busybox login 遇到空密碼欄直接放行 | ✅ `busybox-1.36.1/loginutils/login.c:515`(審查 A);⚠️ 真機未試 |
| dropbear 沒有 `-B` 時拒絕空密碼 | ✅ 上游 `svr-authpasswd`(審查 B);⚠️ 真機未試 |
| 96 對 claimed 鎖定、shadow-root 只要 `root:$…` | ✅ `prov_lock_decision`、`96:99-108, 182-190` |
| prov-state 的寫入者沒有 claim | ✅ `boot.go:60, 276-301`、`main.go:298`(審查 A / B) |
| `--save` 在 root 無 hash 時仍 seed | ✅ `batman-config-save:503, 513`;⚠️ 真機在鏈 1 驗 |
| batman-slot 沒有 HUP trap | ✅ `batman-slot:157` 只有 EXIT |
| S13 時序 | ✅ rc.d:`S11` batdata-mount、`S12` faketime / log / rpcd、`S13` openssl、`S18` keyguard、`S19` dropbear(審查 B);keyguard 只動 wireless(`halow-keyguard:22-38`) |

## 10. 安全
- **資產**:節點 root、擁有權。**攻擊面變化**:新 init(root,開機一次,只讀 p5 / p6 / overlay,無外部輸入);`prov_apply_lock --hash-stdin`(只有 helper 帶,root)。
- **權限**:全部 root;暫存檔 `mktemp` 在 `/etc`(root 0755,非特權不能建檔)→ 沒有 symlink / 可預測檔名問題。`prov-lock.sh` 在 squashfs。
- **秘密**:密碼只在 helper 記憶體與回應中;hash 經 stdin(不經 argv);shadow 0600、p5 shadow-root 0600。
- **fail-secure**:上鎖失敗 → 不回密碼、空 root 變 `!`;已認領 → 每次開機 S13 依 p5 鎖門。
- **負面測試(每一項都要能分辨新舊,v2 A-M2 / B-M2)**:
  - ssh:以 `ssh -v -o PreferredAuthentications=none` 讀 server 的 `Authentications that can continue:` → 必須**只有** `publickey`(未鎖時是 `publickey,password`);並以**已知測試密碼**實際嘗試 password 登入 → 被拒。
  - 序列 / login:musl probe 對 shadow 的 hash 與回傳的密碼 → MATCH(錯密碼 → NOMATCH)。
  - 補鎖:白箱寫入**已知測試 hash** + 解鎖 → 重開 → 被鎖回;舊 image 上同樣步驟 → 仍可用該密碼 ssh 登入(負對照成立的前提:不是空密碼)。

## 11. 測試與驗證(全部進常規全套;harness PR 先進 main)
空結果、0 次執行、工具不在 → 一律 FAIL。
1. **CI 單元 `shacrypt`**:Drepper 規格向量(含 `rounds=` 下限、長 salt 截斷、多行 key)+ musl 自帶自測向量;與 `openssl passwd -6 -salt`(**只涵蓋預設 rounds**)隨機交叉 200 組(可印字元、無換行、key ≤ 256);第三方再比 busybox `mkpasswd -m sha512`(CI 沒有 → FAIL,不 skip)。**突變負對照自動化**:同一組向量跑一個故意換錯 permutation 表 / rounds 迴圈的 variant,必須 FAIL。
2. **CI 單元 node / helper**:fakeSys 注入第 1、2、3 步失敗 → claim / replay / reset 回 `ELockIncomplete`、不回密碼、`Save` 被呼叫;**`Save` 失敗 → claim / replay 回 `ELockIncomplete`、reset 回 `E_STORAGE`,都不回密碼,且 root 欄被還原成呼叫前的值(空 → `!`)**;stage 失敗 → 不是 23;claim 成功後 p6 last_known_state = claimed;`genPassword` 分布(卡方)。**CI loop 跑 `prov_apply_lock`**(假 uci / 假 ubus,同 `tests/prov-p1`):步驟順序、每一步 rc、沒帶 `--hash-stdin` 時不讀 stdin(stdin 接一個永不結束的管線也立即返回)、不合法的 root 欄被拒、多個 dropbear section 都被鎖。**CI loop 跑 S13**:p5 claimed / member / bad / unclaimed / legacy / 掛不上 × p6 各值 × overlay 舊或新 × identity 相同或不同 → LOCK / TODAY 與 shadow 是否收斂(p5 unclaimed + p6 claimed → 鎖但不收斂)。
3. **真機 tier B `prov-claim-254`**(修正版):LOCKED、` pw=off `、`rootpw=off`、`tty=1`、shadow `$6$`、server 只提供 `publickey`、port 22 `none` → `Permission denied`;publickey 經 2222 臨時 listener(`dropbear -s -g -p 2222`,nft 暫時規則,測完刪除並斷言已刪)證明;**musl probe**(`tools/cryptprobe`,static,與 firmware pin 同次 build;harness 斷言 toolchain musl 版本 == 節點 `/lib/libc.so` 版本,不同 → FAIL;測完刪除 binary 並斷言)MATCH / NOMATCH;replay 段;還原 S0。**負對照**:1.5.13-wsl.1 上同一測試 FAIL(2026-10-26 已取得)。
4. **S13 補鎖(tier B)**:認領後白箱寫入**已知測試 hash** + 解鎖(uci set + commit)→ `batman-slot reboot committed` → uci 鎖、dropbear 每個 instance command 含 `-s -g`、server 只提供 `publickey`、以測試密碼 password 登入被拒、root 收斂到 p5 的 hash(probe 以 app 的密碼 MATCH)。**注入變體**(overlay 寫失敗):`mount --bind -o ro` 一份 `/etc/batman-prov` 的副本蓋在原位,trap 保證 umount,claim → 重開一次 → 鎖,還原後斷言 bind 已不在。**負對照**:舊 image(無 S13)同樣步驟 → 測試密碼仍可 ssh 登入。**副作用與還原**(破壞性測試,先列):p5 `identity/shadow-root` 可能被 joinwatch 存進測試 hash → 測試前記 p5 shadow-root sha、測試中停 joinwatch、測試後比對並以快照還原;uci / shadow / overlay 由 prov-base 快照還原並 compare;bind mount 隨 trap 與重開消失。
4b. **`--save` 的暫時性失敗**(tier B,白箱,claim 與 reset 各一次):注入點 = 讓 config-save 的鎖被佔住一次(重用 `prov-base-254.sh` 的 lock holder:`$RUNDIR/cfgsave.lock` + 名稱含 `batman-config-save` 的持有程序,✅ `prov-base-254.sh` `lock_take`),helper 的 `--save` 因此等 10 s 後回 rc 1(「another batman-config-save is writing p5」,✅ `batman-config-save:190-224`);放開鎖後 **joinwatch 照常執行**。斷言:**helper 那次 `--save` 確實失敗過**(helper log 的 save rc 與回應碼;沒走到注入點 → FAIL,v5 B-m3);不回密碼(claim `ELockIncomplete` / reset `E_STORAGE`);live 的 root 欄 == 呼叫前;**等 ≥ 30 s**(兩個 joinwatch tick)後 p5 shadow-root 的 sha 不變;重開 → probe 以 app 手上的舊密碼 MATCH。負對照:不還原的 variant(v4 寫法,白箱)→ p5 sha 改變、舊密碼 NOMATCH。副作用:lock holder 由 trap 結束並斷言鎖已釋放;p5 以快照還原並 compare。
4b'. **joinwatch 自己佔鎖的交錯**(v5 A-m1):以白箱讓 joinwatch 的 `--on-join` 在 helper 第 3 步之後、`--save` 之前取得鎖(在 config-save 的 stage 點插入一次性延遲,trap 還原)→ 斷言 helper 重試 / 補存之後 p5 shadow-root 的 sha 等於呼叫前、probe 以舊密碼 MATCH;負對照 = 無重試、無補存的 variant → p5 留著未交出的 hash。
4c. **`passwd` 未存進 p5 → 重開被改回**:停 joinwatch → `passwd`(已知測試密碼)→ 重開 → probe 對測試密碼 NOMATCH、對 app 密碼 MATCH;`--save` 後重開 → 保留。
4d. **rollback gate**:claimed 節點、目標槽為 1.5.13 → `batman-slot rollback` 拒絕(訊息與 rc);`BATMAN_ALLOW_UNLOCKED_ROLLBACK=1` → 放行(隨即 rollback 回來);legacy 節點 → 不擋。負對照:1.5.13 的 batman-slot 不擋。
5. **認領後 rollback**:claim → 不重開 → `batman-slot rollback` → reboot → 斷言另一槽 LOCKED、probe 以 app 的密碼 MATCH;負對照 = 只看 overlay 的判斷(v2 寫法)以白箱 variant 跑,不鎖。
6. **鏈 1**(chain1-254 v3,兩位審查 APPROVE-WITH-CHANGES)在 rc 上完整跑:8.3 LOCKED + seeded、8.6 claimed OTA 落 A trial 並鎖定、8.7 負對照。
7. **PTY**:`setsid-race` 加兩個變體——「產品新寫法」(父程序先 `trap '' HUP` 再 fork)與「新寫法 + fork 到 setsid 之間插延遲迴圈」;後者必須 N/N(同樣插延遲的舊寫法 0/N 是負對照);N ≥ 100,含 CPU 負載。端到端 `pty-commit` 只當 smoke(分不出新舊,§1.2)。
8. **reconcile**(已過)與以上全部接進 daily-validation;rc 上跑全套。

## 12. PR 切法
1. **harness PR**(先進 main):`prov-claim-254`(修正:推 allowlist、manifest 撞 p5 rw 掛載重試、`pc()` coproc 關閉、2222 publickey 證明、server auth 方法、musl probe、replay 段)、`addr-defer-reconcile-254` + runner、`pty-commit-254`、`setsid-race-254`、`chain1-254`、S13 補鎖與 rollback 測試、`tools/cryptprobe` 與建置腳本、daily-validation 接線;對 1.5.13 的預期 FAIL 進 `validation-known-failures.txt`(格式沒有到期欄位 → **產品 PR 的 checklist 寫明刪除這幾條**)。
2. **產品 PR**:`shacrypt`、`CryptPassword`、`genPassword`、`prov_apply_lock` 改寫 + Go `ApplyLock` 改呼叫它、`ELockIncomplete` 與 claim / replay / reset 失敗語意、claim / replay 寫 p6 last_known_state、`batman-prov-lock`(S13)、`prov_lock_decision` 的 `any` 參數、`--no-reload`、96 依 rc 記錄與 fallback、`batman-slot rollback` gate、`addr_defer_release`、`219-protocol.md` §5.2 / §5.3 與 CDDL 向量。改到兩板共用檔 → PR body `### bcm2711` / `### bcm2710`。
3. **firmware pin**:rc → 04 → 02/04 全套 → merge → 出貨 image 驗收。

## 13. 殘項(寫進 #254 checklist,不排程)
- 互動 shell(有 job control)下 commit 到一半關視窗。
- 真斷電。
- CM4 eMMC:重燒路徑(rpiboot)與序列埠誠實界線的前提。
- LuCI / rpcd 以 root 密碼登入、ttyd(#137 範圍)。
- 「寫 shadow + `--save`」在同一把 config-save 鎖底下完成(消除 joinwatch 晚讀 shadow 的短暫不一致,v5 B-m2)。

## 14. 審查摘要與處理
**v5(A:APPROVE-WITH-CHANGES 0 / 0 / 2;B:APPROVE-WITH-CHANGES 0 / 0 / 3)** — **設計核准**
- A-m1(鎖由 joinwatch 自己的 `--on-join` 佔住的交錯):撞鎖只重試一次 + 還原後補存;殘留窗口寫明;§11.4b'。A-m2(還原失敗):§8 一列 + fakeSys 測試。
- B-m1(撞鎖是 rc 1 不是 rc 8):全文改正,helper 的等待時間列入 timeout 預算。B-m2(joinwatch 晚讀 shadow 的短暫不一致):寫成誠實界線 + §13 殘項。B-m3(注入要斷言 helper 的 `--save` 確實失敗過):§11.4b。rollback gate 維持檔案存在檢查(B 接受);能力標記檔留作改進。

**v4(A:APPROVE-WITH-CHANGES 0 / 1 / 4;B:REJECT(窄)0 / 1 / 4)**
- A-M1 / B-M1(`--save` 失敗後 live 留著未交出的 hash,joinwatch 會把它帶進 p5):§5.3 還原規則;§8、§11.2、§11.4b(一次性 lock-busy 注入、joinwatch 照常、≥ 30 s 後比 p5 sha)。
- MINOR:收斂只在 p5 `ok claimed` / `ok member`(A-m2;p5 unclaimed + p6 claimed 只鎖不收斂);rollback gate 同時檢查 init 檔與 `rc.d/S13` 啟用、兩者列為介面並 lint(A-m3 / B-m4);tryboot 自動退回的推論與證據(A-m3 / B-m3);§11.2 的 reset 預期改正(B-m1);§11.4b 寫明注入點(B-m2);A-m1、A-m4 隨 M1 修好而消失。

**v3(A:APPROVE-WITH-CHANGES 0 / 1 / 6;B:REJECT(窄)0 / 1 / 5)**
- A-M1 / B-M1(root 行雙向同步、`--save` 失敗仍交出密碼會在下次開機被改回):§5.3 新規則「claimed / member 的密碼只以 p5 為準;`--save` 成功才交出密碼」;reset 的 `--save` 失敗回 `E_STORAGE`;`passwd` 的行為寫明;§6 加同步方向一列;§8、§11.4b、§11.4c。選擇理由(不選「S13 只補空 root」)寫在 §5.3。
- MINOR:`prov_lock_decision` 加 `any` 參數(p5 或 p6 任一 claimed 就鎖,A-m1);p6 寫入契約只改第 3 欄(A-m2);`--no-reload`(A-m3);identity 不一致不收斂(A-m4);破壞性測試列 p5 shadow-root 的副作用與還原(A-m5);§6 補 S13 寫入者(A-m6);收斂只在 meta ok(B-m1);96 fallback 例外寫明並修空 root(B-m2);**rollback gate 這次就做**(B-m3,§8、§11.4d);crash loop 一列(B-m4);注入變體寫明 bind ro + trap(B-m5)。

**v2(A:APPROVE-WITH-CHANGES 0 / 3 / 8;B:REJECT(窄)0 / 2 / 6)**
- A-M1(協定契約送不到、`EApply` 意思不唯一):新 helper 碼 23 `ELockIncomplete`(只在 commit 後)→ 協定碼 13 `E_LOCK_INCOMPLETE`;commit 前的失敗照協定 `E_CLAIM_FAILED` / `E_STORAGE`;§7、§11.2。
- A-M2 / B-M2(補鎖測試分不出新舊):已知測試 hash + server 提供的 auth 方法;§10、§11.4。
- A-M3 / B-M1(S13 的輸入是舊的:未重開就 rollback、overlay 寫失敗):S13 改讀 p5、用 96 的同一個決策函式;root 收斂到 p5 的 shadow-root;claim / replay 寫 p6 last_known_state;§5.4、§8、§11.4–11.5。
- MINOR:`--hash-stdin` 明確旗標 + sh 端驗格式(A-m1 / B-m2);ubus 失敗 = 第 2 步失敗、讀回的限度(A-m2 / B-m6,附 04 真機輸出);所有 dropbear section(A-m3);96 依 rc 記錄(A-m4);rollback 到 1.5.13 殘項(A-m5);probe 的 libc 版本斷言與刪除(A-m6 / B-m3);`/etc` 0755(A-m7 / B-m5);序列埠窗口寫明、第 1/2 步失敗仍把空 root 變 `!`(A-m8 / B-m1);2222 listener 參數(B-m4);CM4 eMMC 前提(A 本輪附註)。

**v1(A:REJECT 1 / 5 / 8;B:REJECT 0 / 4 / 9)**
- A-B1 / B-M1:§5.4 改 S13(dropbear 之前);A-M1 / B-M4:「先鎖門最後換密碼」;A-M2:單一實作 + `mktemp`;A-M3 / B-M2:補鎖移出 helper;A-M4:協定語意(v2 再修);A-M5:父程序 fork 前 trap;B-M3:musl probe 取代暫開 RootPasswordAuth;MINOR 見 v2 文件 §14(git 歷史)。
