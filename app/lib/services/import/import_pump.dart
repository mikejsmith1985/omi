/// Purpose: feed a decoded recording into the transcription pipeline at a rate the
/// device can absorb — no faster, and no slower than it has to be.
///
/// This is the piece the whole feature turns on, and the reason it needs to exist is
/// that every other audio source is self-pacing. A microphone produces one second of
/// audio per second; a Bluetooth device the same. Nothing downstream ever needed to
/// limit intake because nothing could ever supply too much. A file can.
///
/// Two wrong answers are both easy to reach:
///
///   * **Feed as fast as the decoder runs.** The transcription socket buffers whatever
///     it is given and transcribes on a timer, so an hour of audio arrives as one
///     enormous buffer and one enormous transcription call. That is the memory failure
///     SC-005 exists to prevent.
///   * **Feed at real time.** Correct, bounded, and useless: a one-hour recording then
///     takes an hour to import, which for twenty hours of recordings a week is not a
///     feature anyone would use.
///
/// The right answer is to bound *audio in flight* rather than elapsed time. The import
/// then runs exactly as fast as the device can transcribe and no faster, and peak
/// memory is flat with respect to how long the recording is (contract obligation P-1).
library;

import 'dart:async';

import 'package:omi/services/audio/native_decoder.dart';
import 'package:omi/services/audio_sources/audio_source.dart';
import 'package:omi/services/audio_sources/file_import_source.dart';

/// Bytes of PCM per second at the pipeline's rate: 16 kHz, 16-bit, mono.
const int pipelineBytesPerSecond = 32000;

/// How much audio may be waiting to be transcribed at once.
///
/// Thirty seconds, chosen to match the transcription model's own attention window
/// rather than picked as a round number. Smaller chunks would give the engine less
/// context and produce worse transcripts; larger ones would raise peak memory and make
/// cancellation slow to take effect, without improving anything.
const int maxAudioInFlightSeconds = 30;

/// How often to re-check whether the pipeline has drained enough to accept more.
///
/// Short enough that the pump does not idle after the pipeline frees up, long enough
/// that waiting costs no measurable battery.
const Duration drainPollInterval = Duration(milliseconds: 100);

/// How much to shrink the in-flight budget by while the system wants memory back.
const int memoryPressureDivisor = 4;

/// The smallest in-flight budget the pump will use, however much pressure there is.
///
/// One second of audio. Below this the pipeline would spend more effort starting and
/// stopping transcription passes than transcribing, and an import that never finishes
/// helps nobody — the point of backing off is to survive the pressure and complete,
/// not to grind to a halt politely.
const int minimumAllowanceBytes = pipelineBytesPerSecond;

/// Where the pump sends frames, and how it learns whether to send more.
///
/// An interface rather than the socket itself so the pacing can be tested without a
/// transcription engine — the behaviour that matters is *when* the pump feeds, and
/// proving that against a real engine would be slow and non-deterministic.
abstract class ImportAudioSink {
  /// Accepts one frame for transcription and for the write-ahead log.
  void sendFrame(WalFrame frame);

  /// Bytes of audio queued but not yet transcribed.
  int get bytesAwaitingTranscription;

  /// Whether a transcription pass is running right now.
  ///
  /// Counted as in-flight audio on top of [bytesAwaitingTranscription], because the
  /// socket clears its buffer when it starts a pass — so a buffer reading zero during
  /// a pass does not mean the pipeline is idle.
  bool get isTranscribing;
}

/// Reports whether the operating system is asking for memory back.
///
/// Flutter surfaces this through `WidgetsBindingObserver.didHaveMemoryPressure`, so the
/// pump can respond to a real signal rather than inferring pressure from a heuristic it
/// would have no way to calibrate. Behind an interface so the response is testable
/// without having to actually exhaust a device's memory.
abstract class MemoryPressureSignal {
  /// Whether the system has recently asked for memory back.
  bool get isUnderPressure;
}

/// The default signal: no pressure ever reported.
///
/// Used where nothing is wired up yet, so the pump behaves identically to having no
/// pressure handling at all rather than mysteriously throttling.
class NoMemoryPressure implements MemoryPressureSignal {
  /// Creates a signal that never reports pressure.
  const NoMemoryPressure();

  @override
  bool get isUnderPressure => false;
}

/// Lets a caller stop an import that is already running.
class ImportCancellation {
  bool _isCancelled = false;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Requests that the import stop at the next opportunity.
  void cancel() => _isCancelled = true;
}

/// How a pump run ended.
enum PumpOutcome {
  /// The whole recording was fed through and the tail flushed.
  completed,

  /// The user stopped it.
  cancelled,
}

/// What one pump run produced.
class PumpResult {
  /// How the run ended.
  final PumpOutcome outcome;

