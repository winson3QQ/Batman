# 審查 B — `254-p1-impl.md` v1(PR-P1 + PR-H2)

審查者 B(獨立)。範圍:整份 v1,對照上層 `254-stage1-impl.md` v19(§3、§4.1–§4.4、§5、§6.4、§8、§9、§10 第 4 點)、`254-h1-harness.md` v8、Batman main f1a1122 原始碼、firmware-2710 rootfs、02 / 04 唯讀實查(只跑讀取指令;沒有印任何金鑰或密碼)。

**判定:REJECT** — 3 BLOCKER / 7 MAJOR / 14 MINOR。

主要原因:兩個「真機」測項排在**沒有乙太網的 02** 上,照寫的流程跑會讓 02 失聯、而且 autocommit 會把失聯的槽 commit 掉;`prov-reset-legacy` 不還原測試動到的網路與帳密狀態,另一槽的 overlay 還會在之後 rollback 時把「公開金鑰的擁有者」認領狀態復活。另外,白箱 image / 二進位檔沒有契約,測試 client 處理秘密的方式沒定,PR 的先後順序和「測項只有一套」規則衝突。

---

## 0. 我自己驗證過的事實(證據)

| # | 事實 | 證據 |
|---|---|---|
| E1 | **02 沒有乙太網**,只能經 04 的 mesh 連到 | 02:`eth0 carrier=0 oper=down`;只有 `br-ahwlan 10.41.1.1/16`。04:`eth0 carrier=1` |
| E2 | #202 閘的註解直接寫了這個風險:「a fresh slot would then boot UNPROVISIONED (no mesh key), and on a mesh-only node (no ethernet) that strands it unrecoverably」。override 是 `/tmp/batman-slot.allow-unseeded` | `batman-slot:528-551` |
| E3 | 96 在 `:93`(未 seed)離開,早於 Lane A(`:96-124`)→ 不還原 `authorized_keys`、host key、shadow、overrides → mesh key 用 image 的預設值 `CHANGE-ME-NOW`(`meshpoint-1.8.0:28`)→ keyguard 關掉 mesh radio(`halow-keyguard:22-27`) | 讀檔 |
| E4 | 今天的 `expected_in_mesh()` 只要 p6 有 `mesh-joined` 就回 1(`batman-autocommit:388-389`),02 / 04 都有這個檔;§6.4 把 `unclaimed` 改成 NEED_MESH=0 | 讀檔;兩台 `ls /opt/batdata/state` |
| E5 | config-save 只在有 crypt hash 時才 stage `identity/shadow-root`(`:302-304`),發布時用 `cp -a "$STAGE/identity/." "$MNT/identity/"`(`:391`),**從不刪除** p5 上已有的檔 | 讀檔 |
| E6 | 02 / 04 的 root 都沒有密碼(`root_pw_len=0`)、`lock-status=UNPROVISIONED`、`PasswordAuth=on`、`ttylogin=0`、沒有 dev-open | 唯讀實查 |
| E7 | `/tmp/run/batman-dv` 是 `drwx------ root`;/etc/passwd 目前沒有 provd;busybox `start-stop-daemon` 有 `-c USER` | 04 實查 |
| E8 | uci-defaults 的執行順序是 `files="$(ls)"`(`etc/init.d/boot:11`)。rootfs 排序後:`… 99-halow-identity 99-migrate-* 99_morse_radio_defaults` → `99zz` → `luci-i18n-*`。**99zz 在所有 9x 之後,只有 luci-i18n-* 排在它後面 ✅**(D5 成立) | firmware-2710 `root-bcm27xx/etc/uci-defaults` 以 `LC_ALL=C sort` 排序 |
| E9 | rootfs 有 **`/etc/rc.button/reset_override`**,長按 ≥ 10 s 會 `jffs2reset -y && reboot`;opkg 組 rootfs 時**沒有** `--force-overwrite`(`include/rootfs.mk:35-44`) | 讀檔 |
| E10 | feed pin f2f2bf6..main f1a1122 之間,`feed/` 與 `deploy/` 沒有任何差異 → P1 rc 和 wsl.9 的差別只有 P1 本身 ✅(F11 對) | `git diff --stat f2f2bf6 f1a1122 -- feed deploy` 輸出為空 |
| E11 | H1 P4:`FEATURE_MODE=--destructive` 時 BLE_PERIPH == DNODE,理由是「重開要有乙太網救援(E18)」;H1 P6「不擋產品狀態」;H1 的 deadman / lease 在 tmpfs,「節點重開 → 工具、標記、deadman 都消失」 | `254-h1-harness.md` §4.1、§4.7、§5 |
| E12 | 04 上的容器沒有整個掛 `/opt/batdata`(只掛 `docker/volumes/*`、`apps/opentakserver/*`);p6 已經累積 5 個沒清的 `dv289-backup-*`(0700) | 04 `docker inspect`、`ls -ld` |
| E13 | 04 overlay 上只存在於 overlay 的東西:`etc/init.d/batman-payload-opentakserver`、`.cache/Tailscale`、`crontabs/root`、`uhttpd.key/crt`、`openmanetd.db*` | 04 `find /overlay/upper` |
| E14 | CI 目前沒有 Go(workflows 裡沒有 `setup-go` / `go test`) | grep `.github/workflows` |

