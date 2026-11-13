# #254 PR-P3 設計 v6(c252b3f)— 審查 A

**判定:APPROVE-WITH-CHANGES。** 0 BLOCKER、1 MAJOR、9 MINOR。v5 的三個 MAJOR(nft 萬用字元、fw4 單一交易、ujail pid namespace)經我自行查證已修好。剩下的一個 MAJOR 屬同一類:L2 規則依賴「其他程式怎麼運作」的假設,但沒有證據。修法很小,可在凍結前補進文字,並在 §9-4 的探針裡驗。MINOR 都可以在實作 PR 附測試修掉。

方法:整份讀過 v6;對照原始碼(Batman-p3、firmware-2710 build_dir 的 kernel 6.6.138 / nftables 1.1.1)與 04(`1.5.14-wsl.22`)的唯讀指令。04 上沒有任何寫入。

## 已核實 ✅(附證據)

- **F11 / §3.7.6 provd 身分**:04 上 `/proc/8388`:Name batman-provd、PPid 1、uid 0、exe `/sbin/ujail`,cmdline `ujail ... -- /usr/bin/batman-provd`;`/proc/8414`:PPid 8388、uid 471、`NSpid: 8414 1`、exe `/usr/bin/batman-provd`。`ubus call service list` 的 instance pid = 8388。init 有 `requirejail`(不會有沒 jail 的執行)。PPid + uid + exe 的規則成立。
- **F69**:nftables-1.1.1 `src/evaluate.c` `expr_evaluate_string`:只認結尾的 `*`。
- **F70 / F59**:04 `/sbin/fw4` start = `utpl | nft -f`(單一交易);`stop` 只刪 `inet fw4`;`flush` 刪全部表;`/etc/init.d/firewall`:`restart` = `fw4 restart`、`stop_service` = `fw4 flush`、`reload` = `fw4 reload`。`/usr/share/nftables.d/README` 與 `fw4.uc:818-821`:`ruleset-post/*.nft` 自動 include,放在 `table inet fw4 {}` 之後;`auto_includes=0` 可關掉(→ 表不在 → helper 不給 `http.2`,fail-closed,與設計一致)。04 上目前沒有 `ruleset-post/` 目錄(套件會建立)。
- **F60**:兩板的 `nft_chain_filter.o` 都含 `nft_do_chain_bridge`(grep -a 得 2 筆);`.config` 有 `NF_TABLES_BRIDGE=m`,原始碼在 `#if IS_ENABLED(CONFIG_NF_TABLES_BRIDGE)`(`nft_chain_filter.c:229`)之內。bridge LOCAL_IN 的 `indev` = 埠(`br_input.c:br_pass_frame_up`:`indev = skb->dev` → `NF_HOOK(..., indev, ...)`)→ `iifname` 是埠名,成立。
- **F9 / F52**:04 `bridge link`:br-ahwlan 的埠 = eth0、phy1-ap0、bat0;br-ots 的埠 = 5 個 veth;wlh0 不是 bridge 埠。`network.wireless status` 有 radio0 `interfaces[].ifname/section/config.mode/ssid`(helper 前提檢查要用的欄位都在)。
- **wlh0 直接進來的 IPv4**:fw4 `input` 沒有 wlh0 的 zone → `handle_reject`(defaults input REJECT)。不是旁路。
- **`nft -j`** 在 04 可用(JSON 版 nftables 1.1.1)。
- **`/tmp/.uci/*`**:04 上有 0 位元組的 delta 檔 →「非空」判斷是對的。
- **F64**:`batman-slot cmd_reboot`:tryboot 旗標 ≠ 0 → 一般重開。
- **讀取用的 helper 動詞不拿 `n.mu`**(`readonly.go:3-8,19`):poll 不會被 `settings.set` 卡住。
- **96 `valid_batch`**(`96-batman-config-migrate:33-46`)接受 wireless 的 `set` 行 → 降級後舊版仍套用 p5 的 ssid,成立。
- **D20 / F74 主邏輯**:`node.go:539` 從 unclaimed 認領時 `RadioManaged = true`;keyguard 對 placeholder mesh key 封鎖 radio1、對 placeholder AP key 封鎖該 AP(`halow-keyguard`);setkey 的解除是逐項的(只解除 key 已非 placeholder 的那一項)。

