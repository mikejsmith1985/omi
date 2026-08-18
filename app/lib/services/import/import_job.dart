/// Purpose: the state of one recording on its way to becoming a conversation.
///
/// Two things in here carry the feature's correctness rather than merely describing
/// it. [ImportStage] is an enum rather than a pair of booleans because an interrupted
/// import must be distinguishable from a finished one — that is data-model Invariant 1,
/// and it is why [ImportJob.conversationId] is only ever set at [ImportStage.completed].
/// And [ImportRequest.contentHash] is the identity, not the file path, because a path
/// changes every time a file is copied (Invariant 2).
library;

import 'package:omi/services/import/recording_time.dart';

/// Where a job has got to.
///
/// Ordered as the work happens. Everything from [completed] onwards is terminal, and
/// a terminal stage always deletes the decoded scratch audio (Invariant 3).
enum ImportStage {
  /// Accepted and waiting for its turn. Nothing has been decoded yet.
  queued,

  /// Being turned into the PCM the transcription pipeline expects.
  decoding,

  /// Being fed through the on-device engine.
  transcribing,

  /// The audio is done; the conversation is being closed out.
  creatingConversation,

  /// Finished. The only stage that carries a conversation.
  completed,

  /// Stopped by a failure. Carries an [ImportFailure] saying what to do.
  failed,

  /// Stopped by the user.
  cancelled;

  /// Whether no further work will happen on this job.
  bool get isTerminal => this == completed || this == failed || this == cancelled;

  /// Whether the job was still working when we last saw it.
  ///
  /// A job in this state at app start was interrupted — the process died mid-import.
  /// It is moved to [failed] and restarted from scratch rather than resumed, because
  /// resuming is how a half-built conversation reaches a user (FR-019).
  bool get wasInterruptedIfFoundAtStartup => !isTerminal;
}

/// A failure a person can act on.
///
/// FR-018: a code alone is not a message. [whatHappened] and [whatToDo] are both
/// required so there is no way to construct a failure that leaves a user stuck.
///
/// It is an [Exception] so the decode and pump layers can throw it directly. Anything
/// that reaches the user as a failure is therefore already in a form they can read —
/// there is no separate "and now translate the technical error" step to forget.
class ImportFailure implements Exception {
  /// What went wrong, in the user's terms.
  final String whatHappened;

  /// The action they can take about it.
  final String whatToDo;

  /// A stable identifier for logs and bug reports. Never shown on its own.
  final String code;

  /// Whether trying again could plausibly succeed.
  ///
  /// A damaged file is not retryable; an import aborted under memory pressure is.
  /// Getting this wrong wastes either the user's time or their battery.
  final bool isRetryable;

  /// Creates a failure that says what happened and what to do about it.
  const ImportFailure({
    required this.whatHappened,
    required this.whatToDo,
    required this.code,
    this.isRetryable = false,
  });

  @override
  String toString() => '$code: $whatHappened';
}

/// One file the user chose, and what we established about it before doing any work.
///
/// Everything here is determined up front so a rejection is immediate rather than
/// discovered after a long wait (FR-003).
class ImportRequest {
  /// Where the picker returned the file from.
  ///
  /// Never the identity: a content URI can expire, and the same recording can arrive
  /// by several routes.
  final String sourceUri;

  /// What to call this recording in the interface.
  final String displayName;

  /// Hash of the file's bytes — the identity (Invariant 2).
  final String contentHash;

  /// Size of the source file.
  final int sizeBytes;

  /// The container the bytes actually are, not what the extension claims.
  final String detectedFormat;

  /// How long the recording runs. Drives the estimate and the progress figure.
  final double durationSeconds;

  /// When the recording was made, once established.
  final DateTime? recordingTime;

  /// How [recordingTime] was arrived at.
  final RecordingTimeSource recordingTimeSource;

