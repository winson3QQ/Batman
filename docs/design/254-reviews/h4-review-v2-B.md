# H4 設計 v2 審查 — 審查者 B(第 2 輪)

**審查對象**:`docs/design/254-h4-harness.md` v2(`harness/254-h4` @ d5cf7ed),整份重讀,不只看增量。
**上層**:P3 `254-p3-impl.md` v7.1(`feat/254-p3` @ dfedd03)§2、§3、§5、§6、§7、§8、附錄 D;先例 h23 v14;main 2ecf1cb。
**方法**:
- 先從實際使用情境找缺的生命週期路徑與資源:使用者遠端、S20 常駐、桌機 Git Bash + WSL + Windows bleak、D20 之後由 H0 建 S0。
- 再逐一查證假設:讀原始碼(`file:line`),在 04 上跑唯讀指令(`cat`、`ls`、`ubus call … get_clients`、`nft list chain`、`uci show firewall`、`ip -br link`、`netstat`、`command -v`),在 WSL 與 Windows 上跑唯讀檢查。
- 沒有改任何節點狀態,沒有連 BLE,只寫了這份報告。

**結論**:**REJECT**,共 1 BLOCKER / 10 MAJOR / 19 MINOR。架構(載具、S0、WSL 核心 + 薄橋、手機 relay、可續期的 dead-man、接縫契約、逐列對表)方向正確,v1 的兩個 BLOCKER 大致已解。但有一個新的順序矛盾會讓 H4 PR 本身的驗證計畫跑不出來,另有多個臂的負對照會空著通過,或在真機上做不出來。

---

## 0. 我自己取得的證據(原始輸出節錄)

**E1:`owner/add`、`settings/set` 在 wsl.22 是 `p3Types`,回 `E_UNSUPPORTED`**(`feed/batman-prov/src/provd/session.go:68-70`、`:623-625`)
```
var p3Types = map[string]bool{"owner/add": true, "owner/remove": true, "settings/get": true, "settings/set": true,
	"status": true, "peers/challenge": true, ... "bulk/open": true, "bulk/close": true}
...
	if p3Types[typ] {
		return errEnv(id, EUnsupported, cbor.M(1, typ))
```

**E2:04 的工具(唯讀,`1.5.14-wsl.22+2ecf1cb.fwce20a68`)**
```
$ nc --help
BusyBox v1.36.1 ... Usage: nc [IPADDR PORT]        ← 精簡版:沒有 -l / -k / -p / -w
timeout=  telnet=  arping=  ss=  unshare=  nsenter=  curl=   (都沒有)
nc=/usr/bin/nc  flock=/usr/bin/flock  netstat=/bin/netstat  setsid=/usr/bin/setsid
tcpdump=/usr/bin/tcpdump  wget=/usr/bin/wget  uclient-fetch=/bin/uclient-fetch  /usr/sbin/uhttpd
/usr/sbin 的 hostapd 相關:hostapd  hostapd_cli_s1g  hostapd_s1g      ← 沒有 hostapd_cli
ubus call hostapd.phy1-ap0 get_clients → {"freq": 5180, "clients": {}}   (可用)
/proc/sys/net/ipv4/tcp_syn_retries = 6
```

**E3:docker 的兩座 bridge 與 fw4 input**
```
docker0  DOWN  <NO-CARRIER,...>          ← 沒有容器
br-ots   UP    (5 條 veth = OTS 的容器)
chain input: iifname "docker0" jump input_docker ; iifname "br-ots" jump input_dockert
chain input_dockert { jump drop_from_dockert }
chain input_docker  { jump accept_from_docker }
firewall.ots_zone.name='dockert'  device='br-ots'  input='DROP'
```

**E4:`upper-helper` 寫的是目前槽的 overlay upper**(`scripts/node/prov-wbox-254.sh:11-12`)
```
#   upper-helper <file> <sha>       copy W/<file> to /usr/bin/batman-provhelper (lands in the overlay upper, survives a
#                                   reboot; overlay-restore / the deadman remove it).
```
overlay 每槽各一份(P3 F41)。

**E5:chain1 的 dead-man 種在 B 的 `/etc/rc.local`(在 overlay 裡)**(`scripts/dv/chain1-254.sh:291`)
```
fq "... echo '( ping -c 5 $HOSTIP; sleep 1500; sh $BASE/ch1-deadman.sh ) ... & # ch1-deadman'; ... > /etc/rc.local ..."
```

**E6:`halow-setkey` 等鎖時不寫 log,只在逾時時寫**(`feed/batman-provision/files/usr/bin/halow-setkey:132-134`)
```
command exec 9>"$RUNDIR/halow-setkey.lock" || ...
w=0; until flock -n 9; do
	w=$((w + 1)); [ "$w" -ge "$LOCKWAIT" ] && { echo "halow-setkey: busy — ..." >&2; exit 2; }
```

