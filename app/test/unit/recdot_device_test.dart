// Tests for the viaim RecDot device identity: serialization, locator, firmware
// warnings, and the backend source mapping.
//
// Modelled on rayban_meta_device_test.dart. It pins the things that must stay true when
// a new DeviceType is added: it round-trips by name, an old persisted index still reads,
// the new transport kinds survive a round-trip, the buds carry no firmware warning, and
// the conversation source is wired end to end.
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/services/capture/conversation_source_for_device.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/connectors/viaim_recdot_connection.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceType.viaimRecDot serialization', () {
    test('round-trips by name through BtDevice json', () {
      final device = BtDevice(
        name: 'viaim RecDot',
        id: 'recdot-1',
        type: DeviceType.viaimRecDot,
        rssi: 0,
        locator: DeviceLocator.externalAccessory(),
      );
      final json = device.toJson();
      expect(json['type'], 'viaimRecDot');

      final restored = BtDevice.fromJson(json);
      expect(restored.type, DeviceType.viaimRecDot);
      expect(restored.id, 'recdot-1');
      expect(restored.locator?.kind, TransportKind.externalAccessory);
    });

    test('deserializes from the legacy integer index', () {
      final device = BtDevice.fromJson({'name': 'viaim RecDot', 'id': 'recdot-1', 'type': 10, 'rssi': 0});
      expect(device.type, DeviceType.viaimRecDot);
    });

    test('has no firmware warnings', () {
      final device = BtDevice(name: 'viaim RecDot', id: 'id', type: DeviceType.viaimRecDot, rssi: 0);
      expect(device.getFirmwareWarningTitle(), isEmpty);
      expect(device.getFirmwareWarningMessage(), isEmpty);
    });

    test('reports its own analytics vendor', () {
      expect(DeviceType.viaimRecDot.analyticsVendor, 'viaim');
    });
  });

  group('DeviceLocator for the RecDot transports', () {
    test('external accessory round-trips', () {
      final restored = DeviceLocator.fromJson(DeviceLocator.externalAccessory().toJson());
      expect(restored.kind, TransportKind.externalAccessory);
    });

    test('bluetooth classic round-trips with its address', () {
      final locator = DeviceLocator.bluetoothClassic(address: '20:FF:36:E9:2A:64');
      final restored = DeviceLocator.fromJson(locator.toJson());
      expect(restored.kind, TransportKind.bluetoothClassic);
      expect(restored.bluetoothId, '20:FF:36:E9:2A:64');
    });

    test('an out-of-range persisted kind still falls back to bluetooth', () {
      expect(DeviceLocator.fromJson({'kind': 99}).kind, TransportKind.bluetooth);
    });
  });

  group('the connection factory builds a RecDot connection for either locator', () {
    BtDevice storedRecDot(DeviceLocator locator) =>
        BtDevice(name: 'viaim RecDot', id: 'recdot-1', type: DeviceType.viaimRecDot, rssi: 0, locator: locator);

    test('an External Accessory locator maps to ViaimRecDotConnection', () {
      final connection = DeviceConnectionFactory.create(storedRecDot(DeviceLocator.externalAccessory()));
      expect(connection, isA<ViaimRecDotConnection>());
    });

    test('a Classic Bluetooth locator maps to ViaimRecDotConnection', () {
      final connection =
          DeviceConnectionFactory.create(storedRecDot(DeviceLocator.bluetoothClassic(address: '20:FF:00:00:00:01')));
      expect(connection, isA<ViaimRecDotConnection>());
    });

    test('a RecDot with no locator is not connectable', () {
      final device = BtDevice(name: 'viaim RecDot', id: 'recdot-1', type: DeviceType.viaimRecDot, rssi: 0);
      expect(DeviceConnectionFactory.create(device), isNull);
    });
  });

  group('conversation source', () {
    test('the RecDot maps to viaim_recdot', () {
      expect(conversationSourceForDeviceType(DeviceType.viaimRecDot), 'viaim_recdot');
    });

    test('the backend source string parses', () {
      expect(ConversationSource.values.asNameMap()['viaim_recdot'], ConversationSource.viaim_recdot);
    });
  });
}
