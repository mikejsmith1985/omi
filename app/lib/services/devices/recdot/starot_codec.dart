// Pure byte-level codec for the viaim RecDot's "STAROT" v2 framing, TLV payloads,
// call-audio packets, FlashRecord chunks and BLE advertisement.
//
// Why this exists (Article VII gap): Omi has no generic framed-serial codec; every device
// carries its own (ring_protocol.dart, the Limitless protobuf reader). This one is kept
// free of transport and connection state so it can be tested byte-for-byte against the
// golden vectors in test/fixtures/recdot_golden/, which an independent Python reference
// generates (TranscriptBoss scripts/generate_recdot_vectors.py). The wire facts come from
// specs/002-viaim-recdot-device/protocol.md §3, §5.2, §6.2 and §2.2.
import 'dart:typed_data';

/// Thrown when bytes cannot be produced or read as the protocol notes describe.
class StarotCodecException implements Exception {
  /// Creates an exception with a message a log reader can act on.
  StarotCodecException(this.message);

  /// What went wrong, in words.
  final String message;

  @override
  String toString() => 'StarotCodecException: $message';
}

/// One `[len][attr][value]` entry inside a command payload.
class TlvAttribute {
  /// Creates an attribute; [value] may be empty.
  const TlvAttribute(this.attribute, this.value);

  /// The one-byte attribute id.
  final int attribute;

  /// The attribute's bytes.
  final Uint8List value;
}

/// A decoded v2 frame: a 16-bit command word and its payload.
class StarotFrame {
  /// Creates a frame from its command word and payload.
  const StarotFrame(this.command, this.payload);

  /// The command word as sent, acknowledgement bit included.
  final int command;

  /// Payload bytes after the four-byte header.
  final Uint8List payload;

  /// True when the buds are acknowledging a command rather than sending one.
  bool get isAck => (command & StarotCodec.ackFlag) != 0;

  /// The command without the acknowledgement bit.
  int get opcode => command & StarotCodec.opcodeMask;

  /// The status byte an acknowledgement carries first; null for plain commands.
  int? get ackStatus => isAck && payload.isNotEmpty ? payload[0] : null;

  /// Acknowledgement data after the status byte, or the whole payload otherwise.
  Uint8List get ackData => isAck ? payload.sublist(payload.isEmpty ? 0 : 1) : payload;
}

/// The far-end and near-end G.722 bytes carried by one call-audio packet.
class CallAudioPacket {
  /// Creates a packet from its two halves; either may be empty.
  const CallAudioPacket({required this.speaker, required this.mic});

  /// The far end of the call as the buds played it.
  final Uint8List speaker;

  /// The user's own voice from the buds' microphones.
  final Uint8List mic;
}

/// One chunk of a FlashRecord download.
class FlashChunk {
  /// Creates a chunk; an end-of-file chunk carries no audio.
  const FlashChunk({required this.offset, required this.speaker, required this.mic, required this.isEndOfFile});

  /// Byte offset into the recording on the bud.
  final int offset;

  /// Far-end (or single-stream) G.722 bytes.
  final Uint8List speaker;

  /// Near-end G.722 bytes when the recording is two-way.
  final Uint8List mic;

  /// True for the sentinel chunk that ends a download.
  final bool isEndOfFile;
}

/// What a RecDot says about itself in its BLE manufacturer data.
class RecDotAdvertisement {
  /// Creates an advertisement record.
  const RecDotAdvertisement({
    required this.productId,
    required this.leftBatteryPercent,
    required this.isLeftCharging,
    required this.rightBatteryPercent,
    required this.isRightCharging,
    required this.caseBatteryPercent,
    required this.isCaseCharging,
    required this.leftMac,
    required this.rightMac,
    required this.feature,
  });

  /// 8 = RecDot, 9 = RecDot 2, 6908 = OpenNote.
  final int productId;

  /// Left bud battery, null when the bud is absent.
  final int? leftBatteryPercent;

  /// Whether the left bud is charging.
  final bool isLeftCharging;

  /// Right bud battery, null when the bud is absent.
  final int? rightBatteryPercent;