**E7:WSL 與 Windows**
```
/proc/sys/fs/binfmt_misc: WSLInterop  llvm-18-runtime.binfmt  python3.12  register  status   ← 沒有 qemu-aarch64
which qemu-aarch64-static → (無);unsquashfs、chroot 有
/etc/wsl.conf: [interop] appendWindowsPath = false;/mnt/c/Windows/py.exe 不存在
py -0p: 3.13 C:\Users\yello\AppData\Local\Programs\Python\Python313\python.exe;bleak 3.0.2(使用者 site,未釘版本 / hash)
~/.batman-dv/peer-venv: pycddl、dissononce 可 import,cryptography 50.0.2(F-H20 ✅)
/home/yello/out/1.5.12-wsl.9+f2f2bf6.fw07f2063 存在(D11 負對照的 rootfs 來源 ✅)
```

**E8:04 的 :80 與 cmdline**
```
curl http://10.41.1.3/ → 200;netstat -ltn:0.0.0.0:80 / :::80 LISTEN(沒有 8095)
cmdline: ... rootfstype=squashfs,ext4 rootwait=20 panic=10 root=PARTUUID=...-02 batman_slot=A
/tmp/dhcp.leases:0 行;ip neigh dev br-ahwlan:4 筆;bluetoothctl 5.72 有
```

**E9:prov_test 的 provd env 只收數字值的固定 key**(`feed/batman-prov/files/batman-provd-test.init:24-33`):`SOCK_ONLY | FAST_FAKE_DELAY_MS | NO_BRUTE_LIMIT | GATT_ENCRYPT_CTRL | ADV_LEN_TEST`,值 `*[!0-9]*` 一律略過。所以 §5.1 的 `fault.provd` 是 P3 要新增的 init 邏輯。release init 與 test init 各自寫一份 `start_service`(兩檔都是 START=92)。

**E10:`batman-slot` 寫 rootfs 前會清零 SQ + 64 MiB**(`batman-slot:638`、`:644`、`:666-668`):`ZERO_MB=$(( SQ_MB + 64 ))`;`clear_root` 用 `dd if=/dev/zero`。另外已經有 shell fault `corrupt-after-write`(`:686`)。

**E11:known-failures 的 pre-P2 先例 ERE 會比對任何版本**(`scripts/validation-known-failures.txt`):`no batman-provd on 04 \([0-9][^)]*\): a pre-P2 image$`。

**E12:`batman_opf` 在 `rundir.sh:44`;`halow-status:111-113` 對 `/tmp/batman-fault.*` 中不是 root 擁有的檔記 `hc WARN tamper`**(health 會因此變成 WARN)。

**E13:`short()` = SHA-256 的前 16 hex**(`tests/tools/peer/owner.py:24-26`)。

**E14:P3 §3.7.6**:「helper 看到 provd 行程的任一條連線連續存在 60 s 時寫 `$RUNDIR/provd-stable`」;辨識 provd 的是 **helper**(PPid / uid / exe)。P3 §4 的清理表:`provd-stable` 在 helper 重啟與 provd 重啟時都「保留(同 boot_id 才有效)」。P3 §8 的接縫表:`provd-id-pid`「provd 辨識改回 peer pid = instance pid」。

---

## BLOCKER

### B1. S0 在任何 P3 之前的 image 上都建不起來,但 H4 PR 的驗證計畫(W 型負對照、`--pre-p3-full`、S0 provision)全部建立在它上面

**情境**
- P3 D1:H4 先 merge,之後才開始 P3 實作。D20:H4 / P3 上機前 02 / 04 重燒成新卡。所以 D20 重燒(§15 步驟 6)時能用的 image 只有 wsl.22 這一類 pre-P3 image。
- §3.1 的 S0 要求:
  - 每台兩位擁有者 H0 + H0b(要 `owner/add`);
  - 04 的 AP = C0、02 的 AP = C0'(要 `settings/set` key 20)。
- 這兩個在 wsl.22 都回 `E_UNSUPPORTED`(E1)。所以 `prov-bench-s0-254 provision` 在 H4 PR 期間一定失敗。
- §3.1:「S0 不成立 → 該單位 INVALID……一個不成立的 S0 不會被當成任何單位的 PASS」。§6.2 的 W 卻要求「wsl.22 上這條斷言 FAIL」並附原始輸出,§15 步驟 5 / 7 要附全部 W 輸出。
- 結果:R / RB / RD / L 載具上每一條 W(RT1、OW1–5、ST1、ST10、ST13、ST15、SD1–5、BG1–2、HT6–7、HT13、UP1、UP4、UP9、UD1–13……)在 wsl.22 上都會因為 `s0_assert` 不成立而印 INVALID,不會印 FAIL。H4 PR 附不出 W 證據。S0 provision 單位本身也沒辦法在 H4 PR 驗證。
- RB 型的 W 列還有第二層問題:它們的前置步驟(T 簽的 `update.check` → pending → `bulk.open`)在 wsl.22 上同樣是 `E_UNSUPPORTED`。設計沒有定義前置步驟失敗時要判 FAIL(W)還是 INVALID。

