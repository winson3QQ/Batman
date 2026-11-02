# 審查 B 第 3 輪:`254-h1-harness.md` v3(整份)

審查者 B,獨立進行。範圍是整份 v3,§12 的對應逐條核對。節點只做唯讀查詢:沒有跑 bluetoothctl / btmgmt、沒有建檔、沒有重啟,也沒有印出任何 IRK。

**結論:REJECT(窄):1 BLOCKER / 1 MAJOR / 8 MINOR。**

v3 把第 2 輪我提的 M1(btmon 區塊判讀)、M2(rekey 改用 kernel 證據)、M3(lease 加原子 deadman)大致修好了。

但 **N3 的 held trial 照字面沿用 fault-injection 的 `held_trial`,保留不住 wsl.2 的 trial**。原因是 hold 旗標寫的是「節點目前的版本」,trial 開進的卻是 wsl.2,autocommit 會丟掉旗標、照常 commit。後果正好和設計的安全承諾相反:02 會被 commit 在舊 build 上。

另外,deadman 自己沒辦法完成「有 kernel 驗證的 rekey」,所以 §5、N7 承諾的「到期後乾淨」做不到。

---

## 0. 本輪驗證
| 項目 | 結果 |
|---|---|
| `held_trial` 寫入的 hold 旗標內容 | ✅ `fault-injection.sh:215-218`:`ver=$(nodever)`,也就是**節點正在跑**的版本,寫進 `/opt/batdata/state/autocommit-hold-commit` |
| autocommit 怎麼看 hold 旗標 | ✅ `feed/.../usr/bin/batman-autocommit:259-290`:旗標內容必須等於**這次開機**的 `version()`(`:66`),否則記 `HOLD-COMMIT-DISCARDED`,並在 `:290` 刪掉旗標,照常走 commit 判定 |
| 用 source 方式載入 fault-injection 的副作用 | ✅ `:116` 的 `trap 'restore_node…' EXIT` 寫在 `:516` 的 `FI_SOURCE_ONLY` return **之前**,所以載入它的腳本會繼承這個 EXIT trap;`restore_node`(`:99-123`)在 `NOTENANT=0` 時要求 OTS 6/6 |
| `r3` / `r4` 會呼叫 `precheck` | ✅ `:311`、`:325`:payload 必須等於執行中的 build;wsl.2 ≠ wsl.9,一定擋下,所以 N3 不能直接用 r3 / r4,只能用 `held_trial` 加 `ota_boot` |
| `ota_boot` | ✅ `:186-193`:`sysupgrade -n $PAYLOAD`,`waitboot` 600 s,`settle` 300 s |
| R4 的 revert 會寫 bad-slot | ✅ `:341-344`:「every revert records bad-slot」 |
| bluetoothd 正常停止時 | ✅ `adapter.c:10915-10936` `adapter_shutdown`:adapter 上電時送 `SET_POWERED 0`(關乎 N11,見 m1) |
| rekey 的 kernel 驗證邏輯 | ✅ 方向正確:kernel 若仍用舊 IRK,看到的 RPA 用新 IRK 做 `ah()` 不會吻合 |
| E22、E23、E24、E25 | ⚠️ 作者在節點上實讀或實測;我依規則沒有重做。E24 和 PR-F 的 btmon 檔一致 ✅ |

---

## BLOCKER

### B1 N3 的 held trial 保留不住 wsl.2:hold 旗標會被丟掉,02 會被 commit 在 wsl.2

**情境**:§4.10 N3 步驟 2 寫「以 `FI_SOURCE_ONLY=1` 載入 fault-injection 的函式 → arm hold-commit → `FI_PAYLOAD=/opt/batdata/ota.tar.gz` 寫入 slot B → tryboot」。照字面沿用 `held_trial` 時:

1. `held_trial` 把**現在執行中**的版本寫進旗標(`fault-injection.sh:216-218`)。在 02 上就是 `1.5.12-wsl.9+…`。fault-injection 原本只做同版本 OTA,所以這樣寫沒問題;N3 卻是**跨版本**。
2. tryboot 進 slot B 後,跑的是 **wsl.2 的** `batman-autocommit`。旗標內容 wsl.9 ≠ `version()` 回傳的 wsl.2 → `HOLD-COMMIT-DISCARDED`(`batman-autocommit:285-287`),旗標被刪(`:290`),trial **沒有被保留**。
3. wsl.2 如果健康(02 以前就跑過 wsl.2、能入網),autocommit 照常 **commit slot B**。`held_trial` 的斷言「hold-commit 有被這次 trial 接收」(`:222`、`:228`)會 FAIL 並返回,但沒有任何東西會讓 02 重開回 A。繼承來的 EXIT trap 只跑 `restore_node`,它不 revert,而且沒帶 `--no-tenant` 時還會因為 02 沒有 OTS 而再 FAIL 一次。
4. 結果:02 被 commit 在 wsl.2。§4.10 步驟 4 說的「`reboot`(tryboot 一次性 → 回 A)」和「時限到自動 revert」都不會發生。02 會停在舊 build,之後全套的 preflight P3(版本一致)都會 FAIL,要靠操作者經 mesh 手動 `rollback` 加 `reboot committed` 救回。如果 wsl.2 在 commit 之後才出問題,02 沒有乙太網,救不回來。

