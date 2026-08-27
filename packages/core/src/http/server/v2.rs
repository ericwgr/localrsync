use crate::http::dto_v2::{
    InfoResponseDtoV2, PrepareUploadRequestDtoV2, PrepareUploadResponseDtoV2, RegisterDtoV2,
    RegisterResponseDtoV2, SyncCommitRequestV2, SyncDiffV2, SyncFolderInfoDtoV2,
    SyncManifestRequestV2,
};
use crate::http::server::common::collect_to_json::CollectToJson;
use crate::http::server::common::error::AppError;
use crate::http::server::common::pin::check_pin;
use crate::http::server::common::query::parse_query;
use crate::http::server::common::response::{empty_body, BoxedBody, JsonResponse};
use crate::http::server::common::save::{FileTimestamps, FileUploadTarget, SaveResult};
use crate::http::server::common::session::{
    FileStatusV2, PendingSessionV2, SessionFileV2, SessionStateV2, UploadSessionV2,
};
use crate::http::server::PeerIp;
use crate::http::server::{common, AppState, RequestClientInfo, SyncSessionV2, V2State};
use crate::model::discovery::PROTOCOL_VERSION_V2;
use crate::model::transfer::FileDto;
use hyper::body::Incoming;
use hyper::{Request, Response, StatusCode};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// Events emitted by the v2 HTTP server that must be handled by the application.
#[derive(Debug)]
pub enum ServerEventV2 {
    /// A device registered itself via `POST /api/localsend/v2/register`.
    ///
    /// On TLS, this event is only emitted when `info.fingerprint` matches the
    /// SHA-256 fingerprint of the client certificate verified during the mTLS
    /// handshake, so the fingerprint cannot be spoofed.
    Register {
        /// The IP address of the remote device.
        ip: PeerIp,

        /// The device information sent by the remote device.
        info: RegisterDtoV2,
    },

    /// A sender requests to upload files via `POST /api/localsend/v2/prepare-upload`.
    ///
    /// The application must answer on `decision_tx`.
    /// Dropping `decision_tx` results in a 500 response.
    PrepareUpload {
        /// The session ID the upload session will have when the request is
        /// accepted. Pre-generated so the application can track the session
        /// consistently from the start.
        session_id: String,

        /// The IP address of the sender.
        ip: PeerIp,

        /// The device information of the sender.
        info: RegisterDtoV2,

        /// The SHA-256 fingerprint (uppercase hex) of the sender's client
        /// certificate verified during the mTLS handshake. Unlike
        /// `info.fingerprint`, this value cannot be spoofed.
        /// `None` when the server runs without TLS.
        cert_fingerprint: Option<String>,

        /// The offered files, mapped by file ID.
        files: HashMap<String, FileDto>,

        /// Channel to send the decision (accept all, a subset, or decline).
        decision_tx: oneshot::Sender<PrepareUploadDecisionV2>,
    },

    /// An accepted file is being uploaded via `POST /api/localsend/v2/upload`.
    ///
    /// The application must answer on `target_tx` with where the file content
    /// should go (a stream to consume itself, a path, or a file descriptor).
    /// Dropping `target_tx` results in a 500 response.
    FileUpload {
        /// The session ID of the upload session.
        session_id: String,

        /// The ID of the file being uploaded.
        file_id: String,

        /// The metadata of the file being uploaded.
        file: FileDto,

        /// Channel to send the target the file content should be written to.
        target_tx: oneshot::Sender<FileUploadTarget>,
    },

    /// An upload session ended.
    SessionEnd {
        /// The session ID of the ended session.
        session_id: String,

        /// Why the session ended.
        reason: SessionEndReasonV2,
    },

    /// A prepare-upload request was aborted before a session was created,
    /// e.g. the sender disconnected while the application was still deciding.
    /// The `decision_tx` of the [ServerEventV2::PrepareUpload] with the same
    /// session ID is dead; answering it has no effect.
    PrepareUploadAborted {
        /// The session ID of the aborted prepare-upload request.
        session_id: String,
    },

    /// `POST /api/localsend/v2/cancel` was received for a session this server
    /// does not manage. This happens when the remote device cancels a transfer
    /// that this application is currently *sending* to it: the session ID is
    /// the one issued by the remote device during prepare-upload.
    ///
    /// The application must verify that `ip` matches the target of the
    /// send session before cancelling it.
    CancelReceived {
        /// The IP address of the remote device requesting the cancellation.
        ip: PeerIp,

        /// The session ID as known by the remote device.
        session_id: String,
    },

