# #255 第 1 期實作設計：bench 上以 608B 作為節點身分（v5）

範圍：把 bench 上的空白 ATECC608B（`255-608b-config.md` v7 的設定）接成節點的身分後端，並讓協定、app、驗證工具配合。**只在開發版生效**：field 版 app 第 1 期之後仍拒絕所有節點（量產根要等選定量產晶片與 #256）。**第 1 期的晶片映像不是發行產物**，只裝在 bench 節點上。
不含：信任模型（第 2 期）、量產晶片、secure boot、晶片背書、入庫計數器（晶片設定 §10）。
依據：`255-608b-config.md` v7；`255-key-authority.md` v3.1（K13–K16、K20、K21 約束本期）；`255-threat-model.md` v2.1。
基準：main 4eba26d，加上 PR 1（#379，`Identity` 介面，未 merge）。節點路徑以 `feed/batman-prov/src/` 為根；app 的 Rust 以 `app/rust/` 為根。標記：✅ 對過原始碼；⚠️ 推論或未驗證。

| 版本 | 審查 |
|---|---|
| v1 | A：REJECT（1 / 7 / 14）；B：REJECT（2 / 10 / 12）。兩位都同意 PR 1 縮成純重構後可先做（已做，#379） |
| v2 | 拿掉背書；建置決定後端；主機端回答認領挑戰。與晶片設定 v4 一起審：A：0 / 4 / 13，APPROVE-WITH-CHANGES；B：0 / 7 / 9，REJECT |
| v3 | `sn` 維持節點 id；開機順序不變；H1；驗證矩陣。與晶片設定 v5 一起審：A：0 / 3 / 16，APPROVE-WITH-CHANGES；B：1 / 7 / 15，REJECT |
| v4 | PR 順序可執行（PR 2 的晶片映像只跑 helper 層的測項）；憑證只在沒有身分快取時寫入；讀 `sn` / 欄位 4 的 app 路徑補齊；晶片的 ECDH 失敗不被吞掉；H0 / H1 / H2 分工；拿掉 OTA 後端欄位。與晶片設定 v6 一起審：A：0 / 2 / 15；B：0 / 4 / 16。兩位都是 APPROVE-WITH-CHANGES |
| v5 | 憑證大小預算；`CheckMac` 回傳錯誤；PR 2 晶片節點上跑哪些測項；H0 四個簽章迴圈與逾時；對照表改正；外來後端檢查兩種映像都做。對應：`255-reviews/v7set-changes.md` |

## 0. 決定（技術細節，由作者定案並說明理由）

| # | 決定 | 理由 |
|---|---|---|
| P1 | **晶片驅動用純 Go 自己寫**（helper 內，經 `/dev/i2c-1`），不用 cryptoauthlib，也不用第三方 Go 套件 | helper 不用任何 C 函式庫（產品建置由 OpenWrt 以 cgo 外部連結，`254-p2-impl.md:590`，純 Go 驅動不受影響；驗證工具與 CI 以 `CGO_ENABLED=0` 建置，`dv-sbx.sh:69,80`）✅；cryptoauthlib 沒有 OpenWrt 套件；現有純 Go 套件沒有人審過（F§15）。產品只需要 9 個指令（§2.2） |
| P2 | **身分後端由建置決定，不在執行期探測**：Go build tag `prov_se`，由建置參數 `BATMAN_PROV_SE=1` 打開。這種 helper 只有晶片後端，**沒有產生軟體身分的程式碼**。只給 bcm2711（Pi 4）；bcm2710 沒有晶片版。配合事項見 §2.8 | 執行期探測時，晶片暫時無回應會讓有晶片的機器產生軟體身分。代價：Pi 4 多一種映像（只在 bench）要建置與驗證 |
| P3 | **晶片映像的身分目錄是從晶片導出的快取，沿用今天的檔名**：`backend`（"se"）、`sn`（節點 id 的 18 個 hex 字元加換行，與今天相同，`keystore.go:210`）、`node.cert`（槽 8 的憑證）、`chip_sn`，加這 4 個檔案的 `sha256` 清單，共 5 個檔案；經今天的保存路徑存到 p5。沒有任何秘密 | 沿用檔名讓 `boot.go` rc 13（讀 `sn`）、`96-batman-config-migrate` 的 `chmod 644 node.cert`、讀 `sn` / `node.cert` 的驗證單元照常運作。**shell 端仍要改**：`prov-lock.sh` 的檔案清單與 `prov_ident_ok`、`batman-config-save` 的「7 個檔案」檢查（`:229, 521-536`）都寫死檔案檢查表，要改成依 `backend` 決定（PR 2，§2.8）。舊 helper 看到 `backend=se` 會拒絕載入（`keystore.go:266-267`） |
| P4 | **每次連線的身分證明放在 msg2 之後的第一個請求** `id/prove`；**驗證用的公鑰一律從已驗過的憑證導出**：檔案樣式 = 憑證金鑰；晶片樣式 = 憑證擴充欄位裡的槽 0 公鑰 | msg2 之後才有最終的交握雜湊 `h`（`noise.go:105`）✅。不從未驗過的欄位取金鑰，就擋住重放 `node_cert` 換掉證明金鑰 |
| P5 | **`id/prove` 不走 helper 全域每秒 2 次的簽章限制**；每條連線只能一次 | 共用限制時，會員或陌生人反覆連線就能讓擁有者登入拿到 `ERate`。上限由結構決定：provd 的連線槽數、每條連線一次、交握成本；晶片本身約每秒 8 次（F§9） |
| P6 | **檔案後端也改用每次連線的證明，拿掉 `sig_static` 與 `boot_id`** | 兩種樣式同一條登入路徑。這是協定改動，放 PR 3 |
| P7 | **不做協定相容**：PR 3 merge 後，舊 app 不認新節點、新 app 不認舊節點。PR 3 等 v1.6 結束才 merge。**PR 2 的晶片映像只裝在 bench 晶片節點上跑 helper 層的測項**（驗證工具經 `helper.sock` 直接對 helper 說話，`provclient/main.go:575-600`，不經 app）；這段期間沒有 app 登入這台，所以不涉及 K13（審查 v5set-B B1） | PR 2 的晶片映像講舊協定，`sig_static` 要用只能內部簽章的槽 1 簽，app 登不進去（審查 v4set-A M4）。檔案樣式的憑證 DER 不變，app 釘的是 DER，所以 02 / 04 升級後不必重新認領。PR 3 這一版若試用失敗自動回退，新 app 登不進回退後的舊映像 → §10 Q7 |
| P8 | **燒錄是 helper 的命令列模式**，開發根的簽章在開發者電腦上做（晶片設定 §5） | 只有 helper 碰晶片（K21）；開發根私鑰不放節點；節點映像也不放開發根公鑰（晶片設定 §2） |
| P9 | **晶片的簽章由 helper 轉成 low-s；app 驗 `id/prove` 時要求 low-s** | 晶片的 ECDSA 約一半是 high-s。節點端已拒絕 high-s（`proto.go:107-117`）；app 驗節點簽章的 `es256_verify`（`nodecert.rs:58-63`）今天不檢查 low-s（⚠️ 依 RustCrypto 的行為推論，PR 3 以向量確認），所以 PR 3 在 `id/prove` 的驗證加上 low-s 檢查（審查 v5set-A m11） |

