// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// An opt-in testing helper: a mockable instance wrapper around the static
/// [Bluebird] API.
///
/// `Bluebird`'s API is static and cannot be mocked directly. Depend on
/// [BluebirdMockable] instead of calling `Bluebird` directly in the code you
/// want to test, then substitute a mock in your tests:
///
/// ```dart
/// import 'package:bluebird/mock.dart';
/// ```
///
/// This library is intentionally *not* exported by `package:bluebird/bluebird.dart`,
/// so it is only compiled into apps that explicitly import it.
library;

import 'package:bluebird/bluebird.dart';

/// Instance wrapper around the static [Bluebird] API so it can be mocked or
/// faked in tests. Every member simply forwards to the matching `Bluebird`
/// static; override them in a subclass or a mocking framework
/// (e.g. [mocktail](https://pub.dev/packages/mocktail)).
class BluebirdMockable {
  LogLevel get platformLogLevel => Bluebird.platformLogLevel;

  Future<void> setPlatformLogLevel(LogLevel level) => Bluebird.setPlatformLogLevel(level);

  Future<bool> get isSupported => Bluebird.isSupported;

  Future<String> get adapterName => Bluebird.adapterName;

  AsyncValueStream<BluetoothAdapterState> get adapterState => Bluebird.adapterState;

  Future<void> turnOn({Duration timeout = const Duration(seconds: 60)}) => Bluebird.turnOn(timeout: timeout);

  Future<void> setOptions({bool showPowerAlert = true, bool restoreState = false}) =>
      Bluebird.setOptions(showPowerAlert: showPowerAlert, restoreState: restoreState);

  Stream<BluebirdEvent> get events => Bluebird.events;

  ValueStream<bool> get isScanning => Bluebird.isScanning;

  ValueStream<List<ScanResult>> get scanResults => Bluebird.scanResults;

  Stream<ScanResult> get scanAdvertisements => Bluebird.scanAdvertisements;

  Future<void> startScan({
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
  }) => Bluebird.startScan(
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
  );

  Future<void> stopScan() => Bluebird.stopScan();

  Stream<ScanResult> performScan({
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
  }) => Bluebird.performScan(
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
  );

  List<BluetoothDevice> get connectedDevices => Bluebird.connectedDevices;

  Future<List<BluetoothDevice>> systemDevices(List<Uuid> withServices) => Bluebird.systemDevices(withServices);

  Future<List<BluetoothDevice>> get bondedDevices => Bluebird.bondedDevices;

  BluetoothDevice deviceForAddress(String address) => Bluebird.deviceForAddress(address);

  Future<PhySupport> getPhySupport() => Bluebird.getPhySupport();
}
