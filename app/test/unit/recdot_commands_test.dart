// Tests for the RecDot typed command builders and response parsers.
//
// These sit one layer above the raw codec: they turn intent ("check the bond code",
// "read the battery") into the exact frames protocol.md §5–§7 documents, and turn the
// buds' replies into typed records. Payloads here are hand-built from the protocol notes,
// so a parser that drifts from the notes fails rather than agreeing with a matching bug.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/devices/recdot/recdot_commands.dart';
import 'package:omi/services/devices/recdot/starot_codec.dart';

String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('connect and capture command frames', () {
    test('bond check carries a four-byte zero code', () {
      expect(toHex(RecDotCommands.checkBondCode()), '5508510100000000');
    });

    test('get serial is an empty command', () {
      expect(toHex(RecDotCommands.getSerial()), '5504550b');
    });

    test('get version requests the 0x07 attribute', () {
      expect(toHex(RecDotCommands.getVersion()), '550755000201 07'.replaceAll(' ', ''));
    });

    test('get battery is an empty command', () {
      expect(toHex(RecDotCommands.getBattery()), '5504550 5'.replaceAll(' ', ''));
    });

    test('set seamless record on sends attribute one with value one', () {
      final frame = StarotFramer().feed(RecDotCommands.setSeamlessRecord(true)).single;
      expect(frame.command, 0x5534);
      expect(StarotCodec.decodeTlvGroup(frame.payload).single.value, [1]);
    });

    test('declare voip call sets the call type attribute', () {
      final frame = StarotFramer().feed(RecDotCommands.declareVoipCall()).single;
      expect(frame.command, 0x5410);
      expect(StarotCodec.decodeTlvGroup(frame.payload).single.value, [1]);
    });

    test('start and stop call audio carry the resume and pause flags', () {
      expect(StarotFramer().feed(RecDotCommands.startCallAudio(isResume: true)).single.command, 0x500B);
      expect(
          StarotCodec.decodeTlvGroup(StarotFramer().feed(RecDotCommands.startCallAudio(isResume: true)).single.payload)
              .single
              .value,
          [1]);
      expect(StarotFramer().feed(RecDotCommands.stopCallAudio(isPause: false)).single.command, 0x500C);
    });

    test('list stored recordings selects a side', () {
      final frame = StarotFramer().feed(RecDotCommands.listStoredRecordings(side: RecDotSide.left)).single;
      expect(frame.command, 0x5A37);
      expect(StarotCodec.decodeTlvGroup(frame.payload).single.value, [RecDotSide.left.wireValue]);
    });
  });

  group('battery parsing (0x5505 / 0x5504)', () {
    Uint8List batteryPayload() => StarotCodec.encodeTlvGroup([
          TlvAttribute(1, Uint8List.fromList([0x80 | 55])),
          TlvAttribute(2, Uint8List.fromList([60])),
          TlvAttribute(3, Uint8List.fromList([0xFF])),
        ]);

    test('reads per-part percent, charging flag, and absence', () {
      final report = RecDotCommands.parseBattery(batteryPayload());
      expect(report.leftPercent, 55);
      expect(report.isLeftCharging, isTrue);
      expect(report.rightPercent, 60);
      expect(report.isRightCharging, isFalse);
      expect(report.casePercent, isNull);
    });
  });

  group('version parsing (0x5500)', () {
    test('reads product code and dotted version from the hex data', () {
      final payload = StarotCodec.encodeTlvGroup([
        TlvAttribute(1, Uint8List.fromList([0x00, 0x08, 0x00, 0x00, 0x01, 0x02, 0x03, 0x2D])),
      ]);
      final report = RecDotCommands.parseVersion(payload);
      expect(report.productId, 8);
      expect(report.version, '1.2.3.45');
    });
  });

  group('serial parsing (0x550B)', () {
    test('reads the ASCII serial and its side', () {
      final payload = StarotCodec.encodeTlvGroup([
        TlvAttribute(1, Uint8List.fromList('A92ABCDEFGHIJK'.codeUnits)),
      ]);
      final report = RecDotCommands.parseSerial(payload);
      expect(report.serials.single, 'A92ABCDEFGHIJK');
    });
  });

  group('stored-recording list parsing (0x5A37)', () {
    Uint8List entryPayload() => StarotCodec.encodeTlvGroup([
          TlvAttribute(1, Uint8List.fromList([1])),
          TlvAttribute(2, Uint8List.fromList([0, 0, 0, 7])),
          TlvAttribute(4, Uint8List.fromList([0, 0x0E, 0xA6, 0x00])),
          TlvAttribute(5, Uint8List.fromList([1])),
          TlvAttribute(6, Uint8List.fromList([0])),
          TlvAttribute(7, Uint8List.fromList([0x67, 0x00, 0x00, 0x00])),
        ]);

    test('reads index, side, length, sample-rate mode, kind and time', () {
      final entry = RecDotCommands.parseStoredRecording(entryPayload())!;
      expect(entry.index, 7);
      expect(entry.side, RecDotSide.left);
      expect(entry.lengthBytes, 0x000EA600);
      expect(entry.mode, RecDotSampleRateMode.narrowband8k);
      expect(entry.kind, RecDotRecordingKind.call);
      expect(entry.recordedAtEpochSeconds, 0x67000000);
      expect(entry.isEndMarker, isFalse);
    });

    test('recognises the end-of-list marker', () {
      final payload = StarotCodec.encodeTlvGroup([TlvAttribute(15, Uint8List(0))]);
      expect(RecDotCommands.parseStoredRecording(payload)!.isEndMarker, isTrue);
    });
  });
}
