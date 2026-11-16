// #329 PR 4 §2.8 (design §4.8, boards 9.x): the software update from the node page. The update page and its flow are
// 254-app-update v0.4, unchanged; what is new is the way to the node: an OpenSession holds the session lease while the
// page is open (through the node's reboot after 套用), logs in again before a request when the login is gone, and
// every call of the update gets the update's own clock (review D M1). The update left half-way stays in AppLink.sw
// (the home page's todo 「軟體更新還沒做完」).
import 'package:flutter/material.dart';

import '../src/flows/op_session.dart';
import '../src/flows/owner_console.dart' show RustSwLink, SwLink;
import '../src/nodelink/app_link.dart';
import '../src/rust/api/swupdate.dart' show SwKind, SwUpdate, swSpecifierText;
import '../swupdate.dart';
import 'settings_pages.dart' show WifiPage, opDeps;
import 'ui_state.dart';

/// The update page's answer: 「去設定手機 Wi-Fi」 (the update waits in AppLink.sw).
const goWifi = 'wifi';

/// A new update of a node (Rust's flow); tests pass their own.
(SwLink, SwHold) rustUpdate() {
  final sw = SwUpdate();
  return (RustSwLink(sw), SwHold(RustSwFlow(sw)));
}

/// Opens the update page of [id] under its own lease; null when another operation holds it (the page does not open).
Future<void> openSwUpdate(BuildContext context, AppLink a, UiState ui, String id,
    {OpDeps? deps, (SwLink, SwHold) Function()? make, String? Function()? specifier}) async {
  final s = await OpenSession.open(deps ?? opDeps(a), id, '軟體更新');
  if (!context.mounted) {
    await s?.pageGone();
    return;
  }
  if (s == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('另一個操作還在進行：${a.reg.current?.name ?? ''}')));
    return;
  }
  final (link, h) = a.sw.take(id, make ?? rustUpdate);
  String? r;
  try {
    r = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (c) => SwUpdatePage(
              hold: h,
              // one request on the page's session; no request could go out -> the flow's noLink (as `_askSw` without a
              // session); always on the update's clock
              ask: (ms) => s.run((con) => con.askSw(link, h.now, ms), failed: (_) => link.noLink(h.now())),
              specifierText: (specifier ?? swSpecifierText)(),
              onShown: a.sw.touched,
              onSetAp: () => Navigator.of(c).pop(goWifi),
            )));
  } finally {
    await s.pageGone(); // the console closes, then the lease goes (the Wi-Fi page can take it next)
  }
  if (h.last?.kind == SwKind.done) a.sw.drop(id);
  if (r == goWifi && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => WifiPage(app: a, ui: ui, id: id, deps: deps)));
  }
}