  /// How many seconds of audio were fed into the pipeline.
  final double secondsFed;

  /// Creates a result.
  const PumpResult({required this.outcome, required this.secondsFed});
}

/// Feeds decoded audio into the transcription pipeline, paced by what it can absorb.
class ImportPump {
  /// Turns decoded bytes into pipeline frames.
  final FileImportSource source;

  /// Supplies decoded PCM on demand.
  ///
  /// The read-only interface rather than the session itself: the pump consumes audio,
  /// it does not own the decoder's lifetime, and depending on the narrower type is what
  /// lets the pacing be tested without a real decoder.
  final DecodedAudioReader decoder;

  /// Where the frames go.
  final ImportAudioSink sink;

  /// The bound on audio awaiting transcription, in bytes.
  final int maxAudioInFlightBytes;

  /// How often to re-check a full pipeline.
  final Duration pollInterval;

  /// Tells the pump when the system wants memory back.
  final MemoryPressureSignal memoryPressure;

  /// Creates a pump for one import.
  ImportPump({
    required this.source,
    required this.decoder,
    required this.sink,
    this.maxAudioInFlightBytes = maxAudioInFlightSeconds * pipelineBytesPerSecond,
    this.pollInterval = drainPollInterval,
    this.memoryPressure = const NoMemoryPressure(),
  });

  /// Feeds the whole recording through, reporting progress as it goes.
  ///
  /// [onSecondsFed] receives the running total of audio duration handed over, which is
  /// what progress is measured against — never elapsed time, since the import runs
  /// faster than real time by a factor that varies with the device and the recording.
  Future<PumpResult> run({
    required ImportCancellation cancellation,
    void Function(double secondsFed)? onSecondsFed,
  }) async {
    var bytesFed = 0;

    while (true) {
      if (cancellation.isCancelled) {
        return PumpResult(outcome: PumpOutcome.cancelled, secondsFed: _toSeconds(bytesFed));
      }

      await _waitUntilPipelineCanAccept(cancellation);
      final chunk = await decoder.readChunk();

      if (chunk.isEmpty) {
        _flushTail();
        return PumpResult(outcome: PumpOutcome.completed, secondsFed: _toSeconds(bytesFed));
      }

      _sendFrames(source.processBytes(chunk));
      bytesFed += chunk.length;
      onSecondsFed?.call(_toSeconds(bytesFed));
    }
  }

  /// Blocks until the pipeline has drained below the in-flight bound.
  ///
  /// Returns immediately when cancellation is requested, so stopping an import does not
  /// have to wait for a transcription pass it no longer cares about.
  Future<void> _waitUntilPipelineCanAccept(ImportCancellation cancellation) async {
    while (!cancellation.isCancelled && _isPipelineFull()) {
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Whether the pipeline is holding as much audio as it is allowed to.
  ///
  /// A running transcription pass holds a chunk the buffer no longer reports — the
  /// socket clears its buffer when it starts a pass — so half the budget is reserved
  /// for it. Without that reservation the bound would be exceeded by exactly one
  /// chunk whenever a pass was in progress, which is the case that occurs most of the
  /// time rather than rarely.
  ///
  /// Under memory pressure the budget shrinks again. The import then runs slower and
  /// finishes, which is the outcome the user wants; without it the system reclaims
  /// memory by killing the app, which is the outcome nobody wants (FR-009, and User
  /// Story 2's fourth acceptance scenario).
  ///
  /// The floor guards **only** the memory-pressure reduction, and never rises above
  /// what is already allowed. Applying it to the total instead silently cancelled the
  /// in-flight reservation whenever the configured bound was near one second — the
  /// reservation was computed and then clamped straight back up again. Caught by
  /// `_reservesBudgetForARunningPass`.
  bool _isPipelineFull() {
    var allowance = maxAudioInFlightBytes;
    if (sink.isTranscribing) allowance ~/= 2;

    if (memoryPressure.isUnderPressure) {
      final floor = allowance < minimumAllowanceBytes ? allowance : minimumAllowanceBytes;
      allowance = (allowance ~/ memoryPressureDivisor).clamp(floor, allowance);
    }
    return sink.bytesAwaitingTranscription >= allowance;
  }

  /// Emits the final partial frame, if the recording did not end on a frame boundary.
  void _flushTail() {
    if (source.bufferedByteCount == 0) return;
    _sendFrames(source.flush());
  }

  /// Hands a batch of frames to the sink.
  void _sendFrames(List<WalFrame> frames) {
    for (final frame in frames) {
      sink.sendFrame(frame);
    }
  }

  /// Converts a byte count at the pipeline's rate into seconds of audio.
  double _toSeconds(int byteCount) => byteCount / pipelineBytesPerSecond;
}
