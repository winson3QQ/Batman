// design 254-app-s1 §4 (the root_password page is FLAG_SECURE): SecureScreen sets the window flag when it enters the
// tree and clears it when it leaves — by pop, by a replaced route, or with the whole tree; two of them overlapping
// (one secure page replaced by another) never leave a moment without the flag; the child is not built before Android
// answered that the flag is on, and never when it cannot be set. The channel is a fake that keeps the flag as the
// window would; the Android side is SecureScreen.kt (SecureScreenTest, and on the phone).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:batman_app/secure_screen.dart';

const secret = 'not-a-real-password';

void main() {
  late List<bool> calls; // every `set` argument, in order
  late bool flag; // the fake window's FLAG_SECURE
  late List<String> shownWithoutFlag; // a frame that showed the secret while the flag was off

  /// [answer]: what the platform does with `set` — null = sets the flag like Android; otherwise its reply / throw
  void platform(WidgetTester t, {Object? Function(bool on)? answer}) {
    calls = [];
    flag = false;
    shownWithoutFlag = [];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, (c) async {
      expect(c.method, 'set');
      final on = c.arguments as bool;
      calls.add(on);
      if (answer != null) return answer(on);
      return flag = on;
    });
  }

  /// after every pump: the secret is on screen only while the flag is on
  Future<void> pump(WidgetTester t) async {
    await t.pumpAndSettle();
    if (find.text(secret).evaluate().isNotEmpty && !flag) shownWithoutFlag.add('calls so far: $calls');
  }

  Widget secretPage() => const Scaffold(body: SecureScreen(child: Text(secret)));
  Widget home() => Builder(
      builder: (c) => Scaffold(
          body: TextButton(
              onPressed: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => secretPage())), child: const Text('open'))));

  testWidgets('set on enter, cleared on pop', (t) async {
    platform(t);
    await t.pumpWidget(MaterialApp(home: home()));
    await pump(t);
    expect(calls, isEmpty, reason: 'a page without a secret does not touch the flag');
    await t.tap(find.text('open'));
    await pump(t);
    expect(calls, [true]);
    expect(flag, isTrue);
    expect(find.text(secret), findsOneWidget);
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await pump(t);
    expect(calls, [true, false]);
    expect(flag, isFalse);
    expect(shownWithoutFlag, isEmpty);
  });

  testWidgets('cleared when the route is replaced by a page without a secret', (t) async {
    platform(t);
    await t.pumpWidget(MaterialApp(home: home()));
    await t.tap(find.text('open'));
    await pump(t);
    expect(flag, isTrue);
    t.state<NavigatorState>(find.byType(Navigator)).pushReplacement(MaterialPageRoute<void>(builder: (_) => const Text('plain')));
    await pump(t);
    expect(find.text(secret), findsNothing);
    expect(calls, [true, false]);
    expect(flag, isFalse);
  });

  testWidgets('cleared when the whole tree goes away', (t) async {
    platform(t);
    await t.pumpWidget(MaterialApp(home: secretPage()));
    await pump(t);
    expect(flag, isTrue);
    await t.pumpWidget(const SizedBox());
    await pump(t);
    expect(calls, [true, false]);
    expect(flag, isFalse);
  });

  testWidgets('a secure page replaced by another secure page: the flag never goes off in between', (t) async {
    platform(t);
    await t.pumpWidget(MaterialApp(home: secretPage()));
    await pump(t);
    t.state<NavigatorState>(find.byType(Navigator)).pushReplacement(MaterialPageRoute<void>(builder: (_) => secretPage()));
    await pump(t);
    expect(calls, [true, true], reason: 'no false while one of them is up');
    expect(flag, isTrue);
    expect(find.text(secret), findsOneWidget);
    expect(shownWithoutFlag, isEmpty);
    await t.pumpWidget(const SizedBox());
    await pump(t);
    expect(calls, [true, true, false]);
    expect(flag, isFalse);
  });

  testWidgets('the secret is not built before the platform answered', (t) async {
    platform(t);
    await t.pumpWidget(MaterialApp(home: secretPage()));
    expect(find.text(secret), findsNothing, reason: 'first frame: asked, not answered');
    await pump(t);
    expect(find.text(secret), findsOneWidget);
  });

  for (final (name, answer) in <(String, Object? Function(bool))>[
    ('throws', (on) => throw PlatformException(code: 'arg')),
    ('answers false', (on) => false),
    ('answers null', (on) => null),
  ]) {
    testWidgets('the flag cannot be set (platform $name): the secret is never shown', (t) async {
      platform(t, answer: answer);
      await t.pumpWidget(MaterialApp(home: secretPage()));
      await pump(t);
      expect(calls, [true]);
      expect(find.text(secret), findsNothing);
      expect(find.textContaining('不顯示內容'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await pump(t);
      expect(calls, [true, false], reason: 'still cleared on the way out');
    });
  }

  // flutter_test leaves a call nobody handles unanswered: the page stays empty
  testWidgets('no platform side at all (no answer): the secret is never shown', (t) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(secureChannel, null);
    await t.pumpWidget(MaterialApp(home: secretPage()));
    await t.pumpAndSettle();
    expect(find.text(secret), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
}
