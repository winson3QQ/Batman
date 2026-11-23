# ATECC608B configuration facts (for slot map / config-zone design)

Compiled 2026-11-23. Research only: no device was contacted, nothing was built.
Every statement carries a source tag. "INFERRED" marks a statement that is documented for a
different part (508A, 608A, TFLXTLS/TNGTLS variant) and assumed to hold for the blank ATECC608B.
"NOT FOUND" means I could not find a public source and did not fill the gap from memory.

## 0. Sources actually read

| Tag | Document | Where it came from | How much was read |
|---|---|---|---|
| [508A] | ATECC508A **Complete** Data Sheet, DS20005927A (2017), 109 p. | distributor mirror `https://store.comet.bg/download-file.php?id=20040` (microchip.com copies return HTTP 403) | §1–§3, §9.1.6–§9.21, §10 read in full; I/O chapters skimmed |
| [608B-SUM] | ATECC608B **Summary** Data Sheet DS40002239B, 30 p. | `https://ww1.microchip.com/downloads/aemDocuments/documents/SCBU/ProductDocuments/DataSheets/ATECC608B-CryptoAuthentication-Device-Summary-Data-Sheet-DS40002239B.pdf` | intro, §4 Compatibility, AC/DC tables, ordering codes |
| [608A-TFLX] | ATECC608A-TFLXTLS **Complete** Data Sheet DS40002138A, 103 p. | `https://ww1.microchip.com/downloads/en/DeviceDoc/ATECC608A-TFLXTLS-CryptoAuthentication-Data-Sheet-DS40002138A.pdf` | §2 (config table with byte values, per-slot SlotConfig/KeyConfig hex), §3, KDF §5.3.4 |
| [608B-TFLX] | ATECC608B-TFLXTLS **Complete** Data Sheet DS40002249A, 98 p. | `https://ww1.microchip.com/downloads/en/DeviceDoc/ATECC608B-TFLXTLS-CryptoAuthentication-Data-Sheet-DS40002249A.pdf` | §2, §5 commands (Counter, Info, Lock, Read, SHA-HMAC, Write, ECDH, GenKey, Sign, Verify-validate, CheckMac, GenDig, KDF stub, MAC), §10 |
| [608B-TNG] | ATECC608B-TNGTLS Data Sheet DS40002250B, 56 p. | local `C:/Users/yello/Desktop/Batman/parts spec/WM1302/ATECC608B-TNGTLS.pdf` | all text pages (pp. 1–44) |
| [608A-TNG] | ATECC608A-TNGTLS Complete Data Sheet DS40002112B, 83 p. | `https://ww1.microchip.com/downloads/en/DeviceDoc/ATECC608A-TNGTLS-CryptoAuthentication-Data-Sheet-DS40002112B.pdf` | **only grepped** (I2C address line); not read in full |
| [AN3539] | "Migrating from the ATECC508A to the ATECC608B" (online version) | `https://onlinedocs.microchip.com/oxy/GUID-D7090430-8C77-4611-BE14-1E6C9D0B117F-en-US-1/index.html` | all topic pages |
| [AN2237] | "Migrating from the ATECC608A to the ATECC608B" (online version) | `https://onlinedocs.microchip.com/oxy/GUID-91D4A0CB-3AFD-443D-B23E-4D22AD0B49DB-en-US-1/index.html` | all topic pages (the timing table rendered only partly) |
| [AN8974] | Atmel-8974 "ATECC Compressed Certificate Definition" | `https://ww1.microchip.com/downloads/en/Appnotes/Atmel-8974-CryptoAuth-ATECC-Compressed-Certificate-Definition-ApplicationNote.pdf` | §2.3–2.4 and tables |
| [CAL] | MicrochipTech/cryptoauthlib, `main` @ `d0b9a77be7372db3bd5ebb1edc321b1374f311a6` (pushed 2026-11-05) | `gh api repos/MicrochipTech/cryptoauthlib/contents/<path>` | files and lines cited inline |

**Not read / not available:** the ATECC608B complete data sheet. [608B-SUM] p.4 says: "This is a summary
document. A complete document is available under NDA." The ATECC608A complete data sheet was also not
found on a Microchip or distributor URL. Therefore **every bit-level table below comes from [508A]**
(same architecture) cross-checked against the 608 field definitions in [CAL] `lib/calib/calib_device.h`
and against real 608 config values printed in [608A-TFLX].

**Why 608A statements are applied to 608B:** [608B-SUM] §4.1: "No configuration bit fields have changed.
Configurations defined for the ATECC608A will be functionally identical with the ATECC608B device."
[AN2237] "Device Differences": "The ATECC608B does not introduce any new configuration bits and has the
same number of data slots ... All commands and command modes are still supported"; "Migration": "a
functional drop-in replacement of the ATECC608A". [608B-TFLX] §10 says the same for the TFLXTLS pair.
Listed 608A→608B differences ([608B-SUM] §4.1, [AN2237]): low-frequency I2C wake fix, Info revision
byte, execution-time changes for Verify / SecureBoot / Lock / Read, new temperature grade and packages.

**Why 508A statements are applied (with care) to 608:** [608B-SUM] §4.2: "Most elements of the
configuration zone in the ATECC608B are identical in both location and value with the ATECC508A."
The documented exceptions are listed in §1.2 below.

---

## 1. Zones, sizes, locks

### 1.1 Zones
- EEPROM: Config 128 bytes, Data 1,208 bytes in 16 slots, OTP 64 bytes (2 × 32). [608B-TFLX] Table 2-1; [508A] Table 2-1.
- Slot sizes: **slots 0–7 = 36 bytes, slot 8 = 416 bytes, slots 9–15 = 72 bytes.** [608B-TFLX] Table 2-1; [508A] Table 2-3.
- What fits where ([508A] §2.1, Table 2-3; [608B-TNG] §4.5.1.1 "Only Slots 8-15 are large enough to hold a public key"):
  - ECC P-256 private key: any slot (uses 32 of the bytes; "the excess memory ... is generally unusable").
  - 32-byte secret: any slot.
  - ECC public key (stored format 72 bytes: 4 pad + X + 4 pad + Y): slots 8–15 only.
  - 64-byte signature / 72-byte compressed certificate: slots 8–15.
  - AES-128 keys (608 only): 16-byte boundaries inside a slot, "not exceeding four keys in any slot" ([608B-TNG] §5.3.1); [608A-TFLX] slot 5 (36 B) "can store up to 2 AES 128-bit keys", slot 9 (72 B) up to four.
- OTP: 64 bytes. On the 508A it could be written after config lock and before data lock, and had a "consumption" mode ([508A] §2.3). **On the 608B the consumption mode is gone: "OTP consumption mode eliminated, now read only"** ([608B-SUM] §4.2); [AN3539] §1.3.1: "After the device configuration zone is locked, no change to the OTP zone is allowed. Only reading of the OTP zone data is allowed." These two 608B sentences do not say clearly whether the OTP can still be written in the window "config locked, data/OTP unlocked" (as on the 508A) → see §17.
- On Trust variants the first 8 OTP bytes hold an ASCII code that cryptoauthlib uses to pick the certificate definition ([CAL] `app/tng/tng_atca.c` ~l.45–65; [608B-TNG] §2.3 shows `78 36 74 6A 75 5A 4D 79` = "x6tjuZMy"; [608B-TNG] warns "The bytes in the OTP zone may change over time").

### 1.2 Config zone layout (608)
Field layout from [CAL] `lib/calib/calib_device.h:104-134` (`atecc608_config_t`), byte numbers and
meanings from [608A-TFLX] Table 2-3; write permissions from [508A] Table 2-5 (INFERRED for 608).

