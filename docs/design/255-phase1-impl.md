# #255 第 1 期實作設計：bench 上以 608B 作為節點身分（v2）

範圍：把 bench 上的空白 ATECC608B（`255-608b-config.md` v4）接成節點的身分後端，並讓協定、app、驗證工具配合。**只在開發版生效**：field 版 app 第 1 期之後仍拒絕所有節點（量產根要等選定量產晶片與 #256）。
不含：信任模型（第 2 期）、量產晶片、secure boot、晶片背書、入庫計數器（晶片設定 §10）。
依據：`255-608b-config.md` v4；`255-key-authority.md` v3.1（K13–K16、K20、K21 約束本期）；`255-threat-model.md` v2.1。
基準：main 4eba26d，加上 PR 1（#379，`Identity` 介面，未 merge）。節點路徑以 `feed/batman-prov/src/` 為根；app 的 Rust 以 `app/rust/` 為根。標記：✅ 對過原始碼；⚠️ 推論或未驗證。

| 版本 | 審查 |
|---|---|
| v1 | A：REJECT（1 / 7 / 14）；B：REJECT（2 / 10 / 12）。兩位都同意 PR 1 縮成純重構後可先做（已做，#379） |
| v2 | 收兩位意見；配合晶片設定 v4 拿掉背書。對應：`255-reviews/phase1-v2-changes.md` |

## 0. 決定（技術細節，由作者定案並說明理由）

| # | 決定 | 理由 |
|---|---|---|
| P1 | **晶片驅動用純 Go 自己寫**（helper 內，經 `/dev/i2c-1`），不用 cryptoauthlib，也不用第三方 Go 套件 | helper 不用 C 函式庫；驗證工具與 CI 都以 `CGO_ENABLED=0` 建置（`dv-sbx.sh:69,80`、`tests/wbox/gen/gen.sh:40`）✅；cryptoauthlib 沒有 OpenWrt 套件；現有純 Go 套件沒有人審過（F§15）。本期只需要 9 個指令（§2.2） |
| P2 | **身分後端由建置決定，不在執行期探測**：Go build tag `prov_se`，由建置參數 `BATMAN_PROV_SE=1` 打開。這種 helper 只有晶片後端，**沒有產生軟體身分的程式碼**。只給 bcm2711（Pi 4）建置；bcm2710 沒有晶片版。建置、版本標記、出貨閘門、CI 的配合見 §2.8 | 執行期探測時，晶片暫時無回應會讓有晶片的機器產生軟體身分（審查 v3-A M5、v3-B M5）。這取代晶片設定 v3 §9-5 的「資料分割區標記 + 探測」，v4 已同步。代價：Pi 4 多一種映像要建置、釘版本、驗證 |
| P3 | **晶片映像的身分目錄是從晶片導出的快取**：`backend=se`、`device_id`、`chip_sn`、`cert`（槽 8 的副本）加 sha 清單，經今天的保存路徑存到 p5。它沒有任何秘密 | 讓今天的開機對帳、保存、降版判斷照常運作（舊 helper 看到 `backend=se` 會拒絕載入，`keystore.go:266-267`）；不另做一個 p6 標記（審查 v3-B M5） |
| P4 | **每次連線的身分證明放在 msg2 之後的第一個請求** `id/prove`；**驗證用的公鑰一律從已驗過的憑證導出**：檔案樣式 = 憑證金鑰；晶片樣式 = 憑證擴充欄位裡的槽 0 公鑰。`node_cert` 沒有「證明金鑰」欄位 | msg2 之後才有最終的交握雜湊 `h`（`noise.go:105`）✅。不從未驗過的欄位取金鑰，就擋住 v1 的 B1（重放 `node_cert` 換掉證明金鑰） |
| P5 | **`id/prove` 不走 helper 全域每秒 2 次的簽章限制**；每條連線只能一次 | 共用限制時，會員或陌生人反覆連線就能讓擁有者登入拿到 `ERate`（審查 phase1-A M1）。上限由結構決定：provd 的連線槽數（BLE + sock 2、HTTP 2）、每條連線一次、交握本身的成本；晶片本身簽章約每秒 8 次（F§9） |
| P6 | **檔案後端也改用每次連線的證明，拿掉 `sig_static` 與 `boot_id`** | 兩種樣式同一條登入路徑。這是協定改動，放 PR 3（審查 phase1-B B1） |
| P7 | **不做協定相容，但驗證工具兩版都懂**：PR 3 merge 後，舊 app 不認新節點、新 app 不認舊節點。H0 的工具依欄位組合分辨 v1 / v2。PR 3 等 v1.6 結束才 merge | 不打斷另一個 session 的 v1.6 驗證（審查 phase1-B M10）。檔案樣式的憑證 DER 不變，app 釘的是 DER（`nodecert.rs:126-133`），所以 02 / 04 升級後**不必重新認領** |
| P8 | **燒錄是 helper 的命令列模式**，開發根的簽章在開發者電腦上做（晶片設定 §5） | 只有 helper 碰晶片（K21）；開發根私鑰不放節點 |
| P9 | **晶片的簽章由 helper 轉成 low-s** | 晶片的 ECDSA 約一半是 high-s，專案拒絕 high-s（`proto.go:117`、`sig.rs:121`）（審查 phase1-A m1） |

