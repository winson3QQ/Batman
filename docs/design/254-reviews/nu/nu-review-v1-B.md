# 審查 B(安全優先,全文):`254-net-update-members.md` v1 DRAFT

審查對象:WSL `/home/yello/Batman-p3/docs/design/254-net-update-members.md`(111 行),Batman-p3 `feat/254-p3` @ e5c89a1。
方法:對照 `node/node.go`、`node/wtxn.go`、`cose/cose.go`、`provstore/provstore.go`、`provd/session.go`、`provd/helper.go`、`219-protocol.md` §5.3/§7、`219-protocol.cddl`、harness `scripts/dv/prov-*-254.sh`、`tests/tools/provclient/net.go`、app `batman-proto/src/joinflow.rs` / `join2flow.rs`。
探針:在 `/tmp/rvB` 複本(不是 repo)加一個測試檔,`GOCACHE=/tmp/rvB/gc go test ./node -run TestRvB` 跑。repo 沒有修改,也沒有碰任何裝置。

**結論:REJECT(1 BLOCKER、2 MAJOR、8 MINOR)。** 設計本身的方向是對的(每一步的 members 都綁 net_id、版本和 prev_hash,國碼也每一步都比)。但它說「轉送者換不掉任何一步」,然後讓 `parseNet` 保持原樣。`parseNet` 其實沒有把 secrets 綁到它要搭配的那一版 net_config。這正好擋住了這份設計存在的目的:移除成員之後換密碼。

---

## BLOCKER

### B1. net_secrets 沒有綁到同一版的 net_config:轉送者可以把舊版(或別的網路)的 secrets 接到新版設定上,讓節點留在被移除者知道的舊 SAE,但節點回報的是新版本

- **情境(移除成員 + 換密碼)**:v5 時 X、Y、R 都在網路裡。網主移除 R,發出 v6,新的 SAE 和 net_root 只加密給 X、Y。X 的轉送者可以是 X 主人的手機 session、X 上被攻陷的 provd,或分裂期間 R 的手機(R 那時還拿著 v5 的 `psk_member`,還能開成員 session)。它送 `{1:[{1: v6 net_config, 2: v6 members, 3: X 的 v5 net_secrets}]}`。網主組沒變時,X 的 v5 secrets 是 v5 的網主簽的,剛好等於 `adminsOfPrev`。X 接受這個請求:mesh_id 和頻道換成 v6 的,SAE 和 net_root 還是 v5 的,紀錄寫 `Version = 6`。結果:
  - app 看到 `net_version = 6`,以為換密碼完成了;
  - R 從公開的 v6 net_config 讀到 ssid 和頻道,再配上它知道的 v5 SAE,就能繼續和 X 組 mesh;
  - X 的 net_root 也是舊的,所以 R 舊的 `psk_member` 還能對 X 開 session(219 §6:節點試的是「目前版本的 psk_member」,它從儲存的 net_root 導出)。

  移除的目標(被移除的人拿不到新的 mesh 秘密,也進不了 mesh)因此達不到,而且 app 會顯示成功。
- **證據**:
  - `node.go` `parseNet`(約 :963–1020)只驗 secrets 的簽章(`openSecrets`)。
  - `wtxn.go:126-152` `decryptSecrets` 只比對 target_dac_hash。它從 **secrets 自己的** payload 讀 net_id 和版本,拿去當 KDF context,但從來不和 net_config 的 net_id / 版本比。
  - 探針(複本,`zz_rvb_test.go`)的結果:
    ```
    v2 cfg + v1 secrets -> code 0, wl=sae-v1-pass/m2/36, ver=2
    v3 cfg + other-net secrets -> code 0, wl=sae-other-net/m3/28
    ```
    第二行表示:同一位網主的金鑰在另一個網路簽給這台節點的 secrets,也接得上去(對同一網主跨網路的情況成立)。
  - 219 §7.3 說「轉送的人換不掉密碼欄位」。對密文內容來說這成立,但版本並沒有被綁住。設計 §5 說轉送者「換不掉任何一步(都要 admins 簽)」,這不成立:secrets 簽章合法,但它是另一版的。
- **補法(一行等級,符合「只做必要的修改」)**:在 `parseNet` 裡要求 secrets payload 的 key 1 = net_config 的 net_id,key 2 = net_config 的版本,否則回 `E_BAD_OBJECT "net_secrets"`。KDF 已經用 payload 的這兩個值,所以比 payload 就夠了。join 和 update 走同一個函式,一次補齊。
- **負向測試**:
  - U11:v2 net_config + v1 secrets → `E_BAD_OBJECT`,紀錄、`.txn`、setkey 呼叫次數都沒變;
  - U12:別的 net_id 的 secrets(同一網主、目標是這台節點)→ 拒絕;
  - mutant:拿掉這兩個比對 → U11 和 U12 都 PASS(也就是測試抓不到)。
