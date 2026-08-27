import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/widget/device_bage.dart';
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
class SyncDeviceDialog extends StatefulWidget {
  const SyncDeviceDialog();

  @override
  State<SyncDeviceDialog> createState() => _SyncDeviceDialogState();
}

/// LocalSend default port, used when a URL has no explicit port.
const _defaultPort = 53317;

class _SyncDeviceDialogState extends State<SyncDeviceDialog> with Refena {
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

  @override
  Widget build(BuildContext context) {
    final strings = t.dialogs.syncDevice;
    return AlertDialog(
      title: Text(strings.title),
      content: _showDetails ? _buildDetails(context) : _buildDeviceList(context),
      actions: [
        if (_showDetails)
          TextButton(
            onPressed: () {
              setState(() {
                _showDetails = false;
              });
            },
            child: Text(strings.back),
          ),
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
        ],
      ),
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
