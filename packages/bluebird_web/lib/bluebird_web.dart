import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' show Event;

import 'src/html.dart';
import 'src/web_bluetooth.dart';

/// Web implementation of the bluebird platform interface, backed by the
/// [Web Bluetooth API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API).
///
/// ## Scanning
///
/// Web Bluetooth has NO passive scan. There is no way to observe advertisements
/// from arbitrary nearby devices. The only entry point is
/// `navigator.bluetooth.requestDevice(...)`, which shows a browser-controlled
/// device chooser and returns exactly ONE device that the user picks. As a
/// result [startScan] triggers the chooser and, when a device is selected,
/// emits a single [BmScanAdvertisementEvent] carrying one advertisement for
/// that device. The advertisement is minimal — the API exposes almost no
/// advertising data, so rssi is reported as `0` and the service/manufacturer
/// data maps are empty. If the user dismisses the chooser, a
/// [BmScanFailedEvent] is emitted instead. [stopScan] is a no-op (there is no
/// ongoing scan to cancel).
///
/// ## Typed-ref resolution
///
/// Web Bluetooth has no attribute instance-id concept. To honor the platform
/// interface's `BmAttributeId { uuid, instance }` refs, [discoverServices]
/// enumerates services (and their characteristics/descriptors) and builds a
/// per-device cache. Each attribute is assigned an `instance` equal to its
/// index among same-uuid siblings (in discovery order). The `BmBluetoothService`
/// tree returned to the app is numbered identically, so the refs the app later
/// sends back can be resolved by matching (service uuid + instance,
/// characteristic uuid + instance).
///
/// ## Unsupported operations
///
/// Web Bluetooth cannot do: read RSSI, request/observe MTU, bonding, PHY,
/// clear GATT cache, enumerate system/bonded devices, or turn the adapter
/// on/off. Those methods are intentionally NOT overridden and fall through to
/// the base class, which throws [UnimplementedError].
final class BluebirdWeb extends BluebirdPlatform {
  static void registerWith(Registrar registrar) {
    BluebirdPlatform.instance = BluebirdWeb();
  }

  final _events = StreamController<BmEvent>.broadcast();

  @override
  Stream<BmEvent> get events => _events.stream;

  /// Devices we have obtained handles to, keyed by address (== `device.id`).
  final _devices = <String, BluetoothDevice>{};

  /// Per-device attribute cache, populated by [discoverServices]. Holds the
  /// live JS handles alongside the instance numbering we exposed to the app so
  /// that refs can be resolved back to handles.
  final _caches = <String, _DeviceCache>{};

  /// Reverse map from a live JS characteristic to the ref we handed the app,
  /// used to label incoming notifications. Keyed by identity via a wrapper.
  final _charRefs = <BluetoothRemoteGATTCharacteristic, BmCharacteristicRef>{};

  /// Programmatic disconnects awaiting the browser's asynchronous
  /// `gattserverdisconnected` event, keyed by address. [disconnect] does not
  /// return until the corresponding event has been handled, so a delayed event
  /// can never straggle past a subsequent reconnect.
  final _pendingDisconnects = <String, Completer<void>>{};

  /// Browser GATT implementations allow only one operation at a time. Keep a
  /// per-device command chain so an entire Dart burst is already queued here
  /// and each promise can start the next write without a Flutter round trip.
  final _writeCommandTails = <String, Future<void>>{};

  late final _characteristicValueChangedListener = _handleCharacteristicValueChanged.toJS;
  late final _gattServerDisconnectedListener = _handleGattServerDisconnected.toJS;

  BluetoothRemoteGATTServer _gattForDevice(String address) {
    final device = _devices[address];
    if (device == null) {
      throw StateError('The device "$address" could not be found.');
    }
    final gatt = device.gatt;
    if (gatt == null) {
      throw StateError('The gatt for the device "$address" is null.');
    }
    return gatt;
  }

  _DeviceCache _cacheForDevice(String address) {
    final cache = _caches[address];
    if (cache == null) {
      throw StateError('Services have not been discovered for device "$address".');
    }
    return cache;
  }

  @override
  Future<bool> isSupported() async {
    try {
      return (await window.navigator.bluetooth.getAvailability().toDart).toDart;
    } catch (e) {
      // https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API#browser_compatibility
      return false;
    }
  }

