# 審查 B 第 6 輪(聚焦):§13 實證結果、§13.1 的鏈 0 / 鏈 1 修正,以及 P1 程式碼抽查

審查者 B。範圍:
- 設計 §13、§13.1;
- `feat/254-p1`(WSL `/home/yello/Batman-p1`,HEAD 58dbb7b)的下列檔案:
  - `boot/boot.go`
  - `node/node.go`
  - `node/txn.go`
  - `cmd/batman-provhelper/main.go`
  - 96、`batman-config-save`、`batman-slot`、`batman-autocommit`、`platform-ab.sh`、99zz、`prov-lock.sh`

只讀原始碼與文件;沒有連節點做任何寫入,也沒有印出秘密。

**判定:REJECT(只針對 §13.1 與程式碼)**:1 BLOCKER / 4 MAJOR / 5 MINOR。

§13 的實證結果本身可信:E3 10/10、E6、02 p3 都成立。但有兩個問題:
- §13.1 的新做法違反上層的 trial 規則,而且它的前提會被 A 的 joinwatch 破壞。
- 抽查程式碼後發現,P-U6 的「凍住」只在 `--boot` 與 `--persist-now` 生效,其他寫入 p5 的路徑不受它管。另外 L44(unclaimed 不擋)在真正的 sysupgrade stage 2 不成立。

我沒找到會讓 04 卡死的路徑:A 一直保有 fleet 設定與 lab key;B 的 trial 會因 openmanetd 重開或到期而回到 A。

---

## BLOCKER

### B1. §13.1 第 1 步「在 fresh trial 的時間窗內完成認領」照程式碼一定回 `E_BUSY`;若為了這個改掉,會違反上層 §4.1 / L21
- **證據**:
  - `node.go:155-160`:`stateChanging` 包含 `claim.verify`,而且 `if stateChanging[verb] && n.Sys.IsTrial() { return E_BUSY }`。
  - 上層 §4.1:「trial 槽:改狀態動詞 `E_BUSY(updating)`」。
  - 設計自己的 `prov-trial-busy-254`(L21)測的就是這一點。
- **後果**:這一步做不出來。如果實作時為了讓鏈 1 跑得通,去放寬 trial 檢查,那就是為了測試改掉產品的安全規則(trial 中的認領會在 revert 後留在 p5,而槽卻回到舊版)。
- **修法**(兩個方向擇一):
  - (a)回到「commit fresh 槽之後再認領」,改用 §13.1 已實證的 mDNS 找節點。前提是先補一個實證 **E1c**:fresh 槽被 openmanetd 重開、換到保留位址之後,`<hostname>.local` 解析得到而且 `none` 可以登入(⚠️ 目前未證:fresh 槽的 hostname 由 `99-halow-identity` 重設)。B 被 commit 之後不是 trial,所以可以認領;它的 mesh 被 keyguard 關著,joinwatch 不會 `--on-join`,p5 會保持「claimed + placeholder」。接著從 B 以 `sysupgrade -n` 寫 A(hold)→ 斷言 `HELD`(要在約 168 s 之內;E3 實測開機到 HELD 是 92–105 s)。
  - (b)把 (2) 拆成兩部分:沙箱 / 單元測 helper 的 `writeProvState`(claimed + placeholder → `0`);真機以 autocommit 的 DRYRUN / FORCE_TRIAL 接縫,配合 tmpfs 上 bind mount 的 `prov-state`,測決策那一段。並明列「沒有真機端到端」。

---

## MAJOR

### M1. §13.1 第 2–3 步的前提會被 A 的 joinwatch 破壞 → (2) 變成假的 PASS
- **情境**:fresh trial 回到 A 之後,A 開機,joinwatch 在 S98 啟動,A 在 fleet mesh 上 → 第一個 JOINED tick 就跑 `--on-join`。程式碼上 `--on-join` 不看 helper 的 identity-mismatch(只看 txn,`config-save` `txn_live`),於是把 **A 的 fleet overrides、A 的 host key 與 `authorized_keys`、`.seeded`** 寫進 p5。p5 變成:prov 是 claimed Y,overrides 是 fleet 的實際 key。
  - 之後「從 A 以 `ALLOW_STALE_P5` 寫 B」,B 的 trial 是 **claimed + live key** → 依今天的規則需要鄰居 → 入網 → `HELD`。
  - 測項 PASS 了,但原因不是「claimed + placeholder → 不需鄰居」→ 沒有鑑別力。
- **證據**:`joinwatch:145`、`batman-config-save` 的 `--on-join` 路徑(prov 不在 fp 內,依上層 §4.3)。
- **修法**:採用 B1(a)(A 不參與);或者在第 3 步之前斷言 p5 的 overrides 裡 mesh key 仍是 placeholder(不是 → 測項作廢,不算 PASS)。另外見 M2:identity-mismatch 期間,這種寫入本身就不應該發生。

