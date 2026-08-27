import 'dart:io';

import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/src/task/sync/sync_scanner.dart';
import 'package:path/path.dart' as p;

/// The path lists of a sync diff, ordered by path.
class SyncDiff {
  /// Files the initiator must upload: missing on the destination or with a
  /// different SHA-256. Directories are never uploaded.
  final List<String> needUpload;

  /// Files that exist only on the destination and must be deleted after all
  /// uploads succeeded, so the destination mirrors the initiator.
  final List<String> deleteRemote;

  /// Destination-only directories whose whole content is being deleted,
  /// deepest-first. They are deleted after [deleteRemote]; directories that
  /// are still not empty are kept.
  final List<String> deleteDirs;

  SyncDiff({required this.needUpload, required this.deleteRemote, required this.deleteDirs});
}

/// Diffs the [remote] manifest (the initiator's folder listing) against the
/// destination's [local] scan. The comparison is authoritative on `sha256`.
SyncDiff computeSyncDiff({
  required List<SyncFileInfoV2> remote,
  required List<SyncEntry> local,
}) {
  final localByPath = {for (final entry in local) entry.relativePath: entry};
  final remoteByPath = {for (final file in remote) file.path: file};
  final remoteDirs = {
    for (final file in remote)
      if (file.isDir) file.path,
  };

  final needUpload = <String>[];
  final sortedRemote = [...remote]..sort((a, b) => a.path.compareTo(b.path));
  for (final file in sortedRemote) {
    if (file.isDir) {
      // Directories carry no content: their existence matters only to the
      // deletion logic below, never to the upload phase.
      continue;
    }
    final localEntry = localByPath[file.path];
    if (localEntry == null || localEntry.sha256 != file.sha256) {
      needUpload.add(file.path);
    }
  }

  final deleteRemote = <String>[];
  final sortedLocal = [...local]..sort((a, b) => a.relativePath.compareTo(b.relativePath));
  for (final entry in sortedLocal) {
    if (entry.isDir) {
      continue;
    }
    if (!remoteByPath.containsKey(entry.relativePath)) {
      deleteRemote.add(entry.relativePath);
    }
  }

  // Destination-only directories are deleted when their entire content is
  // part of the deletion: no file below them survives and all subdirectories
  // are themselves deletable. The result is ordered deepest-first.
  final deleteSet = deleteRemote.toSet();
  final deletable = <String>{};
  bool dirIsDeletable(String dirPath) {
    if (deletable.contains(dirPath)) {
      return true;
    }
    if (remoteDirs.contains(dirPath)) {
      return false;
    }
    final prefix = '$dirPath/';
    for (final entry in local) {
      if (!entry.relativePath.startsWith(prefix)) {
        continue;
      }
      if (!entry.isDir) {
        if (!deleteSet.contains(entry.relativePath)) {
          return false;
        }
      } else if (!dirIsDeletable(entry.relativePath)) {
        return false;
      }
    }
    deletable.add(dirPath);
    return true;
  }

  final deleteDirs = <String>[];
  for (final entry in sortedLocal) {
    if (entry.isDir && dirIsDeletable(entry.relativePath)) {
      deleteDirs.add(entry.relativePath);
    }
  }
  // Children always have a longer path than their parent, so sorting by
  // descending length deletes inner directories before their parents.
  deleteDirs.sort((a, b) => b.length - a.length);

  return SyncDiff(needUpload: needUpload, deleteRemote: deleteRemote, deleteDirs: deleteDirs);
}

/// Deletes the given files and empty directories inside [syncFolderPath].
/// Files are deleted first; then [deleteDirs] (deepest-first) are removed
/// only while they are empty, so directories that received new content are
/// kept. Missing entries are ignored. Returns the number of deleted entries.
Future<int> deleteSyncFiles({
  required String syncFolderPath,
  required List<String> relativePaths,
  required List<String> deleteDirs,
}) async {
  final root = p.normalize(syncFolderPath);
  var deleted = 0;
  for (final relative in relativePaths) {
    // The paths were validated by the Rust server (no `..`, no absolute
    // paths, no `\`); this is a last line of defense against corrupt inputs.
    if (!isSafeRelative(relative)) {
      continue;
    }
    final file = File(p.join(syncFolderPath, relative));
    try {
      await file.delete();
      deleted++;
    } on FileSystemException {
      // Missing files are fine: the folder may have changed since the diff.
      continue;
    }
  }

  for (final relative in deleteDirs) {
    if (!isSafeRelative(relative)) {
      continue;
    }
    final dir = Directory(p.join(syncFolderPath, relative));
    try {
      // The path must still be inside the sync folder even after the
      // symmetric symlink attack: a sync folder whose root itself is a
      // symlink is a user misconfiguration, not an attacker's doing.
      if (p.normalize(dir.path).startsWith('$root${p.separator}')) {
        if (dir.listSync().isEmpty) {
          await dir.delete();
          deleted++;
        }
      }
    } on FileSystemException {
      // Already gone or not empty: the folder may have changed since the
      // diff. The diff authorized only empty directories.
      continue;
    }
  }
  return deleted;
}

/// The path passed the server's validation (no `..`, no leading `/`, no
/// backslashes) — a last line of defense against corrupt inputs.
bool isSafeRelative(String relative) => !relative.contains('..') && !relative.startsWith('/') && !relative.contains(r'\');
