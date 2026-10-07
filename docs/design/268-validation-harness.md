# #268 validation harness:修假綠燈/假紅燈 + dogfood 測項放進 daily-validation

狀態:設計 **v2.1 — review PASS**(v1 FAIL 6 blocking → v2;v2 複審 PASS-with-changes C1–C4 → 已併入,見 §7)· 2026-10-07
範圍:`scripts/daily-validation.sh`、`scripts/fault-injection.sh`、新增 `scripts/node/*.sh`、`scripts/validation-known-failures.txt`

## 0. 背景(reality check,1.5.4 dogfood 實測;§0 事實已由 reviewer 對照程式碼逐條確認)

| # | 問題 | 實際後果 |
|---|---|---|
| A1 | `bchk_rejoin_245` 用 `${a:-0}` 讀 victim 的 PANIC 計數(line 628),讀不到就當 0 → PASS;base 讀不到時當 0 → 有歷史 PANIC 的節點會假紅燈 | 04 最後一次讀取時 ssh 逾時 → 假 PASS |
| A2 | `fault-injection.sh` 寫死 `PAYLOAD=/opt/batdata/ota.tar.gz`(line 22) | 04 上那份是 1.5.0 → 兩個 slot 都被刷成 1.5.0 → 8 個 OTS suite 假紅燈 |
| A3 | R1 用 `docker run batman-canary`(line 76/81),image 實際是 `batman-canary:<tag>` | canary 檢查永遠 FAIL |
| A4 | `restore_runc`(line 36)只把 runc 改回,不重啟 dockerd;`\|\| true` 會在節點還沒起來時默默略過 | 04 OTS 0/6 約 6 分鐘 |
| A5 | `suite()` 只分 0 / 非 0;bchk 用 `return 2` 表示測不了(line 574、609) | 假紅燈 |
| A6 | faketime-174 斷言「年份 ≥ 2026」(line 570) | 從沒拿到真實時間的節點永遠 FAIL;且**沒驗 boot_id**,reboot 沒送到也會 PASS |
| A7 | rejoin 接在三個會重開 DNODE 的測試後面;DNODE=03(這次另外指定的)是主機進 mesh 的唯一橋 | 「no reachable peer」 |
| A8(review 新增) | 所有重開類 bchk(174/192/173)都沒驗 boot_id 有變 | reboot 沒送到 → 假 PASS |

## 1. 原則

1. **讀不到 = 沒驗到**:每個比較前驗「非空、是整數」;否則 FAIL(或有標記的 SKIP),印出原因。
2. 狀態:PASS / FAIL / SKIP / N/A 語意不變。**SKIP 必須同時滿足 rc=3 和 log 中有 harness 自己印的一行 `SKIP-REASON: …`**;rc=3 但沒有這行 → FAIL(防止遠端腳本自己的 `exit 3` 被吞成 SKIP,例如 `verify-profile.sh`、`batman-config-save`)。
3. **已知缺陷照樣 FAIL,但報告分段**(C1 收緊):清單 `scripts/validation-known-failures.txt` 每行 `suite<TAB>FAIL 行特徵 regex<TAB>issue`(單號必填)。**只比對 harness 印出的 `FAIL …` 行,不比整份 log**;一個 suite 裡**每一行 FAIL 都符合某個已知特徵**才算已知,只要有一行不符就是新 FAIL。以下失敗寫死為一律新 FAIL、不得列入清單:restore_node 失敗、清理失敗、CONNECTION-LOST、boot_id 沒變、SKIP 標記缺失。有 `gh` 時單已 closed → 新 FAIL。
   原本的說明:新增 `scripts/validation-known-failures.txt`(`suite<TAB>log 特徵 regex<TAB>issue`)。報告把 FAIL 分成「新 FAIL」和「已知 FAIL(特徵符合 + 單號)」兩段;特徵不符、或單已關(有 `gh` 時查詢)→ 算新 FAIL。**exit 一律 1**,不讓已知缺陷從 exit status 消失。
4. destructive 測試一定要把節點還原;還原失敗本身就是 FAIL。
5. **重開類測試必須證明真的重開了**(boot_id 變了)。

## 2. 修正(A 類)

### A1 rejoin
- base 和 a 都必須是整數;任一讀不到 → 該 victim 用 `dwait` 等最多 240 秒再讀;還是讀不到 → **FAIL** `peer X unreadable — not verified`。
- 同時比對 victim 的 boot_id:**測試期間變了 = FAIL**(重開過,含 hang → watchdog)。