## 1. 現況（✅ main 4eba26d + #379）

- 身分：PR 1 已把 helper 對身分的使用改成 `keystore.Identity` 介面（`SN`、`DeviceID`、`Cert`、`DACPub`、`ECDHPub`、`ECDH`、`CheckMac`、`SignPurpose`、`Backend`），唯一實作是檔案後端；身分檔 `node.key ecdh.key node.cert claim.secret backend sn` 加 sha 清單（`keystore.go:31`、`prov-lock.sh:7`）。
- `sn` 就是節點 id：檔案是 18 個 hex 字元加換行（`keystore.go:210`），`DeviceID() = hex(sn)`（`keystore.go:45-46`）。讀它的地方：provd 的 `deviceID = hex(sn)`（`server.go:357`），用在 Noise prologue（`:747`）、info（`:597`）、廣播後綴（`:638-639`）；PSK 以 `KS.DeviceID()` 衍生（`node.go:438`）；app 的 `device_id = hex(sn)` 並要求憑證主體 serialNumber 等於它（`nodecert.rs:118-121`）；認領證明的 `CheckMacInput` 用 `sn[8]`、`sn[0:2]`（`proto.go:54-70`），app 在 `claimflow.rs:172` 與 `replayflow.rs:204` 用 `Verified.sn` 算回應。
- `ecdh_pub` 的讀者：app 經 `Verified`（已驗過）取用；但 `approve.rs:525` 匯入加入申請時直接讀 `node_cert` 的欄位 4。
- 晶片的 ECDH 會被用在：`psks()`（`node.go:438-455`）——ECDH 失敗時**靜靜省略** `psk_replay` / `psk_member` 仍回成功，provd 快取這組並清掉 `needPSK`（`server.go:505`）；`openSecrets` 把失敗回成 `EBadObject`（`node.go:1089-1091`）；開機完成未完成的無線變更時歸類為 `causeDesired`（`wtxn.go:328-336`）。今天檔案後端的 ECDH 不會失敗，所以這些都沒有問題。
- 開機：`daemon()` 先 `boot.Run`（`main.go:631`）做對帳並每次寫 `prov-state`（`boot.go:278-303`），rc 7 / 9 經 `Env.Generate` 產生身分（`boot.go:33, 142`）；再 `keystore.Load`，失敗就 `select {}` 永遠不服務、不重試（`main.go:632-636`）；之後 `applyState`、計時器、`BootFinish`（`:703`）、最後 `Listen`（`:706`）。`--boot`（會跑 `boot.Run`，`main.go:575`）、`--persist-now` 是另外的命令列模式。
- 保存：身分「只寫一次」，`batman-config-save --prov-only` 拒絕與 p5 不同的身分（`:435-436`），覆蓋層與 p5 不同就凍結（`:429-431`，`boot.go:112-114`）。
- 試用開機：provd 連上 helper 滿 60 秒後 helper 寫 `$RUNDIR/provd-stable`（`stable.go:30-50`）；autocommit 每次輪詢重讀；`is-trial` 回傳碼不是 1 一律當試用（`trial.go:31-35`）。
- OTA：發行資訊的簽章內容只接受固定的鍵（`release.go:262-264`）；app 推的更新只比對板子名稱（`update.go:311-313`）。
- 驗證工具：`provclient node claim / claim-attacker / claim-attacker-chal / replay` 在節點上以 root 讀 `claim.secret`（`tests/tools/provclient/main.go:517`）；擁有者的簽章由主機端回答，`SIGN` → 簽章者的迴圈有四份：`prov-lib-254.sh:52-68`、`prov-254.sh`、`fresh-254.sh:77-93`、`prov-bench-s0-254.sh:335-352`（`pcn`）；`prov-lib-254.sh:12` 把所有輸出 tee 進執行紀錄。preflight 今天只讀 `BATMAN_VERSION`，並要求全部節點同版本（`dv-preflight.sh:32, 41-42`）。
- 登入基準（#329）：連線到讀完狀態 2.8–5.6 秒；10 次登入 9 次 ≤ 20 秒（`329-app-uiux.md:998, 1021`）。

## 2. 節點端

### 2.1 身分介面（PR 3 之後）

| 方法 | 檔案後端 | 晶片後端 |
|---|---|---|
| `SN()`、`DeviceID()` | 不變 | `SHA-256(槽 1 公鑰 65 位元組)[:9]` 與它的 hex（**sn 就是節點 id**） |
| `DACPub()` | DAC 公鑰 | 槽 1 公鑰（密碼包的對象，`wtxn.go:132`） |
| `Cert()` | 自簽 `dev:` 憑證 | 槽 8 讀出後截到外層 DER 的長度；DER 之後不是全 0 = 未燒錄完成 |
| `ECDHPub()`、`ECDH(peer)` | 檔案 ECDH 金鑰 | 槽 2，明文輸出；晶片錯誤回「暫時失敗」（§2.4） |
| `SignPurpose(p, fields)` | DAC 簽 | 只接受 `Session`：槽 0 外部簽章（直通 nonce 載入 `SHA-256(label ‖ fields)` 再簽）；`Peer` 拒絕 |
| `CheckMac(chal, resp)` | 軟體計算，錯誤永遠是 nil | 晶片的 CheckMac，槽 5（晶片自己用它的序號）；晶片錯誤回「暫時失敗」 |
| `Backend()` | "file" | "se" |

- **`CheckMac` 改成回傳 `(bool, error)`**（PR 2）：今天回 `bool`（`identity.go:21-22`），晶片錯誤會被當成「回應錯誤」，在 `claim.replay` 還會計入每小時 10 次的失敗上限（`node.go:620-636`），晶片一次不穩就能讓擁有者一小時內無法復原（審查 v6set-A M2）。`claimVerify`（`node.go:574-575`）與 `claim.replay` 把錯誤回成可重試的錯誤碼，不計入失敗次數。檔案後端永遠回 nil，行為不變。
- 晶片序號在節點端只出現在晶片內部、身分快取的 `chip_sn` 與憑證擴充欄位，不經過 `SN()`。
- `SignPurpose` 的用途是固定列舉：PR 3 加 `Session`（`"batman-node-session-v1" ‖ h`，`h` 剛好 32 位元組）；刪除 `Static`；`ECDH` 只留給檔案後端；`Peer` 只留給檔案後端（`peers/challenge` 今天被拒絕，`session.go:62`；晶片後端沒有用途就不帶，審查 v5set-A m8）。

### 2.2 晶片驅動（`se608` 套件）

