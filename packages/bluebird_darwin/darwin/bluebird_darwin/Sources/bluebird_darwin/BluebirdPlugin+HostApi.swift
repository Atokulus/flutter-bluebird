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

extension BluebirdPlugin: BluebirdHostApi {

  func flutterRestart() throws -> Int64 {
    let central = ensureCentralManager()

    if isAdapterOn {
      central.stopScan()
    }

    // all dart state is reset after a hot restart, so reset native state too
    closeAllL2cap()
    peripherals.values.forEach { $0.cancelAllPending() }
    peripherals.values.forEach { $0.clearDiscoveryState() }
    scanSettings = nil
    scanCounts.removeAll()

    // request disconnection of everything
    if isAdapterOn {
      for (address, state) in peripherals {
        if state.connection == .connected {
          log(.debug, "flutterRestart: disconnecting \(address)")
        }
        central.cancelPeripheralConnection(state.peripheral)
      }
    }

    log(.debug, "connectedPeripherals: \(connectedPeripheralCount)")

    // note: `peripherals` entries are also intentionally retained here: the
    // didDisconnectPeripheral callbacks remove them one by one, which is what
    // drives the connectedCount hot-restart handshake polled by the Dart side.
    // note: we do *not* clear knownPeripherals, otherwise the peripherals
    // would lose their last strong reference and didDisconnectPeripheral
    // would never be called
    if connectedPeripheralCount == 0 {
      knownPeripherals.removeAll()
    }

    return Int64(connectedPeripheralCount)
  }

  func connectedCount() throws -> Int64 {
    log(.debug, "connectedPeripherals: \(connectedPeripheralCount)")
    if connectedPeripheralCount == 0 {
      log(.debug, "Hot Restart: complete")
      knownPeripherals.removeAll()
    }
    return Int64(connectedPeripheralCount)
  }

  func setLogLevel(level: LogLevel) throws {
    logLevel = level
  }

  func setOptions(showPowerAlert: Bool, restoreState: Bool) throws {
    self.showPowerAlert = showPowerAlert
    self.restoreState = restoreState
  }

  func isSupported() throws -> Bool {
    ensureCentralManager()
    return centralManager != nil
  }

  func getAdapterName(completion: @escaping (Result<String, Error>) -> Void) {
    launch(completion) { [self] in
      ensureCentralManager()
      #if os(iOS)
        return UIDevice.current.name
      #else
        return Host.current().localizedName ?? "Mac Bluetooth Adapter"
      #endif
    }
  }

  func getAdapterState() throws -> BluetoothAdapterState {
    let central = ensureCentralManager()
    return bmAdapterState(central.state)
  }

  func turnOn(completion: @escaping (Result<Bool, Error>) -> Void) {
    launch(completion) {
      throw unsupportedError("iOS & macOS do not support turning on bluetooth")
    }
  }

  func turnOff(completion: @escaping (Result<Bool, Error>) -> Void) {
    launch(completion) {
      throw unsupportedError("iOS & macOS do not support turning off bluetooth")
    }
  }

  func startScan(settings: BmScanSettings, completion: @escaping (Result<Void, Error>) -> Void) {
    launch(completion) { [self] in
      let central = ensureCentralManager()

      guard isAdapterOn else {
        throw adapterOffError(central.state)
      }

      // remember this for later
      scanSettings = settings
      scanCounts.removeAll()

      var scanOpts: [String: Any] = [:]
      if settings.continuousUpdates {
        scanOpts[CBCentralManagerScanOptionAllowDuplicatesKey] = true
      }

      // If any custom filter is set then we cannot filter by services.
      // Why? An advertisement can match either the service filter *or* the
      // custom filter. It does not have to match both. So we cannot have
      // iOS & macOS filtering out any advertisements.
      var services: [CBUUID] = []
      if !ScanFilters.hasCustomFilters(settings) {
        services = settings.withServices.map { CBUUID(string: $0) }
      }

      central.scanForPeripherals(
        withServices: services.isEmpty ? nil : services, options: scanOpts)
    }
  }

  func stopScan() throws {
    ensureCentralManager().stopScan()
  }

  func getSystemDevices(
    withServices: [String], completion: @escaping (Result<[BmBluetoothDevice], Error>) -> Void
  ) {
    launch(completion) { [self] in
      let central = ensureCentralManager()
      let services = withServices.map { CBUUID(string: $0) }

      // this returns devices connected by *any* app
      let peripherals = central.retrieveConnectedPeripherals(withServices: services)

      return peripherals.map { bmBluetoothDevice($0) }
    }
  }

  func getBondedDevices(completion: @escaping (Result<[BmBluetoothDevice], Error>) -> Void) {
    launch(completion) {
      throw unsupportedError("android only")
    }
  }

