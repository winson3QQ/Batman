# 審查 B 第 7 輪:設計 v5.1 + §13.2 / §13.3、P1 修正(58dbb7b..c1e1c72)、H2 草稿、E1c 探針

審查者 B,2026-10-21。範圍:
- 整份設計(§13.2 處置、§13.3 E1c、§5.4 鏈 1);
- `feat/254-p1` HEAD c1e1c72;
- `harness/254-h2`:`prov-base-254.sh`、`prov-p1-254.sh`;
- 草稿 `prov-claim-254.sh`;
- 探針 `e1c/e1c.sh`。

真機:對 04、02 只做了唯讀查詢(cat、`batman-slot active`/`is-trial`、`--check`、`docker inspect`、`sysctl`),沒有寫入、沒有重開、沒有印出任何秘密。

WSL 裡做的事:
- 在 `/tmp/rv7` 複製模組,跑 mutant 測試,跑完已刪除;
- `go test` 讓 GOTOOLCHAIN=auto 自動下載了 go1.26.4 到 WSL 的 module cache。這是我造成的環境變動,如實記錄。

**判定:REJECT** — 0 BLOCKER / 6 MAJOR / 10 MINOR。
- 沒有 BLOCKER。round-6 的 B1 已撤回 §13.1,改走 (a) 案,方向正確。
- **E1c 照現在的寫法不要跑**:M1、M5 修好之前,有一條「04 停在位址不明的 fresh B、沒有 dead-man,只能靠人救回」的路徑。這兩項都是小改動。
- 產品還有兩個 MAJOR(M2、M3),出貨前要修。
- H2 的 S0 比對照現在寫法永遠不會過(M6)。

---

## 0. 本輪證據

| # | 事實 | 證據 |
|---|---|---|
| R1 | 04 現況:`slot=A ver=1.5.12-wsl.10+de782bf trial_rc=1`,`protB` = wsl.10,沒有 bad-slot / hold / dirty;`prov-state` = `helper legacy legacy - today`;`--check` 回 `p5 fresh` rc 0;p6 有 `mesh-expected`(`seeded --on-join`)、`mesh-joined`、`ota-armed.mesh`、`ble-ok`;p6 上有 `ota-wsl11.tar.gz` | ssh 唯讀 |
| R2 | 02 現況:`slot=A ver=1.5.12-wsl.11+c1e1c72 trial_rc=1 up=93`(審查期間剛重開過);第一次連線 timeout,但在 04 的 `batctl n` 與 `ip neigh` 中可見(REACHABLE)。Windows 解析不到 `BCM2711-45d7.local` | ssh、ping |
| R3 | **fleet 目前是混版**:04 是 wsl.10,02 是 wsl.11。E1c 的前提(§13.3 寫「04, wsl.11」)與 04 的現況不符 | R1、R2 |
| R4 | `go test ./...` 全部 ok。mutant「拿掉凍住檢查」→ `TestFrozenRefusesStateChanges` FAIL ✅。mutant「rc 13 拿掉 gen 條件」→ 產品自己的 `TestRc13NeverDowngrades` **仍然 PASS**(這個 mutant 沒被抓到);我加了一個「sn 相同、overlay gen 較舊」的案例,real code PASS、mutant FAIL | WSL 輸出:`ok batman-prov/boot` / `FAIL batman-prov/boot` |
| R5 | 兩份 `batman-config-save` 的 HEAD sha 都是 `a15bf8406a978634`;`RAMFS_COPY_DATA` 已含 `prov-lock.sh`;`IsTrial` 改成 `rc != 1` | `git show` |
| R6 | 04:`fs.protected_symlinks=1`、`fs.protected_regular=2`;非 root 的程序有 dnsmasq、logd、network、nobody、ntp、ubus、999、1000;容器只掛 `/opt/batdata/docker/volumes/*` 與 apps 的唯讀檔 | sysctl、`docker inspect` |
| R7 | 這台 Pi 4 EEPROM 上,plain 的 armed tryboot 可能 no-op(變成開 [all]) | `scripts/ab-selftest.sh:233-238` |
| R8 | B commit 時會刪掉 p6 的 `ota-armed.mesh`,也會刪 `bad-slot` | `batman-autocommit:530` |
| R9 | `prov-state`、`ble-ok` 的內容都含 boot_id:`writeProvState` 的格式是 `"<boot_id> helper …"`;health 把 `boot+"\n"` 寫進 `ble-ok` | `boot.go:269-291`、`health.go:150-156` |
| R10 | 有 OTS tenant 時,autocommit 的健康判定只要 services、docker canary、payload drift,**不需要 mesh**;`unclaimed:*` 與 `claimed:0` 會把 NEED_MESH 設成 0,覆蓋 p6 marker 與 `.seeded` 的判斷 | `batman-autocommit:388-420、440-475` |

