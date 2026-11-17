# #329 PR 5 計畫 v1 — 審查 B（安全與 fail-safe）

審查對象：`docs/design/329-pr5-plan.md` v1（worktree `C:/src/Batman-329pr5`，main 2e18de6；工作樹另有未提交的 `QrScanActivity.kt` 解析度修改）。
範圍：只審 §0「本 PR 新做的」1–9 與 §2–§7；§0 的行為基準只拿來對照搬移是否忠實。
方法：逐項對 source（Read / Grep），沒有執行任何程式。標 ⚠️ 的是推算、沒有實測。

## 先講結論

- 碼本身不是秘密，這是整份安全分析的前提，我先查證了。遠端邀請不含秘密（219-protocol.md §7.6 表格「遠端」列）。Rust 沒有任何地方產生 `in_person`，也沒有 `sae_password`（grep `in_person|InPerson|sae_password` 在 `batman-proto/src` 與 `bridge/src` 都是 0 筆）。申請碼是公開資料。同意碼裡的 `net_secrets` 加密給節點，`member_secrets` 加密給隊員的 `owner_enc_pub`（§7.4、§7.6）。所以剪貼簿和截圖外洩的後果是隱私（網路名、人名、net_id），不會洩漏金鑰。完整性靠 SAS。這和計畫 §5 一致。
- 這次真正的秘密有三樣：`z`、mnet 明文裡的 `net_root`、管理者簽章金鑰。計畫對這三樣的處理大致照搬舊程式，沒有問題，只有細節要補（m5）。
- 計畫裡有兩個新部分在現場會出錯：
  - 8.5「網路換新密碼」那一行的資料來源不存在（M1）。結果是隊長照新 UI 走完移除，自己的節點卻沒換密碼，被移除的人仍然連得上。
  - 「三種碼都有 QR」（D1）的證據只涵蓋一人網路的同意碼。同意碼會隨隊員人數變大，超出 R-8 量過的版本（M2）。

---

## MAJOR

### M1. 8.5「網路換新密碼」那一行依賴一個不存在的 session，所以移除後隊長的節點不會換密碼

**情境**：隊長在 8.3 移除一位隊員，在 8.4 把更新包交給每位留下的隊員。接著照 8.4 最後一列「把新密碼送到我的節點」回到節點頁，要找「網路換新密碼」那一行（plan §2.6 第 10 點，「→ 節點頁的 8.5 那一行」）。這一行只在 `update_hint` 有內容時出現（§2.7）。

**證據**：
- §2.7 寫：「它要先讀狀態頁，所以用節點頁現有那一輪的 session；沒有那一輪時不顯示，不另外登入」。
- 節點頁的「那一輪」是 NodeLink 的 prober 在讀，但 prober 的 session 在每次嘗試結束時就 dispose：
  - `prober.dart:1-2` 的註解：「the Rust session is disposed when the attempt ends」；
  - 程式碼在 `prober.dart:205-209`（`s?.dispose()`）。
- 那一輪讀的是 `statusView(hasNet: false, hasMnet: false)`（`prober.dart:123`），根本沒讀 net / mnet 紀錄，也沒有呼叫 `update_hint`。
- `update_hint` 是 `OwnerSession` 的方法，用的是「同一個 session 上次讀的狀態頁」（`owner.rs:1099-1101`、P14）。節點頁沒有任何活著的 OwnerSession（`node_page.dart` 沒有 acquire / OpSession / statusPage）。
- §2.3 又把 `updateHint` 放在 `OwnerConsole`（需要佔用與登入），寫「session 沒讀過狀態頁時先 `statusPage`」。這和 §2.7 的「不另外登入」互相矛盾。

**後果**：照計畫實作，這一行永遠不出現：
- 隊長的節點收不到新密碼；
- 舊密碼在隊長節點上繼續有效；
- **被移除的人仍能連上隊長的節點**。

UI 看起來移除已完成，實際上這是 fail-open。隊員端 8.5 的入口也是同一行，所以隊員也無法從新 UI 匯入後送出。舊控制台在 PR 6 之前還留著，可以繞過去，但新 UI 的使用者不會知道。