- I2C：`/dev/i2c-1`，`ioctl(I2C_SLAVE = 0x0703, 0x60)`，100 kHz。權限由晶片映像附的規則設成 root 0600；helper 不另做 `lstat` 檢查。§4 有負向測試，E0b 記錄實際權限。
- 喚醒：對位址 0x00 寫一個位元組，讀回 `0x11`；每個序列結束送閒置。封包：計數 + 指令 + CRC-16（0x8005）；輪詢等待，逾時用最快時脈的上限（F§9）。
- **序列器與鎖**：helper 常駐終生持有晶片鎖（root 專用執行目錄下的鎖檔，`flock` 獨占）；驅動內一個互斥鎖讓一次只跑一個指令序列。
- **產品需要的指令（9 個）**：Info、Read、Write、Lock、Nonce（只有直通）、GenKey、Sign（只有外部）、ECDH、CheckMac。常駐程式的 GenKey 只能用「讀公鑰」模式；「產生」模式、Write、Lock 只在燒錄模式可用，驅動在其他情況拒絕。
- **不實作**：Random、Nonce 亂數模式、內部簽章、GenDig、MAC、SHA、KDF、AES、Counter、UpdateExtra、DeriveKey、PrivWrite。這些只在 `se-lab`（§5）。
- **故障注入接縫**：`prov_test` 建置的 `se608` 讀既有的 killpoint 檔（`seam.Arm`，`main.go:629`）裡的 `se-fail=<N>`：讓接下來 N 個序列回「無回應」，之後恢復。只在白箱映像裡有（審查 v5set-B m12）。
- 單元測試：以 cryptoauthlib 主機端演算法產生的向量比對封包、CRC、CheckMac 的雜湊輸入。PR D 的狀態碼與位元組格式標為暫定；E1 / E8 / E17 擷取的真實回應回填後才拿掉標記，PR 2 的 CI 在標記還在時失敗。

### 2.3 開機（晶片映像）

**順序與今天相同**：`boot.Run` → 載入身分 → `applyState` → 計時器 → `BootFinish` → `Listen`。晶片映像改這幾處：

1. **`identSum`**（不讀晶片；**兩種映像共用**）：依 `backend` 的檔案清單齊全且 sha 清單正確 = 有身分；`backend` 與這個映像的後端不同 = **「有身分、但是別的後端」**，`boot.Run` 在依 rc 分支之前就判 `unknown(backend-mismatch)`，不寫、不作廢、不產生任何東西（覆蓋層與 p5 都檢查）。檔案映像也做這個檢查，所以 #255 之後的檔案映像在 rc 7 / 9 也不會蓋掉晶片快取產生軟體身分（審查 v6set-A、v6set-B）。`backend-mismatch` 與 `identity-mismatch` 一樣：不重試、不打開 socket。
2. **`Env.Generate`（rc 7 / 9）**：寫快取時先寫暫存目錄、完成後改名（斷電在中途 = 沒有快取，下次開機再產生）。只在常駐程式裡 = 「讀晶片，晶片已燒錄（S4）就寫出身分快取」；晶片無回應或未燒錄 → 錯誤 → `unknown(generate-failed)`。`--boot` 這類命令列模式裡的 `Generate` 一律回「只有常駐程式能讀晶片」的錯誤，所以命令列模式不碰晶片（審查 v5set-B m1）。命令列模式的 `copyDir` 等今天呼叫 `keystore.Load` 的地方，在晶片映像只讀快取檔案。
3. **載入身分**（今天 `select {}` 的位置）：載入快取並與晶片比對——快取的 `sn` 與 `chip_sn` 等於晶片的、`node.cert` 等於槽 8 的憑證且結構相符（晶片設定 §2，節點不驗開發根簽章）。
   - 相符 → 往下照常。
   - 晶片無回應或未燒錄 → 等待後重試整個 `boot.Run` + 載入。等待從 10 秒開始，每次加倍，最長 5 分鐘（每次重跑都會掛載 p5）。重跑得到的新結果取代原本的判斷（`n.Verdict`、`BootFinish` 用的值）。`prov-state` 只在內容改變時寫（`writeProvState` 先比對；#104）。
   - 快取的 `sn` ≠ 晶片的（換了 HAT），或 `node.cert` ≠ 槽 8（有人在快取寫出後換了憑證）→ 凍結 `unknown(identity-mismatch)`，不寫、不作廢任何紀錄，不再重試。
- 晶片在載入這一步等待時，`applyState`、健康、更新計時、未完成的無線變更都還沒開始，與今天「沒有身分」的情形相同；mesh 照現有設定運作。晶片回應後依序執行。
- 其他 p5 回傳碼的行為與今天相同（rc 0 還原、rc 13 以 `sn` 比對後重新保存）。
- **換 HAT**：凍結（與今天 P-U6 相同），不作廢紀錄、不動網路金鑰與 SSH 金鑰；復原 = 重燒卡。

### 2.4 晶片故障

- **開機時**：見 §2.3。試用中晶片一直沒回應：socket 不打開 → provd 連不上 → `provd-stable` 不寫 → 試用逾時回退。晶片在逾時前恢復：開始服務、照常確認。
- **服務中**：只有 `SignPurpose`、`ECDH`、`CheckMac` 會碰晶片（其他值來自快取），所以晶片故障只在用到時才看得到（審查 v5set-B m3）。晶片錯誤一律回「暫時失敗」，下一個請求重試晶片（不閂鎖）。具體：
  - `psks.get`：任何一個 ECDH 失敗就整個回錯誤，**不省略**；provd 對非成功的回應在下一個週期重試並保留舊的一組（`server.go:513`）（審查 v5set-A M2）。
  - `openSecrets`：晶片錯誤回可重試的錯誤碼，不是 `EBadObject`。
  - 開機完成未完成的無線變更時：晶片錯誤歸類為暫時性（`transientCheck`），`.txn` 保留、下次再試。
  - 所有解開已存的網路密碼的路徑都經過 `decryptSecrets`，它今天對任何失敗都回 nil：呼叫者 `openStoredSecrets`、`netRoot`（`psks` 的會員 PSK）、`finishWantsRadio` 與完成無線變更的路徑，都改成分辨「晶片暫時失敗」與「資料錯誤」。
  - `CheckMac`：見 §2.1。
- **試用中服務後晶片失敗**：同一個序列立刻重試一次；**重試也失敗**才刪除 `provd-stable`，並設一個與 `stableWriter.done` 並列的旗標，這次開機不再寫它，試用不會被確認（一次短暫的錯誤不會讓好的 OTA 回退，審查 v6set-B）。helper 是 `provd-stable` 唯一的寫者。
- autocommit 已確認之後晶片才失敗：確認不撤回（不在本期範圍）；helper 照常服務並重試。
- 沒有 A/B 的卡（`is-trial` 回 2）：不再寫 `provd-stable`，但沒有回退；helper 照常服務並重試。

### 2.5 燒錄（`batman-provhelper se-burn`）與 `se-sign`

照晶片設定 §5。實作：

- 節點端：`se-burn status`（唯讀 JSON）；`se-burn`（每次讀狀態做下一步 S0 → S3；S1、S3 從 stdin 讀「預期序號 + 秘密」，序號不符就拒絕；S3 輸出資料包）；`se-burn cert < cert.der`（**只在沒有身分快取時**寫槽 8）。拒絕條件：常駐程式在跑（拿不到鎖）、試用開機、沒有 `/etc/batman-dev-open`（刻意的一步，不是安全控制）。
- 開發者電腦：`feed/batman-prov/src/cmd/se-sign`（同一個 Go module，不打包進映像）：`begin <host>`（讀 status；沒有紀錄才產生秘密，「待寫入」就沿用；經 ssh stdin 交給 `se-burn`）；`sign <bundle>`（依晶片設定 §4、§5 的規則驗證並簽、產生 QR 圖檔）。所有檔案在 WSL ext4 上 0600。秘密不出現在命令列參數、終端機或任何 log。
- 晶片映像的 `provhelper qr` 回「不支援」。

### 2.6 provd

