use crate::api::cancel::RsCancellationToken;
use crate::api::stream;
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
pub use localsend::http::client::{ClientError, LsHttpClientVersion};
pub use localsend::http::dto::{
    PrepareUploadRequestDto, PrepareUploadResponseDto, PrepareUploadResult,
    RegisterDto, RegisterResponseDto,
};
pub use localsend::http::dto_v2::{
    SyncDiffV2, SyncFileInfoV2, SyncFolderInfoDtoV2, SyncManifestRequestV2,
};
use localsend::http::dto_v2::{SyncFolderInfoResultV2, SyncManifestResultV2};
use localsend::model::discovery::ProtocolType;
use localsend::util::error::ErrorChain;

pub struct RsHttpClient {
    inner: localsend::http::client::LsHttpClient,
}

/// Creates an HTTP client.
///
/// `expected_fingerprint` pins the peer to the certificate with that SHA-256
/// fingerprint (uppercase hex). It is enforced during the TLS handshake, so a
/// peer that does not present the expected certificate never receives the
/// request. Pass `None` only for discovery, where the peer is not known yet.
#[frb(sync)]
pub fn create_client(
    private_key: String,
    cert: String,
    version: LsHttpClientVersion,
    expected_fingerprint: Option<String>,
    timeout_ms: Option<u32>,
) -> Result<RsHttpClient, RsHttpClientError> {
    let inner = localsend::http::client::LsHttpClient::new(
        &private_key,
        &cert,
        version,
        expected_fingerprint,
        timeout_ms.map(|ms| std::time::Duration::from_millis(ms as u64)),
    )
    .map_err(RsHttpClientError::from)?;

    Ok(RsHttpClient { inner })
}

impl RsHttpClient {
    pub async fn register(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: RegisterDto,
    ) -> Result<ResultWithPublicKeyRegisterResponseDto, RsHttpClientError> {
        let response = self
            .inner
            .register(protocol, ip, port, payload)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(ResultWithPublicKeyRegisterResponseDto {
            public_key: response.public_key,
            body: response.body,
        })
    }

    pub async fn prepare_upload(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: PrepareUploadRequestDto,
        public_key: Option<String>,
        pin: Option<String>,
        cancel_token: &RsCancellationToken,
    ) -> Result<PrepareUploadResult, RsHttpClientError> {
        let response = self
            .inner
            .prepare_upload(
                protocol,
                ip,
                port,
                public_key,
                payload,
                pin.as_deref(),
                cancel_token.inner.clone(),
            )
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(response)
    }

    /// Uploads a single file, emitting [RsUploadEvent]s on [sink].
    ///
    /// Failures are emitted as [RsUploadEvent::Failed] instead of being
    /// returned: flutter_rust_bridge discards the returned `Result` of
    /// functions taking a [StreamSink], so a returned error would become an
    /// uncaught async error killing the calling isolate.
    pub async fn upload(
        &self,
        sink: StreamSink<RsUploadEvent>,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        public_key: Option<String>,
        session_id: &str,
        file_id: &str,
        token: &str,
        binary: Option<stream::Dart2RustStreamReceiver>,
        path: Option<String>,
        file_descriptor: Option<i32>,
        content_length: u64,
        cancel_token: &RsCancellationToken,
    ) {
        let result = async {
            let content = resolve_file_content(binary, path, file_descriptor)?;
            let last_emit = std::cell::Cell::new(None::<std::time::Instant>);
            let progress_sink = sink.clone();
            let progress = move |sent| {
                let now = std::time::Instant::now();
                let is_final = sent >= content_length;
                if !is_final {
                    if let Some(last) = last_emit.get() {
                        if now.duration_since(last) < std::time::Duration::from_millis(20) {
                            return;
                        }
                    }
                }
                last_emit.set(Some(now));
                let progress = if content_length == 0 {
                    1.0
                } else {
                    (sent as f64 / content_length as f64).min(1.0)
                };
                let _ = progress_sink.add(RsUploadEvent::Progress { progress });
            };

            self.inner
                .upload(
                    protocol,
                    ip,
                    port,
                    public_key,
                    session_id,
                    file_id,
                    token,
                    content,
                    progress,
                    cancel_token.inner.clone(),
                )
                .await
                .map_err(RsHttpClientError::from)?;

            Ok(())
        }
        .await;

        if let Err(error) = result {
            let _ = sink.add(RsUploadEvent::Failed { error });
        }
    }

    pub async fn cancel(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: &str,
    ) -> Result<(), RsHttpClientError> {
        self.inner
            .cancel(protocol, ip, port, session_id)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(())
    }

    /// Queries the sync folder information of another device.
    ///
    /// POST /api/localsend/v2/sync-folder-info (LocalRsync extension).
    /// Returns `null` when the peer has no sync folder configured (204).
    pub async fn sync_folder_info(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
    ) -> Result<Option<SyncFolderInfoDtoV2>, RsHttpClientError> {
        let result = self
            .inner
            .sync_folder_info(protocol, ip, port)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(match result {
            SyncFolderInfoResultV2::Info(info) => Some(info),
            SyncFolderInfoResultV2::NotConfigured => None,
        })
    }

