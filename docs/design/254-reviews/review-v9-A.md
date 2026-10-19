# Review A(第 9 輪)— `254-stage1-impl.md` v9(含 v4–v8 中標「同 vN」的各節)

審查對象:Batman `design/254-stage1-impl` @ 294546f;原始碼 main f2f2bf6(= branch)`feed/batman-provision/files/`;節點 04 唯讀探針(見 §7)。沒有任何寫入、重開、commit。

## 0. 總評

- **A8-M1 / B8-M1 的核心已收**:不變量 U(鎖內、重讀 p5 = `none`、無孤兒寫者)確實蓋到 F1/F2/F2b 失敗、F3 rc 10 重試、cancel、重新發起、啟動表各列。我逐一走過每個「解凍 / 刪 marker / `apps.reset → apps` / 刪哨兵」的入口,沒有找到在 p5 可能有意圖時繞過 U 的路徑。U 本身不會讓健康節點永久卡死(`$RUNDIR` 是 tmpfs、flock 隨程序死亡釋放),但有幾個實作細節必須寫死,否則 U 會「名義上成立、實際上失效」或「永遠不成立」(m1、m5)。
- **但 v9 為了收 A8-m5(W2 被斷電打斷時節點開放)而在 S11 加的「`unreadable` → 上鎖(L)」沒有任何閘門**,套到每一個從沒做過重置、只是 p5 某次掛不起的節點:這次開機被鎖(`root:!` 寫進 overlay、永不自動解開),而且 L 會 touch `.locked` → 下一次 p5 讀得到時,`.locked` 獨立觸發把整個 overlay 清掉再重開。→ **A9-M1(MAJOR)**。修法很小(把 L 限定在「有本機重置證據」時)。
- 其餘是 MINOR,其中意圖行長度 64 B 與新加的 `p6uuid` 直接衝突(m2),是本輪新引入的規格錯誤。

**判定:REJECT(窄)** — 0 BLOCKER / 1 MAJOR / 10 MINOR。

---

## 1. 先補:缺的列 / 資源

| 缺的列 / 資源 | v9 現況 | 對應 |
|---|---|---|
| 從沒重置過的節點,非 fresh 開機時 p5 掛不起(卡片老化、journal replay 失敗) | W 表 `unreadable` → 上鎖(L)+ touch `.locked` → 下次 `none` + `.locked` → 清 overlay + 重開 | **M1** |
| F3 時 helper 持有 `reset.lock`(F0 取),config-save `--reset-intent` 也要取同一把 | 照字面:F3 每次都 rc 10「`reset.lock` 忙」→ 重試 60 s → 解凍 → 恢復出廠永遠不成功 | m1 |
| `reset.lock` 的 fd 被長壽子程序繼承(shell `exec 9>`、`batman-slot reboot` 的 `setsid … sleep 240 &`、未 CLOEXEC) | 未規定 → U(1) 在該次開機永遠不成立 | m1 |
| W1 寫回 `p6uuid` 後的意圖行 | 95 B,超過解析器的 64 B 上限 → W1 與 W2 之間斷電 / W2 失敗的下一次開機判 `bad` → Wb | m2 |
| W1 在新 p6 寫 `prov-state`(`last_known_state=resetting`) | 96 的規則只在 {claimed,member} 上鎖 → 這行沒有效果;W1 也不在 §3 寫者表 | m3 |
| W 成功的那次開機,overlay 帶著上一次開機「因意圖而上鎖」的值 | `.locked` 只在**下一次**開機開頭處理;本次開機鎖住、沒有 key,沒有人重開 | m4 |
| `.locked` 觸發而 `jffs2reset` 失敗 | 沒有計數、沒有 rc 檢查 → S11(網路之前)重開迴圈 | m4 |
| U(2) 重讀時,p5 正被別的讀者以 `ro,noload` 掛著 | 第二個掛載共用同一個 superblock → 不 replay → 可能讀到過時的 `none` | m5 |
| rc 12 / 「接手既有意圖」時意圖的 slot ≠ active | 未規定 | m6 |
| L58 降版 | 只在 §13 出現,§5 矩陣沒有;漏了「降版之後的下一次正常升級」 | m7 |
| 沒有 p5 分割(golden 參考節點「the reference node has no p5」,`p5-config-partition.md:38`) | 解析器回什麼沒規定;若 `unreadable` → 每次非 fresh 開機都 L | m8 / M1 |

