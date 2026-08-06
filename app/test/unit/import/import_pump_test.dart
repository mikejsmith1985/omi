/// Purpose: prove the pump paces by audio in flight, not by wall clock and not at all.
///
/// These are the tests that catch obligation P-1 before a device does. A pacing bug
/// does not show up as a wrong transcript — it shows up as the app being killed
/// part-way through a long import, on someone else's phone, with no useful report. So
/// the pacing is checked here against a fake pipeline whose depth the test controls,
/// where "did it wait?" is a deterministic question rather than a timing race.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/audio/native_decoder.dart';
import 'package:omi/services/audio_sources/audio_source.dart';
import 'package:omi/services/audio_sources/file_import_source.dart';
import 'package:omi/services/import/import_pump.dart';

/// A pipeline whose depth the test decides.
///
/// Drains nothing on its own: a test that wants the pump to proceed must drain it
/// explicitly, which is what makes "the pump waited" observable rather than inferred.
class _FakeSink implements ImportAudioSink {
  final List<WalFrame> received = [];
  int queuedBytes = 0;
  bool transcribing = false;

  @override
  void sendFrame(WalFrame frame) {
    received.add(frame);
    queuedBytes += frame.payload.length;
  }

  @override
  int get bytesAwaitingTranscription => queuedBytes;

  @override
  bool get isTranscribing => transcribing;

  /// Pretends a transcription pass consumed everything queued.
  void drain() => queuedBytes = 0;
}

/// A decoder that hands out a fixed amount of audio, then reports the end.
class _FakeDecoder implements DecodedAudioReader {
  _FakeDecoder({required this.totalBytes, this.chunkSize = 3200});

  final int totalBytes;
  final int chunkSize;
  int served = 0;
  int readCallCount = 0;

  @override
  Future<Uint8List> readChunk({int maxBytes = 32000}) async {
    readCallCount++;
    if (served >= totalBytes) return Uint8List(0);
    final size = served + chunkSize > totalBytes ? totalBytes - served : chunkSize;
    served += size;
    return Uint8List(size);
  }
}

/// A memory-pressure signal the test controls.
class _FakePressure implements MemoryPressureSignal {
  bool underPressure = false;

  @override
  bool get isUnderPressure => underPressure;
}

/// Builds a pump with a poll interval short enough that tests stay fast.
ImportPump buildPump(
  _FakeSink sink,
  _FakeDecoder decoder, {
  int? boundBytes,
  MemoryPressureSignal? pressure,
}) {
  return ImportPump(
    source: FileImportSource(importId: 'pump-test'),
    decoder: decoder,
    sink: sink,
    maxAudioInFlightBytes: boundBytes ?? pipelineBytesPerSecond,
    pollInterval: const Duration(milliseconds: 1),
    memoryPressure: pressure ?? const NoMemoryPressure(),
  );
}

/// Under memory pressure the import must slow down, not stop and not die.
void _backsOffUnderMemoryPressure() {
  group('memory pressure shrinks the budget rather than killing the import', () {
    _holdsLessInFlightUnderPressure();
    _stillFinishesUnderPressure();
  });
}

/// Fills the pipeline without draining it, and reports how much it accepted.
Future<int> _queuedAfterFilling(int bound, MemoryPressureSignal? signal) async {
  final sink = _FakeSink();
  final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 60);
  final pump = buildPump(sink, decoder, boundBytes: bound, pressure: signal);
  final cancellation = ImportCancellation();

  final run = pump.run(cancellation: cancellation);
  await Future<void>.delayed(const Duration(milliseconds: 30));
  cancellation.cancel();
  await run;
  return sink.queuedBytes;
}

/// The whole point of the signal: less audio held while the system is squeezed.
void _holdsLessInFlightUnderPressure() {
  test('holds less audio in flight while the system wants memory back', () async {
    const bound = pipelineBytesPerSecond * 8;

    final relaxedQueued = await _queuedAfterFilling(bound, null);
    final squeezedQueued = await _queuedAfterFilling(bound, _FakePressure()..underPressure = true);

    expect(squeezedQueued, lessThan(relaxedQueued));
  });
}

/// Backing off must mean slower, never stuck.
void _stillFinishesUnderPressure() {
  test('never shrinks below a floor, so the import still finishes', () async {
      final sink = _FakeSink();
      final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 3);
      final pump = buildPump(
        sink,
        decoder,
        boundBytes: pipelineBytesPerSecond * 2,
        pressure: _FakePressure()..underPressure = true,
      );

      var isRunning = true;
      Future<void> drainLoop() async {
        while (isRunning) {
          sink.drain();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      final draining = drainLoop();
      final result = await pump.run(cancellation: ImportCancellation());
      isRunning = false;
      await draining;

      // Backing off must mean slower, never stuck.
      expect(result.outcome, PumpOutcome.completed);
      expect(decoder.served, decoder.totalBytes);
    });
  });
}

