# #254 階段 1 實作設計 v10 — 獨立審查 B(第 10 輪,對抗式)

審查對象:`docs/design/254-stage1-impl.md` v10(branch `design/254-stage1-impl` @ 8079153),加上「同 vN」所指的 `254-reviews/254-stage1-impl-v{4,5}.md`,以及 `review-v9-{A,B}.md`。原始碼:main f2f2bf6(= branch)的 `feed/batman-provision/files/`;firmware `/home/yello/firmware-2710` 的 fstools `2024.07.14~408c2cc4`(`jffs2reset.c`、`libfstools/overlay.c`、`rootdisk.c`)。

全程唯讀。04 上只跑了這些:`flock --help`、`ls -ld /opt/batdata/state/*`、`cat /proc/cmdline`、`/sys/block/loop0/loop/*`、`ls /etc/uci-defaults`、`docker ps`/`docker inspect`(Mounts)、`cat /rom/etc/config/dropbear`、`grep ^root: /rom/etc/shadow`、`sed /etc/init.d/boot`、`ls /etc/rc.d /rom/etc/rc.d`。沒有寫入、沒有重開、沒有 bluetoothctl。沒有讀 reviewer A 的報告。

## 0. 結論

**判定:REJECT(窄)— 0 BLOCKER / 2 MAJOR / 11 MINOR。**

**第 9 輪的 MAJOR(A9-M1/B9-M1),在原本的情境下已經關閉。** 原情境:從沒做過重置的節點,在非 fresh 開機時 p5 讀不到一次。我逐一對過,這類節點現在每條路都不受影響:
- S11:`unreadable` 只在 E 成立時才凍結;`n/a` 照今天的流程走。
- 96:只有讀得到 E 時,才因為重置而上鎖。
- helper 啟動表:`unreadable` 依 E 分兩列。
- `.locked` 觸發:只認 `none`。
- legacy 02/04 第一次 OTA 到這個 image:p6 沒有 `prov-state`、沒有 marker,overlay 也沒有哨兵或鎖記號,所以 E 不成立,結果與今天相同 ✅。

**但 E 這道閘門在兩個地方開錯了方向。**

- **B10-M1(fresh overlay 上看不到 E):**
  - E 的 p6 部分只有 batdata-mount 讀得到,它是用私有掛載點以 ro 掛 p6 去讀的。
  - 在 fresh overlay 上,凍結時刻意不掛 p6,L 交給 96 做。96 只能讀**已掛**的 p6,所以看不到 E,結果走 4b:image 預設,root 空密碼、PasswordAuth on。
  - 最典型的 fresh 開機,正是恢復出廠 F4/F5 之後的那一次。也就是說:擁有者按了重置 → 那次開機 p5 讀不到 → 節點**完全開放**,而 p5(前任身分)、p6(OTS 資料、`apps.reset`)都還在。
- **B10-M2(`n/a` 吞掉讀取錯誤後被拿來解凍):**
  - `n/a` 定義為「p5 非 ext4」,但沒有說讀 magic 時發生讀取錯誤算哪一種。
  - 專案現有寫法(96 `:70-71` 的 `hexdump … 2>/dev/null` + `[ = 53ef ] ||`)會把讀取錯誤歸成非 ext4,也就是 `n/a`。
  - helper 啟動表「marker 在 + `n/a` → **解凍**」因此會在 p5 可能已有意圖時解凍,違反 U。這和 A8-M1 是同一類:之後 W1 會清掉解凍後寫進 p6 的資料。

另外,fd 交接寫的 `flock -w 10`,busybox 不支援 `-w`(m1)。

## 1. 先補:缺的生命週期列與資源

