// Pure-Dart ITU-T G.722 decoder for the viaim RecDot's call and FlashRecord audio.
//
// Why this exists (Article VII gap): neither Flutter, Core Audio nor MediaCodec offers a
// G.722 decoder, and decoding on the backend would put the audio on the metered cloud path.
// The buds send raw G.722 (see specs/002-viaim-recdot-device/protocol.md §5), so the phone
// must decode it before the on-device engine can hear it. A pure-Dart port keeps one
// implementation for both platforms and lets `flutter test` prove it bit-exact against the
// ITU reference (test/fixtures/g722_golden/).
//
// Ported from the public-domain G.722 decoder written by Steve Underwood (2005), which is
// based on the Carnegie Mellon University ADPCM program (1993, Chengxiang Lu and Alex
// Hauptmann). Both authors placed their work in the public domain; CMU asks only for
// acknowledgement, given here. Only the 64 kbit/s rate is implemented because that is
// the only one the RecDot uses.
import 'dart:typed_data';

/// Which linear sample rate the buds chose for a call or stored recording.
///
/// The bit stream is the same 64 kbit/s either way; the mode decides whether one code
/// byte carries two 16 kHz samples (wideband) or one 8 kHz sample (narrowband).
enum G722Mode {
  /// One byte of G.722 decodes to two samples at 16 kHz.
  wideband16k,

  /// One byte of G.722 decodes to one sample at 8 kHz; the high band is skipped.
  narrowband8k,
}

/// Decodes 64 kbit/s G.722 to signed 16-bit PCM, keeping the codec's adaptive state
/// between calls so a stream can be fed chunk by chunk.
class G722Decoder {
  /// Creates a decoder for [mode] in its initial state.
  G722Decoder(this.mode) {
    reset();
  }

  /// The sample-rate mode this decoder runs in.
  final G722Mode mode;

  /// The largest sample magnitude the reference produces for encoded silence.
  ///
  /// Sub-band ADPCM never settles to exact zero; the quantiser idles at a few LSB.
  static const int idleNoiseLimit = 4;

  static const int _sampleLimit = 16383;
  static const int _lowBandLogLimit = 18432;
  static const int _highBandLogLimit = 22528;
  static const int _qmfTapCount = 12;
  static const int _qmfHistoryLength = 24;

  final _G722Band _lowBand = _G722Band();
  final _G722Band _highBand = _G722Band();
  final Int32List _qmfHistory = Int32List(_qmfHistoryLength);

  /// Returns the decoder to the state it had before any byte was decoded.
  void reset() {
    _lowBand.reset(initialDet: 32);
    _highBand.reset(initialDet: 8);
    _qmfHistory.fillRange(0, _qmfHistoryLength, 0);
  }

  /// Decodes [g722Bytes] and returns the PCM samples they represent, continuing from
  /// wherever the previous call left off.
  Int16List decode(List<int> g722Bytes) {
    final samplesPerByte = mode == G722Mode.wideband16k ? 2 : 1;
    final output = Int16List(g722Bytes.length * samplesPerByte);
    var written = 0;
    for (final code in g722Bytes) {
      written = _decodeCode(code & 0xFF, output, written);
    }
    return output;
  }

  int _decodeCode(int code, Int16List output, int written) {
    final lowSample = _decodeLowBand(code & 0x3F);
    if (mode == G722Mode.narrowband8k) {
      output[written] = _saturate(lowSample << 1);
      return written + 1;
    }
    final highSample = _decodeHighBand((code >> 6) & 0x03);
    return _applyReceiveQmf(lowSample, highSample, output, written);
  }

  /// Blocks 5L, 6L, 2L, 3L and 4 of the specification for the low band.
  int _decodeLowBand(int sixBitCode) {
    final band = _lowBand;
    final reconstructed = _clampSample(band.s + ((band.det * _quantiser6[sixBitCode]) >> 15));
    final fourBitCode = sixBitCode >> 2;
    final difference = (band.det * _quantiser4[fourBitCode]) >> 15;
    band.nb = _clampLog(((band.nb * 127) >> 7) + _lowBandLogStep[_lowBandLogIndex[fourBitCode]], _lowBandLogLimit);
    band.det = _scaleFactor(band.nb, 8);
    band.update(difference);
    return reconstructed;
  }

