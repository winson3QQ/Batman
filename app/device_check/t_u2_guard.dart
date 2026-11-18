// #329 PR 6 (review pr6-delta-D M-1): when the T-U2 device check may run. Its `firstRun` regenerates all four keys
// (Keys.kt firstRun), so it must never run over a package that holds keys or records — on 2026-11-18 it ran under the
// S20's dev3, which held node 7C31, and that node's owner key was lost (only a re-flash brings the node back).

/// The four keys (KeyPolicy.kt `enum class KeyRole`); `keyLevels` also carries six ability booleans, never null, so
/// only these names say whether a key exists (null = no key yet).
const keyRoles = ['RECORD_AES', 'OWNER_SIGN', 'ADMIN_SIGN', 'OWNER_ENC'];

/// The app's own flavors (build.gradle.kts): the check never runs under one of them, only under a temporary flavor
/// made for it.
const appFlavors = {'dev', 'dev2', 'field'};

/// The one flavor it runs under (review pr6-delta-E / F MINOR-1: an allow-list, not only the app's names — dev3 was a
/// temporary flavor too, and it held a node).
const tu2Flavor = 'tu2';

/// Why T-U2 must not run, or null when it may. Fail-closed: no flavor, no levels, a missing role name or any key
/// present all refuse.
String? tu2Refusal({required String? flavor, required Map<String, dynamic>? levels, required bool hasRecords}) {
  if (flavor != tu2Flavor || appFlavors.contains(flavor)) return 'flavor ${flavor ?? '?'} is not $tu2Flavor';
  if (levels == null) return 'key levels could not be read';
  final held = [for (final r in keyRoles) if (!levels.containsKey(r) || levels[r] != null) r];
  if (held.isNotEmpty) return 'this package already has keys (${held.join(', ')})';
  if (hasRecords) return 'this package already has records';
  return null;
}
