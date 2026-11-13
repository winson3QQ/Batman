# #254 app — 已持有的 device_id 再被認領(254-app-s1 §5.1 補充設計)

狀態:**v2(審查中)**。v1(35e4feb)第 1 輪:A APPROVE-WITH-CHANGES(1 MAJOR / 5 MINOR)、B APPROVE-WITH-CHANGES(2 MAJOR / 4 MINOR);
處理對照見附錄 R1。範圍:254-app-s1.md v8.5.1 §5.1「已有 node 紀錄或 pending 的 device_id 再被掃到 → 不覆寫;先確認」的落實方式。
起因:code review r1(4967f5d..306bcf8)指出 306bcf8 的「移到一旁」機制本身沒有設計(A-M1、A-M2、B-M1)。本文件取代 306bcf8 在
§5.1 寫的實作註記;程式在本文件通過審查後才改。

## 0. 一句話

**有效的紀錄在新認領 CLAIMED 之前一律不動;被取代的紀錄在取代前先「複製」到 `forgotten-*/`,再由原子寫入蓋過。**
正確的 QR 永遠能往前走(確認後重新認領)。複本**只是留在手機上**:本版沒有還原 UI,replay 也還不會讀它 —— 確認之後,被取代的紀錄
在 app 裡就**回不來**(§4 標 ✗ 的列)。所以對話框只請「剛重置這台節點」或「確定這張 QR 才對」的使用者確認。

## 1. 事實(附證據)

| # | 事實 | 證據 |
|---|---|---|
| F1 | provd 的狀態快取每 4 s 輪詢、ctl 最多等 10 s;`invalidate()` 只設 needOwners / needPSK,不碰 state → CLAIMED 之後 4–14 s 內 STATUS 仍說 unclaimed、NX 仍成功 | `feed/batman-prov/src/provd/server.go:21-22`、`:618-622`、`:561` |
| F2 | K 只在 claim/begin 之後(CheckMac response)才用到;NX 與 node_cert 驗證不看 K → 錯的 K 也會走到 PersistPending | `app/rust/batman-proto/src/claimflow.rs:5-8`、`:171` |
| F3 | finish 碼:3 → BeginAgain、4 → AppBug、9 → TryReplay、13 → Committed、7 / 其他 / 無回應 → Unknown | `app/rust/batman-proto/src/flow.rs:9-15, 54-68` |
| F4 | app 沒有接 §5.2 replay:`grep -rn replay app/lib` 為空;bridge 沒有 replay API(batman-proto 有 `replayflow.rs`,未經 bridge) | grep 輸出(2026-11-13) |
| F5 | 清單只列 `node/`;pending 與 `forgotten-*` 不顯示;沒有忘記 pending、也沒有還原的 UI;release 版的 app 私有目錄使用者拿不到 | `app/rust/bridge/src/api/owner.rs:50-53`;`app/lib/nodes.dart:1546-1553` |
| F6 | `node/<id>` 的寫者只有 claim 頁(Claimed 步驟);移除者只有 nodes.dart 開發用長按 `_forget`(`storeRemove`,刪除);owner session 只寫 `net/` | `app/lib/claim.dart`(Claimed 步驟)、`app/lib/nodes.dart:431, 551`、`owner.rs:391` |
| F7 | 「node + pending 並存 → 刪 pending」(§5.1)在 app **沒有實作** | grep `claim-pending` in app/lib:只有 claim.dart 讀 |
| F8 | AAD = 最終路徑 + 檔頭世代號 → 複本只有搬回原路徑才打得開 | `app/rust/batman-proto/src/store.rs`(`aad`) |
| F9 | file 後端重燒 = 新 DAC、新 device_id → 同一 device_id 再出現只可能是**重置**回 Unclaimed(p5 identity 還原) | 254-app-s1 §5.3 末行;`feed/batman-prov/src/boot/boot.go:185-191` |
| F10 | ⚠️ 未驗證:Android untrusted_app 能否對 app_data_file 做 `link()` → 設計不依賴 hard link | 未查證 |
| F11 | node 紀錄與 pending 目前沒有時間欄位(pending key 1–7,node key 1–8);254-app-s1 §3 寫 pending 含「時間」 | `app/rust/bridge/src/api/claim.rs`(`pending_record`、Claimed 步驟) |
| F12 | ⚠️ 讀 node 紀錄的程式以 key 取值(`get`),多一個 key 預期不影響 —— 實作時以測試確認(T10) | `owner.rs`(紀錄解析) |
| F13 | claim.verify 只對 Unclaimed 成功(否則 9)→ CLAIMED 證明節點當下是 Unclaimed | 254-app-s1 §5.1 第 9 項(node.go:514-526) |