## 1. 現況（✅ main 4eba26d + #379）

- 身分：PR 1 已把 helper 對身分的使用改成 `keystore.Identity` 介面（`SN`、`DeviceID`、`Cert`、`DACPub`、`ECDHPub`、`ECDH`、`CheckMac`、`SignPurpose`、`Backend`），唯一實作仍是檔案後端；`Backend()` 固定 "file"，載入時拒絕其他值（`keystore.go:266-267`）。
- 開機對帳：`boot.Run` 在載入身分之前執行（`main.go:631`），依 p5 的回傳碼（0、7、9、10、13、1/8、3、11）分支；以 `identSum`（`keystore.Load` + sha 清單，`boot.go:51-57`）判斷有沒有身分；只在 rc 7、9 產生身分（`boot.go:207, 231`）；覆蓋層與 p5 的身分不同時凍結為 `unknown(identity-mismatch)`（P-U6）。
- 沒有身分時 helper 不開始服務，而且**永遠不重試**（`main.go:632-636`，`select {}`）。
- 試用開機：provd 連上 helper 滿 60 秒後，**helper** 寫 `$RUNDIR/provd-stable`（`stable.go:30-50`，寫一次就閂住），autocommit 每次輪詢重讀（`batman-autocommit:508-512`）；`is-trial` 回傳碼不是 1 一律當試用（`trial.go:31-35`）。
- 節點證書由 provd 組成：`{1:[cert], 2:s_node, 3:boot_id, 4:ecdh, 5:sig_static, 6:sig_ecdh, 7:sn}`（`server.go:306-363`）；app 檢查 `cert[2]` 等於交握的對方靜態金鑰（`nodecert.rs:104`）。
- 認領：`CheckMacInput` 用 `sn[8]`、`sn[0:2]`（`proto.go:54-70`）；`ClientChal` 雜湊整張憑證（`proto.go:48-52`）。`provclient node claim` 在節點上以 root 讀 `claim.secret`（`tests/tools/provclient/main.go:517`），約 25 個 DV 單元經它認領；擁有者的簽章已經由主機端回答（`SIGN` / `SIG` 行，`main.go:9-10`）。
- `claimed_counter` 是 provstore 紀錄的欄位（`provstore.go:52, 94`；`node.go:592`），不是身分檔。本期不動。
- 碰身分檔、`claim.secret` 或 `sig_*` 標籤的檔案：約 47 個（審查 phase1-B 的統計），另約 25 個 DV 單元經 `provclient` 用到 `claim.secret`。H0 開工時以 grep 重新列出完整清單。
- 登入基準（#329）：連線到讀完狀態 2.8–5.6 秒；10 次登入 9 次 ≤ 20 秒（`329-app-uiux.md:998, 1021`）。

## 2. 節點端

### 2.1 身分介面（PR 3 之後）

| 方法 | 檔案後端 | 晶片後端 |
|---|---|---|
| `DeviceID()` | `SHA-256(DAC 公鑰)[:9]` | `SHA-256(槽 1 公鑰)[:9]` |
| `SN()` | 同 `DeviceID` 的位元組（認領證明照舊） | 晶片序號（設定區 0–3、8–12） |
| `Cert()` | 自簽 `dev:` 憑證 | 槽 8 的開發根憑證 |
| `ECDHPub()`、`ECDH(peer)` | 檔案 ECDH 金鑰 | 槽 2，明文輸出（bench 不開匯流排保護） |
| `SignPurpose(p, fields)` | DAC 簽 | 槽 0 外部簽章：直通 nonce 載入 `SHA-256(label ‖ fields)` 再簽 |
| `CheckMac(chal, resp)` | 軟體計算 | 晶片的 CheckMac，槽 5 |
| `Backend()` | "file" | "se" |

- `SignPurpose` 的用途是固定列舉：PR 3 加 `Session`（`"batman-node-session-v1" ‖ h`，`h` 剛好 32 位元組）；刪除 `Static`；`ECDH` 只留給檔案後端；`Peer` 不變（未來的 `peers/challenge` 用，標籤不同且含 `nonce_node`，所以不能拿來當 `id/prove`）。晶片後端沒有任何「替外部資料背書」的方法。
- 沒有 `Endorsements()`、`Counter()`（v1 的這兩個拿掉）。

### 2.2 晶片驅動（`se608` 套件）

