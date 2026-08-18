## Unreleased

- Fix successful CCCD writes being reported as `KotlinNothingValueException`,
  which immediately rolled back notification routing and broke discovery.
- Queue concurrent write commands per connection inside the native plugin and
  advance the queue from Android's buffer-capacity callbacks.
- Serialize every callback-bearing GATT operation through one native per-device
  FIFO, preventing PHY/MTU/CCCD/read/write callback-slot collisions while
  preserving native write-command pipelining.
- Roll back local notification routing when enabling the peer CCCD fails.

## 0.4.1

- Fixed manufacturer specific data parsing when an advertisement carries more than one Manufacturer Specific Data (AD type `0xFF`) structure. Each structure is now attributed to its own company id; previously every structure was concatenated into one blob keyed by the first company id, so a later structure's company id leaked into the earlier structure's payload (e.g. a device advertising `0x0000` then `0x08FA` surfaced as `{ 0x0000: [.. FA 08 ..] }` instead of two separate entries). Multiple structures sharing a company id are still concatenated.

## 0.4.0

- Added L2CAP connection-oriented channel support (`BluetoothDevice.createL2capChannel`, Android 10 / API 29+).

## 0.3.0

- Regenerated for the `BluetoothConnectionState` `connecting` / `disconnecting` additions. Native behaviour is unchanged — Android still reports only connected / disconnected.

## 0.2.0

- Platform method-channel tracing now goes to `BluebirdPlatform.logger` (at `Level.FINEST`); `setLogLevel` no longer takes a `color` argument.
- Surface a peer's ATT Error Response as `attError` (with the raw ATT code), distinct from local GATT stack/link failures (`androidError`).

## 0.1.0

- Initial release.
