# #254 P1 + H2 — 第 9 輪審查(審查者 A)

**判定:REJECT**(只針對 §13.7。產品 6e3a8c1、harness 78ddbeb 本身這輪沒有 MAJOR)
0 BLOCKER / 4 MAJOR / 8 MINOR。四個 MAJOR 都在 §13.7(位址保留暫停)。

證據檔都在 `scratchpad/h2/rv9/`:
- `omd_test.go` + `omd-test.log`:用 openmanetd 1.3.10 自己的 `internal/config` 套件實跑;
- `gt.sh` + `gt.log`:6e3a8c1 的 mutant;
- `st.log`:tests/prov-p1 實跑結果;
- `config.yml`:04 的 /rom 副本。

## 已驗證(✅,附原始輸出)
- **6e3a8c1 的 mutant 我重跑了。**
  - HEAD `go test ./boot/` ok。
  - mutant1(`ok && g<=` 改成 `ok || g<=`)→ `--- FAIL: TestRc10NeverDowngrades`。
  - mutant2(拿掉 PersistNow 的 `rc==10 && !haveG` 拒絕)→ FAIL。
  - mutant3(改成 `g <= gen+5`)→ FAIL。
  - `deploy/provisioning/batman-config-save` 和 feed 那份 diff 相同(SAME)。
- **tests/prov-p1 實跑(WSL root):**
  - `cfgsave-provget-rc10.sh` → `RC10 RESULT: PASS`(4 項 ok);
  - `cfgsave-frozen-nomount.sh` → `M6 RESULT: PASS`。
- **78ddbeb:**
  - holder 改用 `while :; do sleep 5; done`,所以 argv 會保留,判斷正確;
  - snap 的 trap 設在 `[ ! -e "$D" ] || die` 之後(:118 → :120),所以不會刪掉一個已存在的快照;
  - RUN 有字元集與長度檢查(:17-18),`rm -rf "$D"` 不會變成 `$BASE/`。
- **openmanetd 原始碼事實(§13.6 的部分我重新核對過,成立):**
  - `address_reservation.go:78/167`;
  - `mgmt.go:21`(125 s)、`mgmt.go:122`(只在 Start 時判斷);
  - `system.go:9-12`(plain `reboot`);
  - init 腳本 `START=99`、帶 `--config /etc/openmanetd/config.yml`、bat0 up 時 restart(04 上 `cat /etc/init.d/openmanetd`)。
- **04 / 02 現況:**
  - `dhcpconfigured=1`;
  - logread 有 `AddressReservationWorker initialized`(可以拿來當 E1c v4 的觀測點);
  - 04 的 config.yml 和 /rom 的 sha 前綴相同(`cf5c093a35bcde05`),權限 root 0600;
  - `/boot` 在 preinit 就已經掛好(`/lib/preinit/79_move_config`),所以 Pi 4 在 uci-defaults 階段讀得到 autoboot.txt。

## MAJOR

### A-M1 config.yml 有第二個寫入者 openmanetd;它一改寫,「內容完全相符才刪」就永遠不成立,暫停會卡死
- **情境**:fresh 槽在 trial 或 HELD 的期間,只要 openmanetd 自己寫了一次 config.yml,解除就會失敗。會寫的動作包括:
  - setup 精靈 `PersistSetupAndAuth`;
  - UI 開關 GNSS / BLOS / comms / 音量;
  - BLOS manager 自動切換。

  如果解除因為其他原因延後(見 A-M4),這個窗口會延長到整個 committed 期間。
- **證據**:
  - `internal/config/persist.go:19-60`:讀檔 → 轉成 `yaml.Node` → `yaml.Marshal` → 以 0644 `os.WriteFile` 寫回整個檔案;
  - 呼叫點:`handlers/setup_phases.go:1255`、`gnss.go:100`、`blos.go:236`、`comms.go:100/494`、`blos/manager.go:277/282`、`cmd/setup_reset.go:63`。
  - 實跑 `omd-test.log`:附加我們的區塊後呼叫 `PersistSetupAndAuth`,整個檔案被改成 **4 格縮排**。註記行還在,但區塊內容變成:
    ```
    alfred:
        dataTypes:
            addressReservation: false
    ```
    → 和寫入時的 bytes 不同 → 依 §13.7 第 2 點「不等就不動,記 WARN」→ `addressReservation:false` 永久生效。
  - 另外,§13.7「擁有權」寫「openmanetd 只讀」,這和原始碼不符。
