# #255 第 1 期實作設計：bench 上以 608B 作為節點身分（v3）

範圍：把 bench 上的空白 ATECC608B（`255-608b-config.md` v5 的設定）接成節點的身分後端，並讓協定、app、驗證工具配合。**只在開發版生效**：field 版 app 第 1 期之後仍拒絕所有節點（量產根要等選定量產晶片與 #256）。**第 1 期的晶片映像不是發行產物**，只裝在 bench 節點上。
不含：信任模型（第 2 期）、量產晶片、secure boot、晶片背書、入庫計數器（晶片設定 §10）。
依據：`255-608b-config.md` v5；`255-key-authority.md` v3.1（K13–K16、K20、K21 約束本期）；`255-threat-model.md` v2.1。
基準：main 4eba26d，加上 PR 1（#379，`Identity` 介面，未 merge）。節點路徑以 `feed/batman-prov/src/` 為根；app 的 Rust 以 `app/rust/` 為根。標記：✅ 對過原始碼；⚠️ 推論或未驗證。

| 版本 | 審查 |
|---|---|
| v1 | A：REJECT（1 / 7 / 14）；B：REJECT（2 / 10 / 12）。兩位都同意 PR 1 縮成純重構後可先做（已做，#379） |
| v2 | 拿掉背書；建置決定後端；主機端回答認領挑戰。與晶片設定 v4 一起審：A：0 / 4 / 13，APPROVE-WITH-CHANGES；B：0 / 7 / 9，REJECT |
| v3 | `sn` 維持節點 id；開機順序不變、改用 `Generate` 接縫；身分快取沿用今天的檔名；H1 驗證工具 PR；驗證矩陣；生命週期改正。對應：`255-reviews/v5set-changes.md` |

## 0. 決定（技術細節，由作者定案並說明理由）

| # | 決定 | 理由 |
|---|---|---|
| P1 | **晶片驅動用純 Go 自己寫**（helper 內，經 `/dev/i2c-1`），不用 cryptoauthlib，也不用第三方 Go 套件 | helper 不用任何 C 函式庫（產品建置雖然由 OpenWrt 以 cgo 外部連結，`254-p2-impl.md:590`，但純 Go 驅動不受影響；驗證工具與 CI 以 `CGO_ENABLED=0` 建置，`dv-sbx.sh:69,80`）✅；cryptoauthlib 沒有 OpenWrt 套件；現有純 Go 套件沒有人審過（F§15）。產品只需要 9 個指令（§2.2） |
| P2 | **身分後端由建置決定，不在執行期探測**：Go build tag `prov_se`，由建置參數 `BATMAN_PROV_SE=1` 打開。這種 helper 只有晶片後端，**沒有產生軟體身分的程式碼**。只給 bcm2711（Pi 4）；bcm2710 沒有晶片版。配合事項見 §2.8 | 執行期探測時，晶片暫時無回應會讓有晶片的機器產生軟體身分（審查 v3-A M5、v3-B M5）。代價：Pi 4 多一種映像（只在 bench）要建置與驗證 |
| P3 | **晶片映像的身分目錄是從晶片導出的快取，沿用今天的檔名**：`backend`（"se"）、`sn`（節點 id 的 9 位元組，與今天同義）、`node.cert`（槽 8 的副本），加上 `chip_sn`，以及這 4 個檔案的 sha 清單；經今天的保存路徑存到 p5。沒有任何秘密 | 沿用檔名讓 `boot.go` rc 13（讀 `sn`）、`96-batman-config-migrate` 的 `node.cert` 權限設定、與讀 `sn` / `node.cert` 的驗證單元都不必改（審查 v4set-B M2）；舊 helper 看到 `backend=se` 會拒絕載入（`keystore.go:266-267`） |
| P4 | **每次連線的身分證明放在 msg2 之後的第一個請求** `id/prove`；**驗證用的公鑰一律從已驗過的憑證導出**：檔案樣式 = 憑證金鑰；晶片樣式 = 憑證擴充欄位裡的槽 0 公鑰 | msg2 之後才有最終的交握雜湊 `h`（`noise.go:105`）✅。不從未驗過的欄位取金鑰，就擋住重放 `node_cert` 換掉證明金鑰（審查 phase1-A B1） |
| P5 | **`id/prove` 不走 helper 全域每秒 2 次的簽章限制**；每條連線只能一次 | 共用限制時，會員或陌生人反覆連線就能讓擁有者登入拿到 `ERate`（審查 phase1-A M1）。上限由結構決定：provd 的連線槽數、每條連線一次、交握成本；晶片本身約每秒 8 次（F§9） |
| P6 | **檔案後端也改用每次連線的證明，拿掉 `sig_static` 與 `boot_id`** | 兩種樣式同一條登入路徑。這是協定改動，放 PR 3 |
| P7 | **不做協定相容，但驗證工具兩版都懂**：PR 3 merge 後，舊 app 不認新節點、新 app 不認舊節點。H0 的工具依欄位組合分辨 v1 / v2。PR 3 等 v1.6 結束才 merge。**晶片映像在 PR 3 merge 之前不裝到任何節點**（PR 2 的晶片映像講舊協定，`sig_static` 要用只能內部簽章的槽 1 簽，登不進去，審查 v4set-A M4） | 檔案樣式的憑證 DER 不變，app 釘的是 DER（`nodecert.rs:126-133`），所以 02 / 04 升級後不必重新認領。PR 3 這一版若試用失敗自動回退，新 app 登不進回退後的舊映像 → §10 Q7 |
| P8 | **燒錄是 helper 的命令列模式**，開發根的簽章在開發者電腦上做（晶片設定 §5） | 只有 helper 碰晶片（K21）；開發根私鑰不放節點；節點映像也不放開發根公鑰（晶片設定 §2） |
| P9 | **晶片的簽章由 helper 轉成 low-s** | 晶片的 ECDSA 約一半是 high-s，專案拒絕 high-s（`proto.go:117`、`sig.rs:121`） |

