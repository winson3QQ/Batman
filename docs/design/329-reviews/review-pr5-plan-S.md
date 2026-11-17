# #329 PR 5 計畫 v10 — 第十輪審查（審查者 S）

範圍：`docs/design/329-pr5-plan.md` v10 全文（§0–§8），對照 main 2e18de6 的原始碼與 §0 的行為基準。重點：生命週期、擁有權與契約、舊控制台函式是否照搬、§2.12 入口表、文件內部矛盾。只讀；除本檔外沒有改任何檔案。

## 結論

**0 BLOCKER / 0 MAJOR / 13 MINOR — APPROVE-WITH-CHANGES**

我沒有找到能對應到原始碼、而且會在現場出錯的 MAJOR。以下 MINOR 大多是：
- 規則寫得無法照字面實作；
- 規則和舊程式有小差異；
- 計數或範圍的敘述自相矛盾。

這些都應該在實作前改掉，免得重演 Q-M1 / R-M1 那種「規則留在別處」的問題。

## 1. 附錄 A 的 MAJOR，逐一對原始碼核對

| MAJOR | v10 的位置 | 查證 | 判定 |
|---|---|---|---|
| A-M1 / B-M1（送新密碼的入口常駐、8.4 列出自己的節點） | 2.7 第 10 項、2.10「更多」、R14 | `request_send_update` 沒有 dev_gate（owner.rs:1041）；舊 `_sendUpdate`（nodes.dart:1546-1563）讀 info 再挑 net / mnet，新的「更多」照這個順序 | 已關 |
| A-M2（隊員入口不綁節點） | R15 | 每一列一直在，T-P5-E 有負對照 | 已關 |
| A-M3 / B-M2（QR 大小） | R1、R5 | QrDecode.kt:18 MAX_LEN 4096；R1 依編碼器給的版本；貼上上限 300 000 | 已關 |
| D-M1 / E-M1 / G-M1 / H-M1 / I-m2（hint） | R6–R8 | 見 §2：`update_hint` 讀 `page_info`（owner.rs:1099-1101），這個值只在 status-page 讀完 info 之後才有（owner.rs:951-965）；prober 的 answer 正是在那之後（prober.dart:122-126）；在 `done` 之前算，`s?.dispose()` 在 :200 | 設計上已關。prober.dart:83 要跟著改，見 S-m5 |
| D-M2（指紋、同名） | 2.7 第 1、8、9 項 | 對照 nodes.dart:1324-1338、:1397 | 已關 |
| C-M1 / D-M3 / C-M2（常駐按鈕） | R15、§2.12 | 見 §3 | 已關 |
| E-M2（只有 mnet 時的加入網路） | R16 | net_pages.dart:352-360 確實只給舊控制台，R16 改掉它 | 已關。R16 的入口比對見 S-m1 |
| F-M1（8.4 不能悄悄略過讀不到的節點） | 2.7 第 10 項「自己的節點段」 | 清單來自 `netPeople` 自己那一組，讀不到的也列 | 已關 |
| H-M2 / J-M1 / L-M1 / M-M1 / N-M1（「換好」的判斷） | R9、R14 | 正文用 grep 找「消失」「已送出」都沒有結果；只有 Updated / AlreadyCurrent 打勾（rekey.rs:451-453，`Applying` 也用 `[UPDATED]` 開頭） | 已關。分類的方式見 S-m4 |
| I-M1 / K-M1（8.3 讀每一台、不略過） | 2.7 第 9 項 | 和 nodes.dart:1360-1375 一致；有「第 1 台逾時、第 2 台仍被讀」的測試 | 已關。「60 s」的寫法見 S-m6 |
| O-M1 / P-M2（貼上後一律清） | R4 | 和 nodes.dart:728-732 一致；`clearOwnClip` 已移除 | 已關 |
| P-M1 / R-M1（隊員端的「已是新密碼」） | R14 `justImported` | updflow 的 AlreadyCurrent 只比節點和 mnet 的版本（rekey.rs:451；mupdate.rs:298-299）；四個送出結果都只能由 `RekeyResult` 顯示，並用原始碼檢查鎖住 | 已關。R16 的自動送出算第五處，見 S-m3 |
| Q-M1（7.8 與 R16 規則散在多處） | 2.8 第 11 項、R16 | grep「nodeState」「篩選」：只出現在 R16 與 2.8 第 11 項 | 已關 |