**修法**：
- 明定 8.5 那一行的來源。建議做法：節點頁的「網路」分組在這台已在某個 net / mnet 時，固定顯示「網路換新密碼」。按下後用 `OpSession.once` 登入，依序跑 `statusPage` → `updateHint` → 顯示那一行與按鈕 → `sendUpdateFor`。
- 也可以讓 prober 在讀取時一併算 hint。這要改 PR 3 的讀取規則（§4.3.3-9：讀取不碰紀錄），比較大。
- 不管選哪一種，都要刪掉 §2.7「沒有那一輪時不顯示」這句。
- 測試：widget 流程跑完移除 → 8.4 → 節點頁，斷言看得到這一行，而且按下會送出 `sendUpdateFor`。負對照：拿掉這一行的來源 → FAIL。

### M2. D1「三種碼都有 QR」的證據只到一人網路的同意碼；同意碼會隨人數變大，超出 R-8 量過的版本

**情境**：隊伍已有 2 位以上隊員，隊長當面邀請第 3 位。7.6 顯示的同意碼 QR 版本超過 27，S20 掃不到，或者掃很久。另一種結果是超過 4096 字元，直接顯示「無法顯示 QR」。當面時兩人只能改用通訊軟體傳文字。

**證據**：
- 同意碼裡帶整份 `member_list` 的 COSE_Sign1（`approve.rs:312-319`，key 2 `members`）。219 §7.5 的 member_list 每位成員一筆 `{dac_pub_hash 32 B, ecdh_pub 65, name, owner_pub 65, (owner_enc 65)}`，另有 `removed`、`used_invites`、`revoked_invites` 三個只增不減的列表。
- F36 的 1041 位元組來自 `gen.py:332-335`，`MEMBERS_PAYLOAD` 裡只有 **1 位**成員。
- ⚠️ 推算（沒有實測）：每多一位隊員約多 230–250 B，也就是約 470–500 個十六進位字元。這樣算下來：
  - 第 2 位以後的同意碼就超過 T-Q1 的「≤ 27」；
  - 約 7–8 位以後會超過 4096 字元，`qrMatrix` 依計畫會回錯誤。
- R-8（P15 / P16）只量了 v16 / v26 / v27。
- T-Q1 只用測試向量，所以「版本 ≤ 27」在 CI 永遠綠，給的是假的信心。

**後果**：
- 對中型以上的隊伍，D1「三種都過了」不成立。
- 上層 §5.7:773 原本的規則「掃不到的那一種只留複製文字」被 D1 移掉了，但 D1 的前提只對一人網路成立。
- 這不是金鑰外洩，fallback 也是 fail-safe（還可以複製）。但它是現場一定會遇到的錯誤體驗：畫面顯示一個掃不到的 QR。

**修法**（擇一，或兩者都做）：
- T-Q1 加一組 N 位成員（例如 2、5、8 位）的同意碼向量，記下實際的版本與字元數。R-8 再補量 v30 / v35 / v40。
- CodeView 加門檻：點陣版本大於量測過的上限時，不畫 QR，改顯示「這份碼太大，請用『複製文字』」。上限值寫成常數，並附 R-8 的出處。
- 不論選哪個，D1 的文字都要改成「到 vN 為止有 QR」。

---

## MINOR

### m1. 7.7「確認碼不同」沒有作廢任何東西，但上層情境 2 寫「兩邊都作廢重來」；這個偏離沒有列在 §4

- **證據**：
  - `329-app-uiux.md:803` 情境 2 的異常欄寫「確認碼不同 → 7.7，兩邊都作廢重來」。
  - plan 7.7 寫「不寫任何東西」。
  - Rust 沒有撤銷邀請的入口：`grep revoke` 只找到 forget 相關的註解；§0 又規定 Rust 不改。
  - 所以 7.3 時 PersistNet 寫入的那個 invite 還是「已發出、未使用」，之後任何人拿它來的申請都會走到 7.5。