## 1. 現況（✅ main 4eba26d + #379）

- 身分：PR 1 已把 helper 對身分的使用改成 `keystore.Identity` 介面（`SN`、`DeviceID`、`Cert`、`DACPub`、`ECDHPub`、`ECDH`、`CheckMac`、`SignPurpose`、`Backend`），唯一實作是檔案後端；身分檔 `node.key ecdh.key node.cert claim.secret backend sn` 加 sha 清單（`keystore.go:31`、`prov-lock.sh:7`）。
- `sn` 就是節點 id 的位元組：`DeviceID() = hex(sn)`（`keystore.go:45-46`）；provd 的 `deviceID = hex(sn)`（`server.go:357`），用在 Noise prologue（`:747`）、info（`:597`）、廣播後綴（`:638-639`）；app 的 `device_id = hex(sn)` 並要求憑證主體 serialNumber 等於它（`nodecert.rs:118-121`）；認領證明的 `CheckMacInput` 用 `sn[8]`、`sn[0:2]`（`proto.go:54-70`）。
- 開機：`daemon()` 先 `boot.Run`（`main.go:631`）做對帳與 `prov-state` 判斷，rc 7 / 9 經 `Env.Generate` 產生身分（`boot.go:33, 142`）；再 `keystore.Load`，失敗就 `select {}` 永遠不服務、不重試（`main.go:632-636`）；之後 `applyState`（`:637`）、健康與更新的計時（`:656, 686`）、未完成的無線變更（`BootFinish`，`:703`）、最後才 `Listen`（`:706`）。`--boot`、`--persist-now` 是另外的命令列模式（`main.go:571-575`、`boot.go:324-350`）。
- 試用開機：provd 連上 helper 滿 60 秒後 helper 寫 `$RUNDIR/provd-stable`（`stable.go:30-50`，寫一次就閂住）；autocommit 每次輪詢重讀（`batman-autocommit:508-512`）；`is-trial` 回傳碼不是 1 一律當試用（`trial.go:31-35`）。
- OTA：app 推的更新只比對板子名稱（`update.go:311-313`），兩種 Pi 4 映像的板子名稱相同。
- `96-batman-config-migrate` 開機時把 p5 的身分複製到覆蓋層（`:157-163`），以 `prov_ident_ok` 判斷（`prov-lock.sh:38-44`，固定 6 個檔名）。
- 驗證工具：`provclient node claim / claim-attacker / claim-attacker-chal / replay` 在節點上以 root 讀 `claim.secret`（`tests/tools/provclient/main.go:517`），約 25 個 DV 單元經它認領；擁有者的簽章已由主機端回答（`SIGN` / `SIG` 行）。preflight 今天只讀 `BATMAN_VERSION`（`dv-preflight.sh:32`）。
- 登入基準（#329）：連線到讀完狀態 2.8–5.6 秒；10 次登入 9 次 ≤ 20 秒（`329-app-uiux.md:998, 1021`）。

## 2. 節點端

### 2.1 身分介面（PR 3 之後）

| 方法 | 檔案後端 | 晶片後端 |
|---|---|---|
| `SN()`、`DeviceID()` | 不變 | `SHA-256(槽 1 公鑰)[:9]` 與它的 hex（**與今天同義：sn 就是節點 id**） |
| `Cert()` | 自簽 `dev:` 憑證 | 槽 8 的開發根憑證 |
| `ECDHPub()`、`ECDH(peer)` | 檔案 ECDH 金鑰 | 槽 2，明文輸出 |
| `SignPurpose(p, fields)` | DAC 簽 | 槽 0 外部簽章：直通 nonce 載入 `SHA-256(label ‖ fields)` 再簽 |
| `CheckMac(chal, resp)` | 軟體計算 | 晶片的 CheckMac，槽 5（晶片自己用它的序號） |
| `Backend()` | "file" | "se" |

- 晶片序號在節點端只出現在晶片內部與憑證擴充欄位，不經過 `SN()`。
- `SignPurpose` 的用途是固定列舉：PR 3 加 `Session`（`"batman-node-session-v1" ‖ h`，`h` 剛好 32 位元組）；刪除 `Static`；`ECDH` 只留給檔案後端；`Peer` 不變（標籤不同且含 `nonce_node`）。晶片後端沒有任何「替外部資料背書」的方法。

### 2.2 晶片驅動（`se608` 套件）

