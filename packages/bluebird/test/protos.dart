import 'dart:typed_data';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';

/// Test factories for the generated wire types, so tests read as intent
/// rather than constructor boilerplate.

BmAttributeId attr(String uuid, [int instance = 0]) => BmAttributeId(uuid: Uuid(uuid).string, instance: instance);

BmCharacteristicProperties props({
  bool read = false,
  bool write = false,
  bool writeWithoutResponse = false,
  bool notify = false,
  bool indicate = false,
}) => BmCharacteristicProperties(
  broadcast: false,
  read: read,
  writeWithoutResponse: writeWithoutResponse,
  write: write,
  notify: notify,
  indicate: indicate,
  authenticatedSignedWrites: false,
  extendedProperties: false,
  notifyEncryptionRequired: false,
  indicateEncryptionRequired: false,
);

BmBluetoothCharacteristic bmChar(
  String uuid, {
  int instance = 0,
  List<String> descriptors = const [],
  BmCharacteristicProperties? properties,
}) => BmBluetoothCharacteristic(
  id: attr(uuid, instance),
  descriptors: [for (final d in descriptors) BmBluetoothDescriptor(id: attr(d))],
  properties: properties ?? props(read: true),
);

BmBluetoothService bmService(
  String uuid, {
  int instance = 0,
  bool isPrimary = true,
  List<BmBluetoothCharacteristic> characteristics = const [],
  List<BmServiceRef> includedServices = const [],
}) => BmBluetoothService(
  id: attr(uuid, instance),
  isPrimary: isPrimary,
  characteristics: characteristics,
  includedServices: includedServices,
);

BmScanAdvertisement bmAdv(
  String address, {
  String? advName,
  String? platformName,
  int rssi = -50,
  bool connectable = true,
  Map<int, Uint8List> manufacturerData = const {},
  Map<String, Uint8List> serviceData = const {},
  List<String> serviceUuids = const [],
}) => BmScanAdvertisement(
  address: address,
  advName: advName,
  platformName: platformName,
  connectable: connectable,
  manufacturerData: manufacturerData,
  serviceData: serviceData,
  serviceUuids: serviceUuids,
  rssi: rssi,
);
