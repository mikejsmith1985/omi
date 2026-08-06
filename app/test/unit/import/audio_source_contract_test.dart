/// Purpose: the obligations every AudioSource owes the capture pipeline, written once
/// and run against every implementation.
///
/// The pipeline downstream of `AudioSource` — the write-ahead log, the transcription
/// socket, the on-device engine — was built against how the microphone and Bluetooth
/// sources behave, and this feature changes none of it. So a file source is only safe
/// if it behaves identically. Stating that as a shared suite rather than as prose is
/// what makes "identically" checkable.
///
/// It runs against `PhoneMicSource` today. That is deliberate: a contract suite that
/// has never passed anything is just an assertion about code that does not exist yet.
/// Running it against the implementation the pipeline was actually written for proves
/// the suite describes reality. `FileImportSource` is added to it at T019, and has to
/// clear the same bar.
///
/// Obligations are from `specs/001-omi-audio-import/contracts/audio-source.md`.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/audio_sources/audio_source.dart';
import 'package:omi/services/audio_sources/file_import_source.dart';
import 'package:omi/services/audio_sources/phone_mic_source.dart';

/// Frame size the pipeline expects: 10 ms at 16 kHz, 16-bit mono.
const int expectedFrameSizeBytes = 320;

/// Builds a fresh, empty source.
///
/// Fresh on every call, because the suite relies on starting from a known state and a
/// shared instance would let one test's leftover buffer decide another test's result.
typedef AudioSourceFactory = AudioSource Function();

/// Runs the shared AudioSource contract against one implementation.
void runAudioSourceContract({
  required String description,
  required AudioSourceFactory createSource,
  required BleAudioCodec expectedCodec,
}) {
  group('AudioSource contract: $description', () {
    _framesMatchLiveCapture(createSource, expectedCodec);
    _processBytesIsTotal(createSource);
    _flushEmitsTailExactlyOnce(createSource);
    _nothingIsRetained(createSource);
    _identityIsPresent(createSource);
    _syncKeysAreUnique(createSource);
  });
}

/// O-1 — frames must be indistinguishable from live capture.
void _framesMatchLiveCapture(AudioSourceFactory createSource, BleAudioCodec expectedCodec) {
  group('O-1 frames are indistinguishable from live capture', () {
    test('every full frame is exactly the pipeline frame size', () {
      final frames = createSource().processBytes(List.filled(expectedFrameSizeBytes * 3, 0x7F));

      expect(frames.length, 3);
      for (final frame in frames) {
        expect(frame.payload.length, expectedFrameSizeBytes);
      }
    });

    test('frame payloads preserve the bytes given, in order', () {
      final input = List<int>.generate(expectedFrameSizeBytes, (i) => i % 256);

      final frames = createSource().processBytes(input);

      expect(frames.single.payload, equals(input));
    });

    test('reports the codec the pipeline expects', () {
      expect(createSource().codec, expectedCodec);
    });
  });
}

/// O-2 — `processBytes` must accept any length without throwing.
void _processBytesIsTotal(AudioSourceFactory createSource) {
  group('O-2 processBytes is total', () {
    test('buffers rather than emitting a short frame', () {
      expect(createSource().processBytes(List.filled(expectedFrameSizeBytes - 1, 0x01)), isEmpty);
    });

    test('emits exactly one frame at the boundary', () {
      expect(createSource().processBytes(List.filled(expectedFrameSizeBytes, 0x02)).length, 1);
    });

    test('emits one frame and keeps the remainder just past the boundary', () {
      final source = createSource();

      final frames = source.processBytes(List.filled(expectedFrameSizeBytes + 1, 0x03));

      expect(frames.length, 1);
      // The leftover byte is still buffered, so flushing produces one padded frame.
      expect(source.flush().length, 1);
    });

    test('accepts a zero-length call without throwing', () {
      expect(createSource().processBytes(const []), isEmpty);
    });

    test('assembles a frame across several partial calls', () {
      final source = createSource();
      source.processBytes(List.filled(100, 0x04));
      source.processBytes(List.filled(100, 0x05));

      final frames = source.processBytes(List.filled(120, 0x06));

      expect(frames.length, 1);
      expect(frames.single.payload[0], 0x04);
      expect(frames.single.payload[100], 0x05);
      expect(frames.single.payload[200], 0x06);
    });
  });
}

/// O-3 — `flush` must emit the tail once and only once.
void _flushEmitsTailExactlyOnce(AudioSourceFactory createSource) {
  group('O-3 flush emits the tail exactly once', () {
    test('pads a partial tail to a full frame', () {
      final source = createSource();
      source.processBytes(List.filled(100, 0x55));

      final flushed = source.flush();

      expect(flushed.length, 1);
      expect(flushed.single.payload.length, expectedFrameSizeBytes);
      expect(flushed.single.payload[99], 0x55);
      expect(flushed.single.payload[100], 0);
    });

    test('a second flush emits nothing', () {
      final source = createSource();
      source.processBytes(List.filled(100, 0x55));
      source.flush();

      // The case that matters: the last seconds of a recording appearing twice in a
      // transcript is a visible defect, and this is the only thing preventing it.
      expect(source.flush(), isEmpty);
    });

    test('flushing an untouched source emits nothing', () {
      expect(createSource().flush(), isEmpty);
    });

    test('flushing after an exact frame boundary emits nothing', () {
      final source = createSource();
      source.processBytes(List.filled(expectedFrameSizeBytes, 0x06));

      expect(source.flush(), isEmpty);
    });
  });
}

