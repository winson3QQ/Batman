# #254 階段 1 實作設計 v9 — 獨立審查 B(第 9 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v9(branch `design/254-stage1-impl` @ 294546f),加上 v4/v5/v8 中標「同 vN」的小節(`254-reviews/254-stage1-impl-v{4,5,8}.md`),以及第 8 輪 `review-v8-{A,B}.md`。原始碼 = main f2f2bf6(= branch);firmware `/home/yello/firmware-2710`(fstools `2024.07.14~408c2cc4` 的 `jffs2reset.c`、`libfstools/overlay.c`)。

全部唯讀:讀檔;`ssh root@10.41.1.3` 只跑 `blkid --help`、`blkid <dev>`、`flock --help`、`fsync --help`、`readlink --help`、`ls`、`cat /proc/mounts`、`batman-slot active/is-trial`、`grep /etc/init.d/boot`。沒有寫入、沒有重開、沒有 bluetoothctl。

## 0. 結論

**判定:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 12 MINOR。**

- **round-8 的 MAJOR(A8-M1/B8-M1)已經關掉。** 我逐一對過每個解凍入口:F1/F2/F2b 失敗、F3 rc 10 重試後、cancel、重新發起、helper 啟動表。每一條現在都要求「持 `reset.lock` + 鎖內重讀 = `none` + 沒有孤兒」。W 階段與 `.locked` 觸發都不解凍。B8-M1 的情境(rc 11 → F4 → 讀不到 → cancel)會落在 `reset-uncertain`,cancel 被拒,修法成立。
- **但修法本身多做了一步(B9-M1):** v9 把 `unreadable` 當成「重置可能進行中」,而且**不需要任何本地跡象**:
  - batdata-mount 遇到 `unreadable` 就上鎖(v8 沒有這條),上鎖的同時 touch `.locked`;
  - helper 在 marker 不在時遇到 `unreadable`,也判 `reset-uncertain`。

  結果是,從沒做過重置的節點,只要 p5 讀不到(沒有 p5 的單槽 image、LUKS p5、p5 壞了),就會被上鎖、OTA 被拒。之後 p5 一旦讀得到 `none`,`.locked` 觸發就把這台健康節點的 overlay 清掉。修法是局部的:「本地有跡象才凍結」。
- **其他都是 MINOR。** 最需要先處理的兩條:
  - `reset.lock` 由 helper 在 F0 拿著,F3 又呼叫 config-save 去拿同一把鎖(m1)。照文件實作會自己卡死:F3 每次都回 rc 10,恢復出廠永遠做不成。這是 fail-safe,不會丟資料,但功能完全不能用。
  - 96 的上鎖提示集合不含 `resetting`(m4),所以 v9 為 A8-m5 加的修法實際上沒有作用。

## 1. 先補:缺的生命週期列與資源

| 缺的路徑 / 資源 | v9 的行為 | 對應 |
|---|---|---|
| 從沒重置過的節點,p5 讀不到(壞卡、LUKS、無 p5 的單槽 image) | S11 上鎖 + touch `.locked`;helper `reset-uncertain`;precheck 拒 OTA;cancel 被拒 | **M1** |
| 同上,之後 p5 讀到 `none` | 「無意圖但 `.locked` 在」→ jffs2reset 一台從沒重置的節點 | **M1** |
| helper 在 F0 持 `reset.lock`,F3 子程序 config-save 拿同一把鎖 | 兩個不同的 open file description → `flock -n` 失敗 → rc 10 → 重試 60 s → 解凍 `p5-busy` | m1 |
| fresh 開機 W1 失敗(96 上鎖)→ 下一次非 fresh 開機 W1/W2 成功 | W3「見下」語意不明:補清若只在下一次 `boot()` 開頭做,這次開機就停在「unclaimed、上鎖、沒 key」,直到有人斷電重開 | m2 |
| `.locked` 觸發時 overlay 刪不掉(唯讀、unlink 失敗) | `overlay_delete` 是 void、`unlinkat` 的錯誤被忽略 → `.locked` 留著 → 每次開機都在 S11 重開,沒有上限 | m3 |
| W2 被斷電打斷(p5 變垃圾),而 W1 已經在新 p6 寫了 `last_known_state=resetting` | 96 的提示集合是 {claimed, member} → 不上鎖 → 4b | m4 |
| 95 uci-default 呼叫 `"$INIT" boot`(fresh)vs S11 rc 呼叫(非 fresh) | 兩者是同一個 `boot`,文件沒寫 batdata-mount 怎麼分辨 → L 的寫者可能和 96 重疊 | m5 |
| rc 12 接手的意圖 slot ≠ active,或意圖是 `bad` | 「讀出 nonce、改用它、F4–F5」沒有分支 | m6 |
| L58 降版 | 只寫在 §13,§5 矩陣沒有這一列;之後再升回來會延遲執行 W | m10 |
| 解凍做到一半 crash | 重做時 `mv -T apps.reset apps` 會失敗(來源已不在);重新發起要把 marker 寫回 step 1,和「只增不減」衝突 | m11 |