---

## MAJOR

### M1. E1c 與鏈 1 第一個 trial 不 hold:B 找不到時,04 會 commit 到 fresh B 上,而且沒有 dead-man;第 5–6 步的判讀也會和自動 commit 互相競賽
- **情境 A(E1c)**:`e1c.sh:59-60` 在 240 s 內掃不到 `10.41.254.x` 就 `exit 1`。這時 dead-man **還沒種下**(種在 `:63-65`,前提是先找到 B)。
  - 錯誤訊息寫「autocommit reverts at 600 s」,但在 P1 上 unclaimed 會讓 NEED_MESH=0(R10):約 95 s 時 B 會**自己 commit**,接著 openmanetd 重開,換到一個不知道的位址。
  - 結果:04 committed 在一個 fresh、unclaimed、沒有 lab key 的 B 上,沒有 dead-man;OTS 停擺;02 一直被隔離(02 沒有乙太網,joinwatch 3600 s 只會重開一次)。只能靠人用 mDNS 或掃 /16 找到它,再用 `none` 登入救回。
  - 掃不到的機率不低:E1a 是 83 s 才找到(§13);Windows 的平行 ping 加 ARP 本來就不穩;R2 這次就連 02 的 `.local` 都解析不到。
- **情境 B(鏈 1 §5.4 第 5–6 步,不 hold)**:第 6 步的判讀是「`precheck-node` rc ≠ 0、最後一行是 mis-aimed tryboot(B 還沒 commit)」。但在 P1 上 B 約 95 s 就會 commit,而 E1a 實測約 83 s 才連得到。
  - commit 之後 `[tryboot]` 指回 A(`cmd_commit` 寫 `[tryboot]=FT`),`precheck-node` 就變成 rc 0。
  - 判讀結果取決於誰先誰後 → 這是一個不穩定的測項。
- **修法**(一次解決兩個問題):第一個 trial 先寫 hold = V(F5:同版的 hold 有效),然後:
  1. 先找到 B → 種 dead-man → 做完第 5–6 步的證據批次;
  2. 斷言 log 有 `mesh join required: 0 (prov=unclaimed` **而且**有 `HELD`(這就證明了「unclaimed 不需要鄰居」);
  3. 最後 `batman-autocommit release` = 走產品自己的 commit 路徑。

  這樣一來:找不到 B → hold 期限一到就 revert 回 A;openmanetd 在 release 之前重開 → tryboot 已經用掉 → 回 A。每一條路都會回到 A。E1c 第 1 點量的「自己 commit」改成「HELD + release」,差別只在 commit 的觸發來源,要在 §13.3 寫明。