---

## BLOCKER

### B1. `prov-firstboot-254`、`prov-bypass-254`(以及 `prov-gate-254`)放在 02:會失聯、看不到結果,firstboot 還會被 commit

**情境(firstboot,02)**:p5 `mkfs` → OTA。
1. **#202 閘先擋**:p5 是 ext4 而且沒有 `.seeded`,新的 prov.meta 也不存在(剛 mkfs)→ `precheck` 與 stage 2 都 die(E2)。prov-aware 的例外只放行 `prov.meta state=unclaimed`,空分割區沒有 meta → 在 **P1 rc 和 wsl.9 都會被擋**。設計沒提 override,所以流程第一步就跑不下去。負對照「wsl.9 同一流程」也一樣被擋。
2. 就算用了 override:fresh 槽 96 在 `:93` 離開 → mesh key = `CHANGE-ME-NOW` → keyguard 關掉 mesh radio;99zz 關掉 AP;02 沒有乙太網 → **02 完全失聯**(E1–E3)。
3. 在 P1 下 `unclaimed` 的 NEED_MESH=0 → 健康就 **commit** → 02 永久停在沒有 mesh 的槽,p5 已經是空的,而 p5 的備份放在 02 自己的 p6(連不到)。只能靠實體 serial 或重燒卡救。
4. 斷言(`iw dev`、`identity/` 權限、p5 7 檔)要 SSH 進去,做不到 → 結果只能是 UNKNOWN。負對照「AP 是開的」也看不到。
5. 即使換到 04:fresh 的未 seed 槽沒有 `authorized_keys`(Lane A 沒跑)、host key 會重新產生、IP 回到 image 預設 / 99-halow-identity 重新個人化 → harness 的 key 登入與 known_hosts 都失效。設計沒有寫怎麼連進去。

**情境(bypass,02)**:`batman_bypass=1` → 96 在 `:64` 離開 → 同樣是 image 預設 → 02 在 trial 期間失聯。今天的規則(unknown → p6 `mesh-joined` 存在 → NEED_MESH=1)會在期限到時 revert,所以**不會永久失聯**。但「`unknown(bypass)`、helper 不產生、persist 拒、96 留著」全部要在 trial 期間 SSH 進去看,做不到;第 4 步「改回 cmdline、`batman-slot reboot committed`」也做不到 → UNKNOWN。

**情境(gate,`prov-gate-254`)**:「`prov-reset-legacy` 之後刪 `.seeded` 模擬重燒卡」得到的是 **legacy** + 未 seed,不是 unclaimed。依 L44,閘仍然要擋(只放行 unclaimed)→ 測項的前提不成立。如果真的弄出 unclaimed 再 OTA,就是第 2–3 點(fresh 槽用 image 預設、NEED_MESH=0、會 commit)。

**證據**:E1–E4、E11(H1 已經定了「破壞性測試要有乙太網救援」)。

