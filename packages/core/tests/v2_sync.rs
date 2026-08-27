#![cfg(feature = "http")]

//! Tests for the sync API (`/api/sync/v1/manifest` and `/api/sync/v1/commit`):
//! the manifest diff flow, the commit authorization and the TLS-only gate.

use localsend::http::client::LsHttpClientV2;
use localsend::http::dto_v2::{
    SyncDiffV2, SyncFileInfoV2, SyncManifestRequestV2, SyncManifestResultV2,
};
use localsend::http::server::v2::{ServerEventV2, SyncManifestDecisionV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::ProtocolType;
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot, Mutex};

/// A generated self-signed certificate, as LocalSend peers use them.
struct Identity {
    cert: String,
    private_key: String,
    /// Uppercase-hex SHA-256 of the certificate in DER format.
    fingerprint: String,
}

fn generate_identity() -> Identity {
    let cert = localsend::crypto::cert::generate_self_signed().unwrap();
    Identity {
        cert: cert.certificate_pem,
        private_key: cert.private_key_pem,
        fingerprint: cert.fingerprint,
    }
}

/// The decisions the test event loop takes for sync events.
#[derive(Default)]
struct SyncDecisions {
    /// `None` answers the manifest with [SyncManifestDecisionV2::Reject];
    /// `Some(diff)` answers [SyncManifestDecisionV2::Apply] with it. The
    /// `session_id` of a diff is rewritten to the expected one by the loop.
    manifest: Arc<Mutex<Option<SyncDiffV2>>>,
}

struct TestServer {
    port: u16,
    /// The fingerprint of the server certificate, for client pinning.
    fingerprint: String,
    /// The manifest events that reached the application layer.
    manifests: Arc<Mutex<Vec<SyncManifestRequestV2>>>,
    /// The commit events (session, file deletes, dir deletes) that reached
    /// the application layer.
    commits: Arc<Mutex<Vec<(String, Vec<String>, Vec<String>)>>>,
    /// Whether the application answers commits with success.
    commit_success: Arc<Mutex<bool>>,
    _stop_tx: oneshot::Sender<()>,
}

/// Starts a test server over TLS. When `tls` is false, the server runs plain
/// HTTP (the sync endpoints are then expected to reject every request).
async fn start_test_server(tls: bool, identity: &Identity, decisions: SyncDecisions) -> TestServer {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();
    let manifests: Arc<Mutex<Vec<SyncManifestRequestV2>>> = Arc::new(Mutex::new(Vec::new()));
    let commits: Arc<Mutex<Vec<(String, Vec<String>, Vec<String>)>>> = Arc::new(Mutex::new(Vec::new()));
    let commit_success: Arc<Mutex<bool>> = Arc::new(Mutex::new(true));

    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(16);

    tokio::spawn({
        let manifests = manifests.clone();
        let commits = commits.clone();
        let commit_success = commit_success.clone();
        async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    ServerEventV2::SyncManifestRequested {
                        manifest,
                        session_id,
                        response_tx,
                        ..
                    } => {
                        manifests.lock().await.push(manifest);
                        // The test answers with a diff whose session ID is
                        // rewritten to the pre-generated one, like the app
                        // would answer its own diffs.
                        let decision = {
                            let decisions = decisions.manifest.lock().await;
                            match decisions.as_ref() {
                                Some(diff) => SyncManifestDecisionV2::Apply(SyncDiffV2 {
                                    session_id: session_id.clone(),
                                    need_upload: diff.need_upload.clone(),
                                    delete_remote: diff.delete_remote.clone(),
                                    delete_dirs: diff.delete_dirs.clone(),
                                }),
                                None => SyncManifestDecisionV2::Reject {
                                    status: hyper::StatusCode::FORBIDDEN,
                                    message: "declined by test".to_string(),
                                },
                            }
                        };
                        let _ = response_tx.send(decision);
                    }
                    ServerEventV2::SyncCommitRequested {
                        session_id,
                        delete_remote,
                        delete_dirs,
                        response_tx,
                        ..
                    } => {
                        commits
                            .lock()
                            .await
                            .push((session_id, delete_remote, delete_dirs));
                        if *commit_success.lock().await {
                            let _ = response_tx.send(());
                        }
                        // Dropping response_tx fails the commit.
                    }
                    _ => {}
                }
            }
        }
    });

    let (stop_tx, stop_rx) = oneshot::channel::<()>();

    let handle = start_with_port(
        0,
        if tls {
            Some(TlsConfig {
                cert: identity.cert.clone(),
                private_key: identity.private_key.clone(),
            })
        } else {
            None
        },
        ClientInfo {
            alias: "Test Server".to_string(),
            version: "2.2".to_string(),
            device_model: Some("Rust".to_string()),
            device_type: None,
            token: identity.fingerprint.clone(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: true,
            event_tx,
        }),
        WebConfig::default(),
        stop_rx,
    )
    .await
    .expect("Failed to start server");

    TestServer {
        port: handle.port(),
        fingerprint: identity.fingerprint.clone(),
        manifests,
        commits,
        commit_success,
        _stop_tx: stop_tx,
    }
}

