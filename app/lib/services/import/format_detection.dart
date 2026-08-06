/// Purpose: work out what a chosen file actually is, before spending an hour on it.
///
/// The extension is a claim, not evidence. A `.wav` that arrived through a messaging
/// app is very often an `.m4a` that was renamed, and handing the wrong container to a
/// decoder produces either silence or noise — not an error. So the format comes from
/// the bytes at the front of the file, which is the one thing that cannot be renamed.
///
/// FR-002 and FR-003 also require that a refusal *names* the format found and the ones
/// that work, so the user can convert the file rather than guess what went wrong.
library;

import 'dart:io';
import 'dart:typed_data';

/// A container this feature can decode.
///
/// Deliberately a closed set. Both platforms can decode more than this, but promising
/// a format nobody has tested is how you get a bug report about `.amr` from a car kit.
enum AudioContainer {
  /// Uncompressed PCM in a RIFF wrapper. What voice recorders export when asked to.
  wav('WAV'),

  /// MPEG audio. Still the default on a lot of hardware.
  mp3('MP3'),

  /// AAC in an MPEG-4 container — what most phones and earbuds actually produce.
  m4a('M4A'),

  /// Raw AAC in an ADTS stream.
  aac('AAC'),

  /// Free Lossless Audio Codec.
  flac('FLAC'),

  /// Ogg, usually carrying Vorbis or Opus.
  ///
  /// **Android only.** Core Audio has no Ogg or Vorbis decoder, so an iPhone cannot
  /// read these however valid the file is. See [isDecodableOnThisDevice].
  ogg('OGG', isDecodableOnIos: false);

  const AudioContainer(this.displayName, {this.isDecodableOnIos = true});

  /// What to call this format when talking to a person.
  final String displayName;

  /// Whether iOS can decode this container at all.
  ///
  /// The two platforms genuinely differ here, and pretending otherwise would break
  /// FR-003: accepting a file and then failing on it is exactly the "discovered after
  /// a long wait" outcome that requirement exists to prevent.
  final bool isDecodableOnIos;

  /// Whether the phone this is running on can decode this container.
  bool get isDecodableOnThisDevice => !Platform.isIOS || isDecodableOnIos;
}

/// How many bytes to read to identify a file.
///
/// Enough to cover an ID3v2 tag of reasonable size before the MPEG sync word, which is
/// the only signature that does not sit at a fixed offset.
const int formatSniffLengthBytes = 4096;

/// What the file turned out to be, or why it could not be identified.
class FormatDetectionResult {
  /// The container, when recognised.
  final AudioContainer? container;

  /// A short description of what was found instead, when it was not recognised.
  ///
  /// Used to build the message FR-002 requires — "this looks like a video file",
  /// not "unsupported".
  final String? unrecognisedDescription;

  /// Creates a successful detection.
  const FormatDetectionResult.recognised(AudioContainer this.container) : unrecognisedDescription = null;

  /// Creates a failed detection, describing what was found.
  const FormatDetectionResult.unrecognised(String this.unrecognisedDescription) : container = null;

  /// Whether the file can be decoded on the phone this is running on.
  ///
  /// Deliberately platform-aware rather than a simple "did we recognise it". A file
  /// this build cannot decode is not supported here, however well another build would
  /// cope with it.
  bool get isSupported => container?.isDecodableOnThisDevice ?? false;

  /// Whether the format was recognised but cannot be decoded on this platform.
  ///
  /// Worth distinguishing because the user's next step differs: an unrecognised file
  /// may be damaged, whereas this one is fine and simply needs converting.
  bool get isRecognisedButUnsupportedHere => container != null && !container!.isDecodableOnThisDevice;
}

/// Identifies a file from its leading bytes.
///
/// Reads only [formatSniffLengthBytes] regardless of how large the recording is, so
/// identifying an hour of audio costs the same as identifying a second of it.
Future<FormatDetectionResult> detectAudioFormat(File file) async {
  final length = await file.length();
  if (length == 0) {
    return const FormatDetectionResult.unrecognised('an empty file');
  }

  final handle = await file.open();
  try {
    final header = await handle.read(formatSniffLengthBytes);
    return identifyAudioContainer(header);
  } finally {
    await handle.close();
  }
}