- **情境**：確認碼不同，表示通訊軟體裡有人拿到了邀請並送了自己的申請，也就是中間人。隊長按「重新邀請」，很可能以為舊的那張已經失效。之後攻擊者再送一次舊邀請的申請，只剩 SAS 這一道人為關卡。SAS 這一道和以前一樣，所以這不是新的漏洞；問題在畫面和設計文件可能讓人以為舊邀請已經失效。
- **修法**：
  - 在 §4 加一條 D6：「舊邀請不作廢，因為 Rust 沒有撤銷入口；SAS 是唯一關卡」。
  - 7.7 的文字照實寫，例如：「剛才那張邀請還是有效的；有人可能拿到了它。之後收到這張邀請的申請，一律要用電話核對確認碼」。
  - 撤銷入口寫進 #329 checklist 一行。

### m2. CodeView 的「設不了 FLAG_SECURE」fallback 需要改 `SecureScreen` 本身，但計畫把 SecureScreen 列為不改的基準

- **證據**：
  - `secure_screen.dart:42-46`：`_on == false` 時固定顯示一句話，child 完全不建。
  - plan §2.2 寫「整頁包在 SecureScreen 裡」，又要求 fallback 時「仍提供『複製文字』」。照現有 API，複製按鈕在 child 裡面，fallback 時就不會出現。
  - 要做到計畫說的行為，只有兩條路：
    - SecureScreen 加 `fallback` 參數；
    - 複製按鈕放在 SecureScreen 外面，但這樣 `_on == null`（還在等 Android 回答）時複製按鈕也會出現。
- **風險**：手機 Wi-Fi 密碼頁也用 SecureScreen（`329-app-uiux.md:874`：「Wi-Fi 密碼欄不能切換成顯示」）。如果 fallback 改成預設顯示東西，或者共用同一個參數，那一頁也可能被打開。
- **修法**：
  - 明寫成 `SecureScreen({required child, Widget? fallback})`，預設 `null` 時行為不變；
  - `_on == null` 時什麼都不顯示，包括 fallback；
  - T-S1 加兩個負對照：(a) Wi-Fi 頁在 `set → false` 時仍不顯示密碼欄；(b) CodeView 在 `null` 狀態不顯示 QR 也不顯示複製按鈕。

### m3. 「清除剪貼簿」清不到鍵盤的剪貼簿紀錄，按鈕名稱會讓人以為已經清乾淨

- **證據**：
  - 舊做法是 `Clipboard.setData(ClipboardData(text: ''))`（`nodes.dart:728-732`），這只是放一個空的 clip 進去。
  - Samsung Keyboard 與 Gboard 都有自己的剪貼簿紀錄，Android 13+ 還有系統預覽浮層，`setData('')` 對它們都沒有作用。⚠️ 這是 Android 平台的已知行為，沒有在 S20 上實測。
  - repo 裡沒有用到 `ClipDescription.EXTRA_IS_SENSITIVE` 或 `clearPrimaryClip`（grep 0 筆）。
- **後果**：因為碼不是秘密，影響只有隱私。但按鈕是「清除」，使用者會以為已經清乾淨，這是對使用者的 overclaim。
- **修法**（任選，不必全做）：
  - 改用 Kotlin 的複製方法：Android 13+ 在 `ClipDescription` 設 `EXTRA_IS_SENSITIVE`（不出預覽，Gboard 不記），清除時用 `clearPrimaryClip()`（API 28+）；
  - 或者把文字改成「清除剪貼簿（鍵盤的剪貼簿紀錄要自己刪）」。
  - 再加一個測試：「貼上後清除」的負對照，拿掉清除 → FAIL。§6 第 2 步有列這項，但沒有寫負對照。

### m4. `RemoveTicks` 用 32 位元的 `fpr` 當鍵，舊的 `_copied` 用的是完整 `owner`

- **證據**：
  - `rekey.rs:20-23` 的註解：`fpr` 是 SHA-256(owner_pub) 的前 8 個十六進位字元，也就是 32 位元；
  - 舊程式 `nodes.dart:1494` 是 `_copied.add(who)`，`who = p.owner`，完整公鑰。
- **情境**：一個惡意隊員入隊前先磨自己的金鑰，2^32 次在一般電腦上做得到，讓 fpr 和另一位隊員相同。之後隊長勾他的「已交出」，另一位也跟著顯示已交出，8.1 頂端「還有 N 位沒交」就少算一位。隊長以為大家都拿到了，把新密碼送給自己的節點，那位真的沒拿到的隊員就斷線。
- 勾選不參與任何判斷（T15），所以只影響可用性。但改成用完整的鍵沒有成本。
- **修法**：鍵改成 `RecipientView.owner`，和舊程式一樣；T-R1 加一個「fpr 相同、owner 不同」的案例。