### M2. MeshExpect 的 `claimed` 規則是 fail-open:c1e1c72 把「key 是空的或讀不到 → 0」推廣到三個寫入者;而 `claimed + placeholder → 0` 本身也分辨不出「從來沒有 key」和「這個槽把 key 弄丟了」
- **證據**:
  - `boot.go` 的 `MeshExpect`:`claimed` 時 `k == "" || k == placeholder` → `"0"`;
  - 99zz 現在預設 `me=0`,只有讀到一個非空、非 placeholder 的 key 才改成 `today`;
  - `meshIface()` 找不到 `mode='mesh'` 就回 `""`(`main.go:93-101`);
  - autocommit 的 `claimed:0` → NEED_MESH=0,而且**覆蓋** `mesh-joined`、`mesh-expected` 與 p5 `.seeded`(R10)。
  - `TestMeshExpect` 把 `{Claimed, "", "0"}` 寫成預期值,等於用測試把 fail-open 固定下來。
- **現場情境**:
  1. 一台 fleet 節點經 L17 升級、再被認領 → 狀態是「claimed + fleet 的實際 key」(認領不改 wireless)。
  2. 之後 OTA 到一個有 regression 的 image:96 沒把 wireless 的覆寫套回去,或是 uci 的 wireless 壞了。新槽的 mesh key 因此是 image 預設的 placeholder,或者根本讀不到。
  3. keyguard 關掉 mesh radio → helper 判 `claimed`(由 p5 抄來)、`me=0` → autocommit **不需要鄰居就 commit** → 02 這種只有 mesh 的節點就失聯了。

  同一個故障放在 legacy 節點上:今天的規則看到 `mesh-joined` → 需要鄰居 → revert。這正是 #202 與 1.4.12 事件要防的那一類,對所有 claimed 節點來說,這層保護不見了。
- **修法**:
  - (a)讀不到 key(找不到 mesh 介面、key 空的)→ `today`(fail-closed)。三個寫入者一起改,`TestMeshExpect` 改成 `{Claimed, "", "today"}`。
  - (b)`claimed + placeholder → 0` 只在 p6 **沒有** `mesh-joined` / `mesh-expected` 時才成立(`network.leave` 本來就會刪這兩個 marker,`main.go:228`);或改看 p5 overrides 裡的 mesh key 是不是 placeholder。這是上層 §6.4 規則的修訂,要寫進 §10 回報上層。
  - 鏈 1 的 (2) 跑之前,要先把 p6 的 `mesh-*` marker 移開(snap 會還原),並在報告裡列為偏離。
  - 負對照:claimed + 實際 key 的節點,以 `-wbox` 讓 96 不套 wireless → OTA(不 hold)→ 必須 `REVERT`。
  - 另外:99zz 是「任一個 mesh 介面有實際 key 就算」,Go 是「只看第一個 mesh 介面」(`main.go:93-101`),兩者不一致(見 m8)。

### M3. `--persist-now` 繞過了 round-6 的凍住規則與 rc 13 規則,還會在系統執行中把整個 `boot.Run` 重跑一次
- **證據**:
  - `main.go:348-360`:`--persist-now` 先跑 `boot.Run(bootEnv(p))`,只在 verdict 含 `identity-mismatch` 時拒絕;其他 `unknown(identity-lost)`、`unknown(prov-corrupt)`、`unknown(txn-generation)` 都照樣呼叫 `PersistP5(overlay record, overlay identity)`。
  - `config-save --prov-only` **不檢查 gen 是否單調遞增**(`:174-178` 只驗格式;`:470-486` 直接寫)。
- **情境**(就是 round-6 M3,只是換一個入口):
  1. p5 的 claimed 紀錄是 gen 5,`identity/prov/` 裡壞了一個檔,但 `sha256` 還在,而且和 overlay 的一樣;
  2. rollback 到一個 overlay 還是 legacy gen 1 的槽;
  3. `--check`:身分比對通過(兩邊的 `sha256` 檔相同)→ `prov.meta` 不同 → 報 `p5 stale: prov`;
  4. `batman-slot` 的錯誤訊息**叫操作員跑 `batman-provhelper --persist-now`**;
  5. 操作員照做:`boot.Run` 回 rc 13 → 依新規則 `unknown(identity-lost)`,不寫 → 但 `--persist-now` 接著還是寫了 → `--prov-only` 把 p5 上 gen 5 的 claimed 降成 gen 1 的 legacy。
  
  擁有權在沒有任何紀錄的情況下就沒了。