  /// Whether the right bud is charging.
  final bool isRightCharging;

  /// Case battery, null when unknown.
  final int? caseBatteryPercent;

  /// Whether the case is charging.
  final bool isCaseCharging;

  /// Left bud Classic Bluetooth address, colon-separated upper-case hex.
  final String leftMac;

  /// Right bud Classic Bluetooth address.
  final String rightMac;

  /// 0 = normal, 1 = pairing, 2 = upgrade.
  final int feature;
}

/// Encoders and parsers for the RecDot wire protocol. All members are pure.
class StarotCodec {
  StarotCodec._();

  /// Sync byte of a v2 frame whose total length is at most 255.
  static const int shortFrameSync = 0x55;

  /// Sync byte of a v2 frame whose total length is 257 or more.
  static const int longFrameSync = 0x56;

  /// Sync, length and two command bytes.
  static const int frameHeaderLength = 4;

  /// Added to the length byte of a long frame.
  static const int longFrameLengthOffset = 256;

  /// Largest payload the buds accept.
  static const int maxPayloadLength = 508;

  /// The vendor encoder writes length 0 for this total, which its framer cannot resync on.
  static const int undecodableFrameLength = 256;

  /// Set on a command word when the buds acknowledge.
  static const int ackFlag = 0x8000;

  /// Masks the acknowledgement bit off a command word.
  static const int opcodeMask = 0x7FFF;

  static const int _channelMask = 0x0F;
  static const int _speakerChannelBit = 1;
  static const int _micChannelBit = 2;

  static const int _flashHeaderLength = 4;
  static const int _flashChannelSingle = 3;
  static const int _flashChannelTwoWay = 4;
  static const int _flashChannelEndOfFile = 255;
  static const int _flashFrameLength = 40;

  static const int _getRecordSideAttr = 1;
  static const int _getRecordIndexAttr = 2;
  static const int _getRecordOffsetAttr = 3;
  static const int _getRecordLengthAttr = 4;
  static const int _getRecordPasswordAttr = 5;
  static const int _getRecordCancelAttr = 0xFF;

  static const int _advertisementLength = 21;
  static const int _batteryAbsent = 0xFF;
  static const int _batteryChargingBit = 0x80;
  static const int _batteryPercentMask = 0x7F;
  static const int _prefixScale = 100;
  static const int _firstPrefixLetter = 0x30;

  /// Frames [payload] under [command] in v2 framing.
  static Uint8List encodeFrame(int command, List<int> payload) {
    if (payload.length > maxPayloadLength) {
      throw StarotCodecException('payload of ${payload.length} bytes exceeds $maxPayloadLength');
    }
    final totalLength = frameHeaderLength + payload.length;
    if (totalLength == undecodableFrameLength) {
      throw StarotCodecException('a 256-byte frame cannot be decoded by the vendor framer');
    }
    final frame = Uint8List(totalLength);
    frame[0] = totalLength > undecodableFrameLength ? longFrameSync : shortFrameSync;
    frame[1] = totalLength > undecodableFrameLength ? totalLength - longFrameLengthOffset : totalLength;
    frame[2] = (command >> 8) & 0xFF;
    frame[3] = command & 0xFF;
    frame.setRange(frameHeaderLength, totalLength, payload);
    return frame;
  }

  /// Encodes attributes back to back; each length counts the attribute byte but not itself.
  static Uint8List encodeTlvGroup(List<TlvAttribute> attributes) {
    final builder = BytesBuilder(copy: false);
    for (final entry in attributes) {
      builder.addByte(entry.value.length + 1);
      builder.addByte(entry.attribute);
      builder.add(entry.value);
    }
    return builder.toBytes();
  }

  /// Walks a TLV group; a length that runs past the payload is a malformed packet.
  static List<TlvAttribute> decodeTlvGroup(List<int> payload) {
    final attributes = <TlvAttribute>[];
    var position = 0;
    while (position < payload.length) {
      final declaredLength = payload[position];
      final valueEnd = position + 1 + declaredLength;
      if (declaredLength < 1 || valueEnd > payload.length) {
        throw StarotCodecException('TLV at offset $position runs past the payload');
      }
      attributes.add(TlvAttribute(payload[position + 1], Uint8List.fromList(payload.sublist(position + 2, valueEnd))));
      position = valueEnd;
    }
    return attributes;
  }

