# 測試手機設定(H4 手機載具)

`docs/design/254-h4-harness.md` §4.3 的手機:一支留在實驗室的 Android 手機(實測用 Samsung S20),只跑 Termux 的
`sshd` 與 `tests/tools/peer/httprelay.py`(只用 Python 標準庫)。判定不依賴手機;它只是「連在節點熱點上的裝置」。

存取細節(手機的 IP、Termux 使用者名稱、host key 指紋)不放在這裡,放在私有的運維 repo。

## A. 事前設定(在家即可)

### 1. 安裝
- 從 **F-Droid** 安裝 **Termux** 與 **Termux:Boot**。兩個要同一個來源,混用 Google Play 版會無法搭配。
- 裝完後**手動打開 Termux:Boot 一次**:Android 規定 app 要先被打開過,開機自動啟動才會生效。

### 2. 在 Termux 裡執行(一次一段)

```
pkg update -y && pkg install -y openssh python
```

放進主機專用的公鑰。公鑰由 `phone-254.sh keygen` 產生並印出(私鑰只在 WSL 的 `~/.ssh/batman_phone_ed25519`);
前面的 `no-...` 限制這把鑰匙只能登入,不能轉送連線:

```
mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'no-port-forwarding,no-agent-forwarding,no-X11-forwarding <phone-254.sh 印出的公鑰>' > ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
```

只准用鑰匙登入:密碼登入與鍵盤互動登入都關掉。

```
f=$PREFIX/etc/ssh/sshd_config; for k in PasswordAuthentication KbdInteractiveAuthentication; do grep -q "^$k no" $f || echo "$k no" >> $f; done; sshd -t && echo "sshd -t OK"
```

開機後自動保持喚醒、啟動 sshd:

```
mkdir -p ~/.termux/boot && printf '#!/data/data/com.termux/files/usr/bin/sh\ntermux-wake-lock\nsshd\n' > ~/.termux/boot/start-sshd && chmod 700 ~/.termux/boot/start-sshd
```

現在就啟動,並印出使用者名稱(記進私有 repo):

```
termux-wake-lock; sshd; whoami
```

改過 `sshd_config` 之後要重啟 sshd。Termux 沒有 `pkill`,用 pid 檔:

```
sshd -t && kill $(cat $PREFIX/var/run/sshd.pid); sshd
```

經 ssh 遠端改的話,重啟要放到背景、等這條連線結束後才執行,否則會切斷自己:
`nohup sh -c "sleep 2; kill \$(cat \$PREFIX/var/run/sshd.pid); sleep 1; sshd" >/dev/null 2>&1 &`

### 3. 驗收(從 WSL)
- 用 pinned 的 `~/.batman-dv/phone_known_hosts` 與專用鑰匙登入成功;
- **負向**:不帶鑰匙(`-o PubkeyAuthentication=no`)登入必須被拒(`Permission denied`)。

### 4. Android 設定
- 設定 → 應用程式 → **Termux** → 電池 → 選「**不受限制**」;Termux:Boot 也一樣。
- 通知列上 Termux 的常駐通知(「wake lock held」)不要關掉。
- **不要**執行 `termux-setup-storage`:它會讓 Termux 讀得到手機上的照片與檔案,這支手機用不到。

## B. 到現場才做(步驟在 `docs/validation/h4-onsite.md`)
- 行動數據關閉;家用 Wi-Fi 刪除或關掉自動連線。
- 連上 04 的測試熱點 C0:在主機上打開 `phone-254.sh c0-card` 產生的本機 QR 頁面,用手機掃描。密碼不會出現在對話、log 或指令列。
- 存好第二個測試網路 ALT。
- 兩個網路的「MAC 位址類型」都改成「**手機 MAC**」(進階設定)。
- 手機接上充電器,放在 04 旁邊。
