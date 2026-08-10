// Copyright 2026, Nebojša Cvetković (nebkat).
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart client for the dedicated `bluebird/l2cap` binary data channel, shared by
/// the Android and darwin platform implementations (the wire protocol is
/// identical). Kept off the pigeon host API and the shared event stream so bulk
/// bytes never contend with control traffic.
///
/// Frame layout — `[channelId: int64 big-endian][type: uint8][payload]`:
///   * type 0 = data  — either direction; the message reply gates flow control
///   * type 1 = ready — Dart→native: start forwarding inbound bytes
///
/// Backpressure rides on the message reply. Outbound: [write]'s future resolves
/// when native replies (the bytes were accepted by the socket). Inbound: native
/// sends one chunk and waits for our reply before the next, so withholding the
/// reply while the consumer's subscription is paused — or before it listens —
/// flow-controls the peer with a credit of one in-flight chunk.
class L2capDataChannel {
  static const String channelName = 'bluebird/l2cap';

  static const int _headerLen = 9; // int64 channelId + uint8 type
  static const int _typeData = 0;
  static const int _typeReady = 1;

  final BasicMessageChannel<ByteData?> _channel = const BasicMessageChannel<ByteData?>(channelName, BinaryCodec());

  final Map<int, _Inbound> _inbound = {};
  bool _handlerAttached = false;

  void _ensureHandler() {
    if (_handlerAttached) return;
    _handlerAttached = true;
    _channel.setMessageHandler(_onMessage);
  }

  /// Inbound bytes for [channelId]. The first listen sends the `ready` signal so
  /// native starts forwarding; pausing the subscription backpressures the peer,
  /// and the stream closes when the channel does ([detach]).
  Stream<Uint8List> input(int channelId) {
    _ensureHandler();
    final inbound = _inbound[channelId] ??= _Inbound(() => _sendReady(channelId));
    return inbound.controller.stream;
  }

  /// Writes [data] to [channelId]; completes once native has accepted the bytes.
  Future<void> write(int channelId, Uint8List data) async {
    _ensureHandler();
    await _channel.send(_frame(channelId, _typeData, data));
  }

  /// Closes and forgets the local inbound state for [channelId], after the
  /// channel has been closed (solicited or not).
  void detach(int channelId) {
    _inbound.remove(channelId)?.close();
  }

  void _sendReady(int channelId) {
    _ensureHandler();
    _channel.send(_frame(channelId, _typeReady, Uint8List(0)));
  }

  Future<ByteData?> _onMessage(ByteData? message) async {
    if (message == null || message.lengthInBytes < _headerLen) return null;
    final channelId = message.getInt64(0, Endian.big);
    final type = message.getUint8(8);
    if (type != _typeData) return null;

    final inbound = _inbound[channelId];
    if (inbound == null) return null;

    final payload = Uint8List.fromList(
      message.buffer.asUint8List(message.offsetInBytes + _headerLen, message.lengthInBytes - _headerLen),
    );
    // Resolves when the consumer can take more — this is the native reply, so
    // withholding it stops the peer.
    await inbound.deliver(payload);
    return null;
  }

  ByteData _frame(int channelId, int type, Uint8List payload) {
    final frame = ByteData(_headerLen + payload.length);
    frame.setInt64(0, channelId, Endian.big);
    frame.setUint8(8, type);
    frame.buffer.asUint8List().setRange(_headerLen, _headerLen + payload.length, payload);
    return frame;
  }
}

/// Per-channel inbound state: a single-subscription controller plus a
/// credit-of-one backpressure gate. [deliver] holds its future until the
/// consumer is ready for more (subscription active and not paused), which
/// withholds the native reply and stops the peer.
class _Inbound {
  late final StreamController<Uint8List> controller;
  final void Function() _onFirstListen;
  bool _readySent = false;
  Completer<void>? _blocked;

  _Inbound(this._onFirstListen) {
    controller = StreamController<Uint8List>(onListen: _onListen, onResume: _release, onCancel: _release);
  }

  void _onListen() {
    if (!_readySent) {
      _readySent = true;
      _onFirstListen();
    }
    _release();
  }

  void _release() {
    _blocked?.complete();
    _blocked = null;
  }

  Future<void> deliver(Uint8List data) {
    if (controller.isClosed) return Future.value();
    controller.add(data);
    // Reply now only if the consumer can take more; otherwise withhold until it
    // listens / resumes (credit-of-one backpressure).
    if (controller.hasListener && !controller.isPaused) return Future.value();
    return (_blocked ??= Completer<void>()).future;
  }

  void close() {
    _release();
    if (!controller.isClosed) controller.close();
  }
}