---

## 2. Findings

### MAJOR

**A9-M1. S11 的「`unreadable` → 上鎖(L)」沒有閘門:從沒做過重置的節點,只要 p5 某次掛不起,就被上鎖;L 又 touch `.locked`,下一次 p5 正常時整個 overlay 被清掉。**

- **情境 A(資料遺失,健康節點)**:
  1. 某現場節點(legacy 或 member,**從沒按過恢復出廠**,p6 無 marker、overlay 無哨兵)。某次開機 S11,p5 掛載失敗(卡片開始老化,或 ro 掛載時 journal replay 出錯)→ 解析器 `unreadable`。
  2. W 表第一列:「`unreadable` → 今天的流程 + 上鎖(L)」(`254-stage1-impl.md:240`)。L 段:「fresh overlay 上 96、非 fresh 開機 batdata-mount;**兩者都 touch `.locked`**」(`:251`)。→ dropbear `PasswordAuth=off`、`ttylogin=1`、root 無 hash → `root:!`,寫進 overlay;`/etc/batman-reset.locked` 建立。
  3. 下一次開機 p5 正常 → `none`;`.locked` 規則(`:249`):「沒有意圖、但 `.locked` 存在 → dot sweep + `jffs2reset -y` + `batman-slot reboot committed`」→ **整個 overlay(含 dot 目錄)被清掉**,節點重開成 fresh。
  4. fresh 開機 96 從 p5 還原 identity / overrides。但只存在 overlay 的東西全部消失:沒被 config-save 持久化的 uci(持久化範圍只有 mesh key/mesh_id/channel/country/hostname/位址旗標/AP key,`202-config-survival-closeout.md:108`)、`/etc` 下其他設定、opkg 裝在 overlay 的套件、`ssh_keys.added` 等。一個沒有任何人要求重置的節點,因為一次 SD 讀取錯誤被半套恢復出廠。
- **情境 B(SSH 永久鎖死,無 key 節點)**:unclaimed、沒有 `authorized_keys`、image 預設空密碼的節點(恢復出廠完成後的 04 正是這種狀態,Q5 的還原路徑就靠「重置後 image 預設空密碼」),p5 持續讀不到 → 每次非 fresh 開機都 L,`.locked` 的觸發要求 `none`,所以永遠不清 → `root:!` 永久。96 只在 fresh 跑、helper 對 unclaimed「不動」(§1.4),沒有任何東西會解鎖。04 在這條路上遠端救不回。
- **為什麼是 MAJOR**:照文件實作會在**未發起重置**的節點上丟 overlay 資料,或讓節點遠端救不回;觸發是單一故障(p5 掛不起),而且正是使用者在意的「p5 會死的節點」。v8 這一列是「今天的流程(96 依 `last_known_state` 上鎖)」(`254-stage1-impl-v8.md:230`),v9 改成「+ 上鎖(L)」,是本輪新引入的回歸。
- **文件內部也互相矛盾**:§3 鎖定欄位列說 batdata-mount 只在「**有意圖**且非 fresh」時寫(`:121`、`:251`),可是 `unreadable` 時根本不知道有沒有意圖。`.locked` 的定義是「因為意圖而上鎖」(`:249`),L 段卻寫「兩者都 touch」。
- **修法**(不加機制):
  1. `unreadable` 分支照今天的流程先掛 p6,**之後**才決定。只有本機有重置證據時才 L 並 touch `.locked`,證據是下列任一:overlay 有哨兵或 `.locked`;p6 有 marker;p6 `prov-state` 的 `last_known_state` = `resetting`(W1 寫的,見 m3)。沒有任何證據 → 今天的行為,不上鎖、不建 `.locked`。
  2. `.locked` 只由「因意圖(或上述證據)而上鎖」的一方建立,與 §3、`:249` 一致。
  3. 解析器在「沒有 p5 分割 / 沒有 `PARTNAME=config`」時回 `none`(m8)。
  4. 這樣 A8-m5 的「W2 被斷電打斷」仍然擋得住(新 p6 的 `prov-state` = `resetting` 就是證據),健康節點則不受影響。