- **另外**:§5 的「秘密:不新增」和「換不掉任何一步」都要改寫。

---

## MAJOR

### M1. 每一步都帶 members-sign1 之後,64 KB 的請求上限會讓落後的節點永遠追不上,設計沒有算過,也沒有恢復路徑
- **情境**:一台節點關機或離線一陣子,這段時間隊伍收了幾位新成員、移除了一位,每次都是新的一版。§7.5 要求帶從 v 到最新的每一版 members。成員清單只會變長:removed、used_invites、revoked 都是累加的。BLE 上 provd 最多 8 塊、重組後上限 65400 B(`provd/session.go:94-95, 547-548`),helper 上限 65536(`provd/helper.go:132-135`)。
- **估算**:一位成員約 290 B(dac hash 33、ecdh 66、owner 66、enc 66、lora 33、名字、map 頭),每一步的 net_config 加 Sign1 約 300 B 再加網主。所以一步約 300 + 290·M:M = 10 時最多約 20 步,M = 20 時約 10 步,M = 50 時約 4 步。超過就是「chunked request too large」,節點卡在舊版。換密碼之後,它也收不到新 SAE。F9 只寫了單一清單的大小,沒有算整條鏈。
- **為什麼是 MAJOR**:這是現場一定會遇到的路徑(分裂期間離線的節點),結果是節點被留在被移除者也知道的舊 SAE 上,只能靠擁有者 leave + 重新入網救回。設計沒有寫出這個上限,app 也不知道該提示什麼。
- **補法(擇一,由使用者決定)**:
  - (a)設計寫明支援的上限(N 位成員 × K 步),app 超過上限時改走「leave + 用新邀請重新入網」,並給 app 一個可辨識的錯誤;
  - (b)只有最後一步要求 members(節點不讀成員清單的語意,F3),中間步沿用 §2.3 的寬鬆規則。這會偏離 CDDL,需要使用者拍板。

  不管選哪個,都要加一個真實大小的測試(例如 20 位成員 × 12 步)驗證上限時的行為。

### M2. 生命週期矩陣的「降級 / A/B 回滾」那一列不對:wsl.24 的 update 會保留舊的 Members,升回 wsl.25 後嚴格的 prev_hash 會讓節點永遠拒絕 update
- **情境**:節點在 wsl.25 收過 update,存了 v6 的 members。之後 A/B 回滾或手動降級到 wsl.24,有人用舊形狀送了 v7(舊 provclient、舊 harness、Go 測試工具)。wsl.24 的 `applyNet` 做 `next := *rec`,Members 被原樣帶過去,還是 v6 的(`node.go` applyNet;wsl.24 的 `Encode` 照樣寫回 key 10,`provstore.go:90-95`)。再升回 wsl.25 時 `rec.Members != nil`,所以第一步要求 prev_hash = hash(M6)。但網主的 v8 members 指向的是 M7,於是每次都被拒絕,錯誤碼是 `E_BAD_OBJECT "member_list"`。app 看到這個碼沒辦法重新同步,節點只能 leave 再重新入網。
- **證據**:設計 §4 的降級列只檢查了「紀錄讀得到」(F10),沒有看「降級後的寫入」。
- **補法(一行)**:§2.3 的嚴格條件改成「`rec.Members != nil` **而且** 已存 members 的 key 2 = `rec.Net.Version`」,不符合就當作 nil(寬鬆)。寬鬆本來就論證過是安全的,而且攻擊者造不出這個狀態,因為寫 Members 的只有 helper。另外,members 的 prev_hash 不符應該回 `E_STALE_VERSION`(和 net_config 的 prev_hash 一致),讓 app 知道要重送鏈,而不是以為物件壞了。
- **負向測試**:U13:紀錄 Members.version = 6,但 Net.Version = 7,送 v8 → 0;mutant 拿掉版本比對 → U13 FAIL。

> M2 的嚴重度可以討論:觸發它需要一個舊形狀的發送者。但它正好是規則要求的生命週期路徑,而且設計對這一列的結論寫錯了,所以列 MAJOR。

---

## MINOR

