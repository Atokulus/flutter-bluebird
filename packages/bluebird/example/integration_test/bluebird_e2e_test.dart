// End-to-end integration test for the bluebird BLE library.
//
// Requires the ESP32-S3 hardware fixture in `tools/esp32_peripheral` to be
// flashed, powered, and advertising as "Bluebird-Test". See
// integration_test/README.md for instructions.
//
// Run with:
//   flutter test integration_test/bluebird_e2e_test.dart -d macos
//
// This suite is UI-less: it drives the bluebird API directly and shares a
// single connection across ordered tests.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebird/bluebird.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const String fixtureName = 'Bluebird-Test';
const String fixtureMissingMessage =
    "ESP32 fixture 'Bluebird-Test' not advertising — flash tools/esp32_peripheral and power it";

/// UUID scheme of the fixture: B1EBxxxx-CAFE-4E5D-A2B1-1BD5EE12B1EB
Uuid bb(String short16) => Uuid('b1eb$short16-cafe-4e5d-a2b1-1bd5ee12b1eb');

final Uuid svcA = bb('a000');
final Uuid chrStaticRead = bb('a001'); // READ: "bluebird"
final Uuid chrWriteEcho = bb('a002'); // READ | WRITE | WRITE_NO_RSP
final Uuid chrNotify = bb('a003'); // NOTIFY: counter, 1 s
final Uuid chrIndicate = bb('a004'); // INDICATE: counter, 2 s
final Uuid chrNotifyInd = bb('a005'); // NOTIFY | INDICATE: counter, 1 s
final Uuid chrLong = bb('a006'); // READ | WRITE: 512-byte buffer
final Uuid chrEncrypted = bb('a007'); // READ (encrypted): "top-secret"
final Uuid chrControl = bb('a008'); // WRITE: 0x01 svc-changed, 0x02 disconnect
final Uuid dscCustom = bb('a0ff'); // READ | WRITE 16-byte descriptor
final Uuid dscUserDescription = Uuid('2901');

final Uuid svcB = bb('b000');
final Uuid chrDuplicate = bb('b001'); // two instances, READ

