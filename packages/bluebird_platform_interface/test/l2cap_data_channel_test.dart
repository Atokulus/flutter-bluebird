import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird_platform_interface/src/l2cap_data_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const int _typeData = 0;
const int _typeReady = 1;

/// Builds a `[channelId: int64 BE][type: uint8][payload]` frame.
ByteData _frame(int channelId, int type, List<int> payload) {
  final f = ByteData(9 + payload.length);
  f.setInt64(0, channelId, Endian.big);
  f.setUint8(8, type);
  f.buffer.asUint8List().setRange(9, 9 + payload.length, payload);
  return f;
}

(int, int, List<int>) _parse(ByteData f) =>
    (f.getInt64(0, Endian.big), f.getUint8(8), f.buffer.asUint8List(f.offsetInBytes + 9, f.lengthInBytes - 9));

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const name = L2capDataChannel.channelName;

  late L2capDataChannel client;
  late List<ByteData> sent; // frames the client sent "to native"

  setUp(() {
    client = L2capDataChannel();
    sent = [];
    // Intercept outbound (Dart→native) sends and ack them.
    binding.defaultBinaryMessenger.setMockMessageHandler(name, (ByteData? m) async {
      sent.add(m!);
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMessageHandler(name, null);
  });

  /// Injects an inbound (native→Dart) frame; the future completes with the
  /// handler's reply once it is sent (which the backpressure gate can delay).
  Future<ByteData?> inbound(ByteData frame) {
    final c = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(name, frame, (ByteData? r) => c.complete(r));
    return c.future;
  }

  test('write emits a data frame and completes when native acks', () async {
    await client.write(7, Uint8List.fromList([1, 2, 3]));

    expect(sent, hasLength(1));
    final (ch, type, payload) = _parse(sent.single);
    expect(ch, 7);
    expect(type, _typeData);
    expect(payload, [1, 2, 3]);
  });

  test('first listen on input sends an empty ready frame', () async {
    final sub = client.input(7).listen((_) {});
    await pumpEventQueue();

    expect(sent, hasLength(1));
    final (ch, type, payload) = _parse(sent.single);
    expect(ch, 7);
    expect(type, _typeReady);
    expect(payload, isEmpty);

    await sub.cancel();
  });

  test('inbound data reaches a live input listener and is acked', () async {
    final got = <List<int>>[];
    final sub = client.input(7).listen(got.add);
    await pumpEventQueue(); // ready sent

    final reply = await inbound(_frame(7, _typeData, [9, 8, 7]));
    await pumpEventQueue();

    expect(got, [
      [9, 8, 7],
    ]);
    expect(reply, isNull); // acked immediately (listener active)

    await sub.cancel();
  });

  test('backpressure: the reply is withheld until the consumer listens', () async {
    final stream = client.input(7); // registers the route, no listener yet

    var replied = false;
    final replyFuture = inbound(_frame(7, _typeData, [1, 2])).then((_) => replied = true);
    await pumpEventQueue();
    expect(replied, isFalse); // credit-of-one: no listener → reply held

    final got = <List<int>>[];
    final sub = stream.listen(got.add); // listening releases the gate
    await replyFuture;
    await pumpEventQueue();

    expect(replied, isTrue);
    expect(got, [
      [1, 2],
    ]);

    await sub.cancel();
  });

  test('inbound for an unregistered channel is dropped without error', () async {
    await inbound(_frame(99, _typeData, [1])); // no input(99) → must not throw
  });

  test('a too-short frame is ignored', () async {
    await inbound(ByteData(4)); // < header length
  });

  test('non-data frame types are not delivered', () async {
    final got = <List<int>>[];
    final sub = client.input(7).listen(got.add);
    await pumpEventQueue();

    await inbound(_frame(7, _typeReady, [1, 2]));
    await pumpEventQueue();

    expect(got, isEmpty);
    await sub.cancel();
  });

  test('detach closes the input stream and forgets the channel', () async {
    var done = false;
    final sub = client.input(7).listen((_) {}, onDone: () => done = true);
    await pumpEventQueue();

    client.detach(7);
    await pumpEventQueue();
    expect(done, isTrue);

    // a later inbound frame for the detached channel is a no-op
    await inbound(_frame(7, _typeData, [1]));
    await sub.cancel();
  });
}