- `buildNodeCert` 依 helper `info.cert` 新增的第 3 項（`backend`）決定樣式：檔案樣式照今天組欄位 4、6（不再呼叫 `sign.static`）；晶片樣式不放欄位 4、6、不呼叫 `sign.ecdh_proof`（審查 v5set-A m9）。`deviceID = hex(sn)` 不變。
- 新請求 `id/prove`：所有角色（含匿名）都可送，每條連線一次，回 `SignPurpose(Session, h)`；不經全域限制。
- `psks.get` 回錯誤時照今天的重試路徑（§2.4）。
- `peers/challenge` 維持拒絕。對 helper `info.boot_id` 的輪詢保留。

### 2.7 誰能碰晶片

- 只有 helper（含燒錄模式）。`/dev/i2c-1` 0600 root；provd 的 uid 打不開（EACCES）；承租容器裡沒有這個裝置（ENOENT）。
- `batpower` 在程式裡拒絕位址 0x60（不只靠 uci 設定值；它若對 0x60 發 `i2cget … 0x02`，會讓晶片進閒置）。

### 2.8 建置、版本、出貨閘門與 shell

| 項目 | 做法 |
|---|---|
| Go | build tag `prov_se`；`Makefile` 由 `BATMAN_PROV_SE=1` 帶入。DV 的 `se-fail` 單元需要 `prov_test` + `prov_se` 的白箱晶片映像：`build-board.sh --wbox`、`lint-wbox.sh` 一起支援 |
| 重新建置 | firmware fork 的 `build-board.sh` 比照 `prov_test`，記錄上次的參數，不同就清掉 helper 的建置。firmware repo 的 PR，列在 §9 |
| I2C 設定 | `dtparam=i2c_arm=on` 在 firmware 的 `distroconfig.txt`，兩種板子、兩種映像共用，OTA 不會帶（審查 v6set-B）。做法：加進共用檔，兩種映像都開；bench 晶片節點本來就是重燒卡。檔案映像多開一個 I2C 匯流排，E0b 確認不影響現有裝置。⚠️ firmware repo 的檔案未在本 repo 查證 |
| 版本標記 | `batman-provhelper --version` 印出後端；`/etc/batman-build` 加 `BATMAN_PROV_BACKEND=se`（只有晶片映像加；沒有 = 檔案映像）。晶片映像的 `BATMAN_VERSION` 與同一個 commit 的檔案映像相同（preflight 要求全部節點同版本） |
| OTA | **不改**。後端不符的更新一定會在試用時回退：晶片映像到檔案節點 → `backend-mismatch`；#255 之後的檔案映像到晶片節點 → 檔案後端拒絕 `backend=se`；#255 之前的映像到晶片節點 → `identity-lost`。三種都不會打開 socket，`provd-stable` 不寫（審查 v5set-B M7） |
| shell | `prov-lock.sh` 的 `PROV_IDFILES` 與 `prov_ident_ok`、`batman-config-save` 的 `--prov-identity` 與 `--prov-get` 檢查（`:229, 521-536`）、`96-batman-config-migrate` 的複製（`:158-163`）改成依 `backend` 決定檔案清單：file = 今天的 6 個；se = `backend sn node.cert chip_sn` 加 5 行以內的 `sha256` |
| 映像內容 | 晶片映像要有 `kmod-i2c-bcm2835`、`kmod-i2c-dev`、`dtparam=i2c_arm=on` 與 `/dev/i2c-1` 權限規則，經 board diffconfig（絕不裸跑 `make defconfig`）。今天的映像只有 `kmod-i2c-brcmstb`（`boards-and-builds.md:136`） |
| 出貨閘門 | 晶片映像不發行，閘門只檢查**發行的檔案映像**不含 se 後端、假晶片、`se-lab`、`se-sign`、不含鎖定指令的實驗建置、或 `prov_test` × `prov_se` |
| CI | `go test` 加 `-tags prov_se` 與 `-tags prov_se,prov_test` 兩步（H1），有哨兵：找不到 `prov_se` 測試就 FAIL。PR 2 之前這一步在 main 上是紅的，照既有的先例標明（`ci.yml:172`）。`dv-sbx` 加一個 `prov_se,prov_test` 的 helper 建置 |

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
| 7 sn | 節點 id 的位元組（不變） | 同（**不是**晶片序號） |

晶片樣式的憑證（寫入槽 8 後要換只能重燒卡，晶片設定 §5.3）：

| 項目 | 內容 |
|---|---|
| 格式 | X.509 v3，完整 DER，**≤ 416 位元組**（槽 8）；簽章演算法 ecdsa-with-SHA256，外層與 TBS 的 AlgorithmIdentifier 必須相同 |
| 大小預算 | 兩位審查以 Python `cryptography` 實際建出 v4 的格式，是 448–469 位元組，放不下（審查 v6set-A M1、v6set-B M1）。v5 拿掉三樣沒有用的東西：主體的 serialNumber（晶片樣式的節點 id 由 CN 與主體金鑰決定）、BasicConstraints（app 只接受開發根直接簽發、結構固定的憑證，不建憑證鏈，CA 旗標沒有作用）、長的簽發者名稱（開發根的 CN 用 1–2 個字元）；序號欄位用 1–8 位元組；私有 OID 盡量短。預估約 390 位元組。PR D 的 CI 以最大可能的值（簽章 72 位元組、所有整數取最長）建出憑證，斷言 ≤ 416；做不到就改用槽 8 + 槽 9 兩個槽（只改最終影像的槽 9 設定，變體不受影響），晶片設定改版再審 |
| 簽發者 | 開發根（P-256，自簽，只用於 bench），CN 1–2 個字元 |
| 主體 | 只有 CN = `se:<device_id>` |
| 主體金鑰 | 槽 1 公鑰 |
| 擴充欄位 | 只有一個：私有 OID，非關鍵，內容 CBOR `{0: 槽 0 公鑰, 2: 槽 2 公鑰, 7: 晶片序號 9 位元組}`（公鑰 33 位元組壓縮格式，解壓時檢查在曲線上）。其他任何擴充欄位 → 拒絕 |
| 有效期間 | 2020-01-01 起（同 `DevCert`，`keystore.go:102-104`）到 9999-12-31。沒有任何驗證者檢查時間 |

### 3.2 app 的驗證（`nodecert.rs` 與讀它的地方）

