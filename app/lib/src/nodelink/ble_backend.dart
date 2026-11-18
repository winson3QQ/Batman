// #329 §4.2: the real radio behind BleGate. The only place in the new code that touches flutter_reactive_ble;
// one FlutterReactiveBle for the whole app.
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'ble_gate.dart';

final provdService = Uuid.parse('540aa38c-0086-4d58-a9c0-c7c9d1e1bd42');
final _ids = {
  Char.rx: Uuid.parse('540aa38c-0086-4d59-a9c0-c7c9d1e1bd42'),
  Char.tx: Uuid.parse('540aa38c-0086-4d5a-a9c0-c7c9d1e1bd42'),
  Char.ctrl: Uuid.parse('540aa38c-0086-4d5b-a9c0-c7c9d1e1bd42'),
};

class ReactiveBackend implements BleBackend {
  ReactiveBackend(this.ble);
  final FlutterReactiveBle ble;

  QualifiedCharacteristic _q(String address, Char c) =>
      QualifiedCharacteristic(characteristicId: _ids[c]!, serviceId: provdService, deviceId: address);

  @override
  Stream<String> scan() =>
      ble.scanForDevices(withServices: [provdService], scanMode: ScanMode.lowLatency).map((d) => d.id);

  @override
  Stream<bool> connect(String address, Duration timeout) => ble
      .connectToDevice(id: address, connectionTimeout: timeout)
      .where((u) =>
          u.connectionState == DeviceConnectionState.connected ||
          u.connectionState == DeviceConnectionState.disconnected)
      .map((u) => u.connectionState == DeviceConnectionState.connected);

  @override
  Stream<(String, bool, int?)> get linkStates => ble.connectedDeviceStream
      .where((u) =>
          u.connectionState == DeviceConnectionState.connected ||
          u.connectionState == DeviceConnectionState.disconnected)
      .map((u) {
        final up = u.connectionState == DeviceConnectionState.connected;
        return (u.deviceId, up, up ? null : failureCode(u.failure?.message));
      });

  @override
  Future<int> requestMtu(String address, int mtu) => ble.requestMtu(deviceId: address, mtu: mtu);

  @override
  Future<List<int>> read(String address, Char c) => ble.readCharacteristic(_q(address, c));

  @override
  Stream<List<int>> subscribe(String address, Char c) => ble.subscribeToCharacteristic(_q(address, c));

  @override
  Future<void> write(String address, Char c, List<int> value) =>
      ble.writeCharacteristicWithoutResponse(_q(address, c), value: value);
}

/// #329 re-test (design 329-ble-settle.md §2.2): the status number in the plugin's connect-failure message
/// (RxAndroidBle: "... with status 133 (GATT_ERROR)"), -1 when the message has none. Only the number is kept: the
/// message names the full address and is never logged.
int? failureCode(String? message) {
  if (message == null) return null;
  final m = RegExp(r'with status (\d{1,3})\b').firstMatch(message);
  return m == null ? -1 : int.parse(m.group(1)!);
}
