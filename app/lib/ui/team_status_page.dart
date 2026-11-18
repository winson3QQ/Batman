// #329 PR 6 D5(f) (design §5.6, boards 6.1–6.3): the whole-team page. One section per own node whose last accepted
// read carried a visible team view (NodeLink.teams, written only by NodeLink._run); never merged across nodes, so a
// compromised node can only change its own section (E-M2). Layout = 254-app-team-status v2.4 §6 (frozen): Rust's
// title, `only` above the cards, the cards as Rust wrote them, the small print, `tech` only under 技術資訊.
// T-A9: nothing of a team section is ever logged (core.log, logcat, the text log): this page prints nothing.
import 'dart:async';

import 'package:flutter/material.dart';

import '../say.dart' show SayLine;
import '../src/nodelink/app_link.dart';
import '../src/nodelink/core.dart' as nl;
import '../src/nodelink/node_link.dart' show TeamRead;
import 'home_logic.dart' show hhmm, hhmmss, last4;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// 「看全隊狀態」 on the home page: shown when any own node's team section is visible (no netId needed, H-M2).
bool anyTeamVisible(AppLink a) =>
    a.link.teams.entries.any((e) => a.link.core.states.containsKey(e.key) && e.value.view.visible);

/// D5(c): a section is fresh only when its node is fresh AND the team came from that very read (a later read whose
/// team step ran over its 2 s or was cancelled leaves an older team behind: then it is old data, never green).
bool teamFresh(AppLink a, String id, TeamRead tr) {
  final c = a.link.core;
  final s = c.states[id];
  return s != null && c.fresh(id, a.link.now()) && tr.readAt == s.readAt;
}

const teamUnavailable = '全隊狀態目前不可用';

/// The status lights Rust puts in front of a card (teamview.rs); an old section shows unk instead of them.
const _lights = ['🟢', '⚪', '❔', '🟡', '🔴'];
String _noLight(String card) {
  for (final l in _lights) {
    if (card.startsWith(l)) return card.substring(l.length).trimLeft();
  }
  return card;
}

class TeamPage extends StatefulWidget {
  const TeamPage({super.key, required this.app, required this.ui});
  final AppLink app;
  final UiState ui;

  @override
  State<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends State<TeamPage> {
  StreamSubscription<void>? _sub;
  Timer? _tick;
  final Set<String> _tech = {};

  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    // D5(d): read like the home page (home <-> team changes nothing in the scheduler)
    a.link.setPage(nl.Page.team);
    _sub = a.link.changed.listen((_) => mounted ? setState(() {}) : null);
    // freshness runs out with time, not only with events
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  String _nodeName(String id) => widget.ui.nodes[id]?.nick ?? '節點 ${last4(id)}';

  Widget _section(BatTheme t, String id, TeamRead tr) {
    final v = tr.view;
    final fresh = teamFresh(a, id, tr);
    final ink = fresh ? t.ink : Look.unk.ink(t);
    final small = TextStyle(fontSize: Fs.meta, height: 1.5, color: fresh ? t.sub : ink);
    final open = _tech.contains(id);
    return Container(
      key: Key('teamSection-$id'),
      decoration: BoxDecoration(
        color: fresh ? t.surf : Look.unk.bg(t),
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            v.title,
            key: const Key('teamTitle'),
            style: TextStyle(fontSize: Fs.body, fontWeight: FontWeight.w700, color: ink),
          ),
          if (fresh)
            Text('讀取於 ${hhmmss(tr.readWall)}', key: const Key('teamFresh'), style: small)
          else
            Text('上次讀取 ${hhmm(tr.readWall)}', key: const Key('teamOld'), style: small),
          const SizedBox(height: 6),
          // review pr6 B-4: Rust's `only` and cards are split like every sentence (a technical part never shows raw)
          if (v.only.isNotEmpty) SayLine(v.only, key: const Key('teamOnly'), style: TextStyle(fontSize: Fs.body, color: ink)),
          for (final (i, c) in v.cards.indexed)
            KeyedSubtree(
              key: ValueKey('teamCard-$i'),
              child: Padding(
                key: const Key('teamCard'),
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!fresh) ...[
                      Icon(Look.unk.icon, key: const Key('teamCardUnk'), size: 18, color: ink),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SayLine(
                            fresh ? c.split('\n').first : _noLight(c.split('\n').first),
                            style: TextStyle(fontSize: Fs.body, height: 1.4, color: ink),
                          ),
                          for (final l in c.split('\n').skip(1)) SayLine(l, style: small),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (v.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SayLine(v.note, key: const Key('teamNote'), style: small),
            ),
          if (v.tech.isNotEmpty) ...[
            TextButton(
              key: Key('teamTechToggle-$id'),
              onPressed: () => setState(() => open ? _tech.remove(id) : _tech.add(id)),
              style: TextButton.styleFrom(
                foregroundColor: ink,
                padding: EdgeInsets.zero,
                minimumSize: const Size(48, 48),
              ),
              child: const Text('技術資訊（給維修人員看）'),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SelectableText(
                  v.tech.join('\n'),
                  key: const Key('teamTech'),
                  style: TextStyle(fontFamily: 'monospace', fontSize: Fs.meta, height: 1.5, color: ink),
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final c = a.link.core;
    final ids =
        [
          for (final e in a.link.teams.entries)
            if (c.states.containsKey(e.key) && e.value.view.visible) e.key,
        ]..sort((x, y) {
          final n = _nodeName(x).compareTo(_nodeName(y));
          return n != 0 ? n : x.compareTo(y);
        });
    return BatPage(
      title: '全隊狀態',
      body: [
        if (ids.isEmpty)
          StatusHero(look: Look.unk, text: teamUnavailable, onRefresh: a.link.refresh)
        else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                key: const Key('teamRefresh'),
                onPressed: a.link.refresh,
                style: TextButton.styleFrom(foregroundColor: t.ink, minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text(Btn.refresh, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          for (final id in ids) _section(t, id, a.link.teams[id]!),
        ],
      ],
    );
  }
}
