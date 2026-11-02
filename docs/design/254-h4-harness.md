# Design: #254 PR-H4 — P3 的 harness — **v4(審查中)**

**狀態**:v4,2026-11-02,審查中。

**歷程**:

| 版本 | commit | 審查 A | 審查 B | 備註 |
|---|---|---|---|---|
| v1 | a31489b | REJECT 2 / 8 / 15 | REJECT 2 / 12 / 11 | |
| v2 | d5cf7ed | REJECT 1 / 9 / 22 | REJECT 1 / 10 / 19 | 整份重寫 |
| v3 | 282b48b | REJECT 0 / 4 / 17 | REJECT 1 / 3 / 17 | 兩位都說骨架已收斂、不需要重寫 |
| v4 | (本版) | | | 整份重新寫過,保持一致,結構不變 |

- v3 每條意見的處理見附錄 C。
- 審查報告在 `254-reviews/h4-review-v{1,2,3}-{A,B}.md`。

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
| (待決) | 全套成本(§14);C0 QR 要用的 `segno`(PyPI,要同意下載;不同意就改成本機頁面顯示文字,由使用者手動輸入) | — |
| (沿用) | P3 D1、D2、D11、D20、D21、D22;h23 全部機制 | P3 §1.1、h23 |

**本設計自己決定、審查者可以攻的點**:
- 協定核心放 WSL;
- 接縫負對照都在 committed 槽上以 bind 執行;
- eth 側用 04 本機模擬;
- bench 由 harness 的長期擁有者持有;
- BLE 認目標要經過 Noise static key 認證(§4.2)。

### 1.2 範圍

**本 PR 的檔案**:
- **主機 / 手機工具**:`tests/tools/peer/` 下的 `peer.py`、`blebridge.py`、`httprelay.py`、`netobj.py`(N0 的 net_config / net_secrets 產生器,沿用 `gen.py` 的 `sign1` / `encrypt`,對向量逐位元組 selftest)、`requirements-win.txt`、`sign-test-release.py`、`gen-p3-units.py`、`p3-units.tsv`。
- **主機端腳本**:`scripts/dv/` 下的 `phone-254.sh`、`fresh-254.sh`(chain1 改成 source 它)、`prov-p3-254.sh`(單位驅動)、`http-src-probe-254.sh`、`eeprom-sbx-254.sh`、`data/p3-payloads.sh`。
- **節點端腳本**:
  - `scripts/node/` 下的 `prov-ethsim-254.sh`、`prov-undo-254.sh`、`uci-argv-shim.sh`;
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
| F-H3 | **E-H9(部分)**:bleak 連上 04、02,讀 `STATUS` / `CTRL`;MTU 談到 517;`CTRL` = frame 244、msg 8192;沒有配對提示。這是兩台都是 legacy 時做的 | 2026-11-02 輸出 |
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
| F-H44 | N0 的 net 物件產生器:repo 裡沒有 `provgen.py`;現有的產生器是 `provclient/net.go:185-269`(Go,在節點上)與 `gen.py:302-330`(`sign1` / `encrypt`) | `find`;原始碼 |

### 1.4 回報給 P3(P3 實作的第一個 commit 處理)

1. F-H19 的文字。
2. **§5 的接縫契約**:
   - 名字:Go fault、killpoint、shell fault;
   - shell fault 在所有 image 都有,只認 root 擁有的檔,其他擁有者記 TAMPER;
   - **T 的信任與 `release-min-serial` 都以 build tag 編進 prov_test helper**(RB 是 release image + bind 進去的 helper,所以不能靠 image 上的檔案);
   - provd 的 prov_test 標記;
   - test init 讀 `fault.provd`;
   - helper 的 ro 計數(`info.state` 的一個欄位)。
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

## 3. Bench 基準狀態

### 3.1 S0-pre 與 S0

| 項目 | S0-pre | S0 |
|---|---|---|
| 04、02 | 都是 member,`RadioManaged = true` | 同左 |
| 擁有者 | H0 | H0 + H0b |
| 網路 N0 | 02 + 04;US、ch 40;mesh key 是 `netobj.py` 新產生的測試值 | 同左 |
| 手機 AP | 04 = C0、02 = C0';由 root 執行 P2 的 `halow-setkey --ap`(值在 argv,這是 P2 的界線,C0 是測試值) | 由 key 20 寫入(journal) |
| 手機 | 存了 C0 與 ALT 兩個網路,MAC 用「手機 MAC」 | 同左 |
| 每台記在庫裡的身分 | Noise static 公鑰、deviceID(`info` key 1)、序號末 4 碼 | 同左 |

