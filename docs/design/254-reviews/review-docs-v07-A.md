# #254 §10 第 2 項 docs PR 審查 — 審查者 A — 協定 v0.7 + CDDL + 向量 + 219-field-provisioning v2.9(`docs/254-protocol-v07` baf1a21)

**Verdict:REJECT(窄)— 0 BLOCKER / 3 MAJOR / 8 MINOR**

先講結論:
- owner-op、`psk_replay`、`claim/replay`、首版 join 的**密碼學設計本身是對的**;
- 簽章輸入沒有歧義;
- 向量逐位元組可重現,並且能抓到我做的竄改。

三個 MAJOR 都是「搬運不完整或互相矛盾」,會讓節點(Go)與 app(Rust)的實作者照文件寫出不一致或不安全的東西:
1. **D1**:helper 的 `args_hash` 契約與協定不一致,而且 helper 動詞拿到的是拆好的欄位,不是整個 body,§5.7 宣稱的保護落不了地;
2. **D2**:協定裡完全沒有 `legacy` 狀態;
3. **D3**:§3.5 說「每個改變節點的請求都要 owner-op」,但 `update/*`、`bulk/*` 在 CDDL 裡不用帶。

範圍:
- `git diff 8682f57 baf1a21` 全部;
- 對照 `254-stage1-impl.md` v19 的 §1.3、§1.4、§4.1、§4.2、§4.5、§4.8、§6.1、§8;
- 以 `/home/yello/venv-219/bin/python` 實跑 gen / verify,另做竄改與 pycddl 探測。

只在 WSL 唯讀操作,除了本報告沒有寫任何東西。

---

## 0. 實跑結果

```
verify.py vectors.json            → 156 checks: ALL PASSED
gen.py > tmp; cmp tmp vectors.json → BYTE-IDENTICAL
竄改(每次只改一個欄位,重跑 verify):
  owner_op.args_hash       → rc=1 FAIL "args_hash = SHA-256(body without key 31)"
  owner_op.nonce_helper    → rc=1 3 FAIL(input rebuilt / signature …)
  psk_replay.psk_replay    → rc=1 2 FAIL(HKDF;NXpsk0 replay msg1)
  claim_replay.response    → rc=1 2 FAIL
  claim_replay.client_chal → rc=1 1 FAIL
  identity_file.sn         → rc=1 3 FAIL
  claim_replay.owner_op_input → rc=0 0 FAIL   ← 沒有被檢查(m7)
  claim_replay.owner_op_sig   → rc=0 0 FAIL   ← 沒有被檢查(m7)
pycddl 探測(verify.py 同一份寬鬆 CDDL):
  bulk-open-resp 接受整數 2            → True   ← m1
  owner-op 多一個 key 3                → 被拒 ✅
  update/apply、bulk/open 不帶 owner-op → 接受   ← D3
cbor2.dumps({24:0,-1:0}, canonical=True) = a2 20 00 18 18 00   ← 長度優先(RFC 7049),不是 RFC 8949 位元組序(m7)
```

---

## 1. 判斷 (1):是否忠實且完整搬運 v19

| v19 | v0.7 | 判定 |
|---|---|---|
| §1.3 owner-op 新標籤 | §3.6、§5.7 | ✅ |
| §1.3 首版需 owner-op `network/join` | §7.1 | ✅ |
| §1.3 helper 自己重算 ClientChal | §5.4 | ✅ |
| §1.3 `device_id = hex(sn)`、adv 帶末 4 字元 | §3.3 | ✅ |
| §1.3 `psk_replay`、固定試 6 次、replay session 只允許 `claim/replay` | §3.4、§3.5、§6 | ✅(v0.7 多放行 `info`、`claim/begin`、`op/nonce`,都是 `claim/replay` 需要的) |
| §1.3 節點 Go / app Rust | §10 | ✅ |
| §1.3 自簽 `dev:`、TOFU、release 拒絕 | §3.3、§9 | ✅;但 app 端該做的檢查少一條(m4) |
| §1.3 `reset` → `E_UNSUPPORTED`、`E_VERSION` 逃生口 | §5.1、§5.3、CDDL reason 9 | ✅;CDDL 留下殘行(m1) |
| §4.1 helper 動詞的授權 | §5.7 | ❌ `args_hash` 的定義與 helper 介面矛盾(D1) |
| §4.1 / §6.1 legacy 認領、`E_UNSUPPORTED(no-ssh-key)` | 沒有 | ❌ D2 |
| §4.1 app 契約(先持久化 `node_cert` 與 claim-pending) | §5.4 | ✅ |
| §4.1 `claim.replay` 每次開機每小時 10 次;`nonce(h)` 不需授權 | §8 沒有 | ⚠️ m5 |
| §4.5 轉賣 = 重燒卡 | field-provisioning v2.9 §7 | ✅;§6.1 / §6.8 有殘留(m8) |
| §4.8 單則 ≤ 8 KiB、同時連線 ≤ 2、`status/public`(含 `updating=1`) | 協定仍是 1 MB;CTRL 只有 `{major, minor, max_frame}` | ⚠️ m5 |