## 2. §2.12 入口表，對照 nodes.dart:1733-1770

| 舊按鈕（行號） | 舊程式的實際行為 | v10 的入口 | 判定 |
|---|---|---|---|
| 加入網路（:1735，`_join` → `joinChoice`，nodes.dart:1065-1094） | 隊員那一支 → `_memberJoin`；none + mpend → 「還在等隊長同意」 | 「讓我的節點加入隊長的網路」/ 節點頁 R16；只有 mpend → 7.9 | OK |
| 忘記加入中的節點（:1741）裡的「排除這台」（:1277-1283） | dev 時，對話框可以「排除這台」→ `_remove(node:)` | 8.2 自己那一組 | OK |
| 狀態頁的提示（:1744 → `_readStatusPage` :1158-1177） | 每次讀取都算 hint | 提示卡（R6–R8） | OK，但只在 devTrust、節點頁開著時算（D8） |
| 把新密碼送給節點（:1745） | info → `infoNetId` → net 優先，再 mnet；隊長先確認 | 「更多」，兩次 `once`；隊員同一次 `once` | OK |
| 隊員名單／移除（:1750） | `_pickNet(only: applied)`（:1314） | 選網路 → 8.1 | OK，但 R13 沒把它列進 applied 篩選（S-m7） |
| 產生更新包（:1751） | applied 篩選（:1452） | 選網路 → 8.4 | OK |
| 貼上更新包（:1752） | `_takeUpdate` | 8.5 | OK，有兩處細節沒照搬（S-m8） |
| 邀請隊員（:1757） | applied（:802） | 7.1 | OK |
| 貼上隊員的申請（:1758） | applied（:816） | 7.4 | OK |
| 貼上邀請（:1759） | `_takeInvite` | 7.8 | OK |
| 貼上同意碼（:1760） | `_takeApproval` | 7.10 | OK |
| 申請加入（:1763-1766） | 要先登入 | 7.8 裡選節點 | OK |
| 再顯示申請（:1768） | `_showPendingBody`：有 `_invite` 就用它的 id，否則列 mpend | 7.9（多筆時先選） | OK |
| 3.6「我是隊員」（add_pages.dart:124-130） | 開舊控制台 | 7.8 + devTrust | OK |

結論：每一顆舊的成員按鈕都對得到一個做得到的新入口。

## 3. 事實表抽查

以下都對過原始碼，行號正確：
- P6、P7、P9、P10、P12、P13、P14、P19、P20、P21、P22、P24、P25、P26；
- 2.3 引的 :1573；
- 2.7 引的 :829、:835、:839、:1568-1572；
- P17 / P18（build.gradle.kts:66-69、:109）；
- EcdhPeer.kt 的 `accept(devTrust, …)`。

## 4. 發現

### MINOR

**S-m1　R16「登入後用 `nodeDacHash()` 比對」對 mnet 做不到。**
- **情境**：隊員節點頁的 member 分支。隊員登入入口節點後，要確認這台就是 mnet 記的那台。
- **證據**：
  - `MnetView` 只有 `net_id / net_name / entry_state / device_last4`（member.rs:304-327；Dart member.dart:253-283）；
  - mnet 的 `me.dac_pub_hash` 沒有任何 bridge 入口送到 Dart；
  - §0 又規定「Rust 入口全部不改」。

  所以這個比對沒有東西可以比。
