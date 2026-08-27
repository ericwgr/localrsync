import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/directory_size.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// State of the "sync folder" feature on the receive tab: the path of the
/// configured folder plus the last known folder size (cached on disk, so it
/// survives restarts).
class SyncFolderState {
  /// Absolute path of the configured sync folder, or null if not set.
  final String? path;

  /// Total size of the folder in bytes, from the last successful
  /// calculation. Null when never calculated.
  final int? sizeBytes;

  /// Whether a size calculation is currently running.
  final bool loading;

  /// Whether the last calculation failed (e.g. unreachable storage,
  /// permission error, or web where the file system is not accessible).
  final bool unavailable;

  const SyncFolderState({
    required this.path,
    required this.sizeBytes,
    required this.loading,
    required this.unavailable,
  });

  SyncFolderState copyWith({
    String? path,
    int? sizeBytes,
    bool? loading,
    bool? unavailable,
  }) {
    return SyncFolderState(
      path: path ?? this.path,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      loading: loading ?? this.loading,
      unavailable: unavailable ?? this.unavailable,
    );
  }
}

final syncFolderProvider = ReduxProvider<SyncFolderService, SyncFolderState>(
  (ref) => SyncFolderService(ref.read(persistenceProvider)),
);

class SyncFolderService extends ReduxNotifier<SyncFolderState> {
  final PersistenceService _persistence;

  SyncFolderService(this._persistence);

  @override
  SyncFolderState init() {
    return SyncFolderState(
      path: _persistence.getSyncFolderPath(),
      sizeBytes: _persistence.getSyncFolderSizeBytes(),
      loading: false,
      unavailable: false,
    );
  }
}

/// Shows [path] as the active sync folder while its size is recalculated.
/// The path is only persisted once the calculation succeeds (see
/// [ChangeSyncFolderAction]).
class SyncFolderPathAction extends ReduxAction<SyncFolderService, SyncFolderState> {
  final String path;

  SyncFolderPathAction(this.path);

  @override
  SyncFolderState reduce() => state.copyWith(path: path, sizeBytes: null, loading: true, unavailable: false);
}

/// Sets the loading state while the folder size is being calculated.
class SyncFolderLoadingAction extends ReduxAction<SyncFolderService, SyncFolderState> {
  @override
  SyncFolderState reduce() => state.copyWith(loading: true, unavailable: false);
}

/// Selects [path] as the sync folder, persists it and immediately
/// recalculates the folder size.
class ChangeSyncFolderAction extends AsyncReduxAction<SyncFolderService, SyncFolderState> {
  final String path;

  ChangeSyncFolderAction(this.path);

  @override
  Future<SyncFolderState> reduce() async {
    await notifier._persistence.setSyncFolderPath(path);
    // Show the new path right away (with a loading indicator), so the state
    // does not wait for the size calculation to finish.
    dispatch(SyncFolderPathAction(path));
    final size = await _calculateSize(path);
    await notifier._persistence.setSyncFolderSizeBytes(size);
    return notifier.state.copyWith(sizeBytes: size, loading: false, unavailable: size == null);
  }
}

/// Re-calculates the size of the currently configured sync folder.
class RefreshSyncFolderSizeAction extends AsyncReduxAction<SyncFolderService, SyncFolderState> {
  @override
  Future<SyncFolderState> reduce() async {
    final path = notifier.state.path;
    if (path == null) {
      return state;
    }
    dispatch(SyncFolderLoadingAction());
    final size = await _calculateSize(path);
    await notifier._persistence.setSyncFolderSizeBytes(size);
    return notifier.state.copyWith(sizeBytes: size, loading: false, unavailable: size == null);
  }
}

/// Returns the folder size in bytes, or null when the calculation failed.
Future<int?> _calculateSize(String path) async {
  try {
    return await calculateDirectorySize(path);
  } catch (_) {
    return null;
  }
}
