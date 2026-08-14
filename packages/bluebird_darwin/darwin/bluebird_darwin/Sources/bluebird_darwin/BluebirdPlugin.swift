// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import CoreBluetooth
import Foundation

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

/// iOS / macOS implementation of bluebird.
///
/// All host-api methods and CoreBluetooth delegate callbacks run on the main
/// thread (the CBCentralManager is created with the main queue), so no
/// locking is required.
public class BluebirdPlugin: NSObject, FlutterPlugin {
  var sink: PigeonEventSink<BmEvent>?

  var centralManager: CBCentralManager?

  /// Strong references to every CBPeripheral we have seen. CoreBluetooth does
  /// not keep strong references itself and warns about API misuse otherwise.
  var knownPeripherals: [String: CBPeripheral] = [:]

  /// Per-device state, keyed by device address. Only devices currently
  /// connecting or connected have an entry.
  var peripherals: [String: PeripheralState] = [:]

  // scanning
  var scanSettings: BmScanSettings?
  var scanCounts: [String: Int] = [:]

  // L2CAP connection-oriented channels (data plane on kL2capDataChannelName)
  var l2capDataChannel: FlutterBasicMessageChannel?
  var l2capChannels: [Int64: L2capChannel] = [:]
  var nextL2capId: Int64 = 1

  private var mtuPollTimer: Timer?

  var logLevel: LogLevel = .debug
  var showPowerAlert = true
  var restoreState = false