- **現場影響**：不大。Rust 的 `begin_member` 照樣 fail-closed，回 `NotThisNode`「這份網路資料是給另一台節點的」，而且在任何寫入之前（join2flow.rs:380-384；owner.rs:585）。
- **修法**：R16 改成「後四碼找候選，比對交給 Rust 的 `NotThisNode`，畫面顯示 Rust 原句；撞號時逐台試」（同 8.4）。拿掉 Dart 端「這台不是你加入隊伍時用的節點」那句。

**S-m2　R16 只寫了 `NoEntry` 時給「收隊長的邀請」，有兩種情形沒寫到。**
- **證據**：
  - `member_join_text` 對確定失敗的 `Failed(…, Reverted|NoChange)` 也會在句尾加「；需要新的邀請」（owner.rs:586-590）；R16 只寫 `NoEntry`（P24）。
  - 入口資料被拿掉之後，`entry_state` 是空的、`device_last4` 也是空的（member.rs:315-323）。這時節點頁的 member 分支沒有任何一台會出現；而「隊伍與邀請」→「讓我的節點加入隊長的網路」→ 選這筆 mnet 時，會走到哪一句也沒寫（R16 只寫了「對不上」那一句）。
  - 首頁第 6 列寫的「就顯示 R16 的那句話」也沒說是哪一句。
- **修法**：
  - 判斷依據改成「重讀 mnet，`entry_state == ""`」，不要解析 Rust 句子；
  - 這種情形一律顯示「需要新的邀請」加上 7.8 按鈕；
  - 第 6 列寫清楚要顯示哪一句。

**S-m3　R14 寫「共四個地方」，但 R16 的自動送出是第五處。**
- R16 第 2 步：`memberJoin` 回 `sendUpdate` 之後跑 `sendUpdateFor(member: true)`，結果用 `RekeyResult`。R14 的清單沒有這一處。
- 原始碼檢查會攔下它，但清單和測試項（「四處」）要一致。這正是 v10 想消除的那一類矛盾。
- **修法**：R14 列成五處，並指定 R16 這一處 `justImported` 為假。

**S-m4　R14 要靠 Rust 的顯示句子分類，正是 v10 拿掉「解析第 N 版」的理由。**
- **證據**：`Updated`、`AlreadyCurrent`、`Applying` 三者都以 `[UPDATED]` 開頭（rekey.rs:451-453）。`ConsoleReply` 沒有 End 的種類，只有 `text`（owner_console.dart:110-112）。所以打勾只能比對「已是新密碼 / 已換成新密碼」這兩句。
- 計畫沒寫怎麼比。前言說「解析顯示文字很脆弱」，這裡卻依賴它。
- **修法**：寫明分類函式，例如 `rekeyOk(text)`：前綴 `[UPDATED]` 而且結尾是 `已是新密碼` 或 `已換成新密碼`。再加一個跨語言的釘子：Rust 單元測試斷言這三句的確切字面，Dart 測試用同樣的字面；Rust 改了文字，兩邊都會紅。
- 這不改 Rust 入口。

**S-m5　R7 要能成立，必須改 prober.dart:83，計畫沒點名。**
- **證據**：`unawaited(cancelled.then((_) => done(const Outcome(Res.noResponse))))`（prober.dart:83）。今天 `done` 在 answer 那一步是同步的，所以沒有空檔。R7 加了最多 2 s 的 `openNet` 等待，這段時間如果讀取被取消（例如使用者按下某個操作拿佔用），第 83 行會先以 noResponse 結束。已讀到的 StatusView 會丟掉，這一輪變成「沒回應」。
- R7 的文字「照常 done（帶 StatusView）」只描述了想要的結果。
- **修法**：在 R7 寫明「answer 之後，cancelled 的處理改成 `done(已算好的 StatusView)`」。現有的「等提示時讀取被取消」白箱測試要斷言 `Res.body` 而不是 noResponse，負對照是不改 :83 → FAIL。