C0、C0'、ALT 都是 ≥ 20 字元的高熵隨機值。

**S0-pre 的建立步驟**(`prov-bench-s0-254 provision`,每台依序做;寫在 `docs/validation/h4-onsite.md`):

1. 重燒(使用者)。02 暫時接網路線(H4-U7)。
2. ssh `none` 登入(新卡,認領前),放 lab key。讀 `identity/claim.secret`(root,經 ssh 的 stdout 直接進 `peer.py` 的 stdin,不落地、不進 argv),同時讀 static 公鑰與 deviceID,寫進庫。
3. BLE 認領(H0):`peer.py claim`(§4.2 依序列號末 4 碼 + static key 認目標;unclaimed 時有 key 5)。
4. 以 publickey 證明 lab key 登入(沿用 chain1 的 `pk_proof`)。認領後 dropbear 只收 key(F-H37),所以第 2 步一定要先放 key。
5. `network/join`:
   - 04 用 `netobj.py` 產生 N0 的 net_config(owner H0 簽)與加密給 04 的 net_secrets;
   - 02 用同一份 net_config,加上加密給 02 的 net_secrets。
6. 等 `.txn` 消失,再等 openmanetd 那次重開結束(F-H42)。每一步都重讀 IP。
7. root 執行 `halow-setkey --ap`(值從推到 `/tmp/run/batman-dv/c0` 的 root 0600 檔讀出;用完就刪)。
8. 等 02 經 mesh 連得上 → **使用者拔掉 02 的網路線** → `s0_assert` 兩台。

**`s0_assert`**:依 §6.1 判斷 image 版本,選對應的版本。
- **S0-pre 版**:
  1. §4.2 認證過的 BLE 連線;
  2. `STATUS` 的 state = member;
  3. H0 的 `auth/owner` 成功;
  4. root 讀 uci 的 SSID 與 hostapd conf 的 sha,等於庫裡的值(ifname 從 `ubus call network.wireless status` 取);
  5. `BATMAN_VERSION` = 受測 image,而且目前是 committed(**不比槽字母**,因為 T 會換槽)。
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
- **`netobj.py`**:產生 N0 的 net_config(COSE,owner 簽)與 net_secrets(加密給指定節點的 static key),對 `vectors.json` 逐位元組 selftest。
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

**認目標**(在 WSL 的 peer 核心,v3-B B1):
1. `SCAN` → 依 RSSI 由強到弱逐一 `CONNECT`。
2. 讀 `STATUS`:unclaimed / legacy 時有 key 5,不符就立刻 `CLOSE`(只是加速)。
3. **認證**:做一次 Noise NX 交握的前兩則,取得節點的 static 公鑰,與庫裡目標的值比對;不符就 `CLOSE`。認證通過後,同一條連線再從頭做這一臂要用的交握(NX 匿名 / PSK)。
4. 全部候選都不符 → INVALID。

**負對照**(`peer.py identify` 的 selftest,以及一次實機臂):在 S0-pre 上要連 04,但把庫裡 04 的 static key 換成 02 的 → 必須 INVALID(或連到 02 被認出不是 04 後放掉),**絕不能**對 02 繼續送任何臂的請求。

**其他規則**:
- 連到不是目標的那台會讓它短暫撤廣播。主機鎖底下沒有其他單位在用,列進副作用。
- **04 的廣播在不在**一律在 04 端判:provd log 的 `withdrawn` / `registered` 行,以及 root `bluetoothctl show` 的 advertising instances 數。
- key 20 臂的 Closed = outcome unknown → 認證後重連,讀 `settings.get` 判定。
- **selftest**:假後端,驗證行協定、frame 計算、EOF 退出,以及認目標在「key 不符」時一律放掉。

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