### M2. P-U6 的「凍住」在程式碼裡只管到 `--boot` 與 `--persist-now`;動詞與 config-save 的寫入模式都不受它管
- **證據**:
  - `boot.go:101-103` 遇到不一致時不寫任何東西 ✅;`main.go:347` `--persist-now` 會拒絕 ✅。
  - 但 `node.go:157-166` 的 `dispatch` 只檢查 trial 與 overlay record,**不看這次開機的 verdict**。凍住的 A 上:
    - `claim.verify`(overlay 是 legacy X)→ `commitTxn` → `--prov-only` 把「X 的 claimed 紀錄」寫進 p5;
    - 而 p5 的 `identity/prov` 是一次寫入,仍是 Y(`config-save --prov-only`:只在 p5 沒有完整身分時才寫身分,紀錄則一律寫入,也不檢查紀錄屬於哪個身分)。
    - 結果正好是 §4.8 要防的「X 的擁有權 + Y 的身分」混合狀態。
  - `net.apply`、`owner.*`、`ssh_keys.set` 也一樣。P1 沒有 provd,但 P2 上線後經 BLE 就打得到。
  - `--on-join / --save / --if-healthy` 在凍住期間照樣把這一槽的 overrides、host key、`.seeded` 寫進一份屬於另一個身分的 p5(M1 的機制)。
- **修法**:
  - helper:`boot.Run` 的 verdict 存起來;verdict 是 `unknown(*)`(至少 identity-mismatch、identity-lost、txn-generation)時,所有改狀態動詞回 `E_STATE`(不是 `E_BUSY`)。`prov-unit-auth` 加一列 mutant。
  - `config-save --prov-only` 再加一層防線:p5 已有完整身分時,要求呼叫者以 `--prov-identity` 傳入同一份身分的 sha 清單,不符就 rc 1。
  - `--on-join / --save` 遇到 overlay 與 p5 身分不一致(和 `prov_compare` 同一個判斷)→ 不寫,rc 1,記 log。
  - 沙箱案例:凍住的節點上,`claim.verify`、`--on-join` 都不得改動 p5。

### M3. `boot.go` 的 rc 13 分支會用 overlay 的紀錄蓋掉 p5 的紀錄,而且不比身分;上層對 rc 13 的規定是只補身分
- **證據**:
  - `boot.go:240-250`:`ovIdent` → `persistAll(true)` = `--prov-only --prov-file <overlay record> --prov-identity <overlay identity>`。
  - p5 的身分不完整,所以 identity-first 的比對(`:101`)不會觸發(`p5Ident=false`);`--prov-only` 會先 `rm -rf identity/prov`,再寫 overlay 的身分,**也寫 overlay 的紀錄**。
  - 上層 §4.2 的 rc 13 列:「overlay identity 完整 → 補 persist identity」(不含紀錄)。
- **情境**:p5 的 `identity/prov/` 有一個檔壞掉(SD 位元錯誤、寫入中斷),但 `prov.cbor` 是 claimed(gen 5)。這時開進一個 overlay 是舊的 legacy(gen 1)的槽,p5 就被降成 legacy、換成這一槽的身分。沒有 owner-op,就在無聲無息中失去擁有權;下次 fresh 開機的上鎖判斷也跟著變。
- **修法**:rc 13 只在下列條件都成立時補身分:p5 殘存的 `sn` 等於 overlay 的 `sn`,而且 `ovRec.Generation ≥ p5Rec.Generation`。否則判 `unknown(identity-lost)`,不寫。`prov-unit-helper` 加這兩個 mutant。

### M4. L44(unclaimed 不擋)在 sysupgrade stage 2 不成立:ramfs 裡沒有 `prov-lock.sh`
- **證據**:
  - 新的閘例外是這樣判斷的:`[ -r /usr/lib/batman/prov-lock.sh ] && ( . …; prov_meta_status … = "ok unclaimed" )`(`batman-slot` 的 diff)。
  - `platform-ab.sh:37-39` 的 `RAMFS_COPY_DATA` 只有 `firmware-allowlist`、`otatrace.sh`、`bootfacts.sh`、`rundir.sh`,沒有 `prov-lock.sh`。
  - stage 2 在 ramfs 裡呼叫 `batman-slot stage-root` / `apply`(`platform-ab.sh:363,376`),而它們都會再跑一次 `node_checks`。
- **後果**:unclaimed 新卡的 `sysupgrade -n`:stage 1 放行 → services 被停 → stage 2 判「not seeded」→ die → 什麼都沒寫,重開。這是 fail-closed,不會失聯,但上層 L44 在真正的 OTA 路徑上做不到。
  - 鏈 1 第 6 步只用 `precheck-node`(stage 1)判讀,所以**測不出這個 bug**。
