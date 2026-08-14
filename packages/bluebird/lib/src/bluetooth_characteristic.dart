// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'bluebird.dart';
import 'bluetooth_attribute.dart';
import 'bluetooth_descriptor.dart';
import 'bluetooth_events.dart';
import 'bluetooth_service.dart';

class BluetoothCharacteristic extends BluetoothAttribute {
  final BluetoothService service;
  final CharacteristicProperties properties;
  late final List<BluetoothDescriptor> descriptors;

  @internal
  BluetoothCharacteristic.fromProto(BmBluetoothCharacteristic p, this.service)
    : properties = p.properties,
      super(device: service.device, id: BluetoothAttributeId.fromBm(p.id)) {
    descriptors = p.descriptors.map((d) => BluetoothDescriptor.fromProto(d, this)).toList();
  }

  @override
  @internal
  String get typeLabel => 'BluetoothCharacteristic';

  @override
  String get logPath => "${service.logPath}[$id]";

  @internal
  BmCharacteristicRef get bm => BmCharacteristicRef(service: service.bm, characteristic: id.bm);

  /// Whether [read] is supported.
  bool get canRead => properties.read;

  /// Whether [write] is supported, in either form (with or without response).
  bool get canWrite => properties.write || properties.writeWithoutResponse;

  /// Whether [notifications] are supported, via either notify or indicate.
  bool get canNotify => properties.notify || properties.indicate;

  /// Active notify subscribers — [notifications] listeners plus live [subscribe]
  /// handles. Notify is enabled on 0→1 and disabled on 1→0.
  int _notifyRefs = 0;

  /// The shared "enable notify" future for the current subscribers, so they all
  /// succeed or fail together. Null while nothing is subscribed.
  Future<void>? _notifyEnable;

  /// The values received via notify/indicate, *without* enabling notify —
  /// observe passively (e.g. when notify is kept on separately via [subscribe]).
  /// Broadcast. See [notifications] to enable notify while listening.
  Stream<List<int>> get notificationsPassive =>
      Bluebird.extractEventStream<OnCharacteristicNotifiedEvent>((e) => e.characteristic == this).map((e) => e.value);

  /// [notificationsPassive] with notify enabled for the duration of the
  /// subscription.
  ///   - enabled on the first listener (ref-counted across [notifications],
  ///     [values] and [subscribe]), disabled when the last cancels; the stream
  ///     *errors* if enabling fails (e.g. the peripheral rejects the CCCD write).
  ///   - broadcast: several concurrent listeners share one notify enable. After
  ///     an enable failure the next listen (once all have cancelled) retries.
  late final Stream<List<int>> notifications = _subscribed(notificationsPassive);

  /// All values observed for this characteristic — [read] results *and*
  /// notify/indicate values — *without* enabling notify. Broadcast.
  Stream<List<int>> get valuesPassive =>
      Bluebird.extractEventStream<OnCharacteristicValueEvent>((e) => e.characteristic == this).map((e) => e.value);

  /// [valuesPassive] with notify enabled while listened to (same ref-count /
  /// error / broadcast semantics as [notifications]).
  late final Stream<List<int>> values = _subscribed(valuesPassive);

  /// [source] behind a broadcast stream that holds a [subscribe] handle for as
  /// long as it has listeners: the first listener enables notify, the last to
  /// cancel disables it, and listeners in between share the one enable.
  ///
  /// An enable failure is surfaced to whoever is listening; a disable failure on
  /// teardown is swallowed (logged) because a cancel() must not throw, and it is
  /// harmless anyway (notify resets on disconnect). Callers who must observe a
  /// disable failure should use [subscribe] / [CharacteristicSubscription.unsubscribe].
  Stream<List<int>> _subscribed(Stream<List<int>> source) {
    StreamSubscription<List<int>>? streamSubscription;
    // The in-flight/held subscribe() while listeners are present; null when idle.
    // onCancel awaits it so a listener that leaves mid-enable still releases the
    // ref, and a failed enable (subscribe() self-releases) is caught, not double
    // released.
    Future<CharacteristicSubscription>? gattSubscription;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>.broadcast(
      onListen: () {
        // The passive source stays silent until notify is enabled, so pipe it
        // straight away and enable notify alongside.
        streamSubscription = source.listen(controller.add, onError: controller.addError);
        gattSubscription = subscribe();
        // surface an enable failure to listeners (without leaking it unhandled —
        // onCancel still awaits `subscription` to release the ref).
        unawaited(gattSubscription!.then<void>((_) {}, onError: controller.addError));
      },
      onCancel: () async {
        await streamSubscription?.cancel();
        streamSubscription = null;
        final pending = gattSubscription;
        gattSubscription = null;
        try {
          await (await pending)?.unsubscribe();
        } catch (e) {
          // enable never landed (subscribe() already surfaced + released it) or
          // the disable failed — either way a cancel() must not throw.
          logger.warning("Notify disable failed on cancel", e);
        }
      },
    );
    return controller.stream;
  }

  /// Enables notify/indicate and keeps it on until the returned
  /// [CharacteristicSubscription] is disposed via
  /// [CharacteristicSubscription.unsubscribe].
  ///   - throws if enabling fails.
  ///   - participates in the same ref-count as [notifications]; pair with
  ///     [notificationsPassive] / [valuesPassive] to receive values
  ///     decoupled from this handle's lifetime.
  Future<CharacteristicSubscription> subscribe({Duration timeout = const Duration(seconds: 15)}) async {
    await _acquireNotify(timeout: timeout);
    return CharacteristicSubscription._(this);
  }

