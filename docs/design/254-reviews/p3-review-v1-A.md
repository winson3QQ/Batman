# #254 PR-P3 設計 v1 審查(審查者 A)

對象:`docs/design/254-p3-impl.md`(feat/254-p3 @ 96a578d,base main 2ecf1cb)。審整份文件，不是只看增量。
證據來源:同一棵樹的原始碼(下列 `file:line`)與 04(1.5.14-wsl.22,`BATMAN_VERSION=1.5.14-wsl.22+2ecf1cb.fwce20a68`)上的唯讀指令。04 上沒有做任何寫入。

**結論:REJECT** — BLOCKER 2 / MAJOR 7 / MINOR 12。

---

## BLOCKER

### B1. HTTP 通道和 BLE 共用 provd 的 2 個 session 槽、全域交握額度與廣播撤回:mesh 上不需任何憑證的人就能讓每台節點的 BLE 失效

**情境**:設計 §3.8.2 寫明 HTTP「與 BLE **共用**全域交握額度(20/分)與 session 上限」,而且 ahwlan:8095 常駐。F9 說 ahwlan 整個 mesh 都連得到;04 上 `br-ahwlan` 的 ports 是 `eth0` + `bat0`,所以有線網路和 docker bridge 上的容器也連得到。
- `Slots = 2 // BLE + sock together`(`provd/server.go:33`)。`Accept` 只會踢掉 `evictable()` 的 session,而 `evictable()` 對交握中的 session 和 fake path(10 s)一律回 false(`session.go:150-160`、`server.go:739-771`)。
- 用錯的 PSK 送 msg1 就會走 fake path,佔一個槽 `HandshakeMax = 10 s`(`session.go:396-406`、`server.go:28`)。兩個槽 × 每分鐘 6 次 = 12 次/分，不到 20/分的額度，兩個槽就能一直被佔住。
- 只要有 session 存在,BLE 廣播就撤回:`case nlinks > 0 || b.srv.Sessions() > 0:`(`cmd/batman-provd/bluez.go:772`)。
- 全域額度用完之後，第 21 次交握直接斷線(`server.go:645-661`、`session.go:389-391`)。攻擊者每分鐘送 20 個 msg1,擁有者在旁邊也連不上 BLE。
- 沒有惡意也會出事：成員從 mesh 開一個 HTTP session,只要沒正常關閉，就會佔槽並撤回該節點的 BLE 廣播，最長 `IdleAuthed = 300 s`。
- TCP 層沒有上限:provd 的 open files 是 1024(04 `ulimit -n`)。設計只提「body 上限」,沒有連線數上限、`ReadHeaderTimeout`、idle timeout。slowloris 會用光 fd,BLE 的 AcquireWrite/Notify fd 跟著失敗。

結果:BLE 本來是「必須在旁邊」的實體邊界，加上這條常駐的 HTTP 之後，變成整個 mesh 都能遠端打掉它。BLE 是 3A+ 唯一的管理通道，也是認領的唯一通道。

**修正**:
1. HTTP 用自己的槽池(例如 1 個)與自己的交握額度，另加每個來源 IP 的額度。BLE 的槽與 20/分只算 BLE。
2. `Sessions()` 撤回廣播只算 BLE 的 link / session。
3. HTTP 的 fake path 不佔 BLE 槽，回完等長 msg2 就關。
4. `net/http` 設 `ReadHeaderTimeout`、`IdleTimeout`、`MaxHeaderBytes`,並限制同時連線數(listener 包 LimitListener)。
5. 生命週期矩陣與 §7 補上這個行為者。

**負對照**:mesh 上沒有憑證的主機以 20/分灌 `/batman/v1/session`、並開 900 條半開 TCP。期間擁有者經 BLE 交握必須成功、廣播必須在，否則 FAIL。這個測試在 v1 設計下應該會 FAIL。

### B2. 簽章只綁 `SHA256SUMS`,但 root 在驗簽之前就解開不受信任的 tar;batman-slot 還會把沒列在 SHA256SUMS 裡的 boot 檔寫進 boot 分割