**v0.7 超出 v19 的部分。** 整體成立;D1 那一條例外,要回頭修 v19。
- **`op/nonce` 訊息**:合理。v19 有 helper `nonce(h)`,協定總得有一個取 nonce 的訊息。缺上限,見 m5。
- **key 31**:合理。body key 從 1 起編、0–15 保留給信封;31 不會撞到現有欄位。
- **`u8(len(verb))`**:讓簽章輸入沒有歧義。標籤之後的 h(32)、nonce(32) 定長,verb 有長度前綴,args_hash(32) 定長;和其他擁有者簽章的標籤(`-auth-v1`、`-enc-v1`)在「batman-owner-」之後的第一個位元組就不同,不會跨用途。✅
- **每次驗證嘗試都消耗 nonce**:擋掉「同一個 nonce 拿來試多把金鑰或多種 body」。但它和 HTTP 冪等重送的先後順序沒寫(m2)。
- **`psk_replay` 只在恰好一位擁有者時存在**:合理。v19 的 `claim.replay` 本來就要求「擁有者 1 位」;2–4 位擁有者時以假 PSK 補位,固定 6 次的時間特徵不變(4 個 owner + 1 member + 1 replay = 6)。✅

---

## 2. 發現

### D1(MAJOR)`args_hash` 在 v19 helper 契約裡有兩種定義;helper 動詞拿到的是欄位而不是 body,§5.7「增減欄位必被拒」無從實作

- **v19 自己前後矛盾**:
  - `254-stage1-impl.md:168`(本 PR 沒改的那列)`net.apply(net_config, net_secrets[, owner_op])` 寫 `args_hash = H(net_config ‖ net_secrets)`;
  - 本 PR 改的 `:169`(與協定 §5.7)寫 `args_hash = SHA-256(deterministic CBOR(請求 body 去掉 key 31))`。
- **為什麼這是安全問題**:helper 的動詞簽名是 `net.apply(net_config, net_secrets, owner_op)`、`ssh_keys.set(list, owner_op)`、`claim.replay(h, client_resp, owner_pub, owner_op)`,都是**由 provd 拆好的欄位**。
  - helper 要算「整個 body」的雜湊,只能自己重組 body。app 若帶了任何額外 key(§5.1 允許、CDDL `* uint => any`),或 `network/join` 帶了 `member_list`(key 2)、`invite_id`(key 4),helper 重組不出來 → 互通失敗。
  - 反過來,如果 helper 照 `:168` 只雜湊 `net_config ‖ net_secrets`,被攻陷的 provd 就能**在擁有者簽章之後換掉 `member_list` / `invite_id`**,這正是 §5.7 第 4 點宣稱擋得住的事。
- **修法**:
  1. helper 授權動詞改收**請求 body 的原始 CBOR**;
  2. helper 自己解碼,拒絕重複 key、indefinite-length、非 deterministic 編碼;
  3. 去掉 31、以 RFC 8949 §4.2.1 重新編碼、雜湊、驗 owner-op;
  4. **只從這個解碼後的物件取欄位**去執行;
  5. 修 `:168`;
  6. 負測試:provd 送給 helper 的 body 與 app 簽的差一個 `member_list` 項 → `E_FORBIDDEN`。

### D2(MAJOR)協定裡沒有 `legacy` 狀態

- **v19 的設定**:legacy(既有 fleet 升級後)可以認領(§1.4「開(防呆門)」);防呆門不過時回 `E_UNSUPPORTED(no-ssh-key)`(§6.1);adv 帶末 4 字元。
- **協定 v0.7 只在 §3.3 提到 legacy 的 adv**:
  - CDDL `node-state` 只有 `0 unclaimed / 1 claimed / 2 member`(`219-protocol.cddl:158-160`);
  - §3.1 的模式表、§3.5 的角色表只有「未認領 → NX / 匿名」;
  - `reason-code` 沒有 no-ssh-key。
- **後果**:legacy 節點在 `info.state` 回什麼、接受 NX 還是 NXpsk0、app 收到 `E_UNSUPPORTED` 時用哪個 reason 顯示「先裝 SSH key」,兩邊實作者只能各自猜。若 app 把 legacy 當 claimed 而走 NXpsk0,就認領不了。
- **修法**:
  - `node-state` 加 `3 = legacy`;
  - §3.1:legacy 跟未認領一樣用 `NX`、匿名角色,`claim/*` 開放;
  - `reason-code` 加 `10 = legacy claim needs an SSH key or dev-open`;
  - 向量補 `info` legacy 與錯誤回應。

