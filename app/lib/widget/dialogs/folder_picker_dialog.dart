import 'dart:io';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';

/// A folder picker for Android.
///
/// Since the app holds the "all files access" permission (MANAGE_EXTERNAL_STORAGE),
/// the whole file system can be browsed directly instead of using the SAF
/// picker. Pops with the selected path, or null when cancelled.
class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog();

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  /// The main internal storage, where users store their files.
  late String _currentPath = '/storage/emulated/0';
  List<String> _subFolders = const [];
  bool _loading = true;

  /// Whether the current directory was readable during the last load.
  bool _readable = true;

  bool get _canGoUp => Directory(_currentPath).parent.path != _currentPath;

  @override
  void initState() {
    super.initState();
    _load(); // ignore: discarded_futures
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _readable = true;
    });
    try {
      if (_currentPath == '/storage/emulated/0') {
        _currentPath = await getExternalStorageRootAndroid();
      }
      final result = await listExternalStorageDirectoriesAndroid(_currentPath);
      if (mounted) {
        setState(() {
          _subFolders = result;
          _readable = true;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _subFolders = const [];
          _readable = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _enter(String path) async {
    _currentPath = path;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final strings = t.dialogs.folderPicker;
    return AlertDialog(
      title: Text(strings.title),
      content: SizedBox(
        width: 400,
        height: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.folder, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : !_readable
                  ? Center(child: Text(strings.unreadable))
                  : _subFolders.isEmpty
                  ? Center(child: Text(strings.empty))
                  : ListView(
                      children: [
                        if (_canGoUp)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_upward),
                            title: Text(strings.up),
                            onTap: () => _enter(Directory(_currentPath).parent.path),
                          ),
                        for (final dir in _subFolders)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder),
                            title: Text(dir.split('/').last),
                            onTap: () => _enter(dir),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.general.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _currentPath),
          child: Text(strings.use),
        ),
      ],
    );
  }
}