- I2C：`/dev/i2c-1`，`ioctl(I2C_SLAVE = 0x0703, 0x60)`，100 kHz。權限由晶片映像附的規則設成 root 0600；helper 不另做 `lstat` 檢查（只有 root 能在 `/dev` 建節點，多一道檢查只會在權限規則出錯時讓 helper 永遠不服務，審查 v4set-A m11）。§4 有 EACCES 負向測試，E0b 記錄實際權限。
- 喚醒：對位址 0x00 寫一個位元組，讀回 `0x11`；每個序列結束送閒置。封包：計數 + 指令 + CRC-16（0x8005）；輪詢等待，逾時用最快時脈的上限（F§9）。
- **序列器與鎖**：helper 常駐終生持有晶片鎖（root 專用執行目錄下的鎖檔，`flock` 獨占）；驅動內一個互斥鎖讓一次只跑一個指令序列。
- **產品需要的指令（9 個）**：Info、Read、Write、Lock、Nonce（只有直通）、GenKey、Sign（只有外部）、ECDH、CheckMac。**常駐程式的 GenKey 只能用「讀公鑰」模式**（私鑰槽讀不出公鑰，開機要用它取槽 0 / 1 / 2 的公鑰）；「產生」模式、Write、Lock 只在燒錄模式可用，驅動在其他情況拒絕（防止我們自己的錯誤重新產生未鎖的金鑰槽，審查 v4set-A m1）。
- **不實作**：Random、Nonce 亂數模式、內部簽章、GenDig、MAC、SHA、KDF、AES、Counter、UpdateExtra、DeriveKey、PrivWrite。這些只在 `se-lab`（§5）。登入路徑因此不跑會更新 EEPROM 亂數種子的指令。
- 單元測試：以 cryptoauthlib 主機端演算法產生的向量比對封包、CRC、CheckMac 的雜湊輸入。**PR D 的狀態碼與位元組格式標為暫定**；E1 / E8 / E17 擷取的真實回應回填後才拿掉標記，PR 2 的 CI 在標記還在時失敗（審查 v4set-B m7）。

### 2.3 開機（晶片映像）

**順序與今天相同**（審查 v4set-B M1）：`boot.Run` → 載入身分 → `applyState` → 計時器 → `BootFinish` → `Listen`。晶片映像只改兩處：

1. **`Env.Generate`（rc 7 / 9）**：在晶片映像 = 「讀晶片，寫出身分快取」，不是產生金鑰。只有晶片是已燒錄（S4，晶片設定 §5.2）才寫；晶片無回應或未燒錄 → 回錯誤 → `unknown(generate-failed)`，與今天產生失敗相同。
2. **載入身分**（今天 `select {}` 的位置）：載入快取並與晶片比對：快取的 `sn` 與 `chip_sn` 要等於晶片的；憑證要與晶片結構相符（晶片設定 §2，節點不驗開發根簽章）。
   - 相符 → 往下照常。若槽 8 的憑證與快取的 `node.cert` 不同但結構相符（只會在未認領時用 `se-burn cert` 換過，晶片設定 §5.3），以槽 8 為準重寫快取並保存到 p5。
   - 晶片無回應或未燒錄 → 寫 log；**`prov-state` 只在判斷改變時寫一次**（不是每次重試，#104）；每 10 秒重試這一步。若快取是因為 `Generate` 失敗而不存在，重試時重跑 `boot.Run`（rc 7 / 9 的路徑本來就可以重跑）。
   - 快取的 `sn` ≠ 晶片的（換了 HAT）→ 凍結 `unknown(identity-mismatch)`；快取 `backend=file` → 凍結 `unknown(backend-mismatch)`。都不寫、不作廢任何紀錄，不再重試。
- 晶片映像的 `identSum` = 快取的 4 個檔案存在且 sha 清單正確，**不讀晶片**。所以 `--boot`、`--persist-now` 這些命令列模式不需要晶片、不取晶片鎖。
- 晶片在載入這一步等待時，`applyState`、健康、更新計時、未完成的無線變更都還沒開始，與今天「沒有身分」的情形相同；mesh 照現有設定運作。晶片回應後依序執行。§4.2 有 DV 單元：已認領的節點、開機時晶片無回應、有未完成的無線變更 → 晶片恢復後變更完成。
- 其他 p5 回傳碼的行為與今天相同（rc 0 還原、rc 13 以 `sn` 比對後重新保存等），因為快取沿用今天的檔名（P3）。
- **換 HAT**：凍結（與今天 P-U6 相同），不作廢紀錄、不動網路金鑰與 SSH 金鑰；復原 = 重燒卡。

### 2.4 試用開機與晶片故障

- 試用時晶片在載入那一步就失敗：socket 不打開 → provd 連不上 → `provd-stable` 不寫 → 試用逾時回退（今天的機制）。晶片在逾時前恢復：開始服務、照常確認。
- **已開始服務後晶片失敗**：該請求回錯誤，下一個請求重試晶片一次（不閂鎖）。若此時是試用（`is-trial` 不是 1）：helper 刪除 `provd-stable`，並設一個與 `stableWriter.done` 並列的旗標，這次開機不再寫它；autocommit 下一次輪詢看不到，試用不會被確認（審查 v3-B M4）。helper 是 `provd-stable` 唯一的寫者。
- autocommit 已確認之後晶片才失敗：確認不撤回（不在本期範圍）；helper 照常服務並重試。
- 沒有 A/B 的卡（`is-trial` 回 2）：照上一條不再寫 `provd-stable`，但沒有回退；helper 照常服務並重試晶片。

### 2.5 燒錄（`batman-provhelper se-burn`）與 `se-sign`

照晶片設定 §5。實作：

- 節點端：`se-burn status`（唯讀 JSON）；`se-burn`（每次讀狀態做下一步 S0 → S3；S1、S3 從 stdin 讀「預期序號 + 秘密」，序號不符就拒絕；S3 輸出資料包）；`se-burn cert < cert.der`（只在未認領時寫槽 8）。拒絕條件：常駐程式在跑（拿不到鎖）、試用開機、沒有 `/etc/batman-dev-open`。
- 開發者電腦：`feed/batman-prov/src/cmd/se-sign`（同一個 Go module，不打包進映像）：`begin <host>`（讀 status、產生秘密、寫「待寫入」紀錄、經 ssh stdin 交給 `se-burn`）；`sign <bundle>`（依晶片設定 §5.1、§5.4 的規則驗證並簽、產生 QR 圖檔）。所有檔案 0600 在 WSL ext4 上。秘密不出現在命令列參數、終端機或任何 log；驗證工具的遮蔽規則加一條。
- 晶片映像的 `provhelper qr` 回「不支援」。