- **副作用**:在 daemon 執行中再跑一次 `boot.Run`,會做以下事情:
  - `RemoveAll(Stage)`(把一筆進行中 txn 的 `.stage` 刪掉);
  - 遇到 `.txn` 時可能以 p5 完成 overlay 並 `RemoveTxn`(和 daemon 正在做的 `net.apply` 互相競爭);
  - 改寫 `prov-state`。
- **修法**:
  - `--persist-now` 改成只讀判斷:用和 boot 相同的比較,但**不呼叫** `boot.Run` 的寫入路徑。verdict 是 `unknown(*)` 就拒絕(和 helper 動詞同一條規則)。
  - 拿 helper 的 `flock`(或檢查 socket / pid 是否存活),daemon 有 txn 時拒絕。
  - `--prov-only` 加防線:p5 已有紀錄、新 gen < p5 gen,而且不是 txn 的 rollback → rc 1。
  - mutant 案例:上面的情境 → p5 的 gen 不變。

### M4. B-M4 的回歸測項照 §13.2 的寫法沒有鑑別力:做 OTA 的時候 B 已經 claimed 而且 seeded,stage 2 根本不會用到 `prov-lock.sh`
- **證據**:§13.2 說新增測項是「unclaimed 節點真的跑一次 `sysupgrade -n`(就是上面第 5 步之前、從 committed 的 unclaimed B 做的 OTA)」。但同一段的第 3 步已經先認領了 B,認領的 `--save` 會 seed p5;第 5 步的 OTA 因此在 `node_checks` 的 `[ -f "$m/.seeded" ]` 就放行了(`batman-slot` 約 `:538`),`prov-lock.sh` 從頭到尾沒被 source。
  - 結果:負對照(拿掉 `RAMFS_COPY_DATA` 的那一項)也會 PASS。
  - 「unclaimed B 做 OTA」只存在第 2 步與第 3 步之間,§5.4 並沒有定義那一步。
- **修法**:
  - 明確插一步:在第 2 步與第 3 步之間,從 committed、unclaimed、未 seed 的 B 執行 `sysupgrade -n V`(hold)寫 A。A 反正會在第 5 步被覆寫。
  - 正向證據:stage 2 的 otatrace 或 log 有 `allowed (#254 L44)`,而且落點在 A 的 trial。
  - 之後 `back_to_b`(rollback → B),再接第 3 步。
  - 負對照:在 B 上用 `mount --bind` 換一份拿掉那一項的 `platform-ab.sh`(stage 1 會從 live 路徑複製進 ramfs)→ stage 2 die、什麼都沒寫、重開回到 B。

### M5. E1c 的收尾在正常路徑上很可能誤判 FAIL;FAIL 時不會取消 dead-man,留下一個「拿過期快照蓋掉 p5」的地雷
- **證據**:
  - `e1c.sh:104` 用整個分割區映像的 sha 比對 p5 和快照。但 A 開機後 joinwatch 會照常啟動(snap 時的停止撐不過重開),第一個 JOINED tick 一定 rw 掛載 p5,映像 sha 就變了(F4,§4.5.5 也是因為這樣才改比檔案清單)。
  - A 在 fleet mesh 上,通常一兩分鐘就入網,所以 `:101` 輪到可以連上 A 時,`:104` 很可能已經 FAIL。
  - FAIL 走 `exit 1`,`:105`(`touch e1c.cancel; rm -f e1c-deadman.sh`)不會執行。另外 `trap` 只印結果,不做清理。
- **後果**:B 的 overlay 裡,`rc.local` 還留著那一行(`:63`)。之後在 B 被 brewrite 覆寫**之前**,只要再開進舊的 B overlay 一次,1500 s 後就會:
  1. 拿 E1c 的**舊快照** dd 回 p5,蓋掉那之後的設定 / 認領;
  2. rollback,然後重開。

  會開進舊 B overlay 的情況:ab-selftest 的 happy path 用 raw tryboot 開 B(F26),或任何同版的 tryboot。另外 `:42` 每次都會 `rm -f e1c.cancel`,所以舊的取消檔也擋不住。