## 2. MAJOR

### B9-M1 — `unreadable` 不看本地跡象就上鎖、凍結、touch `.locked`:沒重置過的節點被鎖、OTA 被拒;等 p5 恢復可讀,`.locked` 觸發清掉它的 overlay

**證據(v9 文件本身)**:
- `:240` W 表第一列:「`unreadable` → 今天的流程 + **上鎖(L)**;helper → `reset-uncertain`」。v8 同一列是「今天的流程(96 依 `last_known_state` 上鎖)」,batdata-mount 自己不鎖(v8 §4.5)→ **這是 v9 新加的**。
- `:251` L:「兩者都 touch `.locked`」;`:249` boot() 開頭:「**沒有意圖、但 `.locked` 存在** → dot sweep + `jffs2reset -y` + 重開」。
- `:224` helper 啟動表:「掛 | **任意** | `unreadable` → `reset-uncertain`:凍結,不解凍、不 cancel」。marker 是「任意」,所以 marker 不在也算。
- 和自己的 §1.4 矛盾:
  - `:77` 的 `reset-uncertain` 定義是「**marker 在**、p5 `unreadable`」;
  - `:79` 的 `unknown` 是「p6 `prov-state` ∈ {claimed,member} → 上鎖;**否則不動**」;
  - v4(仍以「同 v4」繼承)`254-stage1-impl-v4.md:181-183`:rc 1/8 → `unknown(p5-unreadable)`「沿用 overlay」;rc 11 無 p5(單槽 image)→ `unknown(no-p5)`;rc 12 → `unknown(p5-not-ext4)`。
- 解析器的輸出(`:235`)只有 `none / intent / bad / unreadable(mount 失敗或讀錯誤)`,沒有「無 p5」「非 ext4/LUKS」→ 這兩種都會落到 `unreadable`。
- 現行程式碼對這三種都**刻意 fail-open**:
  - `batman-slot:531`:「a Secure-tier LUKS p5 … or an opaque one is SKIPPED, never blocked」;
  - 96 `:67`/`:71`/`:89`:image defaults;
  - autocommit `:390-394`;
  - `p5-config-partition.md`:「the reference node has no p5」。

**情境**:
1. **A/B 節點,沒做過重置,p5 壞了**(SD 老化,p5 區域讀錯):
   - 非 fresh 開機,S11 解析器 → `unreadable` → batdata-mount 上鎖:`PasswordAuth=off`、`ttylogin=1`,root 無 hash 時 `root:!`,並 touch `.locked`;
   - helper → `reset-uncertain` → `precheck-node` 拒 OTA(`:77`),cancel 被拒。
   - 以前這台照常運作,只是 p5 不跟著更新。
2. 操作員用 key 登入修 p5(`--seed --reformat`:`batman-config-save:174-192`,marker 不在所以允許)→ p5 變成空的 ext4 = `none`。
   - 下一次開機:「沒有意圖、但 `.locked` 在」→ **jffs2reset 掉這台從沒重置過的節點的 overlay** → 重開。
   - 不在 p5 PRESERVE 裡的 overlay 狀態全部消失:dhcp/firewall 改動、`/etc/batman-dev-open`、`.txn`、額外安裝的套件、payload 的 `/etc` 設定、rc 連結等。
