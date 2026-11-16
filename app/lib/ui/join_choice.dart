// #329 PR 5 R16 (AC-m1): which network a 「加入網路」 joins. Moved from nodes.dart (PR 6 deletes it) unchanged: only
// a network this phone made -> the leader's join; only an imported team network -> the member's; both -> the user
// picks (PR 2 review B-M2: neither path may vanish); neither -> nothing to join.

enum JoinChoice { own, member, ask, none }

/// #329 §3.4 S3 / T-N2: what the one 「加入網路」 does.
JoinChoice joinChoice({required bool hasNet, required bool hasMnet}) => switch ((hasNet, hasMnet)) {
      (true, false) => JoinChoice.own,
      (false, true) => JoinChoice.member,
      (true, true) => JoinChoice.ask,
      (false, false) => JoinChoice.none,
    };

/// R16 (AA-M1): NetFormPage's mode, given by the entry (or by joinChoice in the page when none was given).
enum NetMode { leader, member }

/// R16: the team network's entry node is not on this phone.
const kNotEntryNode = '這台不是你加入隊伍時用的節點；要讓它加入，請隊長再邀請一次';

/// R16 / V-m5: the team network has no entry left.
const kNeedNewInvite = '這筆隊伍網路的加入資料已經沒有了，需要隊長的新邀請';