- I2C：`/dev/i2c-1`，`ioctl(I2C_SLAVE = 0x0703, 0x60)`（常數自己定義），100 kHz。開啟前以 `lstat` 確認它是字元裝置、不是符號連結、root:root、權限 0600，否則拒絕（審查 phase1-A M7）；權限由晶片映像附的 hotplug 規則設定。
- 喚醒：對位址 0x00 寫一個位元組，讀回 `0x11`；每個序列結束送閒置。封包：計數 + 指令 + CRC-16（0x8005）；輪詢等待，逾時用最快時脈的上限（F§9）。
- **序列器與鎖**：helper 常駐終生持有晶片鎖（root 專用執行目錄下的鎖檔，`flock` 獨占）；驅動內一個互斥鎖讓一次只跑一個指令序列。燒錄模式拿不到鎖就拒絕（晶片設定 §5.1）。
- **產品需要的指令（9 個）**：Info、Read、Write、Lock、Nonce（只有直通）、GenKey、Sign（只有外部）、ECDH、CheckMac。Write、Lock、GenKey 只有燒錄模式會呼叫。
- **不實作**：Random、Nonce 亂數模式、內部簽章、GenDig、MAC、SHA、KDF、AES、Counter、UpdateExtra、DeriveKey、PrivWrite。這些只在 `se-lab` 裡（§5）。登入路徑因此不跑會更新 EEPROM 亂數種子的指令（審查 v3-B m11）。
- 單元測試：以 cryptoauthlib 主機端演算法產生的向量比對封包、CRC、CheckMac 的雜湊輸入。E1 / E8 / E14 擷取的真實回應回填成第二組向量（stub 格式取自真機的教訓）。

### 2.3 開機（晶片映像）

1. **在開始服務前**讀晶片，依晶片設定 §5.2 分類：已燒錄（S4）、燒錄未完成（S0–S3）、非本設定的晶片、無回應。只有 S4 往下走；其他狀態寫 log 與 p6 的 `prov-state` 一行，**不打開 helper 的 socket**，每 10 秒重試第 1 步（這是新行為，取代今天的 `select {}`）。
2. 已燒錄：讀槽 0 / 1 / 2 公鑰與槽 8 憑證，確認憑證的主體金鑰 = 槽 1 公鑰、擴充欄位的槽 0 / 2 公鑰與序號都和晶片相符；不符 = 燒錄未完成。
3. 執行 `boot.Run`，晶片映像的差別如下表（其餘與今天相同）：

| p5 回傳碼 | 今天（檔案映像） | 晶片映像 |
|---|---|---|
| 身分比對（任何 rc 之前） | 覆蓋層與 p5 的身分不同 → 凍結 `unknown(identity-mismatch)` | 同；**另外**：覆蓋層或 p5 的身分目錄 `device_id` ≠ 晶片的 → 凍結 `unknown(identity-mismatch)`；`backend=file` → 凍結 `unknown(backend-mismatch)`。兩者都不寫、不作廢任何紀錄 |
| 0 | 從 p5 還原身分與紀錄 | 同（還原的是快取，接著第 4 步重新比對晶片） |
| 7（新卡） | 沒有身分 → 產生軟體身分 | 沒有身分 → **由晶片寫出身分快取**（不是產生金鑰）並保存到 p5；未認領 |
| 9（舊版升級） | 產生，legacy | 由晶片寫出身分快取，legacy |
| 13（p5 缺身分） | 只在同一序號時重新保存 | 同（序號 = 晶片的 `device_id`） |
| 其他 | 不變 | 不變 |

4. 身分快取的完整性：sha 清單涵蓋 4 個檔案（審查 phase1-A m9）；`identSum` 在晶片映像 = 清單正確且 `device_id` 等於晶片的。
5. 開始服務（打開 socket）。

**換 HAT**：新晶片的 `device_id` 與 p5 的不同 → 凍結（與今天 P-U6 相同），不作廢紀錄、不動網路金鑰與 SSH 金鑰；復原 = 重燒卡。v1 與晶片設定 v3 §9-6 的「自動作廢、改為未認領」拿掉：那會讓 5 分鐘的實體接觸就重設擁有權（審查 phase1-A M4、v3-B m4）。

### 2.4 試用開機與晶片故障

- 試用時晶片在第 1 步就失敗：socket 不打開 → provd 連不上 → `provd-stable` 不寫 → 試用逾時回退（今天的機制）。晶片在逾時前恢復：開始服務、照常確認。
- **已開始服務後晶片失敗**：該請求回錯誤，下一個請求重試晶片一次（不閂鎖）。**若此時是試用**（`is-trial` 回傳碼不是 1，沿用今天的保守判斷）：helper 刪除 `provd-stable` 並在這次開機不再寫它，autocommit 下一次輪詢就看不到，試用不會被確認（審查 v3-B M4）。helper 是 `provd-stable` 唯一的寫者（`stable.go`），所以這是同一個擁有者的行為。
- 沒有 A/B 的卡（`is-trial` 回 2）：照上一條會不再寫 `provd-stable`，但沒有回退機制；helper 照常服務並重試晶片，所以只有「確認」這件事不會發生，這種卡本來就沒有確認流程。