  /// Claims a notify ref, enabling notify on the first one. Concurrent callers
  /// share one enable and fail together; a failed enable releases the ref and
  /// rethrows so callers can surface it.
  Future<void> _acquireNotify({Duration timeout = const Duration(seconds: 15)}) async {
    requireValid("setNotifyValue");
    _notifyRefs++;
    final enable = _notifyEnable ??= _setNotifyValue(true, timeout: timeout);
    try {
      await enable;
    } catch (_) {
      _notifyRefs--;
      if (identical(_notifyEnable, enable)) _notifyEnable = null;
      rethrow;
    }
  }

  /// Releases a notify ref, disabling notify once the last one is gone.
  /// The disable is awaited and its error propagates to the caller, so an
  /// explicit `unsubscribe()` surfaces it (unless already disconnected, when
  /// there is nothing to disable). The stream-cancel path in [_subscribed]
  /// deliberately swallows it — a cancel() must not throw.
  Future<void> _releaseNotify() async {
    if (--_notifyRefs > 0) return;
    _notifyEnable = null;
    if (!device.isConnected) return; // nothing to disable unless still connected
    await _setNotifyValue(false);
  }

  /// convenience accessor
  BluetoothDescriptor? get cccd =>
      descriptors.where((d) => d.uuid == Uuids.descriptor.clientCharacteristicConfiguration).firstOrNull;

  /// read a characteristic
  Future<List<int>> read({Duration timeout = const Duration(seconds: 15)}) async {
    requireValid("readCharacteristic");
    final value = await device.invoke(
      "readCharacteristic",
      (p) => p.readCharacteristic(device.remoteId, bm),
      timeout: timeout,
    );

    // reads arrive via the future, not the platform event stream — emit a read
    // event so it shows up in [values] (but not [notifications])
    Bluebird.emitEvent(OnCharacteristicReadEvent(this, value));

    return value;
  }

  /// Writes a characteristic.
  ///  - [withoutResponse]:
  ///       If `true`, the write is not guaranteed and always returns immediately with success.
  ///       If `false`, the write returns error on failure.
  ///  - [allowLongWrite]: if set, larger writes > MTU are allowed (up to 512 bytes).
  ///       This should be used with caution.
  ///         1. it can only be used *with* response
  ///         2. the peripheral device must support the 'long write' ble protocol.
  ///         3. Interrupted transfers can leave the characteristic in a partially written state
  ///         4. If the mtu is small, it is very very slow.
  Future<void> write(
    List<int> value, {
    bool withoutResponse = false,
    bool allowLongWrite = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    requireValid("writeCharacteristic");
    if (withoutResponse && allowLongWrite) {
      throw ArgumentError("cannot longWrite withoutResponse: a long write requires responses");
    }

    final writeType = withoutResponse ? BmWriteType.withoutResponse : BmWriteType.withResponse;
    await device.invoke(
      "writeCharacteristic",
      (p) => p.writeCharacteristic(device.remoteId, bm, writeType, allowLongWrite, Uint8List.fromList(value)),
      timeout: timeout,
      // Write commands have no ATT response. Let consecutive commands enter
      // the platform together; each backend owns ordering and flow control.
      // Operations that need a response wait for this burst to drain.
      concurrentWrite: withoutResponse,
    );
  }

  /// The raw CCCD write that enables/disables notify/indicate on the platform,
  /// driven by the ref-count in [_acquireNotify]/[_releaseNotify].
  ///   - If a characteristic supports both notify and indicate, we use notify
  ///     (a CoreBluetooth limitation on iOS).
  Future<bool> _setNotifyValue(bool notify, {Duration timeout = const Duration(seconds: 15)}) =>
      device.invoke("setNotifyValue", (p) => p.setNotifyValue(device.remoteId, bm, notify), timeout: timeout);

  @override
  String toString() =>
      '$typeLabel{'
      'uuid: $uuid, '
      'properties: ${properties.describe()}, '
      'descriptors: $descriptors'
      '}';
}

/// A live notify/indicate subscription from [BluetoothCharacteristic.subscribe].
/// Holds one ref-count — keeping notify enabled — until [unsubscribe] is called.
/// If simply discarded (e.g. along with the characteristic on disconnect) it
/// does no harm; call [unsubscribe] to release it explicitly.
class CharacteristicSubscription {
  final BluetoothCharacteristic characteristic;
  bool _active = true;

  CharacteristicSubscription._(this.characteristic);

  /// Whether this subscription is still holding notify on.
  bool get isActive => _active;

  /// Releases this subscription's notify ref, disabling notify on the
  /// characteristic if it was the last one. Idempotent.
  Future<void> unsubscribe() async {
    if (!_active) return;
    _active = false;
    await characteristic._releaseNotify();
  }
}

/// The pigeon-generated properties class is used directly; this alias keeps
/// the public name. `describe()` gives a compact human-readable form.
typedef CharacteristicProperties = BmCharacteristicProperties;

extension CharacteristicPropertiesDescribe on BmCharacteristicProperties {
  List<String> _names() => [
    if (broadcast) 'broadcast',
    if (read) 'read',
    if (writeWithoutResponse) 'writeWithoutResponse',
    if (write) 'write',
    if (notify) 'notify',
    if (indicate) 'indicate',
    if (authenticatedSignedWrites) 'authenticatedSignedWrites',
    if (extendedProperties) 'extendedProperties',
    if (notifyEncryptionRequired) 'notifyEncryptionRequired',
    if (indicateEncryptionRequired) 'indicateEncryptionRequired',
  ];

  /// compact list of the enabled flags, e.g. `[read, notify]`
  String describe() => "[${_names().join(", ")}]";
}
