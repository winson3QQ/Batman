# H4 harness 設計 v5 — 審查 A(第 5 輪)

- 對象:`docs/design/254-h4-harness.md` v5(`harness/254-h4` @ 40a598d),整份審。
- 上層對照:P3 `254-p3-impl.md` v7.1;h23 v14;`219-protocol.md` v0.7 + `.cddl`。
- 程式:`/home/yello/Batman` main 2ecf1cb。
- 節點:只做唯讀(04 = 10.41.1.3:`cat`、`ls`、`logread`)。WSL 只在 mktemp 目錄做非 root 實驗,做完已刪除(輸出最後兩行 `No such file or directory` 就是刪除後的確認)。沒有改任何 repo 檔,只寫這份報告。

**結論先講**:第 4 輪的 BLOCKER 與三條 MAJOR 確實解了。我逐一對過原始碼:node_cert 在 NX 與 NXpsk0 的 msg2 裡都有;dm-fire 在同一個行程裡持鎖;p6 備份;`stage-root` 會做 disarm 與 invalidate。pivot_root 沙箱我也在 WSL 非 root 實跑過,可行。

剩下一條 MAJOR,屬於 v5 新寫的「節點端佐證」:§4.2、§4.1、OW3 寫的 provd log 行,在 release 與 prov_test 的 provd 裡**都不存在**,包括 fake path 行、交握行、請求行、session 數。其中 `global handshake rate` 行雖然存在,但會被 log 限流吃掉。結果是 fake path 的負向臂與認目標的負對照,不是永遠 INVALID,就是只剩 peer 端的「msg2 解不開」可以判斷。而連到 02 也會得到「解不開」,所以可能出現假 PASS。

**判決:APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 9 MINOR)**。骨架已收斂。M1 是局部修改(改判定來源,不加新機制)。依規則,MAJOR 修完要再審整份一次;那一輪的範圍應該很小。

---

## 0. 我取得的證據(原始輸出節錄)