3. **沒有 p5 的單槽 image**(v4 rc 11 那一類)與**Secure tier 的 LUKS p5**:每次開機都 `unreadable` → 每次開機都上鎖、`reset-uncertain`,永遠不會好。
   - 只靠密碼登入的節點遠端就救不回;
   - `--seed --reformat` 對 LUKS 也不適用(會 mkfs 掉加密 p5,config-save `:104-107` 明文禁止)。
- **是否 MAJOR**:照文件實作,會丟掉健康節點的 overlay 資料,也會讓沒有 key 的節點遠端救不回。觸發只需要 p5 讀不到,和重置無關。
  - 但 F3 本來就不可能寫進「無 p5 / 非 ext4 / LUKS」的 p5:前置條件 `:191` 要求 ext4、非 LUKS。
  - 所以把這三種當成「可能有意圖」,沒有任何安全收益。

**修法**(局部,不加機制):
1. 解析器輸出分開:
   - 無 p5 塊裝置 → `n/a`;
   - magic ≠ ext4(含 LUKS)→ `n/a`;
   - ext4 但掛不起或讀錯 → `unreadable`。
2. **凍結 / 上鎖 / `reset-uncertain` 只在「本地有跡象」時套用**。跡象 = 以下任一:
   - p6 marker 在;
   - overlay 哨兵在;
   - `.locked` 在;
   - p6 `prov-state` 的 `last_known_state=resetting`。

   沒有跡象 → v4 的 `unknown(...)`:今天的流程,不上鎖、不碰 `.locked`。

   B8-M1 的情境一定留下 p6 marker(F4 不刪 p6);W1 之後的情境有 `resetting` 提示(配合 m4)。所以修法不會把 round-8 的洞打開。
3. `.locked` 只在「因為意圖、壞意圖或有跡象而上鎖」時 touch。觸發條件「沒有意圖」明寫成**解析器 = `none`**(不含 `n/a`、`unreadable`)。
4. **負對照**:
   - 白箱讓 p5 掛不起、p6 沒有 marker → 斷言:沒有上鎖、沒有 `.locked`、helper 判 `unknown(p5-unreadable)`、precheck 與今天相同。照 v9 字面:上鎖 + `reset-uncertain`(FAIL)。
   - 接著讓 p5 變回 `none` 開機 → 斷言 overlay 沒被清。
   - 正對照:marker 在 + `unreadable` → `reset-uncertain`、cancel 被拒(= v9 的 (o))。

## 3. MINOR

**m1 — `reset.lock` 自鎖:helper F0 持鎖,F3 子程序 `--reset-intent` 再拿同一把** — **PR-P1 必帶**
- `:201` F0「取 `reset.lock`」→ F0–F5 都持有;`:185`「`--reset-intent` 自己也持這把鎖」;`:211` rc 10 包含「`reset.lock` 忙」。
- flock 鎖在 open file description 上。子程序自己 `open` 拿到的是另一個 OFD,`flock -n` 會失敗 → 每次都回 rc 10 → 重試 60 s → 解凍、`E_RESET(p5-busy)`。
- 04 的 busybox `flock [-sxun] FD | { FILE [-c] PROG ARGS }`(實測)支援 FD 形式。
- **修法**:helper 把持鎖的 fd 傳給 config-save(繼承同一個 OFD),config-save 對繼承的 fd 呼叫 `flock -n` 會成功。好處是 helper 被 `kill -9` 時,鎖仍由孤兒持有,U 第 1 條自然成立,第 3 條變成備援。另外要寫明:
  - 解析器 `reset-intent.sh` **不取** `reset.lock`,由呼叫者負責。否則 helper 在鎖內呼叫解析器又會自鎖;
  - helper 呼叫 F3 之前,要先卸掉自己的 p5 ro 掛載(T11)。
