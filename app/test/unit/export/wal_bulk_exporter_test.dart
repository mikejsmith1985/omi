/// Purpose: what bulk export must guarantee when one recording in a batch of many
/// goes wrong.
///
/// The reason this class exists at all is that a user with dozens of recordings
/// cannot babysit an export. So the behaviour that matters is not "it decodes a
/// file" — the single-recording share path already did that — it is that one bad
/// recording out of fifty-two never costs the user the other fifty-one, and that a
/// long run can be stopped and still reports honestly what it managed to save.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/export/wal_bulk_exporter.dart';
import 'package:omi/services/export/wal_wav_decoder.dart';
import 'package:omi/services/wals.dart';

/// A decoder that answers from fixed sets, so a test states the failure it wants
/// without touching a real audio file.
class _FakeWavDecoder implements WalWavDecoder {
  _FakeWavDecoder({
    this.audioMissingIds = const <String>{},
    this.decodeReturnsNullIds = const <String>{},
    this.decodeThrowsIds = const <String>{},
  });

  final Set<String> audioMissingIds;
  final Set<String> decodeReturnsNullIds;
  final Set<String> decodeThrowsIds;

  /// Every recording this decoder was actually asked to decode, in order.
  final List<String> decodeAttempts = <String>[];

  @override
  bool canDecode(Wal recording) => !audioMissingIds.contains(recording.id);

  @override
  Future<String?> decodeToWav(Wal recording) async {
    decodeAttempts.add(recording.id);
    if (decodeThrowsIds.contains(recording.id)) {
      throw StateError('decoder failed for ${recording.id}');
    }
    if (decodeReturnsNullIds.contains(recording.id)) {
      return null;
    }
    return '/export/${recording.id}.wav';
  }
}

/// Builds a recording whose only meaningful property here is its identity.
Wal _recording(String deviceName, {int timerStart = 1000}) {
  return Wal(timerStart: timerStart, codec: BleAudioCodec.opus, seconds: 10, device: deviceName);
}

void _exportsEveryUsableRecording() {
  group('exports every usable recording', () {
    test('a clean batch produces one WAV per recording', () async {
      final recordings = [_recording('one'), _recording('two'), _recording('three')];
      final exporter = WalBulkExporter(decoder: _FakeWavDecoder());

      final result = await exporter.exportRecordings(recordings);

      expect(result.exported, hasLength(3));
      expect(result.failures, isEmpty);
      expect(result.wasCancelled, isFalse);
      expect(result.exported.map((entry) => entry.wavFilePath), contains('/export/one_1000.wav'));
    });

    test('an empty batch is not an error', () async {
      final exporter = WalBulkExporter(decoder: _FakeWavDecoder());

      final result = await exporter.exportRecordings(const <Wal>[]);

      expect(result.exported, isEmpty);
      expect(result.failures, isEmpty);
      expect(result.hasAnyExport, isFalse);
    });
  });
}

void _skipsRecordingsWhoseAudioIsGone() {
  group('skips recordings whose audio is gone', () {
    test('the missing one is reported, the others still export', () async {
      final recordings = [_recording('good'), _recording('gone'), _recording('alsogood')];
      final decoder = _FakeWavDecoder(audioMissingIds: {'gone_1000'});
      final exporter = WalBulkExporter(decoder: decoder);

      final result = await exporter.exportRecordings(recordings);

      expect(result.exported, hasLength(2));
      expect(result.failures.single.recordingId, 'gone_1000');
      expect(result.failures.single.reason, ExportFailureReason.audioUnavailable);
      // The point: we never even asked the decoder for the one we knew was gone.
      expect(decoder.decodeAttempts, isNot(contains('gone_1000')));
    });
  });
}

