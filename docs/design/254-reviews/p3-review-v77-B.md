# 254-p3-impl v7.7(4aacc47)審查 B — 安全優先(S5 整份)

範圍:§3.7、§3.8、§3.11、§12(含 §12.5 負對照、§12.5.18 使用者決定)、附錄 E–I,以及 §4 / §5 / §6 / §7 / §8 / §10 用到的列。只讀:沒改任何 repo、沒上節點、`gh` 只做讀取。原始碼:Batman-p3 @ 4aacc47、firmware-2710 @ 02f0913d(rootfs = `build_dir/target-aarch64_cortex-a7{2,3}_musl/root-bcm27xx`)。GitHub 行為查官方文件(下面 G1–G5 附出處)。

## 0. 本輪自己查證的事實

| # | 事實 | 證據 |
|---|---|---|
| V1 | `batman-slot commit` 在**持鎖期間**以 `setsid /etc/init.d/openmanetd start … &` 起一個**脫離的背景子行程**(`addr_defer_release`);用 flock 後它會繼承 fd 9 | `batman-slot:753-765`(`cmd_commit` 先 `slot_lock`)、`:780-782` |
| V2 | openmanetd 是 procd 服務(daemon 由 procd fork,不繼承);持有 fd 9 的是 rc.common 的 sh 與 `batman-addr-defer`,它們通常幾秒內結束 | rootfs `/etc/init.d/openmanetd`(`USE_PROCD=1`、`start_service` 呼叫 `/usr/libexec/batman-addr-defer`);`batman-addr-defer:70` 自己也提到「procd flock」卡住的 HUNG 情況 |
| V3 | busybox `flock` 只有 `-n`(沒有 `-w`),repo 既有寫法是自己輪詢 | `halow-setkey:145`(「busybox flock has only -n, hence the poll」)、`:152`;`payload-run:92`;rootfs `/usr/bin/flock -> ../../bin/busybox`(兩板) |
| V4 | `/tmp/run/batman` 由 `batman_rundir` 驗證 root 0700、非 symlink;寫入類動詞 `need_rundir` 失敗就 die | `batman-slot:56-65`、`:85` |
| V5 | `.busy` / 舊鎖的現存讀者:`batman-autocommit:86`(`slot_writer_alive` 讀 `batman-slot.lock/pid`;被 `:213` 認領接手與 `:226` 延後兩處用)、`:226`(`.busy`)、`node/wtxn.go:450-454`(`otaBusy` Lstat `.busy`)、`node.go:247`;測試 `wtxn_v10b_test.go:59`、`p3review_test.go:147`;harness `scripts/node/tmp-trust-280.sh:22,61`、`scripts/rundir-paths.txt:24` | grep 輸出 |
| V6 | 公開 release 都在 `winson3QQ/Batman`(public、default branch main);資產名歷來不固定:`halow-node-v1.0.0.img.gz`、`golden-1.8.0.img.gz`、`ab-payload-ekh-bcm2711.tar.gz`、`batman-1.5.11-rel.1+…-ab.img.gz` 等;所有 release `immutable: false` | `gh api repos/winson3QQ/Batman/releases`(唯讀) |
| V7 | A/B `.img` 是 GPT 整卡映像,**p2 與 p4 各一份 squashfs**;不能直接對 `.img` 跑 `unsquashfs` | `scripts/build-ab-image.sh:10,135,194` |
| V8 | Batman repo 既有 release 類 workflow `release-scan.yml` 用未釘版本的第三方 action(`dependency-check/Dependency-Check_Action@main`、`anchore/sbom-action@v0`) | `.github/workflows/release-scan.yml` |
| G1 | `release` 事件的 `GITHUB_SHA` =「Last commit in the tagged release」→ 跑的是**那個 tag 指向的 commit 上的** workflow 檔 | docs.github.com …/events-that-trigger-workflows#release |
| G2 | `release` activity types 只有 published / unpublished / created / edited / deleted / prereleased / released;webhook 的 release 動作也沒有「資產上傳」;文件沒說上傳資產會觸發 `edited`(`edited` =「details of a release … were edited」) | 同上;docs.github.com/en/webhooks/webhook-events-and-payloads#release |
| G3 | `GITHUB_TOKEN` 觸發的事件(`workflow_dispatch` / `repository_dispatch` 除外)不會產生 workflow run | events-that-trigger-workflows(pull_request 註記) |
| G4 | `schedule` 只在 default branch 的最新 commit 跑;**public repo 60 天沒有活動會自動停用** | events-that-trigger-workflows#schedule |
| G5 | Immutable releases:發布後資產與 tag 不能改或刪;建議流程 = draft → 附上全部資產 → publish;只對啟用後的新 release 生效;是 repo 設定。文件沒說能不能改回 draft | docs.github.com …/immutable-releases、…/prevent-release-changes |

