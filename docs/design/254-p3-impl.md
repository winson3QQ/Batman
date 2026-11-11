# #254 PR-P3:擁有者 / 設定 / 狀態 / 診斷 / 更新 / 上傳 / 轉賣工具(設計 v7.3 — S5 實作前核對 + 審查修正,審查中)

狀態:v7.3(2026-11-11)= v7.2 + **§12.5 審查修正**(v7.2 審查 A8 / B8 都 APPROVE-WITH-CHANGES、0 BLOCKER、各 2 MAJOR;回應見附錄 E),送兩位整份重審。v7.2 = v7.1 + **§12 S5 實作前核對**(事實更正與 8 項設計沒寫到的決定;只動 §3.7 / §3.8 / §3.11 的範圍),送兩位審查。v7.1 原狀態:**凍結**(v7.1,2026-11-02)。v7(bfb6703)兩位審查都 **APPROVE-WITH-CHANGES、0 BLOCKER / 0 MAJOR**(A 11 MINOR、B 12 MINOR),都判定已收斂、建議凍結。v7.1 = v7 + 審查要求「凍結時一起改」的文字修正(A7-m7);其餘 MINOR 是實作 PR 的必做清單(附錄 D,每項附測試)。**凍結條件**:§9-4 的現場探針在 H4 凍結前跑完並附原始輸出(D22)。歷程:v1 96a578d、v2 03963d9、v3 6433520、v4 5d5ebfd、v5 1ac5fbd(整份重寫)、v6 c252b3f、v7 bfb6703。各輪審查在 `docs/design/254-reviews/p3-review-v*-*.md`。
上層:`254-stage1-impl.md` §10.6;協定 `219-protocol.md` v0.8 + `219-protocol.cddl`;P2 = `254-p2-impl.md` v8.5(已出貨 `1.5.14-wsl.22`)。
原則(使用者):**只做必要的修改**、**失敗就回到之前的狀態**。事實附 `file:line` 或 04 實測;沒有證據的標 ⚠️,並寫明實作前要怎麼查。

## 0. 一句話

provd 仍是唯一入口。P3 補上協定動詞:擁有者增刪、設定(改名 / 國家 / 手機 AP 配對)、自己的狀態、診斷、`peers/challenge`、軟體更新、上傳;每個都由 helper(root)執行並自己驗證。軟體更新以兩層鑰匙簽章(離線根鑰匙背書 YubiKey 上的簽章鑰匙,ES256 + COSE_Sign1)。約 126 MB 的 payload 經**這台節點自己的手機 AP** 用 HTTP 上傳:上傳窗由擁有者經 BLE 開 15 分鐘、只給這位擁有者;防火牆只讓**手機 AP 那個 bridge port** 進來的封包到 8095。同一個 HTTP 伺服器在 BLE 不健康時自動當備援入口(只收擁有者 / 成員)。沒有暫時 AP。

## 1. 決策、範圍

### 1.1 使用者決策(#254 留言 6569483517、6570171273、6570854836、6571066959、6571580317、6572031133;最後一題 2026-11-02 對話)