/// A client speaking to the server with its own certificate (over TLS) or
/// without one (plain HTTP, where it is ignored by the server).
fn client(identity: &Identity, tls: bool, server_fingerprint: &str) -> LsHttpClientV2 {
    if tls {
        LsHttpClientV2::try_new(
            &identity.private_key,
            &identity.cert,
            Some(server_fingerprint.to_string()),
            None,
        )
        .unwrap()
    } else {
        LsHttpClientV2::try_new_without_cert().unwrap()
    }
}

fn file(path: &str, sha256: &str) -> SyncFileInfoV2 {
    SyncFileInfoV2 {
        path: path.to_string(),
        size: 123,
        mtime: Some(1_700_000_000),
        sha256: sha256.to_string(),
        is_dir: false,
    }
}

/// A manifest entry for a directory.
fn dir(path: &str) -> SyncFileInfoV2 {
    SyncFileInfoV2 {
        path: path.to_string(),
        size: 0,
        mtime: Some(1_700_000_000),
        sha256: String::new(),
        is_dir: true,
    }
}

/// A diff with the given upload/delete lists; the server rewrites the session.
fn diff(need_upload: &[&str], delete_remote: &[&str]) -> SyncDiffV2 {
    diff_with_dirs(need_upload, delete_remote, &[])
}

/// A diff with the given upload/file-delete/dir-delete lists.
fn diff_with_dirs(need_upload: &[&str], delete_remote: &[&str], delete_dirs: &[&str]) -> SyncDiffV2 {
    SyncDiffV2 {
        session_id: String::new(),
        need_upload: need_upload.iter().map(|s| s.to_string()).collect(),
        delete_remote: delete_remote.iter().map(|s| s.to_string()).collect(),
        delete_dirs: delete_dirs.iter().map(|s| s.to_string()).collect(),
    }
}

#[tokio::test]
async fn sync_rejects_plain_http() {
    let decisions = SyncDecisions::default();
    let server_identity = generate_identity();
    let server = start_test_server(false, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, false, &server.fingerprint);

    let result = client
        .sync_manifest(
            ProtocolType::Http,
            "127.0.0.1",
            server.port,
            "default",
            vec![file("a.txt", "abc")],
        )
        .await
        .unwrap();

    match result {
        SyncManifestResultV2::Rejected { status, .. } => assert_eq!(status, 403),
        other => panic!("expected rejection, got {other:?}"),
    }

    // No manifest event must have reached the application.
    assert!(server.manifests.lock().await.is_empty());
}

#[tokio::test]
async fn sync_manifest_diff_flow() {
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff(&["a.txt"], &["old.txt"])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    let result = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", vec![file("a.txt", "abc"), file("b.txt", "def"), dir("empty")],
        )
        .await
        .unwrap();

    let SyncManifestResultV2::Diff(diff) = result else {
        panic!("expected diff, got {result:?}");
    };
    assert_eq!(diff.need_upload, vec!["a.txt"]);
    assert_eq!(diff.delete_remote, vec!["old.txt"]);
    assert!(!diff.session_id.is_empty());

    // The manifest reached the application with the directory entry intact.
    let manifests = server.manifests.lock().await;
    assert_eq!(manifests.len(), 1);
    assert_eq!(manifests[0].files.len(), 3);
    assert!(manifests[0].files.iter().any(|f| f.is_dir && f.path == "empty"));
}

#[tokio::test]
async fn sync_manifest_rejection_is_forwarded() {
    let decisions = SyncDecisions::default(); // no diff -> reject
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    let result = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", Vec::new(),
        )
        .await
        .unwrap();

    match result {
        SyncManifestResultV2::Rejected { status, message } => {
            assert_eq!(status, 403);
            assert_eq!(message, "declined by test");
        }
        other => panic!("expected rejection, got {other:?}"),
    }
}

#[tokio::test]
async fn sync_manifest_rejects_unsafe_paths() {
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff(&[], &[])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    for path in ["../escape.txt", "/absolute.txt", "a\\b.txt", ""] {
        let result = client
            .sync_manifest(
                ProtocolType::Https,
                "127.0.0.1",
                server.port, "default", vec![file(path, "abc")],
            )
            .await
            .unwrap();
        match result {
            SyncManifestResultV2::Rejected { status, .. } => assert_eq!(status, 400, "path: {path}"),
            other => panic!("path {path}: expected rejection, got {other:?}"),
        }
    }
}

