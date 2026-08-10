// Pigeon schema for the bluebird platform channel protocol.
//
// This is the single source of truth for all messages exchanged between the
// Dart platform interface and the native (Kotlin/Swift) implementations.
// Regenerate with: tool/generate.sh

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: '../bluebird_android/android/src/main/kotlin/com/lib/bluebird/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.lib.bluebird'),
    swiftOut: '../bluebird_darwin/darwin/bluebird_darwin/Sources/bluebird_darwin/Messages.g.swift',
    dartPackageName: 'bluebird',
  ),
)
// ─────────────────────────────────────────────────────────────────────────────
// Enums
// ─────────────────────────────────────────────────────────────────────────────
enum BluetoothAdapterState { unknown, unavailable, unauthorized, turningOn, on, turningOff, off }

// `connecting` and `disconnecting` are synthesized on the Dart side (around
// device.connect()/disconnect()); the natives only ever emit `connected` /
// `disconnected`. Appended (not reordered) so the existing wire indices for
// `disconnected` (0) and `connected` (1) are preserved.
enum BluetoothConnectionState { disconnected, connected, connecting, disconnecting }

enum BmWriteType { withResponse, withoutResponse }

enum ConnectionPriority { balanced, high, lowPower }

enum BluetoothBondState { none, bonding, bonded }

enum LogLevel { none, error, warning, info, debug, verbose }

/// Single source of truth for error codes, shared by every platform.
///
/// Errors cross the channel as `PlatformException.code` *strings* (pigeon
/// cannot type that field), so the wire form of each code is, by convention,
/// the snake_case of its name here (e.g. [BluebirdErrorCode.deviceDisconnected]
/// crosses as `"device_disconnected"`). Each language has a small `wire`
/// helper implementing that convention; never hand-write a code string.
enum BluebirdErrorCode {
  success,
  timeout,
  platform,
  serviceNotFound,
  characteristicNotFound,
  userRejected,
  removeBondFailed,
  // codes emitted by the native implementations:
  /// An Android-side GATT stack/link failure — e.g. a `BluetoothGatt` call
  /// returned false/null, an HCI disconnect, or `GATT_FAILURE`. Not a peer
  /// response; see [attError]. The darwin analogue is [darwinError].
  androidError,

  /// A darwin-side (CoreBluetooth) stack/link failure — a non-`CBATTErrorDomain`
  /// `NSError` (e.g. connection lost). Not a peer response; see [attError]. The
  /// android analogue is [androidError].
  darwinError,

  /// A Bluetooth spec-level error: the peer answered a request with an ATT
  /// Error Response. Raised uniformly by every platform, with the raw one-octet
  /// code (an `int`, spanning the core ATT / application / GATT common ranges)
  /// riding along as the error details. Platform/link failures that are *not*
  /// peer responses stay [androidError] / [darwinError].
  attError,
  deviceDisconnected,
  adapterOff,
  notConnected,
  invalidIdentifier,
  bondFailed,
  userCanceled,
  unsupported,
  operationInProgress,
  permissionDenied,
  invalidArgument,
}

// ─────────────────────────────────────────────────────────────────────────────
// Attribute references
//
// A GATT attribute is addressed by its uuid plus a platform-opaque instance
// token that disambiguates duplicate uuids (Android: instanceId, darwin:
// object pointer). Refs compose hierarchically instead of the legacy
// "uuid:instance/uuid:instance" path strings.
// ─────────────────────────────────────────────────────────────────────────────

/// The universal uuid:instance pair identifying one attribute.
class BmAttributeId {
  late String uuid;

  /// Platform-opaque token disambiguating duplicate uuids.
  late int instance;
}

class BmServiceRef {
  late BmAttributeId service;

  /// Set when this is a secondary (included) service.
  BmAttributeId? parentService;
}

class BmCharacteristicRef {
  late BmServiceRef service;
  late BmAttributeId characteristic;
}

class BmDescriptorRef {
  late BmCharacteristicRef characteristic;