**修法**
1. 定義 **S0-pre**(pre-P3 基準),只用 P2 動詞與 root 工具,在 lease 底下建立:
   - BLE 認領 H0;
   - `network/join` N0;
   - AP = C0:root 在節點上執行既有的 `halow-setkey --ap`。值從節點上 root 0600 的檔讀入,不經主機 argv。F73 的 argv 界線要寫明;C0 是測試值。
   - 沒有 H0b。
2. 定義 W 列在 S0-pre 上的判法:「前置或本體的 P3 動詞回 `E_UNSUPPORTED` → 印 `FAIL <unit> <row>: …`」;只有 S0-pre 本身不成立時才印 INVALID。
3. 定義升級路徑 S0-pre → S0(第一個 P3 rc 上機時:`owner/add` H0b、key 20 = C0),寫進 §3.3 的生命週期表,並說明 journal 怎麼處理。
4. 改 §15 的順序:步驟 6 的 D20 重燒 + S0-pre provision 要排在步驟 5 的 `--pre-p3-full` **之前**。S0(完整)的 provision 移到 P3 rc 上機時,是 P3 PR 的閘門之一。
5. 在 §14 重算 `--pre-p3-full` 的成本(現在的 6 小時沒有算到 S0-pre)。

---

## MAJOR

### M1. 節點上的工具與設計寫的不符:ethsim、§7 探針、手機 preflight、「不聽」斷言照寫都跑不起來

**證據**(E2)
- busybox `nc` 是精簡版(`Usage: nc [IPADDR PORT]`),沒有 `-l`、`-k`、`-p`、`-w`。
- 沒有 `timeout`、`ss`、`hostapd_cli`(只有 morse 的 `hostapd_cli_s1g`)。
- F-H15 只寫了「有 `nc`」,誤導。

**影響**
1. §7 步驟 2「探針在 04 上起 `nc -lk -p 8095`」做不到。H4 的凍結閘門(D22)因此跑不了。
2. §4.5 的洪流「50 conn/s × 10 分」、lo 臂、VLAN 臂:連往被丟的 SYN 沒有逾時,每個 `nc` 會掛到 kernel 的 SYN 重送結束(`tcp_syn_retries = 6`,約 127 s)。50 conn/s 會累積約 6000 個行程,04 的資源先出事;單一連線的判定也沒有確定的結束時間。
3. §4.3 preflight 第 2 項 `hostapd_cli -i phy1-ap0 all_sta` → command not found → 所有手機臂永遠 INVALID。
4. HT12、HT15、§6.2 的 P 例子用 `ss -ltn` → 沒有這個指令。
5. VLAN 臂(D-1)的量測本身也不成立:
   - netns 的 `q0.0` 收不到 04 未帶標籤的 ARP / SYN-ACK 回覆(回覆會從 `h4v1` 本體進來);
   - 所以「從 `q0.0` 送 SYN」連 ARP 都解析不了;
   - 即使在 v6 規則下 04 收下了,netns 端也看不到連線建立。
   - §7 步驟 5「v6 → 放行」若以 netns 端的連線結果判定,永遠不成立。結果是使用者在場的那一趟白跑。

**修法**
- **listener**:`uhttpd -f -p <ip>:8095 -h <空目錄>`(04 有 `/usr/sbin/uhttpd`)。它回 HTTP,relay 的正向判定也比較直接。
- **connector**:`wget -T 2 -q -O /dev/null`(busybox wget 有 `-T`)或 `uclient-fetch --timeout`,背景執行、每個都有上限。或者在 `tests/tools/` 加一支釘 sha 的靜態 arm64 Go 小工具(connect / listen / 逾時 / 計數),與 provclient 同一套交付。
- **監聽檢查**:改用 `netstat -ltn`。
- **AUTHORIZED 檢查**:改用 `ubus call hostapd.<ifname> get_clients` 的 `authorized: true`(E2:可用),ifname 從 `network.wireless status` 取(F52)。
- **VLAN 臂**:
  - 在 `q0.0` 加 `ip neigh add <04 IP> lladdr <br-ahwlan MAC> dev q0.0 nud permanent`;
  - 判定一律在 04 端:`tcpdump -i br-ahwlan` 數 8095 的 SYN-ACK(04 有 tcpdump),或在 inet input 加一條只計數的規則;
  - 正向 / 負向都用同一種量測。
- 把 F-H15 改成實際的工具清單。

### M2. docker 臂接在 br-ots 上:fw4 本來就丟,所以這條斷言空著通過;P3 要的是 docker0

**證據**(E3)
- `iifname "br-ots" jump input_dockert`,而 `input_dockert { jump drop_from_dockert }`(zone `dockert` input DROP)。所以 br-ots 進來的 SYN 不論有沒有 `batman_http` 都會被丟。
- P3 §8 寫的是「eth0 與 **docker0** 容器送帶 VLAN 封裝的 SYN」。F58:「`docker` zone(docker0)是 input ACCEPT」。真正需要 `batman_http` 擋住的就是 docker0。

**影響**:HT11 永遠 PASS,而且只有 P、沒有能翻轉的對照。

