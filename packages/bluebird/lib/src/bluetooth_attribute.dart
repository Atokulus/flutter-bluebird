// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:flutter/foundation.dart';
import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:logging/logging.dart';

import 'bluebird.dart';
import 'bluetooth_device.dart';

/// Anything that can prefix a log line with its GATT path — a [BluetoothDevice]
/// or any [BluetoothAttribute] (service, characteristic, descriptor).
abstract interface class BluebirdLoggable {
  /// The bracketed path identifying this object in logs, outermost first — e.g.
  /// a characteristic is `[remoteId][service][characteristic]`.
  String get logPath;
}

extension BluebirdLoggableLog on BluebirdLoggable {
  /// A [Bluebird.logger] view that prefixes every line with this object's
  /// [logPath] (e.g. `[remoteId][service][characteristic] …`). Use the standard
  /// [Logger] level methods, e.g. `characteristic.logger.warning('notify failed', error)`.
  @internal
  BluebirdScopedLogger get logger => BluebirdScopedLogger(this);
}

/// A thin [Bluebird.logger] view that prefixes messages with a
/// [BluebirdLoggable]'s [logPath], mirroring the [Logger] level methods. The
/// path is resolved lazily — only when the level is actually loggable — so a
/// filtered call is free.
///
/// Message style (keep it consistent):
///   - capitalize the first letter, no trailing period
///   - `"<Event phrase>[: <key=value …>]"` — a short event phrase, then any
///     variable data as space-separated `key=value` pairs
///   - don't restate what `[path]` already shows (device/attribute ids)
///   - pass exceptions as [error], never interpolated into the message
@internal
class BluebirdScopedLogger {
  final BluebirdLoggable _target;

  BluebirdScopedLogger(this._target);

  /// Logs [message] at [level] unless filtered, prefixed with the scope path.
  /// [message] may be an `Object` or a `() => Object?` evaluated only if emitted;
  /// an optional [error] / [stackTrace] rides along on the [LogRecord].
  void log(Level level, Object? message, [Object? error, StackTrace? stackTrace]) {
    if (!Bluebird.logger.isLoggable(level)) return;
    final resolved = message is Function ? message() : message;
    Bluebird.logger.log(level, "${_target.logPath} $resolved", error, stackTrace);
  }

  void finest(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.FINEST, message, error, stackTrace);
  void finer(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.FINER, message, error, stackTrace);
  void fine(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.FINE, message, error, stackTrace);
  void config(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.CONFIG, message, error, stackTrace);
  void info(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.INFO, message, error, stackTrace);
  void warning(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.WARNING, message, error, stackTrace);
  void severe(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(Level.SEVERE, message, error, stackTrace);
  void shout(Object? message, [Object? error, StackTrace? stackTrace]) => log(Level.SHOUT, message, error, stackTrace);
}

/// Identifies an attribute on a device: a [uuid] plus a platform-opaque
/// [index] disambiguating duplicate uuids.
///
/// This is the object-domain counterpart of the wire-format [BmAttributeId]:
/// the uuid is held as a parsed [Uuid] (form-insensitive equality), converted
/// from/to the wire string form once, at the protocol boundary.
@immutable
class BluetoothAttributeId {
  final Uuid uuid;

  /// Platform-opaque instance token disambiguating duplicate uuids
  /// (null for descriptors, which are uuid-unique within a characteristic).
  final int? index;

  const BluetoothAttributeId(this.uuid, [this.index]);

  @internal
  BluetoothAttributeId.fromBm(BmAttributeId id) : this(Uuid(id.uuid), id.instance);

  @internal
  BmAttributeId get bm => BmAttributeId(uuid: uuid.string, instance: index ?? 0);

  @override
  operator ==(Object other) =>
      other is BluetoothAttributeId && uuid == other.uuid && (index ?? 0) == (other.index ?? 0);

  @override
  int get hashCode => Object.hash(uuid, index ?? 0);

  @override
  String toString() => index == null ? '$uuid' : '$uuid:$index';
}

abstract class BluetoothAttribute implements BluebirdLoggable {
  final BluetoothDevice device;

  /// The uuid:index pair identifying this attribute on [device].
  final BluetoothAttributeId id;

  /// The device's discovery timestamp when this attribute was built. It goes
  /// stale once the device runs a newer discovery (see [isValid]).
  final DateTime _discovery;

  BluetoothAttribute({required this.device, required this.id}) : _discovery = device.discoveryToken;

  Uuid get uuid => id.uuid;

  /// Platform-opaque instance token disambiguating duplicate uuids
  /// (null for descriptors, which are uuid-unique within a characteristic).
  int? get index => id.index;

  /// A stable, human-readable type name for diagnostics. Hardcoded per subtype
  /// rather than derived from [runtimeType], which is minified/obfuscated in
  /// release and web builds.
  @internal
  String get typeLabel;

  /// Whether this attribute belongs to the device's current GATT table.
  ///
  /// Every [BluetoothDevice.discoverServices] — and every services reset —
  /// stamps a new discovery. Each attribute captures the discovery it was found
  /// under, so a reference held across a (re-)discovery reports `false` here and
  /// throws if used. Re-fetch from [BluetoothDevice.services].
  bool get isValid => identical(_discovery, device.discoveryToken);

  /// Throws if this attribute has been superseded by a (re-)discovery or a
  /// disconnect, so a stale reference fails loudly instead of silently operating
  /// on a removed attribute. A disconnect also invalidates attributes, so report
  /// that as the cause first — it's the more useful message.
  @internal
  void requireValid(String method) {
    if (isValid) return;
    device.ensureConnected(method); // throws deviceDisconnected if disconnected
    throw BluebirdException(
      method,
      BluebirdErrorCode.invalidIdentifier,
      "$typeLabel $id is stale: it is from the discovery at $_discovery, but the "
      "device's current discovery is ${device.discoveryToken}. "
      "Re-fetch it from device.services.",
    );
  }
}
