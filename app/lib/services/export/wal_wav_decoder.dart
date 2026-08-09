/// Purpose: the seam between bulk export and whatever actually turns a recording's
/// stored frames into a playable WAV file.
///
/// Bulk export's job is deciding what to export, in what order, and what to do when
/// one recording fails. Decoding Opus or PCM frames is a separate job that the app
/// already does well. Keeping them apart means the export rules can be tested
/// without an audio codec, a temp directory, or a real file — which is what lets the
/// batch behaviour be covered by fast unit tests rather than only on a device.
library;

import 'package:omi/services/wals.dart';

/// Turns a single recording into a playable WAV file on disk.
abstract class WalWavDecoder {
  /// Whether this recording's audio is actually present and can be decoded.
  ///
  /// Checked before decoding so a recording whose audio is already gone is
  /// reported as skipped rather than as a decoder failure — the user can act on
  /// the first and can do nothing about the second.
  bool canDecode(Wal recording);

  /// Decodes [recording] and returns the path of the WAV file written for it.
  ///
  /// Returns null when the recording held no usable audio frames.
  Future<String?> decodeToWav(Wal recording);
}
