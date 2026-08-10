import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

final class BluebirdAndroid extends BluebirdPlatform {
  final _api = BluebirdHostApi();

  Future<void>? _restartFuture;

  late final Stream<BmEvent> _events = nativeEvents().asBroadcastStream();

  @override
  Stream<BmEvent> get events => _events;

  static void registerWith() {
    BluebirdPlatform.instance = BluebirdAndroid();
  }

  @override
  Future<void> clearGattCache(String address) => _call('clearGattCache', () => _api.clearGattCache(address));

  @override
  Future<void> connect(String address) => _call('connect', () => _api.connect(address));

  @override
  Future<bool> createBond(String address, Uint8List? pin) => _call('createBond', () => _api.createBond(address, pin));

  @override
  Future<void> disconnect(String address) => _call('disconnect', () => _api.disconnect(address));

  @override
  Future<List<BmBluetoothService>> discoverServices(String address) =>
      _call('discoverServices', () => _api.discoverServices(address));

  @override
  Future<String> getAdapterName() => _call('getAdapterName', () => _api.getAdapterName());

  @override
  Future<BluetoothAdapterState> getAdapterState() => _call('getAdapterState', () => _api.getAdapterState());

  @override
  Future<BluetoothBondState> getBondState(String address) => _call('getBondState', () => _api.getBondState(address));

  @override
  Future<List<BmBluetoothDevice>> getBondedDevices() => _call('getBondedDevices', () => _api.getBondedDevices());

  @override
  Future<BmPhySupport> getPhySupport() => _call('getPhySupport', () => _api.getPhySupport());

  @override
  Future<List<BmBluetoothDevice>> getSystemDevices(List<String> withServices) =>
      _call('getSystemDevices', () => _api.getSystemDevices(withServices));

  @override
  Future<bool> isSupported() => _call('isSupported', () => _api.isSupported());

  @override
  Future<Uint8List> readCharacteristic(String address, BmCharacteristicRef characteristic) =>
      _call('readCharacteristic', () => _api.readCharacteristic(address, characteristic));

  @override
  Future<Uint8List> readDescriptor(String address, BmDescriptorRef descriptor) =>
      _call('readDescriptor', () => _api.readDescriptor(address, descriptor));

  @override
  Future<int> readRssi(String address) => _call('readRssi', () => _api.readRssi(address));

  @override
  Future<bool> removeBond(String address) => _call('removeBond', () => _api.removeBond(address));

  @override
  Future<void> requestConnectionPriority(String address, ConnectionPriority connectionPriority) =>
      _call('requestConnectionPriority', () => _api.requestConnectionPriority(address, connectionPriority));

  @override
  Future<int> requestMtu(String address, int mtu) => _call('requestMtu', () => _api.requestMtu(address, mtu));

  @override
  Future<void> setLogLevel(LogLevel level) => _api.setLogLevel(level);

  @override
  Future<bool> setNotifyValue(String address, BmCharacteristicRef characteristic, bool enable) =>
      _call('setNotifyValue', () => _api.setNotifyValue(address, characteristic, enable));

  @override
  Future<void> setOptions(bool showPowerAlert, bool restoreState) =>
      _call('setOptions', () => _api.setOptions(showPowerAlert, restoreState));

  @override
  Future<void> setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions) =>
      _call('setPreferredPhy', () => _api.setPreferredPhy(address, txPhy, rxPhy, phyOptions));

  @override
  Future<void> startScan(BmScanSettings settings) => _call('startScan', () => _api.startScan(settings));

  @override
  Future<void> stopScan() => _call('stopScan', () => _api.stopScan());

  @override
  Future<bool> turnOff() => _call('turnOff', () => _api.turnOff());

  @override
  Future<bool> turnOn() => _call('turnOn', () => _api.turnOn());

  @override
  Future<void> writeCharacteristic(
    String address,
    BmCharacteristicRef characteristic,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  ) => _call(
    'writeCharacteristic',
    () => _api.writeCharacteristic(address, characteristic, writeType, allowLongWrite, value),
  );

  @override
  Future<void> writeDescriptor(String address, BmDescriptorRef descriptor, Uint8List value) =>
      _call('writeDescriptor', () => _api.writeDescriptor(address, descriptor, value));

  @override
  Future<int> openL2capChannel(String address, int psm, bool secure) =>
      _call('openL2capChannel', () => _api.openL2capChannel(address, psm, secure));

  @override
  Future<void> closeL2capChannel(int channelId) => _call('closeL2capChannel', () => _api.closeL2capChannel(channelId));

  Future<T> _call<T>(String method, Future<T> Function() fn) async {
    await (_restartFuture ??= _flutterRestart());
    // Trace the round-trip at FINEST; the closures are built only if the logger
    // is actually emitting that level, so this is free when traces are off.
    BluebirdPlatform.logger.finest(() => '<$method>');
    final result = await fn();
    BluebirdPlatform.logger.finest(() => '($method) result: $result');
    return result;
  }

  /// Hot-restart handshake: the native side may still hold connections from a
  /// previous isolate; ask it to close everything and wait until it has.
  Future<void> _flutterRestart() async {
    if (await _api.flutterRestart() != 0) {
      await Future.delayed(const Duration(milliseconds: 50));
      while (await _api.connectedCount() != 0) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
  }
}
