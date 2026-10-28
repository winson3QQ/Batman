# h23 設計審查 v9 — 審查者 B(全文 §0–§18,重點 §17 v9 / §18)

- 對象:`docs/design/254-h23-harness.md` @ f6de6c2(harness/254-h23)。§16–§18 優先於前文。
- 原始碼:rc 樹 `/home/yello/Batman-rc`(`batman-autocommit`、`batman-slot`、`platform-ab.sh`、`98-batman-sysupgrade`、`99zz-batman-prov-state`、`prov-lock.sh`、`96-batman-config-migrate`、init 腳本、`feed/batman-prov/src`);harness `scripts/node/*`、`scripts/dv/*`(h23 樹)。
- 方法:唯讀。沙箱 = `/home/yello/dreview9B.XXXXXX` 下的 `batman-autocommit` 副本(只用 sed 改路徑:`/opt/batdata`、`rundir.sh`、`meshjoin.sh`、`/etc/batman-build` 指到沙箱;`p6()`、`dt_tryboot()` 改成 stub;`POLL=1`;非 dry-run 實驗的 `MIN_WINDOW` 改小),以 **busybox 1.36.1 ash**(`#!/usr/bin/busybox sh`)執行;`batman-slot`、`reboot`、`logger` 是 PATH stub。沙箱已刪。沒有 ssh、沒有碰 firmware build(只唯讀 grep 了 `.config` 一行)。
- 證據標記:✅ 原始碼或實跑看過;⚠️ 推論 / 部分;❌ 沒做。

## 0. 結論

**判定:REJECT(只針對 §17.3 與 §18.1;§0–§16 與 §17 其餘部分沒有新的 BLOCKER / MAJOR)**
0 BLOCKER / 4 MAJOR / 16 MINOR。

v8 的 1 BLOCKER + 3 MAJOR(兩位審查者)與安全審查 F1–F11 都有處理,§17 的方向對了:判定半邊改成 dry-run + 白箱 + autocommit mutant,沙箱實跑證實四個 L 的正向臂、對照臂都有判別力(E2–E5)。這輪擋下來的是:

1. **§18.1 沒寫 wbox 閘和 hold 的先後**。放在 hold 前面時,wbox + hold 的 trial 不再印 `is healthy and HELD`,`TRIAL-REVERTED` 的 reason 也從「held」變成「wbox」,§6.2 (9) 的 HELD 斷言和 revert 型單位「反而 HELD → mutant 無效」的偵測都失效(沙箱 E7 實證)。
2. **§17.3「L 臂在 `mesh join required` 行就殺,不會到 canary」不成立**。poll 迴圈緊接在那行之後,第一輪 `health_ok` 就會在 04(有 OTS tenant、committed 開機沒有 canary latch)跑 canary `docker import/run`,並寫真名的 `autocommit.why`。harness 經 ssh 看 stdout,一定殺得比較晚(E1:1 s 內已寫 `autocommit.why`)。另外 L38 臂 a 用「pgid 下有 `sleep 1` 子程序」判斷「在迴圈裡」,但 firmware busybox 開了 `FEATURE_SH_NOFORK`,`sleep` 不產生子程序(E8),這個條件永遠不成立。有一個只改 harness 的修法,沙箱已證實(E9)。
3. **§18.1 節點負對照要在 04 上 commit 一個 wsl.6 的 `--wbox test` image**。這違反 §16.18 與 §4.2,也就是 F1 要防的事;它的判別力 CI 已經提供;rollback 失敗或 harness 死掉時,04 會停在 committed 的 seam image 上;成本也沒算。
4. **§18.1 第二層只擋 `batman-slot commit`,沒擋 `batman-slot rollback`**。rollback 把「另一槽」設成預設,另一槽若是 wbox(revert 後、brewrite 前),操作員一個 rollback 就把 mutant commit 了,不經過 autocommit。

四個 MAJOR 的修法都只在局部,改完後重審 §17.3 與 §18.1 即可。

---

## 1. v8 審查與安全審查的處理狀況