### 2.6 provd

- `buildNodeCert` 改組 v2 欄位（§3.1）；不再呼叫 `sign.static`；晶片樣式不呼叫 `sign.ecdh_proof`。`deviceID = hex(sn)` 不變（`sn` 仍是節點 id）。
- 新請求 `id/prove`：所有角色（含匿名）都可送，每條連線一次，回 `SignPurpose(Session, h)`；不經全域限制（P5）。
- `peers/challenge` 維持拒絕。對 helper `info.boot_id` 的輪詢保留（`server.go:442-449`）。

### 2.7 誰能碰晶片

- 只有 helper（含燒錄模式）。`/dev/i2c-1` 0600 root；provd 的 uid、沙箱與承租容器打不開（§4 有負向測試）。容器執行環境不給這個裝置。
- `batpower` 在程式裡拒絕位址 0x60（不只靠 uci 設定值）。

### 2.8 建置、版本標記、OTA、出貨閘門

| 項目 | 做法 |
|---|---|
| Go | build tag `prov_se`；`Makefile` 由 `BATMAN_PROV_SE=1` 帶入（同 `BATMAN_PROV_TEST`，`Makefile:23-30`）。DV 的 `se-fail` 單元需要 `prov_test` + `prov_se` 的白箱晶片映像：`build-board.sh --wbox`、`lint-wbox.sh` 一起支援（審查 v4set-B m4） |
| 重新建置 | firmware fork 的 `build-board.sh` 比照 `prov_test`，記錄上次的參數，不同就清掉 helper 的建置（OpenWrt 的 stamp 不含環境變數）。firmware repo 的 PR，列在 §9 |
| 版本標記 | `batman-provhelper --version` 印出後端；`/etc/batman-build` 加 `BATMAN_PROV_BACKEND=se`（只有晶片映像加；**沒有這個鍵 = 檔案映像**，今天所有映像都是，審查 v4set-B M4） |
| OTA | 更新的發行資訊加 `backend`（沒有 = file）；`update.go` 除了板子名稱也比對節點的 `BATMAN_PROV_BACKEND`，不同就拒絕（審查 v4set-B M6a） |
| 映像內容 | 晶片映像要有 `kmod-i2c-bcm2835`、`kmod-i2c-dev`、`dtparam=i2c_arm=on` 與 `/dev/i2c-1` 權限規則，經 board diffconfig（絕不裸跑 `make defconfig`）。今天的映像只有 `kmod-i2c-brcmstb`（`boards-and-builds.md:136`） |
| 出貨閘門 | 晶片映像在第 1 期不發行，所以閘門只檢查一個方向：**發行的檔案映像**不能含 se 後端、假晶片、`se-lab`、`se-sign`、不含鎖定指令的實驗建置、或 `prov_test` × `prov_se`（審查 v4set-B m9） |
| CI | `go test` 加 `-tags prov_se` 與 `-tags prov_se,prov_test` 兩步，**在 H1 加**，並有哨兵：找不到任何 `prov_se` 測試就 FAIL |

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
| 7 sn | 節點 id 的位元組（不變） | 同（節點 id 的位元組，**不是**晶片序號） |

晶片樣式的憑證（本期定案；在未認領時可用 `se-burn cert` 更換，晶片設定 §5.3）：

| 項目 | 內容 |
|---|---|
| 格式 | X.509 v3，完整 DER，≤ 416 位元組（槽 8；E15，PR D 時在開發者電腦上先算）；簽章演算法 ecdsa-with-SHA256，外層與 TBS 的 AlgorithmIdentifier 必須相同 |
| 簽發者 | 開發根（P-256，自簽 CA，只用於 bench） |
| 主體 | CN = `se:<device_id>`；serialNumber = `<device_id>`（與檔案樣式相同的規則，`nodecert.rs:118-121`） |
| 主體金鑰 | 槽 1 公鑰 |
| 擴充欄位 | BasicConstraints CA:FALSE；私有 OID，非關鍵，內容 CBOR `{0: 槽 0 公鑰, 2: 槽 2 公鑰, 7: 晶片序號 9 位元組}`（公鑰 33 位元組壓縮格式，解壓時檢查在曲線上）。其他任何關鍵擴充欄位 → 拒絕 |
| 有效期間 | 2020-01-01 起（與 `DevCert` 相同，`keystore.go:102-104`；bench 節點沒有 RTC，開機時鐘可能早於燒錄日）到 9999-12-31。沒有任何驗證者檢查時間 |

### 3.2 app 的驗證（`nodecert.rs`）

