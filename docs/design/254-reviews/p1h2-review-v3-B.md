# 審查 B 第 3 輪 — `254-p1-impl.md` v3(PR-P1 + PR-H2)

審查者 B(獨立)。審查整份 v3(517 行),對照的依據:
- 上層 `254-stage1-impl.md` v19(main f1a1122);
- main 原始碼;
- 02 / 04 唯讀實查。

沒有寫入節點、沒有重開、沒有重啟服務,也沒有印出任何秘密。

**判定:REJECT**:1 BLOCKER / 5 MAJOR / 10 MINOR。

v3 解掉了 v2 大部分的發現,方向正確:
- provclient 放在 `/tmp/run/batman-dvpc.*`;
- p5 改比映像 sha 與檔案清單;
- 還原前先回到 A,並有槽修復;
- 另一槽用 `stage-root` 作廢;
- 鏈 1 從 mkfs 到重開都停 joinwatch;
- gate 改用 `precheck-node` 判讀;
- 四個負對照改到有鑑別力;
- 拿掉產品接縫;
- CI 改用 arm64 原生 runner。

但仍有下列問題:
- **鏈 1 第 7 步照寫會把 04 鎖死,只能到現場救**(BLOCKER)。
- S0「B 作廢」和現有的每日驗證、ab-selftest 衝突,也拿掉了兩台的 rollback 退路。
- 還原清單漏了身分檔與 openmanetd 設定,鏈 1 之後 restore 會失敗、04 的 IP 會變。
- #202 閘的放行範圍比上層寬,在 P1(沒有 BLE)上多出一條讓節點失聯的路。
- `dv-sbx` 在正式節點上跑,但隔離契約沒寫。
- §4.8 的 fail-closed 有兩個漏洞(判斷順序、`--check` 遇到 rc 7 提早離開)。

---

## 0. 本輪驗證的事實

