// Tests for the RecDot link transport: a byte pipe over the Pigeon accessory API.
//
// The transport carries raw bytes to and from the native accessory session and exposes
// them through Omi's synthetic characteristic-stream vocabulary, exactly as the Ray-Ban
// and Watch transports do. These tests mock the native host API and drive native→Dart
// callbacks through the binary messenger, so the transport's own forwarding, state and
// guard behaviour is exercised without a device.
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/recdot_link_transport.dart';

const _hostPrefix = 'dev.flutter.pigeon.omi_pigeon.RecDotLinkHostAPI';
const _flutterPrefix = 'dev.flutter.pigeon.omi_pigeon.RecDotLinkFlutterAPI';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channelNames = <String>{};
  final writes = <List<Object?>>[];

  void mockHost(String method, Future<Object?> Function(Object? message) handler) {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channelName = '$_hostPrefix.$method';
    channelNames.add(channelName);
    messenger.setMockMessageHandler(channelName, (ByteData? message) async {
      final decoded = RecDotLinkHostAPI.pigeonChannelCodec.decodeMessage(message);
      final response = await handler(decoded);
      return RecDotLinkHostAPI.pigeonChannelCodec.encodeMessage(response);
    });
  }

  // Simulate the native side calling a RecDotLinkFlutterAPI method.
  Future<void> driveNative(String method, List<Object?> args) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final channelName = '$_flutterPrefix.$method';
    final encoded = RecDotLinkHostAPI.pigeonChannelCodec.encodeMessage(args);
    await messenger.handlePlatformMessage(channelName, encoded, (_) {});
  }

  setUp(() {
    writes.clear();
    mockHost('connect', (_) async => <Object?>[]);
    mockHost('disconnect', (_) async => <Object?>[]);
    mockHost('write', (message) async {
      writes.add(message as List<Object?>);
      return <Object?>[];
    });
    mockHost('listAccessories', (_) async => <Object?>[<RecDotAccessory>[]]);
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channelName in channelNames) {
      messenger.setMockMessageHandler(channelName, null);
    }
    channelNames.clear();
  });

  test('received bytes arrive in order on the link characteristic stream', () async {
    final transport = RecDotLinkTransport('recdot-1');
    final received = <List<int>>[];
    final sub = transport
        .getCharacteristicStream(RecDotLinkTransport.linkServiceUuid, RecDotLinkTransport.linkBytesCharacteristicUuid)
        .listen(received.add);
    await pumpEventQueue();

    await driveNative('onBytes', [
      'recdot-1',
      Uint8List.fromList([1, 2, 3])
    ]);
    await driveNative('onBytes', [
      'recdot-1',
      Uint8List.fromList([4, 5])
    ]);
    await pumpEventQueue();

    expect(received, [
      [1, 2, 3],
      [4, 5],
    ]);
    await sub.cancel();
    await transport.dispose();
  });

  test('bytes addressed to another device are not delivered here', () async {
    final transport = RecDotLinkTransport('recdot-1');
    final received = <List<int>>[];
    final sub = transport
        .getCharacteristicStream(RecDotLinkTransport.linkServiceUuid, RecDotLinkTransport.linkBytesCharacteristicUuid)
        .listen(received.add);
    await pumpEventQueue();

    await driveNative('onBytes', [
      'someone-else',
      Uint8List.fromList([9, 9])
    ]);
    await pumpEventQueue();

    expect(received, isEmpty);
    await sub.cancel();
    await transport.dispose();
  });

  test('writeCharacteristic forwards the exact bytes to the native host', () async {
    final transport = RecDotLinkTransport('recdot-1');
    await transport.writeCharacteristic(
      RecDotLinkTransport.linkServiceUuid,
      RecDotLinkTransport.linkBytesCharacteristicUuid,
      [0x55, 0x04, 0x55, 0x0B],
    );
    expect(writes, hasLength(1));
    expect(writes.single[0], 'recdot-1');
    expect((writes.single[1] as Uint8List).toList(), [0x55, 0x04, 0x55, 0x0B]);
    await transport.dispose();
  });

  test('an unknown characteristic id is rejected on read and write', () async {
    final transport = RecDotLinkTransport('recdot-1');
    expect(() => transport.getCharacteristicStream('other', 'other'), throwsArgumentError);
    expect(transport.writeCharacteristic('other', 'other', [0]), throwsArgumentError);
    await transport.dispose();
  });

  test('native connection-state changes are mirrored on the state stream', () async {
    final transport = RecDotLinkTransport('recdot-1');
    final states = <DeviceTransportState>[];
    final sub = transport.connectionStateStream.listen(states.add);
    await pumpEventQueue();

    await driveNative('onConnectionStateChanged', ['recdot-1', 'connecting']);
    await driveNative('onConnectionStateChanged', ['recdot-1', 'connected']);
    await driveNative('onConnectionStateChanged', ['recdot-1', 'disconnected']);
    await pumpEventQueue();

    expect(states, [
      DeviceTransportState.connecting,
      DeviceTransportState.connected,
      DeviceTransportState.disconnected,
    ]);
    await sub.cancel();
    await transport.dispose();
  });

  test('readCharacteristic returns nothing because the link has no readable attributes', () async {
    final transport = RecDotLinkTransport('recdot-1');
    expect(
        await transport.readCharacteristic(
            RecDotLinkTransport.linkServiceUuid, RecDotLinkTransport.linkBytesCharacteristicUuid),
        isEmpty);
    await transport.dispose();
  });
}
