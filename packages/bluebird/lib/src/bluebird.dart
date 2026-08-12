// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import 'bluetooth_attribute.dart';
import 'bluetooth_device.dart';
import 'bluetooth_events.dart';
import 'bluetooth_l2cap.dart';
import 'bluetooth_utils.dart';
import 'utils.dart';

class Bluebird {
  ///////////////////
  //  Internal
  //
  static bool _initialized = false;

  static final StreamController<BluebirdEvent> _eventStream = StreamController.broadcast();

  // always keep track of these device variables
  static final Map<String, BluetoothDevice> _devices = LinkedHashMap<String, BluetoothDevice>(
    equals: (a, b) => a.toLowerCase() == b.toLowerCase(),
    hashCode: (a) => a.toLowerCase().hashCode,
  );

  /// tracks whether a scan is currently running (also the guard that prevents
  /// two concurrent scans on the single radio). Scanning is driven entirely by
  /// us (not the platform), so we own the value and re-emit it via [isScanning].
  static bool _isScanningNow = false;
  static final _isScanningController = StreamController<bool>.broadcast();

  static void _setScanning(bool value) {
    _isScanningNow = value;
    _isScanningController.add(value);
  }

  // Managed-scan state, driven by [startScan]. Each advertisement flows into
  // [scanAdvertisements]; [scanResults] is that, accumulated + value-retaining.
  static StreamSubscription<ScanResult>? _scanSub; // performScan -> _advertisements
  static StreamSubscription<List<ScanResult>>? _scanAccumSub; // accumulate -> _scanList
  static final _advertisementsController = StreamController<ScanResult>.broadcast();
  static List<ScanResult> _scanList = const [];
  static final _scanListController = StreamController<List<ScanResult>>.broadcast();

  /// the last known adapter state
  static BluetoothAdapterState? _adapterStateNow;

  /// Bluebird log level
  static LogLevel _logLevel = LogLevel.debug;

  static OperationQueueMode _operationQueueMode = OperationQueueMode.global;
  static bool _deviceOperationsStarted = false;

  /// Resets all global state and re-subscribes to the current platform on the
  /// next call. For tests only.
  @visibleForTesting
  static void resetForTest() {
    _devices.clear();
    _adapterStateNow = null;
    _setScanning(false);
    _scanSub?.cancel();
    _scanAccumSub?.cancel();
    _scanSub = null;
    _scanAccumSub = null;
    _scanList = const [];
    _logLevel = LogLevel.debug;
    _operationQueueMode = OperationQueueMode.global;
    _deviceOperationsStarted = false;
    _loggerPrintSub?.cancel();
    _loggerPrintSub = null;
    _initialized = false;
  }

  ////////////////////
  //  Public
  //

  /// The current platform log verbosity (see [setPlatformLogLevel]).
  static LogLevel get platformLogLevel => _logLevel;

  /// How GATT operations are queued across connected devices.
  static OperationQueueMode get operationQueueMode => _operationQueueMode;

  /// Configures whether GATT operations use one process-wide queue or one
  /// independent queue per device.
  ///
  /// Call this before starting any device operation. Per-device queueing lets
  /// separate peripherals connect, discover, read, and write concurrently,
  /// while preserving operation ordering for each individual peripheral.
  static void setOperationQueueMode(OperationQueueMode mode) {
    if (mode == _operationQueueMode) return;
    if (_deviceOperationsStarted) {
      throw StateError('setOperationQueueMode must be called before starting device operations');
    }
    _operationQueueMode = mode;
  }

  @internal
  static void markDeviceOperationStarted() {
    _deviceOperationsStarted = true;
  }

  /// Checks whether the hardware supports Bluetooth
  static Future<bool> get isSupported async => await invoke("isSupported", (p) => p.isSupported());

  /// Return the friendly Bluetooth name of the local Bluetooth adapter
  static Future<String> get adapterName async => await invoke("getAdapterName", (p) => p.getAdapterName());

  /// whether a scan (via [startScan] or [performScan]) is currently running, as
  /// a stream that also exposes the current value:
  ///   - `Bluebird.isScanning.value` is `true` if scanning right now
  static ValueStream<bool> get isScanning =>
      ValueStream(value: () => _isScanningNow, changes: () => _isScanningController.stream);

  /// The growing, de-duplicated device list of the scan started via [startScan],
  /// as a stream that also exposes the current value. Value-retaining: a late
  /// listener immediately sees the current devices. Reset to `[]` on each
  /// [startScan]; retained after [stopScan] until the next start.
  static ValueStream<List<ScanResult>> get scanResults =>
      ValueStream(value: () => _scanList, changes: () => _scanListController.stream);

  /// Each advertisement of the scan started via [startScan], one [ScanResult] at
  /// a time (broadcast; silent when no scan is running). [scanResults] is this,
  /// accumulated into a de-duplicated device list.
  static Stream<ScanResult> get scanAdvertisements => _advertisementsController.stream;