- **範圍**:chain1 的步驟 1–6 與 9。`image` 參數可以是受測 rc,也可以是 wsl.22。restore 之後 B = A 的版本(brewrite),A 做 overlay-restore + compare。新卡由臨時擁有者 HF 認領,序號末 4 碼與 static key 都從節點讀。
- **期限檔** p6 `fresh-deadline`(tmp + rename;寫者 = 主機續期、B 上的迴圈;同一行由迴圈改寫時保留 run):
  - 內容:`<run> <boot_id> <剩餘預算秒> <last_seen_uptime>`。
  - B 上的迴圈每 60 s:
    - run 不符 → 不動作;
    - 同一次開機 → 扣掉經過的時間、更新 `last_seen`;
    - boot_id 變了 → 剩餘預算 = 舊的剩餘 − 0(重開期間不計)+ 5 分,而且**只能延長一次**(檔案記錄延長次數 ≥ 1 → 不再加);
    - 剩餘 ≤ 0 → 執行 `ch1-deadman.sh`。
  - 主機續期時才把預算補回 30 分。
  - 重開迴圈中只要主機不續期,預算一定會耗盡(v3-A m6、v3-B m11)。
- 每次 B 開機後,主機先斷言 rc.local 那一行與迴圈都在。
- **LR1 排在 F 的最後**:firstboot 回來後重種 dead-man 並斷言,然後 restore_all。
- **lease dead-man 與新卡 dead-man 的先後**:dirty flag 指向這個 F run 時,lease dead-man 只做 undo 執行器的段 1(§5.7),不啟動服務。
- **新卡 root 的 `none` 登入**:列進副作用。
- **主機死後回來**:下一個 run 的 preflight 看到 `ch1.fired` 或期限已觸發 → 自動跑 overlay-restore + compare + brewrite(遠端可做)→ 再 `s0_assert`。
- **回歸**:
  - chain1 在 wsl.22 上 59 / 0;
  - dead-man:不續期 → 觸發;有續期 → 不觸發;
  - B 上連續 sysrq 重開、不續期 → 預算內觸發。

### 4.5 eth 側模擬:`prov-ethsim-254.sh`(04,lease 底下)

**建立**:
1. netns `h4x`;
2. veth `h4v0`(接進 `br-ahwlan`)↔ `h4v1`(放進 netns,IP 用 `10.41.250.<n>/16`);
3. netns 內 `tcp_syn_retries=1`。

**目標一律是 04 的 `br-ahwlan IP:8095`**,包括 lo 臂。provd 只 bind 這個位址,連 127.0.0.1 不管有沒有規則都是 RST,所以那一條只看 counter、不當斷言。

**連線端**:`wget -T 2`(uclient-fetch),背景執行。並發上限在 E-H15 先量 RSS 再定(目標 ≥ 120),**速率依 P3 §8 是 50 conn/s**;並發上限可以撐到 50/s 才算達標,否則把實際速率列為誠實界線並回報使用者。每秒斷言行程數 ≤ 上限。

**判定**(在 04 端):named counter 的增量 ≥ 送出的 SYN 數 × 0.9,**而且** `tcpdump -i br-ahwlan` 沒有 SYN-ACK、沒有 RST。

**各臂**:

| 臂 | 做法 |
|---|---|
| mesh / eth 洪流(HT8b) | 50 conn/s × 10 分 |
| 偽造手機 MAC + IP + ARP(HT8a) | `h4v1` 用手機的 MAC 與 IP,以這個 IP 送出 ARP。手機會斷線,所以與手機臂不重疊;結束後刪掉、手機 ping、跑 `phone_preflight` |
| VLAN(D-1) | 在 `q0`(802.1ad 0)上疊 `q0.0`(802.1q 0),加靜態 neighbor;判定只在 04 端 |
| docker0 | 第二組 veth 接進 docker0;netns 的 IP 是 `172.17.250.<n>/16`;**目標仍是 04 的 br-ahwlan IP**(經 docker0 路由進 input,zone 是 ACCEPT)。同路徑正向:netns → `<br-ahwlan IP>:80` = 200。VLAN 雙層也從這一組送。docker0 會變 UP(副作用) |
| UP3 的第二來源 | `phy9h4` veth(名字以 `phy` 開頭,會被 bridge 規則打 bit)。**只准在 `http-nofw` 時存在**;殘留的話,helper 的前提檢查不給 `http.2`(fail-closed) |

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
- ⚠️ **E-H12**:不成立時退回 `upper-provd`。

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
- **假 `nft`**:只在 RD 的 PATH 裡。
- **autocommit 變體**(h23 §17 的規則):`ac-noprov`、`ac-provd-required`、`ac-helperoff-err`、`ac-nofw4`。