### m5. ECDH `z` 與明文紀錄：8.5 的歸零沒有寫明；`OfflineOp` 的回傳值不能帶 `OwnerStep`

- 7.10 寫了「`z` 在 `finally` 歸零（照 1035）」。8.5 只寫 `OfflineOp('匯入新密碼', ecdh + memberUpdateImport)`，沒有寫要先 `_ownCopy`、在 work 的 `finally` 裡歸零。舊程式有這兩步（`nodes.dart:1525`、`:1540`）。§6 第 7 步的「z 歸零」也要明確涵蓋 8.5。
- **歸零的位置**：一定要在 `work` 自己的 `finally` 裡，不能在 `OfflineOp.run` 回傳之後。理由有兩個：
  - `run` 可能 busy，或者把例外往外丟；
  - 頁面可能已經不在了。
- **回傳值**：`memberImportApproval` / `memberUpdateImport` 的 `OwnerStep.record` 是 **mnet 明文，含 `net_root`**（`member.rs:268-290`）。`OfflineReply<T>` 的 `T` 如果是 `OwnerStep`，頁面 state 就會一直留著明文。應該規定 work 只回傳顯示用的那一行（`st.detail`）與結果種類。
- **負對照**：沿用 nodes_zero_test 的做法，對 7.10 與 8.5 各跑一次，拿掉 `fillRange` → FAIL。

### m6. `OfflineOp` 引用的 420 s `pageGone` 上限並不存在

- **證據**：plan §2.4 的流程是 `hold()` → work → `release()`，並寫「照 §4.4 的 pageGone 規則：佔用撐到 work 結束，最多 420 s」。但 420 s 的計時只在 `Lease.pageGone()` 裡設（`lease.dart:84-94`），而 `OfflineOp.run` 拿不到頁面，也不會呼叫 `pageGone`。PR 4 的 `OpSession.once`（`op_session.dart:88-130`）和移除節點（`more_pages.dart:80-92`）也一樣沒有上限，所以這是照先例做，但計畫的文字是錯的。
- **後果**：如果 work 裡的平台呼叫不回來，例如 Keystore 卡住，佔用就永遠不放：
  - NodeLink 停止讀取；
  - 之後每個操作都顯示「另一個操作還在進行」。
  - ⚠️ `signAdmin` / `ecdh` / `seal` 都不需要使用者驗證（`KeyHandlers.kt`、`MainActivity.kt:131-141`；grep `UserAuthentication|BiometricPrompt` 0 筆），所以發生機率低。
- **修法**：把 §2.4 的那句改成「`OfflineOp` 沒有上限，與 `OpSession.once` 相同」。或者真的加一個 work 逾時，逾時後 `reg._revoke`，寫進 unsavedTodos。

### m7. 7.5 / 7.10 按下確認後如果 `OfflineOp` 回 busy，`SasConfirmView` 會卡在按鈕停用的狀態

- **證據**：`member_ui.dart:69-75` 按下後 `_pressed = true`，之後不會再恢復。舊程式的 onConfirm 一定會執行到 `pop`。新流程裡 busy 是正常會發生的回應（§3.2 `OfflineReply.busy`）。
- **後果**：只是 UX 問題。按鈕停用，畫面上也沒有說明，使用者只能返回、重新掃碼。
- **修法**：busy 或 failed 時 pop 回上一頁並顯示原因；或者明定 7.5 / 7.10 收到 busy 一律 pop。加一個 widget 測試。

### m8. `joinreqLostLine(saved:)` 的 `saved` 從哪裡來沒有定義

- **證據**：
  - 舊程式的 `_saved` 是「這次請求的任何一筆紀錄寫入成功」，包括 persistPend（`nodes.dart:102`、`:263`、`:223`）。
  - plan §2.3 寫 `_persistedRel` 只記 persistNet，而且不改（`owner_console.dart:290`）。
  - 計畫沒有說 joinreq 斷線時 `saved` 用什麼判斷。
