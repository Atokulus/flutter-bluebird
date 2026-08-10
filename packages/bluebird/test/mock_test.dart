import 'package:bluebird/bluebird.dart';
import 'package:bluebird/mock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';

/// The opt-in `package:bluebird/mock.dart` wrapper must forward to the static
/// [Bluebird] API. This also fails to compile if the wrapped API drifts.
void main() {
  late FakePlatform fake;
  final bluebird = BluebirdMockable();

  setUp(() {
    fake = FakePlatform();
    FakePlatform.install(fake);
  });

  test('forwards simple getters/methods to Bluebird', () async {
    expect(await bluebird.isSupported, isTrue);
    expect(await bluebird.adapterName, 'FakeAdapter');

    await bluebird.setPlatformLogLevel(LogLevel.warning);
    expect(bluebird.platformLogLevel, LogLevel.warning);
    expect(fake.calls, contains('setLogLevel'));
  });

  test('scan forwards and is observable via isScanning', () async {
    expect(bluebird.isScanning.value, isFalse);
    final sub = bluebird.performScan().listen((_) {});
    await pumpEventQueue();
    expect(bluebird.isScanning.value, isTrue);
    await sub.cancel();
  });

  test('forwards the cross-platform calls', () async {
    expect(bluebird.adapterState, isA<AsyncValueStream<BluetoothAdapterState>>());
    expect(bluebird.events, isA<Stream<BluebirdEvent>>());
    expect(bluebird.connectedDevices, isA<List<BluetoothDevice>>());
    expect(bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF'), isA<BluetoothDevice>());
    expect(await bluebird.systemDevices(const []), isA<List<BluetoothDevice>>());
    await bluebird.turnOn();
    expect(fake.calls, contains('turnOn'));
  });

  test('forwards the android-only calls', () async {
    final realSystem = System.current;
    System.current = System.android;
    addTearDown(() => System.current = realSystem);
    expect(await bluebird.bondedDevices, isA<List<BluetoothDevice>>());
    expect(await bluebird.getPhySupport(), isA<PhySupport>());
  });

  test('forwards the darwin-only calls', () async {
    final realSystem = System.current;
    System.current = System.macos;
    addTearDown(() => System.current = realSystem);
    await bluebird.setOptions(showPowerAlert: false);
    expect(fake.calls, contains('setOptions'));
  });
}