  /// Splits a `0x5007` payload into its far-end and near-end halves.
  static CallAudioPacket splitCallAudio(List<int> payload) {
    if (payload.isEmpty) {
      throw StarotCodecException('call audio packet has no channel byte');
    }
    final channels = payload[0] & _channelMask;
    final audio = Uint8List.fromList(payload.sublist(1));
    final hasSpeaker = (channels & _speakerChannelBit) != 0;
    final hasMic = (channels & _micChannelBit) != 0;
    if (hasSpeaker && hasMic) {
      if (audio.length.isOdd) {
        throw StarotCodecException('two-channel call audio must have an even payload');
      }
      final half = audio.length ~/ 2;
      return CallAudioPacket(speaker: audio.sublist(0, half), mic: audio.sublist(half));
    }
    if (hasSpeaker) {
      return CallAudioPacket(speaker: audio, mic: Uint8List(0));
    }
    return CallAudioPacket(speaker: Uint8List(0), mic: hasMic ? audio : Uint8List(0));
  }

  /// Parses a `0x5A3A` chunk: 3-byte big-endian offset, channel tag, audio.
  static FlashChunk parseFlashChunk(List<int> payload) {
    if (payload.length < _flashHeaderLength) {
      throw StarotCodecException('flash chunk shorter than its header');
    }
    final offset = (payload[0] << 16) | (payload[1] << 8) | payload[2];
    final channel = payload[3];
    final audio = Uint8List.fromList(payload.sublist(_flashHeaderLength));
    switch (channel) {
      case _flashChannelEndOfFile:
        return FlashChunk(offset: offset, speaker: Uint8List(0), mic: Uint8List(0), isEndOfFile: true);
      case _flashChannelSingle:
        return FlashChunk(offset: offset, speaker: audio, mic: Uint8List(0), isEndOfFile: false);
      case _flashChannelTwoWay:
        final halves = _deinterleaveFlashFrames(audio);
        return FlashChunk(offset: offset, speaker: halves[0], mic: halves[1], isEndOfFile: false);
      default:
        throw StarotCodecException('unknown flash channel tag $channel');
    }
  }

  /// Two-way flash audio alternates 40-byte frames: speaker, mic, speaker, mic.
  static List<Uint8List> _deinterleaveFlashFrames(Uint8List audio) {
    final speaker = BytesBuilder(copy: false);
    final mic = BytesBuilder(copy: false);
    var frameIndex = 0;
    for (var start = 0; start < audio.length; start += _flashFrameLength) {
      final end = start + _flashFrameLength > audio.length ? audio.length : start + _flashFrameLength;
      (frameIndex.isEven ? speaker : mic).add(audio.sublist(start, end));
      frameIndex++;
    }
    return [speaker.toBytes(), mic.toBytes()];
  }

  /// Builds the payload that starts or resumes a FlashRecord download.
  ///
  /// The integers are little-endian, unlike every value the buds send back.
  static Uint8List encodeGetRecord({
    required int side,
    required int index,
    required int offset,
    required int length,
    String? password,
  }) {
    final attributes = [
      TlvAttribute(_getRecordSideAttr, Uint8List.fromList([side])),
      TlvAttribute(_getRecordIndexAttr, _littleEndian32(index)),
      TlvAttribute(_getRecordOffsetAttr, _littleEndian32(offset)),
      TlvAttribute(_getRecordLengthAttr, _littleEndian32(length)),
      if (password != null) TlvAttribute(_getRecordPasswordAttr, Uint8List.fromList(password.codeUnits)),
    ];
    return encodeTlvGroup(attributes);
  }

  /// The payload that cancels a running download: a single attribute 0xFF.
  static Uint8List encodeGetRecordCancel() => encodeTlvGroup([TlvAttribute(_getRecordCancelAttr, Uint8List(0))]);