### 2.5 燒錄（`batman-provhelper se-burn`）與 `se-sign`

照晶片設定 §5。補充實作細節：

- 節點端只有一個命令 `se-burn`，每次執行讀晶片狀態後做下一步（S0 → S1 → S2 → S3）；S1 從 stdin 讀秘密；S3 輸出資料包到 stdout（JSON，無秘密），再以 `se-burn cert < cert.der` 寫槽 8。
- 開發者電腦的 `tools/se-sign/`：`se-sign begin <host>` 產生秘密、寫燒錄紀錄（「待寫入」）、經 ssh stdin 交給 `se-burn`；`se-sign sign <bundle>` 驗資料包並簽憑證、產生 QR 圖檔；全部檔案 0600，放晶片設定 §5.4 的目錄。秘密不出現在命令列參數、終端機或任何 log；驗證工具的輸出遮蔽規則加一條（只印秘密雜湊的前 8 個字元）。
- 拒絕條件：常駐程式在跑（拿不到鎖）、試用開機、沒有 console 也沒有開發模式。
- 晶片映像的 `provhelper qr` 回「不支援」（秘密在晶片裡讀不出來）。

### 2.6 provd

- `buildNodeCert` 改組 v2 欄位（§3.1）；不再呼叫 `sign.static`；晶片樣式也不呼叫 `sign.ecdh_proof`。
- 新請求 `id/prove`：所有角色（含匿名）都可送，每條連線一次，回 `SignPurpose(Session, h)`；不經全域限制（P5）。
- `peers/challenge` 維持拒絕。
- 對 helper `info.boot_id` 的輪詢保留（`server.go:442-449`），雖然 `boot_id` 不再進 `node_cert`（審查 phase1-B m5）。

### 2.7 誰能碰晶片

- 只有 helper（含燒錄模式）。`/dev/i2c-1` 0600 root（§2.2）；provd 的 uid、沙箱與承租容器都打不開（§4 有負向測試）。容器執行環境不給這個裝置。
- `batpower` 在程式裡拒絕位址 0x60（不只靠 uci 設定值）（審查 v3-A m16）。

### 2.8 建置、版本標記、出貨閘門（P2 的配合）

| 項目 | 做法 |
|---|---|
| Go | build tag `prov_se`；`Makefile` 由 `BATMAN_PROV_SE=1` 帶入（同 `BATMAN_PROV_TEST`，`Makefile:23-30`） |
| 重新建置 | firmware fork 的 `build-board.sh` 比照 `prov_test` 的做法，記錄上次的參數，不同就清掉 helper 的建置（OpenWrt 的 stamp 不含環境變數，審查 phase1-B M2）。這是 firmware repo 的 PR，列在 §9 |
| 版本標記 | `batman-provhelper --version` 印出後端；`/etc/batman-build` 加 `BATMAN_PROV_BACKEND=se|file`（firmware fork 的 `stamp-batman-build.sh`） |
| 映像內容 | 晶片映像要有 `kmod-i2c-bcm2835`、`kmod-i2c-dev`、`dtparam=i2c_arm=on` 與 hotplug 規則，經 board diffconfig（絕不裸跑 `make defconfig`）。⚠️ 今天的映像是否已有，E0 確認 |
| 出貨閘門 | 兩個方向都檢查：晶片映像的 helper 必須是 se 後端，檔案映像的必須不是；任何出貨映像都不能含假晶片、`se-lab`、不含鎖定指令的實驗建置、或 `prov_test` × `prov_se` |
| CI | `go test` 加 `-tags prov_se` 與 `-tags prov_se,prov_test` 兩步（H0 先加，任何 SKIP = FAIL 的規則不變） |

## 3. 協定

### 3.1 `node_cert` v2（`219-protocol.cddl` 同步修改）

| 欄位 | 檔案樣式 | 晶片樣式 |
|---|---|---|
| 1 憑證 | 自簽 `dev:` | 開發根簽發（下表） |
| 2 s_node | 有；app 照舊檢查等於交握的對方靜態金鑰（`nodecert.rs:104`） | 同 |
| 3 boot_id | 刪除 | 刪除 |
| 4 ecdh_pub | 有 | **不可出現**（取自憑證） |
| 5 sig_static | 刪除 | 刪除 |
| 6 sig_ecdh | 有 | **不可出現** |
| 7 sn | `device_id` 的位元組 | 晶片序號，必須等於憑證擴充欄位裡的序號 |