- 負對照:正常 F3 → rc 0(照字面會是 rc 10);(q) 照舊。

**m2 — W3「若 `.locked` 存在 → 見下」語意不明;只在下一次 `boot()` 開頭補清,會讓節點停在「unclaimed、上鎖、沒 key」直到有人斷電** — **PR-P1 必帶**(Q5)
- `:247`、`:249`「W3 不再自己判斷」。如果照字面只在下一次開機開頭補清:
  - fresh 開機 W1 失敗、下一次 W2 成功的那次開機,會一路開到 S19,狀態是上鎖、沒有 key;
  - 沒有人會讓它重開。04 遠端沒有 key,也送不出 reboot。
- **修法**:W2 成功且 `.locked` 在 → **同一次開機**立刻呼叫同一支「補清 + 重開 + return」。boot() 開頭那一條保留,當作斷電後的後備。負對照 (s) 改成同時斷言「同一次開機就重開」。

**m3 — `.locked` 觸發的「不會迴圈」靠 jffs2reset 真的刪掉它,但 jffs2reset 不回報刪除失敗** — **PR-P1 必帶**
- 證據:
  - fstools `jffs2reset.c:44-55`:掛載中 → `overlay_delete(mp, keep)`,這個函式是 `void`,之後 `return 0`;
  - `libfstools/overlay.c:43-68` 的 `handle_rmdir` 不檢查 `unlinkat` 的回傳值。
  - 04 的 overlay 是 `/dev/loop0 f2fs … errors=continue`(實測)。
- overlay 唯讀或 unlink 失敗時,`.locked` 留著 → 每次開機都在 S11 重開。這發生在 dropbear(S19)之前,遠端進不來,也沒有上限。W0 有 attempts ≤ 3,這條沒有。
- **修法**:jffs2reset 之後 `[ -e /overlay/upper/etc/batman-reset.locked ]` 仍在 → crit `reset-stuck locked-clear`、不重開、維持上鎖。負對照:seam 讓刪除失敗 → 斷言只重開 0 次。

**m4 — 96 的提示集合不含 `resetting`,W1 寫的 `last_known_state=resetting` 沒有作用** — **PR-P1 必帶**
- `:245` W1:「寫 `last_known_state=resetting`,讓 W2 被打斷時 96 仍上鎖(A8-m5)」。
- 但 `:171` 96 的規則是「讀不到 p5 而 `prov-state` 第 3 欄 ∈ {claimed,member} → 上鎖」。W2 被斷電打斷 → p5 不是 ext4 → 96 `:71` 出口 → 提示 `resetting` ∉ 集合 → 4b(image 預設空密碼 root)。
- **修法**:集合改成 {claimed, member, resetting}。這時要 touch `.locked`(依 M1 第 3 點,這屬於有跡象的上鎖)。負對照:白箱讓 W2 在 mkfs 中途斷電 → 斷言 96 上鎖。

**m5 — batdata-mount 怎麼知道這次是不是 fresh,文件沒寫;L 的三個寫者「時段不重疊」靠它成立** — **PR-P1 必帶**
- fresh 開機時,`boot()` 由 95 的 uci-default 呼叫(`95:794` `"$INIT" boot`;04 `/etc/init.d/boot:7-17` 依 `ls` 順序以 `( . ./file )` 執行:95 → 95-morse → 96);S11 那次不會跑(「the S11 link was created after rcS enumerated it」)。非 fresh 開機則由 S11 呼叫。兩條路呼叫的是同一個 `boot`。
- v7 刪掉 `BATMAN_FIRSTBOOT` 時,理由是「W 不需要知道」。但 L(`:251`)需要知道:batdata-mount 如果在 fresh 開機也套用 L,96 接著依 4b 改寫同一批欄位,就是兩個寫者。
- **修法**:寫明判斷方式,例如「`/etc/uci-defaults/96-batman-config-migrate` 還在 = fresh(由 96 負責)」,或由 95 傳 env。這樣 §3「三者時段不重疊」才有根據。