/// P-1 — the bound on audio awaiting transcription must actually hold.
void _audioInFlightStaysBounded() {
  group('P-1 audio in flight stays bounded', () {
    _stopsFeedingAtTheBound();
    _resumesOnceDrained();
    _reservesBudgetForARunningPass();
  });
}

/// The core of P-1: a full pipeline must stop the pump, not merely slow it.
void _stopsFeedingAtTheBound() {
  test('stops feeding once the bound is reached', () async {
      final sink = _FakeSink();
      // Ten seconds of audio against a one-second bound: without pacing the pump would
      // hand over all of it before anything was transcribed.
      final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 10);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond);
      final cancellation = ImportCancellation();

      final run = pump.run(cancellation: cancellation);
      // Let it fill, then stop it without ever draining.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final queuedWhileBlocked = sink.queuedBytes;
      cancellation.cancel();
      await run;

      expect(queuedWhileBlocked, lessThanOrEqualTo(pipelineBytesPerSecond + FileImportSource.frameSize));
      expect(decoder.served, lessThan(decoder.totalBytes));
    });

}

/// Bounded must not mean stuck: draining has to let the import continue.
void _resumesOnceDrained() {
  test('resumes as soon as the pipeline drains', () async {
      final sink = _FakeSink();
      final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 4);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond);

      // Drain continuously, as a working transcription pipeline would.
      var isRunning = true;
      Future<void> drainLoop() async {
        while (isRunning) {
          sink.drain();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      final draining = drainLoop();
      final result = await pump.run(cancellation: ImportCancellation());
      isRunning = false;
      await draining;

      expect(result.outcome, PumpOutcome.completed);
      expect(decoder.served, decoder.totalBytes);
    });

}

/// A running pass holds audio the buffer no longer reports; the bound must count it.
void _reservesBudgetForARunningPass() {
  test('reserves budget for a pass that is already running', () async {
      final sink = _FakeSink()..transcribing = true;
      final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 10);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond);
      final cancellation = ImportCancellation();

      final run = pump.run(cancellation: cancellation);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final queued = sink.queuedBytes;
      cancellation.cancel();
      await run;

      // Half the budget, because the running pass holds a chunk the buffer no longer
      // reports. Allowing the full budget would exceed the bound by one chunk in the
      // case that happens most of the time.
      expect(queued, lessThanOrEqualTo(pipelineBytesPerSecond ~/ 2 + FileImportSource.frameSize));
  });
}

/// P-3 — progress must track audio consumed, never elapsed time.
void _progressFollowsAudio() {
  group('P-3 progress follows audio, not the clock', () {
    test('reports seconds of audio fed, not seconds elapsed', () async {
      final sink = _FakeSink();
      final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 3);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond * 100);
      final reported = <double>[];

      final result = await pump.run(
        cancellation: ImportCancellation(),
        onSecondsFed: reported.add,
      );

      // Three seconds of audio, fed in well under three seconds of wall clock.
      expect(result.secondsFed, closeTo(3.0, 0.001));
      expect(reported.last, closeTo(3.0, 0.001));
      expect(reported, equals(List.of(reported)..sort()));
    });
  });

}

/// The final partial frame must survive; losing it clips the last word.
void _tailIsNotLost() {
  group('the tail is not lost', () {
    test('flushes a partial final frame', () async {
      final sink = _FakeSink();
      // Deliberately not a multiple of the frame size, so a tail is left over.
      final decoder = _FakeDecoder(totalBytes: FileImportSource.frameSize * 4 + 100, chunkSize: 500);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond * 100);

      await pump.run(cancellation: ImportCancellation());

      // Four whole frames plus one padded tail frame.
      expect(sink.received.length, 5);
      expect(sink.received.last.payload.length, FileImportSource.frameSize);
    });

    test('emits no tail frame when the recording ends on a boundary', () async {
      final sink = _FakeSink();
      final decoder = _FakeDecoder(totalBytes: FileImportSource.frameSize * 4, chunkSize: 320);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond * 100);

      await pump.run(cancellation: ImportCancellation());

      expect(sink.received.length, 4);
    });
  });

}

/// Cancelling must stop promptly and report honestly what was fed.
void _cancellationStopsPromptly() {
  group('cancellation', () {
    test('stops promptly and reports what was fed', () async {
      final sink = _FakeSink();
      final decoder = _FakeDecoder(totalBytes: pipelineBytesPerSecond * 100);
      final pump = buildPump(sink, decoder, boundBytes: pipelineBytesPerSecond * 1000);
      final cancellation = ImportCancellation()..cancel();

      final result = await pump.run(cancellation: cancellation);

      expect(result.outcome, PumpOutcome.cancelled);
      expect(result.secondsFed, 0);
      expect(decoder.readCallCount, 0);
    });
  });
}

void main() {
  _audioInFlightStaysBounded();
  _backsOffUnderMemoryPressure();
  _progressFollowsAudio();
  _tailIsNotLost();
  _cancellationStopsPromptly();
}