  /// random error code defined by bluebird for user-initiated
  /// connection cancellation
  static let userCanceledErrorCode: Int64 = 23789258
  /// random error code defined by bluebird for adapter-off
  /// disconnections
  static let adapterOffDisconnectCode: Int64 = 1573878

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      let messenger = registrar.messenger
    #else
      let messenger = registrar.messenger()
    #endif
    let instance = BluebirdPlugin()
    BluebirdHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
    NativeEventsStreamHandler.register(
      with: messenger, streamHandler: BluebirdStreamHandler(plugin: instance))
    instance.setUpL2capDataChannel(messenger)
  }

  #if os(iOS)
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
      log(.debug, "detachFromEngine")
      peripherals.values.forEach { $0.cancelAllPending() }
      // drop every L2CAP channel silently (dart side is gone)
      l2capDataChannel?.setMessageHandler(nil)
      closeAllL2cap()
      sink?.success(BmDetachedFromEngineEvent())
      sink?.endOfStream()
      sink = nil
    }
  #endif

  // ───────────────────────────────────────────────────────────────────────────
  // Utils
  // ───────────────────────────────────────────────────────────────────────────

  /// Lazily initializes the CBCentralManager, honoring setOptions.
  @discardableResult
  func ensureCentralManager() -> CBCentralManager {
    if let central = centralManager {
      return central
    }

    log(.debug, "initializing CBCentralManager")

    var options: [String: Any] = [:]
    if showPowerAlert {
      options[CBCentralManagerOptionShowPowerAlertKey] = true
    }
    #if os(iOS)
      if restoreState {
        options[CBCentralManagerOptionRestoreIdentifierKey] = "bluebirdRestoreIdentifier"
      }
    #endif

    log(.debug, "showPowerAlert: \(showPowerAlert ? "yes" : "no")")
    log(.debug, "restoreState: \(restoreState ? "yes" : "no")")

    let central = CBCentralManager(delegate: self, queue: nil, options: options)
    centralManager = central
    return central
  }

  var isAdapterOn: Bool {
    centralManager?.state == .poweredOn
  }

  /// The peripheral for `address`, if currently connected.
  func connectedPeripheral(_ address: String) -> CBPeripheral? {
    guard let state = peripherals[address], state.connection == .connected else { return nil }
    return state.peripheral
  }

  var connectedPeripheralCount: Int {
    peripherals.values.filter { $0.connection == .connected }.count
  }

  func log(_ level: LogLevel, _ message: String) {
    if level.rawValue <= logLevel.rawValue {
      NSLog("[Bluebird-Darwin] %@", message)
    }
  }

  /// Logs a delegate callback result: error at .error level, otherwise
  /// `detail` at .debug level.
  func logResult(_ name: String, _ error: Error?, _ detail: @autoclosure () -> String) {
    if let error {
      log(.error, "\(name): \(error.localizedDescription)")
    } else {
      log(.debug, "\(name): \(detail())")
    }
  }

  /// Runs `body` on the main actor and reports its result through the pigeon
  /// `completion`. A CancellationError (hot restart / engine detach) drops the
  /// completion without invoking it — the dart side no longer exists.
  ///
  /// CBCentralManager uses queue nil (main) and pigeon calls arrive on main,
  /// so @MainActor keeps the single-threaded model.
  func launch<T>(
    _ completion: @escaping (Result<T, Error>) -> Void,
    _ body: @escaping @MainActor () async throws -> T
  ) {
    Task { @MainActor in
      do {
        completion(.success(try await body()))
      } catch is CancellationError {
        // hot restart / detach: drop without invoking
      } catch {
        completion(.failure(error))
      }
    }
  }

  /// The state for `address`, if currently connected; throws not_connected
  /// otherwise.
  func requireConnectedState(_ address: String) throws -> PeripheralState {
    guard let state = peripherals[address], state.connection == .connected else {
      throw notConnectedError()
    }
    return state
  }

  /// The canonical ref for `chr`, so the delegate callback finds the slot.
  func canonicalRef(_ chr: CBCharacteristic, in peripheral: CBPeripheral)
    throws -> BmCharacteristicRef
  {
    guard let ref = characteristicRef(for: chr, in: peripheral) else { throw notConnectedError() }
    return ref
  }

  /// The canonical ref for `desc`, so the delegate callback finds the slot.
  func canonicalRef(_ desc: CBDescriptor, in peripheral: CBPeripheral)
    throws -> BmDescriptorRef
  {
    guard let ref = descriptorRef(for: desc, in: peripheral) else { throw notConnectedError() }
    return ref
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Pending-operation slots
  // ───────────────────────────────────────────────────────────────────────────

  /// Occupies the device's GATT slot with `kind`, runs `start`, then suspends
  /// until a delegate callback resumes the operation.
  ///
  /// Throws operation_in_progress immediately if the slot is occupied. If
  /// `start` throws, the slot is rolled back and the error propagates.
  @MainActor
  func awaitGatt<T>(
    _ state: PeripheralState, _ kind: GattOp, start: () throws -> Void
  ) async throws -> T {
    let value = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Any?, Error>) in
      guard state.pendingGatt == nil else {
        continuation.resume(throwing: operationInProgressError())
        return
      }
      state.pendingGatt = PendingGatt(kind: kind, continuation: continuation)

      do {
        try start()
      } catch {
        // roll back the slot (unless something already resumed it)
        // and propagate the error
        state.takeGatt { $0 == kind }?.continuation.resume(throwing: error)
      }
    }
    return value as! T
  }

  /// Occupies the device's connect slot, runs `start`, then suspends until a
  /// delegate callback resumes the operation. Same contract as `awaitGatt`.
  @MainActor
  func awaitConnect(_ state: PeripheralState, start: () throws -> Void) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      guard state.pendingConnect == nil else {
        continuation.resume(throwing: operationInProgressError())
        return
      }
      state.pendingConnect = continuation

      do {
        try start()
      } catch {
        state.takeConnect()?.resume(throwing: error)
      }
    }
  }

  /// Occupies the device's disconnect slot, runs `start`, then suspends until
  /// a delegate callback resumes the operation. Same contract as `awaitGatt`.
  @MainActor
  func awaitDisconnect(_ state: PeripheralState, start: () throws -> Void) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      guard state.pendingDisconnect == nil else {
        continuation.resume(throwing: operationInProgressError())
        return
      }
      state.pendingDisconnect = continuation

      do {
        try start()
      } catch {
        state.takeDisconnect()?.resume(throwing: error)
      }
    }
  }

  /// Enqueues a write command and completes once CoreBluetooth accepts it.
  /// Consecutive calls are drained synchronously while buffer capacity remains,
  /// which lets CoreBluetooth schedule several frames in one connection event.
  @MainActor
  func enqueueWriteWithoutResponse(
    _ state: PeripheralState, data: Data, characteristic: CBCharacteristic
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      state.pendingWritesWithoutResponse.append(
        PendingWriteWithoutResponse(
          data: data, characteristic: characteristic, continuation: continuation))
      drainWritesWithoutResponse(state)
    }
  }

  /// Drains as much of the FIFO as CoreBluetooth currently accepts. The
  /// delegate calls this again when a full buffer becomes writable.
  func drainWritesWithoutResponse(_ state: PeripheralState) {
    while !state.pendingWritesWithoutResponse.isEmpty,
      state.peripheral.canSendWriteWithoutResponse
    {
      let write = state.pendingWritesWithoutResponse.removeFirst()
      state.peripheral.writeValue(
        write.data, for: write.characteristic, type: .withoutResponse)
      write.continuation.resume()
    }
  }

  /// Occupies the device's L2CAP-open slot, runs `start` (which kicks off
  /// `openL2CAPChannel`), then suspends until `peripheral(_:didOpen:error:)`
  /// resumes it. Same contract as `awaitGatt`.
  @MainActor
  func awaitL2capOpen(_ state: PeripheralState, start: () -> Void) async throws -> CBL2CAPChannel {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<CBL2CAPChannel, Error>) in
      guard state.pendingL2capOpen == nil else {
        continuation.resume(throwing: operationInProgressError())
        return
      }
      state.pendingL2capOpen = continuation
      start()
    }
  }

  /// Completes the device's pending GATT operation from a delegate callback,
  /// but only if `matching` accepts its kind: failure with the wrapped
  /// CoreBluetooth error, or success with `success()`.
  /// Returns false if no such operation was in flight.
  @discardableResult
  func completeGatt(
    _ state: PeripheralState?, matching: (GattOp) -> Bool,
    error: Error?, success: @autoclosure () -> Any?
  ) -> Bool {
    guard let pending = state?.takeGatt(matching: matching) else { return false }
    if let error {
      pending.continuation.resume(throwing: cbError(error))
    } else {
      pending.continuation.resume(returning: success())
    }
    return true
  }

  /// if allowLongWrite is disabled, we can only write up to MTU-3
  func getMaxPayload(
    _ peripheral: CBPeripheral, type: CBCharacteristicWriteType, allowLongWrite: Bool
  ) -> Int {
    let effectiveType: CBCharacteristicWriteType = allowLongWrite ? type : .withoutResponse
    let maxForType = peripheral.maximumWriteValueLength(for: effectiveType)
    // In order to operate the same on both iOS & Android, we enforce a
    // maximum of 512, the maxAttrLen of a characteristic in the BLE spec.
    return min(maxForType, 512)
  }

  func getMtu(_ peripheral: CBPeripheral) -> Int {
    return getMaxPayload(peripheral, type: .withoutResponse, allowLongWrite: false) + 3  // ATT overhead
  }

  /// iOS & macOS negotiate the mtu automatically sometime after the
  /// connection process, but there is no platform callback for it, and
  /// `maximumWriteValueLength` still returns the un-negotiated default at
  /// `didConnect` time. So, while any device is connected, poll for changes
  /// and emit BmMtuChangedEvent when the negotiated value appears.
  func startMtuPolling() {
    guard mtuPollTimer == nil else { return }
    mtuPollTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
      self?.checkForMtuChanges()
    }
  }

  func stopMtuPollingIfIdle() {
    if connectedPeripheralCount == 0 {
      mtuPollTimer?.invalidate()
      mtuPollTimer = nil
    }
  }

  private func checkForMtuChanges() {
    for (address, state) in peripherals where state.connection == .connected {
      let mtu = getMtu(state.peripheral)
      if state.mtu != mtu {
        state.mtu = mtu
        log(.debug, "mtu changed: \(mtu) (\(address))")
        sink?.success(BmMtuChangedEvent(address: address, mtu: Int64(mtu)))
      }
    }
    stopMtuPollingIfIdle()
  }

  func scanCountIncrement(_ remoteId: String) -> Int {
    let count = scanCounts[remoteId] ?? 0
    scanCounts[remoteId] = count + 1
    return count
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Event channel
// ─────────────────────────────────────────────────────────────────────────────

class BluebirdStreamHandler: NativeEventsStreamHandler {
  private weak var plugin: BluebirdPlugin?

  init(plugin: BluebirdPlugin) {
    self.plugin = plugin
  }

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<BmEvent>) {
    plugin?.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    plugin?.sink = nil
  }
}
