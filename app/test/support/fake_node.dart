// The shared fake node library (moved from nodes_update_send_test.dart when #329 PR 6 deleted the old console and its
// page tests): a fake Rust api, a fake owner session, a fake removal, and one provd node under the BLE plugin. Every
// fake answers its frame [n] with [n + 1]. Used by the console, flow and page tests.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
// ignore: depend_on_referenced_packages
import 'package:reactive_ble_platform_interface/reactive_ble_platform_interface.dart' show CharacteristicInstance;

import 'package:batman_app/src/rust/api/member.dart';
import 'package:batman_app/src/rust/api/owner.dart';
import 'package:batman_app/src/rust/api/rekey.dart';
import 'package:batman_app/src/rust/frb_generated.dart';

const deviceId = '0000000000000c4f2a';
const netId = 'abababababababababababababababababababababababababababababababab';
const files = '/data/user/0/app/files';

final service = Uuid.parse('540aa38c-0086-4d58-a9c0-c7c9d1e1bd42');
final chars = [for (final c in const ['9', 'a', 'b']) Uuid.parse('540aa38c-0086-4d5$c-a9c0-c7c9d1e1bd42')]; // RX, TX, ctrl

// frames of the fake protocol: the node answers every write [n] with [n + 1]
const fLogin = 1, fInfo = 10, fSend = 20, fStatus = 30, fLink = 40, fConfirm = 50;
OwnerStep step(OwnerKind kind, {int? frame, String detail = '', String rel = '', Uint8List? info, bool pollLink = false, bool sent = false}) => OwnerStep(
    kind: kind,
    frames: [if (frame != null) Uint8List.fromList([frame])],
    signInput: Uint8List(1),
    detail: detail,
    record: Uint8List(2),
    rel: rel,
    generation: BigInt.two,
    aad: Uint8List(1),
    expectedGen: BigInt.one,
    pollLink: pollLink,
    hex: '',
    sas: '',
    renewed: false,
    sent: sent,
    left: false,
    waitMs: BigInt.zero,
    sendUpdate: false,
    info: info ?? Uint8List(0),
    sw: false,
    note: '', // 254-app-team-status: OwnerStep.note (the duplicate-address line)
    loginEnd: 0, // #329 T8: not a login end
    loginCode: BigInt.zero);

class FakeSession implements OwnerSession {
  FakeSession(this.rust);
  final FakeRust rust;

  @override
  OwnerStep? onFrame({required List<int> frame}) => switch (frame[0]) {
        const (fLogin + 1) => step(OwnerKind.loggedIn, detail: 'in'),
        const (fInfo + 1) => step(OwnerKind.answer, detail: 'info', info: Uint8List.fromList([7])),
        const (fLink + 1) => step(OwnerKind.answer, detail: '[CONNECTED] 節點已連上隊伍網路'),
        const (fConfirm + 1) => step(OwnerKind.answer, detail: '[NET_OK] 網路已套用'),
        _ => step(OwnerKind.answer, detail: 'sent', pollLink: rust.pollAfterJoin),
      };

  // #329 PR 3 step 1: the console paths that had no test (join with ConfirmCountry / ConfirmRemoved, link check,
  // confirm network), pinned before they move into OwnerConsole
  @override
  OwnerStep requestJoinNetwork(
      {required List<int> recordPlain,
      required BigInt recordGen,
      required List<int> adminPub,
      required List<int> ownerEncPub,
      required bool removedConfirmed}) {
    rust.sends.add('join removed=$removedConfirmed');
    if (rust.joinMode == 'removed' && !removedConfirmed) {
      return step(OwnerKind.confirmRemoved, detail: '[JOIN_STATE] 這台節點之前被排除過');
    }
    if (rust.joinMode == 'country') return step(OwnerKind.confirmCountry, detail: '[COUNTRY] 節點的國家是 TW，要改成 US 嗎');
    return step(OwnerKind.write, frame: fSend);
  }

