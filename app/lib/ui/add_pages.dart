// #329 PR 3 §2.7 (design §5.3): after a node was added — 3.2 (its name on this phone), then 3.5 / 3.6 (what next:
// make a network, join one, add another). The choice follows NetIndex as home row 6 does (PR 2 joinChoice): no
// network record -> 建立網路; any -> 加入網路; not computed yet -> the neutral 加入網路 (D-m9).
import 'package:flutter/material.dart';

import '../nodes.dart' show NodesPage;
import '../src/nodelink/app_link.dart';
import '../src/nodelink/raw_use.dart' show openRawPage;
import 'home_logic.dart';
import 'net_pages.dart' show NetFormPage;
import 'theme.dart';
import 'ui_state.dart';
import 'widgets.dart';

/// What 3.5 / 3.6 hands back to the home page: add another node now.
const addAgain = 'again';

/// Board 3.2: the node's name on this phone (UiState.setNick).
class NickPage extends StatefulWidget {
  const NickPage({super.key, required this.app, required this.ui, required this.id, this.devTrust = false});
  final AppLink app;
  final UiState ui;
  final String id;
  final bool devTrust;

  @override
  State<NickPage> createState() => _NickPageState();
}

class _NickPageState extends State<NickPage> {
  late final _name = TextEditingController(text: widget.ui.nodes[widget.id]?.nick ?? '節點 ${last4(widget.id)}');
  String? _err;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final err = await widget.ui.setNick(widget.id, _name.text);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _err = err;
        _saving = false;
      });
      return;
    }
    final r = await Navigator.of(context).pushReplacement<String, String>(MaterialPageRoute(
        builder: (_) => AddedPage(app: widget.app, ui: widget.ui, id: widget.id, devTrust: widget.devTrust)));
    if (r != null && mounted) Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return BatPage(
      title: '幫節點取名',
      body: [
        StatusHero(look: Look.ok, text: '已加入這支手機：後四碼 ${last4(widget.id)}'),
        TextField(
          controller: _name,
          maxLength: nickMax,
          decoration: InputDecoration(border: const OutlineInputBorder(), errorText: _err),
        ),
        Text('這個名字只有這支手機看得到。對別人說是哪一台時，請報後四碼。', style: TextStyle(fontSize: Fs.body, height: 1.6, color: t.sub)),
      ],
      foot: [BatButton(Btn.save, onPressed: _saving ? null : _save)],
    );
  }
}

/// Boards 3.5 / 3.6: what next. 3.5 = the phone's only node (the secondary is the member's join); 3.6 = another one
/// (the secondary is 再加一台).
class AddedPage extends StatefulWidget {
  const AddedPage({super.key, required this.app, required this.ui, required this.id, this.devTrust = false});
  final AppLink app;
  final UiState ui;
  final String id;
  final bool devTrust;

  @override
  State<AddedPage> createState() => _AddedPageState();
}

class _AddedPageState extends State<AddedPage> {
  AppLink get a => widget.app;

  @override
  void initState() {
    super.initState();
    a.nets.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    a.nets.removeListener(_changed);
    super.dispose();
  }

  Future<void> _form(bool makes) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => NetFormPage(app: a, ui: widget.ui, makes: makes, ticked: {widget.id}, devTrust: widget.devTrust)));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _memberJoin() async {
    // the member's join is the older console's until PR 5 (D3)
    final busy = await openRawPage(Navigator.of(context), a.link, a.gate, '我的節點', (u) => NodesPage(ble: a.ble, use: u));
    if (busy != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('另一個操作還在進行：$busy')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final recs = a.nets.now.records;
    final make = recs == NetRecords.none; // design §5.3: no network record at all -> 建立網路
    final only = a.link.core.states.length <= 1;
    final name = widget.ui.nodes[widget.id]?.nick ?? '節點 ${last4(widget.id)}';
    return BatPage(
      title: Btn.addNode,
      body: [
        StatusHero(
          look: Look.ok,
          text: '$name 已加入這支手機',
          next: make ? '下一步：建立隊伍網路，讓節點彼此連上。' : '下一步：把它加入隊伍網路。',
        ),
      ],
      foot: [
        BatButton(make ? Btn.makeNetwork : Btn.joinNetwork, onPressed: () => _form(make)),
        if (make && only)
          BatButton(Btn.memberJoin, kind: BtnKind.text, onPressed: _memberJoin)
        else
          BatButton(Btn.addAnother, kind: BtnKind.text, onPressed: () => Navigator.of(context).pop(addAgain)),
        BatButton(Btn.done, kind: BtnKind.text, onPressed: () => Navigator.of(context).pop()),
      ],
    );
  }
}
