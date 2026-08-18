@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

/// Exercises the Android-only operations by pretending the host is Android
/// (`System.current` is a mutable static). Restored in tearDown.
void main() {
  late FakePlatform fake;
  late BluetoothDevice device;
  final realSystem = System.current;

  setUp(() async {
    System.current = System.android;
    fake = FakePlatform()
      ..services = [
        bmService('a000', characteristics: [bmChar('b001')]),
      ];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
    device.applyEvent(OnConnectionStateChangedEvent(device, BluetoothConnectionState.connected, null));
  });

  tearDown(() => System.current = realSystem);

  test('requestMtu returns the negotiated value', () async {
    expect(await device.requestMtu(247, predelay: Duration.zero), 247);
    expect(fake.calls, contains('requestMtu'));
  });

  test('requestConnectionPriority and setPreferredPhy delegate', () async {
    await device.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
    await device.setPreferredPhy(txPhy: {Phy.le2m}, rxPhy: {Phy.le2m}, option: PhyCoding.noPreferred);
    expect(fake.calls, containsAll(['requestConnectionPriority', 'setPreferredPhy']));
  });

  test('setPreferredPhy waits for an in-flight GATT operation', () async {
    Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);
    final readRelease = Completer<Uint8List>();
    fake.stubs['readCharacteristic'] = () => readRelease.future;

    final characteristic = (await device.discoverServices(
      subscribeToServicesChanged: false,
    )).single.characteristics.single;
    final read = characteristic.read();
    await pumpEventQueue();

    final phy = device.setPreferredPhy(txPhy: {Phy.le2m}, rxPhy: {Phy.le2m}, option: PhyCoding.noPreferred);
    await pumpEventQueue();
    expect(fake.calls.where((call) => call == 'setPreferredPhy'), isEmpty);

    readRelease.complete(Uint8List(0));
    await Future.wait([read, phy]);
    expect(fake.calls.where((call) => call == 'setPreferredPhy'), hasLength(1));
  });

  test('clearGattCache delegates', () async {
    await device.clearGattCache();
    expect(fake.calls, contains('clearGattCache'));
  });

  group('bonding', () {
    test('createBond succeeds when the device reaches bonded', () async {
      fake.bondState = BluetoothBondState.bonded;
      await device.createBond();
      expect(fake.calls, contains('createBond'));
    });

    test('createBond throws when bonding does not complete', () async {
      fake.bondState = BluetoothBondState.none;
      expect(
        () => device.createBond(),
        throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.bondFailed)),
      );
    });

    test('removeBond throws when the bond is not removed', () async {
      fake.bondState = BluetoothBondState.bonded;
      expect(
        () => device.removeBond(),
        throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.removeBondFailed)),
      );
    });

    test('bondState.value reports the platform state', () async {
      fake.bondState = BluetoothBondState.bonded;
      expect(await device.bondState.value, BluetoothBondState.bonded);
    });
  });

  test('getPhySupport returns platform capabilities', () async {
    final phy = await Bluebird.getPhySupport();
    expect(phy.le2M, isTrue);
    expect(phy.leCoded, isFalse);
  });

  test('bondedDevices maps platform devices', () async {
    fake.bondedDevices = [BmBluetoothDevice(address: 'CC', platformName: 'Paired')];
    final devices = await Bluebird.bondedDevices;
    expect(devices.single.remoteId, 'CC');
  });
}