## 2. 擁有權(每個資源一個寫者)

所有檔案的唯一寫者仍是 Rust 紀錄儲存層(單執行緒,§3);下表是「哪一步要它寫」。

| 資源 | 寫 / 蓋過 | 刪 | 複製到一旁 | 讀者 |
|---|---|---|---|---|
| `node/<id>` | claim 頁,**只在 CLAIMED 步驟**(Store::write 原子替換,世代號 = 舊 + 1) | nodes.dart 開發用長按(既有,不變;§9 checklist) | claim 頁,CLAIMED 步驟、寫入之前(若已有) | nodes.dart、claim_target |
| `claim-pending/<id>` | claim 頁,PersistPending 步驟(NX + cert 通過後) | claim 頁,CLAIMED 步驟最後一步(既有) | claim 頁,PersistPending、寫入之前 —— **只看磁碟**:已有 pending 且 K 與這次不同就複製(R4) | claim_target、claim 頁 |
| `forgotten-node/<id>-<n>`、`forgotten-pending/<id>-<n>` | 只由 `copy_aside` 新建(不覆寫任何檔) | 無 | — | 無(本版只保留) |

## 3. 規則

- **R1 node 紀錄**:按「重新認領」確認後,PersistPending 照常寫 pending(node 紀錄不動,兩者並存);**CLAIMED 時**依序:
  ① `copy_aside(node/<id> → forgotten-node/<id>-<n>)`,完成(含目錄 fsync)才往下 ② Store::write 新的 `node/<id>` ③ 刪 pending。
  任何時刻 `node/<id>` 都存在。
  - **① 失敗(磁碟滿 / EIO)→ 仍做 ② 與 ③,並記 log「舊紀錄沒有保留下來」**(不印內容)。理由:新憑證只在記憶體,停下來 = 本變更
    自己造出一個只能靠 replay 的狀態;而 CLAIMED 證明節點當下是 Unclaimed(F13)→ 舊紀錄的 owner 憑證已失效、它的 K 與這次 QR 相同
    → 舊紀錄沒有可救的東西。② 本身失敗 → 既有行為(錯誤,pending 留著)。
- **R2 node + pending 並存**:**改寫 §5.1「以 node 紀錄為準,刪 pending」為「以 node 紀錄為準(清單、登入用它),pending 保留不自動刪」**。
  理由:並存有兩種來源 —— ②③ 之間當掉的殘留,與進行中的重新認領;F7:舊規則本來就沒實作,改寫不刪任何程式。
  區分方式(給日後 replay / 清理用):**新增時間欄位**(F11)—— pending key 8 = 寫入時間(unix 秒),node key 9 = CLAIMED 時間;
  pending 時間 > node 時間 → 進行中的重新認領;≤ → 殘留;任一方沒有時間(舊紀錄)→ 未知,保留。本版只寫、不據此刪任何檔。