### D3(MAJOR)§3.5 說「每個改變節點的請求都要 owner-op」,但 `update/prepare`、`update/apply`、`bulk/open`、`bulk/close` 不用帶

- §3.5 第 3 點:「擁有者角色本身不足以改變節點:每個改變節點的請求另外帶 owner-op」。
- 但 §5.3 的 owner-op 清單與 CDDL 沒有 `update/prepare`、`update/apply`(寫 slot、重開)和 `bulk/open`(開一個 Wi-Fi AP 並給出 PSK)。pycddl 確認,這幾個不帶 key 31 也會被接受。
- v19 階段 1 的 helper 沒有這些動詞,所以今天不會出事。但協定是規範,之後(S5 軟體更新)照 §5.3 實作的人只會檢查角色 → 被攻陷的協定行程就能觸發更新或開 AP。
- **修法(二選一)**:
  - 這四個也列入 owner-op,CDDL 必填 31;
  - 或在 §5.3 標「階段 1 不實作;實作時 MUST 帶 owner-op」,CDDL 先改成 `op-only-req`。

### m1(MINOR)CDDL 的 reset 殘行讓 `bulk-open-resp` 多接受整數 2

- 刪除 `reset-req` / `reset-level` 時,`/ 2 ; zeroize …` 那一行沒刪(`219-protocol.cddl:295`)。CDDL 跨行延續,它接在 `bulk-open-resp = {…}` 後面,變成 `bulk-open-resp = {…} / 2`;pycddl 實測接受整數 2。
- 同檔 `network-join-req` 的註解寫「required for the first version」,但規則是一律必填(§5.3 也是一律)。改註解。

### m2(MINOR)§4.2 的冪等清單沒跟上 v0.7

- **還列著 `reset`**(已經一律不支援)。
- **列著 `claim/finish`**:「節點保留結果 10 分鐘、跨 session 有效」= 把 `owner_tag_key`、`root_password` 快取在 provd 記憶體。這和 v19 §6.1 第 5 步「不快取(回應遺失走 `claim/replay`)」矛盾。
- **沒列新的改狀態動詞**:`claim/replay`、`ssh_keys/set`、`root_password/reset`。向量裡 `claim/replay` 的請求其實帶了 `7: idem_key`。
- **沒寫和一次性 `nonce_helper` 的先後順序**:必須先查冪等快取、再驗 owner-op;否則重送會因 nonce 已消耗而回 `E_FORBIDDEN`,而操作其實已經做了。
- **修法**:更新清單;`claim/finish` 從清單拿掉(依 v19);寫明先查冪等再驗證。

### m3(MINOR)replay 角色裡 `claim/begin` 的 `owner_pub` 語意未定

- CDDL `claim-begin-req` 必帶 `owner_pub`;但在 replay session,ClientChal 用的是**已存的**那把。
- 寫明:replay session 的 `claim/begin` 若 `owner_pub` ≠ 已存 → `E_FORBIDDEN`。v19 helper 的 `claim.replay(…, owner_pub, …)` 也是要求相等。

### m4(MINOR)開發版 TOFU:app 必須驗 `device_id` 是 dac_pub 的承諾

- §3.3 的驗證步驟 3 只要求「`sn` 與憑證欄位一致」。自簽憑證的 CN / serialNumber 是任何人都能填的。
- 對 file 後端,app 在 pin 之前要多驗一條:`device_id == hex(SHA-256(dac_pub)[:9])`。少了這條,看過 QR 的人可以用自己的金鑰做一張同 CN 的自簽憑證冒充;多了這條,冒充需要 72-bit 的第二原像。
- 修法:§3.3 加為 MUST;向量加一個負案例:攻擊者金鑰 + 受害者 CN/serialNumber → 規則不成立。

### m5(MINOR)v19 的上限與 `status/public` 沒有寫進協定

- v19 §4.8 / §8:單則 ≤ 8 KiB(經 `CTRL/info` 回報)、同時連線 ≤ 2、未交握 10 s、`status/public` 帶 `updating=1`;協定 §8 仍是單則 1 MB,`CTRL` 沒有最大訊息欄位,也沒有 `status/public`。
- v19 §4.1:`claim.replay` 每次開機每小時 10 次。協定 §8 沒有。
- `op/nonce` / `nonce(h)` 沒有上限:被攻陷的 provd 可以讓 root 的 helper 無限累積 60 秒的 nonce(記憶體 DoS)。建議每個 h 未用 nonce ≤ 2、全域 ≤ 16。

### m6(MINOR)沒有網路時收到 `network/update` 怎麼辦沒寫

- §7.1 說首版只經 `network/join` + owner-op。也要寫明:節點沒有任何版本時,`network/update`(成員轉送)一律拒絕(`E_STALE_VERSION`),不得把它當首版。
- v19 helper 以「`prov.cbor.net` 為空」判斷,行為正確,但協定文字要對齊。

