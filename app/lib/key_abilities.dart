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
      required this.softOwnerEnc});

  /// Nothing allowed: what an unreadable answer means.
  static const none =
      KeyAbilities(appUsable: false, claim: false, login: false, recover: false, makeNetwork: false, softOwnerEnc: false);

  /// From the `keyLevels` answer. Anything but a `true` under the exact name is a no; one malformed entry of the six
  /// (missing, or not a bool) makes the whole answer unreadable.
  factory KeyAbilities.from(Map<Object?, Object?>? m) {
    if (m == null) return none;
    const names = ['appUsable', 'claim', 'login', 'recover', 'makeNetwork', 'softOwnerEnc'];
    if (names.any((n) => m[n] is! bool)) return none;
    final usable = m['appUsable'] == true;
    bool on(String n) => usable && m[n] == true; // record AES row: the whole app is off, whatever the rest says
    return KeyAbilities(
        appUsable: usable,
        claim: on('claim'),
        login: on('login'),
        recover: on('recover'),
        makeNetwork: on('makeNetwork'),
        softOwnerEnc: m['softOwnerEnc'] == true);
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

  static const appOff = '這支手機無法用硬體保護節點紀錄，資料無法安全存放，App 已停用';
  static const _ownerOff = '這支手機的擁有者金鑰不是硬體保護';
  static const _encOff = '這支手機的復原／成員金鑰不是硬體保護';
  static const _adminOff = '這支手機的網路管理金鑰不是硬體保護';

  bool allows(KeyUse use) => switch (use) {
        KeyUse.claim => claim,
        KeyUse.login => login,
        KeyUse.recover => recover,
        KeyUse.makeNetwork => makeNetwork,
      };

  /// Null = allowed; else the one line that says why not (§4.1 「不符時」).
  String? refusal(KeyUse use) {
    if (!appUsable) return appOff;
    if (allows(use)) return null;
    // owner signing gates all four; with it fine, the use's own second key is the one that does not fit
    if (!login) return '$_ownerOff，不能認領或登入節點';
    return switch (use) {
      KeyUse.makeNetwork => '$_adminOff，不能建立網路',
      KeyUse.recover => '$_encOff，不能接續沒完成的認領',
      _ => '$_encOff，不能認領節點',
    };
  }
}