  /// The raw stream of all app-level events, of every type.
  ///   - [BluebirdEvent] is `sealed`, so you can `switch` over it exhaustively,
  ///     or filter to the events you care about, e.g.
  ///     `Bluebird.events.where((e) => e is OnMtuChangedEvent)`.
  ///   - most consumers want the scoped streams instead (e.g. `device.mtu`,
  ///     `device.connectionState`, `characteristic.notifications`).
  static Stream<BluebirdEvent> get events => _eventStream.stream;

  /// Set configurable options
  ///   - [showPowerAlert] Whether to show the power alert (iOS & MacOS only). i.e. CBCentralManagerOptionShowPowerAlertKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See: https://developer.apple.com/documentation/corebluetooth/cbcentralmanageroptionshowpoweralertkey
  ///       This option has no effect on Android.
  ///   - [restoreState] Whether to opt into state restoration (iOS & MacOS only). i.e. CBCentralManagerOptionRestoreIdentifierKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See Apple Documentation for more details. This option has no effect on Android.
  static Future<void> setOptions({bool showPowerAlert = true, bool restoreState = false}) async {
    ensurePlatform(System.isDarwin, "setOptions");
    await invoke("setOptions", (p) => p.setOptions(showPowerAlert, restoreState));
  }

  /// Turn on Bluetooth (Android only)
  static Future<void> turnOn({Duration timeout = const Duration(seconds: 60)}) async {
    final userAccepted = await invoke("turnOn", (p) => p.turnOn());

    if (!userAccepted) {
      throw BluebirdException("turnOn", BluebirdErrorCode.userRejected, "user rejected");
    }

    // Wait for adapter to turn on
    await adapterReady(timeout: timeout);
  }

  /// The state of the Bluetooth adapter, as a stream that also exposes the
  /// current value via `await Bluebird.adapterState.value`.
  ///   - the platform reports adapter state only on demand (events fire on
  ///     *changes*), so the current value is fetched the first time it is needed.
  static final AsyncValueStream<BluetoothAdapterState> adapterState = AsyncValueStream(
    value: _fetchAdapterState,
    changes: () => extractEventStream<OnAdapterStateChangedEvent>().map((e) => e.adapterState),
  );

  /// Completes once the adapter is on; returns immediately if it already is.
  ///
  /// Fails fast on a terminal state that will never reach `on`, so it can't
  /// silently hang: [BluebirdErrorCode.unsupported] for `unavailable`, or
  /// [BluebirdErrorCode.permissionDenied] for `unauthorized`.
  ///
  /// [timeout] bounds the wait (default 60s); pass `null` to wait indefinitely.
  static Future<void> adapterReady({Duration? timeout = const Duration(seconds: 60)}) {
    final ready = adapterState
        .map((s) {
          switch (s) {
            case BluetoothAdapterState.unavailable:
              throw BluebirdException("adapterReady", BluebirdErrorCode.unsupported, "adapter is unavailable");
            case BluetoothAdapterState.unauthorized:
              throw BluebirdException("adapterReady", BluebirdErrorCode.permissionDenied, "adapter is unauthorized");
            default:
              return s;
          }
        })
        .firstWhere((s) => s == BluetoothAdapterState.on);

    return timeout == null ? ready : ready.bluebirdTimeout(timeout, "adapterReady");
  }

  /// Returns the current adapter state, fetching it from the platform the first
  /// time it is needed (adapter events fire only on *changes*).
  static Future<BluetoothAdapterState> _fetchAdapterState() async =>
      (_adapterStateNow ??= await invoke("getAdapterState", (p) => p.getAdapterState()))!;

  /// Retrieve a list of devices currently connected to your app
  static List<BluetoothDevice> get connectedDevices => _devices.values.where((d) => d.isConnected).toList();

  /// Retrieve a list of devices currently connected to the system
  /// - The list includes devices connected to by *any* app
  /// - You must still call device.connect() to connect them to *your app*
  /// - [withServices] required on iOS (for privacy purposes). ignored on android.
  static Future<List<BluetoothDevice>> systemDevices(List<Uuid> withServices) async {
    final devices = await invoke(
      "getSystemDevices",
      (p) => p.getSystemDevices(withServices.map((s) => s.string).toList()),
    );
    return devices.map(_deviceForBm).toList();
  }

  /// Retrieve a list of bonded devices (Android only)
  static Future<List<BluetoothDevice>> get bondedDevices async {
    ensurePlatform(System.isAndroid, "getBondedDevices");
    final devices = await invoke("getBondedDevices", (p) => p.getBondedDevices());
    return devices.map(_deviceForBm).toList();
  }

  static BluetoothDevice _deviceForBm(BmBluetoothDevice d) =>
      deviceForAddress(d.address)..platformNameInternal = d.platformName;

