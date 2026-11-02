# #254 PR-F 審查 第 17 輪 — 審查者 B — 設計 v17(6feb29d)+ firmware `feat/254-ble`(到 3ec5e9b5)

**判定:REJECT(窄)** — 1 BLOCKER / 2 MAJOR / 8 MINOR。

3ec5e9b5 的程式碼本身我沒找到 MAJOR:
- patch 900 每次啟動都送 SC 模式,kernel 在 LE-only 下即使 powered 也照改旗標;
- init 的儲存區檢查是 fail-closed,13 個案例都照預期;
- gate 用 `grep -a` 掃二進位檔,主機沒有 busybox 就 FAIL。

這三項我都對原始碼或實跑確認過(見 §3)。

要擋下的有三件,都在**驗證計畫與介面契約**:
- **B1**:§12 Q8 / §8 的 `ble-pair-sc-only-254` 照現在的寫法**一定 PASS**,修好的 build 與 wsl.5 都一樣,分不出來。它卻是 D25 / D27 唯一的實證。
- **M1**:provd 的 fail-closed 條件 `sc_only_log` 靠 syslog 環形緩衝區裡的一行。04 上這一行開機約 1 小時就排到快被擠掉的位置;`/dev/log` 是 0666,任何本機 uid 不到一秒就能把它擠掉。結果是 BLE 管理面被關掉。
- **M2**:RPA 的空中測試有兩個會產生假 PASS 的地方,還有一個會改變 DUT 狀態的副作用。

範圍與做法:
- 讀了 v17 全文、`git diff 792967a 6feb29d`、v15 / v16 兩位的報告(已關的點沒有新證據就不重提)。
- firmware 看了 `build-3aplus..feat/254-ble` 全部,重點是 3ec5e9b5。
- BlueZ 5.72 與 linux-6.6.138 的原始碼讀的是 build 樹(patch 900 已套進 `src/adapter.c`)。
- 在 WSL 解開 wsl.7 payload(`/home/yello/out/1.5.12-wsl.7+f2f2bf6.fw5fa809b`)放到自己的 mktemp 目錄,跑了 gate、init 檢查的 busybox ash 測試。
- 04 / 02 只做唯讀查詢。
- 沒有 build、沒動 `/home/yello/firmware-2710`、沒 commit。wsl.8 還在 build:`build-wsl8.log` 最後一行是 `make failed — retrying -j1 V=s`。

**我自己的違規(更正紀錄)**:在 02 上誤下了一次 `mkdir -p /tmp/rvp3ro`(tmpfs 上的空目錄),發現後先 `ls -la` 印出(空、root、Oct 17 21:17),再 `rmdir`,確認已不存在。除此之外 02 / 04 沒有任何寫入。

證據分級:✅ 已驗證並附原始輸出或檔案行號;⚠️ 原始碼推論、未在空中實測;❌ 沒做。

---

## 1. v16 的發現有沒有被 v17 + 3ec5e9b5 關掉

| v16 發現 | 結論 | 證據 |
|---|---|---|
| N1 沒有 sc-only 位元;上游只在 SC 關著時送 | **程式碼關了;證據鏈沒關**(見 M1、B1) | build 樹 `src/adapter.c:10302-10313`:`if (adapter->supported_settings & MGMT_SETTING_SECURE_CONN) { info("Batman: SecureConnections mode %u requested", …); set_mode(adapter, MGMT_OP_SET_SECURE_CONN, btd_opts.secure_conn); }` ✅。kernel `mgmt.c:6905-6927`:`!hdev_is_powered \|\| !lmp_sc_capable \|\| !HCI_BREDR_ENABLED` 分支直接 `hci_dev_set_flag(HCI_SC_ONLY)` / `clear`,不看 powered ✅。04 `mgmt.info` 的 supported settings 有 `secure-conn` ✅ |
| N2 provd dbus 政策 | 設計關了(§4.6 白名單 + 明確 deny);firmware 目前只有 root 政策 ✅;寫法細節見 m7 | wsl.7 rootfs `/etc/dbus-1/system.d/bluetooth.conf` 只有 `<policy user="root">` ✅ |
| m3 / A-N6 儲存區擁有權 | **關了** ✅ | §3 的 13 個案例 |
| m4 / A-N5 wsl.5 列、空的 keys 目錄 | 關了。0012 已拿掉 `INSTALL_DIR …/keys`;wsl.7 rootfs 仍有 `etc/bluetooth/keys`(預期:wsl.7 早於 3ec5e9b5);**wsl.8 artifact 還沒出來,❌ 未在出貨物上驗** | wsl.7 rootfs `ls -la etc/bluetooth` |
| m5 / A-N4 gate | **關了** ✅,含負對照 | §3 |
| m6 SC-only 下的 GATT 回歸 | 計畫改成 02 讀 GATT,鑑別力不夠(m2) | |
| m7 磁碟上殘留的 IRK | 收進 §11 ✅;04 現在仍跑 wsl.4,store 是 symlink 指向 overlay:`/var/lib/bluetooth -> /etc/bluetooth/keys/`,而且 current settings = `powered le secure-conn privacy`(沒有 SC-only)。也就是說 **04 此刻就處於 B1 狀態**,只是沒有廣播者 | 04 唯讀 `ls -la`、`bluetoothctl mgmt.info` |