### m7(MINOR)向量 / 工具

- `gen.py` 的 `cb()` 與 `verify.py` 的 `args_hash` 都用 `cbor2 canonical=True`,這是 RFC 7049 的「長度優先」排序,不是協定規定的 RFC 8949 §4.2.1 位元組序。實測 `{24:0, -1:0}` → `a2 20 00 18 18 00`(位元組序應是 `a2 18 18 00 20 00`)。
  - 目前沒出錯:body 的 key 只有 uint,巢狀 COSE map 的 key 都是 1 位元組,兩種排序結果相同;
  - 但只要 body 出現 key ≥ 24 又夾著負數或字串 key,Go 的 core-deterministic 與向量工具就會算出不同的 `args_hash`;
  - `verify.deterministic()` 同時要求兩種排序都相符,遇到這種物件會一律判 false。
  - 修法:改用自訂的位元組序編碼,並加一個會分辨兩種排序的向量。
- `claim_replay.owner_op_input`、`owner_op_sig` 兩個已發布的欄位,verify 從沒檢查(竄改後仍 156 PASS)。實作者會拿它們比對,應該加檢查。
- 負向檢查都是「verify 自己組一個錯的輸入、確認簽章不過」,證明的是規格公式,不是實作。這是向量的本質,沒問題;但 §11 的說法要對應:真正的鑑別要在 PR-H1 的對手實作裡做(例如 helper 收到被改過的 body)。

### m8(MINOR)219-field-provisioning v2.9 殘留舊文字

- **§6.1 步驟 4**:仍寫「app 回 `HMAC(認領秘密, c)`」。協定從 v0.2 起是 CheckMac 格式(§5.4),應改成引用。
- **§6.1「新機被搶先認領 … 擁有者按鍵後以 QR 重新認領即可取回」**、**§6.8 舊手機沒了「新手機掃 QR + 按鍵 → 替換擁有者」**:階段 1 沒有按鍵與窗口(§6.1 自己的 v2.9 小註),已認領的節點只接受 `claim/replay`(v19 §1.4);遺失手機的唯一出口是重燒卡(v19 L59)。兩處都要加「階段 1:重燒卡;#255」的註記。
- **§10 B5**(dropbear 是否支援 ECDSA):v19 F1 已有答案(沒有 ECDSA,用 ed25519),應改成已決。

---

## 3. 判斷 (2):協定層安全

逐一攻擊,結論:**除了 D1(實作契約)與 D3(未來動詞)之外,沒有找到可以濫用的路徑。**

| 角色 | 嘗試 | 結果 |
|---|---|---|
| 轉送者(BLE / HTTP) | 改 / 重放 owner-op | Noise 端到端加密;owner-op 綁 `h` 與一次性 nonce → 跨 session、跨節點都不能重用 |
| 被攻陷的協定行程(provd) | 換 verb / 換 body / 重放 | verb 在簽章內;`args_hash` 涵蓋整個 body(**前提是 D1 修好**);nonce 一次性 |
| 被攻陷的協定行程 | 換擁有者 | `claim.verify` 由 helper 自己重算 ClientChal(以即將寫入的 `owner_pub`)✅ |
| 被攻陷的協定行程 | 用 `claim/replay` | 需要擁有者簽章 ✅ |
| 被攻陷的協定行程 | 塞首版網路 | 需要 owner-op ✅ |
| 被攻陷的協定行程 | 看到明文 | v19 已列為誠實界線 |
| 路人 | 探測已認領的節點 | 固定 6 次 + 假第 2 則;`psk_replay` 需要擁有者加密私鑰 ✅ |
| 前任擁有者(重燒之後) | 任何事 | 新 ECDH 金鑰、新 `device_id` → `psk_replay` 和舊 owner-op 全部失效 ✅ |
| 前任擁有者(被 `owner/remove` 之後) | 用 `psk_replay` | `psk_replay` 改由剩下那位唯一擁有者的加密金鑰導出 ✅ |
| 只有 QR 的人 | 用 `claim/replay` | 沒有 `psk_replay` session,也沒有 owner-op ✅ |
| 開發版 TOFU | 冒充節點 | 見 m4(只影響開發機) |
| 簽章輸入歧義 | | 無:定長欄位 + verb 長度前綴 + 不同標籤 ✅ |
| CDDL 與內文不一致 | | m1(殘行)、D3(缺 owner-op);`owner-op` 本身拒絕未知 key ✅ |

## 4. 判斷 (3):向量的鑑別力

- 可逐位元組重現 ✅;
- 竄改 6 個主要欄位都被抓到 ✅;
- 兩個欄位沒被檢查(m7);
- canonical 排序與規格不同(m7,目前不影響結果)。