/// Identifies a container from the bytes at the start of a file.
///
/// Separated from the file reading so it can be tested exhaustively without touching
/// a filesystem — which is what keeps the unit tests hermetic, as `test/` requires.
FormatDetectionResult identifyAudioContainer(Uint8List header) {
  if (header.length < 12) {
    return const FormatDetectionResult.unrecognised('a file too short to identify');
  }

  if (_matchesAscii(header, 0, 'RIFF') && _matchesAscii(header, 8, 'WAVE')) {
    return const FormatDetectionResult.recognised(AudioContainer.wav);
  }
  if (_matchesAscii(header, 0, 'fLaC')) {
    return const FormatDetectionResult.recognised(AudioContainer.flac);
  }
  if (_matchesAscii(header, 0, 'OggS')) {
    return const FormatDetectionResult.recognised(AudioContainer.ogg);
  }
  if (_matchesAscii(header, 4, 'ftyp')) {
    return _identifyIsoBaseMedia(header);
  }
  if (_isMpegAudio(header)) {
    return const FormatDetectionResult.recognised(AudioContainer.mp3);
  }
  if (_isAdtsAac(header)) {
    return const FormatDetectionResult.recognised(AudioContainer.aac);
  }
  return const FormatDetectionResult.unrecognised('a format we do not recognise');
}

/// Distinguishes audio from video inside an MPEG-4 container.
///
/// `.m4a` and `.mp4` share a header, so the brand is the only thing separating a
/// recording from a film. Naming video specifically matters because picking a video by
/// mistake is a thing people actually do, and "unsupported format" would not help them.
FormatDetectionResult _identifyIsoBaseMedia(Uint8List header) {
  final brand = String.fromCharCodes(header.sublist(8, 12));
  const audioBrands = {'M4A ', 'M4B ', 'mp42', 'isom', 'iso2'};
  const videoBrands = {'qt  ', 'M4V ', 'avc1'};

  if (videoBrands.contains(brand)) {
    return const FormatDetectionResult.unrecognised('a video file');
  }
  if (audioBrands.contains(brand)) {
    return const FormatDetectionResult.recognised(AudioContainer.m4a);
  }
  // An unfamiliar brand in an MPEG-4 container is more likely audio than not, and the
  // decoder will reject it clearly enough if it is not.
  return const FormatDetectionResult.recognised(AudioContainer.m4a);
}

/// Whether the bytes are MPEG audio, allowing for a leading ID3 tag.
bool _isMpegAudio(Uint8List header) {
  var offset = 0;
  if (_matchesAscii(header, 0, 'ID3')) {
    offset = _id3TagLength(header);
    if (offset <= 0 || offset + 1 >= header.length) {
      // The tag runs past what we read. A valid ID3 header is itself good evidence.
      return true;
    }
  }
  return _hasMpegSyncWord(header, offset);
}

/// The total length of an ID3v2 tag, from its syncsafe size field.
int _id3TagLength(Uint8List header) {
  if (header.length < 10) return -1;
  final size = (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
  return size + 10;
}

/// Whether an MPEG frame header starts at [offset].
bool _hasMpegSyncWord(Uint8List header, int offset) {
  if (offset + 1 >= header.length) return false;
  final isSync = header[offset] == 0xFF && (header[offset + 1] & 0xE0) == 0xE0;
  if (!isSync) return false;
  // Layer 0 is reserved; a "sync word" with it is a coincidence, not a frame.
  return (header[offset + 1] & 0x06) != 0x00;
}

/// Whether the bytes are a raw AAC stream in ADTS framing.
bool _isAdtsAac(Uint8List header) {
  if (header.length < 2) return false;
  return header[0] == 0xFF && (header[1] & 0xF6) == 0xF0;
}

/// Whether [text] appears at [offset] in [bytes].
bool _matchesAscii(Uint8List bytes, int offset, String text) {
  if (offset + text.length > bytes.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[offset + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}

/// The formats a refusal should list, in a form fit to show a person.
///
/// Filtered to what this phone can actually decode. Listing OGG to an iPhone user as
/// something to convert *to* would send them down a road that ends in the same refusal.
String describeSupportedFormats() => AudioContainer.values
    .where((format) => format.isDecodableOnThisDevice)
    .map((format) => format.displayName)
    .join(', ');
