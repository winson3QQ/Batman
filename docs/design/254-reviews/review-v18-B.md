# #254 PR-F 審查 第 18 輪 — 審查者 B — 設計 v18(e5f9d2e)+ firmware `feat/254-ble`(到 07f20637)

**判定:REJECT(窄)** — 0 BLOCKER / 1 MAJOR / 6 MINOR。

v17 的 B1、M1、M2 在設計上都收了,07f20637 的程式碼我也沒找到問題。

唯一的 MAJOR 在重寫後的 §9 配對程序。照字面跑,第三段(bluetoothd 重啟後 SC-only 有沒有重新生效)**分不出 patch 900 有沒有作用**;目標段的失敗判定也會把「沒連上」算成 PASS。修法只需要改 §9 的字,不必改程式。

範圍與做法:
- 讀了 v18 全文與 `git diff 6feb29d e5f9d2e`,§13「v17 → v18」逐列核對;
- 讀了 A 的 v17 報告;
- 讀了 07f20637 的 0013 patch 全文,以及已套進 build 樹的 `src/adapter.c:10198-10361`;
- 在 WSL 解開 wsl.8 出貨 payload,放在自己的 mktemp 目錄,用完即刪;
- **04 / 02 這輪完全沒連線,沒有任何指令**;
- 沒有 build、沒有 commit、沒改 firmware 樹。

過程中有一個本機唯讀查詢因為 grep 讀到 stdin 而卡住,我已用 TaskStop 停掉,並以 `ps` 確認 WSL 與主機上都沒有殘留程序。

證據分級:✅ 已驗證(附輸出或行號);⚠️ 原始碼推論;❌ 沒做。

---

## 1. v17 發現的去向

| v17 B | 結論 | 證據 |
|---|---|---|
| B1 配對判定分辨不了 | 判定改看 public 位址 + 同 build 翻轉,**方向對**;但回合結構有洞,見 N1 | |
| M1 SC 證據放 logread | **關了** ✅ | 見 §3 |
| M2 RPA 測試 | **關了** ✅:RPA 先做;最高兩位元 `01` + ah() 驗證;三段,含不重新註冊與 timeout 前重新註冊兩個負對照;`agent off` | `agent off` → `adapter_set_io_capability(INVALID)` → `SET_BONDABLE 0`(`adapter.c:9077-9085`)✅。bluetoothctl 剛啟動、還沒 `agent off` 的那幾秒 bondable=1,但那時還沒開廣播、不能被連,所以無害 |
| m1 `mgmt.sc on` 看不出 | 關了(§3 改字) | |
| m2 GATT 只是 smoke | 關了 | |
| m3 Q8 副作用 | 大致關了;剩 m3 | |
| m4 L 編號重複 | **沒關,而且產生了新的重複**(m1) | |
| m5 過時文字 | 部分;剩 m2 | |
| m6 / m7 / m8 | 關了 | |

**wsl.8 出貨物**(`/home/yello/out/1.5.12-wsl.8+f2f2bf6.fw3ec5e9b`,我自己解開)✅:
- `etc/bluetooth/` 只剩 `main.conf`,空的 `keys` 目錄沒了;
- init 有 `store_ok`;
- main.conf 有 `SecureConnections = only`;
- `strings bluetoothd` 有 `Batman: SecureConnections mode %u requested`(1 筆);
- keep.d 與 opkg info 裡都沒有 bluetooth 的 conffiles;
- `LEAdvertisingManager` 只出現在 `bluetoothctl` 與 `bluetoothd`,也就是 PR-F 沒有廣播者;
- gate:`check-pvs-shim: OK (sha256 c1446ce4…`。

wsl.9 的 build 樹:`src/bluetoothd-adapter.o`(10-19 14:18)內有 `batman-sc` 字串 ✅,所以新 patch 已編進去。wsl.9 的 artifact 還沒出來 ❌。

---

## 2. 發現

### N1(MAJOR)§9 `ble-pair-sc-only-254` 的回合結構:第三段分辨不了;目標段的失敗判定不夠嚴