這正好推翻 §12 對 A-R3 / B-M4 的處理(「不需要實體救回」),而且**每次執行都必然發生**,不是偶發。

**修法**
- N3 腳本自己寫旗標,內容是 **payload 的** `version`:用 `tar -xzOf "$PAYLOAD" metadata` 讀 `version=`,並確認它和 slot B 讀出的 `BATMAN_VERSION` 完全一致,包括 `+…` 後綴。寫完之後,在 tryboot 之前印出旗標內容,和 payload 版本並列比對。
- 進入 trial 後,先斷言 `$R/autocommit.ctl/hold-commit` 存在、沒有 `autocommit.hold-discarded`,**才做**其他事。不符時立刻 `batman-slot reboot committed` 回 A,並 FAIL。這一步不能等 deadline,因為那時 autocommit 可能已經 commit 了。
- 先唯讀確認 wsl.2 的 autocommit 有 hold-commit(v2.4,`HOLDCOMMIT_FLAG`)。做法:從 `ota.tar.gz` 的 rootfs 裡讀 `/usr/bin/batman-autocommit`,唯讀解開 squashfs 即可。沒有就不能用這個方法。
- 載入 fault-injection 時要帶 `--no-tenant`(02 沒有 OTS),並寫明繼承來的 EXIT trap 會做什麼。也可以不 source,只複製需要的三個函式。
- 加一個負對照:用同樣步驟,但旗標寫成 wsl.9 版本,在 `DRY=1 AUTOCOMMIT_FORCE_TRIAL=1` 下(`batman-autocommit:269`)證明它會被丟掉。這是白箱,不必真的換槽。

---

## MAJOR

### M1 deadman 做不了「有 kernel 驗證的 rekey」,所以 §5 / N7 承諾的「到期後乾淨」不成立,04 的 IRK 外洩狀態沒有自動出路

**情境**:§4.7 規定 `rekey` 必須「04 開 non-connectable 廣播 → **02 取樣** → 主機用新 IRK 做 `ah()`」,全部通過才刪 `irk-exposed`。但 deadman 是在 04 上獨立跑的 `dm-fire`:主機已經死了,它沒辦法叫 02 取樣,也沒有主機端的 `ah()`。所以:
- 翻轉段之後主機死掉 → `dm-fire` 只能做到「停 bluetoothd、刪 identity、啟動」,拿不到 kernel 證據 → 照規則**保留** `irk-exposed` → 下一次 preflight 和每天的 tier A 都 FAIL,一直到 04 重開為止;
- 但 §5「harness 中途死掉」寫的是「到期 04 … rekey … 乾淨」,N7 的預期也是「deadman 到期後 04 `ble-state` 乾淨、… IRK 已 rekey」。N7 照現在的設計一定不符。

而且「保留標記」只會讓之後的測項 FAIL,**不會**真的作廢 IRK。E27 那條路徑上(adapter 帶電啟動),kernel 會繼續用已外洩的 IRK,直到有人重開 04。04 是會帶去現場的 OTS 節點。

**修法**(由使用者選一個,寫進設計)
- (a) deadman 處理 `irk-exposed` 的動作改成 **`batman-slot reboot committed` 重開 04**。tmpfs 清空,IRK 一定換,不需要 kernel 驗證。副作用:無人看守下 OTS 中斷約 2 分鐘;04 有乙太網。這要列進 §8 的副作用清單。
- (b) 保留標記,把 §5 和 N7 的預期改成「標記保留、下一次 run 開頭由主機做有驗證的 rekey 或重開」,並寫明這段期間 IRK 可能仍有效的風險。
- 不管選哪一個,`dm-fire` 做的 rekey 至少要先 `btmgmt power off`,並在 log 寫明「未驗證」。

---

## MINOR

**m1 N11 的負對照做不出它要證明的狀態**。N11 = 「`kill -9 bluetoothd`(respawn,adapter 仍上電)後跑**不先 power off** 的 rekey」。但 rekey 的「停 bluetoothd」是正常的 SIGTERM:`adapter_shutdown`(`adapter.c:10915-10936`)會先送 `SET_POWERED 0`,所以重新啟動時 adapter 是斷電的,privacy 設定會成功,kernel 換成新 IRK,驗證**通過**。結果 N11 不會 FAIL,負對照看起來就像「判定沒有鑑別力」。要重現 E27,必須讓 bluetoothd 在上電狀態下啟動:`rm identity` → `kill -9 bluetoothd` → 等 procd respawn(這時 adapter 仍上電,新的 bluetoothd 寫新 IRK 檔,但 set privacy 被拒)→ 跑 kernel 驗證 → 必須 FAIL。