### 5.6 `provd-stable`(RD)

1. 刪掉 `$RUNDIR/provd-stable`。lease 底下是例外的寫者(§9)。
2. `push-helper`(帶或不帶 fault)→ restart provd → 等 70 s。
3. 執行 dry-run。
4. 還原:helper 正常重啟後會重寫;斷言內容是本次的 boot_id。

### 5.7 undo 執行器 `prov-undo-254.sh`(v3-B M3、v3-A m3 / m4 / m5)

**同一個執行器**:EXIT trap 與 dead-man 都只呼叫 `prov-undo-254.sh run <run>`。它的做法:
- 在節點上以 `setsid` 執行;
- 先 `renew` lease 一個足夠的預算(20 分鐘),全程持有 lease 鎖;
- 重入時,跳過已標 `done` 的項目;
- 主機的 EXIT trap 只負責啟動它、等結果。

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
- `ap-restore`:經 `halow-setkey` 寫回 C0 的 SSID + passphrase,並斷言 hostapd 回到 S0;S0-pre 不會跑 key 20 臂
- `pending-del`
- `p5-save`:執行 `batman-config-save --save`,再用 `--check` 斷言 fresh
- `rm-file <path>`:例如 dev-open 旗標、`/tmp/run/batman-dv/c0`

**撐過重開**:會撐過重開的動作(`uci commit`、`disable`、`auto_includes`、p5 的修改)**先在 p6 `dv-undo.<run>`(root 0600)登記,才去改**。開機後,P9 與下一個 run 的 preflight 依它執行段 2。§11 的測法:臂進行中 sysrq → 重開後殘留項被列出並還原。

**`restoring` 標記存在時**:只做段 1;段 2 交給 pr_restore(它會重開並還原 p5)。

**HT14 的保險**:
- 停防火牆之前先起 `setsid sh -c 'sleep 60; nft list table inet fw4 >/dev/null 2>&1 || { firewall start; /etc/init.d/dockerd restart; }'`,並把 pgid 登記成 `kill-pg`;
- 臂自己的 `fw-start` 執行前,先殺掉這個保險;
- 保險動作之前,如果 `inet fw4` 已經在,就跳過。

**lease 契約的改寫**:dead-man 不直接寫 slot 或 p5;經 setkey `--save`、`batman-config-save --save` 的寫入,屬於那兩個工具自己的職責。每一類動作都有一個 dead-man 臂(`test-h4-undo.sh`):不續 lease → 等 dead-man → 斷言已還原。

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
- **壞 rootfs 的離線驗收**(WSL loop 檔,現場之前做):
  - 前 4 bytes 仍是 `hsqs`;
  - `unsquashfs -s` 失敗;
  - `mount -t squashfs` 失敗;
  - offset 1080 不是 ext4 magic,`mount -t ext4` 也失敗。
- **機制**:kernel 正常 → 掛不上 root → panic → `panic=10` → tryboot 是一次性的 → 回預設槽。這與 F-H16 既有的 invalidate 機制是同一條回程。
- **E-H13 的前置**(lease 底下,現場之前):在 04 上真的跑 `batman-slot apply`,證明壞 payload 會被收下,但**不重開**;然後 `invalidate` B,並斷言 `BATMAN-BAD` 存在。
- **E-H13**(現場):apply → 重開 → 觀察 panic 行、ext4 的嘗試、回到 A 的時間。結束後 **brewrite B**,斷言 B = V、沒有 `BATMAN-BAD`,再 `s0_assert`。否則之後任何 rollback 都會讓 04 陷入 panic 迴圈(v3-B M1)。

### 8.2 `prov-eeprom-hooks-254`(D11;C 載具;H4-U12)

**沙箱**(`eeprom-sbx-254.sh`):
- WSL 的一般使用者執行 `unshare --user --map-root-user --mount --pid --fork --net --uts --ipc`,在裡面 chroot;qemu-aarch64 依 binfmt 的 `F` 旗標執行(F-H31)。
- 沒有真 root,也不用 `dv-sbx.sh`(F-H22)。

