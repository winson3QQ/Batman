# #254 PR-P1 + PR-H2 第 9 輪審查 — 審查者 B

範圍:設計 `254-p1-impl.md` 全份(重點 §13.5–§13.7)、E1c v3 (`e1c/e1c.sh` + `e1c-dry.log`)、產品 `feat/254-p1` 6e3a8c1、harness `harness/254-h2` 78ddbeb(docs 頭 88d0473)、openmanetd 1.3.10 原始碼、04 唯讀實查。
所有節點操作都是唯讀 ssh(cat/grep/logread/uci get/ls),沒有寫入、重啟或改狀態;沒有印出任何金鑰。

## 判定:**REJECT**(只針對 §13.7 設計;它還沒實作)

- 產品 6e3a8c1(rc 10 不降代)與 harness 78ddbeb 沒有新的 MAJOR,我自己重跑了測試(見「已驗證」)。
- §13.7 有 1 個 MAJOR:它對 config.yml 的擁有權假設被 openmanetd 原始碼推翻,而且我用 openmanetd 自己的 config 套件實測,證實「精確比對後才刪」會失效,暫停就變成永久。
- 依規則,MAJOR 未關就要改設計,並重審整份。

---

## 已驗證(✅,附原始輸出)

1. **產品 Go 測試**:放在 /tmp 複本、維持正確的目錄結構(含 `tests/vectors`),全部 ok:
   ```
   ok batman-prov/boot  ok .../cbor  ok .../cose  ok .../health  ok .../keystore  ok .../node  ok .../proto  ok .../provstore  ok .../sock
   ```
   - 第一次跑時,proto 有 5 個 FAIL:`open ../../../../tests/vectors/219-protocol/vectors.json: no such file`。
   - 原因是我的複本少了 vectors 目錄。翻轉驗證:只把 `tests/vectors` 補回正確的相對位置,其他不動,就轉為 ok。所以這 5 個 FAIL 來自我的複本佈局,與產品無關。
2. **rc 10 mutant(我自己做的)**:把 `if g, ok := metaGen(dir); ok && g <= ovRec.Generation` 改成 `if true`,`TestRc10NeverDowngrades` 就 FAIL:
   ```
   boot_test.go:409: Run downgraded: {RC:10 Verdict:legacy Action:p5 record corrupt (p5 gen 0 <= overlay 1): re-persisted ...
   ```
   負對照成立。
3. **tests/prov-p1 共 6 支**:在 WSL root 下對產品 files 的 /tmp 複本執行,全部 PASS:
   ```
   99ZZ fails=0 / AUTOCOMMIT-PROV fails=0 / M6 RESULT: PASS / PASS=8 FAIL=0 / RC10 RESULT: PASS / STATECMP fails=0
   ```
4. **openmanetd 的啟動順序與讀設定的方式(04 實查 + 原始碼)**:
   - uci-defaults 在 `S10boot` 裡同步執行;`S99openmanetd` 在它之後。
   - Pi 4 的 `/boot`(p1)在 preinit 的 `79_move_config` 就掛上了,所以 S10 時 `is-trial` 讀得到 autoboot.txt。
   - viper 只在程序啟動時讀一次 config(`cmd/root.go:79-91`);worker 只在 `Start` 時決定要不要啟動(`mgmt.go:122-125`)。
   - 每次 Start 都會記一行 log:`mgmt AddressReservationWorker initialized`(04 的 logread 實查到)。這行可以當 E1c v4 的正向證據。
5. **viper / YAML 語意(用 openmanetd 自己的 `internal/config` 套件實測;module cache 離線、GOPROXY=off)**:
   ```
   defer.yml: addrRes=false gnss=true          ← §13.7 的區塊附加在檔尾:有效,其他設定保留
   base.yml:  addrRes=true  gnss=true
   dup.yml:   ReadInConfig ERR ... mapping key "alfred" already defined   ← 重複的頂層鍵:整份 config 讀失敗
   nonl.yml:  addrRes=false gnss=false          ← 原檔最後沒有換行:前一行的值被吃掉,註記行也跟著消失
   case.yml:  addrRes=true                      ← 已有 `Alfred:`(大小寫不同):暫停無效
   ```
   - `cmd/root.go:89` 讀設定失敗時會被**靜默忽略**。所以 dup 的情況是 fail-open:openmanetd 用全部預設值跑(addressReservation=true),原本的 gnss/comms 設定也一起消失。

