/// Purpose: work through a backlog of recordings without needing to be watched.
///
/// User Story 4. At twenty hours of audio a week the realistic way to use this feature
/// is to select everything and walk away, so the queue's job is to be unattended-safe:
/// one recording at a time, a failure contained to the recording that caused it, and a
/// pause rather than a flat phone when conditions turn against it.
///
/// **Strictly sequential.** Two imports at once would contend for the single
/// transcription pipeline and produce two interleaved, useless conversations. There is
/// no throughput to win by trying — the device transcribes at the rate it transcribes,
/// and running two at once only splits it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omi/services/import/import_conditions.dart';
import 'package:omi/services/import/import_failures.dart' show duplicateRecordingCode;
import 'package:omi/services/import/import_job.dart';
import 'package:omi/services/import/import_pump.dart';
import 'package:omi/services/import/import_registry.dart';
import 'package:omi/services/import/import_session.dart';

/// Reads the phone's power and thermal state.
///
/// An interface so the queue's behaviour under low battery and heat is testable without
/// needing an actually hot, actually flat phone.
abstract class DeviceStateReader {
  /// The device's current state.
  Future<DeviceState> read();
}

/// One recording's place in the queue.
class QueueEntry {
  /// The work to do.
  final ImportJob job;

  /// How it ended, once it has.
  ImportOutcome? outcome;

  /// Creates an entry.
  QueueEntry(this.job);

  /// Whether this entry is finished, however it finished.
  bool get isDone => outcome != null;

  /// Whether this was skipped because the recording was already imported.
  ///
  /// Not a failure, and must not be shown as one — the user already has the
  /// conversation, they simply selected the file twice.
  bool get wasSkippedAsDuplicate => outcome?.failure?.code == duplicateRecordingCode;
}

/// Works through a backlog of recordings, one at a time.
class ImportQueue extends ChangeNotifier {
  /// Runs a single recording through to a conversation.
  final ImportSession session;

  /// Knows what has already been imported.
  final ImportRegistry registry;

  /// Reports the phone's power and thermal state.
  final DeviceStateReader deviceState;

  /// Decides when it is reasonable to keep going.
  final ImportConditionsPolicy conditions;

  /// How long to wait before re-checking a device that asked the queue to pause.
  final Duration pauseRecheckInterval;

  final List<QueueEntry> _entries = [];
  QueueDisposition _disposition = QueueDisposition.proceed;
  ImportCancellation? _current;
  bool _isRunning = false;
  bool _isStopRequested = false;

  /// Creates a queue.
  ImportQueue({
    required this.session,
    required this.registry,
    required this.deviceState,
    ImportConditionsPolicy? conditions,
    this.pauseRecheckInterval = const Duration(minutes: 1),
  }) : conditions = conditions ?? ImportConditionsPolicy();

  /// Every recording in the queue, in the order they will run.
  List<QueueEntry> get entries => List.unmodifiable(_entries);

  /// Why the queue is waiting, or that it is not.
  QueueDisposition get disposition => _disposition;

  /// Whether the queue is working through recordings.
  bool get isRunning => _isRunning;

  /// The recording being imported right now, if any.
  ImportJob? get currentJob => _nextPending()?.job;

  /// How many recordings are still to run.
  int get remainingCount => _entries.where((entry) => !entry.isDone).length;

  /// How many finished with a conversation.
  int get completedCount => _entries.where((entry) => entry.outcome?.conversationId != null).length;

  /// How many were skipped because they had already been imported.
  ///
  /// Counted separately from failures because it is not one: the user has the
  /// conversation already, and showing it as an error would send them looking for a
  /// problem that does not exist (FR-004).
  int get skippedCount => _entries.where((entry) => entry.wasSkippedAsDuplicate).length;

  /// How many genuinely failed.
  int get failedCount =>
      _entries.where((entry) => entry.outcome?.stage == ImportStage.failed && !entry.wasSkippedAsDuplicate).length;

  /// The first entry that has not run yet.
  QueueEntry? _nextPending() {
    for (final entry in _entries) {
      if (!entry.isDone) return entry;
    }
    return null;
  }

  /// Adds recordings to the back of the queue and starts working if idle.
  Future<void> enqueue(List<ImportJob> jobs) async {
    _entries.addAll(jobs.map(QueueEntry.new));
    notifyListeners();
    if (!_isRunning) unawaited(_drain());
  }

  /// Stops after the recording in progress, leaving the rest queued.
  void stop() {
    _isStopRequested = true;
    _current?.cancel();
  }

  /// Works through the queue until it is empty or told to stop.
  Future<void> _drain() async {
    _isRunning = true;
    _isStopRequested = false;
    notifyListeners();

    try {
      while (!_isStopRequested) {
        final next = _nextPending();
        if (next == null) break;
        if (!await _waitForAcceptableConditions()) break;
        await _runEntry(next);
      }
    } finally {
      _isRunning = false;
      _current = null;
      notifyListeners();
    }
  }

  /// Waits until the device is in a fit state, or until the queue is told to stop.
  ///
  /// Returns false when it should give up rather than keep waiting.
  Future<bool> _waitForAcceptableConditions() async {
    while (!_isStopRequested) {
      _disposition = conditions.evaluate(await deviceState.read());
      notifyListeners();
      if (!_disposition.isPaused) return true;
      await Future<void>.delayed(pauseRecheckInterval);
    }
    return false;
  }

  /// Runs one entry, keeping its failure to itself.
  ///
  /// A recording that cannot be imported must not stop the ones behind it — that is the
  /// difference between a queue that survives a backlog and one that stalls on the
  /// first damaged file and is found the next morning having done nothing.
  Future<void> _runEntry(QueueEntry entry) async {
    _current = ImportCancellation();
    notifyListeners();

    try {
      entry.outcome = await session.run(entry.job, cancellation: _current!, onProgress: _onProgress);
    } on Object {
      // session.run already turns known failures into outcomes; anything reaching here
      // is unexpected, and the queue's response to unexpected is the same as to
      // expected — record it against this recording and move on.
      entry.outcome = ImportOutcome(stage: ImportStage.failed, failure: entry.job.failure);
    } finally {
      notifyListeners();
    }
  }

  /// Republishes progress as the running import advances.
  void _onProgress(ImportJob job) => notifyListeners();
}