**修法**
- 第二組 veth 接進 **docker0**。docker0 現在 DOWN、沒有容器,接一個 port 會讓它的 carrier 變 UP:列進副作用,還原時刪掉。
- 負對照(S):兩臂都用 `http-nofw`,只差有沒有 `inet batman_http_in` → 沒有表的那一臂連得上。
- 若也要測 br-ots,寫明它不鑑別,只當記錄。

### M3. 換規則型的 S 負對照會被 helper 自己的表 / 規則 / `phy*` 檢查擋下來 → 是因為「沒在聽」才連不上(空的 S)

**情境**
- P3 §3.8.1:「helper 背景每 4 s 確認兩張表、兩條規則都在,並做 `phy*` 前提檢查……在才給 `http.2`」。
- 下列 S 都是「把產品的規則換掉 / 拿掉」:
  - HT1「以 v5 `phy*-ap*` 規則載入 → 連不上」;
  - HT10「v6 規則 → 放行」;
  - HT20「沒有清 bit 的規則版本 → 放行」;
  - HT8「`http-nofw` + 不載表」。
- 只要 helper 判定表或規則不對,就不給 `http.2`,provd 根本不 bind 8095:
  - HT1 的「連不上」是因為沒在聽,不是 v5 萬用字元的錯 → 假鑑別;
  - HT10 / HT20 的「放行」永遠看不到 → 這兩條 S 永遠做不出來。
- HT8 的 S 同時改了兩個變數(接縫 + 表),違反 §2 自己定的 flip 規則。UP3 作者自己標了「兩個接縫」。

**修法**
- 這類臂的正、負兩邊**都**在 `http-nofw` 底下跑,只差規則內容。
- 每一邊都先斷言 `netstat -ltn` 有 8095 LISTEN(P),再看連線結果與 counter。
- UP3 可以用一條**名字以 `phy` 開頭**的 veth(例如 `phy9h4`,≤ 15 字元)接進 br-ahwlan:
  - 在 `http-nofw` 下它會被 bridge 規則打 bit,netns 就能用另一個 IP 到達 8095;
  - 兩臂都是 `http-nofw` + 這條 veth,只差 `upload-nosrcip` → 單一變數。
  - 這條 veth 會讓「`phy*` 前提」失效,所以只准在 `http-nofw` 時存在,列進 ethsim 的還原與 P9。

### M4. autocommit 臂:`provd-stable` 的前提沒有處理;P3 指定的 `provd-id-pid` 負對照放錯元件、整個不見了

1. **provd-stable 在 committed 槽上本來就存在**(E14:helper 重啟 / provd 重啟都保留,同 boot_id 有效)。RD 是在 committed 的 S0 上做 dry-run,S0 的 provd 早就穩定過 60 s。所以:
   - AC2「provd 壞掉 → REVERT」:正確的 autocommit 看到本次開機的 `provd-stable`,判 **COMMIT**。正確的程式會 FAIL,而這正是 AC4「穩定後被殺 → 仍 commit」的規則。AC2 與 AC4 在 RD 上分不開。
   - AC5「provclient 掛 60 s 不算」同理:檔早已存在,provclient 掛多久都看不出差別。
2. **`provd-id-pid` 是 helper 的接縫,不是 autocommit 的**(E14)。
   - H4 §5.5 把它做成 autocommit 變體 `ac-id-pid`「peer pid == instance pid」。但 autocommit 只讀 `provd-stable` 這個檔,裡面沒有 pid 判斷,這個變體沒有東西可改。
   - §5.1 的 Go fault 名單裡也沒有 `provd-id-pid`。
   - 結果:P3 §8 指定給 `prov-autocommit-p3-254` 的負對照(「正常 provd 也被退回」)在 H4 裡不存在;AC1 自己也承認 W 不鑑別,等於 AC1 沒有負對照;AC4 / AC5 的 S 指向不存在的機制。
3. AC6(provd 停用 → 只 WARN)的 S 用 `ac-helperoff-err`(D-16 的 helper 停用變體),元件錯了;它需要一個「provd 停用也 FAIL」的變體。

**修法**
- 在 §5.1 加 helper Go fault `provd-id-pid`。
- RD 的流程:
  1. root 刪 `$RUNDIR/provd-stable`。這是 helper 擁有的檔,§9 要寫明 harness 在 lease 底下是第二個寫者,以及還原方式;
  2. `push-helper`(帶或不帶 `provd-id-pid`)→ restart provd → 等 70 s → dry-run;
  3. 沒有接縫 → 檔被重寫 → COMMIT;有接縫 → 沒有檔 → REVERT。這是單一變數的 flip。
- AC2 / AC5 都先刪檔,再讓 provd 停住或只有 provclient。
- AC6 改用「provd 停用也 FAIL」的變體。
- `disable` provd / helper 會改 overlay 的 rc.d(持久),列進 M6 的還原清單。

### M5. 有些 S 負對照撐不過換槽,有些臂的載具與 P3 的前提不符