    /// The listening socket failed permanently, e.g. because the OS
    /// invalidated it while the application was suspended (iOS reclaims the
    /// sockets of suspended apps). The server has stopped itself; the
    /// application must restart it to become reachable again.
    ListenerFailed {
        /// Description of the failure.
        error: String,
    },

    /// A device requests the sync folder information via
    /// `POST /api/localsend/v2/sync-folder-info`.
    ///
    /// The application must answer on `response_tx`: `Some(info)` responds
    /// with the sync folder details, `None` with 204 (the sync folder is not
    /// configured). Dropping `response_tx` results in a 500 response.
    SyncFolderInfoRequested {
        /// The IP address of the requesting device.
        ip: PeerIp,

        /// The SHA-256 fingerprint (uppercase hex) of the requester's client
        /// certificate verified during the mTLS handshake. `None` when the
        /// server runs without TLS.
        cert_fingerprint: Option<String>,

        /// Channel to send the sync folder information to.
        response_tx: oneshot::Sender<Option<SyncFolderInfoDtoV2>>,
    },

    /// A sync initiator submits its directory listing via
    /// `POST /api/localsend/v2/sync/manifest`.
    ///
    /// The application must diff the listing against its own sync folder and
    /// answer on `response_tx` — [SyncManifestDecisionV2::Apply] with the
    /// computed diff (whose `delete_remote` then becomes committable under its
    /// session) or [SyncManifestDecisionV2::Reject]. Dropping `response_tx`
    /// results in a 500 response.
    SyncManifestRequested {
        /// The IP address of the initiator.
        ip: PeerIp,

        /// The SHA-256 fingerprint (uppercase hex) of the initiator's client
        /// certificate. The endpoint requires a verified certificate, so this
        /// is always `Some` for accepted requests.
        cert_fingerprint: Option<String>,

        /// The submitted manifest.
        manifest: SyncManifestRequestV2,

        /// The session that an [SyncManifestDecisionV2::Apply] must answer
        /// with. Pre-generated so the application does not invent it; only a
        /// diff carrying this ID is accepted.
        session_id: String,

        /// Channel to send the decision to.
        response_tx: oneshot::Sender<SyncManifestDecisionV2>,
    },

    /// A sync initiator requests the deletion of files via
    /// `POST /api/localsend/v2/sync/commit`.
    ///
    /// The submitted paths were verified to be authorized deletions of the
    /// session (a subset of the `delete_remote`/`delete_dirs` the application
    /// decided for the manifest). The application must delete them and answer
    /// on `response_tx`. Dropping `response_tx` results in a 500 response and
    /// the session stays authorized, so the initiator can retry.
    SyncCommitRequested {
        /// The IP address of the initiator.
        ip: PeerIp,

        /// The session ID (from [ServerEventV2::SyncManifestRequested]).
        session_id: String,

        /// The relative paths of files to delete from the sync folder, a subset of the
        /// authorized diff. Empty commits are answered without an event.
        delete_remote: Vec<String>,

        /// The relative paths of (empty) directories to delete, also a subset
        /// of the authorized diff.
        delete_dirs: Vec<String>,

        /// Channel to confirm the deletions were applied.
        response_tx: oneshot::Sender<()>,
    },
}

/// The application's decision for a sync manifest request.
#[derive(Debug)]
pub enum SyncManifestDecisionV2 {
    /// The sync is authorized. The diff is returned to the initiator and its
    /// `delete_remote` becomes committable under its session ID.
    Apply(SyncDiffV2),

    /// Reject the sync with a status code and an error message for the
    /// initiator.
    Reject {
        status: StatusCode,
        message: String,
    },
}

/// The application's decision for a prepare-upload request.
#[derive(Debug)]
pub enum PrepareUploadDecisionV2 {
    /// Accept the given file IDs (a subset of the offered files).
    /// An empty set responds with 204 (no file transfer needed).
    Accept(HashSet<String>),

    /// Decline the request (403).
    Decline,
}

/// Why an upload session ended.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionEndReasonV2 {
    /// All accepted files reached a final state (finished or failed).
    Finished,

    /// The sender cancelled the session via `POST /api/localsend/v2/cancel`.
    Cancelled,
}