**修法**:
- 兩個測項都改在 **04** 跑(它也是真機,符合 P-U4「真機有效有真機」),並寫明:
  - 前置:p6 寫 `autocommit-hold-commit`(寫明受測 build 的版本)→ trial 不會 commit,期限到時照常 revert,這是自動回來的路;
  - #202 override(`/tmp/batman-slot.allow-unseeded`),只開這一次,測完先印出再刪;
  - 怎麼連進 fresh 槽:乙太網 + image 預設 / link-local 位址、空密碼登入或其他方式,以及 known_hosts 怎麼處理;
  - 斷言必須在 trial 窗口內完成;另外把證據寫到 p6,revert 之後再讀一次;
  - 04 OTS 的副作用(trial 期間 OTS 網路與 IP 換掉、EUD 中斷)與還原。
- 02 只能跑「失聯了也會自動回來」的測項(trial + hold-commit),而且必須事先證明 02 在那個 trial 裡不會被 commit。
- `prov-gate-254` 改成真的 unclaimed 前提(接在 04 的 firstboot 流程後面),同樣加 hold-commit,斷言「閘放行」就夠了,不必讓 trial commit。

### B2. `prov-reset-legacy` 沒有還原測試動到的網路、帳密與 p6 狀態 → 機隊留在公開金鑰上、02 被切斷、自己的收尾斷言必然失敗

§4.4 第 2 步只刪 prov 檔、還原 dropbear 設定與 shadow、做 `--save`、重開。實際會留下來的東西:

| 留下的東西 | 從哪裡來 | 後果 |
|---|---|---|
| live `wireless.*`、p5 `overrides.uci`、**`lkg/overrides.uci`** | `prov-netjoin` / `netupdate` / `powerloss`(§4.4 第 5 步 `--save`;helper 在入網後 `--save --promote-lkg`) | 兩台留在測試網路的 mesh key / ID / 頻道。這把 key 來自公開的向量(§3)→ **機隊的 mesh key 變成公開的**。只要有一台先還原,02 就經 04 連不到(E1) |
| p5 `identity/shadow-root` = 認領時設的隨機 hash | 認領 → `--save`;還原時做 `--save` 不會刪它(E5) | 下一次 OTA(fresh overlay)96 Lane A 還原這個 hash → 4b `has_key && has_pw` → **LOCKED**,而且 root 密碼沒有人知道;serial `ttylogin=1` 要那個密碼 |
| p6 `lock-status=LOCKED` | 認領上鎖 | 第 2 步沒有還原它,而 helper 對 legacy「不寫鎖定欄位」(上層 §4.4 第 8 點)→ 第 3 步斷言「lock-status 與測試前相同」**每次都會 FAIL** |
| `authorized_keys`、`ssh_keys.added`、p5 `identity/dropbear/authorized_keys` | `ssh_keys.set`(P-U3 有實作;只要有正向測試就會加 key) | 用公開私鑰的 key 變成 04 的 root 登入憑證 |
| p6 `mesh-expected` / `mesh-joined`(`network/leave` 會刪)、`prov-state`、`ble-ok`、`ota-armed.mesh`;overlay 的 `.txn`、`/etc/.batman-prov-restore` | 各個測項 | legacy 的 autocommit 規則跟著改變;`last_known_state=claimed` 會影響下一次 96 的上鎖判斷 |

