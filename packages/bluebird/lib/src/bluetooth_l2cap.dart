// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter/foundation.dart';

import 'bluebird.dart';
import 'bluetooth_device.dart';
import 'utils.dart';

/// An open L2CAP connection-oriented channel: a bidirectional byte stream to the
/// peer that runs alongside — but independently of — GATT.
///
/// Obtain one with [BluetoothDevice.openL2capChannel]. Read from [input], write
/// with [write], and release it with [close]. The channel also closes on its
/// own when the peer closes it or the device disconnects; watch [input]'s done
/// event (or [isClosed]).
///
/// Unlike GATT operations, reads and writes here do **not** pass through the
/// global operation queue — the channel is a separate transport, so its
/// throughput is not gated by (and does not gate) characteristic I/O.
class BluetoothL2CapChannel {
  final BluetoothDevice device;

  /// The PSM this channel was opened to.
  final int psm;

  /// Native-assigned id, unique among channels for the plugin's lifetime.
  final int channelId;

  bool _closed = false;

  @internal
  BluetoothL2CapChannel({required this.device, required this.psm, required this.channelId});

  /// Whether the channel has been closed — by [close], the peer, or a disconnect.
  bool get isClosed => _closed;

  /// Inbound bytes from the peer, as a single-subscription stream. Pausing the
  /// subscription backpressures the peer; the stream is done when the channel
  /// closes. Chunk boundaries are not significant — L2CAP is a byte stream.
  Stream<Uint8List> get input => BluebirdPlatform.instance.l2capInput(channelId);

  /// Writes [data] to the peer, completing once the platform has accepted the
  /// bytes (its backpressure signal). Throws if the channel is already closed.
  ///   - [timeout] guards against a wedged channel; note that legitimate
  ///     backpressure (the peer not reading, so no L2CAP credits) can delay a
  ///     write, so raise it for bulk transfers to a slow consumer.
  Future<void> write(Uint8List data, {Duration timeout = const Duration(seconds: 30)}) {
    if (_closed) {
      throw BluebirdException("l2cap.write", BluebirdErrorCode.deviceDisconnected, "l2cap channel is closed");
    }
    return BluebirdPlatform.instance.l2capWrite(channelId, data).bluebirdTimeout(timeout, "l2cap.write");
  }

  /// Closes the channel. Idempotent; safe to call after a remote close.
  Future<void> close({Duration timeout = const Duration(seconds: 10)}) async {
    if (_closed) return;
    _markClosed();
    await Bluebird.invoke("closeL2capChannel", (p) => p.closeL2capChannel(channelId), timeout: timeout);
  }

  /// Marks closed and tears down the local data-channel state. Shared by [close]
  /// and the unsolicited-close path.
  void _markClosed() {
    if (_closed) return;
    _closed = true;
    Bluebird.unregisterL2cap(channelId);
    BluebirdPlatform.instance.l2capDetach(channelId);
  }

  /// The peer closed the channel, the device disconnected, or an I/O error
  /// occurred. Invoked by the event router.
  @internal
  void onRemoteClosed() => _markClosed();

  @override
  String toString() =>
      'BluetoothL2CapChannel{remoteId: ${device.remoteId}, psm: $psm, channelId: $channelId, closed: $_closed}';
}
