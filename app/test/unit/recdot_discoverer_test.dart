// Tests for the viaim RecDot discoverer: it turns the native accessory list into Omi
// devices, and fails soft.
//
// The native host API is mocked over the Pigeon channel, so the mapping from accessories
// to BtDevices, and the graceful-empty behaviour when the platform has none or errors, is
// exercised without a device.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';
import 'package:omi/services/devices/discovery/viaim_recdot_discoverer.dart';

const _hostPrefix = 'dev.flutter.pigeon.omi_pigeon.RecDotLinkHostAPI';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channelNames = <String>{};

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

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channelName in channelNames) {
      messenger.setMockMessageHandler(channelName, null);
    }
    channelNames.clear();
  });

  test('maps each reachable accessory to a viaim RecDot device', () async {
    mockHost('listAccessories', (_) async {
      return <Object?>[
        <RecDotAccessory>[
          RecDotAccessory(
              deviceId: 'recdot-42', name: 'viaim RecDot', serialNumber: 'A92X', firmwareRevision: '1.2.3.45'),
        ],
      ];
    });

    final result = await ViaimRecDotDiscoverer().discover();

    expect(result.devices, hasLength(1));
    final device = result.devices.single;
    expect(device.type, DeviceType.viaimRecDot);
    expect(device.id, 'recdot-42');
    expect(device.name, 'viaim RecDot');
    expect(device.locator?.kind, anyOf(TransportKind.externalAccessory, TransportKind.bluetoothClassic));
  });

  test('an empty accessory list yields no devices', () async {
    mockHost('listAccessories', (_) async => <Object?>[<RecDotAccessory>[]]);
    final result = await ViaimRecDotDiscoverer().discover();
    expect(result.devices, isEmpty);
  });

  test('a native error fails soft with no devices', () async {
    mockHost('listAccessories', (_) async => throw PlatformException(code: 'boom'));
    final result = await ViaimRecDotDiscoverer().discover();
    expect(result.devices, isEmpty);
  });

  test('a blank accessory name falls back to a readable default', () async {
    mockHost('listAccessories', (_) async {
      return <Object?>[
        <RecDotAccessory>[RecDotAccessory(deviceId: 'recdot-1', name: '')],
      ];
    });
    final result = await ViaimRecDotDiscoverer().discover();
    expect(result.devices.single.name, isNotEmpty);
  });
}