其他問題:
- **並行寫 p5**:第 2 步直接刪 p5 的檔,但 joinwatch 每個 JOINED tick 都會跑 `--on-join`(`joinwatch:145`),它會掛 rw、持有 `cfgsave.lock`。沒有拿鎖 → 兩個寫者(#202 T11:第二個掛載會靜默變成唯讀)。
- **備份會被覆蓋**:備份目錄固定在 `dv-prov-backup/`。上一次跑在認領後死掉,下一次跑就會用 claimed 狀態覆蓋「乾淨」的備份。
- **deadman 撐不過重開**:H1 的 deadman 在 tmpfs(E11),而幾乎每個 tier B 測項都會重開或 OTA → 測項中途 harness 死掉時,節點停在 claimed / member,沒有人收尾。§6 的「deadman 到期 → reset」只在沒重開的情況下成立。

**修法**:
- 每次跑一個備份目錄(`dv-prov-backup/<run_id>/`,0700;已存在就拒絕)。內容:整個 p5 映像 + overlay 的 `wireless`、`dropbear`、`system`、`shadow`、`authorized_keys` + p6 `state/` 的相關檔(lock-status、mesh-*、prov-state、ble-ok、ota-armed.mesh)。
- reset 一律從備份**整份還原**:先拿 `cfgsave.lock`、停 joinwatch 和 helper → 寫回 p5 映像 → 還原 overlay 檔 → 還原 p6 狀態。
- 兩台的順序寫明:先還原 02(兩台都還在測試網路時)、再還原 04,之後斷言 02 有回到 mesh。
- 在 p6 放一個能撐過重開的 `dv-prov-dirty <run_id>` 標記;preflight 看到就 FAIL,並印出還原指令。
- **節點測試用每次跑隨機產生的擁有者 / 網路金鑰**(放在主機 tmp,測完刪);向量金鑰只用在 provclient 的 CI 自測。這樣就算真的留下狀態,擁有者也不是「任何人都有私鑰」的那一個。
- 收尾斷言要比對**下一次 fresh overlay** 會還原出什麼(p5 的 `shadow-root`、`authorized_keys`、`overrides`、`lkg` 與備份逐位元組相同),而不是只看這一次重開後的狀態。

### B3. 另一個槽的 overlay 會在之後 rollback / revert 時,把公開擁有者的 claimed / member 復活

**情境**:`prov-ota-254`(member → OTA)之後,舊槽的 overlay 仍然留著 `/etc/batman-prov/{prov.cbor, identity/}`,內容是 member / 測試擁有者。reset 只清目前這個槽的 overlay 和 p5。之後任何時候 rollback 或 revert 到那個槽,helper `--boot` 會看到:
- p5 是 legacy(新身分),gen 很小;
- overlay 的 gen 比較大 → 依上層 §4.4 第 7 步「overlay 新 → 以 overlay 為準重新 `--prov-only`」;
- 或者在 p5 沒有 prov 時(rc 9)「overlay 有完整 `prov.cbor` + identity → 整份重新 persist」(上層 §4.2 rc 9 列,A11-m5)。

結果是**擁有者 = 公開向量的認領狀態被復活**。P2 上線後,任何拿到向量的人都能經 BLE 認領這台。

另外,上層對「overlay 和 p5 的 identity 都完整、但內容不同」沒有規定:p5 的 `identity/prov/` 是一次寫入,overlay 是舊身分 → 誰勝出沒有定義(上層的介面缺口,這裡被觸發)。

如果 reset 是在 trial 中執行(deadman 在 trial 期間觸發),`reboot committed` 開進的那個槽的 overlay 一樣還帶著 prov → 照上面的規則重新 persist → reset 失敗。

**修法**:
- reset 要處理兩個槽:另一槽重新寫入 image(fresh overlay,也順便清掉 M1 說的白箱 image),或掛起那個槽的 overlay、先印出再刪 `/etc/batman-prov`;
- preflight 的 legacy 斷言改成「兩個槽 + p5」都要 legacy 或沒有 prov;
- 把「identity 不一致」回報給上層定案(建議:p5 的 identity 優先,overlay 丟棄並記 log;也可以定成 fail-closed 的 `unknown(identity-mismatch)`)。

---

## MAJOR

### M1. 白箱 image 與白箱二進位檔沒有契約

會用到的:helper = `exit 1` 的 image(lock-failsecure)、`PROV_TEST_KILLPOINT` 的 test-tag helper(powerloss)、不檢查 `SO_PEERCRED` / `is-trial` / 不重算 `ClientChal` 的 helper(負對照)、改頻道的 image(§6.4 (4)、(7))、`radio1.disabled=1` 的 image((1))、「96 在 `:89` 離開」(怎麼觸發完全沒寫;`ro,noload` 重複掛載不會失敗)。

沒寫的部分:誰 build、版本號(autocommit 的 hold 旗標認 `BATMAN_VERSION`)、放在哪(覆蓋 overlay 的 `/usr/bin` 會一直留著 → 被拿掉安全檢查的 root helper 留在產品節點上)、怎麼移除。測完之後**另一槽留著白箱 image** → 之後 `batman-slot rollback` 或 revert 就開進它(H1 v6 的 BLOCKER 是同一類問題)。CI 的「release 二進位不含 `PROV_TEST_KILLPOINT`」沒說要掃哪個檔;找不到檔案必須 FAIL。

**修法**:
- 白箱二進位一律從 tmpfs 以 `mount --bind` 蓋上去,不寫 overlay。重開自動恢復,而且 powerloss 測的就是 release helper 的開機恢復路徑。
- 白箱 image 用專屬的版本後綴(例如 `-wbox`);轉賣工具清單和 release 都拒收;測完把另一槽重新寫成受測 image,preflight 斷言兩個槽都不是 `-wbox`。
- 寫出 `:89` 要怎麼觸發。
- release 的掃描放進 firmware build gate,讀組好的 rootfs;找不到 helper 就 FAIL。

### M2. 測試 client 的秘密處理沒有定義;放置目錄的權限和 provd uid 矛盾

- `claim.verify` 需要 `claim.secret`(QR)。它在 root 0600 的 `identity/` 裡,而 `batman-provhelper qr` 在 legacy 上要 dev-open 或實體 console(上層 §4.2)。provd uid 的 client 怎麼拿到?不能放 argv 或 env(`/proc/<pid>/cmdline`、`environ` 本機看得到)。用 dev-open 又會改變 96 / 4b 的行為。
- claim、replay、`root_password.reset` 的回應裡有 root 密碼、`owner_tag_key`、`adv_owner_key`;`diag.bundle` 的內容也是。harness 會把 client 的輸出寫進 log → 秘密進到 log、PR、issue。上層 §8「我們自己:`logread | grep -c <secret>` = 0」在 H2 裡沒有。
- 「放在 `/tmp/run/batman-dv/bt/<run_id>/`(0700 root)」+「以 provd uid 執行」→ provd 進不去那個目錄,exec 會 EACCES(E7)。

**修法**:
- root 端讀 secret 經 stdin 或已開好的 fd 交給 client;client 對秘密欄位只輸出 sha256 前 8 碼;
- 加測項:跑完後在主機 log、`logread`、run 目錄 grep 每一個秘密 = 0;
- client 放在獨立的目錄:root 擁有、0711,檔案 0755,驗 sha 與 link count;測完刪除。

### M3. 很多負對照沒有鑑別力,或者根本沒有

- 寫「—」的:`prov-ota`、`prov-netupdate`、`prov-overlay-corrupt`、`prov-overlay-wipe`、`prov-downgrade`。`downgrade` 的判讀是「照實記錄」,這不是測試。上層 L12 有列出預期行為,應該逐項斷言。
- 「wsl.9 FAIL」對大多數項目只是「沒有 helper / 沒有 provd 使用者」,是 presence。真正有鑑別力的只剩白箱負對照,所以每一項都要有。
- `prov-boot-254` 有 6 個以上的斷言,只配了 1 個負對照(停 helper → health stale)。
- `prov-lock-failsecure`「密碼登入被拒」:root 密碼是隨機的,用錯的密碼一定被拒,不管 PasswordAuth 開沒開 → 沒有鑑別力。要用伺服器宣告的認證方法清單判定(`ssh -v` 看 `Authentications that can continue: publickey`,沒有 `password`),不需要知道密碼。
- 「沒有 `wifi reload` log」:在 128 KiB 的 log ring 裡判「沒有」,ring 被擠掉時也是「沒有」→ 改用 helper 寫在 p6 的計數器。
- `prov-unit-cfgsave` 的「寫入順序 identity → cbor → meta 最後」:沒說怎麼觀察。要做故障注入:在 cbor 寫完後讓 meta 寫入失敗,斷言 gen 沒有前進。
- §6.4 (9) 改成「helper 反覆 kill」:helper 死掉 → health 不更新 → 超過 60 s → 依 §3 契約讀者視為全 0 → 有 `ble-ok` 時應該 **UNHEALTHY / revert**。這和原本 (9) 的「不 revert」相反,而且是不同的性質。(9) 應該移到 H3,或明確定兩種結果:procd 在 15 s 內 respawn → 不 revert;helper 持續死掉 → revert。

### M4. PR 順序和「測項只有一套」規則衝突

- H2 先 merge,但 H2 的 CI job 跑的是 P1 的程式碼:`go test` 在 P1 的 Go module、source `prov-lock.sh`、`--prov-only`。merge 後到 P1 merge 之間,main 的 CI 不是紅的,就是「找不到 → 跳過」。後者違反「什麼都沒測到就必須 FAIL」。
- helper `--boot` 的 go test 寫「放在 P1 的 Go module」= 測項跟著產品 PR 進來,違反 harness 先進 main 的規則。
- 要在 H2 改的 lint / 清單,設計都沒提:
  - `check-provisioning-sync.sh` 的 PAIRS(`prov-lock.sh`、99zz、按鈕腳本);
  - `ab-shared-change.yml` 的 paths(新的兩板共用檔);
  - `rundir-paths.txt`(`prov-txn`、`batman-prov.health`、`joinwatch.lastjoined`,否則 `check-tmp-trust.sh` 會 FAIL);
  - `depersonalise.sh` 的安裝清單。
- 每日全套在 P1 出貨前會 FAIL,要不要加 `validation-known-failures.txt` 項(含 #254、到期日),沒寫。
- H2 的測項在 P2 之後還會繼續跑:那時 provd 常駐並佔著 helper 的唯一連線 → provclient 連不上或被序列化。而且留下來的認領狀態在 P2 之後可以經 BLE 被接手。

**修法**:寫一節「H2 在 P1 出貨前、出貨後、P2 出貨後」三個時期的行為:
- CI 用 known-failures(有期限)處理過渡期,不跳過;
- 跑 helper 測試前怎麼處理 provd(停掉,並記在 lease 的還原清單裡);
- 上面列的 lint / 清單改動放進 H2。

### M5. 上層指派給 P1 的項目被靜默丟掉

| 上層 | 本設計 |
|---|---|
| §10 第 4 點:helper 用 mgmt `READ_INFO` 讀狀態、讀 `batman-sc`,寫 health 的 `privacy` / `sc` / `sc_file` / `bondable` | 沒提;`prov-boot-254` 只寫「health 檔格式」 |
| §6.4 負對照 (1) legacy OTA 到 `radio1.disabled=1` → revert;(2) claimed + placeholder → commit | 標了「×10」但只列出 8 項,(1)(2) 不見了((2) 需要 unclaimed 認領,跟 B1 一起規劃) |
| L9–L11 helper 重啟(§9 tier A「helper-restart」) | 沒有 |
| L18 白箱:沒有 key、沒有 dev-open → `E_UNSUPPORTED(no-ssh-key)` | 沒有 |
| L22 `prov-leave-ota-254`(會刪 `mesh-expected` / `mesh-joined`) | 沒有(P-U3 說全部動詞都做,`network.leave` 也在內) |
| L34 persist 之後 `reboot -f`、在回應之前 → replay | 只寫「重開後」 |
| L38(99zz → helper,60 s)、L42(直接 `batman-slot apply`)、L43(過期的 boot_id)、L51(`lastjoined`)、L61(p6 壞掉)、L60(unclaimed 時沒有 AP) | 沒有 |
| §8 本機非 root:`-helper-uid`、`-key-perms`、tmp-trust | 部分有 |
| P-U3 動詞的授權負測試 | 只有 schema / forbidden / 首版 join。缺:owner-op nonce 重放與過期、`args_hash` 不符(簽 A 送 B)、非 deterministic 編碼或重複 key、admins 鏈跳號、`ssh_keys.set` 注入(CR/LF、`command=` 等選項、行數、長度、不准動 `ssh_keys.added` 以外的行 = lab key 不能被刪)、`claim.replay` 每小時 10 次的限制、`sign.*` 不能被當成任意簽章 oracle(purpose 固定)、額度 |
| §3:`rc.button/reset` **與 `reset_override`** | 只寫 reset;`reset_override` 存在而且會 jffs2reset(E9) |

另外,§4.1 的 owner-op 清單有 `owner.*`、`settings.set`、`network.leave`,但動詞表沒有 → P1 到底實作哪些動詞要逐一列出。

**修法**:補一張「上層列 → 測項」的完整對照表,每一列寫測項名稱或「不在 P1」及理由;授權負測試大多可以放 CI(`go test` + provclient + 向量),節點上做 smoke。

### M6. `prov-legacy-upgrade-254` / `prov-downgrade-254` 在常規全套裡不能重複跑

reset 之後 helper rc 9 會在 p5 產生 `prov{legacy}`(§4.4 第 3 步就是這樣斷言的)。下一次跑「wsl.9 → P1」時,`--prov-get` 回 rc 0,不是 rc 9 → 要測的路徑沒被走到:不是 FAIL 就是假 PASS。前置條件也沒寫:要 committed 在舊版、p5 沒有 prov、兩個槽的 overlay 都沒有 prov;也沒寫 P1 出貨後「舊版」改用哪一個(要釘一個 payload,例如 1.5.11-rel.1 或 wsl.9,放在 DV 工具並驗 sha)。

**修法**:寫出前置條件和準備步驟:在舊版槽、helper 不在的情況下,用 B2 的備份還原機制把 p5 回到「沒有 prov」;斷言 helper log 寫的是 rc 9,而不只是最後的狀態。

### M7. helper ↔ config-save 介面只用假的東西測

- `prov-unit-helper-boot` 用假的 p5 跑 `go test`。如果 `--prov-get` 也是假的,那兩個元件各自都對、但 rc 表彼此對不上時,沒有任何測試抓得到——正是審查規則最在意的那一類 bug。
- `prov-unit-cfgsave` 在 WSL / CI 用 bash 或 dash 跑,不是節點上的 busybox ash。而且以 root 在主機上跑時,`BATMAN_P5_*` 只改 p5 的位置,其他路徑仍然碰主機:`/etc/shadow`、`/etc/dropbear`、`/tmp/run/batman`、`/proc/mounts`、`/dev/mmcblk0p7`、uci。

**修法**:
- 加一個整合測項:真的 helper `--boot`(`--root`)+ 真的 config-save,放在 loop ext4 上,用 busybox ash,在 `unshare -m` 的 mount namespace 裡(或 chroot 進節點的 rootfs),逐一跑每個 rc;
- config-save 的單元測試也用同一個沙箱。

---

## MINOR

- **m1** `rc.button/reset` 放在 feed 套件裡,會和 base-files 的同名檔衝突(opkg 沒有 `--force-overwrite`,E9)→ image build 失敗。要用 firmware `files/` overlay(和 shim 一樣)或 base-files patch。99zz 同時寫在 `batman-provision/files` 和 `batman-prov` 套件「安裝 99zz」裡 → 只能有一個擁有者。
- **m2** 99zz 在 helper 不存在或失敗時要 fail-closed:shell 自己判 `prov.meta` / verdict,把 AP 設成 placeholder。image manifest 閘要斷言 `batman-prov` 有進 image(1.4.12 掉套件的教訓)。
- **m3** `halow-setkey` 的 `radio_managed` 警告要讀什麼?`radio_managed` 只存在 `prov.cbor`(shell 解不了 CBOR),介面沒定。建議:helper CLI 查詢,或在 `prov.meta` 加一個 key;查不到時只是少一條警告(fail-open,可以接受,但要寫明)。#202 閘讀 `prov.meta` 時要驗格式與 sha;格式壞 → 擋(fail-closed)。
- **m4** `BATMAN_P5_DEV` / `BATMAN_P5_MNT`:只有 root 能用,不擴大權限 ✅(我找不到非 root 能影響 root 呼叫者環境的路徑:procd 的服務環境是乾淨的,CGI 的變數都帶 `HTTP_` 前綴,uevent 檔是 root 0200)。但值的格式要驗(`/dev/loop*` 或 `/dev/mmcblk0p5`,以免 `--seed --reformat` 把錯的裝置 mkfs);helper exec 時給明確的環境變數,不要繼承。
- **m5** provd uid 要固定數值,並確認不等於任何容器內使用者的 uid(沒有 userns 時 `SO_PEERCRED` 的數字是共用的;04 的容器用 1000、999、rabbitmq)。busybox `start-stop-daemon -S` 遇到相符的程序就不啟動 → 用唯一的 `-x` 路徑。
- **m6** P-U4 的 preflight 檢查「節點是 legacy」是產品狀態,和 H1 P6「不擋產品狀態」的原則衝突。不重議 P-U4,但要寫清楚:它擋整個 run,還是只擋 prov-\* tier B;wsl.9(沒有 helper)上的 legacy 怎麼定義;讀不到 = FAIL。
- **m7** 上層文字不一致(請回報上層):§10 第 4 點「fp / check 納入 prov」和 §4.3「fp 排除 prov」矛盾;L25「步驟 3–4 之間 `reboot -f` → state=claimed」,依 §4.4 第 6、7 步應該是 member(gen_to 已提交);`rc.button/reset` 在 §3 / §4.5 屬於 P1,在 §10 第 6 點屬於 P3。
- **m8** `prov-overlay-wipe` 在 04 的副作用要先列出來(E13:OTS 的 init 腳本、Tailscale、crontab、uhttpd 憑證、openmanetd.db 都只在 overlay 上;等同一次 fresh overlay 的 OTA,但是發生在同一個槽)。04 的 p6 已經累積 5 份沒清的 `dv289-backup-*`(E12)→ 本設計的備份要寫明清理規則(先印出再刪)。
- **m9** 96 的上鎖「接線」只有 `:89` 有節點測試;`:64` / `:67` / `:71` / `:93` 這幾個出口有沒有真的呼叫 `prov_lock_decision`,沒有任何測試。純函式的單元測試涵蓋不了接線。至少補「p5 有 `prov.meta=claimed` 但沒有 `.seeded`」(`--save` 失敗後的真實狀態)→ `:93` 出口要上鎖。
- **m10** tier B 照 H1 §7「只在釋出前、人在場時跑」,要寫明。02 的 p3 沒有 `core_freq_min`(上層 §11)→ 02 永遠不會有 `ble-ok`,(8) 只能在 04 跑。
- **m11** 上層 §6.4 ⚠️ 要求三種 caller 都要實證(`-T`、真 OTA、中止後 LuCI validate);H2 只有 `-T`。
- **m12** provclient 的 CBOR 函式庫(⚠️ ugorji)與 CI 的 Go 工具鏈是新的供應鏈:要 vendor + `go.sum`,`setup-go` 釘 commit。helper 的 CBOR 嚴格解碼器建議加 `go test -fuzz` 的種子語料。
- **m13** 上層 L2 是 `prov-boot-254` ×3(三次開機),本設計寫成「每台」。L3 clean shutdown(helper K15,boot-reasons 乾淨)沒有測項。
- **m14** `prov-reset-legacy` 本身就是 p5 prov 檔的第二個寫者(上層 §3:只有 `--prov-only`)。測試工具可以例外,但要在 §3 寫明,並且受 `cfgsave.lock` 約束(見 B2)。

---

## 已確認成立(✅)

- 99zz 的排序在 `99-halow-identity`、`99-batman-chanfix`、`99_morse_radio_defaults` 之後,只有 `luci-i18n-*` 在它後面(E8)。
- F3 / F4 / F8 / F9 / F10 / F11 都和原始碼相符(96 `:64/67/71/89-91/93/161-176`、config-save `:302-304`、`:391`、setkey `:147`、keyguard `:22-46`、joinwatch `:145`)。
- feed pin 到 main 之間沒有產品差異(E10)。
- P-U2(獨立 provclient)和 P-U3(全部動詞)在元件表有體現,但 P-U3 的負測試不完整(M5)。P-U1 的 reset 不完整(B2 / B3)。P-U4 的「真機」排錯了機台(B1;改到 04 仍然符合 P-U4)。

## 判定

**REJECT**。B1–B3 修好之前,照設計跑 tier B 會讓 02 失聯,或讓機隊留在公開的金鑰與擁有者上。修完要整份重審。
