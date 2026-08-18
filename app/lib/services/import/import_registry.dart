/// Purpose: remember which recordings have already been imported, so selecting one
/// twice does not produce two conversations.
///
/// FR-004 and SC-006. The case is not hypothetical: a person working through a backlog
/// of recordings loses track of where they got to, and a recorder app that exports on
/// every share produces the same audio under a new name each time. Without this, the
/// natural way to use the feature produces duplicates.
///
/// Identity is the content hash, never the path or the name — see `content_identity.dart`
/// for why. What is stored is the hash and the conversation it produced, so a repeat
/// selection can point the user at the conversation they already have rather than only
/// refusing.
///
/// **Not durable across a reinstall.** Accepted, and recorded in data-model.md: the
/// failure mode is one duplicate conversation after a reinstall, which the user can
/// delete. Storing it server-side would mean sending Omi a record of every file a user
/// has ever imported, which is a much worse trade for a much smaller problem.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where the record of completed imports is kept.
const String importRegistryPreferenceKey = 'transcriptboss_imported_recordings';

/// A recording that has already been imported.
class ImportedRecording {
  /// The content hash that identifies the recording.
  final String contentHash;

  /// The conversation it produced.
  final String conversationId;

  /// What the file was called when it was imported, for showing the user.
  final String displayName;

  /// When the import completed.
  final DateTime importedAt;

  /// When the recording was actually made, where that could be established.
  ///
  /// Stored because the conversation itself cannot carry it — the T012 spike found no
  /// route to set a conversation's time from inside the app. Keeping it here means the
  /// information is not lost, the user can be shown it, and if Omi later accepts a
  /// `started_at` on creation nothing has to be re-derived from files that may by then
  /// have been deleted.
  final DateTime? recordingTime;

  /// Creates a record of a completed import.
  const ImportedRecording({
    required this.contentHash,
    required this.conversationId,
    required this.displayName,
    required this.importedAt,
    this.recordingTime,
  });

  /// Restores a record from stored form.
  factory ImportedRecording.fromJson(Map<String, dynamic> json) => ImportedRecording(
        contentHash: json['contentHash'] as String,
        conversationId: json['conversationId'] as String,
        displayName: json['displayName'] as String? ?? '',
        importedAt: DateTime.fromMillisecondsSinceEpoch(json['importedAt'] as int? ?? 0),
        recordingTime: _readOptionalDate(json['recordingTime']),
      );

  /// Renders the record for storage.
  Map<String, dynamic> toJson() => {
        'contentHash': contentHash,
        'conversationId': conversationId,
        'displayName': displayName,
        'importedAt': importedAt.millisecondsSinceEpoch,
        'recordingTime': recordingTime?.millisecondsSinceEpoch,
      };

  /// Returns a copy with a corrected recording time (FR-015).
  ImportedRecording withRecordingTime(DateTime? corrected) => ImportedRecording(
        contentHash: contentHash,
        conversationId: conversationId,
        displayName: displayName,
        importedAt: importedAt,
        recordingTime: corrected,
      );

  /// Whether the conversation sits at a materially different time from the recording.
  ///
  /// What FR-014b turns on: when these differ the user must be told, rather than left
  /// to believe the timeline is accurate.
  bool get isFiledAwayFromRecordingTime {
    final made = recordingTime;
    if (made == null) return false;
    return importedAt.difference(made).abs() > const Duration(minutes: 5);
  }
}

/// Reads a stored optional timestamp, tolerating a missing or malformed value.
DateTime? _readOptionalDate(Object? stored) {
  if (stored is! int) return null;
  return DateTime.fromMillisecondsSinceEpoch(stored);
}

/// Remembers which recordings have been imported.
class ImportRegistry {
  /// Reads the stored preferences. Injectable so tests need no platform channel.
  final Future<SharedPreferences> Function() _openPreferences;

  /// Creates a registry backed by the app's shared preferences.
  ImportRegistry() : _openPreferences = SharedPreferences.getInstance;

  /// Creates a registry over supplied preferences, for tests.
  ImportRegistry.withPreferences(SharedPreferences preferences) : _openPreferences = (() async => preferences);

  /// The recording already imported under [contentHash], or null if there is none.
  Future<ImportedRecording?> findByContentHash(String contentHash) async {
    final entries = await readAll();
    for (final entry in entries) {
      if (entry.contentHash == contentHash) return entry;
    }
    return null;
  }

  /// Records a completed import.
  ///
  /// Called only once a conversation exists. Recording it earlier would make a failed
  /// import look like a completed one and block the retry that should follow it —
  /// which is the same mistake as setting a conversation id before there is a
  /// conversation (data-model Invariant 1).
  Future<void> recordCompleted(ImportedRecording recording) async {
    final entries = await readAll();
    entries.removeWhere((entry) => entry.contentHash == recording.contentHash);
    entries.add(recording);
    await _writeAll(entries);
  }

  /// Corrects the stored recording time for an already-imported recording (FR-015).
  ///
  /// Does nothing when the recording is not known, rather than creating a record for
  /// an import that never happened.
  Future<void> correctRecordingTime(String contentHash, DateTime? corrected) async {
    final entries = await readAll();
    final index = entries.indexWhere((entry) => entry.contentHash == contentHash);
    if (index < 0) return;

    entries[index] = entries[index].withRecordingTime(corrected);
    await _writeAll(entries);
  }

  /// Forgets one recording, so it can be imported again.
  ///
  /// Needed when the user deletes the conversation an import produced: the record
  /// would otherwise keep pointing at something that no longer exists, and refuse a
  /// re-import the user now actively wants.
  Future<void> forget(String contentHash) async {
    final entries = await readAll();
    entries.removeWhere((entry) => entry.contentHash == contentHash);
    await _writeAll(entries);
  }

  /// Every recording imported so far.
  Future<List<ImportedRecording>> readAll() async {
    final preferences = await _openPreferences();
    final stored = preferences.getString(importRegistryPreferenceKey);
    if (stored == null || stored.isEmpty) return [];

    try {
      final decoded = jsonDecode(stored) as List<dynamic>;
      return decoded.map((entry) => ImportedRecording.fromJson(entry as Map<String, dynamic>)).toList();
    } on FormatException {
      // Corrupt storage must not make the feature unusable. The cost of starting over
      // is one possible duplicate; the cost of throwing here is that no import can ever
      // run again on this device.
      return [];
    }
  }

  /// Replaces the stored record set.
  Future<void> _writeAll(List<ImportedRecording> entries) async {
    final preferences = await _openPreferences();
    await preferences.setString(
      importRegistryPreferenceKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }
}