- **修法**:
  - `:104` 改成比 p5 的檔案清單(`prov-base manifest` 或 `compare` 的 p5 部分),或者改讀 dead-man log 裡的 `P5-RESTORED` 那一行(讀回 sha 在重開前就驗過了);
  - `trap` 在任何出口、只要確認 A 已經回來,就 `touch e1c.cancel` 並刪掉 `e1c-deadman.sh`;
  - dead-man 自己加條件:`dv-prov-dirty` 的 run id 必須等於 `$RUN`,而且這次開機的 uptime 與快照時間的差距要在上限內。不符就不動作。

### M6. H2 的 S0 比對(§4.5.5「p6 state 每個檔 == 快照」)只要重開過一次就不可能成立
- **證據**:
  - `prov-state`、`ble-ok` 的內容都含 boot_id(R9);`ota-armed.mesh` 也帶 arm 那次的 boot_id,而且 commit 時會被刪掉(R8)。
  - `prov-base-254.sh:144-148` 比的是整個檔的 sha。restore 必定會重開,所以 `DIFF state prov-state` 一定出現。
  - `prov-claim-254.sh:93-94` 依賴 `diffs=0` → 這個測項永遠 FAIL;依 P-U12,第一個單位就會停下來。
  - 另外,`upper.manifest` 要等 E4 產生允許清單才可能過(E4 還沒做)。
- **修法**:
  - `prov-state` 只比第 3–6 欄(lks、verdict、members、me);
  - `ble-ok` 只比「存在」;
  - `ota-armed.mesh` 依測項類別比「存在」,或讓 restore 寫回;
  - 在 §4.5.5 寫清楚每個 state 檔怎麼比、理由是什麼;
  - 負對照:restore 時故意把 lks 寫錯 → 必須 DIFF。

---

## MINOR

- **m1 E1c 的「找到」與「重開」判讀都太弱**:
  - `:86-88` 只要 mDNS 解析出來的位址的 ARP MAC 等於 04 的 MAC 就算找到。但**兩個槽用的是同一張網卡**:Windows 快取裡 10.41.1.3(A 的位址)的 MAC 也一樣,所以快取可能回一個過期的位址,也可能剛好落在 A 被 EEPROM 誤開的那幾秒(A 同樣允許 `none` 登入)。
  - `:78` 一次 ssh 失敗就判「已重開」。
  - **修法**:找到之後,ssh 要回 `batman-slot active` = B,而且 boot_id ≠ `$bB`,才算數。報告裡分開記錄「mDNS 解析結果」和「實際登入確認」。
- **m2 E1c 沒有落點斷言,而且用 plain `reboot`**:
  - `:55` 在 tryboot armed 的情況下用 plain reboot,這台 EEPROM 可能 no-op(R7);§4.5.0 規定的是受控的 `reboot -f`。
  - 如果 no-op,04 會用 mkfs 過的 p5 開回 A,`:60` 卻告訴操作員「找不到 trial」。
  - 另外兩條回到 A 的路(openmanetd 在 commit 之前就重開;revert)都只有「請手動 p5-restore」。
  - **修法**:重開後先看 10.41.1.3:如果還是 A,而且 boot_id 是新的 → 先 disarm tryboot 並讀回確認,再自動 `p5-restore`;另外改用 §4.5.0 的受控重開。
- **m3 版本前提**:
  - 04 是 wsl.10,02 是 wsl.11(R3);E1c 用 A 的版本當 V,卻把 `PAY` 寫進 B。
  - 回到 A 的那幾條路,A 跑的是 **wsl.10 的 config-save**,沒有 c392443 的凍住寫入保護 → A 的 joinwatch 會把 X 的覆寫寫進存著 Y 身分的 p5(round-6 M2 的混合)。dd 救得回來,但要列出來。
  - **修法**:斷言 A 的版本 == `PAY` 的版本 == wsl.11,或者 04 先 OTA 到 wsl.11。
