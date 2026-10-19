# Review A(第 10 輪)— `254-stage1-impl.md` v10(含 v4–v9 中標「同 vN」的各節)

審查對象:Batman `design/254-stage1-impl` @ 8079153;原始碼 main f2f2bf6(= branch)`feed/batman-provision/files/`;fstools `build_dir/target-aarch64_cortex-a72_musl/fstools-2024.07.14~408c2cc4`;節點 04 唯讀探針(§7)。沒有任何寫入、重開、commit。

## 0. 總評

- **第 9 輪 MAJOR(A9-M1 / B9-M1)對「從沒重置過的節點」已經關掉。** 我把四個入口都走過:S11 batdata-mount(`unreadable` → 先 ro 讀 p6,E 不成立 → 今天的流程;`n/a` → 今天的流程)、96(只在 fresh 跑,`n/a` 走 v4 rc 表)、helper 啟動表(`unreadable` + 無 marker + 無 E → `unknown(p5-unreadable)`)、`.locked` 觸發(只認 `none`)。只要 E 的四項都不在,沒有任何一條會上鎖、建 `.locked` 或清 overlay ✅。E 的四項都只有 root 寫得到:哨兵、`.locked` 在 overlay `/etc`;marker、`prov-state` 在 `/opt/batdata/state`(04 實測 `drwxr-xr-x root`,沒有容器 bind-mount 它,§7)✅。只有一處例外:96 的 claimed/member 提示上鎖會不會 touch `.locked`,文件沒寫清楚(m3)。
- **但為了收 M1 新加的兩條規則,在「真的在重置中」的節點上各開了一個洞:**
  - **A10-M1**:helper 表新增「marker 在 + `n/a` → 解凍」。這等於放寬了 U 第 2 條,前提是「`n/a` = 不可能有意圖」。可是 `n/a` 的判定(magic ≠ ext4)沿用現行寫法 `hexdump … 2>/dev/null`,讀錯時會得到空字串,被當成「非 ext4」。所以 p5 讀錯一次,就可能把已提交的重置解凍,刪掉哨兵。之後 p5 恢復可讀,W 在**沒清 overlay** 的情況下清掉 p5/p6,前任的身分被 helper 重新 persist 回去。
  - **A10-M2**:fresh 開機時 E 只存在 p6 上(哨兵、`.locked` 已被 F4/W0 清掉)。batdata-mount 凍結時不掛 p6,又把上鎖交給 96,可是 96 讀不到 p6 上的 E → 走 4b,也就是 image 預設的空密碼 root。p5 只要掛不起一次(F4 之後那次開機),節點就在前任資料都還在的狀態下對外開放。
- §4.5.2 的 fd 交接可以實作(Go `ExtraFiles` 在子程序 dup2 出同一個 OFD;busybox `flock -n <fd>` 對同一個 OFD 一定成功),只差一個 fd 身分檢查(m6)。fresh 判定(96 檔是否還在)在正常路徑上成立,bypass 是例外(m7)。R-locked 的「檔案已消失」檢查與 fstools 原始碼一致 ✅,有一條假陽性路徑(m8)。

**判定:REJECT(窄)** — 0 BLOCKER / 2 MAJOR / 10 MINOR。兩條 MAJOR 的修法都是一兩行規則,不需要新機制。

---

## 1. 先補:缺的列 / 資源

