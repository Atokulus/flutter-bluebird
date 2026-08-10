import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

void main() {
  late FakePlatform fake;
  late BluetoothDevice device;

  setUp(() async {
    fake = FakePlatform()
      ..services = [
        bmService(
          'a000',
          characteristics: [
            bmChar(
              'b001',
              properties: props(read: true, write: true, writeWithoutResponse: true, notify: true),
              descriptors: ['2901'],
            ),
          ],
        ),
      ];
    FakePlatform.install(fake);
    device = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:FF');
  });

  BluetoothCharacteristic chr() => device.services.single.characteristics.single;

  Future<void> connectAndDiscover() async {
    await device.connect();
    await device.discoverServices(subscribeToServicesChanged: false);
  }

  test('connect marks the device connected and delegates to the platform', () async {
    expect(device.isConnected, isFalse);
    await device.connect();
    expect(fake.calls, contains('connect'));
    expect(device.isConnected, isTrue);
  });

  test('disconnect delegates to the platform', () async {
    await device.connect();
    await device.disconnect();
    expect(fake.calls, contains('disconnect'));
  });

  test('operations on a disconnected device throw deviceDisconnected', () async {
    expect(
      () => device.discoverServices(),
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.deviceDisconnected)),
    );
  });

  test('an operation fails fast if the adapter leaves the on state mid-flight', () async {
    await connectAndDiscover();
    // hold the read in-flight at the platform, so only the adapter guard can
    // end it (gate is released at the end to free the platform mutex)
    final gate = Completer<Uint8List>();
    fake.stubs['readCharacteristic'] = () => gate.future;
    final read = chr().read();
    await pumpEventQueue(); // let the guard attach and consume the current 'on'

    // a non-off terminal state (permission revoked) must still trip the guard,
    // not just off/turningOff
    fake.emit(BmAdapterStateEvent(adapterState: BluetoothAdapterState.unauthorized));

    await expectLater(
      read,
      throwsA(isA<BluebirdException>().having((e) => e.code, 'code', BluebirdErrorCode.adapterOff)),
    );
    gate.complete(Uint8List(0));
  });

  test('characteristic read reaches values but not notifications', () async {
    await connectAndDiscover();
    final c = chr();

    final onValues = expectLater(c.valuesPassive, emits([0xab])); // reads show up in values
    var onNotify = false;
    final notifySub = c.notificationsPassive.listen((_) => onNotify = true); // but not notifications

    final value = await c.read();
    expect(value, [0xab]);
    expect(fake.lastCharRef?.characteristic.uuid, Uuid('b001').string);

    await onValues;
    await pumpEventQueue();
    expect(onNotify, isFalse);
    await notifySub.cancel();
  });

  test('write passes the correct write type', () async {
    await connectAndDiscover();

    await chr().write([1, 2, 3]);
    expect(fake.lastWriteType, BmWriteType.withResponse);
    expect(fake.lastWriteValue, [1, 2, 3]);

    await chr().write([4], withoutResponse: true);
    expect(fake.lastWriteType, BmWriteType.withoutResponse);
  });

  test('write rejects a long write without response', () async {
    await connectAndDiscover();
    expect(() => chr().write([1], withoutResponse: true, allowLongWrite: true), throwsArgumentError);
  });

  test('subscribe delegates the notify enable to the platform', () async {
    await connectAndDiscover();
    await chr().subscribe();
    expect(fake.calls, contains('setNotifyValue'));
  });

  test('descriptor read/write delegate to the platform', () async {
    await connectAndDiscover();
    final d = chr().descriptors.single;
    expect(await d.read(), [0xcd]);
    await d.write([7]);
    expect(fake.lastWriteValue, [7]);
    expect(fake.calls, containsAll(['readDescriptor', 'writeDescriptor']));
  });

  test('readRssi returns the platform value', () async {
    await connectAndDiscover();
    expect(await device.readRssi(), -42);
  });

  test('android-only operations throw on other platforms', () async {
    await device.connect();
    // host is not Android, so these are gated
    expect(() => device.requestMtu(512), throwsA(isA<BluebirdException>()));
    expect(() => device.createBond(), throwsA(isA<BluebirdException>()));
  });
}