1. **UD16(D-9)**:「`p5-autosave-off`,在 T 之前以 `upper-helper` 放進去,撐過重開」。
   - `upper-helper` 寫的是**目前槽**的 overlay upper(E4);T 試用開的是**另一槽**,那槽的 overlay 是從 p5 PRESERVE 新建的,沒有這個 helper;
   - `/tmp/run/batman-prov-test/fault.helper` 在 tmpfs,重開就沒了;
   - 所以這條 S 做不出來。
2. **UD12**:F(wsl.22 新卡)→ ssh sysupgrade 到 P3 → 新槽第一次開機是試用(P3 D-9)→ commit 時 D-9 就存好了。
   - 要在試用槽裡放 prov_test helper,只能用 wbox image,而 wbox 永遠不 commit(F-H5);
   - 所以 S(`p5-autosave-off` → stale)也做不出來。
3. **ST20(D-7)**:在 RB(S0 = 已入網)上送 key 2。已入網的節點 key 2 → `E_REJECTED{14}`(P3 §3.3、§5.1),在走到 `--save` 之前就被拒,永遠到不了 D-7 的路徑。要改在 F + RB(未入網)。
4. **ST7(D-6)**:D-6 寫的是「**新卡**上『還原也驗證失敗』」,還原的動作是重新封鎖。RB(已配對)走的是「寫回舊值」那一條,測到的不是 D-6。要改在 F + RB。

**修法**
- (1)(2)改成在 committed 槽上的 RB flip:
  1. root 讓 p5 只因 P3 新 key 而 stale(從 p5 拿掉 ssid 行,沿用既有的 stale 手法);
  2. `push-helper`(帶或不帶 `p5-autosave-off`)→ helper restart(F42:重跑開機邏輯 = 「非試用的開機」)→ 斷言 stale 留著 / 已存。
  這測的是「非試用開機時存」。「轉 committed 那一刻存」的負對照,寫明只由 Go 單元測證明(誠實界線,請使用者決定),不要寫成節點上做得到。
- (3)(4)改載具,並把 §14 的 F 成本加上這兩臂。

### M6. 主機死掉時的還原不完整:有的臂留下 fail-open 或持久的狀態,dead-man 不知道

**情境**:§11「主機死」只列了 lease dead-man 的 unbind、關 fault、刪 ethsim、重啟服務(另加 dev-open 旗標)。但下列臂改的狀態 dead-man 都不會還原:

| 臂 | 留下的狀態 | 後果 |
|---|---|---|
| HT14 `firewall stop` | **整台沒有任何 nft 表**,docker NAT 也壞了 | fail-open,而且在 mesh 上,一直到有人處理 |
| HT18 `auto_includes = 0` | uci 持久 | 每次開機都不載 batman 表 → HTTP 永遠不聽;持久的錯設定 |
| HT21 `nomaster` | AP 不在 bridge 上 | 所有 AP client 斷線 |
| HT19 / HT20 | 外來的 bit 24 規則 / 更早優先序的打 bit 規則 | 殘留在 ruleset |
| §7 探針 | v6 / v7 的兩張表 | 殘留在 ruleset |
| HT3 | bluetoothd 停著 | BLE 管理通道斷、HTTP 備援一直開 |
| ST13 | `/tmp/.uci/wireless` 的暫存 | F48:下一個寫者 commit 時會被一起提交 |
| AC6 / AC7 | `disable` 了 provd / helper(rc.d 在 overlay) | 下次開機沒有 provd / helper |
| §12 | uid 65534 的 fault 檔 | E12:health 一直是 WARN |

**修法**
- 節點端加一份 **undo journal**(tmpfs,root 0700,每行 = 一個已登記的還原動作)。規則:每個會改狀態的動作**先登記、後執行**;EXIT trap 與 lease dead-man 都照 journal 逆序執行。
- `firewall stop` 的還原 = `firewall start` + `/etc/init.d/dockerd restart`,並斷言 `nft list tables` 與基準相同。
- P9 逐項檢查。
- §11 加「每一種持久 / fail-open 狀態在主機死時怎麼回來」這一列,並附測法:在該臂中途 kill 主機端,看 dead-man 是否還原。

### M7. F 載具的 dead-man 會被 LR1(luci-reset)自己清掉;uptime 期限在重開後失準

**證據**:chain1 把 dead-man 種在 B 的 `/etc/rc.local`(E5),那在 B 的 overlay 裡。LR1 在 F 的 B 上做 `firstboot -r -y`,會清掉 B 的 overlay,包含 rc.local 裡的掛鉤與 setsid 迴圈。

**影響**
- 重開之後到主機重新種下之前,如果主機死掉,04 會停在新卡的 B 上:p5 是 F 期間的測試擁有者,S0 不見了,只能等人來救。使用者常常不在現場。
- §4.4 的 `fresh-deadline` 是 `<run> <uptime 秒>`。B 一重開 uptime 就歸零,期限的意義跟著變:最壞會變成延後約 2 倍,而不是 ≤ 30 分。

