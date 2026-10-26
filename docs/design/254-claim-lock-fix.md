# Design: #254 認領後的上鎖修正 + commit 放行的 PTY 競態 — v8(核准)

**狀態**:**v8 = 核准版**(第 3 輪 A APPROVE-WITH-CHANGES 0 / 0 / 7、B APPROVE-WITH-CHANGES 0 / 0 / 6,MINOR 已併入)。v7 兩位都 REJECT(窄,0 BLOCKER;A 4 MAJOR、B 3 MAJOR)。v6 之後的變更如下。
- **產品變更**(§5.3,真機測試審查 A-M6):busybox `passwd` 預設產生 `$5$`,但 S13 收斂只認 `$6$`。
  - v8 新增 `prov_root_hash_ok`(`$1$` / `$5$` / `$6$` 格式正確),只用在 S13 收斂與 `--hash-stdin`。
  - config-save 與 96 判斷「不是開放」的 `$…` **維持原狀**。v7 把「拒收 `$1$`」擴大到這兩處,會讓 legacy 節點在 OTA 後變開放,所以撤回。
- **重寫真機測試計畫 §11.4–11.5**:依真機測試的兩份審查,原本有三處走不到要測的路徑:4b 的注入點、4 的 overlay 寫失敗注入變體、4b' 的負對照。
  - v8 再修 on-join 證據、trap 的槽位程序、`full` 模式的前置條件。

之前:v6 的 v5 兩位 APPROVE-WITH-CHANGES、0 MAJOR,MINOR 已併入。v4:A APPROVE-WITH-CHANGES 0 / 1 / 4、B REJECT(窄)0 / 1 / 4(同一個 MAJOR);v3:A APPROVE-WITH-CHANGES 0 / 1 / 6、B REJECT(窄)0 / 1 / 5(同一個 MAJOR);v2:A APPROVE-WITH-CHANGES 0 / 3 / 8、B REJECT(窄)0 / 2 / 6;v1 兩位都 REJECT(摘要見 §14)。
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
介面明確:**只有帶 `--hash-stdin` 才讀 stdin**(讀一行;沒帶就絕不讀 → 手動執行、tty 上重跑 96 都不會卡住,v2 審查 A-m1 / B-m2)。**新產生**的 hash 由 Go 端另外驗 `^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$`。

sh 端怎麼驗:
- `--hash-stdin`(要**寫入**一個 hash):必須通過 `prov_root_hash_ok`(見下)。
- `--restore-stdin`(把呼叫前的舊值寫回):原樣接受 `$…` 或 `!…`,其他一律寫 `!`(同 Go 端 `RestoreRoot`,`main.go:167-175`)。
- 不符 → 回 3,shadow 不動。

**兩個問題,兩個判斷(v8,真機測試審查 v7 A-M1 / B-M1)**:四個地方問的其實是兩件事,v6 的 bug 出在把兩者混用。
1. **「這是不是可以收斂、可以寫入的 hash?」**:`prov_root_hash_ok <field>`,新函式,放在 `prov-lock.sh`。只用在兩處:**S13 收斂**、**`prov_apply_lock --hash-stdin`**。
2. **「操作員設過密碼了嗎,也就是不是開放?」**:`$…` 前綴,**維持原狀**。用在 config-save stage(`batman-config-save:406`)、96 從 p5 還原(`96:190`)、96 的 `has_pw`(`96:87`)、`prov_apply_lock` 不帶 hash 時保留現值(`prov-lock.sh:133`)。

`prov_root_hash_ok` = musl `crypt()` 驗得了、且是正常工具產生的格式,只拒絕格式壞掉的值(✅ `musl-1.2.5/src/crypt/crypt_r.c` 以 `$1$` / `$5$` / `$6$` 分派):

| 前綴 | `rounds=` | salt | hash |
|---|---|---|---|
| `$1$`(MD5) | 不可有 | 0–8 字元(✅ `crypt_md5.c:183` SALT_MAX 8、`:214`) | 22 字元 |
| `$5$`(SHA-256) | 可選;十進位、無前導零;值 1000–9 999 999;之後的部分照 musl 一律當 salt(salt 本身可以是「rounds=…」字樣) | 0–16 字元(✅ `crypt_sha256.c:251`) | 43 字元 |
| `$6$`(SHA-512) | 同上(✅ `crypt_sha512.c:240-270`、`crypt_sha256.c:212-248`) | 0–16 字元(✅ `crypt_sha512.c:273-277`) | 86 字元 |

`rounds` 的範圍(v8 審查 B-m1,✅ `crypt_sha512.c:263-270`):musl 對 < 1000 或帶前導零的值,會把**拉高 / 正規化後**的值寫進輸出(`sprintf(rounds, "rounds=%u$", r)`,註解「needed when rounds is zero prefixed or out of bounds」)。所以存著 `rounds=999` 或 `rounds=05000` 的 hash,輸出的字串永遠對不上,登不進去。> 9 999 999 musl 直接拒絕。

