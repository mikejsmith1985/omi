/// Purpose: identify a recording by what it contains, so re-selecting the same audio
/// never produces a second conversation.
///
/// Filenames, paths and modification times all change in ordinary use — a file copied
/// out of a messaging app, re-exported from a recorder, or shared to a second device
/// arrives with a different name every time. The bytes do not. So identity is a hash
/// of the contents (data-model Invariant 2), which is what makes FR-004 and SC-006
/// achievable rather than best-effort.
///
/// The file is read in chunks rather than loaded whole: an hour of audio is well over
/// a hundred megabytes, and hashing it by loading it into memory would fail the very
/// memory bound this feature is built around (SC-005).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// How much of the file to read at a time while hashing.
///
/// Large enough that the read syscalls are not the bottleneck, small enough that the
/// peak cost of identifying a recording is measured in kilobytes rather than in
/// however long the recording happens to be.
const int hashChunkSizeBytes = 64 * 1024;

/// The content hash of a recording, as a lowercase hex string.
///
/// SHA-256 rather than a faster non-cryptographic hash: the cost is trivial next to
/// transcription, and a collision here means one recording silently masking another,
/// which is a defect a user could never diagnose.
Future<String> hashRecordingFile(File file) async {
  final digestSink = _AccumulatingSink();
  final input = sha256.startChunkedConversion(digestSink);

  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();

  return digestSink.digest.toString();
}

/// The content hash of bytes already in memory.
///
/// Used by tests and by any path that has the audio without a file behind it. Kept
/// beside [hashRecordingFile] so both routes provably produce the same identity for
/// the same audio.
String hashRecordingBytes(List<int> bytes) => sha256.convert(bytes).toString();

/// Collects the single digest that a chunked hash conversion emits.
class _AccumulatingSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