pub(crate) async fn register(
    body: Incoming,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<JsonResponse<RegisterResponseDtoV2>, AppError> {
    let payload = body.collect_to_json::<RegisterDtoV2>().await?;

    // On TLS, only trust registrations whose claimed fingerprint is proven
    // by the client certificate of the mTLS handshake.
    let fingerprint_valid = match client_info.cert_fingerprint() {
        Some(cert_fingerprint) => payload.fingerprint.to_ascii_uppercase() == cert_fingerprint,
        None => true,
    };

    if let Some(v2) = &state.v2 {
        if fingerprint_valid {
            // Not awaited: registrations arrive in bursts (every device on the
            // network answers an announcement, and a peer scanning its subnet
            // registers with everyone), so the channel fills up easily. Waiting
            // would block this request handler — and every later one — until
            // the application catches up, which is what makes the device stop
            // answering `register` altogether.
            //
            // The event carries no responder, and peers repeat their
            // announcement, so a dropped registration is recoverable.
            if let Err(err) = v2.event_tx.try_send(ServerEventV2::Register {
                ip: client_info.ip,
                info: payload,
            }) {
                tracing::debug!("Dropped a register event: {err}");
            }
        } else {
            tracing::warn!(
                "Ignoring register from {}: claimed fingerprint does not match the client certificate",
                client_info.ip
            );
        }
    }

    let info = state.info.lock().await.clone();
    let download = state.web.share.download().is_some();

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: RegisterResponseDtoV2 {
            alias: info.alias,
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.token,
            download,
        },
    })
}

pub(crate) async fn info(state: AppState) -> Result<JsonResponse<InfoResponseDtoV2>, AppError> {
    let info = state.info.lock().await.clone();
    let download = state.web.share.download().is_some();

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: InfoResponseDtoV2 {
            alias: info.alias,
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.token,
            download,
        },
    })
}

/// Handles `POST /api/localsend/v2/sync-folder-info`.
///
/// The sync folder is not known to the server; the application answers via a
/// [ServerEventV2::SyncFolderInfoRequested] event. The response is 200 with
/// the folder details, or 204 when no sync folder is configured.
pub(crate) async fn sync_folder_info(
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;

    let (response_tx, response_rx) = oneshot::channel();
    let event = ServerEventV2::SyncFolderInfoRequested {
        ip: client_info.ip,
        cert_fingerprint: client_info.cert_fingerprint(),
        response_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    match response_rx.await {
        Ok(Some(info)) => Ok(JsonResponse {
            status: StatusCode::OK,
            body: info,
        }
        .into_response()),
        Ok(None) => {
            // 204 No Content: the device has no sync folder configured.
            let mut res = Response::new(empty_body());
            *res.status_mut() = StatusCode::NO_CONTENT;
            Ok(res)
        }
        Err(_) => Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR)),
    }
}

/// Handles `POST /api/localsend/v2/sync/manifest`.
///
/// The sync endpoints require TLS with a verified client certificate: the
/// certificate fingerprint is the only strong device identity in the
/// protocol, and a sync can delete files on this device. On a plain HTTP
/// connection every peer on the network could spoof the initiator, so such
/// requests are rejected.
///
/// The diff is computed by the application (it owns the sync folder and its
/// directory scanning); the server only stores the authorized deletions under
/// the pre-generated session so a later commit can be verified against them.
pub(crate) async fn sync_manifest(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());
    check_pin(
        v2.pin.as_deref(),
        &v2.pin_attempts,
        &query,
        client_info.ip.ip,
    )
    .await?;
    require_client_cert(&client_info)?;

    let payload = req
        .into_body()
        .collect_to_json::<SyncManifestRequestV2>()
        .await?;

    for file in &payload.files {
        if !is_safe_relative_path(&file.path) {
            return Err(AppError::BadRequest(format!(
                "Unsafe path in manifest: {}",
                file.path
            )));
        }
    }

    let session_id = Uuid::new_v4().to_string();
    let (response_tx, response_rx) = oneshot::channel();

    let event = ServerEventV2::SyncManifestRequested {
        ip: client_info.ip,
        cert_fingerprint: client_info.cert_fingerprint(),
        manifest: payload.clone(),
        session_id: session_id.clone(),
        response_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    let decision = response_rx
        .await
        .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?;

    match decision {
        SyncManifestDecisionV2::Apply(diff) => {
            if diff.session_id != session_id {
                return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
            }
            // Every authorized deletion must be safe and (re)validated here,
            // even though the manifest paths were checked above: the diff is
            // computed by the application, so its path claims are anchored on
            // the server side again before they become deletable.
            let deletes: HashSet<String> = diff
                .delete_remote
                .iter()
                .chain(diff.delete_dirs.iter())
                .filter(|path| is_safe_relative_path(path))
                .cloned()
                .collect();
            if deletes.len() != diff.delete_remote.len() + diff.delete_dirs.len() {
                return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
            }

            v2.sync_sessions.lock().await.insert(
                session_id.clone(),
                SyncSessionV2 {
                    sender_ip: client_info.ip,
                    authorized_deletes: deletes,
                },
            );

            Ok(JsonResponse {
                status: StatusCode::OK,
                body: diff,
            }
            .into_response())
        }
        SyncManifestDecisionV2::Reject { status, message } => {
            Err(AppError::Message(status, message))
        }
    }
}