  func connect(address: String, completion: @escaping (Result<Void, Error>) -> Void) {
    launch(completion) { [self] in
      let central = ensureCentralManager()

      guard isAdapterOn else {
        throw adapterOffError(central.state)
      }

      // already connected?
      if connectedPeripheral(address) != nil {
        log(.debug, "already connected")
        return
      }

      // reuse the connecting state if a connection is already in flight —
      // its occupied slot makes awaitConnect throw operation_in_progress
      let state: PeripheralState
      if let existing = peripherals[address] {
        state = existing
      } else {
        guard let uuid = UUID(uuidString: address) else {
          throw PigeonError(
            code: BluebirdErrorCode.invalidIdentifier.wire, message: "invalid remoteId",
            details: address)
        }

        // check the devices iOS knows about
        guard
          let peripheral = central.retrievePeripherals(withIdentifiers: [uuid])
            .first(where: { $0.identifier.uuidString == address })
        else {
          throw PigeonError(
            code: BluebirdErrorCode.invalidIdentifier.wire, message: "peripheral not found",
            details: address)
        }

        // we must keep a strong reference to any CBPeripheral before we connect
        // to it. CoreBluetooth does not keep strong references itself.
        knownPeripherals[address] = peripheral

        // set ourself as delegate
        peripheral.delegate = self

        state = PeripheralState(peripheral)
        peripherals[address] = state
      }

      return try await awaitConnect(state) {
        central.connect(state.peripheral, options: nil)
      }
    }
  }

  func disconnect(address: String, completion: @escaping (Result<Void, Error>) -> Void) {
    launch(completion) { [self] in
      let central = ensureCentralManager()

      // connection still in progress? cancel it
      if let state = peripherals[address], state.connection == .connecting {
        peripherals.removeValue(forKey: address)
        log(.debug, "disconnect: cancelling connection in progress")
        central.cancelPeripheralConnection(state.peripheral)

        // canceling a pending connection does not reliably invoke
        // didDisconnectPeripheral, so complete everything here
        state.takeConnect()?.resume(
          throwing: PigeonError(
            code: BluebirdErrorCode.userCanceled.wire, message: "connection canceled", details: nil))

        sink?.success(
          BmConnectionStateEvent(
            address: address,
            connectionState: .disconnected,
            disconnectReasonCode: Self.userCanceledErrorCode,
            disconnectReasonString: "connection canceled"))

        return
      }

      // already disconnected?
      guard let state = peripherals[address], state.connection == .connected else {
        log(.debug, "already disconnected")
        return
      }

      return try await awaitDisconnect(state) {
        central.cancelPeripheralConnection(state.peripheral)
      }
    }
  }

