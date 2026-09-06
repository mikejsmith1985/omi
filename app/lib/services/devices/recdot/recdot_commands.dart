// Typed command builders and reply parsers for the viaim RecDot, one layer above the
// raw STAROT codec.
//
// The connector and the FlashRecord sync speak intent ("check the bond code", "read the
// battery", "list stored recordings"); this file turns that intent into the exact frames
// specs/002-viaim-recdot-device/protocol.md §5–§7 documents and turns the buds' replies
// into records. It stays pure so it is testable without a device; opcode and attribute
// numbers are the only magic here, and each is named.
import 'dart:typed_data';

import 'package:omi/services/devices/recdot/starot_codec.dart';

/// Which earbud a command addresses.
enum RecDotSide {
  /// The left bud.
  left(1),

  /// The right bud.
  right(0);

  const RecDotSide(this.wireValue);

  /// The byte the protocol uses for this side in a list or download request.
  final int wireValue;

  /// The side a reply's side byte names, defaulting to left for anything unexpected.
  static RecDotSide fromWire(int value) => value == right.wireValue ? right : left;
}

/// The linear sample rate a call or stored recording used.
enum RecDotSampleRateMode {
  /// 16 kHz wideband G.722.
  wideband16k,

  /// 8 kHz narrowband G.722.
  narrowband8k,
}

/// Whether a stored recording is a two-way call or a single-channel room capture.
enum RecDotRecordingKind {
  /// A phone or VoIP call: far end and mic, two channels.
  call,

  /// A far-field room recording: one channel.
  room,
}

/// Battery for each part of the device; a null percent means the part is absent.
class RecDotBatteryReport {
  /// Creates a battery report.
  const RecDotBatteryReport({
    required this.leftPercent,
    required this.isLeftCharging,
    required this.rightPercent,
    required this.isRightCharging,
    required this.casePercent,
    required this.isCaseCharging,
  });

  /// Left bud charge, 0–100, or null when absent.
  final int? leftPercent;

  /// Whether the left bud is charging.
  final bool isLeftCharging;

  /// Right bud charge, or null when absent.
  final int? rightPercent;

  /// Whether the right bud is charging.
  final bool isRightCharging;

  /// Case charge, or null when unknown.
  final int? casePercent;

  /// Whether the case is charging.
  final bool isCaseCharging;
}

/// The firmware version and product id a `GET_VERSION` reply carries.
class RecDotVersionReport {
  /// Creates a version report.
  const RecDotVersionReport({required this.productId, required this.version});

  /// 8 = RecDot, 9 = RecDot 2.
  final int productId;

  /// Dotted firmware version, or empty when the buds report none.
  final String version;
}

/// The serial numbers a `GET_SN` reply carries, one per present part.
class RecDotSerialReport {
  /// Creates a serial report.
  const RecDotSerialReport({required this.serials});

  /// The ASCII serials in the reply, in attribute order.
  final List<String> serials;
}

/// One entry from a `GET_RECORD_LIST` reply, or the end-of-list marker.
class RecDotStoredRecording {
  /// Creates a stored-recording entry.
  const RecDotStoredRecording({
    required this.side,
    required this.index,
    required this.lengthBytes,
    required this.mode,
    required this.kind,
    required this.recordedAtEpochSeconds,
    required this.isEndMarker,
  });

  /// The end-of-list marker rather than a real entry.
  factory RecDotStoredRecording.endMarker() => const RecDotStoredRecording(
        side: RecDotSide.left,
        index: -1,
        lengthBytes: 0,
        mode: RecDotSampleRateMode.wideband16k,
        kind: RecDotRecordingKind.call,
        recordedAtEpochSeconds: 0,
        isEndMarker: true,
      );

  /// Which bud holds the recording.
  final RecDotSide side;

  /// The bud's index for the recording.
  final int index;

  /// The recording's size on the bud, in G.722 bytes.
  final int lengthBytes;

  /// The sample-rate mode the recording used.
  final RecDotSampleRateMode mode;

  /// Whether it is a two-way call or a room recording.
  final RecDotRecordingKind kind;

  /// The recording's start time, Unix seconds.
  final int recordedAtEpochSeconds;

  /// True for the sentinel that ends a list reply.
  final bool isEndMarker;
}

/// Builders and parsers for the RecDot command set. All members are pure.
class RecDotCommands {
  RecDotCommands._();

  static const int _checkBondCode = 0x5101;
  static const int _getSerial = 0x550B;
  static const int _getVersion = 0x5500;
  static const int _getBattery = 0x5505;
  static const int _setSeamlessRecord = 0x5534;
  static const int _setCallType = 0x5410;
  static const int _startCallAudio = 0x500B;
  static const int _stopCallAudio = 0x500C;
  static const int _getRecordList = 0x5A37;

  static const int _versionAttribute = 0x07;
  static const int _resumeAttribute = 2;
  static const int _pauseAttribute = 2;
  static const int _callTypeInternet = 1;
  static const int _bondCodeLength = 4;

  static const int _attrSide = 1;
  static const int _attrIndex = 2;
  static const int _attrLength = 4;
  static const int _attrSampleRate = 5;
  static const int _attrKind = 6;
  static const int _attrTimestamp = 7;
  static const int _attrEndMarker = 15;

  static const int _batteryAbsent = 0xFF;
  static const int _batteryChargingBit = 0x80;
  static const int _batteryPercentMask = 0x7F;
  static const int _narrowbandSampleValue = 1;
  static const int _roomKindValue = 1;

  /// Checks the bond code with the all-zero code the RecDot accepts.
  static Uint8List checkBondCode() => StarotCodec.encodeFrame(_checkBondCode, Uint8List(_bondCodeLength));

