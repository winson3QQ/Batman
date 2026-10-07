# #264 OTS eud_handler 遺失 CoT:patch 進 batman/ots image

狀態:設計 v1(待 review)· 2026-10-07 · 範圍:`deploy/ots/`(Dockerfile、新 patch 檔、profile.yaml → ots.manifest)、fleet 上的 tenant image

## 0. 背景(已證實的部分)
上游 OpenTAKServer 1.7.13(= master)的 `opentakserver/eud_handler/EudHandler.py`:
- **機制 A(已證實,確定性重現)**:`handle()` 第 108–127 行。一次 `recv` 裡完整事件後面跟著半筆時,半筆在 ParseError 分支被 `cot = c` 保留,但隨即被 `cot = ""` 清掉;下一次 recv 開頭剩下的那半段沒有 `<event`,被默默跳過。
  - daily `ots-cot-e2e-264` 的 P2 每次都是 B 0/20。
  - P3(真實的合併寫入)遺失約 19–35%。
- **機制 B(log 已證實,原因是推論)**:AMQP 連線因 `missed heartbeats from client` 被 broker 關掉,關閉期間的 CoT 丟失;`publish_cot` 把它們放進 `cached_messages`,但 connection 不會重建,所以永遠不會補送。
  - `pika.SelectConnection` 的 ioloop 跑在另一條執行緒,`handle()` 卻直接從 socket 執行緒呼叫 `basic_publish`。pika 文件明載不是 thread-safe。
