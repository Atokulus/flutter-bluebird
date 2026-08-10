# Migrating from flutter_blue_plus

Bluebird began as a rework of [flutter_blue_plus], so the shape of a session is
unchanged — scan, connect, discover, read/write/subscribe — and most of
`BluetoothDevice`, `BluetoothService`, and `BluetoothCharacteristic` works the
same. This guide covers what changed.

[flutter_blue_plus]: https://pub.dev/packages/flutter_blue_plus

## Package

```yaml
dependencies:
  bluebird: ^0.4.1   # was: flutter_blue_plus
```

```dart
import 'package:bluebird/bluebird.dart';   // was: package:flutter_blue_plus/flutter_blue_plus.dart
```

## Discovering services & characteristics

In flutter_blue_plus you can construct a `BluetoothCharacteristic` yourself from a
`remoteId` plus service/characteristic UUIDs and read or write it straight away.
In bluebird a characteristic (or descriptor) is only ever obtained by **discovering
it** — there is no public constructor. Walk the tree from `discoverServices()`:

```dart
final services = await device.discoverServices();
final service = services.firstWhere((s) => s.uuid == Uuid('180d'));
final characteristic = service.characteristics.firstWhere((c) => c.uuid == Uuid('2a37'));
await characteristic.read();
```

The discovered tree is cached on `device.services` (empty until you call
`discoverServices()`; re-discover when the peer signals its services changed).
Descriptors hang off `characteristic.descriptors` the same way.

To ease migration, a small extension recovers the flutter_blue_plus habit of
grabbing a characteristic by UUID alone — it just searches every discovered
service:

```dart
extension FindCharacteristic on BluetoothDevice {
  BluetoothCharacteristic? findCharacteristicOrNull(Uuid uuid) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == uuid) return characteristic;
      }
    }
    return null;
  }
}
```

**Why:** a UUID does not uniquely identify an attribute — the same service or
characteristic UUID can legally appear more than once on a device. bluebird
identifies each attribute by a discovered instance token (`BluetoothAttributeId`)
that disambiguates duplicates, so every read/write targets the exact attribute
the device exposed rather than a handle fabricated client-side that may not exist.

## Renames

| flutter_blue_plus | bluebird |
| --- | --- |
| `FlutterBluePlus` | `Bluebird` |
| `Guid` | `Uuid` |
| `FlutterBluePlusException` | `BluebirdException` |
| `FbpErrorCode` | `BluebirdErrorCode` |

`Guid('180d')` becomes `Uuid('180d')` (same 16-/32-/128-bit forms). Anywhere you
passed `List<Guid>` — e.g. `withServices` — now takes `List<Uuid>`.

## Scanning

Scanning keeps the same start / observe / stop shape as flutter_blue_plus —
`startScan(...)`, watch `scanResults` for the growing device list, and
`stopScan()` when done. The names are almost identical:

```dart
// flutter_blue_plus
var sub = FlutterBluePlus.scanResults.listen((results) { ... });
await FlutterBluePlus.startScan(withServices: [Guid('180d')], timeout: Duration(seconds: 15));
// ... later:
await FlutterBluePlus.stopScan();

// bluebird
final sub = Bluebird.scanResults.listen((results) { ... });
await Bluebird.startScan(withServices: [Uuid('180d')], timeout: Duration(seconds: 15));
// ... later:
await Bluebird.stopScan();
```

| flutter_blue_plus | bluebird |
| --- | --- |
| `FlutterBluePlus.startScan(...)` | `Bluebird.startScan(...)` |
| `FlutterBluePlus.stopScan()` | `Bluebird.stopScan()` |
| `FlutterBluePlus.scanResults` (growing device list) | `Bluebird.scanResults` (also exposes `.value`) |
| `FlutterBluePlus.isScanningNow` | `Bluebird.isScanning.value` |
| `FlutterBluePlus.isScanning` (`Stream<bool>`) | `Bluebird.isScanning` (listen the same way) |

(`Bluebird.scanResults` is the de-duplicated device list; for the raw
one-`ScanResult`-per-advertisement feed use `Bluebird.scanAdvertisements`.)

Scan filter arguments (`withServices`, `withNames`, `withKeywords`, `withMsd`,
`withServiceData`, `androidScanMode`, `continuousUpdates`, …) are unchanged apart
from `Guid` → `Uuid`.

## Advertisements

`AdvertisementData.advName` is `String?`. It is `null` when the advertisement
carries no name, rather than an empty string, so provide a fallback when you
need something to display:

```dart
final name = result.advertisementData.advName ?? result.device.platformName;
```