1. **分叉(219 §7.5)沒有在「不做」裡寫明**。節點今天不實作「看到勝出的鏈就切換」。已經套用落敗那支的節點,從此每一版的 prev_hash 都對不上,永遠卡住。另外,同一個版本的兩支分叉,可以拿 A 支的 net_config 配 B 支的 members:兩者都是網主簽的,版本相同,members 和 net_config 之間除了版本沒有其他綁定。結果是存下錯的 Members,下一版嚴格比對時被卡住。只影響可用性,但要寫成已知限制,app 要能告警。
2. **移除共同網主沒有防護**:被移除的共同網主的金鑰在 v 版的 admins 裡,所以它可以在 v+1 搶先簽一份保留舊 SAE、保留自己的分叉,而且能替每台節點做 secrets,因為它知道每台的 ecdh_pub。§5 把這類情況歸成「被攻陷的共同網主,範圍不變」,但「移除一位共同網主」是正常的使用情境,不是攻陷。要寫進限制,並交給 app 設計處理。
3. **國碼比對的邊界沒有定義**:CDDL 規定 net_config key 5 必填,但 `parseNet` 不檢查。已存設定缺 key 5,或型別不是 2 字元的 tstr 時,`≠` 怎麼算?測試 rig 的 `mkNet` 根本不放 key 5(`wtxn_test.go:73-76`)。另外,這個國碼檢查加上「每一步都比」的意思是:網主 app 只要發出一版改國碼的設定,整個網路之後的每一版都會被所有節點拒絕,包括移除成員時的換密碼。要寫明 app 端的契約:絕不產生改國碼的版本(D9 的「整網改國家」在 checklist 上)。
4. **硬體負對照沒有判別力**:「同一套在 wsl.24 上 FAIL」失敗的原因是 wsl.24 不認得新形狀。它會在第一步 `VerifySign1` 對著一個 map 失敗,回 `E_BAD_OBJECT "chain link"`。這和 members、國碼、net_id 的檢查無關。可以說它驗證了「舊版拒絕新形狀」,但不要把它說成這些新檢查的負對照。新檢查的負對照只有 Go mutant,要照實寫。
5. **harness 怎麼拿到上一版的 members 沒有寫**:provclient `--update` 今天只吃 prev NETCFG(`net.go:237-251`)。第二次成功 update 時,嚴格比對需要上一版 members 的 OBJECT_HASH,所以 provclient 要多印一行 `MEMBERS <hex>`,harness 要把它傳下去。`prov-country-join` 的 W 臂在 P 也可能是第二次 update。
6. **未知 key 的處理不一致**:設計對 members 的未知 key 拒絕(§7.1),但 net_config 的未知 key 今天不拒絕;中間步的 net_config 也不經過 `parseNet` 驗證,`adminsOf` 不檢查 65 B 和 ≤ 4。至少要寫明這是刻意的不對稱,並列進 checklist。
7. **錯誤碼表不完整**:U5 的「最後一步缺 secrets」「缺 members」要回什麼碼沒寫。要給一張「條件 → 錯誤碼 → app 該做什麼」的表,這是 app 的契約。
8. **已存的 Members 只代表「網主簽過的第 N 版」**:寬鬆的第一步意味著它不是一路驗到 v1 的鏈。要在 §3 寫明,免得以後有讀者(例如 team status 或 peers 用成員清單)把它當成已驗證的鏈。

---

## 已查證屬實的部分
- F1、F2、F3、F5、F6、F8 與原始碼相符,行號差 ±1–2:`netUpdate` 在 `node.go:1072`、`adminsOf` 在 `:1104`、`parseNet` 的呼叫在 `:1108`、`return n.netUpdate` 在 `:757`、leave 清 nil 在 `:1206`、`EReject` 在 `:53`、`hEReject` 在 `helper.go:26`。
- `ReasonCountryJoin` 只在 `settingsset.go:21,123` 出現。
- `CTMembers` 和 `LabelMembers` 已經存在(`cose.go:22`、`proto.go:31`)。
- prov.cbor 和 prov.meta 的權限是 0600(`provstore.go:400,403`)。
- OBJECT_HASH 不含簽章,所以把 s 換成 n−s 或塞 unprotected 欄位都弄不斷鏈;low-s 在 `proto.go:116` 檢查。
- 跨步驟交換 members 被「版本 = 該步 net_config 版本」加上 prev_hash 擋住。
- 重送舊鏈被版本必須連續擋住。
- 被移除的節點本身拿不到新 secrets,因為 target_dac_hash 對不上(`wtxn.go:130`)。前提是修掉 B1 之後,它也不能拿自己的舊 secrets 接到新設定上(不過那樣它拿到的也只是自己本來就知道的舊 SAE)。
- 本機非特權程序:helper socket 是既有的 SO_PEERCRED,沒有新增攻擊面。
- 秘密:members 不含秘密,錯誤字串不含秘密。

## 判定
**REJECT**,修掉 B1、M1、M2 後重審整份文件。B1 修完之後,§5 的論述要重寫:「信任來自網主簽章」不夠,還要「每一個物件都綁到同一個 (net_id, version)」。
