# #254 階段 1 實作設計 v11 — 審查 B(第 11 輪)

審查對象:`docs/design/254-stage1-impl.md` @ `design/254-stage1-impl` 513977c(471 行)。全程唯讀:只讀原始碼、`git`(WSL)、02/04 上的 `cat`/`ls`/`blkid -p`/`vcgencmd bootloader_config`/`command -v`/`df`/`du`。沒有寫節點,沒有 commit。

**判決:REJECT(範圍窄)— 0 BLOCKER / 2 MAJOR / 6 MINOR。**

非轉賣的部分(BLE、認領、replay、交易、OTA 閘、96 上鎖、sysupgrade 程序判定)我抽查過,和前幾輪收斂的內容一致,這一輪不再翻案。兩條 MAJOR 都出在 U8 留下來的那一條出口上。U8 把「重燒卡」當成轉賣時全清的唯一手段,但 v11 對這條路徑的寫法有兩處和實際行為不符:

- 重燒後,前任的資料**用 `dd` 就讀得到**(M1)。
- 前任擁有者重燒後仍保有 SSH 存取(M2)。

兩條都不需要把恢復出廠加回來。修法是:把燒卡工具定成契約、在 image 裡關掉兩個上游 hook、補上買家端的說明,外加兩個負對照。

---

## MAJOR

### M1 — 照現有工具重燒,舊 p6 大部分仍可直接讀回;F19「舊資料不被任何程式讀到」和 §4.5「沒有任何狀態會撐過重燒」不成立

**情境**:擁有者照 app 的說明重燒。卡是 32 GB(04 實際的卡,`SN32G`),之後交給買家。買家拿到後是自己節點的 root:unclaimed 時乙太網空密碼可登入,認領後也拿得到 root 密碼。

**證據**:
- A/B image 的大小 = `TOTAL_MB=$(( 4016 + P6_MB + 2 ))`,其中 `P6_MB=200`(`scripts/build-ab-image.sh:30,121`),也就是約 4218 MiB。重燒只會覆寫這個長度。
- 04 的 p6:`PART_ENTRY_OFFSET="8224768"`(= 4016 MiB)、`PART_ENTRY_SIZE="54109151"`,檔案系統 25.4 G、已用 5.2 G(`df`)。內容包括 `docker/` 11.7 G(OTS:`apps/opentakserver`,含 OTS CA / 使用者私鑰與任務資料)、`wireless.H4.bak`(含 `key` 的 wireless 備份,2 行)、`dv289-backup-*` 等。
- 結論:從 4218 MiB 到卡尾約 25 GB 的舊 p6 區塊,**在邏輯層完整保留**。95 第一次開機會把 p6 長到滿卡,`resize2fs` 也不會清這些區塊。新的 ext4 有新的 UUID 和 csum seed,所以「任何程式都不會把它們當檔案讀」這點成立;但對 root 來說,`dd if=/dev/mmcblk0p6 | strings` 或 photorec 就能讀出來。這不屬於「磨損平均下鑑識才讀得回」(§4.5 誠實界線的說法),只是普通的未覆寫。
- `flash-card.ps1:11` 的 `Clear-Disk -RemoveData` 只是刪分割資訊,不會把整張卡寫一次零(⚠️ 推論:32 GB 卡幾秒內就完成,不可能全寫;要由下面的負對照證實)。`:30-33` 也只比對 image 長度內的頭 256 MB 和尾 4 MB。
- 「Batman 燒卡工具」沒有被定義:
  - `flash-card.ps1` **不在 repo 裡**。`git ls-files | grep -i flash` 只有 `scripts/flash-card.sh`、`flash-write-guard.sh` 和兩份 docs;ps1 是使用者桌面上未追蹤的檔案(10-16)。
  - repo 唯一的燒卡工具 `scripts/flash-card.sh` 不帶參數時,會下載**上游 OpenMANET 1.8.0** 的單槽 image(`:20-22,52-58`),只清 p2 overlay。用它「重燒」時,舊卡位於 3504 MiB 的 **p5 整個保留**:`identity/prov/node.key`、`ecdh.key`、`claim.secret`、`prov.cbor`(owner tag key、`net_secrets`;解它要的 `ecdh.key` 也在同一張卡)、`overrides.uci`(明文 mesh SAE key)。只要 `losetup -o $((3504<<20))` 就能掛起來。
