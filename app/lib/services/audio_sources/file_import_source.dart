import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/audio_sources/audio_source.dart';

/// Audio source for a recording being imported from a file.
///
/// The third implementation of [AudioSource], alongside the Bluetooth device and the
/// phone microphone. Everything downstream — the write-ahead log, the transcription
/// socket, the on-device engine — was written against how those two behave and is not
/// changed by this feature, so this must be indistinguishable from them in every
/// respect that the pipeline can observe.
///
/// It is therefore deliberately a near-copy of [PhoneMicSource]. Both take PCM16 at
/// 16 kHz mono and cut it into 320-byte frames (10 ms, 160 samples), because that is
/// what the pipeline expects and `test/unit/audio_source_test.dart` pins. Resisting the
/// urge to be cleverer here is the point: the shared contract suite in
/// `test/unit/import/audio_source_contract_test.dart` holds both to the same behaviour.
///
/// The one thing that differs is identity. [deviceModel] marks the resulting
/// conversation as an import rather than a live capture (FR-013), and [deviceId]
/// distinguishes one import from another so frames stay attributable (obligation O-5).
class FileImportSource implements AudioSource {
  /// Fixed frame size: 10 ms at 16 kHz, 16-bit mono = 320 bytes.
  ///
  /// Mirrors [PhoneMicSource.frameSize]. Stated rather than imported so that a change
  /// to one is a visible, deliberate change rather than a silent inheritance.
  static const int frameSize = 320;

  /// What imported recordings are called in write-ahead-log metadata.
  static const String importDeviceModel = 'Imported Recording';

  /// Identifies which import these frames belong to.
  final String importId;

  /// Creates a source for one import.
  FileImportSource({required this.importId});

  @override
  BleAudioCodec get codec => BleAudioCodec.pcm16;

  @override
  String get deviceId => 'file-import-$importId';

  @override
  String get deviceModel => importDeviceModel;

  final List<int> _buffer = [];
  int _frameIndex = 0;

  @override
  List<WalFrame> processBytes(List<int> rawBytes) {
    _buffer.addAll(rawBytes);
    final frames = <WalFrame>[];

    while (_buffer.length >= frameSize) {
      final payload = _buffer.sublist(0, frameSize);
      _buffer.removeRange(0, frameSize);

      frames.add(WalFrame(payload: payload, syncKey: FrameSyncKey.fromIndex(_frameIndex)));
      // The 1-byte index wraps at 256, matching both existing sources. Safe for the
      // same reason it is safe for them: markFrameSynced reverse-scans, so the most
      // recent frame with a given key is always the one matched.
      _frameIndex = (_frameIndex + 1) & 0xFF;
    }

    return frames;
  }

  @override
  List<int> getSocketPayload(List<int> rawBytes) => rawBytes;

  @override
  List<WalFrame> flush() {
    if (_buffer.isEmpty) return [];

    final padded = List<int>.filled(frameSize, 0);
    for (var i = 0; i < _buffer.length; i++) {
      padded[i] = _buffer[i];
    }
    // Cleared before the frame is built, so a second flush cannot emit the tail again.
    // The last seconds of a recording appearing twice in a transcript is a visible
    // defect, and this is the only thing preventing it (obligation O-3).
    _buffer.clear();

    final frame = WalFrame(payload: padded, syncKey: FrameSyncKey.fromIndex(_frameIndex));
    _frameIndex = (_frameIndex + 1) & 0xFF;
    return [frame];
  }

  /// How many bytes are buffered short of a complete frame.
  ///
  /// Exposed so the pump can tell the difference between "the recording is finished"
  /// and "there is a partial frame still waiting", which decides whether flushing is
  /// needed before the session is closed.
  int get bufferedByteCount => _buffer.length;
}