  @override
  Future<BluetoothAdapterState> getAdapterState() async =>
      (await isSupported()) ? BluetoothAdapterState.on : BluetoothAdapterState.unavailable;

  @override
  Future<void> startScan(BmScanSettings settings) async {
    final filters = <BluetoothLEScanFilterInit>[
      for (final service in settings.withServices)
        BluetoothLEScanFilterInit(services: [Uuid(service).string128.toJS].toJS),
      for (final name in settings.withNames) BluetoothLEScanFilterInit(name: name),
    ];

    final options = filters.isNotEmpty
        ? RequestDeviceOptions(
            filters: filters.toJS,
            optionalServices: settings.webOptionalServices.map((e) => Uuid(e).string128.toJS).toList().toJS,
          )
        : RequestDeviceOptions(
            // https://developer.mozilla.org/en-US/docs/Web/API/Bluetooth/requestDevice#acceptalldevices
            acceptAllDevices: true,
            optionalServices: settings.webOptionalServices.map((e) => Uuid(e).string128.toJS).toList().toJS,
          );

    final BluetoothDevice device;
    try {
      device = await window.navigator.bluetooth.requestDevice(options).toDart;
    } catch (e) {
      // The user dismissed the chooser (NotFoundError) or the request was
      // otherwise rejected. Web Bluetooth surfaces this as a thrown DOMException.
      _events.add(
        BmScanFailedEvent(
          errorCode: BluebirdErrorCode.userCanceled.index,
          errorString: 'The device chooser was dismissed: $e',
        ),
      );
      return;
    }

    _devices[device.address] = device;

    // Listen for spontaneous disconnects on this device.
    device.removeEventListener('gattserverdisconnected', _gattServerDisconnectedListener);
    device.addEventListener('gattserverdisconnected', _gattServerDisconnectedListener);

    _events.add(
      BmScanAdvertisementEvent(
        advertisement: BmScanAdvertisement(
          address: device.address,
          platformName: device.name,
          advName: null,
          connectable: true,
          txPowerLevel: null,
          appearance: null,
          manufacturerData: {},
          serviceData: {},
          serviceUuids: [],
          rssi: 0,
        ),
      ),
    );
  }

  @override
  Future<void> stopScan() async {
    // Web Bluetooth has no ongoing scan to stop; the chooser is modal and
    // resolves synchronously with the user's choice.
  }

  @override
  Future<void> connect(String address) async {
    final gatt = _gattForDevice(address);
    await gatt.connect().toDart;

    _events.add(BmConnectionStateEvent(address: address, connectionState: BluetoothConnectionState.connected));
  }

  @override
  Future<void> disconnect(String address) async {
    final gatt = _gattForDevice(address);

    // Web Bluetooth dispatches `gattserverdisconnected` asynchronously (on a
    // later task) in response to `disconnect()`. We treat that event as the
    // single source of truth for the disconnected state and don't return until
    // it has been handled — this guarantees a delayed event can't straggle past
    // a subsequent rapid reconnect and tear the new connection down.
    //
    // The event only fires if the GATT server was actually connected; if it
    // isn't, there is nothing to await, so emit the disconnected state directly.
    if (!gatt.connected) {
      _handleDisconnected(address);
      return;
    }

    final completer = Completer<void>();
    _pendingDisconnects[address] = completer;
    gatt.disconnect();

    // Fall back to emitting the disconnected state ourselves if the browser
    // never delivers the event, so callers are never left hanging.
    await completer.future.timeout(const Duration(seconds: 5), onTimeout: () => _handleDisconnected(address));
  }