| 缺的列 / 資源 | v10 現況 | 對應 |
|---|---|---|
| marker 在、F3 已提交,helper respawn 或斷電重開時 p5 superblock 讀錯 | 解析器判 `n/a` → 解凍(刪哨兵、marker,`apps.reset → apps`) | **M1** |
| F4 之後的 fresh 開機,p5 掛不起 | batdata-mount 凍結、不掛 p6、交給 96;96 讀不到 p6 的 E → 4b(開放) | **M2** |
| S11 讀 E 時 p6 也掛不起(ro) | E 的 p6 部分無定義:fail-open 還是 fail-closed? | m1 |
| W2 被打斷(mkfs 先 discard → magic 消失 → `n/a`) | §4.3 一處說「`n/a` 不因重置上鎖」,另一處說「`:67/:71` + `resetting` → 上鎖」 | m2 |
| 96 依 claimed/member 提示上鎖 | 列在 §4.5.7 L 底下,而 L 的內容含「touch `.locked`」 | m3 |
| 重置完成後,helper 一直沒寫出確定的 prov | 新 p6 的 `prov-state` 停在 `resetting` → E 一直成立 | m4 |
| 重置待撤銷期間有一次 `unreadable`+E 開機(L + `.locked`),之後 cancel | 解凍不碰 `.locked` → 下次開機 R-locked 清掉已撤銷節點的 overlay | m5 |
| `BATMAN_RESET_LOCK_FD` 指向的 fd 不是 `reset.lock` | `flock -n` 對任何 fd 都會成功 → config-save 以為自己持鎖 | m6 |
| `batman_bypass=1`(96 exit 1,檔案一直留著) | 非 fresh 開機時 batdata-mount 判「fresh」,把上鎖交給 96,但 96 已在 bypass 出口離開 | m7 |
| `sysupgrade -b -c` / LuCI 還原把哨兵或 `.locked` 帶回來 | 未處理(B9 已提) | m9 |

---

## 2. Findings

### MAJOR

**A10-M1. helper 啟動表「marker 在 + `n/a` → 解凍」放寬了 U,而 `n/a` 可以由一次讀錯產生 → 已提交的重置被解凍;p5 恢復後,W 在沒清 overlay 的情況下完成,前任身分被重新 persist。**

- **證據**:
  - §4.5.5 表最後一列:「掛 | 在 | `n/a` → 不可能由 F 階段產生…;crit `reset-marker-no-p5`,**解凍**(U 的第 2 條改以「`n/a` = 不可能有意圖」成立)」(`254-stage1-impl.md:257`)。
  - §4.5.1:`n/a` 包含「p5 非 ext4」(`:189`)。現行程式判斷「非 ext4」的寫法是 `magic=$(hexdump -s 1080 -n 2 … "$DEV" 2>/dev/null)`,不等於 `53ef` 就判非 ext4(`96-batman-config-migrate:70-71`、`batman-config-save:111`)。讀錯(EIO)時 `magic` 是空字串,會被當成「非 ext4」。設計沒有規定「讀 magic 失敗 = `unreadable`」,照著現有寫法實作,一次 EIO 就是 `n/a`。
  - W1 的前提是「哨兵不在 = overlay 已清」(`:282`);解凍會刪哨兵(§4.5.3)。
  - v4 rc 表:「overlay 有完整 identity 而 p5 無 → **補 persist,絕不重產**」(`254-stage1-impl-v4.md:108`)。
- **情境**(使用者列的「p5 偶爾讀錯一次」):
  1. 擁有者為了轉賣按下恢復出廠。F3 rc 0,意圖已寫進 p5。F4 跑完之前,helper crash 被 procd 拉起,或者斷電重開。
  2. 這次開機,helper 的解析器讀 p5 superblock 時 EIO → `n/a`。表上那一列 → 解凍:刪哨兵、刪 marker、`apps.reset → apps`,tenant 重新起來。
  3. 下一次開機 p5 正常 → `intent`,slot 相符 → W0:哨兵不在 → 略過 → W1 mkfs p6(OTS DB 等資料沒了)→ W2 mkfs p5 → log 寫 completed。
  4. overlay 從頭到尾沒被清,前任的 `identity/`、`prov.cbor`(claimed,owner = 前任)、`authorized_keys`、shadow 都還在。helper 看到 overlay 有完整 identity、p5 rc 7 → **補 persist**,把前任的擁有權寫回新的 p5。
  5. 結果:買家拿到一台「重置已完成」、但仍屬於前任、前任 SSH key 仍有效的節點。p6 資料也沒了。
