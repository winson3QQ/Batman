# Review A(第 11 輪)— `254-stage1-impl.md` v11(design/254-stage1-impl @ 513977c)

審查者 A,獨立,全程唯讀(04 / 02 只跑 cat/ls/find/blkid/mount/grep/du/command -v;沒有寫入、沒有 reboot)。

## 0. 總評

- **U8 把整套 app 端恢復出廠移掉後,v10 的兩條 MAJOR(A10-M1/M2、B10-M1/M2)確實跟著消失。** 我把 §3 / §4 / §5 / §6 / §8 全文走過:沒有留下 intent、哨兵、`.locked`、W 階段、解凍規則,也沒有任何資源還依賴「重置證據」。§4.1 明寫「沒有任何恢復出廠動詞」,L35–L58 的空號也有交代 ✅。
- **文件確實自足**:我沒有找到任何一處需要回去翻 v1–v10 才能實作的地方。只有 F8 的證據標成「B7 讀 04 ota-trace」,這是前輪審查的編號;我自己在 04 讀過,結果成立(§6)。
- **問題出在 U8 換上來的那個出口本身。** 文件說「重燒卡 = 全清」,F19 和 §4.5 也說「舊 p5/p6 的內容在重燒時被新的檔案系統取代;節點端沒有任何狀態會撐過重燒」。這和實際的 image 與燒卡工具對不上:release image 只有 4218 MiB(p6 200 MiB,第一次開機才長滿卡,#201)。所以在 32 GB 的卡上,舊 p6 約 87% 的區塊根本沒有被寫到。在 04 上,這個範圍裡放著 OTS CA 私鑰、OTS 伺服器金鑰、goatak 資料庫等。下一個持有者拿到 root(unclaimed 的 image 預設是空密碼),用 `dd | strings` 就讀得到。另外,文件引用的燒卡工具不在 repo 裡;repo 裡的 `flash-card.sh` 寫的是上游 OpenMANET 1.8.0 image(M1)。
- 其餘是 MINOR,大多屬於「拿掉恢復出廠以後,上游文件與邊角路徑沒有跟著收」。

**判定:REJECT(窄)— 0 BLOCKER / 1 MAJOR / 9 MINOR。**
M1 的修法只限在轉賣工具、§4.5 文字與 L16 測試,不碰任何共享狀態。M1 修好(或使用者明確接受殘留,並把文字改成實情)後,我預期整份可以 APPROVE-WITH-CHANGES。

## 1. 先補:缺的列 / 資源

| 路徑 / 資源 | 文件現況 | 實際 | 發現 |
|---|---|---|---|
| 重燒卡後 p6 尾端(image 4218 MiB 之後) | 「p5/p6 是新的 ext4、舊資料不被任何程式讀到」 | 舊 p6 的區塊沒被覆寫;#201 長滿後落在新 p6 的空閒區塊,root 讀 raw 裝置就拿得到 | **M1** |
| 「Batman 燒卡工具」 | §4.5 要 app 附下載說明 | `flash-card.ps1` 只在 Desktop、不在 repo;repo 的 `flash-card.sh` 寫上游 1.8.0 sysupgrade image | **M1** |
| 同一個槽上清掉 overlay(`/sbin/firstboot`、LuCI「Perform reset」、`/etc/rc.button/reset` → `jffs2reset -y`) | 沒有這一列 | 04 上三者都在;96 `:159` 的註解自己稱它為「factory-reset (overlay wipe)」 | m6 |
| p6 永久壞 | 沒有這一列 | `prov-state`、`ota-armed.mesh`、`ble-ok` 全部讀不到;96 的 p6 提示也沒了 | m6 |
| p5 永久壞 → `--seed --reformat` | 沒有這一列;§3 說 p5 prov「其他模式不寫、不刪」 | `do_mkfs`(config-save `:152-162,:168-184`)會刪掉 p5 上全部 prov | m5 |
| p5 掛得起、`.seeded` 在,但 `prov.meta` 壞 | 96 的上鎖規則 1、2 都不涵蓋 | 走今天的 4b | m4 |

## 2. Findings

### MAJOR

#### A11-M1 — 「重燒卡 = 全清」不成立:舊 p6 約 87% 沒被覆寫,前任的 tenant 資料(含 OTS CA 私鑰)下一個持有者讀得到;文件引用的工具不在 repo,證據也指錯檔案

**情境(誠實的賣家照 app 指示做)**
1. 賣家的 04 型節點,32 GB 卡,跑 OTS,p6 已長滿卡(04 實測 `p6start=8224768 p6size=54109151 disk=62333952` 磁區)。
2. 賣家照 §4.5 用燒卡工具重燒 release image。image 的版面來自 `build-ab-image.sh:121-133`:`TOTAL_MB = 4016 + P6_MB(200) + 2` = **4218 MiB**,p6 從 4016M 開始,200 MiB。
3. `flash-card.ps1` 是 `Clear-Disk -RemoveData` 之後只寫 image 長度的位元組,讀回也只比對 image 的頭 256 MB 與尾 4 MB。卡上 4218 MiB 之後約 25.6 GiB 沒被寫。⚠️ `Clear-Disk` 是否會清整張卡沒有實測;腳本在它之後只 `Start-Sleep 2`,透過 USB 讀卡機零填 30 GB 至少要幾分鐘,所以推斷它沒有清(要靠下面的負對照定案)。
4. 第一次開機,95 的 #201 把 p6 長到滿卡(`95-batman-storage:186-246`,`sgdisk … -n 6:${pst}:0` + step 3b resize2fs)。舊 p6 的資料區塊變成新 ext4 的**空閒區塊**,內容原封不動。
5. 買家拿到節點:unclaimed 的 image 預設是 root 空密碼(F14),接乙太網就能登入;或者認領後拿到 root 密碼。接著 `dd if=/dev/mmcblk0p6 bs=1M | strings | grep -A40 'BEGIN .*PRIVATE KEY'`,就拿到前任的資料。
6. 04 上這個範圍實際放著(`find /opt/batdata … -name '*.key' …`,原始輸出見 §6):
   - `docker/volumes/ots-appdata/_data/ca/ca-do-not-share.key`(OTS CA 私鑰)、`…/opentakserver.key`、`truststore-root.p12`;
   - `apps/goatak-rc/data/db.sqlite`;
   - 5.2 GB 已用,分散在 25.4 GB 的 ext4 各 block group,大部分在 200 MiB 之外。

**為什麼是 MAJOR**:照文件實作,前任擁有者照我們的轉賣指示做之後,下一個持有者仍能取得前任的 tenant 資料與 OTS CA 私鑰(actor 得利)。拿到 CA 私鑰就能簽出前任隊伍 EUD 信任的伺服器憑證。觸發不需要任何故障,也不需要鑑識工具;文件把這個殘留歸到「磨損平均」,低估了它。前幾輪的設計把「前任殘留在 p6 的資料」當成要保護的資產(v10 審查 B10-M1 的情境就是在保護它),v11 換了出口,這項保護不見了,文件卻寫成已經全清。

**另外三個事實錯誤(同一條修)**
- F19 引的 `build-gpt-ab-card.sh:133-134` 不是 release image 的 builder。它是 bench 上就地重切分割的腳本(`DEV=/dev/mmcblk0`、`EXPECT_SECTORS=62333952` 互鎖、`SRC` 要求還原 `p3-batdata`)。release image 是 `build-ab-image.sh:197-199`。
- `flash-card.ps1` 不在 repo(`git ls-files | grep -i flash` 只有 `scripts/flash-card.sh`、`flash-write-guard.sh` 與兩份 docs),沒有版本、沒有 CI,也沒有列在 §10 的任何 PR。
- repo 的 `scripts/flash-card.sh` 寫的是 `openmanet-1.8.0-rpi4-…-sysupgrade.img.gz`(`:20-22`),不是 A/B image;`docs/flashing-and-recovery.md` 也是同一套。照「Batman 燒卡工具」去找,使用者找到的是錯的 image,而且舊 p5(prov、owner 金鑰、overrides 裡的 mesh SAE key)完全沒被碰到。

**修法**(不重開 U8,只把「重燒」定義成真的全清;擇一或並用)
1. **節點端,建議**:#201 長 p6 的那次開機(只在剛燒的卡上發生),在 resize2fs **之前**,先把 p6 舊尾端到卡尾的區段清掉。可以用 `blkdiscard`,也可以零填。`blkdiscard` 目前沒進 image(firmware `.config`:`# CONFIG_PACKAGE_blkdiscard is not set`;04 `command -v blkdiscard` → MISSING),要加進 image。04 的卡 `discard_max_bytes=170519429120` 有支援,但 SD 的 discard 不保證讀回是 0,所以清完要抽樣讀回;不是全 0/全 1 就退回零填,或者在 `halow-status` 與 app 標「前任資料可能殘留,請換卡」。這個做法對任何燒卡工具(Imager、Etcher、dd)都有效。
2. **主機端**:把燒卡工具收進 repo(Windows `.ps1` + Linux/macOS),寫的是 release A/B image。「轉賣模式」預設零填到卡尾,並抽樣讀回卡尾。列進 §10 的某一個 PR。
3. 不論選哪一個:
   - §4.5 和 F19 改成實情;
   - app 的轉賣頁把「換一張新卡」列為首選;
   - 若使用者選擇不修,就要明確接受,並在誠實界線寫明「舊 p6 約 85% 以上的區塊會留在卡上,root 讀得到」。

**負對照**(bench 就做得到,不一定要到現場)
1. 在一張用過的卡的 p6 高位址寫 1 GiB 的 `BATMAN-RESIDUE-<rand>` 樣式;
2. 照文件指示重燒並開機一次;
3. `dd if=/dev/mmcblk0p6 bs=1M | grep -c BATMAN-RESIDUE-<rand>` 必須是 0。

用今天的 `flash-card.ps1` + release image,預期結果 > 0(修法前 FAIL)。這一條要併進 L16 的驗收。

### MINOR(標 **PR-x 必帶** 的在對應 PR 一定要處理)

**A11-m1 — L16「p5/p6 UUID(`blkid -p`)都換了」不是有效判據** — PR-H1 / L16 必帶
- `build-ab-image.sh:198-199` 在建 image 時 `mkfs.ext4` 且沒有 `-U`,所以 UUID 固定在 `.img` 裡;PARTUUID 本來就是固定的(04:`3276af79-0000-4000-8000-00000000000{5,6}`)。
- 原本就是用同一份 `.img` 燒的卡,重燒後 UUID 相同 → 假 FAIL。從 bench 卡換到 `.img` → 必然 PASS,沒有鑑別力。
- 改成斷言內容:`--prov-get` 回 rc 7、新 `device_id` ≠ 舊值、M1 的殘留樣式 = 0。

**A11-m2 — 上游文件拿掉恢復出廠的範圍,比 §1.3 / §10.2 列的多** — docs PR 必帶
- §1.3 只列了 219 §7,但下面這些地方都還依賴 `reset` / 恢復出廠:
  - 協定:`219-protocol.md:148`(冪等鍵清單含 `reset`)、`:160`(`E_VERSION` 時手機「只允許 `info`、`status`、`reset`」)、`:199`(`reset` level leave/factory);CDDL `:93,:127,:286-288`;
  - 219:`:57,:150,:325`(版本不合時只允許查狀態與恢復出廠)、`:130,:138,:139`(任務表:恢復出廠 / 換手機 / 轉賣 = 恢復出廠後交出含 QR)、`:333-334`、`:541`(daily-validation 的「恢復出廠」)、`:557`(S6)。
- 要寫明三件事:
  - 階段 1 provd 對 `reset` 回什麼:建議 `E_UNSUPPORTED`,不要回 `E_SCHEMA`,讓 app 能顯示重燒說明;
  - `reset level=leave` 與本文件的 `network/leave` 是什麼關係;
  - 版本不合時的逃生口改成「查狀態 + 重燒說明」。

**A11-m3 — 文件說「重燒前不需要做任何事」,這只對節點本身成立** — PR-P3 必帶(app 轉賣 / 遺失頁)
1. 已認領的節點,擁有者沒有 SSH key(U3:認領不裝 key)時,沒有任何匯出 p6 資料的路徑。OTS 的任務紀錄要保留(現場需求是任務檢討要還原全部紀錄),重燒前得先用讀卡機備份 p6。手機遺失時,唯一出口也是重燒(L29 `owner.replace` 在 S3),同樣要先備份。
2. 這台若是網路成員,轉賣前應該先從網路移除,不然網路的成員名單會留一筆死成員。
3. 機身 QR 已經失效(U4),新 QR 要用 root 跑 `batman-provhelper qr` 取得。app 要把這一步講清楚,不然買家拿舊 QR 會一直 `E_FORBIDDEN`。

**A11-m4 — 96 的 fail-secure 有缺口:p5 掛得起、`.seeded` 在,但 `prov.meta` 壞** — PR-P1 必帶
- 規則 1 要求讀得到 meta;規則 2 只涵蓋 `:64/:67/:71/:89` 這幾個掛不起的出口。fresh overlay(OTA)遇到 meta 壞時,兩條都不成立 → 走今天的 4b(`96:158-176`)。
- 這時 claimed 節點若沒有 SSH key → `UNPROVISIONED`,`ttylogin` 停在 image 預設,直到 S89 helper 判 `unknown(prov-corrupt)` 並依 p6 提示上鎖。這段期間,以及 helper 起不來時一直到修好為止,serial(GPS 口 console,#105)可以直接拿到 root shell。
- 修法:規則 2 改成「p5 讀不到,**或** `prov.meta` 存在但驗不過」都看 p6 的 `last_known_state`。
- 白箱:把 `prov.meta` 的 sha 弄壞,p6 = claimed,OTA 後 S10 就是 `ttylogin=1`。

**A11-m5 — p5 prov 不只一個刪除者;rc 9 的語意要寫清楚** — PR-P1 必帶
- `--seed`(p5 非 ext4 時)與 `--seed --reformat` 都會呼叫 `do_mkfs`(config-save `:152-162,:183-184`),把 `prov.*` 與 `identity/prov/` 一起清掉,和 §3「其他模式不寫、不刪」矛盾。
- 清掉之後,helper 下次開機看到的是 rc 9(seeded、無 prov)。§4.2 把 rc 9 標成「legacy 升級」,實作的人很容易寫成「overlay 完整 → 補 persist identity」,而 claimed 的 `prov.cbor` 沒有被補回去;萬一寫成 `prov{legacy}`,就等於把擁有權洗掉了。
- 修法:
  - §3 列出 `do_mkfs` 是刪除者;
  - rc 7 / rc 9 遇到 overlay 有 `prov.cbor` 時,一律以 overlay 為準整份重新 `--prov-only`(prov + identity);
  - 加一列生命週期「p5 壞 → `--seed --reformat`」與測試:claimed 節點 reformat 之後 reboot,p5 `prov.meta` 是 `state=claimed`。
- 目前擋住 OTA 的,是 `--check` 的 prov stale → precheck 拒絕,這一點正確 ✅。

**A11-m6 — 生命週期少兩列:同槽清 overlay、p6 壞** — PR-P1 必帶(測試可以放 tier B)
- **同槽清 overlay**:04 上有 `/sbin/firstboot`、LuCI(`/usr/lib/lua/luci`),以及 `/etc/rc.button/reset`(`released` 且 `SEEN≥5` → `jffs2reset -y`)。賣家很可能把 LuCI 的「Perform reset」當成轉賣全清。
  - 預期行為:96 重跑 → 抄 p5 prov → 上鎖;helper 從 p5 還原 identity;擁有權不變。這是 fail-closed,但要寫成一列並測。
  - app / 說明書要寫「LuCI 重置不是轉賣全清」。
- **p6 永久壞**:`ota-armed.mesh` 不在 → 當成 `joined` → member 單台在家更新要求鄰居,會 revert(L31 失效但安全);`ble-ok` 不在 → 只 WARN;96 的 p6 提示不在。以上都要寫進矩陣,讓實作的人知道這是預期行為。

**A11-m7 — 兩個介面有寫者、沒有讀法** — PR-P1 必帶
- `/etc/.batman-prov-restore`:§3 說 helper 會讀,但全文沒有一處規定 helper 拿它做什麼(v10 `:107` 也一樣)。不需要就刪掉;需要就寫契約(格式、boot_id 不符怎麼辦)。
- `batman-provhelper --persist-now`:§4.3 的 `P5_STALE_HINT` 叫操作員執行它,但 helper 的模式清單(`--boot`、`--apply-state`、`--firstboot`、`qr`)裡沒有它。要定義:root-only、在 trial 上怎麼處理、rc 意義。

**A11-m8 — §8「RPA」防追蹤沒有證據** — PR-F / PR-P2
- spike 留言只證明 iPad 這一端用 RPA(「iPad 以新 RPA 再連入」),沒有證明節點廣播的位址是 RPA、而且會輪替。
- 要加一列 D:用 02 central 或手機抓 15 分鐘以上的 adv 位址,斷言最高兩位元 = `01`(RPA)且位址會變;負對照是把 `Privacy=off` → 位址固定。

**A11-m9 — F8 的證據寫成前輪編號「B7」** — docs
- 我在 04 直接讀過,內容成立(§6)。請改成貼原始行,符合「自足」。

## 3. 指定重點逐項

| 情境 | 結論 |
|---|---|
| legacy 02/04 第一次 OTA 到本 image | ✅ L17 成立。config-save 的 `same_identity` 只比 stage 裡有的檔(`:319-323`),`cp -a` 是加法(`:390`),所以 trial revert 回 1.5.12 時,舊程式不會刪 p5 的 prov(L12 的說法有原始碼支持)。02 沒有 `core_freq_min`(實測 `[pi4]` 只有 `miniuart-bt`)→ `ble-ok` 不會寫 → 只 WARN,不會因此 revert ✅ |
| 買家在弱 BLE 下認領 / 認領回應遺失 | ✅ `psk_replay` + `claim/replay` 自足,app 契約(先持久化 `node_cert` 與 claim-pending)有寫 |
| 單一擁有者在家更新 | ✅ L31 / L51;p6 壞時退化成要求鄰居(m6) |
| team OTA | ✅ L40 |
| p5 / p6 死掉 | 大致 fail-closed;m4、m5、m6 |
| BLE 路人 | ✅ 未交握只給 `status/public`;已認領節點失敗 PSK 送假第 2 則;RPA 待證(m8) |
| 轉賣 = 重燒 | **M1**;使用者流程缺口見 m3 |
| 遺失擁有者金鑰 / 手機 | 出口 = 重燒(安全),但要先備份 p6(m3);網主手機遺失 = 整網每台重燒,這是既有界線(S3) |

## 4. 逐 actor

- **前任擁有者**:重燒後拿不回控制權 ✅(新 identity、p5 被覆寫、`authorized_keys` 是新的)。
- **下一個持有者(買家)**:能讀到前任殘留在 p6 的資料 → **M1**。
- **本機非 root**:`/opt/batdata/state` 是 root 0755(04 實測),動不了 96 的 p6 提示 ✅。
- **攻陷的 provd**:helper 的重算與 owner-op 不受 U8 影響 ✅;誠實界線照舊。
- **實體(GPS 口 serial)**:m4 的視窗。failsafe 已由 `pi_preinit_no_failsafe="y"` 關掉(04 `/lib/preinit/00_preinit.conf:13`)✅;只剩 cmdline 的 `failsafe=`,那要改 boot FAT,屬於持有 SD 卡的 actor。
- **持有 SD 卡**:擋不住(既有界線)。
- **供應鏈**:不變。
- **我們自己**:燒卡工具不在 repo、指到錯的 image(M1)。

## 5. 使用者已定案事項的後果(不重開,只列)

- U8:轉賣與手機遺失都要讀卡機與電腦,而且會丟 p6 資料;app 不能自助完成。
- U4:重燒後 hostname / SSID 不變,前後兩任可以被串連(已列殘項)。
- U3:擁有者沒裝 SSH key 時,只有拔卡才拿得到 p6 資料(m3)。

## 6. 唯讀探針原始輸出摘要(✅ 實測)

04(10.41.1.3):
```
blkid: mmcblk0p5 UUID="9af5c61f-…" PARTUUID="3276af79-0000-4000-8000-000000000005"; p6 UUID="254e7c3f-…" PARTUUID="…000000000006"
p6start=8224768 p6size=54109151 disk=62333952        (p6 從 4016 MiB 開始,到卡尾)
df /opt/batdata: 25.4G size, 5.2G used
/opt/batdata/docker 11.7G, apps 1.1G
find: …/docker/volumes/ots-appdata/_data/ca/ca-do-not-share.key
      …/dv289-backup-20261016-195913/ca/certs/opentakserver/opentakserver.key
      /opt/batdata/apps/goatak-rc/data/db.sqlite
fstrim: MISSING  blkdiscard: MISSING  debugfs: MISSING  tune2fs: not found  resize2fs/e2fsck/strings/dd: present
/sys/block/mmcblk0/queue/discard_max_bytes = 170519429120
/sbin/firstboot 存在;/etc/rc.button/reset: SEEN>=5 → "jffs2reset -y && reboot"; /usr/lib/lua/luci 存在
/lib/preinit/00_preinit.conf:13 pi_preinit_no_failsafe="y"
/opt/batdata/state: drwxr-xr-x root root
ota-trace.log:1514 "S1 CHECK rc=0 caller=/bin/sh /sbin/sysupgrade -n … upg=n"
ota-trace.log:1515 "S1 CHECK rc=0 caller=/sbin/procd … upg=y"   (14 s 後;F8 成立)
```
02(10.41.1.1):slot B,`[pi4]` 只有 `dtoverlay=miniuart-bt`(沒有 `core_freq_min`),`authorized_keys` 1 行,lock-status = UNPROVISIONED。

原始碼:
- `build-ab-image.sh:121-133`(`TOTAL_MB=4016+P6_MB+2`、`-n 6:4016M:+${P6_MB}M`)、`:197-199`(mkfs 沒有 `-U`);
- `build-gpt-ab-card.sh:1-20`(bench 重切分割 + 還原資料);
- `flash-card.sh:20-22`(上游 1.8.0);
- `flash-card.ps1`(只寫 image 長度,讀回頭 256 MB / 尾 4 MB);
- `95-batman-storage:186-246`(#201 長 p6);
- `batman-config-save:152-184`(`do_mkfs`)、`:319-323,:390`;
- `96:62-93,:158-176`;
- firmware `.config`:`# CONFIG_PACKAGE_blkdiscard is not set`、`# CONFIG_PACKAGE_fstrim is not set`。

⚠️ 推斷、未實測:`Clear-Disk -RemoveData` 不會清整張卡(手邊沒有卡,沒跑);M1 的負對照會定案。
❌ 沒做:任何寫入節點或卡片的實驗。

## 7. 判定

**REJECT(窄)— 0 BLOCKER / 1 MAJOR / 9 MINOR。**
- M1 修好(或使用者明確接受殘留,並把 §4.5 / F19 改成實情、加上負對照)後,整份可以 APPROVE-WITH-CHANGES。
- PR-P1 必帶:m4、m5、m6、m7。
- docs PR 必帶:m2、m9。
- PR-P3 必帶:m3。
- PR-H1 / L16 必帶:m1。
- PR-F / P2:m8。
