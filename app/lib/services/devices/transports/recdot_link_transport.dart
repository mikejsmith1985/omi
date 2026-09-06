// Transport for viaim RecDot earbuds: a raw byte pipe over the native accessory link.
//
// The native side (an MFi External Accessory session on iOS, an RFCOMM socket on
// Android) only opens the link, writes the bytes it is handed, and forwards received
// bytes back. All STAROT framing lives in Dart above this. The transport exposes the
// link through Omi's synthetic characteristic-stream vocabulary, the same seam the
// Ray-Ban Meta and Watch transports use, so nothing above the transport knows the
// device is not a BLE peripheral.
import 'dart:async';
import 'dart:typed_data';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/recdot_link_bridge.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/utils/logger.dart';

/// Carries raw bytes to and from a viaim RecDot over the native accessory link,
/// exposing them through Omi's synthetic characteristic-stream vocabulary.
class RecDotLinkTransport extends DeviceTransport {
  /// The one synthetic service the link exposes.
  static const String linkServiceUuid = 'viaim-recdot-link';

  /// The one synthetic characteristic the raw bytes flow over.
  static const String linkBytesCharacteristicUuid = 'viaim-recdot-bytes';

  /// Creates a transport for the accessory identified by [deviceId].
  RecDotLinkTransport(this._deviceId) : _stateController = StreamController<DeviceTransportState>.broadcast() {
    _ensureBridge();
    _instances.add(this);
  }

  final String _deviceId;
  final RecDotLinkHostAPI _hostApi = RecDotLinkHostAPI();
  final StreamController<DeviceTransportState> _stateController;
  final StreamController<List<int>> _bytesController = StreamController<List<int>>.broadcast();

  DeviceTransportState _state = DeviceTransportState.disconnected;

  // The Pigeon Flutter API is a process-wide singleton, so one bridge fans events out
  // to every live transport, matching how RayBanMetaTransport is structured.
  static RecDotLinkFlutterBridge? _bridge;
  static final List<RecDotLinkTransport> _instances = [];

  @override
  String get deviceId => _deviceId;

  @override
  Stream<DeviceTransportState> get connectionStateStream => _stateController.stream;

  static void _ensureBridge() {
    if (_bridge != null) return;
    _bridge = RecDotLinkFlutterBridge(
      onBytesCb: (deviceId, bytes) {
        for (final transport in _instances) {
          if (transport._deviceId == deviceId && !transport._bytesController.isClosed) {
            transport._bytesController.add(bytes);
          }
        }
      },
      onConnectionStateChangedCb: (deviceId, state) {
        for (final transport in _instances) {
          if (transport._deviceId == deviceId) transport._applyState(state);
        }
      },
      onAccessoryListChangedCb: () {
        Logger.debug('RecDot link: accessory list changed');
      },
    );
    RecDotLinkFlutterAPI.setUp(_bridge);
  }

  void _applyState(String state) {
    switch (state) {
      case 'connecting':
        _updateState(DeviceTransportState.connecting);
      case 'connected':
        _updateState(DeviceTransportState.connected);
      case 'disconnecting':
        _updateState(DeviceTransportState.disconnecting);
      default:
        _updateState(DeviceTransportState.disconnected);
    }
  }

  void _updateState(DeviceTransportState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  void _requireLinkCharacteristic(String serviceUuid, String characteristicUuid) {
    if (serviceUuid != linkServiceUuid || characteristicUuid != linkBytesCharacteristicUuid) {
      throw ArgumentError(
          'RecDot link has only $linkServiceUuid/$linkBytesCharacteristicUuid, not $serviceUuid/$characteristicUuid');
    }
  }

  @override
  Future<void> connect() async {
    _updateState(DeviceTransportState.connecting);
    await _hostApi.connect(_deviceId);
  }

  @override
  Future<void> disconnect() async {
    _updateState(DeviceTransportState.disconnecting);
    await _hostApi.disconnect(_deviceId);
  }

  @override
  Future<bool> isConnected() async => _state == DeviceTransportState.connected;

  @override
  Future<bool> ping() async => _state == DeviceTransportState.connected;

  @override
  Stream<List<int>> getCharacteristicStream(String serviceUuid, String characteristicUuid) {
    _requireLinkCharacteristic(serviceUuid, characteristicUuid);
    return _bytesController.stream;
  }

  @override
  Future<List<int>> readCharacteristic(String serviceUuid, String characteristicUuid) async {
    _requireLinkCharacteristic(serviceUuid, characteristicUuid);
    return const [];
  }

  @override
  Future<void> writeCharacteristic(String serviceUuid, String characteristicUuid, List<int> data) async {
    _requireLinkCharacteristic(serviceUuid, characteristicUuid);
    await _hostApi.write(_deviceId, Uint8List.fromList(data));
  }

  @override
  Future<void> dispose() async {
    _instances.remove(this);
    await _bytesController.close();
    await _stateController.close();
  }
}