  /// Starts a scan and accumulates its de-duplicated devices into [scanResults]
  /// (value-retaining — read `.value` or listen). Each raw advertisement is also
  /// available one at a time via [scanAdvertisements]. Stop it with [stopScan];
  /// [isScanning] tracks whether it is running. Only one scan may run at a time
  /// (the radio is a single resource); [startScan] throws
  /// [BluebirdErrorCode.operationInProgress] if one already is.
  ///
  /// Scan errors are logged to [logger]; use [performScan] directly if you need
  /// to observe them. See [performScan] for the filter/argument semantics.
  static Future<void> startScan({
    List<Uuid> withServices = const [],
    List<String> withRemoteIds = const [],
    List<String> withNames = const [],
    List<String> withKeywords = const [],
    List<MsdFilter> withMsd = const [],
    List<ServiceDataFilter> withServiceData = const [],
    bool continuousUpdates = false,
    int continuousDivisor = 1,
    bool androidLegacy = false,
    AndroidScanMode androidScanMode = AndroidScanMode.lowLatency,
    bool androidUsesFineLocation = false,
    List<Uuid> webOptionalServices = const [],
    Duration? timeout,
  }) async {
    if (_isScanningNow) {
      throw BluebirdException("scan", BluebirdErrorCode.operationInProgress, "a scan is already in progress");
    }
    _scanList = const [];
    _scanListController.add(_scanList);
    // Maintain the value-retaining [scanResults] by accumulating the raw
    // advertisement stream (reusing the accumulate operator). Subscribed before
    // the pump below so it sees every advertisement.
    _scanAccumSub = _advertisementsController.stream.accumulate().listen((list) {
      _scanList = list;
      if (!_scanListController.isClosed) _scanListController.add(list);
    });
    _scanSub =
        performScan(
          withServices: withServices,
          withRemoteIds: withRemoteIds,
          withNames: withNames,
          withKeywords: withKeywords,
          withMsd: withMsd,
          withServiceData: withServiceData,
          continuousUpdates: continuousUpdates,
          continuousDivisor: continuousDivisor,
          androidLegacy: androidLegacy,
          androidScanMode: androidScanMode,
          androidUsesFineLocation: androidUsesFineLocation,
          webOptionalServices: webOptionalServices,
          timeout: timeout,
        ).listen(
          (r) {
            if (!_advertisementsController.isClosed) _advertisementsController.add(r);
          },
          onError: (Object e, StackTrace st) => logger.warning("scan failed", e, st),
          onDone: () => _scanSub = null,
        );
  }

  /// Stops a scan started via [startScan]. Idempotent.
  static Future<void> stopScan() async {
    await _scanSub?.cancel();
    await _scanAccumSub?.cancel();
    _scanSub = null;
    _scanAccumSub = null;
  }

