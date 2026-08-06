/// Purpose: run one recording all the way from a chosen file to an Omi conversation.
///
/// This is the part that ties the feature together, and almost all of what it does is
/// decide *not* to do something. Transcription is Omi's. Conversation creation is Omi's.
/// Titles, summaries and action items are Omi's. What is left here is the ordering, the
/// guards, and knowing when to stop.
///
/// The order matters more than it looks:
///
///   1. Refuse early — a duplicate, a live recording in progress, an undecodable file.
///      Every one of these is cheaper to detect than to discover (FR-003).
///   2. Feed the audio through the paced pump.
///   3. Only once the whole recording has been transcribed, close the session into a
///      conversation. Never before, because a conversation that exists before the audio
///      is finished is the half-built conversation FR-019 forbids.
library;

import 'dart:async';

import 'package:omi/services/audio/native_decoder.dart';
import 'package:omi/services/audio_sources/file_import_source.dart';
import 'package:omi/services/import/import_failures.dart';
import 'package:omi/services/import/import_job.dart';
import 'package:omi/services/import/import_pump.dart';
import 'package:omi/services/import/import_registry.dart';
import 'package:omi/services/import/scratch_storage.dart';

/// The capture machinery an import needs, expressed as what it needs rather than as
/// the class that happens to provide it.
///
/// An interface so the session's ordering and guards can be tested without a device,
/// a socket or a transcription engine. Those are exactly the parts that cannot be
/// tested any other way, and exactly the parts where a mistake produces a half-built
/// conversation rather than an obvious error.
abstract class ImportCaptureHost {
  /// Whether Omi is recording right now.
  ///
  /// Live capture always wins: a background job must never degrade the conversation
  /// the user is actually having (FR-021).
  bool get isLiveCaptureActive;

  /// Opens a capture session fed by [source], using the on-device transcription path.
  ///
  /// Returns the sink the pump feeds, or throws if the pipeline cannot be started.
  Future<ImportAudioSink> beginImportCapture(FileImportSource source);

  /// How many transcript segments the session has produced so far.
  ///
  /// Read to tell a recording with no speech in it from one that transcribed fine
  /// (FR-011), and to refuse to close a session that produced nothing.
  int get segmentCount;

  /// Closes the session into a conversation, returning its id once Omi has made it.
  ///
  /// Returns null when Omi did not create one — which happens legitimately when the
  /// session held nothing worth keeping.
  Future<String?> finishImportCapture();

  /// Abandons the session without creating a conversation.
  Future<void> abandonImportCapture();
}

/// What one import produced.
class ImportOutcome {
  /// Where the job ended up.
  final ImportStage stage;

  /// The conversation, when one was created.
  final String? conversationId;

  /// Why it failed, when it did.
  final ImportFailure? failure;

  /// Creates an outcome.
  const ImportOutcome({required this.stage, this.conversationId, this.failure});
}

/// Runs one recording through to a conversation.
class ImportSession {
  /// Decodes the recording.
  final NativeAudioDecoder decoder;

  /// Supplies the capture pipeline.
  final ImportCaptureHost host;

  /// Remembers what has already been imported.
  final ImportRegistry registry;

  /// Holds the decoded audio while the import runs.
  final ScratchStorage scratch;

  /// Creates a session runner.
  ImportSession({
    required this.decoder,
    required this.host,
    required this.registry,
    required this.scratch,
  });

  /// Imports one recording.
  ///
  /// Reports progress as seconds of audio transcribed, never as elapsed time — the
  /// import runs faster than real time by a factor that varies with the device.
  Future<ImportOutcome> run(
    ImportJob job, {
    required ImportCancellation cancellation,
    void Function(ImportJob job)? onProgress,
  }) async {
    final refusal = await _refuseEarly(job);
    if (refusal != null) return _fail(job, refusal);

    DecodeSession? session;
    try {
      session = await decoder.openSession(job.request.sourceUri);
      return await _transcribeAndClose(job, session, cancellation, onProgress);
    } on ImportFailure catch (failure) {
      await host.abandonImportCapture();
      return _fail(job, failure);
    } finally {
      await session?.close();
      await scratch.deleteScratchFile(job.scratchPath);
    }
  }

  /// The reasons to refuse before doing any work at all.
  Future<ImportFailure?> _refuseEarly(ImportJob job) async {
    if (host.isLiveCaptureActive) return liveRecordingInProgress();

    final alreadyImported = await registry.findByContentHash(job.request.contentHash);
    if (alreadyImported != null) return alreadyImportedRecording(alreadyImported.displayName);

    if (job.request.durationSeconds <= 0) return emptyRecording();
    return null;
  }

  /// Feeds the recording through, then closes the session into a conversation.
  Future<ImportOutcome> _transcribeAndClose(
    ImportJob job,
    DecodeSession session,
    ImportCancellation cancellation,
    void Function(ImportJob job)? onProgress,
  ) async {
    final source = FileImportSource(importId: job.id);
    final sink = await host.beginImportCapture(source);

    job.stage = ImportStage.transcribing;
    final result = await _runPump(job, source, session, sink, cancellation, onProgress);

    if (result.outcome == PumpOutcome.cancelled) {
      await host.abandonImportCapture();
      job.cancel(at: DateTime.now());
      return const ImportOutcome(stage: ImportStage.cancelled);
    }
    return _closeIntoConversation(job);
  }

  /// Runs the pump, keeping the job's progress in step with it.
  Future<PumpResult> _runPump(
    ImportJob job,
    FileImportSource source,
    DecodeSession session,
    ImportAudioSink sink,
    ImportCancellation cancellation,
    void Function(ImportJob job)? onProgress,
  ) {
    final pump = ImportPump(source: source, decoder: session, sink: sink);
    return pump.run(
      cancellation: cancellation,
      onSecondsFed: (seconds) {
        job.secondsDecoded = seconds;
        job.secondsTranscribed = seconds;
        onProgress?.call(job);
      },
    );
  }

  /// Turns a finished transcription into a conversation, or explains why it did not.
  ///
  /// The two failure cases here look similar and are not. A session with no segments
  /// means the recording held no speech, which is the user's answer (FR-011). A session
  /// with segments that Omi declined to turn into a conversation is our problem, and
  /// must not be reported as though the recording were at fault.
  Future<ImportOutcome> _closeIntoConversation(ImportJob job) async {
    if (host.segmentCount == 0) {
      await host.abandonImportCapture();
      return _fail(job, noSpeechFound());
    }

    job.stage = ImportStage.creatingConversation;
    final conversationId = await host.finishImportCapture();
    if (conversationId == null) {
      return _fail(job, importInterrupted(job.request.displayName));
    }

    job.complete(conversationId: conversationId, at: DateTime.now());
    await registry.recordCompleted(ImportedRecording(
      contentHash: job.request.contentHash,
      conversationId: conversationId,
      displayName: job.request.displayName,
      importedAt: job.endedAt ?? DateTime.now(),
      // Kept even though the conversation cannot carry it (research.md Part 4). Losing
      // it here would mean re-deriving it from a file the user may have since deleted.
      recordingTime: job.request.recordingTime,
    ));
    return ImportOutcome(stage: ImportStage.completed, conversationId: conversationId);
  }

  /// Records a failure on the job and returns it as the outcome.
  ImportOutcome _fail(ImportJob job, ImportFailure failure) {
    job.fail(failure, at: DateTime.now());
    return ImportOutcome(stage: ImportStage.failed, failure: failure);
  }
}