**修法**
- 期限檔改成 `<run> <boot_id> <uptime>`:boot_id 不同 → 當作「現在 + 30 分」。
- LR1 的 firstboot 重開回來後,第一個動作就重新種 dead-man,並斷言它已武裝(chain1 `:292` 那一行檢查);把這段空窗寫進副作用。
- 或者把 LR1 排在 F 的最後,讓它結束後直接走 `restore_all`。

### M8. 「BLE 廣播在」的判定沒有鑑別力;SD3 的 P 門檻不可能達到

1. **掃描只看得到 UUID**。02 與 04 廣播的是同一個服務 UUID,廣播裡只有 `ServiceUUIDs`(F-H3、`bluez.go:269`)。SD3 與 HT8(b) 用「每 30 s 都看到 04 的 UUID」判定,但 04 撤了廣播時 02 的廣播仍然在 → 照樣 PASS。
2. **SD3 的 P「helper 的 ro 計數 ≥ 5000」**:
   - P3 §2 規定 ro 連線每連線 5/s(burst 20),超過的只回 `E_RATE` 給 app。10/s × 600 s 的負載,helper 最多處理約 3000 + 20 → 這條 P 永遠不成立 → SD3 永遠 INVALID。
   - 「helper 的 ro 計數」也不在 §5 的契約裡。

**修法**
- 廣播的判定移到節點端:root `bluetoothctl show` 的 advertising 實例數(04 有 bluetoothctl 5.72)每 30 s 取樣。或在負載開始前連一次 04、記下 04 當時的 RPA,在 RPA 輪替期限內只認那個位址。
- 負載的 P 改成 `peer.py` 自己數:ok 回應數 + `E_RATE` 數 ≥ 0.9 × 6000,ok 回應數 ≥ 2500。如果要 helper 的計數,就把它寫進 §5 的契約,並回報給 P3。

### M9. P3 有幾列 / 片語沒有對應到單位(附錄 A 漏項)

| 來源 | 內容 | H4 現況 |
|---|---|---|
| P3 §6「降級到沒有 P3 的版本」 | 舊槽沒有 P3 動詞;舊版整檔比對判 stale 直到 `--save`;舊版 96 照樣套用 p5 多出的 ssid 行;update-last 留著沒人讀 | UD11 只是兩個 P3 槽之間的回滾;沒有一臂真的回到 wsl.22,也沒有斷言這四件事 |
| P3 §6「helper crash」裡的「arm 後未重開 → disarm,報 3」 | `kill -9` helper(`armed: true` 之後、重開之前)→ 重啟後 disarm、phase 3、tryboot 旗標不在 | 沒有。UD3 是斷電(sysrq),路徑不同 |
| P3 §8 `prov-update-254` bench 臂「T 簽的被拒」 | release image 不信任 T(核心安全斷言) | 併進 UD15 的 NEEDS-PERSON。但這一條**不需要 YubiKey**:在 R(沒有 bind)上送 T 簽的 manifest → `update.check` 回 reason 11,現在就能做 |
| P3 §7「本機非 root 搶建 `/tmp/run/batman-provd-bulk`」 | tmp-trust allowlist **+ 測試**(init 檢查擁有者 / 非 symlink / 已掛載) | 只有 allowlist,沒有臂 |
| 附錄 D-12 | `update.check` 不拿 `n.mu`;key 15 的 `uci_staged` 與「SSID 無法保存」 | A.11 對到「ST*」(錯,應是 UD19 + ST13);沒有任何臂斷言「SSID 無法保存」的回報(ST20 只斷言不被還原) |
| P3 §8 mesh 臂 | 「手機 MAC **+ IP(含 ARP 毒化)**」 | HT8(a) 只偽造 MAC,netns 的 IP 是 10.41.250.n |
| P3 §6「啟動 / 正常停止」 | provd 正常停止 → HTTP 關;上傳檔由 helper 在窗到期或下次啟動時刪 | 只有 HT15(helper 停)與 HT16(provd kill),沒有正常停止 |

**修法**:補上這些列。§6.3 的 lint 要能抓到這一類漏項,見 m2。

### M10. 核准前沒探的假設;有兩個我查過已經不成立

1. **E-H9(BLE:connect、讀 `STATUS`、notify、MTU、9 KiB、230 s)** 是整個 `--via ble` 的前提,可以唯讀地現在就探(連上只會讓那台短暫撤廣播,不改狀態)。依規則要在核准前探過。現在排在凍結之後(§15 步驟 3)。
2. **E-H16 已經不成立**(E7):WSL 沒有 `qemu-aarch64-static`,binfmt 也沒有 aarch64。§8.2 要寫安裝步驟(apt 的 `qemu-user-static`,版本固定)與它的供應鏈。
   另外,以 root 在 WSL 裡 `chroot` 執行 arm64 的 uci-defaults:qemu-user 會把 syscall 直接交給 WSL 的 kernel。腳本裡的 `reboot`、`mount`、`sysctl` 會作用在 WSL VM 本身。要在隔離的環境跑:CI 已有 `dv-sbx` 沙箱(F-H22),或至少 `unshare -m -p -f`,外加一個不能 reboot 的 seccomp 或容器。
