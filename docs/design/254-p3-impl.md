# #254 PR-P3:擁有者 / 設定 / 狀態 / 診斷 / 更新 / 上傳 / 轉賣工具(設計 v7.9 — S5 實作前核對 + 審查修正,審查中)

狀態:v7.9(2026-11-11)= v7.8 + v7.8 審查修正(A14 0 / 0 / 13、B14 0 / 1 / 8;回應見附錄 K;**更正**:附錄 J 說 flock 之後的舊文字已改,實際大部分沒改 —— v7.9 以 grep 逐處清掉),送兩位整份重審。v7.8 = v7.7 + v7.7 審查修正(A13 0 / 1 / 15、B13 0 / 1 / 5)+ 使用者選 A:一般開發版 image 不放根鑰匙、只有 bench build 放 T,發布檢查整套拿掉(回應見附錄 J),送兩位整份重審。v7.7 = v7.6 + v7.6 審查修正(A12 0 / 0 / 18、B12 0 / 1 / 6;鎖改用 `flock` 拿掉整組持有者規則;發布檢查搬到資產真正出去的地方;回應見附錄 I),送兩位整份重審。v7.6 = v7.5 + v7.5 審查修正(A11 0 / 1 / 15、B11 0 / 2 / 7,回應見附錄 H)與使用者三項決定(§12.5.18),送兩位整份重審。v7.5 = v7.4 + v7.4 審查修正(A10 0 / 3 / 17、B10 0 / 0 / 14;多數修法是拿掉機制,回應見附錄 G),送兩位整份重審。v7.4 = v7.3 + v7.3 審查修正(A9 0 / 2 MAJOR、B9 0 / 0;兩個 MAJOR 都是 v7.3 新機制帶進來的,v7.4 以拿掉機制修正)並把 §12 / §12.5 的決定**併回 §3.7 / §3.8**(回應見附錄 F),送兩位整份重審。v7.3 = v7.2 + **§12.5 審查修正**(v7.2 審查 A8 / B8 都 APPROVE-WITH-CHANGES、0 BLOCKER、各 2 MAJOR;回應見附錄 E),送兩位整份重審。v7.2 = v7.1 + **§12 S5 實作前核對**(事實更正與 8 項設計沒寫到的決定;只動 §3.7 / §3.8 / §3.11 的範圍),送兩位審查。v7.1 原狀態:**凍結**(v7.1,2026-11-02)。v7(bfb6703)兩位審查都 **APPROVE-WITH-CHANGES、0 BLOCKER / 0 MAJOR**(A 11 MINOR、B 12 MINOR),都判定已收斂、建議凍結。v7.1 = v7 + 審查要求「凍結時一起改」的文字修正(A7-m7);其餘 MINOR 是實作 PR 的必做清單(附錄 D,每項附測試)。**凍結條件**:§9-4 的現場探針在 H4 凍結前跑完並附原始輸出(D22)。歷程:v1 96a578d、v2 03963d9、v3 6433520、v4 5d5ebfd、v5 1ac5fbd(整份重寫)、v6 c252b3f、v7 bfb6703。各輪審查在 `docs/design/254-reviews/p3-review-v*-*.md`。
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
5. **長動作不拿 `n.mu`**(F37):`update.prepare` 只做檢查 + 啟動 worker 就回;worker 經 `batman-slot` 的鎖(F35)互斥;helper 記憶體旗標 `updating` 在 `update.prepare` 回應前設好(上傳窗在同一點關),`otaBusy()` 也看它。`diag.bundle` 的產生也在背景。
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

v7.4:本節已併入 v7.2 §12、v7.3 §12.5 與 v7.3 審查的所有決定;§12.5 只留索引與負對照表。

#### 3.7.1 鑰匙、簽章物件、版本規則(D4)

| 鑰匙 | 演算法 | 在哪 | 用途 |
|---|---|---|---|
| 根鑰匙 R(prod) | ES256 | 離線產生;私鑰只在兩支加密 USB(不同地點);公鑰內建 `rel` 通道 image 的 `/usr/share/batman/release-root.pub`,指紋另外釘在 Batman repo 與 app repo(§3.7.2) | 只簽背書 |
| 簽章鑰匙 K<sub>i</sub> | ES256 | 使用者的 YubiKey PIV slot 9c(裝置內產生、不可匯出) | 簽每個發行版本 |
| 測試根鑰匙 T | ES256 | repo `tests/keys/`(公開) | 只有 **bench build**(`BATMAN_BENCH_TRUST=T`,由 `build-board.sh --bench` 設;給 02 / 04 這類 bench 節點,含以 `--bench` 建的 prov_test)信任;一般 `wsl` / `ci` image(含一般 prov_test)不放任何根鑰匙;`rel` 只放 R(§3.7.2) |

一個 image 最多信任**一把**根鑰匙;沒有鑰匙檔 = 不能經 app 更新(reason 24)。ES256:所有 YubiKey 5 的 PIV 都支援;節點已有 `cose.VerifySign1` / `VerifyES256`(F22)。YubiKey 回 DER 簽章,`release-sign.sh` 轉成 64 B `r‖s`(low-s)。⚠️ YubiKey 型號與 host 工具鏈待使用者在場時實測(§9)。

- **背書** E<sub>i</sub> = COSE_Sign1(根鑰匙),content type `batman/relkey`,標籤 `batman-relkey-v1`,payload `{1: K_i 公鑰 65 B, 2: serial(uint ≥ 1)}`。
- **發行物件** S = COSE_Sign1(K<sub>i</sub>),content type `batman/release`,標籤 `batman-release-v1`;payload 的 key 與 `update-manifest` 同號:

| key | 欄位 | 用途 |
|---|---|---|
| 1 | version(`BATMAN_VERSION` 全串) | 版本規則 |
| 2 | board(`/etc/batman-build` 的 `BATMAN_BOARD` 全串,例 `ekh-bcm2711`;provd 去掉 `ekh-` 的短字串只用於顯示,`cmd/batman-provd/main.go:81`) | = 本機 board |
| 3 | payload 大小(bytes,壓縮後的 `.tar.gz`) | 上傳大小、RAM 預算 |
| 4 | sha256(`SHA256SUMS`) | 綁定內容 |
| 6 | `[* tstr]`:可以從這些版本降回(或跨通道換成)本版 | 防降級 |
| 7 | min_from:目前版本必須 ≥ 它 | 不符 → reason 4 |
| 8 | `[* sha256]`:本版可用的開機設定(`config.txt` ‖ `distroconfig.txt` 的 sha256);省略 = 不檢查。比對**目標槽** boot 分割上的檔(F56)。`92-batman-ramoops-fix` 會在一個槽第一次開機時改它的 `distroconfig.txt`(`:19-40`;uci-defaults,helper 啟動前、鎖外,是唯一另一個 boot FAT 寫者)→ 清單要同時列改前與改後的 sha | 不符 → reason 5 |
| 9 | 所有 `boot/` 成員的大小總和(bytes) | 解析上限、RAM 預算 |

- `update-manifest` key 5(`bstr`)= CBOR `[E_i, S]`(兩個 bstr);manifest 的 1–4、6 必須等於 S 的同號欄位,否則 reason 11。**格式契約以 harness 的 `tests/tools/peer/signrel.py` 為準**(測項只有一套;產品要不同,先改 harness)。
- **鑰匙檔格式**(image 內 `/usr/share/batman/`;helper **只讀 `/rom/usr/share/batman/`**(squashfs,唯讀):overlay 上的同名檔不算,root 或操作員在執行期放的檔不會讓一般 image 開始信任它;`/rom` 不存在 → reason 21;⚠️ 上機確認 A/B 節點有 `/rom/usr/share/batman`):`release-root.pub` = 一行、130 個小寫 hex = 非壓縮 P-256 點(`04‖X‖Y`),解碼後必須在曲線上(現行 `tests/keys/T.pub` 就是這個格式);`release-min-serial` = 一行、`^[1-9][0-9]{0,9}$`。缺檔 → reason 24(這個 image 不能經 app 更新);多行、格式不對 → reason 21,**不預設成 0**。
- **撤銷**:serial 小於 `release-min-serial` 的背書被拒。K<sub>i</sub> 外流 → R 背書 K<sub>i+1</sub>,發一版 `min-serial = i+1`。**界線**:沒更新到那版的節點仍接受 K<sub>i</sub>(無線上撤銷);經 key 6 降到較舊版本後,舊 image 的 `min-serial` 較低,已撤銷的 K 又會被接受。只有根鑰匙出事才要重燒。
- **版本規則**:版本字串 = `REL[-CH.N][+meta]`(`stamp-batman-build.sh:57` 一律產生 `REL-CH.N+…`;`docs/VERSIONS.md:14` 的無後綴出貨形式也接受),REL = `X.Y.Z`,CH ∈ {`wsl`, `ci`, `rel`},N 是**每個通道各自數**的 build 號;`+meta`(含 `.dirty`、`.wbox-*`)一律忽略。

| 目前 → 新 | 判定 |
|---|---|
| REL 不同 | 依 REL 數值比:大 = 升級;小 = 降級,要 key 6 列出目前版本(去掉 `+meta`) |
| REL 相同、CH 相同 | 依 N 比:大 = 升級;相等 = **重裝,允許**;小 = 降級(同上) |
| REL 相同、一邊沒有後綴(正式出貨形式) | 正式 > 任何 `-CH.N`(D12);正式 → 開發要 key 6 列出目前版本 |
| REL 相同、CH 不同 | 沒有順序(N 各通道自己數)→ 只有 key 6 列出目前版本才允許 |
| 解析失敗 | reason 11 |

  key 7(min_from)用同一規則比;與目前版本沒有順序 → reason 4(fail-closed)。

  **界線**:`+meta` 忽略 → 同號的 wbox(帶 Go 接縫)與乾淨版相等;wbox 永不 commit(`batman-slot:802`),裝上去只會試用後退回。

#### 3.7.2 build / 發行端

