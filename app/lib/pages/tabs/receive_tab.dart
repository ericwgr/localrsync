import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/sync_folder_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/widget/animations/initial_fade_transition.dart';
import 'package:localsend_app/widget/column_list_view.dart';
import 'package:localsend_app/widget/custom_icon_button.dart';
import 'package:localsend_app/widget/dialogs/folder_picker_dialog.dart';
import 'package:localsend_app/widget/dialogs/storage_permission_dialog.dart';
import 'package:localsend_app/widget/dialogs/sync_device_dialog.dart';
import 'package:localsend_app/widget/local_send_logo.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/rotating_widget.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class ReceiveTab extends StatefulWidget {
  const ReceiveTab();

  @override
  State<ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends State<ReceiveTab> {
  /// Whether the advanced network info is shown
  bool _showAdvanced = false;

  /// Whether the history button is shown
  /// This extra boolean is needed to delay the animation
  bool _showHistoryButton = true;

  Future<void> _toggleAdvanced() async {
    if (_showAdvanced) {
      setState(() => _showAdvanced = false);
      await sleepAsync(200);
      if (mounted) {
        setState(() => _showHistoryButton = true);
      }
    } else {
      setState(() {
        _showAdvanced = true;
        _showHistoryButton = false;
      });
    }
  }

  Future<void> _copyIp(String ip) async {
    await Clipboard.setData(ClipboardData(text: ip));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t.general.copiedToClipboard),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  bool _refreshing = false;

  /// Manually re-fetches the local IPs.
  /// Needed because the connectivity listener does not always fire,
  /// e.g. after (re)connecting to a Wi-Fi network.
  Future<void> _refreshIps() async {
    setState(() => _refreshing = true);
    try {
      await context.ref.redux(localIpProvider).dispatchAsync(FetchLocalIpAction());
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final alias = context.watch(settingsProvider.select((s) => s.alias));
    final serverState = context.watch(serverProvider);
    final localIps = context.watch(localIpProvider.select((s) => s.localIps));

    return Stack(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: ResponsiveListView.defaultMaxWidth),
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: ColumnListView(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        InitialFadeTransition(
                          duration: const Duration(milliseconds: 300),
                          delay: const Duration(milliseconds: 200),
                          child: Consumer(
                            builder: (context, ref) {
                              final animations = ref.watch(animationProvider);
                              final activeTab = ref.watch(homePageControllerProvider.select((state) => state.currentTab));
                              return RotatingWidget(
                                duration: const Duration(seconds: 15),
                                spinning: serverState != null && animations && activeTab == HomeTab.receive,
                                child: const LocalSendLogo(withText: false),
                              );
                            },
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(serverState?.alias ?? alias, style: const TextStyle(fontSize: 48)),
                        ),
                        Visibility(
                          visible: serverState == null,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: InitialFadeTransition(
                            duration: const Duration(milliseconds: 300),
                            delay: const Duration(milliseconds: 500),
                            child: Text(
                              t.general.offline,
                              style: const TextStyle(fontSize: 24),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (localIps.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 15),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        children: [
                          for (final ip in localIps)
                            InkWell(
                              key: ValueKey('ip-copy-$ip'),
                              onTap: () => _copyIp(ip),
                              child: Text(
                                ip,
                                style: const TextStyle(fontSize: 24, color: Colors.blue, fontWeight: FontWeight.w500),
                              ),
                            ),
                          RotatingWidget(
                            duration: const Duration(milliseconds: 1200),
                            spinning: _refreshing,
                            child: CustomIconButton(
                              onPressed: () async {
                                await _refreshIps();
                              },
                              child: const Icon(Icons.refresh),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await context.global.dispatchAsync(NavigateAction.push(const WebSharePage()));
                        },
                        icon: Icon(Icons.language),
                        label: Text(t.receiveTab.link),
                      ),
                    ),
                  ),
                  const _SyncFolderSection(),
                  const SizedBox(height: 15),
                ],
              ),
            ),
          ),
        ),
        _InfoBox(
          serverState: serverState,
          showAdvanced: _showAdvanced,
        ),
        _CornerButtons(
          showAdvanced: _showAdvanced,
          showHistoryButton: _showHistoryButton,
          toggleAdvanced: _toggleAdvanced,
        ),
      ],
    );
  }
}

