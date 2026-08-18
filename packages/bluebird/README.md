<p align="center">
  <img src="https://raw.githubusercontent.com/nebkat/flutter-bluebird/main/site/bluebird.png" alt="bluebird" width="500">
</p>

[![pub package](https://img.shields.io/pub/v/bluebird.svg)](https://pub.dev/packages/bluebird)
[![pub points](https://img.shields.io/pub/points/bluebird?color=2E7D32)](https://pub.dev/packages/bluebird/score)
[![Coverage Status](https://coveralls.io/repos/github/nebkat/flutter-bluebird/badge.svg?branch=main)](https://coveralls.io/github/nebkat/flutter-bluebird?branch=main)
[![GitHub stars](https://img.shields.io/github/stars/nebkat/flutter-bluebird?style=social)](https://github.com/nebkat/flutter-bluebird)

[![Platform](https://img.shields.io/badge/platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Web-lightgrey)](https://github.com/nebkat/flutter-bluebird)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.44.0-blue.svg?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-%3E%3D3.12.0-blue.svg?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)


A Bluetooth Low Energy (BLE) plugin for Flutter.

- Zero dependencies
- Easy-to-use interface
- Comprehensively tested
- Permissive license ([BSD-3](./LICENSE))

> [!TIP]
> **Try the demo** [in your browser](https://nebkat.github.io/flutter-bluebird/) or download the Android
demo APK from the [latest release](https://github.com/nebkat/flutter-bluebird/releases/latest).

> [!IMPORTANT]
> Migrating from [FlutterBluePlus](https://pub.dev/packages/flutter_blue_plus)? Check out the [migration guide](https://github.com/nebkat/flutter-bluebird/blob/main/MIGRATION.md).

## Quick Start

### Turn on
```dart
// On iOS this is controlled by the user
if (Platform.isAndroid) await Bluebird.turnOn();

// Wait for adapter to be ready
await Bluebird.adapterReady();
```

### Scan for devices

```dart
// The growing, de-duplicated device list, updated as devices are discovered
final subscription = Bluebird.scanResults.listen((List<ScanResult> results) {
  for (final ScanResult r in results) {
    print('${r.device.remoteId}: "${r.advertisementData.advName}"');
  }
});

// Start scanning
await Bluebird.startScan(withServices: [Uuid("180D")], withNames: ["Bluno"]);

// ... and stop when you're done
await Bluebird.stopScan();
```

> [!TIP]
> Prefer a self-stopping stream? `Bluebird.performScan(...)` starts the scan when you listen and stops it when you cancel (or `break` from an `await for`) — no explicit `stopScan` needed.

### Connect to a device

```dart
// Obtain a device from a ScanResult
final BluetoothDevice device = scanResult.device;
//      Or from raw address: = BluetoothDevice.fromId("77:c6:24:e3:bb:ec");
await device.connect();

// Disconnect when you're done.
await device.disconnect();
```

### Connect to multiple devices concurrently

By default Bluebird preserves its historical process-wide operation queue. Apps
that communicate with multiple peripherals should enable independent per-device
queues before starting any Bluetooth device operation:

```dart
Bluebird.setOperationQueueMode(OperationQueueMode.perDevice);
```

Operations remain ordered within each device, while connections, discovery,
reads, and writes for separate devices can proceed concurrently.

In per-device mode, consecutive `write(..., withoutResponse: true)` calls may
also be submitted without awaiting each one. Bluebird pipelines that burst in
call order and applies the platform's native flow control. On Android, each
GATT callback starts the next queued frame directly before completing the prior
Flutter call, so this native pump applies equally to DFU data and ordinary
multi-frame protocols. Any following response-bearing GATT operation waits for
the burst:

```dart
await Future.wait(frames.map((frame) => characteristic.write(frame, withoutResponse: true)));
```

### Discover services, characteristics & descriptors

```dart
await device.discoverServices();

final service = device.services.firstWhere((s) => s.uuid == Uuids.service.deviceInformation);
final characteristic = service.characteristics.firstWhere((c) => c.uuid == Uuids.characteristic.manufacturerName);
final descriptor = characteristic.descriptors.firstWhere((c) => c.uuid == Uuids.descriptors.characteristicUserDescription);
```

> [!WARNING]
> Calling `discoverServices` (and disconnecting) invalidates any previously discovered attributes, as the
> underlying Bluetooth handles are only valid within a connection and may change on re-discovery. Always
> re-fetch from `device.services` after (re-)connecting. Using a stale attribute throws — check
> `attribute.isValid`.

### Subscribe to characteristic notifications

```dart
// Enables notifications (or indications) on the peripheral (check c.canNotify if unsure)
final subscription = characteristic.notifications.listen(
    (value) {
        // Called for each notification/indication
    },
    // The stream *errors* if the peripheral fails to enable notifications
    onError: (e) => print("failed to enable notify: $e"),
);

// Disables notifications on the peripheral
await subscription.cancel();
```

> [!TIP]
> No need to explicitly manage the underlying subscription state. If there are any active Flutter
> subscriptions the platform enables CCCD, and once all subscriptions are cancelled it disables CCCD.


### Read & write characteristics

```dart
// Read (check c.canRead if unsure)
List<int> value = await c.read();

// Write (check c.canWrite if unsure)
await c.write([0x12, 0x34]);
```

### Read & write descriptors

```dart
// Read
List<int> value = await d.read();

// Write
await d.write([0x12, 0x34])
```

### L2CAP channels

Open a connection-oriented L2CAP channel — a bidirectional byte stream to the
peer, independent of GATT (Android & iOS/macOS; not supported on Web):

```dart
final channel = await device.openL2capChannel(0x80); // the peer's PSM
channel.input.listen((bytes) { /* data from the peer */ });
await channel.write(Uint8List.fromList([0x12, 0x34]));
await channel.close();
```

## Example

Bluebird ships with an example app that is useful for debugging issues.

```
cd ./example
flutter run
```

You can also try it without building anything:
- **Web:** live at [nebkat.github.io/flutter-bluebird](https://nebkat.github.io/flutter-bluebird/) (Chrome/Edge — Web Bluetooth is Chromium-only).
- **Android:** download the demo APK attached to the [latest release](https://github.com/nebkat/flutter-bluebird/releases/latest).

## Project Setup

### Android

#### `minSdkVersion`

In `android/app/build.gradle`:

```gradle
android {
  defaultConfig {
     minSdkVersion: 24 // or higher
```

#### Permissions (without fine location)

In `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Tell Google Play Store that your app uses Bluetooth LE
     Set android:required="true" if bluetooth is necessary -->
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />

<!-- New Bluetooth permissions in Android 12
https://developer.android.com/about/versions/12/features/bluetooth-permissions -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- legacy for Android 11 or lower -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>

<!-- legacy for Android 9 or lower -->
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="28" />
```

#### Permissions (with fine location)

If you want to use Bluetooth to determine location, or support iBeacons.

In `android/app/src/main/AndroidManifest.xml`:

```xml
<!-- Tell Google Play Store that your app uses Bluetooth LE
     Set android:required="true" if bluetooth is necessary -->
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />

<!-- New Bluetooth permissions in Android 12
https://developer.android.com/about/versions/12/features/bluetooth-permissions -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />

<!-- legacy for Android 11 or lower -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />

<!-- legacy for Android 9 or lower -->
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="28" />
```

And set **androidUsesFineLocation** when scanning:
```dart
// Start scanning
await Bluebird.startScan(androidUsesFineLocation: true);
```

#### Proguard

In `project/android/app/proguard-rules.pro`:

```
-keep class com.lib.bluebird.* { *; }
```

To avoid seeing the following errors in your `release` builds:

```
PlatformException(startScan, Field androidScanMode_ for m0.e0 not found. Known fields are
 [private int m0.e0.q, private b3.b0$i m0.e0.r, private boolean m0.e0.s, private static final m0.e0 m0.e0.t,
 private static volatile b3.a1 m0.e0.u], java.lang.RuntimeException: Field androidScanMode_ for m0.e0 not found
```

### iOS

#### Permissions

In **ios/Runner/Info.plist**:

```dart
<dict>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>This app needs Bluetooth to function</string>
```

For location permissions on iOS see more at: [https://developer.apple.com/documentation/corelocation/requesting_authorization_for_location_services](https://developer.apple.com/documentation/corelocation/requesting_authorization_for_location_services)

### macOS

Make sure you have granted access to the Bluetooth hardware:

`Xcode -> Runners -> Targets -> Runner-> Signing & Capabilities -> App Sandbox -> Hardware -> Enable Bluetooth`


## Advanced Usage

### Error Handling

Every error returned by the native platform is checked and thrown as an exception where appropriate. See [Reference](#reference) for a list of throwable functions.

**Streams:** Most state streams returned by Bluebird (e.g. `adapterState`, `device.connectionState`, `device.mtu`) never emit errors and never close, so there's no need to handle `onError` or `onDone`. The exceptions are the *operation* streams that can fail: `Bluebird.performScan()` (errors if a scan cannot start; `startScan` surfaces the same as a thrown exception) and `characteristic.notifications` / `characteristic.values` (error if enabling notify fails) — handle `onError` on those.

### Logging

All Bluebird logs flow through a single [`package:logging`](https://pub.dev/packages/logging) `Logger`, exposed as `Bluebird.logger`. It is *detached* and silent by default. For the common case — just print to the console — there's a one-liner:

```dart
Bluebird.configureLoggerPrinting(); // prints INFO and above; pass level: to change it
```

For anything else, routing and filtering are entirely yours — add [`package:logging`](https://pub.dev/packages/logging) to your `pubspec.yaml`, then listen to `onRecord` and set the level:

```dart
Bluebird.logger.onRecord.listen((r) => myLogger.log(r)); // e.g. a file, Crashlytics, …
Bluebird.logger.level = Level.INFO;                      // FINE / FINEST / … to see more
```

Low-level **platform-channel call tracing** — every call in and out — is logged at `Level.FINEST`, so lower the logger's level to see it:

```dart
Bluebird.logger.level = Level.FINEST;
```

Separately, `Bluebird.setPlatformLogLevel(LogLevel.verbose)` turns up the **native** logging (Android logcat / Apple os_log); those lines surface through the platform's own tooling, not through `Bluebird.logger`.

### Large characteristic writes

**allowLongWrite**: To write large characteristics (up to 512 bytes) regardless of mtu, use `allowLongWrite`:

```dart
/// allowLongWrite should be used with caution.
///   1. it can only be used *with* response to avoid data loss
///   2. the peripheral device must support the 'long write' ble protocol.
///   3. Interrupted transfers can leave the characteristic in a partially written state
///   4. If the mtu is small, it is very very slow.
await c.write(data, allowLongWrite: true);
```

**splitWrite**: To write lots of data (unlimited), you can define the `splitWrite` function.

```dart
import 'dart:math';
// split write should be used with caution.
//    1. due to splitting, `characteristic.read()` will return partial data.
//    2. it can only be used *with* response to avoid data loss
//    3. The characteristic must be designed to support split data
extension splitWrite on BluetoothCharacteristic {
  Future<void> splitWrite(List<int> value, {Duration timeout = const Duration(seconds: 15)}) async {
    int chunk = device.maxAttrLen.value; // mtu - 3 bytes BLE overhead, capped at 512
    for (int i = 0; i < value.length; i += chunk) {
      List<int> subvalue = value.sublist(i, min(i + chunk, value.length));
      await write(subvalue, withoutResponse:false, timeout: timeout);
    }
  }
}
```

### Values (including reads)

`characteristic.values` is like `notifications` but **also includes the result of
every `read()`**. It is convenient for characteristics that support both READ and
NOTIFY — e.g. a "light switch toggle". Like `notifications`, listening enables
notify; `valuesPassive` is the non-subscribing variant.

```dart
final subscription = characteristic.values.listen((value) {
    // emitted anytime read() is called *or* a notification arrives
});

await characteristic.read(); // also flows through `values`
await subscription.cancel();
```

### Keeping notify enabled independently

If you want to keep notify enabled regardless of who is listening — or share it
between several consumers — hold a `CharacteristicSubscription` from `subscribe()`
and observe the *passive* streams (which do **not** toggle notify themselves):

```dart
// enable notify and keep it on until you unsubscribe
final handle = await characteristic.subscribe();

// observe values without affecting the notify state
final sub = characteristic.notificationsPassive.listen((value) { /* ... */ });

// later — release your handle (disables notify once nothing else holds it)
await sub.cancel();
await handle.unsubscribe();
```

### Typed characteristic & descriptor views

`characteristic.map(decode, encode:)` returns a `MappedBluetoothCharacteristic<T>` —
a typed view whose `read`/`write`/`notifications` speak `T` instead of `List<int>`,
so you decode/encode in one place instead of at every call site.

```dart
// decode bytes -> T on the way out; encode T -> bytes on the way in
final level = characteristic.map(
  (bytes) => bytes.isEmpty ? 0 : bytes.first,
  encode: (n) => [n],
);

int battery = await level.read();     // Future<int>
level.notifications.listen(print);     // Stream<int>
await level.write(42);                 // encodes, then writes
```

- **`encode` is optional** — omit it for a read-only mapping; calling `write()`
  without one throws a `StateError`.
- **Everything else delegates** to the underlying characteristic (`uuid`,
  `properties`, `canRead`/`canWrite`/`canNotify`, `descriptors`, `subscribe()`,
  the passive streams, …), and the raw characteristic is always reachable via `.raw`.
- **Mappings chain** — `.map(...).map(...)` composes the decoders (and encoders,
  when both are present).

It is *not* itself a `BluetoothCharacteristic` (its `read()` returns `Future<T>`), so
keep the mapped view where you want typed access and use `.raw` for the byte-level API.

Descriptors work the same way via `descriptor.map(...)` → `MappedBluetoothDescriptor<T>`:

```dart
final userDescription = descriptor.map(utf8.decode, encode: utf8.encode);
String text = await userDescription.read();
```

### Accumulating scan results

`Bluebird.scanResults` is already the growing, de-duplicated device list (keyed by
address) — that's what `startScan` accumulates into. If instead you have a raw
advertisement stream — `Bluebird.scanAdvertisements` or `Bluebird.performScan()`,
which emit one `ScanResult` at a time — use `.accumulate()` to collect them the same
way (with control over the options below):

```dart
Bluebird.performScan().accumulate().listen((List<ScanResult> results) {
  // the full list so far, updated on every advertisement
});
```

- **`coalesce`** (default `true`): a device splits its data across the advertising and
  scan-response packets, so any single packet may omit fields an earlier one carried
  (commonly the name). `accumulate` merges each new advertisement onto the stored one,
  carrying those fields forward so they don't flicker. Pass `coalesce: false` to keep
  each latest packet verbatim. (You can also merge two results yourself with
  `first.mergedWith(newer)`.)
- **`removeIfGone`**: drop a device from the list once it hasn't re-advertised within
  the given duration — see [Scanned device never goes away](#scanned-device-never-goes-away).

### Save Device

To save a device between app restarts, just store the `remoteId` to `SharedPreferences` or a file.

Now you can connect without needing to scan again, like so:

```dart
final String remoteId = await File('/remoteId.txt').readAsString();
var device = BluetoothDevice.fromId(remoteId);
await device.connect();
```

### MTU

On Android, we request an MTU of 517 by default during connection (see: `connect` function arguments).

On iOS & macOS, the MTU is negotiated automatically, typically 135 to 255.

```dart
final subscription = device.mtu.listen((int mtu) {
    // iOS: initial value is always 23, but iOS will quickly negotiate a higher value
    print("mtu $mtu");
});

// Cleanup: cancel subscription when disconnected
device.cancelWhenDisconnected(subscription);

// You can also manually change the mtu yourself.
if (Platform.isAndroid) await device.requestMtu(517);
```

### Services Changed Characteristic

Bluebird automatically listens to the Services Changed Characteristic (0x2A05)

In Bluebird, we call it `onServicesReset` because you must re-discover services.

```dart
// - uses the GAP Services Changed characteristic (0x2A05)
// - you must call discoverServices() again
device.onServicesReset.listen(() async {
    print("Services Reset");
    // a reset invalidates every previously discovered attribute; re-discover and
    // re-fetch anything you use, don't reuse old references.
    await device.discoverServices();
});
```

### Get Connected Devices

Get devices currently connected to your app.

```dart
for (BluetoothDevice d in Bluebird.connectedDevices) {
    print(d);
}
```

### Get System Devices

Get devices connected to the system by *any* app.

**Note:** before you can communicate, you must connect *your app* to these devices

```dart
// `withServices` required on iOS, ignored on android
List<Uuid> withServices = [Uuid("180F")];
List<BluetoothDevice> devs = await Bluebird.systemDevices(withServices);
for (final d in devs) {
    await d.connect(); // Must connect *our* app to the device
    await d.discoverServices();
}
```

### Create Bond (Android Only)

**Note:** calling this is usually not necessary!! The platform will do it automatically.

However, you can force the popup to show sooner.

```dart
final bsSubscription = device.bondState.listen((value) {
    print("$value prev:{$device.prevBondState}");
});

// cleanup: cancel subscription when disconnected
device.cancelWhenDisconnected(bsSubscription);

// Force the bonding popup to show now (Android Only)
await device.createBond();

// remove bond
await device.removeBond();
```

### Events API

`Bluebird.events` is a single broadcast stream of every event, from every device.
Each event is a subtype of the sealed `BluebirdEvent` class, so you can filter it
by type. Event types include:

* `OnConnectionStateChangedEvent`
* `OnMtuChangedEvent`
* `OnServicesResetEvent`
* `OnCharacteristicNotifiedEvent` / `OnCharacteristicReadEvent`
* `OnAdapterStateChangedEvent`
* `OnScanAdvertisementEvent` / `OnScanFailedEvent`
* `OnNameChangedEvent` (iOS only)
* `OnBondStateChangedEvent` (Android only)

```dart
// listen to *any device* connection state changes
Bluebird.events
    .where((e) => e is OnConnectionStateChangedEvent)
    .cast<OnConnectionStateChangedEvent>()
    .listen((event) {
  print('${event.device} ${event.connectionState}');
});

// or use the typed helper, which filters and casts for you
Bluebird.extractEventStream<OnConnectionStateChangedEvent>().listen((event) {
  print('${event.device} ${event.connectionState}');
});
```

Because every event is sealed, a `switch` over `Bluebird.events` is checked for
exhaustiveness by the compiler.

## Mocking

To mock `Bluebird` for development, refer to the [Mocking Guide](MOCKING.md).

## Reference

🌀 = Stream
⚡ = synchronous

### Bluebird API

|                        |      Android       |        iOS         | Throws | Description                                                |
| :--------------------- | :----------------: | :----------------: | :----: | :----------------------------------------------------------|
| setPlatformLogLevel    | :white_check_mark: | :white_check_mark: |        | Configure native/platform log verbosity                    |
| setOptions             | :white_check_mark: | :white_check_mark: |        | Set configurable bluetooth options                         |
| isSupported            | :white_check_mark: | :white_check_mark: |        | Checks whether the device supports Bluetooth               |
| turnOn                 | :white_check_mark: |                    | :fire: | Turns on the bluetooth adapter                             |
| adapterState        🌀 | :white_check_mark: | :white_check_mark: |        | Async value + stream of on/off states (`await .value` for current) |
| adapterReady           | :white_check_mark: | :white_check_mark: | :fire: | Completes once the adapter is on; throws if unavailable/unauthorized |
| startScan               | :white_check_mark: | :white_check_mark: | :fire: | Start a scan; devices accumulate into `scanResults`        |
| stopScan                | :white_check_mark: | :white_check_mark: |        | Stop a scan started with `startScan`                       |
| scanResults         🌀 | :white_check_mark: | :white_check_mark: |        | Value + stream of the de-duplicated device list (`.value`) |
| scanAdvertisements  🌀 | :white_check_mark: | :white_check_mark: |        | Stream of raw advertisements, one `ScanResult` at a time   |
| performScan         🌀 | :white_check_mark: | :white_check_mark: | :fire: | All-in-one advertisement stream; stops when cancelled      |
| isScanning          🌀 | :white_check_mark: | :white_check_mark: |        | Value + stream of the current scanning state (`.value`)    |
| connectedDevices    ⚡  | :white_check_mark: | :white_check_mark: |        | List of devices connected to *your app*                    |
| systemDevices          | :white_check_mark: | :white_check_mark: | :fire: | List of devices connected to the system, even by other apps|
| getPhySupport          | :white_check_mark: |                    | :fire: | Get supported bluetooth phy codings                        |

### Bluebird Events API

`Bluebird.events` is a single broadcast stream of `BluebirdEvent`s from *all
devices*. Filter it by type — either with `.where((e) => e is T)` or the typed
`Bluebird.extractEventStream<T>()` helper. Event types:

| Event                            |      Android       |        iOS         | Description                                     |
| :------------------------------- | :----------------: | :----------------: | :-----------------------------------------------|
| `OnConnectionStateChangedEvent`  | :white_check_mark: | :white_check_mark: | Connection state changed                        |
| `OnMtuChangedEvent`              | :white_check_mark: | :white_check_mark: | MTU changed                                     |
| `OnServicesResetEvent`           | :white_check_mark: | :white_check_mark: | Services changed & must be rediscovered         |
| `OnCharacteristicNotifiedEvent`  | :white_check_mark: | :white_check_mark: | A notify/indicate value arrived                 |
| `OnCharacteristicReadEvent`      | :white_check_mark: | :white_check_mark: | A `read()` completed                            |
| `OnAdapterStateChangedEvent`     | :white_check_mark: | :white_check_mark: | Bluetooth adapter turned on/off                 |
| `OnScanAdvertisementEvent`       | :white_check_mark: | :white_check_mark: | A scan advertisement was received               |
| `OnScanFailedEvent`              | :white_check_mark: | :white_check_mark: | A scan failed to start                          |
| `OnBondStateChangedEvent`        | :white_check_mark: |                    | Android bond state changed                      |
| `OnNameChangedEvent`             |                    | :white_check_mark: | iOS device name changed                         |


### BluetoothDevice API

|                           |      Android       |        iOS         | Throws | Description                                                |
| :------------------------ | :----------------: | :----------------: | :----: | :----------------------------------------------------------|
| platformName            ⚡ | :white_check_mark: | :white_check_mark: |        | The platform preferred name of the device                  |
| advName                 ⚡ | :white_check_mark: | :white_check_mark: |        | The advertised name of the device found during scanning    |
| connect                   | :white_check_mark: | :white_check_mark: | :fire: | Establishes a connection to the device                     |
| disconnect                | :white_check_mark: | :white_check_mark: | :fire: | Cancels an active or pending connection to the device      |
| isConnected             ⚡ | :white_check_mark: | :white_check_mark: |        | Is this device currently connected to *your app*?          |
| isDisonnected           ⚡ | :white_check_mark: | :white_check_mark: |        | Is this device currently disconnected from *your app*?     |
| connectionState        🌀 | :white_check_mark: | :white_check_mark: |        | Value + stream of connection changes (`.value` for current)|
| discoverServices          | :white_check_mark: | :white_check_mark: | :fire: | Discover services                                          |
| services                ⚡ | :white_check_mark: | :white_check_mark: |        | The current list of discovered services                    |
| onServicesReset        🌀 | :white_check_mark: | :white_check_mark: |        | The services changed & must be rediscovered                |
| mtu                    🌀 | :white_check_mark: | :white_check_mark: |        | Value + stream of the mtu (`.value` for current)           |
| maxAttrLen              ⚡ | :white_check_mark: | :white_check_mark: |        | Value + stream of the max writable attribute length        |
| readRssi                  | :white_check_mark: | :white_check_mark: | :fire: | Read RSSI from a connected device                          |
| requestMtu                | :white_check_mark: |                    | :fire: | Request to change the MTU for the device                   |
| requestConnectionPriority | :white_check_mark: |                    | :fire: | Request to update a high priority, low latency connection  |
| bondState              🌀 | :white_check_mark: |                    |        | Stream of device bond state. Can be useful on Android      |
| createBond                | :white_check_mark: |                    | :fire: | Force a system pairing dialogue to show, if needed         |
| removeBond                | :white_check_mark: |                    | :fire: | Remove Bluetooth Bond of device                            |
| setPreferredPhy           | :white_check_mark: |                    | :fire: | Set preferred RX and TX phy for connection and phy options |
| clearGattCache            | :white_check_mark: |                    | :fire: | Clear android cache of service discovery results           |

### BluetoothCharacteristic API

|                        |      Android       |        iOS         | Throws | Description                                              |
| :--------------------- | :----------------: | :----------------: | :----: | :--------------------------------------------------------|
| uuid                 ⚡ | :white_check_mark: | :white_check_mark: |        | The uuid of the characteristic                           |
| isValid              ⚡ | :white_check_mark: | :white_check_mark: |        | False once invalidated by a (re-)discovery or disconnect; ops throw    |
| properties           ⚡ | :white_check_mark: | :white_check_mark: |        | The characteristic's properties (read/write/notify/...)  |
| canRead              ⚡ | :white_check_mark: | :white_check_mark: |        | Whether `read` is supported                              |
| canWrite             ⚡ | :white_check_mark: | :white_check_mark: |        | Whether `write` is supported (with or without response)  |
| canNotify            ⚡ | :white_check_mark: | :white_check_mark: |        | Whether notifications are supported (notify or indicate) |
| read                   | :white_check_mark: | :white_check_mark: | :fire: | Retrieves the value of the characteristic                |
| write                  | :white_check_mark: | :white_check_mark: | :fire: | Writes the value of the characteristic                   |
| notifications       🌀 | :white_check_mark: | :white_check_mark: | :fire: | Notify/indicate values; enables notify while listened    |
| notificationsPassive🌀 | :white_check_mark: | :white_check_mark: |        | Notify/indicate values *without* enabling notify         |
| values              🌀 | :white_check_mark: | :white_check_mark: | :fire: | `notifications` + `read()` results; enables notify        |
| valuesPassive       🌀 | :white_check_mark: | :white_check_mark: |        | `values` *without* enabling notify                       |
| subscribe              | :white_check_mark: | :white_check_mark: | :fire: | Enable notify & keep it on until `unsubscribe()`         |
| cccd                 ⚡ | :white_check_mark: | :white_check_mark: |        | The CCCD descriptor, if the characteristic has one       |

### BluetoothDescriptor API

|         |      Android       |        iOS         | Throws | Description                           |
| :------ | :----------------: | :----------------: | :----: | :-------------------------------------|
| uuid    ⚡ | :white_check_mark: | :white_check_mark: |        | The uuid of the descriptor            |
| isValid ⚡ | :white_check_mark: | :white_check_mark: |        | False once invalidated by re-discovery or disconnect |
| read    | :white_check_mark: | :white_check_mark: | :fire: | Retrieves the value of the descriptor |
| write   | :white_check_mark: | :white_check_mark: | :fire: | Writes the value of the descriptor    |

## Common Problems

Many common problems are easily solved.

Adapter:
- [bluetooth must be turned on](#bluetooth-must-be-turned-on)
- [adapterState is not 'on' but my Bluetooth is on](#adapterstate-is-not-on-but-my-bluetooth-is-on)
- [adapterState is called multiple times](#adapterstate-is-called-multiple-times)

Scanning:
- [Scanning does not find my device](#scanning-does-not-find-my-device)
- [Scanned device never goes away](#scanned-device-never-goes-away)
- [iBeacons not showing](#ibeacons-not-showing)

Connecting:
- [Connection fails](#connection-fails)
- [connectionState is called multiple times](#connectionstate-is-called-multiple-times)
- [remoteId is different on Android vs iOS](#the-remoteid-is-different-on-android-versus-ios--macos)
- [iOS: "[Error] The connection has timed out unexpectedly."](#ios-error-the-connection-has-timed-out-unexpectedly)

Reading & Writing:
- [List of Bluetooth GATT Errors](#list-of-bluetooth-gatt-errors)
- [Characteristic write fails](#characteristic-write-fails)
- [Characteristic read fails](#characteristic-read-fails)

Subscriptions:
- [notifications are never received](#notifications-are-never-received)
- [notification data is split up](#notification-data-is-split-up)
- [notifications arrive with duplicate data](#notifications-arrive-with-duplicate-data)

Android Errors:
- [ANDROID_SPECIFIC_ERROR](#android_specific_error)
- [android pairing popup appears twice](#android-pairing-popup-appears-twice)

Flutter Errors:
- [MissingPluginException(No implementation found for method XXXX ...)](#missingpluginexceptionno-implementation-found-for-method-xxxx-)

---

### "bluetooth must be turned on"

You need to wait for the bluetooth adapter to fully turn on.

`await Bluebird.adapterReady();`

This returns as soon as the adapter is on (immediately if it already is) and throws
if it is unavailable/unauthorized. You can also observe it yourself via
`Bluebird.adapterState.listen(...)`. See [Usage](#usage).

---

### adapterState is not 'on' but my Bluetooth is on

**For iOS:**

`adapterState` always starts as `unknown`. Wait for the service to report a real state:

```dart
await Bluebird.adapterState.firstWhere((state) => state != BluetoothAdapterState.unknown);
```

If `adapterState` is `unavailable`, you must add access to Bluetooth Hardware in the app's Xcode settings. See [Getting Started](#getting-started).

**For Android:**

Check that your device supports Bluetooth & has permissions.

---

### adapterState is called multiple times

You are forgetting to cancel the original `Bluebird.adapterState.listen` resulting in multiple listeners.

```dart
// tip: using ??= makes it easy to only make new listener when currently null
final subscription ??= Bluebird.adapterState.listen((value) {
    // ...
});

// also, make sure you cancel the subscription when done!
subscription.cancel()
```

---

### Scanning does not find my device

**1. you're using an emulator**

Use a physical device.

**2. try using another ble scanner app**

* **iOS**: [nRF Connect](https://apps.apple.com/us/app/nrf-connect-for-mobile/id1054362403)
* **Android**: [BLE Scanner](https://play.google.com/store/apps/details?id=com.macdom.ble.blescanner)

Install a BLE scanner app on your phone. Can it find your device?

**3. your device uses bluetooth classic, not BLE.**

Headphones, speakers, keyboards, mice, gamepads, & printers all use Bluetooth Classic.

These devices may be found in System Settings, but they cannot be connected to by Bluebird. Bluebird only supports Bluetooth Low Energy.

**4. your device stopped advertising.**

- you might need to reboot your device
- you might need to put your device in "discovery mode"
- your phone may have already connected automatically
- another app may have already connected to your device
- another phone may have already connected to your device

Try looking through system devices:

```dart
// search system devices. i.e. any device connected to by *any* app
List<BluetoothDevice> system = await Bluebird.systemDevices([]);
for (var d in system) {
    print('${d.platformName} already connected to! ${d.remoteId}');
    if (d.platformName == "myBleDevice") {
         await d.connect(); // must connect our app
    }
}
```

**5. your scan filters are wrong.**

- try removing all scan filters
- for `withServices` to work, your device must actively advertise the serviceUUIDs it supports

**6. Android: you're scanning too often**

On Android you can only start a scan 5 times per 30 second period. This is a platform restriction.

---

### Scanned device never goes away

This is expected.

Use `.accumulate(removeIfGone: ...)` if you want a device to drop out of the list once it stops advertising.

---

### iBeacons Not Showing

**iOS:**

iOS does not support iBeacons using CoreBluetooth. You must find a plugin meant for CoreLocation.

**Android:**

1. you need to enable location permissions, see [Getting Started](#getting-started)
2. you must pass `androidUsesFineLocation:true` to `Bluebird.startScan()`.

---

### Connection fails

**1. Your ble device have low battery**

Bluetooth can become erratic when your peripheral device is low on battery.

**2. Your ble device may have refused the connection or have a bug**

Connection is a two-way process. Your ble device may be misconfigured.

**3. You may be on the edge of the Bluetooth range.**

The signal is too weak, or there are a lot of devices causing radio interference.

**4. Some phones have an issue connecting while scanning.**

The Huawei P8 Lite is one of the reported phones to have this issue. Try stopping your scanner before connecting.

**5. Try restarting your phone**

Bluetooth is a complicated system service, and can enter a bad state.

---

### connectionState is called multiple times

You are forgetting to cancel the original `device.connectionState.listen` resulting in multiple listeners.

```dart
// tip: using ??= makes it easy to only make new listener when currently null
final subscription ??= device.connectionState.listen((value) {
    // ...
});

// also, make sure you cancel the subscription when done!
subscription.cancel()
```

---

### The remoteId is different on Android versus iOS & macOS

This is expected. There is no way to avoid it.

For privacy, iOS & macOS use a randomly generated uuid. This uuid will periodically change.

e.g. `6920a902-ba0e-4a13-a35f-6bc91161c517`

Android uses the mac address of the bluetooth device. It never changes.

e.g. `05:A4:22:31:F7:ED`

---

### iOS: "[Error] The connection has timed out unexpectedly."

You can google this error. It is a common iOS ble error code.

It means your device stopped working. Bluebird cannot fix it.

---

### List of Bluetooth GATT Errors

These GATT error codes are part of the BLE Specification.

**These are *responses* from your ble device because you are sending an invalid request.**

Bluebird cannot fix these errors. You are doing something wrong & your device is responding with an error.

**GATT errors as they appear on iOS**:
```
apple-code: 1  | The handle is invalid.
apple-code: 2  | Reading is not permitted.
apple-code: 3  | Writing is not permitted.
apple-code: 4  | The command is invalid.
apple-code: 6  | The request is not supported.
apple-code: 7  | The offset is invalid.
apple-code: 8  | Authorization is insufficient.
apple-code: 9  | The prepare queue is full.
apple-code: 10 | The attribute could not be found.
apple-code: 11 | The attribute is not long.
apple-code: 12 | The encryption key size is insufficient.
apple-code: 13 | The value's length is invalid.
apple-code: 14 | Unlikely error.
apple-code: 15 | Encryption is insufficient.
apple-code: 16 | The group type is unsupported.
apple-code: 17 | Resources are insufficient.
apple-code: 18 | Unknown ATT error.
```

**GATT errors as they appear on Android**:
```
android-code: 1  | GATT_INVALID_HANDLE
android-code: 2  | GATT_READ_NOT_PERMITTED
android-code: 3  | GATT_WRITE_NOT_PERMITTED
android-code: 4  | GATT_INVALID_PDU
android-code: 5  | GATT_INSUFFICIENT_AUTHENTICATION
android-code: 6  | GATT_REQUEST_NOT_SUPPORTED
android-code: 7  | GATT_INVALID_OFFSET
android-code: 8  | GATT_INSUFFICIENT_AUTHORIZATION
android-code: 9  | GATT_PREPARE_QUEUE_FULL
android-code: 10 | GATT_ATTR_NOT_FOUND
android-code: 11 | GATT_ATTR_NOT_LONG
android-code: 12 | GATT_INSUFFICIENT_KEY_SIZE
android-code: 13 | GATT_INVALID_ATTRIBUTE_LENGTH
android-code: 14 | GATT_UNLIKELY
android-code: 15 | GATT_INSUFFICIENT_ENCRYPTION
android-code: 16 | GATT_UNSUPPORTED_GROUP
android-code: 17 | GATT_INSUFFICIENT_RESOURCES
```

**Descriptions**:
```
1   | Invalid Handle                 | The attribute handle given was not valid on this server.
2   | Read Not Permitted             | The attribute cannot be read.
3   | Write Not Permitted            | The attribute cannot be written.
4   | Invalid PDU                    | The attribute PDU was invalid.
5   | Insufficient Authentication    | The attribute requires authentication before it can be read or written.
6   | Request Not Supported          | Attribute server does not support the request received from the client.
7   | Invalid Offset                 | Offset specified was past the end of the attribute.
8   | Insufficient Authorization     | The attribute requires an authorization before it can be read or written.
9   | Prepare Queue Full             | Too many prepare writes have been queued.
10  | Attribute Not Found            | No attribute found within the given attribute handle range.
11  | Attribute Not Long             | The attribute cannot be read or written using the Read Blob or Write Blob requests.
12  | Insufficient Key Size          | The Encryption Key Size used for encrypting this link is insufficient.
13  | Invalid Attribute Value Length | The attribute value length is invalid for the operation.
14  | Unlikely Error                 | The request has encountered an unlikely error and cannot be completed.
15  | Insufficient Encryption        | The attribute requires encryption before it can be read or written.
16  | Unsupported Group Type         | The attribute type is not a supported grouping as defined by a higher layer.
17  | Insufficient Resources         | Insufficient Resources to complete the request.
```

---

### characteristic write fails

First, check the [List of Bluetooth GATT Errors](#list-of-bluetooth-gatt-errors) for your error.

**1. your bluetooth device turned off, or is out of range**

If your device turns off or crashes during a write, it will cause a failure.

**2. Your Bluetooth device has bugs**

Maybe your device crashed, or is not sending a response due to software bugs.

**3. there is radio interference**

Bluetooth is wireless and will not always work.

---

### Characteristic read fails

First, check the [List of Bluetooth GATT Errors](#list-of-bluetooth-gatt-errors) for your error.

**1. your bluetooth device turned off, or is out of range**

If your device turns off or crashes during a read, it will cause a failure.

**2. Your Bluetooth device has bugs**

Maybe your device crashed, or is not sending a response due to software bugs.

**3. there is radio interference**

Bluetooth is wireless and will not always work.

---

### notifications are never received

**1. you are not listening to the right stream**

`chr.notifications` emits only notify/indicate values. `chr.values` also includes
the result of `chr.read()`. Neither emits your own `chr.write()` calls.

**2. your device has nothing to send**

With notify/indicate, your _device_ chooses when to send data.

Try interacting with your device to get it to send new data.

**3. your device has bugs**

Try rebooting your ble device.

Some ble devices have buggy software and stop sending data

---

### notification data is split up

Verify that the mtu is large enough to hold your message.

```dart
device.mtu.value
```

If it still happens, it is a problem with your peripheral device.

---

### notifications arrive with duplicate data

You are probably listening to `chr.notifications` more than once. Because listening
enables notify on the peripheral, each active listener receives every value — hold a
single subscription (or use `subscribe()` + `notificationsPassive`).

```dart
final subscription = chr.notifications.listen((value) {
    // ...
});

// cancel when you are done (this also disables notify on the peripheral)
device.cancelWhenDisconnected(subscription);
```

---

### ANDROID_SPECIFIC_ERROR

There is no 100% solution.

Bluebird already has mitigations for this error, but Android will still fail with this code randomly.

The recommended solution is to `catch` the error, and retry.

---

### android pairing popup appears twice

This is a bug in android itself.

You can call `createBond()` yourself just after connecting and this will resolve the issue.

---

### MissingPluginException(No implementation found for method XXXX ...)

If you just added bluebird to your pubspec.yaml, a hot reload / hot restart is not enough.

You need to fully stop your app and run again so that the native plugins are loaded.

Also try `flutter clean`.