  /// Descriptors are uuid-unique within a characteristic, so [id]'s instance is
  /// always 0; the [BmAttributeId] keeps descriptors uniform with services and
  /// characteristics.
  late BmAttributeId id;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scanning
// ─────────────────────────────────────────────────────────────────────────────

class BmMsdFilter {
  late int manufacturerId;
  Uint8List? data;
  Uint8List? mask;
}

class BmServiceDataFilter {
  late String service;
  late Uint8List data;
  Uint8List? mask;
}

class BmScanSettings {
  late List<String> withServices;
  late List<String> withRemoteIds;
  late List<String> withNames;
  late List<String> withKeywords;
  late List<BmMsdFilter> withMsd;
  late List<BmServiceDataFilter> withServiceData;
  late bool continuousUpdates;
  late int continuousDivisor;
  late bool androidLegacy;
  late int androidScanMode;
  late bool androidUsesFineLocation;
  late List<String> webOptionalServices;
}

class BmScanAdvertisement {
  late String address;
  String? platformName;
  String? advName;
  late bool connectable;
  int? txPowerLevel;

  /// Not supported on iOS / macOS.
  int? appearance;
  late Map<int, Uint8List> manufacturerData;
  late Map<String, Uint8List> serviceData;
  late List<String> serviceUuids;
  late int rssi;
}

// ─────────────────────────────────────────────────────────────────────────────
// Devices and the GATT tree
// ─────────────────────────────────────────────────────────────────────────────

class BmBluetoothDevice {
  late String address;
  String? platformName;
}

class BmBluetoothService {
  late BmAttributeId id;
  late bool isPrimary;
  late List<BmBluetoothCharacteristic> characteristics;
  late List<BmServiceRef> includedServices;
}

class BmBluetoothCharacteristic {
  late BmAttributeId id;
  late List<BmBluetoothDescriptor> descriptors;
  late BmCharacteristicProperties properties;
}

class BmBluetoothDescriptor {
  late BmAttributeId id;
}

class BmCharacteristicProperties {
  late bool broadcast;
  late bool read;
  late bool writeWithoutResponse;
  late bool write;
  late bool notify;
  late bool indicate;
  late bool authenticatedSignedWrites;
  late bool extendedProperties;
  late bool notifyEncryptionRequired;
  late bool indicateEncryptionRequired;
}

class BmPhySupport {
  /// High speed (PHY 2M)
  late bool le2M;

  /// Long range (PHY codec)
  late bool leCoded;
}

// ─────────────────────────────────────────────────────────────────────────────
// Events (native → Dart, unsolicited)
// ─────────────────────────────────────────────────────────────────────────────

sealed class BmEvent {}

class BmAdapterStateEvent extends BmEvent {
  late BluetoothAdapterState adapterState;
}

class BmScanAdvertisementEvent extends BmEvent {
  late BmScanAdvertisement advertisement;
}

class BmScanFailedEvent extends BmEvent {
  late int errorCode;
  late String errorString;
}

class BmConnectionStateEvent extends BmEvent {
  late String address;
  late BluetoothConnectionState connectionState;
  int? disconnectReasonCode;
  String? disconnectReasonString;
}

/// A characteristic value received via notify/indicate. Read responses are
/// returned from [BluebirdHostApi.readCharacteristic] instead.
class BmCharacteristicNotificationEvent extends BmEvent {
  late String address;
  late BmCharacteristicRef characteristic;
  late Uint8List value;
}

class BmBondStateEvent extends BmEvent {
  late String address;
  late BluetoothBondState bondState;
  BluetoothBondState? prevState;
}

class BmNameChangedEvent extends BmEvent {
  late String address;
  late String name;
}

class BmServicesResetEvent extends BmEvent {
  late String address;
}

/// Emitted on any MTU change: solicited (requestMtu) or peer-initiated on
/// Android; on darwin, emitted after connect and whenever the negotiated
/// value changes (CoreBluetooth has no MTU callback, so the plugin polls
/// while devices are connected).
class BmMtuChangedEvent extends BmEvent {
  late String address;
  late int mtu;
}

class BmDetachedFromEngineEvent extends BmEvent {
  /// Carries no information — pigeon requires data classes to have a field.
  bool? unused;
}

/// An L2CAP connection-oriented channel closed *unsolicited* — the peer closed
/// it, the device disconnected, or a read/write failed. A successful open is
/// reported by [BluebirdHostApi.openL2capChannel]'s return value, and a
/// [closeL2capChannel] the app requested itself is confirmed by that call
/// completing, so neither emits this event. Channel *data* never crosses here:
/// it flows on the dedicated `bluebird/l2cap` binary channel (see
/// [BluebirdHostApi.openL2capChannel]).
class BmL2capChannelClosedEvent extends BmEvent {
  late int channelId;
  late String address;

