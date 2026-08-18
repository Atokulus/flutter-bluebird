import 'dart:math';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

/// Verifies that Bluebird routes each platform [BmEvent] to the matching
/// public event stream / device state (the `_onPlatformEvent` dispatch).
void main() {
  late FakePlatform fake;

  setUp(() async {
    fake = FakePlatform();
    FakePlatform.install(fake);
    // any invoke() triggers Bluebird to subscribe to the platform event stream
    await Bluebird.isSupported;
  });

  Future<void> pump() => pumpEventQueue();

  test('connection state event reaches onConnectionStateChanged and updates the device', () async {
    final device = Bluebird.deviceForAddress('AA');
    final seen = expectLater(Bluebird.events.where((e) => e is OnConnectionStateChangedEvent), emits(anything));
    fake.emit(BmConnectionStateEvent(address: 'AA', connectionState: BluetoothConnectionState.connected));
    await pump();
    expect(device.isConnected, isTrue);
    await seen;
  });

  test('name changed event reaches onNameChanged', () async {
    final seen = expectLater(
      Bluebird.events.where((e) => e is OnNameChangedEvent),
      emits(isA<OnNameChangedEvent>().having((e) => e.name, 'name', 'Renamed')),
    );
    fake.emit(BmNameChangedEvent(address: 'AA', name: 'Renamed'));
    await seen;
  });

  test('mtu changed event reaches onMtuChanged', () async {
    final seen = expectLater(
      Bluebird.events.where((e) => e is OnMtuChangedEvent),
      emits(isA<OnMtuChangedEvent>().having((e) => e.mtu, 'mtu', 400)),
    );
    fake.emit(BmMtuChangedEvent(address: 'AA', mtu: 400));
    await seen;
  });

  test('device.mtu is a ValueStream: live value + re-emit then updates on listen', () async {
    final device = Bluebird.deviceForAddress('AA');

    // .value reads the current MTU synchronously (default before any event)
    expect(device.mtu.value, 23);
    expect(device.maxAttrLen.value, min(512, 23 - 3));

    // listening emits the current value first, then each change
    final seen = expectLater(device.mtu, emitsInOrder([23, 400]));
    fake.emit(BmMtuChangedEvent(address: 'AA', mtu: 400));
    await seen;

    // .value now tracks the latest, and the mapped ValueStream derives from it
    expect(device.mtu.value, 400);
    expect(device.maxAttrLen.value, min(512, 400 - 3));
  });

  test('device.mtu.changes emits deltas only (no initial re-emit)', () async {
    final device = Bluebird.deviceForAddress('AA');
    // .changes skips the current value and emits only subsequent changes
    final seen = expectLater(device.mtu.changes, emitsInOrder([400]));
    fake.emit(BmMtuChangedEvent(address: 'AA', mtu: 400));
    await seen;
  });

  test('device.connectionState is a ValueStream with a live value', () async {
    final device = Bluebird.deviceForAddress('AA');
    expect(device.connectionState.value, BluetoothConnectionState.disconnected);

    final seen = expectLater(
      device.connectionState,
      emitsInOrder([BluetoothConnectionState.disconnected, BluetoothConnectionState.connected]),
    );
    fake.emit(BmConnectionStateEvent(address: 'AA', connectionState: BluetoothConnectionState.connected));
    await seen;
    expect(device.connectionState.value, BluetoothConnectionState.connected);
  });

  test('bond state event carries the reported previous state', () async {
    final seen = expectLater(
      Bluebird.events.where((e) => e is OnBondStateChangedEvent),
      emits(
        isA<OnBondStateChangedEvent>()
            .having((e) => e.state, 'bondState', BluetoothBondState.bonded)
            .having((e) => e.prevState, 'prevState', BluetoothBondState.bonding),
      ),
    );
    fake.emit(
      BmBondStateEvent(address: 'AA', bondState: BluetoothBondState.bonded, prevState: BluetoothBondState.bonding),
    );
    await seen;
  });

  test('bond state falls back to the last known state when the wire omits prevState', () async {
    final device = Bluebird.deviceForAddress('AA');
    fake.emit(BmBondStateEvent(address: 'AA', bondState: BluetoothBondState.bonding));
    await pump();
    fake.emit(BmBondStateEvent(address: 'AA', bondState: BluetoothBondState.bonded));
    await pump();
    expect(device.prevBondState, BluetoothBondState.bonding);
    expect(device.currentBondState, BluetoothBondState.bonded);
  });

  test('services reset event reaches onServicesReset', () async {
    final seen = expectLater(Bluebird.events.where((e) => e is OnServicesResetEvent), emits(anything));
    fake.emit(BmServicesResetEvent(address: 'AA'));
    await seen;
  });

  group('characteristic notification', () {
    Future<BluetoothCharacteristic> discoverNotifyChar() async {
      fake.services = [
        bmService('a000', characteristics: [bmChar('b001', properties: props(notify: true))]),
      ];
      final device = Bluebird.deviceForAddress('AA');
      device.applyEvent(OnConnectionStateChangedEvent(device, BluetoothConnectionState.connected, null));
      await device.discoverServices(subscribeToServicesChanged: false);
      return device.services.single.characteristics.single;
    }

    BmCharacteristicRef refFor(String charUuid) => BmCharacteristicRef(
      service: Bluebird.deviceForAddress('AA').services.single.bm,
      characteristic: attr(charUuid),
    );

    void emitValue(String charUuid, List<int> value) => fake.emit(
      BmCharacteristicNotificationEvent(
        address: 'AA',
        characteristic: refFor(charUuid),
        value: Uint8List.fromList(value),
      ),
    );

    test('resolved notification reaches notificationsPassive and is broadcast', () async {
      final c = await discoverNotifyChar();

      final onChanges = expectLater(c.notificationsPassive, emits([1, 2, 3]));
      final broadcast = expectLater(
        Bluebird.events.where((e) => e is OnCharacteristicNotifiedEvent),
        emits(
          isA<OnCharacteristicNotifiedEvent>().having((e) => e.characteristic, 'characteristic', c).having(
            (e) => e.value,
            'value',
            [1, 2, 3],
          ),
        ),
      );

      emitValue('b001', [1, 2, 3]);

      await onChanges;
      await broadcast;
    });

    test('values includes notify/indicate values (via the base event)', () async {
      final c = await discoverNotifyChar();
      final onValues = expectLater(c.valuesPassive, emits([7]));
      emitValue('b001', [7]);
      await onValues;
    });

    test('notifications enables notify and delivers values', () async {
      final c = await discoverNotifyChar();
      final received = <List<int>>[];
      final sub = c.notifications.listen(received.add);
      await pump();
      expect(fake.calls, contains('setNotifyValue')); // enabled on listen

      emitValue('b001', [9]);
      await pump();
      expect(received, [
        [9],
      ]);
      await sub.cancel();
    });

    test('subscribe() ref-counts: enable on first, disable on unsubscribe', () async {
      final c = await discoverNotifyChar();
      int notifyCalls() => fake.calls.where((x) => x == 'setNotifyValue').length;

      final subscription = await c.subscribe();
      expect(subscription.isActive, isTrue);
      expect(notifyCalls(), 1); // enabled

      await subscription.unsubscribe();
      expect(subscription.isActive, isFalse);
      expect(notifyCalls(), 2); // + disabled
    });

    test('subscribe() throws if enabling notify fails', () async {
      final c = await discoverNotifyChar();
      fake.stubs['setNotifyValue'] = () => throw PlatformException(code: 'darwin_error', message: 'rejected');
      await expectLater(c.subscribe(), throwsA(isA<BluebirdException>()));
    });

    test('unsubscribe() surfaces a failed disable', () async {
      final c = await discoverNotifyChar();
      final subscription = await c.subscribe(); // enabled OK
      fake.stubs['setNotifyValue'] = () => throw PlatformException(code: 'darwin_error', message: 'disable rejected');
      await expectLater(subscription.unsubscribe(), throwsA(isA<BluebirdException>()));
    });

    test('unsubscribe does not disable through a stale discovery handle', () async {
      final c = await discoverNotifyChar();
      final subscription = await c.subscribe();
      expect(fake.calls.where((call) => call == 'setNotifyValue'), hasLength(1));

      await c.device.discoverServices(subscribeToServicesChanged: false);
      expect(c.isValid, isFalse);
      await subscription.unsubscribe();

      // The old characteristic must not target a same-shaped attribute from
      // the replacement GATT table.
      expect(fake.calls.where((call) => call == 'setNotifyValue'), hasLength(1));
    });

    test('cancelling notifications swallows a failed disable', () async {
      final c = await discoverNotifyChar();
      final sub = c.notifications.listen((_) {});
      await pump(); // enable completes
      fake.stubs['setNotifyValue'] = () => throw PlatformException(code: 'darwin_error', message: 'disable rejected');
      // a stream cancel() must not throw — the failed disable is swallowed
      // (logged) rather than leaking as an uncatchable error. Explicit
      // unsubscribe() still surfaces it (see the test above).
      await expectLater(sub.cancel(), completes);
    });

    test('notification for an unknown characteristic is dropped', () async {
      await discoverNotifyChar();

      var received = false;
      final sub = Bluebird.events.where((e) => e is OnCharacteristicNotifiedEvent).listen((_) => received = true);
      emitValue('bfff', [0]);
      await pump();
      expect(received, isFalse);
      await sub.cancel();
    });
  });

  test('detached-from-engine event stops an active scan', () async {
    final sub = Bluebird.performScan().listen((_) {});
    await pump();
    expect(Bluebird.isScanning.value, isTrue);
    fake.emit(BmDetachedFromEngineEvent());
    await pump();
    expect(Bluebird.isScanning.value, isFalse);
    await sub.cancel();
  });
}