  /// Scan for Bluetooth Low Energy devices, as a stream of advertisements — the
  /// all-in-one form (no separate stop). For the stateful start/stop/results
  /// model, use [startScan] / [stopScan] / [scanResults] instead.
  ///
  /// The native scan starts when the returned stream is first listened to, and
  /// stops when the subscription is cancelled or after [timeout] elapses (if
  /// set). On [timeout] the stream *completes normally* (it does not error), so
  /// `performScan(timeout: …).accumulate().last` yields the final device list.
  /// Only one scan may run at a time (the radio is a single resource); listening
  /// while a scan is already running throws [BluebirdErrorCode.operationInProgress].
  ///
  /// Each advertisement is emitted one at a time. To collect them into a
  /// growing, de-duplicated device list, use [ScanResultAccumulate.accumulate].
  ///
  /// Note: scan filters use an "or" behavior. i.e. if you set `withServices` &
  /// `withNames` we return all the advertisements that match any of the
  /// specified services *or* any of the specified names.
  ///   - [withServices] filter by advertised services
  ///   - [withRemoteIds] filter for known remoteIds (iOS: 128-bit guid, android: 48-bit mac address)
  ///   - [withNames] filter by advertised names (exact match)
  ///   - [withKeywords] filter by advertised names (matches any substring)
  ///   - [withMsd] filter by manufacturer specific data
  ///   - [withServiceData] filter by service data
  ///   - [continuousUpdates] If `true`, we continually update 'lastSeen' & 'rssi' by processing
  ///        duplicate advertisements. This takes more power. You typically should not use this option.
  ///   - [continuousDivisor] Useful to help performance. If divisor is 3, then two-thirds of advertisements are
  ///        ignored, and one-third are processed. This reduces main-thread usage caused by the platform channel.
  ///        The scan counting is per-device so you always get the 1st advertisement from each device.
  ///        If divisor is 1, all advertisements are returned. This argument only matters for `continuousUpdates` mode.
  ///   - [androidLegacy] Android only. If `true`, scan on 1M phy only.
  ///        If `false`, scan on all supported phys. How the radio cycles through all the supported phys is purely
  ///        dependent on the your Bluetooth stack implementation.
  ///   - [androidScanMode] choose the android scan mode to use when scanning
  ///   - [androidUsesFineLocation] request `ACCESS_FINE_LOCATION` permission at runtime
  ///   - [timeout] if set, stop scanning and complete the stream (normally, not
  ///        with an error) after this duration; otherwise scan until cancelled
  static Stream<ScanResult> performScan({
    List<Uuid> withServices = const [],
    List<String> withRemoteIds = const [],
    List<String> withNames = const [],
    List<String> withKeywords = const [],
    List<MsdFilter> withMsd = const [],
    List<ServiceDataFilter> withServiceData = const [],
    bool continuousUpdates = false,
    int continuousDivisor = 1,
    bool androidLegacy = false,
    AndroidScanMode androidScanMode = AndroidScanMode.lowLatency,
    bool androidUsesFineLocation = false,
    List<Uuid> webOptionalServices = const [],
    Duration? timeout,
  }) async* {
    assert(continuousDivisor >= 1, "divisor must be >= 1");

    // Note: `withKeywords` is not compatible with other filters on android
    // because it is implemented in custom bluebird code, not android code, and the
    // android 'name' filter is only available as of android sdk 33 (August 2022)
    if (System.isAndroid) {
      final hasOtherFilter =
          withServices.isNotEmpty ||
          withRemoteIds.isNotEmpty ||
          withNames.isNotEmpty ||
          withMsd.isNotEmpty ||
          withServiceData.isNotEmpty;
      assert(withKeywords.isEmpty || !hasOtherFilter, "withKeywords is not compatible with other filters on Android");
    }

    // one scan at a time — claim synchronously so concurrent listens can't race
    if (_isScanningNow) {
      throw BluebirdException("scan", BluebirdErrorCode.operationInProgress, "a scan is already in progress");
    }
    _setScanning(true);

    final settings = BmScanSettings(
      withServices: withServices.map((s) => s.string).toList(),
      withRemoteIds: withRemoteIds,
      withNames: withNames,
      withKeywords: withKeywords,
      withMsd: withMsd.map((d) => d.bm).toList(),
      withServiceData: withServiceData.map((d) => d.bm).toList(),
      continuousUpdates: continuousUpdates,
      continuousDivisor: continuousDivisor,
      androidLegacy: androidLegacy,
      androidScanMode: androidScanMode.value,
      androidUsesFineLocation: androidUsesFineLocation,
      webOptionalServices: webOptionalServices.map((s) => s.string).toList(),
    );

    // Buffer advertisements from *before* the native scan starts, so none are
    // missed while startScan is in flight.
    final controller = StreamController<ScanResult>();
    // Guard against add-after-close: the controller can be closed (by a timeout
    // or endScan()) before this subscription is cancelled in the finally.
    final advertisements = extractEventStream<OnScanAdvertisementEvent>()
        .map((e) => e.advertisement)
        .listen(
          (a) {
            if (!controller.isClosed) controller.add(a);
          },
          onError: (Object e, StackTrace st) {
            if (!controller.isClosed) controller.addError(e, st);
          },
        );

    // Ways the scan ends without us telling the platform to stop, because the
    // native scan is already dead: it reported a failure, the adapter turned
    // off, or the engine detached (hot restart). In each case skip stopScan.
    var nativeScanDead = false;
    void endScan({Object? error}) {
      if (controller.isClosed) return;
      nativeScanDead = true;
      if (error != null) controller.addError(error);
      controller.close();
    }

    final failures = extractEventStream<OnScanFailedEvent>().listen(
      (e) => endScan(error: BluebirdException("scan", BluebirdErrorCode.platform, "(${e.errorCode}) ${e.errorString}")),
    );
    final adapterOff = adapterState.changes
        .where((s) => s == BluetoothAdapterState.off || s == BluetoothAdapterState.turningOff)
        .listen((_) => endScan());
    final detached = extractEventStream<OnDetachedFromEngineEvent>().listen((_) => endScan());

    Timer? timeoutTimer;
    var started = false;
    try {
      await invoke("startScan", (p) => p.startScan(settings));
      started = true;
      // Stop the scan and complete the stream normally after [timeout]. Closing
      // the controller (rather than endScan()) leaves nativeScanDead false, so
      // the finally still tells the platform to stopScan.
      if (timeout != null) {
        timeoutTimer = Timer(timeout, () {
          if (!controller.isClosed) controller.close();
        });
      }
      yield* controller.stream;
    } finally {
      timeoutTimer?.cancel();
      await advertisements.cancel();
      await failures.cancel();
      await adapterOff.cancel();
      await detached.cancel();
      if (!controller.isClosed) await controller.close();
      try {
        // release the guard only after the native scan has actually stopped, so
        // a new scan can't start before this one's stopScan lands
        if (started && !nativeScanDead) await invoke("stopScan", (p) => p.stopScan());
      } finally {
        _setScanning(false);
      }
    }
  }

