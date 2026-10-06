# #247-1 batman-adv:換成 OpenWrt 24.10 維護線(2024.3-13 + 101 個 backport)

狀態:**v2 — 對抗式 design review = PASS-WITH-CHANGES(2026-10-06),本版已納入全部 findings(見 §10)**
單號:winson3QQ/Batman#247(子項 1)。取代 #246 的單一 backport(firmware `patches/<board>/0009-*`)。
不在範圍:runc(被 #252 擋)、OpenWrt base、Morse driver。

---

## 1. 問題

image 裡的 batman-adv/batctl 是 OpenMANET feed 的 **2025.4-openwrt-2**(三台實機 2026-10-06 確認:kmod、batctl 都是 `2025.4-openwrt-2`,alfred `2025.5-r1`)。上游在 2025.4 之後修了大量 bug(TT/TVLV 溢位、UAF、frag 長度、OOB、tp_meter race…),我們只單獨補了 #246 那一個。現場意義:mesh 核心 kernel module 帶著已知可被鄰居封包觸發的 OOB/UAF/panic 問題;#245/#246 已示範鄰居行為可以把節點打掛。

## 2. 為什麼不追上游最新(v2026.x)— 已實編證實不可行

我們 kernel = 6.6.138(被 Morse/OpenMANET 綁在 24.10)。

| 版本 | 實編結果(2026-10-05,bcm2710) |
|---|---|
| 2026.3 | `bat_iv_ogm.c:257: implicit declaration of function 'disable_delayed_work_sync'`(workqueue API,≥6.10 才有) |
| 2026.1 | `bat_v_elp.c:366: implicit declaration of function 'kzalloc_obj'`(更新的 alloc macro) |
| 2026.3 + 引入 batman-adv 自帶 `compat-include` | `compat-include/linux/version.h: "LINUX_VERSION_IS_LESS" redefined`(跟 OpenMANET 的 mac80211-backport compat 打架) |

要硬上就得自己 backport kernel API shim,量大且脆。

## 3. 方案:OpenWrt `openwrt-24.10` 分支的 routing feed

`openwrt/routing@openwrt-24.10`(HEAD `00619bc7`,2026-09-03 "batadv-for-24.10"):
- `batman-adv 2024.3-13`:**101 個 patch**,含 `0012-Avoid-double-rtnl_lock-ELP-metric-worker`(= #246 的 b0af0a376fb1)、`0011 fix OOB in NC decode`、`0043 reject oversized TVLV`、`0046 mcast UAF`、`0101 reject unrepresentable mcast TVLV`… 由 batman-adv 維護者(Sven Eckelmann)針對 24.10/6.6 這代維護。
- `batctl 2024.3-5`:77 個 patch(含 netlink 錯誤處理、tp/originators 修正)。

⚠️ 我們**目前 pin 的 routing feed `178a40d`(master,2025-12-03)只有 2024.3-7 / 11 個 patch**,不是這條線。

## 4. 相容性事實(reality check 已驗)

| 項目 | 結果 | 依據 |
|---|---|---|
| on-wire 協定(滾動 OTA 時新舊混跑) | ✅ 相容 | 兩版 `BATADV_COMPAT_VERSION 15`;`batadv_packet.h` 只差宣告順序 + `__counted_by_be` 註記,layout 相同 |
| batctl ↔ kmod netlink | ✅ | `batman_adv.h` uapi 只差註解(softif→meshif 改名) |
| 我們腳本用的 batctl 子指令(n/tp/ping/if/o/dc/tg/ra) | ✅ 全有 | 2024.3 指令集 ⊇ 2025.4(多 `nc`) |
| openmanetd 1.3.10 解析 `batctl gwj/mj/nj/oj` JSON | ✅ | 兩版 JSON key 字串集合唯一差異 = 2024.3 多 `network_coding_enabled`;openmanetd 用一般 `json.Unmarshal`(無 `DisallowUnknownFields`)→ 多的欄位被忽略 |
| alfred | ✅ 留 2025.5 | alfred `packet.h` 2024.3 與 2025.5 完全相同;alfred 不依賴 kmod 版本 |
| `batctl-full` 變體 | ✅ | 24.10 batctl Makefile 同樣提供 tiny/default/full |
| netifd proto(`batadv.sh` 等) | ⚠️ 見 §5 D3 | 24.10 版多 `network_coding` 選項;`batadv_vlan.sh` ap_isolation 預設 0(我們無 VLAN 段);99-migrate 多搬 network_coding |
| 失去的 2025.x 非修正功能 | ✅ 不影響 | jumbo frame(我們 bat0 MTU 1460)、VLAN 0 untagged(無 VLAN 介面)、TT 去冗餘(效率)、移除 NC(我們關) |
| 封裝差異(Makefile) | 小 | 24.10 多 `CONFIG_BATMAN_ADV_NC` 選項;OpenMANET 多 `conffiles /etc/config/batman-adv`(節點上此檔不存在) |
| routing feed 其他套件 | ✅ 無波及 | `.config` 沒有任何 routing feed 套件被選 |

## 5. 設計決定

### D1 取得 source 的方式 — **建議 C:routing feed 改 pin 到 openwrt-24.10,強制裝 batman-adv + batctl**

| 選項 | 做法 | 優點 | 缺點 |
|---|---|---|---|
| A | board patch(像 #246 的 0009)把 openmanet feed 的 batman-adv/batctl 目錄改寫成 24.10 內容 | 沿用既有機制 | patch ~1MB × 兩板重複;**setup 的 patch 失敗會被吞**(wsl.1 漏套 022 的前例);下次升級又要重產大 patch |
| B | vendor 進 Batman repo(我們自己的 feed),`feeds install -f -p batman` | 全在自己手上 | 101+77 個 GPL patch 進公開 repo、日後 sync 手工;Batman feed pin 跟 batman-adv 版本耦合 |
| **C** | `feeds.conf.default` 的 `routing` 改 pin `openwrt-24.10@00619bc7`;setup 在 `install -p openmanet -a` 之後把 batman-adv、batctl 改裝自 routing | 零 vendoring、上游原樣、升級 = 改一個 sha;沒有 patch 可被吞 | 改到 firmware fork 的 `openmanet_setup.sh`(我們自己的 fork,可接受);`feeds -f` 對「已由另一 feed 安裝」的行為要實驗確認 → 用顯式 `uninstall` + `install -p routing` 並加硬閘 |

選 C。具體:
```
# feeds.conf.default
src-git routing https://github.com/openwrt/routing.git^00619bc7bc60d8b67ecc490121e45298b122cd6e
# openmanet_setup.sh, -i 區段,在 install -p openmanet -a 之後:
./scripts/feeds uninstall batman-adv batctl
./scripts/feeds install -p routing batman-adv batctl
```
(alfred 不動 → 仍是 openmanet 2025.5。)

- 必須「先 uninstall 再 install -p routing」:`feeds install -f` 對已由別的 feed 安裝的套件是 no-op(review 讀 `scripts/feeds` 確認)。uninstall 會跑一次 `make defconfig`,後續 `-b` 步驟會重生 .config,無害。
- **pin 觸發(review MAJOR-1)**:現在 `build-board.sh` 只有 **batman** feed pin 變動才加 `-i`,`stamp-batman-build.sh` 也只驗 batman feed → 只改 routing pin 的話,既有樹**不會**換過去。修法:`build-board.sh` 與 stamp 改為比對 `feeds.conf.default` 裡**每一條** `src-git <name> ...^<sha>` 和 `git -C feeds/<name> rev-parse HEAD`,任一不符 → `-i`(stamp 則拒絕)。CI(`fast-build.yml` 一律 `-i`)本來就沒問題。
- 既有樹切換程序(寫進 boards-and-builds.md):pull firmware → `bash scripts/build-board.sh <board>`(上面的修法會自動偵測 routing pin 變了並 `-i`)→ 閘 D5-1 確認。

### D2 alfred:留 OpenMANET 2025.5
理由:封包格式相同、不綁 kmod、OpenMANET 在裡面修過啟動邊界條件("fix(alfred): better start up edge case handling"),openmanetd 依賴它。

### D3 Network coding:**編譯期強制關**
- 節點 uci 有 `network.bat0.network_coding='1'`(OpenMANET 預設)。2025.4 的 proto 不認 → 無作用;**24.10 的 proto 會執行 `batctl meshif bat0 network_coding 1`**。
- 若 NC 被編進 kmod → 換版後 NC 默默打開 = 行為改變 + 暴露 NC 解碼路徑(0011 OOB 就在這)。
- 做法:`boards/common/batman_diffconfig` 明寫 `# CONFIG_BATMAN_ADV_NC is not set`(Config.in 無 default=本來就 n,明寫是防日後被別的 diffconfig 打開);config lock 會變(刻意變更,`--update-lock` 後 review,diff 可能不只一行)。
- 更正(review MINOR-6):NC 未編入時 `batctl meshif bat0 network_coding 1` **不會失敗**,是 exit 0 靜默無效(kmod `netlink.c` 在 `#ifdef CONFIG_BATMAN_ADV_NC` 外忽略該屬性)→ 同樣無害。讀取 `batctl nc` 則回 EOPNOTSUPP,可當 D5-3 的檢查。
- 不改 uci(那是 OpenMANET 精靈產生的,改它會牽動 provisioning/golden seed)。

### D4 移除 #246 board patch `0009-batman-adv-avoid-double-rtnl-lock-elp-246.patch`(兩板)
它改的是 openmanet feed 的 batman-adv 目錄,改裝 routing 後變死碼;上游 0012 已含同一修正。保留只會混淆。

### D5 防「靜默沒換到」的硬閘(核心)
setup 的 patch/feeds 步驟有吞錯的前科,所以結果必須被**獨立檢查**:
1. **build 時**(build-board.sh step 2 之後、make 之前):
   - `git -C feeds/routing rev-parse HEAD` == pin `00619bc7…`;
   - `package/feeds/*/batman-adv` 與 `package/feeds/*/batctl` 各**恰好一個**,且指向 `feeds/routing/…`;
   - 其 Makefile `PKG_VERSION=2024.3`、`PKG_RELEASE=13`(batctl `=5`);
   - `.config` 裡 batctl 變體**恰好一個**(`batctl-full=y`,無 `batctl-default`/`-tiny`;review MINOR-8:24.10 batctl Makefile 沒有 OpenMANET 的 per-variant build dir,`kitchensink_diffconfig` 有 `batctl-default=m`)。
   不符 → exit 1。
2. **manifest gate**(step 6,`check-image-manifest.sh`,格式 `<pkg> - <ver>`):**精確比對** `kmod-batman-adv - 6.6.138.2024.3-r13`、`batctl-full - 2024.3-r5`、`alfred - 2025.5-r1`。(review MAJOR-2:只比「含 2024.3」會讓目前 pin 的 master 2024.3-**7** 過關。)
3. **節點上(daily-validation 新增 `batman-ver-247`)**:`/sys/module/batman_adv/version` 與 `batctl -v` 一致且 = 預期;`batctl meshif bat0 nc`(讀)必須失敗(EOPNOTSUPP);`batctl mj` JSON 無 `network_coding_enabled`。預期版本從 image 的 `/etc/batman-build` 或 manifest 讀,不寫死在腳本。

### D6 版本號「看起來倒退」
kmod 版本 `6.6.138.2024.3-r13` < 現行 `…2025.4-r2`。我們只走整顆 image(A/B sysupgrade),不走 opkg upgrade → 無影響。在 release notes / VERSIONS.md 明寫「2024.3-13(24.10 維護線,含 101 backport)取代 2025.4」避免誤解為降級。

## 6. Failure modes

| # | 情境 | 偵測 | 後果 / 處置 |
|---|---|---|---|
| F1 | 2024.3-13 在我們 6.6.138 + OpenMANET mac80211-backport 環境編不過(24.10 kernel 是 6.6.x,預期可編,但沒實證) | build | 停在 build,無節點風險;回頭評估 A/B 選項或補 patch |
| F2 | feeds 安裝沒真的換過去(-f/uninstall 行為、setup 只在 `-i` 跑) | D5-1/D5-2 硬閘 | build 失敗,不出貨 |
| F3 | 混跑期間 mesh 不通(滾動 OTA) | 先 1 台 OTA,混跑測試 | A/B:未 commit 自動 revert;已 commit 可再 OTA 回 1.5.1 |
| F4 | 路由/吞吐行為退化(2025.x 有 OGM 聚合 MTU 限制、TT 去冗餘等變更) | **iperf 為閘**(≥ baseline 8.6–9.3 Mbps 的 90%)、鄰居/路由數穩定。`batctl tp` **不當閘**:~30 個 tp_meter patch 改了壅塞控制,舊 baseline 不可比、新舊混跑的 tp 無意義 → 全 fleet 換完後重建 tp baseline(review MINOR-5) | 退回;逐項比對 |
| F4b | 部分功能壞但 autocommit 閘照樣過 → 壞版被定案(閘只看 plink≥1、1 個鄰居、br-ahwlan IPv4、dropbear) | 混跑互通測試必須在 **trial 視窗內**做(見 §8) | trial 期間 FAIL → 不 commit、自動 revert |
| F9 | 非 root 跑 batctl 的程式行為改變:2024.3 的 JSON 查詢要 root(`check_root_or_die`),2025.4(2024.4 起)不用 → 非 root `batctl nj` 由「`[]` rc=0」變「錯誤 rc≠0」(review MINOR-4) | openmanetd、我們的腳本都以 root 跑 → 不受影響;**#220 影子設計 v3.2 的 §SUSPECT_EMPTY / §11.1 fixtures 建立在 2025.4 行為上,要改** | 在 #220 留言 |
| F10 | batctl ~15 個 patch 改 exit code | 我們腳本解析文字輸出 + `2>/dev/null`;daily-validation 全套確認 | 修腳本 |
| F5 | NC 被意外編入 → 換版後打開 | D3 lock + D5-3 | build/驗證 FAIL |
| F6 | openmanetd 拓樸/gateway 功能出錯(JSON 解析) | 節點上 openmanetd log 無 `batctl … :` 錯誤、web UI 拓樸正常、`batctl gwj/mj/nj/oj` 抽樣 | 退回 |
| F7 | #245 rejoin panic 重現(跟 mm6108 相關,不應受影響,但 batman 是另一端) | daily-validation `rejoin-245-246` + 03 wifi down/up N 圈 | 退回 |
| F8 | 混跑時 alfred 資料交換異常 | `alfred -r` 抽樣、openmanetd 位置/狀態同步 | 退回 |

## 7. 回退
- 節點:A/B,上一槽仍是 1.5.1-rel.1;trial 未 commit 自動 revert;已 commit → OTA 1.5.1 payload(各台 `/opt/batdata/ota-27xx-rel1.tar.gz` 仍在)。
- build:revert firmware commit(feeds.conf pin + setup 兩行 + lock + 刪 0009)。

## 8. 驗證計畫
1. **build**:兩板 `bash scripts/build-board.sh ekh-bcm271{0,1}`(含 `--update-lock` 的刻意 lock 變更 review),D5-1/2 硬閘過;ab-card-invariants(WSL root)。(review 已在 scratch 用 bcm2710 kernel 6.6.138 實編 patched batman-adv:0 error/0 warning,只差 modpost 符號 → 正式 build 才算數;bcm2711 未編。)
2. **單台**:02(bench,非網路橋)`sysupgrade -n` + setsid,照常 autocommit。檢查 D5-3、`batctl n/o`、openmanetd、alfred。
   - **與 review MAJOR-3 的偏差(使用者 2026-10-06 決定)**:實作時查證 `autocommit-hold-once` 只擋 revert、**不擋 commit**(健康 3 次即 commit,Pi4 約 100 s),現有機制沒有可持久的「延後 commit」開關(fault seam 都在 `/tmp`)。`autocommit-skip-once` 會同時關掉自動 revert → 若新版讓 02 掉出 mesh 會失聯、需到場拔電。使用者選擇:**照常 autocommit,commit 後立刻做步驟 3;FAIL → `batman-slot rollback` 回 1.5.1**。安全性:mesh 沒接上時 autocommit 閘本身不會 commit、會自動 revert;會被 commit 的只有「mesh 接上但部分功能壞」,這時節點仍可達,可手動 rollback。
   - 後續(另開單):autocommit 增加「operator 驗收前延後 commit、但保留 deadline revert」的持久開關。
3. **混跑互通**(02 新、03/04 舊)≥30 分:鄰居/路由完整、雙向 iperf、ping 全對、alfred 讀得到三台資料(type 64/102/103 各 3 筆);**加測**(review MAJOR-3):TT churn(02 上用 veth 造一個假 client MAC,看 03/04 `batctl tg` 學到、移除後消失)、`batctl gwj/mj/nj/oj` JSON 合法 + openmanetd 無解析錯誤、混跑中 03 rejoin(wifi down/up)。腳本 `interop.sh`(PR 附輸出)。
4. **04(OTS)** → OTS 6/6;**03(唯一網路橋)最後**。
5. **全 fleet 新版**:daily-validation 全套(node 從 Git Bash、ab-card 在 WSL root,canonical harness `/home/yello/Batman` main)、mesh tput(iperf 為閘;`batctl tp` 重建 baseline)、`rejoin-245-246`、03 wifi down/up ≥20 圈 0 鄰居 panic、crash 計數不增。
6. 新回歸 `batman-ver-247` 加進 daily-validation(D5-3)。

## 9. Review 對 Q1–Q4 的回答(已讀原始碼/上游 git 驗證)
- **Q1 可靠,但只在 `-i` 時發生** → 已用 D1 的「全 pin 比對觸發 `-i`」+ D5-1 解決。
- **Q2 無倒退**:v2024.3..v2025.4 間 12 個帶 `Fixes:` 的修正,8 個已在 24.10 backport(→0003/0004/0005/0006/0008/0009/0010/0011,另 0007),4 個(b10d75d9 TT offset、2105f8ac inactive-iface、472d63bf、59acb425)修的是 2024.3 **之後才引入**的 bug(`merge-base --is-ancestor` 驗證)→ 不適用。2025.4 之後的上游修正 100 個中 89 個已在 24.10。
- **Q3 直接改 pin routing**:master@178a40d 與 openwrt-24.10 的套件目錄集合相同(29 個),`.config` 選 0 個 routing 套件。
- **Q4 沒有其他 OpenMANET 專屬行為**:OpenMANET 的 batman-adv 歷史只有一個 squash commit(Makefile、Config.in、proto、99-migrate、compat patch 0001–0003、compat-hacks.h)。其 99-migrate 在 function 裡用 `continue`(bug),24.10 用 `return`。

## 11. 實作中發現的既有 build 漏洞(firmware `d3dbbef3`、`cedc9ce0`;另經 code review PASS-WITH-CHANGES,已全修)
D1 的「任何 pin 變動就 `-i`」實際跑起來,踩到 `openmanet_setup.sh -i` 兩個既有漏洞:
1. `feeds update` 不動 pinned feed 的 working tree → 上次 `-i` 套過的 board patch 還在,再套一次:新增檔案型 patch(#245 的 022)被**重複追加**、driver build 失敗;修改型 patch 留 `.rej`;而 patch 迴圈**吞掉失敗**照印成功。
2. feed patch 分板(`patches/ekh-bcm2711` ≠ `patches/ekh-bcm2710`),但兩板共用一棵樹;沒重跑 `-i` 就換板 build,會用到另一板的 patch。1.5.1-rel.1 是靠手動「硬清 feeds + detach feeds/batman 強迫 `-i`」避開。

修法:`-i` 先 `reset --hard` + `clean` 每個 feed(feeds/batman 除外)再套 patch;patch 失敗即中止;`feeds/.batman-patched-board` 記錄 feeds 目前帶哪一板的 patch(`-i` 開頭刪、完成才寫),build-board.sh 不符就 `-i`;`check-feed-pins.sh` 也拒絕 `feeds.conf` 覆寫與沒 pin 的 src-git;CI 加 source gate。
連帶:`patches/ekh-bcm2711/0005-golang-GCC-15` 已被上游 packages pin 吸收(一直是「已套用、默默跳過」)→ 刪除。行為差異:bcm2710 不再偷偷帶到 bcm2711 的 packages patch(對 1.5.1 的 manifest 差異見 PR)。

## 10. Review findings 處置
| # | 內容 | 處置 |
|---|---|---|
| MAJOR-1 | 只改 routing pin 不會觸發 `-i`,既有樹不換 | D1 全 pin 比對 + stamp 拒絕 + 切換程序 |
| MAJOR-2 | 「含 2024.3」會放過 master 的 2024.3-7 | D5-2 精確版本 |
| MAJOR-3 | 先 commit 才測混跑 → 半壞版可能被定案 | §8 混跑在 trial 內 + TT churn/gw/rejoin |
| MINOR-4 | batctl 2024.3 JSON 查詢要 root | F9;#220 留言 |
| MINOR-5 | tp baseline 失效 | F4 改 iperf 為閘、重建 tp baseline |
| MINOR-6 | NC set 是 exit 0 不是失敗 | D3 更正 |
| MINOR-7 | 上游仍有 24.10 未收的修正:`742a0e35`(TT hash-remove race)、`d0ded7c5`(BLA lasttime,0091 的後續;我們開 BLA)、`2a77475e`(BATMAN_V bonding 候選;我們開 bonding)、`9c7a6f34`;另兩個只影響 BATMAN_IV | 不是倒退(2025.4 也沒有)。**本次不夾帶**(保持「上游原樣、零自補」);開追蹤單,等下次 24.10 bump 或評估自帶 742a0e35/d0ded7c5/2a77475e |
| MINOR-8 | batctl 多變體 build dir 衝突 | D5-1 恰好一個變體 |
| MINOR-9 | batctl exit code 改變 | F10,daily-validation 確認 |