- **R3 pending,同一張 QR(id 與 K 相同)**:照常認領 = §5.2-1(既有恢復路徑);PersistPending 以同一 K 覆寫。不問。
- **R4 pending,不同 K —— 規則只看磁碟**:PersistPending 時若磁碟上已有 `claim-pending/<id>` 且其 K ≠ 這次的 K(**不論 claim_target
  回 Pending 還是 Node**)→ ① `copy_aside(claim-pending/<id> → forgotten-pending/<id>-<n>)` ② 寫新 pending。**① 失敗 → 不寫新 pending、
  不送 begin**(結束這次,舊 pending 原封不動)—— 這裡沒有只在記憶體的東西會丟。
  - 只有 pending(claim_target = Pending)且 K 不同:**先問**「手機裡有這台節點一次沒完成的認領,用的是另一張 QR 碼。只有在你確定這張
    QR 碼才是對的(例如之前貼錯)時才改用它:舊的認領紀錄會留在手機上,但 App 之後不會再用它。要改用這張 QR 碼嗎?」取消 → 什麼都不寫。
  - K 比對要打開 pending(Keystore `open`):在 claim_target 之後、BLE 之前做一次,結果留在記憶體給 PersistPending;PersistPending 時
    再讀一次檔頭世代號,與當時不同 → 重新打開比對(單一 actor,不應發生;防禦用)。
- **R5 讀不了**(任一紀錄頭壞 / 未知版本,或 pending 的 `open` 失敗):不認領,訊息「讀不到手機裡這台節點的紀錄」。claim_target **兩條
  路徑都讀**。出路:無(254-app-s1 §4:紀錄或 Keystore 壞 = 節點需重燒回收),明寫。
- **R6 CLAIMED 後清掉 `_qr`**:要再認領須重新掃描。
- **R7 node 紀錄的對話框**(F9):「這台節點已在你的清單裡。**只有在你剛把這台節點重置回未認領時才重新認領**:舊紀錄會留在手機上,但
  App 之後不會再用它、也不會顯示在清單裡。要重新認領嗎?」磁碟上同時有 pending 時加一句:「手機裡也有這台一次沒完成的認領。」
- **R8 `copy_aside`**(取代 `move_aside`):讀原檔整個位元組(含檔頭與世代號)→ 寫到目標目錄的 `.<name>.tmp-<rand>`(既有 temp 命名,
  `sweep_temps` 會清)→ `sync_all` → rename 到第一個**不存在**的 `<kind>/<name>-<n>`(存在與否用 `symlink_metadata`:只有 NotFound
  才算不存在,其他錯誤 → Err;store 是單執行緒 actor,檢查與 rename 之間沒有別的寫者)→ 目錄 `sync_all`。當掉 → 只留 temp(被清)或
  完整複本,不會有半個 `forgotten-*` 檔。複本只有搬回原路徑才打得開(F8);它保有自己的世代號,新的 `node/<id>` 世代號 = 舊 + 1,
  所以日後搬回去時 AAD(路徑 + 它自己的世代號)仍相符 —— T2 的「位元組相同」證明這一點。不用 hard link(F10)。

## 4. 狀態表

記號:N = 有效 node 紀錄、N′ = 舊 node 紀錄(節點已重置,舊憑證已失效)、P(K) = pending、FN / FP = 複本。
「出路」= 使用者在 app 裡、不重燒,能否回到可用狀態。

