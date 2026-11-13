# #254 app — 已持有的 device_id 再被認領(254-app-s1 §5.1 補充設計)

狀態:**v1(審查中)**。範圍:254-app-s1.md v8.5.1 §5.1「已有 node 紀錄或 pending 的 device_id 再被掃到 → 不覆寫;先確認」的
落實方式。起因:code review r1(4967f5d..306bcf8,A / B 皆 APPROVE-WITH-CHANGES)指出 306bcf8 的「移到一旁」機制本身沒有設計
(A-M1、A-M2、B-M1 三個 MAJOR + 6 個 MINOR)。本文件取代 306bcf8 在 §5.1 寫的實作註記;程式在本文件通過審查後才改。

## 0. 一句話

**有效的紀錄在新認領 CLAIMED 之前一律不動;被取代的紀錄在取代的那一刻先「複製」到 `forgotten-*/`,再由原子寫入蓋過去。**
正確的 QR 永遠有路可走(確認後重新認領),不需要 replay。

## 1. 事實(附證據)

| # | 事實 | 證據 |
|---|---|---|
| F1 | provd 的狀態快取每 4 s 輪詢、ctl 最多等 10 s;`invalidate()` 只設 needOwners / needPSK,不碰 state → CLAIMED 之後 4–14 s 內 STATUS 仍說 unclaimed、NX 仍成功 | `feed/batman-prov/src/provd/server.go:21-22`(PollEvery / CtlWait)、`:618-622`(invalidate)、`:561`(stateOK 窗口) |
| F2 | K 只在 claim/begin 之後(CheckMac response)才用到;NX 與 node_cert 驗證不看 K → 錯的 K 也會走到 PersistPending | `app/rust/batman-proto/src/claimflow.rs:5-8`(步驟順序)、`:171`(PersistPending 在 cert 之後、begin 之前) |
| F3 | finish 碼對應:3 → BeginAgain、4 → AppBug、9 → TryReplay、13 → Committed、7 / 其他 / 無回應 → Unknown | `app/rust/batman-proto/src/flow.rs:9-15, 54-68` |
| F4 | app 沒有接 §5.2 replay:`grep -rn replay app/lib` 為空;bridge 沒有 replay API(batman-proto 有 `replayflow.rs`,未經 bridge) | grep 輸出(2026-11-13) |
| F5 | 清單只列 `node/`(`list_nodes` = `node/` 底下的檔名);pending 與 `forgotten-*` 不顯示;沒有忘記 pending、也沒有還原的 UI | `app/rust/bridge/src/api/owner.rs:50-53`;`app/lib/nodes.dart:1546-1553` |
| F6 | `node/<id>` 的寫者只有 claim 頁(Claimed 步驟);移除者只有 nodes.dart 開發用長按 `_forget`(`storeRemove`,刪除);owner session 只寫 `net/`(CAS) | `app/lib/claim.dart`(Claimed 步驟)、`app/lib/nodes.dart:431, 238, 702` |
| F7 | 「node + pending 並存 → 刪 pending」(§5.1)在 app **沒有實作**:沒有任何程式在啟動或列清單時刪 pending | grep `claim-pending` in app/lib:只有 claim.dart 讀 |
| F8 | 紀錄的 AAD = 最終路徑 + 世代號 → 複製到別的路徑的紀錄要搬回原路徑才打得開 | `app/rust/batman-proto/src/store.rs`(`aad`) |
| F9 | file 後端重燒 = 新 DAC、新 device_id → 同一 device_id 再出現只可能是**重置**回 Unclaimed(p5 identity 還原,boot.go:185-191),不是重燒 | 254-app-s1 §5.3 末行;`feed/batman-prov/src/boot/boot.go:185-191` |
| F10 | ⚠️ 未驗證:Android 的 untrusted_app 能否對 app_data_file 做 `link()`(印象中 SELinux 禁止)→ 不用 hard link | 未查證 → 設計不依賴它 |

## 2. 擁有權(每個資源一個寫者)

所有檔案的唯一寫者仍是 Rust 紀錄儲存層(§3);下表是「哪一步要它寫」。