### 1.1 v8-B(本人上一輪)
| # | 處理 | 狀態 |
|---|---|---|
| BLOCKER-1 L51 bind 錯檔 | v9 不再 bind `platform-ab.sh`,也不在 bind 下跑 OTA;寫入半邊 = CI `test-arm-mesh-254.sh` + §6.2 (7) 的 `S1 ARMED-MESH … m=joined` | ✅ 已解(CI 測試的寫法另見 m5) |
| MAJOR-1 member 前置 | 判定半邊改用白箱 `prov-state` member/radio,不需要真的 member、也不需要 `lastjoined` | ✅ 已解 |
| MAJOR-2 孤兒 watchdog / L43 收緊 | setsid + pgid kill、`AUTOCOMMIT_TIMEOUT=uptime+600`、L43 整行 + 無 `no usable` + 讀回 arm 檔;產品殘項記在 §17.5 | ✅ 已解;但「殺得夠早」的前提不成立 → 本輪 MAJOR-2 |
| MAJOR-3 `prov-state` 擁有權 | 第 3、5 欄照抄、tmp + mv、每臂還原、helper pid 不變、§3 / §5 增列、deadman / P9 | ✅ 已解(P9 的「第 3 欄 ≠ 快照」見 m16) |
| m1 L38 時序 | 「pgid 下有 `sleep 1`」+ 以臂 b 為判別 | ⚠️ 判別力 ✅,但偵測方法在 busybox NOFORK 下不成立 → MAJOR-2 |
| m2 boot_id 不符臂 | 臂 c | ✅(E4 `prov=none`) |
| m3 只 mutate 一半 | 判定半邊各有 autocommit mutant | ✅ |
| m4 成本 | §17 不新增 trial | ✅(§18.1 新增的見 m13) |
| m5 L42 程序 | L42 不再跑 trial | ✅(不適用) |
| m6 `sock: unexpected` | L11 負對照 | ✅ |
| m7 §6.2 舊文字 | 改成「見 §17」 | ✅ |
| m8 bind 契約 | root 0755、sha、grep 見證、無見證 = INVALID | ⚠️ `grep -c` = 1 與「見證 2 次」矛盾(m1) |
| m9 §7.2 副作用 | 部分 | ⚠️ 缺 `autocommit.hold-discarded` / `ctl.dry` / `hold-consumed` / `why` / `canary-ok`(m4) |
| m10 build 4 個 image | 保留,理由 = 同一條 gate 鏈 | ✅ |
| m11 TIMEOUT | uptime+600 | ✅(✅ 原始碼 `:382` 在 `:381` 夾值之後,不被夾成 3600) |
| m12 §5 列 | §17.5 | ✅ |

### 1.2 v8-A
B1 ✅、M1 ✅(修法 1–5 都進了 §17.3 / §17.5)、M2 ✅、M3 ✅、m1 ⚠️(同上)、m2 ✅、m3 不適用、m4 ✅、m5 ✅(P9 以 `/proc/mounts` 查 `/usr/bin/batman-autocommit`)、m6 ✅、**m7 ❌ 仍開著:§10 沒有記 §17 偏離 p1-impl §4(`:288` 的「開機路徑 -wbox 只寫進 B」)**(→ m12)、m8 ✅、m9 ✅。