### A2 payload precheck(R2/R1 前)
1. `tar -tvzf` 取 `root.squashfs` 的大小,必須等於 `metadata` 的 `size=`;不等 → FAIL(印兩個值)。
2. `tar -xzOf … root.squashfs | sha256sum` 必須等於 payload `SHA256SUMS` 的值(payload 本身沒壞)。
3. `/rom` 的 mount 來源必須是 `/dev/mmcblk*`,否則 FAIL 並印出來源(不自己推算版面)。實測:slot A=`/dev/mmcblk0p2`、Pi 4 slot B=`/dev/mmcblk0p4`。
4. `head -c $size $dev | sha256sum` 必須等於 payload 的 root.squashfs sha(和 `batman-slot verify` 同一種讀法:前 size bytes)。不等 → **拒絕 R2/R1,FAIL** `payload != running slot (payload metadata version=…) — stage the current payload`。
5. payload `metadata` 的 `board=` 必須等於節點 `/etc/batman-build` 的 `BATMAN_BOARD`(C4 回填:metadata 的 `version=` 是打包時間戳 `date +%Y%m%d-%H%M%S`,見 `build-ab-payload.sh:69`,節點上沒有對應欄位,無法比對;版本一致由第 4 步的 rootfs sha 保證)。
6. 印出節點版本;有 `EXPECT_VERSION` 時必須相等;**沒設時印響亮的 `VERSION NOT PINNED`**(C4)。
- `FI_PAYLOAD=<node 上路徑>` 可以指定別的檔案,一樣要過 precheck。不自動上傳 payload。

### A3 canary 檢查
- **trial 中**(autocommit daemon 可能正在跑):用 `docker images batman-canary` 取已存在的 tag,直接 `docker run --rm --network none batman-canary:<tag> /bin/busybox true`;**不呼叫** `batman-autocommit canary`,因為它會 `rmi` 舊 tag,和 daemon 同時跑會有競態。
- **post(已 commit、daemon 已結束)**:用 `batman-autocommit canary`(line 98/120,不看 latch)。

### A4 restore_node(取代 restore_runc,trap 和 R1 FAIL 分支都呼叫)
1. 先 `waitup`(最多 300 秒);連不上 → FAIL `node unreachable — restore NOT done`(trap 也要讓 exit 變 1)。
2. 把**目前開機 slot** 的 `.off` 改回。
3. 如果改回了任何東西,或 dockerd 沒在跑 → `/etc/init.d/dockerd restart`。
4. 等 OTS 6/6 最多 240 秒;沒到 → FAIL `node left degraded`。
5. dockerd 重啟後再跑 `batman-autocommit canary`(此時已不在 trial,daemon 不會同時跑),確認 runc 真的能跑容器;失敗 → FAIL `canary still broken after restore`。
- 限制(寫進 log):R1 弄壞的是 **trial slot** 的 runc。如果之後 R1 成功回退,壞的那個 slot 不是 committed slot,下一次 OTA 會覆寫它;在那之前**不得 `batman-slot rollback` 進去**(EEPROM 開錯槽 bug 也可能開進去 → 開機後由 restore_node 修)。log 會印出哪個 slot 帶著 `.off`。

### R1 診斷(不改判定)
- 改名 runc 的當下記錄 `date -r /tmp/autocommit.canary-ok +%s`(busybox 沒有 `stat`)和當下時間、uptime。latch 在改名之前就存在 → log 印 `CANARY-LATCHED-BEFORE-INJECTION <N>s`;known-failures 用這行作為 #265 的特徵。