- **為什麼是 MAJOR**:照文件實作,前任擁有者在重置之後仍然保有控制權(actor 得利),而且 p6 資料遺失。觸發條件是兩個獨立故障同時發生:F3–F4 之間重啟,加上一次讀錯。但這一列是設計明文的規則,實作者照做就會寫出這個行為,程式碼審查也擋不下來。
- **修法**:
  1. 「marker 在 + `n/a`」→ `reset-uncertain`:凍結、不 cancel、crit、bench。這一列本來就「不可能由 F 階段產生」,改成凍結沒有任何代價。
  2. 解析器只在**確實辨認出來**時才回 `n/a`:沒有區塊裝置或沒有 `PARTNAME=config`;或 magic **讀取成功**,而內容是 LUKS 或其他非 ext4。讀 magic 失敗(hexdump rc ≠ 0,或讀到的長度 ≠ 2 B)→ `unreadable`。
  3. 從沒重置過的節點不受影響:`unreadable` 本來就有 E 閘門。
- **負對照**:seam 讓解析器的 hexdump 回 EIO,節點狀態設成 marker `f3=ok`、意圖在 → 斷言:不解凍、哨兵還在;下一次開機 seam 拿掉 → 斷言 W0 有執行(overlay 被清)。照 v10 字面:解凍、W0 被略過 → FAIL。

**A10-M2. fresh 開機時 E 只在 p6 上,而 batdata-mount 凍結時不掛 p6、又把上鎖交給 96 → 96 看不到 E → 4b → image 預設空密碼 root 開放。**

- **證據**:
  - §4.5.6:`unreadable` → ro 讀 p6 的 E → E 成立 → 「凍結:不掛 p6、上鎖(L)」(`:273`)。§4.5.7:「執行者:fresh overlay → 96;非 fresh → batdata-mount」(`:289`)。
  - §4.3 96:「回 `unreadable` 而 **p6 的**重置證據成立 → 同樣上鎖」(`:167`),提示讀的也是 p6 `prov-state`(`:171`)。96 自己不掛 p6;它的檔頭寫明依賴 95 先把 p6 掛好(`96:6`「Ordered after 95-batman-storage so /opt/batdata (p6) is mounted」)。
  - F4 的 `jffs2reset` 會把 overlay 的哨兵、`.locked` 一起刪掉;W0 也是。所以 F4 或 W0 之後的那次 fresh 開機,E 只剩 p6 上的 marker 和 `prov-state`。
  - helper 啟動表:p6 沒掛 →「依解析器… 其他 → `unknown`」(`:248`)。`unknown` 的上鎖要讀 p6 `prov-state`(§1.4 `:79`),p6 沒掛 → 不動。
  - 文件裡沒有任何 batdata-mount → 96 的通道。`lock-status.override` 只在非 fresh 的 L 時寫(`:291`)。
- **情境**(單一故障):
  1. 恢復出廠 F3 提交 → F4 jffs2reset → F5 重開。
  2. 這次開機 overlay 是 fresh,95 在 uci-defaults 階段呼叫 `boot()` → `reset_wipe()`。p5 這次掛不起 → `unreadable`;ro 讀 p6 看到 marker → E 成立 → 凍結(p6 不掛),上鎖交給 96(96 檔還在)。
  3. 96:p5 讀不到;到 p6 找 E 和提示,但 p6 沒掛 → 沒有證據 → 4b → image 預設(`root:::0`、PasswordAuth 開,R70/R72)。
  4. helper:p6 沒掛 → `unknown` → 不鎖。
  5. 整個開機期間節點開放,而 p5(意圖、前任身分、overrides 含 mesh PSK)和 p6(`apps.reset/` 的 OTS DB、憑證)都原封不動。任何連得到 dropbear 的人(04 / bench 的乙太網;現場的實體持有者)都能拿到空密碼 root,讀出 p6、刪掉意圖。
- **為什麼是 MAJOR**:照文件實作,節點會被留在開放狀態,而且正好落在前任資料最完整的那次開機;觸發只要 p5 掛不起一次。§1.4 的 `reset-uncertain` 那列寫的是「上鎖」,文件自己的契約在這裡不成立。
  - 誠實面:實體持有者本來就能拔卡讀 p5/p6(A6-m12),所以增加的暴露主要是網路側。現場的 unclaimed 節點 AP/mesh 多半被 keyguard 關掉;bench 與 04 有乙太網。