- **負對照**:
  - 白箱 seam 讓沒有 marker、沒有哨兵的節點在 S11 的解析器回 `unreadable` → 斷言 dropbear / shadow 未改、沒有 `.locked`、下次開機 overlay 沒被清。照 v9 字面會上鎖,而且下一次開機清 overlay → FAIL。
  - 正對照:W1 之後 seam 讓 p5 `unreadable` → 斷言上鎖。

### MINOR

**A9-m1. `reset.lock` 的持有與交接沒寫清楚;照字面 F3 永遠失敗,寫法不對時 U(1) 會永遠不成立** — **PR-P1 必帶**
- F0「取 `reset.lock`」;F3 呼叫的 `--reset-intent`「自己也持這把鎖」(`:185`);「`reset.lock` 忙」又是 rc 10 的原因之一(`:211`)。flock(2) 在不同的 open file description 之間互斥。helper 是 Go,預設 `O_CLOEXEC`,子程序不繼承 fd,所以 helper 持鎖時 config-save 一定拿不到 → rc 10 → 重試到 60 s → 解凍 `E_RESET(p5-busy)`。結果安全,但功能全滅。
- 要寫死下列其中一種:
  - (a) helper 在 F3 前釋放鎖,config-save 取鎖;config-save 結束後 helper 重取。這段期間 helper 內部序列化 cancel。
  - (b) helper 以繼承 fd 的方式把鎖傳給 config-save,config-save 不另外取。

  負對照 (q) 要在 (a) 之下才成立。
- 所有參與者一律用 **flock(2)**(busybox `flock` 用的就是 flock(2))。Go 端不得用 `fcntl` 鎖:Linux 上兩種鎖互不干擾。
- 鎖的範圍:
  - shell 端用子 shell 寫法,例如 `( flock -n 9 || exit 75; … ) 9>"$RUNDIR/reset.lock"`,讓鎖只存在於 `reset_wipe()` 之內。不可在 `boot()` 裡用 `exec 9>`。
  - 否則之後的子程序會繼承這個 fd,例如 `batman-slot reboot` 的 `setsid sh -c "sleep 240; …" &`(`batman-slot:773`),或任何不經 procd 啟動的背景程序。U(1) 就會在該次開機一直拿不到鎖:cancel 永遠 `E_BUSY`,F0 失敗或阻塞。
  - F0 要用 `-n`,拿不到就回 `E_BUSY`,不阻塞。
- `RDOK=0`(run dir 不可用)時 `reset_wipe()` 怎麼做沒寫。建議 S11 照樣執行(開機本來就序列執行),helper 端 fail-closed。
- 負對照:
  - helper 持鎖時跑 F3 → 必須成功。照 v9 字面會 FAIL。
  - W 成功後,S89 的 helper 拿得到 `reset.lock`。

**A9-m2. 意圖行的長度上限 64 B 與 v9 新加的 `p6uuid` 衝突** — **PR-P1 必帶**
- 實算:`reset v=1 nonce=5c1e9a07d3b2f648 slot=A attempts=1 p6uuid=7e3f2a91-c4d8-4b06-9e15-a2c7f08d3b64\n` = **95 B**;不含 p6uuid 是 51 B。§4.3 寫「≤ 64 B」(`:153`),解析器寫「`head -c 65`,超過 64 B = bad」(`:235`)。
- 後果:
  - W1 寫回 `p6uuid` 之後,只要 W2 失敗,或 W1 與 W2 之間斷電,下一次開機解析器就回 `bad` → Wb:crit、上鎖、送 bench。設計上這條路應該自癒:`p6uuid` 相同 → 略過 W1 → 重做 W2。
  - W1 的「讀回」如果也走解析器,W1 自己就會失敗。
