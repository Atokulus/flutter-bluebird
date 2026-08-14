// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math' show min;

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'bluebird.dart';
import 'bluetooth_attribute.dart';
import 'bluetooth_characteristic.dart';
import 'bluetooth_descriptor.dart';
import 'bluetooth_events.dart';
import 'bluetooth_l2cap.dart';
import 'bluetooth_service.dart';
import 'bluetooth_utils.dart';
import 'utils.dart';

const int _mtuMax = 517;

class BluetoothDevice implements BluebirdLoggable {
  final String remoteId;

  final Mutex _operations = Mutex();
  final Mutex _disconnectOperations = Mutex();
  final Set<Future<void>> _concurrentWrites = {};

  Mutex get _operationMutex {
    Bluebird.markDeviceOperationStarted();
    return Bluebird.operationQueueMode == OperationQueueMode.global ? Mutex.global : _operations;
  }

  Mutex get _disconnectMutex {
    Bluebird.markDeviceOperationStarted();
    return Bluebird.operationQueueMode == OperationQueueMode.global ? Mutex.disconnect : _disconnectOperations;
  }

  bool get _serializePlatformCall => Bluebird.operationQueueMode == OperationQueueMode.global;

  @override
  String get logPath => "[$remoteId]";

  List<BluetoothService> _services = [];

  /// When the current set of services was discovered. Re-stamped on every
  /// (re-)discovery and on a services reset. Each discovered attribute captures
  /// the timestamp current when it was built; an attribute whose timestamp is no
  /// longer this one is from a superseded discovery and is treated as stale (see
  /// [BluetoothAttribute.isValid]).
  DateTime _discovery = DateTime.now();

  @internal
  DateTime get discoveryToken => _discovery;

  int? _mtu;
  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  DisconnectReason? _disconnectReason;
  DateTime? _connectTimestamp;
  BluetoothBondState? _bondState;
  BluetoothBondState? _prevBondState;

  String? _platformName;

  final List<StreamSubscription> _subscriptions = [];
  final List<StreamSubscription> _delayedSubscriptions = [];

  @internal
  BluetoothDevice({required this.remoteId});

  /// Create a device from an id
  ///   - to connect, this device must have been discovered by your app in a previous scan
  ///   - iOS uses 128-bit uuids the remoteId, e.g. e006b3a7-ef7b-4980-a668-1f8005f84383
  ///   - Android uses 48-bit mac addresses as the remoteId, e.g. 06:E5:28:3B:FD:E0
  factory BluetoothDevice.fromId(String address) => Bluebird.deviceForAddress(address);

  /// platform name
  /// - this name is kept track of by the platform
  /// - this name usually persist between app restarts
  /// - iOS: after you connect, iOS uses the GAP name characteristic (0x2A00)
  ///        if it exists. Otherwise iOS use the advertised name.
  /// - Android: always uses the advertised name
  String get platformName => _platformName ?? "";

  @internal
  set platformNameInternal(String? name) {
    _platformName = name ?? _platformName;
  }

  /// Get services
  ///  - returns empty if discoverServices() has not been called
  ///    or if your device does not have any services (rare)
  List<BluetoothService> get services => _services;

  void ensureConnected(String functionName) {
    if (isConnected) return;
    throw BluebirdException(functionName, BluebirdErrorCode.deviceDisconnected, "device is not connected");
  }

