/// Purpose: export a whole shelf of recordings to WAV in one run, without letting a
/// single bad recording cost the user the rest of them.
///
/// The app could already share one recording at a time. That is fine for one and
/// unusable for fifty — and a user who has accumulated fifty is exactly the user who
/// most needs them off the phone. The rules that make an unattended run trustworthy
/// live here: keep going after a failure, say what failed and why, report progress so
/// the run is visibly alive, and stop cleanly when asked.
///
/// Drift justification (Article VII): `share_plus` already shares many files in one
/// call and is used unchanged for that. What no dependency in this project provides
/// is a decode-many-with-progress-and-partial-failure run, which is all this adds.
library;

import 'package:omi/services/export/wal_wav_decoder.dart';
import 'package:omi/services/wals.dart';

/// Why a single recording could not be exported.
enum ExportFailureReason {
  /// The recording's audio is no longer on the phone, so there was nothing to decode.
  audioUnavailable,

  /// The decoder ran but found no usable audio frames in the recording.
  decodeFailed,

  /// The decoder threw. Kept distinct from [decodeFailed] because a thrown error is
  /// a defect worth reporting, while an empty recording is merely disappointing.
  decodeThrew,
}

/// One recording successfully written out as a WAV file.
class ExportedRecording {
  /// Creates a record of a recording that was exported to [wavFilePath].
  const ExportedRecording({required this.recordingId, required this.wavFilePath});

  /// Identifies the recording this file came from.
  final String recordingId;

  /// Where the WAV file was written.
  final String wavFilePath;
}

/// One recording that could not be exported, and what went wrong.
class FailedExport {
  /// Creates a record of a recording that failed for [reason].
  const FailedExport({required this.recordingId, required this.reason, this.details});

  /// Identifies the recording that failed.
  final String recordingId;

  /// The category of failure, used to decide what to tell the user.
  final ExportFailureReason reason;

  /// The underlying error text, when there was one.
  final String? details;
}

/// How far along a running export is.
class BulkExportProgress {
  /// Creates a progress report for a run that has finished [completedCount] of
  /// [totalCount] recordings.
  const BulkExportProgress({
    required this.completedCount,
    required this.totalCount,
    required this.lastRecordingId,
  });

  /// How many recordings have been dealt with, whether they succeeded or failed.
  final int completedCount;

  /// How many recordings the run started with.
  final int totalCount;

  /// The recording that just finished, so the UI can name what it is working through.
  final String lastRecordingId;

  /// Progress as a fraction between 0 and 1, suitable for a progress bar.
  ///
  /// An empty run reads as complete rather than dividing by zero.
  double get fractionComplete {
    if (totalCount <= 0) return 1.0;
    return (completedCount / totalCount).clamp(0.0, 1.0);
  }
}

/// What a finished export run managed to produce.
class BulkExportResult {
  /// Creates the outcome of a finished run.
  const BulkExportResult({required this.exported, required this.failures, required this.wasCancelled});

  /// Every recording written out successfully.
  final List<ExportedRecording> exported;

  /// Every recording that could not be written out, with its reason.
  final List<FailedExport> failures;

  /// Whether the run stopped early because it was cancelled.
  final bool wasCancelled;

  /// Whether there is at least one file worth offering to the user.
  bool get hasAnyExport => exported.isNotEmpty;
}

/// Called after each recording finishes so a long run stays visibly alive.
typedef BulkExportProgressCallback = void Function(BulkExportProgress progress);

/// Exports many recordings to WAV in one unattended run.
class WalBulkExporter {
  /// Creates an exporter that decodes recordings with [decoder].
  WalBulkExporter({required WalWavDecoder decoder}) : _decoder = decoder;

  final WalWavDecoder _decoder;

  bool _isCancelled = false;

  /// Asks the current run to stop after the recording it is working on.
  ///
  /// Safe to call from a progress callback, which is how a cancel button reaches it.
  void cancel() {
    _isCancelled = true;
  }

  /// Exports every recording in [recordings], reporting each one to [onProgress].
  ///
  /// Never throws for a single bad recording: a failure is recorded and the run
  /// continues, because the user's remaining recordings are worth more than a tidy
  /// error. Returns what the run managed to produce, including a partial result when
  /// it was cancelled.
  Future<BulkExportResult> exportRecordings(
    List<Wal> recordings, {
    BulkExportProgressCallback? onProgress,
  }) async {
    // A new run must not inherit the previous run's cancellation.
    _isCancelled = false;

    final exported = <ExportedRecording>[];
    final failures = <FailedExport>[];
    var completedCount = 0;

    for (final recording in recordings) {
      if (_isCancelled) {
        return BulkExportResult(exported: exported, failures: failures, wasCancelled: true);
      }

      await _exportOneRecording(recording, exported, failures);

      completedCount++;
      onProgress?.call(
        BulkExportProgress(
          completedCount: completedCount,
          totalCount: recordings.length,
          lastRecordingId: recording.id,
        ),
      );
    }

    return BulkExportResult(exported: exported, failures: failures, wasCancelled: _isCancelled);
  }

  /// Exports one recording, adding it to [exported] or [failures].
  Future<void> _exportOneRecording(
    Wal recording,
    List<ExportedRecording> exported,
    List<FailedExport> failures,
  ) async {
    if (!_decoder.canDecode(recording)) {
      failures.add(FailedExport(recordingId: recording.id, reason: ExportFailureReason.audioUnavailable));
      return;
    }

    try {
      final wavFilePath = await _decoder.decodeToWav(recording);
      if (wavFilePath == null) {
        failures.add(FailedExport(recordingId: recording.id, reason: ExportFailureReason.decodeFailed));
        return;
      }
      exported.add(ExportedRecording(recordingId: recording.id, wavFilePath: wavFilePath));
    } catch (error) {
      failures.add(
        FailedExport(
          recordingId: recording.id,
          reason: ExportFailureReason.decodeThrew,
          details: '${recording.id}: $error',
        ),
      );
    }
  }
}
