// #329 design §3.2: the only components the new screens may use. Sizes follow the canvas v5 (gen-lib.js).
import 'package:flutter/material.dart';

import 'theme.dart';

/// The five looks of a status (§3.2 StatusHero): each has its own icon shape, not only a colour.
enum Look { ok, warn, bad, unk, busy }

extension LookStyle on Look {
  Color bg(BatTheme t) => switch (this) {
        Look.ok => t.okBg,
        Look.warn => t.warnBg,
        Look.bad => t.badBg,
        Look.unk || Look.busy => t.unkBg,
      };
  Color ink(BatTheme t) => switch (this) {
        Look.ok => t.okInk,
        Look.warn => t.warnInk,
        Look.bad => t.badInk,
        Look.unk || Look.busy => t.unkInk,
      };
  IconData get icon => switch (this) {
        Look.ok => Icons.check_circle_outline,
        Look.warn => Icons.warning_amber_rounded,
        Look.bad => Icons.highlight_off,
        Look.unk => Icons.help_outline,
        Look.busy => Icons.autorenew,
      };
  String get word => switch (this) {
        Look.ok => '正常',
        Look.warn => '注意',
        Look.bad => '有問題',
        Look.unk => '未知',
        Look.busy => '進行中',
      };
}

/// Page layout: a 56 dp bar (the home page puts the badge on the left), scrolling content, an optional foot.
class BatPage extends StatelessWidget {
  const BatPage({super.key, required this.title, required this.body, this.foot, this.badge = false, this.actions});
  final String title;
  final List<Widget> body;
  final List<Widget>? foot;
  final bool badge;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        foregroundColor: t.ink,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 56,
        titleSpacing: badge ? 0 : null,
        leading: badge
            ? Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Semantics(
                    label: '台灣曙豐防災自訓團臂章',
                    child: Image.asset('assets/brand/badge.webp', width: 34, fit: BoxFit.contain)))
            : null,
        leadingWidth: badge ? 52 : null,
        title: Text(title, style: TextStyle(fontSize: Fs.title + 1, fontWeight: FontWeight.w700, color: t.ink)),
        actions: actions,
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: _gap(body, 14)),
          ),
          if (foot != null)
            Container(
              decoration: BoxDecoration(color: t.bg, border: Border(top: BorderSide(color: t.line))),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(mainAxisSize: MainAxisSize.min, children: _gap(foot!, 6)),
            ),
        ]),
      ),
    );
  }
}

List<Widget> _gap(List<Widget> ws, double g) => [
      for (var i = 0; i < ws.length; i++) ...[if (i > 0) SizedBox(height: g), ws[i]]
    ];

/// The status area: icon + word + one sentence + next step + read time + 重新整理.
class StatusHero extends StatelessWidget {
  const StatusHero({super.key, required this.look, required this.text, this.next, this.time, this.onRefresh, this.extra});
  final Look look;
  final String text;
  final String? next;
  final String? time;
  final VoidCallback? onRefresh;
  final List<Widget>? extra;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ink = look.ink(t);
    return Container(
      decoration: BoxDecoration(color: look.bg(t), borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _gap([
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(look.icon, size: 36, color: ink),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(look.word,
                  style: TextStyle(fontSize: Fs.meta, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: ink)),
              const SizedBox(height: 2),
              Text(text, style: TextStyle(fontSize: Fs.hero - 3, fontWeight: FontWeight.w700, height: 1.35, color: ink)),
            ]),
          ),
        ]),
        if (next != null) Text(next!, style: TextStyle(fontSize: Fs.body, height: 1.6, color: ink)),
        ...?extra,
        if (time != null || onRefresh != null)
          Row(children: [
            Expanded(child: Text(time ?? '', style: TextStyle(fontSize: Fs.meta, color: ink))),
            if (onRefresh != null)
              TextButton.icon(
                onPressed: onRefresh,
                style: TextButton.styleFrom(foregroundColor: ink, minimumSize: const Size(48, 48), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text(Btn.refresh, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
          ]),
      ], 10)),
    );
  }
}

