/// Purpose: turn a recording on disk into the PCM the transcription pipeline expects,
/// using the decoders both operating systems already ship.
///
/// This wraps the generated Pigeon bridge so the rest of the import depends on an
/// interface we own rather than on generated code. That matters for two reasons: the
/// generated file is regenerated wholesale on every contract change, and it speaks in
/// platform errors rather than in things a user can act on.
///
/// **Requires code generation before it will compile**:
///     dart run pigeon --input lib/audio_decoder_interface.dart
/// Never edit the generated `lib/gen/audio_decoder_pigeon.g.dart`.
///
/// Decoding is pull-based on purpose. Native decodes only when [DecodeSession.readChunk]
/// asks it to, which is what lets the pump bound how much audio is in flight (plan.md
/// D-3). A decoder that pushed as fast as it could would race ahead of transcription
/// and reintroduce the unbounded-memory failure SC-005 exists to prevent.
library;

import 'package:flutter/services.dart';
import 'package:omi/gen/audio_decoder_pigeon.g.dart';
import 'package:omi/services/import/import_failures.dart';

/// Output shape the pipeline requires, matching `PhoneMicSource`.
///
/// Not a preference: `test/unit/audio_source_test.dart` pins the frame at 320 bytes,
/// described there as 10 ms at 16 kHz 16-bit mono. Frames of any other shape will not
/// survive the pipeline.
const int decoderSampleRate = 16000;
const int decoderChannelCount = 1;
const int decoderBytesPerSample = 2;

/// How much PCM to ask for in one read.
///
/// One second of audio at the decoder's output rate. Large enough that the bridge
/// crossing is not the bottleneck, small enough that a cancelled import stops
/// promptly rather than after finishing a large read.
const int decoderReadChunkBytes = decoderSampleRate * decoderBytesPerSample;

/// What a recording turned out to be, before any decoding work is done.
class AudioProbe {
  /// Whether the platform decoder can read this file.
  final bool isDecodable;

  /// How long the recording runs.
  final Duration duration;

  /// The rate the file is stored at, before conversion.
  final int sourceSampleRate;

  /// The channel count the file is stored with, before downmixing.
  final int sourceChannelCount;

  /// What the platform said the codec is, for diagnostics.
  final String? codecDescription;

  /// When the recording was made, according to metadata inside the file.
  ///
  /// Null is common and expected — many recorders write no date. It is read anyway
  /// because it is the only evidence of a recording's true time that survives the file
  /// being copied, shared or re-exported.
  final DateTime? embeddedCreationTime;

  /// Creates a probe result.
  const AudioProbe({
    required this.isDecodable,
    required this.duration,
    required this.sourceSampleRate,
    required this.sourceChannelCount,
    this.codecDescription,
    this.embeddedCreationTime,
  });
}

/// A source of decoded PCM, read on demand.
///
/// The pump depends on this rather than on [DecodeSession] so its pacing can be tested
/// against a decoder the test controls. Pacing is the one behaviour whose failure shows
/// up as the app being killed on someone else's phone rather than as a wrong result, so
/// it needs to be provable without a device in the loop.
///
/// Deliberately read-only: opening and closing a session belongs to whoever owns it,
/// not to whoever consumes it.
abstract class DecodedAudioReader {
  /// Reads the next piece of decoded PCM, or an empty list at the end of the audio.
  Future<Uint8List> readChunk({int maxBytes});
}

/// One file open for decoding.
///
/// Always close it, including on failure — a native decoder left open holds a hardware
/// codec that other apps may be waiting for.
class DecodeSession implements DecodedAudioReader {
  final AudioDecoderHostApi _api;
  final int _sessionId;
  bool _isClosed = false;

  DecodeSession._(this._api, this._sessionId);

  /// Whether this session has been closed.
  bool get isClosed => _isClosed;

  /// Reads the next piece of decoded PCM, or an empty list at the end of the audio.
  ///
  /// Returns fewer bytes than [maxBytes] only at the end of the recording, so an empty
  /// result is the end-of-audio signal and a short result is not.
  @override
  Future<Uint8List> readChunk({int maxBytes = decoderReadChunkBytes}) async {
    if (_isClosed) return Uint8List(0);
    try {
      return await _api.readChunk(_sessionId, maxBytes);
    } on PlatformException catch (error) {
      throw describeDecodeFailure(error.code, error.message);
    }
  }

  /// Releases the native decoder. Safe to call more than once.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _api.closeSession(_sessionId);
    } on PlatformException {
      // The session is already gone natively, which is the state we wanted. Turning
      // this into a user-visible failure would report a problem that does not exist.
    }
  }
}

/// Decodes audio files using the platform's own decoders.
class NativeAudioDecoder {
  final AudioDecoderHostApi _api;
  int _nextSessionId = 1;

  /// Creates a decoder over the generated bridge.
  NativeAudioDecoder() : _api = AudioDecoderHostApi();

  /// Creates a decoder over a supplied bridge, for tests.
  NativeAudioDecoder.withApi(this._api);

  /// Inspects a file without decoding it.
  ///
  /// Cheap enough to call before committing to an import, which is what makes FR-003's
  /// "fail immediately rather than after a long wait" achievable.
  Future<AudioProbe> probe(String filePath) async {
    final result = await _callProbe(filePath);
    if (!result.isDecodable) {
      throw undecodableRecording(result.codecDescription, result.rejectionReason);
    }
    if (result.durationSeconds <= 0) {
      throw emptyRecording();
    }
    final createdAt = result.creationEpochMillis;
    return AudioProbe(
      isDecodable: true,
      duration: Duration(milliseconds: (result.durationSeconds * 1000).round()),
      sourceSampleRate: result.sourceSampleRate,
      sourceChannelCount: result.sourceChannelCount,
      codecDescription: result.codecDescription,
      embeddedCreationTime: createdAt == null ? null : DateTime.fromMillisecondsSinceEpoch(createdAt),
    );
  }

  /// Opens a file for decoding.
  ///
  /// The session id is minted here and carried on every native event, so a late event
  /// from an abandoned session cannot be mistaken for one from the current session —
  /// the protection `phone_mic_interface.dart` uses, for the same reason.
  Future<DecodeSession> openSession(String filePath) async {
    final sessionId = _nextSessionId++;
    try {
      await _api.openSession(filePath, sessionId);
      return DecodeSession._(_api, sessionId);
    } on PlatformException catch (error) {
      throw describeDecodeFailure(error.code, error.message);
    }
  }

  /// Calls the native probe, translating a platform error into a usable one.
  Future<AudioProbeResult> _callProbe(String filePath) async {
    try {
      return await _api.probe(filePath);
    } on PlatformException catch (error) {
      throw describeDecodeFailure(error.code, error.message);
    }
  }
}
