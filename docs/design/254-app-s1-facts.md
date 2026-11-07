# App S1 path against a P2 node — protocol fact sheet (2026-11-07, research agent; read-only, file:line evidence)

Roots: S=feed/batman-prov/src, D=docs/design (this repo, = main be90b00; line numbers checked there by both v1 reviewers).
✅ = file:line evidence; ⚠️ = inferred / unverified.

## 1. GATT / advertising / framing
- Service `540aa38c-0086-4d58-a9c0-c7c9d1e1bd42` (S/cmd/batman-provd/bluez.go:31). RX …4d59… write-without-response;
  TX …4d5a… notify (AcquireNotify only); CTRL …4d5b… read; STATUS …4d5c… read (bluez.go:32-35,191-199,186).
- No pairing / bonding (254-p2-impl.md:153; bluez.go:458-475). App must NOT initiate pairing.
- Advertising: UUID list only, non-discoverable, RPA, no name, no scan response (bluez.go:226-229). Any connection
  withdraws advertising (bluez.go:325,666-669). ⚠️ whether iOS/Android list non-discoverable adverts: unverified.
- CTRL = {1:1,2:0,3:244,4:8192} (S/provd/server.go:556-559). STATUS = {1:[1,0],2:["halow"],3:state,4:trial,5?:id last4}
  (key 5 only state 0/3; server.go:562-576); stale -> ATT error 0x0E.
- Frame = flags(1)‖seq(2 BE)‖data; bit0 first, bit1 last; seq from 0 per Noise message; frame ≤ 512 incl. 3-byte header;
  message ≤ 8192 (S/provd/frame.go:8-49). Node frames min(244, mtu−3) (bluez.go:384-391).
- Timeouts: handshake 10 s; anon/candidate idle 30 s, owner 300 s; helper wait 330 s -> E_BUSY{3:"outcome unknown"};
  20 handshakes/min; 2 slots BLE+sock (server.go:22-36,739-756; session.go:274-289,582-601).

## 2. Channel / identity
- Unclaimed/legacy: Noise_NX_25519_ChaChaPoly_SHA256 (msg1 32 B); claimed/member: Noise_NXpsk0 (msg1 48 B)
  (S/provd/noise.go:15-20; D/219-protocol.md:36-43).
- Prologue "batman-prov/1\0ble\0" + device_hint: FULL device_id (18 hex) when unclaimed/legacy, empty when claimed
  (noise.go:28; server.go:680-702) -> app needs the QR to handshake an unclaimed node.
- msg2 payload node_cert {1:[DAC DER],2:s_node_pub,3:boot_id,4:ecdh_pub(65),5:sig_static,6:sig_ecdh,7:sn(9)} (server.go:291).
- Wrong PSK -> fake msg2 of equal length, close after 10 s (noise.go:96-130).
- App checks (219-protocol.md:70-77; ref tests/tools/peer/nodecert.py:40-79): cert[2]==remote static;
  sig_static=ES256_DAC("batman-node-static-v1"‖s_node‖boot_id); sn==DAC subject serialNumber, device_id=hex(sn);
  unclaimed: device_id==QR; claimed: DAC == pinned.
- NO production trust root today: keystore file backend only (S/keystore/keystore.go:266-267), DAC self-signed
  CN=dev:<id> (:106-108) -> dev TOFU: device_id==hex(SHA256(DAC pub)[:9]) == QR, self-signed, then pin (219-protocol.md:77).
- psk_owner=HKDF-SHA256(owner_tag_key, salt ∅, "batman-psk-owner-v1"‖device_id); psk_replay=HKDF(z,
  "batman-psk-replay-v1"‖device_id), z=ECDH(owner_enc_priv, ecdh_pub).x (S/proto/proto.go:157-173).
- h = handshake hash (32 B) = channel binding; AEAD failure -> close; 2^20 messages -> close (session.go:312-322).