3. **`py.exe` 不在 WSL 的 PATH**(E7:`appendWindowsPath = false`,`/mnt/c/Windows/py.exe` 不存在)。§4.1 的 `py.exe -E -P blebridge.py` 照寫會 command not found。要用絕對路徑 `/mnt/c/Users/yello/AppData/Local/Programs/Python/Python313/python.exe`,並寫進 preflight。
4. **Windows 端 bleak 3.0.2 沒有釘版本與 hash**(E7)。H4-U6 只涵蓋 WSL 的 venv。橋接器雖然只看得到密文,但它決定「認目標」與 frame 的進出。被竄改的 bleak 可以讓 negative 臂(例如「連線被切」)空著通過。要用 `--require-hashes` 的 requirements,並由 preflight 檢查版本。

---

## MINOR

- **m1 known-failures 的 ERE**:先例的寫法 `\([0-9][^)]*\)`(E11)會比對任何版本。§6.1 的條目要把 pre-P3 的版本寫死,例如只認 `1\.5\.14-wsl\.22\+`,或依 `/etc/batman-build` 判定版本早於第一個 P3 版本。否則 P3 rc 若打包時漏了 `batman-http.nft` 與 `release-root.pub`,會被歸成 KNOWN,直到條目過期。
- **m2 §6.3 的「片語 ID」不存在**:P3 原文沒有片語 ID,誰來編號(P3 第一個 commit?還是產生器依 `;` 切分?)沒寫。「節點上 image 的 P3 版本與 TSV 的 P3 文件 commit 對不上 → FAIL」:image 裡只有 feed commit,沒有 P3 文件的 commit,這個對應沒有定義。
- **m3 手機 IP 的找法**:04 的 `/tmp/dhcp.leases` 是 0 行(E8),而 02、04 在同一個 L2 上都有 `dhcp.ahwlan`,手機可能從 02 拿到位址。`ip neigh` 只有在 04 跟手機通訊過才有;fdb 只給 MAC,不給 IP。要讀兩台的 leases,並 ping 一次廣播。
- **m4 手機自己說的結果**:負向斷言(「8095 連不上」)與 preflight 4(relay 的 sha 由手機自己算)都是手機自己回報的。被入侵的手機可以讓負向臂空著通過。補節點端的佐證:`tcpdump -i phy1-ap0` 看到來自手機 MAC 的 SYN、nft counter。RT3 的 P 也加「同一單位內開窗後同一個 relay → 8095 連得上」。
- **m5 ST11 的 P「log 有等鎖那一行」不存在**:setkey 等鎖時不寫 log(E6)。改成量 setkey 的總時間 ≥ 15 s,加上持鎖者自己的時間戳。
- **m6 UP5 ENOSPC 用合法的 PUT 誘發不了**:PUT 的 `Content-Length` 必須 = `http.5`;RAM 預算保證 `size=` ≥ payload。要模擬的是被入侵的 provd:以 uid 471 直接在 tmpfs 裡寫超過 `size=`。
- **m7 UD19(D-12)**:`update/check` 走 ops,ops 一次一個,在 provd 端就排在 `settings.set` 後面(P3 §2、§3.1 的表)。「≤ 5 s 回應」要改用 provclient 直接打 helper(第 4 條連線)才觀察得到。
- **m8 UD4 壞 rootfs 的確定性**:寫明依賴 `clear_root` 會清零 SQ + 64 MiB(E10),否則截斷後的尾巴可能還是同一個 V 的舊內容。更穩的做法是破壞 squashfs 的 superblock(長度不變)。cmdline 是 `rootfstype=squashfs,ext4`(E8):寫明 ext4 也試過才會 panic,並列進 E-H13 的觀察項。
- **m9 §7 探針在 wsl.22 的 04 上改 AP**:
  - 所有 AP client 都會斷線;
  - 04 已入網,joinwatch 的 `--on-join` tick 會把 C0 存進 p5(PRESERVE 含 `default_radio0.key`,P3 F8)→ 還原時也要重存 p5;
  - 原密碼的備份與還原必須在節點上做(`uci export wireless` 到 root 0600 檔再 `uci import`),絕不經主機 argv。
- **m10 金鑰庫的範圍**:
  - F 載具的認領會產生新的擁有者金鑰,不能覆寫 S0 的「04」條目,要另開一個 F 範圍;
  - OW4 在快照內移除 H0b,journal 不能記成「H0b 已移除」;
  - F 上用來認目標的序號末 4 碼,是 mkfs 之後的新序號,要從節點讀(chain1 `:268` 的做法)。