salt 的範圍(v8 審查 A-m4,✅ 同上 `:273-277`):musl 接受**空 salt**,以及除了 `$`、`:`、換行以外的任何字元。salt 超過 SALT_MAX 時,musl 只取前面那幾個字元,輸出同樣對不上,所以拒絕。

hash 只含 `[./0-9A-Za-z]`,整個欄位不含 `:` 與換行。其他一律不合格,包括 `$2…`、DES、空、`!…`。原則:**合格 = musl 用它驗得過某個密碼**,不比 musl 寬,也不比 musl 嚴。

**為什麼這樣切**:
- v6 的 bug 只有一處:S13 收斂只認 `$6$`(`batman-prov-lock:55`)。✅ firmware `.config:946` `CONFIG_BUSYBOX_DEFAULT_FEATURE_DEFAULT_PASSWD_ALGO="sha256"`,而 04 上 `busybox passwd` 可選 `-a des,md5,sha256/512`,所以操作員 `passwd` + `--save` 存進 p5 的 `$5$` / `$1$`,開機時不會收斂。結果是之後沒存的 `passwd` 不會被改回,違反「p5 為準」。
- **v7 擴大成「config-save 與 96 也拒收 `$1$`」是錯的**(兩位審查一致):
  - 那是這張單沒有要求的新政策,而且 legacy 節點在 OTA 之後會變成開放:96 不還原 `$1$` → root 空 → `has_pw=0` → UNPROVISIONED。
  - 已出貨的 p5 裡也可能有這類值(config-save 用 `cp -a`,從不刪)。
  - 「該不該接受弱 hash」若要做,是另一份設計,不在這張單。
- **第 2 類維持原狀**:格式壞掉的 `$…` 本來就登不進去,把它當「已設密碼、不開放」是 fail-secure。改它反而會在升級時造成開放(v7 A-M1)。
- 不選「firmware 把 passwd 預設改 sha512」:那只是遮住症狀,`-a md5` / `-a sha256` 照樣產生。

**`prov-lock.sh` 缺檔時**:S13 與 `prov_apply_lock` 都在這個 lib 裡,lib 缺檔時兩者都不存在。96 走既有的 fallback(§5.3 末段,唯一的例外);config-save 的 stage 本來就不依賴它(第 2 類)。沒有新增的 fallback。

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

**操作員手動 `passwd`**:改完要 `batman-config-save --save` 才算數;已入網的節點由 joinwatch 每 15 s 的 `--on-join` 自動帶進 p5(✅ `joinwatch:141-150`;fingerprint 含 shadow 的 root 行,`batman-config-save:273`);沒入網或改完 15 s 內就重開 → 下次開機被 S13 改回 p5 的值。`passwd` 預設的 `$5$`、`-a sha512` 的 `$6$`、`-a md5` 的 `$1$` 都會收斂(v8)。

沒存進 p5 的值有兩種情況會被改回 p5 裡**較舊**的密碼:
- 下次開機(S13,只限 claimed / member);
- 下次 OTA(fresh overlay 上的 96 會從 p5 還原,legacy 節點也一樣)。

`passwd -l`(`!$…`)不會存進 p5(config-save 只存 `$…`),所以下次開機時 S13 會把 root 改回 p5 的值,鎖定被解除;要鎖定 root 請用 owner-op。DES 的情況同理(config-save 也不存),一樣會被改回。

以上寫進操作說明。

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
  - **收斂 root 只在以下條件全成立時做**:p5 的狀態是 `ok claimed` 或 `ok member`(不是只看 meta 是否 ok,v4 A-m2:在 `any` 規則下 p5 為 unclaimed、p6 為 claimed 也會判 LOCK,此時 p5 可能留著前一任擁有者的 shadow-root——config-save 用 `cp -a`、從不刪檔——不能裝到轉賣後的節點上;這種矛盾只維持一次開機,S89 `boot.Run` 之後 p6 就跟上 p5);p5 與 overlay 的 identity 相同(與 config-save 的 identity_mismatch 判斷一致,v3 A-m4);p5 的 `identity/shadow-root` 是 `root:` + 通過 `prov_root_hash_ok` 的欄位(v8:`$1$` / `$5$` / `$6$` 格式正確即可;v6 只認 `$6$`);且與 live 的 root 欄不同 → 經 `--hash-stdin` 交給 `prov_apply_lock --no-reload`;
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
| p5 `prov.meta` / `prov.cbor` / `identity/shadow-root`(S13 ro 讀) | helper(`--prov-only`)/ config-save | `prov_meta_ok`;shadow-root:收斂用 `root:` + `prov_root_hash_ok`(v8:`$1$` / `$5$` / `$6$` 格式正確);96 還原與 config-save 只看 `root:$…`(維持) | meta 壞 → LOCK(fail-secure,同 `prov_lock_decision`);shadow-root 不合法 → 不帶 hash 上鎖(空 → `!`);p5 掛不上 → 依 p6 last_known_state |