- **修法**(擇一):
  1. batdata-mount 凍結時一律寫 `$RUNDIR/reset-freeze`(root 0700 tmpfs,內容寫明原因),96 把它當成 E:上鎖並 touch `.locked`。
  2. 或者凍結時不論 fresh 與否,都由 batdata-mount 自己做 L,並寫明 96 的 4b 不得把它改回來。
  
  任一種都要更新 §3 鎖定欄位的寫者列與 §4.5.6 的 fresh 判定段。
- **負對照**:F4 之後的 fresh 開機,seam 讓 p5 掛不起 → 斷言 `PasswordAuth=off`、`root:!`、`.locked` 存在。照 v10 字面:開放 → FAIL。

### MINOR

**A10-m1. E 的 p6 部分讀不到時怎麼判,沒有定義** — **PR-P1 必帶**
- `unreadable` 分支要 ro 掛 p6 來讀 marker 和 `prov-state`(`:273`)。p6 也掛不起時(壞卡常常兩個分割一起壞),E 是不確定的,文件沒寫要走 fail-open 還是 fail-closed。
- 照實作者最可能的寫法(檔案不存在 → 不成立),結果是:F4 之後的開機遇到 p5、p6 同時讀錯 → 不上鎖 → 同 M2 的開放狀態。
- 建議:E 不確定 → 上鎖但**不** touch `.locked`(fail-secure,但不清 overlay)。從沒重置過的節點,在 p5、p6 同時壞的那次開機被鎖,有 key 的節點不受影響;沒有 `.locked`,之後也不會被清 overlay。
- 負對照:seam 讓 p5、p6 都掛不起 → 斷言上鎖,且沒有 `.locked`。

**A10-m2. §4.3 對 `n/a` 的兩條規則互相矛盾;W2 被打斷的情況要靠其中一條** — **PR-P1 必帶**
- §4.3 第 2 點(`:167`):「回 `n/a` → 照 v4 rc 表的 `unknown` 處理,**不因重置上鎖**」。
- 同一節的出口規則(`:171`):「讀不到 p5(`:64/:67/:71/:89`)而 `last_known_state` ∈ {claimed, member, **resetting**} → 上鎖」。可是 `:67`(無 p5)和 `:71`(非 ext4)正好就是 `n/a`。
- W2 被斷電打斷時,mke2fs 會先 discard 再寫 superblock,下一次開機 magic 消失 → `n/a`。W2 中斷的保護就靠第二條規則成立,實作者若照第一條寫,節點就停在 image 預設。
- 修法:改寫成「`n/a` 本身不觸發重置上鎖,但 96 依 p6 `resetting` 提示上鎖」。負對照:seam 讓 W2 之後 p5 magic 變成 0 → 96 上鎖。

**A10-m3. 「誰會 touch `.locked`」範圍太寬:96 的 claimed/member 提示上鎖也被放在 L 底下** — **PR-P1 必帶**
- §4.5.7 第 4 點把「96 的提示集合 {claimed, member, resetting}」放在 L 這一節;L 的內容包含「touch 鎖記號」(`:290-292`)。
- 照字面:一台從沒重置過的 claimed 節點,在 OTA 的 fresh 開機遇到 p5 讀錯一次 → 96 依提示上鎖並建 `.locked` → 之後某次 p5 讀到 `none` → R-locked 清 overlay、重開。傷害不大(fresh 後 96 會從 p5 還原),但違反「從沒重置過的節點不受影響」,也多了一次沒有原因的重開。
- 修法:只有因為意圖、`bad`、E,或 `resetting` 提示而上鎖時才 touch `.locked`;claimed/member 提示上鎖不 touch。負對照:fresh 開機、p5 讀錯、`last_known_state=claimed` → 上鎖,且沒有 `.locked`。