/// One node in a list (home, team, pick): nickname, one sentence, 「讀取於 HH:MM　後四碼 XXXX」.
class NodeRow extends StatelessWidget {
  const NodeRow({super.key, required this.look, required this.name, required this.line, required this.meta, this.onTap});
  final Look look;
  final String name, line, meta;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 84),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: look.bg(t), borderRadius: BorderRadius.circular(12)),
              child: Icon(look.icon, size: 26, color: look.ink(t)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: TextStyle(fontSize: Fs.title, fontWeight: FontWeight.w700, color: t.ink)),
                const SizedBox(height: 2),
                Text(line,
                    style: TextStyle(
                        fontSize: 15,
                        height: 1.45,
                        color: look == Look.ok ? t.ink : look.ink(t),
                        fontWeight: look == Look.ok ? FontWeight.w400 : FontWeight.w700)),
                const SizedBox(height: 2),
                Text(meta, style: TextStyle(fontSize: Fs.meta, color: t.sub)),
              ]),
            ),
            if (onTap != null) Icon(Icons.chevron_right, size: 22, color: t.sub),
          ]),
        ),
      ),
    );
  }
}

/// A card: rows separated by lines.
class BatCard extends StatelessWidget {
  const BatCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: t.surf, border: Border.all(color: t.line), borderRadius: BorderRadius.circular(14)),
      child: Material(
        type: MaterialType.transparency,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: t.line),
            children[i],
          ]
        ]),
      ),
    );
  }
}

/// A row in a card: icon, title, optional second line, optional value on the right, a chevron when tappable.
class BatRow extends StatelessWidget {
  const BatRow(
      {super.key, required this.icon, required this.title, this.sub, this.right, this.onTap, this.danger = false, this.enabled = true});
  final IconData icon;
  final String title;
  final String? sub, right;
  final VoidCallback? onTap;
  final bool danger, enabled;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ink = !enabled ? t.sub : (danger ? t.danger : t.ink);
    return InkWell(
      onTap: enabled ? onTap : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Icon(icon, size: 24, color: danger ? t.danger : t.sub),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: Fs.body, fontWeight: FontWeight.w500, height: 1.4, color: ink)),
                if (sub != null) Text(sub!, style: TextStyle(fontSize: Fs.meta, height: 1.5, color: t.sub)),
              ]),
            ),
            if (right != null) Text(right!, style: TextStyle(fontSize: Fs.note, color: t.sub)),
            if (onTap != null && enabled) Icon(Icons.chevron_right, size: 20, color: t.sub),
          ]),
        ),
      ),
    );
  }
}

/// A coloured note with an optional action (todo items, warnings).
class BatBanner extends StatelessWidget {
  const BatBanner({super.key, required this.look, required this.title, this.text, this.action, this.onAction});
  final Look look;
  final String title;
  final String? text, action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final ink = look.ink(t);
    return Container(
      decoration: BoxDecoration(color: look.bg(t), borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(look.icon, size: 26, color: ink),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: Fs.body, fontWeight: FontWeight.w700, height: 1.4, color: ink)),
            if (text != null) ...[
              const SizedBox(height: 4),
              Text(text!, style: TextStyle(fontSize: Fs.note, height: 1.55, color: ink)),
            ],
            if (action != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(foregroundColor: ink, padding: EdgeInsets.zero, minimumSize: const Size(48, 48), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text(action!,
                    style: const TextStyle(
                        fontSize: Fs.body, fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// A small upper-case-like section label.
class BatLabel extends StatelessWidget {
  const BatLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
        child: Text(text,
            style: TextStyle(
                fontSize: Fs.meta, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: BatTheme.of(context).sub)),
      );
}

enum BtnKind { primary, secondary, text, danger }

/// Buttons: ≥ 48 dp (54 for the filled ones), text from the Btn table.
class BatButton extends StatelessWidget {
  const BatButton(this.text, {super.key, required this.onPressed, this.kind = BtnKind.primary, this.icon});
  final String text;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = BatTheme.of(context);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    final child = Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
      Flexible(
          child: Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: kind == BtnKind.text ? Fs.body : 17, fontWeight: FontWeight.w700))),
    ]);
    const tall = Size.fromHeight(54);
    return switch (kind) {
      BtnKind.primary => FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
              backgroundColor: t.acc, foregroundColor: t.accInk, minimumSize: tall, tapTargetSize: MaterialTapTargetSize.shrinkWrap, shape: shape,
              disabledBackgroundColor: t.line, disabledForegroundColor: t.sub),
          child: child),
      BtnKind.secondary => OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
              foregroundColor: t.accText, minimumSize: tall, tapTargetSize: MaterialTapTargetSize.shrinkWrap, shape: shape, side: BorderSide(color: t.acc, width: 2)),
          child: child),
      BtnKind.text => TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(foregroundColor: t.accText, minimumSize: const Size.fromHeight(48), tapTargetSize: MaterialTapTargetSize.shrinkWrap, shape: shape),
          child: child),
      BtnKind.danger => FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
              backgroundColor: t.danger, foregroundColor: t.dangerInk, minimumSize: tall, tapTargetSize: MaterialTapTargetSize.shrinkWrap, shape: shape),
          child: child),
    };
  }
}