| # | 事實 | 證據 |
|---|---|---|
| W1 | **image 預設沒有 `authorized_keys`**:`/rom/etc/dropbear/` 是空的;04 的 key 只在 overlay | 04 `ls -la /rom/etc/dropbear /overlay/upper/etc/dropbear` |
| W2 | 96 在 `:93`(未 seed)提早離開,Lane A(`:96-102` 還原 `authorized_keys` 與 host key)不會執行 | `96:93-102` |
| W3 | `stage-root` 會經過 `precheck`:先跑 `node_checks`(#202 interlock 要求 `.seeded`,以及 freshness gate `batman-config-save --check`),再看 payload(要有 `boot/`、`kernel8.img`、boot 檔 sha 相符;`SHA256SUMS` 要有 `root.squashfs` 條目;大小取自 `metadata size=`);**不得**含 `root.squashfs`。之後 `begin_write`(disarm、invalidate、刪 `slot-T.protected`)→ `clear_root` 清掉 SQ_MB+64 MiB。另外會刪掉 `autocommit-skip-once` | `batman-slot:524-613`、`:419-438`、`:614-623` |
| W4 | 每日驗證的 `chk_slotintegrity_209` 要求 `slot-A.protected` **與** `slot-B.protected` 都在,否則 FAIL「only partly protected」 | `daily-validation.sh:593-594` |
| W5 | 還有其他驗證需要 B 可用,或會改槽:ab-selftest `--destructive` 會改 `bootB/start4.elf`、清 rootB 的開頭;`reflash-survives-config-202` 跑完會讓節點停在另一槽;H1 N3 要讀 slot B 自己的 `/etc/batman-build` | `daily-validation.sh:38-44`、`:2111`;`negctl-old-slot-254.sh:6` |
| W6 | hold-commit **不在** `held()` 裡(`held()` 只看 `/tmp` hold、`HOLDC`、hold-once),所以 deadline 的 watchdog 照樣觸發:沒有 `$COMMITTED` → `bad-slot` 寫成「slot+version」→ `reboot committed`。`bad-slot` 只在 commit 時被刪,並且會阻止那個槽以 #133 fallback 的方式被 commit | `batman-autocommit:94-103,196-243,360,502` |
| W7 | `--check` 遇到未 seed 的 p5 會在**任何比對之前**以 rc 7 離開;freshness gate 把 rc 7 記成 `skip:unseeded` 並**放行**(註解寫「只有 allow-unseeded 時才會走到」) | `batman-config-save:337`;`batman-slot:487` |
| W8 | 96 每台持久化的套件 = `system wireless network openmanetd mesh11sd`;身分包含 `identity/dropbear/*` 與 `identity/openmanet/config.yml` | `96:22,96-103` |
| W9 | fresh 槽:`99-halow-identity` 重新個人化 host key / hostname / IP(`10.41.254.x`),並設 `openmanetd.config.dhcpconfigured=0` →「openmanetd reserves the real IP after boot and reboots once」 | 04 `/rom/etc/uci-defaults/99-halow-identity:22-25` |
| W10 | `99-batman-chanfix` 在背景等 wlh0 最多約 80 s 之後才把頻道改回 p5 的值 | `99-batman-chanfix:19-45` |

---

## BLOCKER

### B1. 鏈 1 第 7 步在 committed 的 unclaimed B 上經 eth 認領,會把 harness 鎖在外面;04 只能靠實體處理
- **情境**:
  1. 第 3 步把 p5 mkfs 掉 → B 的 96 在 `:93` 離開 → Lane A 沒跑(W2),image 也沒有 `authorized_keys`(W1)。所以 B 上**沒有任何可用的 key**,harness 只能用 `none`(空密碼,F8)登入。
  2. 第 7 步先讓 autocommit **commit** B(不 hold),再經 eth 認領。
  3. 認領會設隨機 root 密碼,並把 `PasswordAuth` / `RootPasswordAuth` 改成 off(上層 §6.1 第 4 步、§6.2),`none` 從此失效。
  4. root 密碼只出現在認領的回應裡,而 §4.2 規定 provclient 只輸出它的 sha256 前 8 碼 → 沒有人知道密碼。
  5. 結果:**沒有 key、沒有密碼、mesh 被 keyguard 關、AP 是 placeholder,B 又是 committed 的(不會 revert)**。`ttylogin=1` 的 serial 也要那個密碼。第 7 步後面的「OTA rc 進 A」、§4.5 的 restore 全部做不了。
  6. openmanetd 的「保留 IP 後重開一次」(W9)還會讓已經開著的 ssh session 也斷掉。
- **證據**:W1、W2、W9;上層 §6.1 / §6.2;§4.2 的秘密規則。
- **修法**:
  - 認領之前,由 root 在 B 上把 lab 公鑰寫進 `/etc/dropbear/authorized_keys`,並斷言 `PreferredAuthentications=publickey` 登得進去;做不到 → 中止,不得認領。認領的 `--save` 會把這把 key 帶進 p5 `identity/dropbear`,A 的 trial 也就有 key。
  - 在 §7.2 寫明:fresh / 未 seed 的槽上**任何**會上鎖的動作,前提都是「key 登入已驗證」。
  - E1 要另外實證:「commit 一個 fresh 槽」之後,openmanetd 會不會重開、會不會換 IP,以及 harness 怎麼重新找到 04。

---

## MAJOR

### N1. S0「B 一律被 `stage-root` 作廢」和現有驗證衝突,也拿掉了兩台的 rollback 退路
- **情境**:
  - `stage-root` 刪掉 `slot-B.protected`(W3)。之後每日驗證的 `chk_slotintegrity_209` 在兩台都會 FAIL(W4),而且一直 FAIL 到下一次 OTA。這直接違反「測項只能有一套」:prov 測項把機隊留在一個會讓常規全套 FAIL 的狀態。
  - ab-selftest `--destructive` 需要 B 可以開機;`reflash-survives-config-202` 跑完會讓節點停在另一槽,下一個 prov 測項的 `snap` 第 1 步因此失敗;H1 N3 要讀 slot B 的版本(W5)。全套的執行順序和 S0 互相打架,設計沒有處理。
  - S0 也適用 02(「每台」):**02 沒有乙太網**,作廢 B 之後,02 在下一次 OTA 前沒有可以 rollback 的槽。04 是部署角色(OTS),一樣失去退路。這需要使用者決定,目前只在 §7.2 寫了一句「下一次 OTA 前不能 rollback」。
- **我確認可行的部分**:`stage-root` 用只有 boot 檔的 payload 確實可以跑(W3:`metadata size=` 提供大小、`SHA256SUMS` 只要有 `root.squashfs` 條目)。B 被作廢後誤開會因 `root=PARTUUID=<none>` + `panic=10` 回到 A,不是韌體層級的失敗,舊 EEPROM 不會卡在 4 閃。EEPROM 的 partition-1 walk 走到的是 A,與 S0 = A 相容。但這三點都要在 E3 實證。
- **修法**(三選一,並且要先問使用者):
  - (a) restore 最後把 B 寫成有效的 V:`apply` → held trial → `back_to_a`(v2 的做法,多一次開機),S0 = 兩槽都是 V;
  - (b) 保留作廢,但同時以 harness PR 修改 `chk_slotintegrity_209`,讓它接受「B 有 BATMAN-BAD 且 p6 有 dv 紀錄」,並把全套順序定為 prov tier B 最後跑、之後補一次 OTA;
  - (c) 只對 04 作廢,02 保留原來的 B。
  
  無論選哪一個,E3 都要同時跑 `chk_slotintegrity`、`chk_trybootget`、`chk_otatrace`,看結果如何。

### N2. 還原清單漏了身分檔與 openmanetd / mesh11sd 設定:鏈 1(以及任何 p5 被換過身分的路徑)之後,restore 會失敗,04 的 IP 會變
- **情境**:鏈 1 的 B 由 `99-halow-identity` 產生新的 host key、hostname、`10.41.254.x`、`dhcpconfigured=0`(W9)。認領的 `--save` 把這些寫進 p5。A 的 fresh trial 再從這份 p5 還原,所以最後 A 帶著**新的** host key、`/etc/openmanet/config.yml`、`/etc/config/openmanetd`。§4.5 第 4 步的清單只有 `wireless / network / system / dropbear 設定 / authorized_keys / shadow / batman-prov`。restore 之後會發生:
  - `--check` 的 `same_identity` 比對 host key → `p5 stale: identity` → 第 5 步 `stage-root` 的 freshness gate 拒絕(W3)→ restore FAIL;
  - host key 換了 → harness 的 known_hosts 不符,在 BatchMode 下 ssh 被拒;
  - `openmanetd` 設定留著 `dhcpconfigured=0` → openmanetd 重新保留 IP 並重開 → **04 不再是 10.41.1.3**(使用者 2026-10-18 的教訓「改 hostname = openmanetd 換 IP」)。
- **證據**:W8、W9;`batman-config-save:319-327`(`same_identity`)。
- **修法**:snap / restore 的 overlay 清單補上 `/etc/dropbear/dropbear_*_host_key`、`/etc/openmanet/config.yml`、`/etc/config/openmanetd`、`/etc/config/mesh11sd`(= 96 的 `ALLOWED_PKGS` 加上身分)。對 p5 被換過身分的測項(鏈 1),restore 改成「dd p5 → 從 p5 重新 OTA A(fresh overlay 由 96 還原身分)」,不要逐檔寫回。斷言加上:host key 指紋 == 快照、ahwlan IP == 快照、openmanetd 不重開(boot-reasons)。

### N3. #202 閘的放行範圍比上層寬(claimed / member),在 P1 上多出一條讓節點失聯的路
- **情境**:上層 L44 只放行 `prov.meta state=unclaimed`,§2.1 與 §4.9 擴大到 unclaimed / claimed / member。觸發條件是 claimed 節點的 p5 沒有 `.seeded`:認領的 `--save` 失敗(rc 8 lock busy、rc 1),也就是設計自己做的 `claim-before-shadow` 狀態,發生在新卡上。這時 OTA:
  1. fresh 槽 96 在 `:93` 離開 → 沒有 key(W1)、mesh 是 placeholder → keyguard 關掉;
  2. 96 依 `prov.meta=claimed` 上鎖;
  3. autocommit 判「claimed + placeholder → 不需鄰居」→ **commit**;
  4. P1 沒有 BLE → 只有 mesh 的節點完全連不到,serial 也要不知道的密碼。
  
  member 的情況會因 `meshjoin_radio_up` 失敗而 revert,所以安全。真正的問題在 claimed。
- **修法**:照上層,只放行 unclaimed;claimed / member 且未 seed → 擋下,並提示 `--save`。`prov-unit-gate` 加這一列,負對照是 claimed 未 seed 被放行 → FAIL。§10 第 7 點更正:上層 §4.3 本來就寫「`--prov-only` 不碰 `.seeded`」,真正偏離上層的是放行的 state 範圍。

### N4. `dv-sbx` 在正式節點上跑,但隔離契約沒寫;照寫可能動到真的 p5、真的 p6,或讓節點重開
§2.2 說節點那一種底 = 節點的 `/rom` + 已安裝的 helper,以 root 執行。只開 `CLONE_NEWNS` 擋不住下列幾件事:
- **`/dev`**:如果 chroot 的 `/dev` 是 bind 主機的 `/dev`(要拿 `/dev/null` 時最常見的寫法),`mknod mmcblk0p5` 就寫進真的 `/dev`。那個名字本來就存在 = 真的 p5,而 `prov-unit-cfgsave` 有 ENOSPC 填滿測試、`--seed --reformat` 會 mkfs。必須是新的 tmpfs `/dev`,只放必要的節點。
- **p6**:96 會寫 `/opt/batdata/state/lock-status` 與 `log/`。chroot 的 `/opt/batdata` 必須是空的私有目錄,不能 bind 真的 p6。`/tmp/run` 也要是私有的。
- **重開**:`reboot(2)` 不受 mount namespace 隔離。沙箱裡的 `reboot -f`、`batman-slot reboot`、或 autocommit 的 revert,都會讓**真的節點**重開。要加 `CLONE_NEWPID`(非 init 的 pid ns 裡的 reboot 只會殺掉該 ns),或禁止這些案例在節點上跑。
- **硬體**:`/proc/device-tree`、`vcmailbox` 是真的硬體。沙箱裡任何會 disarm / arm tryboot 的路徑(例如 `precheck` 之後的 `stage-root`)都會改到真的 tryboot 旗標。`/dev/kmsg` 會寫進節點的 log(canary 掃描會掃到測試字串)。
- **在哪裡跑**:沒寫要在哪幾台跑。若包含 02,出錯 = 02 的 p5 壞掉 = 下一次 OTA 失聯。

**修法**:寫出隔離契約(新的 `/dev` tmpfs、私有 `/opt/batdata` 與 `/tmp/run`、`CLONE_NEWPID`、不提供 `vcmailbox` / `/proc/device-tree`,或用假檔替代;只在 04 上跑)。加一個負測試:沙箱案例嘗試開啟真的 p5 的 major:minor、呼叫 `reboot` → 必須失敗,節點的 boot_id 不變。

### N5. §4.8 的 fail-closed 有兩個漏洞
1. **和上層 §4.4 第 7 步的順序**:如果先比 gen,遇到「overlay 較新」就會用 overlay 的 `prov.cbor` 重新 `--prov-only`,但 p5 的 `identity/prov/` 是一次寫入、不會換 → p5 變成「X 的擁有權 + Y 的身分」的混合狀態,而且被持久化了(這是 fail-open 的破壞)。必須寫明:identity 比對在 gen 比對**之前**;不一致時不呼叫任何 `--prov-only`。`prov-unit-helper` 加這一列(mutant:先比 gen → 寫入混合 → FAIL)。
2. **`--check` 在未 seed 時提早離開**(W7):p5 沒有 `.seeded` 時,`--check` 直接回 rc 7,不比 prov、也不比 identity,freshness gate 記 `skip:unseeded` 並**放行** OTA。所以「`--check` 報 `prov-identity` → 擋 OTA」只在 seeded 時成立。prov 的比對要移到 `:337` 之前;`batman-slot:487` 的 rc 7 註解也要更新(在 P1 下已經不只是 override 才會走到)。

另外兩點:
- `P5_STALE_HINT` 對 prov 寫的是「`--persist-now`」。不一致時 `--persist-now` 必須拒絕,而且提示文字要不同。
- 恢復方法 = `allow-stale-p5` 覆寫後 OTA:fresh 槽會採用 p5 的 Y,等於「p5 優先」。要寫進 §4.8 的「恢復」,讓使用者在 P-U6 一起定案。

---

## MINOR

- **m1**:槽修復(§4.5 第 0 步)在 hold 下手動 `batman-slot commit`。但 hold-commit 擋不住 deadline watchdog(W6):deadline 一到,它會把**剛 commit 的槽**記成 `bad-slot`,然後重開。改用 `batman-autocommit release`(設計上的正規路徑,commit 時會刪 `bad-slot`)。p6 清單也要加 `bad-slot` 與 `autocommit-skip-once`(`stage-root` 的 precheck 會刪掉它,W3)。
- **m2**:`claim.verify` 需要 `claim.secret`(root 0600)。§4.2 只說 `net_secrets` 的明文走 fd 3,`claim.secret` 怎麼交給 provd uid 的 provclient 沒寫。busybox `start-stop-daemon -c` 會不會把 fd 3 傳下去也沒實證。
- **m3**:tier A 每天跑 `sysupgrade -b /tmp/x.tgz`,在 world-writable 的 `/tmp`、以預設 umask 產生一個含 `/etc/shadow` 與 wireless key 的 tar → 本機非 root 程序可以趁機讀。改用 `umask 077` 並寫到 root 0700 的 run 目錄。
- **m4**:`-wbox-chan` 的 S99 可能早於 chanfix 背景的改回(最多約 80 s,W10)。mutant 要等 chanfix 完成的 log 再動作。而且不得用 `halow-setkey`(它一律 persist,F10):harness 中途死掉的話,p5 的頻道會被改壞。只用 `uci` + `wifi reload`。120 s 的前置斷言很好,保留。
- **m5**:鏈 1 第 7 步寫「gate 依 prov 放行」不正確:認領的 `--save` 已經 seed 了 p5(含 placeholder mesh key 與 B 的隨機 IP),gate 是因為 `.seeded` 才放行的。A 的 trial 也會在 `10.41.254.x`、沒有 mesh、`dhcpconfigured=0` 的狀態下開機 → openmanetd 可能在 trial 裡重開,trial 因此回到 committed 的 B。E1 要涵蓋這條路徑。
- **m6**:overlay-wipe 還原 Tailscale 狀態時,tailscaled 已經在跑,可能已經在 tailnet 註冊了新的機器。還原前先停 tailscaled,之後斷言沒有新增的 tailnet 機器。
- **m7**:§5.6 的缺漏與衝突:
  - 缺上層 §4.1「沒有 `keystore.ecdh` / `persist` / `keystore.sign` / 恢復出廠動詞 → `E_SCHEMA`」這一列;
  - `settings.set` 寫「上層列出的 key」,但上層沒有列任何 key,要在本文件定;
  - `owner.add/remove` 和上層 L29「第二位擁有者 → S3」衝突,要列進 §10。
- **m8**:§5.7 缺這些列:L4、L6、L13 / L14、L16、L19、**L20 / L32**(96 掛不起 p5 → helper 下次開機補回,這是 P1 的行為)、L24、L26–L28、L31、L41、L59、L62、L64、L65。設計自己也寫了「第一步核對」。這張表應在本輪就補齊,而不是留到實作。
- **m9**:`stage-root` 用的 boot-only payload 要放在節點的哪裡(p6?)、sha 由誰驗,都沒寫。E3 要加:作廢 B 之後跑每日的 slot 類檢查(見 N1),以及一般 OTA 進 B 是否正常。
- **m10**:鏈 1 第 6 步寫 `precheck-node` 是「唯讀」,但它會寫 `$RUNDIR/p5-check.rc`(W3 / `batman-slot:466`)。無害,但要照實寫。

---

## v2 發現的狀態

| v2 | 狀態 |
|---|---|
| M1 provclient 放置 | ✅ `/tmp/run/batman-dvpc.*`(`/tmp/run` 0755,F20) |
| M2 逐位元組 | ✅ dd 後比映像 sha;重開後比 `ro,noload` 的清單 |
| M3 restore 的槽與 trial | ⚠️ 第 0 步與槽修復 ✅;`stage-root` ✅(但見 N1);整個目錄取代 ✅;**overlay 清單不完整**(N2);手動 commit(m1) |
| M4 P9 | ✅ `.protected` / BATMAN-BAD |
| M5 joinwatch / gate / L1 | ✅ 停 joinwatch、重開前再驗、硬性斷言、`precheck-node` 夾心對照有鑑別力 |
| M6 identity 規則 | ⚠️ 改成 fail-closed ✅;順序與 rc 7 的漏洞(N5) |
| M7 四個負對照 | ✅(a)(b)(d);(c) 有前置防呆,剩 m4 |
| M8 hold / (2) | ⚠️ 表格 ✅;(2) 的程序會鎖死 04(**B1**) |
| M9 legacy-upgrade 重複跑 | ✅ |
| M10 沙箱 | ⚠️ CI arm64 + repo tree ✅、拿掉產品接縫 ✅;節點的隔離契約缺(N4) |
| M11 動詞 | ⚠️ 表格 ✅、P-U7 ✅;m7 |
| v2 MINOR m1–m15 | ✅ 大多處理完(downgrade 改 `ttylogin=1`、02 的副作用、setsid、runner 登入、`-c nobody:provd`、`:89` 的注入方式);m15 的表仍缺(m8) |

## 其他確認成立(✅)
- `stage-root` 用 boot-only payload 的執行路徑存在(W3)。作廢後誤開會因 `panic=10` 回到 A;EEPROM walk 走到 p1 = A。
- gate 的夾心對照:同一份 p5、同一個 trial,P1 的 `batman-slot` 與 tmpfs 上 wsl.9 的 `batman-slot` 各跑一次 → 有鑑別力。
- 02 在單台測項與 (7) 中:wireless 不變、hold、先 04 後 02、有 watchdog / joinwatch 的恢復路徑。除了 N1 的「02 沒有 rollback 槽」與 N4 的沙箱,我沒找到會讓 02 失聯的路徑。
- `-wbox` 的防漏:P9 在 `.protected` 缺時要求 BATMAN-BAD,所以「寫了 `-wbox` 但還沒開機就中斷」也會 FAIL ✅;build gate 檢查 buildinfo 與標記字串 ✅。

## 判定
**REJECT**(1 BLOCKER / 5 MAJOR / 10 MINOR):
- B1 照寫會讓 04 需要實體處理;
- N1 會讓常規全套在兩台都 FAIL,並拿掉 02 的退路(要使用者決定);
- N2、N3、N4、N5 都是有證據的漏洞。

修完請整份重審。
