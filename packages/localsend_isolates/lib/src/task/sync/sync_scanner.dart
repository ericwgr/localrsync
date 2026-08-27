import 'dart:io';

import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/util/file_hash.dart';
import 'package:path/path.dart' as p;

/// One entry (file or directory) of a sync folder, with everything the sync
/// protocol needs.
class SyncEntry {
  /// Path relative to the sync folder root, with forward slashes. Directory
  /// paths carry no trailing slash.
  final String relativePath;

  /// Absolute path of the entry on disk.
  final String absolutePath;

  /// Whether this entry is a directory. Directories are listed (with size 0
  /// and an empty SHA-256) so the destination can mirror empty folders; they
  /// are never uploaded.
  final bool isDir;

  /// Size of the file in bytes (0 for directories).
  final int size;

  /// Seconds since the Unix epoch of the last modification, if known.
  final int? mtime;

  /// SHA-256 of the file content, lowercase hex (empty for directories).
  final String sha256;

  SyncEntry({
    required this.relativePath,
    required this.absolutePath,
    required this.isDir,
    required this.size,
    required this.mtime,
    required this.sha256,
  });
}

/// Lists [rootPath] recursively: files are hashed (SHA-256, lowercase hex),
/// directories are listed without content. Symlinks are not followed; hidden
/// files are included.
///
/// [onProgress] reports (processed, total) after each entry has been handled;
/// it is called once with (0, total) after the directory walk finished.
///
/// Cancelling [cancelToken] aborts the scan between entries and throws.
Future<List<SyncEntry>> scanSyncFolder({
  required String rootPath,
  required RsCancellationToken cancelToken,
  void Function(int processed, int total)? onProgress,
}) async {
  // The walk happens first: the total only becomes known afterwards.
  final entities = <FileSystemEntity>[];
  await for (final entity in Directory(rootPath).list(recursive: true, followLinks: false)) {
    if (entity is File || entity is Directory) {
      entities.add(entity);
    }
    // Links (symlinks) are skipped.
  }

  entities.sort((a, b) => a.path.compareTo(b.path));

  final entries = <SyncEntry>[];
  final total = entities.length;
  onProgress?.call(0, total);
  for (var i = 0; i < total; i++) {
    final entity = entities[i];
    final relative = p.relative(entity.path, from: rootPath).replaceAll(r'\', '/');
    if (relative.isEmpty) {
      continue;
    }
    final stat = await entity.stat();
    final isDir = entity is Directory;
    final hash = isDir
        ? ''
        : await calculateFileHash(
            path: (entity as File).path,
            bytes: null,
            cancelToken: cancelToken,
          );
    entries.add(
      SyncEntry(
        relativePath: relative,
        absolutePath: entity.path,
        isDir: isDir,
        size: isDir ? 0 : stat.size,
        mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
        sha256: hash,
      ),
    );
    onProgress?.call(i + 1, total);
  }
  return entries;
}