**m2 `dm_arm` 先取消後 arm,中間有空窗**。如果在 cancel 和 `setsid` 之間 ssh 斷線,ash 收到 SIGHUP 就會中止腳本:舊的 deadman 已殺掉,新的還沒建立,而 lease 到期的判定要求「deadman 已執行完」,這個條件永遠不會成立 → lease 卡住到重開,04 停在當時的狀態(可能還在翻轉)。修法:先 arm 新的、確認之後再取消舊的,或者整個 `dm_arm` 以 `trap '' HUP` / `setsid` 執行。「deadman 已執行完」要有明確的完成標記,不能用「pid 不在了」推斷。

**m3 §7 的數字和 §4.7 對不上**。§7 寫「deadman 把窗口限制在 ≤ 300 s + rekey」、「deadman 2700 s 內一定撤掉」,§4.7 寫的是每段配對 900 s、rpa 3300 s。翻轉段之後主機死掉,04 非 SC-only 且 connectable 廣播的時間最長是 900 s。這是路人可以拿到 IRK 的窗口,§7 要改成和 §4.7 一致的數字。

**m4 bash `$SECONDS` 不是單調時鐘**。§4.4 說「主機用自己的單調時鐘(bash `$SECONDS` / Python `time.monotonic()`)」。bash 的 `SECONDS` 是用 wall clock(`gettimeofday`)算出來的,Windows 或 WSL 校時跳動會影響它。⚠️ 這是我依 bash 實作推論的,沒有在這次測試。改用 `/proc/uptime`(WSL)或 Python 的 `time.monotonic()`,並且整條時間軸都由同一個 Python 程序擁有。

**m5 P6「乾淨」本身要靠產品狀態才讀得到**。P6 宣稱不擋產品狀態,但「04 無 adv instance」要用非互動的 `bluetoothctl mgmt.advinfo` 讀,bluetoothctl 需要 bluetoothd 在跑。bluetoothd 沒在跑時讀不到 → 依「讀不到 = FAIL」,preflight 照樣被產品狀態擋下。修法:bluetoothd 不在時,把 adv 檢查標成 N/A(沒有 bluetoothd 就沒有 instance,E9),交給 suite 去判。

**m6 lease 跨兩台節點的取得沒有定義**。tier B 需要 04 和 02 兩台的 lease。取得 04 的、但 02 的被拒(或反過來)時,要先釋放已取得的那一台;各台的 lease 期限與 deadman 也要寫成各自獨立。現在只寫了單台的情況。

**m7 N3 回 A 用的是單純 `reboot`**。`batman-slot` 的 `cmd_reboot` 上方註解(`reboot committed` 的實作段,`:778` 附近)寫明 Pi 4 EEPROM 在單純重開後有一半機率走錯分割區(5/10),所以才有 `batman-slot reboot committed`。在 02(沒有乙太網)上,應該一律用 `batman-slot reboot committed`。另外,R4 式的 revert 會寫 bad-slot(`:344`)。回 A 之後 slot B 是否被標成 bad,要寫進副作用清單:它會讓之後的 `rollback` 被拒。

**m8 §12 的對應抽查**:
- B-M1(btmon):成立。另外,`UNPARSED n` 不是判定依據,寫清楚就好。
- B-M2(rekey):機制成立,但負對照有誤(m1),deadman 那條路徑沒處理(M1)。
- B-M3(lease):成立,只差空窗(m2)和跨兩台節點的取得(m6)。
- B-M4(N3):**不成立**(B1)。
- B-m1(T0 前 restore)成立;N5a / N5b 成立(依原始碼,(a) 段內 power cycle 會因 `HCI_RPA_EXPIRED` 產生新 RPA;(c) 段改在 T0+600 重新註冊則 RPA 不變)。
- m3(FIFO / `--timeout`):成立。非互動 `scan on` 的輸出格式要以 N2b 實測為準,失敗時改用 `btmgmt find`,這個備案也寫了。
- m4:部分成立(m4)。m5 到 m9:成立。

---

## 生命週期補充
| 路徑 | 問題 |
|---|---|
| N3 執行中主機死掉 | 照 B1 修好(旗標寫成 wsl.2)之後,trial 會被保留,deadline 一到 autocommit 就 revert 回 A,能自己恢復。照現在的寫法,autocommit 會 commit wsl.2 |
| deadman 在翻轉段後觸發 | M1:沒有 kernel 驗證 → 標記保留,IRK 可能仍有效,直到 04 重開 |
| `dm_arm` 執行到一半 ssh 斷線 | m2:lease 卡住,04 狀態不還原 |

## 結論
**REJECT(窄)**。
- B1:N3 的 hold 旗標要寫成 payload 的版本,並在 trial 一開始就驗證 hold 生效。
- M1:deadman 遇到 `irk-exposed` 時,要嘛重開 04,要嘛修正 §5 / N7 的承諾。這一點要使用者決定。

這兩點改完後,其他項目都是 MINOR,可以下一輪一起確認。