/// §3.4 rule 4: every button text of the new screens comes from this one table (T-C4b scans it).
abstract final class Btn {
  static const refresh = '重新整理';
  static const addNode = '新增節點';
  static const makeNetwork = '建立網路';
  static const joinNetwork = '加入網路';
  static const checkNetwork = '檢查網路';
  static const seeNode = '看這台節點';
  static const allowBluetooth = '允許藍牙權限';
  static const openBluetooth = '開啟藍牙設定';
  static const tryAgain = '再試一次';
  static const gotIt = '知道了';
  static const remove = '移除';
  static const cancel = '取消';
  static const save = '儲存';
  static const more = '更多';
  static const devOptions = '開發者選項';
  static const about = '關於';
  // named by Rust / older-page sentences (S7: kept, the later PRs' screens carry them)
  static const leaveNetwork = '離開網路';
  static const requestJoin = '申請加入';
  static const showRequestAgain = '再顯示申請';
  static const sendNewKey = '把新密碼送給節點';
  static const excludeThis = '排除這台';
  static const goOn = '繼續';
  static const claim = '認領'; // the older claim page (PR 3 replaces it)
  static const seeRequest = '看我的申請';
  static const openAppSettings = '開啟 app 設定';
  static const next = '下一步';
  static const skipIntro = '跳過說明';
  static const start = '開始';
  static const finishIt = '繼續完成';
  static const joinTeam = '加入隊長的網路';
  // #329 PR 3: the network pages (4.1-4.5, 檢查網路)
  static const nextNode = '繼續下一台';
  static const stopHere = '先停在這裡';
  static const retryNode = '再試這一台';
  static const checkAgain = '再檢查一次';
  static const otherNode = '換一台檢查';
  static const forgetJoin = '放棄這次加入';
  static const done = '完成';
  static const oldConsole = '到舊控制台';
  // #329 PR 3 §2.7 (D1): the claim page keeps its words; 3.2 / 3.5 / 3.6
  static const scanQr = '掃描 QR';
  static const pasteQr = '貼上 QR 碼（開發用）';
  static const stopRecovery = '停止恢復';
  static const fromPending = '從認領暫存恢復';
  static const addAnother = '再加一台';
  static const memberJoin = '我是隊員，加入隊長的網路';
  // #329 PR 5 (plan v16 R4 / R5)
  static const copyText = '複製文字';
  static const clearClip = '清除剪貼簿';
  static const pasteText = '貼上文字';

  static const all = {
    refresh, addNode, makeNetwork, joinNetwork, checkNetwork, seeNode, allowBluetooth, openBluetooth, tryAgain, gotIt,
    remove, cancel, save, more, devOptions, about, leaveNetwork, requestJoin, showRequestAgain, sendNewKey,
    excludeThis, goOn, claim, seeRequest, joinTeam, openAppSettings, next, skipIntro, start, finishIt,
    nextNode, stopHere, retryNode, checkAgain, otherNode, forgetJoin, done, oldConsole,
    scanQr, pasteQr, stopRecovery, fromPending, addAnother, memberJoin,
    copyText, clearClip, pasteText,
  };
}
