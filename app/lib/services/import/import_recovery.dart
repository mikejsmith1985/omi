/// Purpose: clean up after an import the app did not survive.
///
/// FR-019 and SC-007. The crash that matters is not the one during decoding — that
/// leaves a scratch file and nothing else. It is the one during conversation creation,
/// because that is the moment when a partial result could plausibly be mistaken for a
/// finished one. It is also the case nobody tests, which is why it gets its own file.
///
/// The rule is deliberately blunt: **a job found unfinished is failed, never resumed.**
/// Resuming looks attractive and is wrong here. The state that would have to be trusted
/// — how much audio reached the engine, what the server session contains, whether a
/// conversation was half-created — is exactly the state a crash makes unreliable. The
/// cost of starting over is transcribing the recording again, on hardware that does it
/// for free. The cost of resuming wrongly is a conversation with a hole in it that the
/// user has no way to detect.
///
/// This is a departure from the earlier desktop design, where transcription was
/// expensive enough that resuming by stage was worth its complexity. On-device it is
/// not, so correctness wins outright (Article I).
library;

import 'package:omi/services/import/import_failures.dart';
import 'package:omi/services/import/import_job.dart';
import 'package:omi/services/import/scratch_storage.dart';

/// What a recovery sweep found and did.
class RecoveryReport {
  /// Jobs that were still in flight and have been failed.
  final List<ImportJob> interrupted;

  /// Bytes of decoded audio reclaimed from previous runs.
  final int reclaimedBytes;

  /// Creates a report.
  const RecoveryReport({required this.interrupted, required this.reclaimedBytes});

  /// Whether anything needed cleaning up.
  bool get hasFindings => interrupted.isNotEmpty || reclaimedBytes > 0;
}

/// Cleans up imports left unfinished by a previous run.
class ImportRecovery {
  /// Holds the decoded audio that needs reclaiming.
  final ScratchStorage scratch;

  /// Creates a recovery sweep.
  const ImportRecovery({required this.scratch});

  /// Fails every unfinished job and reclaims abandoned scratch.
  ///
  /// Call once at startup, before any import begins. [jobs] is whatever was persisted;
  /// jobs already in a terminal state are left exactly as they are, because a completed
  /// import must not be disturbed by a crash that happened afterwards.
  Future<RecoveryReport> sweep(List<ImportJob> jobs, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final interrupted = <ImportJob>[];

    for (final job in jobs) {
      if (job.stage.isTerminal) continue;
      job.fail(importInterrupted(job.request.displayName), at: at);
      interrupted.add(job);
    }

    final reclaimedBytes = await scratch.purgeAbandonedScratchFiles();
    return RecoveryReport(interrupted: interrupted, reclaimedBytes: reclaimedBytes);
  }
}
