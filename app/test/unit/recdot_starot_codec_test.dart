// Tests for the RecDot STAROT v2 codec against golden vectors from the Python reference.
//
// Every expectation here is loaded from test/fixtures/recdot_golden/*.json, which
// scripts/generate_recdot_vectors.py (TranscriptBoss) derives from an independent
// implementation. Nothing is re-derived from the Dart code under test, so a shared
// misunderstanding of the wire format cannot pass. Obligations C-1..C-8 come from
// specs/002-viaim-recdot-device/contracts/starot-codec.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/recdot/starot_codec.dart';

Map<String, dynamic> loadFixture(String name) {
  final file = File('test/fixtures/recdot_golden/$name.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<Map<String, dynamic>> casesOf(String name) => (loadFixture(name)['cases'] as List).cast<Map<String, dynamic>>();

Uint8List hexBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('C-1 framing', () {
    for (final testCase in casesOf('framing')) {
      final expected = testCase['expected'] as Map<String, dynamic>;
      if (expected.containsKey('error')) {
        test('${testCase['name']} is refused', () {
          expect(
            () => StarotCodec.encodeFrame(0x5007, Uint8List(testCase['payload_len'] as int)),
            throwsA(isA<StarotCodecException>()),
          );
        });
        continue;
      }
      test('${testCase['name']} encodes to the documented bytes', () {
        final encoded =
            StarotCodec.encodeFrame(expected['command'] as int, hexBytes(expected['payload_hex'] as String));
        expect(toHex(encoded), testCase['input_hex']);
        expect(encoded.length, expected['total_length']);
      });
      test('${testCase['name']} decodes back', () {
        final frames = StarotFramer().feed(hexBytes(testCase['input_hex'] as String));
        expect(frames, hasLength(1));
        expect(frames.single.command, expected['command']);
        expect(toHex(frames.single.payload), expected['payload_hex']);
      });
    }
  });

  group('C-2 framer reassembly', () {
    final fixture = loadFixture('framer_splits');
    final stream = hexBytes(fixture['stream_hex'] as String);
    final expectedFrames = (fixture['expected_frames'] as List).cast<Map<String, dynamic>>();

    void expectFrames(List<StarotFrame> frames) {
      expect(frames, hasLength(expectedFrames.length));
      for (var i = 0; i < frames.length; i++) {
        expect(frames[i].command, expectedFrames[i]['command'], reason: 'frame $i command');
        expect(toHex(frames[i].payload), expectedFrames[i]['payload_hex'], reason: 'frame $i payload');
      }
    }

    test('all at once', () => expectFrames(StarotFramer().feed(stream)));

    test('one byte at a time', () {
      final framer = StarotFramer();
      final frames = <StarotFrame>[];
      for (final byte in stream) {
        frames.addAll(framer.feed([byte]));
      }
      expectFrames(frames);
    });

    test('in seven-byte chunks', () {
      final framer = StarotFramer();
      final frames = <StarotFrame>[];
      for (var start = 0; start < stream.length; start += 7) {
        frames.addAll(framer.feed(stream.sublist(start, (start + 7).clamp(0, stream.length))));
      }
      expectFrames(frames);
    });

    test('resynchronises after a garbage prefix', () {
      final garbage = hexBytes(fixture['garbage_prefix_hex'] as String);
      expectFrames(StarotFramer().feed([...garbage, ...stream]));
    });

    test('never yields a partial frame', () {
      final framer = StarotFramer();
      expect(framer.feed(stream.sublist(0, 5)), isEmpty);
      expect(framer.feed(stream.sublist(5)), hasLength(expectedFrames.length));
    });
  });

  group('C-3 acknowledgements', () {
    for (final testCase in casesOf('ack')) {
      final expected = testCase['expected'] as Map<String, dynamic>;
      test(testCase['name'] as String, () {
        final frame = StarotFramer().feed(hexBytes(testCase['input_hex'] as String)).single;
        expect(frame.isAck, expected['is_ack']);
        expect(frame.opcode, expected['opcode']);
        expect(frame.ackStatus, expected['status']);
        expect(toHex(frame.ackData), expected['data_hex']);
      });
    }
  });

  group('C-4 TLV attribute groups', () {
    for (final testCase in casesOf('tlv')) {
      final expected = testCase['expected'] as Map<String, dynamic>;
      if (expected.containsKey('error')) {
        test('${testCase['name']} is refused', () {
          expect(() => StarotCodec.decodeTlvGroup(hexBytes(testCase['input_hex'] as String)),
              throwsA(isA<StarotCodecException>()));
        });
        continue;
      }
      final attributes = (expected['attributes'] as List)
          .cast<Map<String, dynamic>>()
          .map((a) => TlvAttribute(a['attribute'] as int, hexBytes(a['value_hex'] as String)))
          .toList();
      test('${testCase['name']} encodes', () {
        expect(toHex(StarotCodec.encodeTlvGroup(attributes)), testCase['input_hex']);
      });
      test('${testCase['name']} decodes', () {
        final decoded = StarotCodec.decodeTlvGroup(hexBytes(testCase['input_hex'] as String));
        expect(decoded.map((a) => a.attribute).toList(), attributes.map((a) => a.attribute).toList());
        expect(decoded.map((a) => toHex(a.value)).toList(), attributes.map((a) => toHex(a.value)).toList());
      });
    }
  });

  group('C-5 call audio split', () {
    for (final testCase in casesOf('call_audio')) {
      final expected = testCase['expected'] as Map<String, dynamic>;
      if (expected.containsKey('error')) {
        test('${testCase['name']} is refused', () {
          expect(() => StarotCodec.splitCallAudio(hexBytes(testCase['input_hex'] as String)),
              throwsA(isA<StarotCodecException>()));
        });
        continue;
      }
      test(testCase['name'] as String, () {
        final packet = StarotCodec.splitCallAudio(hexBytes(testCase['input_hex'] as String));
        expect(toHex(packet.speaker), expected['speaker_hex']);
        expect(toHex(packet.mic), expected['mic_hex']);
      });
    }
  });

  group('C-6 flash chunks', () {
    for (final testCase in casesOf('flash_chunk')) {
      final expected = testCase['expected'] as Map<String, dynamic>;
      if (expected.containsKey('error')) {
        test('${testCase['name']} is refused', () {
          expect(() => StarotCodec.parseFlashChunk(hexBytes(testCase['input_hex'] as String)),
              throwsA(isA<StarotCodecException>()));
        });
        continue;
      }
      test(testCase['name'] as String, () {
        final chunk = StarotCodec.parseFlashChunk(hexBytes(testCase['input_hex'] as String));
        expect(chunk.offset, expected['offset']);
        expect(toHex(chunk.speaker), expected['speaker_hex']);
        expect(toHex(chunk.mic), expected['mic_hex']);
        expect(chunk.isEndOfFile, expected['is_end_of_file']);
      });
    }
  });

  group('C-7 download requests', () {
    for (final testCase in casesOf('get_record')) {
      final input = testCase['input'] as Map<String, dynamic>;
      final expectedHex = (testCase['expected'] as Map<String, dynamic>)['payload_hex'];
      test(testCase['name'] as String, () {
        final payload = input['cancel'] == true
            ? StarotCodec.encodeGetRecordCancel()
            : StarotCodec.encodeGetRecord(
                side: input['side'] as int,
                index: input['index'] as int,
                offset: input['offset'] as int,
                length: input['length'] as int,
                password: input['password'] as String?,
              );
        expect(toHex(payload), expectedHex);
      });
    }
  });

  group('C-8 advertisement', () {
    for (final testCase in casesOf('advertisement')) {
      final expected = testCase['expected'] as Map<String, dynamic>;
      if (expected.containsKey('error')) {
        test('${testCase['name']} is refused', () {
          expect(() => StarotCodec.decodeAdvertisement(hexBytes(testCase['input_hex'] as String)),
              throwsA(isA<StarotCodecException>()));
        });
        continue;
      }
      test(testCase['name'] as String, () {
        final advert = StarotCodec.decodeAdvertisement(hexBytes(testCase['input_hex'] as String));
        expect(advert.productId, expected['product_id']);
        expect(advert.leftBatteryPercent, expected['left_battery_percent']);
        expect(advert.isLeftCharging, expected['is_left_charging']);
        expect(advert.rightBatteryPercent, expected['right_battery_percent']);
        expect(advert.isRightCharging, expected['is_right_charging']);
        expect(advert.caseBatteryPercent, expected['case_battery_percent']);
        expect(advert.isCaseCharging, expected['is_case_charging']);
        expect(advert.leftMac, expected['left_mac']);
        expect(advert.rightMac, expected['right_mac']);
        expect(advert.feature, expected['feature']);
      });
    }
  });
}
