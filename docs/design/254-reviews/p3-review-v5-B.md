# #254 PR-P3 設計 v5 — 審查 B

審查對象:`docs/design/254-p3-impl.md`(feat/254-p3 @ 1ac5fbd,base main 2ecf1cb),整份。
方法:從現場用法出發(BLE 擁有者手機、剛認領節點 AP 配對、經自己 AP 上傳 ~126 MB、mesh 上 TAK、斷電、Pi 3A+/CM4),逐項對 source(repo、firmware-2710 build_dir)與 04 唯讀實測核對。04 上只跑了唯讀指令(`ubus call service list`、`/proc/*/status`、`uci show`、`nft list tables`、`ls`、讀 fw4 模板),沒有寫入任何檔案。

**判定:REJECT(範圍窄)。0 BLOCKER、4 MAJOR、14 MINOR。**
依使用者規則「有 MAJOR 未關就改設計、整份再審」。4 個 MAJOR 都是局部修正(每個幾行),不需要新的子系統;其中兩個(M1、M2)是**寫成文字的機制在真機上不成立**,實作照抄就會壞,所以不能放到實作時再處理。

---

## MAJOR

### M1. 防火牆規則 `iifname != "phy*-ap*"` 在 nft 裡不是萬用字元比對 → 連手機 AP 的 client 也被丟,HTTP(上傳與備援)完全連不上
- **情境**:照 §3.8.1 安裝 `ruleset-post/batman-http.nft`。nft 只把**最後一個** `*` 當萬用字元(前綴比對);中間的 `*` 是字面字元。`"phy*-ap*"` = 前綴字面 `phy*-ap`,不會等於 `phy1-ap0` → `!=` 對所有 port 都成立 → 所有往 8095 的 TCP 都被丟。helper 的檢查(表、鏈、drop 規則都在)會通過,所以 provd 照樣 bind,但沒有人連得上。fail-closed,但 D15 的核心功能(上傳、備援)整個失效;§3.11-2 的「經 mesh 轉來被丟」與「自己 AP 上可以」在這條規則下無法區分。
- **證據**:nftables 1.1.1 `src/evaluate.c:384-420`(firmware-2710 `build_dir/target-aarch64_cortex-a53_musl/nftables-json/nftables-1.1.1`):只檢查 `data[datalen] == '*'`(最後一個字元),去掉它後其餘當常值;沒有中間萬用字元的路徑。04 bridge ports 實測:`/sys/class/net/br-ahwlan/brif` = `bat0 eth0 phy1-ap0`。
- **修法**(擇一,實作前在非 DUT 節點驗證,併 §9-4 那次):
  - (a) `iifname != "phy*"`:04 上 `phy*` 的 bridge port 只有手機 AP;但要寫明前提「本 image 的 bridge 上 `phy*` 的 port 只有 `mode=ap`」並在 helper 的檢查裡驗證(`network.wireless status` 裡所有在 ahwlan 的 `phy*` iface 都是 AP;否則不給 `http.2`)。
  - (b) 匿名集合 `iifname != { "phy0-ap*", "phy1-ap*", "phy2-ap*", "phy3-ap*" }`(nft 的 interval 集合支援結尾萬用字元,需在目標 nft/kernel 上實測)。
  - 不要改成 deny-list(`iifname { "bat0", "eth0" } drop`):新 port 就 fail-open。
  - `prov-http-254` 要加一條**正向**斷言「手機 AP 上的 client TCP 連得上 8095」與「eth0 上的主機連不上」放在同一臂;負對照:規則改成 `phy*-ap*`(現在這版)→ 正向斷言 FAIL。