## 1. v7.6 發現逐條確認

| 發現 | v7.7 處理 | 判定 |
|---|---|---|
| B12-MAJOR-1 發布檢查不在真正的發布路徑 | `publish-release.sh` + `release-guard.yml` + firmware gate 獨立 job | ⚠️ 方向對、firmware 部分 ✅;但 guard 的觸發方式有三個繞過、`.img` 解析與未知資產沒定義 → **MAJOR-1**(新) |
| B12-m1 / A12-m12 symlink 鎖 → flock | §3.7.3 改 flock,拿掉 pid / starttime / zombie / TAMPER | ✅ 機制成立(§2.1);背景子行程繼承 fd、讀者探測讓 `-n` 寫者誤判 → m1 |
| B12-m2 租約多餘部分、SIGIO、reason | SIGIO 拿掉 ✅;租約失敗一律 15 | ⚠️ `EINVAL`(leases-enable=0)也回 15;§12.5 表仍寫 21 → m3 |
| B12-m3 namespace 裡的 p5 / p7 | §3.7.3 已列 | ✅ |
| B12-m4 過渡版繞過拒簽檢查 | `release-sign.sh --test-key`,檢查照跑 | ✅;發布端不驗簽章鏈 → m4 |
| B12-m5 tmpfs 沒掛上仍 rw 進 jail | §3.8.2 掛上了才 rw 掛進 jail | ✅(`batman-provd.init:19-20` 現在只有 ro 掛載,新加的 rw 掛載依條件加,做得到) |
| B12-m6 文字 | §4 清理表 prepare 那列已改;rc 14 只在 precheck | ⚠️ flock 改版又留下一批舊文字 → m2 |
| A12-m1…m18 | 附錄 I | ✅ 抽查 §3.7.3 / §3.7.4 / §3.7.5 / §3.8.2 都在 |

## 2. v7.7 新機制的攻擊

### 2.1 flock(§3.7.3)

| 攻擊 | 結果 | 證據 |
|---|---|---|
| 非 root 開鎖檔、拿 flock 讓所有槽操作 rc 14 | 做不到:目錄 root 0700,`batman_rundir` 驗證過;open 就失敗,拿不到 OFD | V4 |
| docker tenant / host-net 容器 | 容器裡的 root 只有在掛了 host `/tmp/run` 時才碰得到,那等於 host root;非特權容器碰不到 | V4 |
| 非 root 預先建 `batman-slot.flock` 的 symlink / FIFO / hardlink | 目錄不可寫 → 做不到;`>>` 不 truncate | V4 |
| 讀 `/proc/locks` | 非 root 看得到 inode 與 pid(資訊外洩可忽略,不是控制) | kernel 行為 |
| 被入侵的 provd(uid 471、jail、沒有 /proc) | 碰不到 RunDir | `batman-provd.init:19-20` |
| **持鎖期間起的背景子行程繼承 fd 9** | `commit` 的 `setsid … openmanetd start &` 會持鎖到 rc.common / `batman-addr-defer` 結束;procd 卡住時更久(`batman-addr-defer:70` 自己也處理「HUNG」)→ 這段時間 `write` / `arm` / `disarm` / sysupgrade stage 1 都 rc 14。只是可用性問題,不是完整性問題 | V1、V2 → m1 |
| 只殺 shell、`dd` 還在跑 | 鎖還在 → 不會有第二個寫者 ✅(設計目的) | §3.7.3 |
| 混用版本 | 新舊不在同一節點同時跑;舊 harness 副本只跑唯讀的 `precheck-node` | §3.7.3 |
| 讀者以 `LOCK_EX|LOCK_NB` 探測 | 探測那一瞬間,用 `flock -n` 的寫者會拿到 rc 14。autocommit 的 commit 有重試(`batman-autocommit:553-556`)、worker 會重試 3 次;`update.apply` 的 `arm` 回 14 → `E_BUSY`,app 重試 | V3 → m1 |

