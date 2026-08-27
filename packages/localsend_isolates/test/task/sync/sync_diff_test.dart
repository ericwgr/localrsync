import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/src/task/sync/sync_diff.dart';
import 'package:localsend_isolates/src/task/sync/sync_scanner.dart';

SyncFileInfoV2 _file(String path, String sha) => SyncFileInfoV2(
  path: path,
  size: BigInt.from(123),
  mtime: BigInt.from(1_700_000_000),
  sha256: sha,
  isDir: false,
);

SyncFileInfoV2 _dir(String path) => SyncFileInfoV2(
  path: path,
  size: BigInt.zero,
  mtime: BigInt.from(1_700_000_000),
  sha256: '',
  isDir: true,
);

SyncEntry _entry(String path, {bool isDir = false, String sha = ''}) => SyncEntry(
  relativePath: path,
  absolutePath: '/tmp/$path',
  isDir: isDir,
  size: isDir ? 0 : 123,
  mtime: 1_700_000_000,
  sha256: isDir ? '' : sha,
);

void main() {
  group('computeSyncDiff', () {
    test('lists destination-only empty directories deepest-first', () {
      // The user's scenario: the destination has empty folders the source
      // does not; they must be deleted, inner folders first.
      final remote = [
        _file('a.txt', 'abc'),
      ];
      final local = [
        _entry('a.txt', sha: 'abc'),
        _entry('folder1', isDir: true),
        _entry('folder1/folder1-1', isDir: true),
        _entry('folder2', isDir: true),
        _entry('folder2/folder2-1', isDir: true),
        _entry('folder2/folder2-1/folder2-1-1', isDir: true),
      ];

      final diff = computeSyncDiff(remote: remote, local: local);
      expect(diff.needUpload, isEmpty);
      expect(diff.deleteRemote, isEmpty);
      expect(diff.deleteDirs, [
        'folder2/folder2-1/folder2-1-1',
        'folder1/folder1-1',
        'folder2/folder2-1',
        'folder1',
        'folder2',
      ]);
    });

    test('keeps directories that exist on the source', () {
      final remote = [
        _dir('keep'),
        _file('keep/x.txt', 'abc'),
      ];
      final local = [
        _entry('keep', isDir: true),
        _entry('keep/x.txt', sha: 'abc'),
      ];

      final diff = computeSyncDiff(remote: remote, local: local);
      expect(diff.deleteDirs, isEmpty);
      expect(diff.deleteRemote, isEmpty);
      expect(diff.needUpload, isEmpty);
    });

    test('keeps a directory that contains a surviving file', () {
      // The directory exists only on the destination, but one of its files
      // is also on the source: after the sync the directory is still needed.
      final remote = [_file('mix/a.txt', 'abc')];
      final local = [
        _entry('mix', isDir: true),
        _entry('mix/a.txt', sha: 'abc'),
        _entry('mix/old.txt', sha: 'gone'),
      ];

      final diff = computeSyncDiff(remote: remote, local: local);
      expect(diff.needUpload, isEmpty);
      expect(diff.deleteRemote, ['mix/old.txt']);
      expect(diff.deleteDirs, isEmpty);
    });

    test('deletes a directory whose whole content went away', () {
      final remote = [_file('stale/a.txt', 'abc')];
      final local = [
        _entry('stale', isDir: true),
        _entry('stale/a.txt', sha: 'abc'),
        _entry('stale/deep', isDir: true),
        _entry('stale/deep/b.txt', sha: 'xyz'),
      ];

      final diff = computeSyncDiff(remote: remote, local: local);
      expect(diff.needUpload, isEmpty);
      expect(diff.deleteRemote, ['stale/deep/b.txt']);
      // Deepest directory first; the directory that still holds the source's
      // file survives.
      expect(diff.deleteDirs, ['stale/deep']);
    });

    test('directories are never uploaded', () {
      // The destination does not have the directory at all: uploading is
      // file-based, so the diff must not ask for a directory upload.
      final remote = [_dir('empty'), _file('a.txt', 'abc')];
      final local = [_entry('a.txt', sha: 'zzz')];

      final diff = computeSyncDiff(remote: remote, local: local);
      expect(diff.needUpload, ['a.txt']);
      expect(diff.deleteDirs, isEmpty);
    });
  });

  group('deleteSyncFiles', () {
    test('deletes only files and empty directories', () async {
      final root = await Directory.systemTemp.createTemp('sync_diff_test');
      addTearDown(() => root.delete(recursive: true));
      final folder = Directory('${root.path}/synced')..createSync();
      // Real files, including directories with content.
      final deep = Directory('${folder.path}/folder1/folder1-1')..createSync(recursive: true);
      File('${folder.path}/stale/a.txt').createSync(recursive: true);
      Directory('${folder.path}/stale/deep').createSync(recursive: true);
      File('${folder.path}/keep.txt').createSync();

      final deleted = await deleteSyncFiles(
        syncFolderPath: folder.path,
        relativePaths: ['keep.txt', 'stale/a.txt'],
        deleteDirs: ['stale/deep', 'stale', 'folder1/folder1-1', 'folder1'],
      );

      expect(deleted, 6);
      expect(File('${folder.path}/keep.txt').existsSync(), isFalse);
      expect(Directory('${folder.path}/stale').existsSync(), isFalse);
      expect(Directory('${folder.path}/folder1').existsSync(), isFalse);
      // A directory with new content survives.
      final kept = Directory('${folder.path}/kept')..createSync();
      File('${kept.path}/new.txt').createSync();
      final deleted2 = await deleteSyncFiles(
        syncFolderPath: folder.path,
        relativePaths: const [],
        deleteDirs: ['kept'],
      );
      expect(deleted2, 0);
      expect(Directory('${kept.path}').existsSync(), isTrue);
    });

    test('does not delete directories that received new content', () async {
      final root = await Directory.systemTemp.createTemp('sync_diff_test');
      addTearDown(() => root.delete(recursive: true));
      final folder = Directory('${root.path}/synced')..createSync();
      final dir = Directory('${folder.path}/stale')..createSync();
      File('${dir.path}/new.txt').createSync();

      final deleted = await deleteSyncFiles(
        syncFolderPath: folder.path,
        relativePaths: const [],
        deleteDirs: ['stale'],
      );

      expect(deleted, 0);
      expect(Directory('${dir.path}').existsSync(), isTrue);
    });
  });
}