  func discoverServices(
    address: String, completion: @escaping (Result<[BmBluetoothService], Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)

      return try await awaitGatt(state, .discoverServices) {
        // reset discovery bookkeeping
        state.clearDiscoveryState()

        state.peripheral.discoverServices(nil)
      }
    }
  }

  func readCharacteristic(
    address: String,
    characteristic: BmCharacteristicRef,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)
      let peripheral = state.peripheral
      let chr = try locateCharacteristic(characteristic, in: peripheral)

      // check readable
      guard chr.properties.contains(.read) else {
        throw unsupportedError("The READ property is not supported by this BLE characteristic")
      }

      // key by the canonical ref so the delegate callback finds it
      let ref = try canonicalRef(chr, in: peripheral)

      return try await awaitGatt(state, .readChar(ref)) {
        peripheral.readValue(for: chr)
      }
    }
  }

  func writeCharacteristic(
    address: String,
    characteristic: BmCharacteristicRef,
    writeType: BmWriteType,
    allowLongWrite: Bool,
    value: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)
      let peripheral = state.peripheral

      let cbWriteType: CBCharacteristicWriteType =
        writeType == .withResponse ? .withResponse : .withoutResponse

      // check maximum payload
      let maxLen = getMaxPayload(peripheral, type: cbWriteType, allowLongWrite: allowLongWrite)
      let dataLen = value.data.count
      if dataLen > maxLen {
        let t = writeType == .withResponse ? "withResponse" : "withoutResponse"
        let a = allowLongWrite ? ", allowLongWrite" : ", noLongWrite"
        let b = writeType == .withResponse ? a : ""
        throw unsupportedError(
          "data longer than allowed. dataLen: \(dataLen) > max: \(maxLen) (\(t)\(b))")
      }

      let chr = try locateCharacteristic(characteristic, in: peripheral)

      // check writeable
      if cbWriteType == .withoutResponse {
        guard chr.properties.contains(.writeWithoutResponse) else {
          throw unsupportedError(
            "The WRITE_NO_RESPONSE property is not supported by this BLE characteristic")
        }
      } else {
        guard chr.properties.contains(.write) else {
          throw unsupportedError("The WRITE property is not supported by this BLE characteristic")
        }
      }

      if cbWriteType == .withResponse {
        // key by the canonical ref so the delegate callback finds it
        let ref = try canonicalRef(chr, in: peripheral)

        return try await awaitGatt(state, .writeChar(ref)) {
          peripheral.writeValue(value.data, for: chr, type: .withResponse)
        }
      } else {
        // Queue write commands natively. The queue drains multiple frames at
        // once while CoreBluetooth has capacity and pauses on its documented
        // canSendWriteWithoutResponse backpressure signal.
        try await enqueueWriteWithoutResponse(state, data: value.data, characteristic: chr)
      }
    }
  }

  func readDescriptor(
    address: String,
    descriptor: BmDescriptorRef,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)
      let peripheral = state.peripheral
      let desc = try locateDescriptor(descriptor, in: peripheral)

      // key by the canonical ref so the delegate callback finds it
      let ref = try canonicalRef(desc, in: peripheral)

      return try await awaitGatt(state, .readDesc(ref)) {
        peripheral.readValue(for: desc)
      }
    }
  }

  func writeDescriptor(
    address: String,
    descriptor: BmDescriptorRef,
    value: FlutterStandardTypedData,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)
      let peripheral = state.peripheral

      // check mtu
      let mtu = getMtu(peripheral)
      let dataLen = value.data.count
      if (mtu - 3) < dataLen {
        throw unsupportedError(
          "data is longer than MTU allows. dataLen: \(dataLen) > maxDataLen: \(mtu - 3)")
      }

      let desc = try locateDescriptor(descriptor, in: peripheral)

      // key by the canonical ref so the delegate callback finds it
      let ref = try canonicalRef(desc, in: peripheral)

      return try await awaitGatt(state, .writeDesc(ref)) {
        peripheral.writeValue(value.data, for: desc)
      }
    }
  }

  func setNotifyValue(
    address: String,
    characteristic: BmCharacteristicRef,
    enable: Bool,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)
      let peripheral = state.peripheral
      let chr = try locateCharacteristic(characteristic, in: peripheral)

      // check notify-able
      let canNotify = chr.properties.contains(.notify)
      let canIndicate = chr.properties.contains(.indicate)
      guard canNotify || canIndicate else {
        throw unsupportedError(
          "neither NOTIFY nor INDICATE properties are supported by this BLE characteristic")
      }

      // check that the CCCD is present — necessary for subscribing
      let cccd = CBUUID(string: CBUUIDClientCharacteristicConfigurationString)
      if !(chr.descriptors?.contains(where: { $0.uuid == cccd }) ?? false) {
        log(
          .warning,
          "Warning: CCCD descriptor for characteristic not found: \(chr.uuid.uuidStr)")
      }

      // key by the canonical ref so the delegate callback finds it
      let ref = try canonicalRef(chr, in: peripheral)

      return try await awaitGatt(state, .setNotify(ref)) {
        peripheral.setNotifyValue(enable, for: chr)
      }
    }
  }

  func requestMtu(
    address: String, mtu: Int64, completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    launch(completion) {
      throw unsupportedError("iOS & macOS do not allow mtu requests to the peripheral")
    }
  }

  func readRssi(address: String, completion: @escaping (Result<Int64, Error>) -> Void) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)

      return try await awaitGatt(state, .readRssi) {
        state.peripheral.readRSSI()
      }
    }
  }

  func requestConnectionPriority(
    address: String, connectionPriority: ConnectionPriority
  ) throws {
    throw unsupportedError("android only")
  }

  func getPhySupport() throws -> BmPhySupport {
    throw unsupportedError("android only")
  }

  func setPreferredPhy(
    address: String, txPhy: Int64, rxPhy: Int64, phyOptions: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    launch(completion) {
      throw unsupportedError("android only")
    }
  }

  func getBondState(address: String) throws -> BluetoothBondState {
    throw unsupportedError("android only")
  }

  func createBond(
    address: String, pin: FlutterStandardTypedData?,
    completion: @escaping (Result<Bool, Error>) -> Void
  ) {
    launch(completion) {
      throw unsupportedError("android only")
    }
  }

  func removeBond(address: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    launch(completion) {
      throw unsupportedError("android only")
    }
  }

  func clearGattCache(address: String, completion: @escaping (Result<Void, Error>) -> Void) {
    launch(completion) {
      throw unsupportedError("android only")
    }
  }

  func openL2capChannel(
    address: String, psm: Int64, secure: Bool,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    launch(completion) { [self] in
      ensureCentralManager()

      let state = try requireConnectedState(address)

      guard psm > 0, psm <= 0xFFFF else {
        throw PigeonError(
          code: BluebirdErrorCode.invalidArgument.wire, message: "psm out of range: \(psm)",
          details: nil)
      }

      // `secure` is Android-only; CoreBluetooth derives channel security from
      // the PSM, so it is intentionally ignored here.
      let cbChannel = try await awaitL2capOpen(state) {
        state.peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
      }

      // a disconnect during the open would have failed the slot; still, guard
      guard peripherals[address]?.connection == .connected else {
        throw deviceDisconnectedError()
      }

      return registerL2capChannel(address, cbChannel)
    }
  }

  func closeL2capChannel(channelId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    launch(completion) { [self] in
      closeL2capSolicited(channelId)
    }
  }
}