**m6 — rc 12「接手既有意圖」的分支不完整** — **PR-P1 必帶**
- 要寫明的分支:
  - 既有意圖 slot ≠ active → 依啟動表的「slot 不符」那一格,**不做 F4**(否則清掉本槽 overlay 之後,Wa 會一直等);
  - 既有意圖是 `bad` → 凍結、bench(沒有 nonce 可以接手);
  - 「改用它的 nonce」→ marker 和哨兵要不要一起改寫?W0 只看哨兵在不在,不比 nonce。
- 另外,rc 12 在什麼情況下會出現?前置條件已在鎖內讀到 `none`,所以 rc 12 只剩防禦用途。照實寫明,免得實作者以為它是常見路徑。

**m7 — 文件互相矛盾(實作照錯的那一份就是 bug)** — **PR-P1 必帶**(其中 marker 那一項會重開 A8-m7)
- §4.3 `:160`:`--reset-intent` 寫「rc 只有 0/10/11」,而且「`cfgsave.lock` 忙 = 10」;§4.5 `:209-211` 寫的是 0/10/11/12、`reset.lock`。
- §3 `:116`:marker 寫成「`<nonce> <step> <reason>`;**flock 鎖這個檔**」;§4.5 `:195` 寫的是 `<nonce> <step> <f3> <resume_n>`、0600、鎖在 `reset.lock`。照 §3 實作 = A8-m7(非 root 可以搶 flock)。
- §3 `:109` `.factory-reset` 的寫者沒有列 W1 的 `p6uuid` 改寫;§3 `:117` 哨兵的刪除者仍寫「F3 rc 10 的撤銷」,沒有改成「U 成立的解凍(含 cancel)」。
- §1.4 `:76` `resetting-pending` 那一列欄位錯位;§4.1 `:138`「resetting 模式下只放行它與 `factory_reset`」和 §1.4 `:78`(`resetting` 只開 `status/public`)、§4.5 `:227` 互相矛盾。
- R43 `:32` 仍寫「**任何層級**的 dot 項目都不刪」,§13 說已更正但其實沒改。fstools 的 `handle_rmdir` 會 `unlinkat` 所有非目錄項目,dot 檔照刪;`foreachdir` 的 glob `*` 不進 dot 目錄。正確的說法是:**dot 目錄**(含裡面的東西)不刪。
- §5:L16 `:276` 仍寫「§4.5 v8、(a)–(n)」;L37 `:284`「F 階段失敗 → 撤銷」、L48 `:289`「可 cancel」都沒有加上 U 的條件。
- 負對照 (m)(同 v8)仍用 `reset-p6-wiped` 和「W3 再清」,v9 已經換成 `p6uuid` 和 `.locked` 觸發。

**m8 — `p6uuid` 的讀法與格式**
- 04 的 `/usr/sbin/blkid` 是 util-linux 版,有 `/run/blkid/blkid.tab` 快取(實測)。W1 在 mkfs 之後如果用快取讀 UUID,可能讀到舊值。後果只是下一次多 mkfs 一次 p6,不會略過該做的清除,但要寫死不用快取的讀法:`blkid -p -s UUID -o value`(04 有 `-p`),或 `-c /dev/null`。更簡單的做法是 `mkfs.ext4 -U <自己產的 uuid>`。
- 解析器對 `p6uuid` 只寫「36 字元」,要加字元集 `[0-9a-f-]`,不合就判 `bad`。
- 「新 UUID 寫回意圖」失敗時怎麼做,沒有寫(建議:crit、不做 W2,下次重來;重來只是重清已空的 p6)。
- LUKS 或沒有檔案系統的 p6:`blkid` 回空值或 crypto_LUKS → 不相等 → mkfs。這是對的(前置條件本來就排除 LUKS p6)✅。

**m9 — F3 的 tmp 檔與解析器在 ash 裡的實作細節** — PR-P1 程式碼審查要檢查
- tmp 檔用固定名稱,寫之前先 `rm -f`,**絕不 rename 一個本來就在的 tmp**。殘留的 tmp 由 W2 的 mkfs 一起清掉。
- 解析器用 `set -- $line` 切欄位之前,要先 `set -f`,否則 `*` 會被 glob 展開;「恰好一行」用 `wc -l` 判斷。
- 實測可行:busybox `fsync [-d] FILE` 可以對目錄 fsync,`readlink -f` 也有。`${#n}`、`case *[!0-9a-f]*` 在 ash 都能用 ✅。