- F19 引用的 `build-gpt-ab-card.sh:133-134` 是「把**實體裝置**就地轉成 A/B」的腳本。它最後還會 `rsync` 備份資料回 p6(`:200-206`),不是做發行 image 的腳本;發行 image 是 `build-ab-image.sh:198-199`(見 m1)。
- §4.5 建議「最安全是換一張新卡」,但沒說舊卡怎麼處理。舊卡是**完整**的秘密庫(p5 明文)。

**誰得到什麼**:買家(或撿到舊卡的人)可以讀到前任的 OTS 任務紀錄、TAK CA / 使用者私鑰,以及操作員放在 p6 的任何備份。用上游工具重燒時,還包括 p5 的身分私鑰、網路秘密和 mesh key,也就是能冒充前任的隊伍。

**修法**(都在 U8 範圍內):
1. 燒卡工具寫成契約,並放進 repo(PR-P3 或 harness / tools PR):
   - 「轉賣模式」先把**整張卡**寫零(Windows 用 `diskpart clean all`,或逐 MB 寫零到卡尾;32 GB 約 20–30 分鐘),再寫 A/B image;
   - 驗證段加上:隨機抽樣 image 長度之外的區段,必須全為 0;
   - 只接受 A/B image(p5/p6 的 PARTUUID 要是 `3276af79-…-000000000005/6`),拒絕上游單槽 image。
2. §4.5 與 F19 改寫:
   - 「一般重燒」只保證新的檔案系統和新身分;
   - 「轉賣重燒」才保證邏輯層清除;
   - 誠實界線分成兩層:邏輯層由工具保證;磨損平均下的殘留擋不住,要換新卡。
   - 換新卡時,舊卡要用同一個轉賣模式清掉,或實體銷毀。
3. 「重燒前要不要先做任何事」改寫為:若要保留任務資料,先備份 p6;可選擇先跑 `payload-teardown <t> --zeroize`。
4. **負對照**(不必到現場,WSL loop 檔就能做):
   - 建一個 32 GB 的 loop 檔當「舊卡」;
   - 用 `build-ab-image.sh` 放一份 image,再在 p6 偏移 > 4218 MiB 的地方寫入特徵字串;
   - 用現行的 Clear-Disk + 寫 image 流程「重燒」,掃描 loop 檔 → **找得到**(現況 FAIL);
   - 用轉賣模式重燒 → 0 筆(PASS)。
   - 另做一個 flash-card.sh 上游 image 的版本:p5 在 3504 MiB 仍可掛 → 工具必須拒絕。
   - L16 到現場時,再用實卡重跑一次。

### M2 — 前任擁有者在重燒後仍保有 root SSH:EEPROM 的 `dropbear_authorized_keys` / `device_password` 撐得過重燒,而買家沒有被要求自己重燒

**情境**:前任擁有者(惡意)在交機前,用標準的 Raspberry Pi bootloader recovery 卡,把 `dropbear_authorized_keys=<自己的 key>`、`device_password=<自己的密碼>` 寫進 Pi 4 EEPROM 的 bootloader config。這不需要節點上的工具,也不需要 root,只要實體接觸;前任本來就擁有機器。之後他照 app 的說明重燒,把節點賣出。