  @override
  Future<List<BmBluetoothService>> discoverServices(String address) async {
    final gatt = _gattForDevice(address);

    // Drop any stale cache/notification handles before rebuilding.
    _clearDeviceCache(address);

    final cache = _DeviceCache();
    _caches[address] = cache;

    final services = <BmBluetoothService>[];

    final primaryServices = (await gatt.getPrimaryServices().toDart).toDart;

    // instance = index among same-uuid siblings, in discovery order.
    final serviceUuidCounts = <Uuid, int>{};

    for (final jsService in primaryServices) {
      final serviceUuid = Uuid(jsService.uuid);
      final serviceInstance = serviceUuidCounts[serviceUuid] ?? 0;
      serviceUuidCounts[serviceUuid] = serviceInstance + 1;

      final cachedService = _CachedService(handle: jsService, uuid: serviceUuid, instance: serviceInstance);
      cache.services.add(cachedService);

      final serviceRef = BmServiceRef(
        service: BmAttributeId(uuid: serviceUuid.string, instance: serviceInstance),
      );

      final characteristics = <BmBluetoothCharacteristic>[];

      final jsChars = (await jsService.getCharacteristics().toDart).toDart;
      final charUuidCounts = <Uuid, int>{};

      for (final jsChar in jsChars) {
        final charUuid = Uuid(jsChar.uuid);
        final charInstance = charUuidCounts[charUuid] ?? 0;
        charUuidCounts[charUuid] = charInstance + 1;

        cachedService.characteristics.add(
          _CachedCharacteristic(handle: jsChar, uuid: charUuid, instance: charInstance),
        );

        final charRef = BmCharacteristicRef(
          service: serviceRef,
          characteristic: BmAttributeId(uuid: charUuid.string, instance: charInstance),
        );
        _charRefs[jsChar] = charRef;

        final descriptors = <BmBluetoothDescriptor>[];
        try {
          final jsDescs = (await jsChar.getDescriptors().toDart).toDart;
          for (final jsDesc in jsDescs) {
            descriptors.add(BmBluetoothDescriptor(id: BmAttributeId(uuid: Uuid(jsDesc.uuid).string, instance: 0)));
          }
        } catch (e) {
          // getDescriptors throws if there are none / access is disallowed.
        }

        final props = jsChar.properties;
        characteristics.add(
          BmBluetoothCharacteristic(
            id: BmAttributeId(uuid: charUuid.string, instance: charInstance),
            descriptors: descriptors,
            properties: BmCharacteristicProperties(
              broadcast: props.broadcast,
              read: props.read,
              writeWithoutResponse: props.writeWithoutResponse,
              write: props.write,
              notify: props.notify,
              indicate: props.indicate,
              authenticatedSignedWrites: props.authenticatedSignedWrites,
              extendedProperties: false,
              notifyEncryptionRequired: false,
              indicateEncryptionRequired: false,
            ),
          ),
        );
      }

      services.add(
        BmBluetoothService(
          id: BmAttributeId(uuid: serviceUuid.string, instance: serviceInstance),
          isPrimary: jsService.isPrimary,
          characteristics: characteristics,
          // Web Bluetooth exposes included services via getIncludedServices(),
          // but the app model reaches them through the primary tree; we leave
          // this empty (included-service enumeration is not supported here).
          includedServices: [],
        ),
      );
    }

    return services;
  }

  @override
  Future<Uint8List> readCharacteristic(String address, BmCharacteristicRef characteristic) async {
    final jsChar = _resolveCharacteristic(address, characteristic);
    final value = (await jsChar.readValue().toDart).toDart;
    return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
  }

  @override
  Future<void> writeCharacteristic(
    String address,
    BmCharacteristicRef characteristic,
    BmWriteType writeType,
    bool allowLongWrite,
    Uint8List value,
  ) async {
    final jsChar = _resolveCharacteristic(address, characteristic);
    if (writeType == BmWriteType.withResponse) {
      await jsChar.writeValueWithResponse(value.toJS).toDart;
    } else {
      final previous = _writeCommandTails[address] ?? Future<void>.value();
      final operation = previous.then(
        (_) => jsChar.writeValueWithoutResponse(value.toJS).toDart,
        onError: (_, _) => jsChar.writeValueWithoutResponse(value.toJS).toDart,
      );
      final tail = operation.then<void>((_) {}, onError: (_, _) {});
      _writeCommandTails[address] = tail;
      tail.then((_) {
        if (identical(_writeCommandTails[address], tail)) {
          _writeCommandTails.remove(address);
        }
      });
      await operation;
    }
  }

  @override
  Future<Uint8List> readDescriptor(String address, BmDescriptorRef descriptor) async {
    final jsDesc = await _resolveDescriptor(address, descriptor);
    final value = (await jsDesc.readValue().toDart).toDart;
    return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
  }