晶片樣式的憑證（本期定案；寫進槽 8 後若要改，重跑晶片設定 §5 S3）：

| 項目 | 內容 |
|---|---|
| 格式 | X.509 v3，完整 DER，≤ 416 位元組（槽 8；E15，PR D 時在開發者電腦上先算） |
| 簽發者 | 開發根（P-256，自簽 CA，只用於 bench） |
| 主體 | CN = `se:<device_id>` |
| 主體金鑰 | 槽 1 公鑰 |
| 擴充欄位 | 私有 OID，非關鍵，內容 CBOR `{0: 槽 0 公鑰, 2: 槽 2 公鑰, 7: 晶片序號}`（公鑰用 33 位元組壓縮格式以控制大小） |
| 有效期間 | 燒錄日起，到 9999-12-31（bench 單元，不靠到期換發） |

### 3.2 app 的驗證（`nodecert.rs`）

- 依簽發者判斷樣式：自簽 `dev:` = 檔案樣式；開發根簽、CN 以 `se:` 開頭 = 晶片樣式；其他一律拒絕（包括開發根簽的 `dev:`、自簽的 `se:`）。欄位組合必須完全符合該樣式。
- 晶片樣式：憑證鏈到開發根（開發根公鑰只編進開發版 app）；`device_id = SHA-256(憑證主體金鑰)[:9]`（`nodecert.rs:177-180` 不變）；擴充欄位必須剛好有 0、2、7 三項。
- **`id/prove`**：收到 msg2 後立刻送，驗 `"batman-node-session-v1" ‖ h` 的簽章，公鑰 = 檔案樣式的憑證金鑰 / 晶片樣式擴充欄位的槽 0 公鑰（P4）；驗過之前不送任何其他請求，也不保存任何東西（`claimflow.rs:168-182` 的 `PersistPending` 移到證明之後，審查 phase1-A m6）。三個交握驗證點都要做：`loginflow`、`claimflow`、`replayflow`（審查 phase1-B M9）。
- `ecdh_pub` 的可信來源：檔案樣式 = 欄位 4 + `sig_ecdh`；晶片樣式 = 擴充欄位的槽 2 公鑰。之後所有用到 `ecdh_pub` 的地方都從已驗過的紀錄取值，不改。
- `trust_gate`：開發版接受兩種樣式；field 版兩種都拒絕。晶片樣式的分支只在 `DEV_TRUST` 下編譯，並放在今天的 `dev:` / `Untrusted` 判斷之後（§3.4 有 field 版的負向向量）。
- `verify_offline`（三段式加入時離線驗證申請裡的節點證書）：沒有 `h`，無法驗當場證明。兩種樣式都只驗憑證與欄位組合；`nodecert.rs:164` 的「剛好 1–7 號欄位」改成依樣式。**這條路在第 1 期沒有當場證明，是 K20 的一個偏離**，第 2 期移除這條路（信任模型 Q5）。列為 §10 Q4。
- 節點端密碼包的對象：`SHA-256(身分公鑰)`（`wtxn.go:132-135`），兩種樣式一致。

### 3.3 認領

- `CheckMacInput` 不變；`sn` 來源不變（第 7 欄），晶片樣式下它是晶片序號。`ClientChal` 雜湊的是整張憑證 DER，晶片樣式下就是開發根憑證，認領證明因此仍綁住身分金鑰（審查 v3-A m13）。
- QR 不變：`{1: device_id, 2: 認領秘密}`，由 `se-sign` 產生。

### 3.4 測試向量

`tests/vectors/219-protocol/` 加入晶片樣式與負向向量：晶片樣式多了欄位 4 或 6；擴充欄位的槽 0 公鑰被換掉（`id/prove` 用換掉的金鑰簽 → 拒）；欄位 7 與擴充欄位序號不同；開發根簽的 `dev:`；自簽的 `se:`；field 版拿到有效的晶片 `node_cert`（`verify_first_contact` 與 `verify_offline` 都要 `Untrusted`）；`id/prove` 的簽章換成另一條連線的；high-s 簽章（要被拒，且 helper 的輸出一定是 low-s）。`fakeMsg2` 的長度要隨 `node_cert` 變長而等於真實 msg2（`noise.go:108-109`），加測試，並檢查晶片樣式的 msg2 在框架與 MTU 限制內（審查 phase1-B m11）。

## 4. 驗證工具與測試

### 4.1 H0（harness PR，先進 main；對 v1.6 與之後的產品都能用）

