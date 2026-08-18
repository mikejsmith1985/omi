/// Purpose: show a backlog working through itself, so leaving it alone feels safe.
///
/// The screen answers three questions and nothing else: what is happening now, what is
/// still to come, and — if nothing is happening — why not. That last one carries most
/// of the weight. A queue that has quietly paused for heat looks exactly like a queue
/// that has crashed, and the difference decides whether the user waits or force-quits.
///
/// So a pause is always shown as a state with a reason and never as an error, and a
/// recording that was skipped for being already imported is reported separately from
/// one that failed (FR-004, FR-022).
///
/// **Strings are English here and move to ARB at T061a.**
library;

import 'package:flutter/material.dart';
import 'package:omi/services/import/import_conditions.dart';
import 'package:omi/services/import/import_job.dart';
import 'package:omi/services/import/import_queue.dart';

/// Shows the queue's progress through a backlog.
class ImportQueuePage extends StatelessWidget {
  /// The queue being shown.
  final ImportQueue queue;

  /// Creates the queue screen.
  const ImportQueuePage({super.key, required this.queue});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importing recordings')),
      body: AnimatedBuilder(
        animation: queue,
        builder: (context, _) => _content(context),
      ),
    );
  }

  /// The whole screen for the queue's current state.
  Widget _content(BuildContext context) {
    if (queue.entries.isEmpty) {
      return const Center(child: Text('Nothing is queued.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (queue.disposition.isPaused) _PausedBanner(disposition: queue.disposition),
        Padding(
          padding: const EdgeInsets.all(16),
          child: _QueueSummary(queue: queue),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: queue.entries.length,
            itemBuilder: (context, index) => _EntryTile(entry: queue.entries[index]),
          ),
        ),
        if (queue.isRunning)
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton(
              onPressed: queue.stop,
              child: const Text('Stop after this recording'),
            ),
          ),
      ],
    );
  }
}

/// Explains a pause as a state, never as a fault.
class _PausedBanner extends StatelessWidget {
  /// Why the queue is waiting.
  final QueueDisposition disposition;

  const _PausedBanner({required this.disposition});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(disposition.explanation, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            'The rest of your recordings are still queued and will carry on by themselves.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The counts, worded so "skipped" never reads as "failed".
class _QueueSummary extends StatelessWidget {
  /// The queue being summarised.
  final ImportQueue queue;

  const _QueueSummary({required this.queue});

  @override
  Widget build(BuildContext context) {
    return Text(_describe(), style: Theme.of(context).textTheme.titleSmall);
  }

  /// Builds the summary line, mentioning only what is true.
  String _describe() {
    final parts = <String>[
      if (queue.completedCount > 0) '${queue.completedCount} imported',
      if (queue.skippedCount > 0) '${queue.skippedCount} already had conversations',
      if (queue.failedCount > 0) '${queue.failedCount} could not be imported',
      if (queue.remainingCount > 0) '${queue.remainingCount} to go',
    ];
    return parts.isEmpty ? 'Finished.' : parts.join(' · ');
  }
}

/// One recording's row.
class _EntryTile extends StatelessWidget {
  /// The recording this row is about.
  final QueueEntry entry;

  const _EntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _leading(context),
      title: Text(entry.job.request.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: _subtitle() == null ? null : Text(_subtitle()!),
    );
  }

  /// The icon for this row's state.
  ///
  /// A skipped recording gets the same reassuring mark as a completed one, because from
  /// the user's point of view the outcome is identical: the conversation exists.
  Widget _leading(BuildContext context) {
    final theme = Theme.of(context);
    if (!entry.isDone) return const Icon(Icons.schedule);
    if (entry.wasSkippedAsDuplicate) return Icon(Icons.check_circle_outline, color: theme.colorScheme.primary);

    return switch (entry.outcome!.stage) {
      ImportStage.completed => Icon(Icons.check_circle, color: theme.colorScheme.primary),
      ImportStage.cancelled => const Icon(Icons.remove_circle_outline),
      _ => Icon(Icons.error_outline, color: theme.colorScheme.error),
    };
  }

  /// What to say beneath the name, if anything.
  String? _subtitle() {
    if (!entry.isDone) return null;
    if (entry.wasSkippedAsDuplicate) return 'Already imported';

    final failure = entry.outcome!.failure;
    if (failure != null) return failure.whatToDo;
    return entry.outcome!.stage == ImportStage.cancelled ? 'Stopped' : null;
  }
}