---

## 發現

### MAJOR

**B9-M1:config.yml 有兩個寫入者;「完全相符才刪」會讓暫停變成永久,而且會一路回到 B-M4 本身**

- **情境**:unclaimed 節點做 OTA,進入 trial,區塊已附加。trial 期間(尤其是 #261 的 hold-commit「操作員驗收」,這時操作員本來就會打開 openmanetd 網頁),openmanetd 自己寫了一次 config.yml。寫入來源有三種:
  - 網頁設定頁的 POST(`internal/frontend/handlers.go:772-814`):整份檔案先轉成 `map` 再 `yaml.Marshal`,**所有註解都會被剝掉**,`alfred.dataTypes.addressReservation: false` 被當成一般設定寫回去;
  - GNSS / comms / audio 的設定 handler(`persist.go` 的 `PersistGNSSConfig`、`PersistCommsConfig`、`PersistCommsAudio`,由 `handlers/gnss.go:100`、`comms.go:100,494` 呼叫);
  - BLOS 啟用(`blos/manager.go:277`)。這幾個是 yaml.Node 重新序列化,**縮排會變成 4 格**。

  接下來 commit,`addr_defer_release` 的精確比對不成立,依設計只記一行 WARN、不動檔案。結果是:
  1. 這個槽永遠不做位址保留:停在 `10.41.254.x` 這個 bootstrap 位址,`dhcpconfigured=0`,也沒有 IP 衝突偵測(偵測就在被停掉的 worker 裡,`address_reservation.go:58-76`);
  2. 之後每次開機的補救點也一樣比對失敗;
  3. 一旦節點被 seed,`--on-join` 會把 `dhcpconfigured=0` 和 bootstrap IP 存進 p5(`batman-config-save:47-48` 的 PRESERVE);
  4. 下一次 OTA 是從 p5 還原,`99-halow-identity:7` 會跳過,所以**不會暫停**;新槽的 `dhcpconfigured=0` 又讓 worker 在 trial 裡觸發 → **B-M4 的競賽原樣回來**。
- **證據**:
  - 我用 openmanetd 的 `PersistGNSSConfig` 處理附加了區塊的檔案,輸出為:
    ```
    # batman-addr-defer
    alfred:
        dataTypes:
            addressReservation: false
    # batman-addr-defer
    ```
    縮排從 2 格變成 4 格。
  - 換成設定頁那條 map 來回轉換的路徑:兩行註記都消失,`alfred:` 被排序到檔案開頭。
  - 所以 §13.7「擁有權:openmanetd 只讀」不成立;「安全:能寫 config.yml 的本來就是 root」也不成立,因為經過驗證的網頁使用者就能寫(`DefaultAuthEnable=true`,`config.go:146`)。
- **修法**(擇一,或並用):
  1. 進入暫停時,先把附加前的原檔存成同目錄下的 `config.yml.batman-predefer`(root 0600),並記下它和「原檔 + 區塊」的 sha。解除時:
     - 檔案仍等於「原檔 + 區塊」→ 原子地換回原檔;
     - 不等(被 openmanetd 或網頁改過)→ **不要只記 WARN**,也要有確定的結果。可選擇:
       - (a) 換回原檔,另外記下 trial 期間網頁改動被丟掉的 diff(寫到 p6 log),並大聲留下 `ADDR-DEFER-UI-CHANGES-DISCARDED`;
       - (b) 用語意方式刪掉那個鍵(需要有 YAML 能力的工具,例如在 batman-provhelper 加一個子命令,用 yaml.v3 Node 處理)。
  2. 不管選哪個,都要有**可觀測的閘**:
     - daily-validation tier A 加一項:「已 commit 的槽,config.yml 裡沒有 `addressReservation: false`,而且 `dhcpconfigured=1`」,否則 FAIL;
     - `halow-status` 也要顯示 deferral 狀態。
  3. **負對照**:stub 測試要能注入「Persist 式重新序列化」和「map 式重新序列化」兩種檔案(可以用我在 `scratchpad/h2/rv9/t/` 的 probe 產生),舊的精確比對版本必須 FAIL。

### MINOR

**B9-m1:暫停只綁在「fresh 槽 + 99-halow-identity」,沒有綁在「這次開機是 trial,而且 worker 會觸發」**
- 設計表格寫「legacy / claimed 的 OTA:不變」,前提是 p5 裡的 `dhcpconfigured=1`,但這個前提沒有證據。現場有兩條路會讓還原槽在 trial 裡觸發 worker:
  1. 在暫停期間(或 commit 後 125 s 內)對節點做 `--seed`,p5 存進 bootstrap IP 和 `dhcpconfigured=0`。之後要等 on-join 在 JOINED 時改寫;在那之前再做一次 OTA,就會競賽。
  2. 還原槽的 IP 跟 DB 裡的節點衝突(`address_reservation.go:66-76`)。
- 建議把機制改成**每次開機做一次、不帶狀態的對帳**:
  - 由一支 init 腳本在 openmanetd 之前**同步**執行(START ≤ 98;`batman-autocommit` 的 `run` 是 procd 的非同步 instance,不能拿來保證順序);
  - `is-trial=0` **而且** DT `tryboot=00000001` → 確保區塊存在;
  - `is-trial=1` → 確保區塊不存在,並重啟 openmanetd(如果它在跑);
  - `is-trial=2` → 不動。
  - autocommit commit 之後,同一個函式立即呼叫一次。
- 這樣就**不需要 p6 標記**(順便消掉 B9-m2),revert、rollback、操作員 commit、降版都由「當下的 trial 狀態」決定,不靠記憶。

**B9-m2:p6 標記可能寫進還沒掛上的掛載點**
- `99-halow-identity` 在 S10 執行,`/opt/batdata` 由 S11 `batdata-mount` 掛上,或由 95 在 uci-defaults 裡先掛。
- 設計沒有像 `99zz-batman-prov-state:42` 那樣用 `grep ' /opt/batdata ' /proc/mounts` 擋。沒掛上時,標記會寫進 overlay 上的空目錄,p6 掛上後就被蓋住看不到。
- 修法:加上同樣的掛載檢查,或照 B9-m1 直接拿掉標記。

**B9-m3:commit 之後、解除之前,當機卻沒有重開**
- 補救點只在「下一次 committed 開機」。如果 autocommit 在 commit 和 release 之間被殺,節點卻沒有重開(現場可能連跑數週),暫停就一直存在。
- 修法:joinwatch 的 tick 也做一次對帳(committed + 有區塊 + 沒有活的 autocommit run → 解除)。
- 另外,release 必須排在 `: > $COMMITTED; sync` **之後**,任何失敗都不能影響 commit 的結果;設計要寫明這個順序。
- 設計引用的 autocommit 行號 `:537` / `:551` 實際是 `:536` / `:550`。

**B9-m4:commit 後的「保留位址 + 重開」不保證會「回到同一槽」,也不保證真的會重開**
1. openmanetd 用的是 plain `reboot`(`system.go:9-10`)。`batman-reboot` 的 K90 hook 沒有 `.want` 時不會介入(`/etc/init.d/batman-reboot:30-31`),所以 Pi 4 的 EEPROM 問題(manet02 上 plain reboot 5/10 落到 p1)會讓節點先落在 A,再由 batdata-mount 的自檢做一次修正重開。設計表格的「回同一槽」要改成「可能先繞到 A 一次,靠 #209 自檢修正」。
2. worker 的 `cleanUpInterfaces` 會 reload network(`address_reservation.go:153-158`)。如果 bat0 因此重新 up,procd 的 interface trigger 會重啟 openmanetd(`/etc/init.d/openmanetd`:`procd_add_interface_trigger ... bat0 ... restart`),`system.Reboot()` 可能根本不會被呼叫。⚠️ 這是推論,沒有實測。
- E1c v4 必須把「不重開,但已保留位址」、「繞到 A 再修正」都當成要記錄的結果,不能判 FAIL 或 abort。

**B9-m5:進入暫停的條件只看 `is-trial=0`**
- #133 stale-fallback 開機(`is-trial=0`、DT `tryboot=0`)也會進入暫停,而 autocommit 在那種開機不會 commit,也走不到 `:326`。
- 修法:比照 autocommit 的 `REVERT` 判斷,改成 `is-trial=0 && dt_tryboot=1`。⚠️ 我沒找到 fresh 槽在 stale-fallback 下開機的實例,這條是理論路徑。

**B9-m6:YAML 防護不完整,而且 fail-open**
- 「已經有 `alfred:` 鍵就不暫停」用 grep 判斷時,`Alfred:`、加引號的鍵、flow 寫法都會漏掉(實測 `case.yml` addrRes=true)。
- 檔尾沒有換行時,值會被吃掉(`nonl.yml`)。
- 真的出現重複鍵時,openmanetd 的**整份設定**都失效(`dup.yml`,`root.go:89` 靜默忽略錯誤)。
- 修法:
  - 附加前先確保原檔以換行結尾;
  - 用 `grep -iq '^["'\'']\?alfred["'\'']\?[[:space:]]*:'` 加上檢查 `{` 的方式判斷;
  - fresh 槽的 config.yml 一定等於 image 的 /rom 版本(04 實查 `cmp` = SAME_AS_ROM),所以再加一個 **build/CI lint**:image 的 config.yml 不能有任何 alfred 鍵;
  - 附加後讓 openmanetd 的「Using config file」log 成為 v4 的斷言:沒有這行就代表讀檔失敗。

**B9-m7:§13.6「沒有其他元件會重開」只看了位址保留這條路徑**
- openmanetd 還有網頁的「重開」quick action(`system/services.go:136-137`)和 BLOS 的重開(`blos/blos.go:103-108`)。
- 操作員在 #261 hold 期間按下重開,trial 就會**無聲退回**。這是操作員自己的動作,不在 §13.7 的範圍,但操作文件要寫明。
- `/etc/init.d/openmanetd` 每次 bat0 up 都會重啟它,§13.6 已提到,屬實。

**B9-m8:暫停期間的現場影響要寫進設計**
- 已查證的部分:
  - 暫停期間沒有 IP 衝突偵測;
  - 節點停在 `10.41.254.<2..254>`,253 個值裡隨機挑一個(`99-halow-identity:23-24`);
  - 多個暫停中或第一次開機的節點之間,有生日問題式的碰撞機率;
  - image 沒有 `dhcp.ahwlan`(04 的 `/rom` 實查只有 lan/wan),所以 AP 端沒有 DHCP。unclaimed 節點的 AP 由 keyguard 關著,現在不影響使用者。
- 會讓暫停無限期的情況:
  - hold-once(`held`)的 trial 不會退回;
  - 今天 openmanetd 會在約 165 s 重開,反而會把這種 trial 結束掉。
- 改後 trial 會一直停在 bootstrap 位址。這是預期中的行為改變,要寫進生命週期表。

**B9-m9:安全段落的信任界線寫錯**
- config.yml 可以經由 openmanetd 已驗證的 HTTP API 寫入(`handlers.go:772-814`)。網頁使用者因此可以:
  - 移除區塊,讓 trial 中的節點保留位址並重開(等於遠端讓 OTA 退回);
  - 或寫入 `false`,永久停掉位址保留。
- 能力的增量不大,因為網頁本來就能重開節點,但要照實寫。
- ⚠️ 未查:fresh unclaimed 節點的網頁 auth 在 root 沒有密碼時是否等於不設防。

### E1c v3:出口逐條追查,以及 v4 必須斷言的項目

DRY 的 log 與腳本一致(snap → dead-man 放置 → finish,最後 `DRY DONE`)。78ddbeb 的 holder 修正也合理:holder 的 cmdline 保留成 `/bin/sh .../batman-config-save-dvhold`;trap 安裝在 `[ ! -e "$D" ] || die` 之後,所以不會誤刪別人的 D。

出口問題:

**B9-m10:p5 還原的結果在三個出口沒有被斷言**
- 位置:`e1c.sh:137`(mkfs 失敗)、`:142`(apply 沒 arm)、`:147`(p5 不是 unseeded)。
- 這三處都跑了 p5-restore,但沒有像 `abort_to_a` 那樣檢查 `^P5-RESTORED $RUN`。
- 如果還原失敗,trap 仍會在 A 上取消 dead-man 並啟動 joinwatch,節點就帶著空的 p5 繼續跑,結果只寫「FAIL」。
- 修法:斷言 `P5-RESTORED`;失敗時寫「needs a person」,而且不要啟動 joinwatch。

**B9-m11:SNAP 之後的失敗出口留下殘留,但沒有回報**
- 位置:`:108`、`:124`、`:135`、`:137…`。這些出口都不呼叫 `finish`,dirty flag 和 snapshot 會留下來。下次執行時 prov-base 會 fail-closed 拒絕,這是對的方向,但 RESULT 應該明列殘留。
- `:104` 的 tar 解壓結果沒有檢查;DRY 在 payload 解壓失敗時仍會判 DONE。

**B9-m12:第 3 步沒處理「繞到 A 又修不回 B」**
- 這接續 B9-m4:post-commit 的 plain reboot 落到 A,而 batdata-mount 修不回(p6 沒掛上或重試用完)。
- 這時 04 停在 A,`[all]`=B,p5 是空的。`find_b` 只找 slot=B,所以腳本會印「dead-man returns 04 to A」,但這句是**錯的**:dead-man 只在 B 上動作。
- 修法:find 迴圈同時用 `q "$ST"` 查 10.41.1.3。如果看到 `slot=A trial_rc=0` 或 `batman-fw-override`,就照實回報並走專門的處理。

**B9-m13:§13.5 和 v3 腳本的版本證據寫法不一致**
- §13.5 寫的是「唯讀 loop 掛 root.squashfs」,v3 改成了 host 端 build 目錄的證據鏈(`e1c.sh:92-103`,註記寫 04 的 busybox 掛不起來)。
- 證據鏈本身成立:節點上驗 PSHA,host 上 SHA256SUMS 同時列出 PSHA 和 batman-build.txt。§13.5 要改成實際做法。

**v4 必須斷言的項目(§13.7 落地之後)**:
1. **trial 裡(B fresh,HELD)**:
   - config.yml 等於「/rom 版本 + 固定區塊」,用 sha 比對;
   - 這次開機的 logread 有「Using config file」(證明 YAML 讀成功),**而且沒有** `AddressReservationWorker initialized`;
   - openmanetd 在跑,而且已經跑超過 125 s;bat0 存在;`dhcpconfigured=0`。
   - 然後**停留**到 uptime ≥ openmanetd 啟動 + 125 + 60 s(約 300 s,在 600 s 的 deadline 之內)才 release,期間 boot_id 不變。v3 在 HELD 之後就立刻 release,證明不了暫停有效。
2. **release 之後**:
   - COMMITTED 先於任何 `Rebooting system`(看 recorder 的時間);
   - 區塊已移除,config.yml 與 /rom 的 `cmp` 相同;
   - openmanetd 的 pid 變了,而且出現 `AddressReservationWorker initialized`。
3. **之後**:
   - `dhcpconfigured=1`,ahwlan IP 不在 10.41.254.x;
   - slot B 已 committed;
   - 記錄是否重開、是否繞到 A(fw-override),這些依 B9-m4 不判 FAIL。
4. **負對照**:同一支 v4 在 wsl.12(還沒有 §13.7)上跑,應在 uptime 約 165–200 s 時於 trial 內重開並退回 A。
   - 證據來自 batdata-mount stop 存到 p6 的 shutdown 記錄,因為 recorder 可能來不及放。
   - 這個結果在 NEG 模式下是預期行為,不是 abort。
   - 這也是「真機重現再修」規則所需要的 B-M4 重現。
5. **Pi 3**:❌ 沒有硬體(03 停用)。「stub 兩板一致」不能證明 S10 時 `is-trial` 在 Pi 3 讀得到 p7(`batman-slot:254-262`,要在 S10 用 tmpd 掛 vfat)。要標成 ⚠️,等硬體。

---

## 沒做、只做了一部分、或是推論的
- ❌ 沒有在節點上做任何破壞性或寫入動作(依指示)。
- ⚠️ B9-m4 的第 2 點(network reload 讓 openmanetd 自己被重啟)是讀原始碼推論出來的。
- ⚠️ B9-m5 的 stale-fallback 是理論路徑。
- ⚠️ B9-m9 未驗證 fresh 節點網頁 auth 的實際行為。
- ⚠️ Pi 3 全部沒有實測。
- probe 的原始碼與 YAML 樣本在 `scratchpad/h2/rv9/`(`t/main.go`、`run.sh`)。