## MAJOR

### M1. 「只收手機 AP 埠」的 L2 規則,用的是 `tcp dport` 比對,而 bridge hook 是用外層 ethertype 決定能不能看到 L4;沒有證據(也沒有負測試)證明每一種會被本機 IP 堆疊收下的 frame,都會在這個 hook 被認成 IPv4/IPv6
- **情境**:D15 和 §7 第 1 列說,8095 只有這台的手機 AP 埠進得來;eth0、bat0、docker0 的 veth 都在 L2 被丟。規則是 `tcp dport 8095 iifname != "phy*" drop`。
- **證據**:`nft_chain_filter.c:239-248`:`nft_do_chain_bridge` 依 `eth_hdr(skb)->h_proto` 設 L3/L4 資訊;不是 IP / IPv6 時是 `nft_set_pktinfo_unspec` → `tcp dport` 不會成立 → 規則不會 drop。核心收包路徑(`net/core/dev.c:5528-5642`,VLAN 標籤處理)在 bridge 把 frame 往上交之後,還可能再剝一層 VLAN 封裝,再當 IPv4 交給本機。所以「bridge hook 看不到 L4」和「本機 IP 層會收下」不一定一致。這是從原始碼推論的(⚠️ 未實測;依規定不在 04 實驗)。eth0 埠與 docker0 的 veth 埠(容器預設有 raw socket 權限;docker zone 是 input ACCEPT)都適用;bat0 那條還要看 batman-adv 怎麼轉發帶標籤的 frame(未驗)。
- **影響**:D15 的保證沒有做到:非 AP 來源可以佔掉 HTTP 的 2 槽和每分鐘 10 次交握。上傳窗或 BLE 備援期間,擁有者就連不進來(可用性)。Noise 仍保護內容,所以不是取得控制權。v6 要求每一句外部行為假設都附證據,這一句沒有。
- **修法(擇一,建議第一個)**:
  1. **正向標記、fail-closed**:bridge 鏈對 `iifname "phy*"` 的 frame 設一個專用的 `meta mark` 位元,不帶任何 L3 條件;再加一個獨立的 `inet` 表(input hook):`tcp dport 8095` 而沒有那個位元 → drop。這樣凡是沒有從 AP 埠經過 bridge hook 的(VLAN 封裝、docker、lo、將來任何路由介面),在 L3 一律被擋,§7 的「lo 本機 DoS」誠實界線也可以拿掉。實作時要確認 fw4 / docker 不用這個 mark 位元。helper 的檢查同時涵蓋兩張表。
  2. 最少:在同一條 bridge 鏈對非 `phy*` 埠的 VLAN 類 ethertype 一律 drop(ahwlan 沒有用 VLAN,實作前要確認)。
- **測試**:`prov-http-254` mesh / eth0 臂加帶 VLAN 封裝的 SYN(單層與雙層),從 eth0 與 docker0 容器各送一次,斷言連不上。負對照 = v6 原規則(預期連得上)。§9-4 的功能探針要在凍結 H4 之前跑,並包含這些情況。

## MINOR