// Advertisement contents (see tools/esp32_peripheral/main/main.c)
const int mfgCompanyId = 0x02E5;
const List<int> mfgPayload = [0xde, 0xad, 0xbe, 0xef];
final Uuid advServiceUuid = Uuid('181a');
const List<int> advServiceData = [0x11, 0x22, 0x33, 0x44];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late BluetoothDevice device;
  late List<BluetoothService> services;

  BluetoothService serviceByUuid(Uuid uuid) => services.firstWhere(
    (s) => s.uuid == uuid,
    orElse: () => fail('service $uuid not found on fixture; discovered: ${services.map((s) => s.uuid).toList()}'),
  );

  BluetoothCharacteristic chr(Uuid service, Uuid characteristic) => serviceByUuid(service).characteristics.firstWhere(
    (c) => c.uuid == characteristic,
    orElse: () => fail('characteristic $characteristic not found in service $service'),
  );

  int decodeCounter(List<int> value) => ByteData.sublistView(Uint8List.fromList(value)).getUint32(0, Endian.little);

  void expectStrictlyIncrementing(List<int> counters) {
    expect(counters.length, greaterThanOrEqualTo(3));
    for (int i = 1; i < counters.length; i++) {
      expect(counters[i], greaterThan(counters[i - 1]), reason: 'counter values must strictly increment: $counters');
    }
  }

  /// Scans for the fixture. Fails with [fixtureMissingMessage] if it is not
  /// seen at all within ~20s. Prefers a scan result that already carries both
  /// the manufacturer data and the (scan-response) service data.
  Future<ScanResult> scanForFixture() async {
    final completer = Completer<ScanResult>();
    ScanResult? partial;

    final sub = Bluebird.performScan(withNames: const [fixtureName]).listen((r) {
      final adv = r.advertisementData;
      if (adv.advName != fixtureName && r.platformName != fixtureName) return;
      partial = r;
      // wait until the scan-response (service data) has been merged in
      if (adv.manufacturerData.isNotEmpty && adv.serviceData.isNotEmpty) {
        if (!completer.isCompleted) completer.complete(r);
      }
    });

    try {
      return await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => partial ?? fail(fixtureMissingMessage),
      );
    } finally {
      await sub.cancel(); // stops the scan
    }
  }

  setUpAll(() async {
    // wait for the adapter to power on
    await Bluebird.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first
        .timeout(const Duration(seconds: 10), onTimeout: () => fail('bluetooth adapter did not turn on within 10s'));

    final result = await scanForFixture();

    // scan-filter / advertisement assertions
    final adv = result.advertisementData;
    expect(
      adv.manufacturerData,
      contains(mfgCompanyId),
      reason: 'advertisement must carry manufacturer data for company 0x02E5',
    );
    expect(adv.manufacturerData[mfgCompanyId], mfgPayload);
    expect(adv.serviceData, contains(advServiceUuid), reason: 'scan response must carry service data for 0x181A');
    expect(adv.serviceData[advServiceUuid], advServiceData);
    expect(adv.serviceUuids, contains(advServiceUuid));
    expect(adv.connectable, isTrue);

    device = result.device;
    // ignore: avoid_print
    print(
      'FIXTURE result: address=${result.address} platformName=${result.platformName} adv=${result.advertisementData}',
    );
    await device.connect(timeout: const Duration(seconds: 15));
    // ignore: avoid_print
    print('CONNECTED: remoteId=${device.remoteId} platformName=${device.platformName}');
    services = await device.discoverServices();
    // ignore: avoid_print
    print('DISCOVERED: ${services.map((s) => s.uuid).toList()}');
  });

  tearDownAll(() async {
    try {
      if (device.isConnected) await device.disconnect();
    } catch (_) {
      /* best effort */
    }
  });

  test(
    'service tree shape: both fixture services present with expected characteristics',
    () async {
      final a = serviceByUuid(svcA);
      final b = serviceByUuid(svcB);

      expect(a.isPrimary, isTrue);
      expect(b.isPrimary, isTrue);

      final aUuids = a.characteristics.map((c) => c.uuid).toList();
      expect(
        aUuids,
        containsAll([
          chrStaticRead,
          chrWriteEcho,
          chrNotify,
          chrIndicate,
          chrNotifyInd,
          chrLong,
          chrEncrypted,
          chrControl,
        ]),
      );

      // spot-check properties
      expect(chr(svcA, chrStaticRead).properties.read, isTrue);
      expect(chr(svcA, chrWriteEcho).properties.write, isTrue);
      expect(chr(svcA, chrWriteEcho).properties.writeWithoutResponse, isTrue);
      expect(chr(svcA, chrNotify).properties.notify, isTrue);
      expect(chr(svcA, chrIndicate).properties.indicate, isTrue);
      expect(chr(svcA, chrNotifyInd).properties.notify, isTrue);
      expect(chr(svcA, chrNotifyInd).properties.indicate, isTrue);
      expect(chr(svcA, chrControl).properties.write, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  test('AttributeId: Service B duplicate-uuid characteristics are distinct instances '
      'with different values', () async {
    final dups = serviceByUuid(svcB).characteristics.where((c) => c.uuid == chrDuplicate).toList();
    expect(dups, hasLength(2), reason: 'Service B must expose TWO characteristics with uuid $chrDuplicate');

    // the two instances must be disambiguated by their attribute ids
    expect(
      dups[0].id,
      isNot(equals(dups[1].id)),
      reason: 'same-uuid characteristics must have distinct BluetoothAttributeIds',
    );

    final v1 = utf8.decode(await dups[0].read());
    final v2 = utf8.decode(await dups[1].read());
    expect(v1, isNot(equals(v2)), reason: 'reads of the two instances must hit different attributes');
    expect({v1, v2}, {'instance-one', 'instance-two'});
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('static read returns "bluebird"', () async {
    final value = await chr(svcA, chrStaticRead).read();
    expect(utf8.decode(value), 'bluebird');
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('write with response then read-back', () async {
    final c = chr(svcA, chrWriteEcho);
    final payload = utf8.encode('hello-with-response');
    await c.write(payload);
    expect(await c.read(), payload);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('write without response then read-back', () async {
    final c = chr(svcA, chrWriteEcho);
    final payload = utf8.encode('hello-no-response');
    await c.write(payload, withoutResponse: true);
    // withoutResponse gives no delivery guarantee; give the peripheral a moment
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await c.read(), payload);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'descriptors: 0x2901 user description read + custom descriptor write/read-back',
    () async {
      final c = chr(svcA, chrStaticRead);

      final userDesc = c.descriptors.firstWhere(
        (d) => d.uuid == dscUserDescription,
        orElse: () => fail('0x2901 user description descriptor not found'),
      );
      expect(utf8.decode(await userDesc.read()), 'Bluebird static read characteristic');

      final custom = c.descriptors.firstWhere(
        (d) => d.uuid == dscCustom,
        orElse: () => fail('custom descriptor $dscCustom not found'),
      );
      final payload = [0xb1, 0xeb, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06];
      await custom.write(payload);
      expect(await custom.read(), payload);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('notify: collects >=3 strictly-incrementing counter values', () async {
    // fixture notifies a uint32 LE counter every 1 s while subscribed;
    // the notifications stream subscribes on listen, unsubscribes on cancel
    final values = await chr(
      svcA,
      chrNotify,
    ).notifications.take(3).map(decodeCounter).toList().timeout(const Duration(seconds: 10));
    expectStrictlyIncrementing(values);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('indicate: collects >=3 strictly-incrementing counter values', () async {
    // fixture indicates every 2 s while subscribed
    final values = await chr(
      svcA,
      chrIndicate,
    ).notifications.take(3).map(decodeCounter).toList().timeout(const Duration(seconds: 15));
    expectStrictlyIncrementing(values);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('notify|indicate characteristic subscribes (uses notifications)', () async {
    final c = chr(svcA, chrNotifyInd);
    final values = await c.notifications.take(3).map(decodeCounter).toList().timeout(const Duration(seconds: 10));

    expectStrictlyIncrementing(values);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('512-byte long write (allowLongWrite) + read-back equality', () async {
    final c = chr(svcA, chrLong);

    // requestMtu is Android-only (macOS negotiates the MTU automatically)
    if (System.isAndroid) {
      await device.requestMtu(517);
    }

    final payload = List<int>.generate(512, (i) => (i * 7 + 3) & 0xff);
    await c.write(payload, allowLongWrite: true, timeout: const Duration(seconds: 30));
    final back = await c.read(timeout: const Duration(seconds: 30));
    expect(back, hasLength(512));
    expect(back, payload);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('l2cap: echo channel round-trips written bytes', () async {
    // PSM 0x0080 — the fixture's L2CAP CoC echo server (see
    // tools/esp32_peripheral/main/l2cap_svr.c). `secure: false` avoids
    // requiring an encrypted link (Android); ignored on iOS/macOS.
    final channel = await device.openL2capChannel(0x0080, secure: false, timeout: const Duration(seconds: 15));
    addTearDown(() async {
      if (!channel.isClosed) await channel.close();
    });

    // L2CAP is a byte stream, so an echoed payload may arrive split across
    // events — accumulate until we have the expected number of bytes back.
    final inbound = <int>[];
    Completer<void>? pending;
    int expectedLen = 0;
    final sub = channel.input.listen((chunk) {
      inbound.addAll(chunk);
      if (pending != null && !pending!.isCompleted && inbound.length >= expectedLen) pending!.complete();
    });
    addTearDown(sub.cancel);

    Future<List<int>> echo(List<int> payload) async {
      inbound.clear();
      expectedLen = payload.length;
      pending = Completer<void>();
      await channel.write(Uint8List.fromList(payload));
      await pending!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('l2cap echo did not return $expectedLen bytes (got ${inbound.length})'),
      );
      return List<int>.of(inbound.take(expectedLen));
    }

    // round-trip a small payload, then a second write on the same channel
    expect(await echo(utf8.encode('bluebird-l2cap')), utf8.encode('bluebird-l2cap'));
    expect(await echo(const [1, 2, 3, 4, 5]), const [1, 2, 3, 4, 5]);

    // a full 512-byte SDU (the fixture's max) exercises multi-chunk + backpressure
    final big = List<int>.generate(512, (i) => (i * 31 + 7) & 0xff);
    expect(await echo(big), big);

    await channel.close();
    expect(channel.isClosed, isTrue);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('control 0x01: services-changed indication fires onServicesReset, '
      're-discovery succeeds', () async {
    final reset = device.onServicesReset.first;
    await chr(svcA, chrControl).write([0x01]);
    await reset.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('onServicesReset event not received within 10s'),
    );

    services = await device.discoverServices();
    expect(services.any((s) => s.uuid == svcA), isTrue);
    expect(services.any((s) => s.uuid == svcB), isTrue);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('control 0x02: peripheral-side disconnect emits disconnected state with a '
      'reason, then reconnect succeeds', () async {
    final disconnected = device.connectionState.where((s) => s == BluetoothConnectionState.disconnected).first;

    // the write response may be lost in the race with the disconnect
    try {
      await chr(svcA, chrControl).write([0x02], timeout: const Duration(seconds: 5));
    } catch (_) {
      /* expected on some platforms */
    }

    await disconnected.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('disconnected connectionState event not received within 10s'),
    );
    expect(
      device.disconnectReason,
      isNotNull,
      reason: 'peripheral-initiated disconnect must surface a DisconnectReason',
    );

    // fixture resumes advertising immediately; reconnect
    await device.connect(timeout: const Duration(seconds: 15));
    services = await device.discoverServices();
    expect(services.any((s) => s.uuid == svcA), isTrue);
  }, timeout: const Timeout(Duration(seconds: 40)));

  // Reading an encryption-requiring characteristic forces pairing/bonding.
  // Android exposes bond-state management (query + remove) and Just-Works
  // bonds silently; macOS/iOS bond implicitly inside CoreBluetooth (no bond
  // API) and prompt with an OS pairing dialog that must be accepted by hand.
  group('bonding', () {
    final canManageBonds = !System.isDarwin;

    test('encrypted read triggers bonding and returns "top-secret"', () async {
      // start from a clean bond so the encrypted read actually drives
      // pairing; removeBond disconnects on Android, so reconnect + rediscover
      // to run the read against live attribute handles
      if (canManageBonds && await device.bondState.value != BluetoothBondState.none) {
        await device.removeBond();
        if (!device.isConnected) {
          await device.connect(timeout: const Duration(seconds: 15));
          services = await device.discoverServices();
        }
      }

      // the read only succeeds once the link is encrypted, so a correct
      // value is itself proof that bonding completed
      final value = await chr(svcA, chrEncrypted).read(timeout: const Duration(seconds: 30));
      expect(utf8.decode(value), 'top-secret');

      if (canManageBonds) {
        expect(await device.bondState.value, BluetoothBondState.bonded);
      }
    }, timeout: const Timeout(Duration(seconds: 45)));
  });
}
