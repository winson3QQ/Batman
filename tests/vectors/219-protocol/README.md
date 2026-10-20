# 供裝協定測試向量(#219 / #254)

對應規格:`docs/design/219-protocol.md`(v0.7)與 `docs/design/219-protocol.cddl`。

| 檔案 | 用途 |
|---|---|
| `vectors.json` | 測試向量(固定金鑰、決定性簽章,可逐位元組重現) |
| `gen.py` | 產生 `vectors.json`(`cryptography` + `noiseprotocol` + `cbor2`) |
| `verify.py` | **用另一份實作**逐項驗證:Noise 用 `dissononce`、ECDSA / ECDH 用 `python-ecdsa`、HKDF 用標準庫 `hmac`、結構用 `pycddl` 對 CDDL 驗證 |
| `requirements.txt` | 產生與驗證時用的套件:整個相依閉包釘版本 + sha256(`--require-hashes`) |
| `ci-check.sh` | CI(`vectors-219`)與手動共用的閘門 |

## 使用

```
python -m venv venv && venv/bin/pip install --require-hashes --no-deps -r requirements.txt
venv/bin/python gen.py > vectors.json      # 重新產生(輸出應與 repo 內完全相同)
venv/bin/python verify.py vectors.json     # 195 項檢查(含負向測試),全部 PASS 才算通過
PY=venv/bin/python bash ci-check.sh         # CI 同一道閘門:檢查數 >= 195、gen.py 逐位元組重現、竄改向量必須被拒絕
```

## 涵蓋範圍

- 測試用的根憑證與 DAC(X.509 DER,決定性簽章);`node_cert` 與其兩個簽章
- HKDF:`psk_owner`、`psk_member`、`adv_owner`、`adv_member`
- Noise `NX`(未認領)與 `NXpsk0`(擁有者 PSK):三則訊息、交握雜湊、第一則傳輸訊息;**以 `dissononce` 重新跑一次交握,位元組必須完全相同**
- `auth/owner`、認領的 CheckMac(88 B 輸入與輸出)、`sig_enc`、`peers/challenge`
- COSE:`net_config`、`member_list`、`net_secrets` / `member_secrets`(含 ECDH 共享秘密、KDF context、CEK)、兩種邀請、加入申請、同意圖片
- SAS、QR 物件大小(三種圖片都在 QR version 25-L 的 1273 B 以內)
- GATT 框架切段與重組;CBOR 信封範例
- **v0.7**:file 後端身分(`sn`、`device_id = hex(sn)`、自簽 `dev:` 憑證)、`psk_replay`(雙方 ECDH、HKDF、`NXpsk0` 交握)、owner-op(`args_hash`、簽章與負向測試)、`op/nonce`、`claim/replay`、`reset` 的 `E_UNSUPPORTED` reason 9

## 注意

- 這些金鑰由固定字串導出,**不是秘密**,只能用於測試。
- 向量使用**正式版**的標籤與 prologue;開發版(`-dev` 後綴)的向量之後另外產生。
- 實作端(Rust `batman-proto`)應把 `vectors.json` 納入單元測試;`flynn/noise`(Go)的交叉驗證可在有 Go 的環境補做(規格 §12 Q8)。