- **樣式判斷**：以釘在開發版 app 裡的開發根公鑰驗憑證簽章，通過且 CN 以 `se:` 開頭 = 晶片樣式；自簽且 CN 以 `dev:` 開頭 = 檔案樣式；其他一律拒絕（包括開發根簽的 `dev:`、自簽的 `se:`）。**不依簽發者名稱的文字判斷**。欄位組合必須完全符合該樣式。
- 兩種樣式共同（`common()`）：`device_id = hex(第 7 欄)`，且等於憑證主體 serialNumber（今天的規則）。
- 晶片樣式另外：`device_id = hex(SHA-256(憑證主體金鑰)[:9])`、CN = `se:<device_id>`；擴充欄位剛好 0、2、7 三項。
- **`id/prove`**：收到 msg2 後立刻送，驗 `"batman-node-session-v1" ‖ h` 的簽章，公鑰 = 檔案樣式的憑證金鑰 / 晶片樣式擴充欄位的槽 0 公鑰；驗過之前不送任何其他請求，也不保存任何東西（`claimflow.rs:168-182` 的 `PersistPending` 移到證明之後）。三個交握驗證點都要做：`loginflow`、`claimflow`、`replayflow`。
- **認領證明的序號**：檔案樣式 = 第 7 欄（今天）；晶片樣式 = 擴充欄位的晶片序號（`claimflow.rs:172` 改取 `Verified` 裡新的 `claim_sn`）。
- `ecdh_pub` 的可信來源：檔案樣式 = 欄位 4 + `sig_ecdh`；晶片樣式 = 擴充欄位的槽 2 公鑰。
- `trust_gate`：開發版接受兩種樣式；field 版兩種都拒絕。開發根公鑰只在 `DEV_TRUST` 下編譯。**今天每個 APK flavor 都帶 `dev-trust`**（`cargokit.yaml:1-11`），field APK 只靠啟動時的交叉檢查；PR 3 把 flavor 與 feature 接好，`check-field-build.sh` 對 field APK 判定不含開發根公鑰（審查 v4set-A m8）。
- `verify_offline`（三段式加入）：沒有 `h`，無法驗當場證明。兩種樣式都只驗憑證與欄位組合。**第 1 期沒有當場證明，是 K20 的一個偏離**，第 2 期移除這條路 → §10 Q4。
- 節點端密碼包的對象：`SHA-256(身分公鑰)`（`wtxn.go:132-135`），兩種樣式一致。

### 3.3 認領

- `CheckMacInput` 不變。`ClientChal` 雜湊的是整張憑證 DER，晶片樣式下就是開發根憑證，認領證明仍綁住身分金鑰。
- QR 不變：`{1: device_id, 2: 認領秘密}`，由 `se-sign` 產生。

### 3.4 測試向量

`tests/vectors/219-protocol/` 加入晶片樣式與負向向量：**晶片序號 ≠ 節點 id**（假晶片也是，CI 才看得出混用，審查 v4set-A M1）；晶片樣式多了欄位 4 或 6；擴充欄位的槽 0 公鑰被換掉；擴充欄位多一項或少一項；未知的關鍵擴充欄位；CN 或 serialNumber 與 `SHA-256(主體金鑰)[:9]` 不符；開發根簽的 `dev:`；自簽的 `se:`；field 版拿到有效的晶片 `node_cert`（`verify_first_contact` 與 `verify_offline` 都要 `Untrusted`）；`id/prove` 的簽章換成另一條連線的；high-s 簽章。`fakeMsg2` 的長度要等於真實 msg2（`noise.go:108-109`），並檢查晶片樣式的 msg2 在框架與 MTU 限制內。

## 4. 驗證工具與測試

### 4.1 H0（harness PR；**v1.6 打完 tag 之後才 merge**，與 v1.6 session 確認）

- **主機端回答認領挑戰**：`provclient node claim`、`claim-attacker`、`claim-attacker-chal`、`replay` 在節點上不再讀 `claim.secret`，改成在 stdout 輸出 `MAC <ClientChal hex>`，由主機端 `provclient mac <紀錄>` 回答 `MACR <hex>`。用哪一筆紀錄由節點清單決定。檔案節點的紀錄 = 本次執行開始時從節點複製回主機的 `claim.secret`，放在本次執行的 0600 暫存目錄，執行結束時刪除（審查 v4set-B M4）。
- **log 洩漏檢查搬到主機端**：`prov-claim-254.sh:49-51`、`scripts/node/prov-p1-254.sh:63-66` 改成把 logread 複製回主機比對。
- `node_cert` v1 / v2 依欄位組合分辨：`tests/tools/peer/*`、`provclient`、`app/tools/synth-joinreq`、`tests/tools/peer/netobj.py`。`ci-check.sh` 的 `MIN_CHECKS` 依向量版本分開計。
- preflight：讀 `/etc/batman-build` 的 `BATMAN_PROV_BACKEND`（沒有 = file）；節點清單標明每台的後端；**鍵存在且與清單不符才拒絕**。今天的映像都沒有這個鍵，所以 v1.6 的執行不受影響。
- 證據：每項改動附「舊工具在目標情境 FAIL、新工具 PASS」，並在 v1.6 的映像上跑一次全套確認不退步。

### 4.2 H1（harness PR；PR D 之後、PR 2 merge 之前）

把晶片節點的驗證單元放進常規全套（一套測項的規則，審查 v4set-B M3）：

- `se-fail` killpoint（白箱晶片映像）：開機時晶片無回應；試用中無回應 → 回退；服務中無回應 → 恢復後照常；試用中服務後才失敗 → 不確認；已認領、晶片無回應、有未完成的無線變更 → 晶片恢復後變更完成。
- 晶片映像不產生 `node.key`（負向對照：一個 wbox 修補讓晶片映像退回檔案後端，這條必須 FAIL）。
- 以 provd 的 uid、在承租容器內 `open("/dev/i2c-1")` → EACCES（負向對照：權限 0644 的假裝置要讓這條 FAIL）。
- 燒錄拒絕：常駐在跑、試用開機、序號不符、已認領時 `se-burn cert`。
- OTA 後端不符的更新被拒（簽好的錯誤後端更新包）。
- CI 的 `prov_se` 兩步與哨兵；`check-field-build.sh` 的開發根檢查（開發根在 PR 2 才存在，之前這條標為未啟用並 FAIL 若被當成通過）。
- **逐單元對照表**（晶片節點上）：