  /// [Bluebird.invoke] plus the device-scoped guards — connected pre-check,
  /// per-device serialization, disconnection watchdog — stating [name] once.
  ///   - [before] runs inside the serialization mutex, before the call.
  @internal
  Future<T> invoke<T>(
    String name,
    Future<T> Function(BluebirdPlatform p) call, {
    Duration? timeout,
    bool requiresConnection = true,
    bool serialized = true,
    bool concurrentWrite = false,
    Future<void> Function()? before,
  }) {
    Bluebird.markDeviceOperationStarted();
    if (requiresConnection) ensureConnected(name);
    Future<T> run() async {
      if (before != null) await before();
      var future = Bluebird.invoke(name, call, ensureAdapterIsOn: true, serializePlatformCall: _serializePlatformCall);
      if (requiresConnection) future = future.bluebirdEnsureDeviceIsConnected(this, name);
      if (timeout != null) future = future.bluebirdTimeout(timeout, name);
      return future;
    }

    if (!serialized) return run();

    final operationMutex = _operationMutex;
    if (concurrentWrite && Bluebird.operationQueueMode == OperationQueueMode.perDevice) {
      Future<T> startConcurrentWrite() async {
        late Future<T> operation;
        await operationMutex.protect(() {
          operation = run();
          final tracked = operation.then<void>((_) {}, onError: (_, _) {});
          _concurrentWrites.add(tracked);
          tracked.then((_) => _concurrentWrites.remove(tracked));
        });
        return operation;
      }

      return startConcurrentWrite();
    }

    return operationMutex.protect(() async {
      if (_concurrentWrites.isNotEmpty) {
        await Future.wait(_concurrentWrites.toList(growable: false));
      }
      return run();
    });
  }

  /// Register a subscription to be canceled when the device is disconnected.
  /// This function simplifies cleanup, so you can prevent creating duplicate stream subscriptions.
  ///   - this is an optional convenience function
  ///   - prevents accidentally creating duplicate subscriptions on each reconnection.
  ///   - [next] if true, the the stream will be canceled only on the *next* disconnection.
  ///     This is useful if you setup your subscriptions before you connect.
  ///   - [delayed] Note: This option is only meant for `connectionState` subscriptions.
  ///     When `true`, we cancel after a small delay. This ensures the `connectionState`
  ///     listener receives the `disconnected` event.
  void cancelWhenDisconnected(StreamSubscription subscription, {bool next = false, bool delayed = false}) {
    if (isConnected == false && next == false) {
      subscription.cancel(); // cancel immediately if already disconnected.
    } else if (delayed) {
      _delayedSubscriptions.add(subscription);
    } else {
      _subscriptions.add(subscription);
    }
  }

  /// Returns true if this device is currently connected to your app.
  bool get isConnected => _connectionState == BluetoothConnectionState.connected;

  void _emitConnectionState(BluetoothConnectionState state) {
    final event = OnConnectionStateChangedEvent(this, state, _disconnectReason);
    applyEvent(event);
    Bluebird.emitEvent(event);
  }

  /// Establishes a connection to the Bluetooth Device.
  ///   [timeout] if timeout occurs, cancel the connection request and throw exception
  ///   [mtu] Android only. Request a larger mtu right after connection, if set.
  Future<void> connect({Duration timeout = const Duration(seconds: 35), int? mtu = _mtuMax}) async {
    // make sure no one else is calling disconnect
    final disconnectMutex = _disconnectMutex;
    final operationMutex = _operationMutex;
    await disconnectMutex.take();
    bool disconnectReturned = false;

    // enter the `connecting` state up front (the platforms don't report it)
    _emitConnectionState(BluetoothConnectionState.connecting);

    try {
      await operationMutex.protect(() async {
        // record connection time
        if (System.isAndroid) _connectTimestamp = DateTime.now();

        try {
          final future = Bluebird.invoke(
            "connect",
            (p) => p.connect(remoteId),
            ensureAdapterIsOn: true,
            timeout: timeout,
            serializePlatformCall: _serializePlatformCall,
          );

          // we return the disconnect mutex now so that this
          // connection attempt can be canceled by calling disconnect
          disconnectMutex.give();
          disconnectReturned = true;

          await future;

          // the connect future completing means we are connected; update state
          // here rather than waiting for the BmConnectionStateEvent, which
          // travels on a separate channel and may be processed after we return
          _connectionState = BluetoothConnectionState.connected;
        } on BluebirdException catch (e) {
          if (e.code == BluebirdErrorCode.timeout) {
            await Bluebird.invoke(
              "disconnect",
              (p) => p.disconnect(remoteId),
              serializePlatformCall: _serializePlatformCall,
            );
          }
          rethrow;
        }
      });
    } catch (_) {
      // connect failed: the synthesized `connecting` never resolves on its own.
      // Android/darwin also emit a native disconnected event, but web does not —
      // so revert here (skipped if a native event already moved us on).
      if (_connectionState == BluetoothConnectionState.connecting) {
        _emitConnectionState(BluetoothConnectionState.disconnected);
      }
      rethrow;
    }

    if (!disconnectReturned) disconnectMutex.give();

    // request larger mtu
    if (System.isAndroid && isConnected && mtu != null) {
      await requestMtu(mtu);
    }
  }