| 手機持有 | QR | 結果 | 磁碟之後 | 使用者看到 | 出路 |
|---|---|---|---|---|---|
| 無 | — | 找不到 / NX 解不開 / cert 拒 | 無 | 失敗訊息 | ✓ 再按 |
| 無 | — | PersistPending 後 begin 拒、finish 3/4/7/9/13、無回應、當掉 | P | 失敗訊息(既有) | 同一 QR 再按 = R3;已提交(13 / 快取)要 replay(F4:**既有缺口**) |
| 無 | — | CLAIMED | N | 認領成功 | ✓ |
| N | 任 | 取消 | N | 「沒有重新認領」 | ✓ |
| N | 任 | 確認,找不到 / NX / cert 失敗 | N | 失敗訊息 | ✓(N 沒動) |
| N(有效)| 任 | 確認,**快取窗口內**(F1):NX、cert 過 → P → finish 9 | N + P | 「認領被拒絕…」 | ✓ N 仍在清單、可登入(R1 不在 PersistPending 動 N) |
| N(有效)| 任 | 確認,**冒充的節點**(DAC 私鑰外洩、廣播同 device_id、Unclaimed)→ CLAIMED | 假 N + FN(真 N) | 認領成功(對象是假的) | ✗ 真 N 只在 FN,**還原 UI 未做** → 真節點要重燒回收。前提是 DAC 私鑰外洩(dev file 後端);防線只有 R7 的確認條件 |
| N′(已重置)| 同 K | 確認,PersistPending 後 3/4/7/9/13/無回應/當掉 | N′ + P | 失敗訊息 | 同一 QR 再按 → R7 → 確認 → R3 再試;已提交要 replay(F4,既有) |
| N′ | 任 | 確認,CLAIMED | 新 N + FN(N′) | 認領成功 | ✓ |
| N′ | 任 | CLAIMED,① 失敗 | 新 N(無 FN) | 認領成功;log「舊紀錄沒有保留」 | ✓(N′ 已失效,R1) |
| N′ | 任 | CLAIMED 中當掉:① 後、② 前 | N′ + P + FN | 清單有 N′,登入失敗 | 憑證只在記憶體 → 要 replay(F4)。與「finish 回了、node 還沒寫就當掉」同一個既有窗口,不是新的 |
| N′ | 任 | CLAIMED 中當掉:② 後 | 新 N + P + FN | 正常 | ✓;P 殘留(R2) |
| N + P(K1) | K2 | 確認(R7 帶 pending 那句)→ PersistPending:FP(K1) + P(K2) | N + P(K2) + FP(K1) | 依結果 | 同 N 各列;**P(K1) 不會被無複製地蓋掉**(R4 只看磁碟) |
| P(K) | 同 K | 任 | 同「無」各列(P 以同 K 覆寫) | — | 同上 |
| P(K1) | K2 | 取消 | P(K1) | 「沒有改用這張 QR 碼」 | ✓ |
| P(K1),K1 錯貼紙 | K2 正確 | 確認 → FP(K1) + P(K2) → CLAIMED | N + FP(K1) | 認領成功 | ✓ |
| P(K1) | K2 | 確認,NX / cert 失敗 | P(K1) | 失敗訊息 | ✓(沒動) |
| P(K1) | K2 | 確認,PersistPending ① 失敗 | P(K1) | 失敗訊息 | ✓(沒動,沒送 begin) |
| P(K1),K1 那次已提交 | K2 | 節點已認領 → NX 解不開 | P(K1) | 失敗訊息 | 要 replay(F4,既有);P(K1) 沒動 |
| P(K1),K1 那次已提交,**快取窗口內** | K2 | 確認 → NX 過 → FP(K1) + P(K2) → finish 9 | P(K2) + FP(K1) | 「認領被拒絕…」 | ✗ 好的 P(K1) 只在 FP;之後 NX 永遠失敗,replay 未接、接上後也還不會讀 FP → **重燒回收**。防線只有 R4 的確認條件 |
| 讀不了 | 任 | 不認領 | 不變 | 「讀不到…」 | ✗(254-app-s1 §4:重燒回收;既有) |

結論:本變更**自己**沒有新增「只能靠 replay」的狀態(R1 ① 失敗照寫)。✗ 的兩列(冒充節點、快取窗口內改用別張 QR)只在使用者確認後
發生,出路要等 §9 的兩個 checklist 項目(還原 UI、replay 讀 FP)。→ **本版不接 replay**。

## 5. 沒接上的 §5.2(F4)

未實作:psk_replay 握手、`claim/replay`、9 之後 3 × 15 s 自動重試、13 的 ≤ 5 次自限、每 device_id 每小時 ≤ 3 次、清單上的「需恢復」
節點、「已忘記」區(列出 / 恢復 / 手動忘記)、重燒時由使用者指認舊紀錄。app 的因應:有效紀錄與未決 pending 只會被複製保留、不會被刪;
R2 的時間欄位讓日後的 replay 分得出殘留與進行中。

## 6. 生命週期

