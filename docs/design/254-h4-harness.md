# Design: #254 PR-H4 — P3 的 harness — **v8.1(凍結)**

**狀態**:**凍結**(v8.1,2026-11-03)。v8 兩位審查都是 APPROVE-WITH-CHANGES、0 BLOCKER / 0 MAJOR(A 12 MINOR、B 9 MINOR),都判已收斂;v8.1 = v8 + 兩位的 MINOR(附錄 H)。B 建議不需要再一輪完整審查。凍結條件:§7 探針(D22)在現場完成並附原始輸出之後,才開 harness PR(H4-U7)。v8 在 v7 上做局部修改(附錄 G);v7 在 v6 上做局部修改(附錄 F);v6 在 v5 上做局部修改:§1.1、§3.1、§4.1、§4.2、§4.4、§4.5、§5.7、§8.1、§8.2、§9、§12、§15、§17、附錄 A。v5 審查意見的處理見附錄 E;v4 的處理見附錄 D。

**歷程**:

| 版本 | commit | 審查 A | 審查 B | 備註 |
|---|---|---|---|---|
| v1 | a31489b | REJECT 2 / 8 / 15 | REJECT 2 / 12 / 11 | |
| v2 | d5cf7ed | REJECT 1 / 9 / 22 | REJECT 1 / 10 / 19 | 整份重寫 |
| v3 | 282b48b | REJECT 0 / 4 / 17 | REJECT 1 / 3 / 17 | 兩位都說骨架已收斂、不需要重寫 |
| v4 | 56dcf42 | REJECT 1 / 3 / 13 | REJECT 1 / 1 / 11 | 兩位都說骨架已收斂;BLOCKER 都是 v4 新加的「用 static key 認目標」 |
| v5 | 40a598d | **AWC 0 / 1 / 9** | REJECT 0 / 2 / 14 | 兩位都判已收斂;v4 的 BLOCKER 已解 |
| v6 | 1181c75 | **AWC 0 / 2 / 10** | **AWC 0 / 0 / 8** | 兩位都判已收斂 |
| v7 | c9dac70 | **AWC 0 / 1 / 12** | **AWC 0 / 1 / 9** | 兩位都判已收斂;MAJOR 是同一條(UD8b 到不了 worker) |
| v8 | 3b2aa32 | **AWC 0 / 0 / 12** | **AWC 0 / 0 / 9** | 收斂 |
| v8.1 | (本版) | | | 凍結:v8 + MINOR(附錄 H) |

- v3 每條意見的處理見附錄 C。
- 審查報告在 `254-reviews/h4-review-v{1,2,3,4,5,6,7,8}-{A,B}.md`。

**上層**:
- `254-p3-impl.md` v7.1(凍結,`feat/254-p3` @ dfedd03),以下稱 P3;
- `254-h23-harness.md` v14,以下稱 h23;
- `219-protocol.md` v0.7 + `.cddl`。