- **後果**：如果實作者拿 `persistedRel != null` 當 `saved`，mpend 已經寫入時也會顯示「申請沒有存，請再按一次」。使用者再按一次會產生新的申請（`renewed`），SAS 跟著改變，但他可能已經把舊的申請傳出去了。
- **修法**：明定 `saved` 的來源，例如 `SendTrack.persisted()`，或在 ConsoleReply 加一個「這次寫了 persistPend」的旗標。加一個斷線測試：persistPend 之後斷線 → saved 文字；persistPend 之前斷線 → 沒存的文字。

### m9. 首頁「加入隊長的網路」在 field 版也會出現，PR 5 之後它會帶到 7.8 這個死路

- **證據**：
  - `home_logic.dart:95`：`NetRecords.none` 時第二個動作是 `joinTeam`；
  - `home_page.dart:300-301` 顯示這個動作時不看 devTrust；
  - plan §2.7 只對首頁待辦寫了「非 devTrust 不出現」。
- **後果**：field 版使用者照計畫會進到 7.8，掃完邀請後 Rust `dev_gate` 回「遠端邀請只限開發版」（`member.rs:17-23`、`:63-64`）。這是 fail-closed，但是一條死路。以前它帶到舊控制台，也一樣不能用。
- **修法**：非 devTrust 時隱藏 `joinTeam`，或者讓 7.8 一進來就顯示「這個版本還不能加入隊長的網路」。T-S5 要涵蓋首頁第 6 列。

### m10. 名字的記錄規則寫得模稜兩可

- **證據**：plan §5 寫「新程式不記碼、確認碼、`z`、名字以外的節點字串」。這句可以讀成「名字可以記」。
- **問題**：隊員的名字和網路名稱都是對方給的字串（joinreq 的 `name`、netcfg 的 `name`）。上層 §887 規定紀錄行只放時間、種類、後四碼；T-S4 只抓 32 個以上連續的十六進位字元，抓不到名字。
- **修法**：
  - 把那句改成「不記碼、確認碼、`z`、任何名字與節點字串」；
  - T-U6 / T-S4 的標記字串擴到 joinreq 的 `name`、`netPeople` 的名字、`mnetSummary` 的 `netName`，對 NodeLink 紀錄與 `BMAPP` 新增的行做搜尋。

### m11. 掃描器的解析度改動也影響 field 版的認領掃描，但 §6 / §7 沒有重測認領 QR

- **證據**：
  - `QrScanActivity` 是唯一的掃描器，認領也用它（`claim.dart:211`；類別註解寫「the preview shows K」）；
  - 工作樹 diff 讓所有掃描都改成 1280×960 起跳（實得 1440×1080）；
  - R-8 只量了三種邀請碼。
- **風險**：認領是 field 版唯一的掃描用途，也是第一次使用的必經路徑。
  - 每一格要配置的 `ByteArray` 從約 0.3 MB 變成約 1.5 MB（`QrDecode.kt` 的 `fromPlane`），解碼時間大約變成 4 倍。
  - 在較弱的手機上，`CLOSEST_HIGHER` 可能選到更高的解析度。
  - ⚠️ 這些影響都沒有量。
- **修法**：§7 加「認領貼紙 QR 在 S20 用新解析度掃 5 次」，記下秒數；並記錄 Preview 與 Analysis 實際拿到的解析度。程式註解寫「121-141 modules」，和 P16 的 81 / 121 / 125 不一致，順手更正。

### m12. （上層已定案，只記錄）SAS 頁包在 SecureScreen 裡，設不了 FLAG_SECURE 的手機會整個流程卡住

SAS 可以從公開的碼算出來，藏起來沒有安全上的好處。但上層 §8:874 已經定案，這裡不重審。只建議 7.5 / 7.9 / 7.10 在 fallback 時的文字要說明「這支手機不能用來核對確認碼，請改用另一支手機」，不要只顯示 SecureScreen 的預設句子。

---

## 逐項查證：沒有發現問題的部分

