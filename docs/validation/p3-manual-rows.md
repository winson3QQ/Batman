# P3 測項裡由人執行的列(由 `scripts/dv/gen-p3-units.py --manual` 產生,不要手改)

來源:`docs/design/254-h4-harness.md` 附錄 A + `scripts/dv/data/p3-how.tsv`。主機端沒有能經 provd 開擁有者連線的測試
client(#254 留言 6697703967,使用者 2026-11-07 決定不寫),所以這些列要用**正式的 provisioning app / 手機**執行。

- 執行時機:app 第一版之後,以及每次發版前。前置與記錄格式同 `h4-manual-cases.md` 第 0 節與「紀錄格式」。
- 「部分」= 該列的自動化部分由測項跑;表中「人要做的」是剩下的那一段。
- 沒有證據(app 截圖、節點唯讀輸出、時間)= 沒跑,不算 PASS。


## `prov-p3-routes-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| RT1 | §8 動詞 × 角色 × owner-op | 部分 | anonymous role over an NX session; owner / member roles need an owner session through provd | 碼與 reason 逐一相等(`p3-expect.tsv`) |
| RT1h | 同上,HTTP | 全部 | owner session over HTTP | 同上 |
| RT2 | key 20 經 HTTP → `E_U{2: 19}` | 全部 | owner session over HTTP | — |

## `prov-owner-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| OW1 | add | 部分 | the add and the owner list by the helper; Hx's auth/owner needs a session through provd | Hx `auth/owner` 成功 |
| OW3 | remove 切 BLE + HTTP | 全部 | BLE + HTTP sessions of an owner being cut | 時序:Hx 先開一條 BLE session(Windows 對同一台節點只能有一條 BLE 連線)與一條 HTTP session(手機);H0 經**另一條 HTTP session** 送 `owner/remove` Hx(P3 的 HTTP 有 2 個 slot,剛好用完)。斷言:Hx 的兩條 session ≤ 5 s 都 Closed;04 的 provd log 有兩行 `session revoked reason=`(`server.go:639`,不受限流);BLE 斷開後 ≤ 15 s 出現 `adv registered reason=disconnect`(`bluez.go:776-781`);Hx 重新交握 → peer 分類為 `fake`(加上 §4.2 的 fake path 佐證);`adv_owner_key` 輪替 |
| OW6 | §7 遺失手機:psk 失效 | 全部 | psk_owner handshake of a removed owner | 被 remove 的 Hx,psk_owner 交握失敗 |

## `prov-settings-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| ST6 | 已配對注入失敗 → 舊帳密 | 部分 | hostapd back on the old credentials by the helper; the phone being authorized needs the phone | hostapd = C0;手機 `authorized` |

## `prov-status-diag-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| SD2 | 成員只拿摘要 | 全部 | the member role is provd's | 只有摘要的欄位 |
| SD3 | ro 10/s × 10 分 | 全部 | the ro connection and its rate are provd's | 沒有 `cfgsave-lock.busy`;沒有 ERate;04 端廣播在 |
| SD4 | bundle | 部分 | the bundle's content by the helper; chunked retrieval > 64 KiB is provd's | > 64 KiB、`tar t`、原值 grep = 0 |
| SD5 | handle 跨 session | 全部 | handles across sessions are provd's | 15 |

## `prov-http-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| HT1 | 正向 | 全部 | a client on the phone AP completing a handshake | 交握成功;`batman_http_mark` 增加 |
| HT6 | psk_owner → 候選 → `auth/owner` | 全部 | owner session over HTTP | 成功 |
| HT7 | NX / psk_replay 被拒 | 全部 | NX / psk_replay over HTTP from the phone AP | 關閉 |
| HT8b | 洪流 50/s × 10 分 + poll 沒有 ERate + 擁有者傳完 + 廣播在 | 部分 | the flood is dropped and the poll is not starved; the owner's upload finishing needs an owner session | 同上 + helper log 沒有 ERate + 上傳完成 + 04 端廣播在 |
| HT17 | hostapd / `wifi reload` | 全部 | the phone reconnecting | 手機重連後連得上 |

## `prov-upload-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| UP2 | 不是窗的擁有者 | 全部 | a second owner's session | 被拒 |
| UP3 | 來源 IP | 全部 | an owner session on the phone | session 在手機上,PUT 經 `phy9h4` → 被拒 |
| UP8 | 上傳中 helper 重啟 | 全部 | an upload over HTTP repeated | 重新開窗、重傳成功 |

## `prov-update-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| UD15 | YubiKey | 全部 | a person with the YubiKey | — |

## `p3-other-254`

| 列 | 來源 | 全部 / 部分 | 人要做的(為什麼不能自動) | 設計裡的斷言 |
|---|---|---|---|---|
| TT1 | 轉賣工具 | 部分 | the loop-file arm; the real card needs a person | §3.9 |
| PR1 | D-1 / D-2 | 全部 | the §7 probe's positive arm needs the phone on the AP | §7 |

合計:全部由人執行 16 列,部分 6 列(共 132 列中的 22 列)。
