# #254 PR-P3:擁有者 / 設定 / 狀態 / 診斷 / 更新 / 大量傳輸 / 轉賣工具(設計 v1)

狀態:v1 草稿,2026-11-02,待兩位審查。上層:`254-stage1-impl.md` §10.6;協定 `219-protocol.md` v0.8 + `219-protocol.cddl`;P2 = `254-p2-impl.md` v8.5(已出貨 `1.5.14-wsl.22`)。
原則(使用者 2026-10-31 / 10-30):**只做必要的修改**、**失敗就回到之前的狀態**;本文件所有「事實」附 `file:line` 或節點實測,沒有證據的標 ⚠️。

## 0. 一句話

把 P2 的 provd 當成唯一入口,補上 P3 的協定動詞(擁有者增刪、設定 / 改名 / 國家、自己的狀態、診斷、`peers/challenge`、軟體更新、大量傳輸),每個動詞都經 helper(root)執行、helper 自己驗證;軟體更新以**兩層鑰匙**簽章(離線根鑰匙背書 YubiKey 上的簽章鑰匙),payload 經一個**暫時取代手機 AP** 的獨立 Wi-Fi 傳進節點;同一條 HTTP 通道也是 BLE 壞掉時的備援入口(只收擁有者 / 成員,不收匿名認領)。另附轉賣工具與 LuCI reset 文字。

## 1. 決策、範圍、事實

### 1.1 使用者決策(2026-11-02,#254 留言 6569483517、6570171273)