  /// Sets the verbosity of the *native* platform logging (Android logcat / Apple
  /// os_log). Those logs surface through the platform's own tooling (logcat /
  /// Console.app), not through [logger].
  ///
  /// The Dart-side platform-channel call tracer is separate and independent of
  /// this — it logs to [logger] at [Level.FINEST], so lower `logger.level` to see
  /// it.
  static Future<void> setPlatformLogLevel(LogLevel level) async {
    _logLevel = level;
    await invoke("setLogLevel", (p) => p.setLogLevel(level));
  }

  /// The logger for every Bluebird log, yours to configure — attach a listener
  /// and set a level; nothing is printed unless you do:
  /// ```dart
  /// Bluebird.logger.onRecord.listen((r) => debugPrint('${r.level.name}: ${r.message}'));
  /// Bluebird.logger.level = Level.INFO; // filter as you like
  /// ```
  /// It carries both the Dart-side events from this package — most of them
  /// path-scoped (`[remoteId][service][characteristic] …`) via the
  /// [BluebirdLoggable.logger] helper — and the low-level platform-channel call
  /// tracing (at [Level.FINEST]). It is the same instance as
  /// [BluebirdPlatform.logger], one layer down.
  static Logger get logger => BluebirdPlatform.logger;

  static StreamSubscription<LogRecord>? _loggerPrintSub;

  /// Convenience for the common case: print [logger] records to the console (via
  /// `debugPrint`) in a default format, at [level] and above. For anything else
  /// — routing to a file or Crashlytics, a custom format, filtering by
  /// [LogRecord.loggerName] — listen to [logger]'s `onRecord` yourself instead.
  ///
  /// If [level] is given, sets [logger]'s `level` to it; otherwise the current
  /// level is left untouched (so you can start printing without changing it).
  /// Idempotent: the console subscription is created once and reused, so repeat
  /// calls never double-print.
  static void configureLoggerPrinting({Level? level}) {
    if (level != null) logger.level = level;
    _loggerPrintSub ??= logger.onRecord.listen((r) {
      debugPrint('[${r.loggerName}] ${r.level.name}: ${r.message}${r.error != null ? ' — ${r.error}' : ''}');
      if (r.stackTrace != null) debugPrint('${r.stackTrace}');
    });
  }

  /// Request Bluetooth PHY support
  static Future<PhySupport> getPhySupport() async {
    ensurePlatform(System.isAndroid, "getPhySupport");
    return await invoke("getPhySupport", (p) => p.getPhySupport());
  }

  static BluetoothDevice deviceForAddress(String address) {
    return _devices.putIfAbsent(address, () => BluetoothDevice(remoteId: address));
  }

  static void _initBluebird() {
    if (_initialized) return;
    _initialized = true;

    BluebirdPlatform.instance.events.listen(_onPlatformEvent);
  }

  static void _onPlatformEvent(BmEvent event) {
    switch (event) {
      case BmAdapterStateEvent():
        _adapterStateNow = event.adapterState;
        _eventStream.add(OnAdapterStateChangedEvent(event.adapterState));

      case BmScanAdvertisementEvent():
        _eventStream.add(OnScanAdvertisementEvent(ScanResult.fromProto(event.advertisement)));

      case BmScanFailedEvent():
        _eventStream.add(OnScanFailedEvent(event.errorCode, event.errorString));

      case BmConnectionStateEvent():
        final device = deviceForAddress(event.address);
        final disconnectReason = event.connectionState == BluetoothConnectionState.disconnected
            ? DisconnectReason(event.disconnectReasonCode, event.disconnectReasonString)
            : null;
        _dispatchDeviceEvent(device, OnConnectionStateChangedEvent(device, event.connectionState, disconnectReason));

      case BmCharacteristicNotificationEvent():
        final device = deviceForAddress(event.address);
        final characteristic = device.characteristicForRefOrNull(event.characteristic);
        if (characteristic == null) {
          device.logger.warning(
            "Dropped notification: unknown characteristic=${event.characteristic.characteristic.uuid}",
          );
          break;
        }
        _eventStream.add(OnCharacteristicNotifiedEvent(characteristic, event.value));

      case BmMtuChangedEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(device, OnMtuChangedEvent(device, event.mtu));

      case BmNameChangedEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(device, OnNameChangedEvent(device, event.name));

      case BmServicesResetEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(device, OnServicesResetEvent(device));

      case BmBondStateEvent():
        final device = deviceForAddress(event.address);
        _dispatchDeviceEvent(
          device,
          OnBondStateChangedEvent(device, event.bondState, event.prevState ?? device.currentBondState),
        );

      case BmDetachedFromEngineEvent():
        _eventStream.add(OnDetachedFromEngineEvent());

      case BmL2capChannelClosedEvent():
        // Unsolicited close (peer close, disconnect, or I/O error): tear down
        // the matching channel so its `input` stream completes. A channel the
        // app closed itself is already unregistered, so this is a no-op then.
        _l2capChannels.remove(event.channelId)?.onRemoteClosed();
    }
  }