**逃脫負測試**(每次執行都先跑,任一沒有失敗 → 整個單位 FAIL):
- 沙箱內 `reboot -f` → WSL 的 boot_id 不變;
- `mount /dev/sd*` 失敗;
- 寫 `/proc/sys/kernel/hostname` 失敗;
- 對宿主的檔案 `mknod` 失敗。

**底**:wsl.22 的 rootfs(sha 釘死)。

**各臂**:
- **EE1**:PATH 最前面放假 `vcgencmd`,回四個 key → 依序執行 `/etc/uci-defaults/*` → 斷言:`authorized_keys` 不含植入的 key;root 密碼的 hash 不變;AP `disabled`;country 沒被鎖。
- **EE2**(D11 的 fresh-overlay 與 stage1 `:487`):shim 對所有 key 的 `READ` 都回 rc 1。
- **負對照(W)**:`1.5.12-wsl.2+f2f2bf6.fw9d87d02`(沒有 shim,F-H39;sha 釘死)→ 四個 key 全部被採用;另加 P:斷言負對照的 rootfs 裡沒有 shim 版的 `persistent_vars_storage.sh`。

### 8.3 `prov-fw-boot-254` 與 `fw-badinclude`

- **常規**:每次開機後斷言三張表都在,做成單位框架的掛鉤。負對照(W):wsl.22 沒有這些表。
- **rc 閘門**:bench 上執行 `fw4 print | nft -c -f -`。
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
| undo journal(tmpfs 與 p6) | 單位登記;只有 `prov-undo-254.sh run` 執行(持有 lease 鎖) | P9 |
| HT14 保險行程 | HT14;由 `kill-pg` 收掉 | — |
| `/tmp/run/batman-dv/c0` | provision 步驟 7;用完 `rm-file` | — |
| bench 金鑰庫 / journal | `peer.py s0`;`run/` 範圍歸該 run | 單位 |
| `fresh-deadline` | 主機(續期)與 B 上的迴圈(扣時間);都用 tmp + rename;主機的續期優先(迴圈讀到 run 與 boot_id 相同時,只扣時間、不改預算上限) | — |
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
| `fresh-deadline` | 主機 / 迴圈 → 迴圈 | §4.4 | run 不符 → 不動;壞檔 → 觸發(fail-secure) | root |
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
- **blebridge**:看得到密文與公開的 `STATUS`;bleak 依 hash 釘選;認目標以 static key 認證,所以被竄改的橋沒辦法讓 peer 把擁有者的請求送到錯的節點。
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
| prov-update | 多次重開、A / B 重寫;壞 rootfs 一次 panic | 回到 S0 的版本、committed;brewrite;`s0_assert` |
| E-H13 | B 是壞 rootfs | brewrite B(§8.1) |
| prov-upload | 126 MB × 每個接縫一次 | tmpfs 用量回到 0 |
| AC | 刪 `provd-stable`;`disable` | 重寫;`svc-enable`(p6) |
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
   - E-H9 剩下的部分:legacy 狀態下對 04 開 NX session,做 static key 認證、notify、9 KiB、230 s。
3. **改節點,lease 底下立刻還原**(先給使用者步驟):
   - E-H12;
   - E-H15;
   - `test-h4-undo.sh`;
   - E-H13 的前置(apply、不重開、invalidate)。