| 資源 | 寫 / 蓋過 | 刪 | 複製到一旁 | 讀者 |
|---|---|---|---|---|
| `node/<id>` | claim 頁,**只在 CLAIMED 步驟**(Store::write 原子替換) | nodes.dart 開發用長按(既有,不變) | claim 頁,CLAIMED 步驟、寫入之前(若已有) | nodes.dart(登入)、claim_target |
| `claim-pending/<id>` | claim 頁,PersistPending 步驟(NX + cert 通過後) | claim 頁,CLAIMED 步驟最後一步(既有) | claim 頁,PersistPending、寫入之前(若已有且 K 不同) | claim_target、claim 頁(比對 K) |
| `forgotten-node/<id>-<n>`、`forgotten-pending/<id>-<n>` | 只由 `copy_aside` 新建(create_new,不覆寫任何檔) | 無(本版沒有任何刪除路徑) | — | 無(本版只保留;還原 UI 不在本版) |

## 3. 規則(取代 306bcf8 的做法)

- **R1 node 紀錄**:按「重新認領」確認後,PersistPending 照常寫 `claim-pending/<id>`(node 紀錄不動,兩者並存);**CLAIMED 時**依序:
  ① `copy_aside(node/<id> → forgotten-node/<id>-<n>)`(新檔 create_new + fsync + 目錄 fsync)② Store::write 新的 `node/<id>`
  (原子替換)③ 刪 pending。任何時刻 `node/<id>` 都存在。
- **R2 node + pending 並存**:**改寫 §5.1「以 node 紀錄為準,刪 pending」為「以 node 紀錄為準(清單、登入用它),pending 保留不自動刪」**。
  理由:並存現在有兩種來源 —— 舊的收尾殘留(無害,一個檔)與進行中的重新認領(刪了就丟掉可能已提交的那次);app 分不出來,
  且 F7:舊規則本來就沒實作,改寫不刪任何程式。殘留在下一次該 id 的 CLAIMED ③ 被清掉。
- **R3 pending,同一張 QR(id 與 K 相同)**:照常認領 = §5.2-1(既有恢復路徑:BeginAgain / 結果未知的訊息就是叫使用者再按「認領」);
  PersistPending 以同一 K 覆寫。不問。
- **R4 pending,不同 K**:**先問**(§5.1「先確認」;A-m3):「手機裡有這台節點一次沒完成的認領,用的是另一張 QR 碼。要改用這張
  QR 碼重新認領嗎?舊的認領紀錄會保留在手機上(不會刪除)。」確認 → PersistPending 時 ① `copy_aside(claim-pending/<id> →
  forgotten-pending/<id>-<n>)` ② 寫新 pending(原子替換)。取消 → 什麼都不寫。選這個而不是「拒絕」(B-M1):錯貼紙的 pending
  會永遠擋住正確 QR,而 app 沒有忘記 pending 的 UI(F5)。選「PersistPending 才換」而不是「確認時就換」:沒連到節點就什麼都不變。
- **R5 讀不了**(任一紀錄頭壞 / 未知版本,或 pending 的 Keystore `open` 失敗):不認領,訊息「讀不到手機裡這台節點的紀錄」
  (不再說成「另一張 QR」;A-m1 / B-m3)。claim_target 兩個路徑**都**讀(現在 node 讀得到就不看 pending → 改)。出路:無(紀錄或
  Keystore 壞 = §4 的「節點需重燒回收」),明寫。
- **R6 CLAIMED 後清掉 `_qr`**:認領成功即忘記這次讀到的 QR(按鈕回到停用),要再認領須重新掃描(A-M1 的次要點)。
- **R7 對話框文字**(A-m2,F9):「這台節點已在你的清單裡。若節點已重置回未認領,可以重新認領:舊紀錄會保留在手機上(不會刪除),
  不再顯示在清單裡。要重新認領嗎?」
- **R8 `copy_aside`**(取代 `move_aside`;B-m1):目標用 `OpenOptions::create_new` 開(已存在 → 換下一個 n;其他錯誤 → Err,
  不覆寫任何檔),寫入原檔位元組、`sync_all`、目錄 `sync_all`。不用 rename、不用 hard link(F10)。

## 4. 狀態表

記號:N = 有效 node 紀錄、N′ = 舊 node 紀錄(節點已重置,舊憑證已失效)、P(K) = pending、FN / FP = forgotten-node / -pending 的複本。
「出路」= 使用者不重燒能否回到可用狀態。