  @override
  OwnerStep? countryConfirmed({required bool yes}) {
    rust.sends.add('country $yes');
    return yes ? step(OwnerKind.write, frame: fSend) : step(OwnerKind.answer, detail: '[JOIN_STATE] 已取消');
  }

  @override
  OwnerStep requestLinkCheck({required BigInt secsSinceJoin}) {
    rust.sends.add('link');
    return step(OwnerKind.write, frame: fLink);
  }

  @override
  OwnerStep requestConfirmNetwork({required List<int> recordPlain, required BigInt recordGen}) {
    rust.sends.add('confirm');
    return step(OwnerKind.write, frame: fConfirm);
  }

  @override
  OwnerStep requestInfo() => step(OwnerKind.write, frame: fInfo);

  // the status page (v8.1 §2): one read, a node in `netId`, and the §3.5 hint with its button
  @override
  OwnerStep requestStatusPage() => step(OwnerKind.write, frame: fStatus);
  @override
  String last4() => '4f2a';
  @override
  StatusView statusView({required bool hasNet, required bool hasMnet}) => StatusView(
      color: 'green',
      row: 'r',
      sentence: 's',
      lagNote: '',
      warning: '',
      nodeState: 2,
      netId: netId,
      version: '',
      tech: const [],
      fresh: true,
      rateNote: '',
      unfinished: '',
      unfinishedUnderVerdict: false,
      canLeave: false);
  @override
  UpdateHint updateHint({required List<int> recordPlain, required bool member}) => const UpdateHint(line: 'hint', button: true);
  // 254-app-team-status §6: the status page also asks for the team section (hidden, as in version N)
  @override
  TeamView teamView({Uint8List? recordPlain, required bool member}) =>
      const TeamView(visible: false, title: '', only: '', cards: [], note: '', tech: []);

  // #329 PR 2 review B-M3: which join the one 「加入網路」 starts
  @override
  OwnerStep requestMemberJoin({required List<int> mnetPlain, required BigInt mnetGen}) {
    rust.sends.add('memberJoin');
    return step(OwnerKind.write, frame: fSend);
  }

