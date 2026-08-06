/// Purpose: the estimate must be honest — right when it speaks, silent when it cannot be.
///
/// The failure this guards against is not an inaccurate number. It is a *confident*
/// inaccurate number: a user who is told twelve minutes and waits forty has been
/// misled, and will trust nothing the screen says afterwards. So these tests check both
/// halves — that a settled estimate is close, and that no estimate is offered while it
/// would be guesswork.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/import/import_progress.dart';

/// Feeds the estimator a steady import running at [speedFactor] times real time.
ImportProgress runSteadily(
  ImportProgressEstimator estimator, {
  required double untilAudioSeconds,
  required double speedFactor,
  double stepAudioSeconds = 5,
}) {
  var audio = 0.0;
  var progress = estimator.update(secondsTranscribed: 0, elapsed: Duration.zero);

  while (audio < untilAudioSeconds) {
    audio += stepAudioSeconds;
    final elapsedSeconds = audio / speedFactor;
    progress = estimator.update(
      secondsTranscribed: audio,
      elapsed: Duration(milliseconds: (elapsedSeconds * 1000).round()),
    );
  }
  return progress;
}

/// The estimate must stay silent until it has something worth saying.
void _withholdsEarlyEstimates() {
  group('an untrustworthy estimate is withheld, not shown badly', () {
    test('offers nothing before any progress', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(hours: 1));

      final progress = estimator.update(secondsTranscribed: 0, elapsed: Duration.zero);

      expect(progress.isEstimatePending, isTrue);
      expect(progress.remaining, isNull);
    });

    test('offers nothing in the first seconds, when start-up costs dominate', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(hours: 1));

      final progress = runSteadily(estimator, untilAudioSeconds: 10, speedFactor: 5);

      expect(progress.isEstimatePending, isTrue);
    });

    test('offers an estimate once enough audio has been seen', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(hours: 1));

      final progress = runSteadily(estimator, untilAudioSeconds: 60, speedFactor: 5);

      expect(progress.isEstimatePending, isFalse);
      expect(progress.remaining, isNotNull);
    });
  });
}

/// A settled estimate must actually be close to the truth.
void _estimatesAreAccurateOnceSettled() {
  group('a settled estimate is close', () {
    test('projects the remaining time of a steady import', () {
      // An hour of audio at five times real time takes twelve minutes. After two
      // minutes of audio, ~58 minutes remain, which is ~11.6 minutes of waiting.
      final estimator = ImportProgressEstimator(recordingLength: const Duration(hours: 1));

      final progress = runSteadily(estimator, untilAudioSeconds: 120, speedFactor: 5);

      expect(progress.remaining!.inSeconds, closeTo(696, 30));
    });

    test('measures throughput rather than assuming it', () {
      final fast = ImportProgressEstimator(recordingLength: const Duration(hours: 1));
      final slow = ImportProgressEstimator(recordingLength: const Duration(hours: 1));

      final fastProgress = runSteadily(fast, untilAudioSeconds: 120, speedFactor: 10);
      final slowProgress = runSteadily(slow, untilAudioSeconds: 120, speedFactor: 2);

      // A device five times slower must be told it has five times longer to wait.
      expect(slowProgress.remaining!.inSeconds, greaterThan(fastProgress.remaining!.inSeconds * 3));
      expect(fast.audioSecondsPerWallSecond, closeTo(10, 1));
      expect(slow.audioSecondsPerWallSecond, closeTo(2, 0.5));
    });

    test('reports no time remaining at the end', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(minutes: 2));

      final progress = runSteadily(estimator, untilAudioSeconds: 120, speedFactor: 5);

      expect(progress.fraction, 1.0);
      expect(progress.remaining, Duration.zero);
    });
  });
}

/// Progress must track audio, and must never leave the range a bar can show.
void _progressFractionIsWellBehaved() {
  group('the progress fraction stays sane', () {
    test('is the share of audio transcribed', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(minutes: 10));

      final progress = estimator.update(secondsTranscribed: 300, elapsed: const Duration(seconds: 60));

      expect(progress.fraction, closeTo(0.5, 0.001));
    });

    test('cannot exceed one, even if more audio arrives than expected', () {
      // Container durations are sometimes slightly wrong, so the decoder can legitimately
      // produce a little more audio than the file claimed. A progress bar past its end
      // looks like a defect, so the fraction is clamped rather than trusted.
      final estimator = ImportProgressEstimator(recordingLength: const Duration(minutes: 1));

      final progress = estimator.update(secondsTranscribed: 75, elapsed: const Duration(seconds: 15));

      expect(progress.fraction, 1.0);
    });

    test('is zero rather than infinite for a recording of unknown length', () {
      final estimator = ImportProgressEstimator(recordingLength: Duration.zero);

      final progress = estimator.update(secondsTranscribed: 10, elapsed: const Duration(seconds: 2));

      expect(progress.fraction, 0.0);
    });
  });
}

/// Degenerate timing must not poison the running average.
void _degenerateInputIsIgnored() {
  group('degenerate observations do not poison the rate', () {
    test('a repeated reading with no elapsed time is ignored', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(hours: 1));
      runSteadily(estimator, untilAudioSeconds: 120, speedFactor: 5);
      final before = estimator.audioSecondsPerWallSecond;

      // The same instant reported twice — a rebuild, not progress.
      estimator.update(secondsTranscribed: 120, elapsed: const Duration(seconds: 24));

      expect(estimator.audioSecondsPerWallSecond, before);
    });

    test('a backwards reading is ignored', () {
      final estimator = ImportProgressEstimator(recordingLength: const Duration(hours: 1));
      runSteadily(estimator, untilAudioSeconds: 120, speedFactor: 5);
      final before = estimator.audioSecondsPerWallSecond;

      estimator.update(secondsTranscribed: 60, elapsed: const Duration(seconds: 30));

      expect(estimator.audioSecondsPerWallSecond, before);
    });
  });
}

void main() {
  _withholdsEarlyEstimates();
  _estimatesAreAccurateOnceSettled();
  _progressFractionIsWellBehaved();
  _degenerateInputIsIgnored();
}
