# 審查 A 第 3 輪:`254-p1-impl.md` v3(PR-P1 + PR-H2)

審查者 A,2026-10-21。範圍:**整份** v3,對照上層 `254-stage1-impl.md` v19、main f1a1122 原始碼、firmware-2710 rootfs、GitHub release v1.5.11、02 / 04 唯讀實查(只跑讀取指令;沒有印任何秘密)。

**判定:REJECT**:1 BLOCKER / 7 MAJOR / 11 MINOR。

v3 解掉了 v2 大部分的 MAJOR:provclient 的路徑、p5 兩段式比對、S0 = A 加槽修復、`stage-root` 作廢 B、主機 ↔ provclient 的簽章往返、(7) 的角色分配、動詞表、pending 機制。新的機制本身我逐一驗過:boot-only payload 確實能通過 `stage-root` 的 precheck、release asset 裡有 squashfs。

但鏈 1 第 7 步照寫的做,會讓 04 被鎖在外面,而且救不回來(BLOCKER)。另外:
- S0「B 一律作廢」拿掉了 02 的備援槽,也會讓同一次全套裡的 ab-selftest 失敗;
- #202 閘的放寬超出上層,重新打開了 strand 的路徑;
- 沙箱只隔離 mount namespace,在節點上會真的重開機或改網路;
- 每天的 `prov-boot` 會把 shadow 和金鑰寫到 world-readable 的 `/tmp`。

---

## 0. 本輪證據(唯讀)

| # | 事實 | 證據 |
|---|---|---|
| W1 | `stage-root` → `precheck`:需要 `boot/kernel8.img`、`SHA256SUMS` 有 `root.squashfs` 這一列、`metadata` 有 `size=`(串流 rootfs 的大小);payload 帶 `root.squashfs` 反而拒絕。接著 `begin_write`(disarm tryboot、BATMAN-BAD、刪 `slot-T.protected`)→ `clear_root`(把 B 開頭 `SQ_MB+64` MiB 寫零)。04 的 payload `metadata` = `board=… version=… size=112631352` → **boot-only payload 可行** ✅ | `batman-slot:419-438,561-623`;04 `tar xzOf ota.tar.gz metadata` |
| W2 | `precheck` 會先跑完整的 `node_checks`:#202 閘、`p5_freshness_gate`(執行 `batman-config-save --check`,並寫 `$RUNDIR/p5-check.rc`)、`[tryboot]` 指向檢查。p5 stale → `die` | `:507-560` |
| W3 | 在 B 的 trial 裡跑 `node_checks`:`T` = A;此時 autoboot 的 `[tryboot]` 還指著 B(=2),`fw_part(A)` = 1 → 最後一定 `die "mis-aimed tryboot"`。只有在 autocommit 已經 commit B 之後才會 rc 0 | `:555-559` |
| W4 | ab-selftest 的 happy path 用 raw tryboot 開 B,期待「switched」;B 被作廢 → 開進 BATMAN-BAD + 無 rootfs 的 cmdline → `panic=10` 回到 A → `bad "tryboot did not switch"`。H1 的 N3(`negctl-old-slot-254.sh`)需要 B 上有「舊版」build | `ab-selftest.sh:227-241`、`negctl-old-slot-254.sh:2-4`;daily-validation `:237-241` |
| W5 | 95 每次開機寫 `slot-<自己>.protected`;`halow-status` 的 `fw_protection` 會顯示 partial(只是 json 欄位,不影響 HEALTH) | `95:717`、`halow-status:148-149` |
| W6 | 節點:有 `/dev/loop-control`、`/dev/loop0-7`;kernel `CONFIG_PID_NS=y`、`NET_NS=y`、`UTS_NS=y`;root 的 umask 是 `0022`;`/tmp` 是 1777;`sysupgrade -l`(`--list-backup`)存在 | 04 實查 |
| W7 | Pi 4 的 trial 期限預設 600 s(`DEF=600`,上下限 300–3600) | `batman-autocommit:378-380` |
| W8 | release v1.5.11 的 assets:`…-bcm2711-ab-payload.tar.gz`(122 MB,內含 `root.squashfs`)、`…-bcm2711-ab.img.gz`、bcm2710 的同類兩個、`SHA256SUMS` | `gh release view v1.5.11` |
| W9 | batman-provision 是以 Makefile 逐檔 `INSTALL_BIN` / `INSTALL_DATA` 安裝,不是整個 `files/` 樹複製 | `feed/batman-provision/Makefile:62-111` |
| W10 | 上層 L44:「#202 閘 prov-aware:p5 `prov.meta` state=**unclaimed** → 不擋」;上層 §4.3:`--prov-only`「不碰 `.seeded`」 | 上層 `:374`、`:220` |
| W11 | `batman-slot detect_layout` 必須從 `/proc/device-tree/compatible` 讀到 SoC;`assert_fw_sane` 要從整顆碟數 FAT;`node_checks` 要讀 `/boot/autoboot.txt` | `:128-131,188-196,238-246` |
| W12 | config-save 的 `--on-join` fp 包含 dropbear host key、`authorized_keys`、`/etc/openmanet/config.yml`、shadow;PRESERVE 清單含 `openmanetd dhcpconfigured` | `batman-config-save:188-196`;`p5-config-partition.md:89` |