void _survivesADecoderFailure() {
  group('survives a decoder failure', () {
    test('a decoder that returns nothing is a recorded failure, not a stopped run', () async {
      final recordings = [_recording('first'), _recording('empty'), _recording('last')];
      final exporter = WalBulkExporter(decoder: _FakeWavDecoder(decodeReturnsNullIds: {'empty_1000'}));

      final result = await exporter.exportRecordings(recordings);

      expect(result.exported, hasLength(2));
      expect(result.failures.single.reason, ExportFailureReason.decodeFailed);
    });

    test('a decoder that throws is caught and the batch continues', () async {
      final recordings = [_recording('before'), _recording('boom'), _recording('after')];
      final decoder = _FakeWavDecoder(decodeThrowsIds: {'boom_1000'});
      final exporter = WalBulkExporter(decoder: decoder);

      final result = await exporter.exportRecordings(recordings);

      expect(result.exported, hasLength(2));
      expect(result.failures.single.reason, ExportFailureReason.decodeThrew);
      expect(result.failures.single.details, contains('boom_1000'));
      // The recording after the throw must still have been attempted.
      expect(decoder.decodeAttempts, contains('after_1000'));
    });
  });
}

void _reportsProgressWhileItRuns() {
  group('reports progress while it runs', () {
    test('every recording reports once, counting up to the batch total', () async {
      final recordings = [_recording('one'), _recording('two'), _recording('three')];
      final exporter = WalBulkExporter(decoder: _FakeWavDecoder());
      final progressUpdates = <BulkExportProgress>[];

      await exporter.exportRecordings(recordings, onProgress: progressUpdates.add);

      expect(progressUpdates.map((update) => update.completedCount), [1, 2, 3]);
      expect(progressUpdates.every((update) => update.totalCount == 3), isTrue);
      expect(progressUpdates.last.fractionComplete, 1.0);
    });

    test('a failed recording still counts as progress, so the bar never stalls', () async {
      final recordings = [_recording('fine'), _recording('bad')];
      final exporter = WalBulkExporter(decoder: _FakeWavDecoder(decodeReturnsNullIds: {'bad_1000'}));
      final progressUpdates = <BulkExportProgress>[];

      await exporter.exportRecordings(recordings, onProgress: progressUpdates.add);

      expect(progressUpdates.map((update) => update.completedCount), [1, 2]);
    });

    test('an empty batch reports a complete fraction rather than dividing by zero', () {
      const progress = BulkExportProgress(completedCount: 0, totalCount: 0, lastRecordingId: '');

      expect(progress.fractionComplete, 1.0);
    });
  });
}

void _canBeStoppedPartWayThrough() {
  group('can be stopped part way through', () {
    test('cancelling stops further decoding and keeps what was already exported', () async {
      final recordings = [_recording('one'), _recording('two'), _recording('three')];
      final decoder = _FakeWavDecoder();
      final exporter = WalBulkExporter(decoder: decoder);

      final result = await exporter.exportRecordings(
        recordings,
        onProgress: (_) => exporter.cancel(),
      );

      expect(result.wasCancelled, isTrue);
      // Cancelled after the first finished, so the second must never be attempted.
      expect(decoder.decodeAttempts, ['one_1000']);
      expect(result.exported, hasLength(1));
      expect(result.hasAnyExport, isTrue);
    });

    test('a fresh run after a cancelled one is not still cancelled', () async {
      final decoder = _FakeWavDecoder();
      final exporter = WalBulkExporter(decoder: decoder);
      await exporter.exportRecordings([_recording('one'), _recording('two')], onProgress: (_) => exporter.cancel());

      final secondResult = await exporter.exportRecordings([_recording('three')]);

      expect(secondResult.wasCancelled, isFalse);
      expect(secondResult.exported, hasLength(1));
    });
  });
}

void main() {
  _exportsEveryUsableRecording();
  _skipsRecordingsWhoseAudioIsGone();
  _survivesADecoderFailure();
  _reportsProgressWhileItRuns();
  _canBeStoppedPartWayThrough();
}
