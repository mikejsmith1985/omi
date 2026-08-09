/// Purpose: let bulk export reuse the decoder the app already ships, rather than
/// growing a second one.
///
/// `AudioPlayerUtils` has decoded recordings to WAV for playback and single-recording
/// sharing since long before this feature existed, including the Opus and raw-PCM
/// cases and the WAV header. Bulk export needs exactly that and nothing more, so this
/// is a thin adapter onto it — the alternative, a parallel decode path, would be a
/// second thing to keep correct for no gain.
library;

import 'package:omi/services/export/wal_wav_decoder.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/audio_player_utils.dart';

/// Decodes recordings for bulk export using the app's existing audio decoder.
class AudioPlayerWavDecoder implements WalWavDecoder {
  /// Creates a decoder backed by [audioPlayerUtils].
  const AudioPlayerWavDecoder(this._audioPlayerUtils);

  final AudioPlayerUtils _audioPlayerUtils;

  @override
  bool canDecode(Wal recording) => _audioPlayerUtils.canPlayOrShare(recording);

  @override
  Future<String?> decodeToWav(Wal recording) => _audioPlayerUtils.createWavFileForExport(recording);
}
