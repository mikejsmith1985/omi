// Connection to a viaim RecDot: runs the STAROT handshake and exposes battery.
//
// It speaks the RecDot's framed protocol over the accessory link transport: after the
// transport connects, it checks the (all-zero) bond code, reads the serial and version,
// reads the battery, and turns the bud's seamless-record flag on. Commands are correlated
// to their acknowledgements by opcode, one outstanding per opcode, as the buds have no
// transaction id (protocol.md §3). All framing lives in the pure StarotCodec; this class
// only sequences requests and holds the results.
import 'dart:async';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/models.dart';
import 'package:omi/services/devices/recdot/recdot_commands.dart';
import 'package:omi/services/devices/recdot/starot_codec.dart';
import 'package:omi/services/devices/transports/recdot_link_transport.dart';

/// A connected viaim RecDot, reached over the accessory link transport.
class ViaimRecDotConnection extends DeviceConnection {
  /// Creates a connection for [device] over [transport].
  ViaimRecDotConnection(super.device, super.transport);

  /// How long to wait for a command's acknowledgement before giving up.
  static const Duration commandTimeout = Duration(seconds: 12);

  static const int _batteryPushOpcode = 0x5504;
  static const int _absentBattery = -1;

  final StarotFramer _framer = StarotFramer();
  final Map<int, Completer<StarotFrame>> _pending = {};
  final StreamController<StarotFrame> _incomingFrames = StreamController<StarotFrame>.broadcast();

  StreamSubscription<List<int>>? _linkSub;
  RecDotBatteryReport? _battery;
  RecDotVersionReport? _version;
  List<String> _serials = const [];

  /// Non-acknowledgement frames the buds send unprompted (call pushes, audio); the
  /// capture session listens here.
  Stream<StarotFrame> get incomingFrames => _incomingFrames.stream;

  /// The serial numbers read during the handshake.
  List<String> get serials => _serials;

  /// The firmware version read during the handshake.
  RecDotVersionReport? get version => _version;

  @override
  Future<void> connect({void Function(String deviceId, DeviceConnectionState state)? onConnectionStateChanged}) async {
    await super.connect(onConnectionStateChanged: onConnectionStateChanged);
    _linkSub = transport
        .getCharacteristicStream(RecDotLinkTransport.linkServiceUuid, RecDotLinkTransport.linkBytesCharacteristicUuid)
        .listen(_onBytes);
    await _runHandshake();
  }

  Future<void> _runHandshake() async {
    final bondAck = await _request(RecDotCommands.checkBondCode(), 0x5101);
    if ((bondAck.ackStatus ?? _absentBattery) != 0) {
      throw DeviceConnectionException('RecDot bond check failed (status ${bondAck.ackStatus})');
    }
    _serials = RecDotCommands.parseSerial((await _request(RecDotCommands.getSerial(), 0x550B)).ackData).serials;
    _version = RecDotCommands.parseVersion((await _request(RecDotCommands.getVersion(), 0x5500)).ackData);
    _battery = RecDotCommands.parseBattery((await _request(RecDotCommands.getBattery(), 0x5505)).ackData);
    await _request(RecDotCommands.setSeamlessRecord(true), 0x5534);
  }

  Future<StarotFrame> _request(List<int> frame, int opcode) {
    final completer = Completer<StarotFrame>();
    _pending[opcode] = completer;
    transport.writeCharacteristic(
        RecDotLinkTransport.linkServiceUuid, RecDotLinkTransport.linkBytesCharacteristicUuid, frame);
    return completer.future.timeout(commandTimeout, onTimeout: () {
      _pending.remove(opcode);
      throw DeviceConnectionException('RecDot did not acknowledge 0x${opcode.toRadixString(16)}');
    });
  }

  void _onBytes(List<int> bytes) {
    for (final frame in _framer.feed(bytes)) {
      _dispatch(frame);
    }
  }

  void _dispatch(StarotFrame frame) {
    if (frame.isAck) {
      final completer = _pending.remove(frame.opcode);
      if (completer != null && !completer.isCompleted) completer.complete(frame);
      return;
    }
    if (frame.command == _batteryPushOpcode) {
      _battery = RecDotCommands.parseBattery(frame.payload);
      return;
    }
    _incomingFrames.add(frame);
  }

  @override
  Future<int> performRetrieveBatteryLevel() async => _lowestPresentBattery();

  int _lowestPresentBattery() {
    final report = _battery;
    if (report == null) return _absentBattery;
    final present = [report.leftPercent, report.rightPercent].whereType<int>().toList();
    if (present.isEmpty) return _absentBattery;
    return present.reduce((a, b) => a < b ? a : b);
  }

  @override
  Future<BleAudioCodec> performGetAudioCodec() async => BleAudioCodec.pcm16;

  @override
  Future<int> performGetFeatures() async => OmiFeatures.battery;

  @override
  Future<List<int>> performGetButtonState() async => const [];

  @override
  Future<bool> performHasPhotoStreamingCharacteristic() async => false;

  @override
  Future<void> performSetLedDimRatio(int ratio) async {}

  @override
  Future<int?> performGetLedDimRatio() async => null;

  @override
  Future<void> performSetMicGain(int gain) async {}

  @override
  Future<int?> performGetMicGain() async => null;

  // The RecDot has no camera, accelerometer, image feed or on-device storage that Omi
  // reaches over the link, so these device capabilities report nothing.
  @override
  Future<void> performCameraStartPhotoController() async {}

  @override
  Future<void> performCameraStopPhotoController() async {}

  @override
  Future<StreamSubscription?> performGetBleStorageBytesListener({
    required void Function(List<int>) onStorageBytesReceived,
  }) async =>
      null;

  @override
  Future<StreamSubscription?> performGetImageListener({
    required void Function(OrientedImage orientedImage) onImageReceived,
  }) async =>
      null;

  @override
  Future<StreamSubscription<List<int>>?> performGetAccelListener({void Function(int)? onAccelChange}) async => null;

  @override
  Future<void> disconnect() async {
    await _linkSub?.cancel();
    _linkSub = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(DeviceConnectionException('RecDot disconnected'));
    }
    _pending.clear();
    if (!_incomingFrames.isClosed) await _incomingFrames.close();
    await super.disconnect();
  }
}