## 3. Claim
- QR = hex of CBOR {1: device_id tstr, 2: K 32 B} (S/cmd/batman-provhelper/main.go:572-574). ⚠️ QR image format undefined.
- Envelope {0:[1,0],1:id (increasing),2:type,3:body}, deterministic CBOR, keys 0-3,6,7 only (session.go:440-501).
- claim/begin {1: owner_pub 65 B P-256} -> {1: nonce 32} (session.go:695-716).
- claim/finish {1: response 32, 2: owner_enc_pub 65, 3: sig_enc 64} within 55 s (session.go:742-756);
  response=SHA256(K‖ClientChal‖08 00 00 00‖00×8‖00 00 00‖sn[8]‖00 00 00 00‖sn[0:2]‖00 00);
  ClientChal=SHA256("batman-claim-v1"‖nonce‖h‖SHA256(DAC DER)‖owner_pub); sig_enc=ES256_owner("batman-owner-enc-v1"‖owner_enc_pub)
  (proto.go:49-69; S/node/node.go:519-524).
- OK -> {1: owner_tag_key, 2: adv_owner_key, 3: root_password}; session becomes owner (node.go:550; session.go:677-693).
- Errors: 9 E_CLAIM_FAILED (3/conn then close); 13 E_LOCK_INCOMPLETE (owner anyway -> replay); 6{1:"claim",2:10} legacy
  without SSH key; 7 trial; 3 no/expired begin (session.go:765-785; node.go:206-207).
- ES256 raw r‖s, low-s required (proto.go:116).
- Persist BEFORE claim/finish: node_cert + claim-pending{device_id, owner_pub}; K stored or rescannable (219-protocol.md:241).
  Long-term: owner sign key, owner_enc key (separate, ECDH), owner_tag_key, adv_owner_key, root_password, pinned DAC/node_cert.

## 4. Owner login
- NXpsk0 with psk_owner, empty hint -> candidate (info / auth/owner only, session.go:76-83).
- auth/owner {1: SHA256(owner_pub), 2: ES256("batman-owner-auth-v1"‖h‖kid)} -> {} (session.go:790-813).

## 5. op/nonce + network/join
- op/nonce -> {1: nonce_helper}: 60 s, single use, ≤ 4 per h (session.go:731-739; node.go:259-290).
- Key 31 {1:"network/join", 2:sig}; sig over "batman-owner-op-v1"‖h‖nonce_helper‖u8(len)‖type‖SHA256(detCBOR(body
  without 31)); verb == envelope type (proto.go:81-102; node.go:652-690).
- network/join body {1: netcfg-sign1, 2: members-sign1, 3: secrets-sign1, 31: op} -> {1:0} (session.go:666-667).
  Sign1 tag 18, protected exactly {1:-7,3:ct}, unprotected empty, external_aad = label (S/cose/cose.go:36-84).
  Node checks: net_config signed by its own key-8 admins (1-4), net_id 16 B, 1 ≤ version ≤ u32, halow {1: ssid, 2: channel}
  (node.go:960-1030).
- net_secrets encrypted BY THE APP to node ecdh_pub after verifying sig_ecdh (tests/tools/peer/netobj.py:133-139):
  target_dac_hash=SHA256(DAC pub); KDF ctx [24,[nil,nil,nil],[target,nil,nil],[256,rprot,net_id‖u32BE(ver)]];
  ChaCha20-Poly1305, aad = Enc_structure ["Encrypt", bstr(detCBOR({1:24})), label] (protected as an encoded bstr, cose.go:202); plaintext {1: sae ≥8, 2: net_root} (S/node/wtxn.go:126-152; cose.go:139-211).
- App keeps signed net_config, net_root, SAE, admin key (to give other nodes the same config) (provclient/net.go:253-268).
- net.apply worst case ~180 s (254-p2-impl.md:314).

## 6. info
- {1:device_id,2:model,3:board,4:fw,5:[1,0],6:["halow"],7:state 0-3,8:claim_window}; owner/member add 9 net_version,
  10 net_id, 11 unfinished (server.go:529-553).

## 7. Must-dos and doc/code mismatches
- Verify node_cert before any request; encrypt only to a sig_ecdh-verified ecdh_pub; pick handshake mode from local
  records, not adverts/STATUS (219-protocol.md:43); low-s; increasing ids; no key 7 on P2 (session.go:614-619).
