use crate::model::discovery::DeviceType;
use crate::model::transfer::FileDto;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// Discovery types are shared with the (HTTP-independent) multicast module and
// therefore live in `crate::model::discovery`. They are re-exported here so that
// the v2 DTOs remain available under a single path.
use crate::model::discovery::ProtocolType;
use crate::model::discovery::{device_type_v2, protocol_type_v2};

/// The sync folder information of a device, as reported by
/// `POST /api/localsend/v2/sync-folder-info`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncFolderInfoDtoV2 {
    /// Absolute path of the device's configured sync folder.
    pub path: String,

    /// Total size of the folder in bytes, or null when not calculated yet.
    pub size_bytes: Option<u64>,
}

/// Result of a `POST /api/localsend/v2/sync-folder-info` request.
#[derive(Debug, Clone)]
pub enum SyncFolderInfoResultV2 {
    /// The device has a sync folder configured.
    Info(SyncFolderInfoDtoV2),

    /// The device has no sync folder configured (204 No Content).
    NotConfigured,
}

/// A single file or directory entry of a sync manifest.
///
/// The source device lists its files and directories so the destination can
/// diff them against its own directory. The comparison is authoritative on
/// `sha256` (empty for directories); the other fields are carried along for
/// future needs (e.g. block-level delta) and are not used by the diff.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncFileInfoV2 {
    /// Path relative to the sync folder root.
    /// Must not be absolute and must not contain `..` segments —
    /// the destination rejects such paths, since the path is where
    /// uploads are stored and what deletions target.
    pub path: String,

    /// Size of the entry in bytes (0 for directories).
    pub size: u64,

    /// Seconds since the Unix epoch of the last modification.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtime: Option<u64>,

    /// SHA-256 of the file content (hex, lowercase).
    /// The authoritative content identity for the comparison.
    /// Empty for directories.
    pub sha256: String,

    /// Whether the entry is a directory. Directories carry no content, but
    /// the listing includes them so the destination can mirror the source's
    /// empty folders: it keeps the ones the source has and deletes only the
    /// ones it does not.
    #[serde(default)]
    pub is_dir: bool,
}

/// The source device's directory listing, submitted by a sync initiator.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncManifestRequestV2 {
    /// Identifies the folder being synced. `"default"` for the app's single
    /// sync folder; reserved for future multi-folder support.
    pub folder_id: String,

    /// The files of the source folder, with paths relative to its root.
    pub files: Vec<SyncFileInfoV2>,
}

/// The diff of a source manifest against the destination directory.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncDiffV2 {
    /// Session that authorizes a later `POST /api/localsend/v2/sync/commit` to delete
    /// files. Only deletions listed in this diff may be committed.
    pub session_id: String,

    /// Files the destination is missing or whose `sha256` differs.
    /// The initiator uploads these via the regular v2 upload API.
    pub need_upload: Vec<String>,

    /// Files that exist on the destination but not in the manifest.
    /// Deletion must happen via a commit, so uploads are guaranteed to
    /// have succeeded first.
    pub delete_remote: Vec<String>,

    /// Directories that exist only on the destination (not in the manifest
    /// listing), whose entire content is being deleted, so they become empty
    /// once the commit applied. Deleted after `delete_remote`, deepest first;
    /// a directory that is still not empty is kept.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub delete_dirs: Vec<String>,
}

/// Instructs the destination to delete files previously reported in
/// [`SyncDiffV2::delete_remote`], i.e. after all uploads succeeded.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncCommitRequestV2 {
    /// The session that authorized the deletions.
    pub session_id: String,

    /// The relative paths of files to delete. Must be a subset of the
    /// `delete_remote` of the authorized diff.
    pub delete_remote: Vec<String>,

    /// The relative paths of (empty) directories to delete. Must be a subset
    /// of the `delete_dirs` of the authorized diff.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub delete_dirs: Vec<String>,
}

/// Result of a `POST /api/localsend/v2/sync/manifest` request.
#[derive(Debug, Clone)]
pub enum SyncManifestResultV2 {
    /// The destination computed a diff; proceed with the sync.
    Diff(SyncDiffV2),

    /// The destination refused the sync (e.g. no sync folder configured,
    /// HTTPS required, or the sync was declined).
    Rejected {
        /// The HTTP status code the destination answered with.
        status: u16,

        /// The error message from the destination.
        message: String,
    },
}

/// Register request DTO for v2.2 protocol.
///
/// Sent to POST /api/localsend/v2/register for device discovery.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDtoV2 {
    /// The display name of the device.
    pub alias: String,

    /// Protocol version (e.g., "2.0", "2.2").
    pub version: String,

    /// Device model (e.g., "Samsung", "Windows"). Optional.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,

    /// Device type category. Optional.
    #[serde(
        default,
        with = "device_type_v2",
        skip_serializing_if = "Option::is_none"
    )]
    pub device_type: Option<DeviceType>,

    /// Fingerprint for device identification.
    /// Ignored in HTTPS mode (certificate is used instead).
    pub fingerprint: String,

    /// Port number the device is listening on.
    pub port: u16,

    /// Protocol type (http or https).
    #[serde(with = "protocol_type_v2")]
    pub protocol: ProtocolType,

    /// Whether the download API (sections 5.2, 5.3) is active.
    #[serde(default)]
    pub download: bool,
}