1. **helper 在 setkey 執行中重啟:「子程序自己跑完並 `--rollback`」沒有證據,原始碼也不支持。** `provstore.Exec` 用 `bytes.Buffer` 當 stdout/stderr(`exec.go`),所以是 pipe;helper 的 `SigIgn` 是 0(04 `/proc/<helper>/status`);setkey 沒有 `trap`。helper 掛掉後,setkey 下一次寫 stdout(例如 `echo "applied on:"`)就會被 SIGPIPE 結束:已 commit、已 reload,但沒有讀回、persist,也沒有還原。修法:setkey 開頭 `trap '' PIPE`,或 helper 讓子程序寫到自己 0700 RunDir 裡的檔案。§6 那一列的測試(`prov-settings-254`)要真的在 setkey commit 之後殺 helper,斷言結果是還原或已 persist 二者之一。
2. **上傳 tmpfs:「helper 刪檔 → 被入侵的 provd 在窗外最多佔一個 poll 週期」不成立。** unlink 不會釋放還開著的 fd;tmpfs 用量會一直算到 provd 關檔。上限一直都是 `size=`,不只在窗內。修法:改寫 §3.8.2 / §7;測試改量 `statfs` 用量,不是看檔案在不在;可以加:窗外刪檔後用量仍 > 0 → helper 重啟 provd。
3. **phase 3 是從 `BATMAN-VERIFIED` = pending sha 重建的。** P3 之前的 `batman-slot`(降級後的槽)寫入目標槽時不會刪舊的 VERIFIED,所以舊檔可能讓 `update.apply` arm 到不是擁有者同意的內容(只在操作員走過未簽章路徑時發生)。修法:VERIFIED 內容 = `<sha> <boot_id>`,phase 3 和 `arm` 都要求 boot_id = 本次開機。
4. **文件不一致**:§4 清理表寫「update-last 下一次 check 通過時覆寫」,§3.7.4 寫「只有 apply 寫」;§5.3 update-last 的格式少了 `bad_slot_at_apply`、`rebooting`;§3.7.3 寫 `arm <sha>`,§3.7.4 寫 `arm <sha> <清單檔>`;§9 的編號順序 7 / 9 / 8。
5. **`bad-slot` 的內容是 `slot=X version=V`**(`batman-autocommit:195,244`)。重裝同一版本又失敗時,值與 `bad_slot_at_apply` 相同 → 會報成 6 + 18,而不是 6。arm 之後、寫 `rebooting` 之前若有熱重開,tryboot 旗標還在,但 `rebooting` 是 false → 新版沒開機成功時會報成 0。建議 update-last 記 autocommit 的 `aclog` 行號,或比對 TRIAL-REVERTED 的 boot id。
6. **F74 的證據括號寫錯**:「入網才設 `RadioManaged = true`」— `node.go:539` 從 unclaimed 認領時就是 true。結論不變,改括號即可。
7. **`/tmp/.uci/wireless` 非空 → `E_BUSY`**:操作員 `uci set` 後忘了 commit 會造成永久 busy,app 沒有出路。建議另給一個 reason,並在 `status` 回報。
8. **§3.8.1「不用 br_netfilter」的前提已經過時**:04 上 `br_netfilter` 已載入、`bridge-nf-call-iptables=1`(docker 載入的)。不影響本設計,但文字要改正。§8 的 `fw-badinclude` 會讓 bench 節點在那次開機沒有防火牆,要列進破壞性測試的副作用與還原。
9. **§9-3(morse 換表)**:不成立時的出路「寫入 + 要求重開」還沒有線上形狀(CDDL / reason)。H4 是先照本文件寫的(D1),所以要先定形狀,或在 H4 凍結前先跑 §9-3。另外 §3.7.1 用 `.wbox-` 當「版本解析失敗」的例子,但 wbox 字尾在 `+` 之後(`check-prov-test-gate.sh:119`),規則會忽略它,所以例子錯了(行為無害:wbox 試用永遠不會 commit,`batman-autocommit` 的 WBOX_STATE 邏輯)。

## §9 延後項

- 1、2、6、7、8、9:接受。
- 3:接受,附 MINOR 9 的條件。
- 4:**只有在凍結 H4 之前跑、並且包含 M1 的情況時才接受**。

## 收斂

除了 M1,v6 已收斂;附錄 B 對 v5 的各項處理我抽查都成立。M1 的修法是局部的(一個 mark + 一條 inet 規則 + 一個測試臂)。補上後不需要整份重審,MINOR 進實作 PR 附測試即可。