| 缺的路徑 / 資源 | v10 照字面的行為 | 對應 |
|---|---|---|
| F4/F5 之後那次開機(**fresh overlay**),p5 `unreadable`,p6 有 marker | batdata-mount 判 E 成立 → 不掛 p6;L 交給 96 → 96 看不到 p6 → 4b → image 預設開放 | **M1** |
| 同上,但 p5 superblock 所在的 sector 讀取錯誤(magic 讀不到) | 解析器回 `n/a` → batdata-mount 走今天的流程;helper「marker 在 + `n/a`」→ 解凍 | **M2** |
| 凍結(p6 沒掛)期間做 OTA | `node_checks` 只看 marker / 意圖:marker 讀不到(p6 沒掛)、意圖讀不到(`unreadable`)→ 放行 | m6 |
| `batdata-mount start/restart` | 現行 `start(){ boot; }`(95 INITBODY);照「reset_wipe 只由 `boot()` 呼叫」實作,執行期就會跑 W | m3 |
| 恢復出廠完成後,新 p6 的 `prov-state` = `resetting/resetting` | 沒指定誰負責改;要等 helper 讀到確定的 prov 才會更新。這段期間,或 helper 一直失敗時,E 都是過時的 | m4 |
| `resetting-pending`(F1–F2b 被打斷)+ 一次 p5 讀不到 → L + 鎖記號;下一次讀到 `none` | R-locked 會清掉一台**還沒提交**重置的節點的 overlay;解凍也不刪鎖記號 | m5 |
| helper 啟動時,孤兒 config-save 還持著鎖 | U(1) 不成立時的狀態沒定義,鎖釋放後也沒規定要重新判斷 | m7 |
| `unreadable` 分支裡,以私有點 ro 掛 p6 失敗 | E 的 p6 部分算成立還是不成立,沒寫 | m8 |
| bypass 開機(96 `exit 1`,保持 armed) | 「96 檔還在 = fresh」會判錯;非 fresh 的 bypass 開機,96 在 S10(p6 還沒掛)就已經跑完 | m9 |

## 2. MAJOR

### B10-M1 — fresh overlay 上「`unreadable` + E → 凍結」時,L 交給 96,但 96 看不到 E(p6 被刻意不掛)→ 4b → 節點以 image 預設開放,前任資料都還在

**證據**
- §4.5.6 的 parser 表,`unreadable` 列:「先以 `ro` 掛 p6 到私有點讀 E 的 p6 部分 … **E 成立 → 凍結:不掛 p6**、上鎖(L)」。
- §4.5.7:「執行者:fresh overlay → 96」。§4.5.6 的 fresh 判定:「`96-batman-config-migrate` 還在 = fresh(96 稍後會依意圖上鎖)」。
- §4.3 對 96 的要求:「回 `unreadable` 而 **p6 的**重置證據成立 → 同樣上鎖」。
- 96 讀 p6 的唯一方式是已掛的 `/opt/batdata`:§4.5.8 寫「96 … 先 `mountpoint -q /opt/batdata`」;現行 96 `:161` 也是直接用 `/opt/batdata/state/lock-status`。**全文沒有任何地方讓 96 自己掛 p6,也沒有讓 batdata-mount 把凍結的判斷交給 96。**
- fresh overlay 上不可能有 E 的 overlay 部分:哨兵、鎖記號都放在 `/etc`,而 overlay 剛被 F4 的 jffs2reset 清掉。所以 96 只能靠 p6 上的證據,而 p6 沒掛。
- F4/F5 之後那次開機確實是 fresh:
  - F4 的 `jffs2reset -y` 在已掛載時會設 PENDING,並當場刪除(`jffs2reset.c:44-55`);下一次開機 fstools 會再刪一次(`overlay.c:444-455`)。
  - 04 的 `S11batdata-mount` 不在 `/rom/etc/rc.d`(實測),它是 95 在 overlay 裡 `enable` 出來的(95 尾段 `"$INIT" enable` + `"$INIT" boot`)。所以 fresh 開機時 `boot()` 只由 95 呼叫一次,S11 不會再跑一次來補救。
  - 執行順序(04 `/etc/init.d/boot:7-17`):uci-defaults 依 `ls` 順序跑 95 → 96 → … → 99zz,全部在 S10。
- 4b 的實際結果:96 `:89-91` mount 失敗時 `exit 0`,留在 image defaults;現行 4b(`:161-177`)要有 key **且**有密碼才上鎖。04 的 `/rom/etc/config/dropbear` 是 `PasswordAuth 'on'`、`RootPasswordAuth 'on'`,`/rom/etc/shadow` 是 `root::`(實測)→ **root 空密碼,而且可以從網路登入**。
- §4.3 的提示規則(`last_known_state` ∈ {claimed, member, resetting} → 上鎖)同樣需要已掛的 p6,這條路上幫不上忙。