  /// Cancels connection to the Bluetooth Device
  ///   - [queue] If true, this disconnect request will be executed after all other operations complete.
  ///     If false, this disconnect request will be executed right now, i.e. skipping to the front
  ///     of the bluebird operation queue, which is useful to cancel an in-progress connection attempt.
  ///   - [androidDelay] Android only. Minimum gap between connect and disconnect to
  ///     workaround a race condition that leaves connection stranded. A stranded connection in this case
  ///     refers to a connection that Bluebird and Android Bluetooth stack are not aware of and thus cannot be
  ///     disconnected because there is no gatt handle.
  ///     https://issuetracker.google.com/issues/37121040
  ///     From testing, 2 second delay appears to be enough.
  Future<void> disconnect({
    Duration timeout = const Duration(seconds: 35),
    bool queue = true,
    Duration androidDelay = const Duration(seconds: 2),
  }) async {
    // Only allow a single disconnect operation at a time
    final disconnectMutex = _disconnectMutex;
    final operationMutex = _operationMutex;
    await disconnectMutex.protect(() {
      Future<void> action() async {
        // enter the `disconnecting` state (the platforms don't report it); the
        // native `disconnected` event follows and moves us to disconnected
        if (_connectionState != BluetoothConnectionState.disconnected) {
          _emitConnectionState(BluetoothConnectionState.disconnecting);
        }

        // Workaround Android race condition
        await _ensureAndroidDisconnectionDelay(androidDelay);

        // invoke
        await Bluebird.invoke(
          "disconnect",
          (p) => p.disconnect(remoteId),
          ensureAdapterIsOn: true,
          timeout: timeout,
          serializePlatformCall: _serializePlatformCall,
        );

        if (System.isAndroid) {
          // Disconnected, remove connect timestamp
          _connectTimestamp = null;
        }
      }

      return queue ? operationMutex.protect(action) : action();
    });
  }