---

## BLOCKER

### B1. 鏈 1 第 7 步:在 B 上認領之後,harness 再也登不進 04,而且 B 已經 committed → 只能到現場處理
- **情境**:
  1. 第 7 步「不 hold → autocommit commit B」。B 是 fresh、p5 未 seed → **沒有 `authorized_keys`**:Lane A 沒跑,EEPROM 的 key 讀取也已被 shim 停用。harness 是以 `none`(空密碼)登入的。
  2. 接著「經 eth 以 provclient 認領 → claimed」。認領會上鎖(上層 §6.2):`PasswordAuth=off`、`RootPasswordAuth=off`、隨機 root 密碼、`ttylogin=1`。
  3. 依 §4.2,回應裡的 root 密碼**只輸出 sha8**。
  4. 結果:沒有 key、密碼沒有人知道、serial 也要那個密碼、B 已經 committed、沒有 trial 可以 revert。下一步「OTA rc 進 A」根本送不出去(除非剛好留著那條 root ssh session)。04 被鎖死,只能拔卡重燒。這正是使用者規則「nothing can strand 04」要防的事。
- 上層 L47「上鎖後 key 登入仍可用」的前提是節點**先有** lab key,而 fresh 的 unclaimed 槽沒有。
- **修正**(擇一,並寫進 §5.4 與副作用表):
  - (a) 認領**之前**,以 root 把 lab 公鑰寫進 B 的 `authorized_keys`。這也符合上層 `ssh_keys` 的前提,而且必須在同一個 session 裡先斷言 key 登入可用,才送認領。
  - (b) 認領在 **held** 的 trial 上做,失敗時靠 deadline revert 回 A。但這會讓 (2) 的「commit」斷言要改走另一條路。
  - (c) 認領後在同一個 root session 裡馬上以 owner-op `ssh_keys.set` 加 key,先斷言 key 登入可用,才離開 session。

  無論選哪一個,都要加上「key 登入不可用 → 不得 commit、立刻 `back_to_a`」的守門條件。

---

## MAJOR

### M1. S0「B 一律作廢」是一個長期的節點狀態,它拿掉了 02 的備援槽,也會讓同一次全套的其他測項 FAIL
- **02**:今天 A 壞到 firmware 開不了機時,EEPROM 會走到 B 那個仍然可開機的舊 image → 02 還連得到。B 被 `stage-root` 作廢之後(BATMAN-BAD、無 rootfs 的 cmdline、rootfs 開頭被寫零,W1),走到 B 就是 `panic=10` 的重開迴圈 → 02 沒有乙太網 = 被卡在現場。S0 是**測項之間的常態**(§4.5「每台」),所以兩次 run 之間,02 一直沒有備援槽。
- **全套**:ab-selftest(default / destructive)直接 raw tryboot 開 B → B 被作廢 → `tryboot did not switch` FAIL(W4)。H1 的 N3 需要 B 上的舊版 build(W4)。設計沒有寫 prov tier B 在全套裡排在哪裡,也沒有寫結束時要把 B 恢復成可開機。
- **修正**:
  - 02 不作廢 B。02 只參與 (7) 和雙台 member,它的 B 測完以 held trial 重寫成 V 並讓它 revert;或者至少保持「B 可開機」。
  - 04 在整個 prov 套件結束時把 B 寫回可開機的 V(apply 加 held trial,讓它 revert),或者把 ab-selftest 排在 prov 套件之前,並由 P9 斷言順序。
  - §7.2 寫出「B 被作廢期間沒有備援」的風險,以及持續多久。

