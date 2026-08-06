/// Purpose: own the running import, so it survives the screen that started it.
///
/// FR-017. This exists because of where an import lives in a person's day: they pick a
/// recording, see it start, and then go and do something else. If the work were owned
/// by the screen, leaving it would cancel an hour of transcription silently — the exact
/// behaviour that makes a feature feel broken rather than slow.
///
/// So the import belongs to a controller that outlives any screen, and screens observe
/// it. Cancelling is then something the user does deliberately, never a side effect of
/// navigating away.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:omi/services/import/import_failures.dart';
import 'package:omi/services/import/import_job.dart';
import 'package:omi/services/import/import_progress.dart';
import 'package:omi/services/import/import_pump.dart';
import 'package:omi/services/import/import_session.dart';

/// Owns the running import and reports its progress.
///
/// A [ChangeNotifier] because that is how the rest of the app publishes state; screens
/// listen and rebuild, and none of them owns the work.
class ImportController extends ChangeNotifier with WidgetsBindingObserver implements MemoryPressureSignal {
  /// Runs one recording through to a conversation.
  final ImportSession session;

  /// Called when an import finishes, so the user can be told (FR-017).
  final void Function(ImportJob job, ImportOutcome outcome)? onFinished;

  ImportJob? _activeJob;
  ImportProgress? _progress;
  ImportProgressEstimator? _estimator;
  ImportCancellation? _cancellation;
  Stopwatch? _elapsed;
  DateTime? _lastPressureAt;

  /// Creates a controller.
  ImportController({required this.session, this.onFinished}) {
    WidgetsBinding.instance.addObserver(this);
  }

  /// The import currently running, if any.
  ImportJob? get activeJob => _activeJob;

  /// How far along the running import is.
  ImportProgress? get progress => _progress;

  /// Whether an import is running right now.
  bool get isImporting => _activeJob != null;

  /// How long the system's request for memory is respected for.
  ///
  /// The platform signals pressure as an event, not a state, so it has to be held for a
  /// while to be useful. Long enough to cover the burst that usually follows, short
  /// enough that one transient event does not slow the rest of an hour-long import.
  static const Duration memoryPressureHoldTime = Duration(seconds: 30);

  @override
  bool get isUnderPressure {
    final since = _lastPressureAt;
    if (since == null) return false;
    return DateTime.now().difference(since) < memoryPressureHoldTime;
  }

  @override
  void didHaveMemoryPressure() {
    // The pump reads this and shrinks how much audio it keeps in flight, so the import
    // slows down and finishes rather than being killed part-way.
    _lastPressureAt = DateTime.now();
    super.didHaveMemoryPressure();
  }

  /// Starts importing [job], unless one is already running.
  ///
  /// Returns false when an import is already in progress. Refusing is deliberate: two
  /// concurrent imports would contend for the single transcription pipeline and produce
  /// two interleaved, useless conversations.
  Future<bool> start(ImportJob job) async {
    if (_activeJob != null) return false;

    _beginTracking(job);
    unawaited(_runToCompletion(job));
    return true;
  }

  /// Stops the running import at the next opportunity.
  ///
  /// The import stops without creating a conversation, which is what distinguishes
  /// cancelling from finishing early (FR-020).
  void cancel() => _cancellation?.cancel();

  /// Sets up progress tracking for a new import.
  void _beginTracking(ImportJob job) {
    _activeJob = job;
    _cancellation = ImportCancellation();
    _elapsed = Stopwatch()..start();
    _estimator = ImportProgressEstimator(
      recordingLength: Duration(milliseconds: (job.request.durationSeconds * 1000).round()),
    );
    _progress = null;
    notifyListeners();
  }

  /// Runs the import and publishes its result.
  Future<void> _runToCompletion(ImportJob job) async {
    ImportOutcome outcome;
    try {
      outcome = await session.run(job, cancellation: _cancellation!, onProgress: _publishProgress);
    } on Object catch (error) {
      // Nothing may escape and leave the controller believing an import is still
      // running — that would block every future import until the app restarts.
      outcome = ImportOutcome(stage: ImportStage.failed, failure: _describeUnexpected(error, job));
    }
    _finish(job, outcome);
  }

  /// Updates the published progress from the job's position.
  void _publishProgress(ImportJob job) {
    final estimator = _estimator;
    final elapsed = _elapsed;
    if (estimator == null || elapsed == null) return;

    _progress = estimator.update(
      secondsTranscribed: job.secondsTranscribed,
      elapsed: elapsed.elapsed,
    );
    notifyListeners();
  }

  /// Clears the running import and announces how it ended.
  void _finish(ImportJob job, ImportOutcome outcome) {
    _elapsed?.stop();
    _activeJob = null;
    _cancellation = null;
    _estimator = null;
    _progress = null;
    notifyListeners();
    onFinished?.call(job, outcome);
  }

  /// Turns an unexpected error into something a person can act on.
  ImportFailure _describeUnexpected(Object error, ImportJob job) {
    if (error is ImportFailure) return error;
    if (error is OutOfMemoryError) return ranOutOfMemory();
    return importInterrupted(job.request.displayName);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