  /// Blocks 2H, 5H, 6H, 3H and 4 of the specification for the high band.
  int _decodeHighBand(int twoBitCode) {
    final band = _highBand;
    final difference = (band.det * _quantiser2[twoBitCode]) >> 15;
    final reconstructed = _clampSample(difference + band.s);
    band.nb = _clampLog(((band.nb * 127) >> 7) + _highBandLogStep[_highBandLogIndex[twoBitCode]], _highBandLogLimit);
    band.det = _scaleFactor(band.nb, 10);
    band.update(difference);
    return reconstructed;
  }

  /// The receive quadrature-mirror filter that turns one low and one high band sample
  /// into two wideband output samples.
  int _applyReceiveQmf(int lowSample, int highSample, Int16List output, int written) {
    for (var i = 0; i < _qmfHistoryLength - 2; i++) {
      _qmfHistory[i] = _qmfHistory[i + 2];
    }
    _qmfHistory[_qmfHistoryLength - 2] = lowSample + highSample;
    _qmfHistory[_qmfHistoryLength - 1] = lowSample - highSample;
    var oddSum = 0;
    var evenSum = 0;
    for (var i = 0; i < _qmfTapCount; i++) {
      evenSum += _qmfHistory[2 * i] * _qmfCoefficients[i];
      oddSum += _qmfHistory[2 * i + 1] * _qmfCoefficients[_qmfTapCount - 1 - i];
    }
    output[written] = _saturate(oddSum >> 11);
    output[written + 1] = _saturate(evenSum >> 11);
    return written + 2;
  }

  static int _scaleFactor(int logValue, int shiftBase) {
    final tableIndex = (logValue >> 6) & 31;
    final shift = shiftBase - (logValue >> 11);
    final scaled = shift < 0 ? _inverseLog[tableIndex] << -shift : _inverseLog[tableIndex] >> shift;
    return scaled << 2;
  }

  static int _clampSample(int value) =>
      value > _sampleLimit ? _sampleLimit : (value < -_sampleLimit - 1 ? -_sampleLimit - 1 : value);

  static int _clampLog(int value, int limit) => value < 0 ? 0 : (value > limit ? limit : value);

  static const List<int> _lowBandLogStep = [-60, -30, 58, 172, 334, 538, 1198, 3042];
  static const List<int> _lowBandLogIndex = [0, 7, 6, 5, 4, 3, 2, 1, 7, 6, 5, 4, 3, 2, 1, 0];
  static const List<int> _highBandLogStep = [0, -214, 798];
  static const List<int> _highBandLogIndex = [2, 1, 2, 1];
  static const List<int> _quantiser2 = [-7408, -1616, 7408, 1616];
  static const List<int> _quantiser4 = [
    0, -20456, -12896, -8968, -6288, -4240, -2584, -1200, //
    20456, 12896, 8968, 6288, 4240, 2584, 1200, 0,
  ];
  static const List<int> _quantiser6 = [
    -136, -136, -136, -136, -24808, -21904, -19008, -16704, //
    -14984, -13512, -12280, -11192, -10232, -9360, -8576, -7856,
    -7192, -6576, -6000, -5456, -4944, -4464, -4008, -3576,
    -3168, -2776, -2400, -2032, -1688, -1360, -1040, -728,
    24808, 21904, 19008, 16704, 14984, 13512, 12280, 11192,
    10232, 9360, 8576, 7856, 7192, 6576, 6000, 5456,
    4944, 4464, 4008, 3576, 3168, 2776, 2400, 2032,
    1688, 1360, 1040, 728, 432, 136, -432, -136,
  ];
  static const List<int> _inverseLog = [
    2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383, //
    2435, 2489, 2543, 2599, 2656, 2714, 2774, 2834,
    2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371,
    3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008,
  ];
  static const List<int> _qmfCoefficients = [3, -11, 12, 32, -210, 951, 3876, -805, 362, -156, 53, -11];
}