**情境 1:第三段永遠失敗,不論 patch 900 有沒有作用。**
- §9 第 3 步寫:翻轉後「重做 2」,restart 04 的 bluetoothd 後再「重做 2」;第 4 步寫「每輪之間重啟 02 的 bluetoothd」。
- 但 02 跑的是**同一個 PR-F build**。02 的 bluetoothd 一重啟,patch 900 就把 **02 自己**的 SC 改回 only(`adapter.c:10344-10361`,每次接管 adapter 都送)✅。同時 02 的 bondable 也會依 agent 狀態重設。
- 如果下一輪只「重做 2」(`mgmt.pair`)、沒重做第 1 步(`mgmt.sc off`、`mgmt.bondable off`),02 送出的是 **SC** 配對請求。04 這邊是 SC Just Works,一律要 user confirm(`smp.c:2206-2216`),而 04 沒有 agent → 被拒。
- 這個拒絕在「04 有 SC-only」與「04 只有 SC on」兩種狀態下都一樣。
- 所以第三段(驗證 bluetoothd restart 後 SC-only 重新生效,也是 patch 900 第 (2) 段與 L22 的負對照)**一定得到「失敗」**,即使 patch 900 沒作用也一樣 → 假 PASS。
- 翻轉段如果也這樣跑,會因為「不外洩」而露出來(這是好事,但會白跑一輪)。

**情境 2:「配對失敗」的判定字串不對,也太寬。**
- 第 2 步寫目標 = 配對失敗「(Authentication Requirements)」。
- 實際上 02 端的 mgmt 回覆:對方送來的任何 Pairing Failed 都走 `smp_failure()` → `mgmt_auth_failed(hcon, HCI_ERROR_AUTH_FAILURE)`(`smp.c` `smp_failure`)→ status **0x05 `Authentication Failed`**(`mgmt.h:32`)✅。02 這邊看不到 SMP 的拒絕原因碼(0x03 或 0x05 都長一樣)。
- 照字面比對「Authentication Requirements」→ 永遠對不上 → 假 FAIL。
- 如果放寬成「failed 就算」→ 沒連上(`0x04 Connect Failed`、`0x08 Timeout`,例如 RPA 在掃描與配對之間換掉了,或測試廣播已經停了)也會被當成 PASS。

**修法(只改 §9 的字):**
1. **每一輪 = 第 1 步 + 第 2 步**,而且在**同一個** 02 bluetoothctl session 裡:在 `mgmt.pair` 的**前一行**印出 `mgmt.info`,斷言沒有 `bondable`、沒有 `secure-conn`。斷言不成立 → 這一輪無效,重做,不判定。04 也在每輪前斷言(第三段要多斷言 `batman-sc` 的 pid 是新的)。
2. **判定表:**

   | 結果 | 判定 |
   |---|---|
   | `Paired with 88:A2:9E:B5:6C:8B (LE Public)`,或 02 的 `devices` 出現 public 位址 | 外洩 |
   | `failed. status 0x05 (Authentication Failed)`,且之前有 Device Connected 事件(或 02 的 `mgmt.con` 列出該連線) | 擋下 |
   | 其他(0x04 / 0x08 / 找不到裝置 / 斷言不成立) | **無效,重做;不是 PASS** |

3. **三段照「目標 → 翻轉 → restart」的順序夾著跑**,翻轉段必須外洩,本次結果才算數。這樣目標段與第三段的「擋下」都夾在一個證明測試裝置有效的段落旁邊。

---

## MINOR

- **m1. §5 的編號又重複。**
  - 原本第二組的 L19–L22 改成 L23–L26,但表裡本來就有 L23(改名)、L24(兩支手機)、L25(交易進行中)、L26(`network/update`)。
  - L32 現在寫「同 L24」,指向不明。
  - 修法:改用沒用過的號碼(例如 L62–L65),並把所有引用一起改。