4. `fresh-254.sh` + chain1 在 wsl.22 回歸;接著在 F 上**預演 S0-pre**(含 member 狀態下認目標)。
5. 各單位依 §16 的做法寫。
6. **現場**(H4-U7,步驟在 `h4-onsite.md`)。
7. `--pre-p3-full`。
8. harness PR(S 標 ❌、列為 P3 的閘門)→ 使用者 merge → P3 實作。

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
| E-H9 | 連線、STATUS / CTRL、MTU | ✅ 部分(legacy);static key 認證、notify、9 KiB、230 s ❌(§15-2) |
| E-H10 | 手機在 C0 ↔ ALT 之間切換 | ❌ 現場 |
| E-H12 | `push-provd` 在 ujail 下 | ❌ §15-3 |
| E-H13 | 壞 rootfs → panic → 回到原槽 | ❌ 前置 §15-3、本體在現場 |
| E-H15 | ethsim(mesh、前提檢查、還原、uclient 結束碼、RSS) | ❌ §15-3 |
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
| OW3 | remove 切 BLE + HTTP | remove | RB(T 窗) | 兩條 ≤ 5 s Closed;provd log 的 session 數 = 0;重新交握被拒;`adv_owner_key` 輪替 | W + P |
| OW4 | 最後一位 | last | R(快照,`run/`) | Hx、H0b 先移除成功;再移除 H0 → `EForbidden "cannot remove the last owner"`;快照還原;`s0_assert` | W |
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
| ST9 | passphrase 不外洩 | secret | RB(`uci-argv` + cmdline 每 10 ms 取樣) | 節點上的計數 = 0;WSL 原值 grep = 0 | S(bind 一個走 `uci set` 的 setkey 變體) |
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
| SD3 | ro 10/s × 10 分 | ro-load | RB(T 窗) | 沒有 `cfgsave-lock.busy`;沒有 ERate;04 端廣播在 | S(`ro-on-ctl`)+ P(ok + E_RATE ≥ 5400,ok ≥ 2500) |
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
| HT8b | 洪流 50/s × 10 分 + 擁有者傳完 + 廣播在 | mesh-b | RB + ethsim + 手機 | 同上 + 上傳完成 + 04 端廣播在 | 同上 |
| HT9 | lo(目標是 br-ahwlan IP) | lo | RB | drop 增加 | S(同上)+ P |
| HT10 | VLAN 雙層 | vlan | RB + ethsim | 沒有 SYN-ACK、drop 增加 | S(兩邊 `http-nofw`;v6 規則 → 有 SYN-ACK) |
| HT11 | docker0 + VLAN | docker | RB + ethsim | 同上 | S(同上) |
| HT12 | 刪表 → ≤ 8 s 不聽 | deltable | RB | `netstat` 沒有 8095 | S(`http-nofw`) |
| HT13 | reload → 兩張表、各一份 | reload | R | | W(表不在) |
| HT14 | `firewall stop` | fwstop | RB(H4-U11) | ≤ 8 s 不聽 | S(`http-nofw`) |
| HT15 | helper 停 | helper-stop | RB | ≤ 8 s 不聽 | P |
| HT16 | provd crash | provd-kill | RB | 斷線;tmpfs = 0 | P |
| HT16b | provd 正常停止 | provd-stop | RB | 同上 | P |
| HT16c | provd 每 5 s 重生的迴圈 | provd-loop | RB(`crash-on-start`) | 迴圈期間不聽、helper 正常、上傳檔被刪 | P |
| HT17 | hostapd / `wifi reload` | wifi-reload | RB | 手機重連後連得上 | P |
| HT18 | `auto_includes = 0` | autoinc | RB | 不給 `http.2` | S(`http-nofw`) |
| HT19 | D-3 | bit24 | RB | 不聽;`status` 回報 | S(`http-nofw`) |
| HT20 | D-8 | d8 | RB + ethsim | 仍被丟 | S(兩邊 `http-nofw`,不清 bit 的規則 → 放行) |
| HT21 | D-13 | d13 | RB | `http.2` 消失;`status` 回報 | S(`http-nofw`) |
| HT22 | §6 依賴重啟 dbus | dbus | R | BLE 回來 ≤ 15 s;沒有因此開啟 HTTP 備援 | P |

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
| UD-T1 | release 拒收 T | t-reject | R | `{1: false, 2: 11}` | S(同一份 manifest 在 RB 上會過) |
| UD1 | T → trial → commit → 5 | main | RB → T | 2 → 3 → 4 → 5 | W |
| UD2 | 同版本退回 → 6 | same | RB → T | hold → 到期 revert → 6 | W + P |
| UD3 | arm 前斷電 → 0 | kp-before | RB(`upd-before-arm`) | 0;沒有旗標 | S(`upd-after-arm` → 進試用;副作用見 §13) |
| UD3b | arm 後 helper crash → disarm、3 | arm-crash | RB(`helper-arm-crash`) | 重啟後旗標被清、3 | S(`no-boot-disarm` → 旗標留著)+ P |
| UD4 | 新版沒開機成功 → 6 + 18(P3 寫 kernel 壞掉,H4 改成 rootfs superblock 壞掉,§1.4-7) | badroot | RB → T | panic → 回原槽;6 + 18 | W(E_U `update/check`)+ P(panic 行) |
| UD5 | 舊的 bad-slot 不造成假 6 | oldbad | RB | 5 | W + P |
| UD6 | worker 失敗的 reason | worker | RB | 1 / 11 / 12 / 17 | W + P |
| UD7 | 七種拒絕 | reject | RB | reason 逐一相等(min-serial 編在 helper 裡) | W |
| UD8 | 惡意 | malicious | RB | 11;槽 BAD、不 arm | W |
| UD9 | prepare 中 kill / 斷電 | kill | RB(`upd-write-mid`) | 槽 BAD、仍在舊槽 | P |
| UD10 | helper 重啟 → phase 3 | rebuild | RB | 3 | W + P |
| UD10b | 重開 → pending 不在 | reboot | RB | 不在 | P |
| UD11 | 降級到 wsl.22 | downgrade | R → ssh sysupgrade | 四件事 + S0-pre 的 `s0_assert` | P |
| UD12 | 未入網升級 → fresh | upgrade-unjoined | F(wsl.22)→ sysupgrade | fresh | G(H4-U8) |
| UD12b | 已入網升級 → tick 存檔 | upgrade-joined | R(wsl.22)→ sysupgrade | fresh | P |
| UD13 | SSID 含 `'` | quote-ssid | RB | 通過 | W + P |
| UD14 | 沒列名的 dtb | sysupgrade | R | 沒有那個 dtb | S(`slot-copy-all`) |
| UD15 | YubiKey | bench | R | — | NEEDS-PERSON |
| UD16 | D-9 試用轉 committed | d9 | T | commit 後 fresh | G(H4-U8) |
| UD16b | 非試用開機時存一次 | d9-boot | RB | stale(P)→ restart → 存 | S(`p5-autosave-off`) |
| UD17 | D-10 | d10 | RB | (a) 6 不帶 18;(b) 旗標不在 | S(`d10-no-disarm`) |
| UD18 | D-14 | — | C | `.busy` 不在 | S(沒有 trap 的變體) |
| UD19 | D-12 | d12 | RB(`setkey-pause`;provclient 直接打 helper) | ≤ 5 s 回應 | S(`d12-take-mu`) |

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
| FB1 | 三張表 | fw-boot | R(每次開機後) | | W |
| FB2 | `nft -c` | fw-boot | bench | rc 0 | S(壞 include → rc ≠ 0) |
| FB3 | `fw-badinclude` | fw-badinclude | W(02) | §8.3 | P |
| EE1 | D11 採用 | eeprom | C | §8.2 | W(1.5.12-wsl.2)+ P(沒有 shim) |
| EE2 | D11 fresh-overlay / READ rc 1 | eeprom | C | rc 1 | W(1.5.12-wsl.2 → rc 0) |
| PR1 | D-1 / D-2 | 探針 | 04 | §7 | v6 規則 |
| SEC1 | §7 非 root 的 fault 檔 | prov-sec 補 | R | setkey 照常還原;TAMPER | P |

**D 項對照**:
- D-1 → HT10、PR1;D-2 → PR1;D-3 → HT19 + lint;D-4 → HT8a / b;D-5 → ST19;D-6 → ST7;
- D-7 → ST20;D-8 → HT20;D-9 → UD16 / UD16b;D-10 → UD17;D-11 → ST9;D-12 → UD19 + ST13 + ST20;
- D-13 → HT21;D-14 → UD18;D-15 → UP10;D-16 → AC7;D-17 → AC8。

## 附錄 B. v1、v2 的處理

- v1 的處理見 d5cf7ed 的附錄 B;
- v2 的處理見 282b48b 的附錄 C。
- v4 沿用;改動見附錄 C。

## 附錄 C. v3 審查的處理

| 意見 | 處理 |
|---|---|
| B-B1 member 認不出目標 | §4.2 用 static key 認證 + 負對照;§3.1 庫裡記每台的身分;預演 |
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