- **樣式判斷**：以開發版 app 裡的開發根公鑰驗憑證簽章，通過且 CN 以 `se:` 開頭 = 晶片樣式；自簽且 CN 以 `dev:` 開頭 = 檔案樣式；其他一律拒絕。不依簽發者名稱的文字判斷。欄位組合必須完全符合該樣式。
- 兩種樣式共同（`common()`）：`device_id = hex(第 7 欄)`。檔案樣式照今天要求主體 serialNumber 等於它；晶片樣式改為要求 CN = `se:<device_id>`（晶片樣式的憑證沒有 serialNumber，以控制大小）。
- 晶片樣式另外：`device_id = hex(SHA-256(憑證主體金鑰)[:9])`；擴充欄位剛好 0、2、7 三項。
- **`id/prove`**：收到 msg2 後立刻送，驗 `"batman-node-session-v1" ‖ h` 的簽章，**要求 low-s**，公鑰 = 檔案樣式的憑證金鑰 / 晶片樣式擴充欄位的槽 0 公鑰；驗過之前不送任何其他請求，也不保存任何東西（`claimflow.rs:168-182` 的 `PersistPending` 移到證明之後）。三個交握驗證點都要做：`loginflow`、`claimflow`、`replayflow`。
- **認領回應用的序號**：`Verified` 加 `claim_sn`（檔案樣式 = 第 7 欄；晶片樣式 = 擴充欄位的晶片序號）。`claimflow.rs:172` 與 `replayflow.rs:204` 都改用它（審查 v5set-A M1）。
- **`ecdh_pub`**：檔案樣式 = 欄位 4 + `sig_ecdh`；晶片樣式 = 擴充欄位的槽 2 公鑰，都放進 `Verified`。`approve.rs:525` 匯入加入申請時改用 `verify_offline` 的結果，不直接讀欄位 4。
- PR 3 以 grep 列出 `app/rust`、`tests/tools`、`app/tools` 裡所有讀 `node_cert` 欄位 4、7 與 `Verified.sn` 的地方，逐一列在 PR 裡，各附晶片樣式的測試。
- `trust_gate`：開發版接受兩種樣式；field 版兩種都拒絕。開發根公鑰只在 `DEV_TRUST` 下編譯。今天每個 APK flavor 都帶 `dev-trust`（`cargokit.yaml:1-11`，cargokit 無法依 flavor 分開，`:1-3`），field APK 靠啟動時的交叉檢查拒絕。第 1 期不建 field APK，所以維持這個現狀，不另做分 flavor 的建置（審查 v5set-A m14）；`check-field-build.sh` 對主機建置判定 field 版不含開發根公鑰（H2）。
- `verify_offline`（三段式加入）：沒有 `h`，無法驗當場證明。兩種樣式都只驗憑證與欄位組合，並回傳 `ecdh_pub` 與 `claim_sn`。**第 1 期沒有當場證明，是 K20 的一個偏離**，第 2 期移除這條路 → §10 Q4。
- 節點端密碼包的對象：`SHA-256(DACPub())`（`wtxn.go:132-135`），晶片後端的 `DACPub()` = 槽 1 公鑰。

### 3.3 認領

- `CheckMacInput` 不變。`ClientChal` 雜湊的是整張憑證 DER，晶片樣式下就是開發根憑證，認領證明仍綁住身分金鑰。
- QR 不變：`{1: device_id, 2: 認領秘密}`，由 `se-sign` 產生。

### 3.4 測試向量（H2）

晶片樣式與負向向量：最大可能大小的晶片憑證 ≤ 416 位元組；晶片序號 ≠ 節點 id（假晶片也是）；**晶片樣式的 `claim/replay` 回應**與**晶片樣式加入申請的匯入**（兩者在今天的程式上 FAIL）；晶片樣式多了欄位 4 或 6；擴充欄位的槽 0 公鑰被換掉；擴充欄位多一項或少一項；未知的關鍵擴充欄位；CN 或 serialNumber 與 `SHA-256(主體金鑰)[:9]` 不符；開發根簽的 `dev:`；自簽的 `se:`；field 版拿到有效的晶片 `node_cert`（`verify_first_contact` 與 `verify_offline` 都要 `Untrusted`）；`id/prove` 的簽章換成另一條連線的；high-s 的 `id/prove` 簽章 → 拒絕。`fakeMsg2` 的長度要等於真實 msg2（`noise.go:108-109`），並檢查晶片樣式的 msg2 在框架與 MTU 限制內。

## 4. 驗證工具與測試（三個 harness PR，都比對應的產品 PR 先進 main）

### 4.1 H0：主機端回答認領挑戰（v1.6 打完 tag 之後 merge）

- **`MAC` 行**：`provclient node claim`、`claim-attacker`、`claim-attacker-chal`、`replay` 在節點上不再讀 `claim.secret`，改成在 stdout 輸出 `MAC <ClientChal hex>`；主機端 `provclient mac` 依**節點清單**找到這台的紀錄（節點清單：H0 在 harness 加一個檔案，以節點名稱為鍵，記錄後端與紀錄的位置；節點換 IP 不影響。若 harness 已有節點清單就加欄位），用紀錄裡的序號（檔案節點 = 節點 `sn`；晶片節點 = 晶片序號）與秘密算出回應，回 `MACR <hex>`。四份 `SIGN` 迴圈（`prov-lib-254.sh:52-68`、`prov-254.sh`、`fresh-254.sh:77-93`、`prov-bench-s0-254.sh:335-352`）都加 `MAC` 分支；CI 加一條檢查：每個處理 `SIGN` 的地方都有 `MAC` 分支。`provclient` 等主機回答時有逾時（30 秒，與簽章相同），逾時 = 單元 FAIL，不會卡住（審查 v6set-B M3）。
- **檔案節點的秘密**：每次**產生新身分之後**（執行開始時，以及每個重建 p5、產生新身分的單元在那一步之後）以 `scp` 把 `claim.secret` 與 `sn` 一起直接存成檔案，不經過 stdout（`prov-lib-254.sh:12` 會把 stdout 寫進執行紀錄）。存放處是 Windows 使用者自己的暫存目錄（`%LOCALAPPDATA%\Temp` 下，Windows ACL 只有該使用者能讀；Git Bash 在 NTFS 上的 `chmod` 無效），`trap` 在每一種結束時刪除（審查 v5set-A m13、v5set-B M4）。
- **log 洩漏檢查搬到主機端**：`prov-claim-254.sh:49-51`、`scripts/node/prov-p1-254.sh:63-66` 改成把 logread 複製回主機比對；另加一條：執行紀錄裡不得出現任何秘密。
- **preflight**：讀 `BATMAN_PROV_BACKEND`（沒有 = file），與節點清單比對，不同就拒絕。今天的節點清單都標 file、映像都沒有這個鍵，所以 v1.6 的執行不受影響。
- **負向對照**：把節點上的 `claim.secret` 暫時移開——舊工具在 `claim.secret` 讀取失敗，新工具照常 PASS；之後移回。並在 v1.6 的映像上跑一次全套確認不退步。
- 不含：任何 v2 的東西（在 H2）。

### 4.2 H1：晶片節點的單元（PR D 之後、PR 2 merge 之前；前提是 §10 Q8 已決定）

- `se-fail`（白箱晶片映像）：開機時晶片無回應；試用中無回應 → 回退；**試用中服務後才失敗**（注入後立刻送一個會碰晶片的請求，如 `claim.verify`，再等 autocommit 的輪詢）→ 不確認；已認領、開機時晶片無回應、有未完成的無線變更 → 晶片恢復後變更完成；**PSK 取得時晶片無回應**：在 helper 層以 `provclient` 呼叫 `psks.get`，故障中回錯誤、恢復後回完整的一組（今天的 `psks()` 會回成功但少了 PSK，所以 FAIL）；**`claim.replay` 時晶片無回應**：回可重試的錯誤，失敗計數不增加（今天的程式計數增加，FAIL）。
- 開機的後端檢查：rc 0 與 rc 7（p5 有身分、沒有紀錄）各放一份 `backend=file` 的身分 → `backend-mismatch`，不寫任何東西。
- 晶片映像不產生 `node.key`（負向對照：一個 wbox 修補讓晶片映像退回檔案後端，這條必須 FAIL）。
- **每個案例各有一個變異體當負向對照**（例如拿掉 `provd-stable` 撤回、拿掉 `psks` 的錯誤回傳、拿掉 `CheckMac` 的錯誤分辨），在 H1 的 PR 裡列出。
- 以 provd 的 uid `open("/dev/i2c-1")` → EACCES（負向對照：權限 0644 的假裝置讓它 FAIL；`prov-wbox` 的 bind 允許清單加 `/dev/i2c-1`）；承租容器內 → ENOENT。
- 燒錄拒絕：常駐在跑、試用開機、序號不符、已有身分快取時 `se-burn cert`。
- CI 的 `prov_se` 兩步與哨兵。
- **shell 與 CI 測試的晶片版本**：`tests/prov-p1/cfgsave-identity-freeze.sh`、`cfgsave-provget-rc10.sh`、`cfgsave-frozen-nomount.sh`、`sbx/cases/cfgsave.sh`、`sbx/cases/helper.sh`、`prov-lock-init.sh` 各加晶片快取的案例；`tests/wbox/96-noprov.patch`、`96-norestore.patch` 確認仍能套用。
- **逐單元對照表**（晶片節點上；H1 實際讀完每個單元後在 PR 裡定稿，下表是目前已知的）：