### M2. `provd-stable` 用「peer pid = procd `batman-provd` instance 的 pid」辨識 provd — procd 的 instance pid 是 **ujail(root)**,provd 是它的子行程 → 條件永遠不成立 → 每個 P3 以後的試用都被退回(app 更新與 ssh sysupgrade 都升不上去)
- **情境**:§3.7.6 (b):helper 看到 ctl 連線的 SO_PEERCRED pid = `ubus call service list` 的 batman-provd pid,連續 60 s 才寫 `provd-stable`;autocommit 沒看到就判試用不健康 → revert。ujail 下兩個 pid 不同,provd-stable 永遠不會寫。
- **證據**(04 唯讀):`ubus call service list '{"name":"batman-provd"}'` → `"pid": 8388`;`pidof batman-provd` → `8414 8388`;`/proc/8414/status`:`PPid: 8388`、`Uid: 471`;`/proc/8388/status`:`PPid: 1`、`Uid: 0`;`ps`:`8388 root … /sbin/ujail -t 5 -n batman-provd -U provd …`、`8414 provd … /usr/bin/batman-provd`。§3.7.6 的「provd 沒有 pid namespace」是對的(`"netns": false` 等),漏的是 ujail 會 fork。
- **修法**:辨識條件改成「peer pid 的 `PPid` = procd instance pid,且 `/proc/<pid>/exe` = `/usr/bin/batman-provd`、uid 471」(都在 root 可讀的 /proc;provclient 的 PPid 不同,仍被排除)。F 表補一列(ujail fork,附上面輸出)。負對照:按設計原文(只比 instance pid)實作 → `prov-autocommit-p3-254`「正常 provd → commit」FAIL;現在 §8 的接縫 `autocommit-noprov` 只證明「不看就會 commit 壞的」,不證明「看得到好的」,要加這條正向斷言。

### M3. `halow-setkey --rollback-only`(helper 逾時後的收尾)沒有契約:舊值存在哪、含不含秘密、誰清;而 helper 逾時時 setkey 已被 SIGTERM/SIGKILL,自己沒機會還原
- **情境**:§3.3 預算 230 s、helper 上限 300 s;超過 → helper 背景跑 `--rollback-only`。但 `provstore.Exec` 逾時會對整個 process group 送 SIGTERM、10 s 後 SIGKILL(`provstore/exec.go:37-42`),setkey 的同一次呼叫裡的 `--rollback` 不會跑。`--rollback-only` 要還原到「之前的狀態」,就必須知道舊的 SSID / **舊 AP passphrase** / 舊國家 / 封鎖狀態 — 設計沒有說 setkey 在動手前把快照寫在哪裡(檔名、權限、格式、什麼時候刪、helper 重啟或開機後還在不在、斷電後怎麼辦)。這是一個**新的、含秘密的資源**,不在 §4 擁有權表、§5.3 介面表、§4 清理表裡。§6「helper 重啟時 setkey 子程序還在跑」那列又說「outcome unknown 的那次由 `--rollback-only` 收尾」,但 helper 重啟後沒有任何紀錄知道有一次 outcome unknown(記憶體狀態已消失),所以這條路徑實際上沒有人觸發。
- **證據**:`halow-setkey` 現在沒有任何快照 / rollback 機制(`halow-setkey:1-100`、`:280-303` 只有 apply → read back → persist);`exec.go:27`(`Setpgid: true`,helper 死掉時 setkey 存活 → 那條自己會跑完並自己 `--rollback`,這點設計是對的)、`:37-42`(逾時 kill)。
- **修法**(只做必要的):優先**拿掉 `--rollback-only`**:預算 230 s < 300 s,只有 setkey 卡在 D-state 才會逾時,那時 rollback-only 也一樣會卡;逾時 = outcome unknown,app 以 `settings/get` 重讀,與 P2 `net.apply` 逾時的處理一致。若要保留,就要寫完整契約:快照 = `$RUNDIR/halow-setkey.prev`(root 0600,RunDir 是 root 0700 tmpfs、不進 p5、不進 log),動手前寫、成功或還原後刪;開機消失 = 斷電時 live 是哪一份由 §6 斷電列決定;helper 啟動時看到快照且沒有 setkey 持鎖 → 跑 `--rollback-only`(這樣 helper 重啟那條才有觸發者);負對照 = 接縫讓 setkey 在 commit 後 sleep 到逾時。