- **m4 E1c 少了幾個斷言**:
  - `deadman_in_rclocal` 只有印出來,沒有斷言;
  - commit 的原因沒有用 `mesh join required: 0 (prov=unclaimed` 確認;
  - 回到 A 後沒有斷言 A 的 `prov-state` = 這次開機、helper、legacy(不是 `unknown(identity-mismatch)`),也沒斷言 `--check` rc 0;
  - p6 的差異(`ota-armed.mesh` 被 B 的 commit 刪掉、`prov-state`、`ble-ok`、`lock-status`)沒有列出,也沒有寫回。
- **m5 E1c 沒有 lease,也沒有 02 的前置條件**:R2 顯示審查期間 02 剛重開過。E1c 讓 04 離開 mesh 長達約 38 分鐘(最壞情況更久);如果 02 這時正在一個需要鄰居的 trial 裡,就會 revert 並寫 `bad-slot`(A-m12)。
  - **修法**:取得 prov lease;斷言 02 是 committed、不在 trial。
- **m6 root 在 1777 的 `/tmp` 用固定名稱**:`/tmp/p5e1c`(`:50`)、`/tmp/rcl.e1c`(`:63`)。
  - 04 開著 `protected_symlinks=1` 與 `protected_regular=2`(R6),所以 symlink 或預先建立的檔案只能讓操作失敗(DoS),而且 m4 不會發現。
  - **修法**:改用 `/tmp/run/batman-dv` 底下的 mktemp。
- **m7 `identity_mismatch` 只在兩邊都有 `sha256` 時才成立**:
  - p5 有 prov 紀錄,但 `identity/prov/sha256` 不見了,而 overlay 有身分 → `--on-join` / `--save` 仍會把這一槽的 key、`authorized_keys`、shadow 寫進那份 p5。
  - `prov_compare` 印出的「the helper re-persists it at the next boot」在 b482268 之後,只有 sn 相同、gen 不較舊時才成立,其他情況是錯的。
  - **修法**:「p5 有 `prov.meta` 但身分不完整」→ 寫入模式一律拒絕;訊息照實改寫。
- **m8 MeshExpect 的兩份實作不一致**:99zz 只要任一個 mesh 介面有 key 就算;Go 的 `meshIface()` 只看第一個。和 M2 一起改成同一套規則。
- **m9 rc 13 的 gen 條件沒有測項會抓到**:產品的 `TestRc13NeverDowngrades` 在 gen 條件被拿掉時仍然 PASS(R4)。
  - **修法**:補上「sn 相同、overlay gen 1 < p5 gen 5 → 不寫、`unknown(identity-lost)`」這個案例(我在 WSL 跑過:real code PASS、mutant FAIL)。
- **m10 文件與草稿**:
  - §13.3「收尾」那段自相矛盾(提了 hold、brewrite,還說「登入方式 ⚠️ 未驗」),和 `e1c.sh` 的實際做法(不 hold、`none` 登入、dead-man)不一致,要照實改寫;
  - §13.2 的「(2) 的前半段」寫錯了,unclaimed 自己 commit 屬於 L1 / L44,不屬於 (2);
  - `prov-claim-254.sh` 只涵蓋 §5.3 的一部分:沒有 `claim-after-persist` killpoint / replay、沒有 `E_UNSUPPORTED(no-ssh-key)`、沒有 bind mount 的 helper 負對照;它的 restore 判讀還卡在 M6;
  - helper 的 verdict 在整次開機期間是固定的:短暫的 `unknown(no-rundir)` 也會讓整次開機凍住,只有重啟 helper 才能解。這是 fail-closed、可以接受,但要寫進文件。

---