- **主機端回答認領挑戰**：`provclient node claim` 在節點上不再讀 `claim.secret`，改成像擁有者簽章一樣在 stdout 輸出 `MAC <ClientChal hex>`，由主機端的 `provclient mac <紀錄>` 回答 `MACR <hex>`（審查 phase1-B B2）。檔案節點的「紀錄」= 從節點複製回主機的 `claim.secret`；晶片節點的紀錄 = 晶片設定 §5.4 的燒錄紀錄。
- **log 洩漏檢查搬到主機端**：`prov-claim-254.sh:49-51`、`scripts/node/prov-p1-254.sh:63-66` 改成把 logread 複製回主機，用主機端的秘密比對。
- `node_cert` v1 / v2 依欄位組合分辨：`tests/tools/peer/*`、`provclient`、`app/tools/synth-joinreq`、`tests/tools/peer/netobj.py`。
- `ci-check.sh` 的 `MIN_CHECKS` 依向量版本分開計（v2 向量拿掉 `sig_static` 的檢查後數量會變，`ci.yml:93`）。
- preflight：讀 `/etc/batman-build` 的後端；節點清單標明每台是晶片節點或檔案節點，不符就拒絕執行；**不把檔案映像裝到晶片節點**（§7 的降版列）。
- CI 加 `prov_se` 兩步（§2.8）。
- `app/tools/check-field-build.sh` 加一條：field 版不含開發根公鑰。

### 4.2 各 PR 的測試

| 類別 | 內容 |
|---|---|
| 假晶片（PR D） | 有狀態：設定區與資料區、兩區的鎖、每槽的鎖、真的 P-256 金鑰、CheckMac 真的比對；能模擬「N 次無回應後恢復」。狀態碼與位元組格式在 E1 / E8 / E14 之後換成真機擷取 |
| 燒錄（PR 2，假晶片） | 每個狀態 S0–S3 中斷後重跑都能接續；S1 中斷後秘密仍在開發者電腦（同一秘密重寫）；兩顆晶片的憑證互換 → S3 拒絕；試用開機時燒錄 → 拒絕；常駐程式在跑時燒錄 → 拒絕 |
| 開機（PR 2） | §2.3 表的每一列（含換 HAT 凍結、`backend=file` 凍結）；晶片映像在任何情況下都不產生 `node.key` |
| `prov_test` 接縫（PR 2） | `se-fail` killpoint：讓驅動回「無回應」，在真的晶片節點上變成 DV 單元：開機時無回應；試用中無回應 → 回退；服務中無回應 → 恢復後照常；試用中服務後才失敗 → 不確認（審查 phase1-B M6） |
| 協定（PR 3） | §3.4 的向量；Rust 測試含三個交握驗證點都做 `id/prove` |
| 爭用（PR 3） | 兩個會員連線反覆送 `id/prove`，擁有者同時登入，要在基準時間內成功（審查 phase1-A M1） |
| 權限（PR 2） | 以 provd 的 uid、與在承租容器內 `open("/dev/i2c-1")` → EACCES |
| 出貨閘門（PR 2） | §2.8 兩個方向，各附一個會被抓到的錯誤建置 |
| 登入時間（PR 3 + 晶片） | 同一支手機（S20）、同一個 R-7 程序，檔案節點與晶片節點各 10 次登入，改動前後各一組；預期增加一個 GATT 來回加一次簽章（晶片 ≤ 200 ms，E14）；結果交給使用者決定（K15，§10 Q5） |

- 負向對照：產品改動前的程式失敗的，照常；晶片映像沒有「舊程式」，改用明確的變異體（例如一個 wbox 修補讓晶片映像退回檔案後端，必須讓「不產生 `node.key`」的測試失敗）（審查 phase1-B m6）。
- 手動、無法自動化的（拔晶片、換 HAT、斷電）列為手動測項，結果附在 PR。
- 在晶片節點上**不跑**的單元：`prov-downgrade-254`、`prov-legacy-upgrade-254`、`negctl-old-slot`（它們刻意裝舊映像或檔案映像）。這是覆蓋率的損失，寫進 #255 的清單。

## 5. 晶片實驗程式

`tools/se-lab/`，規則見晶片設定 §8.0。它和產品驅動共用封包與 CRC 的程式碼，另外實作產品沒有的指令；PR D 交付，E0–E3 用不含任何鎖定指令的建置。

## 6. 擁有權、契約

| 資源 | 唯一能改的 | 只讀 |
|---|---|---|
| 晶片與匯流排上的晶片狀態 | 持有晶片鎖的程式：helper 常駐（序列器）或燒錄模式；`se-lab` 只在實驗台 | — |
| 身分快取目錄（覆蓋層） | helper 的開機對帳 | `prov-lock.sh`、`batman-config-save`、腳本 |
| p5 的身分 | `batman-config-save`（保存，`:521-536`）；`96-batman-config-migrate`（升級時搬移，`:160-163`）——兩者的檔案清單改成依 `backend` 決定 | helper 開機對帳 |
| `provd-stable` | helper | autocommit |
| 開發根私鑰、燒錄紀錄 | 開發者電腦的 `se-sign` | 驗證工具（只讀秘密，主機端） |
| `node_cert` | provd（由 helper 提供材料） | app、對端工具 |

