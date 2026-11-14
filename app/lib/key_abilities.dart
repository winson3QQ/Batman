// #254 app S1 — what this phone's keys allow (design v8.5.1 §4.1 table). Kotlin reads the four Keystore levels live
// and decides with KeyPolicy (`keyLevels`); this file only turns that answer into "which entries are on, and what to
// say when one is off". Fail closed: no answer, a missing entry, a value that is not a bool, or a platform error = off.
import 'package:flutter/services.dart';

/// The uses the §4.1 table gates (the map entry of each is its name).
enum KeyUse { claim, login, recover, makeNetwork }

class KeyAbilities {
  const KeyAbilities(
      {required this.appUsable,
      required this.claim,
      required this.login,
      required this.recover,
      required this.makeNetwork,
      required this.softOwnerEnc,
      this.unread = false,
      this.missing = const {}});

  /// Nothing allowed: what an unreadable answer means (not the same as a key that does not fit: it may be transient).
  static const none = KeyAbilities(
      appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, softOwnerEnc: false, unread: true);

  static const _roles = ['RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'];

  /// From the `keyLevels` answer. Anything but a `true` under the exact name is a no; one malformed entry of the six
  /// (missing, or not a bool) or of the four levels (missing, or neither an int nor null) makes the whole answer
  /// unreadable. A level of null = that key has no Keystore entry (lost): its uses are off whatever the six say.
  factory KeyAbilities.from(Map<Object?, Object?>? m) {
    if (m == null) return none;
    const names = ['appUsable', 'claim', 'login', 'recover', 'makeNetwork', 'softOwnerEnc'];
    if (names.any((n) => m[n] is! bool)) return none;
    if (_roles.any((r) => !m.containsKey(r) || (m[r] != null && m[r] is! int))) return none;
    final missing = {
      for (final r in _roles)
        if (m[r] == null) r
    };
    bool has(String r) => !missing.contains(r);
    final usable = m['appUsable'] == true && has('RECORD_AES');
    // record AES row: the whole app is off, whatever the rest says; owner signing gates every use
    bool on(String n) => usable && has('OWNER_SIGN') && m[n] == true;
    return KeyAbilities(
        appUsable: usable,
        claim: on('claim') && has('OWNER_ENC'),
        login: on('login'),
        recover: on('recover') && has('OWNER_ENC'),
        makeNetwork: on('makeNetwork') && has('ADMIN_SIGN'),
        softOwnerEnc: m['softOwnerEnc'] == true,
        missing: missing);
  }

  /// The live read (design §4.1: at every start and before each claim / recovery / login / network creation).
  /// [detail] gets the raw answer (levels and booleans, nothing secret) or the error, for the technical section.
  static Future<KeyAbilities> read(MethodChannel platform, {void Function(String)? detail}) async {
    try {
      final m = await platform.invokeMethod<Object?>('keyLevels');
      detail?.call('$m');
      return KeyAbilities.from(m as Map<Object?, Object?>?);
    } catch (e) {
      // PlatformException, MissingPluginException, an answer that is not a map
      detail?.call('讀取失敗（${e is PlatformException ? '${e.code} ${e.message}' : e.runtimeType}）');
      return none;
    }
  }

  final bool appUsable, claim, login, recover, makeNetwork, softOwnerEnc;

  /// The answer could not be read (platform error, malformed): nothing is known about the keys.
  final bool unread;

  /// The roles whose key has no Keystore entry (§4.1 「單一金鑰遺失」).
  final Set<String> missing;

  static const appOff = '這支手機無法用硬體保護節點紀錄，資料無法安全存放，App 已停用';
  static const unreadOff = '讀不到這支手機的金鑰狀態，App 暫時不能使用，請再試一次';
  static const aesGone = '保護節點紀錄的金鑰不見了，紀錄打不開，App 已停用（紀錄沒有刪除）';
  static const allGone = '這支手機的四把金鑰都不見了，App 已停用。唯一的出路：清除 App 資料或重新安裝；節點需要重燒卡回收';
  static const ownerGone = '這支手機的擁有者金鑰不見了，不能登入、認領或接續認領；紀錄還讀得到，節點需要重燒卡回收';
  static const adminGone = '這支手機的網路管理金鑰不見了，不能建立或更改網路';
  static const encGone = '這支手機的復原／成員金鑰不見了，不能接續沒完成的認領（還沒認領完的節點需要重燒卡）';
  static const _ownerOff = '這支手機的擁有者金鑰不是硬體保護';
  static const _encOff = '這支手機的復原／成員金鑰不是硬體保護';
  static const _adminOff = '這支手機的網路管理金鑰不是硬體保護';

  /// Why the whole app is off (only meaningful while [appUsable] is false): unread, lost, or not hardware.
  String get offReason => unread
      ? unreadOff
      : missing.length == _roles.length
          ? allGone
          : missing.contains('RECORD_AES')
              ? aesGone
              : appOff;

  /// Kotlin's own gate refused a key use (MainActivity.gate -> KeyPolicy.refused): error code `keyLevel`, message =
  /// the role, details = its live level (null = no key). Null = [e] is not that refusal.
  static String? refusedBy(Object e) {
    if (e is! PlatformException || e.code != 'keyLevel') return null;
    final gone = e.details == null;
    return switch (e.message) {
      'RECORD_AES' => gone ? aesGone : appOff,
      'OWNER_SIGN' => gone ? ownerGone : _ownerOff,
      'ADMIN_SIGN' => gone ? adminGone : _adminOff,
      'OWNER_ENC' => gone ? encGone : _encOff,
      _ => '這支手機的金鑰不符合要求',
    };
  }

  bool allows(KeyUse use) => switch (use) {
        KeyUse.claim => claim,
        KeyUse.login => login,
        KeyUse.recover => recover,
        KeyUse.makeNetwork => makeNetwork,
      };

  /// Null = allowed; else the one line that says why not (§4.1 「不符時」).
  String? refusal(KeyUse use) {
    if (!appUsable) return offReason;
    if (allows(use)) return null;
    // owner signing gates all four; with it fine, the use's own second key is the one that does not fit
    if (!login) return missing.contains('OWNER_SIGN') ? ownerGone : '$_ownerOff，不能認領或登入節點';
    final encLost = missing.contains('OWNER_ENC');
    return switch (use) {
      KeyUse.makeNetwork => missing.contains('ADMIN_SIGN') ? adminGone : '$_adminOff，不能建立網路',
      KeyUse.recover => encLost ? encGone : '$_encOff，不能接續沒完成的認領',
      _ => encLost ? '這支手機的復原／成員金鑰不見了，不能認領節點' : '$_encOff，不能認領節點',
    };
  }
}