| # | 決策 |
|---|---|
| D1 | 順序:P3 設計 + 兩位審查 → H4 照本文件契約寫並先 merge → P3 實作 → rc → 上機 → H4 + P3 完成後、app 開工前跑全套 |
| D2 | 重做 host 端 provd 擁有者 client(Noise over prov_test frame socket / BLE);被分類器擋再說(H4) |
| D3 | `update/*`、`bulk/*` 算進 P3(取代 stage1-impl §10.7「S4 另寫 addendum」與協定 `:218`「階段 1 不實作」) |
| D4 | B18:**兩層鑰匙**(離線根鑰匙兩份 + YubiKey 上的簽章鑰匙;背書 / 撤銷免重燒;防降級)。使用者有 YubiKey;終端使用者不持有發行鑰匙 |
| D5 | bulk 期間**暫停該節點的手機 AP**(B2 預設);節點之間的 HaLow / LoRa mesh 不受影響 |
| D6 | autocommit 的 BLE 檢查維持 WARN(P-U5,等 #305);P3 只補 boot_id / ts 新鮮度。HTTP 通道兼一般備援入口(新攻擊面,§7) |
| D7 | `status` 只做 self;team 沿用現有 mesh / hostname 抓法,`dac_pub_hash` + 最後看到時間進 checklist |
| D8 | 改名探針 U5 由 Claude 在 04 跑(先列步驟 / 副作用 / 還原給使用者;**尚待使用者回覆「IP 沒回來時手動改回」**) |
| D9 | 國家以 `net_config` 為準;單台設定只在未入網時可改 |
| D10 | `diag/summary` 成員可讀;`diag/bundle` 只給擁有者 |
| D11 | `prov-eeprom-hooks-254` 缺的 1.5.12 負對照與 fresh-overlay 檢查併 H4 |

### 1.2 範圍

**在本 PR**:§3 各節。**不在本 PR**(逐條理由):
- app 本身與其說明頁(賣方 / 買方 / 遺失手機)— repo 無 app 程式碼,U9:app 在 P3 之後(說明頁的**文字**列在 §3.10,供 app 引用)。
- `status` team 的 `dac_pub_hash` / 最後看到時間(D7)— 需要新的 mesh 廣播機制。
- 邀請 QR 的產生 / 申請 / 同意 — 網主 app 端簽章物件(§7.6);節點端只收 `network/join` 的選填 `invite_id`(P2 已轉送),**節點端無新增**。
- `owner.replace`(L29,S3)、恢復出廠(#255)、608B(#255)、bcm2710 實測(P-U14)。
- autocommit BLE 檢查改成擋 commit(D6,等 #305)。
- 冪等快取(`254-p2-impl.md:406`):P3 的動詞都可安全重試或帶秘密(§3.1.3),維持 P2 的「帶 idem → `E_UNSUPPORTED{idem}`」。⚠️ 審查請確認沒有哪個 P3 動詞的重送會造成傷害。

### 1.3 事實(reality check 2026-11-02,main 2ecf1cb;節點 = 04 wsl.22)

| # | 事實 | 證據 |
|---|---|---|
| F1 | provd 對 `p3Types`(owner/add|remove、settings/get|set、status、peers/challenge、diag/*、update/*、bulk/*)在角色判斷前回 `E_UNSUPPORTED{1:typ}` | `provd/session.go:68-70`、`:623-625` |
| F2 | provd 角色白名單:擁有者 = info、op/nonce、network/*、ssh_keys/set、root_password/reset;成員 = info、network/update | `session.go:79-81` |
| F3 | helper 已有 `owner.add`(重送同 pub = 輪替該擁有者 tag key;上限 4)、`owner.remove`(不能移除最後一位;輪替 `adv_owner_key`;removed 的 psk 隨 TagKey 消失) | `node/node.go:834-898`、`:385-390` |
| F4 | `owner.*` 邊界(sig_enc 錯、上限、最後一位、未知 kid、兩種輪替)沒有測試 | grep `node/*_test.go`(reality check A) |
| F5 | `settings.set` 收到 hostname 回 `EUnsupported "rename-pending"`;其他 key `ESchema`;沒有 `settings.get` | `node.go:760-770`、`:230-256`、`readonly.go:104-133` |
| F6 | CDDL settings:1 = 名稱、2 = 國家(2 字)、10 = halow{channel,bw}、11–13 = ptt/gps/lora、`* uint => any` 忽略未知 | `219-protocol.cddl:190-200`、`:431-440` |
| F7 | 04:`radio1.country='US'`、channel 40;`radio0`(5 GHz AP)沒有 country;`halow-setkey` 不設國家,只在 country 未設時拒絕 | 04 `uci show wireless`;`halow-setkey:92` |
| F8 | config-save 持久化:hostname、radio1 mesh_id / key / channel / country、**default_radio0.key**、ahwlan ipaddr / proto、openmanetd 兩個位址旗標 | `batman-config-save:41-52` |
| F9 | 手機 AP `phy1-ap0` 與 bat0 在同一座 `br-ahwlan`(10.41.1.3/16):ahwlan 上的服務整個 mesh 都連得到;firewall ahwlan zone input ACCEPT | 04 `ip -br addr`、`uci show firewall` |
| F10 | meshpoint 只在 uci-defaults(`94-batman-baseline`,每個新 overlay 的第一次開機)把每個 `mode=ap` 接進 ahwlan;執行期不跑 | `meshpoint-1.8.0:66-70`;`94-batman-baseline` |
| F11 | provd 的 ujail 沒有 netns(與主機共用網路),無 capability;只掛 batman-build 與兩個 socket 目錄 | `files/batman-provd.init:18-19`;04 `/etc/capabilities/batman-provd.json` |
| F12 | provd 讀 helper 回覆 > 64 KiB 就斷線;請求上限 `sock.MaxRequest = 65536` | `provd/helper.go:129-133` |
| F13 | provd 已會把大回應切塊(`{1:id,4:0,3:bstr,6:{n,total}}`),**沒有測試** | `session.go:349-372` |
| F14 | helper `diag.bundle` = halow-status + `batman-slot verify` + `logread -l 300` 純文字,無上限、inline 回傳 | `cmd/batman-provhelper/main.go:393-401`、`node.go:778-783` |
| F15 | `/www/cgi-bin/bundle` 無驗證、ahwlan 上任何人可下載(含 dmesg / logread / join.log);`status`、`mesh` 頁連結它;`mesh` 頁抓同伴的 `status?json`(也無驗證) | `files/www/cgi-bin/bundle`;`www/cgi-bin/mesh:14-30` |
| F16 | `halow-status json` 有 health{level,verdict,checks[{level,id,msg}]}、join{state,…}、`last_join_diagnosis`;joinwatch 失敗原因只有英文句子,沒有數字碼 | `halow-status:66`、`:162`;`joinwatch:71-82` |
| F17 | helper `sign.peer` 已實作(全域 2/s),沒有測試;provd 沒有每連線額度 | `node.go:238`、`:324-377` |
| F18 | **沒有任何 image 簽章**(只有 `SHA256SUMS`);`metadata` 只有 `board=`、`version=`(build 時間戳)、`size=` | grep feed/scripts;`build-ab-payload.sh:69-73`;wsl.22 `metadata` |
| F19 | `batman-slot apply`:precheck(雜湊 vs SHA256SUMS)→ begin_write(BAD 標記)→ dd → 讀回驗證(:692-714)→ **arm**(`vcmailbox`,:716-738);寫完驗完就 arm | `batman-slot:592-738` |
| F20 | `sysupgrade` 的 stage 2 一定重開 → `update/prepare` 不能走 sysupgrade;live 系統直接 `batman-slot apply` 是支援的 | `platform-ab.sh:325-377`;`batman-slot:456` |
| F21 | autocommit BLE 檢查 WARN-only,不比 boot_id / ts | `batman-autocommit:506-511` |
| F22 | 現有 COSE_Sign1 驗證與 ES256:`cose.VerifySign1`、`proto.VerifyES256` | `cose/cose.go:36`、`proto/proto.go:107` |
| F23 | LuCI flash.js 仍是「Perform reset」+ `firstboot -r -y`;`rc.button/reset` 已在 firmware P1 改(長按只重開) | firmware `feeds/luci/.../flash.js:104,402,408`;`files/etc/rc.button/reset`;`scripts/test-rc-button.sh` |
| F24 | 沒有轉賣工具;`scripts/flash-card.sh` 只支援 OpenMANET 1.8.0、不全卡清零 | repo grep |
| F25 | 04:RAM 8 GB、`/tmp` 3.9 GB;3A+ `/tmp` 212 MB、payload ≈ 116 MiB(wsl.21 release payload 126,210,741 B) | 04 `free`/`df`;`219-field-provisioning.md:448`;`/home/yello/out/…wsl.22` |

## 2. 總體結構

```
app ──BLE GATT(P2)────────────┐
app ──HTTP over Wi-Fi(§3.8,新)┴→ batman-provd(uid 471,ujail)── ctl / ops socket ──→ batman-provhelper(root)
                                                                                    ├ provstore / p5(owner、settings)
                                                                                    ├ halow-status / joinwatch(status、diag)
                                                                                    ├ keystore(sign.peer)
                                                                                    ├ release 驗證(§3.7,新)
                                                                                    └ batman-slot write / arm(§3.7,拆開)
```

不變的 P2 契約:provd 不碰任何 root 資源、不讀 health 檔;每個 owner-op 由 helper 驗章(`verifyOwnerOp`);provd 只做角色、額度、分塊、Noise。P3 新增的 helper 動詞全部沿用 `ops` 連線(一次一個在飛)與既有的 `stateChanging` / `commitOnly` 規則(`node.go:199-203`)。

## 3. 設計

### 3.1 provd 路由(`provd/session.go`)

1. `p3Types` 改成空集合(本 PR 全部實作);保留機制與 `route_test` 的形狀,供之後的新動詞。
2. 角色白名單(`allowed`):
   - 擁有者 += `owner/add`、`owner/remove`、`settings/get`、`settings/set`、`status`、`diag/summary`、`diag/bundle`、`update/check`、`update/prepare`、`update/apply`、`update/status`、`bulk/open`、`bulk/close`。
   - 成員 += `status`(摘要,§3.4)、`diag/summary`(D10)、`peers/challenge`。
3. 轉送表與回應:

| 協定 type | helper 動詞 | owner-op | 回應 body |
|---|---|---|---|
| `owner/add` | `owner.add`(既有) | 要 | `{1: owner_tag_key}`(秘密:不得帶 idem,`secretTypes` 已含) |
| `owner/remove` | `owner.remove`(既有) | 要 | `{}` |
| `settings/get` | `settings.get`(新,唯讀,§3.3) | 不要 | CDDL `settings` |
| `settings/set` | `settings.set`(擴充,§3.3) | 要 | CDDL `settings`(套用後的值) |
| `status` | `status.get`(新,唯讀,§3.4) | 不要 | CDDL `status-resp`;成員 = 摘要 |
| `diag/summary` | `diag.summary`(新,唯讀,§3.5) | 不要 | CDDL `diag-summary-resp` |
| `diag/bundle` | `diag.bundle`(改)+ `diag.read`(新,§3.5) | 要 | 分塊 `{1: bstr}` |
| `peers/challenge` | `sign.peer`(既有) | 不要 | `{1: nonce_node, 2: sig}` |
| `update/check` | `update.check`(新,§3.7) | 不要 | `update-check-resp` |
| `update/prepare` | `update.prepare`(新) | 要 | `update-progress` |
| `update/apply` | `update.apply`(新) | 要 | `update-progress`(然後重開) |
| `update/status` | `update.status`(新,唯讀) | 不要 | `update-progress` |
| `bulk/open`、`bulk/close` | `bulk.open`、`bulk.close`(新,§3.8) | 要 | `bulk-open-resp`、`{}` |

4. **唯讀動詞**(`settings.get`、`status.get`、`diag.summary`、`update.status`)走 P2 的唯讀路徑(不取 `n.mu`、有額度,`readonly.go`),不會被進行中的 `net.apply` 卡成 `E_BUSY`。`sign.peer` 會取 `n.mu`(`node.go:233-235`):`net.apply` 期間回 `E_BUSY`,app 重試 — **不改**(只做必要)。
5. 每連線額度:`peers/challenge` 0.5/s(stage1-impl `:164`;F17 缺);`diag/bundle` 每 session 同時一份;`status` / `diag/summary` 共用唯讀額度。

### 3.2 擁有者增刪

helper 行為不變(F3)。本 PR 只做:
- provd 路由(§3.1)。`owner/remove` 成功後依 P2 的 `invalidate → reconcile`(`session.go:649`、`server.go:601-640`)切斷被移除者的 session — P2 既有,H4 上機斷言。
- 補 F4 的 Go 邊界測試:`sig_enc` 錯 → `E_FORBIDDEN`;第 5 位 → `E_UNSUPPORTED`;移除最後一位 → `E_FORBIDDEN`;未知 kid → `E_FORBIDDEN`;重送同 pub → 新 tag key、舊 tag key 的 psk 失效;remove → `adv_owner_key` 換新。
- 文件矛盾:`219-protocol.md:447` 寫 remove 輪替 `owner_tag_key`;以 `:203` 與程式碼為準(**輪替 `adv_owner_key`**),改 `:447`。`254-p1-impl.md:465`「admins +1」刪除(`Admins` 是 net_config 的網主清單,與擁有者無關,`node.go:1059-1127`)。

### 3.3 設定:`settings/get`、`settings/set`(改名、國家)

**`settings.get`(唯讀)**:`1` = hostname(`system.@system[0].hostname`)、`2` = 國家(`wireless.radio1.country`)、`10` = `{1: radio1.channel, 2: 由 regdb 推的頻寬}`;`11`–`13` 依 `info.capabilities` 有就回、沒有就省略。「依能力分組」= 依 `capabilities` 決定出現哪些 key(CDDL 已允許省略)。

**`settings.set`** 只接受 key 1(名稱)與 key 2(國家):
- key 10–13 → `E_UNSUPPORTED{capability}`(頻道走 `network/update`,stage1-impl §11;ptt / gps / lora 沒有設定面)。
- **未知 uint key 忽略**(CDDL `* uint => any`、§5.1),改掉 P1 的 `E_SCHEMA`,修 `254-p1-impl.md:466`;文字 key(如 `"hostname"`)→ `E_SCHEMA`。
- 一次只改一項;同時帶 1 與 2 → `E_SCHEMA`(兩者副作用不同)。

**改名(key 1)**,沿用「失敗就回到之前的狀態」:
1. 驗 `[A-Za-z0-9-]{1,32}`、不以 `-` 開頭或結尾,否則 `E_SCHEMA`。與現值相同 → 直接回,不 reload。
2. 記舊值;`uci set` + `uci commit system`;`batman-config-save --save`(F8:hostname 在 PRESERVE)。`--save` 失敗 → 還原舊值 + commit + `--save`,回 `E_STORAGE`(與 `root_password.reset` 同型,`node.go:771-777`)。
3. 成功 → 回 `{1: new}`,之後(回應送出後)背景執行 `/etc/init.d/system reload`。app 顯示「機台會重新啟動」。
4. ⚠️ **U5 未驗**:#202 兩次觀察到改名後 openmanetd 重保留 IP 並重開(D15)。改名後 IP 會不會變、`<hostname>.local` 多久可解析、AP SSID(第一次開機時的 hostname,F8 不持久)不跟著改 — **U5 跑完前只寫成 ⚠️;H4 的改名單位以 U5 結果為準**。
5. 改名不碰 `net_config`(成員清單裡的 `name` 由網主 app 經 `network/update` 改,協定 §7.5)。

**國家(key 2)**,依 D9:
- 節點已入網(`info.net` 有 `net_id` 且未 `left`)→ `E_STATE`;國家跟著 `net_config` key 5,由 `network/join|update` 套用。
- 未入網:驗 2 個大寫字母且 regdb 有該國(`halow-setkey:92-96` 的 `$REGDB`);目前頻道在新國家不合法 → `E_SCHEMA` + detail;否則 `uci set wireless.radio1.country` 與 `radio0.country`(F7:5 GHz AP 目前沒有 country)+ commit + `--save` + `wifi reload`;失敗依步驟 2 還原。
- **`network/join|update` 套用 `net_config` key 5**:⚠️ P2 的 `netJoin` 是否已寫 country,實作時查;沒有就補(在 `halow-setkey` 之前 `uci set …country`),txn 的 read-back 一併比對國家。
- 事實提醒(F7):fleet 現在是 `US`;D9 的預設 TW 由 app 建網時寫進 `net_config`,節點端不自己改。

### 3.4 狀態:`status`(self)

`status.get`:helper 執行 `halow-status json`(root,F16)後對應:

| CDDL key | 來源 |
|---|---|
| 1 node-state | `info.state` |
| 2 verdict | `health.level`:OK → 0、WARN → 1、CRIT → 2 |
| 3 鄰居數 | `join.batman_neighbours` |
| 4 p5_saved | `batman-config-save --check` rc 0(**新**,F16 沒有現成訊號;`--check` 是 #202 既有) |
| 5 join-failure | 只在未入網:`{1: code, 2: verdict 原句}`,code 依 §3.4.1 |
| 6 電量 % | 省略(`battery` 是 `batpower.state` 字串,不是 %) |
| 7 team | `scope = 1` → `E_UNSUPPORTED{capability: "status.team"}`(D7) |
| 15 其餘 #131 欄位 | 擁有者:`node`、`image`、`uptime_s`、`last_boot_reason`、`last_ota`、`temp_c`、`throttled`、`join{state, channel, country, plinks, snr_db}`;**成員只拿 1–5**(摘要,協定 `:208`) |

⚠️ `batman-config-save --check` 會 ro 掛 p5,與寫入者同時跑的行為由 #202 T11 處理;實作時確認唯讀路徑呼叫它的頻率上限(額度)不會干擾 15 s 的 save tick。

#### 3.4.1 入網失敗原因碼

`joinwatch verdict()`(`joinwatch:71-82`)每一種句子一個數字(1 起),表放在 `usr/lib/batman/join-reasons`,joinwatch 與 helper 共用同一份;句子不在表裡 → code 0,`2` 帶原句。⚠️ 表內容實作時從 `joinwatch:71-82` 逐句列出。

### 3.5 診斷

**`diag.summary`(唯讀,成員也可)**:`halow-status json` 的 `health.checks[]` 轉成 `diag-item`:`1` = check id、`2` = level(OK 0 / WARN 1 / CRIT 2)、`4` = msg;不帶 `3`(沒有發生時間的來源)。

**`diag/bundle`(擁有者)**:
- helper 把 bundle 產生到**自己的** `/tmp/run/batman-prov/diag/`(root 0700):內容 = `/www/cgi-bin/bundle` 現在打包的那份(F15)加上 `batman-slot verify`,tar.gz,上限 2 MiB(超過從 logread / dmesg 尾端截,`MANIFEST` 註明)。**不含秘密**:不讀 `/etc/config/wireless`、`/etc/shadow`、`/etc/batman-prov/identity`、p5;logread 會含 MAC / IP / 名稱 → app 送出前提示(`219-field-provisioning.md:477`)。
- `diag.bundle` 回 `{1: size, 2: handle(16 B 隨機)}`;provd 以 `diag.read {1: handle, 2: offset}` 每次取 ≤ 48 KiB(F12 的 64 KiB 以內),依 §5.1 分塊回 app(F13 的切塊路徑,補測試)。bundle 檔 10 分鐘或 session 結束即刪;同時最多一份(新的取代舊的)。
- 選 handle + 分頁、不選 fd 傳遞(stage1-impl `:171`):sock 層沒有 SCM_RIGHTS,分頁不改 sock 協定 → 只做必要;改寫 stage1-impl `:171`。

**關掉 `/www/cgi-bin/bundle`**(F15):依 stage1-impl `:427`,只在 `info.state ∈ {legacy, unclaimed}` **且** 有 `batman-dev-open` 時給,其他回 403;`status`、`mesh` 頁不變(`mesh` 依賴同伴的 `status?json`)。index / status / mesh 頁的 bundle 連結:403 時改顯示「用 app 取得診斷包」。⚠️ `batman-dev-open` 的位置與檢查(opf:root、非 symlink、link count 1)實作時確認現有定義。

### 3.6 `peers/challenge`

成員可呼叫;provd 轉 `sign.peer {1: nonce_app, 2: h}`(F17,helper 自己產 `nonce_node`);每連線 0.5/s(新)、helper 全域 2/s(既有)。Go 測試:簽章可用 `node_cert` 公鑰以 `batman-peer-v1 ‖ nonce_app ‖ nonce_node ‖ h` 驗過;`nonce_app` 長度錯 → `E_SCHEMA`;兩層額度。

### 3.7 軟體更新(`update/*`)與發行簽章(B18)

#### 3.7.1 鑰匙(D4)

| 鑰匙 | 演算法 | 在哪 | 用途 |
|---|---|---|---|
| 根鑰匙 R(prod) | ES256(P-256) | 離線產生;私鑰只在兩支加密 USB(不同地點);公鑰內建在 image `/usr/share/batman/release-root.pub` 與 app | 只簽「簽章鑰匙背書」 |
| 簽章鑰匙 K<sub>i</sub> | ES256 | 使用者的 **YubiKey PIV slot 9c**(裝置內產生、不可匯出) | 簽每個發行版本 |
| 測試根鑰匙 T | ES256 | repo `tests/keys/`(公開) | **只有 prov_test image** 另外信任它(協定 §9 開發 / 正式隔離);release image 的 gate 斷言不含 T |

選 ES256 而不是 ed25519:所有 YubiKey 5 的 PIV 都支援 P-256;節點已有 `proto.VerifyES256` 與 `cose.VerifySign1`(F22),**不引入新演算法或新格式**。⚠️ 使用者的 YubiKey 型號 / 韌體未讀(使用者在遠端);host 端簽章工具鏈(`yubico-piv-tool` 或 PKCS#11 `ykcs11` + openssl)在 YubiKey 插上時實測,本設計只依賴「PIV slot 9c 能做 ECDSA P-256 簽 32 B digest」。

**背書** E<sub>i</sub> = COSE_Sign1(R),content type `batman/relkey`,外部標籤 `batman-relkey-v1`,payload `{1: K_i 公鑰 65 B, 2: serial(uint,從 1 起)}`。
**發行簽章** S = COSE_Sign1(K<sub>i</sub>),content type `batman/release`,標籤 `batman-release-v1`,payload:

```
release = { 1: version(tstr,BATMAN_VERSION 全串), 2: board(tstr), 3: sha256(SHA256SUMS),
            4: payload 大小(uint), ? 5: [* tstr](可以從哪些較新版本降回本版), * uint => any }
```

`update-manifest` key 5 = CBOR `[E_i, S]`(兩個 COSE_Sign1);key 1–4、6 必須與 S 的 payload 相同(不同 → `reason` 簽章不符)。

**撤銷**(D4「背書 / 撤銷免重燒」):image 內建 `/usr/share/batman/release-min-serial`;節點拒絕 serial 小於它的背書。K<sub>1</sub> 外流 → 用 R 背書 K<sub>2</sub>(serial 2),發一版以 K<sub>2</sub> 簽、`min-serial = 2` 的 image;裝了它的節點從此拒絕 K<sub>1</sub>。**誠實界線**:還沒更新到那一版的節點仍接受 K<sub>1</sub>(沒有線上撤銷;節點不連網)。只有 R 外流 / 遺失才需要換 R = 重燒(轉賣工具)。

**防降級**:比較順序:MAJOR.MINOR.PATCH,再比 build N;channel 不同 → 不可比,拒絕(⚠️ `docs/VERSIONS.md` 現在沒有寫比較規則,本 PR 補進去);新版本 > 目前 → 可;= 目前 → 可(重裝修復);< 目前 → 只有當**目前版本**列在 S 的 key 5 才可。修 CDDL `:273` 的註解(key 6 = 「可以從哪些較新版本降回本版」)。

#### 3.7.2 build / 發行端

- `scripts/build-ab-payload.sh`:`metadata` 加一行 `release=<BATMAN_VERSION>`(F18:現在 `version=` 是 build 時間戳,不改它,避免動到既有讀者)。
- 新 `scripts/release-sign.sh <payload>`:讀 `SHA256SUMS` 與 `metadata`,組 `release` payload,以 YubiKey 簽成 S,和既有的 E<sub>i</sub>(`release-keys/relkey-<i>.cbor`,公開)一起寫 `<payload>.sig.cbor`。另一支 `release-endorse.sh`(只在換簽章鑰匙時、離線用 R)。
- 發行流程(`docs/VERSIONS.md` / release 文件)加一步:簽 → 上傳 `.sig.cbor` 與 payload;轉賣工具的 image 清單同步(§3.9)。

#### 3.7.3 節點端動詞(helper)

| 動詞 | 做什麼 | 拒絕(`update-check-resp` reason,CDDL `:122-129`) |
|---|---|---|
| `update.check {1: manifest}` | 驗 E(R 公鑰;prov_test 另加 T)、serial ≥ min、S(K)、board = 本機、版本規則、大小 ≤ RAM 預算;通過 → 在 p6 `/opt/batdata/state/update-pending`(root 0600)記 `{version, sha256(SHA256SUMS), size, serial}` | 試用中、p5 未 seed、板子不符、需要中間版本、降級不允許、RAM 不足(8)、簽章不符(**新碼 11**;9、10 已被 reset / legacy 用,CDDL `:122-131`)、`.txn` 未完成(**新碼 12**) |
| `update.prepare`(owner-op) | 要有 pending 且 bulk 已收完(§3.8);見 §3.7.4 | 無 pending → `E_STATE`;檔案不符 → reason 11 |
| `update.apply`(owner-op) | 要有已 prepare 且仍有效的槽 → `batman-slot arm <sha>` → 回應送出後 2 s `reboot`(經既有 `batman-slot` / `shutdown.reason` 路徑) | 無 prepared → `E_STATE` |
| `update.status`(唯讀) | 由 pending + 目前版本 + `batman-slot is-trial` + `bad-slot` 推:0 idle、1 receiving(bulk 開著且未收完,含百分比)、2 verifying、3 written、4 trial、5 committed、6 reverted | — |

RAM 預算:`/tmp` 可用 − 32 MiB 餘裕 ≥ payload 大小(只落地一份;root.squashfs 不解開,F25)。p6 `update-pending`:撐過重開(apply 之後要報 4 / 5 / 6);commit 或 revert 後由 helper `--boot` 清掉(看到結果就刪)。

#### 3.7.4 `update.prepare` 與 `batman-slot` 拆兩步(兩板共用檔)

1. helper 把上傳檔改名搬進自己的目錄(`/tmp/run/batman-prov/update/payload.tgz`,同一個 tmpfs,不複製;`O_NOFOLLOW` + fstat:regular、link count 1、大小 = 簽章的大小)。
2. 解出除 `root.squashfs` 以外的成員到 root-only 目錄(同 `platform-ab.sh:325-329`);`sha256(SHA256SUMS)` 必須等於 S 的 key 3;`metadata` 的 `board=` 與 `release=` 必須等於 S。
3. `batman-slot write <dir> <payload.tgz>`(**新動詞** = 現在的 `apply` 到 `:714` 為止):precheck → begin_write → 串流 dd → 讀回驗證;**不 arm**;成功時在目標槽 boot 分割寫 `BATMAN-VERIFIED` = `sha256(SHA256SUMS)`。
4. `batman-slot arm <sha>`(**新動詞** = 現在 `:716-738`):先重驗 — 目標槽沒有 `BATMAN-BAD`、cmdline 正確、`BATMAN-VERIFIED` 等於 `<sha>`、`node_checks` 通過;再 arm + 讀回。
5. 既有 `batman-slot apply` = `write` + `arm`(sysupgrade 路徑行為不變)。
6. **為什麼上傳檔被 provd 改寫也不怕**:helper 用的 `SHA256SUMS` 是步驟 2 自己解出、比對過簽章的那份;步驟 3 的讀回以它為準,payload 在 dd 前後被改都會讓讀回失敗 → 槽保持 invalidated、不 arm(F19)。

#### 3.7.5 autocommit(D6)

`batman-autocommit:506-511` 的 BLE 檢查:health 行的 `boot_id` 必須等於本次開機、`ts` 在 60 s 內,否則視同「BLE 不健康」;**仍然只 WARN**(P-U5)。

#### 3.7.6 不變 / 不做

- 操作員 ssh `sysupgrade` 路徑**不要求簽章**(root 本來就能做任何事;rc / harness image 沒有簽章)。誠實界線寫進 PR。
- 經 mesh 分發給整隊(#116)不做。

### 3.8 大量傳輸(`bulk/*`)與 HTTP 通道

#### 3.8.1 暫時 AP(helper `bulk.open` / `bulk.close`)

- 前提:擁有者 owner-op、purpose 0、有 `update-pending`;否則 `E_STATE`。
- 動作(全部 helper,root):
  1. `wireless.default_radio0.disabled=1`(手機 AP 暫停,D5)。**不改** `default_radio0.key`(F8:它在 PRESERVE,改了會被 save 進 p5)。
  2. 新 `wireless.bulk`(radio0、mode ap、ssid `Batman-<sn 末 4>-u`、psk2、20 字隨機 passphrase、network `bulk`);`network.bulk`(static `192.168.250.1/24`,不在 br-ahwlan);`dhcp.bulk`(4 個位址);`firewall` zone `bulk`(input REJECT、forward REJECT),規則只開 DHCP 與 TCP 8095 到本機。
  3. `uci commit` 上述四個檔 + `wifi reload` + `/etc/init.d/firewall reload`。
  4. 回 `{1: ssid, 2: passphrase, 3: "192.168.250.1", 4: 8095, 5: 900}`(15 分鐘)。
- `bulk.close`、逾時、helper 重啟、**每次開機**:刪 `wireless.bulk`、`network.bulk`、`dhcp.bulk`、firewall bulk 段,恢復 `default_radio0.disabled`,commit + reload。開機清理放在一支早於 network 的 init(`batman-bulk-clean`,START=11),避免斷電重開時 AP 帶著用過的 passphrase 回來。
- 與既有寫者的關係:meshpoint 只在 uci-defaults 跑(F10),不會把 `wireless.bulk` 接進 ahwlan;keyguard 只動 `CHANGE-ME-NOW` key(bulk 是隨機);99zz 只在 unclaimed 時改 AP key(bulk 需要已認領)。⚠️ H4 要上機確認 `wifi reload` 後 joinwatch / config-save tick 不會把 `bulk` 段或 `disabled` 存進 p5(F8 的 PRESERVE 不含它們 — 預期不會)。
- 5 GHz:radio0 現在 channel 36(非 DFS);country 由 §3.3 同步。⚠️ CYW43455 在 BLE 連著時開 AP 的共存(B13)H4 實測。

#### 3.8.2 HTTP 通道(provd)

- provd(與主機共用網路,F11;uid 471 可綁 > 1024 的埠)內建 HTTP server,埠 **8095**(04 上未被佔用:22 53 80 443 2947 8080 8081 8087;OTS 8088/8089/8443 經 docker DNAT)。
- 端點(協定 §4.2):`POST /batman/v1/session`、`POST /batman/v1/msg`;跑完整 §3 Noise,不依賴 TLS;每 session 一次一個請求;與 BLE **共用**全域交握額度(20/分)與 session 上限。
- **只收 PSK 交握(擁有者 / 成員),不收 NX(匿名)** → 認領只能經 BLE(必須在旁邊);這是 HTTP 通道比 BLE 窄的地方,§7 的關鍵。
- 監聽位址:
  - **ahwlan**(`10.41.x.x:8095`)常駐 — D6 的一般備援。F9:整個 mesh 都連得到 → 只有擁有者 / 成員 PSK 能完成交握。
  - **bulk**(`192.168.250.1:8095`)只在 bulk 開著時。
- **上傳**:`PUT /batman/v1/bulk/0`,header `X-Batman-Session` = 一個在 **bulk 位址上**建立、角色為擁有者的 HTTP session;`Content-Length` 必須等於 pending 的大小;只在 bulk 位址收;寫到 `/tmp/run/batman-provd-bulk/payload`(provd:provd 0700,由 init 以 root 建、掛進 jail rw);超過大小 / 中斷 → 刪檔。payload 是公開的 image,不加密;完整性由 §3.7 的簽章 + 讀回負責。
- 協定文件:§4.2 加上傳端點、PSK-only 規則、埠;CDDL 不變。

### 3.9 轉賣工具

照 `254-stage1-impl.md` §4.5(`:262-300`)實作 `scripts/transfer-flash.ps1`(Windows,主要)與 `scripts/transfer-flash.sh`(Linux),**不改契約**:內建發行 image 清單(檔名、`.img.gz` sha256、board、版本)、只接受讀卡機上的卡(Windows `BusType=USB` + Removable、非 boot / system、≤ 512 GB、打確認字串;Linux `removable=1` / `mmcblk*`、未掛載、非 root 所在)、全卡清零(Windows 自己的 4 MiB 迴圈寫 `\\.\PhysicalDriveN`,不用 `clean all`;Linux `dd … conv=fsync` 或 `blkdiscard -z`)、寫 image、讀回頭尾、≥ 64 個隨機 1 MiB 區塊在 image 之後全 0、`--test-target-file`。發行流程加一步更新清單(§3.7.2 同一步)。`scripts/flash-card.sh`(1.8.0)不動。

### 3.10 LuCI reset 文字(firmware)與 app 說明頁文字

- firmware patch `flash.js`:`Perform reset` 的說明改為「重新套用設定(不清除擁有者與資料)」;動作不變(`firstboot -r -y` 只清本槽 overlay,開機時 96 從 p5 還原,F22)。`rc.button/reset` 已在 P1 改(F23),不動。
- app 說明頁(賣方 / 買方 / 遺失手機)的文字照 stage1-impl `:282-292` 收進 `docs/`,供 app 引用;app 畫面不在本 PR。

## 4. 擁有權(每個資源一個寫者)

| 資源 | 寫者 | 讀者(唯讀) |
|---|---|---|
| p5 prov 紀錄(owners、tag key、adv_owner_key) | helper(`commit`,P1/P2 既有) | provd 經 helper |
| `system.hostname`、`wireless.radio1/radio0.country` | helper(`settings.set`);入網時 helper 的 `netJoin`(country);操作員 ssh | config-save(→ p5)、halow-status |
| `wireless.default_radio0.disabled`、`wireless.bulk`、`network.bulk`、`dhcp.bulk`、firewall bulk 段 | **helper 的 bulk**(open / close / 逾時);**`batman-bulk-clean`**(開機,START=11)— 兩者不會同時跑(開機清理在 helper S89 之前) | netifd、hostapd、firewall |
| `/tmp/run/batman-provd-bulk/`(payload 上傳) | provd(寫);init 建目錄(root) | helper(搬走後只有 helper) |
| `/tmp/run/batman-prov/update/`、`/tmp/run/batman-prov/diag/` | helper | — |
| p6 `state/update-pending` | helper(check 寫、`--boot` 看到結果後刪) | helper(status) |
| 目標槽(rootfs、boot 分割、`BATMAN-VERIFIED`、`BATMAN-BAD`) | `batman-slot write`(helper 呼叫)或 sysupgrade stage 2 — **同一時間只會有一個**:`batman-slot` 既有的鎖 ⚠️ 實作時確認 write 與 sysupgrade 互斥的鎖名 | autocommit、`batman-slot verify` |
| tryboot 旗標 | `batman-slot arm`(helper 呼叫)或 `apply` | autocommit |
| `/usr/share/batman/release-root.pub`、`release-min-serial` | build(image 內,唯讀) | helper |
| `/www/cgi-bin/bundle` 的放行判斷 | — (每次請求讀 `info.state` 與 `batman-dev-open`) | uhttpd CGI |

## 5. 契約

| 介面 | 寫 → 讀 | 格式 / 有效 | 缺 / 舊 / 壞 | 誰寫得到(信任邊界) |
|---|---|---|---|---|
| `update-manifest` + `[E, S]` | app → provd → helper | CDDL `:267-275`;§3.7.1 | 驗不過 → reason 11,fail-closed | 任何擁有者 session(簽章才是權威) |
| p6 `update-pending` | helper → helper | CBOR `{version, sha, size, serial}`,root 0600 | 缺 → `update.status` 0、prepare `E_STATE`;壞 → 刪掉當缺,fail-closed | root |
| bulk 上傳檔 | provd → helper | 大小 = pending.size;內容 = A/B payload tgz | 大小不符 → 刪;內容被改 → 讀回失敗、不 arm(§3.7.4 步驟 6) | provd(uid 471)— **不被信任**,只當原料 |
| `BATMAN-VERIFIED` | `batman-slot write` → `arm` | 一行 sha256 hex | 缺 / 不符 → arm 拒絕 | root |
| HTTP `/batman/v1/*` | app → provd | 協定 §4.2;PSK-only | 交握失敗 → 斷;超額 → 429 + 連線關 | ahwlan 上任何人(整個 mesh,F9)/ bulk AP 上的人 |
| `join-reasons` 表 | repo → joinwatch、helper | `code<TAB>句子` | 句子不在表 → code 0 + 原句 | image(唯讀) |
| `settings-set-req` | app → helper | CDDL;§3.3 | 未知 uint key 忽略;文字 key / 兩項同時 → `E_SCHEMA` | 擁有者 owner-op |
| `diag.read` handle | helper → provd | 16 B 隨機,10 分鐘 | 過期 / 不符 → `E_STATE` | provd(只有它拿得到 handle) |

## 6. 生命週期矩陣

| 路徑 | 今天 | 改後 | 證明的測試(H4) |
|---|---|---|---|
| 首次安裝 / 第一次開機 | P3 動詞 `E_UNSUPPORTED` | 動詞可用;`batman-bulk-clean` 無事可做 | `prov-p3-routes-254`(每個動詞的角色 / owner-op / 回應) |
| 啟動 | — | provd 起 HTTP 監聽 ahwlan:8095 | `prov-http-254`:PSK 交握成功、NX 被拒 |
| 正常停止 | — | provd 停 → HTTP 關;bulk 由 helper 收 | `prov-bulk-254` 的 stop 臂 |
| 重開 | — | bulk 在開機時清掉;`update-pending` 撐過、報 trial / committed / reverted | `prov-bulk-254` 斷電臂、`prov-update-254` |
| 升級 / 回滾 | ssh sysupgrade only | + app 路徑(簽章);sysupgrade 行為不變 | `prov-update-254`(正向 + 4 個負對照:錯簽章、錯板子、降級、被改的 payload) |
| 降級到沒有本 PR 的版本 | — | 舊版沒有 P3 動詞 → app 看到 `E_UNSUPPORTED`;舊版沒有 `batman-bulk-clean` → **若在 bulk 開著時回滾**,舊 overlay 不含 bulk 段(bulk 段只寫在新槽的 overlay)⚠️ 審查確認 | `prov-update-254` 回滾臂 |
| crash / crash loop | — | provd crash:HTTP 斷、bulk 由 helper 逾時收;helper crash:bulk 留著直到 helper 重啟收(`--boot` 也清) | `prov-bulk-254` kill 臂 |
| 斷電 / 斷網 | — | bulk:開機清;prepare 中斷電:槽保持 BAD(F19 begin_write)、不 arm;apply 後斷電:tryboot 一次性(autocommit `:70-72`) | `prov-update-254` 斷電臂(prepare 中) |
| 依賴重啟:bluetoothd / dbus | P2 | 不變;HTTP 不依賴它們 | P2 既有 |
| 依賴重啟:helper | P2 ctl 重連 | bulk 段由 helper `--boot` 清;pending 從 p6 讀回 | `prov-bulk-254` |
| 依賴重啟:netifd / `wifi reload` | — | bulk 段在 commit 後 reload 仍在 | `prov-bulk-254` |
| 平台 bcm2711 | — | 實測 | 全部 |
| 平台 bcm2710 | — | `batman-slot` 兩板共用 → 只做沙箱(P-U14) | CI 沙箱 |

## 7. 安全

**資產**:節點控制權(更新 = 任意程式碼)、擁有者 / 成員秘密、診斷內容(MAC / IP / 名稱)、可用性(手機 AP、BLE)。

| 行為者 | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| mesh 上任何人(F9) | 打 HTTP 8095:暴力、DoS、認領 | PSK-only(沒有匿名角色,不能認領);共用全域交握 20/分;每 session 一個在飛;body 上限 | `prov-http-254`:NX 被拒、超額、超大 body |
| mesh 上任何人 | 下載 `/cgi-bin/bundle` | claimed / member 一律 403 | `prov-bundle-gate-254` |
| 路人(BLE / bulk AP 附近) | 連 bulk AP | WPA2 一次性 passphrase(只經 Noise 給擁有者)、15 分鐘、zone 只開 8095 + DHCP、上傳要擁有者 HTTP session | `prov-bulk-254`:錯 session / 錯大小 / zone 掃描 |
| 被入侵的 provd | 改 payload、給假 manifest、亂開 bulk | helper 驗簽(provd 拿不到 K / R);讀回以 helper 自己的 SHA256SUMS 為準;bulk 要擁有者 owner-op(provd 偽造不了 owner-op) | `prov-update-254` 被改 payload 臂;Go:假 owner-op |
| 被入侵的 provd | 經 bulk 目錄讓 helper 跟 symlink | helper `O_NOFOLLOW` + fstat(regular、link 1、大小);rename 在 helper 端 | Go / shell:symlink、hardlink、大小不符 |
| 前任 / 離開的擁有者 | 用舊 tag key | remove 後 psk 消失、session 被切(P2 reconcile) | `prov-owner-254` |
| 隊員(成員) | 讀 bundle、改設定 | 成員只到 status 摘要 / diag summary / peers | `prov-p3-routes-254` 成員臂 |
| 供應鏈 / 我們自己的錯 | 簽了壞 image;K 外流 | min-serial 撤銷(界線:未更新的節點);防降級;R 離線兩份 | Go:serial < min、降級、channel 不同 |
| 本機非 root | 寫 `/tmp/run/batman-provd-bulk` | 目錄 provd:provd 0700 在 root-only `/tmp/run` 下(#280) | tmp-trust allowlist + 測試 |

**權限**:helper(root)做所有寫入;provd 不新增 capability(HTTP 用 > 1024 的埠)。**秘密**:bulk passphrase 只在 Noise 回應裡,不進 log、不進 p5(F8);K 在 YubiKey、R 離線。**失敗模式**:fail-closed(驗不過不寫、不 arm;bulk 逾時收;開機清)。

## 8. 測試(H4 依此寫;每項要有負對照)

- `prov-p3-routes-254`(tier B,provd + host 擁有者 client D2):每個 P3 動詞的角色(匿名 / 候選 / 成員 / 擁有者)、owner-op 缺 / 錯、回應形狀;負對照 = wsl.22(P3 前)全部 `E_UNSUPPORTED`。
- `prov-owner-254`:add → 新擁有者能 auth;重送輪替 tag key;remove → 被移除者 session 斷、psk 失效、`adv_owner_key` 換;不能移除最後一位。
- `prov-settings-254`:get;改名(以 U5 結果定副作用斷言);國家:入網時 `E_STATE`、未入網改國家 + 頻道不合法拒絕;`--save` 失敗還原(白箱:wbox 讓 config-save 失敗)。
- `prov-status-diag-254`:status 鍵 1–5 / 15 與 halow-status 一致;成員只拿摘要;diag summary;bundle 分塊 > 64 KiB 完整取回、tar 可解、沒有秘密檔;handle 過期。
- `prov-bundle-gate-254`:claimed → 403;unclaimed + dev-open → 200;`status` 仍 200。
- `prov-http-254`:ahwlan:8095 PSK 交握與 BLE 等價;NX 被拒;額度與 BLE 共用。
- `prov-bulk-254`:open → AP 起、手機 AP 停、zone 只開 8095;close / 逾時 / provd kill / helper kill / 斷電重開 → bulk 段消失、手機 AP 回來、p5 沒有 bulk passphrase。
- `prov-update-254`:test 根鑰匙 T 簽的 image 經 app 路徑升級 → trial → commit;負對照:錯簽章、serial < min、錯板子、降級、上傳後改 payload(讀回失敗、不 arm)、prepare 中斷電(槽 BAD、仍在舊槽)。
- `prov-transfer-tool-254`(WSL loop 檔,§3.9);真卡(使用者有讀卡機)。
- `prov-eeprom-hooks-254` 補項(D11)。
- Go:§3.2 邊界、§3.6、§3.7 驗證全部分支、§3.8 HTTP、§3.5 分頁;mutant 每個拒絕分支。

## 9. 未決 / ⚠️

1. **U5**(D8):等使用者回覆「IP 沒回來時手動改回」;結果決定 §3.3 步驟 3–4 的寫法。
2. **YubiKey** 型號 / 韌體與 host 簽章工具鏈(§3.7.1)— 使用者回到電腦旁時實測。
3. `netJoin` 是否已套 `net_config` key 5(§3.3)— 實作時查。
4. `batman-slot` 寫入互斥的鎖名(§4)、`batman-dev-open` 的位置(§3.5)— 實作時查。
5. B13:BLE 連著時開 bulk AP 的共存 — H4 實測。
6. 降級到沒有 `batman-bulk-clean` 的版本時 bulk 段是否殘留(§6)— 審查確認。
7. 冪等快取不做(§1.2)— 審查確認沒有傷害。

## 10. 要改的文件(本 PR)

- `219-protocol.md`:`:218` 拿掉「階段 1 不實作」;§4.2 加上傳端點 / PSK-only / 埠;`:447` 改為輪替 `adv_owner_key`;`:210` 與 field-provisioning `:474` 對齊 D10。
- `219-protocol.cddl`:`:273` key 6 註解;reason-code 加 11(簽章不符)、12(`.txn` 未完成);`update-manifest` key 5 = `[E, S]`。
- `254-stage1-impl.md`:§10.6 / §10.7 依 D3;`:171`(bundle 用 handle 分頁);`:357` `E_STATE` → `E_BUSY`(與 h23 / Go 測試一致)。
- `254-p1-impl.md`:`:465`(admins +1 刪)、`:466`(未知 key 忽略)。
- `docs/VERSIONS.md`:版本比較規則。