**A10-m4. 重置完成後 E 可能過時:新 p6 的 `prov-state=resetting` 要等 helper 寫出確定的 prov 才會被覆寫** — **PR-P1 必帶**
- W1 在新 p6 寫 `verdict=resetting last_known_state=resetting`(`:282`)。正常情況下,S89 的 helper 會在 rc 7 時產生 `prov{unclaimed}`,覆寫掉這個值。
- 但只要 helper 沒有走到那一步(crash loop、keystore 失敗),這個值就一直留著。之後任何一次 p5 讀錯 → E 成立 → 凍結、上鎖、建 `.locked`。這發生在一台已經重置完成、unclaimed、沒有 key 的節點上(L16 之後的 04 就是這種狀態):那次開機遠端救不回。要等下次開機 p5 讀得到,R-locked 清掉 overlay,才會自己好。
- 修法:W2 成功之後,batdata-mount 掛上新 p6 時,把 `last_known_state` 改寫成 `reset-done`(不在 E、也不在 96 的集合裡)。重置一完成,E 就失效。負對照:W2 成功、helper 停用,下一次開機 seam 讓 p5 `unreadable` → 不上鎖。

**A10-m5. 解凍(cancel / 撤銷)不處理 `.locked`,也沒說 L 鎖上的欄位怎麼辦** — **PR-P1 必帶**
- 情境:
  1. 重置還在待撤銷期間(F1 之後、F3 之前),有一次開機遇到 `unreadable`。這時 E 成立(哨兵在)→ L + `.locked`。
  2. 下一次 p5 正常、`none` + `.locked` → R-locked 清 overlay。結果是:擁有者還能撤銷的重置,overlay 已經先被清了,overlay 才有的設定都沒了。
  3. 就算擁有者先 cancel 成功(U 成立),解凍步驟也只刪 SD 標記、哨兵、marker(§4.5.3),`.locked` 還在 → 下次開機一樣會清。
- 另外,R-locked 的 jffs2reset 也會刪掉哨兵,但 §4.5.1 列的哨兵刪除者沒有 R-locked。這一點不違反 U,因為 R-locked 只在 `none` 時執行,只是文件少寫了一個刪除者。
- 修法(擇一,寫明即可):
  - `.locked` 存在時拒絕 cancel(`E_BUSY(locked-pending-clear)`),並說明下次開機會清 overlay、再從 p5 還原;
  - 或解凍時一併刪掉 `.locked`,同時說明鎖定欄位維持上鎖(legacy 的密碼節點要靠 key 或重開還原)。
- 負對照:待撤銷 + 一次 `unreadable` 開機 → cancel → 下次開機 → 斷言行為和所選規則相符。

**A10-m6. fd 交接要檢查 fd 的身分**(程式碼審查)
- 可行性 ✅:
  - Go `exec.Cmd.ExtraFiles[i]` 在子程序以 dup2 放到 fd 3+i,共用同一個 OFD;
  - busybox `flock -n <fd>` 是 flock(2)(04 `flock [-sxun] FD`),對已經持有 LOCK_EX 的同一個 OFD 呼叫會成功;
  - helper 被 kill 之後,孤兒 config-save 繼續持有這個 OFD → U(1) 不成立 ✅。
- 缺口:`flock -n "$n"` 不會檢查 fd n 是不是 `reset.lock`。env 和 fd 對不上時(操作員的 shell 留著 `BATMAN_RESET_LOCK_FD`,或 fd 3 剛好是別的檔),flock 會鎖到別的檔,config-save 卻以為自己持有重置鎖。
- 修法:
  - 先檢查 `[ "$(readlink /proc/$$/fd/$n)" = "$RUNDIR/reset.lock" ]`,不符 → 當作沒有 env 處理(自己 `flock -w 10`);
  - config-save 自己的重導向不得用到 fd n;
  - 寫明 config-save 的子程序(mount/sync)也會繼承這個 fd(和 D-state 那條一起歸 bench)。
- 另外,shell 端的 `( flock 9; … )` 建議改用 `flock -w`。S11 沒有逾時機制(R71),萬一有人持鎖,開機會永遠卡住。

**A10-m7. fresh 判定在 `batman_bypass=1` 時不成立**(寫明即可)
- bypass 時 96 `exit 1`,刻意讓自己保持 armed(`96:62-64`),所以 96 檔會一直在 `/etc/uci-defaults/`。非 fresh 開機的 S11:batdata-mount 看到 96 檔 → 判 fresh → 把上鎖交給 96。可是 96 在 S10 已經從 bypass 出口離開,沒有上鎖 → 意圖、`bad`、E 都沒人鎖。
- bypass 本來就是實體的逃生門(要改 FAT 上的 autoboot.txt),所以可以接受,但要寫進 §4.5.6 和誠實界線。比較精確的判準是:檔案在,**且**這次是由 95 的 uci-default 呼叫的 `boot()`。
- 04 實測:非 fresh 時 `/etc/uci-defaults/` 是空的 ✅,正常路徑的判定成立。