| 單元 | 讀什麼 / 假設什麼 | 晶片節點上 |
|---|---|---|
| `prov-provd-254`、`prov-provd-wbox-254` | `identity/sn`；需要 provd 組出 `node_cert` | PR 2 的晶片節點上**不能跑**（PR 2 的 provd 仍呼叫 `sign.static`，晶片後端拒絕，provd 不會就緒，`server.go:337, 531`）；PR 3 起照常 |
| `prov-overlay-wipe-254`、`fresh-254` | `node.cert` | 照常；但 `fresh-254.sh:45` 的 `prov_files` 計數在晶片節點是 5 |
| `chain1-254` | `prov_files=7`（`:201`）；重建 p5 後「新身分」（`:162-207`） | 改：晶片節點期望 5 個檔案、重建 p5 後**同一個** `device_id`（C5） |
| `prov-bench-s0-254` | 重建 p5 後記下「新的序號」（`:44, 68`） | 改：晶片節點期望同一個 `device_id` |
| `prov-chain0-254` | `node.key` | 改：今天的「沒有 `node.key`」在晶片節點上永遠成立，判不出東西；改為斷言快取剛好 5 個檔案、`backend=se`、沒有任何私鑰檔、`sn` 等於晶片的（退回檔案後端的變異體讓它 FAIL） |
| `prov-sec-254`（兩處） | `node.key` 權限與負向對照 | 改：判 `/dev/i2c-1` 權限，0644 假裝置為負向對照 |
| `prov-p1-254` | `claim.secret`；`node.key`、`ecdh.key` 的權限（`:39-41`） | 秘密：H0 已改為主機端；權限：晶片節點改判快取檔權限與 `/dev/i2c-1` |
| `prov-claim-254` | `claim.secret` | H0 已改為主機端 |
| `prov-p2-254`（`scripts/node`） | 等 provd 的 log「re-signing node_cert」 | H2 隨 `node_cert` v2 調整 |
| `prov-downgrade-254` | 裝舊映像 | 改成負向測試：sysupgrade 到舊映像 → 凍結 `identity-lost` → 試用回退 |
| `prov-legacy-upgrade-254`、`negctl-old-slot` | 舊映像、拿掉 p5 紀錄 | H1 實跑判斷；任何要在晶片節點上拿掉的單元先問使用者 |

- **PR 2 晶片節點上的範圍**：只跑 helper 層（經 `helper.sock`）的單元與上表標為可跑的單元；需要 provd 或 app 的單元（上表標「不能跑」的）到 PR 3 才跑。這是 PR 2 → PR 3 之間暫時少跑，不是從全套拿掉；PR 3 的全套把它們都跑回來。
- 證據：在變異體與 PR 2 之前的產品上 FAIL，在 PR 2 的 rc 上 PASS。

### 4.3 H2：v2 協定的測試資料與工具（PR 3 merge 之前）

- §3.4 的向量（`gen.py` / `verify.py`）；對端工具（`tests/tools/peer/*`、`provclient`、`app/tools/synth-joinreq`、`netobj.py`）依欄位組合分辨 v1 / v2；`ci-check.sh` 的 `MIN_CHECKS` 依版本分開計，v2 的檢查數為 0 時 FAIL；`check-field-build.sh` 的開發根檢查（開發根公鑰在 PR 3 進 app）。
- 證據：v2 的向量在 PR 3 之前的產品上 FAIL，在 PR 3 的 rc 上 PASS；v1 的部分在 v1.6 映像上照常 PASS（審查 v5set-B M5）。

### 4.4 各產品 PR 的測試

| 類別 | 內容 |
|---|---|
| 假晶片（PR D） | 有狀態：設定區與資料區、兩區的鎖（鎖定位元組照 F§1.2）、每槽的鎖、真的 P-256 金鑰、CheckMac 真的比對、序號 ≠ 節點 id；能模擬「N 次無回應後恢復」；格式標為暫定 |
| 燒錄（PR 2，假晶片） | 每個狀態 S0–S3 中斷後重跑都能接續；S1 在資料區鎖定後中斷 → 重跑 `begin` 送出**同一個**秘密；S1 的 CheckMac 前中斷 → S3 先補 CheckMac；比對規則：正確燒錄通過、86 = `0x55` 或 88 = `FF` 拒絕；兩顆晶片的憑證互換 → 拒絕；`se-sign` 拒絕槽 1 公鑰重複的資料包 |
| 開機（PR 2） | §2.3 的每一種情況；`--boot`、`--persist-now` 不碰晶片；重試的退避與 `prov-state` 只在改變時寫 |
| 晶片故障（PR 2） | §2.4 的三條路徑在假晶片上各一個測試 |
| 協定（PR 3） | H2 的向量；三個交握驗證點都做 `id/prove`；`replayflow` 與 `approve::import` 的晶片樣式 |
| 爭用（PR 3） | 兩個會員連線反覆送 `id/prove`，擁有者同時登入，要在基準時間內成功 |
| 出貨閘門（PR 2） | 發行的檔案映像含任一禁止項目 → 閘門擋下（各附一個錯誤建置） |
| 登入時間（PR 3 + 晶片節點） | 同一支手機（S20）、同一個 R-7 程序，檔案節點與晶片節點各 10 次登入，改動前後各一組；預期增加一個 GATT 來回加一次簽章（晶片 ≤ 200 ms）；結果交給使用者決定（K15，§10 Q5） |

手動、無法自動化的（拔晶片、換 HAT、燒錄中斷電）列為手動測項，結果附在 PR。

## 5. 晶片實驗程式

`feed/batman-prov/src/cmd/se-lab`（同一個 Go module，共用 `se608` 的封包與 CRC 程式碼，不打包進映像），規則見晶片設定 §8.0。它要有：直通 nonce + 外部簽章、GenKey 各模式（槽 1、2、4）、UpdateExtra（位元組 85）、AES、Random，以及設定文件 §8 各列用到的指令。PR D 交付，含不含任何鎖定指令的建置。

## 6. 擁有權、契約