/// Clamps a 32-bit intermediate to the signed 16-bit range, as the reference's
/// `saturate` does.
int _saturate(int value) => value > 32767 ? 32767 : (value < -32768 ? -32768 : value);

/// The adaptive predictor state of one sub-band ("block 4" of the specification).
class _G722Band {
  int s = 0;
  int sp = 0;
  int sz = 0;
  final Int32List r = Int32List(3);
  final Int32List a = Int32List(3);
  final Int32List ap = Int32List(3);
  final Int32List p = Int32List(3);
  final Int32List d = Int32List(7);
  final Int32List b = Int32List(7);
  final Int32List bp = Int32List(7);
  final Int32List sg = Int32List(7);
  int nb = 0;
  int det = 0;

  void reset({required int initialDet}) {
    s = sp = sz = nb = 0;
    for (final list in [r, a, ap, p, d, b, bp, sg]) {
      list.fillRange(0, list.length, 0);
    }
    det = initialDet;
  }

  /// Runs the predictor update for one decoded difference [difference].
  void update(int difference) {
    d[0] = difference;
    r[0] = _saturate(s + difference);
    p[0] = _saturate(sz + difference);
    _updateSecondPoleCoefficient();
    _updateFirstPoleCoefficient();
    _updateZeroCoefficients(difference);
    _shiftDelayLines();
    _predict();
  }

  void _updateSecondPoleCoefficient() {
    for (var i = 0; i < 3; i++) {
      sg[i] = p[i] >> 15;
    }
    final scaledFirst = _saturate(a[1] << 2);
    var wd2 = sg[0] == sg[1] ? -scaledFirst : scaledFirst;
    if (wd2 > 32767) wd2 = 32767;
    var wd3 = (wd2 >> 7) + (sg[0] == sg[2] ? 128 : -128);
    wd3 += (a[2] * 32512) >> 15;
    ap[2] = wd3 > 12288 ? 12288 : (wd3 < -12288 ? -12288 : wd3);
  }

  void _updateFirstPoleCoefficient() {
    sg[0] = p[0] >> 15;
    sg[1] = p[1] >> 15;
    final wd1 = sg[0] == sg[1] ? 192 : -192;
    final wd2 = (a[1] * 32640) >> 15;
    ap[1] = _saturate(wd1 + wd2);
    final limit = _saturate(15360 - ap[2]);
    if (ap[1] > limit) {
      ap[1] = limit;
    } else if (ap[1] < -limit) {
      ap[1] = -limit;
    }
  }

  void _updateZeroCoefficients(int difference) {
    final step = difference == 0 ? 0 : 128;
    sg[0] = difference >> 15;
    for (var i = 1; i < 7; i++) {
      sg[i] = d[i] >> 15;
      final wd2 = sg[i] == sg[0] ? step : -step;
      final wd3 = (b[i] * 32640) >> 15;
      bp[i] = _saturate(wd2 + wd3);
    }
  }

  void _shiftDelayLines() {
    for (var i = 6; i > 0; i--) {
      d[i] = d[i - 1];
      b[i] = bp[i];
    }
    for (var i = 2; i > 0; i--) {
      r[i] = r[i - 1];
      p[i] = p[i - 1];
      a[i] = ap[i];
    }
  }

  void _predict() {
    final poleOne = (a[1] * _saturate(r[1] + r[1])) >> 15;
    final poleTwo = (a[2] * _saturate(r[2] + r[2])) >> 15;
    sp = _saturate(poleOne + poleTwo);
    var zeroSum = 0;
    for (var i = 6; i > 0; i--) {
      zeroSum += (b[i] * _saturate(d[i] + d[i])) >> 15;
    }
    sz = _saturate(zeroSum);
    s = _saturate(sp + sz);
  }
}