- 修法:
  - 上限改成 ≤ 128 B,欄位順序固定;`p6uuid` 驗字元集 `[0-9a-f-]` 和長度 36。
  - §3、§4.3 的格式行補上 `p6uuid`。
  - 負對照 (u) 加一項:合法、含 p6uuid 的行 → `intent`。

**A9-m3. W1 寫 `last_known_state=resetting`,但沒有讀者會照它上鎖;W1 也不在 §3** — **PR-P1 必帶(與 M1 一起)**
- 96 的規則:p5 讀不到時,只有 `prov-state` 第 3 欄 ∈ {claimed,member} 才上鎖(`:171`)。`resetting` 不在集合裡,所以 `:245` 宣稱的「讓 W2 被打斷時 96 仍上鎖」不成立。這也和「`last_known_state` 只在讀到確定的 prov 時更新」(`:111`、`:171`)矛盾。
- §3 也沒登記:
  - `prov-state` 的寫者只列 99zz 和 helper;
  - 意圖檔的寫者只列 F3 建立、W0 改 attempts、W2 消失,**沒有 W1 改寫 `p6uuid`**。
- 修法:
  - 96 的集合加上 `resetting`(並 touch `.locked`);或依 M1 的修法,由 batdata-mount 以此為證據上鎖。
  - §3 補 W1(改寫 p5 意圖、寫 p6 `prov-state`),並把 `last_known_state` 規則的例外寫明。
- 誠實面:W2 被打斷、p5 半格式化的節點,即使上了鎖,`.locked` 也要 `none` 才會觸發 → 永遠不清 → 要 bench。§11 已列 ✅;但 Q5 的副作用清單要寫「04 走到這條要到現場」。

**A9-m4. `.locked` 獨立觸發的三個缺口** — **PR-P1 必帶**
- **(a) 「沒有意圖」的定義**:必須明定為解析器回 `none`。若寫成「不是 `intent`」,`bad` / `unreadable` 也會觸發清 overlay,例如 Wb 節點每次開機都多清一次、多重開一次。
- **(b) 同一次開機**:
  - `:247` W3 寫「若 `.locked` 存在 → 見下」,`:249` 又寫「W3 不再自己判斷」,觸發點則是 `boot()` **開頭**。
  - 照後者,W 成功的那次開機會帶著上一次開機的鎖(沒有 key)一直跑,直到有人重開。遠端沒辦法登入就沒辦法重開(Q5 / 04)。
  - 這段期間 BLE 開放 unclaimed 認領;新擁有者在這段時間寫進 overlay 的東西,下次開機會被清掉。
  - 修法:W2 成功後,在同一次開機由 W3 執行同一個動作(dot sweep + jffs2reset + reboot + `return`)。`boot()` 開頭的檢查保留,用來補斷電的情況。
- **(c) 沒有計數、沒有 rc 檢查**:
  - `jffs2reset` 若在標記 PENDING 之前就失敗(例如 `volume_find` 失敗),`.locked` 還在 → 每次開機都在 S11(網路起來之前)重開,無限迴圈。
  - 修法:只在 `jffs2reset` rc 0 時重開;否則 crit 並繼續開機(維持鎖)。或在 `.locked` 檔內記次數,超過 3 次就停。
- **迴圈分析(正面)**:jffs2reset 成功時,掛載中會走 PENDING + `overlay_delete`(R43),下次開機 fstools 一定先清掉 overlay → `.locked` 必定消失。就算 overlay 壞掉退回 tmpfs,`.locked` 也不存在 → 不會迴圈 ✅。
- **負對照**:
  - seam 讓 `jffs2reset` 回非 0 → 斷言不重開、有 crit;
  - W 成功的那次開機結束時,斷言 shadow 已回到 `root:::`。照 v9 字面要等下一次開機才回復 → FAIL。