**m10 — L58 降版沒有進 §5 矩陣;「之後再升回來」的後果沒寫;`-F` 其實擋得住**
- §13 描述了降版當下的情況,但沒有寫降版之後:
  - 舊 image 不認得意圖,precheck 不擋 → 之後升回新 image,槽相符 → W1/W2 會在幾週後執行,清掉降版期間 p6 的內容;
  - 舊的 96 會從 p5 還原前任的 `authorized_keys` 和 shadow。
- 現有的 #202 機制(`$RUNDIR/p5-check.rc`,讓 stage-2 在 `sysupgrade -F` 下也照樣執行)可以照抄:「marker 或意圖存在」→ stage-2 拒絕。這樣降版就只剩直接呼叫 `batman-slot apply` 加 override 這條路。
- 補一列 L58 和它的負對照。

**m11 — 解凍要冪等;重新發起與「step 只增不減」衝突**
- 解凍順序是 `mv -T apps.reset apps` → 刪標記 → 刪哨兵 → 刪 marker。中途 crash → 再次解凍時 `mv` 的來源已經不在。要寫明「`apps.reset` 不在、`apps` 在 → 這一步跳過」。
- 重新發起(`:228` 從 F0 開始)會把 marker 寫成 `<新 nonce> 1 - 0`,和 `:195`「`step` 只增不減」矛盾。要寫明:U 成立之後才允許整份換掉。

**m12 — S11 的 L 寫 `lock-status`「若 p6 有掛」,但 `unreadable` 那條路之後才掛 p6 → `halow-status` 顯示舊值**
- 修法:掛上 p6 之後補寫一次,或交給 helper 在 S89 重寫。

**PR-P1 必帶**:M1 + m1、m2、m3、m4、m5、m6、m7(至少 §3 marker、§4.3 rc 表兩項),各附負對照。m8–m12 可以在實作和程式碼審查時處理。

## 4. 指定重點逐項

| 項 | 結論 |
|---|---|
| U 套到每個解凍入口 | F1/F2/F2b 失敗 ✅、F3 rc 10 重試 ✅、cancel ✅(`:227`)、重新發起 ✅(`:228`)、啟動表 ✅(含 f3 欄)、W 階段不解凍 ✅、`.locked` 觸發不解凍 ✅。round-8 的 MAJOR 已關 |
| U 會不會讓健康節點卡死 | **會**:`unreadable` 沒有跡象門檻(M1)。有跡象時永久讀不到的 p5 → 永遠凍結,出口只有 bench,文件有寫(§11、Q5)✅;另外 m1 讓每次 F3 都卡死 |
| F3 rc 0/10/11/12 以 `rename(2)` 為界 | 判準正確,可以實作;tmp 同目錄 + fsync + rename + fsync 目錄 ✅(04 有 `fsync -d`)。tmp 命名與殘留(m9);§4.3 的 rc 表沒更新(m7);rc 12 分支(m6) |
| ash 解析器的各項檢查 | 全部可行(`-f`、`! -L`、`head -c 65`、`wc -l`、`${#}`、`case *[!0-9a-f]*`);要加 `set -f`(m9);要分出 `n/a`(M1) |
| `p6uuid` 用 blkid | 不掛載、前任無法預先種 ✅;快取(m8);LUKS 或沒有檔案系統 → 不相等 → mkfs ✅ |
| `.locked` 當獨立觸發 | 只有 root 寫得了(`/etc`)✅;正常情況不會迴圈 ✅;刪除失敗會無限迴圈(m3);W3 同一次開機的語意(m2);`unreadable` 上鎖也會 touch 它 → 清掉健康節點的 overlay(M1)。另一個寫者:`sysupgrade -o` 或 LuCI 的「含所有修改檔」備份還原,會把 `.locked` 和哨兵一起帶回來(低,建議加進排除清單) |
| batdata-mount 在 S11 上鎖 vs uci commit | S11 的 `uci commit` 早於 S19 dropbear ✅;fresh 開機時 uci-default 結束後由 `/etc/init.d/boot` 統一 `uci commit`(04 實測 `boot:16`)✅;fresh 和非 fresh 的判斷沒定義(m5) |
| L58 降版 | 見 m10 |