- **修法**:
  1. 擁有權改寫成實際情況:openmanetd 也會寫整個檔案;
  2. 解除改成結構比對:在兩行註記之間,去掉空白後恰好是 `alfred:` / `dataTypes:` / `addressReservation: false` 三個鍵,沒有別的鍵,就刪。註記不在,但 `alfred.dataTypes.addressReservation: false` 仍存在 → CRIT,不要默默放著;
  3. 測項:`addr-defer.sh` 要有一個「中途經過 openmanetd 式重寫」的案例。可以直接用 rv9 那段 Go 產生檔案。負對照是現在的逐字比對版本,它會 FAIL。

### A-M2 檔案改寫不是原子的,而 openmanetd 遇到 YAML 錯誤會靜默改用全部預設值
- **情境**:
  - 附加區塊到一半斷電、或寫入被截斷;
  - 原檔最後一行沒有換行;
  - 解除時與 openmanetd 啟動同時進行:autocommit 和 openmanetd 都是 START=99,`S99batman-autocommit` 排在 `S99openmanetd` 前面(04 `/etc/rc.d` 實查),而 autocommit 是背景 procd 服務,補救點會和 openmanetd 讀 config 並行。

  在這些情況下,openmanetd 讀到的是壞掉的 YAML。
- **證據**:
  - `cmd/root.go:96-98` 的 `ReadInConfig` 失敗只是不印訊息,照樣繼續。
  - 實跑(`omd-test.log`):
    - 壞掉的 YAML → `READERR … did not find expected key`,`addrRes=true`,而且 **`gnss=false`**:04 的 `gnss.enable: true` 也一起丟了;
    - 重複的 `alfred:` 鍵 → 解析錯誤 → 全部用預設值;
    - 原檔沒有結尾換行就直接附加 → `controlSource` 變成 `openvlm# batman-addr-defer begin`。
  - 換句話說,失敗時不只是「回到今天的競賽」,而是整個節點的 openmanetd 設定被靜默重設,而且之後沒有人修回來。
- **修法**:
  - 進入與解除都改成:在 `/etc/openmanetd/` 內建 temp 檔(不放 /tmp,避免 TOCTOU)→ 必要時先補換行 → 寫入 → `fsync` → 讀回比對(進入:前段 bytes == 原檔,尾段 == 區塊;解除:結果 == 原檔去掉區塊)→ `mv` 原子取代 → 保留 0600;
  - 讀回不符就不取代,並且 CRIT;
  - 測項加入「截斷的區塊」與「沒有結尾換行」兩個案例。

### A-M3 進入條件沒有對準 worker 真正的觸發條件:claimed / legacy 的 OTA 也可能觸發;Pi 3 的 trial 判斷沒有證據
- **情境 1**:worker 的觸發條件是 `!configured || ipConflictDetected`(`:78`),在**任何** trial 都可能成立,但 §13.7 只在 `99-halow-identity` 的個人化路徑裡進入暫停。從 p5 還原時,`99-halow-identity:7` 會直接 exit,所以不會暫停。
  - p5 的 `openmanetd.config.dhcpconfigured` 是由 config-save 持久化的(`batman-config-save:48`)。
  - p5 寫入 0 的情況,例如:
    - 新卡開機後約 165 s 內(保留位址之前)就被認領(`--save`);
    - 或者在保留之前做了 `--seed`。
  - 之後只有 joinwatch 的 `--on-join`(`joinwatch:147`,要先加入 mesh)才會把 1 寫回 p5。**claimed + placeholder 的節點永遠不會加入 mesh**(§13.2 第 4 點)→ p5 一直是 0 → 每次 OTA 還原出 `dhcpconfigured=0` → trial 裡又是 125 s 的 plain `reboot` 和 commit 競賽。
  - 這就是 B-M4,只是發生在 claimed 節點上。§13.7 生命週期表把「legacy / claimed 的 OTA」寫成「不變(跳過)」,沒有任何證據。
- **情境 2**:進入條件依賴 uci-defaults 階段的 `batman-slot is-trial`。
  - Pi 4:✅ /boot 已在 preinit 掛好。
  - Pi 3:`autoboot_read` 要用 `tmpd`/vfat 唯讀掛 p7(`batman-slot:254-263`),在 uci-defaults 階段 ❌ 沒有驗證過;
  - rc 2 → 不暫停 = 失敗方向是今天的競賽,而且偏偏發生在最慢、餘裕最小的 SKU。