### A5 「測不了」
- `bchk_*` 的「測不了」一律 `echo "SKIP-REASON: …"; return 3`。
- guardian-192:呼叫前 `soc_of $DNODE`,bcm2710 → **N/A**(Pi 3 設計上不帶 OTS/guardian,#209 D6)。bcm2711 卻沒有 guardian → `return 1`(壞了,不是測不了)。

### A6 faketime-174 改驗機制本身(review K2)
重開前:T0=`date +%s`、boot0=boot_id。重開後全部成立才 PASS:
1. boot_id ≠ boot0(真的重開了);
2. S=`/opt/batdata/.faketime` 的值 ≥ T0 → 證明關機時 STOP=09 的 `save` 真的寫了(`save` 是 forward-only,所以一定要讀出來比);
3. T1=`date +%s` ≥ S → 證明開機時 `restore` 把時鐘拉到存檔值以上(或時鐘本來就更新)。
- 不看 logread:`restore` 在 START=12 執行,比 logd 還早,那行 log 不一定看得到。
- 印出 T0/S/T1、「節點是否有過真實時間」(T0 ≥ 2026-01-01)作為資訊,不作判定。
- 負對照:暫時拿掉 `/etc/rc.d/K09batman-faketime` → 重開 → 條件 2 必須 FAIL → 還原連結(trap 保證)。
- 已知限制(review):條件 3 在關機時有寫 /etc 檔的情況下,可能因 sysfixtime 而不靠 restore 也成立;主要證據是條件 2。

### A7 rejoin 的前置
- 把 rejoin 移到 tier B **第一項**(tier A 不會重開 DNODE)。
- 開始前先查 mover 的 `iw dev wlh0 station dump` 中 ESTAB plink 數:等最多 240 秒仍是 0 → **FAIL**(DNODE 沒重新加入 mesh,是真 bug);有 plink 但主機連不到任何 victim → SKIP(SKIP-REASON)。

### A8 所有重開類 bchk 驗 boot_id
- 174 / 192 / 173 在 reboot 前後比對 boot_id;沒變 → FAIL `reboot did not happen`。

### A9 fault-injection 拆成 4 個 suite
- `fi-f2`、`fi-f1`、`fi-r2`、`fi-r1`,順序不變(各自呼叫 `fault-injection.sh --case <x>`)。R1 的已知 FAIL 不再遮住 F1/F2/R2 的回歸。
- precheck(A2)失敗 → fi-r2 和 fi-r1 FAIL(不是 SKIP:payload 錯是操作問題,而且會刷壞節點)。

## 3. 新測項(B 類)

共同:node 端腳本放 `scripts/node/`,harness 用 `ssh … sh -s < file` 送上去執行;image 一律由節點自己的 busybox + musl 現場 `docker import`(不需網路);名稱前綴 `dv-`;開始前清殘留,結束 trap 清理。

### B1 `container-lifecycle-247`(tier A,每台,每天)
- `scripts/node/container-lifecycle.sh` = dogfood 的 `lifecycle.sh` + `extra2472.sh`。
- **預期數寫死在 harness**(C2)。node 腳本只能用 `NOTRUN <項目名> <原因>` 減項,而且只限白名單項目;dockerd-restart **拆成獨立 suite `dockerd-restart-247`**:對沒有 tenant 的節點跑,一台都沒跑到 → SKIP(SKIP-REASON),進 exit status。container-lifecycle-247 本身就不再包含 dockerd 重啟。
- 每一項只有 PASS / FAIL,不再有會讓項目數變少的 info 分支(像 exeseal「沒訊息」改成 FAIL)。
- harness 解析 `RESULT pass=N fail=M`:**fail=0 且 pass=預期數**(印出預期數);沒有 RESULT 行、ssh 回 124/255 → FAIL。
- dockerd-restart-247:只對**沒有任何非 `dv-` 容器**的節點跑(依實際狀態判斷)。
- 「`runc features` 失敗」那項改成直接執行 `runc features` 必須 rc=0,不靠 logread(ring buffer 可能已被蓋掉 → 假綠燈)。

### B2 `ots-cot-e2e-264`(tier A,每天,約 5 分鐘)
- 產生端 = BENCH_NODE(必須 ≠ OTS_NODE,且連得到 OTS_NODE:8088),否則 SKIP(SKIP-REASON)。
- run id `DV<stamp>`;uid = `DV<stamp>-<phase>-<seq>`;每筆都帶 `<marti><dest callsign="dv-nobody"/></marti>`,stale = +60 秒。
  - 實測:帶 dest 的 CoT 仍入庫(`cot.uid` 每筆一個,`sender_uid` = 這條連線第一筆的 uid,並建出一筆 euds);cot_parser `route_cot` 對有 `dest callsign` 的事件只 publish 到 `dms` exchange(routing_key=dv-nobody,沒有人收),**不會廣播到 groups → 不會在 ATAK 上出現幽靈標記**。firehose 和 web UI 仍收得到(可接受,只有 uid 帶 DV 前綴)。
- phase(每個 phase 一條新的長連線,busybox `nc`;粒度 1 秒,節點沒有 `usleep`):
  - **P1 對照組**:每秒 1 筆、每筆一次 write,共 30 筆。**#264 沒修也應該 0 遺失;P1 掉 = 新 FAIL。**
  - **P2 確定性截斷**(#264 機制 A):20 對事件 A/B。每對:第一次 write = **完整的 A + B 的前半**(在屬性值中間切開)→ `sleep 1` → 第二次 write = B 的後半。nc 分兩次 write,伺服器分兩次 `recv`。**每一對結束後也 `sleep 1`**(C3),避免下一對的第一次 write 和上一對的第二次 write 被合併成同一次 recv;離線腳本照同樣的 recv 切法模擬。
    - 為什麼不是「半筆 / sleep / 半筆」:那樣第一次 recv 沒有 `</event>`,`handle()` 走 `len(cot_list) < 2: continue` 把半筆留著,接起來仍完整 → **不會觸發**。觸發條件是「同一個 recv 裡有完整事件,後面跟著不完整的事件」。
    - 離線驗證(`handle()` 第 96–127 行原樣複製):半筆/半筆 = 20/20 入庫(不觸發);A+半B / 半B = **A 20/20、B 0/20**;P1 = 30/30。
    - 判定:A 必須 20/20(同批對照,A 掉 = 新 FAIL);B 必須 20/20(#264 修好之前預期 0/20 → 已知 FAIL)。
  - **P3 連發**:每秒 5 筆一次寫出(約 1.6 KB > 1 MSS),共 100 筆。真實客戶端合併寫入的情況,機率性。
  - **機制 B(心跳)daily 驗不到**:實測 10–15 分鐘才斷一次,而且卡住的原因還只是推論。只記錄這段時間 rabbitmq `missed heartbeats` 與 eud `channel is closed` 的次數(資訊);判定放到 B3。
- 送出數:產生端在**每筆 printf 之後**檢查 nc 還活著(`kill -0`);nc 提早結束 → 該 phase 記為 `CONNECTION-LOST at seq N`(另外報告,不算成 OTS 掉資料),判定 FAIL。
- 入庫數:輪詢 `count(*) from cot where uid like 'DV<stamp>-%'`(精確 stamp),連續兩次不變才採用(最多 60 秒)。每個 phase 分開計,印出缺哪些 seq。
- 判定:每個 phase 都要 stored == sent;known-failures 對 P2/P3 的特徵(`P2 lost` / `P3 lost` 且 eud log 有 `Failed to parse`)列為 #264。P1 掉、CONNECTION-LOST、清理失敗、測試前後 OTS 不是 6/6 → 不符合任何特徵 → 新 FAIL。
- 清理(同一個 transaction):`delete from euds where uid like 'DV<stamp>-%'`(cot 用 `sender_uid` FK cascade,points/markers/eud_stats 等也 cascade)+ `delete from cot where uid like 'DV<stamp>-%'`(保險);之後逐表驗 = 0:cot(uid、sender_uid)、euds、points(uid、device_uid)。`video_streams`、`geochat` 對 cot 沒有 cascade,我們的事件不會產生這兩種列,但仍驗 = 0。
- 筆數:30+40+100 = 170 筆/天。

### B3 `load-soak-247`(release gate:只在 `AB_MODE=--destructive` 時跑)
- `SOAK_MIN` 預設 30,**< 30 拒絕**(前後兩個 10 分鐘窗口需要不重疊,而且要涵蓋心跳斷線的週期)。
- 負載:BENCH_NODE、MESH_NODE 各起 `dv-web`(python http.server,256m,image 由 `SOAK_HTTP_IMAGE` 指定,預設 `meshtastic-cli:arm64`);每台每秒 3 次 64 KiB GET,**本機 GET 和走 mesh 的 GET 分開計**;BENCH_NODE 對 OTS_NODE 送 CoT 5 筆/秒,沿用原型的 5 個固定 uid(帶 dest、短 stale),不會累積 9000 個標記。
- 暖機 2 分鐘後才取基準。
- 拆成多個 suite(一個 suite 只有一種狀態):
  - `soak-daemon-mem`:每台 dockerd、containerd、shims RSS:最後 10 分鐘平均 ≤ 前 10 分鐘平均 × 1.15 + 8 MB;
  - `soak-memavail`:每台 MemAvailable 最低值 ≥ 基準 × 85%;
  - `soak-containers`:所有容器 RestartCount 不增加;所有 docker cgroup 的 `memory.events oom_kill` 差值 = 0;
  - `soak-http-local`:本機 GET fail = 0(必須);
  - `soak-http-mesh`:走 mesh 的 GET fail = 0(mesh 抖動也算 FAIL,不放寬;分開是為了讓人看得出是容器問題還是無線問題);
  - 某台沒有 `SOAK_HTTP_IMAGE` → 該台的兩個 http suite 記 SKIP(SKIP-REASON)。實測:02、04 有,**03 目前沒有任何 image**;
  - `soak-cot-264`:stored == sent;已知特徵(`missed heartbeats` 或 `Failed to parse`)→ #264。
- trap 清理:停產生器、刪 `dv-web`、刪 DV CoT 列並驗 0。

## 4. 測試計畫(實作後上機,每個修正都要負對照)
- A1:測試中把一台 victim 的 22 port 暫時擋掉(在 victim 上用 nft,trap 保證移除)→ 必須 FAIL。
- A2:`FI_PAYLOAD` 指向舊的 `ota-1.5.0-rel.1.tar.gz` → 拒絕 + FAIL;指向 254 → precheck 通過。
- A3/A4:跑 fi-r1(依 #265 會 FAIL)→ 結束時 04 必須自己回到 OTS 6/6,不需人工介入。
- A5:guardian 在 03 → N/A;rejoin 擋掉所有 victim → SKIP(且有 SKIP-REASON)。
- A6:03 上 → PASS;拿掉 K09 連結 → FAIL;結束連結還原。
- A8:把 reboot 指令換成 `true`(測試用環境變數)→ 必須 FAIL。
- B1:三台都 fail=0、pass=預期數。
- B2:P1 = 30/30、P2 的 A = 20/20、B = 0/20(#264,與離線重現一致)、清理後逐表 0。
- 最後:非 destructive 全套 + destructive 全套各一次,報告附進 PR。

## 5. Alternatives(不採用)
- **XFAIL 狀態(已知缺陷不影響 exit)**:「#264/#265 還沒修」會從 exit status 消失。改用 §1.3 的分段報告,exit 仍是 1。
- **R1 改成 trial 開機前就弄壞 runc**:要改 payload 或 overlay,侵入性大;等 #265 決定修法後再看。
- **自動上傳 payload**:主機不一定有 build 輸出;120 MB 走 mesh 很慢。用 precheck 擋。
- **調低 mesh-tput 門檻**:不在本單範圍(調門檻讓它變綠),另外記錄。

## 6. Failure modes / 風險
- precheck 讀錯裝置 → 永遠拒絕 → R1/R2 不跑:失敗時印出裝置與兩個 sha;上機負對照驗過才算數。
- B2 每天 170 筆寫入 OTS DB:清理失敗 → FAIL;帶 dest 不廣播。
- B3 30 分鐘:只在 release gate 跑。
- restore_node 重啟 dockerd 會斷 OTS 數十秒:只在改過 runc 或 dockerd 已死時才做。
- known-failures 清單本身可能過期:有 `gh` 時檢查單是否已關,單關了還符合特徵 → 算新 FAIL;沒有 `gh` → 報告標明「單號狀態未查」。

## 7. v1 review 對照
| review | 處理 |
|---|---|
| K1 重開沒驗 boot_id | A8;A6 條件 1 |
| K2 faketime 沒驗機制 | A6 改驗存檔值與 restore;負對照改為拿掉 K09 |
| K3 rc=3 撞遠端 exit 3;192 矛盾 | §1.2 SKIP 需 SKIP-REASON;192 Pi4 回 1、Pi3 N/A |
| K4 已知 FAIL 遮住新 FAIL | §1.3 分段報告;A9 拆 fi 4 suite;B2 P1 對照組 |
| K5 B2 機制 A 機率性、B 沒打到、nc 斷線 | P2 確定性截斷(review 建議的「半筆/半筆」離線驗證不會觸發,改為「A+半B / 半B」);機制 B 標明 daily 驗不到、交給 B3;CONNECTION-LOST |
| K6 DB schema/FK 沒查 | 已上機查(cot 有 uid;FK 全部列出);同一 transaction 清理、逐表驗 0 |
| Major 廣播副作用 | dest callsign(已驗不廣播、仍入庫);B3 固定 uid |
| Major A7 / A4 / B1 / B3 / A2 | 全部照建議納入(見各節) |
| Minor 筆數、canary 競態、等待方式 | 170 筆;trial 中不呼叫 `batman-autocommit canary`;輪詢到穩定 |
| 順便發現 chk_156 / confinement-98 UNKNOWN 假綠燈 | **另開單**,不在本單範圍 |
| v2 C1 known-failures 比對單位 | §1.3:逐行比對 FAIL 行,特定失敗寫死為新 FAIL,單號必填 |
| v2 C2 B1 預期數 | 寫死在 harness;dockerd-restart 拆成獨立 suite |
| v2 C3 P2 對與對之間 | 每對結束 sleep 1 |
| v2 C4 precheck 版本 | metadata version 比對 + VERSION NOT PINNED |
| v2 建議 restore 後 canary | A4 第 5 步 |