**情境(擁有者轉賣)**
1. 擁有者對 claimed 節點發起恢復出廠。F3 rc 0,F4、F5 重開。
2. 這次開機是 fresh,而 p5 讀不到(卡片老化,或 journal replay 出錯)。這和 B9-M1 承認的是同一類單一故障。
3. batdata-mount 判 E 成立(p6 marker 在)→ 不掛 p6,L 留給 96。
4. 96 看不到 E → 4b → `UNPROVISIONED`、root 空密碼、PasswordAuth on。
5. 節點一直維持開放,直到有人重開;下一次開機已經不是 fresh,batdata-mount 才會自己上鎖。
6. 在這段期間,任何連得到 SSH 的人(乙太網,或 image 預設的 AP / mesh)都能以 root 登入,自己掛 `/dev/mmcblk0p6`、`mmcblk0p5`。他可以:
   - 讀前任的 OTS DB 和憑證;
   - 讀 `identity/prov/`(`node.key`、`claim.secret`),拿來冒充這台裝置;
   - 讀 `shadow-root`;
   - 改寫意圖或 marker,阻止重置完成。

**為什麼是 MAJOR:** 照文件實作,節點會開放,而且暴露的正是 L 要保護的資產,也就是前任的殘留資料(§8「前任擁有者」列)。觸發條件只是「重置當次開機,p5 發生一次讀取故障」。

**修法**(不加新機制,只把交接寫成契約)
- batdata-mount 凍結時寫 `$RUNDIR/reset-freeze`(root 0700 tmpfs,不跨開機),內容 `<boot_id> <reason> <E 的來源>`。這個檔取代 `lock-status.override`。
- 讀者各自的處理:
  - 96:檔在 → 一律上鎖並 touch 鎖記號(fail-closed),不再自己算 E;
  - helper:檔在 → `reset-uncertain`(不是 `unknown`);
  - `node_checks`:檔在 → 拒絕 OTA(順便收掉 m6);
  - `halow-status`:顯示這個狀態。
- 另一種做法:凍結時不分 fresh 與否,一律由 batdata-mount 做 L;96 看到這個檔就不改鎖定欄位,寫者仍然只有一個。
- **負對照:** 白箱讓 F5 之後那次 fresh 開機的 p5 掛不起(seam),斷言:shadow 為 `root:!`、`PasswordAuth=off`、helper 判 `reset-uncertain`、`node_checks` 拒絕。照 v10 字面會 FAIL(實際是 `root::`、`UNPROVISIONED`)。

### B10-M2 — `n/a` 沒有排除「讀取錯誤」;helper 啟動表「marker 在 + `n/a` → 解凍」會在 p5 可能已有意圖時解凍,違反 U

**證據**
- §4.5.1:`n/a` 是「沒有 p5 分割、**p5 非 ext4**、或 LUKS」;`unreadable` 是「p5 存在、是 ext4、非 LUKS,但掛不起或讀錯」。讀不到 magic 時屬於哪一種,沒有規定。
- 專案既有寫法:96 `:70-71` 是 `magic=$(hexdump -s 1080 -n 2 … "$DEV" 2>/dev/null); [ "$magic" = "53ef" ] || { … image defaults; }`,config-save `:109` 也一樣。讀取錯誤時 magic 是空字串,會被歸成非 ext4。實作者照抄,就會得到 `n/a`。
- §4.5.5 啟動表的最後一列:「掛 | 在 | `n/a` | 不可能由 F 階段產生 … crit `reset-marker-no-p5`,**解凍**(U 的第 2 條改以「`n/a` = 不可能有意圖」成立)」。
- 這是 fail-open,理由只有「不可能」。但「marker 在、p5 看起來非 ext4」只會由故障造成,正是最不該解凍的時候。

**情境**
1. F3 rc 0(意圖已寫進 p5),接著 F4、F5。
2. 下一次開機,p5 superblock 所在的 sector 暫時讀取錯誤 → 解析器回 `n/a`。
3. batdata-mount 走今天的流程,照常掛 p6;tenant 被 marker 擋住,這一步還安全。96(fresh)走 image 預設,再依提示上鎖。
4. S89 的 helper 看到「marker 在 + `n/a`」→ **解凍**:`apps.reset → apps`、刪 marker,tenant 起來。
5. 擁有者看到節點恢復服務,繼續使用,新資料寫進 p6。
6. 之後某次開機 p5 讀得到 → 解析器回 `intent`,slot 相符,哨兵不在 → W1 mkfs p6 → **解凍後寫進的資料全部消失**,事前沒有任何提示。這和 A8-M1 同一類。

**為什麼是 MAJOR:** 會丟資料。觸發條件和 B9-M1 一樣,只是一次 p5 讀取故障,差別在於發生在重置期間。

