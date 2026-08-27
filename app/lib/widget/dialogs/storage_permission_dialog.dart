import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:routerino/routerino.dart';

/// Guided dialog shown when entering the settings tab while the file access
/// permission of the current platform is missing:
/// - Android: "All files access" (MANAGE_EXTERNAL_STORAGE)
/// - macOS: "Full Disk Access" (TCC)
class StoragePermissionDialog extends StatelessWidget {
  /// Whether the dialog runs on Android. When false, it presents the macOS flow.
  final bool isAndroid;

  /// Android: opens the "All files access" system screen and resolves with the
  /// granted state once the user returns. macOS: opens the Full Disk Access pane
  /// in System Settings and resolves immediately.
  final Future<bool> Function() onOpenSettings;

  /// Re-checks the current granted state (used on macOS after the user returns
  /// from System Settings).
  final Future<bool> Function() onRecheck;

  const StoragePermissionDialog({
    super.key,
    required this.isAndroid,
    required this.onOpenSettings,
    required this.onRecheck,
  });

  @override
  Widget build(BuildContext context) {
    final strings = t.dialogs.permissionsRequired;
    return AlertDialog(
      title: Text(isAndroid ? strings.titleAllFiles : strings.titleFullDisk),
      content: Text(isAndroid ? strings.descriptionAllFiles : strings.descriptionFullDisk),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(strings.later),
        ),
        // On macOS the user returns to the still-open dialog and re-checks here;
        // on Android the dialog closes itself once the permission is granted.
        if (!isAndroid)
          TextButton(
            onPressed: () async {
              final granted = await onRecheck();
              if (granted && context.mounted) {
                context.pop();
              }
            },
            child: Text(strings.recheck),
          ),
        ElevatedButton.icon(
          onPressed: () async {
            final granted = await onOpenSettings();
            if (granted && context.mounted) {
              context.pop();
            }
          },
          icon: const Icon(Icons.settings),
          label: Text(strings.openSettings),
        ),
      ],
    );
  }
}
