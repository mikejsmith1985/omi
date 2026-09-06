// Bridge that receives the RecDot link's native callbacks and forwards them to Dart.
//
// It implements the generated Pigeon Flutter API and turns each native event into a
// plain callback the transport wires up. It holds no state of its own, mirroring
// RayBanMetaFlutterBridge.
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';

/// Forwards RecDot link callbacks (bytes, connection state, accessory-list changes)
/// from the native side to the transport.
class RecDotLinkFlutterBridge implements RecDotLinkFlutterAPI {
  /// Creates a bridge; every callback is optional.
  RecDotLinkFlutterBridge({this.onBytesCb, this.onConnectionStateChangedCb, this.onAccessoryListChangedCb});

  /// Called with raw bytes received from a device's link.
  final void Function(String deviceId, Uint8List bytes)? onBytesCb;

  /// Called when a device's link connection state changes.
  final void Function(String deviceId, String state)? onConnectionStateChangedCb;

  /// Called when the set of reachable accessories changes.
  final void Function()? onAccessoryListChangedCb;

  @override
  void onBytes(String deviceId, Uint8List bytes) => onBytesCb?.call(deviceId, bytes);

  @override
  void onConnectionStateChanged(String deviceId, String state) => onConnectionStateChangedCb?.call(deviceId, state);

  @override
  void onAccessoryListChanged() => onAccessoryListChangedCb?.call();
}