```
# (1) 交握與 node_cert —— feed/batman-prov/src/provd/noise.go
56  func Respond(msg1, static, prologue, psks, nodeCert, rng)
60-73  psks == nil(NX):只收 len 32
74-88  PSK:6 把全試,只收 len 48
89-96  ok == nil → fakeMsg2(… len(nodeCert) …); hs.Fake = true
98  m2, cs1, cs2, err := ok.WriteMessage(nil, nodeCert)       # NX 與 NXpsk0 的真 msg2 payload 都是 node_cert
# provd/server.go:246-296 buildNodeCert:{1:[cert], 2:s_node_pub, 3:boot_id, 4:ecdh(65), 5:sigS, 6:sigE, 7:sn(9)}
# node/node.go:346  SignPurpose(PurposeStatic, s_node_pub, BootID);keystore.go:73 = s_node_pub(32) ‖ boot_id(16)
# provd/server.go:679-701 handshakeParams:unclaimed/legacy → Prologue(deviceID), NX;其他 → Prologue(""), 6 把 PSK
# 219:292  psk_owner = HKDF(owner_tag_key, "batman-psk-owner-v1" ‖ device_id)   ← 每台不同
# 219:293  psk_member = HKDF(net_root, … ‖ net_id ‖ u32BE(net_version))           ← 全網共用

# (1b) provd 實際會寫的 log(release 與 prov_test 都一樣;grep logf / logLimited)
session.go:234  logLimited("session", "provd: session ended: %v", err)    # 只在 onMessage 回錯時
session.go:305  fake 路徑上再收到任何訊息 → "message on the fake path"
session.go:388-390  onMsg1:限速 → "global handshake rate (20/min)"(也是經 :234 的 logLimited)
server.go:126-144  logLimited:每個 key 每分鐘最多 10 行,超過就不寫
server.go:768  logLimited("conn", "provd: connection %s")
server.go:639  "provd: session revoked reason=%s"
bluez.go:599 / :614  "adv registered / withdrawn reason=%s"
→ fake path 被選中時沒有任何 log;交握成功沒有;請求沒有;session 數沒有
→ peer 收到 fake msg2 後自己 CLOSE(ReadFrame 錯誤)或等逾時(session.go:274-280),都不寫 log

# 04 唯讀:logread 1062 行裡 provd 相關的行
30 adv withdrawn reason=rpa_timeout / 30 adv registered reason=rpa_timeout
 1 adv withdrawn reason=connect     / 1 adv registered reason=disconnect      # 只讀 STATUS 的那次連線,沒有其他行

# P3 :376  HTTP 交握額度 10 / 分(只算 HTTP),與 BLE 的 20 / 分分開

# (2) net_secrets —— 219:325-337;gen.py:314-322;cose.go:139
KDF context = [24, [nil,nil,nil], [target_dac_hash, nil, nil], [256, rec_prot, net_id ‖ u32be(ver)]]
aad = ["Encrypt", body_prot, label]          # Enc_structure 的 external_aad = 標籤 "batman-secrets-v1",不是 target
cose.Decrypt(item, label, partyV, other, ecdh)   # wtxn.go:144:partyV = dacHash、other = net_id‖ver
CDDL :205-212 network-join-req:1, 2 (members-sign1), 3, 31 都是必填
node.go:1003-1017 netJoin 只讀 key 1、3(key 2 不讀)

# (3) lease / dead-man —— scripts/node/prov-lease-254.sh、ble-lib-254.sh
prov-lease:85-96  子命令:stage-check provd-reset provd-check radio-restore acquire renew release restoring normalising state
                  (沒有 `arm`;`renew` = cmd_arm)
prov-lease:32-65  role_fire_restore:stop_judges → unbind-all → rm killpoint 目錄 → upper helper
                  → [restoring 就 return :57] → provd_restart :60 → radio_restore :62 → joinwatch / openmanetd / tailscaled start :63
ble-lib:97-101   lock = exec 9>> + flock -n
ble-lib:305-310  cmd_arm:lock 30;lease_valid_for;lease_write;dm_arm
ble-lib:313      held = lock + lease_valid_for
ble-lib:327-343  dm-fire:sleep;最多 20 × lock 30;拿不到 → kill_run_groups,不拿鎖照做;lease 必須過期;role_fire_restore 在同一個行程
ble-lib:276-293  acquire:前一個 run 的 lease 檔還在就拒絕;之後 gc_rundirs

# (5) batman-slot(feed/batman-provision/files/usr/sbin/batman-slot)
419-436  begin_write:disarm_tryboot → invalidate_slot T → 刪 slot-T.protected
600-635  precheck:node_checks(含 p5_freshness_gate :465-515)、boot/、SHA256SUMS、boot/kernel8.img、
         root.squashfs 那一行;沒有 root.squashfs 檔 → SQ_BYTES 取 metadata 的 size=,沒有就 die "unknown rootfs size"
640-647  cmd_stage_root:payload 帶 root.squashfs 就拒絕;begin_write;clear_root;echo $TROOT
751      apply 成功 arm 之後寫 $RUNDIR/shutdown.reason "sysupgrade-trial (slot T)"
scripts/dv/brewrite-254.sh:2  brewrite = sysupgrade -n V + hold → back_to_a

# (6) WSL 非 root 沙箱實測(6.6.114.1-microsoft-standard-WSL2;binfmt qemu-aarch64 flags: POF)
複製 root-bcm27xx(cortex-a72)的 bin / lib / sbin 到 mktemp;
unshare --user --map-root-user --mount --pid --fork --net --uts --ipc → bind 新根到自己 → pivot_root . old → umount -l /old
→ exec /bin/busybox(aarch64,經 qemu F 旗標):ls / = bin dev lib lib64 old proc sbin tmp;nprocs=4
== outside control: OUTSIDE-WRITE-OK        # 沙箱外寫 $HOME 下的 canary 會成功
== canary: orig                             # 沙箱內寫同一路徑:宿主上的內容沒變
== host hostname: DSKT-Moonlight
/dev 裡多出一個一般檔 `null`                 # 沙箱內的 `2>/dev/null` 在 rootfs 副本裡建了一般檔

# peer 用的 noiseprotocol 0.3.1(~/.batman-dv/peer-venv)
noise_protocol.py:52-66  handshake_done(): del self.handshake_state …
實測:hs attr after read_message = False;先留住 handshake_state 的參照 → hs.rs.public_bytes == s_node  True
```