| # | 決策 |
|---|---|
| D1 | 順序:P3 設計 + 兩位審查 → H4 照本文件契約寫並先 merge → P3 實作 → rc → 上機 → H4 + P3 完成後、app 開工前跑全套 |
| D2 | 重做 host 端 provd 擁有者 client(H4);被分類器擋再說 |
| D3 | `update/*`、`bulk/*` 算進 P3 |
| D4 | B18 兩層鑰匙:離線根鑰匙(兩份,不同地點)+ YubiKey 上的簽章鑰匙;背書 / 撤銷免重燒;防降級。終端使用者不持有發行鑰匙 |
| D5 | 沒有暫時 AP:上傳走這台節點既有的手機 AP;手機 AP 不暫停 |
| D6 | autocommit 的 **BLE 無線電**檢查維持 WARN(P-U5,等 #305),只補新鮮度。HTTP 備援只在 BLE 不健康時開、恢復就關 |
| D7 | `status` 只做 self;team(`dac_pub_hash`、最後看到時間)進 checklist |
| D8 | 改名:副作用**待 U5 探針**(使用者回現場時由 Claude 在 04 跑);本設計只定改名寫什麼、失敗怎麼還原 |
| D9 | 國家以 `net_config` 為準;**國家不同就拒絕入網**;app 在入網前用 `settings/set` 改國家;P2 wireless txn 不動;整個網路一起改國家進 checklist |
| D10 | `diag/summary` 成員可讀;`diag/bundle` 只給擁有者 |
| D11 | `prov-eeprom-hooks-254` 的 1.5.12 負對照與 fresh-overlay 檢查併 H4 |
| D12 | 版本:同 MAJOR.MINOR.PATCH 時正式版(無後綴)> 任何 `-<channel>.N`;正式 → 開發只在簽章允許時 |
| D13 | 更新前兩端 Wi-Fi 都檢查;節點手機 AP 關著 → 拒絕開上傳(不自動開:發射是人的決定);拒絕經 mesh 轉來的上傳;節點回報是否跑 TAK server,app 在 apply 前警告 |
| D14 | 手機 ↔ 自己節點 Wi-Fi 配對:擁有者 app 經 BLE 設這台手機 AP 的 SSID + 強密碼(存 p5 — 使用者決定的例外,見 §7),失敗還原;不隱藏 SSID;EMCON 進 checklist |
| D15 | HTTP 只收這台節點手機 AP 的 client,**由防火牆在 L2 以 bridge port 判斷**;BLE 壞時擁有者連上這台節點自己的 AP |
| D16 | autocommit 對新版加看:helper 在跑,且 provd 試用期間至少一次連續穩定 ≥ 60 s(之後被弄當不算) |
| D17 | 遺失手機:`owner/remove` 後 app 提示以 key 20 換 AP 密碼;認領後 app 建議加一位備用擁有者 |
| D18 | CM4:開發用 Lite(SD 卡),量產用 eMMC → eMMC 的轉賣 / 遺失手機重燒路徑(rpiboot)量產前要做(checklist);本 PR 的轉賣工具只做 SD 卡 |
| D19 | `/cgi-bin/bundle` 照規格:只在 unclaimed / legacy **且**有 `/etc/batman-dev-open` 時給(現役 legacy 節點要下載時,用 ssh 建旗標) |
| D20 | **基本沒有 legacy 節點,app 伴隨機台設定**:P3 不為 legacy 設計 — legacy(`RadioManaged = false`)上 `settings/set` key 2、key 20 一律拒絕;legacy 只保留 P1 的最低限度(不掉線、可被認領)。02 / 04 現在是 legacy → H4 / P3 上機前重燒成新卡再認領(破壞性,先列步驟給使用者)(#254 留言 6573253167) |
| D21 | **不做晶片端的國家實測**:改國家只驗 uci + regdb;「晶片真的換表」是誠實界線,留到 app 階段在合法的國家驗(在台灣的 bench 不能發 EU / JP / KR 的頻道)(#254 留言 6575410512) |
| D22 | HTTP 來源規則的功能探針在 02(非 DUT)做:非 VLAN 部分已做(F75);VLAN 臂與「AP 上的 client 通過」等使用者在現場 |

### 1.2 範圍

**在本 PR**:§3。**不在本 PR**(理由):
- app 本身(U9);app 要做的檢查寫在 §3.11。
- `status` team(D7);EMCON(D14);autocommit BLE 無線電擋 commit(D6);`owner.replace`(L29 / S3);恢復出廠、608B(#255);bcm2710 實測(P-U14);CM4 實測與 eMMC 重燒(D18)。
- 邀請 QR 的產生 / 申請 / 同意:網主 app 的簽章物件(協定 §7.6);節點只收 `network/join` 選填的 `invite_id`(P2 已轉送),**節點端無新增**。
- 冪等快取:不做(§5.2 寫每個動詞的重送語意;協定 §4.2 同步改)。
- 未簽章的更新 / 重設路徑**不關**:操作員 ssh `sysupgrade`、LuCI 刷韌體、openmanetd 的 local upgrade 與 `PerformFactoryReset`(都要管理密碼)— 誠實界線(§7)。
- 改國家只動 HaLow(`radio1.country`);5 GHz 手機 AP(`radio0`)的國家不動(D9 只要 HaLow;改 radio0 會多一個失敗點而沒有需要它的理由)。

### 1.3 事實(main 2ecf1cb;節點 = 04 `1.5.14-wsl.22`;審查者另行查證的標 〔A〕〔B〕,第 N 輪審查補的標 〔AN〕〔BN〕)

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
| F11 | provd 的 ujail 沒有 netns、沒有 seccomp、capability 全空;掛載全是唯讀;**有自己的 pid namespace**:procd 的 instance pid 是 ujail(root),provd 是它的子行程 〔A5〕〔B5〕 | `files/batman-provd.init:18-19`;`batman-provd.json`;04:`ubus call service list` → `"pid": 8388`(`/sbin/ujail`,uid 0);provd = 8414,`PPid: 8388`、uid 471、`NSpid: 8414 1`、exe `/usr/bin/batman-provd` |
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
| F49 | keyguard(S18,每次開機)看到 placeholder AP key 就 `default_radio0.disabled=1` + `/etc/halow-keyguard.blocked` + commit;key 已是真值時開機自己解除 〔B3〕;執行期解除的門是 `halow-setkey`(拿 `$RUNDIR/halow-setkey.lock`,chanfix 也拿;讀回、persist);`--ap <psk>` 已有,但它寫**每一個** `mode=ap` iface 〔B3〕 | 04 `/etc/init.d/halow-keyguard:8-46`;`halow-setkey:2-31,48,213-227,262-303,286-288` |
| F50 | AP 的 SSID 由 `99-halow-identity` 在新卡時設為 hostname;openmanetd 也有設 SSID 的介面(`SettingsWireless`) 〔A2〕〔B2〕 | `99-halow-identity:19-21`;04 `strings openmanetd` |
| F51 | `wifi reload radio0` 的參數被忽略 = `ubus call network reload` 〔A2〕 | 04 `/sbin/wifi` |
| F52 | phy 編號會漂移(04 只剩 phy1 / phy2);AP 的 ifname 要從 `ubus call network.wireless status` 取 〔A2〕〔B2〕 | 04 `ls /sys/class/ieee80211` |
| F53 | `/tmp/run/batman-prov` 是 root:provd 0750 且 ro bind 進 provd 的 jail;helper 自己的 RunDir = `/tmp/run/batman`(root 0700) 〔B2〕 | 04 mountinfo;`provstore.go:339` |
| F54 | p6 已有 `/opt/batdata/state/prov-state`(`<boot_id> helper <state> <verdict> …`,0600) 〔B2〕 | 04;`main.go:471-473` |
| F55 | legacy 認領 = `RadioManaged=false`(保留操作員的 radio);04 現在是 legacy 〔B2〕 | `node.go:539` |
| F56 | `begin_write` 不刪 `BATMAN-VERIFIED`(新檔);payload 不帶 `config.txt`,trial 用的是**目標槽** boot 分割上的 config.txt 〔A2〕〔B2〕 | `build-ab-payload.sh:17-18`;`batman-slot:697`;04 `autoboot.txt` |
| F57 | `platform-ab.sh` 依名字取 tar 成員(`-X`、`-xOf root.squashfs`),與順序無關 〔A2〕〔B2〕 | `platform-ab.sh:207,328,368,370` |
| F58 | Linux weak host model:`LocalAddr` 不代表進來的介面;br-ots(`dockert`)input DROP;**`docker` zone(docker0)是 input ACCEPT**;容器流量經 docker0 / br-ots 的 veth 進來時會經過 bridge input hook(iifname = veth…)〔A5〕〔B5〕 | 04 `uci show firewall`、`nft list ruleset` |
| F59 | `/etc/init.d/firewall stop` = `fw4 flush` = 刪掉**所有** nft 表(各 family);`fw4 restart` / `reload` 只重建 `inet fw4`;fw4 每次 start / reload 會 include `/usr/share/nftables.d/ruleset-post/` 〔A4〕〔B4〕 | 04 `/etc/init.d/firewall`、`/sbin/fw4:61-67`、`ruleset.uc:472` |
| F60 | bridge family 的 filter chain 已編進兩板的 `nf_tables`(`nft_chain_filter.o` 有 `nft_do_chain_bridge`;`CONFIG_NF_TABLES_BRIDGE=m`、`CONFIG_NETFILTER_FAMILY_BRIDGE=y`)→ **不需要 `kmod-nft-bridge`**(它只多帶 `nft_meta_bridge`,`iifname` 用不到)〔A5〕 | firmware build_dir 的 bcm2711 / bcm2710 `linux-6.6.138/net/netfilter/nft_chain_filter.o`、`.config:1325-1326` |
| F61 | 04 沒有 `/rom/etc/config/wireless`(也沒有 `system`);AP SSID 由 `99-halow-identity` 在新卡時設為 hostname 〔A4〕〔B4〕 | 04 `ls /rom/etc/config` |
| F62 | `halow-setkey` 時間常數:LOCKWAIT 90、FORGET_WAIT 30、SETTLE_WAIT 30、READBACK_WAIT 60;persist = `batman-config-save --save`(鎖等 10 s);helper 對 setkey 的上限 300 s(逾時 = outcome unknown) 〔A4〕〔B4〕 | `halow-setkey:37-40,165`;`batman-config-save:244`;`cmd/batman-provhelper/main.go:84-85` |
| F63 | `--check` 拿整份 `overrides.uci` 逐 byte 比(`cmp -s`),stale 時輸出 `p5 stale: <key>`、rc 5;自動 `--save` 只有 joinwatch `--on-join`(只在 JOINED)與 setkey 〔A4〕〔B4〕 | `batman-config-save:440-494`;`joinwatch:150`;`halow-setkey:165` |
| F64 | `batman-slot` 的 CLI 動詞:active、target、layout、fw-part、stage-root、apply、commit、rollback、is-trial、verify、precheck-node、verdict-gate、`reboot committed`;**沒有** `disarm`(`disarm_tryboot` 只是內部函式);tryboot 旗標是一次性的 〔A4〕〔B4〕 | `batman-slot:392`、`:716-738`、`:871-915` |
| F65 | helper socket 最多 4 條連線(`sock.MaxConns = 4`);唯讀額度兩層:每連線 5/s burst 20、全 helper 10/s burst 40;連線的 SO_PEERCRED 都是 uid 471,分不出 ctl / ops / provclient 〔A4〕〔B4〕 | `sock/sock.go:1-6,28`;`node/readonly.go:7,21-24` |
| F66 | openmanetd 也寫國家(`SetupCountry`、`currentMorseCountry`) 〔B4〕 | 04 `strings /usr/bin/openmanetd` |
| F67 | autocommit 的 MIN_WINDOW 300 s、NEED 3 × POLL 10 s;provd 在 bluetoothd 不在時不結束(只要 `/tmp/run/dbus` 存在),`preflight` 只檢查廣播長度 〔A4〕〔B4〕 | `batman-autocommit:30-35`;`cmd/batman-provd/main.go:67-79`、`bluez.go:70-80,629-639` |
| F68 | 04 上所有節點目前都是 legacy,沒有 `/etc/batman-dev-open` 〔A4〕 | 04 |

| F69 | nft 只把字串**最後一個** `*` 當萬用字元(前綴比對),中間的 `*` 是字面字元 〔A5〕〔B5〕 | nftables 1.1.1 `src/evaluate.c:362-431`(firmware build_dir) |
| F70 | fw4 start 把整份 ruleset(含 `ruleset-post/*.nft`)以**單一** `nft -f` 交易載入:include 有錯 → 整份失敗、開機後沒有 `inet fw4`;fw4 只 `flush table inet fw4`,include 裡的其他表每次 reload 會重複加 〔A5〕〔B5〕 | 04 `/sbin/fw4` start、`/usr/share/ucode/fw4.uc:816-821`、`ruleset.uc:1-11` |
| F71 | `96-batman-config-migrate` 是 uci-default,每個新槽 overlay 只跑一次;一般重開不會再跑(04 `/etc/uci-defaults/` 只剩 `README`)〔A5〕〔B5〕 | `96-batman-config-migrate:2-4`;04 |
| F72 | helper 的 `run()` 對 setkey / config-save 以外的子程序預設 60 s 期限;`provstore.Exec` 逾時對整個 process group SIGTERM、10 s 後 SIGKILL 〔A5〕〔B5〕 | `cmd/batman-provhelper/main.go:78-91`;`provstore/exec.go:27,37-42` |
| F73 | `halow-setkey` 現在的 `--ap <psk>` 把密碼放在命令列;只有 `--mesh -` 讀 stdin;setkey 以一般 `uci commit wireless` 提交(會一起提交別人在 `/tmp/.uci/wireless` 的暫存)〔A5〕〔B5〕 | `halow-setkey:51,64-65,228,307,366` |
| F74 | 未入網、`RadioManaged = true` 的節點 radio1 一定被封鎖:新卡的 mesh key 是 placeholder(keyguard 關,F49),認領時 `RadioManaged` 就設成 true(`node.go:539`:`next.RadioManaged = rec.State == provstore.Unclaimed`),認領不設 mesh key;離開網路走 `--forget-mesh`(radio 確認關閉,P1b) 〔A6〕〔B6〕 | F49;`node.go:539`;`halow-setkey --forget-mesh` |
| F75 | **02 實測(2026-11-02,使用者同意,非 DUT)**:臨時表 `bridge`(`iifname "phy*" meta mark set meta mark \| 0x01000000`)+ `inet` input priority −10(`tcp dport 8095 meta mark & 0x01000000 == 0 drop`)可以載入(nft 1.1.1,沒有 `kmod-nft-bridge`);04 經 mesh 連 02:8095:沒有規則時 0.40 s 被拒 → 有規則時 4.31 s 逾時(被丟),02 本機 lo 也被丟,drop 計數 7(SYN 重送);刪表後 `nft list tables` 與基準相同、0.36 s 被拒。02 沒有其他 fwmark 使用者(`ip rule` 只有 local / main / default,ruleset 沒有 mark)。**未測**:AP 上的 client 通過(mark 從 bridge 帶到 IP 層)、VLAN 封裝(D22) | 02 / 04 輸出(本 session) |
| F76 | bridge hook 依外層 ethertype 決定看不看得到 L4:帶 VLAN 封裝的 frame 在 bridge 的 `tcp dport` 比對不到,之後 kernel 可能剝掉標籤交給 IP 層 〔A6〕 | `nft_chain_filter.c:239-248`;`net/core/dev.c` VLAN 處理(⚠️ 推論,VLAN 臂未實測) |
| F77 | helper 以 pipe 接 setkey 的輸出(`provstore.Exec`,`bytes.Buffer`);helper 不忽略 SIGPIPE、setkey 沒有 `trap` → helper 一死,setkey 下一次輸出就被 SIGPIPE 結束(狀態可能停在一半) 〔A6〕〔B6〕 | `provstore/exec.go`;04 `/proc/<helper>/status` `SigIgn: 0`;`halow-setkey` 無 trap |
| F78 | `halow-setkey` 用 `uci set …key=$AP` 寫密碼 → 密碼會短暫出現在 `uci` 的 argv 〔B6〕 | `halow-setkey`(`--ap` 路徑) |
| F79 | morse regdb:channel 40 只在 US / AU / NZ / SG 等(922.0 MHz);EU 只有 1,3,5,7,9,2,6;JP、KR、IN 也沒有 40;新卡預設 channel 40 / US 〔B6〕 | 04 morse regdb;`meshpoint-1.8.0:21,49-50` |
## 2. 總體結構

```
app ──BLE GATT(P2:2 槽,20 交握/分)───────────────────────────┐
app ──HTTP :8095(自己的 2 槽、10 交握/分;只有手機 AP port 進得來)┴→ batman-provd(uid 471,ujail)
        ctl(poll,每 4 s)/ ro(app 的唯讀)/ ops(會改狀態,一次一個)──→ batman-provhelper(root)
```

**不變的 P2 契約**:provd 不碰 root 資源、不讀 health 檔;owner-op 由 helper 驗章;provd 只做角色、額度、分塊、Noise、HTTP。

**provd ↔ helper 三條連線**(F65:最多 4 條):

| 連線 | 用途 | 額度 / 時限 |
|---|---|---|
| ctl | **只給 poll**:`health.get`、`info.state`、`info.boot_id`、`info.owners`(每 4 s,約 1/s);**嚴格唯讀** | 每連線 5/s;poll 不會被 app 的讀取擠到 ERate(否則 120 s 後 `HealthOK` 變 false、BLE 撤廣播) |
| ro(新) | app 觸發的唯讀動詞:`settings.get`、`status.get`、`diag.summary`、`diag.read`、`update.status` | 每連線 5/s;ro + ctl ≈ 6/s < 全 helper 10/s;超過 → 只回 `E_RATE` 給 app |
| ops | 會改狀態的動詞,一次一個 | `HelperWait` 330 s;helper 端每個新動詞的上限 ≤ 300 s(§3.3 的預算) |

第 4 條留給 H4 的 provclient:**最多 1 條,且不與 app 的讀取並行**(H4 的規則)。

**HTTP 開關**(§3.8):
- **上傳窗**由 helper 決定:poll 的 `health.get` 回覆帶 `http` 欄位 `{2: 監聽位址, 3: 上傳窗擁有者 key id, 4: 剩餘秒數(uptime), 5: pending 的 payload 大小}`。
- **備援**由 provd 自己決定(它自己的 `HealthOK()`,F45),監聽位址同樣取自 `http.2`。
- **helper 只在確認防火牆規則在時才給 `http.2`**(§3.8.1);沒有 `http.2` → provd 不 bind(兩種模式都一樣,fail-closed)。
- provd 重啟後從下一次 poll 拿回狀態,不自己記。

## 3. 設計

### 3.1 provd 路由與錯誤碼

1. `p3Types` 改成空集合(保留機制)。
2. 角色:
   - 擁有者 += `owner/add`、`owner/remove`、`settings/get`、`settings/set`、`status`、`diag/summary`、`diag/bundle`、`update/check`、`update/prepare`、`update/apply`、`update/status`、`bulk/open`、`bulk/close`。
   - 成員 += `status`(摘要)、`diag/summary`、`peers/challenge`。
   - **HTTP 接受 psk_owner(→ 候選 → 必須 `auth/owner` 才是擁有者,F44)與 psk_member;不接受 NX(匿名)與 psk_replay(重取)**:認領與重取都必須人在旁邊、走 BLE。
   - **`settings/set` key 20 只接受 BLE session**(HTTP 上 → `E_UNSUPPORTED{1: typ, 2: 7}`):改 AP 會切斷承載這個請求的 Wi-Fi 連線,回應會遺失(A4-m3)。
3. 轉送表:

| 協定 type | helper 動詞 | 連線 | owner-op | 回應 |
|---|---|---|---|---|
| `owner/add` | `owner.add`(既有) | ops | 要 | `{1: owner_tag_key}`(秘密,`secretTypes` 已含) |
| `owner/remove` | `owner.remove`(既有) | ops | 要 | `{}` |
| `settings/get` | `settings.get`(新) | ro | 不要 | CDDL `settings`(不回密碼) |
| `settings/set` | `settings.set`(擴充,§3.3) | ops | 要 | 套用後的 `settings` |
| `status` | `status.get`(新) | ro | 不要 | `status-resp`(成員 = 摘要) |
| `diag/summary` | `diag.summary`(新) | ro | 不要 | `diag-summary-resp` |
| `diag/bundle` | `diag.bundle`(改,背景產生)+ `diag.read`(新) | ops + ro | 要(bundle) | 分塊 `{1: bstr}` |
| `peers/challenge` | `sign.peer`(既有) | ops | 不要 | `{1: nonce_node, 2: sig}` |
| `update/check` | `update.check`(新) | ops | 不要(擁有者角色) | `update-check-resp`:被拒 = `{1: false, 2: reason, 3: RAM}`(CDDL 形狀);只有並發 → `E_BUSY` |
| `update/prepare` | `update.prepare`(新,啟動背景 worker) | ops | 要;body 帶 `sha256(SHA256SUMS)` | `update-progress`(phase 2,立刻回) |
| `update/apply` | `update.apply`(新) | ops | 要;body 帶同一個 sha | `update-progress`(然後重開) |
| `update/status` | `update.status`(新) | ro | 不要 | `update-progress` |
| `bulk/open`、`bulk/close` | `bulk.open`、`bulk.close`(新,§3.8.2) | ops | 要 | `bulk-open-resp`(秘密,`secretTypes` 已含)、`{}` |

4. **唯讀動詞不跑子程序**(`readonly.go:1-8` 的契約):只讀 helper 記憶體裡的快取或 helper 自己的檔案;快取由 helper 背景更新(§3.3、§3.4)。
5. **長動作不拿 `n.mu`**(F37):`update.prepare` 只做檢查 + 啟動 worker 就回;worker 經 `batman-slot` 的鎖(F35)互斥;helper 記憶體旗標 `updating` 從 worker 開檔起為真,`otaBusy()` 也看它。`diag.bundle` 的產生也在背景。
6. **`settings.set` 會拿 `n.mu` 直到 setkey 結束(最長約 230 s,§3.3 的預算)**:這段期間新的 BLE / HTTP 交握(要 `sign.static` / `psks.get`)會等待 — 與 P2 的 `net.apply` 相同;app 顯示「節點忙碌,最多約 4 分鐘」(§3.11)。
7. **`otaBusy()` 擋的動詞**(→ `E_BUSY`):worker 在跑或上傳窗開著時,`settings.set`、`update.check`、`network/join`、`network/update`、`network/leave`(會 reload 網路的動作不能打斷 126 MB 的上傳);**另一位擁有者**的 `bulk.open`;worker 在跑時的第二個 `update.prepare`。**不擋**:上傳窗擁有者的 `update.prepare`(這是正常流程,它會關窗)與同一位擁有者重送的 `bulk.open`(= 延長窗)。
8. **錯誤碼**(F38、F39):
   - helper 新碼 `hERejectR = 24`(帶 `reason`)→ `E_REJECTED{2: reason}`;`hEInput = 25`(使用者輸入不合法,帶 `reason`)→ `E_REJECTED{2: reason}`,**不記 CRIT**(`hESchema` 維持「provd 送錯格式 = provd bug」)。
   - helper 錯誤回覆加選填 `reason`(uint);`hEUnsupported` 也帶 `reason` 時 → `E_UNSUPPORTED{1: typ, 2: reason}`(A4-m10);沒有 `reason` → 照 P2 對應(相容)。
   - 新 reason-code(CDDL 加):**11** 內容與簽章不符 / 版本解析失敗;**12** 有未完成的網路變更(`.txn`);**13** 值不合法;**14** 國家:要在未入網時改 / 入網的國家與節點不同;**15** 這一步的前提不成立;**16** 節點手機 AP 關著;**17** p5 還沒存到最新(stale);**18** 新版沒有開機成功(`update-progress` key 3);**19** 這個動作只能經 BLE;**20** legacy 節點不支援(D20)。reason **7** 只留給「這台硬體沒有這個能力 / 這個參數」(key 10–13、`status` team)。完整對應在 §5.1。
9. 每連線額度:`peers/challenge` 0.5/s;`status`、`diag/summary` 每連線 1/s、全域 2/s;`update/check` 每連線 1 / 10 s。

### 3.2 擁有者增刪

helper 行為不變(F3)。本 PR:provd 路由;`owner/remove` 後依 P2 的 `invalidate → reconcile` 切斷被移除者的 session(BLE 與 HTTP);補 F4 的 Go 邊界測試(`sig_enc` 錯、第 5 位、最後一位、未知 kid、重送輪替 tag key、remove 輪替 `adv_owner_key`)。文件:`219-protocol.md:447` 改為輪替 `adv_owner_key`(以 `:203` 與程式碼為準);`254-p1-impl.md:465`「admins +1」刪除。遺失手機的 AP 密碼 → D17(§3.11)。

### 3.3 設定:`settings/get`、`settings/set`

**`settings.get`(唯讀,ro)**:回 `1` hostname、`2` 國家(`radio1.country`)、`10` `{1: radio1.channel, 2: regdb 推的頻寬}`、`20` `{1: 手機 AP 的 ssid}`(不回密碼)、`11`–`13` 依 `info.capabilities` 有才回。**資料來源**:helper 的設定快取 — 最近 10 分鐘有人問過時每 15 s 以 `uci -q get` 刷新(single-flight,不在請求路徑上);helper 自己的 `settings.set` 成功後立刻刷新;openmanetd / 操作員改的值最遲 15 s 後看得到(B4-m4)。第一次請求:觸發刷新、最多等 2 s。

**`settings.set`**:一次只帶一項(1、2 或 20);key 10–13 → `E_UNSUPPORTED{1: typ, 2: 7}`(頻道走 `network/update`);未知 uint key 忽略(CDDL `* uint => any`,改 `254-p1-impl.md:466`);文字 key / 一次多項 → reason 13。

| key | 誰可以 | 驗證 | 經由(現有的門) |
|---|---|---|---|
| 1 名稱 | 所有已認領節點 | `[A-Za-z0-9-]{1,32}`,不以 `-` 開頭結尾 | `uci` + `batman-config-save --save`(system 沒有 setkey);commit 前 `/tmp/.uci/system` 非空(別人有暫存,F48)→ `E_BUSY` |
| 2 國家 | 未入網、`RadioManaged = true`(D20:legacy → `E_UNSUPPORTED{1: typ, 2: 20}`);已入網 → reason 14 | 2 個大寫字母、regdb 有這個國家(**不檢查目前頻道**:新卡預設 ch 40 不在 EU / JP / KR 的表裡,F79,檢查它會讓 key 2 與 D9 互鎖;頻道在 join 時由 setkey 依新國家驗並讀回,`halow-setkey:88-100`) | `halow-setkey --country <cc> --rollback --lockwait 20`(新);`/tmp/.uci/wireless` 非空 → `E_BUSY` |
| 20 手機 AP | 已認領、`RadioManaged = true`(D20:legacy → `E_UNSUPPORTED{1: typ, 2: 20}`);**只經 BLE**(經 HTTP → `E_UNSUPPORTED{1: typ, 2: 19}`) | SSID 1–32 個 `[A-Za-z0-9 ._~+=,:@%^*-]`、不以空白開頭結尾;passphrase 12–63 個 `[A-Za-z0-9._~+=,:@%^*-]`、≠ `CHANGE-ME-NOW` | `halow-setkey --ap - --ap-ssid <ssid> --ap-section default_radio0 --rollback --lockwait 20`(新增 `--ap -`(stdin)、`--ap-ssid`、`--ap-section`、`--rollback`、`--lockwait`);**setkey 以 `uci batch`(從 stdin)寫密碼,不用 `uci set …=$AP`**(F78:否則密碼會出現在 uci 的 argv);`/tmp/.uci/wireless` 非空 → `E_BUSY` |

- **字元集**(F46):所有會進 p5 的值都不得含 config-save `UNSAFE` 的字元(`` ` $ ( ) ; | & < > ' ``);上表的字元集是它的子集,違反 → reason 13(**不是** `E_STORAGE`)。
- **`--ap-section default_radio0`**:只寫這一個 section(`--ap` 原本寫每個 `mode=ap` iface,而 PRESERVE 只存 `default_radio0`,F49)。
- **讀回**:
  - key 20:setkey 的讀回 + `network.wireless status` 的 radio0 up、iface 的 ssid 相符(ifname 從同一個 status 取,F52)。
  - key 2:**radio1 被封鎖**(未入網、`RadioManaged = true` 的節點一定是,F74;legacy 已被 D20 排除)→ 只驗 uci 值 + regdb,不要求 up。**「晶片真的換表」不在 P3 驗**(D21):join 時 setkey 既有的讀回(`morse_cli` Operating Frequency 對 regdb centre,`halow-setkey:349-374`)只在 radio 起來時發生;在台灣 bench 上只能用與 US 同頻率的國家,分辨不出換表 → 誠實界線,app 階段在合法的國家驗。
  - key 1:`uci get` 相符。
- **`--rollback`(失敗就回到之前的狀態,由 setkey 在同一次呼叫裡做)**:
  - 舊值是正常值 → 寫回舊值並讀回。
  - key 20 的舊 key 是 placeholder(剛認領的節點)→ **回到封鎖**(placeholder + `disabled=1` + MARK,驗證 AP 不在空中),因為 setkey 拒收 placeholder 當新值(`halow-setkey:83`)。
  - key 1 由 helper 寫回舊值 + `--save`。
  - 回 reason 13(值被拒 / 起不來)或 `E_STORAGE`(persist 失敗)。
- **時間預算**(F62;helper 對 setkey 的上限 300 s):
- **setkey 新旗標的結束碼**(helper 依此對應 §5.1;既有模式的結束碼不變;附錄 D-5 / D-6 實作時定案,#324):

  | rc | 意思 | helper → app |
  |---|---|---|
  | 0 | 成功(讀回 + persist);值與現值相同 → 不改、不 reload,但先 `--check`,p5 不新鮮就 `--save`(斷電在 commit 與存檔之間;審查 A r2 MAJOR-2;存檔失敗 → 4)。AP 要在空中且 ssid / key 相同才算同值 | `OK` + 套用後的 settings |
  | 2 | 值不合法、沒有寫入(含密碼多於一行、中間有 CR);或現有的 AP key / ssid(app 以外設的)含引號 / 反斜線 / 換行,失敗時寫不回去 → 改之前就拒絕(安全審查 B r2 m1) | `E_REJECTED` reason 13 |
  | 3 | 套用了但讀回失敗(含 `uci batch` 沒落地,reload 前就讀回)→ 執行中的狀態已還原並驗證(原本關著 / 沒有 ssid 的 AP 驗證不在空中);p5 不新鮮就存 | `E_REJECTED` reason 13 |
  | 4 | persist 失敗 → 執行中的狀態已還原(還原後再存一次也失敗仍是 4:p5 不新鮮由 status key 4 說) | `E_STORAGE` |
  | 5 | 忙:拿不到鎖、別人暫存的 wireless 變更、未完成的 `.txn`、netifd 還沒 settle、run dir 不能用;沒有寫入(D-5) | `E_BUSY` |
  | 6 | 執行中的狀態還原沒驗證到(新卡:再做一次完整 `wifi` 仍在空中)→ 狀態未知(D-6) | 線上 `E_REJECTED{2: 13}`(helper `EApply` + reason;provd 帶 reason 轉出)+ CRIT log + status key 15 `settings_restore: "not verified"`,直到下一次**手機 AP** 的 settings.set 回 0(改國家不算:它沒有驗證 AP)。**誠實界線**:旗標只在 helper 記憶體,重開或 helper 重啟就不見;新卡那條路 uci 已是 placeholder + disabled + MARK,重開後 keyguard 讓 AP 維持關閉 |

  ⚠️ 實作時逐行對既有 `halow-setkey` 的結束碼,不撞號(既有模式不會回 6)。

| 階段 | 秒 |
|---|---|
| 等鎖(`--lockwait 20`,只給 P3 的呼叫;操作員與 chanfix 照舊 90) | 20 |
| settle | 30 |
| 套用的讀回 | 60 |
| persist | 15 |
| 還原的 settle + 讀回(或封鎖的確認 30) | 90 |
| 還原的 persist | 15 |
| 合計(最壞) | **230** |

  餘裕 70 s。沒有 `--rollback-only`。helper 逾時(setkey 卡在 D-state)= outcome unknown,與 P2 `net.apply` 相同 — app 以 `settings.get` 重讀。**helper 中途死掉**:setkey 一開始 `trap '' PIPE`,並把輸出寫到 stdout 失敗時忽略(F77:否則 helper 一死,setkey 下一次 echo 就被 SIGPIPE 結束,停在「已 commit、未讀回、未還原」);setkey 自己的 process group(`Setpgid`)擋 SIGTERM → 它拿著鎖跑完並自己 `--rollback`;helper 重啟後以設定快取的刷新看到結果。

- **PRESERVE 加 `wireless.default_radio0.ssid`**(config-save 與 setkey 的持久化清單,兩板共用;**不加 `radio0.country`**,§1.2)。ssid 的值若含 `UNSAFE` 字元(例如操作員或 openmanetd 設過 `Tom's AP`)→ **這一個 key 不持久化、不算 stale**(與空值同一條「image 預設勝出」規則,`batman-config-save:466`),`status` 回報「SSID 無法保存」;否則這種節點升級後 p5 會永遠 stale、OTA 永遠被擋(B5-m5)。
- **升級到 P3 後 p5 的 stale**(F63:整檔比對,`diff_keys` 列出每個不同的 key):未入網的節點 p5 沒有 ssid、live 有 → `--check` stale。helper 在**非試用的開機時**與**每次 `update.check` 通過簽章驗證之後**檢查:stale 的 key **全部是 P3 新增的 PRESERVE key**、沒有 `.txn`、不在試用中 → 執行一次 `--save`。其他 stale → `update.check` 回 reason 17。**同值的 `settings.set`** 也會在 `--check` stale 時執行 `--save`(否則 reason 17 在未入網節點上沒有 app 端的出路,A5-m3)。已入網的節點下一個 joinwatch tick 就會存。
- **降級**:舊版的整檔比對會判 stale,直到舊版下一次 `--save` / `--on-join`(已入網的節點一個 tick 內自癒;未入網的要 ssh `--save`)(A4-m1)。舊版的 96 照樣套用 p5 多出的 ssid 行(`valid_batch` 接受,B4 ✅)。再升級回 P3 時若 p5 的 ssid 已被舊版拿掉 → SSID 回 hostname,app 以 `settings.get` 發現不符並提示重新配對(誠實界線)。
- **改名(key 1)在 U5 跑完、改名單位通過之前,繼續回今天的 `rename-pending`**(`node.go:760-766`;D8)— 任何 rc / release 都不會帶著沒驗過的改名出貨。U5 之後才開放上表 key 1 那一列。
- **其他寫者**(最後寫的贏,都由 config-save 存;app 以 `settings.get` 為準):hostname — openmanetd(F32)、操作員、`99-halow-identity`(新卡);國家 — openmanetd(F66)、操作員;SSID — openmanetd(F50)、`99-halow-identity`(新卡)、操作員。

**國家與入網(D9)**:`network/join` 的 `net_config` key 5 ≠ `radio1.country` → 整筆拒絕(reason 14),不寫任何東西;`network/update` 的 key 5 ≠ **已存的** `net_config` 的 key 5 → 拒絕(只擋「改國家」;P2 時入網、radio 國家與 net_config 不同的成員仍收得到更新)。P2 wireless txn 與 `.txn` 格式都不變。開機修復不強制國家(誠實界線)。

### 3.4 狀態(`status`,self)

helper 背景維護兩個快取,**請求路徑上不跑子程序**;計時一律用 uptime(節點沒有 RTC:04 的 `date` = 2025-07-28):
- `halow-status json`:最近 10 分鐘有人問過時每 15 s 刷新(single-flight)。第一次請求:觸發刷新、最多等 2 s;等不到 → 回 key 1(`info.state`,不需要快取)與 `15: {stale: true}`;key 2–4 在 CDDL 改為選填(§10;目前 `219-protocol.cddl:229-240` 是必填)。
- `p5_saved`:最近 10 分鐘有人問過時每 120 s 最多跑一次 `batman-config-save --check`(cfgsave 鎖每 2 分鐘最多被拿一次,F28 的 `--on-join` 不會連續 8 次拿不到)。

| CDDL key | 來源 |
|---|---|
| 1 node-state | `info.state` |
| 2 verdict | `health.level`:OK 0、WARN 1、CRIT 2 |
| 3 鄰居數 | `join.batman_neighbours` |
| 4 p5_saved | 快取;超過 300 s 或從未算過 → 省略(CDDL 改選填,§10) |
| 5 join-failure | 未入網時:`{1: join.reason_code, 2: 原句}`;`reason_code` 由 joinwatch **新增的 `verdict_code()`** 給(與 `verdict()` 同一組判斷、同一個檔;`verdict()` 的句子與它的消費者 — diagline、STATE、`status` 頁的字串比對、deploy 鏡像 — 都不動),經 `halow-status json` 的新欄位 `join.reason_code` 帶出 |
| 6 電量 % | 省略 |
| 7 team | `scope = 1` → `E_UNSUPPORTED{1: typ, 2: 7}`(D7) |
| 15 #131 欄位 | 擁有者:`node`、`image`、`uptime_s`、`last_boot_reason`、`last_ota`、`temp_c`、`throttled`、`join{state, channel, country, plinks, snr_db}`、`tenants`(app 據此判斷是否跑 TAK server,D13);成員只拿 1–5 |

### 3.5 診斷

- **`diag.summary`**(ro):快取的 `health.checks[]` → `diag-item`(`1` id、`2` level、`4` msg)。
- **`diag/bundle`**(擁有者):`diag.bundle {1: session id(provd 給)}` 在背景產生 tar.gz 到 `/tmp/run/batman/diag/<handle>`(helper 的 RunDir,root 0700,F53),立刻回 `{1: handle}`;內容 = `/www/cgi-bin/bundle` 現在那份 + `batman-slot verify`,上限 2 MiB(超過從 logread / dmesg 尾端截,`MANIFEST` 註明)。`diag.read {1: handle, 2: offset}`(ro)回 `{1: total(未完成時 0), 2: ≤ 48 KiB}`(F12)。handle 綁 session id;同一 session 同時一份(新的取代舊的);全節點最多 2 份;**10 分鐘(uptime)到期刪**(不靠 provd 通知 session 結束)。helper 啟動時清空 `diag/`。
- **不含秘密**:不讀 `/etc/config/wireless`、`/etc/shadow`、`/etc/batman-prov/identity`、p5、hostapd conf;測試以**內容**比對(包裡不得出現現行 AP 密碼、mesh key、root 雜湊、tag key)。logread 會含 MAC / IP / 名稱 → app 送出前提示(`219-field-provisioning.md:477`)。
- **`/cgi-bin/bundle`**(D19):CGI(uhttpd 以 root 跑)讀 p6 既有的 `/opt/batdata/state/prov-state`(F54);只在第 1 欄 = 目前 boot_id、第 3 欄是 `unclaimed` 或 `legacy`,**且** `/etc/batman-dev-open` 是 root 擁有、regular、非 symlink、link count 1 時給;其他一律 403(fail-closed)。現役節點都是 legacy、都沒有旗標(F68)→ **升級到 P3 後網頁下載 403**,要下載時用 ssh 建旗標,或對有擁有者的節點用 app 的 `diag/bundle`(release note)。`deploy/provisioning/www/bundle` 鏡像同步改(`check-provisioning-sync.sh:34`);`halow-status:183` 的文字與 index / status / mesh 頁的連結改成「用 app 取得診斷包」;`status`、`mesh` 頁不變。

### 3.6 `peers/challenge`

成員可呼叫;轉 `sign.peer`(F17);每連線 0.5/s + helper 全域 2/s。`sign.peer` 取 `n.mu`(阻塞,F37):`settings.set` 進行中最長約 230 s 會等(§3.1.6)。Go 測試:簽章可驗、`nonce_app` 長度錯 → `hEInput`、兩層額度。

### 3.7 軟體更新(`update/*`)與發行簽章(B18)

#### 3.7.1 鑰匙與簽章物件(D4)

| 鑰匙 | 演算法 | 在哪 | 用途 |
|---|---|---|---|
| 根鑰匙 R(prod) | ES256 | 離線產生;私鑰只在兩支加密 USB(不同地點);公鑰內建 image `/usr/share/batman/release-root.pub` 與 app | 只簽背書 |
| 簽章鑰匙 K<sub>i</sub> | ES256 | 使用者的 YubiKey PIV slot 9c(裝置內產生、不可匯出) | 簽每個發行版本 |
| 測試根鑰匙 T | ES256 | repo `tests/keys/`(公開) | DEV 通道(`BATMAN_CHANNEL=wsl`)與 prov_test image 信任;正式通道 image 不得含 T,release gate 正向釘死 R 的指紋(§12.5.10) |

ES256:所有 YubiKey 5 的 PIV 都支援;節點已有 `cose.VerifySign1` / `VerifyES256`(F22)。YubiKey 回 DER 簽章,`release-sign.sh` 轉成 64 B `r‖s`(low-s)。⚠️ YubiKey 型號與 host 工具鏈待使用者在場時實測(§9)。

- **背書** E<sub>i</sub> = COSE_Sign1(R),content type `batman/relkey`,標籤 `batman-relkey-v1`,payload `{1: K_i 公鑰 65 B, 2: serial(uint ≥ 1)}`。
- **發行物件** S = COSE_Sign1(K<sub>i</sub>),content type `batman/release`,標籤 `batman-release-v1`;payload 的 key 與 `update-manifest` 同號:

| key | 欄位 | 用途 |
|---|---|---|
| 1 | version(`BATMAN_VERSION` 全串) | 版本規則 |
| 2 | board | = 本機 board |
| 3 | payload 大小(bytes,壓縮後的 `.tar.gz`) | 上傳大小、RAM 預算 |
| 4 | sha256(`SHA256SUMS`) | 綁定內容 |
| 6 | `[* tstr]`:可以從這些**較新**的版本降回本版 | 防降級 |
| 7 | min_from:目前版本必須 ≥ 它 | 不符 → reason 4(需要中間版本) |
| 8 | `[* sha256]`:本版可用的開機設定(`config.txt` ‖ `distroconfig.txt` 的 sha256);空 = 不檢查。比對**目標槽** boot 分割上的檔(F56) | 不符 → reason 5(需重燒卡) |
| 9 | boot 成員總大小(bytes) | 解析上限、RAM 預算 |

- `update-manifest` key 5(`bstr`)= CBOR `[E_i, S]` 的編碼;manifest 的 1–4、6 必須等於 S 的同號欄位,否則 reason 11。
- **撤銷**:image 內建 `/usr/share/batman/release-min-serial`;serial 小於它的背書被拒。K<sub>i</sub> 外流 → R 背書 K<sub>i+1</sub>,發一版 `min-serial = i+1`。**界線**:沒更新到那版的節點仍接受 K<sub>i</sub>(無線上撤銷);經 key 6 降到較舊版本後,舊 image 的 `min-serial` 較低,已撤銷的 K 又會被接受。只有 R 出事才要重燒。
解析失敗(例如 `1.5.14-wsl`,少了 build N;`+` 之後的 build metadata 一律忽略)→ reason 11

#### 3.7.2 build / 發行端

- `scripts/build-ab-payload.sh`:tar 順序改為 **`SHA256SUMS metadata boot root.squashfs`**(F27);`metadata` 加 `release=<BATMAN_VERSION>`(`version=` 時間戳不動)。sysupgrade 路徑以名字取成員,與順序無關(F57)。**界線**:P3 之前建的 payload 不能經 app 安裝(Go 解析要求 `SHA256SUMS` 是第一個成員),包括經 key 6 降到 P3 之前的版本 → 只能 ssh sysupgrade。
- `scripts/release-sign.sh <payload>`:讀 `SHA256SUMS` / `metadata` / 開機設定清單,組 S,用 YubiKey 簽,與 `release-keys/relkey-<i>.cbor` 寫成 `<payload>.sig.cbor`;`release-endorse.sh`(離線用 R,換鑰匙時)。發行流程加這兩步與轉賣工具清單(§3.9)。

#### 3.7.3 `batman-slot` 的新 CLI 動詞(兩板共用)

| 動詞 | 做什麼 |
|---|---|
| `write <dir>` | 現在 `apply` 的 precheck → begin_write → dd(stdin)→ 複製 boot 檔 → 讀回驗證(`:592-714`),**不 arm**;成功時在目標槽 boot 分割寫 `BATMAN-VERIFIED` = sha256(`SHA256SUMS`) |
| `arm <sha>` | 先重跑完整 `node_checks`、確認無 `BATMAN-BAD`、cmdline 正確、`BATMAN-VERIFIED` = sha、`bootcfg-sum` 仍在 key 8 清單裡;再 arm + 讀回(`:716-738`) |
| `disarm` | 清掉 tryboot 旗標(包現在的內部 `disarm_tryboot`,F64) |
| `bootinfo <A\|B>`(v7.3 取代 `bootcfg-sum`) | 在 `batman-slot.lock` 內唯讀掛該槽 boot 分割,印 `verified=`、`bootcfg=`(key 8 用)與 `distroconfig.txt`;helper 不再自己掛 FAT(§12.5.1) |
| `apply`(既有) | = `write` + `arm`;sysupgrade 路徑行為不變 |

共同修改:**`begin_write` 一開始先刪目標槽的 `BATMAN-VERIFIED`**(所有寫者都經過它,含 sysupgrade);**複製 boot 檔 = `SHA256SUMS` 列出的 ∩ 現行類別白名單,並明確拒絕 `autoboot.txt` / `config.txt` / `distroconfig.txt` / `cmdline.txt` / `bootcode.bin` / `BATMAN-*`**(§12.5.4;sysupgrade 也受益)。結束碼見 §12.5.2。重開用既有的 `batman-slot reboot committed`(tryboot 旗標在時它自己走一般重開,F64)。

#### 3.7.4 節點端動詞與狀態

| 動詞 | 做什麼 | 拒絕 |
|---|---|---|
| `update.check {1: manifest}` | 1. 驗 E(R;prov_test 另加 T)、serial ≥ min、S(K)— **先驗簽,通過前不寫任何東西**;2. 若 p5 stale 只因 P3 新 PRESERVE key → `--save` 一次(§3.3);3. `batman-slot precheck-node`(試用中、p5 新鮮度、`.txn`、fw override);4. board、版本規則、key 7、key 8(`batman-slot bootcfg-sum`,鎖被佔 → `E_BUSY`);5. RAM 預算;6. 通過 → 寫 **pending**(`/tmp/run/batman/update/pending`,helper RunDir root 0700,`{S, boot_id, 到期 = uptime + 30 min}`);內容相同的 pending 已在 → 不重寫。**helper 端額度**:全域 1 / 10 s(provd 的每連線額度之外,A5-m4) | `{1: false, 2: reason, 3: RAM}`:1 試用中、2 p5 未 seed、3 板子、4 中間版本、5 開機設定、6 降級、8 RAM、11 簽章 / 版本解析、12 `.txn`、17 p5 stale;worker 在跑或上傳窗開著 → `E_BUSY` |
| `update.prepare {1: sha}` | sha = pending 的 key 4(綁擁有者同意的版本);呼叫者 = 上傳窗擁有者;上傳檔存在且大小 = key 3;啟動 worker,立刻回 phase 2;關上傳窗;**pending 到期延到 worker 結束 + 30 分**(B5-m4) | 無 pending / sha 不符 / 上傳不完整 → reason 15 |
| `update.apply {1: sha}` | worker 已寫完(phase 3)且 sha 相同;p6 已掛載(否則 `E_STORAGE`,不 arm)→ 寫 **update-last**(p6 `/opt/batdata/state/update-last`,root 0600,格式見 §5.3;v7.3 起 `update.prepare` 先寫嘗試紀錄,§12.5.5)`armed: false` → `batman-slot arm <sha> <key8 清單檔>`(清單檔在 helper 的 0700 update 目錄)→ rc 0 時改寫 `armed: true` → 回應後 2 s,**緊接在** `batman-slot reboot committed` 之前改寫 `rebooting: true`。**update-last 只有 helper 的更新序列寫(prepare / worker 結束 / apply,§12.5.5)** | reason 15;arm 失敗 → reason 11 / 12 / 1 / 5 / 17 |
| `update.status`(ro) | 見下 | — |

**狀態判讀**(helper 每次啟動只讀 update-last、不刪,F42;以**槽**判讀)— **v7.3:由 §12.5.5 的有序表取代,下表只留作歷程**:

| 情況 | phase |
|---|---|
| 上傳窗開著 | 1(百分比 = 已收 / key 3) |
| worker 在跑 | 2(百分比) |
| pending 有效(同 boot_id、未到期)且目標槽 `BATMAN-VERIFIED` = pending sha | 3(helper 重啟後也能重建) |
| **helper 記憶體裡本次開機的嘗試結果**(worker 失敗:phase 0 + `3: reason`)— 有就優先 | 0 + reason |
| update-last:目前槽 = `to_slot` 且 `is-trial` | 4 |
| 目前槽 = `to_slot` 且已 commit | 5 |
| 目前槽 = `from_slot`、`armed: true`、boot_id ≠ `apply_boot_id`、`bad-slot` 標記指向 `to_slot` **且與 `bad_slot_at_apply` 不同**(autocommit 這次退回的證據,A5-m6) | 6 |
| 目前槽 = `from_slot`、`rebooting: true`、boot_id ≠ `apply_boot_id`、沒有新的 `bad-slot` | 6 + `3: 18`(新版沒有開機成功,韌體回到預設槽)。界線:在寫 `rebooting` 到真正重開之間的毫秒級斷電也會落到這裡 |
| boot_id = `apply_boot_id`(apply 之後還沒重開,helper 中途掛了;不論 `armed` 有沒有寫成)| helper 啟動時一律 `batman-slot disarm`,報 3(避免 tryboot 旗標留著,下一次無關的重開才進試用,B6) |
| 目前槽 = `from_slot`、`armed` 為 false 或 `rebooting` 為 false(arm 前、或 arm 後重開前斷電,tryboot 旗標沒留下) | 0(「沒有更新」— app 不寫成「試用失敗」) |
| 目前槽的版本 ≠ update-last 記的 `from_version` / `to_version`(之後操作員換過槽) | 0(update-last 過期) |

update-last 保留到下一次 `update.apply` 覆寫。pending 在 tmpfs:重開即消失。**判讀所需的槽資訊**(`BATMAN-VERIFIED`、`is-trial`)由 helper 在啟動時與每次 `write` / `arm` / `disarm` 之後快取,`update.status`(ro)只讀快取。

**RAM 預算**:`MemAvailable` − 64 MiB ≥ payload 大小 + boot 總大小(key 9);上傳目錄的 tmpfs `size=` 也要 ≥ payload 大小(否則 reason 8)。

#### 3.7.5 worker:驗證、寫入(不 arm)

1. **先**以 `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` 開上傳檔(§3.8.2;`O_NONBLOCK` 防 FIFO 卡住),**之後**才關上傳窗(順序反過來,helper 的窗外刪檔可能先刪掉它 → 誤報 reason 15);fstat:regular、link count 1、uid 471、大小 = key 3,通過後清掉 `O_NONBLOCK`;之後只用這個 fd。`updating` 旗標從開檔起為真。
2. **Go `compress/gzip` + `archive/tar` 白名單解析**(不呼叫 busybox tar;root 不在驗證前解析外來的 tar,F47):第 1 個成員必須是 `SHA256SUMS`、第 2 個 `metadata`(都 ≤ 64 KiB、regular);sha256(`SHA256SUMS`)= key 4,否則 reason 11、停。
3. `metadata` 的 `board=` / `release=` = S 的 2 / 1。
4. 之後的成員:目錄成員只允許 `boot/`、`boot/overlays/`(忽略 mode / owner,不在檔案系統建立);檔案名字必須符合 `^boot/[A-Za-z0-9._-]+$` 或 `^boot/overlays/[A-Za-z0-9._-]+$` 且**列在 `SHA256SUMS`**,或是最後的 `root.squashfs`(tar header 大小 = `metadata size=` 且 ≤ 目標槽大小);只收 regular file;重複、link、目錄穿越、沒列名 → reason 11、停;boot 成員累計 ≤ key 9,以 `O_CREAT|O_EXCL|O_NOFOLLOW` 寫進 helper 新建的 0700 目錄(`/tmp/run/batman/update/boot/`)。
5. `root.squashfs`:Go 從同一個 fd 串流給 `batman-slot write <dir>` 的 stdin。
6. 結束(成功或失敗):worker 刪上傳檔與解出目錄;失敗原因依 `batman-slot` 的失敗類別對應(試用中 1、`.txn` 12、p5 stale 17、內容 / 讀回不符 11),記在 helper 記憶體(B5-m6)。**期限**(F72):`batman-slot write` 600 s(SD 卡寫 + 讀回約 126 MB)、`arm` 60 s、`bootcfg-sum` 30 s;逾時 → 槽保持 BAD(begin_write)、phase 0 + reason 11、`batman-slot.lock` 由它既有的 pid 檢查回收(`batman-slot:78-95`)。
7. **上傳檔被 provd 中途改寫**:helper 用的 `SHA256SUMS` 是步驟 2 驗過的那份;rootfs 與每個 boot 檔的讀回都以它為準 → 不符就 `invalidate_slot`、不 arm(F19)。`metadata size=` 只是串流長度提示(未簽):讀回仍以 `SHA256SUMS` 為準,fail-closed。

**界線**:prepare 開始寫之後,另一槽(原本的退路)已被覆寫;放棄更新 = 回不到「兩槽都可用」,只能再更新一次(A/B 寫入的本質)。app 在 prepare 前提示。

#### 3.7.6 autocommit(D6、D16)

- **BLE 無線電**(`batman-autocommit:506-511`):health 行的 `boot_id` = 本次開機、`ts`(uptime)距今 ≤ 60 s,否則視同不健康;**仍只 WARN**(P-U5)。
- **新:`health_ok` 加兩項(會讓試用退回)**:
  - (a) helper 的 procd instance 在跑(`ubus call service list` 的 `batman-provhelper` running)。
  - (b) **provd 本次開機至少一次連續穩定 ≥ 60 s**:helper 看到 **provd 行程的任一條連線**(ctl / ro / ops 從憑證分不出來,只要是 provd 這個行程)連續存在 60 s 時寫 `$RUNDIR/provd-stable`(root,內容 = boot_id);autocommit 讀它,boot_id = 本次開機才算。**辨識 provd**(F11:procd 的 instance pid 是 ujail,provd 是它的子行程):SO_PEERCRED 的 peer pid 的 `PPid`(`/proc/<pid>/status`)= `ubus call service list` 的 `batman-provd` instance pid,**且** uid = 471,**且** `readlink /proc/<pid>/exe` = `/usr/bin/batman-provd`(provclient 的 PPid 不是 ujail → 不算)。
  - **`batman-provd` 被操作員停用**(`/etc/init.d/batman-provd enabled` 為 false)→ (b) 不要求,只 WARN(否則停用 provd 的節點永遠升不上去,B5-m8)。
  - provd 在 bluetoothd 不在時不會結束(F67)→ BT UART 卡住不會讓 (b) 失敗;autocommit 的 MIN_WINDOW 300 s 涵蓋 60 s(F67)。之後 provd 被路人弄當不影響(檔已寫);路人在試用頭幾分鐘一直弄當 provd → 退回 = 更新失敗,不是節點壞掉。

### 3.8 HTTP 通道與上傳

#### 3.8.1 provd 的 HTTP 伺服器

- **與 BLE 隔離**:HTTP session 池 2 槽(與 BLE 分開);交握額度 10 / 分(只算 HTTP);HTTP 的 fake path 只佔 HTTP 的槽;**撤 BLE 廣播只看 BLE 的 link / session**(`bluez.go:772` 改成只數 BLE)。
- **來源只收手機 AP 的 client(D15),由防火牆在 L2 擋**:
  - 規則(兩張表,同一個 include 檔):
    - `bridge batman_http`,`input` hook:`iifname "phy*" meta mark set meta mark | 0x01000000` — **只替從 `phy*` port(手機 AP)進來的 frame 打一個專屬 bit**(OR,不動其他 bit;02 / 04 沒有其他 fwmark 使用者,F75;tailscale 若啟用用的是 0x00ff0000 範圍,不重疊)。
    - `inet batman_http_in`,`input` hook priority −10(在 fw4 之前):`tcp dport 8095 meta mark & 0x01000000 == 0 drop`(IPv4 / IPv6)。
    - 這樣在 **IP 層**判斷:沒有從手機 AP port 進來的封包(mesh `bat0`、`eth0`、docker0 / br-ots 的 veth、**VLAN 封裝後被剝標籤的 frame**(F76)、`wlh0`、本機 lo)都到不了 8095 — fail-closed。v6 在 bridge 層比 `tcp dport`,看不到 VLAN 封裝裡的 L4(A6-M1)。
    - nft 只認結尾的 `*`(F69),所以用前綴 `phy`;**前提由 helper 驗證**:列出**所有** bridge 的 port,每一個 `phy*` 的 port 都必須是 `network.wireless status` 裡 `default_radio0` 這個 section 的 iface(ifname 也要符合 `phy*`);有任何例外 → 不給 `http.2`(fail-closed)。不需要 helper 維護 set。
    - **02 實測**(F75):這組規則可載入、mesh 來源與 lo 被丟、刪表後完全回到原狀。⚠️ 未測:AP 上的 client 通過、VLAN 臂(D22,§9-4)。
  - **載入者 = fw4**(F59):`/usr/share/nftables.d/ruleset-post/batman-http.nft` 隨 image 安裝,fw4 每次 start / reload 都會 include。兩張表都用 fw4 的寫法**先刪再建**(`table X` / `delete table X` / `table X { … }`)→ reload 不會重複規則(F70)。**這個檔一有錯,fw4 整份交易失敗、開機後整台沒有防火牆**(F70)→ 兩道關:(1) rc 驗收在 bench 節點跑 `fw4 print \| nft -c -f -`(兩板);(2) 常規全套每次開機後斷言 `inet fw4`、`bridge batman_http`、`inet batman_http_in` 都在(§8)。操作員把 `firewall.@defaults[0].auto_includes` 設成 0 → include 不載入 → helper 看不到表 → 不給 `http.2`(fail-closed)。`firewall stop`(`fw4 flush`)會刪掉它們 = 操作員動作。
  - **表不在 = 不聽(fail-closed)**:helper 背景每 4 s 確認兩張表、兩條規則都在,並做上面的 `phy*` 前提檢查;結果放快取,poll 只讀快取(唯讀路徑不跑子程序);快取超過 10 s → 當作不在。**在才給 `http.2`**;provd 沒有 `http.2`、或 poll 失敗 / 過期(helper 掛了、ERate)→ 不 bind,已 bind 的關掉 — 最壞 **≤ 8 s**(4 s 檢查 + 4 s poll)。這對備援與上傳窗都成立。
  - 不需要 `kmod-nft-bridge`(F60、F75)。04 上 `br_netfilter` 已由 docker 載入(`bridge-nf-call-iptables=1`)— 本設計不依賴它,也不受它影響(判斷在 inet input,本機收的封包都會經過)。
  - 本機 lo 上的行程也被丟(沒有標記,F75)→ v6 列的「lo 可佔 HTTP 槽」界線拿掉。provd 只 bind `http.2` 給的 `br-ahwlan` 位址。
- `net/http`:`ReadHeaderTimeout` 5 s、非上傳 `ReadTimeout` 15 s、`IdleTimeout` 30 s、`MaxHeaderBytes` 4 KiB;同時連線上限 8(F43);`/session`、`/msg` body ≤ 9 KiB(`max_msg` 8192 + 封裝)。上傳最低速率 **256 KiB/s**(30 s 平均;126 MB 約 8 分鐘,在 15 分鐘窗與 30 分鐘 pending 之內),低於就關。
- 端點(協定 §4.2):`POST /batman/v1/session`、`POST /batman/v1/msg`;完整 §3 Noise;角色依 §3.1.2。多塊回應以多次 `POST /batman/v1/msg`(空 body = 取下一塊)取回。**回應遺失 = 這個 session 中止**(沒有冪等快取,重送的 Noise 訊息會 AEAD 失敗):app 重新交握、`auth/owner`,再依 §5.2 重讀狀態;協定 §4.2 同步改。
- **什麼時候聽**:
  - **備援**(D6):provd 自己的 `HealthOK()`(F45)連續 5 分鐘(uptime)為 false → 開;連續 1 分鐘為 true → 不收新連線,已建立的 HTTP session 繼續到結束或 10 分鐘。之後的 EMCON(checklist)若刻意關 BLE,也必須關掉備援。
  - **上傳窗**:`bulk.open` 後 15 分鐘(uptime),或到 `update.prepare` 開始 / `bulk.close`;窗關了不收新連線,已建立的 session 保留到 worker 結束或閒置 10 分鐘。
  - 都不是,或沒有 `http.2` → 不 bind。
- 埠 8095:04 未被佔用。

#### 3.8.2 上傳窗(`bulk.open` / `bulk.close`)

- `bulk.open`(owner-op,purpose 0)前提:有 pending;手機 AP 開著(`network.wireless status` 的 radio0 up 且有 AP iface)否則 reason 16(D13,不自動開;剛認領節點被 keyguard 關著的 AP 由 §3.3 的配對打開);**沒有另一位擁有者的上傳窗**(有 → `E_BUSY`);同一位擁有者重送 = 延長同一個窗。`owner/remove` 會一併清掉該擁有者的上傳窗與 pending(B5-m11)。
- helper 記 `{owner_key_id, 到期}`;回 `{1: 手機 AP 的 ssid, 2: 手機 AP 的 passphrase, 3: 節點在 ahwlan 的 IPv4, 4: 8095, 5: 900}`。key 2 是這台 AP 的現行密碼(擁有者本來就有權知道;配對後 app 已知道,仍回給沒有配對的手機),**不是一次性 PSK**;重送 `bulk/open` = 延長同一個窗、回同樣的值。
- **上傳**:`PUT /batman/v1/bulk/0`,header `X-Batman-Session` = 一個在 HTTP 上建立、`auth/owner` 後角色擁有者、owner_key_id = 上傳窗擁有者的 session;來源 IP = 建立該 session 的來源 IP;`Content-Length` = `http.5`。`X-Batman-Session` 是明文 bearer:同一台 AP 上知道 AP 密碼的人可以解出來並搶先 PUT — 只造成 DoS(內容由簽章 + 讀回把關)→ 誠實界線。
- **寫入位置**:`/tmp/run/batman-provd-bulk/payload`。專屬 tmpfs,由 `batman-provd` init(root)在啟動 jail 前掛上:`nodev,nosuid,noexec`、mode 0700、provd:provd、`size=` = **2 × 本板目前的 release payload 大小**(實際限制交給 RAM 預算,§3.7.4);init 先檢查是否已掛載(不疊掛);rw 掛進 jail(provd 唯一的 rw 掛載)。helper 在沒有上傳窗時,每個 poll 週期看到上傳檔就刪 — **但 provd 若還開著那個檔的 fd,刪除不會釋放空間**:被入侵的 provd 可以一直佔用到 `size=`(A6-m2)→ 誠實界線;測試量的是 tmpfs 的用量,不是檔案在不在;3A+ 與 2 GB TAK 節點列 checklist。
- **上傳完成**:provd 收完回 HTTP 200;app 接著 `update/prepare`(BLE 或同一個 HTTP session);prepare 自己檢查大小(§3.7.4)。
- **刪除上傳檔的唯一負責者 = helper**:worker 結束、`bulk.close`、窗到期(且沒有 worker)、helper 啟動時(若 `batman-slot.lock` 的持有者還活著就不刪解出目錄)。helper 在上傳中重啟 → 窗消失、檔被刪(provd 寫到已 unlink 的 inode,關檔時釋放)→ fail-closed,擁有者重開窗再傳。

### 3.9 轉賣工具

照 `254-stage1-impl.md` §4.5(`:262-300`)實作 `scripts/transfer-flash.ps1`(Windows,主要)與 `scripts/transfer-flash.sh`(Linux),**不改契約**:內建發行 image 清單、只收讀卡機上的卡、全卡清零、寫入、讀回頭尾、≥ 64 個隨機 1 MiB 區塊在 image 之後全 0、`--test-target-file`。發行流程加「更新清單」一步(與 §3.7.2 同一步)。CM4(D18):開發用 Lite(本工具適用);量產 eMMC 的重燒路徑(rpiboot)量產前做(checklist)。

### 3.10 LuCI reset 文字(firmware)與說明頁文字

- firmware patch `flash.js`:`Perform reset` 的說明改為「重新套用設定(不清除擁有者與資料)」;動作不變(`firstboot -r -y` 只清本槽 overlay,開機時 96 從 p5 還原 — `254-stage1-impl.md:63` 的 F22 唯讀實測;H4 加實機測試)。`rc.button/reset` 已在 P1 改(F23)。
- 賣方 / 買方 / 遺失手機說明頁的文字(stage1-impl `:282-292`)收進 `docs/`,供 app 引用。

### 3.11 App 需求(U9 開工時照做;節點端只負責如實回報)

1. **更新前**:手機 Wi-Fi 開著(不能代開 → 帶到系統設定);手機連得到 `bulk/open` 回的 IP(連不上 → 用回傳的 SSID / 密碼請使用者加入);節點手機 AP 關著(reason 16)→「節點 Wi-Fi 關閉中,請在可開 Wi-Fi 時(例如維護)再更新」。
2. **上傳只能連這台節點的 AP**:經 mesh 轉來的連線在防火牆就被丟(TCP 連不上);app 顯示「請直接連這台節點的 Wi-Fi」。
3. **HTTP socket 綁在 Wi-Fi 網路上**(Android `bindProcessToNetwork` / iOS 對應機制),否則 AP 沒有對外網路時系統會改走行動網路。
4. `status` 的 `tenants` 顯示節點跑著 TAK server → apply 前警告「重開約 2 分鐘,全隊 TAK 中斷」並再確認。
5. prepare 前提示「開始寫入後,放棄就回不到原本的退路」;`update.status` 0 的文字是「沒有更新」,6 才是「新版不健康,已退回」。
6. **配對**(D14):認領後以 `settings/set` key 20(經 BLE)設這台節點的 SSID(中性、不含個人資料)與 ≥ 20 字隨機密碼(字元集 `[A-Za-z0-9._~+=,:@%^*-]`),存在手機;SSID 不隱藏。剛認領的節點 AP 被 keyguard 關著,配對同時打開它。之後若 `settings.get` 的 SSID 與手機記的不同 → 提示重新配對。
7. **國家**(D9):建網時寫進 `net_config`;節點入網前先以 `settings/set` key 2 改成網路的國家,否則入網被拒(reason 14)。
8. **遺失手機**(D17):`owner/remove` 後提示以 key 20 換這台的 AP 密碼;認領後建議加一位備用擁有者(只有一位擁有者時手機遺失只能重燒,L59)。
9. **節點忙碌**:`settings/set` 或 `network/*` 進行中,新連線最多等約 4 分鐘(230 s 預算);顯示「節點忙碌」。
10. 回應遺失 → 重新交握並以 `settings/get` / `update/status` 重讀(§5.2)。
11. 完全靜默(EMCON)時連 BLE 也不連 — app 模式,不在 P3。

## 4. 擁有權

| 資源 | 寫者 | 唯讀 / 其他 |
|---|---|---|
| p5 prov 紀錄 | helper `commit`(P1/P2) | provd 經 helper |
| `system.hostname` | helper `settings.set` key 1;openmanetd(F32)、操作員、`99-halow-identity`(新卡)— 不同時發生的設定動作,最後寫的贏 | config-save、halow-status、helper 設定快取 |
| `wireless.radio1.country` | `halow-setkey --country`(helper 的 key 2 經由它,未入網時);openmanetd(F66)、操作員。**入網不寫國家**(D9) | config-save、`netJoin`(只比對)、helper 設定快取 |
| `wireless.default_radio0.ssid` / `.key` | `halow-setkey --ap --ap-ssid --ap-section`(helper 的 key 20 經由它);`99-halow-identity`(新卡寫 ssid);helper `--apply-state --firstboot` / 99zz(unclaimed 時寫 placeholder key);openmanetd(F50);操作員 | config-save、hostapd、helper 設定快取 |
| `wireless.default_radio0.disabled` + `/etc/halow-keyguard.blocked` | keyguard(開機:placeholder 時設 1,key 已設好時解除,F49);`halow-setkey`(執行期解除;`--rollback` 時恢復封鎖) | netifd |
| `halow-setkey.lock` | `halow-setkey`(chanfix、操作員、helper 的呼叫都經由它) | — |
| `.txn` | helper(P1b txn,格式不變) | config-save(看存在) |
| nft 表 `bridge batman_http`、`inet batman_http_in` | **fw4**(include `ruleset-post/batman-http.nft`,每次 start / reload 先刪再建);`fw4 flush`(`firewall stop`)= 操作員動作會刪掉 | kernel;helper(只檢查存在) |
| fwmark bit `0x01000000`(bit 24) | **只有** `bridge batman_http` 的規則設它(其他 port 的 frame 先清掉這個 bit,附錄 D-8);保留給 P3,lint 檢查 repo 裡沒有別人用 | `inet batman_http_in`(只讀) |
| HTTP 上傳窗、`http` 欄位 | helper(經 poll 告訴 provd) | provd |
| HTTP 備援開關 | provd(自己的 `HealthOK`) | — |
| `/tmp/run/batman-provd-bulk`(tmpfs)| `batman-provd` init 掛載;provd 寫上傳檔;**helper 刪** | helper worker 讀 fd |
| `/tmp/run/batman/update/`(pending、解出的 boot 檔)、`/tmp/run/batman/diag/`、helper 的記憶體快取 | helper | — |
| `$RUNDIR/provd-stable` | helper | autocommit |
| p6 `state/update-last` | helper 的更新序列(`update.prepare`、worker 結束、`update.apply`;§12.5.5) | helper |
| p6 `state/prov-state`(既有) | helper(既有) | `/cgi-bin/bundle`(新讀者) |
| 目標槽(rootfs、boot、`BATMAN-VERIFIED`、`BATMAN-BAD`)、tryboot 旗標 | `batman-slot`(`write` / `arm` / `disarm` / `apply`),`batman-slot.lock` 互斥(F35):helper worker 與 sysupgrade 不會同時寫 | autocommit、`bootcfg-sum`(鎖內) |
| `release-root.pub`、`release-min-serial` | build(image 內) | helper |
| provd ↔ helper 的 ctl / ro / ops 連線 | provd 開 | helper 限速 |

**清理表**:

| 東西 | 正常結束 | 失敗 / 到期 | helper 重啟 | provd 重啟 | 開機 |
|---|---|---|---|---|---|
| 上傳檔 | worker 用完刪 | helper 刪(`bulk.close`、窗到期且沒有 worker、prepare 發現不符) | 啟動時刪 | 不刪(helper 是唯一刪除者;init 不疊掛) | tmpfs 消失 |
| 解出的 boot 檔 | worker 刪 | worker 刪 | 啟動時刪(`batman-slot.lock` 持有者活著就不刪) | — | tmpfs 消失 |
| pending | 被下一個 check 覆寫或到期 | 到期(uptime 30 分) | 讀回(同 boot_id 才有效) | — | 消失 |
| diag bundle | 10 分鐘到期 | 同 | 啟動時清空 | 不影響(純到期) | 消失 |
| update-last | 下一次 `update.apply` 覆寫 | 同 | 保留 | — | 保留(p6) |
| `provd-stable` | — | — | 保留(同 boot_id 才有效) | 保留 | 消失(RunDir) |

## 5. 契約

### 5.1 動詞 × 拒絕 → 線上碼

| 動詞 | 情況 | 線上 |
|---|---|---|
| 所有 owner-op | owner-op 缺 / 錯 | `E_FORBIDDEN` |
| 所有 state-changing | 試用中、verdict 不明、`.txn` 未完成(P1b 既有) | P1b 既有對應 |
| `settings.set`、`update.check`、`network/*` | worker 在跑或上傳窗開著(§3.1.7) | `E_BUSY` |
| `bulk.open` | 另一位擁有者的上傳窗開著 | `E_BUSY`(同一位擁有者重送 = 延長,不是錯誤) |
| `update.prepare` | worker 已在跑 | `E_BUSY`(上傳窗開著時由窗擁有者呼叫 = 正常流程) |
| `update.check` | `bootcfg-sum` 拿不到 `batman-slot.lock` | `E_BUSY` |
| `settings.set` | 值不合法 / 一次多項 / 文字 key / setkey 套用失敗已還原 | `E_REJECTED{2: 13}` |
| `settings.set` | `--save` 失敗(已還原) | `E_STORAGE` |
| `settings.set` key 1 | U5 之前 | `E_UNSUPPORTED`(今天的 `rename-pending`) |
| `settings.set` key 1 / 2 / 20 | `/tmp/.uci/system`(key 1)或 `/tmp/.uci/wireless`(key 2、20)有別人的暫存 | `E_BUSY`;`status` key 15 回報 `uci_staged: [packages]`,app 提示「節點有未提交的設定,請重開或由操作員處理」(否則 app 沒有出路,A6-m7) |
| `settings.set` key 2 | 已入網 | `E_REJECTED{2: 14}` |
| `settings.set` key 2 / 20 | legacy 節點(D20) | `E_UNSUPPORTED{1: typ, 2: 20}` |
| `settings.set` key 20 | 經 HTTP | `E_UNSUPPORTED{1: typ, 2: 19}` |
| `settings.set` key 10–13 | — | `E_UNSUPPORTED{1: typ, 2: 7}` |
| `network/join` / `network/update` | 國家不符(§3.3) | `E_REJECTED{2: 14}` |
| `status` scope 1 | — | `E_UNSUPPORTED{1: typ, 2: 7}` |
| `update.check` | 1 / 2 / 3 / 4 / 5 / 6 / 8 / 11 / 12 / 17 | **ok 回應** `{1: false, 2: reason, 3: RAM}` |
| `update.prepare` / `apply` | 前提不成立 / sha 不符 / 上傳不完整 | `E_REJECTED{2: 15}` |
| `update.prepare` 的 worker | 失敗 | `update.status` = phase 0 + `3: 1 / 11 / 12 / 17`(依失敗類別) |
| `update.apply` | arm 失敗 | `E_REJECTED{2: 11 / 12 / 1 / 5 / 17}` |
| `bulk.open` | 無 pending | `E_REJECTED{2: 15}` |
| `bulk.open` | 手機 AP 關著 | `E_REJECTED{2: 16}` |
| `diag.read` | handle 過期 / 不屬於這個 session | `E_REJECTED{2: 15}` |
| HTTP 交握 | NX / psk_replay | 連線關閉(與 fake path 等長回應後關) |
| HTTP 連線 | 不是從手機 AP 的 bridge port 進來 | 防火牆丟棄(TCP 連不上,沒有任何回應) |

### 5.2 重送語意(沒有冪等快取;HTTP 回應遺失 = session 中止,先重新交握)

| 動詞 | 回應遺失後重送 | app 的處理 |
|---|---|---|
| `owner/add` | 再送 = 輪替該擁有者 tag key(新值) | 以最後一次的 tag key 為準 |
| `owner/remove` | 第二次 `E_FORBIDDEN`(no such owner) | 當成功 |
| `settings/set` | 與現值相同 → 不 reload;p5 stale 時執行 `--save`;outcome unknown(逾時)→ 以 `settings/get` 重讀 | 以 `settings/get` 重讀 |
| `update/check` | 內容相同的 pending 不重寫 | 冪等 |
| `update/prepare` | worker 已在跑 → `E_BUSY`;已寫完 → `E_REJECTED{15}` | 先讀 `update/status` |
| `update/apply` | 節點可能已重開 | 讀 `update/status` |
| `bulk/open` | 已開著 → 延長同一個窗、回同樣的值 | 用回應 |
| `diag/bundle` | 同 session 的新 bundle 取代舊的 | — |

### 5.3 介面

| 介面 | 寫 → 讀 | 格式 / 有效 | 缺 / 舊 / 壞 | 誰寫得到 |
|---|---|---|---|---|
| `update-manifest` + `[E, S]` | app → provd → helper | §3.7.1 | 驗不過 → reason 11,fail-closed | 任何擁有者 session;簽章才是權威 |
| pending | helper → helper | CBOR,root 0700 目錄,綁 boot_id、uptime 30 分 | 缺 / 過期 / 壞 → 當作沒有 | root |
| update-last(p6) | helper → helper | CBOR `{0: format 1, sha, from_slot, from_version, to_slot, to_version, attempt_boot_id, written, apply_boot_id, bad_slot_at_apply, armed, rebooting}`(§12.5.5) | 缺 / 壞 / 未知 format / 版本對不上 → phase 0 | root |
| 上傳檔 | provd → helper | 大小 = key 3 | §3.7.5 步驟 1–4 | provd(不受信任) |
| `BATMAN-VERIFIED` | `batman-slot write` → `arm` | 一行 sha256 hex | 缺 / 不符 → arm 拒絕 | root |
| `batman-slot write / arm / disarm / bootinfo` | helper → batman-slot | §3.7.3 | rc 依 §12.5.2 對應 | root |
| poll 的 `http` 欄位 | helper → provd | §2 | 缺 → 不聽(fail-closed) | helper |
| nft 表 `bridge batman_http`、`inet batman_http_in` | fw4 → kernel;helper 檢查 | §3.8.1 | 任一缺 → helper 不給 `http.2` → 不聽 | root |
| `$RUNDIR/provd-stable` | helper → autocommit | 一行 boot_id | 缺 / 不是本次開機 → 試用不健康 | root |
| HTTP `/batman/v1/*` | app → provd | 協定 §4.2 + §3.8 | 交握失敗 → 關;超額 → 關 | 手機 AP 上的 client(防火牆) |
| `halow-setkey` 新旗標 `--ap -`(stdin)、`--ap-ssid`、`--ap-section`、`--country`、`--rollback`、`--lockwait` | helper → setkey | §3.3 | rc ≠ 0 → §5.1 | root |
| joinwatch `verdict_code()` → `halow-status json` `join.reason_code` | joinwatch → halow-status → helper | uint | 缺 → code 0 | image |
| p6 `prov-state`(既有) | helper → CGI | `<boot_id> helper <state> …` | 缺 / boot_id 不符 / 其他值 → 403 | root |
| helper 錯誤回覆 `reason` | helper → provd | 選填 uint | 缺 → 照 P2 對應 | helper |

## 6. 生命週期矩陣

| 路徑 | 今天 | 改後 | 測試(H4) |
|---|---|---|---|
| 首次安裝 / 第一次開機 | P3 動詞 `E_UNSUPPORTED` | 可用;HTTP 不聽(BLE 健康、沒有上傳窗) | `prov-p3-routes-254` |
| 升級到 P3(ssh sysupgrade) | — | 已入網:下一個 joinwatch tick 存 p5;未入網:只因新 PRESERVE key 而 stale 時,helper 在非試用的開機時與每次 `update.check` 時 `--save` 一次(§3.3);`/cgi-bin/bundle` 變 403(release note) | `prov-update-254` 升級臂 |
| 啟動 / 正常停止 | — | provd 依 `http` 欄位與 `HealthOK` 決定 HTTP;停止 → HTTP 關,上傳檔由 helper 在窗到期或下次啟動時刪 | `prov-http-254` |
| 重開 | — | pending 消失;update-last 撐過並依 §3.7.4 判讀 | `prov-update-254` |
| 升級 / 回滾(app 路徑) | 只有 ssh sysupgrade | + app 路徑(簽章、白名單 tar);sysupgrade 不變(只複製列名的 boot 檔) | `prov-update-254` |
| 降級到沒有 P3 的版本 | — | 舊槽沒有 P3 動詞;`.txn` 格式不變;舊版整檔比對判 stale 直到它下一次 `--save` / `--on-join`;p5 多出的 ssid 行舊版 96 照樣套用;update-last 留在 p6 無人讀 | `prov-update-254` 回滾臂 |
| 降級再升級 | — | p5 的 ssid 可能被舊版拿掉 → SSID 回 hostname;app 提示重新配對 | 誠實界線 |
| provd crash / crash loop | — | HTTP 斷;上傳檔由 helper 刪;provd-stable 已寫就不受影響 | `prov-http-254` kill 臂 |
| helper crash | — | worker 中斷 → 槽保持 BAD(begin_write),不 arm;重啟時刪暫存;pending 同 boot_id 仍有效;arm 後未重開 → disarm | `prov-update-254` kill 臂 |
| helper 重啟時 setkey 子程序還在跑 | — | 子程序(另一個 process group,F72)拿著鎖自己跑完並自己 `--rollback`;helper 啟動後以設定快取的刷新取得結果;那一次請求對 app 是 outcome unknown → 重讀 | `prov-settings-254` |
| `settings.set` 中斷電 | — | setkey 在 commit 之後、persist 之前斷電 → live(overlay)是新值、p5 是舊值;一般重開時 96 不跑(F71),不會從 p5 覆寫 → 新值留著、p5 stale → 下一次 `--save`(on-join / 下一次 setkey / 同值的 `settings.set` / `update.check`)補上;與 P1 的 setkey 相同的已知界線 | 誠實界線 |
| 上傳中 helper 重啟 | — | 窗消失、檔被刪 → fail-closed,重開窗重傳 | `prov-upload-254` |
| 手機斷 Wi-Fi / 上傳中斷 | — | provd 關檔;prepare 大小不符 → reason 15;app 從頭重 PUT(§12.5.7) | `prov-upload-254` |
| 寫到一半斷電 / helper 重啟 / worker 被中止 | — | 槽 BAD;status 0 + reason 22(§12.5.5) | `prov-update-254` |
| 已寫入、未啟用(pending 到期) | — | status 0 + reason 23;若 from_slot 開不起來,#133 fallback 進這一槽會被 commit(§12.5.13) | 誠實界線 + Go 表測 |
| 同時 ssh sysupgrade | — | app `write` 在跑時 stage 1 rc 14 拒絕;`-F` 照舊可強制(§12.5.14) | `prov-update-254` |
| DEV → PROD 換信任 | — | 只能用 T 簽、內建 R 的過渡版,或 ssh / 重燒(§12.5.10) | #255 |
| 斷電 | — | prepare 中:槽 BAD、仍跑舊槽;apply 後:tryboot 一次性 | `prov-update-254` 斷電臂 |
| 換 IP(改名 / openmanetd) | — | helper 給新的 `http.2`,下一次 poll provd 換 bind | ⚠️ 待 U5 |
| 依賴重啟:bluetoothd / dbus | P2 | 不變;BLE 不健康 5 分鐘 → HTTP 備援開 | `prov-http-254` |
| 依賴重啟:hostapd / `wifi reload`(= `network reload`,F51) | — | 防火牆規則以 port 名前綴判斷,iface 重建後仍有效;上傳中的 reload 被 §3.1.7 擋 | `prov-http-254` |
| 依賴重啟:firewall reload / restart | — | fw4 重建 `batman_http`(檔案先刪再建兩張表,不重複) | `prov-http-254` |
| `ruleset-post` 檔載入失敗 | — | 整份 fw4 失敗、沒有防火牆(F70)→ rc 驗收的 `nft -c` 閘門與每次開機的斷言抓到;**`fw-badinclude` 接縫本身會讓那台 bench 節點那次開機沒有防火牆** → 只在非 DUT 節點、經使用者同意、斷開對外網路時跑;還原 = 移除接縫並重開 | `prov-fw-boot-254` |
| `firewall stop` | — | 表被刪 → helper 不給 `http.2` → provd ≤ 8 s 內不聽 | `prov-http-254` |
| 平台 bcm2711(Pi 4) | — | 實測 | 全部 |
| 平台 bcm2710(Pi 3) | — | `batman-slot`、config-save、setkey 兩板共用 → CI 沙箱(P-U14);`fw4 print \| nft -c` 閘門要真的 kernel → bcm2710 沒有節點可跑 → 只做 bcm2711,bcm2710 列誠實界線 | CI |
| 平台 CM4 | — | 開發 Lite / 量產 eMMC(D18);**必須是有無線的型號**;實測與 eMMC 重燒待 CM4 載板 | checklist |

## 7. 安全

**資產**:節點控制權(更新 = 任意程式碼)、擁有者 / 成員秘密、AP 帳密、診斷內容、可用性(BLE 管理通道、手機 AP、mesh 頻寬)。

| 行為者 | 威脅 | 擋法 | 負測試 |
|---|---|---|---|
| mesh 上任何人(F9) | 讓 BLE 失效、讓擁有者的 HTTP 建不起來、把 poll 擠到 ERate | HTTP 平常不聽;聽的時候防火牆只收手機 AP port;HTTP 與 BLE 的槽 / 額度分開;撤廣播只看 BLE;app 讀取走 ro | §8 `prov-http-254` 的 mesh 臂 |
| mesh 上任何人 | 認領 / 重取 | HTTP 不收 NX / psk_replay | `prov-http-254` |
| mesh 上任何人 | 下載 `/cgi-bin/bundle` | 只在 unclaimed / legacy + dev-open | `prov-bundle-gate-254` |
| 成員 / 遺失的手機 | 輪詢 `status` 卡住 p5 存檔 | 請求路徑不跑子程序;`--check` ≤ 1 / 120 s;額度 | `prov-status-diag-254` |
| 遺失 / 被偷的手機 | 用 PSK 或記住的 AP 密碼 | `owner/remove` 切 session、psk 失效;app 提示換 AP 密碼(D17) | `prov-owner-254` |
| 同 AP 上知道 AP 密碼的人 | 解出明文 `X-Batman-Session`、搶先 PUT | 只造成 DoS;內容由簽章 + 讀回把關;PUT 綁來源 IP | 誠實界線 |
| 被入侵的 provd | 改 payload、塞沒列名的 boot 檔、tar 穿越 | Go 白名單解析、先驗簽、只寫列名的檔、讀回以 helper 的 `SHA256SUMS` 為準 | `prov-update-254` 惡意 tar 臂 |
| 被入侵的 provd | 佔 RAM | 專屬 tmpfs `size=` 上限;窗外 helper 每個 poll 週期刪檔;3A+ 與 2 GB TAK 節點列 checklist | `prov-upload-254` |
| 被入侵的 provd | 偷換 pending 版本 | prepare / apply body 帶 sha,由 owner-op 綁擁有者同意的版本 | Go |
| 被入侵的 provd | 自己聽 HTTP | 本來就能(無 netns,> 1024 埠);沒有 PSK 解不開 session、拿不到 owner-op;8095 仍只收從手機 AP port 進來的封包(其他埠不在本規則範圍) | 誠實界線 |
| 本機非 root | 讀 AP 密碼 | `/etc/config/wireless`、hostapd conf 0644(F34,與現況相同) | 誠實界線 |
| 本機非 root | 從 cmdline 或 log 讀 AP 密碼 | passphrase 走 stdin(`--ap -`);不進 log | `prov-settings-254`(`/proc/*/cmdline`、logread、helper / provd log、診斷包都不含) |
| 本機行程(lo)、eth0 / docker0 的 VLAN 封裝 frame | 佔掉 HTTP 的 2 槽 | inet input 只收 `iifname br-ahwlan` 且帶「手機 AP port」標記的封包(F75、F76;有 CAP_NET_RAW 的行程可設 `SO_MARK`,所以加 iifname,§12.5.11) | `prov-http-254` 的 lo / `SO_MARK` / VLAN 臂 |
| 本機非特權行程 | 先佔住 8095 | provd bind 失敗經 `status` 回報;只造成 DoS(Noise 擋冒充) | 誠實界線 + `prov-http-254` |
| 下載來源被換掉(DEV) | 擁有者同意一份 T 簽的惡意 image | T 公開:DEV 的信任根 = app 拿 payload 的來源;DEV 只用於 bench(§12.5.10) | 誠實界線 |
| 實體奪取 | 換 rootfs 上的 `release-root.pub` | 沒有 secure boot 前擋不住 | 誠實界線 |
| 本機非 root | 搶建 `/tmp/run/batman-provd-bulk` | `/tmp/run` 只有 root 能建(F33);init 建前檢查 owner / 非 symlink / 是否已掛載 | tmp-trust allowlist + 測試 |
| 實體奪取(SD 卡) | 從 p5 讀 AP 密碼 → 連 AP → mesh LAN | p5 不加密(既有);AP key 早已在 PRESERVE,P3 加 SSID — **D14 是使用者決定的例外**(「秘密不進 p5」規則下明列);換卡後擁有者換密碼 | 誠實界線 |
| 供應鏈 / 我們自己的錯 | 簽了壞 image;K 外流 | min-serial;防降級;R 離線兩份;出貨鑰匙鏈 bench 測試 | `prov-update-254` bench 臂 |
| 有管理密碼的人 | ssh sysupgrade / LuCI / openmanetd local upgrade 與 `PerformFactoryReset`(未簽章) | 不擋(root 等同完全控制) | 誠實界線 |

**秘密**:AP passphrase 經 Noise、經 setkey 的 stdin;它本來就在 `/etc/config/wireless` 與 hostapd conf(0644,與今天相同)。K 在 YubiKey、R 離線。**失敗模式**:fail-closed(驗不過不寫、不 arm;HTTP 預設不聽;防火牆表不在就不聽;CGI 預設 403;設定失敗由 setkey 還原)。

## 8. 測試(H4 依此寫)

**負對照只用兩種做得出來的東西**(A4-M4):
- **基準**:wsl.22(P3 之前的 image)與 main 現行的腳本;
- **故障注入接縫**:P3 build 上一次關掉一道防線。**Go 端**的接縫用既有的 `seam` 套件(`seam/seam_provtest.go`,只編進 prov_test build);**shell 端**沿用 `batman-slot` 既有的 `/tmp/batman-fault.*`(root 擁有的旗標,`batman-slot:71-77`)— 這個機制**在所有 image 都在**(與現況相同,只有 root 能觸發),所以 release gate 不斷言 shell 接縫不存在,只斷言 Go 接縫不在 release build。

| 接縫 | 關掉什麼 |
|---|---|
| `http-nofw` | helper 不檢查 nft 表 / `phy*` 前提就給 `http.2` |
| `fw-badinclude` | 安裝一個故意錯的 `ruleset-post` 檔(只在 wbox image) |
| `p5-autosave-off` | 不做「只因 P3 新 key 而 stale → `--save`」 |
| `provd-id-pid` | provd 辨識改回「peer pid = instance pid」(v5 的錯) |
| `setkey-norollback` | `--rollback` 不還原 |
| `setkey-readback-skip` | 跳過 radio0 / hostapd 讀回 |
| `healthok-2field` | 備援只看 bluetoothd + hci0_powered |
| `slot-copy-all` | `batman-slot` 複製所有 boot 檔(現行行為) |
| `autocommit-noprov` | autocommit 不看 helper / provd-stable |
| `ro-on-ctl` | app 的唯讀動詞走 ctl |

| 單位 | 斷言 | 負對照 |
|---|---|---|
| `prov-p3-routes-254` | 每個動詞 × 角色(匿名 / 候選 / 成員 / 擁有者)× owner-op 缺 / 錯 → §5.1 的線上碼;key 20 經 HTTP → `E_UNSUPPORTED` | wsl.22:全部 `E_UNSUPPORTED` |
| `prov-owner-254` | add / 重送輪替 / remove(BLE 與 HTTP session 都被切)/ 最後一位 | wsl.22 |
| `prov-settings-254` | get;**新卡 → 認領 → key 20 → 不重開**,30 s 內 AP 起來、新帳密可連、`bulk.open` ≠ 16、p5 有新值;**已入網節點**做 key 20 時 morse plink 不斷(新卡的 radio1 是封鎖的,在那裡量不到;並確認 setkey 的 `wifi reload \|\| wifi` 退路沒有被觸發);新卡配對注入失敗 → AP 不在空中、`disabled=1`、MARK 有該 iface、p5 不變;已配對節點注入失敗 → 舊帳密回來;passphrase 不在 `/proc/*/cmdline`(以 setkey 執行期間每 10 ms 取樣)、logread、helper / provd log、診斷包;密碼含 `$` → 13;另一程序持 setkey 鎖 15 s 時仍在預算內完成;**在 commit 與讀回之間殺掉 helper → setkey 自己跑完並還原**(負對照:沒有 `trap '' PIPE` 的 setkey 停在一半);`/tmp/.uci/wireless` 有暫存 → `E_BUSY` 且 `status` 回報;國家:未入網改 → 成功、p5 已存;已入網 → 14;legacy key 2 / 20 → 20;key 20 經 HTTP → 19;同值 `settings.set` 在 p5 stale 時存檔;改名在 U5 前回 `rename-pending` | `setkey-norollback`、`setkey-readback-skip`、wsl.22(key 20 不存在)、無 trap 的 setkey |
| `prov-country-join-254` | join / update 國家不符 → 14,`.txn` 不存在、uci 不變;先 key 2(regdb 有的國家,不看目前頻道)再 join(同國家的 net_config)→ 成功;新卡 key 2 = 例如 `DE`(ch 40 不在它的表裡)→ 仍成功(B6-M1);晶片換表不測(D21) | wsl.22(不比對國家) |
| `prov-status-diag-254` | status 與 halow-status 一致、成員只拿摘要;ro 10 / s × 10 分鐘:`cfgsave-lock.busy` 不出現、poll 沒有 ERate、BLE 廣播在;bundle > 64 KiB 完整取回、tar 可解、**內容**不含秘密;handle 跨 session 被拒 | `ro-on-ctl`(poll 拿到 ERate) |
| `prov-bundle-gate-254` | claimed → 403;legacy 無旗標 → 403;unclaimed / legacy + dev-open → 200;`status` 仍 200 | wsl.22(全部 200) |
| `prov-http-254` | **正向**:手機 AP 上的 client TCP 連得上 8095(⚠️ D22:使用者在現場);平常不聽;停 bluetoothd 5 分鐘 → 聽;讓 `sc_file` 失效 5 分鐘 → 聽;恢復 → 不收新連線、既有保留;psk_owner → 候選 → `auth/owner` 成功;NX / psk_replay 被拒;**mesh 臂**(與正向同一臂):另一台節點 eth0 上的主機以手機 MAC + IP(含 ARP 毒化)、50 conn/s、10 分鐘 → TCP 連不上、poll 無 ERate、BLE 廣播在、AP 上的擁有者完成上傳;**lo 臂**:本機連 8095 被丟;**VLAN 臂**(⚠️ D22):eth0 與 docker0 容器送帶 VLAN 封裝的 SYN → 被丟;刪表 → ≤ 8 s 不聽;firewall reload → 兩張表回來且規則各一份;helper 停掉 → provd ≤ 8 s 不聽 | `healthok-2field`、`http-nofw`、以 v6 的「bridge 層比 `tcp dport`」規則載入(VLAN 臂 FAIL)、以 v5 的 `phy*-ap*` 規則載入(正向 FAIL) |
| `prov-upload-254` | AP 關 → 16;非窗擁有者的 session → 拒;大小不符 → prepare 15;provd 寫超過 tmpfs → ENOSPC、其他服務正常;窗外的上傳檔一個 poll 週期內被刪;上傳中 `network/update` → `E_BUSY`;上傳中 helper 重啟 → 窗消失、重傳成功;`owner/remove` 清掉窗 | Go 接縫(各關一道:窗擁有者檢查、來源 IP 綁定、`otaBusy` 擴大)+ wsl.22 |
| `prov-update-254` | T 簽的 image 經 app 路徑 → trial → commit → 5;重裝同版本退回 → 6(不是 5);arm 前斷電 → 0;新版沒開機成功(注入:目標槽 kernel 壞掉)→ 6 + 18;之前退回過同一槽的 `bad-slot` 不造成假 6;worker 失敗的 reason 依類別;簽章錯、serial < min、板子錯、降級、min_from、目標槽開機設定不符、版本解析失敗、四包惡意 tar、上傳檔換成 FIFO、上傳後改 payload、prepare 中 kill helper / 斷電、helper 重啟後 phase 3 重建;回滾臂;**升級臂**:P2 未入網節點 sysupgrade 到 P3 → `--check` fresh;SSID 含 `'` 的節點升級後 OTA 不被擋;**sysupgrade 臂**:未列名的 dtb 不被寫進槽;**bench 臂**:YubiKey K 簽、release 設定節點、T 簽的被拒 | `slot-copy-all`(未列名的 dtb 被寫進去)、`p5-autosave-off`(升級臂 stale) |
| `prov-autocommit-p3-254` | **正向**:正常的 provd → commit;試用 image 的 provd 壞掉 → revert;helper 不在 → revert;provd 穩定 60 s 後被殺 → 仍 commit;provclient 掛 60 s 不算 provd-stable;`batman-provd` 被停用 → 只 WARN、commit | `autocommit-noprov`(壞 provd 被 commit)、`provd-id-pid`(正常 provd 也被退回) |
| `prov-transfer-tool-254` | WSL loop 檔(§3.9)+ 真卡(使用者的讀卡機) | 工具的測試旗標 `--test-skip-wipe`(只在 `--test-target-file` 模式可用)→ 特徵字串還在 |
| `prov-luci-reset-254` | firstboot 後擁有者 / mesh / AP 帳密仍在 | — (行為不變,只驗文字與保留) |
| `prov-fw-boot-254`(常規全套,每次開機後) | `inet fw4`、`bridge batman_http`、`inet batman_http_in` 都在;rc 驗收另跑 `fw4 print \| nft -c -f -`(兩板) | `fw-badinclude`(只在非 DUT、使用者同意、斷網) |
| `prov-eeprom-hooks-254` 補項(D11) | 1.5.12 負對照、fresh-overlay 檢查 | 1.5.12 image |

Go:§3.2 邊界、§3.6、§3.7 每個拒絕分支(mutant)、tar 白名單、版本規則表、§3.8 額度隔離、錯誤碼表(含 `hEUnsupported` 帶 reason)。CYW43455 的 Wi-Fi / BT 共存(key 20 reload 時 BLE 是否斷)在 `prov-settings-254` 量測並記錄。

## 9. 未決 / 實作前要查的(⚠️)

1. **U5 改名探針**(D8):使用者回現場時跑;結果補 §3.3 改名、§6「換 IP」列、`prov-settings-254` 的改名斷言。改名在那之前維持 `rename-pending`。
2. **YubiKey** 型號 / 韌體與 host 簽章工具鏈(DER → r‖s):使用者在場時實測;節點端只依賴 ES256。
3. (關閉,D21)晶片端的國家換表不在 P3 驗。
4. **HTTP 來源規則的剩餘實測**(D22):非 VLAN 部分已在 02 做(F75);剩「手機 AP 上的 client 通過(mark 從 bridge 帶到 IP 層)」與 VLAN 臂(eth0、docker0 容器),使用者在現場時在非 DUT 節點做,**H4 凍結前完成**;不成立時的出路:mark 帶不過去 → 回到 bridge 層判斷:`iifname != "phy*" tcp dport 8095 drop`,再加 `iifname != "phy*" ether type { 8021q, 8021ad } drop`(本機收的 VLAN 封裝 frame 一律丟;這套網路不用 VLAN),並以 VLAN 臂證明。
5. (關閉)一般重開時 96 不跑(F71)。
6. bulk tmpfs `size=` 的實際值(2 × 目前 release payload)與 bcm2710 的值。
7. `halow-setkey` 新旗標的讀回、還原與結束碼(§3.3):實作時逐行對 `halow-setkey:37-374`,不與既有結束碼撞號。
8. CYW43455 Wi-Fi / BT 共存(key 20 reload 時 BLE 是否斷):H4 量測。
9. **02 / 04 重燒成新卡**(D20):H4 / P3 上機前;破壞性,先列步驟與還原給使用者。

## 10. 要改的文件與檔案(本 PR)

- `219-protocol.md`:`:218` 拿掉「階段 1 不實作」;§4.2:PSK-only、什麼時候聽、`/msg` 多塊取回、上傳端點、**回應遺失 = session 中止(不做冪等快取)**;`:155`、`:212` 的 bulk「一次性 PSK」改為現行 AP 密碼;`:447` 改為輪替 `adv_owner_key`;`:210` 與 field-provisioning `:474` 對齊 D10;§5.2 `E_REJECTED` 改為「被拒(附原因)」不限更新。
- `219-protocol.cddl`:reason-code 11–20;`update-manifest` key 5(= CBOR `[E, S]`)、key 6 語意、S 的 key 7–9;`update/prepare`、`update/apply` 的 key 1 = sha(由 owner-op 的 `args_hash` 綁定);`status-resp` key 2–4 改選填;settings key 20;`bulk-open-resp` key 2 的註解;`update-phase` 2 的名稱;冪等欄位(`idem-type`、各請求的 `? 7`)註記「保留、P3 不使用(provd 回 `E_UNSUPPORTED{idem}`)」。
- `219-field-provisioning.md` §6.9:暫時 AP 改為「經這台節點的手機 AP」;B18 寫入兩層鑰匙。
- `254-stage1-impl.md`:§10.6 / §10.7(D3);`:171`(bundle 用 handle 分頁);`:357` `E_STATE` → `E_BUSY`。
- `254-p1-impl.md`:`:465`(admins +1 刪)、`:466`(未知 key 忽略)。
- `docs/VERSIONS.md`:版本比較規則。
- 新 `docs/`:說明頁文字(§3.10);release note(`/cgi-bin/bundle` 403、P3 之前的 payload 不能經 app 裝)。
- 檔案:`halow-setkey`(新旗標 + 說明 + deploy 鏡像);`batman-slot`(`write`、`arm`、`disarm`、`bootcfg-sum`、只複製列名的 boot 檔、`begin_write` 刪 VERIFIED);`batman-config-save`(PRESERVE 加 ssid;ssid 不可存時略過);`joinwatch` / `halow-status`(`verdict_code()`、`join.reason_code`,含 deploy 鏡像);`batman-autocommit`(新鮮度、helper、provd-stable、provd 停用時 WARN);`www/cgi-bin/bundle`(+ deploy 鏡像);`/usr/share/nftables.d/ruleset-post/batman-http.nft`(新,兩張表先刪再建);`batman-provd.init`(tmpfs、rw mount、不疊掛);`build-ab-payload.sh`(順序、`release=`);`release-sign.sh`、`release-endorse.sh`(新);`transfer-flash.ps1` / `.sh`(新,含 `--test-skip-wipe`);tmp-trust allowlist 的新路徑照 #290 走 harness PR。
- firmware:`flash.js` 文字 patch;**不加** `kmod-nft-bridge`(F60)。

## 11. 寫進 #254 checklist(不在本 PR)

`status` team(`dac_pub_hash`、最後看到時間);EMCON(手機 AP 平常關 / 功率;刻意關 BLE 時也要關 HTTP 備援);autocommit BLE 無線電擋 commit(#305 後);CM4 eMMC 的轉賣 / 遺失手機重燒路徑(量產前,D18);未簽章更新路徑(ssh / LuCI / openmanetd local upgrade、`PerformFactoryReset`)要不要收;app 端的靜默模式;整個網路一起改國家(D9);3A+ 上 bulk tmpfs 的常駐佔用;P3 之前建的 payload 不能經 app 裝;5 GHz 手機 AP 的國家合規。

## 12. v7.2 實作前核對(2026-11-11;S5 開工前)

設計寫於 main 2ecf1cb / 節點 wsl.22;S5(§3.7、§3.8、§3.11)開工前,依 feat/254-p3 fbc01ae、firmware 02f0913d、節點 04 = `1.5.14-wsl.25+fbc01ae.fw02f0913` 逐條核對(原始報告:#254 留言,`facts-check.md`)。**§3.7 / §3.8 的產品端完全沒有實作**;harness 已先有 `tests/keys/`(T、K_test)、`tests/tools/peer/signrel.py`、`scripts/dv/prov-http-254.sh`。行號移動(`server.go` 約 +17、`mapHelper` → `session.go:567`、`otaBusy` → `node/wtxn.go:450-454`)不影響設計。本節只寫**與設計不同或設計沒寫到**的地方;§3 其餘照舊。原則不變:只做必要的修改、失敗回到之前的狀態。

### 12.1 事實更正

| # | 設計寫的 | 現況(證據) | 影響 |
|---|---|---|---|
| C1 | F8:PRESERVE 不含 `default_radio0.ssid` | 已含(`batman-config-save:46`),另有 `SKIP_UNSAFE`(`:58`、`:466`) | §3.3 的「PRESERVE 加 ssid」已做;不再改 |
| C2 | F37:`otaBusy` 只擋 `net.apply` / `network.leave` | 也擋 `settings.set`(`node/node.go:247`) | 與 §3.1-7 方向一致;`update.*` 照 §3.7.4 自己判斷 busy |
| C3 | §3.1-8 錯誤碼待做 | 已做:`hEReject`(24)、`hEInput`(25)(`provd/helper.go:26-27`)、`mapHelperR`(`session.go:896-911`);設計寫的 `hERejectR` 即 `hEReject` | 只引用 |
| C4 | §3.7.2 tar 順序待改 | 仍是 `root.squashfs boot metadata SHA256SUMS`(`build-ab-payload.sh:73`);兩板實際 payload 的成員都在 §3.7.5 白名單內 | 照 §3.7.2 改 |
| C5 | F59:fw4 會 include `ruleset-post` | 原始碼成立(`fw4.uc:817-822` 前綴比對 → `ruleset-append`,`ruleset.uc:472`;整份 `nft -f` 一次,`sbin/fw4:35-36`);**rootfs 沒有 `/usr/share/nftables.d/ruleset-post/` 目錄** | 我們的套件建這個目錄 |

### 12.2 設計沒寫到、會撞到同一資源的(要先定)

1. **(v7.3 由 §12.5.1 取代)helper 在鎖外掛載 B 槽的開機分割區**:`bootConfigOK`(P1 起,`cmd/batman-provhelper/main.go:713-733`)在已 commit 且 Powered ≥ 600 s 時,**每 15 s 唯讀掛載 `/dev/mmcblk0p3`**(`health/health.go:223,235`),不經 `batman-slot.lock` —— 推翻 A4-m13「鎖外不掛 FAT」的前提。目前槽 = A 時,p3 正是更新的目標槽;與 `tboot_open` 的 rw 掛載(`batman-slot:409-416`)相撞 → EBUSY → `write` 中途 die(fail-closed:槽留 BAD,但 app 只看到 reason 11)。04 唯讀觀察 30 s 沒取樣到掛載(掛載只有毫秒級,1 s 取樣抓不到),**不能當作沒發生**。
   **做法**:(a) helper 在自己的 worker / `update.apply` 進行中**不跑** p3 掛載,沿用上一次 `ConfigOK` 的結果;(b) 其他時候掛載前先看 `$RUNDIR/batman-slot.lock` 存在 → 這一輪跳過(沿用上次結果)。剩下「看了沒鎖 → 掛載」之間的毫秒窗,只在 **sysupgrade**(不經 helper)時可能撞到 → 該次 sysupgrade fail-closed、可重試 → 誠實界線。測試:worker 執行中 helper 的 p3 掛載次數 = 0(負對照:拿掉 (a) → > 0)。
2. **(v7.3 由 §12.5.2 取代)`batman-slot` 的失敗沒有類別碼**:`die` 一律 `exit 1`(`batman-slot:40-44`),§3.7.5-6「依失敗類別對應 reason」無從判斷。**做法**:新動詞 `write` / `arm` / `bootcfg-sum` 的結束碼:

   | rc | 意思 | helper 對應 |
   |---|---|---|
   | 0 | 成功 | — |
   | 10 | 試用中 | reason 1 |
   | 11 | 有 `.txn` | reason 12 |
   | 12 | p5 不新鮮 | reason 17 |
   | 13 | 內容 / 讀回不符、`BATMAN-VERIFIED` 不符 | reason 11 |
   | 14 | 另一個 `batman-slot` 持鎖 | `E_BUSY` |
   | 15 | 開機設定不在 key 8 清單 | reason 5 |
   | 其他 | 內部錯誤 | reason 11 |

   既有的 `apply` / sysupgrade 路徑只看 rc ≠ 0,行為不變;`--check` 拿不到鎖(`:506`)也回 14。測試:每個 rc 各一個誘發案例(故障接縫 `fault()` `:75`)。
3. **provd 行程辨識需要 peer pid**:`sock.peerUID` 只取 uid、丟掉 pid(`sock/sock.go:178-194`),handler 工廠拿不到連線資訊(`main.go:663`)。**做法**:sock 層保留 SO_PEERCRED 的 pid 與 uid,傳給 handler 工廠;§3.7.6(b) 照原設計用 pid 判斷。只改 Go 內部介面,不改協定。04 實測 F11 成立:provd pid 8072、`PPid` 8041 = ujail(procd instance pid)、uid 471、`exe=/usr/bin/batman-provd`。
4. **board 字串比哪個**:payload `metadata` 是 `board=ekh-bcm2711`(`build-ab-payload.sh:69`),provd 的 `Config.Board` 去掉了 `ekh-`(`cmd/batman-provd/main.go:81`)。**做法**:S key 2 與 `metadata board=` 都和 `/etc/batman-build` 的 `BATMAN_BOARD`(全串,例 `ekh-bcm2711`)比;provd 的短字串只用於顯示。
5. **信任哪把根鑰匙**(使用者 2026-11-11 決定:先用測試根鑰匙 T):
   - DEV 通道(`BATMAN_CHANNEL=wsl`)的 image 內建 `release-root.pub` = **T**(`tests/keys/T.pub`),`release-min-serial` = 1;wbox / prov_test image 同樣信任 T(原設計)。
   - 正式根鑰匙 R 與 YubiKey(§3.7.1、§9-2)在正式版(#255)時產生、實測;**release gate**:`BATMAN_CHANNEL` ≠ `wsl` 的 image 若含 T → 不出貨。
   - 因此 §8 `prov-update-254` 的「T 簽 → 試用 → commit → phase 5」用一般 DEV image(會 commit);wbox image 永不 commit(`batman-autocommit:489-494`、`batman-slot:800-805`)不能當目標。
   - **界線**:DEV image 信任的是公開的 T,任何人都能簽出 DEV image 能裝的 payload —— DEV 只在 bench / 開發用,與 dev-trust app 同一條界線。
6. **bcm2710**:使用者已決定量產用 CM4、Pi 3 暫不支援(2026-10-23)。S5 的程式兩板共用、都要編譯,但**只在 bcm2711 真機驗證**;firmware 樹裡的 bcm2710 payload 是舊的(2026-10-27)。bulk tmpfs 的 `size=` 依各板當次 build 的 payload 大小計算(bcm2711 = 2 × 126,309,765 B ≈ 241 MiB)。
7. **簽章格式以 harness 的 `signrel.py` 為準**(測項只有一套):key 9 = 所有 `boot/` 成員大小總和;key 8 空 = 省略(= 不檢查);manifest key 5 = CBOR 陣列 `[E, S]`(兩個 bstr);key 3 = `.tar.gz` 檔大小。產品若要不同,先改 harness(harness PR 先進)。
8. **(v7.3 由 §12.5.3 取代)D-14(`batman-slot` 被 TERM 殺掉時 `.busy` 留下)現在必修**:helper 的期限(§3.7.5-6)會對 `write` 送 SIGTERM;仍無 TERM trap(`batman-slot:157`)。`.busy` 殘留會讓 autocommit 延後退回最多 600 s(`batman-autocommit:226`)且 `otaBusy` 擋到下次開機。做法照附錄 D-14。

### 12.3 04 唯讀實測(2026-11-11,wsl.25)

| 項目 | 結果 |
|---|---|
| RAM / tmp(F25) | MemAvailable 7,174,904 kB;`/tmp` tmpfs 3,983,412 kB;無 swap |
| RunDir(F53) | `/tmp/run/batman` root 0700;`/tmp/run/batman-prov` root:provd 0750 |
| provd 開檔上限(F43) | soft 1024 |
| 手機 AP | **關著**:`br-ahwlan` 的 port 只有 `bat0`、`eth0`,沒有 `phy*`(04 的 AP key 是 placeholder,keyguard 擋)→ 真機測上傳前,app 要先以 key 20 配對打開(§3.11-6) |
| fw4 | 只有 `table inet fw4`;`auto_includes` 未設(預設 1);`/usr/share/nftables.d/` 只有 README |
| br_netfilter | 已載入;`bridge-nf-call-iptables` = 1 |
| 埠 8095 | 空著 |
| 槽 | A committed,`batman-slot verify ok`;tryboot 旗標讀回 0 |

**沒做**:F75 / F76 / §9-4 的 VLAN 臂與「AP client 通過」(要載入臨時 nft 規則、不是唯讀,需使用者同意;§9-4 仍開著)。

### 12.4 CDDL / 協定還沒改的(§10)

reason-code 11–20 已加(`219-protocol.cddl:132-143`);仍要改:`update-manifest` key 5 = `[E, S]`(`:300` 還寫 detached signature)、`bulk-open-resp` key 2 = 現行 AP 密碼(`:323` 還寫 one-time)、`update/prepare|apply` 的 key 1 = sha。

### 12.5 v7.3 審查修正(2026-11-11;A8 = `p3-review-v72-A.md`、B8 = `p3-review-v72-B.md`)

兩位都 APPROVE-WITH-CHANGES、0 BLOCKER;A8 2 MAJOR / 14 MINOR、B8 2 MAJOR / 12 MINOR。下面每項**取代**它所指的段落;沒提到的照舊。逐條回應見附錄 E。

#### 12.5.1 boot 分割只有一個掛載者 = `batman-slot`(取代 §12.2-1;A8-m1)

- 事實更正:`tboot_open` 看到目標分割已被掛著就**重用**那個掛載點(`batman-slot:409-416`),所以撞上 helper 的 ro 掛載時不是 EBUSY,而是寫進 ro 掛載失敗,或在 helper 剛卸載後寫進留下的 tmpfs 空目錄。A8 逐支追過都 fail-closed,但依賴 `arm` 不重用掛載點 —— 不可靠。
- **做法**:
  1. `tboot_open` **只重用 `/boot`**(p1 的正常掛載);目標分割在別處被掛著 → rc 14(busy),不重用。
  2. 新唯讀動詞 **`batman-slot bootinfo <A|B>`**:拿 `batman-slot.lock`(拿不到 → rc 14)、ro 掛該槽的 boot 分割(p1 直接讀 `/boot`)、印 `verified=<hex|->`、`bootcfg=<sha256(config.txt ‖ distroconfig.txt)>`,再印一行 `--` 與 `distroconfig.txt` 全文(≤ 64 KiB);卸載、放鎖。**取代 §3.7.3 的 `bootcfg-sum`**。
  3. helper **不再自己掛任何 FAT**:`bootConfigOK`(`main.go:713-733`)改用 `bootinfo` 的輸出、同一個 `sectionOK` 規則;§3.7.4 的 `BATMAN-VERIFIED` 快取也來自 `bootinfo`。rc 14 → 這一輪沿用上一次結果,並標「待重讀」,下一個 tick 再試(孤兒 `write` 完成後快取會更新)。
- 結果:boot 分割的掛載者與寫者都只有 `batman-slot`,全部在鎖內;§12.2-1 的 (a)(b) 與「sysupgrade 毫秒窗」界線一起拿掉。操作員手動掛著目標分割 → rc 14,fail-closed。
- 測試:接縫 `/tmp/batman-fault.bootinfo-hold`(`bootinfo` 持鎖 5 s)同時 `write` → `write` rc 14、目標槽沒被動到。負對照:接縫 `tboot-reuse-any`(恢復「重用任何掛載點」)+ 先 ro 掛目標分割 → `write` 寫錯地方或 die(FAIL)。

#### 12.5.2 結束碼與 reason(取代 §12.2-2 的表;A8-MAJOR-2、B8-m4)

定義在 `node_checks` 這一層,`precheck-node`、`write`、`arm`、`apply`、`bootinfo`、`disarm` 共用:

| rc | 意思 | helper 對應 |
|---|---|---|
| 0 | 成功 | — |
| 10 | 試用中 | reason 1 |
| 11 | 有 `.txn` | reason 12 |
| 12 | p5 不新鮮 | reason 17 |
| 13 | 內容 / 讀回 / `BATMAN-VERIFIED` 不符;SUMS 列了不允許的名字(§12.5.4) | reason 11 |
| 14 | 另一個 `batman-slot` 持鎖;`.busy` 持有者還活著(§12.5.3);目標分割在別處被掛著(§12.5.1) | `E_BUSY` |
| 15 | 開機設定不在 key 8 清單 | reason 5 |
| 16 | p5 未 seed | reason 2 |
| 17 | 韌體開錯槽(fw-override,`batman-slot:556-578`) | reason 21 |
| 18 | 卡片 / layout 不健全(MBR、FAT 數、`[tryboot]` 指向) | reason 21 |
| 其他、逾時(124)、exec 失敗(127)、被殺(137 / 143) | 內部錯誤 | reason 21 |

- **新 reason 21**(CDDL):「節點端現在無法寫入槽」;log 帶 rc。**reason 11 只留給雜湊 / 簽章 / 版本解析不符**(rc 13 與 helper 自己的檢查)。
- `is-trial` 的 `DIE_RC=2` 不變(`batman-slot:894`)。既有呼叫者只看 rc ≠ 0,行為不變:`platform-ab.sh:184-186`、`:364-366`、`:375-379`;`daily-validation.sh:2068`(`^rc=[1-9]`,10–18 也符合);`chain1-254.sh:220`。
- §5.1 `update.apply` 補 rc 14 → `E_BUSY`。
- 測試:每個 rc 一個誘發案例(故障接縫 `fault()`,`batman-slot:75`);另加「p5 未 seed → `update.check` 回 reason 2」。負對照:wsl.25 的 `batman-slot` 一律 rc 1 → helper 回 11(FAIL)。

#### 12.5.3 `.busy` 帶 pid(取代 §12.2-8 與附錄 D-14 的二選一;A8-m2、B8-M2)

- helper 的期限先送 SIGTERM、10 s 後送 SIGKILL(`provstore/exec.go:37-45`);SIGKILL 不跑任何 trap;busybox 的 trap 也要等前景 `dd` 回來。只加 TERM trap 不夠。
- **做法**:
  1. `.busy` 的內容 = 持有者 pid。所有讀者(`otaBusy`,`node/wtxn.go:450-454`;autocommit `:226`;`node_checks`)都用與 `slot_lock` 相同的規則判斷:pid 活著且 `/proc/<pid>/cmdline` 含 `batman-slot` 才算忙;持有者死了 = 不忙(讀者不刪,下一次 `batman-slot` 執行時清掉)。
  2. EXIT trap 加 `tboot_close`;加 `trap 'exit 143' TERM`(正常 TERM 時清乾淨)。
  3. 每個寫入動詞開始時,卸載 `/proc/mounts` 裡 pid 已死的 `/mnt/slotboot.<pid>` 並 rmdir。
- 測試:Go 接縫 `update-deadline-short` + 故障接縫 `write-hang`(`dd` 前 sleep)→ helper TERM → KILL → 之後 `settings.set` 不是 `E_BUSY`,`/proc/mounts` 沒有 `/mnt/slotboot.*`。負對照:只有 TERM trap 的版本 → `E_BUSY` 到重開(FAIL)。

#### 12.5.4 boot 檔的複製集合(B8-M1;改 §3.7.3「共同修改」)

- 原句「複製 boot 檔只複製 `SHA256SUMS` 列出的」改為:**複製的集合 = SUMS 列出的 ∩ 現行類別白名單**(`kernel8.img`、`start*.elf`、`fixup*.dat`、`*.dtb`、`overlays/*`,`batman-slot:677-683`)。「NEVER `bootcode.bin` / `autoboot.txt`」的保證不變。
- helper(reason 11)與 `batman-slot`(rc 13)**兩邊**都明確拒絕 `autoboot.txt`、`config.txt`、`distroconfig.txt`、`cmdline.txt`、`bootcode.bin`、`BATMAN-*`。出現就拒絕,不默默略過。
- **SUMS 的每一列**(不只 tar 成員)都要符合 `^(root\.squashfs|boot/[A-Za-z0-9_-][A-Za-z0-9._-]*|boot/overlays/[A-Za-z0-9_-][A-Za-z0-9._-]*)$`。第一個字元不能是 `.`,擋 `boot/..`。
- 現行兩板 payload 的 SUMS 只有 kernel、start、fixup、dtb 與 overlays(bcm2711 實際 payload 逐列核對:11 個檔 + 350 個 overlay),所以這個拒絕不會擋掉正常 payload;sysupgrade 路徑同樣受益。
- 測試(`prov-update-254` 惡意 tar 臂 + sysupgrade 臂):一份**有效簽章**、SUMS 列 `boot/autoboot.txt` / `boot/config.txt` / `boot/..x` 的 payload → 拒絕;p1 `autoboot.txt` 的 sha 前後相同。負對照:接縫「只照 SUMS 複製、不交集」→ `autoboot.txt` 被改(FAIL)。

#### 12.5.5 `update.status` 綁定「哪一次嘗試」(A8-MAJOR-1;改 §3.7.4 判讀、§4、§5.3、CDDL)

- **CDDL** `update-progress` 加 `? 4 => sha256`(這個 phase 說的是哪一份 `SHA256SUMS`)與 `? 5 => tstr`(to_version)。app(§3.11-5)只在 sha 等於自己要裝的那份時,才把 3 / 4 / 5 當成功。
- **update-last 的寫者 = helper 的更新序列**(`update.prepare`、worker 結束、`update.apply`、`reboot committed` 失敗;同一個 goroutine 依序寫,仍是一個寫者)。格式(§5.3):`{0: format = 1, sha, from_slot, from_version, to_slot, to_version, attempt_boot_id, written, apply_boot_id, bad_slot_at_apply, armed, rebooting}`;未知 format / 壞 → 當作沒有。
  - `update.prepare`:啟動 worker **之前**寫 `{…, written: false, armed: false, rebooting: false}`;寫入失敗(p6 未掛載、滿、唯讀)→ `E_STORAGE`,不啟動 worker。
  - worker 成功 → `written: true`。
  - `update.apply` 照舊寫 `apply_boot_id`、`armed`、`rebooting`;寫入失敗 → `E_STORAGE`,不 arm。
  - `reboot committed` 失敗(D-10)→ disarm 並改回 `rebooting: false`。
- **判讀順序寫死(取第一個成立的)**:

| # | 情況 | phase |
|---|---|---|
| 1 | 上傳窗開著 | 1 |
| 2 | worker 在跑 | 2 |
| 3 | helper 記憶體裡本次開機的嘗試失敗 | 0 + reason |
| 4 | pending 有效且目標槽 `verified` = pending sha | 3 |
| 5 | update-last 缺 / 壞,或目前槽版本 ∉ {from_version, to_version} | 0 |
| 6 | boot_id = `apply_boot_id`(apply 之後還沒重開) | disarm,報 3 |
| 7 | 目前槽 = `to_slot`、版本 = to_version、`is-trial` | 4 |
| 8 | 目前槽 = `to_slot`、版本 = to_version、已 commit | 5 |
| 9 | 目前槽 = `from_slot`、`armed`、boot_id ≠ `apply_boot_id`、`bad-slot` 新指向 `to_slot` | 6 |
| 10 | 目前槽 = `from_slot`、`rebooting`、boot_id ≠ `apply_boot_id`、沒有新的 `bad-slot` | 6 + reason 18 |
| 11 | 目前槽 = `from_slot`、`written` 為 false(寫到一半斷電、helper 重啟、worker 被中止) | 0 + **reason 22** |
| 12 | 目前槽 = `from_slot`、`written` 為 true、`armed` 為 false、沒有有效 pending | 0 + **reason 23** |
| 13 | 其他 | 0 |

  每個 phase 都帶 key 4 / 5(取自 pending 或 update-last)。
- **新 reason**(CDDL):**22**「上次寫入沒有完成,另一槽(退路)已失效,需要再更新一次」;**23**「新版已寫入但沒有啟用,請重新更新」。
- **reason 18 的界線改正**(A8-m3):涵蓋的不只毫秒級窗,而是 `rebooting` 寫入之後到試用結束前的任何中斷,包括 procd 關機(安全網 240 s,`batman-slot:885-890`),以及試用中斷電、卡死、看門狗重開。文字改為「新版沒有完成試用(沒開機,或試用中斷電 / 重開)」。
- MAJOR 情境:上次成功更新到 v2,這次更新 v3,寫到一半斷電。prepare 已把 update-last 改成 to_version = v3、`written: false`;重開後目前槽 = from_slot(v2)→ 第 11 列 → 0 + 22,**不是 5**。同時有 ssh sysupgrade 裝別的版本 → 版本 ∉ {from, to} → 第 5 列 0。
- 測試:Go 單元表測判讀函式(每列一案);`prov-update-254` 加「v2 成功後 v3 寫入中 kill helper / 斷電 → 0 + 22」。負對照:接縫 `update-no-attempt-record`(prepare 不寫 update-last = v7.2 行為)→ 報 5(FAIL)。

#### 12.5.6 兩位擁有者、移除擁有者(A8-m4、B8-m8)

- pending 記 `owner_key_id`。有效的 pending 屬於別的擁有者時,`update.check` → `E_BUSY`(pending 30 分鐘到期或重開後釋放);同一位擁有者 → 覆寫。
- `bulk.open` body 加 `2: sha`(由 owner-op 綁定),必須等於 pending 的 sha,否則 reason 15。CDDL `bulk-open-req` 同步。
- `owner/remove` 移除的若是 pending 的擁有者:清窗、清 pending;**worker 屬於他時中止 worker**(context cancel → `batman-slot write` 收 TERM → 槽保持 BAD,update-last `written: false` → 第 11 列報 0 + 22)。測試:worker 執行中 `owner/remove` → worker 結束、槽 BAD、status 0 + 22。

#### 12.5.7 上傳語意(A8-m5;§3.8.2、§3.11、§6)

- `PUT` 每次都從頭寫:`O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW`,不續傳;同時只能一個 PUT(第二個 → 409)。
- provd 從 poll 知道窗到期時間。**剩餘時間 < `Content-Length` ÷ 256 KiB/s + 60 s → PUT 回 409**;app 先重送 `bulk/open`(同一擁有者 = 延長)再 PUT。§3.11-1 加這一步。窗是 15 分鐘,126 MB 在最低速率下約 8.2 分鐘,延長後一定夠,不需要新機制。
- 手機斷 Wi-Fi、上傳中斷:provd 關檔;prepare 會發現大小不符(reason 15);app 重新 PUT(從頭)。§6 加一列。

#### 12.5.8 串流 stdin 與期限(A8-m6)

`provstore.Exec` 的 stdin 是 `[]byte`(`exec.go:19-23`),會把約 111 MiB 的 squashfs 整個放進記憶體。新增 `ExecReader(timeout, env, stdin io.Reader, …)`,pgid、TERM → KILL 規則相同;worker 用它。期限:`write` 600 s、`arm` 60 s、`bootinfo` 30 s、`disarm` 30 s(`run()` 對 batman-slot 預設的 60 s 不適用於 `write`)。

#### 12.5.9 版本規則表(A8-m7;加進 §3.7.1)

- 解析 `X.Y.Z[-CH.N][+meta]`;比較鍵 = `(X, Y, Z, N)`,正式版 N = ∞;**CH 不參與比較**;`+meta` 忽略。
- 新 > 舊 = 升級;**相等 = 重裝,允許**(不是降級);新 < 舊 = 降級,要在 S key 6 列出目前版本(去掉 `+meta` 的全串)。
- **界線**:`+meta` 忽略 → 同號的 wbox(帶 Go 接縫)與乾淨版相等,DEV 上可以用 T 簽互裝(與 §12.5.10 同一條界線)。
- 測試:Go 表測(相等、正式 vs 通道、跨通道同號、`+meta`、解析失敗)。

#### 12.5.10 信任與 release gate(A8-m8、B8-m1、B8-m10;改 §3.7.1 鑰匙表)

- §3.7.1 表的 T 列改為:「DEV 通道(`BATMAN_CHANNEL=wsl`)與 prov_test image 信任;正式通道 image 不得含 T」。`tests/keys/README.md` 的「T is trusted only by `prov_test`」在 harness PR 同步改(#290:測項只有一套,harness 檔先進 main)。
- **DEV → PROD 的出口**:R 產生之後(#255),DEV 節點要換信任,只能用一份 **T 簽、內建 R(不再含 T)的過渡版**,或用 ssh sysupgrade / 重燒。§6 加列。02 / 04 目前都是 wsl 通道。
- **release gate 改成正向**:`BATMAN_CHANNEL` ≠ `wsl` 的 image,`release-root.pub` 必須等於釘死在 `scripts/release-root.fpr` 的 R 指紋,而且 `release-min-serial` 存在且 ≥ 1。R 產生前這個檔不存在 → 正式通道 build 的 gate 一律 FAIL(正確:R 之前不出正式版)。負測試:正式通道 + T.pub → FAIL;沒有釘選 → FAIL。
- **鑰匙檔缺 / 壞 → 拒絕**:`release-root.pub` 不是正好一個 65 B 的點,或 `release-min-serial` 不是正好一行 ≥ 1 的十進位 → `update.check` 回 reason 21,不預設成 0。附 Go 測試。
- §7 加列:
  - **DEV 的信任根 = app 從哪裡拿到 payload**。T 公開,任何人都簽得出 DEV 會接受的 payload;擁有者同意的是那份檔的 sha,下載來源(release 頁、雲端、手機存檔)被換掉,擁有者就會同意一份惡意 image。DEV 只用於 bench / 開發;另一個做法(不公開的開發根鑰匙 R_dev)待使用者選。
  - 信任 T 不擴大擁有者的權限:擁有者本來就能 `ssh_keys/set`(F2)。
  - 實體奪取者可以換 rootfs 上的 `release-root.pub`:沒有 secure boot 前擋不住,列誠實界線。
- B8-m9(DEV 上被入侵的 provd 用 T 簽的 manifest 反覆 `update.check` 搶鎖):`update.check` 只在 manifest 的 sha 與上一次不同時才跑 `bootinfo` / `precheck-node`,相同就用快取的結果;加上 helper 的 1 / 10 s 額度。剩下的可用性影響只在 DEV,列 §7。

#### 12.5.11 防火牆、bind 與 bearer(B8-m2、m3、m5)

- **lo 主張改正**:有 CAP_NET_RAW 的行程可以設 `SO_MARK`(kernel 6.6 `net/core/sock.c:1388-1395`),例如 `--network host` 的容器。inet 規則在 mark 檢查**之前**加 `tcp dport 8095 meta iifname != "br-ahwlan" drop`(本機產生的封包 iif = lo)。測試:root 開 `SO_MARK=0x01000000` 的 socket 連 8095 → 被丟。負對照:只有 mark 的規則 → 連得上。
- **8095 被搶占**:provd bind 失敗(EADDRINUSE)→ 經 poll 回報,`status` key 15 加 `http_bind_failed`,app 顯示。本機非特權行程可以先佔住 8095 → 只造成 DoS(Noise 擋住冒充),列 §7 誠實界線。測試:先用一般使用者佔住 8095,再 `bulk.open` → `status` 回報。
- **`X-Batman-Session` bearer 的規格**:
  - provd 在 HTTP session `auth/owner` 成功後,以 `crypto/rand` 產生 128 bit,與 Noise 的金鑰 / 雜湊無關;
  - constant-time 比對;
  - 不進 log、錯誤字串、診斷包;
  - 只對 `PUT /bulk/0` 有效。
  - `/msg` 的 AEAD 失敗 → **丟掉那個請求(400),不中止 session**。`flynn/noise` v1.1.0 的 `Decrypt` 失敗不推進 nonce(`state.go:76-80`),所以可以這樣做;偽造的 `/msg` 踢不掉擁有者。
  - §8 `prov-http-254` 加「bearer 不在 log / 診斷包」與「偽造 `/msg` 後 session 仍可用」。

#### 12.5.12 bulk tmpfs 與 tar 解析(B8-m6、m7、A8-m11)

- tmpfs 掛載加 `nr_inodes=16`;**`batman-provd.init` 與 `batman-provd-test.init` 兩個檔都加**(Makefile 依 `BATMAN_PROV_TEST` 二選一安裝)。D-15 照做。
- helper 刪檔只用 `unlinkat(dirfd, "payload")`;其他名字以 dirfd + `O_NOFOLLOW` 列舉後 `unlinkat`,不用 `RemoveAll`、不跟隨 symlink。
- tar 解析寫死:
  - 只收 `Typeflag` = `TypeReg`,以及 `boot/`、`boot/overlays/` 兩個 `TypeDir`;其他型別(含 PAX global、GNU sparse)→ reason 11;
  - `root.squashfs` 之後 `Next()` 必須是 `io.EOF`;
  - 成員數 ≤ SUMS 列數 + 4;
  - gzip 用 `Multistream(false)`,gzip 串流之後不得有尾端資料;
  - 解壓總量 ≤ 2 × 64 KiB + key 9 + 目標槽大小 + 1 MiB(header 與 padding)。
  - 每項附一包惡意 tar(§8「四包」擴充成逐項)。

#### 12.5.13 「已寫入、未啟用」與 #133 fallback(A8-m9、B8-m11)

- `write` 成功後,目標槽是真 cmdline、沒有 BAD、未 arm(`batman-slot:704-714`)= 一個可以開機的有效槽;pending 到期後也不清。status:pending 有效時報 3,之後報 0 + 23(§12.5.5 第 12 列)。
- **界線**:如果之後 `from_slot` 開不起來,韌體 #133 fallback(`p_req` 0)開進這一槽,autocommit 會在健康時 commit 它(`batman-autocommit:352-369`)。它有簽章、讀回過,擁有者在 prepare 時也同意了,所以不是越權,只是擁有者沒按 apply。§6 加列、§3.11-5 加「已寫入、未啟用」的文字。

#### 12.5.14 同時 ssh sysupgrade(A8-m10)

`node_checks` 加:`.busy` 存在且持有者活著、不是自己 → rc 14。結果:app 的 `write` 在跑時,sysupgrade stage 1(`precheck-node`,`platform-ab.sh:~186`)拒絕;操作員照舊可以 `-F` 強制。測試:`write-hang` 中跑 sysupgrade → stage 1 拒絕。

#### 12.5.15 其他契約補漏(A8-m12、m14)

- update-last 的 key 0 = format(見 §12.5.5)。
- helper 啟動時的 `batman-slot disarm` 要拿鎖;拿不到 → rc 14,下一個 tick 重試(不打斷孤兒 `write`;`begin_write` 本身也會 disarm)。
- `write <dir>` 的 dir 放 helper 驗過的 `SHA256SUMS`、`metadata` 與 `boot/`(precheck 會讀 `$PAYLOAD/SHA256SUMS` 與 `metadata size=`,`batman-slot:609-627`)。
- **bcm2710**:`batman-slot` 的 rc、trap、`tboot_open`、`bootinfo` 改動會進入 Pi 3 共用的 sysupgrade 路徑 → CI ab-card(pi3 layout)要跑過,寫進 §8。

#### 12.5.16 §12 決定的負對照(A8-m13、B8-m12)

| 決定 | 測試 | 負對照(拿掉就 FAIL) |
|---|---|---|
| 12.5.1 單一掛載者 | `bootinfo-hold` + `write` | `tboot-reuse-any` 接縫 |
| 12.5.2 結束碼 | 每個 rc 一案 + 未 seed → reason 2 | wsl.25 `batman-slot` |
| 12.5.3 `.busy` 帶 pid | `write-hang` + 期限 → KILL | 只有 TERM trap |
| 12.5.4 複製集合 | 有效簽章 + `autoboot.txt` | 「只照 SUMS」接縫 |
| 12.5.5 嘗試綁定 | v2 → v3 中斷 → 0 + 22 | `update-no-attempt-record` |
| 12.5.6 移除擁有者 | worker 中 `owner/remove` | 不中止 worker |
| 12.5.10 gate | 正式通道 + T → FAIL | 只檢查「不含 T」的舊 gate |
| 12.5.10 鑰匙檔 | 缺 / 壞 → reason 21 | 預設 min-serial 0 |
| 12.5.11 iifname | `SO_MARK` socket → 丟 | 只有 mark 的規則 |
| 12.5.12 tar | 每包惡意 tar | 拿掉該項檢查 |
| 12.2-3 peer pid | `provd-id-pid`(既有) | — |
| 12.2-4 board 全串 | S key 2 = `bcm2711` → reason 3;`metadata board=` ≠ S → 11 | 用 provd 短字串比 |
| 12.2-7 格式契約 | `signrel.py` 的正向物件 Go 接受;每個負向旗標(`--bad-sig`、`--wrong-board`、`--unparsable-version`、`--mismatch-size`、`--key other`)Go 都拒絕 | 拿掉 Go 任一檢查 |

#### 12.5.17 CDDL 要改的(加到 §12.4)

`update-progress` 加 key 4 / 5;`bulk-open-req` 加 key 2 = sha;reason-code 加 21 / 22 / 23;18 的文字改為「新版沒有完成試用」。

## 附錄 A. v4 審查回應(A4 = `p3-review-v4-A.md`、B4 = `p3-review-v4-B.md`)

| 項 | 處理 |
|---|---|
| A4-M1 / B4-M1 nft 表沒有執行期擁有者、表不在 = fail-open | 載入者 = fw4(`ruleset-post` include);helper 確認表 + 鏈 + 規則在才給 `http.2`,否則 provd 不聽(§3.8.1);靜態 `iifname != "phy*-ap*"`,不用 helper 維護 set;生命週期加 firewall stop / reload(§6);負對照 `http-nofw`;**v6 規則改為 `phy*` 並先 flush,見附錄 B** |
| A4-M2 / B4-m7 setkey 300 s 預算 | `--lockwait 20`,逐常數算到 230 s(§3.3 表);逾時 → 背景 `--rollback-only`(**v6 拿掉,見附錄 B**) |
| A4-M3 文件前後矛盾 | v5 整份重寫;舊的 §12–§14 移除(見 git 歷史) |
| A4-M4 負對照做不出來 | 只用 wsl.22 基準與 `BATMAN_FAULT_INJECT` 接縫(§8 表) |
| B4-M2 新 PRESERVE key 的 stale | 只因 P3 新 key 而 stale → helper 在非試用開機時與 `update.check` 時 `--save` 一次;其他 stale → reason 17(§3.3) |
| A4-m1 `/rom` fresh 規則 | 移除;降級的 stale 寫實(§3.3、§6) |
| A4-m2 / B4-m6 radio0.country | 不改 radio0、不進 PRESERVE(§1.2) |
| A4-m3 key 20 經 HTTP 切斷自己 | key 20 只經 BLE(§3.1.2) |
| A4-m4 `n.mu` | 寫實:最長約 230 s(§3.1.6、§3.6、§3.11-9) |
| A4-m5 / B4-m8 `batman-slot` 新動詞 | `write`、`arm`、`disarm`、`bootcfg-sum`;`reboot committed`(§3.7.3) |
| A4-m6 pending 與上傳速率 | 最低速率 256 KiB/s(§3.8.1) |
| A4-m7 / B4-m11 arm 前斷電誤報 6 | `armed` 欄位 + `bad-slot` 證據才報 6,否則 0「沒有更新」(§3.7.4) |
| A4-m8 漏的生命週期列 | settings.set 中斷電、setkey 子程序、tmpfs 疊掛、firewall(§6、§3.8.2) |
| A4-m9 tmpfs 掛載選項 | `nodev,nosuid,noexec`、0700、`size=`、不疊掛(§3.8.2) |
| A4-m10 `E_UNSUPPORTED` 帶 reason | §3.1.8 |
| A4-m11 回應遺失 | session 中止、重新交握;協定 §4.2 同步改(§3.8.1、§5.2、§10) |
| A4-m12 / D19 `/cgi-bin/bundle` 對現役節點 | 照規格(使用者決定 D19);release note(§3.5) |
| A4-m13 / B4-m11 key 8 的分割與鎖 | `batman-slot bootcfg-sum` 在鎖內;arm 時再驗(§3.7.3) |
| B4-m1 kmod 是否需要 | 實作前實測(§9-4) |
| B4-m2 provd-stable 的身分 | v5:peer pid = procd instance(**錯,v6 改為 PPid,見附錄 B**) |
| B4-m3 ro 容量算式 | §2 表;provclient 最多 1 條、不與 app 讀取並行 |
| B4-m4 `settings.get` 的資料來源 | 背景設定快取(§3.3) |
| B4-m5 openmanetd 寫國家 | §3.3、§4 |
| B4-m9 上傳中被 reload 打斷 | 上傳窗開著時 reload 網路的動詞 `E_BUSY`(§3.1.7) |
| B4-m10 tmpfs `size=` 太緊 | 2 × 目前 payload(§3.8.2) |
| B4-m11 其他不一致 | v5 整份重寫 |

## 附錄 B. v5 審查回應(A5 = `p3-review-v5-A.md`、B5 = `p3-review-v5-B.md`)

v5 的三個「真機上不成立」都是沒實測的外部行為假設;v6 每一個都附了證據(F11、F69、F70)。

| 項 | 處理 |
|---|---|
| A5-M1 / B5-M1 `phy*-ap*` 不是萬用字元 | `iifname != "phy*"`(nft 只認結尾 `*`,F69);helper 驗證 bridge 上每個 `phy*` port 都是 radio0 的 AP,否則不給 `http.2`;`prov-http-254` 加正向斷言,負對照 = 以 v5 規則載入(§3.8.1、§8) |
| A5-M2 fw4 單一交易、reload 重複規則 | include 先 flush 自己的表;rc 驗收 `fw4 print \| nft -c -f -`(兩板);每次開機斷言 `inet fw4` 與 `batman_http` 都在(`prov-fw-boot-254`);負對照 `fw-badinclude`(§3.8.1、§6、§8);不需要 kmod(F60) |
| A5-M3 / B5-M2 provd-stable 的 pid | `PPid` = instance pid、uid 471、exe = `/usr/bin/batman-provd`(F11 改正:ujail 有 pid namespace);正向斷言「正常 provd → commit」,負對照 `provd-id-pid`(§3.7.6) |
| A5-M4 / B5-M4 legacy 改國家 | **使用者決定 D20**:legacy 上 key 2、20 一律拒絕;「未入網 → radio1 被封鎖」改為只對 `RadioManaged = true` 成立(F74) |
| A5-M5 / B5-m1 主路徑的矛盾 | §3.1.7、§5.1:窗擁有者的 prepare 是正常流程、同一擁有者重送 bulk.open = 延長、另一位擁有者 → `E_BUSY`;nft 檢查與槽資訊改為背景快取;`status` key 2–4 在 CDDL 改選填;update-last 只有 apply 寫;worker 失敗記在 helper 記憶體並優先;忙碌時間統一「約 4 分鐘」 |
| B5-M3 / A5-m1 `--rollback-only` 沒有契約 | 拿掉;逾時 = outcome unknown,app 重讀(與 P2 `net.apply` 相同);helper 重啟時 setkey 子程序自己跑完(§3.3、§6) |
| A5-m2 別人暫存的 `/tmp/.uci/wireless` | key 2、20 遇到非空 → `E_BUSY`(F73) |
| A5-m3 reason 17 的死路 | 同值 `settings.set` 在 p5 stale 時存檔(§3.3) |
| A5-m4 check 先寫 p5、沒有 helper 端額度 | 先驗簽;helper 全域 1 / 10 s(§3.7.4) |
| A5-m5 worker 子程序期限 | write 600 s、arm 60 s、bootcfg-sum 30 s;逾時的結果(§3.7.5) |
| A5-m6 舊的 bad-slot 造成假 6 | update-last 記 `bad_slot_at_apply`,只有變了才報 6(§3.7.4) |
| A5-m7 arm 拿不到 key 8 清單 | 清單檔當參數(§3.7.4) |
| A5-m8 CDDL 沒寫 sha 參數 | §10 |
| A5-m9 / B5-m7 負對照不分辨 | Go 接縫(`seam` 套件,只在 prov_test)、`p5-autosave-off`、`provd-id-pid`、`fw-badinclude`、轉賣工具 `--test-skip-wipe`;shell 接縫在所有 image 都在(root 旗標,與現況相同)— release gate 只斷言 Go 接縫(§8) |
| A5-m10 / B5 §9-5 | 關閉(F71) |
| A5-m11 poll 失敗 | 不 bind(§3.8.1) |
| A5-m12 / B5-m9 docker0 / lo | F58 改正;lo 的本機 DoS 列誠實界線(§3.8.1、§7) |
| A5-m13 改名在 U5 之前 | 繼續回 `rename-pending`(§3.3) |
| A5-m14 bootcfg-sum 拿不到鎖 | `E_BUSY`(§5.1) |
| A5-m15 key 20 密碼進 log | `prov-settings-254` 斷言 logread / log / 診斷包都不含 |
| B5-m3 新版沒開機成功報 0 | `rebooting` 欄位 → 6 + reason 18(§3.7.4) |
| B5-m4 pending 到期 | prepare 延長到 worker 結束 + 30 分(§3.7.4) |
| B5-m5 SSID 含 UNSAFE 字元 | 這個 key 不持久化、不算 stale,`status` 回報(§3.3) |
| B5-m6 worker 失敗的原因碼 | 依類別 1 / 11 / 12 / 17(§3.7.5) |
| B5-m8 操作員停用 provd | 只 WARN(§3.7.6) |
| B5-m10 `--ap -` 不在旗標清單 | 列入(§3.3、§5.3、§9、§10) |
| B5-m11 owner/remove 沒清上傳窗 | 一併清掉窗與 pending(§3.8.2) |
| B5-m12 tmpfs 常駐 | 窗外每個 poll 週期刪檔;checklist 加 2 GB TAK 節點(§3.8.2) |
| B5-m13 update-last 寫入時機 | 只有 apply 寫(§3.7.4) |
| B5-m14 CDDL 冪等欄位 | 註記保留、不使用(§10) |
| B5 §9-3 morse 實測失敗時 | 要重開 → 「寫入 + 要求重開」;連重開也不換 → 停用 key 2(§3.3、§9) |


## 附錄 C. v6 審查回應(A6 = `p3-review-v6-A.md` APPROVE-WITH-CHANGES、B6 = `p3-review-v6-B.md` REJECT)

| 項 | 處理 |
|---|---|
| A6-M1 bridge 的 `tcp dport` 看不到 VLAN 封裝 | 改成「bridge 層只替手機 AP port 的 frame 打 bit、inet input 沒有 bit 就丟 8095」;lo、VLAN、veth、mesh 都被丟;02 實測非 VLAN 部分(F75);VLAN 臂與正向等使用者在現場(D22、§9-4,含不成立時的出路) |
| B6-M1 key 2 的頻道檢查讓非美規國家卡死 | 刪掉「目前頻道在新國家合法」;頻道在 join 時由 setkey 驗(F79、§3.3);測試加 `DE` |
| B6-M2 / A6-m1 helper 死掉時 setkey 被 SIGPIPE 結束 | setkey `trap '' PIPE`、忽略輸出失敗;測試「commit 與讀回之間殺 helper」,負對照 = 沒有 trap 的 setkey(F77、§3.3、§8) |
| A6-m2 刪檔不釋放 provd 開著的 fd | 寫實:被入侵的 provd 可佔用到 `size=`;測試量 tmpfs 用量(§3.8.2) |
| A6-m3 舊的 `BATMAN-VERIFIED` | 不需要加 boot_id:phase 3 與 arm 都要求 pending 有效(tmpfs、同 boot_id),舊版 image 的寫者只會在另一次開機出現,pending 已不在 → 不會 arm 到別的內容 |
| A6-m4 / B6 update-last 寫者、格式、arm 參數、§9 編號 | 只有 `update.apply` 寫;§5.3 格式加 `bad_slot_at_apply`、`rebooting`;arm 一律 `arm <sha> <key8 清單檔>`;§9 重排 |
| A6-m5 / B6 update-last 的邊角 | apply 之後還沒重開(同 boot_id)→ 一律 disarm;`rebooting` 緊接在 reboot 之前寫,剩下毫秒級的界線寫明(§3.7.4) |
| A6-m6 / B6 F74 的證據 | 改正為 `node.go:539`(認領時就設 true) |
| A6-m7 `/tmp/.uci` 暫存讓 key 2 / 20 一直 `E_BUSY` | `status` 回報 `uci_staged`,app 提示(§5.1) |
| A6-m8 / B6 br_netfilter 已載入、`fw-badinclude` 的副作用 | 改寫(本設計不依賴也不受它影響);`fw-badinclude` 列破壞性副作用與還原(§6) |
| A6-m9 `.wbox-` 的例子錯 | 換例子;`+` 之後一律忽略(§3.7.1) |
| B6 `--ap -` 仍經 `uci set` 的 argv | setkey 用 `uci batch` 從 stdin 寫(F78);`/proc/*/cmdline` 以 10 ms 取樣(§3.3、§8) |
| B6 `phy*` 前提檢查的範圍 | 列出所有 bridge 的 port,綁 `default_radio0` section,ifname 也要符合(§3.8.1) |
| B6 setkey 的 rc 對應 | 新旗標的結束碼 0 / 2 / 3 / 4 / 5 與對應(§3.3) |
| B6 「≤ 4 s」 | 改為 ≤ 8 s(4 s 檢查 + 4 s poll) |
| B6 reason 7 一碼多用 | 新 19(只能經 BLE)、20(legacy 不支援);7 只留給硬體能力(§3.1.8、§5.1) |
| B6 `update.apply` 缺 reason 17、p6 沒掛 | 加 17;p6 沒掛 → `E_STORAGE`、不 arm |
| B6 worker 開 fd 與刪檔的順序 | 先開 fd 再關窗(§3.7.5) |
| B6 provd-stable 只看 ctl | 改為「provd 行程的任一條連線」(§3.7.6) |
| B6 國家測試分辨不出換表 | 使用者決定 D21:不做晶片端實測,寫成界線 |
| B6 key 20 的 plink 測試 | 改在已入網節點上量;確認 `wifi reload \|\| wifi` 退路沒被觸發(§8) |
| B6 include 用 delete table、`auto_includes` | 先刪再建;`auto_includes = 0` → 不給 `http.2`(§3.8.1) |


## 附錄 D. 凍結後的實作必做清單(v7 審查 MINOR;A7 = `p3-review-v7-A.md`、B7 = `p3-review-v7-B.md`)

每一項在實作 PR 裡修,並附一個「沒修會 FAIL」的測試;H4 照這份寫。動工前要先定的(★)在實作 PR 的第一個 commit 裡寫進 §3。

| # | 項目 | 來源 | 做法 |
|---|---|---|---|
| D-1 ★ | VLAN 臂的負對照:單層 VLAN 標籤在進 bridge 前就被剝掉(`dev.c:5528-5531`),v6 舊規則也丟得掉;真正能繞過的是外層 VID 0 的雙層標籤 | B7-m1 | §9-4 探針用 VID 0 / VID 0 雙層,並先證明 v6 規則放行它;F76 改寫 |
| D-2 ★ | §9-4 探針加看 bridge 鏈的 mark 計數器有增加(證明規則真的執行),並以正向臂證明 AP client 通過;若改用 §9-4 的備案規則 → 備案另做一次短審查,lo 那一列退回誠實界線 | B7 F75、B7-m2、A7-m11 | H4 凍結閘門,附原始輸出 |
| D-3 | 新共用資源:bit 24 與 `inet batman_http_in` 已列入 §4 / §5.3(v7.1);helper 檢查時順便確認 ruleset 裡沒有別人寫 bit 24 | B7-m3 | 檢查 + lint |
| D-4 | mesh 臂拆兩臂:偽造手機 MAC 只驗「連不上」(bridge 會把手機 MAC 學到 eth0,擁有者會被斷);「擁有者照樣傳完」改用不複製 MAC 的偽造流量;MAC 偽造造成的 DoS 寫進 §7 誠實界線 | B7-m4 | 改 §8 `prov-http-254` |
| D-5 ★ | setkey 新旗標的結束碼再細分:settle 逾時、run dir 不能用、`.txn` 存在 → 5(`E_BUSY`)或 12,不是 2 / reason 13 | B7-m5、A7-m6 | 結束碼表 |
| D-6 ★ | 新卡上「還原也驗證失敗」:專屬結束碼(例如 6)+ 加強處理:再以 `--forget` 式的封鎖把 AP 關掉並驗證不在空中;仍失敗 → CRIT、`status` 回報、reason 13 | B7-m6 | setkey + 測試 |
| D-7 | SSID 存不了時 `--save` 仍回 rc 6 → key 2 會被一律還原:helper 把「只有 ssid 不可存」的 rc 6 當成功;§3.3 引的 `batman-config-save:466(實作時 :465–466,原文 :478 已過時)` 行號改正 | B7-m7 | helper + 測試 |
| D-8 | 非 `phy*` port 的 frame 先清掉 bit 24(防 batman-adv `isolation_mark` 之類先設了這個 bit) | A7-m8 | 規則 + 測試 |
| D-9 | 「只因新 PRESERVE key 而 stale → 存一次」也在試用轉 committed 時做(sysupgrade 後第一次開機是試用,那次不會存) | B7-m8 | helper |
| D-10 | 同版本重試又失敗:比對 autocommit.log 新出現的 TRIAL-REVERTED,報 6 而不是 6 + 18;`reboot committed` 失敗時 disarm | B7-m9、A7-m4、A7-m5 | helper + 測試 |
| D-11 | `/proc/*/cmdline` 取樣測試分不出來(舊的 `uci set` 只存在 1–3 ms)→ 在 prov_test image 用記錄 argv 的 `uci` shim | B7-m10 | 改 §8 |
| D-12 | §3.4 key 15 加 `uci_staged` 與「SSID 無法保存」;§2 寫兩張表;`update.check` 不拿 `n.mu`(寫明) | B7-m11 | 文字 |
| D-13 | `phy*` 前提加「AP iface 是 br-ahwlan 的 port」(否則擁有者被默默丟掉、無從診斷) | B7-m12、A7-m9 | helper + `status` 回報 |
| D-14 | `batman-slot write` 被 TERM 殺掉時 `batman-slot.busy` 留下(busybox ash 非互動的 SIGTERM 不跑 EXIT trap,`ash.c:3707-3742`)→ `batman-slot` 加 `trap 'exit 143' TERM`,或 `.busy` 帶 pid、`otaBusy` 檢查持有者 | A7-m1 | 兩板共用檔 + 測試 |
| D-15 | bulk tmpfs 掛不上時不得退化成一般目錄(沒有 `size=` 上限)→ init 掛載失敗就不啟動上傳(helper 不開窗);路徑用 lstat、拒絕 `.` / `..` | A7-m2 | init + helper |
| D-16 | autocommit (a) 加「helper 被停用」的例外(只 WARN) | A7-m3 | autocommit |
| D-17 | autocommit `health_ok` 加「`inet fw4` 在」:否則帶著壞 include 的簽章 image 會在沒有防火牆的情況下被 commit | A7-m10 | autocommit + `fw-badinclude` 測試 |

## 附錄 E. v7.2 審查回應(A8 = `p3-review-v72-A.md`、B8 = `p3-review-v72-B.md`)

| 發現 | 處理 |
|---|---|
| A8-MAJOR-1 status 不綁嘗試 | §12.5.5(update-progress key 4/5、prepare 起寫 update-last、判讀順序、reason 22/23) |
| A8-MAJOR-2 結束碼不涵蓋 precheck-node | §12.5.2(node_checks 層、rc 16–18、reason 21) |
| B8-M1 照 SUMS 複製會蓋 autoboot.txt | §12.5.4(交集 + 明確拒絕 + 每列驗名) |
| B8-M2 / A8-m2 SIGKILL 留下 `.busy` 與掛載 | §12.5.3(`.busy` 帶 pid、EXIT 卸載、清死掉的掛載點) |
| A8-m1 tboot_open 重用掛載 | §12.5.1(單一掛載者 `bootinfo`) |
| A8-m3 6+18 界線 | §12.5.5(界線改正、`reboot committed` 失敗改回 rebooting) |
| A8-m4 / B8-m8 兩位擁有者、移除 | §12.5.6 |
| A8-m5 上傳語意 | §12.5.7 |
| A8-m6 串流 stdin | §12.5.8 |
| A8-m7 版本規則 | §12.5.9 |
| A8-m8 / B8-m1 / B8-m10 信任 T、gate、鑰匙檔 | §12.5.10(R_dev 替代方案待使用者選) |
| A8-m9 / B8-m11 已寫未啟用 | §12.5.13 |
| A8-m10 同時 sysupgrade | §12.5.14 |
| A8-m11 / B8-m6 tmpfs | §12.5.12 |
| A8-m12 / m14 契約補漏 | §12.5.15 |
| A8-m13 / B8-m12 負對照 | §12.5.16 |
| B8-m2 SO_MARK | §12.5.11 |
| B8-m3 8095 搶占 | §12.5.11 |
| B8-m4 rc 雜項 → 11 | §12.5.2 |
| B8-m5 bearer 規格 | §12.5.11 |
| B8-m7 tar 邊角 | §12.5.12 |
| B8-m9 DEV 上 check 搶鎖 | §12.5.10 |
