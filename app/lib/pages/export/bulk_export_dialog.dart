/// Purpose: the dialog that runs a bulk export and shows it happening.
///
/// A batch of recordings can take minutes to decode. Without a visible count and a way
/// out, a user cannot tell a slow export from a frozen app, and the only remedy they
/// have is killing the app — which is how a half-finished export becomes a support
/// problem. So this shows what it is working on and stays cancellable throughout.
library;

import 'package:flutter/material.dart';
import 'package:omi/providers/sync_provider.dart';
import 'package:omi/services/export/wal_bulk_exporter.dart';

/// Runs a bulk export behind a modal dialog and returns what it produced.
///
/// Returns null when the user dismissed the dialog before anything was exported.
Future<BulkExportResult?> showBulkExportDialog(BuildContext context, SyncProvider provider) {
  return showDialog<BulkExportResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _BulkExportDialog(provider: provider),
  );
}

class _BulkExportDialog extends StatefulWidget {
  const _BulkExportDialog({required this.provider});

  final SyncProvider provider;

  @override
  State<_BulkExportDialog> createState() => _BulkExportDialogState();
}

class _BulkExportDialogState extends State<_BulkExportDialog> {
  BulkExportProgress? _progress;
  bool _wasCancelRequested = false;

  @override
  void initState() {
    super.initState();
    _startExport();
  }

  Future<void> _startExport() async {
    final result = await widget.provider.exportAllRecordingsToWav(onProgress: _onProgress);
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  void _onProgress(BulkExportProgress progress) {
    // The export runs to completion off-screen if the dialog has gone; dropping the
    // update rather than calling setState avoids tearing down a disposed state.
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  void _requestCancel() {
    setState(() => _wasCancelRequested = true);
    widget.provider.cancelBulkExport();
  }

  String get _statusLabel {
    final progress = _progress;
    if (progress == null) return 'Preparing…';
    if (_wasCancelRequested) return 'Finishing the current recording…';
    return 'Exporting ${progress.completedCount} of ${progress.totalCount}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1C1E),
      title: const Text('Exporting recordings', style: TextStyle(color: Colors.white, fontSize: 18)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _progress?.fractionComplete ?? 0),
          const SizedBox(height: 16),
          Text(_statusLabel, style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _wasCancelRequested ? null : _requestCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
