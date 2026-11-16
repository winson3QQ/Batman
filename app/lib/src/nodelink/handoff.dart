// #329 PR 3 §2.2: what a login under a lease hands to the flow that asked for it (OwnerConsole): the open link, the
// Rust session and the frames from the node, none lost between the login and the flow's first request.
import 'dart:async';

import '../rust/api/owner.dart' show OwnerSession;
import 'ble_gate.dart';

/// The node's frames, in order, for one handler at a time. Built before the subscription; frames that arrive while
/// no handler is set are kept and handed over, in order, when the next one is set (§2.2: the prober sets none while
/// it handles `loggedIn`, the flow sets its own after the hand-off).
class FrameInbox {
  final List<List<int>> _held = [];
  void Function(List<int> frame)? _onFrame;
  void Function(Object error)? _onError;
  Object? _error;

  int get held => _held.length;

  void add(List<int> frame) {
    final h = _onFrame;
    if (h != null && _held.isEmpty) {
      h(frame);
    } else {
      _held.add(frame);
    }
  }

  void addError(Object error) {
    final h = _onError;
    if (h != null && _held.isEmpty) {
      h(error);
    } else {
      _error ??= error; // after the held frames, once
    }
  }

  /// Set (or clear, with nulls) the handler; held frames go to it first, in order, then a held error.
  void handle(void Function(List<int> frame)? onFrame, void Function(Object error)? onError) {
    _onFrame = onFrame;
    _onError = onError;
    while (_held.isNotEmpty && onFrame != null && identical(_onFrame, onFrame)) {
      onFrame(_held.removeAt(0));
    }
    final e = _error;
    if (e != null && _held.isEmpty && onError != null && identical(_onError, onError)) {
      _error = null;
      onError(e);
    }
  }
}

/// A logged-in session on an open link (§2.1 結果 ok). The receiver owns all of it from now on, `link.state` and the
/// subscription's errors (through [inbox]) included; [close] gives it all up.
class LoginHandoff {
  LoginHandoff({
    required this.id,
    required this.link,
    required this.inbox,
    this.session,
    this.sub,
    this.detail = '',
  });
  final String id;
  final GateLink link;
  final FrameInbox inbox;

  /// The Rust session (null only in tests that fake the flow).
  final OwnerSession? session;
  final StreamSubscription<List<int>>? sub;

  /// The `loggedIn` step's text (the old console showed it as [LOGGED_IN]).
  final String detail;

  bool _closed = false;
  bool get closed => _closed;

  /// Idempotent: stop handling frames, cancel the subscription, close the link (waits until it is gone), dispose the
  /// session. Each step on its own; a failure never stops the next.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    inbox.handle(null, null);
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await link.close();
    } catch (_) {}
    try {
      session?.dispose();
    } catch (_) {}
  }
}
