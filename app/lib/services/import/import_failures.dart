/// Purpose: every way an import can fail, written as something a person can act on.
///
/// FR-018 says a failure is what happened plus what to do, never a code alone. Keeping
/// them all in one file is what makes that checkable: the list below is the complete
/// set, so a new failure path has an obvious place to go and an obvious standard to
/// meet, rather than growing an inline `throw Exception('decode failed')` somewhere.
///
/// **Localisation**: the English text here is the source form. T042 moves these strings
/// to `lib/l10n/app_en.arb` and resolves them through `context.l10n`, as Omi requires of
/// every user-facing string. The [ImportFailure.code] on each is what the ARB key is
/// derived from, so that move is mechanical rather than a rewrite.
library;

import 'package:omi/services/import/format_detection.dart';
import 'package:omi/services/import/import_job.dart';

/// The failure code meaning "already imported" rather than "went wrong".
///
/// Named here, where the failure is created, so the queue can recognise it without the
/// two files having to import each other.
const String duplicateRecordingCode = 'already_imported';

/// The file could not be opened at all.
ImportFailure unreadableRecording(String fileName) => ImportFailure(
      whatHappened: 'We could not open $fileName.',
      whatToDo: 'Check the file plays in another app. If it does not, it is damaged and '
          'will need exporting again from wherever it came from.',
      code: 'recording_unreadable',
    );

/// The file is in a format the platform decoder cannot read.
///
/// Names the format found as well as the ones that work, so the user can convert the
/// file rather than guess what went wrong (FR-002).
ImportFailure undecodableRecording(String? foundDescription, String? reason) {
  final found = foundDescription ?? reason ?? 'a format we do not recognise';
  return ImportFailure(
    whatHappened: 'This looks like $found, which cannot be transcribed.',
    whatToDo: 'Convert it to one of these first: ${describeSupportedFormats()}.',
    code: 'format_unsupported',
  );
}

/// The format is valid but this phone has no decoder for it.
///
/// Distinct from [undecodableRecording] because the file is not the problem — an
/// iPhone simply has no Ogg decoder, and telling the user their recording is broken
/// when it plays perfectly well elsewhere would be both wrong and infuriating.
ImportFailure formatNotSupportedOnThisDevice(AudioContainer container) => ImportFailure(
      whatHappened: 'This phone cannot read ${container.displayName} files.',
      whatToDo: 'The recording is fine — it just needs converting to one of these first: '
          '${describeSupportedFormats()}.',
      code: 'format_unsupported_on_platform',
    );

/// The file contains no audio track — commonly a video with its audio stripped.
ImportFailure noAudioTrack(String fileName) => ImportFailure(
      whatHappened: '$fileName has no sound in it.',
      whatToDo: 'Check you picked the right file — this one contains no audio track.',
      code: 'no_audio_track',
    );

/// This recording has already been imported.
///
/// Not really a failure, and worded so it does not read as one — the user has what
/// they wanted, they just asked for it twice. Naming the existing conversation matters
/// more than the refusal does (FR-004).
ImportFailure alreadyImportedRecording(String previousName) => ImportFailure(
      whatHappened: 'This recording has already been imported.',
      whatToDo: previousName.isEmpty
          ? 'Its conversation is already in your list.'
          : 'It is already in your conversations as "$previousName".',
      code: duplicateRecordingCode,
    );

/// The recording has no length.
ImportFailure emptyRecording() => const ImportFailure(
      whatHappened: 'This recording is empty.',
      whatToDo: 'Pick a different file — there is nothing in this one to transcribe.',
      code: 'recording_empty',
    );

/// The recording decoded fine but contains no recognisable speech.
///
/// Distinct from [emptyRecording] because the user's next step differs: this file has
/// audio in it, so the useful advice is about what kind of audio (FR-011).
ImportFailure noSpeechFound() => const ImportFailure(
      whatHappened: 'We could not find any speech in this recording.',
      whatToDo: 'If it should contain talking, the audio may be too quiet or too noisy '
          'to transcribe. Try a recording made closer to the speaker.',
      code: 'no_speech_found',
    );

/// The platform decoder failed to start.
ImportFailure decoderUnavailable() => const ImportFailure(
      whatHappened: 'The phone could not start decoding this recording.',
      whatToDo: 'Close other apps that may be playing or recording audio, then try again.',
      code: 'decoder_init_failed',
      isRetryable: true,
    );

/// The import stopped part-way and left nothing behind.
///
/// Deliberately says no conversation was created. A user who is not told that will go
/// looking for a partial one (FR-019).
ImportFailure importInterrupted(String fileName) => ImportFailure(
      whatHappened: 'The import of $fileName did not finish.',
      whatToDo: 'No conversation was created. Start the import again when you are ready.',
      code: 'import_interrupted',
      isRetryable: true,
    );

/// The device ran short of memory during a long import.
ImportFailure ranOutOfMemory() => const ImportFailure(
      whatHappened: 'The phone ran short of memory part-way through this import.',
      whatToDo: 'Close some other apps and start the import again. Nothing was saved.',
      code: 'out_of_memory',
      isRetryable: true,
    );

/// There is not enough free storage to decode the recording.
///
/// States the amount, because "free up some space" without a figure leaves the user
/// guessing whether deleting one photo will do.
ImportFailure notEnoughStorage({required int requiredBytes}) {
  final requiredMegabytes = (requiredBytes / (1024 * 1024)).ceil();
  return ImportFailure(
    whatHappened: 'There is not enough free space to work on this recording.',
    whatToDo: 'About $requiredMegabytes MB is needed while it is being transcribed. '
        'Free up some space and try again.',
    code: 'insufficient_storage',
    isRetryable: true,
  );
}

/// An import was attempted while Omi was recording live.
///
/// Live capture wins, always — a background job must never degrade the conversation
/// the user is actually having (FR-021).
ImportFailure liveRecordingInProgress() => const ImportFailure(
      whatHappened: 'Omi is recording right now, so the import has not started.',
      whatToDo: 'It will begin on its own once the recording finishes.',
      code: 'live_recording_in_progress',
      isRetryable: true,
    );

/// Translates a platform error code from the decode bridge into a usable failure.
///
/// The codes are the ones `audio_decoder_interface.dart` documents. An unrecognised
/// code still produces a complete message rather than falling through to something
/// raw — an unmapped code is our bug, and the user should not be the one who pays for
/// it with an unreadable error.
ImportFailure describeDecodeFailure(String code, String? message) {
  switch (code) {
    case 'file_unreadable':
      return unreadableRecording('this recording');
    case 'format_unsupported':
      return undecodableRecording(null, message);
    case 'no_audio_track':
      return noAudioTrack('this file');
    case 'decoder_init_failed':
      return decoderUnavailable();
    default:
      return ImportFailure(
        whatHappened: 'Something went wrong while reading this recording.',
        whatToDo: 'Try the import again. If it keeps failing, the file may be damaged.',
        code: code,
        isRetryable: true,
      );
  }
}