| 手機持有 | QR | 結果 | 磁碟之後 | 使用者看到 | 出路 |
|---|---|---|---|---|---|
| 無 | — | 找不到 / NX 解不開 / cert 拒 | 無 | 失敗訊息 | 再按 |
| 無 | — | PersistPending 後 begin 拒、finish 3/4/7/9/13、無回應、當掉 | P | 失敗訊息(既有) | 同一 QR 再按 = R3(9 / 13 且已提交的情況要 replay,F4:**既有缺口,與本變更無關**) |
| 無 | — | CLAIMED | N | 認領成功 | ✓ |
| N | 任 | 取消 | N | 「沒有重新認領」 | ✓ |
| N | 任 | 確認,找不到 / NX / cert 失敗 | N | 失敗訊息 | ✓(N 沒動) |
| N(有效)| 任 | 確認,**快取窗口內**(F1):NX、cert 過 → P 寫入 → finish 9 | N + P | 「認領被拒絕…」 | ✓ **N 仍在清單、可登入**(A-M1 的修法:R1 不在 PersistPending 動 N);P 為殘留,R2 |
| N′(已重置)| 同 K | 確認,PersistPending 後 3/4/7/9/13/無回應/當掉 | N′ + P | 失敗訊息 | 同一 QR 再按 → 對話框 → 確認 → R3 覆寫 P 再試;已提交(13 / 快取)的情況要 replay(F4,同第二列的既有缺口) |
| N′ | 任 | 確認,CLAIMED | 新 N + FN(N′) | 認領成功 | ✓ |
| N′ | 任 | CLAIMED 中當掉:①後 | N′ + P + FN | (下次)清單有 N′,登入失敗 | 憑證只在記憶體 → 要 replay(F4)。與「finish 回了、node 還沒寫就當掉」同一個既有窗口(毫秒級),不是新的 |
| N′ | 任 | CLAIMED 中當掉:②後 | 新 N + P + FN | 正常 | ✓;P 殘留(R2),下次 CLAIMED 清 |
| P(K) | 同 K | 任 | 同「無」各列(P 以同 K 覆寫) | — | 同上 |
| P(K1) | K2 | 取消 | P(K1) | 「沒有重新認領」 | ✓ |
| P(K1),K1 錯貼紙 | K2 正確 | 確認 → NX / cert 過 → FP(K1) + P(K2) → CLAIMED | N + FP(K1) | 認領成功 | ✓ **(B-M1 的修法)** |
| P(K1) | K2 | 確認,NX / cert 失敗 | P(K1) | 失敗訊息 | ✓(沒動) |
| P(K1),K1 那次其實已提交 | K2 | 節點已認領 → PSK 模式 → NX 解不開 | P(K1) | 失敗訊息 | 要 replay(F4,既有);P(K1) 沒被動 |
| P(K1),快取窗口內 | K2 | NX 過 → FP(K1) + P(K2) → finish 9 | P(K2) + FP(K1) | 「認領被拒絕…」 | 要 replay;K1 那次的資料完整保留在 FP(未刪),replay 接上時要能從 FP 取 |
| N + P | 任 | 照 N 各列(claim_target 回 Node) | — | 對話框 | 同 N |
| 讀不了 | 任 | 不認領 | 不變 | 「讀不到…」 | ✗(§4:紀錄 / Keystore 壞 = 重燒回收;既有) |

結論:本變更沒有新增任何「必須 replay 才能回來」的狀態;需要 replay 的列都是 F4 的既有缺口(認領已提交但沒拿到憑證)。
→ **本版不接 replay**。

## 5. 沒接上的 §5.2(F4)

未實作:psk_replay 握手、`claim/replay`、9 之後 3 × 15 s 自動重試、13 的 ≤ 5 次自限、每 device_id 每小時 ≤ 3 次、清單上的「需恢復」
節點、「已忘記」區(列出 / 恢復 / 手動忘記)、重燒時由使用者指認舊紀錄。app 的因應:R1–R4 保證有效紀錄與未決 pending 不會被
刪掉(只會被複製保留),所以日後接上 replay 時資料都在(包含 `forgotten-pending/`)。

## 6. 生命週期

| 路徑 | 影響 |
|---|---|
| 安裝 / 首次 | 無紀錄 → R 規則不觸發 |
| 啟動 / 重啟 | 不在啟動時清任何紀錄(R2);`store_has_records` 把 `forgotten-node` 與 `forgotten-pending` 都算紀錄(§4.1 金鑰不刪) |
| 當掉 | 見狀態表各「當掉」列;`copy_aside` 留下半個檔 = create_new 後未寫完 → 檔頭不完整的複本,不在清單、不影響原檔(⚠️ 下次 copy 換 n) |
| 升級 / 降級 | 舊版 app 不認得 `forgotten-*` → 忽略(只看 `node/` 與 `claim-pending/`);舊版的 `store_has_records` 不算 `forgotten-*` → 只在**只剩 forgotten 紀錄且安裝標記遺失**時可能重產金鑰(極窄,記為缺口) |
| 斷電 / 斷線 | = 當掉 / NX 失敗各列 |
| 平台 | Android(本版);iOS 不在範圍 |