## 8. 生命週期矩陣

| 路徑 | 今天 | 修正後 | 測試 |
|---|---|---|---|
| 首次開機(新卡,unclaimed) | 不鎖 | 不變(S13 判 TODAY) | 鏈 1 第 5 步 |
| 認領 | 不鎖、假密碼、不 seed | 鎖、密碼可用、seed、p6 last_known=claimed | `prov-claim-254`(tier B);鏈 1 第 8.3 步 |
| 認領時上鎖失敗(第 1–2 步 / 第 3 步) | 回成功 + 假密碼 | `ELockIncomplete`、`--save`、空 root → `!` | fakeSys + CI loop 對每一步注入 |
| replay / reset | 一定 `E_APPLY` | 成功 | `prov-claim-254` replay 段;reset 以 socket 測試 |
| 重開機(已認領,上鎖曾失敗或被改掉) | 一直不鎖 | S13 在 dropbear 前鎖、root 收斂到 p5 | §11.4 |
| **認領後沒重開就 rollback 到另一槽(同版本)**(v2 B-M1) | — | 另一槽開機時 S13 讀 p5 = claimed → 鎖、root 換成 p5 的 hash(app 的密碼有效) | §11.5:04 上 claim → `batman-slot rollback` → reboot → 斷言 LOCKED + probe MATCH;負對照 = v2 寫法(只看 overlay)|
| **overlay 寫失敗**(p5 已 commit,`txn.go:36-39`)(v2 A-M3) | — | 下次開機 S13 讀 p5 → 鎖 | §11.4-inj(v7):只把 `prov.meta` / `prov.cbor` 兩個檔案以唯讀副本 bind(不擋 `.stage`)→ helper log「overlay write … failed」→ 解鎖 + p6 改回 legacy → 重開 → S13 log `p5=ok/claimed p6=legacy` + 收斂 |
| helper respawn / crash loop | — | 不補鎖(S13 才補);claim 中途 crash:commit 已寫 → replay 接手 | 程式審查 + 既有 L34 killpoint |
| clean stop / dropbear 重啟 | — | dropbear 重啟讀已鎖 uci | §11.4 讀回 |
| OTA(已認領) | gate 擋 | 可 OTA;fresh overlay 由 p5 shadow-root 還原、96 鎖定 | 鏈 1 第 8.6 步 |
| reset 時 `--save` 失敗(暫時性)→ joinwatch 照常 → 重開 | — | 不回密碼(`E_STORAGE`);helper 先把 root 欄還原 → joinwatch 存進 p5 的仍是舊值 → 重開後 app 手上的舊密碼仍有效 | §11.4b(一次性 lock-busy 注入、joinwatch 不停);負對照 = v4 寫法(不還原)以白箱 variant 跑:p5 shadow-root 的 sha 變、舊密碼 NOMATCH |
| `passwd` → 重開 | — | 已入網:15 s 內進 p5,保留;沒進 p5 → 改回 | 真機:停 joinwatch → `passwd` → 重開 → 改回;`--save` 後重開 → 保留 |
| p5 存的是 `$5$` / `$1$`(操作員 `passwd` + `--save`)→ 再改一次沒存 → 重開(v8,v7 A-M6) | S13 不收斂(只認 `$6$`)→ 沒存的密碼留著 | S13 收斂到 p5 的值 | §11.4c(v6 產品 FAIL = 負對照) |
| 升級:p5 裡已有 v8 之前存的任何 `root:$…`(含格式壞的) | 96 還原;有 key 就 LOCKED | **不變**:96 與 config-save 仍用 `$…`(第 2 類判斷)→ 沒有開放的路徑;格式壞的值 S13 不收斂,只鎖門 | CI:p5 `root:$1$…` / 格式壞的 × legacy / claimed |
| 降版到 v8 之前的版本(v6/v7 rc,只在本單的 rc 之間) | — | 舊 S13 只收斂 `$6$`;`$5$` / `$1$` 退回 v6 的行為(不收斂但已鎖) | 不測(rc 之間) |
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
| `prov_root_hash_ok` 的規格 = musl 驗得了的格式 | ✅ `musl-1.2.5/src/crypt/crypt_r.c`(依 `$1$` / `$2x$` / `$5$` / `$6$` 分派,其他走 DES);`crypt_md5.c:183, 211`(SALT_MAX 8);`crypt_sha256.c:182-186, 212-248`、`crypt_sha512.c:203-207, 234-270`(SALT_MAX 16、ROUNDS 1000–9 999 999:超過拒絕、不足拉到 1000、`rounds=` 首字非數字或沒有 `$` 結尾就拒絕) |
| busybox `passwd` 預設 `$5$`,可選 md5 / des | ✅ firmware `.config:946`;✅ 04 `busybox passwd --help`:`-a ALG des,md5,sha256/512 (default sha256)`(v7 審查 B 唯讀) |
| 節點 login 接受 `$5$` / `$1$` | ✅ 04 2026-10-26(1.5.14-wsl.1):以主機 openssl 3.5.5 產生 `$1$` / `$5$` / `$6$`,static musl cryptprobe 在節點上 right=MATCH、wrong=NOMATCH 各三組(probe 測完刪除並斷言)。busybox `passwd` 自己產生的 hash 在 §11.4c 驗 |
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
2. **CI 單元 node / helper**:fakeSys 注入第 1、2、3 步失敗 → claim / replay / reset 回 `ELockIncomplete`、不回密碼、`Save` 被呼叫;**`Save` 失敗 → claim / replay 回 `ELockIncomplete`、reset 回 `E_STORAGE`,都不回密碼,且 root 欄被還原成呼叫前的值(空 → `!`)**;stage 失敗 → 不是 23;claim 成功後 p6 last_known_state = claimed;`genPassword` 分布(卡方)。**CI loop 跑 `prov_apply_lock`**(假 uci / 假 ubus,同 `tests/prov-p1`):步驟順序、每一步 rc、沒帶 `--hash-stdin` 時不讀 stdin(stdin 接一個永不結束的管線也立即返回)、不合法的 root 欄被拒、多個 dropbear section 都被鎖。**CI loop 跑 S13**:p5 claimed / member / bad / unclaimed / legacy / 掛不上 × p6 各值 × overlay 舊或新 × identity 相同或不同 → LOCK / TODAY 與 shadow 是否收斂(p5 unclaimed + p6 claimed → 鎖但不收斂)。**`prov_root_hash_ok`(v8)**:
- 接受:`$1$` / `$5$` / `$6$`,含 `rounds=1000`、`rounds=9999999`、空 salt、salt 長度上限。
- 拒絕:`rounds=999`、`rounds=05000`(musl 輸出會改寫成拉高後的值)、`rounds=10000000`、`rounds=`、`rounds=x`、salt 含 `$`/`:`、salt 過長(`$1$` 9 字元、`$5$` / `$6$` 17 字元)、hash 長度不對(截斷)、非法字元、含 `:`、`$2b$`、DES、空、`!…`。
- 每一類各附一個突變負對照(例如把長度判斷拿掉,必須 FAIL)。
- 這組向量不只對規格表推導:同一組向量在 tier B(§11.4c 第一步)以節點上的 musl(cryptprobe)交叉驗證(v8 A-m5)。