class _CornerButtons extends StatelessWidget {
  final bool showAdvanced;
  final bool showHistoryButton;
  final Future<void> Function() toggleAdvanced;

  const _CornerButtons({
    required this.showAdvanced,
    required this.showHistoryButton,
    required this.toggleAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (!showAdvanced)
              AnimatedOpacity(
                opacity: showHistoryButton ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: CustomIconButton(
                  onPressed: () async {
                    await context.push(() => const ReceiveHistoryPage());
                  },
                  child: const Icon(Icons.history),
                ),
              ),
            CustomIconButton(
              key: const ValueKey('info-btn'),
              onPressed: toggleAdvanced,
              child: const Icon(Icons.info),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final ServerState? serverState;
  final bool showAdvanced;

  const _InfoBox({
    required this.serverState,
    required this.showAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedCrossFade(
      crossFadeState: showAdvanced ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 200),
      firstChild: Container(),
      secondChild: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: IntrinsicColumnWidth(),
                  2: IntrinsicColumnWidth(),
                },
                children: [
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.alias),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(right: 30),
                        child: SelectableText(serverState?.alias ?? '-'),
                      ),
                    ],
                  ),
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.port),
                      const SizedBox(width: 10),
                      SelectableText(serverState?.port.toString() ?? '-'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "sync folder" section below the receive-upload button.
///
/// Lets the user pick a folder whose path and size (last known value, cached
/// on disk) are shown on this page. The size can be refreshed manually.
class _SyncFolderSection extends StatelessWidget {
  const _SyncFolderSection();

  Future<void> _pickFolder(BuildContext context) async {
    if (checkPlatform([TargetPlatform.android])) {
      // On Android, picking a folder requires "All files access". Without it,
      // the picker cannot browse the whole device, so block the flow and guide
      // the user to the system settings instead.
      if (!await hasAllFilesAccessPermissionAndroid()) {
        if (!context.mounted) {
          return;
        }
        await showDialog(
          context: context,
          builder: (_) => StoragePermissionDialog(
            isAndroid: true,
            onOpenSettings: requestAllFilesAccessPermissionAndroid,
            onRecheck: hasAllFilesAccessPermissionAndroid,
          ),
        );
        return;
      }
    }
    if (!context.mounted) {
      return;
    }
    // Android: browse the file system directly with a built-in picker
    // (the permission above is granted). Other platforms: system picker.
    final String? path;
    if (checkPlatform([TargetPlatform.android])) {
      path = await showDialog<String>(
        context: context,
        builder: (_) => const FolderPickerDialog(),
      );
    } else {
      path = await pickDirectoryPath();
    }
    if (path == null || !context.mounted) {
      return;
    }
    await context.ref.redux(syncFolderProvider).dispatchAsync(ChangeSyncFolderAction(path));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch(syncFolderProvider);
    final sizeStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: state.path == null
          ? Center(
              child: OutlinedButton.icon(
                onPressed: () => _pickFolder(context),
                icon: const Icon(Icons.folder_open),
                label: Text(t.receiveTab.syncFolder.choose),
              ),
            )
          : Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.folder, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                state.path!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              if (state.loading)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(t.receiveTab.syncFolder.calculating, style: sizeStyle),
                                  ],
                                )
                              else
                                Text(
                                  state.sizeBytes != null ? state.sizeBytes!.asReadableFileSize : t.receiveTab.syncFolder.unavailable,
                                  style: sizeStyle,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // The buttons live on their own row: refresh and change
                    // keep their icon form, "sync" queries another device.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: t.receiveTab.syncFolder.refresh,
                          onPressed: () async {
                            await context.ref.redux(syncFolderProvider).dispatchAsync(RefreshSyncFolderSizeAction());
                          },
                          icon: const Icon(Icons.refresh),
                        ),
                        IconButton(
                          tooltip: t.receiveTab.syncFolder.change,
                          onPressed: () => _pickFolder(context),
                          icon: const Icon(Icons.folder_open),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => showDialog(
                            context: context,
                            builder: (_) => const SyncDeviceDialog(),
                          ),
                          icon: const Icon(Icons.sync),
                          label: Text(t.receiveTab.syncFolder.sync),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