  @override
  OwnerStep requestSendUpdate({required List<int> recordPlain, required bool member, required List<int> adminPub}) {
    rust.sends.add(member ? 'member' : 'admin');
    return step(OwnerKind.write, frame: fSend);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// the removal: SignAdmin -> PersistNet -> "[REKEY]"
class FakeRemoveOp implements RemoveOp {
  @override
  OwnerStep? signed({required List<int> der}) => step(OwnerKind.persistNet, rel: 'net/$netId');
  @override
  OwnerStep? netPersisted() => step(OwnerKind.answer, detail: '[REKEY] 已換密碼');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeRust implements RustLibApi {
  final calls = <String>[]; // record writes and the removal's start
  final sends = <String>[]; // request_send_update calls
  final records = <String>{}; // the records on "disk"
  String joinMode = 'plain'; // #329 PR 3 step 1: plain / country / removed
  bool pollAfterJoin = false; // the join answer asks for the link check
  OwnerStep? forgetStep; // #329 PR 3 step 3: netForgetJoining's answer (flows/owner_console_test)

  @override
  OwnerStep crateApiOwnerNetForgetJoining({required List<int> recordPlain, required BigInt recordGen, required String dacHash}) =>
      forgetStep ?? (throw '建立網路的節點不能忘記');

  @override
  Future<List<String>> crateApiOwnerListNodes({required String dir}) async => [deviceId];
  @override
  Future<List<String>> crateApiOwnerListNets({required String dir}) async => [
        for (final r in records)
          if (r.startsWith('net/')) r.substring(4)
      ];
  @override
  Future<SealedRecord?> crateApiOwnerStoreReadSealed({required String dir, required String rel}) async =>
      records.contains(rel) ? SealedRecord(generation: BigInt.one, sealed: Uint8List(3), aad: Uint8List(1)) : null;
  @override
  Future<BigInt> crateApiOwnerStoreWriteCas({required String dir, required String rel, required BigInt expectedGen, required List<int> sealed}) async {
    calls.add('cas $rel');
    records.add(rel);
    return BigInt.two;
  }

  @override
  Future<int> crateApiClaimFrameLimit({required List<int> ctrl, required int mtu}) async => 244;
  @override
  (OwnerSession, OwnerStep) crateApiOwnerOwnerSessionStart({required List<int> recordPlain, required List<int> ownerPub, required int frameLimit}) =>
      (FakeSession(this), step(OwnerKind.write, frame: fLogin));
  @override
  String crateApiRekeyInfoNetId({required List<int> info}) => info.isEmpty ? '' : netId;

  // T30: the member's import
  @override
  String crateApiRekeyUpdateNetId({required String hex}) => netId;
  @override
  UpdatePrep crateApiRekeyMemberUpdatePrepare(
          {required String hex, Uint8List? mnetPlain, required BigInt mnetGen, required List<Uint8List> nodeRecords, required List<int> ownerEncPub}) =>
      UpdatePrep(state: UpdateState.advance, ephPub: Uint8List(65), mnetGen: mnetGen, detail: '');
  @override
  OwnerStep crateApiRekeyMemberUpdateImport(
          {required String hex,
          Uint8List? mnetPlain,
          required BigInt mnetGen,
          required BigInt expectedGen,
          required List<Uint8List> nodeRecords,
          required List<int> ownerEncPub,
          required List<int> z}) =>
      step(OwnerKind.persistMnet, rel: 'mnet/$netId', detail: '已匯入');

  // the status page's reads of this phone's records
  @override
  Future<List<String>> crateApiMemberListMnets({required String dir}) async => [
        for (final r in records)
          if (r.startsWith('mnet/')) r.substring(5)
      ];
  @override
  Future<List<String>> crateApiMemberListPends({required String dir}) async => [
        for (final r in records)
          if (r.startsWith('mpend/')) r.substring(6)
      ];
  @override
  MnetView crateApiMemberMnetSummary({required List<int> mnetPlain}) =>
      const MnetView(netId: netId, netName: 'n', entryState: 'applied', deviceLast4: '4f2a');
  @override
  List<String> crateApiOwnerLeaveConfirmText({required String last4, required String netId, required bool adminApplied, required bool memberEntry}) =>
      const ['t', 'b'];
  @override
  String crateApiOwnerStatusMembershipLine({required int nodeState, required String netId, String? name}) => 'm';

  // T19: the admin's removal
  @override
  NetView crateApiOwnerNetSummary({required List<int> recordPlain}) =>
      const NetView(netId: netId, meshId: 'm', netName: 'n', applied: true, country: 'US', members: []);
  @override
  List<PersonView> crateApiRekeyNetPeople({required List<int> recordPlain, required List<int> ownerPub}) => const [
        PersonView(owner: 'b0b0', fpr: 'F', name: 'Bob', isSelf: false, nodes: [PersonNode(last4: '1234', dacHash: 'dd', state: 'applied')], sameName: [])
      ];
  @override
  List<OwnNodeView> crateApiRekeyRemoveOwnNodes({required List<int> recordPlain, required List<int> ownerPub, required String person, required String node}) =>
      const [OwnNodeView(deviceId: deviceId, dacHash: 'ee')];
  @override
  RemovePlanView crateApiRekeyRemoveCheck(
          {required List<int> recordPlain,
          required List<int> adminPub,
          required List<int> ownerPub,
          required String person,
          required String node,
          required List<NodeInfo> reads}) =>
      const RemovePlanView(ok: true, text: 'plan', unverified: false, nodes: 1);
  @override
  String crateApiRekeyRemoveTickText() => 'tick';
  @override
  (RemoveOp, OwnerStep) crateApiRekeyRemoveOpStartRemove(
      {required List<int> recordPlain,
      required BigInt recordGen,
      required List<int> adminPub,
      required List<int> ownerPub,
      required String person,
      required String node,
      required List<NodeInfo> reads,
      required bool ticked}) {
    calls.add('remove $person ticked=$ticked reads=${reads.map((r) => r.info.length).toList()}');
    return (FakeRemoveOp(), step(OwnerKind.signAdmin));
  }

  @override
  List<RecipientView> crateApiRekeyNetRecipients({required List<int> recordPlain, required List<int> ownerPub}) => const [];

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

/// One provd node under the BLE plugin: found by a scan, connects, and answers every frame written to RX with
/// [frame + 1] on TX. `written` = the first byte of every frame the app wrote.
class FakeNode extends ReactiveBlePlatform {
  final scans = StreamController<ScanResult>.broadcast(sync: true);
  final conns = StreamController<ConnectionStateUpdate>.broadcast(sync: true);
  final values = StreamController<CharacteristicValue>.broadcast(sync: true);
  final written = <int>[];
  CharacteristicInstance? tx;
  Completer<void>? holdConnect; // #329 r3 E2: the connection comes up only when this completes
  final disconnects = <String>[];

  @override
  Future<void> initialize() async {}
  @override
  Stream<BleStatus> get bleStatusStream => const Stream.empty();
  @override
  Stream<ScanResult> get scanStream => scans.stream;
  @override
  Stream<ConnectionStateUpdate> get connectionUpdateStream => conns.stream;
  @override
  Stream<CharacteristicValue> get charValueUpdateStream => values.stream;

  @override
  Stream<void> scanForDevices({required List<Uuid> withServices, required ScanMode scanMode, required bool requireLocationServicesEnabled}) {
    Timer(const Duration(milliseconds: 10), () {
      scans.add(ScanResult(
          result: Result.success(
              DiscoveredDevice(id: 'AA', name: '', serviceData: const {}, manufacturerData: Uint8List(0), rssi: -40, serviceUuids: const []))));
    });
    return Stream.value(null);
  }

  @override
  Stream<void> connectToDevice(String id, Map<Uuid, List<Uuid>>? servicesWithCharacteristicsToDiscover, Duration? connectionTimeout) {
    void up() => conns.add(ConnectionStateUpdate(deviceId: id, connectionState: DeviceConnectionState.connected, failure: null));
    final h = holdConnect;
    h == null ? Timer(const Duration(milliseconds: 10), up) : h.future.then((_) => up());
    return Stream.value(null);
  }

  @override
  Future<void> disconnectDevice(String deviceId) async => disconnects.add(deviceId);
  @override
  Future<int> requestMtuSize(String deviceId, int? mtu) async => 517;
  @override
  Future<List<DiscoveredService>> getDiscoverServices(String deviceId) async => [
        DiscoveredService(serviceId: service, serviceInstanceId: 's', characteristicIds: chars, characteristics: [
          for (final c in chars)
            DiscoveredCharacteristic(
                characteristicId: c,
                characteristicInstanceId: '$c',
                serviceId: service,
                isReadable: true,
                isWritableWithResponse: true,
                isWritableWithoutResponse: true,
                isNotifiable: true,
                isIndicatable: false)
        ])
      ];
  @override
  Future<List<DiscoveredService>> discoverServices(String deviceId) => getDiscoverServices(deviceId);

  @override
  Stream<void> readCharacteristic(CharacteristicInstance characteristic) {
    Timer(const Duration(milliseconds: 10), () => values.add(CharacteristicValue(characteristic: characteristic, result: const Result.success([0]))));
    return Stream.value(null);
  }

  @override
  Stream<void> subscribeToNotifications(CharacteristicInstance characteristic) {
    tx = characteristic;
    return Stream.value(null);
  }

  @override
  Future<void> stopSubscribingToNotifications(CharacteristicInstance characteristic) async {}

  @override
  Future<WriteCharacteristicInfo> writeCharacteristicWithoutResponse(CharacteristicInstance characteristic, List<int> value) async {
    written.add(value[0]);
    Timer.run(() => values.add(CharacteristicValue(characteristic: tx!, result: Result.success([value[0] + 1]))));
    return WriteCharacteristicInfo(characteristic: characteristic, result: const Result.success(Unit()));
  }
}