- **附帶**:`close_connection()` 在 guard 之前就 `basic_publish`,channel 關掉時會丟 `ChannelWrongStateError`(上游 brian7704/OpenTAKServer#404)。

## 1. 修法(一個 patch 檔 `deploy/ots/patches/eudhandler-264.patch`,在 Dockerfile 裡 `git apply`)
**P-A 正確保留不完整的事件**(handle):
```python
cot += data.decode("utf-8")
while True:
    m = re.search(r"</event>|</auth>", cot)
    if not m: break
    chunk, cot = cot[:m.end()], cot[m.end():]     # 一個完整訊息;剩下的(可能是半筆)留在 cot
    try:
        if "<event" in chunk:   fromstring(chunk[chunk.index("<event"):]); self.handle_cot(chunk[chunk.index("<event"):])
        elif "<auth>" in chunk: fromstring(chunk[chunk.index("<auth>"):]); self.handle_auth(chunk[chunk.index("<auth>"):])
    except ParseError as e:
        self.logger.error(f"Failed to parse: {e}")    # 真的壞掉的那一筆才丟,不影響後面的
if len(cot) > MAX_PENDING: cot = ""; log            # 防止沒有結尾標籤的資料無限長大(1 MiB)
```
- 和上游的差異:上游把 `</event>` 拿掉後再補上,所以 `<?xml …?>` 前綴、事件之間的空白都包含在 `c` 裡。新版從 `<event` / `<auth>` 開始截取,前面的 XML 宣告和空白直接丟掉。`fromstring` 遇到中間有 `<?xml` 會失敗,上游靠「每段剛好從 decl 開始」才沒出事。
- `handle_cot` 收到的字串格式和上游一樣(以 `<event` 開頭、`</event>` 結尾)。

**P-B 跨執行緒 publish 改為 thread-safe + 斷線重連**:
- 新增 `_publish(exchange, routing_key, body, props)`:
  - 從 handler 執行緒呼叫時,用 `self.rabbit_connection.ioloop.add_callback_threadsafe(functools.partial(self._do_publish, …))` 交給 ioloop 執行緒。
  - `_do_publish` 在 ioloop 執行緒內檢查 `channel.is_open`;沒開就放進 `cached_messages`(改成 instance 變數,上游是 class 變數)。
- 所有 `basic_publish`(`publish_cot` 兩處、`on_channel_open` 的 socketio、`close_connection`、第 749 行)都改走 `_publish`。
- `on_close`(connection 關閉):如果 handler 還沒 `shutdown`,**不要**停 ioloop、不要讓 handler 結束;改成排程 2 秒後重建 `SelectConnection`(新的 ioloop 執行緒)。重建成功時 `on_channel_open` 會補送 `cached_messages`(上游已有這段邏輯)。最多重試 N 次(每次間隔加倍,上限 30 秒);仍失敗就照上游行為 shutdown。
- `on_channel_close`:上游會把整個 handler `shutdown` 掉(斷掉 TAK client)。改成:channel 關閉時如果 connection 還開著就重開 channel,不要踢掉 client。
- `cached_messages` 加上限(例如 1000 筆),超過就丟最舊的並記 log,避免 broker 長期不在時記憶體無限成長。

**P-C close_connection guard**:先檢查 channel 開著才 publish disconnect 訊息;否則跳過(對應上游 #404)。

## 2. image 與交付
- 新 tag:**`batman/ots:1.7.13-p264-arm64`**(不覆蓋舊 tag;回退到 1.5.4 時,舊 slot 的 manifest 仍然指向舊 tag,舊 image 留在節點上)。
- `Dockerfile`:pip install 之後 `COPY patches/ /tmp/patches/` + `RUN cd /app/venv/lib/python3.13/site-packages && git apply /tmp/patches/eudhandler-264.patch`。git 在 python:3.13 image 裡本來就有(pip `git+` 需要)。
- build 時加一步:對 patch 後的 `EudHandler.py` 跑 `python -m py_compile`,並 grep 確認上游那行 `cot = ""` 已不存在(防止上游檔案變了導致 patch 沒套上卻沒發現 — `git apply` 失敗本來就會讓 build 失敗)。
- `profile.yaml` 改 tag → 用 `scripts/profile-to-manifest.py` 重新產生 `ots.manifest`(不手改)→ golden 會在 1.5.5 build 裡帶進 rootfs。
- 交付:image tar 放到 04 的 `/opt/batdata/apps/opentakserver/images/`(firstload 下次開機載入,#159/#216 的正式路徑)→ OTA 1.5.5。firstload 載入期間的 latch 不擋 commit(R2)。
- 同時也送上游:Issue + PR 到 brian7704/OpenTAKServer。**這是對外發布,要先問你**,不在本設計自動執行。

## 3. Alternatives(不採用)
- **在 compose 層加 TCP proxy 重組封包**:治標,機制 B 不解決,又多一個元件。
- **只修 P-A**:機制 B 在 30 分鐘 soak 裡仍會掉(heartbeat 關閉 1–3 次)。
- **換成 `BlockingConnection` + 每次 publish 前 `process_data_events`**:改動更大,而且 eud_handler 也要消費(`on_message` 轉送給 client),BlockingConnection 不適合。
- **等上游修**:上游 master 還沒修,時間不可控;先在我們的 image 打 patch,同時送上游。

## 4. Failure modes
| 情況 | 結果 |
|---|---|
| 上游檔案改版,patch 套不上 | `git apply` 失敗 → build 失敗(不會默默出一個沒修的 image) |
| 重連一直失敗(rabbitmq 掛掉) | 有上限的重試 → 照上游行為 shutdown handler;cached_messages 有上限 |
| client 送超大或沒有結尾的資料 | 1 MiB 上限,清掉並記 log(上游沒有上限) |
| `add_callback_threadsafe` 在 connection 關閉時呼叫 | pika 會丟例外 → `_publish` 捕捉,放進 cached_messages |
| 新 image 沒放到 p6 就 OTA 1.5.5 | guardian 起不來 OTS(image 不存在)→ autocommit 的 tenant drift gate 不 commit → deadline revert 回 1.5.4。payload-config-golden suite 也會 FAIL「image not loaded」 |
| SSL handler(EudHandlerSSL)| 繼承 EudHandler,`handle()` 也是同一份 → 一起修好。要另外驗證 8089 |

## 5. 測試計畫
- **離線**:
  - 把 patch 後的 `handle()` 迴圈抽出來,用 `p2check.py` 的切法跑:半筆/半筆、A+半B/半B、1024/1460/333 bytes 切段 → **全部 100% 入庫**;有 XML 宣告和沒有的都測。
  - 真的壞掉的一筆 → 只丟那一筆。
  - 超過 1 MiB → 清掉。
- **真機(04)**:
  - `ots-cot-e2e-264`:P1/P2A/**P2B 20/20**/**P3 100/100**。
  - 30 分鐘 soak `soak-cot-264`:**送出 = 入庫**、rabbit `missed heartbeats` = 0(或有發生但重連後沒有遺失)。
  - 人為重啟 rabbitmq 一次 → eud_handler 重連、client 沒被斷、cached 的 CoT 補送入庫。
  - SSL 8089:用 ATAK/iTAK 實機或 openssl s_client 送 CoT。實機這部分需要你操作手機,沒做就標「沒測到」。
- 通過後,把 known-failures 裡 #264 的四行移除(之後再掉就是新 FAIL)。

## 6. v2 — review v1 判 FAIL;重新界定範圍(取代 §1 P-B、§2 交付、§5 測試)

**範圍拆成兩階段**:
- **第一階段(本設計,進 1.5.5)**:P-A + P-C + **所有 channel 操作改在 ioloop 執行緒**(只修執行緒安全,**不做重連**)+ 結束前排空。
- **第二階段(另開單)**:斷線重連。前提是先能確定性重現機制 B(`rabbitmqctl close_connection` 或 bench 調低 heartbeat 加 `docker pause rabbitmq`),並驗證上行、下行、不斷線、超過上限時踢掉 client 四件事。v1 的重連設計有 review 指出的 #9–#12 問題:
  - 送進已停 ioloop 的 callback 會默默丟失;
  - 重連時開了第二個 ioloop;
  - 缺 `on_open_error_callback`;
  - 重連後沒重新訂閱,client 變成收不到;
  - channel 重開沒有退避。

  這些全部留到第二階段,重新設計。

**排除一個替代原因(review #16)**:04 的 rabbitmq log 沒有 `memory resource limit alarm`,`rabbitmq-diagnostics status` 的 Alarms 是 `(none)`,記憶體 0.13 GB / 警戒 0.3 GB。機制 B 不是 memory alarm 擋住 publisher 造成的。

**P-A v2**(review #1–#5)
- 緩衝區改存 **bytes**:`buf += data`;用 `buf.find(b"</event>", scan)` / `b"</auth>"` 找結尾,`scan = max(0, 舊長度 − 8)`,不每次從頭掃(#3)。
- 只對**完整的一段**做 `decode("utf-8", errors="replace")`,UTF-8 多位元組字元被切開時不會丟 UnicodeDecodeError、也不會斷線(#1)。
- 起點用 `rfind(b"<event", 0, end)` / `rfind(b"<auth>", …)`(#4):前一筆壞掉、少了結尾時,不會連帶丟掉後面好的那筆。
- 每處理完一段就檢查 `if self.shutdown: break`(#2);`close_connection` 改成可重複呼叫(冪等,用 `self._closed` 旗標)。
- 1 MiB 上限保留,超過時清掉並記 log。
- 不動 `pong()`(#7,上游另一個 bug,與本單無關)。
- build 檢查改成檢查正向標記 `# BATMAN-264-PA` 是否存在(#5)。

**執行緒安全 v2**(review #8、#13)
- 新增 `self._io(fn, *args)`:用 `self.rabbit_connection.ioloop.add_callback_threadsafe(functools.partial(fn, *args))`,把**所有**channel 操作交給 ioloop 執行緒,包括:
  - `basic_publish`(publish_cot ×2、close_connection、on_channel_open 的 socketio、第 749 行);
  - `parse_device_info` 的 `queue_declare` / `queue_bind` / `basic_consume`;
  - `unbind_rabbitmq_queues`;
  - `channel.close()`。
- **publish 的 body 在呼叫端執行緒先組好**(`json.dumps(...)`,包括 `self.user.id`),再交給 ioloop(Flask-SQLAlchemy 的 session 是 thread-local,#8)。
- ioloop 已經停了的時候(`on_close` 之後):`_io` 不再排程,直接走上游原本的「channel closed」路徑(記 log、cache、handler shutdown → client 斷線,ATAK 會自己重連)。**行為和上游一致,只是不再從錯的執行緒碰 channel。**
- **結束前排空**(#13):`close_connection` 排程「publish disconnect → channel.close」之後,用 `threading.Event` 最多等 2 秒,等 ioloop 回報完成或 connection 已關,才讓 `handle()` 回傳(子行程隨後 `os._exit`)。
- **已知限制**(#15):沒有 publisher confirms。heartbeat 斷線之前已經寫進 socket 的訊息救不回來。第二階段再評估 `confirm_delivery`(代價是可能重複 CoT)。

**交付 v2**(review #17–#19)
- `deploy/ots/Dockerfile.p264`:`FROM batman/ots:1.7.13-arm64`,只加一層:`COPY` patch → `git apply` → `py_compile` → 檢查 `# BATMAN-264` 標記。依賴完全不變,docker layer 共用,image 只多幾 KB。
  - firstload 會把 tar `mv` 到 `images/loaded/` 保留,所以 p6 上仍會多一份約 1 GB 的 tar。04 的 p6 剩約 20 GB,可以接受;文件註明。
  - 匯出時只匯出新 tag:`docker save` 會包含所有 layer,tar 不會比較小,只是載入時 layer 已存在,很快。
- 新 tag `batman/ots:1.7.13-p264-arm64`。`profile.yaml` 的 4 個 app 容器改用新 tag。兩處 `chown_image: batman/ots:1.7.13-arm64`(ots-db / rabbitmq 的 volume chown helper)**一起改成新 tag**,舊 tag 只在回退到 1.5.4 時才需要。
  - 用 `scripts/profile-to-manifest.py` 重新產生 `ots.manifest`;`images/manifest.sha256` 跟著更新;flash-and-go 打包新卡時的 image 清單也要更新。文件逐一列出這些路徑。
- 回退 1.5.4:舊 slot 的 golden manifest 指向舊 tag,舊 image 還在 → 可行(review #19 已確認)。

**測試 v2**
- **離線**:用 patch 後的 `handle()` 原樣複製,測:
  - 半筆/半筆、A+半B/半B;
  - 1024 / 1460 / 333 bytes 切段;
  - **中文 callsign 逐 byte 送**(每次 recv 1 byte);
  - `<auth>` 和 `<event>` 在同一次 write;
  - 壞掉的一筆後面接好的一筆(只丟壞的);
  - 超過 1 MiB。
- **真機 04**:
  - `ots-cot-e2e-264`:P1 / P2A / **P2B 20/20** / **P3 100/100**;
  - 8089 用 `openssl s_client` 跑 P2B、P3;
  - 中文 callsign 逐 byte 送;
  - 第二個 client 收得到(下行):ATAK/iTAK 實機,或用 nc 當第二個 EUD 看有沒有收到轉送。沒做就標「沒測到」。
- **30 分鐘 soak**:
  - `soak-cot-264` 送出 = 入庫;
  - 記錄 heartbeat 斷線次數:如果第一階段後歸零,就是支持「跨執行緒卡住」推論的證據;沒歸零就交給第二階段;
  - 記錄 eud_handler 子行程的 RSS。
- known-failures:P2B 那行在通過後移除。P3 / soak 那兩行**只在**真機確認 0 遺失後移除;如果機制 B 仍有遺失,保留並改指向第二階段的新單。

## 7. v2.1 — v2 複審(PASS-with-changes)併入
- **(a) ioloop 是否已停**:不看 `is_closed/is_closing`。ioloop 執行緒入口改成自己的 `_run()`:`try: ioloop.start()` / `finally: self._loop_dead = True; self._drained.set()`。`_io` 在 `self._loop_dead or not self.iothread.is_alive()` 時走上游的「channel closed」路徑。同時補上 `on_open_error_callback`,記 log 並觸發 shutdown(上游沒有,第一次連線失敗時 ioloop 執行緒會直接死掉)。
- **(b1)** `close_connection` 如果是在 ioloop 執行緒被呼叫(`on_message` 例外那條路),直接執行,**不等 Event**。
- **(b2)** 排空用的 Event 只在 `on_channel_close`(收到 CloseOk,前面的 frame 都已送出)、`on_close` 或 `_run` 的 finally 才 set,不在 `channel.close()` 呼叫完就 set。
- **(c)** `parse_device_info` 的 DB 查詢留在 handler 執行緒,結果交給單一 callback `_subscribe(uid, callsign, routing_keys)`。在 ioloop 裡才檢查 channel:開著就 declare/bind/consume;還沒開就記成待辦,`on_channel_open` 時補做(順便修掉上游「一連上就送第一筆、AMQP 還沒開 → 永遠不訂閱」的 bug)。`bound_queues` 排程 unbind 時先複製一份 list。
- **(d1)** build 不用 docker-container driver 的 `batman-arm64` builder(它看不到本機 image store,`FROM batman/ots:1.7.13-arm64` 會去 docker.io 拉而失敗):改 `docker buildx build --builder default --platform linux/arm64 --load`;匯出用 `docker save --platform linux/arm64`(避開 Docker 29 的 digest bug)。
- **(d2)** build 前比對 WSL 本機 `batman/ots:1.7.13-arm64` 的 image ID 和 04 上的相同;不同就停,不出貨。
- chown_image 改新 tag:接受。manifest 變了,ots-db / rabbitmq 可能被判 drift 而重建(OTA 本來就會重開機);實作時確認 chown-once 對已存在的 volume 不會重跑。
- **測試補兩案**:在 ioloop 執行緒觸發 close(client 中途斷線)不會固定延遲 2 秒;先停 rabbit 再讓 client 連入,ioloop 死掉時立即返回、不卡住。

## 8. v3 — 交付方式改成 golden bind-mount(取代 §6「交付 v2」與 §7 d1/d2、chown_image 那條)

**發現的缺口(v2 兩輪 review 都沒抓到)**:已部署節點只走 OTA(`sysupgrade -n`)。OTA 只換 rootfs,**p6 上的 image tar 不會跟著送**。`build-ab-image.sh` 的 `P6_PAYLOAD` 只在工廠燒卡時生效。
- 如果 manifest 改指 `batman/ots:1.7.13-p264-arm64`:OTA 後,開機時 `95-batman-storage` 的 golden refresh 會把新 manifest 寫進 p6,guardian 再跑 `payload-run`,先 `docker rm -f` 全部 → `docker run --pull=never <新 tag>` 失敗 → OTS 全黑。
- 之後 autocommit 的 canary 會不會擋下來要看 tenant 健康檢查,不能指望它。就算擋下來,也等於「1.5.5 在已部署節點上裝不上」。
- 要先人工把 800 MB tar 搬到每台 p6 才能 OTA,這是運維地雷,而且 tar 會永久留在 `images/loaded/`。

**v3 做法**:image 不動,仍是 `batman/ots:1.7.13-arm64`。修補後的**單一檔案**跟 rootfs 一起送,用 bind-mount 蓋掉 image 裡的檔案。
- repo 新增 `deploy/ots/patches/EudHandler-264.py`:由 `make-eudhandler-264.py` 對 upstream 1.7.13 產生的完整檔案,約 40 KB,GPL-3.0(上游授權,檔頭註明)。
- `batman-payload-ots` 的 Makefile 把它裝進 `/usr/share/batman/payload-golden/opentakserver/EudHandler-264.py`(0644)。開機時 golden refresh 會照現有機制、冪等地把它寫進 p6 的 `apps/opentakserver/`。
- `profile.yaml`:`ots_eud_handler`、`ots_eud_handler_ssl` 兩個容器加上
  `mounts: [{src: EudHandler-264.py, dst: /app/venv/lib/python3.13/site-packages/opentakserver/eud_handler/EudHandler.py, ro: true}]`。
  - 再用 `profile-to-manifest.py` 重新產生 manifest,會多一行 `MOUNT EudHandler-264.py:…:ro`。
  - `payload-run` 已經支援相對 src(rabbitmq-extra.conf 走的就是這條路)。
- **不需要 p264 image、不改 chown_image、不更新 images/manifest.sha256**。
- 刪掉 `Dockerfile.p264` / `build-p264.sh`,改用 `patches/check-eudhandler-264.sh`(開發機用):從本機 `batman/ots:1.7.13-arm64` 取出 upstream 檔,確認 sha256 等於 pin 值;再確認 make 腳本產出的結果和 commit 進來的 `EudHandler-264.py` 完全一致;最後跑離線測試。

**一致性與防漂移(CI 可跑,不需要 image)**
- `patch -R` 從 `EudHandler-264.py` 加 `eudhandler-264.patch` 還原出 upstream,sha256 必須等於 pin 值 `UPSTREAM_SHA256`(寫在 make 腳本與 check 腳本裡)。這證明 commit 的檔案就是「upstream 加上這個 patch」,不是手改過的。
- 離線測試 `test-eudhandler-264.py` 在 CI 對 commit 進來的檔案跑。
- **image 升級防呆**:CI 檢查 profile 裡有 `EudHandler-264.py` mount 的容器,image ref 必須是 `batman/ots:1.7.13-arm64`。升 OTS 版本卻忘了處理 overlay,CI 會紅燈,不會靜默地用舊檔蓋掉新版。

**回退**:A/B revert 到 1.5.4 時,舊 slot 的 golden manifest 沒有 MOUNT 行。golden refresh 會把舊 manifest 寫回 p6,payload-run 重建容器 → 回到上游原檔。p6 上會殘留 `EudHandler-264.py`(refresh 不刪檔),沒有人 mount 它,無害。

**生效時機**:manifest 只在開機時被 refresh,guardian 在那時跑 payload-run,容器都會重建。所以 OTA 重開機後**一定**生效,不存在「容器沒重建、舊檔還在跑」的情況。

**唯讀 rootfs 與 pyc**:容器帶 `--read-only`,site-packages 底下的 `__pycache__` 寫不進去。Python 比對 pyc 標頭的 mtime/size 不符時,會改在記憶體裡重新編譯,不會用到舊的 pyc。eud 每個連線都是 fork 出來的,模組只在父行程 import 一次,成本可忽略。

**真機驗證(2026-10-07,04,已做)**
- 原版 image 加完整 `ots.hardening.env`(`--read-only`、`cap-drop ALL`、uid 1000),bind-mount 修補檔:
  - 容器內 `m.__file__` 指向 site-packages 原路徑,`MAX_PENDING` = 1048576(確認載入的是修補版);
  - e2e P1 30/30、P2A 20/20、**P2B 20/20**、**P3 100/100**;RSS 116 MiB(原版 139 MiB)。
- 同一輪對照:原版 172.20.0.10 是 P2B **0/20**、P3 **82/100**;p264 image 是 170/170。
- 測試容器與 DB 測資都已清除,04 仍是 6/6。

**Failure modes(新增)**
- F8:golden refresh 寫 p6 失敗(p6 唯讀或已滿)→ 檔案不存在 → `docker run -v 不存在的路徑:...` 會讓 docker 在 host 上**建一個同名空目錄**再 mount → 容器內 EudHandler.py 變成目錄 → import 失敗 → eud 全掛。
  - **對策**:`payload-run` 在 MOUNT 的相對 src 不存在時 `die`(拒絕帶著錯的 mount 起容器),並記 log;`chk_98`/canary 會抓到 eud 沒起來。
  - 另一個選項是「src 不存在就跳過 mount、退回上游原檔」,但這等於**靜默降級**到有 bug 的版本,不採用。
- F9:有人手動在 p6 改了 `EudHandler-264.py` → 下次開機 golden refresh 用 cmp 比對後覆寫回正本。行為和其他 golden 檔一致。
- F10:流量路徑上,8088 / 8089 共用同一個檔案。SSL 版沿用 `EudHandler.handle()` 的路徑,實作時必須用 `openssl s_client` 實測 8089。

## 9. v3.1 — v3 review(FAIL)併入

**Finding 1 已上機證實(04,2026-10-07)**:這次開機約在 01:04:35,但 6 個容器的 `Created` 都是 01:01:00–01:01:18(比這次開機早),`StartedAt` 是 01:06 → 是 dockerd(live-restore + unless-stopped)把舊容器**原封不動復活**的,guardian 沒有重建。§8 說的「OTA 後一定生效」是錯的。這也是 payload-config-golden 本身既有的潛在 bug:golden 改了 manifest,不會反映到已經在跑的容器上。另開單追蹤。

**修法(通用,payload-manager 層級)**
- **G1 設定指紋 label**:`payload-run --cfg-hash <tenant>` 輸出一個 sha256,算的是:manifest 內容 + 每個相對路徑 MOUNT src 的檔案內容 + 每個 HARDEN env 檔內容,依固定順序串接。
  - payload-run 起每個容器時都加 `--label batman.cfg=<hash>`。
  - guardian:`_need=1` 的條件改成「任一容器沒在跑 **或** 它的 `batman.cfg` label ≠ 現在重算的 hash」。缺 label(舊容器)也視為不符。
  - 1.5.5 第一次開機會因為舊容器沒有 label 而整組重建一次,之後收斂。golden 再有變動也會自動收斂。
  - secrets 內容不納入 hash(輪替 secret 不在本單範圍,文件註明)。
- **G2 `stop_service` manifest 路徑**:改成和 payload-run 一樣 glob `*.manifest`(原本寫死 `$_T.manifest`,OTS 實際檔名是 `ots.manifest`,stop 一直是 no-op)。
- **G3(F8 改寫)MOUNT 改用 `--mount type=bind,source=…,target=…,readonly`**:來源不存在時 docker 直接報錯,不會自動建目錄。
  - 另外先檢查 `[ -f "$src" ]`;不是一般檔(不存在或是目錄)時,**只跳過這個容器**(`FAILED=1`、記 log),其他容器照常起來。guardian 的 liveness 會把它標成 DRIFT → autocommit 拒絕 → deadline revert。
  - `refresh_payload_config` 在 `mv` 之前:如果 `$dst/$b` 是目錄、golden 是檔案,先 `rmdir`(只刪空目錄),修好舊版 `-v` 留下的毒目錄。
  - 這會不會讓 1.5.4 回退後壞掉?1.5.4 的 payload-run 仍用 `-v`;檔案存在就沒事。只要不手動刪 `EudHandler-264.py` 就不會出問題,文件註明「有容器引用時不可刪」。
- **G4 端到端一致性檢查(daily `chk_golden` 加項)**:
  - manifest 裡每一行 MOUNT,實際容器的 `docker inspect .Mounts` 都要有對應的 Source=`$dst/<src>`、Destination、RW=false,而且 src 是一般檔案;
  - 每個容器的 `batman.cfg` label 都要等於 `payload-run --cfg-hash`;
  - 兩個 eud 容器裡 `grep -c BATMAN-264-PA` 要有命中;
  - **image 原檔指紋**:`docker run --rm --entrypoint sha256sum batman/ots:1.7.13-arm64 <path>`(不帶 mount)要等於 `UPSTREAM_SHA256`。這是對付「tag 一樣但 image 被重 build」(review 5d)。
- **G5 CI**:
  - `payload-manifest-sync.yml` 的 paths 加上 `deploy/ots/patches/**`、`scripts/profile-to-manifest.py` 已有;
  - CI 跑三件事:(1) `patch -R` 還原出 upstream,驗 `UPSTREAM_SHA256`;(2) 對還原出的 upstream 跑 `make-eudhandler-264.py`,結果要和 commit 的檔案 cmp 一致(防止 generator 過期);(3) 離線測試;
  - 新增反向檢查:manifest 裡每個相對 MOUNT src,`feed/batman-payload-host/Makefile` 都要有安裝(5c);
  - `UPSTREAM_SHA256` 只存一處:`deploy/ots/patches/UPSTREAM_SHA256`。
- **G6 授權**:
  - `EudHandler-264.py` 保留上游 GPL-3.0 檔頭,另加 SPDX 和「Modified by Batman for #264, 2026-10-07」(由 make 腳本產生,patch -R 往返仍成立);
  - 新增 `deploy/ots/patches/README.md` 說明這三個檔是 GPL-3.0;
  - repo 根 README 的 License 段加上「MIT except where noted」。
- **G7 SSL**:8089 用 `openssl s_client` 跑 P2B/P3,列為 merge gate;daily 加 8089 版本(需要 client cert,用 OTS CA 簽一張測試 cert,CN 對應測試 user)。

**回退描述更正**:回到 1.5.4 時,1.5.4 的 guardian 沒有 G1,已經帶 mount 的容器會被 dockerd 復活,繼續跑修補版。這在功能上無害,但做 A/B 比對或 bisect 時要知道這件事。再升回 1.5.5 時,label 會收斂。

**上機驗收(merge 前必做)**:
- 04 做真正的 `sysupgrade -n` 1.5.4→1.5.5:兩個 eud 容器的 `Created` 晚於開機時間、Mounts 正確、容器內有 marker、label 一致、e2e 8088/8089 P2B 20/20、P3 100/100;
- 再回退一次:確認 1.5.4 下 OTS 6/6 健康;
- 再升回 1.5.5:確認 label 收斂。

## 10. v3.2 — §9 複審(PASS-with-changes)併入

- **R1 commit 期限**:OTA 驗收時,記錄 payload-run 開始、payload-run 結束、COMMITTED 三個時點的 uptime。目標是 300s 內 commit(期限 600s 的 2 倍餘裕)。另外做兩件事:
  - (b) guardian 在 G1 重建期間設 `/tmp/batman-payload-<t>.converging`,watchdog 的 bounded deferral 比照 first-load 認這個 latch;
  - (c) `prechown` 只在「volume 剛建立」或「頂層目錄 owner 不對」時才 `chown -R`。判斷在 vehicle 容器裡用 `find -maxdepth 0 -user/-group` 做,host 的 busybox 沒有 stat。
- **R2 liveness**:「活著」的定義改成 `.State.Status == running` 且 `.State.Restarting == false`。guardian 的 `_need` 和 verdict 兩處都改。只比較一次就好:目前 Running=true 的容器在 restart backoff 時也是 true,這次只把 Restarting 擋掉;RestartCount 跨 tick 的判斷另開單。
- **R3 graceful stop**:`stop_service` 改成依反向順序 `docker stop -t 20`,之後才 `rm`。驗收加兩項:乾淨 `reboot` 一次(pgdata 完好、沒有 crash recovery),以及 `service … restart` 一次。
- **R4 hash 編碼**:
  - 輸入依序是 `cfg-v1`、manifest 的 `sha256sum`、每個 HARDEN 與相對 MOUNT src 的 `sha256sum`(檔案不存在就寫 `MISSING <name>`)、每個 IMAGE 的 `docker image inspect -f {{.Id}}`(不存在就寫 `MISSING`);
  - 把整份清單再做一次 sha256;
  - 版本字串 `cfg-v1` 寫死在 payload-run 裡,payload-run 的渲染邏輯一改就要 bump。
- **R5**:guardian 一律呼叫 `payload-run --cfg-hash`,不另外實作;補 `.gitattributes`(`deploy/ots/patches/* -text`、`*.manifest eol=lf`)。
- **R7**:文件註明 reconcile loop 只告警、不重查 label;label 不一致的偵測交給 G4。
- **R8**:毒目錄修復先刪 `"$dst/$b"/.$b.tmp.*`,再 `rmdir`,並記 log;`--mount` 的路徑若含逗號就拒絕。
- **R9**:G4 檢查 image 原檔 sha 時,用 `docker create` + `docker cp` + `docker rm`,不執行任何東西。