**證據(04 唯讀)**:
- `/rom/etc/uci-defaults/31_dropbear_persistent_storage`:沒有 `/sysupgrade.tgz` 時(Batman 的 A/B OTA 用 `sysupgrade -n`,第一次開機也沒有),執行 `authorized_keys="$(persistent_vars_storage.sh READ dropbear_authorized_keys)"`,有值就寫進 `/etc/dropbear/authorized_keys`,並設定 `PasswordAuth=off`。
- `/rom/etc/uci-defaults/31_password`:同樣條件下,讀 `device_password` 後用 `passwd root` 設定。
- `/sbin/persistent_vars_storage.sh` 的 READ 就是 `vcgencmd bootloader_config | grep "$key="`。節點上的 WRITE 未實作(「isn't implemented on bcm2711」),但 EEPROM config 本來就能從 recovery 卡寫入,所以節點端寫不了並不能擋這條路。⚠️ 用 recovery 卡寫入自訂 key 我沒有實機驗證,只是從 rpi-eeprom 的 config 是純文字推論。
- 04 目前 `vcgencmd bootloader_config | grep -ci dropbear` = 0,只有 `BOOT_UART`、`WAKE_ON_GPIO`、`POWER_OFF_ON_HALT`、`NET_INSTALL_AT_POWER_ON`。
- 重燒後第一次開機:31_* 在 S10 早於 96 執行,把前任的 key 裝進 overlay。96 看到未 seed 的 p5 → 照今天的 4b(`has_key && has_pw` → LOCKED)。節點仍顯示 `unclaimed`。買家認領時,U3 規定認領**不碰 `authorized_keys`**;`ssh_keys.set` 也只動 `ssh_keys.added` 上的行,所以 app 看不到也刪不掉這把 key。之後每次 OTA(fresh overlay),31_* 都會再裝一次。
- 這一點在 v7-B m11 已經提過,v8 §4.5 的誠實界線也寫了一行,並要求 L16 斷言 EEPROM 裡沒有 `dropbear`。**v11 改成自足版時把它刪掉了**:`grep -i "eeprom\|persistent_vars\|31_dropbear" 254-stage1-impl.md` → 0 筆。這是「只存在舊版」的內容遺失。U8 之後重燒是唯一的出口,它從殘留風險升格成「出口本身被繞過」。
- 第二個缺口:§4.5 只告訴**賣方**怎麼做,§8 的「前任擁有者 → 重燒卡」也假設前任會配合。買家沒有被要求自己重燒,但他無法驗證賣方重燒過:
  - 前任有 root 時,可以把 overlay 和 p5 改成 `unclaimed` 再留下 key;
  - legacy 節點(既有 fleet 的形態)沒重燒就賣出時,legacy 認領**刻意不清**既有 key(L18),而且防呆門正是靠前任那把 key 才放行。

**誰得到什麼**:前任擁有者在買家節點上保有持續的 root SSH;節點入網後,經 mesh / AP 都到得了。

**修法**:
1. image 端(PR-F / PR-P1):Batman image 把 `31_dropbear_persistent_storage`、`31_password` 改成不採用 EEPROM 值(移除,或 overlay 成 no-op 並 log WARN「EEPROM 有 `dropbear_authorized_keys`/`device_password`,已忽略」)。擁有權和 SSH 由 Batman 自己的模型管,上游這兩個 hook 是多出來的寫者:它們寫 `authorized_keys` 和 shadow,違反 §3「一個資源一個寫者」(`authorized_keys` 的寫者清單裡沒有它們)。
2. §3 的 `/etc/dropbear/authorized_keys`、shadow 寫者表補上「上游 31_*:Batman image 停用」。
3. §4.5 / §8:
   - 補一列「買家」:**收到二手機台一律自己重燒(用 M1 的轉賣模式),並把 EEPROM 重設成官方預設**(rpi-eeprom recovery);
   - 誠實界線寫明:EEPROM(含 `BOOT_ORDER` / 網路開機)不在重燒範圍,沒有 secure boot 時,階段 1 擋不住會改 bootloader 的實體前任。
4. 可選(與 U3 相容,唯讀):認領回應或 app 的機台頁顯示「`authorized_keys` 中有 N 行不是由 app 加的」(只列指紋,不刪)。
5. **負對照**:
   - 白箱在測試 image 上把 `persistent_vars_storage.sh` 換成固定回傳一把 key 的版本(模擬 EEPROM 有值),fresh overlay 開機:現行 rom → `authorized_keys` 有該行(FAIL);修正後 → 沒有,且有 WARN log(PASS)。
   - 再補一個實機版本:bench 用 recovery 卡寫 EEPROM 後重燒。
   - L16 斷言 `vcgencmd bootloader_config | grep -c 'dropbear\|device_password'` = 0。

---

## MINOR

**m1 — F19 / D23 引用的原始碼錯了**
- `build-gpt-ab-card.sh:133-134` 是就地重新分割實體卡的腳本,而且會把舊資料 rsync 回 p6。發行 image 的 mkfs 在 `build-ab-image.sh:198-199`。
- `flash-card.ps1` 不在 repo,F19 的「原始碼」證據指向一個未版本化的檔案。
- 修法:改引用,並把 ps1 收進 repo(M1)。

**m2 — L16 的斷言「p5/p6 UUID(`blkid -p`)都換了」沒有鑑別力**
- PARTUUID 是常數 `3276af79-0000-4000-8000-00000000000{5,6}`(`build-ab-image.sh:40-45`;02、04 `blkid -p` 都一樣)。
- 檔案系統 UUID 在**建 image 時**就固定了(`mkfs.ext4` 沒帶 `-U`;02 和 04 的 p5 UUID 不同,只是因為來自不同次 build)。
- 所以:用同一個 `.img` 重燒,UUID 不會變,斷言會 FAIL,即使清除成功;用不同 build 重燒,不管清沒清都 PASS。
- 修法:改成 M1 的特徵字串掃描,加上身分斷言(新 `device_id`、helper log rc 7、`identity/` 是新產生的)。PR-H1 要求。

**m3 — 生命週期少一列「擁有者遺失手機 / 擁有者金鑰」**(只有 1 位擁有者;`owner.replace` 在 S3)
- 實際出口只有重燒,而 p6 的任務資料(OTS)會跟著消失。現場情境要求任務檢討能還原全部紀錄,所以說明要寫重燒前的備份方式:
  - 用 Linux 讀卡機掛 p6(Windows 不能讀 ext4);
  - 或若曾 `ssh_keys.set`,用 key 登入 `scp`。
- 不需要新機制,補一列 L 和 app 說明即可。PR-P3 要求。

**m4 — 上層文件和協定還留著恢復出廠的介面,docs PR 的清單只寫了 219 §7**
- `219-protocol.md:160` major 不同時「只允許 `info`、`status`、`reset`」、`:199` `reset{level: leave/factory}`;CDDL `:93,127,286-288` 的 `reset-level 1 = factory reset`。
- `219-field-provisioning.md:57,130,139,150,325,333,511,541`(轉賣 = 恢復出廠後連 QR 一起交出、按鍵開窗口、版本不符只能恢復出廠、daily-validation 測恢復出廠)。
- 另外,provd 收到 `reset` 型別時的回應沒有定義:§4.1 只說 helper 沒有這個動詞。
- 修法:協定 v0.7 對 `reset{factory}` 回 `E_UNSUPPORTED`(或刪除該型別),版本不符的後備清單拿掉 `reset`;`level=leave` 對應 `network/leave` 的 owner-op,或刪除。docs PR 與 PR-P2 要求。

**m5 — 買家拿到重燒後的機台,沒有可照做的步驟**
- §4.5 寫了「新的 QR 需由 root 取得(`batman-provhelper qr`,經乙太網或 serial)」,但 app 的轉賣頁只對賣方說話。
- 若賣方用舊版 A/B image 重燒(例如 1.5.12 的 `ab-fleet.img`),p5 未 seed → #202 閘(F12)擋 OTA,要先 setkey seed,升級後變成 legacy → 認領還要過防呆門。
- 修法:轉賣頁和說明書要寫:image 版本 ≥ 階段 1;重燒後如何以乙太網 `ssh root@…` 加 `batman-provhelper qr` 取得 QR(或賣方在重燒後立即取 QR 交給買家;此時賣方也持有新 QR,買家應立刻認領,或依 M2 自己重燒)。
- 買家掃到已認領的機台時,app 應提示「已被認領,二手機台請重燒」:已認領節點不帶 `device_id` 末碼,app 能推得出來。PR-P3 要求。

**m6 — 自足化留下的小殘留**
- `prov-tools-254` 仍斷言 `mkfs.ext4`、`hexdump`(§9),但 v11 已經沒有使用者(原本是恢復出廠的 p5 mkfs)。缺了會造成無謂的 FAIL;刪掉,或註明用途。
- §13 說「全部移除」,但 L57(app 被殺後 replay)其實是併進 L34,不是被移除;只是用語問題。

---

## 有查、沒問題的(附證據)

- **95 處理重燒卡 p6 的方式**:新 image 的 p6 有 ext4 magic → `has_fs` → 「already has a filesystem — keeping it」(`95-batman-storage:332`)→ 1b 用 `sgdisk -e -d 6 -n 6:${pst}:0`,起點不變、長到滿卡(`:192-258`)→ 3b `e2fsck -pf` + `resize2fs`(`:350-357`)→ 上線後再做一次 online resize(`:627-629`)。
- 舊檔案系統不會被復活:新 superblock 已經覆寫在同一個起點,`recover_ext4` 的備份 superblock(`-b 32768` = 128 MiB)落在新 image 的 200 MiB 之內,是新 fs 的備份。所以檔案層面沒有舊資料回流;問題只在原始區塊(M1)。
- 04 的 p6 起點 8224768 = 4016 MiB,與 image 一致。
- 重燒後 p5:image 內整段 512 MiB(含零)會被 `flash-card.ps1` 逐位元組寫入,在邏輯層覆寫(只限 A/B image,見 M1 的上游 image 例外)。
- 重燒後第一次開機的狀態推導(96 `:93` 未 seed、helper rc 7 → unclaimed、#202 閘 prov-aware)與 §4.2 / §4.3 / L44 一致。
- 恢復出廠機制的移除:§4.1 沒有任何恢復出廠動詞;`.factory-reset`、`resetting`、`intent`、`W*` / `F*`、`jffs2reset` 在 v11 都找不到(grep 0 筆);v10 被移除的 L 列逐列核對過,都是恢復出廠專屬,只有 L46(dropbear 重啟)和 L57 被併進 L27 / L34。
- 前幾輪的非恢復出廠內容抽查(§4.1 授權、§4.2 rc 表、§4.4 交易、§6.4 OTA 閘、96 上鎖出口清單)與 v10、v5 一致,沒有遺漏。

## PR 要求彙整

| 項 | PR |
|---|---|
| M1 轉賣模式燒卡工具進 repo + 全卡寫零 + 拒絕上游 image + loop 檔負對照 | PR-P3(工具)/ PR-H1(負對照);§4.5、F19 文字改在 v12 |
| M2 停用 31_dropbear_persistent_storage / 31_password 的 EEPROM 採用 + 白箱負對照 + 買家須知 + L16 EEPROM 斷言 | PR-F 或 PR-P1;§3、§4.5、§8 文字改在 v12 |
| m2 L16 斷言改寫 | PR-H1 |
| m4 協定 / 219 去掉 reset | docs PR、PR-P2 |
| m3、m5 app 說明 | PR-P3 |
| m1、m6 | v12 文字 |
