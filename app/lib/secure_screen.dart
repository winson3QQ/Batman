// #254 app — design 254-app-s1 §4: a page that shows a secret (root_password) is FLAG_SECURE: no screenshot, no screen
// recording, a blank Recents thumbnail. SecureScreen wraps whatever shows the secret, whatever the page looks like:
// the window flag goes on when the first one enters the tree and off when the last one leaves it (pop, replaced route,
// the whole tree gone); a killed app has no window left. The child is built only after Android answered that the flag
// is on — when it cannot be set, the secret is not shown. Android side: SecureScreen.kt, channel dev.batman/secure.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const secureChannel = MethodChannel('dev.batman/secure');

class SecureScreen extends StatefulWidget {
  const SecureScreen({super.key, required this.child, this.fallback});
  final Widget child;

  /// #329 PR 5 R3: shown instead of the default sentence when the flag cannot be set; null = the default (unchanged)
  final Widget? fallback;

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  /// the SecureScreens in the tree: a page replaced by another secure page keeps the flag (the new one enters first)
  static int _held = 0;
  bool? _on; // null = asked, no answer yet

  @override
  void initState() {
    super.initState();
    _held++;
    // asked every time (setting it twice is the same flag); calls on one channel are handled in order, so a `false`
    // from a page that just left cannot land after this
    secureChannel.invokeMethod<bool>('set', true).then((v) => v == true, onError: (_) => false).then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  void dispose() {
    if (--_held == 0) secureChannel.invokeMethod<bool>('set', false).then((_) {}, onError: (_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_on) {
        true => widget.child,
        false => widget.fallback ?? const Center(child: Text('這支手機無法防止這個畫面被截圖，所以不顯示內容')),
        null => const SizedBox.shrink(),
      };
}