---

## 2. 發現

### B1(BLOCKER)`ble-pair-sc-only-254` 的判定「02 有沒有存下 04 的 IRK」一定是否,所以分不出修好與沒修好

**情境。** §12 Q8 的計畫:
- 02 用 runtime `mgmt.sc off` 當 legacy initiator,對 04 發起配對;
- 判定看 02 有沒有存下 04 的 `IdentityResolvingKey`;
- 負對照是 04 換成 wsl.5,預期會存下。

這個判定在兩種 build 上都必然是「沒存下」,原因有兩層,不管 02 送不送 bonding 位元都一樣:

1. **02 送 bonding 位元**(bluetoothctl `pair` / `Device1.Pair`,或 02 上有 agent 使 bondable=1;互動式 bluetoothctl 一定會註冊 agent,`client/main.c:491-494`)。
   - 04 的 `smp_cmd_pairing_req` **先**檢查 bondable,**後**才檢查 SC-only(`smp.c` build 樹:`if (!HCI_BONDABLE && (auth & SMP_AUTH_BONDING)) return SMP_PAIRING_NOTSUPP;` 在 `if (HCI_SC_ONLY && !(auth & SMP_AUTH_SC)) return SMP_AUTH_REQUIREMENTS;` 之前)✅。
   - 04 永遠是 bondable off,所以 wsl.5 一樣被拒,拿不到 IRK。
2. **02 不送 bonding 位元**(02 bondable off;這正是 v15 B1 的攻擊形狀)。
   - wsl.5 上配對會成功,04 也會送出 IRK 與身分位址。
   - 但 kernel 對 LE 的 `persistent = (req->auth_req & rsp->auth_req) & SMP_AUTH_BONDING` = false(`smp.c` `smp_notify_keys`)✅。
   - BlueZ `new_irk_callback`:`persistent = !!ev->store_hint; if (!persistent) return;` 在 `store_irk()` 之前就 return(`src/adapter.c` `new_irk_callback`)✅。
   - 所以 02 的 `/var/lib/bluetooth/…/identity` 或裝置檔**不會**出現 04 的 IRK。

**結論。** 照字面跑:
- 修好的 build:PASS;
- wsl.5 負對照:同樣「沒存下」。

如果有人照規則看負對照,會發現負對照沒有翻轉,但很容易被誤讀成「wsl.5 本來就安全」。如果沒人看,這就是一個永遠 PASS 的發行閘門,而它是 SC-only(D25 / D27)唯一的實證。

**修法**(全部只用 image 裡已有的 bluetoothctl `mgmt.*` 子選單,不需要 btmon):