**A10-m8. R-locked / W0 的「檔案已消失」檢查在 `jffs2_mark` 路徑會誤判**(程式碼審查)
- fstools `jffs2reset.c:47-57`:volume 有掛載時 → `overlay_delete`,檔案當下就刪掉;**沒掛載時** → `jffs2_mark`,檔案要等下一次開機才被格式化掉。
- 在後者,「檔案還在」是正常的,卻會被判成 `reset-stuck` → 鎖住、送 bench。04 的 overlay 有掛載(loop0),所以實務上不會走到這條。但規則應寫成「檔案已消失,**或** jffs2reset 印出 not mounted 而且 rc 0」。

**A10-m9. 設定備份還原會把哨兵或 `.locked` 帶回來**(B9 已提,v10 沒處理)
- `sysupgrade -b -c`,以及 LuCI 含「所有修改過的檔案」的備份,都會帶上 `/etc/batman-reset.*`。還原之後:
  - `.locked` + `none` → R-locked 把剛還原的設定清掉;
  - 哨兵 → E 一直成立。
- 修法:把這兩個檔案排除在備份之外(或還原後由 helper 清掉沒有對應 p6 marker 的哨兵),並寫進殘項。

**A10-m10. 文件殘留 / 自足宣稱不實**(PR-P1 前修文字)
- **R43**(`:32`)仍寫「**任何層級**的 dot 項目都不刪」。§13 說「R43 實際更正」,但沒有改。fstools `overlay.c:43-68` 的 `handle_rmdir` 會 `unlinkat` 所有非目錄項目(dot 檔照刪);`foreachdir` 的 glob `*` 加 `GLOB_ONLYDIR`,只是不進 dot 目錄。正確寫法:**dot 目錄**(含內容)不刪。
- **E 的範圍不一致**:helper 表 `unreadable` 列寫「E 成立(哨兵或鎖記號)」(`:251`),§4.5.1 的 E 是四項(還有 marker、`prov-state=resetting`)。W1 之後、W2 未完成而 p5 讀錯時,兩種寫法結果不同。
- **§1.4 `unknown` 列**(`:79`)的上鎖集合是 {claimed, member},§4.3 和 §4.5.7 是 {claimed, member, resetting}。
- **§4.1** `:138`:「resetting 模式下 provd 對 `status/public` 之外只放行它與 `factory_reset`」,和 §1.4 `resetting` 列(只開 `status/public`)不一致,應寫成 `resetting-pending`。
- **D27**(`:355`)仍寫「argv[1]=`/sbin/sysupgrade`」;§4.5.4 已改成以 cwd 為基準的 `readlink -f`。§6.4 指向「§4.5『sysupgrade 程序判定』」,應改成 §4.5.4。
- **§4.5 宣稱自足,但 §4.5.10** 的「結果斷言:同 v8」和「(a)–(u) 沿用 v8/v9 的定義」仍然指向前版。要嘛把定義搬進來,要嘛把標題改成「自足(測試定義除外)」。

**PR-P1 必帶**:M1、M2 + m1、m2、m3、m4、m5,各附上面的負對照。m6–m10 可在實作與程式碼審查時處理。

---

## 3. 指定重點逐項