| 單元 | 讀什麼 | 晶片節點上 |
|---|---|---|
| `chain1-254`、`prov-provd-254`、`prov-provd-wbox-254`、`prov-bench-s0-254` | `identity/sn` | 照常（檔名與意義不變） |
| `prov-overlay-wipe-254`、`fresh-254` | `node.cert` | 照常 |
| `prov-chain0-254` | `node.key` | 改：斷言 `node.key` 不存在 |
| `prov-sec-254`（兩處） | `node.key` 權限與負向對照 | 改：判 `/dev/i2c-1` 權限，0644 假裝置為負向對照 |
| `prov-p1-254`、`prov-claim-254` | `claim.secret` | H0 已改為主機端 |
| `prov-downgrade-254` | 裝舊映像 | 改成負向測試：sysupgrade 到舊映像 → 舊 helper 凍結 `identity-lost` → 試用回退。⚠️ H1 實跑確認 |
| `prov-legacy-upgrade-254`、`negctl-old-slot` | 舊映像、拿掉 p5 紀錄 | H1 逐一實跑判斷；任何要在晶片節點上拿掉的單元先問使用者（§10 Q8） |

  H1 開工時以 grep 補齊其餘讀身分檔的單元。
- 證據：在變異體與 PR 2 之前的產品上 FAIL，在 PR 2 的 rc 上 PASS。

### 4.3 各產品 PR 的測試

| 類別 | 內容 |
|---|---|
| 假晶片（PR D） | 有狀態：設定區與資料區、兩區的鎖、每槽的鎖、真的 P-256 金鑰、CheckMac 真的比對、序號 ≠ 節點 id；能模擬「N 次無回應後恢復」；格式標為暫定 |
| 燒錄（PR 2，假晶片） | 每個狀態 S0–S3 中斷後重跑都能接續；S1 中斷後秘密仍在開發者電腦；S1 的 CheckMac 後中斷 → S3 先補 CheckMac；兩顆晶片的憑證互換 → 拒絕；`se-sign` 拒絕槽 1 公鑰重複的資料包 |
| 開機（PR 2） | §2.3 的每一種情況；`--boot`、`--persist-now` 不碰晶片 |
| 協定（PR 3） | §3.4 的向量；三個交握驗證點都做 `id/prove` |
| 爭用（PR 3） | 兩個會員連線反覆送 `id/prove`，擁有者同時登入，要在基準時間內成功 |
| 出貨閘門（PR 2） | 發行的檔案映像含任一禁止項目 → 閘門擋下（各附一個錯誤建置） |
| 登入時間（PR 3 + 晶片節點） | 同一支手機（S20）、同一個 R-7 程序，檔案節點與晶片節點各 10 次登入，改動前後各一組；預期增加一個 GATT 來回加一次簽章（晶片 ≤ 200 ms）；結果交給使用者決定（K15，§10 Q5） |

手動、無法自動化的（拔晶片、換 HAT、燒錄中斷電）列為手動測項，結果附在 PR。

## 5. 晶片實驗程式

`feed/batman-prov/src/cmd/se-lab`（同一個 Go module，共用 `se608` 的封包與 CRC 程式碼，不打包進映像），規則見晶片設定 §8.0。PR D 交付，含不含任何鎖定指令的建置。

## 6. 擁有權、契約

| 資源 | 唯一能改的 | 只讀 |
|---|---|---|
| 晶片與匯流排上的晶片狀態 | 持有晶片鎖的程式：helper 常駐（序列器）或燒錄模式；`se-lab` 只在實驗台 | — |
| 覆蓋層的身分快取 | 開機時依序兩個寫者：`96-batman-config-migrate`（S10，從 p5 複製，依 `backend` 的檔案清單）→ helper（S89，對帳、`Generate`、以槽 8 重寫）。不同時執行 | `prov-lock.sh`、`batman-config-save`、腳本、命令列模式 |
| p5 的身分 | `batman-config-save` 的保存（`:521-536`），清單依 `backend` | helper、`96-batman-config-migrate` |
| `provd-stable` | helper | autocommit |
| 燒錄紀錄、開發根私鑰 | 開發者電腦的 `se-sign`（兩個分開的目錄） | 驗證工具只讀燒錄紀錄 |
| `node_cert` | provd（由 helper 提供材料） | app、對端工具 |

| 介面 | 寫 → 讀 | 缺漏或錯誤 |
|---|---|---|
| `id/prove` | provd → app | app 拒絕連線，不保存任何東西 |
| `node_cert` v2 | provd → app | 欄位組合不符或驗不過 → 拒絕 |
| 身分快取目錄 | helper → 腳本 | sha 清單不符 → 腳本判 FAIL；helper 下次開機重新比對 |
| `MAC` / `MACR` 行 | `provclient`（節點）↔ `provclient mac`（主機） | 主機沒有該節點的紀錄 → 不回答，單元 FAIL |
| `BATMAN_PROV_BACKEND` | firmware 建置 → preflight、`update.go` | 沒有 = file |
| 燒錄的秘密、資料包、憑證 | 晶片設定 §7 | 晶片設定 §7 |

## 7. 生命週期（晶片映像）