    /// Submits a sync manifest to another device.
    ///
    /// POST /api/localsend/v2/sync/manifest (LocalRsync extension).
    ///
    /// The destination diffs its sync folder against the submitted listing
    /// and returns the files to upload and delete.
    pub async fn sync_manifest(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        folder_id: String,
        files: Vec<SyncFileInfoV2>,
    ) -> Result<RsSyncManifestResult, RsHttpClientError> {
        let result = self
            .inner
            .sync_manifest(protocol, ip, port, &folder_id, files)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(match result {
            SyncManifestResultV2::Diff(diff) => RsSyncManifestResult::Diff(diff),
            SyncManifestResultV2::Rejected { status, message } => {
                RsSyncManifestResult::Rejected { status, message }
            }
        })
    }

    /// Commits a sync session: asks the destination to delete the files and
    /// directories its diff authorized, which happens after all uploads
    /// succeeded.
    ///
    /// POST /api/localsend/v2/sync/commit (LocalRsync extension).
    pub async fn sync_commit(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: String,
        delete_remote: Vec<String>,
        delete_dirs: Vec<String>,
    ) -> Result<(), RsHttpClientError> {
        self.inner
            .sync_commit(protocol, ip, port, &session_id, delete_remote, delete_dirs)
            .await
            .map_err(RsHttpClientError::from)?;
        Ok(())
    }
}

fn resolve_file_content(
    binary: Option<stream::Dart2RustStreamReceiver>,
    path: Option<String>,
    file_descriptor: Option<i32>,
) -> Result<localsend::model::transfer::FileContent, RsHttpClientError> {
    match (binary, path, file_descriptor) {
        (Some(binary), None, None) => Ok(localsend::model::transfer::FileContent::Stream(
            binary.receiver,
        )),
        (None, Some(path), None) => Ok(localsend::model::transfer::FileContent::Path(path.into())),
        (None, None, Some(file_descriptor)) => {
            #[cfg(target_os = "android")]
            {
                Ok(localsend::model::transfer::FileContent::Fd(file_descriptor))
            }
            #[cfg(not(target_os = "android"))]
            {
                let _ = file_descriptor;
                Err(RsHttpClientError::Other(
                    "File descriptors are only supported on Android".into(),
                ))
            }
        }
        _ => Err(RsHttpClientError::Other(
            "Exactly one upload content source must be provided".into(),
        )),
    }
}

/// An event emitted while a file is being uploaded by [RsHttpClient::upload].
#[derive(Clone)]
pub enum RsUploadEvent {
    /// The upload progress as a fraction (0.0 to 1.0). Throttled.
    Progress { progress: f64 },

    /// The upload failed. Always the last event of the stream.
    Failed { error: RsHttpClientError },
}

/// Result of [RsHttpClient::sync_manifest].
#[derive(Clone)]
pub enum RsSyncManifestResult {
    /// The destination computed a diff; proceed with the sync.
    Diff(SyncDiffV2),

    /// The destination refused the sync (e.g. no sync folder configured or
    /// the sync was declined).
    Rejected { status: u16, message: String },
}

#[derive(Clone)]
pub enum RsHttpClientError {
    StatusCode {
        status: u16,
        message: Option<String>,
    },
    Reqwest(String),
    Json(String),
    Io(String),
    Other(String),
}

impl From<ClientError> for RsHttpClientError {
    fn from(e: ClientError) -> Self {
        match e {
            ClientError::StatusCode(e) => RsHttpClientError::StatusCode {
                status: e.status,
                message: e.message,
            },
            ClientError::Reqwest(e) => RsHttpClientError::Reqwest(ErrorChain(&e).to_string()),
            ClientError::Json(e) => RsHttpClientError::Json(e.to_string()),
            ClientError::Io(e) => RsHttpClientError::Io(e.to_string()),
            ClientError::Other(e) => RsHttpClientError::Other(e.to_string()),
            ClientError::Cancelled => RsHttpClientError::Other("Upload cancelled".to_string()),
        }
    }
}

#[frb(mirror(LsHttpClientVersion))]
pub enum _LsHttpClientVersion {
    V2,
    V3,
}

#[frb(mirror(PrepareUploadResult))]
pub struct _PrepareUploadResult {
    pub status_code: u16,
    pub response: Option<PrepareUploadResponseDto>,
}

pub struct ResultWithPublicKeyRegisterResponseDto {
    pub public_key: Option<String>,
    pub body: RegisterResponseDto,
}

#[frb(mirror(SyncFolderInfoDtoV2))]
pub struct _SyncFolderInfoDtoV2 {
    pub path: String,
    pub size_bytes: Option<u64>,
}

#[frb(mirror(SyncFileInfoV2))]
pub struct _SyncFileInfoV2 {
    pub path: String,
    pub size: u64,
    pub mtime: Option<u64>,
    pub sha256: String,
    pub is_dir: bool,
}

#[frb(mirror(SyncDiffV2))]
pub struct _SyncDiffV2 {
    pub session_id: String,
    pub need_upload: Vec<String>,
    pub delete_remote: Vec<String>,
    pub delete_dirs: Vec<String>,
}

#[frb(mirror(SyncManifestRequestV2))]
pub struct _SyncManifestRequestV2 {
    pub folder_id: String,
    pub files: Vec<SyncFileInfoV2>,
}

#[frb(mirror(SyncCommitRequestV2))]
pub struct _SyncCommitRequestV2 {
    pub session_id: String,
    pub delete_remote: Vec<String>,
    pub delete_dirs: Vec<String>,
}