| 項 | 結論 |
|---|---|
| E 讓從沒重置過的節點不受影響(S11 / 96 / helper 表 / `.locked`) | ✅ 四條路都不上鎖、不建 `.locked`、不清 overlay;例外是 m3(claimed/member 提示上鎖會不會 touch,文件沒寫清楚) |
| 真的在重置中的節點仍然凍結/上鎖 | 非 fresh ✅;**fresh 開機失效**(M2);marker + `n/a` 會解凍(M1);E 的 p6 部分讀不到時沒有定義(m1) |
| E 能否被偽造 | 本機非 root、provd、容器 root 都寫不到(04:`/opt/batdata/state` root 0755、容器 mount 只有 `apps/opentakserver/*` 唯讀和 `docker/volumes/*`)✅。實體 SD 本來就無所不能。我們自己的錯:備份還原(m9) |
| E 會不會過時 | 完成重置後的 `resetting` 要靠 helper 覆寫(m4);cancel 後 `.locked` 留著(m5) |
| §4.5.2 fd 交接 | 可行 ✅(ExtraFiles = dup2 同一個 OFD;busybox `flock -n FD` 是 flock(2));要加 fd 身分檢查(m6) |
| fresh/非 fresh 用 96 檔判斷 | 正常路徑成立 ✅(`/etc/init.d/boot` 依 ls 順序跑,95 在 96 之前;成功才 `rm`;04 非 fresh 時目錄是空的);bypass 例外(m7) |
| R-locked 的「檔案已消失」 | 和 `jffs2reset.c:47-53` 掛載中的路徑一致 ✅(`handle_rmdir` 會刪 `upper/etc/` 下的一般檔);`jffs2_mark` 路徑會誤判(m8) |
| §4.5 改成自足後的矛盾 | §3 / §4.3 的指向都正確 ✅;§4.3 `n/a` 兩條規則衝突(m2);§1.4 `unknown`、§4.1、D27、R43、§4.5.10(m10) |

## 4. 逐 actor

- **BLE 路人 / 只看過 QR 的人**:本輪沒有變化 ✅。
- **本機非 root 程序**:碰不到 E 的任何一項,也碰不到 `reset.lock`(run dir 0700)✅。
- **被入侵的 tenant / 容器 root**:沒有 mount `state/`,也不在主機的 pid ns ✅。
- **被入侵的 provd**:cancel 和重新發起都要 owner-op,而且要過 U ✅。M1 那一列的解凍是 helper 自己觸發的,provd 不需要做任何事。
- **前任擁有者**:M1 讓前任在「重置已完成」的節點上保有擁有權;M2 讓前任的資料在一次開機內經網路可讀。
- **實體 SD**:本來就無所不能;讓 p5 讀錯 → 不再影響從沒重置過的節點 ✅。
- **供應鏈**:沒有新的依賴。
- **我們自己**:M1(規則所依據的前提是錯的)、M2(兩個寫者之間的交接沒有通道)、m2(同一節兩條規則衝突)、m10(文件殘留)。

## 5. v9 發現核對(一條一行)

| v9 | 狀態 | 說明 |
|---|---|---|
| A9-M1 | addressed | 從沒重置過的節點已不受影響;新引入 M1(`n/a` 解凍)、M2(fresh 交接) |
| A9-m1 | addressed | fd 經 ExtraFiles 交接、子 shell、解析器不取鎖、RDOK=0;身分檢查見 m6 |
| A9-m2 | addressed | 128 B、(z) |
| A9-m3 | addressed | 96 集合加入 `resetting`、§3 登記了 W1;§1.4 `unknown` 列沒跟上(m10) |
| A9-m4 | addressed | 只認 `none`、同一次開機、檔案已消失檢查;`jffs2_mark` 誤判見 m8 |
| A9-m5 | addressed | p5 已被掛 → 忙 |
| A9-m6 | addressed | rc 12 三個分支;step 規則 |
| A9-m7 | addressed | §4.5.9 + L58 + stage 1 訊息 |
| A9-m8 | partial | 欄位、`blkid -p`、tmp 都 ✅;`n/a` 的判定沒有區分讀錯(M1) |
| A9-m9 | addressed | 冪等寫法、D-state 歸 bench |
| A9-m10 | partial | §1.4 兩列、L16 (a)–(z) ✅;D27 用語、R43 沒改(m10) |
| B9-M1 | addressed | 同 A9-M1 |
| B9-m1 | addressed | 同 A9-m1 |
| B9-m2 | addressed | W2 之後同一次開機就 R-locked |
| B9-m3 | addressed | 重開前確認檔案已消失 |
| B9-m4 | partial | 集合 ✅;§4.3 `n/a` 規則和它衝突(m2) |
| B9-m5 | addressed | 用 96 檔判斷;bypass 例外(m7) |
| B9-m6 | addressed | rc 12 分支 |
| B9-m7 | partial | §3 / §4.3 都改成指向 §4.5 ✅;R43、§4.1 的 cancel 時段仍矛盾(m10) |
| B9-m8 | addressed | `blkid -p`、字元集、寫回失敗 |
| B9-m9 | addressed | tmp 固定名、先 `rm -f`、`set -f` |
| B9-m10 | addressed | L58 + `node_checks` |
| B9-m11 | addressed | 冪等、step 只在同一個 marker 的生命期內單調 |
| B9-m12 | addressed | `lock-status.override`;fresh 凍結時不會寫(M2 修法會一併涵蓋) |
| (B9 §4 附帶)備份還原帶回 `.locked` | open | m9 |