The remaining fields — `manufacturerData` (`Map<int, List<int>>`), `serviceData`,
`serviceUuids`, `txPowerLevel`, `appearance`, and `connectable` — keep the same
names and types, with `Guid` → `Uuid` in the `serviceData` keys and
`serviceUuids`.

## Adapter state

```dart
// flutter_blue_plus
var now = FlutterBluePlus.adapterStateNow;

// bluebird
var now = Bluebird.adapterState.value;
```

`Bluebird.adapterState` is a stream you can `listen` to and also exposes the
current value via `.value`. The `BluetoothAdapterState` and `BluetoothBondState`
enums keep the same names and values as flutter_blue_plus.

## Connection state

`device.connectionState` is a `ValueStream<BluetoothConnectionState>`: read the
current value with `.value` or `listen` for changes. The enum carries two
transient states alongside the terminal ones:

```dart
enum BluetoothConnectionState { disconnected, connected, connecting, disconnecting }
```

`connecting` and `disconnecting` are synthesized on the Dart side around
`device.connect()` / `device.disconnect()` — the platforms report only the
terminal states — so a `switch` over `connectionState` must handle all four.

There is no `device.isDisconnected`. Use `!device.isConnected`, or compare
against `disconnected` when you need to tell a fully-disconnected device from one
mid-transition:

```dart
if (device.connectionState.value == BluetoothConnectionState.disconnected) { ... }
```

## Characteristic values & notifications

flutter_blue_plus separated "enable notify" from "receive values" and cached the
last value. In bluebird, **listening to `notifications` enables notify/indicate**,
and `read()` returns the value directly — there is no `lastValueStream`.

```dart
// flutter_blue_plus
await c.setNotifyValue(true);
c.onValueReceived.listen((value) { ... });   // or c.lastValueStream
final value = await c.read();                // then read from c.lastValue / onValueReceived

// bluebird
final sub = c.notifications.listen((value) { ... });   // listening turns notify on
await sub.cancel();                                     // cancelling turns it off
final value = await c.read();                           // read() returns the value
```

| flutter_blue_plus | bluebird |
| --- | --- |
| `c.setNotifyValue(true)` + `c.onValueReceived` / `c.lastValueStream` | `c.notifications.listen(...)` |
| `c.setNotifyValue(false)` | cancel the `notifications` subscription |
| `c.lastValue` | not retained — keep the value from `read()` or the latest notification |
| `c.read()` (then read `lastValue`) | `c.read()` returns the value |
| `c.isNotifying` | track your own subscription, or use `c.notificationsPassive` to observe without enabling |

Descriptors work the same way; `write(value, withoutResponse:, allowLongWrite:)`
is unchanged.

## Errors

```dart
try {
  await c.read();
} on BluebirdException catch (e) {          // was: FlutterBluePlusException
  if (e.code == BluebirdErrorCode.deviceDisconnected) { ... }
}
```

## Logging

flutter_blue_plus had a single `setLogLevel` that also drove console output. In
bluebird these are two separate concerns:

- **`Bluebird.logger`** — a [`package:logging`](https://pub.dev/packages/logging)
  `Logger` carrying all Dart-side logs. It is silent by default; attach your own
  listener and pick a level (nothing is printed unless you do):

  ```dart
  Bluebird.logger.onRecord.listen((r) => debugPrint('${r.level.name} ${r.message}'));
  Bluebird.logger.level = Level.INFO;
  ```

- **`Bluebird.setPlatformLogLevel(LogLevel.verbose)`** — the native/platform log
  verbosity (Android logcat / Apple os_log) only. This replaces `setLogLevel`; the
  old `color:` argument is gone. (Dart-side call tracing is separate — it logs to
  `Bluebird.logger` at `Level.FINEST`.)

| flutter_blue_plus | bluebird |
| --- | --- |
| `FlutterBluePlus.setLogLevel(level, color: …)` | `Bluebird.setPlatformLogLevel(level)` |
| console `print` output (on by default) | attach `Bluebird.logger.onRecord.listen(...)` (off by default) |

## Other differences

- **`device.connect()`** no longer takes `autoConnect`; it's `connect({timeout, mtu})`.
- **`FlutterBluePlus.events`** is now **`Bluebird.events`** (same event classes).
- Everything else on `BluetoothDevice` — `disconnect()`, `discoverServices()`,
  `readRssi()`, `requestMtu()`, `connectionState`, `mtu`, `bondState`,
  `createBond()`, `removeBond()`, `clearGattCache()`, `setPreferredPhy()`,
  `requestConnectionPriority()` — and `Bluebird.connectedDevices`,
  `systemDevices()`, `bondedDevices`, `turnOn()`, `setOptions()`,
  `isSupported` keep the same names.