---

## 1. 第 4 輪意見的處理(對附錄 D 逐條核對)

| v4 意見 | v5 處理 | 我的核對 |
|---|---|---|
| A-B1 / B-B1 以 static key 認目標 | §4.2 在這一臂自己的交握裡驗 node_cert | ✅ 機制正確。NX 與 NXpsk0 的真 msg2 payload 都是 node_cert(`noise.go:98`)。`sig_static` 簽的是 s_node ‖ boot_id(`node.go:346`)。NX 的 msg2 有 `es`,證明回應方持有 s_node,所以「`rs` = cert[2] + sig_static 用釘選的 DAC 驗」這條鏈可以排除冒充:psk_owner 依 device_id 推導,只有目標打得開;psk_member 是共用的,靠比對 DAC 才分得出來。殘留:節點端佐證寫錯 → **M1**;peer 要怎麼取得 `rs` → m7 |
| A-M1 / B-m3 netobj | §4.1 自己實作;target = DAC hash;加密給 ecdh_pub;先驗 sig_ecdh;key 31 | ⚠️ 大致正確。殘留 m1:「AAD = target」寫錯;join 少了必填的 key 2;庫沒記 net_root |
| A-M2 / B-M1 執行器的鎖 | host 模式 / deadman 模式 | ✅ 與 `ble-lib:96-101, 305-343` 一致:先 renew 再 `held`,在同一個行程持鎖;deadman 在 dm-fire 的行程裡,不 renew。殘留 m2:子命令名字;m3:重疊時 role_fire_restore 其餘步驟的寫者 |
| A-M3 / B-m1 p6 持久 undo | 備份放 p6、綁槽、preflight 在 lease 底下執行、§13 列 fail-closed | ✅ |
| A-m1 / B-m9 交握限速 | ≤ 15 / 分;`global handshake rate` → INVALID | ⚠️ 那一行經 logLimited,可能被吃掉;HTTP 是 10 / 分 → 併入 M1 |
| A-m2 / B-m8 期限檔 | grant / spent 各一個寫者;每次開機 + 120 s | ✅ 上限:每次開機至少扣 120 s,1800 s 最多撐 15 次開機,一定會耗盡。殘留 m4(檔案缺時的語意) |
| A-m3 / B-m7 tcpdump 介面 | 在入口介面擷取;SYN 不足 → INVALID;counter 歸零 → INVALID | ✅ |
| A-m4 / B-m6 沙箱 | pivot_root + canary + 沙箱外對照 | ✅ 我實跑過,可行(§0-6)。殘留 m6 |
| A-m5 claim.secret | 節點端 hex | ✅ |
| A-m6 ap-restore 的 C0 | tmpfs stage + 主機重送 | ✅ |
| A-m7 / B-m5 E-H13 前置 | stage-root + brewrite | ✅ 機制對(`batman-slot:419-436, 640-647`;brewrite = sysupgrade -n + hold + back_to_a)。殘留 m5(payload 的條件、`shutdown.reason`) |
| A-m8 PROVD_KEYS | 加 `BATMAN_FAULT` | ✅ |
| A-m9 … A-m13、B-m2、B-m4、B-m10、B-m11 | 附錄 D 列的位置 | ✅ 逐條看過,文字都有落地 |

---

## 2. BLOCKER

無。

---

## 3. MAJOR

### M1. §4.2 / §4.1 / OW3 的「節點端佐證」用的 provd log 行並不存在,fake path 負向臂與認目標的負對照判不出來