/// Handles `POST /api/localsend/v2/sync/commit`.
///
/// Deletes the files the application authorized in the manifest decision.
/// The commit is the last step of a sync; the session is revoked once it
/// succeeded, so it cannot be reused.
pub(crate) async fn sync_commit(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());
    check_pin(
        v2.pin.as_deref(),
        &v2.pin_attempts,
        &query,
        client_info.ip.ip,
    )
    .await?;
    require_client_cert(&client_info)?;

    let payload = req
        .into_body()
        .collect_to_json::<SyncCommitRequestV2>()
        .await?;

    // Verify the deletion request against the authorized session without
    // consuming it yet: on failure the session stays, so the initiator can
    // retry the commit.
    {
        let sessions = v2.sync_sessions.lock().await;
        let Some(session) = sessions.get(&payload.session_id) else {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Unknown sync session".to_string(),
            ));
        };
        if session.sender_ip != client_info.ip {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Sync session of another device".to_string(),
            ));
        }
        if !payload.delete_remote.iter().all(|path| {
            is_safe_relative_path(path) && session.authorized_deletes.contains(path)
        }) || !payload.delete_dirs.iter().all(|path| {
            is_safe_relative_path(path) && session.authorized_deletes.contains(path)
        }) {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Unauthorized deletion".to_string(),
            ));
        }
    }

    if payload.delete_remote.is_empty() && payload.delete_dirs.is_empty() {
        // Nothing to delete; the session is done.
        v2.sync_sessions.lock().await.remove(&payload.session_id);
        return Ok(Response::new(empty_body()));
    }

    let (response_tx, response_rx) = oneshot::channel();
    let event = ServerEventV2::SyncCommitRequested {
        ip: client_info.ip,
        session_id: payload.session_id.clone(),
        delete_remote: payload.delete_remote,
        delete_dirs: payload.delete_dirs,
        response_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    // Only consume the session after the deletions were applied.
    if response_rx.await.is_ok() {
        v2.sync_sessions.lock().await.remove(&payload.session_id);
    } else {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    tracing::info!("Sync session committed: {}", payload.session_id);
    Ok(Response::new(empty_body()))
}

/// The sync endpoints require a verified client certificate (i.e. a TLS
/// connection); see [sync_manifest] for why.
fn require_client_cert(client_info: &RequestClientInfo) -> Result<(), AppError> {
    if client_info.cert_fingerprint().is_some() {
        Ok(())
    } else {
        Err(AppError::Message(
            StatusCode::FORBIDDEN,
            "Sync requires a TLS connection with a client certificate".to_string(),
        ))
    }
}

/// Whether a manifest/commit path is safe to store or delete within the sync
/// folder: not absolute, no `..` segments, no empty segments (no trailing
/// slash), no Windows-style separators.
fn is_safe_relative_path(path: &str) -> bool {
    !path.starts_with('/')
        && !path.contains('\\')
        && path != "."
        && path
            .split('/')
            .all(|segment| !segment.is_empty() && segment != "..")
}

pub(crate) async fn prepare_upload(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());

    check_pin(
        v2.pin.as_deref(),
        &v2.pin_attempts,
        &query,
        client_info.ip.ip,
    )
    .await?;

    let payload = req
        .into_body()
        .collect_to_json::<PrepareUploadRequestDtoV2>()
        .await?;

    if payload.files.is_empty() {
        return Err(AppError::BadRequest("No files provided".to_string()));
    }

    let session_id = Uuid::new_v4().to_string();
    let cancelled = CancellationToken::new();

    // Claim the single session slot.
    {
        let mut slot = v2.session.lock().await;
        if slot.is_some() {
            return Err(AppError::Message(
                StatusCode::CONFLICT,
                "Blocked by another session".to_string(),
            ));
        }
        *slot = Some(SessionStateV2::Pending(PendingSessionV2 {
            session_id: session_id.clone(),
            sender_ip: client_info.ip,
            cancel: cancelled.clone(),
        }));
    }

    // Frees the slot again if this request is aborted before a session is created.
    let mut pending_guard = PendingSessionGuard::new(v2.clone(), session_id.clone());

    let (decision_tx, decision_rx) = oneshot::channel();
    let event = ServerEventV2::PrepareUpload {
        session_id: session_id.clone(),
        ip: client_info.ip,
        info: payload.info,
        cert_fingerprint: client_info.cert_fingerprint(),
        files: payload.files.clone(),
        decision_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    // The sender may cancel the request while the application is deciding.
    // Returning with the guard still armed frees the slot and emits
    // [ServerEventV2::PrepareUploadAborted], like a dropped connection.
    let decision = tokio::select! {
        decision = decision_rx => {
            decision.map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?
        }
        _ = cancelled.cancelled() => {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Cancelled by sender".to_string(),
            ));
        }
    };

    let accepted_ids = match decision {
        PrepareUploadDecisionV2::Decline => {
            pending_guard.clear().await;
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Rejected".to_string(),
            ));
        }
        PrepareUploadDecisionV2::Accept(ids) => ids,
    };

    let files: HashMap<String, SessionFileV2> = payload
        .files
        .into_iter()
        .filter(|(id, _)| accepted_ids.contains(id))
        .map(|(id, dto)| {
            let file = SessionFileV2 {
                dto,
                token: Uuid::new_v4().to_string(),
                status: FileStatusV2::Pending,
                attempts: 0,
            };
            (id, file)
        })
        .collect();

    if files.is_empty() {
        // Nothing to transfer.
        pending_guard.clear().await;
        let mut res = Response::new(empty_body());
        *res.status_mut() = StatusCode::NO_CONTENT;
        return Ok(res);
    }

    let tokens: HashMap<String, String> = files
        .iter()
        .map(|(id, file)| (id.clone(), file.token.clone()))
        .collect();

    {
        let mut slot = v2.session.lock().await;
        *slot = Some(SessionStateV2::Active(UploadSessionV2 {
            session_id: session_id.clone(),
            sender_ip: client_info.ip,
            files,
        }));
    }
    pending_guard.disarm();

    tracing::info!("Upload session created: {session_id}");

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: PrepareUploadResponseDtoV2 {
            session_id,
            files: tokens,
        },
    }
    .into_response())
}

