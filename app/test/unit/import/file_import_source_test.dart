/// Purpose: what is specific to the file source, beyond the shared AudioSource contract.
///
/// The frame behaviour every source must have is checked in
/// `audio_source_contract_test.dart`, which runs the same suite against both this and
/// `PhoneMicSource`. What is left here is what only a file source has: identity that
/// marks a conversation as imported, and the buffered-byte count the pump reads to
/// decide whether a flush is still owed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/audio_sources/file_import_source.dart';
import 'package:omi/services/audio_sources/phone_mic_source.dart';

/// O-5 and FR-013: the conversation must be identifiable as an import.
void _identityMarksTheImport() {
  group('identity marks the conversation as imported (O-5, FR-013)', () {
    test('the device model says the recording was imported', () {
      final source = FileImportSource(importId: 'abc');

      expect(source.deviceModel, FileImportSource.importDeviceModel);
      // The point of the requirement: it must not be mistakable for live capture.
      expect(source.deviceModel, isNot(PhoneMicSource().deviceModel));
    });

    test('the device id distinguishes one import from another', () {
      final first = FileImportSource(importId: 'recording-one');
      final second = FileImportSource(importId: 'recording-two');

      expect(first.deviceId, isNot(second.deviceId));
      expect(first.deviceId, contains('recording-one'));
    });

    test('the device id is stable for one import', () {
      final source = FileImportSource(importId: 'stable');

      expect(source.deviceId, source.deviceId);
    });
  });

}

/// The frame size must not drift from the one the pipeline pins.
void _frameSizeMatchesPipeline() {
  group('frame size matches the pipeline', () {
    test('is 320 bytes, the same as the phone microphone', () {
      // Stated in both places deliberately, so a divergence is a failing test rather
      // than a silent inheritance. 320 bytes is 10 ms at 16 kHz 16-bit mono.
      expect(FileImportSource.frameSize, 320);
      expect(FileImportSource.frameSize, PhoneMicSource.frameSize);
    });
  });

}

/// The pump reads this to know whether a flush is still owed.
void _bufferedCountIsAccurate() {
  group('buffered byte count tells the pump whether a flush is owed', () {
    test('is zero for an untouched source', () {
      expect(FileImportSource(importId: 'x').bufferedByteCount, 0);
    });

    test('reports the partial frame still waiting', () {
      final source = FileImportSource(importId: 'x');

      source.processBytes(List.filled(FileImportSource.frameSize + 45, 0x01));

      expect(source.bufferedByteCount, 45);
    });

    test('is zero after an exact frame boundary', () {
      final source = FileImportSource(importId: 'x');

      source.processBytes(List.filled(FileImportSource.frameSize * 2, 0x02));

      expect(source.bufferedByteCount, 0);
    });

    test('is zero once flushed', () {
      final source = FileImportSource(importId: 'x');
      source.processBytes(List.filled(50, 0x03));

      source.flush();

      expect(source.bufferedByteCount, 0);
    });
  });

}

/// A retained remainder shows here long before it shows as a memory failure.
void _longRecordingsDoNotAccumulate() {
  group('long recordings do not accumulate', () {
    test('the buffer never grows beyond one frame across many chunks', () {
      final source = FileImportSource(importId: 'long');

      // Roughly a minute of audio in decoder-sized pieces, which is the shape the pump
      // will actually feed. A retained remainder would show as unbounded growth here
      // long before it showed as a memory failure on a device.
      for (var i = 0; i < 600; i++) {
        source.processBytes(List.filled(1600, i % 256));
        expect(source.bufferedByteCount, lessThan(FileImportSource.frameSize));
      }
    });

    test('sync keys wrap rather than growing without bound', () {
      final source = FileImportSource(importId: 'wrap');

      final frames = source.processBytes(List.filled(FileImportSource.frameSize * 257, 0x04));

      expect(frames.length, 257);
      expect(frames[0].syncKey.bytes, [0]);
      expect(frames[255].syncKey.bytes, [255]);
      expect(frames[256].syncKey.bytes, [0]);
    });
  });
}

void main() {
  _identityMarksTheImport();
  _frameSizeMatchesPipeline();
  _bufferedCountIsAccurate();
  _longRecordingsDoNotAccumulate();
}