**S-m6　8.3「每台一個 `OpSession.once(那台, c.info)`，上限 60 s」可能被做成外層 timeout，等於重開 K-M1。**
- **證據**：`once` 沒有逾時參數（op_session.dart:89）。60 s 是 `loginFor` 自己的預算（node_link.dart:222、:345-349），之後 `info` 還有 15 s。如果實作者在 `once` 外面包 `.timeout(60 s)`，前一台的 `once` 會在背景繼續持有佔用，下一台就拿到 busy，正是 K-M1。
- 現有的「第 1 台逾時、第 2 台仍被讀」測試會抓到，但文字容易誤導。
- **修法**：改寫成「上限由 `loginFor` 的 60 s 與 `info` 的 15 s 決定，不另外包 timeout」。

**S-m7　R13 的 applied 篩選漏了 8.1 / 8.3。**
- **證據**：舊 `_members` 用 `_pickNet(only: applied)`（nodes.dart:1314）。R13 只列「邀請、產生更新包、收申請」。
- **現場影響**：對還沒套用的網路，Rust 會以 `NotApplied`「這個網路還沒確認建立完成」拒絕（rekey.rs:132），所以無害。但這和舊程式不同，而且違反 §0「照搬」。
- **修法**：R13 加上「隊員名單（8.1）、節點頁的隊員分組選網路」。

**S-m8　8.5 有兩處細節沒照搬 `_takeUpdate`。**
1. ecdh 只在 `UpdateState.advance` 時呼叫，AddSecrets 傳空的 `z`（nodes.dart:1525-1528）。計畫寫成「ecdh + memberUpdateImport」，像是一律呼叫。
2. CAS 衝突時，舊程式把 `staleRecordLine` 換成「請隊長再複製一次你的包，再貼上」（nodes.dart:1532）。R10 卻寫「`failed(line)`，line 是 Rust 的拒絕原句」。

- 同類問題：R10 只寫了 String 例外。舊程式對 `PlatformException` 給「[KEY_LEVEL] 沒有匯入：…」或「手機金鑰出錯（code）」（nodes.dart:1034-1036、:1534-1536），`NoLease`、`StateError` 也要有句子。
- **修法**：R10 補一張例外對句子的表：String → 原句（加上這一個 stale 的替換）；PlatformException → 舊句；NoLease → R12 的 `unknown`。8.5 寫明 ecdh 的條件。

**S-m9　mpend 待辦的條件比上層設計多了一個，會在「被移除後重新邀請」時藏起待辦。**
- **證據**：上層設計 329-app-uiux.md:699 的條件只有「有 `mpend/<netid>`」。計畫（2.10，來自 A-m6）多加了「而且沒有同一個 id 的 mnet」。
- **情境**：
  - 隊員被移除後重新邀請（remove-member §3.6-2）。手機上同時有舊的 `mnet/<id>` 和新的 `mpend/<id>`，正是 `_takeApproval` 的 replace 情形（nodes.dart:974-982）。
  - 這時待辦不出現。第 6 列也不給（節點仍在舊網路裡，`notInNetwork` 為假）。隊員只能自己想到去「隊伍與邀請」。
  - A-m6 想處理的是「匯入後刪 mpend 失敗」的殘留，而這種情形很少見（member-join :65「留著無害」）。
- 這也不在 §4 的偏離清單裡。
- **修法**：改回上層設計的條件（只看 mpend）。如果要壓掉匯入後的殘留，就改用「mpend 的 netcfg 版本不大於 mnet 的版本」，而不是「有 mnet 就不顯示」；或者把它列為 D11。

**S-m10　§0 寫「對 PR 1–4 機制的增量，只有這四處」，和正文不符。**
- 正文還改了：
  - `SecureScreen` 的 `fallback`（R3）；
  - `NodeLink` 的 `hints` / `onHint` / `netKnown`（R6、R8）；
  - prober.dart:83（S-m5）；
  - `OwnerConsole` 加的請求，以及 `_pendSaved`（2.3；`OwnerConsole` 本身是 §0 基準列的 PR 3 機制）；
  - `AppLink.devTrust`（2.6）。
- 另外，§0 說「本 PR 新做的」有 1–9 項，清單實際是 10 項。
- **修法**：§0 列出全部的增量，每一項附上負對照的測試名稱。