**A9-m5. p5 已被別人以 `ro,noload` 掛著時,U(2) 的「重讀 = `none`」可能是過時的** — **PR-P1 必帶**
- **機制**:對同一個區塊裝置再做一次 ro 掛載,會共用既有的 superblock,第二次的掛載選項不生效。
- **現行仍有 `ro,noload` 的讀者**:config-save `:254`、`batman-slot:540`(`node_checks`)、96 `:89`、99-chanfix `:28`。§4.5 `:236` 也明說它們自己的 noload 掛載保留。
- **情境**(多重故障,機率低):
  1. F3 rename + sync 之後、umount 之前斷電。
  2. 下一次開機,S11 和 S89 的解析器都回 `unreadable`。這時第一個成功的非 noload 掛載還沒發生,journal 仍待 replay。
  3. 之後擁有者送 cancel。U 的重讀剛好和 precheck / `--check` 的 noload 掛載重疊 → 看不到 journal 裡的 rename → 讀到 `none` → 解凍。
  4. 下一次 replay 之後意圖出現 → W1 清掉 p6。結果和 A8-M1 同一類。
- **修法**(擇一):
  - 解析器掛載前先查 `/proc/mounts`。p5 已在任何地方掛著 → 回 `busy`(可重試,U 不成立),不共用。
  - 或者掛上後用 `hexdump` 讀 superblock 的 RECOVER 旗標(`s_feature_incompat & 0x4`)。旗標仍在 → 回 `unreadable`。
- **負對照**:seam 讓 p5 先以 `ro,noload` 掛著,再送 cancel → 斷言回 `E_BUSY`。

**A9-m6. 「接手既有意圖」(rc 12 / 重新發起時 p5 已有意圖)的細節**
- 意圖的 slot ≠ `batman-slot active` 時要拒絕(回 `E_BUSY`,維持 Wa),不可以做 F4/F5。否則會清掉不屬於意圖槽的 overlay,節點被鎖在一個 W 永遠不處理的槽上。
- 接手時要把 marker 和哨兵的 nonce 改成意圖的 nonce。哨兵的內容就是 nonce,W0/W1 會讀(`:117`);不改的話,W0 若比對 nonce,會判成「哨兵不在」。
- 「marker `step` 只增不減」(`:195`)和「重新發起 → 從 F0 開始」(會寫 `<nonce> 1 - 0`)互相矛盾。安全性由 U 保住,但文件要擇一:例如重新發起時保留 `step` 的最大值,或明說新 nonce 會重設 step。

**A9-m7. L58(降版)只寫在 §13,§5 矩陣沒有,而且漏了真正的後果**
- 真正危險的不是降版本身,而是**降版之後的下一次正常升級**:
  1. 舊 image 的 precheck 不認得意圖,放行升級。
  2. `-F` 降版用的是另一槽(原本被 F2b 作廢的那一槽),所以這次升級會寫回原本的意圖槽。
  3. slot 相符,overlay 是新的、沒有哨兵 → W1/W2 在幾個月後把 p6、p5 全清,沒有任何提示。
- 修法:
  - §5 補 L58 列,把這條寫進去。
  - 可選的低成本防護:W1 之前用 `ro` 掛舊 p6,確認同 nonce 的 marker 存在(或 `p6uuid` 相符);都沒有 → crit `stale-intent`、不清、上鎖。
  - 不採用防護的話,就寫進殘項和 `-F` 的操作員警告。

**A9-m8. 解析器 / 寫入細節**(busybox 上的可行性已逐項查過,見 §3)— 第一點 **PR-P1 必帶**
- 沒有 p5 區塊裝置(或沒有 `PARTNAME=config`)→ 回 `none`,不是 `unreadable`(M1)。
- `attempts` 限 ≤ 2 位數:避免 `$((a+1))` 溢位,或 busybox `test -le` 遇到超長數字時報錯。
- 欄位順序固定,每個 key 只能出現一次。否則出現兩個 `slot=` 時不知道要取哪一個。
- 寫入用 `mv -T`(R72 有):`.factory-reset` 如果是目錄(實體 SD 放的),普通 `mv` 會把檔案搬**進**目錄。U 仍然擋得住解凍,但 rc 會錯。
- 用 `blkid -p`,繞過 `/run/blkid/blkid.tab` 快取(04 上這個快取存在)。快取失準只會多清一次、不會漏清,但規格寫 `-p` 比較乾淨。
- 留在 p5 上的 tmp 檔要由下一次 `--reset-intent` 或 W2 清掉。這是 A8-m1 原本的要求,v9 只寫了「忽略」。

