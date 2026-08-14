import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'protos.dart';

void main() {
  late BluetoothDevice firstDevice;
  late BluetoothDevice secondDevice;

  setUp(() {
    FakePlatform.install(FakePlatform());
    firstDevice = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:01');
    secondDevice = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:02');
  });

  Future<void> connectDevices() async {
    await firstDevice.connect(mtu: null);
    await secondDevice.connect(mtu: null);
  }

  test('global mode serializes operations across devices', () async {
    expect(Bluebird.operationQueueMode, OperationQueueMode.global);
    await connectDevices();

    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();

    final first = firstDevice.invoke('first', (_) async {
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;

    final second = secondDevice.invoke('second', (_) async {
      secondStarted.complete();
    });
    await pumpEventQueue();
    expect(secondStarted.isCompleted, isFalse);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(secondStarted.isCompleted, isTrue);
  });

  test('per-device mode overlaps operations on separate devices', () async {
    Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);
    await connectDevices();

    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();

    final first = firstDevice.invoke('first', (_) async {
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;

    final second = secondDevice.invoke('second', (_) async {
      secondStarted.complete();
    });
    await secondStarted.future.timeout(const Duration(seconds: 1));

    releaseFirst.complete();
    await Future.wait([first, second]);
  });

  test('per-device mode overlaps connection attempts', () async {
    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    var invocation = 0;

    FakePlatform.install(
      FakePlatform()
        ..stubs['connect'] = () {
          invocation++;
          if (invocation == 1) {
            firstStarted.complete();
            return releaseFirst.future;
          }
          secondStarted.complete();
          return null;
        },
    );
    firstDevice = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:01');
    secondDevice = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:02');
    Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);

    final first = firstDevice.connect(mtu: null);
    await firstStarted.future;
    final second = secondDevice.connect(mtu: null);
    await secondStarted.future.timeout(const Duration(seconds: 1));

    releaseFirst.complete();
    await Future.wait([first, second]);
  });

  test('per-device mode still serializes operations on the same device', () async {
    Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);
    await connectDevices();

    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();

    final first = firstDevice.invoke('first', (_) async {
      firstStarted.complete();
      await releaseFirst.future;
    });
    await firstStarted.future;

    final second = firstDevice.invoke('second', (_) async {
      secondStarted.complete();
    });
    await pumpEventQueue();
    expect(secondStarted.isCompleted, isFalse);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(secondStarted.isCompleted, isTrue);
  });

  test('per-device mode pipelines write-without-response calls on one device', () async {
    final releases = <Completer<void>>[];
    final started = <Completer<void>>[];
    final platform = FakePlatform()
      ..services = [
        bmService('1800', characteristics: [bmChar('2a00', properties: props(writeWithoutResponse: true))]),
      ]
      ..stubs['writeCharacteristic'] = () {
        final release = Completer<void>();
        releases.add(release);
        started.add(Completer<void>()..complete());
        return release.future;
      };
    FakePlatform.install(platform);
    firstDevice = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:01');
    Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);
    await firstDevice.connect(mtu: null);
    final characteristic = (await firstDevice.discoverServices()).single.characteristics.single;

    final first = characteristic.write([1], withoutResponse: true);
    await pumpEventQueue();
    final second = characteristic.write([2], withoutResponse: true);
    await pumpEventQueue();

    expect(started, hasLength(2));
    releases[0].complete();
    releases[1].complete();
    await Future.wait([first, second]);
  });

  test('response-bearing operation waits for a write-without-response burst', () async {
    final writeRelease = Completer<void>();
    final readStarted = Completer<void>();
    final platform = FakePlatform()
      ..services = [
        bmService('1800', characteristics: [bmChar('2a00', properties: props(read: true, writeWithoutResponse: true))]),
      ]
      ..stubs['writeCharacteristic'] = () {
        return writeRelease.future;
      }
      ..stubs['readCharacteristic'] = () {
        readStarted.complete();
        return Uint8List(0);
      };
    FakePlatform.install(platform);
    firstDevice = Bluebird.deviceForAddress('AA:BB:CC:DD:EE:01');
    Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);
    await firstDevice.connect(mtu: null);
    final characteristic = (await firstDevice.discoverServices()).single.characteristics.single;

    final write = characteristic.write([1], withoutResponse: true);
    await pumpEventQueue();
    final read = characteristic.read();
    await pumpEventQueue();
    expect(readStarted.isCompleted, isFalse);

    writeRelease.complete();
    await Future.wait([write, read]);
    expect(readStarted.isCompleted, isTrue);
  });

  test('queue mode cannot change after device operations begin', () async {
    await firstDevice.connect(mtu: null);

    expect(() => Bluebird.setOperationQueueMode(OperationQueueMode.perDevice), throwsStateError);
  });
}