- **修法**:把 `/usr/lib/batman/prov-lock.sh` 加進 `RAMFS_COPY_DATA`。鏈 1 或沙箱另加「真的 `sysupgrade -n`,unclaimed 未 seed 的 p5 → 槽確實被寫入」的斷言;負對照是拿掉 `RAMFS_COPY_DATA` 那一項 → stage 2 die。

---

## MINOR

- **m1 `IsTrial()` 在無法判定時放行**:`main.go:108` 只把 rc 0 當成 trial,而 `batman-slot is-trial` 遇到內部錯誤時回 rc 2(unknown,`batman-slot:38-39` 的 DIE_RC)→ 改狀態動詞被放行。應該把 rc ≠ 1 都當成 trial(fail-closed)。health 的 `Committed` 已經是以 rc == 1 判斷 ✅。
- **m2 兩個寫 `prov-state` 的地方,mesh_expect 判法不一致**:helper 的 `--apply-state --firstboot`(`main.go:286-292`)對 claimed 一律寫 `today`,不看 placeholder;99zz 的 shell 版與 `boot.writeProvState` 都會看。autocommit 只等 writer=99zz 最多 60 s,helper 晚到就用 `today` → 需要鄰居 → revert(fail-closed,但 (2) 會因此不穩定)。三處改成同一套判斷。
- **m3 `--check` 漏掉「p5 沒有身分」的情況**:`prov_compare` 在 overlay 有身分而 p5 的 `identity/prov/sha256` 不存在時,略過身分比對,只比 meta。meta 相同就放行 OTA,而 fresh 槽之後會是 `unknown(identity-lost)`。應該加一個 `p5 stale: prov-identity-missing`。
- **m4 S0 與現況不符**:§13 說兩台現在都是 wsl.10、committed 在 **slot B**,S0 卻要求 committed = A。04 會自動跨槽重建;02 依 §4.5.0 不會自動處理,要交給人。請在下一次 prov tier B 之前寫明怎麼回到 S0(例如兩台各做一次一般的 OTA 回 A),或者把 S0 改成「committed 槽 = 記錄下來的那一槽」。
- **m5 「fresh 槽約 168 s 後自己重開 = openmanetd #11」只是推論**:boot-reasons 只寫了「reboot command」。鏈 0 / 鏈 1 的時間窗都依賴它。E1c 一併以 `logread` / openmanetd 的 log 確認是誰下的重開,以及第二次開機的位址是怎麼決定的。

---

## 確認成立(✅)
- `boot.go`:
  - identity 的比對在 txn 與 gen 之前(`:100-103`),不一致時不寫任何東西;
  - txn 的「已提交 / 未提交 / 不明」三分正確,不明時留給操作員;
  - rc 0 / 7 / 9 / 10 / 1 / 8 / 3 / 11 / 12 / 14 與上層的表一致;
  - `last_known_state` 只在紀錄確定時更新;unknown 時保留前一次的值,96 因此依舊能上鎖。
- `claimVerify`:
  - 只允許 legacy / unclaimed;
  - 以自己的 `nonce_node`、自己的 DAC 重算 `ClientChal`;
  - 防呆門在 CheckMac 通過之後才判;
  - 先 commit,再上鎖,再 `--save`;
  - 回應裡的密碼不寫進 log。
- `txn.go`:`--prov-only` 的 rc ≠ 0 時讀回 gen 決定成敗,然後才寫 overlay。
- 96:
  - 每個出口都經過 `finish96`;
  - lib 缺少時有 fail-secure 的替代規則;
  - prov 的抄寫在 `.seeded` 檢查之前;
  - bypass 依 p6 的 `last_known_state` 上鎖。
- `--check`:prov / identity 的比對在 rc 7 之前 ✅。
- 閘:只放行 `ok unclaimed`(stage 1)✅;stage 2 的問題見 M4。
- autocommit:
  - 讀 `prov-state` 時比對 boot_id;
  - writer=99zz 時等待;
  - member 要求 radio up;
  - `ota-armed.mesh` 綁 arm 那次的 boot_id 與槽;
  - `ble-ok` 只記 WARN(P-U5)。
- 04 不會失聯:§13.1 的任何一步,A 都保有 fleet 設定與 lab key;B 的 trial 會被 openmanetd 重開或到期 revert,回到 A。

## 判定
**REJECT**(1 BLOCKER / 4 MAJOR / 5 MINOR)。
- §13.1 的鏈 1 第 7 步要換做法(B1 的 (a) 或 (b))。
- 程式碼要補三件事:凍住期間不得寫 p5(M2)、rc 13 不得蓋掉紀錄(M3)、ramfs 要帶上 `prov-lock.sh`(M4)。

修完後,這三個程式碼問題各自要有 mutant 或負對照。