| 路徑 | 影響 |
|---|---|
| 安裝 / 首次 | 無紀錄 → 不觸發 |
| 啟動 / 重啟 | 不在啟動時清任何紀錄(R2);`store_has_records` 把 `forgotten-node`、`forgotten-pending` 都算紀錄(254-app-s1 §4.1 金鑰不刪) |
| 當掉 | 見狀態表;`copy_aside` 當掉只留 temp(R8,`sweep_temps` 清) |
| 升級(安裝前檢查)| 306bcf8 的 `move_aside` 會把**有效**紀錄 rename 走。安裝本版前在測試機(S20)列一次 `forgotten-node/`(`adb shell run-as <dev applicationId> ls files/records/forgotten-node`):有東西 → 先手動搬回 `node/<id>`(世代號在檔頭,AAD 仍符)。⚠️ 依協調者:S20 現在裝的是 #328 的 5c7b9fe APK,從沒有 move_aside → 預期為空;仍要列一次確認 |
| 降級到 4967f5d | 舊版沒有不覆寫的保護:N′ + P 殘留會被舊版的認領直接覆寫;`forgotten-*` 與新的時間欄位被忽略(讀 key 的程式不受影響,F12) |
| 重裝 / 清除資料 / 備份 | n/a:紀錄排除於備份與裝置轉移、Keystore 金鑰不隨行(254-app-s1 §4)→ 清除或重裝後所有紀錄(含 forgotten)都失效,與本變更無關 |
| 斷電 / 斷線 | = 當掉 / NX 失敗各列 |
| 平台 | Android(本版) |

## 7. 安全

- 資產:K、root_password、owner_tag_key(紀錄內,AES-GCM 封裝)。複本是原檔位元組,仍封裝、AAD 綁原路徑(F8),不新增明文。
- 新輸入:無新的外部輸入。錯貼紙 / 他人的 QR(同 device_id、錯 K)只能讓手機多一份 pending;有效 node 紀錄在 CLAIMED 前不會被動(R1)。
  確認之後,被取代的紀錄**只是留在手機上,app 不再使用、也無法還原**(§4 的 ✗ 列)—— 防線是對話框(R4 / R7)的確認條件,不是機制。
- 權限:app 私有目錄,單一寫者;`copy_aside` 不覆寫任何檔(R8)。
- log:不印紀錄內容、K;只印末 4 碼(既有)。
- fail-closed:讀不了 → 不認領(R5);R4 ① 失敗 → 不送 begin。唯一的 fail-open:R1 ① 失敗照寫新紀錄(理由見 R1)。

## 8. 測試(每條附負對照;負對照都是**改動本版新程式**)

| 測試 | 層 | 證明 | 負對照 |
|---|---|---|---|
| T1 claim_target 讀兩條路徑 | Rust | N 可讀 + P 壞 → Err | 改成只讀 node → 回 Node → FAIL |
| T2 copy_aside | Rust(**WSL ext4 的 /tmp**,不是 /mnt/c) | 原檔仍在且不變、複本位元組相同(含世代號)、n 遞增、目標存在不覆寫;目標目錄 chmod 000 → Err | 改成 rename(搬走)→「原檔仍在」FAIL(有鑑別力的那一條);改成 `exists()` → chmod 情況不報錯 → FAIL |
| T3 步驟處理抽出成 `ClaimRecords`(Dart,注入 store 函式)記錄呼叫順序 | Dart 單元 | 重新認領:PersistPending 不碰 node;CLAIMED = copy(node) → write(node) → remove(pending) | 把 copy + write(node) 移到 PersistPending → FAIL;拿掉 copy → FAIL |
| T4 快取窗口 | Dart 單元(T3 + 假 store) | N 存在、確認、PersistPending、finish 9 → node 仍在 | 同 T3 的「移到 PersistPending」突變 → FAIL |
| T5 不同 K 的 pending(含 N + P(K1)) | Dart 單元 + widget | PersistPending:copy(pending) → write(pending K2);claim_target = Node 時也一樣;R7 帶 pending 那句 | 拿掉 copy → FAIL;改成看 claim_target 決定 → N + P 情況 FAIL |
| T6 讀不了 | Dart widget | open 丟例外 → 「讀不到…」 | 把 open 錯誤歸為「K 不同」→ FAIL |
| T7 CLAIMED 後 `_qr` 清掉 | Dart widget | 「認領」按鈕停用 | 不清 → FAIL |
| T8 對話框文字 | Dart widget | R4 / R7 字串(含「只有在你剛把這台節點重置…」「只有在你確定這張 QR 碼才是對的…」) | 舊字串 → FAIL |
| T9 `store_has_records` | Rust | 只有 `forgotten-pending/` → true | 拿掉該 kind → FAIL |
| T10 時間欄位 | Rust | pending key 8、node key 9 有寫;舊格式(無 key 8 / 9)仍讀得開、能登入 | 讀取改成要求 key 9 → 舊紀錄 FAIL |
| T11 R1 ① 失敗 | Dart 單元(T3,假 store 的 copy 丟例外) | write(node) 與 remove(pending) 仍被呼叫、log 有「舊紀錄沒有保留」 | 改成 copy 失敗就停 → FAIL |
| T12 R4 ① 失敗 | Dart 單元 | copy(pending) 丟例外 → 沒有 write(pending)、沒有 pending_persisted | 改成照寫 → FAIL |