## 5. v8 發現 → v9 核對(一條一行)

| v8 | 判定 | 說明 |
|---|---|---|
| A8-M1 | addressed | U + 啟動表 + (o)(p)(q);但範圍擴大過頭,見 B9-M1 |
| A8-m1 | partial | §4.5 以 rename 為界 ✅;§4.3 `:160` 仍是舊的 rc 表(m7) |
| A8-m2 | addressed | 不用 noload、私有掛載點、`unreadable` 分開、T11 可重試;讀者清單沒列 autocommit(它的 `:394` 自己掛 p5,只看 `.seeded`,影響小) |
| A8-m3 | addressed | 逐欄檢查、`*[!0-9a-f]*`、恰好一行;`p6uuid` 字元集(m8) |
| A8-m4 | addressed | `reset.lock` + S11 序列執行 |
| A8-m5 | partial | 兩個上鎖方都 touch ✅、獨立觸發 ✅;W1 的 `resetting` 提示沒作用(m4);W3 同一次開機(m2);刪除失敗會迴圈(m3) |
| A8-m6 | addressed | joinwatch 只看 marker;寫 p6 之前查 mountpoint |
| A8-m7 | partial | §4.5 ✅;§3 `:116` 仍寫「flock 鎖這個檔」(m7);新的自鎖(m1) |
| A8-m8 | partial | 加了 `.locked`、`reset.lock`、batdata-mount ✅;marker 格式、W1 `p6uuid` 寫者沒更新(m7) |
| A8-m9 | partial | §6.4 pgrep ✅、§4.3 `last_known_state` ✅;§4.1 / §1.4 的 cancel 文字、R43 沒改(m7) |
| A8-m10 | partial | L58 只寫在 §13、升回來的後果沒寫(m10);S11 走 shutdown 的證據仍是 ⚠️ |
| A8-m11 | addressed | `readlink -f` 以 cwd 解析;負測試加了兩項 |
| A8-m12 | addressed | 有 root 的前任、卡住的節點接受前任 key |
| B8-M1 | addressed | 同 A8-M1;副作用見 B9-M1 |
| B8-m1 | addressed | 96 也 touch;W3 的語意見 m2 |
| B8-m2 | addressed | 同 A8-m4 |
| B8-m3 | partial | rc 12 + rename 判準 ✅;§4.3 沒更新(m7);rc 12 分支(m6) |
| B8-m4 | addressed | T11 → rc 10 可重試 |
| B8-m5 | addressed | `resume_n` ≤ 3、(t) |
| B8-m6 | partial | journal、掛載點、限制都寫了 ✅;「本地有跡象才讀」的緩解沒採用 → B9-M1 |
| B8-m7 | addressed | §6.4 統一、相對路徑 |
| B8-m8 | partial | 同 A8-m8 |
| B8-m9 | addressed | 寫 p6 之前查 mountpoint;啟動表第一列 |
| B8-m10 | addressed | 改用 `p6uuid`;快取見 m8 |
| B8-m11 | addressed | 改成「是 tmpfs」(`:191`、`:243`) |
| B8-m12 | partial | (o)(r) 和 app 文字 ✅;§5 矩陣沒有 rc 11 三種結果的列 |

## 6. 逐 actor