## 7. 安全

- 資產:K、root_password、owner_tag_key(紀錄內,AES-GCM 封裝)。複本是原檔位元組,仍封裝、AAD 綁原路徑(F8),不新增明文。
- 新輸入:無新的外部輸入;QR 解析不變。錯貼紙 / 他人的 QR(同 device_id、錯 K)只能讓手機多一份 pending,有效 node 紀錄不會被動
  (R1),正確的 pending 只會被複製保留(R4)。
- 權限:app 私有目錄,單一寫者;`copy_aside` 用 create_new,不覆寫任何檔(R8)。
- log:不印紀錄內容、K;只印末 4 碼(既有)。
- fail-closed:讀不了 → 不認領(R5)。

## 8. 測試(每條都附負對照)

| 測試 | 層 | 證明 | 負對照(改掉什麼 → FAIL) |
|---|---|---|---|
| T1 claim_target 讀兩條路徑 | Rust | N 可讀 + P 壞 → Err | 只讀 node(306bcf8)→ 回 Node |
| T2 copy_aside | Rust | 原檔不動、複本位元組相同、n 遞增、目標已存在不覆寫;目錄不可讀(chmod 000)→ Err 且原檔與既有複本不變 | 用 `exists()` + rename(306bcf8 的 move_aside)→ 原檔消失 / 權限錯誤時覆寫 |
| T3 步驟處理抽出成 `ClaimRecords`(Dart,注入 store 函式),逐步記錄呼叫順序 | Dart 單元 | 重新認領:PersistPending 只寫 pending、不碰 node;CLAIMED = copy(node) → write(node) → remove(pending) | 在 PersistPending 移 node(306bcf8)→ FAIL;拿掉 copy → FAIL(A-M2) |
| T4 快取窗口 | Dart 單元(T3 的 handler + 假 store) | N 存在、確認、PersistPending、finish 9 → `listNodes` 仍含該 id | 306bcf8 → 清單沒了 |
| T5 錯貼紙 | Dart widget + T3 | P(K1) + QR K2:問 → 確認 → PersistPending 時 copy(pending) → write(pending K2);取消 → 無呼叫 | 306bcf8 → 直接拒絕(無對話框) |
| T6 讀不了 | Dart widget | open 丟例外 → 「讀不到…」,不是「另一張 QR」 | 306bcf8 → 顯示「另一張 QR」 |
| T7 CLAIMED 後 `_qr` 清掉 | Dart widget(T3 handler 回 claimed) | 「認領」按鈕停用 | 不清 → 按鈕仍可按 |
| T8 對話框文字 | Dart widget | R7 字串,不含「重燒」 | 舊字串 → FAIL |
| T9 `store_has_records` | Rust | 只有 `forgotten-pending/` → true | 拿掉該 kind → FAIL |

既有:claim_target_test 的 6 個依 R4 / R5 / R7 調整預期;全套 = `test-all.sh`(WSL)+ Windows `flutter test` + `testDevDebugUnitTest`
+ dev APK。

## 9. 最小變更(相對 306bcf8)

- **移除**:`store_forget_node` 與它在 PersistPending 的呼叫;`Store::move_aside`(與其測試);「用的是另一張 QR 碼 → 不認領」的拒絕;
  對話框的「已重燒」;254-app-s1 §5.1 的 306bcf8 實作註記(改指向本文件)。
- **新增**:`Store::copy_aside`;bridge `store_copy_aside(dir, rel, kind)`(或兩個具名函式);claim_target 兩條都讀;R4 對話框;
  CLAIMED 步驟的 copy;`ClaimRecords` 抽出(只是把 claim.dart 現有的 seal / write / remove 移進可測的類別,行為不變外加 R1 / R4);
  `_qr = null`;`forgotten-pending` 進 RECORD_KINDS。
- **改寫(文件)**:254-app-s1 §5.1 的「node 紀錄與 pending 同時存在 → 刪 pending」→ R2。
- 不做:replay、還原 UI、忘記 pending 的 UI、開發用長按改成複製。