**A9-m9. 解凍步驟要冪等;卡住的孤兒怎麼算**
- 解凍順序是 `mv -T apps.reset apps` → … → 刪 marker。若在中間 crash,下一次解凍會遇到「`apps.reset` 不在、`apps` 在」→ `mv` 失敗。要寫明:來源不在而目的在 = 這一步已完成。
- U(3):孤兒 config-save 卡在 D-state(SD 死掉)時,U 永遠不成立。要寫明這屬於 `reset-uncertain` / bench,不是 bug。

**A9-m10. 文件殘留**
- §1.4:
  - `resetting-pending` 列少了兩欄(`:76`)。
  - `reset-uncertain` 列寫「provd 只 `status/public` + `factory_reset.cancel`」(`:77`),§4.5 `:227` 卻寫「reset-uncertain 不放行 cancel」。helper 會依 U 擋下,所以實際安全,但兩處要統一。
- D27(`:303`、`:313`)仍寫「argv[1]=`/sbin/sysupgrade`」,而 §4.5 `:193` 已改成以 cwd 為基準的 `readlink -f`。
- L16 的測試欄仍寫「(a)–(n)」(`:276`),應為 (a)–(u)。

**PR-P1 必帶**:M1 + m1、m2、m3、m4、m5、m8(第一點)。m6、m7、m9、m10 可在實作與程式碼審查時補。

---

## 3. 指定重點逐項

| 項 | 結論 |
|---|---|
| U 是否蓋到每個解凍 / 刪除入口 | 都有蓋到 ✅:F1/F2/F2b 失敗(`:202-204`「依 U」);F3 rc 10 重試(`:212`,重讀不是 `none` → 不解凍);cancel(`:227`);重新發起(`:228`);啟動表(`unreadable`/`bad` 凍結,`f3` ≥ called 要重讀);W 階段只在意圖存在時刪 marker(W1);`.locked` 不碰 marker / `apps.reset`。殘留:m1(鎖交接)、m5(共用 superblock) |
| U 會不會讓健康節點死鎖 | `$RUNDIR=/tmp/run/batman`(`rundir.sh:19`)是 tmpfs、0700 root(04 實測 `drwx------`)→ 不會跨開機殘留。flock 在最後一個 fd 關閉時釋放,程序死掉就釋放,**除非 fd 被長壽子程序繼承**(m1)。孤兒判定只認 uid 0 + 主機 pid ns + argv,非 root / 容器偽造不了 ✅。D-state 孤兒 = 永久不成立(m9,屬 bench) |
| 設計承認的「永久凍結、無路可走」 | `reset-uncertain`(p5 讀不到)、`bad`、`reset-stuck`、Wa 但已 commit 在非意圖槽:都要 bench。M1 不修的話,會多出一條「健康節點被鎖」 |
| F3 rc 0/10/11/12 以 `rename(2)` 為界 | 可以實作:shell 在執行 `mv -T` **之前**先設「已呼叫」旗標,之後任何非 0 都是 11 ✅;同目錄 rename 不會走 busybox 的 EXDEV「複製再刪」後備 ✅;`fsync <dir>` 可用(busybox `fsync` 以 O_RDONLY 開檔,目錄也行)✅;rc 12 ✅(細節見 m6)。但照字面,F3 永遠回 10(m1) |
| 解析器在 busybox ash 的可行性 | 都可行 ✅:`[ -f ] && [ ! -L ]` 擋 FIFO / symlink;`head -c`;「恰好一行」= `wc -l` 為 1 且 `IFS= read -r` 讀到整行;`${#n}` = 16 加 `case *[!0-9a-f]*`(不用 `{16}`);`readlink -f`;`flock -n`。問題:長度上限與 p6uuid 衝突(m2);`attempts` 長度、欄位順序未規定(m8) |
| 用 blkid 讀 `p6uuid` | 04 上是 util-linux 的 `blkid`:`-s UUID -o value` 與 `-p` 都能用,不需要掛載 ✅。快取在 `/run/blkid/blkid.tab`,建議用 `-p`(m8)。前任無法預先種 UUID,因為 UUID 是這次 mkfs 才產生的 ✅ |
| `.locked` 獨立觸發 | jffs2reset 成功時不會迴圈 ✅。缺口:`none` 的定義、同一次開機的處理、jffs2reset 失敗時的迴圈(m4);觸發來源被 M1 擴大到健康節點 |
| L58 | 見 m7 |