1. **攻擊形狀要固定**:在 02 上以**非互動**指令執行(不註冊 agent):`bluetoothctl mgmt.sc off`、`bluetoothctl mgmt.bondable off`,然後 `bluetoothctl mgmt.info` 斷言 02 的 current settings 沒有 `bondable`、沒有 `secure-conn`。
2. **發起配對用 `bluetoothctl mgmt.pair -c 3 -t 2 <04 目前的 RPA>`**(io cap NoInputNoOutput、LE random)。不用 `pair` / `Device1.Pair`。
3. **判定改看「02 學到 04 的身分位址」**,不看存檔:
   - kernel 收到 Identity Address Info 後把 `hcon->dst` 改成身分位址(`smp_notify_keys`),`pairing_complete` 用 `conn->dst` 回覆(`mgmt.c:3377`)✅;
   - 所以 `mgmt.pair` 的輸出若是 `Paired with 88:A2:9E:B5:6C:8B (LE Public)`,就是外洩;
   - 輔助判定:02 的 `bluetoothctl devices` 出現 `88:A2:9E:B5:6C:8B`(BlueZ 在 store_hint 檢查之前就做了 `device_update_addr`)✅ 原始碼。
   - 修好的 build 應該看到 `Pairing … failed`,而且 02 上看不到 public 位址。
4. **負對照改用同一 build 的翻轉測試**,取代把 04 OTA 回 wsl.5:
   1. 在 04 上 `bluetoothctl mgmt.sc on`(LE-only 下立即清掉 `HCI_SC_ONLY`,`mgmt.c:6907-6915`)✅,其他東西(privacy、bondable、無 agent)都不變;
   2. 重做 2–3 → **必須**外洩。不外洩 = 測試裝置無效,判 FAIL,不是 PASS;
   3. 接著 `/etc/init.d/bluetoothd restart` → log 有本次的 mode 2 → 重做 2–3 → 必須失敗。
   
   這一組同時是 patch 900 第 (2) 部分與 L22 的負對照,而且只改了一個變數,符合使用者「翻轉實證」的規則。
5. **前置斷言**:04 的 current settings 有 `privacy`、沒有 `bondable`;04 有 connectable 的測試廣播。每一輪之前 02 都要重啟 bluetoothd(LOAD_IRKS 會 `hci_smp_irks_clear`,`mgmt.c:7124`)✅,清掉上一輪學到的 IRK。
6. **還原**:翻轉測試之後 04 的 IRK 已經給了 02 → **重開 04**(tmpfs 換新 IRK,mode 2 也重新套用),不要只重啟 bluetoothd。
7. 拿 wsl.5 當負對照要多做兩次 OTA,還會在那個槽的 overlay 留下持久 IRK(§11)。翻轉測試不需要這些,建議刪掉 wsl.5 方案。

### M1(MAJOR)`sc_only_log` 以 syslog 為來源:會被自然擠掉,也能被本機非 root 擠掉;契約沒寫

**情境。** §8 寫 provd 只在 health 檔 `privacy=1 sc=1 sc_only_log=1 bondable=0` 時廣播,欄位缺 / 過期 / 壞就撤廣播。D27 寫 `sc_only_log` = 「本次開機 log 有 `Batman: SecureConnections mode 2 requested` 且其後沒有 `Failed to set mode`」。

**證據(04,1.5.12-wsl.4,uptime 66 分鐘)✅:**

```
uci get system.@system[0].log_size  → 128
logread | wc -c → 138115 ; logread | wc -l → 1126
logread | head -1 → "Tue Jul 15 20:46:16 2025 kern.info kernel: [   12.985524] …"
(幾秒後再看)      → "… [   13.014084] …" → "… [   13.035510] …"  (環形緩衝已滿,正在丟最舊的行)
logread | grep -n -m1 'Bluetooth daemon 5.72' → 401:… bluetoothd[4513]
ls -l /dev/log → srw-rw-rw- root root
```

**後果:**
- **自然擠掉**:bluetoothd 的開機行離被丟掉只剩約 400 行(約 45 KB)。04 閒置時每分鐘 1–6 行,幾小時內就會丟掉;有 OTS、mesh 事件、SSH 登入時更快。之後 helper 讀不到 → `sc_only_log=0` → provd 撤廣播 → **BLE 這個唯一的管理面在正常運作中消失**。
- **本機非 root**:`/dev/log` 是 0666,任何 uid(nobody、容器裡若掛了 /dev/log 的程序)跑 `logger` 迴圈,不到一秒就能擠掉那一行 → 同樣的 DoS。偽造也做得到(tag 由 client 自己給),不過 D27 已說明偽造只在 root 拿掉 SC-only 時才有意義,這部分我同意。
- **契約沒定義**:
  - helper 是每 15 s 掃一次 logread,還是看到一次就記住?
  - 怎麼綁 bluetoothd 的 pid(respawn 後要看新的那一行)?
  - 「其後」的順序怎麼判斷?
  - `Failed to set mode` 是 `set_mode_complete` 的通用字串,不帶 opcode(`src/adapter.c:724`)✅,其他 opcode 的失敗也會讓它 fail-closed,而且無從歸因。
  - 「requested」是在指令送出**之前**記的,成功時沒有任何紀錄。