/// O-4 — nothing may be retained once the source is done.
void _nothingIsRetained(AudioSourceFactory createSource) {
  group('O-4 nothing is retained once the source is done', () {
    test('a flushed source starts clean again', () {
      final source = createSource();
      source.processBytes(List.filled(expectedFrameSizeBytes + 50, 0x07));
      source.flush();

      final frames = source.processBytes(List.filled(expectedFrameSizeBytes, 0x08));

      // A retained remainder would shift these bytes and corrupt the frame.
      expect(frames.length, 1);
      expect(frames.single.payload.every((byte) => byte == 0x08), isTrue);
    });
  });
}

/// O-5 — identity must be present so frames are attributable.
void _identityIsPresent(AudioSourceFactory createSource) {
  group('O-5 identity is present and usable', () {
    test('reports a device id and model', () {
      final source = createSource();

      expect(source.deviceId, isNotEmpty);
      expect(source.deviceModel, isNotEmpty);
    });
  });
}

/// Sync keys must not collide within a frame window, or the log cannot match them.
void _syncKeysAreUnique(AudioSourceFactory createSource) {
  group('sync keys are unique across a frame window', () {
    test('consecutive frames do not collide', () {
      final frames = createSource().processBytes(List.filled(expectedFrameSizeBytes * 8, 0x09));

      final keys = frames.map((frame) => frame.syncKey).toSet();
      expect(keys.length, frames.length);
    });
  });
}

/// O-1, stated as strictly as it can be: the frames must be byte-identical.
///
/// Every other test in this suite checks each source against a description of the
/// contract. This one checks the new source against the implementation the pipeline
/// was actually built for. If they ever diverge, the description is not what matters —
/// `PhoneMicSource` is, because that is what the downstream code was written to handle.
void _framesAreByteIdenticalToLiveCapture() {
  group('O-1 file frames are byte-identical to phone-mic frames', () {
    _sameInputProducesSameFrames();
    _sameInputProducesSameTail();
    _chunkingDoesNotChangeFrames();
  });
}

/// Pseudo-random but fixed, so a failure is reproducible rather than occasional.
List<int> _audioLike(int byteCount, {int seed = 7}) {
  final random = Random(seed);
  return List<int>.generate(byteCount, (_) => random.nextInt(256));
}

/// The same bytes through both sources must come out as the same frames.
void _sameInputProducesSameFrames() {
  test('identical input produces identical frames', () {
    final audio = _audioLike(expectedFrameSizeBytes * 5 + 137);

    final fromMic = PhoneMicSource().processBytes(audio);
    final fromFile = FileImportSource(importId: 'test').processBytes(audio);

    expect(fromFile.length, fromMic.length);
    for (var i = 0; i < fromMic.length; i++) {
      expect(fromFile[i].payload, equals(fromMic[i].payload), reason: 'frame $i payload differs');
      expect(fromFile[i].syncKey, equals(fromMic[i].syncKey), reason: 'frame $i sync key differs');
    }
  });
}

/// The padded final frame must match too — it is the one most easily got wrong.
void _sameInputProducesSameTail() {
  test('identical input produces an identical flushed tail', () {
    final audio = _audioLike(expectedFrameSizeBytes + 91, seed: 11);
    final mic = PhoneMicSource()..processBytes(audio);
    final file = FileImportSource(importId: 'test')..processBytes(audio);

    final micTail = mic.flush();
    final fileTail = file.flush();

    expect(fileTail.length, micTail.length);
    expect(fileTail.single.payload, equals(micTail.single.payload));
    expect(fileTail.single.syncKey, equals(micTail.single.syncKey));
  });
}

/// Frames must not depend on how the bytes happened to arrive.
///
/// A file source reads in whatever sizes the decoder returns, which will never match
/// the microphone's chunking. If the frames varied with the chunking, the byte-identity
/// above would hold only for the one input size the test happened to pick.
void _chunkingDoesNotChangeFrames() {
  test('the same audio split differently still yields the same frames', () {
    final audio = _audioLike(expectedFrameSizeBytes * 4, seed: 13);
    final wholeSource = FileImportSource(importId: 'whole');
    final splitSource = FileImportSource(importId: 'split');

    final whole = wholeSource.processBytes(audio);
    final split = <WalFrame>[
      ...splitSource.processBytes(audio.sublist(0, 33)),
      ...splitSource.processBytes(audio.sublist(33, 900)),
      ...splitSource.processBytes(audio.sublist(900)),
    ];

    expect(split.length, whole.length);
    for (var i = 0; i < whole.length; i++) {
      expect(split[i].payload, equals(whole[i].payload), reason: 'frame $i differs by chunking');
    }
  });
}

void main() {
  // Proves the suite describes the pipeline as it actually is, by running it against
  // the implementation the pipeline was written for.
  runAudioSourceContract(
    description: 'PhoneMicSource',
    createSource: PhoneMicSource.new,
    expectedCodec: BleAudioCodec.pcm16,
  );

  // The same bar, unsoftened, for the source this feature adds.
  runAudioSourceContract(
    description: 'FileImportSource',
    createSource: () => FileImportSource(importId: 'contract-test'),
    expectedCodec: BleAudioCodec.pcm16,
  );

  _framesAreByteIdenticalToLiveCapture();
}