- `scripts/build-ab-payload.sh`:tar 順序改為 **`SHA256SUMS metadata boot root.squashfs`**(現在是 `root.squashfs boot metadata SHA256SUMS`,`:73`;F27);`metadata` 加 `release=<BATMAN_VERSION>`(`version=` 時間戳不動)。sysupgrade 路徑以名字取成員,與順序無關(F57)。**界線**:P3 之前建的 payload 不能經 app 安裝(Go 解析要求 `SHA256SUMS` 是第一個成員),包括經 key 6 降到 P3 之前的版本 → 只能 ssh sysupgrade。現行兩板 payload 的 SUMS 只列 kernel、start、fixup、dtb 與 overlays(bcm2711 361 列、bcm2710 364 列,約 35 KB),SUMS 上限定 256 KiB。
- **誰把哪把根鑰匙放進 image**:firmware `scripts/stamp-batman-build.sh`(寫 `/etc/batman-build` 的同一步)依下表放 `files/usr/share/batman/release-root.pub` 與 `release-min-serial`(兩個都加進 firmware `.gitignore`,否則每次 build 都變 DIRTY;`BATMAN_CHANNEL` 必須 ∈ {`wsl`, `ci`, `rel`},否則 stamp 失敗 —— 現在只檢查非空,`stamp-batman-build.sh:23-24`):

  | build | 放什麼 | 經 app 更新 |
  |---|---|---|
  | `rel` | `keys/release-root.pub` = R 與 `keys/release-min-serial`(#255 產生前不存在 → `rel` build 失敗) | 可以(R → K 簽) |
  | `wsl` / `ci` + bench(`build-board.sh --bench`,只給 02 / 04 這類 bench 節點與要經 app 更新的 prov_test 節點) | Batman feed 釘選 commit 的 `tests/keys/T.pub`、min-serial 1;`/etc/batman-build` 寫 `BATMAN_BENCH_TRUST=T` | 可以(T → K_test 簽) |
  | `wsl` / `ci`(一般) | 不放 | 不行:`update.check` 回 reason 24;只能 ssh sysupgrade / 重燒 |

  **bench 旗標只從 `build-board.sh --bench` 參數來**(和 `-wbox` 一樣,`wbox_env_reset` 先 unset 環境變數,r1 A-M2);值只收 `T`;`batman-release.env` 裡出現 `BATMAN_BENCH_TRUST` → stamp 失敗;`rel` + bench → stamp 失敗;版本字串加 `+… .bench` 以便分辨;stamp 先 `rm -f` 兩個鑰匙檔再依表放(它們在 `.gitignore`,不刪就會沿用上一次 bench build 的 T)。**結果**:不小心公開發布的一般開發版沒有「任何人都能簽」的風險(使用者 2026-11-11 選 A,取代「R 產生前不發公開 release」)。
- **release gate** = 獨立腳本 `scripts/check-release-key-gate.sh`(放在 Batman repo,firmware 經 `feeds/batman/` 呼叫同一支;image 組好之後),由 `build-board.sh` 第 7 步**與** `.github/workflows/build-firmware.yml`(和 `check-prov-test-gate.sh` 同一段,`:227-230`)各自呼叫 —— CI 的出貨路徑 `build-release.yml` → `build-firmware.yml` 不經 `build-board.sh`:
  - `rel`:`release-root.pub` 的指紋必須等於 Batman repo `scripts/release-root.fpr` 釘的 R 指紋,`release-min-serial` 合格式;釘選檔不存在(R 產生前)→ FAIL(R 之前不出 `rel`)。
  - bench build:`release-root.pub` 必須等於 T,且 stamp 有 `BATMAN_BENCH_TRUST=T`;一般 `wsl` / `ci`:不得有 `release-root.pub`。**CI(`build-firmware.yml`)遇到任何 bench build 一律 FAIL**:`build-release.yml:251-262` 會自動把 `*.img.gz` 發成公開 release,不經 `release-sign.sh`(B14-MAJOR-1)。
  - 負測試:`rel` + T.pub → FAIL;`rel` 沒有釘選檔 → FAIL;`rel` + `BATMAN_BENCH_TRUST` → FAIL;一般 `wsl` 放了任何鑰匙 → FAIL;bench build 放了 T 以外的鑰匙 → FAIL;`batman-release.env` 含 `BATMAN_BENCH_TRUST` → stamp FAIL;CI 建 bench → FAIL;同一棵樹先 bench 後一般 build → 一般 image 沒有鑰匙檔。
  - **界線**:能同時寫 Batman 與 firmware repo 的人可以一起換掉鑰匙與指紋 → gate 擋的是我們自己的錯,不是被入侵的 repo;app repo 另外釘同一個指紋(第二道,不同 repo)。
- **簽章**:`rel` 用 `scripts/release-sign.sh <payload>`:讀 `SHA256SUMS` / `metadata` / 開機設定清單,組 S,用 YubiKey 簽,與 `release-keys/relkey-<i>.cbor` 寫成 `<payload>.sig.cbor`;**拒絕簽** `BATMAN_WBOX` 或 `BATMAN_BENCH_TRUST` 非空、版本含 `.wbox-` 或 `.dirty`、通道 ≠ `rel` 的 build(讀 stamp 時就停),並在要簽的那份 payload 的 squashfs 上(`unsquashfs -cat`)重跑 stamp 檢查、`check-release-key-gate.sh` 與 prov-test gate(避免用 K 簽出內建 T 的 `rel` image)。`release-endorse.sh`(離線用 R,換鑰匙時)。bench build 用 harness 的 `signrel.py` 以 T → K_test 簽;`signrel.py` 預設拒簽 image 裡沒有 T 的 payload(否則 bench 節點經 app 裝了一般 image 就只能 ssh 回來),要簽必須 `--allow-no-key`(harness PR)。發行流程加這兩步與轉賣工具清單(§3.9)。
- **DEV → PROD 的出口**:R 產生之後(#255),bench 節點要換信任,只能用一份 **T 簽、內建 R(不再含 T)的過渡版**,或 ssh sysupgrade / 重燒。02 / 04 目前都是 `wsl` 通道(之後以 bench build 燒;一般 DEV 節點沒有鑰匙,只能 ssh / 重燒)。過渡版的通道是 `rel`(內建 R,gate 要求 `rel`),用 `release-sign.sh --test-key` 簽(全部檢查照跑:dirty / wbox / 通道 / 在 payload 上重跑 gate,只把簽章換成 T → K_test 的軟體鑰匙)—— 它是所有 PROD 節點的起點,不能跳過檢查;它的 REL 與節點現行 DEV 版相同時是跨通道 → S key 6 要列出那個 DEV 版本。
- **公開發布**:不另設檢查(使用者 2026-11-11 選 A):一般開發版不含根鑰匙,公開了也不能經 app 更新;bench build 不得公開發布(stamp 有 `BATMAN_BENCH_TRUST=T`,`release-sign.sh` 拒簽)—— 有人手動把 bench image 公開仍擋不住,列 §7 誠實界線。

#### 3.7.3 `batman-slot`(兩板共用)

**新動詞**(都加進 `detect_layout` 的 dispatch,`:895-898`;寫入的 `write` / `arm` / `disarm` 加進 TRACE,唯讀的 `bootinfo` 不加):

| 動詞 | 做什麼 |
|---|---|
| `write <dir>` | `<dir>` = helper 驗過的 `SHA256SUMS`、`metadata` 與 `boot/`;rootfs 從 stdin 串流(只有 rootfs 的 dd 讀 stdin,其他子程序一律 `</dev/null`)。照 `stage-root` 的順序(`:650-657`):`slot_lock` → `precheck`(`:592-641`:`node_checks`、刪 `autocommit-skip-once`、squashfs + 64 MiB 放得進目標槽(`SQ_BYTES` 取自 `metadata size=`)、Pi 3 韌體允許清單)→ `begin_write`(disarm、invalidate、刪 `BATMAN-VERIFIED`)→ **`clear_root`**(清 overlay 窗;否則同版本重裝時 fstools 在同一位置找到上次試用的 overlay 就沿用,`rootdisk.c:120-136`,96 / 92 不再跑,讀回也抓不到)→ 從 stdin dd → 複製 boot 檔 → 讀回驗證(`:592-714`)→ 寫真 cmdline、清 BAD → 寫 `BATMAN-VERIFIED` = `<sha256(SHA256SUMS)> <本次 boot_id>`;**不 arm** |
| `arm <sha> <key8 清單檔>` | 重跑 `node_checks`;確認無 `BATMAN-BAD`、cmdline 正確、`BATMAN-VERIFIED` = `<sha> <本次 boot_id>`(別次開機寫的不算 —— 擋 P3 之前的 `batman-slot` 不刪 VERIFIED 的殘留)、開機設定在 key 8 清單(空 = 不檢查);再 arm + 讀回(`:716-738`) |
| `disarm` | 拿鎖;清 tryboot 旗標(包現在的內部 `disarm_tryboot`,F64) |
| `bootinfo <A\|B>` | 拿鎖;ro 掛該槽 boot 分割(p1 直接讀 `/boot`);**stdout** 正好依序印:`verified=<64 hex> <boot_id>` 或 `verified=-`、`bad=0\|1`、`bootcfg=<sha256(config.txt ‖ distroconfig.txt)>`、`--`、`distroconfig.txt` 全文;卸載、放鎖。`config.txt` / `distroconfig.txt` 缺或 > 64 KiB(`head -c 65537` 判斷)→ rc 18 |
| `apply`(既有) | = `write` + `arm`;sysupgrade 路徑行為不變 |

**boot 分割只有 `batman-slot` 掛**(產品端):`tboot_open` 只重用 `/boot`(p1 的正常掛載);目標分割(以 major:minor 比對)在 `/boot` 以外的地方被掛著 → rc 14,**不卸載別人的掛載**。helper 以 `SysProcAttr.Unshareflags = CLONE_NEWNS` 執行 `batman-slot` 的 `write` / `arm` / `disarm` / `bootinfo` / `precheck-node`(`precheck-node` 被殺時會留下 p5 的 ro 掛載,`:556-572`,之後 config-save 的 rw 掛載失敗 → 也進 namespace;`reboot committed`、`is-trial` 照舊在 init namespace:`reboot committed` 的 240 s 安全網不能把 namespace 留到關機期間,`:885`;Go 會把 `/` 設成 rprivate,go1.26 `syscall/exec_linux.go:473-478`)→ 它被 KILL 時掛載隨 namespace 消失,不會殘留;寫進 `/boot`(p1)仍是同一個檔案系統。操作員或 sysupgrade 執行中被殺留下的掛載 → rc 14,直到操作員卸載或重開(§6)。副作用:superblock 跨 namespace 共用,helper 的 `write` rw 掛著目標 FAT 時,init namespace 的 ro 掛載會 EBUSY → boot FAT 的讀者一律經 `bootinfo` 或在鎖內;其他 namespace(特權容器)的掛載 major:minor 檢查看不到 → 只有 root 做得到,列 §7。namespace 裡的 p5(ext4)、p7 掛載 init namespace 也看不到;同一 superblock 上 ro / rw 並掛會 EBUSY,與現在在 init namespace 時相同(暫時性)。「目標分割在別處被掛著」的檢查在 `precheck` 就做(`begin_write` 之前),所以 rc 14 只會在目標槽被動到之前出現。被 KILL 時留下的空 `/mnt/slotboot.<pid>` 目錄無害,重開前不清。helper 不再自己掛 FAT(§3.7.4)。harness 仍有鎖外的掛載(`ab-selftest.sh:73,75`、`eh13-pre-254.sh:55,62`、`prov-chain0-254.sh:22`)→ harness PR 改成在鎖內或用 `bootinfo`(#290)。

**複製的 boot 檔** = `SHA256SUMS` 列出的 ∩ 現行類別白名單(`kernel8.img`、`start*.elf`、`fixup*.dat`、`*.dtb`、`overlays/*`,`:677-683`);「NEVER `bootcode.bin` / `autoboot.txt`」不變。`SHA256SUMS` **每一列**都要符合 `^(root\.squashfs|boot/[A-Za-z0-9_-][A-Za-z0-9._-]*|boot/overlays/[A-Za-z0-9_-][A-Za-z0-9._-]*)$`;名字轉小寫後是 `autoboot.txt`、`config.txt`、`distroconfig.txt`、`cmdline.txt`、`bootcode.bin` 或以 `batman-` 開頭 → rc 13;轉小寫後重複的名字(FAT 不分大小寫)→ rc 13。helper 端做同樣的檢查(reason 11)。sysupgrade 也受益。

**鎖 = `flock`**(取代現行 mkdir 鎖 `:84-95`、`.busy` 檔 `:155`,以及 v7.4–v7.6 的持有者規則):每個動詞(`write`、`arm`、`disarm`、`bootinfo`、`apply`、`stage-root`、`commit`、`rollback`、`precheck-node`)開頭 `exec 9>>$RUNDIR/batman-slot.flock`(root 0600,RunDir root 0700)+ `flock -n 9`:先 `command -v flock || exit 18`;拿不到時 `sleep 1` 重試 3 次(照 `halow-setkey:152-155`;target busybox 沒開 `CONFIG_FLOAT_DURATION`,`.config:88`,`sleep 0.2` 會直接失敗 —— A14 以 qemu 實跑證實;busybox flock 也沒有 `-w`),仍拿不到 → rc 14。fd 9 由子程序繼承(`dd` 等):**持有者與它所有子程序都結束,kernel 才放鎖** —— 只殺掉 shell、`dd` 還在寫時鎖仍在。沒有 pid / starttime / zombie / 接手 / TAMPER 判斷:行程死了鎖就沒了,原子、不可能兩個寫者,`sh -x` 或別的路徑跑的副本照樣互斥。「寫入進行中」(現行 `.busy`)= 這把鎖被持有:讀者(Go `otaBusy` `node/wtxn.go:450-454`、autocommit `:226` 的 `.busy` 與 `slot_writer_alive`,後者也被 `:213` 的認領接手與 `:550` 使用)以**共享**鎖試拿(shell:`[ -e $LOCKF ] && { exec 8<$LOCKF; flock -s -n 8; }`,用 fd 形式 —— `flock FILE` 會以 0666 建檔,`flock.c:53`;Go `syscall.Flock(LOCK_SH|LOCK_NB)`)、拿到立刻放 → 拿不到 = 忙(試拿的瞬間寫者多等一下,由寫者的 3 s 重試吸收);鎖檔不存在 = 開機後沒有寫者 = 不忙;開不了(權限等)= 忙 + log(fail-closed);`bootinfo` 持鎖的短時間也會讓 `otaBusy` 回忙 → `E_BUSY`(可重試)。`busybox flock` 已在兩板 build 的 rootfs(`/usr/bin/flock` → busybox;⚠️ 節點上待確認)。EXIT trap 加 `tboot_close`;加 `trap 'exit 143' TERM`。持鎖期間起的背景子程序(例如 `commit` 的 `addr_defer_release` `setsid /etc/init.d/openmanetd start &`,`:781`)一律 `9>&-`,否則它繼承 fd 9、`commit` 回來後鎖還在;lint 檢查持鎖動詞裡每個背景 `&`(排除 `&&`、`2>&1`、`$(( ))`)、`setsid`、`nohup`、`start-stop-daemon`、`/etc/init.d/* start` 都有 `9>&-`;另加通用測試:每個持鎖動詞回來後 1 s 內 `flock -n` 拿得到。`reboot committed` 不開 fd 9。升級 / 降級:新舊 `batman-slot` 不會在同一節點同時跑(sysupgrade stage 2 用的是執行中 image 的那支)。**sysupgrade stage 2 在 ramfs 裡跑**,ramfs 只有 stock 清單加 `RAMFS_COPY_BIN`(firmware `lib/upgrade/stage2:39-55`、`platform-ab.sh:38`),busybox 沒開 `SH_STANDALONE`(`.config:1198`)→ `RAMFS_COPY_BIN` 加 `/usr/bin/flock`;否則每次 ssh sysupgrade 都 rc 18 失敗、重開回舊槽(同類事故:#89 ramfs 缺 `tr`,`platform-ab.sh:24-30`);harness 的舊版副本只跑 `precheck-node`(唯讀)。app 的 `write` 在跑時,sysupgrade stage 1 的 `precheck-node` 拿不到鎖 → 拒絕;`-F` 照舊可強制。

**結束碼**(定義在 `node_checks` 層,所有動詞共用;既有呼叫者只看 rc ≠ 0:`platform-ab.sh:184-186,364-366,375-379`、`daily-validation.sh:2068`、`chain1-254.sh:220`;`is-trial` 的 `DIE_RC=2` 不變):

| rc | 意思(`batman-slot` 行號) | helper 對應 |
|---|---|---|
| 0 | 成功 | — |
| 10 | 試用中(`:545`) | reason 1 |
| 11 | 有 `.txn`(`:498`、`:525`) | reason 12 |
| 12 | p5 不新鮮 / 身分不符 / 沒有新鮮的 stage-1 判定(`:502-505`、`:529`、`:531`) | reason 17 |
| 13 | 內容、讀回、`BATMAN-VERIFIED` 不符;SUMS 名字不允許(`:601-618`、`:705`) | reason 11 |
| 14 | 另一個 `batman-slot` 持 flock;config-save 在跑(`:506`);目標分割(major:minor)在 `/boot` 以外被掛著(`write` / `arm` / `bootinfo` 都適用);上一個 helper 的孤兒 `write` 仍持 flock(新 worker 建 boot 目錄前先試拿鎖,拿不到 → `E_BUSY`) | `E_BUSY`(可重試) |
| 15 | 開機設定不在 key 8 清單 | reason 5 |
| 16 | p5 未 seed(`:574`) | reason 2 |
| 17 | 韌體開錯槽(`:249`、`:539`) | reason 21 |
| 18 | 卡片 / layout / 掛載不健全(`:177-180`、`:196-199`、`:242`、`:510-514`、`:584-588`、`bootinfo` 缺檔) | reason 21 |
| 其他、逾時(124)、exec 失敗(127)、被殺(137 / 143) | 內部錯誤 | reason 21 |

reason 21(新)=「節點端現在無法寫入槽」,log 帶 rc;**reason 11 只留給雜湊 / 簽章 / 版本解析不符**。重開用既有的 `batman-slot reboot committed`(tryboot 旗標在時它自己走一般重開,F64)。

#### 3.7.4 helper:動詞、序列化、狀態

**序列化**:helper 對 `batman-slot` 的所有呼叫(worker 的 `write`、apply 的 `arm`、`disarm`、`bootinfo`、`precheck-node`;`update.apply` 從 arm 到寫好 `rebooting` 全程持有)都經過**同一個 mutex `slotMu`**;update-last 與 pending 的所有寫入經過 `updMu`(讀-改-寫在鎖內),update-last 以 tmp → fsync → rename → fsync(目錄)寫。health tick 以 TryLock 取 `slotMu`,拿不到就跳過這一輪(不在 `write` 的 600 s 期間阻塞)。

**槽資訊快取**:helper 對兩槽跑 `bootinfo`,只在:啟動時、自己的 `write` / `arm` / `disarm` 之後、`update.check` 時(目標槽)、上一次拿到 rc 14(60 s 後重讀,例如前一個 helper 的孤兒 `write` 還持鎖)或輸出壞掉 / rc 18(最多每 10 分鐘重試一次)。**不定期跑**。`bootinfo` 只解析 stdout(`ExecReader` 分開 stdout / stderr);header 每行正好一次、在 `--` 之前、hex 格式對,否則當作讀不到。`bootConfigOK`(`main.go:713-733`,原本每 15 s 在鎖外 ro 掛 p3)改用這份快取,同一個 `sectionOK` 規則;本次開機從沒讀到 → false。

| 動詞 | 做什麼 | 拒絕 |
|---|---|---|
| `update.check {1: manifest}` | 1. 驗 E(image 唯一的根鑰匙)、serial ≥ min、S — **先驗簽,通過前不寫任何東西**;簽章驗證結果可依**整份 manifest bytes 的 sha256** 快取(與節點狀態無關),其他每次都重跑;2. 若 p5 stale 只因 P3 新 PRESERVE key → `--save` 一次(§3.3);3. `batman-slot precheck-node`;4. board、版本規則、key 7、key 8(目標槽 `bootinfo`);5. RAM 預算;6. 在 `updMu` 內寫 **pending**(`/tmp/run/batman/update/pending`,helper RunDir root 0700,`{S, owner_key_id, boot_id, 到期 = uptime + 30 min}`)。**helper 端額度**:全域 1 / 10 s | `{1: false, 2: reason, 3: RAM}`:reason 1、2、3、4、5、6、8、11、12、17、21、24;`E_BUSY`:worker 在跑、上傳窗開著、或有效的 pending 屬於另一位擁有者(同一位擁有者在沒有窗 / worker 時 → 覆寫) |
| `update.prepare {1: sha}` | sha = pending 的 key 4;呼叫者 = 上傳窗擁有者;上傳檔存在且大小 = key 3;寫 update-last 的**嘗試紀錄**(失敗 → `E_STORAGE`,不啟動);清掉記憶體裡上一次的失敗;啟動 worker,立刻回 phase 2;pending 到期延到 worker 結束 + 30 分 | 無 pending / sha 不符 / 上傳不完整 → reason 15 |
| `update.apply {1: sha}` | 呼叫者 = pending 的擁有者、沒有 worker 在跑、pending 有效且 sha 相同、目標槽 `verified` = `<sha> <本次 boot_id>`(看槽,不看 helper 記憶體);**拿到 `slotMu` 之後、arm 之前**寫 update-last `{apply_boot_id = 本次開機, aclog_off = autocommit.log 目前大小, rebooting: false}`(= 已開始 arm;失敗 → `E_STORAGE`,不 arm)→ `batman-slot arm <sha> <key8 清單檔>` → rc 0 時**立刻**寫 `rebooting: true`(寫不進 → `disarm`、回 0 後清 `apply_boot_id`、回 `E_STORAGE`,不重開;寫進了才回應;否則回應後到重開之間被別的東西重開、試用 panic,會報 23 而不是 6 + 18)→ 回應後 2 s `batman-slot reboot committed`(在 init namespace);arm 回非 0 → `disarm`,回 0 後才清掉 `apply_boot_id`;`reboot committed` 失敗 → `disarm`、寫 `rebooting: false`、清掉 `apply_boot_id`。apply 之後 `owner/remove` 不取消(擁有者已同意) | reason 15;arm 失敗依 §3.7.3 結束碼 |
| `update.status`(ro) | 見下 | — |

**update-last**(p6 `/opt/batdata/state/update-last`,root 0600):CBOR `{0: format = 1, sha, from_slot, from_version, to_slot, to_version, apply_boot_id, aclog_off, rebooting}`;未知 format / 壞 → 當作沒有。寫者 = helper(`update.prepare` 寫嘗試紀錄、`update.apply`、`reboot committed` 失敗)。保留到下一次 `update.prepare` 覆寫。

**disarm 的 tick 規則**(helper 啟動時與之後每個 tick 都套用):update-last 的 `apply_boot_id` = 本次開機、`rebooting` 為 false、而且 `slotMu` 沒有被 `update.apply` 持有 → `batman-slot disarm`;回 0 之後才清掉 `apply_boot_id`(清不掉 —— p6 唯讀 —— 就在記憶體記「本次開機已 disarm」,不再重跑,避免取消操作員之後手動的 apply),回 14 → 下一個 tick 再試。涵蓋:helper 在 apply 中 crash(沒斷電)、arm 失敗後 disarm 回 14。`update.apply` 從 arm 到寫好 `rebooting` 全程持 `slotMu` → tick 不會在中間取消擁有者的 apply。操作員手動 `apply`(沒有 `apply_boot_id`)不受影響。斷電後是新的開機,tryboot 旗標本來就沒了(⚠️ 依 Pi 公開行為推論,未量測)。**界線**:已寫 `rebooting: true` 而 helper 在呼叫 `reboot committed` 之前掛掉 → 旗標保持 arm、沒有重開;下一次任何重開會進試用(擁有者已同意的版本);status 在 pending 有效時報 3(app 可再 apply 觸發重開),pending 到期後報 23。

**判讀**(`update.status` 只讀快取;依序取**第一個**成立的;每個 phase 都帶 `4: sha`、`5: to_version`,取自 pending 或 update-last):

| # | 情況 | phase |
|---|---|---|
| 1 | 上傳窗開著 | 1(百分比 = provd 經 poll 回報的已寫 bytes / key 3) |
| 2 | worker 在跑 | 2(百分比) |
| 3 | 記憶體裡有失敗結果,且它的 sha = 目前 pending 的 sha | 0 + reason |
| 4 | pending 有效且目標槽 `verified` = `<pending sha> <本次 boot_id>` | 3 |
| 5 | update-last 缺 / 壞,或目前槽版本 ∉ {from_version, to_version} | 0 |
| 6 | 目前槽 = `to_slot`、版本 = to_version、`is-trial` | 4 |
| 7 | 目前槽 = `to_slot`、版本 = to_version、已 commit | 5 |
| 8 | 目前槽 = `from_slot`、`apply_boot_id` 有值且 ≠ 本次開機:讀 autocommit.log 從 `aclog_off` 之後的行 —— 有 `COMMITTED` 或 `COMMITTED-BY-OPERATOR` 且 `slot=<to_slot> version=<to_version>` → 0(曾 commit,之後被操作員 / fallback 換回);有 `TRIAL-REVERTED … slot=<to_slot> version=<to_version>` → 6;都沒有且 `rebooting` → 6 + reason 18;都沒有且沒有 `rebooting` → 往下 | 見左 |
| 9 | 目前槽 = `from_slot`、目標槽 `bad=1` | 0 + reason 22 |
| 10 | 目前槽 = `from_slot`、目標槽 `bad=0`、`verified` 的 sha = update-last 的 sha | 0 + reason 23 |
| 11 | 其他 | 0 |

- reason 18 =「新版沒有完成試用(沒開機,或試用中斷電 / 卡住 / 重開)」:涵蓋 `rebooting` 寫入之後到試用結束前的任何中斷,包括 procd 關機(tryboot 旗標已 arm 時 `reboot committed` 走一般 `reboot`,沒有 240 s 安全網,`batman-slot:878-881`)。
- reason 22 =「上次寫入沒有完成,另一槽(退路)已失效,需要再更新一次」;reason 23 =「新版已寫入但沒有啟用,請重新更新」。
- autocommit.log 只有 autocommit 與 95(`FW-OVERRIDE` 行)寫、只追加(`batman-autocommit:65`;`95-batman-storage:460-483`);helper 從 `aclog_off` 起最多讀 1 MiB(`O_NOFOLLOW`),逐行以空白切欄:時間戳之後的第一欄**整個等於** `COMMITTED`、`COMMITTED-BY-OPERATOR` 或 `TRIAL-REVERTED`,且 `slot=`、`version=` 兩欄**整個相等**(`NOT-COMMITTED` 不算;`version=1.5.14-wsl.2` ≠ `…-wsl.25`);檔案比 `aclog_off` 短 → 當作沒有紀錄。
- 寫到一半斷電 / helper 重啟 / worker 被中止:`begin_write` 已讓目標槽 BAD → 第 9 列。worker 在 `begin_write` 之前就失敗:目標槽沒動 → 第 11 列 0。worker 成功但 helper 在 apply 前掛掉、pending 到期:第 10 列 23。arm 開始後、`rebooting` 寫入前斷電:新的開機、tryboot 旗標已消失 → 第 10 列 23;同一段 helper crash(沒斷電)→ 啟動時 disarm → 第 10 列 23。
- **「已寫入、未啟用」**(第 10 列)的目標槽是可開機的有效槽:若之後 `from_slot` 開不起來,韌體 #133 fallback(`p_req` 0)會開進它,autocommit 會在健康時 commit 它(`batman-autocommit:352-369`)。它有簽章、讀回過,擁有者在 prepare 時同意過 → 不是越權,誠實界線(包括之後被移除的擁有者寫入的版本)。

- `status` key 15 加 `trust` = image 內根鑰匙(`/rom`)sha256 指紋的前 8 bytes(hex);沒有鑰匙 = `none`、壞掉 = `bad`。app 依它顯示「這個版本不能經 app 更新」,或 bench 的「測試信任」橫幅;bench image 外流到現場時看得到(B14-m4)。

**RAM 預算**:`MemAvailable` − 64 MiB ≥ payload 大小 + boot 總大小(key 9);上傳目錄的 tmpfs `size=` 也要 ≥ payload 大小(否則 reason 8)。worker 用串流,不把 payload 讀進記憶體(§3.7.5)。

#### 3.7.5 worker:驗證、寫入(不 arm)

1. 以 `O_RDONLY|O_NOFOLLOW|O_NONBLOCK` 開上傳檔(`O_NONBLOCK` 防 FIFO 卡住);fstat:regular、link count 1、uid 471、大小 = key 3;通過後清掉 `O_NONBLOCK`,**立刻 `unlinkat(dirfd, "payload")`**,接著 `fchown(fd, 0, 0)`、`fchmod(fd, 0400)`(provd 的 jail 沒有 `/proc`,`batman-provd.init:19`;權限改掉是第二道),再 `fcntl(fd, F_SETLEASE, F_RDLCK)`:kernel 只在**沒有任何寫入 fd / 可寫共享 mmap** 時給讀取租約(kernel 6.6 `fs/locks.c:1695-1696`;tmpfs 走 `generic_setlease`,`:1957-1960`)→ `EAGAIN` = 還有人開著它準備寫(被入侵的 provd 保留 fd,或 PUT 還沒關檔)→ reason 15(上傳檔已 unlink,app 重傳),**目標槽沒動**;拿到租約後再 fstat(regular、link count 0、大小 = key 3)。租約持有到第二遍結束(拿到之後非 root 不可能再出現寫者:inode 是 root 0400,權限檢查在 `break_lease` 之前,`fs/open.c:920`;不另外處理 SIGIO,Go 預設忽略)。provd 的 PUT 必須在回 200 **之前**關檔。之後只用這個 fd。上傳窗與 `updating` 旗標在 `update.prepare` 回應前就處理好(§3.1-5);步驟 1 任何檢查失敗 → reason 15;租約拿不到:`EAGAIN` → 15(app 重傳;app 端最多重試 3 次,§3.11-12);`EINVAL`(`leases-enable` = 0)→ 21。⚠️ NEEDS-NODE:`/proc/sys/fs/leases-enable` = 1(預設)。
2. **Go `compress/gzip`(`Multistream(false)`)+ `archive/tar` 白名單解析**(不呼叫 busybox tar;root 不在驗證前解析外來的 tar,F47):第 1 個成員必須是 `SHA256SUMS`(≤ 256 KiB)、第 2 個 `metadata`(≤ 64 KiB),都是 `TypeReg`;sha256(`SHA256SUMS`)= key 4,否則 reason 11、停。`SHA256SUMS` 每一列照 §3.7.3 的名字規則檢查。
3. `metadata` 的 `board=` = S key 2 = `BATMAN_BOARD`;`release=` = S key 1。
4. 之後的成員:`TypeDir` 只允許 `boot/`、`boot/overlays/`(忽略 mode / owner,不在檔案系統建立);其他成員必須是 `TypeReg`(PAX global、GNU sparse 等一律拒絕),名字列在 `SHA256SUMS` 且符合 §3.7.3 的複製集合,或是最後的 `root.squashfs`(tar header 大小 = `metadata size=` 且 ≤ 目標槽大小)。`root.squashfs` 之後 `Next()` 必須是 `io.EOF`,gzip 串流之後不得有尾端資料;成員數 ≤ SUMS 列數 + 4;解壓總量 ≤ 256 KiB + 64 KiB + key 9 + 目標槽大小 + 1 MiB。重複、link、目錄穿越、沒列名、超量 → reason 11、停。boot 成員累計 ≤ key 9,以 `O_CREAT|O_EXCL|O_NOFOLLOW` 寫進 helper 新建的 0700 目錄 `/tmp/run/batman/update/boot/`(目錄已存在 = 上一個 helper 的孤兒留下:flock 沒被持有時先刪整個目錄再建;被持有 → `E_BUSY`);驗過的 `SHA256SUMS`、`metadata` 也寫在 `/tmp/run/batman/update/`(`batman-slot` 的 precheck 會讀,`:609-627`)。
5. **第一遍只驗、不寫槽**:步驟 2–4 的解析(boot 成員在這一遍寫進 helper 目錄)同時把 `root.squashfs` 讀完並算 sha256,= SUMS 的 `root.squashfs` 才繼續;不符 → reason 11,**目標槽完全沒動**。否則同一台 AP 上抓到明文 bearer 的人可以送一份前段照抄、rootfs 是垃圾的有效簽章 payload,讓 `begin_write` 毀掉退路後讀回才失敗(B10-m2)。⚠️ 多一遍解壓的時間未實測(估 Pi 4 上數秒)。
6. **第二遍寫入**:`lseek(fd, 0)` 重新解壓,重跑步驟 2–4 的檢查(不假設與第一遍相同),boot 成員只比對 sha、不再寫;`root.squashfs`:Go 從同一個 fd 串流給 `batman-slot write /tmp/run/batman/update` 的 stdin,用新的 `provstore.ExecReader(timeout, env, stdin io.Reader, …)`(現行 `Exec` 的 stdin 是 `[]byte`,`exec.go:19-23`;pgid、TERM → 10 s → KILL 規則相同),持有 `slotMu`。
7. 結束(成功或失敗):worker 刪解出目錄;失敗記在 helper 記憶體 `{sha, reason}`(依 §3.7.3 結束碼)。**期限**:`write` 600 s(SD 卡寫 + 讀回約 126 MB)、`arm` 60 s、`bootinfo` 30 s、`disarm` 30 s;逾時 → reason 21,目標槽保持 BAD(`begin_write`),鎖隨行程與子程序結束由 kernel 釋放(§3.7.3 flock)。`write` 回 rc 14(外部持鎖;helper 自己的呼叫已由 `slotMu` 序列化)時目標槽沒動(rc 14 只在 `precheck`,`begin_write` 之前)→ 以同一個 fd `lseek(0)` 從第二遍開頭重跑,每 10 s 一次,最多 3 次,仍 14 → reason 21。
8. **上傳檔被改寫**:上傳檔已在步驟 1 unlink 並拿到讀取租約(沒有其他寫者);helper 用的 `SHA256SUMS` 是步驟 2 驗過的那份;rootfs 與每個 boot 檔的讀回都以它為準 → 不符就 `invalidate_slot`、不 arm(F19)。`metadata size=` 只是串流長度提示(未簽),讀回仍以 `SHA256SUMS` 為準,fail-closed。
9. **`owner/remove` 移除的是 worker 的擁有者** → 中止 worker:第一遍中止 → 目標槽沒動 → status 0;第二遍(`begin_write` 之後)中止 → `batman-slot write` 收 TERM → 目標槽保持 BAD → status 第 9 列 22。

**界線**:`begin_write` 之後,另一槽(原本的退路)已被覆寫;放棄更新 = 回不到「兩槽都可用」,只能再更新一次(A/B 寫入的本質)。app 在 prepare 前提示。

#### 3.7.6 autocommit(D6、D16)

- **BLE 無線電**(`batman-autocommit:506-511`):health 行的 `boot_id` = 本次開機、`ts`(uptime)距今 ≤ 60 s,否則視同不健康;**仍只 WARN**(P-U5)。
- **寫入中**:`:226` 的 `.busy` 與 `slot_writer_alive`(也被 `:213` 的認領接手使用)改用 §3.7.3 的 flock 共享鎖試拿。
- **新:`health_ok` 加兩項(會讓試用退回)**:
  - (a) helper 的 procd instance 在跑(`ubus call service list` 的 `batman-provhelper` running);helper 被操作員停用 → 只 WARN(D-16)。
  - (b) **provd 本次開機至少一次連續穩定 ≥ 60 s**:helper 看到 **provd 行程的任一條連線**連續存在 60 s 時寫 `$RUNDIR/provd-stable`(root,內容 = boot_id);autocommit 讀它,boot_id = 本次開機才算。**辨識 provd**(F11:procd 的 instance pid 是 ujail,provd 是它的子行程):sock 層保留 SO_PEERCRED 的 pid 與 uid 並傳給 handler 工廠(現在 `sock.peerUID` 丟掉 pid,`sock/sock.go:178-194`;只改 Go 內部介面);peer pid 的 `PPid` = `ubus call service list` 的 `batman-provd` instance pid,**且** uid = 471,**且** `readlink /proc/<pid>/exe` = `/usr/bin/batman-provd`。04 實測:provd pid 8072、`PPid` 8041 = ujail、uid 471。
  - **`batman-provd` 被操作員停用**(`/etc/init.d/batman-provd enabled` 為 false)→ (b) 不要求,只 WARN(B5-m8)。
  - provd 在 bluetoothd 不在時不會結束(F67)→ BT UART 卡住不會讓 (b) 失敗;autocommit 的 MIN_WINDOW 300 s 涵蓋 60 s(F67)。之後 provd 被路人弄當不影響(檔已寫);路人在試用頭幾分鐘一直弄當 provd → 退回 = 更新失敗,不是節點壞掉。
- `health_ok` 加「`inet fw4` 在」(D-17)。

### 3.8 HTTP 通道與上傳

#### 3.8.1 provd 的 HTTP 伺服器

- **與 BLE 隔離**:HTTP session 池 2 槽(與 BLE 分開);交握額度 10 / 分(只算 HTTP);HTTP 的 fake path 只佔 HTTP 的槽;**撤 BLE 廣播只看 BLE 的 link / session**(`bluez.go:772` 改成只數 BLE)。**上傳窗模式只收擁有者**(psk_owner);窗開著時(不論備援是否也成立)只收擁有者,開窗時關掉既有的成員 HTTP session;成員 session 只在單純備援模式收(成員 session 不可驅逐,否則能在窗期間佔滿 2 槽)。
- **來源只收手機 AP 的 client(D15),由防火牆擋**:
  - 規則(兩張表,同一個 include 檔):
    - `bridge batman_http`,`input` hook:非 `phy*` port 的 frame 先清掉 bit 24(D-8);`iifname "phy*" meta mark set meta mark | 0x01000000` — 只替從手機 AP port 進來的 frame 打這個 bit(02 / 04 沒有其他 fwmark 使用者,F75;tailscale 若啟用用 0x00ff0000 範圍,不重疊)。
    - `inet batman_http_in`,`input` hook priority −10(在 fw4 之前):`tcp dport 8095 meta iifname != "br-ahwlan" drop`,再 `tcp dport 8095 meta mark & 0x01000000 == 0 drop`(IPv4 / IPv6)。iifname 條件擋本機產生的封包(iif = lo):有 CAP_NET_RAW 的行程可以自己設 `SO_MARK`(kernel 6.6 `net/core/sock.c:1388-1395`),例如 `--network host` 的容器。
    - 在 **IP 層**判斷:沒有從手機 AP port 進來的封包(mesh `bat0`、`eth0`、docker0 / br-ots 的 veth(跨 netns 時 mark 被清,`skbuff.c:5876-5895`)、VLAN 封裝後被剝標籤的 frame(F76)、`wlh0`、本機)都到不了 8095 — fail-closed。
    - nft 只認結尾的 `*`(F69),所以用前綴 `phy`;**前提由 helper 驗證**:列出所有 bridge 的 port,每一個 `phy*` 的 port 都必須是 `network.wireless status` 裡 `default_radio0` 這個 section 的 iface,而且 AP iface 是 `br-ahwlan` 的 port(D-13);有例外 → 不給 `http.2`(fail-closed)。
    - **02 實測**(F75):規則可載入、mesh 來源與 lo 被丟、刪表後完全回到原狀。⚠️ 未測:AP 上的 client 通過、VLAN 臂(D-1、D-2,§9-4)。
  - **載入者 = fw4**(F59;`fw4.uc:817-822` 前綴比對 → `ruleset-append`,`ruleset.uc:472`;整份 `nft -f` 一次,`sbin/fw4:35-36`):`/usr/share/nftables.d/ruleset-post/batman-http.nft` 隨 image 安裝(rootfs 現在沒有這個目錄 → 我們的套件建它)。兩張表都用 fw4 的寫法**先刪再建** → reload 不會重複規則(F70)。**這個檔一有錯,fw4 整份交易失敗、開機後整台沒有防火牆**(F70)→ 三道關:(1) rc 驗收在 bench 節點跑 `fw4 print \| nft -c -f -`(兩板);(2) 常規全套每次開機後斷言 `inet fw4`、`bridge batman_http`、`inet batman_http_in` 都在(§8);(3) autocommit 要求 `inet fw4` 在(D-17)。`auto_includes` 設成 0 → include 不載入 → helper 看不到表 → 不給 `http.2`。`firewall stop` 會刪掉它們 = 操作員動作。
  - **表不在 = 不聽(fail-closed)**:helper 背景每 4 s 確認兩張表、規則與 `phy*` 前提;結果放快取,poll 只讀快取;快取超過 10 s → 當作不在。**在才給 `http.2`**;provd 沒有 `http.2`、或 poll 失敗 / 過期 → 不 bind,已 bind 的關掉 — 最壞 ≤ 8 s。
  - 不需要 `kmod-nft-bridge`(F60、F75)。04 上 `br_netfilter` 已由 docker 載入(`bridge-nf-call-iptables=1`)— 本設計不依賴它。
  - provd 只 bind `http.2` 給的 `br-ahwlan` 位址。**bind 失敗**(EADDRINUSE:本機任何行程都能先佔 8095,> 1024 不需權限)→ 經 poll 回報,`status` key 15 加 `http_bind_failed`,app 顯示;只造成 DoS(Noise 擋冒充)→ 誠實界線。
- `net/http`:`ReadHeaderTimeout` 5 s、非上傳 `ReadTimeout` 15 s、`IdleTimeout` 30 s、`MaxHeaderBytes` 4 KiB;同時連線上限 8(F43;provd soft nofile 1024,04 實測);`/session`、`/msg` body ≤ 9 KiB。上傳最低速率 **256 KiB/s**(30 s 平均;126 MB 約 8.2 分鐘),低於就關。
- 端點(協定 §4.2):`POST /batman/v1/session`、`POST /batman/v1/msg`;完整 §3 Noise;角色依 §3.1.2。`X-Batman-Session` = 路由用的 session id(`/session` 明文回傳)。多塊回應以多次 `POST /batman/v1/msg`(空 body = 取下一塊)取回。
  - **AEAD 失敗**(偽造的 `/msg`)→ 丟掉那個請求(400),**不中止 session、不改 `msgs` 計數、不刷新 `lastActive`**(現行 provd 在解密前就 `msgs++`、`lastActive = now`,`provd/session.go:314-322`,要改);`flynn/noise` v1.1.0 的 `Decrypt` 失敗不推進 nonce(`state.go:76-80`)。
  - **回應遺失 = 這個 session 中止**(沒有冪等快取):app 重新交握、`auth/owner`,再依 §5.2 重讀狀態;協定 §4.2 同步改。
  - **界線**:空 body 的「取下一塊」沒有認證 → 知道 session id 的旁聽者(同一台 AP、知道 AP 密碼)可以先取走一塊,打斷擁有者的分塊取回 → app 重新交握;DoS,列 §7。
- **什麼時候聽**:
  - **備援**(D6):provd 自己的 `HealthOK()`(F45)連續 5 分鐘(uptime)為 false → 開;連續 1 分鐘為 true → 不收新連線,已建立的 HTTP session 繼續到結束或 10 分鐘。之後的 EMCON(checklist)若刻意關 BLE,也必須關掉備援。
  - **上傳窗**:`bulk.open` 後 15 分鐘(uptime),或到 `update.prepare` 開始 / `bulk.close`;窗關了不收新連線,已建立的 session 保留到 worker 結束或閒置 10 分鐘。
  - 都不是,或沒有 `http.2` → 不 bind。
- 埠 8095:04 未被佔用(§12.3)。

#### 3.8.2 上傳窗(`bulk.open` / `bulk.close`)與上傳

- `bulk.open {1: purpose 0, 2: sha, 31: owner-op}`:前提:有 pending、呼叫者 = pending 的擁有者、`2` = pending 的 sha(由 owner-op 綁定;不符 → reason 15);手機 AP 開著(`network.wireless status` 的 radio0 up 且有 AP iface)否則 reason 16(D13,不自動開;剛認領節點被 keyguard 關著的 AP 由 §3.3 的配對打開;04 現在就是關著的);沒有另一位擁有者的上傳窗、也沒有 worker 在跑(有 → `E_BUSY`,同一位擁有者也一樣);同一位擁有者重送 = 延長同一個窗。**pending 到期延到窗到期 + 5 分**。helper 每次操作時才開 dirfd(helper 是 S89,tmpfs 由 provd 的 init 在 S92 才掛),開窗前以它 `fstatfs` 確認 `/tmp/run/batman-provd-bulk` 是 tmpfs 且是掛載點(`st_dev` ≠ `/tmp/run`),否則 reason 21(init 沒掛上時不退化成 `/tmp` 上的普通目錄,D-15)。`owner/remove` 一併清掉該擁有者的上傳窗與 pending(worker 見 §3.7.5-9)。
- helper 記 `{owner_key_id, 到期}`;回(在 Noise 加密的回應裡)`{1: 手機 AP 的 ssid, 2: 手機 AP 的 passphrase, 3: 節點在 ahwlan 的 IPv4, 4: 8095, 5: 900, 6: 上傳 bearer}`。key 2 是這台 AP 的現行密碼(擁有者本來就有權知道),**不是一次性 PSK**。key 6 = **helper**(上傳窗的擁有者)在這次 `bulk.open` 以 `crypto/rand` 產生的 128 bit,經 poll 的 `http` 欄位交給 provd(provd 重啟後重新取得;helper 重啟 → 窗消失;PUT 的 header 必須正好 32 個小寫 hex,provd 沒有持有 16 bytes 的 bearer 時一律拒絕 PUT,空字串不進比對),與 Noise 的金鑰 / 雜湊、與 `X-Batman-Session` 都無關;重送 `bulk/open` 回同一個值。
- **上傳**:`PUT /batman/v1/bulk/0`,header `X-Batman-Upload` = 上傳 bearer(constant-time 比對;只對這個端點有效;不進 log、錯誤字串、診斷包;是 PUT **唯一**的憑證 —— 不綁來源 IP:正常流程經 BLE 開窗,沒有對應的 HTTP session,而同一 L2 上的人本來就能冒用 IP);`Content-Length` = `http.5`。provd 回 **409** 的情況:窗沒開、worker 在跑、已有一個 PUT 在進行、窗的剩餘時間 < `Content-Length` ÷ 256 KiB/s + 60 s(app 先重送 `bulk/open` 延長再 PUT)。bearer 經 HTTP 明文送出 → 同一台 AP 上知道 AP 密碼的人可以抓到並搶先 PUT → 只造成 DoS:內容由簽章把關,worker 第一遍驗完整份才動退路(§3.7.5-5)→ 誠實界線。
- **每個 PUT 從頭寫**:`O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW`,不續傳。手機斷 Wi-Fi / 上傳中斷 → provd 關檔;prepare 會發現大小不符(reason 15);app 重新 PUT。
- **寫入位置**:`/tmp/run/batman-provd-bulk/payload`。專屬 tmpfs,由 init(root)在啟動 jail 前掛上:`nodev,nosuid,noexec,mode=0700,nr_inodes=16`、provd:provd、`size=` = **2 × 本板當次 build 的 payload 大小**(bcm2711 = 2 × 126,309,765 B ≈ 241 MiB;實際限制交給 RAM 預算);**`batman-provd.init` 與 `batman-provd-test.init` 兩個檔都加**(Makefile 依 `BATMAN_PROV_TEST` 二選一安裝);init 先檢查是否已掛載(不疊掛)、路徑 lstat、非 symlink;掛不上 → 不開上傳(D-15),**而且不把它 rw 掛進 jail**(否則 `/tmp` 上的普通目錄會讓被入侵的 provd 塞滿 `/tmp`);掛上了才 rw 掛進 jail(provd 唯一的 rw 掛載)。被入侵的 provd 開著 fd 時刪除不會釋放空間 → 最多佔到 `size=`(A6-m2)→ 誠實界線;3A+ 與 2 GB TAK 節點列 checklist。
- **上傳完成**:provd 收完、**關檔**後才回 HTTP 200;app 接著 `update/prepare`(BLE,或手機已有的 HTTP session)。
- **刪除上傳檔的唯一負責者 = helper**,規則只有一條:helper 每 4 s 的背景 tick(不依賴 provd 的 poll),在 `updMu` 內判斷「沒有窗且沒有 worker」→ 刪;`update.prepare` 的關窗、設 `updating`、啟動 worker 也在同一個 `updMu` 內完成,tick 不會插在中間(A14-m9、B14-m7);helper 啟動時刪;worker 開檔驗完後立刻 unlink(§3.7.5-1)。prepare 被拒時**不**刪、窗保持開著(app 直接重 PUT,PUT 本來就從頭寫)。窗關前就在跑的 PUT(poll 延遲 ≤ 4 s)若在 worker 期間寫完,那個新檔在 worker 結束後依同一條規則刪;tmpfs `size=` = 2 × payload 已涵蓋。
- **poll 的 `http` 欄位**(helper → provd,§2):既有 `2` = bind 位址、`5` = 上傳大小;新增 `6` = 上傳 bearer(16 bytes)、`7` = 窗到期(uptime 秒)、`8` = worker 在跑。provd → helper(poll 請求)新增:已收 bytes(phase 1 百分比)、bind 失敗。缺欄位 = 沒有窗、不收 PUT(fail-closed)。只用 `unlinkat(dirfd, "payload")`;目錄裡其他名字以 dirfd + `O_NOFOLLOW` 列舉後 `unlinkat`,不用 `RemoveAll`、不跟隨 symlink。helper 在上傳中重啟 → 窗消失、檔被刪 → fail-closed,擁有者重開窗再傳。

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
5. prepare 前提示「開始寫入後,放棄就回不到原本的退路」;`update.status` 0 的文字是「沒有更新」,6 才是「新版不健康,已退回」;0 + 22「上次寫入沒有完成,退路已失效,請再更新一次」;0 + 23「新版已寫入但沒有啟用,請重新更新」;6 + 18「新版沒有完成試用」。**只在 status 的 key 4(sha)等於自己要裝的那份時,才把 3 / 4 / 5 當成這次更新的結果**(§3.7.4)。0 + 15 →「上傳不完整,請重新上傳」;0 + 21 →「節點現在無法寫入,請稍後再試」;check 回 24 →「這個版本不能經 app 更新,請用電腦(ssh)更新或重燒」。
6. **配對**(D14):認領後以 `settings/set` key 20(經 BLE)設這台節點的 SSID(中性、不含個人資料)與 ≥ 20 字隨機密碼(字元集 `[A-Za-z0-9._~+=,:@%^*-]`),存在手機;SSID 不隱藏。剛認領的節點 AP 被 keyguard 關著,配對同時打開它。之後若 `settings.get` 的 SSID 與手機記的不同 → 提示重新配對。
7. **國家**(D9):建網時寫進 `net_config`;節點入網前先以 `settings/set` key 2 改成網路的國家,否則入網被拒(reason 14)。
8. **遺失手機**(D17):`owner/remove` 後提示以 key 20 換這台的 AP 密碼;認領後建議加一位備用擁有者(只有一位擁有者時手機遺失只能重燒,L59)。
9. **節點忙碌**:`settings/set` 或 `network/*` 進行中,新連線最多等約 4 分鐘(230 s 預算);顯示「節點忙碌」;`otaBusy` 一直為忙超過 10 分鐘(子程序卡在 D 狀態、SD 卡壞)→ 改顯示「節點的儲存卡可能有問題,請重開節點」。
10. 回應遺失 → 重新交握並以 `settings/get` / `update/status` 重讀(§5.2)。
11. 完全靜默(EMCON)時連 BLE 也不連 — app 模式,不在 P3。
12. **上傳流程**(§3.8.2):`bulk/open` 帶 pending 的 sha;從加密回應取上傳 bearer(key 6),PUT 用 `X-Batman-Upload`(不是 `X-Batman-Session`);PUT 前若窗剩不到「大小 ÷ 256 KiB/s + 60 s」先重送 `bulk/open` 延長;PUT 中斷 → 從頭重 PUT;prepare 連續 3 次回 15 →「節點拒絕上傳檔,請重開節點後再試」;收到 409 → 依 status 判斷(窗沒開 / worker 在跑);`bulk/open` 之後 10 s 內的連線拒絕或 409 一律重試(間隔 1 s;provd 經下一次 poll 才拿到 bearer、才 bind)。

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
| p6 `state/update-last` | helper(`update.prepare`、`update.apply`、`reboot committed` 失敗;`updMu`,§3.7.4) | helper |
| p6 `state/prov-state`(既有) | helper(既有) | `/cgi-bin/bundle`(新讀者) |
| 目標槽(rootfs、boot、`BATMAN-VERIFIED`、`BATMAN-BAD`)、tryboot 旗標;boot 分割的**掛載** | `batman-slot`(`write` / `arm` / `disarm` / `apply` / `bootinfo`),flock 互斥(§3.7.3):helper 的呼叫經 `slotMu` 序列化 | autocommit;helper 只經 `bootinfo` 讀;**harness 仍有鎖外掛載**(`ab-selftest.sh:73,75`、`eh13-pre-254.sh:55,62`、`prov-chain0-254.sh:22`)→ harness PR 改 |
| 槽第一次開機時的 `distroconfig.txt` | `92-batman-ramoops-fix`(uci-defaults,helper 啟動前、鎖外,`:19-40`) | key 8 清單要列改前與改後 |
| 上傳 bearer | helper(`bulk.open` 產生),經 poll 交給 provd | provd 比對 |
| pending | helper(`updMu`) | — |
| `release-root.pub`、`release-min-serial` | firmware `stamp-batman-build.sh` 依 build 種類放(§3.7.2:`rel` = R、bench = T、一般 DEV = 不放);gate = `check-release-key-gate.sh`(`build-board.sh`、`build-firmware.yml`) | helper |
| provd ↔ helper 的 ctl / ro / ops 連線 | provd 開 | helper 限速 |

**清理表**:

| 東西 | 正常結束 | 失敗 / 到期 | helper 重啟 | provd 重啟 | 開機 |
|---|---|---|---|---|---|
| 上傳檔 | worker 開檔驗完立刻 unlink | helper 每 4 s tick:沒有窗且沒有 worker → 刪(prepare 被拒不刪) | 啟動時刪 | 不刪(helper 是唯一刪除者;init 不疊掛) | tmpfs 消失 |
| 解出的 boot 檔 | worker 刪 | worker 刪 | 啟動時刪(flock 被持有就不刪) | — | tmpfs 消失 |
| pending | 被下一個 check 覆寫或到期 | 到期(uptime 30 分) | 讀回(同 boot_id 才有效) | — | 消失 |
| diag bundle | 10 分鐘到期 | 同 | 啟動時清空 | 不影響(純到期) | 消失 |
| update-last | 下一次 `update.prepare` 覆寫 | 同 | 保留 | — | 保留(p6) |
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
| `update.check` | `bootinfo` 拿不到 flock | `E_BUSY` |
| `update.check` | image 沒有根鑰匙 | ok 回應 `{1: false, 2: 24}` |
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
| `update.check` | 1 / 2 / 3 / 4 / 5 / 6 / 8 / 11 / 12 / 17 / 21 | **ok 回應** `{1: false, 2: reason, 3: RAM}` |
| `update.prepare` / `apply` | 前提不成立 / sha 不符 / 上傳不完整 | `E_REJECTED{2: 15}` |
| `update.prepare` 的 worker | 失敗 | `update.status` = phase 0 + `3: reason`(依 §3.7.3 結束碼,含 21) |
| `update.apply` | arm 失敗 | 依 §3.7.3 結束碼:`E_REJECTED{2: 1 / 2 / 5 / 11 / 12 / 17 / 21}`;rc 14 → `E_BUSY` |
| `bulk.open` | 無 pending | `E_REJECTED{2: 15}` |
| `bulk.open` | sha ≠ pending,或呼叫者不是 pending 的擁有者 | `E_REJECTED{2: 15}` |
| `bulk.open` | worker 在跑 | `E_BUSY` |
| `bulk.open` | bulk tmpfs 不是掛載點 | `E_REJECTED{2: 21}` |
| `update.apply` | 呼叫者不是 pending 的擁有者 | `E_REJECTED{2: 15}` |
| `update.apply` | `rebooting` 寫不進 p6 | `E_STORAGE`(已 disarm、不重開) |
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
| update-last(p6) | helper → helper | CBOR `{0: format 1, sha, from_slot, from_version, to_slot, to_version, apply_boot_id, aclog_off, rebooting}`(§3.7.4),tmp + fsync + rename | 缺 / 壞 / 未知 format / 版本對不上 → phase 0 | root |
| 上傳檔 | provd → helper | 大小 = key 3 | §3.7.5 步驟 1–4 | provd(不受信任) |
| `BATMAN-VERIFIED` | `batman-slot write` → `arm`、`bootinfo` | 一行 `<sha256 hex> <boot_id>` | 缺 / 不符 / 別次開機 → arm 拒絕 | root |
| `batman-slot bootinfo` 的 stdout | batman-slot → helper | §3.7.3(`verified=`、`bad=`、`bootcfg=`、`--`、distroconfig) | 缺行 / 重複 / 格式錯 → 當作讀不到,沿用上次、待重讀 | root |
| `batman-slot.flock` | batman-slot(持有)→ batman-slot、helper、autocommit(`flock -n` 試拿) | 空檔,root 0600;語意 = kernel flock | 持有者與子程序都結束 → 自動釋放 | root |
| autocommit.log(p6) | autocommit、95 → helper(只讀) | 追加的行 | 比 `aclog_off` 短 → 當作沒有紀錄 | root |
| `batman-slot write / arm / disarm / bootinfo` | helper → batman-slot | §3.7.3 | rc 依 §3.7.3 結束碼表 | root |
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
| provd crash / crash loop | — | HTTP 斷;上傳檔依 §3.8.2 的規則由 helper 刪(窗還開著就保留,app 重 PUT);provd-stable 已寫就不受影響 | `prov-http-254` kill 臂 |
| helper crash | — | worker 中斷 → 槽保持 BAD(begin_write),不 arm;重啟時刪暫存;pending 同 boot_id 仍有效;apply 已開始而還沒重開(`apply_boot_id` = 本次、`rebooting` 為 false)→ disarm,status 23(§3.7.4) | `prov-update-254` kill 臂 |
| helper 重啟時 setkey 子程序還在跑 | — | 子程序(另一個 process group,F72)拿著鎖自己跑完並自己 `--rollback`;helper 啟動後以設定快取的刷新取得結果;那一次請求對 app 是 outcome unknown → 重讀 | `prov-settings-254` |
| `settings.set` 中斷電 | — | setkey 在 commit 之後、persist 之前斷電 → live(overlay)是新值、p5 是舊值;一般重開時 96 不跑(F71),不會從 p5 覆寫 → 新值留著、p5 stale → 下一次 `--save`(on-join / 下一次 setkey / 同值的 `settings.set` / `update.check`)補上;與 P1 的 setkey 相同的已知界線 | 誠實界線 |
| 上傳中 helper 重啟 | — | 窗消失、檔被刪 → fail-closed,重開窗重傳 | `prov-upload-254` |
| 手機斷 Wi-Fi / 上傳中斷 | — | provd 關檔;prepare 大小不符 → reason 15;app 從頭重 PUT(§12.5.7) | `prov-upload-254` |
| 寫到一半斷電 / helper 重啟 / worker 被中止 | — | 槽 BAD;status 0 + reason 22(§12.5.5) | `prov-update-254` |
| 已寫入、未啟用(pending 到期) | — | status 0 + reason 23;若 from_slot 開不起來,#133 fallback 進這一槽會被 commit(§12.5.13) | 誠實界線 + Go 表測 |
| 同時 ssh sysupgrade | — | app `write` 在跑時 stage 1 rc 14 拒絕;`-F` 照舊可強制(§3.7.3) | `prov-update-254` |
| p6 壞 / 滿 / 唯讀 | — | update-last 寫不進 → prepare / apply 回 `E_STORAGE`,不寫槽、不 arm;status 讀不到 update-last → 0 | `prov-update-254` |
| 非 helper 的 `batman-slot` 被殺、留下掛載 | — | 之後的寫入 rc 14,直到操作員卸載或重開(helper 的呼叫在自己的 mount namespace,不會留下) | 誠實界線 |
| 子程序卡在 D 狀態(SD 卡壞) | — | 鎖跟著 `dd` 留到重開;之後的寫入 rc 14、`otaBusy` 為忙 | 誠實界線 |
| ssh sysupgrade(stage 2 在 ramfs) | — | `RAMFS_COPY_BIN` 帶 flock,`stage-root` / `apply` 照常拿鎖 | sysupgrade 臂 |
| DEV → PROD 換信任 | — | bench 節點:T 簽、內建 R 的過渡版(`release-sign.sh --test-key`),或 ssh / 重燒;一般 DEV 節點(沒有鑰匙):只能 ssh / 重燒(§3.7.2) | #255 |
| bench 節點經 app 裝了一般 image | — | 新 image 沒有鑰匙 → 之後只能 ssh / 重燒;`signrel.py` 預設拒簽,要 `--allow-no-key` | 誠實界線 + signrel 測試 |
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
| 同 AP 上知道 AP 密碼的人 | 抓到明文的上傳 bearer(`X-Batman-Upload`)、搶先 PUT、送前段照抄而 rootfs 是垃圾的 payload;打斷分塊取回 | 只造成 DoS:內容由簽章把關,worker 第一遍驗完整份才動退路(§3.7.5-5) | 誠實界線 + `prov-update-254` 垃圾 rootfs 臂 |
| 被入侵的 provd | 改 payload、塞沒列名的 boot 檔、tar 穿越 | Go 白名單解析、先驗簽、只寫列名的檔、讀回以 helper 的 `SHA256SUMS` 為準 | `prov-update-254` 惡意 tar 臂 |
| 被入侵的 provd | 保留寫入 fd,在 worker 兩遍之間改內容,讓 `begin_write` 毀掉退路 | unlink 後 `F_SETLEASE F_RDLCK`:有寫入 fd 就拿不到 → reason 15、目標槽沒動(§3.7.5-1) | `prov-update-254` 保留 fd 臂 |
| 被入侵的 provd、抓到 bearer 的 AP 鄰居 | 讓更新一直失敗(截短檔、丟 PUT、持 fd) | 只造成 DoS:app 重試 3 次後提示重開節點,重開後恢復 | 誠實界線 |
| root / 操作員 | 在 overlay 放 `release-root.pub` 讓一般 image 信任它 | helper 只讀 `/rom` | `prov-update-254`(overlay 放 T → 仍 24) |
| 其他 mount namespace 的 root(特權容器) | 掛著目標 FAT,major:minor 檢查看不到 | 只有 root 做得到;同一 superblock 快取一致,另起 superblock 時讀回失敗 → fail-closed | 誠實界線 |
| 供應鏈 / 我們自己的錯 | 公開發布了開發版 | 一般 `wsl` / `ci` image 不含根鑰匙 → 不能經 app 更新;bench build(含 T)不得公開發布:stamp 有 `BATMAN_BENCH_TRUST=T`、`release-sign.sh` 拒簽、gate 要求 bench build 才能放 T —— 有人手動把 bench image 公開仍擋不住 → 誠實界線 | gate 負測試 |
| 被入侵的 provd | 佔 RAM | 專屬 tmpfs `size=` 上限;窗外 helper 每 4 s 刪檔;3A+ 與 2 GB TAK 節點列 checklist | `prov-upload-254` |
| 被入侵的 provd | 偷換 pending 版本 | prepare / apply body 帶 sha,由 owner-op 綁擁有者同意的版本 | Go |
| 被入侵的 provd | 自己聽 HTTP | 本來就能(無 netns,> 1024 埠);沒有 PSK 解不開 session、拿不到 owner-op;8095 仍只收從手機 AP port 進來的封包(其他埠不在本規則範圍) | 誠實界線 |
| 本機非 root | 讀 AP 密碼 | `/etc/config/wireless`、hostapd conf 0644(F34,與現況相同) | 誠實界線 |
| 本機非 root | 從 cmdline 或 log 讀 AP 密碼 | passphrase 走 stdin(`--ap -`);不進 log | `prov-settings-254`(`/proc/*/cmdline`、logread、helper / provd log、診斷包都不含) |
| 本機行程(lo)、eth0 / docker0 的 VLAN 封裝 frame | 佔掉 HTTP 的 2 槽 | inet input 只收 `iifname br-ahwlan` 且帶「手機 AP port」標記的封包(F75、F76;有 CAP_NET_RAW 的行程可設 `SO_MARK`,所以加 iifname,§12.5.11) | `prov-http-254` 的 lo / `SO_MARK` / VLAN 臂 |
| 本機非特權行程 | 先佔住 8095 | provd bind 失敗經 `status` 回報;只造成 DoS(Noise 擋冒充) | 誠實界線 + `prov-http-254` |
| 下載來源被換掉(bench) | 擁有者同意一份 T 簽的惡意 image | T 公開:bench 節點的信任根 = app 拿 payload 的來源;bench build 只用於 02 / 04 這類 bench 節點;一般 DEV 節點不含鑰匙 | 誠實界線 |
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
| `prov-upload-254` | AP 關 → 16;非窗擁有者的 session → 拒;大小不符 → prepare 15;provd 寫超過 tmpfs → ENOSPC、其他服務正常;窗外的上傳檔一個 poll 週期內被刪;上傳中 `network/update` → `E_BUSY`;上傳中 helper 重啟 → 窗消失、重傳成功;`owner/remove` 清掉窗 | Go 接縫(各關一道:窗擁有者檢查、bearer 檢查、`otaBusy` 擴大)+ wsl.22 |
| `prov-update-254` | T 簽的 image 經 app 路徑 → trial → commit → 5;重裝同版本退回 → 6(不是 5);重裝同版本時第二次試用的 overlay 是新的(第一次試用留的標記檔不在);arm 後、`rebooting` 前斷電 → 0 + 23;新版沒開機成功(注入:目標槽 kernel 壞掉)→ 6 + 18;之前退回過同一版本不造成誤判(看 `aclog_off` 之後的行);有效簽章、前段照抄、rootfs 是垃圾 → reason 11 且目標槽沒動;worker 失敗的 reason 依類別;簽章錯、serial < min、板子錯、降級、min_from、目標槽開機設定不符、版本解析失敗、四包惡意 tar、上傳檔換成 FIFO、上傳後改 payload、prepare 中 kill helper / 斷電、helper 重啟後 phase 3 重建;回滾臂;**升級臂**:P2 未入網節點 sysupgrade 到 P3 → `--check` fresh;SSID 含 `'` 的節點升級後 OTA 不被擋;**sysupgrade 臂**:未列名的 dtb 不被寫進槽;**bench 臂**:YubiKey K 簽、release 設定節點、T 簽的被拒 | `slot-copy-all`(未列名的 dtb 被寫進去)、`p5-autosave-off`(升級臂 stale) |
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
- firmware(另一個 repo、另一個 PR):`scripts/stamp-batman-build.sh`(依通道放鑰匙檔、通道白名單)、`scripts/check-release-key-gate.sh`(新)、`build-board.sh` 第 7 步與 `.github/workflows/build-firmware.yml` 呼叫它、`.gitignore`。
- harness(#290,先進 main):`tests/keys/README.md` 與 `tests/tools/peer/signrel.py:4` 的「T 只給 prov_test」改為「只有 bench build(含以 `--bench` 建的 prov_test)信任 T」;鎖外掛 boot FAT 的腳本改在鎖內或用 `bootinfo`;讀 `.busy` 或依 rc 1 判斷的測試改成 flock / rc 14(`daily-validation.sh:2067`、`setkey-persists-202.sh:65`、`p5-follows-202.sh:121`、`negctl-old-slot-254.sh:29`;Go `wtxn_v10b_test.go:59`、`p3review_test.go:147`)。
- `219-protocol.cddl`:reason-code 11–23;`update-manifest` key 5(= CBOR `[E, S]`)、key 6 語意、S 的 key 7–9;`update/prepare`、`update/apply` 的 key 1 = sha(由 owner-op 的 `args_hash` 綁定);`status-resp` key 2–4 改選填;settings key 20;`bulk-open-resp` key 2 的註解;`update-phase` 2 的名稱;冪等欄位(`idem-type`、各請求的 `? 7`)註記「保留、P3 不使用(provd 回 `E_UNSUPPORTED{idem}`)」。
- `219-field-provisioning.md` §6.9:暫時 AP 改為「經這台節點的手機 AP」;B18 寫入兩層鑰匙。
- `254-stage1-impl.md`:§10.6 / §10.7(D3);`:171`(bundle 用 handle 分頁);`:357` `E_STATE` → `E_BUSY`。
- `254-p1-impl.md`:`:465`(admins +1 刪)、`:466`(未知 key 忽略)。
- `docs/VERSIONS.md`:版本比較規則。
- 新 `docs/`:說明頁文字(§3.10);release note(`/cgi-bin/bundle` 403、P3 之前的 payload 不能經 app 裝)。
- 檔案:`halow-setkey`(新旗標 + 說明 + deploy 鏡像);`batman-slot`(`write`(含 `clear_root`)、`arm`、`disarm`、`bootinfo`、複製集合與名字規則、`begin_write` 刪 VERIFIED、`flock` 鎖(取代 mkdir 鎖與 `.busy`)、TERM trap、結束碼表、`tboot_open` 只重用 `/boot`、別處掛著 → rc 14);`batman-autocommit`(以共享 flock 試拿判斷寫入中:`:79-86`、`:213`、`:226`、`:550`);Go(`otaBusy` 改用共享 flock 試拿 `node/wtxn.go:450-454`、`provstore.ExecReader`、`sock` 的 peer pid、worker 的租約);`scripts/release-root.fpr`(#255 產生);Batman `scripts/check-release-key-gate.sh`;Batman feed `usr/lib/batman/platform-ab.sh:38` 的 `RAMFS_COPY_BIN` 加 `/usr/bin/flock`;firmware:stamp 的 bench 規則、`build-board.sh --bench`、`build-firmware.yml` 拒絕 bench;helper 讀 `/rom/usr/share/batman/`;`batman-config-save`(PRESERVE 加 ssid;ssid 不可存時略過);`joinwatch` / `halow-status`(`verdict_code()`、`join.reason_code`,含 deploy 鏡像);`batman-autocommit`(新鮮度、helper、provd-stable、provd 停用時 WARN);`www/cgi-bin/bundle`(+ deploy 鏡像);`/usr/share/nftables.d/ruleset-post/batman-http.nft`(新,兩張表先刪再建);`batman-provd.init`(tmpfs、rw mount、不疊掛);`build-ab-payload.sh`(順序、`release=`);`release-sign.sh`、`release-endorse.sh`(新);`transfer-flash.ps1` / `.sh`(新,含 `--test-skip-wipe`);tmp-trust allowlist 的新路徑照 #290 走 harness PR。
- firmware:`flash.js` 文字 patch;**不加** `kmod-nft-bridge`(F60)。

## 11. 寫進 #254 checklist(不在本 PR)

- 既有問題:joinwatch 的 3600 s 自動重開不看 slot 寫入(`joinwatch:171-196`);app 的 `write` 中被它重開 → 槽 BAD、status 22(fail-closed,但退路沒了)(A13-m10)。
- 既有問題:`slot_is_bad` 在目標 boot 分割掛不上時回「不是 BAD」(`batman-slot:364-369`),rollback 會照做(B10-m14)。

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
2. **(v7.3 由 §12.5.2 取代)`batman-slot` 的失敗沒有類別碼**:`die` 一律 `exit 1`(`batman-slot:40-44`),§3.7.5-6「依失敗類別對應 reason」無從判斷。**做法**:新動詞 `write` / `arm` / `bootinfo` 的結束碼:

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
   - **v7.8 取代**:只有 bench build(`BATMAN_BENCH_TRUST=T`)內建 T;一般 DEV image 不放鑰匙(§3.7.2)。
   - 正式根鑰匙 R 與 YubiKey(§3.7.1、§9-2)在正式版(#255)時產生、實測;**release gate**:見 §3.7.2(v7.8 起:`rel` 釘 R;bench build 放 T;一般 `wsl` / `ci` 不放鑰匙)。
   - 因此 §8 `prov-update-254` 的「T 簽 → 試用 → commit → phase 5」用 bench build(會 commit;一般 DEV image 沒有鑰匙,不能當目標);wbox image 永不 commit(`batman-autocommit:489-494`、`batman-slot:800-805`)不能當目標。
   - **界線**:bench build 信任公開的 T,任何人都能簽出它能裝的 payload —— bench build 只用於 02 / 04 這類 bench 節點(v7.8)。
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

### 12.5 審查修正索引與負對照(v7.3、v7.4;A8 / B8 = v7.2 審查、A9 / B9 = v7.3 審查)

v7.3 的修正(§12.5.1–12.5.15)與 v7.3、v7.4 審查的修正都已**直接寫進 §3.7 / §3.8**(v7.4 審查的回應見附錄 G、v7.5 審查見附錄 H、v7.7 審查見附錄 J);實作只看 §3。本節保留編號作為索引,加上負對照表。

| 原編號 | 內容 | 現在在哪 |
|---|---|---|
| 12.5.1 | boot 分割只有 `batman-slot` 掛;`bootinfo` | §3.7.3、§3.7.4(槽資訊快取,v7.4 改成不定期跑,A9-MAJOR-1) |
| 12.5.2 | 結束碼與 reason 21 | §3.7.3 結束碼表(v7.4 補齊行號,A9-m12) |
| 12.5.3 | `.busy` 持有者 | §3.7.3(v7.7:改用 `flock`,拿掉 pid / starttime / zombie / symlink / TAMPER,A12-m12、B12-m1) |
| 12.5.4 | boot 檔複製集合 | §3.7.3(v7.4:不分大小寫、重複名字,B9-m12;SUMS 256 KiB) |
| 12.5.5 | status 綁定嘗試 | §3.7.4(v7.4:拿掉 `written`,改看目標槽 `bad` / `verified`,A9-m1;記憶體結果綁 sha,A9-m2;啟動時有條件 disarm,A9-m3、B9-m11;讀 autocommit.log,A9-m4;原子寫入,A9-m7、B9-m7) |
| 12.5.6 | 兩位擁有者、移除擁有者 | §3.7.4、§3.7.5-8、§3.8.2(v7.4:apply 之後不取消,A9-m13) |
| 12.5.7 | 上傳語意 | §3.8.2(v7.4:409 規則、worker unlink、bulk.open 延長 pending,A9-m5、m6、B9-m6) |
| 12.5.8 | 串流 stdin | §3.7.5-6 |
| 12.5.9 | 版本規則 | §3.7.1(v7.4:照真實字串 `REL-CH.N`,跨通道要 key 6,A9-m8) |
| 12.5.10 | 信任、gate、鑰匙檔 | §3.7.1、§3.7.2(v7.4:誰放鑰匙、gate 在哪跑、`ci` = DEV、release-sign 拒簽,A9-m14、B9-m9;**check 只快取簽章驗證**,A9-MAJOR-2) |
| 12.5.11 | 防火牆、bind、bearer | §3.8.1、§3.8.2(v7.4:上傳 bearer 與 session id 分開、在加密回應裡給;AEAD 失敗不刷新計數;窗模式只收擁有者,B9-m4、m5、m10) |
| 12.5.12 | tmpfs、tar | §3.7.5、§3.8.2 |
| 12.5.13 | 已寫入未啟用 | §3.7.4 判讀第 10 列與界線(B9-m8:被移除擁有者寫入的版本也在界線內) |
| 12.5.14 | 同時 sysupgrade | §3.7.3 |
| 12.5.15 | 其他契約 | §3.7.3、§3.7.4 |

**負對照**(每個決定一個「拿掉就 FAIL」的測試;H4 照這份寫):

| 決定 | 測試 | 負對照 |
|---|---|---|
| 單一掛載者 | 接縫 `bootinfo-hold`(持鎖 5 s)+ `write` → rc 14、目標槽沒動 | 接縫 `tboot-reuse-any` + 先 ro 掛目標分割 → 寫錯地方或 die |
| helper 序列化、不定期 `bootinfo`(A9-MAJOR-1) | 接縫讓 `bootinfo` 持鎖 2 s,worker `write` 50 次 → 0 次 rc 14;外部 `batman-slot commit` 迴圈 200 次與 helper 並行 → 0 次 rc 14 | 恢復每 15 s `bootinfo`、不經 `slotMu` → 出現 rc 14 |
| check 不快取節點狀態(A9-MAJOR-2) | check → 12;完成 `.txn`;同一份 manifest 再 check → 通過 | 快取整個結果 → 仍回 12 |
| 結束碼 | 每個 rc 一案;p5 未 seed → reason 2 | wsl.25 `batman-slot`(一律 rc 1 → 11) |
| flock 鎖 | `write-hang` + 期限 → KILL shell、`dd` 還活著 → 另一個 `write` rc 14、`otaBusy` 為忙;所有子程序結束 → 鎖自動釋放、`settings.set` 不是 `E_BUSY`;`sh -x` / 別的路徑跑的持有者照樣互斥 | 現行 mkdir 鎖 + pid 規則:只殺 shell 就被接手 |
| 複製集合 | 有效簽章 + SUMS 列 `boot/autoboot.txt`、`boot/AutoBoot.txt`、`boot/config.txt`、`boot/..x`、大小寫重複 → 拒絕,p1 `autoboot.txt` 不變 | 「只照 SUMS 複製、分大小寫」接縫 |
| 判讀表 | Go 表測每列一案;v2 成功後 v3 寫入中斷 → 0 + 22;寫入前失敗 → 0;worker 成功後 helper 掛、pending 到期 → 23;同版本重試又退回 → 6;commit 後被 rollback → 0 | 接縫 `update-no-attempt-record`(prepare 不寫)→ 報 5 |
| 記憶體失敗綁 sha | 第一次失敗、重來成功 → phase 3、apply 可用 | 不綁 sha → 卡在 0 + 舊 reason |
| 啟動時 disarm 的條件 | 操作員手動 `apply` 後重啟 helper → tryboot 旗標仍是 1 | 無條件 disarm |
| update-last 原子寫入 | Go 測試在 rename 前中止 → 讀到上一版 | 直接覆寫 |
| VERIFIED 綁 boot_id | 上次開機寫的 VERIFIED(同 sha)→ `arm` 拒絕 | 只比 sha |
| 移除擁有者 | worker 中 `owner/remove` → worker 結束、槽 BAD、0 + 22 | 不中止 worker |
| worker unlink | worker 開檔後 1 s 內再 PUT 一份垃圾 → worker 成功 | 不 unlink |
| PUT 409 | 第二個 PUT;剩餘時間不夠;worker 在跑 → 409 | 拿掉檢查 |
| `bulk.open` sha | 錯的 sha → 15 | 不比對 |
| 版本規則 | 相等重裝、`+meta` 不同、跨通道同 REL(沒有 / 有 key 6)、降級(沒有 / 有 key 6) | 拿掉跨通道規則 |
| gate | `rel` + T → FAIL;`rel` 無釘選 → FAIL;`wsl` 放別把 → FAIL | 只檢查「不含 T」 |
| `release-sign.sh` | 對 wbox / dirty / bench(`BATMAN_BENCH_TRUST`)/ `wsl` / `ci` / 未知通道的 payload、`rel` 但內建 T → 拒簽 | 拿掉檢查 |
| 鑰匙檔 | 缺、多行、壞點、min-serial 0 → reason 21 | 預設 min-serial 0 |
| iifname | root 開 `SO_MARK=0x01000000` 的 socket 連 8095 → 丟 | 只有 mark 的規則 |
| 8095 搶占 | 一般使用者先佔 8095 → `status` 報 `http_bind_failed` | 不回報 |
| bearer | 用 `X-Batman-Session` 當 `X-Batman-Upload` → 401;bearer 不在 log / 診斷包 | 共用同一個值 |
| AEAD 失敗 | 偽造 `/msg` 後 session 仍可用;持續偽造 11 分鐘 → session 照樣因閒置關閉、`msgs` 不變 | 解密前就 `msgs++` / 刷新 |
| 窗模式只收擁有者 | 兩個成員 session 佔槽時擁有者的 PUT 流程仍完成 | 收成員 |
| tmpfs | provd 建第 17 個 inode → ENOSPC;`payload` 換成指向 `/etc/shadow` 的 symlink → helper 刪的是 symlink 本身 | 沒有 `nr_inodes`;`RemoveAll` |
| tar | 每一包惡意 tar(型別、尾端成員、尾端 gzip、成員數、總量) | 拿掉該項檢查 |
| 串流 | worker 期間 helper RSS 不隨 payload 大小成長 | 用 `[]byte` 的 `Exec` → 長約 111 MiB |
| 同時 sysupgrade | `write-hang` 中跑 sysupgrade → stage 1 拿不到 flock → 拒絕 | 拿掉鎖檢查 |
| ramfs 有 flock | ssh sysupgrade 走完 stage 2(`stage-root` + `apply` 在 ramfs 裡拿得到 flock) | `RAMFS_COPY_BIN` 沒有 flock → stage 2 rc 18、重開回舊槽 |
| 背景子程序不帶鎖 | `commit` 回來後立刻另一個 `batman-slot` 拿得到鎖 | `addr_defer_release` 沒有 `9>&-` → rc 14 |
| 讀者用共享鎖 | 讀者每 10 ms 試拿,同時寫者 200 次 → 0 次 rc 14 | 讀者用排他鎖、寫者不重試 |
| 一般 DEV image 沒有鑰匙 | Go 單元測試 + 離線 gate 檢查:一般 `wsl` image 的 `update.check` → reason 24;bench build → 通過(不在 02 / 04 上裝一般 image) | 一般 DEV 也放 T |
| 寫者重試在 target busybox 上真的等 | qemu / 節點跑 `slot_lock`:另一個持鎖 2 s → 第 3 次重試拿到 | `sleep 0.2`(target 上直接失敗;host 上會假 PASS) |
| 只讀 `/rom` | overlay 放 T.pub → `update.check` 仍 24、`trust` = `none` | 讀 `/usr/share/batman` |
| bench 旗標來源 | `batman-release.env` 含 `BATMAN_BENCH_TRUST` → stamp FAIL;環境變數設了但沒有 `--bench` → 一般 image | 讀環境變數 |
| CI 不建 bench | `build-firmware.yml` 以 bench 建 → FAIL | 接受 bench |
| stamp 先刪鑰匙檔 | 同一棵樹先 bench 後一般 → 一般 image 沒有鑰匙檔 | 不 `rm -f` |
| `trust` 欄位 | 一般 → `none`、bench → T 的指紋、壞檔 → `bad` | 沒有欄位 |
| tick 與 prepare | 接縫讓 tick 落在關窗與啟動 worker 之間 → worker 照常成功 | 不在同一個 `updMu` 內 |
| 持鎖動詞不留鎖 | 每個持鎖動詞回來後 1 s 內 `flock -n` 拿得到 | 背景子程序沒有 `9>&-` |
| signrel 拒簽沒有 T 的 payload | 對一般 image 的 payload → 拒簽;`--allow-no-key` → 簽 | 什麼都簽 |
| disarm tick | arm 失敗後 disarm 回 14 → 下一個 tick 成功並清 `apply_boot_id` | 只在啟動時重試 |
| 租約失敗 | 有寫入 fd → 15;`leases-enable` = 0 → 21 | 一律 21 |
| sock peer pid | `provd-id-pid`(既有) | — |
| board 全串 | S key 2 = `bcm2711` → reason 3;`metadata board=` ≠ S → 11 | 用 provd 短字串比 |
| 格式契約 | `signrel.py` 正向物件 Go 接受;`--bad-sig`、`--wrong-board`、`--unparsable-version`、`--mismatch-size`、`--key other` Go 都拒絕 | 拿掉 Go 任一檢查 |
| 垃圾 rootfs | 有效簽章、前段照抄、rootfs 是垃圾 → reason 11、目標槽沒動 | 只在寫入時驗 |
| CI 出貨 gate | `build-firmware.yml` 以 `rel` + T 建 → FAIL | gate 只在 `build-board.sh` |
| 通道白名單 | `BATMAN_CHANNEL=foo` → stamp 失敗 | 只檢查非空 |
| `bootinfo` 只讀 stdout | 接縫讓 `bootinfo` 在 stderr 印 `verified=<假 sha>` → helper 不採用 | 合併 stdout / stderr |
| aclog 精確比對 | `NOT-COMMITTED`、`version=…wsl.2` 對 `…wsl.25` → 不算 | 子字串比對 |
| apply 前提看槽 | helper 重啟後(記憶體清空)pending 與 VERIFIED 都在 → apply 可用 | 看記憶體 |
| PUT 不綁 IP | 經 BLE `bulk.open` 後 PUT 成功 | 綁 HTTP session 的來源 IP |
| 跨通道 key 7 | min_from 與目前版本沒有順序 → reason 4 | 當作通過 |
| mount namespace | helper 的 `write` 被 KILL 後 `/proc/mounts` 沒有目標分割的掛載 | 不 unshare |
| `precheck-node` 在 namespace | `precheck-node` 被 KILL 後 config-save `--save` 照常成功 | 在 init namespace → p5 ro 掛載殘留、存檔失敗 |
| `rebooting` 寫不進 | p6 唯讀 → apply 回 `E_STORAGE`、tryboot 旗標 0、不重開 | 照樣重開 |
| 第一遍中移除擁有者 | 第一遍中 `owner/remove` → status 0、目標槽沒有 BAD | 一律報 22 |
| tmpfs 沒掛上 | init 掛載失敗 → jail 裡沒有 rw 的 bulk 目錄 | 照樣 rw 掛普通目錄 |
| 讀取租約 | uid 471 行程持有 `O_RDWR` fd → prepare → reason 15、目標槽沒有 BAD;fd 在 prepare 前關掉 → 正常完成 | 拿掉租約 → 翻 1 byte → 目標槽 BAD(0 + 22) |
| `write` 清 overlay | v2 退回後重裝同一份 v2 → 第二次試用的 overlay 是新的 | `write` 不做 `clear_root` → 標記檔還在 |
| arm 失敗後 | arm 失敗 → 操作員手動 apply → 重啟 helper → tryboot 旗標仍是 1 | 不清 `apply_boot_id` |
| `rebooting` 時機 | arm 成功後、回應前被重開且試用 panic → 6 + 18 | 回應後 2 s 才寫 → 23 |
| bearer 格式 | 窗開、bearer 缺 → 空 header PUT 被拒 | 空字串進 constant-time 比對 |
| tmpfs 檢查 | init 沒掛 tmpfs → `bulk.open` reason 21 | 不檢查 |
| worker rc 14 重試 | 外部持鎖 15 s → worker 成功 | 不重試 → 21 |
| provd 重啟取回 bearer | 窗開著時重啟 provd → 下一次 poll 取回 → PUT 成功 | bearer 只在 provd 記憶體 |
| key 8 與 92 | 清單只列 92 改前 → 那一槽第一次開機後 reason 5;改前改後都列 → 通過(`signrel.py` / `release-sign.sh` 的測試) | — |

⚠️ NEEDS-NODE(上機才知道):`sysupgrade -F` 在 app 寫入中強制時,stage 2(ramfs)遇到非 helper 的 `batman-slot` 被殺後留下的掛載時,是否 rc 14 → 靜默重開回舊槽(A9-m16;helper 自己的呼叫在 mount namespace 裡,不會留下);`bootinfo` 實際耗時。

#### 12.5.17 CDDL 要改的(加到 §12.4)

`update-progress` 加 key 4(sha256)/ 5(to_version);`bulk-open-req` 加 key 2 = sha;`bulk-open-resp` key 2 = 現行 AP 密碼、加 key 6 = 上傳 bearer;reason-code 加 21 / 22 / 23 / 24(這個 image 沒有根鑰匙,不能經 app 更新),status key 15 加 `trust`,18 的文字改為「新版沒有完成試用」;協定 §4.2 加 `X-Batman-Upload`、AEAD 失敗不中止 session、409 的條件。

#### 12.5.18 使用者決定(2026-11-11)

1. 只有 bench build(`BATMAN_BENCH_TRUST=T`,給 02 / 04)信任公開的 T;一般 `wsl` image 不放鑰匙(2026-11-11 選 A,取代「DEV 信任 T」);不改用 R_dev。
2. `ci` 與一般 `wsl` 相同:不放鑰匙。
3. 公開發布不另設檢查(選 A 後取代「R 產生前不發公開 release」):一般開發版不含鑰匙,公開了也不能經 app 更新。

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
| A4-m5 / B4-m8 `batman-slot` 新動詞 | `write`、`arm`、`disarm`、`bootinfo`;`reboot committed`(§3.7.3) |
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

## 附錄 F. v7.3 審查回應(A9 = `p3-review-v73-A.md` 0 / 2 / 17、B9 = `p3-review-v73-B.md` 0 / 0 / 14)

兩個 MAJOR 都是 v7.3 自己加的機制帶進來的;v7.4 的修法是**拿掉**機制,不再加新的。

| 發現 | 處理 |
|---|---|
| A9-MAJOR-1 `bootinfo` 讓 helper 每 15 s 持鎖 | §3.7.4:helper 內 `slotMu`;`bootinfo` 只在啟動、自己的寫入後、check 時跑;bootConfigOK 用快取 |
| A9-MAJOR-2 check 快取讓暫時性拒絕重播 | §3.7.4:只快取簽章驗證 |
| A9-m1 `written` 不是槽的實況 | §3.7.4:拿掉 `written`;`bootinfo` 加 `bad=`;第 9 / 10 列看目標槽 |
| A9-m2 記憶體失敗沒綁嘗試 | §3.7.4 第 3 列 |
| A9-m3 / B9-m11 第 6 列 disarm | §3.7.4「helper 啟動時」的條件 |
| A9-m4 第 9 / 10 列沒看 autocommit.log | §3.7.4 第 8 列(`aclog_off`,取代 `bad_slot_at_apply`) |
| A9-m5 pending 到期 | §3.8.2:`bulk.open` 延長 pending |
| A9-m6 / B9-m6 窗關後 PUT、O_TRUNC | §3.8.2 409;§3.7.5-1 worker unlink |
| A9-m7 / B9-m7 update-last 多寫者 / 原子性 | §3.7.4 `updMu` + tmp/fsync/rename |
| A9-m8 版本規則 | §3.7.1 新表 |
| A9-m9 harness 鎖外掛載 | §3.7.3 列出;harness PR(#290) |
| A9-m10 / B9-m2 `bootinfo` 輸出契約 | §3.7.3、§3.7.4 |
| A9-m11 / B9-m14 舊文字矛盾 | §3.7 / §3.8 整段重寫,§12.5 改成索引 |
| A9-m12 結束碼漏項 | §3.7.3 表 |
| A9-m13 apply 中移除擁有者 | §3.7.4 apply 列 |
| A9-m14 / B9-m9 gate 與鑰匙的寫者 | §3.7.2 |
| A9-m15 / B9-m13 負對照 | §12.5 表 |
| A9-m16 `-F` stage 2 殘留掛載 | §3.7.3「拿到鎖後卸載」;⚠️ NEEDS-NODE |
| A9-m17 舊 VERIFIED 殘留 | §3.7.3:VERIFIED 綁 boot_id |
| B9-m1 pid 冒充 | §3.7.3 持有者規則 |
| B9-m3 每 15 s 拿鎖 | 同 A9-MAJOR-1 |
| B9-m4 AEAD 失敗的副作用 | §3.8.1 |
| B9-m5 bearer 與 session id | §3.8.2 `X-Batman-Upload`;取塊 DoS 列界線 |
| B9-m8 被移除擁有者寫入的槽 | §3.7.4 界線(不加新的 invalidate 動詞:有簽章、讀回過,只有 from_slot 壞掉時才會開進去) |
| B9-m10 成員佔 HTTP 槽 | §3.8.1 窗模式只收擁有者 |
| B9-m12 FAT 不分大小寫 | §3.7.3 |

## 附錄 G. v7.4 審查回應(A10 = `p3-review-v74-A.md` 0 / 3 / 17、B10 = `p3-review-v74-B.md` 0 / 0 / 14)

三個 MAJOR 都是 v7.4 寫進去的規則;v7.5 兩個以拿掉機制修正、一個把 gate 改成獨立腳本。

| 發現 | 處理 |
|---|---|
| A10-MAJOR-1 / B10-m8 PUT 綁 HTTP session 來源 IP,正常流程沒有那個 session | §3.8.2:拿掉 IP 綁定,bearer 是唯一憑證 |
| A10-MAJOR-2 / B10-m1 argv[1] 規則把活著的持有者判死 | §3.7.3:只看 pid + starttime(最後一個 `)` 之後第 20 欄);不看 argv / uid |
| A10-MAJOR-3 / B10-m3 CI 出貨路徑沒有 gate | §3.7.2:`check-release-key-gate.sh` 獨立腳本,`build-board.sh` 與 `build-firmware.yml` 都呼叫 |
| A10-m1 永久失敗重試 / tick 阻塞 | §3.7.4:最多每 10 分鐘重試;tick 用 TryLock |
| A10-m2 簽章快取的鍵 | §3.7.4:整份 manifest bytes 的 sha256 |
| A10-m3 / B10-m6 `armed` 寫入時機 | §3.7.4:拿掉 `armed`;arm 前寫 `apply_boot_id`;啟動時 disarm 看 `apply_boot_id` + `!rebooting` |
| A10-m4 / B10-m7 aclog 比對 | §3.7.4:欄位整個相等、含 `COMMITTED-BY-OPERATOR`、讀 ≤ 1 MiB、`O_NOFOLLOW` |
| A10-m5 worker 遇 rc 14 | §3.7.5-7:同一個 fd 重試 3 次 |
| A10-m6 pending 寫者 / bulk.open 呼叫者 | §3.7.4 `updMu`;§5.1 `bulk.open` 要是 pending 的擁有者 |
| A10-m7 bearer 的擁有者 | §3.8.2:helper 產生,經 poll 交給 provd |
| A10-m8 apply 前提 | §3.7.4:看目標槽 VERIFIED + boot_id |
| A10-m9 reason 18 的 240 s | §3.7.4 文字改正(`batman-slot:878-881`) |
| A10-m10 `92-batman-ramoops-fix` | §3.7.1 key 8、§4 |
| A10-m11 鑰匙檔讓 build 變 DIRTY | §3.7.2 `.gitignore` |
| A10-m12 版本規則 vs D12 | §3.7.1:正式 > 任何 `-CH.N` |
| A10-m13 write 子程序繼承 stdin | §3.7.3 |
| A10-m14 phase 1 的「已收」 | §3.7.4 第 1 列 |
| A10-m15 上傳檔刪除時機 | §3.8.2、§4 清理表統一 |
| A10-m16 p6 壞 | §6 |
| A10-m17 / B10-m13 其他段落矛盾 | §4、§5.1、§5.3、§6、§7、§8、§10 改;harness 的 README / signrel 進 harness PR |
| B10-m2 垃圾 rootfs 毀退路 | §3.7.5-5:第一遍只驗不寫(唯一新增的機制,防真實的攻擊路徑) |
| B10-m4 通道白名單 | §3.7.2 |
| B10-m5 release-sign 在 payload 上重跑 gate | §3.7.2 |
| B10-m9 窗與備援同時成立 | §3.8.1 |
| B10-m10 per-IP 429 | §3.8.1:拿掉 |
| B10-m11 殘留掛載 | §3.7.3:helper 用 mount namespace;不卸載別人的掛載,major:minor 比對 |
| B10-m12 跨通道 key 7 | §3.7.1:沒有順序 → reason 4 |
| B10-m14 `slot_is_bad` 既有問題 | §11 checklist |

## 附錄 H. v7.5 審查回應(A11 = `p3-review-v75-A.md` 0 / 1 / 15、B11 = `p3-review-v75-B.md` 0 / 2 / 7)

| 發現 | 處理 |
|---|---|
| A11-MAJOR-1 `write` 漏 `clear_root` 與 precheck 其他項目 | §3.7.3:照 `stage-root` 的順序(precheck → begin_write → clear_root → 串流) |
| B11-MAJOR-1 / A11-m4 被入侵的 provd 保留寫入 fd,兩遍之間改內容 | §3.7.5-1:unlink → fchown / fchmod → `F_SETLEASE F_RDLCK`;第二遍重跑檢查;⚠️ `leases-enable` 待上機 |
| B11-MAJOR-2 `wsl` / `ci` 不出貨沒有機制 | §3.7.2 發布點 `--publish`;使用者決定 R 前不發公開 release(§12.5.18-3) |
| A11-m1 arm 失敗後的 disarm 取消操作員 | §3.7.4:arm 失敗、啟動 disarm 後都清 `apply_boot_id` |
| A11-m2 `rebooting` 的 2 s 窗 | §3.7.4:arm 成功立刻寫 |
| A11-m3 bearer 經 poll 的延遲 | §3.11-12:10 s 內重試 |
| A11-m5 孤兒 write 讓 status 報 0 | §3.7.4:rc 14 60 s 後重讀;§3.7.3 rc 14 含孤兒占 boot 目錄 |
| A11-m6 zombie | §3.7.3 持有者規則看第 3 欄 |
| A11-m7 `attempt_boot_id` 沒有讀者 | 拿掉 |
| A11-m8 刪檔規則三個版本 | §3.8.2 統一成一條;prepare 失敗不刪 |
| A11-m9 窗關 / `updating` 時點 | §3.1-5、§3.7.5-1:prepare 回應前;步驟 1 失敗 → 15 |
| A11-m10 `bulk.open` 擁有者檢查只在 §5.1 | §3.8.2 |
| A11-m11 文字錯誤 | rc 14 列、斷電理由、HTTP session、§12.5 索引、§3.11 編號 |
| A11-m12 §10 檔案清單 | §10 |
| A11-m13 過渡版通道與版本 | §3.7.2 |
| A11-m14 缺的負對照 | §12.5 表 |
| A11-m15 哪些動詞進 namespace | §3.7.3:只有 write / arm / disarm / bootinfo |
| B11-m1 鎖與 `.busy` 不是原子 | §3.7.3:symlink 鎖、`.busy` rename、格式錯 = 忙 |
| B11-m2 starttime 測試向量 | §3.7.3、§12.5 |
| B11-m3 namespace 副作用 | §3.7.3、§7 |
| B11-m4 bearer 格式 | §3.8.2 |
| B11-m5 兩遍與 boot 檔 | §3.7.5-5 / 6 |
| B11-m6 tmpfs 沒掛上 | §3.8.2 `fstatfs`;選配的窗外縮 tmpfs 不做(不必要的機制) |
| B11-m7 舊文字 | §4、§5.3、§12、§12.5;§7「每個 poll 週期刪檔」現在與 §3.8.2 一致,保留;harness README / signrel 在 harness PR |

## 附錄 I. v7.6 審查回應(A12 = `p3-review-v76-A.md` 0 / 0 / 18、B12 = `p3-review-v76-B.md` 0 / 1 / 6)

| 發現 | 處理 |
|---|---|
| B12-MAJOR-1 / A12-m14 發布檢查不在真正的發布路徑 | §3.7.2:`publish-release.sh`(唯一發布方式)+ Batman `release-guard.yml`(不過 → 改回 draft)+ firmware gate 獨立 job(`release`、`publish-packages` 都 needs);gate 腳本放 Batman repo |
| A12-m12 / B12-m1 鎖與 `.busy` 的持有者規則 | §3.7.3:改用 `flock`,拿掉 pid / starttime / zombie / symlink / TAMPER;子程序繼承 fd,只殺 shell 時鎖仍在 |
| A12-m1 `arm` 沒拿鎖 | 所有動詞都拿 flock |
| A12-m2 disarm 失敗仍清 `apply_boot_id` | §3.7.4:回 0 之後才清 |
| A12-m3 `rebooting` 後 helper 掛、沒重開 | §3.7.4 界線 |
| A12-m4 `rebooting` 寫不進 | §3.7.4、§5.1:disarm、`E_STORAGE`、不重開 |
| A12-m5 `precheck-node` 被殺留 p5 掛載 | §3.7.3:`precheck-node` 也進 namespace |
| A12-m6 prepare 被拒關不關窗 / 清理表矛盾 | §3.8.2、§4、§6 |
| A12-m7 worker 中重開窗 | §3.8.2:`E_BUSY` |
| A12-m8 poll 延遲的 PUT 佔 RAM | §3.8.2:依同一條規則刪,`size=` 已涵蓋 |
| A12-m9 / B12-m2 SIGIO 處理 | 拿掉 |
| A12-m10 rc 14 重試從哪開始 | §3.7.5-7:`lseek(0)` 從第二遍開頭 |
| A12-m11 「格式不對 = 忙」沒有出路 | 隨 flock 拿掉 |
| A12-m13 dirfd 時點 | §3.8.2:每次操作才開 |
| A12-m15 poll `http` 欄位、§5.1、§3.11 | §3.8.2、§5.1、§3.11-5 |
| A12-m16 dispatch | §3.7.3 |
| A12-m17 apply 呼叫者 | §3.7.4、§5.1 |
| A12-m18 第一遍中移除擁有者 | §3.7.5-9:status 0 |
| B12-m2 租約拿不到的 reason | 15(app 重傳) |
| B12-m3 namespace 裡的 p5 / p7 掛載 | §3.7.3 |
| B12-m4 過渡版繞過拒簽檢查 | §3.7.2:`release-sign.sh --test-key`,檢查照跑 |
| B12-m5 tmpfs 沒掛上仍 rw 進 jail | §3.8.2:不掛進 jail |
| B12-m6 文字 | §4 清理表;rc 14 只在 `precheck`(§3.7.3) |

## 附錄 J. v7.7 審查回應(A13 = `p3-review-v77-A.md` 0 / 1 / 15、B13 = `p3-review-v77-B.md` 0 / 1 / 5)

使用者 2026-11-11 選 A:危險從 image 拿掉,不在發布點擋 —— 一般開發版不放根鑰匙,只有 bench build 放 T;publish 腳本、release-guard、firmware 發布 job 整套拿掉。

| 發現 | 處理 |
|---|---|
| B13-MAJOR-1 / A13-m12 release-guard 的繞過 | 選 A:guard 整套拿掉;一般開發版公開了也不能經 app 更新(§3.7.2) |
| A13-MAJOR-1 sysupgrade ramfs 沒有 flock | §3.7.3:`RAMFS_COPY_BIN` 加 `/usr/bin/flock`;flock 不存在 → rc 18;sysupgrade 臂負對照 |
| A13-m1 / B13-m1 讀者試拿讓寫者偶發 rc 14 | 讀者用共享鎖;寫者重試約 3 s |
| A13-m2 / B13-m1 背景子程序繼承 fd 9 | `9>&-` + lint |
| A13-m3 disarm 失敗沒人重試 | §3.7.4 disarm 的 tick 規則;apply 全程持 `slotMu` |
| A13-m4 / B13-m2 舊文字 | §3.7.5-1、§3.7.6、§4、§12.5 |
| A13-m5 / B13-m3 租約失敗的 reason | `EAGAIN` 第一次 15、同 sha 第二次 21;`EINVAL` 21;§12.5 對齊 |
| A13-m6 rc 14 列的孤兒 | 孤兒 `write` 仍持 flock |
| A13-m7 刪檔綁 provd 的 poll | helper 自己每 4 s 的 tick |
| A13-m8 鎖檔不存在 / 開不了 | 不存在 = 不忙;開不了 = 忙 + log |
| A13-m9 harness / Go 測試的新 rc 14 | §10 harness 清單 |
| A13-m10 joinwatch 自動重開 | §11 checklist(既有問題) |
| A13-m11 D 狀態子程序 | §6 |
| A13-m13 非 bcm 板子的 gate | 隨選 A 簡化:沒有 A/B payload 的板子不放鑰匙,不經 app 更新 |
| A13-m14 TRACE 含 `bootinfo` | 唯讀的不加 |
| A13-m15 `precheck-node` 不在 `slotMu` | 加入 |
| B13-m4 `--publish` 沒驗簽章鏈 | 隨 `--publish` 拿掉 |
| B13-m5 `.img` 解析契約 | 隨 guard 拿掉 |

## 附錄 K. v7.8 審查回應(A14 = `p3-review-v78-A.md` 0 / 0 / 13、B14 = `p3-review-v78-B.md` 0 / 1 / 8)

**更正**:附錄 J 寫「A13-m4 / B13-m2 舊文字已改」,實際大部分沒改。v7.9 以 grep(`.busy`、`batman-slot.lock`、`flock -n`、reason 21、DEV 信任 T)逐處改,並在送審前重跑一次(輸出在 #254 紀錄)。

| 發現 | 處理 |
|---|---|
| B14-MAJOR-1 bench image 可能經 CI 自動公開 | §3.7.2:bench 旗標只從 `build-board.sh --bench` 來、`batman-release.env` 出現就 stamp 失敗、CI 遇 bench 一律 FAIL |
| A14-m1 `sleep 0.2` 在 target busybox 失敗 | §3.7.3:`sleep 1` × 3;先 `command -v flock` → 18;負對照在 target busybox 跑 |
| A14-m2 / B14-m1 舊文字 | §3.7.3 write 列、§3.7.5-7、§4、§5.1、§7、§10(含 autocommit `:550`) |
| A14-m3 / B14-m2 「DEV 信任 T」殘留 | §12.2-5、§10 |
| A14-m4 / B14-m2 prov_test 怎麼信任 T | 只經 `--bench`;一般 prov_test 不放鑰匙 |
| A14-m5 / B14-m5 bench 旗標來源、白名單、殘留、版本 | §3.7.2:參數、只收 `T`、`rm -f`、`+… .bench` |
| A14-m6 bench 節點裝一般 image | §6;`signrel.py` 預設拒簽;負對照改成 Go + 離線 gate |
| A14-m7 / B14-m4 沒鑰匙時 app 的文字、看不到信任狀態 | reason 24;status `trust` |
| A14-m8 `apply_boot_id` 與 tick | §3.7.4:拿到 `slotMu` 後才寫;`updMu` 讀-改-寫;p6 唯讀時記憶體記「已 disarm」 |
| A14-m9 / B14-m7 刪檔 tick 與 prepare | §3.8.2:同一個 `updMu` |
| A14-m10 / B14-m6 EAGAIN 計數 | 拿掉計數;app 重試 3 次;§7 界線 |
| A14-m11 孤兒留下 boot 目錄 | §3.7.5-4 |
| A14-m12 `RAMFS_COPY_BIN` 的 repo、lint 範圍 | §10 改 Batman feed;§3.7.3 lint |
| A14-m13 shell 讀者用 fd 形式、D 狀態的 app 文字 | §3.7.3、§3.11-9 |
| B14-m3 helper 從 overlay 讀鑰匙 | 只讀 `/rom`;⚠️ 上機確認 |
| B14-m8 lint 只抓 `&` | §3.7.3 lint 範圍 + 通用測試 |
