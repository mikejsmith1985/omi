/// Purpose: let someone choose a recording and start importing it.
///
/// The screen's real job is refusing well. Anyone can show a file picker; what decides
/// whether this feature is usable is what happens when the chosen file is a video, a
/// renamed `.m4a`, an empty file, or one already imported. FR-003 requires those to be
/// caught *before* any work starts, because a refusal after a long wait is the failure
/// this whole feature is trying to avoid.
///
/// **Strings are English here and move to ARB at T061a.** Omi requires every
/// user-facing string to reach the interface through `context.l10n`, across 49 locales,
/// with `flutter gen-l10n` reporting zero untranslated messages. That move is mechanical
/// because every message already comes from `import_failures.dart` with a stable code.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:omi/services/import/content_identity.dart';
import 'package:omi/services/import/format_detection.dart';
import 'package:omi/services/import/import_failures.dart';
import 'package:omi/services/import/import_job.dart';
import 'package:omi/services/import/import_registry.dart';
import 'package:omi/services/import/recording_time.dart';

/// Lets the user pick recordings and hands back requests ready to import.
class ImportPickerPage extends StatefulWidget {
  /// Called with the requests that passed every up-front check.
  ///
  /// Takes a list because a backlog is the realistic way this feature gets used — at
  /// twenty hours of audio a week, selecting one file at a time is not a workflow
  /// anyone would tolerate (FR-005).
  final Future<void> Function(List<ImportRequest> requests) onRequestsReady;

  /// Knows what has already been imported.
  final ImportRegistry registry;

  /// Creates the picker.
  const ImportPickerPage({super.key, required this.onRequestsReady, required this.registry});

  @override
  State<ImportPickerPage> createState() => _ImportPickerPageState();
}

class _ImportPickerPageState extends State<ImportPickerPage> {
  ImportFailure? _refusal;
  bool _isChecking = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import a recording')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Choose an audio file and Omi will transcribe it on this phone, '
              'exactly as it transcribes what it records itself. Nothing is sent '
              'anywhere to be transcribed, and there is no limit on how much you import.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _isChecking ? null : _chooseFile,
              child: Text(_isChecking ? 'Checking…' : 'Choose a recording'),
            ),
            const SizedBox(height: 24),
            if (_refusal != null) _RefusalNotice(failure: _refusal!),
          ],
        ),
      ),
    );
  }

  /// Opens the picker and runs every up-front check on what comes back.
  Future<void> _chooseFile() async {
    setState(() {
      _isChecking = true;
      _refusal = null;
    });

    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
      final paths = picked?.files.map((file) => file.path).whereType<String>().toList() ?? [];
      if (paths.isEmpty) return;
      await _acceptOrRefuse(paths.map(File.new).toList());
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  /// Checks each file, queuing what passes and reporting what did not.
  ///
  /// One bad file among ten must not throw away the other nine — the whole point of
  /// selecting a backlog is not having to nurse it. So refusals are collected and
  /// summarised, and everything acceptable goes to the queue.
  Future<void> _acceptOrRefuse(List<File> files) async {
    final accepted = <ImportRequest>[];
    final refusals = <ImportFailure>[];

    for (final file in files) {
      final refusal = await _checkFile(file);
      if (refusal != null) {
        refusals.add(refusal);
        continue;
      }
      accepted.add(await _buildRequest(file));
    }

    if (mounted) setState(() => _refusal = _summarise(refusals, accepted.length));
    if (accepted.isNotEmpty) await widget.onRequestsReady(accepted);
  }

  /// Reduces a set of refusals to the one message worth showing.
  ///
  /// A list of ten near-identical complaints is not more informative than one that says
  /// how many were skipped and why the first was.
  ImportFailure? _summarise(List<ImportFailure> refusals, int acceptedCount) {
    if (refusals.isEmpty) return null;
    if (refusals.length == 1) return refusals.single;

    return ImportFailure(
      whatHappened: '${refusals.length} of the recordings you chose could not be imported.',
      whatToDo: acceptedCount > 0
          ? 'The other $acceptedCount are importing. The first problem was: ${refusals.first.whatToDo}'
          : refusals.first.whatToDo,
      code: 'multiple_refusals',
    );
  }

  /// Every reason to refuse, in the order that costs least to discover.
  Future<ImportFailure?> _checkFile(File file) async {
    final detection = await detectAudioFormat(file);
    if (detection.isRecognisedButUnsupportedHere) {
      return formatNotSupportedOnThisDevice(detection.container!);
    }
    if (!detection.isSupported) {
      return undecodableRecording(detection.unrecognisedDescription, null);
    }

    final existing = await widget.registry.findByContentHash(await hashRecordingFile(file));
    if (existing != null) return alreadyImportedRecording(existing.displayName);
    return null;
  }

  /// Builds the request for a file that has passed every check.
  ///
  /// Duration is left to the decoder's probe, which is the only thing that actually
  /// knows it. Guessing from the file size would be wrong for every compressed format,
  /// and the estimate shown to the user is built from this.
  Future<ImportRequest> _buildRequest(File file) async {
    final name = file.uri.pathSegments.last;
    final detection = await detectAudioFormat(file);
    final fromName = parseRecordingTimeFromFilename(name);

    return ImportRequest(
      sourceUri: file.path,
      displayName: name,
      contentHash: await hashRecordingFile(file),
      sizeBytes: await file.length(),
      detectedFormat: detection.container!.displayName,
      durationSeconds: 0,
      recordingTime: fromName,
      recordingTimeSource: fromName != null ? RecordingTimeSource.filename : RecordingTimeSource.unknown,
    );
  }
}

/// Shows a refusal as what happened and what to do, never as a code.
class _RefusalNotice extends StatelessWidget {
  /// The refusal to explain.
  final ImportFailure failure;

  const _RefusalNotice({required this.failure});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(failure.whatHappened, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(failure.whatToDo, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
