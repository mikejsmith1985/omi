/// Purpose: show what an import is doing, so a long wait reads as work rather than a hang.
///
/// FR-016 and FR-017. The screen deliberately owns nothing: the import belongs to
/// [ImportController], which outlives this page, so leaving cannot cancel an hour of
/// transcription. Cancelling stays something the user does on purpose.
///
/// **Strings are English here and move to ARB at T061a**, along with every other
/// user-facing string in this feature.
library;

import 'package:flutter/material.dart';
import 'package:omi/services/import/import_controller.dart';
import 'package:omi/services/import/import_progress.dart';

/// Shows the running import and lets the user stop it.
class ImportProgressPage extends StatelessWidget {
  /// Owns the import being shown.
  final ImportController controller;

  /// Creates the progress screen.
  const ImportProgressPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Importing')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => _body(context),
      ),
    );
  }

  /// The screen's content for the controller's current state.
  Widget _body(BuildContext context) {
    final job = controller.activeJob;
    if (job == null) return const _NothingRunning();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(job.request.displayName, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          _ProgressReadout(progress: controller.progress),
          const SizedBox(height: 24),
          const Text(
            'You can leave this screen — the import keeps going, and you will be told '
            'when it finishes.',
          ),
          const Spacer(),
          OutlinedButton(
            onPressed: controller.cancel,
            child: const Text('Stop importing'),
          ),
        ],
      ),
    );
  }
}

/// What to show when no import is running.
class _NothingRunning extends StatelessWidget {
  const _NothingRunning();

  @override
  Widget build(BuildContext context) => const Center(child: Text('No import is running.'));
}

/// The bar, the position, and an estimate only once there is an honest one.
class _ProgressReadout extends StatelessWidget {
  /// The current progress, or null before the first update.
  final ImportProgress? progress;

  const _ProgressReadout({required this.progress});

  @override
  Widget build(BuildContext context) {
    final current = progress;
    if (current == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(),
          SizedBox(height: 12),
          Text('Getting started…'),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: current.fraction),
        const SizedBox(height: 12),
        Text('${_describe(current.transcribed)} of ${_describe(current.total)} transcribed'),
        const SizedBox(height: 4),
        Text(_describeRemaining(current), style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  /// Says how much longer, or says nothing rather than guessing.
  ///
  /// An early estimate would be dominated by start-up costs and wrong by a wide margin.
  /// A confident wrong number is worse than none, because the user plans around it.
  String _describeRemaining(ImportProgress progress) {
    if (progress.isEstimatePending) return 'Working out how long this will take…';
    final remaining = progress.remaining!;
    if (remaining.inSeconds < 30) return 'Almost done';
    return 'About ${_describe(remaining)} left';
  }

  /// Renders a duration the way a person would say it.
  String _describe(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
    if (duration.inMinutes > 0) return '${duration.inMinutes}m';
    return '${duration.inSeconds}s';
  }
}
