import 'package:flutter/services.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/cancel.dart';
import 'package:localsend_isolates/rust/api/http.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/src/isolate/child/http_provider.dart';
import 'package:localsend_isolates/src/isolate/child/main.dart';
import 'package:localsend_isolates/src/isolate/dto/send_to_isolate_data.dart';
import 'package:localsend_isolates/src/task/sync/sync_scanner.dart';
import 'package:localsend_isolates/src/task/upload/http_upload.dart';
import 'package:localsend_isolates/util/android_channel.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:pool/pool.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:typed_isolates/typed_isolates.dart';

final _logger = Logger('HttpUploadIsolate');

/// How many files of a [HttpUploadFilesTask] are uploaded in parallel.
const _concurrency = 2;

/// How often a single file is uploaded at most when the receiver keeps
/// rejecting it with a checksum mismatch (HTTP 422).
/// Must not exceed MAX_UPLOAD_ATTEMPTS of the Rust server which stops
/// accepting retries at some point.
const _maxUploadAttempts = 3;

sealed class BaseHttpUploadTask {}

class HttpUploadFile {
  final String remoteFileToken;
  final String fileId;
  final String? filePath;
  final List<int>? fileBytes;
  final int fileSize;

  HttpUploadFile({
    required this.remoteFileToken,
    required this.fileId,
    required this.filePath,
    required this.fileBytes,
    required this.fileSize,
  });
}

/// Uploads a list of files as one isolate task.
///
/// This task is intended to replace the file scheduling loop in the parent
/// isolate. Up to [_concurrency] files are uploaded in parallel and progress
/// is reported across the complete list.
class HttpUploadFilesTask implements BaseHttpUploadTask {
  final String? remoteSessionId;
  final List<HttpUploadFile> files;
  final Device device;

  HttpUploadFilesTask({
    required this.remoteSessionId,
    required this.files,
    required this.device,
  });
}

class HttpUploadCancelTask implements BaseHttpUploadTask {
  final int taskId;

  HttpUploadCancelTask({required this.taskId});
}

/// How many sync files are uploaded in parallel.
const _syncConcurrency = 4;

/// Mirrors the folder at [localPath] into the sync folder of [device]
/// (LocalRsync extension, one-way local → remote).
///
/// The engine scans and hashes the folder, submits the listing as a sync
/// manifest, uploads the files the destination's diff says are missing or
/// changed (up to [_syncConcurrency] in parallel, reusing the regular
/// LocalSend upload mechanism) and finally commits, which deletes the files
/// the destination has but the sender does not. The task emits
/// [HttpSyncEvent]s and completes (with the stream's completion) only after
/// the commit, so the destination's folder mirrors the sender's.
class HttpSyncPushTask implements BaseHttpUploadTask {
  /// Absolute path of the folder to mirror.
  final String local;

  /// The destination device.
  final Device device;

  HttpSyncPushTask({
    required this.local,
    required this.device,
  });
}

/// A message sent from the upload isolate to the main isolate reporting the
/// progress of a [HttpSyncPushTask].
///
/// Extends [HttpUploadEvent] (with an empty [HttpUploadEvent.fileId]) so the
/// events fit the upload isolate's typed channel.
sealed class HttpSyncEvent extends HttpUploadEvent {
  const HttpSyncEvent() : super(fileId: '');
}

/// The scan of the sender's folder has begun; [total] files will be hashed.
class HttpSyncScanStartedEvent extends HttpSyncEvent {
  final int total;

  HttpSyncScanStartedEvent({required this.total});
}

/// [processed] of [total] files of the sender's folder have been hashed.
class HttpSyncScanProgressEvent extends HttpSyncEvent {
  final int processed;
  final int total;

  HttpSyncScanProgressEvent({
    required this.processed,
    required this.total,
  });
}

/// The destination has diffed its folder against the listing: these files
/// will be uploaded and these files/directories deleted to make it mirror
/// the sender.
class HttpSyncDiffEvent extends HttpSyncEvent {
  final List<String> needUpload;
  final List<String> deleteRemote;

  /// Destination-only directories whose whole content is being deleted,
  /// deepest-first.
  final List<String> deleteDirs;