**修法**
1. 解析器只在兩種情況回 `n/a`:沒有 p5 區塊裝置;或 magic **成功讀出**(`hexdump` rc 0,且輸出恰好 4 個 hex 字元),而且是 LUKS 或其他已知的非 ext4 簽章。讀取錯誤、輸出長度不對 → `unreadable`。
2. 「marker 在 + `n/a`」改成凍結 + crit + bench,**不解凍**。U 的第 2 條維持「重讀 = `none`」,不准用其他判斷取代。
3. batdata-mount 的 `n/a` 列:E 成立(marker 或哨兵在)時,比照 `unreadable` + E 處理;至少不能讓任何程序解凍。
4. **負對照:**
   - 白箱讓 p5 的 magic 讀取回 EIO,且 marker 在 → 斷言解析器回 `unreadable`、helper 不解凍、`apps.reset` 還在。照 v10 字面加上既有寫法,會得到 `n/a` → 解凍 → FAIL。
   - 保留 (w),證明真正的 LUKS / 無 p5 仍然判 `n/a`、正常開機。

## 3. MINOR

**m1 — busybox `flock` 沒有 `-w`** — **PR-P1 必帶**
- §4.5.2 寫「沒有這個 env → config-save 自己 `flock -w 10` 取鎖」。04 實測只有 `Usage: flock [-sxun] FD | { FILE [-c] PROG ARGS }`。repo 裡也有佐證:`payload-run:37` 的註解「busybox flock has only -sxun: a -n poll」,`:91-92` 用 `until flock -n 9` 迴圈。
- 照字面實作,`flock` 會因參數錯誤失敗,被當成「取不到鎖 → rc 10」。後果是安全的,但操作員以 root 手動跑 `--reset-intent` 時永遠拿到 rc 10。
- 修法:改成 `-n` + `sleep 1` 迴圈,最多 10 次。`prov-tools-254` 斷言 config-save 用到的 flock 參數都存在。

**m2 — `BATMAN_RESET_LOCK_FD` 沒驗證 fd 指向哪個檔;shell 子程序會繼承這個 fd** — 程式碼審查時處理
- 如果 env 指的 fd 是別的檔(我們自己寫錯,或 root 呼叫者傳錯),`flock -n <n>` 照樣成功,等於繞過 `reset.lock`。
- 修法:
  - 比對 `readlink /proc/$$/fd/$n` = `$RUNDIR/reset.lock`,不符 → rc 10。
  - config-save 裡不准把子程序放到背景(`&`、`setsid`)。ash 不會 CLOEXEC,背景子程序會繼續持鎖,U(1) 就永遠不成立。

**m3 — 現行 `batdata-mount start(){ boot; }`** — **PR-P1 必帶**
- 95 INITBODY 尾段是 `start(){ boot; }`(95 `:~728`)。§4.5.6 / L54 說「`batdata-mount start/restart` 不呼叫」,但 reset_wipe 放在 `boot()` 開頭。照字面實作,執行期跑 `/etc/init.d/batdata-mount restart` 就會跑 W:
  - 發生在 F3–F5 之間 → 執行期 jffs2reset + 重開;
  - 發生在 p6 已掛時 → W1 對已掛的 p6 動手。
- 修法:`start()` 改呼叫不含 reset_wipe 的 `mount_p6()`,或讓 reset_wipe 以 rc.common 的 `$action = boot` 為條件。L54 的白箱測試必須真的跑 `restart`,並斷言 reset_wipe 沒有執行。

**m4 — 重置完成後,新 p6 上的 `prov-state = resetting/resetting` 沒有指定清除者** — **PR-P1 必帶**
- 這個值由 W1 寫入(§4.5.6)。依 §3,`last_known_state` 只在讀到確定的 prov 時更新。99zz 在 fresh S10 讀不到 prov(p5 剛 mkfs,是空的),所以不會更新;要等 S89 的 helper rc 7 → `prov{unclaimed}`(v4 `:177`、`:302`)。
- 過時的時間窗:W2 之後到 S89;helper 失敗、crash loop 或 keystore 錯誤時則一直存在。
- 後果:這段期間只要 p5 讀不到一次,E 就成立 → 上鎖。被鎖的是剛重置、unclaimed、沒有 key 的節點(Q5 之後的 04 就是這種狀態),遠端救不回。之後鎖記號在、p5 又讀到 `none` → R-locked 再清一次 overlay。
- 修法:W2 成功之後,在同一次開機掛上新 p6 時,由 batdata-mount 把 `prov-state` 改寫成 `reset-done`(或直接刪掉)。W2 被打斷時保留 `resetting`,A8-m5 的保護不受影響。E 只認 `resetting`。