| 路徑 | 今天（檔案映像） | 之後（晶片映像） | 測試 |
|---|---|---|---|
| 首次開機，晶片已燒錄 | 產生檔案身分 | `Generate` 由晶片寫快取，未認領 | bench |
| 首次開機，晶片未燒錄 / 非本設定 / 無晶片 | — | `generate-failed`，不服務，每 10 秒重試，**不產生身分** | `se-fail` DV；變體晶片手動 |
| 開機（已認領） | 照常 | 照常；載入時與晶片比對 | DV |
| 開機時晶片無回應、有未完成的無線變更 | — | 等晶片；恢復後依序完成 | `se-fail` DV（H1） |
| 正常關機、重開，或在指令序列中途關機 | — | 晶片進睡眠，暫存狀態全失；下次重跑整個序列 | 序列中途重開 |
| helper 重啟 / 當機重啟循環 | 照常 | 每次啟動只讀晶片，不寫 EEPROM；`node_cert` 不變 | 重啟 10 次後讀晶片狀態不變 |
| provd、bluetoothd 重啟 | 照常 | 照常 | DV 既有 |
| 試用開機，晶片在開機時失敗 | — | 不服務 → 回退 | `se-fail` DV |
| 試用開機，服務後晶片失敗 | — | 刪除 `provd-stable`、不再寫 → 回退 | `se-fail` DV |
| 試用開機，短暫失敗後恢復 | — | 恢復後服務 → 照常確認 | `se-fail` DV |
| OTA 晶片映像 → 晶片映像 | 照常 | 快取經 `96-batman-config-migrate` 搬移；與晶片比對 | DV（bench 晶片節點） |
| 回退到上一個晶片映像（K13） | 照常 | 同一顆晶片、同一個身分，可登入。**例外：PR 3 那一版**回退到 v1 協定的映像，新 app 登不進（P7，§10 Q7） | DV |
| app 推送後端不符的更新 | — | `update.go` 拒絕 | H1 DV |
| OTA 檔案映像 → 晶片映像（節點有檔案身分） | — | `backend=file` → 凍結（試用就回退），**不作廢紀錄** | CI；bench 手動 |
| 晶片節點 sysupgrade 到檔案映像 | — | #255 之後的檔案映像：p5 的快取通過依 `backend` 的檢查而被還原，但檔案後端拒絕載入 `backend=se`（`keystore.go:266-267`）→ 不服務 → 回退；不會走到 rc 7 / 9 的產生。#255 之前的映像：`prov_ident_ok` 不認 → rc 13 → 凍結 `identity-lost` → 回退（審查 v4set-B M6c） | H1：`prov-downgrade-254` 改成負向測試 |
| 晶片節點**重燒卡**成任何檔案映像 | — | p5 也被清掉 → rc 7 → 產生軟體身分（違反 K20）。不支援；preflight 不做這件事；手動重燒卡仍可能 → §10 Q3 | — |
| 重燒 SD 卡（晶片映像） | 新的軟體身分 | **同一個** `device_id`，紀錄沒了 → 未認領。app 裡若還有這台的擁有者紀錄，登入會失敗，使用者重新認領後紀錄被取代。⚠️ app 在這條路的畫面在 PR 3 確認 | bench |
| 換 HAT | — | 凍結 `identity-mismatch`，紀錄與金鑰不動；復原 = 重燒卡 | bench（兩片 HAT 互換） |
| 在未認領的節點換憑證（`se-burn cert`） | — | 開機時以槽 8 重寫快取並保存 | PR 2 |
| 在已認領的節點換憑證 / 換開發根 | — | `se-burn cert` 拒絕；要先重設或重燒卡、換完再認領（晶片設定 §5.3） | PR 2 |
| 把檔案節點改成晶片節點（02 / 04，v1.6 之後） | — | 只能重燒卡（OTA 會凍結）：使用者同意後重燒晶片映像（A/B 卡）→ `se-burn` → 認領。重燒卡會清掉 p6 的承租資料；app 裡舊的紀錄（節點 id 不同）由使用者刪除。這違反「模擬已部署 = 只 sysupgrade」的角色規則一次，要使用者同意 | 手動，結果附在 #255 |
| 燒錄中斷電 | — | 晶片設定 §5.2，從讀回狀態接續 | 假晶片 CI；F1 手動 |
| 認領中斷電 | 紀錄交易 | 同 | DV 既有 |
| I2C 驅動 | — | 編進映像、開機載入；開啟失敗 = 無回應，重試 | E0b |
| 晶片映像裝到沒有 `/dev/i2c-1` 的機器 | — | 無回應 → 不服務、重試 | CI |
| bcm2710（Pi 3） | — | 不適用：沒有晶片版建置 | — |

## 8. 安全

- **新的輸入**：`id/prove`（任何人都能送，每條連線一次，不經全域限制）；`node_cert` v2 的新欄位與憑證擴充欄位（app 端解析，欄位組合與擴充欄位嚴格）；燒錄模式（root、`/etc/batman-dev-open`、非試用、拿到晶片鎖；標記不是安全控制）；`MAC` / `MACR` 行（驗證工具）；更新資訊的 `backend` 欄位（簽過的發行資訊）。
- **逐個行為者**：
  - 遠端：只看得到 `node_cert` 與 `id/prove` 的簽章；重放 `node_cert` 不能通過 `id/prove`（金鑰取自憑證）。
  - 本機非 root 程式與承租容器：打不開 `/dev/i2c-1`（有負向測試）。
  - 被攻破的 provd：可以讓槽 0 簽任何 `h`、即時轉送證明、以每秒約 8 次佔用晶片。這等於 provd 被攻破，與今天的 `sign.static` 相同，列為殘餘風險。
  - 實體接觸（有 root 或能接匯流排）：可以讓晶片簽章、做 ECDH、覆寫或鎖住槽 8（只是拒絕服務），等於節點被攻破；不能取出私鑰或認領秘密，也不能讓別的機器變成這台（換 HAT 會凍結）。bench 接受。
  - 燒錄時的節點：開發根相信節點回報的公鑰，所以只在剛燒好卡、開發者在場時燒錄；`se-sign` 拒絕重複的槽 1 公鑰，避免冒充另一台。
  - 被攻破的受測節點對驗證工具：主機端依節點清單選紀錄，不依節點輸出，所以拿不到別台的認領回應。
  - 開發根外洩：能做出開發版 app 信任的假節點；開發版不對外，field 版不信任它（PR 3 起 field APK 也不含它）。