| 資源 | 唯一能改的 | 只讀 |
|---|---|---|
| 晶片與匯流排上的晶片狀態 | 持有晶片鎖的程式：helper 常駐（序列器）或燒錄模式；`se-lab` 只在實驗台 | — |
| 覆蓋層的身分快取 | 開機時依序兩個寫者：`96-batman-config-migrate`（S10，從 p5 複製，依 `backend` 的檔案清單）→ helper 常駐（S89，`Generate`）。不同時執行 | `prov-lock.sh`、`batman-config-save`、腳本、命令列模式 |
| p5 的身分 | `batman-config-save` 的保存，只寫一次 | helper、`96-batman-config-migrate` |
| 槽 8 | `se-burn cert`，只在沒有身分快取時 | helper（載入時比對） |
| `provd-stable` | helper | autocommit |
| 燒錄紀錄、開發根私鑰 | 開發者電腦的 `se-sign`（兩個分開的目錄） | 驗證工具只讀燒錄紀錄 |
| 檔案節點秘密的主機副本 | H0 的驗證工具（每次執行的暫存目錄） | `provclient mac` |
| `node_cert` | provd（由 helper 提供材料） | app、對端工具 |

| 介面 | 寫 → 讀 | 缺漏或錯誤 |
|---|---|---|
| `id/prove` | provd → app | app 拒絕連線，不保存任何東西 |
| `node_cert` v2 | provd → app | 欄位組合不符或驗不過 → 拒絕 |
| `info.cert` 第 3 項 `backend` | helper → provd | 缺少 → 當成 file（今天的 helper）；值不認得 → provd 不服務 |
| `psks.get` | helper → provd | 晶片錯誤 → 錯誤碼，provd 保留舊的一組並重試 |
| 身分快取目錄 | helper → 腳本 | sha 清單不符 → 腳本判 FAIL；helper 下次開機重新比對 |
| `MAC` / `MACR` 行 | `provclient`（節點）↔ `provclient mac`（主機） | 主機沒有該節點的紀錄 → 不回答，單元 FAIL；序號取自主機的紀錄，不取自節點輸出 |
| `BATMAN_PROV_BACKEND` | firmware 建置 → preflight | 沒有 = file |
| 燒錄的秘密、資料包、憑證 | 晶片設定 §7 | 晶片設定 §7 |

## 7. 生命週期（晶片映像）

| 路徑 | 今天（檔案映像） | 之後（晶片映像） | 測試 |
|---|---|---|---|
| 首次開機，晶片已燒錄 | 產生檔案身分 | `Generate` 由晶片寫快取，未認領 | bench |
| 首次開機，晶片未燒錄 / 非本設定 / 無晶片 | — | `generate-failed`，不服務，退避重試，**不產生身分** | `se-fail` DV；變體晶片手動 |
| 開機（已認領） | 照常 | 照常；載入時與晶片比對 | DV |
| 開機時晶片無回應、有未完成的無線變更 | — | 等晶片；恢復後依序完成 | H1 |
| 正常關機、重開，或在指令序列中途關機 | — | 晶片進睡眠，暫存狀態全失；下次重跑整個序列 | 序列中途重開 |
| helper 重啟 / 當機重啟循環 | 照常 | 每次啟動只讀晶片，不寫 EEPROM；`node_cert` 不變 | 重啟 10 次後讀晶片狀態不變 |
| provd、bluetoothd 重啟 | 照常 | 照常 | DV 既有 |
| 服務中晶片短暫無回應 | — | 用到晶片的請求回暫時失敗；PSK 取得重試；恢復後照常 | H1 |
| 試用開機，晶片在開機時失敗 | — | 不服務 → 回退 | H1 |
| 試用開機，服務後晶片失敗 | — | 刪除 `provd-stable`、不再寫 → 回退 | H1 |
| 試用開機，短暫失敗後恢復 | — | 恢復後服務 → 照常確認 | H1 |
| OTA 晶片映像 → 晶片映像 | 照常 | 快取經 `96-batman-config-migrate` 搬移；與晶片比對 | DV（bench 晶片節點） |
| 回退到上一個晶片映像（K13） | 照常 | 同一顆晶片、同一個身分。**例外：PR 3 那一版**回退到 v1 協定的映像，新 app 登不進（P7，§10 Q7） | DV |
| app 推送另一種後端的更新 | — | 試用時回退（§2.8 OTA 列） | H1：`prov-downgrade-254`；CI |
| OTA 檔案映像 → 晶片映像（節點有檔案身分） | — | `backend-mismatch` 凍結 → 回退，**不作廢紀錄** | H1 |
| 晶片節點 sysupgrade 到檔案映像 | — | #255 之後的：還原的快取是 `backend=se`，檔案後端拒絕載入 → 回退。#255 之前的：`prov_ident_ok` 不認 → rc 13 → `identity-lost` → 回退 | H1：`prov-downgrade-254` |
| 晶片節點**重燒卡**成任何檔案映像 | — | p5 也被清掉 → rc 7 → 產生軟體身分（違反 K20）。不支援；驗證工具不做；手動重燒卡仍可能 → §10 Q3 | — |
| 重燒 SD 卡（晶片映像） | 新的軟體身分 | **同一個** `device_id`，紀錄沒了 → 未認領。app 若還有擁有者紀錄，登入失敗，重新認領後取代。⚠️ app 在這條路的畫面在 PR 3 確認 | bench |
| 換 HAT | — | 凍結 `identity-mismatch`，紀錄與金鑰不動；復原 = 重燒卡 | bench |
| 換憑證 / 換開發根 | — | 只能重燒卡後 `se-burn cert`、再認領（晶片設定 §5.3）；已有快取時 `se-burn cert` 拒絕；快取寫出後槽 8 被改 → 凍結 | H1、PR 2 |
| 把檔案節點改成晶片節點（v1.6 之後） | — | 只能重燒卡：使用者同意後重燒晶片映像（A/B 卡）→ `se-burn` → 認領。會清掉 p6 的承租資料；app 裡舊的紀錄由使用者刪除。這違反「模擬已部署 = 只 sysupgrade」的角色規則一次，要使用者同意 | 手動，結果附在 #255 |
| 燒錄中斷電 | — | 晶片設定 §5.2，從讀回狀態接續 | 假晶片 CI；F1 手動 |
| `Generate` 寫快取時斷電 | 今天的產生流程 | 快取先寫暫存目錄再改名：斷電 = 沒有快取 → 下次開機 rc 7 再產生（同一顆晶片、同一個身分） | PR 2：killpoint |
| 第一次保存到 p5 時斷電 | 今天的行為 | 同今天（保存是今天的程式）；快取由晶片決定，重新保存結果相同 | DV 既有 |
| `sysupgrade -n`（不保留設定） | 覆蓋層清空、p5 保留 → rc 0 還原 | 同；還原的快取再與晶片比對 | DV（bench 晶片節點） |
| 開機時 p5 讀不到（rc 1 / 8） | 今天的行為 | 同今天；載入時以覆蓋層的快取與晶片比對 | DV 既有 |
| 認領中斷電 | 紀錄交易 | 同 | DV 既有 |
| I2C 驅動 | — | 編進映像、開機載入；開啟失敗 = 無回應，重試 | E0b |
| 晶片映像裝到沒有 `/dev/i2c-1` 的機器 | — | 無回應 → 不服務、重試 | CI |
| bcm2710（Pi 3） | — | 不適用：沒有晶片版建置 | — |

## 8. 安全