**流程**:P3 D1 規定 H4 先 merge,之後才開始 P3 實作。H4 走獨立的 harness PR(#290)。

## 0. 一句話

H4 把 P3 的測試要求全部變成可以執行的單位與臂。來源包括:P3 §6 的每一列、§7 的每一條負測試、§8 的每一個斷言片語,以及附錄 D-1…D-17。逐條對照在附錄 A。

每一臂都要寫清楚:
- 在什麼載具上跑(§2);
- 怎麼誘發;
- 斷言什麼;
- 負對照是哪一種(§6.2);
- 副作用,以及怎麼還原。

需要這些工具:
- WSL 上的 owner client `peer.py`;
- Windows 端的 BLE 薄橋;
- 實驗室常駐的 S20 手機 relay;
- 新卡 lib(chain1 步驟 1–6,加上可續期的 dead-man);
- 04 本機的 eth 側模擬;
- 節點端的 undo 執行器。

bench 的基準狀態分兩段:P3 之前是 **S0-pre**,P3 之後是 **S0**(§3)。

**驗證分四段,各自附證據**:
1. 離線 / CI;
2. 不改節點的實測;
3. 改節點、但在 lease 底下立刻還原的實測與預演;
4. 一次現場,之後是 P3 rc 上機(S 型負對照與正向全套,是 P3 PR 的閘門)。

## 1. 決策、範圍、事實

### 1.1 使用者決策

| # | 決定 | 來源 |
|---|---|---|
| H4-U1 | HTTP 的 AP client 用 S20 + Termux sshd(專用公鑰) | #254 留言 6576525655 |
| H4-U2 | 新卡臂用 chain1 式的新卡 | 同上 |
| H4-U3 | BLE 用桌機的 Windows bleak | 6576687238 |
| H4-U4 | S20 是備用機,常駐實驗室、常接電源;可以為了測試調設定 | 2026-11-02 |
| H4-U5 | eth 側的臂用 04 本機模擬(netns + veth);真 eth0 驅動那一段列為誠實界線 | 2026-11-02 |
| H4-U6 | WSL venv 依 `requirements.txt` 以 `--require-hashes` 安裝(已裝) | 2026-11-02 |
| H4-U7 | **一次現場**,依序:重燒 02 / 04 → **02 暫時接網路線到實驗室交換器** → harness 建 S0-pre → 手機設定(本機 QR)→ §7 探針在 04 → E-H13。H4 PR 等這次現場做完、收到證據才開 | 2026-11-02 |
| H4-U8 | D-9「試用轉 committed 那一刻存設定」的負對照,只由 Go 單元測試證明(UD16、UD12) | 2026-11-02 |
| H4-U9 | `fw-badinclude` 保留在節點上真的跑(02) | 2026-11-02 |
| H4-U10 | 已下載:WSL `qemu-user-static` 8.2.2;Windows bleak 3.0.2(依 hash 重裝) | 2026-11-02 |
| H4-U11 | **HT14(`firewall stop`)在 04 上做**:最長 60 s 沒有防火牆,只暴露在實驗室區網 | 2026-11-02 |
| H4-U12 | **EE1 用 WSL 非 root 沙箱**(`unshare -r`,加上逃脫的負測試);不用 `dv-sbx.sh`,也不在桌機上以 root 跑 | 2026-11-02 |
| H4-U13 | 新卡期限沿用 chain1 的一次性 dead-man(§4.4 開頭) | 2026-11-03 |
| H4-U14 | S0-pre 的認領改用既有 `provclient`;建 S0-pre 的認領與 join 改成正式 app 的手動案例 M1、M2(`h4-manual-cases.md`) | 2026-11-03 |
| H4-U15 | **H4 的 harness PR 不等現場**:現場項目(重燒、S0-pre、§7 探針、E-H13 本體、M1–M4)移到 P3 之後、app 有第一版時做,列進 #254 checklist。§7 探針的用途(P3 之前驗證 §3.8.1 規則可行)改由 **P3 的設計審查與 P3 自己的測試承擔**;原因:S0-pre 要用 app(P3 之後才有),探針腳本實作時被工具的安全機制擋下。取代 H4-U7 的「PR 等現場」 | 2026-11-03 |
| (待決) | 全套成本(§14);C0 QR 要用的 `segno`(PyPI,要同意下載;不同意就改成本機頁面顯示文字,由使用者手動輸入) | — |
| (沿用) | P3 D1、D2、D11、D20、D21、D22;h23 全部機制 | P3 §1.1、h23 |

**本設計自己決定、審查者可以攻的點**:
- 協定核心放 WSL;
- 接縫負對照都在 committed 槽上以 bind 執行;
- eth 側用 04 本機模擬;
- bench 由 harness 的長期擁有者持有;
- 認目標:每一臂在自己的交握裡驗 `node_cert`,DAC 必須等於庫裡釘選的那一張(§4.2);BLE、HTTP、sock 三種傳輸都一樣。

### 1.2 範圍

**本 PR 的檔案**:
- **主機 / 手機工具**:`tests/tools/peer/` 下的 `peer.py`、`blebridge.py`、`httprelay.py`、`netobj.py`(N0 的 net_config / net_secrets 產生器,沿用 `gen.py` 的 `sign1` / `encrypt`,對向量逐位元組 selftest)、`requirements-win.txt`、`sign-test-release.py`、`gen-p3-units.py`、`p3-units.tsv`。
- **主機端腳本**:`scripts/dv/` 下的 `phone-254.sh`、`fresh-254.sh`(chain1 改成 source 它)、`prov-p3-254.sh`(單位驅動)、`http-src-probe-254.sh`、`eeprom-sbx-254.sh`、`data/p3-payloads.sh`。
- **節點端腳本**:
  - `scripts/node/` 下的 `prov-ethsim-254.sh`、`prov-undo-lib-254.sh`、`uci-argv-shim.sh`;
  - `prov-wbox-254.sh` 擴充:`push-provd`、`set-fault`、新的 bind 目標與 killpoint 名字;
  - `prov-lease-254.sh` 的 dead-man 擴充(§5.7)。
- **判定**:`tests/judges/h4/`(§16)。
- **單位**:附錄 A 的全部單位,加上 `prov-bench-s0-254`。
- **CI**:peer、netobj、blebridge(假後端)、relay 的 selftest;判定的離線測試;`p3-units.tsv` lint;tmp-trust;shellcheck。
- **文件**:`docs/validation/s20-setup.md`、`docs/validation/h4-onsite.md`(現場步驟)。

**不在本 PR**:
- P3 的產品程式、Go 單元測試、mutant;
- 接縫的實作;
- U5;
- YubiKey 實機(UD15 NEEDS-PERSON;「release 拒收 T」是常規臂 UD-T1);
- bcm2710 真機;
- 晶片換表;
- iOS;
- 真 eth0 驅動路徑。

### 1.3 事實

2026-11-02 實查;main 2ecf1cb;04 與 02 都是 `1.5.14-wsl.22+2ecf1cb.fwce20a68`,都是 legacy。

| # | 事實 | 證據 |
|---|---|---|
| F-H1 | 04 的手機 AP 是 `phy1-ap0`,與 `eth0`、`bat0` 同在 `br-ahwlan`;沒有 `isolate`;FORWARD 是 ACCEPT;`br_netfilter` 已載入。⚠️ E-H8 尚未實測 | 04 唯讀;v1-B E6 |
| F-H2 | 桌機的上網走自己的 Wi-Fi | `Get-NetRoute` |
| F-H3 | **E-H9(部分)**:bleak 連上 04、02,讀 `STATUS` / `CTRL`;MTU 談到 517;`CTRL` = frame 244、msg 8192;沒有配對提示。**這是兩台都是 legacy 時做的,認出 04 靠的是 key 5,不代表 member 狀態也能這樣認**(F-H35) | 2026-11-02 輸出 |
| F-H4 | 試用中,會改狀態的動詞一律 `EBusy` | `node.go:198-206` |
| F-H5 | `-wbox` 永遠不會 auto-commit | `batman-autocommit:485-530` |
| F-H6 | 回到 Unclaimed 只能靠 p5 mkfs;不能移除最後一位擁有者(`EForbidden`) | `node.go:514-539, 890` |
| F-H7 | chain1:步驟 6 release → B committed unclaimed;dead-man 寫在 B 的 rc.local + `sleep 1500`;前提是「A committed $V」;新卡的狀態是 `ap=0`、`mesh=0` | `chain1-254.sh:10, 186-196, 265, 275, 280-297` |
| F-H8 | lease dead-man 的順序:kill run groups → unbind-all → 刪 killpoint 目錄 → 還原 upper helper →(`restoring` 就停在這裡)→ provd 重啟 → radio 還原 → 啟動服務。「never touches a slot or p5」。**鎖是每個指令各自拿,等 10 分鐘拿不到就不拿鎖照做** | `prov-lease-254.sh:14-18`;`ble-lib-254.sh:313, 327-345` |
| F-H9 | h23 的 bind 機制與封閉清單:bind 目標不含 batman-slot;killpoint 名字是 `txn-[1-5]` / `claim-*`;`upper-helper` 只寫目前槽 | `prov-wbox-254.sh:1-25, 50, 64-67` |
| F-H10 | h23 §17 的 dry-run;autocommit 不重設 PATH | h23 `:706-760`;`batman-autocommit:26-27, 69, 323` |
| F-H11 | prov_test 的 provd 只在 wbox image 裡;`--version` 沒有標記;test init 的 env 只收固定 key、純數字值;provd 的 log pid 是 `[1]` | `testenv_provtest.go:1-5`;`main.go:7, 53`;`batman-provd-test.init:24-33`;`prov-wbox-254.sh:149` |
| F-H12 | 只要有 BLE link 或 session 就撤廣播;約 900 s + jitter 換一次 RPA;inbound `MaxFrame` 512、`OutFrame` 244;廣播只有 UUID | `bluez.go:37, 233-236, 269, 597, 771-779`;`frame.go:12-17` |
| F-H13 | `verify.py` 需要 `pycddl` / `dissononce`;`Proxy` 在 pipe 上用 `select()`(Linux 可以) | `verify.py:23-36`;`transport_sock.py:75` |
| F-H14 | 02 的 eth0 沒有接線(carrier 0);04 的 eth0 段上只有桌機 | 02 唯讀 |
| F-H15 | **04 的工具**:`nc` 只能 `nc IP PORT`;**沒有** `timeout`、`ss`、`hostapd_cli`、arping、python3、socat、unshare、curl;**有** `netstat`、`tcpdump`、`uhttpd`、`wget`(= `uclient-fetch`,`-T` 是連線 / 請求逾時)、`flock`、`setsid`、`bluetoothctl` 5.72、`ip-full`(netns)、`iperf`、`openssl`;`ubus call hostapd.<if> get_clients` 可用;`NET_NS=y`、`VETH=m`(已載入)、`VLAN_8021Q=y`、`NF_TABLES_BRIDGE=m`;`tcp_syn_retries` = 6 | 04 唯讀;v3-A E5 |
| F-H16 | cmdline 有 `rootfstype=squashfs,ext4 rootwait=20 panic=10`;procd watchdog 30 s;**既有機制**:被 invalidate 的槽 cmdline 指向不存在的 PARTUUID 並保留 `panic=10` → panic 後回預設槽(#209 E0f 已實證);開機檔壞掉則會卡住、不會 panic | `/proc/cmdline`;`batman-slot:36, 376-386` |
| F-H17 | firstboot 會清掉只存在 overlay 的東西;`firewall stop` 會刪掉所有 nft 表;`fw4 start` 在已載入時會 `die` | v1-B E11;v3-B E7 |
| F-H18 | `strip-p5-prov` 只能在快照內用 | `prov-base-254.sh:12, 256-266` |
| F-H19 | P3 文件矛盾:`:168` 寫 reason 7,§5.1 / §8 寫 19 | P3 |
| F-H20 | WSL venv:`verify` 197 項、peer selftest 29 項都 PASS | 2026-11-02 |
| F-H21 | known-failures 只看 FAIL 行;pre-P2 條目的 ERE 比對任何版本 | `validation-known-failures.txt:25-35` |
| F-H22 | **`dv-sbx.sh` 只准在 CI 跑**(`GITHUB_ACTIONS` 檢查);它的隔離只防意外;`--base` 的 sha 是釘死的 | `dv-sbx.sh:3-10, 44, 62` |
| F-H23 | `network/join` 不在 `p3Types`;`owner/*`、`settings/*`、`status` 等在 → wsl.22 上回 `E_UNSUPPORTED` | `session.go:66-69, 623-625` |
| F-H24 | 04 的 `BATMAN_FEATURES` 有 `provd-p2(#254)`,沒有 P3 的標記 | `/etc/batman-build` |
| F-H25 | overlay 每個槽各一份 | v2-A E1 |
| F-H26 | `br-ots` 的 input 是 DROP;`docker0` 是 ACCEPT,目前 DOWN | v2 |
| F-H27 | provd 的 ops 一次只跑一個 | `server.go:182-184` |
| F-H28 | `batman-slot apply` 遇到帶 `root.squashfs` 的 payload,寫入前會檢查 magic `hsqs`,不符就 die;串流路徑(stage-root)不檢查;寫入前會把 SQ + 64 MiB 清零;已有 `corrupt-after-write` 這個 fault | `batman-slot:614-618, 638-668, 686` |
| F-H29 | `halow-setkey` 等鎖時不寫 log;P2 的 `--ap` 值放在 argv、沒有 `--ap-ssid`;它會放開 keyguard 並 `--save`;`.txn` 存在時拒絕 | `halow-setkey:45-50, 132-140, 165, 280-302` |
| F-H30 | `halow-status` 會對非 root 擁有的 fault 檔記 `WARN tamper` | `halow-status:111-113` |
| F-H31 | WSL `appendWindowsPath = false`;Windows Python 的絕對路徑;binfmt `qemu-aarch64` 的 flags = `POF` | `/etc/wsl.conf`;v3-B E10 |
| F-H32 | 04 的 `/tmp/dhcp.leases` 是 0 行;02、04 都有 `dhcp.ahwlan` | v2-B E8 |
| F-H33 | 02、04 **都沒有預設路由** | `ip route` |
| F-H34 | H3 收尾時 chain1 59 / 0 | commit c12567b |
| F-H35 | **`STATUS` 的 key 5(序號末 4 碼)只在 unclaimed / legacy 時才有**;member 沒有 | `server.go:60, 572-573` |
| F-H36 | **認領要用 `identity/claim.secret`**:root 0600,只存在節點上 | `node.go:520`;`provclient main.go:512-517` |
| F-H37 | **認領之後 dropbear 只收 key**(PasswordAuth off) | `prov-lock.sh:140-146` |
| F-H38 | **P3 §3.8.1 的兩條 nft 規則沒有 `counter`** | P3 `:379-380` |
| F-H39 | **EEPROM shim 從 firmware `5ec36f40` 起就有**:1.5.12-wsl.9 有 shim;1.5.12-wsl.2 與 1.5.11-rel.1 沒有 | firmware git ancestry(v3-B E5) |
| F-H40 | procd 的 `respawn 3600 5 0`:retry 0 = 無限重試,不會「用完」 | v3-B E9 |
| F-H41 | 04 的 `fs.protected_symlinks=1`、`protected_regular=2` | 04 唯讀 |
| F-H42 | 新卡入網後,openmanetd 會保留位址並重開一次 → IP 會換 | `99-halow-identity:21-24` |
| F-H43 | regdb:AU 有 ch 40(4 MHz、922.0 MHz,與 US 相同);DE 沒有 ch 40 | 04 regdb |
| F-H44 | N0 的 net 物件產生器:repo 裡沒有 `provgen.py`;現有的產生器是 `provclient/net.go:185-269`(Go,在節點上)與 `gen.py:302-330`(`sign1` / `encrypt`)。`gen.py` 的 `encrypt()` 用模組層的 `NET_ID` / `NET_VERSION`,而且 import 時就會跑一次全部向量,不能直接沿用 | `find`;原始碼;v4-A M1 |
| F-H45 | **`s_node`(Noise static)每次 provd 啟動都重新產生、只在記憶體**,協定禁止 app 快取它;**member 節點收到 NX msg1 一律回假 msg2**;交握完成後,同一條連線上的新 msg1 會被當成 transport 訊息 → AEAD 失敗 → 斷線 | `noise.go:29, 62-96`;`server.go:104-113, 673-683`;`session.go:300-321`;219 `:57, :515` |
| F-H46 | **交握第 2 則訊息的 payload = `node_cert`**:`{1: dac_chain, 2: s_node_pub, 3: boot_id, 4: ecdh_pub, 5: sig_static, 6: sig_ecdh, 7: sn}`;手機要驗 DAC 鏈(dev 版 = 自簽 + TOFU pin,而且 `device_id == hex(SHA-256(pub)[:9])`)、`sig_static` 對上交握裡實際的 `s_node`、`sn` 與 DAC 一致,以及 **DAC = 預期的目標**(只驗鏈不夠:任何持有 `psk_member` 的成員都能冒充別台);peer 已經會解析 `node_cert`(`cert[7]`) | 219 §3.3 `:55-78`;`peer_core.py:93` |
| F-H47 | **net_secrets** = COSE_Sign1,payload `{1: net_id, 2: version, 3: target = SHA-256(DAC pub), 4: 加密給 node_cert 的 ecdh_pub(P-256)}`;解密時 AAD 帶 target,`other` = net_id ‖ version。`network-join-req` 一定帶 key 31 owner-op | `wtxn.go:125-150`;`219-protocol.cddl:205-210` |
| F-H48 | lease 鎖 = `$BT/lock` 的 fd 9,每個指令各自拿(`lock` / `held`);`dm-fire` 在 lease **過期後**才動作,最多等鎖 10 分,拿到鎖之後**在同一個行程裡**呼叫 `role_fire_restore`;`dm_arm` 會殺掉舊的 dead-man 群組;`cmd_arm` 要求 lease 有效 | `ble-lib-254.sh:96-101, 137-155, 305-343`(`cmd_release` 在 lease 過期時 die:`:314-316`;`cmd_dm_fire`:`:327-340`);`prov-lease-254.sh:30-68` 。**更正(2026-11-03,04 實測)**:`lock()` 與 `cmd_dm_fire` 共用全域 `n`,main(2ecf1cb)上 dm-fire 實際只等 **30 s**;babe108 改成各自的計數器,`test-dv-ble-254` lockt 以 2ecf1cb 當負對照 |
| F-H49 | `batman-slot stage-root <dir>`(payload 不帶 `root.squashfs`)→ `begin_write`:disarm tryboot、invalidate 目標槽(寫 `BATMAN-BAD`)、清空 rootfs,然後印出裝置。`batman-slot` 沒有單獨的 invalidate / disarm 動詞 | `batman-slot:8-14, 423-436, 650-656, 900-917` |
| F-H50 | provd 的全域交握限速 20 次 / 分,fake path 也算 | `server.go:35, 645-660` |
| F-H51 | `provd_check` 的 `PROVD_KEYS` 沒有 `BATMAN_FAULT` | `ble-lib-254.sh:170` |
| F-H52 | 04 的 batman `bridge_loop_avoidance` = enabled、`stp_state` = 0(02 接線後 eth + mesh 兩條路同時存在時,靠它防迴圈) | 04 唯讀(v4-B m4) |
| F-H53 | 新卡的 bootstrap IP 是 `10.41.254.<隨機>`,入網後 openmanetd 再換一次;host key 每次重燒都重新產生 | `99-halow-identity:22-28` |
| F-H54 | Linux squashfs 在 mount 時檢查 `s_major`,不等於 4 就拒絕 | `fs/squashfs/super.c:158-166`(6.6;v4-A 核對) |
| F-H55 | WSL userns 沙箱:宿主上 yello 擁有的檔案在 userns 裡寫得進去;chroot 擋不住 userns 裡的 root;v4 寫的四條逃脫負測試,在沙箱外執行一樣會失敗(沒有鑑別力) | v4-B 實測 |
| F-H56 | provd 的 session 閒置上限:匿名 30 s、已認證 300 s,請求處理中不計(`server.go:29-30`、`session.go:121, 284-288`)。一則訊息超過 `max_msg` − 16(CTRL key 4 = 8192)時,必須依 §5.1 分塊;不分塊的話 provd 會斷線 | 04 實測 2026-11-03(E-H9) |

### 1.4 回報給 P3(P3 實作的第一個 commit 處理)

1. F-H19 的文字。
2. **§5 的接縫契約**:
   - 名字:Go fault、killpoint、shell fault;
   - shell fault 在所有 image 都有,只認 root 擁有的檔,其他擁有者記 TAMPER;
   - **T 的信任與 `release-min-serial` 都以 build tag 編進 prov_test helper**(RB 是 release image + bind 進去的 helper,所以不能靠 image 上的檔案);
   - provd 的 prov_test 標記;
   - test init 讀 `fault.provd`;
   - helper 的 ro 計數(`info.state` 的一個欄位)。
   - **完整清單**就是 §5.1、§5.2、§5.4 的三張表(Go fault 19 個、killpoint 3 個、shell fault 14 個)。這些比 P3 §8 凍結時的 10 個接縫多,**屬於凍結設計之外新增的產品程式**;其中 shell fault 會出現在**所有 image,包括 release**。因此 P3 第一個 commit 的程式碼審查與 `/security-review` 必須逐一涵蓋這批程式路徑,**特別點名 `upd-open-block`**(它拿掉的正是 worker 對 FIFO / 非 regular 檔的防線)。信任邊界:`batman_opf` 只接受 root 擁有、regular、非 symlink、link 1 的檔(`rundir.sh:44-52`),加上 `protected_hardlinks=1`(04 sysctl)。
   - **worker 的 fstat 檢查不符(不是 regular、link count、uid、大小)→ phase 0 + reason 11**:P3 §3.7.5 只寫了檢查,沒寫 reason;H4 的 UD8b-race 以 11 判定,請 P3 照這個寫進 §3.7.5。
3. **`BATMAN_FEATURES` 加 `provd-p3(#254)`**。
4. **pending 綁定驗它的信任集合**:H4 的 `unbind-all` 會刪 pending 與上傳檔。
5. **autocommit 的 `inet fw4` 檢查以 PATH 呼叫 `nft`**。
6. **兩條 nft 規則都帶 named counter**:`counter name batman_http_mark`(bridge 表)、`counter name batman_http_drop`(inet 表)。
7. **`batman-slot write`(串流路徑)只檢查 squashfs magic**:H4 的壞 rootfs 不動 magic(§8.1)。另外,§8 的「目標槽 kernel 壞掉」由 H4 改成「rootfs superblock 壞掉」,理由見 F-H16:kernel 壞掉會卡住、不會 panic。

## 2. 載具

| 代號 | 載具 | 能做 | 不能做 |
|---|---|---|---|
| **R** | committed release(S0-pre 或 S0) | 黑箱正向 | 接縫 |
| **RB** | R 加上 bind:`push-helper`、`push-provd`、shell fault、檔案 bind | 接縫負對照、注入、T 簽的 pending、上傳窗 | 跨重開(bind 與 `/tmp` 都會消失;`upper-helper` 只寫目前槽) |
| **RD** | RB + autocommit dry-run | autocommit 的判定 | 真 commit |
| **T** | 真試用:由 RB 的 helper 收下 T 簽的 payload(V = 受測的 rc,用 T 重新簽)→ 重開進試用 | phase 4 / 5 / 6、真 commit / revert | 試用中改狀態 |
| **W** | wbox held 試用 | 只用在 `fw-badinclude`(02) | 改狀態、commit |
| **F** | 新卡:B committed unclaimed,之後在 B 上再疊 R / RB | 新卡臂 | — |
| **L** | legacy:快照內 `strip-p5-prov`,由臨時擁有者認領 | legacy 臂 | — |
| **C** | CI(`dv-sbx` arm64)或 WSL(loop 檔、非 root 沙箱) | 兩板共用的 shell、eeprom-hooks、轉賣工具 loop | 真無線 |

**flip 規則**:每組正 / 負對照只差一個變數。

**pre-P3 上的 RB 前置**:wsl.22 沒有 P3 的 prov_test 產物。所以 `--pre-p3-full` **跳過所有需要 P3 產物的前置**(`push-helper`、T pending、上傳窗),直接打該列的第一個 P3 動詞,以它的 `E_UNSUPPORTED` 當作 W 行。

**「以 uid 471」怎麼做**:04 上沒有 su / setpriv。照 repo 既有的 `NB()` 寫法(`tmp-trust-280.sh:19`):`start-stop-daemon -S -c 471:471 -n <這一臂唯一的名字> -a /bin/sh -- -c "<指令>"`。**不能用 `-x <工具>`**:同名行程已在跑時它只印 `is already running` 並回 rc 1、什麼都不做(v8-A 在 WSL busybox 1.36.1 實跑)。每次都先執行 `id -u` 並斷言 = 471。⚠️ 尚未在 04 實際執行,列入 E-H15 一起驗。

## 3. Bench 基準狀態

### 3.1 S0-pre 與 S0

| 項目 | S0-pre | S0 |
|---|---|---|
| 04、02 | 都是 member,`RadioManaged = true` | 同左 |
| 擁有者 | H0 | H0 + H0b |
| 網路 N0 | 02 + 04;US、ch 40;mesh key 是 `netobj.py` 新產生的測試值 | 同左 |
| 手機 AP | 04 = C0、02 = C0';由 root 執行 P2 的 `halow-setkey --ap`(值在 argv,這是 P2 的界線,C0 是測試值) | 由 key 20 寫入(journal) |
| 手機 | 存了 C0 與 ALT 兩個網路,MAC 用「手機 MAC」 | 同左 |
| 每台記在庫裡的身分 | **DAC 憑證**(`identity/node.cert`,0644,ssh 讀)、`device_id` / `sn`、eth MAC、ssh host key。**不存 Noise static key**(每次 provd 啟動都會變,F-H45) | 同左 |

C0、C0'、ALT 都是 ≥ 20 字元的高熵隨機值。

**S0-pre 的建立步驟**(`prov-bench-s0-254 provision`,每台依序做;寫在 `docs/validation/h4-onsite.md`):

1. 重燒(使用者)。02 暫時接網路線(H4-U7)。兩條路同時存在時,靠 batman 的 BLA 避免迴圈(F-H52)。
2. **找到新卡**:bootstrap IP 是 `10.41.254.<隨機>`(F-H53)→ 沿用 chain1 的「依 eth MAC 做 ARP 掃描」;每次 ssh 都斷言 `identity/sn` 與 eth MAC;重燒後重新 pin host key。
3. ssh `none` 登入(新卡,認領前):
   - 放 lab key;
   - **以 publickey 證明登入成功(chain1 的 `pk_proof`),證明之前不認領**(chain1 `:342` "not claiming");認領之後 dropbear 只收 key(F-H37),先證明可以避免 02 被鎖在外面;
   - 讀 `identity/node.cert` 與 `sn` 寫進庫;
   - 讀 `identity/claim.secret`:在節點上以 `hexdump -v -e '1/1 "%02x"'` 輸出 hex,經 ssh stdout 直接進 `peer.py` 的 stdin。不落地、不進 argv,也不會被跨 Git Bash / WSL 的換行處理弄壞(v4-A m5)。
4. 認領(H0):**H4-U14(使用者 2026-11-03)改用既有、已驗證的 `provclient`(sock,經 helper;H3 chain1 / prov-claim 用過)**,不寫 `peer.py claim`(實作時被工具的安全機制擋下)。認領前仍以 `peer.py` 依 §4.2 認證目標(新卡 = unclaimed,NX 交握的 `node_cert` 必須等於第 3 步記下的 DAC);認領後以 `peer.py` 讀 `STATUS` 斷言 state 變成 claimed。**界線**:BLE 上的認領路徑不在 S0-pre 建立時涵蓋,改由 P3 的單位涵蓋(列進 #254 checklist)。
5. `network/join`(請求依 CDDL `network-join-req`,一定帶 key 31 owner-op;F-H47):
   - 04:`netobj.py` 產生 N0 的 net_config(H0 簽,國家 US),以及給 04 的 net_secrets:target = SHA-256(04 的 DAC pub),加密給 04 `node_cert` 的 `ecdh_pub`(先驗 `sig_ecdh`);
   - 02:同一份 net_config,加上給 02 的 net_secrets。
6. 等 `.txn` 消失,再等 openmanetd 那次重開結束(F-H42)。之後依 eth MAC 重找 IP。
7. root 執行 `halow-setkey --ap`(值從推到 `/tmp/run/batman-dv/c0` 的 root 0600 檔讀出;用完就刪)。
8. 等 02 經 mesh 連得上 → **使用者拔掉 02 的網路線** → `s0_assert` 兩台。

**`s0_assert`**:依 §6.1 判斷 image 版本,選對應的版本。
- **S0-pre 版**:
  1. §4.2 認證過的 BLE 連線;
  2. `STATUS` 的 state = member;
  3. H0 的 `auth/owner` 成功;
  4. root 讀 uci 的 SSID 與 hostapd conf 的 sha,等於庫裡的值(ifname 從 `ubus call network.wireless status` 取);
  5. `BATMAN_VERSION` = 受測 image,而且目前是 committed(**不比槽字母**,因為 T 會換槽)。
  6. 02 的 eth0 沒有載波(現場的網路線已拔掉,測試拓撲與設計一致;v5-B m)。
- **S0 版**:再加上 H0b 的 `auth/owner`、`settings.get` 的 SSID、`status`。
- 不成立 → INVALID,並印出重建步驟。

**W 行的判法**:在 S0-pre 上,第一個 P3 動詞回 `E_UNSUPPORTED` → 印 `FAIL <unit> <row>: …`;只有 S0-pre 本身不成立時才印 INVALID。

**升級**:P3 rc 第一次上機時執行 `upgrade`:`owner/add` H0b;key 20 = C0(值不變)。這是 P3 PR 的閘門之一。

**預演**(現場之前,§15):在 F 載具(04 的 B 新卡)上把第 2–7 步完整跑一次,建成單節點的 N0,包含 §4.2 在 member 狀態下認目標。這證明現場那一趟不會白跑。

### 3.2 金鑰庫

- **位置**:WSL 的 `~/.batman-dv/bench/`(0700 / 0600)。`run/<run>/` 放臨時擁有者 Hx、HF,以及快照內的動作。
- **journal**:先寫「意圖 + 新值」(fsync)→ 送出 → 改成「已套用」。中斷後新、舊兩組都試。
- **備份**:tar 到 Windows `%LOCALAPPDATA%\batman-dv\bench-backup\`,ACL 由程式設定,並以 `icacls` 讀回斷言。
- **誠實界線**:同一個 Windows 使用者底下的行程,可以經 `\\wsl.localhost` 讀到庫;庫裡都是 bench 的測試值。
- **H0 與 H0b 都遺失** → 只能重燒,要使用者在場。
- **C0 給手機**:`phone-254.sh c0-card` 在 `%LOCALAPPDATA%\batman-dv\c0-card.html` 產生 Wi-Fi QR:
  - 用 hash 釘選的 `segno` 產生 inline SVG(待使用者同意下載;不同意就只顯示文字,讓使用者手動輸入);
  - 頁面不載入任何外部資源,斷言檔案裡沒有 `http`;
  - ACL 只限使用者;
  - 我與工具輸出都不讀這個檔。

### 3.3 S0 的生命週期

| 路徑 | 行為 | 測法 |
|---|---|---|
| 首次(現場) | `provision` → S0-pre | 結束時的 `s0_assert` |
| 每個單位 | 開頭 `s0_assert` → 臂 → undo → `s0_assert` | 每個單位 |
| P3 rc 第一次上機 | `upgrade` | P3 PR |
| 主機死 | §5.7 | §11 |
| 金鑰輪替中斷 | journal | 斷在送出與「已套用」之間 |
| 降回 wsl.22 | S0-pre 版的 `s0_assert` | UD11 |
| **02 離開 mesh** | 沒有遠端的路(沒有網路線,新卡沒有 mesh)→ **NEEDS-PERSON**。可能造成的臂:country-join 的 02 那一半、`fw-badinclude`、mesh 臂失誤。這些臂開始前都斷言 02 的 plink 在,結束後先檢查 02 連得到,才做下一臂 | — 偵測型 |

## 4. 元件

### 4.1 `peer.py`(WSL)

- **執行**:`~/.batman-dv/peer-venv/bin/python tests/tools/peer/peer.py`。
- **輸出**:每次呼叫一行 JSON;秘密欄位只印 `short()`(清單寫死在程式裡)。單位的秘密斷言在 WSL 端用原值 grep,必須是 0。節點的 log **在節點上先以原值 grep 過**才拷回主機(§16)。
- **子命令**:`s0 provision|assert|upgrade`、`claim`、`auth`、`call`、`owner-*`、`settings-*`、`status`、`diag-*`、`update-*`、`bulk-*`、`upload`、`raw`、`load ro <rate> <secs>`(自己計數:ok / `E_RATE` / 其他)、`identify`(§4.2)、`--selftest`。
- **`netobj.py`**(自己的實作,不 import `gen.py`;F-H44):
  - 產生 N0 的 net_config(COSE_Sign1,owner 簽;國家、頻道、頻寬依 CDDL);
  - 產生 net_secrets(F-H47):payload `{1: net_id, 2: version, 3: target = SHA-256(目標 DAC pub), 4: 加密給目標 node_cert 的 ecdh_pub}`。對照 `cose.Decrypt(enc, LabelSecrets, dacHash, other, ECDH)` 的參數(`wtxn.go:145`):**target 放在 COSE KDF context 的 PartyV,AAD 是標籤 `batman-secrets-v1`**,`other` = net_id ‖ version(4 B BE),放在 KDF context 的 SuppPubInfo(`cose.go:193, 201`);net_secrets 的簽者必須列在 net_config 的 key 8。加密之前先驗 `sig_ecdh`。
  - 組 `network-join-req`:依 CDDL 帶 key 2(`members-sign1`)與 key 31(owner-op)。wsl.22 的 helper 不讀 key 2,`provclient` 也不送;key 2 是照規格帶的,不是 wsl.22 需要。
  - 庫裡另外存 N0 的 `net_root` 私鑰、`net_id`、`net_version`:`psk_member` 由這三個推導,SD2 等成員臂會用到。
  - 在 P3 image 上重建 S0 時,P3 遇到國家不符會拒絕 join(P3 `:245`),所以 join 之前先把 key 2 設成 US。
  - **selftest**:用 `vectors.json` 的輸入逐位元組重現 net_config、net_secrets、join 請求;另加負向案例「拿 `s_node` 當加密對象 → 和向量不一樣」。
- **交握限速**:provd 的交握額度是 BLE 全域 20 次 / 分、HTTP 10 次 / 分,fake path 也算(F-H50;P3 `:376`)。peer 自己對每個節點限速:BLE ≤ 15 次 / 分、HTTP ≤ 8 次 / 分。
  - provd 連線類的 log,每個 key 每分鐘最多 10 行(`logLimited`,`server.go:126-144`)。所以 **log 的行數不能當作計數的唯一證據**;有沒有被限速,看 peer 端的分類。
  - BLE 與 sock 共用 2 個 slot;helper 的第 4 條連線不算在內。
- **peer 端的交握結果分類**(v5-A M1)。判定只用這個分類,再加上節點端的佐證:
  - `ok`:msg2 解得開,`node_cert` 也驗過;
  - `fake`:msg2 解不開;
  - `wrong-target`:解得開,但 `node_cert` 不是目標;
  - `refused`:連線被拒,或立刻斷線;
  - `budget`:peer 自己的限速擋下來。
  
  `refused` 與 `budget` 一律 INVALID,不能當作「被拒」的證據。
- **noiseprotocol 的實作細節**:0.3.1 版交握完成時會刪掉 `handshake_state`,所以要在讀 msg2 之前先留住 `rs` 的參照(v5-A 實測可行)。
- **傳輸 `--via`**:
  - `sock`:provclient proxy。只用在 `push-provd SOCK_ONLY=1`。
  - `ble`:WSL 以絕對路徑執行 Windows 的 `python.exe -E -P …\blebridge.py`。preflight 檢查:版本、bleak = `requirements-win.txt`、沒有殘留的橋(`Get-CimInstance Win32_Process`)。
  - `http`:經 ssh 到手機的 relay,使用 pinned 的 known_hosts。
- **helper 的第 4 條連線**:provclient → helper,最多一條,不與 app 的讀取並行。UD19 刻意用它。

### 4.2 `blebridge.py` 與認目標

**橋**(Windows)只做傳輸:
- 控制行:`SCAN`(回傳每個位址 + RSSI)、`CONNECT <addr>`、`MTU`、`CLOSE`;資料行:一行 hex = 一個 frame。
- stdin EOF 或父行程消失 → 斷線並退出。
- frame 大小 = `min(244, CTRL key 3, max_write_without_response_size)`,等 MTU 談完、連續兩次讀值相同才定。
- notify 用 `start_notify`;write 用 `response=False`。
- 出現配對提示 = FAIL。

**認目標**(在 WSL 的 peer 核心;v4-A B1 / v4-B B1;依 219 §3.3 的手機驗證,F-H46):

**在這一臂自己的交握裡驗**,不另外做認證交握(一條連線只能交握一次,F-H45):
1. `SCAN` → 依 RSSI 由強到弱逐一 `CONNECT`。
2. 讀 `STATUS`:unclaimed / legacy 時有 key 5,不符就立刻 `CLOSE`(只是加速)。
3. 送出這一臂本來就要做的 msg1(NX / psk_owner / psk_member)。收到 msg2 後,**在送出任何請求之前**驗 `node_cert`:
   - `dac_chain[0]` 必須等於庫裡目標的 DAC。只驗鏈不夠:`psk_member` 是全網共用的,不比 DAC 就分不出是哪一台;
   - `sig_static` 要對上交握裡實際的 `s_node`,也要對上 `boot_id`;
   - `sn` 要與 DAC 一致(dev 憑證:`device_id == hex(SHA-256(pub)[:9])`)。
4. 不符(包括 msg2 解析不出 `node_cert`,也就是 fake path)→ `CLOSE`,換下一個位址。
5. 全部候選都不符 → INVALID。

**預期會走 fake path 的負向臂**(例如錯的 PSK、member 收到 NX):這種臂沒有可驗的 `node_cert`,做法如下:
- 同一臂內先建一條**已認證**的連線,記下目標目前的位址,關掉;
- 在 RPA 換址窗(約 900 s,F-H12)內重連**同一個位址**,送負向的 msg1;peer 端的分類必須是 `fake`;
- **節點端佐證**(v5-A M1):收到 fake msg2 之後,在連線後 10 s 內再送**一則完整的單 frame 訊息**,provd 一定會寫 `session ended: message on the fake path`(`session.go:300-306` → `:234`)。斷言 04 的這一行增加、02 沒有增加。**HTTP** 的 NX / psk_replay 依 P3 `:492` 是回一個等長的回應後就關閉,不會產生這一行 → HTTP 的 fake path 不能看回應長度(P3 `:492` 規定 fake 回應與真回應等長),改用 tcpdump 看 04 在回應之後**立刻主動送出 FIN**,。前提:relay 對這一臂用**持久連線**(不送 `Connection: close`),同一臂先做正向對照:真的 session 回應之後,04 **不會**送 FIN。第二個 `/msg` 只判定「TCP 連線已關」,不判斷回應內容(P3 沒有定義)。
  - 這一行的限流 key `session` 由所有 session-end 行共用(10 行 / 分)。每個 fake path 臂開始前,先數 04 log 前 60 s 內已有的 `session` 行;要 ≤ 4 才開始,否則等到符合;臂期間不做其他會產生 session-end 的動作。
- 位址在這中間換了(重新掃描找不到)→ INVALID。

**HTTP 與 sock 也一樣驗 `node_cert`**(v5-B m):被入侵的手機可以把 relay 轉到 02,所以經 HTTP 的每個交握也要比對 DAC。sock 經 provclient proxy 連到指定的節點,一樣要驗。

**`SCAN` 只回報廣播 provd 服務 UUID 的裝置**,不會去連其他 BLE 裝置。

**負對照**(`peer.py identify` 的 selftest,以及實機兩臂):
- (a) 在 S0-pre 上要連 04,但庫裡 04 的 DAC 換成一張**不屬於任何節點**的測試憑證 → 04 與 02 都被認出「不是目標」而放掉 → INVALID。佐證(pre-P3 也拿得到;v6-A M1、v6-B m3):blebridge 記的「msg1 之後、由 peer 送出的 frame 數」= 0(只算 msg1 之後;這個計數器在 selftest 有負對照:peer 以測試模式在 msg2 之後多送一個 frame → 計數器 = 1 → 斷言 FAIL;計數器只算 peer 送出的 frame);兩台 provd log 的 `adv withdrawn reason=connect` 與 `adv registered reason=disconnect` 時間戳,證明每條連線只存在到交握完成。
- (b) 強制候選順序先試 02(忽略 RSSI)→ 02 被放掉、04 被接受。斷言:02 那條連線在 msg1 之後由 peer 送出的 frame 數 = 0;04 那條連線上 `info` 回應的 key 1(device_id)= 庫裡 04 的值。
- provd 不寫「收到請求」的 log,P3 v7.1 也沒有定義 helper 的請求計數(P3 F65:helper 分不出 provd 的幾條連線),所以這裡不用它們。§1.4-2 原本要求的「helper ro 計數」只留給 SD3,並寫成 P3 的契約:`info.state` 加一個 `ro_served` 欄位 = helper 啟動以來在 ro 連線上回應的動詞數(不分動詞、不含 ctl / ops)。
- **絕不能**在認證不符的連線上送出任何請求。

**其他規則**:
- 連到不是目標的那台會讓它短暫撤廣播。主機鎖底下沒有其他單位在用,列進副作用。
- **04 的廣播在不在**一律在 04 端判:provd log 的 `withdrawn` / `registered` 行,以及 root `bluetoothctl show` 的 advertising instances 數。
- key 20 臂的 Closed = outcome unknown → 認證後重連,讀 `settings.get` 判定。
- **selftest**:假後端,驗證行協定、frame 計算、EOF 退出;認目標用 `vectors.json` 的 `node_cert`:DAC 不符、`sig_static` 不符、fake path,三種情況都要放掉。

### 4.3 手機

**設定**(`s20-setup.md`,使用者在現場做一次):
- Termux + Termux:Boot(開機自動起 sshd 與 wakelock);
- `authorized_keys` 加限制、`PasswordAuthentication no`、不給 storage 權限;
- 行動數據關閉;刪掉家用 Wi-Fi;只留 C0 與 ALT,兩者都用「手機 MAC」;
- 電池「不受限制」、永不睡眠、常接電源。

**連線與 relay**:
- **host key**:釘在 `~/.batman-dv/phone_known_hosts`,`StrictHostKeyChecking=yes`。
- **手機 IP**:每個 run 重找:讀 04 與 02 的 `/tmp/dhcp.leases` → `ip neigh` → 從 04 ping 廣播後再讀一次。
- **relay**:只用標準庫;每個 run 用 scp 推一份新的,`python -I` 執行;只連 argv 給的那一個位址;錯誤分成 `refused` / `timeout` / `unreach` / `reset`(只當記錄,判定以節點端為準)。

**`phone_preflight`**(任一項不過 → 手機臂 INVALID):
1. ssh 連得上;
2. `ubus call hostapd.<ifname> get_clients` 裡,手機 MAC 的 `authorized: true`;
3. 手機 MAC 出現在 `bridge fdb` 的 AP iface 上;
4. relay 的 sha 對;
5. relay → `<node-ip>:80` = 200。

**同路徑的正向對照**:每個經手機的負向斷言,同一臂內要緊接著做 relay → :80 = 200。

**節點端佐證**:每個經手機的負向斷言,04 上的 `tcpdump -i <AP if>` 都要看到手機 MAC 送出的 SYN,named counter 也要有增加。

**key 20 的「新帳密可連」分兩段判**:
- (a) 節點端 ≤ 30 s:hostapd 的 SSID = 新值、AP iface 起來 → 產品斷言;
- (b) 手機端 ≤ 180 s:`authorized: true`,且 relay → :80 = 200 → 逾時是 INVALID。

### 4.4 新卡 lib:`fresh-254.sh`

> **2026-11-03 使用者決定(H4-U13):期限機制沿用 chain1 現有、已驗證的一次性 dead-man,不實作下面「兩個檔」的版本。**
> - 理由:新寫的期限迴圈在實作時被工具的安全機制擋下;現有機制已在 04 上驗證過(chain1 59 / 0)。
> - **缺口(列進 #254 checklist)**:主機死掉、而且 B 每次開機不到 25 分鐘就重開時,一次性 dead-man 可能永遠不觸發。這時 04 停在 F 的狀態,要人照 `restore_all` 的步驟處理(實驗室在身邊)。其他情況(主機死、B 正常開著)照舊由 dead-man 帶回 A。
> - **之後的改進想法(不排程)**:讓 B 在不需要 commit 的步驟保持 tryboot 試開狀態,縮短沒有保險的窗口。
> - `fresh-254.sh` 的抽出(chain1 步驟 1–6 與 9)延到寫第一個 F 單位時做,當場跑 chain1 回歸;在那之前沒有使用者。
> - 下面的「期限」與「回歸」中 dead-man 相關的幾條,以這段為準。

- **範圍**:chain1 的步驟 1–6 與 9。`image` 參數可以是受測 rc,也可以是 wsl.22。restore 之後 B = A 的版本(brewrite),A 做 overlay-restore + compare。新卡由臨時擁有者 HF 認領;它的 DAC、`sn`、eth MAC 都從節點讀進 `run/`(§3.1 第 2–3 步)。
- **期限:兩個檔、各一個寫者**(v4-A m2、v4-B m8):
  - p6 `fresh-grant`:**只有主機寫**(tmp + rename),內容 `<run> <grant_seq> <預算秒>`。每次續期 `grant_seq` + 1,預算 = 30 分。
  - p6 `fresh-spent`:**只有 B 上的迴圈寫**(tmp + rename),內容 `<run> <grant_seq> <已用秒> <boot_id> <last_uptime>`。
  - 迴圈的規則:
    - run 不符 → 不動作;
    - `fresh-spent` 不存在(第一次開機)→ 當作已用 0,`grant_seq` = 目前的值;
    - **每次開機時(`boot_id` 與 `fresh-spent` 記的不同),迴圈一啟動就先扣「本次 uptime + 每次開機的固定成本 120 s」**;所以每次開機不到 60 s 就重開的迴圈,預算一樣會減少;
    - 同一次開機內迴圈自己重啟(`boot_id` 相同)→ 只扣 `uptime − last_uptime`;
    - 之後每 60 s 扣一次經過的時間;
    - 讀到的 `grant_seq` 比 `fresh-spent` 記的大 → 已用歸零(主機續期了);
    - 已用 ≥ 預算 → 執行 `ch1-deadman.sh`;
    - 任一個檔讀不懂 → 觸發(fail-secure)。
  - 只要主機不續期,不論重開迴圈多快,預算一定會耗盡。
- 每次 B 開機後,主機先斷言 rc.local 那一行與迴圈都在。
- **LR1 排在 F 的最後**:firstboot 回來後重種 dead-man 並斷言,然後 restore_all。
- **lease dead-man 與新卡 dead-man 的先後**:dirty flag 指向這個 F run 時,lease dead-man 只做 undo 執行器的段 1(§5.7),不啟動服務。
- **新卡 root 的 `none` 登入**:列進副作用。
- **主機死後回來**:下一個 run 的 preflight 看到 `ch1.fired` 或期限已觸發 → 自動跑 overlay-restore + compare + brewrite(遠端可做)→ 再 `s0_assert`。
- **回歸**:
  - chain1 在 wsl.22 上 59 / 0;
  - dead-man:不續期 → 觸發;有續期 → 不觸發;
  - B 上連續 sysrq 重開(包括每次開機 < 60 s 就重開)、不續期 → 預算內觸發。

### 4.5 eth 側模擬:`prov-ethsim-254.sh`(04,lease 底下)

**建立**:
1. netns `h4x`;
2. veth `h4v0`(接進 `br-ahwlan`)↔ `h4v1`(放進 netns,IP 用 `10.41.250.<n>/16`);
3. netns 內 `tcp_syn_retries=1`。

**目標一律是 04 的 `br-ahwlan IP:8095`**,包括 lo 臂。provd 只 bind 這個位址,連 127.0.0.1 不管有沒有規則都是 RST,所以那一條只看 counter、不當斷言。

**連線端**:`wget -T 2`(uclient-fetch),背景執行(以子 shell `( … ) 9>&-` 起,不繼承 lease 鎖的 fd;HT14 的保險行程、§7 的 uhttpd listener 也一樣)。並發上限在 E-H15 先量 RSS 再定(目標 ≥ 120),**速率依 P3 §8 是 50 conn/s**;並發上限可以撐到 50/s 才算達標,否則把實際速率列為誠實界線並回報使用者。每秒斷言行程數 ≤ 上限。

**判定**(在 04 端):
- tcpdump 一律在**這一臂的入口介面**擷取:eth / mesh / MAC 偽造 / VLAN 臂在 `br-ahwlan`;lo 臂在 `lo`;docker0 臂在 `docker0`。VLAN 雙層臂的 filter 要寫 `vlan and vlan and tcp port 8095`(否則 BPF 看不到內層的 TCP)。
- 要求同時成立:
  - 看到的 SYN 數 ≥ 送出數 × 0.9。看不到 → INVALID,因為流量根本沒到;
  - named counter 的增量 ≥ 看到的 SYN 數 × 0.9。增量 < 0(fw reload 讓計數歸零)→ INVALID;
  - 同一介面上沒有 SYN-ACK、沒有 RST。

**各臂**:

| 臂 | 做法 |
|---|---|
| mesh / eth 洪流(HT8b) | 50 conn/s × 10 分 |
| 偽造手機 MAC + IP + ARP(HT8a) | `h4v1` 用手機的 MAC 與 IP,以這個 IP 送出 ARP。手機會斷線,所以與手機臂不重疊;結束後刪掉、手機 ping、跑 `phone_preflight` |
| VLAN(D-1) | 在 `q0`(802.1ad 0)上疊 `q0.0`(802.1q 0),加靜態 neighbor;判定只在 04 端 |
| docker0 | 第二組 veth 接進 docker0;netns 的 IP 是 `172.17.250.<n>/16`;**目標仍是 04 的 br-ahwlan IP**(經 docker0 路由進 input,zone 是 ACCEPT)。同路徑正向:netns → `<br-ahwlan IP>:80` = 200。VLAN 雙層也從這一組送。docker0 會變 UP(副作用) |
| UP3 的第二來源 | `phy9h4` veth(名字以 `phy` 開頭,會被 bridge 規則打 bit)。**只准在兩種情況存在**:`http-nofw` 下的 UP3;以及 HT23(刻意不帶 `http-nofw`,驗證前提檢查會讓 `http.2` 消失)。殘留的話,helper 的前提檢查不給 `http.2`(fail-closed,HT23 就是證據) |

**還原**:每個 veth / netns 都登記進 undo;P9 檢查殘留。

**界線**:沒有測到網卡驅動那一段。

**⚠️ E-H15**:mesh(`batctl tl`)、helper 的前提檢查、還原、uclient-fetch 的結束碼、行程的 RSS。

## 5. P3 的接縫與 H4 的節點端機制(契約)

### 5.1 Go fault(prov_test build)

**檔案**:
- `/tmp/run/batman-prov-test/fault.helper`:helper 啟動時讀;
- `fault.provd`:test init 以 root 讀,經 env `BATMAN_FAULT` 傳入,接受 `[a-z0-9,-]{1,128}`。

**格式**:root 0600、regular、非 symlink、link 1、≤ 256 B,每行一個名字。
- 認得的名字 → 記 `fault <n>: armed`;
- 不認得的 → 記 `fault <n>: unknown, ignored`。

**`set-fault helper|provd <names…>`**:
1. 目標檔必須不存在;存在就 INVALID,並印出擁有者;
2. `umask 077` 寫暫存檔,再原子 rename(依賴 F-H41 的兩個 sysctl);
3. 重啟該元件;
4. 斷言生效:helper 看本次 pid 的 `armed` 行;provd 看新 pid 的 environ,加上「新出現」的 `armed` 行數。

**關閉** = 刪檔 → 重啟 → 斷言新行程沒有 fault。由 undo 執行器的段 1 負責;P9 檢查執行中行程的 environ 與 log。

**重啟的副作用**:helper 重啟 → 跑一次開機邏輯、上傳窗消失、上傳檔被刪;provd 重啟 → session 斷、廣播撤了再重來。

| 名字 | 元件 | 關掉什麼 / 注入什麼 | 用在 |
|---|---|---|---|
| `http-nofw` | helper | 不檢查表與 `phy*` 前提就給 `http.2` | 換規則型的 S、HT12 / 14 / 18 / 19 / 21 |
| `p5-autosave-off` | helper | 非試用開機時「只因新 key 而 stale → `--save`」 | UD16b |
| `provd-id-pid` | helper | provd 的辨識改成 peer pid = instance pid | AC1 / AC4 |
| `stable-any-471` | helper | 任何 uid 471 的連線都算 provd(不看 PPid / exe) | AC5 |
| `no-boot-disarm` | helper | 啟動時不做「同一次開機 apply 之後 → disarm」 | UD3b |
| `upload-nobusy` | helper | `otaBusy` 不看上傳窗 | UP7 |
| `d7-ssid-rc6` | helper | 「只有 SSID 不可存」的 rc 6 當成失敗 | ST20 |
| `d10-no-disarm` | helper | `reboot committed` 失敗時不 disarm | UD17 |
| `d12-take-mu` | helper | `update.check` 會拿 `n.mu` | UD19 |
| `upd-open-pause` | helper | 注入:worker 在 prepare 的檢查之後、開上傳檔之前停 30 s(重現被入侵 provd 能贏的那個競態) | UD8b-race |
| `upd-open-block` | helper | 開上傳檔時不帶 `O_NONBLOCK`、不檢查 regular | UD8b-race 的 S |
| `helper-arm-crash` | helper | 注入:寫完 `armed: true` 後 `os.Exit(1)` | UD3b |
| `healthok-2field` | provd | 備援只看兩個欄位 | HT4 |
| `ro-on-ctl` | provd | app 的唯讀動詞走 ctl | SD3 |
| `upload-noowner` | provd | PUT 不檢查窗擁有者 | UP2 |
| `upload-nosrcip` | provd | PUT 不比對來源 IP | UP3 |
| `http-allow-nx` | provd | HTTP 收 NX / psk_replay | HT7、RT1h |
| `k20-any-transport` | provd | key 20 不限 BLE | RT2 |
| `crash-on-start` | provd | 注入:啟動 2 s 後 `os.Exit(1)` | HT16c |

### 5.2 Go killpoint

新增名字 `upd-write-mid`、`upd-before-arm`、`upd-after-arm`,`prov-wbox-254.sh` 的封閉清單同步加入。

### 5.3 `push-provd`

- 要求 P3:prov_test provd 的 `--version` 印出標記;test init 跟上 release init 的變更。H4 的 lint 比對兩份 `start_service`,只准在已知的 test 段不同。
- 步驟:
  1. bind `/usr/bin/batman-provd` 與 `/etc/init.d/batman-provd`(兩者加進 bind 封閉清單);
  2. 寫 env / fault;
  3. restart;
  4. 斷言 exe sha、標記、environ。
- `unbind-all` 也會重啟 provd 並斷言。
- ✅ **E-H12**(2026-11-03,04):成立,不需 `upper-provd`。

### 5.4 shell fault(`/tmp/batman-fault.<n>`,`rundir.sh:44` 的 `batman_opf`)

| 名字 | 誰讀 | 效果 | 用在 |
|---|---|---|---|
| `setkey-norollback` | halow-setkey | `--rollback` 不還原 | ST5、ST6 |
| `setkey-readback-skip` | 同上 | 跳過讀回 | ST8 |
| `setkey-notrap` | 同上 | 不設 `trap '' PIPE` | ST12 |
| `setkey-no-reblock` | 同上 | D-6 那條路不重新封鎖 AP | ST7 |
| `setkey-rc-legacy` | 同上 | 新旗標的結束碼照舊對應(→ 2) | ST19 |
| `setkey-full-restart` | 同上 | 一律走 `wifi` 全重啟 | ST4 |
| `setkey-apply-fail` | 同上 | 注入:套用後的讀回當作失敗 | ST5–ST8、ST12 |
| `setkey-rbverify-fail` | 同上 | 注入:還原的讀回也失敗 | ST7 |
| `setkey-pause` | 同上 | 注入:commit 之後 sleep 30 s | ST12、UD19 |
| `setkey-settle-timeout` | 同上 | 注入:settle 逾時 | ST19 |
| `slot-copy-all` | batman-slot | 複製所有 boot 檔 | UD14 |
| `slot-reboot-fail` | 同上 | 注入:`reboot committed` rc ≠ 0 | UD17 |
| `bulk-mount-fail` | provd init | 注入:tmpfs 掛不上 | UP10 |
| `bulk-mount-fallback` | provd init | 掛不上時退回一般目錄 | UP10 的 S |

建立方式與 §5.1 相同(必須不存在、`umask 077`、原子 rename)。D-14 在 C 載具做,節點不 bind `batman-slot`。

### 5.5 檔案 bind

- **`/sbin/uci` → `uci-argv-shim.sh`**:
  - `exec /rom/sbin/uci "$@"`,argv 與 rc 原樣傳回;
  - argv 記到 `/tmp/run/batman-dv/uci-argv.<run>`(root 0600),只在節點上計數,臂結束就刪;
  - shim 有自己的 selftest(參數含空白、引號、`$`):bind 之前在 04 上與 `/rom/sbin/uci` 的輸出比對。
- **`/usr/bin/halow-setkey` → `setkey-argv-leak`**(ST9 的 S):一個 setkey 變體,用 `uci set …=$AP` 寫密碼(也就是 P3 F78 之前的寫法);加進 bind 封閉清單,只在 ST9 的 S 臂期間 bind。
- **假 `nft`**:只在 RD 的 PATH 裡。
- **autocommit 變體**(h23 §17 的規則):`ac-noprov`、`ac-provd-required`、`ac-helperoff-err`、`ac-nofw4`。
- **`provd_check` 的 `PROVD_KEYS` 加上 `BATMAN_FAULT`**(本 PR,F-H51)。否則 dead-man 與 `unbind-all` 之後的「provd 沒有測試開關」斷言,檢查不到 fault。

### 5.6 `provd-stable`(RD)

1. 刪掉 `$RUNDIR/provd-stable`。lease 底下是例外的寫者(§9)。
2. `push-helper`(帶或不帶 fault)→ restart provd → 等 70 s。
3. 執行 dry-run。
4. 還原:helper 正常重啟後會重寫;斷言內容是本次的 boot_id。

### 5.7 undo 執行器(v3-B M3;v4-A M2 / M3、v4-B M1;鎖的語意見 F-H48)

**程式形式**:`prov-undo-lib-254.sh` 提供函式 `undo_run <run> <mode>`,與 `ble-lib-254.sh`、`prov-lease-254.sh` 一起 stage(同一套 `stage-check`)。兩種進入方式只差在「鎖從哪裡來」:

- **`host` 模式**(單位正常結束,或主機的 EXIT trap):
  1. 主機先 `prov-lease-254.sh renew <預算>`。`prov-lease-254.sh` 沒有 `arm` 這個子命令,`renew` 才是延長 lease 並重設 dead-man 的那一個。預算 = 最壞情況的還原時間,例如 20 分;`renew` 要求 lease 還有效。
  2. 呼叫新的 `prov-lease-254.sh undo <run>`(加進 dispatch):在 `held` 底下(拿鎖、lease 有效)執行 `undo_run <run> host`。
  3. 這個指令一開始就 `trap '' HUP PIPE`,所以 ssh 斷線也會跑完。輸出寫進節點上的 `/opt/batdata/log/dv-undo-<run>.log`(三種模式都寫這個檔),不靠 stdout(ssh 斷了 stdout 會 EPIPE)。它在 `$BT/undo-doing.<run>` 寫 `<pid> <pgid> <boot_id>`,結束時刪掉。 log 只記動作名稱與 `short()`,不記 C0 等秘密的原值。
  4. 段 2 的每一個動作都包在 `lim <秒>` 裡,各自有上限。所有子行程都以子 shell `( … ) 9>&-` 執行,不繼承鎖的 fd;busybox ash 在函式呼叫上加 `9>&-` 的行為不可靠,所以一律用子 shell。主機端 `q()` 預設逾時是 120 s,呼叫 `undo` 的那一次改用「預算 + 60 s」。
  - **journal 的位置**:tmpfs 的放在 `/tmp/run/batman-dv/undo/<run>/`(root 0700),**不放在 `$BT/<run>/`**,否則 `gc_rundirs` 或 `release` 會把它刪掉;p6 的放在 `/opt/batdata/state/dv-undo/<run>/`。
  5. 結束之後主機照常 `release`。`release` 失敗(lease 在途中過期)→ 主機不重試,讀 `dv-undo-<run>.log` 等 dead-man 那一輪跑完(它會因為 `done` 標記而不重做),再以 preflight 檢查殘留。
  - **主機的 EXIT trap 執行時,lease 已經過期**:`renew` 會失敗 → 主機不做 host 模式,交給 dead-man;主機印出「dead-man 會接手」並等它的結果(讀 `dv-undo-<run>.log`)。
- **`deadman` 模式**:`role_fire_restore` 在 `dm-fire` 裡、**同一個行程**呼叫 `undo_run <run> deadman`。位置緊接在 `stop_judges` 之後,取代原本的「unbind-all、刪 killpoint 目錄」那幾步(那些都包含在段 1 裡)。**不 renew、不 setsid**:lease 已經過期,而 `dm_arm` 會殺掉呼叫它的 dm-fire。
  - **正常情況**:host 模式拿著鎖時,`dm-fire` 會等鎖(最多 10 分,`ble-lib-254.sh:334-336`)。分兩種:(i) lease 在 host 做完前一直有效 → host `release` 取消 dead-man,dead-man 不會執行;(ii) lease 在 host 執行途中過期 → `release` 會 die(`:314-316`),取消不了 dead-man → host 做完、鎖放開之後,dm-fire 照常跑 `role_fire_restore`,段 2 的項目都已標 `done` 而跳過。
  - **host 卡住**(等了 10 分還拿不到鎖,F-H48 的既有規則是不拿鎖照做):先讀 `undo-doing.<run>`,驗證那個 pid 的 cmdline 是 undo 執行器,**殺掉它的 pgid**,然後由 deadman 做段 1 與段 2。所以同一時間只會有一個執行器在跑。
    - 殺之前:先驗證 pgid 是整數、> 1、不等於自己的群組(04 上監聽中的 dropbear pgid = 1,`pg_kill` 本身只檢查是不是整數;對 `-1` 送 TERM 等於殺掉所有行程)。然後對 host 執行器的**父 shell** 送 `SIGSTOP`,它就不會開始下一個動作;每個工具都在各自的子 shell 裡跑,`done` 只由父 shell 標記,所以停住父 shell 就夠了。接著等它**直接的子 shell**(正在跑的 `halow-setkey` / `batman-config-save`)結束,zombie 視為已結束,最多等那個工具的預算;再 `TERM` 整個群組、**立刻** `CONT`,之後才輪詢 10 s(既有 `pg_kill` 是 TERM 後就輪詢、沒有 CONT,要改)。
    - `pg_kill` 殺不掉(例如 D 狀態)→ 只做段 1,記 NEEDS-PERSON,不做段 2(避免出現兩個寫者)。由 `test-h4-lib.sh` 以 stub 的 `pg_kill`(回失敗)測;負對照:stub 回「成功」但群組其實還在 → 斷言 FAIL(證明判定看的是群組真的消失,不是回傳值)。
    - host 執行器的 pgid **不登記**在 run 的行程群組裡:`cmd_dm_fire` 在呼叫 `role_fire_restore` 之前就會 `kill_run_groups`(`:333`、`:338`),登記了會在動作中途被殺。
    - **單位不以 `bg_start` 在背景起 `halow-setkey`**:`cmd_dm_fire` 會在 undo 之前 `kill_run_groups`,而 `halow-setkey` 沒有 TERM trap,會在寫到一半時被打斷(v7-B m2 的後半)。單位要用 setkey 時,一律在前景、包 `lim`;要「另一個程序持有 setkey 鎖」的 ST11 持的是 `flock`,不是 setkey 本身。
    - 被殺的群組是那條 ssh 連線的 dropbear 子行程,不是監聽中的 dropbear 主行程,所以不會切斷遠端存取(v6-B 在 04 唯讀確認)。
  - `role_fire_restore` 其餘的步驟(provd 重啟、`radio_restore`、啟動服務)在 undo 之後照原樣執行。
- **`ble-recover`(人工的 recover)**:掃 `/tmp/run/batman-dv/undo/` 與 `/opt/batdata/state/dv-undo/`,對每個還有未完成項目的 run 呼叫 `undo_run <run> recover`。行為與 deadman 相同:先處理卡住的 host 執行器,再做兩段。
- **重入**:三種模式都跳過已標 `done` 的項目;每個動作都必須冪等。

**段 1:去武裝**。不論登記的順序,一律最先做:
1. 刪除所有 shell fault、`fault.*`、killpoint;
2. `unbind-all`;
3. helper 與 provd 換回 release,並斷言;
4. 殺掉登記過的行程群組(`kill-pg <pgid>`,先驗 cmdline 才殺)。

**段 2:狀態**。journal 逆序執行;每做完一項,原子改寫成 `done`。每個動作都要**冪等**。動作有:
- `fw-start`
- `uci-revert <pkg>`
- `uci-restore <pkg> <file>`
- `nft-del-table <f> <n>`
- `link-master <dev> <br>`
- `link-del <dev>`
- `netns-del <ns>`
- `svc-start <n>`
- `svc-enable <n>`
- `bt-start`
- `ap-restore`:經 `halow-setkey` 寫回 C0 的 SSID + passphrase,並斷言 hostapd 回到 S0。C0 從哪來:key 20 臂開始時,把 C0 stage 到 `/tmp/run/batman-dv/c0.<run>`(root 0600,登記 `rm-file`)。重開之後 tmpfs 沒了,改由主機從庫裡以 key 20 重送(journal),節點端不長期存 C0。S0-pre 不會跑 key 20 臂。
- `pending-del`
- `p5-save`:執行 `batman-config-save --save`,再用 `--check` 斷言 fresh
- `rm-file <path>`:例如 dev-open 旗標、`/tmp/run/batman-dv/c0.<run>`

**每一行的參數驗證**(v4-A m11):不符就記 CRIT、跳過該行,P9 判 FAIL。
- `<pkg>` 只能是 `[a-z_]+`;
- `<dev>` 只能是 `h4*`、`phy9h4`、`q0*`、`phy1-ap0` 這類由 ethsim / HT21 登記的名字(封閉清單);
- `rm-file` 的路徑只能在 `/tmp/run/batman-dv/` 底下,或是 dev-open 旗標的固定路徑;拒絕 `..` 與 symlink;
- `uci-restore` 的備份檔只能在本 run 的 p6 目錄裡;
- `kill-pg` 要帶 boot_id,而且要先驗 cmdline。

**撐過重開**(v4-A M3、v4-B m1):
- 會撐過重開的動作(`uci commit`、`disable`、`auto_includes`、p5 的修改),**先在 p6 `/opt/batdata/state/dv-undo/<run>/`(root 0700)登記,才去改**。
- **備份檔(`uci export` 的結果)也放在這個目錄**。
- 綁定的範圍依動作的性質決定(v5-B m):
  - overlay 裡的變更(`uci commit`、`disable`、`auto_includes`)綁**槽**:目前的槽與登記的不同(T 換過槽)→ 不在這一槽執行,改印 NEEDS-PERSON;
  - p5 的變更(`p5-save`)不屬於任何槽,不綁;
  - 只在同一次開機有效的動作(`kill-pg`)才綁 boot_id,而且這類動作不會寫進 p6。
- **誰在開機後執行**:**下一個 run 的 preflight**(先拿 lease,再以 `host` 模式執行段 2)。P9 只讀:列出殘留項、判 FAIL,不執行。主機不在時**沒有人在開機時重放**,所以下面這些會一直留到主機回來。這一點寫進 §13,而且每一項都是 fail-closed 或只影響可用性:
  - AC 臂 `disable` 了 provd → BLE 管理通道沒了;
  - HT18 的 `auto_includes=0` → HTTP 不聽;
  - ST16 / UD16b 讓 p5 stale → OTA 被擋。
- §11 的測法:臂進行中 sysrq → 重開後殘留項被列出、在主機那一輪被還原。

**單位如何縮短持久項的窗口**:`disable` 只在 dry-run 的那幾秒存在;`auto_includes` 臂不重開。

**`restoring` 標記存在時**:只做段 1;段 2 交給 pr_restore(它會重開並還原 p5)。

**HT14 的保險**:
- 停防火牆之前先起 `setsid sh -c 'sleep 60; nft list table inet fw4 >/dev/null 2>&1 || { firewall start; /etc/init.d/dockerd restart; }'`,並把 pgid 登記成 `kill-pg`;
- 臂自己的 `fw-start` 執行前,先殺掉這個保險;
- 保險動作之前,如果 `inet fw4` 已經在,就跳過。

**lease 契約的改寫**:dead-man 不直接寫 slot 或 p5;經 setkey `--save`、`batman-config-save --save` 的寫入,屬於那兩個工具自己的職責。

**測試**(`test-h4-undo.sh`,在 04 上跑):
- 每一類動作各一個 dead-man 臂:不續 lease → 等 dead-man → 斷言已還原;
- host 卡住的一臂:用一個測試用動作讓 host 模式的段 2 卡住(超過 lease + 10 分)→ deadman 殺掉 host 執行器、做完兩段 → 每一項只執行一次、鎖被釋放、之後的 lease 指令正常。**負對照**:照 v5 的規則(deadman 只做段 1、段 2 留給卡住的 host)→ 段 2 沒做完 → FAIL;
- host 正常、lease 一直有效的一臂:host 模式做完 → `release` 取消 dead-man → dead-man 沒有執行任何動作;
- host 正常、但 lease 在 host 執行途中過期的一臂:`release` 會 die(`ble-lib-254.sh:314-316`),取消不了 dead-man → dm-fire 等鎖;host 做完之後,dm-fire 照常跑 `role_fire_restore`,段 2 的項目都已標 `done` 而跳過 → 斷言每一項只執行一次;
- 參數驗證的負測試:在 journal 寫一行 `rm-file /etc/passwd` → 被拒、檔案還在。

## 6. pre-P3、負對照與對表

### 6.1 pre-P3 的判斷

- 判斷條件:`BATMAN_FEATURES` 沒有 `provd-p3(#254)`,**而且**版本在「已知的 pre-P3 版本清單」裡。這份清單在 `scripts/dv/pre-p3-versions.txt`,每次 pin bump 都要更新(lint 檢查)。成立 → 印一行 `FAIL <unit>: pre-P3 image (<version>)`。
- known-failures 的 ERE 只比對清單裡的版本;到期日 = P3 預估 merge + 14 天。
- 其他情況(P3 rc 漏了標記、或不在清單裡的新版本)→ 一般的 FAIL。
- `--pre-p3-full`:在 wsl.22 + S0-pre 上跑全部 W 斷言(§2 的前置規則)。
- INVALID 刻意被歸為 NEW。

### 6.2 負對照的種類

| 代號 | 意思 | 附在哪裡 |
|---|---|---|
| **W** | wsl.22 + S0-pre 上會 FAIL,附錄 A 寫出預期的那一行;只在「動詞不存在」那一層 FAIL 的,另外加 P | H4 PR(現場之後) |
| **S** | 同一載具、只差一個接縫 / 注入 | P3 PR 的閘門 |
| **P** | 同一臂內的前提證據:正向對照、LISTEN、named counter、bundle 非空、注入確實生效 | 每次執行 |
| **G** | 只有 Go 單元測試:**只限 H4-U8(UD16、UD12)** | P3 PR |
| **—** | 沒有,附理由 | — |

**換規則型的 S**:兩邊都在 `http-nofw` 下跑,而且都先斷言 8095 在 LISTEN。

### 6.3 對表

- 附錄 A 是唯一的來源,`gen-p3-units.py` 由它產生 TSV。
- 片語 ID = `<P3 節>.<列>.<片語序>`:§6、§7 每列一個;§8 的斷言欄依 `;`、`、` 切開後編號;附錄 D 用 D 編號。產生器同時記下每段文字正規化後的 sha。
- lint:每個片語 ID 至少對到附錄 A 的一列;sha 變了 → FAIL。

## 7. §9-4 探針(H4 凍結的閘門;D22、D-1、D-2;04,H4-U7)

**前提**:04 跑 wsl.22、處於 S0-pre、在 lease 與主機鎖底下;手機已在 C0 上。

**步驟**:
1. **基準**:記下 `nft -s list ruleset` 與 `netstat -ltn`。
2. **listener**:`setsid uhttpd -f -p <br-ahwlan IP>:8095 -h <空的 root 0700 目錄>`,pgid 登記成 `kill-pg`。
3. **載入 v7 規則**:照 P3 §3.8.1 的原文,加上 §1.4-6 的 named counter;兩張表都登記 `nft-del-table`。
4. **正向**:手機 relay → `<br-ahwlan IP>:8095` 收到 HTTP 回應;`batman_http_mark` 增加(D-2);tcpdump 看到手機送出的 SYN。
5. **負向**:ethsim 的 mesh / eth、lo(目標 br-ahwlan IP)、docker0、VLAN 雙層,每一項都要:`batman_http_drop` 增加、tcpdump 沒有 SYN-ACK 也沒有 RST,並附同路徑的正向(`:80` = 200)。
6. **鑑別力**(D-1):刪掉 v7 表、改載 v6 規則 → 同樣送 VLAN 雙層 → tcpdump **看到 SYN-ACK**。
7. **undo**:回到基準(`nft -s` 與 `netstat` 都相同)。

**不成立時**:改用備案規則 + 短審查,由使用者決定。結果回填 P3 F76、D-1、D-2。

## 8. 個別機制

### 8.1 T 簽章與 payload

- `tests/keys/` 放 T 與 K_test(公開)。`sign-test-release.py` 產生 E_T 與 S。prov_test helper 以 build tag 帶 `min-serial = 2`(§1.4-2);serial 1 的背書用來測「serial < min」。
- `p3-payloads.sh` 以受測 rc 的 payload 為底產生:
  - 四包惡意 tar;
  - `SHA256SUMS` 不在第一個;
  - 版本解析失敗;
  - **壞 rootfs**:保留 magic `hsqs`,把 superblock 的 `s_major`(offset 28,u16)改成 `0xFFFF`,長度不變;`SHA256SUMS` 用改過的 sha。
- **壞 rootfs 的離線驗收**(WSL,非 root,現場之前做):
  - 前 4 bytes 仍是 `hsqs`;
  - `unsquashfs -s` 失敗;
  - offset 1080 不是 ext4 magic(`0xEF53`)。
  - 不做 `mount` 測試:非 root 不能 mount squashfs。kernel 會拒絕的證據是 `super.c:158-166` 的 `s_major` 檢查(F-H54),實機證據是 E-H13。
- **機制**:kernel 正常 → 掛不上 root → panic → `panic=10` → tryboot 是一次性的 → 回預設槽。這與 F-H16 既有的 invalidate 機制是同一條回程。
- **E-H13 的前置**(lease 底下,現場之前;F-H49):
  1. 在 04 上跑 `batman-slot apply <壞 payload>`,證明會被收下。`apply` 結尾會 arm tryboot。
  2. **緊接著、不重開**:用一個不帶 `root.squashfs` 的 payload 目錄跑 `batman-slot stage-root`。它會走 `begin_write`:disarm tryboot、invalidate B(寫 `BATMAN-BAD`)、清空 B 的 rootfs。
     - 這個目錄要能通過 `precheck`:要有 `boot/`、`SHA256SUMS`(含 `root.squashfs` 那一行)、`metadata` 的 `size=`;p5 必須是 fresh。照 V 的 payload 拿掉 `root.squashfs` 做出來。
  3. 斷言:tryboot 旗標 = 0、B 有 `BATMAN-BAD`。
  4. 第 1 步留下的 `shutdown.reason` 已登記 `rm-file`,由 undo 刪掉。
  5. **brewrite B**,斷言 B = V、沒有 `BATMAN-BAD`,再 `s0_assert`。
  - 第 1 步與第 2 步之間如果意外重開,會進到壞槽 → panic → 回到 A。這個方向是安全的,但前置要重做。
- **E-H13**(現場):apply → 重開 → 觀察 panic 行、ext4 的嘗試、回到 A 的時間。結束後一樣 **brewrite B**,斷言 B = V、沒有 `BATMAN-BAD`,再 `s0_assert`。否則之後任何 rollback 都會讓 04 陷入 panic 迴圈(v3-B M1)。

### 8.2 `prov-eeprom-hooks-254`(D11;C 載具;H4-U12)

**沙箱**(`eeprom-sbx-254.sh`):
- 進沙箱之前:關掉 fd 3 以上的所有 fd;fd 0 = `/dev/null`;fd 1 / 2 接到父行程的 pipe,不接宿主的檔案(否則可以經 `/proc/self/fd/1` 截斷宿主的 log;v6-A m7);`env -i` 清掉環境變數;
- WSL 的一般使用者執行 `unshare --user --map-root-user --mount --pid --fork --net --uts --ipc`;
- 在新的 mount namespace 裡:把 rootfs 的目錄 bind 到自己身上 → **在宿主的 cwd 執行** `pivot_root "$R" "$R/old"`(先 `cd $R` 再 pivot 的話,cwd 對照做不出來) → **`cd /`** → 用**新根裡的** `/bin/busybox umount -l /old` 卸掉舊根(pivot_root 之後 PATH 已經變了,找不到 `umount` 時舊根會靜默留在 `/old`;v6-A M2 實測)→ `rmdir /old`;失敗就整個單位 FAIL。不用 chroot,因為 chroot 擋不住 userns 裡的 root(F-H55)。少了 `cd /`,cwd 會留在宿主目錄,用相對路徑就能寫到宿主(v5-B 實測:`pwn-cwd`);
- 新根之內只放 rootfs、一個空的 tmpfs `/tmp`、自己的 `/proc`,以及從宿主 bind 進來的 `/dev/null`、`/dev/zero`、`/dev/urandom`(沒有它們,`>/dev/null` 會在 rootfs 副本裡建出一般檔);**宿主的 `$HOME` 不在新根裡**;
- qemu-aarch64 依 binfmt 的 `F` 旗標執行(F-H31)。
- 沒有真 root,也不用 `dv-sbx.sh`(F-H22)。

**逃脫負測試**(每次執行都先跑;每一條都要有「沙箱外會成功」的對照,才算有鑑別力;F-H55):

| 測試 | 沙箱內(必須失敗) | 對照:沙箱外(必須成功) |
|---|---|---|
| 絕對路徑寫宿主資產 | 寫宿主 `$HOME/.batman-dv/sbx-canary`(yello 擁有)→ 寫不進去(路徑在新根裡不存在);宿主上的 canary 內容不變 | 同一條指令在沙箱外寫得進去 |
| cwd 逃脫 | 從主機的 canary 目錄啟動沙箱,沙箱內以相對路徑寫 `sbx-canary-cwd` → 宿主上的檔案內容不變 | 拿掉 `cd /` 的沙箱 → 宿主的檔案被改(v5-B 實測) |
| 繼承 fd 逃脫 | 父行程開著宿主 canary 的 fd 進沙箱,沙箱內寫那個 fd 編號 → 宿主的檔案內容不變 | 不關 fd 的沙箱 → 宿主的檔案被改(v5-B 實測) |
| 舊根沒卸掉 | 沙箱內的 `/proc/self/mountinfo` 只有白名單裡的掛載點(`/`、`/proc`、`/tmp`、`/dev/null`、`/dev/zero`、`/dev/urandom`),多一筆就 FAIL;`/old` 不存在;寫 `/old$HOME/.batman-dv/sbx-canary-old` → 宿主上的檔案內容不變 | 不卸舊根的沙箱 → 宿主上的檔案被改(v6-A 實測:`pwn-old`) |
| 宿主的 hostname(sanity,沒有鑑別力) | 沙箱內 `hostname x` 之後,宿主的 hostname 不變 | — |
| reboot(sanity,沒有鑑別力) | 沙箱內 `reboot -f` → 沙箱的 init 被結束,WSL 的 boot_id 不變 | — |

判定只看宿主 canary 的**內容**有沒有變,不看指令的結束碼。

任一條不成立 → 整個單位 FAIL。

**底**:wsl.22 的 rootfs(sha 釘死)。

**各臂**:
- **EE1**:PATH 最前面放假 `vcgencmd`,回四個 key → 依序執行 `/etc/uci-defaults/*` → 斷言:`authorized_keys` 不含植入的 key;root 密碼的 hash 不變;AP `disabled`;country 沒被鎖。
- **EE2**(D11 的 fresh-overlay 與 stage1 `:487`):shim 對所有 key 的 `READ` 都回 rc 1。
- **負對照(W)**:`1.5.12-wsl.2+f2f2bf6.fw9d87d02`(沒有 shim,F-H39;sha 釘死)→ 四個 key 全部被採用;另加 P:斷言負對照的 rootfs 裡沒有 shim 版的 `persistent_vars_storage.sh`。

### 8.3 `prov-fw-boot-254` 與 `fw-badinclude`

- **常規**(`prov-fw-boot-254`,附錄 A.12;daily-validation tier A,每次執行、每個 fleet 節點,唯讀):三張表都在、include 的每條規則正好一條、provd 的上傳 tmpfs 照 init 的選項掛著、`bootinfo A` / `bootinfo B` / `precheck-node` 回來後 1 s 內放鎖。負對照:離線 fixture 各破一處(S,`scripts/test-s5-node-254.sh`)。S5 之前的 image(例如 wsl.22)= 一條 FAIL「pre-S5 image」,在 `scripts/validation-known-failures.txt` 有一條帶到期日的 KNOWN 條目(和 pre-P1b / pre-P2 同一做法;到期後變回 NEW,r2 B-MAJOR-1):它沒有這些表是因為它早於 S5,但 S5 出貨之後節點退回舊 image 就該變紅,不能靜靜地 SKIP。
- **rc 閘門**:`fw4 print | nft -c -f -`(兩板)。`prov-fw-boot-254` 的 FB2 每次執行都在每個 fleet 節點跑(唯讀,check 模式不載入;r2 B-m4),所以 bench 上的 rc 也涵蓋。
- **`fw-badinclude`**(02,W 載具;H4-U9):
  1. 拿 02 central 鎖;
  2. 臂的前後都斷言 02 沒有預設路由(F-H33);
  3. 開機後最多 600 s 沒有防火牆,只暴露在實驗室 L2;
  4. 判定:試用被退回的原因、fw4 不在的 log、開機斷言 FAIL;
  5. 還原:回到 committed → `s0_assert`;結束後檢查 02 連得到(§3.3);
  6. 只在 rc 時跑。
- **D-17**:RD + 假 `nft`。

## 9. 擁有權

| 資源 | 唯一寫者 | 其他(唯讀) |
|---|---|---|
| 節點狀態(uci、p5、slot、防火牆、AP) | 持有 lease 的單位 | P9 |
| p5(lease 底下的例外) | ST16 / UD16b 由 root 讓 p5 stale;還原是 `p5-save`,登記在 p6 | — |
| `$RUNDIR/provd-stable`(例外) | helper;AC 臂可在 lease 底下刪除 | autocommit |
| undo journal(tmpfs 與 p6) | 單位登記;執行者 = `undo_run`,同一時間只有一個(host 模式持有 lease 鎖;deadman / recover 先殺掉卡住的 host 執行器) | P9(只讀) |
| HT14 保險行程 | HT14;由 `kill-pg` 收掉 | — |
| `/tmp/run/batman-dv/c0` | provision 步驟 7;用完 `rm-file` | — |
| bench 金鑰庫 / journal | `peer.py s0`;`run/` 範圍歸該 run | 單位 |
| `fresh-grant` / `fresh-spent` | grant 只有主機寫;spent 只有 B 上的迴圈寫(§4.4,各一個寫者) | 對方唯讀 |
| 新卡(p5 快照、B、rc.local) | `fresh-254.sh` | lease dead-man(只讀 dirty flag) |
| netns / veth | `prov-ethsim-254.sh` | P9 |
| fault 檔,以及帶 fault 的執行中行程 | `set-fault` / `push-*`;關閉 = undo 段 1 | P9 |
| `c0-card.html` | `phone-254.sh c0-card` | 使用者 |
| `~/.ssh/batman_phone_ed25519`、`phone_known_hosts` | `phone-254.sh`(keygen / pin);輪替 = 重新產生 + 使用者在手機上換 `authorized_keys` | — |
| 手機上的 run 目錄、relay | `phone-254.sh` | — |
| 手機的 Wi-Fi、Termux、電源 | 使用者 | harness 只檢查 |
| 桌機 BLE、blebridge | `peer.py`(主機鎖底下) | — |
| 02 central 鎖 | h23 | — |

## 10. 契約(新介面)

| 介面 | 寫 → 讀 | 格式 | 缺 / 壞 | 誰寫得到 |
|---|---|---|---|---|
| peer 的 JSON 行 | peer → 單位 | §4.1 | INVALID | WSL 使用者 |
| blebridge 行協定 | peer ↔ 橋 | §4.2 | `ERR` / Closed → INVALID;認證不符 → 放掉 | Windows 使用者(看得到密文與公開的 STATUS) |
| relay 行協定 | peer ↔ relay | §4.3 | 同上 | 有手機 key 的主機 |
| 金鑰庫 / journal | `s0` → 單位 | CBOR 0600 | INVALID + 重建步驟 | WSL 使用者 |
| `fresh-grant` / `fresh-spent` | 主機 → 迴圈 / 迴圈 → 迴圈 | §4.4 | run 不符 → 不動;任一個讀不懂 → 觸發(fail-secure) | root |
| undo journal | 單位 → 執行器 | 一行一個動作,封閉清單,帶 `done` 標記 | 不認得的行 → 記 CRIT、跳過、P9 FAIL | root |
| fault 檔 | `set-fault` → helper / provd init | §5.1 | §5.1 | root |
| `pre-p3-versions.txt` | harness PR → 單位、known-failures | 一行一個版本 | lint | harness PR |
| `p3-units.tsv` | 產生器 → 單位、lint | §6.3 | sha 不符 → lint FAIL | harness PR |

## 11. 生命週期矩陣(harness)

| 路徑 | 行為 | 測法 |
|---|---|---|
| 首次(現場) | `provision`;庫是空的 → INVALID + 步驟 | 空庫跑一次;F 上預演 |
| 一般執行 | §3.1 | 每個單位 |
| P3 rc 第一次上機 | `upgrade` | P3 PR |
| 主機死 / 睡眠 / Windows 更新 / `wsl --shutdown` | lease dead-man → undo 執行器;F → `fresh-deadline`;HT14 → 保險 | `test-h4-undo.sh`;chain1 回歸 |
| 臂進行中斷電 / 非預期重開 | p6 的 `dv-undo` → 開機後 P9 / preflight 執行段 2;04 的 boot_id 變了 → 該臂 FAIL | 臂進行中 sysrq 一次 |
| 孤兒 blebridge | EOF → 退出;preflight 檢查 | 殺掉 WSL 端,Windows 端 5 s 內退出 |
| BLE adapter / 驅動 | `ERR` → INVALID | 關藍牙跑一次 |
| 手機重開 | Termux:Boot | 重開手機 |
| 手機換網路 | 每臂前後做 preflight | 改連 ALT |
| 02 重開 / 離開 mesh | boot_id 比對 → INVALID;離開 mesh → NEEDS-PERSON | 偵測型 |
| 中途換接縫 | 重啟、重建 | 每個 S 臂 |
| 長單位 | lease `renew` | — |
| EXIT trap 組合 | `h4_on_exit add` | `test-h4-lib.sh` |
| F 期間 IP 改變 | 每一步重讀 | — |
| 降回 wsl.22 | S0-pre 版的 `s0_assert` | UD11 |
| bcm2710 | P-U14 | — |

## 12. 安全

**新的攻擊面**:
- **手機 sshd**:只收專用 key 且有限制;沒有密碼。被入侵的手機可以假造正向的連線,但 Noise 是端到端,交握假造不了;負向斷言有節點端佐證。
- **relay**:只連一個位址。
- **blebridge**:看得到密文與公開的 `STATUS`;bleak 依 hash 釘選;認目標以 `node_cert`(釘選的 DAC)認證,所以被竄改的橋沒辦法讓 peer 把擁有者的請求送到錯的節點。
- **ethsim**:只在 lease 期間存在。
- **T 私鑰是公開的**:由 UD-T1 證明 release 拒收。
- **EEPROM 沙箱**:非 root,而且每次都先跑逃脫負測試。

**供應鏈**:
- WSL venv、Windows bleak、`segno`(若同意):都依 hash 釘選;
- qemu:Ubuntu 套件庫的固定版本;
- Termux:沒有釘選,手機上只跑 relay(只用標準庫)與 sshd,判定不依賴它 → 列為界線。

**秘密**:
- 金鑰庫在 WSL(`\\wsl.localhost` 的界線見 §3.2);
- `claim.secret` 從 ssh stdout 直接進 peer 的 stdin,不落地;
- 不進 argv(P2 setkey 的 `--ap` 是例外,C0 是測試值,P3 之後改走 key 20);
- 原值 grep;`uci-argv` 的 log 不離開節點;
- C0 只出現在本機的 QR 頁面。

**dev-open**:只在臂期間存在(`rm-file`),只在 L / F 載具上用。

**權限**:fault 檔是 root 0600、必須不存在才建;非 root 寫的會被記 TAMPER(SEC1,排在最後)。

**沒有防火牆的窗口**:
- HT14:≤ 60 s(H4-U11);
- 02 的 `fw-badinclude`:≤ 600 s(H4-U9)。
- 兩者都沒有外網路徑(F-H33)。

**失敗模式**:INVALID 是預設;還原失敗 = FAIL + NEVER_KNOWN。

## 13. 副作用與還原

| 單位 / 臂 | 動到什麼 | 還原 |
|---|---|---|
| 全部 | lease、服務 | undo 執行器 |
| F(settings / country-join / bundle-gate / D-6 / D-7 / UD12 / LR1) | 04 離開 N0 約 90–150 分、OTS 停、p5 mkfs、B 重寫、UD12 寫 A;新卡 root `none` 登入 | `fresh-254.sh` 的 restore_all + compare + brewrite;`s0_assert` |
| LR1 | 約 2 分鐘沒有 dead-man | 重種、斷言、restore_all |
| HT3 | 停 bluetoothd ≥ 5 分(#305 風險) | `bt-start` |
| HT14 | 沒有防火牆 ≤ 60 s;OTS 中斷約 3 分 | `fw-start` + 保險 |
| HT18–HT21 | `auto_includes`、外來規則、`nomaster`(AP client 斷線) | undo(持久的登記在 p6) |
| ethsim / 偽造 MAC | 手機斷線約 5 分;docker0 變 UP | undo |
| `http-nofw` + `phy9h4` | 8095 對 lab mesh 開著 | 段 1 |
| UP7 的 S | `network/update` 真的套用(與現值相同)→ reload | 斷言 plink 恢復 |
| UP1 / key 20 | AP client 斷線 | `ap-restore` |
| ST13 | uci 暫存:用一個 commit 了也無害的 key;臂後斷言沒有被別人 commit | `uci-revert` |
| UD3 的 S(`upd-after-arm`) | 會真的進另一槽的試用 | hold → revert → 回到原槽;`s0_assert` |
| prov-update | 多次重開、A / B 重寫;壞 rootfs 一次 panic;UD11 把 04 降到 wsl.22、UD12 / UD12b 從 wsl.22 升到受測版本(整台 image 改變,S0 → S0-pre → S0) + UD20 的 P 會真的覆寫 B | 回到 S0 的版本、committed(sysupgrade 回 V);brewrite;`upgrade` 之後 `s0_assert` S0 版 |
| E-H13(前置與本體) | B 是壞 rootfs / 被清空 | brewrite B,斷言 B = V、沒有 `BATMAN-BAD`(§8.1) |
| prov-upload | 126 MB × 每個接縫一次 | tmpfs 用量回到 0 |
| AC | 刪 `provd-stable`;`disable` | 重寫;`svc-enable`(p6) |
| 持久項遇上「臂進行中重開 + 主機不在」 | AC 的 `disable` provd(BLE 管理通道沒了)、HT18 的 `auto_includes=0`(HTTP 不聽)、ST16 / UD16b 的 p5 stale(OTA 被擋)會一直留著;都是 fail-closed 或只影響可用性 | 主機回來後,P9 / preflight 依 p6 `dv-undo` 還原(§5.7) |
| fw-badinclude | 02 沒有防火牆 ≤ 600 s | 回到 committed |
| SEC1 | health 變 WARN | 刪檔;排在最後 |
| 02 | country-join、mesh 臂、認目標時被短暫連線 | 02 的 `s0_assert` |
| 手機 | AP 換兩次;暫存的 payload | run 結束刪除 |

## 14. 成本(⚠️ 推估)

- 一輪全套約 **19–20 小時**:04 離開 mesh 約 4 小時、OTS 中斷約 5 小時(逐單位的數字與 v3 相同)。
- `--pre-p3-full` 約 8 小時。
- 預演(F 上的 S0-pre、認目標、壞 rootfs 前置)約 3 小時。
- 每個 rc 的 build:prov_test 的 helper + provd 兩個 binary,加一個 wbox image。
- 依 P-U10,只在動到 prov 的 PR 與發版時跑。**成本待使用者決定**。

## 15. 工作順序

1. 設計審查到 0 BLOCKER / 0 MAJOR。
2. **不改節點**:
   - 工具與 selftest(peer、netobj、blebridge、relay);
   - 判定的離線框架;
   - 壞 rootfs 的 loop 驗收;
   - E-H16:沙箱與逃脫負測試;
   - E-H9 剩下的部分:legacy 狀態下對 04 開 NX session,驗 `node_cert`(DAC、`sig_static`、`sn`)、notify、9 KiB、230 s。
3. **改節點,lease 底下立刻還原**(先給使用者步驟):
   - E-H12;
   - E-H15;
   - `test-h4-undo.sh`;
   - E-H13 的前置(apply、不重開、invalidate)。
4. `fresh-254.sh` + chain1 在 wsl.22 回歸(H4-U13:與第一個 F 單位一起做;期限沿用一次性 dead-man);接著在 F 上**預演 S0-pre**(含 member 狀態下認目標)。
5. 各單位依 §16 的做法寫。
6. **現場**(H4-U7,步驟在 `h4-onsite.md`)。**H4-U15:移到 P3 之後、app 有第一版時;不擋 harness PR。**
7. `--pre-p3-full`。
8. harness PR(S 標 ❌、列為 P3 的閘門;H4-U15:現場項目列在 #254 checklist)→ 使用者 merge → P3 實作。

## 16. 怎麼讓測試程式少改幾次

1. 先驗工具、再寫測試(E-H 系列,以及 §15 的預演)。
2. 抓資料與判定分開:每臂的原始輸出先在節點上以原值 grep 過秘密,再拷回主機;判定在 `tests/judges/h4/` 離線執行;每條判定都要有「餵壞的 log → FAIL」的離線案例。
3. 一次只跑一臂:`prov-p3-254.sh <unit> --arm <id>`。
4. 先確認舊版會 FAIL,再確認新版會 PASS。
5. 全套只當最後確認;出錯就只補跑那幾臂,最後再完整跑一次。

## 17. 實測項目(E-H)

| # | 內容 | 狀態 |
|---|---|---|
| E-H1 | BLE 掃描 | ✅ |
| E-H8 | 桌機 ↔ AP 上的手機;relay → :80 | ❌ 現場 |
| E-H9 | 連線、STATUS / CTRL、MTU;`node_cert` 認證、notify、多 frame、閒置計時 | ✅ 2026-11-03(04 legacy,`peer.py eh9`):identify ok(−58 dBm,dev DAC 規則 + `sig_static`);`info` status 0、state 3;7820 B 請求 33 frame、0.43 s;匿名 session 閒置 25 s 仍開、再閒置 40 s 已關(IdleAnon 30 s)。原本列的「230 s」指的是處理中的請求(不計閒置,`session.go:121`),要 P3 的認證 session 才測得到 |
| E-H10 | 手機在 C0 ↔ ALT 之間切換 | ❌ 現場 |
| E-H12 | `push-provd` 在 ujail 下 | ✅ 2026-11-03(04 wsl.22,`eh12-push-provd-254.sh`):bind wsl.21 wbox-test 的 provd(95ffa2dc…,release 74dfa1dc…)+ 測試 init → 重啟一次,被 jail 的 pid 17230 `/proc/<pid>/exe` sha = 推上去的;uid 471、父程序 `/sbin/ujail`;provd-check ok adv=1;`unbind-all` 後 pid 20097 = `/rom` 的,無殘留 bind,lease 釋放。fails=0 |
| E-H13 | 壞 rootfs → panic → 回到原槽 | ⚠️ **前置 ✅ 2026-11-03**(04 wsl.22,`eh13-pre-254.sh` 第 2 輪 16 PASS / 0 FAIL):`p3-payloads.sh badpayload` 由 V 做出壞 payload(驗收 6/6、SUMS 只換 root 那行);`batman-slot apply` 收下、驗證通過、tryboot 旗標 = 1;緊接著 `stage-root` 只印 `/dev/mmcblk0p4`、旗標 = 0、B 的 FAT 有 `BATMAN-BAD`;undo 刪掉 `shutdown.reason`;收尾:還原循環(diffs = 只有 protB 兩行)、B 以 V 重寫(trial HELD → 回 A)、`slot-B.protected` = V、B 沒有 `BATMAN-BAD`、02 沒重開。第 1 輪在第 1 步中止(wsl.exe 把內嵌 shell 展開兩次),沒動到槽,還原 diffs = 0。**本體(重開進壞槽 → panic → 回 A)在現場** |
| E-H15 | ethsim(mesh、前提檢查、還原、uclient 結束碼、RSS) | ⚠️ 2026-11-03(04 wsl.22,`eh15-ethsim-254.sh` 第 3 輪 12 PASS / 1 FAIL):undo 先登記再建;h4v0 是 br-ahwlan 的 port;netns 的 MAC 出現在 `batctl tl`;uclient 結束碼 :80 = 0、被拒 = 4、沒回應 = 4(**結束碼分不出被拒與逾時 → 判定只靠 tcpdump**);`start-stop-daemon -c 471:471` → uid 471;120 個同時:117 個在跑、MemAvailable −265 MB;VLAN 雙層 10 SYN、沒有 SYN-ACK / RST;docker0 路徑 :80 = 0;拆除後無殘留。**❌ 速率**:60 秒只送出 1326 / 3000(wall 127 s,行程數頂在 120 上限)= 在受測節點上自己產生流量的**誠實界線**(§4.5),tcpdump 1326 SYN / 1326 RST / 0 SYN-ACK。named counter 與 helper 前提檢查要等 P3 |
| E-H16 | WSL 非 root 沙箱 + 逃脫負測試 | ❌ §15-2 |
| E-H17 | 在 F 上預演 S0-pre | ❌ §15-4 |

## 附錄 A. 逐列對表

**欄位**:# | 來源 | 臂 | 載 | 斷言 | 負

- 「E_U」= `E_UNSUPPORTED`。
- 「W(E_U)」= 在 S0-pre 上,第一個 P3 動詞回 E_U → `FAIL <row>: <type> E_UNSUPPORTED`。

### A.1 `prov-p3-routes-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| RT1 | §8 動詞 × 角色 × owner-op | matrix-ble | R | 碼與 reason 逐一相等(`p3-expect.tsv`) | W(E_U) |
| RT1h | 同上,HTTP | matrix-http | RB(T 窗) | 同上 | S(`http-allow-nx`) |
| RT2 | key 20 經 HTTP → `E_U{2: 19}` | key20-http | RB | | S(`k20-any-transport`) |
| RT3 | §6 首次:HTTP 不聽 | idle | R | relay → 8095 是 refused / timeout;`netstat` 沒有 8095;同一臂內 :80 = 200 | P(同一單位內開窗後連得上) |
| RT4 | legacy key 2 / 20 → 20 | legacy | L | `E_U{2: 20}` | W(E_U,沒有 reason) |
| RT5 | scope 1 / key 10–13 → 7 | matrix | R | `E_U{2: 7}` | W(E_U,沒有 reason) |

### A.2 `prov-owner-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| OW1 | add | add | R | Hx `auth/owner` 成功 | W(E_U) |
| OW2 | 重送輪替 | resend | R | 新 tag key ≠ 舊的,舊的失效 | W + P |
| OW3 | remove 切 BLE + HTTP | remove | RB(T 窗) | 時序:Hx 先開一條 BLE session(Windows 對同一台節點只能有一條 BLE 連線)與一條 HTTP session(手機);H0 經**另一條 HTTP session** 送 `owner/remove` Hx(P3 的 HTTP 有 2 個 slot,剛好用完)。斷言:Hx 的兩條 session ≤ 5 s 都 Closed;04 的 provd log 有兩行 `session revoked reason=`(`server.go:639`,不受限流);BLE 斷開後 ≤ 15 s 出現 `adv registered reason=disconnect`(`bluez.go:776-781`);Hx 重新交握 → peer 分類為 `fake`(加上 §4.2 的 fake path 佐證);`adv_owner_key` 輪替 | W + P(remove 前兩條都能用) |
| OW4 | 最後一位 | last | R(`run/`) | 依序移除 Hx、H0b → 成功;再移除 H0 → `EForbidden "cannot remove the last owner"`。還原:H0 以 `owner/add` 重新加入 H0b(journal 記新的 tag key),然後 `s0_assert` S0 版。**不用 p5 快照**(那是 pr_restore 的事,v4-A m10) | W |
| OW5 | remove 重送 | resend-rm | R | `E_FORBIDDEN` | W + P |
| OW6 | §7 遺失手機:psk 失效 | psk | RB | 被 remove 的 Hx,psk_owner 交握失敗 | W |

### A.3 `prov-settings-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| ST1 | get | get | R | 值 = uci;原值 grep = 0 | W(E_U) |
| ST2 | 新卡 → 認領 → key 20 → 不重開 | fresh-k20 | F | (a)(b);boot_id 不變;p5 有新值 | W(F on wsl.22:E_U) |
| ST3 | `bulk.open ≠ 16` | fresh-bulk | F + RB | pending 存在(P)→ ok | W + P |
| ST4 | 已入網 key 20,plink 不斷、不走退路 | member-k20 | R | `connected time` 遞增;沒有退路那一行 | S(`setkey-full-restart`)+ P |
| ST5 | 新卡注入失敗 → 四項 | fresh-k20-fail | F + RB(`setkey-apply-fail`) | AP 不在空中、`disabled=1`、MARK、p5 不變;`E_REJECTED{13}` | S(`setkey-norollback`) |
| ST6 | 已配對注入失敗 → 舊帳密 | k20-fail | RB | hostapd = C0;手機 `authorized` | S(`setkey-norollback`) |
| ST7 | D-6 | fresh-k20-rbfail | F + RB(`setkey-apply-fail` + `setkey-rbverify-fail`) | rc 6;AP 封鎖、不在空中;CRIT;`status` 回報;13 | S(`setkey-no-reblock` → AP 留在空中)+ P |
| ST8 | 讀回 | readback | RB(`setkey-apply-fail`) | 失敗被發現 → 13 | S(`setkey-readback-skip`) |
| ST9 | passphrase 不外洩 | secret | RB(`uci-argv` + cmdline 每 10 ms 取樣) | 節點上的計數 = 0;WSL 原值 grep = 0 | S(bind `setkey-argv-leak`,§5.5) |
| ST10 | 密碼含 `$` → 13 | input | R | 13 | W |
| ST11 | 持鎖 15 s | lock | R | 成功;總時間 ≥ 15 s(持鎖者的時間戳)且 ≤ 230 s | W + P |
| ST12 | 殺 helper → setkey 自己完成 | kill-helper | RB(`setkey-apply-fail` + `setkey-pause`) | setkey(另一個 pgid)完成並還原;AP = C0 | S(`setkey-notrap`) |
| ST13 | 暫存 → `E_BUSY` + `status` | staged | R | `E_BUSY`;key 15 有 `uci_staged`;臂後斷言暫存沒有被別人 commit | W + P |
| ST14 | 未入網改國家(`DE`) | fresh-k2 | F | 成功;p5 有新值 | W |
| ST15 | 已入網 key 2 → 14 | member-k2 | R | 14 | W |
| ST16 | 同值 set 在 stale 時存檔 | stale | RB | p5 被存、沒有 reload | W + P(`--check` 確實是 stale;還原 `p5-save`) |
| ST17 | 改名 → rename-pending | rename | R | E_U(rename-pending) | —(不變) |
| ST19 | D-5 | d5 | RB | 三種情況的結束碼與線上碼,依 D-5 的表 | S(`setkey-rc-legacy`)+ P |
| ST20 | D-7 / D-12 | d7 | F + RB | 未入網的 key 2 成功、沒有被還原;`status` 回報「SSID 無法保存」 | S(`d7-ssid-rc6`) |
| ST22 | 共存 | coex | R | 只記錄 | — 量測 |

### A.4 `prov-country-join-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| CJ1 | join 國家不符 → 14 | join-mismatch | F | key 2 = AU、join N0(US)→ 14;`.txn` 不在;uci 的 sha 不變 | W(F on wsl.22:root 以 uci 設 AU;AU 有 ch 40,F-H43 → 入網成功 → `FAIL CJ1: joined with country mismatch`) |
| CJ2 | update 國家不符 → 14 | update-mismatch | R | 同上 | W(同上的手法 → 套用成功 → FAIL) |
| CJ3 | 先 key 2 再 join → 成功 | join-ok | F | 成功;02 看得到 plink | W(E_U key 2) |

### A.5 `prov-status-diag-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| SD1 | status 與 halow-status 一致 | status | R | 逐欄相等 | W |
| SD2 | 成員只拿摘要 | member | R | 只有摘要的欄位 | W + P(角色) |
| SD3 | ro 10/s × 10 分 | ro-load | RB(T 窗) | 沒有 `cfgsave-lock.busy`;沒有 ERate;04 端廣播在 | S(`ro-on-ctl`);另外 helper 的 `ro_served` 增量 ≥ 2700(以 provclient 經 `sock-as 471` 的自己那一條連線讀 `info.state`,不經 ro 連線,所以讀取本身不算進去)+ P(ok + E_RATE ≥ 5400,ok ≥ 2500) |
| SD4 | bundle | bundle | R | > 64 KiB、`tar t`、原值 grep = 0 | W + P |
| SD5 | handle 跨 session | handle | R | 15 | W + P |

### A.6 `prov-bundle-gate-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| BG1 | claimed → 403 | claimed | R | 403 | W(200) |
| BG2 | legacy 沒有旗標 → 403 | legacy | L | 403 | W(200) |
| BG3 | unclaimed / legacy + dev-open → 200 | devopen | F + L | 200;刪旗標 → 403 | P |
| BG4 | `status` 仍 200 | status | R | 200 | — |

### A.7 `prov-http-254`(判定 = named counter + 04 端 tcpdump,§4.5)

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| HT1 | 正向 | pos | RB(T 窗) | 交握成功;`batman_http_mark` 增加 | S(兩邊 `http-nofw`;v5 規則 → 連不上)+ P |
| HT3 | 停 bluetoothd 5 分 → 聽 | fb-bt | R | 5 分 ± 10 s 時連得上;提早 30 s 時連不上 | W(`not listening after 300 s`) |
| HT4 | `sc_file` 失效 → 聽 | fb-sc | RB | 同上 | S(`healthok-2field`) |
| HT5 | 恢復 | fb-recover | R | 不收新連線、既有的保留 | W + P |
| HT6 | psk_owner → 候選 → `auth/owner` | roles | RB | 成功 | P(由 HT7 的 S 涵蓋) |
| HT7 | NX / psk_replay 被拒 | roles-neg | RB | 關閉 | S(`http-allow-nx`) |
| HT8a | 偽造 MAC + IP + ARP | mesh-a | RB + ethsim | drop 增加、沒有 SYN-ACK | S(兩邊 `http-nofw`,不載 `batman_http_in`)+ P |
| HT8b | 洪流 50/s × 10 分 + poll 沒有 ERate + 擁有者傳完 + 廣播在 | mesh-b | RB + ethsim + 手機 | 同上 + helper log 沒有 ERate + 上傳完成 + 04 端廣播在 | 同上 |
| HT9 | lo(目標是 br-ahwlan IP) | lo | RB | drop 增加 | S(同上)+ P |
| HT10 | VLAN 雙層 | vlan | RB + ethsim | 沒有 SYN-ACK、drop 增加 | S(兩邊 `http-nofw`;v6 規則 → 有 SYN-ACK) |
| HT11 | docker0 + VLAN | docker | RB + ethsim | 同上 | S(同上) |
| HT12 | 刪表 → ≤ 8 s 不聽 | deltable | RB(T 窗) | 前提:誘發前 `netstat` 有 8095 LISTEN(P);刪表後 ≤ 8 s `netstat` 沒有 8095 | S(`http-nofw`) |
| HT13 | reload → 兩張表、各一份 | reload | R | | W(表不在) |
| HT14 | `firewall stop` | fwstop | RB(T 窗;H4-U11) | 前提:誘發前 8095 LISTEN;≤ 8 s 不聽 | S(`http-nofw`) |
| HT15 | helper 停 | helper-stop | RB(T 窗) | 前提:誘發前 8095 LISTEN;停 helper 後 ≤ 8 s 不聽 | P |
| HT16 | provd crash | provd-kill | RB | 斷線;tmpfs = 0 | P |
| HT16b | provd 正常停止 | provd-stop | RB | 同上 | P |
| HT16c | provd 每 5 s 重生的迴圈 | provd-loop | RB(`crash-on-start`) | 迴圈期間不聽、helper 正常、上傳檔被刪 | P |
| HT17 | hostapd / `wifi reload` | wifi-reload | RB | 手機重連後連得上 | P |
| HT18 | `auto_includes = 0` | autoinc | RB(T 窗) | 前提:誘發前 8095 LISTEN;不給 `http.2`、≤ 8 s 不聽 | S(`http-nofw`) |
| HT19 | D-3 | bit24 | RB(T 窗) | 前提:誘發前 8095 LISTEN;不聽;`status` 回報 | S(`http-nofw`) |
| HT20 | D-8 | d8 | RB + ethsim | 仍被丟 | S(兩邊 `http-nofw`,不清 bit 的規則 → 放行) |
| HT21 | D-13 | d13 | RB(T 窗) | 前提:誘發前 8095 LISTEN;`http.2` 消失;`status` 回報 | S(`http-nofw`) |
| HT22 | §6 依賴重啟 dbus | dbus | R | BLE 回來 ≤ 15 s;沒有因此開啟 HTTP 備援 | P |
| HT23 | §3.8.1 `phy*` 前提:bridge 上有不屬於 radio0 的 `phy*` port → 不給 `http.2` | phy-premise | RB(T 窗,**沒有** `http-nofw`)+ ethsim 的 `phy9h4` | 前提:先斷言 8095 LISTEN(P);`phy9h4` 接進 br-ahwlan → ≤ 8 s 內 `http.2` 消失、8095 不聽;刪掉 → 恢復。這也是「`phy9h4` 殘留時 fail-closed」的證據。不斷言 `status` 有回報:P3 沒有定義這一項 | S(`http-nofw` → 照樣給 `http.2`) |

### A.8 `prov-upload-254`(RB,T pending)

| # | 來源 | 斷言 | 負 |
|---|---|---|---|
| UP1 | AP 關 → 16 | 16 | W + P |
| UP2 | 不是窗的擁有者 | 被拒 | S(`upload-noowner`) |
| UP3 | 來源 IP | session 在手機上,PUT 經 `phy9h4` → 被拒 | S(兩邊 `http-nofw` + `phy9h4`,只差 `upload-nosrcip`) |
| UP4 | 大小不符 → 15 | 15 | W + P |
| UP5 | ENOSPC | 以 uid 471 直接寫超過 `size=` → ENOSPC;其他服務正常 | P |
| UP6 | 窗外的上傳檔被刪 | 先存在 → ≤ 8 s 用量 0 | P |
| UP7 | 上傳中 `network/update` → `E_BUSY` | | S(`upload-nobusy`) |
| UP8 | 上傳中 helper 重啟 | 重新開窗、重傳成功 | P |
| UP9 | `owner/remove` 清窗 | | W + P |
| UP10 | D-15 | `bulk-mount-fail` → 被拒;不是一般目錄 | S(`bulk-mount-fallback` → 退回一般目錄、照收)+ P |
| UP11 | §7 搶建 bulk 路徑 | uid 65534 建不了;root 預建 symlink → init 拒絕 | P |

### A.9 `prov-update-254`

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| UD-T1 | release 拒收 T | t-reject | R | 先讀 status key 15 `trust`(provclient 印 `trust=`):= T 的指紋(`tests/keys/T.pub` 的 sha256 前 8 bytes)→ INVALID(bench image 信任 T,UD-T1 要 R image);`none` → `{1: false, 2: 24}`;其他指紋(R)→ `{1: false, 2: 11}`;`bad` → FAIL;key 15 沒有 trust → INVALID(S5 之前的節點,或 provclient 沒印)。再用 release-key-254 的 `rk_judge` 比對 `/rom` 的兩個鑰匙檔(照 `release.LoadTrust` 讀)和 key 15 的 trust:不一致 → FAIL(r2 A-m2 / B-m10)。bench fleet(02 / 04 都信任 T)上這列一定是 INVALID;R 與 none 兩臂的證據在離線,直到有 R image 上機(r2 B-m9):Batman-p3 `feed/batman-prov/src/release/release_test.go` `TestVerifySignrelNegative`(「another root」→ 11、「no key in the image」→ 24)、`feed/batman-prov/src/node/update_test.go` `TestUpdateCheckRefusals`(「no key」→ 24)、firmware `scripts/check-release-key-gate.sh` + `scripts/test-release-key-gate.sh`(release image 不含 T) | S(同一份 manifest 在 RB 上會過) |
| UD-L | §3.7.3 持鎖動詞回來後放鎖 | lock-free | R + RB | 每個由 helper 跑持鎖 `batman-slot` 動詞的步驟(`update.check` 的 precheck-node + bootinfo、prepare 的 write、apply 的 arm、disarm)回報完成後 1 s 內 `flock -n` 成功,而且步驟期間啟動的行程沒有開著鎖檔(`pr_slot_free`,`slk_free`);只被步驟外的行程持有,或被別的寫入者(祖先裡沒有 batman-provhelper 的 `batman-slot`)持有 = INVALID(r2 B-m3)。`update.check` 只要跑過 precheck-node 就判(`pr_precheck_ran`:ok = true,或 reason 是 precheck-node 或其後才會給的 1 / 2 / 5 / 8 / 12 / 17 / 21;Batman-p3 `node/update.go:249-331`;r2 A-m3);停在它之前(R:11、none:24、板子 / 版本:3 / 4 / 6)或分不出來(11 也可能是 precheck-node rc 13)→ 一條 `NOT-JUDGED` 判定列(`nj`,計在 RESULT 行,不改 UNIT 判定),不是只寫 log;prepare / apply / disarm 等 RB 列寫好時同樣斷言 | S(背景子程序不 `9>&-` 的 batman-slot 變體 → FAIL;離線 `scripts/test-slotlock-254.sh`、`scripts/test-s5-dv-254.sh`) |
| UD1 | T → trial → commit → 5 | main | RB → T | 2 → 3 → 4 → 5 | W |
| UD2 | 同版本退回 → 6 | same | RB → T | hold → 到期 revert → 6 | W + P |
| UD3 | arm 前斷電 → 0 | kp-before | RB(`upd-before-arm`) | 0;沒有旗標 | S(`upd-after-arm` → 進試用;副作用見 §13) |
| UD3b | arm 後 helper crash → disarm、3 | arm-crash | RB(`helper-arm-crash`) | 重啟後旗標被清、3 | S(`no-boot-disarm` → 旗標留著)+ P |
| UD4 | 新版沒開機成功 → 6 + 18(P3 寫 kernel 壞掉,H4 改成 rootfs superblock 壞掉,§1.4-7) | badroot | RB → T | panic → 回原槽;6 + 18 | W(E_U `update/check`)+ P(panic 行) |
| UD5 | 舊的 bad-slot 不造成假 6 | oldbad | RB | 5 | W + P |
| UD6 | worker 失敗的 reason | worker | RB | 1 / 11 / 12 / 17 | W + P |
| UD7 | 七種拒絕(簽章、serial、板子、降級、min_from、開機設定、版本解析) | reject | RB | reason 逐一相等(min-serial 編在 helper 裡) | W |
| UD8 | 四包惡意 tar | malicious | RB | 11;槽 BAD、不 arm | W |
| UD8b | §8「上傳檔換成 FIFO」(prepare 之前換) | fifo-pre | RB | 以 uid 471 把上傳檔換成 FIFO → `update.prepare` 的大小檢查回 `E_REJECTED{15}`、FIFO 被刪(P3 `:327`、`:456`) | W(E_U)+ P(檔案確實是 FIFO、擁有者是 471) |
| UD8b-race | §8 同上(prepare 之後、worker 開檔之前換;被入侵的 provd 能贏這個競態) | fifo-race | RB(`upd-open-pause`) | prepare 回 phase 2 之後,在 30 s 暫停窗內以 uid 471 換成 FIFO → 暫停結束後 ≤ 10 s 內 `update.status` = phase 0 + 11、FIFO 已刪、B 不是 BAD、同值的 `settings.set` 不是 `E_BUSY` | S(`upd-open-pause` + `upd-open-block` → 同一時限過後仍是 phase 2;`update.status` 只讀快取(P3 `:347`),所以不會逾時,判定看 phase) |
| UD8c | §8「上傳後改 payload」 | mutate | RB | 上傳完成、prepare 之前,以 uid 471 **先刪掉原檔、再寫入**(tmpfs 只有 2 × payload,兩份同時在會 ENOSPC)**另一個合法、而且長度相同的 tar.gz**(worker 會先比 fstat 的大小 = key 3,P3 §3.7.5-1)。第一個成員仍是簽過的 `SHA256SUMS`,`metadata`、`boot/` 都不變;`root.squashfs` 保留 `hsqs` magic、長度不變、內容不同(mutant 先做得比原檔短,壓縮後的總長再用 gzip header 的 `FEXTRA` / `FCOMMENT` 欄位補到與原檔相同;比原檔長就補不回來,要重做)。gzip 與 tar 解析都會過,讀回時與 `SHA256SUMS` 不符 → B 被 invalidate、不 arm、11 | W + P(換過的檔是合法 tar、總長相同、`root.squashfs` 的 sha 不同) |
| UD9 | prepare 中 kill / 斷電 | kill | RB(`upd-write-mid`) | 槽 BAD、仍在舊槽 | P |
| UD10 | helper 重啟 → phase 3 | rebuild | RB | 3 | W + P |
| UD10b | 重開 → pending 不在 | reboot | RB | 不在 | P |
| UD11 | 回滾臂 / 降級到 wsl.22 | downgrade | R → ssh sysupgrade | 舊槽沒有 P3 動詞;`.txn` 相容;舊版判 stale 直到它自己 `--save`;舊版 96 照樣套用 ssid 行;update-last 留著沒人讀;S0-pre 版的 `s0_assert`。之後 sysupgrade 回 V + `upgrade`(§13) | P |
| UD12 | 未入網升級 → fresh | upgrade-unjoined | F(wsl.22)→ sysupgrade | fresh | G(H4-U8) |
| UD12b | 已入網升級 → tick 存檔 | upgrade-joined | R(wsl.22)→ sysupgrade | fresh | P |
| UD13 | SSID 含 `'` | quote-ssid | RB | 通過 | W + P |
| UD14 | 沒列名的 dtb | sysupgrade | R | 沒有那個 dtb | S(`slot-copy-all`) |
| UD15 | YubiKey | bench | R | — | NEEDS-PERSON |
| UD16 | D-9 試用轉 committed | d9 | T | commit 後 fresh | G(H4-U8) |
| UD16b | 非試用開機時存一次 | d9-boot | RB | stale(P)→ restart → 存 | S(`p5-autosave-off`) |
| UD17 | D-10 | d10 | RB | (a) 6 不帶 18;(b) 旗標不在 | S(`d10-no-disarm`) |
| UD18 | D-14 | — | C | `write` 寫入中送 TERM 之後,在有上限的等待內(ash 等前景的 `dd` / `cat` 回來才跑 TERM trap,所以不是「立刻」;上限 30 s):(1) 目標槽的 boot FAT 不在任何 `/proc/mounts` / `mountinfo` 裡(以 major:minor 比對);(2) 被殺的 `batman-slot` 沒有留下開著鎖檔的子程序(`/proc/*/fd`,以啟動時帶的 `DV_SLK` token 辨認),而且 1 s 內 `flock -n` 成功(`slk_free`);(3) 鎖可再取得(下一個 `bootinfo` rc 0)。只看 flock 不夠:kernel 在持有者結束時一定放鎖,有沒有 trap 都一樣(r1 A-MAJOR-3) | S(沒有 `trap 'exit 143' TERM` 的變體 → EXIT trap 不跑、B 的 boot FAT 留著掛載 → (1) FAIL)+ S(背景子程序不 `9>&-` 的變體 → 子程序持有 fd 9、鎖被持有 → (2) FAIL) |
| UD19 | D-12 | d12 | RB(`setkey-pause`;provclient 直接打 helper) | ≤ 5 s 回應 | S(`d12-take-mu`) |
| UD20 | §7「被入侵的 provd 偷換 pending 版本」:owner-op 簽的不是 pending | swap | RB(provclient 直接打 helper,uid 471) | 資料路徑:provclient `nonce` 取 helper nonce → WSL 的 peer 用 H0 簽 owner-op → provclient 送 `update.prepare`。pending = X、body 的 sha = X;**負向**:owner-op 是對 Y 簽的 → `args_hash` 不符 → `E_FORBIDDEN`、沒有啟動 worker。**正向**(同一份 pending 與 body,只差被簽的 sha):用新的 nonce 對 X 簽 → 成功。兩者只差一個變數,而且拒絕條件只剩 `args_hash` 一個(v8-A m9) | W(E_U)+ 正向是 flip。helper 每次驗 owner-op 都會消耗 nonce,失敗也一樣(`node.go:672-690`、`:310-319`),所以兩臂各用新的 nonce。正向會真的啟動 worker、覆寫 B:**順序固定為 UD20c → UD20b → UD20 負向 → UD20 正向(最後)**,之後 brewrite B(§13);prepare 失敗會刪上傳檔(`:456`),所以每一臂前都重新上傳 |
| UD20b | 同上:owner-op 有效、但 sha ≠ pending | swap-sha | RB | 擁有者以新的 nonce 對 Y 簽一個有效的 owner-op,而 pending 是 X → `E_REJECTED{15}`(P3 `:327`) | W(E_U)+ P |
| UD20c | §7 同上:被入侵的 provd 用**不需要 owner-op** 的 `update.check` 把 pending 換成 Y(v8-B m1) | swap-check | RB(provclient,uid 471) | 擁有者已對 X 做過 `update.check`(pending = X);provclient 以 T 簽的 Y manifest 送 `update.check` → pending 變成 Y;擁有者接著以對 X 簽的 owner-op 送 `update.prepare {sha: X}` → `E_REJECTED{15}`(sha ≠ pending),沒有啟動 worker → 證明換掉 pending 也沒辦法讓 Y 不經擁有者簽章就被寫入 | W(E_U)+ P(pending 確實變成 Y:`update.status`);P3 `:568` 把這條指定給 Go 單元測試,H4 另加這一個黑箱臂 |

### A.10 `prov-autocommit-p3-254`(§5.6)

| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| AC1 | 正常 → commit | pos | T + RD | T:committed;RD:COMMIT | S(`provd-id-pid` → REVERT) |
| AC2 | provd 壞掉 → revert | badprovd | RD | REVERT | S(`ac-noprov`) |
| AC3 | helper 不在 → revert | nohelper | RD | REVERT | S(`ac-noprov`) |
| AC4 | 穩定後被殺 → commit | stable-kill | RD | COMMIT | S(`provd-id-pid`) |
| AC5 | provclient 掛 60 s 不算 | provclient | RD | REVERT | S(`stable-any-471` → COMMIT) |
| AC6 | provd 停用 → WARN + commit | disabled | RD | COMMIT + WARN | S(`ac-provd-required`) |
| AC7 | D-16 | d16 | RD | COMMIT + WARN | S(`ac-helperoff-err`) |
| AC8 | D-17 | d17 | RD(假 `nft`) | REVERT | S(`ac-nofw4`) |

### A.11 其他

| # | 來源 | 單位 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| TT1 | 轉賣工具 | transfer | C + 真卡(NEEDS-PERSON) | §3.9 | S(`--test-skip-wipe`) |
| LR1 | firstboot 後仍在 | luci-reset | F(最後) | 三者都在 | W(舊字串) |
| RK1 | §3.7.1 / r1 B-M6:非 bench image 不信任 T(T 的私鑰任何人都算得出) | release-key | R(每次) | image 信任的 root 照 helper 的 `release.LoadTrust`(Batman-p3 `release.go:84-125`)讀 `/rom/usr/share/batman/` 的 `release-root.pub` 與 `release-min-serial`:兩個都沒有 = trusts none(PASS);兩個都是一行、格式對(04 + 128 hex 的點、1–10 位不以 0 開頭的 serial)= 信任該點;只有一個、多行、值不對 = bad → FAIL(r2 A-m2 / B-m10)。信任的點 = `tests/keys/T.pub` ⇔ `/rom/etc/batman-build` 有 `BATMAN_BENCH_TRUST=T`(且版本含 `.bench`);有 provclient 的 status 時(prov-update-254 UD-T1)key 15 的 trust 必須等於 `/rom` 那個點的指紋(或 none);`scripts/dv/s5-254.sh` `release-key-254` | S(離線 fixture:T 但沒有 bench stamp、bench stamp 但不是 T、未知的值、沒有 stamp、只有 pub、只有 serial、serial 0 / 前導 0、兩行的檔、CRLF、status trust 不一致 → FAIL;`scripts/test-s5-node-254.sh`) |
| FB2 | `nft -c` | fw-boot | bench | rc 0;`prov-fw-boot-254` 每次執行在每個 fleet 節點跑 `fw4 print \| nft -c -f -`(兩板,唯讀;r2 B-m4) | S(壞 include → rc ≠ 0;離線 fixture:`nft -c` 拒絕、`fw4 print` 失敗 → FAIL,`scripts/test-s5-node-254.sh`) |
| FB3 | `fw-badinclude` | fw-badinclude | W(02) | §8.3 | P |
| EE1 | D11 採用 | eeprom | C | §8.2 | W(1.5.12-wsl.2)+ P(沒有 shim) |
| EE2 | D11 fresh-overlay / READ rc 1 | eeprom | C | rc 1 | W(1.5.12-wsl.2 → rc 0) |
| PR1 | D-1 / D-2 | 探針 | 04 | §7 | v6 規則 |
| SEC1 | §7 非 root 的 fault 檔 | prov-sec 補 | R | setkey 照常還原;TAMPER | P |

**D 項對照**:
- D-1 → HT10、PR1;D-2 → PR1;D-3 → HT19 + lint;D-4 → HT8a / b;D-5 → ST19;D-6 → ST7;
- D-7 → ST20;D-8 → HT20;D-9 → UD16 / UD16b;D-10 → UD17;D-11 → ST9;D-12 → UD19 + ST13 + ST20;
- D-13 → HT21;D-14 → UD18;D-15 → UP10;D-16 → AC7;D-17 → AC8。

### A.12 `prov-fw-boot-254`(R,常規全套每次執行 = 每次開機後;`scripts/dv/s5-254.sh` + `scripts/node/fw-boot-254.sh`,唯讀)

S5 之前的 image(`batman-slot` 沒有 `slot_lock`)→ 一條 FAIL「pre-S5 image <版本>」,什麼都不判;`scripts/validation-known-failures.txt` 有一條 KNOWN 條目,`expires=2026-12-15`(和 P3 那三條同一天,是**佔位日期**,由使用者定),到期後 `kf_classify` 判 NEW(r2 B-MAJOR-1;離線測試 `scripts/test-s5-node-254.sh`:到期當天 KNOWN、隔天 NEW)。INVALID 只留給鎖被別人佔用、或動詞在拿鎖之前就停了。

**副作用**(這個單元不是嚴格唯讀;r2 A-m4):
1. `precheck-node` 會照 sysupgrade stage 1 的方式改寫 p5 判定檔(`$RUNDIR/p5-check.rc`),寫的是當下的真值;
2. `bootinfo B` 在 **host 的 mount namespace** 把 B 的 boot FAT 以唯讀掛在 `/mnt/slotboot.<它的 pid>`,動詞結束時由它自己的 EXIT trap 卸載(helper 跑動詞時是在私有 namespace,這裡是從 ssh 直接跑);
3. 遠端 shell 如果在 `bootinfo B` 期間被殺(主機端 ssh 的 timeout 300 s),這個掛載可能留下來,之後每個 slot 動詞都會因 `tboot_elsewhere` 回 rc 14,直到它被卸載或重開機。清理:每個動詞的 pid 記在 `/tmp/run/batman-dv/fw-boot-254.pids`(只在這個目錄是我們自己的、不是 symlink 時才寫),下一次執行先在 slot 鎖底下卸載「記錄過的 pid、該 pid 已不是執行中的 `batman-slot`」的 `/mnt/slotboot.<pid>`,印一條 INFO;卸不掉 = FAIL。只碰自己記錄過的 pid 的掛載,別人的不動。動詞正常回來後掛載還在 = FAIL(它的 EXIT trap 沒卸載),並當場卸載;
4. 寫上述 pid 檔。


| # | 來源 | 臂 | 載 | 斷言 | 負 |
|---|---|---|---|---|---|
| FB1 | §3.8.1 三道關 (2):include 一錯整份 fw4 失敗(F70) | fw-boot | R(每次開機後) | `inet fw4`、`bridge batman_http`、`inet batman_http_in` 都在 | S(離線 fixture:缺 fw4、缺一張表 → FAIL;`scripts/test-s5-node-254.sh`)+ FB3 |
| FB4 | F70 reload 不重複規則 | fw-boot | R(每次開機後) | image 的 include(`/rom/usr/share/nftables.d/ruleset-post/batman-http.nft`,不手抄)裡每條帶 comment 的規則在 nft 裡正好一條;fw4 讀的 include = image 的那份 | S(離線 fixture:同一規則兩份、overlay 改過的 include、沒有 comment 的 include → FAIL) |
| FB5 | §3.8.2 provd 的上傳 tmpfs | fw-boot | R(每次開機後) | provd 在跑 → init 的 `BDIR` 是 tmpfs、只掛一次、不是 symlink,掛載選項 = init 自己的(`nodev,nosuid,noexec,mode=0700,nr_inodes=16,size=<本板>,uid=471,gid=471`;size 以 KiB 顯示、4 KiB 頁進位);provd 沒跑 = 記錄、不判 | S(離線 fixture:少 noexec、size 不同、沒掛、疊掛、未知的板子 → FAIL;ekh-bcm2711 與 ekh-bcm2710 各一個 good) |
| FB6 | §3.7.3 通用測試:持鎖動詞回來後 1 s 內放鎖 | fw-boot | R(每次開機後) | `batman-slot bootinfo A`、`bootinfo B`、`precheck-node`(帶 `DV_SLK` token)各自回來後 1 s 內 `flock -n` 成功,而且帶 token 的行程(動詞留下的子程序)沒有開著鎖檔。不管動詞回什麼都判鎖(r2 A-MAJOR-2):節點狀態的拒絕(precheck-node 10–12 / 13 / 15–18、`detect_layout` 在動詞之前的 17,例如 Pi 4 plain reboot 開到錯的槽)只記一條 INFO;rc 14 或只被別人持有 → 重試 5 次,仍是 → INVALID;動詞失敗而且沒有鎖檔 → INVALID(在拿鎖之前就停了);rc 0 而沒有鎖檔 → FAIL。副作用見上 | S(子程序不 `9>&-` 的變體 → FAIL,動詞回 16 時也是;拿了鎖再回 16 / 17 → PASS;拿鎖前 17、沒有鎖檔 → INVALID;rc 0 不拿鎖的變體 → FAIL;`bootinfo B` 留下掛載 → FAIL;上一輪留下的掛載 → 卸載;`scripts/test-s5-node-254.sh`、`scripts/test-slotlock-254.sh`) |

## 附錄 B. v1、v2 的處理

- v1 的處理見 d5cf7ed 的附錄 B;
- v2 的處理見 282b48b 的附錄 C。
- v4 沿用;改動見附錄 C。

## 附錄 C. v3 審查的處理

| 意見 | 處理 |
|---|---|
| B-B1 member 認不出目標 | (v4 的做法,已被附錄 D 取代:改驗 node_cert)§4.2 用 static key 認證 + 負對照;§3.1 庫裡記每台的身分;預演 |
| A-M1 / B-M2 S0-pre 的 02 與工具 | H4-U7 加 02 網路線;§3.1 步驟表(claim.secret 經 stdout → stdin、先放 lab key、pk_proof、netobj、等 `.txn` 與重開、setkey);`netobj.py`;F 上預演;§3.3 加「02 離開 mesh」 |
| A-M2 / B-M1 壞 rootfs | §8.1 保留 magic、改 `s_major`;loop 驗收;04 上 apply 但不重開的前置;E-H13 後 brewrite B;§1.4-7 |
| A-M3 EEPROM 沙箱 | H4-U12;§8.2 非 root + 逃脫負測試;F-H22 |
| A-M4 counter | §1.4-6 named counter;§4.5 / §7 目標一律是 br-ahwlan IP;判定 = counter + tcpdump |
| B-M3 undo 契約 | §5.7:同一個執行器、段 1 去武裝 / 段 2 狀態、`done`、冪等、持有鎖;p6 `dv-undo`;`restoring`;lease 契約改寫 |
| A-m1 wget | F-H15 |
| A-m2 / B-m5 速率 | §4.5:目標 50/s;並發依 RSS 定;達不到就列為界線並回報 |
| A-m3 互斥 | §5.7 |
| A-m4 / B-m10 HT14 保險 | §5.7 可取消、先檢查;H4-U11 |
| A-m5 kill | `kill-pg` |
| A-m6 / B-m11 重開迴圈 | §4.4 預算 + 只延長一次 |
| A-m7 擁有權 | §9 |
| A-m8 / B-m3 min-serial | §1.4-2、§8.1 |
| A-m9 `ap-restore` | §5.7 |
| A-m10 / B-m16 槽字母 | §3.1 |
| A-m11 寫死 wsl.22 | §6.1 版本清單 |
| A-m12 / B-m1 D11 | EE1 改 wsl.2 + P;EE2 |
| A-m13 標記 | UD4 加 W;AC5 改 S;CJ1 依 F-H43 確認 |
| A-m14 dbus | HT22 |
| A-m15 uci shim | §5.5 |
| A-m16 IP 變動 | §3.1 第 6 步 |
| A-m17 log 拷回 | §4.1、§16 |
| B-m2 pre-P3 的 RB 前置 | §2 |
| B-m4 lo | §4.5 |
| B-m6 docker0 位址 | §4.5 |
| B-m7 HT16c | `crash-on-start` |
| B-m8 ST13 | A.3 |
| B-m9 G 超出授權 | 補 S:`setkey-no-reblock`、`setkey-rc-legacy`、`no-boot-disarm`、`bulk-mount-fallback`、`stable-any-471`;G 只剩 UD12 / UD16 |
| B-m12 p5 的第二個寫者 | §9、`p5-save` |
| B-m13 UD3 的 S 會進試用 | §13 |
| B-m14 set-fault 前置 | §5.1 |
| B-m15 QR | §3.2 segno(待同意) |
| B-m17 dead-man 之後的 restore | §4.4 |

## 附錄 D. v4 審查的處理(每條附查證過的 `file:line`)

| 意見 | 處理 | 查證 |
|---|---|---|
| A-B1 / B-B1 static key 不能用來認目標 | §4.2 改在每一臂自己的交握裡驗 `node_cert`(釘選 DAC、`sig_static`、`sn`);庫裡存 DAC,不存 static key;fake path 的負向臂先認證、再重連同一個位址,並以 04 端 log 佐證;負對照改用「不屬於任何節點的 DAC」與「強制先試 02」 | F-H45、F-H46:`noise.go:29, 62-96`;`server.go:104-113, 673-683`;`session.go:300-321`;219 §3.3 |
| A-M1 / B-m3 netobj 的規格 | §4.1:自己實作;target = SHA-256(DAC pub)、加密給 `ecdh_pub`、先驗 `sig_ecdh`;join 帶 key 31;負向 selftest | F-H47:`wtxn.go:125-150`;CDDL `:205-210` |
| A-M2 / B-M1 執行器的鎖 | §5.7:`host` 模式(先 `arm`、在 `held` 下、忽略 HUP、`undo-doing` 標記)與 `deadman` 模式(在 `dm-fire` 同一個行程裡、不 renew / arm);重疊時 deadman 只做段 1 | F-H48:`ble-lib-254.sh:96-101, 137-155, 305-343` |
| A-M3 / B-m1 p6 持久 undo | §5.7:備份檔放 p6、綁槽與 boot_id、由 P9 / preflight 在 lease 底下執行;主機不在時不重放(fail-closed,寫進 §13) | — |
| A-m1 / B-m9 交握限速 | §4.1:每節點 ≤ 15 次 / 分;出現 `global handshake rate` → INVALID | F-H50:`server.go:35, 645-660` |
| A-m2 / B-m8 期限檔兩個寫者 / 快速重開 | §4.4:`fresh-grant`(主機)與 `fresh-spent`(迴圈)各一個寫者;每次開機先扣 uptime + 120 s | — |
| A-m3 / B-m7 tcpdump 介面 | §4.5:在入口介面擷取;看到的 SYN 不足 → INVALID;counter 歸零 → INVALID | — |
| A-m4 / B-m6 沙箱的逃脫負測試 | §8.2:`pivot_root` + 宿主 `$HOME` 不在新根;canary 負測試附「沙箱外會成功」的對照 | F-H55(v4-B 實測) |
| A-m5 claim.secret 的管道 | §3.1 第 3 步:節點端 hex | — |
| A-m6 `ap-restore` 的 C0 | §5.7:臂開始時 stage 到 tmpfs;重開後由主機從庫重送 key 20 | — |
| A-m7 / B-m5 E-H13 前置 | §8.1:`stage-root` 做 disarm + invalidate,接著 brewrite B | F-H49:`batman-slot:423-436, 650-656` |
| A-m8 `PROVD_KEYS` | §5.5:加 `BATMAN_FAULT` | F-H51:`ble-lib-254.sh:170` |
| A-m9 §13 的升降級 | §13 prov-update 列 | — |
| A-m10 OW4 用快照 | OW4 改用 `owner/add` 加回 H0b | — |
| A-m11 journal 的參數 | §5.7 的參數驗證 + 負測試 | — |
| A-m12 ST9 的變體 | §5.5 `setkey-argv-leak` | — |
| A-m13 §1.3 的事實 | F-H3 註明、F-H45–F-H55 | — |
| B-m2 `pk_proof` 的順序 | §3.1 第 3 步:先證明登入成功才認領 | `chain1-254.sh:342` |
| B-m4 新卡的位址與身分 | §3.1 第 2 步:依 MAC 掃描、斷言 `sn` 與 MAC、重新 pin host key;BLA | F-H52、F-H53 |
| B-m10 漏列的片語 | UD7 註明七種、UD8 / UD8b(FIFO)/ UD8c(上傳後改 payload)、UD11 涵蓋回滾臂、HT8b 加上 poll 沒有 ERate | — |
| B-m11 接縫清單擴大 | §1.4-2:完整清單即 §5 的三張表;列為凍結設計之外新增的產品程式,P3 的程式碼審查與 `/security-review` 要涵蓋 | `rundir.sh:44-52`;`protected_hardlinks=1` |

## 附錄 E. v5 審查的處理

| 意見 | 處理 | 查證 |
|---|---|---|
| A-M1 provd log 不存在或被限流 | §4.1 交握結果分類(`refused` / `budget` = INVALID);§4.2 fake path 的佐證改成「再送一個 frame → `session ended: message on the fake path`」,而且限速;請求的佐證改看 helper 計數;OW3 改看 `session revoked reason=` 與 `adv registered reason=disconnect`;HTTP 限速 ≤ 8 次 / 分 | `server.go:126-144, 639, 743-768`;`session.go:234`;P3 `:376` |
| B-M1 undo 重疊的時序 | §5.7:正常時 dm-fire 等鎖 → host 做完 `release`,dead-man 不動作;host 卡住 → deadman / recover 殺掉 host 執行器再做兩段;段 2 每個動作包 `lim`;子行程 `9>&-`;重疊測試附負對照 | `ble-lib-254.sh:327-343` |
| B-M2 沙箱的 cwd / fd 逃脫 | §8.2:`cd /`、關 fd ≥ 3、`env -i`、bind `/dev/*`;cwd 與 fd 兩條負測試,各附「拿掉修正就會被改」的對照;判定看 canary 內容 | v5-B 實測 |
| A-m1 / B-m netobj | §4.1:target 在 KDF context 的 PartyV、AAD 是標籤;join 帶 key 2;庫裡存 `net_root` / `net_id` / `net_version` | `wtxn.go:145`;CDDL |
| A-m2 / B-m 子命令名字 | §5.7 改用 `renew`;新增 `undo` 子命令;最後 `release` | `prov-lease-254.sh` dispatch |
| A-m3 重疊時其餘步驟 | §5.7:同一時間只有一個執行器,問題不再存在;輸出寫進節點上的 log 檔 | — |
| A-m4 `fresh-spent` 的初值 | §4.4 | — |
| A-m5 / B-m E-H13 前置的條件 | §8.1 | `batman-slot` `precheck` |
| A-m6 沙箱的 sanity 列 | §8.2 標成 sanity | — |
| A-m7 noiseprotocol 的 `rs` | §4.1 | v5-A 實測 |
| A-m8 P3 上重建 S0 | §4.1:先設 key 2 = US | P3 `:245` |
| A-m9 / B-m 編輯 | 狀態列、報告清單;§1.1、§12、§15、§17 的「static key」改成 `node_cert` | — |
| B-m HTTP / sock 也驗 | §4.2 | — |
| B-m SCAN 過濾 UUID | §4.2 | — |
| B-m UD8c 的改法 | UD8c 改成換一個合法的 tar.gz | — |
| B-m P3 §7「偷換 pending 版本」 | 新增黑箱臂 UD20(W + P),不用 G | — |
| B-m p6 的綁定語意 | §5.7:overlay 項綁槽、p5 不綁、只有 tmpfs 類綁 boot_id | — |
| B-m P9 只讀 | §5.7、§9:執行者是 preflight,P9 只讀 | — |
| B-m 主機 EXIT trap 時 lease 已過期 / `ble-recover` | §5.7 | — |
| B-m `phy9h4` 殘留的證據 | 新增 HT23(沒有 `http-nofw` 時 `phy9h4` 讓 `http.2` 消失) | P3 §3.8.1 |
| B-m `s0_assert` 確認 02 拔線 | §3.1 第 6 項 | — |
| B-m VLAN 的 tcpdump filter | §4.5 `vlan and vlan` | — |
| B-m loop 驗收要 root | §8.1 改成非 root 的檢查,mount 的證據改為原始碼加 E-H13 | F-H54 |
| B-m E-H13 的 `shutdown.reason` | §8.1 第 4 步 | — |


## 附錄 F. v6 審查的處理

| 意見 | 處理 |
|---|---|
| A-M1 / B-m3 認目標負對照的佐證(pre-P3 拿不到 helper 計數) | §4.2:改用 blebridge 記的「msg2 之後送出的 frame 數」、`info` 回應的 device_id、兩台 provd 的 adv withdrawn / registered 時間戳;helper 的 ro 計數只留給 SD3,並寫成 P3 的契約 |
| A-M2 舊根沒卸掉 | §8.2:用新根裡的 busybox `umount -l /old` 再 `rmdir /old`;新增「舊根沒卸掉」的負測試,附不卸舊根的對照 |
| A-m1 / B-m1 「host 正常」那一臂的預期 | §5.7 的測試拆成兩臂:lease 一直有效 → dead-man 不動作;lease 中途過期 → dead-man 會跑,但每一項只執行一次 |
| A-m2 / B-m5 UD20 | 正向對照改用新的 nonce;另拆出 UD20b(`E_REJECTED{15}`) |
| A-m3 UD8c 的長度 | 同長度、保留 magic |
| A-m4 / B-m4 fake path 的細節 | 完整的單 frame 訊息、連線後 10 s 內、限流 key 共用;HTTP 改用 tcpdump + counter |
| A-m5 OW3 | 寫明時序與 slot 的安排、`adv registered` 的時限 |
| A-m6 / B-m2 deadman 殺 pgid | 先等 setkey / config-save 結束;殺不掉 → 只做段 1 + NEEDS-PERSON |
| A-m7 沙箱的 fd 0–2 | fd 0 = `/dev/null`,fd 1 / 2 = pipe |
| A-m8 HT23 與 §4.5 的矛盾 | §4.5 寫明 HT23 是例外;拿掉 `status` 回報的斷言 |
| A-m9 / B-m6 / B-m7 檔名、recover、journal 位置、逾時 | §1.2 改成 `prov-undo-lib-254.sh`;recover 掃兩個 journal 目錄;journal 不放在 `$BT/<run>/`;ssh 逾時 = 預算 + 60 s;三種模式都寫 log |
| A-m10 UD8b | FIFO 由 uid 471 建立;「沒卡住」= `update.status` ≤ 5 s + helper pid 不變 |
| B-m8 文字 | netobj 的 `other` 放在 SuppPubInfo、簽者列在 net_config key 8;一律用子 shell 加 `9>&-`;`undo_run` 緊接在 `stop_judges` 之後 |


## 附錄 G. v7 審查的處理

| 意見 | 處理 |
|---|---|
| A-M1 / B-M1 UD8b 到不了 worker | UD8b 拆成 pre(預期 15)與 race(`upd-open-pause` 注入 + `upd-open-block` 當 S);兩個名字加進 §5.1,也就是交給 P3 的接縫清單 |
| A-m1 §5.7 正常情況的正文 | 改成 (i)(ii) 兩種情況,與測試臂一致 |
| A-m2 / B-m2 等 setkey 時 host 沒被凍結 | 先 `SIGSTOP` host 的 shell,等子工具結束,再 `TERM` + `CONT`;host 的 pgid 不登記在 run groups |
| A-m3 pg_kill 失敗沒有測試 | `test-h4-lib.sh` 以 stub 測 |
| A-m4 / B-m8 「不聽」的臂缺 LISTEN 前提 | HT12、HT15、HT23 都加 T 窗 + LISTEN 的 P |
| A-m5 / B-m4 UD20 的資料路徑、副作用、順序 | UD20 列寫明;順序固定;§13 加覆寫 B |
| A-m6 uid 471 的工具 | `start-stop-daemon -c 471:471`(E-H15 驗) |
| A-m7 沙箱 cwd 對照 | 在宿主 cwd 執行 `pivot_root "$R" "$R/old"` |
| A-m8 frame 計數器的負對照 | §4.2 加 selftest 負對照 |
| A-m9 fake path 限流額度 | 沿用 v7 的 ≤ 5 次 / 分、臂期間不產生其他 session-end 行 |
| A-m10 ro 計數契約 | §4.2 定義 `ro_served` |
| A-m11 undo log 不記秘密 | §5.7 |
| B-m1 HTTP fake path 佐證 | 改看 04 主動送出的 FIN + 同一 session 再送 `/msg` |
| B-m3 release 失敗的主流程 | §5.7 第 5 步 |
| B-m5 UD8c 長度 | gzip `FEXTRA` / `FCOMMENT` 補長度 |
| B-m6 mountinfo | 改成白名單 |
| B-m7 背景行程的 `9>&-` | §4.5 |
| A-m12 / B-m9 文字 | 審查報告清單、frame 計數定義在 msg1 之後 |


## 附錄 H. v8 審查的 MINOR(凍結時一併處理)

| 意見 | 處理 |
|---|---|
| A-m1 / B-m8 uid 471 的寫法 | §2:照 `NB()` 用 `-n <唯一名字> -a /bin/sh`,不用 `-x`;斷言 `id -u` = 471 |
| A-m2 / B-m3 UD8b-race 的判定 | 暫停結束後 ≤ 10 s 的 phase 0 + 11、FIFO 已刪、B 不是 BAD、`settings.set` 不是 `E_BUSY`;S = 同一時限後仍是 phase 2 |
| A-m3 fstat 不符的 reason;UD8c 的空間 | §1.4-2 請 P3 寫成 reason 11;UD8c 先刪原檔再寫 |
| A-m4 / B-m4 LISTEN 前提 | HT14、HT18、HT19、HT21 都加 T 窗 + LISTEN |
| A-m5 子 shell 與 STOP | §5.7:每個工具各自在子 shell;`done` 由父 shell 標;STOP 父 shell |
| A-m6 pgid 驗證 | §5.7:整數、> 1、不是自己的群組 |
| A-m7 pg_kill 失敗臂的負對照 | §5.7:stub 回成功但群組還在 → FAIL |
| A-m8 / B-m5 HTTP FIN 佐證 | 持久連線 + 正向對照;第二個 `/msg` 只看 TCP 已關 |
| A-m9 / B-m1 UD20 | 只剩 `args_hash` 一個拒絕條件的 flip;新增 UD20c(`update.check` 換 pending) |
| A-m10 fake path 的額度 | §4.2:先數前 60 s 的 `session` 行 |
| A-m11 / B-m7 `ro_served` | SD3 用它;讀取走 provclient 自己的連線 |
| A-m12 / B-m8 文字 | Go fault 19 個;frame 計數器的負對照改在 peer 端 |
| B-m2 TERM 與 CONT | §5.7:TERM 之後立刻 CONT 再輪詢;等直接子 shell;zombie 視為結束 |
| B-m6 frame 計數器的負對照 | 同 A-m12 |
| B-m8 `upd-open-block` 要點名進 P3 的 security review;UD8c mutant 要先變短 | §1.4-2;UD8c |
| B-m9 背景 setkey 會被 `kill_run_groups` 打斷 | §5.7:單位不以 `bg_start` 起 setkey |