- **同一個介面的欄位清單三處不一致**:
  - §3 health 列:`<uptime> bluetoothd= hci0_powered= adv_registered_once=`;
  - §6.4:`bluetoothd=1 hci0_powered=1 adv_registered_once=1`;
  - §8:`privacy=1 sc=1 sc_only_log=1 bondable=0` + 「本次開機的 boot_id」(但格式裡沒有 boot_id 欄位);
  - §10 第 4 點還寫著 v16 的 `sc_only`。
- `ble-privacy-254` 的 log 斷言(`Generated IRK (getrandom)`、mode 2)也會受影響:測試開始得晚,那兩行就已經不在,結果會被判 FAIL / ❓。

**修法(建議放進 PR-F,因為 patch 900 是 PR-F 出貨的,PR-P1 的 helper 直接讀它,現在不做之後要重做 patch):**
1. patch 900 給 `SET_SECURE_CONN` 一個專用的完成 callback,在 init 已驗證過的 root 0700 儲存區裡寫狀態檔,例如 `/var/lib/bluetooth/.batman-sc`,內容 `pid=<bluetoothd pid> mode=<n> status=<mgmt status>`(tmp + rename)。log 行保留,當作人看的 witness。
2. 契約寫明:
   - 寫者 = bluetoothd(root),讀者 = helper;
   - 有效條件:檔案存在、`pid` == 現在活著的 bluetoothd(`pidof`)、`mode=2`、`status=0`;
   - 缺 / 舊 pid / 格式壞 → `sc_only=0`,fail-closed。理由:寧可沒有 BLE,也不要可能可配對的廣播;
   - 信任邊界:只有 root 寫得到,非 root 寫不進 0700 目錄,init 已驗證過。
3. §3 / §6.4 / §8 / §10 統一成一份 health 檔格式,含 `boot_id` 欄位。
4. 負對照:
   - 拿掉 main.conf 的 `SecureConnections = only` → 狀態檔 `mode=1` → helper `sc_only=0`;
   - 以 nobody 執行 `logger` 洪水 → health 不變。

(如果選擇不改 patch,至少要寫明 helper 在 bluetoothd 每次啟動時看到該行就記住,綁 pid,並說明擠掉後怎麼處理;但那仍然擋不住「helper 晚於擠掉」的情況。)

### M2(MAJOR)RPA 空中測試:「是 random 且會換」可能假 PASS;測試廣播的做法會改變 DUT

1. **「random」不等於 RPA。** kernel 有 NRPA 路徑(`hci_sync.c` `hci_update_random_address_sync`:`require_privacy` 且不用 RPA 時產生 non-resolvable 位址)✅,static random 也是 random。
   - 修法:斷言位址最高兩位元 = `01`。並且以 root 讀 04 tmpfs 的 `/var/lib/bluetooth/<addr>/identity`,在主機上計算 `ah(IRK, prand)` == hash,證明它是**這把 IRK** 的 RPA。這是唯一能把「privacy 真的生效」和「剛好是隨機位址」分開的檢查。
2. **02 若持有 04 的 IRK,掃描結果會被轉成身分位址。** `hci_event.c:6094-6095`「Check if we need to convert to identity address」✅。B1 的翻轉測試會讓 02 學到 04 的 IRK(非持久,但留在 kernel 清單裡;`smp_chan_destroy` 只在配對失敗時刪)。
   - 修法:RPA 測試排在配對測試**之前**,或者在兩者之間重開 04 並重啟 02 的 bluetoothd。