  HttpSyncDiffEvent({
    required this.needUpload,
    required this.deleteRemote,
    required this.deleteDirs,
  });
}

/// One of the files of the diff started uploading.
class HttpSyncFileStartedEvent extends HttpSyncEvent {
  final String path;

  HttpSyncFileStartedEvent({required this.path});
}

/// Upload progress of a file of the diff in the range [0, 1].
class HttpSyncFileProgressEvent extends HttpSyncEvent {
  final String path;
  final double progress;

  HttpSyncFileProgressEvent({
    required this.path,
    required this.progress,
  });
}

/// A file of the diff has been uploaded successfully.
class HttpSyncFileFinishedEvent extends HttpSyncEvent {
  final String path;

  HttpSyncFileFinishedEvent({required this.path});
}

/// The commit was applied on the destination: [deletedCount] files were
/// deleted there. The destination's folder now mirrors the sender's.
class HttpSyncCommittedEvent extends HttpSyncEvent {
  final int deletedCount;

  HttpSyncCommittedEvent({required this.deletedCount});
}

/// The mirror finished successfully. [HttpSyncCommittedEvent] precedes this
/// unless nothing had to be deleted.
class HttpSyncFinishedEvent extends HttpSyncEvent {}

/// The mirror failed; no commit was applied for the failed phases.
/// The task still completes normally.
class HttpSyncFailedEvent extends HttpSyncEvent {
  /// The phase that failed: 'scan', 'manifest', 'upload' or 'commit'.
  final String phase;

  final String error;

  HttpSyncFailedEvent({
    required this.phase,
    required this.error,
  });
}

/// A message sent from the upload isolate to the main isolate
/// reporting the state of a single file of a [HttpUploadFilesTask].
sealed class HttpUploadEvent {
  final String fileId;

  const HttpUploadEvent({required this.fileId});
}

/// The upload of the file has started.
class HttpUploadFileStartedEvent extends HttpUploadEvent {
  HttpUploadFileStartedEvent({required super.fileId});
}

/// The upload progress of the file in the range [0, 1].
class HttpUploadFileProgressEvent extends HttpUploadEvent {
  final double progress;

  HttpUploadFileProgressEvent({
    required super.fileId,
    required this.progress,
  });
}

/// The file has been uploaded successfully.
class HttpUploadFileFinishedEvent extends HttpUploadEvent {
  HttpUploadFileFinishedEvent({required super.fileId});
}

/// The upload of the file has failed. The next file is still uploaded.
class HttpUploadFileFailedEvent extends HttpUploadEvent {
  final String error;

  HttpUploadFileFailedEvent({
    required super.fileId,
    required this.error,
  });
}

/// Map of cancel tokens for each task.
/// Task ID -> CancelToken
final _cancelTokenProvider = Provider((ref) => <int, RsCancellationToken>{});