### M2. 測項中 A 被重建時,A 的個人化會漂移,restore 的清單蓋不到;鏈 1 最嚴重
- **鏈 1 第 7 步**:B(unclaimed fresh)在認領時 `--save` → p5 被 **B 的**設定 seed:B 的隨機 `10.41.254.x`、`dhcpconfigured`(0,或 B 的 openmanetd 保留後的值)、B 重新產生的 dropbear host key、B 的 `config.yml`(W12)。接著「OTA rc 進 A」→ fresh 的 A 由這份 p5 還原,A 變成 B 的個人化。
- restore 第 2 步把 p5 寫回原本的,第 3 步只寫回 `wireless`、`network`、`system`、`dropbear`(uci)、`authorized_keys`、`shadow`、`batman-prov`。**沒有寫回** `/etc/dropbear/dropbear_*_host_key`、`/etc/config/openmanetd`、`/etc/openmanet/config.yml`。後果:
  - A 的 host key 換了。開機後 joinwatch 的 `--on-join`(fp 含 host key,W12)會把新的 host key 寫進 p5 → **原本的 host 身分永久被取代**,主機上 `known_hosts` 對 10.41.1.3 的 pin 失效,BatchMode ssh 會失敗。
  - `dhcpconfigured` 如果是 0,而 `network` 寫回了 10.41.1.3 → openmanetd 會重新保留位址並重開(F8)→ **04 的 IP 改變**,harness 找不到它。⚠️ 實際的值要在 E1 查,但這條路沒有被排除。
- **其他會重建 A 的路徑**:`prov-legacy-upgrade` 第 3 步、槽修復。F16 的 overlay-only 項目(crontab、uhttpd 憑證、`openmanetd.db`)只在「只給 overlay-wipe」時被快照 → 這兩條路徑之後也會悄悄丟掉。
- §4.5 第 7 步的斷言只比對清單裡的路徑,所以上面這些漂移完全不會被發現。
- **修正**:
  - 「測項中 A 被重建過」時(以 boot-reasons 或 A 的 overlay 世代判定),restore 改成:先 dd p5 → 在 A 上 `firstboot` → 重開,讓 96 從**原本的** p5 完整重建 A → 再寫回 F16 項目。
  - F16 項目在**每一次** snap 都記錄。
  - 第 7 步的斷言加上:host key 的指紋 == 快照、ahwlan IP == 快照、`dhcpconfigured` == 快照。
  - 負對照:跳過 firstboot → 指紋斷言 FAIL。

### M3. §4.9 把 #202 閘放寬到 claimed / member,超出上層 L44,而且重新打開 #202 要防的 strand 路徑
- **情境**:上層只放行 `prov.meta` state=**unclaimed**(W10)。unclaimed 本來就沒有 mesh、NEED_MESH = 0、不需要被 seed 的 per-node 設定。v3 把 claimed / member 也放行。
- member 節點的 p5 只有 prov、沒有 `.seeded`,代表 `net.apply` 第 5 步的 `--save` 一直沒成功(rc 1 只寫 log,上層 §4.4)。這時 OTA 會被放行 → fresh 槽的 96 在 `:93` 離開 → 用 image 預設的 placeholder mesh key → keyguard 關掉 mesh radio → helper 開機時「沒有 `.txn` 就不對帳 wireless」(上層 §4.4 第 6 點)→ **只有 mesh 的 member 節點會失聯**。這正是 `batman-slot:528-551` 註解寫的情境。
- 另外,§4.9 自己寫的理由「`.seeded` 的意思是每台設定已 seed」,反而說明 claimed / member 的 p5 沒有 `.seeded` 就是不完整。
- §10 第 7 點把「`--prov-only` 不寫 `.seeded`」列成可能和上層衝突,其實並不衝突:上層 §4.3 本來就寫「不碰 `.seeded`」✅。真正和上層衝突的是閘的放寬。
- **修正**:閘只放行 `.seeded` **或**(`prov.meta` 格式 / sha 正確且 state = unclaimed),照上層。`prov-unit-gate` 加上「member + 無 `.seeded` → 擋」的案例。鏈 1 第 7 步的「gate 依 prov 放行」改成依 `.seeded`(認領的 `--save` 會 seed;上層 (2) 也寫「`--save` 已 seed」),並斷言它。