  /// Open L2CAP channels, keyed by their native channel id, so an unsolicited
  /// [BmL2capChannelClosedEvent] can be routed to the right [BluetoothL2CapChannel].
  static final Map<int, BluetoothL2CapChannel> _l2capChannels = {};

  @internal
  static void registerL2cap(BluetoothL2CapChannel channel) => _l2capChannels[channel.channelId] = channel;

  @internal
  static void unregisterL2cap(int channelId) => _l2capChannels.remove(channelId);

  /// Applies a device event to its device (a synchronous state update) and then
  /// broadcasts it. The `Bm…Event` → `On…Event` translation happens in
  /// [_onPlatformEvent]; the device only reacts to the app-level event.
  static void _dispatchDeviceEvent(BluetoothDevice device, BluebirdDeviceEvent event) {
    device.applyEvent(event);
    _eventStream.add(event);
  }

  /// Broadcast an app-level event that does not originate from the platform
  /// event stream (e.g. a read result, which arrives via the method future).
  @internal
  static void emitEvent(BluebirdEvent event) => _eventStream.add(event);

  /// Runs one platform call with the standard guard pipeline, stating the
  /// operation [name] once. Device-scoped calls go through
  /// [BluetoothDevice.invoke], which adds the connection guards.
  @internal
  static Future<T> invoke<T>(
    String name,
    Future<T> Function(BluebirdPlatform p) call, {
    Duration? timeout,
    bool ensureAdapterIsOn = false,
    bool serializePlatformCall = true,
  }) {
    Future<T> run() async {
      _initBluebird();
      try {
        return await call(BluebirdPlatform.instance);
      } on PlatformException catch (e) {
        final code = _errorCodes[e.code] ?? BluebirdErrorCode.platform;
        if (code == BluebirdErrorCode.attError && e.details is int) {
          throw BluetoothAttException(e.code, e.details as int, e.message);
        }
        throw BluebirdException(e.code, code, e.message, e.details);
      }
    }

    // Federated backends protect their hot-restart handshake. The legacy mode
    // additionally serializes all platform calls for backwards compatibility.
    var future = serializePlatformCall ? Mutex.platform.protect(run) : run();
    if (ensureAdapterIsOn) future = future.bluebirdEnsureAdapterIsOn(name);
    if (timeout != null) future = future.bluebirdTimeout(timeout, name);
    return future;
  }

  /// Wire-string -> [BluebirdErrorCode] lookup, built from the shared pigeon enum.
  static final _errorCodes = {for (final c in BluebirdErrorCode.values) c.wire: c};

  /// The stream of events of type [T], optionally filtered by [test].
  @internal
  static Stream<T> extractEventStream<T extends BluebirdEvent>([bool Function(T event)? test]) =>
      _eventStream.stream.where((e) => e is T).cast<T>().where(test ?? (_) => true);
}

/// Controls how Bluebird serializes operations involving a peripheral.
enum OperationQueueMode {
  /// Preserve the historical behavior: one operation at a time globally.
  global,

  /// Serialize each device independently, allowing cross-device concurrency.
  perDevice,
}

enum AndroidScanMode {
  lowPower(0),
  balanced(1),
  lowLatency(2),
  opportunistic(-1);

  final int value;
  const AndroidScanMode(this.value);
}

class MsdFilter {
  final int manufacturerId;

  /// Filter for this data
  final List<int> data;

  /// Optional bitwise mask to define which bits in [data] must match.
  /// Must have the same length as [data].
  final List<int>? mask;

  MsdFilter(this.manufacturerId, {this.data = const [], this.mask = const []})
    : assert(mask == null || (data.length == mask.length), "mask & data must be same length");

  BmMsdFilter get bm => BmMsdFilter(
    manufacturerId: manufacturerId,
    data: data.isEmpty ? null : Uint8List.fromList(data),
    mask: mask == null || mask!.isEmpty ? null : Uint8List.fromList(mask!),
  );
}

class ServiceDataFilter {
  final Uuid service;

  /// Filter for this data
  final List<int> data;

  /// Optional bitwise mask to define which bits in [data] must match.
  /// Must have the same length as [data].
  final List<int>? mask;

  ServiceDataFilter(this.service, {this.data = const [], this.mask})
    : assert(mask == null || (data.length == mask.length), "mask & data must be same length");

  // convert to bmMsg
  BmServiceDataFilter get bm => BmServiceDataFilter(
    service: service.string,
    data: Uint8List.fromList(data),
    mask: mask == null ? null : Uint8List.fromList(mask!),
  );
}

class ScanResult {
  final String address;
  final String platformName;
  final AdvertisementData advertisementData;
  final int rssi;
  final DateTime timestamp;

