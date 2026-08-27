import 'package:refena_flutter/refena_flutter.dart';

/// The phase of an inbound sync (another device mirrors its folder into the
/// sync folder of this device).
enum SyncReceivePhase {
  /// No sync is running.
  idle,

  /// The sync folder is being scanned and hashed to answer the manifest.
  scanning,

  /// The manifest was applied; the initiator's uploads are in progress or
  /// were skipped (nothing to upload).
  applying,

  /// The commit succeeded: the folder now mirrors the initiator.
  committed,

  /// The commit failed (deleting the authorized files failed).
  failed,
}

/// The activity of the inbound sync engine, driven by the events of the
/// server isolate. Shown in the receive tab's sync folder section.
class SyncReceiveState {
  final SyncReceivePhase phase;

  /// The IP of the initiator, for display.
  final String? peerIp;

  /// Absolute path of the sync folder being mirrored, for display.
  final String? folderPath;

  final int scanProcessed;
  final int scanTotal;

  /// Files the initiator announced it will upload (its manifest diff).
  final int uploadCount;

  /// Files the initiator announced it will delete.
  final int deleteCount;

  /// Files that were actually deleted by the commit.
  final int committedDeletes;

  /// Why the commit failed, `null` otherwise.
  final String? error;

  const SyncReceiveState({
    required this.phase,
    this.peerIp,
    this.folderPath,
    this.scanProcessed = 0,
    this.scanTotal = 0,
    this.uploadCount = 0,
    this.deleteCount = 0,
    this.committedDeletes = 0,
    this.error,
  });

  SyncReceiveState copyWith({
    SyncReceivePhase? phase,
    String? peerIp,
    String? folderPath,
    int? scanProcessed,
    int? scanTotal,
    int? uploadCount,
    int? deleteCount,
    int? committedDeletes,
    String? error,
  }) {
    return SyncReceiveState(
      phase: phase ?? this.phase,
      peerIp: peerIp ?? this.peerIp,
      folderPath: folderPath ?? this.folderPath,
      scanProcessed: scanProcessed ?? this.scanProcessed,
      scanTotal: scanTotal ?? this.scanTotal,
      uploadCount: uploadCount ?? this.uploadCount,
      deleteCount: deleteCount ?? this.deleteCount,
      committedDeletes: committedDeletes ?? this.committedDeletes,
      error: error ?? this.error,
    );
  }
}

final syncReceiveProvider = ReduxProvider<SyncReceiveService, SyncReceiveState>(
  (ref) => SyncReceiveService(),
);

class SyncReceiveService extends ReduxNotifier<SyncReceiveState> {
  @override
  SyncReceiveState init() {
    return const SyncReceiveState(phase: SyncReceivePhase.idle);
  }
}

/// Starts scanning the sync folder to answer a manifest.
class SyncReceiveScanStartedAction extends ReduxAction<SyncReceiveService, SyncReceiveState> {
  final String folderPath;

  SyncReceiveScanStartedAction({required this.folderPath});

  @override
  SyncReceiveState reduce() {
    return SyncReceiveState(phase: SyncReceivePhase.scanning, folderPath: folderPath);
  }
}

/// Progress of the scan in progress.
class SyncReceiveScanProgressAction extends ReduxAction<SyncReceiveService, SyncReceiveState> {
  final int processed;
  final int total;

  SyncReceiveScanProgressAction({required this.processed, required this.total});

  @override
  SyncReceiveState reduce() {
    return state.copyWith(scanProcessed: processed, scanTotal: total);
  }
}

/// The manifest was applied; the initiator will upload/delete these counts.
class SyncReceiveManifestAction extends ReduxAction<SyncReceiveService, SyncReceiveState> {
  final String ip;
  final String folderPath;
  final int uploadCount;
  final int deleteCount;

  SyncReceiveManifestAction({
    required this.ip,
    required this.folderPath,
    required this.uploadCount,
    required this.deleteCount,
  });

  @override
  SyncReceiveState reduce() {
    return state.copyWith(
      phase: SyncReceivePhase.applying,
      peerIp: ip,
      folderPath: folderPath,
      uploadCount: uploadCount,
      deleteCount: deleteCount,
      error: null,
    );
  }
}

/// The commit was applied (or failed); the folder mirrors the initiator.
class SyncReceiveCommitAction extends ReduxAction<SyncReceiveService, SyncReceiveState> {
  final int deletedCount;
  final bool success;
  final String? error;

  SyncReceiveCommitAction({
    required this.deletedCount,
    required this.success,
    required this.error,
  });

  @override
  SyncReceiveState reduce() {
    return state.copyWith(
      phase: success ? SyncReceivePhase.committed : SyncReceivePhase.failed,
      committedDeletes: deletedCount,
      error: error,
    );
  }
}