S13 stub:p5 為 `$5$` / `$1$` → 收斂;p5 為格式壞的 `$…` → 只鎖、不收斂。96 與 config-save **不變**(v8 沒有改它們):「升級不變開放」由鏈 1 的真 OTA(8.6:fresh overlay 上 96 從 p5 還原)驗證,不另寫一份 96 的假環境測試(不擴大範圍)。
3. **真機 tier B `prov-claim-254`**(修正版):LOCKED、` pw=off `、`rootpw=off`、`tty=1`、shadow `$6$`、server 只提供 `publickey`、port 22 `none` → `Permission denied`;publickey 經 2222 臨時 listener(`dropbear -s -g -p 2222`,nft 暫時規則,測完刪除並斷言已刪)證明;**musl probe**(`tools/cryptprobe`,static,與 firmware pin 同次 build;harness 斷言 toolchain musl 版本 == 節點 `/lib/libc.so` 版本,不同 → FAIL;測完刪除 binary 並斷言)MATCH / NOMATCH;replay 段;還原 S0。**負對照**:1.5.13-wsl.1 上同一測試 FAIL(2026-10-26 已取得)。
**真機 tier B 共通規則(v7 + v8,真機測試審查 A / B)**

- **前置條件**(S0 之前就斷言,不符就在動手前 FAIL):
  - joinwatch.state 為 `JOINED`;
  - 模式的條件成立(見下)。
- **注入一律要有正向證據**,沒走到注入點 → FAIL:
  - 注入用的 arm 檔已被消耗;
  - helper log 有對應的那一行,且是**本 phase 的 MARK 之後**、`batman-provhelper[<目前的 pid>]` 寫的。4b' 的副本以 log 驅動放鎖時,也套用同一個過濾(v8 B-m6)。
  - **誠實界線(v8 A-m1)**:04 的 `/dev/log` 是 `srw-rw-rw-`,busybox `logger -t` 的 tag 可以任意指定(包括字面上的 `batman-provhelper[1234]`),所以 MARK + pid 只能防止**誤配**到別的 phase 或別的 pid,防不了惡意偽造;OTS 容器能不能寫 `/dev/log`,實作時查清楚並寫明。偽造只會造成誤判 FAIL 或 INVALID,不會誤判 PASS,因為每個結論都有主證據:helper 的回應碼、shadow / p5 的 sha、probe、uci。