結論:**非 root 沒辦法 DoS 這把鎖**,原子性也成立。剩下兩點只影響可用性(m1)。

### 2.2 發布點(§3.7.2)→ MAJOR-1

### 2.3 `release-sign.sh --test-key`(過渡版)

- 所有拒簽檢查照跑 ✅。DEV 節點本來就接受任何 T 簽的東西(T 是公開的),所以過渡版沒有讓 DEV 節點的風險變大;信任 R 的節點不收 T 簽的東西 ✅。
- 缺的一點:`publish-release.sh --publish` 只檢查 image 內建的根鑰匙,沒有檢查附上的 `.sig.cbor`。結果是 T 簽的過渡版 payload(內建 R、`rel`)也能被公開發布。PROD 節點收到後會拒絕(不是安全缺口),但仍會有一個裝不起來的「正式版」流出,而且也沒有證據顯示正式簽章儀式真的做過 → m4。

### 2.4 tmpfs 沒掛上時不 rw 掛進 jail

✅ 已修。provd 寫入時拿到 ENOENT 或 EROFS → PUT 失敗,這是 fail-closed;`bulk.open` 也會因為 `fstatfs` 而回 reason 21。

### 2.5 租約失敗 → reason 15

`EAGAIN` 回 15 是對的:檔案已經 unlink,app 重傳就好。`EINVAL`(`leases-enable=0`,只有 root 改得到)也回 15 的話,app 會一直重傳、每次都失敗,畫面也會顯示錯的文字;被入侵的 provd 一直開著 fd 也會造成同樣的無限重傳。兩種情況都只有 DoS → m3。

## 3. 行為者總覽(整份 S5)

| 行為者 | 結果 |
|---|---|
| mesh 遠端 | 8095 被 bridge mark + iifname 擋(F75)✅;更新動詞只走 Noise 擁有者 session ✅ |
| 手機 AP 上的裝置(知道 AP 密碼) | 能搶 bearer、先 PUT、搶走回應分塊 → 都只是 DoS(已列界線);垃圾 rootfs 在第一遍就被擋 ✅ |
| 本機非特權行程 / docker tenant / host-net 容器 | flock、RunDir、FAT 都碰不到 ✅;`SO_MARK` 由 iifname 擋 ✅;先佔 8095 = DoS(已列)✅ |
| 被入侵的 provd | 租約 + unlink + fchown 保住內容完整性 ✅;最多佔用到 `size=` ✅;tmpfs 沒掛上時不再有 rw 目錄 ✅;一直開著 fd = 無限重傳的 DoS → m3 |
| 被移除的擁有者 | 窗、pending、worker 都會清掉;「已寫入、未啟用」的槽已列誠實界線 ✅ |
| 成員 | 不能用 `update/*`、`bulk/*`;窗模式只收擁有者 ✅ |
| 實體奪取 | 沒有 secure boot 前的界線(已列)。**如果有信任 T 的 image 被公開發布,奪取節點 → 重置 → 認領後就能經 app 裝任意韌體** → 所以發布點很重要 → MAJOR-1 |
| 供應鏈 / 維護者 / GitHub | 能改兩個 repo 的人(已列界線);**guard 依觸發方式可被繞過、新 workflow 的權限與 action 釘選沒寫** → MAJOR-1 |
| 我們自己的錯 | 事後追加資產、tag 指到舊 commit、資產格式沒預料到、編輯舊 release 的說明 → MAJOR-1;背景子行程持鎖、舊文字 → m1、m2 |