  @override
  Future<void> writeDescriptor(String address, BmDescriptorRef descriptor, Uint8List value) async {
    final jsDesc = await _resolveDescriptor(address, descriptor);
    await jsDesc.writeValue(value.toJS).toDart;
  }

  @override
  Future<bool> setNotifyValue(String address, BmCharacteristicRef characteristic, bool enable) async {
    final jsChar = _resolveCharacteristic(address, characteristic);
    if (enable) {
      jsChar.addEventListener('characteristicvaluechanged', _characteristicValueChangedListener);
      await jsChar.startNotifications().toDart;
    } else {
      await jsChar.stopNotifications().toDart;
      jsChar.removeEventListener('characteristicvaluechanged', _characteristicValueChangedListener);
    }
    return true;
  }

  // --- ref resolution -------------------------------------------------------

  BluetoothRemoteGATTCharacteristic _resolveCharacteristic(String address, BmCharacteristicRef ref) {
    final cache = _cacheForDevice(address);

    final serviceId = ref.service.service;
    final cachedService = cache.services.firstWhere(
      (s) => s.uuid == Uuid(serviceId.uuid) && s.instance == serviceId.instance,
      orElse: () => throw StateError('Service ${serviceId.uuid}#${serviceId.instance} not found for "$address".'),
    );

    final charId = ref.characteristic;
    final cachedChar = cachedService.characteristics.firstWhere(
      (c) => c.uuid == Uuid(charId.uuid) && c.instance == charId.instance,
      orElse: () => throw StateError('Characteristic ${charId.uuid}#${charId.instance} not found for "$address".'),
    );

    return cachedChar.handle;
  }

  Future<BluetoothRemoteGATTDescriptor> _resolveDescriptor(String address, BmDescriptorRef ref) async {
    final jsChar = _resolveCharacteristic(address, ref.characteristic);
    return await jsChar.getDescriptor(Uuid(ref.id.uuid).string128.toJS).toDart;
  }

  // --- event handlers -------------------------------------------------------

  void _handleCharacteristicValueChanged(Event event) {
    final jsChar = event.target as BluetoothRemoteGATTCharacteristic;
    final ref = _charRefs[jsChar];
    if (ref == null) {
      // We received a notification for a characteristic we have no ref for
      // (e.g. after a cache reset). Nothing meaningful we can label it with.
      return;
    }

    final address = jsChar.service.device.address;
    final data = jsChar.value?.toDart;
    final value = data == null ? Uint8List(0) : data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    _events.add(BmCharacteristicNotificationEvent(address: address, characteristic: ref, value: value));
  }

  void _handleGattServerDisconnected(Event event) {
    final device = event.target as BluetoothDevice;
    _handleDisconnected(device.address);
  }

  /// Applies the disconnected state for [address]: drops the attribute cache,
  /// emits the connection-state event, and completes any [disconnect] that is
  /// waiting on the browser's `gattserverdisconnected` event. This is the sole
  /// emitter of the disconnected state, so it fires exactly once per teardown
  /// whether the disconnect was programmatic or spontaneous.
  void _handleDisconnected(String address) {
    _clearDeviceCache(address);

    _events.add(BmConnectionStateEvent(address: address, connectionState: BluetoothConnectionState.disconnected));

    _pendingDisconnects.remove(address)?.complete();
  }

  void _clearDeviceCache(String address) {
    final cache = _caches.remove(address);
    if (cache == null) return;
    for (final service in cache.services) {
      for (final char in service.characteristics) {
        _charRefs.remove(char.handle);
      }
    }
  }
}

/// Per-device discovered-attribute cache used for ref resolution.
class _DeviceCache {
  final List<_CachedService> services = [];
}

class _CachedService {
  _CachedService({required this.handle, required this.uuid, required this.instance});

  final BluetoothRemoteGATTService handle;
  final Uuid uuid;
  final int instance;
  final List<_CachedCharacteristic> characteristics = [];
}

class _CachedCharacteristic {
  _CachedCharacteristic({required this.handle, required this.uuid, required this.instance});

  final BluetoothRemoteGATTCharacteristic handle;
  final Uuid uuid;
  final int instance;
}

extension on BluetoothDevice {
  /// Web Bluetooth's stable per-origin device identifier, used as the address.
  String get address => id;
}
