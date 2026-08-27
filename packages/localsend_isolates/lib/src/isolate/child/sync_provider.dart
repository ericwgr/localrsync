import 'package:dart_mappable/dart_mappable.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:refena_flutter/refena_flutter.dart';

part 'sync_provider.mapper.dart';

/// Represents the state that is synchronized from the main isolate to the child isolate.
/// In other words, the main isolate sends this state to the child isolate.
@MappableClass()
class SyncState with SyncStateMappable {
  final Object rootIsolateToken;
  final StoredSecurityContext securityContext;
  final DeviceInfoResult deviceInfo;
  final String alias;
  final int port;
  final List<String>? networkWhitelist;
  final List<String>? networkBlacklist;
  final ProtocolType protocol;
  final String multicastGroup;
  final int discoveryTimeout;

  final bool serverRunning;
  final bool download;

  /// Absolute path of the configured sync folder, or null when none is set.
  /// The server isolate uses it to answer sync manifests and to store the
  /// received files of a sync session.
  final String? syncFolderPath;

  SyncState({
    required this.rootIsolateToken,
    required this.securityContext,
    required this.deviceInfo,
    required this.alias,
    required this.port,
    required this.networkWhitelist,
    required this.networkBlacklist,
    required this.protocol,
    required this.multicastGroup,
    required this.discoveryTimeout,
    required this.serverRunning,
    required this.download,
    required this.syncFolderPath,
  });

  @override
  String toString() {
    return 'SyncState(securityContext: <SecurityContext>, deviceInfo: $deviceInfo, alias: $alias, port: $port, networkWhitelist: $networkWhitelist, networkBlacklist: $networkBlacklist, protocol: $protocol, multicastGroup: $multicastGroup, discoveryTimeout: $discoveryTimeout, serverRunning: $serverRunning, download: $download, syncFolderPath: $syncFolderPath)';
  }
}

final syncProvider = ReduxProvider<SyncService, SyncState>((ref) {
  throw 'Not initialized';
});

class SyncService extends ReduxNotifier<SyncState> {
  final SyncState initial;

  SyncService({
    required this.initial,
  });

  @override
  SyncState init() => initial;
}

class UpdateSyncStateAction extends ReduxAction<SyncService, SyncState> {
  final SyncState newState;

  UpdateSyncStateAction(this.newState);

  @override
  SyncState reduce() {
    return newState;
  }
}
