import 'dart:io';
import 'dart:isolate';

/// Calculates the total size in bytes of all files inside [path], recursively.
///
/// The walk runs on a separate isolate so the UI stays responsive even for
/// very large folders. Access errors (permission, vanished entries, symlink
/// loops) are skipped instead of aborting the walk.
Future<int> calculateDirectorySize(String path) {
  return Isolate.run(() => _walk(Directory(path)));
}

int _walk(Directory root) {
  var total = 0;
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    final List<FileSystemEntity> entities;
    try {
      entities = current.listSync(followLinks: false);
    } catch (_) {
      continue; // permission error or unreadable directory: skip
    }
    for (final entity in entities) {
      if (entity is File) {
        try {
          total += entity.lengthSync();
        } catch (_) {
          // file vanished or is not readable: skip
        }
      } else if (entity is Directory) {
        pending.add(entity);
      }
    }
  }
  return total;
}