- **秘密**：認領秘密只在開發者電腦與晶片裡；經 stdin 傳一次；不進 repo、log、命令列參數。開發根私鑰加密存放，與燒錄紀錄分開。晶片的 ECDH 明文輸出經過 I2C（bench 接受）。
- **失敗時**：拿不到身分就不服務（fail-closed）；任何不一致都凍結，不自動修正。
- 本期不改變：PSK、網路密碼的保管、認領鎖定。

## 9. 交付順序與驗證矩陣

| 順序 | 內容 | 前提 |
|---|---|---|
| PR 1 | `Identity` 介面（#379，已完成） | v1.6 打完 tag 後 merge |
| H0 | §4.1 | v1.6 打完 tag 後 merge |
| PR D | `se608` 驅動核心 + 假晶片 + 向量 + `se-lab` + `se-sign` 的憑證部分（先算憑證大小） | 不需要晶片；可以現在開始 |
| 實驗台 | E0a、E1–E3 → 本文件與晶片設定審過 → E4–E13、E15–E17 | 晶片已焊、使用者同意 |
| H1 | §4.2 | PR D |
| PR 2 | 晶片後端、開機、試用、燒錄模式、`se-sign`、§2.8（另有 firmware fork 的 PR） | 實驗台的 E5、E6、E13、E15、E17；H1 先 merge |
| PR 3 | `node_cert` v2、`id/prove`、app、對端工具與向量 | E8、E15；v1.6 結束 |
| 驗收 | 一台 bench 節點改成晶片節點 → E0b、F1、E14 → 全套驗證 + 登入時間量測 | PR 2、PR 3 都 merge；§10 Q8 |

| 階段 | 映像 | 節點 | 跑什麼 |
|---|---|---|---|
| PR D、H0、H1 的開發 | — | CI、實驗台（Raspberry Pi OS） | 單元測試、假晶片、`se-lab` |
| PR 2 / PR 3 開發 | 檔案映像（產品改動也影響檔案後端） | 02 / 04（v1.6 結束後） | 全套 |
| PR 2 / PR 3 開發 | 白箱晶片映像 | 改成晶片節點的那一台 | H1 的晶片單元 + 全套中適用的部分 |
| 驗收 | 晶片映像 | 晶片節點 | 全套（含 mesh：另一端是檔案節點，見 Q8） |
| 每次發行 | 檔案映像 | 照今天 | 照今天（晶片映像不發行） |

## 10. 使用者決定

| # | 決定 | 狀態 |
|---|---|---|
| Q1 | 晶片先焊在其他片 WM1302 HAT 上做實驗，**不動 02 / 04**；v1.6 結束後再把 02 / 04 換成晶片身分。⚠️ 實驗台的 Pi 焊好時確認 | 已決定（2026-11-23） |
| Q2 | 開發根私鑰放在 DSKT-MOONLIGHT；保管說明寫進 Batman-P | 已決定（2026-11-23）；補充：加密存放、與燒錄紀錄分開、備份到可移除媒體 |
| Q3 | **K20 的範圍**：晶片映像在任何情況下都不產生軟體身分。但把晶片節點**重燒卡**成任何檔案映像（含 #255 之後的）時，那個映像會產生軟體身分。驗證工具不這樣做；手動重燒卡則接受 | 待使用者確認 |
| Q4 | **三段式加入在第 1 期沒有當場證明**（`verify_offline`），第 2 期移除這條路 | 待使用者確認 |
| Q5 | **登入時間**：量測後把差異交給使用者決定（K15） | 量測後 |
| Q6 | 入庫計數器（U9）移到選量產晶片時，U9 的措辭到時一起確認 | 告知 |
| Q7 | **K13 的例外**：升級到 PR 3 那一版時，若試用失敗自動回退，已換成新版 app 的手機登不進回退後的節點；復原是在手機上裝回前一版 app（`adb install -r -d`）或重新 OTA。只影響 bench，只發生一次 | 待使用者確認 |
| Q8 | **bench 硬體與測項**：驗收需要一台 Pi 4 + HaLow 當晶片節點。(a) 把 02 或 04 改成晶片節點：mesh 測項變成一台檔案、一台晶片，檔案映像在這段期間沒有「兩台同映像」的全套；(b) 另備第三台 Pi 4 + HaLow。另外，H1 若判定某些單元在晶片節點上不能跑，逐項列出請使用者同意 | 驗收前 |

## 11. 尚未查證

今天的映像是否已含 `dtparam=i2c_arm`（E0b）；`/dev/i2c-1` 在晶片映像上的實際權限（E0b）；app 在「重燒卡後同一個 `device_id` 變成未認領」這條路的畫面（PR 3）；`prov-downgrade-254`、`prov-legacy-upgrade-254`、`negctl-old-slot` 在晶片節點上的實際行為（H1）；晶片行為的所有 ⚠️（晶片設定 §11）。
