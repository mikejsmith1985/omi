/// Purpose: hold the decoded audio for an import, and make sure it is always deleted.
///
/// Decoding produces a lot of bytes: an hour of 16 kHz mono PCM16 is about 115 MB. At
/// the volume this feature is built for — around twenty hours a week — a scratch file
/// that survives its import would fill a phone within days. So data-model Invariant 3
/// says the decoded audio is scratch, deleted on every terminal outcome.
///
/// "Every terminal outcome" includes the one nobody tests: the app being killed
/// mid-import. A file left behind by a process that died cannot be cleaned up by that
/// process, so [purgeAbandonedScratchFiles] runs at startup and removes anything left
/// from a previous run. Without it the leak still happens, just more slowly.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Directory name for decoded import audio, under the app's temporary directory.
///
/// Its own directory rather than loose files so a startup purge can be certain it is
/// only deleting our scratch, never something another part of the app is using.
const String scratchDirectoryName = 'import_scratch';

/// Extension marking a decoded scratch file.
const String scratchFileExtension = '.pcm';

/// Manages the decoded-audio scratch files for imports.
class ScratchStorage {
  /// Resolves the temporary directory. Injectable so tests need no real filesystem.
  final Future<Directory> Function() _resolveTemporaryDirectory;

  /// Creates storage backed by the platform's temporary directory.
  ScratchStorage() : _resolveTemporaryDirectory = getTemporaryDirectory;

  /// Creates storage rooted at a directory of the caller's choosing, for tests.
  ScratchStorage.withDirectory(Directory root) : _resolveTemporaryDirectory = (() async => root);

  /// The directory scratch files live in, created if it does not exist.
  Future<Directory> resolveScratchDirectory() async {
    final root = await _resolveTemporaryDirectory();
    final directory = Directory(p.join(root.path, scratchDirectoryName));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// Creates an empty scratch file for the job identified by [jobId].
  ///
  /// Named from the job rather than randomly so that a file left behind by a crash can
  /// be traced back to what produced it.
  Future<File> createScratchFile(String jobId) async {
    final directory = await resolveScratchDirectory();
    final file = File(p.join(directory.path, '$jobId$scratchFileExtension'));
    if (await file.exists()) {
      await file.delete();
    }
    await file.create();
    return file;
  }

  /// Deletes one scratch file, tolerating its absence.
  ///
  /// Called on every terminal stage, including paths that may already have deleted it.
  /// A failure to delete must never become the reason an import reports failure.
  Future<void> deleteScratchFile(String? path) async {
    if (path == null) return;
    final file = File(path);
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing useful to do or say: the import itself succeeded or failed on its own
      // terms, and the startup purge will collect this file on the next run.
    }
  }

  /// Deletes scratch left behind by a previous run.
  ///
  /// Call once at startup, before any import begins. Returns how many bytes were
  /// recovered, so the amount can be logged and a persistent leak noticed rather than
  /// silently tolerated.
  Future<int> purgeAbandonedScratchFiles() async {
    final directory = await resolveScratchDirectory();
    var recoveredBytes = 0;

    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      if (p.extension(entity.path) != scratchFileExtension) continue;
      recoveredBytes += await _deleteAndMeasure(entity);
    }
    return recoveredBytes;
  }

  /// Deletes one abandoned file, returning the bytes it was occupying.
  Future<int> _deleteAndMeasure(File file) async {
    try {
      final size = await file.length();
      await file.delete();
      return size;
    } on FileSystemException {
      return 0;
    }
  }
}
