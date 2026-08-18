/// Purpose: prove the one thing FR-014 actually forbids — quietly using the import time.
///
/// Every test here exists because of a specific way a recording's date gets lost. The
/// file is copied out of a messaging app and its filesystem timestamp becomes today.
/// The container reports 1904 because a field was never written. The recorder's clock
/// was wrong and claims next week. In each case the tempting answer is "just use now",
/// and in each case that produces a conversation filed on a day nothing happened.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/import/recording_time.dart';

final DateTime _now = DateTime(2026, 8, 6, 14, 30);

ResolvedRecordingTime resolve({
  DateTime? embedded,
  String fileName = 'recording.m4a',
  DateTime? modified,
}) {
  return resolveRecordingTime(
    embeddedCreationTime: embedded,
    fileName: fileName,
    fileSystemModified: modified,
    now: _now,
  );
}

/// Strongest evidence wins, and weaker evidence is not consulted.
void _prefersTheStrongestEvidence() {
  group('the strongest available evidence wins', () {
    test('embedded metadata beats the filename and the filesystem', () {
      final embedded = DateTime(2026, 8, 4, 9, 15);

      final resolved = resolve(
        embedded: embedded,
        fileName: 'REC_20260801_120000.m4a',
        modified: DateTime(2026, 8, 6, 14, 0),
      );

      expect(resolved.value, embedded);
      expect(resolved.source, RecordingTimeSource.embeddedMetadata);
      expect(resolved.needsConfirmation, isFalse);
    });

    test('the filename is used when there is no embedded date', () {
      final resolved = resolve(
        fileName: 'REC_20260801_120000.m4a',
        modified: DateTime(2026, 8, 6, 14, 0),
      );

      expect(resolved.value, DateTime(2026, 8, 1, 12, 0, 0));
      expect(resolved.source, RecordingTimeSource.filename);
      expect(resolved.needsConfirmation, isFalse);
    });

    test('the filesystem is the last resort before asking', () {
      final modified = DateTime(2026, 8, 2, 10, 0);

      final resolved = resolve(modified: modified);

      expect(resolved.value, modified);
      expect(resolved.source, RecordingTimeSource.fileSystem);
    });
  });
}

/// The import time is never substituted, however little else is known.
void _neverFallsBackToNow() {
  group('the import time is never substituted', () {
    test('returns unknown when nothing can be determined', () {
      final resolved = resolve();

      expect(resolved.value, isNull);
      expect(resolved.source, RecordingTimeSource.unknown);
      expect(resolved.needsConfirmation, isTrue);
    });

    test('a recent filesystem timestamp is offered but flagged', () {
      // The overwhelmingly common case: a file copied out of a messaging app minutes
      // ago. The timestamp records when it arrived, not when it was recorded.
      final justCopied = _now.subtract(const Duration(minutes: 5));

      final resolved = resolve(modified: justCopied);

      expect(resolved.value, justCopied);
      expect(resolved.needsConfirmation, isTrue);
    });

    test('an old filesystem timestamp is trusted without asking', () {
      final resolved = resolve(modified: _now.subtract(const Duration(days: 3)));

      expect(resolved.needsConfirmation, isFalse);
    });
  });
}

/// Implausible dates are rejected rather than carried forward.
void _rejectsImplausibleDates() {
  group('implausible dates are rejected', () {
    test('ignores a zeroed container date and moves to the next source', () {
      // 1904 is the QuickTime epoch and appears whenever the field was never written.
      final resolved = resolve(
        embedded: DateTime(1904),
        fileName: 'REC_20260801_120000.m4a',
      );

      expect(resolved.source, RecordingTimeSource.filename);
      expect(resolved.value, DateTime(2026, 8, 1, 12, 0, 0));
    });

    test('ignores a date in the future', () {
      // A recorder with a wrong clock. Carrying it forward would file the conversation
      // in a day that has not happened.
      final resolved = resolve(embedded: _now.add(const Duration(days: 30)));

      expect(resolved.source, RecordingTimeSource.unknown);
    });

    test('ignores a future filesystem timestamp too', () {
      final resolved = resolve(modified: _now.add(const Duration(hours: 2)));

      expect(resolved.value, isNull);
    });
  });
}

/// Filename parsing must be strict, or a bitrate becomes a date.
void _parsesFilenamesStrictly() {
  group('filenames are parsed strictly', () {
    test('reads the common recorder patterns', () {
      expect(parseRecordingTimeFromFilename('REC_20260805_143022.m4a'), DateTime(2026, 8, 5, 14, 30, 22));
      expect(parseRecordingTimeFromFilename('2026-08-05_14-30-22.wav'), DateTime(2026, 8, 5, 14, 30, 22));
      expect(parseRecordingTimeFromFilename('audio-20260805T143022.mp3'), DateTime(2026, 8, 5, 14, 30, 22));
    });

    test('reads a date-only name as midnight', () {
      expect(parseRecordingTimeFromFilename('meeting 2026-08-05.m4a'), DateTime(2026, 8, 5));
    });

    test('rejects an impossible month', () {
      expect(parseRecordingTimeFromFilename('track_20264705.mp3'), isNull);
    });

    test('rejects a day that does not exist in that month', () {
      // DateTime would silently roll this into March, filing the conversation on the
      // wrong day rather than admitting the name was not a date.
      expect(parseRecordingTimeFromFilename('20260231.m4a'), isNull);
    });

    test('rejects a name with no date in it', () {
      expect(parseRecordingTimeFromFilename('voice memo.m4a'), isNull);
      expect(parseRecordingTimeFromFilename('song_128kbps.mp3'), isNull);
    });
  });
}

void main() {
  _prefersTheStrongestEvidence();
  _neverFallsBackToNow();
  _rejectsImplausibleDates();
  _parsesFilenamesStrictly();
}