**S-m11　R11 寫「用到紀錄的 work，一開始先重讀」，清單卻沒有「邀請」。**
- `makeInvite` 也用紀錄（nodes.dart:802-806）。
- 舊程式不在佔用裡重讀（用 `_pickNet` 當時的 gen 做 CAS）。照搬的話，CAS 衝突會出現 stale 句子，結果無害。
- **修法**：二選一，並寫明理由。一是把邀請加進 R11 的清單；二是寫「邀請照舊程式，不重讀，靠 CAS 擋衝突」。

**S-m12　R8 沒說空的提示要不要存，2.10 的提示卡又是「`hints` 裡有這台就顯示」。**
- **證據**：`update_hint_of` 在大多數情形回 `line: ""`（rekey.rs:466-499）。如果實作把空句也存進 `hints`，節點頁會出現一張空的 warn 卡。
- **修法**：R8 寫明「`line` 為空就刪掉這台」，並加一個測試：空提示 → 沒有卡。

**S-m13　3.1 擁有權表有兩處小缺。**
- `unsavedTodos` 的寫入者寫成只有 `LeaseRegistry`。但首頁的「知道了」會 `remove`（home_page.dart:310-311），那是第二個寫入者，而且是既有行為。寫成「LeaseRegistry 新增、首頁刪除」即可。
- `RemoveTicks.removedThisRun` 的讀者，除了 8.1、8.4，還有 `RekeyResult`（R14 的那一句加句）。`RekeyResult` 會在節點頁「更多」與提示卡上顯示，所以它也是讀者，而且需要 netId。

## 5. 安全與現場行為，逐個 actor 看過，沒有新的發現

- **遠端攔截碼**：
  - 邀請被攔下 → 攻擊者送申請 → 隊長在 7.5 靠電話核對確認碼擋住（基準 §5.5）；
  - 同意碼與更新包是加密給對方的（基準）。
  - 本 PR 沒有加新的暴露點：只做 QR 與複製；沒有 intent，也沒有深層連結。
- **同一支手機上的 app**：
  - 貼上之後一律清（R4）；
  - 複製時加 sensitive 旗標（Android 12 有沒有效 ⚠️，計畫已標明）；
  - 鍵盤 app 的剪貼簿紀錄清不到，計畫已寫明；
  - 截圖靠 R3。
- **被入侵的節點**：
  - k10 只會變成 16 位元組十六進位的路徑（owner.rs:2260）；
  - `info_net_id` 不檢查長度（rekey.rs:360-362），但只產生十六進位，不會穿出目錄（P-m2 已記錄）；
  - 它能影響的只有提示卡，而提示卡不是「換好」的判斷（R9）。
- **惡意隊員用兩組身分**：每組都一直顯示指紋，同名會提示。
- **實體被奪**：計畫列為殘留風險。
- **我們自己的錯**：
  - T-P5-L 攔 log；
  - Kotlin 新檔案有原始碼檢查；
  - 操作名稱是常數；
  - 寫入都經 `RecordWriter`（record_writer.dart:27-33），收回之後 fail-closed。
- **生命週期**：3.3 的各列我逐一對過，沒有缺漏的路徑。
  - app 被殺：`InviteHolds` / `RemoveTicks` / `hints` 都丟，紀錄還在；這和舊程式的頁面記憶體一樣（P11 / P12）。
  - 降版：紀錄格式不變。
  - field 版：所有新入口都沒有；Rust 的 `dev_gate` 是第二層（member.rs:17-23；owner.rs:1255、:1284）。
  - `request_send_update` 沒有 Rust gate，T-S5 已點名要測。

## 6. 判定

**APPROVE-WITH-CHANGES。** 0 BLOCKER / 0 MAJOR / 13 MINOR。
- 先改 S-m1、S-m2、S-m4、S-m5、S-m9：這幾條會影響實作出來的行為或判斷。
- 其餘是文字與範圍的一致性，按 v10「每條規則只寫一次」的原則，改在規則本身，不要在別處補。