**情境**:payload 由 app → provd(不受信任，§5)→ helper。
- 解開的順序反了。§3.7.4 步驟 2 是先「解出除 `root.squashfs` 以外的成員到 root-only 目錄」,之後才比對 `sha256(SHA256SUMS)`。tar 本身沒有被簽章雜湊涵蓋;`build-ab-payload.sh:73` 產生的 tar 順序是 `root.squashfs boot metadata SHA256SUMS`,SHA256SUMS 在最後，所以一定要先把整包解完才驗得到簽章。04 上 `/bin/tar -> busybox`。現有路徑 `tar -xf - -C "$dir" -X "$ex"`(`platform-ab.sh:330`)以前只處理 root 自己放的檔，所以沒有問題;設計沒有證明 busybox tar 對 `../`、絕對路徑、symlink 成員再寫穿、hardlink 成員的處理是安全的。這是 root 解析攻擊者控制的檔案，而且發生在驗證之前，屬於第 5 條的 privileged-on-untrusted-data。
- 簽章涵蓋有缺口(現有 batman-slot 的行為，到 P3 變成可以利用)。`cmd_apply` 會複製目錄裡**所有** `start*.elf`、`fixup*.dat`、`*.dtb`、`overlays/*`(`batman-slot:678-682`),但讀回驗證只看 SHA256SUMS 列出的名字(`:697-701`),precheck 也一樣(`:600-603`)。因此可以在 boot 分割多放一個未簽章的檔：例如簽章集合裡沒有的板子變體 DTB(量產是 CM4,要確認 `bcm2711-rpi-cm4*.dtb` 是否都在集合內),或 HAT EEPROM 指名的 overlay。§3.7.4 步驟 6 說「上傳檔被改也不怕」,只對 rootfs 與「列出的」boot 檔成立。
- 資產是 §7 自己寫的「更新 = 任意程式碼」,攻擊者是 §7 列出的「被入侵的 provd」。

**修正**:
1. 在 helper(Go)用 `archive/tar` 自己解析，嚴格白名單：只收 regular file;名字限 `^(SHA256SUMS|metadata|boot/[A-Za-z0-9._-]+|boot/overlays/[A-Za-z0-9._-]+)$`;每個成員有大小上限;任何 link、目錄穿越或重複名字一律拒絕。只寫進 helper 自己新建的 0700 目錄，以 `O_EXCL|O_NOFOLLOW` 開檔。
2. `build-ab-payload.sh` 把 tar 順序改成 `SHA256SUMS metadata boot root.squashfs`。platform-ab 先用 `-X` 再 `-xOf` 單獨取 root.squashfs,不依賴成員順序。helper 先驗 S 和 SHA256SUMS,通過後才寫出任何其他成員;不在 SHA256SUMS 裡的成員 → 拒絕(reason 11)。
3. `batman-slot write` 拒絕 payload 目錄裡任何沒列在 SHA256SUMS 的檔。sysupgrade 路徑同樣受益，兩板共用。

**負對照**:四包 tar 都要被拒，且目錄外沒有任何寫入、boot 分割沒有變化。在 v1 設計 + 現行 batman-slot 下，第 3、4 包會被寫進去。
1. 含 `../x` 成員;
2. 含 symlink 成員 `boot/overlays -> /etc`,後面接 `boot/overlays/rc.local`;
3. 簽章正確，另加一個未列名的 `boot/overlays/evil.dtbo`;
4. 簽章正確，另加一個未列名的 `boot/bcm2711-rpi-cm4s.dtb`。

---

## MAJOR

### M1. `status` / `diag/summary` 在唯讀路徑上跑昂貴的 root 子程序，成員可以從 mesh 遠端觸發，會卡住 p5 存檔並讓 OTA 被拒