## 4. Findings

### MAJOR

**MAJOR-1 release-guard 依 `release` 事件觸發,有三條「我們自己的錯」會直接繞過;資產怎麼解析、未知資產怎麼處理都沒定義;編輯舊 release 會把 Latest 改回 draft**

- **情境**
  - (a) **事後追加資產**:先用 `publish-release.sh` 發一個合格的 release,之後有人用 `gh release upload vX foo-wsl.img.gz`(或 `--clobber` 換一個「修好」的檔)追加或替換資產。資產上傳不會觸發任何 `release` 事件(G2),guard 不會跑;`publish-release.sh` 也只管 `gh release create`。結果是信任公開 T 的 image 一直掛在公開頁面上。
  - (b) **tag 指向的 commit 上沒有 guard**:`release` 事件執行的是 tag 指向那個 commit 上的 workflow 檔(G1)。tag 打在加 guard 之前的 commit、或打在一個沒有(或改過)guard 的分支上,guard 就不會跑,或跑的是別的版本。
  - (c) **資產格式不在預期內**:資產名歷來不固定(V6),也可能出現 `.img.xz`、`.zip`、`.7z` 這類格式。設計只寫「對每個要附上的 image / payload 以 `unsquashfs -cat` 讀」,沒定義「解不開 = FAIL」。另外 A/B `.img` 是 GPT 整卡,裡面有 p2、p4 兩份 squashfs(V7),不能直接 `unsquashfs`。照字面實作很容易只檢查認得的副檔名,其他一律放行。
  - (d) **編輯舊 release**:R 產生前釘選檔不存在,所以檢查一律 FAIL(§3.7.2)。這時有人改 v1.5.11(目前的 Latest)的說明 → 觸發 `edited` → guard 把現行公開版改回 draft,轉賣工具的 image 清單與使用者下載都會斷。P3 之前的 image 沒有 `release-root.pub`,不經 app 更新,本來就不在這個威脅裡。
  - 另外,設計寫「從網頁手動上傳也擋得到」,但只有「在 draft 上傳完再 publish」這條路有根據;網頁「編輯 release 時追加檔案」會不會觸發 `edited`,文件沒有寫(G2),⚠️ 沒驗證。
- **證據**:G1、G2、G4、G5、V6、V7;設計 §3.7.2 第 1–2 點、§12.5 的「發布點」列。
- **修法**(偏向拿掉機制,讓平台本身擋):
  1. **開 repo 的 release immutability**(G5):發布後資產與 tag 都不能改,(a) 直接消失,也不需要 guard 去追「事後的資產」。`publish-release.sh` 改成:建 **draft** → 上傳 → **從 draft 下載回來**跑 `--publish` 檢查 → 過了才 publish。只對啟用後的新 release 生效,所以舊 release 不受影響(d 的一半)。⚠️ immutable release 能不能改回 draft,文件沒說;啟用前要在測試 repo 實測。如果不能,guard 的動作改成「開 issue + 刪 release」(文件說可以刪),或只開 issue。
  2. guard 改用 **`schedule`(只在 default branch 跑,G4)+ `release: [published]` + `workflow_dispatch`**,每次掃**所有**非 draft、建立時間晚於 cutoff 的 release(cutoff = guard 上線日;更早的 release 列在 allowlist,不改回 draft → 解決 d)。排程跑的永遠是 main 上的 workflow 檔,(b) 就消失了。注意 public repo 60 天沒活動會自動停用排程(G4):把「guard 上次成功的時間」放進 daily-validation 或 #75 的檢查。
  3. **未知資產 = FAIL**:每個資產都必須屬於明列的類型,`SHA256SUMS` / `*.sig.cbor` / `*-ab-payload.tar.gz` / `*-ab.img.gz` 各自有解析方式。`.img` 要讀 GPT,找出 p2 與 p4 兩份 squashfs **都**檢查;解壓或解析失敗一律 FAIL。
  4. **權限**:解析不受信任資產的 job 用 `permissions: contents: read`,只輸出判定結果;另一個 job 才拿 `contents: write`、`issues: write` 去改 release / 開 issue。不需要任何 secret。所有 action 用 commit SHA 釘選(這個 repo 的 release workflow 現在用 `@main` / `@v0`,V8)。guard 與 gate 腳本加進 CODEOWNERS / 必要審查。惡意的 fork PR 不會觸發 `release` / `schedule`,`pull_request` 的 token 是唯讀 → 它只能靠「被 merge」生效,所以靠審查擋。
  5. 界線照舊寫明:有 admin 權限的人可以關掉 immutability、停用 workflow。guard 擋的是我們自己的錯。