pub(crate) async fn upload(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());

    let (Some(session_id), Some(file_id), Some(token)) = (
        query.get("sessionId"),
        query.get("fileId"),
        query.get("token"),
    ) else {
        return Err(AppError::Message(
            StatusCode::BAD_REQUEST,
            "Missing parameters".to_string(),
        ));
    };

    // Validate the request and mark the file as in progress. The response
    // message names the exact guard that failed, so a failing sync shows
    // which one it is instead of a generic "Invalid token or IP address".
    let file_dto = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            match &*slot {
                Some(SessionStateV2::Pending(pending)) => {
                    // The prepare-upload for this session was answered with a
                    // decision, but the upload still arrived while the session
                    // is pending (waiting for the application's decision).
                    tracing::warn!(
                        "Upload rejected: session {} is still pending (waiting for the decision); active session would be {}",
                        session_id,
                        pending.session_id
                    );
                    return Err(AppError::Message(
                        StatusCode::FORBIDDEN,
                        "The upload session is still waiting for the decision".to_string(),
                    ));
                }
                None => {
                    tracing::warn!("Upload rejected: no active upload session (requested {session_id})");
                    return Err(AppError::Message(
                        StatusCode::FORBIDDEN,
                        "No active upload session".to_string(),
                    ));
                }
                // The else branch of the let-else above, unreachable here.
                Some(SessionStateV2::Active(_)) => unreachable!(),
            }
        };
        if session.session_id != *session_id {
            tracing::warn!(
                "Upload rejected: session {} does not match the active session {}",
                session_id,
                session.session_id
            );
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Upload session mismatch".to_string(),
            ));
        }
        if session.sender_ip != client_info.ip {
            tracing::warn!(
                "Upload rejected: sender {} does not match the session's sender {}",
                client_info.ip,
                session.sender_ip
            );
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "The upload comes from a different IP address than the prepare-upload".to_string(),
            ));
        }
        let Some(file) = session.files.get_mut(file_id) else {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "File is not part of this session".to_string(),
            ));
        };
        if file.token != *token {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Invalid file token".to_string(),
            ));
        }
        if file.status != FileStatusV2::Pending {
            tracing::warn!(
                "Upload rejected: file {} is {:?}, not Pending (a previous attempt may have failed)",
                file_id,
                file.status
            );
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "The file is still in progress or marked as failed: a previous attempt left it in this state".to_string(),
            ));
        }
        file.status = FileStatusV2::InProgress;
        file.attempts = file.attempts.saturating_add(1);
        file.dto.clone()
    };

    // Marks the file as failed if this request is aborted mid-transfer.
    let mut upload_guard = UploadGuard::new(v2.clone(), session_id.clone(), file_id.clone());

    let file_size = file_dto.size;
    let expected_sha256 = match v2.verify_checksums {
        true => file_dto.sha256.clone(),
        false => None,
    };
    let timestamps = match &file_dto.metadata {
        Some(metadata) => FileTimestamps {
            modified: metadata.modified_time(),
            accessed: metadata.accessed_time(),
        },
        None => FileTimestamps::default(),
    };
    let (target_tx, target_rx) = oneshot::channel::<FileUploadTarget>();

    let event = ServerEventV2::FileUpload {
        session_id: session_id.clone(),
        file_id: file_id.clone(),
        file: file_dto,
        target_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        upload_guard.finish(SaveResult::Failed).await;
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    let Ok(target) = target_rx.await else {
        upload_guard.finish(SaveResult::Failed).await;
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    };

    let result = common::save::save_req_to_target(
        req,
        target,
        file_size,
        expected_sha256.as_deref(),
        timestamps,
    )
    .await;

    upload_guard.finish(result).await;

    match result {
        SaveResult::Success => Ok(Response::new(empty_body())),
        SaveResult::Failed => Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR)),
        SaveResult::HashMismatch => Err(AppError::Message(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Checksum mismatch".to_string(),
        )),
    }
}