3. **怎麼起測試廣播沒寫。** 互動式 `bluetoothctl advertise on` 會註冊 agent → 04 的 bondable 變 1(A-N2,`client/main.c:491-494`)→ 測試期間 DUT 不是出貨狀態,路人也可以在這段時間綁定。
   - 修法:用非互動 `bluetoothctl --timeout <s> advertise on`(NON_INTERACTIVE 不註冊 agent)⚠️ 需實測它在 timeout 內會一直持有廣播;另開一個非互動的 `mgmt.info` 斷言沒有 `bondable`。
4. **負對照要寫進 PR-F 這次的測試**,不是只留給 PR-P2:
   - 重新註冊在 `rpa_timeout` 之前 → 同一個 RPA;
   - 不重新註冊、等 ≥ 2 × 900 s → 同一個 RPA(F28);
   - 重新註冊在過期之後 → 新 RPA。
   
   另外要確認期間 bluetoothd 的 pid 沒變(重啟會換位址,會讓「會換」誤判成功)。
5. 02 的掃描期間不要連線(連線結束後 kernel 會自己重開廣播,B-m2)。GATT 測試(m2)要排在 RPA 測試之後。

---

## MINOR

- **m1. §3 說 root 手動 `mgmt.*` 時「health 轉壞 → provd 撤廣播」,對 SC-only 不成立。**
  - `mgmt.sc on` 之後 current settings 仍有 `secure-conn`,log 行也還在,health 不會轉壞。
  - 只有 bluetoothd 重啟才會改回來(patch 900)✅ 原始碼。
  - 修法:誠實寫明「root 改 SC 模式在 bluetoothd 重啟前偵測不到」。測試與 runbook 的還原一律用重開機,並以 B1 的配對失敗確認,不能只看 log。
- **m2. 用 02 讀 GATT 不能取代 iPad 回歸。**
  - PR-F 沒有 GATT 應用程式,02 只能讀到 BlueZ 內建的 GAP / GATT service;未加密的 ATT 讀取本來就不經過 SC-only 的檢查(v16 B 已從原始碼推論)。
  - v16 B-m6 擔心的是 iOS 面對 SC-only 的周邊會不會主動要求配對,Linux central 測不到這件事。
  - 修法:02 的讀取保留(順便確認 connectable 廣播可連),iPad 的 GATT 連線讀取在 wsl.8 上重跑一次,寫進 §10 第 1 點。
- **m3. Q8 沒有列副作用與還原**(使用者 2026-10-18 的規則):
  - (a) 02 OTA:slot 切換加上 trial,`.seeded` → NEED_MESH=1,所以 trial 期間 04 必須在 mesh 上 → **先做完 04 並 commit,再做 02**。
  - (b) 02 的 p1 `distroconfig.txt` 加 `core_freq_min=500` 是持久改動;02 p1 已有 `[pi4] dtoverlay=miniuart-bt`(✅ 唯讀),p3 我沒看。之後 02 落到 slot B 時讀 p3,BT UART 可能異常,而且 `ble-ok` 要求兩份都改 → 兩份都改,或寫明只改 p1 的後果。
  - (c) 02 runtime 的 `mgmt.sc` / `mgmt.bondable` 改動 → 以重啟 bluetoothd 還原,並斷言 mode 2 已重新套用。
  - (d) 04 的 IRK 洩給了 02 → 重開 04。
  - (e) 測試廣播要確認已撤:bluetoothctl 結束後 `mgmt.info` / 無 instance。
  - (f) 如果仍用 wsl.5:04 是 lab 的乙太網橋、跑著 OTS;兩次 OTA 失敗會讓主機失去整個 mesh;wsl.5 的槽會留下持久 IRK。
- **m4. §5 的編號 L19–L22 各重複一次**:BLE 那幾列,和舊的 distroconfig / 96 掛不起 / trial / leave 那幾列。§13 寫「L20」時指的是哪一列不明確。修法:BLE 列改用新編號。
- **m5. 過時文字。**
  - §1 基準同一段裡,04 一下寫 wsl.4、一下寫「1.5.12-wsl.3 spike build」(實際 04 = `1.5.12-wsl.4+f2f2bf6.fw5ec36f4` ✅);
  - §4.6 表頭還是「a5e181b7;policy plugin 修正未重 build」;
  - §10 第 4 點還是 `sc_only` 欄位。