- **m2. 過時文字**(都和 v17 前的 sc-only / log 契約有關):
  - §10 第 1 點仍寫「**privacy + sc-only 在 current settings**」——current settings 沒有 sc-only,這是誇大;
  - §3 儲存區那一列的讀者仍寫「讀 privacy / **sc-only** / bondable 旗標」;
  - D25 仍寫「Linux central + **btmon**」(新程序不用 btmon);
  - L22 的測試欄仍寫「log 有本次的 mode 2 行」,應改成 `batman-sc` 的 pid 換新、mode=2、status=0,外加 N1 的配對第三段;
  - Q8 寫「02 還原 = `batman-slot rollback`」,同一格又寫「測完 02 留在 PR-F build」,要擇一。若留下,「刪 p1 那一行」也不必做。
- **m3. 02 的 p3 沒處理。**
  - Q8 只改 02 的 p1 `core_freq_min=500`。之後 02 的 OTA 會落到 slot B,韌體讀 p3,p3 沒有那一行 → BT UART 時脈不對。
  - `ble-ok` 也要求 p1、p3 兩份都有。
  - 修法:02 也改兩份,或寫明只改 p1 的後果與時機。
- **m4. ah() 的實作要先用 Core spec 的範例向量驗過**(Vol 3 Part H §2.2.2 的 sample data)。
  - BlueZ 存 IRK 的十六進位字串,與 kernel / spec 的 byte order 不同,實作錯了會得到假 FAIL(不是假 PASS),但會被誤歸因成「privacy 沒生效」。
  - 從 04 讀出的 IRK 不要進 harness log 或 PR body;測後重開 04 作廢,這點已寫。
- **m5. `batman-sc` 只有一個檔、帶 `index`。** 多 adapter 時是最後寫的贏。§3 的 `sc_file=1` 條件要加「`index` = helper 檢查的那個 hci」;今天只有 hci0,不是回歸。
- **m6. patch 900 的 `batman_sc_complete` 把 `adapter` 當 user_data,沒有 ref**(`mgmt_send(…, batman_sc_complete, adapter, NULL)`)。
  - 與上游 `set_mode()` 的 `set_mode_data->adapter` 是同一種寫法(`adapter.c:757-790`)✅;adapter 在指令完成前被移除的處理也跟上游一樣。
  - 可接受,記一筆即可。

---

## 3. 07f20637 / patch 900 新段落的核對(✅ 原始碼)

- **送出時機**:`read_info_complete` 只要 `supported_settings` 有 SECURE_CONN 就送;`mgmt_send` 失敗(回 0)→ 記 `status=0xff`(`:10356-10361`)。
- **完成回呼**:先 `batman_sc_record(status)`;失敗時記錄 mode 並 return;成功時照上游呼叫 `new_settings_callback`(`:10222-10234`)。LE-only 分支的 `send_settings_rsp` 回的就是 settings,長度正確(`mgmt.c:6918`)。
- **內容與寫法**:
  - `boot_id` 讀自 `/proc/sys/kernel/random/boot_id`,去掉換行;
  - 檔名 = STORAGEDIR + `/batman-sc`(`create_filename`,`textfile.c:31`);
  - `g_file_set_contents` 先寫暫存檔再 rename,原子;
  - bluetoothd `umask(0077)`(`main.c:1383`)→ 檔案 0600;
  - 父目錄是 init 驗過的 root 0700 → 非 root 無法寫入或替換。
- **stale 處理**:bluetoothd respawn 後如果沒有 hci0,檔案留著舊 pid → 讀者比對「活著的 bluetoothd」就判 0(fail-closed)。這與 §3 的契約一致。
- **擋不到的情況**:root 事後 `mgmt.sc on` 時檔案仍寫著 mode=2,§3 已誠實寫明。

## 4. 沒做的(❌)

- wsl.9 artifact 還沒出來,`batman-sc` 沒在出貨物或節點上驗過;
- 空中測試全部沒做;
- bcm2710 沒驗。

## 5. 結論

v18 把 v17 的三個主要發現都收了,patch 900 的新段落寫法正確,wsl.8 出貨物也符合 v17 的宣稱。

剩下 N1:§9 配對程序的回合結構,與「擋下」的判定條件。改字後只需要窄範圍複查 §9 與 Q8 這兩處。