pub(crate) async fn cancel(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());
    let session_id = query.get("sessionId");

    // A pending prepare-upload request: the sender does not know the session
    // ID yet (it is part of the response), so a cancel from the pending
    // sender's address is accepted without one.
    let pending_cancelled = {
        let slot = v2.session.lock().await;
        match slot.as_ref() {
            Some(SessionStateV2::Pending(pending))
                if pending.sender_ip == client_info.ip
                    && session_id.is_none_or(|id| *id == pending.session_id) =>
            {
                tracing::info!(
                    "Pending upload session cancelled by sender: {}",
                    pending.session_id
                );
                // The waiting prepare-upload handler frees the slot and
                // notifies the application.
                pending.cancel.cancel();
                true
            }
            _ => false,
        }
    };

    if pending_cancelled {
        return Ok(Response::new(empty_body()));
    }

    if let Some(session_id) = session_id {
        let cancelled = {
            let mut slot = v2.session.lock().await;
            match slot.as_ref() {
                Some(SessionStateV2::Active(session))
                    if session.session_id == *session_id && session.sender_ip == client_info.ip =>
                {
                    *slot = None;
                    true
                }
                _ => false,
            }
        };

        if cancelled {
            tracing::info!("Upload session cancelled by sender: {session_id}");
            let _ = v2
                .event_tx
                .send(ServerEventV2::SessionEnd {
                    session_id: session_id.clone(),
                    reason: SessionEndReasonV2::Cancelled,
                })
                .await;
        } else {
            // Not one of our upload sessions: the remote device may be
            // cancelling a transfer this application is sending to it.
            let _ = v2
                .event_tx
                .send(ServerEventV2::CancelReceived {
                    ip: client_info.ip,
                    session_id: session_id.clone(),
                })
                .await;
        }
    }

    Ok(Response::new(empty_body()))
}