- **修法(比原設計更簡單)**:
  1. 另寫一支排在 96 之後的 uci-default(或放進 99zz),**不看是不是 trial**,只要 `dhcpconfigured != 1` 就進入暫停。最好在每次開機、只要這個槽還沒被證明是 committed,就保持暫停;
  2. 由 autocommit 用權威的判斷解除:`is-trial` rc 1(包括新卡第一次開機:同一次開機在 `:326` 就會解除,和今天的行為只差一次 openmanetd restart);或 rc 2 而且 `! dt_tryboot`(和 `:329-332` 同一個切分);
  3. 這樣就不必在早期開機呼叫 `is-trial`,claimed 與 legacy 的 trial 也一併涵蓋;
  4. 測項:stub 測「p5 還原出 dhcpconfigured=0 的 trial」。負對照是 §13.7 原版:不會暫停。

### A-M4 暫停卡住時沒有任何訊號,也沒有時間上限;「下次開機補救」對不會重開的節點等於沒有補救
- **情境**:
  - autocommit 是一次性服務、沒有 respawn(`/etc/init.d/batman-autocommit`:「No respawn」);
  - commit 之後到解除之前,如果 autocommit 被殺,或 `openmanetd restart` 失敗,或發生 A-M1 的不相符;
  - 或補救點(`:326`)根本沒被執行到:
    - SKIP-ONCE(`:298`)、fw-override(`:307-318`)會在 `:326` 之前 exit;
    - is-trial rc 2 而且不是 tryboot 時,會 exit 0。

  這些情況下,節點會一直停在 bootstrap 位址,直到下一次開機。而 commit 之後唯一會造成重開的,正是被我們暫停的那個保留動作,所以實際上「沒有下一次開機」。
- **現場後果**:
  - `dhcpconfigured=0` → `NodeDataWorker` 不會廣播節點資料(`internal/mgmt/node.go:79-88`)→ 其他節點和地圖看不到它;
  - 多台卡住的節點之間,bootstrap 位址 `10.41.254.{2..254}` 可能撞號;
  - `lan` 段沒有清掉(`cleanUpInterfaces` 沒有跑);
  - `halow-status:122` 只報 INFO「still on bootstrap」,沒有任何 WARN 或 CRIT。
- **修法**:
  - `halow-status`:committed 而且 config.yml 有暫停區塊(或標記存在)→ CRIT;
  - daily-validation tier A 加同一個斷言;
  - 解除的擁有者仍然只有 autocommit,但 joinwatch 的 tick 在「committed + 有區塊」時呼叫 `batman-autocommit addr-reconcile`(同一個函式,冪等),讓時間上限是分鐘級,而不是「下次開機」;
  - 生命週期表要把上面每一種情況各列一行。

## MINOR

1. **§13.7 的依賴證據寫錯。**
   - 「openmanetd 只讀」:錯,見 A-M1。
   - 「keep.d 在 `-n` 不保留」:真正的理由是 `platform-ab.sh:18-19` 把 config tar 的流程整個停用了。`keep.d/openmanetd` 保留的是整個 `/etc/openmanetd/` 目錄(04 實查),包括 db。
   - 要改成引用正確的 file:line。
2. **標記和區塊是兩個事實來源,而且契約已經寫明「只看區塊」。**
   - 標記殘留(trial 被退回到舊版 A,舊版不會清)之後,如果下一次 OTA 是 claimed 的,commit 時會多做一次沒有必要的 openmanetd restart(會中斷 comms 和 alfred)。
   - 修法:只有真的刪掉區塊時才 restart;標記帶 boot_id,只用來診斷。
3. **生命週期表缺少的路徑:**
   - autocommit 在 commit 後當掉(沒有 respawn);
   - SKIP-ONCE / fw-override 的開機;
   - 長時間 HELD;
   - trial 中 openmanetd 寫入 config.yml;
   - 位址衝突(`ipConflictDetected`)在 claimed trial 中觸發;
   - Pi 3 在 uci-defaults 的 `is-trial`;
   - 新卡出廠。
   - 另外,「操作員 commit」那一列和第 2 點的呼叫點 `:551` 互相矛盾:`:551` 在 deadline 才會跑到,表裡卻寫「下次開機」。
4. **commit 之後約 125–170 s 的保留重開,現在剛好落在操作員最可能開始認領的時候。**
   - B-B1 規定只有 committed 才能認領。
   - 認領的 `--save` 可能被 `reboot` 打斷,或者把 bootstrap IP + `dhcpconfigured=0` 寫進 p5,接著觸發 A-M3。
   - 建議:helper 在「committed 但 `dhcpconfigured != 1`」時,把認領也當成 `E_BUSY`(位址保留尚未完成),並寫進 §3。