**m5 — marker 還在時 R-locked 也會觸發;解凍不刪鎖記號** — **PR-P1 必帶**
- 情境:
  1. F1–F2b 之間斷電或 helper crash → `resetting-pending`,意圖還沒寫。
  2. 下一次開機 p5 讀不到 → E 成立(哨兵、marker)→ L + 鎖記號。
  3. 再下一次開機 p5 讀到 `none` → R-locked:dot sweep + jffs2reset。這台節點的重置**從沒提交**,overlay 卻被清了;哨兵也一起被刪,和 §4.5.1「哨兵的刪除者只有 F4/W0/U 解凍」不一致。
  4. 擁有者隨後 cancel 成功,但 overlay 裡沒有持久化到 p5 的設定已經沒了。
- 判 MINOR 的理由:擁有者發起重置時已同意清除。不過 cancel 的契約是「回到原狀」,這裡沒做到。
- 修法:
  - R-locked 加條件「p6 已掛且 marker 不在」;marker 在時交給 helper 處理。
  - U 的解凍步驟加上:刪鎖記號,並依 prov 重新推導 L 改過的欄位(claimed/member 照樣上鎖)。
- 負對照:pending 狀態下 seam 讓 p5 讀不到一次 → 下次開機 `none` → 斷言 overlay 沒被清。

**m6 — 凍結(p6 沒掛)期間 `node_checks` 會放行 OTA** — **PR-P1 必帶**(可和 M1 的 `reset-freeze` 一起收)
- §4.5.9 只寫「marker 或意圖存在 → 拒絕」。凍結時兩者都讀不到,所以會放行。
- 如果操作員接著以 `-F` 降版:舊 96 遇到 p5 讀不到 → image 預設開放;舊 batdata-mount 會掛上 p6。
- 修法:`reset-freeze` 在,或 `unreadable` 且 E 成立 → 拒絕。

**m7 — helper 啟動時拿不到重置鎖(孤兒還在寫)怎麼辦,沒規定**
- 啟動表寫「f3 ≥ called → 依 U 重讀」,但沒寫 U(1) 不成立時是什麼狀態,也沒寫鎖釋放後要不要重新判斷。
- 照字面,helper 會停在中間狀態,一直到下一次開機:意圖已寫、F4/F5 沒做,節點以凍結狀態繼續運作,下次有人重開時就被清掉。
- 修法:先判 `resetting-pending(busy)`,不放行 cancel;每 5 s 以 `flock -n` 重試,拿到鎖後重新查表。

**m8 — 兩個未定義的情況**
- `unreadable` 分支以私有點 ro 掛 p6 失敗時,E 怎麼算沒寫。建議:E 的 p6 部分視為「未知」→ 凍結但不上鎖(今天 p6 掛不起時本來就不啟動 tenant),並發 crit。
- U(2) 寫「p5 已被掛 → 視為忙」,但解析器的 5 種輸出裡沒有「忙」。要寫明:解析器自己查 `/proc/mounts`,掛著就回 `busy`;所有讀者把 `busy` 當成 `unreadable` 的子集處理,不准當成 `none`。

**m9 — 96 保持 armed 時,「96 檔還在 = fresh」會判錯**
- 96 `:62-64` 在 bypass 時 `exit 1`。`/etc/init.d/boot:14` 是 `( . ./file ) && rm -f`,所以 96 不會被刪,之後每次開機都還在。
- 非 fresh 的 bypass 開機:96 在 S10 先跑(04 實測順序 S10boot → S11batdata-mount),這時 p6 還沒掛,96 算不出 E。S11 的 batdata-mount 看到 96 檔在,判成 fresh,把 L 留給 96 → 結果沒有人因 E 上鎖。
- bypass 本身就是需要實體存取的復原入口,開放是設計使然,所以影響低。但判定規則要把這個例外寫進去,也要寫明「96 在非 fresh 開機時看不到 p6」。