Future<void> setupHttpUploadIsolate(
  Stream<SendToIsolateData<IsolateTask<BaseHttpUploadTask>>> receiveFromMain,
  void Function(IsolateTaskStreamResult<HttpUploadEvent>) sendToMain,
  InitialData initialData,
) async {
  await setupChildIsolateHelper(
    debugLabel: 'HttpUploadIsolate',
    receiveFromMain: receiveFromMain,
    sendToMain: sendToMain,
    initialData: initialData,
    init: (ref) async {
      // Initialize the platform method channel so getFileDescriptorAndroid
      // (used to resolve "content://" files) works inside this isolate.
      BackgroundIsolateBinaryMessenger.ensureInitialized(
        ref.read(syncProvider).rootIsolateToken as RootIsolateToken,
      );
    },
    handler: (ref, task) async {
      final HttpUploadFilesTask uploadTask;
      switch (task.data) {
        case HttpSyncPushTask syncTask:
          await _runSyncPush(
            ref: ref,
            taskId: task.id,
            task: syncTask,
            sendToMain: sendToMain,
          );
          return;
        case HttpUploadFilesTask task:
          uploadTask = task;
          break;
        case HttpUploadCancelTask task:
          final cancelToken = ref.read(_cancelTokenProvider)[task.taskId];
          cancelToken?.cancel();
          ref.read(_cancelTokenProvider).remove(task.taskId);
          return;
      }

      // One client for the whole task: pinned to the receiver, so no file
      // content can be streamed to a different peer, and shared by all files
      // of the task so the connection is reused.
      final client = ref.read(httpProvider).pinnedTo(uploadTask.device.fingerprint);

      final cancelToken = createCancellationToken();
      ref.read(_cancelTokenProvider).putIfAbsent(task.id, () => cancelToken);
      try {
        await Pool(_concurrency).forEach<HttpUploadFile, void>(uploadTask.files, (file) async {
          if (!ref.read(_cancelTokenProvider).containsKey(task.id)) {
            // the task was canceled, do not upload the remaining files
            return;
          }

          sendToMain(
            IsolateTaskStreamResult.event(
              id: task.id,
              data: HttpUploadFileStartedEvent(fileId: file.fileId),
            ),
          );

          try {
            final filePath = file.filePath;
            final isContentUri = filePath?.startsWith('content://') ?? false;

            for (var attempt = 1; ; attempt++) {
              // The file descriptor is consumed by the upload, so a fresh one
              // is needed for every attempt.
              final fileDescriptor = isContentUri ? await getFileDescriptorAndroid(uri: filePath!) : null;

              try {
                await ref
                    .read(httpUploadProvider)
                    .upload(
                      client: client,
                      stream: filePath == null && file.fileBytes != null ? Stream.value(file.fileBytes!) : null,
                      path: !isContentUri ? filePath : null,
                      fileDescriptor: fileDescriptor,
                      contentLength: file.fileSize,
                      target: uploadTask.device,
                      remoteSessionId: uploadTask.remoteSessionId,
                      fileId: file.fileId,
                      token: file.remoteFileToken,
                      onSendProgress: (progress) {
                        sendToMain(
                          IsolateTaskStreamResult.event(
                            id: task.id,
                            data: HttpUploadFileProgressEvent(
                              fileId: file.fileId,
                              progress: progress,
                            ),
                          ),
                        );
                      },
                      cancelToken: cancelToken,
                    );
                break;
              } on RsHttpClientError_StatusCode catch (e) {
                if (e.status != 422 || attempt >= _maxUploadAttempts) {
                  rethrow;
                }
                // The receiver discarded the file because its checksum did not
                // match (e.g. the file changed while being read). Send it again.
              }
            }

            sendToMain(
              IsolateTaskStreamResult.event(
                id: task.id,
                data: HttpUploadFileFinishedEvent(fileId: file.fileId),
              ),
            );
          } catch (e) {
            sendToMain(
              IsolateTaskStreamResult.event(
                id: task.id,
                data: HttpUploadFileFailedEvent(
                  fileId: file.fileId,
                  error: e.humanErrorMessage,
                ),
              ),
            );
          }
        }).drain<void>();

        sendToMain(
          IsolateTaskStreamResult.done(
            id: task.id,
          ),
        );
      } finally {
        ref.read(_cancelTokenProvider).remove(task.id);
      }
    },
  );
}

