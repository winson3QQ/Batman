# #252 golang toolchain:讓所有 Go 套件用 build 樹自建的 Go

狀態:**v2 — 對抗式 design review = PASS-WITH-CHANGES(2026-10-06),已全部納入(§8)**。單號 winson3QQ/Batman#252(擋 #247 runc、#250 containerd/docker)。

## 1. 事實(2026-10-06 reality check,WSL `/home/yello/firmware-2710` @ build-3aplus c77cfa04 + 節點)
- 安裝的 `golang` = **OpenMANET feed** meta 套件(`feeds/openmanet/lang/golang/golang`,`HOST_BUILD_DEPENDS:=golang$(GO_DEFAULT_VERSION)/host`,`GO_DEFAULT_VERSION:=1.26`)。建出 **go 1.26.4** 於 `staging_dir/hostpkg/lib/go-1.26/`,只有帶版本號的連結 `staging_dir/hostpkg/bin/go1.26`、`gofmt1.26`;**沒有不帶版本號的 `go`**。go-bootstrap(1.24.13)是編 1.26 用的 bootstrap。
- OpenMANET 的 `golang-package.mk` 有 `GO_BIN_PATH := PATH=$(STAGING_DIR_HOSTPKG)/lib/go-$(GO_HOST_VERSION)/bin:$(PATH)`,`GO_HOST_VERSION` 由 `golang-values.mk` 依 `PKG_BUILD_DEPENDS` 的 `golangX.Y/host` 解析,預設 1.26。
- packages feed(openwrt-24.10 @953b6d4)的 `lang/golang/golang-package.mk` 是**舊版單一版本設計**:沒有 `GO_BIN_PATH`,假設 `golang/host` 會在 hostpkg/bin 放 `go`。實際沒有 → PATH 上的**系統 `/usr/bin/go` 1.22.2**。
- packages feed 的 `golang-package.mk` 使用者(在 .config 裡)**恰好 4 個**:runc、containerd、dockerd、docker(`include ../../lang/golang/golang-package.mk`)。(v1 誤列 morse feed 的 mediamtx;實際安裝的是 OpenMANET 版 mediamtx,`package/feeds/openmanet/mediamtx`,用 OpenMANET 規則。)它們用到的 GO_* 變數/巨集(`GO_PKG*`、`GO_ARCH_DEPENDS`、`GO_PKG_VARS`、`GO_PKG_WORK_DIR_NAME`)在 OpenMANET 那份 .mk 全部有。
- **rootfs 裡所有 Go 執行檔**(兩板相同):
  - go1.22.2:docker、dockerd、docker-proxy、containerd、containerd-shim(-runc-v1/-v2)、ctr、containerd-stress、runc(10 個)
  - go1.26.4:openmanetd、openvlm、tailscaled、mediamtx(Pi4)— 都是 OpenMANET feed 的套件、用 OpenMANET 規則。
- 節點 04(1.5.2-wsl.1):`docker version` client/server go1.22.2、`runc --version` go1.22.2、openmanetd go1.26.4。