fn require_v2(state: &AppState) -> Result<Arc<V2State>, AppError> {
    state
        .v2
        .clone()
        .ok_or(AppError::Status(StatusCode::NOT_FOUND))
}

/// Frees a claimed `Pending` session slot unless a session was created.
///
/// The cleanup also runs on drop so the slot is not leaked
/// when the request future is cancelled (e.g. the sender disconnected
/// while the application was still deciding).
struct PendingSessionGuard {
    v2: Arc<V2State>,
    session_id: String,
    armed: bool,
}

impl PendingSessionGuard {
    fn new(v2: Arc<V2State>, session_id: String) -> Self {
        Self {
            v2,
            session_id,
            armed: true,
        }
    }

    /// Disarms the guard after the pending slot was replaced by an active session.
    fn disarm(&mut self) {
        self.armed = false;
    }

    /// Frees the pending slot immediately.
    async fn clear(&mut self) {
        self.armed = false;
        clear_pending_session(&self.v2).await;
    }
}

impl Drop for PendingSessionGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let v2 = self.v2.clone();
        let session_id = std::mem::take(&mut self.session_id);
        tokio::spawn(async move {
            clear_pending_session(&v2).await;
            // The application may still be waiting for a decision; tell it
            // that answering is pointless now.
            let _ = v2
                .event_tx
                .send(ServerEventV2::PrepareUploadAborted { session_id })
                .await;
        });
    }
}

async fn clear_pending_session(v2: &V2State) {
    let mut slot = v2.session.lock().await;
    if matches!(*slot, Some(SessionStateV2::Pending(_))) {
        *slot = None;
    }
}

/// Sets the final status of a file after an upload attempt.
///
/// The cleanup also runs on drop (as a failure) so the file is not stuck
/// in progress when the request future is cancelled mid-transfer.
struct UploadGuard {
    v2: Arc<V2State>,
    session_id: String,
    file_id: String,
    armed: bool,
}

impl UploadGuard {
    fn new(v2: Arc<V2State>, session_id: String, file_id: String) -> Self {
        Self {
            v2,
            session_id,
            file_id,
            armed: true,
        }
    }

    async fn finish(&mut self, result: SaveResult) {
        self.armed = false;
        finalize_file(&self.v2, &self.session_id, &self.file_id, result).await;
    }
}

impl Drop for UploadGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let v2 = self.v2.clone();
        let session_id = std::mem::take(&mut self.session_id);
        let file_id = std::mem::take(&mut self.file_id);
        tokio::spawn(async move {
            finalize_file(&v2, &session_id, &file_id, SaveResult::Failed).await;
        });
    }
}

/// How often an upload of the same file may be started, i.e. how often a
/// sender may retry a file after a checksum mismatch.
/// Senders must not retry more often than this (see the upload isolate).
const MAX_UPLOAD_ATTEMPTS: u8 = 3;

/// Sets the final status of a file and ends the session once all files are done.
///
/// A checksum mismatch resets the file to [FileStatusV2::Pending] (as long as
/// [MAX_UPLOAD_ATTEMPTS] is not exhausted) so the sender can retry the upload
/// with the same token; the session stays active in that case.
async fn finalize_file(v2: &V2State, session_id: &str, file_id: &str, result: SaveResult) {
    let session_ended = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            return;
        };
        if session.session_id != session_id {
            return;
        }
        if let Some(file) = session.files.get_mut(file_id) {
            if file.status == FileStatusV2::InProgress {
                file.status = match result {
                    SaveResult::Success => FileStatusV2::Finished,
                    SaveResult::HashMismatch if file.attempts < MAX_UPLOAD_ATTEMPTS => {
                        FileStatusV2::Pending
                    }
                    SaveResult::Failed | SaveResult::HashMismatch => FileStatusV2::Failed,
                };
            }
        }
        match session.is_complete() {
            true => {
                *slot = None;
                true
            }
            false => false,
        }
    };

    if session_ended {
        tracing::info!("Upload session finished: {session_id}");
        let _ = v2
            .event_tx
            .send(ServerEventV2::SessionEnd {
                session_id: session_id.to_string(),
                reason: SessionEndReasonV2::Finished,
            })
            .await;
    }
}