### M4. `dv-sbx` 只做了 mount namespace,在節點上會真的重開機、真的改網路;`prov-unit-gate` 在 CI 上照寫跑不起來
- **隔離不足**:`CLONE_NEWNS` 加 chroot,PID、網路、UTS 都和主機共用,又是以 root 執行:
  - busybox `reboot` 會對 PID 1(真的 procd)送訊號;`reboot -f` 直接呼叫 `reboot(2)`,不受 mount namespace 影響;
  - `halow-setkey` / `--apply-state` 路徑上的 `iw`、`ip`、`batctl` 走的是真的 netlink,真的介面;
  - `prov_test` 的 mutant 或 killpoint 一觸發 `reboot -f`,**04(或 CI runner)就會真的重開**。

  節點支援 PID / NET / UTS namespace(W6),所以修得起來。
- **環境不夠**:`batman-slot precheck-node` 需要 `/proc/device-tree/compatible`(否則 `detect_layout` 直接 die)、整顆碟的 GPT(數 FAT)、`/boot/autoboot.txt`(W11)。CI 的 arm64 runner 這些都沒有;節點上 chroot 的 `/dev` 只有 `mmcblk0p5`。所以 `prov-unit-gate` 在兩種底上都會 die 在閘之前 → 這是「找不到東西卻要能判」的測項。
- **修正**:
  - `dv-sbx` 加 `CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWUTS | CLONE_NEWIPC`,丟掉 `CAP_SYS_BOOT`、`CAP_SYS_MODULE`、`CAP_SYS_TIME`,在 chroot 裡放 `reboot`、`wifi`、`ubus` 的 stub;
  - 加負測試:沙箱內 `reboot -f` 不會重開、`ip link add` 在主機上看不到;
  - 沙箱的 `/opt/batdata`、`/tmp/run` 一律是私有的 tmpfs(要寫明),不能 bind 真的 p6 或 RUNDIR;
  - `prov-unit-gate` 改用 `tests/ab-card-invariants.sh` 既有的 loop 卡(真 GPT 加 FAT),再加上偽造的 DT `compatible` 與 `/boot`;或者明寫這一項只在節點上跑,並說明為什麼。