  /// Creates a request for a file that has already been probed.
  const ImportRequest({
    required this.sourceUri,
    required this.displayName,
    required this.contentHash,
    required this.sizeBytes,
    required this.detectedFormat,
    required this.durationSeconds,
    required this.recordingTimeSource,
    this.recordingTime,
    this.needsTimeConfirmation = false,
  });

  /// Builds a request carrying an already-resolved recording time.
  ///
  /// A factory rather than three separate assignments so the time, its source and
  /// whether it needs confirming cannot drift out of step with one another.
  factory ImportRequest.withResolvedTime({
    required String sourceUri,
    required String displayName,
    required String contentHash,
    required int sizeBytes,
    required String detectedFormat,
    required double durationSeconds,
    required ResolvedRecordingTime resolvedTime,
  }) {
    return ImportRequest(
      sourceUri: sourceUri,
      displayName: displayName,
      contentHash: contentHash,
      sizeBytes: sizeBytes,
      detectedFormat: detectedFormat,
      durationSeconds: durationSeconds,
      recordingTime: resolvedTime.value,
      recordingTimeSource: resolvedTime.source,
      needsTimeConfirmation: resolvedTime.needsConfirmation,
    );
  }

  /// Whether the recording time is too weakly sourced to use without asking.
  ///
  /// Carried from the resolver rather than derived from [recordingTimeSource], because
  /// for a filesystem timestamp the answer depends on how recent it is — see
  /// [isSuspectFilesystemTime].
  final bool needsTimeConfirmation;
}

/// The work of turning one [ImportRequest] into a conversation.
class ImportJob {
  /// Identifies this job.
  final String id;

  /// The file this job is importing.
  final ImportRequest request;

  /// Where the job has got to.
  ImportStage stage;

  /// How much audio has been decoded so far.
  double secondsDecoded;

  /// How much audio has come back transcribed.
  ///
  /// Trails [secondsDecoded] by the pump's in-flight bound, which is what keeps peak
  /// memory flat with respect to recording length (contract P-1).
  double secondsTranscribed;

  /// When the import started.
  final DateTime startedAt;

  /// When it reached a terminal stage.
  DateTime? endedAt;

  /// The conversation this produced.
  ///
  /// Set only at [ImportStage.completed] — see [complete], which is the only way to
  /// set it. That restriction is Invariant 1 expressed in code rather than in prose.
  String? conversationId;

  /// Why the job failed, when it did.
  ImportFailure? failure;

  /// The decoded audio on disk, deleted on any terminal stage (Invariant 3).
  String? scratchPath;

  /// Creates a job in [ImportStage.queued].
  ImportJob({
    required this.id,
    required this.request,
    required this.startedAt,
    this.stage = ImportStage.queued,
    this.secondsDecoded = 0,
    this.secondsTranscribed = 0,
  });

  /// How far through the recording the transcription has got, from 0 to 1.
  ///
  /// Measured against transcribed audio rather than decoded audio, because decoding
  /// runs ahead and reporting its position would show progress the user cannot yet see.
  double get progress {
    if (request.durationSeconds <= 0) return 0;
    return (secondsTranscribed / request.durationSeconds).clamp(0.0, 1.0);
  }

  /// Moves the job to [ImportStage.completed] with the conversation it produced.
  ///
  /// The only route to a non-null [conversationId]. Every other transition leaves it
  /// null, so a partial import cannot present itself as a finished one (Invariant 1).
  void complete({required String conversationId, required DateTime at}) {
    this.conversationId = conversationId;
    stage = ImportStage.completed;
    endedAt = at;
    scratchPath = null;
  }

  /// Moves the job to [ImportStage.failed].
  void fail(ImportFailure cause, {required DateTime at}) {
    failure = cause;
    stage = ImportStage.failed;
    endedAt = at;
    scratchPath = null;
  }

  /// Moves the job to [ImportStage.cancelled] at the user's request.
  void cancel({required DateTime at}) {
    stage = ImportStage.cancelled;
    endedAt = at;
    scratchPath = null;
  }
}