- **負測試**(在測試 repo):
  - 發布後 `gh release upload` 一個 `wsl` 資產:開了 immutability → 上傳被拒;沒開 → 下一次排程把它抓出來。
  - tag 打在沒有 guard 的舊 commit 上發布 → 排程仍然抓到。
  - 資產是 `.img.xz`、`.zip`,或 GPT 映像的 p4 放 `wsl` rootfs → FAIL。
  - 編輯 cutoff 之前 release 的說明 → 不改回 draft。
  - guard 解析 job 的 token 沒有 write 權限(lint)。
  - **負對照**:只用 `release: published/edited` 觸發 → 追加資產與舊 tag 兩案都還是 published。

### MINOR

**m1 flock:持鎖期間的背景子行程、讀者探測會讓 `-n` 寫者誤判**

- (a) `cmd_commit` → `addr_defer_release` 的 `setsid /etc/init.d/openmanetd start &`(V1)會繼承 fd 9,commit 回來之後鎖還在,直到 rc.common 與 `batman-addr-defer` 結束;procd 卡住時會更久(V2)。這段時間 helper 的 `write` 回 14(要重試)、`update.apply` 的 `arm` 回 `E_BUSY`、sysupgrade 被拒。修法:在設計裡規定「鎖動詞裡的每個 `&` / `setsid` 子行程都要加 `9>&-`」(`wireless-settle.sh:14-15` 已經這樣做),並加一條 lint:在 `batman-slot` 裡 grep `&$`,沒有 `9>&-` 就 FAIL。測試:接縫讓 `openmanetd start` 卡 30 s → commit 回來後馬上 `flock -n` 拿得到。
- (b) 讀者用 `LOCK_EX|LOCK_NB` 探測的那一瞬間,寫者的 `flock -n` 會失敗。busybox 沒有 `-w`(V3)。修法:寫者照 `halow-setkey:152` 的方式輪詢(例如最多 5 s、每 0.2 s 一次)後才回 14;讀者改用 `LOCK_SH`,讀者之間不互斥。測試:讀者以 1 kHz 探測時跑 `commit` 200 次,0 次 rc 14。
- (c) 寫明讀者遇到檔案不存在 = 不忙(這是對的:沒有人持鎖時本來就可能沒有檔);讀者開檔要用 `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`。

**m2 改成 flock 之後留下的舊文字與漏改的讀者**

