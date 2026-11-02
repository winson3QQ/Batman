# #254 PR-P3:擁有者 / 設定 / 狀態 / 診斷 / 更新 / 上傳 / 轉賣工具(設計 v4)

狀態:v4,2026-11-02,送兩位審查(v1 = 96a578d、v2 = 03963d9 都兩位 REJECT;v3 = 6433520 審查者 B REJECT(窄,近收斂)、審查者 A 的報告被安全分類器擋下未交;§12 回應 v1、§13 回應 v2、§14 回應 v3)。上層:`254-stage1-impl.md` §10.6;協定 `219-protocol.md` v0.8 + `219-protocol.cddl`;P2 = `254-p2-impl.md` v8.5(已出貨 `1.5.14-wsl.22`)。
原則(使用者):**只做必要的修改**、**失敗就回到之前的狀態**。「事實」附 `file:line` 或 04 實測;沒有證據的標 ⚠️。

## 0. 一句話

provd 仍是唯一入口;P3 補上協定動詞(擁有者增刪、設定:改名 / 國家 / **手機 AP 配對**、自己的狀態、診斷、`peers/challenge`、軟體更新、上傳),每個都由 helper(root)執行並自己驗證。軟體更新以**兩層鑰匙**(離線根鑰匙背書 YubiKey 上的簽章鑰匙,ES256 + COSE_Sign1)簽章;116 MiB 的 payload **經這台節點自己的手機 AP** 用 HTTP 上傳,上傳入口只在擁有者經 BLE 開窗的 15 分鐘內、只對該擁有者、只對連在這台 AP 上的手機開;同一個 HTTP 伺服器在 **BLE 不健康時**自動當備援入口(只收擁有者 / 成員)。**沒有暫時 AP**。

## 1. 決策、範圍

### 1.1 使用者決策(#254 留言 6569483517、6570171273、6570854836、6571066959)