- **m6. 0013 的 Batman-Witness 只剩 SC 那一段的字串**(IRK 那段的 `Generated IRK (getrandom)` 不再當 witness)。兩段在同一個 `900-*.patch`、同一個檔案,套用是全有或全無,所以不是洞。不過 witness 清單最好兩個字串都列,免得之後有人把 patch 拆開。
- **m7. provd dbus 白名單的寫法要精確**(PR-P2)。
  - 每條 `<allow>` 都要同時帶 `send_destination="org.bluez"`、`send_interface`、`send_member`;只寫 `send_interface` 的規則會放行到**任何**目的地。
  - deny 清單要加 `AgentManager1.RequestDefaultAgent`、`ProfileManager1.*`、`Device1.Pair`。
  - 負測試不要只測 `RegisterAgent` / `Set Pairable`,也要抽測一個沒列出的方法(例如 `Adapter1.RemoveDevice`)→ 必須 AccessDenied。
- **m8. init fail-closed 的可用性面要寫進 §8 / §5。**
  - 若有一個在 S19 之前就跑、被攻陷的非 root 程序(ubus、logd 等)先建了 `/tmp/lib`,bluetoothd 就不會啟動;
  - `ble-ok` 存在時 health 是 `bluetoothd=0` → trial 判 UNHEALTHY → 好的 image 被 revert。
  - 只影響可用性、需要先攻陷一個程序,可以接受,但要寫成誠實界線。
  - 附帶:`[ -O "$STORE" ]` 對 symlink 會跟到目標。因為父目錄 `/tmp/lib` 已先驗為 root 0755,只有 root 建得出那個 symlink,所以無害(已實測,見 §3 案例 3)。

---

## 3. 我實際跑過的東西(✅)

**init 儲存區檢查**(從 tree 的 `bluetoothd.init` 抽出 `_mode` / `_bad` / `store_ok`,路徑改到 mktemp 目錄,WSL root 下用 `busybox ash` 執行):

| # | 情境 | 結果 |
|---|---|---|
| 1 | fresh | rc 0;`/tmp/lib` 0755 root、store `drwx------` root |
| 2 | 已存在(重啟) | rc 0 |
| 3 | spike 的 root symlink | rc 0,symlink 換成 0700 目錄 |
| 4 | `/tmp/lib` 屬 nobody | `NOT STARTING: … not a directory of ours` rc 1 |
| 5 | `/tmp/lib` 0775 | `… is group/other-writable` rc 1 |
| 6 | store 0700 屬 nobody | `… is not a private directory of ours` rc 1 |
| 7 | store root 0755 | rc 1 |
| 8 | `/tmp/lib` 是 symlink | rc 1 |
| 9 | store 是一般檔 | rc 1 |
| 10 | store root 0700,內有 nobody 的檔 | rc 0(只有 root 做得出這個狀態,因為父目錄已驗,所以無害) |
| 11 | `/var` 不指向 `/tmp` | `NOT STARTING: /var is not /tmp` rc 1 |
| 12 | `/tmp/lib` 1777 | rc 1 |
| 13 | store 2700 | rc 1 |

另外在 04 上唯讀確認:busybox `[ -O / ]` 支援;`readlink -f /var` = `/tmp`;`/tmp/lib` 是 `drwxr-xr-x root`。

**gate(`scripts/check-pvs-shim.sh` @3ec5e9b5,對 wsl.7 rootfs):**
- 乾淨:`check-pvs-shim: OK (sha256 c1446ce4…; 11 keys READ rc 1 silent under: sh busybox_ash; …)`,rc 0。`grep -rla bootloader_config` 只命中 `./etc/uci-defaults/95-batman-storage`、`./sbin/persistent_vars_storage.sh`。
- 放一個含 NUL 與 `vcgencmd bootloader_config` 的假 ELF 到 `usr/bin` → 新 gate rc 1(`./usr/bin/rvfake`);**負對照**:舊 gate(`git show 5fa809b1:scripts/check-pvs-shim.sh`,放在臨時樹裡執行)rc 0,沒抓到。
- PATH 上沒有 busybox → `FAIL: host has no busybox` rc 1。
- 邊界:執行時才組出字串的讀者照樣看不到,gate 註解已寫明。