## 4. 逐 actor

- **BLE 路人 / 只看過 QR 的人**:本輪沒有變化 ✅。
- **本機非 root 程序**:
  - `reset.lock` 在 0700 的 run dir 裡,拿不到 ✅(A8-m7 已收);marker 是 0600 ✅;偽造 config-save 程序會被 uid 0 + pid ns 擋下 ✅。
  - 填滿 `/tmp` 讓解析器建不了掛載點 → `unreadable` → cancel 回 `E_BUSY`,只是 DoS。即使 M1 沒修,S11 時還沒有任何非 root 程序,這條路也影響不到開機判斷。
- **被入侵的 tenant(容器 root)**:不在主機 pid ns,騙不過 U(3) ✅。
- **被入侵的 provd**:cancel / 重新發起都要 owner_op,helper 也一律要過 U ✅。
- **前任擁有者**:成功路徑全清 ✅;有 root 的前任在誠實界線內 ✅。
- **實體 SD**:目錄型的 `.factory-reset`(m8,用 `mv -T`)、超長行 → `bad` → Wb ✅,等同重燒卡。
- **供應鏈**:沒有新依賴;`blkid`、`fsync`、`flock`、`readlink -f`、`mv -T` 在 04 上都有 ✅。
- **我們自己**:M1(為修一條路影響到整個 fleet)、m1(鎖自我衝突)、m2(新欄位撐破舊上限)、m3(寫了沒人讀的值)。這幾條都是新增規格時沒有回頭對其他段落。

## 5. v8 發現核對(一條一行)

| v8 | 狀態 | 說明 |
|---|---|---|
| A8-M1 | addressed | U 蓋到所有解凍入口;實作細節見 m1、m5 |
| A8-m1 | addressed | rename 判準、同目錄、fsync;建議 `mv -T`(m8) |
| A8-m2 | partial | 不用 noload ✅、`unreadable` 分開 ✅、T11 可重試 ✅;共用 superblock 未處理(m5) |
| A8-m3 | partial | 逐欄檢查、`*[!0-9a-f]*` ✅;64 B 上限與 `p6uuid` 衝突(m2) |
| A8-m4 | addressed | 刪掉 cfgsave.lock 的說法;改靠 S11 序列執行 + `reset.lock` |
| A8-m5 | partial | 96 touch ✅、獨立觸發 ✅;W2 被打斷改靠 S11 無條件上鎖(M1)和沒人讀的 `resetting`(m3);同一次開機未處理(m4) |
| A8-m6 | addressed | joinwatch 只看 marker;寫者先查 mountpoint |
| A8-m7 | addressed | `reset.lock` 移到 run dir;marker 0600 |
| A8-m8 | partial | 補了 batdata-mount、`.locked`、`reset.lock`;W1 改寫意圖、寫 `prov-state` 沒登記(m3) |
| A8-m9 | partial | §6.4 的 pgrep 已刪 ✅;D27 用語、§1.4 cancel、L16 測試欄還有殘留(m10) |
| A8-m10 | partial | L58 只在 §13,而且漏了「下一次升級」的後果(m7);procd shutdown 已標 ⚠️ 待 bench 實證 ✅ |
| A8-m11 | addressed | `readlink -f` 以 cwd 解析;負測試加兩項 |
| A8-m12 | addressed | |
| B8-M1 | addressed | `unreadable` → `reset-uncertain`、不准 cancel;cancel 以 U 為準 |
| B8-m1 | partial | 96 會 touch ✅;W 成功的那次開機仍然鎖著,直到下一次重開(m4b) |
| B8-m2 | addressed | |
| B8-m3 | addressed | rc 12、rename 判準 |
| B8-m4 | addressed | T11 可重試 |
| B8-m5 | addressed | `resume_n` ≤ 3,負對照 (t) |
| B8-m6 | partial | journal / 私有掛載點 / 無逾時都寫明了 ✅;「每次開機都掛 p5」這個新依賴只寫成已知限制,沒有依本機證據加閘門(M1 的修法可以順便縮小範圍) |
| B8-m7 | addressed | |
| B8-m8 | partial | 同 A8-m8 |
| B8-m9 | addressed | |
| B8-m10 | addressed | 改用 blkid 比對 `p6uuid`;長度問題見 m2、`-p` 見 m8 |
| B8-m11 | addressed | 條件改成「是 tmpfs」 |
| B8-m12 | addressed | 啟動表 + app 文字 |