- §3.7.3 `write` 列:「precheck(… 寫 `.busy` …)」→ 應該刪掉。
- §3.7.5-7:「鎖與 `.busy` 由持有者檢查回收(§3.7.3)」→ 改成「持有者與子程序結束時 kernel 自動釋放」。
- §3.7.6:「`.busy`:改用 §3.7.3 的持有者規則(`:226`)」→ 改成 flock 探測,而且要寫明 `slot_writer_alive`(`:86`)也被 `:213` 的認領接手使用(V5)。漏改的話,Pi 3 commit 的 p7 寫入期間 watchdog 會接手並重開 → `:205-206` 註解說的磚機。
- §4 `:546`:「`batman-slot.lock` 持有者活著就不刪」→ 改成用 flock 探測。
- §12.5:「同時 sysupgrade」那列的負對照「拿掉 `.busy` 檢查」→ 改成「拿掉 flock」;「讀取租約」那列寫 reason 21,但 §3.7.5-1 是 15 → 統一(見 m3)。
- §10 要列出測試與 harness 中的 `.busy` 讀者:`wtxn_v10b_test.go:59`、`p3review_test.go:147`、`tmp-trust-280.sh`、`rundir-paths.txt:24`(後兩個照 #290 走 harness PR)。

**m3 租約拿不到的 reason 沒有分情況**

`EAGAIN` → 15(app 重傳,正確)。`EINVAL`(`leases-enable=0`)→ 改回 21(節點端無法寫入,重傳沒用)。另外,同一個 sha 連續 3 次 `EAGAIN` 也回 21,讓被入侵的 provd 造成的情況不會變成無限重傳。§12.5 表一起改。測試:用 root 設 `sysctl fs.leases-enable=0` → reason 21、目標槽沒動。

**m4 發布檢查沒有驗 `.sig.cbor` 的簽章鏈**

`publish-release.sh --publish` 對每個 payload 加一道:附上的 `.sig.cbor` 必須由 R 背書、serial ≥ image 的 min-serial、S 的 key 4 = 該 payload 的 sha256(SUMS)(Go 驗證程式或 `signrel.py --verify`)。T 簽的過渡版不能公開發布(它本來就只該用 ssh / bench 送進 DEV 節點)。測試:T 簽的 `rel` payload 加 R image → `--publish` FAIL。

**m5 `--publish` 與 `.img` 的解析細節要寫進契約**

並進 MAJOR-1 第 3 點:GPT 的 p2 與 p4 都要檢查;「解不開」與「找不到 stamp」都是 FAIL;只能用 `-cat` 讀指定的檔,不能解開整份 squashfs(guard 是在 runner 上處理外來的檔案)。

## 5. 確認沒問題(✅)

- flock 的原子性、非 root 碰不到、只殺 shell 時 `dd` 仍持鎖(V4、§2.1)。
- 租約、unlink、fchown 對被入侵的 provd 的所有寫入路徑(沿用 B12 §2.1 的分析,本輪的 v7.7 沒有改動這部分)。
- tmpfs 沒掛上時不 rw 掛進 jail;`fstatfs` 的檢查。
- `release-sign.sh --test-key` 所有拒簽檢查照跑;DEV 節點的風險沒有增加。
- firmware gate 獨立 job,`release` 與 `publish-packages` 都 `needs` 它(修掉 B12 的 W14)。
- 白名單 tar、兩遍、SUMS 名字規則、版本規則、key 6 / 7 / 8、判讀表、`rebooting` 時機、啟動時 disarm、namespace —— 本輪重看沒有新問題。

## 6. 判定

**APPROVE-WITH-CHANGES(0 BLOCKER / 1 MAJOR / 5 MINOR)。**

- 核心的節點端機制(flock、租約、tmpfs、namespace)都成立,沒有找到非 root 或被入侵的 provd 的繞過方式;m1–m3 是可用性問題與文字問題。
- MAJOR-1:guard 用 `release` 事件觸發,追加資產、tag 指到舊 commit、未知格式這三條「我們自己的錯」都會繞過,而這正是使用者決定要擋的後果(信任公開 T 的 image 被公開發布)。最小修法是開 release immutability、先發 draft 檢查再 publish、guard 改用排程在 main 上掃全部 release、未知資產 = FAIL。
- 依規則:MAJOR 改完後整份再審。