**m10 — 文件殘留與矛盾** — 前 3 項 **PR-P1 必帶**
- **R43 `:32`** 仍寫「**任何層級**的 dot 項目都不刪」。實際上 fstools `overlay.c:43-68` 的 `handle_rmdir` 以 `readdir` + `unlinkat` 刪掉所有非目錄項目(含 dot 檔);只有 **dot 目錄**會被 `foreachdir` 的 `glob("*")` 跳過。§13 說「R43 實際更正」,但正文沒改(B9-m7 partial)。
- **E 的範圍不一致:** §4.5.5 啟動表 `unreadable` 列寫「E 成立(哨兵或鎖記號)」;§4.5.1 的 E 還包括 marker 和 `prov-state = resetting`。
- **96 的 `n/a` 規則和提示規則互相矛盾:** §4.3 一方面說 96「回 `n/a` → 不因重置上鎖」,另一方面提示規則說「`last_known_state = resetting` → 上鎖」。W2 被打斷時兩者會同時成立(`n/a` + `resetting`)。要寫明以提示規則為準,以及這時要不要 touch 鎖記號。
- §6.4 D27 仍寫「argv[1]=`/sbin/sysupgrade`」,§4.5.4 已改成以 cwd 為基準的 `readlink -f`(A9-m10 partial)。
- §4.1 `:138` 寫「resetting 模式下 … 放行它與 `factory_reset`」,和 §1.4 `resetting` 列的「provd 只 `status/public`」對不上。應該寫 `resetting-pending`。
- §4.5.6 的 Wa 列沒寫 L。依 §1.4,只要有意圖就要上鎖,非 fresh 時由 batdata-mount 做。
- 解析器的實作細節(`set -f`、恰好一行、`head -c 129`、`p6uuid` 字元集)只寫在 §13,沒有寫進號稱自足的 §4.5.1。
- §4.5.7 說 `lock-status` 只在 p6 已掛時寫,但現行 96 `:161` 會 `mkdir -p /opt/batdata/state`,p6 沒掛時就把 `lock-status` 寫進 overlay。要寫明:96 在 p6 沒掛時不寫這個檔,改寫 run dir 的檔。

**m11 — 缺負對照**
- M1、M2、m1(flock 參數)、m3(`restart` 不跑 W)、m4(重置完成後 `prov-state` 已被改掉)、m5 都要各補一條。
- (x) 要同時斷言兩件事:helper 被 kill -9 之後,孤兒仍持著鎖;孤兒結束後,新 helper 能拿到鎖並重新判斷(m7)。

**PR-P1 必帶:** M1、M2、m1、m3、m4、m5、m6、m10 前 3 項,各附負對照。其餘(m2、m7、m8、m9、m10 其餘項、m11)在實作與程式碼審查時補。

## 4. 指定重點逐項

| 項 | 結論 |
|---|---|
| E + `n/a` 能不能讓從沒重置過的節點完全不受影響 | 非 fresh 的 S11 ✅;96 fresh 且無 E → 今天的規則 ✅;helper 的 `unreadable` 依 E ✅;鎖記號只認 `none` ✅;legacy 02/04 第一次 OTA ✅(沒有 `prov-state`、marker、哨兵、鎖記號)。漏洞在 `n/a` 吞掉讀取錯誤,以及 `n/a` 的解凍列(M2) |
| 真的在重置中時,凍得住、鎖得住嗎 | 非 fresh ✅;**fresh 的 `unreadable` + E 鎖不住(M1)**;凍結時 OTA 會被放行(m6) |
| E 能被偽造嗎 | 哨兵、鎖記號在 `/etc`,只有 root 能寫;marker、`prov-state` 在 `/opt/batdata/state`(04 實測 `drwxr-xr-x root`)。OTS 容器只掛 `docker/volumes/*`,以及 ro 的 `apps/opentakserver/*`(實測 `docker inspect`),碰不到 `state/` ✅。偽造最多只能造成 DoS(凍結、上鎖);實體 SD 本來就在誠實界線內 |
| E 會過時嗎 | 會。重置完成後 `prov-state = resetting` 會留到 S89,helper 失敗時一直留著(m4);marker 還在時,鎖記號會被 R-locked 用掉(m5) |
| §4.5.2 的 fd 交接 | 機制正確:Go ExtraFiles 讓子程序共用同一個 OFD,對同一個 OFD 再 `flock -n` 會成功;孤兒會繼續持鎖;Go 預設 CLOEXEC ✅。問題:`-w` 不存在(m1)、env 沒驗證(m2)、啟動時拿不到鎖未定義(m7) |
| shell 子 shell 寫法 | `( flock 9; … ) 9>file` 和現行 `payload-arbiter:58` 相同 ✅;S11 時沒有其他持鎖者,用 blocking 可以接受 |
| fresh / 非 fresh 判定,以及 96 何時被刪 | `/etc/init.d/boot:13-14`:每個 uci-default 跑完、rc 0 才 `rm -f`,所以 95 執行時 96 一定還在 ✅;非 fresh 開機時 uci-defaults 在 S10,早於 S11 ✅;例外是 96 `exit 1`(bypass,m9)。fresh 開機時 S11 不會再跑 `boot()`(`S11batdata-mount` 不在 `/rom/etc/rc.d`,實測),所以 M1 沒有後備 |
| R-locked 的「檔案已不存在」檢查 | 有效 ✅:`jffs2reset.c:44-55` 在已掛載時當場執行 `overlay_delete`(void),事後用 `[ -e /overlay/upper/etc/… ]` 就能確認。`rootdisk.c:95-122` 支援 loop overlay 的 `rootfs_data` ✅(04 是 `loop0`,backing `/mmcblk0p4`,offset 113442816)。執行中的 INIT 腳本自己會被 unlink;unlink 不是截斷,ash 仍能從已開的 fd 讀下去 ✅ |
| `lock-status.override` 與 `halow-status` | 現行 `halow-status:114` 只讀 p6 的 `lock-status`,PR-P1 要改。override 只在非 fresh 凍結時寫;fresh 時 96 會把 `lock-status` 寫進 overlay(m10)。建議和 M1 的 `reset-freeze` 合併成同一個檔 |
| §4.5 自足之後新出現的矛盾 | 見 m10:R43、E 列、`n/a` 與提示規則、D27、§4.1、Wa |

