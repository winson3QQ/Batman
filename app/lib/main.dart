// #254 app S1 — first slice: the startup flavor cross-check (design v8.5.1 §4.1) and an on-device self-test of the Rust
// core. No BLE, no keys generated yet.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'claim.dart';
import 'nodes.dart';
import 'scan.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

const _platform = MethodChannel('dev.batman/platform');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const BatmanApp());
}

class BatmanApp extends StatelessWidget {
  const BatmanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Batman',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const StartupCheck(),
    );
  }
}

class StartupCheck extends StatefulWidget {
  const StartupCheck({super.key});

  @override
  State<StartupCheck> createState() => _StartupCheckState();
}

class _StartupCheckState extends State<StartupCheck> {
  String? _report;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final info = buildInfo();
    final flavorDevTrust = await _platform.invokeMethod<bool>('devTrust');
    // design v8.5.1 §4.1: the Rust library and the flavor must agree, else the app is disabled
    final agree = flavorDevTrust == info.devTrust;
    final lines = <String>[
      'rust dev_trust=${info.devTrust} (batman_bridge ${info.crateVersion})',
      'flavor DEV_TRUST=$flavorDevTrust',
      agree ? 'flavor check: OK' : 'flavor check: MISMATCH — app disabled',
    ];
    if (agree) {
      lines.add('selftest: ${selftest()}');
      lines.addAll(await _install());
      try {
        final levels = await _platform.invokeMapMethod<String, dynamic>('keyLevels');
        lines.add('live: $levels');
        if (levels?['softOwnerEnc'] == true) {
          lines.add('NOTE: recovery / member key is software-protected on this phone — development use only');
        }
      } on PlatformException catch (e) {
        lines.add('keys: error ${e.code} ${e.message}');
      }
    }
    debugPrint('BMAPP ${lines.join(' | ')}');
    setState(() {
      _ok = agree;
      _report = lines.join('\n');
    });
  }

  /// Design v8.5.1 §4.1: the install marker; the four keys are generated only when there is no marker AND no record.
  Future<List<String>> _install() async {
    final out = <String>[];
    final dir = (await _platform.invokeMethod<String>('filesDir'))!;
    final swept = await storeSweep(dir: '$dir/records');
    if (swept > 0) out.add('store: removed $swept interrupted write(s)');
    final marker = await storeReadMarker(dir: '$dir/records');
    if (marker != null) {
      out.add('install marker: $marker');
      return out;
    }
    if (await storeHasRecords(dir: '$dir/records')) {
      // marker lost but records exist: never delete or regenerate keys
      out.add('install marker missing but records exist — keys are kept as they are');
      return out;
    }
    try {
      final levels = await _platform.invokeMapMethod<String, dynamic>('firstRun');
      final content = levels!.entries.map((e) => '${e.key}=${e.value}').join(' ');
      await storeWriteMarker(dir: '$dir/records', content: content);
      out.add('first run: four keys generated and self-tested; marker written: $content');
    } on PlatformException catch (e) {
      out.add('first run FAILED (all keys deleted, retried at the next start): ${e.message}');
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Batman — startup check')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _report == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
                SelectableText(_report!,
                    style: TextStyle(fontFamily: 'monospace', color: _ok ? null : Colors.red)),
                const SizedBox(height: 16),
                // only an app that passed the startup check talks to nodes
                if (_ok)
                  FilledButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ScanPage())),
                      child: const Text('Nodes nearby (BLE probe)')),
                if (_ok)
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ClaimPage())),
                      child: const Text('Claim a node (dev)')),
                if (_ok)
                  OutlinedButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NodesPage())),
                      child: const Text('My nodes')),
              ]),
      ),
    );
  }
}