- **on-join 的證據(v8,v7 A-M3 / B-M2)**:修正版還原之後 fp 等於快取,`--on-join` 走 fast path 直接 exit,不會重寫 `cfgsave-onjoin.state`,所以 mtime 不能當證據。改成兩者並用:
  1. `joinwatch.state` 每個 tick 更新(證明 JOINED 分支有跑);
  2. 一份**計數副本**:現場從節點上的 `/usr/bin/batman-config-save` 產生,斷言 `diff` 只多出記錄用的行,只在 `--on-join` 時把結局寫進 tmpfs 計數檔。
  - **計數副本的範圍**(v8 A-m2 / B-m4):
    - 只在 4b(放鎖之後)與 4b' 需要 on-join 證據的那段時間 bind;4、4c 的 `--save`、claim 的 `--prov-only` 測的都是產品本身。
    - 4b claim 與 4b' 的注入副本,也是從同一份計數副本產生(疊在一起,記錄不中斷)。
    - bind 在重開後會消失:每次重開後依 mutant 的規則重新 bind,並以 sha 驗證。
  - **「非 busy」的定義**:只計「拿到鎖並算過 fp」的結局,也就是 cache-hit / unchanged / saved。拿鎖之前的提早 exit(txn-live,`batman-config-save:165`)、GATEFAIL / FROZEN / MNTFAIL、rate-limited 都不算。
  - 放鎖後至少要有 2 次非 busy 的結局,否則 FAIL。
  - 同一份記錄也用來斷言 4b' 從放鎖到停 joinwatch 之間沒有其他 on-join。
