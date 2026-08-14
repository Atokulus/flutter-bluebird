## Unreleased

- Drain queued write commands until CoreBluetooth reports
  `canSendWriteWithoutResponse == false`, then continue from its readiness
  callback. This allows several frames per connection event without drops.

## 0.4.0

- Added L2CAP connection-oriented channel support (CoreBluetooth `openL2CAPChannel`).

## 0.3.0

- Regenerated for the `BluetoothConnectionState` `connecting` / `disconnecting` additions. Native behaviour is unchanged — CoreBluetooth still reports only connected / disconnected.

## 0.2.1

- Writes without response now wait for CoreBluetooth's flow control (`canSendWriteWithoutResponse`) to open before enqueuing, instead of failing with a "you must slow down" error. `write(withoutResponse: true)` applies backpressure and resolves once the stack accepts the bytes, matching the Android and web behaviour.

## 0.2.0

- Platform method-channel tracing now goes to `BluebirdPlatform.logger` (at `Level.FINEST`); `setLogLevel` no longer takes a `color` argument.
- Surface a peer's ATT Error Response (`CBATTErrorDomain`) as `attError` (with the raw ATT code), distinct from other CoreBluetooth failures (`darwinError`).

## 0.1.0

- Initial release.