### M5. 鏈 1 第 6 步 gate 的判讀是「沒有出現某個字串」,沒有鑑別力
- **情境**:在 B 的 trial 裡,P1 版本的 `precheck-node` 通過 #202 閘之後,會 die 在 `[tryboot]` mis-aim(W3)。如果 autocommit 已經 commit B(這一步不 hold),它就會 rc 0。wsl.9 版本則 die 在「not seeded」。判讀規則是「不得出現 not seeded」:任何更早的失敗都會被算成 PASS,例如 `TRIAL_APPLY` 沒生效 → die 在 trial 檢查、fw-override、`assert_fw_sane`。這正是「找不到東西卻判綠」。
- **修正**:要求**正向證據**:本次呼叫寫出的 `$RUNDIR/p5-check.rc` = `skip:unseeded`,時間戳是呼叫之後(W2:只有通過 #202 閘才會走到 `p5_freshness_gate`);rc 與最後一行 die 的訊息都要列為預期(mis-aim 或 0)。wsl.9 負對照的預期則是 rc 1 + 「not seeded」+ 沒有新的 `p5-check.rc`。

### M6. 每天的 tier A `prov-boot` 以 `sysupgrade -b /tmp/x.tgz` 把 shadow 和金鑰寫成 world-readable
- **情境**:root 的 umask 是 0022,`/tmp` 是 1777(W6)。這份備份包含 `/etc/shadow`、`/etc/config/wireless`(mesh / AP key)、dropbear 的 host key 等,檔名是可預測的 `/tmp/x.tgz`,權限 0644。存在的那段時間裡,本機任何非 root 程序都讀得到。這是每天在正式 fleet 上發生的秘密外洩(「本機非特權程序」這個 actor)。
- **修正**:改用 `sysupgrade -l`(只列出會備份的路徑,不產生 archive,W6),斷言輸出裡沒有 `etc/batman-prov`。如果一定要產生 archive,就寫到 root 0700 的 `/tmp/run/batman-dv/`、`umask 077`,並加入 canary 掃描。

### M7. pending 的結束狀態沒有定義,和「找不到東西就必須 FAIL」的規則衝突
- **情境**:§6 寫 PENDING「印出,不計入 n,不算 PASS」,CI 沙箱 job 在 `feed/batman-prov` 不存在時也是 PENDING,但都沒寫 **exit code**。如果是 0,H2 merge 到 P1 merge 之間,CI 的沙箱 job 是綠的,卻什麼都沒測,違反使用者規則。這也是一個新的例外機制(類似 known-failures),要使用者同意。
- **修正**:明定 PENDING 的 exit code ≠ 0,或在報告裡歸為 KNOWN(同 known-failures:不會變綠,只是分類);CI 用 neutral / 有標記的狀態,不顯示為 success。過期 = FAIL(已寫)。列入 §10 或 §1.1,請使用者決定。

---

## MINOR

- **m1** snap 第 8 步和 restore 第 5 步的 `stage-root`,以及第 0 步的槽修復(`apply`),都會經過 #202 閘與 `--check`(W2)。所以:snap 時 p5 stale → 測項開不了始;restore 第 0 步發生在 p5 dd(第 2 步)**之前**,遇到 identity-mismatch 或 stale(§4.8 會讓 `--check` rc 5)→ 槽修復 die → restore 永遠失敗。**修正**:第 0 步之前先做 p5 dd,或槽修復帶 `BATMAN_ALLOW_STALE_P5=1`,並寫明理由。
- **m2** 鏈 1 第 4 步「OTA → 刪覆寫檔 → 重開前再斷言」:`sysupgrade` 在 stage 2 結束就自己重開,沒有「重開前」這個時間點。要改用直接 `batman-slot apply`(加 `BATMAN_ALLOW_UNSEEDED=1` env)再手動重開,並註明這是 L42 的路徑(沒有 `ota-armed.mesh`)。
- **m3** 成本低估:Pi 4 的 trial 期限是 600 s(W7)。每個 held 或 revert 的測項 ≈ OTA 5 分 + 開機 + 最多 10 分等到期限 + revert 開機 + snap / restore(各含一次 `stage-root`,restore 再加一次重開)≈ 25–30 分。§5.3 + §5.5 約 26 個單位 → **約 10–13 小時**,不是 5–6 小時。請重算後讓使用者知道。
- **m4** 沙箱的疊加不能照 `files/` 整個樹複製,要照 Makefile 的 install 規則(W9)。否則「新檔忘了加 install 規則」在沙箱 PASS、產品卻壞掉。另外加一個 lint:`files/` 下每個檔都有對應的 install 行。CI 底用 release 的 **payload** tar(W8,內含 `root.squashfs`,不用從 img 解 p2);release 也有 bcm2710 的 payload → `prov-unit-bcm2710` 可以直接在 CI 跑。
- **m5** §5.7 不完整(文件自己也承認)。沒有列出歸屬或理由的上層列:L4、L6、L13 / L14、L16、L19、L20 / L32(helper 在下一次開機自己重試,這是 P1 的行為 → 需要測項)、L24、L26–L28、L31、L41、L59、L62–L65。
- **m6** killpoint 檔放在 `/tmp/run/batman-prov/`,這是 helper 的 socket 目錄;helper 啟動時會「清掉殘留」並驗證擁有權。必須先放 killpoint 才能啟動 helper,但 helper 會不會把它當殘留刪掉?順序要寫清楚。
- **m7** 「02 不會走到槽修復」沒有保證:hold 旗標的版本不符 → `HOLD-COMMIT-DISCARDED` → 02 照一般規則 commit。修正:照 N3 的做法,02 的 trial 先斷言 hold 生效;否則立刻 `back_to_a`。並寫出 02 經 mesh 做槽修復的路徑。
- **m8** `precheck-node` 不是嚴格唯讀:會寫 `$RUNDIR/p5-check.rc`、建 cfgsave 鎖目錄、在 overlay 上 `mkdir` / `rmdir` `/mnt/p5seed.$$`(W2)。影響不大,但文字要改,並註明 `p5-check.rc` 之後 600 s 內會被 stage 2 採信。
- **m9** 單台網路測項的 lease 上限 < 3000 s。`prov-powerloss` 有三個 killpoint,每個都要重開,再加 restore,總時間可能超過。要寫明每個 killpoint 各做一次 snap / restore,或者算出它塞得進去。
- **m10** 測項表的負對照欄還是「—」:`prov-unit-bcm2710`。可以用「拿掉 cortex-a53 helper」這類 mutant,或明寫這項只是 smoke。
- **m11** 04 上的 FI_PAYLOAD `/opt/batdata/ota.tar.gz` 是 `version=20261018-113030`,和現在跑的 build 不一定相同。§4.5 的 boot-only payload「= 受測 payload 的 `boot/`」要明寫來源,並驗 sha,不要沿用這個檔。

---

## v2 發現的狀態

| v2 | 狀態 |
|---|---|
| M1 provclient 路徑 | ✅ `/tmp/run/batman-dvpc.*`(`/tmp/run` 0755,`batman-dv` 0700 不動) |
| M2 p5 逐位元組 | ✅ dd 後比映像 sha,重開後比 `ro,noload` 的清單 |
| M3 槽位 / 基準 / legacy-upgrade | ⚠️ 一部分:S0 = A、槽修復、釘住的 wsl.9 加 `strip-p5-prov` ✅;A 被重建後的漂移(本輪 M2)、修復順序(m1) |
| M4 armed tryboot / 另一槽復活 | ✅ `stage-root` 確實會 disarm 並作廢(W1);但帶來新的副作用(本輪 M1) |
| M5 (7) 角色 | ✅ |
| M6 簽章與秘密的流向 | ✅(fd 3、20 s、擁有者私鑰只在 WSL) |
| M7 過渡期 | ⚠️ lint pending、到期欄、不混 fleet、CI 有底 ✅;PENDING 的 exit code(本輪 M7)、沙箱的可行性(本輪 M4) |
| M8 動詞 / 對照表 | ✅ §5.6;§5.7 還有缺(m5) |
| M9 新槽鏈 | ⚠️ joinwatch、E1 改走 bypass、02 隔離 ✅;第 7 步鎖死(B1)、第 6 步判讀(M5)、第 4 步時序(m2) |
| m1–m18 | ✅ 大部分已解(拿掉 P5 接縫、不掛 f2fs、lease 互斥、`halow-status`、清單、canary、killpoint 清單、buildinfo、bcm2710 沙箱);m14 成本 → 本輪 m3 |

## 我確認成立的部分
- boot-only payload 確實能通過 `stage-root` 的 precheck:需要 `metadata size=`,04 的 payload 有(W1)。
- release asset 可以取得 squashfs(W8)。
- 節點支援 loop-control 與 PID / NET namespace(W6)。
- §4.9「`--prov-only` 不寫 `.seeded`」和上層一致。
- 第 6 步的 wsl.9 負對照確實走不同的程式碼(會 die 在「not seeded」),只是判讀方式要改(M5)。
- §4.8 的 fail-closed 方向合理,等使用者確認 P-U6。

## 判定
**REJECT**。B1 照寫做會讓 04 停在一個被鎖住、沒有 key、已 committed 的槽上,只能到現場救。M1–M7 涉及:02 的備援、同一次全套的其他測項、和上層衝突的閘、沙箱會真的影響節點、每天的秘密外洩、「什麼都沒測卻判綠」。修完後請整份再審。
