/// Purpose: say how far along an import is and roughly how much longer it will take.
///
/// FR-016. This matters more than it sounds for a feature whose whole point is
/// handling twenty hours of recordings a week: an import that runs for a long time
/// with no visible movement is indistinguishable from a hang, and a user who cannot
/// tell the difference will force-quit the app and lose the work.
///
/// The estimate is built from **audio transcribed per second of wall clock**, measured
/// as the import runs rather than assumed. Speed varies by several times between a
/// recent phone and an old one, between the small and large speech models, and between
/// a device that is cool and one that has been transcribing for twenty minutes. A fixed
/// multiplier would be wrong for most people most of the time.
///
/// Early estimates are deliberately withheld rather than shown badly. The first few
/// seconds of any import are unrepresentative — models load, buffers fill, the first
/// pass is slower than the rest — and a confident wrong estimate is worse than no
/// estimate, because the user plans around it.
library;

/// How much audio must be transcribed before an estimate is offered.
///
/// Below this the measured rate is dominated by start-up costs rather than by the
/// device's actual throughput.
const double minimumSecondsBeforeEstimating = 20.0;

/// How much of the running rate estimate carries over between updates.
///
/// A heavy weight on history, because throughput genuinely fluctuates — a thermal
/// throttle, another app waking up — and an estimate that jumps around reads as
/// unreliable even when its average is right.
const double rateSmoothingFactor = 0.8;

/// What to tell the user about an import in flight.
class ImportProgress {
  /// How far through the recording, from 0 to 1.
  final double fraction;

  /// How much audio has been transcribed.
  final Duration transcribed;

  /// How long the recording runs in total.
  final Duration total;

  /// Roughly how much longer, or null when it is too early to say honestly.
  final Duration? remaining;

  /// Creates a progress report.
  const ImportProgress({
    required this.fraction,
    required this.transcribed,
    required this.total,
    this.remaining,
  });

  /// Whether an estimate is being withheld because it would not yet be trustworthy.
  bool get isEstimatePending => remaining == null;
}

/// Tracks how fast an import is running and projects when it will finish.
///
/// Fed elapsed time explicitly rather than reading a clock itself, so its behaviour is
/// testable without waiting for real time to pass.
class ImportProgressEstimator {
  /// How long the recording runs.
  final Duration recordingLength;

  /// Smoothed audio-seconds transcribed per wall-clock second.
  double? _smoothedRate;
  double _lastSecondsTranscribed = 0;
  Duration _lastElapsed = Duration.zero;

  /// Creates an estimator for a recording of known length.
  ImportProgressEstimator({required this.recordingLength});

  /// The measured throughput, or null before enough has been seen to measure it.
  ///
  /// Exposed so the interface can say "about three times faster than real time" where
  /// that is useful, and so a pathologically slow device is diagnosable.
  double? get audioSecondsPerWallSecond => _smoothedRate;

  /// Records progress and returns what to show.
  ///
  /// [secondsTranscribed] is audio consumed, never elapsed time — the two differ by a
  /// factor of several, which is the entire benefit of the feature.
  ImportProgress update({required double secondsTranscribed, required Duration elapsed}) {
    _updateRate(secondsTranscribed, elapsed);

    final totalSeconds = recordingLength.inMilliseconds / 1000.0;
    final fraction = totalSeconds <= 0 ? 0.0 : (secondsTranscribed / totalSeconds).clamp(0.0, 1.0);

    return ImportProgress(
      fraction: fraction,
      transcribed: Duration(milliseconds: (secondsTranscribed * 1000).round()),
      total: recordingLength,
      remaining: _projectRemaining(secondsTranscribed, totalSeconds),
    );
  }

  /// Folds the latest observation into the smoothed throughput.
  void _updateRate(double secondsTranscribed, Duration elapsed) {
    final wallDelta = (elapsed - _lastElapsed).inMilliseconds / 1000.0;
    final audioDelta = secondsTranscribed - _lastSecondsTranscribed;
    _lastElapsed = elapsed;
    _lastSecondsTranscribed = secondsTranscribed;

    // A zero or backwards interval carries no information about speed. Feeding it in
    // would divide by zero or, worse, quietly poison the average with a spike.
    if (wallDelta <= 0 || audioDelta <= 0) return;

    final observed = audioDelta / wallDelta;
    _smoothedRate = _smoothedRate == null
        ? observed
        : _smoothedRate! * rateSmoothingFactor + observed * (1 - rateSmoothingFactor);
  }

  /// Projects the time left, or null while an estimate would be untrustworthy.
  Duration? _projectRemaining(double secondsTranscribed, double totalSeconds) {
    final rate = _smoothedRate;
    if (rate == null || rate <= 0) return null;
    if (secondsTranscribed < minimumSecondsBeforeEstimating) return null;

    final audioLeft = totalSeconds - secondsTranscribed;
    if (audioLeft <= 0) return Duration.zero;
    return Duration(milliseconds: (audioLeft / rate * 1000).round());
  }
}