## 6. 使用者已定案事項的後果(不重開,只列)

- **Q5(L16 在 04)**:排 L16 之前,副作用清單要加三點:
  - M2 沒修:F4 之後那次開機只要 p5 掛不起,04 會以空密碼 root 對乙太網開放,這時 OTS 資料還在;
  - M1 沒修:同樣的讀錯可能讓重置「完成」,但 lab key 和身分都還在;
  - m4 沒修:L16 之後,只要 helper 有一次沒走完、p5 又讀錯,04 那次開機就會被鎖、遠端進不來。
- **U3 / U4**:沒有新的後果。

## 7. 本輪唯讀探針(04,原始輸出摘要)

```
ls -ld: /opt/batdata drwxr-xr-x root;/opt/batdata/state drwxr-xr-x root;/opt/batdata/apps drwxr-xr-x root
/opt/batdata/state: lock-status mesh-expected mesh-joined slot-A.protected slot-B.protected(全 -rw-r--r-- root)
docker mounts:
  /ots_eud_gateway apps/opentakserver/eud-gateway.pyz->/app/eud-gateway.pyz:false  docker/volumes/ots-appdata/_data->/app/ots:true
  /ots_cot_parser、/opentakserver docker/volumes/ots-appdata/_data->/app/ots:true
  /rabbitmq apps/opentakserver/rabbitmq-*.{json,conf}:false  docker/volumes/ots-mqdata/_data:true
  /ots-db docker/volumes/ots-pgdata/_data:true
  (沒有任何容器 mount /opt/batdata/state 或 /opt/batdata 本身)
ls /etc/uci-defaults/  → (空;非 fresh)
ls /etc/batman-reset*  → No such file
blkid --help: -p, --probe  low-level superblocks probing (bypass cache)
```

原始碼:
- `96-batman-config-migrate`:`:6`(依賴 95 先掛 p6)、`:62-64`(bypass exit 1)、`:67`、`:70-71`(`hexdump … 2>/dev/null`,≠ 53ef → 非 ext4)、`:89-93`
- `batman-config-save`:`:111`(同樣的 magic 寫法)、`:115-122`(mkdir 鎖,與 `reset.lock` 無關)
- `95-batman-storage`:`:605-633`(`boot()`、`[ -b PART ] || return 0`、閂)
- fstools:`jffs2reset.c:44-63`(掛載中 → PENDING + `overlay_delete`;沒掛載 → `jffs2_mark`);`libfstools/overlay.c:43-68`(`handle_rmdir` 刪所有非目錄項目,不檢查回傳值);`:70-110`(glob `*`,`GLOB_ONLYDIR`)

## 8. 判定

**REJECT(窄)**:0 BLOCKER / 2 MAJOR / 10 MINOR。

E 閘門達到了它的目的:從沒重置過的節點不再受影響。兩條 MAJOR 都出在 E 和 `n/a` 規則的副作用上:
- **M1**:把「marker + `n/a`」改成凍結,並讓解析器在讀錯時回 `unreadable`;
- **M2**:讓 batdata-mount 在 fresh 開機凍結時有一條通道交給 96(或自己上鎖)。

兩者加上 m1–m5 修完後,請重審整份文件,預期可以 APPROVE-WITH-CHANGES。