| Byte | Field (608) | Writable | Notes |
|---|---|---|---|
| 0–3 | SN[0:3] | never | [508A] Table 2-5 |
| 4–7 | RevNum | never | "should never be used by system software" [508A] §2.2.6 |
| 8–12 | SN[4:8] | never | |
| 13 | AES_Enable (508A: reserved) | **factory-set** (INFERRED) | [508A] Table 2-5 lists byte 13 as "Never"; [CAL] `lib/calib/calib_read.c:460-466` treats only bytes 16–51, 68–83, 90–127 as "user writeable and lockable". Bit 0 = AES enable ([CAL] `calib_device.h:145-146`). [AN3539] Table 3-1: "enables/disables the AES functionalities for both AES and KDF commands". Whether a user can change it on a blank part: NOT FOUND. |
| 14 | I2C_Enable | never | bit 0: 1 = I2C, 0 = SWI ([508A] Table 2-5; [608A-TFLX] Table 2-3) |
| 15 | Reserved | never | |
| 16 | I2C_Address | until config lock | bits 7–1 = 7-bit address, bit 0 must be 0 ([508A] Table 2-5) |
| 17 | Reserved | until config lock | must be 0 |
| 18 | CountMatch (508A: OTPmode) | until config lock | [AN3539] Table 3-1; bit 0 enable, bits 7–4 key slot ([CAL] `calib_device.h:152-157`) |
| 19 | ChipMode | until config lock | see §9 |
| 20–51 | SlotConfig[16] (2 bytes each, little-endian) | until config lock | §2 |
| 52–59 | Counter[0] | until config lock; then Counter command | §7 |
| 60–67 | Counter[1] | same | |
| 68 | UseLock (508A: LastKeyUse[0]) | until config lock | bits 3–0 enable, bits 7–4 key ([CAL] `calib_device.h:203-207`); "controls the transport lock functionality" [AN3539] Table 3-1 |
| 69 | VolatileKeyPermission | until config lock | bits 3–0 slot, bit 7 enable ([CAL] `calib_device.h:209-214`) |
| 70–71 | SecureBoot | until config lock | §12 |
| 72 | KdfIvLoc | until config lock | [AN3539] Table 3-1 |
| 73–74 | KdfIvStr | until config lock | |
| 75–83 | Reserved | until config lock | "Must be zero" [608A-TFLX] Table 2-3 |
| 84 | UserExtra | **UpdateExtra command only**, once, only if currently 0x00 | [608A-TFLX] Table 2-3; [608B-TNG] §5.1.9 |
| 85 | UserExtraAdd (508A: Selector) | UpdateExtra only, once, only if 0x00 | if non-zero and ChipMode bit 0 = 1 it **is the I2C address** ([608A-TFLX] Table 2-3) |
| 86 | LockValue | Lock command only | 0x55 = unlocked, 0x00 = locked ([508A] Table 2-5) |
| 87 | LockConfig | Lock command only | 0x55 = unlocked, 0x00 = locked |
| 88–89 | SlotLocked | until config lock; then Lock(slot) only | one bit per slot, **1 = not locked, 0 = locked** ([508A] Table 2-5, §2.4.3; [608B-TNG] §2.1.1) |
| 90–91 | ChipOptions (508A: RFU) | until config lock | §5 |
| 92–95 | X509format | until config lock | |
| 96–127 | KeyConfig[16] (2 bytes each, little-endian) | until config lock | §2 |

