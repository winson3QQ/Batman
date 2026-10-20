# #254 PR-H1 harness 設計 v3 — 獨立審查 A(第 3 輪,整份)

審查對象:`254-h1-harness.md` v3 整份(並與 `254-h1-harness-v2.md` diff)。節點全程唯讀;沒跑 bluetoothctl / btmgmt;沒印出 IRK。

## 本輪查證
| # | 查證 | 結果 |
|---|---|---|
| X1 | `batman-autocommit` 約 259–290 行(hold-commit,#261 v2.4) | **只在旗標內容 == 開機的 build 版本時才 hold**(`elif [ "$want" = "$(version)" ]`);否則記 `HOLD-COMMIT-DISCARDED`、刪掉旗標、照常走 commit 流程 |
| X2 | `fault-injection.sh:211-228` `held_trial` | 旗標寫的是 `ver=$(nodever)` = **目前執行中的版本**(N3 時是 wsl.9);hold 沒被 trial 吃掉時,`held_trial` 只判 FAIL 並 return,**trial 照樣在跑** |
| X3 | `fault-injection.sh` r1/r3/r4 | 都先呼叫 `precheck`(payload 必須 == 執行中的 build);`ota_boot` = `sysupgrade -n`(trial 槽是 fresh overlay) |
| X4 | autocommit 的 revert 路徑(約 236–250 行) | 到期 revert 時寫 `$ST/bad-slot`(`slot= version=`),之後 `batman-slot reboot committed`;只有 trial 成功 commit 時(約 502 行)才會刪 bad-slot |
| X5 | `batman-slot cmd_reboot` 註解 | Pi 4 EEPROM 在 partition-0 重開後可能不照 `autoboot.txt`(約 5/10 次);explicit partition 重開是 10/10 |
| X6 | PR-F `air-sandwich-04-btmon*.txt` | **是 grep 過的檔案**:沒有 `> HCI Event:` 標頭,第一行就是縮排的 `LE Connection Complete` / `Peer address`;不是完整的 `btmon -r` 輸出 |
| X7 | hold-commit 的引入時間 | `6b3022a 2026-10-07 feat(#265,#261): autocommit v2.4`,比 wsl.2 早 → wsl.2 應該有 hold 邏輯(⚠️ 沒讀 wsl.2 image 本身) |

## §12 對應表逐項檢查
| v2 發現 | 結果 |
|---|---|
| A-R1 / B-M1 btmon 過濾 | ⚠️ 改成以區塊讀、帶方向、SMP 與斷線的 Reason 分開,設計正確;但 fixture 來源是 grep 過的檔案(X6),見 m1 |
| B-M2 rekey 沒驗 kernel | ✅ 先 power off 再用 RPA 做 `ah()`,有 N11。但在 deadman 情境下這個驗證做不到,見 S2 |
| B-M3 / A-m2 鎖 | ✅ lease + 原子替換的 deadman + `dm-fire` 驗 lease;有三個邊角未定義,見 m3 |
| A-R2 preflight 擋產品狀態 | ✅ P6 已拆;hci0 那一列改了 |
| A-R3 / B-M4 N3 救回路徑 | ❌ held trial 的方向對,但直接沿用 `held_trial` 時 hold 不會生效(X1 / X2),見 S1 |
| A-m1 deadman 實作 | ✅ 腳本放在 `bt/`、還原時殺 btmon / 刪 snoop、pgid 從 `/proc` 讀、kill 語法(E25)、等鎖時間 |
| A-m3 FIFO 是互動模式 | ✅ 取樣改 `--timeout`;配對輪寫明是互動模式;有 N2b(但 N2b 的鑑別力見 m2) |
| A-m4 canary | ✅ 不分大小寫,也涵蓋有分隔符的寫法 |
| A-m5 P7 | ✅ 開機等 600 s、時鐘回跳判 FAIL(門檻沒改成用 ring 換一輪的時間,可以接受) |
| A-m6 N5 | ✅ N5a / N5b(預期 FAIL 的「原因」也要比對,見 m5) |
| A-m7 uptime | ✅ |
| A-m8 P5 | ⚠️ P5 用 `--case r1` source,沒問題;但 N3 也打算 source 同一份,而那裡的 precheck 一定擋,見 S1 |

---

## MAJOR

### S1 N3 的 held trial 照設計做,hold 不會生效,02 會被 commit 到 wsl.2
- **情境**:§4.10 N3 第 2 步「以 `FI_SOURCE_ONLY=1` 載入 fault-injection 的函式:arm hold-commit → 寫入 wsl.2 → tryboot」。如果沿用 `held_trial`(X2),旗標寫的是執行中的 **wsl.9**。開機進來的 trial 是 wsl.2,autocommit 判定「旗標寫的不是本 build」→ `HOLD-COMMIT-DISCARDED`(X1)→ trial 健康(mesh 有加入)時會**照常 commit** → 02 就停在 slot B 的 wsl.2,而且是 committed。`held_trial` 會印 FAIL,但 trial 已經在跑,沒有任何東西擋住它 commit。
- 另外,r1 / r3 / r4 都先跑 `precheck`,payload 不等於執行中的 build 時一律拒絕(X3)。N3 刻意要用不同版本的 payload,所以要明寫「不呼叫 precheck,改用 E23 的 slot B 雜湊比對取代」,否則實作者會在這裡卡住,或乾脆把 precheck 拿掉。
- **後果**:不至於失聯,因為 commit 的前提是 mesh 健康。但 N3 宣稱的「trial 不 commit、重開自動回 A」不成立,而且 02(BENCH)會停在舊版槽,之後 ab-selftest 的前提(BENCH 在 slot A)、版本一致都會壞,要手動 `rollback` + `reboot committed` 才能救。
- **修法**:
  1. 旗標內容寫 **payload 的版本**。從 payload 讀(`metadata` / slot B rootfs 的 `/etc/batman-build`),必須等於 E23 查到的 wsl.2 字串。
  2. 進 trial 後先驗 `$R/autocommit.ctl/hold-commit` 存在且 `autocommit.hold-discarded` 不存在。不成立就立刻 `batman-slot reboot committed` 回 A,再判 N3 FAIL「hold 沒生效」。
  3. 驗證 wsl.2 image 裡的 autocommit 有 v2.4 的 hold 邏輯:唯讀掛載 slot B rootfs,grep `HOLD-COMMIT`。
  4. 回 A 時用 `batman-slot reboot committed`(explicit partition,X5),不要用 plain `reboot`。
  5. 寫明 revert 路徑會留下 `bad-slot`(X4)。這不影響 slot A,但收尾要印出它、記錄進報告,並說明對之後 OTA 到 slot B 的影響(同版本的 slot B 不會被當成 stale fallback commit)。

### S2 deadman 的 rekey 做不到 kernel 驗證,而 N7 的預期與 §4.7 規則互相矛盾
- **情境**:§4.7 規定 `rekey` 必須「04 non-connectable `adv-on` 一次 + 02 取樣一次 + 主機用新 IRK 做 `ah()` 吻合」才刪 `irk-exposed`,不過就保留標記並 FAIL。可是 deadman(`dm-fire`)是在 harness 已經死掉時、在 04 上單獨執行的:它沒有 02、沒有主機、沒有 Python,節點上要做 AES 只能用 `openssl enc -K`,這會把 IRK 放進 argv,違反 §7。所以 deadman 的 rekey 必定驗證不了 → 保留 `irk-exposed`。
- 但 §4.10 N7 的預期是「deadman 到期後 04 `ble-state` 乾淨、IRK 已 rekey」,§5「harness 中途死掉」那一列也寫還原完成。這兩處互相矛盾。實作者最可能的解法是讓 deadman 不驗證就刪標記,這正好把 B-M2 剛補上的保證拿掉。
- **修法**:明定 deadman 模式的契約。deadman 做 power off → 刪 identity → 啟動,標記改成 `irk-exposed state=rekeyed-unverified`,不刪。preflight P6 / tier A 看到這個狀態就 FAIL,並在訊息寫明處置:跑 `ble-recover`(harness 子指令,做 adv-on + 02 取樣 + `ah()` 驗證後清標記),或重開 04。另一種做法是 deadman 直接 `batman-slot reboot committed` 重開 04:這是最確定的作廢方式,代價是 OTS 中斷約 2 分鐘,要把這個取捨寫出來讓使用者選。N7 的預期與 §5 要對齊選定的做法,並各自跑一次。

---

## MINOR
- **m1 btmon-judge 的 fixture 不是真實輸出**:E24 引用、§4.7 fixture 要用的 PR-F 兩份 btmon 檔都是 grep 過的(X6),沒有 `> HCI Event: LE Meta Event` / `Disconnect Complete` 等標頭。用這種檔案測區塊解析器,證明不了它能處理真實輸出;實際上線若對不上,就會整輪「無效」→ FAIL,浪費一次 run。改成用 04 上實錄的**完整** `btmon -r` 輸出(E12 作者已經能錄)。從非翻轉輪取樣;翻轉輪的 key 值要先替換成假值再進 repo。另外 `UNPARSED n > 0` 要有處理規則,至少在 fixture 案例中必須為 0。
- **m2 N2b 要有鑑別力**:「04 不開廣播,02 取樣 3 次 → 0 次看見」。如果 04 已經很久沒廣播,02 的 cache 本來就是空的,這個負對照一定 PASS,證明不了什麼。改成 `adv-off` 之後 **5 s 內**取樣一次、30 s 內再一次(在 TemporaryTimeout 30 s 之內,也就是 cache 物件還在時),都必須 0 次看見。
- **m3 lease / deadman 的邊角**:
  - (a) `dm-fire` 等 `flock -w 120` 拿不到鎖時怎麼辦?建議重試到拿到為止,不要放棄;放棄的話狀態會沒還原。
  - (b) 「lease 到期但 deadman 已死、lease 還在」(deadman 被殺或異常結束)時,`acquire` 怎麼判?目前寫法會永遠拿不到,只能等重開。建議:這個情況下只要 `ble-state` 乾淨就可以接手,否則 FAIL 並指示 `ble-recover`。
  - (c) staging 會覆蓋 `bt/` 底下的腳本,而另一個 run 尚未觸發的 deadman 之後會執行這份新腳本(版本錯配)。改成放在 `bt/<run_id>/`,deadman 只執行自己 run 的那份。
- **m4 rekey 驗證取樣的前提**:rekey 在配對段之後做。02 的 bluetoothd 裡還有翻轉輪 `Paired with <04 public>` 的裝置物件(在記憶體,不是 temporary),也有舊 RPA 的物件。驗證前 02 先 `reset`,並用新的隨機名稱;否則舊物件會被誤算 → ah 不吻合 → 假 FAIL。§4.5 的「04 儲存區裡名字符合 MAC 的裝置目錄」要寫成 `/var/lib/bluetooth/<adapter>/<MAC>/`:04 自己的 adapter 目錄名稱也符合 `^[0-9A-F:]{17}$`。
- **m5 負對照要比對 FAIL 的原因,不只是有沒有 FAIL**:例如 N5a 如果 power cycle 之後 kernel 沒有重新啟用 adv instance,會變成「缺桶」FAIL,而不是預期的「(a) 兩個位址」FAIL,原因錯了卻會被當成負對照成立。每個 N* 都把預期的 FAIL 訊息(或結論 token)寫進表格並比對。
- **m6 N3 第 1 步的比對要補**:p5 雜湊與 `uci show` 摘要的比對,要加上 slot A overlay 不受影響(sysupgrade 寫的是 slot B,slot A 的 overlay 應該不變)。`/opt/batdata/state` 在 trial 前後的差異也要印出來(hold 旗標、bad-slot、autocommit log)。

## 新設計的其他部分(查過,沒有發現)
- P6 拆分、tier B 每個 suite 開頭重驗前提:✅。
- T0 前先 `restore`(power cycle 換新 RPA):讓 (b) 段不會剛好跨過 900 s;N5b 在 T0+600 時 RPA 才產生約 600 多秒,< 900 s ✅。
- rekey 先 power off(E27):與 V2 讀碼一致;N11 是真的注入故障 ✅。
- 04 的 deadman 還原動作含殺 btmon、刪 snoop ✅;02 的還原走 bluetoothd 的 SIGTERM 路徑,會先 power off,所以 privacy 與 SC 都會重設 ✅。

## 裁決
**APPROVE-WITH-CHANGES**:BLOCKER 0、MAJOR 2(S1、S2)、MINOR 6。v2 的 3 個 MAJOR 中,R1 與 R2 已修好;R3 改成 held trial,方向正確,但沿用的 `held_trial` 寫的是 wsl.9 的版本號,hold 不會生效(S1)。S1、S2 修完後依規則整份再審。

未驗 ⚠️:wsl.2 image 內的 autocommit 實際有沒有 v2.4 hold 邏輯(要唯讀掛 slot B 才能看,S1 第 3 點要求作者查);kernel 在 mgmt power off / on 後會不會自動重新啟用 adv instance(影響 N5a 的 FAIL 原因,m5)。