| 介面 | 寫 → 讀 | 缺漏或錯誤 |
|---|---|---|
| `id/prove` | provd → app | app 拒絕連線，不保存任何東西 |
| `node_cert` v2 | provd → app | 欄位組合不符或驗不過 → 拒絕 |
| 身分快取目錄 | helper → 腳本 | sha 清單不符 → 腳本判 FAIL；helper 下次開機從晶片重寫 |
| `MAC` / `MACR` 行 | `provclient`（節點）↔ `provclient mac`（主機） | 主機沒有該節點的紀錄 → 不回答，單元 FAIL（不當通過） |
| `BATMAN_PROV_BACKEND` | firmware 建置 → preflight、出貨閘門 | 缺少 → 當成不明，preflight 拒絕 |
| 燒錄的秘密、資料包、憑證 | 晶片設定 §7 | 晶片設定 §7 |

## 7. 生命週期

| 路徑 | 今天 | 之後（晶片映像） | 測試 |
|---|---|---|---|
| 首次開機，晶片已燒錄 | 產生檔案身分 | 由晶片寫身分快取，未認領 | bench |
| 首次開機，晶片未燒錄 / 非本設定 / 無晶片 | — | 不服務，每 10 秒重試，**不產生身分** | 變體晶片；`se-fail` |
| 開機（已認領） | 照常 | 照常；身分快取與晶片比對 | DV |
| 正常關機、重開，或在指令序列中途關機 | — | 晶片進睡眠，暫存狀態全失；下次重跑整個序列（序列之間本來就不保留暫存區） | 序列中途重開 |
| helper 重啟 / 當機重啟循環 | 照常 | 每次啟動讀晶片（只讀與一次喚醒），不寫 EEPROM；`node_cert` 不變（沒有 `boot_id`、沒有背書） | 重啟 10 次後讀晶片狀態不變 |
| provd 重啟、bluetoothd 重啟 | 照常 | 照常（`node_cert` 由 provd 重組，內容相同） | DV 既有 |
| I2C 驅動 | — | 驅動編進映像、開機載入；開啟失敗 = 無回應，重試 | E0 |
| 試用開機，晶片在開機時失敗 | — | 不服務 → 回退 | `se-fail` DV |
| 試用開機，服務後晶片失敗 | — | 刪除 `provd-stable`、不再寫 → 不確認 → 回退 | `se-fail` DV |
| 試用開機，開機時短暫失敗後恢復 | — | 恢復後服務 → 照常確認 | `se-fail` DV |
| OTA 晶片映像 → 晶片映像 | 照常 | 身分快取經 `96-batman-config-migrate`（依 `backend` 的清單）搬移；與晶片比對 | DV（bench 晶片節點） |
| 回退到上一個晶片映像（K13） | 照常 | 同一顆晶片、同一個身分，可登入 | DV |
| OTA 檔案映像 → 晶片映像（節點有檔案身分） | — | `backend=file` → 凍結（試用就回退），**不作廢紀錄** | CI；bench 手動 |
| 晶片節點裝檔案映像（降版） | — | #255 之後的檔案映像：p5 有 `backend=se` → 拒絕產生身分、不服務。#255 之前的映像：會產生軟體身分（違反 K20），**不支援**：preflight 拒絕把檔案映像裝到晶片節點，相關單元在晶片節點上不跑（§4.2）。開發者手動刷卡仍可能發生 → §10 Q3 | CI（#255 之後的檔案映像拒絕產生） |
| 重燒 SD 卡（晶片映像） | 新的軟體身分 | **同一個** `device_id`，紀錄沒了 → 未認領。app 裡若還有這台的擁有者紀錄，登入會失敗（節點未認領），使用者重新認領後紀錄被取代。⚠️ app 在這條路的畫面要在 PR 3 確認 | bench |
| 換 HAT | — | 凍結 `identity-mismatch`，紀錄與金鑰不動；復原 = 重燒卡 | bench（兩片 HAT 互換） |
| 燒錄中斷電 | — | 晶片設定 §5.2，從讀回狀態接續 | 假晶片 CI；F1 手動 |
| 認領中斷電 | 照今天（紀錄交易） | 同（計數器本期不動） | DV 既有 |
| 晶片映像裝到沒有 `/dev/i2c-1` 的機器 | — | 無回應 → 不服務、重試 | CI |
| bcm2710（Pi 3） | — | 不適用：沒有晶片版建置（P2） | — |

## 8. 安全