## 5. v9 發現核對(一條一行)

| v9 | 狀態 | 說明 |
|---|---|---|
| A9-M1 | addressed(非 fresh);新洞見 M1、M2 | E 閘門 + `n/a`;fresh 交接和讀取錯誤是這次新開的洞 |
| A9-m1 | addressed;見 m1、m2、m7 | fd 交接、CLOEXEC、子 shell、RDOK=0 都寫了;`flock -w` 不存在 |
| A9-m2 | addressed | 128 B;負對照 (z) |
| A9-m3 | addressed;見 m4 | 96 提示集合加了 `resetting`;§3 登記了 W1;但沒有人負責清除 |
| A9-m4 | addressed;見 m5 | 只認 `none`、同一次開機、刪不掉就不重開;marker 在時的情況是新缺口 |
| A9-m5 | partial | U(2)「p5 已被掛 → 忙」✅;但解析器沒有 `busy` 這個輸出(m8) |
| A9-m6 | addressed | rc 12 三分支、改寫 nonce、step 的生命期 |
| A9-m7 | addressed | §4.5.9 + L58 + 印出 pending;`-F` 屬操作員責任,已寫明 |
| A9-m8 | addressed;見 M2 | `n/a`、固定欄位順序、attempts、`blkid -p`、tmp;但 `n/a` 和讀取錯誤的界線沒寫 |
| A9-m9 | addressed | 冪等;D-state 歸 bench |
| A9-m10 | partial | §1.4 ✅、L16 ✅;D27 仍是 argv[1](m10) |
| B9-M1 | addressed(非 fresh);新洞見 M1、M2 | 同 A9-M1 |
| B9-m1 | addressed;見 m1 | fd 交接;解析器不取鎖 |
| B9-m2 | addressed | W2 之後同一次開機就 R-locked |
| B9-m3 | addressed | 確認檔案已消失、刪不掉就不重開;負對照 (y) |
| B9-m4 | addressed;見 m4 | |
| B9-m5 | addressed;見 m9 | 以 96 檔判 fresh;bypass 是例外 |
| B9-m6 | addressed | rc 12 分支 |
| B9-m7 | partial | §3/§4.3 改為指向 §4.5 ✅;R43 文字、§4.1 用語沒改(m10) |
| B9-m8 | addressed | |
| B9-m9 | partial | 細節只寫在 §13,沒有進 §4.5(m10) |
| B9-m10 | addressed | 選擇不擋 `-F`,並已寫明 |
| B9-m11 | addressed | |
| B9-m12 | partial | override ✅;fresh 時 96 會寫進 overlay,`halow-status` 也要改(m10、M1) |

## 6. 逐 actor

