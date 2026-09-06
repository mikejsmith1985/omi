// Doubles an 8 kHz PCM stream to 16 kHz so narrowband RecDot audio fits Omi's pipeline.
//
// Why this exists: when the buds negotiate the 8 kHz G.722 mode, the decoder yields
// 8 kHz samples, but every Omi audio source is pinned at 16 kHz mono
// (test/unit/audio_source_test.dart). Nothing in Flutter resamples PCM, so this is the
// smallest correct thing: insert a zero between samples and low-pass the result with a
// short windowed-sinc filter, which removes the mirror image above 4 kHz that plain
// sample doubling would leave in.
import 'dart:math';
import 'dart:typed_data';

/// Stateful 2× upsampler for 16-bit mono PCM; keeps filter history between calls so a
/// stream can be fed chunk by chunk without clicks at the joins.
class NarrowbandUpsampler {
  /// Creates an upsampler with a freshly designed filter and empty history.
  NarrowbandUpsampler() : _taps = _designHalfBandLowPass();

  /// Taps on each side of the centre; 15 gives a 31-tap filter, enough to hold a
  /// 1 kHz tone within a fraction of a dB while suppressing the 4 kHz image.
  static const int _halfLength = 15;

  /// Zero-stuffing halves the signal level; the filter gain puts it back.
  static const double _zeroStuffingGain = 2.0;

  /// Half the output rate relative to the input, expressed as the sinc cutoff.
  static const double _normalisedCutoff = 0.5;

  final Float64List _taps;
  final Float64List _history = Float64List(2 * _halfLength + 1);

  /// Returns twice as many samples as [narrowband], at 16 kHz.
  Int16List upsample(Int16List narrowband) {
    final output = Int16List(narrowband.length * 2);
    var written = 0;
    for (final sample in narrowband) {
      written = _push(sample.toDouble(), output, written);
      written = _push(0.0, output, written);
    }
    return output;
  }

  int _push(double value, Int16List output, int written) {
    for (var i = _history.length - 1; i > 0; i--) {
      _history[i] = _history[i - 1];
    }
    _history[0] = value;
    var accumulator = 0.0;
    for (var i = 0; i < _taps.length; i++) {
      accumulator += _history[i] * _taps[i];
    }
    output[written] = _clampToInt16((accumulator * _zeroStuffingGain).round());
    return written + 1;
  }

  /// A Hamming-windowed sinc low-pass at a quarter of the 16 kHz output rate,
  /// normalised to unity gain at DC.
  static Float64List _designHalfBandLowPass() {
    const length = 2 * _halfLength + 1;
    final taps = Float64List(length);
    var sum = 0.0;
    for (var i = 0; i < length; i++) {
      final offset = i - _halfLength;
      final sinc = offset == 0 ? _normalisedCutoff : sin(pi * _normalisedCutoff * offset) / (pi * offset);
      final window = 0.54 - 0.46 * cos(2 * pi * i / (length - 1));
      taps[i] = sinc * window;
      sum += taps[i];
    }
    for (var i = 0; i < length; i++) {
      taps[i] /= sum;
    }
    return taps;
  }

  static int _clampToInt16(int value) => value > 32767 ? 32767 : (value < -32768 ? -32768 : value);
}