### 1.3 安全審查(`p1b-security-review.md`)
| # | 處理 | 狀態 |
|---|---|---|
| F1 MEDIUM | §18.1 | ⚠️ 方向對,但有 MAJOR-1 / 3 / 4 |
| F2 | `local-ab-tar.sh` + `fast-build.yml` 加 gate | ✅ 設計有;❌ 沒列負測試(m14) |
| F3 | 正常模式全 rootfs grep | ✅;❌ 負測試(N8)沒列(m14) |
| F4 | staged + `-z` | ✅;❌ 負測試沒列 |
| F5 | `wbox_env_reset` unset `WBOX_DIR GO` | ⚠️ 只修了一半:F2 讓 `local-ab-tar` 也呼叫 gate,而那條路不經過 `wbox_env_reset`;安全審查建議的「gate 只在 `PROV_GATE_SELFTEST=1` 才採用 `WBOX_DIR` / `GO`」沒採用(m14) |
| F6 | INFO,不改 | ✅(可接受;openat 強化可寫一行進 #254) |
| F7 | `%q`,已做 | ✅ |
| F8–F11 | INFO | ✅ |

---

## 2. 沙箱實驗(✅ 原始輸出節錄)

```
=== E0 pgrep -f self-match (nothing of ours running) ===
734998 sh -c true; pgrep -af batman-autocommit; echo rc=$?
rc=0
=== E1 setsid group: is the dry-run watchdog subshell inside the pgid? ===
pid=735003 pgid-of-pid=735003
 735003  735003  735003 /usr/bin/busybox sh /home/yello/dreview9B.djnijJ/batman-autocommit run
 735066  735003  735003 /usr/bin/busybox sh /home/yello/dreview9B.djnijJ/batman-autocommit run
autocommit.wd
autocommit.why
after group TERM, members left: []
=== E2 L38 arm b ===   line after 62s: mesh join required: 0 (prov=unclaimed mesh_expect=0 radio_required=0)
=== E3 L38 arm a ===   sleep child seen in pgid:            <- 空
                       mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)
=== E4 L38 arm c ===   mesh join required: 0 (prov=none mesh_expect=- radio_required=0)
=== E5 ===
[cccccccc A radio]  -> mesh join required: 1 ... | armed-line=0 nousable=0 file-after=[cccccccc A radio]
[bbbbbbbb A radio]  -> mesh join required: 0 ... | armed-line=1 nousable=0
[bbbbbbbb A joined] -> mesh join required: 1 ... | armed-line=0 nousable=0
[bbbbbbbb B radio]  -> mesh join required: 1 ... | armed-line=0 nousable=0
=== E6 hold-commit flag present on p6 during a dry-run ===
run dir: autocommit-dryrun.log autocommit.hold-discarded autocommit.wd autocommit.why
=== E7 §18.1 prototype (non-dry) ===
[after  wbox=0 hold=0] commit-calls=1 why=[]
[after  wbox=1 hold=0] commit-calls=0 why=[wbox test image — never auto-committed] bad-slot=[slot=A version=…wbox-96-noprov] reboot=1
[after  wbox=1 hold=1] commit-calls=0 why=[held for operator acceptance (batman-autocommit release)] bad-slot=[…] reboot=1
[before wbox=1 hold=1] commit-calls=0 why=[wbox test image — never auto-committed] bad-slot=[…] reboot=1
=== E8 busybox sleep in a loop: child process? ===
 822020  822020 busybox sh -c i=0; while [ $i -lt 3 ]; do sleep 1; i=$((i+1)); done   <- 沒有 sleep 子程序
=== E9 proposed: HOLDC marker + AUTOCOMMIT_TIMEOUT=1 ===
[member-noarm]    rc=0 exited-after=.017s group-left=[] run=[autocommit.hold-consumed ] arm-after=[]
    hold present — this trial will not be reverted
    slot A is an uncommitted trial — gate until uptime 4176s (now 4176s), revert=0
    member: no usable ota-armed.mesh — neighbours required (fail-closed)
    mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)
    slot A NOT committed by uptime 4176s. last: ?
[member-stalearm] rc=0 exited-after=.015s group-left=[] run=[autocommit.hold-consumed ] arm-after=[cccccccc A radio]
    mesh join required: 1 (prov=member mesh_expect=radio radio_required=1)
```
firmware:`/home/yello/firmware-2710/.config` → `CONFIG_BUSYBOX_DEFAULT_FEATURE_SH_NOFORK=y`、`CONFIG_BUSYBOX_DEFAULT_SLEEP=y`(✅;節點 busybox 版本未上機確認 ⚠️,WSL 1.36.1 的行為如 E8)。

E7 的 `before` / `after` 是我依 §18.1 文字做的兩種擺法的原型(不是實作)。在非 dry-run 時 `log` 不印 stdout,所以 HELD 行要看 `autocommit.why`;`why` 就是 watchdog 寫進 `TRIAL-REVERTED … reason=` 的值(`batman-autocommit:236-239`)。

---

## 3. 發現

### MAJOR-1 §18.1 沒有規定 wbox 閘在 hold 之後;擺在前面會讓 HELD 訊號消失,改變所有 wbox + hold 單位的判定
- **情境**:§18.1 寫「摺進與 hold 相同的位置」,沒寫先後。如果實作成在 `:509` 的 `HOLDUNSAFE` / `held_commit` 之前先判 wbox:
  - wbox + hold 的健康 trial,`why` 先被設成 wbox,`:511` 的 `elif [ -z "$why" ] && held_commit` 永遠不成立 → 不印 `trial … is healthy and HELD`,也不記 `otalog AC HELD`;
  - watchdog 在期限讀到的 `autocommit.why` = wbox → `TRIAL-REVERTED … reason=wbox test image`(E7 `before`)。
- **後果**(現在所有 wbox trial 都帶 hold,§1.4):
  1. §6.2 (9) 斷言真 main 的 `is healthy and HELD` → 永遠 FAIL;
  2. §4.3 revert 型單位「反而 `HELD` → FAIL mutant 無效」的偵測失效。mutant 無效(trial 其實健康)時,harness 只會看到 `TRIAL-REVERTED`。(7) `chan` 只斷言 `TRIAL-REVERTED` + `ARMED-MESH m=joined`,不看 reason,只靠前置三次取樣擋 → 可能**假 PASS**;
  3. §4.2 / §15.7 的 HELD 與 DISCARDED 判斷也會被改寫。
- **證據**:✅ `batman-autocommit:505-516`(hold 只在 `why` 為空時摺入);✅ E7:`after` 擺法 → `why=held for operator acceptance`,`before` 擺法 → `why=wbox test image`;✅ §6.2 (9)、(7)、§4.3 第 1 步的文字。
- **修法**:
  1. §18.1 明定:wbox 是 `:509-514` 之後的**最後一個** `elif` / `if [ -z "$why" ]`(在 `HOLDUNSAFE`、`held_commit` 之後),非 dry-run 才生效。
  2. CI `test-autocommit-wbox.sh` 加一案:wbox + hold → `why` = held、`HELD` 行在、不 commit。負對照:把閘移到 hold 之前 → BAD。
  3. 所有 revert 型 wbox 單位斷言 reason(或 `otalog AC UNHEALTHY first_why`)**不是** `wbox test image`。這樣即使有人改了順序,也會變成 FAIL,不會假 PASS。

### MAJOR-2 §17.3 的「殺在 `mesh join required` 行、不會到 canary」不成立;L38 臂 a 的「在迴圈裡」偵測在節點的 busybox 上不成立
- **情境 1(canary 與真名檔)**:dry-run 印完 `:425` 之後立刻起 watchdog(`:429-436`),接著進 `:487` 的 poll 迴圈;第一輪 `health_ok`(`:492`)在 `have_docker_tenant` 時,若沒有 `$RUNDIR/autocommit.canary-ok`(committed 開機的真 main 在 `:326` 就退出,所以一定沒有),就跑 `canary_run`(`:459-470`)。也就是說,在 04 上,dry-run 印出那行後幾十毫秒內就開始 `docker image inspect` → 可能 `docker import`(`batman_tmp -d canary` 建暫存目錄)→ `docker run` → prune 舊 tag(`:121-143`),成功才寫真名 `autocommit.canary-ok`;每輪也寫真名的 `$RUNDIR/autocommit.why`(`:515`)。harness 只能經 ssh 輪詢 stdout 檔,看到那行時一定已晚於第一輪。12 個臂就是最多 12 次 canary,而且 TERM 打在 `docker import` 中途 → `$t` 暫存目錄留在 run dir(`rm -rf "$t"` 在 import 之後才跑),不完整的 import 怎麼處理也沒有證據。§17.3 / §7.2 寫的是「不會到 canary」「可能 import / prune」,快照清單沒有 `why` / `canary-ok` / canary 暫存目錄。
- **情境 2(臂 a)**:§17.4 L38 臂 a「等到它在迴圈裡(其 pgid 下有 `sleep 1` 子程序)」。firmware busybox 是 `FEATURE_SH_NOFORK=y`,ash 內的 `sleep` 是 NOFORK applet,不 fork 子程序(E8:3 s 迴圈期間 pgid 裡只有 shell 本身;E3:等 10 s 都看不到 `sleep`)。照文字實作,臂 a 永遠等不到,不是逾時 INVALID,就是被人「修」成拿掉這個條件。
- **證據**:✅ `batman-autocommit:425-436,459-470,487-492,515`;✅ E1(殺之前 1 s,run dir 已有 `autocommit.why`);✅ E3 / E8;✅ firmware `.config`;⚠️ 04 的 busybox 版本未上機確認。
- **修法(只改 harness,沙箱已證,E9)**:讓 dry-run **自己在判定行之後立刻結束**,而不是靠搶時間 kill:
  - 臂前 root 建 `$RUNDIR/autocommit.hold-consumed`(`held()` 的 `HOLDC`,`:78,96`,只有 autocommit 讀;committed 開機的真 main 在 `:326` 已退出)→ `:372` `REVERT=0` → **不起 watchdog**;
  - `AUTOCOMMIT_TIMEOUT=1` → `DEADLINE = START`(`:382-383`,`MIN_WINDOW=0`)→ `:487` 迴圈一輪都不跑 → 不跑 `health_ok` / canary、不寫 `why`;
  - E9:印出 `mesh join required` 後 15–17 ms 自行 exit 0,process group 已空,run dir 只剩 harness 自己建的標記,arm 檔沒被動到。L38 臂 b 的 60 s 等待在 `:404`,不受影響。
  - 臂後刪 `hold-consumed`(deadman 也刪)。pgid kill 與 `pgrep` 斷言留作安全網(注意 m2)。
  - 臂 a 的「在迴圈裡」改判:stdout 已有 `gate until uptime` 行,且之後 ≥ 3 s 仍沒有 `mesh join required` 行(writer = 99zz 時只可能停在 `:404`)。
  - 這樣一來,§17.5 的「刪 dry-run 建的 `wd` / `decided`」、§7.2 的 canary 列,都可以改成斷言「沒有新增」。

### MAJOR-3 §18.1 的節點負對照(在 04 commit wsl.6 `--wbox test`)應該拿掉
- **情境**:`prov-wbox-nocommit-254` 的負對照是 OTA 一個「本閘之前 build」的 wsl.6 `--wbox test` payload、不設 hold,讓它被 commit,再 `batman-slot rollback`。問題如下:
  1. 這正是 F1 要擋的事件(健康的 wbox trial 被 commit),而且是在 OTS 節點上故意做。`test` 變體帶 `prov_test` helper(killpoint seam),04 會有一段時間 committed 在 seam image 上。
  2. 違反 §16.18(「rc 必須是審過的程式碼」「舊 payload 只當 build 流程的證據,不上節點」),也違反 §4.2 / §1.4 的「只進非 committed 槽」「一律 hold」。
  3. 失敗路徑沒寫:harness 在 COMMITTED 與 rollback 之間死掉,deadman 不碰槽(§3),04 就停在 committed 的 wbox seam image 上,直到下次 P9。rollback 本身失敗(`assert_fw_sane`、`slot_lock`)也沒寫。
  4. 判別力重複:這個負對照證明的是「舊的 autocommit 會 commit 健康的 trial」,和閘本身無關(換了整個 image,不是只翻轉一個原因)。CI 的「拿掉閘 → commit」已經是乾淨的翻轉測試。節點正向臂的判別力可以來自只有閘會產生的證據(見修法)。
  5. 成本與 H3-U3:多一次 commit、rollback、重開、brewrite,沒算進 §7.3(m13)。
- **另外,正向臂本身也要補兩件事**:
  - (a) 不設 hold 違反 `pr_ota_b`「一律寫 hold」(§4.3)。要有明確的例外參數,而且 `lint` 限定只有這個單位可以用。
  - (b) 若產品閘回歸(這正是這個單位要抓的),`96-noprov` mutant 會被 commit 進 04。§18.1 沒寫「看到 COMMITTED → 立刻 `batman-slot rollback` + `reboot committed` → brewrite;失敗 → `pr_needs_person`」。
- **證據**:✅ §16.18、§4.2、§3 prov deadman 列(不碰槽);✅ `batman-slot:786-797`(rollback 會寫 autoboot,要 `slot_lock` / `assert_fw_sane`);✅ E7(閘的判定可以在沙箱 / CI 完整翻轉)。
- **修法**:
  - 刪掉節點負對照。
  - 節點正向臂的判別證據改成閘獨有的 `otalog AC WBOX-NOCOMMIT`,並把這行改在 `ok ≥ NEED` 時才記(= 「沒有閘就會 commit」,m10),加上沒有 COMMITTED、`TRIAL-REVERTED` 有出現。
  - 負對照只放 CI(拿掉閘 → commit;閘移到 hold 前 → HELD 消失,MAJOR-1)。
  - 若一定要節點翻轉,用 hold 擋 commit 的方式做(白箱:hold trial 內 bind 一份去掉 `BATMAN_WBOX=` 行的 `/etc/batman-build`(或 m7 的 `/rom` 路徑)→ release → 看到「會 commit」的 `DRYRUN` 或 `RELEASED` 後立即 `back_to_a`),永遠不真的 commit wbox。

### MAJOR-4 `batman-slot rollback` 可以把一個 wbox 槽設成 committed 預設,§18.1 沒擋
- **情境**:wbox trial 被 revert(或 harness 在 brewrite 前死掉)之後,B 留著 mutant rootfs,P9 也只會印 brewrite 指令(§4.7)。現場或 bench 上,操作員依 runbook 執行 `batman-slot rollback`(「make the OTHER slot the default」,`batman-slot:17`),reboot 後 B 就是 committed 預設,`is-trial` = 1,autocommit 在 `:326` 直接退出,完全不經過 §18.1 的兩層。F11 第一組 mutant(`helper-nojoinop` / `helper-clientchal` / `rc9-unclaimed` / `helper-notrial`)就這樣變成 committed。§18.1 宣稱的「節點自己拒絕 commit `-wbox` image」在這條動詞上有洞。
- **證據**:✅ `batman-slot:786-797` `cmd_rollback`:只查 `slot_is_bad "$T"` 與 `rollback_lock_gate`(只對 claimed / member,legacy 直接 return 0,`:775-776`);✅ `rollback_lock_gate` 已經會唯讀掛載目標 squashfs(`:778-781`),所以加查 `etc/batman-build` 的成本很低;✅ `.protected` 由 apply 刪(F31),wbox 槽不會有完整的 `.protected`(可以作為第二個訊號)。
- **修法**:
  - `cmd_rollback` 對目標槽一律(不分 prov 狀態)唯讀掛載,`etc/batman-build` 有 `BATMAN_WBOX=` → die,覆寫方式與 commit 相同。
  - `test-autocommit-wbox.sh` 或 `prov-unit-gate`(§4.4 已有 loop GPT 卡 + 假 DT)加一案:目標槽是 wbox → rollback 拒絕;拿掉檢查 → 放行(負對照)。
  - 若使用者決定不在本 PR 做,至少寫進 #254 checklist 與 §18.1「不擋的路徑」,並在 P9「另一槽含 wbox」的輸出加一行「不要 rollback」。

### MINOR
- **m1 見證 `grep -c` = 1 與「見證 2 次」矛盾**:§17.2 規定見證在 log 行一次、檔頭註解一次(`lint-wbox` 也要求 ≥ 2 次,§4.2),但 bind 後斷言 `grep -c WBOX-misc-LNN /usr/bin/batman-autocommit` = 1。`grep -c` 算行數 = 2,這個斷言永遠 FAIL。改成 ≥ 1,或 = lint 算出的次數。
- **m2 `pgrep -f batman-autocommit` 會匹配到 harness 自己的 shell**:經 ssh 跑複合指令(`kill …; pgrep -f batman-autocommit`)時,`sh -c` 的 cmdline 含這個字串(E0:`pgrep -af` 回了自己的父 shell,rc 0)。bind 前「沒有 autocommit 在跑」與 kill 後「殘留為空」兩個斷言都會假 FAIL。改成 `pgrep -g <pgid>`,或比對 `/proc/*/cmdline` 第 2 欄 = `/usr/bin/batman-autocommit`,並排除自己的 pid / ppid(記憶「pgrep 自我匹配」是已知坑)。
- **m3 見證 log 行的位置**:要能區分「mutant 沒被執行(INVALID)」與「mutant 執行了但沒效果(mutant 無效 → FAIL)」,見證必須放在 `member:*)` 分支開頭這類**不受 mutant 條件影響**的位置(L38:`:403` 前;L42 / L43 / L51:`:417` 後),不能放在 mutant 改過的條件分支裡,也要在 `log()`(`:62`)定義之後。§17.2 只寫「mutant 那一行旁」。
- **m4 §17.3 快照清單不完整,且「本來不存在」的假設不成立**:
  - 加 `autocommit.why`、`autocommit.canary-ok`、`autocommit.hold-discarded`、`autocommit.ctl.dry`、`autocommit.hold-consumed`、`autocommit-dryrun.log`、canary 暫存目錄。E6:p6 有 `autocommit-hold-commit` 時,dry-run 會建真名的 `autocommit.hold-discarded`(`:289`),而這正是 `pr_ota_b` 拿來偵測 DISCARDED 的檔(§4.2)。前置斷言 p6 無 `autocommit-hold-commit` / `autocommit-hold-once`。
  - 「`autocommit.decided` 在 committed 槽上本來不存在」不成立:既有的 `scripts/node/tmp-trust-280.sh:71`、`payload-274.sh:78` 在 committed 開機跑 FORCE_TRIAL dry-run 到期限,它們的 watchdog 會建 `wd` / `decided`,並刪 p6 `ota-armed.mesh`(✅ 原始碼;同 v8-A M1 的沙箱結果)。harness 只能「快照 → 只刪新增的」,不能先斷言它不存在。
  - §17.5 的產品殘項也要註明,既有單位已在觸發它。
- **m5 `test-arm-mesh-254.sh` 照文字寫不出來,而且漏一案**:
  - `platform-ab.sh` 一 source 就 `. /lib/functions.sh`(`:22`);runner 上沒有這個檔,ash / dash 會直接結束。
  - `_ab_arm_mesh` 把 `/opt/batdata/state/ota-armed.mesh` 寫死(`:104`),`/proc/mounts` 檢查是行內 `grep`(`:105`),不是函式,沒辦法「以函式覆寫 stub」。
  - `meshjoin.sh` 在子殼內重新 source(`:112`),會蓋掉測試定義的 stub 函式。
  - 建議放進 `dv-sbx`(真 busybox、真 `/lib/functions.sh`、`/opt/batdata` tmpfs 本來就在 `/proc/mounts`),`meshjoin.sh` 以檔案替換,`_ab_live_sysupgrade` 在 source 後覆寫,`$RAM_ROOT/sbin/upgraded` 建成可執行檔。
  - 補一案:「`lastjoined` 空 + `meshjoin_joined` 真 → `joined`」(stage1 L51「joinwatch 停用時退回單次取樣」)。
  - L42 的寫入半邊:真正有判別力的是靜態檢查「`batman-slot` 不寫 `ota-armed.mesh`」(`grep` = 0 → CI lint)。(6a) 的「apply 後無檔」只算 characterization,文字要這樣標。
- **m6 deadman 的 pgid kill 要防 pid 重用**:記錄 pgid 的檔放 `$DVD/<run>/`(root 0700)。kill 前驗證該 pgid 的 leader 的 cmdline = `… /usr/bin/batman-autocommit run`,且 `/proc/<pgid>/environ` 含 `AUTOCOMMIT_DRYRUN=1`。否則一個早已結束的臂留下的 pgid 可能剛好是 OTS / docker 的 process group。若採 MAJOR-2 的修法,dry-run 幾毫秒就結束,這條幾乎只剩防呆。
- **m7 §18.1 的讀法**:
  - 讀 `/rom/etc/batman-build`(squashfs 下層),不讀 `/etc/batman-build`:`/etc` 在 overlay 上,trial 內任何 root 程序(包括 mutant 的 uci-defaults)都可以在 upper 蓋掉這個檔。
  - `grep` rc ≥ 2(讀取錯誤)→ 視為 wbox(拒絕)。「讀不到 → 非 wbox」的理由(release 沒有這行)只適用於「沒有這行」,不適用於「讀不到」。`health_ok` 在檔缺 / 空時已經不健康(`:455`),所以 fail-closed 不會影響 release。
  - 可加第二訊號 `BATMAN_VERSION` 含 `.wbox-`。
  - `batman-slot` 同樣處理。
- **m8 逃生口**:
  - `batman-slot` 既有的覆寫慣例是 `allowed X` = `BATMAN_ALLOW_X=1` **或** root 擁有的 `/tmp/batman-slot.allow-x`(`batman-slot:77`;`halow-status:107` 會顯示)。§18.1 自訂了 `BATMAN_SLOT_ALLOW_WBOX`。實作者若沿用 `allowed WBOX`,一個 `/tmp` 檔就會讓整個開機期間所有 `batman-slot commit` 放行。要明定只吃 env(或 CLI `--allow-wbox`,如安全審查建議),並記 `st COMMIT-WBOX-OVERRIDE` / otalog。
  - procd 服務的 env 不繼承操作員 shell,autocommit 本身又先擋,所以不會從 procd 洩漏 ✅。能設這個變數的都是 root,不是權限邊界 ✅。
  - CI 要 stub `/etc/batman-build`,應該用 mount namespace(`unshare -m` + bind),**不要**為測試在產品加「build 檔路徑」的 env 覆寫(那會變成 production 的繞過口)。
- **m9 §18.1 生命週期缺列**:
  - (a) 非 tryboot 的 stale-fallback 開機進了 wbox 槽:`REVERT=0`(`:351`),閘讓它永不 commit,也沒有 watchdog → 一直跑 mutant,直到有人重開。要寫明這個行為與處置(P9 抓得到)。
  - (b) bcm2710 不適用(CM4 決定),要寫出來。
  - (c) `batman-autocommit` / `batman-slot` 是 A/B 共用檔:PR body 要有 `### bcm2711` / `### bcm2710` 兩節(`ab-shared-change.yml`;記憶 #307 的教訓)。
- **m10 `WBOX-NOCOMMIT` 要在 `ok ≥ NEED` 時才記**,作為「沒有閘就會 commit」的證據。節點斷言放在這一行;`TRIAL-REVERTED` 的 reason 只記錄:reason 是最後一輪的 `why`,04 有 `NEED_MESH=1`,最後一輪剛好 mesh 抖動就會變成別的字串。
- **m11 主機上閘之前的 wbox payload**(wsl.5 / wsl.6 等)仍會被自動 commit:`pr_ota_b` 要對 wbox payload 斷言它的 rootfs `usr/bin/batman-autocommit` 含閘(`unsquashfs -cat` + 固定字串),舊的移到隔離目錄。這是 F1「拿錯檔」最可能的來源。
- **m12 上層與安全表沒同步**:
  - §10 沒有 §17 偏離 p1-impl §4(v8-A m7)。
  - §10 沒有 §18.1 這個產品契約改動(`ab-autocommit.md`、stage1 §6.4、`batman-slot` 用法說明)。
  - §7 actor 表「我們自己」沒有 harness 對 p6 `prov-state` / `ota-armed.mesh` 的白箱寫入,也沒有 bind 覆蓋 root 執行的 `batman-autocommit`。
  - §1.4 / §4.2 / §7 的「所有 wbox trial 一律 hold」沒有註明 §18.1 的例外。
- **m13 成本**:§18.1 的節點單位是一次新的 revert 型 trial(≈ 37 分 + 600 s + brewrite 14 分;若保留負對照,再加 commit / rollback / 重開),§7.3 與 H3-U3 沒更新。依規則要回報使用者。
- **m14 §18.2 的修正沒有列負測試**(F2:假 rootfs 的 `local-ab-tar` gate 段 FAIL;F3:N8;F4:staged / 非 ASCII;F5:W5)。F5 要改成 gate 自己只在 `PROV_GATE_SELFTEST=1` 時採用 `WBOX_DIR` / `GO`,因為 F2 之後 gate 多了不經過 `wbox_env_reset` 的呼叫者。
- **m15 L9 / L10 / L27 的副作用沒進 §7.2**:在 OTS 節點重啟 `dbus`(連帶 bluetoothd);在 harness 自己的 ssh(dropbear)上重啟 dropbear,斷線怎麼重連、判定怎麼算,都沒寫。
- **m16 P9 的「`prov-state` 第 3 欄 ≠ 快照」跨 run 做不到**:快照在 `$DVD/<run>`(tmpfs),重開或換 run 就沒了。要嘛把快照放 p6 dirty 目錄,要嘛只留「第 2 欄 ≠ helper 且 uptime > 120 s」這條。另外,「helper pid 不變」擋不到 helper 同一 pid 內的 `SetLastKnown`(`main.go:204`,只改第 3 欄,只在 claim / replay 時跑)。prov-misc 在 lease 內沒有 claim,所以可以接受,寫一句即可。

---

## 4. 依任務要求的逐點回答

1. **§17.3 dry-run 程序**
   - `( revert_watchdog ) &` 在非互動 ash 下與 main 同一個 pgid,`kill -TERM -- -<pgid>` 殺得乾淨(✅ E1:兩個成員都在 pgid 735003,殺完 `[]`)。
   - `setsid` 由背景 `&` 啟動時不是 group leader,所以不 fork,`$! = pgid` ✅。
   - `AUTOCOMMIT_TIMEOUT` 是絕對 uptime,而且在 `:381` 夾值之後才套用,600 s 會照實施行 ✅(`:382`)。
   - `wd` / `decided` 的刪除:在 committed 開機上沒有別的寫者,所以沒有競爭 ✅;但「本來不存在」的假設不成立(m4)。
   - 真正的問題是 kill 之前已經跑了 canary 與寫了真名檔(MAJOR-2)。
2. **§17.2 bind `/usr/bin/batman-autocommit`**
   - 執行它的只有:procd init(`START=99`,只在開機或手動 `start` / `restart`;在 committed 槽上,mutant 的改動都在 `:326` 之後,所以無害)、`batman-autocommit canary`(daily-validation,與 prov 區塊不同時跑)、`release`(harness)。feed 裡沒有 cron 或其他呼叫者 ✅(grep)。
   - bind 期間跑真 OTA 也無害:stage 1 / 2 不執行 autocommit,trial 是新開機,bind 已消失。
   - INVALID 只在 harness 自己出錯時才可能出現(呼叫路徑不對、bind 沒掛上)。前提是見證放在不受 mutant 條件影響的位置(m3),並修好 `grep -c` 的矛盾(m1)。
3. **L42 / L51 寫入半邊**
   - L51:節點 (7) 是真的端到端 ✅。CI stub 照文字寫不出來,也漏了 meshjoin fallback 一案(m5)。負對照「改掉 `m=joined` 分支 → BAD」有判別力 ✅。
   - L42:(6a) 只能算 characterization,真正的保證是「`batman-slot` 不寫此檔」的靜態檢查(m5)。
   - 判定半邊四個 mutant 都只拿掉指名的保護。E5 證明各正向臂沒有別的理由能 PASS:boot8 錯 → 1、boot8 對 → 0、`joined` → 1、slot 錯 → 1,並且沒有 `no usable` 行、arm 檔沒被動到。
4. **§18.1**
   - 位置:要在 hold 之後(MAJOR-1);不搶 `FIRSTWHY` ✅(`:505` 在摺入之前);canary 不跑 ✅;watchdog 照常 revert,reason = wbox ✅(E7);`COMMITTED-BY-OPERATOR` 只能經逃生口 ✅。
   - 逃生口:不會漏進 procd ✅;命名與 `allowed()` 慣例的風險見 m8。
   - 讀不到 → 非 wbox:對「沒有這行」合理,對「讀取錯誤」不合理(m7)。
   - 負對照應拿掉(MAJOR-3)。
   - 既有流程:brewrite / chain1 / pty-commit / pr_normalise / fault-injection(R3、C2)/ prov-legacy-upgrade(wsl.9)/ ab-selftest 都只 commit V 或舊的 release ✅(grep `batman-slot commit`、`autocommit release`);(9) 的 dry-run 不受影響 ✅,但它的 HELD 斷言靠 MAJOR-1 的順序。
   - 發版流程:release image 沒有這行,行為不變 ✅。
   - 漏洞:rollback(MAJOR-4)。

## 5. 安全(本輪增量)
- **本機非 root**:§17 的白箱檔(p6 state 目錄、`$RUNDIR`、bind 來源 root 0700)碰不到 ✅(依 #280 run dir 設計,未上機查權限 ⚠️)。§18.1 的 `/etc/batman-build`:非 root 寫不了;root 可以在 overlay upper 蓋掉 → 改讀 `/rom`(m7)。
- **攻陷的 tenant / mutant 本身**:wbox image 可以自己改掉自己的標記(upper 寫 `/etc/batman-build`)。改讀 `/rom` 後就做不到。`lint-wbox` 應拒絕任何碰 `wbox_image` / `batman-slot` 閘那幾行的 patch。`misc-*` 會改 `batman-autocommit`,但只用於 bind、永遠不進槽:`pr_ota_b` 要拒絕 `misc-*`。
- **我們自己**:rollback 洞(MAJOR-4)、舊 payload(m11)、故意 commit seam image(MAJOR-3)。
- **CI runner**:§18.1 CI 用 mount namespace stub,不在產品加路徑覆寫(m8)。
- **fail-secure**:§18.1 的閘本身 fail-closed ✅;讀取錯誤要改成 fail-closed(m7)。

## 6. 證據分類
- ✅ 驗過:E0–E9 的沙箱輸出(上面節錄);原始碼行號(`batman-autocommit:62,78,96,270-291,326,351,372,376-386,402-425,429-436,459-470,487-516,529-537`;`batman-slot:17,77,735-797`;`platform-ab.sh:22,83,103-117`;`prov-lock.sh:56`;`96:70`;`main.go:204`;`tmp-trust-280.sh:71`;`payload-274.sh:78`;init 腳本無 respawn);firmware `.config` 的 NOFORK。
- ⚠️ 推論或部分:04 實際的 busybox 版本與 NOFORK 行為(依 `.config` 與 WSL 1.36.1 推論);04 上 TERM 打斷 `docker import` 的後果;§18.1 的 E7 是依文字做的原型,不是實作。
- ❌ 沒做:任何上機驗證;`test-autocommit-wbox.sh` 與 `test-arm-mesh-254.sh` 尚未存在,無法跑。

## 7. 摘要
v8 的 BLOCKER / MAJOR 與安全審查 F1–F11 都有處理。§17 的判定設計經沙箱實證有判別力。本輪 4 個 MAJOR 都是局部問題:
1. §18.1 要明定 wbox 閘在 hold 之後,並讓 revert 型單位斷言 reason(否則 HELD 消失,(9) 永遠 FAIL,(7) 可能假 PASS)。
2. §17.3 改成讓 dry-run 自行結束:預建 `hold-consumed` + `AUTOCOMMIT_TIMEOUT=1`,E9 已證實不起 watchdog、不跑 canary、不寫真名檔;L38 臂 a 改用 `gate until` 行判斷。
3. 拿掉在 04 commit wsl.6 wbox 的負對照,改用 CI 翻轉 + 節點 `WBOX-NOCOMMIT@ok≥NEED`;正向臂寫明 no-hold 例外與回歸時的回收。
4. `batman-slot rollback` 也要拒絕 wbox 目標槽,或由使用者決定記成殘項。

另有 16 個 MINOR,其中 m13(新增 trial 的成本)要回報使用者。