**情境**:成員角色可以呼叫 `status`、`diag/summary`(§3.1);D6 之後，任何持有 `psk_member` 的人經 mesh 都能呼叫(psk_member 全隊共用，遺失的手機也算)。
- `halow-status json` 在 Pi 4 上 `real 0m 0.41s`(04 實測)。唯讀額度是全 helper 10/s(`readonly.go:23-24`),最多約 4 CPU-秒/秒。
- §3.4 key 4 每次都跑 `batman-config-save --check`。它會取 `cfgsave.lock`(`--check` 等 5 s,`batman-config-save:244`)並 ro 掛 p5。joinwatch 的 `--on-join` 是 `wait=0`:拿不到鎖就 `exit 1` 並累加 `BUSYCNT`,連續 8 次後寫 `cfgsave-lock.busy`(`:247-256`)。`batman-slot` 的 `p5_freshness_gate` 看到 `cfgsave-lock.busy` 就拒絕 OTA,訊息是「saves are failing this boot」(`batman-slot` p5_freshness_gate `*)` 分支)。另外 ro 掛載本身會讓並行的 rw 掛載變成唯讀(#202 T11,`batman-config-save:33-35`)。
- 這也違反 `readonly.go:1-8` 的契約:唯讀動詞「只碰 n.P、n.KS、overlay 檔」,不執行子程序。
- 設計沒寫這些動詞走 provd 的哪條連線。走 ctl 會跟 4 s poll 共用 `ctlMu`,`CtlWait 10 s` 一逾時就斷 ctl,並重拉 owners / PSK(`server.go:163-182`)。走 ops 會排在 `net.apply` / `update.prepare` 後面，最多 330 s(`server.go:22`)。

**修正**:
1. `p5_saved` 改讀現成的快取判定(例如 `--on-join` 最近一次的結果檔，或 `$RUNDIR/p5-check.rc`,附時間戳，過期就省略或回 false),不要每次都跑 `--check`。
2. `halow-status json` 在 helper 內 single-flight 並快取 ≥ 5 s。
3. 跑子程序的動詞另設低額度(例如每連線 1/s、全域 2/s)。
4. 文件寫明這些動詞走哪條連線，並說明為什麼不會干擾 poll。

**負對照**:成員以額度上限打 `status` 10 分鐘。期間 `--on-join` 不得被擋 8 次、`cfgsave-lock.busy` 不得出現、`batman-slot precheck-node` 仍然通過。

### M2. 國家改以 `net_config` 為準(D9),但 `netJoin` 完全沒有處理國家。要改的是 P2 的無線交易，設計卻延到「實作時查」

**證據**:`grep -n country feed/batman-prov/src/node/*.go cmd/batman-provhelper/*.go`(排除 _test)→ 0 筆。
**影響**:要在 `wtxn.go` 的交易裡加國家，這是 P2 審查最多輪的元件。要定的事有：`.txn` 格式、read-back、回滾、新國家下目前頻道合不合法(`halow-setkey` regdb)、`radio0.country` 變動會重載手機 AP、降級回沒有這個欄位的 P2 時 `.txn` 的相容性。改 radio1 國家還會觸發 morse 重載，等於整個 mesh 斷一次。
**修正**:把「入網時套用國家」寫成完整設計。要涵蓋：在交易的哪一步、read-back 的欄位、失敗時回到舊國家與舊頻道、生命週期矩陣的 upgrade / downgrade 列;並列為 H4 斷言(join 的國家與 radio1 不同 → 套用;頻道在新國家不合法 → 整筆 txn 回滾)。

### M3. D1 要求 H4 照本文件的契約先寫、先 merge,但契約裡還有 ⚠️;其中好幾項現在讀原始碼就能定

我已查證，可以直接寫進文件的：
- 寫入互斥的鎖 = `$RUNDIR/batman-slot.lock`(mkdir,pid + cmdline 檢查，`batman-slot:82-95`)加上 `$RUNDIR/batman-slot.busy`(`:155`;helper 的 `otaBusy()` 看它，`node.go:215`)。
- `batman-dev-open` = `/etc/batman-dev-open`,現有程式碼只做 `os.Stat`(`cmd/batman-provhelper/main.go:387,564`)。要做 opf / 非 symlink / link count 檢查，就是新增的程式碼，不是「確認現有定義」。04 上不存在。
- §9-6(降級時 bulk 殘留):overlay 是每槽各一份(04:`/mmcblk0p2 on /overlay type f2fs`;新槽從 p5 的 PRESERVE 還原，不含 bulk 段)→ 不會殘留在新槽。回到舊槽時，舊槽本身就有 `batman-bulk-clean`(bulk 只會在 P3 以上的槽打開)。可以結案。
- §3.4.1 join-reasons:`verdict()` 的句子帶變數(`mesh key $KEY`、`($RTYPE)`、`ch$CH/$MID`、`($STA)`、`fwding=$FWD nolearn=$NOL`;04 `/usr/bin/joinwatch` 約 :70-80)。「一句一碼」的完全比對，10 種裡有 5 種會落到 code 0。改由 `verdict()` 自己輸出 `code|句子`,只留一個來源。

仍然開著、會影響契約的：
- U5 改名。改名後 IP 會不會變、會不會重開、變了怎麼回復，都沒有定義。這不符合「失敗就回到之前的狀態」。要嘛等 U5 跑完再定，要嘛把改名移出 P3 的 H4 範圍並寫進 checklist。
- M2 的國家。

### M4. `bulk.open` 沒有「失敗就回到之前的狀態」,步驟也不完整

- 沒有驗證 AP、IP、DHCP 真的起來了;沒有失敗回滾。`wifi reload` 或 hostapd 起不來時，手機 AP 已經關了，使用者最多 15 分鐘沒有 Wi-Fi,直到逾時才恢復。
- 「恢復 `default_radio0.disabled`」沒有記住原值。操作員原本就把手機 AP 關掉時,`bulk.close` 和開機清理會把它打開。原值要存在 helper 自己的檔案裡(開機清理也讀它)。
- 步驟少了 netifd 與 dnsmasq 的重載。`network.bulk` 要 `reload_config` 或 `ubus call network reload` 才會出現,`wifi reload` 不會建 netifd 介面;`dhcp.bulk` 要重載 dnsmasq。少了這兩步,AP 起來了卻沒有 IP、沒有 DHCP。
- uci 的多寫者問題。OpenWrt 的 `uci set` 暫存在共用的 delta 目錄;任何其他 root 程序在中間做 `uci commit wireless|network|dhcp|firewall`(例如 halow-setkey、keyguard、99zz、操作員),就會把 helper 做到一半的變更提交出去，或把它丟掉。要嘛一次 `uci batch` 加 commit,要嘛用 `-t` 私有 savedir,並在擁有權表列出這四個設定檔的其他寫者。
- 「HaLow mesh 不受影響」(D5)沒有證據:netifd 的 `wifi reload` 對 radio1(morse)是否真的不動，要實測或引原始碼。`fw4 reload` 對 OTS 的 docker DNAT 規則有沒有影響，也要附證據(04 有跑 OTS)。

**負對照**:用 wbox 讓 hostapd 起不來 → `bulk.open` 回錯誤，手機 AP 在 N 秒內恢復，四個設定檔與開啟前 byte-identical。

### M5. 「只做必要的修改」:有了 D6 的常駐 ahwlan:8095,暫時 AP 原本的理由已經不存在(要使用者重新決定)

暫時 AP 的原始理由是「獨立 zone,只開 provd 的埠」(`219-field-provisioning.md:463-467`),因為 ahwlan zone 全收。D6 讓 8095 在 ahwlan 上常駐(PSK-only),這層隔離已經沒有意義。現場的情況是每個人的手機連自己節點的手機 AP(專案現場情境),手機可以直接經**已連著的手機 AP** 上傳到 ahwlan:8095(擁有者 session)。這樣不用換 AP、不用動四個設定檔、不用開機清理、不用定時器，也沒有 15 分鐘的 AP 中斷與 M4 的那些失敗模式。
暫時 AP 只剩一種情況需要：手機不在手機 AP 上(例如手機不知道 AP 金鑰)。
**要使用者決定**:(a) 維持 D5;或 (b) 預設走 ahwlan:8095,暫時 AP 只當後備，或乾脆不做。不論選哪個，上傳端點都要限定只收擁有者 session,且 Content-Length 等於 pending 的大小。

### M6. `update/check` 沒有判斷「需要中間版本」(reason 4)與「需要重燒卡」(reason 5)的資料來源

協定要求 check 回報這兩種原因(`219-field-provisioning.md:436-441,446-447`:config.txt、distroconfig、cmdline、p7 不隨 OTA 更新;Pi 3 的韌體白名單要分兩次更新)。但 §3.7.1 的 `release` payload 沒有對應欄位，§3.7.3 的拒絕表只列名稱，沒寫怎麼判斷。
現場後果：一個需要改 distroconfig 的版本(例如 BLE 的 `miniuart-bt`)會被接受。autocommit 的 BLE 檢查只 WARN(`batman-autocommit:506-511`),所以會 commit 一個 BLE 壞掉的版本;BLE 是 3A+ 的管理通道。
**修正**:`release` 加 `? 6: min_from_version`,以及「需要的 boot 設定」(config.txt / distroconfig 的 sha256 清單，或一個 boot-config 世代號);節點拿自己 p1 的值比對，不符 → reason 5。Pi 3 韌體白名單不含新的 `start*.elf` → reason 4。Go 測試每個分支都要有。

### M7. `update-pending` 和結果的狀態機不完整;上傳檔沒有清理者

- 設計寫「commit 或 revert 後由 helper `--boot` 看到結果就刪」。但 helper daemon 每次啟動都會先跑 boot 階段，包括 crash 後的 respawn(`main.go:5-6,525,614`)。revert 之後回到舊槽，舊槽的 helper 開機時就刪了 pending。結果是 app 的 `update/status` 永遠讀不到 5(committed)/ 6(reverted)。要另外留 `update-last {version, result, boot_id}`,保留到下一次 check。
- 兩位擁有者並發：第二次 check 會覆寫正在上傳中的 pending。前一次開機留下的 pending 也能讓人不做新的 check 就 `bulk.open`。修正:pending 綁 `boot_id` 與期限;bulk 開著或已 prepared 時 check 回 `E_BUSY`。
- 上傳完卻沒有 prepare 的 116 MiB 留在 tmpfs(`/tmp/run/batman-provd-bulk/`),擁有權表沒有人負責刪。`bulk.close`、逾時、helper 重啟、provd 啟動時都要刪，由 helper 負責。
- 新動詞(`update.check`、`update.prepare`、`update.apply`、`bulk.open`、`bulk.close`、`diag.read`)屬不屬於 `stateChanging`(試用中 / verdict 閘門 / `finishGated`,`node.go:199-224`),以及 `diag.read` 是否進封閉的唯讀清單(`readonly.go:19-20`),都要逐一列出。

---

## MINOR

1. **擁有者的同意沒有綁定是哪個版本**。`update/prepare`、`update/apply` 是 `op-only-req`(CDDL :96-97),`update/check` 不需要 owner-op。被入侵的 provd 可以在擁有者 prepare 之前，把 pending 換成另一個簽章有效、不是降級的版本。修正:prepare / apply 的 body 帶 `sha256(SHA256SUMS)`,helper 與 pending 比對。
2. **manifest 與 release 的 key 不一致**。CDDL manifest 3 = size、4 = sha、6 = 降級清單;§3.7.1 release 3 = sha、4 = size、5 = 降級清單。「key 1–4、6 必須相同」會有歧義。改成同一套 key,並逐欄寫出對應。
3. **秘密的說法不正確**。bulk passphrase 會 `uci commit` 進 `/etc/config/wireless`(overlay f2fs;04 上這個檔是 `-rw-r--r--`)。hostapd 也會寫 `/tmp/run/hostapd-phy1.conf`(04 上 `-rw-r--r--`,其中有 2 行符合 `wpa_passphrase|wpa_psk`)。改正 §7「只在 Noise 回應裡」的說法;價值低，可接受，但要寫進誠實界線。
4. **版本比較的文法**。04 的版本字串是 `1.5.14-wsl.22+2ecf1cb.fwce20a68`。要定義 `+…` 後綴怎麼處理，以及 channel 之間怎麼搬(rc → release)。「channel 不同 → 拒絕」會讓現場機台永遠換不了 channel。
5. **RAM 預算**。只看 `/tmp` 可用量不夠：沒有 swap,tmpfs 的 size ≠ 可用 RAM(04:tmpfs 3.8G)。還要 `MemAvailable` − 餘裕 ≥ payload 大小。
6. **prepare 是同步的**。它在 ops 上同步執行(最多 `HelperWait 330 s`),同時持有 `n.mu`,這段時間其他動詞都 `E_BUSY`;較慢的板子可能逾時，變成「outcome unknown」。CDDL 已有 phase / percent,建議改為非同步、由 `update/status` 輪詢。
7. **HTTP 的細節**。
   - 分塊回應(一則請求對多則 Noise 訊息)在 `/msg` 回應裡怎麼分框;
   - fake path 在 HTTP 上的行為;
   - 協定 §4.2 要求 HTTP 有冪等快取(32 筆、10 分鐘),設計維持 `E_UNSUPPORTED{idem}`,要寫明這是刻意的偏離與理由;
   - `RoleReacquire`(psk_replay → `claim/replay`)可不可以走 HTTP,要明寫。
8. **診斷包「不含秘密」的測試只檢查檔案在不在**。改成看內容:grep 包內是否出現現行 AP key、mesh key、root 密碼雜湊、bulk passphrase、tag key。
9. **平台矩陣沒有 CM4**(2026-10-23 量產決定)。eMMC 版無法用「只收讀卡機」的轉賣工具重燒;Lite 版要確認 boot 行為。要寫明支援狀態。
10. **prepare 之後放棄**:另一槽(原本的 fallback)已經被覆寫，回不到之前的狀態。這是 A/B 寫入的本質，要寫進誠實界線，app 也要提示。
11. **`update.check` 應先跑 `batman-slot precheck-node`**(試用中、p5 新鮮度、`.txn`、fw override),避免傳完 116 MiB 才在 prepare 被拒。
12. **上傳檔搬移的順序**。provd 擁有的目錄可以被它隨時換掉，所以順序要是：先 rename 進 helper 目錄，再以 `O_NOFOLLOW` 開檔、fstat(regular、nlink 1、uid 471、大小),之後只用 fd 操作。provd 仍可能握著寫入 fd,所以每個使用者都要以自己驗過的副本為準(B2 的修正已涵蓋)。04 的 `fs.protected_hardlinks = 1`、`protected_symlinks = 1`,可引為佐證。

---

## 已查證成立的前提(供作者引用)

- F11:provd 的 init 沒有 netns、沒有 seccomp,capabilities 全空(`files/batman-provd.init`、`batman-provd.json`)。uid 471 可以綁 > 1024 的埠。
- F12:回覆 > 65536 B 就斷線(`provd/helper.go:139-141`)。diag.read 每次 ≤ 48 KiB,在範圍內。
- 8095 在 04 未被佔用(`netstat -tlnp` 只有 uhttpd 的 80 / 443 與 §3.8.2 列的那些)。
- F8:PRESERVE 不含 `disabled` 與 bulk 段(`batman-config-save:40-51`)→ bulk 段不會進 p5 這點成立。
- autocommit 的 health 檔已經帶 `boot_id=` 和 `ts=`(uptime)(04 `/tmp/run/batman/batman-prov.health`),D6 的新鮮度檢查只需要改讀取端。
- `arm` 重跑 `node_checks`(其中含 `p5_freshness_gate` 與 `.txn` 檢查)→ write 到 arm 之間發生的網路變更會在 arm 時被擋下。§3.7.4 步驟 4 必須保留「整個 node_checks」,不能只做部分檢查。

## 給作者的審查方法說明

先從現場流程走(BLE 手機 → check → 換 Wi-Fi 上傳 116 MiB → prepare → apply → trial → 回報結果;mesh 上的隊員與陌生人;斷電),再逐一對原始碼與 04 驗證。B1 與 M1 都是「兩個元件各自正確、合起來衝突」的介面問題:P2 的「Slots = 2 / 有 session 就撤回廣播」配上 P3 的 mesh 級 HTTP;P3 的唯讀 `status` 配上 #202 的 cfgsave.lock 與 OTA 閘門。