**情境**
- §4.2「預期會走 fake path 的負向臂」:例如 OW6(被移除的 Hx 用 psk_owner)、member 收到 NX、RT1 矩陣裡被拒的格子、OW3「重新交握被拒」。v5 的做法是「以 04 端 provd log 的 fake path 行數增加作佐證」。
- §4.2 負對照 (a)「兩台的 provd log 都只有交握、沒有任何請求」、(b)「斷言請求只出現在 04 的 log」。
- §4.1「每個單位結束時在 provd log 斷言沒有 `global handshake rate` 行」。
- OW3「provd log 的 session 數 = 0」。

**證據**(§0-1b)
1. fake path 被選中時 provd 什麼都不寫(`session.go:345-357`)。之後如果 peer 自己 CLOSE 或等到逾時,也不寫。只有 peer 在 fake path 上**再送一則訊息**,provd 才會寫 `session ended: message on the fake path`(`:305`、`:234`)。
2. 交握成功、請求、session 數都沒有 log。04 實際的 log 裡,provd 相關的行只有 adv 的 registered / withdrawn。
3. `session ended: …`(包括 `global handshake rate`)與 `connection ble` 都經 `logLimited`:每個 key 每分鐘 10 行,超過就不寫(`server.go:126-144`)。fake path 臂連續做時,`global handshake rate` 那一行可能剛好被吃掉,「沒有這一行」就成了空洞的斷言。
4. HTTP 的交握額度是 10 / 分(P3 `:376`),低於 peer 的 15 / 分。

**後果**
- 照字面實作,這些負向臂不是永遠 INVALID(等不到不存在的那一行),就是實作者退回只看 peer 端的「msg2 解不開」。
- 而 psk_owner 是依 device_id 推導的,所以連到 02 時,peer 一樣看到「解不開」。萬一重連「同一個位址」實際連到 02(RPA 剛好換掉,或橋接錯),這一臂會**假 PASS**。
- 被限速擋下的連線,在 peer 看來也只是「被關掉」,與 HT7 / RT1h 等「預期關閉」的負向臂分不出來,這也是一種假 PASS。

**修法**(改判定來源,不加新機制)
1. **peer 端先分類**:
   - 收到長度正確的 msg2、但解不開 → `fake`;
   - 沒有收到 msg2 就斷線 → `ratelimited / not-ready` → 該臂 INVALID,不准算 PASS 或 FAIL;
   - 收到 msg2、解得開但 node_cert 不符 → `wrong-target`。
2. **fake path 的節點端佐證改用已經存在的行**:peer 收到 fake msg2 之後,送一個任意 frame → 04 必定寫一行 `provd: session ended: message on the fake path`。斷言:04 這一行的數量增加 1,同一個時間窗內 02 沒有增加。每個節點每分鐘最多 8 次,留在 logLimited 的 10 行以內;超過的話,那一臂 INVALID。
3. **認目標的負對照 (a)、(b)**:改成「peer 的 transcript 顯示不符的連線上沒有送出任何 envelope」,加上節點端用 `adv withdrawn reason=connect` 的時間戳,證明有連到那一台。「請求只出現在 04」改用 §1.4-2 已經要 P3 加的 helper ro 計數(04 增加、02 不變);或者在 §1.4 再向 P3 要一行 prov_test 專用的 `session end role=… reqs=N`。
4. **限速**:`global handshake rate` 的偵測改以第 1 步的 peer 分類為主,log 只當輔助。peer 對 HTTP 的限速 ≤ 8 / 分。
5. **OW3**:改成斷言兩行 `session revoked reason=…`(`server.go:639`)加上一行 `adv registered reason=disconnect`。
6. §1.3 補一條事實:provd 的 log 只有上面列的那幾種行,而且有限流(附 `file:line`)。

---

## 4. MINOR

