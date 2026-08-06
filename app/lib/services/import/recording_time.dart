/// Purpose: work out when a recording was actually made, and be honest when we cannot.
///
/// FR-014 forbids one specific shortcut: silently using the import time. It is the
/// tempting default — it is always available and always plausible — and it is always
/// wrong. A conversation filed at the moment you happened to press Import tells you
/// nothing, and worse, it looks correct.
///
/// The T012 spike established that the app cannot set a conversation's timestamp at
/// all (research.md Part 4), so what this produces is stored and displayed alongside
/// the conversation rather than becoming its date. Determining it is still worth doing:
/// the information would otherwise be lost, and the upstream change that would let the
/// conversation carry it is small enough to be worth preparing for.
library;

/// How a recording's time was arrived at, strongest first.
///
/// The order is the fallback order. The first source that yields a plausible answer
/// wins, and the weaker ones carry [needsConfirmation] because being wrong quietly is
/// worse than asking.
enum RecordingTimeSource {
  /// A creation date inside the file itself. Trustworthy.
  embeddedMetadata,

  /// Parsed from a name like `REC_20260805_143022`. Recorders write these on purpose.
  filename,

  /// The file's own modification time. Weak, and sometimes actively misleading.
  fileSystem,

  /// The user told us.
  userProvided,

  /// Nothing worked.
  unknown;

  /// Whether a time from this source should be confirmed before being relied on.
  ///
  /// [fileSystem] is conditional rather than always — see [isSuspectFilesystemTime],
  /// which is where the real judgement lives.
  bool get needsConfirmation => this == unknown || this == fileSystem;
}

/// How recent a filesystem timestamp has to be before we stop believing it.
///
/// A recording made moments ago is possible but rare; a file *copied* moments ago is
/// the overwhelmingly common case. Messaging apps, cloud drives and USB transfers all
/// rewrite the modification time, so a fresh timestamp on an old recording is the
/// normal outcome of moving a file, not an unusual one.
const Duration suspectFilesystemTimeWindow = Duration(hours: 6);

/// Whether a filesystem timestamp is too recent to be believed.
///
/// Returns true when [candidate] falls within [suspectFilesystemTimeWindow] of [now],
/// which is the case where the timestamp is far more likely to record when the file
/// arrived on this device than when the audio was captured.
bool isSuspectFilesystemTime(DateTime candidate, {required DateTime now}) {
  final age = now.difference(candidate);
  return age < suspectFilesystemTimeWindow;
}

/// A recording time and where it came from.
class ResolvedRecordingTime {
  /// When the recording was made, if we could tell.
  final DateTime? value;

  /// How [value] was determined.
  final RecordingTimeSource source;

  /// Whether the user should be asked to confirm this before it is relied on.
  ///
  /// Decided when the time is resolved rather than inferred from [source] alone,
  /// because for a filesystem timestamp the answer depends on *how recent* it is —
  /// see [isSuspectFilesystemTime].
  final bool needsConfirmation;

  /// Creates a resolved time.
  const ResolvedRecordingTime(this.value, this.source, {this.needsConfirmation = false});

  /// The result when nothing could be determined.
  ///
  /// Deliberately carries no value at all. There is no constructor here that takes
  /// "now" as a fallback, because FR-014's whole point is that no such fallback exists.
  static const ResolvedRecordingTime unknown =
      ResolvedRecordingTime(null, RecordingTimeSource.unknown, needsConfirmation: true);
}

/// Works out when a recording was made, following FR-014's order of evidence.
///
/// The order is strongest-first and stops at the first source that yields a plausible
/// answer: what the file says about itself, then what its name says, then what the
/// filesystem says — and if none of them can be believed, the user is asked.
///
/// **The import time is never a fallback.** It is always available and always plausible
/// and always wrong, and a conversation stamped with the moment somebody pressed Import
/// tells them nothing while looking entirely correct. That absence is the requirement.
ResolvedRecordingTime resolveRecordingTime({
  required DateTime? embeddedCreationTime,
  required String fileName,
  required DateTime? fileSystemModified,
  required DateTime now,
}) {
  if (_isPlausible(embeddedCreationTime, now)) {
    return ResolvedRecordingTime(embeddedCreationTime, RecordingTimeSource.embeddedMetadata);
  }

  final fromName = parseRecordingTimeFromFilename(fileName);
  if (_isPlausible(fromName, now)) {
    return ResolvedRecordingTime(fromName, RecordingTimeSource.filename);
  }

  if (_isPlausible(fileSystemModified, now)) {
    // Offered, but flagged for confirmation when it is recent enough to be the moment
    // the file arrived rather than the moment it was recorded.
    return ResolvedRecordingTime(
      fileSystemModified,
      RecordingTimeSource.fileSystem,
      needsConfirmation: isSuspectFilesystemTime(fileSystemModified!, now: now),
    );
  }

  return ResolvedRecordingTime.unknown;
}

/// Whether a candidate time could describe a real recording.
///
/// Rejects the future outright: a recording made after now is a clock that was wrong
/// when the file was written, and carrying it forward would file a conversation in a
/// day that has not happened.
bool _isPlausible(DateTime? candidate, DateTime now) {
  if (candidate == null) return false;
  if (candidate.isAfter(now)) return false;
  return candidate.isAfter(earliestPlausibleRecordingTime);
}

/// The floor for a believable recording date.
///
/// A file whose metadata claims 1904 or 1970 is reporting a zeroed or epoch-default
/// field, not a date. Both appear routinely in audio containers.
final DateTime earliestPlausibleRecordingTime = DateTime(2000);

/// Patterns recorders use in filenames, most specific first.
///
/// Ordered so that a name containing both a date and a time does not match the
/// date-only pattern first and lose the time.
final List<RegExp> _filenameTimePatterns = [
  // REC_20260805_143022 · 20260805-143022 · 20260805T143022
  RegExp(r'(\d{4})(\d{2})(\d{2})[_\-T](\d{2})(\d{2})(\d{2})'),
  // 2026-08-05_14-30-22 · 2026_08_05 14.30.22
  RegExp(r'(\d{4})[-_](\d{2})[-_](\d{2})[ _T](\d{2})[-_.:](\d{2})[-_.:](\d{2})'),
  // 2026-08-05 · 20260805 — date only, so the time falls back to midnight
  RegExp(r'(\d{4})[-_]?(\d{2})[-_]?(\d{2})'),
];

/// Reads a recording time out of a filename, or returns null if there is none.
///
/// Deliberately strict about ranges: a run of digits that happens to look like a date
/// but describes month 47 is a bitrate or a serial number, and accepting it would put
/// a conversation in the wrong year.
DateTime? parseRecordingTimeFromFilename(String fileName) {
  for (final pattern in _filenameTimePatterns) {
    final match = pattern.firstMatch(fileName);
    if (match == null) continue;

    final parsed = _buildDateFromMatch(match);
    if (parsed != null) return parsed;
  }
  return null;
}

/// Turns a matched filename pattern into a date, rejecting impossible values.
DateTime? _buildDateFromMatch(RegExpMatch match) {
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);

  final hasTime = match.groupCount >= 6 && match.group(4) != null;
  final hour = hasTime ? int.parse(match.group(4)!) : 0;
  final minute = hasTime ? int.parse(match.group(5)!) : 0;
  final second = hasTime ? int.parse(match.group(6)!) : 0;

  if (year < 2000 || year > 2100) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  final candidate = DateTime(year, month, day, hour, minute, second);
  // DateTime silently rolls 31 February over into March. Comparing back catches it.
  if (candidate.month != month || candidate.day != day) return null;
  return candidate;
}
