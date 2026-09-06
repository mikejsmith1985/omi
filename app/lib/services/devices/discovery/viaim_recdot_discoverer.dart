// Discovers viaim RecDot earbuds by asking the platform which accessories are reachable.
//
// The RecDot is not a BLE peripheral, so it never appears in a BLE scan. Instead the
// native side lists the accessories that speak the RecDot protocol (MFi accessories on
// iOS, bonded-and-connected headsets on Android) and this discoverer turns them into Omi
// devices. It self-gates: on a platform with no such API it simply yields nothing, the
// repo's idiomatic feature gate.
import 'dart:io';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/devices/discovery/device_discoverer.dart';
import 'package:omi/services/devices/discovery/device_locator.dart';
import 'package:omi/utils/logger.dart';

/// Lists connected viaim RecDot earbuds as Omi devices.
class ViaimRecDotDiscoverer extends DeviceDiscoverer {
  /// A readable name for a RecDot whose accessory reports a blank one.
  static const String defaultName = 'viaim RecDot';

  @override
  String get name => 'viaim RecDot';

  @override
  bool get isSupported => Platform.isIOS || Platform.isAndroid;

  @override
  Future<DeviceDiscoveryResult> discover({int timeout = 5}) async {
    try {
      final accessories = await RecDotLinkHostAPI().listAccessories();
      final devices = accessories.map(_deviceForAccessory).toList();
      return DeviceDiscoveryResult(devices: devices);
    } catch (e) {
      Logger.debug('viaim RecDot discovery error: $e');
      return const DeviceDiscoveryResult(devices: []);
    }
  }

  BtDevice _deviceForAccessory(RecDotAccessory accessory) {
    return BtDevice(
      name: accessory.name.isNotEmpty ? accessory.name : defaultName,
      id: accessory.deviceId,
      type: DeviceType.viaimRecDot,
      rssi: 0,
      locator: _locatorFor(accessory.deviceId),
    );
  }

  // The Dart transport is the same on both platforms; only the locator kind differs, so
  // the connection factory can pick the right native side.
  DeviceLocator _locatorFor(String deviceId) {
    return Platform.isAndroid ? DeviceLocator.bluetoothClassic(address: deviceId) : DeviceLocator.externalAccessory();
  }

  @override
  Future<void> stop() async {
    // Discovery is a stateless snapshot of the native accessory list.
  }
}