- **BLE 路人 / 只看過 QR 的人:** 本輪無變化 ✅。
- **本機非 root 程序:** `reset.lock`、run dir、`state/` 都只有 root 能寫 ✅;偽造不了 E。
- **被入侵的 tenant(容器 root):** 04 上 OTS 的掛載碰不到 `state/` ✅。其他 tenant 的 manifest 如果給了更寬的 p6 掛載,就能放 marker 造成 DoS(凍結)。建議在 payload-arbiter 明文禁止掛 `/opt/batdata/state`(在殘項加一行)。
- **被入侵的 provd:** cancel 和重新發起仍然要 owner_op + U ✅。
- **前任擁有者 / 買家:**
  - M1:重置當次開機 p5 讀不到 → 節點開放,前任資料可被讀走。
  - M2:解凍後寫進的資料,之後會被延遲執行的重置清掉。
- **實體 SD:** 在誠實界線內 ✅。
- **供應鏈:** 沒有新依賴;`flock -w` 不存在(m1)。
- **我們自己:** M1(把上鎖交給一個讀不到輸入的元件)、M2(照抄既有的 magic 判斷寫法)、m3(`start` 直接呼叫 `boot`)。

## 7. 使用者決策的後果(不重開,只列)

- **Q5(L16 在 04):**
  - M1 不修:L16 那次開機只要 p5 掛不起一次,04 就以 root 空密碼開放,直到下次重開。04 有乙太網,所以「救得回來」,但這是安全缺口,不能當成復原路徑。
  - m4 不修:L16 完成後、helper 寫入新 prov 之前,只要 p5 讀不到一次,04 就會上鎖而且沒有 key → 必須到現場。
  - 04 目前的 p5 是健康的 ext4(A9、B9 都實測過),所以 L16 觸發這兩條的機率低。
- **U3 / U4:** 沒有新的後果。

## 8. 本輪唯讀探針(原始輸出摘要)

```
04 flock --help: Usage: flock [-sxun] FD | { FILE [-c] PROG ARGS }        (無 -w)
04 /opt/batdata/state: drwxr-xr-x root;內容 lock-status, mesh-expected, mesh-joined, slot-{A,B}.protected(尚無 prov-state)
04 docker inspect Mounts: ots-* 只掛 /opt/batdata/docker/volumes/*/_data 與 /opt/batdata/apps/opentakserver/*(ro)
04 /proc/cmdline: root=PARTUUID=…-000000000004 batman_slot=B;loop0 backing=/mmcblk0p4 offset=113442816
04 /etc/uci-defaults: (空,非 fresh)
04 /rom/etc/config/dropbear: PasswordAuth 'on', RootPasswordAuth 'on';/rom/etc/shadow: root::
04 /etc/init.d/boot:7-17: for file in $(ls); ( . ./file ) && rm -f "$file"; uci commit
04 /etc/rc.d: S10boot S10system S11batdata-mount …;/rom/etc/rc.d 無 S11batdata-mount
repo payload-run:37 "busybox flock has only -sxun: a -n poll";payload-arbiter:58 ( flock 9; check ) 9>"$LOCK"
repo 96:62-64 bypass exit 1;:67/:71/:89-91 exit 0 image defaults;:70 magic=$(hexdump … 2>/dev/null);:161 mkdir -p /opt/batdata/state
repo 95 INITBODY: start(){ boot; };"$INIT" enable;"$INIT" boot;boot() 閂在 mount 之後
fstools jffs2reset.c:44-55 掛載中 PENDING + overlay_delete + remount;:134-150 volume_find("rootfs_data")
fstools overlay.c:43-68 handle_rmdir readdir+unlinkat 非目錄(含 dot 檔);foreachdir glob "*" GLOB_ONLYDIR(跳過 dot 目錄)
fstools rootdisk.c:95-122 rootfs_data = root 裝置上 squashfs 之後 64 KiB 對齊的 loop
```

## 9. 判定

**REJECT(窄)**:0 BLOCKER / 2 MAJOR / 11 MINOR。

第 9 輪的回歸在非 fresh 路徑上已經收掉。兩條 MAJOR 都可以局部修:
- M1:凍結的判斷經 run dir 交給 96、helper、`node_checks`。
- M2:`n/a` 只認成功讀出的簽章;「marker + `n/a`」改成凍結,不解凍。

PR-P1 必帶的 MINOR 一併修完、整份重審後,預期可以 APPROVE-WITH-CHANGES。
