// #254 app — the words the screens use. On-screen lines are plain Traditional Chinese; the logcat copy of a line keeps
// its English prefix tag ("BMAPP owner", "BMAPP claim", ...) and may start with ASCII markers ("[LOGGED_IN] ",
// "[ANSWER] [NET_MADE] ", ...) that scripts grep for. The screen never shows the markers.

final _markers = RegExp(r'^(?:\[[A-Z_]+\] )+');

/// [line] without its leading log markers: what the screen shows.
String screenText(String line) => line.replaceFirst(_markers, '');

/// A node state as STATUS names it (protocol value from batman_proto::status), in words.
String stateText(String state) => switch (state) {
      'unclaimed' => '未認領',
      'claimed' => '已認領（還沒加入網路）',
      'member' => '已加入網路',
      'legacy' => '舊版節點',
      _ => '狀態不明',
    };