- **qrMatrix 輸入驗證**：Kotlin 再檢查一次 `[0-9A-F]{1,4096}`。輸入是 app 自己產生的，不是外部輸入。v40-L 英數容量 4296 > 4096，所以 4096 以內不會碰到 WriterException 以外的錯誤；計畫要記得把 WriterException 也對應到錯誤 `qr`。不記 log、不放 Intent，可接受。
- **掃描與貼上共用解析器**：成立。所有解析都經 `qr_object` → `from_hex`（`invite.rs:75-97`），它濾掉空白、接受大小寫；`approval_net_id` / `update_net_id` / `parse_invite` / `net_check_joinreq` 都走這條（`approve.rs:312-329`、`mupdate.rs:124`）。貼上會先 `trim`，掃描不會，但 `from_hex` 會濾空白，結果相同。T-Q2 的負對照合理。
  - 注意 `approval_net_id` 沒有 `dev_gate`（`member.rs:219-221`）。它只用來挑要讀哪個檔，下一步 `member_import_prepare` 有 gate，所以可以接受。這是基準。
- **devTrust 的三層**：
  - Rust：`dev_gate` 涵蓋 member / rekey 的寫入與解析入口（`member.rs:63`、`:85`、`:158`、`:168`、`:245`、`:279`、`:294`；`rekey.rs:110`、`:154`、`:255`、`:268`、`:313`、`:335`、`:397`、`:411`）；
  - Kotlin：`EcdhPeer.accept(devTrust)`（`EcdhPeer.kt:41-42`）；
  - Dart：新入口的 gate，除了 m9 之外，計畫都有寫。
- **OfflineOp 經 RecordWriter**：`RecordWriter._check` 要求 lease 有效，而且是 registry 目前的佔用者（`record_writer.dart:28-34`），fail-closed。拿不到佔用就回 busy，什麼都不做。寫入順序（hex 只在 PersistNet 之後交出）照 `op_step`。不連節點的寫入改成要佔用，是本 PR 的改善：舊的 `_runOp` 用的是 raw 佔用（`nodes.dart:747-756`）。
- **`InviteHolds`**：只放公開資料，不寫紀錄，不佔用也合理。
- **`RemoveTicks`**：除了 m4，只存在記憶體、不參與判斷，與 T15 一致。
- **NetIndex 的新欄位**：只記代號、名稱、後四碼。mnet 明文要解開，和 net 的做法一樣（`net_index.dart:160-166`），明文丟給 GC，不歸零，與 `prober.dart:2-4` 已接受的做法相同。
- **紀錄行**：NetIndex 只印 id 前 8 碼；OwnerConsole 的 rel 只印前 12 字元（`owner_console.dart:291`）；`OpSession` 只印型別（`op_session.dart:123`）。新加的 mnet / mpend 寫入走同一個步驟迴圈，沿用這些規則。
- **攻擊者角色**：
  - 遠端，在通訊軟體裡拿到碼：拿到邀請可以送申請，但被 SAS 擋，這是基準；
  - 同一支手機上的 app：剪貼簿只有隱私影響（m3）；換掉剪貼簿內容也會被 SAS 擋；截圖有 FLAG_SECURE 擋；
  - 惡意隊員：m4；名字是對方給的字串（m10）；
  - 手機被拿走：mnet / mpend 紀錄是 Keystore 封裝的；InviteHolds 是公開資料。

## 負對照檢查

§5 列的四個負對照（SecureScreen、Rust 解析、佔用、gate）都成立。還缺這些：
- M1：拿掉 8.5 那一行的來源 → FAIL；
- M2：N 位成員的同意碼向量；
- m2：Wi-Fi 頁的 fallback；
- m3：拿掉「貼上後清除」 → FAIL；
- m5：8.5 的 `z` 歸零；
- m8：斷線時 `saved` 的兩個分支；
- m9：field 版首頁第 6 列。

## 計數與結論

- BLOCKER：0
- MAJOR：2
  - M1：8.5「網路換新密碼」那一行依賴不存在的 session，移除後隊長的節點不會換密碼（fail-open）。
  - M2：「三種碼都有 QR」的證據只到一人網路；同意碼隨人數變大，超出量過的版本或 4096 字元。
- MINOR：12（m1–m12）

**Verdict：APPROVE-WITH-CHANGES**。M1 與 M2 修正後要再審整份計畫。
