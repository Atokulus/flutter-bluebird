## 0.4.2

- Fixed (Web) a spurious `deviceDisconnected` when a device is disconnected and quickly reconnected: a delayed `gattserverdisconnected` event from the previous connection could tear down the new one. Requires `bluebird_web` 0.4.1.

## 0.4.1

- Fixed (Android) `AdvertisementData.manufacturerData` when an advertisement carries more than one manufacturer specific data structure. Each structure is now keyed by its own company id, instead of being merged into a single blob under the first company id (which leaked later structures' ids into the earlier payload). Requires `bluebird_android` 0.4.1.

## 0.4.0

- Added L2CAP connection-oriented channel support. `device.openL2capChannel(psm, secure: …)` returns a `BluetoothL2CapChannel` — a bidirectional byte stream to the peer (`input` / `write(...)` / `close()`), independent of GATT, on Android (API 29+) and iOS/macOS (unsupported on Web; `secure` is Android-only). Data flows over a dedicated binary channel with backpressure in both directions and does not pass through the global GATT operation queue, so its throughput neither gates nor is gated by characteristic I/O. The channel closes on its own when the peer closes it or the device disconnects.
- **Breaking:** `AdvertisementData.advName` is now `String?`. It is `null` when the advertisement carries no name, rather than being coerced to an empty string. `mergedWith` carries the prior name forward whenever `newer.advName` is `null`.

## 0.3.0

- **Breaking:** `BluetoothConnectionState` now has `connecting` and `disconnecting` in addition to `connected` / `disconnected`. They are synthesized on the Dart side around `device.connect()` / `disconnect()` (the platforms only report the terminal states), so `device.connectionState` drives a connecting/disconnecting spinner directly. `device.isDisconnected` is **removed** — it was ambiguous with the new transient states; use `!device.isConnected`, or `connectionState.value == BluetoothConnectionState.disconnected` for a fully-disconnected device.
- Added an optional `timeout` to `Bluebird.scan(...)`: the scan stops and the stream *completes normally* (not with an error) after the duration, so `Bluebird.scan(timeout: …).accumulate().last` yields the final device list. Also hardened the advertisement feed against add-after-close.

## 0.2.1

- Stopped re-exporting `Level` / `Logger` / `LogRecord` from `package:logging`, which collided with a consumer's own `package:logging` import (`unnecessary_import`). If you configure `Bluebird.logger` directly, add `package:logging` to your `pubspec.yaml`.

## 0.2.0

- **Breaking:** logging now flows through a single [`package:logging`](https://pub.dev/packages/logging) `Logger`, exposed as `Bluebird.logger` (with `Level`, `Logger`, and `LogRecord` re-exported). Nothing is printed by default — attach an `onRecord` listener, or call `Bluebird.configureLoggerPrinting()` for a console one-liner. The previous string log stream and default `print` output have been removed.
- **Breaking:** renamed `Bluebird.setLogLevel` to `setPlatformLogLevel` (and `logLevel` to `platformLogLevel`) and removed its `color` argument. It now sets only the native logcat / os_log verbosity; Dart-side output is filtered with `Bluebird.logger.level`. Records are path-scoped (`[remoteId][service][characteristic] …`), with platform-channel call tracing at `Level.FINEST`.
- **Breaking:** reworked error codes around ATT protocol errors. `BluebirdErrorCode.gattError`/`cbError` are replaced by `androidError`/`darwinError` (local stack or link failures) and `attError` (the peer answered with an ATT Error Response). A new `BluetoothAttException` — with `AttError` constants and `attError` — surfaces peer rejections with their raw one-octet code, uniformly across platforms.
- `characteristic.notifications` and `characteristic.values` are now broadcast streams: several listeners share one notify enable, and notify is released when the last idle listener (e.g. a mobx `ObservableStream` or `StreamBuilder`) cancels.
- Fixed Web/WASM compatibility: platform detection no longer pulls `dart:io` into the web build (it is now behind a conditional import), so the package is Web- and WASM-compatible.

## 0.1.0

- Initial release.