## 確認成立(✅,附證據)
- **round-6 M2(凍住)**:
  - config-save 的每個寫入模式都在 rw mount 之後、寫入之前,呼叫 `identity_mismatch` 並 rc 1(`:377-381`);
  - `--prov-only` 拒收和 p5 不同的身分(`:382-384`);
  - helper 在 verdict 為 `unknown(*)` 時,改狀態的動詞一律回 `E_STATE`(`node.go:164-166`);
  - 負對照有效(R4)。例外見 M3、m7。
- **round-6 M3**:boot 路徑的 rc 13 只補身分,而且要 sn 相同、gen 不較舊(`boot.go:240-251`)✅。`--persist-now` 這個入口仍然沒擋(M3)。
- **round-6 M4**:`RAMFS_COPY_DATA` 已加入 `prov-lock.sh` ✅。測項的設計見 M4。
- **round-6 m1**:`IsTrial` 改成 `rc != 1` ✅,和 health 的 `Committed`(rc == 1)一致。
- **round-6 m2**:三個寫入者確實改成同一套規則 ✅,但選到 fail-open 那一邊(M2)。這一點我在第 6 輪沒有指定方向,責任在我。
- **round-6 m3**:`--check` 會報 `prov-identity-missing` ✅;`batman-slot` 的 `*p5 stale: prov-identity*` 也會比對到這個字串,給的是「擁有者處理或重燒卡」的訊息。
- **兩份 config-save 逐位元組相同**(R5)。
- **E1c 不會讓 04 卡死**的部分(在 M1、M5 修好的前提下):
  - A 的 overlay 一直完好、有 lab key;
  - p5 的快照在 mkfs 之前,在鎖內、joinwatch 停止時 dd 下來;
  - dead-man 的 `p5-restore` 可以重複執行,斷電後重開會再跑一次;
  - `batman-slot rollback` 在 committed 的 B 上可用(`cmd_rollback` 只拒絕 BAD 的目標槽);
  - busybox `dd` 支援 `conv=fsync` 與 `iflag=direct`(04 實查)。
- **E1c 有沒有在 p6 留下 A 會讀錯的狀態**:
  - `prov-state` 綁 boot_id,autocommit 會比對(`:402`);A 的 helper 每次開機都會重寫;
  - 96 只在 A 的 overlay 是全新或 bypass 時才讀 `last_known_state`,E1c 不會讓 A 的 overlay 變成全新;
  - B 的 commit 會刪 A 的 `ota-armed.mesh`(R8),那個檔是過期的,不影響 A 的判斷,但要記錄(m4);
  - 結論:E1c 沒有 A 會讀錯的 p6 狀態。鏈 1 (a) 會把 `lks=claimed` 留在 p6;restore 時會從快照寫回;萬一沒寫回,這個值只會讓 bypass 往上鎖的方向偏(fail-secure)。
- **E1c 涵蓋了 §13.3 的三個事實**(自己 commit、誰下的重開、找不找得到),但要補上 M1、m1–m4 才算數。它**沒有**涵蓋 M4 的 stage 2 測項,也沒有涵蓋 (a) 案第 3 步之後的部分。
- **鏈 1 (a) 本身**:B 被 commit 之後 `IsTrial` = false,verdict 是 `unclaimed`,不會碰到 `E_BUSY` 或 `E_STATE` ✅;keyguard 關著,joinwatch 不會寫 p5 ✅。
  - 仍有兩個依賴:同槽重建靠 `firstboot -y`(E4 還沒做);(2) 的判讀要依 M2 處理 p6 的 marker。

## 判定
**REJECT**(0 BLOCKER / 6 MAJOR / 10 MINOR)。順序建議:
1. E1c 先修 M1(hold + release)、M5(收尾判讀與清理)、m1–m5,之後才在 04 上跑;
2. 產品修 M2、M3,各附 mutant 或負對照;
3. 設計補上 M4 的步驟、M6 的比對規則,以及 §13.3 的文字。

修完後,依規則整份重審。
