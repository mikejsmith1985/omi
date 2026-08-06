/// Purpose: supply the reference recordings the import integration tests run against,
/// without committing hours of audio to a repository we intend to contribute upstream.
///
/// Two kinds of fixture, for two different reasons:
///
///   * **Synthesised** — silence, a zero-length file, a truncated file, and a tone of
///     an exact known duration. These are generated at test time from a few lines of
///     code, so they are byte-identical on every machine and cost the repository
///     nothing. Anything whose value is determinism belongs here.
///
///   * **Provided** — real speech, including the one-hour recording that proves
///     memory stays bounded (SC-005). These cannot be synthesised: the thing under
///     test is how a real transcription engine handles real speech, and a generated
///     tone would prove nothing about it. They also cannot be committed — an hour of
///     16 kHz mono PCM16 is about 115 MB, and a pull request carrying that would be
///     refused on sight. So they are read from a directory on the device and the test
///     skips with a clear message when they are absent.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Audio shape the transcription pipeline expects, matching `PhoneMicSource`.
///
/// These are not ours to choose. `test/unit/audio_source_test.dart` pins the frame
/// at 320 bytes and describes it as 10 ms at 16 kHz 16-bit mono; the decoder in
/// `native_decoder.dart` must produce exactly this or the frames will not match.
const int fixtureSampleRate = 16000;
const int fixtureBytesPerSample = 2;
const int fixtureChannelCount = 1;

/// Where a person running these tests puts the real recordings.
///
/// Named rather than discovered so a missing fixture produces "put the file here"
/// instead of "not found".
const String providedFixtureDirectoryName = 'omi_import_test_fixtures';

/// A recording the tests need but cannot generate.
enum ProvidedFixture {
  /// A few seconds of clear speech. The everyday case.
  shortSpeechWav('short_speech.wav'),

  /// The same audio as [shortSpeechWav], re-encoded. Proves the decoder handles
  /// what a consumer recorder actually exports (plan.md D-1).
  shortSpeechM4a('short_speech.m4a'),

  /// The same audio again, as MP3.
  shortSpeechMp3('short_speech.mp3'),

  /// An hour of continuous speech. Carries SC-003, SC-005 and the word-boundary
  /// obligation (contract P-2) — none of which a short clip can exercise.
  longSpeechM4a('one_hour_speech.m4a');

  const ProvidedFixture(this.fileName);

  /// The name the file must have in the fixture directory.
  final String fileName;
}

/// Locates a recording the test cannot generate.
///
/// Returns null when it is absent, so the caller can skip with a message naming
/// the file and where to put it. Failing outright would make an incomplete fixture
/// set look like a broken feature.
Future<File?> findProvidedFixture(Directory root, ProvidedFixture fixture) async {
  final candidate = File('${root.path}/$providedFixtureDirectoryName/${fixture.fileName}');
  return await candidate.exists() ? candidate : null;
}

/// Explains a missing fixture in terms of what to do about it.
String describeMissingFixture(Directory root, ProvidedFixture fixture) {
  return 'Skipped: ${fixture.fileName} is not present. '
      'Put a recording at ${root.path}/$providedFixtureDirectoryName/${fixture.fileName} '
      'and run again. It is not committed because real speech fixtures are too large '
      'for a repository we intend to contribute upstream.';
}

/// Builds a WAV file of pure silence lasting [seconds].
///
/// Used to prove a recording with no speech is reported rather than turned into an
/// empty conversation (FR-011).
Uint8List buildSilentWav({required int seconds}) {
  final sampleCount = fixtureSampleRate * seconds;
  return _wrapInWavHeader(Uint8List(sampleCount * fixtureBytesPerSample));
}

/// Builds a WAV file containing a steady tone of exactly [seconds] duration.
///
/// The point is the *duration*, not the sound: a decoder that drops or duplicates
/// samples changes the byte count, and a known length is what makes that visible.
Uint8List buildTonedWav({required int seconds, double frequencyHz = 440.0}) {
  final sampleCount = fixtureSampleRate * seconds;
  final samples = Int16List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    final angle = 2 * math.pi * frequencyHz * i / fixtureSampleRate;
    samples[i] = (math.sin(angle) * 0x4000).round();
  }
  return _wrapInWavHeader(samples.buffer.asUint8List());
}

/// Builds a file whose header promises far more audio than it contains.
///
/// This is what a recording interrupted mid-export actually looks like, and it must
/// fail with an explanation rather than producing a truncated transcript (FR-018).
Uint8List buildTruncatedWav({required int claimedSeconds}) {
  final full = buildTonedWav(seconds: claimedSeconds);
  final cutPoint = math.min(full.length, _wavHeaderLength + 1024);
  return Uint8List.sublistView(full, 0, cutPoint);
}

/// A file with no bytes at all. Selecting one must be refused before any work starts.
Uint8List buildEmptyFile() => Uint8List(0);

const int _wavHeaderLength = 44;

/// Wraps raw PCM16 in the WAV header the pipeline's sample rate implies.
Uint8List _wrapInWavHeader(Uint8List pcmBytes) {
  final header = ByteData(_wavHeaderLength);
  final byteRate = fixtureSampleRate * fixtureChannelCount * fixtureBytesPerSample;

  _writeAscii(header, 0, 'RIFF');
  header.setUint32(4, _wavHeaderLength - 8 + pcmBytes.length, Endian.little);
  _writeAscii(header, 8, 'WAVE');
  _writeAscii(header, 12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // PCM subchunk size
  header.setUint16(20, 1, Endian.little); // PCM, uncompressed
  header.setUint16(22, fixtureChannelCount, Endian.little);
  header.setUint32(24, fixtureSampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, fixtureChannelCount * fixtureBytesPerSample, Endian.little);
  header.setUint16(34, fixtureBytesPerSample * 8, Endian.little);
  _writeAscii(header, 36, 'data');
  header.setUint32(40, pcmBytes.length, Endian.little);

  return Uint8List.fromList(header.buffer.asUint8List() + pcmBytes);
}

/// Writes a four-character chunk identifier at [offset].
void _writeAscii(ByteData target, int offset, String value) {
  for (var i = 0; i < value.length; i++) {
    target.setUint8(offset + i, value.codeUnitAt(i));
  }
}
