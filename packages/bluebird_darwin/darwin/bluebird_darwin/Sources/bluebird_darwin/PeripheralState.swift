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

/// One case per kind of in-flight GATT operation. Operations that target an
/// attribute carry its canonical ref, because CoreBluetooth correlates
/// delegate callbacks by attribute only.
enum GattOp: Equatable {
  case readChar(BmCharacteristicRef)
  case writeChar(BmCharacteristicRef)
  case setNotify(BmCharacteristicRef)
  case readDesc(BmDescriptorRef)
  case writeDesc(BmDescriptorRef)
  case discoverServices
  case readRssi
}

/// The in-flight GATT operation of a device: which kind it is (so delegate
/// callbacks can match it) and the continuation to resume with its result.
struct PendingGatt {
  let kind: GattOp
  let continuation: CheckedContinuation<Any?, Error>
}

/// One queued ATT Write Command. CoreBluetooth provides no per-command
/// callback, so completion means that the bytes were accepted by its buffer.
struct PendingWriteWithoutResponse {
  let data: Data
  let characteristic: CBCharacteristic
  let continuation: CheckedContinuation<Void, Error>
}

/// Per-device state for a peripheral we are connecting to or connected to.
/// Mirrors the Android side's DeviceConnection.
final class PeripheralState {
  enum Connection { case connecting, connected }

  let peripheral: CBPeripheral
  var connection: Connection = .connecting

  /// last observed mtu (see checkForMtuChanges)
  var mtu = 23

  // service discovery bookkeeping
  var discoveredServices: [CBService] = []
  var servicesToDiscover: [CBService] = []
  var characteristicsToDiscover: [CBCharacteristic] = []

  // In-flight operations, one slot per concurrency class. CoreBluetooth
  // correlates results only by attribute on a shared delegate, and the Dart
  // layer serializes operations, so a single in-flight GATT slot suffices;
  // `kind` lets delegate callbacks match (e.g. a notification must not
  // resume a pending read). The take* helpers clear a slot before resuming
  // it, guaranteeing exactly-once resumption.
  var pendingConnect: CheckedContinuation<Void, Error>?
  var pendingDisconnect: CheckedContinuation<Void, Error>?
  var pendingGatt: PendingGatt?

  /// Pending write commands. They are drained in order until CoreBluetooth's
  /// per-peripheral buffer applies backpressure.
  var pendingWritesWithoutResponse: [PendingWriteWithoutResponse] = []

  /// An in-flight `openL2capChannel`, resumed by `peripheral(_:didOpen:error:)`.
  /// The Dart layer serializes operations, so at most one is ever parked here.
  var pendingL2capOpen: CheckedContinuation<CBL2CAPChannel, Error>?

  init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }

  func clearDiscoveryState() {
    discoveredServices = []
    servicesToDiscover = []
    characteristicsToDiscover = []
  }

  /// Removes and returns the pending GATT operation, if any, but only if
  /// `matching` accepts its kind.
  func takeGatt(matching: (GattOp) -> Bool = { _ in true }) -> PendingGatt? {
    guard let pending = pendingGatt, matching(pending.kind) else { return nil }
    pendingGatt = nil
    return pending
  }

  /// Removes and returns the pending connect continuation, if any.
  func takeConnect() -> CheckedContinuation<Void, Error>? {
    defer { pendingConnect = nil }
    return pendingConnect
  }

  /// Removes and returns the pending disconnect continuation, if any.
  func takeDisconnect() -> CheckedContinuation<Void, Error>? {
    defer { pendingDisconnect = nil }
    return pendingDisconnect
  }

  /// Removes and returns the L2CAP-open continuation, if any.
  func takeL2capOpen() -> CheckedContinuation<CBL2CAPChannel, Error>? {
    defer { pendingL2capOpen = nil }
    return pendingL2capOpen
  }

  /// Fails every pending operation on this device (device disconnected or
  /// adapter turned off).
  func failAllPending(_ error: Error) {
    takeGatt()?.continuation.resume(throwing: error)
    takeConnect()?.resume(throwing: error)
    takeDisconnect()?.resume(throwing: error)
    let writes = pendingWritesWithoutResponse
    pendingWritesWithoutResponse.removeAll(keepingCapacity: true)
    for write in writes { write.continuation.resume(throwing: error) }
    takeL2capOpen()?.resume(throwing: error)
  }

  /// Hot restart / engine detach: resumes every slot with CancellationError
  /// so the launch wrapper drops the pigeon completion without invoking it
  /// (the dart side no longer exists).
  func cancelAllPending() {
    failAllPending(CancellationError())
  }
}
