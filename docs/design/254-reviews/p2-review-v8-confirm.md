# #254 PR-P2 `batman-provd` 設計 v8.1 — 減法確認審查(單一審查員)

範圍(依指示,窄):只確認 v8 砍掉的三個機制沒留下洞、live 章節沒有殘留對已砍機制的依賴、§1.3 簡化後的 reconcile 規則對 helper 原始碼成立。不提新機制。

## 0. 我自己核過的(✅ 原始碼 / 實跑;⚠️ 推論;❌ 未驗)

| # | 事實 | 證據 |
|---|---|---|
| V1 ✅ | Batman `/home/yello/Batman` = main `34f216d`(#316);firmware `/home/yello/firmware-2710` = `da30986f`(rc wsl.17 pin 34f216d) | `git log -1` |
| V2 ✅ | `psk_owner` 一把一個 owner、由 `o.TagKey` 導出:`for _, o := range rec.Owners { owners = append(owners, proto.PskOwner(o.TagKey, dev)) }`;`psk_replay` 只在 `len(rec.Owners) == 1` 時由 `ECDH(Owners[0].EncPub)` 導出;`psk_member` 綁 `Net.NetID, Net.Version` | `node.go:392-411` |
| V3 ✅ | `applyNet`(join / update)`next := *rec` 後只改 `Generation / State / RadioManaged / Left / Admins / Net`,**不碰 `Owners`**;`leave` 同樣不碰 `Owners`(只清 `Net / Members / Admins`、`Left=true`) | `node.go:1132-1139`、`1191-1195` |
| V4 ✅ | `ownerRemove`:以 `kid == sha256(o.Pub)` 濾掉、拒刪最後一位、`AdvOwnerKey` 輪替、`Generation++`、`commit` | `node.go:885-908` |
| V5 ✅ | `ownerAdd` 對已存在的 pub = **輪替該 owner 的 TagKey**(pub 不變、`psk_owner[i]` 值變)、`Generation++` | `node.go:862-878` |
| V6 ✅ | `claimVerify` 只在 `state ∈ {Legacy, Unclaimed}`(`:525`)→ 認領永遠來自 NX 匿名 session;成功後 `Owners = [{ownerPub, encPub, tag}]`、`Generation+1`、**回應前** commit | `node.go:525, 547-553` |
| V7 ✅ | `claimReplay` 以**已存的** `rec.Owners[0].Pub` 驗 owner-op 與 CheckMac(app 在 begin 送的 `owner_pub` 不進驗證)、不 commit | `node.go:610-622` |
| V8 ✅ | `owner_key_id` = SHA-256(owner_pub 65 B)(協定);helper `ownerRemove` 用同一定義 | `docs/design/219-protocol.md:201`;`node.go:889` |
| V9 ✅ | `info.state` 回 `{state, Generation, len(Owners), RadioManaged}`;`dispatch` 無 record 只放行 `info.cert / info.ecdh_pub / info.boot_id / nonce` | `node.go:206-208, 231-235` |
| V10 ✅ | `sock.go` 今天仍是單連線 `Serve`(`:108-116`)、`serveConn` 每次 `Read` 前武裝 `Idle` deadline、`h(m)` 同步(`:144-170`)= F-P6 / F-P45 | `sock.go` |
| V11 ✅ | `build-board.sh` 真有「4 stamp」一步(`:140-142`,接著 5 make);feed 樹 `feeds/batman/scripts/dv/` 存在(Batman feed 根 = repo 根)→ §4.8 的 `cmp target/… feeds/batman/scripts/dv/data/…` 路徑成立;`scripts/dv/data/` 今天不存在(H3 PR 帶進來,與 §4.8 一致);`patches-6.6/` 已有 4 個 `999-batman-*.patch`(含兩個 `-305`)= 範式成立;`scripts/patch-kernel.sh` 套不上 → `exit 1`(patch 進了樹就一定套上,否則 build 死) | firmware 樹 |
| V12 ✅ | F-P61 的三處 `svc stop joinwatch batman-provhelper batman-provd` 在 `scripts/node/prov-base-254.sh:207, 222, 258`;`:272` `svc start batman-provhelper joinwatch` 漏 provd;repo 零 `start batman-provd`;`ble_state`(`scripts/node/ble-lib-254.sh:151-170`)在 `adv_instances != 0` 時 `fail "leftover: … advertising instance(s)"`;`ble-periph-254.sh:45,52,171` 無條件 `rm-adv 1` | Batman main |
| V13 ✅ | live 章節(§0–§12)grep `expectGen / inFlight / pendingReconcile / QUEUE_WAIT / DV_FW_TREE / DIRTY_WHY / FW_COMMIT_FULL / 臂 2 / instance 5 / KPATCH / L82`:只剩 §1.3 撤銷列與 §4.8 兩處「v5–v7 的 … 已砍」的歷史指涉(合法)、§3 狀態行;**沒有** live 文字依賴它們。`btmon` 在 live 章節只用於 F-P41 le_states 見證(L80 / §6),不是臂 2。§13–§18 的提及為歷史 | grep |
| V14 ⚠️ | 第 7 輪兩位審查員的發現:A-M3(commit id、只動 `eir_create_adv_data`)、A-M2 / B-M4(`ble_state ≤ 1`、刪 `provd.env` 一律 restart、`prov-base:272` 補 provd)、B-M3(`HELPER_WAIT` 到期不釋放 `ops`)、A-m4(`ops` 一次一則硬規則)已進 v8;A-M1 / B-M2(基準重設)、B-M1(hold 型臂 2)、B-m2 / m6 / m7、A-m2 / m3 / m6 / m7 / m9 隨機制一起砍、不再適用;**A-m1(D9 刪)只改了 §7,別處沒跟(→ 發現 1);A-m8 的「§6 最後一列改成兩個 id」沒做(→ 發現 2)** | 比對 v7 兩份與 v8 |

## 1. 三處減法逐一確認

### 1.1 砍「臂 2」(節點端 kernel patch 見證)與其閘門

- **原本擋什麼**:證明「節點正在跑的 kernel 含 D3 patch」(image 出自哪棵樹、pin 沒漂、patch 真進了 kernel 二進位)。
- **留下的能不能接住**:build 時 `cmp`(V11)證明 `target/…/999-…-254.patch` 與 pinned Batman 正本逐位元組相同;`KERNEL_FILE_DEPENDS` 含 `$(PATCH_DIR)`(F-P47)讓 patch 檔變動必重 prepare;`patch-kernel.sh` 套不上即 `exit 1`(V11)→ 「patch 在樹裡但沒套進 kernel」這條在 build 階段 fail-closed。**接不住的**只剩「節點上正在跑的 image 是不是那個 build」——§4.8 明寫「節點端沒有正向見證」、§11 殘項列了、§8 攻陷 provd 列的負測試改成「build 時 cmp」、L68 / §9 都寫「節點端不做」。誠實界線到位,不是洞:它與既有 #275 board-patch 見證同層(#275 也只證 rootfs 內容,不證 kernel 二進位),而 F-P10 實跑紀錄是 n=1 的負對照。
- **殘留**:§6 最後一列仍寫「上游 CVE 修法 commit | 待查 | ⚠️ D3 核准後」,而 §4.8 已釘 `47c03902…` + `6f5fb689…`(發現 2)。**D9「`-wbox` 變體加 `btmgmt`」在 §7 改「不做」,但 §1.3、§2、§9 release gate、§12 四處仍寫要加 / gate 斷言「`-wbox` 變體相反」**(發現 1)。這不是臂 2 的洞,是 v8 折進 A-m1 時沒改完。

### 1.2 砍「旁路 gen 變化 → 全斷」+ `expectGen / inFlight / pendingReconcile`

- **原本擋什麼**(A4 m3 / B4 m1 的原始需求):(a) root `provclient` 移除 / 換掉 owner 後,被移除者的既有 session 不能繼續當擁有者;(b) `network/leave` / `update` 後成員 session 不能繼續用舊 PSK 身分;加上 v5–v7 多出來的 (c)「不是我改的 gen 變化 → 全斷」。v6–v7 的狀態機全部是為了讓 (c) 不誤殺自家動詞;A7 M1 / B7 M2 證明它仍會誤殺。
- **v8 一條規則對 helper 原始碼逐案核**:
  - 擁有者自己的 join / update / leave:`Owners` 不變(V3)→ `info.owners` 重拉後 `owner_key_id` 仍在集合 → 不斷 ✅。候選 session 以 `psk_owner[i]` 值比對:TagKey 不變(V2 / V3)→ 不斷 ✅。
  - 擁有者自己的認領:認領只能從 NX 匿名 session 做(V6),§1.3「匿名 session 不動」→ 不會自斷;回應後升擁有者,其 `owner_key_id = SHA-256(begin 的 owner_pub)` = helper 存的那把(`:552`)→ 之後每輪 reconcile 都在集合裡 ✅。`ctl` 可能在 `ops` 回應前就看到 gen 變(F-P55)並先 reconcile 一次——那時該 session 仍是匿名,不受影響 ✅。
  - `claim/replay`:不 commit(V7)→ 無 gen 變 → 不觸發;升擁有者後身分 = helper 存的 `Owners[0].Pub` ✅。
  - root `provclient` 移除 owner:`ownerRemove` `Generation++`(V4)→ `ctl` ≤ 4 s 看到 → 重拉 `info.owners`(`ctl`,不取鎖、不在長動詞連線上)→ 被移除者 `owner_key_id` 不在集合 → Disconnect ✅。擁有者 session 這條路**不經 `psks.get`**,所以不會被長動詞拖到 960 s;§1.3 寫的「`psks.get` 排在長動詞後面時到該動詞結束」只對候選 / 成員 session 成立(發現 5 的一句話澄清)。
  - root reset → 無 owners / state unclaimed:二元組變 → 集合空 → 擁有者 / 候選全斷、`psk_member` 消失 → 成員斷 ✅;新連線改 NX ✅。
  - `owner/add` 重加同一把 pub(TagKey 輪替,V5):擁有者 session 不斷(pub 不變)、以舊 `psk_owner[i]` 進來的候選被斷(值變)— 合理(舊 PSK 在 helper 端已失效)。
  - helper 重啟 / `boot.Run` 重寫 record(F-P55):§3 把「`ops` 連線重建」列為獨立失效條件 + L11「全量 reconcile」→ 不靠二元組也會重拉 ✅。
  - F-P62(p5 已 commit、overlay 寫失敗)→ `info.state` 讀 overlay 看不到 → 被移除者留到下一個 owner-op 的 `resolve()` 或重開:§1.3 誠實界線明寫 ✅;改狀態動詞 helper 端以 p5 驗(`node.go:753-761`)→ 被移除者拿不到任何副作用 ✅。
  - 砍掉的 (c) 沒有獨立價值:任何「旁路」變化最終都反映在 owners / PSK 集合,比對集合就夠;唯一 (c) 多擋的是「集合沒變但 gen 變」的 session,那本來就沒有理由斷。
- **沒接住 / 沒寫清的**:`psk_replay` 進來的「擁有者重取」session(交握到 replay 成功之間幾秒)在 §1.3 的四類(擁有者 / 候選 / 成員 / 匿名)裡沒有名字;`psk_replay` 在 `owner/add` 第二位 owner 後**消失**(V2:`len(Owners) != 1` → nil)、在 EncPub 輪替後值變。實作者若把它當候選比對會被斷(無害,app 重新 begin),當匿名就留著(也無害,helper 端 `claimReplay` 會以 `len(Owners) != 1` 拒)。只要寫一句(發現 5)。

### 1.3 砍 `QUEUE_WAIT` / `ops` 排隊

- **原本擋什麼**(B6 M4 / B7 M3):排隊的請求在 app 放棄後才被送進 helper 執行(leave 在 900 s 後離網)。
- **留下的能不能接住**:沒有佇列 → 沒有「過期才送出」;單在飛 + `HELPER_WAIT` 到期不釋放、不送下一則直到真回應或 EOF(§4.3)→ B7 M3 的情境(到期後送出的那一則)也不存在;fake helper 收件計數 1 的單元在 §9 ✅。EOF 時非冪等不重送 → `E_BUSY` ✅。L24「一個 0 一個 7」與 `claimInProgress` 一致 ✅。
- **殘留 / 不清**:§4.3 錯誤碼表「provd 自己產生 … 7(互斥、helper 逾時、**佇列丟棄**、擠槽前)」仍指佇列(發現 3);§4.3「有請求在飛時再來的**改狀態 / 簽章**請求直接回 `E_BUSY`」沒把 `nonce`(`claim/begin`)與 `claim.*` 明說進去,而它們也走 `ops`(發現 4)。內部重拉(`psks.get`、啟動的 `sign.*`)在 `ops` 忙時是「標記、空了再送」(§3 寫了「失效 = 標記待重拉」),§4.3 「`psks.get` 排在它後面」一詞容易讀成佇列,同發現 4 一句話即可。
- 與減法無關、v3 起就有的既有界線(不列為發現):`ops` 對「helper 活著但永遠不回、也不 EOF」沒有上限(`ctl` 的 10 s 重連與 60 s 不新鮮撤廣播只保 STATUS / 廣播)。

## 2. 發現

**1. MAJOR(文字互斥 → 會做出錯的 gate)**:D9 在 §7 已改「不做」,但四處仍寫要加 `btmgmt`:§1.3「h23 §6.3 / §4.8 用 btmgmt」列(「**`-wbox` 變體 image 加裝 `btmgmt`**(bluez-utils 的單一工具,release gate 斷言 …)」)、§2 firmware 列(「`-wbox` 變體加 `btmgmt`」)、§9 release gate(「image 無 `/usr/bin/btmgmt`;… **`-wbox` 變體相反**」)、§12 第 4 步(「firmware(policy、kernel patch、**btmgmt 變體**、pin)」)。照 §9 字面,`-wbox` 變體的 gate 會要求 rootfs **有** `/usr/bin/btmgmt`,而 D9 不裝 → 每個 wbox build 必 FAIL;且 A7 m1 已證 `btmgmt` 在 `bluez-utils-extra` 不是單一工具。
- 修(刪字,不加機制):§1.3 該列只留「節點 release 無 `btmgmt`(F-P4);harness 既有 `ble-periph-254.sh` scp 自帶 btmgmt / btmon(h1 §4.7)」;§2 刪「`-wbox` 變體加 `btmgmt`」;§9 改「image(release 與 `-wbox` 都)無 `/usr/bin/btmgmt`」;§12 刪「btmgmt 變體」。

**2. MINOR(過時)**:§6 最後一列「上游 CVE 修法 commit | 待查 | ⚠️ D3 核准後」與 §4.8(兩個 id、A7 以 `gh api` 核過 diff)不符;改成「✅ `47c03902…` + `6f5fb689…`(A7 V7/V8);實作時再對 linux-stable 核一次」。

**3. MINOR(殘留)**:§4.3 錯誤碼表「7(互斥、helper 逾時、佇列丟棄、擠槽前)」→ 「7(互斥、`ops` 在飛、`HELPER_WAIT` 到期、擠槽前)」。

**4. MINOR(規則寫全)**:§4.3「`ops` 一次只准一個在飛」一句改成:「`ops` 上的任何請求(`nonce`、`sign.*`、`psks.get`、`claim.*`、owner-op)都受此限;手機觸發的在飛時直接 `E_BUSY`;provd 內部的(重拉 `psks.get`、啟動 `sign.*`)只標記,`ops` 空了才送,不排隊」。§4.3 快取段「`psks.get` 排在它後面」改「等該動詞結束後才送」。

**5. MINOR(reconcile 規則補兩句)**:§1.3 撤銷列 (a) 加「`owner_key_id` = SHA-256(owner_pub)(協定 §3.5;helper `ownerRemove` 同定義),與 `info.owners` 回的公鑰以此比對」;(b) 「擁有者重取(`psk_replay`)中的 session 視同候選,以它用的 `psk_replay` 值比對(第二位 owner 加入後該值消失 → 斷,app 重新 begin)」或明寫「視同匿名不動」,二擇一;(c) 「被移除 owner … 常態 ≤ 5 s」後面的「`psks.get` 排在長動詞後面時到該動詞結束」改為「(候選 / 成員 session 靠 `psks.get`,會等長動詞結束;擁有者 session 只靠 `info.owners`,不受長動詞影響)」。

沒有 BLOCKER。三處減法本身都沒留洞:臂 2 的空缺有誠實界線且 build 側 fail-closed(V11);撤銷規則對 `node.go` 的每條改 record 路徑(V2–V7)都不會自斷、會斷被移除者;單在飛把 B6 M4 / B7 M3 兩種「過期才執行」一起消掉。

## 3. 負對照盤點(減法相關,v8 §9 已有的)

- `cache_test`:owners 少一把 → 下一輪被斷(mutant 不重拉 → 不斷)✅;自家 `net.apply` 在飛時 gen +1 → 不斷 ✅;認領 → 立刻 join → 不斷 ✅;成員自己 `update` 回 0 → `psk-rotated` 斷、擁有者不斷 ✅;`ops` 在飛時第二個請求立即 `E_BUSY` 且 fake helper 計數 1 ✅。
- 建議加一臂(不是新機制,是既有單元的 mutant):`claim.verify` 回 0 **之前** fake helper 先讓 `info.state` 回 gen+1(模擬 F-P55 的 `ctl` 先看到)→ 匿名 session 不動、回應後升擁有者、再下一輪不斷。
- build 時 `cmp`:改正本一個位元組 → build 拒(§4.8 已列)✅。

## 4. 判定

**APPROVE-WITH-CHANGES — 0 BLOCKER / 1 MAJOR / 4 MINOR。**

三個砍掉的機制沒有留下需要新機制補的洞;留下的規則我對 helper 原始碼逐路徑核過(擁有者自己的 claim / join / update / leave 不會自斷;被 root 移除的 owner 在下一輪 `info.owners` 到手即斷,且不經長動詞的 `ops`)。唯一 MAJOR 是 D9 折進來時四處文字沒跟上,會做出相反的 release gate;全部是刪字 / 改一句,修完由主 agent 以 grep(`btmgmt`、`佇列`、`待查`)確認即可,不需再開一輪整份審查。04 實機證據(F-P41 le_states、L10 / L11 目錄 bind)仍欠,與前七輪相同,不在本輪範圍。