- **BLE 路人 / 只看過 QR 的人**:本輪沒有變化 ✅。
- **本機非 root 程序**:`reset.lock` 在 `/tmp/run/batman`(04 實測 `drwx------ root`)碰不到 ✅;marker 0600 ✅,前提是 §3 的文字要跟著改(m7)。
- **被入侵的 tenant 或容器 root**:不在主機的 pid ns,假冒不了孤兒 config-save(U 第 3 條)✅。
- **被入侵的 provd**:cancel 和重新發起都要 owner-op ✅;provd 唯一的影響是讓動作回 `E_BUSY` 這類 DoS。
- **前任擁有者**:成功路徑全清 ✅;`p6uuid` 由這次 mkfs 產生,無法預先種 ✅;有 root 的前任可以自己在意圖行寫 `p6uuid`,這已在誠實界線內。降版後舊 96 會還原前任的 key(m10)。
- **實體 SD**:放壞意圖 → Wb 上鎖(DoS,和重燒卡同級)✅;讓 p5 變成讀不到 → B9-M1(健康節點被鎖、之後 overlay 被清)。
- **供應鏈**:沒有新的依賴。
- **我們自己**:B9-M1(修法擴大過頭)、m1(自鎖)、m4(集合漏一個值)、m7(文件矛盾)。

## 7. 使用者決策的後果(不重開,只列)

- **Q5(L16 在 04)**:
  - m2 不修的話,04 只要 fresh 開機的 W1 失敗過一次,下一次就算 W2 成功,也會停在「上鎖、沒有 key」,直到現場斷電;
  - m1 不修的話,L16 會一直回 `p5-busy`(安全,但白跑一趟);
  - 04 的 p5 健康(`blkid` 有 ext4 UUID,實測),B9-M1 對 L16 本身沒有影響。
- **U4 全清含身分**:沒有新的後果。
- **U6 3A+ / 其他平台**:B9-M1 的修法同時涵蓋 LUKS p5(Secure tier)和沒有 p5 的單槽 image。這兩種平台**是否仍然出這個 feed**,我沒有查證(⚠️ 推論)。

## 8. 本輪唯讀探針(原始輸出摘要)

```
04 blkid --help: 有 -p/--probe "bypass cache"、-c /dev/null;/run/blkid/blkid.tab 存在(1395 B)
04 blkid /dev/mmcblk0p5: LABEL="batconfig" UUID="9af5c61f-…" TYPE="ext4" PARTLABEL="config"
04 blkid /dev/mmcblk0p6: LABEL="batdata"   UUID="254e7c3f-…" TYPE="ext4" PARTLABEL="data"
04 flock --help: Usage: flock [-sxun] FD | { FILE [-c] PROG ARGS }
04 fsync --help: Usage: fsync [-d] FILE...;readlink: -f 有
04 ls -ld /tmp/run/batman: drwx------ root root
04 /proc/mounts: /dev/loop0 /overlay f2fs rw,…,errors=continue;/dev/mmcblk0p6 /opt/batdata ext4;/opt/batdata/docker 同 p6
04 batman-slot active = B;is-trial rc=1
04 /etc/init.d/boot:7-17 uci_apply_defaults: for file in $(ls); ( . ./file ) && rm -f; 結束 uci commit
04 /rom/etc/uci-defaults: … 95-batman-storage, 95-morse-wireless-defaults, 96-batman-config-migrate, 97-…
fstools jffs2reset.c:44-55 掛載中 → fs_state PENDING + overlay_delete(void) + remount;return 0
fstools overlay.c:43-68 handle_rmdir:unlinkat 所有非目錄項目,不檢查回傳;:97 glob "*" 不含 dot 目錄;:444-454 PENDING → 下次開機 overlay_delete
95-batman-storage:630-632 boot():[ -b PART ] || return 0 → mount p6 → 閂;:794 "$INIT" boot
batman-slot:531 LUKS / opaque p5 SKIPPED, never blocked;batman-config-save:104-107 絕不 mkfs 非 ext4 p5
254-stage1-impl-v4.md:181-183 rc 1/8 → unknown(p5-unreadable);rc 11 無 p5(單槽 image)→ unknown(no-p5);rc 12 → unknown(p5-not-ext4)
v8 §4.5 W 表:「unreadable → 今天的流程(96 依 last_known_state 上鎖)」(batdata-mount 不鎖)
```