  /// Discover services, characteristics, and descriptors of the remote device
  ///   - [subscribeToServicesChanged] Android Only: If true, after discovering services we will subscribe
  ///     to the Services Changed Characteristic (0x2A05) used for the `device.onServicesReset` stream.
  ///     Note: this behavior happens automatically on iOS and cannot be disabled
  Future<List<BluetoothService>> discoverServices({
    bool subscribeToServicesChanged = true,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final discoveredAt = DateTime.now();
    final services = await invoke("discoverServices", (p) => p.discoverServices(remoteId), timeout: timeout);
    // Stamp this discovery so any previously discovered attributes become stale
    // (their identity can't be safely reused), then build the fresh tree under
    // the new timestamp.
    _discovery = discoveredAt;
    _services = BluetoothService.constructServices(this, services);

    // in order to match iOS behavior on all platforms,
    // we always listen to the Services Changed characteristic if it exists.
    if (subscribeToServicesChanged) {
      if (!System.isDarwin) {
        BluetoothCharacteristic? c = _servicesChangedCharacteristic;
        if (c != null && (c.properties.notify || c.properties.indicate)) {
          // keep the Services Changed indications on for the connection's lifetime
          await c.subscribe();
        }
      }
    }

    return _services;
  }

  /// The most recent disconnection reason
  DisconnectReason? get disconnectReason => _disconnectReason;

  /// The connection state *of our app* to the device, as a stream that also
  /// exposes the current value via `device.connectionState.value`.
  late final ValueStream<BluetoothConnectionState> connectionState = ValueStream(
    value: () => _connectionState,
    changes: () => Bluebird.extractEventStream<OnConnectionStateChangedEvent>(
      (e) => e.device == this,
    ).map((e) => e.connectionState),
  );

  /// The MTU size in bytes, as a stream that also exposes the current value:
  ///   - `device.mtu.value` reads the current MTU synchronously
  ///   - listening emits immediately, then again whenever the mtu changes
  ///
  /// Built once per device (the underlying change stream is cold until listened
  /// to), so `.value` is a cheap field read rather than rebuilding the chain.
  late final ValueStream<int> mtu = ValueStream(
    value: () => _mtu ?? 23,
    changes: () => Bluebird.extractEventStream<OnMtuChangedEvent>((e) => e.device == this).map((e) => e.mtu),
  );

  /// The maximum attribute length in bytes, derived from [mtu].
  /// Use `device.maxAttrLen.value` for the current value.
  late final ValueStream<int> maxAttrLen = mtu.map((m) => min(512, m - 3));

  /// Services Reset Stream
  ///  - uses the GAP Services Changed characteristic (0x2A05)
  ///  - you must re-call discoverServices() when services are reset
  Stream<void> get onServicesReset =>
      Bluebird.extractEventStream<OnServicesResetEvent>((e) => e.device == this).map((_) {});

  /// Read the RSSI of connected remote device
  Future<int> readRssi({Duration timeout = const Duration(seconds: 15)}) =>
      invoke("readRssi", (p) => p.readRssi(remoteId), timeout: timeout);

  /// Open an L2CAP connection-oriented channel to [psm] — a bidirectional byte
  /// stream to the peer, independent of GATT (Android & iOS/macOS only; not
  /// supported on Web).
  ///   - the device must be connected; the PSM is typically learned out-of-band
  ///     or from a GATT characteristic the peripheral exposes.
  ///   - [secure] (Android only) requires an authenticated + encrypted (bonded)
  ///     link for the channel — Android's `createL2capChannel` vs
  ///     `createInsecureL2capChannel`. Defaults to `false`: like iOS/macOS
  ///     (where this flag is ignored and channel security follows the PSM), the
  ///     channel then uses whatever security the link already has rather than
  ///     demanding encryption. Set `true` only if the peer's PSM requires it —
  ///     a mismatch surfaces as a "Client security clearance failed" connect
  ///     error. Requires Android 10 (API 29).
  ///   - the returned [BluetoothL2CapChannel] carries data on a dedicated transport that
  ///     bypasses the global operation queue (see [BluetoothL2CapChannel]).
  Future<BluetoothL2CapChannel> openL2capChannel(
    int psm, {
    bool secure = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    ensurePlatform(System.isAndroid || System.isDarwin, "openL2capChannel");
    final channelId = await invoke(
      "openL2capChannel",
      (p) => p.openL2capChannel(remoteId, psm, secure),
      timeout: timeout,
    );
    final channel = BluetoothL2CapChannel(device: this, psm: psm, channelId: channelId);
    Bluebird.registerL2cap(channel);
    return channel;
  }

  /// Request to change MTU (Android Only)
  ///  - returns new MTU
  ///  - [predelay] adds delay to avoid a race condition on some peripherals:
  ///    peripherals that push an unsolicited MTU update right after connection
  ///    can confuse an immediate `requestMtu`, making it return too early and
  ///    breaking a subsequent `discoverServices`. The delay lets the automatic
  ///    update land first. Set to zero if your peripheral doesn't do this.
  Future<int> requestMtu(
    int desiredMtu, {
    Duration predelay = const Duration(milliseconds: 350),
    Duration timeout = const Duration(seconds: 15),
  }) {
    ensurePlatform(System.isAndroid, "requestMtu");
    return invoke(
      "requestMtu",
      (p) => p.requestMtu(remoteId, desiredMtu),
      timeout: timeout,
      before: () => Future.delayed(predelay),
    );
  }

  /// Request connection priority update (Android only)
  Future<void> requestConnectionPriority({
    required ConnectionPriority connectionPriorityRequest,
    Duration timeout = const Duration(seconds: 3),
  }) {
    ensurePlatform(System.isAndroid, "requestConnectionPriority");
    return invoke(
      "requestConnectionPriority",
      (p) => p.requestConnectionPriority(remoteId, connectionPriorityRequest),
      timeout: timeout,
      serialized: false,
    );
  }

  /// Set the preferred connection (Android Only)
  ///   - [txPhy] the set of allowed phys for Tx, e.g. {Phy.le2m, Phy.leCoded}
  ///   - [rxPhy] the set of allowed phys for Rx, e.g. {Phy.le2m, Phy.leCoded}
  ///   - [option] preferred coding to use when transmitting on Phy.leCoded
  /// Please note that this is just a recommendation given to the system.
  Future<void> setPreferredPhy({
    required Set<Phy> txPhy,
    required Set<Phy> rxPhy,
    required PhyCoding option,
    Duration timeout = const Duration(seconds: 3),
  }) {
    ensurePlatform(System.isAndroid, "setPreferredPhy");
    return invoke(
      "setPreferredPhy",
      (p) => p.setPreferredPhy(remoteId, Phy.maskFrom(txPhy), Phy.maskFrom(rxPhy), option.index),
      timeout: timeout,
      serialized: false,
    );
  }

  /// Force the bonding popup to show now (Android Only)
  /// Note! calling this is usually not necessary!! The platform does it automatically.
  Future<void> createBond({Uint8List? pin, Duration timeout = const Duration(seconds: 90)}) async {
    ensurePlatform(System.isAndroid, "createBond");
    final bonded = await invoke("createBond", (p) => p.createBond(remoteId, pin), timeout: timeout);
    if (!bonded) {
      throw BluebirdException("createBond", BluebirdErrorCode.bondFailed, "Failed to create bond");
    }
  }

  /// Remove bond (Android Only)
  Future<void> removeBond({Duration timeout = const Duration(seconds: 30)}) async {
    ensurePlatform(System.isAndroid, "removeBond");
    final removed = await invoke(
      "removeBond",
      (p) => p.removeBond(remoteId),
      timeout: timeout,
      requiresConnection: false,
    );
    if (!removed) {
      throw BluebirdException("removeBond", BluebirdErrorCode.removeBondFailed, "Failed to remove bond");
    }
  }

  /// Refresh ble services & characteristics (Android Only)
  Future<void> clearGattCache() {
    ensurePlatform(System.isAndroid, "clearGattCache");
    return invoke("clearGattCache", (p) => p.clearGattCache(remoteId), serialized: false);
  }

  /// The bond state of the device (Android Only), as a stream that also exposes
  /// the current value via `await device.bondState.value`.
  ///   - the platform reports bond state only on demand (events fire on
  ///     *changes*), so the current value is fetched the first time it is needed.
  late final AsyncValueStream<BluetoothBondState> bondState = AsyncValueStream(
    value: _fetchBondState,
    changes: () => Bluebird.extractEventStream<OnBondStateChangedEvent>((m) => m.device == this).map((e) => e.state),
  );

  /// Returns the current bond state, fetching it from the platform the first
  /// time it is needed (Android Only).
  Future<BluetoothBondState> _fetchBondState() async {
    ensurePlatform(System.isAndroid, "bondState");
    _bondState ??= await invoke(
      "getBondState",
      (p) => p.getBondState(remoteId),
      requiresConnection: false,
      serialized: false,
    );
    return _bondState!;
  }

  /// Get the previous bondState of the device (Android Only)
  BluetoothBondState? get prevBondState => _prevBondState;

  /// Get the GATT service (0x1801)
  BluetoothService? get _gattService => _services.where((s) => s.uuid == Uuids.service.genericAttribute).firstOrNull;

  /// Get the Services Changed characteristic (0x2A05)
  BluetoothCharacteristic? get _servicesChangedCharacteristic =>
      _gattService?.characteristics.where((chr) => chr.uuid == Uuids.characteristic.serviceChanged).firstOrNull;

  /// Workaround race condition between connect and disconnect.
  /// The bug: If you call disconnect right as android is establishing a connection
  /// android may still connect to the device. Worse, "onConnectionStateChange" will not be called
  /// so Bluebird will have no idea this connection is active. Adding a delay fixes this issue.
  /// https://issuetracker.google.com/issues/37121040
  Future<void> _ensureAndroidDisconnectionDelay(Duration minGap) async {
    if (!System.isAndroid) return;
    if (_connectTimestamp == null) return;
    Duration elapsed = DateTime.now().difference(_connectTimestamp!);
    if (elapsed.compareTo(minGap) < 0) {
      Duration timeLeft = minGap - elapsed;
      logger.fine("Enforcing disconnect gap: min=${minGap.inMilliseconds}ms delay=${timeLeft.inMilliseconds}ms");
      await Future<void>.delayed(timeLeft);
    }
  }

  @internal
  void applyEvent(BluebirdDeviceEvent event) {
    switch (event) {
      case OnCharacteristicValueEvent():
        break;
      case OnConnectionStateChangedEvent():
        _connectionState = event.connectionState;

        if (event.connectionState == BluetoothConnectionState.disconnected) {
          _disconnectReason = event.disconnectReason;

          // clear mtu
          _mtu = null;

          // cancel & delete subscriptions
          for (final s in _subscriptions) {
            s.cancel();
          }
          _subscriptions.clear();

          // cancel delayed subscriptions after the disconnected event has been
          // delivered to their streams
          if (_delayedSubscriptions.isNotEmpty) {
            final delayed = List.of(_delayedSubscriptions);
            _delayedSubscriptions.clear();
            Future.delayed(Duration.zero).then((_) {
              for (final s in delayed) {
                s.cancel();
              }
            });
          }

          // A disconnect invalidates the whole GATT tree — the handles are only
          // valid within a connection. Clear `_services` and bump the discovery
          // generation, so `device.services` is empty and any still-held attribute
          // reports as stale (its ops then surface "device is not connected"; see
          // BluetoothAttribute.requireValid) until the next discoverServices().
          _services = [];
          _discovery = DateTime.now();
        }

      case OnMtuChangedEvent():
        _mtu = event.mtu;

      case OnNameChangedEvent():
        if (System.isDarwin) {
          // iOS & macOS internally use the name changed callback for the platform name
          _platformName = event.name;
        }

      case OnServicesResetEvent():
        // The GATT layout may have changed. Re-stamp the discovery so every
        // previously discovered attribute becomes stale, and require a fresh
        // discoverServices() before anything can be used again.
        _discovery = DateTime.now();
        _services = [];

      case OnBondStateChangedEvent():
        _prevBondState = event.prevState;
        _bondState = event.state;
    }
  }

  /// The last known bond state, read synchronously (null if never observed).
  /// Used by [Bluebird] to resolve the previous state on a bond-state event.
  @internal
  BluetoothBondState? get currentBondState => _bondState;

  //
  // Attribute lookup by typed ref
  //

  T? _attributeForId<T extends BluetoothAttribute>(List<T> list, BmAttributeId id) {
    final wanted = BluetoothAttributeId.fromBm(id);
    return list.where((a) => a.id == wanted).firstOrNull;
  }

  /// Resolves a characteristic by its platform ref, or null if it cannot be
  /// resolved (e.g. services not discovered).
  @internal
  BluetoothCharacteristic? characteristicForRefOrNull(BmCharacteristicRef ref) {
    final service = _attributeForId(_services, ref.service.service);
    if (service == null) return null;
    return _attributeForId(service.characteristics, ref.characteristic);
  }

  @internal
  BluetoothCharacteristic characteristicForRef(BmCharacteristicRef ref) {
    final characteristic = characteristicForRefOrNull(ref);
    if (characteristic == null) {
      throw BluebirdException(
        "characteristicForRef",
        BluebirdErrorCode.characteristicNotFound,
        "characteristic not found: ${ref.service.service.uuid}/${ref.characteristic.uuid}",
      );
    }
    return characteristic;
  }

  @internal
  BluetoothDescriptor descriptorForRef(BmDescriptorRef ref) {
    final characteristic = characteristicForRef(ref.characteristic);
    final descriptor = _attributeForId(characteristic.descriptors, ref.id);
    if (descriptor == null) {
      throw BluebirdException(
        "descriptorForRef",
        BluebirdErrorCode.characteristicNotFound,
        "descriptor not found: ${ref.id.uuid}",
      );
    }
    return descriptor;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BluetoothDevice && runtimeType == other.runtimeType && remoteId == other.remoteId);

  @override
  int get hashCode => remoteId.hashCode;

  @override
  String toString() =>
      'BluetoothDevice{'
      'remoteId: $remoteId, '
      'platformName: $platformName, '
      'services: $_services'
      '}';
}