**原始碼:**
- patch 900 的 SC 段 `adapter.c:10302-10313`;
- `set_mode_complete` 的通用錯誤字串 `:724`;
- kernel `set_secure_conn` `mgmt.c:6879-6955`;
- `smp_cmd_pairing_req` 的 bondable / SC-only 順序;
- `smp_notify_keys` 的 persistent 規則;
- BlueZ `new_irk_callback` 的 store_hint 提前 return;
- `pairing_complete` 用 `conn->dst` 回覆(`mgmt.c:3377`);
- `hci_event.c:6094` 掃描端轉身分位址;
- LOAD_IRKS 清除(`mgmt.c:7124`);
- NRPA 路徑(`hci_update_random_address_sync`)。

**bcm2710**:`boards/ekh-bcm2710` 沒有 `ble_diffconfig` 的 symlink → 3A+ image 不帶任何 BLE 套件;shim 走共用的 `files/`,行為與 F24 相同。❌ bcm2710 的 build 與 gate 這輪沒跑。

**04 / 02 唯讀狀態:**
- 04:`1.5.12-wsl.4`;store 是 symlink 到 `/etc/bluetooth/keys/`;current settings `powered le secure-conn privacy`;`Failed to set` 0 行;本次開機 20:52 bluetoothd 被重啟過一次(作者的原型操作)。
- 02:`1.5.12-wsl.2`;沒有 `/sys/class/bluetooth`;p1 `[pi4] dtoverlay=miniuart-bt`,沒有 `core_freq_min`。

## 4. 沒做的(❌)

- wsl.8 artifact 還沒 build 完 → v17 的 firmware 改動(init、0012、0013、gate)都**還沒在出貨物上驗**。
- 空中測試全部沒做(按指示不動節點)。
- 02 的 p3 內容沒看(要掛分割,屬寫入)。
- bcm2710 的 build / gate 沒跑。

## 5. 生命週期補充(對 §5,只列 v17 有新東西的路徑)

| 路徑 | 判定 |
|---|---|
| first boot / 每次開機 | init 驗證後建 store;IRK 用 getrandom;SC mode 2。✅ 原始碼 + ash 測試;❌ 出貨物 |
| bluetoothd respawn(procd) | 不重跑 `start_service`,沿用 store;patch 重送 mode 2(powered 也生效 ✅);privacy 在 powered 時被拒但旗標保留(A,v16) |
| `/etc/init.d/bluetoothd restart` | 重跑 store_ok(已存在 → pass,案例 2);BlueZ 正常結束時會先關電 |
| dbus 重啟 | bluetoothd 斷 bus → 結束 → respawn → 同上 ⚠️ 未實測 |
| hci_uart 重新 probe | 新 hdev → index added → `read_info_complete` 再跑一次 → SC + privacy 都重設 ⚠️ |
| upgrade wsl.4 → wsl.8 | 新 overlay、新 tmpfs → 沒有 symlink、沒有 keys 目錄 ✅ 推論 |
| rollback 到 wsl.4 槽(04 slot B) | 讀 overlay 的原型 IRK,沒有 SC-only,沒有廣播者 → L20 已涵蓋;**04 現在就是這個狀態** |
| 斷電 | 沒有持久狀態 ✅ |
| syslog 環形緩衝滿 | **新路徑**:M1 |
| 3A+ | 無 BLE 套件;shim 共用 ✅ 設定;❌ build |

## 6. 結論

3ec5e9b5 的三項程式改動成立,也都有負對照。

不能核准的原因:
- 設計宣稱 SC-only 的唯一實證,照計畫跑會兩邊都 PASS(B1);
- provd 的 fail-closed 條件建立在會被擠掉的 syslog 行上(M1);
- RPA 測試的判定與做法有假 PASS 與副作用(M2)。

修法都很小:
- B1 與 M2 只改 §9 / §12 Q8 的測試程序(用 `mgmt.pair` 加同 build 翻轉測試、RPA 位元與 ah() 驗證、非互動廣播、排序);
- M1 建議在 PR-F 的 patch 900 加狀態檔,並統一 health 契約。

修完之後需要窄範圍複查 §8、§9、§12 Q8、D27,以及 patch 900 的新 callback。