- Mismatches (code wins): adverts carry no id suffix (only STATUS); auth/owner returns {} not adv_owner_key; E_CLAIM_WINDOW
  never sent (trial -> 7); member may only info/network/update; chunked max 65400 B not 1 MB; member_list not verified;
  key 5 country ignored by P2 (P3: must equal radio1.country, reason 14); join does not check version 1 / prev null;
  unknown keys in signed objects not rejected; owner reacquire 55 s in provd; 219-field-provisioning SIGMA/AES-GCM text obsolete.
- Unverified ⚠️: production root distribution; QR image format; non-discoverable adverts on iOS/Android; real MTU.
- Test vectors: tests/vectors/219-protocol/vectors.json (node_cert, claim_checkmac, owner_op, cose, gatt_framing,
  identity_file) -> app unit tests.

## 8. Added from the v2 reviews (file:line verified by reviewers)
- Response envelope: success {1: id, 3: body, 4: 0} (S/provd/session.go:431-436); error {1: id, 4: code, 5: detail}, no key 3
  (session.go:424-429); detail = {1: capability, 2: reason, 3: text} (219-protocol.cddl:117-119); chunked response
  {1, 4: 0, 3: bstr, 6: {1: n, 2: total}} (cddl:108). No key 0 in responses; the app checks id == request id.
  Vector claim_replay.response_envelope decodes to {1: 4, 3: {...}, 4: 0}.
- claim/replay request {1: response 32 (CheckMac with THIS session's claim/begin nonce and h, the node's stored owner_pub),
  31: {1: "claim/replay", 2: sig64}} (cddl:427; S/node/node.go:560-610); nonce_helper from op/nonce; both within 55 s
  (session.go:721-729). Response {1: owner_tag_key, 2: adv_owner_key, 3: NEW root_password} (node.go:615-619): every
  replay rotates root_password. Success or 13 makes the session Owner and evicts the others (session.go:660-665, 692);
  an Owner session may not replay (session.go:79).
- Reacquire failures: <= 10 per node per hour, then E_RATE (12) (node.go:571-584); E_FORBIDDEN 3x on one connection -> close
  (session.go:654).
- Handshake failure classes (corrected by the v3 reviews): NO msg2 only for rate (> 20/min, session.go:389), not ready
  (server.go:741-745), both slots busy. A fake equal-length msg2 for a wrong PSK AND for a mode mismatch (32 B NX msg1 to a
  PSK node, 48 B msg1 to an NX node; noise.go:56-58,63-72,84,89-96). An NX prologue / device_id mismatch gets a REAL msg2
  (msg1 is plaintext, the node does not check the prologue, noise.go:69) that the phone cannot decrypt. A read error ends the session at
  once (session.go:199-202, 222-225): the 10 s hold applies only while the phone stays connected.
- claim/finish 7 has three sources: trial (node.go:206), ops busy, helper connection lost after sending (no body,
  session.go:603-606) -> outcome unknown. network/join 5 = E_STALE_VERSION = already in a network (node.go:1003); 11 also
  covers hEState / hESchema (session.go:571-577).
- P2 ignores net_config key 5 and halow key 3 (node.go:967-981); the channel is validated by halow-setkey against the RADIO's
  country (halow-setkey:89-99); bench radios are US (meshpoint-1.8.0:22,50).
- members (member-list) CDDL at cddl:331-346; join-req at cddl:202-209. 219-protocol.md:400-407 (§10): app = Rust
  batman-proto (sans-IO, snow) + flutter_rust_bridge v2; signatures and ECDH on the platform side.
- info key 11 = TxnPresent, always present when info.net answers (readonly.go:127-131; server.go:549-551); true while a
  network change is in progress (node.go:1129-1165).
- net_secrets uses ECDH-ES (alg -25) with a sender ephemeral P-256 key (cose.go:164-191); outer Sign1 payload
  {1 net_id, 2 version, 3 SHA256(DAC pub), 4 COSE_Encrypt} (wtxn.go:128-145). halow key 3 = bandwidth in MHz (cddl:325).