1. **netobj 規格的三處文字**(§4.1、F-H47):
   - 「AAD = target」寫錯了。target 放在 KDF context 的 PartyV.identity;Enc_structure 的 external_aad 是標籤 `batman-secrets-v1`(219 `:325-337`、`gen.py:314-322`)。selftest 逐位元組比對向量會抓到,但規格要改對。
   - CDDL 的 `network-join-req` 規定 key 2 `members-sign1` 必填(`:205-212`;v4-A M1 已提過)。節點雖然不讀它(`node.go:1003-1017`),peer 的 CDDL 驗證與向量比對都需要。
   - 庫裡要記 `net_id`、`net_version`、`net_root`:psk_member 要靠它們推導(219 `:293`),SD2 等成員臂都用得到。
2. **§5.7 的子命令名字**:`prov-lease-254.sh` 沒有 `arm`,要用 `renew <secs>`(`:86`)。新的 `undo` 子命令要加進 dispatch / usage 與 `stage-check`。寫明 host 模式的 `undo` 做完之後,主機要 `release`(lease 已過期時 release 會失敗,這是可接受的)。
3. **§5.7 兩種模式重疊時的寫者**:deadman 看到 `undo-doing` 還活著,「只做段 1」。但 `role_fire_restore` 接下來的 `provd_restart`、`radio_restore`、joinwatch / openmanetd / tailscaled start(`prov-lease:60-63`)照樣會跑,和 host 的段 2(`svc-start`、`bt-start`、`ap-restore`)同時寫,等於兩個寫者。修法:比照 `restoring` 那一支(`:57`),段 1 做完就 return。另外:
   - 判斷 pid 還活著時要同時驗 cmdline,比照 `dm_rec_alive`,避免 pid 被重用;
   - host 模式在 ssh 斷線、SIGPIPE 被忽略之後,stdout 的寫入會回 EPIPE。undo 的輸出要改寫進節點上的 log 檔(p6,比照 `dm_log`),免得結果遺失,也免得 `echo … || die` 讓執行器中途停下。
4. **§4.4 期限檔的初值**:B 第一次開機時 `fresh-spent` 還不存在,照「讀不懂 → 觸發」會立刻觸發。要寫明:檔不存在 = 這個 `grant_seq` 已用 0。同一個 boot_id 內迴圈被重啟時,只扣 `uptime − last_uptime`,不再加 120 s。
5. **§8.1 E-H13 前置**:
   - `stage-root` 用的 payload 目錄,必須有 `boot/`(含 `kernel8.img`,sha 要對)、帶 `root.squashfs` 那一行的 `SHA256SUMS`,以及 `metadata` 的 `size=`。否則 `precheck` 會 die「unknown rootfs size」(`batman-slot:600-635`)。
   - `precheck` 也會跑 p5 freshness gate,所以要先斷言 p5 是 fresh。
   - 第 1 步的 `apply` 寫了 `$RUNDIR/shutdown.reason`(`:751`)。disarm 之後它還在,下一次正常重開的 boot-reasons 會被標錯。登記一個 `rm-file`。
6. **§8.2 沙箱**(我實測可行,§0-6):
   - hostname 與 reboot 兩列在沙箱外也不會成功(非 root 本來就不能),照 §8.2 自己的規則,它們不算有鑑別力的負測試。標成 sanity,真正的負測試是 canary 那一列。
   - `unshare` 之前要關掉 fd > 2:繼承下來的宿主目錄 fd,可以繞過 pivot_root。
   - bind `/dev/null`、`/dev/zero`、`/dev/urandom`。否則 `>/dev/null` 會在 rootfs 副本裡建出一般檔(實測),讀 urandom 的 uci-defaults 也會失敗,EE1 的逼真度就不夠。