| # | 決策 |
|---|---|
| D1 | 順序:P3 設計 + 兩位審查 → H4 照本文件契約寫並先 merge → P3 實作 → rc → 上機 → H4 + P3 完成後、app 開工前跑全套 |
| D2 | 重做 host 端 provd 擁有者 client(H4) |
| D3 | `update/*`、`bulk/*` 算進 P3 |
| D4 | B18 兩層鑰匙:離線根鑰匙(兩份)+ YubiKey 上的簽章鑰匙;背書 / 撤銷免重燒;防降級。終端使用者不持有發行鑰匙 |
| D5′ | **沒有暫時 AP**:`bulk/open` 經 BLE 開 15 分鐘上傳入口,只給該擁有者,走這台節點既有的手機 AP;手機 AP 不暫停(取代 v1 的 D5) |
| D6′ | autocommit BLE 檢查維持 WARN(P-U5,等 #305),只補 boot_id / ts 新鮮度。**HTTP 備援只在 BLE 不健康時自動開、恢復就關**(取代 v1 的「常駐」) |
| D7 | `status` 只做 self;team 進 checklist |
| D8 | 改名:**待 U5 探針**(使用者回現場時由 Claude 在 04 跑);本設計只定「改名寫什麼、失敗怎麼還原」,IP / 重開的副作用以 U5 結果補入(§3.3、§9) |
| D9 | 國家以 `net_config` 為準;單台設定只在未入網時可改(實作方式見 D15) |
| D10 | `diag/summary` 成員可讀;`diag/bundle` 只給擁有者 |
| D11 | `prov-eeprom-hooks-254` 缺項併 H4 |
| D12 | 版本:同 MAJOR.MINOR.PATCH 時正式版(無後綴)> 任何 `-<channel>.N`;正式 → 開發只在簽章允許時 |
| D13 | 更新前兩端 Wi-Fi 都檢查;**節點手機 AP 關著 → 拒絕開上傳**(不自動開:發射是人的決定);**拒絕經 mesh 轉來的上傳**;節點回報是否跑 TAK server(OTS),app 在 apply 前警告 |
| D15 | **國家不同就拒絕入網**:`network/join`、`network/update` 的 `net_config` 國家 ≠ 節點國家 → 拒絕;app 在入網前用 `settings/set` 改國家;P2 wireless txn 不動;整個網路一起改國家進 checklist(#254 留言 6571580317,取代 v2 的「國家併進 txn」) |
| D16 | **HTTP 兩種模式都只收這台節點手機 AP 的 client**(accept 時檢查);BLE 壞時擁有者連上這台節點自己的 AP(配對過) |
| D18 | **autocommit 看 helper 與 provd**:新版試用期間 helper 必須在跑,provd 至少有一次連續穩定 ≥ 60 s(之後被路人弄當不算);藍牙無線電仍只 WARN(D6′)(#254 留言 6572031133) |
| D19 | **HTTP 來源由防火牆檢查**:image 加 `kmod-nft-bridge`,nft bridge 規則只讓手機 AP 那個 bridge port 進來的封包到 TCP 8095(取代 v3 的 IP→MAC 檢查) |
| D20 | **遺失手機**:`owner/remove` 後 app 提示以 key 20 換這台的 AP 密碼;認領後 app 建議加一位備用擁有者(只有一位擁有者時手機遺失只能重燒,L59) |
| D17 | CM4:開發用 Lite(SD 卡),量產用 eMMC → eMMC 的轉賣 / 遺失手機重燒路徑(rpiboot)量產前要做(checklist);本 PR 的轉賣工具只做 SD 卡 |
| D14 | **手機 ↔ 自己節點 Wi-Fi 配對**:擁有者 app 經 BLE 設這台手機 AP 的 SSID + 強密碼(存 p5,失敗還原);不隱藏 SSID;EMCON(AP 平常關 / 功率)進 checklist |

### 1.2 範圍

**在本 PR**:§3。**不在本 PR**(理由):
- app 本身(U9);app 端要做的檢查寫在 §3.11「App 需求」。
- `status` team(D7);EMCON(D14);autocommit BLE 擋 commit(D6′);`owner.replace`(L29 / S3);恢復出廠、608B(#255);bcm2710 與 CM4 實測(§6 平台列)。
- 邀請 QR 的產生 / 申請 / 同意:網主 app 的簽章物件(協定 §7.6);節點只收 `network/join` 選填的 `invite_id`(P2 已轉送),**節點端無新增**。
- 冪等快取:不做;每個動詞的重送語意列在 §5.2(協定 §4.2 對 HTTP 要求快取 → 刻意偏離,理由同表)。
- 未簽章的更新路徑**不關**:操作員 ssh `sysupgrade`、LuCI 刷韌體、openmanetd 的 local upgrade(都要管理密碼)— 列為誠實界線(§7)。

### 1.3 事實(main 2ecf1cb;節點 = 04 `1.5.14-wsl.22`;審查者另行查證的標 〔A〕〔B〕,v2 審查補的標 〔A2〕〔B2〕)

| # | 事實 | 證據 |
|---|---|---|
| F1 | provd 對 `p3Types` 在角色判斷前回 `E_UNSUPPORTED{1:typ}` | `provd/session.go:68-70`、`:623-625` |
| F2 | 角色白名單:擁有者 = info、op/nonce、network/*、ssh_keys/set、root_password/reset;成員 = info、network/update | `session.go:79-81` |
| F3 | helper `owner.add`(重送同 pub = 輪替 tag key;上限 4)、`owner.remove`(不能移除最後一位;輪替 `adv_owner_key`) | `node/node.go:834-898`、`:385-390` |
| F4 | `owner.*` 邊界沒有測試 | grep `node/*_test.go` |
| F5 | `settings.set` 收 hostname 回 `rename-pending`;沒有 `settings.get` | `node.go:760-770`、`readonly.go:104-133` |
| F6 | CDDL settings:1 名稱、2 國家、10 halow、11–13 ptt/gps/lora、`* uint => any` | `219-protocol.cddl:190-200`、`:431-440` |
| F7 | 04:`radio1.country='US'`、channel 40;`radio0` 沒有 country;`halow-setkey` 不設國家 | 04 `uci show wireless`;`halow-setkey:92` |
| F8 | config-save PRESERVE:hostname、radio1 mesh_id / key / channel / country、`default_radio0.key`、ahwlan ipaddr / proto、openmanetd 兩個旗標;**不含 `default_radio0.ssid`、`radio0.country`** | `batman-config-save:41-52` |
| F9 | 手機 AP `phy1-ap0`、`eth0`、`bat0` 在同一座 `br-ahwlan`(10.41.1.3/16);ahwlan zone input ACCEPT;docker0 172.17.0.1、br-ots 172.20.0.1 另有位址 〔A〕〔B〕 | 04 `ip -br addr`、`uci show firewall` |
| F11 | provd 的 ujail 沒有 netns、沒有 seccomp、capability 全空;掛載全是唯讀 〔A〕〔B〕 | `files/batman-provd.init:18-19`;`batman-provd.json` |
| F12 | provd 讀 helper 回覆 > 64 KiB 就斷線 | `provd/helper.go:129-141` |
| F13 | provd 已會切塊回應,沒有測試 | `session.go:349-372` |
| F14 | helper `diag.bundle` = 三個指令的純文字,inline、無上限 | `cmd/batman-provhelper/main.go:393-401` |
| F15 | `/www/cgi-bin/bundle`(與 `deploy/provisioning/www/bundle` 鏡像、`scripts/check-provisioning-sync.sh:34` 檢查)無驗證;`halow-status:183` 文字輸出引用它;`mesh` 頁抓同伴的 `status?json` 〔B〕 | 各檔 |
| F16 | joinwatch `verdict()` 的句子**帶變數**(`$KEY`、`$RTYPE`、`ch$CH/$MID`、`$STA`…)〔A〕 | 04 `/usr/bin/joinwatch:70-80` |
| F17 | helper `sign.peer`(全域 2/s)沒有測試 | `node.go:238`、`:324-377` |
| F18 | 沒有任何 image 簽章;`metadata` = `board=`、`version=`(build 時間戳)、`size=` | grep;`build-ab-payload.sh:69` |
| F19 | `batman-slot apply`:precheck → begin_write(BAD)→ 讀回驗證(`:692-714`)→ arm(`:716-738`) | `batman-slot:592-738` |
| F20 | sysupgrade stage 2 一定重開;live `batman-slot apply` 支援;rootfs 串流 = stage-root + 呼叫端串流 + apply 〔B〕 | `platform-ab.sh:325-377`;`batman-slot:456` |
| F21 | autocommit BLE 檢查 WARN-only、不比 boot_id / ts;health 行已有 `boot_id=`、`ts=`,每 15 s 寫 〔A〕〔B〕 | `batman-autocommit:506-511`;`health/health.go:196` |
| F22 | `cose.VerifySign1(item, contentType, label, pubs)`(ES256、low-s)、`proto.VerifyES256` 〔B〕 | `cose/cose.go:36-70`、`proto/proto.go:107` |
| F23 | LuCI flash.js 仍「Perform reset」+ `firstboot -r -y`;`rc.button/reset` 已在 firmware P1 改 | firmware `flash.js:104,402,408`;`files/etc/rc.button/reset` |
| F24 | 沒有轉賣工具 | repo grep |
| F25 | 04 RAM 8 GB、無 swap;3A+ `/tmp` 212 MB;release payload ≈ 126 MB | 04;`219-field-provisioning.md:448` |
| F26 | **`Slots = 2`(BLE + sock 共用)、全域交握 20/分;交握中與 fake path(10 s)不可擠;擠不掉就拒絕;有任何 session 就撤 BLE 廣播** | `server.go:33-35`、`:645-661`、`:739-771`;`session.go:150-160`;`bluez.go:772` |
| F27 | **`SHA256SUMS` 是 tar 的最後一個成員**;`batman-slot apply` 複製目錄裡所有 `start*.elf`、`fixup*.dat`、`*.dtb`、`overlays/*`,但只驗 `SHA256SUMS` 列名 | `build-ab-payload.sh:73`;`batman-slot:679-682`、`:697-701` |
| F28 | `batman-config-save --check` 拿 `cfgsave.lock`(等 5 s)並 ro 掛 p5;`--on-join` 拿不到鎖就跳過,連 8 次寫 `cfgsave-lock.busy`,`batman-slot` 看到就拒 OTA;04 實測 `--check` 0.56 s、`halow-status json` 0.34–0.41 s 〔A〕〔B〕 | `batman-config-save:244-258`;`batman-slot:510-512` |
| F29 | **P2 完全沒有處理國家**(Go 非 vendor 0 筆 `country`);`.txn` 快照只有 mesh key / id / channel + radio disabled | grep;`provstore/txn.go:12-40`、`node/wtxn.go:162-192` |
| F30 | `ReadTxn` 只接受 2 或 3 行,其他當讀不到 | `provstore/txn.go:104-134` |
| F31 | `ubus call hostapd.phy1-ap0 get_clients` 在 04 可用(回 `clients{}`) | 04 |
| F32 | openmanetd 也寫 hostname / dhcp / network(`uci set system.@system[0].hostname='%s' && uci commit system`)〔B〕 | 04 `strings /usr/bin/openmanetd` |
| F33 | `/tmp/run` 是 `drwxr-xr-x root`(只有 root 能建項目,但不是 0700) 〔B〕 | 04 |
| F34 | hostapd 把 passphrase 寫進 `/tmp/run/hostapd-phy1.conf`(0644);`/etc/config/wireless` 0644 〔A〕〔B〕 | 04 |
| F35 | `batman-slot` 寫入互斥 = `$RUNDIR/batman-slot.lock`(mkdir + pid / cmdline)+ `$RUNDIR/batman-slot.busy`(helper `otaBusy()` 讀);sysupgrade stage 2 共用 〔A〕〔B〕 | `batman-slot:82-95`、`:155`;`node.go:213-217` |
| F36 | `batman-dev-open` = `/etc/batman-dev-open`,現有程式只 `os.Stat` 〔A〕 | `main.go:387,564` |
| F37 | 非唯讀 helper 動詞用阻塞的 `n.mu.Lock()`;`otaBusy` 只擋 `net.apply` / `network.leave` 〔B〕 | `node.go:189`、`:213-217` |
| F38 | provd `mapHelper`:`hEState`、`hEApply` → `E_REJECTED`(無 detail);`hESchema` → `E_REJECTED` + CRIT「provd bug」;`hEUnsupported` → `{1: typ}` 〔B〕 | `session.go:563-579` |
| F39 | 協定錯誤碼只有 1–13(沒有 E_STATE / E_SCHEMA);`E_REJECTED` 附 reason;reason-code 1–10 已用 | `219-protocol.md:173-189`;`219-protocol.cddl:118-131` |
| F40 | 版號 `<M.m.p>-<channel>.<build>+<feed>.fw<fw>`;channel `wsl` / `ci` / `rel`;正式版不帶後綴 〔B〕 | `docs/VERSIONS.md:9-15` |
| F41 | overlay 每槽各一份(`/dev/mmcblk0p2 on /overlay`);新槽從 p5 PRESERVE 還原 〔A〕 | 04 `mount` |
| F42 | helper daemon 每次啟動(含 respawn)先跑 boot 階段 〔A〕 | `main.go:5-6,525,614` |
| F43 | provd 開檔上限 1024 〔A〕 | 04 `ulimit -n`(provd 環境) |
| F44 | psk_owner(index 0–3)開出的是**候選**,`auth/owner` 驗 ES256 後才是擁有者;psk_member = 成員;psk_replay = 重取;NX = 匿名 〔B2〕 | `provd/server.go:706-716`;`session.go:78`、`:788-805` |
| F45 | provd 廣播條件 `HealthOK` = bluetoothd、hci0_powered、privacy、sc、sc_file、bondable=0、health 新鮮(60 s)、ready 〔B2〕 | `server.go:480-499` |
| F46 | config-save 的 `UNSAFE` 字元集 `` ` $ ( ) ; | & < > ' `` 的值不寫進 p5,`--save` 回 rc 6;`halow-setkey` 也禁止;P2 `applyNet` 把 rc 6 當成功 〔A2〕〔B2〕 | `batman-config-save:53,461,548,557`;`halow-setkey:30`;`node.go` applyNet |
| F47 | payload 是 gzip tar,含 `boot/`、`boot/overlays/` 兩個目錄成員 | wsl.22 payload `tar -tzv` |
| F48 | `uci -t <dir>` **不隔離**:`/tmp/.uci` 仍在 delta_path,commit 會一起寫進別人暫存的變更 〔A2〕 | libuci `libuci.c:63-64`、`delta.c:99-125,329-337`、`file.c:760-788`(firmware-2710 build_dir) |
| F49 | keyguard(S18,每次開機)看到 placeholder AP key 就 `default_radio0.disabled=1` + `/etc/halow-keyguard.blocked` + commit;**`halow-setkey` 是唯一會解除的門**,拿 `$RUNDIR/halow-setkey.lock`(chanfix 也拿)、讀回、persist;已有 `--ap <psk>` 〔A2〕〔B2〕 | 04 `/etc/init.d/halow-keyguard:8-46`;`halow-setkey:2-31,48,213-227,287-303` |
| F50 | AP 的 SSID 由 `99-halow-identity` 在新卡時設為 hostname;openmanetd 也有設 SSID 的介面(`SettingsWireless`) 〔A2〕〔B2〕 | `99-halow-identity:19-21`;04 `strings openmanetd` |
| F51 | `wifi reload radio0` 的參數被忽略 = `ubus call network reload` 〔A2〕 | 04 `/sbin/wifi` |
| F52 | phy 編號會漂移(04 只剩 phy1 / phy2);AP 的 ifname 要從 `ubus call network.wireless status` 取 〔A2〕〔B2〕 | 04 `ls /sys/class/ieee80211` |
| F53 | `/tmp/run/batman-prov` 是 root:provd 0750 且 ro bind 進 provd 的 jail;helper 自己的 RunDir = `/tmp/run/batman`(root 0700) 〔B2〕 | 04 mountinfo;`provstore.go:339` |
| F54 | p6 已有 `/opt/batdata/state/prov-state`(`<boot_id> helper <state> <verdict> …`,0600) 〔B2〕 | 04;`main.go:471-473` |
| F55 | legacy 認領 = `RadioManaged=false`(保留操作員的 radio);04 現在是 legacy 〔B2〕 | `node.go:539` |
| F56 | `begin_write` 不刪 `BATMAN-VERIFIED`(新檔);payload 不帶 `config.txt`,trial 用的是**目標槽** boot 分割上的 config.txt 〔A2〕〔B2〕 | `build-ab-payload.sh:17-18`;`batman-slot:697`;04 `autoboot.txt` |
| F57 | `platform-ab.sh` 依名字取 tar 成員(`-X`、`-xOf root.squashfs`),與順序無關 〔A2〕〔B2〕 | `platform-ab.sh:207,328,368,370` |
| F58 | Linux weak host model:`LocalAddr` 不代表進來的介面;docker 容器被 fw4 `drop_from_dockert` 擋,br-ots input DROP 〔A2〕〔B2〕 | 04 `nft list ruleset`、`uci show firewall` |

## 2. 總體結構

```
app ──BLE GATT(P2,2 槽,20 交握/分)────────────────┐
app ──HTTP :8095(新,自己的槽與額度;只在開窗時聽)──┴→ batman-provd(uid 471,ujail)── ctl / ops ──→ batman-provhelper(root)
                                                                                              ├ provstore / p5(owner、settings)
                                                                                              ├ 快取:halow-status、p5_saved(背景)
                                                                                              ├ keystore(sign.peer)
                                                                                              ├ release 驗證 + tar 白名單解析(§3.7)
                                                                                              ├ 更新 worker(背景,不拿 n.mu)
                                                                                              └ batman-slot write / arm(拆開)
```

不變的 P2 契約:provd 不碰 root 資源、不讀 health 檔;owner-op 由 helper 驗章;provd 只做角色、額度、分塊、Noise、(新)HTTP。

**HTTP 開關**(§3.8):**備援由 provd 自己決定**(它自己的 `HealthOK()`,F45 — 不繞 helper;被入侵的 provd 本來就能自己聽,§7);**上傳窗由 helper 決定**,經 poll 的 `health.get` 回覆帶 `http` 欄位 `{2: 允許的本機位址, 3: 上傳窗擁有者 key id, 4: 剩餘秒數, 5: pending 的 key 3(大小)}`(沒有上傳窗 → 欄位缺)。provd 重啟時從下一次 poll 拿回。**ctl 連線維持嚴格唯讀**(不帶任何會改 helper 狀態的通知)。**來源只收手機 AP 的 client**由防火牆擋(D19),provd 不再對每個連線問 helper。

**provd ↔ helper 的連線預算**(F12、F26;helper 最多 4 條 socket 連線):ctl = 只給 poll(`health.get`、`info.state`、`info.boot_id`、`info.owners`,每 4 s);**新增一條 `ro` 連線**給 app 觸發的唯讀動詞(`settings.get`、`status.get`、`diag.summary`、`diag.read`、`update.status`),有自己的每連線 5/s 額度 → app 的讀取被限速只會回 `E_RATE` 給 app,**不會讓 poll 拿到 ERate**(否則 120 s 後 `HealthOK` 變 false、BLE 撤廣播,B3-M2);ops = state-changing,一次一個,`HelperWait` 330 s;新動詞的 helper 端時間上限都 ≤ 300 s(§3.3)。

## 3. 設計

### 3.1 provd 路由與錯誤碼

1. `p3Types` 改成空集合(保留機制)。
2. 角色白名單:
   - 擁有者 += `owner/add`、`owner/remove`、`settings/get`、`settings/set`、`status`、`diag/summary`、`diag/bundle`、`update/check`、`update/prepare`、`update/apply`、`update/status`、`bulk/open`、`bulk/close`。
   - 成員 += `status`(摘要)、`diag/summary`、`peers/challenge`。
   - **HTTP 接受 psk_owner(→ 候選 → 必須 `auth/owner` 才是擁有者,F44)與 psk_member**;不接受 NX(匿名)與 psk_replay(重取)— 認領與重取都必須人在旁邊、走 BLE。
3. 轉送表:

| 協定 type | helper 動詞 | 路徑 | owner-op | 回應 |
|---|---|---|---|---|
| `owner/add` | `owner.add`(既有) | ops | 要 | `{1: owner_tag_key}`(秘密,`secretTypes` 已含) |
| `owner/remove` | `owner.remove`(既有) | ops | 要 | `{}` |
| `settings/get` | `settings.get`(新) | 唯讀 | 不要 | CDDL `settings`(不回 passphrase) |
| `settings/set` | `settings.set`(擴充,§3.3) | ops | 要 | 套用後的 `settings` |
| `status` | `status.get`(新,讀快取) | 唯讀 | 不要 | `status-resp`(成員 = 摘要) |
| `diag/summary` | `diag.summary`(新,讀快取) | 唯讀 | 不要 | `diag-summary-resp` |
| `diag/bundle` | `diag.bundle`(改,背景產生)+ `diag.read`(新,唯讀) | ops + 唯讀 | 要(bundle) | 分塊 `{1: bstr}` |
| `peers/challenge` | `sign.peer`(既有) | ops | 不要 | `{1: nonce_node, 2: sig}` |
| `update/check` | `update.check`(新) | ops | 不要(擁有者角色) | `update-check-resp`:被拒 = `{1: false, 2: reason, 3: RAM}`(CDDL 的形狀,不是錯誤回應);只有並發 → `E_BUSY` |
| `update/prepare` | `update.prepare`(新,啟動背景 worker) | ops | 要;body 帶 `sha256(SHA256SUMS)` | `update-progress`(phase 2,立刻回) |
| `update/apply` | `update.apply`(新) | ops | 要;body 帶同一個 sha | `update-progress`(然後重開) |
| `update/status` | `update.status`(新) | 唯讀 | 不要 | `update-progress` |
| `bulk/open` / `bulk/close` | `bulk.open` / `bulk.close`(新,§3.8) | ops | 要 | `bulk-open-resp`(秘密,`secretTypes` 已含)/ `{}` |

4. **唯讀路徑不跑子程序**(`readonly.go:1-8` 的契約):`status.get`、`diag.summary`、`update.status`、`diag.read`、`settings.get` 只讀 helper 記憶體裡的快取或 helper 自己的檔案;快取由 helper 背景更新(§3.4);全部走 `ro` 連線(§2)。
5. **長動作不拿 `n.mu`**(F37):`update.prepare` 只做參數檢查 + 啟動 worker 就回;worker 經 `batman-slot` 自己的鎖(F35)互斥,並在跑的期間讓 `otaBusy()` 為真。`otaBusy()` 擋的動詞擴大到 `settings.set`、`bulk.*`、`update.check`、`update.prepare`(另一個 worker 在跑 → `E_BUSY`)。`diag.bundle` 的產生也在背景。
6. **錯誤碼(F38、F39)**:
   - helper 新增兩個碼:`hERejectR = 24`(帶 `reason` 數字)→ 協定 `E_REJECTED{2: reason}`;`hEInput = 25`(使用者輸入不合法,帶 `reason`)→ `E_REJECTED{2: reason}`,**不記 CRIT**(`hESchema` 維持「provd 送錯格式 = provd bug」)。
   - helper 錯誤回覆加選填欄位 `reason`(uint);P2 的回覆沒有它 → 照舊對應(相容)。
   - 新 reason-code(CDDL 加):11 內容與簽章不符;12 有未完成的網路變更(`.txn`);13 值不合法(名稱 / 國家 / SSID / 密碼);14 已入網:國家要經網路設定改;15 這一步的前提不成立(沒有 pending / 沒有 prepare / handle 過期 / 上傳窗沒開);16 節點手機 AP 關著;17 上傳必須來自這台節點自己的 AP。「需要的開機設定不符」直接用既有的 5(需重燒卡)。
   - 完整「動詞 × 拒絕 → 線上碼」在 §5.1。
7. 每連線額度:`peers/challenge` 0.5/s;`status`、`diag/summary` 每連線 1/s、全域 2/s;`update/check` 每連線 1 / 10 s。

### 3.2 擁有者增刪

helper 行為不變(F3)。本 PR:provd 路由;`owner/remove` 後依 P2 的 `invalidate → reconcile` 切斷被移除者的 session(**包括 HTTP 上的 session**);補 F4 的 Go 邊界測試(`sig_enc` 錯、第 5 位、最後一位、未知 kid、重送輪替、remove 輪替 `adv_owner_key`)。文件:`219-protocol.md:447` 改為輪替 `adv_owner_key`(以 `:203` 與程式碼為準);`254-p1-impl.md:465`「admins +1」刪除。

### 3.3 設定:`settings/get`、`settings/set`

**`settings.get`(唯讀)**:`1` hostname;`2` 國家(`radio1.country`);`10` `{1: radio1.channel, 2: regdb 推的頻寬}`;`20` 手機 AP `{1: ssid}`(不回密碼);`11`–`13` 依 `info.capabilities` 有才回。

**`settings.set`**:一次只帶一項(1、2 或 20);key 10–13 → `E_UNSUPPORTED{1: typ, 2: 7}`(頻道走 `network/update`);未知 uint key 忽略(CDDL `* uint => any`,改 `254-p1-impl.md:466`);文字 key / 一次多項 → reason 13。**legacy 節點**(`RadioManaged=false`,F55:保留操作員的 radio)的 key 2、20 → `E_UNSUPPORTED{1: typ, 2: 7}`(不搶操作員的 radio);key 1 可。

**值的字元集(F46)**:所有會進 p5 的值都不得含 config-save `UNSAFE` 的字元(`` ` $ ( ) ; | & < > ' ``),違反 → reason 13(**不是** `E_STORAGE`)。另:SSID 1–32 個 `[A-Za-z0-9 ._~+=,:@%^*-]`、不以空白開頭結尾;passphrase 12–63 個 `[A-Za-z0-9._~+=,:@%^*-]`、不得是 `CHANGE-ME-NOW`;名稱 `[A-Za-z0-9-]{1,32}`、不以 `-` 開頭結尾;國家 2 個大寫字母且 regdb 有。app 的密碼產生器用同一個字元集(§3.11)。

**寫入一律經現有的門**(F49:`halow-setkey` 是 wireless 的唯一入口,有鎖、解除 keyguard、讀回、persist):

| key | 經由 | 讀回(回應前) | 失敗時 |
|---|---|---|---|
| 20 手機 AP | `halow-setkey --ap - --ap-ssid <ssid> --ap-section default_radio0 --rollback`(**新增 `--ap-ssid`、`--ap-section`、`--rollback`**;`--ap` 已有,passphrase 走 **stdin**(`-`),同 helper 對 mesh key 的慣例 `main.go:154`、`halow-setkey:64-65`,不出現在 cmdline)。`--ap-section` 只寫這一個 section(`--ap` 原本寫每個 `mode=ap` iface,而 PRESERVE 只存 `default_radio0`,B3-m5)。它拿 `halow-setkey.lock`、解除 keyguard 的 `disabled` / MARK、commit、reload、讀回、persist | setkey 的讀回 + 新增:`network.wireless status` 的 radio0 up、iface 的 ssid 相符(ifname 從同一個 status 取,F52) | **`--rollback` 由 setkey 自己在同一次呼叫裡還原「之前的狀態」**:舊 key 是正常值 → 寫回舊 ssid / key 並讀回;**舊 key 是 placeholder(剛認領的節點)→ 回到封鎖**(placeholder + `disabled=1` + MARK,驗證 AP 已不在空中),因為 setkey 拒收 placeholder 當新值(`halow-setkey:83`,B3-M3)。回 reason 13 或 `E_STORAGE`。整次呼叫(含還原)≤ 300 s(helper 的 setkey 上限,`main.go:84-85`)< `HelperWait` 330 s |
| 2 國家(未入網) | `halow-setkey --country <cc> --rollback`(**新增**):鎖內依新國家驗 radio1 的頻道(regdb);設 radio1 + radio0 的 country,commit,reload | **被封鎖 / disabled 的 radio(未入網節點的 radio1 一定是 — mesh key 是 placeholder,keyguard 關著;AP 在配對前也是)只驗 uci 值 + regdb**,不要求 up(B3-M4);up 的 radio(radio0 已配對)要 hostapd 回報 up。**晶片端的真驗證在 join**:setkey `--mesh/--channel` 既有的讀回以 `morse_cli` 的 Operating Frequency 對 regdb centre(`halow-setkey:349-374`)— radio1 第一次以新國家起來時就涵蓋了國家 | `--rollback` 寫回舊國家 |
| 1 名稱 | `uci` + `batman-config-save --save`(system 不是 wireless,沒有 setkey):commit 前若 `/tmp/.uci/system` 非空(別人有暫存,F48)→ `E_BUSY`(fail-closed,不把別人的變更一起 commit) | `uci get` 相符 | 寫回舊值 + `--save`,回 `E_STORAGE` |

- 已入網時改國家 → reason 14(D15)。legacy 節點**未入網時可以改國家**(入網時 `RadioManaged` 會變 true,`node.go:1125`;否則國家不同的 legacy 節點無法從 app 入網,B3-m3a)。
- 改名之後的 `/etc/init.d/system reload` 與副作用:⚠️ **待 U5**(D8)。openmanetd 也寫 hostname / SSID(F32、F50)= 另一個寫者(使用者在 openmanetd UI 操作);最後寫的贏、都由 config-save 存;app 以 `settings.get` 為準。
- **PRESERVE 加 `wireless.default_radio0.ssid`、`wireless.radio0.country`**(config-save 與 `halow-setkey` 的持久化清單,兩板共用)。升級到 P3 後:`--check` 對「p5 的 overrides 裡沒有、live 值等於 `/rom` 預設」的 PRESERVE key 視為 fresh(config-save 的小改,兩板共用)→ 新 PRESERVE 不會讓 `--check` 判 stale 擋 OTA(B2-m7);不需要記「上次版本」的新資源(B3-m6)。降級再升級:舊版的 `--save` 會把 p5 的 ssid 去掉 → 再升級後 SSID 回到 image 預設;app 以 `settings.get` 發現 ssid 不符時提示重新配對(誠實界線)。

**國家與入網(D15)**:`network/join` 的 `net_config` key 5 ≠ `radio1.country` → 整筆拒絕(reason 14),**不寫任何東西**;`network/update` 的 key 5 ≠ **已存的** `net_config` 的 key 5 → 拒絕(只擋「改國家」;P2 時入網、radio 國家與 net_config 不同的成員仍收得到更新,B3-m3b)。P2 wireless txn、`.txn` 格式都不變。開機修復不強制國家(誠實界線)。

### 3.4 狀態(`status`,self)

helper 背景維護兩個快取,**請求路徑上不跑子程序**(計時一律用 uptime,節點沒有 RTC:04 的 `date` = 2025-07-28,B3-m2):
- `halow-status json`:最近 10 分鐘內有人問過時,每 15 s 刷新一次(single-flight);沒人問就不跑。**第一次請求**:觸發刷新、最多等 2 s;等不到 → 只回 key 1、4(有的話),3 / 5 / 15 省略(B3-m13)。
- `p5_saved`:最近 10 分鐘內有人問過時,每 120 s 最多跑一次 `batman-config-save --check`(F28 的鎖每 2 分鐘最多被拿一次 → `--on-join` 不會連續 8 次拿不到)。

| CDDL key | 來源 |
|---|---|
| 1 node-state | `info.state` |
| 2 verdict | `health.level`:OK 0、WARN 1、CRIT 2 |
| 3 鄰居數 | `join.batman_neighbours` |
| 4 p5_saved | 快取;快取超過 300 s 或從未算過 → 省略(不猜) |
| 5 join-failure | 未入網時:`{1: code, 2: 原句}`;code 由 joinwatch **新增的 `verdict_code()`** 給(與 `verdict()` 同一組判斷、同一個檔案;`verdict()` 的句子與它的所有消費者 — diagline、STATE、`status` 頁的字串比對、deploy 鏡像 — 都不動,B2-m6),經 `halow-status json` 的新欄位 `join.reason_code` 帶出 |
| 6 電量 % | 省略 |
| 7 team | `scope = 1` → `E_UNSUPPORTED{1: typ, 2: 7}`(D7) |
| 15 #131 欄位 | 擁有者:`node`、`image`、`uptime_s`、`last_boot_reason`、`last_ota`、`temp_c`、`throttled`、`join{state, channel, country, plinks, snr_db}`、`tenants`;成員只拿 1–5 |

### 3.5 診斷

- **`diag.summary`**:快取的 `health.checks[]` → `diag-item`(`1` id、`2` level、`4` msg)。
- **`diag/bundle`(擁有者)**:`diag.bundle {1: session id(provd 給)}` 在背景產生 tar.gz 到 `/tmp/run/batman/diag/<handle>`(helper 的 RunDir,root 0700,F53 — 不放在 bind 進 provd jail 的 `/tmp/run/batman-prov`;內容 = `/www/cgi-bin/bundle` 現在那份 + `batman-slot verify`;上限 2 MiB,超過從 logread / dmesg 尾端截並記在 `MANIFEST`),立刻回 `{1: handle}`;`diag.read {1: handle, 2: offset}` 回 `{1: total(未完成時 0), 2: ≤ 48 KiB}`(F12)。handle 綁 session id;同一 session 同時一份(新的取代舊的);全節點最多 2 份;10 分鐘(uptime)到期刪(不靠 provd 通知 session 結束,ctl 維持唯讀)。
- **不含秘密**:不讀 `/etc/config/wireless`、`/etc/shadow`、`/etc/batman-prov/identity`、p5、hostapd conf;測試以**內容**比對(包裡不得出現現行 AP 密碼、mesh key、root 雜湊、tag key)。
- **`/cgi-bin/bundle` 關閉**:CGI(uhttpd 以 root 跑)讀 p6 既有的 `/opt/batdata/state/prov-state` 第 3 欄(F54,`unclaimed` / `claimed` / `member` / `legacy`,不新增檔案);只在它是 `unclaimed` 或 `legacy` **且本次開機**(第 1 欄 = 目前 boot_id),**且** `/etc/batman-dev-open` 是 root 擁有、regular、非 symlink、link count 1 時給;檔不在 / 讀不到 / 其他值 → 403(fail-closed)。`deploy/provisioning/www/bundle` 鏡像同步改(`check-provisioning-sync.sh:34`);`halow-status:183` 的文字與 index / status / mesh 頁的連結改成「用 app 取得診斷包」;`status`、`mesh` 頁不變。

### 3.6 `peers/challenge`

成員可呼叫;轉 `sign.peer`(F17);每連線 0.5/s + helper 全域 2/s。`sign.peer` 取 `n.mu`(阻塞,F37):prepare 已不拿 `n.mu`(§3.1.5),所以只會被短的 owner-op 擋住數秒。Go 測試:簽章可驗、`nonce_app` 長度錯 → `hEInput`、額度。

### 3.7 軟體更新(`update/*`)與發行簽章(B18)

#### 3.7.1 鑰匙與簽章物件(D4)

| 鑰匙 | 演算法 | 在哪 | 用途 |
|---|---|---|---|
| 根鑰匙 R(prod) | ES256 | 離線產生;私鑰只在兩支加密 USB(不同地點);公鑰內建 image `/usr/share/batman/release-root.pub` 與 app | 只簽背書 |
| 簽章鑰匙 K<sub>i</sub> | ES256 | 使用者的 YubiKey PIV slot 9c(裝置內產生、不可匯出) | 簽每個發行版本 |
| 測試根鑰匙 T | ES256 | repo `tests/keys/`(公開) | 只有 prov_test image 另外信任;release gate 斷言 release image 不含 T |

ES256:所有 YubiKey 5 的 PIV 都支援;節點已有 `cose.VerifySign1` / `VerifyES256`(F22)。YubiKey 回 DER 簽章,`release-sign.sh` 轉成 64 B `r‖s`(low-s)。⚠️ YubiKey 型號 / host 工具鏈待使用者在場時實測(§9)。

- **背書** E<sub>i</sub> = COSE_Sign1(R),content type `batman/relkey`,標籤 `batman-relkey-v1`,payload `{1: K_i 公鑰 65 B, 2: serial(uint ≥ 1)}`。
- **發行物件** S = COSE_Sign1(K<sub>i</sub>),content type `batman/release`,標籤 `batman-release-v1`。payload 的 key **與 `update-manifest` 同號**:

| key | 欄位 | 用途 |
|---|---|---|
| 1 | version(`BATMAN_VERSION` 全串) | 版本規則 |
| 2 | board | = 本機 board |
| 3 | payload 大小(bytes,**壓縮後**的 `.tar.gz`) | 上傳大小、RAM 預算 |
| 4 | sha256(`SHA256SUMS`) | 綁定內容 |
| 6 | `[* tstr]`:可以從這些**較新**的版本降回本版 | 防降級 |
| 7 | min_from:目前版本必須 ≥ 它(否則 reason 4) | 中間版本 |
| 8 | `[* sha256]`:本版可用的開機設定(`config.txt` ‖ `distroconfig.txt` 的 sha256);空 = 不檢查。比對的是**目標槽** boot 分割上的檔(F56:payload 不帶 config.txt,trial 用目標槽的) | 不符 → reason 5(需重燒卡) |
| 9 | boot 成員總大小(bytes) | 解析上限、RAM 預算 |

- `update-manifest` key 5(`bstr`)= CBOR `[E_i, S]` 的編碼;manifest 的 1–4、6 必須等於 S 的同號欄位,否則 reason 11。改 CDDL `:267-275`(key 6 語意、新增 7–9 為選填,manifest 不必帶 7–9,節點以 S 為準)。
- **撤銷**:image 內建 `/usr/share/batman/release-min-serial`;serial 小於它的背書被拒。K<sub>i</sub> 外流 → R 背書 K<sub>i+1</sub>,發一版 `min-serial = i+1`。**界線**:沒更新到那版的節點仍接受 K<sub>i</sub>(無線上撤銷)。只有 R 出事才要重燒。
- **版本規則**(D12,F40):解析 `<M.m.p>[-<channel>.<N>][+<build-meta>]`,`+` 之後忽略。先比 `M.m.p`;相同時:無後綴(正式)> 任何 `-<channel>.N`;同 channel 比 N;不同的開發 channel(`wsl` vs `ci`)不可比 → 只有在 key 6 列出時才可。**解析失敗**(例如 `.wbox-` 後綴、F40 以外的格式)→ reason 11。key 7(min_from)與目前版本不可比 → reason 4。**撤銷界線**:經 key 6 降到較舊的版本後,舊 image 的 `release-min-serial` 較低,已撤銷的 K 又會被接受。新 > 目前 → 可;= → 可(重裝);< → 只有目前版本列在 S 的 key 6 才可。規則寫進 `docs/VERSIONS.md`。

#### 3.7.2 build / 發行端

- `scripts/build-ab-payload.sh`:tar 順序改為 **`SHA256SUMS metadata boot root.squashfs`**(F27);`metadata` 加 `release=<BATMAN_VERSION>`(`version=` 時間戳不動)。`platform-ab.sh` 的 sysupgrade 路徑以名字取成員(`-X` 排除、`-xOf root.squashfs`),不依賴順序 ⚠️ 實作時逐行確認。
- `scripts/release-sign.sh <payload>`:讀 `SHA256SUMS` / `metadata` / 開機設定清單,組 S,用 YubiKey 簽,與 `release-keys/relkey-<i>.cbor` 寫成 `<payload>.sig.cbor`;`release-endorse.sh`(離線用 R,換鑰匙時)。發行流程加這兩步與轉賣工具清單(§3.9)。

#### 3.7.3 節點端動詞與狀態

| 動詞 | 做什麼 | 拒絕 |
|---|---|---|
| `update.check {1: manifest}` | 0. 被拒時回 `{1: false, 2: reason, 3: RAM}`(CDDL 形狀);1. `batman-slot precheck-node`(試用中、p5 新鮮度、`.txn`、fw override — 與 prepare / arm 同一組檢查,避免傳完才被拒);2. 驗 E(R;prov_test 另加 T)、serial ≥ min、S(K);3. board、版本規則、key 7、key 8 對本機 p1;4. RAM 預算;5. 通過 → 寫 **pending**(`/tmp/run/batman/update/pending`,helper RunDir root 0700(F53),`{S, boot_id, 到期 = now + 30 min}`);內容相同的 pending 已在 → 不重寫 | reason 1、2、3、4、5、6、8、11、12;上傳窗開著或 worker 在跑 → `E_BUSY` |
| `update.prepare {1: sha}` | sha = pending 的 key 4(綁擁有者同意的版本);上傳已完成(§3.8);啟動 worker,立刻回 phase 2 | 無 pending / sha 不符 / 沒上傳完 → reason 15 |
| `update.apply {1: sha}` | worker 已寫完(phase 3)且 sha 相同 → **先寫 update-last**(p6 `/opt/batdata/state/update-last`,root 0600:`{from_slot, to_slot, to_version, sha, apply_boot_id}`)**再** `batman-slot arm <sha>`(重跑完整 `node_checks` + 驗 `BATMAN-VERIFIED`)→ 回應後 2 s 經 `batman-slot` 既有路徑重開(B3-m8:順序反過來會留下「armed 但沒有紀錄」) | reason 15;arm 失敗 → reason 11 / 12 / 1 |
| `update.status` | phase 1 上傳中(%)、2 寫入中(%)、3 寫好待 apply、4 試用中、5 已保留、6 已退回、0 無 | — |

**update-last 的判讀**(每次 helper 啟動只讀、不刪,F42;以**槽**判讀,不以版本字串 — 重裝同版本時 from = to,A2-m4):目前槽 = `to_slot` 且 `is-trial` → 4;= `to_slot` 且已 commit → 5;= `from_slot` 且 boot_id ≠ `apply_boot_id` → 6;= `from_slot` 且 boot_id = `apply_boot_id`(arm 了還沒重開,helper 中途掛了)→ helper 啟動時 **disarm tryboot**(`batman-slot` 既有的 disarm 路徑),報 3(寫好待 apply)— 不讓節點在任務中某次意外重開時才進 trial(B3-m8)。**之後換過槽**(操作員 sysupgrade):目前槽 = `from_slot` 但該槽的版本 ≠ update-last 記的 from 版本 → update-last 視為過期、報 0(B3-m9)。**phase 3 在 helper 重啟後重建**:pending 仍有效(同 boot_id)且目標槽的 `BATMAN-VERIFIED` = pending sha → 3(不必重傳)。下一次 `update.check` 通過時才覆寫。**pending** 在 tmpfs:重開即消失(apply 之前的步驟本來就不撐過重開);到期或 boot_id 不同 → 當作沒有。

**RAM 預算**:`MemAvailable` − 64 MiB ≥ payload 大小 + boot 總大小(key 9);上傳目錄是專屬 tmpfs(§3.8),它的 `size=` 也要 ≥ payload 大小(否則 reason 8)。

#### 3.7.4 worker:驗證、寫入(不 arm)

1. 以 `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` 開上傳檔(provd 的 tmpfs,§3.8;`O_NONBLOCK` 防 FIFO 卡住,A2-m2),fstat:regular、link count 1、uid 471、大小 = key 3,通過後才清掉 `O_NONBLOCK`;之後只用這個 fd。worker 從開檔起把 helper 記憶體裡的 `updating` 旗標設起來(`otaBusy()` 也看它,A2-m11)。
2. **Go `compress/gzip` + `archive/tar` 白名單解析**(不呼叫 busybox tar,root 不在驗證前解析攻擊者的 tar;F47:payload 是 gzip):第 1 個成員必須是 `SHA256SUMS`、第 2 個 `metadata`(都 ≤ 64 KiB、regular);sha256(`SHA256SUMS`)= key 4,否則 reason 11、停。
3. `metadata` 的 `board=` / `release=` = S 的 2 / 1。
4. 之後的成員:目錄成員只允許 `boot/` 與 `boot/overlays/`(F47,忽略其 mode / owner,不在檔案系統上建立);檔案名字必須符合 `^boot/[A-Za-z0-9._-]+$` 或 `^boot/overlays/[A-Za-z0-9._-]+$` 且**列在 `SHA256SUMS`**,或是最後的 `root.squashfs`(其 tar header 大小 = `metadata size=` 且 ≤ 目標槽大小,否則 reason 11);檔案只收 regular file;重複、link、目錄穿越、沒列名 → reason 11、停;boot 成員累計 ≤ key 9。boot 成員以 `O_CREAT|O_EXCL|O_NOFOLLOW` 寫進 helper 新建的 0700 目錄。
5. `root.squashfs`:由 Go 從同一個 fd 串流給 `batman-slot write <dir>` 的 stdin。
6. **`begin_write` 一開始先刪目標槽的 `BATMAN-VERIFIED`**(所有寫者都經過它,含 sysupgrade;否則別的寫者覆寫後,舊的 VERIFIED 會讓 `arm` 去 arm 不同的內容,B2-m10)。**`batman-slot write <dir>`(新動詞,兩板共用)**= 現在 `apply` 的 precheck → begin_write → dd(stdin)→ 複製 boot 檔 → 讀回驗證(`:592-714`),**不 arm**;成功時在目標槽 boot 分割寫 `BATMAN-VERIFIED`(= sha256(`SHA256SUMS`))。**只複製 `SHA256SUMS` 列出的 boot 檔**(F27 的缺口;`apply` / sysupgrade 路徑同樣改,兩板受益)。
7. **`batman-slot arm <sha>`(新動詞)**= `:716-738`,前面先重跑完整 `node_checks`、確認無 `BATMAN-BAD`、cmdline 正確、`BATMAN-VERIFIED` = sha。`apply` = `write` + `arm`。
8. 結束(成功或失敗)由 worker 刪上傳檔與解出目錄;**上傳檔的刪除者只有 helper**(worker、`bulk.close` / 到期、helper 啟動時 — 啟動時若 `batman-slot.lock` 的持有者還活著就不刪解出的目錄)(§4)。
9. **上傳檔被 provd 中途改寫**:helper 用的 `SHA256SUMS` 是步驟 2 驗過的那份;rootfs 與每個 boot 檔的讀回都以它為準 → 不符就 `invalidate_slot`、不 arm(F19)。`metadata size=` 只是串流長度提示(未簽,B-m13):讀回仍以 `SHA256SUMS` 為準,fail-closed。

**誠實界線**:prepare 開始寫之後,另一槽(原本的退路)已被覆寫;放棄更新 = 回不到「兩槽都可用」,只能再更新一次(A/B 寫入的本質)。app 在 prepare 前提示。

#### 3.7.5 autocommit(D6′、D18)

- BLE 無線電(`batman-autocommit:506-511`):health 行的 `boot_id` 必須等於本次開機、`ts`(uptime)距今 ≤ 60 s,否則視同不健康;**仍只 WARN**(P-U5)。
- **新:`health_ok` 加兩項(D18,會讓試用退回)**:(a) helper 的 procd instance 在跑(`ubus call service list` 的 `batman-provhelper` running);(b) **provd 本次開機至少有一次連續穩定 ≥ 60 s**:helper 看到 provd 的 ctl 連線連續存在 60 s 時,寫 `$RUNDIR/provd-stable`(root,內容 = boot_id);autocommit 讀它,boot_id = 本次開機才算。之後 provd 被路人弄當不影響(檔案已寫);路人若在試用的頭幾分鐘一直弄當 provd → 退回舊版 = 更新失敗,不是節點壞掉(之前「不看 provd 當下是否活著」的理由保留)。

### 3.8 HTTP 通道與上傳(沒有暫時 AP)

#### 3.8.1 provd 的 HTTP 伺服器

- **與 BLE 隔離**:HTTP session 池 2 槽(與 BLE 的 2 槽分開);交握額度 10 / 分(只算 HTTP);HTTP 的 fake path 只佔 HTTP 的槽;**撤 BLE 廣播只看 BLE 的 link / session**(`bluez.go:772` 改成只數 BLE)。
- **來源只收手機 AP 的 client(D16、D19),由防火牆在 L2 擋**:image 加 `kmod-nft-bridge`;nft bridge family 表 `batman_http`,`input` 鏈 `tcp dport 8095 iifname != @ap_ports drop`(IPv4 / IPv6 都擋)。`@ap_ports` = 這台節點手機 AP 的 bridge port 名,由 **helper** 依 `ubus call network.wireless status` 的 radio0 interfaces 維護(F52 的漂移;開機與每 5 s 檢查一次;**唯一寫者**);set 是空的 → 全部丟掉(fail-closed)。mesh(`bat0`)、`eth0`、其他節點 AP 的 client 進不來 — 以 port 判斷,偽造 MAC / ARP 都沒用(B3-M1:IP→MAC 的檢查可從 mesh 偽造,因為 client MAC 經 batman TT 廣播,`batctl tl`)。provd 端不再對每個連線問 helper(B3-M2)。⚠️ `kmod-nft-bridge` 在 bcm2711 / bcm2710 build 的可用性與 fw4 的共存(fw4 只管 inet 表)實作時確認;不用 `br_netfilter`(會讓整座橋、含 mesh 流量,都經過 iptables)。
- `net/http`:`ReadHeaderTimeout` 5 s、非上傳 `ReadTimeout` 15 s、`IdleTimeout` 30 s、`MaxHeaderBytes` 4 KiB;同時連線上限 8(F43);`/session`、`/msg` body ≤ 9 KiB(= `max_msg` 8192 + 封裝)。上傳的最低速率 64 KiB/s(30 s 平均),低於就關。
- 端點(協定 §4.2):`POST /batman/v1/session`、`POST /batman/v1/msg`;完整 §3 Noise;接受 psk_owner(→ 候選 → `auth/owner`)與 psk_member,不接受 NX 與 psk_replay(§3.1.2)。多塊回應以多次 `POST /batman/v1/msg`(空 body = 取下一塊)取回。
- **什麼時候聽**(helper 決定,§2;poll 的 `http` 欄位另帶 pending 的 key 3,給 provd 比 `Content-Length`):
  - **備援**(D6′):**provd 自己決定**:自己的 `HealthOK()`(F45)連續 5 分鐘(uptime)為 false → 開;連續 1 分鐘為 true → 不再接受新連線,已建立的 HTTP session 繼續到結束或 10 分鐘(避免切斷正在下載的診斷包)。不經 helper(B3-m4:繞 helper 一圈沒有意義,被入侵的 provd 本來就能自己聽);監聽位址仍來自 poll 的 `http.2`(備援時 helper 照樣給)。之後的 EMCON(checklist)若刻意關 BLE,也必須同時關掉備援 — 寫進 checklist。
  - **上傳窗**:`bulk.open` 後 15 分鐘(uptime),或到 `update.prepare` 開始 / `bulk.close`;窗關了以後**不接受新連線**,已建立的 session 保留到 worker 結束或 10 分鐘閒置。
  - 都不是 → 不 bind。
- 聽在哪:bind `br-ahwlan` 目前的位址:8095(由 helper 給;位址變了 → 下一次 poll 換)。`LocalAddr` 檢查保留,但真正擋住容器的是 fw4(`drop_from_dockert`、br-ots input DROP,F58)。
- 埠 8095:04 未被佔用。

#### 3.8.2 上傳窗(`bulk.open` / `bulk.close`)

- `bulk.open`(owner-op,purpose 0)前提:有 pending;手機 AP 開著(`network.wireless status` 的 radio0 up 且有 AP iface)否則 reason 16(D13,不自動開;**keyguard 關著的 AP 由 §3.3 的配對解除**,不在這裡);沒有其他上傳窗。
- helper 記 `{owner_key_id, 到期}`;回 `{1: 手機 AP 的 ssid, 2: 手機 AP 的 passphrase, 3: 節點在 ahwlan 的 IPv4, 4: 8095, 5: 900}`。**key 2 不再是一次性 PSK**,而是這台 AP 的現行密碼(擁有者本來就有權知道);重送 `bulk/open` = 延長同一個窗、回同樣的值。改 CDDL `bulk-open-resp` key 2 的註解與協定 `:155`、`:212`。
- **上傳**:`PUT /batman/v1/bulk/0`,header `X-Batman-Session` = 一個在 HTTP 上建立、`auth/owner` 後角色擁有者、owner_key_id = 上傳窗擁有者的 session;**來源 IP = 建立該 session 的來源 IP**;`Content-Length` = key 3。`X-Batman-Session` 是明文 bearer:同一台 AP 上知道 AP 密碼的人可以解出來並搶先 PUT(只造成 DoS;內容由簽章 + 讀回把關)→ 誠實界線。
- 寫入 `/tmp/run/batman-provd-bulk/payload`:專屬 tmpfs,`batman-provd` init(root)在啟動 jail 前掛上,`size=` = 本板最大 payload + 8 MiB(⚠️ 依實際 payload 大小定),provd:provd 0700,rw 掛進 jail(provd 唯一的 rw 掛載)。**誠實界線**:這個 tmpfs 在 provd 存活期間一直在,被入侵的 provd 可以隨時佔用到 `size=`(tmpfs 只在寫入時用 RAM);3A+ 上約 136 MiB,列入 checklist(bcm2710 依 P-U14 暫不支援)。
- **上傳完成**:**沒有 `bulk.done`**(B3-M2:少一個介面,也不會因 ops 被佔而遺失)。provd 收完就回 HTTP 200;app 接著 `update/prepare`(BLE 或同一個 HTTP session),`update.prepare` 自己 fstat 上傳檔(大小 = key 3,§3.7.4)。中斷 / 大小不符的檔由 helper 在 prepare 時發現(reason 15)、在 `bulk.close` / 到期 / helper 啟動時刪(唯一刪除者)。helper 在上傳中重啟 → 上傳窗消失、檔案被刪(provd 寫到已 unlink 的 inode,關檔時釋放)→ fail-closed,擁有者重開窗再傳(B3-m7)。

### 3.9 轉賣工具

照 `254-stage1-impl.md` §4.5(`:262-300`)實作 `scripts/transfer-flash.ps1`(Windows,主要)與 `scripts/transfer-flash.sh`(Linux),**不改契約**(內建發行 image 清單、只收讀卡機上的卡、全卡清零、寫入、讀回頭尾、≥ 64 個隨機 1 MiB 區塊在 image 之後全 0、`--test-target-file`)。發行流程加「更新清單」一步(與 §3.7.2 同一步)。**CM4**(D17):開發用 CM4 Lite(SD 卡,本工具適用);量產用 eMMC,不能用「只收讀卡機」的工具重燒(要 rpiboot / usbboot)→ eMMC 的轉賣 / 遺失手機重燒路徑在量產前做,寫進 checklist。

### 3.10 LuCI reset 文字(firmware)與說明頁文字

- firmware patch `flash.js`:`Perform reset` 的說明改為「重新套用設定(不清除擁有者與資料)」;動作不變(`firstboot -r -y` 只清本槽 overlay,開機時 96 從 p5 還原 — `254-stage1-impl.md:63` F22 的唯讀實測;**H4 補一個實機測試**:reset 後擁有者、mesh、AP 帳密都還在)。`rc.button/reset` 已在 P1 改(F23)。
- 賣方 / 買方 / 遺失手機說明頁的文字(stage1-impl `:282-292`)收進 `docs/`,供 app 引用。

### 3.11 App 需求(U9 開工時照做;節點端只負責如實回報)

1. 更新前:手機 Wi-Fi 開著(不能代開 → 帶到系統設定);手機連得到 `bulk/open` 回的 IP(連不上 → 用回傳的 SSID / 密碼請使用者加入);節點手機 AP 關著 → 顯示「節點 Wi-Fi 關閉中,請在可開 Wi-Fi 時(例如維護)再更新」。
2. 上傳只能連**這台**節點的 AP(節點會以 reason 17 拒絕經 mesh 轉來的)。
3. `update/check` 的 `status` 顯示節點跑著 TAK server(`tenants` 含 OTS)→ apply 前警告「重開約 2 分鐘,全隊 TAK 中斷」並再確認一次。
4. prepare 前提示「開始寫入後,放棄就回不到原本的退路」。
5. 配對(D14):認領後,以 `settings/set` key 20 設這台節點的 SSID(中性、不含個人資料)與 ≥ 20 字隨機密碼(字元集 `[A-Za-z0-9._~+=,:@%^*-]`,§3.3),並存在手機;SSID 不隱藏。剛認領的節點 AP 是 keyguard 關著的,配對同時把它打開。
7. 國家(D15):建網時寫進 `net_config`;節點加入前先以 `settings/set` key 2 把國家改成網路的國家,否則入網被拒(reason 14)。
6. 完全靜默(EMCON)時連 BLE 也不連 — app 模式,不在 P3。
8. HTTP(上傳 / 備援)的 socket **綁在 Wi-Fi 網路上**(Android `bindProcessToNetwork` / iOS 對應機制);AP 沒有對外網路時,手機系統會把連線改走行動網路,連不到 10.41.x(B3-m12)。
9. 遺失手機(D20):`owner/remove` 後提示以 key 20 換這台的 AP 密碼;認領後建議加一位備用擁有者。

## 4. 擁有權

| 資源 | 寫者(唯一) | 唯讀 / 其他 |
|---|---|---|
| p5 prov 紀錄 | helper `commit`(P1/P2) | provd 經 helper |
| `system.hostname` | helper `settings.set`(`/tmp/.uci/system` 非空 → `E_BUSY`,F48);**另有寫者**:openmanetd(F32)、操作員 ssh、`99-halow-identity`(新卡)— 不同時發生的設定動作,最後寫的贏,都由 config-save 存 | config-save、halow-status |
| `wireless.radio1/radio0.country` | **`halow-setkey --country`**(helper 的 `settings.set` 未入網時經由它);操作員 ssh。入網**不寫**國家(D15) | config-save、`netJoin`(只比對) |
| `wireless.default_radio0.ssid` / `.key` | **`halow-setkey --ap / --ap-ssid`**(helper 的 key 20 經由它,拿 `halow-setkey.lock`);`99-halow-identity`(新卡寫 ssid = hostname,F50);helper `--apply-state --firstboot` / 99zz(unclaimed 時寫 placeholder key);openmanetd `SettingsWireless`(F50);操作員 ssh | config-save、hostapd |
| `wireless.default_radio0.disabled` + `/etc/halow-keyguard.blocked` | keyguard(開機,placeholder key 時設 1 並 commit,F49);`halow-setkey`(解除) | netifd |
| `.txn` | helper(P1b txn,**格式不變**,D15) | config-save(看存在) |
| HTTP 上傳窗與允許位址 | **helper**(經 poll 告訴 provd) | provd 照做 |
| HTTP 備援開關 | **provd**(自己的 `HealthOK`) | — |
| nft bridge 表 `batman_http` 與 `@ap_ports` | 表:image(開機載入);set:**helper** | kernel |
| `$RUNDIR/provd-stable` | helper | autocommit |
| `ro` 連線(provd → helper) | provd 開 | helper 限速 |
| `/tmp/run/batman-provd-bulk`(專屬 tmpfs) | `batman-provd` init 掛載 / 建目錄;provd 寫上傳檔 | helper worker 只讀 fd |
| `/tmp/run/batman/update/`(pending、解出的 boot 檔)、`/tmp/run/batman/diag/`(helper RunDir,root 0700,F53) | helper | — |
| AP client 快取(記憶體) | helper | provd(唯讀動詞) |
| p6 `state/update-last` | helper(apply 時寫;下一次 check 通過時覆寫) | helper(status) |
| p6 `state/prov-state`(既有,F54) | helper(既有) | `/cgi-bin/bundle`(新讀者) |
| 目標槽(rootfs、boot、`BATMAN-VERIFIED`、`BATMAN-BAD`)與 tryboot 旗標 | `batman-slot`(`write` / `arm` / `apply`),由 `batman-slot.lock` 互斥(F35):helper worker 與 sysupgrade 不會同時寫 | autocommit |
| `release-root.pub`、`release-min-serial` | build(image 內) | helper |

**清理表**(誰刪什麼):

| 東西 | 成功 | 失敗 | helper 重啟 | provd 重啟 | 開機 |
|---|---|---|---|---|---|
| 上傳檔(`batman-provd-bulk/payload`) | worker 用完刪 | helper 刪(prepare 發現不符 / 到期 / `bulk.close`) | 啟動時刪(`batman-slot.lock` 持有者活著就不刪解出目錄) | 不刪(helper 是唯一刪除者) | tmpfs 消失 |
| 解出的 boot 檔 | worker 刪 | worker 刪 | 啟動時刪 | — | tmpfs 消失 |
| pending | 覆寫或到期 | 到期 | 讀回(boot_id 相同才有效) | — | 消失 |
| diag bundle | 10 分鐘 / session 結束 | 同 | 啟動時刪 | session 全斷 → helper 刪 | 消失 |
| update-last | 下一次 check 通過時覆寫 | 同 | 保留 | — | 保留(p6) |

## 5. 契約

### 5.1 動詞 × 拒絕 → 線上碼

| 動詞 | 情況 | 線上 |
|---|---|---|
| 所有 owner-op | owner-op 缺 / 錯 | `E_FORBIDDEN` |
| 所有 state-changing | 試用中、verdict 不明、`.txn` 未完成且在 finish(P1b 既有) | `E_BUSY` / P1b 既有對應 |
| `settings.set` | 值不合法 / 一次多項 / 文字 key | `E_REJECTED{2: 13}` |
| `settings.set` 國家 | 已入網 | `E_REJECTED{2: 14}` |
| `settings.set` key 2 / 20 | legacy 節點 | `E_UNSUPPORTED{1: typ, 2: 7}` |
| `settings.set` key 1 | `/tmp/.uci/system` 有別人的暫存 | `E_BUSY` |
| `network/join` / `network/update` | `net_config` 國家 ≠ 節點國家 | `E_REJECTED{2: 14}` |
| `settings.set` key 10–13 | — | `E_UNSUPPORTED{1: typ, 2: 7}` |
| `settings.set` | `--save` 失敗(已還原) | `E_STORAGE` |
| `status` scope 1 | — | `E_UNSUPPORTED{1: typ, 2: 7}` |
| `update.check` | 試用中 / p5 未 seed / 板子 / 中間版本 / 開機設定 / 降級 / RAM / 簽章或版本解析 / `.txn` | **ok 回應** `{1: false, 2: 1 / 2 / 3 / 4 / 5 / 6 / 8 / 11 / 12, 3: RAM}`(CDDL `update-check-resp`) |
| `update.check` | 上傳窗或 worker 進行中 | `E_BUSY` |
| `update.prepare` / `apply` | 前提不成立 / sha 不符 | `E_REJECTED{2: 15}` |
| `update.prepare` worker | 內容不符(之後經 `update.status` 的 key 3) | phase 0 + `3: 11` |
| `bulk.open` | 無 pending | `E_REJECTED{2: 15}`;AP 關 → `{2: 16}` |
| HTTP 上傳 | 不是本 AP client | HTTP 403 + body `reason 17` |
| `diag.read` | handle 過期 / 不屬於這個 session | `E_REJECTED{2: 15}` |
| HTTP 交握 | NX / psk_replay | 連線關閉(與 fake path 等長回應後關) |
| HTTP accept | 來源不是本 AP client | 立刻關閉(不讀 header) |

### 5.2 重送語意(不做冪等快取)

| 動詞 | 回應遺失後重送 | app 的處理 |
|---|---|---|
| `owner/add` | 再送 = 輪替該擁有者 tag key(新值) | 以最後一次的 tag key 為準 |
| `owner/remove` | 第二次 `E_FORBIDDEN`(no such owner) | 當成功 |
| `settings/set` | 與現值相同 → 直接回 | 冪等 |
| `update/check` | 內容相同的 pending 不重寫 | 冪等 |
| `update/prepare` | worker 已在跑 → `E_BUSY`;已寫完 → `E_REJECTED{15}`… | 先讀 `update/status` |
| `update/apply` | 節點可能已重開 | 讀 `update/status`(update-last) |
| `bulk/open` | 已開著 → 延長同一個窗、回同樣的值(不換 PSK) | 用回應 |
| `diag/bundle` | 同 session 的新 bundle 取代舊的 | — |

### 5.3 介面

| 介面 | 寫 → 讀 | 格式 / 有效 | 缺 / 舊 / 壞 | 誰寫得到 |
|---|---|---|---|---|
| `update-manifest` + `[E, S]` | app → provd → helper | §3.7.1 | 驗不過 → reason 11,fail-closed | 任何擁有者 session;簽章才是權威 |
| pending | helper → helper | CBOR,root 0600,綁 boot_id、30 分鐘 | 缺 / 過期 / 壞 → 當作沒有 | root |
| update-last(p6) | helper → helper | CBOR `{from, to, sha, apply_boot_id}` | 缺 → status 0;壞 → 當缺 | root |
| 上傳檔 | provd → helper | 大小 = key 3 | §3.7.4 步驟 1–4 | provd(不受信任) |
| `BATMAN-VERIFIED` | `batman-slot write` → `arm` | 一行 sha256 hex | 缺 / 不符 → arm 拒絕 | root |
| poll 的 `http` 欄位 | helper → provd | §2 + pending key 3 | 缺 → 不聽(fail-closed) | helper |
| nft `@ap_ports` | helper → kernel | bridge port 名 | 空 → 8095 全丟(fail-closed) | root |
| `$RUNDIR/provd-stable` | helper → autocommit | 一行 boot_id | 缺 / 不是本次開機 → 試用不健康 | root |
| HTTP `/batman/v1/*` | app → provd | 協定 §4.2 + §3.8 | 交握失敗 → 關;超額 → 關 | br-ahwlan 上任何人(整個 mesh) |
| joinwatch `verdict_code()` → `halow-status json` 的 `join.reason_code` | joinwatch → halow-status → helper | uint | 缺 → code 0 | image |
| p6 `prov-state`(既有) | helper → CGI | `<boot_id> helper <state> …` | 缺 / boot_id 不符 / 其他值 → 403 | root |
| helper 錯誤回覆 `reason` | helper → provd | 選填 uint | 缺 → 照 P2 對應 | helper |

## 6. 生命週期矩陣

| 路徑 | 今天 | 改後 | 測試(H4) |
|---|---|---|---|
| 首次安裝 / 第一次開機 | P3 動詞 `E_UNSUPPORTED` | 可用;HTTP 不聽(BLE 健康) | `prov-p3-routes-254` |
| 啟動 | — | provd 依 poll 決定 HTTP | `prov-http-254` |
| 正常停止 | — | provd 停 → HTTP 關、上傳檔由 helper 刪 | `prov-http-254` stop 臂 |
| 重開 | — | pending 消失;update-last 撐過並報 4 / 5 / 6 | `prov-update-254` |
| 升級 / 回滾 | ssh sysupgrade | + app 路徑(簽章、白名單 tar);sysupgrade 不變(tar 順序新舊都可) | `prov-update-254` 正向 + 負對照 |
| 降級到沒有 P3 的版本 | — | 舊槽沒有 P3 動詞;`.txn` 格式不變(D15);p5 `overrides.uci` 多出的 ssid、radio0.country 舊版 96 照樣套用(無害);update-last 留在 p6 無人讀(無害) | `prov-update-254` 回滾臂 |
| provd crash / crash loop | — | HTTP 斷;上傳檔下次 provd 啟動刪;helper 關上傳窗 | `prov-http-254` kill 臂 |
| helper crash | — | worker 中斷 → 槽保持 BAD(begin_write),不 arm;重啟時刪暫存;pending 若 boot_id 同仍有效 | `prov-update-254` kill 臂 |
| 斷電 | — | prepare 中:槽 BAD、仍跑舊槽;apply 後:tryboot 一次性 | `prov-update-254` 斷電臂 |
| 換 IP(改名 / openmanetd) | — | 允許清單更新,HTTP 連線斷開重連 | ⚠️ 待 U5 |
| 升級到 P3 第一次開機 | — | PRESERVE 多兩項 → helper `--boot` 看到版本變了執行一次 `--save`,`--check` 不判 stale | `prov-update-254` 升級臂 |
| helper 在上傳中重啟 | — | 上傳窗消失、檔被刪 → fail-closed,重開窗重傳 | `prov-upload-254` |
| arm 後、重開前 helper 掛掉 | — | 啟動時 disarm tryboot,報 3 | `prov-update-254` |
| 降級再升級 | — | 舊版 `--save` 去掉 p5 的 ssid → 再升級後 SSID 回 image 預設;app 由 `settings.get` 發現並提示重新配對 | 誠實界線 |
| 依賴重啟:bluetoothd / dbus | P2 | 不變;BLE 不健康 5 分鐘 → HTTP 備援開 | `prov-http-254` 備援臂(停 bluetoothd) |
| 依賴重啟:hostapd / `wifi reload`(= `network reload`,F51) | — | client 快取 5 s 內更新;ifname 每次從 `network.wireless status` 取 | `prov-http-254` |
| 平台 bcm2711(Pi 4) | — | 實測 | 全部 |
| 平台 bcm2710(Pi 3) | — | `batman-slot`、config-save 兩板共用 → CI 沙箱(P-U14) | CI |
| 平台 CM4 | — | 開發 Lite / 量產 eMMC(D17);**必須是有無線的型號**(BLE + radio0 AP;沒有無線的 CM4 兩條通道都沒有 → 不支援);eMMC 重燒路徑與實測待 CM4 載板(checklist) | — |

## 7. 安全

**資產**:節點控制權(更新 = 任意程式碼)、擁有者 / 成員秘密、AP 帳密、診斷內容、可用性(BLE 管理通道、手機 AP、mesh 頻寬)。

| 行為者 | 攻擊 | 擋法 | 負測試 |
|---|---|---|---|
| mesh 上任何人(F9) | 灌 HTTP 讓 BLE 失效(v1 B1)、讓擁有者的上傳 / 備援建不起來(v2 M5 / M3)、把 poll 擠到 ERate(v3 M2) | HTTP 平常不聽;聽的時候 **nft bridge 規則只收手機 AP port**(偽造 MAC / ARP 無效);HTTP 與 BLE 的槽 / 額度分開;撤廣播只看 BLE;app 讀取走 `ro` 連線,不碰 poll | 另一台節點 eth0 上的主機以手機 MAC + 手機 IP(含 ARP 毒化變體)、50 conn/s、10 分鐘:封包被丟、poll 沒有 ERate、BLE 廣播在、AP 上的擁有者完成 HTTP 上傳;負對照 = v3 的 IP→MAC 版本放行 |
| mesh 上任何人 | 認領 / 重取 | HTTP 不收 NX / psk_replay | `prov-http-254` |
| mesh 上的成員 / 遺失的手機 | 輪詢 `status` 卡住 p5 存檔(v1 M1) | 請求路徑不跑子程序;`--check` 每 120 s 最多一次;額度 | 10 / s × 10 分鐘:`cfgsave-lock.busy` 不出現、`--on-join` 照常 |
| 遺失 / 被偷的手機 | HTTP 上用 PSK;用記住的 AP 密碼連 AP → mesh LAN | 只在備援 / 上傳窗開著時;`owner/remove` 後 session 立刻斷、psk 失效;**app 提示以 key 20 換 AP 密碼**(D20) | `prov-owner-254` 含 HTTP session;換密碼後舊密碼連不上 |
| 鄰近節點 AP 上的人 | 經 mesh 上傳(佔頻寬)或亂傳 | 上傳只收本 AP client + 綁上傳窗擁有者 | `prov-upload-254` 經 mesh → 403 |
| 被入侵的 provd | 改 payload、塞沒列名的 boot 檔、tar 穿越 | Go 白名單解析、先驗簽、只寫列名的檔、讀回以 helper 的 `SHA256SUMS` 為準 | 四包惡意 tar(`../`、symlink、未列名 dtbo、未列名 dtb)全拒、boot 分割不變 |
| 被入侵的 provd | 吃光 RAM | 專屬 tmpfs `size=` 上限 | provd 身分寫超過上限 → ENOSPC,其他服務正常 |
| 被入侵的 provd | 偷換 pending 版本 | prepare / apply body 帶 sha,由 owner-op 綁擁有者同意的版本 | Go |
| 被入侵的 provd | 自己開 HTTP / 亂聽 | HTTP 開關由 helper 決定;provd 被入侵本來就能聽 > 1024 的埠(無 netns),但沒有 PSK 解不開 session、拿不到 owner-op | 誠實界線 |
| 本機非 root | 讀 AP 密碼 | `/etc/config/wireless`、hostapd conf 是 0644(F34,今天就如此) | 誠實界線(與現況相同,非新增) |
| 實體奪取(撿到 / 偷走 SD 卡) | 從 p5 讀 AP 密碼 → 連 AP → br-ahwlan 整個 mesh LAN | p5 不加密(既有);AP key 早已在 PRESERVE,P3 加 SSID — **D14 是使用者決定的例外**(「秘密不進 p5」的規則下明列);換卡後擁有者 `settings/set` 換密碼 | 誠實界線 |
| 同 AP 上知道 AP 密碼的人 | 解出明文 `X-Batman-Session`、搶先 PUT | 只造成 DoS;內容由簽章 + 讀回把關;PUT 綁建立 session 的來源 IP | 誠實界線 |
| 本機非 root | 搶建 `/tmp/run/batman-provd-bulk` | `/tmp/run` 只有 root 能建(F33);init 建前檢查 owner / 非 symlink | tmp-trust allowlist + 測試 |
| 供應鏈 / 我們自己的錯 | 簽了壞 image;K 外流 | min-serial;防降級;R 離線兩份;**出貨鑰匙鏈 bench 測試**(YubiKey K 簽 rc,在 release 設定的節點上走 app 路徑;T 簽的被拒) | `prov-update-254` bench 臂 |
| 有管理密碼的人 | ssh sysupgrade / LuCI 刷韌體 / openmanetd local upgrade 與 `PerformFactoryReset`(未簽章) | 不擋(root 等同完全控制) | 誠實界線 |

**秘密**:AP passphrase 與 bulk 回應只經 Noise;它們本來就在 `/etc/config/wireless`(0644)與 hostapd conf(0644)— 與今天相同,不新增暴露。K 在 YubiKey、R 離線。**失敗模式**:fail-closed(驗不過不寫、不 arm;HTTP 預設不聽;CGI 預設 403)。

## 8. 測試(H4 依此寫;每項有負對照)

- `prov-p3-routes-254`:每個動詞 × 角色(匿名 / 候選 / 成員 / 擁有者)× owner-op 缺 / 錯,斷言 §5.1 的線上碼;負對照 = wsl.22 全部 `E_UNSUPPORTED`。
- `prov-owner-254`:add / 重送輪替 / remove(BLE 與 HTTP session 都被切)/ 最後一位。
- `prov-settings-254`:get;國家(入網 → 14;未入網、radio 被封鎖時改 → 成功、uci 已改、p5 已存(負對照 = v3 要求 radio up 的版本被還原);頻道不合法 → 13;之後同國 join → morse 頻率 = 該國 regdb);**AP 配對**:新卡 → 認領 → key 20 → **不重開**,30 s 內 AP 起來、新帳密可連、`bulk.open` ≠ 16、p5 有新值、morse plink 不斷(負對照 = 只寫 uci 的版本 FAIL);**新卡配對注入失敗 → AP 不在空中、`disabled=1`、MARK 有該 iface、p5 不變**(負對照 = v3 版本 AP 開著);passphrase 不出現在 `/proc/*/cmdline`;密碼含 `$` → 13、live 與 p5 不變(負對照 = 回 `E_STORAGE`);`/tmp/.uci/system` 有暫存 → 改名 `E_BUSY`、`/etc/config/system` 不變;hostapd 起不來(wbox 注入非法值)→ 舊值回來、p5 不變;legacy 節點 key 2 / 20 → 7;改名(⚠️ U5 後補斷言)。
- `prov-country-join-254`:join / update 的 `net_config` 國家 ≠ 節點國家 → 14,什麼都沒寫(`.txn` 不存在、uci 不變);先 `settings/set` 改國家再 join → 成功。
- `prov-status-diag-254`:status 與 halow-status 一致、成員只拿摘要;輪詢 10 / s × 10 分鐘不產生 `cfgsave-lock.busy`;bundle > 64 KiB 完整取回、tar 可解、**內容**不含秘密;handle 跨 session 被拒。
- `prov-bundle-gate-254`:claimed → 403;unclaimed + dev-open → 200;`status` 仍 200。
- `prov-http-254`:平常不聽;停 bluetoothd 5 分鐘 → 聽;**讓 `sc_file` 失效(或 `bondable=1`)5 分鐘 → 聽**(負對照 = 只看兩個欄位的版本不聽);恢復 → 不收新連線、既有 session 保留;psk_owner → 候選 → `auth/owner` 成功(負對照 = 不收候選的版本失敗);NX / psk_replay 被拒;mesh / eth 來源被 accept 時關閉;DoS 負測試(§7 第一列)。
- `prov-upload-254`:AP 關 → 16;經 mesh → 17;非窗擁有者的 session → 403;大小不符 → 刪;provd 寫超過 tmpfs → ENOSPC。
- `prov-autocommit-p3-254`:試用 image 的 provd 壞掉 → revert;helper 不在 → revert;provd 穩定 60 s 後被殺 → 仍 commit(負對照 = 現行 autocommit commit 壞 provd 的版本)。
- `prov-update-254`:T 簽的 image 經 app 路徑 → trial → commit → status 5;重裝同版本 → 退回時 status 6(不是 5);負對照:錯簽章、serial < min、錯板子、降級、min_from、目標槽開機設定不符(5)、版本解析失敗、四包惡意 tar、上傳檔換成 FIFO(worker 不卡)、上傳後改 payload、prepare 中 kill helper / 斷電、helper 重啟後 phase 3 重建;回滾 → status 6;**sysupgrade 臂**:未列名的 dtb 不被寫進槽(負對照 = 現行 `batman-slot`);**bench 臂**:YubiKey K 簽、release 設定節點。
- `prov-transfer-tool-254`(WSL loop 檔)+ 真卡(使用者讀卡機)。
- `prov-luci-reset-254`:firstboot 後擁有者 / mesh / AP 帳密仍在。
- `prov-eeprom-hooks-254` 補項(D11)。
- Go:§3.2 邊界、§3.6、§3.7 每個拒絕分支(mutant)、tar 白名單、版本規則表、§3.8 額度隔離、錯誤碼表。

## 9. 未決 / ⚠️

1. **U5 改名**(D8):使用者回現場時跑;結果補 §3.3 key 1 的副作用、§6「換 IP」列、`prov-settings-254` 的改名斷言。**H4 的改名單位等 U5**;其他單位不受影響。
2. **YubiKey** 型號 / 韌體與 host 簽章工具鏈(DER → r‖s):使用者在場時實測;不影響節點端設計(只依賴 ES256)。
3. (關閉)`platform-ab.sh` 依名字取成員,與順序無關(F57)。
4. bulk tmpfs 的 `size=`(§3.8.2)依實際 payload 大小定;bcm2710 值 ⚠️。
5. AP 配對的 reload = `network reload`(F51)對 morse plink 的影響 — H4 量測;國家只在未入網時改。
6. 改國家後 morse 是否真的換 regdomain / 頻道表 — **實作前先在 04 實測**(A2-M4),結果寫進 F 表。
7. `halow-setkey` 新增 `--ap-ssid`、`--ap-section`、`--country`、`--rollback`:讀回與還原條件如 §3.3;實作時讀 `halow-setkey:213-374` 逐行比對。
8. `kmod-nft-bridge` 在兩板 build 的可用性、與 fw4 的共存(§3.8.1)。

## 10. 要改的文件(本 PR)

- `219-protocol.md`:`:218` 拿掉「階段 1 不實作」;§4.2:PSK-only、什麼時候聽、`/msg` 的多塊取回、上傳端點、刻意不做冪等快取的理由;`:447` 改為輪替 `adv_owner_key`;`:210` 與 field-provisioning `:474` 對齊 D10;§5.2 `E_REJECTED` 改為「被拒(附原因)」不限更新。
- `219-protocol.cddl`:reason-code 11–17;`update-manifest` key 5 註解(= CBOR `[E, S]`)、key 6 語意、S 的 7–9;settings key 20;`bulk-open-resp` key 2 不再是一次性;`update-phase` 2 的名稱(寫入 / 驗證中);`update-check-resp` 不變。
- `219-field-provisioning.md` §6.9:暫時 AP 改為「經這台節點的手機 AP」(D5′、D13)。
- `254-stage1-impl.md`:§10.6 / §10.7(D3);`:171`(bundle 用 handle 分頁);`:357` `E_STATE` → `E_BUSY`。
- `254-p1-impl.md`:`:465`、`:466`。
- `halow-setkey` 的說明(`--ap-ssid`、`--country`)與 deploy 鏡像;`joinwatch` / `halow-status` 的 deploy 鏡像(`verdict_code()`、`join.reason_code`)。
- `docs/VERSIONS.md`:版本比較規則(§3.7.1)。
- 新 `docs/`:說明頁文字(§3.10)。

## 11. 寫進 #254 checklist(不在本 PR)

`status` team(`dac_pub_hash`、最後看到時間);EMCON(手機 AP 平常關 / 功率;**刻意關 BLE 時也要關 HTTP 備援**);autocommit BLE 擋 commit(#305 後);**CM4 eMMC 的轉賣 / 遺失手機重燒路徑(量產前,D17)**;未簽章更新路徑(ssh / LuCI / openmanetd local upgrade、`PerformFactoryReset`)要不要收;app 端的靜默模式;**整個網路一起改國家(D15)**;3A+ 上 bulk tmpfs 的常駐佔用;**P3 之前建的 payload 不能經 app 安裝**(Go 解析要求 `SHA256SUMS` 是第一個成員;經 key 6 降到 P3 之前的版本也不行 → 只能 ssh sysupgrade,B3-m10)。

## 12. v1 審查回應(A = `review-v1-A.md`、B = `review-v1-B.md`)

| 項 | 處理 |
|---|---|
| A-B1 / B-B1 HTTP 與 BLE 共用槽與額度 | 使用者決定 HTTP 只在 BLE 不健康 / 上傳窗時聽(D6′);聽的時候自己的槽與額度 + 每 IP 額度 + `net/http` timeout + 連線上限;撤廣播只看 BLE(§3.8.1);負測試 §7 |
| A-B2 / B-M2 root 在驗簽前解 tar、未列名 boot 檔 | Go 白名單解析、`SHA256SUMS` 改成第一個成員且先驗、只複製列名的 boot 檔(`batman-slot` 兩板共用,sysupgrade 也受益)(§3.7.4);四包惡意 tar 負測試 |
| A-M1 / B-M7 `status` 跑 `--check` 卡 p5 存檔 | 請求路徑不跑子程序;背景快取,`--check` ≤ 1 / 120 s(§3.4);額度;負測試 |
| A-M2 / B-M6 國家沒在 P2 | v2 寫成 txn 的一部分;**v3 由 D15 取代**(國家不同就拒絕入網,txn 不動,見 §13) |
| A-M3 契約 ⚠️ | 鎖名(F35)、dev-open(F36)、降級殘留(F41,bulk AP 已拿掉)、join-reasons(`verdict()` 自己輸出碼)都定了;U5 依 D8 只留改名一項 |
| A-M4 / B-M5 bulk 回滾與多寫者 | **暫時 AP 拿掉**(D5′),不再動 wireless / network / dhcp / firewall;settings 寫入用私有 uci savedir + 失敗還原(§3.3);openmanetd 列入擁有權(§4) |
| A-M5 暫時 AP 是否需要 | 使用者:不需要(D5′),改經這台節點的手機 AP |
| A-M6 reason 4 / 5 的資料 | S 加 key 7(min_from)、key 8(開機設定)(§3.7.1) |
| A-M7 / B-m6 狀態機 | pending(tmpfs,綁 boot_id、30 分鐘)與 update-last(p6,不在開機刪)分開;並發 → `E_BUSY`;清理表(§4) |
| B-M1 錯誤碼 | helper 新碼 24 / 25 + `reason`;只用協定既有線上碼 + reason 11–17;§5.1 全表 |
| B-M3 RAM / payload 生命週期 | 專屬 tmpfs `size=`、清理表、預算含 boot 總大小(key 9)與 `MemAvailable` |
| B-M4 監聽位址 | bind `:8095` + `LocalAddr` 允許清單由 helper 給,位址變了重給(§3.8.1) |
| B-M8 `n.mu` 與長動作 | prepare / bundle 在背景 worker,不拿 `n.mu`;`otaBusy` 擴大(§3.1.5) |
| B-M9 U5 | D8:改名待探針,其他送審 |
| B-M10 channel 規則、出貨鑰匙鏈沒驗 | D12 版本規則;bench 臂用 YubiKey K 在 release 設定節點驗(§7、§8) |
| A-m1 擁有者同意綁版本 | prepare / apply body 帶 sha |
| A-m2 / B-m15 key 不一致 | S 的 key 與 manifest 同號(§3.7.1) |
| A-m3 / B-m2 bulk 密碼的說法 | bulk 密碼不存在了;AP 密碼的現況寫進 §7 |
| A-m4 版本文法 | §3.7.1 |
| A-m5 RAM 預算 | `MemAvailable`(§3.7.3) |
| A-m6 prepare 同步 | 改非同步(§3.1.5) |
| A-m7 HTTP 細節 | 多塊取回、fake path、冪等偏離理由、psk_replay 只走 BLE(§3.8.1、§5.2) |
| A-m8 診斷包秘密測試 | 改看內容(§3.5) |
| A-m9 / B-m16 CM4 | §6 平台列、§3.9、§11 |
| A-m10 / B-m12 prepare 後放棄 | 誠實界線 + app 提示(§3.7.4、§3.11) |
| A-m11 check 先跑 precheck-node | §3.7.3 |
| A-m12 上傳檔順序 | `O_NOFOLLOW` fd + fstat;不 rename(B-M3 的 EXDEV) |
| B-m1 bulk SSID 洩漏 | 沒有 bulk SSID 了 |
| B-m3 `/tmp/run` 權限 | F33 改寫;init 檢查 owner / 非 symlink |
| B-m4 bulk 防火牆 | 不再有 bulk zone;HTTP 以 `LocalAddr` 允許清單限定 |
| B-m5 重送語意 | §5.2 |
| B-m7 diag handle | 綁 session、每 session 一份、全節點 2 份(§3.5) |
| B-m8 psk_replay 走 HTTP | 不行(§3.1.2) |
| B-m9 §10 漏檔、CGI 讀 state | 鏡像 + sync 檢查 + `halow-status:183` + `prov-state` 檔(§3.5) |
| B-m10 未簽章更新路徑 | §1.2、§7 誠實界線、§11 |
| B-m11 LuCI 證據 | 引 stage1-impl `:63`(F22 實測),H4 加 `prov-luci-reset-254` |
| B-m13 `write` 的準確範圍、未簽的 size | §3.7.4 步驟 6、9 |
| B-m14 check 每次寫 p6 | pending 改在 tmpfs、內容相同不重寫、每連線 1 / 10 s |
| B-m16 遺失的手機 | §7 新列 |

## 13. v2 審查回應(A2 = `p3-review-v2-A.md`、B2 = `p3-review-v2-B.md`)

| 項 | 處理 |
|---|---|
| A2-M1 / B2-M4 key 20 繞過 halow-setkey / keyguard | 改走 `halow-setkey --ap --ap-ssid`(新增 `--ap-ssid`):同一把鎖、解除 keyguard、讀回、persist(§3.3);擁有權表改正 keyguard / 99-halow-identity / openmanetd(§4);負測試「新卡 → 認領 → 配對 → 不重開 AP 起來」 |
| A2-M2 / B2-M4-2 字元集與 `UNSAFE` | 字元集 = `UNSAFE` 的補集,違反 → reason 13;app 用同一個字元集(§3.3、§3.11) |
| A2-M3 `uci -t` 不隔離 | 刪掉宣稱(F48);wireless 走 setkey;hostname 遇到 `/tmp/.uci/system` 非空 → `E_BUSY` |
| A2-M4 / B2-M6 國家併進 txn 不完整 | **使用者決定 D15**:國家不同就拒絕入網,txn 不動;單台改國家經 `halow-setkey --country`(§3.3) |
| A2-M5 / B2-M3 mesh 擋掉上傳窗 / 備援 | **使用者決定 D16**:accept 時只收本 AP client(§3.8.1);負測試 §7 |
| B2-M1 HTTP 角色 | 收 psk_owner(候選 → `auth/owner`)與 psk_member;不收 NX、psk_replay(§3.1.2) |
| B2-M2 備援觸發 | 以 provd 的 `HealthOK()` 為唯一定義,經 poll 回報(§3.8.1);`sc_file` 負測試 |
| B2-M5 reload 後不讀回 | setkey 的讀回 + `network.wireless status`;起不來就以舊值再走同一個門(§3.3) |
| A2-m1 / B2-m3 gzip、目錄成員 | `compress/gzip`;只允許 `boot/`、`boot/overlays/` 目錄成員;`root.squashfs` 大小檢查(§3.7.4) |
| A2-m2 FIFO、多個刪除者 | `O_NONBLOCK`;helper 是唯一刪除者;lock 持有者活著不刪(§3.7.4、§4) |
| A2-m3 / B2-m11 key 8 的分割 | 比對目標槽(§3.7.1) |
| A2-m4 重裝同版本誤報 | update-last 以槽判讀(§3.7.3) |
| A2-m5 / B2 weak host | 證據改為 fw4 規則(F58) |
| A2-m6 / B2-m1 `phy1-ap0` 寫死 | ifname 從 `network.wireless status` 取(F52) |
| A2-m7 備援觸發的意圖、EMCON、關閉時切 session | §3.8.1;EMCON 寫進 checklist |
| A2-m8 漏列介面 | v3:`bulk.done`、AP client 查詢、poll 帶 key 3、`max_msg` 與 9 KiB;**v4 拿掉 `bulk.done` 與 AP client 查詢**(§14) |
| A2-m9 / B2-m9 明文 bearer | 誠實界線;PUT 綁建立 session 的來源 IP(§3.8.2、§7) |
| A2-m10 / B2-m6 `verdict()` 的消費者 | 不改 `verdict()`,新增 `verdict_code()` + `join.reason_code`(§3.4) |
| A2-m11 otaBusy 在解析階段 | helper 記憶體旗標 `updating`(§3.7.4) |
| A2-m12 文件不一致 | D15 指 stage1-impl 的 D15;CDDL key 5 / bulk key 2 / phase 2 列進 §10;§9-3 關閉;降級列寫明 overrides.uci |
| A2-m13 撤銷界線、min_from 跨 channel | §3.7.1 |
| A2-m14 CM4 | **使用者決定 D17**(開發 Lite、量產 eMMC → checklist) |
| A2-m15 bulk tmpfs 常駐 | 誠實界線 + checklist(§3.8.2) |
| B2-m2 update-check-resp 形狀 | 被拒用 ok 回應 `{1: false, 2: reason, 3: RAM}`(§3.1、§5.1) |
| B2-m4 私有目錄位置 | 改 helper RunDir `/tmp/run/batman`(F53) |
| B2-m5 prov-state 撞名 | 改讀 p6 既有的 `prov-state`,不新增檔(F54、§3.5) |
| B2-m7 PRESERVE 升降級 | 升級時 helper `--boot` 執行一次 `--save`;降級再升級 → 誠實界線 + app 重新配對(§3.3、§6) |
| B2-m8 bulk key 2 語意 | 不再一次性;協定 / CDDL 改(§3.8.2、§10) |
| B2-m10 VERIFIED 與 phase 3 | `begin_write` 先刪 VERIFIED;phase 3 由 pending + VERIFIED 重建(§3.7) |
| B2-m12 legacy | key 2 / 20 → `E_UNSUPPORTED{7}`(§3.3) |
| B2-m13 實體奪取、`PerformFactoryReset` | §7 新列;D14 標為「秘密不進 p5」的例外 |
| B2-m14 窗關閉與既有 session、慢速上傳 | 窗關了不收新連線、既有保留;最低速率 64 KiB/s(§3.8) |
| B2-m15 小缺口 | poll 帶 key 3;`.wbox-` 解析失敗 → 11;arm 後未重開 → phase 3;sysupgrade 臂負對照(§3.7、§8) |

## 14. v3 審查回應(B3 = `p3-review-v3-B.md`;v3 審查者 A 的報告被安全分類器擋下、未交,v4 送兩位新審查者)

| 項 | 處理 |
|---|---|
| B3-M1 IP→MAC 來源檢查可從 mesh 偽造 | **D19**:nft bridge 規則以進來的 bridge port 判斷(`kmod-nft-bridge`),`@ap_ports` 由 helper 維護,空 = 全丟(§3.8.1);負測試:另一台節點 eth0 以手機 MAC / IP / ARP 毒化 |
| B3-M2 ctl / ops 容量 | accept 不再問 helper;新增 `ro` 連線給 app 的唯讀動詞,poll 獨占 ctl(§2);拿掉 `bulk.done`(§3.8.2);setkey 呼叫含還原 ≤ 300 s < `HelperWait`(§3.3) |
| B3-M3 新卡配對失敗回不去 | setkey `--rollback`:舊 key 是 placeholder → 回到封鎖;passphrase 走 stdin;`--ap-section` 只寫 `default_radio0`(§3.3) |
| B3-M4 未入網改國家讀回不成立 | 被封鎖的 radio 只驗 uci + regdb;晶片端驗證在 join 的既有讀回(§3.3) |
| B3-M5 autocommit 不看 provd / helper | **D18**:helper 在跑 + provd 本次開機穩定 ≥ 60 s 一次(`provd-stable`)(§3.7.5) |
| B3-m1 遺失手機的 AP 密碼 | **D20**(§3.11、§7) |
| B3-m2 時間來源 | 全部用 uptime(§3.4、§3.8) |
| B3-m3 D15 的兩條死路 | legacy 未入網可改國家;`network/update` 比對已存的 net_config 國家(§3.3) |
| B3-m4 ctl 唯讀的說法 | ctl 維持嚴格唯讀;備援由 provd 自己決定;diag 刪除改純到期(§2、§3.5、§3.8) |
| B3-m5 F49 的事實 | keyguard 開機時也會自己解除(key 已設好時);`--ap-section`(§3.3) |
| B3-m6「版本變了就 `--save`」的隱藏資源 | 改為 `--check` 對「p5 沒有、live = `/rom` 預設」的新 key 視為 fresh(§3.3) |
| B3-m7 helper 在上傳中重啟 | §3.8.2、§6 |
| B3-m8 arm 後、重開前掛掉 | 先寫 update-last 再 arm;helper 啟動時 disarm(§3.7.3) |
| B3-m9 之後換槽誤判 | 比對該槽版本(§3.7.3) |
| B3-m10 P3 之前的 payload | 誠實界線 + checklist(§11) |
| B3-m11 CM4 無線型號 | §6 平台列 |
| B3-m12 app 的 socket 綁 Wi-Fi | §3.11 第 8 點 |
| B3-m13 快取第一次請求 | 等 ≤ 2 s,否則省略 3 / 5 / 15(§3.4) |

v3 審查者 A 雖然沒有報告,但它列出查過的面:setkey 的 placeholder / `--ap` 與還原、未入網改國家、provd 單一 ctl / ops 的容量、D16 來源檢查的強度、poll 介面是否存在、trial 期間寫 p5 / apply 後重開 / key 8 的分割 — 前五項與 B3 的 M1–M4 重疊、已處理;poll 存在(`server.go:20,316-344`,F 已引);其餘留給 v4 審查者自行查證。