16-bit fields are little-endian on the bus and in the zone: [508A] §4.1 ("SlotConfig or KeyConfig, appear
on the bus least-significant byte first"). Example: [608A-TFLX] prints slot 0 as "Slot: 0x0085"; the
pkcs11 example in [CAL] stores slot 0's `0x208F` as bytes `8F 20`.

### 1.3 Locks ([508A] §2.4, Table 2-13/2-14/2-15; INFERRED for 608 unless a 608 source is given)
- **LockConfig (byte 87).** Before: config zone readable and writable (except never-write bytes); **Data and OTP zones can be neither read nor written** ("Any attempt to read or write the data or OTP zones prior to locking the configuration zone causes the device to return an error"). After: no direct writes to the config zone, ever ("there is no way to unlock it"). Still changeable afterwards only through commands: SlotLocked bits (Lock), bytes 84/85 (UpdateExtra), counters (Counter). [608B-TNG] §2.1.1 confirms the same list for the 608B.
- **LockValue (byte 86)** locks Data + OTP together. Before (config locked, value unlocked): data slots can be written (clear or encrypted), **never read**; "Most write access restrictions are ignored when the data zone is unlocked". After: every slot behaves per its SlotConfig/KeyConfig. "Locking the data/OTP zone does not mean that the values in these zones cannot be modified; locking indicates that the slot now behaves according to the policies set".
- **SlotLocked bit + KeyConfig.Lockable**: per-slot, one-way. "If the SlotLocked bit for a particular slot is set to zero ... modification of that slot via the PrivWrite, Write, GenKey, and/or DeriveKey commands is permanently prohibited, regardless of the state of the corresponding Lockable, SlotConfig and/or KeyConfig bits. When SlotLocked is zero, then the corresponding slot cannot be written even if the data zone is unlocked." A slot-locked key can still be *used* ([608B-TNG] §2.1.1).
- SlotLocked bits and Lockable bits "can be freely written using the Write command prior to locking of the configuration zone" → **a config with a SlotLocked bit already 0 permanently freezes that slot's contents from the start** ([508A] §2.4.3).
- Lock command CRC ([508A] §9.10): config lock checks a CRC-16 over all 128 config bytes; data lock checks a CRC over all slots in order (slots configured as ECC private keys are skipped) followed by the OTP zone; Mode bit 7 skips the check ("Microchip does not recommend using this mode"). Slot lock ignores the CRC.

---

## 2. SlotConfig and KeyConfig bit fields

Source of the tables: [508A] Table 2-6 … 2-12. 608 field positions confirmed in [CAL]
`lib/calib/calib_device.h:170-201` (SlotConfig) and `:251-275` (KeyConfig). Real 608 values that
exercise these bits are in [608A-TFLX] Tables 2-4 … 2-17 (quoted below as "TFLX example").
All restrictions apply **when the data zone is locked** ([508A] §2.2.1, §2.2.5).

### 2.1 SlotConfig (16 bits per slot)

| Bits | Name | Non-private slot (data / secret / public key) | ECC private-key slot (KeyConfig.Private = 1) |
|---|---|---|---|
| 15–12 | WriteConfig | Write command: `0000` Always (clear writes; "should never be used as key storage"); `0001` PubInvalid (writes refused while a validated public key is stored); `001x` and `10xx` Never; `x1xx` Encrypt (encrypted + MAC with WriteKey; 4-byte writes prohibited). DeriveKey: bit 13 = 0 → slot can never be a DeriveKey target; bit 13 = 1 → target (bit 12: 0 = roll, 1 = create from parent WriteKey; bit 15: authorising MAC required). The tables overlap. ([508A] Tables 2-8, 2-9) | **bit 13 = GenKey permission** (1 = "GenKey may be used to write random keys into this slot"; 0 = may not). **bit 14 = PrivWrite permission** (0 = "Forbidden: PrivWrite will return an error"; 1 = encrypted PrivWrite with WriteKey). ([508A] Tables 2-10, 2-11) |
| 11–8 | WriteKey | slot whose key validates/encrypts writes to this slot; also the DeriveKey parent | key used for encrypted PrivWrite |
| 7 | IsSecret | 1 = no clear reads; 4-byte reads/writes prohibited. "must be set if EncryptRead is a one or if WriteConfig has any value other than Always" | must be 1: "The GenKey and Sign commands will fail if IsSecret is set to zero for any ECC private key" |
| 6 | EncryptRead | 1 = slot can be read encrypted with ReadKey (requires IsSecret = 1). IsSecret=1 + EncryptRead=0 = "Reads are never permitted" ([508A] Table 2-7) | (private keys can never be read) |
| 5 | LimitedUse | 1 = each use of the key first increments Counter[0]; fails when the counter is at its limit ([508A] §3.2.5). On 608 this applies to slot 15 too (the 508A "LastKeyUse" special case is removed: [608B-SUM] §4.2, [AN3539] §1.3.2) | same |
| 4 | NoMac | 1 = "The key stored in the slot is intended for verification usage and cannot be used by the MAC or HMAC commands. When this key is used to generate or modify TempKey, then that value may not be used by the MAC and HMAC commands. Also cannot be used with the SHA command in HMAC mode." | (n/a) |
| 3–0 | ReadKey | key slot for encrypted reads. **ReadKey = 0 enables CheckMac/Copy from this slot** ("Do not set this field to zero unless the CheckMac/Copy operation is explicitly desired, regardless of any other read/write restrictions"). For validated public keys: the KeyID used to validate. | **bit 0 ExtSignEnable**: 1 = external (arbitrary digest) signatures allowed. **bit 1 IntSignEnable**: 1 = internal signatures of messages generated by GenDig or GenKey allowed. **bit 2 ECDHEnable**: 1 = ECDH permitted. **bit 3 ECDHToNextSlot**: 0 = master secret output in the clear, 1 = written into slot N+1 ("Can only be set to 1 for even number slots"); ignored if bit 2 = 0. |

Discrepancy to be aware of: [CAL] `calib_device.h:198-201` defines `ATCA_SLOT_CONFIG_GEN_KEY_SHIFT (8)`
and `ATCA_SLOT_CONFIG_PRIV_WRITE_SHIFT (9)`, which does **not** match [508A] Tables 2-10/2-11
(bits 13 and 14). Real configs agree with the data sheet: TFLX example slot 2 `0x2085` "GenKey can be
used to generate a new ECC private key in this slot" (bit 13 set); slot 0 `0x0085` permanent key
(bit 13 clear). **Use bits 13 / 14.**

TFLX examples ([608A-TFLX] Tables 2-4…2-9) that decode consistently with the table above:
- slot 0 `SlotConfig 0x0085 / KeyConfig 0x0053`: IsSecret, ECDH enable, ExtSign; no GenKey, no PrivWrite; Private, PubInfo, P-256, ReqRandom. "Permanent, Ext Sign, ECDH".
- slot 1 `0x0082 / 0x0053`: IsSecret, **IntSign only**, ECDH disabled. "can only sign messages generated internally by the GenKey or GenDig commands and cannot be used to sign arbitrary external messages" ([608B-TNG] §2.2.1.1).
- slots 2–4 `0x2085 / 0x0073`: as slot 0 plus GenKey (bit 13) and Lockable.
- slot 5 `0x468F / 0x0038`: Encrypt write with WriteKey = 6, IsSecret, ReadKey = F, KeyType 6 (AES), Lockable.
- slot 6 `0x0F8F / 0x007C`: Always-write, IsSecret, no read, KeyType 7, Lockable, ReqRandom (IO protection key).
- slot 7 `0x8F9F / 0x001C`: Never-write, IsSecret, **NoMac** ("This slot is secret and cannot be used by the MAC command").

### 2.2 KeyConfig (16 bits per slot) — [508A] Table 2-12 unless noted

| Bits | Name | Meaning |
|---|---|---|
| 0 | Private | 1 = slot holds an ECC private key "and can be used only with the Sign, GenKey, ECDH and PrivWrite commands". 0 = not a private key; "cannot be used with the Sign, GenKey, ECDH and PrivWrite commands". Private-key slots can never be read; "They can never be written with the Write and/or DeriveKey commands" (§2.2.4). |
| 1 | PubInfo | Private slot: 1 = public key can always be regenerated (GenKey), 0 = "can never be generated"; "ignored when a random key is generated" (the create command always returns the public key). Public-key slot (8–15): 1 = Verify uses the key only after it has been validated; any write resets the validity nibble to 0xA. |
| 4–2 | KeyType | `100` (4) = P-256 ECC key; `111` (7) = not an ECC key (SHA key / data); 608 adds `110` (6) = AES key ([608A-TFLX] Tables 2-7, 2-11 "(KeyType = 0x6)"; [AN3539] Table 3-1 "two new types (AES, SHA)"). "Keys that will be the source or destination of the SHA-256 computation commands (CheckMac, DeriveKey, MAC, or HMAC) should be set to a KeyType of 0b111." |
| 5 | Lockable | **1 = slot can be individually locked with Lock**; 0 = cannot. Note: [608B-TNG] §2.2.1.1 and [608B-TFLX] §2.2.1.1 say "slot-lockable (KeyConfig.Lockable bit is set to zero)" — this contradicts [508A] Table 2-12/2-15 and the hex values in [608A-TFLX] (lockable slots 2–4 = `0x0073`, bit 5 **set**; permanent = `0x0053`). Treat the "set to zero" sentence as a data-sheet error. |
| 6 | ReqRandom | 1 = TempKey must come from a random Nonce for GenKey(digest), MAC, HMAC, CheckMac, Verify, DeriveKey, GenDig using this key. |
| 7 | ReqAuth | 1 = a successful authorisation with the key in AuthKey (CheckMac, or Verify in stored mode) must precede "any cryptographic command (i.e. CheckMac, DeriveKey, GenDig, GenKey, MAC, HMAC, Sign, or Verify) that uses this key". "The GenKey command checks for usage authorization even when generating a new key". AuthValid is volatile: cleared on sleep/power-off **and after any command that uses a key requiring authorisation** (§2.2.5, §3.2.9). ECDH is **not** in the quoted list → NOT FOUND whether ReqAuth gates ECDH. |
| 11–8 | AuthKey | slot of the authorising key; must be 0 if ReqAuth = 0. |
| 12 | PersistentDisable (508A: IntrusionDisable) | 1 = key usable only while the persistent latch is set; GenKey is still permitted ([508A] wording for IntrusionDisable). 608: [608A-TFLX] slot 0 option 2 `KeyConfig 0x1053` "Persistent Disable Option Enabled … Sign/ECDH After Successful Secure Boot"; [CAL] `calib_device.h:269-270`. |
| 13 | RFU | must be 0 |
| 15–14 | X509id | index into X509format[0..3] for a public-key slot; "Must be zero if the slot does not contain a public key". |

### 2.3 Internal vs external signing, and what an internal signature covers
- External: host loads a 32-byte digest (Nonce pass-through into TempKey, or on 608 the Message Digest Buffer) and Sign(Mode bit 7 = 1) signs it. Needs ExtSignEnable. [508A] §9.18; [608B-TFLX] §5.2.4.2 (modes 0x80/0xC0 TempKey, 0xA0 Message Digest Buffer).
- Internal (Mode bit 7 = 0): the device builds a 55-byte message and signs its SHA-256. Needs IntSignEnable, TempKey must have been produced by GenKey or GenDig, **and the data zone must be locked** ("If the data zone has not been locked, then internal signatures will always generate an error code"). [508A] §9.18.
- 55-byte internal message ([608B-TFLX] §5.2.4.1 table; [508A] §9.18):
  `TempKey(32) ‖ Opcode 0x41 ‖ Mode ‖ KeyID(2) ‖ SlotConfig[TempKey.KeyID](2) ‖ KeyConfig[TempKey.KeyID](2) ‖ TempKeyFlags(1) ‖ 00 00 ‖ SN[8] ‖ SN[4:7] or zeros ‖ SN[0:1] ‖ SN[2:3] or zeros ‖ SlotLocked[TempKey.KeyID](1) ‖ PubKeyValid(1) ‖ 00`
  (Mode bit 6 selects whether SN[2:7] is included; SN[8] and SN[0:1] always are.)
  So it covers: the digest in TempKey, the **SlotConfig, KeyConfig and SlotLocked bit of the slot that produced TempKey**, the TempKey flags, and the serial number. It does **not** directly include OTP, counters or the rest of the config zone; those can be folded into TempKey beforehand with GenDig (zones Config / OTP / Counter / KeyConfig, [508A] §9.6), but "only the configuration for the last key used will be signed".
- **Attesting a public key generated in another slot** — documented flow: GenKey with the digest bit (mode 0x0C create+digest, 0x08 public+digest; or 0x10 for a stored public key) puts `SHA-256(TempKey ‖ 0x40 ‖ Param1 ‖ Param2 ‖ SN[8] ‖ SN[0:1] ‖ 25 zeros ‖ X ‖ Y)` into TempKey ([608B-TFLX] §5.2.2.1–5.2.2.4; [508A] §9.7), then Sign(internal) with the attestation key. [508A] §3.2.3: "the device can also use another internally stored key to create a MAC or signature (using the Sign(Internal) command) covering the new public key." [608B-TNG] §2.2.1.1 "Key Attestation" describes slot 1 for exactly this.

### 2.4 ECDH bits
- 508A behaviour ([508A] §9.5): output either in the clear or written to slot N+1, decided "solely by bit 3 of SlotConfig.ReadKey".
- 608 adds mode-controlled outputs (§5). [608B-TFLX] §5.2.1.1: "Access policies may also specify whether or not the output will be stored, encrypted or allow the command itself to determine whether the output is stored or encrypted." [CAL] `lib/calib/calib_command.h:439-443` names mode bits 3–2 = 00 "COPY_COMPATIBLE" (508A-compatible), 01 slot, 10 TempKey, 11 output buffer.
- NOT FOUND: the exact 608 rule for how SlotConfig bit 3 interacts with the non-compatible ECDH modes.

---

## 3. Guaranteeing and proving on-chip key generation

Guarantee (config bits, [508A] §2.2.4, Tables 2-10/2-11, §9.7, §9.14):
- KeyConfig.Private = 1, KeyType = 4, SlotConfig.IsSecret = 1.
- **SlotConfig bit 14 = 0** → after data-zone lock "PrivWrite will return an error". Write and DeriveKey can never write a private-key slot.
- SlotConfig bit 13 = 1 if the key is to be generated/regenerated by GenKey after data lock; bit 13 = 0 makes the key permanent after data lock.
- **Window before data-zone lock:** "Prior to the data zone being locked, this command [PrivWrite] can be used to write the slot contents without regards to the SlotConfig value" and in clear text ([508A] §9.14). KeyConfig restrictions also do not apply then, "with the exception that slots configured to contain private keys can be written only with the PrivWrite command" (§2.2.5). GenKey(create) before data lock works regardless of bit 13 (the bit-13 check is listed under "Once the Data zone has been locked", §9.7). **So the config bits alone do not prove a key was generated on-chip; they prove nobody can inject one after data lock.** A key created before data lock could have been injected by the provisioning station.
- GenKey/PrivWrite/DeriveKey always error before config lock ([508A] §9.7, §9.14, §9.4).

Proof to a verifier:
- The config zone is readable forever: "The values of these bytes can always be obtained using the Read command" ([508A] §2.2), "The zone can always be read" ([608B-TNG] Table 2-1). A plain Read is **not authenticated** (a bus or root attacker can fake it).
- Authenticated evidence = Sign(internal) by an IntSign-only attestation key: the signed message contains the target slot's SlotConfig, KeyConfig and SlotLocked bit and the GenKey digest (§2.3). A verifier who trusts the attestation public key can check Private = 1, bit 14 = 0, etc.
- INFERRED (from the documented message formats; not stated by Microchip in the documents read): because the GenKey digest message includes `Param1` (the GenKey mode byte), a digest made by mode 0x0C (create + digest) differs from one made by 0x08 (existing key + digest); with a verifier-supplied nonce in TempKey this would let the verifier check that the key was **freshly generated in that command, after data lock**. Must be confirmed on a sacrificial chip (§17 E7) before relying on it.
- The attestation key's own public key must be captured in a trusted setting (it has the same "before data lock" caveat).
- Info(KeyValid) reports whether a private/public key slot holds a valid key ([608B-TFLX] §5.1.2.2).

---

## 4. CheckMac / MAC / GenDig / DeriveKey / HMAC / KDF on a 32-byte secret slot

What each command does with the secret:
- **CheckMac** ([508A] §9.2; [608B-TFLX] §5.3.2, Table 5-82): computes `SHA-256(Key[KeyID] or TempKey ‖ ClientChal or TempKey ‖ OtherData[0:3] ‖ 8 zeros ‖ OtherData[4:6] ‖ SN[8] ‖ OtherData[7:10] ‖ SN[0:1] ‖ OtherData[11:12])` and returns only 0x00 match / 0x01 mismatch. Mode 0x00 = slot key + host-supplied challenge; 0x01/0x05 = slot key + TempKey; 0x02/0x06 = TempKey + challenge. This matches `CheckMacInput` in `C:/src/Batman-255/feed/batman-prov/src/proto/proto.go:53-70`.
  - Side effects: a successful CheckMac sets AuthValid/AuthKeyID (authorisation for ReqAuth keys); and **CheckMac/Copy**: with Mode 0x01 or 0x05, on a match "the target EEPROM slot value may be copied into TempKey. If KeyID is even, then the target slot is KeyID+1, or else the target slot is KeyID ... SlotConfig.ReadKey for the target key must be zero"; the copied TempKey has NoMacFlag = 0 ([508A] §9.2, §3.2.7).
- **MAC** ([508A] §9.11): returns `SHA-256(key ‖ challenge/TempKey ‖ …)` — a digest output that depends on the secret. Blocked by SlotConfig.NoMac = 1 (direct use, and indirectly via the TempKey NoMacFlag).
- **HMAC command**: exists on 508A only; "HMAC command removed, replaced via new more powerful SHA command" ([608B-SUM] §4.2).
- **SHA command, HMAC_Start with a slot key** (608): [608B-TFLX] §5.1.8.2 (mode 0x04, Param2 = slot) returns the HMAC digest. [508A] Table 2-6 says NoMac keys "cannot be used with the SHA command in HMAC mode". INFERRED that the 608B enforces the same; no 608 document read states it.
- **GenDig** ([508A] §9.6; [608B-TFLX] §5.3.3.3): mixes the slot's first 32 bytes into TempKey; "it can never be read from the device". With a NoMac slot the message uses 4 host-supplied OtherData bytes instead of opcode/params, and TempKey.NoMacFlag is set so MAC cannot output it. The resulting TempKey can still serve as (a) the data-protection key for encrypted Read/Write of slots whose ReadKey/WriteKey point at this slot, (b) the first or second block of a later CheckMac, (c) the input of Sign(internal).
- **DeriveKey** ([508A] §9.4): overwrites the *target* slot with `SHA-256(target-or-parent key ‖ … ‖ TempKey)`. Allowed only if the target's SlotConfig bit 13 = 1. A slot is used as a *parent* only by slots whose WriteKey points at it.
- **KDF** (608; [608A-TFLX] §5.3.4): "The input key may be located in either the TempKey, the Alternate Key Buffer, or an EEPROM Slot"; output "can be returned to the system in the output buffer". HKDF mode = one HMAC-SHA256 with the selected key. **NOT FOUND: which SlotConfig/KeyConfig bits forbid KDF from using a given slot as its source key** (the public documents say "contact Microchip Sales", [608B-TNG] §5.3.4). KDF-AES needs AES_Enable and ChipOptions bit 2.
- **AES command** (608): uses 16-byte keys from a slot; TFLX lists AES only for KeyType 6 slots. NOT FOUND whether KeyType 7 slots are rejected.

Answer to "can a slot be CheckMac-only?":
- Documented controls: `IsSecret = 1`, `EncryptRead = 0` (never readable), `NoMac = 1` (no MAC / HMAC / SHA-HMAC, and TempKey derived from it cannot be MAC'ed), WriteConfig bit 13 = 0 (never a DeriveKey target), `ReadKey ≠ 0` on this slot **and on the slot that would be its CheckMac/Copy target** (itself if the slot number is odd, N+1 if even), no other slot's ReadKey/WriteKey/AuthKey pointing at it, KeyType = 7.
- Microchip precedents for a NoMac secret slot: [608A-TFLX] slot 7 `0x8F9F`; [CAL] `app/pkcs11/example_pkcs11_config.c:24-32` slot 6 = bytes `9F 0F` / `3C 00` (Always-write until slot-locked, IsSecret, NoMac, ReadKey F, lockable).
- **Not closed by any document I could read:** KDF with slot source, and (608-specific confirmation of) SHA-HMAC. So "can ONLY be used for CheckMac" is documented for MAC / Read / DeriveKey, but unverified for KDF and SHA-HMAC on the 608B → sacrificial-chip test (§17 E8). CheckMac itself is a yes/no oracle on a 256-bit secret, and Sign(internal) over a GenDig of the slot yields a signature whose message depends on the secret (not invertible, but it is a secret-dependent output).

Rewriting such a secret after data-zone lock ([508A] §2.2.3, §9.21, §9.21.1; [608B-TFLX] §5.1.10.2):
- WriteConfig = Encrypt (bit 14 = 1): Nonce → GenDig(WriteKey slot) → Write with data XOR TempKey plus MAC `SHA-256(TempKey ‖ 0x12 ‖ Param1 ‖ Param2 ‖ SN[8] ‖ SN[0:1] ‖ 25 zeros ‖ plaintext)`. The authorising key is the slot named in **SlotConfig.WriteKey**; TempKey.KeyID must equal it. TFLX example: slot 5 `0x468F`, written under the key in slot 6.
- Self-rotation is documented: "WriteConfig ... Encrypt and SlotConfig.WriteKey should point back to the same slot ... provided that the authentication MAC is computed using the old (i.e. current) key value" ([508A] §2.2.3). NOT FOUND whether this works when that same slot has NoMac = 1.
- WriteConfig = Always: anyone on the bus can overwrite it (32-byte clear write) until the slot is slot-locked. WriteConfig = Never: fixed for life after data lock.
- Once the slot's SlotLocked bit is 0 nothing can rewrite it.
- ReqRandom caveat for our mode-0 CheckMac: [508A] §9.2 "If KeyConfig.ReqRandom is one, the RNG must have been used during the execution of the Nonce command, or else this command will return an error" — it is not stated whether mode 0x00 (no TempKey involved) is exempt → test (§17 E8).

---

## 5. ECDH and KDF on the 608B

ECDH modes ([608B-TFLX] Tables 5-44…5-47; bit names from [CAL] `lib/calib/calib_command.h:433-443`):

| Mode | Private key source | Output |
|---|---|---|
| 0x0C | slot | output buffer, **clear** (encrypted instead if ChipOptions.ECDHPROT = 1) |
| 0x0E | slot | output buffer, **encrypted** with the IO protection key; response = 32 B ciphertext + 32 B OutNonce |
| 0x08 | slot | kept in **TempKey** ("available for other operations but is not directly accessible") |
| 0x0D / 0x0F / 0x09 | ephemeral key in TempKey (made by GenKey mode 0x04 with KeyID 0xFFFF) | clear / encrypted / TempKey |
| 0x05 | ephemeral key in TempKey | stored in the slot given by KeyID |
| 0x00 | slot | "compatible" = 508A behaviour (clear, or slot N+1, per SlotConfig bit 3) — name from [CAL]; behaviour INFERRED from [508A] §9.5 |

- "Encryption can only occur when data is output to the output buffer." "The IO protection key is used when encryption is required." ([608B-TFLX] §5.2.1.1)
- Output encryption algorithm (documented for KDF, "in a manner similar to the ECDH command", [608A-TFLX] §5.3.4.4): `SHA-256(IO protection key(32) ‖ first 16 bytes of a device-generated 32-byte nonce)` XOR first 32 bytes; a second 32 bytes use the second half of the nonce; the nonce is returned. [CAL] host side: `calib_ecdh_ioenc()` (`lib/calib/calib_ecdh.c:196-225`).
- ChipOptions (bytes 90–91, 16-bit little-endian; [608A-TFLX] Table 2-3 and [CAL] `calib_device.h:234-249`):
  - bit 0 POST enable (self-test on power-up/wake);
  - bit 1 **IO protection key enable**;
  - bit 2 KDF AES mode enable;
  - bit 3 (per [608A-TFLX] only) Health-Test-Failure auto-clear;
  - bits 7–4 must be zero;
  - bits 9–8 **ECDHPROT**: 0 = "Output of ECDH master secret in the clear is allowed but encryption is possible"; 1 = clear-mode output is encrypted ([608B-TFLX] Table 5-44 note). Values 2 and 3: **NOT FOUND**;
  - bits 11–10 **KDFPROT**: 0 = "Output of the KDF function in the clear is allowed but encryption is possible". Other values: **NOT FOUND**;
  - bits 15–12 **IO protection key slot** (TFLX: 6).
  - TFLX value: bytes `0E 60`.
- KDF ([608A-TFLX] §5.3.4; [CAL] `calib_command.h:541-581`): algorithms PRF (TLS 1.2), AES, HKDF (one HMAC-SHA256 iteration per call); source key = TempKey / TempKey upper / slot / AltKeyBuf; target = TempKey / TempKey upper / slot / AltKeyBuf / output clear / output encrypted. So ECDH(→TempKey) followed by KDF-HKDF(source TempKey, message from input, output clear or encrypted) is a supported chain. Our protocol's HKDF (`219-protocol.md` §7.3: COSE ECDH-ES + HKDF-256 with a structured context) is extract + expand; each KDF call is a single HMAC, so reproducing it on-chip takes several calls, and the KDF message field is 0–127 bytes. KdfIvLoc/KdfIvStr only matter for the HKDF "special IV" message mode (disabled on TFLX).
- The IO protection key is a 32-byte secret shared by host and chip ([608B-TNG] §2.2.1.5: host generates it, stores it in its own flash, writes it to the slot, slot-locks it). **On a Linux host the IO key lives in the same machine's storage/RAM**, so it protects the I2C wires, not against root on the host.

---

## 6. Sign, Verify, validate/invalidate

- Sign external / internal and the internal message contents: §2.3.
- **Restricting a private key to internal signatures only: yes** — IntSignEnable = 1, ExtSignEnable = 0 (ReadKey = 0x2), e.g. TFLX/TNG slot 1 `0x0082`.
- An ExtSign-enabled key signs any 32-byte digest the host gives it; the chip cannot enforce our purpose labels (`batman-node-static-v1` etc.) — that separation exists only in host software.
- Sign needs KeyConfig.Private = 1 and IsSecret = 1; may return an ECC fault code to be retried ([508A] §9.18).
- Verify modes ([508A] §9.20; [CAL] `calib_command.h:810-819`): External (public key supplied), Stored (public key in a slot; honours PubInfo validation and ReqAuth; a success sets AuthValid for that KeyID), Validate (0x03) / Invalidate (0x07), ValidateExternal (0x01). 608 adds an optional output MAC computed with the IO protection key (mode bit 7) "to defeat any man-in-the-middle attacks" ([608B-TFLX] §5.2.5).
- Validate/Invalidate ([608B-TFLX] §5.2.5.3): for a public-key slot with PubInfo = 1; parent key = the slot named in the target's ReadKey; the signature must be over the Sign(internal)-format message built from a GenKey digest of the stored key; sets the top nibble of byte 0 to 0x5 (valid) or 0xA (invalid). With WriteConfig = PubInvalid the slot can be rewritten only after Invalidate (TFLX slot 14 `0x1F0D / 0x0012`, parent slot 13).

---

## 7. Monotonic counters

- **Two** counters, Counter[0] and Counter[1], max value **2,097,151**; never decrement; "There is no way to reset the counters"; power-loss-safe but "In some power loss conditions, the counter may increment by a value of more than one". [508A] §3.2.5, §9.3; [608B-TFLX] §5.1.1; [608B-TNG] §2.1.1.
- Counter command (opcode 0x24): Mode 0 = read, 1 = increment; KeyID 0 or 1; returns the 4-byte binary count ([608B-TFLX] Tables 5-3/5-4; [CAL] `lib/calib/calib_counter.c:50-82`).
- **No authorisation parameter exists for Counter in any document read** → INFERRED: any host on the I2C bus can increment either counter (and so can exhaust it: ~2.1 M increments). NOT FOUND: any config bit that restricts the plain Counter increment.
- Initial value: the 8 config bytes can be written before config lock; TFLX shows `FF FF FF FF 00 00 00 00` = count 0 ([608A-TFLX] Table 2-3). "The number of legal uses for a key can be controlled by initializing the Counter<0> to a non-zero value at configuration time. Contact Microchip for details." ([508A] §9.3) → the encoding of non-zero start values is NOT FOUND.
- LimitedUse (SlotConfig bit 5): Counter[0] is incremented before each use of the key; at the limit the command fails. GenKey, Read, Write ignore it; a CheckMac/Copy source ignores it ([508A] §3.2.5). On 608 it also applies to slot 15 ([608B-SUM] §4.2).
- 608 additions: **Counter Match** — "a mechanism for altering the limit to which the first monotonic counter (Counter 0) can be incremented ... The counter match value in the slot can be changed any number of times" ([AN3539] §1.1.9); enabled by CountMatch byte 18 (bit 0 enable, bits 7–4 slot). Format of the match value: NOT FOUND.
- UpdateExtra mode bit 1 on the 508A decrements the limited-use count of a key without using it ([508A] §9.19; [CAL] `UPDATE_MODE_DEC_COUNTER`, `calib_command.h:790`) — unauthenticated; 608 behaviour NOT FOUND.
- GenDig zone 0x04 (Counter) folds a counter value into TempKey ([508A] §9.6; [608B-TFLX] §5.3.3.5), so a counter value can be covered by a MAC or an internal signature.

---

## 8. Serial number and device identity

- 9-byte (72-bit) serial number in config bytes 0–3 and 8–12, "can never be written under any circumstances and can always be read" ([508A] §2.2.6). "Each ATECC608B ships with an ensured unique 72-bit serial number" ([608B-SUM] §1).
- Fixed bytes: SN[0:1] = `01 23`; SN[8] = **0xEE on standard parts** ([508A] §2.2.6: "fixed at manufacturing time in most versions ... Their default value is 0x01 23 EE") but **0x01 on Trust variants** ([608B-TNG] §2.1; [608B-TFLX] §2.1). For the blank ATECC608B-SSHDA the SN[8] value is INFERRED to be 0xEE (the [CAL] test config also carries 0xEE at byte 12, `test/api_calib/test_calib_config.c:36`, but that byte is never written by the test). Read it from the chip. SN[2:7] are unique per die.
- SN[8] and SN[0:1] enter every MAC/CheckMac/GenDig/Sign-internal hash; SN[2:7] only optionally.
- Reading the SN over I2C is unauthenticated; authenticity needs a signature/MAC (e.g. Sign(internal) with Mode bit 6).
- Identifying the silicon: **Info(Revision) returns `00 00 60 02` on ATECC608A and `00 00 60 03` on ATECC608B**; third byte 0x60 means 608; "the fourth byte for the ATECC608B could change"; "The value of the Revision mode response is not the same as the 4-byte RevNum (Bytes[4:7]) in the device configuration zone. Only the Revision mode response can be used for device identification." ([608B-TFLX] §5.1.2.1; [AN2237] Table 1-1). 508A = `00 00 50 00`. [CAL] `lib/calib/calib_helpers.c:313-345` maps only byte index 2 (0x60 → ATECC608) and does not distinguish A/B/C.
- ATECC608C revision value: NOT FOUND (no 608C document was read).
- Package marking never identifies the part ([608B-TNG] §10.1).
- Distinguishing blank vs Trust parts: Trust parts have SN[8] = 0x01, locked zones, a non-0x60 default address (TNGTLS 0x35, TFLXTLS 0x36) and an OTP code string. TNGLORA specifics: not read.

---

## 9. I2C, ChipMode, wake/sleep/idle, timing

- I2C address: config byte 16, bits 7–1; "default value of 0xC0" (8-bit) = **7-bit 0x60** ([508A] Table 2-5). For 608: [CAL] `lib/atca_cfgs.c:42-60` default `.atcai2c.address = 0xC0` for devtype ATECC608; [608B-TNG] §2.1 "The default I2C address of the ECC608-TNGTLS differs from that of the standard ATECC608 Device"; [608B-TFLX] "is not the same as that of the generic non-configured ATECC608B device". The literal value 0x60 for the blank 608B-SSHDA is therefore INFERRED from 508A + cryptoauthlib; no 608B document read states the number.
- After config lock, byte 16 is frozen. With ChipMode bit 0 = 1, byte 85 (UserExtraAdd), **if non-zero, replaces the address**; it can be written exactly once (while 0x00) with UpdateExtra, takes effect after sleep/power cycle ([608A-TFLX] Table 2-3; [608B-TNG] §2.1.1, §5.1.9). UpdateExtra has no authorisation parameter.
- ChipMode (byte 19) on 608 ([CAL] `calib_command.h:278-287`, `calib_device.h:159-168`; [608A-TFLX] Table 2-3):
  - bit 0: I2C address taken from UserExtraAdd ("Alternate I2C address mode") enable;
  - bit 1: TTLenable (0 = fixed reference input levels; 1 = VCC-referenced) — with 0, VIL max 0.5 V / VIH min 1.5 V regardless of VCC ([608B-TNG] Table 8-5);
  - bit 2: watchdog duration, 0 = 1.3 s nominal (0.7 min / 1.7 max, [608B-TNG] Table 8-2). Long value: [508A] Table 2-5 says 10 s; [CAL] comment says "~13s"; **608B value NOT FOUND**. "Microchip recommends this be set to zero for the best security" ([508A]);
  - bits 7–3: clock divider. 0x00 = M0 "High Speed"; 0x05 (byte value 0x28) = M1; 0x0D (byte value 0x68) = M2. ECC-command supply current 14 / 6 / 3 mA respectively ([608B-SUM] DC table).
  - Default ChipMode of a blank part: **NOT FOUND**. TFLX = 0x01, pkcs11 example = 0x01, cryptoauthlib test config = 0x00.
  - [AN3539] Table 4-1 (508A-like behaviour): CountMatch 0x00, ChipMode bits 3–7 zero, UseLock 0x00, VolatileKeyPermission 0x00, SecureBoot 0x0000, KdfIvLoc 0x00, KdfIvStr 0x00, UserExtraAdd 0x00, ChipOptions 0x00.
- Wake ([608B-TNG] §7.1.1, Table 8-2): hold SDA low ≥ tWLO = 60 µs, then wait tWHI = 1500 µs (20 ms if power-on self-test is enabled); "A simple way to generate a wake pulse is to send a byte of 0x00 at 100 kHz." After wake a read returns status 0x11 (Table 4-3). Power-up delay tPU 100 µs.
- Word address byte after the device address: 0x00 reset, **0x01 sleep** (all volatile state lost), **0x02 idle** (TempKey, Message Digest Buffer, Alt Key retained), 0x03 command ([608B-TNG] Table 7-2).
- Watchdog: starts at wake; when it expires the device sleeps and loses TempKey etc.; only sleep/idle + wake restarts it ([508A] §9.1.6; [608B-TNG] §7.4). Status 0xEE = "Watchdog About to Expire". So a Nonce → GenDig → CheckMac style sequence must fit in the 0.7 s minimum or use idle between commands.
- The device NACKs its address while busy, idle or asleep ([608B-TNG] §7.5) → poll for completion.
- I2C up to 1 MHz ([608B-TNG] Table 8-3). The 608A low-frequency false-wake bug (≤ 300 kHz, shared bus) is fixed on the 608B: "may still wake up at low frequency but it does not respond or cause data corruption" ([AN2237]). [608B-TNG] §7.1.1 still recommends issuing sleep/idle after talking to other devices at low speed.
- I/O block: count byte + packet + CRC-16 (poly 0x8005, init 0, LSB first), max group 155 bytes ([608B-TNG] Table 4-1). Multi-byte parameters are sent little-endian (§5 intro).
- Execution times, ms — [CAL] `lib/calib/calib_execution.c:124-199` (selected by clock divider at `:280-295`). These are the library's maximum wait values, used together with polling:

| Command | M0 (0x00) | M1 (0x28) | M2 (0x68) |
|---|---|---|---|
| AES | 27 | 27 | 27 |
| CheckMac | 40 | 40 | 40 |
| Counter | 25 | 25 | 25 |
| DeriveKey | 50 | 50 | 50 |
| ECDH | 75 | 172 | 531 |
| GenDig | 25 | 35 | 35 |
| GenKey | 115 | 215 | 653 |
| Info | 5 | 5 | 5 |
| KDF | 165 | 165 | 165 |
| Lock | 35 | 35 | 35 |
| MAC | 55 | 55 | 55 |
| Nonce | 20 | 20 | 20 |
| PrivWrite | 50 | 50 | 50 |
| Random | 23 | 23 | 23 |
| Read | 5 | 5 | 5 |
| SecureBoot | 80 | 160 | 480 |
| SelfTest | 250 | 625 | 2324 |
| SHA | 36 | 42 | 75 |
| Sign | 115 | 220 | 665 |
| UpdateExtra | 10 | 10 | 10 |
| Verify | 105 | 295 | 1085 |
| Write | 45 | 45 | 45 |

  [CAL] `calib_execution.c:37-38` (compile-time warning text): "ATECC608B supports only polling mode". With M2, Sign (665 ms) nearly fills the minimum watchdog (700 ms).

---

## 10. The blank part as shipped

- **Factory-default config zone of a blank ATECC608B-SSHDA: NOT FOUND** in any document or repository read. It must be read from a blank chip (reading the config zone is always allowed and changes nothing).
- Config arrays that exist in cryptoauthlib — none of them is "the factory default":
  - `test_ecc608_configdata`, [CAL] `test/api_calib/test_calib_config.c:35-44` — the unit-test config. It is a complete 128-byte image, but built to exercise features: CountMatch `0xA1`, UseLock byte `0xFF`, VolatileKeyPermission `0x84`, SecureBoot `03 BC`, slot 0 LimitedUse, slot 5 PersistentDisable, ChipOptions bytes `0E 40`, LockValue/LockConfig bytes `00 00` (never written). **Do not copy it.**
  - `atecc608_config`, [CAL] `app/pkcs11/example_pkcs11_config.c:24-32` ("Standard Configuration Structure for ATECC608 devices") — a plain example: address 0xC0, ChipMode 0x01, CountMatch/UseLock/VolatileKey/SecureBoot/ChipOptions all zero.
  - [608A-TFLX] Table 2-3 + Tables 2-4…2-17 — the complete TFLXTLS configuration with explanations.
- Lock state as shipped: LockValue = LockConfig = 0x55 (unlocked) "On shipment from Microchip" ([508A] Table 2-5); INFERRED for the blank 608B (SSHDA/MAHDA are the "standard blank ATECC608B devices", [608B-SUM] §3 ordering note 3).
- Before **config** lock ([508A] §2.4, §3.3.2, §9.x; INFERRED for 608B):
  - config zone read/write OK; Data and OTP zones: no read, no write;
  - GenKey, PrivWrite, DeriveKey: always error;
  - **Random and Nonce return/use the fixed pattern `FF FF 00 00 FF FF 00 00 …`** ("To simplify system testing, prior to Config Locking the RNG always returns ..."). The 608 has a new RNG ([608B-SUM] §4.2), so confirm on a chip.
- After config lock, before **data** lock:
  - slots can be written in clear with Write (non-private) and PrivWrite (private); nothing in Data/OTP can be read;
  - GenKey(create) works on any slot configured Private + IsSecret, regardless of bit 13; public-key generation works without the PubInfo check (those checks are listed under "Once the Data zone has been locked", [508A] §9.7);
  - Sign(internal) always errors; Sign(external) is not stated to be blocked ([508A] §9.18) → INFERRED usable;
  - SlotConfig/KeyConfig restrictions "generally do not apply" — so **secrets written in this window travel in clear on the I2C bus unless Write Zone bit 6 (encrypted, with a transport key via GenDig) is used** ([508A] §9.21.1, §3.2.8; transport-key values are given by Microchip "only to qualified customers").

---

## 11. Per-slot locking after data-zone lock

[508A] §2.4.3 Table 2-15; [608B-TFLX] §5.1.3.1; INFERRED identical on the blank 608B.

| SlotLocked bit | Lockable | Lock(slot) allowed | PrivWrite / Write / DeriveKey / GenKey |
|---|---|---|---|
| 0 | any | no | **never** |
| 1 | 0 | no | per SlotConfig/KeyConfig, forever |
| 1 | 1 | yes, once | per SlotConfig/KeyConfig until locked |

- A "lockable, not yet locked" slot can be changed exactly as its WriteConfig allows: Always → any clear Write; Encrypt → holder of WriteKey; private slot with bit 13 → GenKey regenerates the key (the old key is destroyed; TNG slots 2–4 work this way, [608B-TNG] §2.2.1.1).
- **Who can do it:** the Lock command (opcode 0x17, mode `00bbbb10`, CRC ignored) carries no authorisation in any document read → INFERRED: **any host on the bus** can lock a lockable slot at any time, and any host can modify an Always-write or GenKey-enabled slot until then. ReqAuth is documented as gating GenKey (§2.2), not Lock or Write.
- Slot lock does not validate contents: "The Lock command does not provide a CRC validation mechanism when using the individual slot locking mechanism" — verify the slot first (Read / CheckMac / MAC) ([508A] §2.4.3).
- Lock(slot) works before or after data-zone lock, as long as the config zone is locked ("either before or after the Data zone is locked").

---

## 12. Other features — what they are and what they need

- **IO protection key**: 32-byte shared secret in the slot named by ChipOptions[15:12], enabled by ChipOptions bit 1. Used to encrypt ECDH/KDF outputs and to MAC Verify/SecureBoot results ([AN3539] §1.1.5; [608B-TNG] §2.2.1.5). TFLX: slot 6, `0x0F8F / 0x007C`, written by the host then slot-locked.
- **SecureBoot command** (0x80): validates a host firmware digest/signature (modes Full, FullStore, FullCopy); config bytes 70–71 select mode, digest slot, public-key slot, persistent-latch behaviour ([AN3539] §2.1.1; [608A-TFLX] Table 2-3: `03 F7`). Disabled with `00 00` ([AN3539] Table 4-1). The bit positions of "persistent latch" / "random nonce" differ between [608A-TFLX] (bits 2 / 3) and [CAL] `calib_device.h:220-223` (bits 3 / 4) → unresolved; irrelevant if left at 0x0000.
- **Persistent latch**: "a single bit of volatile memory ... It can retain its state as long as the VCC remains above 2V. It is always set to low on power-up"; survives sleep/idle; set by secure boot, volatile-key permit, authorization output or intrusion detection; keys with KeyConfig.PersistentDisable = 1 work only while it is set ([AN3539] §1.1.6; [608A-TFLX] §2.2.4). Readable via Info mode 0x04.
- **Volatile key permission** (byte 69: bit 7 enable, bits 3–0 slot): a shared secret; a successful cryptographic exchange with it sets the persistent latch ([AN3539] §1.1.7; "Volatile Key Permitting to prevent device transfer", [608B-SUM] §4.2). Command-level detail: NOT FOUND.
- **Transport / UseLock** (byte 68): "The general purpose usage of the device is prohibited until the device is cryptographically enabled" with a shared secret in a slot ([AN3539] §1.1.10). Value semantics: NOT FOUND; TFLX and [AN3539] use 0x00 = disabled.
- **AES**: AES-128 ECB encrypt/decrypt and GFM, key from a slot (KeyType 6) or TempKey; needs AES_Enable (byte 13); KDF-AES additionally needs ChipOptions bit 2 ([AN3539] Table 3-1, §2.1.3; [608B-TNG] §5.3.1).
- **SelfTest / POST**: ChipOptions bit 0 runs self-tests at every power-up/wake (wake delay becomes 20 ms, [608B-TNG] Table 8-2); a failure puts the chip in a failure state until the next wake ([608B-TNG] §5.1.7).
- **X509format** (bytes 92–95) with KeyConfig.X509id: constrains Verify(ValidateExternal) certificate formats; zero = ignored ([508A] Table 2-5).
- Nothing above has to be reserved unless used; the documented "off" values are all zero ([AN3539] Table 4-1).

---

## 13. Compressed certificates

- Compressed certificate = 72 bytes: signature R‖S (64) + encoded dates (3) + signer ID (2) + template ID / chain ID (1) + SN source / format version (1) + reserved (1) ([AN8974] §2; [608B-TNG] Table 4-12). "For P256 curves, the Compressed Certificate can be stored with the signature in one of the 72 byte slots (8 to 15)" ([AN8974]).
- Device certificate: 72 bytes (public key is regenerated from the private key). Signer certificate: 72 bytes + the signer public key (72 bytes stored format) in another slot = 136 bytes of dynamic data ([608B-TNG] Table 4-12 notes).
- Trust&GO layout as a worked example: device compressed cert slot 10, signer public key slot 11, signer compressed cert slot 12, device public key from GenKey on slot 0 ([CAL] `app/tng/tngtls_cert_def_2_device.c:128-140`, `app/tng/tngtls_cert_def_1_signer.c:102-114`).
- Slot 8 (416 bytes): "Depending on the size of the serial number stored in the cert, it may or may not be possible to store two complete certificates" ([608B-TNG] §4.5.3). The full X.509 template is not stored on the chip; it lives in host firmware (`atcacert_def_t`).
- Limits of the format: issue year is 5 bits "starting from 2000. 0 to 31 (2000 to 2031)"; expiry = 0–31 years after issue, 0 = no expiration ([AN8974] §2.4; [CAL] `lib/atcacert/atcacert_def.h:203`). **A certificate issued after 2031 cannot be encoded in this original format**; whether newer format versions extend it was not checked.
- Certificate serial-number source options (stored, public-key hash, device-SN hash …): [CAL] `atcacert_def.h:85-94`.
- Private-key slots 0–7 are 36 bytes, so certificates/public keys must go in 8–15.

---

## 14. Known pitfalls relevant to locking

1. **Config lock is irreversible and freezes everything in §1.2**, including the I2C address, SlotConfig/KeyConfig, ChipOptions, initial counters and initial SlotLocked bits ([508A] §2.4.1).
2. **I2C address**: a wrong byte 16 (or bit 0 set) is permanent after config lock. With ChipMode bit 0 = 1 and byte 85 = 0, the address can still be changed once by *anyone* with UpdateExtra; Microchip's own instruction for Trust parts: "If there is no need to change the I2C address, this location must be written with the default I2C address" ([608B-TNG] §2.1.1).
3. **Lock with CRC, not Mode bit 7** — the summary CRC is the only device-side check that what was written is what was intended ([508A] §9.10).
4. **ReadKey = 0 enables CheckMac/Copy** ("Do not use zero as a default") — applies to every non-private slot ([508A] Table 2-6, §3.2.7).
5. **Always-write secret slots** (WriteConfig 0) stay overwritable by any bus host until slot-locked; "Slots set to always should never be used as key storage" ([508A] Table 2-8).
6. **Before data lock everything is weaker**: PrivWrite in clear to any private slot, clear writes, restrictions not enforced. "It is vital that the data and OTP zones be locked prior to release into the field" ([508A] §2.4).
7. **IsSecret must be 1** whenever EncryptRead = 1 or WriteConfig ≠ Always, and for every private key ([508A] Table 2-6); "IsSecret 0 + EncryptRead 1: Prohibited. No security is guaranteed" (Table 2-7).
8. **KeyType must match use**: 7 for SHA-type secrets, 4 for ECC; "Proper operation of the device is not guaranteed if these commands are attempted with any other KeyType" ([508A] §2.2.5).
9. **Lockable polarity**: 1 = lockable; the Trust data sheets' sentence "Lockable bit is set to zero" is wrong (§2.2).
10. **ECDH in clear** on an I2C bus that an attacker can probe exposes the shared secret; mitigations are ECDH→TempKey + KDF, or IO-protection encryption (§5) — neither helps against root on the host.
11. **Counters**: maximum 2,097,151, no reset, unauthenticated increment (INFERRED), possible extra counts on power loss (§7). LimitedUse keys die when Counter[0] is exhausted.
12. **Watchdog**: multi-command sequences that rely on TempKey must finish before the 0.7–1.7 s watchdog or use idle; sleep clears TempKey and AuthValid ([508A] §9.1.6).
13. **DeriveKey roll and power loss**: "Any power interruption during the execution of the DeriveKey command in Roll mode may cause the key to have an unknown value" ([508A] §3.2.2). A PrivWrite interrupted by power loss can leave an invalid key ([508A] §2.1).
14. **EEPROM endurance**: 400,000 write cycles per byte at 85 °C ([608B-TNG] Table 8-1).
15. **608A→608B**: same config bits and commands; timing of Verify/SecureBoot/Lock/Read changed (≤ 10 % for Verify) — use polling; Info revision differs ([AN2237]; [608B-SUM] §4.1).
16. **508A→608B traps**: byte 18 is CountMatch (not OTPmode: a 508A-style `0xAA`/`0x55` there would land in the Counter Match enable/slot fields), bytes 68–83 are no longer LastKeyUse (a 508A-style `0xFF` fill lands in UseLock/VolatileKey/SecureBoot/KDF fields), byte 85 is the alternate I2C address, HMAC/Pause commands are gone ([AN3539] Tables 3-1, 4-1; [608B-SUM] §4.2).
17. **Physical attacks** (web-search result summaries only; the papers themselves were not read): Ledger Donjon published laser fault-injection attacks on the ATECC508A (2020) and ATECC608A (2021, "Defeating a Secure Element with Multiple Laser Fault Injections", Black Hat USA / SSTIC), after which Microchip released the 608B; later Donjon material discusses the 608B's countermeasures. Microchip's own wording: the 608B changes "were primarily done to enhance device security and are largely transparent to the user" ([AN2237] Conclusion).

---

## 15. Linux / OpenWrt practicalities

- cryptoauthlib Linux I2C HAL: `lib/hal/hal_linux_i2c_userspace.c` — opens `/dev/i2c-<bus>` (`:98`, `:167`), `ioctl(I2C_SLAVE, addr >> 1)` (`:174`), plain `write()`/`read()`. `hal_i2c_control()` returns `ATCA_UNIMPLEMENTED` for every option (`:246-257`), i.e. **the HAL cannot change the bus speed**.
- Wake in cryptoauthlib ([CAL] `lib/calib/calib_basic.c:37-82`): it tries to drop the bus to 100 kHz via the HAL control (unimplemented on Linux), then performs a transfer to **I2C address 0x00** to produce the wake pulse, then restores the address. So on Linux the pulse width depends on the adapter's configured bus clock: at 100 kHz a 0x00 byte holds SDA low for about 80–90 µs (> tWLO 60 µs); at 400 kHz about 20 µs (< tWLO) — arithmetic from the bit time, not measured. Default config uses `baud = 100000` on Linux (`lib/atca_cfgs.c:52-54`). After each command the library puts the device into **idle** (`lib/calib/calib_execution.c:477-478`, `:626`).
- The interface config takes the **8-bit** address (0xC0 for 7-bit 0x60) ([CAL] `lib/atca_cfgs.c:47-49`).
- CMake options ([CAL] `lib/CMakeLists.txt:7-46`): `ATCA_HAL_I2C` ("Linux & MCU only"), `ATCA_HAL_KIT_HID`, `ATCA_HAL_KIT_UART`, `ATCA_HAL_KIT_BRIDGE`, `ATCA_HAL_SPI`, `ATCA_HAL_CUSTOM`, `ATCA_PKCS11`, `ATCA_BUILD_SHARED_LIBS` (ON), `ATCA_NO_HEAP`, `ATCA_USE_ATCAB_FUNCTIONS`, `ATCA_OPENSSL` / `ATCA_MBEDTLS` / `ATCA_WOLFSSL`, `ATCA_TNGTLS_SUPPORT` / `ATCA_TNGLORA_SUPPORT` / `ATCA_TFLEX_SUPPORT`, `ATCA_PRINTF`. Top-level `CMakeLists.txt:11` `BUILD_TESTS` (OFF). Host-side helper math (MAC, GenDig, IO-decrypt, CheckMac) is in `lib/host/atca_host.c`.
- Device-type detection by Info revision: `lib/calib/calib_helpers.c:313-345`.
- An OpenWrt package for cryptoauthlib: not searched.
- Go without cgo:
  - `github.com/northvolt/go-atecc` → the repository is now **`northvolt/go-atecc-old`, archived** (last push 2026-03-31, Apache-2.0, 3 stars) — "A driver for the Microchip ATECC608 device in Go".
  - `github.com/bobo/go-atecc` — a fork of it (created 2024-11-19, last push 2025-01-08, 0 stars, Apache-2.0). `go.mod`: Go 1.22, depends on `golang.org/x/crypto`, `periph.io/x/conn/v3`, `periph.io/x/host/v3` (I2C through periph, pure Go). README: "It supports communication using I²C and USB for dev kits", "The API is not fully stable", "If cgo is disabled, the USB support is also disabled" (I2C remains). Tree has `pkg/atecc` (commands, packet, CRC, I2C HAL) and `pkg/ateccconf`.
  - I did not review either package's command coverage (CheckMac, Counter, Lock, internal Sign) or correctness. No other Go driver turned up in a GitHub repository search for "atecc608 language:go".

---

## 16. Not found / uncertain

| # | Item | Status |
|---|---|---|
| U1 | ATECC608B complete data sheet (NDA) and ATECC608A complete data sheet | not read; all bit tables are from the 508A complete data sheet + cryptoauthlib + TFLXTLS examples |
| U2 | Factory-default config zone of a blank ATECC608B-SSHDA (incl. default ChipMode, AES_Enable, SN[8], I2C address byte) | NOT FOUND — read from a chip |
| U3 | Whether AES_Enable (byte 13) is user-writable on a blank part | NOT FOUND |
| U4 | Which config bits (if any) stop KDF from using a slot as source key; whether NoMac blocks SHA-HMAC and KDF on the 608B | NOT FOUND (SHA-HMAC: 508A wording only) |
| U5 | ChipOptions ECDHPROT / KDFPROT values 2 and 3; behaviour of ECDH mode 0x00 and of SlotConfig bit 3 with the new modes | NOT FOUND |
| U6 | CountMatch value format, UseLock semantics (why the test config uses 0xFF), VolatileKeyPermission command flow | NOT FOUND (only one-paragraph descriptions in AN3539) |
| U7 | Long watchdog duration on 608B (10 s per 508A vs "~13s" per cryptoauthlib comment) | conflicting |
| U8 | SecureBoot config bit positions (TFLXTLS data sheet vs cryptoauthlib macros) | conflicting |
| U9 | cryptoauthlib macros `ATCA_SLOT_CONFIG_GEN_KEY_SHIFT (8)` / `PRIV_WRITE_SHIFT (9)` vs data-sheet bits 13 / 14 | data sheet + real configs say 13 / 14 |
| U10 | "Lockable bit is set to zero" sentence in TNGTLS/TFLXTLS data sheets | contradicted by 508A table and TFLXTLS hex values |
| U11 | Whether Counter, Lock(slot), UpdateExtra can be restricted/authorised | no restriction documented; "anyone on the bus" is an inference from absence |
| U12 | Whether ReqAuth gates ECDH; whether ReqRandom affects CheckMac mode 0x00 | NOT FOUND |
| U13 | OTP writability between config lock and data lock on the 608B | ambiguous wording |
| U14 | Encoding of a non-zero initial counter value | "Contact Microchip" |
| U15 | Whether the device validates CheckMac OtherData contents (e.g. OtherData[0] = 0x08) or only hashes them | not stated |
| U16 | ATECC608C Info revision; TNGLORA variant details | not searched / not read |
| U17 | Laser-fault papers | known only from search-result summaries |
| U18 | Go drivers' command coverage and quality | not reviewed |
| U19 | Freshness inference of §3 (GenKey mode byte inside the attested digest) | my inference from message formats; untested |

---

## 17. Must be confirmed on a sacrificial chip before locking the rest

Order matters: E1–E3 change nothing permanent; everything from E4 on consumes the chip.

- **E1 (read-only).** Info(Revision) → expect `00 00 60 03`. Read all 128 config bytes of a blank chip and archive them: record SN[8], byte 13 (AES_Enable), byte 14, byte 16 (expect 0xC0), byte 19, bytes 52–67 (counter encoding of zero), 68–83, 84–91; confirm LockValue = LockConfig = 0x55 and SlotLocked = FF FF. (Resolves U2.)
- **E2 (read-only, unlocked).** Random before config lock: confirm the `FF FF 00 00…` test pattern on the 608B. Confirm Read/Write of Data and OTP zones fail, and GenKey fails.
- **E3 (reversible, before lock).** Write the candidate config, read it back, compare the user-writable ranges (16–51, 68–83, 90–127), try writing byte 13 (U3). Compute the Lock CRC on the host over the read-back image. Nothing is permanent until Lock.
- **E4. Config lock with CRC** (not mode 0x80). Then confirm: address unchanged after sleep/power cycle; config zone no longer writable; Random now random.
- **E5 (config locked, data unlocked).** Confirm what the open window allows: clear PrivWrite into the DAC slot (expect success → documents the provisioning-trust caveat of §3), GenKey(create) on a slot with bit 13 = 0, Sign(external) and Sign(internal) results, whether OTP is writable (U13).
- **E6. Data lock with CRC.** Then, on each private slot with bit 14 = 0: PrivWrite (clear and encrypted) must fail; Write must fail; GenKey(create) must fail where bit 13 = 0 and succeed where bit 13 = 1.
- **E7. Attestation.** Nonce(verifier value) → GenKey 0x0C on a regenerable slot → Sign(internal, attestation key, with SN); rebuild the 55-byte message on the host and verify the signature; repeat with GenKey 0x08 and confirm the digests differ by Param1 (U19). Confirm Sign(external) on the IntSign-only key fails, and Sign(internal) on the ExtSign-only key fails.
- **E8. Claim-secret slot (the important one).** With the intended SlotConfig/KeyConfig (IsSecret, NoMac, ReadKey ≠ 0, no DeriveKey, KeyType 7):
  - CheckMac mode 0x00 with our exact vector (OtherData `08 00…00`, the device's own SN bytes) → match; wrong response → 0x01; confirm it works with the chosen ReqRandom setting (U12, U15);
  - each of these must **fail**: MAC with the slot; Nonce + GenDig(slot) then MAC with TempKey; SHA HMAC_Start with the slot; **KDF HKDF / PRF with source = slot and output to the buffer (clear and encrypted)**; AES with the slot; Read (clear, and after GenDig); DeriveKey targeting it; CheckMac mode 0x01 followed by MAC (copy path), for both this slot and slot N+1;
  - if any of them succeeds, the slot is not CheckMac-only and the design must change before any real chip is locked (U4).
- **E9. Rewrite policy of the claim secret**, whichever is chosen: (a) Always + slot lock: confirm clear write works before Lock(slot) and fails after, and that Lock(slot) needs no authorisation (U11); (b) Encrypt with WriteKey: confirm the GenDig + encrypted Write + MAC flow, including when WriteKey is a NoMac slot.
- **E10. ECDH slot.** Mode 0x0C (clear), 0x0E (encrypted, decrypt with the IO key on the host), 0x08 (TempKey) + KDF; compare the shared secret with a software P-256 ECDH; confirm behaviour under the chosen ECDHPROT value and that a slot with ECDHEnable = 0 (the DAC slot) refuses ECDH. Check whether ReqAuth (if used) gates ECDH (U12).
- **E11. Counters.** Read both; increment Counter[1] once from a fresh wake with no prior authorisation (U11); confirm it survives a power cycle; confirm Counter[0] behaviour if LimitedUse is used anywhere. Do **not** run to exhaustion on a chip you want to keep.
- **E12. UpdateExtra.** Confirm whether bytes 84/85 can be written once by an unauthenticated host under the chosen ChipMode bit 0, and that with bit 0 = 0 a non-zero byte 85 does not change the address.
- **E13. Slot lock.** On a Lockable slot: Lock(slot) from a fresh wake; confirm the SlotLocked bit clears, the slot can no longer be modified, the key still works; confirm Lock(slot) on a non-lockable slot fails.
- **E14. Timing / watchdog on the real host.** Wake via the Pi's actual I2C clock setting; measure Nonce → GenDig → CheckMac and GenKey → Sign sequences against the 0.7 s minimum watchdog; confirm polling and idle keep TempKey.
- **E15. Certificates.** Write a 72-byte compressed certificate and a 72-byte stored-format public key to the chosen slots, read back, rebuild the X.509 on the host, verify the chain.