## 6. 使用者已定案事項的後果(不重開,只列)

- **Q5(L16 在 04)**:排 L16 之前,副作用清單要含以下三點:
  - M1 沒修:重置後的 04(unclaimed、沒有 key)只要有一次非 fresh 開機掛不起 p5,就會變成 `root:!`。
  - m4(b) 沒修:任何一次 W 先失敗、後成功,成功的那次開機就是鎖住、沒有 key,直到斷電重開。
  - m3:W2 被斷電打斷 → 要到現場(§11 已列)。
- **U3(擁有權與 SSH 脫鉤)**:M1 情境 B 對有 key 的節點無害(key 登入仍可用)。受害的是沒有 key 的 unclaimed 節點,只剩 BLE 認領一條路。
- **U4 全清含身分**:沒有新後果。

## 7. 本輪唯讀探針(04,原始輸出摘要)

```
/usr/sbin/blkid  (util-linux;-c/-o/-s/-p 皆有)
/etc/blkid.tab: No such file;/run/blkid/blkid.tab 存在(1395 B)
blkid -s UUID -o value /dev/mmcblk0p6    -> 254e7c3f-9120-495c-853e-0e7de68c29f3
blkid -p -s UUID -o value /dev/mmcblk0p6 -> 254e7c3f-9120-495c-853e-0e7de68c29f3 rc=0
flock: BusyBox v1.36.1  Usage: flock [-sxun] FD | { FILE [-c] PROG ARGS }   (flock(2))
readlink [-fnv];/bin/fsync [-d] FILE...
/proc/mounts: p5 目前沒有掛載
/tmp/run drwxr-xr-x root;/tmp/run/batman drwx------ root;/tmp = tmpfs 3.8G
```

意圖行長度(WSL `wc -c`):含 p6uuid 95 B;不含 51 B。

原始碼:
- `rundir.sh:19`(`RUNDIR=/tmp/run/batman`)
- `batman-slot:773`(`setsid sh -c "sleep 240; …" &`)、`:540`(ro,noload)
- `batman-config-save:115-122`(lock_try)、`:254`(ro,noload)
- `96:62-91`(各出口)、`:155-177`(4b 只在 fresh 跑;UNPROVISIONED = 不上鎖)
- `99-batman-chanfix:28`(ro,noload)
- `95:106`(p6 已掛就 exit)、`:605-735`(`boot()` 的順序)
- `p5-config-partition.md:8,38`(卡片製作時就格式化 p5;參考節點沒有 p5)

## 8. 判定

**REJECT(窄)**:0 BLOCKER / 1 MAJOR / 10 MINOR。

U 本身是對的,A8-M1 / B8-M1 已經收掉。A9-M1 是 v9 為了修 A8-m5 而新引入、影響整個 fleet 的回歸;修法是一個閘門:只有本機有重置證據時,才在 `unreadable` 時上鎖並建 `.locked`。連同 m1–m5、m8 第一點修完後,請重審整份文件,預期可以 APPROVE-WITH-CHANGES。