- **INVALID 的處理(v8 A-m3 / B-m5)**:注入沒產生要的狀況(例如 4b' 超過 10 s 的時間限制)判 INVALID。
  - INVALID 屬於 ❌ 未完成,不是 PASS:腳本的總結果、daily-validation 的 suite、PR 的測試段都當 FAIL,與「空結果不算 PASS」同一條規則。
  - 同一個 phase 最多自動重試 3 次;3 次都 INVALID 就判 FAIL,附上每次的時間戳。
- **槽位與 autoboot**:
  - 每次重開後斷言目前所在的槽(Pi 4 EEPROM 開錯槽的前例)。
  - 任何 rollback / commit 失敗都中止。
  - `/boot/autoboot.txt`:開跑前記下 sha 與開跑時的槽 S。EXIT trap 的程序(v8,v7 A-M4):
    - active == S 且 autoboot 不同 → `batman-slot commit`;
    - active != S(意外重開進了另一槽)→ 不 commit,也不還原 S0;改做 `batman-slot rollback` 回到 S(S 有修正,gate 會放行;若是開進 1.5.13,那一槽的 batman-slot 沒有 gate,也會放行)→ **立刻 `batman-slot reboot committed`**,讓節點回到 S(在 S 上,S13 依 p5 上鎖)→ 等它回來,斷言在 S 且已鎖 → 印出 `restore <RUN>` 指令,中止(v8 B-m3)。
    - **誠實界線**:開進 1.5.13 槽時,從開機到這次重開完成之前(數分鐘),那一槽的 overlay 是 legacy、開著(p5 是 claimed,但舊 image 沒有 S13)。實驗室 LAN。
    - 重開後斷言槽位失敗時,走同一個程序。
- **秘密**:
  - 識別資料與密碼的副本只放 tmpfs;
  - 必須跨重開的(測試密碼、probe)放 p6 `$PCD`,每條能執行到的結束路徑都刪掉 `$PCD` 與主機端 `$HT`,並斷言已刪;
  - **誠實界線**:主機在中途死掉時,`$PCD` 會留在 p6(含 claimed 節點的 app 密碼,0600)。`pl_prep` 開跑時清掉殘留的 `/opt/batdata/dv-pc.*`(只清這個前綴),手動清除指令 `rm -rf /opt/batdata/dv-pc.<RUN>` 寫進腳本 header;
  - 結尾做 prov-claim 第 8 步那種外洩掃描(所有密碼 + `claim.secret`,含新的還原 / CRIT log 路徑)。
- **S0 快照**:只有在比對 `diffs=0` 之後才 finish;中途還原失敗就中止並保留快照。
- **mutant helper**(`norestore`、`noresave`,由 `dv-prov-mutant-tools.sh` 建置):
  - 用 SHA256SUMS 驗;
  - `FEEDCOMMIT` 的前 7 碼必須等於節點 `/etc/batman-build` 的 `BATMAN_FEED_COMMIT`,且 rc 不是 dirty;
  - 驗 `/proc/$(pidof batman-provhelper)/exe` 的 sha 等於 mutant;
  - 重開後重新 bind,並且要驗證。
- **兩種模式,不默默略過**:
  - `full`:前置條件是另一槽版本相同且有 S13、另一槽的 overlay 開過機(有 `/etc/batman-prov/prov.meta`,state 為 legacy,identity 與 p5 相同)、active = A(brewrite 只能重寫 B)。跑 4、4b、4b'、4c、4d 白箱、5。
  - `old-other`:前置條件是另一槽沒有 S13。用 4d 的真實拒絕 + override 取代 5。
  - 另一槽與模式不符 → 動手前 FAIL。
  - daily-validation 的順序:pty-commit(兩槽一致,停在另一槽)→ … → 停在 A 時跑 `full`;`old-other` 在 rc 驗證時手動跑。
- **rc**:v8 的產品變更要新的 rc(1.5.14-wsl.2)。在 wsl.1 上取得的結果(setsid-race、claim)都要在 wsl.2 上重跑(通用規則第 8 步),wsl.1 的結果只當早期證據。

**各項測試**

4. **S13 補鎖(tier B)**
   - 步驟:認領 → 停 joinwatch → 白箱寫入**已知測試 hash** + 解鎖(uci set + commit + dropbear restart)。
   - **正對照**:以測試密碼做 password 登入**成功**(askpass,known_hosts 與 `q()` 同一份,不關 host key 檢查)。
   - → `batman-slot reboot committed` → 斷言:
     - uci 已鎖;
     - dropbear 每個 instance 的 command 都含 `-s -g`;
     - server 只提供 `publickey`;
     - 以測試密碼登入**被拒**;
     - root 收斂到 p5 的 hash:probe 以 app 密碼 MATCH、以測試密碼 NOMATCH;
     - 本次開機有 S13 的「root converged to p5」那一行;
     - p5 sha 不變。
   - **副作用**:`ttylogin=0` 期間序列埠免密碼即得 root shell;password auth 開著直到重開(實驗室 LAN,數分鐘)。
4-inj. **overlay 寫失敗(白箱)**
   - **v6 的注入是錯的**(審查 B-B3):把整個 `/etc/batman-prov` 改成唯讀,也會擋住 `.stage`(`provstore.go` `Stage()`、`txn.go:18-27`),claim 在 `--prov-only` **之前**就 `EApply`。
   - v7 做法:S0 → 只把 `prov.meta` 與 `prov.cbor` 這兩個**檔案**的唯讀副本 bind 回原位(副本放 tmpfs)。`atomicWrite` 的 rename 遇到 mountpoint 會失敗,所以是在 p5 commit **之後**才失敗(`txn.go:36-39`)。
   - 正向證據:helper log 有「overlay write after a committed p5 write failed」。
   - helper 照樣 `setPassword`、把 p6 寫成 claimed(審查 A-M3 / B-M1),所以光看「鎖著」分辨不出 S13 有沒有讀 p5。因此:停 joinwatch → 寫測試 hash + 解鎖 → p6 prov-state 第 3 欄改回 legacy → 斷言 overlay 的 meta 仍是 legacy。
   - 重開 → 斷言:
     - 本次開機 S13 log 有 `p5=ok/claimed p6=legacy` 與 root converged;
     - 已鎖;
     - probe 以 claim 的密碼 MATCH;
     - 測試密碼被拒。
   - 副作用(v7 B-m5):rename 失敗會留下 `/etc/batman-prov/prov.cbor.tmp` 與 `prov.meta.tmp`(`atomicWrite` 只在寫入失敗時刪 tmp,`provstore.go:402-407`),由 S0 的 EXTRA 清除;p6 prov-state 第 3 欄的改寫用 tmp + mv,只改第 3 欄。
4b. **`--save` 的暫時性失敗(tier B,白箱)**
   - **claim**:不能預先持鎖——claim 的 commit 自己會 `--prov-only` 取鎖,預先持鎖會讓 commit 失敗,走的是另一條路(審查 A-B1 / B-B1)。
     - 注入點:config-save 副本在 `--save` **入口**,armed 一次;同步執行 `prov-base lock-hold <run> 50`,等它印出 HELD 才往下走。
     - 這時 hash 已寫進 live、鎖必定是空的,所以 helper 第一次 `--save` 必定撞鎖。
   - **reset**:沒有 `--prov-only`,呼叫前持鎖 50 s 即可。
   - 斷言:
     - helper log 有「busy, retrying once」與「--save rc=1 … restoring」;
     - 不回密碼(claim 23 / reset 10);
     - live root == 呼叫前(空 → `!`);
     - helper 的 best-effort `--save after the restore` 那一行也出現(它在鎖仍被佔住時失敗);
     - 放鎖後 on-join 至少有 2 次非 busy 的結局(計數副本),之後 p5 shadow-root 的 sha 不變;
     - reset 那次重開後,probe 以舊密碼 MATCH。
   - **負對照** `--flip norestore`(去掉還原規則的 mutant):`P2 p5 changed` **與** 重開後 NOMATCH **都要** FAIL,才判 VALID。
4b'. **joinwatch 自己佔鎖的交錯(白箱)**
   - config-save 副本只在 `--on-join` 時 armed 一次:
     1. 取鎖後,等 live root 欄改變(上限 25 s,即 helper 第 3 步已寫入);
     2. stage(記下 staged 的 sha;必須等於新的 live root 行,也就是**未交出**的 hash);
     3. 保持持鎖,直到 helper log 出現「--save rc=1 … restoring」(重試已失敗、live 已還原);
     4. 再寫 p5(未交出的 hash),然後放鎖。這時 helper 的 best-effort `--save` 正在等鎖,會取得鎖。
   - **時間限制**(v7 A-m7 / B-m4b):「restoring」那一行在 `RestoreRoot` 之前就印出(`node.go:447-451`),之後 helper 的補存最多等 10 s。所以副本從看到那一行,到寫完 p5(含 SD 的 sync)、放鎖,必須在 10 s 內完成。
     - 副本記下這三個時間戳(看到 log、p5 寫完、放鎖);
     - 補存的 rc 由 helper log 取得;
     - 超時 → 判 INVALID(注入沒產生要的交錯),不判 PASS 或 FAIL。
   - helper 回 reset 之後**立刻停 joinwatch**,斷言 p5 sha == 呼叫前。此時能把 p5 改回的只有 helper 的補存(審查 A-M2 / B-M2:v6 的版本靠的是 joinwatch 下一個 tick,證明不了補存)。
   - **負對照** `--flip noresave`(去掉補存的 mutant):p5 == staged 的未交出 hash → VALID。
4c. **`passwd`**
   - 第一步(不碰 shadow,v8 A-m6):主機 `openssl passwd -1 / -5 / -6` 加上 §11.2 的 `prov_root_hash_ok` 向量,在節點上用 cryptprobe 交叉驗證(合格者 MATCH、拒絕者 musl 也驗不過或輸出不同)。失敗就停。busybox `passwd` 產生的 hash 由後面的步驟以 probe 驗(那時本來就會改 live 的 root)。
   - 停 joinwatch → `passwd`(預設 `$5$`)→ 重開 → 測試密碼 NOMATCH、app 密碼 MATCH。
   - `passwd` + `--save` → 重開 → 保留。
   - **v8**:在已存 `$5$` 的狀態下再 `passwd` 一次不存 → 重開 → 改回已存的 `$5$`。這是 `prov_root_hash_ok` 的回歸測試;wsl.1 的產品在這裡會 FAIL(負對照)。
   - 同樣流程用 `passwd -a md5`(`$1$`)再做一次:存了就保留,沒存就改回。
   - 最後 replay 拿回 app 密碼。
4d. **rollback gate**
   - **白箱**(兩種模式都跑):在節點上以 image 自己的 `rollback_lock_gate` + 真的 squashfs(**`-comp xz`**:04 的 kernel 只有 `CONFIG_SQUASHFS_XZ`,審查 A-B2 / B-B2;先用 `unsquashfs -s` 斷言壓縮方式),三張映像:
     - 沒有 init → 拒絕;
     - 有 init、沒有 `rc.d/S13` → 拒絕(A-m4);
     - 兩者都有 → 放行;
     - 拒絕訊息必須是「cannot keep」,不是「cannot read」;
     - 不留 mount / 暫存目錄。
   - `old-other` 模式:真實 `batman-slot rollback` → 拒絕、autoboot.txt 不變;override → 放行 → `commit` → autoboot.txt sha 還原。
   - legacy 節點不擋。
   - 負對照:1.5.13 的 batman-slot 不擋(CI stub 與 fixture)。
5. **認領後 rollback**(`full` 模式)
   - claim → 不重開 → `batman-slot rollback` → reboot → 斷言:
     - 在另一槽;
     - LOCKED;
     - probe 以 app 密碼 MATCH;
     - 本次開機有 S13 log。
   - → rollback 回來 → 斷言槽位 → 另一槽的 overlay 被這個測試改過,以 brewrite 重寫另一槽(active = A 是 `full` 的前置條件)。**順序(v8 B-m2)**:先 S0 還原(p5 回到 legacy),再 brewrite。brewrite 會開進那一槽試跑一次再回來,下一輪的另一槽 overlay 就仍是「開過機」的;若 p5 當時仍是 claimed,試跑時 96 與 `boot.Run` 會把它寫成 claimed,下一輪的前置條件就會 FAIL。brewrite 之後斷言那一槽的 overlay 是 legacy。
   - 負對照(只看 overlay 的判斷)由 CI 的 S13 stub 涵蓋:p5 claimed × p6 × overlay legacy → LOCK。真機上沒有可以白箱替換的 S13(它在 squashfs 裡,開機時就跑),寫明。
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
- `passwd -l`(`!$…`)不會存進 p5,所以 claimed / member 節點下次開機時 S13 會把 root 改回 p5 的值,操作員的鎖定被解除。這與「p5 為準」一致,列為操作說明;要鎖定請用 owner-op(v8 A-m7)。
- 96 的 shadow 寫入用固定檔名 `/etc/shadow.137`(還原)與 `/etc/shadow.96fb`(fallback)、自己的 awk,不是 mktemp(v7 A-m9)。這是 #137 以來的既有寫法(`/etc` root 0755,非特權寫不進去),不是這次的變更,不擴大範圍;之後改走 `prov_apply_lock --restore-stdin --no-reload`。
- 「寫 shadow + `--save`」在同一把 config-save 鎖底下完成(消除 joinwatch 晚讀 shadow 的短暫不一致,v5 B-m2)。

## 14. 審查摘要與處理
**v8(第 3 輪:A APPROVE-WITH-CHANGES 0 / 0 / 7、B APPROVE-WITH-CHANGES 0 / 0 / 6)— 設計核准**。第 3 輪的 MINOR 已併入:
- rounds 1000–9 999 999、不得有前導零(B-m1,musl 會改寫輸出);
- salt 0–SALT_MAX,不含 `$` / `:` / 換行(A-m4,musl 接受空 salt);
- logger 偽造寫成誠實界線,以回應碼與 sha 為主證據(A-m1 / B-m6);
- 計數副本的範圍、生命週期、「非 busy」的定義(A-m2 / B-m4);
- INVALID 屬於未完成,自動重試上限 3 次(A-m3 / B-m5);
- 向量以真的 musl 交叉驗證(A-m5);
- 4c 的 probe 不碰 shadow(A-m6);
- `passwd -l` 列 §13(A-m7);
- 5 的順序是 S0 還原再 brewrite(B-m2);
- trap 開進舊槽後 rollback 並立即重開(B-m3)。

**v8 首版處理的是 v7 兩位的 REJECT(窄):A 0 / 4 / 10、B 0 / 3 / 8**
- A-M1 / B-M1(同一件事:拒收 `$1$` 讓 legacy 節點 OTA 後開放、超出範圍):§5.3 改成兩類判斷。`prov_root_hash_ok` 只用在收斂與寫入,接受格式正確的 `$1$` / `$5$` / `$6$`;「不是開放」維持 `$…`。§8 加升級、降版兩列;CI stub 補 `$1$` 與格式壞的值。
- A-M2(config-save 拒收的契約):隨 M1 消失,config-save 不變。
- A-M3 / B-M2(mtime 證據在修正版上不會出現):改用 joinwatch.state + config-save 計數副本(非 busy 結局 ≥ 2)。
- A-M4(trap 會把錯的槽 commit 成預設):trap 只在 active == 開跑時的槽才 commit,否則 rollback 回去並中止。
- B-M3(`full` 的前提):另一槽 overlay 開過機、active = A,都在 S0 之前斷言。
- MINOR:
  - 規格表附 musl `file:line`(A-m1 / B-m1);
  - §9 補 `$5$` / `$1$` 證據,並把真機 probe 列為 4c 第一步(A-m2);
  - `passwd -l` 與 OTA 改回的說明(A-m3 / B-m8);
  - `--restore-stdin` 與 Go 一致(A-m4 / B-m3);
  - 新的 rc wsl.2(A-m5);
  - log 錨在 MARK 之後 + pid(B-m4a);
  - 4b' 的 10 s 時間限制(A-m7 / B-m4b);
  - `$PCD` 的誠實界線與清除(A-m8 / B-m7);
  - 96 的固定檔名列 §13(A-m9);
  - `noresave` mutant(A-m10);
  - `.tmp` 副作用(B-m5);
  - FEEDCOMMIT 前綴比對(B-m6);
  - `prov-lock.sh` 缺檔(B-m2:沒有新的 fallback)。

**v7(REJECT 窄)— 真機測試 `prov-lock-254.sh` 兩位審查都 REJECT(A 2 / 7 / 11、B 3 / 7 / 10)後的修正**
- 產品:A-M6(`$5$` 與 S13 只認 `$6$`、四處各自判斷)→ §5.3 `prov_root_hash_ok` 單一定義,四個呼叫者共用;§5.4、§7 隨之修改。
- 測試計畫 §11.4–11.5 重寫:
  - 4b claim 注入改在 `--save` 入口同步持鎖(A-B1 / A-M1 / B-B1);
  - 4-inj 改成只對檔案做唯讀 bind,並以解鎖 + p6 改回 legacy 來區分 S13 是否讀 p5(B-B3 / A-M3 / B-M1);
  - 4b' 改由 helper 的 log 驅動放鎖,停 joinwatch 後立刻比對,加 `noresave` 負對照(A-M2 / B-M2);
  - on-join 的正向證據、JOINED 前置條件(A-M5 / B-M3);
  - finish 只在 diffs=0 之後(A-M4 / B-M4);
  - autoboot 與槽位的斷言、中止規則(B-M5);
  - 秘密的位置與清除、外洩掃描(B-M6 / A-m1 / A-m2);
  - P7 不得默默略過 → `full` / `old-other` 兩種模式(A-M7 / B-M7);
  - squashfs 用 xz + 三張映像(A-B2 / B-B2 / A-m4);
  - mutant 驗證(A-m3 / B-m6)。
- 其餘 MINOR 在實作時處理,於該腳本的 code review 回報。

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