  ScanResult({
    required this.address,
    required this.platformName,
    required this.advertisementData,
    required this.rssi,
    required this.timestamp,
  });

  ScanResult.fromProto(BmScanAdvertisement p)
    : address = p.address,
      platformName = p.platformName ?? "",
      advertisementData = AdvertisementData.fromProto(p),
      rssi = p.rssi,
      timestamp = DateTime.now();

  BluetoothDevice get device => Bluebird.deviceForAddress(address);

  /// Returns this result updated with [newer], carrying forward any field that
  /// [newer] does not carry.
  ///
  /// A device's advertising and scan-response PDUs arrive as separate
  /// advertisements, so a given packet may omit fields (commonly the name) that
  /// an earlier one carried. [rssi], [timestamp] and a non-empty [platformName]
  /// always take [newer]'s value; [advertisementData] is merged field-by-field
  /// (see [AdvertisementData.mergedWith]).
  ScanResult mergedWith(ScanResult newer) => ScanResult(
    address: newer.address,
    platformName: newer.platformName.isNotEmpty ? newer.platformName : platformName,
    advertisementData: advertisementData.mergedWith(newer.advertisementData),
    rssi: newer.rssi,
    timestamp: newer.timestamp,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScanResult && runtimeType == other.runtimeType && address == other.address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() =>
      'ScanResult{'
      'address: $address, '
      'advertisementData: $advertisementData, '
      'rssi: $rssi, '
      'timestamp: $timestamp'
      '}';
}

/// Layers on top of a raw [Bluebird.scan] stream of individual advertisements.
extension ScanResultAccumulate on Stream<ScanResult> {
  /// Accumulates advertisements into a growing, de-duplicated device list,
  /// keyed by address.
  ///   - emits `[]` first, then the updated list on every advertisement.
  ///   - [coalesce] (default `true`): when a device re-advertises, merge the new
  ///     advertisement onto the stored one via [ScanResult.mergedWith] rather
  ///     than replacing it, so fields split across the advertising and
  ///     scan-response PDUs (commonly the name) don't flicker. Set `false` to
  ///     keep the latest advertisement verbatim.
  ///   - [removeIfGone]: if set, a device that has not re-advertised within this
  ///     duration is evicted from the list. This only makes sense when the
  ///     underlying scan uses `continuousUpdates: true` (otherwise duplicate
  ///     advertisements are suppressed and every device looks "gone").
  Stream<List<ScanResult>> accumulate({Duration? removeIfGone, bool coalesce = true}) {
    final output = <String, ScanResult>{};
    StreamSubscription<ScanResult>? source;
    Timer? evictTimer;
    late final StreamController<List<ScanResult>> controller;
    controller = StreamController<List<ScanResult>>(
      onListen: () {
        controller.add(const []);
        source = listen(
          (sr) {
            final prev = output[sr.address];
            output[sr.address] = (coalesce && prev != null) ? prev.mergedWith(sr) : sr;
            controller.add(output.values.toList());
          },
          onError: controller.addError,
          onDone: controller.close,
        );
        if (removeIfGone != null) {
          evictTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
            final before = output.length;
            output.removeWhere((_, sr) => DateTime.now().difference(sr.timestamp) > removeIfGone);
            if (output.length != before) controller.add(output.values.toList());
          });
        }
      },
      onCancel: () async {
        evictTimer?.cancel();
        await source?.cancel();
      },
    );
    return controller.stream;
  }
}

class AdvertisementData {
  final String? advName;
  final int? txPowerLevel;
  final int? appearance; // not supported on iOS / macOS
  final bool connectable;
  final Map<int, List<int>> manufacturerData; // key: manufacturerId
  final Map<Uuid, List<int>> serviceData; // key: service guid
  final List<Uuid> serviceUuids;

  AdvertisementData({
    required this.advName,
    required this.txPowerLevel,
    required this.appearance,
    required this.connectable,
    required this.manufacturerData,
    required this.serviceData,
    required this.serviceUuids,
  });

  AdvertisementData.fromProto(BmScanAdvertisement p)
    : advName = p.advName,
      txPowerLevel = p.txPowerLevel,
      appearance = p.appearance,
      connectable = p.connectable,
      manufacturerData = p.manufacturerData,
      serviceData = p.serviceData.map((uuid, data) => MapEntry(Uuid(uuid), data)),
      serviceUuids = p.serviceUuids.map(Uuid.new).toList();

  AdvertisementData mergedWith(AdvertisementData newer) => AdvertisementData(
    advName: newer.advName ?? advName,
    txPowerLevel: newer.txPowerLevel ?? txPowerLevel,
    appearance: newer.appearance ?? appearance,
    connectable: newer.connectable,
    manufacturerData: newer.manufacturerData.isNotEmpty ? newer.manufacturerData : manufacturerData,
    serviceData: newer.serviceData.isNotEmpty ? newer.serviceData : serviceData,
    serviceUuids: newer.serviceUuids.isNotEmpty ? newer.serviceUuids : serviceUuids,
  );