#[tokio::test]
async fn sync_commit_deletes_authorized_paths() {
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff(&[], &["old.txt", "stale/other.txt"])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    // Obtain the session via a manifest.
    let SyncManifestResultV2::Diff(diff) = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", Vec::new(),
        )
        .await
        .unwrap()
    else {
        panic!("expected diff")
    };

    // Commit one of the authorized deletions.
    client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            vec!["old.txt".to_string()],
            Vec::new(),
        )
        .await
        .unwrap();

    let commits = server.commits.lock().await;
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].0, diff.session_id);
    assert_eq!(commits[0].1, vec!["old.txt"]);

    // The session was consumed by the commit: reusing it fails.
    let err = client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            vec!["old.txt".to_string()],
            Vec::new(),
        )
        .await
        .expect_err("session must be revoked after a commit");
    assert!(format!("{err:?}").contains("403"));
}

#[tokio::test]
async fn sync_commit_rejects_unauthorized_paths() {
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff(&[], &["old.txt"])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    let SyncManifestResultV2::Diff(diff) = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", Vec::new(),
        )
        .await
        .unwrap()
    else {
        panic!("expected diff")
    };

    // Not in the authorized list, and a path escape.
    for path in ["other.txt", "../outside.txt"] {
        let err = client
            .sync_commit(
                ProtocolType::Https,
                "127.0.0.1",
                server.port,
                &diff.session_id,
                vec![path.to_string()],
                Vec::new(),
            )
            .await
            .expect_err("unauthorized delete must fail");
        assert!(format!("{err:?}").contains("403"), "path: {path}, err: {err:?}");
    }

    // The session survives failed commits: an authorized commit still works.
    client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            vec!["old.txt".to_string()],
            Vec::new(),
        )
        .await
        .unwrap();

    // And no commit event reached the application for the rejected ones.
    let commits = server.commits.lock().await;
    assert_eq!(commits.len(), 1);
}

#[tokio::test]
async fn sync_commit_with_empty_deletes_does_not_touch_the_application() {
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff(&[], &[])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    let SyncManifestResultV2::Diff(diff) = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", Vec::new(),
        )
        .await
        .unwrap()
    else {
        panic!("expected diff")
    };

    client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            Vec::new(),
            Vec::new(),
        )
        .await
        .unwrap();

    assert!(server.commits.lock().await.is_empty());
}

#[tokio::test]
async fn sync_commit_deletes_authorized_dirs() {
    // The app's diff may authorize directory deletions (destination-only
    // empty dirs) alongside file deletions.
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff_with_dirs(&[], &[], &["stale", "stale/deep"])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    let SyncManifestResultV2::Diff(diff) = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", Vec::new(),
        )
        .await
        .unwrap()
    else {
        panic!("expected diff")
    };
    assert_eq!(diff.delete_dirs, vec!["stale", "stale/deep"]);

    // An unauthorized directory (not in delete_dirs) is rejected.
    let err = client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            Vec::new(),
            vec!["other/".to_string()],
        )
        .await
        .expect_err("unauthorized dir delete must fail");
    assert!(format!("{err:?}").contains("403"), "err: {err:?}");
    assert!(server.commits.lock().await.is_empty());

    // The authorized directories are forwarded to the application.
    client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            Vec::new(),
            vec!["stale".to_string(), "stale/deep".to_string()],
        )
        .await
        .unwrap();

    let commits = server.commits.lock().await;
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].1, Vec::<String>::new());
    assert_eq!(commits[0].2, vec!["stale", "stale/deep"]);
}

#[tokio::test]
async fn sync_commit_failure_keeps_session() {
    let decisions = SyncDecisions {
        manifest: Arc::new(Mutex::new(Some(diff(&[], &["old.txt"])))),
        ..Default::default()
    };
    let server_identity = generate_identity();
    let server = start_test_server(true, &server_identity, decisions).await;
    let sender = generate_identity();
    let client = client(&sender, true, &server.fingerprint);

    let SyncManifestResultV2::Diff(diff) = client
        .sync_manifest(
            ProtocolType::Https,
            "127.0.0.1",
            server.port, "default", Vec::new(),
        )
        .await
        .unwrap()
    else {
        panic!("expected diff")
    };

    // The application fails the deletions.
    *server.commit_success.lock().await = false;
    let err = client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            vec!["old.txt".to_string()],
            Vec::new(),
        )
        .await
        .expect_err("failed commit must error");
    assert!(format!("{err:?}").contains("500"), "err: {err:?}");

    // The session survives the failed commit, so the initiator can retry.
    *server.commit_success.lock().await = true;
    client
        .sync_commit(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            &diff.session_id,
            vec!["old.txt".to_string()],
            Vec::new(),
        )
        .await
        .unwrap();
}