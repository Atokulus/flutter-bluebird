import 'dart:async';
import 'dart:typed_data';

import 'package:bluebird_platform_interface/bluebird_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal concrete platform that only supplies an event stream, so the
/// L2CAP delegation defaults on [BluebirdPlatform] can be exercised.
final class _FakePlatform extends BluebirdPlatform {
  final controller = StreamController<BmEvent>.broadcast();

  @override
  Stream<BmEvent> get events => controller.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;

  setUp(() => platform = _FakePlatform());
  tearDown(() => platform.controller.close());

  test('openL2capChannel / closeL2capChannel default to UnimplementedError', () {
    expect(() => platform.openL2capChannel('addr', 0x80, false), throwsUnimplementedError);
    expect(() => platform.closeL2capChannel(1), throwsUnimplementedError);
  });

  test('onL2capChannelClosed surfaces the matching event', () async {
    final next = platform.onL2capChannelClosed.first;
    platform.controller.add(BmScanFailedEvent(errorCode: 1, errorString: 'x')); // filtered out
    platform.controller.add(BmL2capChannelClosedEvent(channelId: 9, address: 'addr', errorString: 'gone'));
    final event = await next;
    expect(event.channelId, 9);
    expect(event.errorString, 'gone');
  });

  test('l2capInput / l2capWrite / l2capDetach delegate to the shared data channel', () async {
    // input() returns the inbound stream for the channel
    expect(platform.l2capInput(3), isA<Stream<Uint8List>>());

    // write() sends over the (mock-less) binary channel and completes
    await platform.l2capWrite(3, Uint8List.fromList([1, 2, 3]));

    // detach() is a no-op that does not throw
    platform.l2capDetach(3);
    platform.l2capDetach(999); // unknown channel
  });
}
