import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/sync_folder_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/widget/device_bage.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// A dialog to query the sync folder information of another device.
///
/// Step 1: enter an IP address / http(s) URL or pick a nearby device.
/// Step 2: shows the peer's configured sync folder path and size
/// (fetched via `POST /api/localsend/v2/sync-folder-info`).
/// Step 3: mirrors the local sync folder into the peer's sync folder
/// (scan → manifest → parallel uploads → commit).
class SyncDeviceDialog extends StatefulWidget {
  const SyncDeviceDialog();

  @override
  State<SyncDeviceDialog> createState() => _SyncDeviceDialogState();
}

/// LocalSend default port, used when a URL has no explicit port.
const _defaultPort = 53317;

class _SyncDeviceDialogState extends State<SyncDeviceDialog> with Refena {
  final _inputController = TextEditingController();
  String _input = '';

  /// Currently registering the entered address.
  bool _connecting = false;
  String? _inputError;

  /// The device resolved from the entered address, shown as a selectable entry.
  Device? _inputDevice;

  /// The currently selected device (entered or nearby).
  Device? _selected;

  /// Whether the detail step (step 2) is shown.
  bool _showDetails = false;

  /// The result of the sync folder query.
  _SyncFolderInfo? _query;

  /// Whether the mirror sync (step 3) is running.
  bool _syncing = false;

  /// The id of the running push task, used to cancel it.
  int? _taskId;

  /// The stream of sync events of the running push.
  StreamSubscription<HttpSyncEvent>? _syncSubscription;

  /// The progress snapshot shown in step 3.
  _SyncProgress? _progress;

  /// Files of the diff that finished uploading / are uploading right now.
  int _uploadDone = 0;
  final Map<String, double> _inFlight = {};

  /// Files deleted on the destination by the commit.
  int _deleted = 0;

  @override
  void initState() {
    super.initState();
    ensureRef((ref) {
      final lastAddress = ref.read(persistenceProvider).getLastSyncAddress() ?? '';
      _input = lastAddress;
      _inputController.text = lastAddress;
    });
  }

  void _selectInputDevice() {
    setState(() {
      _selected = _inputDevice;
    });
  }

  void _connectAddress() async {
    final input = _input.trim();
    if (input.isEmpty) {
      return;
    }
    final settings = ref.read(settingsProvider);
    final uri = Uri.tryParse(input);
    final String host;
    final bool https;
    final int port;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
      // Full URL: protocol and port come from the URL itself.
      host = uri.host;
      https = uri.scheme == 'https';
      port = uri.hasPort ? uri.port : _defaultPort;
    } else {
      // Bare IP: fall back to the local protocol settings.
      host = input;
      https = settings.https;
      port = settings.port;
    }

    setState(() {
      _connecting = true;
      _inputError = null;
    });