### M4. key 2(國家)對「從 legacy 認領的已認領節點」:前提「未入網的節點 radio1 一定被封鎖」不成立,讀回規則沒有答案;而且與 key 20 的 `RadioManaged` 規則矛盾
- **情境**:legacy 節點(現在整個 fleet,F68)被認領後是 `Claimed` + `RadioManaged=false`,radio1 仍是操作員設的真 mesh key、正在 mesh 上跑(04:radio1 ch40 US,`wlh0` UP)。§3.3 允許它改國家(「含 legacy」),而讀回段寫「被封鎖 / disabled 的 radio1(未入網節點一定是)只驗 uci 值 + regdb」。對這台節點,radio 在空中,改國家會 `wifi reload` 一個正在承載 mesh(可能還有 TAK)的 radio;設計沒有定義這時要不要用 setkey 既有的晶片讀回(`morse_cli` Operating Frequency 對 regdb centre,`halow-setkey:349-374`),也沒說失敗怎麼還原。最壞情況:回應「成功」,節點已經離開原本的 legacy mesh。另一方面,key 20 以「legacy 的 radio 屬於操作員」為由拒絕 legacy(`E_UNSUPPORTED{7}`),key 2 卻改操作員的 radio — 同一個原則兩種答案。
- **證據**:`node/node.go:514-539`(legacy 與 unclaimed 都能認領;`next.RadioManaged = rec.State == provstore.Unclaimed`,註解「legacy claim keeps the operator's radio」);`:1125`(入網才設 true);狀態只有 legacy / unclaimed / claimed / member(`provstore/provstore.go:29-32`);04 `uci show wireless`、`ip -br link`。
- **修法**:一個答案:radio1 不在 keyguard MARK 且 `disabled≠1`(在空中)時,key 2 走 setkey 的完整晶片讀回(與 `--channel` 同一段),失敗由 `--rollback` 還原並回 13;回應前提示「這台會離開目前國家不同的 mesh」(§3.11-7)。key 2 對 `RadioManaged=false` 仍允許(否則 legacy 節點無法加入不同國家的網路 — join 拒絕國家不符、key 2 又被拒,會卡死),在 §3.3 明寫這個與 key 20 不同的理由。`prov-settings-254` 加「從 legacy 認領、radio 在空中 → key 2 → 頻率 = 新國家 regdb;注入讀回失敗 → 還原為舊國家且 plink 回來」;負對照 `setkey-readback-skip`。

---

## MINOR

1. **§5.1 與 §3.1.7 / §3.8.2 / §5.2 對同一件事給不同答案**(重寫的目的就是一條路徑一個答案)。§3.1.7 寫 `bulk.open(第二個)`、`update.prepare(第二個)`;§5.1 那列拿掉了「第二個」→ 照 §5.1,上傳完成後(窗仍開)正常的 `update/prepare` 會回 `E_BUSY`,重送 `bulk/open` 也 `E_BUSY`;§5.2 卻說重送 `bulk/open` = 延長同一個窗;§3.8.2 又寫前提「沒有其他上傳窗」。修:§5.1 一列明寫「prepare 在窗開著時是正常流程;同一擁有者重送 bulk/open = 延長;另一位擁有者 → `E_BUSY`;worker 在跑時第二個 prepare → `E_BUSY`」。
2. **nft 檢查跑在 poll 路徑上**:§3.8.1「helper 每次 poll 前以 `nft -j list chain …` 確認」,與 §3.1.4「唯讀動詞不跑子程序」(`readonly.go:3-7` 的契約)矛盾。修:與 settings / halow-status 快取同一種背景刷新(例如每 4 s),poll 只讀快取,快取超過 10 s → 當作表不在。另外 `ruleset-post` 檔每次 `fw4 reload` 都會被 include(04 `/usr/share/ucode/fw4.uc:816-820`,`ruleset-post` 以前綴對應到 `ruleset-append`,`:990-996`、`:1583-1597`),而 fw4 只 `flush table inet fw4`(04 `ruleset.uc:9`)→ 檔案內必須先 `table bridge batman_http` + `flush table bridge batman_http` 再定義,否則每次 reload 規則重複一份。
3. **新版根本沒開機成功時,`update/status` 報 0「沒有更新」**:tryboot 的新槽在 autocommit 跑起來之前就掛掉(kernel panic / 卡住 → 韌體回預設槽),不會有 `bad-slot`(只有 autocommit 自己寫,`batman-autocommit:195,244`)→ 依 §3.7.4 表 = 0。這是最需要讓擁有者知道的失敗。修:`update.apply` 在 `reboot committed` 之前把 update-last 改成 `rebooting: true`;回到 from_slot、`rebooting: true`、沒有 bad-slot → 回新 phase(或 6 + reason「新版未開機」);只有 `armed: true` 而沒有 `rebooting` 的才是斷電 → 0。
4. **pending 30 分鐘到期會讓已寫好的槽不能 apply**:phase 3 與 `update.apply` 都要求 pending 未到期;check → 找 Wi-Fi → 上傳(窗 15 分)→ worker → 看 TAK 警告再按 apply,很容易超過 30 分,之後只能整包重傳。修:prepare 開始時把 pending 到期延到 worker 結束 + 30 分,或 phase 3 只看 `BATMAN-VERIFIED` = sha + 同 boot_id。
5. **SSID 進 PRESERVE 後,含 UNSAFE 字元的現有 SSID(例 `Tom's AP`、`A&B`)會讓 p5 永遠 stale**:`--check` 回 `unpersistable`(`batman-config-save:483-485`),`batman-slot` 依 `:504` 拒絕 OTA,`--save` 修不好;§3.3 的「只因新 key stale 就 `--save` 一次」也救不了。legacy 節點不能用 key 20 改 SSID。SSID 是 openmanetd / LuCI / 操作員都能寫的(F50)。修:§3.3 寫明這條路徑(升級後該節點 OTA 被擋,訊息指示改 SSID),或 PRESERVE 對 ssid 採「不可存就略過、image 預設勝出」(與空值相同規則,`batman-config-save:478`)並在 `status` 回報。
6. **worker 失敗的原因碼**:`batman-slot write` 內部會重跑 `node_checks`(試用中、p5 新鮮度、`.txn`)與 Pi 3 韌體白名單(`batman-slot:592-637`);§5.1 把 worker 失敗一律寫成 phase 0 + reason 11(內容不符)。p5 在 check 與 prepare 之間變 stale 時,app 會說「簽章不符」。修:worker 依 batman-slot 的失敗類別對應 1 / 12 / 17 / 11。
7. **負對照有幾條做不出來或不分辨**(§8 自己定的規則):
   - `prov-update-254` 升級臂的負對照寫「wsl.22」— 但要證明的是「P3 加了 ssid PRESERVE、沒有自動 `--save`」會 stale,wsl.22 沒有新 key,本來就 fresh。要一個接縫(例如 `p5-autosave-off`)。
   - `prov-upload-254` 的負對照「wsl.22」只證明功能不存在,不證明「窗開著時 `network/update` → `E_BUSY`」「tmpfs 上限」各自有效;要各一個接縫或改成 Go 單元的 mutant。
   - 「provclient 掛 60 s 不算 provd-stable」沒有負對照(見 M2)。
   - §8 說接縫「只在 prov_test / wbox image」,但 `batman-slot` 現有的 `fault()` 是在**所有** image 裡、以 root 擁有的 `/tmp/batman-fault.*` 觸發(`batman-slot:72-77`);新的 shell 接縫(`setkey-norollback`、`slot-copy-all`、`autocommit-noprov`)如果沿用,release gate 的斷言就不成立。寫明 shell 接縫的閘門(root-only 旗標,與現況相同)或改成 build 時移除。
8. **操作員停用 `batman-provd` 的節點會永遠升不上去**:§3.7.6 (a)(b) 讓試用退回,但沒有區分「provd 壞了」與「provd 被操作員停用」(`/etc/init.d/batman-provd disable`,例如 legacy fleet 不用 app 或日後的 EMCON)。修:只在 `batman-provd` enabled 時要求 (b);停用時 WARN。
9. **F58 / §3.8.1 寫「docker 容器被 fw4 擋」,但 04 上 `docker` zone 是 `input='ACCEPT'`(network `docker` = `docker0`)**;只有 `br-ots`(`dockert`)是 DROP。現在沒有容器在 docker0 上(DOWN),但經 docker0 或 lo 的本機行程連得到 `10.41.1.3:8095`(weak host,F58),可以佔掉 HTTP 的 2 個槽 / 10 交握/分。內容仍有 Noise 保護,只是 DoS。修:改正 F58,把「本機行程 / docker0 容器可佔 HTTP 槽」列進 §7 誠實界線(或在 `inet fw4` input 對 docker0 加 8095 drop)。
10. **`--ap -`(從 stdin 讀 passphrase)不在新旗標清單**:§3.3 用 `--ap -`,但 §5.3 與 §10 只列 `--ap-ssid`、`--ap-section`、`--country`、`--rollback`、`--rollback-only`、`--lockwait`。現行 `--ap <psk>` 是放在命令列(`halow-setkey:51`),只有 `--mesh -` 讀 stdin(`:64-65`)。少了這項,`/proc/*/cmdline` 的負測試會失敗,或實作者照舊把 passphrase 放命令列。
11. **`owner/remove` 沒有關掉被移除者的上傳窗**:§3.2 只切 session;`bulk.open` 記的 `owner_key_id` 還在,窗在 15 分鐘內仍是開著的(新的 session 驗不過,所以沒有安全問題,但 `otaBusy` 會繼續擋其他擁有者的 `settings.set` / `network/*`)。修:`owner.remove` 時清掉該擁有者的窗與 pending。
12. **被入侵的 provd 可以隨時把 bulk tmpfs 填到 `size=`(2 × payload ≈ 252 MB)**:§3.8.2 只把 3A+ 列進 checklist;Pi 4 2 GB 也是 TAK 的支援等級(TAK RAM 地板 2 GB),252 MB 常駐可能把 OTS 擠到 OOM。修:helper 在窗沒開時每次 poll 看到上傳檔就刪(它本來就是唯一刪除者),把「窗外最多存在一個 poll 週期」寫進界線;checklist 項目改為「3A+ 與 2 GB TAK 節點」。
13. **update-last 的寫入時機寫了兩種**:§3.7.4 表說 `update.apply` 寫它,下一段又說「下一次 `update.check` 通過時才覆寫 update-last」。寫明 check 是「刪除」還是「寫入新的 armed:false 草稿」,phase 判讀表也照這個寫。
14. **CDDL 的冪等欄位還在**:`219-protocol.cddl:71-74` 的 `idem-type` 與各請求的 `? 7 => bytes16` 仍在,§10 只改 §4.2 文字。寫明節點忽略 key 7(未知欄位規則),CDDL 註記「保留、不使用」,避免 app 依 CDDL 以為重送會命中快取。

---

## §9 延後項目的判斷

| # | 延後可以嗎 | 理由 |
|---|---|---|
| 1 U5 改名探針 | 可以 | D8 是使用者決定;H4 改名單位等 U5,其他不受影響 |
| 2 YubiKey | 可以 | 節點端只依賴 ES256 與 64 B r‖s;host 工具鏈不影響節點設計 |
| 3 改國家後 morse 換表 | 可以,但要補**探針失敗時的答案** | D9 全靠它;若 morse 需要 driver reload / 重開才換表,key 2 的「讀回在 join」就不成立。寫一句:探針失敗 → key 2 改為「寫入 + 要求重開」或停用 key 2(join 前請操作員 ssh) |
| 4 kmod-nft-bridge | 可以 | 兩種結果都便宜;**同一次實測要一起驗 M1 的規則** |
| 5 一般重開時 96 不覆寫 overlay | **不用延後,現在就能從 source 確認**:`96-batman-config-migrate:2-4`「A uci-default: runs once per fresh slot overlay」— uci-defaults 跑完就刪,一般重開不會再跑 → §6 斷電列的假設成立。把 ⚠️ 改成證據 |
| 6 tmpfs `size=` | 可以 | 見 MINOR 12 |
| 7 setkey 新旗標逐行對照 | 可以,但 `--rollback-only` 先依 M3 決定要不要 |
| 8 CYW43455 共存 | 可以 | H4 量測並記錄;不影響介面 |

---

## 已核實(✅,附出處)

- F27 / §3.7.2:`build-ab-payload.sh:73` 現在 `tar … root.squashfs boot metadata SHA256SUMS`;`batman-slot:679-682` 依 glob 複製(不看 SHA256SUMS),`:697-701` 只驗列名的 → 「只複製列名的」是真缺口,修法正確。
- 串流:`precheck` 在沒有 `root.squashfs` 檔時用 `metadata size=`(未簽)當長度(`batman-slot:613-621`),讀回以 `SHA256SUMS` 的 RSUM 比對(`:697`)→ §3.7.5-7 的 fail-closed 成立;`write` 在一次呼叫內持鎖 dd stdin,比現在 `stage-root` 與 `apply` 分兩次拿鎖更好。
- `reboot committed` 在 tryboot 旗標 ≠ 0 時走一般 reboot(`batman-slot:864-881`)→ apply 後重開的說法正確。
- `bad-slot` 標記存在、格式 `slot=<S> version=<v>`,在 `/opt/batdata/state`(`batman-autocommit:36,195,244`),commit 時刪(`:554`)。
- `--check` 列出**所有**不同的 key(`diff_keys`,`batman-config-save:471-477`)→ §3.3「stale key 全部是 P3 新 key」可以判斷。
- owner-op 簽 `args_hash` = 整個 body(`219-protocol.md:264-272`)→ prepare / apply 帶 sha 綁擁有者同意的版本成立。
- setkey 的釋放邏輯只釋放 key 不再是 placeholder 的 MARK 項(`halow-setkey:286-300`)→ `--country` 不會把 placeholder 的 radio1 放上空中。
- `99-halow-identity` 在 p5 還原過的新槽不重設 SSID(`:7`)→ PRESERVE 的 ssid 能撐過 OTA。
- fw4 每次 start / reload 會 include `/usr/share/nftables.d/ruleset-post/*.nft`(04 `fw4.uc:816-820`);`fw4 flush` 刪所有表(04 `/sbin/fw4:61-67`)— F59 正確。
- 04:`/tmp/run` root 0755、`/tmp/run/batman` root 0700、`/tmp/run/batman-prov` root:provd 0750;8095 未被佔用;provd jail 無 netns(F11、F33、F53)。
- Appendix A 抽查:A4-M1(載入者、檢查後才聽)✅ 方向對,但規則語法見 M1;B4-m2 provd-stable 身分 ❌ 見 M2;A4-M2 預算 ✅,但逾時收尾見 M3;B4-M2 ✅(另見 MINOR 5、7);A4-m6、A4-m9、A4-m13 ✅。先前各輪已修的(HTTP 不對 mesh 開、poll 不被 app 讀取擠掉、秘密不進命令列、tar 不交給 busybox)在 v5 都還在,唯一退步是 MINOR 10(`--ap -` 沒列在旗標清單)。

## 收斂判斷

接近收斂。v5 確實比 v4 一致,剩下的不一致只有 MINOR 1、13。4 個 MAJOR 都是「一個機制的具體寫法在真機上不成立或沒有答案」,修法各幾行:M1 改規則語法並在 §9-4 那次一起實測;M2 改用 PPid + exe 辨識;M3 建議拿掉 `--rollback-only`(只做必要的),與 P2 逾時的處理一致;M4 key 2 對在空中的 radio 用既有的晶片讀回。MAJOR 修完、整份再審一輪,應該可以 APPROVE 並凍結。