  @override
  String toString() =>
      'AdvertisementData{'
      'advName: $advName, '
      'txPowerLevel: $txPowerLevel, '
      'appearance: $appearance, '
      'connectable: $connectable, '
      'manufacturerData: $manufacturerData, '
      'serviceData: $serviceData, '
      'serviceUuids: $serviceUuids'
      '}';
}

extension BluebirdErrorCodeWire on BluebirdErrorCode {
  /// The wire form of this code: snake_case of the enum name — the
  /// convention shared with the native implementations (see pigeons/messages.dart).
  String get wire => name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
}

class BluebirdException implements Exception {
  /// Which function failed?
  final String function;
  final BluebirdErrorCode code;

  /// note: depends on platform
  final String? description;

  /// The raw platform error detail, when available — e.g. the native error
  /// domain + code behind a [BluebirdErrorCode.darwinError]/`androidError`. Useful for
  /// pinning down the exact cause (e.g. which ATT error a write hit).
  final Object? details;

  BluebirdException(this.function, this.code, [this.description, this.details]);

  /// The Bluetooth ATT error-response code behind this exception (e.g. 3 ==
  /// write-not-permitted), or null when the failure was not an ATT error.
  ///
  /// A spec-level error means the peer answered a request with an ATT Error
  /// Response — distinct from a platform/link failure (see the class docs).
  /// Every platform reports these uniformly as [BluebirdErrorCode.attError]
  /// carrying the raw code, so this is a simple accessor. See [AttError] for the
  /// well-known codes and [BluetoothAttException] to catch these directly.
  int? get attError => code == BluebirdErrorCode.attError && details is int ? details as int : null;

  @override
  String toString() =>
      'BluebirdException | $function | bluebird-code: $code | $description'
      '${details != null ? ' | details: $details' : ''}';
}

/// A [BluebirdException] raised when a GATT operation fails at the Bluetooth
/// *spec* level — the peer answered with an ATT Error Response — as opposed to a
/// platform/link failure (adapter off, disconnect, CoreBluetooth `CBError`,
/// Android stack error), which stays a plain [BluebirdException]. Lets callers
/// distinguish "the device rejected my request, and here's why" from "the
/// operation failed locally":
///
/// ```dart
/// try {
///   await characteristic.write(value);
/// } on BluetoothAttException catch (e) {
///   if (e.attError == AttError.writeNotPermitted) { ... }
/// }
/// ```
///
/// [attError] is always non-null here — it carries the raw one-octet code, which
/// spans the core ATT, application, and GATT common ranges (see [AttError]).
class BluetoothAttException extends BluebirdException {
  BluetoothAttException(String function, int attError, [String? description])
    : super(function, BluebirdErrorCode.attError, description, attError);

  @override
  int get attError => details as int;

  /// If [attError] is in the ATT application error range (0x80–0x9F, defined by
  /// the peer's profile), its zero-based offset within that range — `0` for
  /// 0x80 … `31` for 0x9F — otherwise null. Handy when a profile numbers its own
  /// errors from zero.
  int? get appErrorZeroIndexed => attError >= 0x80 && attError <= 0x9f ? attError - 0x80 : null;
}

/// Well-known Bluetooth ATT error-response codes, as surfaced by
/// [BluebirdException.attError] / [BluetoothAttException].
///
/// The single one-octet error space carried by the ATT Error Response is
/// layered by who defines each range:
///   - `0x01–0x11` — the core ATT spec codes (below).
///   - `0x80–0x9F` — **application** errors, defined by the peer's profile; not
///     enumerated here (they're app-specific) but delivered as raw ints.
///   - `0xE0–0xFF` — the GATT **common profile & service** codes (below).
abstract final class AttError {
  // Core ATT spec codes (0x01–0x11).
  static const int invalidHandle = 0x01;
  static const int readNotPermitted = 0x02;
  static const int writeNotPermitted = 0x03;
  static const int invalidPdu = 0x04;
  static const int insufficientAuthentication = 0x05;
  static const int requestNotSupported = 0x06;
  static const int invalidOffset = 0x07;
  static const int insufficientAuthorization = 0x08;
  static const int prepareQueueFull = 0x09;
  static const int attributeNotFound = 0x0a;
  static const int attributeNotLong = 0x0b;
  static const int insufficientEncryptionKeySize = 0x0c;
  static const int invalidAttributeValueLength = 0x0d;
  static const int unlikelyError = 0x0e;
  static const int insufficientEncryption = 0x0f;
  static const int unsupportedGroupType = 0x10;
  static const int insufficientResources = 0x11;

  // GATT common profile & service codes (0xE0–0xFF).
  static const int writeRequestRejected = 0xfc;
  static const int cccdImproperlyConfigured = 0xfd;
  static const int procedureAlreadyInProgress = 0xfe;
  static const int outOfRange = 0xff;
}