    try {
      final response = await ref
          .read(httpProvider)
          .discovery
          .register(
            protocol: https ? ProtocolType.https : ProtocolType.http,
            ip: host,
            port: port,
            payload: ref.read(deviceFullInfoProvider).toRegisterDto(),
          );
      if (!mounted) {
        return;
      }
      final device = response.body.toDevice(host, port, https);
      // Persistence should not delay showing the successfully connected peer
      // or turn a storage error into a connection error.
      unawaited(ref.read(persistenceProvider).setLastSyncAddress(input));
      setState(() {
        _connecting = false;
        _inputDevice = device;
        _selected = device;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connecting = false;
        _inputError = '${t.dialogs.syncDevice.addressNotFound}: ${e.humanErrorMessage}';
      });
    }
  }

  /// Enters the detail step and queries the peer's sync folder.
  void _showDetailsStep() {
    final device = _selected;
    if (device == null) {
      return;
    }
    setState(() {
      _showDetails = true;
      _query = null;
    });
    // ignore: discarded_futures
    _queryFolderInfo(device);
  }

  Future<void> _queryFolderInfo(Device device) async {
    // The device is known (either discovered or just registered), so its
    // fingerprint can be pinned: under HTTPS it is the certificate identity
    // (the server enforces that the payload fingerprint matches the cert),
    // under HTTP pinning is a no-op.
    final client = device.fingerprint.isNotEmpty ? ref.read(httpProvider).pinnedTo(device.fingerprint) : ref.read(httpProvider).discovery;
    try {
      final info = await client.syncFolderInfo(
        protocol: device.https ? ProtocolType.https : ProtocolType.http,
        ip: device.ip!,
        port: device.port,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        // `null` means the peer responded with 204: no sync folder configured.
        _query = info == null ? const _SyncFolderInfoNotConfigured() : _SyncFolderInfoData(info);
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _query = _SyncFolderInfoError(e.humanErrorMessage);
      });
    }
  }

  /// Mirrors the local sync folder into the peer's sync folder by dispatching
  /// a push task to the upload isolate and rendering its events as progress.
  void _startSync() {
    final device = _selected;
    final query = _query;
    final localPath = ref.read(syncFolderProvider).path;
    if (device == null || device.ip == null || query is! _SyncFolderInfoData || localPath == null) {
      return;
    }

    setState(() {
      _syncing = true;
      _progress = null;
      _uploadDone = 0;
      _inFlight.clear();
      _deleted = 0;
    });

    final result = ref
        .redux(parentIsolateProvider)
        .dispatchTakeResult(
          IsolateHttpSyncPushAction(
            localPath: localPath,
            device: device,
          ),
        );
    _taskId = result.taskId;
    _syncSubscription = result.events.listen(
      _onSyncEvent,
      onError: (Object error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _progress = _SyncProgressFailed(error.toString());
        });
      },
      onDone: () {
        if (!mounted || _taskId == null) {
          // The dialog was closed or the push was canceled: nothing to do.
          return;
        }
        setState(() {
          _syncing = false;
          _taskId = null;
          // The stream ended without a terminal event: treat as canceled.
          _progress ??= const _SyncProgressCanceled();
        });
      },
    );
  }

  void _onSyncEvent(HttpSyncEvent event) {
    setState(() {
      switch (event) {
        case HttpSyncScanStartedEvent(:final total):
          _progress = _SyncProgressScanning(processed: 0, total: total);
        case HttpSyncScanProgressEvent(:final processed, :final total):
          _progress = _SyncProgressScanning(processed: processed, total: total);
        case HttpSyncDiffEvent(:final needUpload, :final deleteRemote, :final deleteDirs):
          _uploadDone = 0;
          _inFlight.clear();
          _progress = _SyncProgressDiff(
            upload: needUpload.length,
            delete: deleteRemote.length + deleteDirs.length,
          );
        case HttpSyncFileStartedEvent():
          if (_progress case _SyncProgressDiff()) {
            _progress = const _SyncProgressUploading();
          }
        case HttpSyncFileProgressEvent(:final path, :final progress):
          _inFlight[path] = progress;
        case HttpSyncFileFinishedEvent(:final path):
          _inFlight.remove(path);
          _uploadDone += 1;
          _progress = const _SyncProgressUploading();
        case HttpSyncCommittedEvent(:final deletedCount):
          _deleted = deletedCount;
          _progress = _SyncProgressCommitted(deletedCount);
        case HttpSyncFailedEvent(:final error):
          _progress = _SyncProgressFailed(error);
        case HttpSyncFinishedEvent():
          _progress = _SyncProgressDone(uploaded: _uploadDone, deleted: _deleted);
      }
    });
  }

  /// The number of files the manifest told us to upload: set by the diff
  /// event, then unchanged. 0 until the diff arrives.
  int get diffTotal => _progress is _SyncProgressDiff ? (_progress as _SyncProgressDiff).upload : _uploadDone;

  /// The overall upload progress as a fraction of [diffTotal], counting
  /// in-flight files by their own progress.
  double get _uploadFraction {
    final total = diffTotal;
    if (total == 0) {
      return 1;
    }
    final inFlight = _inFlight.values.fold<double>(0, (sum, p) => sum + p);
    return ((_uploadDone + inFlight) / total).clamp(0.0, 1.0);
  }

  void _cancelSync() {
    final taskId = _taskId;
    if (taskId == null) {
      return;
    }
    ref.redux(parentIsolateProvider).dispatch(IsolateHttpUploadCancelAction(taskId: taskId));
    setState(() {
      _progress = const _SyncProgressCanceled();
      _syncing = false;
      _taskId = null;
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    // ignore: discarded_futures
    _syncSubscription?.cancel();
    if (_syncing && _taskId != null) {
      // Closing the dialog mid-sync cancels the push instead of leaving an
      // orphan task running in the upload isolate.
      ref.redux(parentIsolateProvider).dispatch(IsolateHttpUploadCancelAction(taskId: _taskId!));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = t.dialogs.syncDevice;
    return AlertDialog(
      title: Text(strings.title),
      content: _showDetails ? _buildDetails(context) : _buildDeviceList(context),
      actions: [
        if (_showDetails && !_syncing)
          TextButton(
            onPressed: () {
              setState(() {
                _showDetails = false;
              });
            },
            child: Text(strings.back),
          ),
        if (_syncing && _taskId != null)
          TextButton(
            onPressed: _cancelSync,
            child: Text(strings.cancelSync),
          )
        else if (_progress case _SyncProgressDone() || _SyncProgressFailed() || _SyncProgressCanceled())
          TextButton(
            onPressed: () => context.pop(),
            child: Text(strings.close),
          )
        else
          TextButton(
            onPressed: () => context.pop(),
            child: Text(t.general.cancel),
          ),
        if (!_showDetails)
          FilledButton(
            onPressed: _selected == null ? null : _showDetailsStep,
            child: Text(strings.next),
          ),
      ],
    );
  }

  Widget _buildDetails(BuildContext context) {
    final strings = t.dialogs.syncDevice;
    final device = _selected;
    final query = _query;
    return SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.deviceDetails, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          if (device != null) ...[
            Row(
              children: [
                Icon(device.deviceType.icon, size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(device.alias, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${device.ip}${device.https ? ' (HTTPS)' : ''}${device.deviceModel != null ? ' • ${device.deviceModel}' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
          const Divider(height: 24),
          Text(
            strings.syncFolderPath,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          if (query == null)
            const _QueryRow()
          else
            switch (query) {
              _SyncFolderInfoData(:final info) => Text(info.path, style: Theme.of(context).textTheme.bodyMedium),
              _SyncFolderInfoNotConfigured() => Text(
                strings.notConfigured,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
              _SyncFolderInfoError(:final message) => Text(
                '${strings.queryFailed}: $message',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            },
          if (query case _SyncFolderInfoData(:final info) when info.sizeBytes != null) ...[
            const SizedBox(height: 12),
            Text(strings.folderSize, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(info.sizeBytes!.toInt().asReadableFileSize, style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (query case _SyncFolderInfoData()) ...[
            const SizedBox(height: 16),
            _buildSyncSection(context),
          ],
        ],
      ),
    );
  }

  /// Step 3: the button that mirrors the local sync folder into the peer's
  /// sync folder, plus the progress of the running mirror.
  Widget _buildSyncSection(BuildContext context) {
    final strings = t.dialogs.syncDevice;
    final localPath = ref.read(syncFolderProvider).path;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (localPath == null)
          Text(
            strings.localSyncFolderNotSet,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
          )
        else
          FilledButton.tonalIcon(
            onPressed: _syncing ? null : _startSync,
            icon: _syncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            label: Text(
              _syncing
                  ? strings.syncing
                  : _progress is _SyncProgressDone || _progress is _SyncProgressCommitted
                  ? strings.syncAgain
                  : strings.startSync,
            ),
          ),
        if (_progress != null) ...[
          const SizedBox(height: 12),
          _buildProgress(context, _progress!),
        ],
      ],
    );
  }

  /// The status line (and optional progress bar) of the running mirror.
  Widget _buildProgress(BuildContext context, _SyncProgress progress) {
    final strings = t.dialogs.syncDevice;
    final (text, isError, value) = switch (progress) {
      _SyncProgressScanning(:final processed, :final total) => (
        strings.phaseScanning(processed: processed, total: total),
        false,
        total == 0 ? null : processed / total,
      ),
      _SyncProgressDiff(:final upload, :final delete) => (
        strings.phaseDiff(upload: upload, delete: delete),
        false,
        null,
      ),
      _SyncProgressUploading() => (
        strings.phaseUploading(done: _uploadDone, total: diffTotal),
        false,
        _uploadFraction,
      ),
      _SyncProgressCommitted(:final deleted) => (
        strings.phaseCommitted(deleted: deleted),
        false,
        null,
      ),
      _SyncProgressDone(:final uploaded, :final deleted) => (
        strings.phaseDone(uploaded: uploaded, deleted: deleted),
        false,
        null,
      ),
      _SyncProgressFailed(:final error) => (
        strings.phaseFailed(error: error),
        true,
        null,
      ),
      _SyncProgressCanceled() => (strings.phaseCanceled, false, null),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.sync,
              size: 16,
              color: isError ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isError ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        if (value != null) ...[
          const SizedBox(height: 6),
          LinearProgressIndicator(value: value),
        ],
      ],
    );
  }

  Widget _buildDeviceList(BuildContext context) {
    final strings = t.dialogs.syncDevice;
    final nearbyDevices = ref.watch(nearbyDevicesProvider.select((s) => s.allDevices)).values.where((device) => device.ip != null).toList()
      ..sort((a, b) => a.alias.compareTo(b.alias));
    return SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(strings.chooseDevice, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _inputController,
                  enabled: !_connecting,
                  decoration: InputDecoration(
                    hintText: strings.inputHint,
                    isDense: true,
                  ),
                  onChanged: (s) {
                    setState(() => _input = s);
                  },
                  onFieldSubmitted: (s) => _connectAddress(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _connecting ? null : _connectAddress,
                child: Text(strings.connect),
              ),
            ],
          ),
          if (_inputError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _inputError!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_inputDevice != null) ...[
            const SizedBox(height: 8),
            _DeviceTile(
              device: _inputDevice!,
              selected: _selected == _inputDevice,
              onTap: _selectInputDevice,
            ),
          ],
          const SizedBox(height: 14),
          Text(strings.nearbyDevices, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Flexible(
            child: nearbyDevices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(strings.noDevicesFound, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final device in nearbyDevices)
                        _DeviceTile(
                          device: device,
                          selected: _selected == device,
                          onTap: () {
                            setState(() {
                              _selected = device;
                            });
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A row showing a device, tappable to select it.
class _DeviceTile extends StatelessWidget {
  final Device device;
  final bool selected;
  final VoidCallback onTap;

  const _DeviceTile({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = Color.lerp(Theme.of(context).colorScheme.secondaryContainer, Colors.white, 0.3)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      child: ListTile(
        dense: true,
        leading: Icon(device.deviceType.icon),
        title: Text(device.alias, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Row(
          children: [
            Flexible(
              child: Text(
                '${device.ip}${device.https ? ':${device.port}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            DeviceBadge(
              backgroundColor: badgeColor,
              foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
              label: 'HTTP',
            ),
            if (device.deviceModel != null) ...[
              const SizedBox(width: 6),
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: device.deviceModel!,
              ),
            ],
          ],
        ),
        trailing: selected ? const Icon(Icons.check, color: Colors.green) : null,
        onTap: onTap,
      ),
    );
  }
}

/// A small row with a spinner, shown while the sync folder info is fetched.
class _QueryRow extends StatelessWidget {
  const _QueryRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(t.dialogs.syncDevice.querying, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

/// The result of the sync folder query.
sealed class _SyncFolderInfo {
  const _SyncFolderInfo();
}

/// The peer has a sync folder configured.
class _SyncFolderInfoData extends _SyncFolderInfo {
  final SyncFolderInfoDtoV2 info;

  const _SyncFolderInfoData(this.info);
}

/// The peer responded with 204: no sync folder configured.
class _SyncFolderInfoNotConfigured extends _SyncFolderInfo {
  const _SyncFolderInfoNotConfigured();
}

/// The query failed.
class _SyncFolderInfoError extends _SyncFolderInfo {
  final String message;

  const _SyncFolderInfoError(this.message);
}

/// A snapshot of the running mirror sync (step 3), rendered in the dialog.
sealed class _SyncProgress {
  const _SyncProgress();
}

/// The sender's folder is being scanned and hashed.
class _SyncProgressScanning extends _SyncProgress {
  final int processed;
  final int total;

  const _SyncProgressScanning({required this.processed, required this.total});
}

/// The manifest was answered: the destination will receive these uploads and
/// deletions to mirror the sender's folder.
class _SyncProgressDiff extends _SyncProgress {
  final int upload;
  final int delete;

  const _SyncProgressDiff({required this.upload, required this.delete});
}

/// The files of the diff are being uploaded.
class _SyncProgressUploading extends _SyncProgress {
  const _SyncProgressUploading();
}

/// The destination's commit deleted its extra files.
class _SyncProgressCommitted extends _SyncProgress {
  final int deleted;

  const _SyncProgressCommitted(this.deleted);
}

/// The mirror finished successfully.
class _SyncProgressDone extends _SyncProgress {
  final int uploaded;
  final int deleted;

  const _SyncProgressDone({required this.uploaded, required this.deleted});
}

/// The mirror failed; no commit was applied for the failed phases.
class _SyncProgressFailed extends _SyncProgress {
  final String error;

  const _SyncProgressFailed(this.error);
}

/// The mirror was canceled by the user.
class _SyncProgressCanceled extends _SyncProgress {
  const _SyncProgressCanceled();
}