7. **peer 取得 `rs` 的方法**:noiseprotocol 0.3.1 在交握完成時會刪掉 `handshake_state`(`noise_protocol.py:52-66`)。要在 `read_message(msg2)` 之前先留住它的參照,之後才讀得到 `rs`(我實測可行)。寫進 §4.2;selftest 的「sig_static 不符」要用真的交握跑,讓 `rs` ≠ cert[2]。
8. **在 P3 image 上重建 S0**:P3 遇到 `net_config` 的 key 5 ≠ `radio1.country` 會拒絕 join(reason 14,P3 `:245`)。S0 遺失之後在 P3 rc 上重建,或在 rc 上做 F 預演,都必須先設 key 2 = US,或先斷言國家已經是 US,否則第 5 步會被拒。
9. **編輯**:
   - 狀態列(`:3`)的修改清單少了 §5.5 與附錄 D;
   - `:16` 的審查報告清單要加上 v4;
   - F-H48 寫的 `:96-101, 137-155` 與實際行號不同(`dm_arm` 在 `:137-155`,鎖在 `:97-101`);意思正確。

---

## 5. 附錄 A 逐列核對(W / S / P / G)

- **W**:`--pre-p3-full` 的規則(§2)與 F-H23 都成立,W(E_U) 產生得出來。CJ1 / CJ2 的手法依 F-H43。
- **S**:§5.1 / §5.4 的名字與附錄 A 一一對得上。UD-T1 的 S(同一份 manifest 在 RB 上會過)合理。
- **P**:HT15–HT17、HT22、UP5 / 6 / 8 / 11、UD9 / UD10b / UD11 都是臂內的前後對比,判定本身可以 FAIL。
- **G**:只出現在 UD12、UD16,符合 H4-U8。
- **依賴 M1 的列**:
  - OW3(session 數);
  - OW6、OW5 的重交握;
  - RT1 / RT1h 裡預期被拒的格子;
  - HT7(預期關閉,與限速分不開)。

  M1 修好之前,這幾列的負向判定不可靠。
- **「—」**:ST17、ST22、BG4 都附了理由。

---

## 6. 安全(逐個 actor)

| actor | 結論 |
|---|---|
| 被竄改的 Windows 橋 / bleak | 認證之後才送請求,成立。不符的連線不送任何 envelope。負向臂因為不送請求,沒有洩漏;但判定的佐證見 M1 |
| 被入侵的成員節點(有 psk_member、root) | 拿得到自己的 DAC 私鑰,拿不到別台的,做不出別台的 `sig_static`;NX msg2 的 `es` 綁住 s_node。比對 DAC 就擋得住冒充 |
| 本機非 root 行程(節點) | fault 檔與 journal 的信任邊界沒有變。journal 參數驗證已加(§5.7) |
| 同一個 Windows / WSL 使用者 | 庫的誠實界線已寫明。沙箱:實測 canary 擋得住;fd 繼承見 m6 |
| 被入侵的手機 | 負向斷言都有節點端佐證(named counter + tcpdump),沒有變 |
| 我們自己的錯 | M1(假 PASS 的路)、m3(重疊時兩個寫者) |

**秘密**:`claim.secret` 走 hex 經 stdout → stdin,不落地;C0 在 tmpfs 0600,並登記 `rm-file`。沒有新的洩漏面。

---

## 7. 判決

**APPROVE-WITH-CHANGES:0 BLOCKER / 1 MAJOR / 9 MINOR。**

- **M1**:§4.2、§4.1、OW3 的節點端佐證用的 provd log 行並不存在(fake path、交握、請求、session 數),或者會被限流吃掉(`global handshake rate`);HTTP 的額度是 10 / 分。修法:改成 peer 端分類(fake / 限速 / 認錯目標);fake path 的佐證改用「送一個 frame 之後,04 出現 `message on the fake path`」;OW3 改用 `session revoked`;HTTP 限速 ≤ 8 / 分。

**收斂了嗎**:收斂了。第 4 輪的 BLOCKER 與 MAJOR 都真的解決了,新加的機制(node_cert 認目標、host / deadman 兩種模式、grant / spent、stage-root 前置、pivot_root 沙箱)我都對過原始碼或實跑過,本身成立。

M1 是同一類錯誤的最後一處:對他人程式行為的假設沒有附證據。修法只需要改判定來源,不需要新機制。依規則,MAJOR 修完要再審整份一次,但預期很快。
