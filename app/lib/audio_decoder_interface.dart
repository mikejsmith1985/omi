import 'package:pigeon/pigeon.dart';

// Dedicated contract for the native audio-file decoders (iOS and Android).
// Kept separate from pigeon_interfaces.dart so the module owns its generated files
// end to end, following the phone_mic_interface.dart precedent.
// Regenerate with: dart run pigeon --input lib/audio_decoder_interface.dart
//
// Why native decoders rather than a Dart package: nothing in the app can currently
// read an .m4a — the existing transcoders in utils/audio/audio_transcoder.dart handle
// only the PCM and Opus that Omi's own hardware produces. Both operating systems
// already ship hardware-accelerated decoders for every format a consumer voice
// recorder emits, so reaching them costs nothing in app size and needs no maintenance
// when a codec changes. The alternative, ffmpeg_kit_flutter, was retired upstream in
// 2025 with its prebuilt binaries withdrawn.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/gen/audio_decoder_pigeon.g.dart',
    dartOptions: DartOptions(),
    swiftOut: 'ios/Runner/AudioDecoder/AudioDecoderPigeon.g.swift',
    // PigeonCommunicator.g.swift already defines `PigeonError`; a second generated
    // file using the default name would collide at link time.
    swiftOptions: SwiftOptions(errorClassName: 'AudioDecoderPigeonError'),
    kotlinOut: 'android/app/src/main/kotlin/com/friend/ios/audiodecoder/AudioDecoderPigeon.g.kt',
    // Own package and error class, for the same reason as the Swift side.
    kotlinOptions: KotlinOptions(package: 'com.friend.ios.audiodecoder', errorClassName: 'AudioDecoderPigeonError'),
    dartPackageName: 'omi_audio_decoder',
  ),
)

/// What a decode session is doing. Mirrored to Dart on every transition.
enum AudioDecodeState {
  /// No decode has been asked for yet.
  idle,

  /// The file is being opened and its format read, before any audio is produced.
  opening,

  /// Audio is being produced and handed to the pipeline.
  decoding,

  /// The whole file was decoded successfully.
  finished,

  /// Decoding stopped because something went wrong; the reason travels separately.
  failed,

  /// Decoding stopped because the user asked it to, which is not a failure.
  cancelled,
}

/// What the decoder found in the file before decoding it.
///
/// Returned by probe() so an unsupported or empty recording is refused immediately,
/// rather than after the user has waited through a long decode (FR-003).
class AudioProbeResult {
  /// Whether the platform decoder can read this file.
  bool isDecodable;

  /// How long the recording runs, in seconds. Drives the time estimate (FR-016).
  double durationSeconds;

  /// The source sample rate, before conversion.
  int sourceSampleRate;

  /// The source channel count, before downmixing.
  int sourceChannelCount;

  /// The codec the platform reported, for diagnostics and for naming a refusal.
  String? codecDescription;

  /// Why the file cannot be decoded, when [isDecodable] is false.
  String? rejectionReason;

  /// When the recording was made, from metadata inside the file, in epoch
  /// milliseconds — or null when the file carries no such date.
  ///
  /// This is the strongest evidence of a recording's true time and the only source
  /// that cannot be disturbed by copying the file around, so it is read here at probe
  /// time rather than guessed at later. Null is common and expected: plenty of
  /// recorders write no date at all, which is what the filename and the user are for.
  int? creationEpochMillis;

  /// Creates the result of probing one file, before any of it is decoded.
  AudioProbeResult(
    this.isDecodable,
    this.durationSeconds,
    this.sourceSampleRate,
    this.sourceChannelCount,
    this.codecDescription,
    this.rejectionReason,
    this.creationEpochMillis,
  );
}

/// Dart -> native.
///
/// The decoder always produces **16 kHz, mono, signed 16-bit little-endian PCM**,
/// resampling and downmixing as needed. That shape is not a preference: the existing
/// test/unit/audio_source_test.dart pins PhoneMicSource at 320-byte frames described
/// as 10 ms at 16 kHz 16-bit mono, and frames that do not match will not survive the
/// pipeline.
///
/// Decoding is pull-based. Native decodes only when [readChunk] asks it to, so the
/// pump can bound how much audio is in flight (plan.md D-3). A push-based decoder
/// would race ahead of transcription and reintroduce the unbounded-memory failure
/// SC-005 exists to prevent.
@HostApi()
abstract class AudioDecoderHostApi {
  /// Inspects a file without decoding it. Cheap, and safe to call before committing.
  ///
  /// Throws a PlatformException with code `file_unreadable` when the path cannot be
  /// opened at all.
  AudioProbeResult probe(String filePath);

  /// Opens [filePath] for decoding under [sessionId] and resolves once ready.
  ///
  /// `sessionId` is minted by Dart and carried on every event, so a late event from an
  /// abandoned session cannot be mistaken for one from the current session — the same
  /// protection phone_mic_interface.dart uses, and for the same reason.
  ///
  /// Throws a PlatformException with one of: `file_unreadable`, `format_unsupported`,
  /// `no_audio_track`, `decoder_init_failed`.
  void openSession(String filePath, int sessionId);

  /// Decodes and returns up to [maxBytes] of PCM, or an empty list at end of audio.
  ///
  /// The caller decides when to ask, which is what makes the pacing in plan.md D-3
  /// possible. Returns fewer bytes than asked for only at the end of the recording.
  Uint8List readChunk(int sessionId, int maxBytes);

  /// Closes a session and releases the native decoder.
  ///
  /// Safe to call on a session that already finished or failed, because the pump's
  /// cleanup path must not need to know which happened.
  void closeSession(int sessionId);
}

/// Native -> Dart.
@FlutterApi()
abstract class AudioDecoderFlutterApi {
  /// Reports a state transition for [sessionId].
  void onStateChanged(int sessionId, AudioDecodeState state);

  /// Reports that decoding failed, with a code matching the ones openSession throws.
  void onDecodeError(int sessionId, String code, String message);
}