- **新的輸入**：`id/prove`（任何人都能送，每條連線一次，不經全域限制，P5）；`node_cert` v2 的新欄位與憑證擴充欄位（app 端解析，欄位組合嚴格）；燒錄模式（root、console 或開發模式、非試用、拿到晶片鎖）；`MAC` / `MACR` 行（驗證工具，不進產品）。
- **逐個行為者**：
  - 遠端：只看得到 `node_cert` 與 `id/prove` 的簽章；重放 `node_cert` 不能通過 `id/prove`（金鑰取自憑證，P4）。
  - 本機非 root 程式與承租容器：打不開 `/dev/i2c-1`（§2.7，有負向測試）。
  - 被攻破的 provd：可以讓槽 0 簽任何 `h`（helper 無法檢查 `h`），也可以即時轉送證明。這等於 provd 被攻破（它本來就握有連線的金鑰），與今天的 `sign.static` 相同，列為殘餘風險（審查 phase1-A m3、phase1-B m10）。
  - 實體接觸（有 root 或能接匯流排）：可以讓晶片簽章、做 ECDH，等於節點被攻破；不能取出私鑰或認領秘密，也不能讓別的機器變成這台（換 HAT 會凍結）。bench 接受。
  - 燒錄時的節點：開發根相信節點回報的公鑰，所以只在剛燒好卡、開發者在場時燒錄（晶片設定 §2）。
  - 開發根外洩：能做出開發版 app 信任的假節點；開發版不對外，field 版不信任它。
- **秘密**：認領秘密只在開發者電腦與晶片裡；經 stdin 傳一次；不進 repo、log、命令列參數。開發根私鑰加密存放。晶片的 ECDH 明文輸出經過 I2C（bench 接受）。
- **失敗時**：拿不到身分就不服務（fail-closed）；任何不一致都凍結，不自動修正。
- 本期不改變：PSK、網路密碼的保管、認領鎖定。

## 9. 交付順序（同一張單，分 PR）

| 順序 | 內容 | 需要晶片 / 實驗結果 |
|---|---|---|
| H0 | §4.1（harness，先進 main） | 不需要 |
| PR 1 | `Identity` 介面（#379，已完成，等 v1.6 tag 後 merge） | 不需要 |
| PR D | `se608` 驅動核心 + 有狀態的假晶片 + 向量；`se-lab`（含不含鎖定指令的建置）；開發者電腦上先算憑證大小 | 不需要 |
| 晶片 | 實驗台：E0–E3 → 晶片設定 v4 已審過才 E4 → E5–E16 | 晶片已焊 |
| PR 2 | 晶片後端、開機、試用、燒錄模式、`se-sign`、§2.8 的建置與出貨閘門（另有 firmware fork 的 PR） | E5（OTP）、E6（資料鎖）、E13、E14（序列與時間）、E15（憑證放不放得下） |
| PR 3 | `node_cert` v2、`id/prove`、app、對端工具與向量；**等 v1.6 結束才 merge** | E8（CheckMac 用晶片序號）、E15 |
| 驗收 | F1 燒錄第 2 顆 → bench 晶片節點 → 全套驗證 + 登入時間量測 | 全部 |

v1 的背書、計數器相關工作已移出本期，所以 PR 2 / 3 不再依賴 E7、E11。

## 10. 使用者決定

| # | 決定 | 狀態 |
|---|---|---|
| Q1 | 晶片先焊在其他片 WM1302 HAT 上做實驗，**不動 02 / 04**；v1.6 結束後再把 02 / 04 換成晶片身分。⚠️ 實驗台的 Pi 焊好時確認 | 已決定（2026-11-23） |
| Q2 | 開發根私鑰放在 DSKT-MOONLIGHT；保管說明寫進 Batman-P | 已決定（2026-11-23）；v2 補充：加密存放、備份到可移除媒體（晶片設定 §5.4） |
| Q3 | **K20 的範圍**：晶片映像在任何情況下都不產生軟體身分；但開發者手動把 #255 之前的映像刷到晶片節點時，那個舊映像會產生軟體身分。用 preflight 與節點清單防止驗證工具這樣做，手動刷卡則接受 | 待使用者確認 |
| Q4 | **三段式加入在第 1 期沒有當場證明**（`verify_offline`），第 2 期移除這條路 | 待使用者確認 |
| Q5 | **登入時間**：量測後把差異交給使用者決定（K15） | 量測後 |
| Q6 | 入庫計數器（U9）移到選量產晶片時（晶片設定 §10），U9 的「最多 / 至少」措辭到時一起確認 | 告知 |

## 11. 尚未查證

OpenWrt 的 Go 套件規則是否一律用 cgo（`254-p2-impl.md:590`；本設計不依賴 cgo）；今天的映像是否已含 I2C 核心模組與 `dtparam`（E0）；`/dev/i2c-1` 在 bench 節點上的權限（E0）；app 在「重燒卡後同一個 `device_id` 變成未認領」這條路的畫面（PR 3）；晶片行為的所有 ⚠️（晶片設定 §11）。