## 2. 問題
1. **不可重現**:Go 程式用哪個 Go 編,取決於 build 主機的系統 Go。(CI 的 workflow 用 apt 裝 `golang-go`,在 ubuntu-24.04 上剛好也是 1.22.2,所以目前 CI 與本機碰巧一致,但仍是外部依賴。)runc 自己的 README 要求 Go 1.22.x 時須 ≥1.22.4(runc#4233),我們用的 1.22.2 正好落在受影響範圍。
2. **安全**:容器工具鏈(OTS 節點的 docker/containerd/runc)是 EOL 的 Go 1.22 編的,之後 Go 標準函式庫的 CVE(net/http、crypto/tls、archive/tar…)都沒進。
3. **擋升級**:runc ≥1.2.8 / containerd 1.7.33 / docker 28+ 都要 go ≥1.23/1.24 → #247/#250 卡住。

## 3. 方案
**A(建議)**:`openmanet_setup.sh -i` 在 reset feeds、套 board patch 之後,把 OpenMANET 的 golang 建置規則同步到 packages feed:複製 `feeds/openmanet/lang/golang/{golang-package.mk,golang-values.mk,golang-compiler.mk,golang-host-build.mk,golang-build.sh,go-gcc-helper,go-strip-helper}` → `feeds/packages/lang/golang/`(`golang-version.mk` 只給 golangX.Y 目錄用,不需要)。review 證實 OpenMANET 這套規則與上游 **openwrt-25.12** 的逐位元相同 → A 等於「採用 25.12 的 golang 規則」;24.10 分支最新版仍沒有 GO_BIN_PATH,所以 bump packages pin 不能解決。代價:新規則的 `GO_BIN_PATH` 以 `PATH=<go>/bin:$(TARGET_PATH)` 取代 PATH,`staging_dir/hostpkg/bin` 會從 Go 套件的 PATH 中消失(25.12 上游同樣如此,可接受)。結果:所有 Go 套件走同一套(上游多版本 golang 的)規則,都把 `lib/go-1.26/bin` 放進 PATH。
- 不動 packages feed 的 `lang/golang/golang`(1.23 套件本身沒被安裝)。
- 每次 `-i` 先 reset 再同步,所以是確定性的(兩邊來源都是 pin 住的 feed)。
**B**:在 hostpkg/bin 補一個不帶版本號的 `go` → go-1.26 連結。改動最小,但舊規則 + 新 Go 混用,而且依賴 PATH 順序(hostpkg/bin 必須在 /usr/bin 前)。
**C**:改 runc/containerd/dockerd/docker/mediamtx 各自的 include 路徑指向 OpenMANET 的 .mk。要改 5 個 Makefile,上游一更新就衝突。
→ 選 A。

## 4. 防再發的閘(核心)
新增 `scripts/check-go-toolchain.sh <rootfs-dir>`,build-board **step 6**(manifest gate 之後)與 **CI build-firmware.yml** 的 manifest gate 步驟都執行(CI 不走 build-board):
- 掃 `build_dir/target-*/root-bcm27xx`(不需 root、不需 unsquashfs),用 build 樹的 go 的 `go version <dir>` 讀出每個 Go 執行檔嵌入的 buildinfo(amd64 host go 讀 arm64 binary 可行;OpenWrt strip 後仍讀得到)。
- 期望值 = `staging_dir/hostpkg/lib/go-<GO_DEFAULT_VERSION>/VERSION` 第一行(例:go1.26.4);`GO_DEFAULT_VERSION` 從 `feeds/openmanet/lang/golang/golang-values.mk` 讀。
- **任何一個 Go 執行檔版本 ≠ 期望值 → build 失敗**,列出檔名與版本。必須找到每一個預期的 Go 程式(dockerd、docker、containerd、runc、openmanetd、tailscaled、openvlm),防止掃描壞掉卻「通過」(只看「至少 1 個」不夠,openmanetd 永遠在)。
- 同步步驟本身另加 setup 後檢查:`feeds/packages/lang/golang/golang-package.mk` 與 OpenMANET 那份 cmp 相同,否則拒絕(放進既有的 `check-batman-adv-source.sh`?或新 `check-golang-source.sh`)。

## 5. Failure modes
| # | 情境 | 偵測 | 處置 |
|---|---|---|---|
| F1 | docker 27.3.1 / containerd 1.7.22 / runc 1.1.14 用 go1.26 編不過(Go 1.23 起的 `//go:linkname` 限制、vet 變嚴、deprecated API) | build | 個別加 `-ldflags=-checklinkname=0` 或升到相容版本(runc 本來就要升 → #247-2);不行就評估 golang1.24(bootstrap 已有)當這幾個套件的 Go |
| F2 | 編得過但執行行為變了(Go 1.2x 的 GODEBUG 預設、net/http、TLS 預設、GC/記憶體) | dogfood:OTS 6/6、canary、confinement、fault-injection、daily 全套 | 退回 |
| F3 | review 讀 `internal/godebugs/table.go` 證實:這幾個 go.mod(runc `go 1.18`、containerd/moby `go 1.21`)的 DefaultGODEBUG 帶 `containermaxprocs=0,updatemaxprocs=0`(1.25 的 cgroup-aware GOMAXPROCS **不會**啟用)、`tls10server=1,tlsrsakex=1,tls3des=1,tlsmlkem=0,x509negativeserial=1`(TLS 相容維持)。**不受 go.mod 控制的**:Green Tea GC 預設開(記憶體行為變;opt-out `GOEXPERIMENT=nogreenteagc`)、`x509sha1` 1.24 起移除(SHA-1 簽的憑證一律拒絕) | dockerd/containerd RSS 兩板 ≥30 分 vs 1.5.2 基準;OTS 6/6 | 若 Pi3 記憶體明顯變差 → build 時 `GOEXPERIMENT=nogreenteagc` |
| F4 | binary 變大 → rootfs/payload 變大(Pi3 512MB) | 比較 payload 大小、`df` | 評估 |
| F5 | 閘誤判(非 Go 檔案、strip 過沒 buildinfo、第三方預編 binary) | 閘只認 `go version` 讀得出 buildinfo 的檔;第三方預編 binary 若出現要明列例外 | 調整閘 |
| F6 | CI(GitHub runner)行為 | build-firmware.yml 走 setup -i → 一樣同步;閘在 build-board(CI 不走 build-board?)→ 另把閘加進 build-firmware.yml | |
| F7 | 同步讓 packages feed 的其他(未選)Go 套件規則改變 | 未選的不 build,無影響;日後選新的 Go 套件也會一致用 1.26 | — |
| F8 | 舊 build 樹增量 build 不會重編 Go 套件(OpenWrt 重編判斷只 hash 套件自己的目錄,不含 include 的 .mk 和 Go 本身)→ 還是舊 binary | build-board step 5:規則或 staged Go 變了就 `make package/<p>/clean` 所有選中的 Go 套件;閘也會擋 | — |
| F9 | 已初始化的舊樹不會跑 `-i` → 永遠不同步 | build-board:`check-golang-rules.sh` 失敗就觸發 `-i`,setup 後仍失敗就拒絕 | — |

## 6. Dogfood / 驗證
1. 兩板 build 通過新閘:rootfs 內所有 Go 執行檔 = go1.26.4;manifest 對 1.5.2 只差預期(版本號、可能的 binary 內容)。
2. **04(OTS)先**:OTA → OTS 6/6、`docker version` server/client = go1.26.4、`runc --version` go1.26.4、canary、confinement-98、drift-156、flashgo-159;fault-injection F1/F2/R2(R1 已知)。
3. 02、03 → 全套 daily-validation(含 destructive)+ rejoin;03 上 docker(payload host)可跑 canary。
4. 觀察 04 OTS ≥30 分(容器重啟次數、記憶體)。
5. 版本號 1.5.3-wsl.1。

## 7. 回退
節點:A/B(上一槽 1.5.2-wsl.1;Batman-P 有 1.5.2-wsl.1 / 1.5.1-rel.1 payload)。build:revert setup 同步步驟 + 閘。

## 8. Review findings 處置(PASS-WITH-CHANGES)
| # | 內容 | 處置 |
|---|---|---|
| MAJOR-1 | 增量 build 不會重編 Go 套件 | build-board step 5 依 `logs/go-rules-<board>.stamp`(規則 + staged Go 的 hash)在變更時 clean 所有選中的 Go 套件;stamp 在 Go 閘通過後才寫 |
| MAJOR-2 | 已初始化的樹不會跑 `-i` | `check-golang-rules.sh` 失敗 → `-i`;setup 後仍失敗 → 拒絕 |
| MAJOR-3 | mediamtx 事實錯誤 | §1 更正:packages 規則使用者恰好 4 個 |
| MAJOR-4 | F1 實編 | reviewer 用 go1.26.4 + musl cgo 實編 runc 1.1.14(含 seccomp tag)、containerd 1.7.22(6 個指令)、moby/cli 27.3.1 全部成功,無 linkname/vet 錯誤;正式 build 兩板通過 |
| MAJOR-5 | F2/F3 事實 | §5 F3 改寫(GODEBUG 由 go.mod 鎖住 TLS/maxprocs;Green Tea GC 與 x509sha1 移除不受控)→ dogfood 量 RSS |
| MINOR-6 | GO_BIN_PATH 取代 PATH | §3 記錄代價(與 25.12 上游相同) |
| MINOR-7 | 閘設計 | 逐一檢查必要 Go 程式;`go version <dir>`;掃 build_dir rootfs;CI 也跑 |
| MINOR-8 | CI 也是 apt go 1.22.2 | §2 更正;不複製 golang-version.mk |
| MINOR-9 | dockerd Makefile 用 `$(KERNEL_SECCOMP)` 少了 `CONFIG_` 前綴 → dockerd 沒帶 seccomp build tag(既有) | 另開單 |