  /// Requests the serial numbers.
  static Uint8List getSerial() => StarotCodec.encodeFrame(_getSerial, Uint8List(0));

  /// Requests the firmware version.
  static Uint8List getVersion() => StarotCodec.encodeFrame(
      _getVersion,
      StarotCodec.encodeTlvGroup([
        TlvAttribute(1, Uint8List.fromList([_versionAttribute]))
      ]));

  /// Requests the current battery levels.
  static Uint8List getBattery() => StarotCodec.encodeFrame(_getBattery, Uint8List(0));

  /// Turns the bud's seamless ("Safe Record") flag on or off.
  static Uint8List setSeamlessRecord(bool enabled) => StarotCodec.encodeFrame(
        _setSeamlessRecord,
        StarotCodec.encodeTlvGroup([
          TlvAttribute(1, Uint8List.fromList([enabled ? 1 : 0]))
        ]),
      );

  /// Tells the bud the current call is a VoIP call so seamless record applies.
  static Uint8List declareVoipCall() => StarotCodec.encodeFrame(
        _setCallType,
        StarotCodec.encodeTlvGroup([
          TlvAttribute(1, Uint8List.fromList([_callTypeInternet]))
        ]),
      );

  /// Starts streaming call audio; [isResume] resumes a paused capture.
  static Uint8List startCallAudio({required bool isResume}) => StarotCodec.encodeFrame(
        _startCallAudio,
        StarotCodec.encodeTlvGroup([
          TlvAttribute(_resumeAttribute, Uint8List.fromList([isResume ? 1 : 0]))
        ]),
      );

  /// Stops streaming call audio; [isPause] keeps the session so it can resume.
  static Uint8List stopCallAudio({required bool isPause}) => StarotCodec.encodeFrame(
        _stopCallAudio,
        StarotCodec.encodeTlvGroup([
          TlvAttribute(_pauseAttribute, Uint8List.fromList([isPause ? 1 : 0]))
        ]),
      );

  /// Lists the recordings stored on one bud.
  static Uint8List listStoredRecordings({required RecDotSide side}) => StarotCodec.encodeFrame(
        _getRecordList,
        StarotCodec.encodeTlvGroup([
          TlvAttribute(_attrSide, Uint8List.fromList([side.wireValue]))
        ]),
      );

  /// Reads a battery reply payload into a report.
  static RecDotBatteryReport parseBattery(List<int> payload) {
    final byAttr = _attributesByType(payload);
    final left = _battery(byAttr[1]);
    final right = _battery(byAttr[2]);
    final caseUnit = _battery(byAttr[3]);
    return RecDotBatteryReport(
      leftPercent: left.$1,
      isLeftCharging: left.$2,
      rightPercent: right.$1,
      isRightCharging: right.$2,
      casePercent: caseUnit.$1,
      isCaseCharging: caseUnit.$2,
    );
  }

  /// Reads a version reply payload into a report.
  static RecDotVersionReport parseVersion(List<int> payload) {
    final data = _attributesByType(payload).values.first;
    if (data.length < 8) {
      return const RecDotVersionReport(productId: 0, version: '');
    }
    final productId = data[1];
    final version = [data[4], data[5], data[6], data[7]].join('.');
    return RecDotVersionReport(productId: productId, version: version);
  }

  /// Reads a serial reply payload into a report.
  static RecDotSerialReport parseSerial(List<int> payload) {
    final serials =
        StarotCodec.decodeTlvGroup(payload).map((attribute) => String.fromCharCodes(attribute.value)).toList();
    return RecDotSerialReport(serials: serials);
  }

  /// Reads one `GET_RECORD_LIST` reply into a stored-recording entry, or the end marker.
  static RecDotStoredRecording? parseStoredRecording(List<int> payload) {
    final byAttr = _attributesByType(payload);
    if (byAttr.containsKey(_attrEndMarker)) {
      return RecDotStoredRecording.endMarker();
    }
    if (!byAttr.containsKey(_attrIndex)) {
      return null;
    }
    final sampleValue = byAttr[_attrSampleRate]?.firstOrNull ?? 0;
    final kindValue = byAttr[_attrKind]?.firstOrNull ?? 0;
    return RecDotStoredRecording(
      side: RecDotSide.fromWire(byAttr[_attrSide]?.firstOrNull ?? RecDotSide.left.wireValue),
      index: _bigEndian(byAttr[_attrIndex]!),
      lengthBytes: _bigEndian(byAttr[_attrLength] ?? const []),
      mode:
          sampleValue == _narrowbandSampleValue ? RecDotSampleRateMode.narrowband8k : RecDotSampleRateMode.wideband16k,
      kind: kindValue == _roomKindValue ? RecDotRecordingKind.room : RecDotRecordingKind.call,
      recordedAtEpochSeconds: _bigEndian(byAttr[_attrTimestamp] ?? const []),
      isEndMarker: false,
    );
  }

  static Map<int, Uint8List> _attributesByType(List<int> payload) {
    final byAttr = <int, Uint8List>{};
    for (final attribute in StarotCodec.decodeTlvGroup(payload)) {
      byAttr[attribute.attribute] = attribute.value;
    }
    return byAttr;
  }

  static (int?, bool) _battery(Uint8List? value) {
    if (value == null || value.isEmpty || value[0] == _batteryAbsent) {
      return (null, false);
    }
    return (value[0] & _batteryPercentMask, (value[0] & _batteryChargingBit) != 0);
  }

  static int _bigEndian(List<int> bytes) {
    var result = 0;
    for (final byte in bytes) {
      result = (result << 8) | (byte & 0xFF);
    }
    return result;
  }
}
