# Design: #202 config-survival close-out — p5 永遠跟著 live 設定走 — **v1**

狀態:待兩位獨立審查。根據 2026-10-17 的 reality check 與真機重現(issue #202 留言 6229383727)。
基準:Batman `main` 6a049f2(= 出貨 v1.5.11),節點 02/04 = `1.5.11-rel.1+6a049f2.fw7049fd8`。

## 0. 一句話

節點上任何支援路徑改的 per-node 設定(mesh key / channel / mesh_id / hostname / …)都要在 **≤ 15 s 內(入網中)或立即(操作員工具)** 寫進 p5;p5 落後 live 時 **OTA 被擋**;並補上「設 config → reflash 另一槽 → 新槽 provisioned + rejoin」的回歸。關閉 #202,給 #254(app 供裝)一個可以依賴的契約。

## 1. 現場觸發(逐 actor)與今天的行為

| # | 現場 | 今天(main 6a049f2) | 證據 |
|---|---|---|---|
| T1 | **LOCKED** 節點(有 root 密碼)開機入網一次後,操作員/app 改 key / hostname / channel | `joinwatch:144` 首次 `--on-join` 回 0 就 touch `$RUNDIR/config-saved`,之後本次開機**不再呼叫 save** → p5 凍結 → OTA 新槽用舊設定 | G1 白箱重現(02,latch 注入:60 s p5 不跟、快取指紋/stamp 不動;拔 latch 35 s 跟上) |
| T2 | **建網第一台 / 換 key** 的那台:設完沒 peer | save 只在 joinwatch 的 JOINED 分支 → 不入網就不存;`batman-slot:466-471` interlock 只看 `.seeded` → **放行 OTA** → 新槽用舊 key 開機 | G2 真機重現(02:換 key 60 s p5 仍舊 key;`precheck-node` 回「ready for an OTA」rc 0) |
| T3 | 公開 image 新卡用 `halow-setkey` 入 fleet | `halow-setkey` 不設 channel/頻寬(image 預設 ch42 = 2 MHz,fleet ch40 = 4 MHz)→ 入不了 mesh,要手動 `uci set wireless.radio1.channel=40` | #75 行 208(2026-10-05 v1.5.0 燒卡實測);`halow-setkey:1-70` 無 channel 參數 |
| T4 | 操作員手動 `uci set … ; uci commit`(不經工具) | 入網中:OPEN 節點 15 s 內跟上(#263 M0 指紋快取);LOCKED 節點同 T1;未入網同 T2 | `batman-config-save:55-99`(快取)、T0 兩台 `p5 == live` |
| T5 | p5 **從未** seed 的 mesh-only 節點 reflash | interlock 擋(`.seeded` 缺)→ 不 strand | 現行,不改 |
| T6 | OPEN 節點(今天整個 fleet)入網中改設定 | 指紋快取失效 → 15 s 內重存 | T0 + G1 負對照(拔 latch 後 35 s 跟上) |

**結論**:機制(join → save → 96 還原)是對的,壞在三個「各自正確」的假設互相衝突:joinwatch 以為「存過一次 = 這次開機不會再變」(同 #265 的 latch 教訓);halow-setkey 以為「有人會存」;interlock 以為「有 `.seeded` = p5 是新的」。

## 2. 範圍(從現場推,不從好交付推)

**做**
- **A. 拿掉 joinwatch 的 latch**:JOINED 的每個 tick 都呼叫 `batman-config-save --on-join`;冪等與成本由 #263 M0 的指紋快取負責(已在 image,實測快取命中 0.03 s)。解 T1、T4(入網中)。
- **B. `halow-setkey` 成為「套用 + 立即持久化」的入口**:新增 `--channel <n>`(解 T3);設完自動 `batman-config-save --save`,結果明示(解 T2 的「操作員意圖沒進 p5」)。`--save` 補 Pi 3 factory check(runbook G4)。
- **C. interlock 改查新鮮度**:新 `batman-config-save --check`(唯讀:p5 是否等於現在會寫的內容);`batman-slot precheck-node` 在 stage 1(live 系統)用它,**p5 落後 → 拒絕 OTA**(解 T2、T4 未入網)。
- **D. 回歸三條進 daily-validation**(harness PR 先進 main,#290):D1 設定跟隨(白箱 latch 注入)、D2 setkey 持久化 + interlock 拒絕 stale、D3 reflash-survives-config(真 `sysupgrade -n`,02)。
- **E. 文件**:`p5-config-partition.md` saver 契約更新、`golden-image.md` setkey 用法、本文件。

**不做(寫回 #202 殘項清單,不開新單)**
- autocommit 在「單台建網、沒鄰居」時永遠 revert(`batman-autocommit:389` `expected_in_mesh`):219 §6.3 已指定由 #254 改成「依 p5 成員資格」。本單只保證 p5 內容正確。
- LOCKED 節點的**黑箱**驗證(真設 root 密碼):fleet 全 OPEN;D1 用白箱注入涵蓋同一條程式路徑;等新 Pi 3 或使用者決定鎖 02。
- LUKS(戰術 tier,#111)p5:`--check` 與 interlock 對非 ext4 p5 一律 skip(與現行 interlock 同策略,見 §7)。
- 集中推送(#14/#54)、provd(#254):只需遵守 §4 契約 C2(改完呼叫 `--save`),不在本單實作。

## 3. 擁有權

| 資源 | 唯一寫者 | 唯讀者 | 備註 |
|---|---|---|---|
| p5 `overrides.uci` / `schema_version` / `identity/*` / `.seeded` | `batman-config-save`(`--seed/--save/--on-join/--if-healthy`) | `96-batman-config-migrate`、`99-batman-chanfix`、`batman-slot precheck-node`(ro)、`batman-config-save --check`(ro)、harness(ro,noload) | 不變 |
| p5 `lkg/overrides.uci` | `batman-config-save`(只 `--seed/--on-join/--if-healthy` 旋轉;`--save` 不碰,N-R8) | `96` | 不變 |
| `$RUNDIR/config-saved`(latch) | **刪除**:A 之後無人寫、無人讀 | — | 舊 image 殘留檔無害(新 joinwatch 不看) |
| `$RUNDIR/cfgsave-onjoin.state`(指紋快取) | `batman-config-save`(`--on-join` 寫;其他模式刪 L96-98) | 自己 | 不變;`--check` **不**寫它 |
| `$RUNDIR/cfgsave-mount.failed` / `cfgsave-pi3gate.failed` | `batman-config-save --on-join` | 自己 | 不變 |
| live uci `wireless.<mesh>.key/encryption/mesh_id`、`wireless.radio1.channel` | `halow-setkey`(操作員/app)、`96`(fresh-slot firstboot 還原)、`99-chanfix`(fresh-slot firstboot 晚期重設 channel) | joinwatch(radio 診斷)、`batman-config-save` | 三個寫者在**不同生命週期階段**(firstboot vs 執行期),不重疊;morse 驅動會把 42 寫回 uci 的情況已由 99 處理 |
| `system.@system[0].hostname` 等其他 PRESERVE 鍵 | 操作員 / provd(#254) | `batman-config-save` | 不變 |
| `/opt/batdata/state/lock-status` | `96` | `halow-status` | 不變;`--save` 不改鎖定狀態 |
| `/opt/batdata/state/mesh-expected` | `batman-config-save`(seed/on-join) | `batman-autocommit` | 不變 |
| OTA 准駁 | `batman-slot precheck-node`(由 `platform.sh:150` stage 1 呼叫) | `sysupgrade` | 新增一條判定(C5) |
| joinwatch tick 計時 | joinwatch | — | 不變(~15 s) |

兩個寫者同一資源:無。`wireless.radio1.channel` 的三個寫者按階段互斥(上表)。

## 4. 契約

**C1 `batman-config-save --on-join`**(呼叫者:joinwatch,JOINED 的每個 tick)
- 行為不變:算指紋(PRESERVE 值 + 身分檔 + shadow + p5 superblock stamp);命中快取 → 回快取 rc,不掛載;未命中 → 掛 p5 rw、比對、必要時寫、旋轉 lkg、寫 `.seeded`。
- rc:0 = 已持久化且有 root 密碼;4 = 已持久化但節點 OPEN;1 = 錯誤(mount 失敗 → 300 s 退避;Pi 3 factory gate 失敗 → 本次開機不再試)。
- **變更只在呼叫者**:joinwatch 不再 latch。`[ ! -b /dev/mmcblk0p5 ]` 的便宜跳過保留(無 p5 的卡不 fork)。
- 失效模式:mount 一直失敗 → 每 300 s 一次錯誤,p5 不更新 → C5 會擋 OTA(fail-closed,因為 p5 落後)。

**C2 `batman-config-save --save`**(呼叫者:`halow-setkey`、操作員、provd #254)
- 行為:寫 overrides + identity + schema,**不**旋轉 lkg,刪指紋快取;**新增**:`.seeded` 不存在且有 `mmcblk0p7` 時跑 `pi3_factory_check`(與 seed/on-join 同,L140 條件加 `--save`)。
- rc:0 寫入;1 失敗(mount / factory gate / 不是 ext4 且無 mapper)。
- 不格式化(只 `--seed` 會)。p5 不是 ext4(LUKS、未 seed 的空分割)→ rc 1 + 訊息。

**C3 `batman-config-save --check`(新)**(呼叫者:`batman-slot precheck-node`、harness、操作員)
- 行為:**唯讀**。無 p5 或 p5 非 ext4 → rc 3(skip);`ro,noload` 掛 p5;沒有 `.seeded` → rc 5;組出 `--save` 現在會寫的 `overrides.uci` + `schema_version` 到 `batman_tmp`(root 0600,非 /tmp 可預測名);與 p5 `overrides.uci` / `schema_version` 逐位元組比對 + `same_identity` → 相同 rc 0,不同 rc 5 並印**鍵名**(`stale: wireless.default_radio1.key system.@system[0].hostname`),**不印值**;mount 失敗 rc 1。
- 不寫 p5、不動快取檔、不寫 `mesh-expected`。
- 格式:stdout 一行 `batman-config-save: p5 fresh|stale (<keys>)|unseeded|no-p5|not-ext4`。
- 信任邊界:只有 root 能掛 p5;非 root 呼叫 → mount 失敗 rc 1(不是旁路:C5 在 root 下跑)。

**C4 `halow-setkey --mesh <k> [--ap <k>] [--mesh-id <id>] [--channel <n>]`**
- `--channel`:整數;必須出現在該 mesh iface 所屬 radio 的 `iw phy <phy> channels` 清單且非 disabled;否則 exit 2 不改任何東西。設 `wireless.<radio>.channel`。
- 順序:驗參數 → uci set(key/encryption/mesh_id/channel)→ 釋放 keyguard → `uci commit wireless` → `wifi reload` → **`batman-config-save --save`** → 印 `persist: saved -> /dev/mmcblk0p5` 或 `persist: FAILED (<原因>) — 設定只在本槽,下次 OTA 會遺失` 或 `persist: n/a (no p5 on this card)`。
- exit:0 = radio 套用且(持久化成功或無 p5);**3 = radio 套用但持久化失敗**(呼叫者如 provd 用來顯示 219 §2.3 的「設定沒有存好」);2 = 參數錯,未改。
- 不迴印 key。root only(uci/wifi 本來就需要)。
- 後果宣告:`--save` 寫的是**未經入網證明**的設定(操作員意圖);lkg 不旋轉,96 只在 overrides 壞掉/schema 太新時退回 lkg,**不會**因「key 打錯」退回。打錯 key 的救法同今天:再跑一次 `halow-setkey`。

**C5 `batman-slot precheck-node` 新判定**(呼叫者:`platform.sh:150` stage 1;`batman-slot apply` 在 stage 2 ramfs 重跑 precheck)
- 現行 `.seeded` 判定之後:若 `command -v batman-config-save` 且 `/etc/config/wireless` 可讀(= live 系統)→ 跑 `--check`;rc 5 → `die "p5 (config) is STALE vs the running config (<keys>) — a reflash now would boot the fresh slot with the OLD settings. Run 'batman-config-save --save' (or halow-setkey) or wait for the mesh join to persist it; override: touch /tmp/batman-slot.allow-stale-p5 (root) / BATMAN_ALLOW_STALE_P5=1"`;rc 3(無 p5/非 ext4)與 rc 1(掛不起)→ 不擋(與現行 interlock 同:查不了就不擋,stage 1 已經用同一份 p5 判過 `.seeded`);rc 0 → 過。
- stage 2 ramfs:`batman-config-save` 與 `uci` 不在 `RAMFS_COPY_BIN`(`platform.sh:37`)→ `command -v` 失敗 → 跳過。stage 1 幾秒前已判過,且 stage 1 到 stage 2 之間沒有使用者程式會改 uci(sysupgrade 已 kill services)。
- 覆寫用既有 `allowed()`(`batman-slot:77`,root-owned predicate file 或環境變數),名稱 `STALE_P5`。
- 失效模式:**fail-closed**(p5 落後就不准 OTA)。理由:T2 的後果是 mesh-only 節點用舊 key 開機 = 現場不可救;操作員有明確的兩個出口(存,或覆寫)。

**C6 `99-batman-chanfix`**:不變(從 p5 讀 channel 晚期重設)。B 讓 p5 的 channel 就是操作員設的值,所以 fresh slot 的 99 會把它重設回來。

**C7 harness(D1–D3)**:見 §8。

## 5. 生命週期矩陣

| 路徑 | 今天 | 之後 | 證明的測試 |
|---|---|---|---|
| fresh slot 首次開機(install) | 96 還原 p5 → 99 重設 channel → joinwatch JOINED → on-join(OPEN 每 tick / LOCKED 一次) | 同,但 LOCKED 也每 tick(快取命中 0.03 s) | D3(黑箱:新槽 hostname/key/JOINED) |
| 一般開機(start) | 同上 | 同上 | D1 |
| clean stop / 重開 | 無持久狀態(快取在 tmpfs) | 同 | — |
| joinwatch 重啟(procd) | 快取檔由 config-save 以指紋+stamp 驗證 | 同;latch 不存在所以沒有「重啟後再存一次」的差異 | D1(restart joinwatch 後再改一次) |
| 升級到本版(OTA from 1.5.11) | 舊 image 的 precheck 跑(沒有 C5)→ 這一次 OTA 不受新鮮度保護 | 之後每次 OTA 受保護 | D2 在新版上 |
| 回滾/降級到 1.5.11 | — | 舊 joinwatch 又會 latch(T1 回來);p5 schema 仍 1,內容相容;舊 `halow-setkey` 不認 `--channel`(exit 2,不改) | 設計上宣告;ab-selftest rollback 既有 |
| crash / crash loop | save 原子(STAGE → mv,`.seeded` 最後) | 同;多一個 `--check` 唯讀路徑 | 既有 ab-selftest;D3 期間斷電不在本單 |
| 斷電 / 斷網 | 未入網 → 不 on-join | 同;操作員工具改的靠 `--save` 立即寫;其餘等入網;**OTA 前被 C5 擋** | D2(stale → 拒絕) |
| 依賴重啟:`wifi reload`(setkey) | joinwatch 看到短暫 NOT_JOINED | 同;`--save` 在 reload 之後跑,不等入網 | D2 |
| Pi 4(bcm2711) | — | 全部適用 | D1–D3 在 02 |
| Pi 3(bcm2710) | `--save` 不跑 factory check(G4) | `--save` 在未 seed 卡上跑 factory check | ❌ 無板(03 故障)→ 程式碼審查 + 殘項 |
| golden/MBR 單槽卡(無 p5) | 全部 skip | 同(`--check` rc 3,setkey `persist: n/a`) | D1 precondition skip 路徑 |
| LUKS p5(#111 未落地) | interlock skip | `--check` rc 3 → skip | 不適用(無 image) |

## 6. 依賴的行為與證據

| 假設 | 證據 |
|---|---|
| latch 在 `joinwatch:144`,只擋 save 的呼叫 | 原始碼;G1 白箱(latch 在 → 快取檔的指紋與 stamp 60 s 不變 = save 沒被呼叫) |
| 快取命中不掛載、成本可忽略 | `batman-config-save:55-99`;02 實測 `time batman-config-save --on-join` = real 0.03 s ×2(rc 4,`cached this boot — skip`) |
| OPEN 節點指紋失效會重存 | G1 負對照:拔 latch 後 35 s p5 更新、快取 stamp 4278→4279 |
| 未入網不存 | G2:60 s p5 key md5 不變 |
| interlock 只看 `.seeded` | `batman-slot:466-471`;G2 `precheck-node` rc 0 |
| precheck 在 stage 1 live 系統跑 | `/lib/upgrade/platform.sh:150`(02 上 grep);ramfs 階段的工具清單 `platform.sh:37` 無 uci / config-save |
| `allowed()` 覆寫機制 | `batman-slot:77` |
| 96 會還原 hostname/channel;99 晚期重設 channel | `96:126-150`、`99-batman-chanfix` 全文 |
| `iw phy` 列出 S1G 頻道 | 02:`iw phy` 91 行 `MHz [`;radio1 `channel='40' country='US'`,mesh encryption `sae` |
| deploy/ 與 feed/ 兩份要同步 | `scripts/check-provisioning-sync.sh` PAIRS 含 setkey/config-save/joinwatch |
| 新臨時檔不能用 /tmp 可預測名 | `scripts/check-tmp-trust.sh` 規則;allowlist 是 harness 檔(產品 PR 不碰)→ 用 `batman_tmp`/`$RUNDIR` |
| autocommit 需要 JOIN_NEED=3 且 ≥ MIN_WINDOW 300 s | `batman-autocommit:30-35`;D3 預算由此來 |
| 02 上有可用 OTA payload = 同版本 | `/opt/batdata/ota.tar.gz` sha 73300d1b = rel.1 payload(記憶 + 02 ls) |
| 02 slot A committed(非 trial) | `batman-slot active`=A,`is-trial` rc 1 |

## 7. 安全

- **資產**:p5 裡的 mesh key / AP PSK / 身分檔(民用 tier 明文 ext4,**不變**)、節點 root 控制、OTA 准駁。
- **遠端攻擊者**:無新網路輸入;`--check` 不開 port。
- **本機非特權程序**:新檔案只在 `$RUNDIR`(root 0700)與 `batman_tmp`(root 0600,不可預測名);覆寫檔 `/tmp/batman-slot.allow-stale-p5` 走既有 `opf`(必須 root 擁有)。`--check` 的輸出只有鍵名。非 root 跑 `--check`/`--save` → mount 失敗 rc 1,不能偽造「fresh」:C5 在 root 下自己跑,不讀別人的結果。
- **被攻陷的對等節點**:不能寫本機 p5(需本機 root);mesh 上沒有新協定。
- **輸入驗證增量**:`--channel`(整數 + `iw phy` 白名單);所有值仍過 config-save 的 metachar 過濾(L177)。
- **特權**:全部 root(uci/wifi/mount 必須)。沒有 root 程式讀低權限可寫路徑的新情況(TOCTOU:`--check` 掛 p5 到 `mktemp -d` 目錄,與現行一致)。
- **秘密**:不印 key;`--check` 鍵名不含值;log 行同。
- **失效模式**:C5 fail-closed;查不了(無 p5/非 ext4/ramfs)才 fail-open,理由如 C5。`--save` 失敗大聲(exit 3 + 訊息),不是默默略過。
- **我們自己的錯**:`--save` 會把打錯的 key 寫進 p5 → 新槽也是錯 key → 與 live 一致,操作員用同一工具改回;lkg 不被 `--save` 覆蓋,96 的 lkg 退路只對「壞檔/schema」。
- **負向驗證**:D2 的 stale → `precheck-node` 拒絕(rc≠0、訊息含 STALE);非 root `batman-config-save --check` rc 1(D1 內附一行)。

## 8. 測試(harness PR 先進 main;每條都真驅動介面)

**D1 `p5-follows-config-202`(tier A,MESH_NODE 與 OTS_NODE 各一次)**
前置:p5 是 ext4 且 `.seeded`(否則 SKIP-REASON);joinwatch 狀態 JOINED。
1. `touch $RUNDIR/config-saved`(白箱:模擬 LOCKED 節點存過一次的狀態;新 image 這個檔沒有讀者)。
2. `uci set hostname=<old>-dv202; uci commit system`;每 5 s `ro,noload` 掛 p5 讀 hostname,≤ 60 s 要變成新值。
3. 還原 hostname;≤ 60 s p5 回舊值;刪 latch 檔;`batman-config-save --check` 必須 rc 0;非 root(`su nobody`,若有)跑 `--check` 必須非 0。
負對照:rel.1 上步驟 2 不變 → FAIL(= G1 的 log)。新版 PASS。
**D2 `setkey-persists-202`(tier B,DNODE,D:會短暫離網)**
1. 記 p5 key md5、live channel;`halow-setkey --mesh <tmp-key> --channel <同一 channel>` → exit 0,輸出含 `persist: saved`;≤ 10 s p5 key md5 == 新 key 的 md5;`batman-slot precheck-node` rc 0。
2. `uci set wireless.<mesh>.key=<old>; uci commit wireless`(不 reload、不存)→ `batman-config-save --check` rc 5 且輸出含 `key`;`batman-slot precheck-node` **非 0** 且訊息含 `STALE`。
3. `halow-setkey --mesh <old-key>` → p5 key md5 == 舊;precheck rc 0;≤ 180 s 重新 JOINED(與 `bchk_rejoin_245` 同樣的 plink 等待)。
節點端有 150 s 看門狗還原(同 G2 腳本),連線掉也會回來。
負對照:rel.1 上步驟 1 p5 不變 → FAIL;步驟 2 precheck 放行 → FAIL。
**D3 `reflash-survives-config-202`(tier B,DNODE,D,慢 ~12 min)**
前置:`/opt/batdata/ota.tar.gz` 存在且 `batman-slot is-trial` rc 1(committed);記 boot_id、active slot、BATMAN_VERSION。
1. `uci set hostname=<old>-dv202x; uci commit; batman-config-save --save`;`--check` rc 0。
2. `setsid sh -c 'sysupgrade -n /opt/batdata/ota.tar.gz'`(同 `fault-injection.sh:191`);等 boot_id 改變(≤ 300 s)。
3. 新槽:active slot 翻轉;`uci get hostname` == `<old>-dv202x`;mesh key ≠ placeholder、`halow-setkey --status` 無 `keyguard blocked`;JOINED ≤ 240 s;BATMAN_VERSION 不變(同 build 重刷)。
4. 等 autocommit committed(≤ MIN_WINDOW 300 + 120 s;`fault-injection.sh:80` 的 `committed()`)。
5. 還原 hostname + `--save`;`--check` rc 0。
負對照:對 G1/G2 的設定變更路徑,rel.1 上**不能**用 D3 顯示 FAIL(fleet OPEN,on-join 會存)→ D3 是 DoD 第 1 條的黑箱證明,不是 A/B/C 的負對照;負對照由 D1/D2 提供。誠實標在 PR。
**CI**:`check-provisioning-sync`、shellcheck、`check-tmp-trust`、`ab-card-invariants`(不動)。
**known-failures**:D1/D2 在 1.5.11 上預期 FAIL → 進 `validation-known-failures.txt` 掛 #202,新版出貨後移除(#290 流程)。

## 9. 實作切法

- **PR-H(harness)**:`test/202-harness` → main:D1–D3 + known-failures + rel.1 的 FAIL log 證據。
- **PR-P(產品)**:`feat/202-config-survival`:`joinwatch`(兩份)、`batman-config-save`(`--check`、`--save` factory gate,兩份)、`halow-setkey`(`--channel`、`--save`、exit 3,兩份)、`batman-slot`(C5)、`docs/design/p5-config-partition.md`、`docs/golden-image.md`、本文件。
- rc `1.5.12-wsl.N`(WSL build-3aplus,board diffconfig)→ OTA 02 → D1–D3 → 全套 → PR → 使用者 merge → firmware pin bump → 出貨產物煙霧/全套。

## 10. 殘項(關單時寫回 #202 checklist)

- LOCKED 節點黑箱驗證(需鎖一台或新 Pi 3)。
- Pi 3 上的 `--save` factory gate 實測(03 故障)。
- autocommit 單台建網(#254 / 219 §6.3)。
- LUKS tier 的 `--check`/interlock(#111)。
- 舊 image 回滾後 T1 回來(文件化,無法修)。