/// Register response DTO for v2.2 protocol.
///
/// Response from POST /api/localsend/v2/register.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterResponseDtoV2 {
    /// The display name of the device.
    pub alias: String,

    /// Protocol version (e.g., "2.0", "2.2").
    pub version: String,

    /// Device model. Optional.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,

    /// Device type category. Optional.
    #[serde(
        default,
        with = "device_type_v2",
        skip_serializing_if = "Option::is_none"
    )]
    pub device_type: Option<DeviceType>,

    /// Fingerprint for device identification.
    /// Ignored in HTTPS mode (certificate is used instead).
    #[serde(default)]
    pub fingerprint: String,

    /// Whether the download API (sections 5.2, 5.3) is active.
    #[serde(default)]
    pub download: bool,
}

/// Prepare upload request DTO for v2.2 protocol.
///
/// Sent to POST /api/localsend/v2/prepare-upload to initiate a file transfer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadRequestDtoV2 {
    /// Sender's device information.
    pub info: RegisterDtoV2,

    /// Map of file ID to file metadata.
    pub files: HashMap<String, FileDto>,
}

/// Prepare upload response DTO for v2.2 protocol.
///
/// Response from POST /api/localsend/v2/prepare-upload.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponseDtoV2 {
    /// Session ID for the file transfer.
    pub session_id: String,

    /// Map of file ID to file token.
    /// Only contains files that were accepted by the receiver.
    pub files: HashMap<String, String>,
}

pub struct PrepareUploadResultV2 {
    pub status_code: u16,
    pub response: Option<PrepareUploadResponseDtoV2>,
}

/// Prepare download response DTO for v2.2 protocol (Download API).
///
/// Response from POST /api/localsend/v2/prepare-download.
/// Used when the sender provides files for others to download.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareDownloadResponseDtoV2 {
    /// Sender's device information.
    pub info: InfoResponseDtoV2,

    /// Session ID for the download session.
    pub session_id: String,

    /// Map of file ID to file metadata.
    pub files: HashMap<String, FileDto>,
}

/// Info response DTO for v2.2 protocol.
///
/// Response from GET /api/localsend/v2/info.
/// Also used as the `info` field in PrepareDownloadResponseDtoV2.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoResponseDtoV2 {
    /// The display name of the device.
    pub alias: String,

    /// Protocol version (e.g., "2.0", "2.2").
    pub version: String,

    /// Device model. Optional.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,

    /// Device type category. Optional.
    #[serde(
        default,
        with = "device_type_v2",
        skip_serializing_if = "Option::is_none"
    )]
    pub device_type: Option<DeviceType>,

    /// Fingerprint for device identification.
    pub fingerprint: String,

    /// Whether the download API (sections 5.2, 5.3) is active.
    #[serde(default)]
    pub download: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_register_dto_v2_deserialization() {
        let json = r#"{
            "alias": "Secret Banana",
            "version": "2.0",
            "deviceModel": "Windows",
            "deviceType": "desktop",
            "fingerprint": "random string",
            "port": 53317,
            "protocol": "https",
            "download": true
        }"#;

        let dto: RegisterDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(dto.alias, "Secret Banana");
        assert_eq!(dto.version, "2.0");
        assert_eq!(dto.device_model, Some("Windows".to_string()));
        assert_eq!(dto.device_type, Some(DeviceType::Desktop));
        assert_eq!(dto.fingerprint, "random string");
        assert_eq!(dto.port, 53317);
        assert_eq!(dto.protocol, ProtocolType::Https);
        assert!(dto.download);
    }

    #[test]
    fn test_device_type_unknown_falls_back_to_desktop() {
        // Unknown device types must fall back to desktop (protocol section 7.1).
        let json = r#"{
            "alias": "Test Device",
            "version": "2.0",
            "deviceType": "fridge",
            "fingerprint": "abc123",
            "port": 53317,
            "protocol": "http"
        }"#;

        let dto: RegisterDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(dto.device_type, Some(DeviceType::Desktop));
    }

    #[test]
    fn test_register_response_without_download_field() {
        // Test that download defaults to false when not present
        let json = r#"{
            "alias": "Test Device",
            "version": "2.0",
            "fingerprint": "abc123"
        }"#;

        let dto: RegisterResponseDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(dto.alias, "Test Device");
        assert!(!dto.download);
    }

    #[test]
    fn test_prepare_upload_request_v2() {
        let request = PrepareUploadRequestDtoV2 {
            info: RegisterDtoV2 {
                alias: "Sender".to_string(),
                version: "2.2".to_string(),
                device_model: None,
                device_type: None,
                fingerprint: "sender-fingerprint".to_string(),
                port: 53317,
                protocol: ProtocolType::Https,
                download: false,
            },
            files: HashMap::from([(
                "file1".to_string(),
                FileDto {
                    id: "file1".to_string(),
                    file_name: "test.png".to_string(),
                    size: 1024,
                    file_type: "image/png".to_string(),
                    sha256: None,
                    preview: None,
                    metadata: None,
                },
            )]),
        };

        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("\"info\""));
        assert!(json.contains("\"files\""));
        assert!(json.contains("\"fingerprint\":\"sender-fingerprint\""));
    }
}
