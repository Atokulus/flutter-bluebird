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

extension BluebirdPlugin: CBPeripheralDelegate {

  // ───────────────────────────────────────────────────────────────────────────
  // CBPeripheralDelegate — service discovery
  // ───────────────────────────────────────────────────────────────────────────

  /// Handles the error case shared by all discovery callbacks: logs, resets
  /// discovery bookkeeping, and fails the pending discoverServices call.
  /// Returns true if an error was handled.
  private func failDiscoveryIfNeeded(_ name: String, _ address: String, _ error: Error?) -> Bool {
    guard let error else { return false }
    log(.error, "\(name): \(error.localizedDescription)")
    if let state = peripherals[address] {
      state.clearDiscoveryState()
      state.takeGatt { $0 == .discoverServices }?.continuation.resume(throwing: cbError(error))
    }
    return true
  }

  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverServices", address, error) { return }
    log(.debug, "didDiscoverServices")

    guard let state = peripherals[address] else { return }

    let services = peripheral.services ?? []
    state.discoveredServices = services
    state.servicesToDiscover = services
    state.characteristicsToDiscover = []

    // discover characteristics and included services
    for service in services {
      log(.debug, "  svc: \(service.uuid.uuidStr)")
      peripheral.discoverIncludedServices(nil, for: service)
      peripheral.discoverCharacteristics(nil, for: service)
    }

    maybeCompleteDiscovery(peripheral)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverIncludedServicesFor service: CBService,
    error: Error?
  ) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverIncludedServicesForService", address, error) { return }
    log(.debug, "didDiscoverIncludedServicesForService: \(service.uuid.uuidStr)")

    guard let state = peripherals[address] else { return }

    for included in service.includedServices ?? [] {
      log(.debug, "    svc: \(included.uuid.uuidStr)")

      // don't try to discover services we already know about
      if state.discoveredServices.contains(where: { $0 === included }) {
        continue
      }

      state.discoveredServices.append(included)
      state.servicesToDiscover.append(included)
      peripheral.discoverCharacteristics(nil, for: included)
      peripheral.discoverIncludedServices(nil, for: included)
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverCharacteristicsForService", address, error) { return }
    log(.debug, "didDiscoverCharacteristicsForService: \(service.uuid.uuidStr)")

    guard let state = peripherals[address] else { return }
    state.servicesToDiscover.removeAll { $0 === service }

    // loop through and discover descriptors for characteristics
    let characteristics = service.characteristics ?? []
    state.characteristicsToDiscover.append(contentsOf: characteristics)
    for characteristic in characteristics {
      log(.debug, "    chr: \(characteristic.uuid.uuidStr)")
      peripheral.discoverDescriptors(for: characteristic)
    }

    maybeCompleteDiscovery(peripheral)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverDescriptorsFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let address = peripheral.identifier.uuidString

    if failDiscoveryIfNeeded("didDiscoverDescriptorsForCharacteristic", address, error) { return }
    log(.debug, "didDiscoverDescriptorsForCharacteristic: \(characteristic.uuid.uuidStr)")

    guard let state = peripherals[address] else { return }
    state.characteristicsToDiscover.removeAll { $0 === characteristic }

    maybeCompleteDiscovery(peripheral)
  }

  /// Resumes the pending discoverServices call once every service has
  /// reported its characteristics and every characteristic its descriptors.
  private func maybeCompleteDiscovery(_ peripheral: CBPeripheral) {
    let address = peripheral.identifier.uuidString

    guard let state = peripherals[address],
      state.servicesToDiscover.isEmpty,
      state.characteristicsToDiscover.isEmpty
    else { return }

    state.takeGatt { $0 == .discoverServices }?.continuation.resume(
      returning: state.discoveredServices.map { bmBluetoothService($0, in: peripheral) })
  }

  // ───────────────────────────────────────────────────────────────────────────
  // CBPeripheralDelegate — GATT operations
  // ───────────────────────────────────────────────────────────────────────────

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // this callback is shared by manual reads and notifications
    logResult("didUpdateValueForCharacteristic", error, characteristic.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = characteristicRef(for: characteristic, in: peripheral) else { return }

    // a pending read consumes this callback as the read response
    let wasPendingRead = completeGatt(
      peripherals[address], matching: { $0 == .readChar(ref) }, error: error,
      success: FlutterStandardTypedData(bytes: characteristic.value ?? Data()))

    if !wasPendingRead && error == nil {
      // otherwise it's a notification / indication
      sink?.success(
        BmCharacteristicNotificationEvent(
          address: address,
          characteristic: ref,
          value: FlutterStandardTypedData(bytes: characteristic.value ?? Data())))
    }
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    // note: this callback is only called for writeWithResponse
    logResult("didWriteValueForCharacteristic", error, characteristic.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = characteristicRef(for: characteristic, in: peripheral) else { return }

    completeGatt(
      peripherals[address], matching: { $0 == .writeChar(ref) }, error: error, success: () as Any)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    logResult("didUpdateNotificationStateForCharacteristic", error, characteristic.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = characteristicRef(for: characteristic, in: peripheral) else { return }

    completeGatt(
      peripherals[address], matching: { $0 == .setNotify(ref) }, error: error,
      success: characteristic.isNotifying)
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    logResult("didUpdateValueForDescriptor", error, descriptor.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = descriptorRef(for: descriptor, in: peripheral) else { return }

    completeGatt(
      peripherals[address], matching: { $0 == .readDesc(ref) }, error: error,
      success: FlutterStandardTypedData(bytes: descriptorValueData(descriptor)))
  }

  public func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor descriptor: CBDescriptor,
    error: Error?
  ) {
    logResult("didWriteValueForDescriptor", error, descriptor.uuid.uuidStr)

    let address = peripheral.identifier.uuidString
    guard let ref = descriptorRef(for: descriptor, in: peripheral) else { return }

    completeGatt(
      peripherals[address], matching: { $0 == .writeDesc(ref) }, error: error, success: () as Any)
  }

  public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    logResult("didReadRSSI", error, "\(RSSI)")

    let address = peripheral.identifier.uuidString
    completeGatt(
      peripherals[address], matching: { $0 == .readRssi }, error: error,
      success: Int64(truncating: RSSI))
  }

  public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
    log(.debug, "didUpdateName: \(peripheral.name ?? "")")
    sink?.success(
      BmNameChangedEvent(
        address: peripheral.identifier.uuidString,
        name: peripheral.name ?? ""))
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]
  ) {
    log(.debug, "didModifyServices")
    sink?.success(BmServicesResetEvent(address: peripheral.identifier.uuidString))
  }

  public func peripheral(
    _ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?
  ) {
    logResult("didOpenL2CAPChannel", error, channel.map { "psm \($0.psm)" } ?? "")

    let address = peripheral.identifier.uuidString
    guard let cont = peripherals[address]?.takeL2capOpen() else { return }

    if let error = error {
      cont.resume(throwing: cbError(error))
    } else if let channel = channel {
      cont.resume(returning: channel)
    } else {
      cont.resume(
        throwing: PigeonError(
          code: BluebirdErrorCode.darwinError.wire, message: "openL2CAPChannel returned no channel",
          details: nil))
    }
  }

  public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    log(.verbose, "peripheralIsReadyToSendWriteWithoutResponse")
    if let state = peripherals[peripheral.identifier.uuidString] {
      drainWritesWithoutResponse(state)
    }
  }
}