  /// Wire error code (snake_case of a [BluebirdErrorCode]) when the close was
  /// caused by a failure; null for a clean peer/EOF close.
  String? errorCode;
  String? errorString;
}

@EventChannelApi()
abstract class BluebirdEventChannelApi {
  BmEvent nativeEvents();
}

// ─────────────────────────────────────────────────────────────────────────────
// Host API (Dart → native)
//
// Error contract: natives reject with stable string codes — "android_error",
// "darwin_error", "att_error", "device_disconnected", "adapter_off", "not_connected",
// "invalid_identifier", "bond_failed", "user_canceled", "unsupported",
// "operation_in_progress" — human message, and the raw native status int as
// details.
// ─────────────────────────────────────────────────────────────────────────────

@HostApi()
abstract class BluebirdHostApi {
  // lifecycle / adapter
  /// Hot-restart handshake: disconnects and closes everything, returns the
  /// number of devices still closing.
  int flutterRestart();
  int connectedCount();
  void setLogLevel(LogLevel level);
  void setOptions(bool showPowerAlert, bool restoreState);
  bool isSupported();

  /// @async: may need to request runtime permissions before answering.
  @async
  String getAdapterName();
  BluetoothAdapterState getAdapterState();

  /// Android: shows the enable-bluetooth dialog; completes with user consent.
  @async
  bool turnOn();
  @async
  bool turnOff();

  // scanning — startScan completes once the scan is running (it may first
  // need to request runtime permissions); advertisements/errors arrive on the
  // event stream
  @async
  void startScan(BmScanSettings settings);
  void stopScan();
  @async
  List<BmBluetoothDevice> getSystemDevices(List<String> withServices);
  @async
  List<BmBluetoothDevice> getBondedDevices();

  // connection
  @async
  void connect(String address);
  @async
  void disconnect(String address);
  @async
  List<BmBluetoothService> discoverServices(String address);

  // GATT operations
  @async
  Uint8List readCharacteristic(String address, BmCharacteristicRef characteristic);
  @async
  void writeCharacteristic(
    String address,
    BmCharacteristicRef characteristic,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  );
  @async
  Uint8List readDescriptor(String address, BmDescriptorRef descriptor);
  @async
  void writeDescriptor(String address, BmDescriptorRef descriptor, Uint8List value);

  /// Completes after the CCCD write confirms (or immediately if no CCCD).
  @async
  bool setNotifyValue(String address, BmCharacteristicRef characteristic, bool enable);

  @async
  int requestMtu(String address, int mtu);
  @async
  int readRssi(String address);

  // android-only extras
  void requestConnectionPriority(String address, ConnectionPriority connectionPriority);
  BmPhySupport getPhySupport();
  @async
  void setPreferredPhy(String address, int txPhy, int rxPhy, int phyOptions);

  // bonding (android)
  BluetoothBondState getBondState(String address);
  @async
  bool createBond(String address, Uint8List? pin);
  @async
  bool removeBond(String address);
  @async
  void clearGattCache(String address);

  // L2CAP connection-oriented channels
  //
  // Control plane only. `openL2capChannel` completes once the channel is open
  // and returns a native-assigned channelId; `closeL2capChannel` tears it down.
  // Channel *data* does NOT cross the pigeon channels — it flows both ways on a
  // dedicated binary `BasicMessageChannel` named "bluebird/l2cap", framed as
  // `[channelId: int64 big-endian][type: uint8][payload]` with:
  //   type 0 = data     (either direction; reply gates flow control)
  //   type 1 = ready    (Dart→native: the app has wired its handler for
  //                      channelId, so the native side may start forwarding
  //                      inbound bytes — avoids racing this call's return)
  // Each message's reply is the backpressure signal: native replies to an
  // outbound-data frame once the bytes were accepted by the socket, and Dart
  // replies to an inbound-data frame once it has taken them, which flow-controls
  // the peer. Unsolicited closes arrive as [BmL2capChannelClosedEvent].
  //
  // [secure] selects Android's secure vs. insecure channel; ignored on darwin
  // (CoreBluetooth derives channel security from the PSM). Android requires
  // API 29+.
  @async
  int openL2capChannel(String address, int psm, bool secure);
  @async
  void closeL2capChannel(int channelId);
}
