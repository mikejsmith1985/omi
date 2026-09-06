// Tests for the pure-Dart G.722 decoder against bit-exact reference vectors.
//
// The vectors in test/fixtures/g722_golden/ were produced by the ITU reference
// implementation (scripts/generate_g722_vectors.py in TranscriptBoss), not by this
// decoder, so a wrong port shows up as a failing comparison rather than a
// self-consistent mistake. Obligations G-1..G-4 come from
// specs/002-viaim-recdot-device/contracts/starot-codec.md.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/utils/audio/g722_decoder.dart';
import 'package:omi/utils/audio/narrowband_upsampler.dart';

Map<String, dynamic> loadFixture(String name) {
  final file = File('test/fixtures/g722_golden/$name.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

Uint8List hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Int16List pcmFromHex(String hex) {
  final bytes = hexBytes(hex);
  return Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 2);
}

void expectSamplesEqual(Int16List actual, Int16List expected, String label) {
  expect(actual.length, expected.length, reason: '$label: sample count');
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      fail('$label: sample $i is ${actual[i]}, reference says ${expected[i]}');
    }
  }
}

void main() {
  group('G-1 wideband 16 kHz mode is bit-exact', () {
    for (final entry in loadFixture('mode_16k')['cases'] as List) {
      final testCase = entry as Map<String, dynamic>;
      test(testCase['name'] as String, () {
        final decoder = G722Decoder(G722Mode.wideband16k);
        final actual = decoder.decode(hexBytes(testCase['input_hex'] as String));
        expectSamplesEqual(actual, pcmFromHex(testCase['expected']['pcm16_hex'] as String), testCase['name'] as String);
      });
    }
  });

  group('G-2 narrowband 8 kHz mode', () {
    for (final entry in loadFixture('mode_8k')['cases'] as List) {
      final testCase = entry as Map<String, dynamic>;
      test('${testCase['name']} is bit-exact at 8 kHz', () {
        final decoder = G722Decoder(G722Mode.narrowband8k);
        final actual = decoder.decode(hexBytes(testCase['input_hex'] as String));
        expectSamplesEqual(actual, pcmFromHex(testCase['expected']['pcm16_hex'] as String), testCase['name'] as String);
      });
    }

    test('upsampling doubles the sample count and keeps a 1 kHz tone within 1 dB', () {
      final tone = Int16List.fromList(List.generate(800, (n) => (8000 * sin(2 * pi * 1000 * n / 8000)).round()));
      final upsampled = NarrowbandUpsampler().upsample(tone);
      expect(upsampled.length, tone.length * 2);
      final inputRms = _rms(tone.sublist(100, 700));
      final outputRms = _rms(upsampled.sublist(200, 1400));
      final gainDb = 20 * log(outputRms / inputRms) / ln10;
      expect(gainDb.abs(), lessThan(1.0), reason: 'tone level changed by $gainDb dB');
    });
  });

  group('G-3 decoder state', () {
    test('decoding 40-byte chunks with one instance equals decoding the whole stream', () {
      final fixture = loadFixture('chunked');
      final input = hexBytes(fixture['input_hex'] as String);
      final chunkBytes = fixture['chunk_bytes'] as int;
      final decoder = G722Decoder(G722Mode.wideband16k);
      final pieces = <int>[];
      for (var start = 0; start < input.length; start += chunkBytes) {
        pieces.addAll(decoder.decode(input.sublist(start, start + chunkBytes)));
      }
      expectSamplesEqual(Int16List.fromList(pieces), pcmFromHex(fixture['expected']['pcm16_hex'] as String), 'chunked');
    });

    test('reset restores the initial state', () {
      final fixture = loadFixture('chunked');
      final input = hexBytes(fixture['input_hex'] as String);
      final chunkBytes = fixture['chunk_bytes'] as int;
      final expected = pcmFromHex(fixture['expected']['pcm16_hex'] as String);
      final decoder = G722Decoder(G722Mode.wideband16k);
      decoder.decode(input);
      decoder.reset();
      final firstChunkAgain = decoder.decode(input.sublist(0, chunkBytes));
      expectSamplesEqual(firstChunkAgain, expected.sublist(0, chunkBytes * 2), 'after reset');
    });
  });

  group('G-4 sanity', () {
    test('silence decodes to at most the codec idle noise', () {
      final cases = (loadFixture('mode_16k')['cases'] as List).cast<Map<String, dynamic>>();
      final silence = cases.firstWhere((c) => c['name'] == 'silence');
      final pcm = G722Decoder(G722Mode.wideband16k).decode(hexBytes(silence['input_hex'] as String));
      expect(pcm.map((s) => s.abs()).reduce(max), lessThanOrEqualTo(G722Decoder.idleNoiseLimit));
    });
  });
}

double _rms(List<int> samples) {
  var sum = 0.0;
  for (final sample in samples) {
    sum += sample * sample;
  }
  return sqrt(sum / samples.length);
}