既有:claim_target_test 的 6 個依 R4 / R5 / R7 調整預期;全套 = `test-all.sh`(WSL)+ Windows `flutter test` + `testDevDebugUnitTest` + dev APK。

## 9. 最小變更(相對 306bcf8)與 #254 checklist

- **移除**:`store_forget_node` 與它在 PersistPending 的呼叫;`Store::move_aside`(與其測試);「用的是另一張 QR 碼 → 不認領」的拒絕;
  對話框的「已重燒」與「可恢復」;254-app-s1 §5.1 的 306bcf8 實作註記(改指向本文件)。
- **新增**:`Store::copy_aside` + bridge 函式;claim_target 兩條都讀;R4 對話框與只看磁碟的 PersistPending 複製;CLAIMED 步驟的 copy
  (失敗照寫);`ClaimRecords` 抽出(把 claim.dart 現有的 seal / write / remove 移進可測的類別);`_qr = null`;pending key 8、node key 9;
  `forgotten-pending` 進 RECORD_KINDS。
- **改寫(文件)**:254-app-s1 §5.1 的「node 紀錄與 pending 同時存在 → 刪 pending」→ R2。
- 不做:replay、還原 UI、忘記 pending 的 UI、開發用長按。
- **#254 checklist(由協調者記錄)**:
  - [ ] 「已忘記」還原 UI(`forgotten-node/`、`forgotten-pending/` 搬回原路徑)—— 解 §4 冒充節點列的 ✗
  - [ ] replay 也從 `forgotten-pending/` 取候選 —— 解 §4「快取窗口內改用別張 QR」列的 ✗
  - [ ] nodes.dart:431 開發用長按 `_forget` 直接刪 `node/<id>`(不經 copy_aside);本版不變

## 附錄 R1 — 第 1 輪處理對照

| 意見 | 處理 |
|---|---|
| A-M1 CLAIMED ① 失敗未定義 | R1:照寫 + log,理由(F13);T11 |
| B-M1 / A-m2 N + P(K1) + K2 被無複製覆寫 | R4 只看磁碟;R7 帶 pending 句;T5 |
| B-M2「保留」沒有出路 | §4 兩列標 ✗ 與原因;R4 / R7 確認條件;§0 / §7 改寫;§9 checklist |
| A-m1 沒有時間欄位 | R2:pending key 8、node key 9 與區分規則;T10 |
| A-m3 / B-m1 copy 當掉留半檔、順序 | R8 temp + rename + `symlink_metadata`;R1 / R4 的 ① 失敗分別寫清 |
| A-m4 複本何時打得開 | R8 末段;T2 位元組相同 |
| A-m5 T2 環境與鑑別點 | T2:WSL /tmp、「原檔仍在」 |
| B-m2 升級前檢查 | §6 升級列 |
| B-m3 降級 | §6 降級列 |
| B-m4 重裝 / 清除 / 備份 | §6 n/a 列 |
| T1 / T4 負對照要改新程式 | §8 全部改為新程式的突變 |
| 開發用長按 `_forget` | §9 checklist |