- **m11 孤兒 blebridge**:主機或 WSL 死掉時,Windows 端的 `python.exe` 可能還活著並且握著 BLE link → 04 撤廣播(`bluez.go:771-774`)。橋接器要在 stdin EOF 或父行程消失時結束;下一個 run 先用 `ps` 確認沒有殘留(使用者的 Windows 規則)。§11 加這一列。
- **m12 `push-provd` 用的 test init 要跟上 release init 在 P3 的變更**(bulk tmpfs、rw 掛載、`bulk-mount-fail`)。現在兩檔各自寫一份 `start_service`(E9),要 lint 比對差異。E-H12 不成立時的退路「W 載具」做不了上傳類的臂(試用中沒有 pending)。比較好的退路是比照 `upper-helper` 做 `upper-provd`。
- **m13 T 簽的 pending 殘留**:pending 在 helper 重啟後只要同 boot_id 就有效(P3 §4 清理表)。所以 unbind 之後,release helper 會接受 prov_test helper 建的 T 簽 pending。`unbind-all` / dead-man 要刪 pending 與上傳檔,並回報給 P3:pending 應該綁定驗它的信任集合。
- **m14 §13 漏列的副作用**:
  - UD12 / F 的 sysupgrade 會覆寫 **A** 槽的 rootfs 與 overlay(OTS 的 init、docker 的 rc.d),要 overlay-restore;
  - UP1(AP 關)、HT21(nomaster)會切斷所有 AP client;
  - uid 65534 的 fault 檔讓 health 變 WARN(E12),同一段時間的 `status` / verdict 斷言會受影響;
  - ST13 要用一個 commit 了也無害的 key,並在臂結束後確認沒有被別人提交。
- **m15 `s0_assert` 的 hostapd conf 路徑**:phy 編號會漂移(P3 F52),不要寫死 `hostapd-phy1.conf`,ifname 從 `network.wireless status` 取。
- **m16 「chain1 59 PASS / 0 FAIL」沒有證據**:repo 裡找不到這個數字。要附 H3 收尾時那次 run 的 log。
- **m17 §5.4 的引用錯了**:「F-H8 的 `batman_opf`」應為 `rundir.sh:44`。新的 shell fault(`setkey-*`、`slot-reboot-fail`、`slot-pause-write`、`bulk-mount-fail`)依 P3 §8 會存在於所有 image。這是產品的新增,要列進 §1.4 回報給 P3,並寫明安全性(只認 root 擁有的檔、其他記 TAMPER)。
- **m18 HT3 的 S 沒有鑑別力**:停掉 bluetoothd 時,`healthok-2field` 與完整的 `HealthOK` 都是 false,開啟的時點相同。HT3 的鑑別靠 W 即可,把 S 拿掉,或改成「只讓 `privacy` 失效」這類只有完整版才看得到的條件。
- **m19 秘密的斷言**:`short()` 是 SHA-256 的前 64 bit(E13)。對 C0 / ALT 這類人選的測試值,它可以拿來做離線字典比對,要寫明它們是高熵的隨機值。§12「grep 斷言不含(只比 `short()`)」要改成:grep 原始秘密值必須是 0(在 WSL 端做),log 只印 `short()`。CJ1 的 W 理由寫成「wsl.22 不比國家 → 入網」不準:wsl.22 上連 key 2 = AU 都設不了(`E_UNSUPPORTED`)。要嘛前置改由 root 設 uci,要嘛把理由改正。

---

## 附:v1 意見的處理(抽查)

| v1 | v2 現況 |
|---|---|
| B1 wbox 跑不出來 | 大致解決(載具 R / RB / RD / T / F)。殘留:跨槽的 S(M5) |
| B2 S0 | 已定義。新問題:pre-P3 建不起來(B1) |
| M1 接縫契約 | 解決(開 / 關、armed 斷言、environ)。殘留:`provd-id-pid` 放錯元件(M4) |
| M2 鑑別 | W / S / P 制度好。殘留:M2、M3、M8 的空斷言 |
| M3 pre-P3 判斷 | 改成依 build 特徵 ✅;known-failures 的 ERE(m1) |
| M4 手機 | 1、2、3、5、6、7 ✅;4 IP(m3) |
| M5 Windows | 架構 ✅;interop 路徑、bleak 釘版本(M10) |
| M6 BLE | 3、4 ✅;1 E-H9 未探(M10);5 改成只掃描,但仍分不出是哪一台在廣播(M8) |
| M7 發送端 | ethsim ✅;工具不存在(M1) |
| M8 dead-man | 可續期 ✅;LR1 自己把它清掉(M7);lease 契約維持不碰 p5 ✅ |
| M9 副作用 | docker / OTS、fw-badinclude ✅;持久 / fail-open 的還原(M6) |
| M10 對表 | 附錄 A ✅;漏項(M9) |
| M11 成本 | 逐單位 ✅ |
| M12 生命週期 | 大致 ✅;孤兒橋接器(m11)、持久狀態(M6) |

## Verdict:**REJECT**

- **B1**:S0 的順序矛盾,讓 H4 PR 拿不出 W 證據。
- **M1–M10**:有的臂在真機上做不出來(工具、跨槽),有的會空著通過(br-ots、換規則型的 S、廣播判定、autocommit 的前提)。

**收斂判斷**:**尚未收斂,但不需要再整份重寫**。v2 的骨架站得住,上面每一條都可以在原架構內修。建議修完後整份再送兩位審查。另外,凍結前先在 lease 外唯讀地完成 E-H9,並修正 F-H15 / E-H16 的事實,避免下一輪又在事實層翻盤。