5. **負對照:** §13.6 的 F34(168 s 重開)是在 `batman_bypass=1` 的 trial 量到的,不是 HELD 的 unclaimed trial。v4 的「trial 內不重開」需要同一條路徑上的負對照:wsl.12(沒有 §13.7)跑一次 HELD 的 trial,預期 ~165 s 重開;或者明列只有 stub 層級的負對照。
6. **E1c v3 的出口與細節(v4 要一併修):**
   - rc.local 只做一次 `ping -c 5`,可能早於網路就緒 → ARP 學不到。改成重試 60 s;
   - 保留之後的 IP 是亂數 `10.41.<1-252>.x`(`uci_network.go:724-739`),sweep 的範圍(254 / 1)多半掃不到,實際上只能靠 ARP 和 mDNS,要照實寫;
   - prov-base 的 `STATEFILES`(:23)要加 `addr-defer`,否則殘留的標記會被 compare 漏掉;
   - `abort_to_a` 回到 A 之後要斷言:A 的 reconcile 已經清掉 marker=B,而且 A 的 config.yml 的 sha == /rom 的 sha。
   - 其餘出口我逐條重看過:
     - 前置條件與 DRY 的出口都沒有改變任何狀態,或者已經收尾(DRY log 吻合);
     - commit 之後的 `exit 1` 依賴 dead-man(rc.local 版本在保留重開之後仍有效,trial 那次開機的 timer 會在重開時消失),和 §13.3 的描述一致。
7. **rc 10 的信任界線:** p5 的 meta 沒有簽章,gen 可以被改。擁有實體卡的人可以把 gen 改低,再弄壞 cbor,讓 legacy 槽把自己的紀錄覆蓋上去。這在現有的威脅模型內(rootfs 沒有加密,實體取得本來就贏),但 §8 要明寫,不要讓人以為 rc 10 擋得住實體攻擊者。
8. **替代機制(⚠️ 未驗證,供選擇):** viper 開了 `AutomaticEnv`(`root.go:93`),openmanetd 用的是全域 viper(`openmanet.go:45`)。用環境變數覆寫 `alfred.dataTypes.addressReservation`,完全不必動 config.yml,也就沒有 A-M1 / A-M2 的問題。
   - 但要改 openmanetd 的 init 腳本(覆蓋上游檔案,不耐久,見 #264 的教訓),而且 env 名稱帶點號、IsSet 是否成立都要先實測。
   - 這只是比較基準,不是推薦。

## E1c v4 必須斷言的項目(§13.7 落地之後)
**HELD trial 期間:**
1. config.yml 的前段 bytes == /rom 原檔,尾段 == 區塊,權限 0600;marker = `B`;`dhcpconfigured=0`。
2. 這次開機的 logread **沒有** `AddressReservationWorker initialized`;openmanetd 在跑;記下每一次 openmanetd 啟動的時間(bat0 up 時的 restart)。
3. 同一個 boot_id,在最後一次 openmanetd 啟動之後至少撐過 300 s(≥ 2 × 125 s);boot-reasons 沒有新增的行。這一項取代 v3 的「150 s 內做完」,dead-man 仍然要在 release 之前種好。
4. v3 原有的斷言保留:unclaimed 判定、HELD、沒有 AP 介面。

**release 之後:**
5. 10 s 內:B committed;區塊已刪,config.yml 的 sha == /rom 的 sha;權限 0600;marker 已刪。
6. logread 在 release 之後出現 openmanetd 重啟,以及恰好一次 `AddressReservationWorker initialized`。
7. release 之後 125–200 s 內,recorder 錄到 `Rebooting system to apply new network settings`,B 消失。

**新的那次開機:**
8. slot B、`trial_rc=1`;`dhcpconfigured=1`;ahwlan 不在 10.41.254.0/24;沒有區塊、沒有 marker;撐過 300 s 沒有第二次保留重開。

**其他:**
9. 負對照見 MINOR-5;A-M1 的「中途經過 openmanetd 重寫」案例在 stub 層做。
10. VEXP、hold、payload 都要換成帶 §13.7 的 rc。fleet 要先升級到那一版,再跑 v4。

## 審查範圍說明
- 沒有在節點上做任何寫入:只用唯讀 ssh 讀 config、init、rc.d、logread、uci get。
- 沒有測 Pi 3(03 停用)。
- §13.7 還沒有實作,所以 A-M1..M4 是依原始碼加上 openmanetd 套件實跑推得的。實作之後,stub 測試與 E1c v4 才是最終證據。