- **新的輸入**：`id/prove`（任何人都能送，每條連線一次，不經全域限制）；`node_cert` v2 的新欄位與憑證擴充欄位（app 端嚴格解析）；燒錄模式（root、非試用、拿到晶片鎖）；`info.cert` 的 `backend`（helper → provd，同一台節點內）；`MAC` / `MACR` 行（驗證工具）。
- **逐個行為者**：
  - 遠端：只看得到 `node_cert` 與 `id/prove` 的簽章；重放 `node_cert` 不能通過 `id/prove`（金鑰取自憑證）；high-s 的變形簽章被拒。
  - 本機非 root 程式與承租容器：打不開 `/dev/i2c-1`（有負向測試）。
  - 被攻破的 provd：可以讓槽 0 簽任何 `h`、即時轉送證明、以每秒約 8 次佔用晶片。這等於 provd 被攻破，與今天的 `sign.static` 相同，列為殘餘風險。
  - 實體接觸（有 root 或能接匯流排）：可以讓晶片簽章、做 ECDH、覆寫或鎖住槽 8（只是拒絕服務或凍結），等於節點被攻破；不能取出私鑰或認領秘密，也不能讓別的機器變成這台。bench 接受。
  - 燒錄時的節點：開發根相信節點回報的公鑰，所以只在剛燒好卡、開發者在場時燒錄；`se-sign` 拒絕重複的槽 1 公鑰。
  - 被攻破的受測節點對驗證工具：主機端依節點清單選紀錄與序號，不依節點輸出。
  - 開發根外洩：能做出開發版 app 信任的假節點；開發版不對外，field 版不信任它。
  - 供應鏈：晶片是向經銷商買的空白品，由我們設定；不同型號在 E1 / `se-burn` 的版本檢查被擋下；版本相同但行為不同的仿冒品 bench 接受，量產晶片另議（晶片設定 §10）。
- **秘密**：認領秘密只在開發者電腦與晶片裡；經 stdin 傳一次；不進 repo、log、命令列參數。檔案節點秘密的主機副本只在每次執行的暫存目錄。開發根私鑰加密存放，與燒錄紀錄分開。晶片的 ECDH 明文輸出經過 I2C（bench 接受）。
- **失敗時**：拿不到身分就不服務（fail-closed）；任何不一致都凍結，不自動修正；晶片的暫時錯誤不被當成成功或「物件錯誤」。
- 本期不改變：PSK、網路密碼的保管、認領鎖定。

## 9. 交付順序與驗證矩陣

| 順序 | 內容 | 前提 / merge 時機 |
|---|---|---|
| PR 1 | `Identity` 介面（#379，已完成） | v1.6 打完 tag 後 merge |
| H0 | §4.1 | v1.6 打完 tag 後 merge |
| PR D | `se608` 驅動核心 + 假晶片 + 向量 + `se-lab` + `se-sign` 的憑證部分（先算憑證大小）。測試不帶 build tag（套件還沒接進 helper） | 現在可以開始；v1.6 打完 tag 後 merge |
| 實驗台 | 晶片設定 §8 的順序：E0a → E1 … E16 | 晶片已焊、使用者同意、本設計審過才 E4 |
| — | **§10 Q8 與實驗台的 Pi 型號決定** | H1 之前 |
| H1 | §4.2 | PR D 之後、PR 2 merge 之前 |
| PR 2 | 晶片後端、開機、晶片故障處理、燒錄模式、`se-sign`、§2.8（另有 firmware fork 的 PR）。**在 bench 晶片節點上**：E0b、F1（燒錄第 2 顆）、E14、H1 的晶片單元、helper 層的全套；不經 app 登入 | 實驗台的 E5、E6、E13、E15、E17；H1 先 merge |
| H2 | §4.3 | PR 3 merge 之前 |
| PR 3 | `node_cert` v2、`id/prove`、app；全套驗證（含 app 登入）+ 登入時間量測 | E8、E15；v1.6 結束；H2 先 merge |

| 階段 | 映像 | 節點 | 跑什麼 |
|---|---|---|---|
| PR D、H0 | — | CI、實驗台（Raspberry Pi OS） | 單元測試、假晶片、`se-lab` |
| H1、PR 2 | 檔案映像（PR 2 也改了檔案後端的 shell） | 檔案節點 | 全套 |
| H1、PR 2 | 晶片映像與白箱晶片映像 | bench 晶片節點（Q8） | E0b、F1、E14、H1 的晶片單元、helper 層的全套 |
| H2、PR 3 | 兩種映像 | 檔案節點與晶片節點 | 全套（含 app 登入、mesh）、登入時間 |
| 每次發行 | 檔案映像 | 依 Q8：(b) 照今天兩台；(a) 只剩一台檔案節點，mesh 測項的另一端是晶片節點（哪些 mesh 單元失去「兩台同映像」，在 Q8 決定時列出並請使用者同意） | 全套 |

## 10. 使用者決定

| # | 決定 | 狀態 |
|---|---|---|
| Q1 | 晶片先焊在其他片 WM1302 HAT 上做實驗，**不動 02 / 04**；v1.6 結束後再把 02 / 04 換成晶片身分 | 已決定（2026-11-23） |
| Q2 | 開發根私鑰放在 DSKT-MOONLIGHT；保管說明寫進 Batman-P | 已決定（2026-11-23）；補充：加密存放、與燒錄紀錄分開、備份到可移除媒體 |
| Q3 | **K20 的範圍**：晶片映像在任何情況下都不產生軟體身分。但把晶片節點**重燒卡**成任何檔案映像時，那個映像會產生軟體身分。驗證工具不這樣做；手動重燒卡則接受 | 待使用者確認 |
| Q4 | **三段式加入在第 1 期沒有當場證明**（`verify_offline`），第 2 期移除這條路 | 待使用者確認 |
| Q5 | **登入時間**：量測後把差異交給使用者決定（K15） | 量測後 |
| Q6 | 入庫計數器（U9）移到選量產晶片時，U9 的措辭到時一起確認 | 告知 |
| Q7 | **K13 的例外**：升級到 PR 3 那一版時，若試用失敗自動回退，已換成新版 app 的手機登不進回退後的節點；復原是在手機上裝回前一版 app（`adb install -r -d`）或重新 OTA。只影響 bench，只發生一次 | 待使用者確認 |
| Q8 | **bench 晶片節點**：需要一台 Pi 4 + HaLow 跑晶片映像。(a) 把 02 或 04 改成晶片節點（每次發行的檔案映像全套只剩一台檔案節點）；(b) 另備第三台 Pi 4 + HaLow。另外：實驗台若是 Pi 4，可以兼作 H1 / PR 2 的晶片節點（要換掉 Raspberry Pi OS、裝 A/B 卡），但沒有 HaLow 就跑不了 mesh 測項。決定時一併寫明：哪片 HAT 焊哪顆晶片、HaLow 模組是否要在 HAT 之間移動 | **H1 之前要決定** |

## 11. 尚未查證

今天的映像是否已含 `dtparam=i2c_arm`（E0b）；`/dev/i2c-1` 在晶片映像上的實際權限（E0b）；app 的 `es256_verify` 是否接受 high-s（PR 3 以向量確認）；app 在「重燒卡後同一個 `device_id` 變成未認領」這條路的畫面（PR 3）；`prov-legacy-upgrade-254`、`negctl-old-slot` 在晶片節點上的實際行為（H1）；晶片行為的所有 ⚠️（晶片設定 §11）。