/// Runs a sync push (see [HttpSyncPushTask]): scan → manifest → parallel
/// uploads → commit. Every path of execution (success, failure, exception,
/// cancellation) ends with the task's stream completion.
Future<void> _runSyncPush({
  required Ref ref,
  required int taskId,
  required HttpSyncPushTask task,
  required void Function(IsolateTaskStreamResult<HttpSyncEvent>) sendToMain,
}) async {
  void emit(HttpSyncEvent event) {
    sendToMain(IsolateTaskStreamResult.event(id: taskId, data: event));
  }

  final cancelToken = createCancellationToken();
  ref.read(_cancelTokenProvider).putIfAbsent(taskId, () => cancelToken);
  try {
    // Phase 1: scan and hash the sender's folder.
    final List<SyncEntry> entries;
    try {
      entries = await scanSyncFolder(
        rootPath: task.local,
        cancelToken: cancelToken,
        onProgress: (processed, total) {
          if (processed == 0) {
            emit(HttpSyncScanStartedEvent(total: total));
          }
          emit(HttpSyncScanProgressEvent(processed: processed, total: total));
        },
      );
    } catch (e) {
      if (ref.read(_cancelTokenProvider).containsKey(taskId)) {
        emit(HttpSyncFailedEvent(phase: 'scan', error: e.humanErrorMessage));
      }
      return;
    }

    // Phase 2: submit the listing and let the destination compute the diff.
    final client = ref.read(httpProvider).pinnedTo(task.device.fingerprint);
    final RsSyncManifestResult manifestResult;
    try {
      manifestResult = await client.syncManifest(
        protocol: task.device.getProtocolType(),
        ip: task.device.ip!,
        port: task.device.port,
        folderId: 'default',
        files: [
          for (final entry in entries)
            SyncFileInfoV2(
              path: entry.relativePath,
              size: BigInt.from(entry.size),
              mtime: entry.mtime == null ? null : BigInt.from(entry.mtime!),
              sha256: entry.sha256,
              isDir: entry.isDir,
            ),
        ],
      );
    } catch (e) {
      if (ref.read(_cancelTokenProvider).containsKey(taskId)) {
        emit(HttpSyncFailedEvent(phase: 'manifest', error: e.humanErrorMessage));
      }
      return;
    }

    final SyncDiffV2 diff;
    switch (manifestResult) {
      case RsSyncManifestResult_Rejected(:final status, :final message):
        emit(HttpSyncFailedEvent(phase: 'manifest', error: '[$status] $message'));
        return;
      case RsSyncManifestResult_Diff(:final field0):
        diff = field0;
    }
    emit(
      HttpSyncDiffEvent(
        needUpload: diff.needUpload,
        deleteRemote: diff.deleteRemote,
        deleteDirs: diff.deleteDirs,
      ),
    );

    // Phase 3: upload the missing or changed files, reusing the regular
    // LocalSend upload mechanism with a small pool. Files whose checksum the
    // receiver rejects (HTTP 422) are retried: the Rust server keeps them
    // Pending for a few attempts, so a file that changed between the scan and
    // the upload heals itself. Every other failure is final — the receiver
    // marks the file Failed, so a retry would only be rejected. All failures
    // are collected and reported with their exact error per file.
    final uploadFailures = <(String, String)>[];
    if (diff.needUpload.isNotEmpty) {
      final byPath = {for (final entry in entries) entry.relativePath: entry};

      final rust_model.PrepareUploadRequestDto requestPayload;
      try {
        requestPayload = rust_model.PrepareUploadRequestDto(
          info: task.device.toRegisterDto(),
          files: {
            for (final path in diff.needUpload)
              if (byPath[path] != null)
                path: rust_model.FileDto(
                  id: path,
                  fileName: path,
                  size: BigInt.from(byPath[path]!.size),
                  fileType: lookupMimeType(path) ?? 'application/octet-stream',
                  sha256: byPath[path]!.sha256,
                  preview: null,
                  metadata: rust_model.FileMetadata(
                    // The received files keep their modification time.
                    modified: DateTime.fromMillisecondsSinceEpoch((byPath[path]!.mtime ?? 0) * 1000, isUtc: true).toIso8601String(),
                    accessed: null,
                  ),
                ),
          },
        );
      } catch (e) {
        emit(HttpSyncFailedEvent(phase: 'upload', error: e.humanErrorMessage));
        return;
      }

      final PrepareUploadResult prepare;
      try {
        prepare = await client.prepareUpload(
          protocol: task.device.getProtocolType(),
          ip: task.device.ip!,
          port: task.device.port,
          payload: requestPayload,
          publicKey: null,
          pin: null,
          cancelToken: cancelToken,
        );
      } catch (e) {
        if (ref.read(_cancelTokenProvider).containsKey(taskId)) {
          emit(HttpSyncFailedEvent(phase: 'upload', error: e.humanErrorMessage));
        }
        return;
      }

      final sessionId = prepare.response?.sessionId;
      final tokens = prepare.response?.files ?? const <String, String>{};
      if (sessionId == null) {
        // 204: the destination accepted nothing, e.g. because its folder
        // changed since the diff.
        emit(HttpSyncFailedEvent(phase: 'upload', error: 'The destination accepted no file (HTTP ${prepare.statusCode})'));
        return;
      }

      await Pool(_syncConcurrency).forEach<String, void>(diff.needUpload, (path) async {
        if (!ref.read(_cancelTokenProvider).containsKey(taskId)) {
          // the task was canceled, do not upload the remaining files
          return;
        }

        final entry = byPath[path];
        final token = tokens[path];
        if (entry == null || token == null) {
          // The destination refused to authorize this file (e.g. its folder
          // changed between the diff and the prepare-upload).
          uploadFailures.add((path, 'the destination did not authorize this file'));
          return;
        }

        emit(HttpSyncFileStartedEvent(path: path));
        Object? lastError;
        var uploaded = false;
        for (var attempt = 1; attempt <= _maxUploadAttempts && !uploaded; attempt++) {
          try {
            await ref
                .read(httpUploadProvider)
                .upload(
                  client: client,
                  stream: null,
                  path: entry.absolutePath,
                  fileDescriptor: null,
                  contentLength: entry.size,
                  target: task.device,
                  remoteSessionId: sessionId,
                  fileId: path,
                  token: token,
                  onSendProgress: (progress) {
                    emit(HttpSyncFileProgressEvent(path: path, progress: progress));
                  },
                  cancelToken: cancelToken,
                );
            emit(HttpSyncFileFinishedEvent(path: path));
            uploaded = true;
          } on RsHttpClientError_StatusCode catch (e) {
            if (e.status == 422) {
              // Checksum mismatch: the receiver keeps the file Pending for
              // a few attempts (MAX_UPLOAD_ATTEMPTS in the Rust server), so
              // the same token can be retried.
              lastError = e;
              if (attempt < _maxUploadAttempts) {
                await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
              }
            } else {
              lastError = e;
              break; // not retryable: e.g. the receiver rejected the token
            }
          } catch (e) {
            if (!ref.read(_cancelTokenProvider).containsKey(taskId)) {
              // canceled while this file was uploading
              return;
            }
            lastError = e;
            break; // not retryable: the receiver marks the file Failed
          }
        }
        if (!uploaded) {
          _logger.warning('Sync upload of $path failed', lastError);
          uploadFailures.add((path, lastError == null ? 'unknown error' : lastError.humanErrorMessage));
        }
      }).drain<void>();

      if (!ref.read(_cancelTokenProvider).containsKey(taskId)) {
        // canceled: the commit must not delete anything on the destination.
        return;
      }
      if (uploadFailures.isNotEmpty) {
        emit(
          HttpSyncFailedEvent(
            phase: 'upload',
            error: formatUploadFailures(uploadFailures),
          ),
        );
        return;
      }
    }

    // Phase 4: commit — delete the destination's extra files and empty
    // directories. Only when every upload succeeded, so the destination
    // never loses data the initiator failed to provide.
    if (diff.deleteRemote.isNotEmpty || diff.deleteDirs.isNotEmpty) {
      try {
        await client.syncCommit(
          protocol: task.device.getProtocolType(),
          ip: task.device.ip!,
          port: task.device.port,
          sessionId: diff.sessionId,
          deleteRemote: diff.deleteRemote,
          deleteDirs: diff.deleteDirs,
        );
      } catch (e) {
        if (ref.read(_cancelTokenProvider).containsKey(taskId)) {
          emit(HttpSyncFailedEvent(phase: 'commit', error: e.humanErrorMessage));
        }
        return;
      }
      emit(
        HttpSyncCommittedEvent(deletedCount: diff.deleteRemote.length + diff.deleteDirs.length),
      );
    }

    emit(HttpSyncFinishedEvent());
  } finally {
    ref.read(_cancelTokenProvider).remove(taskId);
    sendToMain(IsolateTaskStreamResult.done(id: taskId));
  }
}

/// The error message of an [HttpSyncFailedEvent] with phase 'upload':
/// one line per failed file with its exact error, so a failing sync no
/// longer hides what went wrong behind a generic summary. At most
/// [_maxReportedFailures] files are listed.
String formatUploadFailures(List<(String, String)> failures) {
  var message = '${failures.length} file(s) failed to upload:';
  for (final (path, error) in failures.take(_maxReportedFailures)) {
    message += '\n• $path — $error';
  }
  final rest = failures.length - _maxReportedFailures;
  if (rest > 0) {
    message += '\n… and $rest more';
  }
  return message;
}

/// How many failed files [formatUploadFailures] lists before abbreviating.
const _maxReportedFailures = 5;