  /// Decodes the 21-byte manufacturer payload the buds advertise over BLE.
  static RecDotAdvertisement decodeAdvertisement(List<int> manufacturerData) {
    if (manufacturerData.length < _advertisementLength) {
      throw StarotCodecException('advertisement manufacturer data shorter than $_advertisementLength bytes');
    }
    final prefixLetter = manufacturerData[1];
    final prefixValue = prefixLetter > _firstPrefixLetter ? prefixLetter * _prefixScale : 0;
    return RecDotAdvertisement(
      productId: prefixValue + manufacturerData[0],
      leftBatteryPercent: _batteryPercent(manufacturerData[3]),
      isLeftCharging: _isCharging(manufacturerData[3]),
      rightBatteryPercent: _batteryPercent(manufacturerData[4]),
      isRightCharging: _isCharging(manufacturerData[4]),
      caseBatteryPercent: _batteryPercent(manufacturerData[5]),
      isCaseCharging: _isCharging(manufacturerData[5]),
      leftMac: _formatMac(manufacturerData.sublist(8, 14)),
      rightMac: _formatMac(manufacturerData.sublist(14, 20)),
      feature: manufacturerData[20],
    );
  }

  static int? _batteryPercent(int raw) => raw == _batteryAbsent ? null : raw & _batteryPercentMask;

  static bool _isCharging(int raw) => raw != _batteryAbsent && (raw & _batteryChargingBit) != 0;

  static String _formatMac(List<int> raw) =>
      raw.map((octet) => octet.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');

  static Uint8List _littleEndian32(int value) {
    final bytes = Uint8List(4);
    ByteData.view(bytes.buffer).setUint32(0, value, Endian.little);
    return bytes;
  }
}

/// Reassembles v2 frames from a byte stream that arrives in arbitrary chunks.
///
/// Resynchronises on the next `0x55`/`0x56` after garbage and never yields a partial
/// frame. The legacy `0xFF` v1 sync is deliberately not recognised: the RecDot only ever
/// speaks v2, and honouring `0xFF` would let a single stray byte swallow real frames.
class StarotFramer {
  final BytesBuilder _pending = BytesBuilder(copy: true);

  /// Appends [bytes] and returns every frame that is now complete, in order.
  List<StarotFrame> feed(List<int> bytes) {
    _pending.add(bytes);
    final frames = <StarotFrame>[];
    final buffer = _pending.toBytes();
    var position = 0;
    while (true) {
      position = _skipToSync(buffer, position);
      final frameEnd = _frameEnd(buffer, position);
      if (frameEnd == null) break;
      final frame = _frameAt(buffer, position, frameEnd);
      if (frame != null) frames.add(frame);
      position = frameEnd;
    }
    _pending.clear();
    _pending.add(buffer.sublist(position));
    return frames;
  }

  static int _skipToSync(Uint8List buffer, int position) {
    var index = position;
    while (index < buffer.length && !_isSyncByte(buffer[index])) {
      index++;
    }
    return index;
  }

  static bool _isSyncByte(int byte) => byte == StarotCodec.shortFrameSync || byte == StarotCodec.longFrameSync;

  /// The end index of the frame starting at [position], or null if it is incomplete.
  static int? _frameEnd(Uint8List buffer, int position) {
    if (position + 2 > buffer.length) return null;
    final sync = buffer[position];
    final totalLength = sync == StarotCodec.shortFrameSync
        ? buffer[position + 1]
        : buffer[position + 1] + StarotCodec.longFrameLengthOffset;
    if (totalLength < StarotCodec.frameHeaderLength) return position + 1;
    final end = position + totalLength;
    return end <= buffer.length ? end : null;
  }

  static StarotFrame? _frameAt(Uint8List buffer, int start, int end) {
    if (end - start < StarotCodec.frameHeaderLength) return null;
    final command = (buffer[start + 2] << 8) | buffer[start + 3];
    return StarotFrame(command, buffer.sublist(start + StarotCodec.frameHeaderLength, end));
  }
}
