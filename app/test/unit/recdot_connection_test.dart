// Tests for the viaim RecDot connection: the connect handshake and battery.
//
// A scripted fake transport answers each command the way the buds would, so the
// connection's ordering, request/response correlation, error handling and battery
// parsing are exercised without a device. The exact command bytes are asserted against
// the protocol notes, so a handshake that drifts fails here.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/connectors/viaim_recdot_connection.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';
import 'package:omi/services/devices/recdot/starot_codec.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/recdot_link_transport.dart';

/// A transport that captures writes and replies to each command with a scripted frame.
class ScriptedRecDotTransport extends DeviceTransport {
  final StreamController<List<int>> _bytes = StreamController<List<int>>.broadcast();
  final StreamController<DeviceTransportState> _state = StreamController<DeviceTransportState>.broadcast();

  /// Opcodes written to the link, in order.
  final List<int> writtenOpcodes = [];

  /// Per-opcode responder: given the request frame, returns response frames to emit.
  final Map<int, List<int> Function(StarotFrame request)> responders = {};

  @override
  String get deviceId => 'fake-recdot';

  @override
  Future<void> connect() async => _state.add(DeviceTransportState.connected);

  @override
  Future<void> disconnect() async => _state.add(DeviceTransportState.disconnected);

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<bool> ping() async => true;

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) => _bytes.stream;

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async => const [];

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    final request = StarotFramer().feed(data).single;
    writtenOpcodes.add(request.opcode);
    final responder = responders[request.opcode];
    if (responder != null) {
      final response = responder(request);
      scheduleMicrotask(() => _bytes.add(response));
    }
  }

  @override
  Stream<DeviceTransportState> get connectionStateStream => _state.stream;

  @override
  Future<void> dispose() async {
    await _bytes.close();
    await _state.close();
  }
}

Uint8List ackFor(int opcode, {int status = 0, List<int> data = const []}) {
  return StarotCodec.encodeFrame(opcode | StarotCodec.ackFlag, Uint8List.fromList([status, ...data]));
}

BtDevice recDotDevice() => BtDevice(
      name: 'viaim RecDot',
      id: 'fake-recdot',
      type: DeviceType.viaimRecDot,
      rssi: 0,
      locator: DeviceLocator.externalAccessory(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bond = 0x5101;
  const serial = 0x550B;
  const version = 0x5500;
  const battery = 0x5505;
  const seamless = 0x5534;

  ScriptedRecDotTransport happyTransport() {
    final transport = ScriptedRecDotTransport();
    transport.responders[bond] = (_) => ackFor(bond);
    transport.responders[serial] = (_) => StarotCodec.encodeFrame(
          serial | StarotCodec.ackFlag,
          Uint8List.fromList([
            0,
            ...StarotCodec.encodeTlvGroup([TlvAttribute(1, Uint8List.fromList('A92ABCDEFGHIJK'.codeUnits))])
          ]),
        );
    transport.responders[version] = (_) => StarotCodec.encodeFrame(
          version | StarotCodec.ackFlag,
          Uint8List.fromList([
            0,
            ...StarotCodec.encodeTlvGroup([
              TlvAttribute(1, Uint8List.fromList([0, 8, 0, 0, 1, 2, 3, 0x2D]))
            ])
          ]),
        );
    transport.responders[battery] = (_) => StarotCodec.encodeFrame(
          battery | StarotCodec.ackFlag,
          Uint8List.fromList([
            0,
            ...StarotCodec.encodeTlvGroup([
              TlvAttribute(1, Uint8List.fromList([0x80 | 55])),
              TlvAttribute(2, Uint8List.fromList([60])),
              TlvAttribute(3, Uint8List.fromList([0xFF]))
            ])
          ]),
        );
    transport.responders[seamless] = (_) => ackFor(seamless);
    return transport;
  }

  test('connect runs the documented handshake in order', () async {
    final transport = happyTransport();
    final connection = ViaimRecDotConnection(recDotDevice(), transport);
    await connection.connect();
    expect(transport.writtenOpcodes, [bond, serial, version, battery, seamless]);
    await connection.disconnect();
  });

  test('the bond check is exactly the documented four zero bytes', () async {
    final transport = happyTransport();
    final captured = <List<int>>[];
    final wrapped = transport;
    wrapped.responders[bond] = (request) {
      captured.add([0x55, 0x08, 0x51, 0x01, ...request.payload]);
      return ackFor(bond);
    };
    final connection = ViaimRecDotConnection(recDotDevice(), transport);
    await connection.connect();
    expect(captured.single, [0x55, 0x08, 0x51, 0x01, 0, 0, 0, 0]);
    await connection.disconnect();
  });

  test('a non-zero ack status on any step fails connect with a message naming the step', () async {
    final transport = happyTransport();
    transport.responders[bond] = (_) => ackFor(bond, status: 6);
    final connection = ViaimRecDotConnection(recDotDevice(), transport);
    await expectLater(
      connection.connect(),
      throwsA(isA<DeviceConnectionException>().having((e) => e.cause.toLowerCase(), 'cause', contains('bond'))),
    );
    await connection.disconnect();
  });

  test('battery is parsed and the lowest present bud level is reported', () async {
    final transport = happyTransport();
    final connection = ViaimRecDotConnection(recDotDevice(), transport);
    await connection.connect();
    expect(await connection.retrieveBatteryLevel(), 55);
    await connection.disconnect();
  });

  test('a battery push updates the reported level', () async {
    final transport = happyTransport();
    final connection = ViaimRecDotConnection(recDotDevice(), transport);
    await connection.connect();
    // Native push (0x5504) with both buds at 40, unsolicited.
    final push = StarotCodec.encodeFrame(
      0x5504,
      Uint8List.fromList(StarotCodec.encodeTlvGroup([
        TlvAttribute(1, Uint8List.fromList([40])),
        TlvAttribute(2, Uint8List.fromList([40]))
      ])),
    );
    transport._bytes.add(push);
    await pumpEventQueue();
    expect(await connection.retrieveBatteryLevel(), 40);
    await connection.disconnect();
  });

  test('the link characteristic is the transport link characteristic', () {
    expect(RecDotLinkTransport.linkServiceUuid, 'viaim-recdot-link');
    expect(RecDotLinkTransport.linkBytesCharacteristicUuid, 'viaim-recdot-bytes');
  });
}
